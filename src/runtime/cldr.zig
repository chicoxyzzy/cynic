//! Embedded Unicode CLDR data for `-Dintl=full` builds.
//!
//! The blob is `vendor/cldr/cynic_cldr.bin` (CYCL v2 — see `tools/pack_cldr.zig`):
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
    numbers = 3,
    numbering_systems = 4,
    dates = 5,
    display_names = 6,
    currencies = 7,
    currency_names = 8,
    likely_subtags = 9,
    list_patterns = 10,
    relative_time = 11,
    compact = 12,
    units = 13,
    language_aliases = 14,
    territory_aliases = 15,
    interval_formats = 16,
};

// ── container parse (lazy; thread-safe one-shot init) ────────────────────────
//
// The test262 harness runs one Realm per worker thread and every intl
// formatting path funnels through `ensureInit`, so the first CLDR access races
// across workers. A plain `init_done` flag let a racer observe it `true` before
// the payload slices were published, then read an empty payload set and fall
// back to structural / Latin-numeral output — a nondeterministic wrong result
// (never a crash). Init is now an atomic `uninit → building → done` one-shot:
// the CAS winner parses the blob and publishes `done` with a release store;
// racers spin on an acquire load until the payloads are visible. Mirrors the
// pattern in `unicode/perlex_props.zig`.

const InitState = enum(u8) { uninit, building, done };
var init_state = std.atomic.Value(u8).init(@intFromEnum(InitState.uninit));
var init_ok: bool = false;
var card_payload: []const u8 = &.{};
var ord_payload: []const u8 = &.{};
var cur_payload: []const u8 = &.{};
var cur_names_payload: []const u8 = &.{};
var num_payload: []const u8 = &.{};
var ns_payload: []const u8 = &.{};
var dates_payload: []const u8 = &.{};
var display_payload: []const u8 = &.{};
var likely_payload: []const u8 = &.{};
var lp_payload: []const u8 = &.{};
var rt_payload: []const u8 = &.{};
var cp_payload: []const u8 = &.{};
var un_payload: []const u8 = &.{};
var lang_alias_payload: []const u8 = &.{};
var territory_alias_payload: []const u8 = &.{};
var iv_payload: []const u8 = &.{};

fn embedBlob() []const u8 {
    if (!available) return &.{};
    return @embedFile("cynic_cldr.bin");
}

/// Parse the embedded CLDR container into the payload slices exactly once
/// across threads, then report whether the data is usable. The winner of the
/// `uninit`→`building` CAS runs `parseContainer` and publishes `done`; racers
/// spin until the payloads are visible (`release`/`acquire` pair the parse's
/// writes to the reading thread).
fn ensureInit() bool {
    if (init_state.load(.acquire) != @intFromEnum(InitState.done)) initOnce();
    return init_ok;
}

fn initOnce() void {
    if (init_state.cmpxchgStrong(
        @intFromEnum(InitState.uninit),
        @intFromEnum(InitState.building),
        .acq_rel,
        .acquire,
    ) == null) {
        init_ok = parseContainer();
        init_state.store(@intFromEnum(InitState.done), .release);
        return;
    }
    while (init_state.load(.acquire) != @intFromEnum(InitState.done)) {
        std.atomic.spinLoopHint();
    }
}

/// The container walk. Runs on exactly one thread (the CAS winner), so its
/// writes to the module-level payload slices need no atomics — `initOnce`
/// publishes them with a release store once this returns. Reports whether the
/// blob parsed cleanly; on any structural error the payloads stay empty and
/// callers fall back to structural formatting.
fn parseContainer() bool {
    if (!available) return false;
    const blob = embedBlob();
    if (blob.len < 12) return false;
    if (!std.mem.eql(u8, blob[0..4], "CYCL")) return false;
    if (blob[4] != 2) return false;
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
            @intFromEnum(SectionKind.numbers) => num_payload = payload,
            @intFromEnum(SectionKind.numbering_systems) => ns_payload = payload,
            @intFromEnum(SectionKind.dates) => dates_payload = payload,
            @intFromEnum(SectionKind.display_names) => display_payload = payload,
            @intFromEnum(SectionKind.currencies) => cur_payload = payload,
            @intFromEnum(SectionKind.currency_names) => cur_names_payload = payload,
            @intFromEnum(SectionKind.likely_subtags) => likely_payload = payload,
            @intFromEnum(SectionKind.list_patterns) => lp_payload = payload,
            @intFromEnum(SectionKind.relative_time) => rt_payload = payload,
            @intFromEnum(SectionKind.compact) => cp_payload = payload,
            @intFromEnum(SectionKind.units) => un_payload = payload,
            @intFromEnum(SectionKind.language_aliases) => lang_alias_payload = payload,
            @intFromEnum(SectionKind.territory_aliases) => territory_alias_payload = payload,
            @intFromEnum(SectionKind.interval_formats) => iv_payload = payload,
            else => {}, // unknown/future section — ignore
        }
    }
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

// ── numbers (symbols + patterns) ─────────────────────────────────────────────

/// Per-locale number formatting data from the CLDR `numbers` section.
pub const NumberData = struct {
    ns: []const u8, // default numbering system id
    digit_base: u32, // code point of that system's digit 0
    decimal: []const u8,
    group: []const u8,
    minus: []const u8,
    plus: []const u8,
    percent: []const u8,
    infinity: []const u8, // §15.5.x non-finite glyph (CLDR `infinity` symbol)
    nan: []const u8, // §15.5.x non-finite glyph (CLDR `nan` symbol)
    dec_pattern: []const u8,
    pct_pattern: []const u8,
    min_group: u8 = 1, // minimumGroupingDigits (UTS #35 grouping suppression)
};

/// Look up the locale's number data (default numbering system), most- to
/// least-specific candidate. Returns null when absent (caller falls back to en).
pub fn numberData(locale: []const u8) ?NumberData {
    if (!ensureInit()) return null;
    if (num_payload.len < 4) return null;

    var lang_buf: [16]u8 = undefined;
    var script_buf: [8]u8 = undefined;
    var region_buf: [8]u8 = undefined;
    const parts = splitTag(locale, &lang_buf, &script_buf, &region_buf);
    if (parts.lang.len == 0) return null;

    var cand_buf: [32]u8 = undefined;
    if (parts.script.len > 0 and parts.region.len > 0)
        if (joinTag(&cand_buf, parts.lang, parts.script, parts.region)) |k|
            if (findNumber(k)) |d| return d;
    if (parts.region.len > 0)
        if (joinTag(&cand_buf, parts.lang, "", parts.region)) |k|
            if (findNumber(k)) |d| return d;
    if (parts.script.len > 0)
        if (joinTag(&cand_buf, parts.lang, parts.script, "")) |k|
            if (findNumber(k)) |d| return d;
    return findNumber(parts.lang);
}

/// Digit-0 code point for an explicit numbering system id (e.g. "arab"), so a
/// requested `numberingSystem` option can substitute glyphs. null if unknown.
pub fn numberingSystemDigitBase(id: []const u8) ?u32 {
    if (!ensureInit()) return null;
    if (ns_payload.len < 4) return null;
    const count = std.mem.readInt(u32, ns_payload[0..4], .little);
    var off: usize = 4;
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        if (off + 1 > ns_payload.len) return null;
        const ilen = ns_payload[off];
        off += 1;
        if (off + ilen + 4 > ns_payload.len) return null;
        const nid = ns_payload[off .. off + ilen];
        off += ilen;
        const base = std.mem.readInt(u32, ns_payload[off..][0..4], .little);
        off += 4;
        if (asciiEqlIgnoreCase(nid, id)) return base;
    }
    return null;
}

