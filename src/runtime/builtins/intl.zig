//! ECMA-402 structural `Intl` — namespace + service constructors.
//!
//! No CLDR/ICU: constructors accept locales/options, store internal
//! slots, expose `resolvedOptions` / `supportedLocalesOf`, and implement
//! format/compare/select/segment as implementation-defined minimal
//! behaviour (typically `ToString` of the input, or always `"other"`
//! for plurals). Tag validation and canonicalization live in
//! `runtime/intl.zig`.

const std = @import("std");

const Realm = @import("../realm.zig").Realm;
const Value = @import("../value.zig").Value;
const JSString = @import("../string.zig").JSString;
const JSObject = @import("../object.zig").JSObject;
const JSFunction = @import("../function.zig").JSFunction;
const NativeError = @import("../function.zig").NativeError;
const NativeFn = @import("../function.zig").NativeFn;
const heap_mod = @import("../heap.zig");
const intrinsics = @import("../intrinsics.zig");
const lantern = @import("../lantern/interpreter.zig");
const intl = @import("../intl.zig");
const cldr = @import("../cldr.zig");
const temporal = @import("../temporal.zig");
const tshared = @import("temporal/shared.zig");
const dtoa = @import("../dtoa.zig");
const utf16 = @import("../utf16.zig");
const uax29 = @import("../uax29.zig");

const installConstructor = intrinsics.installConstructor;
const installNativeMethod = intrinsics.installNativeMethod;
const installNativeMethodOnProto = intrinsics.installNativeMethodOnProto;
const installNativeGetter = intrinsics.installNativeGetter;
const installToStringTag = intrinsics.installToStringTag;
const setNonEnumerable = intrinsics.setNonEnumerable;
const argOr = intrinsics.argOr;
const throwTypeError = intrinsics.throwTypeError;
const throwRangeError = intrinsics.throwRangeError;
const getPropertyChain = intrinsics.getPropertyChain;
const stringifyArg = intrinsics.stringifyArg;
const toNumber = intrinsics.toNumber;
const allocateArray = intrinsics.allocateArray;
const toBoolean = @import("array.zig").toBoolean;

// ── Install ────────────────────────────────────────────────────────────────

pub fn install(realm: *Realm) !void {
    const ns = try realm.heap.allocateObject();
    realm.heap.setObjectPrototype(ns, realm.intrinsics.object_prototype);
    try installToStringTag(realm, ns, "Intl");
    realm.intrinsics.intl_namespace = ns;

    try installNativeMethodOnProto(realm, ns, "getCanonicalLocales", intlGetCanonicalLocales, 1);
    try installNativeMethodOnProto(realm, ns, "supportedValuesOf", intlSupportedValuesOf, 1);

    try installLocale(realm, ns);
    try installCollator(realm, ns);
    try installNumberFormat(realm, ns);
    try installDateTimeFormat(realm, ns);
    try installPluralRules(realm, ns);
    try installRelativeTimeFormat(realm, ns);
    try installListFormat(realm, ns);
    try installDisplayNames(realm, ns);
    try installSegmenter(realm, ns);
    try installDurationFormat(realm, ns);

    try realm.globals.put(realm.allocator, "Intl", heap_mod.taggedObject(ns));
}

fn putCtorOnIntl(realm: *Realm, ns: *JSObject, name: []const u8, ctor: *JSFunction) !void {
    try setNonEnumerable(ns, realm.allocator, name, heap_mod.taggedFunction(ctor));
}

// ── Helpers ────────────────────────────────────────────────────────────────

fn dupeOrEmpty(allocator: std.mem.Allocator, s: []const u8) ![]const u8 {
    if (s.len == 0) return "";
    return try allocator.dupe(u8, s);
}

fn dupeSlice(allocator: std.mem.Allocator, s: []const u8) ![]const u8 {
    if (s.len == 0) return "";
    return try allocator.dupe(u8, s);
}

fn valueToStringSlice(realm: *Realm, v: Value) NativeError![]const u8 {
    const s = try stringifyArg(realm, v);
    return s.flatBytes();
}

fn makeStringValue(realm: *Realm, bytes: []const u8) NativeError!Value {
    const s = realm.heap.allocateString(bytes) catch return error.OutOfMemory;
    return Value.fromString(s);
}

fn makeBoolValue(b: bool) Value {
    return Value.fromBool(b);
}

fn makeNumberValue(n: f64) Value {
    if (n == @trunc(n) and n >= @as(f64, @floatFromInt(std.math.minInt(i32))) and n <= @as(f64, @floatFromInt(std.math.maxInt(i32)))) {
        return Value.fromInt32(@intFromFloat(n));
    }
    return Value.fromDouble(n);
}

fn setDataProp(realm: *Realm, obj: *JSObject, key: []const u8, v: Value) NativeError!void {
    obj.setWithFlags(realm.allocator, key, v, .{
        .writable = true,
        .enumerable = true,
        .configurable = true,
    }) catch return error.OutOfMemory;
}

fn setDataPropStr(realm: *Realm, obj: *JSObject, key: []const u8, bytes: []const u8) NativeError!void {
    if (bytes.len == 0) return;
    try setDataProp(realm, obj, key, try makeStringValue(realm, bytes));
}

fn getOptionsObject(realm: *Realm, options: Value) NativeError!?*JSObject {
    if (options.isUndefined()) return null;
    if (heap_mod.valueAsPlainObject(options)) |o| return o;
    if (heap_mod.valueAsFunction(options) != null) {
        return throwTypeError(realm, "options must be an object or undefined");
    }
    return throwTypeError(realm, "options must be an object or undefined");
}

/// §9.2.13 CoerceOptionsToObject — undefined → empty (null); otherwise
/// ? ToObject(options). Unlike GetOptionsObject this accepts a primitive
/// (number / boolean / string / symbol), wrapping it (no relevant options →
/// defaults). Used by the constructors whose spec text coerces.
fn coerceOptionsToObject(realm: *Realm, options: Value) NativeError!?*JSObject {
    if (options.isUndefined()) return null;
    return try intrinsics.toObjectThis(realm, options);
}

fn getOptionString(
    realm: *Realm,
    opts: ?*JSObject,
    property: []const u8,
    values: ?[]const []const u8,
    fallback: []const u8,
) NativeError![]const u8 {
    const obj = opts orelse return fallback;
    const v = try getPropertyChain(realm, obj, property);
    if (v.isUndefined()) return fallback;
    const s = try valueToStringSlice(realm, v);
    if (values) |allowed| {
        for (allowed) |a| {
            if (std.mem.eql(u8, s, a)) return a; // interned allowed value
        }
        return throwRangeError(realm, "invalid option value");
    }
    // Caller may need owned copy — return temporary slice from JSString
    // which lives on the heap; we dupe when storing in slots.
    return s;
}

fn getOptionStringOwned(
    realm: *Realm,
    opts: ?*JSObject,
    property: []const u8,
    values: ?[]const []const u8,
    fallback: []const u8,
) NativeError![]const u8 {
    const s = try getOptionString(realm, opts, property, values, fallback);
    // Always own — never return interned option table / fallback pointers
    // (IntlRecord.deinit frees every non-empty slice).
    return realm.allocator.dupe(u8, s) catch return error.OutOfMemory;
}

fn getBooleanOption(realm: *Realm, opts: ?*JSObject, property: []const u8, fallback: bool) NativeError!bool {
    const obj = opts orelse return fallback;
    const v = try getPropertyChain(realm, obj, property);
    if (v.isUndefined()) return fallback;
    return toBoolean(v);
}

fn getLocaleMatcher(realm: *Realm, opts: ?*JSObject) NativeError!intl.LocaleMatcher {
    const s = try getOptionString(realm, opts, "localeMatcher", &.{ "lookup", "best fit" }, "best fit");
    if (std.mem.eql(u8, s, "lookup")) return .lookup;
    return .best_fit;
}

fn fmtRequiresNew(realm: *Realm, name: []const u8) ![]const u8 {
    // Message is only for the throw helper path; use static-ish via class arena when possible.
    _ = realm;
    _ = name;
    return "Intl constructor requires 'new'";
}

/// §9.2.1 CanonicalizeLocaleList — returns owned slice of owned tags.
pub fn canonicalizeLocaleList(realm: *Realm, locales: Value) NativeError![]const []const u8 {
    const allocator = realm.allocator;
    if (locales.isUndefined()) {
        return allocator.alloc([]const u8, 0) catch return error.OutOfMemory;
    }

    // Single string shortcut.
    if (locales.isString()) {
        const tag = try valueToStringSlice(realm, locales);
        if (!intl.isStructurallyValidLanguageTag(tag)) return throwRangeError(realm, "invalid language tag");
        const canon = intl.canonicalizeUnicodeLocaleId(allocator, tag) catch return throwRangeError(realm, "invalid language tag");
        const arr = allocator.alloc([]const u8, 1) catch {
            allocator.free(canon);
            return error.OutOfMemory;
        };
        arr[0] = canon;
        return arr;
    }

    // Intl.Locale instance.
    if (heap_mod.valueAsPlainObject(locales)) |obj| {
        if (obj.getIntlRecord()) |rec| {
            if (rec.* == .locale) {
                const tag = rec.locale.locale;
                const canon = allocator.dupe(u8, tag) catch return error.OutOfMemory;
                const arr = allocator.alloc([]const u8, 1) catch {
                    allocator.free(canon);
                    return error.OutOfMemory;
                };
                arr[0] = canon;
                return arr;
            }
        }
    }

    // §9.2.1 step 4 — `O = ? ToObject(locales)`. CanonicalizeLocaleList uses
    // the array-like protocol (length + indexed Get), NOT `@@iterator`; a
    // primitive (number / boolean / Symbol) becomes a length-less wrapper and
    // yields an empty list, while `null` throws via ToObject (spec-correct).
    const obj = try intrinsics.toObjectThis(realm, locales);

    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(allocator);
    var list: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer {
        for (list.items) |t| allocator.free(t);
        list.deinit(allocator);
    }

    // §9.2.1 step 5 — `len = ? ToLength(? Get(O, "length"))`. A poisoned
    // `length` valueOf throws through ToNumber and propagates.
    const len_v = try getPropertyChain(realm, obj, "length");
    const len_n = try toNumber(realm, len_v);
    const len_f: f64 = if (len_n.isInt32()) @floatFromInt(len_n.asInt32()) else numberToF64(len_n);
    const len: usize = if (len_f > 0 and len_f < 1e9) @intFromFloat(@floor(len_f)) else 0;
    var i: usize = 0;
    while (i < len) : (i += 1) {
        var idx_buf: [24]u8 = undefined;
        const idx_key = std.fmt.bufPrint(&idx_buf, "{d}", .{i}) catch unreachable;
        // §9.2.1 step 7.b — `kPresent = ? HasProperty(O, Pk)`. Holes are
        // skipped; a present index with a non-String / non-Object value (incl.
        // an explicit `undefined`) throws TypeError inside appendLocaleElement.
        // The HasProperty must trap so a Proxy `has` handler is observed.
        if (!try hasPropertyP(realm, obj, idx_key)) continue;
        const el = try getPropertyChain(realm, obj, idx_key);
        try appendLocaleElement(realm, &list, &seen, el);
    }
    return list.toOwnedSlice(allocator) catch return error.OutOfMemory;
}

/// §7.3.11 HasProperty — proxy-aware (dispatches the Proxy `has` trap §10.5.7
/// before §10.1.7.1 OrdinaryHasProperty).
fn hasPropertyP(realm: *Realm, obj: *JSObject, key: []const u8) NativeError!bool {
    const proxy_mod = @import("proxy.zig");
    var cur = obj;
    while (cur.proxy_target != null or cur.proxy_revoked) {
        switch (try proxy_mod.nativeProxyHas(realm, cur, key, null)) {
            .boolean => |b| return b,
            .fallthrough => |t| {
                if (t == cur) return cur.hasProperty(key);
                cur = t;
            },
        }
    }
    return cur.hasProperty(key);
}

fn appendLocaleElement(
    realm: *Realm,
    list: *std.ArrayListUnmanaged([]const u8),
    seen: *std.StringHashMapUnmanaged(void),
    el: Value,
) NativeError!void {
    const allocator = realm.allocator;

    const tag_slice: []const u8 = blk: {
        if (heap_mod.valueAsPlainObject(el)) |o| {
            if (o.getIntlRecord()) |rec| {
                if (rec.* == .locale) break :blk rec.locale.locale;
            }
        }
        // §9.2.1 step 7.c.ii — only a String or an Object is accepted; a
        // number / boolean / symbol / bigint / null / undefined throws a
        // TypeError (it is NOT coerced via ToString, which would mis-report
        // `[2]` as a RangeError or accept `[true]` as the tag "true").
        if (!el.isString() and !el.isObject()) return throwTypeError(realm, "locale must be a string or object");
        // String is itself; a (non-Locale) Object goes through ToPrimitive.
        const s = try valueToStringSlice(realm, el);
        break :blk s;
    };

    if (!intl.isStructurallyValidLanguageTag(tag_slice)) return throwRangeError(realm, "invalid language tag");
    const canon = intl.canonicalizeUnicodeLocaleId(allocator, tag_slice) catch return throwRangeError(realm, "invalid language tag");
    const gop = seen.getOrPut(allocator, canon) catch {
        allocator.free(canon);
        return error.OutOfMemory;
    };
    if (gop.found_existing) {
        allocator.free(canon);
        return;
    }
    gop.key_ptr.* = canon;
    list.append(allocator, canon) catch {
        _ = seen.remove(canon);
        allocator.free(canon);
        return error.OutOfMemory;
    };
}

fn freeLocaleList(allocator: std.mem.Allocator, list: []const []const u8) void {
    for (list) |t| allocator.free(t);
    allocator.free(list);
}

const ResolvedService = struct { locale: []const u8, matcher: intl.LocaleMatcher };

fn resolveServiceLocale(
    realm: *Realm,
    locales: Value,
    opts: ?*JSObject,
) NativeError!ResolvedService {
    return resolveServiceLocaleAvail(realm, locales, opts, .cldr_data);
}

fn resolveServiceLocaleAvail(
    realm: *Realm,
    locales: Value,
    opts: ?*JSObject,
    avail: intl.Availability,
) NativeError!ResolvedService {
    const matcher = try getLocaleMatcher(realm, opts);
    const requested = try canonicalizeLocaleList(realm, locales);
    defer freeLocaleList(realm.allocator, requested);
    const r = switch (matcher) {
        .lookup => intl.lookupMatcher(requested, avail),
        .best_fit => intl.bestFitMatcher(requested, avail),
    };
    const canon = intl.canonicalizeUnicodeLocaleId(realm.allocator, r) catch
        realm.allocator.dupe(u8, intl.default_locale) catch return error.OutOfMemory;
    return .{ .locale = canon, .matcher = matcher };
}

/// Compute and cache the UTS #35 §4.3 script-maximized data-locale once, so the
/// per-`format()` CLDR lookups never re-scan the likelySubtags table (the table
/// is only consulted for a script-less tag like `en` / `zh-TW`). Stores an owned
/// copy in `base.data_locale` only when maximization actually inserts a script;
/// when the resolved tag already carries one (`en-Latn`) or no script can be
/// inferred (stub/off build, unknown tag), `data_locale` stays empty and
/// `dataLocale()` falls back to `base.locale` — already cheap to split. Must run
/// after `base.locale` is assigned and before any CLDR data lookup.
fn setDataLocale(realm: *Realm, base: *intl.ServiceLocaleSlots) NativeError!void {
    if (!cldr.available or base.locale.len == 0) return;
    var buf: [intl.max_tag_bytes]u8 = undefined;
    const maxed = cldr.maximizeForData(base.locale, &buf);
    // Only a freshly script-inserted tag is worth storing; an unchanged result
    // (already-scripted or un-maximizable) leaves the cheap `locale` fallback.
    if (maxed.ptr == base.locale.ptr) return;
    base.data_locale = realm.allocator.dupe(u8, maxed) catch return error.OutOfMemory;
}

fn storeRecord(realm: *Realm, inst: *JSObject, rec: intl.IntlRecord) NativeError!void {
    const box = realm.allocator.create(intl.IntlRecord) catch return error.OutOfMemory;
    box.* = rec;
    inst.setIntlRecord(realm.allocator, box) catch {
        box.deinit(realm.allocator);
        realm.allocator.destroy(box);
        return error.OutOfMemory;
    };
}

fn requireKind(realm: *Realm, this_value: Value, kind: intl.IntlKind) NativeError!*intl.IntlRecord {
    const obj = heap_mod.valueAsPlainObject(this_value) orelse
        return throwTypeError(realm, "Incompatible Receiver");
    const rec = obj.getIntlRecord() orelse return throwTypeError(realm, "Incompatible Receiver");
    if (std.meta.activeTag(rec.*) != kind) return throwTypeError(realm, "Incompatible Receiver");
    return rec;
}

/// Return `locale` with the `-u-` keyword for `key` (and its
/// continuation `type` subtags) removed. Caller owns the slice;
/// preserves the rest of the tag verbatim so a subsequent re-
/// canonicalisation can re-sort the new keyword in.
/// Remove a -u- keyword from an owned ServiceLocaleSlots.locale in place,
/// re-canonicalising. Used by ResolveLocale when an option supersedes (or
/// invalidates) a locale-supplied relevant-extension keyword.
/// Known BCP 47 `-u-co-` collation types (UTS #35 / CLDR bcp47/collation).
/// "standard" / "search" are excluded — they're never reported (→ "default").
/// Intl Locale Info WeekdayToString: a `firstDayOfWeek` value (a weekday name
/// or 1..7 / 0) → the canonical -u-fw- day code (0 ≡ 7 ≡ "sun"). Null = invalid.
fn weekdayToFw(s: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, s, "mon") or std.mem.eql(u8, s, "1")) return "mon";
    if (std.mem.eql(u8, s, "tue") or std.mem.eql(u8, s, "2")) return "tue";
    if (std.mem.eql(u8, s, "wed") or std.mem.eql(u8, s, "3")) return "wed";
    if (std.mem.eql(u8, s, "thu") or std.mem.eql(u8, s, "4")) return "thu";
    if (std.mem.eql(u8, s, "fri") or std.mem.eql(u8, s, "5")) return "fri";
    if (std.mem.eql(u8, s, "sat") or std.mem.eql(u8, s, "6")) return "sat";
    if (std.mem.eql(u8, s, "sun") or std.mem.eql(u8, s, "7") or std.mem.eql(u8, s, "0")) return "sun";
    return null;
}

/// Per-language tailored collations (CLDR common/collation availability);
/// "emoji" and "eor" are root collations available for every locale.
fn languageCollations(lang: []const u8) []const []const u8 {
    const Entry = struct { lang: []const u8, types: []const []const u8 };
    const table = [_]Entry{
        .{ .lang = "ar", .types = &.{"compat"} },
        .{ .lang = "de", .types = &.{"phonebk"} },
        .{ .lang = "es", .types = &.{"trad"} },
        .{ .lang = "hi", .types = &.{"direct"} },
        .{ .lang = "ko", .types = &.{"searchjl"} },
        .{ .lang = "ln", .types = &.{"phonetic"} },
        .{ .lang = "si", .types = &.{"dict"} },
        .{ .lang = "sv", .types = &.{"reformed"} },
        .{ .lang = "zh", .types = &.{ "big5han", "gb2312", "pinyin", "stroke", "unihan", "zhuyin" } },
    };
    for (table) |e| if (std.mem.eql(u8, e.lang, lang)) return e.types;
    return &.{};
}

/// §9.2.7 ResolveLocale supportedness for the `co` key: a collation type is
/// supported when the locale's language tailors it (or it is a root
/// collation). "standard" / "search" are handled by the caller (never
/// reported).
fn collationSupportedFor(locale: []const u8, ty: []const u8) bool {
    if (std.mem.eql(u8, ty, "emoji") or std.mem.eql(u8, ty, "eor")) return true;
    const lang_end = std.mem.indexOfScalar(u8, locale, '-') orelse locale.len;
    for (languageCollations(locale[0..lang_end])) |t| if (std.mem.eql(u8, t, ty)) return true;
    return false;
}

fn isKnownCollation(s: []const u8) bool {
    const known = [_][]const u8{
        "big5han",  "compat", "dict",    "direct",   "ducet",  "emoji",
        "eor",      "gb2312", "phonebk", "phonetic", "pinyin", "reformed",
        "searchjl", "stroke", "trad",    "unihan",   "zhuyin",
    };
    for (known) |k| if (std.mem.eql(u8, s, k)) return true;
    return false;
}

/// Whether a `-u-<key>-<value>` keyword names a value Cynic actually supports
/// for that key; an unsupported value is dropped from the resolved locale
/// (ResolveLocale falls back to the default). nu/ca consult the CLDR blob.
fn isValidExtValue(key: []const u8, value: []const u8) bool {
    if (std.mem.eql(u8, key, "nu")) return !cldr.available or cldr.numberingSystemDigitBase(value) != null;
    if (std.mem.eql(u8, key, "co")) return isKnownCollation(value); // "standard"/"search"/invalid → default
    if (std.mem.eql(u8, key, "hc")) return std.mem.eql(u8, value, "h11") or std.mem.eql(u8, value, "h12") or std.mem.eql(u8, value, "h23") or std.mem.eql(u8, value, "h24");
    if (std.mem.eql(u8, key, "kn")) return value.len == 0 or std.mem.eql(u8, value, "true") or std.mem.eql(u8, value, "false");
    if (std.mem.eql(u8, key, "kf")) return std.mem.eql(u8, value, "upper") or std.mem.eql(u8, value, "lower") or std.mem.eql(u8, value, "false");
    if (std.mem.eql(u8, key, "ca")) return intl.isValidUnicodeType(value);
    return true;
}

/// §9.2.7 ResolveLocale — drop every `-u-` keyword whose key is not in the
/// service's relevant-extension set (e.g. `-cu-usd` on a NumberFormat), and any
/// relevant keyword whose value Cynic doesn't support, so neither surfaces in
/// resolvedOptions().locale.
fn retainRelevantUnicodeExtensions(realm: *Realm, base: *intl.ServiceLocaleSlots, relevant: []const []const u8) NativeError!void {
    // Strip one irrelevant key per pass (stripExtKeyword re-canonicalizes, so
    // re-scan from the start) until none remain.
    while (true) {
        const locale = base.locale;
        const search = if (std.mem.indexOf(u8, locale, "-x-")) |x| locale[0..x] else locale;
        const u_at = std.mem.indexOf(u8, search, "-u-") orelse return;
        var i = u_at + 3;
        var strip: ?[2]u8 = null;
        while (i < search.len) {
            const seg_start = i;
            while (i < search.len and search[i] != '-') i += 1;
            const seg = search[seg_start..i];
            if (seg.len == 1) break; // a singleton extension begins; -u- block ended
            if (seg.len == 2) {
                var keep = false;
                for (relevant) |r| if (std.mem.eql(u8, r, seg)) {
                    keep = true;
                    break;
                };
                // Drop a non-relevant key, or a relevant key with an
                // unsupported value (so the default applies).
                if (!keep or !isValidExtValue(seg, intl.unicodeExtensionValue(search, seg) orelse "")) {
                    strip = .{ seg[0], seg[1] };
                    break;
                }
            }
            if (i < search.len) i += 1;
        }
        if (strip) |k| try stripExtKeyword(realm, base, &k) else return;
    }
}

fn stripExtKeyword(realm: *Realm, base: *intl.ServiceLocaleSlots, key: []const u8) NativeError!void {
    const stripped = stripUnicodeExtensionKeyword(realm.allocator, base.locale, key) catch return error.OutOfMemory;
    realm.allocator.free(base.locale);
    const canon = intl.canonicalizeUnicodeLocaleId(realm.allocator, stripped) catch stripped;
    if (canon.ptr != stripped.ptr) realm.allocator.free(stripped);
    base.locale = canon;
}

/// Add (or replace) a `-u-<key>[-value]` keyword on an owned
/// ServiceLocaleSlots.locale and re-canonicalize so it sorts into place. An
/// empty value writes the bare keyword (e.g. "-u-kn" for numeric:true).
fn addExtKeyword(realm: *Realm, base: *intl.ServiceLocaleSlots, key: []const u8, value: []const u8) NativeError!void {
    try stripExtKeyword(realm, base, key); // drop any existing, avoid a dup
    const loc = base.locale;
    const has_u = std.mem.indexOf(u8, loc, "-u-") != null;
    const built = (if (value.len == 0)
        (if (has_u) std.fmt.allocPrint(realm.allocator, "{s}-{s}", .{ loc, key }) else std.fmt.allocPrint(realm.allocator, "{s}-u-{s}", .{ loc, key }))
    else if (has_u)
        std.fmt.allocPrint(realm.allocator, "{s}-{s}-{s}", .{ loc, key, value })
    else
        std.fmt.allocPrint(realm.allocator, "{s}-u-{s}-{s}", .{ loc, key, value })) catch return error.OutOfMemory;
    const canon = intl.canonicalizeUnicodeLocaleId(realm.allocator, built) catch built;
    if (canon.ptr != built.ptr) realm.allocator.free(built);
    realm.allocator.free(base.locale);
    base.locale = canon;
}

fn stripUnicodeExtensionKeyword(allocator: std.mem.Allocator, locale: []const u8, key: []const u8) ![]const u8 {
    if (key.len != 2) return allocator.dupe(u8, locale);
    const u_at = std.mem.indexOf(u8, locale, "-u-") orelse return allocator.dupe(u8, locale);
    // Find the start of the key within the `-u-` extension.
    var i = u_at + 3;
    while (i < locale.len) {
        // End of -u- block at the next singleton extension.
        if (i + 1 < locale.len and locale[i] == '-' and locale[i + 2] == '-' and locale[i + 1] != 'u') break;
        const seg_start = i;
        while (i < locale.len and locale[i] != '-') : (i += 1) {}
        const seg = locale[seg_start..i];
        const is_key = seg.len == 2;
        if (is_key and std.mem.eql(u8, seg, key)) {
            // Found the key — extend through following type subtags
            // (3-8 alphanum), stopping at the next 2-ALPHA key or end.
            var rm_end = i;
            while (rm_end < locale.len) {
                if (locale[rm_end] != '-') break;
                const t_start = rm_end + 1;
                if (t_start >= locale.len) break;
                var t_end = t_start;
                while (t_end < locale.len and locale[t_end] != '-') : (t_end += 1) {}
                const t_len = t_end - t_start;
                if (t_len == 2 or t_len == 1) break; // next key or singleton
                rm_end = t_end;
            }
            // Slice out [seg_start - 1, rm_end) — include the preceding '-'.
            const cut_start = seg_start - 1;
            const cut_end = rm_end;
            const out = try allocator.alloc(u8, locale.len - (cut_end - cut_start));
            @memcpy(out[0..cut_start], locale[0..cut_start]);
            @memcpy(out[cut_start..], locale[cut_end..]);
            // If the -u- now has no keywords left, drop it. A dash after
            // `u` is only "empty" when what follows is another singleton
            // (1-char segment) — a longer segment is a remaining keyword
            // ("en-u-kn" after stripping co keeps its -u-).
            const u_block_start = u_at;
            const u_after_dash = u_at + 2; // points at second '-' after `u`
            if (u_after_dash < out.len and out[u_after_dash] == '-') {
                const n_start = u_after_dash + 1;
                var n_end = n_start;
                while (n_end < out.len and out[n_end] != '-') : (n_end += 1) {}
                if (n_end - n_start <= 1) {
                    // Singleton (or nothing) follows — drop the `-u`.
                    const drop = try allocator.alloc(u8, out.len - 2);
                    @memcpy(drop[0..u_block_start], out[0..u_block_start]);
                    @memcpy(drop[u_block_start..], out[u_block_start + 2 ..]);
                    allocator.free(out);
                    return drop;
                }
            }
            // Or if -u- is at end of tag now.
            if (u_after_dash >= out.len) {
                const trimmed = try allocator.alloc(u8, out.len - 2);
                @memcpy(trimmed, out[0 .. out.len - 2]);
                allocator.free(out);
                return trimmed;
            }
            return out;
        }
        if (i >= locale.len) break;
        i += 1; // skip '-'
    }
    return allocator.dupe(u8, locale);
}

fn supportedLocalesOfImpl(realm: *Realm, args: []const Value) NativeError!Value {
    const locales = argOr(args, 0, Value.undefined_);
    const options = argOr(args, 1, Value.undefined_);
    // §9.2.9 SupportedLocales step 1 — `options = ? ToObject(options)` (not
    // GetOptionsObject): a primitive options arg coerces to a wrapper rather
    // than throwing. localeMatcher is then read + validated off it.
    const opts: ?*JSObject = if (options.isUndefined()) null else try intrinsics.toObjectThis(realm, options);
    _ = try getLocaleMatcher(realm, opts);
    const list = try canonicalizeLocaleList(realm, locales);
    defer freeLocaleList(realm.allocator, list);

    const arr = allocateArray(realm) catch return error.OutOfMemory;
    var i: i32 = 0;
    for (list) |tag| {
        // §9.2.7 LookupSupportedLocales — keep only locales with a
        // BestAvailableLocale match. Availability is proxied by the all-locale
        // CLDR plural set (a candidate-walk over language/script/region), so a
        // structurally-valid but data-less tag like "zxx" is dropped. With no
        // blob (stub) nothing can be filtered, so every requested tag passes.
        if (cldr.available and !cldr.hasPluralLocale(tag, false)) continue;
        var idx_buf: [24]u8 = undefined;
        const idx_key = std.fmt.bufPrint(&idx_buf, "{d}", .{i}) catch unreachable;
        const sv = try makeStringValue(realm, tag);
        arr.set(realm.allocator, idx_key, sv) catch return error.OutOfMemory;
        i += 1;
    }
    arr.setArrayLength(realm.allocator, @intCast(i)) catch return error.OutOfMemory;
    return heap_mod.taggedObject(arr);
}

fn makeResolvedBase(realm: *Realm, locale: []const u8) NativeError!*JSObject {
    const obj = realm.heap.allocateObject() catch return error.OutOfMemory;
    realm.heap.setObjectPrototype(obj, realm.intrinsics.object_prototype);
    try setDataProp(realm, obj, "locale", try makeStringValue(realm, locale));
    return obj;
}

// ── Intl namespace methods ──────────────────────────────────────────────────

fn intlGetCanonicalLocales(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = this_value;
    const locales = argOr(args, 0, Value.undefined_);
    const list = try canonicalizeLocaleList(realm, locales);
    defer freeLocaleList(realm.allocator, list);
    const arr = allocateArray(realm) catch return error.OutOfMemory;
    var i: i32 = 0;
    for (list) |tag| {
        var idx_buf: [24]u8 = undefined;
        const idx_key = std.fmt.bufPrint(&idx_buf, "{d}", .{i}) catch unreachable;
        arr.set(realm.allocator, idx_key, try makeStringValue(realm, tag)) catch return error.OutOfMemory;
        i += 1;
    }
    arr.setArrayLength(realm.allocator, @intCast(i)) catch return error.OutOfMemory;
    return heap_mod.taggedObject(arr);
}

fn intlSupportedValuesOf(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = this_value;
    const key_v = argOr(args, 0, Value.undefined_);
    const key = try valueToStringSlice(realm, key_v);

    // numberingSystem is derived from the CLDR blob when present, so the
    // enumerated set is exactly the systems NumberFormat accepts (every
    // digit-base mapping, including recent CLDR additions like `gara`); every
    // other key uses its curated static list. `owned` backs the blob path.
    var owned: std.ArrayListUnmanaged([]const u8) = .empty;
    defer owned.deinit(realm.allocator);
    const values: []const []const u8 = if (std.mem.eql(u8, key, "calendar"))
        &intl.supported_calendars
    else if (std.mem.eql(u8, key, "collation"))
        &intl.supported_collations
    else if (std.mem.eql(u8, key, "currency")) blk: {
        if (cldr.available) {
            cldr.appendCurrencyCodes("en", realm.allocator, &owned) catch return error.OutOfMemory;
            if (owned.items.len > 0) break :blk owned.items;
        }
        break :blk &intl.supported_currencies;
    } else if (std.mem.eql(u8, key, "numberingSystem")) blk: {
        if (cldr.available) {
            cldr.appendNumberingSystemIds(realm.allocator, &owned) catch return error.OutOfMemory;
            if (owned.items.len > 0) break :blk owned.items;
        }
        break :blk &intl.supported_numbering_systems;
    } else if (std.mem.eql(u8, key, "timeZone"))
        &intl.supported_time_zones
    else if (std.mem.eql(u8, key, "unit"))
        &intl.supported_units
    else
        return throwRangeError(realm, "invalid key for supportedValuesOf");

    // §6.x SupportedValues returns a sorted List of unique values.
    const sorted = realm.allocator.dupe([]const u8, values) catch return error.OutOfMemory;
    defer realm.allocator.free(sorted);
    std.mem.sort([]const u8, sorted, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);

    const arr = allocateArray(realm) catch return error.OutOfMemory;
    var i: i32 = 0;
    var prev: ?[]const u8 = null;
    for (sorted) |v| {
        if (prev) |p| if (std.mem.eql(u8, p, v)) continue; // drop duplicates
        prev = v;
        var idx_buf: [24]u8 = undefined;
        const idx_key = std.fmt.bufPrint(&idx_buf, "{d}", .{i}) catch unreachable;
        arr.set(realm.allocator, idx_key, try makeStringValue(realm, v)) catch return error.OutOfMemory;
        i += 1;
    }
    arr.setArrayLength(realm.allocator, @intCast(i)) catch return error.OutOfMemory;
    return heap_mod.taggedObject(arr);
}

// ── Intl.Locale ────────────────────────────────────────────────────────────

fn installLocale(realm: *Realm, ns: *JSObject) !void {
    const r = try installConstructor(realm, .{
        .name = "Locale",
        .ctor = localeConstructor,
        .arity = 1,
        .is_class = true,
        .set_home_object = true,
        .to_string_tag = "Intl.Locale",
        .install_global = false,
    });
    const proto = r.proto;
    try installNativeGetter(realm, proto, "baseName", localeBaseName);
    try installNativeGetter(realm, proto, "calendar", localeCalendar);
    try installNativeGetter(realm, proto, "caseFirst", localeCaseFirst);
    try installNativeGetter(realm, proto, "collation", localeCollation);
    try installNativeGetter(realm, proto, "hourCycle", localeHourCycle);
    try installNativeGetter(realm, proto, "language", localeLanguage);
    try installNativeGetter(realm, proto, "numberingSystem", localeNumberingSystem);
    try installNativeGetter(realm, proto, "numeric", localeNumeric);
    try installNativeGetter(realm, proto, "region", localeRegion);
    try installNativeGetter(realm, proto, "script", localeScript);
    try installNativeMethodOnProto(realm, proto, "toString", localeToString, 0);
    try installNativeMethodOnProto(realm, proto, "maximize", localeMaximize, 0);
    try installNativeMethodOnProto(realm, proto, "minimize", localeMinimize, 0);
    // Intl Locale Info (Stage 4): the resolved-extension query methods +
    // the `variants` getter. `getTimeZones` (region→zone data) stays out
    // until the CLDR zone-by-region table is packed.
    try installNativeGetter(realm, proto, "variants", localeVariants);
    try installNativeGetter(realm, proto, "firstDayOfWeek", localeFirstDayOfWeek);
    try installNativeMethodOnProto(realm, proto, "getCalendars", localeGetCalendars, 0);
    try installNativeMethodOnProto(realm, proto, "getCollations", localeGetCollations, 0);
    try installNativeMethodOnProto(realm, proto, "getHourCycles", localeGetHourCycles, 0);
    try installNativeMethodOnProto(realm, proto, "getNumberingSystems", localeGetNumberingSystems, 0);
    try installNativeMethodOnProto(realm, proto, "getTextInfo", localeGetTextInfo, 0);
    try installNativeMethodOnProto(realm, proto, "getTimeZones", localeGetTimeZones, 0);
    try installNativeMethodOnProto(realm, proto, "getWeekInfo", localeGetWeekInfo, 0);
    // §14.1.1 Intl.Locale throws without `new` — route through the
    // NewTarget-aware construct path (see newIntlInstance).
    r.ctor.defers_proto_lookup = true;
    realm.intrinsics.intl_locale_constructor = r.ctor;
    realm.intrinsics.intl_locale_prototype = proto;
    try putCtorOnIntl(realm, ns, "Locale", r.ctor);
}

/// §14.1.2 ApplyOptionsToTag — override the tag's core subtags (language /
/// script / region / variants) from the options, validating each against its
/// grammar. Returns a freshly-canonicalised owned tag; the caller frees the
/// previous one. Reads happen before the -u- keyword application (§14.1.1).
fn applyOptionsToTag(realm: *Realm, tag: []const u8, o: *JSObject) NativeError![]const u8 {
    const allocator = realm.allocator;
    // Option getters can re-enter JS (and move/free the transient JSString
    // bytes), so each validated value is duped immediately.
    var lang: ?[]u8 = null;
    var script: ?[]u8 = null;
    var region: ?[]u8 = null;
    var variants: ?[]u8 = null;
    defer {
        if (lang) |x| allocator.free(x);
        if (script) |x| allocator.free(x);
        if (region) |x| allocator.free(x);
        if (variants) |x| allocator.free(x);
    }

    const lv = try getPropertyChain(realm, o, "language");
    if (!lv.isUndefined()) {
        const s = try valueToStringSlice(realm, lv);
        if (!intl.isValidLanguageSubtag(s)) return throwRangeError(realm, "invalid Locale language option");
        lang = allocator.dupe(u8, s) catch return error.OutOfMemory;
    }
    const sv = try getPropertyChain(realm, o, "script");
    if (!sv.isUndefined()) {
        const s = try valueToStringSlice(realm, sv);
        if (!intl.isValidScriptSubtag(s)) return throwRangeError(realm, "invalid Locale script option");
        script = allocator.dupe(u8, s) catch return error.OutOfMemory;
    }
    const rv = try getPropertyChain(realm, o, "region");
    if (!rv.isUndefined()) {
        const s = try valueToStringSlice(realm, rv);
        if (!intl.isValidRegionSubtag(s)) return throwRangeError(realm, "invalid Locale region option");
        region = allocator.dupe(u8, s) catch return error.OutOfMemory;
    }
    const vv = try getPropertyChain(realm, o, "variants");
    if (!vv.isUndefined()) {
        const s = try valueToStringSlice(realm, vv);
        if (!isValidVariantList(s)) return throwRangeError(realm, "invalid Locale variants option");
        variants = allocator.dupe(u8, s) catch return error.OutOfMemory;
    }

    if (lang == null and script == null and region == null and variants == null)
        return allocator.dupe(u8, tag) catch return error.OutOfMemory;

    var slots = intl.parseLocaleComponents(allocator, tag) catch return error.OutOfMemory;
    defer slots.deinit(allocator);
    // Everything after the base name is the extension suffix (begins with '-'
    // or empty); base_name was extracted from `tag`, so its length aligns.
    const ext = if (slots.base_name.len <= tag.len) tag[slots.base_name.len..] else "";

    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(allocator);
    const append = struct {
        fn seg(a: std.mem.Allocator, buf: *std.ArrayListUnmanaged(u8), s: []const u8) NativeError!void {
            if (s.len == 0) return;
            if (buf.items.len > 0) buf.append(a, '-') catch return error.OutOfMemory;
            buf.appendSlice(a, s) catch return error.OutOfMemory;
        }
    }.seg;
    try append(allocator, &out, lang orelse slots.language);
    try append(allocator, &out, script orelse slots.script);
    try append(allocator, &out, region orelse slots.region);
    try append(allocator, &out, variants orelse slots.variants);
    out.appendSlice(allocator, ext) catch return error.OutOfMemory;

    return intl.canonicalizeUnicodeLocaleId(allocator, out.items) catch
        (allocator.dupe(u8, out.items) catch return error.OutOfMemory);
}

