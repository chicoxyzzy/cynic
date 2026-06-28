//! Pack Unicode CLDR-JSON data into `vendor/cldr/cynic_cldr.bin` (CYCL v2).
//!
//! Normal workflow (mirrors the tzdata pipeline):
//!
//!     tools/fetch-cldr.sh              # download CLDR-JSON → vendor/cldr/json/
//!     zig build pack-cldr              # this tool → vendor/cldr/cynic_cldr.bin
//!
//! Only `-Dintl=full` embeds the blob; off/stub builds never link it.
//!
//! Container format (little-endian index; payloads are section-defined):
//!
//!     magic "CYCL"
//!     u8  version = 2
//!     u8  reserved[3]
//!     u32 section_count
//!     repeated section_count times (the directory):
//!         u8  kind            # SectionKind
//!         u8  reserved[3]
//!         u32 off             # offset from blob start to the payload
//!         u32 len
//!     then concatenated section payloads.
//!
//! Plural sections (kind 1 = cardinal, kind 2 = ordinal) carry CLDR plural
//! rule *conditions* (UTS #35 Part 3 syntax, sample suffixes stripped). The
//! runtime parses + evaluates them — see `src/runtime/cldr.zig`. Payload:
//!
//!     u32 locale_count
//!     repeated (sorted by key bytes):
//!         u8  key_len; u8 key[key_len]      # CLDR locale key, e.g. "en", "pt-PT"
//!         u8  rule_count                    # non-"other" categories only
//!         repeated rule_count times:
//!             u8  category                  # 0=zero 1=one 2=two 3=few 4=many
//!             u16 cond_len; u8 cond[cond_len]

const std = @import("std");

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
};

/// RTF units in fixed order (year … second); each packs 3 styles (long /
/// short / narrow) → CLDR fields `<unit>` / `<unit>-short` / `<unit>-narrow`.
const rtf_units = [8][]const u8{ "year", "quarter", "month", "week", "day", "hour", "minute", "second" };

/// Plural-category index shared with `cldr.zig`'s PluralCategory
/// (zero=0 … other=5). Unlike `Category.fromName`, "other" maps to 5 — the
/// currency long-name / unitPattern tables key the catch-all explicitly.
fn pluralCatIndex(name: []const u8) ?u8 {
    if (std.mem.eql(u8, name, "zero")) return 0;
    if (std.mem.eql(u8, name, "one")) return 1;
    if (std.mem.eql(u8, name, "two")) return 2;
    if (std.mem.eql(u8, name, "few")) return 3;
    if (std.mem.eql(u8, name, "many")) return 4;
    if (std.mem.eql(u8, name, "other")) return 5;
    return null;
}

/// CLDR "modern" coverage tier, base-language locales (plus the few
/// script-primary ones CLDR treats as principal). Derived from
/// cldr-core/coverageLevels.json (effectiveCoverageLevels == "modern",
/// language-only keys); region variants fall back to their base at runtime.
/// "und" (root) is excluded. Keep sorted by the packer's own sort, not here.
const modern_locales = [_][]const u8{
    "af", "ak", "am",  "ar",  "as",  "az",      "ba",      "be",
    "bg", "bn", "bs",  "ca",  "chr", "cs",      "cv",      "cy",
    "da", "de", "dsb", "el",  "en",  "es",      "et",      "eu",
    "fa", "fi", "fil", "fr",  "ga",  "gd",      "gl",      "gu",
    "ha", "he", "hi",  "hr",  "hsb", "ht",      "hu",      "hy",
    "id", "ig", "is",  "it",  "ja",  "jv",      "ka",      "kk",
    "km", "kn", "ko",  "kok", "ky",  "lo",      "lt",      "lv",
    "mk", "ml", "mn",  "mr",  "ms",  "my",      "nb",      "ne",
    "nl", "nn", "no",  "or",  "pa",  "pcm",     "pl",      "ps",
    "pt", "qu", "rm",  "ro",  "ru",  "sd",      "shn",     "si",
    "sk", "sl", "so",  "sq",  "sr",  "sv",      "sw",      "ta",
    "te", "th", "ti",  "tk",  "tr",  "uk",      "ur",      "uz",
    "vi", "yo", "yue", "zh",  "zu",  "sr-Latn", "zh-Hans", "zh-Hant",
};

const Category = enum(u8) {
    zero = 0,
    one = 1,
    two = 2,
    few = 3,
    many = 4,
    // "other" is the implicit catch-all and is never stored.
    fn fromName(name: []const u8) ?Category {
        if (std.mem.eql(u8, name, "zero")) return .zero;
        if (std.mem.eql(u8, name, "one")) return .one;
        if (std.mem.eql(u8, name, "two")) return .two;
        if (std.mem.eql(u8, name, "few")) return .few;
        if (std.mem.eql(u8, name, "many")) return .many;
        return null; // "other" or unknown
    }
};

const Rule = struct {
    category: Category,
    cond: []const u8,
};

const LocaleRules = struct {
    key: []const u8,
    rules: []Rule,
    fn lessThan(_: void, a: LocaleRules, b: LocaleRules) bool {
        return std.mem.lessThan(u8, a.key, b.key);
    }
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    var json_root: []const u8 = "vendor/cldr/json";
    var out_path: []const u8 = "vendor/cldr/cynic_cldr.bin";

    var args_iter = init.minimal.args.iterate();
    _ = args_iter.next(); // argv[0]
    while (args_iter.next()) |a| {
        if (std.mem.eql(u8, a, "--cldr-json")) {
            json_root = args_iter.next() orelse fatal("missing value for --cldr-json", .{});
        } else if (std.mem.eql(u8, a, "-o")) {
            out_path = args_iter.next() orelse fatal("missing value for -o", .{});
        } else if (std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "--help")) {
            try std.Io.File.stdout().writeStreamingAll(io,
                \\usage: pack_cldr [--cldr-json <dir>] [-o <out.bin>]
                \\
                \\Reads CLDR-JSON under <dir> (default vendor/cldr/json) and writes the
                \\CYCL blob (default vendor/cldr/cynic_cldr.bin).
                \\
            );
            return;
        } else {
            fatal("unknown argument: {s}", .{a});
        }
    }

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const cardinal = try loadPlurals(arena, io, json_root, "plurals.json", "plurals-type-cardinal");
    const ordinal = try loadPlurals(arena, io, json_root, "ordinals.json", "plurals-type-ordinal");
    const ns_table = try loadNumberingSystems(arena, io, json_root);
    const numbers = try loadNumbers(arena, io, json_root, ns_table);
    const dates = try loadDates(arena, io, json_root);
    const display = try loadDisplayNames(arena, io, json_root);
    const currencies = try loadCurrencies(arena, io, json_root);
    const likely = try loadLikelySubtags(arena, io, json_root);
    const list_patterns = try loadListPatterns(arena, io, json_root);
    const relative_time = try loadRelativeTime(arena, io, json_root);
    const compact = try loadCompact(arena, io, json_root);
    const units = try loadUnits(arena, io, json_root);
    const lang_aliases = try loadLanguageAliases(arena, io, json_root);
    const territory_aliases = try loadTerritoryAliases(arena, io, json_root);

    const blob = try pack(allocator, cardinal, ordinal, numbers, ns_table, dates, display, currencies, likely, list_patterns, relative_time, compact, units, lang_aliases, territory_aliases);
    defer allocator.free(blob);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = out_path, .data = blob });

    var buf: [540]u8 = undefined;
    const msg = try std.fmt.bufPrint(&buf, "pack_cldr: wrote {s} ({d} bytes) — cardinal {d}, ordinal {d}, numbers {d}, ns {d}, dates {d}, display {d}, currencies {d}, likely {d}, list_patterns {d}, relative_time {d}, compact {d}, units {d}, lang_aliases {d}, territory_aliases {d}\n", .{ out_path, blob.len, cardinal.len, ordinal.len, numbers.len, ns_table.len, dates.len, display.len, currencies.locales.len, likely.len, list_patterns.len, relative_time.len, compact.len, units.len, lang_aliases.len, territory_aliases.len });
    try std.Io.File.stdout().writeStreamingAll(io, msg);
}

/// Load one plural-rule supplemental file into a sorted slice of LocaleRules.
fn loadPlurals(
    arena: std.mem.Allocator,
    io: std.Io,
    json_root: []const u8,
    filename: []const u8,
    section_key: []const u8,
) ![]LocaleRules {
    const path = try std.fmt.allocPrint(arena, "{s}/cldr-core/supplemental/{s}", .{ json_root, filename });
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(8 * 1024 * 1024)) catch
        fatal("cannot read {s} (run tools/fetch-cldr.sh first)", .{path});

    const root = try std.json.parseFromSliceLeaky(std.json.Value, arena, bytes, .{});
    const supp = (root.object.get("supplemental") orelse fatal("no .supplemental in {s}", .{filename})).object;
    const table = (supp.get(section_key) orelse fatal("no {s} in {s}", .{ section_key, filename })).object;

    var out: std.ArrayListUnmanaged(LocaleRules) = .empty;
    var it = table.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        const cats = entry.value_ptr.*.object;

        var rules: std.ArrayListUnmanaged(Rule) = .empty;
        var cit = cats.iterator();
        while (cit.next()) |c| {
            const rk = c.key_ptr.*; // "pluralRule-count-one"
            const prefix = "pluralRule-count-";
            if (!std.mem.startsWith(u8, rk, prefix)) continue;
            const cat = Category.fromName(rk[prefix.len..]) orelse continue; // skip "other"
            const cond = stripSamples(c.value_ptr.*.string);
            if (cond.len == 0) continue;
            try rules.append(arena, .{ .category = cat, .cond = cond });
        }
        // Canonical evaluation order: zero, one, two, few, many.
        std.sort.block(Rule, rules.items, {}, struct {
            fn lt(_: void, a: Rule, b: Rule) bool {
                return @intFromEnum(a.category) < @intFromEnum(b.category);
            }
        }.lt);
        try out.append(arena, .{ .key = key, .rules = rules.items });
    }

    std.sort.block(LocaleRules, out.items, {}, LocaleRules.lessThan);
    return out.items;
}

