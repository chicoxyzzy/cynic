//! Structural Intl — unit + realm integration tests (AGENTS.md tests-first
//! discipline for the ECMA-402 slice). Covers tag algorithms in `intl.zig`
//! and observable `Intl` / constructor behaviour via `installBuiltins`.
//!
//! Requires `-Dintl=stub` or `-Dintl=full` (default build is `-Dintl=off`
//! and skips this file's tests via `SkipZigTest`).
//!
//! Integration tests compare results *inside* the realm (before `deinit`)
//! so heap-backed `JSString` values are not read after GC/teardown.

const std = @import("std");
const testing = std.testing;

const Realm = @import("realm.zig").Realm;
const lantern = @import("lantern/interpreter.zig");
const intl = @import("intl.zig");
const intl_config = @import("intl_config.zig");
const cldr = @import("cldr.zig");

fn requireIntlBuild() !void {
    if (!intl_config.enabled) return error.SkipZigTest;
}

/// CLDR-backed behaviour (real plural selection, locale data) needs the
/// embedded blob — `-Dintl=full` only. stub/off skip these.
fn requireFullBuild() !void {
    if (!intl_config.has_locale_data) return error.SkipZigTest;
}

/// Evaluate `source`; return true when completion is a throw.
/// Requires `-Dintl=stub|full` (realm has `Intl` only in those tiers).
fn evalThrows(source: []const u8) !void {
    try requireIntlBuild();
    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    try realm.installBuiltins();
    const outcome = try lantern.evaluateScript(testing.allocator, &realm, source);
    switch (outcome) {
        .thrown => {},
        .value, .yielded => return error.TestUnexpectedResult,
    }
}

/// Evaluate `source` that must complete with a Number (int32) used as
/// an assertion code: 1 = pass, anything else = fail.
/// Requires `-Dintl=stub|full`.
fn evalAssert1(source: []const u8) !void {
    try requireIntlBuild();
    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    try realm.installBuiltins();
    const outcome = try lantern.evaluateScript(testing.allocator, &realm, source);
    const v = switch (outcome) {
        .value => |val| val,
        .thrown => return error.TestUnexpectedResult,
        .yielded => return error.TestUnexpectedResult,
    };
    if (!v.isInt32() or v.asInt32() != 1) return error.TestUnexpectedResult;
}

/// Realm eval helpers that do **not** require Intl (for `-Dintl=off` checks).
fn evalThrowsAnyTier(source: []const u8) !void {
    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    try realm.installBuiltins();
    const outcome = try lantern.evaluateScript(testing.allocator, &realm, source);
    switch (outcome) {
        .thrown => {},
        .value, .yielded => return error.TestUnexpectedResult,
    }
}

fn evalAssert1AnyTier(source: []const u8) !void {
    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    try realm.installBuiltins();
    const outcome = try lantern.evaluateScript(testing.allocator, &realm, source);
    const v = switch (outcome) {
        .value => |val| val,
        .thrown => return error.TestUnexpectedResult,
        .yielded => return error.TestUnexpectedResult,
    };
    if (!v.isInt32() or v.asInt32() != 1) return error.TestUnexpectedResult;
}

// ── Tag algorithms (runtime/intl.zig) ──────────────────────────────────────

test "intl: isStructurallyValidLanguageTag accepts and rejects core shapes" {
    try requireIntlBuild();
    try testing.expect(intl.isStructurallyValidLanguageTag("en"));
    try testing.expect(intl.isStructurallyValidLanguageTag("en-US"));
    try testing.expect(intl.isStructurallyValidLanguageTag("zh-Hant-TW"));
    try testing.expect(intl.isStructurallyValidLanguageTag("en-u-ca-gregory"));
    try testing.expect(intl.isStructurallyValidLanguageTag("de-DE-u-co-phonebk"));
    try testing.expect(!intl.isStructurallyValidLanguageTag(""));
    try testing.expect(!intl.isStructurallyValidLanguageTag("en_US"));
    try testing.expect(!intl.isStructurallyValidLanguageTag("-en"));
    try testing.expect(!intl.isStructurallyValidLanguageTag("en-"));
    try testing.expect(!intl.isStructurallyValidLanguageTag("e"));
}