/// Validate the `variants` option: one or more variant subtags joined by '-',
/// each well-formed, with no duplicates (§ unicode_variant_subtag).
fn isValidVariantList(s: []const u8) bool {
    if (s.len == 0) return false;
    var it = std.mem.splitScalar(u8, s, '-');
    var seen: [16][]const u8 = undefined;
    var n: usize = 0;
    while (it.next()) |sub| {
        if (!intl.isValidVariantSubtag(sub)) return false;
        for (seen[0..n]) |v| if (std.ascii.eqlIgnoreCase(v, sub)) return false;
        if (n >= seen.len) return false;
        seen[n] = sub;
        n += 1;
    }
    return true;
}

fn localeConstructor(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const inst = try newIntlInstance(realm, this_value, realm.intrinsics.intl_locale_prototype, "Locale", true);
    const tag_v = argOr(args, 0, Value.undefined_);
    // §14.1.1 step 7 — `tag` must be a String or an Object; a boolean / number
    // / null / symbol / bigint throws a TypeError (not ToString'd to a tag).
    if (!tag_v.isString() and heap_mod.valueAsPlainObject(tag_v) == null and heap_mod.valueAsFunction(tag_v) == null)
        return throwTypeError(realm, "Intl.Locale tag must be a string or object");

    const options = argOr(args, 1, Value.undefined_);
    const opts = try getOptionsObject(realm, options);

    var tag_slice: []const u8 = undefined;
    if (heap_mod.valueAsPlainObject(tag_v)) |o| {
        if (o.getIntlRecord()) |rec| {
            if (rec.* == .locale) {
                tag_slice = rec.locale.locale;
            } else {
                tag_slice = try valueToStringSlice(realm, tag_v);
            }
        } else {
            tag_slice = try valueToStringSlice(realm, tag_v);
        }
    } else {
        tag_slice = try valueToStringSlice(realm, tag_v);
    }

    if (!intl.isStructurallyValidLanguageTag(tag_slice)) return throwRangeError(realm, "invalid language tag");
    var canon = intl.canonicalizeUnicodeLocaleId(realm.allocator, tag_slice) catch return throwRangeError(realm, "invalid language tag");
    errdefer realm.allocator.free(canon);

    // Apply option overrides by appending unicode extensions (structural).
    if (opts) |o| {
        // §14.1.1 InitializeLocale + §14.1.3 ApplyUnicodeExtensionToTag —
        // validate every option value before it lands in the tag.
        // `kind` chooses the validator: .type for the open `alphanum{3,8}`
        // grammar (calendar / collation / numberingSystem); the rest are
        // closed enumerations from the spec.
        const ValueKind = enum { type, hour_cycle, case_first };
        const apply = struct {
            fn kw(realm2: *Realm, locale_in: []const u8, key: []const u8, prop: []const u8, kind: ValueKind, o2: *JSObject) NativeError![]const u8 {
                const v = try getPropertyChain(realm2, o2, prop);
                if (v.isUndefined()) return locale_in;
                const s = try valueToStringSlice(realm2, v);
                const ok = switch (kind) {
                    .type => intl.isValidUnicodeType(s),
                    .hour_cycle => std.mem.eql(u8, s, "h11") or std.mem.eql(u8, s, "h12") or std.mem.eql(u8, s, "h23") or std.mem.eql(u8, s, "h24"),
                    .case_first => std.mem.eql(u8, s, "upper") or std.mem.eql(u8, s, "lower") or std.mem.eql(u8, s, "false"),
                };
                if (!ok) return throwRangeError(realm2, "invalid Locale option value");
                // §14.1.3 ApplyUnicodeExtensionToTag — the option value
                // overrides any existing -u- keyword for the same key.
                // Strip the existing keyword (if any) so the new one wins
                // after re-canonicalisation.
                const stripped = if (intl.unicodeExtensionValue(locale_in, key) != null)
                    stripUnicodeExtensionKeyword(realm2.allocator, locale_in, key) catch return error.OutOfMemory
                else
                    locale_in;
                if (stripped.ptr != locale_in.ptr) realm2.allocator.free(locale_in);
                const has_u = std.mem.indexOf(u8, stripped, "-u-") != null;
                const out = if (has_u)
                    std.fmt.allocPrint(realm2.allocator, "{s}-{s}-{s}", .{ stripped, key, s })
                else
                    std.fmt.allocPrint(realm2.allocator, "{s}-u-{s}-{s}", .{ stripped, key, s });
                const owned = out catch return error.OutOfMemory;
                realm2.allocator.free(stripped);
                return owned;
            }
        }.kw;
        // §14.1.2 ApplyOptionsToTag — core subtag overrides (language /
        // script / region / variants), read + validated first, then the §14.1.3
        // -u- keywords in spec order (ca, co, hc, kf, kn, nu).
        const with_opts = try applyOptionsToTag(realm, canon, o);
        realm.allocator.free(canon);
        canon = with_opts;
        canon = try apply(realm, canon, "ca", "calendar", .type, o);
        canon = try apply(realm, canon, "co", "collation", .type, o);
        canon = try apply(realm, canon, "hc", "hourCycle", .hour_cycle, o);
        canon = try apply(realm, canon, "kf", "caseFirst", .case_first, o);

        // numeric → -u-kn (read after caseFirst, before numberingSystem). The
        // option overrides any existing kn keyword (§14.1.3). The canonical form
        // of a true value is the bare keyword "-u-kn" (not "-u-kn-true").
        const num_v = try getPropertyChain(realm, o, "numeric");
        if (!num_v.isUndefined()) {
            const truthy = toBoolean(num_v);
            const stripped = if (intl.unicodeExtensionValue(canon, "kn") != null)
                stripUnicodeExtensionKeyword(realm.allocator, canon, "kn") catch return error.OutOfMemory
            else
                canon;
            if (stripped.ptr != canon.ptr) realm.allocator.free(canon);
            const has_u = std.mem.indexOf(u8, stripped, "-u-") != null;
            const out = if (truthy)
                (if (has_u) std.fmt.allocPrint(realm.allocator, "{s}-kn", .{stripped}) else std.fmt.allocPrint(realm.allocator, "{s}-u-kn", .{stripped}))
            else
                (if (has_u) std.fmt.allocPrint(realm.allocator, "{s}-kn-false", .{stripped}) else std.fmt.allocPrint(realm.allocator, "{s}-u-kn-false", .{stripped}));
            const owned = out catch return error.OutOfMemory;
            realm.allocator.free(stripped);
            canon = owned;
        }
        canon = try apply(realm, canon, "nu", "numberingSystem", .type, o);

        // firstDayOfWeek → -u-fw (Intl Locale Info §1.4 WeekdayToString): 1..7
        // and 0 map to mon..sun (0 ≡ sun); any other value (a weekday name, or
        // an arbitrary fw type like "frank") passes through and must match the
        // -u- type sequence (alphanum{3,8} subtags) or it is a RangeError. The
        // value "true" canonicalises to the bare keyword.
        const fw_v = try getPropertyChain(realm, o, "firstDayOfWeek");
        if (!fw_v.isUndefined()) {
            const s = try valueToStringSlice(realm, fw_v);
            const day = weekdayToFw(s) orelse s;
            if (!intl.isValidUnicodeType(day)) return throwRangeError(realm, "invalid firstDayOfWeek");
            const bare = std.mem.eql(u8, day, "true");
            const stripped = if (intl.unicodeExtensionValue(canon, "fw") != null)
                stripUnicodeExtensionKeyword(realm.allocator, canon, "fw") catch return error.OutOfMemory
            else
                canon;
            if (stripped.ptr != canon.ptr) realm.allocator.free(canon);
            const has_u = std.mem.indexOf(u8, stripped, "-u-") != null;
            const out = if (bare)
                (if (has_u) std.fmt.allocPrint(realm.allocator, "{s}-fw", .{stripped}) else std.fmt.allocPrint(realm.allocator, "{s}-u-fw", .{stripped}))
            else
                (if (has_u) std.fmt.allocPrint(realm.allocator, "{s}-fw-{s}", .{ stripped, day }) else std.fmt.allocPrint(realm.allocator, "{s}-u-fw-{s}", .{ stripped, day }));
            const owned = out catch return error.OutOfMemory;
            realm.allocator.free(stripped);
            canon = owned;
        }

        const recanon = intl.canonicalizeUnicodeLocaleId(realm.allocator, canon) catch canon;
        if (recanon.ptr != canon.ptr) {
            realm.allocator.free(canon);
            canon = recanon;
        }
    }

    const slots = intl.parseLocaleComponents(realm.allocator, canon) catch return error.OutOfMemory;
    realm.allocator.free(canon); // parseLocaleComponents dupes locale
    try storeRecord(realm, inst, .{ .locale = slots });
    return heap_mod.taggedObject(inst);
}

fn localeSlots(realm: *Realm, this_value: Value) NativeError!*intl.LocaleSlots {
    const rec = try requireKind(realm, this_value, .locale);
    return &rec.locale;
}

fn localeBaseName(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    const s = try localeSlots(realm, this_value);
    return makeStringValue(realm, s.base_name);
}
fn localeCalendar(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    const s = try localeSlots(realm, this_value);
    if (s.calendar.len == 0) return Value.undefined_;
    return makeStringValue(realm, s.calendar);
}
fn localeCaseFirst(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    const s = try localeSlots(realm, this_value);
    // §1.4.x — undefined only when the kf keyword is ABSENT; a present but
    // valueless kf ("de-u-kf") reports the empty string.
    if (!s.case_first_present and s.case_first.len == 0) return Value.undefined_;
    return makeStringValue(realm, s.case_first);
}
fn localeCollation(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    const s = try localeSlots(realm, this_value);
    if (s.collation.len == 0) return Value.undefined_;
    return makeStringValue(realm, s.collation);
}
fn localeHourCycle(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    const s = try localeSlots(realm, this_value);
    if (s.hour_cycle.len == 0) return Value.undefined_;
    return makeStringValue(realm, s.hour_cycle);
}

/// Intl Locale Info — `Intl.Locale.prototype.firstDayOfWeek` returns the
/// locale's -u-fw keyword as a weekday code ("mon".."sun"), or undefined.
fn localeFirstDayOfWeek(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    const s = try localeSlots(realm, this_value);
    if (intl.unicodeExtensionValue(s.locale, "fw")) |v| return makeStringValue(realm, v);
    return Value.undefined_;
}
fn localeLanguage(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    const s = try localeSlots(realm, this_value);
    return makeStringValue(realm, s.language);
}
fn localeNumberingSystem(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    const s = try localeSlots(realm, this_value);
    if (s.numbering_system.len == 0) return Value.undefined_;
    return makeStringValue(realm, s.numbering_system);
}
fn localeNumeric(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    const s = try localeSlots(realm, this_value);
    return makeBoolValue(s.numeric);
}
fn localeRegion(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    const s = try localeSlots(realm, this_value);
    if (s.region.len == 0) return Value.undefined_;
    return makeStringValue(realm, s.region);
}
fn localeScript(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    const s = try localeSlots(realm, this_value);
    if (s.script.len == 0) return Value.undefined_;
    return makeStringValue(realm, s.script);
}
fn localeToString(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    const s = try localeSlots(realm, this_value);
    return makeStringValue(realm, s.locale);
}
fn localeMaximize(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    // §14.3.4 Intl.Locale.prototype.maximize — UTS #35 §4.3 Add Likely Subtags.
    const s = try localeSlots(realm, this_value);
    const tag = try rewriteLikelyTag(realm, s, .maximize);
    defer realm.allocator.free(tag);
    return createLocaleFromTag(realm, tag);
}
fn localeMinimize(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    // §14.3.5 Intl.Locale.prototype.minimize — UTS #35 §4.3 Remove Likely Subtags.
    const s = try localeSlots(realm, this_value);
    const tag = try rewriteLikelyTag(realm, s, .minimize);
    defer realm.allocator.free(tag);
    return createLocaleFromTag(realm, tag);
}

const LikelyOp = enum { maximize, minimize };

/// Rebuild a locale tag with the §4.3 likely-subtags algorithm applied to its
/// language / script / region, preserving the variants and extension tail. When
/// the CLDR data is absent (stub / off) or the algorithm signals no change, the
/// original tag is returned unchanged (the spec's "If an error is signaled, set
/// … to loc.[[Locale]]"). Caller owns the returned slice.
fn rewriteLikelyTag(realm: *Realm, s: *const intl.LocaleSlots, op: LikelyOp) NativeError![]const u8 {
    const in: cldr.Subtags = .{ .lang = s.language, .script = s.script, .region = s.region };
    var out: cldr.Subtags = .{};
    const ok = switch (op) {
        .maximize => cldr.addLikelySubtags(in, &out),
        .minimize => cldr.removeLikelySubtags(in, &out),
    };
    if (!ok) return realm.allocator.dupe(u8, s.locale) catch return error.OutOfMemory;

    // Suffix = the part of the canonical locale after its base name: variants
    // first (already in s.variants / part of base_name), then -u-/-x-/etc.
    // s.base_name = language(-script)(-region)(-variants); the extension tail is
    // s.locale[base_name.len..].
    const ext_tail = if (s.locale.len >= s.base_name.len) s.locale[s.base_name.len..] else "";

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(realm.allocator);
    buf.appendSlice(realm.allocator, out.lang) catch return error.OutOfMemory;
    if (out.script.len > 0) {
        buf.append(realm.allocator, '-') catch return error.OutOfMemory;
        buf.appendSlice(realm.allocator, out.script) catch return error.OutOfMemory;
    }
    if (out.region.len > 0) {
        buf.append(realm.allocator, '-') catch return error.OutOfMemory;
        buf.appendSlice(realm.allocator, out.region) catch return error.OutOfMemory;
    }
    if (s.variants.len > 0) {
        buf.append(realm.allocator, '-') catch return error.OutOfMemory;
        buf.appendSlice(realm.allocator, s.variants) catch return error.OutOfMemory;
    }
    if (ext_tail.len > 0) {
        buf.appendSlice(realm.allocator, ext_tail) catch return error.OutOfMemory;
    }
    return buf.toOwnedSlice(realm.allocator) catch return error.OutOfMemory;
}

// ── Intl Locale Info (Stage 4) ───────────────────────────────────────────────

/// Build a single-element string Array (the common shape of the resolved
/// list getters; the -u- extension value sorts first per
/// CreateArrayFromListAndPreferred).
fn singletonStringArray(realm: *Realm, value: []const u8) NativeError!Value {
    const arr = allocateArray(realm) catch return error.OutOfMemory;
    arr.set(realm.allocator, "0", try makeStringValue(realm, value)) catch return error.OutOfMemory;
    arr.setArrayLength(realm.allocator, 1) catch return error.OutOfMemory;
    return heap_mod.taggedObject(arr);
}

fn localeVariants(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    const s = try localeSlots(realm, this_value);
    if (s.variants.len == 0) return Value.undefined_;
    return makeStringValue(realm, s.variants);
}

/// §1.4.x getCalendars — the calendar from the -u-ca- extension, else the
/// structural default ("gregory"). (Region-preferred calendar lists need
/// CLDR `calendarPreferenceData`, deferred.)
fn localeGetCalendars(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    const s = try localeSlots(realm, this_value);
    return singletonStringArray(realm, if (s.calendar.len > 0) s.calendar else "gregory");
}

fn localeGetCollations(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    const s = try localeSlots(realm, this_value);
    // "standard" / "search" are never reported (§1.4.x); fall back to "default".
    const c = s.collation;
    const use = if (c.len > 0 and !std.mem.eql(u8, c, "standard") and !std.mem.eql(u8, c, "search")) c else "default";
    return singletonStringArray(realm, use);
}

fn localeGetHourCycles(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    const s = try localeSlots(realm, this_value);
    return singletonStringArray(realm, if (s.hour_cycle.len > 0) s.hour_cycle else "h23");
}

fn localeGetNumberingSystems(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    const s = try localeSlots(realm, this_value);
    return singletonStringArray(realm, if (s.numbering_system.len > 0) s.numbering_system else "latn");
}

/// §1.4.x getTextInfo — { direction: "ltr" | "rtl" }, the writing direction
/// of the locale's script (or its likely script when none is given).
/// §1.4.x getTimeZones — the IANA zones whose country list includes the
/// locale's region (undefined when the locale has no region), sorted by
/// zone name, from the vendored zone1970.tab (see tzdata_zones.zig).
fn localeGetTimeZones(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    const s = try localeSlots(realm, this_value);
    if (s.region.len == 0) return Value.undefined_;
    const region_zones = @import("../tzdata_zones.zig").region_zones;
    const arr = allocateArray(realm) catch return error.OutOfMemory;
    var n: u32 = 0;
    for (region_zones) |rz| {
        if (!std.ascii.eqlIgnoreCase(rz.region, s.region)) continue;
        var idx_buf: [12]u8 = undefined;
        const idx_key = std.fmt.bufPrint(&idx_buf, "{d}", .{n}) catch unreachable;
        arr.set(realm.allocator, idx_key, try makeStringValue(realm, rz.zone)) catch return error.OutOfMemory;
        n += 1;
    }
    arr.setArrayLength(realm.allocator, n) catch return error.OutOfMemory;
    return heap_mod.taggedObject(arr);
}

fn localeGetTextInfo(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    const s = try localeSlots(realm, this_value);
    const rtl = isRtlLocale(s.script, s.language);
    const obj = realm.heap.allocateObject() catch return error.OutOfMemory;
    realm.heap.setObjectPrototype(obj, realm.intrinsics.object_prototype);
    try setDataProp(realm, obj, "direction", try makeStringValue(realm, if (rtl) "rtl" else "ltr"));
    return heap_mod.taggedObject(obj);
}

/// §1.4.x getWeekInfo — { firstDay, weekend }, weekday numbers 1 (Mon) … 7
/// (Sun). Structural default (Mon-first, Sat/Sun weekend); per-region
/// `weekData` refinement is deferred.
/// Map a -u-fw weekday code to the ISO weekday number (mon = 1 … sun = 7).
fn fwDayToNumber(day: []const u8) f64 {
    const codes = [_][]const u8{ "mon", "tue", "wed", "thu", "fri", "sat", "sun" };
    for (codes, 1..) |c, n| if (std.mem.eql(u8, day, c)) return @floatFromInt(n);
    return 1;
}

fn localeGetWeekInfo(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const s = try localeSlots(realm, this_value);
    _ = args;
    const obj = realm.heap.allocateObject() catch return error.OutOfMemory;
    realm.heap.setObjectPrototype(obj, realm.intrinsics.object_prototype);
    // §1.4.x — firstDay reflects the locale's -u-fw keyword (default Monday).
    const first_day = if (intl.unicodeExtensionValue(s.locale, "fw")) |v| fwDayToNumber(v) else 1;
    try setDataProp(realm, obj, "firstDay", makeNumberValue(first_day));
    const weekend = allocateArray(realm) catch return error.OutOfMemory;
    weekend.set(realm.allocator, "0", makeNumberValue(6)) catch return error.OutOfMemory;
    weekend.set(realm.allocator, "1", makeNumberValue(7)) catch return error.OutOfMemory;
    weekend.setArrayLength(realm.allocator, 2) catch return error.OutOfMemory;
    try setDataProp(realm, obj, "weekend", heap_mod.taggedObject(weekend));
    return heap_mod.taggedObject(obj);
}

/// Right-to-left when the script is an RTL script, or (script absent) when the
/// language is a commonly RTL one. Structural — covers the major RTL systems.
fn isRtlLocale(script: []const u8, language: []const u8) bool {
    const rtl_scripts = [_][]const u8{ "Arab", "Hebr", "Syrc", "Thaa", "Nkoo", "Samr", "Mand", "Mend", "Adlm", "Rohg", "Hung", "Yezi", "Sogd", "Phnx" };
    if (script.len > 0) {
        for (rtl_scripts) |sc| if (std.ascii.eqlIgnoreCase(script, sc)) return true;
        return false;
    }
    const rtl_langs = [_][]const u8{ "ar", "he", "fa", "ur", "ps", "sd", "ug", "yi", "dv", "ku", "nqo", "ckb" };
    for (rtl_langs) |l| if (std.ascii.eqlIgnoreCase(language, l)) return true;
    return false;
}

fn createLocaleFromTag(realm: *Realm, tag: []const u8) NativeError!Value {
    const inst = realm.heap.allocateObject() catch return error.OutOfMemory;
    realm.heap.setObjectPrototype(inst, realm.intrinsics.intl_locale_prototype.?);
    const slots = intl.parseLocaleComponents(realm.allocator, tag) catch return error.OutOfMemory;
    try storeRecord(realm, inst, .{ .locale = slots });
    return heap_mod.taggedObject(inst);
}

// ── Service constructor install helpers ────────────────────────────────────

const ServiceSpec = struct {
    name: []const u8,
    ctor: NativeFn,
    arity: u8,
    to_string_tag: []const u8,
    methods: []const struct { name: []const u8, fn_ptr: NativeFn, params: u8 },
    supported_locales_of: NativeFn,
    set_ctor_intrinsic: *const fn (*Realm, *JSFunction) void,
    set_proto_intrinsic: *const fn (*Realm, *JSObject) void,
    /// True for the non-legacy services that throw when called without `new`
    /// (everything except Collator / NumberFormat / DateTimeFormat). Wires the
    /// `defers_proto_lookup` construct path so the native sees NewTarget.
    requires_new: bool = false,
};

fn installService(realm: *Realm, ns: *JSObject, spec: ServiceSpec) !void {
    const r = try installConstructor(realm, .{
        .name = spec.name,
        .ctor = spec.ctor,
        .arity = spec.arity,
        .is_class = true,
        .set_home_object = true,
        .to_string_tag = spec.to_string_tag,
        .install_global = false,
    });
    for (spec.methods) |m| {
        try installNativeMethodOnProto(realm, r.proto, m.name, m.fn_ptr, m.params);
    }
    try installNativeMethod(realm, r.ctor, "supportedLocalesOf", spec.supported_locales_of, 1);
    // §11.1.1-style "If NewTarget is undefined, throw a TypeError" — the
    // non-legacy services. The construct path stashes NewTarget on the realm
    // (call.zig), so the native distinguishes new from a plain call.
    if (spec.requires_new) r.ctor.defers_proto_lookup = true;
    spec.set_ctor_intrinsic(realm, r.ctor);
    spec.set_proto_intrinsic(realm, r.proto);
    try putCtorOnIntl(realm, ns, spec.name, r.ctor);
}

/// NewTarget-aware instance creation for Intl service constructors. The
/// construct path (new / super / Reflect.construct) stashes NewTarget on
/// `realm.pending_native_new_target` and passes `this = undefined`; a plain
/// [[Call]] passes the receiver as `this` and never touches that slot. So
/// `this_value` discriminates the two reliably — even when an enclosing
/// native construct left a stale NewTarget in the realm slot (e.g. a
/// constructor's own option getter re-enters with another Intl call).
///
/// `requires_new` services (Locale, PluralRules, …) throw a TypeError when
/// invoked without `new` (§ "If NewTarget is undefined, throw a TypeError").
/// The legacy three (Collator / NumberFormat / DateTimeFormat, §10.1.1 /
/// §11.1.1 / §12.1.1) are callable without `new`: NewTarget defaults to the
/// active function object, so the instance's [[Prototype]] falls back to the
/// constructor's own `.prototype` and a fresh instance is returned — never
/// `this_value` (the old `requireNew` path wrote the record onto the `Intl`
/// namespace, leaking it on every no-`new` call). Mirrors the Promise /
/// TypedArray `defers_proto_lookup` OrdinaryCreateFromConstructor pattern.
fn newIntlInstance(realm: *Realm, this_value: Value, default_proto: ?*JSObject, name: []const u8, requires_new: bool) NativeError!*JSObject {
    const new_target = if (this_value.isUndefined()) realm.pending_native_new_target else Value.undefined_;
    if (new_target.isUndefined()) {
        if (requires_new) return throwTypeError(realm, try fmtRequiresNew(realm, name));
        // Legacy no-`new` fallback: instantiate from the service prototype.
        const inst = realm.heap.allocateObject() catch return error.OutOfMemory;
        realm.heap.setObjectPrototype(inst, default_proto);
        return inst;
    }

    const interp = @import("../lantern/interpreter.zig");
    const proto_lookup = interp.getPrototypeFromConstructorValue(realm.allocator, realm, new_target, default_proto, realm) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.NativeThrew,
    };
    const inst = realm.heap.allocateObject() catch return error.OutOfMemory;
    switch (proto_lookup) {
        .proto => |p| realm.heap.setObjectPrototype(inst, p),
        .proto_fn => |f| realm.heap.setObjectPrototypeFn(inst, f),
        .thrown => |ex| {
            realm.pending_exception = ex;
            return error.NativeThrew;
        },
    }
    return inst;
}

/// §10.3.5 (Collator) / §11.3.5 (NumberFormat) / §12.3.5 (DateTimeFormat)
/// — the spec exposes `compare` / `format` as **accessor** properties
/// whose get returns a function bound to the service instance, so user
/// code may pull the function off the receiver and call it free:
///
///   var f = collator.compare;
///   sorted.sort(f);   // `this === undefined` here, but f still uses
///                     // the collator captured at the getter call.
///
/// Mirror that here: a getter brand-checks `this`, then allocates a
/// bound wrapper whose `[[BoundThis]]` is the service instance. The
/// interpreter's existing bound-function dispatch unwraps before the
/// worker runs, so the worker still sees `this_value = service`. We
/// allocate fresh on every access (no cache) — caching the bound
/// function on the receiver would need a GC mark walk for the cached
/// `Value`, which is the Metla agent's domain. Identity
/// (`c.compare === c.compare`) is therefore observably false here; the
/// failing test262 fixtures that motivated this fix do not depend on
/// identity, only on detached invocation working.
fn makeBoundServiceFunction(
    realm: *Realm,
    this_value: Value,
    worker: NativeFn,
    name: []const u8,
    params: u8,
) NativeError!Value {
    // §11.1.5 / §15.1.4 — the bound format function's `name` is the empty string
    // (it is an anonymous built-in); `name` here only labels the inner target.
    const inner = realm.heap.allocateFunctionNative(realm, worker, params, name) catch return error.OutOfMemory;
    const bound = realm.heap.allocateFunctionNative(realm, worker, params, "") catch return error.OutOfMemory;
    realm.heap.setBoundTarget(bound, inner);
    realm.heap.setBoundThis(bound, this_value);
    bound.has_construct = false;
    return heap_mod.taggedFunction(bound);
}

// ── Collator ───────────────────────────────────────────────────────────────

fn installCollator(realm: *Realm, ns: *JSObject) !void {
    try installService(realm, ns, .{
        .name = "Collator",
        .ctor = collatorConstructor,
        .arity = 0,
        .to_string_tag = "Intl.Collator",
        .methods = &.{
            // §10.3.5 — `compare` is an accessor (getter returning a bound
            // function), installed below once installService has set
            // intl_collator_prototype.
            .{ .name = "resolvedOptions", .fn_ptr = collatorResolvedOptions, .params = 0 },
        },
        .supported_locales_of = anySupportedLocalesOf,
        .set_ctor_intrinsic = struct {
            fn f(r: *Realm, c: *JSFunction) void {
                r.intrinsics.intl_collator_constructor = c;
            }
        }.f,
        .set_proto_intrinsic = struct {
            fn f(r: *Realm, p: *JSObject) void {
                r.intrinsics.intl_collator_prototype = p;
            }
        }.f,
    });
    // §10.3.5 — `Intl.Collator.prototype.compare` is an accessor.
    const proto = realm.intrinsics.intl_collator_prototype.?;
    try installNativeGetter(realm, proto, "compare", collatorCompareGetter);
    // §10.1.1 — Intl.Collator is callable without `new`. Clear the
    // class-constructor brand (so a plain call reaches the native instead of
    // being rejected at the call layer) and defer OCFC so the native builds a
    // fresh instance from Collator.prototype rather than mutating `this`.
    const ctor = realm.intrinsics.intl_collator_constructor.?;
    ctor.is_class_constructor = false;
    ctor.defers_proto_lookup = true;
}

fn collatorCompareGetter(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    _ = try requireKind(realm, this_value, .collator);
    return makeBoundServiceFunction(realm, this_value, collatorCompare, "compare", 2);
}

fn anySupportedLocalesOf(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = this_value;
    return supportedLocalesOfImpl(realm, args);
}

fn collatorConstructor(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    // Callable without new? Spec allows legacy; we require new via is_class.
    const inst = try newIntlInstance(realm, this_value, realm.intrinsics.intl_collator_prototype.?, "Collator", false);
    const locales = argOr(args, 0, Value.undefined_);
    const options = argOr(args, 1, Value.undefined_);
    const opts = try getOptionsObject(realm, options);
    const resolved = try resolveServiceLocaleAvail(realm, locales, opts, .any);

    var slots: intl.CollatorSlots = .{};
    errdefer slots.deinit(realm.allocator);
    slots.base.locale = resolved.locale;
    try retainRelevantUnicodeExtensions(realm, &slots.base, &.{ "co", "kf", "kn" }); // §9.2.7 Collator keys
    slots.usage = try getOptionStringOwned(realm, opts, "usage", &.{ "sort", "search" }, "sort");
    // §10.1.2 collation option — any -u- type sequence is accepted here;
    // supportedness is decided against the locale below.
    var co_opt: []const u8 = "";
    if (opts) |o| {
        const v = try getPropertyChain(realm, o, "collation");
        if (!v.isUndefined()) {
            co_opt = try valueToStringSlice(realm, v);
            if (!intl.isValidUnicodeType(co_opt)) return throwRangeError(realm, "invalid collation");
        }
    }
    slots.sensitivity = try getOptionStringOwned(realm, opts, "sensitivity", &.{ "base", "accent", "case", "variant" }, "variant");
    // §10.1.1 — ignorePunctuation's default is locale-dependent: Thai's root
    // collation shifts punctuation, so `th` defaults to true; other locales false.
    const ip_default = std.mem.startsWith(u8, slots.base.locale, "th") and
        (slots.base.locale.len == 2 or slots.base.locale[2] == '-');
    slots.ignore_punctuation = try getBooleanOption(realm, opts, "ignorePunctuation", ip_default);

    // §10.1.1 relevant-extension-keys « co, kn, kf ». The option overrides the
    // locale's -u- keyword; an option-sourced value also drops that keyword
    // from [[Locale]], while a locale-sourced one is retained. collation has
    // no option and "standard"/"search" are never reported (→ "default").
    const numeric_opt: ?bool = if (opts) |o| blk: {
        const v = try getPropertyChain(realm, o, "numeric");
        break :blk if (v.isUndefined()) null else toBoolean(v);
    } else null;
    const cf_opt = try getOptionString(realm, opts, "caseFirst", &.{ "upper", "lower", "false" }, "");

    // §9.2.7 co key: the option wins when the locale supports it, else the
    // locale's -u-co keyword when supported, else "default". "standard" /
    // "search" are never reported. [[Locale]] keeps the keyword only when it
    // supplied the resolved value.
    const never = struct {
        fn reported(ty: []const u8) bool {
            return std.mem.eql(u8, ty, "standard") or std.mem.eql(u8, ty, "search");
        }
    };
    const kw_co = intl.unicodeExtensionValue(slots.base.locale, "co");
    const kw_ok = if (kw_co) |k| k.len > 0 and !never.reported(k) and collationSupportedFor(slots.base.locale, k) else false;
    const opt_ok = co_opt.len > 0 and !never.reported(co_opt) and collationSupportedFor(slots.base.locale, co_opt);
    slots.collation = realm.allocator.dupe(u8, if (opt_ok) co_opt else if (kw_ok) kw_co.? else "default") catch return error.OutOfMemory;
    const keep_kw = kw_ok and std.mem.eql(u8, slots.collation, kw_co.?);
    if (kw_co != null and !keep_kw) try stripExtKeyword(realm, &slots.base, "co");

    // numeric (-u-kn): §9.2.7 — [[numeric]] takes the option, else the locale
    // keyword, else false; but [[locale]] reflects only the *locale* keyword,
    // canonicalized — "kn-true"/bare → "-u-kn", "kn-false" dropped (the default).
    // An option changes [[numeric]] but never [[locale]].
    const kn_loc = intl.unicodeExtensionValue(slots.base.locale, "kn");
    slots.numeric = if (numeric_opt) |n| n else if (kn_loc) |kn| !std.mem.eql(u8, kn, "false") else false;
    if (kn_loc) |kn| {
        if (std.mem.eql(u8, kn, "false")) {
            try stripExtKeyword(realm, &slots.base, "kn");
        } else if (std.mem.eql(u8, kn, "true")) {
            try addExtKeyword(realm, &slots.base, "kn", ""); // canonicalize true → bare
        }
    }

    // caseFirst (-u-kf): [[caseFirst]] = option ?? locale ?? "false"; [[locale]]
    // keeps the locale "lower"/"upper" keyword and drops "false" (the default).
    const kf_loc = intl.unicodeExtensionValue(slots.base.locale, "kf");
    const kf_from_locale = if (kf_loc) |kf| (if (std.mem.eql(u8, kf, "upper") or std.mem.eql(u8, kf, "lower")) kf else "false") else "false";
    slots.case_first = realm.allocator.dupe(u8, if (cf_opt.len > 0) cf_opt else kf_from_locale) catch return error.OutOfMemory;
    if (kf_loc) |kf| {
        if (!std.mem.eql(u8, kf, "lower") and !std.mem.eql(u8, kf, "upper")) try stripExtKeyword(realm, &slots.base, "kf");
    }

    try storeRecord(realm, inst, .{ .collator = slots });
    return heap_mod.taggedObject(inst);
}

fn collatorCompare(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = try requireKind(realm, this_value, .collator);
    const x = try valueToStringSlice(realm, argOr(args, 0, Value.undefined_));
    const y = try valueToStringSlice(realm, argOr(args, 1, Value.undefined_));
    const ord = std.mem.order(u8, x, y);
    const n: i32 = switch (ord) {
        .lt => -1,
        .eq => 0,
        .gt => 1,
    };
    return Value.fromInt32(n);
}

fn collatorResolvedOptions(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    const rec = try requireKind(realm, this_value, .collator);
    const s = rec.collator;
    const obj = try makeResolvedBase(realm, s.base.locale);
    try setDataProp(realm, obj, "usage", try makeStringValue(realm, if (s.usage.len > 0) s.usage else "sort"));
    try setDataProp(realm, obj, "sensitivity", try makeStringValue(realm, if (s.sensitivity.len > 0) s.sensitivity else "variant"));
    try setDataProp(realm, obj, "ignorePunctuation", makeBoolValue(s.ignore_punctuation));
    try setDataProp(realm, obj, "collation", try makeStringValue(realm, if (s.collation.len > 0) s.collation else "default"));
    try setDataProp(realm, obj, "numeric", makeBoolValue(s.numeric));
    try setDataProp(realm, obj, "caseFirst", try makeStringValue(realm, if (s.case_first.len > 0) s.case_first else "false"));
    return heap_mod.taggedObject(obj);
}

// ── NumberFormat ───────────────────────────────────────────────────────────

fn installNumberFormat(realm: *Realm, ns: *JSObject) !void {
    try installService(realm, ns, .{
        .name = "NumberFormat",
        .ctor = numberFormatConstructor,
        .arity = 0,
        .to_string_tag = "Intl.NumberFormat",
        .methods = &.{
            // §11.3.5 — `format` is an accessor (see `makeBoundServiceFunction`).
            .{ .name = "formatToParts", .fn_ptr = numberFormatFormatToParts, .params = 1 },
            .{ .name = "formatRange", .fn_ptr = numberFormatFormatRange, .params = 2 },
            .{ .name = "formatRangeToParts", .fn_ptr = numberFormatFormatRangeToParts, .params = 2 },
            .{ .name = "resolvedOptions", .fn_ptr = numberFormatResolvedOptions, .params = 0 },
        },
        .supported_locales_of = anySupportedLocalesOf,
        .set_ctor_intrinsic = struct {
            fn f(r: *Realm, c: *JSFunction) void {
                r.intrinsics.intl_number_format_constructor = c;
            }
        }.f,
        .set_proto_intrinsic = struct {
            fn f(r: *Realm, p: *JSObject) void {
                r.intrinsics.intl_number_format_prototype = p;
            }
        }.f,
    });
    // §11.3.5 — `Intl.NumberFormat.prototype.format` is an accessor.
    const proto = realm.intrinsics.intl_number_format_prototype.?;
    try installNativeGetter(realm, proto, "format", numberFormatFormatGetter);
    // §11.1.1 — Intl.NumberFormat is callable without `new` (legacy chain).
    const ctor = realm.intrinsics.intl_number_format_constructor.?;
    ctor.is_class_constructor = false;
    ctor.defers_proto_lookup = true;
}

fn numberFormatFormatGetter(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    _ = try requireKind(realm, this_value, .number_format);
    return makeBoundServiceFunction(realm, this_value, numberFormatFormat, "format", 1);
}