/// Strip the `@integer …` / `@decimal …` sample suffix and trim a rule string
/// down to its bare condition. "other" rules are pure samples → empty result.
fn stripSamples(rule: []const u8) []const u8 {
    const at = std.mem.indexOfScalar(u8, rule, '@') orelse rule.len;
    return std.mem.trim(u8, rule[0..at], " \t");
}

fn pack(
    gpa: std.mem.Allocator,
    cardinal: []LocaleRules,
    ordinal: []LocaleRules,
    numbers: []NumberLocale,
    ns_table: []NumberingSystem,
    dates: []DateLocale,
    display: []DisplayLocale,
    currencies: CurrencyData,
    likely: []LikelyEntry,
    list_patterns: []ListPatternLocale,
    relative_time: []RelativeTimeLocale,
    compact: []CompactLocale,
    units: []UnitsLocale,
    lang_aliases: []LangAliasEntry,
    territory_aliases: []TerritoryAliasEntry,
) ![]u8 {
    var payloads: std.ArrayListUnmanaged(u8) = .empty;
    defer payloads.deinit(gpa);

    const SectionDir = struct { kind: SectionKind, off: u32, len: u32 };
    var dirs: [15]SectionDir = undefined;

    const card_start: u32 = @intCast(payloads.items.len);
    try writePluralPayload(gpa, &payloads, cardinal);
    dirs[0] = .{ .kind = .plural_cardinal, .off = card_start, .len = @as(u32, @intCast(payloads.items.len)) - card_start };

    const ord_start: u32 = @intCast(payloads.items.len);
    try writePluralPayload(gpa, &payloads, ordinal);
    dirs[1] = .{ .kind = .plural_ordinal, .off = ord_start, .len = @as(u32, @intCast(payloads.items.len)) - ord_start };

    const num_start: u32 = @intCast(payloads.items.len);
    try writeNumbersPayload(gpa, &payloads, numbers);
    dirs[2] = .{ .kind = .numbers, .off = num_start, .len = @as(u32, @intCast(payloads.items.len)) - num_start };

    const ns_start: u32 = @intCast(payloads.items.len);
    try writeNumberingSystemsPayload(gpa, &payloads, ns_table);
    dirs[3] = .{ .kind = .numbering_systems, .off = ns_start, .len = @as(u32, @intCast(payloads.items.len)) - ns_start };

    const dates_start: u32 = @intCast(payloads.items.len);
    try writeDatesPayload(gpa, &payloads, dates);
    dirs[4] = .{ .kind = .dates, .off = dates_start, .len = @as(u32, @intCast(payloads.items.len)) - dates_start };

    const disp_start: u32 = @intCast(payloads.items.len);
    try writeDisplayNamesPayload(gpa, &payloads, display);
    dirs[5] = .{ .kind = .display_names, .off = disp_start, .len = @as(u32, @intCast(payloads.items.len)) - disp_start };

    const cur_start: u32 = @intCast(payloads.items.len);
    try writeCurrenciesPayload(gpa, &payloads, currencies);
    dirs[6] = .{ .kind = .currencies, .off = cur_start, .len = @as(u32, @intCast(payloads.items.len)) - cur_start };

    const curname_start: u32 = @intCast(payloads.items.len);
    try writeCurrencyNamesPayload(gpa, &payloads, currencies);
    dirs[7] = .{ .kind = .currency_names, .off = curname_start, .len = @as(u32, @intCast(payloads.items.len)) - curname_start };

    const likely_start: u32 = @intCast(payloads.items.len);
    try writeLikelySubtagsPayload(gpa, &payloads, likely);
    dirs[8] = .{ .kind = .likely_subtags, .off = likely_start, .len = @as(u32, @intCast(payloads.items.len)) - likely_start };

    const lp_start: u32 = @intCast(payloads.items.len);
    try writeListPatternsPayload(gpa, &payloads, list_patterns);
    dirs[9] = .{ .kind = .list_patterns, .off = lp_start, .len = @as(u32, @intCast(payloads.items.len)) - lp_start };

    const rt_start: u32 = @intCast(payloads.items.len);
    try writeRelativeTimePayload(gpa, &payloads, relative_time);
    dirs[10] = .{ .kind = .relative_time, .off = rt_start, .len = @as(u32, @intCast(payloads.items.len)) - rt_start };

    const cp_start: u32 = @intCast(payloads.items.len);
    try writeCompactPayload(gpa, &payloads, compact);
    dirs[11] = .{ .kind = .compact, .off = cp_start, .len = @as(u32, @intCast(payloads.items.len)) - cp_start };

    const un_start: u32 = @intCast(payloads.items.len);
    try writeUnitsPayload(gpa, &payloads, units);
    dirs[12] = .{ .kind = .units, .off = un_start, .len = @as(u32, @intCast(payloads.items.len)) - un_start };

    const la_start: u32 = @intCast(payloads.items.len);
    try writeLanguageAliasPayload(gpa, &payloads, lang_aliases);
    dirs[13] = .{ .kind = .language_aliases, .off = la_start, .len = @as(u32, @intCast(payloads.items.len)) - la_start };

    const ta_start: u32 = @intCast(payloads.items.len);
    try writeTerritoryAliasPayload(gpa, &payloads, territory_aliases);
    dirs[14] = .{ .kind = .territory_aliases, .off = ta_start, .len = @as(u32, @intCast(payloads.items.len)) - ta_start };

    // Header + directory size, so we can fix up payload offsets to be absolute.
    const header_len: u32 = 4 + 1 + 3 + 4; // magic, ver, reserved, section_count
    const dir_entry_len: u32 = 1 + 3 + 4 + 4;
    const dir_len: u32 = dir_entry_len * dirs.len;
    const base: u32 = header_len + dir_len;

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, "CYCL");
    try out.append(gpa, 2); // version
    try out.appendSlice(gpa, &.{ 0, 0, 0 }); // reserved
    try appendU32(gpa, &out, dirs.len);
    for (dirs) |d| {
        try out.append(gpa, @intFromEnum(d.kind));
        try out.appendSlice(gpa, &.{ 0, 0, 0 });
        try appendU32(gpa, &out, base + d.off);
        try appendU32(gpa, &out, d.len);
    }
    try out.appendSlice(gpa, payloads.items);
    return out.toOwnedSlice(gpa);
}

// ── numbers (symbols + patterns) ─────────────────────────────────────────────

const NumberLocale = struct {
    key: []const u8,
    ns: []const u8, // default numbering system id
    digit_base: u32, // code point of that system's digit 0
    decimal: []const u8,
    group: []const u8,
    minus: []const u8,
    plus: []const u8,
    percent: []const u8,
    infinity: []const u8,
    nan: []const u8,
    dec_pattern: []const u8,
    pct_pattern: []const u8,
    min_group: u8, // minimumGroupingDigits (1 for most, 2 for pl/es/…)
    fn lessThan(_: void, a: NumberLocale, b: NumberLocale) bool {
        return std.mem.lessThan(u8, a.key, b.key);
    }
};

const NumberingSystem = struct {
    id: []const u8,
    digit_base: u32,
    fn lessThan(_: void, a: NumberingSystem, b: NumberingSystem) bool {
        return std.mem.lessThan(u8, a.id, b.id);
    }
};

/// numberingSystems.json → (id, digit-0 code point) for every `numeric` system.
fn loadNumberingSystems(arena: std.mem.Allocator, io: std.Io, json_root: []const u8) ![]NumberingSystem {
    const path = try std.fmt.allocPrint(arena, "{s}/cldr-core/supplemental/numberingSystems.json", .{json_root});
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(1024 * 1024)) catch
        fatal("cannot read {s} (run tools/fetch-cldr.sh first)", .{path});
    const root = try std.json.parseFromSliceLeaky(std.json.Value, arena, bytes, .{});
    const ns = (root.object.get("supplemental") orelse fatal("no supplemental", .{})).object
        .get("numberingSystems").?.object;

    var out: std.ArrayListUnmanaged(NumberingSystem) = .empty;
    var it = ns.iterator();
    while (it.next()) |e| {
        const obj = e.value_ptr.*.object;
        const typ = if (obj.get("_type")) |t| t.string else continue;
        if (!std.mem.eql(u8, typ, "numeric")) continue; // skip algorithmic systems
        const digits = if (obj.get("_digits")) |d| d.string else continue;
        const base = std.unicode.utf8Decode(digits[0..(std.unicode.utf8ByteSequenceLength(digits[0]) catch continue)]) catch continue;
        try out.append(arena, .{ .id = e.key_ptr.*, .digit_base = base });
    }
    std.sort.block(NumberingSystem, out.items, {}, NumberingSystem.lessThan);
    return out.items;
}

fn nsDigitBase(table: []NumberingSystem, id: []const u8) u32 {
    for (table) |n| {
        if (std.mem.eql(u8, n.id, id)) return n.digit_base;
    }
    return '0'; // latn fallback
}