test "intl: canonicalizeUnicodeLocaleId normalizes language/region case" {
    try requireIntlBuild();
    const a = try intl.canonicalizeUnicodeLocaleId(testing.allocator, "EN-us");
    defer testing.allocator.free(a);
    try testing.expectEqualStrings("en-US", a);

    const b = try intl.canonicalizeUnicodeLocaleId(testing.allocator, "en");
    defer testing.allocator.free(b);
    try testing.expectEqualStrings("en", b);
}

test "intl: defaultLocale is en" {
    try requireIntlBuild();
    try testing.expectEqualStrings("en", intl.defaultLocale());
}

// ── Temporal + Intl structural seam (calendars / IANA zones) ───────────────

test "intl/temporal: supported calendar ids canonicalise" {
    try requireIntlBuild();
    const temporal = @import("temporal.zig");
    try testing.expectEqualStrings("islamic-civil", temporal.canonicalizeCalendarId("islamicc").?);
    try testing.expectEqualStrings("ethioaa", temporal.canonicalizeCalendarId("ethiopic-amete-alem").?);
    try testing.expectEqualStrings("gregory", temporal.canonicalizeCalendarId("GREGORY").?);
    try testing.expect(temporal.canonicalizeCalendarId("notexist") == null);
}

test "intl/temporal: realm accepts gregory calendar and IANA zone structurally" {
    try requireIntlBuild();
    // Use an epoch firmly in 1970-01 UTC so local fields stay in 1970 even
    // when `-Dintl=full` applies a real America/New_York offset (EST = UTC-5
    // would push epoch 0 into 1969-12-31 local).
    try evalAssert1(
        \\const d = new Temporal.PlainDate(2024, 7, 2, "islamicc");
        \\if (d.calendarId !== "islamic-civil") throw 0;
        \\const z = new Temporal.ZonedDateTime(86400000000000n, "America/New_York", "gregory");
        \\if (z.calendarId !== "gregory") throw 0;
        \\if (z.timeZoneId !== "America/New_York") throw 0;
        \\if (z.era !== "ce") throw 0;
        \\if (z.eraYear !== 1970) throw 0;
        \\1
    );
}

test "intl off: Temporal rejects non-ISO calendar and named IANA" {
    if (intl_config.enabled) return error.SkipZigTest;
    try evalThrowsAnyTier(
        \\new Temporal.PlainDate(2024, 7, 2, "gregory")
    );
    try evalThrowsAnyTier(
        \\new Temporal.ZonedDateTime(0n, "America/New_York")
    );
    try evalAssert1AnyTier(
        \\typeof Intl === "undefined" ? 1 : 0
    );
}

test "intl: lookupMatcher falls back to default when list empty" {
    try requireIntlBuild();
    try testing.expectEqualStrings("en", intl.lookupMatcher(&.{}));
}

test "intl: lookupMatcher picks first structurally valid requested locale" {
    try requireIntlBuild();
    try testing.expectEqualStrings("fr", intl.lookupMatcher(&.{ "fr", "de" }));
}

test "intl: parseLocaleComponents splits language and region" {
    try requireIntlBuild();
    var slots = try intl.parseLocaleComponents(testing.allocator, "en-US");
    defer slots.deinit(testing.allocator);
    try testing.expectEqualStrings("en", slots.language);
    try testing.expectEqualStrings("US", slots.region);
    try testing.expectEqualStrings("en-US", slots.base_name);
}

test "intl: unicodeExtensionValue reads u- keywords" {
    try requireIntlBuild();
    const v = intl.unicodeExtensionValue("en-u-ca-gregory-nu-latn", "ca");
    try testing.expect(v != null);
    try testing.expectEqualStrings("gregory", v.?);
}

test "intl full: ZonedDateTime America/New_York applies DST offset" {
    if (!intl_config.has_locale_data) return error.SkipZigTest;
    // 2024-01-01T00:00Z in New York is EST (UTC-5) → local 2023-12-31T19:00
    try evalAssert1(
        \\const z = new Temporal.ZonedDateTime(1704067200000000000n, "America/New_York");
        \\const s = z.toString();
        \\(s.includes("2023-12-31T19:00") && s.includes("-05:00")) ? 1 : 0
    );
}

