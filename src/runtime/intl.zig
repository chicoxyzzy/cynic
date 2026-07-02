//! ECMA-402 structural Intl substrate — language-tag algorithms,
//! locale resolution, option helpers, and per-constructor internal
//! slot records. No CLDR/ICU data: formatting/collation/segmentation
//! methods are present and option-faithful but produce implementation-
//! defined minimal output (typically `ToString` of the input).
//!
//! Abstract operations cite ECMA-402 sections; names mirror the spec
//! so test262 failures map cleanly.

const std = @import("std");
const cldr = @import("cldr.zig");

/// Maximum bytes we accept for a single language tag (well above any
/// realistic BCP 47 tag; guards pathological input from DoS'ing the
/// host — AGENTS.md host-safety contract).
pub const max_tag_bytes: usize = 256;

/// Implementation-defined default locale (§9.2.13 DefaultLocale).
pub const default_locale: []const u8 = "en";

// ── Internal slot records ──────────────────────────────────────────────────

pub const LocaleMatcher = enum { lookup, best_fit };

pub const IntlKind = enum {
    locale,
    collator,
    number_format,
    date_time_format,
    plural_rules,
    relative_time_format,
    list_format,
    display_names,
    segmenter,
    segments,
    duration_format,
};

/// Internal state for a `Segments` object (from `segmenter.segment(str)`) and
/// its segment iterator. `pos` is the iterator's code-unit cursor (unused by
/// the container). `string` + `granularity` are allocator-owned.
pub const SegmentsRecord = struct {
    string: []const u8 = "",
    granularity: []const u8 = "",
    pos: usize = 0,

    pub fn deinit(self: *SegmentsRecord, allocator: std.mem.Allocator) void {
        if (self.string.len > 0) allocator.free(self.string);
        if (self.granularity.len > 0) allocator.free(self.granularity);
        self.* = .{};
    }
};

/// Owned strings are allocator-owned copies; `deinit` frees them.
pub const LocaleSlots = struct {
    locale: []const u8 = "",
    language: []const u8 = "",
    script: []const u8 = "",
    region: []const u8 = "",
    variants: []const u8 = "",
    calendar: []const u8 = "",
    collation: []const u8 = "",
    hour_cycle: []const u8 = "",
    case_first: []const u8 = "",
    numeric: bool = false,
    numbering_system: []const u8 = "",
    base_name: []const u8 = "",

    pub fn deinit(self: *LocaleSlots, allocator: std.mem.Allocator) void {
        if (self.locale.len > 0) allocator.free(self.locale);
        if (self.language.len > 0) allocator.free(self.language);
        if (self.script.len > 0) allocator.free(self.script);
        if (self.region.len > 0) allocator.free(self.region);
        if (self.variants.len > 0) allocator.free(self.variants);
        if (self.calendar.len > 0) allocator.free(self.calendar);
        if (self.collation.len > 0) allocator.free(self.collation);
        if (self.hour_cycle.len > 0) allocator.free(self.hour_cycle);
        if (self.case_first.len > 0) allocator.free(self.case_first);
        if (self.numbering_system.len > 0) allocator.free(self.numbering_system);
        if (self.base_name.len > 0) allocator.free(self.base_name);
        self.* = .{};
    }
};

pub const ServiceLocaleSlots = struct {
    /// All non-empty slices are allocator-owned copies. Never store
    /// interned string literals here — deinit always frees non-empty.
    locale: []const u8 = "",
    /// UTS #35 §4.3 script-maximized form of `locale`, computed once when the
    /// formatter is constructed (e.g. `en` → `en-Latn`, `zh-TW` → `zh-Hant-TW`).
    /// CLDR data lookups read this so the per-`format()` path never re-scans the
    /// likelySubtags table; `resolvedOptions().locale` still reports `locale`.
    /// Empty means "not computed" — `dataLocale()` then falls back to `locale`,
    /// keeping behaviour correct (just unoptimised). Allocator-owned when set.
    data_locale: []const u8 = "",
    calendar: []const u8 = "",
    numbering_system: []const u8 = "",
    hour_cycle: []const u8 = "",
    collation: []const u8 = "",
    case_first: []const u8 = "",
    numeric: bool = false,

    /// The locale CLDR data lookups should key on: the script-maximized
    /// `data_locale` when present, else the resolved `locale`.
    pub fn dataLocale(self: *const ServiceLocaleSlots) []const u8 {
        return if (self.data_locale.len > 0) self.data_locale else self.locale;
    }

    pub fn deinit(self: *ServiceLocaleSlots, allocator: std.mem.Allocator) void {
        if (self.locale.len > 0) allocator.free(self.locale);
        if (self.data_locale.len > 0) allocator.free(self.data_locale);
        if (self.calendar.len > 0) allocator.free(self.calendar);
        if (self.numbering_system.len > 0) allocator.free(self.numbering_system);
        if (self.hour_cycle.len > 0) allocator.free(self.hour_cycle);
        if (self.collation.len > 0) allocator.free(self.collation);
        if (self.case_first.len > 0) allocator.free(self.case_first);
        self.* = .{};
    }
};

pub const CollatorSlots = struct {
    base: ServiceLocaleSlots = .{},
    /// Empty = unset; non-empty always allocator-owned.
    usage: []const u8 = "",
    sensitivity: []const u8 = "",
    ignore_punctuation: bool = false,
    collation: []const u8 = "",
    numeric: bool = false,
    case_first: []const u8 = "",

    pub fn deinit(self: *CollatorSlots, allocator: std.mem.Allocator) void {
        self.base.deinit(allocator);
        if (self.usage.len > 0) allocator.free(self.usage);
        if (self.sensitivity.len > 0) allocator.free(self.sensitivity);
        if (self.collation.len > 0) allocator.free(self.collation);
        if (self.case_first.len > 0) allocator.free(self.case_first);
        self.* = .{};
    }
};

pub const NumberFormatSlots = struct {
    base: ServiceLocaleSlots = .{},
    style: []const u8 = "",
    currency: []const u8 = "",
    currency_display: []const u8 = "",
    currency_sign: []const u8 = "",
    unit: []const u8 = "",
    unit_display: []const u8 = "",
    notation: []const u8 = "",
    compact_display: []const u8 = "",
    sign_display: []const u8 = "",
    use_grouping: []const u8 = "",
    minimum_integer_digits: u32 = 1,
    minimum_fraction_digits: ?u32 = null,
    maximum_fraction_digits: ?u32 = null,
    minimum_significant_digits: ?u32 = null,
    maximum_significant_digits: ?u32 = null,
    rounding_type: []const u8 = "",
    rounding_increment: u32 = 1,
    rounding_mode: []const u8 = "",
    trailing_zero_display: []const u8 = "",

    pub fn deinit(self: *NumberFormatSlots, allocator: std.mem.Allocator) void {
        self.base.deinit(allocator);
        if (self.style.len > 0) allocator.free(self.style);
        if (self.currency.len > 0) allocator.free(self.currency);
        if (self.currency_display.len > 0) allocator.free(self.currency_display);
        if (self.currency_sign.len > 0) allocator.free(self.currency_sign);
        if (self.unit.len > 0) allocator.free(self.unit);
        if (self.unit_display.len > 0) allocator.free(self.unit_display);
        if (self.notation.len > 0) allocator.free(self.notation);
        if (self.compact_display.len > 0) allocator.free(self.compact_display);
        if (self.sign_display.len > 0) allocator.free(self.sign_display);
        if (self.use_grouping.len > 0) allocator.free(self.use_grouping);
        if (self.rounding_type.len > 0) allocator.free(self.rounding_type);
        if (self.rounding_mode.len > 0) allocator.free(self.rounding_mode);
        if (self.trailing_zero_display.len > 0) allocator.free(self.trailing_zero_display);
        self.* = .{};
    }
};