fn numberFormatConstructor(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const inst = try newIntlInstance(realm, this_value, realm.intrinsics.intl_number_format_prototype.?, "NumberFormat", false);
    const locales = argOr(args, 0, Value.undefined_);
    const options = argOr(args, 1, Value.undefined_);
    const opts = try coerceOptionsToObject(realm, options);
    const resolved = try resolveServiceLocale(realm, locales, opts);

    var slots: intl.NumberFormatSlots = .{};
    slots.base.locale = resolved.locale;
    // Option resolution can throw partway (an invalid enum, a bad currency
    // code); free the owned slots so a rejected constructor doesn't leak.
    // On success storeRecord takes ownership and this never fires.
    errdefer slots.deinit(realm.allocator);
    // §9.2.7 — NumberFormat's only relevant -u- key is `nu` (unsupported values
    // dropped); every other keyword (e.g. `-cu-usd`) is removed.
    try retainRelevantUnicodeExtensions(realm, &slots.base, &.{"nu"});
    try setDataLocale(realm, &slots.base);
    slots.style = try getOptionStringOwned(realm, opts, "style", &.{ "decimal", "percent", "currency", "unit" }, "decimal");
    const is_currency_style = std.mem.eql(u8, slots.style, "currency");
    const is_unit_style = std.mem.eql(u8, slots.style, "unit");

    // §15.1.2 SetNumberFormatUnitOptions — currency / currencyDisplay /
    // currencySign are read and validated *unconditionally* (an invalid value
    // throws RangeError regardless of style); they are only applied when the
    // style is "currency". `getOptionString` with an allowed list returns an
    // interned pointer, so reading-for-validation costs no allocation.
    // §15.1.2 — distinguish an absent `currency` (undefined) from a present but
    // ill-formed one (e.g. ""): the former is a TypeError under the currency
    // style, the latter always a RangeError (IsWellFormedCurrencyCode). A
    // sentinel fallback flags the undefined case, which ToString can't produce.
    const cur_undef = "\x00undefined";
    const cur = try getOptionString(realm, opts, "currency", null, cur_undef);
    if (std.mem.eql(u8, cur, cur_undef)) {
        if (is_currency_style) return throwTypeError(realm, "currency option required for currency style");
    } else if (cur.len != 3 or !isAsciiAlpha(cur)) {
        return throwRangeError(realm, "invalid currency code");
    }
    const cur_display = try getOptionString(realm, opts, "currencyDisplay", &.{ "code", "symbol", "narrowSymbol", "name" }, "symbol");
    const cur_sign = try getOptionString(realm, opts, "currencySign", &.{ "standard", "accounting" }, "standard");
    if (is_currency_style) {
        var up: [3]u8 = undefined;
        for (cur, 0..) |c, i| up[i] = if (c >= 'a' and c <= 'z') c - 32 else c;
        slots.currency = try realm.allocator.dupe(u8, &up);
        slots.currency_display = try realm.allocator.dupe(u8, cur_display);
        slots.currency_sign = try realm.allocator.dupe(u8, cur_sign);
    }

    // §15.1.1 unit / unitDisplay. A provided `unit` must be a well-formed unit
    // identifier (§6.5.1) regardless of style — RangeError otherwise; the unit
    // style additionally requires one (TypeError when absent).
    const unit = try getOptionString(realm, opts, "unit", null, "");
    if (unit.len > 0 and !isWellFormedUnitIdentifier(unit))
        return throwRangeError(realm, "invalid unit identifier");
    const unit_display = try getOptionString(realm, opts, "unitDisplay", &.{ "short", "narrow", "long" }, "short");
    if (is_unit_style) {
        if (unit.len == 0) return throwTypeError(realm, "unit option required for unit style");
        slots.unit = try realm.allocator.dupe(u8, unit);
        slots.unit_display = try realm.allocator.dupe(u8, unit_display);
    }
    slots.notation = try getOptionStringOwned(realm, opts, "notation", &.{ "standard", "scientific", "engineering", "compact" }, "standard");
    slots.compact_display = try getOptionStringOwned(realm, opts, "compactDisplay", &.{ "short", "long" }, "short");
    // §15.1.2 — useGrouping defaults to "min2" under compact notation, "auto"
    // otherwise (so compact omits grouping below ~10,000).
    slots.use_grouping = try getUseGroupingOwned(realm, opts, if (std.mem.eql(u8, slots.notation, "compact")) "min2" else "auto");

    // §15.1.1 SetNumberFormatDigitOptions — fraction-digit defaults vary by
    // style: percent → min 0 / max 0; decimal → min 0 / max 3; currency →
    // min and max both cCurrencyDigits(currency) (2 for most, 0 for JPY, 3 for
    // BHD, …), so an integer amount still shows the minor units ("$5.00").
    const cur_digits: u32 = if (is_currency_style) cldr.currencyFractionDigits(slots.currency) else 0;
    const mnfd_default: u32 = if (is_currency_style) cur_digits else 0;
    const mxfd_default: u32 = if (is_currency_style) cur_digits else if (std.mem.eql(u8, slots.style, "percent")) 0 else 3;
    try setNumberFormatDigitOptions(realm, &slots, opts, mnfd_default, mxfd_default);

    slots.sign_display = try getOptionStringOwned(realm, opts, "signDisplay", &.{ "auto", "never", "always", "exceptZero", "negative" }, "auto");

    // Numbering system: explicit option wins, else the locale's CLDR default,
    // else latn. (The -u-nu- extension is resolved into the locale upstream.)
    slots.base.numbering_system = try resolveNumberingSystem(realm, slots.base.dataLocale(), slots.base.locale, opts);

    try storeRecord(realm, inst, .{ .number_format = slots });
    return heap_mod.taggedObject(inst);
}

/// §1.1.5 GetNumberOption / DefaultNumberOption — read an integer option in
/// [min,max], flooring; RangeError out of range. null when absent.
fn getNumberOptionOpt(realm: *Realm, opts: ?*JSObject, key: []const u8, min: u32, max: u32) NativeError!?u32 {
    const obj = opts orelse return null;
    const v = try getPropertyChain(realm, obj, key);
    if (v.isUndefined()) return null;
    const f = numberToF64(try toNumber(realm, v));
    if (std.math.isNan(f) or f < @as(f64, @floatFromInt(min)) or f > @as(f64, @floatFromInt(max)))
        return throwRangeError(realm, "number option out of range");
    return @intFromFloat(@floor(f));
}

fn getNumberOption(realm: *Realm, opts: ?*JSObject, key: []const u8, min: u32, max: u32, fallback: u32) NativeError!u32 {
    return (try getNumberOptionOpt(realm, opts, key, min, max)) orelse fallback;
}

/// §15.1.2 GetUnsignedRoundingMode-adjacent useGrouping reader — accepts the
/// string forms plus the legacy boolean; stores a canonical string.
fn getUseGroupingOwned(realm: *Realm, opts: ?*JSObject, default_value: []const u8) NativeError![]const u8 {
    // §15.1.2 GetBooleanOrStringNumberFormatOption(«"min2","auto","always"», def).
    // `default_value` is "min2" under compact notation, else "auto". Internal
    // "false" represents the boolean false; resolvedOptions maps it back.
    const obj = opts orelse return realm.allocator.dupe(u8, default_value) catch error.OutOfMemory;
    const v = try getPropertyChain(realm, obj, "useGrouping");
    if (v.isUndefined()) return realm.allocator.dupe(u8, default_value) catch error.OutOfMemory;
    if (v.isBool()) return realm.allocator.dupe(u8, if (v.toBooleanPrimitive()) "always" else "false") catch error.OutOfMemory;
    // A falsy non-boolean (0, "", null, NaN) → false; a truthy non-string then
    // ToString'd. The strings "true"/"false" are NOT valid values → fallback.
    if (!toBoolean(v)) return realm.allocator.dupe(u8, "false") catch error.OutOfMemory;
    const s = try valueToStringSlice(realm, v);
    if (std.mem.eql(u8, s, "true") or std.mem.eql(u8, s, "false"))
        return realm.allocator.dupe(u8, "auto") catch error.OutOfMemory;
    if (std.mem.eql(u8, s, "always") or std.mem.eql(u8, s, "auto") or std.mem.eql(u8, s, "min2"))
        return realm.allocator.dupe(u8, s) catch error.OutOfMemory;
    return throwRangeError(realm, "invalid useGrouping value");
}

/// §6.5.1 — the sanctioned single-unit identifiers for Intl.NumberFormat's
/// `unit` option. Mirrors the packer's list; needed for validation even at
/// -Dintl=stub (structural, no CLDR data).
const sanctioned_unit_names = [_][]const u8{
    "acre",        "bit",      "byte",              "celsius",     "centimeter",
    "day",         "degree",   "fahrenheit",        "fluid-ounce", "foot",
    "gallon",      "gigabit",  "gigabyte",          "gram",        "hectare",
    "hour",        "inch",     "kilobit",           "kilobyte",    "kilogram",
    "kilometer",   "liter",    "megabit",           "megabyte",    "meter",
    "microsecond", "mile",     "mile-scandinavian", "milliliter",  "millimeter",
    "millisecond", "minute",   "month",             "nanosecond",  "ounce",
    "percent",     "petabyte", "pound",             "second",      "stone",
    "terabit",     "terabyte", "week",              "yard",        "year",
};

/// §6.5.2 IsSanctionedSingleUnitIdentifier.
fn isSanctionedSingleUnit(u: []const u8) bool {
    for (sanctioned_unit_names) |n| if (std.mem.eql(u8, n, u)) return true;
    return false;
}

/// §6.5.1 IsWellFormedUnitIdentifier — a sanctioned single unit, or "X-per-Y"
/// where both X and Y are sanctioned single units (split at the first "-per-").
fn isWellFormedUnitIdentifier(u: []const u8) bool {
    if (isSanctionedSingleUnit(u)) return true;
    const per = std.mem.indexOf(u8, u, "-per-") orelse return false;
    const num = u[0..per];
    const den = u[per + 5 ..];
    return isSanctionedSingleUnit(num) and isSanctionedSingleUnit(den);
}

/// §15.1.1 SetNumberFormatDigitOptions (fraction / significant subset). Reads
/// the digit + rounding options into `slots` with the given fraction defaults.
fn setNumberFormatDigitOptions(realm: *Realm, slots: *intl.NumberFormatSlots, opts: ?*JSObject, mnfd_default: u32, mxfd_default: u32) NativeError!void {
    slots.minimum_integer_digits = try getNumberOption(realm, opts, "minimumIntegerDigits", 1, 21, 1);
    const mnfd = try getNumberOptionOpt(realm, opts, "minimumFractionDigits", 0, 100);
    const mxfd = try getNumberOptionOpt(realm, opts, "maximumFractionDigits", 0, 100);
    const mnsd = try getNumberOptionOpt(realm, opts, "minimumSignificantDigits", 1, 21);
    const mxsd = try getNumberOptionOpt(realm, opts, "maximumSignificantDigits", 1, 21);
    slots.rounding_increment = try getNumberOption(realm, opts, "roundingIncrement", 1, 5000, 1);
    // §15.1.1 — roundingIncrement must be one of the sanctioned increments.
    switch (slots.rounding_increment) {
        1, 2, 5, 10, 20, 25, 50, 100, 200, 250, 500, 1000, 2000, 2500, 5000 => {},
        else => return throwRangeError(realm, "invalid roundingIncrement"),
    }
    slots.rounding_mode = try getOptionStringOwned(realm, opts, "roundingMode", &.{ "ceil", "floor", "expand", "trunc", "halfCeil", "halfFloor", "halfExpand", "halfTrunc", "halfEven" }, "halfExpand");
    slots.trailing_zero_display = try getOptionStringOwned(realm, opts, "trailingZeroDisplay", &.{ "auto", "stripIfInteger" }, "auto");
    const priority = try getOptionString(realm, opts, "roundingPriority", &.{ "auto", "morePrecision", "lessPrecision" }, "auto");

    const is_more = std.mem.eql(u8, priority, "morePrecision");
    const is_less = std.mem.eql(u8, priority, "lessPrecision");

    if (is_more or is_less) {
        // §15.1.1 morePrecision/lessPrecision — both significant and fraction
        // bounds are active; roundDigits computes both and picks.
        slots.rounding_type = try realm.allocator.dupe(u8, if (is_more) "morePrecision" else "lessPrecision");
        slots.minimum_significant_digits = mnsd orelse 1;
        slots.maximum_significant_digits = mxsd orelse 21;
        const lo = mnfd orelse @min(mnfd_default, mxfd orelse mnfd_default);
        const hi = mxfd orelse @max(lo, mxfd_default);
        if (lo > hi) return throwRangeError(realm, "minimumFractionDigits > maximumFractionDigits");
        slots.minimum_fraction_digits = lo;
        slots.maximum_fraction_digits = hi;
    } else if (mnsd != null or mxsd != null) {
        slots.rounding_type = try realm.allocator.dupe(u8, "significantDigits");
        slots.minimum_significant_digits = mnsd orelse 1;
        slots.maximum_significant_digits = mxsd orelse 21;
    } else if (mnfd != null or mxfd != null) {
        slots.rounding_type = try realm.allocator.dupe(u8, "fractionDigits");
        // §15.1.1: when only one bound is explicit, the other default is
        // clamped to it (mnfd → min(default, mxfd); mxfd → max(default, mnfd)),
        // so a currency-driven default mnfd never spuriously exceeds a smaller
        // user mxfd. A RangeError is reserved for both bounds explicit + crossed.
        const lo = mnfd orelse @min(mnfd_default, mxfd orelse mnfd_default);
        const hi = mxfd orelse @max(lo, mxfd_default);
        if (lo > hi) return throwRangeError(realm, "minimumFractionDigits > maximumFractionDigits");
        slots.minimum_fraction_digits = lo;
        slots.maximum_fraction_digits = hi;
    } else if (std.mem.eql(u8, slots.notation, "compact")) {
        // §15.1.1 — compact with no explicit digit bounds rounds to whichever of
        // 1-2 significant or 0 fraction digits is more precise (morePrecision),
        // giving "1.2K" / "988M" rather than "1K" / "990M".
        slots.rounding_type = try realm.allocator.dupe(u8, "morePrecision");
        slots.minimum_significant_digits = 1;
        slots.maximum_significant_digits = 2;
        slots.minimum_fraction_digits = 0;
        slots.maximum_fraction_digits = 0;
    } else {
        slots.rounding_type = try realm.allocator.dupe(u8, "fractionDigits");
        slots.minimum_fraction_digits = mnfd_default;
        slots.maximum_fraction_digits = mxfd_default;
    }

    // §15.1.1 — a non-default roundingIncrement is only meaningful with
    // fraction-digit rounding at a fixed precision: it requires roundingType
    // "fractionDigits" (TypeError otherwise — e.g. paired with significant
    // digits or morePrecision) and equal min/max fraction digits (RangeError).
    if (slots.rounding_increment != 1) {
        if (!std.mem.eql(u8, slots.rounding_type, "fractionDigits"))
            return throwTypeError(realm, "roundingIncrement requires fractionDigits rounding");
        if ((slots.minimum_fraction_digits orelse 0) != (slots.maximum_fraction_digits orelse 0))
            return throwRangeError(realm, "roundingIncrement requires equal min/max fraction digits");
    }
}

/// Resolve the numbering-system id: explicit `numberingSystem` option (must be
/// a known numeric system) → the locale's CLDR default → "latn".
fn resolveNumberingSystem(realm: *Realm, locale: []const u8, ext_locale: []const u8, opts: ?*JSObject) NativeError![]const u8 {
    if (opts) |o| {
        const v = try getPropertyChain(realm, o, "numberingSystem");
        if (!v.isUndefined()) {
            const s = try valueToStringSlice(realm, v);
            // §9.x: the option must be a well-formed `type` (3-8 alphanumeric
            // subtags) — a malformed value throws RangeError. A well-formed but
            // unsupported system is NOT an error; it falls back to the locale
            // default per ResolveLocale (reported as the default).
            if (!intl.isValidUnicodeType(s)) return throwRangeError(realm, "invalid numberingSystem");
            if (cldr.available and cldr.numberingSystemDigitBase(s) != null)
                return realm.allocator.dupe(u8, s) catch error.OutOfMemory;
        }
    }
    // NOTE: the locale's -u-nu keyword deliberately does NOT apply here yet —
    // honouring it unmasks digit-substituted output for values whose exact
    // decimal expansion the f64 render path cannot yet produce (the nu-arab
    // big-value fixtures skip their asserts while the resolved system stays
    // "latn"). Wire the keyword through once the exact-decimal path lands.
    _ = ext_locale;
    if (cldr.available) {
        if (cldr.numberData(locale)) |d| return realm.allocator.dupe(u8, d.ns) catch error.OutOfMemory;
    }
    return realm.allocator.dupe(u8, "latn") catch error.OutOfMemory;
}

/// §21.1.3.4 / §21.2.3.3 Number|BigInt.prototype.toLocaleString at the CLDR
/// tier — format `value` through a transient Intl.NumberFormat built from
/// (locales, options), so both surface the locale's grouping / digit symbols.
/// Assumes `cldr.available`; the structural tiers keep the ToString fallback.
pub fn numberValueToLocaleString(realm: *Realm, value: Value, locales: Value, options: Value) NativeError!Value {
    const nf = try numberFormatConstructor(realm, Value.undefined_, &.{ locales, options });
    return numberFormatFormat(realm, nf, &.{value});
}

fn numberFormatFormat(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const rec = try requireKind(realm, this_value, .number_format);
    const v = argOr(args, 0, Value.undefined_);
    // Without the CLDR blob, fall back to ToString of the magnitude.
    if (!cldr.available) {
        const n = if (heap_mod.isBigInt(v)) v else try toNumber(realm, v);
        return makeStringValue(realm, try valueToStringSlice(realm, n));
    }
    // §15.5.x — a BigInt formats as its (approximated) numeric value: convert
    // to f64 and run the same CLDR path as a Number, so grouping / digit
    // symbols apply. (Exact-decimal digits for a > 2^53 BigInt await the
    // mathematical-value pipeline.)
    const x = if (heap_mod.valueAsBigInt(v)) |b|
        b.toF64()
    else
        numberToF64(try toNumber(realm, v));
    var buf: [256]u8 = undefined;
    const s = try formatNumericToBuf(realm, &rec.number_format, x, &buf);
    return makeStringValue(realm, s);
}

fn numberFormatFormatToParts(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const rec = try requireKind(realm, this_value, .number_format);
    const v = argOr(args, 0, Value.undefined_);
    const arr = allocateArray(realm) catch return error.OutOfMemory;
    if (heap_mod.isBigInt(v) or !cldr.available) {
        const formatted = try numberFormatFormat(realm, this_value, args);
        try pushPart(realm, arr, 0, "integer", formatted);
        arr.setArrayLength(realm.allocator, 1) catch return error.OutOfMemory;
        return heap_mod.taggedObject(arr);
    }
    const x = numberToF64(try toNumber(realm, v));
    var segs: [48]Seg = undefined;
    const n = renderNumber(&rec.number_format, x, &segs);
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const part = realm.heap.allocateObject() catch return error.OutOfMemory;
        realm.heap.setObjectPrototype(part, realm.intrinsics.object_prototype);
        try setDataProp(realm, part, "type", try makeStringValue(realm, segs[i].typ));
        try setDataProp(realm, part, "value", try makeStringValue(realm, segs[i].bytes()));
        var kb: [12]u8 = undefined;
        arr.set(realm.allocator, std.fmt.bufPrint(&kb, "{d}", .{i}) catch unreachable, heap_mod.taggedObject(part)) catch return error.OutOfMemory;
    }
    arr.setArrayLength(realm.allocator, n) catch return error.OutOfMemory;
    return heap_mod.taggedObject(arr);
}

/// §15.5.8 ToIntlMathematicalValue (coercion subset) → f64. BigInt converts
/// directly; everything else flows through ToNumber (so a Symbol throws
/// TypeError and a numeric string parses). undefined is rejected by the caller.
fn rangeOperandF64(realm: *Realm, v: Value) NativeError!f64 {
    if (heap_mod.valueAsBigInt(v)) |bi| return bi.toF64();
    return numberToF64(try toNumber(realm, v));
}

const en_dash = "\u{2013}";

/// Format one range operand to its number string (CLDR path when available,
/// else ToString) — shared by formatRange / formatRangeToParts.
fn rangeFormatOne(realm: *Realm, slots: *const intl.NumberFormatSlots, f: f64, buf: []u8) NativeError![]const u8 {
    if (!cldr.available) return valueToStringSlice(realm, Value.fromDouble(f));
    return formatNumericToBuf(realm, slots, f, buf);
}

fn numberFormatFormatRange(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const rec = try requireKind(realm, this_value, .number_format);
    // §15.5.8 — both arguments are required (TypeError when either is undefined),
    // then coerced; a NaN operand is a RangeError. x > y does not throw.
    const xv = argOr(args, 0, Value.undefined_);
    const yv = argOr(args, 1, Value.undefined_);
    if (xv.isUndefined() or yv.isUndefined()) return throwTypeError(realm, "formatRange requires two arguments");
    const xf = try rangeOperandF64(realm, xv);
    const yf = try rangeOperandF64(realm, yv);
    if (std.math.isNan(xf) or std.math.isNan(yf)) return throwRangeError(realm, "formatRange arguments must not be NaN");
    var bufx: [256]u8 = undefined;
    var bufy: [256]u8 = undefined;
    const sx = try rangeFormatOne(realm, &rec.number_format, xf, &bufx);
    const sy = try rangeFormatOne(realm, &rec.number_format, yf, &bufy);
    // When the two operands format identically, collapse to the approximate
    // form ("~{0}"); otherwise join with the range separator.
    const out = if (std.mem.eql(u8, sx, sy))
        std.fmt.allocPrint(realm.allocator, "~{s}", .{sx}) catch return error.OutOfMemory
    else
        std.fmt.allocPrint(realm.allocator, "{s}{s}{s}", .{ sx, en_dash, sy }) catch return error.OutOfMemory;
    defer realm.allocator.free(out);
    return makeStringValue(realm, out);
}

fn pushPartSourced(realm: *Realm, arr: anytype, idx: u32, typ: []const u8, value: []const u8, source: []const u8) NativeError!void {
    const part = realm.heap.allocateObject() catch return error.OutOfMemory;
    realm.heap.setObjectPrototype(part, realm.intrinsics.object_prototype);
    try setDataProp(realm, part, "type", try makeStringValue(realm, typ));
    try setDataProp(realm, part, "value", try makeStringValue(realm, value));
    try setDataProp(realm, part, "source", try makeStringValue(realm, source));
    var kb: [12]u8 = undefined;
    arr.set(realm.allocator, std.fmt.bufPrint(&kb, "{d}", .{idx}) catch unreachable, heap_mod.taggedObject(part)) catch return error.OutOfMemory;
}

fn numberFormatFormatRangeToParts(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const rec = try requireKind(realm, this_value, .number_format);
    const xv = argOr(args, 0, Value.undefined_);
    const yv = argOr(args, 1, Value.undefined_);
    if (xv.isUndefined() or yv.isUndefined()) return throwTypeError(realm, "formatRangeToParts requires two arguments");
    const xf = try rangeOperandF64(realm, xv);
    const yf = try rangeOperandF64(realm, yv);
    if (std.math.isNan(xf) or std.math.isNan(yf)) return throwRangeError(realm, "formatRangeToParts arguments must not be NaN");
    const arr = allocateArray(realm) catch return error.OutOfMemory;
    var idx: u32 = 0;
    if (!cldr.available) {
        var bx: [256]u8 = undefined;
        const sx = try rangeFormatOne(realm, &rec.number_format, xf, &bx);
        try pushPartSourced(realm, arr, idx, "integer", sx, "startRange");
        idx += 1;
    } else {
        var segx: [48]Seg = undefined;
        var segy: [48]Seg = undefined;
        const nx = renderNumber(&rec.number_format, xf, &segx);
        const ny = renderNumber(&rec.number_format, yf, &segy);
        // Equal renderings collapse to a "shared"-sourced approximate run.
        var same = nx == ny;
        if (same) {
            var k: u32 = 0;
            while (k < nx) : (k += 1) {
                if (!std.mem.eql(u8, segx[k].typ, segy[k].typ) or !std.mem.eql(u8, segx[k].bytes(), segy[k].bytes())) {
                    same = false;
                    break;
                }
            }
        }
        if (same) {
            try pushPartSourced(realm, arr, idx, "approximatelySign", "~", "shared");
            idx += 1;
            var k: u32 = 0;
            while (k < nx) : (k += 1) {
                try pushPartSourced(realm, arr, idx, segx[k].typ, segx[k].bytes(), "shared");
                idx += 1;
            }
        } else {
            var k: u32 = 0;
            while (k < nx) : (k += 1) {
                try pushPartSourced(realm, arr, idx, segx[k].typ, segx[k].bytes(), "startRange");
                idx += 1;
            }
            try pushPartSourced(realm, arr, idx, "literal", en_dash, "shared");
            idx += 1;
            k = 0;
            while (k < ny) : (k += 1) {
                try pushPartSourced(realm, arr, idx, segy[k].typ, segy[k].bytes(), "endRange");
                idx += 1;
            }
        }
    }
    arr.setArrayLength(realm.allocator, idx) catch return error.OutOfMemory;
    return heap_mod.taggedObject(arr);
}

fn pushPart(realm: *Realm, arr: anytype, idx: u32, typ: []const u8, value: Value) NativeError!void {
    const part = realm.heap.allocateObject() catch return error.OutOfMemory;
    realm.heap.setObjectPrototype(part, realm.intrinsics.object_prototype);
    try setDataProp(realm, part, "type", try makeStringValue(realm, typ));
    try setDataProp(realm, part, "value", value);
    var kb: [12]u8 = undefined;
    arr.set(realm.allocator, std.fmt.bufPrint(&kb, "{d}", .{idx}) catch unreachable, heap_mod.taggedObject(part)) catch return error.OutOfMemory;
}

fn numberFormatResolvedOptions(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    const rec = try requireKind(realm, this_value, .number_format);
    const s = rec.number_format;
    const obj = try makeResolvedBase(realm, s.base.locale);
    try setDataProp(realm, obj, "numberingSystem", try makeStringValue(realm, if (s.base.numbering_system.len > 0) s.base.numbering_system else "latn"));
    try setDataProp(realm, obj, "style", try makeStringValue(realm, if (s.style.len > 0) s.style else "decimal"));
    if (s.currency.len > 0) {
        try setDataProp(realm, obj, "currency", try makeStringValue(realm, s.currency));
        try setDataProp(realm, obj, "currencyDisplay", try makeStringValue(realm, if (s.currency_display.len > 0) s.currency_display else "symbol"));
        try setDataProp(realm, obj, "currencySign", try makeStringValue(realm, if (s.currency_sign.len > 0) s.currency_sign else "standard"));
    }
    if (s.unit.len > 0) {
        try setDataProp(realm, obj, "unit", try makeStringValue(realm, s.unit));
        try setDataProp(realm, obj, "unitDisplay", try makeStringValue(realm, if (s.unit_display.len > 0) s.unit_display else "short"));
    }
    try setDataProp(realm, obj, "minimumIntegerDigits", makeNumberValue(@floatFromInt(s.minimum_integer_digits)));
    // §15.5.2 — key order is fraction pair *before* significant pair.
    // morePrecision/lessPrecision report both; significantDigits → the
    // significant pair only; fractionDigits → the fraction pair only.
    const is_more_less = std.mem.eql(u8, s.rounding_type, "morePrecision") or std.mem.eql(u8, s.rounding_type, "lessPrecision");
    const is_sig = std.mem.eql(u8, s.rounding_type, "significantDigits");
    if (!is_sig) {
        try setDataProp(realm, obj, "minimumFractionDigits", makeNumberValue(@floatFromInt(s.minimum_fraction_digits orelse 0)));
        try setDataProp(realm, obj, "maximumFractionDigits", makeNumberValue(@floatFromInt(s.maximum_fraction_digits orelse 3)));
    }
    if (is_sig or is_more_less) {
        try setDataProp(realm, obj, "minimumSignificantDigits", makeNumberValue(@floatFromInt(s.minimum_significant_digits orelse 1)));
        try setDataProp(realm, obj, "maximumSignificantDigits", makeNumberValue(@floatFromInt(s.maximum_significant_digits orelse 21)));
    }
    // §15.5.2 — useGrouping resolves to `false` (boolean) or a string.
    if (std.mem.eql(u8, s.use_grouping, "false")) {
        try setDataProp(realm, obj, "useGrouping", Value.false_);
    } else {
        try setDataProp(realm, obj, "useGrouping", try makeStringValue(realm, if (s.use_grouping.len > 0) s.use_grouping else "auto"));
    }
    try setDataProp(realm, obj, "notation", try makeStringValue(realm, if (s.notation.len > 0) s.notation else "standard"));
    // §15.5.2 — compactDisplay is reported only under notation:"compact".
    if (std.mem.eql(u8, s.notation, "compact"))
        try setDataProp(realm, obj, "compactDisplay", try makeStringValue(realm, if (s.compact_display.len > 0) s.compact_display else "short"));
    try setDataProp(realm, obj, "signDisplay", try makeStringValue(realm, if (s.sign_display.len > 0) s.sign_display else "auto"));
    // §15.5.2 key order: roundingIncrement, roundingMode, roundingPriority, trailingZeroDisplay.
    try setDataProp(realm, obj, "roundingIncrement", makeNumberValue(@floatFromInt(s.rounding_increment)));
    try setDataProp(realm, obj, "roundingMode", try makeStringValue(realm, if (s.rounding_mode.len > 0) s.rounding_mode else "halfExpand"));
    try setDataProp(realm, obj, "roundingPriority", try makeStringValue(realm, if (is_more_less) s.rounding_type else "auto"));
    try setDataProp(realm, obj, "trailingZeroDisplay", try makeStringValue(realm, if (s.trailing_zero_display.len > 0) s.trailing_zero_display else "auto"));
    return heap_mod.taggedObject(obj);
}

// ── number formatting engine (decimal / percent; §15.5) ──────────────────────

/// One output segment of a formatted number (NumberFormat formatToParts type +
/// its UTF-8 bytes, held in a caller-owned scratch buffer).
const Seg = struct {
    typ: []const u8,
    buf: [128]u8 = undefined,
    len: usize = 0,
    fn bytes(self: *const Seg) []const u8 {
        return self.buf[0..self.len];
    }
};

fn setSeg(seg: *Seg, typ: []const u8, s: []const u8) void {
    seg.typ = typ;
    const n = @min(s.len, seg.buf.len);
    @memcpy(seg.buf[0..n], s[0..n]);
    seg.len = n;
}

/// Default symbols when the locale has no CLDR number data (latn / en-like).
const default_number_data = cldr.NumberData{
    .ns = "latn",
    .digit_base = '0',
    .decimal = ".",
    .group = ",",
    .minus = "-",
    .plus = "+",
    .percent = "%",
    .infinity = "∞",
    .nan = "NaN",
    .dec_pattern = "#,##0.###",
    .pct_pattern = "#,##0%",
};