test "intl full: rejects unknown IANA name even if structurally valid" {
    if (!intl_config.has_locale_data) return error.SkipZigTest;
    try evalThrows(
        \\new Temporal.ZonedDateTime(0n, "Not/ARealZone")
    );
}

test "intl stub: structurally accepts unknown IANA (UTC math)" {
    try requireIntlBuild();
    if (intl_config.has_locale_data) return error.SkipZigTest;
    try evalAssert1(
        \\const z = new Temporal.ZonedDateTime(0n, "Not/ARealZone");
        \\z.timeZoneId === "Not/ARealZone" ? 1 : 0
    );
}

// ── Realm integration (builtins/intl.zig) ──────────────────────────────────

test "intl: global Intl exists with toStringTag" {
    try evalAssert1(
        \\Object.prototype.toString.call(Intl) === "[object Intl]" ? 1 : 0
    );
}

test "intl: getCanonicalLocales normalizes and dedupes" {
    try evalAssert1(
        \\Intl.getCanonicalLocales(["EN-us", "en-US"]).join(",") === "en-US" ? 1 : 0
    );
}

test "intl: getCanonicalLocales rejects invalid tags" {
    try evalThrows(
        \\Intl.getCanonicalLocales(["en_US"])
    );
}

test "intl: supportedValuesOf calendar returns non-empty array" {
    try evalAssert1(
        \\Intl.supportedValuesOf("calendar").length > 0 ? 1 : 0
    );
}

test "intl: supportedValuesOf rejects unknown key" {
    try evalThrows(
        \\Intl.supportedValuesOf("not-a-key")
    );
}

test "intl: Locale constructor and getters" {
    try evalAssert1(
        \\const l = new Intl.Locale("en-US");
        \\(l.language === "en" && l.region === "US" && l.toString() === "en-US") ? 1 : 0
    );
}

test "intl: Locale brand check rejects non-Locale receivers" {
    try evalThrows(
        \\Intl.Locale.prototype.toString.call({})
    );
}

// §14.1.1 InitializeLocale + §14.1.3 ApplyUnicodeExtensionToTag —
// options must be drawn from the enumerated set or match the type
// grammar. Empty strings and out-of-range enum values throw RangeError.
test "intl: Locale rejects empty hourCycle" {
    try evalThrows(
        \\new Intl.Locale("en", { hourCycle: "" })
    );
}

test "intl: Locale rejects invalid hourCycle enum" {
    try evalThrows(
        \\new Intl.Locale("en", { hourCycle: "h00" })
    );
}

test "intl: Locale rejects empty caseFirst" {
    try evalThrows(
        \\new Intl.Locale("en", { caseFirst: "" })
    );
}

test "intl: Locale rejects empty calendar" {
    try evalThrows(
        \\new Intl.Locale("en", { calendar: "" })
    );
}

test "intl: Locale rejects empty collation" {
    try evalThrows(
        \\new Intl.Locale("en", { collation: "" })
    );
}

test "intl: Locale rejects empty numberingSystem" {
    try evalThrows(
        \\new Intl.Locale("en", { numberingSystem: "" })
    );
}

test "intl: Locale rejects empty language" {
    try evalThrows(
        \\new Intl.Locale("en", { language: "" })
    );
}

test "intl: Locale rejects empty script" {
    try evalThrows(
        \\new Intl.Locale("en", { script: "" })
    );
}

test "intl: Locale rejects empty region" {
    try evalThrows(
        \\new Intl.Locale("en", { region: "" })
    );
}

test "intl: Collator compare is ordinal and resolvedOptions has locale" {
    try evalAssert1(
        \\const c = new Intl.Collator("en");
        \\const ro = c.resolvedOptions();
        \\(c.compare("a", "b") < 0 && typeof ro.locale === "string") ? 1 : 0
    );
}

test "intl: PluralRules select — structural at stub, CLDR-backed at full" {
    try requireIntlBuild();
    // Without locale data (stub) every value is "other"; with the embedded
    // CLDR blob (full) en.select(1) resolves to the real "one" category.
    if (intl_config.has_locale_data) {
        try evalAssert1(
            \\new Intl.PluralRules("en").select(1) === "one" ? 1 : 0
        );
    } else {
        try evalAssert1(
            \\new Intl.PluralRules("en").select(1) === "other" ? 1 : 0
        );
    }
}