// ── likely subtags (UTS #35 §4.3 Add/Remove Likely Subtags) ──────────────────

const LikelyEntry = struct {
    key: []const u8, // lookup key, canonical CLDR form: lang | und (-script)? (-region)?
    lang: []const u8, // value language subtag
    script: []const u8, // value script subtag (4 alpha)
    region: []const u8, // value region subtag (2 alpha / 3 digit)
    fn lessThan(_: void, a: LikelyEntry, b: LikelyEntry) bool {
        return std.mem.lessThan(u8, a.key, b.key);
    }
};

/// likelySubtags.json → sorted (key, lang, script, region). The full CLDR table
/// (every `und-…` source plus language-keyed sources) so maximize works on any
/// requested tag. Sorted by key for a runtime binary search.
fn loadLikelySubtags(arena: std.mem.Allocator, io: std.Io, json_root: []const u8) ![]LikelyEntry {
    const path = try std.fmt.allocPrint(arena, "{s}/cldr-core/supplemental/likelySubtags.json", .{json_root});
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(4 * 1024 * 1024)) catch
        fatal("cannot read {s} (run tools/fetch-cldr.sh first)", .{path});
    const root = try std.json.parseFromSliceLeaky(std.json.Value, arena, bytes, .{});
    const tbl = (root.object.get("supplemental") orelse fatal("no supplemental", .{})).object
        .get("likelySubtags").?.object;

    var out: std.ArrayListUnmanaged(LikelyEntry) = .empty;
    var it = tbl.iterator();
    while (it.next()) |e| {
        const v = subtagsOf(e.value_ptr.*.string);
        try out.append(arena, .{ .key = e.key_ptr.*, .lang = v.lang, .script = v.script, .region = v.region });
    }
    std.sort.block(LikelyEntry, out.items, {}, LikelyEntry.lessThan);
    return out.items;
}

const Subtags = struct { lang: []const u8, script: []const u8, region: []const u8 };

/// Split a CLDR locale id into language / script / region (variants/extensions
/// dropped — likelySubtags values never carry them).
fn subtagsOf(tag: []const u8) Subtags {
    var lang: []const u8 = "";
    var script: []const u8 = "";
    var region: []const u8 = "";
    var i: usize = 0;
    var first = true;
    while (i < tag.len) {
        var j = i;
        while (j < tag.len and tag[j] != '-' and tag[j] != '_') j += 1;
        const sub = tag[i..j];
        if (first) {
            lang = sub;
            first = false;
        } else if (sub.len == 4 and isAllAlpha(sub) and script.len == 0) {
            script = sub;
        } else if (((sub.len == 2 and isAllAlpha(sub)) or (sub.len == 3 and isAllDigit(sub))) and region.len == 0) {
            region = sub;
            break;
        }
        i = j + 1;
    }
    return .{ .lang = lang, .script = script, .region = region };
}

fn writeLikelySubtagsPayload(gpa: std.mem.Allocator, buf: *std.ArrayListUnmanaged(u8), table: []LikelyEntry) !void {
    try appendU32(gpa, buf, table.len);
    for (table) |e| {
        try appendStr8(gpa, buf, e.key);
        try appendStr8(gpa, buf, e.lang);
        try appendStr8(gpa, buf, e.script);
        try appendStr8(gpa, buf, e.region);
    }
}

// ── language aliases (UTS #35 §3.2.1 languageAlias) ──────────────────────────

/// One languageAlias entry with a single-subtag key (a bare language). The
/// replacement is split into language / script / region so the runtime can
/// apply the field-aware merge (an input field wins; the replacement only fills
/// a gap). Multi-subtag keys (e.g. `sgn-GR`, `no-bok`) are skipped here.
const LangAliasEntry = struct {
    key: []const u8, // input language subtag (lowercase)
    lang: []const u8, // replacement language
    script: []const u8, // replacement script (4 alpha) or ""
    region: []const u8, // replacement region (2 alpha / 3 digit) or ""
    fn lessThan(_: void, a: LangAliasEntry, b: LangAliasEntry) bool {
        return std.mem.lessThan(u8, a.key, b.key);
    }
};

/// aliases.json → sorted (key, repl-lang, repl-script, repl-region) for the
/// bare-language keys. Sorted by key for a runtime binary search.
fn loadLanguageAliases(arena: std.mem.Allocator, io: std.Io, json_root: []const u8) ![]LangAliasEntry {
    const path = try std.fmt.allocPrint(arena, "{s}/cldr-core/supplemental/aliases.json", .{json_root});
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(4 * 1024 * 1024)) catch
        fatal("cannot read {s} (run tools/fetch-cldr.sh first)", .{path});
    const root = try std.json.parseFromSliceLeaky(std.json.Value, arena, bytes, .{});
    const tbl = (root.object.get("supplemental") orelse fatal("no supplemental", .{})).object
        .get("metadata").?.object.get("alias").?.object
        .get("languageAlias").?.object;

    var out: std.ArrayListUnmanaged(LangAliasEntry) = .empty;
    var it = tbl.iterator();
    while (it.next()) |e| {
        const key = e.key_ptr.*;
        // Skip multi-subtag keys (full-tag replacements) — handled separately.
        if (std.mem.indexOfScalar(u8, key, '-') != null) continue;
        const repl = e.value_ptr.*.object.get("_replacement").?.string;
        const v = subtagsOf(repl);
        try out.append(arena, .{ .key = key, .lang = v.lang, .script = v.script, .region = v.region });
    }
    std.sort.block(LangAliasEntry, out.items, {}, LangAliasEntry.lessThan);
    return out.items;
}

fn writeLanguageAliasPayload(gpa: std.mem.Allocator, buf: *std.ArrayListUnmanaged(u8), table: []LangAliasEntry) !void {
    try appendU32(gpa, buf, table.len);
    for (table) |e| {
        try appendStr8(gpa, buf, e.key);
        try appendStr8(gpa, buf, e.lang);
        try appendStr8(gpa, buf, e.script);
        try appendStr8(gpa, buf, e.region);
    }
}

// ── territory aliases (UTS #35 §3.2.1 territoryAlias) ────────────────────────

/// A region replacement: a single region (numeric→alpha, deprecated→current)
/// or a space-separated 1→many list (e.g. SU → "RU AM …"), which the runtime
/// disambiguates with likelySubtags.
const TerritoryAliasEntry = struct {
    key: []const u8, // input region subtag (numeric or alpha)
    region: []const u8, // replacement (single, or space-separated list)
    fn lessThan(_: void, a: TerritoryAliasEntry, b: TerritoryAliasEntry) bool {
        return std.mem.lessThan(u8, a.key, b.key);
    }
};

fn loadTerritoryAliases(arena: std.mem.Allocator, io: std.Io, json_root: []const u8) ![]TerritoryAliasEntry {
    const path = try std.fmt.allocPrint(arena, "{s}/cldr-core/supplemental/aliases.json", .{json_root});
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(4 * 1024 * 1024)) catch
        fatal("cannot read {s} (run tools/fetch-cldr.sh first)", .{path});
    const root = try std.json.parseFromSliceLeaky(std.json.Value, arena, bytes, .{});
    const tbl = (root.object.get("supplemental") orelse fatal("no supplemental", .{})).object
        .get("metadata").?.object.get("alias").?.object
        .get("territoryAlias").?.object;

    var out: std.ArrayListUnmanaged(TerritoryAliasEntry) = .empty;
    var it = tbl.iterator();
    while (it.next()) |e| {
        const repl = e.value_ptr.*.object.get("_replacement").?.string;
        try out.append(arena, .{ .key = e.key_ptr.*, .region = repl });
    }
    std.sort.block(TerritoryAliasEntry, out.items, {}, TerritoryAliasEntry.lessThan);
    return out.items;
}

fn writeTerritoryAliasPayload(gpa: std.mem.Allocator, buf: *std.ArrayListUnmanaged(u8), table: []TerritoryAliasEntry) !void {
    try appendU32(gpa, buf, table.len);
    for (table) |e| {
        try appendStr8(gpa, buf, e.key);
        try appendStr8(gpa, buf, e.region);
    }
}

// ── list patterns (Intl.ListFormat) ──────────────────────────────────────────

/// One {2,start,middle,end} template group for a (type, style) pair.
const PatternSet = struct { two: []const u8, start: []const u8, middle: []const u8, end: []const u8 };
/// 9 sets per locale, indexed `type*3 + style`: type 0=conjunction 1=disjunction
/// 2=unit; style 0=long 1=short 2=narrow.
const ListPatternLocale = struct {
    key: []const u8,
    sets: [9]PatternSet,
    fn lessThan(_: void, a: ListPatternLocale, b: ListPatternLocale) bool {
        return std.mem.lessThan(u8, a.key, b.key);
    }
};

/// The CLDR `listPattern-type-*` key for a (type, style) pair, matching the
/// `type*3 + style` index order.
const list_pattern_keys = [9][]const u8{
    "listPattern-type-standard", "listPattern-type-standard-short", "listPattern-type-standard-narrow",
    "listPattern-type-or",       "listPattern-type-or-short",       "listPattern-type-or-narrow",
    "listPattern-type-unit",     "listPattern-type-unit-short",     "listPattern-type-unit-narrow",
};