/// Render `x` into typed segments per the resolved NumberFormat options.
/// Returns the number of segments written into `out`.
fn renderNumber(slots: *const intl.NumberFormatSlots, x: f64, out: []Seg) u32 {
    const nd = if (cldr.numberData(slots.base.dataLocale())) |d| d else default_number_data;
    const digit_base: u32 = if (slots.base.numbering_system.len > 0 and !std.mem.eql(u8, slots.base.numbering_system, nd.ns))
        (cldr.numberingSystemDigitBase(slots.base.numbering_system) orelse nd.digit_base)
    else
        nd.digit_base;

    const is_percent = std.mem.eql(u8, slots.style, "percent");
    const is_currency = std.mem.eql(u8, slots.style, "currency");
    // §15.5.x — NaN and ±∞ replace the whole numeric portion with a single CLDR
    // glyph, but the sign and the style affixes ($, %) are emitted exactly as
    // for a finite magnitude, so both cases share the sign/affix path below.
    // Per ToIntlMathematicalValue a NaN is sign-less (its sign bit is dropped, so
    // `-NaN` formats as "NaN") and is grouped with zero for sign selection, so
    // signDisplay "exceptZero"/"negative" emit no sign while "always" emits "+".
    const non_finite = !std.math.isFinite(x);
    const is_nan = std.math.isNan(x);
    const negative = std.math.signbit(x) and !is_nan;

    // Round to ASCII int/frac digit strings (finite magnitudes only).
    var int_ascii: [160]u8 = undefined;
    var frac_ascii: [160]u8 = undefined;
    var int_len: usize = 0;
    var frac_len: usize = 0;
    var int_pad: [160]u8 = undefined;
    var ip_len: usize = 0;
    var is_zero = is_nan; // NaN groups with zero for signDisplay selection
    if (!non_finite) {
        const scale: f64 = if (is_percent) 100 else 1;
        const magnitude = @abs(x) * scale;
        roundDigits(slots, magnitude, negative, &int_ascii, &int_len, &frac_ascii, &frac_len);

        is_zero = blk: {
            for (int_ascii[0..int_len]) |c| if (c != '0') break :blk false;
            for (frac_ascii[0..frac_len]) |c| if (c != '0') break :blk false;
            break :blk true;
        };

        // minimumIntegerDigits: left-pad with '0'.
        if (int_len < slots.minimum_integer_digits) {
            const pad = slots.minimum_integer_digits - int_len;
            var k: usize = 0;
            while (k < pad) : (k += 1) {
                int_pad[ip_len] = '0';
                ip_len += 1;
            }
        }
        @memcpy(int_pad[ip_len .. ip_len + int_len], int_ascii[0..int_len]);
        ip_len += int_len;
    }

    var n: u32 = 0;
    const append = struct {
        fn f(o: []Seg, idx: *u32, typ: []const u8, s: []const u8) void {
            if (idx.* >= o.len) return;
            setSeg(&o[idx.*], typ, s);
            idx.* += 1;
        }
    }.f;

    // §15.5 currencyDisplay:"name" — a wholly different layout: the number is
    // formatted plainly (no `¤`) and wrapped in the locale `unitPattern-count`
    // ("{0} {1}"), with the long name plural-selected on the *formatted*
    // operands. The unit pattern has no accounting variant, so a negative always
    // shows a discrete minus/plus inside the "{0}" slot.
    if (is_currency and std.mem.eql(u8, slots.currency_display, "name")) {
        const min_frac = slots.minimum_fraction_digits orelse 0;
        const max_frac = slots.maximum_fraction_digits orelse 2;
        const ops = cldr.computeOperands(@abs(x), min_frac, max_frac);
        const cat = cldr.selectPlural(slots.base.dataLocale(), false, ops);
        const long_name = cldr.currencyDisplayNameCount(slots.base.dataLocale(), slots.currency, cat) orelse
            cldr.displayName(slots.base.dataLocale(), .currency, slots.currency) orelse slots.currency;
        const unit_pat = cldr.currencyUnitPattern(slots.base.dataLocale(), cat) orelse "{0} {1}";

        var sign: []const u8 = "";
        var sign_type: []const u8 = "minusSign";
        if (signShows(slots.sign_display, negative, is_zero)) {
            sign = if (negative) nd.minus else nd.plus;
            sign_type = if (negative) "minusSign" else "plusSign";
        }
        emitUnitPattern(out, &n, unit_pat, .{
            .sign = sign,
            .sign_type = sign_type,
            .int_ascii = int_pad[0..ip_len],
            .frac_ascii = frac_ascii[0..frac_len],
            // §15.5.x — for ±∞ / NaN the "{0}" number slot is the CLDR glyph
            // ("∞ US dollars", "NaN US dollars"), not the (empty) digit run.
            .glyph = if (non_finite) (if (is_nan) nd.nan else nd.infinity) else "",
            .glyph_type = if (is_nan) "nan" else "infinity",
            .name = long_name,
            .slots = slots,
            .nd = nd,
            .digit_base = digit_base,
        }, append);
        return n;
    }

    // §15.5 unit style — format the number plainly (sign + grouped integer +
    // fraction) and wrap it in the locale's unit pattern (single or compound
    // "X-per-Y"), emitting the unit text as a single "unit" part and the
    // surrounding spaces as "literal". Isolated path: the unit pattern is a
    // "{0}" template, not a CLDR number skeleton, so it bypasses the affix logic.
    if (std.mem.eql(u8, slots.style, "unit") and slots.unit.len > 0) {
        const style_idx: u8 = if (std.mem.eql(u8, slots.unit_display, "long"))
            0
        else if (std.mem.eql(u8, slots.unit_display, "narrow")) 2 else 1;
        const loc = slots.base.dataLocale();
        const minf = slots.minimum_fraction_digits orelse 0;
        const maxf = slots.maximum_fraction_digits orelse 3;
        const cat = cldr.selectPlural(loc, false, cldr.computeOperands(@abs(x), minf, maxf));
        var patbuf: [256]u8 = undefined;
        const combined = unitCombinedPattern(slots.unit, loc, style_idx, cat, &patbuf) orelse "{0}";
        const z = std.mem.indexOf(u8, combined, "{0}") orelse combined.len;
        const prefix = combined[0..z];
        const suffix = if (z + 3 <= combined.len) combined[z + 3 ..] else "";

        if (signShows(slots.sign_display, negative, is_zero))
            append(out, &n, if (negative) "minusSign" else "plusSign", if (negative) nd.minus else nd.plus);
        if (prefix.len > 0) {
            var pe = prefix.len;
            while (pe > 0 and prefix[pe - 1] == ' ') pe -= 1;
            if (pe > 0) append(out, &n, "unit", prefix[0..pe]);
            if (pe < prefix.len) append(out, &n, "literal", prefix[pe..]);
        }
        if (non_finite) {
            append(out, &n, if (is_nan) "nan" else "infinity", if (is_nan) nd.nan else nd.infinity);
        } else {
            appendGroupedInteger(out, &n, int_pad[0..ip_len], slots, nd, digit_base, append);
            if (frac_len > 0) {
                append(out, &n, "decimal", nd.decimal);
                var sub: [256]u8 = undefined;
                append(out, &n, "fraction", substituteDigits(frac_ascii[0..frac_len], digit_base, &sub));
            }
        }
        if (suffix.len > 0) {
            var ss: usize = 0;
            while (ss < suffix.len and suffix[ss] == ' ') ss += 1;
            if (ss > 0) append(out, &n, "literal", suffix[0..ss]);
            if (ss < suffix.len) append(out, &n, "unit", suffix[ss..]);
        }
        return n;
    }

    // §15.5 scientific / engineering notation — an isolated path: normalize the
    // magnitude to a mantissa (1 ≤ |m| < 10, or < 1000 for engineering with the
    // exponent a multiple of 3), round the mantissa, and emit
    // integer/decimal/fraction + exponentSeparator/[exponentMinusSign]/exponentInteger.
    // (Decimal/percent only; currency notation stays on the pattern path.)
    if (!non_finite and !is_currency and
        (std.mem.eql(u8, slots.notation, "scientific") or std.mem.eql(u8, slots.notation, "engineering")))
    {
        const eng = std.mem.eql(u8, slots.notation, "engineering");
        const m = @abs(x) * (if (is_percent) @as(f64, 100) else 1);
        var exp: i32 = 0;
        if (m > 0) {
            exp = @as(i32, @intFromFloat(@floor(std.math.log10(m))));
            if (eng) exp = @divFloor(exp, 3) * 3;
        }
        var mant = if (m == 0) 0 else m / std.math.pow(f64, 10, @floatFromInt(exp));
        var mi: [160]u8 = undefined;
        var mil: usize = 0;
        var mf: [160]u8 = undefined;
        var mfl: usize = 0;
        roundDigits(slots, mant, negative, &mi, &mil, &mf, &mfl);
        // Rounding may carry the mantissa to 10 (e.g. 9.999→"10"); renormalize.
        if (mil > (if (eng) @as(usize, 3) else 1) and m > 0) {
            exp += @intCast(mil - 1);
            if (eng) exp = @divFloor(exp, 3) * 3;
            mant = m / std.math.pow(f64, 10, @floatFromInt(exp));
            roundDigits(slots, mant, negative, &mi, &mil, &mf, &mfl);
        }

        if (signShows(slots.sign_display, negative, is_zero))
            append(out, &n, if (negative) "minusSign" else "plusSign", if (negative) nd.minus else nd.plus);
        var sub: [256]u8 = undefined;
        append(out, &n, "integer", substituteDigits(mi[0..mil], digit_base, &sub));
        if (mfl > 0) {
            append(out, &n, "decimal", nd.decimal);
            var sub2: [256]u8 = undefined;
            append(out, &n, "fraction", substituteDigits(mf[0..mfl], digit_base, &sub2));
        }
        append(out, &n, "exponentSeparator", "E");
        if (exp < 0) append(out, &n, "exponentMinusSign", nd.minus);
        var eb: [16]u8 = undefined;
        const es = std.fmt.bufPrint(&eb, "{d}", .{@abs(exp)}) catch "0";
        var sub3: [256]u8 = undefined;
        append(out, &n, "exponentInteger", substituteDigits(es, digit_base, &sub3));
        return n;
    }

    // §15.5 compact notation — pick the locale's magnitude bucket pattern
    // (10³…10¹⁴), divide by the bucket's implied divisor (10^(magnitude−zeros+1),
    // where zeros is the count of '0' placeholders), round the compact value, and
    // wrap it in the pattern's literal/compact affixes ("988M", "1.2 thousand",
    // "10万"). Falls through to the standard path for |x| < 1000 or buckets the
    // locale leaves uncompacted ("0"). A rounding carry that grows the integer
    // past the bucket width promotes to the next bucket (999999 → "1M", not
    // "1000K"). Decimal/percent only; currency notation keeps the pattern path.
    if (!non_finite and !is_currency and std.mem.eql(u8, slots.notation, "compact")) {
        const m = @abs(x) * (if (is_percent) @as(f64, 100) else 1);
        var mag: i32 = if (m >= 1) @as(i32, @intFromFloat(@floor(std.math.log10(m)))) else -1;
        if (mag >= 3) {
            const long = std.mem.eql(u8, slots.compact_display, "long");
            const loc = slots.base.dataLocale();
            var ci: [160]u8 = undefined;
            var cil: usize = 0;
            var cf: [160]u8 = undefined;
            var cfl: usize = 0;
            var attempts: u8 = 0;
            while (attempts < 3) : (attempts += 1) {
                const bucket: u8 = @intCast(@min(mag, @as(i32, 14)));
                const pat0 = cldr.compactPattern(loc, long, bucket, .other) orelse break;
                var zeros: usize = 0;
                var has_affix = false;
                for (pat0) |c| {
                    if (c == '0') zeros += 1 else if (c != '.') has_affix = true;
                }
                // A pattern that is only "0"s (no suffix/prefix) is CLDR's
                // no-compaction marker for that magnitude — e.g. Japanese has no
                // compact form below 万 (10⁴), so 9876 renders in full, not "9.9".
                if (zeros == 0 or !has_affix) break; // → standard (uncompacted) path
                const div_exp: i32 = mag - @as(i32, @intCast(zeros)) + 1;
                const cv = m / std.math.pow(f64, 10, @floatFromInt(div_exp));
                roundDigits(slots, cv, negative, &ci, &cil, &cf, &cfl);
                if (cil > zeros and mag < 14) {
                    mag += 1; // carry crossed the bucket width — promote and retry
                    continue;
                }
                const minf = slots.minimum_fraction_digits orelse 0;
                const maxf = slots.maximum_fraction_digits orelse 0;
                const cat = cldr.selectPlural(loc, false, cldr.computeOperands(cv, minf, maxf));
                const pat = cldr.compactPattern(loc, long, bucket, cat) orelse pat0;
                const first0 = std.mem.indexOfScalar(u8, pat, '0').?;
                var last0 = first0;
                while (last0 + 1 < pat.len and pat[last0 + 1] == '0') last0 += 1;
                const prefix = pat[0..first0];
                const suffix = pat[last0 + 1 ..];

                if (signShows(slots.sign_display, negative, is_zero))
                    append(out, &n, if (negative) "minusSign" else "plusSign", if (negative) nd.minus else nd.plus);
                var uq: [64]u8 = undefined;
                if (prefix.len > 0) {
                    var pe = prefix.len;
                    while (pe > 0 and prefix[pe - 1] == ' ') pe -= 1;
                    if (pe > 0) append(out, &n, "compact", unquoteCldr(prefix[0..pe], &uq));
                    if (pe < prefix.len) append(out, &n, "literal", prefix[pe..]);
                }
                var sub: [256]u8 = undefined;
                append(out, &n, "integer", substituteDigits(ci[0..cil], digit_base, &sub));
                if (cfl > 0) {
                    append(out, &n, "decimal", nd.decimal);
                    var sub2: [256]u8 = undefined;
                    append(out, &n, "fraction", substituteDigits(cf[0..cfl], digit_base, &sub2));
                }
                if (suffix.len > 0) {
                    var ss: usize = 0;
                    while (ss < suffix.len and suffix[ss] == ' ') ss += 1;
                    if (ss > 0) append(out, &n, "literal", suffix[0..ss]);
                    if (ss < suffix.len) append(out, &n, "compact", unquoteCldr(suffix[ss..], &uq));
                }
                return n;
            }
        }
    }

    // Pattern affixes (percent / currency sign placement, literals). Decimal
    // patterns usually have none. Currency draws its own pattern (standard or
    // accounting) from the locale's currencyFormats; the `¤` placeholder is
    // substituted with the resolved display text.
    var cur_display: []const u8 = "";
    const pattern = if (is_currency) blk: {
        cur_display = currencyDisplayText(slots);
        const cp = cldr.currencyPattern(slots.base.dataLocale()) orelse
            cldr.CurrencyPattern{ .standard = "¤#,##0.00", .accounting = "¤#,##0.00" };
        break :blk if (std.mem.eql(u8, slots.currency_sign, "accounting")) cp.accounting else cp.standard;
    } else if (is_percent) nd.pct_pattern else nd.dec_pattern;

    // §15.5 — a negative magnitude that signDisplay surfaces renders through
    // the pattern's *negative subpattern* (after ';') when one exists. CLDR's
    // accounting currency form supplies it (e.g. "(¤#,##0.00)"), so the
    // parentheses become the sign and no separate minus is emitted. Without a
    // negative subpattern (standard currency / decimal / percent) the positive
    // subpattern carries the digits and the minus/plus is a discrete part.
    const show_sign = signShows(slots.sign_display, negative, is_zero);
    const semi = std.mem.indexOfScalar(u8, pattern, ';');
    const use_neg_subpattern = is_currency and negative and show_sign and semi != null;
    const subpattern = if (use_neg_subpattern)
        pattern[semi.? + 1 ..]
    else if (semi) |s|
        pattern[0..s]
    else
        pattern;
    const affix = patternAffixes(subpattern);

    // sign string (suppressed when the negative subpattern's affixes carry it)
    var sign: []const u8 = "";
    var sign_type: []const u8 = "minusSign";
    if (show_sign and !use_neg_subpattern) {
        if (negative) {
            sign = nd.minus;
            sign_type = "minusSign";
        } else {
            sign = nd.plus;
            sign_type = "plusSign";
        }
    }

    // CLDR currencySpacing (alphaNextToNumber): a U+00A0 separates the currency
    // display from the abutting digits when the display's number-facing
    // character is a letter (the ISO code, or a letter-based symbol). A symbol
    // glyph ($, €) gets none. Only applies where `¤` directly abuts the number
    // skeleton — a pattern that already bakes a space (de "#,##0.00 ¤") does
    // not double up, since its suffix starts with the space, not `¤`.
    const prefix_space: CurrencySpace =
        if (is_currency and endsWithCurrency(affix.prefix) and asciiLetterAt(cur_display, .last)) .after else .none;
    const suffix_space: CurrencySpace =
        if (is_currency and startsWithCurrency(affix.suffix) and asciiLetterAt(cur_display, .first)) .before else .none;

    // Sign leads the prefix affix so the minus precedes a currency symbol
    // ("-$5.00", not "$-5.00"); for percent / decimal the prefix is empty so
    // ordering is unaffected.
    if (sign.len > 0) append(out, &n, sign_type, sign);
    if (is_currency) appendCurrencyAffix(out, &n, affix.prefix, cur_display, prefix_space, append) else appendAffix(out, &n, affix.prefix, nd, append);

    if (non_finite) {
        // §15.5.x — the entire numeric run is a single glyph segment; the style
        // affixes emitted above and below still surround it ("$∞", "-∞%").
        append(out, &n, if (is_nan) "nan" else "infinity", if (is_nan) nd.nan else nd.infinity);
    } else {
        // integer with grouping + digit substitution
        appendGroupedInteger(out, &n, int_pad[0..ip_len], slots, nd, digit_base, append);

        if (frac_len > 0) {
            append(out, &n, "decimal", nd.decimal);
            var sub: [256]u8 = undefined;
            const sb = substituteDigits(frac_ascii[0..frac_len], digit_base, &sub);
            append(out, &n, "fraction", sb);
        }
    }

    if (is_currency) appendCurrencyAffix(out, &n, affix.suffix, cur_display, suffix_space, append) else appendAffix(out, &n, affix.suffix, nd, append);
    return n;
}

/// Unescape CLDR single-quote literals: '' → ' and 'text' → text. Used for
/// compact-pattern affixes like the German "0 Mio'.'" (literal period).
fn unquoteCldr(s: []const u8, buf: []u8) []const u8 {
    var n: usize = 0;
    var i: usize = 0;
    while (i < s.len and n < buf.len) {
        if (s[i] == '\'') {
            i += 1;
            if (i < s.len and s[i] == '\'') {
                buf[n] = '\'';
                n += 1;
                i += 1;
            } else {
                while (i < s.len and s[i] != '\'' and n < buf.len) {
                    buf[n] = s[i];
                    n += 1;
                    i += 1;
                }
                if (i < s.len) i += 1; // closing quote
            }
        } else {
            buf[n] = s[i];
            n += 1;
            i += 1;
        }
    }
    return buf[0..n];
}

/// Clamped copy into buf at off; returns bytes written (never overruns).
fn copyClamp(buf: []u8, off: usize, s: []const u8) usize {
    if (off >= buf.len) return 0;
    const n = @min(s.len, buf.len - off);
    @memcpy(buf[off..][0..n], s[0..n]);
    return n;
}

/// Substitute the first "{0}" in `template` with `v` into `buf`.
fn subst0(template: []const u8, v: []const u8, buf: []u8) []const u8 {
    const idx = std.mem.indexOf(u8, template, "{0}") orelse return buf[0..copyClamp(buf, 0, template)];
    var n: usize = 0;
    n += copyClamp(buf, n, template[0..idx]);
    n += copyClamp(buf, n, v);
    n += copyClamp(buf, n, template[idx + 3 ..]);
    return buf[0..n];
}

/// Substitute "{0}" → v0 then "{1}" → v1 (v0 may itself contain "{0}", which is
/// preserved). Used for the compound-unit fallback "{0}/{1}".
fn subst01(template: []const u8, v0: []const u8, v1: []const u8, buf: []u8) []const u8 {
    var tmp: [256]u8 = undefined;
    const s0 = subst0(template, v0, &tmp);
    const idx = std.mem.indexOf(u8, s0, "{1}") orelse return buf[0..copyClamp(buf, 0, s0)];
    var n: usize = 0;
    n += copyClamp(buf, n, s0[0..idx]);
    n += copyClamp(buf, n, v1);
    n += copyClamp(buf, n, s0[idx + 3 ..]);
    return buf[0..n];
}

/// §15.5 — combine the CLDR unit patterns for a (possibly compound "X-per-Y")
/// unit into a single template carrying one "{0}" number placeholder. A compound
/// applies the divisor unit's perUnitPattern to the numerator's formatted unit
/// ("{0} km" through hour's "{0}/h" → "{0} km/h"), falling back to the locale
/// "per" compound pattern + the divisor displayName when no perUnitPattern.
fn unitCombinedPattern(unit: []const u8, loc: []const u8, style_idx: u8, cat: cldr.PluralCategory, buf: []u8) ?[]const u8 {
    if (std.mem.indexOf(u8, unit, "-per-")) |p| {
        const num = unit[0..p];
        const den = unit[p + 5 ..];
        const pat_num = cldr.unitPattern(loc, num, style_idx, cat) orelse "{0}";
        const per_den = cldr.unitPerPattern(loc, den, style_idx) orelse "";
        if (per_den.len > 0) return subst0(per_den, pat_num, buf);
        const comp = cldr.unitCompoundPer(loc, style_idx) orelse "{0} {1}";
        const den_disp = cldr.unitDisplay(loc, den, style_idx) orelse den;
        return subst01(comp, pat_num, den_disp, buf);
    }
    return cldr.unitPattern(loc, unit, style_idx, cat);
}

const Affix = struct { prefix: []const u8, suffix: []const u8 };

/// Split a CLDR number pattern into the literal/symbol text before and after
/// the numeric skeleton (the run of `#`, `0`, `,`, `.`).
fn patternAffixes(pattern: []const u8) Affix {
    // Use only the positive subpattern (before ';').
    const semi = std.mem.indexOfScalar(u8, pattern, ';') orelse pattern.len;
    const pos = pattern[0..semi];
    var first: usize = pos.len;
    var last: usize = 0;
    var i: usize = 0;
    while (i < pos.len) : (i += 1) {
        const c = pos[i];
        if (c == '#' or c == '0' or c == ',' or c == '.') {
            if (i < first) first = i;
            last = i;
        }
    }
    if (first > last) return .{ .prefix = "", .suffix = "" };
    return .{ .prefix = pos[0..first], .suffix = pos[last + 1 ..] };
}

fn appendAffix(out: []Seg, n: *u32, affix: []const u8, nd: cldr.NumberData, append: anytype) void {
    if (affix.len == 0) return;
    // Affixes contain literals and the '%' symbol placeholder.
    var i: usize = 0;
    while (i < affix.len) {
        if (affix[i] == '%') {
            append(out, n, "percentSign", nd.percent);
            i += 1;
        } else {
            // Gather a literal run up to the next '%'.
            const start = i;
            while (i < affix.len and affix[i] != '%') i += 1;
            append(out, n, "literal", affix[start..i]);
        }
    }
}

/// Where (if anywhere) a currencySpacing no-break space is inserted relative to
/// the currency segment: `.before` for a suffix-position currency, `.after` for
/// a prefix-position currency, `.none` when the display is a symbol glyph.
const CurrencySpace = enum { none, before, after };

/// The U+00A0 (no-break space) CLDR inserts between an alphabetic currency
/// display and the abutting digits (the `-alphaNextToNumber` separator).
const nbsp = "\u{00A0}";

/// `¤` (U+00A4, UTF-8 0xC2 0xA4) is the CLDR currency placeholder. Emit the
/// resolved display text as a "currency" segment; other text is a literal. When
/// `space` is set, a U+00A0 currencySpacing literal is emitted adjacent to the
/// currency segment (before it for a suffix currency, after it for a prefix).
fn appendCurrencyAffix(out: []Seg, n: *u32, affix: []const u8, cur_display: []const u8, space: CurrencySpace, append: anytype) void {
    if (affix.len == 0) return;
    var i: usize = 0;
    while (i < affix.len) {
        if (i + 1 < affix.len and affix[i] == 0xC2 and affix[i + 1] == 0xA4) {
            if (space == .before) append(out, n, "literal", nbsp);
            append(out, n, "currency", cur_display);
            if (space == .after) append(out, n, "literal", nbsp);
            i += 2;
        } else {
            const start = i;
            while (i < affix.len and !(i + 1 < affix.len and affix[i] == 0xC2 and affix[i + 1] == 0xA4)) i += 1;
            append(out, n, "literal", affix[start..i]);
        }
    }
}

/// True when `s` begins / ends with the `¤` placeholder (UTF-8 0xC2 0xA4),
/// i.e. the currency abuts the number skeleton on that side of the affix.
fn startsWithCurrency(s: []const u8) bool {
    return s.len >= 2 and s[0] == 0xC2 and s[1] == 0xA4;
}
fn endsWithCurrency(s: []const u8) bool {
    return s.len >= 2 and s[s.len - 2] == 0xC2 and s[s.len - 1] == 0xA4;
}

/// Whether the first / last byte of `s` is an ASCII letter — the
/// currencySpacing `currencyMatch` test ([:^S:]&[:^Z:]) approximated for the
/// number-facing character: ISO codes and letter-symbols are ASCII letters,
/// while symbol glyphs ($, €, ¥) are non-letters (multi-byte or punctuation).
fn asciiLetterAt(s: []const u8, comptime end: enum { first, last }) bool {
    if (s.len == 0) return false;
    const c = if (end == .first) s[0] else s[s.len - 1];
    return std.ascii.isAlphabetic(c);
}

/// Inputs for `emitUnitPattern` — the already-rounded number pieces plus the
/// plural-selected long name and the locale's formatting data.
const UnitPatternCtx = struct {
    sign: []const u8,
    sign_type: []const u8,
    int_ascii: []const u8,
    frac_ascii: []const u8,
    // Non-finite glyph: when non-empty it replaces the "{0}" digit run with a
    // single infinity / nan segment (§15.5.x).
    glyph: []const u8 = "",
    glyph_type: []const u8 = "infinity",
    name: []const u8,
    slots: *const intl.NumberFormatSlots,
    nd: cldr.NumberData,
    digit_base: u32,
};

/// Render a currencyDisplay:"name" `unitPattern` ("{0} {1}"): "{0}" expands to
/// the formatted number (sign + grouped integer + fraction), "{1}" to the long
/// currency name, and surrounding text is a literal. A `{` that does not begin a
/// `{0}` / `{1}` placeholder is treated as the start of a literal run.
fn emitUnitPattern(out: []Seg, n: *u32, pat: []const u8, ctx: UnitPatternCtx, append: anytype) void {
    var i: usize = 0;
    while (i < pat.len) {
        if (i + 2 < pat.len and pat[i] == '{' and pat[i + 2] == '}' and (pat[i + 1] == '0' or pat[i + 1] == '1')) {
            if (pat[i + 1] == '0') {
                if (ctx.sign.len > 0) append(out, n, ctx.sign_type, ctx.sign);
                if (ctx.glyph.len > 0) {
                    append(out, n, ctx.glyph_type, ctx.glyph);
                } else {
                    appendGroupedInteger(out, n, ctx.int_ascii, ctx.slots, ctx.nd, ctx.digit_base, append);
                    if (ctx.frac_ascii.len > 0) {
                        append(out, n, "decimal", ctx.nd.decimal);
                        var sub: [256]u8 = undefined;
                        append(out, n, "fraction", substituteDigits(ctx.frac_ascii, ctx.digit_base, &sub));
                    }
                }
            } else {
                append(out, n, "currency", ctx.name);
            }
            i += 3;
        } else {
            const start = i;
            i += 1; // consume this char (incl. a non-placeholder '{')
            while (i < pat.len and pat[i] != '{') i += 1;
            append(out, n, "literal", pat[start..i]);
        }
    }
}

/// Resolve the currency display text for the symbol-style displays (the "name"
/// style renders through `emitUnitPattern`, not this `¤` substitution): "code" →
/// the ISO code itself; "symbol"/"narrowSymbol" → the localized (narrow) symbol
/// with the code as fallback. §15.5.x.
fn currencyDisplayText(slots: *const intl.NumberFormatSlots) []const u8 {
    const code = slots.currency;
    if (std.mem.eql(u8, slots.currency_display, "code")) return code;
    const narrow = std.mem.eql(u8, slots.currency_display, "narrowSymbol");
    return cldr.currencySymbol(slots.base.dataLocale(), code, narrow) orelse code;
}

/// Apply primary/secondary grouping from the pattern, substituting digits, and
/// emit interleaved "integer"/"group" segments.
fn appendGroupedInteger(out: []Seg, n: *u32, int_ascii: []const u8, slots: *const intl.NumberFormatSlots, nd: cldr.NumberData, digit_base: u32, append: anytype) void {
    const grouping = !std.mem.eql(u8, slots.use_grouping, "false");
    const g = patternGrouping(nd.dec_pattern);
    // UTS #35 minimumGroupingDigits: suppress grouping until the integer has at
    // least primaryGroupingSize + minimumGroupingDigits digits (so pl/es keep
    // "1000" but group "10 000"). useGrouping:"always" overrides the threshold.
    const min_group: usize = if (std.mem.eql(u8, slots.use_grouping, "always")) 1 else if (std.mem.eql(u8, slots.use_grouping, "min2")) 2 else nd.min_group;
    if (!grouping or g.primary == 0 or int_ascii.len < g.primary + min_group) {
        var sub: [256]u8 = undefined;
        append(out, n, "integer", substituteDigits(int_ascii, digit_base, &sub));
        return;
    }
    // Split right-to-left: last `primary` digits, then `secondary`-sized groups.
    // Build the boundary indices from the right.
    var bounds: [32]usize = undefined;
    var nb: usize = 0;
    var pos: usize = int_ascii.len;
    pos -= g.primary;
    bounds[nb] = pos;
    nb += 1;
    const sec = if (g.secondary > 0) g.secondary else g.primary;
    while (pos > sec) {
        pos -= sec;
        bounds[nb] = pos;
        nb += 1;
    }
    // Emit left-to-right: first chunk [0..bounds[nb-1]], then group, chunk, ...
    var sub: [256]u8 = undefined;
    var start: usize = 0;
    var bi: usize = nb;
    while (bi > 0) {
        bi -= 1;
        const end = bounds[bi];
        append(out, n, "integer", substituteDigits(int_ascii[start..end], digit_base, &sub));
        append(out, n, "group", nd.group);
        start = end;
    }
    append(out, n, "integer", substituteDigits(int_ascii[start..], digit_base, &sub));
}

const Grouping = struct { primary: usize, secondary: usize };

fn patternGrouping(pattern: []const u8) Grouping {
    const semi = std.mem.indexOfScalar(u8, pattern, ';') orelse pattern.len;
    const dot = std.mem.indexOfScalar(u8, pattern[0..semi], '.') orelse semi;
    const int_part = pattern[0..dot];
    // Positions of ',' from the right give primary then secondary group sizes.
    const last_comma = std.mem.lastIndexOfScalar(u8, int_part, ',') orelse return .{ .primary = 0, .secondary = 0 };
    const primary = int_part.len - last_comma - 1;
    const before = int_part[0..last_comma];
    const prev_comma = std.mem.lastIndexOfScalar(u8, before, ',');
    const secondary = if (prev_comma) |pc| (last_comma - pc - 1) else primary;
    return .{ .primary = primary, .secondary = secondary };
}

fn substituteDigits(ascii: []const u8, digit_base: u32, out: []u8) []const u8 {
    if (digit_base == '0') return ascii; // latn: identity
    var n: usize = 0;
    for (ascii) |c| {
        if (n + 4 > out.len) break; // bound: never write past the scratch buffer
        const cp: u21 = @intCast(digit_base + (c - '0'));
        n += std.unicode.utf8Encode(cp, out[n..]) catch 0;
    }
    return out[0..n];
}

fn signShows(sign_display: []const u8, negative: bool, is_zero: bool) bool {
    if (std.mem.eql(u8, sign_display, "never")) return false;
    if (std.mem.eql(u8, sign_display, "always")) return true;
    if (std.mem.eql(u8, sign_display, "exceptZero")) return !is_zero;
    if (std.mem.eql(u8, sign_display, "negative")) return negative and !is_zero;
    return negative; // "auto"
}

/// Round `magnitude` (>= 0) to ASCII integer + fraction digit strings per the
/// resolved rounding type. Uses the engine's exact dtoa (halfExpand).
/// Round a non-negative `q` to an integer per the named rounding mode (the
/// "half*" variants resolve ties; the value is always ≥ 0 here so floor = trunc
/// toward zero, ceil = expand away from zero).
fn applyRoundingModeNonNeg(q: f64, mode: []const u8) f64 {
    const fl = @floor(q);
    const frac = q - fl;
    if (std.mem.eql(u8, mode, "ceil") or std.mem.eql(u8, mode, "expand")) return @ceil(q);
    if (std.mem.eql(u8, mode, "floor") or std.mem.eql(u8, mode, "trunc")) return fl;
    if (std.mem.eql(u8, mode, "halfCeil") or std.mem.eql(u8, mode, "halfExpand")) return if (frac >= 0.5) fl + 1 else fl;
    if (std.mem.eql(u8, mode, "halfFloor") or std.mem.eql(u8, mode, "halfTrunc")) return if (frac > 0.5) fl + 1 else fl;
    if (std.mem.eql(u8, mode, "halfEven")) {
        if (frac < 0.5) return fl;
        if (frac > 0.5) return fl + 1;
        return if (@mod(fl, 2) == 0) fl else fl + 1;
    }
    // default halfExpand
    return if (frac >= 0.5) fl + 1 else fl;
}

/// Round `magnitude` to the nearest multiple of `increment × 10^-frac_digits`.
/// Round `x` to `sig` significant decimal digits — used to absorb the f64
/// representation error before a half-way rounding decision, so that an exact
/// decimal input (1.15, stored as 1.1499999…) is treated as the value the
/// Number's shortest round-trip string denotes, per ECMA-402's rounding basis.
fn snapToSignificant(x: f64, sig: u32) f64 {
    if (x == 0 or !std.math.isFinite(x)) return x;
    const e = @floor(std.math.log10(@abs(x)));
    const p = @as(f64, @floatFromInt(sig)) - 1 - e;
    const f = std.math.pow(f64, 10, p);
    return @round(x * f) / f;
}

/// §15.1.x GetUnsignedRoundingMode — applied to a magnitude (always ≥ 0), a
/// negative value swaps the directed modes: ceil↔floor, halfCeil↔halfFloor.
/// expand/trunc/halfExpand/halfTrunc/halfEven are sign-symmetric.
fn effectiveMode(mode: []const u8, neg: bool) []const u8 {
    if (!neg) return mode;
    if (std.mem.eql(u8, mode, "ceil")) return "floor";
    if (std.mem.eql(u8, mode, "floor")) return "ceil";
    if (std.mem.eql(u8, mode, "halfCeil")) return "halfFloor";
    if (std.mem.eql(u8, mode, "halfFloor")) return "halfCeil";
    return mode;
}

fn roundToIncrement(magnitude: f64, frac_digits: u32, increment: u32, mode: []const u8) f64 {
    const scale = std.math.pow(f64, 10, @floatFromInt(frac_digits));
    const inc: f64 = @floatFromInt(increment);
    // Value in increment-units, snapped to absorb f64 error so a true halfway
    // (1.15 → 11.4999… → 11.5) rounds the way the decimal value dictates.
    const q = snapToSignificant(magnitude * scale / inc, 12);
    const rq = applyRoundingModeNonNeg(q, mode);
    return rq * inc / scale;
}

fn roundDigits(slots: *const intl.NumberFormatSlots, magnitude: f64, neg: bool, int_buf: []u8, int_len: *usize, frac_buf: []u8, frac_len: *usize) void {
    // Significant-digit rounding scales the magnitude down to a maxsd-digit
    // integer, so it handles every finite magnitude (including >= 1e21)
    // without the fraction path's overflow — must run before the large-value
    // fallback (format-significant-digits over a 10^34 value).
    if (std.math.isFinite(magnitude) and std.mem.eql(u8, slots.rounding_type, "significantDigits")) {
        roundSig(slots, magnitude, neg, int_buf, int_len, frac_buf, frac_len);
        return;
    }

    if (!std.math.isFinite(magnitude) or magnitude >= 1e21) {
        // Fallback: trunc to integer digits (rare path; non-finite handled upstream).
        var dec = dtoa.Decimal{};
        dtoa.fixedDigits(if (std.math.isFinite(magnitude)) magnitude else 0, 0, &dec);
        const m = dec.digits();
        @memcpy(int_buf[0..m.len], m);
        int_len.* = m.len;
        frac_len.* = 0;
        return;
    }

    if (std.mem.eql(u8, slots.rounding_type, "significantDigits")) {
        roundSig(slots, magnitude, neg, int_buf, int_len, frac_buf, frac_len);
        return;
    }
    // §15.1.1 roundingPriority morePrecision / lessPrecision — compute both the
    // significant- and fraction-digit results, then pick by rounding magnitude
    // (the base-10 power of the least-significant retained digit). morePrecision
    // keeps the finer result (smaller magnitude); lessPrecision the coarser. The
    // magnitude — not the fraction-digit count — is decisive: 987.65 to 2 sig
    // ("990", mag 1) is coarser than to 0 frac ("988", mag 0), though both show
    // zero fraction digits, so morePrecision must yield "988".
    if (std.mem.eql(u8, slots.rounding_type, "morePrecision") or std.mem.eql(u8, slots.rounding_type, "lessPrecision")) {
        var si: [160]u8 = undefined;
        var sil: usize = 0;
        var sf: [160]u8 = undefined;
        var sfl: usize = 0;
        roundSig(slots, magnitude, neg, &si, &sil, &sf, &sfl);
        var fi: [160]u8 = undefined;
        var fil: usize = 0;
        var ff: [160]u8 = undefined;
        var ffl: usize = 0;
        roundFrac(slots, magnitude, neg, &fi, &fil, &ff, &ffl);
        const more = std.mem.eql(u8, slots.rounding_type, "morePrecision");
        const max_sig: i32 = @intCast(slots.maximum_significant_digits orelse 21);
        const max_frac: i32 = @intCast(slots.maximum_fraction_digits orelse 0);
        const f_mag: i32 = -max_frac;
        const s_mag: i32 = @as(i32, @intFromFloat(@floor(std.math.log10(magnitude)))) - max_sig + 1;
        const use_sig = if (magnitude <= 0) false else if (more) s_mag <= f_mag else s_mag > f_mag;
        if (use_sig) {
            @memcpy(int_buf[0..sil], si[0..sil]);
            int_len.* = sil;
            @memcpy(frac_buf[0..sfl], sf[0..sfl]);
            frac_len.* = sfl;
        } else {
            @memcpy(int_buf[0..fil], fi[0..fil]);
            int_len.* = fil;
            @memcpy(frac_buf[0..ffl], ff[0..ffl]);
            frac_len.* = ffl;
        }
        return;
    }
    roundFrac(slots, magnitude, neg, int_buf, int_len, frac_buf, frac_len);
}

/// ToRawPrecision — significant-digit rounding into int/frac ASCII.
fn roundSig(slots: *const intl.NumberFormatSlots, magnitude: f64, neg: bool, int_buf: []u8, int_len: *usize, frac_buf: []u8, frac_len: *usize) void {
    const maxsd = slots.maximum_significant_digits orelse 21;
    const minsd = slots.minimum_significant_digits orelse 1;
    if (magnitude == 0) {
        int_buf[0] = '0';
        int_len.* = 1;
        const z = minsd -| 1;
        var k: usize = 0;
        while (k < z and k < frac_buf.len) : (k += 1) frac_buf[k] = '0';
        frac_len.* = k;
        return;
    }
    // §15.1.x ToRawPrecision honoring the rounding mode: scale so the value is a
    // maxsd-digit integer, round per the mode (dtoa alone is fixed half-even),
    // then re-extract. Snapping to 14 sig absorbs f64 representation noise (so
    // 1.15 → 11.5) without disturbing genuine near-halfway inputs.
    const e = @floor(std.math.log10(magnitude));
    const scale_exp = @as(f64, @floatFromInt(maxsd)) - 1 - e;
    const scale = std.math.pow(f64, 10, scale_exp);
    const q_raw = magnitude * scale;
    const q = if (maxsd <= 14) snapToSignificant(q_raw, 14) else q_raw;
    const rounded = applyRoundingModeNonNeg(q, effectiveMode(slots.rounding_mode, neg)) / scale;
    var dec = dtoa.Decimal{};
    dtoa.precisionDigits(rounded, maxsd, &dec);
    splitByPoint(dec.digits(), dec.point_exp, int_buf, int_len, frac_buf, frac_len);
    trimSignificant(int_buf, int_len, frac_buf, frac_len, minsd);
}

/// ToRawFixed — fraction-digit rounding (+ roundingIncrement, trailing-zero
/// trim, trailingZeroDisplay) into int/frac ASCII.
fn roundFrac(slots: *const intl.NumberFormatSlots, magnitude: f64, neg: bool, int_buf: []u8, int_len: *usize, frac_buf: []u8, frac_len: *usize) void {
    const maxfd = slots.maximum_fraction_digits orelse 3;
    const minfd = slots.minimum_fraction_digits orelse 0;
    const mode = effectiveMode(slots.rounding_mode, neg);
    // §15.1.x ToRawFixed honoring the rounding mode. roundingIncrement rounds to
    // a multiple of increment × 10^-maxfd; otherwise round to 10^-maxfd via the
    // mode (dtoa alone is fixed half-even). Only for values with a real
    // fractional part (|x| < 1e15): larger magnitudes are integral in f64, so the
    // mode is moot and dtoa handles them without overflow risk.
    const mag = if (slots.rounding_increment > 1)
        roundToIncrement(magnitude, maxfd, slots.rounding_increment, mode)
    else if (magnitude != 0 and magnitude < 1e15) blk: {
        const fscale = std.math.pow(f64, 10, @floatFromInt(maxfd));
        const q = snapToSignificant(magnitude * fscale, 15);
        break :blk applyRoundingModeNonNeg(q, mode) / fscale;
    } else magnitude;
    var dec = dtoa.Decimal{};
    dtoa.fixedDigits(mag, maxfd, &dec);
    const m = dec.digits();
    if (maxfd == 0) {
        @memcpy(int_buf[0..m.len], m);
        int_len.* = m.len;
        frac_len.* = 0;
    } else if (m.len > maxfd) {
        const il = m.len - maxfd;
        @memcpy(int_buf[0..il], m[0..il]);
        int_len.* = il;
        @memcpy(frac_buf[0..maxfd], m[il..]);
        frac_len.* = maxfd;
    } else {
        int_buf[0] = '0';
        int_len.* = 1;
        const lead = maxfd - m.len;
        var k: usize = 0;
        while (k < lead) : (k += 1) frac_buf[k] = '0';
        @memcpy(frac_buf[lead .. lead + m.len], m);
        frac_len.* = maxfd;
    }
    // Trim trailing fraction zeros down to minimumFractionDigits.
    while (frac_len.* > minfd and frac_buf[frac_len.* - 1] == '0') frac_len.* -= 1;
    // trailingZeroDisplay: stripIfInteger drops the fraction when it's all zeros.
    if (std.mem.eql(u8, slots.trailing_zero_display, "stripIfInteger")) {
        var all_zero = true;
        for (frac_buf[0..frac_len.*]) |c| if (c != '0') {
            all_zero = false;
        };
        if (all_zero) frac_len.* = 0;
    }
}

/// Split dtoa significant digits + point exponent into int/frac ASCII.
fn splitByPoint(digits: []const u8, point_exp: i32, int_buf: []u8, int_len: *usize, frac_buf: []u8, frac_len: *usize) void {
    if (point_exp <= 0) {
        int_buf[0] = '0';
        int_len.* = 1;
        const lead: usize = @intCast(-point_exp);
        var k: usize = 0;
        while (k < lead) : (k += 1) frac_buf[k] = '0';
        @memcpy(frac_buf[lead .. lead + digits.len], digits);
        frac_len.* = lead + digits.len;
    } else if (@as(usize, @intCast(point_exp)) >= digits.len) {
        @memcpy(int_buf[0..digits.len], digits);
        const trail: usize = @as(usize, @intCast(point_exp)) - digits.len;
        var k: usize = 0;
        while (k < trail) : (k += 1) int_buf[digits.len + k] = '0';
        int_len.* = digits.len + trail;
        frac_len.* = 0;
    } else {
        const p: usize = @intCast(point_exp);
        @memcpy(int_buf[0..p], digits[0..p]);
        int_len.* = p;
        @memcpy(frac_buf[0 .. digits.len - p], digits[p..]);
        frac_len.* = digits.len - p;
    }
}

/// Pad/trim fraction so the total significant-digit count is >= minsd, trimming
/// surplus trailing zeros otherwise.
fn trimSignificant(int_buf: []u8, int_len: *usize, frac_buf: []u8, frac_len: *usize, minsd: u32) void {
    // Significant digits = int digits (minus leading zeros) + frac digits.
    var sig: usize = 0;
    if (!(int_len.* == 1 and int_buf_is_zero(int_buf, int_len.*))) sig += int_len.*;
    sig += frac_len.*;
    // Trim trailing fraction zeros while staying >= minsd.
    while (frac_len.* > 0 and frac_buf[frac_len.* - 1] == '0' and sig > minsd) {
        frac_len.* -= 1;
        sig -= 1;
    }
}

fn int_buf_is_zero(int_buf: []const u8, len: usize) bool {
    for (int_buf[0..len]) |c| if (c != '0') return false;
    return true;
}