test "intl: NumberFormat format falls back to ToString number" {
    try evalAssert1(
        \\new Intl.NumberFormat("en").format(42) === "42" ? 1 : 0
    );
}

test "intl: DateTimeFormat resolvedOptions exposes timeZone" {
    try evalAssert1(
        \\new Intl.DateTimeFormat("en").resolvedOptions().timeZone === "UTC" ? 1 : 0
    );
}

test "intl: DisplayNames of — CLDR name at full, code fallback at stub" {
    try requireIntlBuild();
    // Without CLDR data (stub) `of` falls back to the canonicalised code; with
    // the embedded blob (full) it resolves the real localized name.
    if (intl_config.has_locale_data) {
        try evalAssert1(
            \\new Intl.DisplayNames("en", { type: "language" }).of("fr") === "French" ? 1 : 0
        );
    } else {
        try evalAssert1(
            \\new Intl.DisplayNames("en", { type: "language" }).of("fr") === "fr" ? 1 : 0
        );
    }
}

test "intl: DisplayNames requires options.type" {
    try evalThrows(
        \\new Intl.DisplayNames("en")
    );
}

test "intl: Segmenter segment returns an object" {
    try evalAssert1(
        \\typeof new Intl.Segmenter("en").segment("hello") === "object" ? 1 : 0
    );
}

test "intl: supportedLocalesOf exists on constructors" {
    try evalAssert1(
        \\(Intl.Collator.supportedLocalesOf(["en"]).length === 1
        \\  && Intl.NumberFormat.supportedLocalesOf(["de"]).length === 1
        \\  && Intl.PluralRules.supportedLocalesOf(["fr"]).length === 1) ? 1 : 0
    );
}

test "intl: RelativeTimeFormat and ListFormat construct" {
    try evalAssert1(
        \\(new Intl.RelativeTimeFormat("en").format(1, "day").length > 0
        \\  && new Intl.ListFormat("en").format(["a", "b"]).indexOf("a") >= 0) ? 1 : 0
    );
}

test "intl: DurationFormat constructs with style option" {
    try evalAssert1(
        \\new Intl.DurationFormat("en", { style: "short" }).resolvedOptions().style === "short" ? 1 : 0
    );
}

test "intl: incompatible receiver throws on prototype methods" {
    try evalThrows(
        \\Intl.Collator.prototype.compare.call({}, "a", "b")
    );
    try evalThrows(
        \\Intl.PluralRules.prototype.select.call({}, 1)
    );
}

test "intl: supportedValuesOf currencies loop does not abort" {
    // Regression for SIGABRT in intl402 supportedValuesOf/*-accepted-by-* fixtures:
    // iterating the full currency catalog must not crash the host.
    try evalAssert1(
        \\const cs = Intl.supportedValuesOf("currency");
        \\let ok = 1;
        \\for (const c of cs) {
        \\  try {
        \\    new Intl.NumberFormat("en", { style: "currency", currency: c }).format(1);
        \\  } catch (e) { ok = 0; break; }
        \\}
        \\ok
    );
}

test "intl: supportedValuesOf units loop does not abort" {
    try evalAssert1(
        \\const us = Intl.supportedValuesOf("unit");
        \\let ok = 1;
        \\for (const u of us) {
        \\  try {
        \\    new Intl.NumberFormat("en", { style: "unit", unit: u }).format(1);
        \\  } catch (e) { ok = 0; break; }
        \\}
        \\ok
    );
}

// ── PluralRules (CLDR plural engine — §16) ───────────────────────────────────

test "cldr.computeOperands: integer 1 → i=1 v=0" {
    const o = cldr.computeOperands(1, 0, 3);
    try testing.expectEqual(@as(u64, 1), o.i);
    try testing.expectEqual(@as(u32, 0), o.v);
    try testing.expectEqual(@as(u32, 0), o.w);
}

test "cldr.computeOperands: 1.5 → i=1 v=1 f=5 t=5 n=1.5" {
    const o = cldr.computeOperands(1.5, 0, 3);
    try testing.expectEqual(@as(u64, 1), o.i);
    try testing.expectEqual(@as(u32, 1), o.v);
    try testing.expectEqual(@as(u64, 5), o.f);
    try testing.expectEqual(@as(u64, 5), o.t);
    try testing.expectEqual(@as(f64, 1.5), o.n);
}