/// cldr-misc-full/main/<loc>/listPatterns.json → the 9 template groups per
/// modern locale. Missing keys fall back to the standard set; absent locales
/// are skipped (runtime falls back to the language candidate, then en).
fn loadListPatterns(arena: std.mem.Allocator, io: std.Io, json_root: []const u8) ![]ListPatternLocale {
    var out: std.ArrayListUnmanaged(ListPatternLocale) = .empty;
    for (modern_locales) |loc| {
        const path = try std.fmt.allocPrint(arena, "{s}/cldr-misc-full/main/{s}/listPatterns.json", .{ json_root, loc });
        const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(1024 * 1024)) catch continue;
        const root = std.json.parseFromSliceLeaky(std.json.Value, arena, bytes, .{}) catch continue;
        var mit = root.object.get("main").?.object.iterator();
        const lp = (mit.next() orelse continue).value_ptr.*.object.get("listPatterns").?.object;
        var sets: [9]PatternSet = undefined;
        for (list_pattern_keys, 0..) |k, i| {
            const o = if (lp.get(k)) |v| v.object else lp.get("listPattern-type-standard").?.object;
            sets[i] = .{
                .two = strField(o, "2", "{0}, {1}"),
                .start = strField(o, "start", "{0}, {1}"),
                .middle = strField(o, "middle", "{0}, {1}"),
                .end = strField(o, "end", "{0}, {1}"),
            };
        }
        try out.append(arena, .{ .key = loc, .sets = sets });
    }
    std.sort.block(ListPatternLocale, out.items, {}, ListPatternLocale.lessThan);
    return out.items;
}

fn writeListPatternsPayload(gpa: std.mem.Allocator, buf: *std.ArrayListUnmanaged(u8), locales: []ListPatternLocale) !void {
    try appendU32(gpa, buf, locales.len);
    for (locales) |l| {
        try appendStr8(gpa, buf, l.key);
        for (l.sets) |s| {
            try appendStr16(gpa, buf, s.two);
            try appendStr16(gpa, buf, s.start);
            try appendStr16(gpa, buf, s.middle);
            try appendStr16(gpa, buf, s.end);
        }
    }
}

// ── measurement units (Intl.NumberFormat style:"unit") ───────────────────────

/// The ECMA-402 §6.5.1 sanctioned single-unit identifiers, mapped to their CLDR
/// category-prefixed keys. The JS `unit` option uses the simple name; CLDR keys
/// them by category, so the packer stores patterns under the simple name.
const sanctioned_units = [_]struct { simple: []const u8, key: []const u8 }{
    .{ .simple = "acre", .key = "area-acre" },
    .{ .simple = "bit", .key = "digital-bit" },
    .{ .simple = "byte", .key = "digital-byte" },
    .{ .simple = "celsius", .key = "temperature-celsius" },
    .{ .simple = "centimeter", .key = "length-centimeter" },
    .{ .simple = "day", .key = "duration-day" },
    .{ .simple = "degree", .key = "angle-degree" },
    .{ .simple = "fahrenheit", .key = "temperature-fahrenheit" },
    .{ .simple = "fluid-ounce", .key = "volume-fluid-ounce" },
    .{ .simple = "foot", .key = "length-foot" },
    .{ .simple = "gallon", .key = "volume-gallon" },
    .{ .simple = "gigabit", .key = "digital-gigabit" },
    .{ .simple = "gigabyte", .key = "digital-gigabyte" },
    .{ .simple = "gram", .key = "mass-gram" },
    .{ .simple = "hectare", .key = "area-hectare" },
    .{ .simple = "hour", .key = "duration-hour" },
    .{ .simple = "inch", .key = "length-inch" },
    .{ .simple = "kilobit", .key = "digital-kilobit" },
    .{ .simple = "kilobyte", .key = "digital-kilobyte" },
    .{ .simple = "kilogram", .key = "mass-kilogram" },
    .{ .simple = "kilometer", .key = "length-kilometer" },
    .{ .simple = "liter", .key = "volume-liter" },
    .{ .simple = "megabit", .key = "digital-megabit" },
    .{ .simple = "megabyte", .key = "digital-megabyte" },
    .{ .simple = "meter", .key = "length-meter" },
    .{ .simple = "microsecond", .key = "duration-microsecond" },
    .{ .simple = "mile", .key = "length-mile" },
    .{ .simple = "mile-scandinavian", .key = "length-mile-scandinavian" },
    .{ .simple = "milliliter", .key = "volume-milliliter" },
    .{ .simple = "millimeter", .key = "length-millimeter" },
    .{ .simple = "millisecond", .key = "duration-millisecond" },
    .{ .simple = "minute", .key = "duration-minute" },
    .{ .simple = "month", .key = "duration-month" },
    .{ .simple = "nanosecond", .key = "duration-nanosecond" },
    .{ .simple = "ounce", .key = "mass-ounce" },
    .{ .simple = "percent", .key = "concentr-percent" },
    .{ .simple = "petabyte", .key = "digital-petabyte" },
    .{ .simple = "pound", .key = "mass-pound" },
    .{ .simple = "second", .key = "duration-second" },
    .{ .simple = "stone", .key = "mass-stone" },
    .{ .simple = "terabit", .key = "digital-terabit" },
    .{ .simple = "terabyte", .key = "digital-terabyte" },
    .{ .simple = "week", .key = "duration-week" },
    .{ .simple = "yard", .key = "length-yard" },
    .{ .simple = "year", .key = "duration-year" },
};

const UnitPat = struct { cat: u8, pat: []const u8 };
/// One unit's patterns for one style: the plural unitPatterns + perUnitPattern
/// (the divisor side of a compound "X-per-Y") + displayName (fallback).
const UnitStyle = struct {
    pats: []UnitPat,
    per: []const u8,
    display: []const u8,
};
const UnitEntry = struct { simple: []const u8, styles: [3]UnitStyle };
/// All sanctioned-unit data for one locale + the "per" compound pattern per style.
const UnitsLocale = struct {
    key: []const u8,
    units: []UnitEntry,
    compound_per: [3][]const u8,
    fn lessThan(_: void, a: UnitsLocale, b: UnitsLocale) bool {
        return std.mem.lessThan(u8, a.key, b.key);
    }
};

const unit_styles = [_][]const u8{ "long", "short", "narrow" };

fn loadUnitStyle(arena: std.mem.Allocator, units: std.json.ObjectMap, style: []const u8, cldr_key: []const u8) UnitStyle {
    const s = if (units.get(style)) |v| v.object else return .{ .pats = &.{}, .per = "", .display = "" };
    const u = if (s.get(cldr_key)) |v| v.object else return .{ .pats = &.{}, .per = "", .display = "" };
    var pats: std.ArrayListUnmanaged(UnitPat) = .empty;
    var per: []const u8 = "";
    var display: []const u8 = "";
    var it = u.iterator();
    while (it.next()) |e| {
        if (e.value_ptr.* != .string) continue;
        if (std.mem.startsWith(u8, e.key_ptr.*, "unitPattern-count-")) {
            const cat = pluralCatIndex(e.key_ptr.*["unitPattern-count-".len..]) orelse continue;
            pats.append(arena, .{ .cat = cat, .pat = e.value_ptr.*.string }) catch {};
        } else if (std.mem.eql(u8, e.key_ptr.*, "perUnitPattern")) {
            per = e.value_ptr.*.string;
        } else if (std.mem.eql(u8, e.key_ptr.*, "displayName")) {
            display = e.value_ptr.*.string;
        }
    }
    return .{ .pats = pats.items, .per = per, .display = display };
}

fn loadUnits(arena: std.mem.Allocator, io: std.Io, json_root: []const u8) ![]UnitsLocale {
    var out: std.ArrayListUnmanaged(UnitsLocale) = .empty;
    for (modern_locales) |loc| {
        const path = try std.fmt.allocPrint(arena, "{s}/cldr-units-full/main/{s}/units.json", .{ json_root, loc });
        const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(8 * 1024 * 1024)) catch continue;
        const root = std.json.parseFromSliceLeaky(std.json.Value, arena, bytes, .{}) catch continue;
        var mit = root.object.get("main").?.object.iterator();
        const units = (mit.next() orelse continue).value_ptr.*.object.get("units").?.object;

        var entries: std.ArrayListUnmanaged(UnitEntry) = .empty;
        for (sanctioned_units) |su| {
            var styles: [3]UnitStyle = undefined;
            for (unit_styles, 0..) |st, i| styles[i] = loadUnitStyle(arena, units, st, su.key);
            try entries.append(arena, .{ .simple = su.simple, .styles = styles });
        }
        var compound_per: [3][]const u8 = .{ "", "", "" };
        for (unit_styles, 0..) |st, i| {
            const s = if (units.get(st)) |v| v.object else continue;
            const p = if (s.get("per")) |v| v.object else continue;
            if (p.get("compoundUnitPattern")) |v| {
                if (v == .string) compound_per[i] = v.string;
            }
        }
        try out.append(arena, .{ .key = loc, .units = entries.items, .compound_per = compound_per });
    }
    std.sort.block(UnitsLocale, out.items, {}, UnitsLocale.lessThan);
    return out.items;
}

fn writeUnitsPayload(gpa: std.mem.Allocator, buf: *std.ArrayListUnmanaged(u8), locales: []UnitsLocale) !void {
    try appendU32(gpa, buf, locales.len);
    for (locales) |l| {
        try appendStr8(gpa, buf, l.key);
        for (l.compound_per) |cp| try appendStr16(gpa, buf, cp);
        try appendU32(gpa, buf, l.units.len);
        for (l.units) |u| {
            try appendStr8(gpa, buf, u.simple);
            for (u.styles) |st| {
                try appendStr16(gpa, buf, st.display);
                try appendStr16(gpa, buf, st.per);
                try buf.append(gpa, @intCast(st.pats.len));
                for (st.pats) |p| {
                    try buf.append(gpa, p.cat);
                    try appendStr16(gpa, buf, p.pat);
                }
            }
        }
    }
}