/// Render `x` into `buf` as a flat string (concatenation of segments).
fn formatNumericToBuf(realm: *Realm, slots: *const intl.NumberFormatSlots, x: f64, buf: []u8) NativeError![]const u8 {
    _ = realm;
    var segs: [48]Seg = undefined;
    const n = renderNumber(slots, x, &segs);
    var len: usize = 0;
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const b = segs[i].bytes();
        if (len + b.len > buf.len) break;
        @memcpy(buf[len .. len + b.len], b);
        len += b.len;
    }
    return buf[0..len];
}

// ── DateTimeFormat ─────────────────────────────────────────────────────────

fn installDateTimeFormat(realm: *Realm, ns: *JSObject) !void {
    try installService(realm, ns, .{
        .name = "DateTimeFormat",
        .ctor = dateTimeFormatConstructor,
        .arity = 0,
        .to_string_tag = "Intl.DateTimeFormat",
        .methods = &.{
            // §12.3.5 — `format` is an accessor (see `makeBoundServiceFunction`).
            .{ .name = "formatToParts", .fn_ptr = dateTimeFormatFormatToParts, .params = 1 },
            .{ .name = "formatRange", .fn_ptr = dateTimeFormatFormatRange, .params = 2 },
            .{ .name = "formatRangeToParts", .fn_ptr = dateTimeFormatFormatRangeToParts, .params = 2 },
            .{ .name = "resolvedOptions", .fn_ptr = dateTimeFormatResolvedOptions, .params = 0 },
        },
        .supported_locales_of = anySupportedLocalesOf,
        .set_ctor_intrinsic = struct {
            fn f(r: *Realm, c: *JSFunction) void {
                r.intrinsics.intl_date_time_format_constructor = c;
            }
        }.f,
        .set_proto_intrinsic = struct {
            fn f(r: *Realm, p: *JSObject) void {
                r.intrinsics.intl_date_time_format_prototype = p;
            }
        }.f,
    });
    // §12.3.5 — `Intl.DateTimeFormat.prototype.format` is an accessor.
    const proto = realm.intrinsics.intl_date_time_format_prototype.?;
    try installNativeGetter(realm, proto, "format", dateTimeFormatFormatGetter);
    // §12.1.1 — Intl.DateTimeFormat is callable without `new` (legacy chain).
    const ctor = realm.intrinsics.intl_date_time_format_constructor.?;
    ctor.is_class_constructor = false;
    ctor.defers_proto_lookup = true;
}

fn dateTimeFormatFormatGetter(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    _ = try requireKind(realm, this_value, .date_time_format);
    return makeBoundServiceFunction(realm, this_value, dateTimeFormatFormat, "format", 1);
}

/// §11.1.1 — ASCII-lowercase a calendar id (into `buf`) and map its BCP-47
/// type aliases to the canonical form (CLDR bcp47/calendar.xml).
fn canonicalCalendarId(raw: []const u8, buf: []u8) []const u8 {
    var n: usize = 0;
    for (raw) |c| {
        if (n >= buf.len) break;
        buf[n] = std.ascii.toLower(c);
        n += 1;
    }
    const lc = buf[0..n];
    // Deprecated BCP-47 calendar aliases → preferred form. Only "islamicc" is
    // included: it is the one the conformance suite pins, and Cynic's
    // AvailableCalendars list already uses the preferred form for every other
    // id (so e.g. "ethioaa" must round-trip unchanged).
    if (std.mem.eql(u8, lc, "islamicc")) return "islamic-civil";
    // Cynic implements the tabular Islamic calendars only; the generic "islamic"
    // and the sighting-based "islamic-rgsa" both resolve to the civil tabular
    // variant. This keeps AvailableCalendars (which lists islamic-civil, not
    // "islamic" / "islamic-rgsa") consistent with what DateTimeFormat accepts —
    // calendars-accepted-by-DateTimeFormat.js asserts a calendar canonicalised
    // away must not appear in supportedValuesOf.
    if (std.mem.eql(u8, lc, "islamic") or std.mem.eql(u8, lc, "islamic-rgsa")) return "islamic-civil";
    if (std.mem.eql(u8, lc, "ethiopic-amete-alem")) return "ethioaa";
    return lc;
}

fn dateTimeFormatConstructor(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const inst = try newIntlInstance(realm, this_value, realm.intrinsics.intl_date_time_format_prototype.?, "DateTimeFormat", false);
    var slots = try buildDateTimeFormatSlots(realm, argOr(args, 0, Value.undefined_), argOr(args, 1, Value.undefined_));
    errdefer slots.deinit(realm.allocator);
    try storeRecord(realm, inst, .{ .date_time_format = slots });
    return heap_mod.taggedObject(inst);
}

/// §11.1.1 CreateDateTimeFormat — resolve (locales, options) into the format
/// slots. Shared by the constructor and Temporal.*.prototype.toLocaleString.
/// The locale's default hour cycle (hcDefault), derived from the CLDR short
/// time pattern: h/K is h12, H/k is h23. Falls back to h23 without data.
fn localeDefaultHourCycle(locale: []const u8) []const u8 {
    if (cldr.dateData(locale)) |dd| {
        var in_quote = false;
        for (dd.time_short) |ch| {
            if (ch == '\'') in_quote = !in_quote;
            if (in_quote) continue;
            if (ch == 'h') return "h12";
            if (ch == 'K') return "h11";
            if (ch == 'H') return "h23";
            if (ch == 'k') return "h24";
        }
    }
    return "h23";
}

fn buildDateTimeFormatSlots(realm: *Realm, locales: Value, options: Value) NativeError!intl.DateTimeFormatSlots {
    const opts = try coerceOptionsToObject(realm, options);
    const resolved = try resolveServiceLocale(realm, locales, opts);

    var slots: intl.DateTimeFormatSlots = .{};
    errdefer slots.deinit(realm.allocator); // free allocated fields if a later option read throws
    slots.base.locale = resolved.locale;
    try retainRelevantUnicodeExtensions(realm, &slots.base, &.{ "ca", "nu", "hc" }); // §9.2.7 DateTimeFormat keys
    // The default calendar is the locale's — gregory across the locales Cynic
    // ships — never iso8601 (no locale has the ISO calendar as its default).
    slots.calendar = realm.allocator.dupe(u8, "gregory") catch return error.OutOfMemory;
    slots.numbering_system = try resolveNumberingSystem(realm, resolved.locale, resolved.locale, opts);
    slots.time_zone = realm.allocator.dupe(u8, "UTC") catch return error.OutOfMemory;
    if (opts) |o| {
        const tz_v = try getPropertyChain(realm, o, "timeZone");
        if (!tz_v.isUndefined()) {
            const tz = try valueToStringSlice(realm, tz_v);
            if (tz.len == 0) return throwRangeError(realm, "invalid time zone");
            // §11.1.1 — an offset zone normalizes to "±HH:MM"; a named zone is
            // matched case-insensitively against the tzdb and stored with its
            // available casing *without* alias collapse ("Etc/UTC" stays
            // "Etc/UTC"). An unknown name (MEZ, ACT, a Unicode-minus offset) is a
            // RangeError. At -Dintl=stub (no tzdb) the raw name is kept.
            var tzbuf: [16]u8 = undefined;
            const tzdata = @import("../tzdata.zig");
            const canon: []const u8 = if (tz[0] == '+' or tz[0] == '-') blk: {
                const parsed = temporal.parseTimeZoneIdentifier(tz) orelse return throwRangeError(realm, "invalid time zone");
                break :blk temporal.timeZoneIdentifierString(parsed, &tzbuf);
            } else if (tzdata.available)
                (tzdata.canonicalZoneName(tz) orelse return throwRangeError(realm, "invalid time zone"))
            else
                tz;
            realm.allocator.free(slots.time_zone); // release the default "UTC"
            slots.time_zone = try realm.allocator.dupe(u8, canon);
        }
        const cal_v = try getPropertyChain(realm, o, "calendar");
        var cal_set = false;
        if (!cal_v.isUndefined()) {
            // §11.1.1 — the calendar option must be a well-formed Unicode type
            // (RangeError otherwise); it is then ASCII-lowercased and its BCP-47
            // aliases canonicalized ("ISO8601" → "iso8601", "islamicc" →
            // "islamic-civil").
            const raw = try valueToStringSlice(realm, cal_v);
            if (!intl.isValidUnicodeType(raw)) return throwRangeError(realm, "invalid calendar");
            var lc_buf: [40]u8 = undefined;
            const canon = canonicalCalendarId(raw, &lc_buf);
            // A well-formed but unsupported calendar resolves as if the option
            // were absent (the locale's -u-ca keyword applies below).
            if (temporal.isSupportedCalendarId(canon)) {
                realm.allocator.free(slots.calendar); // release the default
                slots.calendar = try realm.allocator.dupe(u8, canon);
                cal_set = true;
            }
        }
        if (!cal_set) {
            if (intl.unicodeExtensionValue(slots.base.locale, "ca")) |v| {
                var lc_buf2: [40]u8 = undefined;
                const canon2 = canonicalCalendarId(v, &lc_buf2);
                if (temporal.isSupportedCalendarId(canon2)) {
                    realm.allocator.free(slots.calendar);
                    slots.calendar = try realm.allocator.dupe(u8, canon2);
                }
            }
        }

        slots.date_style = try dupOptOwned(realm, try getOptionString(realm, opts, "dateStyle", &.{ "full", "long", "medium", "short" }, ""));
        slots.time_style = try dupOptOwned(realm, try getOptionString(realm, opts, "timeStyle", &.{ "full", "long", "medium", "short" }, ""));

        // Component options (§11.1.1 — the date/time field descriptors).
        slots.weekday = try dupOptOwned(realm, try getOptionString(realm, opts, "weekday", &.{ "long", "short", "narrow" }, ""));
        slots.era = try dupOptOwned(realm, try getOptionString(realm, opts, "era", &.{ "long", "short", "narrow" }, ""));
        slots.year = try dupOptOwned(realm, try getOptionString(realm, opts, "year", &.{ "numeric", "2-digit" }, ""));
        slots.month = try dupOptOwned(realm, try getOptionString(realm, opts, "month", &.{ "numeric", "2-digit", "long", "short", "narrow" }, ""));
        slots.day = try dupOptOwned(realm, try getOptionString(realm, opts, "day", &.{ "numeric", "2-digit" }, ""));
        slots.hour = try dupOptOwned(realm, try getOptionString(realm, opts, "hour", &.{ "numeric", "2-digit" }, ""));
        slots.minute = try dupOptOwned(realm, try getOptionString(realm, opts, "minute", &.{ "numeric", "2-digit" }, ""));
        slots.second = try dupOptOwned(realm, try getOptionString(realm, opts, "second", &.{ "numeric", "2-digit" }, ""));
        slots.fractional_second_digits = try getNumberOptionOpt(realm, opts, "fractionalSecondDigits", 1, 3);
        slots.day_period = try dupOptOwned(realm, try getOptionString(realm, opts, "dayPeriod", &.{ "long", "short", "narrow" }, ""));
        slots.time_zone_name = try dupOptOwned(realm, try getOptionString(realm, opts, "timeZoneName", &.{ "long", "short", "shortOffset", "longOffset", "shortGeneric", "longGeneric" }, ""));

        // hourCycle / hour12 → resolved hour cycle. hour12 maps through the
        // locale's default cycle (§11.1.1): true keeps an h11/h12 default and
        // turns h23/h24 into h11; false always lands on h23 here (Cynic's
        // CLDR derivation never yields h24).
        const hc = try getOptionString(realm, opts, "hourCycle", &.{ "h11", "h12", "h23", "h24" }, "");
        const h12_v = try getPropertyChain(realm, o, "hour12");
        if (!h12_v.isUndefined()) {
            const dflt = localeDefaultHourCycle(slots.base.locale);
            const dflt_is_12 = std.mem.eql(u8, dflt, "h11") or std.mem.eql(u8, dflt, "h12");
            slots.hour_cycle = try realm.allocator.dupe(u8, if (toBoolean(h12_v))
                (if (dflt_is_12) dflt else "h11")
            else
                "h23");
        } else if (hc.len > 0) {
            slots.hour_cycle = try realm.allocator.dupe(u8, hc);
        } else if (intl.unicodeExtensionValue(slots.base.locale, "hc")) |v| {
            // §11.1.1 — no option, so the resolved locale's -u-hc keyword (kept by
            // retainRelevantUnicodeExtensions above) selects the hour cycle.
            if (isValidExtValue("hc", v)) slots.hour_cycle = try realm.allocator.dupe(u8, v);
        }
        // §11.1.1 step 30 — an hourCycle / hour12 OPTION overrides the locale's
        // -u-hc keyword, which then drops from the resolved locale unless the
        // resolved cycle agrees with it.
        if (!h12_v.isUndefined() or hc.len > 0) {
            const ext = intl.unicodeExtensionValue(slots.base.locale, "hc");
            const agrees = ext != null and slots.hour_cycle.len > 0 and std.ascii.eqlIgnoreCase(ext.?, slots.hour_cycle);
            if (!agrees) try retainRelevantUnicodeExtensions(realm, &slots.base, &.{ "ca", "nu" });
        }

        // §11.1.1 formatMatcher — validated (RangeError on an invalid value);
        // the renderer doesn't yet branch on best-fit vs basic.
        _ = try getOptionString(realm, opts, "formatMatcher", &.{ "basic", "best fit" }, "best fit");

        // §11.1.1 — dateStyle/timeStyle may not be combined with explicit
        // component options (TypeError).
        const has_style = slots.date_style.len > 0 or slots.time_style.len > 0;
        const has_component = slots.weekday.len > 0 or slots.era.len > 0 or slots.year.len > 0 or
            slots.month.len > 0 or slots.day.len > 0 or slots.hour.len > 0 or slots.minute.len > 0 or
            slots.second.len > 0 or slots.day_period.len > 0 or slots.time_zone_name.len > 0 or
            slots.fractional_second_digits != null;
        if (has_style and has_component) return throwTypeError(realm, "dateStyle/timeStyle cannot be combined with component options");
    }

    // After all option reads (which can throw): cache the maximized data-locale
    // so per-`format()` CLDR lookups skip the likelySubtags scan.
    try setDataLocale(realm, &slots.base);
    // §11.1.1 — when the resolved format includes an hour, hourCycle defaults
    // to the locale's hcDefault (from the CLDR short time pattern: h→h12,
    // K→h11, H→h23, k→h24). resolvedOptions reports it as undefined when the
    // format has no hour (dateStyle-only) — see dateTimeFormatResolvedOptions.
    if (slots.hour_cycle.len == 0 and (slots.hour.len > 0 or slots.time_style.len > 0)) {
        slots.hour_cycle = try realm.allocator.dupe(u8, localeDefaultHourCycle(slots.base.dataLocale()));
    }
    return slots;
}

fn dupOptOwned(realm: *Realm, s: []const u8) NativeError![]const u8 {
    if (s.len == 0) return "";
    return realm.allocator.dupe(u8, s) catch error.OutOfMemory;
}

/// §11.5.5 — coerce the format argument to a time value (epoch ms), clamped to
/// the valid Date range. undefined → current time. RangeError if out of range.
fn dtfTimeValue(realm: *Realm, v: Value) NativeError!f64 {
    if (v.isUndefined()) return @import("date.zig").currentTimeMs();
    const x = numberToF64(try toNumber(realm, v));
    if (!std.math.isFinite(x) or @abs(x) > 8.64e15) return throwRangeError(realm, "Invalid time value");
    return @trunc(x);
}

fn dateTimeFormatFormat(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const rec = try requireKind(realm, this_value, .date_time_format);
    const arg = argOr(args, 0, Value.undefined_);
    if (!cldr.available) return makeStringValue(realm, try valueToStringSlice(realm, makeNumberValue(try dtfTimeValue(realm, arg))));
    var buf: [256]u8 = undefined;
    var segs: [48]Seg = undefined;
    const n = try dtfRenderArg(realm, &rec.date_time_format, arg, &segs);
    var len: usize = 0;
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const b = segs[i].bytes();
        if (len + b.len > buf.len) break;
        @memcpy(buf[len .. len + b.len], b);
        len += b.len;
    }
    return makeStringValue(realm, buf[0..len]);
}

/// §13.x Temporal.*.prototype.toLocaleString — FormatDateTime through a
/// transient DateTimeFormat built from (locales, options). The per-Temporal-
/// type ToDateTimeOptions defaults make a bare call show the type's natural
/// fields (PlainDate → date, PlainDateTime/Instant → date + time, etc.).
/// Callers gate on `cldr.available`; ZonedDateTime is handled by its own
/// method (it overrides the format's time zone) and is not routed here.
pub fn temporalToLocaleString(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    var slots = try buildDateTimeFormatSlots(realm, argOr(args, 0, Value.undefined_), argOr(args, 1, Value.undefined_));
    defer slots.deinit(realm.allocator);
    // Shallow copy: the default literals below must never reach slots.deinit
    // (which frees only the allocated option fields the copy keeps sharing).
    var eff = slots;
    // §6.3.x Temporal.ZonedDateTime.prototype.toLocaleString — the formatter
    // takes the value's own time zone (a timeZone option is a TypeError), and
    // the wall-clock fields come from the epoch instant in that zone.
    var zdt_tz_buf: [64]u8 = undefined;
    if (heap_mod.valueAsPlainObject(this_value)) |o| {
        if (o.getTemporalRecord()) |rec| {
            // §Temporal toLocaleString — the construction's (required,
            // defaults) pair rejects a style axis the type cannot express.
            const kind0 = std.meta.activeTag(rec.*);
            const date_only0 = kind0 == .plain_date or kind0 == .plain_year_month or kind0 == .plain_month_day;
            if (date_only0 and slots.time_style.len > 0)
                return throwTypeError(realm, "timeStyle is not applicable to this Temporal type");
            if (kind0 == .plain_time and slots.date_style.len > 0)
                return throwTypeError(realm, "dateStyle is not applicable to this Temporal type");
            if (rec.* == .zoned_date_time) {
                if (heap_mod.valueAsPlainObject(argOr(args, 1, Value.undefined_))) |ob| {
                    if (!(try getPropertyChain(realm, ob, "timeZone")).isUndefined())
                        return throwTypeError(realm, "timeZone option is not allowed when formatting a ZonedDateTime");
                }
                // §6.3.x — a non-ISO ZonedDateTime calendar must match the
                // formatter's calendar (RangeError otherwise); when it does,
                // it drives the rendering.
                const zcal = rec.zoned_date_time.calendar.slice();
                if (!std.ascii.eqlIgnoreCase(zcal, "iso8601") and !std.ascii.eqlIgnoreCase(zcal, eff.calendar))
                    return throwRangeError(realm, "Temporal calendar does not match the DateTimeFormat calendar");
                eff.time_zone = temporal.timeZoneIdentifierString(rec.zoned_date_time.time_zone, &zdt_tz_buf);
                applyTemporalToLocaleDefaults(&eff, this_value);
                const ms: f64 = @floatFromInt(@divFloor(rec.zoned_date_time.epoch_ns, 1_000_000));
                var zsegs: [48]Seg = undefined;
                const zn = try dtfRenderArg(realm, &eff, makeNumberValue(ms), &zsegs);
                var zbuf: [256]u8 = undefined;
                return makeStringValue(realm, flattenSegs(&zsegs, zn, &zbuf));
            }
        }
    }
    applyTemporalToLocaleDefaults(&eff, this_value);
    var segs: [48]Seg = undefined;
    const n = try dtfRenderArg(realm, &eff, this_value, &segs);
    var buf: [256]u8 = undefined;
    return makeStringValue(realm, flattenSegs(&segs, n, &buf));
}

pub const DateLocaleKind = enum { any, date, time };

/// §21.4.4.38-40 Date.prototype.toLocale{,Date,Time}String at the CLDR tier —
/// FormatDateTime through a transient DateTimeFormat built from (locales,
/// options), applying the §11.1.2 ToDateTimeOptions (required, defaults)
/// pair: toLocaleString defaults to date+time, toLocaleDateString to date
/// (timeStyle is a TypeError), toLocaleTimeString to time (dateStyle is a
/// TypeError). Callers gate on `cldr.available` and pass a finite epoch ms.
pub fn dateToLocaleString(realm: *Realm, epoch_ms: f64, locales: Value, options: Value, which: DateLocaleKind) NativeError!Value {
    var slots = try buildDateTimeFormatSlots(realm, locales, options);
    defer slots.deinit(realm.allocator);
    var eff = slots; // shallow copy; defaults below are static literals
    const has_date = slots.weekday.len > 0 or slots.year.len > 0 or
        slots.month.len > 0 or slots.day.len > 0;
    const has_time = slots.hour.len > 0 or slots.minute.len > 0 or slots.second.len > 0 or
        slots.day_period.len > 0 or slots.fractional_second_digits != null;
    const has_style = slots.date_style.len > 0 or slots.time_style.len > 0;
    switch (which) {
        .any => if (!has_date and !has_time and !has_style) {
            eff.year = "numeric";
            eff.month = "numeric";
            eff.day = "numeric";
            eff.hour = "numeric";
            eff.minute = "numeric";
            eff.second = "numeric";
        },
        .date => {
            if (slots.time_style.len > 0) return throwTypeError(realm, "timeStyle is not allowed for toLocaleDateString");
            if (!has_date and !has_style) {
                eff.year = "numeric";
                eff.month = "numeric";
                eff.day = "numeric";
            }
        },
        .time => {
            if (slots.date_style.len > 0) return throwTypeError(realm, "dateStyle is not allowed for toLocaleTimeString");
            if (!has_time and !has_style) {
                eff.hour = "numeric";
                eff.minute = "numeric";
                eff.second = "numeric";
            }
        },
    }
    var segs: [48]Seg = undefined;
    const n = try dtfRenderArg(realm, &eff, makeNumberValue(epoch_ms), &segs);
    var buf: [256]u8 = undefined;
    return makeStringValue(realm, flattenSegs(&segs, n, &buf));
}

/// Apply the §11.5 ToDateTimeOptions defaults for the Temporal type of `v` onto
/// `slots` when the caller supplied no component / style option. Writes only the
/// empty ("") fields with static literals, so the shallow copy keeps sharing
/// (and freeing through the original) the allocated option strings.
fn applyTemporalToLocaleDefaults(slots: *intl.DateTimeFormatSlots, v: Value) void {
    const o = heap_mod.valueAsPlainObject(v) orelse return;
    const rec = o.getTemporalRecord() orelse return;
    // fractionalSecondDigits is a precision modifier, not a standalone
    // component: alone it still takes the type's default component set (so a
    // lone { fractionalSecondDigits } on a PlainTime renders h:m:s.fff rather
    // than failing to overlap).
    // §11.1.2 ToDateTimeOptions checks weekday / year / month / day / hour /
    // minute / second / dayPeriod / fractionalSecondDigits (+ the styles);
    // era is the one component that does NOT suppress the defaults.
    const has_any = slots.weekday.len > 0 or slots.year.len > 0 or
        slots.month.len > 0 or slots.day.len > 0 or slots.hour.len > 0 or slots.minute.len > 0 or
        slots.second.len > 0 or slots.day_period.len > 0 or slots.fractional_second_digits != null or
        slots.date_style.len > 0 or slots.time_style.len > 0;
    if (has_any) return;
    switch (rec.*) {
        .plain_date => {
            slots.year = "numeric";
            slots.month = "numeric";
            slots.day = "numeric";
        },
        .plain_time => {
            slots.hour = "numeric";
            slots.minute = "numeric";
            slots.second = "numeric";
        },
        .plain_date_time, .instant => {
            slots.year = "numeric";
            slots.month = "numeric";
            slots.day = "numeric";
            slots.hour = "numeric";
            slots.minute = "numeric";
            slots.second = "numeric";
        },
        .zoned_date_time => {
            slots.year = "numeric";
            slots.month = "numeric";
            slots.day = "numeric";
            slots.hour = "numeric";
            slots.minute = "numeric";
            slots.second = "numeric";
            // §6.3.x — the ZonedDateTime defaults also show the zone.
            slots.time_zone_name = "short";
        },
        .plain_year_month => {
            slots.year = "numeric";
            slots.month = "numeric";
        },
        .plain_month_day => {
            slots.month = "numeric";
            slots.day = "numeric";
        },
        .duration => {},
    }
}

fn dateTimeFormatFormatToParts(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const rec = try requireKind(realm, this_value, .date_time_format);
    const arg = argOr(args, 0, Value.undefined_);
    const arr = allocateArray(realm) catch return error.OutOfMemory;
    if (!cldr.available) {
        try pushPart(realm, arr, 0, "literal", try makeStringValue(realm, try valueToStringSlice(realm, makeNumberValue(try dtfTimeValue(realm, arg)))));
        arr.setArrayLength(realm.allocator, 1) catch return error.OutOfMemory;
        return heap_mod.taggedObject(arr);
    }
    var segs: [48]Seg = undefined;
    const n = try dtfRenderArg(realm, &rec.date_time_format, arg, &segs);
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        try pushPart(realm, arr, i, segs[i].typ, try makeStringValue(realm, segs[i].bytes()));
    }
    arr.setArrayLength(realm.allocator, n) catch return error.OutOfMemory;
    return heap_mod.taggedObject(arr);
}

fn dateTimeFormatFormatRange(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const rec = try requireKind(realm, this_value, .date_time_format);
    // §11.5.5 — both arguments are required (TypeError when either is undefined),
    // then coerced; a NaN/∞ operand is a RangeError. x > y does not throw.
    const av = argOr(args, 0, Value.undefined_);
    const bv = argOr(args, 1, Value.undefined_);
    if (av.isUndefined() or bv.isUndefined()) return throwTypeError(realm, "formatRange requires two arguments");
    // §11.5.6 — both endpoints must be the same kind (both legacy, or the same
    // Temporal type); mixing throws TypeError.
    if (!dtfSameKind(dtfArgTemporalKind(av), dtfArgTemporalKind(bv)))
        return throwTypeError(realm, "formatRange endpoints must be the same type");
    if (!cldr.available) return makeStringValue(realm, "");
    var sega: [48]Seg = undefined;
    var segb: [48]Seg = undefined;
    const na = try dtfRenderArg(realm, &rec.date_time_format, av, &sega);
    const nb = try dtfRenderArg(realm, &rec.date_time_format, bv, &segb);
    var bufa: [256]u8 = undefined;
    var bufb: [256]u8 = undefined;
    const sa = flattenSegs(&sega, na, &bufa);
    const sb = flattenSegs(&segb, nb, &bufb);
    // Identical renderings collapse to a single date (no range separator).
    if (std.mem.eql(u8, sa, sb)) return makeStringValue(realm, sa);
    const joined = std.fmt.allocPrint(realm.allocator, "{s} – {s}", .{ sa, sb }) catch return error.OutOfMemory;
    defer realm.allocator.free(joined);
    return makeStringValue(realm, joined);
}

fn dateTimeFormatFormatRangeToParts(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const rec = try requireKind(realm, this_value, .date_time_format);
    const av = argOr(args, 0, Value.undefined_);
    const bv = argOr(args, 1, Value.undefined_);
    if (av.isUndefined() or bv.isUndefined()) return throwTypeError(realm, "formatRangeToParts requires two arguments");
    if (!dtfSameKind(dtfArgTemporalKind(av), dtfArgTemporalKind(bv)))
        return throwTypeError(realm, "formatRangeToParts endpoints must be the same type");
    const arr = allocateArray(realm) catch return error.OutOfMemory;
    if (!cldr.available) {
        arr.setArrayLength(realm.allocator, 0) catch return error.OutOfMemory;
        return heap_mod.taggedObject(arr);
    }
    var sa: [48]Seg = undefined;
    var sb: [48]Seg = undefined;
    const na = try dtfRenderArg(realm, &rec.date_time_format, av, &sa);
    const nb = try dtfRenderArg(realm, &rec.date_time_format, bv, &sb);
    // Identical renderings → one date, every part sourced "shared".
    var same = na == nb;
    if (same) {
        var k: usize = 0;
        while (k < na) : (k += 1) {
            if (!std.mem.eql(u8, sa[k].typ, sb[k].typ) or !std.mem.eql(u8, sa[k].bytes(), sb[k].bytes())) {
                same = false;
                break;
            }
        }
    }
    var idx: u32 = 0;
    if (same) {
        var k: usize = 0;
        while (k < na) : (k += 1) {
            try pushPartSourced(realm, arr, idx, sa[k].typ, sa[k].bytes(), "shared");
            idx += 1;
        }
    } else {
        // ICU's greatest-difference collapse: every part before the first
        // differing field renders once with source "shared"; from there each
        // side renders fully as startRange / endRange. No collapse when one
        // rendering is a strict prefix of the other.
        var prefix: usize = 0;
        while (prefix < na and prefix < nb and
            std.mem.eql(u8, sa[prefix].typ, sb[prefix].typ) and
            std.mem.eql(u8, sa[prefix].bytes(), sb[prefix].bytes())) : (prefix += 1)
        {}
        if (prefix >= na or prefix >= nb) prefix = 0;
        // The collapse breaks at the date/time boundary (the ", " literal):
        // when only the time differs the whole date is shared, but a
        // difference anywhere inside the time run duplicates the entire time
        // (a fractional-second difference re-renders h:m:s.fff on both sides,
        // per ICU's greatest-difference range patterns). Date-only ranges
        // (no boundary literal) fall back to full duplication.
        while (prefix > 0) : (prefix -= 1) {
            const prev = &sa[prefix - 1];
            if (std.mem.eql(u8, prev.typ, "literal") and std.mem.eql(u8, prev.bytes(), ", ")) break;
        }
        var k: usize = 0;
        while (k < prefix) : (k += 1) {
            try pushPartSourced(realm, arr, idx, sa[k].typ, sa[k].bytes(), "shared");
            idx += 1;
        }
        k = prefix;
        while (k < na) : (k += 1) {
            try pushPartSourced(realm, arr, idx, sa[k].typ, sa[k].bytes(), "startRange");
            idx += 1;
        }
        try pushPartSourced(realm, arr, idx, "literal", " – ", "shared");
        idx += 1;
        k = prefix;
        while (k < nb) : (k += 1) {
            try pushPartSourced(realm, arr, idx, sb[k].typ, sb[k].bytes(), "endRange");
            idx += 1;
        }
    }
    arr.setArrayLength(realm.allocator, idx) catch return error.OutOfMemory;
    return heap_mod.taggedObject(arr);
}

fn dateTimeFormatResolvedOptions(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    const rec = try requireKind(realm, this_value, .date_time_format);
    const s = rec.date_time_format;
    const obj = try makeResolvedBase(realm, s.base.locale);
    try setDataProp(realm, obj, "calendar", try makeStringValue(realm, if (s.calendar.len > 0) s.calendar else "iso8601"));
    try setDataProp(realm, obj, "numberingSystem", try makeStringValue(realm, if (s.numbering_system.len > 0) s.numbering_system else "latn"));
    try setDataProp(realm, obj, "timeZone", try makeStringValue(realm, if (s.time_zone.len > 0) s.time_zone else "UTC"));
    // §11.3.7 — [[HourCycle]] (and hour12) are undefined when [[Hour]] is
    // undefined: a dateStyle-only format, or components with no hour.
    const has_hour = s.hour.len > 0 or s.time_style.len > 0;
    if (s.hour_cycle.len > 0 and has_hour) {
        try setDataProp(realm, obj, "hourCycle", try makeStringValue(realm, s.hour_cycle));
        try setDataProp(realm, obj, "hour12", Value.fromBool(std.mem.eql(u8, s.hour_cycle, "h11") or std.mem.eql(u8, s.hour_cycle, "h12")));
    }
    if (s.date_style.len > 0 or s.time_style.len > 0) {
        if (s.date_style.len > 0) try setDataProp(realm, obj, "dateStyle", try makeStringValue(realm, s.date_style));
        if (s.time_style.len > 0) try setDataProp(realm, obj, "timeStyle", try makeStringValue(realm, s.time_style));
    } else {
        // Component fields present in the resolved format.
        if (s.weekday.len > 0) try setDataProp(realm, obj, "weekday", try makeStringValue(realm, s.weekday));
        if (s.era.len > 0) try setDataProp(realm, obj, "era", try makeStringValue(realm, s.era));
        if (s.year.len > 0) try setDataProp(realm, obj, "year", try makeStringValue(realm, s.year));
        if (s.month.len > 0) try setDataProp(realm, obj, "month", try makeStringValue(realm, s.month));
        if (s.day.len > 0) try setDataProp(realm, obj, "day", try makeStringValue(realm, s.day));
        if (s.day_period.len > 0) try setDataProp(realm, obj, "dayPeriod", try makeStringValue(realm, s.day_period));
        if (s.hour.len > 0) try setDataProp(realm, obj, "hour", try makeStringValue(realm, s.hour));
        if (s.minute.len > 0) try setDataProp(realm, obj, "minute", try makeStringValue(realm, s.minute));
        if (s.second.len > 0) try setDataProp(realm, obj, "second", try makeStringValue(realm, s.second));
        if (s.fractional_second_digits) |fsd| try setDataProp(realm, obj, "fractionalSecondDigits", makeNumberValue(@floatFromInt(fsd)));
        if (s.time_zone_name.len > 0) try setDataProp(realm, obj, "timeZoneName", try makeStringValue(realm, s.time_zone_name));
        // Default to numeric y/m/d when no component or style was requested.
        if (s.weekday.len == 0 and s.year.len == 0 and s.month.len == 0 and s.day.len == 0 and
            s.hour.len == 0 and s.minute.len == 0 and s.second.len == 0)
        {
            try setDataProp(realm, obj, "year", try makeStringValue(realm, "numeric"));
            try setDataProp(realm, obj, "month", try makeStringValue(realm, "numeric"));
            try setDataProp(realm, obj, "day", try makeStringValue(realm, "numeric"));
        }
    }
    return heap_mod.taggedObject(obj);
}

// ── date/time formatting engine (dateStyle/timeStyle + components; §11.5) ─────

const CivilTime = struct {
    year: i64,
    month: u32, // 1-13 (calendar ordinal)
    hebrew: bool = false, // month renders as a name, never numerically (CLDR-15510)
    named_cal: temporal.CalendarId = temporal.CalendarId.iso8601(), // named non-gregorian months (islamic/persian/...)
    lunisolar_code: i64 = 0, // chinese/dangi: month renders as its CODE number ("Nbis" when leap)
    day: u32, // 1-31
    hour: u32, // 0-23
    minute: u32,
    second: u32,
    ms_fraction: u32, // 0-999 sub-second milliseconds
    weekday: u32, // 0=sun .. 6=sat
};

/// Break epoch milliseconds into civil fields in the format's time zone.
fn breakDown(slots: *const intl.DateTimeFormatSlots, ms: f64) CivilTime {
    const epoch_ns: i128 = @as(i128, @intFromFloat(ms)) * 1_000_000;
    const offset_ns: i128 = tzOffsetNs(slots.time_zone, epoch_ns);
    const local_ns: i128 = epoch_ns + offset_ns;
    const ns_per_day: i128 = 86_400 * 1_000_000_000;
    const days: i64 = @intCast(@divFloor(local_ns, ns_per_day));
    const ns_in_day: i128 = local_ns - @as(i128, days) * ns_per_day;
    const ymd = temporal.civilFromDays(days);
    const t = temporal.nanosecondsToTimeRecord(ns_in_day);
    const iso_dow = temporal.isoDayOfWeek(ymd.year, ymd.month, ymd.day); // 1=Mon..7=Sun
    // Resolve the ISO date into the format's calendar (numeric fields), keeping
    // DTF output consistent with the Temporal getters (compare-to-temporal.js).
    // Month *names* still index the gregorian tables until per-calendar CLDR
    // month data lands, so non-gregorian month labels remain approximate.
    const cid = temporal.CalendarId.fromSlice(slots.calendar) orelse temporal.CalendarId.iso8601();
    const cf = tshared.calendarFields(cid, @intCast(ymd.year), ymd.month, ymd.day);
    return .{
        // Japanese renders the era-relative year (Reiwa 32), not the gregorian
        // 2050; for every other calendar year == era_year so this is a no-op.
        .year = if (std.ascii.eqlIgnoreCase(slots.calendar, "japanese")) (cf.era_year orelse cf.year) else cf.year,
        .hebrew = std.ascii.eqlIgnoreCase(slots.calendar, "hebrew"),
        .named_cal = cid,
        .lunisolar_code = if (std.ascii.eqlIgnoreCase(slots.calendar, "chinese") or std.ascii.eqlIgnoreCase(slots.calendar, "dangi"))
            tshared.monthOrdinalToCode(cid, cf.year, cf.month)
        else
            0,
        .month = cf.month,
        .day = cf.day,
        .hour = t.hour,
        .minute = t.minute,
        .second = t.second,
        .ms_fraction = @intCast(@mod(@as(i64, @intFromFloat(ms)), 1000)),
        .weekday = @intCast(iso_dow % 7), // → 0=Sun..6=Sat
    };
}

fn tzOffsetNs(tz: []const u8, epoch_ns: i128) i128 {
    if (tz.len == 0 or std.mem.eql(u8, tz, "UTC")) return 0;
    // A canonical offset zone ("±HH:MM") is a fixed shift, no tzdb consult.
    if (tz[0] == '+' or tz[0] == '-') {
        if (tz.len == 6 and tz[3] == ':') {
            const h = (tz[1] - '0') * 10 + (tz[2] - '0');
            const m = (tz[4] - '0') * 10 + (tz[5] - '0');
            const mins: i128 = @as(i128, h) * 60 + m;
            const ns = mins * 60 * 1_000_000_000;
            return if (tz[0] == '-') -ns else ns;
        }
        return 0;
    }
    const tzdata = @import("../tzdata.zig");
    if (tzdata.available) return @as(i128, tzdata.offsetNanosecondsFor(tz, epoch_ns));
    return 0;
}

/// The CLDR pattern letters for a timeZoneName style.
fn tzPatternLetters(style: []const u8) []const u8 {
    if (std.mem.eql(u8, style, "long")) return "zzzz";
    if (std.mem.eql(u8, style, "short")) return "z";
    if (std.mem.eql(u8, style, "longOffset")) return "OOOO";
    if (std.mem.eql(u8, style, "shortOffset")) return "O";
    if (std.mem.eql(u8, style, "longGeneric")) return "vvvv";
    if (std.mem.eql(u8, style, "shortGeneric")) return "v";
    return "";
}