test "cldr.computeOperands: minimumFractionDigits pads trailing zeros (1 → 1.00)" {
    const o = cldr.computeOperands(1, 2, 3);
    try testing.expectEqual(@as(u32, 2), o.v); // with trailing zeros
    try testing.expectEqual(@as(u32, 0), o.w); // without
    try testing.expectEqual(@as(u64, 0), o.f);
}

test "Intl.PluralRules: en cardinal select" {
    try requireFullBuild();
    try evalAssert1(
        \\const pr = new Intl.PluralRules('en');
        \\(pr.select(0)==='other' && pr.select(1)==='one' && pr.select(2)==='other' && pr.select(1.5)==='other') ? 1 : 0
    );
}

test "Intl.PluralRules: en ordinal select (th/st/nd/rd)" {
    try requireFullBuild();
    try evalAssert1(
        \\const pr = new Intl.PluralRules('en', {type:'ordinal'});
        \\(pr.select(1)==='one' && pr.select(2)==='two' && pr.select(3)==='few' &&
        \\ pr.select(4)==='other' && pr.select(11)==='other' && pr.select(21)==='one') ? 1 : 0
    );
}

test "Intl.PluralRules: pl cardinal few/many" {
    try requireFullBuild();
    try evalAssert1(
        \\const pr = new Intl.PluralRules('pl');
        \\(pr.select(1)==='one' && pr.select(2)==='few' && pr.select(5)==='many' && pr.select(22)==='few') ? 1 : 0
    );
}

test "Intl.PluralRules: ar exercises all six categories" {
    try requireFullBuild();
    try evalAssert1(
        \\const pr = new Intl.PluralRules('ar');
        \\(pr.select(0)==='zero' && pr.select(1)==='one' && pr.select(2)==='two' &&
        \\ pr.select(3)==='few' && pr.select(11)==='many' && pr.select(100)==='other') ? 1 : 0
    );
}

test "Intl.PluralRules: resolvedOptions.pluralCategories (pl, canonical order)" {
    try requireFullBuild();
    try evalAssert1(
        \\const c = new Intl.PluralRules('pl').resolvedOptions().pluralCategories;
        \\(c.length===4 && c[0]==='one' && c[1]==='few' && c[2]==='many' && c[3]==='other') ? 1 : 0
    );
}

test "Intl.PluralRules: locale fallback en-US → en rules" {
    try requireFullBuild();
    try evalAssert1(
        \\const pr = new Intl.PluralRules('en-US');
        \\(pr.select(1)==='one' && pr.select(2)==='other') ? 1 : 0
    );
}

test "Intl.PluralRules: selectRange NaN endpoint throws RangeError" {
    try requireFullBuild();
    try evalThrows("new Intl.PluralRules('en').selectRange(NaN, 1)");
}

test "Intl.PluralRules: selectRange missing end throws TypeError" {
    try requireFullBuild();
    try evalThrows("new Intl.PluralRules('en').selectRange(1)");
}

// ── NumberFormat (CLDR symbols + patterns — §15) ─────────────────────────────

test "Intl.NumberFormat: en grouping + fraction" {
    try requireFullBuild();
    try evalAssert1(
        \\const f = new Intl.NumberFormat('en');
        \\(f.format(1234567.891)==='1,234,567.891' && f.format(-1234.5)==='-1,234.5') ? 1 : 0
    );
}

test "Intl.NumberFormat: de and fr separators" {
    try requireFullBuild();
    // fr's group separator is a narrow no-break space (U+202F), not ASCII space,
    // so assert structure (comma decimal, no dot) rather than the exact glyph.
    try evalAssert1(
        \\const de = new Intl.NumberFormat('de').format(1234567.89);
        \\const fr = new Intl.NumberFormat('fr').format(1234567.89);
        \\(de==='1.234.567,89' && fr.endsWith(',89') && fr.startsWith('1') && !fr.includes('.')) ? 1 : 0
    );
}