// ── compact notation (Intl.NumberFormat notation:"compact") ───────────────────

const CompactEntry = struct { power: u8, cat: u8, pat: []const u8 };
/// short + long compact patterns for one locale (each entry: 10^power × plural).
const CompactLocale = struct {
    key: []const u8,
    short: []CompactEntry,
    long: []CompactEntry,
    fn lessThan(_: void, a: CompactLocale, b: CompactLocale) bool {
        return std.mem.lessThan(u8, a.key, b.key);
    }
};

fn loadCompactStyle(arena: std.mem.Allocator, dec: std.json.ObjectMap, style: []const u8) []CompactEntry {
    const s = if (dec.get(style)) |v| v.object else return &.{};
    const df = if (s.get("decimalFormat")) |v| v.object else return &.{};
    var out: std.ArrayListUnmanaged(CompactEntry) = .empty;
    var it = df.iterator();
    while (it.next()) |e| {
        // key form: "<power>-count-<cat>", e.g. "1000-count-one".
        const dashc = std.mem.indexOf(u8, e.key_ptr.*, "-count-") orelse continue;
        const power_str = e.key_ptr.*[0..dashc];
        const cat_str = e.key_ptr.*[dashc + 7 ..];
        if (power_str.len < 4) continue; // 10^3 = "1000" minimum
        const power: u8 = @intCast(power_str.len - 1); // digits-1 = exponent
        const cat = pluralCatIndex(cat_str) orelse continue;
        if (e.value_ptr.* != .string) continue;
        out.append(arena, .{ .power = power, .cat = cat, .pat = e.value_ptr.*.string }) catch {};
    }
    return out.items;
}

fn loadCompact(arena: std.mem.Allocator, io: std.Io, json_root: []const u8) ![]CompactLocale {
    var out: std.ArrayListUnmanaged(CompactLocale) = .empty;
    for (modern_locales) |loc| {
        const path = try std.fmt.allocPrint(arena, "{s}/cldr-numbers-full/main/{s}/numbers.json", .{ json_root, loc });
        const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(4 * 1024 * 1024)) catch continue;
        const root = std.json.parseFromSliceLeaky(std.json.Value, arena, bytes, .{}) catch continue;
        var mit = root.object.get("main").?.object.iterator();
        const n = (mit.next() orelse continue).value_ptr.*.object.get("numbers").?.object;
        const default_ns = if (n.get("defaultNumberingSystem")) |d| d.string else "latn";
        const dec_key = std.fmt.allocPrint(arena, "decimalFormats-numberSystem-{s}", .{default_ns}) catch continue;
        const dec = if (n.get(dec_key)) |v| v.object else continue;
        try out.append(arena, .{
            .key = loc,
            .short = loadCompactStyle(arena, dec, "short"),
            .long = loadCompactStyle(arena, dec, "long"),
        });
    }
    std.sort.block(CompactLocale, out.items, {}, CompactLocale.lessThan);
    return out.items;
}

fn writeCompactStyle(gpa: std.mem.Allocator, buf: *std.ArrayListUnmanaged(u8), entries: []CompactEntry) !void {
    try appendU32(gpa, buf, entries.len);
    for (entries) |e| {
        try buf.append(gpa, e.power);
        try buf.append(gpa, e.cat);
        try appendStr16(gpa, buf, e.pat);
    }
}

fn writeCompactPayload(gpa: std.mem.Allocator, buf: *std.ArrayListUnmanaged(u8), locales: []CompactLocale) !void {
    try appendU32(gpa, buf, locales.len);
    for (locales) |l| {
        try appendStr8(gpa, buf, l.key);
        try writeCompactStyle(gpa, buf, l.short);
        try writeCompactStyle(gpa, buf, l.long);
    }
}

// ── relative time (Intl.RelativeTimeFormat) ───────────────────────────────────

const RtfPattern = struct { cat: u8, pat: []const u8 };
const RtfRel = struct { offset: i8, str: []const u8 };
/// One (unit, style) field's relative strings + future/past plural patterns.
const RtfField = struct { rels: []RtfRel, future: []RtfPattern, past: []RtfPattern };
/// 24 fields per locale, indexed `unit*3 + style` (unit: year…second; style:
/// long / short / narrow).
const RelativeTimeLocale = struct {
    key: []const u8,
    fields: [24]RtfField,
    fn lessThan(_: void, a: RelativeTimeLocale, b: RelativeTimeLocale) bool {
        return std.mem.lessThan(u8, a.key, b.key);
    }
};

fn loadRtfPatterns(arena: std.mem.Allocator, obj: std.json.ObjectMap, key: []const u8) []RtfPattern {
    const grp = if (obj.get(key)) |v| v.object else return &.{};
    var out: std.ArrayListUnmanaged(RtfPattern) = .empty;
    var it = grp.iterator();
    while (it.next()) |e| {
        const prefix = "relativeTimePattern-count-";
        if (!std.mem.startsWith(u8, e.key_ptr.*, prefix)) continue;
        const cat = pluralCatIndex(e.key_ptr.*[prefix.len..]) orelse continue;
        if (e.value_ptr.* != .string) continue;
        out.append(arena, .{ .cat = cat, .pat = e.value_ptr.*.string }) catch {};
    }
    return out.items;
}

fn loadRelativeTime(arena: std.mem.Allocator, io: std.Io, json_root: []const u8) ![]RelativeTimeLocale {
    var out: std.ArrayListUnmanaged(RelativeTimeLocale) = .empty;
    for (modern_locales) |loc| {
        const path = try std.fmt.allocPrint(arena, "{s}/cldr-dates-full/main/{s}/dateFields.json", .{ json_root, loc });
        const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(2 * 1024 * 1024)) catch continue;
        const root = std.json.parseFromSliceLeaky(std.json.Value, arena, bytes, .{}) catch continue;
        var mit = root.object.get("main").?.object.iterator();
        const fields = (mit.next() orelse continue).value_ptr.*.object
            .get("dates").?.object.get("fields").?.object;

        var locale_fields: [24]RtfField = undefined;
        for (rtf_units, 0..) |unit, ui| {
            for ([_][]const u8{ "", "-short", "-narrow" }, 0..) |suffix, si| {
                const fkey = try std.fmt.allocPrint(arena, "{s}{s}", .{ unit, suffix });
                const f = if (fields.get(fkey)) |v| v.object else {
                    locale_fields[ui * 3 + si] = .{ .rels = &.{}, .future = &.{}, .past = &.{} };
                    continue;
                };
                var rels: std.ArrayListUnmanaged(RtfRel) = .empty;
                var rit = f.iterator();
                while (rit.next()) |e| {
                    const prefix = "relative-type-";
                    if (!std.mem.startsWith(u8, e.key_ptr.*, prefix)) continue;
                    const off = std.fmt.parseInt(i8, e.key_ptr.*[prefix.len..], 10) catch continue;
                    if (e.value_ptr.* != .string) continue;
                    rels.append(arena, .{ .offset = off, .str = e.value_ptr.*.string }) catch {};
                }
                locale_fields[ui * 3 + si] = .{
                    .rels = rels.items,
                    .future = loadRtfPatterns(arena, f, "relativeTime-type-future"),
                    .past = loadRtfPatterns(arena, f, "relativeTime-type-past"),
                };
            }
        }
        try out.append(arena, .{ .key = loc, .fields = locale_fields });
    }
    std.sort.block(RelativeTimeLocale, out.items, {}, RelativeTimeLocale.lessThan);
    return out.items;
}

fn writeRelativeTimePayload(gpa: std.mem.Allocator, buf: *std.ArrayListUnmanaged(u8), locales: []RelativeTimeLocale) !void {
    try appendU32(gpa, buf, locales.len);
    for (locales) |l| {
        try appendStr8(gpa, buf, l.key);
        for (l.fields) |f| {
            try buf.append(gpa, @intCast(f.rels.len));
            for (f.rels) |r| {
                try buf.append(gpa, @bitCast(r.offset));
                try appendStr8(gpa, buf, r.str);
            }
            try buf.append(gpa, @intCast(f.future.len));
            for (f.future) |p| {
                try buf.append(gpa, p.cat);
                try appendStr16(gpa, buf, p.pat);
            }
            try buf.append(gpa, @intCast(f.past.len));
            for (f.past) |p| {
                try buf.append(gpa, p.cat);
                try appendStr16(gpa, buf, p.pat);
            }
        }
    }
}

