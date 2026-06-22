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

fn requireIntlBuild() !void {
    if (!intl_config.enabled) return error.SkipZigTest;
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

test "intl: Collator compare is ordinal and resolvedOptions has locale" {
    try evalAssert1(
        \\const c = new Intl.Collator("en");
        \\const ro = c.resolvedOptions();
        \\(c.compare("a", "b") < 0 && typeof ro.locale === "string") ? 1 : 0
    );
}

test "intl: PluralRules select is always other structurally" {
    try evalAssert1(
        \\new Intl.PluralRules("en").select(1) === "other" ? 1 : 0
    );
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

test "intl: DisplayNames of returns code when fallback is code" {
    try evalAssert1(
        \\new Intl.DisplayNames("en", { type: "language" }).of("fr") === "fr" ? 1 : 0
    );
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