/// Append every numbering-system id in the packed digit-base table to `out`.
/// Each id borrows from the embedded blob (static lifetime). This set is
/// exactly the systems `numberingSystemDigitBase` accepts, which is what
/// `Intl.supportedValuesOf("numberingSystem")` must enumerate so the
/// enumerate-set matches what NumberFormat accepts (§6 AvailableNumberingSystems).
pub fn appendNumberingSystemIds(alloc: std.mem.Allocator, out: *std.ArrayListUnmanaged([]const u8)) !void {
    if (!ensureInit() or ns_payload.len < 4) return;
    const count = std.mem.readInt(u32, ns_payload[0..4], .little);
    var off: usize = 4;
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        if (off + 1 > ns_payload.len) return;
        const ilen = ns_payload[off];
        off += 1;
        if (off + ilen + 4 > ns_payload.len) return;
        try out.append(alloc, ns_payload[off .. off + ilen]);
        off += ilen + 4;
    }
}

fn findNumber(key: []const u8) ?NumberData {
    const count = std.mem.readInt(u32, num_payload[0..4], .little);
    var off: usize = 4;
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        var d: NumberData = undefined;
        const klen = readU8(num_payload, &off) orelse return null;
        const k = readBytes(num_payload, &off, klen) orelse return null;
        const nslen = readU8(num_payload, &off) orelse return null;
        d.ns = readBytes(num_payload, &off, nslen) orelse return null;
        d.digit_base = readU32(num_payload, &off) orelse return null;
        d.decimal = readStr8(num_payload, &off) orelse return null;
        d.group = readStr8(num_payload, &off) orelse return null;
        d.minus = readStr8(num_payload, &off) orelse return null;
        d.plus = readStr8(num_payload, &off) orelse return null;
        d.percent = readStr8(num_payload, &off) orelse return null;
        d.infinity = readStr8(num_payload, &off) orelse return null;
        d.nan = readStr8(num_payload, &off) orelse return null;
        d.dec_pattern = readStr16(num_payload, &off) orelse return null;
        d.pct_pattern = readStr16(num_payload, &off) orelse return null;
        d.min_group = readU8(num_payload, &off) orelse 1;
        if (asciiEqlIgnoreCase(k, key)) return d;
    }
    return null;
}

// ── currencies (symbols + patterns + fraction digits) ─────────────────────────

pub const CurrencyPattern = struct { standard: []const u8, accounting: []const u8 };

/// §15.1.1 cCurrencyDigits — minor units for a currency code. The packed table
/// holds only non-default entries; returns 2 (the CLDR `DEFAULT`) when absent.
pub fn currencyFractionDigits(code: []const u8) u8 {
    if (!ensureInit() or cur_payload.len < 4 or code.len != 3) return 2;
    const count = std.mem.readInt(u32, cur_payload[0..4], .little);
    var off: usize = 4;
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const c = readBytes(cur_payload, &off, 3) orelse return 2;
        const digits = readU8(cur_payload, &off) orelse return 2;
        if (asciiEqlIgnoreCase(c, code)) return digits;
    }
    return 2;
}

/// Byte offset of the per-locale currency table (just past the fraction table).
fn currencyLocalesStart() ?usize {
    if (cur_payload.len < 4) return null;
    const fcount = std.mem.readInt(u32, cur_payload[0..4], .little);
    const start = 4 + @as(usize, fcount) * 4; // 3-byte code + 1-byte digits
    return if (start + 4 <= cur_payload.len) start else null;
}

/// Advance `off` past the per-locale unitPattern block (u8 count, then
/// [u8 category; str16 pattern] each). Returns false on a malformed payload.
fn skipUnitPatterns(off: *usize) bool {
    const uc = readU8(cur_payload, off) orelse return false;
    var u: u32 = 0;
    while (u < uc) : (u += 1) {
        _ = readU8(cur_payload, off) orelse return false; // category
        _ = readStr16(cur_payload, off) orelse return false; // pattern
    }
    return true;
}

/// Locate one locale's currency record; returns the offset just past its key
/// (at `std_pattern`). Exact key match only — callers walk the fallback chain.
fn findCurrencyLocale(key: []const u8) ?usize {
    const tbl = currencyLocalesStart() orelse return null;
    var off = tbl;
    const count = std.mem.readInt(u32, cur_payload[off..][0..4], .little);
    off += 4;
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const klen = readU8(cur_payload, &off) orelse return null;
        const k = readBytes(cur_payload, &off, klen) orelse return null;
        const rec_off = off;
        // Skip std + acct patterns, the unitPattern block, and the symbol table
        // to reach the next key.
        _ = readStr16(cur_payload, &off) orelse return null;
        _ = readStr16(cur_payload, &off) orelse return null;
        if (!skipUnitPatterns(&off)) return null;
        const sym_count = readU16(cur_payload, &off) orelse return null;
        var s: u32 = 0;
        while (s < sym_count) : (s += 1) {
            _ = readBytes(cur_payload, &off, 3) orelse return null;
            _ = readStr8(cur_payload, &off) orelse return null;
            _ = readStr8(cur_payload, &off) orelse return null;
        }
        if (asciiEqlIgnoreCase(k, key)) return rec_off;
    }
    return null;
}

/// The currency display pattern pair for a locale (`¤#,##0.00` + accounting),
/// walking the language/script/region fallback chain. Null when absent.
pub fn currencyPattern(locale: []const u8) ?CurrencyPattern {
    if (!ensureInit()) return null;
    var rec_off: ?usize = null;
    if (withCandidates(locale, findCurrencyLocale)) |o| rec_off = o;
    const off0 = rec_off orelse return null;
    var off = off0;
    const std_pat = readStr16(cur_payload, &off) orelse return null;
    const acct_pat = readStr16(cur_payload, &off) orelse return null;
    return .{ .standard = std_pat, .accounting = acct_pat };
}

/// The localized currency symbol (or narrow symbol) for `code` in `locale`,
/// walking the fallback chain. Null when the locale stores no override (caller
/// falls back to the ISO code). `narrow` prefers `symbol-alt-narrow`.
pub fn currencySymbol(locale: []const u8, code: []const u8, narrow: bool) ?[]const u8 {
    if (!ensureInit() or code.len != 3) return null;
    const off0 = withCandidates(locale, findCurrencyLocale) orelse return null;
    var off = off0;
    _ = readStr16(cur_payload, &off) orelse return null; // std
    _ = readStr16(cur_payload, &off) orelse return null; // acct
    if (!skipUnitPatterns(&off)) return null;
    const sym_count = readU16(cur_payload, &off) orelse return null;
    var s: u32 = 0;
    while (s < sym_count) : (s += 1) {
        const c = readBytes(cur_payload, &off, 3) orelse return null;
        const sym = readStr8(cur_payload, &off) orelse return null;
        const nar = readStr8(cur_payload, &off) orelse return null;
        if (asciiEqlIgnoreCase(c, code))
            return if (narrow and nar.len > 0) nar else sym;
    }
    return null;
}

/// The currencyDisplay:"name" `unitPattern-count-{category}` for a locale
/// ("{0} {1}"), with the canonical CLDR fallback to the "other" form. Null when
/// the locale has no unitPattern data (caller defaults to "{0} {1}").
pub fn currencyUnitPattern(locale: []const u8, category: PluralCategory) ?[]const u8 {
    if (!ensureInit()) return null;
    const off0 = withCandidates(locale, findCurrencyLocale) orelse return null;
    var off = off0;
    _ = readStr16(cur_payload, &off) orelse return null; // std
    _ = readStr16(cur_payload, &off) orelse return null; // acct
    const want: u8 = @intFromEnum(category);
    const uc = readU8(cur_payload, &off) orelse return null;
    var found: ?[]const u8 = null;
    var other: ?[]const u8 = null;
    var u: u32 = 0;
    while (u < uc) : (u += 1) {
        const cat = readU8(cur_payload, &off) orelse return null;
        const pat = readStr16(cur_payload, &off) orelse return null;
        if (cat == want) found = pat;
        if (cat == @intFromEnum(PluralCategory.other)) other = pat;
    }
    return found orelse other;
}