pub const DateTimeFormatSlots = struct {
    base: ServiceLocaleSlots = .{},
    calendar: []const u8 = "",
    numbering_system: []const u8 = "",
    time_zone: []const u8 = "",
    hour_cycle: []const u8 = "",
    date_style: []const u8 = "",
    time_style: []const u8 = "",
    weekday: []const u8 = "",
    era: []const u8 = "",
    year: []const u8 = "",
    month: []const u8 = "",
    day: []const u8 = "",
    day_period: []const u8 = "",
    hour: []const u8 = "",
    minute: []const u8 = "",
    second: []const u8 = "",
    fractional_second_digits: ?u32 = null,
    time_zone_name: []const u8 = "",

    pub fn deinit(self: *DateTimeFormatSlots, allocator: std.mem.Allocator) void {
        self.base.deinit(allocator);
        if (self.calendar.len > 0) allocator.free(self.calendar);
        if (self.numbering_system.len > 0) allocator.free(self.numbering_system);
        if (self.time_zone.len > 0) allocator.free(self.time_zone);
        if (self.hour_cycle.len > 0) allocator.free(self.hour_cycle);
        if (self.date_style.len > 0) allocator.free(self.date_style);
        if (self.time_style.len > 0) allocator.free(self.time_style);
        if (self.weekday.len > 0) allocator.free(self.weekday);
        if (self.era.len > 0) allocator.free(self.era);
        if (self.year.len > 0) allocator.free(self.year);
        if (self.month.len > 0) allocator.free(self.month);
        if (self.day.len > 0) allocator.free(self.day);
        if (self.day_period.len > 0) allocator.free(self.day_period);
        if (self.hour.len > 0) allocator.free(self.hour);
        if (self.minute.len > 0) allocator.free(self.minute);
        if (self.second.len > 0) allocator.free(self.second);
        if (self.time_zone_name.len > 0) allocator.free(self.time_zone_name);
        self.* = .{};
    }
};

pub const PluralRulesSlots = struct {
    base: ServiceLocaleSlots = .{},
    type_name: []const u8 = "",
    notation: []const u8 = "",
    compact_display: []const u8 = "",
    minimum_integer_digits: u32 = 1,
    minimum_fraction_digits: u32 = 0,
    maximum_fraction_digits: u32 = 3,
    minimum_significant_digits: ?u32 = null,
    maximum_significant_digits: ?u32 = null,
    rounding_increment: u32 = 1,
    rounding_mode: []const u8 = "",
    rounding_priority: []const u8 = "",
    trailing_zero_display: []const u8 = "",
    plural_categories: []const []const u8 = &.{"other"},

    pub fn deinit(self: *PluralRulesSlots, allocator: std.mem.Allocator) void {
        self.base.deinit(allocator);
        if (self.type_name.len > 0) allocator.free(self.type_name);
        if (self.notation.len > 0) allocator.free(self.notation);
        if (self.compact_display.len > 0) allocator.free(self.compact_display);
        if (self.rounding_mode.len > 0) allocator.free(self.rounding_mode);
        if (self.rounding_priority.len > 0) allocator.free(self.rounding_priority);
        if (self.trailing_zero_display.len > 0) allocator.free(self.trailing_zero_display);
        self.* = .{};
    }
};

pub const RelativeTimeFormatSlots = struct {
    base: ServiceLocaleSlots = .{},
    numbering_system: []const u8 = "",
    style: []const u8 = "",
    numeric: []const u8 = "",

    pub fn deinit(self: *RelativeTimeFormatSlots, allocator: std.mem.Allocator) void {
        self.base.deinit(allocator);
        if (self.numbering_system.len > 0) allocator.free(self.numbering_system);
        if (self.style.len > 0) allocator.free(self.style);
        if (self.numeric.len > 0) allocator.free(self.numeric);
        self.* = .{};
    }
};

pub const ListFormatSlots = struct {
    base: ServiceLocaleSlots = .{},
    type_name: []const u8 = "",
    style: []const u8 = "",

    pub fn deinit(self: *ListFormatSlots, allocator: std.mem.Allocator) void {
        self.base.deinit(allocator);
        if (self.type_name.len > 0) allocator.free(self.type_name);
        if (self.style.len > 0) allocator.free(self.style);
        self.* = .{};
    }
};

pub const DisplayNamesSlots = struct {
    base: ServiceLocaleSlots = .{},
    style: []const u8 = "",
    type_name: []const u8 = "",
    fallback: []const u8 = "",
    language_display: []const u8 = "",

    pub fn deinit(self: *DisplayNamesSlots, allocator: std.mem.Allocator) void {
        self.base.deinit(allocator);
        if (self.style.len > 0) allocator.free(self.style);
        if (self.type_name.len > 0) allocator.free(self.type_name);
        if (self.fallback.len > 0) allocator.free(self.fallback);
        if (self.language_display.len > 0) allocator.free(self.language_display);
        self.* = .{};
    }
};

pub const SegmenterSlots = struct {
    base: ServiceLocaleSlots = .{},
    granularity: []const u8 = "",

    pub fn deinit(self: *SegmenterSlots, allocator: std.mem.Allocator) void {
        self.base.deinit(allocator);
        if (self.granularity.len > 0) allocator.free(self.granularity);
        self.* = .{};
    }
};

pub const DurationFormatSlots = struct {
    base: ServiceLocaleSlots = .{},
    numbering_system: []const u8 = "",
    style: []const u8 = "",
    /// Per-unit style + display, indexed by DurationUnit order
    /// (years … nanoseconds). All allocator-owned when set.
    unit_style: [10][]const u8 = @splat(""),
    unit_display: [10][]const u8 = @splat(""),
    fractional_digits: ?u32 = null,

    pub fn deinit(self: *DurationFormatSlots, allocator: std.mem.Allocator) void {
        self.base.deinit(allocator);
        if (self.numbering_system.len > 0) allocator.free(self.numbering_system);
        if (self.style.len > 0) allocator.free(self.style);
        for (self.unit_style) |u| if (u.len > 0) allocator.free(u);
        for (self.unit_display) |u| if (u.len > 0) allocator.free(u);
        self.* = .{};
    }
};

pub const IntlRecord = union(IntlKind) {
    locale: LocaleSlots,
    collator: CollatorSlots,
    number_format: NumberFormatSlots,
    date_time_format: DateTimeFormatSlots,
    plural_rules: PluralRulesSlots,
    relative_time_format: RelativeTimeFormatSlots,
    list_format: ListFormatSlots,
    display_names: DisplayNamesSlots,
    segmenter: SegmenterSlots,
    segments: SegmentsRecord,
    duration_format: DurationFormatSlots,

    pub fn deinit(self: *IntlRecord, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .locale => |*s| s.deinit(allocator),
            .collator => |*s| s.deinit(allocator),
            .number_format => |*s| s.deinit(allocator),
            .date_time_format => |*s| s.deinit(allocator),
            .plural_rules => |*s| s.deinit(allocator),
            .relative_time_format => |*s| s.deinit(allocator),
            .list_format => |*s| s.deinit(allocator),
            .display_names => |*s| s.deinit(allocator),
            .segmenter => |*s| s.deinit(allocator),
            .segments => |*s| s.deinit(allocator),
            .duration_format => |*s| s.deinit(allocator),
        }
    }
};

// ── Tag / locale algorithms ────────────────────────────────────────────────

fn isAlpha(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z');
}

fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

fn isAlphanum(c: u8) bool {
    return isAlpha(c) or isDigit(c);
}

fn toLowerAscii(c: u8) u8 {
    if (c >= 'A' and c <= 'Z') return c + 32;
    return c;
}

fn toUpperAscii(c: u8) u8 {
    if (c >= 'a' and c <= 'z') return c - 32;
    return c;
}