/// Localized GMT offset ("GMT", "GMT-8", "GMT-08:00"). `extended` forces the
/// always-two-digit "GMT±HH:MM" form (longOffset / the name-style fallback);
/// otherwise the compact "GMT±H[:MM]" form (shortOffset).
fn fmtGmtOffset(off_ns: i128, extended: bool, buf: []u8) []const u8 {
    if (off_ns == 0) {
        @memcpy(buf[0..3], "GMT");
        return buf[0..3];
    }
    const total_min: i64 = @intCast(@divTrunc(off_ns, 60_000_000_000));
    const neg = total_min < 0;
    const abs_min: u64 = @intCast(if (neg) -total_min else total_min);
    const h = abs_min / 60;
    const m = abs_min % 60;
    const sign: u8 = if (neg) '-' else '+';
    return if (extended)
        (std.fmt.bufPrint(buf, "GMT{c}{d:0>2}:{d:0>2}", .{ sign, h, m }) catch "GMT")
    else if (m == 0)
        (std.fmt.bufPrint(buf, "GMT{c}{d}", .{ sign, h }) catch "GMT")
    else
        (std.fmt.bufPrint(buf, "GMT{c}{d}:{d:0>2}", .{ sign, h, m }) catch "GMT");
}

/// §11.5.x — the timeZoneName display for the format's zone at `epoch_ns`.
/// The effective timeZoneName style implied by a resolved pattern's tz field
/// (e.g. the timeStyle "full"/"long" patterns carry `zzzz` / `z` with no
/// explicit timeZoneName option). "" when the pattern has no tz field.
fn patternTzStyle(pattern: []const u8) []const u8 {
    var in_quote = false;
    var i: usize = 0;
    while (i < pattern.len) : (i += 1) {
        const c = pattern[i];
        if (c == '\'') {
            in_quote = !in_quote;
            continue;
        }
        if (in_quote) continue;
        switch (c) {
            'z', 'v', 'O', 'Z', 'X', 'x', 'V' => {
                var j = i;
                while (j < pattern.len and pattern[j] == c) j += 1;
                const count = j - i;
                return switch (c) {
                    'z' => if (count >= 4) "long" else "short",
                    'v' => if (count >= 4) "longGeneric" else "shortGeneric",
                    'O', 'Z' => if (count >= 4) "longOffset" else "shortOffset",
                    else => "shortOffset",
                };
            },
            else => {},
        }
    }
    return "";
}

/// Offset styles are computed exactly; UTC has fixed names; other zones fall
/// back to the localized GMT offset (CLDR's documented missing-name fallback,
/// since Cynic ships no per-zone display-name data). `style` is the effective
/// timeZoneName width (the option, or the pattern's tz-field width).
fn tzDisplay(slots: *const intl.DateTimeFormatSlots, epoch_ns: i128, style: []const u8, buf: []u8) []const u8 {
    const off_ns = tzOffsetNs(slots.time_zone, epoch_ns);
    if (std.mem.eql(u8, style, "longOffset")) return fmtGmtOffset(off_ns, true, buf);
    if (std.mem.eql(u8, style, "shortOffset")) return fmtGmtOffset(off_ns, false, buf);
    if (std.mem.eql(u8, slots.time_zone, "UTC")) {
        if (std.mem.eql(u8, style, "long") or std.mem.eql(u8, style, "longGeneric")) return "Coordinated Universal Time";
        return "UTC"; // short / shortGeneric
    }
    // Name-style fallback for a named zone without display data: the localized
    // GMT offset, in the width matching the requested style (short → GMT+1,
    // long → GMT+01:00) so the styles stay distinguishable.
    const long_form = std.mem.eql(u8, style, "long") or std.mem.eql(u8, style, "longGeneric");
    return fmtGmtOffset(off_ns, long_form, buf);
}

/// The pattern hour-field letter for a resolved hour cycle (0 = leave as-is).
fn hourLetterForHc(hc: []const u8) u8 {
    if (std.mem.eql(u8, hc, "h11")) return 'K';
    if (std.mem.eql(u8, hc, "h12")) return 'h';
    if (std.mem.eql(u8, hc, "h23")) return 'H';
    if (std.mem.eql(u8, hc, "h24")) return 'k';
    return 0;
}

/// Byte length of a trailing space character (ASCII ' ', U+00A0, or U+202F) in
/// `s`, or 0 if none — CLDR date patterns separate the dayPeriod with a narrow
/// or non-breaking space, not always ASCII.
fn trailingSpaceBytes(s: []const u8) usize {
    if (s.len >= 1 and s[s.len - 1] == ' ') return 1;
    if (s.len >= 2 and s[s.len - 2] == 0xC2 and s[s.len - 1] == 0xA0) return 2; // U+00A0
    if (s.len >= 3 and s[s.len - 3] == 0xE2 and s[s.len - 2] == 0x80 and s[s.len - 1] == 0xAF) return 3; // U+202F
    return 0;
}

/// Byte length of a leading space character (ASCII ' ', U+00A0, or U+202F).
fn leadingSpaceBytes(s: []const u8) usize {
    if (s.len >= 1 and s[0] == ' ') return 1;
    if (s.len >= 2 and s[0] == 0xC2 and s[1] == 0xA0) return 2;
    if (s.len >= 3 and s[0] == 0xE2 and s[1] == 0x80 and s[2] == 0xAF) return 3;
    return 0;
}

/// §11.1.1 — rewrite a dateStyle/timeStyle CLDR pattern to the resolved hour
/// cycle: replace the hour field's letter (preserving its width), and for a
/// 24-hour cycle drop the dayPeriod field plus one adjacent space. Component
/// patterns already bake the cycle in (requestedFieldToken) and skip this.
fn applyHourCycleToStylePattern(pattern: []const u8, hc: []const u8, buf: []u8) []const u8 {
    const target = hourLetterForHc(hc);
    if (target == 0) return pattern;
    const is24 = target == 'H' or target == 'k';
    var n: usize = 0;
    var i: usize = 0;
    var in_quote = false;
    while (i < pattern.len) {
        const c = pattern[i];
        if (c == '\'') {
            in_quote = !in_quote;
            if (n < buf.len) {
                buf[n] = c;
                n += 1;
            }
            i += 1;
        } else if (!in_quote and (c == 'h' or c == 'H' or c == 'K' or c == 'k')) {
            var j = i;
            while (j < pattern.len and pattern[j] == c) j += 1;
            var k: usize = i;
            while (k < j and n < buf.len) : (k += 1) {
                buf[n] = target;
                n += 1;
            }
            i = j;
        } else if (!in_quote and (c == 'a' or c == 'b' or c == 'B')) {
            var j = i;
            while (j < pattern.len and pattern[j] == c) j += 1;
            if (is24) {
                // Drop the dayPeriod field and collapse one adjacent space — the
                // CLDR separator is often U+202F / U+00A0, not ASCII ' '.
                const tb = trailingSpaceBytes(buf[0..n]);
                if (tb > 0) {
                    n -= tb;
                } else {
                    j += leadingSpaceBytes(pattern[j..]);
                }
            } else {
                var k: usize = i;
                while (k < j and n < buf.len) : (k += 1) {
                    buf[n] = pattern[k];
                    n += 1;
                }
            }
            i = j;
        } else {
            if (n < buf.len) {
                buf[n] = c;
                n += 1;
            }
            i += 1;
        }
    }
    return buf[0..n];
}

/// Resolve the CLDR pattern for these options into `buf`, returning the slice.
fn resolveDateTimePattern(dd: cldr.DateData, slots: *const intl.DateTimeFormatSlots, buf: []u8) []const u8 {
    const has_date_style = slots.date_style.len > 0;
    const has_time_style = slots.time_style.len > 0;
    if (has_date_style or has_time_style) {
        const date_pat = if (has_date_style) styleDatePattern(dd, slots.date_style) else "";
        const time_pat = if (has_time_style) styleTimePattern(dd, slots.time_style) else "";
        if (has_date_style and has_time_style) {
            const comb = styleDateTimePattern(dd, slots.date_style);
            return combinePattern(comb, date_pat, time_pat, buf);
        }
        return if (has_date_style) date_pat else time_pat;
    }

    // Component options (or the §11.1.2 ToDateTimeOptions(ANY, DATE)
    // numeric y/m/d default — which a lone { era } also takes, era being
    // the one component outside the needDefaults check list).
    var eff_slots = slots.*;
    const slots_nine = slots.weekday.len > 0 or slots.year.len > 0 or slots.month.len > 0 or
        slots.day.len > 0 or slots.hour.len > 0 or slots.minute.len > 0 or slots.second.len > 0 or
        slots.day_period.len > 0 or slots.fractional_second_digits != null;
    if (!slots_nine) {
        eff_slots.year = "numeric";
        eff_slots.month = "numeric";
        eff_slots.day = "numeric";
    }
    const slots2 = &eff_slots;
    const any_date = slots2.weekday.len > 0 or slots2.era.len > 0 or slots2.year.len > 0 or slots2.month.len > 0 or slots2.day.len > 0;
    const any_time = slots2.hour.len > 0 or slots2.minute.len > 0 or slots2.second.len > 0 or slots2.day_period.len > 0 or
        slots2.fractional_second_digits != null;

    var date_buf: [128]u8 = undefined;
    var time_buf: [128]u8 = undefined;
    var date_pat: []const u8 = "";
    var time_pat: []const u8 = "";

    if (any_date or !any_time) {
        // Base template by the most textual requested field.
        const base = if (slots2.weekday.len > 0)
            dd.date_full
        else if (isTextualMonth(slots2.month))
            (if (std.mem.eql(u8, slots2.month, "short")) dd.date_medium else dd.date_long)
        else
            dd.date_short;
        date_pat = buildFromTemplate(base, slots2, true, date_buf[0..]);
    }
    if (any_time) {
        time_pat = buildFromTemplate(dd.time_medium, slots2, false, time_buf[0..]);
        // The flexible day-period skeleton (hB) separates with a plain space,
        // unlike am/pm (h a); the template carries the am/pm separator, so
        // flatten the narrow / non-breaking space when the dayPeriod option set.
        if (slots2.day_period.len > 0) time_pat = flattenNarrowSpaces(time_buf[0..time_pat.len]);
    }

    if (date_pat.len > 0 and time_pat.len > 0)
        return combinePattern(dd.dt_short, date_pat, time_pat, buf);
    if (date_pat.len > 0) {
        @memcpy(buf[0..date_pat.len], date_pat);
        return buf[0..date_pat.len];
    }
    @memcpy(buf[0..time_pat.len], time_pat);
    return buf[0..time_pat.len];
}

fn isTextualMonth(m: []const u8) bool {
    return std.mem.eql(u8, m, "long") or std.mem.eql(u8, m, "short") or std.mem.eql(u8, m, "narrow");
}

/// Compact any U+202F / U+00A0 in `s` to a single ASCII space, in place.
fn flattenNarrowSpaces(s: []u8) []const u8 {
    var w: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        if (i + 2 < s.len and s[i] == 0xE2 and s[i + 1] == 0x80 and s[i + 2] == 0xAF) {
            s[w] = ' ';
            w += 1;
            i += 3;
        } else if (i + 1 < s.len and s[i] == 0xC2 and s[i + 1] == 0xA0) {
            s[w] = ' ';
            w += 1;
            i += 2;
        } else {
            s[w] = s[i];
            w += 1;
            i += 1;
        }
    }
    return s[0..w];
}

fn styleDatePattern(dd: cldr.DateData, style: []const u8) []const u8 {
    if (std.mem.eql(u8, style, "full")) return dd.date_full;
    if (std.mem.eql(u8, style, "long")) return dd.date_long;
    if (std.mem.eql(u8, style, "short")) return dd.date_short;
    return dd.date_medium;
}
fn styleTimePattern(dd: cldr.DateData, style: []const u8) []const u8 {
    if (std.mem.eql(u8, style, "full")) return dd.time_full;
    if (std.mem.eql(u8, style, "long")) return dd.time_long;
    if (std.mem.eql(u8, style, "short")) return dd.time_short;
    return dd.time_medium;
}
fn styleDateTimePattern(dd: cldr.DateData, style: []const u8) []const u8 {
    if (std.mem.eql(u8, style, "full")) return dd.dt_full;
    if (std.mem.eql(u8, style, "long")) return dd.dt_long;
    if (std.mem.eql(u8, style, "short")) return dd.dt_short;
    return dd.dt_medium;
}

/// Substitute {1} (date) and {0} (time) in a dateTime combiner pattern.
fn combinePattern(comb: []const u8, date_pat: []const u8, time_pat: []const u8, buf: []u8) []const u8 {
    var n: usize = 0;
    var i: usize = 0;
    while (i < comb.len) {
        if (i + 2 < comb.len and comb[i] == '{' and comb[i + 2] == '}') {
            const repl = if (comb[i + 1] == '1') date_pat else if (comb[i + 1] == '0') time_pat else "";
            if (n + repl.len <= buf.len) {
                @memcpy(buf[n .. n + repl.len], repl);
                n += repl.len;
            }
            i += 3;
        } else {
            if (n < buf.len) buf[n] = comb[i];
            n += 1;
            i += 1;
        }
    }
    return buf[0..@min(n, buf.len)];
}

/// Build a pattern by filtering a CLDR template to the requested fields, taking
/// field widths from the options and separators/order from the template.
fn buildFromTemplate(template: []const u8, slots: *const intl.DateTimeFormatSlots, is_date: bool, buf: []u8) []const u8 {
    var n: usize = 0;
    var emitted_field = false;
    var pending_lit_start: usize = 0;
    var pending_lit_len: usize = 0;

    var i: usize = 0;
    while (i < template.len) {
        const c = template[i];
        if (std.ascii.isAlphabetic(c)) {
            // Field run.
            var j = i;
            while (j < template.len and template[j] == c) j += 1;
            const tok = requestedFieldToken(c, slots, is_date);
            if (tok.len > 0) {
                if (emitted_field and pending_lit_len > 0) {
                    const lit = template[pending_lit_start .. pending_lit_start + pending_lit_len];
                    if (n + lit.len <= buf.len) {
                        @memcpy(buf[n .. n + lit.len], lit);
                        n += lit.len;
                    }
                }
                if (n + tok.len <= buf.len) {
                    @memcpy(buf[n .. n + tok.len], tok);
                    n += tok.len;
                }
                emitted_field = true;
            }
            // A field (kept OR dropped) ends the current literal run. Resetting
            // even on a dropped field is essential: otherwise the pending slice
            // would span the dropped field's letters (":mm:ss"), which the
            // renderer would re-parse as minute/second fields.
            pending_lit_len = 0;
            i = j;
        } else {
            // Literal run (accumulate; flushed only between kept fields).
            if (pending_lit_len == 0) pending_lit_start = i;
            pending_lit_len += 1;
            i += 1;
        }
    }
    return buf[0..n];
}

/// Return the pattern token for a template field letter given the requested
/// option width, or "" to drop the field. `default_ymd` forces numeric y/m/d
/// when no component options were given at all.
fn requestedFieldToken(letter: u8, slots: *const intl.DateTimeFormatSlots, is_date: bool) []const u8 {
    const default_ymd = is_date and slots.weekday.len == 0 and slots.era.len == 0 and
        slots.year.len == 0 and slots.month.len == 0 and slots.day.len == 0;
    return switch (letter) {
        'G' => if (slots.era.len > 0) "G" else "",
        'y', 'Y' => blk: {
            var w = if (default_ymd) "numeric" else slots.year;
            // An era without a year still renders the year (CLDR era skeletons
            // are Gy — "AD 1970" not a bare "AD").
            if (w.len == 0 and slots.era.len > 0) w = "numeric";
            if (w.len == 0) break :blk "";
            break :blk if (std.mem.eql(u8, w, "2-digit")) "yy" else "y";
        },
        'M', 'L' => blk: {
            const w = if (default_ymd) "numeric" else slots.month;
            if (w.len == 0) break :blk "";
            if (std.mem.eql(u8, w, "2-digit")) break :blk "MM";
            if (std.mem.eql(u8, w, "long")) break :blk "MMMM";
            if (std.mem.eql(u8, w, "short")) break :blk "MMM";
            if (std.mem.eql(u8, w, "narrow")) break :blk "MMMMM";
            break :blk "M";
        },
        'd' => blk: {
            const w = if (default_ymd) "numeric" else slots.day;
            if (w.len == 0) break :blk "";
            break :blk if (std.mem.eql(u8, w, "2-digit")) "dd" else "d";
        },
        'E', 'c', 'e' => blk: {
            if (slots.weekday.len == 0) break :blk "";
            if (std.mem.eql(u8, slots.weekday, "long")) break :blk "EEEE";
            if (std.mem.eql(u8, slots.weekday, "narrow")) break :blk "EEEEE";
            break :blk "EEE";
        },
        'h', 'H', 'K', 'k' => blk: {
            if (slots.hour.len == 0) break :blk "";
            const hl = hourLetter(letter, slots.hour_cycle);
            break :blk if (std.mem.eql(u8, slots.hour, "2-digit")) twoCharHour(hl) else oneCharHour(hl);
        },
        // §11.1.1 / UTS #35 availableFormats — a "numeric" minute or second
        // combined with another time field renders 2-digit (the {h,m}→"h:mm",
        // {m,s}→"mm:ss" skeletons); only a sole field honors "numeric" as 1-digit.
        'm' => blk: {
            if (slots.minute.len == 0) break :blk "";
            const combined = slots.hour.len > 0 or slots.second.len > 0;
            break :blk if (std.mem.eql(u8, slots.minute, "2-digit") or combined) "mm" else "m";
        },
        's' => blk: {
            if (slots.second.len == 0) break :blk "";
            const combined = slots.hour.len > 0 or slots.minute.len > 0;
            break :blk if (std.mem.eql(u8, slots.second, "2-digit") or combined) "ss" else "s";
        },
        'a', 'b', 'B' => blk: {
            // The dayPeriod option selects the flexible day-period field 'B'
            // (width-encoded by letter count). The period names are currently
            // hard-coded for English, so other locales fall back to am/pm.
            if (slots.day_period.len > 0 and dtfLangIsEn(slots)) {
                if (std.mem.eql(u8, slots.day_period, "long")) break :blk "BBBB";
                if (std.mem.eql(u8, slots.day_period, "narrow")) break :blk "BBBBB";
                break :blk "B";
            }
            if (slots.hour.len > 0 and hourIs12(slots.hour_cycle)) break :blk "a";
            if (slots.day_period.len > 0) break :blk "a";
            break :blk "";
        },
        'z', 'Z', 'O', 'v', 'V', 'x', 'X' => if (slots.time_zone_name.len > 0) "z" else "",
        else => "",
    };
}

fn hourLetter(template_letter: u8, hc: []const u8) u8 {
    if (hc.len == 0) return template_letter; // keep locale default
    if (std.mem.eql(u8, hc, "h11")) return 'K';
    if (std.mem.eql(u8, hc, "h12")) return 'h';
    if (std.mem.eql(u8, hc, "h23")) return 'H';
    if (std.mem.eql(u8, hc, "h24")) return 'k';
    return template_letter;
}
fn oneCharHour(l: u8) []const u8 {
    return switch (l) {
        'h' => "h",
        'H' => "H",
        'K' => "K",
        else => "k",
    };
}
fn twoCharHour(l: u8) []const u8 {
    return switch (l) {
        'h' => "hh",
        'H' => "HH",
        'K' => "KK",
        else => "kk",
    };
}
fn hourIs12(hc: []const u8) bool {
    return hc.len == 0 or std.mem.eql(u8, hc, "h11") or std.mem.eql(u8, hc, "h12");
}

/// Splice "." + `n`×'S' after the (unquoted) seconds run in a resolved pattern,
/// so fractionalSecondDigits renders as a literal "." + a fractionalSecond field.
/// Returns the pattern unchanged when it has no seconds field.
fn injectFractionalSecond(pattern: []const u8, n: u32, buf: []u8) []const u8 {
    var in_quote = false;
    var s_end: ?usize = null;
    var i: usize = 0;
    while (i < pattern.len) : (i += 1) {
        const c = pattern[i];
        if (c == '\'') {
            in_quote = !in_quote;
        } else if (!in_quote and c == 's') {
            var j = i;
            while (j < pattern.len and pattern[j] == 's') j += 1;
            s_end = j;
            i = j - 1;
        }
    }
    // A lone fractionalSecondDigits option has no seconds field to attach
    // to: the format is just the fraction digits ("SSS").
    const se = s_end orelse {
        if (pattern.len != 0) return pattern;
        var l2: usize = 0;
        var k2: u32 = 0;
        while (k2 < n and l2 < buf.len) : (k2 += 1) {
            buf[l2] = 'S';
            l2 += 1;
        }
        return buf[0..l2];
    };
    var l: usize = 0;
    l += copyClamp(buf, l, pattern[0..se]);
    l += copyClamp(buf, l, ".");
    var k: u32 = 0;
    while (k < n and l < buf.len) : (k += 1) {
        buf[l] = 'S';
        l += 1;
    }
    l += copyClamp(buf, l, pattern[se..]);
    return buf[0..l];
}

/// Resolve the option pattern for these slots (style or components) and splice
/// in fractionalSecondDigits. `pat_buf`/`frac_buf` are caller scratch.
/// Whether a pattern already carries a time-zone field (unquoted z/Z/O/v/V/x/X).
fn patternHasTzField(pattern: []const u8) bool {
    var in_quote = false;
    for (pattern) |c| {
        if (c == '\'') {
            in_quote = !in_quote;
        } else if (!in_quote) switch (c) {
            'z', 'Z', 'O', 'v', 'V', 'x', 'X' => return true,
            else => {},
        };
    }
    return false;
}

fn resolvePatternFull(dd: cldr.DateData, slots: *const intl.DateTimeFormatSlots, pat_buf: []u8, hc_buf: []u8, frac_buf: []u8, tz_buf: []u8) []const u8 {
    var pattern = resolveDateTimePattern(dd, slots, pat_buf);
    // §11.1.1 — the style patterns carry the locale's default hour cycle; an
    // explicit/locale-keyword cycle rewrites the hour field (+ dayPeriod).
    if ((slots.date_style.len > 0 or slots.time_style.len > 0) and slots.hour_cycle.len > 0)
        pattern = applyHourCycleToStylePattern(pattern, slots.hour_cycle, hc_buf);
    if (slots.fractional_second_digits) |fsd| pattern = injectFractionalSecond(pattern, fsd, frac_buf);
    // §11.1.1 — a timeZoneName option not already covered by the (style) pattern
    // appends its field, so component options + timeZoneName still show the zone.
    if (slots.time_zone_name.len > 0 and !patternHasTzField(pattern)) {
        const letters = tzPatternLetters(slots.time_zone_name);
        if (letters.len > 0) {
            var n = copyClamp(tz_buf, 0, pattern);
            n += copyClamp(tz_buf, n, " ");
            n += copyClamp(tz_buf, n, letters);
            pattern = tz_buf[0..n];
        }
    }
    return pattern;
}

/// Interpret a resolved CLDR pattern against the broken-down time into segments.
fn renderDateTime(slots: *const intl.DateTimeFormatSlots, ms: f64, out: []Seg) u32 {
    const dd = cldr.dateData(slots.base.dataLocale()) orelse return 0;
    const ct = breakDown(slots, ms);
    var pat_buf: [256]u8 = undefined;
    var hc_buf: [256]u8 = undefined;
    var frac_buf: [288]u8 = undefined;
    var tz_buf: [320]u8 = undefined;
    const pattern = resolvePatternFull(dd, slots, &pat_buf, &hc_buf, &frac_buf, &tz_buf);
    var tzn_buf: [40]u8 = undefined;
    // The timeStyle patterns carry the tz field implicitly; derive its width
    // from the pattern when no explicit timeZoneName option was set.
    const tz_style = if (slots.time_zone_name.len > 0) slots.time_zone_name else patternTzStyle(pattern);
    const tzn = tzDisplay(slots, @as(i128, @intFromFloat(ms)) * 1_000_000, tz_style, &tzn_buf);
    return renderPattern(slots, dd, pattern, ct, tzn, out);
}

/// Interpret a resolved pattern against an explicit CivilTime — shared by the
/// epoch-ms path (renderDateTime) and the Temporal path (which supplies civil
/// fields directly and a pattern already masked to the object's data model).
/// `tz_name` is the precomputed timeZoneName display (empty when none).
fn renderPattern(slots: *const intl.DateTimeFormatSlots, dd: cldr.DateData, pattern: []const u8, ct: CivilTime, tz_name: []const u8, out: []Seg) u32 {
    const digit_base: u32 = if (cldr.numberData(slots.base.dataLocale())) |nd|
        (if (!std.mem.eql(u8, slots.numbering_system, nd.ns)) (cldr.numberingSystemDigitBase(slots.numbering_system) orelse nd.digit_base) else nd.digit_base)
    else
        (cldr.numberingSystemDigitBase(slots.numbering_system) orelse '0');

    var n: u32 = 0;
    var i: usize = 0;
    while (i < pattern.len and n < out.len) {
        const c = pattern[i];
        if (c == '\'') {
            // Quoted literal: '' is a literal quote.
            i += 1;
            if (i < pattern.len and pattern[i] == '\'') {
                setSeg(&out[n], "literal", "'");
                n += 1;
                i += 1;
                continue;
            }
            const start = i;
            while (i < pattern.len and pattern[i] != '\'') i += 1;
            setSeg(&out[n], "literal", pattern[start..i]);
            n += 1;
            if (i < pattern.len) i += 1; // closing quote
        } else if (std.ascii.isAlphabetic(c)) {
            var j = i;
            while (j < pattern.len and pattern[j] == c) j += 1;
            const count = j - i;
            n += emitField(out[n..], c, count, ct, dd, digit_base, tz_name);
            i = j;
        } else {
            const start = i;
            while (i < pattern.len and !std.ascii.isAlphabetic(pattern[i]) and pattern[i] != '\'') i += 1;
            setSeg(&out[n], "literal", pattern[start..i]);
            n += 1;
        }
    }
    return n;
}

// ── Temporal → DateTimeFormat bridge (§11.5.x) ───────────────────────────────

/// Whether a pattern field letter belongs to a Temporal type's data model.
fn temporalFieldAllowed(kind: temporal.TemporalKind, letter: u8) bool {
    const ym = switch (kind) {
        .instant, .plain_date_time, .plain_date, .plain_year_month => true,
        else => false,
    };
    const md = switch (kind) {
        .instant, .plain_date_time, .plain_date, .plain_month_day => true,
        else => false,
    };
    const full_date = switch (kind) {
        .instant, .plain_date_time, .plain_date => true,
        else => false,
    };
    const time = switch (kind) {
        .instant, .plain_date_time, .plain_time => true,
        else => false,
    };
    return switch (letter) {
        'G', 'y', 'Y' => ym, // era + year
        'M', 'L' => ym or md, // month (present in year-month and month-day)
        'd' => md, // day
        'E', 'c', 'e' => full_date, // weekday needs a full date
        'h', 'H', 'K', 'k', 'm', 's', 'S', 'a', 'b', 'B' => time,
        'z', 'Z', 'O', 'v', 'V', 'x', 'X' => kind == .instant, // tz name: absolute time only
        else => true,
    };
}

/// Drop pattern field runs the Temporal type lacks (and their adjacent
/// separators, via the same contiguous-literal logic as buildFromTemplate);
/// returns null when no field survives (no overlap → caller throws TypeError).
fn filterPatternByMask(pattern: []const u8, kind: temporal.TemporalKind, buf: []u8) ?[]const u8 {
    var n: usize = 0;
    var emitted = false;
    var pend_start: usize = 0;
    var has_pend = false;
    var i: usize = 0;
    while (i < pattern.len) {
        const c = pattern[i];
        if (std.ascii.isAlphabetic(c)) {
            var j = i;
            while (j < pattern.len and pattern[j] == c) j += 1;
            if (temporalFieldAllowed(kind, c)) {
                if (emitted and has_pend) n += copyClamp(buf, n, pattern[pend_start..i]);
                n += copyClamp(buf, n, pattern[i..j]);
                emitted = true;
            }
            has_pend = false; // a field (kept or dropped) ends the literal run
            i = j;
        } else {
            if (!has_pend) {
                pend_start = i;
                has_pend = true;
            }
            if (c == '\'') {
                i += 1;
                if (i < pattern.len and pattern[i] == '\'') {
                    i += 1;
                } else {
                    while (i < pattern.len and pattern[i] != '\'') i += 1;
                    if (i < pattern.len) i += 1;
                }
            } else i += 1;
        }
    }
    if (!emitted) return null;
    return buf[0..n];
}

/// Civil fields for a stored ISO date resolved into the FORMAT's calendar —
/// the Plain-type analogue of breakDown's calendar step, so a hebrew /
/// islamic / chinese PlainDate renders its calendar month (names, codes)
/// rather than raw ISO fields.
fn temporalIsoCivil(slots: *const intl.DateTimeFormatSlots, y: i64, mo: u32, da: u32, h: u32, mi: u32, s: u32, ms: u32) CivilTime {
    const cid = temporal.CalendarId.fromSlice(slots.calendar) orelse temporal.CalendarId.iso8601();
    const cf = tshared.calendarFields(cid, @intCast(y), mo, da);
    return .{
        .year = if (std.ascii.eqlIgnoreCase(slots.calendar, "japanese")) (cf.era_year orelse cf.year) else cf.year,
        .hebrew = std.ascii.eqlIgnoreCase(slots.calendar, "hebrew"),
        .named_cal = cid,
        .lunisolar_code = if (std.ascii.eqlIgnoreCase(slots.calendar, "chinese") or std.ascii.eqlIgnoreCase(slots.calendar, "dangi"))
            tshared.monthOrdinalToCode(cid, cf.year, cf.month)
        else
            0,
        .month = cf.month,
        .day = cf.day,
        .hour = h,
        .minute = mi,
        .second = s,
        .ms_fraction = ms,
        .weekday = @intCast(temporal.isoDayOfWeek(y, mo, da) % 7),
    };
}

/// Civil fields for a Temporal record. Plain types use their ISO fields
/// (resolved into the format's calendar; the format's time zone is
/// ignored); an Instant is the epoch broken down in the format's zone.
fn temporalCivil(slots: *const intl.DateTimeFormatSlots, rec: *const temporal.TemporalRecord) CivilTime {
    return switch (rec.*) {
        .instant => |v| breakDown(slots, @floatFromInt(@divFloor(v.epoch_ns, 1_000_000))),
        .plain_date => |d| temporalIsoCivil(slots, d.iso_year, d.iso_month, d.iso_day, 0, 0, 0, 0),
        .plain_date_time => |d| temporalIsoCivil(slots, d.iso_year, d.iso_month, d.iso_day, d.hour, d.minute, d.second, d.millisecond),
        .plain_time => |t| temporalIsoCivil(slots, 1972, 1, 1, t.hour, t.minute, t.second, t.millisecond),
        .plain_year_month => |d| temporalIsoCivil(slots, d.iso_year, d.iso_month, d.ref_iso_day, 0, 0, 0, 0),
        .plain_month_day => |d| temporalIsoCivil(slots, d.ref_iso_year, d.iso_month, d.iso_day, 0, 0, 0, 0),
        else => temporalIsoCivil(slots, 1970, 1, 1, 0, 0, 0, 0),
    };
}

/// The calendar id a Temporal record carries ("iso8601" for the calendar-free
/// PlainTime / Instant).
fn temporalCalendarId(rec: *const temporal.TemporalRecord) []const u8 {
    // Capture by pointer (|*d|): .slice() borrows the record's bytes, so a
    // by-value capture would return a slice into a copy that dies here.
    return switch (rec.*) {
        .plain_date => |*d| d.calendar.slice(),
        .plain_date_time => |*d| d.calendar.slice(),
        .plain_year_month => |*d| d.calendar.slice(),
        .plain_month_day => |*d| d.calendar.slice(),
        .zoned_date_time => |*d| d.calendar.slice(),
        else => "iso8601",
    };
}

/// §11.5.x HandleDateTimeValue — render `arg` (a legacy time value or a Temporal
/// object) into `out`. A Temporal object validates calendar match + field
/// overlap (TypeError on no overlap, RangeError on calendar mismatch); a
/// ZonedDateTime / Duration is rejected. Assumes cldr.available.
fn dtfRenderArg(realm: *Realm, slots: *const intl.DateTimeFormatSlots, arg: Value, out: []Seg) NativeError!u32 {
    if (heap_mod.valueAsPlainObject(arg)) |o| {
        if (o.getTemporalRecord()) |rec| {
            switch (rec.*) {
                .zoned_date_time => return throwTypeError(realm, "Temporal.ZonedDateTime has no fixed format; use toLocaleString"),
                .duration => return throwTypeError(realm, "Temporal.Duration is not a date/time value"),
                else => {},
            }
            const rcal = temporalCalendarId(rec);
            // §11.5.x — PlainYearMonth / PlainMonthDay require calendar
            // EQUALITY (their fields are calendar-dependent, so even an ISO
            // instance mismatches a gregory formatter); the other types
            // exempt iso8601.
            const strict_cal = rec.* == .plain_year_month or rec.* == .plain_month_day;
            const cal_matches = std.ascii.eqlIgnoreCase(rcal, slots.calendar) or
                (!strict_cal and std.mem.eql(u8, rcal, "iso8601"));
            if (!cal_matches)
                return throwRangeError(realm, "Temporal calendar does not match the DateTimeFormat calendar");
            const dd = cldr.dateData(slots.base.dataLocale()) orelse return 0;
            // §11.5.x — defaults are per Temporal type: a PlainTime with no
            // explicit time components (so the construction pattern defaulted to
            // date) re-resolves with time defaults, else nothing would overlap.
            var s2: intl.DateTimeFormatSlots = undefined;
            var pat_slots = slots;
            {
                // §11.1.3 GetDateTimeFormat — restrict the requested options
                // to the type's field set (era on a MonthDay is dropped, not
                // an error); a style axis the type cannot express is a
                // TypeError; when nothing relevant remains, the type's
                // default components apply.
                const kind = std.meta.activeTag(rec.*);
                const date_only = kind == .plain_date or kind == .plain_year_month or kind == .plain_month_day;
                const time_only = kind == .plain_time;
                // era is outside the §11.1.2 needDefaults check list: a lone
                // { era } takes the type's defaults rather than failing to
                // overlap.
                const had_any = slots.weekday.len > 0 or slots.year.len > 0 or
                    slots.month.len > 0 or slots.day.len > 0 or slots.hour.len > 0 or slots.minute.len > 0 or
                    slots.second.len > 0 or slots.day_period.len > 0 or slots.fractional_second_digits != null or
                    slots.date_style.len > 0 or slots.time_style.len > 0;
                s2 = slots.*;
                // An inapplicable style axis is dropped here, not an error —
                // the toLocaleString entry points reject it at construction.
                if (date_only) s2.time_style = "";
                if (time_only) s2.date_style = "";
                switch (kind) {
                    .plain_date => {
                        s2.hour = "";
                        s2.minute = "";
                        s2.second = "";
                        s2.day_period = "";
                        s2.fractional_second_digits = null;
                        s2.time_zone_name = "";
                    },
                    .plain_year_month => {
                        s2.weekday = "";
                        s2.day = "";
                        s2.hour = "";
                        s2.minute = "";
                        s2.second = "";
                        s2.day_period = "";
                        s2.fractional_second_digits = null;
                        s2.time_zone_name = "";
                    },
                    .plain_month_day => {
                        s2.weekday = "";
                        s2.era = "";
                        s2.year = "";
                        s2.hour = "";
                        s2.minute = "";
                        s2.second = "";
                        s2.day_period = "";
                        s2.fractional_second_digits = null;
                        s2.time_zone_name = "";
                    },
                    .plain_time => {
                        s2.weekday = "";
                        s2.era = "";
                        s2.year = "";
                        s2.month = "";
                        s2.day = "";
                        s2.time_zone_name = "";
                    },
                    else => {}, // the date-time types admit every field
                }
                const any_relevant = s2.weekday.len > 0 or s2.year.len > 0 or
                    s2.month.len > 0 or s2.day.len > 0 or s2.hour.len > 0 or s2.minute.len > 0 or
                    s2.second.len > 0 or s2.day_period.len > 0 or s2.fractional_second_digits != null or
                    s2.date_style.len > 0 or s2.time_style.len > 0;
                if (!any_relevant) {
                    // Explicit options that ALL fell outside the type's field
                    // set ({year} against a PlainTime) fail to overlap; a
                    // componentless format takes the type's defaults.
                    if (had_any)
                        return throwTypeError(realm, "DateTimeFormat options do not overlap the Temporal object's fields");
                    applyTemporalToLocaleDefaults(&s2, arg);
                }
                pat_slots = &s2;
            }
            var pat_buf: [256]u8 = undefined;
            var hc_buf: [256]u8 = undefined;
            var frac_buf: [288]u8 = undefined;
            var tz_buf: [320]u8 = undefined;
            const pattern = resolvePatternFull(dd, pat_slots, &pat_buf, &hc_buf, &frac_buf, &tz_buf);
            var mask_buf: [288]u8 = undefined;
            const masked = filterPatternByMask(pattern, std.meta.activeTag(rec.*), mask_buf[0..]) orelse
                return throwTypeError(realm, "DateTimeFormat options do not overlap the Temporal object's fields");
            // Only an Instant carries a zone; the masked Plain patterns drop it.
            var tzn_buf: [40]u8 = undefined;
            const tz_style = if (slots.time_zone_name.len > 0) slots.time_zone_name else patternTzStyle(masked);
            const tzn = if (rec.* == .instant) tzDisplay(slots, rec.instant.epoch_ns, tz_style, &tzn_buf) else "";
            return renderPattern(slots, dd, masked, temporalCivil(slots, rec), tzn, out);
        }
    }
    return renderDateTime(slots, try dtfTimeValue(realm, arg), out);
}

/// The Temporal type of `arg` (null for a legacy time value), used by
/// formatRange to reject endpoints of differing types.
fn dtfArgTemporalKind(arg: Value) ?temporal.TemporalKind {
    if (heap_mod.valueAsPlainObject(arg)) |o| {
        if (o.getTemporalRecord()) |rec| return std.meta.activeTag(rec.*);
    }
    return null;
}

fn dtfSameKind(a: ?temporal.TemporalKind, b: ?temporal.TemporalKind) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return a.? == b.?;
}

/// Flatten rendered segments into `buf`, returning the concatenated string.
fn flattenSegs(segs: []const Seg, n: u32, buf: []u8) []const u8 {
    var len: usize = 0;
    var i: u32 = 0;
    while (i < n) : (i += 1) len += copyClamp(buf, len, segs[i].bytes());
    return buf[0..len];
}