/// Per modern locale: default numbering system + its symbols and decimal/percent
/// patterns. Missing locales are skipped (they fall back at runtime).
fn loadNumbers(arena: std.mem.Allocator, io: std.Io, json_root: []const u8, ns_table: []NumberingSystem) ![]NumberLocale {
    var out: std.ArrayListUnmanaged(NumberLocale) = .empty;
    for (modern_locales) |loc| {
        const path = try std.fmt.allocPrint(arena, "{s}/cldr-numbers-full/main/{s}/numbers.json", .{ json_root, loc });
        const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(4 * 1024 * 1024)) catch continue;
        const root = std.json.parseFromSliceLeaky(std.json.Value, arena, bytes, .{}) catch continue;
        const main_obj = root.object.get("main").?.object;
        // main has one key (the locale id, possibly normalised); take the first.
        var mit = main_obj.iterator();
        const loc_entry = mit.next() orelse continue;
        const n = loc_entry.value_ptr.*.object.get("numbers").?.object;
        const default_ns = if (n.get("defaultNumberingSystem")) |d| d.string else "latn";

        const sym_key = try std.fmt.allocPrint(arena, "symbols-numberSystem-{s}", .{default_ns});
        const dec_key = try std.fmt.allocPrint(arena, "decimalFormats-numberSystem-{s}", .{default_ns});
        const pct_key = try std.fmt.allocPrint(arena, "percentFormats-numberSystem-{s}", .{default_ns});
        const syms = (n.get(sym_key) orelse continue).object;

        try out.append(arena, .{
            .key = loc,
            .ns = try arena.dupe(u8, default_ns),
            .digit_base = nsDigitBase(ns_table, default_ns),
            .decimal = strField(syms, "decimal", "."),
            .group = strField(syms, "group", ","),
            .minus = strField(syms, "minusSign", "-"),
            .plus = strField(syms, "plusSign", "+"),
            .percent = strField(syms, "percentSign", "%"),
            .infinity = strField(syms, "infinity", "∞"),
            .nan = strField(syms, "nan", "NaN"),
            .dec_pattern = if (n.get(dec_key)) |d| strField(d.object, "standard", "#,##0.###") else "#,##0.###",
            .pct_pattern = if (n.get(pct_key)) |p| strField(p.object, "standard", "#,##0%") else "#,##0%",
            .min_group = if (n.get("minimumGroupingDigits")) |m| (std.fmt.parseInt(u8, m.string, 10) catch 1) else 1,
        });
    }
    std.sort.block(NumberLocale, out.items, {}, NumberLocale.lessThan);
    return out.items;
}

fn strField(obj: std.json.ObjectMap, key: []const u8, dflt: []const u8) []const u8 {
    return if (obj.get(key)) |v| (if (v == .string) v.string else dflt) else dflt;
}

fn writeNumbersPayload(gpa: std.mem.Allocator, buf: *std.ArrayListUnmanaged(u8), locales: []NumberLocale) !void {
    try appendU32(gpa, buf, locales.len);
    for (locales) |l| {
        try appendStr8(gpa, buf, l.key);
        try appendStr8(gpa, buf, l.ns);
        try appendU32(gpa, buf, l.digit_base);
        try appendStr8(gpa, buf, l.decimal);
        try appendStr8(gpa, buf, l.group);
        try appendStr8(gpa, buf, l.minus);
        try appendStr8(gpa, buf, l.plus);
        try appendStr8(gpa, buf, l.percent);
        try appendStr8(gpa, buf, l.infinity);
        try appendStr8(gpa, buf, l.nan);
        try appendStr16(gpa, buf, l.dec_pattern);
        try appendStr16(gpa, buf, l.pct_pattern);
        try buf.append(gpa, l.min_group);
    }
}

// ── currencies (symbols + patterns + fraction digits) ─────────────────────────

const CurSym = struct { code: [3]u8, symbol: []const u8, narrow: []const u8 };
/// A `unitPattern-count-{cat}` ("{0} {1}") for the currencyDisplay:"name" style.
const UnitPattern = struct { cat: u8, pattern: []const u8 };
/// A plural-keyed long name (`displayName-count-{cat}`) for one currency.
const PluralName = struct { cat: u8, name: []const u8 };
const CurrencyNames = struct { code: [3]u8, forms: []PluralName };
const CurrencyLocale = struct {
    key: []const u8,
    std_pattern: []const u8, // currencyFormats `standard`, e.g. "¤#,##0.00"
    acct_pattern: []const u8, // currencyFormats `accounting`
    unit_patterns: []UnitPattern, // currencyDisplay:"name" wrappers
    syms: []CurSym,
    names: []CurrencyNames, // per-currency plural long names (written separately)
    fn lessThan(_: void, a: CurrencyLocale, b: CurrencyLocale) bool {
        return std.mem.lessThan(u8, a.key, b.key);
    }
};
const CurFraction = struct { code: [3]u8, digits: u8 };
const CurrencyData = struct { fractions: []CurFraction, locales: []CurrencyLocale };

/// cldr-core/supplemental/currencyData.json `fractions` → per-currency minor
/// units (§ cCurrencyDigits). Only non-default (≠2) entries are stored; the
/// runtime defaults to 2. `DEFAULT` / non-3-letter keys are skipped.
fn loadCurrencyFractions(arena: std.mem.Allocator, io: std.Io, json_root: []const u8) ![]CurFraction {
    const path = try std.fmt.allocPrint(arena, "{s}/cldr-core/supplemental/currencyData.json", .{json_root});
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(4 * 1024 * 1024)) catch
        return &.{};
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena, bytes, .{}) catch return &.{};
    const fr = ((root.object.get("supplemental") orelse return &.{}).object
        .get("currencyData") orelse return &.{}).object
        .get("fractions") orelse return &.{};
    var out: std.ArrayListUnmanaged(CurFraction) = .empty;
    var it = fr.object.iterator();
    while (it.next()) |e| {
        const code = e.key_ptr.*;
        if (code.len != 3 or !isUpper3(code)) continue; // skip DEFAULT etc.
        const digs = if (e.value_ptr.*.object.get("_digits")) |d| d.string else continue;
        const n = std.fmt.parseInt(u8, digs, 10) catch continue;
        if (n == 2) continue; // default
        out.append(arena, .{ .code = code[0..3].*, .digits = n }) catch return &.{};
    }
    return out.items;
}

fn isUpper3(s: []const u8) bool {
    for (s) |c| if (c < 'A' or c > 'Z') return false;
    return true;
}

/// Per modern locale: currency display patterns + localized symbols +
/// currencyDisplay:"name" data — the `unitPattern-count-*` wrappers
/// (numbers.json) and the per-currency `displayName-count-*` plural long names
/// (currencies.json). Symbols are packed only where they differ from the ISO
/// code; long names only where they differ from the already-packed singular
/// `displayName` (the runtime falls back: count → other → singular → code), so
/// the table stays a delta over the display-names section.
fn loadCurrencies(arena: std.mem.Allocator, io: std.Io, json_root: []const u8) !CurrencyData {
    const fractions = try loadCurrencyFractions(arena, io, json_root);
    var out: std.ArrayListUnmanaged(CurrencyLocale) = .empty;
    for (modern_locales) |loc| {
        const npath = try std.fmt.allocPrint(arena, "{s}/cldr-numbers-full/main/{s}/numbers.json", .{ json_root, loc });
        const nbytes = std.Io.Dir.cwd().readFileAlloc(io, npath, arena, .limited(4 * 1024 * 1024)) catch continue;
        const nroot = std.json.parseFromSliceLeaky(std.json.Value, arena, nbytes, .{}) catch continue;
        var nit = nroot.object.get("main").?.object.iterator();
        const n = (nit.next() orelse continue).value_ptr.*.object.get("numbers").?.object;
        const default_ns = if (n.get("defaultNumberingSystem")) |d| d.string else "latn";
        const cf_key = try std.fmt.allocPrint(arena, "currencyFormats-numberSystem-{s}", .{default_ns});
        const cf = if (n.get(cf_key)) |c| c.object else continue;
        const std_pat = strField(cf, "standard", "¤#,##0.00");
        const acct_pat = strField(cf, "accounting", std_pat);

        // unitPattern-count-{cat}: the "{0} {1}" wrappers for the "name" style.
        var unit_patterns: std.ArrayListUnmanaged(UnitPattern) = .empty;
        var cfit = cf.iterator();
        while (cfit.next()) |e| {
            const k = e.key_ptr.*;
            const prefix = "unitPattern-count-";
            if (!std.mem.startsWith(u8, k, prefix)) continue;
            if (e.value_ptr.* != .string) continue;
            const cat = pluralCatIndex(k[prefix.len..]) orelse continue;
            unit_patterns.append(arena, .{ .cat = cat, .pattern = try arena.dupe(u8, e.value_ptr.*.string) }) catch {};
        }
        sortByCat(UnitPattern, unit_patterns.items);

        var syms: std.ArrayListUnmanaged(CurSym) = .empty;
        var names: std.ArrayListUnmanaged(CurrencyNames) = .empty;
        const cpath = try std.fmt.allocPrint(arena, "{s}/cldr-numbers-full/main/{s}/currencies.json", .{ json_root, loc });
        if (std.Io.Dir.cwd().readFileAlloc(io, cpath, arena, .limited(8 * 1024 * 1024))) |cbytes| {
            if (std.json.parseFromSliceLeaky(std.json.Value, arena, cbytes, .{})) |croot| {
                var cit = croot.object.get("main").?.object.iterator();
                const curs = (cit.next() orelse continue).value_ptr.*.object
                    .get("numbers").?.object.get("currencies").?.object;
                var it = curs.iterator();
                while (it.next()) |e| {
                    const code = e.key_ptr.*;
                    if (code.len != 3 or !isUpper3(code)) continue;
                    const o = e.value_ptr.*.object;
                    if (o.get("symbol")) |sv| {
                        const sym = sv.string;
                        if (!std.mem.eql(u8, sym, code)) { // symbol == code → runtime fallback
                            const narrow_v = o.get("symbol-alt-narrow");
                            const narrow = if (narrow_v) |nv| nv.string else "";
                            syms.append(arena, .{
                                .code = code[0..3].*,
                                .symbol = try arena.dupe(u8, sym),
                                .narrow = if (narrow.len > 0 and !std.mem.eql(u8, narrow, sym)) try arena.dupe(u8, narrow) else "",
                            }) catch {};
                        }
                    }
                    // Plural long names, delta-encoded over the singular display
                    // name + the "other" anchor so the table stays minimal.
                    const singular = if (o.get("displayName")) |d| d.string else "";
                    const other = if (o.get("displayName-count-other")) |d| d.string else singular;
                    var forms: std.ArrayListUnmanaged(PluralName) = .empty;
                    const cats = [_][]const u8{ "zero", "one", "two", "few", "many", "other" };
                    for (cats) |cn| {
                        const fk = try std.fmt.allocPrint(arena, "displayName-count-{s}", .{cn});
                        const v = if (o.get(fk)) |d| d.string else continue;
                        const idx = pluralCatIndex(cn).?;
                        // Store "other" only when it differs from the singular;
                        // store any other category only when it differs from
                        // "other" (the within-table fallback target).
                        const keep = if (idx == 5) !std.mem.eql(u8, v, singular) else !std.mem.eql(u8, v, other);
                        if (!keep) continue;
                        forms.append(arena, .{ .cat = idx, .name = try arena.dupe(u8, v) }) catch {};
                    }
                    if (forms.items.len > 0) {
                        sortByCat(PluralName, forms.items);
                        names.append(arena, .{ .code = code[0..3].*, .forms = forms.items }) catch {};
                    }
                }
            } else |_| {}
        } else |_| {}

        out.append(arena, .{
            .key = loc,
            .std_pattern = try arena.dupe(u8, std_pat),
            .acct_pattern = try arena.dupe(u8, acct_pat),
            .unit_patterns = unit_patterns.items,
            .syms = syms.items,
            .names = names.items,
        }) catch {};
    }
    std.sort.block(CurrencyLocale, out.items, {}, CurrencyLocale.lessThan);
    return .{ .fractions = fractions, .locales = out.items };
}

