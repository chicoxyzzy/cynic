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

test "intl/temporal: roc + buddhist year-offset calendar arithmetic" {
    try requireIntlBuild();
    // roc: year = iso − 1911, era roc (year ≥ 1), gregorian month structure.
    // `from` converts the calendar year back to ISO; the getters convert
    // forward; add/subtract + with preserve the calendar; ZonedDateTime year +
    // toPlainDateTime carry it through.
    try evalAssert1(
        \\const r = Temporal.PlainDate.from({year:108, monthCode:"M01", day:31, calendar:"roc"});
        \\if (r.year !== 108 || r.era !== "roc" || r.eraYear !== 108) throw 0;
        \\if (r.month !== 1 || r.day !== 31) throw 0;
        \\if (r.toString().slice(0,4) !== "2019") throw 0; // 108 roc = 2019 ISO
        \\const r2 = r.add({months:1});
        \\if (r2.year !== 108 || r2.month !== 2 || r2.era !== "roc") throw 0;
        \\const r3 = r.with({monthCode:"M02"});
        \\if (r3.calendarId !== "roc" || r3.month !== 2) throw 0;
        \\const b = Temporal.PlainDate.from({year:2563, monthCode:"M03", day:10, calendar:"buddhist"});
        \\if (b.year !== 2563 || b.era !== "be" || b.eraYear !== 2563) throw 0;
        \\if (b.toString().slice(0,4) !== "2020") throw 0; // 2563 BE = 2020 ISO
        \\const z = Temporal.ZonedDateTime.from({year:108, monthCode:"M01", day:1, timeZone:"UTC", calendar:"roc"});
        \\if (z.year !== 108 || z.era !== "roc") throw 0;
        \\if (z.toPlainDateTime().era !== "roc") throw 0;
        \\1
    );
}

test "intl/temporal: toLocaleString formats Temporal types via DateTimeFormat" {
    if (!intl_config.has_locale_data) return error.SkipZigTest; // needs CLDR output
    // §13.x — each Temporal type's toLocaleString routes through a transient
    // DateTimeFormat, applying the per-type ToDateTimeOptions defaults.
    try evalAssert1(
        \\const L = "en";
        \\if (Temporal.PlainDate.from("1976-11-18").toLocaleString(L) !== "11/18/1976") throw 0;
        \\if (Temporal.PlainDateTime.from("1976-11-18T14:23:30").toLocaleString(L) !== "11/18/1976, 2:23:30 PM") throw 1;
        \\if (Temporal.PlainTime.from("14:23:30").toLocaleString(L) !== "2:23:30 PM") throw 2;
        \\if (Temporal.PlainYearMonth.from("1976-11").toLocaleString(L) !== "11/1976") throw 3;
        \\if (Temporal.PlainMonthDay.from("11-18").toLocaleString(L) !== "11/18") throw 4;
        \\if (Temporal.Instant.from("1976-11-18T14:23:30Z").toLocaleString(L,{timeZone:"UTC"}) !== "11/18/1976, 2:23:30 PM") throw 5;
        \\if (Temporal.PlainDate.from("1976-11-18").toLocaleString(L,{year:"numeric",month:"long",day:"numeric"}) !== "November 18, 1976") throw 6;
        \\1
    );
}

test "temporal: islamic tabular calendar conversion (calendarFields/islamicToIso)" {
    // Pure calendar math — runs at every -Dintl flavour. Reference values
    // verified against V8 / JSC / SpiderMonkey via pragmatist engines.diff.
    const shared = @import("builtins/temporal/shared.zig");
    const temporal = @import("temporal.zig");
    const civil = temporal.CalendarId.fromSlice("islamic-civil").?;
    const tbla = temporal.CalendarId.fromSlice("islamic-tbla").?;

    // ISO 2024-01-01 → islamic-civil 1445-06-19 (month 6 = 29 days, 1445 leap).
    const a = shared.calendarFields(civil, 2024, 1, 1);
    try testing.expectEqual(@as(i32, 1445), a.year);
    try testing.expectEqual(@as(u32, 6), a.month);
    try testing.expectEqual(@as(u32, 19), a.day);
    try testing.expectEqual(@as(u32, 29), a.days_in_month);
    try testing.expectEqual(@as(u32, 355), a.days_in_year);
    try testing.expect(a.in_leap_year);
    try testing.expectEqualStrings("ah", a.era.?);
    try testing.expectEqual(@as(i32, 1445), a.era_year.?);

    // islamic-tbla is one day later for the same ISO date (epoch one day earlier).
    try testing.expectEqual(@as(u32, 20), shared.calendarFields(tbla, 2024, 1, 1).day);

    // ISO 2024-07-07 → civil 1445-12-30 (leap-year Dhuʻl-Ḥijja has 30 days).
    const b = shared.calendarFields(civil, 2024, 7, 7);
    try testing.expectEqual(@as(u32, 12), b.month);
    try testing.expectEqual(@as(u32, 30), b.day);
    try testing.expectEqual(@as(u32, 30), b.days_in_month);

    // Round-trip: islamic-civil 1445-06-19 → ISO 2024-01-01.
    const iso = shared.islamicToIso(civil, 1445, 6, 19, true).?;
    try testing.expectEqual(@as(i64, 2024), iso.year);
    try testing.expectEqual(@as(u32, 1), iso.month);
    try testing.expectEqual(@as(u32, 1), iso.day);

    // Constrain vs reject: day 30 in a 29-day month clamps (non-null) or throws.
    try testing.expect(shared.islamicToIso(civil, 1445, 6, 30, false) != null);
    try testing.expect(shared.islamicToIso(civil, 1445, 6, 30, true) == null);
}

test "intl/temporal: PlainDate islamic-civil getters / from / add / with" {
    try requireIntlBuild(); // Temporal accepts non-ISO calendars at stub+ (math is pure)
    try evalAssert1(
        \\const c = "islamic-civil";
        \\const w = Temporal.PlainDate.from("2024-01-01").withCalendar(c);
        \\if (w.year !== 1445 || w.month !== 6 || w.day !== 19) throw 0;
        \\if (w.monthCode !== "M06" || w.era !== "ah" || w.eraYear !== 1445) throw 1;
        \\if (w.daysInMonth !== 29 || w.daysInYear !== 355 || w.inLeapYear !== true) throw 2;
        \\const f = Temporal.PlainDate.from({ year: 1445, monthCode: "M06", day: 19, calendar: c });
        \\if (f.year !== 1445 || f.month !== 6 || f.day !== 19) throw 3;
        \\const a = f.add({ months: 1 }); // calendar-aware: +1 Islamic month
        \\if (a.year !== 1445 || a.month !== 7) throw 4;
        \\const v = f.with({ monthCode: "M12" }); // leap year → month 12 has 30 days
        \\if (v.month !== 12 || v.daysInMonth !== 30) throw 5;
        \\if (Temporal.PlainDate.from("2024-01-01").withCalendar("islamic-tbla").day !== 20) throw 6;
        \\1
    );
}

test "intl/temporal: PlainDateTime + ZonedDateTime islamic-civil getters / add" {
    try requireIntlBuild();
    try evalAssert1(
        \\const c = "islamic-civil";
        \\const dt = Temporal.PlainDateTime.from("2024-01-01T05:30:00").withCalendar(c);
        \\if (dt.year !== 1445 || dt.month !== 6 || dt.day !== 19 || dt.hour !== 5) throw 0;
        \\if (dt.era !== "ah" || dt.daysInMonth !== 29) throw 1;
        \\if (dt.add({ months: 1 }).month !== 7) throw 2; // calendar-aware
        \\const z = Temporal.ZonedDateTime.from("2024-01-01T00:00:00[UTC]").withCalendar(c);
        \\if (z.year !== 1445 || z.month !== 6 || z.day !== 19 || z.era !== "ah") throw 3;
        \\if (z.add({ months: 1 }).month !== 7) throw 4;
        \\if (z.toPlainDateTime().era !== "ah" || z.toPlainDate().month !== 6) throw 5;
        \\1
    );
}

test "intl/temporal: PlainYearMonth islamic-civil + calendar preservation" {
    try requireIntlBuild();
    try evalAssert1(
        \\const c = "islamic-civil";
        \\const p = Temporal.PlainYearMonth.from({ year: 1445, monthCode: "M06", calendar: c });
        \\if (p.calendarId !== c || p.year !== 1445 || p.month !== 6) throw 0;
        \\if (p.monthCode !== "M06" || p.era !== "ah" || p.daysInMonth !== 29) throw 1;
        \\if (p.add({ months: 1 }).month !== 7 || p.add({ months: 12 }).year !== 1446) throw 2;
        \\const q = Temporal.PlainYearMonth.from({ year: 1446, monthCode: "M06", calendar: c });
        \\const d = p.until(q); // exactly one Islamic year
        \\if (d.years !== 1 || d.months !== 0) throw 3;
        \\// the calendar-preservation gap fix also keeps a gregory year-month:
        \\if (Temporal.PlainYearMonth.from({ year: 2024, monthCode: "M03", calendar: "gregory" }).era !== "ce") throw 4;
        \\1
    );
}