/// The currencyDisplay:"name" long name for `code` in `locale`, plural-selected
/// by `category` with the CLDR fallback chain (category → "other"). Null when
/// the locale/currency stores no plural name — the caller then falls back to the
/// singular display name (`displayName`) and finally the ISO code itself.
pub fn currencyDisplayNameCount(locale: []const u8, code: []const u8, category: PluralCategory) ?[]const u8 {
    if (!ensureInit() or code.len != 3 or cur_names_payload.len < 4) return null;
    const off0 = withCandidates(locale, findCurrencyName) orelse return null;
    var off = off0;
    const cur_count = readU32(cur_names_payload, &off) orelse return null;
    const want: u8 = @intFromEnum(category);
    var i: u32 = 0;
    while (i < cur_count) : (i += 1) {
        const c = readBytes(cur_names_payload, &off, 3) orelse return null;
        const form_count = readU8(cur_names_payload, &off) orelse return null;
        const match = asciiEqlIgnoreCase(c, code);
        var found: ?[]const u8 = null;
        var other: ?[]const u8 = null;
        var f: u8 = 0;
        while (f < form_count) : (f += 1) {
            const cat = readU8(cur_names_payload, &off) orelse return null;
            const name = readStr16(cur_names_payload, &off) orelse return null;
            if (match) {
                if (cat == want) found = name;
                if (cat == @intFromEnum(PluralCategory.other)) other = name;
            }
        }
        if (match) return found orelse other;
    }
    return null;
}

/// Append every currency code with a display name in `locale`'s record
/// (walking the fallback chain) to `out`. Each code is a 3-byte slice
/// borrowed from the blob (static lifetime). This is the AvailableCurrencies
/// set — the codes DisplayNames can name — which supportedValuesOf("currency")
/// must enumerate so the enumerate-set matches DisplayNames (§6).
pub fn appendCurrencyCodes(locale: []const u8, alloc: std.mem.Allocator, out: *std.ArrayListUnmanaged([]const u8)) !void {
    if (!ensureInit() or cur_names_payload.len < 4) return;
    const off0 = withCandidates(locale, findCurrencyName) orelse return;
    var off = off0;
    const cur_count = readU32(cur_names_payload, &off) orelse return;
    var i: u32 = 0;
    while (i < cur_count) : (i += 1) {
        const code = readBytes(cur_names_payload, &off, 3) orelse return;
        try out.append(alloc, code);
        const form_count = readU8(cur_names_payload, &off) orelse return;
        var f: u8 = 0;
        while (f < form_count) : (f += 1) {
            _ = readU8(cur_names_payload, &off) orelse return; // category
            _ = readStr16(cur_names_payload, &off) orelse return; // name
        }
    }
}

/// Locate a locale's record in the `currency_names` section; returns the offset
/// just past the key (at `cur_count`). Mirrors `findCurrencyLocale`.
fn findCurrencyName(key: []const u8) ?usize {
    if (cur_names_payload.len < 4) return null;
    var off: usize = 0;
    const count = readU32(cur_names_payload, &off) orelse return null;
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const klen = readU8(cur_names_payload, &off) orelse return null;
        const k = readBytes(cur_names_payload, &off, klen) orelse return null;
        const rec_off = off;
        const cur_count = readU32(cur_names_payload, &off) orelse return null;
        var c: u32 = 0;
        while (c < cur_count) : (c += 1) {
            _ = readBytes(cur_names_payload, &off, 3) orelse return null; // code
            const form_count = readU8(cur_names_payload, &off) orelse return null;
            var f: u8 = 0;
            while (f < form_count) : (f += 1) {
                _ = readU8(cur_names_payload, &off) orelse return null; // cat
                _ = readStr16(cur_names_payload, &off) orelse return null; // name
            }
        }
        if (asciiEqlIgnoreCase(k, key)) return rec_off;
    }
    return null;
}

/// Walk the most→least specific locale candidates (lang-script-region, …,
/// lang), calling `find` on each; returns the first hit. Mirrors numberData.
fn withCandidates(locale: []const u8, comptime find: fn ([]const u8) ?usize) ?usize {
    var lang_buf: [16]u8 = undefined;
    var script_buf: [8]u8 = undefined;
    var region_buf: [8]u8 = undefined;
    const parts = splitTag(locale, &lang_buf, &script_buf, &region_buf);
    if (parts.lang.len == 0) return null;
    var cand_buf: [32]u8 = undefined;
    if (parts.script.len > 0 and parts.region.len > 0)
        if (joinTag(&cand_buf, parts.lang, parts.script, parts.region)) |k|
            if (find(k)) |o| return o;
    if (parts.region.len > 0)
        if (joinTag(&cand_buf, parts.lang, "", parts.region)) |k|
            if (find(k)) |o| return o;
    if (parts.script.len > 0)
        if (joinTag(&cand_buf, parts.lang, parts.script, "")) |k|
            if (find(k)) |o| return o;
    return find(parts.lang);
}

// ── list patterns (Intl.ListFormat) ──────────────────────────────────────────

/// Which template in a {2,start,middle,end} group.
pub const ListPatternKind = enum(u8) { two = 0, start = 1, middle = 2, end = 3 };

/// Locate one locale's list-pattern record; returns the offset at its first
/// pattern set (just past the key). Exact key match — callers walk fallback.
fn findListPatternLocale(key: []const u8) ?usize {
    if (lp_payload.len < 4) return null;
    const count = std.mem.readInt(u32, lp_payload[0..4], .little);
    var off: usize = 4;
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const klen = readU8(lp_payload, &off) orelse return null;
        const k = readBytes(lp_payload, &off, klen) orelse return null;
        const rec_off = off;
        // Skip 9 sets × 4 str16 patterns to reach the next key.
        var s: usize = 0;
        while (s < 9 * 4) : (s += 1) {
            _ = readStr16(lp_payload, &off) orelse return null;
        }
        if (asciiEqlIgnoreCase(k, key)) return rec_off;
    }
    return null;
}

/// The `Intl.ListFormat` template for `locale` + (type, style, which), walking
/// the language/script/region fallback chain. `type_idx` 0=conjunction
/// 1=disjunction 2=unit; `style_idx` 0=long 1=short 2=narrow. Null when the
/// CLDR data is unavailable or the locale is absent.
pub fn listPattern(locale: []const u8, type_idx: u8, style_idx: u8, which: ListPatternKind) ?[]const u8 {
    if (!ensureInit() or type_idx > 2 or style_idx > 2) return null;
    const rec_off = withCandidates(locale, findListPatternLocale) orelse return null;
    // Patterns are variable-length str16s, so walk to the target: skip
    // (set_idx*4 + which) entries, where set_idx = type*3 + style.
    const target: usize = (@as(usize, type_idx) * 3 + style_idx) * 4 + @intFromEnum(which);
    var off = rec_off;
    var idx: usize = 0;
    var pat: []const u8 = "";
    while (idx <= target) : (idx += 1) {
        pat = readStr16(lp_payload, &off) orelse return null;
    }
    return pat;
}

// ── compact notation (Intl.NumberFormat notation:"compact") ──────────────────

