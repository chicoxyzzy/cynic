//! Pack Unicode CLDR-JSON data into `vendor/cldr/cynic_cldr.bin` (CYCL v1).
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
//!     u8  version = 1
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

/// Section kinds. Dates / display-names land in later phases.
const SectionKind = enum(u8) {
    plural_cardinal = 1,
    plural_ordinal = 2,
    numbers = 3,
    numbering_systems = 4,
};

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

    const blob = try pack(allocator, cardinal, ordinal, numbers, ns_table);
    defer allocator.free(blob);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = out_path, .data = blob });

    var buf: [256]u8 = undefined;
    const msg = try std.fmt.bufPrint(&buf, "pack_cldr: wrote {s} ({d} bytes) — cardinal {d}, ordinal {d}, numbers {d}, numbering-systems {d}\n", .{ out_path, blob.len, cardinal.len, ordinal.len, numbers.len, ns_table.len });
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
) ![]u8 {
    var payloads: std.ArrayListUnmanaged(u8) = .empty;
    defer payloads.deinit(gpa);

    const SectionDir = struct { kind: SectionKind, off: u32, len: u32 };
    var dirs: [4]SectionDir = undefined;

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

    // Header + directory size, so we can fix up payload offsets to be absolute.
    const header_len: u32 = 4 + 1 + 3 + 4; // magic, ver, reserved, section_count
    const dir_entry_len: u32 = 1 + 3 + 4 + 4;
    const dir_len: u32 = dir_entry_len * dirs.len;
    const base: u32 = header_len + dir_len;

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, "CYCL");
    try out.append(gpa, 1); // version
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
    dec_pattern: []const u8,
    pct_pattern: []const u8,
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
            .dec_pattern = if (n.get(dec_key)) |d| strField(d.object, "standard", "#,##0.###") else "#,##0.###",
            .pct_pattern = if (n.get(pct_key)) |p| strField(p.object, "standard", "#,##0%") else "#,##0%",
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
        try appendStr16(gpa, buf, l.dec_pattern);
        try appendStr16(gpa, buf, l.pct_pattern);
    }
}

fn writeNumberingSystemsPayload(gpa: std.mem.Allocator, buf: *std.ArrayListUnmanaged(u8), table: []NumberingSystem) !void {
    try appendU32(gpa, buf, table.len);
    for (table) |n| {
        try appendStr8(gpa, buf, n.id);
        try appendU32(gpa, buf, n.digit_base);
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

fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("pack_cldr: " ++ fmt ++ "\n", args);
    std.process.exit(1);
}