/// §6.2.2 IsStructurallyValidLanguageTag — pragmatic structural
/// check for Unicode Locale Identifiers (language-Script-REGION
/// plus optional variants and extensions; rejects underscores and
/// empty segments). Not a full UTS #35 parser.
pub fn isStructurallyValidLanguageTag(tag: []const u8) bool {
    if (tag.len == 0 or tag.len > max_tag_bytes) return false;

    var i: usize = 0;
    // Language subtag: 2-3 / 5-8 ALPHA (4 is reserved; we accept 2-8
    // alpha then refine — reject singleton-only).
    const lang_start = i;
    while (i < tag.len and isAlpha(tag[i])) : (i += 1) {}
    const lang_len = i - lang_start;
    // §unicode_language_subtag — 2-3 or 5-8 ALPHA; a 4-ALPHA primary subtag is
    // the reserved slot and not a valid language (so "hans-cmn-cn" is invalid).
    if (lang_len < 2 or lang_len > 8 or lang_len == 4) return false;

    // Optional extlang sequences (3 ALPHA) — up to 3 — or script/region.
    var saw_script = false;
    var saw_region = false;
    var variant_count: usize = 0;
    var variants: [16][]const u8 = undefined;
    var saw_extension = false;
    var saw_privateuse = false;
    var seen_singletons: u64 = 0; // bitset of extension singletons already seen

    while (i < tag.len) {
        if (tag[i] != '-') return false;
        i += 1;
        if (i >= tag.len) return false;

        if ((tag[i] == 'x' or tag[i] == 'X') and i + 1 < tag.len and tag[i + 1] == '-') {
            // Private use: x-alphanum{1,8}(-alphanum{1,8})* — the singleton
            // only, not a longer subtag that merely starts with x ("zh-xiang").
            i += 1;
            if (i >= tag.len or tag[i] != '-') return false;
            i += 1;
            var seg_start = i;
            while (i < tag.len) {
                if (tag[i] == '-') {
                    const seg_len = i - seg_start;
                    if (seg_len < 1 or seg_len > 8) return false;
                    i += 1;
                    seg_start = i;
                    continue;
                }
                if (!isAlphanum(tag[i])) return false;
                i += 1;
            }
            const seg_len = i - seg_start;
            if (seg_len < 1 or seg_len > 8) return false;
            saw_privateuse = true;
            break;
        }

        // Singleton extension: single alphanum except x, then segments.
        if (i + 1 < tag.len and tag[i + 1] == '-' and isAlphanum(tag[i])) {
            const sing = toLowerAscii(tag[i]);
            if (sing == 'x') return false; // handled above
            // §unicode_locale_id — a singleton extension may appear at most once
            // (so "en-u-…-U-…" / repeated -t- is structurally invalid).
            const sbit: u6 = if (sing >= 'a' and sing <= 'z') @intCast(sing - 'a') else @intCast(26 + (sing - '0'));
            const mask = @as(u64, 1) << sbit;
            if (seen_singletons & mask != 0) return false;
            seen_singletons |= mask;
            i += 2;
            var seg_start = i;
            var any_seg = false;
            while (i < tag.len) {
                if (tag[i] == '-') {
                    const seg_len = i - seg_start;
                    if (seg_len < 2 or seg_len > 8) return false;
                    // §unicode_locale_extensions — a `-u-` keyword `key` is
                    // `alphanum alpha`; a 2-char segment (always a key, since
                    // attributes are {3,8}) must end in a letter (`c0`/`00`
                    // are invalid; `0c` is valid).
                    if (sing == 'u' and seg_len == 2 and !isAlpha(tag[seg_start + 1])) return false;
                    any_seg = true;
                    i += 1;
                    // Next might be another extension singleton.
                    if (i < tag.len and i + 1 < tag.len and tag[i + 1] == '-' and isAlphanum(tag[i])) {
                        // Close current extension; outer loop handles next.
                        i -= 1; // back up so outer sees '-'
                        break;
                    }
                    seg_start = i;
                    continue;
                }
                if (!isAlphanum(tag[i])) return false;
                i += 1;
            }
            if (!any_seg) {
                const seg_len = i - seg_start;
                if (seg_len < 2 or seg_len > 8) return false;
                if (sing == 'u' and seg_len == 2 and !isAlpha(tag[seg_start + 1])) return false;
            } else {
                const seg_len = i - seg_start;
                if (seg_len > 0 and (seg_len < 2 or seg_len > 8)) return false;
                if (sing == 'u' and seg_len == 2 and !isAlpha(tag[seg_start + 1])) return false;
            }
            saw_extension = true;
            continue;
        }

        const seg_start = i;
        while (i < tag.len and isAlphanum(tag[i])) : (i += 1) {}
        const seg_len = i - seg_start;
        if (seg_len == 0) return false;
        const seg = tag[seg_start..i];

        if (!saw_script and !saw_region and seg_len == 4 and allAlpha(seg)) {
            saw_script = true;
            continue;
        }
        if (!saw_region and (seg_len == 2 and allAlpha(seg)) or (seg_len == 3 and allDigit(seg))) {
            saw_region = true;
            continue;
        }
        // Variants: 5-8 alphanum, or digit+3 alphanum. A repeated variant
        // subtag makes the tag structurally invalid (§ unicode_language_id).
        if ((seg_len >= 5 and seg_len <= 8) or (seg_len == 4 and isDigit(seg[0]))) {
            for (variants[0..variant_count]) |v| {
                if (std.ascii.eqlIgnoreCase(v, seg)) return false;
            }
            if (variant_count >= variants.len) return false;
            variants[variant_count] = seg;
            variant_count += 1;
            continue;
        }
        // §unicode_language_id has no extlang production — a 3-ALPHA subtag
        // after the language is not a valid script/region/variant, so the
        // tag is structurally invalid (e.g. "en-els", and the grandfathered
        // BCP 47 forms like "zh-min-nan" with it).
        return false;
    }
    return validTExtension(tag);
}

/// §unicode_locale_id transformed_extensions — the `-t-` extension carries a
/// tlang (a full language id: language, optional script/region, variants with
/// no case-insensitive duplicates) and/or tfields (tkey = alpha+digit, each
/// with at least one alphanum{3,8} tvalue, no duplicate keys).
fn isTKey(seg: []const u8) bool {
    return seg.len == 2 and isAlpha(seg[0]) and isDigit(seg[1]);
}

fn validTExtension(tag: []const u8) bool {
    var parts = std.mem.splitScalar(u8, tag, '-');
    var in_t = false;
    var t_any = false; // the t extension has at least one subtag
    var saw_lang = false;
    var saw_script = false;
    var saw_region = false;
    var in_tfields = false;
    var last_was_tkey = false;
    var variants: [16][]const u8 = undefined;
    var vn: usize = 0;
    var keys: [16][2]u8 = undefined;
    var kn: usize = 0;
    while (parts.next()) |seg| {
        if (seg.len == 0) continue; // empty segments rejected by the caller
        if (seg.len == 1) {
            // Any 1-char segment before `-x-` is a singleton and ends the
            // t extension; private use is opaque (1-char segments inside it
            // are not singletons).
            if (in_t) {
                if (last_was_tkey or !t_any) return false;
                in_t = false;
            }
            if (seg[0] == 'x' or seg[0] == 'X') break;
            if (seg[0] == 't' or seg[0] == 'T') {
                in_t = true;
                t_any = false;
                saw_lang = false;
                saw_script = false;
                saw_region = false;
                in_tfields = false;
                last_was_tkey = false;
                vn = 0;
                kn = 0;
            }
            continue;
        }
        if (!in_t) continue;
        t_any = true;
        if (isTKey(seg)) {
            if (last_was_tkey) return false; // key without a value
            const lo = [2]u8{ toLowerAscii(seg[0]), seg[1] };
            for (keys[0..kn]) |k| if (k[0] == lo[0] and k[1] == lo[1]) return false;
            if (kn >= keys.len) return false;
            keys[kn] = lo;
            kn += 1;
            in_tfields = true;
            last_was_tkey = true;
            continue;
        }
        if (in_tfields) {
            if (seg.len < 3 or seg.len > 8) return false; // tvalue is alphanum{3,8}
            last_was_tkey = false;
            continue;
        }
        // tlang subtags.
        if (!saw_lang) {
            // unicode_language_subtag — 2-3 or 5-8 ALPHA.
            if (!allAlpha(seg) or seg.len == 4 or seg.len > 8) return false;
            saw_lang = true;
            continue;
        }
        if (!saw_script and !saw_region and vn == 0 and seg.len == 4 and allAlpha(seg)) {
            saw_script = true;
            continue;
        }
        if (!saw_region and vn == 0 and ((seg.len == 2 and allAlpha(seg)) or (seg.len == 3 and allDigit(seg)))) {
            saw_region = true;
            continue;
        }
        if ((seg.len >= 5 and seg.len <= 8) or (seg.len == 4 and isDigit(seg[0]))) {
            for (variants[0..vn]) |v| if (std.ascii.eqlIgnoreCase(v, seg)) return false;
            if (vn >= variants.len) return false;
            variants[vn] = seg;
            vn += 1;
            continue;
        }
        // Anything else (3-ALPHA extlang, a second script, a stray 2-char
        // subtag after the region, "lat0", …) is structurally invalid.
        return false;
    }
    if (in_t and (last_was_tkey or !t_any)) return false;
    return true;
}