test "Intl.NumberFormat: percent style scales and suffixes" {
    try requireFullBuild();
    try evalAssert1(
        \\new Intl.NumberFormat('en', {style:'percent'}).format(0.4567)==='46%' ? 1 : 0
    );
}

test "Intl.NumberFormat: fraction-digit options" {
    try requireFullBuild();
    try evalAssert1(
        \\const a = new Intl.NumberFormat('en',{maximumFractionDigits:2}).format(3.14159);
        \\const b = new Intl.NumberFormat('en',{minimumFractionDigits:2}).format(5);
        \\(a==='3.14' && b==='5.00') ? 1 : 0
    );
}

test "Intl.NumberFormat: Indian grouping (hi)" {
    try requireFullBuild();
    try evalAssert1(
        \\new Intl.NumberFormat('hi',{maximumFractionDigits:0}).format(1234567)==='12,34,567' ? 1 : 0
    );
}

test "Intl.NumberFormat: numbering-system digit substitution (arab)" {
    try requireFullBuild();
    try evalAssert1(
        \\new Intl.NumberFormat('ar',{numberingSystem:'arab'}).format(1234.5)==='١,٢٣٤.٥' ? 1 : 0
    );
}

test "Intl.NumberFormat: useGrouping false and signDisplay always" {
    try requireFullBuild();
    try evalAssert1(
        \\const g = new Intl.NumberFormat('en',{useGrouping:false}).format(12345);
        \\const s = new Intl.NumberFormat('en',{signDisplay:'always'}).format(5);
        \\(g==='12345' && s==='+5') ? 1 : 0
    );
}

test "Intl.NumberFormat: formatToParts segments" {
    try requireFullBuild();
    try evalAssert1(
        \\const p = new Intl.NumberFormat('en').formatToParts(1234.5);
        \\(p[0].type==='integer'&&p[0].value==='1'&&p[1].type==='group'&&p[2].type==='integer'&&
        \\ p[3].type==='decimal'&&p[4].type==='fraction'&&p[4].value==='5') ? 1 : 0
    );
}

test "Intl.NumberFormat: significant digits" {
    try requireFullBuild();
    try evalAssert1(
        \\new Intl.NumberFormat('en',{maximumSignificantDigits:3}).format(1234.5)==='1,230' ? 1 : 0
    );
}

test "Intl.NumberFormat: format(0) with significant digits does not crash (host-safety)" {
    try requireFullBuild();
    // dtoa.precisionDigits asserts x > 0; formatting zero must take the guarded path.
    try evalAssert1(
        \\(new Intl.NumberFormat('en',{minimumSignificantDigits:3}).format(0)==='0.00') ? 1 : 0
    );
}

test "Intl.NumberFormat: resolvedOptions reports resolved digits + numberingSystem" {
    try requireFullBuild();
    try evalAssert1(
        \\const r = new Intl.NumberFormat('en',{minimumFractionDigits:2}).resolvedOptions();
        \\(r.numberingSystem==='latn' && r.minimumFractionDigits===2 && r.maximumFractionDigits===3 &&
        \\ r.roundingMode==='halfExpand' && r.useGrouping==='auto') ? 1 : 0
    );
}

// ── DateTimeFormat (CLDR gregorian names + patterns — §11) ───────────────────

test "Intl.DateTimeFormat: en default is numeric m/d/y" {
    try requireFullBuild();
    try evalAssert1(
        \\const d = Date.UTC(2024, 0, 2, 15, 4, 5);
        \\new Intl.DateTimeFormat('en').format(d)==='1/2/2024' ? 1 : 0
    );
}

test "Intl.DateTimeFormat: en dateStyle full/long/medium" {
    try requireFullBuild();
    try evalAssert1(
        \\const d = Date.UTC(2024, 0, 2, 15, 4, 5);
        \\(new Intl.DateTimeFormat('en',{dateStyle:'full'}).format(d)==='Tuesday, January 2, 2024' &&
        \\ new Intl.DateTimeFormat('en',{dateStyle:'long'}).format(d)==='January 2, 2024' &&
        \\ new Intl.DateTimeFormat('en',{dateStyle:'medium'}).format(d)==='Jan 2, 2024') ? 1 : 0
    );
}