fn findCompactLocale(key: []const u8) ?usize {
    if (cp_payload.len < 4) return null;
    const count = std.mem.readInt(u32, cp_payload[0..4], .little);
    var off: usize = 4;
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const klen = readU8(cp_payload, &off) orelse return null;
        const k = readBytes(cp_payload, &off, klen) orelse return null;
        const styles_off = off;
        // Skip both style blocks to reach the next locale key.
        inline for (.{ 0, 1 }) |_| off = skipCompactStyle(off) orelse return null;
        if (asciiEqlIgnoreCase(k, key)) return styles_off;
    }
    return null;
}

fn skipCompactStyle(off_in: usize) ?usize {
    var off = off_in;
    if (off + 4 > cp_payload.len) return null;
    const c = std.mem.readInt(u32, cp_payload[off..][0..4], .little);
    off += 4;
    var i: u32 = 0;
    while (i < c) : (i += 1) {
        off += 2; // power + cat
        _ = readStr16(cp_payload, &off) orelse return null;
    }
    return off;
}

/// The compact pattern (e.g. "0K", "0 thousand") for (locale, style, 10^power,
/// plural cat), falling back to the "other" category. Null when absent — the
/// caller then renders the value with no compaction. `power` is the exponent of
/// the chosen magnitude bucket (3 for 10³ … 14 for 10¹⁴).
pub fn compactPattern(locale: []const u8, long: bool, power: u8, cat: PluralCategory) ?[]const u8 {
    if (!ensureInit()) return null;
    const styles_off = withCandidates(locale, findCompactLocale) orelse return null;
    var off = styles_off;
    if (long) off = skipCompactStyle(off) orelse return null;
    if (off + 4 > cp_payload.len) return null;
    const c = std.mem.readInt(u32, cp_payload[off..][0..4], .little);
    off += 4;
    var fallback: ?[]const u8 = null;
    var i: u32 = 0;
    while (i < c) : (i += 1) {
        const p = readU8(cp_payload, &off) orelse return null;
        const ct = readU8(cp_payload, &off) orelse return null;
        const pat = readStr16(cp_payload, &off) orelse return null;
        if (p == power) {
            if (ct == @intFromEnum(cat)) return pat;
            if (ct == @intFromEnum(PluralCategory.other)) fallback = pat;
        }
    }
    return fallback;
}

// ── measurement units (Intl.NumberFormat style:"unit") ───────────────────────

fn findUnitsLocale(key: []const u8) ?usize {
    if (un_payload.len < 4) return null;
    const count = std.mem.readInt(u32, un_payload[0..4], .little);
    var off: usize = 4;
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const klen = readU8(un_payload, &off) orelse return null;
        const k = readBytes(un_payload, &off, klen) orelse return null;
        const data_off = off; // at compound_per[0]
        // Skip 3 compound_per str16s + the unit list to reach the next key.
        inline for (.{ 0, 1, 2 }) |_| _ = readStr16(un_payload, &off) orelse return null;
        if (off + 4 > un_payload.len) return null;
        const uc = std.mem.readInt(u32, un_payload[off..][0..4], .little);
        off += 4;
        var u: u32 = 0;
        while (u < uc) : (u += 1) {
            const slen = readU8(un_payload, &off) orelse return null;
            _ = readBytes(un_payload, &off, slen) orelse return null;
            inline for (.{ 0, 1, 2 }) |_| off = skipUnitStyle(off) orelse return null;
        }
        if (asciiEqlIgnoreCase(k, key)) return data_off;
    }
    return null;
}

fn skipUnitStyle(off_in: usize) ?usize {
    var off = off_in;
    _ = readStr16(un_payload, &off) orelse return null; // display
    _ = readStr16(un_payload, &off) orelse return null; // per
    const pc = readU8(un_payload, &off) orelse return null;
    var i: usize = 0;
    while (i < pc) : (i += 1) {
        off += 1; // cat
        _ = readStr16(un_payload, &off) orelse return null;
    }
    return off;
}

/// Offset at the (style_idx) style block's `display` str16 for one unit, or null.
fn unitStyleBase(locale: []const u8, simple: []const u8, style_idx: u8) ?usize {
    if (style_idx > 2) return null;
    const data_off = withCandidates(locale, findUnitsLocale) orelse return null;
    var off = data_off;
    inline for (.{ 0, 1, 2 }) |_| _ = readStr16(un_payload, &off) orelse return null; // skip compound_per
    if (off + 4 > un_payload.len) return null;
    const uc = std.mem.readInt(u32, un_payload[off..][0..4], .little);
    off += 4;
    var u: u32 = 0;
    while (u < uc) : (u += 1) {
        const slen = readU8(un_payload, &off) orelse return null;
        const name = readBytes(un_payload, &off, slen) orelse return null;
        if (std.mem.eql(u8, name, simple)) {
            var s: u8 = 0;
            while (s < style_idx) : (s += 1) off = skipUnitStyle(off) orelse return null;
            return off;
        }
        inline for (.{ 0, 1, 2 }) |_| off = skipUnitStyle(off) orelse return null;
    }
    return null;
}

/// The unitPattern for (locale, unit, style, plural cat), "other" fallback. The
/// "{0}" placeholder receives the formatted number. Null when the unit is absent.
pub fn unitPattern(locale: []const u8, simple: []const u8, style_idx: u8, cat: PluralCategory) ?[]const u8 {
    if (!ensureInit()) return null;
    var off = unitStyleBase(locale, simple, style_idx) orelse return null;
    _ = readStr16(un_payload, &off) orelse return null; // display
    _ = readStr16(un_payload, &off) orelse return null; // per
    const pc = readU8(un_payload, &off) orelse return null;
    var fallback: ?[]const u8 = null;
    var i: usize = 0;
    while (i < pc) : (i += 1) {
        const ct = readU8(un_payload, &off) orelse return null;
        const pat = readStr16(un_payload, &off) orelse return null;
        if (ct == @intFromEnum(cat)) return pat;
        if (ct == @intFromEnum(PluralCategory.other)) fallback = pat;
    }
    return fallback;
}

/// The perUnitPattern for (locale, unit, style) — the divisor side of a compound
/// "X-per-Y" ("{0}/h", "{0} per hour"). Empty string when CLDR has none.
pub fn unitPerPattern(locale: []const u8, simple: []const u8, style_idx: u8) ?[]const u8 {
    if (!ensureInit()) return null;
    var off = unitStyleBase(locale, simple, style_idx) orelse return null;
    _ = readStr16(un_payload, &off) orelse return null; // display
    return readStr16(un_payload, &off);
}

/// The displayName for (locale, unit, style) — used as "{1}" when a compound's
/// divisor unit has no perUnitPattern. Empty string when absent.
pub fn unitDisplay(locale: []const u8, simple: []const u8, style_idx: u8) ?[]const u8 {
    if (!ensureInit()) return null;
    var off = unitStyleBase(locale, simple, style_idx) orelse return null;
    return readStr16(un_payload, &off);
}

/// The "per" compoundUnitPattern ("{0}/{1}") for (locale, style), used to combine
/// when the divisor unit has no perUnitPattern. Empty string when absent.
pub fn unitCompoundPer(locale: []const u8, style_idx: u8) ?[]const u8 {
    if (!ensureInit() or style_idx > 2) return null;
    const data_off = withCandidates(locale, findUnitsLocale) orelse return null;
    var off = data_off;
    var s: u8 = 0;
    while (s < style_idx) : (s += 1) _ = readStr16(un_payload, &off) orelse return null;
    return readStr16(un_payload, &off);
}

// ── relative time (Intl.RelativeTimeFormat) ──────────────────────────────────