/// Sort a slice of `{ cat: u8, … }` records ascending by category index, so the
/// runtime can stop early and the canonical fallback order is preserved.
fn sortByCat(comptime T: type, items: []T) void {
    std.sort.block(T, items, {}, struct {
        fn lt(_: void, a: T, b: T) bool {
            return a.cat < b.cat;
        }
    }.lt);
}

fn writeCurrenciesPayload(gpa: std.mem.Allocator, buf: *std.ArrayListUnmanaged(u8), data: CurrencyData) !void {
    // Global fraction-digit overrides.
    try appendU32(gpa, buf, data.fractions.len);
    for (data.fractions) |f| {
        try buf.appendSlice(gpa, &f.code);
        try buf.append(gpa, f.digits);
    }
    // Per-locale patterns + unitPatterns + symbols.
    try appendU32(gpa, buf, data.locales.len);
    for (data.locales) |l| {
        try appendStr8(gpa, buf, l.key);
        try appendStr16(gpa, buf, l.std_pattern);
        try appendStr16(gpa, buf, l.acct_pattern);
        std.debug.assert(l.unit_patterns.len <= 0xFF);
        try buf.append(gpa, @intCast(l.unit_patterns.len));
        for (l.unit_patterns) |u| {
            try buf.append(gpa, u.cat);
            try appendStr16(gpa, buf, u.pattern);
        }
        std.debug.assert(l.syms.len <= 0xFFFF);
        try buf.append(gpa, @intCast(l.syms.len & 0xFF));
        try buf.append(gpa, @intCast((l.syms.len >> 8) & 0xFF));
        for (l.syms) |s| {
            try buf.appendSlice(gpa, &s.code);
            try appendStr8(gpa, buf, s.symbol);
            try appendStr8(gpa, buf, s.narrow);
        }
    }
}

/// The `currency_names` section: per locale, the per-currency plural long names
/// for currencyDisplay:"name". Kept apart from the `currencies` section so the
/// hot symbol/pattern lookups never walk this (much larger) table.
///   u32 locale_count
///   repeated: str8 key; u32 cur_count;
///     repeated: u8 code[3]; u8 form_count; repeated: u8 cat; str16 name
fn writeCurrencyNamesPayload(gpa: std.mem.Allocator, buf: *std.ArrayListUnmanaged(u8), data: CurrencyData) !void {
    try appendU32(gpa, buf, data.locales.len);
    for (data.locales) |l| {
        try appendStr8(gpa, buf, l.key);
        try appendU32(gpa, buf, l.names.len);
        for (l.names) |c| {
            try buf.appendSlice(gpa, &c.code);
            std.debug.assert(c.forms.len <= 0xFF);
            try buf.append(gpa, @intCast(c.forms.len));
            for (c.forms) |f| {
                try buf.append(gpa, f.cat);
                try appendStr16(gpa, buf, f.name);
            }
        }
    }
}

fn writeNumberingSystemsPayload(gpa: std.mem.Allocator, buf: *std.ArrayListUnmanaged(u8), table: []NumberingSystem) !void {
    try appendU32(gpa, buf, table.len);
    for (table) |n| {
        try appendStr8(gpa, buf, n.id);
        try appendU32(gpa, buf, n.digit_base);
    }
}

// ── dates (gregorian names + patterns) ───────────────────────────────────────

const DateLocale = struct {
    key: []const u8,
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
    fn lessThan(_: void, a: DateLocale, b: DateLocale) bool {
        return std.mem.lessThan(u8, a.key, b.key);
    }
};

const day_keys = [_][]const u8{ "sun", "mon", "tue", "wed", "thu", "fri", "sat" };

/// Per modern locale: gregorian month/day/dayPeriod/era names + the standard
/// date/time/dateTime patterns. The `-alt-ascii` time variants are skipped
/// (we keep the canonical narrow-no-break-space forms).
fn loadDates(arena: std.mem.Allocator, io: std.Io, json_root: []const u8) ![]DateLocale {
    var out: std.ArrayListUnmanaged(DateLocale) = .empty;
    for (modern_locales) |loc| {
        const path = try std.fmt.allocPrint(arena, "{s}/cldr-dates-full/main/{s}/ca-gregorian.json", .{ json_root, loc });
        const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(4 * 1024 * 1024)) catch continue;
        const root = std.json.parseFromSliceLeaky(std.json.Value, arena, bytes, .{}) catch continue;
        const main_obj = root.object.get("main").?.object;
        var mit = main_obj.iterator();
        const le = mit.next() orelse continue;
        const g = le.value_ptr.*.object.get("dates").?.object
            .get("calendars").?.object.get("gregorian").?.object;

        var d: DateLocale = undefined;
        d.key = loc;

        const months_fmt = g.get("months").?.object.get("format").?.object;
        const mwide = months_fmt.get("wide").?.object;
        const mabbr = months_fmt.get("abbreviated").?.object;
        var mi: usize = 0;
        while (mi < 12) : (mi += 1) {
            var kb: [4]u8 = undefined;
            const k = std.fmt.bufPrint(&kb, "{d}", .{mi + 1}) catch unreachable;
            d.months_wide[mi] = try arena.dupe(u8, strField(mwide, k, ""));
            d.months_abbr[mi] = try arena.dupe(u8, strField(mabbr, k, ""));
        }

        const days_fmt = g.get("days").?.object.get("format").?.object;
        const dwide = days_fmt.get("wide").?.object;
        const dabbr = days_fmt.get("abbreviated").?.object;
        for (day_keys, 0..) |dk, di| {
            d.days_wide[di] = try arena.dupe(u8, strField(dwide, dk, ""));
            d.days_abbr[di] = try arena.dupe(u8, strField(dabbr, dk, ""));
        }

        const dp = g.get("dayPeriods").?.object.get("format").?.object.get("wide").?.object;
        d.am = try arena.dupe(u8, strField(dp, "am", "AM"));
        d.pm = try arena.dupe(u8, strField(dp, "pm", "PM"));

        const eras = g.get("eras").?.object.get("eraAbbr").?.object;
        d.era_bc = try arena.dupe(u8, strField(eras, "0", "BC"));
        d.era_ad = try arena.dupe(u8, strField(eras, "1", "AD"));

        const df = g.get("dateFormats").?.object;
        d.date_full = try arena.dupe(u8, strField(df, "full", ""));
        d.date_long = try arena.dupe(u8, strField(df, "long", ""));
        d.date_medium = try arena.dupe(u8, strField(df, "medium", ""));
        d.date_short = try arena.dupe(u8, strField(df, "short", ""));

        const tf = g.get("timeFormats").?.object;
        d.time_full = try arena.dupe(u8, strField(tf, "full", ""));
        d.time_long = try arena.dupe(u8, strField(tf, "long", ""));
        d.time_medium = try arena.dupe(u8, strField(tf, "medium", ""));
        d.time_short = try arena.dupe(u8, strField(tf, "short", ""));

        const dtf = g.get("dateTimeFormats").?.object;
        d.dt_full = try arena.dupe(u8, strField(dtf, "full", "{1}, {0}"));
        d.dt_long = try arena.dupe(u8, strField(dtf, "long", "{1}, {0}"));
        d.dt_medium = try arena.dupe(u8, strField(dtf, "medium", "{1}, {0}"));
        d.dt_short = try arena.dupe(u8, strField(dtf, "short", "{1}, {0}"));

        try out.append(arena, d);
    }
    std.sort.block(DateLocale, out.items, {}, DateLocale.lessThan);
    return out.items;
}