test "Intl.DateTimeFormat: de and ja localized names + order" {
    try requireFullBuild();
    try evalAssert1(
        \\const d = Date.UTC(2024, 0, 2, 15, 4, 5);
        \\(new Intl.DateTimeFormat('de',{dateStyle:'full'}).format(d)==='Dienstag, 2. Januar 2024' &&
        \\ new Intl.DateTimeFormat('ja',{dateStyle:'full'}).format(d)==='2024年1月2日火曜日') ? 1 : 0
    );
}

test "Intl.DateTimeFormat: timeStyle + hourCycle h23" {
    try requireFullBuild();
    try evalAssert1(
        \\const d = Date.UTC(2024, 0, 2, 15, 4, 5);
        \\(new Intl.DateTimeFormat('en',{timeStyle:'medium'}).format(d).startsWith('3:04:05') &&
        \\ new Intl.DateTimeFormat('en',{hour:'2-digit',minute:'2-digit',hourCycle:'h23'}).format(d)==='15:04') ? 1 : 0
    );
}

test "Intl.DateTimeFormat: component options (weekday + long month)" {
    try requireFullBuild();
    try evalAssert1(
        \\const d = Date.UTC(2024, 0, 2, 15, 4, 5);
        \\new Intl.DateTimeFormat('en',{weekday:'long',year:'numeric',month:'long',day:'numeric'}).format(d)==='Tuesday, January 2, 2024' ? 1 : 0
    );
}

test "Intl.DateTimeFormat: formatToParts typed segments" {
    try requireFullBuild();
    try evalAssert1(
        \\const p = new Intl.DateTimeFormat('en',{dateStyle:'medium'}).formatToParts(Date.UTC(2024,0,2));
        \\(p[0].type==='month' && p[0].value==='Jan' && p.some(x=>x.type==='day'&&x.value==='2') && p.some(x=>x.type==='year'&&x.value==='2024')) ? 1 : 0
    );
}

test "Intl.DateTimeFormat: resolvedOptions reports calendar/timeZone/numberingSystem" {
    try requireFullBuild();
    try evalAssert1(
        \\const r = new Intl.DateTimeFormat('en',{dateStyle:'full'}).resolvedOptions();
        \\(r.calendar==='iso8601' && r.timeZone==='UTC' && r.numberingSystem==='latn' && r.dateStyle==='full') ? 1 : 0
    );
}

test "Intl.DateTimeFormat: invalid time value throws RangeError (host-safety)" {
    try requireFullBuild();
    // |ms| > 8.64e15 is outside the Date range — must be a catchable RangeError,
    // never a trap in the civil-from-days breakdown.
    try evalThrows("new Intl.DateTimeFormat('en').format(1e21)");
}

// ── DisplayNames (CLDR language/region/script/currency — §12) ─────────────────

test "Intl.DisplayNames: language / region / script / currency in en" {
    try requireFullBuild();
    try evalAssert1(
        \\(new Intl.DisplayNames('en',{type:'language'}).of('fr')==='French' &&
        \\ new Intl.DisplayNames('en',{type:'language'}).of('zh-Hant')==='Traditional Chinese' &&
        \\ new Intl.DisplayNames('en',{type:'region'}).of('US')==='United States' &&
        \\ new Intl.DisplayNames('en',{type:'script'}).of('Latn')==='Latin' &&
        \\ new Intl.DisplayNames('en',{type:'currency'}).of('USD')==='US Dollar') ? 1 : 0
    );
}

test "Intl.DisplayNames: localized into de / fr / es" {
    try requireFullBuild();
    try evalAssert1(
        \\(new Intl.DisplayNames('de',{type:'region'}).of('DE')==='Deutschland' &&
        \\ new Intl.DisplayNames('fr',{type:'currency'}).of('EUR')==='euro' &&
        \\ new Intl.DisplayNames('es',{type:'language'}).of('fr')==='francés') ? 1 : 0
    );
}

test "Intl.DisplayNames: case-insensitive code lookup" {
    try requireFullBuild();
    try evalAssert1(
        \\(new Intl.DisplayNames('en',{type:'region'}).of('us')==='United States' &&
        \\ new Intl.DisplayNames('en',{type:'currency'}).of('usd')==='US Dollar') ? 1 : 0
    );
}