fn allAlpha(s: []const u8) bool {
    for (s) |c| if (!isAlpha(c)) return false;
    return true;
}

fn allDigit(s: []const u8) bool {
    for (s) |c| if (!isDigit(c)) return false;
    return true;
}

/// §3.2 UTS #35 `type` production —
/// `(alphanum{3,8}) ("-" alphanum{3,8})*`. The value space for
/// Unicode extension keys (`ca`, `co`, `nu`) and for any "type"
/// option (calendar, collation, numberingSystem).
pub fn isValidUnicodeType(value: []const u8) bool {
    if (value.len == 0) return false;
    var i: usize = 0;
    while (i < value.len) {
        const seg_start = i;
        while (i < value.len and value[i] != '-') : (i += 1) {
            if (!isAlphanum(value[i])) return false;
        }
        const seg_len = i - seg_start;
        if (seg_len < 3 or seg_len > 8) return false;
        if (i < value.len) i += 1; // consume '-'
    }
    // Trailing '-' would have produced a zero-length final segment above.
    return value[value.len - 1] != '-';
}

/// §14.1.2 ApplyOptionsToTag — `unicode_language_subtag`:
/// 2-3 / 5-8 ALPHA (the 4-ALPHA reserved slot rejected).
pub fn isValidLanguageSubtag(value: []const u8) bool {
    if (value.len < 2 or value.len > 8 or value.len == 4) return false;
    return allAlpha(value);
}

/// §14.1.2 ApplyOptionsToTag — `unicode_script_subtag`: 4 ALPHA.
pub fn isValidScriptSubtag(value: []const u8) bool {
    return value.len == 4 and allAlpha(value);
}

/// §14.1.2 ApplyOptionsToTag — `unicode_region_subtag`:
/// 2 ALPHA or 3 DIGIT.
pub fn isValidRegionSubtag(value: []const u8) bool {
    if (value.len == 2) return allAlpha(value);
    if (value.len == 3) return allDigit(value);
    return false;
}

/// `unicode_variant_subtag`: 5-8 alphanum, or 4 chars beginning with a digit.
pub fn isValidVariantSubtag(value: []const u8) bool {
    if (value.len >= 5 and value.len <= 8) {
        for (value) |c| if (!isAlphanum(c)) return false;
        return true;
    }
    if (value.len == 4) {
        if (value[0] < '0' or value[0] > '9') return false;
        for (value[1..]) |c| if (!isAlphanum(c)) return false;
        return true;
    }
    return false;
}

/// `unicode_language_id`: language subtag, then an optional script, an optional
/// region, and any number of variants — with **no** singleton / extension
/// subtags. Stricter than `isStructurallyValidLanguageTag` (which permits
/// `-u-` / `-t-` / `-x-`); used for `Intl.DisplayNames.prototype.of`
/// type:"language", whose argument must match the bare id production (§12.5.1).
pub fn isUnicodeLanguageId(code: []const u8) bool {
    if (code.len == 0) return false;
    var it = std.mem.splitScalar(u8, code, '-');
    const lang = it.next() orelse return false;
    if (!isValidLanguageSubtag(lang)) return false;
    var seen_script = false;
    var seen_region = false;
    var variants: [16][]const u8 = undefined;
    var nvar: usize = 0;
    while (it.next()) |sub| {
        if (sub.len == 1) return false; // singleton ⇒ extension, not an id
        if (!seen_script and !seen_region and nvar == 0 and isValidScriptSubtag(sub)) {
            seen_script = true;
        } else if (!seen_region and nvar == 0 and isValidRegionSubtag(sub)) {
            seen_region = true;
        } else if (isValidVariantSubtag(sub)) {
            // unicode_language_id forbids a repeated variant subtag.
            for (variants[0..nvar]) |v| if (std.ascii.eqlIgnoreCase(v, sub)) return false;
            if (nvar < variants.len) {
                variants[nvar] = sub;
                nvar += 1;
            }
        } else return false;
    }
    return true;
}

/// §6.2.3 CanonicalizeUnicodeLocaleId — structural only: normalize
/// case (language lower, script title, region upper, extensions lower),
/// sort unicode extension keywords, drop duplicate variants.
/// Caller owns the returned slice.
pub fn canonicalizeUnicodeLocaleId(allocator: std.mem.Allocator, tag: []const u8) ![]const u8 {
    if (tag.len == 0 or tag.len > max_tag_bytes) return error.InvalidTag;

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    var parts = std.mem.splitScalar(u8, tag, '-');
    var first = true;
    var part_idx: usize = 0;
    var in_unicode_ext = false;
    var in_other_ext = false; // inside a non-`u` singleton extension (-t-, -x-, …)
    var in_t_ext = false;
    var in_private_use = false;
    var unicode_keywords: std.ArrayListUnmanaged([]const u8) = .empty;
    defer unicode_keywords.deinit(allocator);
    var t_segments: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (t_segments.items) |t| allocator.free(t);
        t_segments.deinit(allocator);
    }

    while (parts.next()) |raw_part| {
        if (raw_part.len == 0) return error.InvalidTag;
        var part_buf: [max_tag_bytes]u8 = undefined;
        if (raw_part.len > part_buf.len) return error.InvalidTag;
        @memcpy(part_buf[0..raw_part.len], raw_part);
        const part = part_buf[0..raw_part.len];

        if (part_idx == 0) {
            // language → lowercase
            for (part) |*c| c.* = toLowerAscii(c.*);
        } else if (in_private_use) {
            // §unicode_locale_id pu_extensions — everything after `-x-` is
            // opaque (a 1-char `u` segment there is NOT the unicode
            // extension); lowercase and pass through.
            for (part) |*c| c.* = toLowerAscii(c.*);
        } else if (part.len == 1) {
            // Extension singleton → lowercase; flush prior u-keywords /
            // t-extension content.
            if (in_unicode_ext) {
                try appendUnicodeKeywords(allocator, &out, &unicode_keywords);
                in_unicode_ext = false;
            }
            if (in_t_ext) {
                try appendTransformedExt(allocator, &out, t_segments.items);
                in_t_ext = false;
            }
            for (part) |*c| c.* = toLowerAscii(c.*);
            in_other_ext = part[0] != 'u';
            if (part[0] == 'u') in_unicode_ext = true;
            in_t_ext = part[0] == 't';
            if (part[0] == 'x') in_private_use = true;
        } else if (in_unicode_ext) {
            // Unicode extension key/value — always lowercase. A 2-ALPHA
            // segment here is a `-u-` keyword key (e.g. `hc`, `ca`), not
            // a region; the region-case rule below would corrupt it.
            for (part) |*c| c.* = toLowerAscii(c.*);
        } else if (in_other_ext) {
            // Any other extension / private-use segment (-t- tlang + tfields,
            // -x-, …) is lowercase; the region-case rule below would corrupt a
            // 2-ALPHA segment like the `-t-en` tlang language.
            for (part) |*c| c.* = toLowerAscii(c.*);
        } else if (part.len == 4 and allAlpha(part) and part_idx == 1) {
            // Likely script — Title case.
            part[0] = toUpperAscii(part[0]);
            var j: usize = 1;
            while (j < part.len) : (j += 1) part[j] = toLowerAscii(part[j]);
        } else if ((part.len == 2 and allAlpha(part)) or (part.len == 3 and allDigit(part))) {
            // Region → UPPER.
            for (part) |*c| c.* = toUpperAscii(c.*);
        } else {
            // variants / extension segments → lower
            for (part) |*c| c.* = toLowerAscii(c.*);
        }

        if (in_unicode_ext and part.len > 1) {
            try unicode_keywords.append(allocator, try allocator.dupe(u8, part));
            part_idx += 1;
            continue;
        }
        if (in_t_ext and part.len > 1) {
            try t_segments.append(allocator, try allocator.dupe(u8, part));
            part_idx += 1;
            continue;
        }

        if (!first) try out.append(allocator, '-');
        try out.appendSlice(allocator, part);
        first = false;
        part_idx += 1;
    }
    if (in_unicode_ext) {
        try appendUnicodeKeywords(allocator, &out, &unicode_keywords);
    }
    if (in_t_ext) {
        try appendTransformedExt(allocator, &out, t_segments.items);
    }
    // Free keyword dupes.
    for (unicode_keywords.items) |k| allocator.free(k);

    const canon = try out.toOwnedSlice(allocator);
    return applyLanguageAlias(allocator, canon);
}