/// Seek to one locale's relative-time field block (unit*3 + style), walking the
/// variable-length field records. Returns the offset at that field's rel_count.
fn findRelTimeField(locale: []const u8, field_idx: usize) ?usize {
    const tbl_off = withCandidates(locale, findRelTimeLocale) orelse return null;
    var off = tbl_off;
    var fi: usize = 0;
    while (fi < field_idx) : (fi += 1) off = skipRelTimeField(off) orelse return null;
    return off;
}

fn findRelTimeLocale(key: []const u8) ?usize {
    if (rt_payload.len < 4) return null;
    const count = std.mem.readInt(u32, rt_payload[0..4], .little);
    var off: usize = 4;
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const klen = readU8(rt_payload, &off) orelse return null;
        const k = readBytes(rt_payload, &off, klen) orelse return null;
        const fields_off = off;
        // Skip all 24 fields to reach the next locale key.
        var fi: usize = 0;
        while (fi < 24) : (fi += 1) off = skipRelTimeField(off) orelse return null;
        if (asciiEqlIgnoreCase(k, key)) return fields_off;
    }
    return null;
}

fn skipRelTimeField(off_in: usize) ?usize {
    var off = off_in;
    const rel_count = readU8(rt_payload, &off) orelse return null;
    var i: usize = 0;
    while (i < rel_count) : (i += 1) {
        off += 1; // i8 offset
        _ = readStr8(rt_payload, &off) orelse return null;
    }
    inline for (.{ 0, 1 }) |_| {
        const c = readU8(rt_payload, &off) orelse return null;
        var j: usize = 0;
        while (j < c) : (j += 1) {
            off += 1; // u8 cat
            _ = readStr16(rt_payload, &off) orelse return null;
        }
    }
    return off;
}

/// The future/past relative-time pattern for (locale, unit, style, plural cat),
/// falling back to the "other" category. Null when absent.
pub fn relativeTimePattern(locale: []const u8, unit_idx: u8, style_idx: u8, future: bool, cat: PluralCategory) ?[]const u8 {
    if (!ensureInit() or unit_idx > 7 or style_idx > 2) return null;
    var off = findRelTimeField(locale, @as(usize, unit_idx) * 3 + style_idx) orelse return null;
    // Skip rels.
    const rel_count = readU8(rt_payload, &off) orelse return null;
    var i: usize = 0;
    while (i < rel_count) : (i += 1) {
        off += 1;
        _ = readStr8(rt_payload, &off) orelse return null;
    }
    // future group first, then past.
    const fc = readU8(rt_payload, &off) orelse return null;
    const fut_off = off;
    var k: usize = 0;
    while (k < fc) : (k += 1) { // skip future group to reach past
        off += 1;
        _ = readStr16(rt_payload, &off) orelse return null;
    }
    const pc = readU8(rt_payload, &off) orelse return null;
    const past_off = off;
    const group_off = if (future) fut_off else past_off;
    const group_count = if (future) fc else pc;
    return readRtfPattern(group_off, group_count, @intFromEnum(cat)) orelse
        readRtfPattern(group_off, group_count, @intFromEnum(PluralCategory.other));
}

fn readRtfPattern(group_off: usize, count: u8, want_cat: u8) ?[]const u8 {
    var off = group_off;
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const cat = readU8(rt_payload, &off) orelse return null;
        const pat = readStr16(rt_payload, &off) orelse return null;
        if (cat == want_cat) return pat;
    }
    return null;
}

/// The relative-type string (e.g. "yesterday") for (locale, unit, style) at the
/// given integer offset (-1 / 0 / 1 …), used under numeric:"auto". Null absent.
pub fn relativeTypeString(locale: []const u8, unit_idx: u8, style_idx: u8, offset: i8) ?[]const u8 {
    if (!ensureInit() or unit_idx > 7 or style_idx > 2) return null;
    var off = findRelTimeField(locale, @as(usize, unit_idx) * 3 + style_idx) orelse return null;
    const rel_count = readU8(rt_payload, &off) orelse return null;
    var i: usize = 0;
    while (i < rel_count) : (i += 1) {
        const ro = readU8(rt_payload, &off) orelse return null;
        const str = readStr8(rt_payload, &off) orelse return null;
        if (@as(i8, @bitCast(ro)) == offset) return str;
    }
    return null;
}

// ── likely subtags (UTS #35 §4.3 Add / Remove Likely Subtags) ─────────────────

/// Parsed language / script / region subtags (each may be empty). `lang` is
/// lowercased, `script` title-cased, `region` uppercased to the CLDR canonical
/// form so candidate keys match the packed table.
pub const Subtags = struct {
    lang: []const u8 = "",
    script: []const u8 = "",
    region: []const u8 = "",
    lang_buf: [16]u8 = undefined,
    script_buf: [8]u8 = undefined,
    region_buf: [8]u8 = undefined,
};

/// Look up one likely-subtags key. On a hit, writes the value's
/// lang/script/region into `out` and returns true. The packed table is sorted
/// by key, but entries are variable-length so this is a linear scan; maximize
/// runs once per formatter over ~7.8k entries, acceptable without an index.
fn likelyLookup(key: []const u8, out: *Subtags) bool {
    if (likely_payload.len < 4) return false;
    const count = std.mem.readInt(u32, likely_payload[0..4], .little);
    var off: usize = 4;
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const klen = readU8(likely_payload, &off) orelse return false;
        const k = readBytes(likely_payload, &off, klen) orelse return false;
        const llen = readU8(likely_payload, &off) orelse return false;
        const lang = readBytes(likely_payload, &off, llen) orelse return false;
        const slen = readU8(likely_payload, &off) orelse return false;
        const script = readBytes(likely_payload, &off, slen) orelse return false;
        const rlen = readU8(likely_payload, &off) orelse return false;
        const region = readBytes(likely_payload, &off, rlen) orelse return false;
        if (asciiEqlIgnoreCase(k, key)) {
            const ln = @min(lang.len, out.lang_buf.len);
            @memcpy(out.lang_buf[0..ln], lang[0..ln]);
            out.lang = out.lang_buf[0..ln];
            const sn = @min(script.len, out.script_buf.len);
            @memcpy(out.script_buf[0..sn], script[0..sn]);
            out.script = out.script_buf[0..sn];
            const rn = @min(region.len, out.region_buf.len);
            @memcpy(out.region_buf[0..rn], region[0..rn]);
            out.region = out.region_buf[0..rn];
            return true;
        }
    }
    return false;
}

/// UTS #35 §3.2.1 languageAlias — look up a bare-language alias key (e.g.
/// `cmn` → zh, `sh` → sr-Latn). On a hit, writes the replacement's
/// lang/script/region into `out` and returns true. Requires the embedded blob
/// (`-Dintl=full`); returns false when absent or the key has no alias.
pub fn languageAlias(key: []const u8, out: *Subtags) bool {
    if (!ensureInit() or lang_alias_payload.len < 4) return false;
    const count = std.mem.readInt(u32, lang_alias_payload[0..4], .little);
    var off: usize = 4;
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const klen = readU8(lang_alias_payload, &off) orelse return false;
        const k = readBytes(lang_alias_payload, &off, klen) orelse return false;
        const llen = readU8(lang_alias_payload, &off) orelse return false;
        const lang = readBytes(lang_alias_payload, &off, llen) orelse return false;
        const slen = readU8(lang_alias_payload, &off) orelse return false;
        const script = readBytes(lang_alias_payload, &off, slen) orelse return false;
        const rlen = readU8(lang_alias_payload, &off) orelse return false;
        const region = readBytes(lang_alias_payload, &off, rlen) orelse return false;
        if (asciiEqlIgnoreCase(k, key)) {
            const ln = @min(lang.len, out.lang_buf.len);
            @memcpy(out.lang_buf[0..ln], lang[0..ln]);
            out.lang = out.lang_buf[0..ln];
            const sn = @min(script.len, out.script_buf.len);
            @memcpy(out.script_buf[0..sn], script[0..sn]);
            out.script = out.script_buf[0..sn];
            const rn = @min(region.len, out.region_buf.len);
            @memcpy(out.region_buf[0..rn], region[0..rn]);
            out.region = out.region_buf[0..rn];
            return true;
        }
    }
    return false;
}