test "Intl.DisplayNames: fallback none returns undefined for unknown" {
    try requireFullBuild();
    try evalAssert1(
        \\new Intl.DisplayNames('en',{type:'language',fallback:'none'}).of('qqq')===undefined ? 1 : 0
    );
}

test "Intl.DisplayNames: invalid code shape throws RangeError" {
    try requireFullBuild();
    try evalThrows("new Intl.DisplayNames('en',{type:'region'}).of('USA')"); // 3-alpha not a region
    try evalThrows("new Intl.DisplayNames('en',{type:'currency'}).of('US')"); // 2-alpha not a currency
}

// ── new-target enforcement (§ "If NewTarget is undefined, throw TypeError") ──

test "intl: non-legacy constructors throw without new" {
    try requireIntlBuild();
    // Valid args, but no `new` → TypeError (the receiver-is-Intl-namespace case
    // that the old plain-object check let slip through).
    try evalThrows("Intl.PluralRules('en')");
    try evalThrows("Intl.RelativeTimeFormat('en')");
    try evalThrows("Intl.ListFormat('en')");
    try evalThrows("Intl.DisplayNames('en', { type: 'region' })");
    try evalThrows("Intl.Segmenter('en')");
    try evalThrows("Intl.Locale('en')");
    try evalThrows("Intl.DurationFormat('en')");
}

test "intl: non-legacy constructors still construct + subclass with new" {
    try requireIntlBuild();
    try evalAssert1(
        \\const pr = new Intl.PluralRules('en');
        \\class MyPR extends Intl.PluralRules {}
        \\const m = new MyPR('en');
        \\(pr instanceof Intl.PluralRules &&
        \\ m instanceof MyPR && m instanceof Intl.PluralRules &&
        \\ new Intl.Locale('en-US').language === 'en') ? 1 : 0
    );
}

// §10.1.1 / §11.1.1 / §12.1.1 — Collator / NumberFormat / DateTimeFormat are
// the legacy services callable *without* `new`. Each bare call must mint a
// fresh instance off the constructor's own prototype (so the `.compare` /
// `.format` accessors resolve through the chain) and must never write its
// internal-slots record onto the `Intl` namespace object. Reusing the
// namespace (the old `requireNew` path) leaked the record + its duped option
// strings on every repeat call and left the result prototype-less; the realm
// runs on `testing.allocator`, so a per-call leak trips leak detection at
// `realm.deinit()`.
test "intl: legacy Collator/NumberFormat/DateTimeFormat callable without new (no leak)" {
    try requireIntlBuild();
    try evalAssert1(
        \\let ok = 1;
        \\for (let i = 0; i < 8; i++) {
        \\  const nf = Intl.NumberFormat("en");
        \\  if (typeof nf.format !== "function" || nf.format(42) !== "42") ok = 0;
        \\  const co = Intl.Collator("en");
        \\  if (typeof co.compare !== "function" || !(co.compare("a", "b") < 0)) ok = 0;
        \\  const df = Intl.DateTimeFormat("en");
        \\  if (typeof df.format !== "function") ok = 0;
        \\}
        \\// No internal record may have landed on the Intl namespace: the
        \\// prototype methods brand-check their receiver, so calling one on
        \\// `Intl` itself must throw a TypeError.
        \\let clean = 0;
        \\try { Intl.NumberFormat.prototype.resolvedOptions.call(Intl); }
        \\catch (e) { clean = (e instanceof TypeError) ? 1 : 0; }
        \\(ok === 1 && clean === 1) ? 1 : 0
    );
}

// §11.1.1 — the `new` / subclass path runs OrdinaryCreateFromConstructor
// against NewTarget, so a subclass instance chains its prototype through the
// subclass and still reaches NumberFormat.prototype's accessors. Guards the
// deferred-proto path that the no-`new` fix routes all construction through.
test "intl: legacy ctor subclass chains prototype from NewTarget" {
    try requireIntlBuild();
    try evalAssert1(
        \\class MyNF extends Intl.NumberFormat {}
        \\const m = new MyNF("en");
        \\(m instanceof MyNF && m instanceof Intl.NumberFormat &&
        \\ Object.getPrototypeOf(m) === MyNF.prototype &&
        \\ typeof m.format === "function" && m.format(42) === "42") ? 1 : 0
    );
}