/// §3.2.1 territoryAlias — resolve a region subtag to its canonical form: a
/// 1→1 alias replaces directly; a 1→many alias picks the likely territory for
/// the (language, script), else the first in the list. Returns `region`
/// unchanged when there is no alias (or no blob).
fn resolveRegionAlias(region: []const u8, lang: []const u8, script: []const u8) []const u8 {
    const alias = cldr.territoryAlias(region) orelse return region;
    if (std.mem.indexOfScalar(u8, alias, ' ') == null) return alias; // 1→1
    var likely: cldr.Subtags = .{};
    const have = cldr.addLikelySubtags(.{ .lang = lang, .script = script }, &likely);
    var first: []const u8 = region;
    var it = std.mem.splitScalar(u8, alias, ' ');
    var idx: usize = 0;
    while (it.next()) |r| : (idx += 1) {
        if (idx == 0) first = r;
        if (have and likely.region.len != 0 and std.mem.eql(u8, r, likely.region)) return r;
    }
    return first;
}

/// §3.2.1 — apply the CLDR languageAlias to the (already case-canonicalised)
/// tag's language subtag, merging the replacement's script/region into any the
/// input lacks (an input field wins; the replacement only fills a gap, e.g.
/// `sh` → sr-Latn but `sh-Cyrl` → sr-Cyrl). Bare-language keys only. Ownership
/// of `canon` passes in: returned unchanged on no match, otherwise freed and a
/// fresh allocation returned. A no-op at `-Dintl` flavours without the blob.
fn applyLanguageAlias(allocator: std.mem.Allocator, canon: []const u8) ![]const u8 {
    // language_id portion = up to the first single-char subtag (an extension
    // or `-x-` singleton); the remainder is carried through verbatim.
    var lang_id_end: usize = canon.len;
    {
        var i: usize = 0;
        var seg_start: usize = 0;
        while (i <= canon.len) : (i += 1) {
            if (i == canon.len or canon[i] == '-') {
                if (i - seg_start == 1 and seg_start > 0) {
                    lang_id_end = seg_start - 1;
                    break;
                }
                seg_start = i + 1;
            }
        }
    }
    const language_id = canon[0..lang_id_end];
    const rest = canon[lang_id_end..]; // leading '-' (extensions) or empty

    // Split the language_id into subtags.
    var subs: [16][]const u8 = undefined;
    var n: usize = 0;
    var sit = std.mem.splitScalar(u8, language_id, '-');
    while (sit.next()) |s| {
        if (n >= subs.len) return canon; // pathological; leave as-is
        subs[n] = s;
        n += 1;
    }
    if (n == 0) return canon;

    // Classify the input's script / region; everything else is a variant.
    var in_script: []const u8 = "";
    var in_region: []const u8 = "";
    var variants: [16][]const u8 = undefined;
    var vn: usize = 0;
    for (subs[1..n]) |s| {
        if (in_script.len == 0 and s.len == 4 and allAlpha(s)) {
            in_script = s;
        } else if (in_region.len == 0 and ((s.len == 2 and allAlpha(s)) or (s.len == 3 and allDigit(s)))) {
            in_region = s;
        } else {
            variants[vn] = s;
            vn += 1;
        }
    }
    // §3.2.1 languageAlias, multi-subtag keys (sgn-BR → bzs, cel-gaulish →
    // xtg, und-hepburn-heploc → und-alalc97, und-arevela → und, …): the first
    // table row whose fields are all present in the input fires; its key
    // fields are consumed and its replacement fields merged.
    var variants_aliased = false;
    var cur_lang = subs[0];
    multi: for (@import("intl_language_aliases.zig").multi_subtag_aliases) |row| {
        if (!std.mem.eql(u8, row.lang, "und") and !std.mem.eql(u8, row.lang, cur_lang)) continue;
        if (row.script.len != 0 and !std.ascii.eqlIgnoreCase(row.script, in_script)) continue;
        if (row.region.len != 0 and !std.ascii.eqlIgnoreCase(row.region, in_region)) continue;
        for (row.variants) |kv| {
            for (variants[0..vn]) |v| {
                if (std.ascii.eqlIgnoreCase(kv, v)) break;
            } else continue :multi;
        }
        if (!std.mem.eql(u8, row.r_lang, "und")) cur_lang = row.r_lang;
        if (row.script.len != 0) in_script = row.r_script;
        if (row.region.len != 0) in_region = row.r_region;
        if (row.variants.len != 0 or row.r_variants.len != 0) {
            var w: usize = 0;
            outer: for (variants[0..vn]) |v| {
                for (row.variants) |kv| if (std.ascii.eqlIgnoreCase(kv, v)) continue :outer;
                variants[w] = v;
                w += 1;
            }
            vn = w;
            for (row.r_variants) |rv| {
                if (vn >= variants.len) break;
                variants[vn] = rv;
                vn += 1;
            }
        }
        variants_aliased = true;
        break;
    }
    // §3.2.1 languageAlias, bare-language key — applied to the (possibly
    // multi-subtag-rewritten) language.
    var repl: cldr.Subtags = .{};
    const has_alias = cldr.languageAlias(cur_lang, &repl);
    // §3.2.1 variantAlias — the two deprecated simple variants.
    for (variants[0..vn]) |*v| {
        if (std.mem.eql(u8, v.*, "heploc")) {
            v.* = "alalc97";
            variants_aliased = true;
        } else if (std.mem.eql(u8, v.*, "polytoni")) {
            v.* = "polyton";
            variants_aliased = true;
        }
    }
    // §unicode_language_id — variants are sorted alphabetically in canonical
    // form. Skip the rebuild entirely if there is no alias and the variants are
    // already ordered (the common case).
    var variants_sorted = true;
    var vk: usize = 1;
    while (vk < vn) : (vk += 1) {
        if (std.mem.lessThan(u8, variants[vk], variants[vk - 1])) {
            variants_sorted = false;
            break;
        }
    }
    const out_lang = if (has_alias) repl.lang else cur_lang;
    const out_script = if (in_script.len != 0) in_script else (if (has_alias) repl.script else "");
    // §3.2.1 territoryAlias — canonicalise the region (input's, else the
    // language alias's): a 1→1 alias replaces directly (554→NZ, UK→GB); a
    // 1→many alias picks the likely territory for the language/script.
    const base_region = if (in_region.len != 0) in_region else (if (has_alias) repl.region else "");
    const out_region = if (base_region.len != 0) resolveRegionAlias(base_region, out_lang, out_script) else "";
    const region_aliased = !std.mem.eql(u8, out_region, base_region);
    if (!has_alias and variants_sorted and !region_aliased and !variants_aliased) return canon;
    std.mem.sort([]const u8, variants[0..vn], {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);

    // Rebuild language_id (input fields already canonically cased; the CLDR
    // replacement subtags are in canonical case too) + the carried remainder.
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);
    try buf.appendSlice(allocator, out_lang);
    if (out_script.len != 0) {
        try buf.append(allocator, '-');
        try buf.appendSlice(allocator, out_script);
    }
    if (out_region.len != 0) {
        try buf.append(allocator, '-');
        try buf.appendSlice(allocator, out_region);
    }
    for (variants[0..vn]) |v| {
        try buf.append(allocator, '-');
        try buf.appendSlice(allocator, v);
    }
    try buf.appendSlice(allocator, rest);

    allocator.free(canon);
    return buf.toOwnedSlice(allocator);
}