/// UTS #35 §3.2.1 territoryAlias — a 1→1 region replacement (numeric → alpha,
/// or deprecated → current; e.g. "554" → "NZ", "UK" → "GB"). Returns a slice
/// into the embedded blob (static) or null. Requires the blob (`-Dintl=full`).
pub fn territoryAlias(key: []const u8) ?[]const u8 {
    if (!ensureInit() or territory_alias_payload.len < 4) return null;
    const count = std.mem.readInt(u32, territory_alias_payload[0..4], .little);
    var off: usize = 4;
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const klen = readU8(territory_alias_payload, &off) orelse return null;
        const k = readBytes(territory_alias_payload, &off, klen) orelse return null;
        const rlen = readU8(territory_alias_payload, &off) orelse return null;
        const region = readBytes(territory_alias_payload, &off, rlen) orelse return null;
        if (asciiEqlIgnoreCase(k, key)) return region;
    }
    return null;
}

/// UTS #35 §4.3 "Add Likely Subtags". Given parsed input subtags (any of which
/// may be empty, with an empty/`und` language treated as undefined), fill the
/// missing fields from the CLDR likelySubtags table and write the maximized
/// language / script / region into `out`. Returns false when no candidate key
/// matched (data absent, or a wholly unknown tag) — the caller keeps the input.
pub fn addLikelySubtags(in: Subtags, out: *Subtags) bool {
    if (!ensureInit() or likely_payload.len < 4) return false;

    // Empty or "und" language → the wildcard key prefix "und".
    const lang_known = in.lang.len != 0 and !asciiEqlIgnoreCase(in.lang, "und");
    var keybuf: [32]u8 = undefined;
    const base: []const u8 = if (lang_known) in.lang else "und";

    var hit: Subtags = .{};
    var matched = false;
    // Search order (ICU / §4.3): lang-script-region, lang-region, lang-script,
    // lang, und-script. First match wins.
    if (in.script.len > 0 and in.region.len > 0) {
        if (joinTag(&keybuf, base, in.script, in.region)) |k|
            if (likelyLookup(k, &hit)) {
                matched = true;
            };
    }
    if (!matched and in.region.len > 0) {
        if (joinTag(&keybuf, base, "", in.region)) |k|
            if (likelyLookup(k, &hit)) {
                matched = true;
            };
    }
    if (!matched and in.script.len > 0) {
        if (joinTag(&keybuf, base, in.script, "")) |k|
            if (likelyLookup(k, &hit)) {
                matched = true;
            };
    }
    if (!matched) {
        if (likelyLookup(base, &hit)) matched = true;
    }
    if (!matched and in.script.len > 0) {
        if (joinTag(&keybuf, "und", in.script, "")) |k|
            if (likelyLookup(k, &hit)) {
                matched = true;
            };
    }
    if (!matched) return false;

    // Keep present input fields; fill the missing ones from the match.
    out.* = .{};
    const rl = if (lang_known) in.lang else hit.lang;
    const rs = if (in.script.len > 0) in.script else hit.script;
    const rr = if (in.region.len > 0) in.region else hit.region;
    const ln = @min(rl.len, out.lang_buf.len);
    @memcpy(out.lang_buf[0..ln], rl[0..ln]);
    out.lang = out.lang_buf[0..ln];
    const sn = @min(rs.len, out.script_buf.len);
    @memcpy(out.script_buf[0..sn], rs[0..sn]);
    out.script = out.script_buf[0..sn];
    const rn = @min(rr.len, out.region_buf.len);
    @memcpy(out.region_buf[0..rn], rr[0..rn]);
    out.region = out.region_buf[0..rn];
    return true;
}

/// UTS #35 §4.3 "Remove Likely Subtags". First maximizes `in`, then finds the
/// shortest equivalent: tries (lang), (lang, region), (lang, script) and keeps
/// the first whose maximization equals the full maximization. Writes the
/// minimized subtags into `out`. Returns false when the input could not be
/// maximized (data absent) — the caller keeps the input.
pub fn removeLikelySubtags(in: Subtags, out: *Subtags) bool {
    var max: Subtags = .{};
    if (!addLikelySubtags(in, &max)) return false;

    // Candidate trials, in the §4.3 order: language only, then language+region,
    // then language+script. The first whose AddLikelySubtags matches `max` wins.

    // 1. language alone.
    if (maximizesTo(.{ .lang = max.lang }, max)) {
        copySubtags(out, max.lang, "", "");
        return true;
    }
    // 2. language + region.
    if (max.region.len > 0 and maximizesTo(.{ .lang = max.lang, .region = max.region }, max)) {
        copySubtags(out, max.lang, "", max.region);
        return true;
    }
    // 3. language + script.
    if (max.script.len > 0 and maximizesTo(.{ .lang = max.lang, .script = max.script }, max)) {
        copySubtags(out, max.lang, max.script, "");
        return true;
    }
    // Nothing shorter matched → the maximal form is already minimal.
    copySubtags(out, max.lang, max.script, max.region);
    return true;
}

/// True when AddLikelySubtags(candidate) yields exactly `target`.
fn maximizesTo(candidate: Subtags, target: Subtags) bool {
    var m: Subtags = .{};
    if (!addLikelySubtags(candidate, &m)) return false;
    return asciiEqlIgnoreCase(m.lang, target.lang) and
        asciiEqlIgnoreCase(m.script, target.script) and
        asciiEqlIgnoreCase(m.region, target.region);
}

fn copySubtags(out: *Subtags, lang: []const u8, script: []const u8, region: []const u8) void {
    out.* = .{};
    const ln = @min(lang.len, out.lang_buf.len);
    @memcpy(out.lang_buf[0..ln], lang[0..ln]);
    out.lang = out.lang_buf[0..ln];
    const sn = @min(script.len, out.script_buf.len);
    @memcpy(out.script_buf[0..sn], script[0..sn]);
    out.script = out.script_buf[0..sn];
    const rn = @min(region.len, out.region_buf.len);
    @memcpy(out.region_buf[0..rn], region[0..rn]);
    out.region = out.region_buf[0..rn];
}

// ── interval formats (Intl.DateTimeFormat.formatRange) ───────────────────────

fn findIntervalLocale(key: []const u8) ?usize {
    if (iv_payload.len < 4) return null;
    const count = std.mem.readInt(u32, iv_payload[0..4], .little);
    var off: usize = 4;
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const klen = readU8(iv_payload, &off) orelse return null;
        const k = readBytes(iv_payload, &off, klen) orelse return null;
        const data_off = off; // at the fallback str16
        _ = readStr16(iv_payload, &off) orelse return null; // fallback
        const ec = readU32(iv_payload, &off) orelse return null;
        var e: u32 = 0;
        while (e < ec) : (e += 1) {
            const slen = readU8(iv_payload, &off) orelse return null;
            _ = readBytes(iv_payload, &off, slen) orelse return null; // skeleton
            _ = readU8(iv_payload, &off) orelse return null; // field
            _ = readStr16(iv_payload, &off) orelse return null; // pattern
        }
        if (asciiEqlIgnoreCase(k, key)) return data_off;
    }
    return null;
}