fn writeDatesPayload(gpa: std.mem.Allocator, buf: *std.ArrayListUnmanaged(u8), locales: []DateLocale) !void {
    try appendU32(gpa, buf, locales.len);
    for (locales) |d| {
        try appendStr8(gpa, buf, d.key);
        for (d.months_wide) |m| try appendStr8(gpa, buf, m);
        for (d.months_abbr) |m| try appendStr8(gpa, buf, m);
        for (d.days_wide) |x| try appendStr8(gpa, buf, x);
        for (d.days_abbr) |x| try appendStr8(gpa, buf, x);
        try appendStr8(gpa, buf, d.am);
        try appendStr8(gpa, buf, d.pm);
        try appendStr8(gpa, buf, d.era_bc);
        try appendStr8(gpa, buf, d.era_ad);
        try appendStr16(gpa, buf, d.date_full);
        try appendStr16(gpa, buf, d.date_long);
        try appendStr16(gpa, buf, d.date_medium);
        try appendStr16(gpa, buf, d.date_short);
        try appendStr16(gpa, buf, d.time_full);
        try appendStr16(gpa, buf, d.time_long);
        try appendStr16(gpa, buf, d.time_medium);
        try appendStr16(gpa, buf, d.time_short);
        try appendStr16(gpa, buf, d.dt_full);
        try appendStr16(gpa, buf, d.dt_long);
        try appendStr16(gpa, buf, d.dt_medium);
        try appendStr16(gpa, buf, d.dt_short);
    }
}

// ── display names (language / region / script / currency) ────────────────────

const NameEntry = struct {
    code: []const u8,
    name: []const u8,
    fn lessThan(_: void, a: NameEntry, b: NameEntry) bool {
        return std.mem.lessThan(u8, a.code, b.code);
    }
};

const DisplayLocale = struct {
    key: []const u8,
    languages: []NameEntry,
    regions: []NameEntry,
    scripts: []NameEntry,
    currencies: []NameEntry,
    fn lessThan(_: void, a: DisplayLocale, b: DisplayLocale) bool {
        return std.mem.lessThan(u8, a.key, b.key);
    }
};

/// Per modern locale: language / territory / script / currency display names.
/// `-alt-*` variant keys are skipped (keep the primary name).
fn loadDisplayNames(arena: std.mem.Allocator, io: std.Io, json_root: []const u8) ![]DisplayLocale {
    var out: std.ArrayListUnmanaged(DisplayLocale) = .empty;
    for (modern_locales) |loc| {
        var d: DisplayLocale = .{ .key = loc, .languages = &.{}, .regions = &.{}, .scripts = &.{}, .currencies = &.{} };
        d.languages = loadNameTable(arena, io, json_root, "cldr-localenames-full", loc, "languages.json", "languages", codeIsLanguage);
        d.regions = loadNameTable(arena, io, json_root, "cldr-localenames-full", loc, "territories.json", "territories", codeIsRegion);
        d.scripts = loadNameTable(arena, io, json_root, "cldr-localenames-full", loc, "scripts.json", "scripts", codeIsScript);
        d.currencies = loadCurrencyNames(arena, io, json_root, loc);
        if (d.languages.len == 0 and d.regions.len == 0 and d.scripts.len == 0 and d.currencies.len == 0) continue;
        try out.append(arena, d);
    }
    std.sort.block(DisplayLocale, out.items, {}, DisplayLocale.lessThan);
    return out.items;
}

fn codeIsLanguage(code: []const u8) bool {
    // Skip `-alt-` variants; keep base + script/region subtags.
    return std.mem.indexOf(u8, code, "-alt-") == null;
}
fn codeIsRegion(code: []const u8) bool {
    if (std.mem.indexOf(u8, code, "-alt-") != null) return false;
    return (code.len == 2 and isAllAlpha(code)) or (code.len == 3 and isAllDigit(code));
}
fn codeIsScript(code: []const u8) bool {
    return std.mem.indexOf(u8, code, "-alt-") == null and code.len == 4 and isAllAlpha(code);
}

fn loadNameTable(
    arena: std.mem.Allocator,
    io: std.Io,
    json_root: []const u8,
    pkg: []const u8,
    loc: []const u8,
    filename: []const u8,
    table_key: []const u8,
    accept: *const fn ([]const u8) bool,
) []NameEntry {
    const path = std.fmt.allocPrint(arena, "{s}/{s}/main/{s}/{s}", .{ json_root, pkg, loc, filename }) catch return &.{};
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(4 * 1024 * 1024)) catch return &.{};
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena, bytes, .{}) catch return &.{};
    const main_obj = (root.object.get("main") orelse return &.{}).object;
    var mit = main_obj.iterator();
    const le = mit.next() orelse return &.{};
    const ldn = (le.value_ptr.*.object.get("localeDisplayNames") orelse return &.{}).object;
    const table = (ldn.get(table_key) orelse return &.{}).object;

    var out: std.ArrayListUnmanaged(NameEntry) = .empty;
    var it = table.iterator();
    while (it.next()) |e| {
        const code = e.key_ptr.*;
        if (!accept(code)) continue;
        if (e.value_ptr.* != .string) continue;
        out.append(arena, .{ .code = code, .name = e.value_ptr.*.string }) catch return out.items;
    }
    std.sort.block(NameEntry, out.items, {}, NameEntry.lessThan);
    return out.items;
}

/// Currency display names live in cldr-numbers (currencies.json) under the
/// `displayName` field of each 3-letter code.
fn loadCurrencyNames(arena: std.mem.Allocator, io: std.Io, json_root: []const u8, loc: []const u8) []NameEntry {
    const path = std.fmt.allocPrint(arena, "{s}/cldr-numbers-full/main/{s}/currencies.json", .{ json_root, loc }) catch return &.{};
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(8 * 1024 * 1024)) catch return &.{};
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena, bytes, .{}) catch return &.{};
    const main_obj = (root.object.get("main") orelse return &.{}).object;
    var mit = main_obj.iterator();
    const le = mit.next() orelse return &.{};
    const cur = (le.value_ptr.*.object.get("numbers") orelse return &.{}).object.get("currencies");
    if (cur == null) return &.{};

    var out: std.ArrayListUnmanaged(NameEntry) = .empty;
    var it = cur.?.object.iterator();
    while (it.next()) |e| {
        const code = e.key_ptr.*;
        if (code.len != 3 or !isAllAlpha(code)) continue;
        const dn = e.value_ptr.*.object.get("displayName") orelse continue;
        if (dn != .string) continue;
        out.append(arena, .{ .code = code, .name = dn.string }) catch return out.items;
    }
    std.sort.block(NameEntry, out.items, {}, NameEntry.lessThan);
    return out.items;
}

fn writeDisplayNamesPayload(gpa: std.mem.Allocator, buf: *std.ArrayListUnmanaged(u8), locales: []DisplayLocale) !void {
    try appendU32(gpa, buf, locales.len);
    for (locales) |d| {
        try appendStr8(gpa, buf, d.key);
        try writeNameTable(gpa, buf, d.languages);
        try writeNameTable(gpa, buf, d.regions);
        try writeNameTable(gpa, buf, d.scripts);
        try writeNameTable(gpa, buf, d.currencies);
    }
}

fn writeNameTable(gpa: std.mem.Allocator, buf: *std.ArrayListUnmanaged(u8), table: []NameEntry) !void {
    try appendU32(gpa, buf, table.len);
    for (table) |e| {
        try appendStr8(gpa, buf, e.code);
        try appendStr16(gpa, buf, e.name);
    }
}

fn appendStr8(gpa: std.mem.Allocator, buf: *std.ArrayListUnmanaged(u8), s: []const u8) !void {
    std.debug.assert(s.len <= 255);
    try buf.append(gpa, @intCast(s.len));
    try buf.appendSlice(gpa, s);
}

fn appendStr16(gpa: std.mem.Allocator, buf: *std.ArrayListUnmanaged(u8), s: []const u8) !void {
    std.debug.assert(s.len <= 0xFFFF);
    try buf.append(gpa, @intCast(s.len & 0xFF));
    try buf.append(gpa, @intCast((s.len >> 8) & 0xFF));
    try buf.appendSlice(gpa, s);
}

fn writePluralPayload(gpa: std.mem.Allocator, buf: *std.ArrayListUnmanaged(u8), locales: []LocaleRules) !void {
    try appendU32(gpa, buf, locales.len);
    for (locales) |loc| {
        std.debug.assert(loc.key.len <= 255);
        try buf.append(gpa, @intCast(loc.key.len));
        try buf.appendSlice(gpa, loc.key);
        try buf.append(gpa, @intCast(loc.rules.len));
        for (loc.rules) |r| {
            try buf.append(gpa, @intFromEnum(r.category));
            std.debug.assert(r.cond.len <= 0xFFFF);
            try buf.append(gpa, @intCast(r.cond.len & 0xFF));
            try buf.append(gpa, @intCast((r.cond.len >> 8) & 0xFF));
            try buf.appendSlice(gpa, r.cond);
        }
    }
}

fn appendU32(gpa: std.mem.Allocator, buf: *std.ArrayListUnmanaged(u8), v: usize) !void {
    const x: u32 = @intCast(v);
    try buf.appendSlice(gpa, &.{
        @intCast(x & 0xFF),
        @intCast((x >> 8) & 0xFF),
        @intCast((x >> 16) & 0xFF),
        @intCast((x >> 24) & 0xFF),
    });
}

fn isAllAlpha(s: []const u8) bool {
    for (s) |c| if (!std.ascii.isAlphabetic(c)) return false;
    return true;
}
fn isAllDigit(s: []const u8) bool {
    for (s) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
}

fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("pack_cldr: " ++ fmt ++ "\n", args);
    std.process.exit(1);
}