test "intl/temporal: coptic + ethiopic 13-month calendars (getters / from / add)" {
    try requireIntlBuild();
    // Coptic-type family: 13 months (12×30 + a 5/6-day epagomenal M13), leap
    // every 4th year, era "am"; coptic / ethiopic differ only by epoch.
    try evalAssert1(
        \\const co = Temporal.PlainDate.from("2020-09-11").withCalendar("coptic");
        \\if (co.year !== 1737 || co.month !== 1 || co.day !== 1) throw 0;
        \\if (co.era !== "am" || co.monthsInYear !== 13 || co.daysInMonth !== 30) throw 1;
        \\const et = Temporal.PlainDate.from("2020-09-11").withCalendar("ethiopic");
        \\if (et.year !== 2013 || et.month !== 1 || et.era !== "am" || et.monthsInYear !== 13) throw 2;
        \\const f = Temporal.PlainDate.from({ year: 1740, monthCode: "M04", day: 22, calendar: "coptic" });
        \\if (f.toString().slice(0, 10) !== "2024-01-01") throw 3;
        \\if (f.add({ months: 13 }).year !== 1741 || f.add({ months: 13 }).month !== 4) throw 4;
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

test "Intl.NumberFormat: non-finite format (infinity / NaN glyphs)" {
    try requireFullBuild();
    // §15.5.x — ±∞ and NaN render as the locale's CLDR infinity / nan symbols,
    // not the truncated "0" the digit path used to produce.
    try evalAssert1(
        \\const f = new Intl.NumberFormat('en');
        \\(f.format(-Infinity)==='-∞' && f.format(Infinity)==='∞' && f.format(NaN)==='NaN') ? 1 : 0
    );
}

test "Intl.NumberFormat: non-finite formatToParts segments" {
    try requireFullBuild();
    try evalAssert1(
        \\const ni = new Intl.NumberFormat('en').formatToParts(-Infinity);
        \\const pi = new Intl.NumberFormat('en').formatToParts(Infinity);
        \\const pn = new Intl.NumberFormat('en').formatToParts(NaN);
        \\(ni.length===2 && ni[0].type==='minusSign' && ni[0].value==='-' && ni[1].type==='infinity' && ni[1].value==='∞' &&
        \\ pi.length===1 && pi[0].type==='infinity' && pi[0].value==='∞' &&
        \\ pn.length===1 && pn[0].type==='nan' && pn[0].value==='NaN') ? 1 : 0
    );
}

test "Intl.NumberFormat: non-finite signDisplay (NaN sign-less, infinity signed)" {
    try requireFullBuild();
    // NaN is sign-less per ToIntlMathematicalValue: "always" emits "+NaN" but
    // "exceptZero"/auto/"negative" emit no sign, and a -NaN still formats "NaN".
    try evalAssert1(
        \\const always = new Intl.NumberFormat('en',{signDisplay:'always'});
        \\const exceptZero = new Intl.NumberFormat('en',{signDisplay:'exceptZero'});
        \\const negative = new Intl.NumberFormat('en',{signDisplay:'negative'});
        \\(always.format(Infinity)==='+∞' && always.format(NaN)==='+NaN' && always.format(-Infinity)==='-∞' &&
        \\ exceptZero.format(Infinity)==='+∞' && exceptZero.format(NaN)==='NaN' &&
        \\ negative.format(Infinity)==='∞' && negative.format(-Infinity)==='-∞' &&
        \\ new Intl.NumberFormat('en').format(-NaN)==='NaN') ? 1 : 0
    );
}

test "Intl.NumberFormat: non-finite currency and percent keep affixes" {
    try requireFullBuild();
    // The infinity / nan glyph replaces only the digits; the currency symbol and
    // percent sign still surround it ("$∞", "-∞%").
    try evalAssert1(
        \\const usd = new Intl.NumberFormat('en',{style:'currency',currency:'USD'});
        \\const pct = new Intl.NumberFormat('en',{style:'percent'});
        \\const cp = usd.formatToParts(-Infinity);
        \\(usd.format(Infinity)==='$∞' && usd.format(-Infinity)==='-$∞' &&
        \\ pct.format(Infinity)==='∞%' && pct.format(-Infinity)==='-∞%' &&
        \\ cp.length===3 && cp[0].type==='minusSign' && cp[1].type==='currency' && cp[1].value==='$' &&
        \\ cp[2].type==='infinity' && cp[2].value==='∞') ? 1 : 0
    );
}

test "Intl.NumberFormat: non-finite currencyDisplay name + accounting" {
    try requireFullBuild();
    // currencyDisplay:"name" wraps the glyph in the unitPattern ("∞ US dollars");
    // accounting parens wrap it too ("($∞)"). The glyph replaces only the digits.
    try evalAssert1(
        \\const nm = new Intl.NumberFormat('en',{style:'currency',currency:'USD',currencyDisplay:'name'});
        \\const acct = new Intl.NumberFormat('en',{style:'currency',currency:'USD',currencySign:'accounting'});
        \\const p = nm.formatToParts(Infinity);
        \\(nm.format(Infinity)==='∞ US dollars' && nm.format(-Infinity)==='-∞ US dollars' &&
        \\ nm.format(NaN)==='NaN US dollars' && acct.format(-Infinity)==='($∞)' &&
        \\ p.length===3 && p[0].type==='infinity' && p[1].type==='literal' && p[2].type==='currency' &&
        \\ p[2].value==='US dollars') ? 1 : 0
    );
}

test "Intl.NumberFormat: localized NaN symbol (ar CLDR nan)" {
    try requireFullBuild();
    // ar's CLDR `nan` symbol is a localized phrase joined by a U+00A0 no-break
    // space, proving the per-locale packed symbol is used, not the "NaN" default.
    try evalAssert1(
        \\const arNaN = new Intl.NumberFormat('ar').format(NaN);
        \\(arNaN!=='NaN' && arNaN==='ليس رقمًا') ? 1 : 0
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

// ── NumberFormat currency (CLDR symbols + patterns + fraction digits) ─────────

test "intl: currency formats with localized symbol + minor units" {
    try requireFullBuild();
    try evalAssert1(
        \\const f = (l, c, v) => new Intl.NumberFormat(l, { style: 'currency', currency: c }).format(v);
        \\(f('en','USD',5) === '$5.00' &&
        \\ f('en','USD',-1234.5) === '-$1,234.50' &&
        \\ f('en','EUR',1) === '€1.00' &&
        \\ f('en','JPY',1234.5) === '¥1,235' &&      // 0 fraction digits
        \\ f('de','EUR',1234.5) === '1.234,50 €' // suffix symbol, nbsp
        \\) ? 1 : 0
    );
}

test "intl: currencyDisplay symbol vs narrowSymbol" {
    try requireFullBuild();
    try evalAssert1(
        \\const f = (o) => new Intl.NumberFormat('en', Object.assign({ style:'currency', currency:'CAD' }, o)).format(5);
        \\// CAD's locale symbol is "CA$"; its narrow form is "$".
        \\(f({ currencyDisplay:'symbol' }) === 'CA$5.00' &&
        \\ f({ currencyDisplay:'narrowSymbol' }) === '$5.00') ? 1 : 0
    );
}

test "intl: currency formatToParts emits currency + sign parts in order" {
    try requireFullBuild();
    try evalAssert1(
        \\const p = new Intl.NumberFormat('en', { style:'currency', currency:'USD' }).formatToParts(-5);
        \\const t = p.map(x => x.type).join(',');
        \\(t === 'minusSign,currency,integer,decimal,fraction' &&
        \\ p.find(x => x.type==='currency').value === '$') ? 1 : 0
    );
}

test "intl: currency options validated regardless of style (§15.1.2)" {
    try requireIntlBuild();
    // currencyDisplay / currencySign are read + validated even when the style
    // is not "currency" — an invalid value throws RangeError.
    try evalThrows("new Intl.NumberFormat('en', { currencyDisplay: 'bogus' })");
    try evalThrows("new Intl.NumberFormat('en', { currencySign: 'bogus' })");
    try evalThrows("new Intl.NumberFormat('en', { style:'decimal', currency: 'US' })"); // malformed code
}

test "intl: currency default minFractionDigits clamps to a smaller user max" {
    try requireIntlBuild();
    // cCurrencyDigits(USD)=2 would make the default mnfd 2, but an explicit
    // maximumFractionDigits:0 must clamp it down, not throw (§15.1.1).
    try evalAssert1(
        \\const ro = new Intl.NumberFormat('en', { style:'currency', currency:'USD', maximumFractionDigits:0 }).resolvedOptions();
        \\(ro.minimumFractionDigits === 0 && ro.maximumFractionDigits === 0) ? 1 : 0
    );
}

// §15.5 GetNumberFormatPattern — currencySign:"accounting" selects the
// locale's accounting *negative subpattern* (after ';') for negatives, so
// en/ja/ko/zh wrap the value in parentheses and emit no minus sign. The
// positive subpattern still applies to non-negatives, and signDisplay still
// governs whether the positive case shows a plusSign. Matches V8 / JSC / SM.
test "intl: currency accounting sign wraps negatives in parentheses" {
    try requireFullBuild();
    try evalAssert1(
        \\const acct = (v, sd) => new Intl.NumberFormat('en-US', { style:'currency', currency:'USD', currencySign:'accounting', signDisplay: sd || 'auto' }).format(v);
        \\(acct(-987) === '($987.00)' &&
        \\ acct(987) === '$987.00' &&
        \\ acct(0) === '$0.00' &&
        \\ acct(-987, 'never') === '$987.00' &&
        \\ acct(987, 'always') === '+$987.00' &&
        \\ acct(-987, 'always') === '($987.00)' &&
        \\ acct(-987, 'negative') === '($987.00)') ? 1 : 0
    );
}

test "intl: currency accounting negative formatToParts emits paren literals (6 parts)" {
    try requireFullBuild();
    // The cited test262 shape: 6 parts where a minus-sign rendering gives 5.
    try evalAssert1(
        \\const p = new Intl.NumberFormat('en-US', { style:'currency', currency:'USD', currencySign:'accounting' }).formatToParts(-987);
        \\const t = p.map(x => x.type).join(',');
        \\(p.length === 6 &&
        \\ t === 'literal,currency,integer,decimal,fraction,literal' &&
        \\ p[0].value === '(' && p[1].value === '$' && p[5].value === ')') ? 1 : 0
    );
}

// §15.5 / CLDR currencySpacing — when the currency display abuts the digits
// and its number-facing character is a letter (the "alphaNextToNumber" case,
// e.g. the ISO code "CAD"), a U+00A0 no-break space is inserted between the
// currency and the number. A symbol glyph ($, €) gets no space. Matches the
// production engines' `-alphaNextToNumber` pattern selection.
test "intl: currencyDisplay code inserts a no-break space before digits" {
    try requireFullBuild();
    try evalAssert1(
        \\const code = (c) => new Intl.NumberFormat('en-US', { style:'currency', currency:c, currencyDisplay:'code' }).format(5);
        \\const sym = new Intl.NumberFormat('en-US', { style:'currency', currency:'USD' }).format(5);
        \\(code('CAD') === 'CAD\u00A05.00' &&    // letter-adjacent → U+00A0
        \\ code('USD') === 'USD\u00A05.00' &&
        \\ sym === '$5.00') ? 1 : 0               // symbol glyph → no space
    );
}

test "intl: currencyDisplay code formatToParts emits a literal nbsp segment" {
    try requireFullBuild();
    try evalAssert1(
        \\const p = new Intl.NumberFormat('en-US', { style:'currency', currency:'CAD', currencyDisplay:'code' }).formatToParts(5);
        \\const t = p.map(x => x.type).join(',');
        \\(t === 'currency,literal,integer,decimal,fraction' &&
        \\ p[0].value === 'CAD' && p[1].value === '\u00A0' && p[1].value.charCodeAt(0) === 160) ? 1 : 0
    );
}

// \u00A715.5 \u2014 currencyDisplay:"name" renders the locale `unitPattern-count-{plural}`
// ("{0} {1}": number then long name) with the long name plural-selected on the
// *formatted* operands, not the raw value. So "1.00" (two fraction digits \u2192 v=2,
// category "other") is "1.00 US dollars", while a 0-fraction "1" (v=0, "one")
// is "1 US dollar". The separator is the pattern's own U+0020. Matches V8/JSC/SM.
test "intl: currencyDisplay name uses plural unit pattern (en)" {
    try requireFullBuild();
    try evalAssert1(
        \\const f = (v, o) => new Intl.NumberFormat('en', Object.assign({ style:'currency', currency:'USD', currencyDisplay:'name' }, o)).format(v);
        \\(f(5) === '5.00 US dollars' &&
        \\ f(1) === '1.00 US dollars' &&                                  // v=2 \u21D2 "other"
        \\ f(1, { minimumFractionDigits:0, maximumFractionDigits:0 }) === '1 US dollar' &&   // v=0 \u21D2 "one"
        \\ f(2, { minimumFractionDigits:0, maximumFractionDigits:0 }) === '2 US dollars') ? 1 : 0
    );
}

test "intl: currencyDisplay name is locale-pluralised (de, fr)" {
    try requireFullBuild();
    // de has only unitPattern-count-other; fr's cardinal "one" covers i\u2208{0,1}
    // so 1,00 is singular "euro". Both draw the per-currency long name.
    try evalAssert1(
        \\const f = (l, c, v) => new Intl.NumberFormat(l, { style:'currency', currency:c, currencyDisplay:'name' }).format(v);
        \\(f('de','EUR',5) === '5,00 Euro' &&
        \\ f('fr','EUR',1) === '1,00 euro') ? 1 : 0
    );
}

test "intl: currencyDisplay name formatToParts puts long name in the currency part" {
    try requireFullBuild();
    try evalAssert1(
        \\const p = new Intl.NumberFormat('en', { style:'currency', currency:'USD', currencyDisplay:'name' }).formatToParts(1234.5);
        \\const t = p.map(x => x.type).join(',');
        \\(t === 'integer,group,integer,decimal,fraction,literal,currency' &&
        \\ p[p.length-1].value === 'US dollars' && p[5].value === ' ') ? 1 : 0
    );
}

test "intl: currencyDisplay name negative leads with a minus, ignores accounting" {
    try requireFullBuild();
    // The unit pattern has no accounting variant, so a negative shows a minus
    // sign even under currencySign:"accounting".
    try evalAssert1(
        \\const f = (o) => new Intl.NumberFormat('en', Object.assign({ style:'currency', currency:'USD', currencyDisplay:'name' }, o)).format(-5);
        \\(f({}) === '-5.00 US dollars' &&
        \\ f({ currencySign:'accounting' }) === '-5.00 US dollars') ? 1 : 0
    );
}

// ── DisplayNames.prototype.of code validation (§12.5.1) ──────────────────────

test "intl: DisplayNames.of rejects malformed codes per type" {
    try requireIntlBuild();
    // language type → must be a bare unicode_language_id (no singletons / -u-,
    // no duplicate variants, valid subtag shapes).
    try evalThrows("new Intl.DisplayNames('en',{type:'language'}).of('en-u-hebrew')");
    try evalThrows("new Intl.DisplayNames('en',{type:'language'}).of('aa-aaaaa-aaaaa')");
    try evalThrows("new Intl.DisplayNames('en',{type:'language'}).of('abcdefghi')");
    try evalThrows("new Intl.DisplayNames('en',{type:'language'}).of('1a')");
    // calendar type → must be a Unicode `type` (3-8 alphanumeric subtags).
    try evalThrows("new Intl.DisplayNames('en',{type:'calendar'}).of('')");
    try evalThrows("new Intl.DisplayNames('en',{type:'calendar'}).of('ab')");
    // dateTimeField type → must be a sanctioned field.
    try evalThrows("new Intl.DisplayNames('en',{type:'dateTimeField'}).of('bogus')");
}

test "intl: DisplayNames.of accepts well-formed codes" {
    try requireIntlBuild();
    try evalAssert1(
        \\const lang = new Intl.DisplayNames('en',{type:'language'});
        \\const cal = new Intl.DisplayNames('en',{type:'calendar'});
        \\const dtf = new Intl.DisplayNames('en',{type:'dateTimeField'});
        \\(typeof lang.of('zh-Hant') === 'string' &&
        \\ typeof cal.of('gregory') === 'string' &&
        \\ typeof dtf.of('month') === 'string') ? 1 : 0
    );
}

// ── Intl.Locale info methods (Stage 4) ───────────────────────────────────────

test "intl: Locale info methods return correct shapes" {
    try requireIntlBuild();
    try evalAssert1(
        \\const l = new Intl.Locale('en-US');
        \\const arr = (x) => Array.isArray(x) && x.length > 0 && x.every(s => typeof s === 'string');
        \\const wi = l.getWeekInfo();
        \\const ti = l.getTextInfo();
        \\(arr(l.getCalendars()) && arr(l.getCollations()) && arr(l.getHourCycles()) &&
        \\ arr(l.getNumberingSystems()) &&
        \\ JSON.stringify(Reflect.ownKeys(ti)) === '["direction"]' &&
        \\ (ti.direction === 'ltr' || ti.direction === 'rtl') &&
        \\ JSON.stringify(Reflect.ownKeys(wi)) === '["firstDay","weekend"]' &&
        \\ wi.firstDay >= 1 && wi.firstDay <= 7 &&
        \\ wi.weekend.every(d => d >= 1 && d <= 7)) ? 1 : 0
    );
}

test "intl: Locale getCalendars reflects -u-ca-, getTextInfo reflects script" {
    try requireIntlBuild();
    try evalAssert1(
        \\(new Intl.Locale('th-u-ca-buddhist').getCalendars()[0] === 'buddhist' &&
        \\ new Intl.Locale('ar').getTextInfo().direction === 'rtl' &&
        \\ new Intl.Locale('en').getTextInfo().direction === 'ltr' &&
        \\ new Intl.Locale('de-DE-1996').variants === '1996') ? 1 : 0
    );
}

// ── UTS #35 §4.3 Likely Subtags (locale maximize / minimize) ─────────────────

test "intl: NumberFormat resolves CLDR data against the maximized script (zh-TW)" {
    try requireFullBuild();
    // §4.3 Add Likely Subtags: zh-TW maximizes to zh-Hant-TW, so the non-finite
    // glyph resolves from zh-Hant ("非數值"), not bare zh ("NaN").
    try evalAssert1(
        \\new Intl.NumberFormat('zh-TW').format(NaN) === '非數值' ? 1 : 0
    );
}

test "intl: NumberFormat resolvedOptions.locale is NOT maximized" {
    try requireFullBuild();
    // The maximized tag feeds CLDR lookups only; resolvedOptions().locale keeps
    // the requested (canonicalised) tag per ECMA-402 §11.5.1 ResolvedOptions.
    try evalAssert1(
        \\new Intl.NumberFormat('zh-TW').resolvedOptions().locale === 'zh-TW' ? 1 : 0
    );
}

test "intl: data-locale caching matches the explicit-script path (en == en-Latn)" {
    try requireFullBuild();
    // §4.3 Add Likely Subtags is computed once at construction and stored as the
    // data-locale; the per-format CLDR lookups must produce byte-identical output
    // to passing the maximized script explicitly. Covers number / percent /
    // currency / date / plural so a regression in any lookup path shows here.
    try evalAssert1(
        \\const eq = (a, b) => a === b;
        \\const num = eq(new Intl.NumberFormat('en').format(1234567.89),
        \\              new Intl.NumberFormat('en-Latn').format(1234567.89));
        \\const pct = eq(new Intl.NumberFormat('en', {style:'percent'}).format(0.4567),
        \\              new Intl.NumberFormat('en-Latn', {style:'percent'}).format(0.4567));
        \\const cur = eq(new Intl.NumberFormat('en', {style:'currency', currency:'USD'}).format(5),
        \\              new Intl.NumberFormat('en-Latn', {style:'currency', currency:'USD'}).format(5));
        \\const dat = eq(new Intl.DateTimeFormat('en', {dateStyle:'long'}).format(0),
        \\              new Intl.DateTimeFormat('en-Latn', {dateStyle:'long'}).format(0));
        \\const plu = eq(new Intl.PluralRules('en').select(1),
        \\              new Intl.PluralRules('en-Latn').select(1));
        \\const dn = eq(new Intl.DisplayNames('en', {type:'language'}).of('fr'),
        \\             new Intl.DisplayNames('en-Latn', {type:'language'}).of('fr'));
        \\(num && pct && cur && dat && plu && dn) ? 1 : 0
    );
}

test "intl: Locale.prototype.maximize fills missing subtags" {
    try requireFullBuild();
    try evalAssert1(
        \\const m = (t) => new Intl.Locale(t).maximize().toString();
        \\(m('zh-TW') === 'zh-Hant-TW' &&
        \\ m('zh-HK') === 'zh-Hant-HK' &&
        \\ m('zh-SG') === 'zh-Hans-SG' &&
        \\ m('zh-CN') === 'zh-Hans-CN' &&
        \\ m('sr-RS') === 'sr-Cyrl-RS' &&
        \\ m('pa-PK') === 'pa-Arab-PK' &&
        \\ m('zh') === 'zh-Hans-CN' &&
        \\ m('en') === 'en-Latn-US') ? 1 : 0
    );
}

test "intl: Locale.prototype.maximize handles undefined primary language" {
    try requireFullBuild();
    try evalAssert1(
        \\const m = (t) => new Intl.Locale(t).maximize().toString();
        \\(m('und-Thai') === 'th-Thai-TH' &&
        \\ m('und-419') === 'es-Latn-419' &&
        \\ m('und-Cyrl-RO') === 'bg-Cyrl-RO' &&
        \\ m('und-AQ') === 'en-Latn-AQ' &&
        \\ m('und') === 'en-Latn-US') ? 1 : 0
    );
}

test "intl: Locale.prototype.maximize preserves variants and extensions" {
    try requireFullBuild();
    try evalAssert1(
        \\const m = (t) => new Intl.Locale(t).maximize().toString();
        \\(m('zh-TW-u-co-phonebk') === 'zh-Hant-TW-u-co-phonebk' &&
        \\ m('en-fonipa') === 'en-Latn-US-fonipa' &&
        \\ m('en-x-private') === 'en-Latn-US-x-private') ? 1 : 0
    );
}

test "intl: Locale.prototype.minimize removes likely subtags" {
    try requireFullBuild();
    try evalAssert1(
        \\const m = (t) => new Intl.Locale(t).minimize().toString();
        \\(m('en-Latn-US') === 'en' &&
        \\ m('en-Shaw-GB') === 'en-Shaw' &&
        \\ m('en-Arab-US') === 'en-Arab' &&
        \\ m('en-Latn-GB') === 'en-GB' &&
        \\ m('zh-Hant') === 'zh-TW' &&
        \\ m('und-Latn-AQ') === 'en-AQ') ? 1 : 0
    );
}

test "intl: cldr.addLikelySubtags fills script/region (UTS #35 §4.3)" {
    try requireFullBuild();
    const Case = struct { in: cldr.Subtags, lang: []const u8, script: []const u8, region: []const u8 };
    const cases = [_]Case{
        .{ .in = .{ .lang = "zh", .region = "TW" }, .lang = "zh", .script = "Hant", .region = "TW" },
        .{ .in = .{ .lang = "zh", .region = "SG" }, .lang = "zh", .script = "Hans", .region = "SG" },
        .{ .in = .{ .lang = "sr", .region = "RS" }, .lang = "sr", .script = "Cyrl", .region = "RS" },
        .{ .in = .{ .lang = "pa", .region = "PK" }, .lang = "pa", .script = "Arab", .region = "PK" },
        .{ .in = .{ .lang = "zh" }, .lang = "zh", .script = "Hans", .region = "CN" },
        // Empty / "und" language → root maximizes to en-Latn-US.
        .{ .in = .{ .lang = "und" }, .lang = "en", .script = "Latn", .region = "US" },
        .{ .in = .{ .lang = "und", .script = "Thai" }, .lang = "th", .script = "Thai", .region = "TH" },
    };
    for (cases) |c| {
        var out: cldr.Subtags = .{};
        try testing.expect(cldr.addLikelySubtags(c.in, &out));
        try testing.expectEqualStrings(c.lang, out.lang);
        try testing.expectEqualStrings(c.script, out.script);
        try testing.expectEqualStrings(c.region, out.region);
    }
}

test "intl: cldr.removeLikelySubtags finds the minimal form" {
    try requireFullBuild();
    var out: cldr.Subtags = .{};
    try testing.expect(cldr.removeLikelySubtags(.{ .lang = "en", .script = "Latn", .region = "US" }, &out));
    try testing.expectEqualStrings("en", out.lang);
    try testing.expectEqualStrings("", out.script);
    try testing.expectEqualStrings("", out.region);

    try testing.expect(cldr.removeLikelySubtags(.{ .lang = "zh", .script = "Hant" }, &out));
    try testing.expectEqualStrings("zh", out.lang);
    try testing.expectEqualStrings("", out.script);
    try testing.expectEqualStrings("TW", out.region);
}

// ── Intl.ListFormat (CLDR list patterns + StringListFromIterable) ─────────────

test "intl: ListFormat applies CLDR patterns by type/style" {
    try requireFullBuild();
    try evalAssert1(
        \\const f = (o, a) => new Intl.ListFormat('en', o).format(a);
        \\(f({}, ['a','b','c']) === 'a, b, and c' &&
        \\ f({}, ['a','b']) === 'a and b' &&
        \\ f({type:'disjunction'}, ['a','b','c']) === 'a, b, or c' &&
        \\ f({type:'conjunction',style:'short'}, ['a','b']) === 'a & b') ? 1 : 0
    );
}

test "intl: ListFormat iterates any iterable + validates strings" {
    try requireIntlBuild();
    // Generic iterable (Set), empty list, and non-string rejection.
    try evalAssert1(
        \\const lf = new Intl.ListFormat('en');
        \\const set = lf.format(new Set(['x','y','z']));
        \\let threw = 0;
        \\try { lf.format(['ok', 3]); } catch (e) { threw = (e instanceof TypeError) ? 1 : 0; }
        \\(set.length > 0 && lf.format([]) === '' && threw === 1) ? 1 : 0
    );
}

test "intl: ListFormat formatToParts emits element/literal segments" {
    try requireFullBuild();
    try evalAssert1(
        \\const p = new Intl.ListFormat('en').formatToParts(['a','b','c']);
        \\const types = p.map(x => x.type).join(',');
        \\(types === 'element,literal,element,literal,element' &&
        \\ p.filter(x => x.type === 'element').map(x => x.value).join('') === 'abc') ? 1 : 0
    );
}

// ── CanonicalizeLocaleList (§9.2.1) — array-like, not iterator protocol ───────

test "intl: CanonicalizeLocaleList uses array-like coercion" {
    try requireIntlBuild();
    // Observed via supportedLocalesOf, which returns the canonicalized list.
    try evalAssert1(
        \\const s = Intl.PluralRules.supportedLocalesOf;
        \\// Array-like object (length + indices), not an iterable.
        \\const al = s({ 0: 'en', 1: 'fr', length: 2 });
        \\// A primitive coerces via ToObject to a length-less wrapper → empty.
        \\const prim = s(Symbol());
        \\(Array.isArray(al) && al.length === 2 && al[0] === 'en' &&
        \\ Array.isArray(prim) && prim.length === 0) ? 1 : 0
    );
}

test "intl: CanonicalizeLocaleList propagates a poisoned length valueOf" {
    try requireIntlBuild();
    try evalAssert1(
        \\class E extends Error {}
        \\let got = 0;
        \\try { Intl.PluralRules.supportedLocalesOf({ get length() { throw new E(); } }); }
        \\catch (e) { got = (e instanceof E) ? 1 : 0; }
        \\got
    );
}

test "intl: supportedLocalesOf filters unsupported locales" {
    try requireFullBuild();
    // 'zxx' (no linguistic content) is structurally valid but has no CLDR
    // data, so LookupSupportedLocales drops it; 'en' is kept.
    try evalAssert1(
        \\const s = Intl.PluralRules.supportedLocalesOf(['en', 'zxx']);
        \\(s.length === 1 && s[0] === 'en') ? 1 : 0
    );
}

// ── Intl.Locale tag validation (§14.1.1) ─────────────────────────────────────

test "intl: Locale rejects non-string/non-object tags with TypeError" {
    try requireIntlBuild();
    try evalThrows("new Intl.Locale(true)");
    try evalThrows("new Intl.Locale(null)");
    try evalThrows("new Intl.Locale(42)");
}

test "intl: language tag with duplicate variant is structurally invalid" {
    try requireIntlBuild();
    try testing.expect(!intl.isStructurallyValidLanguageTag("en-emodeng-emodeng"));
    try testing.expect(intl.isStructurallyValidLanguageTag("de-DE-1996-fonipa")); // distinct variants ok
    try evalThrows("new Intl.Locale('en-emodeng-emodeng')");
}

// ── Intl.Locale ApplyOptionsToTag (§14.1.2) ──────────────────────────────────

test "intl: Locale applies language/script/region/variants options" {
    try requireIntlBuild();
    try evalAssert1(
        \\(new Intl.Locale('en', {region:'FR'}).toString() === 'en-FR' &&
        \\ new Intl.Locale('en', {script:'Cyrl'}).toString() === 'en-Cyrl' &&
        \\ new Intl.Locale('en', {language:'fr'}).toString() === 'fr' &&
        \\ new Intl.Locale('zh', {region:'CN', script:'Hans'}).toString() === 'zh-Hans-CN' &&
        \\ new Intl.Locale('en', {variants:'fonipa'}).toString() === 'en-fonipa') ? 1 : 0
    );
}

test "intl: Locale option overrides validate + reject + propagate" {
    try requireIntlBuild();
    try evalThrows("new Intl.Locale('en', {region:'XYZ'})"); // bad region subtag
    try evalThrows("new Intl.Locale('en', {script:'x'})"); // bad script subtag
    try evalThrows("new Intl.Locale('en', {variants:'a'})"); // bad variant
    // an abrupt option getter propagates
    try evalThrows("new Intl.Locale('en', {get region(){ throw new RangeError('x'); }})");
}

// ── Intl.PluralRules notation + digit options (§16.1.1 / §16.3.2) ─────────────

test "intl: PluralRules reads notation + digit options into resolvedOptions" {
    try requireIntlBuild();
    try evalAssert1(
        \\const ro = new Intl.PluralRules('en', {
        \\  notation: 'scientific', minimumFractionDigits: 2, roundingMode: 'ceil'
        \\}).resolvedOptions();
        \\(ro.notation === 'scientific' && ro.minimumFractionDigits === 2 &&
        \\ ro.roundingMode === 'ceil' && ro.roundingPriority === 'auto' &&
        \\ ro.trailingZeroDisplay === 'auto' &&
        \\ new Intl.PluralRules('en').resolvedOptions().notation === 'standard') ? 1 : 0
    );
}

test "intl: PluralRules validates notation + propagates abrupt getters" {
    try requireIntlBuild();
    try evalThrows("new Intl.PluralRules('en', { notation: 'bogus' })");
    try evalThrows("new Intl.PluralRules('en', { get roundingIncrement(){ throw new RangeError('x'); } })");
}

// ── Intl.Collator unicode extension resolution (§10.1.1) ─────────────────────

test "intl: Collator resolves -u-co/kn/kf with option override" {
    try requireIntlBuild();
    try evalAssert1(
        \\const ro = (l, o) => new Intl.Collator(l, o).resolvedOptions();
        \\const a = ro('de-u-co-phonebk');
        \\const b = ro('en-u-kn-false', { numeric: true });
        \\const c = ro('en-u-co-standard');           // standard never reported
        \\const d = ro('en-u-co-bogus');              // unsupported → default
        \\(a.collation === 'phonebk' && a.locale === 'de-u-co-phonebk' &&
        \\ b.numeric === true && b.locale === 'en' &&  // option drops the keyword
        \\ c.collation === 'default' && c.locale === 'en' &&
        \\ d.collation === 'default') ? 1 : 0
    );
}

test "intl: unicode extension inside private-use is ignored" {
    try requireIntlBuild();
    try evalAssert1(
        \\new Intl.Collator('de-x-u-co-phonebk').resolvedOptions().collation === 'default' ? 1 : 0
    );
}

// ── Intl.Segmenter Segments.containing + iteration (§18.6 / §18.7) ────────────

test "intl: Segmenter segments iterate + containing + isWordLike" {
    try requireIntlBuild();
    try evalAssert1(
        \\const w = new Intl.Segmenter('en', { granularity: 'word' });
        \\const segs = w.segment('a b');
        \\const parts = [...segs];
        \\const c = segs.containing(2); // the 'b' word
        \\(parts.length === 3 && parts[0].segment === 'a' && parts[0].isWordLike === true &&
        \\ parts[1].segment === ' ' && parts[1].isWordLike === false &&
        \\ parts[0].index === 0 && parts[2].index === 2 &&
        \\ c.segment === 'b' && c.index === 2 &&
        \\ segs.containing(100) === undefined) ? 1 : 0
    );
}

test "intl: Segments + SegmentIterator have the right prototype shape" {
    try requireIntlBuild();
    try evalAssert1(
        \\const g = new Intl.Segmenter('en');
        \\const segs = g.segment('abc');
        \\const it = segs[Symbol.iterator]();
        \\(typeof Object.getPrototypeOf(segs).containing === 'function' &&
        \\ it[Symbol.iterator]() === it &&
        \\ Object.prototype.toString.call(it) === '[object Segmenter String Iterator]' &&
        \\ [...g.segment('héllo')].length >= 5) ? 1 : 0
    );
}

// ── Intl.DurationFormat per-unit options + resolvedOptions ───────────────────

test "intl: DurationFormat resolves per-unit options + key order" {
    try requireIntlBuild();
    try evalAssert1(
        \\const ro = new Intl.DurationFormat('en', { style:'long', fractionalDigits:2 }).resolvedOptions();
        \\const keys = Object.keys(ro);
        \\(ro.years === 'long' && ro.yearsDisplay === 'auto' && ro.seconds === 'long' &&
        \\ ro.fractionalDigits === 2 &&
        \\ keys.indexOf('numberingSystem') < keys.indexOf('style') &&
        \\ keys.indexOf('style') < keys.indexOf('years') &&
        \\ keys.indexOf('years') < keys.indexOf('yearsDisplay') &&
        \\ new Intl.DurationFormat('en', {style:'digital'}).resolvedOptions().hours === 'numeric') ? 1 : 0
    );
}

test "intl: DurationFormat validates fractionalDigits" {
    try requireIntlBuild();
    try evalThrows("new Intl.DurationFormat('en', { fractionalDigits: -10 })");
    try evalThrows("new Intl.DurationFormat('en', { years: 'bogus' })");
}

// ── Intl.RelativeTimeFormat CLDR patterns (§17) ──────────────────────────────

test "intl: RelativeTimeFormat formats with CLDR relative patterns" {
    try requireFullBuild();
    try evalAssert1(
        \\const f = (o,v,u) => new Intl.RelativeTimeFormat('en', o).format(v,u);
        \\(f({}, 1000, 'second') === 'in 1,000 seconds' &&
        \\ f({}, -5, 'day') === '5 days ago' &&
        \\ f({}, 1, 'day') === 'in 1 day' &&
        \\ f({numeric:'auto'}, -1, 'day') === 'yesterday' &&
        \\ f({numeric:'auto'}, 0, 'day') === 'today' &&
        \\ f({}, 2, 'days') === 'in 2 days') ? 1 : 0
    );
}

test "intl: RelativeTimeFormat formatToParts + validation" {
    try requireFullBuild();
    try evalThrows("new Intl.RelativeTimeFormat('en').format(Infinity, 'day')");
    try evalThrows("new Intl.RelativeTimeFormat('en').format(1, 'bogus')");
    try evalAssert1(
        \\const p = new Intl.RelativeTimeFormat('en').formatToParts(1, 'day');
        \\(p[0].type === 'literal' && p[0].value === 'in ' &&
        \\ p[1].type === 'integer' && p[1].value === '1' && p[1].unit === 'day' &&
        \\ p[2].type === 'literal' &&
        \\ new Intl.RelativeTimeFormat('en',{numeric:'auto'}).formatToParts(-1,'day')[0].value === 'yesterday') ? 1 : 0
    );
}

test "intl: NumberFormat honors minimumGroupingDigits" {
    try requireFullBuild();
    try evalAssert1(
        \\const f = (l,v) => new Intl.NumberFormat(l).format(v);
        \\(f('en',1000) === '1,000' && f('en',10000) === '10,000' &&
        \\ f('pl',1000) === '1000' &&        // pl minimumGroupingDigits=2
        \\ f('pl',10000).replace(/ | /g,' ') === '10 000' &&
        \\ f('en',100).indexOf(',') === -1) ? 1 : 0
    );
}

test "intl: numberingSystem option — well-formed unknown falls back, malformed throws" {
    try requireFullBuild();
    // A known system is honoured; a malformed one throws; RTF reports it.
    try evalAssert1(
        \\const nf = new Intl.NumberFormat('en', { numberingSystem: 'arab' });
        \\const rtf = new Intl.RelativeTimeFormat('en', { numberingSystem: 'arab' });
        \\(nf.resolvedOptions().numberingSystem === 'arab' &&
        \\ rtf.resolvedOptions().numberingSystem === 'arab') ? 1 : 0
    );
    try evalThrows("new Intl.NumberFormat('en', { numberingSystem: 'a' })"); // too short
    try evalThrows("new Intl.RelativeTimeFormat('en', { numberingSystem: '!!' })"); // non-alnum
}

test "intl: constructors coerce a primitive options arg (CoerceOptionsToObject)" {
    try requireIntlBuild();
    // §9.2.13 — a primitive options coerces to a wrapper (no relevant options)
    // rather than throwing, for the constructors whose spec text coerces.
    try evalAssert1(
        \\let ok = 1;
        \\for (const o of [true, 'x', 7, Symbol()]) {
        \\  try {
        \\    new Intl.NumberFormat('en', o);
        \\    new Intl.DateTimeFormat('en', o);
        \\    new Intl.RelativeTimeFormat('en', o);
        \\  } catch (e) { ok = 0; }
        \\}
        \\ok
    );
}

test "intl: tag with duplicate singleton or 4-alpha language is invalid" {
    try requireIntlBuild();
    // A singleton extension may appear at most once; a 4-ALPHA primary subtag
    // is the reserved slot and not a valid language.
    try testing.expect(!intl.isStructurallyValidLanguageTag("de-DE-u-kn-true-U-kn-true"));
    try testing.expect(!intl.isStructurallyValidLanguageTag("hans-cmn-cn"));
    try testing.expect(intl.isStructurallyValidLanguageTag("en-a-bbb-u-co-phonebk")); // distinct singletons ok
    try evalThrows("new Intl.Locale('de-u-kn-U-kn')");
}

test "intl: NumberFormat roundingIncrement rounds to the increment grid" {
    try requireFullBuild();
    try evalAssert1(
        \\const f = (inc, v) => new Intl.NumberFormat('en', {
        \\  maximumFractionDigits: 2, minimumFractionDigits: 2, roundingIncrement: inc
        \\}).format(v);
        \\(f(5, 1.23) === '1.25' && f(5, 1.27) === '1.25' &&
        \\ f(25, 1.18) === '1.25' && f(50, 7.30) === '7.50' &&
        \\ new Intl.NumberFormat('en').format(1.235) === '1.235') ? 1 : 0
    );
}

test "intl: useGrouping resolution + min2" {
    try requireIntlBuild();
    try evalAssert1(
        \\const r = (o) => new Intl.NumberFormat(undefined, { useGrouping: o }).resolvedOptions().useGrouping;
        \\(r('min2') === 'min2' && r(true) === 'always' && r(false) === false &&
        \\ r(undefined) === 'auto' && r('true') === 'auto' && r(0) === false) ? 1 : 0
    );
}

test "intl: NumberFormat roundingPriority more/lessPrecision" {
    try requireFullBuild();
    try evalAssert1(
        \\const f = (p) => new Intl.NumberFormat('en', {
        \\  maximumSignificantDigits: 2, maximumFractionDigits: 2, roundingPriority: p
        \\}).format(1.625);
        \\const ro = new Intl.NumberFormat('en', {
        \\  maximumSignificantDigits: 2, maximumFractionDigits: 2, roundingPriority: 'morePrecision'
        \\}).resolvedOptions();
        \\(f('morePrecision') === '1.63' && f('lessPrecision') === '1.6' &&
        \\ ro.roundingPriority === 'morePrecision' && ro.maximumSignificantDigits === 2 &&
        \\ ro.maximumFractionDigits === 2 &&
        \\ new Intl.NumberFormat('en').resolvedOptions().roundingPriority === 'auto') ? 1 : 0
    );
}

test "intl: NumberFormat scientific + engineering notation" {
    try requireFullBuild();
    try evalAssert1(
        \\const f = (n, v) => new Intl.NumberFormat('en', { notation: n }).format(v);
        \\(f('scientific', 987654321) === '9.877E8' &&
        \\ f('scientific', 0.000345) === '3.45E-4' &&
        \\ f('scientific', -1234) === '-1.234E3' &&
        \\ f('engineering', 987654321) === '987.654E6' &&
        \\ f('engineering', 12345) === '12.345E3') ? 1 : 0
    );
    try evalAssert1(
        \\const p = new Intl.NumberFormat('en', { notation: 'scientific' }).formatToParts(1234);
        \\(p.map(x => x.type).join(',') === 'integer,decimal,fraction,exponentSeparator,exponentInteger') ? 1 : 0
    );
}

test "intl: NumberFormat compact notation (short/long/CJK + parts)" {
    try requireFullBuild();
    try evalAssert1(
        \\const s = v => new Intl.NumberFormat('en', { notation: 'compact' }).format(v);
        \\const l = v => new Intl.NumberFormat('en', { notation: 'compact', compactDisplay: 'long' }).format(v);
        \\(s(987654321) === '988M' && s(98765) === '99K' && s(1234) === '1.2K' &&
        \\ s(999999) === '1M' && s(100) === '100' &&
        \\ l(987654321) === '988 million' && l(1500) === '1.5 thousand' &&
        \\ new Intl.NumberFormat('ja', { notation: 'compact' }).format(12345) === '1.2万') ? 1 : 0
    );
    try evalAssert1(
        \\const p = new Intl.NumberFormat('en', { notation: 'compact', compactDisplay: 'long' }).formatToParts(987654321);
        \\(p.map(x => x.type).join(',') === 'integer,literal,compact' &&
        \\ p[2].value === 'million') ? 1 : 0
    );
    try evalAssert1(
        \\const o = new Intl.NumberFormat('en', { notation: 'compact' }).resolvedOptions();
        \\const k = Object.keys(o);
        \\(o.compactDisplay === 'short' && o.roundingPriority === 'morePrecision' &&
        \\ k.indexOf('minimumFractionDigits') < k.indexOf('minimumSignificantDigits') &&
        \\ k.indexOf('compactDisplay') === k.indexOf('notation') + 1) ? 1 : 0
    );
}

test "intl: NumberFormat unit style (single, compound, plural, validation)" {
    try requireFullBuild();
    try evalAssert1(
        \\const f = (u, d, v) => new Intl.NumberFormat('en', { style: 'unit', unit: u, unitDisplay: d }).format(v);
        \\(f('kilometer-per-hour', 'short', 987) === '987 km/h' &&
        \\ f('kilometer-per-hour', 'long', 987) === '987 kilometers per hour' &&
        \\ f('kilometer-per-hour', 'narrow', 987) === '987km/h' &&
        \\ f('meter', 'long', 1) === '1 meter' &&
        \\ f('meter', 'long', 5) === '5 meters' &&
        \\ f('kilometer', 'short', 5) === '5 km') ? 1 : 0
    );
    try evalAssert1(
        \\const p = new Intl.NumberFormat('en', { style: 'unit', unit: 'kilometer-per-hour' }).formatToParts(987);
        \\(p.map(x => x.type).join(',') === 'integer,literal,unit' && p[2].value === 'km/h') ? 1 : 0
    );
    // §6.5.1 — invalid identifier → RangeError; unit style with no unit → TypeError.
    try evalAssert1(
        \\let r = 0;
        \\try { new Intl.NumberFormat('en', { style: 'unit', unit: 'century' }); } catch (e) { if (e instanceof RangeError) r++; }
        \\try { new Intl.NumberFormat('en', { style: 'unit' }); } catch (e) { if (e instanceof TypeError) r++; }
        \\try { new Intl.NumberFormat('en', { unit: 'not-a-unit' }); } catch (e) { if (e instanceof RangeError) r++; }
        \\r === 3 ? 1 : 0
    );
}

test "intl: NumberFormat currency + roundingIncrement validation (§15.1)" {
    try requireIntlBuild();
    try evalAssert1(
        \\const thrown = (f) => { try { f(); return ''; } catch (e) { return e.constructor.name; } };
        \\// undefined currency under currency style → TypeError; present-but-"" → RangeError.
        \\(thrown(() => new Intl.NumberFormat('en', { style: 'currency' })) === 'TypeError' &&
        \\ thrown(() => new Intl.NumberFormat('en', { style: 'currency', currency: '' })) === 'RangeError' &&
        \\ // roundingIncrement: only sanctioned values; requires fractionDigits + equal min/max.
        \\ thrown(() => new Intl.NumberFormat('en', { roundingIncrement: 3 })) === 'RangeError' &&
        \\ thrown(() => new Intl.NumberFormat('en', { roundingIncrement: 2, roundingPriority: 'morePrecision' })) === 'TypeError' &&
        \\ thrown(() => new Intl.NumberFormat('en', { roundingIncrement: 2, minimumSignificantDigits: 2 })) === 'TypeError' &&
        \\ thrown(() => new Intl.NumberFormat('en', { roundingIncrement: 25, minimumFractionDigits: 2, maximumFractionDigits: 2 })) === '') ? 1 : 0
    );
}

test "intl: NumberFormat formatRange / formatRangeToParts (§15.5.8)" {
    try requireIntlBuild();
    try evalAssert1(
        \\const nf = new Intl.NumberFormat('en');
        \\const thrown = (f) => { try { f(); return ''; } catch (e) { return e.constructor.name; } };
        \\(nf.formatRange.length === 2 && nf.formatRange.name === 'formatRange' &&
        \\ typeof nf.formatRange(3, 5) === 'string' &&
        \\ typeof nf.formatRange(23, 12) === 'string' &&        // x > y does not throw
        \\ typeof nf.formatRange(23n, 12n) === 'string' &&      // BigInt operands
        \\ typeof nf.formatRange(0, -0) === 'string' &&
        \\ thrown(() => nf.formatRange(NaN, 5)) === 'RangeError' &&
        \\ thrown(() => nf.formatRange(undefined, 5)) === 'TypeError' &&
        \\ thrown(() => nf.formatRange(Symbol(), 5)) === 'TypeError') ? 1 : 0
    );
    try evalAssert1(
        \\const nf = new Intl.NumberFormat('en');
        \\const p = nf.formatRangeToParts(3, 5);
        \\(p.length === 3 && p[0].source === 'startRange' && p[1].source === 'shared' &&
        \\ p[2].source === 'endRange' && p[0].type === 'integer' && p[2].value === '5') ? 1 : 0
    );
}

test "intl: DurationFormat format (long/digital/mixed/fraction/negative)" {
    try requireFullBuild();
    try evalAssert1(
        \\const f = (o, d) => new Intl.DurationFormat('en', o).format(d);
        \\(f({ style: 'long' }, { hours: 1, minutes: 46, seconds: 40 }) === '1 hour, 46 minutes, 40 seconds' &&
        \\ f({ style: 'digital' }, { hours: 1, minutes: 2, seconds: 3 }) === '1:02:03' &&
        \\ f({ minutes: 'numeric', seconds: 'numeric' }, { days: 5, hours: 1, minutes: 2, seconds: 3 }) === '5 days, 1 hr, 2:03' &&
        \\ f({ style: 'digital' }, { minutes: 1, seconds: 30, milliseconds: 500 }) === '0:01:30.5' &&
        \\ f({ style: 'long' }, { hours: -1, minutes: -30 }) === '-1 hour, 30 minutes') ? 1 : 0
    );
    // §1.1.6 ToDurationRecord validation.
    try evalAssert1(
        \\const thrown = (f) => { try { f(); return ''; } catch (e) { return e.constructor.name; } };
        \\const df = new Intl.DurationFormat('en');
        \\(thrown(() => df.format({ hours: 1.5 })) === 'RangeError' &&
        \\ thrown(() => df.format({ hours: 1, minutes: -2 })) === 'RangeError' &&
        \\ thrown(() => df.format({})) === 'TypeError') ? 1 : 0
    );
}

test "intl: DurationFormat formatToParts (typed parts + unit tags)" {
    try requireFullBuild();
    try evalAssert1(
        \\const p = new Intl.DurationFormat('en', { style: 'long' }).formatToParts({ hours: 1, minutes: 46 });
        \\(p[0].type === 'integer' && p[0].value === '1' && p[0].unit === 'hour' &&
        \\ p[2].type === 'unit' && p[2].unit === 'hour' &&
        \\ p.some(x => x.type === 'literal' && x.value === ', ' && x.unit === undefined) &&
        \\ p[p.length - 1].unit === 'minute') ? 1 : 0
    );
    try evalAssert1(
        \\const p = new Intl.DurationFormat('en', { style: 'digital' }).formatToParts({ hours: 1, minutes: 2, seconds: 3 });
        \\// Digital clock: "1:02:03" with ":" separators carrying no unit.
        \\(p.map(x => x.value).join('') === '1:02:03' &&
        \\ p[0].unit === 'hour' && p[1].type === 'literal' && p[1].value === ':' && p[1].unit === undefined &&
        \\ p[2].value === '02' && p[2].unit === 'minute') ? 1 : 0
    );
}

test "intl: DateTimeFormat formatRange + option validation (§11.1/§11.5)" {
    try requireFullBuild();
    try evalAssert1(
        \\const dtf = new Intl.DateTimeFormat('en');
        \\const thrown = (f) => { try { f(); return ''; } catch (e) { return e.constructor.name; } };
        \\(dtf.formatRange.length === 2 &&
        \\ typeof dtf.formatRange(new Date(2020, 0, 1), new Date(2020, 0, 5)) === 'string' &&
        \\ typeof dtf.formatRange(Date.now(), Date.now() - 1000) === 'string' &&   // x > y ok
        \\ thrown(() => dtf.formatRange(undefined, Date.now())) === 'TypeError' &&
        \\ thrown(() => dtf.formatRange(NaN, Date.now())) === 'RangeError') ? 1 : 0
    );
    try evalAssert1(
        \\const same = new Date(2020, 5, 15);
        \\const r = new Intl.DateTimeFormat('en').formatRange(same, same);
        \\(r === new Intl.DateTimeFormat('en').format(same)) ? 1 : 0   // identical → single date
    );
    try evalAssert1(
        \\const thrown = (f) => { try { f(); return ''; } catch (e) { return e.constructor.name; } };
        \\(thrown(() => new Intl.DateTimeFormat('en', { weekday: 'short', dateStyle: 'short' })) === 'TypeError' &&
        \\ thrown(() => new Intl.DateTimeFormat('en', { formatMatcher: 'bad' })) === 'RangeError') ? 1 : 0
    );
}

test "intl: DateTimeFormat formatRangeToParts source tags (§11.5.6)" {
    try requireFullBuild();
    try evalAssert1(
        \\const dtf = new Intl.DateTimeFormat('en');
        \\const p = dtf.formatRangeToParts(new Date(2020, 0, 1), new Date(2020, 0, 5));
        \\(p.every(x => typeof x.type === 'string' && typeof x.value === 'string') &&
        \\ p.some(x => x.source === 'startRange') &&
        \\ p.some(x => x.source === 'shared') &&
        \\ p.some(x => x.source === 'endRange')) ? 1 : 0
    );
    try evalAssert1(
        \\const same = new Date(2020, 0, 1);
        \\const p = new Intl.DateTimeFormat('en').formatRangeToParts(same, same);
        \\(p.length > 0 && p.every(x => x.source === 'shared')) ? 1 : 0
    );
}

test "intl: DateTimeFormat fractionalSecondDigits (§11.5.5)" {
    try requireFullBuild();
    try evalAssert1(
        \\const d = new Date(Date.UTC(2020, 0, 1, 13, 5, 9, 123));
        \\const f = (n) => new Intl.DateTimeFormat('en', { minute: '2-digit', second: '2-digit', fractionalSecondDigits: n, timeZone: 'UTC' }).format(d);
        \\(f(3) === '05:09.123' && f(1) === '05:09.1' && f(2) === '05:09.12') ? 1 : 0
    );
    try evalAssert1(
        \\const d = new Date(Date.UTC(2020, 0, 1, 13, 5, 9, 123));
        \\const p = new Intl.DateTimeFormat('en', { second: '2-digit', fractionalSecondDigits: 3, timeZone: 'UTC' }).formatToParts(d);
        \\const fs = p.find(x => x.type === 'fractionalSecond');
        \\(fs && fs.value === '123' && p.some(x => x.type === 'literal' && x.value === '.') &&
        \\ new Intl.DateTimeFormat('en', { fractionalSecondDigits: 3 }).resolvedOptions().fractionalSecondDigits === 3) ? 1 : 0
    );
}

test "intl: DateTimeFormat timeZone validation + canonicalization (§11.1.1)" {
    try requireFullBuild();
    try evalAssert1(
        \\const r = (tz) => new Intl.DateTimeFormat('en', { timeZone: tz }).resolvedOptions().timeZone;
        \\const thrown = (tz) => { try { r(tz); return ''; } catch (e) { return e.constructor.name; } };
        \\(r('utc') === 'UTC' &&
        \\ r('AFRICA/ABIDJAN') === 'Africa/Abidjan' &&   // case-insensitive match → available casing
        \\ r('Etc/UTC') === 'Etc/UTC' && r('GMT') === 'GMT' &&   // aliases preserved, not collapsed
        \\ r('+0300') === '+03:00' &&                    // offset normalized
        \\ thrown('MEZ') === 'RangeError' && thrown('ACT') === 'RangeError') ? 1 : 0
    );
}

test "intl: DateTimeFormat partial component selection (§11.1.1 pattern build)" {
    try requireFullBuild();
    // Unrequested fields (and their separators) must be dropped, not re-parsed
    // from a spanning literal — the bug produced "01:05:9PM" for hour-only.
    try evalAssert1(
        \\const d = new Date(Date.UTC(2020, 0, 1, 13, 5, 9, 0));
        \\const f = (o) => new Intl.DateTimeFormat('en', { ...o, timeZone: 'UTC' }).format(d);
        \\// Space-agnostic (CLDR uses U+202F before the day period): the point is
        \\// that unrequested fields don't leak back in via the separator literal.
        \\const hourOnly = f({ hour: '2-digit', hourCycle: 'h12' });
        \\const hm = f({ hour: 'numeric', minute: '2-digit' });
        \\(hourOnly.startsWith('01') && hourOnly.endsWith('PM') && !hourOnly.includes(':') &&
        \\ hm.startsWith('1:05') && hm.endsWith('PM') && !hm.includes(':09') &&
        \\ f({ hour: 'numeric', minute: '2-digit', second: '2-digit' }).startsWith('1:05:09') &&
        \\ f({ minute: '2-digit' }) === '05') ? 1 : 0
    );
}

test "intl: DateTimeFormat formats Temporal objects (§11.5.x bridge)" {
    try requireFullBuild();
    try evalAssert1(
        \\const pd = new Temporal.PlainDate(2024, 9, 19);
        \\const pt = new Temporal.PlainTime(12, 23, 37);
        \\const pdt = new Temporal.PlainDateTime(2024, 9, 19, 12, 23, 37);
        \\const pym = new Temporal.PlainYearMonth(2024, 9);
        \\const pmd = new Temporal.PlainMonthDay(9, 19);
        \\const thrown = (f) => { try { f(); return ''; } catch (e) { return e.constructor.name; } };
        \\const ds = (o, v) => new Intl.DateTimeFormat('en', { ...o, calendar: 'iso8601', timeZone: 'UTC' }).format(v);
        \\(ds({ dateStyle: 'short' }, pd) === '9/19/24' &&
        \\ ds({ year: 'numeric' }, pym) === '2024' &&
        \\ ds({ day: '2-digit' }, pmd) === '19' &&
        \\ ds({ timeStyle: 'short' }, pt).startsWith('12:23') &&        // space before PM is U+202F
        \\ ds({ dateStyle: 'short', timeStyle: 'short' }, pdt).startsWith('9/19/24, 12:23') &&
        \\ // no field overlap → TypeError; ZonedDateTime unsupported → TypeError
        \\ thrown(() => ds({ dateStyle: 'short' }, pt)) === 'TypeError' &&
        \\ thrown(() => ds({ year: 'numeric' }, pmd)) === 'TypeError' &&
        \\ thrown(() => ds({ dateStyle: 'short' }, new Temporal.ZonedDateTime(0n, 'UTC'))) === 'TypeError') ? 1 : 0
    );
}

test "intl: DateTimeFormat formatRange of Temporal objects (§11.5.6)" {
    try requireFullBuild();
    try evalAssert1(
        \\const dtf = new Intl.DateTimeFormat('en', { dateStyle: 'short', calendar: 'iso8601', timeZone: 'UTC' });
        \\const pd1 = new Temporal.PlainDate(2024, 1, 1), pd2 = new Temporal.PlainDate(2024, 1, 5);
        \\const pt = new Temporal.PlainTime(12, 0);
        \\const thrown = (f) => { try { f(); return ''; } catch (e) { return e.constructor.name; } };
        \\(dtf.formatRange(pd1, pd2) === '1/1/24 – 1/5/24' &&
        \\ // distinct Temporal types, and Temporal mixed with legacy → TypeError
        \\ thrown(() => dtf.formatRange(pd1, pt)) === 'TypeError' &&
        \\ thrown(() => dtf.formatRange(pd1, Date.now())) === 'TypeError') ? 1 : 0
    );
    try evalAssert1(
        \\const dtf = new Intl.DateTimeFormat('en', { dateStyle: 'short', calendar: 'iso8601', timeZone: 'UTC' });
        \\const p = dtf.formatRangeToParts(new Temporal.PlainDate(2024, 1, 1), new Temporal.PlainDate(2024, 1, 5));
        \\(p.some(x => x.source === 'startRange') && p.some(x => x.source === 'shared') &&
        \\ p.some(x => x.source === 'endRange')) ? 1 : 0
    );
}

test "intl: DateTimeFormat calendar option validation + canonicalization (§11.1.1)" {
    try requireFullBuild();
    try evalAssert1(
        \\const cal = (c) => new Intl.DateTimeFormat('en', { calendar: c }).resolvedOptions().calendar;
        \\const thrown = (c) => { try { cal(c); return ''; } catch (e) { return e.constructor.name; } };
        \\(cal('islamicc') === 'islamic-civil' &&   // deprecated alias → preferred
        \\ cal('ISO8601') === 'iso8601' &&          // ASCII-lowercased
        \\ cal('gregory') === 'gregory' &&
        \\ cal('ethioaa') === 'ethioaa' &&          // already-preferred id round-trips
        \\ thrown('bad!') === 'RangeError' &&        // not a well-formed Unicode type
        \\ thrown('İSO8601') === 'RangeError') ? 1 : 0   // capital dotted-I is non-ASCII
    );
}

test "intl: DateTimeFormat timeZoneName rendering (§11.5.x offsets + UTC)" {
    try requireFullBuild();
    try evalAssert1(
        \\const d = Date.UTC(2026, 0, 5, 12, 0);
        \\const f = (s, tz) => new Intl.DateTimeFormat('en', { timeZoneName: s, timeZone: tz || 'UTC' }).format(d);
        \\(f('long').endsWith('Coordinated Universal Time') &&
        \\ f('short').endsWith('UTC') &&
        \\ f('shortOffset').endsWith('GMT') &&
        \\ f('shortOffset', 'America/New_York').endsWith('GMT-5') &&
        \\ f('longOffset', 'America/New_York').endsWith('GMT-05:00')) ? 1 : 0
    );
    try evalAssert1(
        \\// A PlainDate has no zone: timeZoneName must not appear.
        \\const r = new Intl.DateTimeFormat('en', { timeZoneName: 'long' }).format(new Temporal.PlainDate(2026, 1, 5));
        \\(r.indexOf('Coordinated') === -1 && r.indexOf('GMT') === -1) ? 1 : 0
    );
}

test "intl: DateTimeFormat PlainTime defaults to time components (§11.5.x)" {
    try requireFullBuild();
    try evalAssert1(
        \\const pt = new Temporal.PlainTime(12, 23, 37);
        \\const thrown = (f) => { try { f(); return ''; } catch (e) { return e.constructor.name; } };
        \\// {timeZoneName} alone → PlainTime renders default time, zone omitted (no throw).
        \\const r = new Intl.DateTimeFormat('en', { timeZoneName: 'long' }).format(pt);
        \\(r.startsWith('12:23') && r.indexOf('Coordinated') === -1 &&
        \\ // an explicit *date* component still has no overlap with a PlainTime → TypeError
        \\ thrown(() => new Intl.DateTimeFormat('en', { year: 'numeric' }).format(pt)) === 'TypeError') ? 1 : 0
    );
}

test "intl: format function name is empty + dateStyle/component conflict (§11.1)" {
    try requireIntlBuild();
    try evalAssert1(
        \\// §11.1.5 / §15.1.4 — the bound format accessor function has name "".
        \\const d = Object.getOwnPropertyDescriptor(new Intl.DateTimeFormat('en').format, 'name');
        \\const n = Object.getOwnPropertyDescriptor(new Intl.NumberFormat('en').format, 'name');
        \\(d.value === '' && d.writable === false && d.enumerable === false && d.configurable === true &&
        \\ n.value === '') ? 1 : 0
    );
    try evalAssert1(
        \\const thrown = (o) => { try { new Intl.DateTimeFormat('en', o); return ''; } catch (e) { return e.constructor.name; } };
        \\// dateStyle/timeStyle conflicts with any explicit component, incl. fractionalSecondDigits.
        \\(thrown({ dateStyle: 'full', fractionalSecondDigits: 3 }) === 'TypeError' &&
        \\ thrown({ timeStyle: 'full', weekday: 'long' }) === 'TypeError') ? 1 : 0
    );
}

test "intl: NumberFormat roundingIncrement halfway precision (§15.1.1)" {
    try requireIntlBuild();
    try evalAssert1(
        \\const f = (v) => new Intl.NumberFormat('en', { minimumFractionDigits: 2, maximumFractionDigits: 2, roundingIncrement: 10 }).format(v);
        \\// 1.15 is 1.1499… in f64; the decimal value is an exact halfway → 1.20.
        \\(f(1.15) === '1.20' && f(1.125) === '1.10' && f(1.175) === '1.20' && f(1.1) === '1.10') ? 1 : 0
    );
}

test "intl: NumberFormat roundingMode with significant digits (§15.1.1)" {
    try requireIntlBuild();
    try evalAssert1(
        \\const f = (v, m) => new Intl.NumberFormat('en', { useGrouping: false, roundingMode: m, maximumSignificantDigits: 2 }).format(v);
        \\(f(1.101, 'ceil') === '1.2' && f(1.19, 'floor') === '1.1' &&
        \\ f(1.11, 'expand') === '1.2' && f(1.1999, 'trunc') === '1.1' &&
        \\ f(1.15, 'halfEven') === '1.2' && f(1.15, 'halfTrunc') === '1.1' &&
        \\ f(1.15, 'halfExpand') === '1.2') ? 1 : 0
    );
}

test "intl: NumberFormat roundingMode sign-aware + fraction digits (§15.1.1)" {
    try requireIntlBuild();
    try evalAssert1(
        \\const f = (v, m, o) => new Intl.NumberFormat('en', { useGrouping: false, roundingMode: m, ...o }).format(v);
        \\// Negatives swap ceil/floor (round toward ±∞ on the number line).
        \\(f(-1.101, 'floor', { maximumSignificantDigits: 2 }) === '-1.2' &&
        \\ f(-1.101, 'ceil', { maximumSignificantDigits: 2 }) === '-1.1' &&
        \\ f(-1.101, 'floor', { maximumFractionDigits: 2, minimumFractionDigits: 2 }) === '-1.11' &&
        \\ f(-1.105, 'ceil', { maximumFractionDigits: 2, minimumFractionDigits: 2 }) === '-1.10' &&
        \\ f(2.5, 'halfExpand', { maximumFractionDigits: 0 }) === '3' &&
        \\ f(1.005, 'halfExpand', { maximumFractionDigits: 2, minimumFractionDigits: 2 }) === '1.01') ? 1 : 0
    );
}

test "intl: NumberFormat compact min2 grouping + no-compaction buckets (§15.1)" {
    try requireFullBuild();
    try evalAssert1(
        \\const c = (loc, v) => new Intl.NumberFormat(loc, { notation: 'compact' }).format(v);
        \\// compact defaults useGrouping:"min2" → no group below ~10,000; Japanese
        \\// has no compact form below 万 (10⁴) so 9876 renders in full.
        \\(c('ja', 9876) === '9876' && c('ja', 12345) === '1.2万' &&
        \\ c('en', 9876) === '9.9K' && c('en', 999) === '999' &&
        \\ c('de', 1000000).endsWith('Mio.')) ? 1 : 0   // de uses U+00A0 before "Mio."
    );
}

test "intl: NumberFormat drops irrelevant/invalid -u- extensions (§9.2.7)" {
    try requireFullBuild();
    try evalAssert1(
        \\const r = (l) => new Intl.NumberFormat([l]).resolvedOptions().locale;
        \\(r('ja-JP-u-cu-usd') === 'ja-JP' &&            // cu irrelevant to NumberFormat
        \\ r('ja-JP-u-nu-invalid') === 'ja-JP' &&        // nu relevant but unsupported value
        \\ r('ja-JP-u-nu-native') === 'ja-JP' &&
        \\ r('ja-JP-u-nu-latn') === 'ja-JP-u-nu-latn' && // valid nu retained
        \\ r('ar-u-nu-arab') === 'ar-u-nu-arab') ? 1 : 0
    );
}

test "intl: Collator/DateTimeFormat drop irrelevant -u- extensions (§9.2.7)" {
    try requireFullBuild();
    try evalAssert1(
        \\const co = (l) => new Intl.Collator([l]).resolvedOptions().locale;
        \\const dt = (l) => new Intl.DateTimeFormat([l]).resolvedOptions().locale;
        \\(co('de-u-cu-usd') === 'de' && co('de-u-ka-shifted') === 'de' &&   // irrelevant to Collator
        \\ co('de-u-co-phonebk') === 'de-u-co-phonebk' &&                    // relevant + valid
        \\ dt('ja-JP-u-cu-usd') === 'ja-JP' &&                              // irrelevant to DateTimeFormat
        \\ dt('ja-JP-u-ca-japanese') === 'ja-JP-u-ca-japanese') ? 1 : 0     // relevant + valid
    );
}

test "intl: Collator kn/kf resolved locale canonicalization (§9.2.7)" {
    try requireFullBuild();
    try evalAssert1(
        \\const loc = (l, opt) => new Intl.Collator([l], opt).resolvedOptions().locale;
        \\// [[locale]] reflects the LOCALE keyword (true/bare → "-u-kn", false dropped);
        \\// an option sets [[numeric]] but never [[locale]].
        \\(loc('en-u-kn-true') === 'en-u-kn' && loc('en-u-kn-false') === 'en' &&
        \\ loc('en-u-kn-true', { numeric: false }) === 'en-u-kn' &&
        \\ loc('en-u-kn-false', { numeric: true }) === 'en' &&
        \\ loc('en-u-kf-lower') === 'en-u-kf-lower' && loc('en-u-kf-false') === 'en') ? 1 : 0
    );
}

test "intl: Collator ignorePunctuation locale default (§10.1.1)" {
    try requireIntlBuild();
    try evalAssert1(
        \\const ip = (l) => new Intl.Collator(l).resolvedOptions().ignorePunctuation;
        \\// Thai's root collation shifts punctuation → default true; others false.
        \\(ip('th') === true && ip('th-TH') === true && ip('en') === false && ip('ja') === false) ? 1 : 0
    );
}

test "intl: Locale numeric canonicalization + firstDayOfWeek (§14.1)" {
    try requireIntlBuild();
    try evalAssert1(
        \\const t = (opt) => new Intl.Locale('en', opt).toString();
        \\const thrown = (opt) => { try { t(opt); return ''; } catch (e) { return e.constructor.name; } };
        \\(t({ numeric: true }) === 'en-u-kn' &&             // canonical bare keyword
        \\ t({ numeric: false }) === 'en-u-kn-false' &&
        \\ t({ firstDayOfWeek: 'mon' }) === 'en-u-fw-mon' &&
        \\ t({ firstDayOfWeek: 1 }) === 'en-u-fw-mon' &&     // numeric 1..7 → mon..sun
        \\ t({ firstDayOfWeek: 7 }) === 'en-u-fw-sun' &&
        \\ t({ firstDayOfWeek: true }) === 'en-u-fw' &&        // "true" → bare keyword
        \\ t({ firstDayOfWeek: 'frank' }) === 'en-u-fw-frank' && // arbitrary fw type passes through
        \\ thrown({ firstDayOfWeek: 'x' }) === 'RangeError' &&  // not a valid -u- type subtag
        \\ thrown({ firstDayOfWeek: 8 }) === 'RangeError' &&
        \\ new Intl.Locale('en-u-fw-tue').firstDayOfWeek === 'tue' &&        // getter reads -u-fw
        \\ new Intl.Locale('en', { firstDayOfWeek: '3' }).firstDayOfWeek === 'wed' &&
        \\ new Intl.Locale('en').firstDayOfWeek === undefined &&             // absent → undefined
        \\ new Intl.Locale('en-u-fw-thu').getWeekInfo().firstDay === 4 &&    // getWeekInfo reflects it
        \\ new Intl.Locale('en').getWeekInfo().firstDay === 1) ? 1 : 0       // default Monday
    );
}

test "intl: getCanonicalLocales -u- type canonicalization (§3.2.1)" {
    try requireIntlBuild();
    try evalAssert1(
        \\const g = (t) => Intl.getCanonicalLocales(t)[0];
        \\(g('und-u-kb-yes') === 'und-u-kb' &&            // yes → true → dropped (boolean key)
        \\ g('und-u-kn-true') === 'und-u-kn' &&           // default true dropped
        \\ g('und-u-ks-primary') === 'und-u-ks-level1' && // collation-strength alias
        \\ g('und-u-ks-tertiary') === 'und-u-ks-level3' &&
        \\ g('und-u-ms-imperial') === 'und-u-ms-uksystem' && // measurement-system alias
        \\ g('de-u-co-phonebk') === 'de-u-co-phonebk' && // non-aliased type untouched
        \\ g('en-u-0c') === 'en-u-0c' &&                 // alphanum-alpha key is valid
        \\ (() => { try { Intl.getCanonicalLocales('en-u-c0'); return false; } // key must end in a letter
        \\          catch (e) { return e.constructor.name === 'RangeError'; } })() &&
        \\ (() => { try { Intl.getCanonicalLocales('en-u-00'); return false; }
        \\          catch (e) { return e.constructor.name === 'RangeError'; } })()) ? 1 : 0
    );
}

test "intl: DateTimeFormat flexible dayPeriod for en (§11.x)" {
    try requireFullBuild();
    try evalAssert1(
        \\const at = (h, o) => new Intl.DateTimeFormat('en', Object.assign({ dayPeriod: 'long' }, o)).format(new Date(2017, 11, 12, h, 0, 0));
        \\const set = [...Array(24).keys()].map((h) => at(h)).filter((v, i, a) => a.indexOf(v) === i).join(',');
        \\(set === 'in the morning,noon,in the afternoon,in the evening,at night' &&
        \\ at(0) === 'in the morning' &&        // midnight absorbed into morning
        \\ at(12) === 'noon' &&
        \\ new Intl.DateTimeFormat('en', { dayPeriod: 'narrow' }).format(new Date(2017, 11, 12, 12, 0, 0)) === 'n' &&
        \\ at(0, { hour: 'numeric' }) === '12 in the morning') ? 1 : 0 // hB skeleton: plain-space separator
    );
}

test "intl: DateTimeFormat hourCycle applied to timeStyle (§11.1.1)" {
    try requireFullBuild();
    try evalAssert1(
        \\const d = new Date("1886-05-01T14:12:47Z");
        \\const f = (loc, o) => new Intl.DateTimeFormat(loc, Object.assign({ timeStyle: 'short', timeZone: 'UTC' }, o)).format(d);
        \\(f('en-US', {}).startsWith('2:12') &&                 // en default → 12-hour
        \\ f('en-US-u-hc-h23', {}) === '14:12' &&               // locale -u-hc → 24-hour, dayPeriod dropped
        \\ f('en-US-u-hc-h11', {}).startsWith('2:12') &&        // h11 → 12-hour
        \\ f('en-US', { hour12: false }) === '14:12' &&         // option → 24-hour
        \\ f('en-US-u-hc-h23', { hour12: true }).startsWith('2:12') && // hour12 overrides -u-hc
        \\ f('en-US', { hourCycle: 'h23' }) === '14:12' &&
        \\ new Intl.DateTimeFormat('en-US-u-hc-h23', { timeStyle: 'short' }).resolvedOptions().hourCycle === 'h23') ? 1 : 0
    );
}

test "intl: DateTimeFormat timeStyle tz-name width from pattern (§11.1.1)" {
    try requireFullBuild();
    try evalAssert1(
        \\const d = new Date(Date.UTC(1886, 4, 1, 14, 12, 47));
        \\const f = (o) => new Intl.DateTimeFormat('en', Object.assign({ timeZone: 'UTC' }, o)).format(d);
        \\(f({ timeStyle: 'full' }).endsWith('Coordinated Universal Time') && // zzzz → long
        \\ f({ timeStyle: 'long' }).endsWith('UTC') &&                        // z → short
        \\ f({ hour: 'numeric', timeZoneName: 'long' }).endsWith('Coordinated Universal Time') &&
        \\ f({ hour: 'numeric', timeZoneName: 'short' }).endsWith('UTC')) ? 1 : 0 // explicit option unchanged
    );
}

test "intl: DateTimeFormat minute/second 2-digit when combined (§11.1.1)" {
    try requireFullBuild();
    try evalAssert1(
        \\const d = new Date(2000, 0, 1, 5, 3, 4);
        \\const f = (o) => new Intl.DateTimeFormat('en', o).format(d);
        \\(f({ minute: 'numeric' }) === '3' &&                      // sole field → 1-digit
        \\ f({ second: 'numeric' }) === '4' &&
        \\ f({ minute: 'numeric', second: 'numeric' }) === '03:04' && // combined → 2-digit
        \\ f({ hour: 'numeric', minute: 'numeric' }).startsWith('5:03') && // minute after hour → 2-digit
        \\ new Intl.DateTimeFormat('en', { minute: 'numeric', second: 'numeric', fractionalSecondDigits: 2 })
        \\   .format(new Date(2000, 0, 1, 0, 2, 3, 456)) === '02:03.45') ? 1 : 0
    );
}

test "intl: -t- transformed extension content is lowercase (§unicode_locale_id)" {
    try requireIntlBuild();
    try evalAssert1(
        \\const g = (t) => Intl.getCanonicalLocales(t)[0];
        \\(g('en-t-en') === 'en-t-en' &&                       // tlang language not region-uppercased
        \\ g('en-t-en-latn') === 'en-t-en-latn' &&             // -t- script stays lowercase
        \\ g('und-Latn-t-und-hani') === 'und-Latn-t-und-hani' && // outer script Title, inner lower
        \\ g('en-t-d0-ascii') === 'en-t-d0-ascii' &&
        \\ g('en-CA') === 'en-CA') ? 1 : 0                     // outer region still uppercased
    );
}

test "intl: 3-alpha extlang after language is invalid (§unicode_language_id)" {
    try requireIntlBuild();
    try evalAssert1(
        \\const inv = (t) => { try { Intl.getCanonicalLocales(t); return false; } catch (e) { return e.constructor.name === 'RangeError'; } };
        \\(inv('en-els') &&                                 // 3-alpha extlang → invalid
        \\ inv('en-abc') &&
        \\ inv('no-nyn') && inv('zh-min-nan') &&            // regular grandfathered, 3-alpha → invalid
        \\ inv('i-klingon') && inv('en-GB-oed') &&          // irregular grandfathered → invalid
        \\ Intl.getCanonicalLocales('yue')[0] === 'yue' &&  // a 3-alpha LANGUAGE subtag is valid
        \\ Intl.getCanonicalLocales('art-lojban')[0] === 'jbo' && // valid grandfathered still canonicalizes
        \\ Intl.getCanonicalLocales('en-US')[0] === 'en-US' &&
        \\ Intl.getCanonicalLocales('de-1901')[0] === 'de-1901') ? 1 : 0 // 4-digit variant valid
    );
}

test "intl: territory-alias region canonicalization (§3.2.1)" {
    try requireFullBuild(); // CLDR territoryAlias table is in the embedded blob
    try evalAssert1(
        \\const g = (t) => Intl.getCanonicalLocales(t)[0];
        \\(new Intl.Locale('en', { region: '554' }).toString() === 'en-NZ' && // numeric → alpha
        \\ g('en-UK') === 'en-GB' && g('en-BU') === 'en-MM' &&                // deprecated → current
        \\ g('ru-SU') === 'ru-RU' &&                                         // 1→many: ru's likely territory is in the list
        \\ g('en-SU') === 'en-RU' &&                                         // 1→many: en's likely (US) absent → first
        \\ g('und-Latn-SU') === 'und-Latn-RU' &&
        \\ g('en-FR') === 'en-FR' && g('en-US') === 'en-US') ? 1 : 0          // no alias → unchanged
    );
}

test "intl: language tag variants sorted in canonical form (§unicode_language_id)" {
    try requireIntlBuild();
    try evalAssert1(
        \\const g = (t) => Intl.getCanonicalLocales(t)[0];
        \\(g('de-1996-1901') === 'de-1901-1996' &&              // variants sorted alphabetically
        \\ g('sl-rozaj-biske-1994') === 'sl-1994-biske-rozaj' &&
        \\ new Intl.Locale('xx', { variants: '1xyz-1234-abcde-12345678' }).toString() === 'xx-1234-12345678-1xyz-abcde' &&
        \\ g('en') === 'en' && g('en-US') === 'en-US' &&        // no variants → unchanged (no crash)
        \\ g('de-1901') === 'de-1901') ? 1 : 0                  // single variant → unchanged
    );
}

test "intl: getCanonicalLocales language alias + field-aware merge (§3.2.1)" {
    try requireFullBuild(); // CLDR languageAlias table is in the embedded blob
    try evalAssert1(
        \\const g = (t) => Intl.getCanonicalLocales(t)[0];
        \\(g('cmn') === 'zh' &&                       // macrolanguage alias
        \\ g('CMN-hANS') === 'zh-Hans' &&             // alias + case canonicalization
        \\ g('cmn-hans-cn') === 'zh-Hans-CN' &&       // script/region kept from input
        \\ g('mo') === 'ro' && g('ji') === 'yi' && g('aar') === 'aa' &&
        \\ g('sh') === 'sr-Latn' &&                   // replacement supplies the script
        \\ g('sh-Cyrl') === 'sr-Cyrl' &&              // input script wins over replacement
        \\ g('cnr') === 'sr-ME' &&                    // replacement supplies the region
        \\ g('cnr-BA') === 'sr-BA' &&                 // input region wins
        \\ g('cmn-u-nu-latn') === 'zh-u-nu-latn' &&   // extensions carried through
        \\ g('en-US') === 'en-US') ? 1 : 0            // no alias → unchanged
    );
}

test "intl: CanonicalizeLocaleList HasProperty + element type (§9.2.1)" {
    try requireIntlBuild();
    try evalAssert1(
        \\const g = Intl.getCanonicalLocales;
        \\const thrown = (fn) => { try { fn(); return ''; } catch (e) { return e.constructor.name; } };
        \\(thrown(() => g([undefined])) === 'TypeError' &&   // present undefined → TypeError (step 7.c.ii)
        \\ thrown(() => g([2])) === 'TypeError' &&           // number is not String/Object (not RangeError)
        \\ thrown(() => g([true])) === 'TypeError' &&        // boolean, not the tag "true"
        \\ thrown(() => g(null)) === 'TypeError' &&          // ToObject(null)
        \\ JSON.stringify(g([, 'en'])) === '["en"]' &&       // a hole is absent → skipped
        \\ thrown(() => {                                    // Proxy `has` trap is observed (step 7.b)
        \\   const p = new Proxy({ 0: 'en', length: 1 }, { has() { throw new RangeError('trap'); } });
        \\   g(p);
        \\ }) === 'RangeError') ? 1 : 0
    );
}