/// The interval pattern for (locale, skeleton, greatest-difference field), or
/// null when that combination is absent. The pattern duplicates the field so the
/// range renderer can split it (yMMMd.d = "MMM d – d, y").
pub fn intervalPattern(locale: []const u8, skeleton: []const u8, field: u8) ?[]const u8 {
    if (!ensureInit()) return null;
    var off = withCandidates(locale, findIntervalLocale) orelse return null;
    _ = readStr16(iv_payload, &off) orelse return null; // fallback
    const ec = readU32(iv_payload, &off) orelse return null;
    var e: u32 = 0;
    while (e < ec) : (e += 1) {
        const slen = readU8(iv_payload, &off) orelse return null;
        const sk = readBytes(iv_payload, &off, slen) orelse return null;
        const fc = readU8(iv_payload, &off) orelse return null;
        const pat = readStr16(iv_payload, &off) orelse return null;
        if (fc == field and std.mem.eql(u8, sk, skeleton)) return pat;
    }
    return null;
}

/// The locale's intervalFormatFallback ("{0} – {1}"), or null without data.
pub fn intervalFallback(locale: []const u8) ?[]const u8 {
    if (!ensureInit()) return null;
    var off = withCandidates(locale, findIntervalLocale) orelse return null;
    return readStr16(iv_payload, &off);
}

fn readU16(buf: []const u8, off: *usize) ?u16 {
    if (off.* + 2 > buf.len) return null;
    const v = std.mem.readInt(u16, buf[off.*..][0..2], .little);
    off.* += 2;
    return v;
}

fn readU8(buf: []const u8, off: *usize) ?u8 {
    if (off.* + 1 > buf.len) return null;
    const v = buf[off.*];
    off.* += 1;
    return v;
}
fn readU32(buf: []const u8, off: *usize) ?u32 {
    if (off.* + 4 > buf.len) return null;
    const v = std.mem.readInt(u32, buf[off.*..][0..4], .little);
    off.* += 4;
    return v;
}
fn readBytes(buf: []const u8, off: *usize, len: usize) ?[]const u8 {
    if (off.* + len > buf.len) return null;
    const s = buf[off.* .. off.* + len];
    off.* += len;
    return s;
}
fn readStr8(buf: []const u8, off: *usize) ?[]const u8 {
    const len = readU8(buf, off) orelse return null;
    return readBytes(buf, off, len);
}
fn readStr16(buf: []const u8, off: *usize) ?[]const u8 {
    if (off.* + 2 > buf.len) return null;
    const len = std.mem.readInt(u16, buf[off.*..][0..2], .little);
    off.* += 2;
    return readBytes(buf, off, len);
}

// ── dates (gregorian names + patterns) ───────────────────────────────────────

/// Per-locale gregorian date data from the CLDR `dates` section. All slices
/// point into the embedded blob (static lifetime).
pub const DateData = struct {
    months_wide: [12][]const u8,
    months_abbr: [12][]const u8,
    days_wide: [7][]const u8, // sun..sat
    days_abbr: [7][]const u8,
    am: []const u8,
    pm: []const u8,
    era_bc: []const u8,
    era_ad: []const u8,
    date_full: []const u8,
    date_long: []const u8,
    date_medium: []const u8,
    date_short: []const u8,
    time_full: []const u8,
    time_long: []const u8,
    time_medium: []const u8,
    time_short: []const u8,
    dt_full: []const u8,
    dt_long: []const u8,
    dt_medium: []const u8,
    dt_short: []const u8,
};

/// Look up gregorian date data for `locale` (candidate fallback), or null.
pub fn dateData(locale: []const u8) ?DateData {
    if (!ensureInit()) return null;
    if (dates_payload.len < 4) return null;

    var lang_buf: [16]u8 = undefined;
    var script_buf: [8]u8 = undefined;
    var region_buf: [8]u8 = undefined;
    const parts = splitTag(locale, &lang_buf, &script_buf, &region_buf);
    if (parts.lang.len == 0) return null;

    var cand_buf: [32]u8 = undefined;
    if (parts.script.len > 0 and parts.region.len > 0)
        if (joinTag(&cand_buf, parts.lang, parts.script, parts.region)) |k|
            if (findDate(k)) |d| return d;
    if (parts.region.len > 0)
        if (joinTag(&cand_buf, parts.lang, "", parts.region)) |k|
            if (findDate(k)) |d| return d;
    if (parts.script.len > 0)
        if (joinTag(&cand_buf, parts.lang, parts.script, "")) |k|
            if (findDate(k)) |d| return d;
    return findDate(parts.lang);
}

fn findDate(key: []const u8) ?DateData {
    const count = std.mem.readInt(u32, dates_payload[0..4], .little);
    var off: usize = 4;
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const klen = readU8(dates_payload, &off) orelse return null;
        const k = readBytes(dates_payload, &off, klen) orelse return null;
        var d: DateData = undefined;
        var ok = true;
        for (&d.months_wide) |*m| m.* = readStr8(dates_payload, &off) orelse blkfail(&ok);
        for (&d.months_abbr) |*m| m.* = readStr8(dates_payload, &off) orelse blkfail(&ok);
        for (&d.days_wide) |*x| x.* = readStr8(dates_payload, &off) orelse blkfail(&ok);
        for (&d.days_abbr) |*x| x.* = readStr8(dates_payload, &off) orelse blkfail(&ok);
        d.am = readStr8(dates_payload, &off) orelse blkfail(&ok);
        d.pm = readStr8(dates_payload, &off) orelse blkfail(&ok);
        d.era_bc = readStr8(dates_payload, &off) orelse blkfail(&ok);
        d.era_ad = readStr8(dates_payload, &off) orelse blkfail(&ok);
        d.date_full = readStr16(dates_payload, &off) orelse blkfail(&ok);
        d.date_long = readStr16(dates_payload, &off) orelse blkfail(&ok);
        d.date_medium = readStr16(dates_payload, &off) orelse blkfail(&ok);
        d.date_short = readStr16(dates_payload, &off) orelse blkfail(&ok);
        d.time_full = readStr16(dates_payload, &off) orelse blkfail(&ok);
        d.time_long = readStr16(dates_payload, &off) orelse blkfail(&ok);
        d.time_medium = readStr16(dates_payload, &off) orelse blkfail(&ok);
        d.time_short = readStr16(dates_payload, &off) orelse blkfail(&ok);
        d.dt_full = readStr16(dates_payload, &off) orelse blkfail(&ok);
        d.dt_long = readStr16(dates_payload, &off) orelse blkfail(&ok);
        d.dt_medium = readStr16(dates_payload, &off) orelse blkfail(&ok);
        d.dt_short = readStr16(dates_payload, &off) orelse blkfail(&ok);
        if (!ok) return null;
        if (asciiEqlIgnoreCase(k, key)) return d;
    }
    return null;
}

/// Mark a parse as failed and return an empty slice (used in the field loop).
fn blkfail(ok: *bool) []const u8 {
    ok.* = false;
    return "";
}

// ── display names (language / region / script / currency) ─────────────────────

pub const DisplayKind = enum(u8) { language = 0, region = 1, script = 2, currency = 3 };