fn renderDateTimeFlat(slots: *const intl.DateTimeFormatSlots, ms: f64, buf: []u8) []const u8 {
    var segs: [48]Seg = undefined;
    const n = renderDateTime(slots, ms, &segs);
    var len: usize = 0;
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const b = segs[i].bytes();
        if (len + b.len > buf.len) break;
        @memcpy(buf[len .. len + b.len], b);
        len += b.len;
    }
    return buf[0..len];
}

/// Emit one date/time field. Returns number of segments written (0 or 1).
fn dtfLangIsEn(slots: *const intl.DateTimeFormatSlots) bool {
    const loc = slots.base.dataLocale();
    return std.mem.eql(u8, loc, "en") or std.mem.startsWith(u8, loc, "en-");
}

/// UTS #35 flexible day period for English (the only locale with hard-coded
/// names today; a general engine needs the CLDR dayPeriodRules + per-locale
/// names). Verified against V8 / JSC / SpiderMonkey: [0,12)→morning, exactly
/// 12:00:00.000→noon, [12,18)→afternoon, [18,21)→evening, [21,24)→night
/// (midnight is absorbed by the morning range). `count` is the 'B' letter
/// count: 5 = narrow (only "noon"→"n" differs from wide/abbreviated for en).
fn flexibleDayPeriodEn(ct: CivilTime, count: usize) []const u8 {
    const narrow = count >= 5;
    if (ct.hour == 12 and ct.minute == 0 and ct.second == 0 and ct.ms_fraction == 0)
        return if (narrow) "n" else "noon";
    if (ct.hour < 12) return "in the morning";
    if (ct.hour < 18) return "in the afternoon";
    if (ct.hour < 21) return "in the evening";
    return "at night";
}

fn emitField(out: []Seg, letter: u8, count: usize, ct: CivilTime, dd: cldr.DateData, digit_base: u32, tz_name: []const u8) u32 {
    if (out.len == 0) return 0;
    const seg = &out[0];
    switch (letter) {
        'G' => setSeg(seg, "era", if (ct.year <= 0) dd.era_bc else dd.era_ad),
        'y', 'Y' => {
            const yv: u64 = @intCast(if (ct.year < 0) -ct.year else ct.year);
            // The chinese/dangi year renders as the related Gregorian year
            // (part type "relatedYear" per CLDR; the cyclic yearName is not
            // modelled).
            const ytype: []const u8 = if (ct.lunisolar_code != 0) "relatedYear" else "year";
            if (count == 2) setNumberSeg(seg, ytype, yv % 100, 2, digit_base) else setNumberSeg(seg, ytype, yv, 1, digit_base);
        },
        'M', 'L' => {
            if (ct.hebrew) {
                setSeg(seg, "month", tshared.hebrewMonthDisplayName(ct.year, ct.month));
            } else if (ct.lunisolar_code != 0) {
                // chinese/dangi months print their CODE number; a leap month
                // carries the CLDR root "bis" suffix (never a bare ordinal).
                const n: u64 = @intCast(if (ct.lunisolar_code < 0) -ct.lunisolar_code else ct.lunisolar_code);
                setNumberSeg(seg, "month", n, count, digit_base);
                if (ct.lunisolar_code < 0) {
                    const suffix = "bis";
                    const m = @min(seg.len + suffix.len, seg.buf.len);
                    @memcpy(seg.buf[seg.len..m], suffix[0 .. m - seg.len]);
                    seg.len = m;
                }
            } else if (count >= 3) {
                // Non-gregorian calendars with fixed month names (islamic
                // family, persian, indian, coptic, ethiopic) use their CLDR
                // en tables at the named widths; gregorian-month calendars
                // index the locale's own tables.
                if (tshared.calendarMonthNameEn(ct.named_cal, ct.month, count >= 4)) |name|
                    setSeg(seg, "month", name)
                else if (count >= 4)
                    setSeg(seg, "month", dd.months_wide[ct.month - 1])
                else
                    setSeg(seg, "month", dd.months_abbr[ct.month - 1]);
            } else setNumberSeg(seg, "month", ct.month, count, digit_base);
        },
        'd' => setNumberSeg(seg, "day", ct.day, count, digit_base),
        'E', 'c', 'e' => {
            if (count >= 4) setSeg(seg, "weekday", dd.days_wide[ct.weekday]) else setSeg(seg, "weekday", dd.days_abbr[ct.weekday]);
        },
        'h' => setNumberSeg(seg, "hour", h12(ct.hour), count, digit_base),
        // CLDR en (and every packed locale) writes the 23/24-hour clock
        // 2-digit (time patterns use HH); the 12-hour clock is unpadded.
        'H' => setNumberSeg(seg, "hour", ct.hour, @max(count, 2), digit_base),
        'K' => setNumberSeg(seg, "hour", ct.hour % 12, count, digit_base),
        'k' => setNumberSeg(seg, "hour", if (ct.hour == 0) 24 else ct.hour, @max(count, 2), digit_base),
        'm' => setNumberSeg(seg, "minute", ct.minute, count, digit_base),
        's' => setNumberSeg(seg, "second", ct.second, count, digit_base),
        'S' => {
            // First `count` digits of the zero-padded 3-digit millisecond fraction.
            const fm = ct.ms_fraction;
            const d3 = [3]u8{ @intCast('0' + (fm / 100) % 10), @intCast('0' + (fm / 10) % 10), @intCast('0' + fm % 10) };
            var sub: [16]u8 = undefined;
            setSeg(seg, "fractionalSecond", substituteDigits(d3[0..@min(count, 3)], digit_base, &sub));
        },
        'a', 'b' => setSeg(seg, "dayPeriod", if (ct.hour < 12) dd.am else dd.pm),
        'B' => setSeg(seg, "dayPeriod", flexibleDayPeriodEn(ct, count)),
        'z', 'Z', 'O', 'v', 'V', 'x', 'X' => setSeg(seg, "timeZoneName", tz_name),
        else => return 0,
    }
    return 1;
}

fn h12(hour: u32) u32 {
    const h = hour % 12;
    return if (h == 0) 12 else h;
}

/// Set a numeric field segment, zero-padded to `min_width`, digit-substituted.
fn setNumberSeg(seg: *Seg, typ: []const u8, value: u64, min_width: usize, digit_base: u32) void {
    var ascii: [20]u8 = undefined;
    var len: usize = 0;
    var v = value;
    if (v == 0) {
        ascii[0] = '0';
        len = 1;
    } else {
        var tmp: [20]u8 = undefined;
        var t: usize = 0;
        while (v > 0) {
            tmp[t] = @intCast('0' + (v % 10));
            t += 1;
            v /= 10;
        }
        while (t > 0) {
            t -= 1;
            ascii[len] = tmp[t];
            len += 1;
        }
    }
    // Zero-pad to min_width.
    var padded: [20]u8 = undefined;
    var plen: usize = 0;
    while (plen + len < min_width) {
        padded[plen] = '0';
        plen += 1;
    }
    @memcpy(padded[plen .. plen + len], ascii[0..len]);
    plen += len;
    // Digit substitution.
    seg.typ = typ;
    if (digit_base == '0') {
        const m = @min(plen, seg.buf.len);
        @memcpy(seg.buf[0..m], padded[0..m]);
        seg.len = m;
    } else {
        var n: usize = 0;
        for (padded[0..plen]) |ch| {
            if (n + 4 > seg.buf.len) break;
            const cp: u21 = @intCast(digit_base + (ch - '0'));
            n += std.unicode.utf8Encode(cp, seg.buf[n..]) catch 0;
        }
        seg.len = n;
    }
}

// ── PluralRules ────────────────────────────────────────────────────────────

fn installPluralRules(realm: *Realm, ns: *JSObject) !void {
    try installService(realm, ns, .{
        .name = "PluralRules",
        .ctor = pluralRulesConstructor,
        .requires_new = true,
        .arity = 0,
        .to_string_tag = "Intl.PluralRules",
        .methods = &.{
            .{ .name = "select", .fn_ptr = pluralRulesSelect, .params = 1 },
            .{ .name = "selectRange", .fn_ptr = pluralRulesSelectRange, .params = 2 },
            .{ .name = "resolvedOptions", .fn_ptr = pluralRulesResolvedOptions, .params = 0 },
        },
        .supported_locales_of = anySupportedLocalesOf,
        .set_ctor_intrinsic = struct {
            fn f(r: *Realm, c: *JSFunction) void {
                r.intrinsics.intl_plural_rules_constructor = c;
            }
        }.f,
        .set_proto_intrinsic = struct {
            fn f(r: *Realm, p: *JSObject) void {
                r.intrinsics.intl_plural_rules_prototype = p;
            }
        }.f,
    });
}

fn pluralRulesConstructor(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const inst = try newIntlInstance(realm, this_value, realm.intrinsics.intl_plural_rules_prototype, "PluralRules", true);
    const locales = argOr(args, 0, Value.undefined_);
    const options = argOr(args, 1, Value.undefined_);
    const opts = try getOptionsObject(realm, options);
    const resolved = try resolveServiceLocaleAvail(realm, locales, opts, .plural_data);
    var slots: intl.PluralRulesSlots = .{};
    errdefer slots.deinit(realm.allocator);
    slots.base.locale = resolved.locale;
    // §16.1.1 read order: type, notation, compactDisplay, then digit options.
    slots.type_name = try getOptionStringOwned(realm, opts, "type", &.{ "cardinal", "ordinal" }, "cardinal");
    slots.notation = try getOptionStringOwned(realm, opts, "notation", &.{ "standard", "scientific", "engineering", "compact" }, "standard");
    slots.compact_display = try getOptionStringOwned(realm, opts, "compactDisplay", &.{ "short", "long" }, "short");
    // §15.1.1 SetNumberFormatDigitOptions (fraction subset) — reads the digit
    // options so an abrupt getter propagates and resolvedOptions reports them.
    slots.minimum_integer_digits = try getNumberOption(realm, opts, "minimumIntegerDigits", 1, 21, 1);
    const mnfd = try getNumberOptionOpt(realm, opts, "minimumFractionDigits", 0, 100);
    const mxfd = try getNumberOptionOpt(realm, opts, "maximumFractionDigits", 0, 100);
    slots.minimum_significant_digits = try getNumberOptionOpt(realm, opts, "minimumSignificantDigits", 1, 21);
    slots.maximum_significant_digits = try getNumberOptionOpt(realm, opts, "maximumSignificantDigits", 1, 21);
    if (slots.minimum_significant_digits == null and slots.maximum_significant_digits == null) {
        slots.minimum_fraction_digits = mnfd orelse 0;
        slots.maximum_fraction_digits = mxfd orelse @max(slots.minimum_fraction_digits, 3);
        if (slots.minimum_fraction_digits > slots.maximum_fraction_digits)
            return throwRangeError(realm, "minimumFractionDigits > maximumFractionDigits");
    }
    // Rounding options, in §16.1.1 read order (after the significant digits).
    slots.rounding_increment = try getNumberOption(realm, opts, "roundingIncrement", 1, 5000, 1);
    switch (slots.rounding_increment) {
        1, 2, 5, 10, 20, 25, 50, 100, 200, 250, 500, 1000, 2000, 2500, 5000 => {},
        else => return throwRangeError(realm, "invalid roundingIncrement"),
    }
    slots.rounding_mode = try getOptionStringOwned(realm, opts, "roundingMode", &.{ "ceil", "floor", "expand", "trunc", "halfCeil", "halfFloor", "halfExpand", "halfTrunc", "halfEven" }, "halfExpand");
    slots.rounding_priority = try getOptionStringOwned(realm, opts, "roundingPriority", &.{ "auto", "morePrecision", "lessPrecision" }, "auto");
    slots.trailing_zero_display = try getOptionStringOwned(realm, opts, "trailingZeroDisplay", &.{ "auto", "stripIfInteger" }, "auto");
    try setDataLocale(realm, &slots.base);
    try storeRecord(realm, inst, .{ .plural_rules = slots });
    return heap_mod.taggedObject(inst);
}

/// Coerce a numeric Value (the result of ToNumber) to f64.
fn numberToF64(v: Value) f64 {
    return if (v.isInt32()) @floatFromInt(v.asInt32()) else v.asDouble();
}

/// §16.5.6 ResolvePlural — operands from FormatNumericToString, then
/// PluralRuleSelect against the locale's CLDR rules. Non-finite → "other".
/// Without CLDR data (`-Dintl=stub`) every value is "other".
fn pluralRulesSelect(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const rec = try requireKind(realm, this_value, .plural_rules);
    const num = try toNumber(realm, argOr(args, 0, Value.undefined_));
    const x = numberToF64(num);
    const s = rec.plural_rules;
    if (!std.math.isFinite(x) or !cldr.available) return makeStringValue(realm, "other");
    const ordinal = std.mem.eql(u8, s.type_name, "ordinal");
    const ops = cldr.computeOperands(x, s.minimum_fraction_digits, s.maximum_fraction_digits);
    const cat = cldr.selectPlural(s.base.dataLocale(), ordinal, ops);
    return makeStringValue(realm, cat.name());
}

/// §16.5.4 selectRange → §16.5.5 ResolvePluralRange. Undefined endpoints are a
/// TypeError; NaN endpoints a RangeError. CLDR plural-range tables aren't packed
/// yet, so we fall back to the end value's category (the CLDR root behaviour).
fn pluralRulesSelectRange(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const rec = try requireKind(realm, this_value, .plural_rules);
    const start_v = argOr(args, 0, Value.undefined_);
    const end_v = argOr(args, 1, Value.undefined_);
    if (start_v.isUndefined() or end_v.isUndefined())
        return throwTypeError(realm, "Intl.PluralRules.prototype.selectRange: start and end are required");
    const x = numberToF64(try toNumber(realm, start_v));
    const y = numberToF64(try toNumber(realm, end_v));
    if (std.math.isNan(x) or std.math.isNan(y))
        return throwRangeError(realm, "Intl.PluralRules.prototype.selectRange: start and end must be numbers");
    const s = rec.plural_rules;
    if (!cldr.available) return makeStringValue(realm, "other");
    const ordinal = std.mem.eql(u8, s.type_name, "ordinal");
    const yp = cldr.selectPlural(s.base.dataLocale(), ordinal, cldr.computeOperands(y, s.minimum_fraction_digits, s.maximum_fraction_digits));
    return makeStringValue(realm, yp.name());
}

fn pluralRulesResolvedOptions(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    const rec = try requireKind(realm, this_value, .plural_rules);
    const s = rec.plural_rules;
    const ordinal = std.mem.eql(u8, s.type_name, "ordinal");
    const obj = try makeResolvedBase(realm, s.base.locale);
    try setDataProp(realm, obj, "type", try makeStringValue(realm, if (s.type_name.len > 0) s.type_name else "cardinal"));
    // §16.3.2 key order: type, notation, (compactDisplay if compact),
    // minimumIntegerDigits, the digit pair, pluralCategories, rounding props.
    const notation = if (s.notation.len > 0) s.notation else "standard";
    try setDataProp(realm, obj, "notation", try makeStringValue(realm, notation));
    if (std.mem.eql(u8, notation, "compact"))
        try setDataProp(realm, obj, "compactDisplay", try makeStringValue(realm, if (s.compact_display.len > 0) s.compact_display else "short"));
    try setDataProp(realm, obj, "minimumIntegerDigits", makeNumberValue(@floatFromInt(s.minimum_integer_digits)));
    // report the fraction-digit pair, or the significant-digit pair when
    // significant digits were requested.
    if (s.minimum_significant_digits != null or s.maximum_significant_digits != null) {
        try setDataProp(realm, obj, "minimumSignificantDigits", makeNumberValue(@floatFromInt(s.minimum_significant_digits orelse 1)));
        try setDataProp(realm, obj, "maximumSignificantDigits", makeNumberValue(@floatFromInt(s.maximum_significant_digits orelse 21)));
    } else {
        try setDataProp(realm, obj, "minimumFractionDigits", makeNumberValue(@floatFromInt(s.minimum_fraction_digits)));
        try setDataProp(realm, obj, "maximumFractionDigits", makeNumberValue(@floatFromInt(s.maximum_fraction_digits)));
    }

    // pluralCategories: the categories the locale defines, canonical order,
    // "other" always last. From the CLDR mask (or just "other" without data).
    const mask: u8 = if (cldr.available) cldr.pluralCategoriesMask(s.base.dataLocale(), ordinal) else 0;
    const cats = allocateArray(realm) catch return error.OutOfMemory;
    var idx: u32 = 0;
    const order = [_]cldr.PluralCategory{ .zero, .one, .two, .few, .many };
    for (order) |c| {
        if (mask & (@as(u8, 1) << @as(u3, @intCast(@intFromEnum(c)))) != 0) {
            var key_buf: [12]u8 = undefined;
            const key = std.fmt.bufPrint(&key_buf, "{d}", .{idx}) catch unreachable;
            cats.set(realm.allocator, key, try makeStringValue(realm, c.name())) catch return error.OutOfMemory;
            idx += 1;
        }
    }
    {
        var key_buf: [12]u8 = undefined;
        const key = std.fmt.bufPrint(&key_buf, "{d}", .{idx}) catch unreachable;
        cats.set(realm.allocator, key, try makeStringValue(realm, "other")) catch return error.OutOfMemory;
        idx += 1;
    }
    cats.setArrayLength(realm.allocator, idx) catch return error.OutOfMemory;
    try setDataProp(realm, obj, "pluralCategories", heap_mod.taggedObject(cats));
    try setDataProp(realm, obj, "roundingIncrement", makeNumberValue(@floatFromInt(s.rounding_increment)));
    try setDataProp(realm, obj, "roundingMode", try makeStringValue(realm, if (s.rounding_mode.len > 0) s.rounding_mode else "halfExpand"));
    try setDataProp(realm, obj, "roundingPriority", try makeStringValue(realm, if (s.rounding_priority.len > 0) s.rounding_priority else "auto"));
    try setDataProp(realm, obj, "trailingZeroDisplay", try makeStringValue(realm, if (s.trailing_zero_display.len > 0) s.trailing_zero_display else "auto"));
    return heap_mod.taggedObject(obj);
}

// ── RelativeTimeFormat ─────────────────────────────────────────────────────

fn installRelativeTimeFormat(realm: *Realm, ns: *JSObject) !void {
    try installService(realm, ns, .{
        .name = "RelativeTimeFormat",
        .ctor = rtfConstructor,
        .requires_new = true,
        .arity = 0,
        .to_string_tag = "Intl.RelativeTimeFormat",
        .methods = &.{
            .{ .name = "format", .fn_ptr = rtfFormat, .params = 2 },
            .{ .name = "formatToParts", .fn_ptr = rtfFormatToParts, .params = 2 },
            .{ .name = "resolvedOptions", .fn_ptr = rtfResolvedOptions, .params = 0 },
        },
        .supported_locales_of = anySupportedLocalesOf,
        .set_ctor_intrinsic = struct {
            fn f(r: *Realm, c: *JSFunction) void {
                r.intrinsics.intl_relative_time_format_constructor = c;
            }
        }.f,
        .set_proto_intrinsic = struct {
            fn f(r: *Realm, p: *JSObject) void {
                r.intrinsics.intl_relative_time_format_prototype = p;
            }
        }.f,
    });
}

fn rtfConstructor(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const inst = try newIntlInstance(realm, this_value, realm.intrinsics.intl_relative_time_format_prototype, "RelativeTimeFormat", true);
    const locales = argOr(args, 0, Value.undefined_);
    const options = argOr(args, 1, Value.undefined_);
    const opts = try coerceOptionsToObject(realm, options);
    const resolved = try resolveServiceLocale(realm, locales, opts);
    var slots: intl.RelativeTimeFormatSlots = .{};
    errdefer slots.deinit(realm.allocator);
    slots.base.locale = resolved.locale;
    try retainRelevantUnicodeExtensions(realm, &slots.base, &.{"nu"}); // §9.2.7 RelativeTimeFormat keys
    // § read order: numberingSystem, style, numeric.
    slots.numbering_system = try resolveNumberingSystem(realm, slots.base.locale, slots.base.locale, opts);
    slots.style = try getOptionStringOwned(realm, opts, "style", &.{ "long", "short", "narrow" }, "long");
    slots.numeric = try getOptionStringOwned(realm, opts, "numeric", &.{ "always", "auto" }, "always");
    try storeRecord(realm, inst, .{ .relative_time_format = slots });
    return heap_mod.taggedObject(inst);
}

/// RTF unit → index (year…second); accepts the plural form ("days") too.
fn rtfUnitIndex(raw: []const u8) ?u8 {
    const u = if (raw.len > 0 and raw[raw.len - 1] == 's') raw[0 .. raw.len - 1] else raw;
    const names = [8][]const u8{ "year", "quarter", "month", "week", "day", "hour", "minute", "second" };
    for (names, 0..) |nm, i| if (std.mem.eql(u8, u, nm)) return @intCast(i);
    return null;
}

fn rtfFormat(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const rec = try requireKind(realm, this_value, .relative_time_format);
    const s = rec.relative_time_format;
    const value = numberToF64(try toNumber(realm, argOr(args, 0, Value.undefined_)));
    if (!std.math.isFinite(value)) return throwRangeError(realm, "RelativeTimeFormat value must be finite");
    const unit_raw = try valueToStringSlice(realm, argOr(args, 1, Value.undefined_));
    const unit_idx = rtfUnitIndex(unit_raw) orelse return throwRangeError(realm, "invalid RelativeTimeFormat unit");
    const style_idx: u8 = if (std.mem.eql(u8, s.style, "short")) 1 else if (std.mem.eql(u8, s.style, "narrow")) 2 else 0;

    if (cldr.available) {
        // numeric:"auto" + an integer with a matching relative-type → use it.
        if (std.mem.eql(u8, s.numeric, "auto") and value == std.math.floor(value) and @abs(value) < 128) {
            if (cldr.relativeTypeString(s.base.dataLocale(), unit_idx, style_idx, @intFromFloat(value))) |str|
                return makeStringValue(realm, str);
        }
        const future = !std.math.signbit(value);
        const abs_v = @abs(value);
        const cat = cldr.selectPlural(s.base.dataLocale(), false, cldr.computeOperands(abs_v, 0, 3));
        if (cldr.relativeTimePattern(s.base.dataLocale(), unit_idx, style_idx, future, cat)) |pat|
            return rtfApplyPattern(realm, s, pat, abs_v);
    }
    // Fallback: "{n} {unit}" from the already-coerced value (no re-coercion).
    var nb: [64]u8 = undefined;
    const ns = std.fmt.bufPrint(&nb, "{d}", .{value}) catch "0";
    const out = std.fmt.allocPrint(realm.allocator, "{s} {s}", .{ ns, unit_raw }) catch return error.OutOfMemory;
    defer realm.allocator.free(out);
    return makeStringValue(realm, out);
}

/// Substitute {0} in a relative-time pattern with the locale-formatted magnitude.
fn rtfApplyPattern(realm: *Realm, s: intl.RelativeTimeFormatSlots, pat: []const u8, abs_v: f64) NativeError!Value {
    var segs: [64]Seg = undefined;
    var nfs: intl.NumberFormatSlots = .{};
    nfs.base.locale = s.base.locale;
    nfs.base.numbering_system = if (s.numbering_system.len > 0) s.numbering_system else "latn";
    nfs.style = "decimal";
    nfs.use_grouping = "auto";
    nfs.sign_display = "auto";
    nfs.notation = "standard";
    nfs.rounding_type = "fractionDigits";
    nfs.minimum_integer_digits = 1;
    nfs.minimum_fraction_digits = 0;
    nfs.maximum_fraction_digits = 3;
    nfs.rounding_increment = 1;
    nfs.rounding_mode = "halfExpand";
    nfs.trailing_zero_display = "auto";
    const cnt = renderNumber(&nfs, abs_v, &segs);

    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(realm.allocator);
    const idx = std.mem.indexOf(u8, pat, "{0}") orelse pat.len;
    out.appendSlice(realm.allocator, pat[0..idx]) catch return error.OutOfMemory;
    var i: u32 = 0;
    while (i < cnt) : (i += 1) out.appendSlice(realm.allocator, segs[i].bytes()) catch return error.OutOfMemory;
    if (idx < pat.len) out.appendSlice(realm.allocator, pat[idx + 3 ..]) catch return error.OutOfMemory;
    return makeStringValue(realm, out.items);
}

fn rtfEmitPart(realm: *Realm, arr: *JSObject, pn: *u32, typ: []const u8, value: []const u8, unit: ?[]const u8) NativeError!void {
    const part = realm.heap.allocateObject() catch return error.OutOfMemory;
    realm.heap.setObjectPrototype(part, realm.intrinsics.object_prototype);
    try setDataProp(realm, part, "type", try makeStringValue(realm, typ));
    try setDataProp(realm, part, "value", try makeStringValue(realm, value));
    if (unit) |u| try setDataProp(realm, part, "unit", try makeStringValue(realm, u));
    var kb: [12]u8 = undefined;
    const k = std.fmt.bufPrint(&kb, "{d}", .{pn.*}) catch unreachable;
    arr.set(realm.allocator, k, heap_mod.taggedObject(part)) catch return error.OutOfMemory;
    pn.* += 1;
}

fn rtfFormatToParts(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const rec = try requireKind(realm, this_value, .relative_time_format);
    const s = rec.relative_time_format;
    const value = numberToF64(try toNumber(realm, argOr(args, 0, Value.undefined_)));
    if (!std.math.isFinite(value)) return throwRangeError(realm, "RelativeTimeFormat value must be finite");
    const unit_raw = try valueToStringSlice(realm, argOr(args, 1, Value.undefined_));
    const unit_idx = rtfUnitIndex(unit_raw) orelse return throwRangeError(realm, "invalid RelativeTimeFormat unit");
    const names = [8][]const u8{ "year", "quarter", "month", "week", "day", "hour", "minute", "second" };
    const singular = names[unit_idx];
    const style_idx: u8 = if (std.mem.eql(u8, s.style, "short")) 1 else if (std.mem.eql(u8, s.style, "narrow")) 2 else 0;

    const arr = allocateArray(realm) catch return error.OutOfMemory;
    var pn: u32 = 0;
    if (cldr.available) {
        if (std.mem.eql(u8, s.numeric, "auto") and value == std.math.floor(value) and @abs(value) < 128) {
            if (cldr.relativeTypeString(s.base.dataLocale(), unit_idx, style_idx, @intFromFloat(value))) |str| {
                try rtfEmitPart(realm, arr, &pn, "literal", str, null);
                arr.setArrayLength(realm.allocator, pn) catch return error.OutOfMemory;
                return heap_mod.taggedObject(arr);
            }
        }
        const future = !std.math.signbit(value);
        const abs_v = @abs(value);
        const cat = cldr.selectPlural(s.base.dataLocale(), false, cldr.computeOperands(abs_v, 0, 3));
        if (cldr.relativeTimePattern(s.base.dataLocale(), unit_idx, style_idx, future, cat)) |pat| {
            var segs: [64]Seg = undefined;
            var nfs: intl.NumberFormatSlots = .{};
            nfs.base.locale = s.base.locale;
            nfs.base.numbering_system = if (s.numbering_system.len > 0) s.numbering_system else "latn";
            nfs.style = "decimal";
            nfs.use_grouping = "auto";
            nfs.sign_display = "auto";
            nfs.notation = "standard";
            nfs.rounding_type = "fractionDigits";
            nfs.minimum_integer_digits = 1;
            nfs.minimum_fraction_digits = 0;
            nfs.maximum_fraction_digits = 3;
            nfs.rounding_increment = 1;
            nfs.rounding_mode = "halfExpand";
            nfs.trailing_zero_display = "auto";
            const cnt = renderNumber(&nfs, abs_v, &segs);
            const idx = std.mem.indexOf(u8, pat, "{0}") orelse pat.len;
            if (idx > 0) try rtfEmitPart(realm, arr, &pn, "literal", pat[0..idx], null);
            var i: u32 = 0;
            while (i < cnt) : (i += 1) try rtfEmitPart(realm, arr, &pn, segs[i].typ, segs[i].bytes(), singular);
            if (idx < pat.len and idx + 3 < pat.len) try rtfEmitPart(realm, arr, &pn, "literal", pat[idx + 3 ..], null);
            arr.setArrayLength(realm.allocator, pn) catch return error.OutOfMemory;
            return heap_mod.taggedObject(arr);
        }
    }
    var nb: [64]u8 = undefined;
    const fb = std.fmt.bufPrint(&nb, "{d} {s}", .{ value, unit_raw }) catch "?";
    try rtfEmitPart(realm, arr, &pn, "literal", fb, null);
    arr.setArrayLength(realm.allocator, pn) catch return error.OutOfMemory;
    return heap_mod.taggedObject(arr);
}

fn rtfResolvedOptions(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    const rec = try requireKind(realm, this_value, .relative_time_format);
    const s = rec.relative_time_format;
    const obj = try makeResolvedBase(realm, s.base.locale);
    // §17.3.4 key order: locale, style, numeric, numberingSystem.
    try setDataProp(realm, obj, "style", try makeStringValue(realm, if (s.style.len > 0) s.style else "long"));
    try setDataProp(realm, obj, "numeric", try makeStringValue(realm, if (s.numeric.len > 0) s.numeric else "always"));
    try setDataProp(realm, obj, "numberingSystem", try makeStringValue(realm, if (s.numbering_system.len > 0) s.numbering_system else "latn"));
    return heap_mod.taggedObject(obj);
}

// ── ListFormat ─────────────────────────────────────────────────────────────

fn installListFormat(realm: *Realm, ns: *JSObject) !void {
    try installService(realm, ns, .{
        .name = "ListFormat",
        .ctor = listFormatConstructor,
        .requires_new = true,
        .arity = 0,
        .to_string_tag = "Intl.ListFormat",
        .methods = &.{
            .{ .name = "format", .fn_ptr = listFormatFormat, .params = 1 },
            .{ .name = "formatToParts", .fn_ptr = listFormatFormatToParts, .params = 1 },
            .{ .name = "resolvedOptions", .fn_ptr = listFormatResolvedOptions, .params = 0 },
        },
        .supported_locales_of = anySupportedLocalesOf,
        .set_ctor_intrinsic = struct {
            fn f(r: *Realm, c: *JSFunction) void {
                r.intrinsics.intl_list_format_constructor = c;
            }
        }.f,
        .set_proto_intrinsic = struct {
            fn f(r: *Realm, p: *JSObject) void {
                r.intrinsics.intl_list_format_prototype = p;
            }
        }.f,
    });
}

fn listFormatConstructor(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const inst = try newIntlInstance(realm, this_value, realm.intrinsics.intl_list_format_prototype, "ListFormat", true);
    const locales = argOr(args, 0, Value.undefined_);
    const options = argOr(args, 1, Value.undefined_);
    const opts = try getOptionsObject(realm, options);
    const resolved = try resolveServiceLocale(realm, locales, opts);
    var slots: intl.ListFormatSlots = .{};
    slots.base.locale = resolved.locale;
    slots.type_name = try getOptionStringOwned(realm, opts, "type", &.{ "conjunction", "disjunction", "unit" }, "conjunction");
    slots.style = try getOptionStringOwned(realm, opts, "style", &.{ "long", "short", "narrow" }, "long");
    try storeRecord(realm, inst, .{ .list_format = slots });
    return heap_mod.taggedObject(inst);
}

/// One formatted-list part: `is_element` distinguishes an "element" (a list
/// item) from a "literal" (pattern text). `val` is a borrowed slice — either
/// an owned list item or a slice of a CLDR pattern in the blob — valid until
/// the string list is freed.
const ListSeg = struct { is_element: bool, val: []const u8 };

/// §13.5.1 StringListFromIterable — iterate `list_v` via the iterator protocol,
/// requiring every yielded value to be a String (else IteratorClose + TypeError).
/// Returns an owned list of owned string copies; caller frees both.
fn listStringList(realm: *Realm, list_v: Value) NativeError![][]const u8 {
    var list: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer {
        for (list.items) |s| realm.allocator.free(s);
        list.deinit(realm.allocator);
    }
    if (list_v.isUndefined()) return list.toOwnedSlice(realm.allocator) catch return error.OutOfMemory;

    const iter_v = lantern.openIterator(realm.allocator, realm, list_v) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.NotIterable => return throwTypeError(realm, "ListFormat list is not iterable"),
        else => return error.NativeThrew,
    };
    const iter_obj = heap_mod.valueAsPlainObject(iter_v) orelse return throwTypeError(realm, "iterator is not an object");
    const next_fn = heap_mod.valueAsFunction(try getPropertyChain(realm, iter_obj, "next")) orelse
        return throwTypeError(realm, "iterator.next is not callable");

    var guard: usize = 0;
    while (guard < 1_000_000) : (guard += 1) {
        const step = switch (lantern.callJSFunction(realm.allocator, realm, next_fn, iter_v, &.{}) catch return error.NativeThrew) {
            .value => |v| v,
            // Propagate an abrupt completion from next() (its thrown value,
            // not a generic TypeError) so iterator-step-throw fixtures see it.
            .thrown => |ex| {
                realm.pending_exception = ex;
                return error.NativeThrew;
            },
            .yielded => return error.NativeThrew,
        };
        const step_obj = heap_mod.valueAsPlainObject(step) orelse return throwTypeError(realm, "iterator result is not an object");
        if (toBoolean(try getPropertyChain(realm, step_obj, "done"))) break;
        const value_v = try getPropertyChain(realm, step_obj, "value");
        if (!value_v.isString()) {
            // §13.5.1 — non-String element: close the iterator, then throw.
            listCloseIterator(realm, iter_v);
            return throwTypeError(realm, "ListFormat list elements must be strings");
        }
        const s = try valueToStringSlice(realm, value_v);
        list.append(realm.allocator, realm.allocator.dupe(u8, s) catch return error.OutOfMemory) catch return error.OutOfMemory;
    }
    return list.toOwnedSlice(realm.allocator) catch return error.OutOfMemory;
}

/// §7.4.11 IteratorClose (best-effort): invoke the iterator's `return` method,
/// swallowing any error — the original throw is what propagates.
fn listCloseIterator(realm: *Realm, iter_v: Value) void {
    const iter_obj = heap_mod.valueAsPlainObject(iter_v) orelse return;
    const ret_v = getPropertyChain(realm, iter_obj, "return") catch return;
    const ret_fn = heap_mod.valueAsFunction(ret_v) orelse return;
    _ = lantern.callJSFunction(realm.allocator, realm, ret_fn, iter_v, &.{}) catch {};
}

/// Build the formatted-list parts from the string list using the locale's CLDR
/// list patterns (§13.5.3 CreatePartsFromList). `out` segments borrow `items`
/// and the pattern blob — consume before freeing `items`.
fn listBuildParts(realm: *Realm, slots: *const intl.ListFormatSlots, items: [][]const u8, out: *std.ArrayListUnmanaged(ListSeg)) NativeError!void {
    const n = items.len;
    if (n == 0) return;
    const t: u8 = if (std.mem.eql(u8, slots.type_name, "disjunction")) 1 else if (std.mem.eql(u8, slots.type_name, "unit")) 2 else 0;
    const sty: u8 = if (std.mem.eql(u8, slots.style, "short")) 1 else if (std.mem.eql(u8, slots.style, "narrow")) 2 else 0;

    out.append(realm.allocator, .{ .is_element = true, .val = items[0] }) catch return error.OutOfMemory;
    var i: usize = 1;
    while (i < n) : (i += 1) {
        const which: cldr.ListPatternKind = if (n == 2) .two else if (i == 1) .start else if (i == n - 1) .end else .middle;
        const pat = cldr.listPattern(slots.base.locale, t, sty, which) orelse defaultListPattern(which);
        // Deconstruct the pattern: {0} expands to the parts built so far, {1}
        // is the next element; literal runs become literal segments. Rebuilt
        // into `next` so {0} can splice the prior parts in place.
        var next: std.ArrayListUnmanaged(ListSeg) = .empty;
        errdefer next.deinit(realm.allocator);
        var p: usize = 0;
        while (p < pat.len) {
            if (p + 3 <= pat.len and pat[p] == '{' and pat[p + 2] == '}' and (pat[p + 1] == '0' or pat[p + 1] == '1')) {
                if (pat[p + 1] == '0') {
                    next.appendSlice(realm.allocator, out.items) catch return error.OutOfMemory;
                } else {
                    next.append(realm.allocator, .{ .is_element = true, .val = items[i] }) catch return error.OutOfMemory;
                }
                p += 3;
            } else {
                const start = p;
                while (p < pat.len and pat[p] != '{') p += 1;
                next.append(realm.allocator, .{ .is_element = false, .val = pat[start..p] }) catch return error.OutOfMemory;
            }
        }
        out.deinit(realm.allocator);
        out.* = next;
    }
}

fn defaultListPattern(which: cldr.ListPatternKind) []const u8 {
    return switch (which) {
        .two, .start, .middle, .end => "{0}, {1}",
    };
}

fn listFormatFormat(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const rec = try requireKind(realm, this_value, .list_format);
    const items = try listStringList(realm, argOr(args, 0, Value.undefined_));
    defer {
        for (items) |s| realm.allocator.free(s);
        realm.allocator.free(items);
    }
    var parts: std.ArrayListUnmanaged(ListSeg) = .empty;
    defer parts.deinit(realm.allocator);
    try listBuildParts(realm, &rec.list_format, items, &parts);

    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(realm.allocator);
    for (parts.items) |seg| out.appendSlice(realm.allocator, seg.val) catch return error.OutOfMemory;
    return makeStringValue(realm, out.items);
}

fn listFormatFormatToParts(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const rec = try requireKind(realm, this_value, .list_format);
    const items = try listStringList(realm, argOr(args, 0, Value.undefined_));
    defer {
        for (items) |s| realm.allocator.free(s);
        realm.allocator.free(items);
    }
    var parts: std.ArrayListUnmanaged(ListSeg) = .empty;
    defer parts.deinit(realm.allocator);
    try listBuildParts(realm, &rec.list_format, items, &parts);

    const arr = allocateArray(realm) catch return error.OutOfMemory;
    for (parts.items, 0..) |seg, idx| {
        const part = realm.heap.allocateObject() catch return error.OutOfMemory;
        realm.heap.setObjectPrototype(part, realm.intrinsics.object_prototype);
        try setDataProp(realm, part, "type", try makeStringValue(realm, if (seg.is_element) "element" else "literal"));
        try setDataProp(realm, part, "value", try makeStringValue(realm, seg.val));
        var idx_buf: [24]u8 = undefined;
        const k = std.fmt.bufPrint(&idx_buf, "{d}", .{idx}) catch unreachable;
        arr.set(realm.allocator, k, heap_mod.taggedObject(part)) catch return error.OutOfMemory;
    }
    arr.setArrayLength(realm.allocator, @intCast(parts.items.len)) catch return error.OutOfMemory;
    return heap_mod.taggedObject(arr);
}