/// UTS #35 §3.2.1 — `-u-` keys whose `true` type is the default and is dropped
/// in canonical form; these keys also alias `yes` → `true`.
fn isBooleanUKey(key: []const u8) bool {
    return std.mem.eql(u8, key, "kb") or std.mem.eql(u8, key, "kc") or
        std.mem.eql(u8, key, "kh") or std.mem.eql(u8, key, "kk") or
        std.mem.eql(u8, key, "kn");
}

/// UTS #35 §3.2.1 — replace a `-u-` type value by its canonical form from the
/// bcp47 data. Only the finite type-alias sets that can appear as a valid
/// `uvalue` (alphanum{3,8}) subtag are mapped; longer aliases (`secondary`,
/// `identical`) can never occur as input and need no entry.
fn canonicalUnicodeType(key: []const u8, value: []const u8) []const u8 {
    if (isBooleanUKey(key) and std.mem.eql(u8, value, "yes")) return "true";
    if (std.mem.eql(u8, key, "ks")) {
        if (std.mem.eql(u8, value, "primary")) return "level1";
        if (std.mem.eql(u8, value, "tertiary")) return "level3";
    }
    if (std.mem.eql(u8, key, "ms") and std.mem.eql(u8, value, "imperial")) return "uksystem";
    if (std.mem.eql(u8, key, "rg") or std.mem.eql(u8, key, "sd")) {
        // §3.2.1 subdivisionAlias — deprecated subdivision codes replace.
        for (@import("intl_subdivision_aliases.zig").subdivision_aliases) |a| {
            if (std.mem.eql(u8, a.alias, value)) return a.canonical;
        }
    }
    if (std.mem.eql(u8, key, "tz")) {
        // bcp47 timezone.xml — deprecated tz codes and their preferred values.
        const tz_aliases = [_][2][]const u8{
            .{ "cnckg", "cnsha" },
            .{ "eire", "iedub" },
            .{ "est", "papty" },
            .{ "gmt0", "gmt" },
            .{ "uct", "utc" },
            .{ "zulu", "utc" },
        };
        for (tz_aliases) |a| if (std.mem.eql(u8, a[0], value)) return a[1];
    }
    return value;
}

/// §3.2.1 bcp47 transform field-value aliases (finite deprecated set),
/// matched against the whole joined key-value group.
fn tFieldAlias(group: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, group, "m0-names")) return "m0-prprname";
    if (std.mem.eql(u8, group, "m0-alaloc")) return "m0-alalc97";
    if (std.mem.eql(u8, group, "d0-name")) return "d0-charname";
    return null;
}

/// §3.2.1 — canonical form of the `-t-` extension (all lowercase, which the
/// caller's case pass already produced): the tlang gets the CLDR language
/// alias on its language subtag and its variants sorted; the tfields are
/// grouped per tkey, alias-mapped, and sorted by key. Appends `-…` after the
/// already-emitted `t` singleton.
fn appendTransformedExt(
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u8),
    items: []const []const u8,
) !void {
    if (items.len == 0) return;
    var tlang_len: usize = 0;
    while (tlang_len < items.len and !isTKey(items[tlang_len])) : (tlang_len += 1) {}
    if (tlang_len > 0) {
        var repl: cldr.Subtags = .{};
        const lang = if (cldr.languageAlias(items[0], &repl)) repl.lang else items[0];
        try out.append(allocator, '-');
        for (lang) |c| try out.append(allocator, toLowerAscii(c));
        // Script / region keep their positions; variants sort alphabetically.
        var variants: [16][]const u8 = undefined;
        var vn: usize = 0;
        for (items[1..tlang_len]) |seg| {
            const is_variant = (seg.len >= 5 and seg.len <= 8) or (seg.len == 4 and isDigit(seg[0]));
            if (is_variant and vn < variants.len) {
                variants[vn] = seg;
                vn += 1;
                continue;
            }
            try out.append(allocator, '-');
            try out.appendSlice(allocator, seg);
        }
        std.mem.sort([]const u8, variants[0..vn], {}, struct {
            fn lt(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.lessThan(u8, a, b);
            }
        }.lt);
        for (variants[0..vn]) |v| {
            try out.append(allocator, '-');
            try out.appendSlice(allocator, v);
        }
    }
    var groups: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (groups.items) |g| allocator.free(g);
        groups.deinit(allocator);
    }
    var i: usize = tlang_len;
    while (i < items.len) {
        var end = i + 1;
        while (end < items.len and !isTKey(items[end])) : (end += 1) {}
        var total: usize = 0;
        for (items[i..end]) |seg| total += seg.len + 1;
        const buf = try allocator.alloc(u8, total - 1);
        var pos: usize = 0;
        for (items[i..end], 0..) |seg, idx| {
            if (idx > 0) {
                buf[pos] = '-';
                pos += 1;
            }
            @memcpy(buf[pos .. pos + seg.len], seg);
            pos += seg.len;
        }
        if (tFieldAlias(buf)) |alias| {
            allocator.free(buf);
            try groups.append(allocator, try allocator.dupe(u8, alias));
        } else {
            try groups.append(allocator, buf);
        }
        i = end;
    }
    var gi: usize = 1;
    while (gi < groups.items.len) : (gi += 1) {
        var gj = gi;
        while (gj > 0 and std.mem.order(u8, groups.items[gj], groups.items[gj - 1]) == .lt) : (gj -= 1) {
            const tmp = groups.items[gj];
            groups.items[gj] = groups.items[gj - 1];
            groups.items[gj - 1] = tmp;
        }
    }
    for (groups.items) |g| {
        try out.append(allocator, '-');
        try out.appendSlice(allocator, g);
    }
}

/// §3.2.1 bcp47 deprecated type aliases that cross a subtag boundary
/// (`islamicc` → `islamic-civil`, `ethiopic-amete-alem` → `ethioaa`), matched
/// against the whole joined key-type group.
fn uKeywordGroupAlias(group: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, group, "ca-islamicc")) return "ca-islamic-civil";
    if (std.mem.eql(u8, group, "ca-ethiopic-amete-alem")) return "ca-ethioaa";
    return null;
}