/// CLDR display name for `code` of the given `kind` in `locale`, or null. The
/// 4 tables per locale are stored in DisplayKind order; codes are matched
/// case-insensitively (the builtin canonicalises case first).
pub fn displayName(locale: []const u8, kind: DisplayKind, code: []const u8) ?[]const u8 {
    if (!ensureInit()) return null;
    if (display_payload.len < 4) return null;

    var lang_buf: [16]u8 = undefined;
    var script_buf: [8]u8 = undefined;
    var region_buf: [8]u8 = undefined;
    const parts = splitTag(locale, &lang_buf, &script_buf, &region_buf);
    if (parts.lang.len == 0) return null;

    var cand_buf: [32]u8 = undefined;
    if (parts.script.len > 0 and parts.region.len > 0)
        if (joinTag(&cand_buf, parts.lang, parts.script, parts.region)) |k|
            if (findDisplay(k, kind, code)) |nm| return nm;
    if (parts.region.len > 0)
        if (joinTag(&cand_buf, parts.lang, "", parts.region)) |k|
            if (findDisplay(k, kind, code)) |nm| return nm;
    if (parts.script.len > 0)
        if (joinTag(&cand_buf, parts.lang, parts.script, "")) |k|
            if (findDisplay(k, kind, code)) |nm| return nm;
    return findDisplay(parts.lang, kind, code);
}

fn findDisplay(key: []const u8, kind: DisplayKind, code: []const u8) ?[]const u8 {
    const count = std.mem.readInt(u32, display_payload[0..4], .little);
    var off: usize = 4;
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const klen = readU8(display_payload, &off) orelse return null;
        const k = readBytes(display_payload, &off, klen) orelse return null;
        const match = asciiEqlIgnoreCase(k, key);
        // Walk the 4 tables; capture the wanted one's name on a key match.
        var found: ?[]const u8 = null;
        var t: u8 = 0;
        while (t < 4) : (t += 1) {
            const tcount = readU32(display_payload, &off) orelse return null;
            var j: u32 = 0;
            while (j < tcount) : (j += 1) {
                const clen = readU8(display_payload, &off) orelse return null;
                const c = readBytes(display_payload, &off, clen) orelse return null;
                if (off + 2 > display_payload.len) return null;
                const nlen = std.mem.readInt(u16, display_payload[off..][0..2], .little);
                off += 2;
                const nm = readBytes(display_payload, &off, nlen) orelse return null;
                if (match and t == @intFromEnum(kind) and asciiEqlIgnoreCase(c, code)) found = nm;
            }
        }
        if (match) return found;
    }
    return null;
}

// ── small helpers ────────────────────────────────────────────────────────────

const TagParts = struct { lang: []const u8, script: []const u8, region: []const u8 };

/// Split a BCP 47 tag into language / script / region subtags, lowercasing the
/// language and uppercasing the region (script title-case) so candidate keys
/// match CLDR's canonical form. Extensions and variants are ignored.
///
/// When the tag carries no script, the UTS #35 §4.3 likely script is inferred
/// from the language (+region) and written into `script_buf`, so the candidate
/// chains below reach script-keyed CLDR data (e.g. zh-TW → zh-Hant). This only
/// affects *data resolution*, never a user-visible tag. The inferred script is
/// skipped if the likelySubtags data is absent (stub / off, or a future build).
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

    // §4.3 Add Likely Subtags — fill the script when absent so script-keyed
    // CLDR sections (zh-Hant, sr-Cyrl, …) are reachable from a region-only tag.
    if (script.len == 0 and lang.len != 0) {
        var max: Subtags = .{};
        if (addLikelySubtags(.{ .lang = lang, .script = "", .region = region }, &max) and
            max.script.len > 0 and max.script.len <= script_buf.len)
        {
            @memcpy(script_buf[0..max.script.len], max.script);
            script = script_buf[0..max.script.len];
        }
    }

    return .{ .lang = lang, .script = script, .region = region };
}

/// §11.1.2 [[hourCycle12]] — the locale's 12-hour cycle. Per CLDR supplemental
/// timeData, JP is the only region whose 12-hour clock prefers K (0-11 → "h11");
/// every other region uses h (1-12 → "h12"). The tag's region is used directly,
/// else derived from its likely region via addLikelySubtags.
pub fn hourCycle12(locale: []const u8) []const u8 {
    var lbuf: [16]u8 = undefined;
    var sbuf: [8]u8 = undefined;
    var rbuf: [8]u8 = undefined;
    const parts = splitTag(locale, &lbuf, &sbuf, &rbuf);
    var region = parts.region;
    if (region.len == 0 and parts.lang.len != 0) {
        var max: Subtags = .{};
        if (addLikelySubtags(.{ .lang = parts.lang, .script = parts.script }, &max)) region = max.region;
    }
    return if (std.ascii.eqlIgnoreCase(region, "JP")) "h11" else "h12";
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

/// UTS #35 §4.3 Add Likely Subtags, materialised once per formatter as the
/// "data locale": the resolved tag with its likely script filled in when the
/// tag carries none (e.g. `en` → `en-Latn`, `zh-TW` → `zh-Hant-TW`), so the
/// per-`format()` CLDR candidate chains can resolve script-keyed sections
/// without re-scanning the ~7.8k-entry likelySubtags table on every call.
///
/// The result is written into `buf` (no allocation here; the caller owns a
/// copy) as `lang(-script)(-region)` from `splitTag`'s canonicalised parts.
/// Returns the original `locale` unchanged when no script can be inferred
/// (data absent at stub/off, or a wholly unknown tag) or when `buf` is too
/// small — both cases are safe: the per-format lookup then re-derives the
/// script via `splitTag` exactly as before, so behaviour never changes, only
/// the (rare) hot-path scan cost returns. Idempotent: a tag that already
/// carries its script splits to the same parts and round-trips identically.
pub fn maximizeForData(locale: []const u8, buf: []u8) []const u8 {
    var lang_buf: [16]u8 = undefined;
    var script_buf: [8]u8 = undefined;
    var region_buf: [8]u8 = undefined;
    const parts = splitTag(locale, &lang_buf, &script_buf, &region_buf);
    // No script was inferred (or the language was unparsable) → keep the input
    // tag verbatim so the caller's stored data-locale equals the resolved tag.
    if (parts.script.len == 0) return locale;
    return joinTag(buf, parts.lang, parts.script, parts.region) orelse locale;
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

// ── concurrency regression test ──────────────────────────────────────────────

const testing = std.testing;

fn hammerNumberingSystem(out: *bool) void {
    // The digit-substitution read path the `ar-EG` Arabic-Indic numerals
    // fixture depends on: a half-published `ns_payload` returns null here and
    // the formatter silently falls back to Latin digits (a wrong result).
    out.* = numberingSystemDigitBase("arab") != null;
}

// Hammer the lazy init from many first-callers at once, re-opening the race
// window each round, and assert every caller agrees with a post-join read. This
// guards the atomic one-shot (`initOnce`) against a regression to unsynchronized
// init. The race is timing-dependent, so this is a best-effort net, not a
// deterministic reproducer — the authoritative gate is a threaded test262
// intl402 sweep.
test "cldr: concurrent first-callers see a consistent numbering-system table" {
    const rounds = 64;
    const n_threads = 8;
    var round: usize = 0;
    while (round < rounds) : (round += 1) {
        // Force a cold state so the CAS election runs again this round.
        init_state.store(@intFromEnum(InitState.uninit), .seq_cst);
        init_ok = false;
        var threads: [n_threads]std.Thread = undefined;
        var results: [n_threads]bool = undefined;
        for (0..n_threads) |i|
            threads[i] = try std.Thread.spawn(.{}, hammerNumberingSystem, .{&results[i]});
        for (0..n_threads) |i| threads[i].join();
        const want = numberingSystemDigitBase("arab") != null;
        for (results) |r| try testing.expectEqual(want, r);
        // When the CLDR blob is linked, "arab" must resolve — a null here would
        // mean a caller read the empty payload set.
        if (available) try testing.expect(want);
    }
}