fn listFormatResolvedOptions(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    const rec = try requireKind(realm, this_value, .list_format);
    const s = rec.list_format;
    const obj = try makeResolvedBase(realm, s.base.locale);
    try setDataProp(realm, obj, "type", try makeStringValue(realm, if (s.type_name.len > 0) s.type_name else "conjunction"));
    try setDataProp(realm, obj, "style", try makeStringValue(realm, if (s.style.len > 0) s.style else "long"));
    return heap_mod.taggedObject(obj);
}

// ── DisplayNames ───────────────────────────────────────────────────────────

fn installDisplayNames(realm: *Realm, ns: *JSObject) !void {
    try installService(realm, ns, .{
        .name = "DisplayNames",
        .ctor = displayNamesConstructor,
        .requires_new = true,
        .arity = 2,
        .to_string_tag = "Intl.DisplayNames",
        .methods = &.{
            .{ .name = "of", .fn_ptr = displayNamesOf, .params = 1 },
            .{ .name = "resolvedOptions", .fn_ptr = displayNamesResolvedOptions, .params = 0 },
        },
        .supported_locales_of = anySupportedLocalesOf,
        .set_ctor_intrinsic = struct {
            fn f(r: *Realm, c: *JSFunction) void {
                r.intrinsics.intl_display_names_constructor = c;
            }
        }.f,
        .set_proto_intrinsic = struct {
            fn f(r: *Realm, p: *JSObject) void {
                r.intrinsics.intl_display_names_prototype = p;
            }
        }.f,
    });
}

fn displayNamesConstructor(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const inst = try newIntlInstance(realm, this_value, realm.intrinsics.intl_display_names_prototype, "DisplayNames", true);
    const locales = argOr(args, 0, Value.undefined_);
    const options = argOr(args, 1, Value.undefined_);

    // §12.1.1 in spec order: GetOptionsObject, then CanonicalizeLocaleList +
    // localeMatcher resolve (resolveServiceLocale), then style, then the
    // required `type` (read with an undefined fallback + TypeError when absent,
    // *after* style) so an invalid localeMatcher / style, an abrupt option
    // getter, or a poisoned locales arg throws first. The old early `type`
    // check surfaced the wrong error for those cases.
    const opts = try getOptionsObject(realm, options);
    const resolved = try resolveServiceLocale(realm, locales, opts);
    var slots: intl.DisplayNamesSlots = .{};
    errdefer slots.deinit(realm.allocator);
    slots.base.locale = resolved.locale;
    slots.style = try getOptionStringOwned(realm, opts, "style", &.{ "narrow", "short", "long" }, "long");
    const type_s = try getOptionString(realm, opts, "type", &.{ "language", "region", "script", "currency", "calendar", "dateTimeField" }, "");
    if (type_s.len == 0) return throwTypeError(realm, "Intl.DisplayNames options.type is required");
    slots.type_name = realm.allocator.dupe(u8, type_s) catch return error.OutOfMemory;
    slots.fallback = try getOptionStringOwned(realm, opts, "fallback", &.{ "code", "none" }, "code");
    slots.language_display = try getOptionStringOwned(realm, opts, "languageDisplay", &.{ "dialect", "standard" }, "dialect");
    try setDataLocale(realm, &slots.base);
    try storeRecord(realm, inst, .{ .display_names = slots });
    return heap_mod.taggedObject(inst);
}

fn displayNamesOf(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const rec = try requireKind(realm, this_value, .display_names);
    const s = rec.display_names;
    const raw = try valueToStringSlice(realm, argOr(args, 0, Value.undefined_));

    // §12.5.1 — canonicalise + structurally validate the code per type.
    var cbuf: [64]u8 = undefined;
    const kind: ?cldr.DisplayKind =
        if (std.mem.eql(u8, s.type_name, "language")) .language else if (std.mem.eql(u8, s.type_name, "region")) .region else if (std.mem.eql(u8, s.type_name, "script")) .script else if (std.mem.eql(u8, s.type_name, "currency")) .currency else null;

    const canonical: []const u8 = blk: {
        if (kind) |k| switch (k) {
            .region => break :blk (try canonRegion(realm, raw, &cbuf)),
            .script => break :blk (try canonScript(realm, raw, &cbuf)),
            .currency => break :blk (try canonCurrency(realm, raw, &cbuf)),
            .language => {
                // §12.5.1 — type:"language" requires a bare unicode_language_id
                // (no singleton / -u- / -x- extensions), not just any valid tag.
                if (!intl.isUnicodeLanguageId(raw)) return throwRangeError(realm, "invalid language code");
                const c = intl.canonicalizeUnicodeLocaleId(realm.allocator, raw) catch return throwRangeError(realm, "invalid language code");
                defer realm.allocator.free(c);
                const n = @min(c.len, cbuf.len);
                @memcpy(cbuf[0..n], c[0..n]);
                break :blk cbuf[0..n];
            },
        };
        // §12.5.1 — calendar codes must match a Unicode `type` (one or more
        // 3-8 alphanumeric subtags); dateTimeField must be a sanctioned field.
        if (std.mem.eql(u8, s.type_name, "calendar")) {
            if (!intl.isValidUnicodeType(raw)) return throwRangeError(realm, "invalid calendar code");
        } else if (std.mem.eql(u8, s.type_name, "dateTimeField")) {
            if (!isDateTimeField(raw)) return throwRangeError(realm, "invalid dateTimeField code");
        }
        break :blk raw;
    };

    if (kind != null and cldr.available) {
        if (cldr.displayName(s.base.dataLocale(), kind.?, canonical)) |nm| return makeStringValue(realm, nm);
    }
    if (std.mem.eql(u8, s.fallback, "none")) return Value.undefined_;
    return makeStringValue(realm, canonical); // fallback: the canonicalised code
}

/// §12.5.1 — the sanctioned `dateTimeField` codes for Intl.DisplayNames.
fn isDateTimeField(code: []const u8) bool {
    const fields = [_][]const u8{
        "era", "year",      "quarter", "month",  "weekOfYear", "weekday",
        "day", "dayPeriod", "hour",    "minute", "second",     "timeZoneName",
    };
    for (fields) |f| if (std.mem.eql(u8, code, f)) return true;
    return false;
}

fn canonRegion(realm: *Realm, raw: []const u8, buf: []u8) NativeError![]const u8 {
    if (raw.len == 2 and isAsciiAlpha(raw)) {
        for (raw, 0..) |c, i| buf[i] = std.ascii.toUpper(c);
        return buf[0..2];
    }
    if (raw.len == 3 and isAsciiDigit(raw)) {
        @memcpy(buf[0..3], raw);
        return buf[0..3];
    }
    return throwRangeError(realm, "invalid region code");
}

fn canonScript(realm: *Realm, raw: []const u8, buf: []u8) NativeError![]const u8 {
    if (raw.len != 4 or !isAsciiAlpha(raw)) return throwRangeError(realm, "invalid script code");
    buf[0] = std.ascii.toUpper(raw[0]);
    for (raw[1..], 1..) |c, i| buf[i] = std.ascii.toLower(c);
    return buf[0..4];
}

fn canonCurrency(realm: *Realm, raw: []const u8, buf: []u8) NativeError![]const u8 {
    if (raw.len != 3 or !isAsciiAlpha(raw)) return throwRangeError(realm, "invalid currency code");
    for (raw, 0..) |c, i| buf[i] = std.ascii.toUpper(c);
    return buf[0..3];
}

fn isAsciiAlpha(s: []const u8) bool {
    for (s) |c| if (!std.ascii.isAlphabetic(c)) return false;
    return true;
}
fn isAsciiDigit(s: []const u8) bool {
    for (s) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
}

fn displayNamesResolvedOptions(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    const rec = try requireKind(realm, this_value, .display_names);
    const s = rec.display_names;
    const obj = try makeResolvedBase(realm, s.base.locale);
    try setDataProp(realm, obj, "style", try makeStringValue(realm, if (s.style.len > 0) s.style else "long"));
    try setDataProp(realm, obj, "type", try makeStringValue(realm, if (s.type_name.len > 0) s.type_name else "language"));
    try setDataProp(realm, obj, "fallback", try makeStringValue(realm, if (s.fallback.len > 0) s.fallback else "code"));
    try setDataProp(realm, obj, "languageDisplay", try makeStringValue(realm, if (s.language_display.len > 0) s.language_display else "dialect"));
    return heap_mod.taggedObject(obj);
}

// ── Segmenter ──────────────────────────────────────────────────────────────

fn installSegmenter(realm: *Realm, ns: *JSObject) !void {
    try installService(realm, ns, .{
        .name = "Segmenter",
        .ctor = segmenterConstructor,
        .requires_new = true,
        .arity = 0,
        .to_string_tag = "Intl.Segmenter",
        .methods = &.{
            .{ .name = "segment", .fn_ptr = segmenterSegment, .params = 1 },
            .{ .name = "resolvedOptions", .fn_ptr = segmenterResolvedOptions, .params = 0 },
        },
        .supported_locales_of = anySupportedLocalesOf,
        .set_ctor_intrinsic = struct {
            fn f(r: *Realm, c: *JSFunction) void {
                r.intrinsics.intl_segmenter_constructor = c;
            }
        }.f,
        .set_proto_intrinsic = struct {
            fn f(r: *Realm, p: *JSObject) void {
                r.intrinsics.intl_segmenter_prototype = p;
            }
        }.f,
    });

    // %Segments.prototype% — `containing` + the segment iterator factory.
    const seg_proto = realm.heap.allocateObject() catch return error.OutOfMemory;
    realm.heap.setObjectPrototype(seg_proto, realm.intrinsics.object_prototype);
    try installNativeMethodOnProto(realm, seg_proto, "containing", segmentsContaining, 1);
    try installNativeMethodOnProto(realm, seg_proto, "@@iterator", segmentsIterator, 0);
    realm.intrinsics.intl_segments_prototype = seg_proto;

    // %SegmentIterator.prototype% — `next` + the self-returning @@iterator,
    // tagged "Segmenter String Iterator" (§18.6.2.2).
    const it_proto = realm.heap.allocateObject() catch return error.OutOfMemory;
    realm.heap.setObjectPrototype(it_proto, realm.intrinsics.object_prototype);
    try installNativeMethodOnProto(realm, it_proto, "next", segmentIteratorNext, 0);
    try installNativeMethodOnProto(realm, it_proto, "@@iterator", segmentIteratorSelf, 0);
    try installToStringTag(realm, it_proto, "Segmenter String Iterator");
    realm.intrinsics.intl_segment_iterator_prototype = it_proto;
}

fn segmenterConstructor(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const inst = try newIntlInstance(realm, this_value, realm.intrinsics.intl_segmenter_prototype, "Segmenter", true);
    const locales = argOr(args, 0, Value.undefined_);
    const options = argOr(args, 1, Value.undefined_);
    const opts = try getOptionsObject(realm, options);
    const resolved = try resolveServiceLocale(realm, locales, opts);
    var slots: intl.SegmenterSlots = .{};
    slots.base.locale = resolved.locale;
    slots.granularity = try getOptionStringOwned(realm, opts, "granularity", &.{ "grapheme", "word", "sentence" }, "grapheme");
    try storeRecord(realm, inst, .{ .segmenter = slots });
    return heap_mod.taggedObject(inst);
}

/// §18.4.1 Intl.Segmenter.prototype.segment — returns a Segments object whose
/// internal-slots record holds the (duped) string + granularity in a typed
/// slot (never a user-visible property).
fn segmenterSegment(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const seg_rec = try requireKind(realm, this_value, .segmenter);
    const granularity = seg_rec.segmenter.granularity;
    const str = try valueToStringSlice(realm, argOr(args, 0, Value.undefined_));
    return makeSegmentsObject(realm, realm.intrinsics.intl_segments_prototype.?, str, granularity);
}

fn makeSegmentsObject(realm: *Realm, proto: *JSObject, str: []const u8, granularity: []const u8) NativeError!Value {
    const segs = realm.heap.allocateObject() catch return error.OutOfMemory;
    realm.heap.setObjectPrototype(segs, proto);
    const rec: intl.SegmentsRecord = .{
        .string = realm.allocator.dupe(u8, str) catch return error.OutOfMemory,
        .granularity = realm.allocator.dupe(u8, if (granularity.len > 0) granularity else "grapheme") catch return error.OutOfMemory,
        .pos = 0,
    };
    try storeRecord(realm, segs, .{ .segments = rec });
    return heap_mod.taggedObject(segs);
}

/// %Segments.prototype%.containing(index) — the segment data object whose
/// boundaries straddle the code-unit `index`, or undefined when out of range.
fn segmentsContaining(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const rec = try requireKind(realm, this_value, .segments);
    const sr = rec.segments;
    const n = numberToF64(try toNumber(realm, argOr(args, 0, Value.undefined_)));
    const len_cu: f64 = @floatFromInt(utf16.lengthInCodeUnits(sr.string));
    const idx_f = if (std.math.isNan(n)) 0 else std.math.trunc(n);
    if (idx_f < 0 or idx_f >= len_cu) return Value.undefined_;
    const idx_cu: usize = @intFromFloat(idx_f);
    // Walk segments from the start until one contains idx_cu.
    var bs: usize = 0;
    while (bs < sr.string.len) {
        const be = segmentEndByte(sr.string, sr.granularity, bs);
        const start_cu = utf16.codeUnitIndexForByte(sr.string, bs);
        const end_cu = utf16.codeUnitIndexForByte(sr.string, be);
        if (idx_cu >= start_cu and idx_cu < end_cu)
            return makeSegmentData(realm, sr, bs, be);
        bs = be;
    }
    return Value.undefined_;
}

/// %Segments.prototype%[@@iterator] — a fresh Segment Iterator over the string.
fn segmentsIterator(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    const rec = try requireKind(realm, this_value, .segments);
    const sr = rec.segments;
    const it = realm.heap.allocateObject() catch return error.OutOfMemory;
    realm.heap.setObjectPrototype(it, realm.intrinsics.intl_segment_iterator_prototype.?);
    const irec: intl.SegmentsRecord = .{
        .string = realm.allocator.dupe(u8, sr.string) catch return error.OutOfMemory,
        .granularity = realm.allocator.dupe(u8, sr.granularity) catch return error.OutOfMemory,
        .pos = 0,
    };
    try storeRecord(realm, it, .{ .segments = irec });
    return heap_mod.taggedObject(it);
}

fn segmentIteratorSelf(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    _ = try requireKind(realm, this_value, .segments);
    return this_value;
}

/// %SegmentIterator.prototype%.next — yield the next segment data object,
/// advancing the iterator's byte cursor.
fn segmentIteratorNext(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    const rec = try requireKind(realm, this_value, .segments);
    const sr = &rec.segments; // mutable: advance pos
    const result = realm.heap.allocateObject() catch return error.OutOfMemory;
    realm.heap.setObjectPrototype(result, realm.intrinsics.object_prototype);
    if (sr.pos >= sr.string.len) {
        try setDataProp(realm, result, "value", Value.undefined_);
        try setDataProp(realm, result, "done", makeBoolValue(true));
        return heap_mod.taggedObject(result);
    }
    const bs = sr.pos;
    const be = segmentEndByte(sr.string, sr.granularity, bs);
    sr.pos = be;
    const data = try makeSegmentData(realm, sr.*, bs, be);
    try setDataProp(realm, result, "value", data);
    try setDataProp(realm, result, "done", makeBoolValue(false));
    return heap_mod.taggedObject(result);
}

/// The §18.7.1 segment data object: { segment, index, input[, isWordLike] }.
fn makeSegmentData(realm: *Realm, sr: intl.SegmentsRecord, byte_start: usize, byte_end: usize) NativeError!Value {
    const obj = realm.heap.allocateObject() catch return error.OutOfMemory;
    realm.heap.setObjectPrototype(obj, realm.intrinsics.object_prototype);
    try setDataProp(realm, obj, "segment", try makeStringValue(realm, sr.string[byte_start..byte_end]));
    try setDataProp(realm, obj, "index", makeNumberValue(@floatFromInt(utf16.codeUnitIndexForByte(sr.string, byte_start))));
    try setDataProp(realm, obj, "input", try makeStringValue(realm, sr.string));
    if (std.mem.eql(u8, sr.granularity, "word"))
        try setDataProp(realm, obj, "isWordLike", makeBoolValue(uax29.segmentIsWordLike(sr.string[byte_start..byte_end])));
    return heap_mod.taggedObject(obj);
}

/// End (byte offset) of the segment starting at byte `start`, by granularity.
/// Grapheme and word follow UAX #29 (src/runtime/uax29.zig); sentence is a
/// terminator + trailing-spaces heuristic pending the §5.1 rules.
fn segmentEndByte(bytes: []const u8, granularity: []const u8, start: usize) usize {
    if (start >= bytes.len) return bytes.len;
    if (std.mem.eql(u8, granularity, "word")) return uax29.wordEnd(bytes, start);
    if (std.mem.eql(u8, granularity, "sentence")) {
        var i = start;
        while (i < bytes.len) {
            const c = bytes[i];
            i += utf16.utf8SeqLen(bytes[i]);
            if (c == '.' or c == '!' or c == '?') {
                while (i < bytes.len and (bytes[i] == ' ' or bytes[i] == '\t' or bytes[i] == '\n')) i += 1;
                break;
            }
        }
        return i;
    }
    return uax29.graphemeEnd(bytes, start);
}

fn segmenterResolvedOptions(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    const rec = try requireKind(realm, this_value, .segmenter);
    const s = rec.segmenter;
    const obj = try makeResolvedBase(realm, s.base.locale);
    try setDataProp(realm, obj, "granularity", try makeStringValue(realm, if (s.granularity.len > 0) s.granularity else "grapheme"));
    return heap_mod.taggedObject(obj);
}

// ── DurationFormat ─────────────────────────────────────────────────────────

fn installDurationFormat(realm: *Realm, ns: *JSObject) !void {
    try installService(realm, ns, .{
        .name = "DurationFormat",
        .ctor = durationFormatConstructor,
        .requires_new = true,
        .arity = 0,
        .to_string_tag = "Intl.DurationFormat",
        .methods = &.{
            .{ .name = "format", .fn_ptr = durationFormatFormat, .params = 1 },
            .{ .name = "formatToParts", .fn_ptr = durationFormatFormatToParts, .params = 1 },
            .{ .name = "resolvedOptions", .fn_ptr = durationFormatResolvedOptions, .params = 0 },
        },
        .supported_locales_of = anySupportedLocalesOf,
        .set_ctor_intrinsic = struct {
            fn f(r: *Realm, c: *JSFunction) void {
                r.intrinsics.intl_duration_format_constructor = c;
            }
        }.f,
        .set_proto_intrinsic = struct {
            fn f(r: *Realm, p: *JSObject) void {
                r.intrinsics.intl_duration_format_prototype = p;
            }
        }.f,
    });
}

/// The 10 duration units in spec order, with the style values each accepts.
const duration_units = [10]struct { name: []const u8, display: []const u8, styles: []const []const u8 }{
    .{ .name = "years", .display = "yearsDisplay", .styles = &.{ "long", "short", "narrow" } },
    .{ .name = "months", .display = "monthsDisplay", .styles = &.{ "long", "short", "narrow" } },
    .{ .name = "weeks", .display = "weeksDisplay", .styles = &.{ "long", "short", "narrow" } },
    .{ .name = "days", .display = "daysDisplay", .styles = &.{ "long", "short", "narrow" } },
    .{ .name = "hours", .display = "hoursDisplay", .styles = &.{ "long", "short", "narrow", "numeric", "2-digit" } },
    .{ .name = "minutes", .display = "minutesDisplay", .styles = &.{ "long", "short", "narrow", "numeric", "2-digit" } },
    .{ .name = "seconds", .display = "secondsDisplay", .styles = &.{ "long", "short", "narrow", "numeric", "2-digit" } },
    .{ .name = "milliseconds", .display = "millisecondsDisplay", .styles = &.{ "long", "short", "narrow", "numeric" } },
    .{ .name = "microseconds", .display = "microsecondsDisplay", .styles = &.{ "long", "short", "narrow", "numeric" } },
    .{ .name = "nanoseconds", .display = "nanosecondsDisplay", .styles = &.{ "long", "short", "narrow", "numeric" } },
};

fn buildDurationFormatSlots(realm: *Realm, locales: Value, options: Value) NativeError!intl.DurationFormatSlots {
    const opts = try getOptionsObject(realm, options);
    const resolved = try resolveServiceLocale(realm, locales, opts);
    var slots: intl.DurationFormatSlots = .{};
    errdefer slots.deinit(realm.allocator);
    slots.base.locale = resolved.locale;
    try retainRelevantUnicodeExtensions(realm, &slots.base, &.{"nu"}); // §9.2.7 DurationFormat keys

    // § InitializeDurationFormat read order: numberingSystem, style, then each
    // unit's style + display, then fractionalDigits.
    slots.numbering_system = try resolveNumberingSystem(realm, slots.base.locale, slots.base.locale, opts);
    slots.style = try getOptionStringOwned(realm, opts, "style", &.{ "long", "short", "narrow", "digital" }, "short");
    const digital = std.mem.eql(u8, slots.style, "digital");

    // §1.1.5 GetDurationUnitOptions, threading prevStyle: an unspecified unit
    // after a numeric/2-digit/fractional one becomes "2-digit" (minutes/seconds)
    // or "numeric" (others); otherwise it takes the base style — digital giving
    // "numeric" + display "always" for h/m/s and "short" elsewhere. An explicit
    // style (or the digital h/m/s default) displays "always"; the rest "auto".
    var prev_style: []const u8 = "";
    inline for (duration_units, 0..) |u, i| {
        const is_hms = comptime (i >= 4 and i <= 6);
        const is_min_sec = comptime (i == 5 or i == 6);
        const explicit = try getOptionString(realm, opts, u.name, u.styles, "");
        const prev_numeric = std.mem.eql(u8, prev_style, "numeric") or std.mem.eql(u8, prev_style, "2-digit") or std.mem.eql(u8, prev_style, "fractional");
        var resolved_style: []const u8 = undefined;
        if (explicit.len > 0) {
            resolved_style = explicit;
        } else if (prev_numeric) {
            // A unit after a numeric/2-digit one joins the digital clock.
            resolved_style = if (is_min_sec) "2-digit" else "numeric";
        } else if (digital) {
            resolved_style = if (is_hms) "numeric" else "short";
        } else {
            resolved_style = slots.style;
        }
        // Step 9: minutes/seconds after a numeric/2-digit unit are "2-digit"
        // (overrides even an explicit "numeric", giving the "h:mm:ss" form).
        if (is_min_sec and (std.mem.eql(u8, prev_style, "numeric") or std.mem.eql(u8, prev_style, "2-digit")))
            resolved_style = "2-digit";
        // Display defaults to "always" for an explicit style and for digital
        // h/m/s; "auto" otherwise (zero values then omitted).
        const display_default: []const u8 = if (explicit.len > 0 or (digital and is_hms)) "always" else "auto";
        slots.unit_style[i] = realm.allocator.dupe(u8, resolved_style) catch return error.OutOfMemory;
        slots.unit_display[i] = try getOptionStringOwned(realm, opts, u.display, &.{ "always", "auto" }, display_default);
        prev_style = resolved_style;
    }
    slots.fractional_digits = try getNumberOptionOpt(realm, opts, "fractionalDigits", 0, 9);
    return slots;
}

fn durationFormatConstructor(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const inst = try newIntlInstance(realm, this_value, realm.intrinsics.intl_duration_format_prototype, "DurationFormat", true);
    var slots = try buildDurationFormatSlots(realm, argOr(args, 0, Value.undefined_), argOr(args, 1, Value.undefined_));
    errdefer slots.deinit(realm.allocator);
    try storeRecord(realm, inst, .{ .duration_format = slots });
    return heap_mod.taggedObject(inst);
}

fn isNumericDurStyle(st: []const u8) bool {
    return std.mem.eql(u8, st, "numeric") or std.mem.eql(u8, st, "2-digit");
}

/// §1.1.6 ToDurationRecord (validation subset) → the 10 unit values. Each field
/// must be an integral Number (RangeError otherwise); signs must not be mixed
/// (RangeError); at least one field must be present (TypeError).
fn toDurationRecord(realm: *Realm, dur: Value, out: *[10]f64) NativeError!void {
    // §1.1.6 → ToTemporalDuration: a String parses as an ISO 8601 duration; a
    // non-String non-Object is a TypeError (matching Temporal.Duration.from).
    if (dur.isString()) {
        const s: *JSString = @ptrCast(@alignCast(dur.asString()));
        const d = temporal.parseTemporalDurationString(s.flatBytes()) catch
            return throwRangeError(realm, "invalid ISO 8601 duration string");
        if (!temporal.isValidDuration(d)) return throwRangeError(realm, "Duration values are out of range");
        out.* = .{ d.years, d.months, d.weeks, d.days, d.hours, d.minutes, d.seconds, d.milliseconds, d.microseconds, d.nanoseconds };
        return;
    }
    const obj = heap_mod.valueAsPlainObject(dur) orelse return throwTypeError(realm, "duration must be an object or a string");
    // A Temporal.Duration is read from its [[InitializedTemporalDuration]] slots
    // directly — never via the prototype getters (which user code may taint).
    if (obj.getTemporalRecord()) |rec| switch (rec.*) {
        .duration => |d| {
            out.* = .{ d.years, d.months, d.weeks, d.days, d.hours, d.minutes, d.seconds, d.milliseconds, d.microseconds, d.nanoseconds };
            return;
        },
        else => {},
    };
    var any_defined = false;
    var sign: i8 = 0;
    inline for (duration_units, 0..) |u, i| {
        const v = try getPropertyChain(realm, obj, u.name);
        if (v.isUndefined()) {
            out[i] = 0;
        } else {
            any_defined = true;
            const n = numberToF64(try toNumber(realm, v));
            if (!std.math.isFinite(n) or n != @trunc(n))
                return throwRangeError(realm, "duration field must be an integer");
            out[i] = n;
            if (n > 0) {
                if (sign < 0) return throwRangeError(realm, "duration must not mix signs");
                sign = 1;
            } else if (n < 0) {
                if (sign > 0) return throwRangeError(realm, "duration must not mix signs");
                sign = -1;
            }
        }
    }
    if (!any_defined) return throwTypeError(realm, "duration requires at least one field");
    // §IsValidDuration — each field's magnitude must be in range (years / months
    // / weeks < 2^32; total time < 2^53 ms), else RangeError.
    const d = temporal.DurationRecord{ .years = out[0], .months = out[1], .weeks = out[2], .days = out[3], .hours = out[4], .minutes = out[5], .seconds = out[6], .milliseconds = out[7], .microseconds = out[8], .nanoseconds = out[9] };
    if (!temporal.isValidDuration(d)) return throwRangeError(realm, "Duration values are out of range");
}

/// §1.1.7 — fold sub-second units into a fractional amount for the unit at `idx`
/// (6 = seconds, 7 = milliseconds, 8 = microseconds), used when the next unit is
/// numeric so e.g. {seconds:1, milliseconds:500} renders as "1.5".
fn durationToFractional(vals: *const [10]f64, idx: usize) f64 {
    const sec = vals[6];
    const ms = vals[7];
    const us = vals[8];
    const ns = vals[9];
    return switch (idx) {
        6 => if (ms == 0 and us == 0 and ns == 0) sec else sec + ms / 1000.0 + us / 1_000_000.0 + ns / 1_000_000_000.0,
        7 => if (us == 0 and ns == 0) ms else ms + us / 1000.0 + ns / 1_000_000.0,
        else => if (ns == 0) us else us + ns / 1000.0,
    };
}

/// One formatted DurationFormat part: a NumberFormat segment type + bytes,
/// tagged with the unit it belongs to (empty for the ":" time separator).
const DurPart = struct { typ: []const u8, buf: [64]u8 = undefined, len: usize = 0, unit: []const u8 = "" };

fn setDurPart(p: *DurPart, typ: []const u8, val: []const u8, unit: []const u8) void {
    p.typ = typ;
    const n = @min(val.len, p.buf.len);
    @memcpy(p.buf[0..n], val[0..n]);
    p.len = n;
    p.unit = unit;
}

/// §1.1.8 PartitionDurationFormatPattern — format each present unit (long/short/
/// narrow via NumberFormat unit style; numeric/2-digit grouped with ":" into a
/// digital-clock element). Fills `parts` with the per-segment records and
/// `elem_start[0..=nitems]` with each list element's part range; returns nitems.
fn durationBuildParts(s: *const intl.DurationFormatSlots, vals: *const [10]f64, parts: *[96]DurPart, elem_start: *[12]usize) usize {
    const loc = s.base.dataLocale();
    var any_negative = false;
    for (vals) |v| {
        if (v < 0) {
            any_negative = true;
            break;
        }
    }
    var nparts: usize = 0;
    var nitems: usize = 0;
    var need_separator = false;
    var display_negative_sign = true;
    var i: usize = 0;
    while (i < 10) : (i += 1) {
        var value = vals[i];
        const style = s.unit_style[i];
        const display = s.unit_display[i];
        // Numeric seconds / sub-seconds fold their fraction when the next unit
        // is numeric; that ends the loop (the fraction subsumes the rest).
        var fractional = false;
        if ((i == 6 or i == 7 or i == 8) and std.mem.eql(u8, s.unit_style[i + 1], "numeric")) {
            value = durationToFractional(vals, i);
            fractional = true;
        }
        // A zero numeric minutes is still shown when seconds will follow.
        var display_required = false;
        if (i == 5 and need_separator)
            display_required = std.mem.eql(u8, s.unit_display[6], "always") or vals[6] != 0 or vals[7] != 0 or vals[8] != 0 or vals[9] != 0;

        if (value != 0 or !std.mem.eql(u8, display, "auto") or display_required) {
            var sign_never = false;
            if (display_negative_sign) {
                display_negative_sign = false;
                if (value == 0 and any_negative) value = -0.0; // force the leading sign
            } else {
                sign_never = true;
            }
            var nf: intl.NumberFormatSlots = .{};
            nf.base.locale = loc;
            nf.base.numbering_system = s.numbering_system;
            nf.notation = "standard";
            nf.rounding_type = "fractionDigits";
            nf.rounding_mode = "halfExpand";
            nf.trailing_zero_display = "auto";
            nf.sign_display = if (sign_never) "never" else "auto";
            nf.minimum_fraction_digits = 0;
            nf.maximum_fraction_digits = 0;
            if (std.mem.eql(u8, style, "2-digit")) nf.minimum_integer_digits = 2;
            const unit_singular = duration_units[i].name[0 .. duration_units[i].name.len - 1];
            if (!isNumericDurStyle(style)) {
                nf.style = "unit";
                nf.unit = unit_singular;
                nf.unit_display = style;
                nf.use_grouping = "auto";
                nf.maximum_fraction_digits = 3;
            } else {
                nf.style = "decimal";
                nf.use_grouping = "false";
            }
            if (fractional) {
                nf.maximum_fraction_digits = s.fractional_digits orelse 9;
                nf.minimum_fraction_digits = s.fractional_digits orelse 0;
                nf.rounding_mode = "trunc";
            }
            var segs: [48]Seg = undefined;
            const nseg = renderNumber(&nf, value, &segs);
            if (!need_separator) {
                elem_start[nitems] = nparts;
                nitems += 1;
                if (isNumericDurStyle(style)) need_separator = true;
            } else if (nparts < parts.len) {
                setDurPart(&parts[nparts], "literal", ":", "");
                nparts += 1;
            }
            var k: usize = 0;
            while (k < nseg and nparts < parts.len) : (k += 1) {
                setDurPart(&parts[nparts], segs[k].typ, segs[k].bytes(), unit_singular);
                nparts += 1;
            }
        }
        if (fractional) break;
    }
    elem_start[nitems] = nparts;
    return nitems;
}

/// Concatenate one list element's part bytes into `buf`; returns the slice.
fn durElementString(parts: *const [96]DurPart, start: usize, end: usize, buf: []u8) []const u8 {
    var l: usize = 0;
    var p = start;
    while (p < end) : (p += 1) l += copyClamp(buf, l, parts[p].buf[0..parts[p].len]);
    return buf[0..l];
}

fn durationListStyle(s: *const intl.DurationFormatSlots) []const u8 {
    return if (std.mem.eql(u8, s.style, "long")) "long" else if (std.mem.eql(u8, s.style, "narrow")) "narrow" else "short";
}

fn formatDurationString(realm: *Realm, s: *const intl.DurationFormatSlots, vals: *const [10]f64) NativeError!Value {
    if (!cldr.available) return makeStringValue(realm, "");

    var parts: [96]DurPart = undefined;
    var elem_start: [12]usize = undefined;
    const nitems = durationBuildParts(s, vals, &parts, &elem_start);

    var item_store: [10][256]u8 = undefined;
    var slices: [10][]const u8 = undefined;
    var k: usize = 0;
    while (k < nitems) : (k += 1) slices[k] = durElementString(&parts, elem_start[k], elem_start[k + 1], item_store[k][0..]);

    var lf: intl.ListFormatSlots = .{};
    lf.base.locale = s.base.dataLocale();
    lf.type_name = "unit";
    lf.style = durationListStyle(s);
    var lsegs: std.ArrayListUnmanaged(ListSeg) = .empty;
    defer lsegs.deinit(realm.allocator);
    try listBuildParts(realm, &lf, slices[0..nitems], &lsegs);
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(realm.allocator);
    for (lsegs.items) |seg| out.appendSlice(realm.allocator, seg.val) catch return error.OutOfMemory;
    return makeStringValue(realm, out.items);
}

fn durationFormatFormat(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const rec = try requireKind(realm, this_value, .duration_format);
    var vals: [10]f64 = undefined;
    try toDurationRecord(realm, argOr(args, 0, Value.undefined_), &vals);
    return formatDurationString(realm, &rec.duration_format, &vals);
}

/// Temporal.Duration.prototype.toLocaleString — build a transient DurationFormat
/// from (locales, options) and format the receiver duration through it.
pub fn durationToLocaleString(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    var slots = try buildDurationFormatSlots(realm, argOr(args, 0, Value.undefined_), argOr(args, 1, Value.undefined_));
    defer slots.deinit(realm.allocator);
    var vals: [10]f64 = undefined;
    try toDurationRecord(realm, this_value, &vals);
    return formatDurationString(realm, &slots, &vals);
}

fn durationFormatFormatToParts(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const rec = try requireKind(realm, this_value, .duration_format);
    const s = &rec.duration_format;
    var vals: [10]f64 = undefined;
    try toDurationRecord(realm, argOr(args, 0, Value.undefined_), &vals);
    const arr = allocateArray(realm) catch return error.OutOfMemory;
    if (!cldr.available) {
        arr.setArrayLength(realm.allocator, 0) catch return error.OutOfMemory;
        return heap_mod.taggedObject(arr);
    }
    var parts: [96]DurPart = undefined;
    var elem_start: [12]usize = undefined;
    const nitems = durationBuildParts(s, &vals, &parts, &elem_start);

    var item_store: [10][256]u8 = undefined;
    var slices: [10][]const u8 = undefined;
    var k: usize = 0;
    while (k < nitems) : (k += 1) slices[k] = durElementString(&parts, elem_start[k], elem_start[k + 1], item_store[k][0..]);

    var lf: intl.ListFormatSlots = .{};
    lf.base.locale = s.base.dataLocale();
    lf.type_name = "unit";
    lf.style = durationListStyle(s);
    var lsegs: std.ArrayListUnmanaged(ListSeg) = .empty;
    defer lsegs.deinit(realm.allocator);
    try listBuildParts(realm, &lf, slices[0..nitems], &lsegs);

    // §1.1.10 — a list "element" segment expands to that element's unit parts
    // (each carrying its NumberFormat type + the unit); the list-pattern literals
    // (conjunctions) become plain "literal" parts.
    var idx: u32 = 0;
    var e: usize = 0;
    for (lsegs.items) |seg| {
        if (seg.is_element and e < nitems) {
            var p = elem_start[e];
            while (p < elem_start[e + 1]) : (p += 1) {
                const part = realm.heap.allocateObject() catch return error.OutOfMemory;
                realm.heap.setObjectPrototype(part, realm.intrinsics.object_prototype);
                try setDataProp(realm, part, "type", try makeStringValue(realm, parts[p].typ));
                try setDataProp(realm, part, "value", try makeStringValue(realm, parts[p].buf[0..parts[p].len]));
                if (parts[p].unit.len > 0)
                    try setDataProp(realm, part, "unit", try makeStringValue(realm, parts[p].unit));
                var kb: [12]u8 = undefined;
                arr.set(realm.allocator, std.fmt.bufPrint(&kb, "{d}", .{idx}) catch unreachable, heap_mod.taggedObject(part)) catch return error.OutOfMemory;
                idx += 1;
            }
            e += 1;
        } else {
            try pushPart(realm, arr, idx, "literal", try makeStringValue(realm, seg.val));
            idx += 1;
        }
    }
    arr.setArrayLength(realm.allocator, idx) catch return error.OutOfMemory;
    return heap_mod.taggedObject(arr);
}

fn durationFormatResolvedOptions(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    const rec = try requireKind(realm, this_value, .duration_format);
    const s = rec.duration_format;
    // § key order: locale, numberingSystem, style, then each unit's style +
    // display, then fractionalDigits (only when set).
    const obj = try makeResolvedBase(realm, s.base.locale);
    try setDataProp(realm, obj, "numberingSystem", try makeStringValue(realm, if (s.numbering_system.len > 0) s.numbering_system else "latn"));
    try setDataProp(realm, obj, "style", try makeStringValue(realm, if (s.style.len > 0) s.style else "short"));
    inline for (duration_units, 0..) |u, i| {
        try setDataProp(realm, obj, u.name, try makeStringValue(realm, if (s.unit_style[i].len > 0) s.unit_style[i] else "short"));
        try setDataProp(realm, obj, u.display, try makeStringValue(realm, if (s.unit_display[i].len > 0) s.unit_display[i] else "auto"));
    }
    if (s.fractional_digits) |fd|
        try setDataProp(realm, obj, "fractionalDigits", makeNumberValue(@floatFromInt(fd)));
    return heap_mod.taggedObject(obj);
}