fn appendUnicodeKeywords(
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u8),
    keywords: *std.ArrayListUnmanaged([]const u8),
) !void {
    // §3.2 UTS #35 — a Unicode keyword is key (alphanum{2}) followed
    // by zero or more types (alphanum{3,8}). Sort by KEY for canonical
    // form, so `hc-h11-ca-abc` → `ca-abc-hc-h11`, not by each segment
    // (which would scramble "hc-h11" into "h11-hc").
    const items = keywords.items;
    if (items.len == 0) return;
    var groups: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (groups.items) |g| allocator.free(g);
        groups.deinit(allocator);
    }
    var i: usize = 0;
    while (i < items.len) {
        if (items[i].len != 2) {
            // Stray non-key segment — emit it alone (defensive; the
            // canonicaliser only reaches here on a structurally valid
            // tag, so this should not trigger).
            try groups.append(allocator, try allocator.dupe(u8, items[i]));
            i += 1;
            continue;
        }
        var end = i + 1;
        while (end < items.len and items[end].len != 2) : (end += 1) {}
        // §3.2.1 — canonicalise the type values, then drop a default `true`
        // type on a boolean key. Build the surviving segment list (key first).
        const key = items[i];
        var segs: std.ArrayListUnmanaged([]const u8) = .empty;
        defer segs.deinit(allocator);
        try segs.append(allocator, key);
        for (items[i + 1 .. end]) |raw_type| {
            const canon = canonicalUnicodeType(key, raw_type);
            // A single type value `true` canonicalises to the bare key for
            // every key (`und-u-kn-true` → `und-u-kn`, `de-u-kf-true` →
            // `de-u-kf`) — UTS #35 Annex C canonicalizing syntax.
            if (end - i == 2 and std.mem.eql(u8, canon, "true")) continue;
            try segs.append(allocator, canon);
        }
        // Concatenate the surviving segments with '-'.
        var total: usize = 0;
        for (segs.items) |s| total += s.len;
        total += segs.items.len - 1; // separators
        const buf = try allocator.alloc(u8, total);
        var pos: usize = 0;
        for (segs.items, 0..) |s, idx| {
            if (idx > 0) {
                buf[pos] = '-';
                pos += 1;
            }
            @memcpy(buf[pos .. pos + s.len], s);
            pos += s.len;
        }
        // §3.2.1 bcp47 type aliases whose source or target spans subtag
        // boundaries — rewrite the joined group.
        if (uKeywordGroupAlias(buf)) |alias| {
            allocator.free(buf);
            try groups.append(allocator, try allocator.dupe(u8, alias));
        } else {
            try groups.append(allocator, buf);
        }
        i = end;
    }
    // Sort groups by full string (keys are 2-char alpha, so this is
    // sort-by-key for the common case).
    var gi: usize = 1;
    while (gi < groups.items.len) : (gi += 1) {
        var gj = gi;
        while (gj > 0 and std.mem.order(u8, groups.items[gj], groups.items[gj - 1]) == .lt) : (gj -= 1) {
            const tmp = groups.items[gj];
            groups.items[gj] = groups.items[gj - 1];
            groups.items[gj - 1] = tmp;
        }
    }
    for (groups.items) |g| {
        try out.append(allocator, '-');
        try out.appendSlice(allocator, g);
    }
}

/// §9.2.13 DefaultLocale.
pub fn defaultLocale() []const u8 {
    return default_locale;
}

/// Structural build treats every structurally valid tag as available
/// (§9.1 AvailableLocales — implementation-defined; we accept all
/// valid tags so resolution is identity + default fallback).
pub fn isAvailableLocale(tag: []const u8) bool {
    return isStructurallyValidLanguageTag(tag);
}

/// §9.2.2 BestAvailableLocale — walk candidate and truncate subtags
/// until a hit; structural: any valid prefix of the tag itself.
pub fn bestAvailableLocale(available_unused: void, locale: []const u8) ?[]const u8 {
    _ = available_unused;
    if (!isStructurallyValidLanguageTag(locale)) return null;
    // Truncate from the right on '-' until we find a valid language-only
    // or full tag (always valid if input was valid).
    return locale;
}

/// §9.2.3 LookupMatcher — structural: pick first requested locale that
/// is structurally valid, else default.
pub fn lookupMatcher(requested: []const []const u8) []const u8 {
    for (requested) |loc| {
        if (isStructurallyValidLanguageTag(loc)) return loc;
    }
    return default_locale;
}

/// §9.2.4 BestFitMatcher — same as LookupMatcher without ICU.
pub fn bestFitMatcher(requested: []const []const u8) []const u8 {
    return lookupMatcher(requested);
}

pub const ResolvedLocale = struct {
    locale: []const u8,
    data_locale: []const u8,
};

/// §9.2.7 ResolveLocale — structural: match, then apply option overrides
/// for known keys by appending unicode extension keywords when absent.
pub fn resolveLocale(
    allocator: std.mem.Allocator,
    requested: []const []const u8,
    matcher: LocaleMatcher,
    relevant_extension_keys: []const []const u8,
    options_locale_data: ?*const std.StringHashMapUnmanaged([]const u8),
) !ResolvedLocale {
    _ = relevant_extension_keys;
    const r = switch (matcher) {
        .lookup => lookupMatcher(requested),
        .best_fit => bestFitMatcher(requested),
    };
    var found = try canonicalizeUnicodeLocaleId(allocator, r) catch try allocator.dupe(u8, default_locale);
    errdefer allocator.free(found);

    if (options_locale_data) |opts| {
        // Append u- extensions from options not already present.
        var need_u = !std.mem.containsAtLeast(u8, found, 1, "-u-");
        var it = opts.iterator();
        while (it.next()) |entry| {
            const key = entry.key_ptr.*;
            const val = entry.value_ptr.*;
            if (val.len == 0) continue;
            // Skip if key already in locale unicode extension (simple scan).
            var needle_buf: [16]u8 = undefined;
            const needle = std.fmt.bufPrint(&needle_buf, "-{s}-", .{key}) catch continue;
            if (std.mem.indexOf(u8, found, needle) != null) continue;
            if (need_u) {
                const with_u = try std.fmt.allocPrint(allocator, "{s}-u", .{found});
                allocator.free(found);
                found = with_u;
                need_u = false;
            }
            const with_kv = try std.fmt.allocPrint(allocator, "{s}-{s}-{s}", .{ found, key, val });
            allocator.free(found);
            found = with_kv;
        }
        if (!need_u) {
            // Re-canonicalize after extension append.
            const recanon = canonicalizeUnicodeLocaleId(allocator, found) catch found;
            if (recanon.ptr != found.ptr) {
                allocator.free(found);
                found = recanon;
            }
        }
    }

    const data = try allocator.dupe(u8, found);
    return .{ .locale = found, .data_locale = data };
}

/// Extract the base name (language-script-region-variants, no extensions).
pub fn localeBaseName(allocator: std.mem.Allocator, locale: []const u8) ![]const u8 {
    var end = locale.len;
    var i: usize = 0;
    while (i + 1 < locale.len) : (i += 1) {
        if (locale[i] == '-' and i + 2 < locale.len and locale[i + 2] == '-' and isAlphanum(locale[i + 1])) {
            // Singleton extension starts.
            end = i;
            break;
        }
        if (locale[i] == '-' and (locale[i + 1] == 'x' or locale[i + 1] == 'X') and (i + 2 >= locale.len or locale[i + 2] == '-')) {
            end = i;
            break;
        }
    }
    return try allocator.dupe(u8, locale[0..end]);
}

/// Unicode extension keyword value for `key` (2-char), or null.
pub fn unicodeExtensionValue(locale: []const u8, key: []const u8) ?[]const u8 {
    if (key.len != 2) return null;
    // A `-u-` inside the private-use (`-x-`) sequence is opaque, not a real
    // Unicode extension — truncate there before searching.
    const search = if (std.mem.indexOf(u8, locale, "-x-")) |x| locale[0..x] else locale;
    const u_idx = std.mem.indexOf(u8, search, "-u-") orelse return null;
    var rest = search[u_idx + 3 ..];
    while (rest.len > 0) {
        // Next singleton extension ends the u- block.
        if (rest.len >= 2 and rest[1] == '-' and isAlphanum(rest[0]) and rest[0] != 'u') break;
        const dash = std.mem.indexOfScalar(u8, rest, '-');
        const seg = if (dash) |d| rest[0..d] else rest;
        if (seg.len == 2 and std.mem.eql(u8, seg, key)) {
            if (dash == null) return ""; // key without value
            const after = rest[dash.? + 1 ..];
            // §3.2 UTS #35 — the type is a SEQUENCE of alphanum{3,8}
            // subtags ("islamic-civil"); span until the next 2-char key,
            // a singleton, or the end of the tag.
            var span: usize = 0;
            var vals = std.mem.splitScalar(u8, after, '-');
            while (vals.next()) |val| {
                if (val.len < 3) break; // next key (2) or singleton (1)
                span = (@intFromPtr(val.ptr) - @intFromPtr(after.ptr)) + val.len;
            }
            if (span == 0) return ""; // key immediately followed by a key
            return after[0..span];
        }
        if (dash == null) break;
        rest = rest[dash.? + 1 ..];
    }
    return null;
}

/// Language / script / region / variants accessors for Intl.Locale.
pub fn parseLocaleComponents(allocator: std.mem.Allocator, locale: []const u8) !LocaleSlots {
    var slots: LocaleSlots = .{};
    errdefer slots.deinit(allocator);

    slots.locale = try allocator.dupe(u8, locale);
    slots.base_name = try localeBaseName(allocator, locale);

    var parts = std.mem.splitScalar(u8, slots.base_name, '-');
    var idx: usize = 0;
    var variants_list: std.ArrayListUnmanaged(u8) = .empty;
    defer variants_list.deinit(allocator);

    while (parts.next()) |part| {
        if (part.len == 0) continue;
        if (idx == 0) {
            slots.language = try allocator.dupe(u8, part);
        } else if (part.len == 4 and allAlpha(part) and slots.script.len == 0) {
            slots.script = try allocator.dupe(u8, part);
        } else if (((part.len == 2 and allAlpha(part)) or (part.len == 3 and allDigit(part))) and slots.region.len == 0) {
            slots.region = try allocator.dupe(u8, part);
        } else {
            if (variants_list.items.len > 0) try variants_list.append(allocator, '-');
            try variants_list.appendSlice(allocator, part);
        }
        idx += 1;
    }
    if (variants_list.items.len > 0) {
        slots.variants = try variants_list.toOwnedSlice(allocator);
    }

    if (unicodeExtensionValue(locale, "ca")) |v| slots.calendar = try allocator.dupe(u8, v);
    if (unicodeExtensionValue(locale, "co")) |v| slots.collation = try allocator.dupe(u8, v);
    if (unicodeExtensionValue(locale, "hc")) |v| slots.hour_cycle = try allocator.dupe(u8, v);
    if (unicodeExtensionValue(locale, "kf")) |v| slots.case_first = try allocator.dupe(u8, v);
    if (unicodeExtensionValue(locale, "kn")) |v| slots.numeric = std.mem.eql(u8, v, "true") or v.len == 0;
    if (unicodeExtensionValue(locale, "nu")) |v| slots.numbering_system = try allocator.dupe(u8, v);

    return slots;
}

// ── supportedValuesOf catalogs (structural static lists) ───────────────────

// The set required by the Intl Era/MonthCode supportedValuesOf fixture —
// canonical ids only, no aliases ("islamic" / "islamic-rgsa" are excluded by
// calendars-required-by-intl-era-monthcode.js). The emitter sorts defensively.
pub const supported_calendars = [_][]const u8{
    "buddhist", "chinese",  "coptic",  "dangi",         "ethioaa",      "ethiopic",
    "gregory",  "hebrew",   "indian",  "islamic-civil", "islamic-tbla", "islamic-umalqura",
    "iso8601",  "japanese", "persian", "roc",
};

pub const supported_collations = [_][]const u8{
    "compat",   "dict",   "emoji", "eor",    "phonebk", "phonetic", "pinyin", "reformed",
    "searchjl", "stroke", "trad",  "unihan", "zhuyin",
};

pub const supported_currencies = [_][]const u8{
    "AED", "AFN", "ALL", "AMD", "ANG", "AOA", "ARS", "AUD", "AWG", "AZN", "BAM", "BBD",
    "BDT", "BGN", "BHD", "BIF", "BMD", "BND", "BOB", "BRL", "BSD", "BTN", "BWP", "BYN",
    "BZD", "CAD", "CDF", "CHF", "CLP", "CNY", "COP", "CRC", "CUC", "CUP", "CVE", "CZK",
    "DJF", "DKK", "DOP", "DZD", "EGP", "ERN", "ETB", "EUR", "FJD", "FKP", "GBP", "GEL",
    "GHS", "GIP", "GMD", "GNF", "GTQ", "GYD", "HKD", "HNL", "HRK", "HTG", "HUF", "IDR",
    "ILS", "INR", "IQD", "IRR", "ISK", "JMD", "JOD", "JPY", "KES", "KGS", "KHR", "KMF",
    "KPW", "KRW", "KWD", "KYD", "KZT", "LAK", "LBP", "LKR", "LRD", "LSL", "LYD", "MAD",
    "MDL", "MGA", "MKD", "MMK", "MNT", "MOP", "MRU", "MUR", "MVR", "MWK", "MXN", "MYR",
    "MZN", "NAD", "NGN", "NIO", "NOK", "NPR", "NZD", "OMR", "PAB", "PEN", "PGK", "PHP",
    "PKR", "PLN", "PYG", "QAR", "RON", "RSD", "RUB", "RWF", "SAR", "SBD", "SCR", "SDG",
    "SEK", "SGD", "SHP", "SLE", "SOS", "SRD", "SSP", "STN", "SYP", "SZL", "THB", "TJS",
    "TMT", "TND", "TOP", "TRY", "TTD", "TWD", "TZS", "UAH", "UGX", "USD", "UYU", "UZS",
    "VES", "VND", "VUV", "WST", "XAF", "XCD", "XOF", "XPF", "YER", "ZAR", "ZMW", "ZWL",
};

pub const supported_numbering_systems = [_][]const u8{
    "adlm", "ahom",     "arab",     "arabext",  "bali",     "beng",     "bhks",     "brah",    "cakm", "cham",
    "deva", "diak",     "fullwide", "gong",     "gonm",     "gujr",     "guru",     "hanidec", "hmng", "hmnp",
    "java", "kali",     "kawi",     "khmr",     "knda",     "lana",     "lanatham", "laoo",    "latn", "lepc",
    "limb", "mathbold", "mathdbl",  "mathmono", "mathsanb", "mathsans", "mlym",     "modi",    "mong", "mroo",
    "mtei", "mymr",     "mymrepka", "mymrpao",  "mymrshan", "mymrtlng", "nagm",     "newa",    "nkoo", "olck",
    "orya", "osma",     "outlined", "rohg",     "saur",     "segment",  "shrd",     "sind",    "sinh", "sora",
    "sund", "takr",     "talu",     "tamldec",  "telu",     "thai",     "tibt",     "tirh",    "tnsa", "vaii",
    "wara", "wcho",
};

pub const supported_time_zones = [_][]const u8{
    "UTC",
    "America/New_York",
    "America/Los_Angeles",
    "America/Chicago",
    "America/Denver",
    "Europe/London",
    "Europe/Paris",
    "Europe/Berlin",
    "Asia/Tokyo",
    "Asia/Shanghai",
    "Asia/Kolkata",
    "Australia/Sydney",
    "Pacific/Auckland",
};

pub const supported_units = [_][]const u8{
    "acre",        "bit",         "byte",     "celsius",           "centimeter", "day",        "degree",      "fahrenheit",
    "fluid-ounce", "foot",        "gallon",   "gigabit",           "gigabyte",   "gram",       "hectare",     "hour",
    "inch",        "kilobit",     "kilobyte", "kilogram",          "kilometer",  "liter",      "megabit",     "megabyte",
    "meter",       "microsecond", "mile",     "mile-scandinavian", "milliliter", "millimeter", "millisecond", "minute",
    "month",       "nanosecond",  "ounce",    "percent",           "petabyte",   "pound",      "second",      "stone",
    "terabit",     "terabyte",    "week",     "yard",              "year",
};

// ── Tests ──────────────────────────────────────────────────────────────────

test "isStructurallyValidLanguageTag accepts common tags" {
    try std.testing.expect(isStructurallyValidLanguageTag("en"));
    try std.testing.expect(isStructurallyValidLanguageTag("en-US"));
    try std.testing.expect(isStructurallyValidLanguageTag("zh-Hant-TW"));
    try std.testing.expect(isStructurallyValidLanguageTag("en-u-ca-gregory"));
    try std.testing.expect(!isStructurallyValidLanguageTag(""));
    try std.testing.expect(!isStructurallyValidLanguageTag("en_US"));
    try std.testing.expect(!isStructurallyValidLanguageTag("-en"));
}

test "canonicalizeUnicodeLocaleId normalizes case" {
    const a = try canonicalizeUnicodeLocaleId(std.testing.allocator, "EN-us");
    defer std.testing.allocator.free(a);
    try std.testing.expectEqualStrings("en-US", a);
}
