//! Temporal — the JS-visible surface for the plain (calendar-free,
//! time-zone-free) value types Cynic ships so far.
//!
//! The `Temporal` global is a namespace object (like `Math`), not a
//! constructor. It currently exposes:
//!   • `Temporal.Duration`  (§7  proposal-temporal)
//!   • `Temporal.PlainTime` (§4  proposal-temporal)
//!
//! Data + pure abstract operations live in `runtime/temporal.zig`;
//! this file holds the constructors, prototype methods, statics, and
//! the namespace wiring. The instance state is a heap-allocated
//! `TemporalRecord` reached through `JSObject.temporal_record` — never
//! a `__cynic_*` property-bag key (AGENTS.md "no engine state on
//! user-visible objects").
//!
//! Deferred (the deep end — needs the TimeDuration BigInt math,
//! rounding machinery, and options parsing): `add` / `subtract` /
//! `round` / `total` / `until` / `since` on both types, and
//! `Duration.compare` / `PlainTime.compare`'s relative-to handling.
//! These throw a clear "not yet implemented" TypeError so a fixture
//! that reaches them fails loudly rather than silently misbehaving.

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
const temporal = @import("../temporal.zig");
const bigint_builtin = @import("bigint.zig");

const installConstructor = intrinsics.installConstructor;
const installNativeMethod = intrinsics.installNativeMethod;
const installNativeMethodOnProto = intrinsics.installNativeMethodOnProto;
const installNativeGetter = intrinsics.installNativeGetter;
const installToStringTag = intrinsics.installToStringTag;
const setNonEnumerable = intrinsics.setNonEnumerable;
const throwTypeError = intrinsics.throwTypeError;
const throwRangeError = intrinsics.throwRangeError;
const argOr = intrinsics.argOr;
const getPropertyChain = intrinsics.getPropertyChain;
const toNumber = intrinsics.toNumber;
const stringifyArg = intrinsics.stringifyArg;

const DurationRecord = temporal.DurationRecord;
const PlainTimeRecord = temporal.PlainTimeRecord;
const PlainDateRecord = temporal.PlainDateRecord;
const PlainDateTimeRecord = temporal.PlainDateTimeRecord;
const TemporalRecord = temporal.TemporalRecord;

/// Extract the f64 mathematical value from a Number `Value` (the
/// result of `toNumber`, which is either an Int32 or a Double).
fn numberToF64(v: Value) f64 {
    if (v.isInt32()) return @floatFromInt(v.asInt32());
    return v.asDouble();
}

/// Positional constructor parameter with a spec default of 0. ES
/// default-parameter semantics: a *missing* argument OR an explicit
/// `undefined` both trigger the `= 0` default — so `new Duration()`,
/// `new Duration(undefined)`, and the implicit tail all coerce to 0
/// rather than `ToNumber(undefined) = NaN`. (`years-undefined.js`
/// et al. assert this.)
fn argDefault0(args: []const Value, i: usize) Value {
    const v = argOr(args, i, Value.fromInt32(0));
    if (v.isUndefined()) return Value.fromInt32(0);
    return v;
}

// ── Namespace install ─────────────────────────────────────────────────────

pub fn install(realm: *Realm) !void {
    // The `Temporal` namespace object — a plain object inheriting
    // %Object.prototype% with a `Symbol.toStringTag` of "Temporal"
    // and the per-type constructors as non-enumerable data
    // properties.
    const ns = try realm.heap.allocateObject();
    realm.heap.setObjectPrototype(ns, realm.intrinsics.object_prototype);
    try installToStringTag(realm, ns, "Temporal");
    realm.intrinsics.temporal_namespace = ns;

    try installDuration(realm, ns);
    try installPlainTime(realm, ns);
    try installInstant(realm, ns);
    try installPlainDate(realm, ns);
    try installPlainDateTime(realm, ns);
    try installPlainYearMonth(realm, ns);
    try installPlainMonthDay(realm, ns);
    try installZonedDateTime(realm, ns);
    try installNow(realm, ns);

    // `Temporal` is a non-enumerable, writable, configurable global
    // (§17 namespace-object convention, matching the property
    // descriptor of `Math` / `JSON` / `Reflect`).
    try realm.globals.put(realm.allocator, "Temporal", heap_mod.taggedObject(ns));
}

// ── §2 Temporal.Now ─────────────────────────────────────────────────────────

/// §2.1 The `Temporal.Now` namespace object — a plain object inheriting
/// %Object.prototype% with a `Symbol.toStringTag` of "Temporal.Now" and
/// the six clock-reading methods as non-enumerable data properties. Like
/// `Math` / `JSON`, it is not a constructor (no `[[Construct]]`, no
/// `prototype`). Stored in an intrinsic slot before its methods install
/// so it stays a GC root throughout (and the SES freeze pass reaches it
/// via the `Temporal` namespace).
fn installNow(realm: *Realm, ns: *JSObject) !void {
    const now = try realm.heap.allocateObject();
    realm.heap.setObjectPrototype(now, realm.intrinsics.object_prototype);
    realm.intrinsics.temporal_now_namespace = now;
    try installToStringTag(realm, now, "Temporal.Now");

    try installNativeMethodOnProto(realm, now, "instant", nowInstant, 0);
    try installNativeMethodOnProto(realm, now, "timeZoneId", nowTimeZoneId, 0);
    try installNativeMethodOnProto(realm, now, "zonedDateTimeISO", nowZonedDateTimeISO, 0);
    try installNativeMethodOnProto(realm, now, "plainDateTimeISO", nowPlainDateTimeISO, 0);
    try installNativeMethodOnProto(realm, now, "plainDateISO", nowPlainDateISO, 0);
    try installNativeMethodOnProto(realm, now, "plainTimeISO", nowPlainTimeISO, 0);

    // Non-enumerable, writable, configurable data property on the
    // namespace (§17), matching the per-type constructors.
    try setNonEnumerable(ns, realm.allocator, "Now", heap_mod.taggedObject(now));
}

/// §2.x SystemUTCEpochNanoseconds — the host wall clock as nanoseconds
/// since the Unix epoch. Mirrors `Date`'s host hook (libc
/// `clock_gettime(CLOCK_REALTIME)`); the freestanding playground build
/// has no ambient clock and resolves to the epoch (0), exactly like
/// `Date.now()` there. The value always lies well within the
/// ±8.64×10^21 ns Instant range, so no clamping is needed.
fn systemUTCEpochNanoseconds() i128 {
    if (@import("builtin").os.tag == .freestanding) return 0;
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts) != 0) return 0;
    const sec: i128 = ts.sec;
    const nsec: i128 = ts.nsec;
    return sec * 1_000_000_000 + nsec;
}

/// §2.x Resolve the optional `temporalTimeZoneLike` argument of the
/// `*ISO` Now methods. A missing argument or explicit `undefined` →
/// the system time zone (UTC in Cynic's no-tzdata scope); anything
/// else goes through ToTemporalTimeZoneIdentifier (string or
/// ZonedDateTime-bearing object; TypeError / RangeError otherwise).
fn nowTimeZoneArg(realm: *Realm, args: []const Value) NativeError!temporal.TimeZone {
    const arg = argOr(args, 0, Value.undefined_);
    if (arg.isUndefined()) return .utc;
    return toTimeZoneArg(realm, arg);
}

/// §2.3 Temporal.Now.instant ( ).
fn nowInstant(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = this_value;
    _ = args;
    return createTemporalInstant(realm, systemUTCEpochNanoseconds());
}

/// §2.2 Temporal.Now.timeZoneId ( ). Cynic's host ships no IANA tzdata,
/// so SystemTimeZoneIdentifier is always the UTC zone.
fn nowTimeZoneId(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = this_value;
    _ = args;
    var buf: [16]u8 = undefined;
    const s = temporal.timeZoneIdentifierString(.utc, &buf);
    const js = realm.heap.allocateString(s) catch return error.OutOfMemory;
    return Value.fromString(js);
}

/// §2.6 Temporal.Now.zonedDateTimeISO ( [ temporalTimeZoneLike ] ).
fn nowZonedDateTimeISO(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = this_value;
    const tz = try nowTimeZoneArg(realm, args);
    return createTemporalZonedDateTime(realm, .{ .epoch_ns = systemUTCEpochNanoseconds(), .time_zone = tz });
}

/// §2.4 Temporal.Now.plainDateTimeISO ( [ temporalTimeZoneLike ] ).
fn nowPlainDateTimeISO(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = this_value;
    const tz = try nowTimeZoneArg(realm, args);
    const dt = temporal.getISODateTimeFor(tz, systemUTCEpochNanoseconds());
    return createTemporalDateTime(realm, dt);
}

/// §2.5 Temporal.Now.plainDateISO ( [ temporalTimeZoneLike ] ).
fn nowPlainDateISO(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = this_value;
    const tz = try nowTimeZoneArg(realm, args);
    const dt = temporal.getISODateTimeFor(tz, systemUTCEpochNanoseconds());
    return createTemporalDate(realm, dt.date());
}

/// §2.x Temporal.Now.plainTimeISO ( [ temporalTimeZoneLike ] ). Derives
/// the wall-clock time directly from the system instant — it does not
/// route through PlainDateTime.prototype.toPlainTime (an observable
/// difference the `toPlainTime-override.js` fixture checks).
fn nowPlainTimeISO(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = this_value;
    const tz = try nowTimeZoneArg(realm, args);
    const dt = temporal.getISODateTimeFor(tz, systemUTCEpochNanoseconds());
    return createTemporalTime(realm, dt.time());
}

// ── §7 Temporal.Duration ───────────────────────────────────────────────────

fn installDuration(realm: *Realm, ns: *JSObject) !void {
    // §7.2.1 — `new`-only constructor with arity 0 (all 10 numeric
    // parameters are optional and default to 0).
    const r = try installConstructor(realm, .{
        .name = "Duration",
        .ctor = durationConstructor,
        .arity = 0,
        .is_class = true,
        .set_home_object = true,
        .to_string_tag = "Temporal.Duration",
        .install_global = false,
    });
    const fn_obj = r.ctor;
    const proto = r.proto;

    // §7.3 prototype getters — years … nanoseconds, plus sign / blank.
    try installNativeGetter(realm, proto, "years", durationYears);
    try installNativeGetter(realm, proto, "months", durationMonths);
    try installNativeGetter(realm, proto, "weeks", durationWeeks);
    try installNativeGetter(realm, proto, "days", durationDays);
    try installNativeGetter(realm, proto, "hours", durationHours);
    try installNativeGetter(realm, proto, "minutes", durationMinutes);
    try installNativeGetter(realm, proto, "seconds", durationSeconds);
    try installNativeGetter(realm, proto, "milliseconds", durationMilliseconds);
    try installNativeGetter(realm, proto, "microseconds", durationMicroseconds);
    try installNativeGetter(realm, proto, "nanoseconds", durationNanoseconds);
    try installNativeGetter(realm, proto, "sign", durationSignGetter);
    try installNativeGetter(realm, proto, "blank", durationBlank);

    // §7.3 prototype methods (implemented subset).
    try installNativeMethodOnProto(realm, proto, "with", durationWith, 1);
    try installNativeMethodOnProto(realm, proto, "negated", durationNegated, 0);
    try installNativeMethodOnProto(realm, proto, "abs", durationAbs, 0);
    try installNativeMethodOnProto(realm, proto, "toString", durationToString, 0);
    try installNativeMethodOnProto(realm, proto, "toJSON", durationToJSON, 0);
    try installNativeMethodOnProto(realm, proto, "toLocaleString", durationToLocaleString, 0);
    try installNativeMethodOnProto(realm, proto, "valueOf", durationValueOf, 0);
    // Deferred deep-end methods — present so they exist on the
    // prototype with the right shape, but throw until the rounding
    // machinery lands.
    try installNativeMethodOnProto(realm, proto, "add", durationAdd, 1);
    try installNativeMethodOnProto(realm, proto, "subtract", durationSubtract, 1);
    try installNativeMethodOnProto(realm, proto, "round", durationRound, 1);
    try installNativeMethodOnProto(realm, proto, "total", durationTotal, 1);

    // §7.2 statics.
    try installNativeMethod(realm, fn_obj, "from", durationFrom, 1);
    try installNativeMethod(realm, fn_obj, "compare", durationCompare, 2);

    realm.intrinsics.temporal_duration_constructor = fn_obj;
    realm.intrinsics.temporal_duration_prototype = proto;

    // `Temporal.Duration` is a non-enumerable, writable,
    // configurable data property on the namespace (§17).
    try setNonEnumerable(ns, realm.allocator, "Duration", heap_mod.taggedFunction(fn_obj));
}

/// §7.5.x ToIntegerIfIntegral(value) — ToNumber, then RangeError on a
/// non-finite or non-integral result. Maps -0 to +0. Re-enters JS
/// via ToNumber (valueOf / @@toPrimitive), so the caller's instance
/// must be rooted across the loop (the interpreter roots `this` on
/// `native_ctor_roots`; we hold only stack-local f64 in between).
fn toIntegerIfIntegral(realm: *Realm, v: Value) NativeError!f64 {
    const num = try toNumber(realm, v);
    const n = numberToF64(num);
    if (!std.math.isFinite(n)) return throwRangeError(realm, "Duration field must be finite");
    if (std.math.trunc(n) != n) return throwRangeError(realm, "Duration field must be an integer");
    if (n == 0) return 0; // normalise -0 → +0
    return n;
}

/// §7.2.1 Temporal.Duration ( years, months, …, nanoseconds ).
/// `new`-only. Coerces all 10 args left-to-right via
/// ToIntegerIfIntegral, then validates with IsValidDuration.
fn durationConstructor(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const inst = heap_mod.valueAsPlainObject(this_value) orelse
        return throwTypeError(realm, "Temporal.Duration constructor requires 'new'");

    // §7.2.1 steps 2-11 — ToIntegerIfIntegral on each field, in
    // argument order (the order-of-operations fixtures assert this
    // left-to-right valueOf sequence).
    var d = DurationRecord{};
    d.years = try toIntegerIfIntegral(realm, argDefault0(args, 0));
    d.months = try toIntegerIfIntegral(realm, argDefault0(args, 1));
    d.weeks = try toIntegerIfIntegral(realm, argDefault0(args, 2));
    d.days = try toIntegerIfIntegral(realm, argDefault0(args, 3));
    d.hours = try toIntegerIfIntegral(realm, argDefault0(args, 4));
    d.minutes = try toIntegerIfIntegral(realm, argDefault0(args, 5));
    d.seconds = try toIntegerIfIntegral(realm, argDefault0(args, 6));
    d.milliseconds = try toIntegerIfIntegral(realm, argDefault0(args, 7));
    d.microseconds = try toIntegerIfIntegral(realm, argDefault0(args, 8));
    d.nanoseconds = try toIntegerIfIntegral(realm, argDefault0(args, 9));

    // §7.5.x CreateTemporalDuration step 1 — IsValidDuration.
    if (!temporal.isValidDuration(d)) {
        return throwRangeError(realm, "Duration values are out of range");
    }
    try storeDuration(realm, inst, d);
    return heap_mod.taggedObject(inst);
}

/// Allocate a fresh `Temporal.Duration` instance with the realm's
/// prototype and the given record. Used by `from` / `with` /
/// `negated` / `abs` where the spec calls `CreateTemporalDuration`
/// without a user-facing NewTarget.
fn createTemporalDuration(realm: *Realm, d: DurationRecord) NativeError!Value {
    if (!temporal.isValidDuration(d)) {
        return throwRangeError(realm, "Duration values are out of range");
    }
    const inst = realm.heap.allocateObject() catch return error.OutOfMemory;
    realm.heap.setObjectPrototype(inst, realm.intrinsics.temporal_duration_prototype.?);
    try storeDuration(realm, inst, d);
    return heap_mod.taggedObject(inst);
}

fn storeDuration(realm: *Realm, inst: *JSObject, d: DurationRecord) NativeError!void {
    const rec = realm.allocator.create(TemporalRecord) catch return error.OutOfMemory;
    rec.* = .{ .duration = d };
    inst.setTemporalRecord(realm.allocator, rec) catch return error.OutOfMemory;
}

/// §7.3.x RequireInternalSlot(duration, [[InitializedTemporalDuration]]).
fn requireDuration(realm: *Realm, this_value: Value) NativeError!DurationRecord {
    const obj = heap_mod.valueAsPlainObject(this_value) orelse
        return throwTypeError(realm, "not a Temporal.Duration");
    const rec = obj.getTemporalRecord() orelse
        return throwTypeError(realm, "not a Temporal.Duration");
    return switch (rec.*) {
        .duration => |d| d,
        else => throwTypeError(realm, "not a Temporal.Duration"),
    };
}

// §7.3.{4-13} — the field getters. Each requires the brand then
// returns the slot value as a Number.
fn durationYears(realm: *Realm, t: Value, a: []const Value) NativeError!Value {
    _ = a;
    return Value.fromDouble((try requireDuration(realm, t)).years);
}
fn durationMonths(realm: *Realm, t: Value, a: []const Value) NativeError!Value {
    _ = a;
    return Value.fromDouble((try requireDuration(realm, t)).months);
}
fn durationWeeks(realm: *Realm, t: Value, a: []const Value) NativeError!Value {
    _ = a;
    return Value.fromDouble((try requireDuration(realm, t)).weeks);
}
fn durationDays(realm: *Realm, t: Value, a: []const Value) NativeError!Value {
    _ = a;
    return Value.fromDouble((try requireDuration(realm, t)).days);
}
fn durationHours(realm: *Realm, t: Value, a: []const Value) NativeError!Value {
    _ = a;
    return Value.fromDouble((try requireDuration(realm, t)).hours);
}
fn durationMinutes(realm: *Realm, t: Value, a: []const Value) NativeError!Value {
    _ = a;
    return Value.fromDouble((try requireDuration(realm, t)).minutes);
}
fn durationSeconds(realm: *Realm, t: Value, a: []const Value) NativeError!Value {
    _ = a;
    return Value.fromDouble((try requireDuration(realm, t)).seconds);
}
fn durationMilliseconds(realm: *Realm, t: Value, a: []const Value) NativeError!Value {
    _ = a;
    return Value.fromDouble((try requireDuration(realm, t)).milliseconds);
}
fn durationMicroseconds(realm: *Realm, t: Value, a: []const Value) NativeError!Value {
    _ = a;
    return Value.fromDouble((try requireDuration(realm, t)).microseconds);
}
fn durationNanoseconds(realm: *Realm, t: Value, a: []const Value) NativeError!Value {
    _ = a;
    return Value.fromDouble((try requireDuration(realm, t)).nanoseconds);
}

/// §7.3.2 get Temporal.Duration.prototype.sign.
fn durationSignGetter(realm: *Realm, t: Value, a: []const Value) NativeError!Value {
    _ = a;
    const d = try requireDuration(realm, t);
    return Value.fromInt32(temporal.durationSign(d));
}

/// §7.3.3 get Temporal.Duration.prototype.blank.
fn durationBlank(realm: *Realm, t: Value, a: []const Value) NativeError!Value {
    _ = a;
    const d = try requireDuration(realm, t);
    return Value.fromBool(temporal.durationSign(d) == 0);
}

/// §7.5.x ToTemporalPartialDurationRecord — read each duration field
/// off `like`, applying ToIntegerIfIntegral to present (non-
/// undefined) values, and require at least one present. Singular
/// keys (`year`, `month`, …) are NOT read — only the plural slots.
/// Returns the merged record (starting from `base`).
fn toTemporalPartialDurationRecord(realm: *Realm, base: DurationRecord, like: Value) NativeError!DurationRecord {
    const obj = heap_mod.valueAsPlainObject(like) orelse
        return throwTypeError(realm, "Duration-like must be an object");
    var d = base;
    var any = false;
    // Spec reads the fields in alphabetical order (DURATION_FIELDS):
    // days, hours, microseconds, milliseconds, minutes, months,
    // nanoseconds, seconds, weeks, years.
    const Field = struct { key: []const u8, ptr: *f64 };
    var fields = [_]Field{
        .{ .key = "days", .ptr = &d.days },
        .{ .key = "hours", .ptr = &d.hours },
        .{ .key = "microseconds", .ptr = &d.microseconds },
        .{ .key = "milliseconds", .ptr = &d.milliseconds },
        .{ .key = "minutes", .ptr = &d.minutes },
        .{ .key = "months", .ptr = &d.months },
        .{ .key = "nanoseconds", .ptr = &d.nanoseconds },
        .{ .key = "seconds", .ptr = &d.seconds },
        .{ .key = "weeks", .ptr = &d.weeks },
        .{ .key = "years", .ptr = &d.years },
    };
    for (&fields) |f| {
        const v = try getPropertyChain(realm, obj, f.key);
        if (!v.isUndefined()) {
            any = true;
            f.ptr.* = try toIntegerIfIntegral(realm, v);
        }
    }
    if (!any) return throwTypeError(realm, "Duration-like must have at least one duration property");
    return d;
}

/// §7.3.26 Temporal.Duration.prototype.with ( durationLike ).
fn durationWith(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const d = try requireDuration(realm, this_value);
    const merged = try toTemporalPartialDurationRecord(realm, d, argOr(args, 0, Value.undefined_));
    return createTemporalDuration(realm, merged);
}

/// §7.3.20 Temporal.Duration.prototype.negated ( ).
fn durationNegated(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    const d = try requireDuration(realm, this_value);
    const n = DurationRecord{
        .years = negZero(d.years),
        .months = negZero(d.months),
        .weeks = negZero(d.weeks),
        .days = negZero(d.days),
        .hours = negZero(d.hours),
        .minutes = negZero(d.minutes),
        .seconds = negZero(d.seconds),
        .milliseconds = negZero(d.milliseconds),
        .microseconds = negZero(d.microseconds),
        .nanoseconds = negZero(d.nanoseconds),
    };
    return createTemporalDuration(realm, n);
}

/// Negate but keep -0 → +0 (the spec's negated duration normalises
/// signed zero: `new Temporal.Duration(0).negated()` has +0 years).
fn negZero(v: f64) f64 {
    if (v == 0) return 0;
    return -v;
}

/// §7.3.21 Temporal.Duration.prototype.abs ( ).
fn durationAbs(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    const d = try requireDuration(realm, this_value);
    const a = DurationRecord{
        .years = @abs(d.years),
        .months = @abs(d.months),
        .weeks = @abs(d.weeks),
        .days = @abs(d.days),
        .hours = @abs(d.hours),
        .minutes = @abs(d.minutes),
        .seconds = @abs(d.seconds),
        .milliseconds = @abs(d.milliseconds),
        .microseconds = @abs(d.microseconds),
        .nanoseconds = @abs(d.nanoseconds),
    };
    return createTemporalDuration(realm, a);
}

/// §7.3.24 Temporal.Duration.prototype.toString — read the
/// `fractionalSecondDigits` / `roundingMode` / `smallestUnit` options (in
/// that order, each read before `smallestUnit` is validated), round the
/// duration's *time* part to the resulting precision, then format.
///
/// Per §7.3.24 steps 9-11: with `auto` precision (unit = nanosecond,
/// increment = 1) no rounding occurs. Otherwise round the time component
/// (RoundTimeDuration over the time-only nanoseconds, days excluded), then
/// re-expand it capped at LargerOfTwoTemporalUnits(DefaultTemporalLargestUnit,
/// second) — so the seconds floor holds (PT60S never balances to PT1M) and
/// any whole-day carry from the rounding adds into the days field without
/// cascading into weeks/months/years (a calendar boundary the time round
/// can't cross).
fn durationToString(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const d = try requireDuration(realm, this_value);
    const options = argOr(args, 0, Value.undefined_);
    const frac = try getFractionalSecondDigitsOption(realm, options);
    const opts_obj = try getOptionsObject(realm, options);
    const mode = try getRoundingModeOption(realm, opts_obj, .trunc);
    const smallest = try getTemporalUnitOption(realm, opts_obj, "smallestUnit");
    try requireDurationToStringSmallestUnit(realm, smallest);

    const prec = toSecondsStringPrecision(smallest, frac);
    var result = d;
    if (!(prec.unit == .nanosecond and prec.increment == 1)) {
        const time_ns = temporal.timeDurationNanoseconds(d);
        const inc_ns = prec.increment * temporal.unitNanoseconds(prec.unit);
        const rounded = temporal.roundToIncrement(time_ns, inc_ns, mode);
        const dl = temporal.defaultTemporalLargestUnit(d);
        // LargerOfTwoTemporalUnits(dl, second): coarser unit wins (coarser =
        // smaller enum index). balanceTimeDuration caps extraction at days.
        const largest = if (@intFromEnum(dl) < @intFromEnum(temporal.LargestUnit.second)) dl else temporal.LargestUnit.second;
        const bal = temporal.balanceTimeDuration(rounded, largest);
        result = .{
            .years = d.years,
            .months = d.months,
            .weeks = d.weeks,
            .days = d.days + bal.days,
            .hours = bal.hours,
            .minutes = bal.minutes,
            .seconds = bal.seconds,
            .milliseconds = bal.milliseconds,
            .microseconds = bal.microseconds,
            .nanoseconds = bal.nanoseconds,
        };
        // §7.5.x CreateDurationRecord step 1 — the rounded duration must
        // still be a valid (float64-representable) duration; ceil/expand on
        // a near-maximal seconds field can push the total past 2^53−1 s.
        if (!temporal.isValidDuration(result)) {
            return throwRangeError(realm, "duration out of range after rounding");
        }
    }
    var buf: [128]u8 = undefined;
    const s = temporal.temporalDurationToString(result, &buf, prec.precision);
    const js = realm.heap.allocateString(s) catch return error.OutOfMemory;
    return Value.fromString(js);
}

/// §7.3.25 Temporal.Duration.prototype.toJSON — always `auto`.
fn durationToJSON(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    const d = try requireDuration(realm, this_value);
    var buf: [128]u8 = undefined;
    const s = temporal.temporalDurationToString(d, &buf, .auto);
    const js = realm.heap.allocateString(s) catch return error.OutOfMemory;
    return Value.fromString(js);
}

/// §7.3.x Temporal.Duration.prototype.toLocaleString — without
/// Intl.DurationFormat, the spec polyfill falls back to the ISO
/// `auto` string. Cynic has no Intl, so use that fallback.
fn durationToLocaleString(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    return durationToJSON(realm, this_value, args);
}

/// §7.3.23 Temporal.Duration.prototype.valueOf — always throws
/// TypeError (Temporal values are not relationally comparable via
/// the primitive operators).
fn durationValueOf(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = this_value;
    _ = args;
    return throwTypeError(realm, "Called valueOf on a Temporal.Duration; use compare() instead");
}

/// §7.5.x ToTemporalDuration — accept a Duration (copy), an object
/// (partial record from a zeroed base), or a string (ISO parse).
fn toTemporalDuration(realm: *Realm, item: Value) NativeError!DurationRecord {
    if (heap_mod.valueAsPlainObject(item)) |obj| {
        if (obj.getTemporalRecord()) |rec| {
            switch (rec.*) {
                .duration => |d| return d,
                else => {},
            }
        }
        // Object (not a Duration) — partial record from a zeroed
        // base. (The spec's ToTemporalDuration on a non-Duration
        // object builds from zero, so any absent field stays 0.)
        return toTemporalPartialDurationRecord(realm, .{}, item);
    }
    // String path. ToString-coerce non-strings (a number throws via
    // the parse failure; the spec requires a String here).
    if (!item.isString()) {
        return throwTypeError(realm, "Temporal.Duration.from expects an object or string");
    }
    const s: *JSString = @ptrCast(@alignCast(item.asString()));
    const d = temporal.parseTemporalDurationString(s.flatBytes()) catch
        return throwRangeError(realm, "invalid ISO 8601 duration string");
    if (!temporal.isValidDuration(d)) {
        return throwRangeError(realm, "Duration values are out of range");
    }
    return d;
}

/// §7.2.2 Temporal.Duration.from ( item ).
fn durationFrom(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = this_value;
    const d = try toTemporalDuration(realm, argOr(args, 0, Value.undefined_));
    return createTemporalDuration(realm, d);
}

/// The larger-magnitude of two largest units (smaller enum index wins).
fn largerLargestUnit(a: temporal.LargestUnit, b: temporal.LargestUnit) temporal.LargestUnit {
    return if (@intFromEnum(a) < @intFromEnum(b)) a else b;
}

/// §7.5.x TotalTimeDuration — a span of `total_ns` expressed as a fractional
/// count of `unit` (day or a finer time unit, each a fixed length): the exact
/// rational `total_ns / unit_ns` rounded once to a double, matching the spec's
/// `TimeDuration.fdiv`.
fn totalInUnit(total_ns: i128, unit: temporal.LargestUnit) f64 {
    return temporal.divRoundToF64(total_ns, temporal.unitNanoseconds(unit));
}

/// §7.3.x Temporal.Duration.compare step 7 — whether two durations have
/// identical fields component-for-component (an early-return shortcut that
/// precedes any relativeTo-dependent balancing).
fn durationFieldsEqual(a: temporal.DurationRecord, b: temporal.DurationRecord) bool {
    return a.years == b.years and a.months == b.months and a.weeks == b.weeks and
        a.days == b.days and a.hours == b.hours and a.minutes == b.minutes and
        a.seconds == b.seconds and a.milliseconds == b.milliseconds and
        a.microseconds == b.microseconds and a.nanoseconds == b.nanoseconds;
}

/// The anchor a duration is measured relative to: either a *plain* wall-clock
/// PlainDateTime (a PlainDate / PlainDateTime / time-zone-less property bag /
/// bare date string — its date at midnight, any time component discarded) or
/// a *zoned* anchor (a ZonedDateTime / time-zone-bearing bag or string), kept
/// as its exact instant + time zone. The two drive different spec paths: a
/// plain anchor differences in the wall clock
/// (DifferencePlainDateTimeWithRounding / …WithTotal); a zoned anchor adds and
/// differences through the instant (AddZonedDateTime / DifferenceZonedDateTime
/// …), so the sum overflows the *Instant* range — narrower than a bare
/// PlainDateTime, whose midnight can sit one ISO day past the Instant floor —
/// and the next-day boundary the NudgeToZonedTime nudge probes must itself be
/// a representable instant.
const RelativeToAnchor = union(enum) {
    plain: temporal.PlainDateTimeRecord,
    zoned: struct { epoch_ns: i128, time_zone: temporal.TimeZone },
};

/// §7.3.x GetTemporalRelativeToOption — read the `relativeTo` option and
/// reduce it to the start wall-clock PlainDateTime the duration is measured
/// from (with its zoned-vs-plain provenance), or null when `relativeTo` is
/// absent.
///
/// A plain relativeTo (PlainDate / PlainDateTime, a time-zone-less property
/// bag, or a bare date string) is its date at midnight — CreateTemporalDate
/// discards any time. A zoned relativeTo (ZonedDateTime, a property bag or
/// string carrying a `[time-zone]`) is the wall-clock GetISODateTimeFor shows
/// at its instant. Because Cynic's time zones are fixed-offset, the constant
/// offset cancels in every later epoch difference, so the *date* arithmetic is
/// shared — only the rounding nudge differs (see `RelativeToAnchor`). A
/// branded Temporal value that is not one of the three valid types falls
/// through to the field-bag reader, which rejects it with a TypeError
/// (missing / throwing `year`..`day` getters).
fn getTemporalRelativeToOption(realm: *Realm, opts: ?*JSObject) NativeError!?RelativeToAnchor {
    const obj = opts orelse return null;
    const v = try getPropertyChain(realm, obj, "relativeTo");
    if (v.isUndefined()) return null;

    if (heap_mod.valueAsPlainObject(v)) |bag| {
        if (bag.getTemporalRecord()) |rec| switch (rec.*) {
            .zoned_date_time => |z| return .{ .zoned = .{ .epoch_ns = z.epoch_ns, .time_zone = z.time_zone } },
            // A PlainDate / PlainDateTime relativeTo is its date at midnight —
            // the time component is discarded. Both were range-checked at
            // construction (CreateTemporalDate), so no re-check is needed.
            .plain_date => |pd| return .{ .plain = temporal.PlainDateTimeRecord.combine(pd, .{}) },
            .plain_date_time => |pdt| return .{ .plain = temporal.PlainDateTimeRecord.combine(pdt.date(), .{}) },
            // Other Temporal types fall through to the property-bag reader.
            else => {},
        };
        // Generic property bag: one alphabetical pass over calendar + date /
        // time + optional offset / time-zone, resolved under `constrain`, then
        // anchored — zoned when a time zone was present, else plain (midnight).
        // InterpretTemporalDateTimeFields applies no PlainDateTime-range gate
        // here (each branch range-checks with its own wider bound below), so the
        // no-range resolver is used.
        var extras: ZonedFieldExtras = .{ .time_zone_required = false };
        const f = try readDateTimeFieldsRaw(realm, bag, &extras);
        const dt = try resolveDateTimeFieldsNoRange(realm, f, .constrain);
        if (!extras.time_zone_present) {
            // §7.3.x: the plain anchor is CreateTemporalDate(isoDate), which
            // rejects a date outside the representable PlainDate range.
            if (!temporal.isoDateWithinLimits(dt.iso_year, dt.iso_month, dt.iso_day)) {
                return throwRangeError(realm, "relativeTo date is outside the representable range");
            }
            return .{ .plain = temporal.PlainDateTimeRecord.combine(dt.date(), .{}) };
        }
        const epoch = temporal.interpretISODateTimeOffset(dt, extras.behaviour, extras.offset_ns, extras.time_zone, .reject) catch |e| switch (e) {
            error.OffsetMismatch => return throwRangeError(realm, "offset does not match the time zone"),
            error.Invalid => return throwRangeError(realm, "relativeTo is out of range"),
        };
        return .{ .zoned = .{ .epoch_ns = epoch, .time_zone = extras.time_zone } };
    }

    if (!v.isString()) {
        return throwTypeError(realm, "relativeTo must be an object or string");
    }
    const s: *JSString = @ptrCast(@alignCast(v.asString()));
    const bytes = s.flatBytes();
    // A `[time-zone]`-annotated string is zoned; a bare date / date-time
    // string is a plain date at midnight. A string with a `Z` designator but
    // no annotation parses as neither (a PlainDate forbids UTC) → RangeError.
    if (temporal.parseTemporalZonedDateTimeString(bytes)) |pz| {
        const epoch = temporal.interpretISODateTimeOffset(pz.date_time, pz.behaviour, pz.offset_ns, pz.time_zone, .reject) catch |e| switch (e) {
            error.OffsetMismatch => return throwRangeError(realm, "offset does not match the time zone"),
            error.Invalid => return throwRangeError(realm, "relativeTo is out of range"),
        };
        return .{ .zoned = .{ .epoch_ns = epoch, .time_zone = pz.time_zone } };
    } else |_| {}
    const pd = temporal.parseTemporalDateString(bytes) catch
        return throwRangeError(realm, "invalid relativeTo string");
    // §7.3.x: the plain anchor is CreateTemporalDate(isoDate), which rejects a
    // date outside the representable PlainDate range (e.g. -271821-04-18).
    if (!temporal.isoDateWithinLimits(pd.iso_year, pd.iso_month, pd.iso_day)) {
        return throwRangeError(realm, "relativeTo date is outside the representable range");
    }
    return .{ .plain = temporal.PlainDateTimeRecord.combine(pd, .{}) };
}

/// §7.3.x Temporal.Duration.compare ( one, two [, options] ). With a zoned
/// relativeTo and a date-category largest unit on either side, the two
/// durations are ordered by the instant each reaches (AddZonedDateTime). With
/// calendar units (years/months/weeks) the date components are balanced to a
/// common day axis through a plain anchor (DateDurationDays) — absent that
/// anchor they're unorderable and throw. Otherwise both reduce to a total
/// nanosecond count (each day a fixed 24 h) and compare directly.
fn durationCompare(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = this_value;
    const one = try toTemporalDuration(realm, argOr(args, 0, Value.undefined_));
    if (!temporal.isValidDuration(one)) return throwRangeError(realm, "Duration values are out of range");
    const two = try toTemporalDuration(realm, argOr(args, 1, Value.undefined_));
    if (!temporal.isValidDuration(two)) return throwRangeError(realm, "Duration values are out of range");
    const opts = try getOptionsObject(realm, argOr(args, 2, Value.undefined_));
    const rel = try getTemporalRelativeToOption(realm, opts);

    // §7.3.x step 7: field-for-field identical durations compare equal,
    // short-circuiting before any anchor-dependent balancing.
    if (durationFieldsEqual(one, two)) return Value.fromInt32(0);

    const day_idx = @intFromEnum(temporal.LargestUnit.day);
    const largest1 = temporal.defaultTemporalLargestUnit(one);
    const largest2 = temporal.defaultTemporalLargestUnit(two);

    // §7.3.x step 12: a zoned anchor with a date-category largest unit
    // (year/month/week/day) on either side orders by the reached instant.
    if (rel) |r| switch (r) {
        .zoned => |z| {
            if (@intFromEnum(largest1) <= day_idx or @intFromEnum(largest2) <= day_idx) {
                const after1 = temporal.addZonedDateTime(z.epoch_ns, z.time_zone, one, false) orelse
                    return throwRangeError(realm, "duration is out of range relative to relativeTo");
                const after2 = temporal.addZonedDateTime(z.epoch_ns, z.time_zone, two, false) orelse
                    return throwRangeError(realm, "duration is out of range relative to relativeTo");
                const cmp: i32 = if (after1 < after2) -1 else if (after1 > after2) 1 else 0;
                return Value.fromInt32(cmp);
            }
        },
        .plain => {},
    };

    // §7.3.x steps 13-14: place both durations on a common day axis. Calendar
    // units need a plain anchor to balance to days (DateDurationDays); without
    // one they're unorderable. (A zoned anchor with calendar units always took
    // step 12 above, so only a plain anchor can reach here with them.)
    var d1: i128 = @intFromFloat(one.days);
    var d2: i128 = @intFromFloat(two.days);
    if (temporal.hasCalendarUnits(one) or temporal.hasCalendarUnits(two)) {
        const anchor = switch (rel orelse
            return throwRangeError(realm, "a relativeTo is required to compare durations with calendar units")) {
            .plain => |s| s.date(),
            .zoned => |z| temporal.getISODateTimeFor(z.time_zone, z.epoch_ns).date(),
        };
        d1 = temporal.dateDurationDays(anchor, one) orelse
            return throwRangeError(realm, "duration is out of range relative to relativeTo");
        d2 = temporal.dateDurationDays(anchor, two) orelse
            return throwRangeError(realm, "duration is out of range relative to relativeTo");
    }
    // §7.3.x steps 15-17: Add24HourDaysToTimeDuration then CompareTimeDuration.
    // Add24HourDaysToTimeDuration throws RangeError when folding the whole-day
    // count into the time duration overflows maxTimeDuration (2^53 × 10^9 − 1
    // ns) — a duration valid on its own can exceed the limit once its calendar
    // span is resolved to days against the anchor.
    const t1 = temporal.timeDurationNanoseconds(one) + d1 * temporal.ns_per_day;
    const t2 = temporal.timeDurationNanoseconds(two) + d2 * temporal.ns_per_day;
    if (@abs(t1) > temporal.max_time_duration_ns or @abs(t2) > temporal.max_time_duration_ns) {
        return throwRangeError(realm, "duration is out of range relative to relativeTo");
    }
    const cmp: i32 = if (t1 < t2) -1 else if (t1 > t2) 1 else 0;
    return Value.fromInt32(cmp);
}

/// §7.3.x AddDurations — `add` (sign +1) / `subtract` (−1). These take
/// no relativeTo, so calendar units (years/months/weeks) are
/// unorderable and throw; day-and-smaller durations combine by total
/// nanoseconds and re-balance to the larger of the two largest units.
fn durationAddSubtract(realm: *Realm, this_value: Value, other_v: Value, sign: i128) NativeError!Value {
    const a = try requireDuration(realm, this_value);
    const b = try toTemporalDuration(realm, other_v);
    if (!temporal.isValidDuration(b)) return throwRangeError(realm, "Duration values are out of range");
    if (temporal.hasCalendarUnits(a) or temporal.hasCalendarUnits(b)) {
        return throwRangeError(realm, "a relativeTo is required to add durations with calendar units");
    }
    const total = temporal.dayTimeDurationNanoseconds(a) + temporal.dayTimeDurationNanoseconds(b) * sign;
    const largest = largerLargestUnit(temporal.defaultTemporalLargestUnit(a), temporal.defaultTemporalLargestUnit(b));
    return createTemporalDuration(realm, temporal.balanceTimeDuration(total, largest));
}

fn durationAdd(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    return durationAddSubtract(realm, this_value, argOr(args, 0, Value.undefined_), 1);
}

fn durationSubtract(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    return durationAddSubtract(realm, this_value, argOr(args, 0, Value.undefined_), -1);
}

/// Read the `largestUnit` option, distinguishing an absent option (unset —
/// `present` false) from an explicit `"auto"` (present, value null → caller
/// substitutes the default largest unit). §7.3.21 keeps these distinct: an
/// `"auto"` largestUnit counts as present, so it alone satisfies the
/// "neither largestUnit nor smallestUnit given" guard.
const LargestUnitOption = struct { unit: ?temporal.LargestUnit = null, present: bool = false };

fn getLargestUnitOption(realm: *Realm, opts: ?*JSObject) NativeError!LargestUnitOption {
    const obj = opts orelse return .{};
    const v = try getPropertyChain(realm, obj, "largestUnit");
    if (v.isUndefined()) return .{};
    const s = try stringifyArg(realm, v);
    const bytes = s.flatBytes();
    if (std.mem.eql(u8, bytes, "auto")) return .{ .present = true };
    const u = temporal.parseTemporalUnit(bytes) orelse
        return throwRangeError(realm, "invalid largestUnit value");
    return .{ .unit = u, .present = true };
}

/// §7.3.21 Temporal.Duration.prototype.round ( roundTo ). Without a
/// relativeTo, calendar units (years/months/weeks) can't be balanced and
/// throw; a calendar-unit-free duration rounds its day-and-time span (each
/// day a fixed 24 h) to the requested smallest unit and re-balances to
/// largestUnit. The relativeTo path is deferred.
fn durationRound(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const d = try requireDuration(realm, this_value);
    const round_to = argOr(args, 0, Value.undefined_);
    if (round_to.isUndefined()) {
        return throwTypeError(realm, "Temporal.Duration.prototype.round requires an options argument");
    }

    // §7.3.21 steps 4-15: a String shorthand sets smallestUnit; otherwise an
    // options object whose options are read in the spec's fixed order
    // (largestUnit, relativeTo, roundingIncrement, roundingMode,
    // smallestUnit) before any algorithmic validation fires.
    var largest_opt: LargestUnitOption = .{};
    var smallest: ?temporal.LargestUnit = null;
    var increment: i128 = 1;
    var mode: temporal.RoundingMode = .half_expand;
    var start: ?RelativeToAnchor = null;
    if (round_to.isString()) {
        const s: *JSString = @ptrCast(@alignCast(round_to.asString()));
        smallest = temporal.parseTemporalUnit(s.flatBytes()) orelse
            return throwRangeError(realm, "invalid smallestUnit value");
    } else {
        const opts = try getOptionsObject(realm, round_to);
        largest_opt = try getLargestUnitOption(realm, opts);
        start = try getTemporalRelativeToOption(realm, opts);
        increment = try getRoundingIncrementOption(realm, opts);
        mode = try getRoundingModeOption(realm, opts, .half_expand);
        smallest = try getTemporalUnitOption(realm, opts, "smallestUnit");
    }

    // §7.3.21 steps 16-23: resolve defaults + validate the unit pair and the
    // increment — independent of relativeTo, so these run before the branch.
    const smallest_present = smallest != null;
    const smallest_u = smallest orelse temporal.LargestUnit.nanosecond;
    const existing = temporal.defaultTemporalLargestUnit(d);
    const default_largest = largerLargestUnit(existing, smallest_u);
    const largest_u = largest_opt.unit orelse default_largest;
    if (!smallest_present and !largest_opt.present) {
        return throwRangeError(realm, "round requires either largestUnit or smallestUnit");
    }
    // LargerOfTwoTemporalUnits(largestUnit, smallestUnit) must be largestUnit:
    // largestUnit can be no finer than smallestUnit (smaller enum = coarser).
    if (@intFromEnum(largest_u) > @intFromEnum(smallest_u)) {
        return throwRangeError(realm, "largestUnit must be larger than or equal to smallestUnit");
    }
    // §7.3.21: a date unit (year/month/week/day) has no fixed sub-unit count,
    // so an increment above 1 only makes sense when the rounded unit is also
    // the largest — otherwise the result would mix it with a coarser unit it
    // cannot balance against (e.g. weeks beneath a `month` largestUnit).
    if (increment > 1 and @intFromEnum(smallest_u) <= @intFromEnum(temporal.LargestUnit.day) and largest_u != smallest_u) {
        return throwRangeError(realm, "for calendar units with roundingIncrement > 1, largestUnit must equal smallestUnit");
    }
    if (temporal.maximumTemporalDurationRoundingIncrement(smallest_u)) |maximum| {
        if (!temporal.validateRoundingIncrement(increment, maximum, false)) {
            return throwRangeError(realm, "roundingIncrement is out of range");
        }
    }

    // §7.3.21 with a relativeTo: add the duration to the anchor wall-clock to
    // resolve its calendar units into a concrete target, then difference back
    // and round. The nudge dispatch follows RoundRelativeDuration, keyed on
    // the smallest unit + zoned provenance:
    //   • largestUnit a time unit → a uniform epoch-nanosecond span balanced
    //     to largestUnit (DifferenceInstant for zoned; the time-category
    //     NudgeToDayOrTime for plain — identical under a fixed offset);
    //   • smallestUnit a calendar unit (year/month/week) → NudgeToCalendarUnit;
    //   • smallestUnit a time unit with a *zoned* anchor → NudgeToZonedTime,
    //     which holds days fixed and rounds only the sub-day time;
    //   • otherwise (plain time-unit, or day) → NudgeToDayOrTime, folding days
    //     into the rounded span.
    const day_idx = @intFromEnum(temporal.LargestUnit.day);
    if (start) |rel| {
        const result: temporal.DurationRecord = switch (rel) {
            // §7.3.21 plainRelativeTo: DifferencePlainDateTimeWithRounding.
            // The duration's calendar units resolve against the wall date
            // (CalendarDateAdd, 'constrain' / date-only range); the wall span
            // is then differenced and rounded.
            .plain => |s| blk: {
                const target = temporal.addDateTimeDateChecked(s, d, false) orelse
                    return throwRangeError(realm, "duration is out of range relative to relativeTo");
                // The zero short-circuit precedes RejectDateTimeRange: an
                // empty span on an edge anchor (whose midnight sits one ISO
                // day past the Instant floor) returns zero, not RangeError.
                if (temporal.compareISODateTime(s, target) == 0) break :blk temporal.DurationRecord{};
                if (!temporal.isoDateTimeWithinLimits(s) or !temporal.isoDateTimeWithinLimits(target)) {
                    return throwRangeError(realm, "relativeTo or its sum is outside the representable range");
                }
                if (@intFromEnum(largest_u) > day_idx) {
                    // largestUnit a time unit → fold the whole wall span into
                    // a uniform nanosecond count and balance to largestUnit.
                    const span = temporal.isoDateTimeToEpochNs(target) - temporal.isoDateTimeToEpochNs(s);
                    const rounded = temporal.roundToIncrement(span, increment * temporal.unitNanoseconds(smallest_u), mode);
                    break :blk temporal.balanceTimeDuration(rounded, largest_u);
                }
                const base_diff = temporal.differenceISODateTime(s, target, largest_u);
                if (smallest_u == .nanosecond and increment == 1) break :blk base_diff;
                break :blk temporal.roundRelativeDateTime(s, target, base_diff, largest_u, smallest_u, increment, mode) orelse
                    return throwRangeError(realm, "rounded duration is outside the representable range");
            },
            // §7.3.21 zonedRelativeTo: DifferenceZonedDateTimeWithRounding.
            // The duration is added through the instant (AddZonedDateTime —
            // Instant-range overflow throws); the wall span between the two
            // instants is then differenced and rounded. For a fixed-offset
            // zone the constant offset cancels in the difference, so the
            // wall-clock arithmetic matches — only the NudgeToZonedTime
            // next-day instant probe can additionally overflow.
            .zoned => |z| blk: {
                const target_epoch = temporal.addZonedDateTime(z.epoch_ns, z.time_zone, d, false) orelse
                    return throwRangeError(realm, "duration is out of range relative to relativeTo");
                if (@intFromEnum(largest_u) > day_idx) {
                    // largestUnit a time unit → DifferenceInstant: a uniform
                    // epoch-nanosecond span balanced to largestUnit.
                    const span = target_epoch - z.epoch_ns;
                    const rounded = temporal.roundToIncrement(span, increment * temporal.unitNanoseconds(smallest_u), mode);
                    break :blk temporal.balanceTimeDuration(rounded, largest_u);
                }
                const start_wall = temporal.getISODateTimeFor(z.time_zone, z.epoch_ns);
                const end_wall = temporal.getISODateTimeFor(z.time_zone, target_epoch);
                const base_diff = temporal.differenceISODateTime(start_wall, end_wall, largest_u);
                if (smallest_u == .nanosecond and increment == 1) break :blk base_diff;
                if (@intFromEnum(smallest_u) > day_idx) {
                    // smallestUnit a time unit with a zoned anchor →
                    // NudgeToZonedTime (holds days fixed, rounds the sub-day
                    // time, probes the ±1-day instant boundary).
                    break :blk temporal.nudgeToZonedTimeDateTime(start_wall, z.time_zone, base_diff, largest_u, smallest_u, increment, mode) orelse
                        return throwRangeError(realm, "rounded duration is outside the representable range");
                }
                // smallestUnit a calendar unit or day → NudgeToCalendarUnit /
                // NudgeToDayOrTime; under a fixed offset every day is 24 h, so
                // the wall-clock nudge is exact.
                break :blk temporal.roundRelativeDateTime(start_wall, end_wall, base_diff, largest_u, smallest_u, increment, mode) orelse
                    return throwRangeError(realm, "rounded duration is outside the representable range");
            },
        };
        if (!temporal.isValidDuration(result)) {
            return throwRangeError(realm, "duration out of range after rounding");
        }
        return createTemporalDuration(realm, result);
    }

    // §7.3.21 step 25 (no relativeTo): calendar units are unbalanceable.
    if (temporal.hasCalendarUnits(d) or @intFromEnum(largest_u) < @intFromEnum(temporal.LargestUnit.day)) {
        return throwRangeError(realm, "a relativeTo is required to round a duration with calendar units");
    }

    const total_ns = temporal.dayTimeDurationNanoseconds(d);
    const inc_ns = increment * temporal.unitNanoseconds(smallest_u);
    const rounded = temporal.roundToIncrement(total_ns, inc_ns, mode);
    const result = temporal.balanceTimeDuration(rounded, largest_u);
    if (!temporal.isValidDuration(result)) {
        return throwRangeError(realm, "duration out of range after rounding");
    }
    return createTemporalDuration(realm, result);
}

/// §7.3.x Temporal.Duration.prototype.total ( totalOf ). A string selects the
/// unit; an options bag may also carry a relativeTo anchor (read before the
/// unit per spec). With a relativeTo the duration is added to the anchor and
/// the fractional count of `unit` between anchor and target is returned
/// (DifferencePlainDateTimeWithTotal / DifferenceZonedDateTimeWithTotal —
/// TotalRelativeDuration for an irregular calendar unit, a uniform ratio for a
/// day-or-finer unit). Without one, calendar units are untotalable and a
/// day-and-time duration returns the fixed-length ratio.
fn durationTotal(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const d = try requireDuration(realm, this_value);
    const total_of = argOr(args, 0, Value.undefined_);
    if (total_of.isUndefined()) {
        return throwTypeError(realm, "Temporal.Duration.prototype.total requires a unit");
    }
    var unit_opt: ?temporal.LargestUnit = null;
    var start: ?RelativeToAnchor = null;
    if (total_of.isString()) {
        const s: *JSString = @ptrCast(@alignCast(total_of.asString()));
        unit_opt = temporal.parseTemporalUnit(s.flatBytes());
    } else {
        const opts = try getOptionsObject(realm, total_of);
        // §7.3.x: relativeTo is read before the unit.
        start = try getTemporalRelativeToOption(realm, opts);
        unit_opt = try getTemporalUnitOption(realm, opts, "unit");
    }
    const unit = unit_opt orelse return throwRangeError(realm, "a unit is required");
    const day_idx = @intFromEnum(temporal.LargestUnit.day);

    if (start) |rel| {
        const total: f64 = switch (rel) {
            // §7.3.x plainRelativeTo: DifferencePlainDateTimeWithTotal. The
            // duration's calendar units resolve against the wall date
            // (date-only range); the wall span is then totalled.
            .plain => |s| blk: {
                const target = temporal.addDateTimeDateChecked(s, d, false) orelse
                    return throwRangeError(realm, "duration is out of range relative to relativeTo");
                // Zero short-circuit precedes RejectDateTimeRange (an empty
                // span on an edge anchor totals to zero, not RangeError).
                if (temporal.compareISODateTime(s, target) == 0) break :blk 0;
                if (!temporal.isoDateTimeWithinLimits(s) or !temporal.isoDateTimeWithinLimits(target)) {
                    return throwRangeError(realm, "relativeTo or its sum is outside the representable range");
                }
                if (@intFromEnum(unit) >= day_idx) {
                    // A day-or-finer unit totals the uniform wall span.
                    const span = temporal.isoDateTimeToEpochNs(target) - temporal.isoDateTimeToEpochNs(s);
                    break :blk totalInUnit(span, unit);
                }
                const base_diff = temporal.differenceISODateTime(s, target, unit);
                break :blk temporal.totalRelativeDateTime(s, base_diff, temporal.isoDateTimeToEpochNs(target), unit) orelse
                    return throwRangeError(realm, "duration is out of range relative to relativeTo");
            },
            // §7.3.x zonedRelativeTo: DifferenceZonedDateTimeWithTotal. The
            // duration is added through the instant (Instant-range overflow
            // throws); under a fixed offset the constant offset cancels, so the
            // wall span between the two instants drives the total.
            .zoned => |z| blk: {
                const target_epoch = temporal.addZonedDateTime(z.epoch_ns, z.time_zone, d, false) orelse
                    return throwRangeError(realm, "duration is out of range relative to relativeTo");
                if (@intFromEnum(unit) > day_idx) {
                    // A sub-day (time) unit totals the uniform epoch span
                    // (DifferenceInstant); each day is 24 h under a fixed offset.
                    break :blk totalInUnit(target_epoch - z.epoch_ns, unit);
                }
                // A calendar unit OR `day`: DifferenceZonedDateTimeWithTotal
                // routes both through the calendar-window technique, whose
                // boundaries are re-anchored through the zone — a next-day
                // boundary past the Instant range throws.
                const start_wall = temporal.getISODateTimeFor(z.time_zone, z.epoch_ns);
                const end_wall = temporal.getISODateTimeFor(z.time_zone, target_epoch);
                const base_diff = temporal.differenceISODateTime(start_wall, end_wall, unit);
                break :blk temporal.totalRelativeZonedDateTime(start_wall, z.time_zone, z.epoch_ns, base_diff, target_epoch, unit) orelse
                    return throwRangeError(realm, "duration is out of range relative to relativeTo");
            },
        };
        return Value.fromDouble(total);
    }

    // No relativeTo: a calendar unit (or a calendar-bearing duration) is
    // untotalable; a day-and-time duration totals by fixed-length ratio.
    if (@intFromEnum(unit) < day_idx or temporal.hasCalendarUnits(d)) {
        return throwRangeError(realm, "a relativeTo is required to total a duration with calendar units");
    }
    return Value.fromDouble(totalInUnit(temporal.dayTimeDurationNanoseconds(d), unit));
}

// ── §4 Temporal.PlainTime ────────────────────────────────────────────────

fn installPlainTime(realm: *Realm, ns: *JSObject) !void {
    // §4.2.1 — `new`-only constructor, arity 0 (all 6 components
    // optional, default 0).
    const r = try installConstructor(realm, .{
        .name = "PlainTime",
        .ctor = plainTimeConstructor,
        .arity = 0,
        .is_class = true,
        .set_home_object = true,
        .to_string_tag = "Temporal.PlainTime",
        .install_global = false,
    });
    const fn_obj = r.ctor;
    const proto = r.proto;

    try installNativeGetter(realm, proto, "hour", plainTimeHour);
    try installNativeGetter(realm, proto, "minute", plainTimeMinute);
    try installNativeGetter(realm, proto, "second", plainTimeSecond);
    try installNativeGetter(realm, proto, "millisecond", plainTimeMillisecond);
    try installNativeGetter(realm, proto, "microsecond", plainTimeMicrosecond);
    try installNativeGetter(realm, proto, "nanosecond", plainTimeNanosecond);

    try installNativeMethodOnProto(realm, proto, "with", plainTimeWith, 1);
    try installNativeMethodOnProto(realm, proto, "equals", plainTimeEquals, 1);
    try installNativeMethodOnProto(realm, proto, "toString", plainTimeToString, 0);
    try installNativeMethodOnProto(realm, proto, "toJSON", plainTimeToJSON, 0);
    try installNativeMethodOnProto(realm, proto, "toLocaleString", plainTimeToLocaleString, 0);
    try installNativeMethodOnProto(realm, proto, "valueOf", plainTimeValueOf, 0);
    // Deferred deep-end methods.
    try installNativeMethodOnProto(realm, proto, "add", plainTimeAdd, 1);
    try installNativeMethodOnProto(realm, proto, "subtract", plainTimeSubtract, 1);
    try installNativeMethodOnProto(realm, proto, "round", plainTimeRound, 1);
    try installNativeMethodOnProto(realm, proto, "until", plainTimeUntil, 1);
    try installNativeMethodOnProto(realm, proto, "since", plainTimeSince, 1);

    try installNativeMethod(realm, fn_obj, "from", plainTimeFrom, 1);
    try installNativeMethod(realm, fn_obj, "compare", plainTimeCompare, 2);

    realm.intrinsics.temporal_plain_time_constructor = fn_obj;
    realm.intrinsics.temporal_plain_time_prototype = proto;

    try setNonEnumerable(ns, realm.allocator, "PlainTime", heap_mod.taggedFunction(fn_obj));
}

/// §7.1.x ToIntegerWithTruncation(value) — ToNumber, RangeError on a
/// non-finite result, then truncate toward zero. (Used by PlainTime,
/// which truncates fractional components rather than rejecting them
/// — distinct from Duration's ToIntegerIfIntegral.)
fn toIntegerWithTruncation(realm: *Realm, v: Value) NativeError!f64 {
    const num = try toNumber(realm, v);
    const n = numberToF64(num);
    if (!std.math.isFinite(n)) return throwRangeError(realm, "time field must be finite");
    return std.math.trunc(n);
}

/// §4.2.1 Temporal.PlainTime ( hour, minute, second, ms, µs, ns ).
fn plainTimeConstructor(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const inst = heap_mod.valueAsPlainObject(this_value) orelse
        return throwTypeError(realm, "Temporal.PlainTime constructor requires 'new'");

    const hour = try toIntegerWithTruncation(realm, argDefault0(args, 0));
    const minute = try toIntegerWithTruncation(realm, argDefault0(args, 1));
    const second = try toIntegerWithTruncation(realm, argDefault0(args, 2));
    const millisecond = try toIntegerWithTruncation(realm, argDefault0(args, 3));
    const microsecond = try toIntegerWithTruncation(realm, argDefault0(args, 4));
    const nanosecond = try toIntegerWithTruncation(realm, argDefault0(args, 5));

    const t = try rejectTime(realm, hour, minute, second, millisecond, microsecond, nanosecond);
    try storePlainTime(realm, inst, t);
    return heap_mod.taggedObject(inst);
}

/// §4.5.x RejectTime — build a `PlainTimeRecord` from coerced f64
/// components, throwing RangeError on any out-of-range value. Used
/// by the constructor (which has no `overflow` option — it always
/// rejects).
fn rejectTime(realm: *Realm, hour: f64, minute: f64, second: f64, millisecond: f64, microsecond: f64, nanosecond: f64) NativeError!PlainTimeRecord {
    if (!rangeOk(hour, 23) or !rangeOk(minute, 59) or !rangeOk(second, 59) or
        !rangeOk(millisecond, 999) or !rangeOk(microsecond, 999) or !rangeOk(nanosecond, 999))
    {
        return throwRangeError(realm, "PlainTime field is out of range");
    }
    return PlainTimeRecord{
        .hour = @intFromFloat(hour),
        .minute = @intFromFloat(minute),
        .second = @intFromFloat(second),
        .millisecond = @intFromFloat(millisecond),
        .microsecond = @intFromFloat(microsecond),
        .nanosecond = @intFromFloat(nanosecond),
    };
}

const Overflow = enum { constrain, reject };

/// §4.5.x RegulateTime — `constrain` clamps each field into its ISO
/// range; `reject` throws (delegates to `rejectTime`). Used by
/// `with` / `from` (object path) where the `overflow` option
/// applies.
fn regulateTime(realm: *Realm, hour: f64, minute: f64, second: f64, millisecond: f64, microsecond: f64, nanosecond: f64, overflow: Overflow) NativeError!PlainTimeRecord {
    switch (overflow) {
        .reject => return rejectTime(realm, hour, minute, second, millisecond, microsecond, nanosecond),
        .constrain => return PlainTimeRecord{
            .hour = clampField(hour, 23),
            .minute = clampField(minute, 59),
            .second = clampField(second, 59),
            .millisecond = clampField(millisecond, 999),
            .microsecond = clampField(microsecond, 999),
            .nanosecond = clampField(nanosecond, 999),
        },
    }
}

fn rangeOk(v: f64, max: f64) bool {
    return v >= 0 and v <= max;
}

/// §4.5.x ConstrainToRange — clamp `v` into `[0, max]` and narrow to
/// the u32 field. The f64 has already been truncated by
/// ToIntegerWithTruncation, so the cast after clamping is defined.
fn clampField(v: f64, max: comptime_int) u32 {
    if (v < 0) return 0;
    if (v > max) return max;
    return @intFromFloat(v);
}

/// §13.x GetTemporalOverflowOption — read `overflow` off an options
/// object. `undefined` options ⇒ `constrain`. An options value that
/// is neither undefined nor an object throws TypeError
/// (GetOptionsObject). The `overflow` property, if present, must
/// ToString to "constrain" or "reject"; anything else is RangeError.
fn getTemporalOverflowOption(realm: *Realm, options: Value) NativeError!Overflow {
    if (options.isUndefined()) return .constrain;
    const obj = heap_mod.valueAsPlainObject(options) orelse {
        // A non-object, non-undefined options is a TypeError per
        // GetOptionsObject (functions count as objects — but Cynic's
        // valueAsPlainObject excludes functions, so accept those
        // too: a callable options bag is legal, its `overflow` is
        // just undefined).
        if (heap_mod.valueAsFunction(options) != null) return .constrain;
        return throwTypeError(realm, "options must be an object or undefined");
    };
    const v = try getPropertyChain(realm, obj, "overflow");
    if (v.isUndefined()) return .constrain;
    const s = try stringifyArg(realm, v);
    const bytes = s.flatBytes();
    if (std.mem.eql(u8, bytes, "constrain")) return .constrain;
    if (std.mem.eql(u8, bytes, "reject")) return .reject;
    return throwRangeError(realm, "overflow must be 'constrain' or 'reject'");
}

fn createTemporalTime(realm: *Realm, t: PlainTimeRecord) NativeError!Value {
    const inst = realm.heap.allocateObject() catch return error.OutOfMemory;
    realm.heap.setObjectPrototype(inst, realm.intrinsics.temporal_plain_time_prototype.?);
    try storePlainTime(realm, inst, t);
    return heap_mod.taggedObject(inst);
}

fn storePlainTime(realm: *Realm, inst: *JSObject, t: PlainTimeRecord) NativeError!void {
    const rec = realm.allocator.create(TemporalRecord) catch return error.OutOfMemory;
    rec.* = .{ .plain_time = t };
    inst.setTemporalRecord(realm.allocator, rec) catch return error.OutOfMemory;
}

fn requirePlainTime(realm: *Realm, this_value: Value) NativeError!PlainTimeRecord {
    const obj = heap_mod.valueAsPlainObject(this_value) orelse
        return throwTypeError(realm, "not a Temporal.PlainTime");
    const rec = obj.getTemporalRecord() orelse
        return throwTypeError(realm, "not a Temporal.PlainTime");
    return switch (rec.*) {
        .plain_time => |t| t,
        else => throwTypeError(realm, "not a Temporal.PlainTime"),
    };
}

fn plainTimeHour(realm: *Realm, t: Value, a: []const Value) NativeError!Value {
    _ = a;
    return Value.fromInt32(@intCast((try requirePlainTime(realm, t)).hour));
}
fn plainTimeMinute(realm: *Realm, t: Value, a: []const Value) NativeError!Value {
    _ = a;
    return Value.fromInt32(@intCast((try requirePlainTime(realm, t)).minute));
}
fn plainTimeSecond(realm: *Realm, t: Value, a: []const Value) NativeError!Value {
    _ = a;
    return Value.fromInt32(@intCast((try requirePlainTime(realm, t)).second));
}
fn plainTimeMillisecond(realm: *Realm, t: Value, a: []const Value) NativeError!Value {
    _ = a;
    return Value.fromInt32(@intCast((try requirePlainTime(realm, t)).millisecond));
}
fn plainTimeMicrosecond(realm: *Realm, t: Value, a: []const Value) NativeError!Value {
    _ = a;
    return Value.fromInt32(@intCast((try requirePlainTime(realm, t)).microsecond));
}
fn plainTimeNanosecond(realm: *Realm, t: Value, a: []const Value) NativeError!Value {
    _ = a;
    return Value.fromInt32(@intCast((try requirePlainTime(realm, t)).nanosecond));
}

/// §13.x RejectTemporalLikeObject — throw TypeError if `obj` carries
/// a `calendar` or `timeZone` own property (reading `calendar` then
/// `timeZone` in that order, per the order-of-operations fixture) or
/// is itself a branded Temporal value. Used by `PlainTime.prototype.
/// with` to reject a date-ish / Temporal bag.
fn rejectTemporalLikeObject(realm: *Realm, obj: *JSObject) NativeError!void {
    if (obj.getTemporalRecord() != null) {
        return throwTypeError(realm, "a Temporal object is not a valid PlainTime-like property bag");
    }
    const cal = try getPropertyChain(realm, obj, "calendar");
    if (!cal.isUndefined()) {
        return throwTypeError(realm, "PlainTime-like must not have a calendar property");
    }
    const tz = try getPropertyChain(realm, obj, "timeZone");
    if (!tz.isUndefined()) {
        return throwTypeError(realm, "PlainTime-like must not have a timeZone property");
    }
}

/// §4.5.x ToTemporalTimeRecord(bag, 'partial') — read present time
/// fields off `like` (ToIntegerWithTruncation each), require at
/// least one. Singular spec keys only (hour, microsecond,
/// millisecond, minute, nanosecond, second).
fn plainTimeWith(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const base = try requirePlainTime(realm, this_value);
    const like = argOr(args, 0, Value.undefined_);
    const obj = heap_mod.valueAsPlainObject(like) orelse
        return throwTypeError(realm, "PlainTime-like must be an object");

    // §4.5.x RejectTemporalLikeObject — a property bag carrying a
    // `calendar` or `timeZone` own property (or a branded Temporal
    // value) is not a plain time-like and is rejected. The two
    // reads happen first per the order-of-operations fixture.
    try rejectTemporalLikeObject(realm, obj);

    // Start from the receiver's fields (as f64 so a present partial
    // value can override).
    var hour: f64 = @floatFromInt(base.hour);
    var minute: f64 = @floatFromInt(base.minute);
    var second: f64 = @floatFromInt(base.second);
    var millisecond: f64 = @floatFromInt(base.millisecond);
    var microsecond: f64 = @floatFromInt(base.microsecond);
    var nanosecond: f64 = @floatFromInt(base.nanosecond);

    var any = false;
    const Field = struct { key: []const u8, ptr: *f64 };
    var fields = [_]Field{
        .{ .key = "hour", .ptr = &hour },
        .{ .key = "microsecond", .ptr = &microsecond },
        .{ .key = "millisecond", .ptr = &millisecond },
        .{ .key = "minute", .ptr = &minute },
        .{ .key = "nanosecond", .ptr = &nanosecond },
        .{ .key = "second", .ptr = &second },
    };
    for (&fields) |f| {
        const v = try getPropertyChain(realm, obj, f.key);
        if (!v.isUndefined()) {
            any = true;
            f.ptr.* = try toIntegerWithTruncation(realm, v);
        }
    }
    if (!any) return throwTypeError(realm, "PlainTime-like must have at least one time property");

    // §4.3.x step — the overflow option is read AFTER every field
    // (the order-of-operations fixture pins this sequence).
    const overflow = try getTemporalOverflowOption(realm, argOr(args, 1, Value.undefined_));
    const t = try regulateTime(realm, hour, minute, second, millisecond, microsecond, nanosecond, overflow);
    return createTemporalTime(realm, t);
}

/// §4.3.x Temporal.PlainTime.prototype.equals ( other ).
fn plainTimeEquals(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const a = try requirePlainTime(realm, this_value);
    const b = try toTemporalTime(realm, argOr(args, 0, Value.undefined_), Value.undefined_);
    return Value.fromBool(temporal.compareTime(a, b) == 0);
}

/// §4.3.x Temporal.PlainTime.prototype.toString — read the
/// `fractionalSecondDigits` / `roundingMode` / `smallestUnit` options (in
/// that order, each read before `smallestUnit` is validated), round the
/// time to the resulting precision (any whole-day carry is discarded — a
/// PlainTime has no date), and format.
fn plainTimeToString(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const t = try requirePlainTime(realm, this_value);
    const options = argOr(args, 0, Value.undefined_);
    const frac = try getFractionalSecondDigitsOption(realm, options);
    const opts_obj = try getOptionsObject(realm, options);
    const mode = try getRoundingModeOption(realm, opts_obj, .trunc);
    const smallest = try getTemporalUnitOption(realm, opts_obj, "smallestUnit");
    try requireToStringSmallestUnit(realm, smallest);

    const prec = toSecondsStringPrecision(smallest, frac);
    const rt = temporal.roundTime(t, prec.unit, prec.increment, mode);
    var buf: [64]u8 = undefined;
    const s = temporal.plainTimeToString(rt.time, &buf, prec.precision);
    const js = realm.heap.allocateString(s) catch return error.OutOfMemory;
    return Value.fromString(js);
}

fn plainTimeToJSON(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    const t = try requirePlainTime(realm, this_value);
    var buf: [64]u8 = undefined;
    const s = temporal.plainTimeToString(t, &buf, .auto);
    const js = realm.heap.allocateString(s) catch return error.OutOfMemory;
    return Value.fromString(js);
}

fn plainTimeToLocaleString(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    return plainTimeToJSON(realm, this_value, args);
}

fn plainTimeValueOf(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = this_value;
    _ = args;
    return throwTypeError(realm, "Called valueOf on a Temporal.PlainTime; use compare() instead");
}

/// §4.5.x ToTemporalTime — accept a PlainTime (copy), an object
/// (time record + overflow regulation), or a string (ISO time
/// parse). `options` carries the `overflow` option (default
/// `constrain`); the copy/string paths validate it but ignore the
/// overflow value, matching the spec.
fn toTemporalTime(realm: *Realm, item: Value, options: Value) NativeError!PlainTimeRecord {
    if (heap_mod.valueAsPlainObject(item)) |obj| {
        if (obj.getTemporalRecord()) |rec| {
            switch (rec.*) {
                .plain_time => |t| {
                    // Validate (and ignore) options on the copy path.
                    _ = try getTemporalOverflowOption(realm, options);
                    return t;
                },
                // §4.5.x ToTemporalTime — a PlainDateTime / ZonedDateTime
                // converts via its internal slots, never the user-facing
                // getters: the time part of the ISO date-time (the
                // ZonedDateTime first resolved to wall-clock via
                // GetISODateTimeFor).
                .plain_date_time => |pdt| {
                    _ = try getTemporalOverflowOption(realm, options);
                    return pdt.time();
                },
                .zoned_date_time => |zdt| {
                    const iso = temporal.getISODateTimeFor(zdt.time_zone, zdt.epoch_ns);
                    _ = try getTemporalOverflowOption(realm, options);
                    return iso.time();
                },
                else => {},
            }
        }
        // Object — complete time record (absent fields default 0).
        var hour: f64 = 0;
        var minute: f64 = 0;
        var second: f64 = 0;
        var millisecond: f64 = 0;
        var microsecond: f64 = 0;
        var nanosecond: f64 = 0;
        var any = false;
        const Field = struct { key: []const u8, ptr: *f64 };
        var fields = [_]Field{
            .{ .key = "hour", .ptr = &hour },
            .{ .key = "microsecond", .ptr = &microsecond },
            .{ .key = "millisecond", .ptr = &millisecond },
            .{ .key = "minute", .ptr = &minute },
            .{ .key = "nanosecond", .ptr = &nanosecond },
            .{ .key = "second", .ptr = &second },
        };
        for (&fields) |f| {
            const v = try getPropertyChain(realm, obj, f.key);
            if (!v.isUndefined()) {
                any = true;
                f.ptr.* = try toIntegerWithTruncation(realm, v);
            }
        }
        if (!any) return throwTypeError(realm, "PlainTime-like must have at least one time property");
        const overflow = try getTemporalOverflowOption(realm, options);
        return regulateTime(realm, hour, minute, second, millisecond, microsecond, nanosecond, overflow);
    }
    if (!item.isString()) {
        return throwTypeError(realm, "Temporal.PlainTime.from expects an object or string");
    }
    // §4.5.x ToTemporalTime string path — `ParseTemporalTimeString`
    // runs BEFORE `GetTemporalOverflowOption`, so an invalid string
    // throws RangeError even when the options argument is a wrong
    // type (which would otherwise throw TypeError). `options-wrong-
    // type.js` pins this order with `from("T99:99", badOptions)`.
    const s: *JSString = @ptrCast(@alignCast(item.asString()));
    const t = temporal.parseTemporalTimeString(s.flatBytes()) catch |e| switch (e) {
        // Both Invalid and UTCDesignator surface as RangeError per
        // §4.5.x; the distinct error tags let the messages differ.
        error.UTCDesignator => return throwRangeError(realm, "Z designator is not valid for a PlainTime"),
        error.Invalid => return throwRangeError(realm, "invalid ISO 8601 time string"),
    };
    _ = try getTemporalOverflowOption(realm, options);
    return t;
}

/// §4.2.2 Temporal.PlainTime.from ( item [, options] ). The
/// `overflow` option (default `constrain`) regulates an object
/// argument's fields; the copy / string paths validate it but ignore
/// the value.
fn plainTimeFrom(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = this_value;
    const t = try toTemporalTime(realm, argOr(args, 0, Value.undefined_), argOr(args, 1, Value.undefined_));
    return createTemporalTime(realm, t);
}

/// §4.2.3 Temporal.PlainTime.compare ( one, two ).
fn plainTimeCompare(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = this_value;
    const a = try toTemporalTime(realm, argOr(args, 0, Value.undefined_), Value.undefined_);
    const b = try toTemporalTime(realm, argOr(args, 1, Value.undefined_), Value.undefined_);
    return Value.fromInt32(temporal.compareTime(a, b));
}

/// §4.5.x AddDurationToTime — add (`sign` +1) or subtract (−1) a
/// duration's time part to a PlainTime, wrapping mod 24 h. A PlainTime
/// has no date, so the duration's calendar units (years/months/weeks/
/// days) are ignored, not rejected.
fn plainTimeAddSubtract(realm: *Realm, this_value: Value, duration_like: Value, sign: i128) NativeError!Value {
    const base = try requirePlainTime(realm, this_value);
    const d = try toTemporalDuration(realm, duration_like);
    if (!temporal.isValidDuration(d)) return throwRangeError(realm, "Duration values are out of range");
    const total = temporal.timeRecordToNanoseconds(base) + temporal.timeDurationNanoseconds(d) * sign;
    const wrapped = @mod(total, @as(i128, 86_400_000_000_000));
    return createTemporalTime(realm, temporal.nanosecondsToTimeRecord(wrapped));
}

fn plainTimeAdd(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    return plainTimeAddSubtract(realm, this_value, argOr(args, 0, Value.undefined_), 1);
}

fn plainTimeSubtract(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    return plainTimeAddSubtract(realm, this_value, argOr(args, 0, Value.undefined_), -1);
}

/// §4.5.x Temporal.PlainTime.prototype.round ( roundTo ). String
/// shorthand for `{ smallestUnit }`; smallestUnit required (hour..ns).
/// A rounding that reaches 24 h wraps back to 00:00.
fn plainTimeRound(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const t = try requirePlainTime(realm, this_value);
    const round_to = argOr(args, 0, Value.undefined_);
    if (round_to.isUndefined()) {
        return throwTypeError(realm, "Temporal.PlainTime.prototype.round requires a smallestUnit");
    }
    var unit: temporal.LargestUnit = undefined;
    var increment: i128 = 1;
    var mode: temporal.RoundingMode = .half_expand;
    if (round_to.isString()) {
        const s: *JSString = @ptrCast(@alignCast(round_to.asString()));
        unit = temporal.parseTemporalUnit(s.flatBytes()) orelse
            return throwRangeError(realm, "invalid smallestUnit");
    } else {
        const opts = try getOptionsObject(realm, round_to);
        increment = try getRoundingIncrementOption(realm, opts);
        mode = try getRoundingModeOption(realm, opts, .half_expand);
        unit = (try getTemporalUnitOption(realm, opts, "smallestUnit")) orelse
            return throwRangeError(realm, "smallestUnit is required");
    }
    try requireUnitInRange(realm, unit, .hour, .nanosecond);
    // §4.3.x ValidateTemporalRoundingIncrement(increment,
    // MaximumTemporalDurationRoundingIncrement(smallestUnit), false): the
    // increment must divide the next-larger unit and stay strictly below
    // it (hour < 24, minute/second < 60, sub-second < 1000) — NOT the
    // per-day "inclusive" rule Instant.round uses.
    if (!temporal.validateRoundingIncrement(increment, differenceDividend(unit), false)) {
        return throwRangeError(realm, "roundingIncrement is out of range for the smallestUnit");
    }
    const rounded = temporal.roundToIncrement(temporal.timeRecordToNanoseconds(t), increment * temporal.unitNanoseconds(unit), mode);
    const wrapped = @mod(rounded, @as(i128, 86_400_000_000_000));
    return createTemporalTime(realm, temporal.nanosecondsToTimeRecord(wrapped));
}

fn plainTimeUntil(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    return differenceTemporalTime(realm, this_value, args, false);
}

fn plainTimeSince(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    return differenceTemporalTime(realm, this_value, args, true);
}

/// §4.5.x DifferenceTemporalPlainTime — like the Instant difference, but
/// the operands are times-of-day (delta within ±24 h) and the default
/// largestUnit is "hour".
fn differenceTemporalTime(realm: *Realm, this_value: Value, args: []const Value, is_since: bool) NativeError!Value {
    const this_t = try requirePlainTime(realm, this_value);
    const other_t = try toTemporalTime(realm, argOr(args, 0, Value.undefined_), Value.undefined_);
    const opts = try getOptionsObject(realm, argOr(args, 1, Value.undefined_));

    const largest_opt = try getTemporalUnitOption(realm, opts, "largestUnit");
    const increment = try getRoundingIncrementOption(realm, opts);
    const mode = try getRoundingModeOption(realm, opts, .trunc);
    const smallest_opt = try getTemporalUnitOption(realm, opts, "smallestUnit");

    if (largest_opt) |lu| try requireUnitInRange(realm, lu, .hour, .nanosecond);
    const smallest = smallest_opt orelse temporal.LargestUnit.nanosecond;
    try requireUnitInRange(realm, smallest, .hour, .nanosecond);
    const largest = largest_opt orelse temporal.LargestUnit.hour;
    if (@intFromEnum(largest) > @intFromEnum(smallest)) {
        return throwRangeError(realm, "largestUnit must not be smaller than smallestUnit");
    }
    if (!temporal.validateRoundingIncrement(increment, differenceDividend(smallest), false)) {
        return throwRangeError(realm, "invalid roundingIncrement for the smallestUnit");
    }

    const diff = temporal.timeRecordToNanoseconds(other_t) - temporal.timeRecordToNanoseconds(this_t);
    const eff_mode = if (is_since) negateRoundingMode(mode) else mode;
    const rounded = temporal.roundToIncrement(diff, increment * temporal.unitNanoseconds(smallest), eff_mode);
    var dr = temporal.balanceTimeDuration(rounded, largest);
    if (is_since) {
        dr.days = negZero(dr.days);
        dr.hours = negZero(dr.hours);
        dr.minutes = negZero(dr.minutes);
        dr.seconds = negZero(dr.seconds);
        dr.milliseconds = negZero(dr.milliseconds);
        dr.microseconds = negZero(dr.microseconds);
        dr.nanoseconds = negZero(dr.nanoseconds);
    }
    return createTemporalDuration(realm, dr);
}

// ── §8 Temporal.Instant ────────────────────────────────────────────────────

fn installInstant(realm: *Realm, ns: *JSObject) !void {
    // §8.1.1 — `new`-only constructor, arity 1 (the epoch-nanoseconds
    // BigInt).
    const r = try installConstructor(realm, .{
        .name = "Instant",
        .ctor = instantConstructor,
        .arity = 1,
        .is_class = true,
        .set_home_object = true,
        .to_string_tag = "Temporal.Instant",
        .install_global = false,
    });
    const fn_obj = r.ctor;
    const proto = r.proto;

    try installNativeGetter(realm, proto, "epochMilliseconds", instantEpochMilliseconds);
    try installNativeGetter(realm, proto, "epochNanoseconds", instantEpochNanoseconds);

    try installNativeMethodOnProto(realm, proto, "add", instantAdd, 1);
    try installNativeMethodOnProto(realm, proto, "subtract", instantSubtract, 1);
    try installNativeMethodOnProto(realm, proto, "equals", instantEquals, 1);
    try installNativeMethodOnProto(realm, proto, "toString", instantToString, 0);
    try installNativeMethodOnProto(realm, proto, "toJSON", instantToJSON, 0);
    try installNativeMethodOnProto(realm, proto, "toLocaleString", instantToLocaleString, 0);
    try installNativeMethodOnProto(realm, proto, "valueOf", instantValueOf, 0);
    // Deferred deep-end methods — present with the right shape, but
    // they throw until the rounding / time-zone machinery lands.
    try installNativeMethodOnProto(realm, proto, "round", instantRound, 1);
    try installNativeMethodOnProto(realm, proto, "until", instantUntil, 1);
    try installNativeMethodOnProto(realm, proto, "since", instantSince, 1);
    try installNativeMethodOnProto(realm, proto, "toZonedDateTimeISO", instantToZonedDateTimeISO, 1);

    try installNativeMethod(realm, fn_obj, "from", instantFrom, 1);
    try installNativeMethod(realm, fn_obj, "fromEpochMilliseconds", instantFromEpochMilliseconds, 1);
    try installNativeMethod(realm, fn_obj, "fromEpochNanoseconds", instantFromEpochNanoseconds, 1);
    try installNativeMethod(realm, fn_obj, "compare", instantCompare, 2);

    realm.intrinsics.temporal_instant_constructor = fn_obj;
    realm.intrinsics.temporal_instant_prototype = proto;

    try setNonEnumerable(ns, realm.allocator, "Instant", heap_mod.taggedFunction(fn_obj));
}

/// §8.1.1 Temporal.Instant ( epochNanoseconds ). `new`-only. ToBigInt-
/// coerces the argument (so a numeric string parses as a BigInt and a
/// Number throws TypeError), then validates the epoch-ns range.
fn instantConstructor(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const inst = heap_mod.valueAsPlainObject(this_value) orelse
        return throwTypeError(realm, "Temporal.Instant constructor requires 'new'");
    // §8.1.1 step 2 — ToBigInt(epochNanoseconds) (§7.1.13).
    const bi_val = try bigint_builtin.toBigIntValue(realm, argOr(args, 0, Value.undefined_));
    const epoch_ns = try epochNsFromBigInt(realm, bi_val);
    try storeInstant(realm, inst, epoch_ns);
    return heap_mod.taggedObject(inst);
}

/// Extract a validated epoch-ns `i128` from a BigInt `Value`, throwing
/// RangeError when it is outside the representable instant range —
/// including BigInts too large to fit `i128` (`2n ** 128n`).
fn epochNsFromBigInt(realm: *Realm, bi_val: Value) NativeError!i128 {
    const bi = heap_mod.valueAsBigInt(bi_val) orelse
        return throwTypeError(realm, "expected a BigInt");
    if (!bi.fitsI128()) return throwRangeError(realm, "epoch nanoseconds are out of range");
    const ns = bi.toI128();
    if (!temporal.isValidEpochNanoseconds(ns)) {
        return throwRangeError(realm, "epoch nanoseconds are out of range");
    }
    return ns;
}

fn storeInstant(realm: *Realm, inst: *JSObject, epoch_ns: i128) NativeError!void {
    const rec = realm.allocator.create(TemporalRecord) catch return error.OutOfMemory;
    rec.* = .{ .instant = .{ .epoch_ns = epoch_ns } };
    inst.setTemporalRecord(realm.allocator, rec) catch return error.OutOfMemory;
}

/// §8.1.x CreateTemporalInstant — allocate a fresh Instant with the
/// realm prototype. Exposed (`pub`) so `Date.prototype.toTemporalInstant`
/// can mint the bridged Instant.
pub fn createTemporalInstant(realm: *Realm, epoch_ns: i128) NativeError!Value {
    const inst = realm.heap.allocateObject() catch return error.OutOfMemory;
    realm.heap.setObjectPrototype(inst, realm.intrinsics.temporal_instant_prototype.?);
    try storeInstant(realm, inst, epoch_ns);
    return heap_mod.taggedObject(inst);
}

/// §8.x RequireInternalSlot(instant, [[InitializedTemporalInstant]]).
fn requireInstant(realm: *Realm, this_value: Value) NativeError!i128 {
    const obj = heap_mod.valueAsPlainObject(this_value) orelse
        return throwTypeError(realm, "not a Temporal.Instant");
    const rec = obj.getTemporalRecord() orelse
        return throwTypeError(realm, "not a Temporal.Instant");
    return switch (rec.*) {
        .instant => |i| i.epoch_ns,
        else => throwTypeError(realm, "not a Temporal.Instant"),
    };
}

/// §8.5.x ToTemporalInstant — a Temporal.Instant (copy), or any other
/// value coerced via ToPrimitive(string) and parsed as an ISO instant
/// string. A non-string primitive (Number, …) throws TypeError; a
/// malformed string throws RangeError. (Temporal.ZonedDateTime would
/// also resolve here once it ships.)
fn toTemporalInstant(realm: *Realm, item: Value) NativeError!i128 {
    var v = item;
    // Any Object — plain OR callable (a function is still an Object per
    // the spec) — coerces via ToPrimitive(string); a branded
    // Temporal.Instant short-circuits to its epoch ns. A non-string,
    // non-object primitive (Number, Symbol, …) falls through to the
    // TypeError below.
    if (heap_mod.valueAsPlainObject(v) != null or heap_mod.valueAsFunction(v) != null) {
        if (heap_mod.valueAsPlainObject(v)) |obj| {
            if (obj.getTemporalRecord()) |rec| {
                switch (rec.*) {
                    .instant => |i| return i.epoch_ns,
                    // §8.5.x ToTemporalInstant step 1.b — a ZonedDateTime
                    // converts via its [[EpochNanoseconds]] slot directly;
                    // no ToPrimitive / toString is observed.
                    .zoned_date_time => |zdt| return zdt.epoch_ns,
                    else => {},
                }
            }
        }
        v = try intrinsics.toPrimitive(realm, v, .string);
    }
    if (!v.isString()) {
        return throwTypeError(realm, "Temporal.Instant.from expects a Temporal.Instant or ISO 8601 string");
    }
    const s: *JSString = @ptrCast(@alignCast(v.asString()));
    return temporal.parseInstantString(s.flatBytes()) catch
        return throwRangeError(realm, "invalid ISO 8601 instant string");
}

/// §8.4.4 get Temporal.Instant.prototype.epochMilliseconds — floor of
/// the epoch ns divided by 10^6, as a Number (always exact: |ms| ≤
/// 8.64×10^15 < 2^53).
fn instantEpochMilliseconds(realm: *Realm, t: Value, a: []const Value) NativeError!Value {
    _ = a;
    const ns = try requireInstant(realm, t);
    const ms = @divFloor(ns, 1_000_000);
    return Value.fromDouble(@floatFromInt(ms));
}

/// §8.4.5 get Temporal.Instant.prototype.epochNanoseconds — the slot
/// value as a BigInt.
fn instantEpochNanoseconds(realm: *Realm, t: Value, a: []const Value) NativeError!Value {
    _ = a;
    const ns = try requireInstant(realm, t);
    const bi = realm.heap.allocateBigInt(ns) catch return error.OutOfMemory;
    return heap_mod.taggedBigInt(bi);
}

/// §8.2.2 Temporal.Instant.from ( item ).
fn instantFrom(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = this_value;
    const ns = try toTemporalInstant(realm, argOr(args, 0, Value.undefined_));
    return createTemporalInstant(realm, ns);
}

/// §8.2.3 Temporal.Instant.fromEpochMilliseconds ( epochMilliseconds ).
fn instantFromEpochMilliseconds(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = this_value;
    const num = try toNumber(realm, argOr(args, 0, Value.undefined_));
    const d = numberToF64(num);
    // §21.2.1.1.1 NumberToBigInt — RangeError on a non-finite or
    // non-integral Number.
    if (!std.math.isFinite(d) or @trunc(d) != d) {
        return throwRangeError(realm, "epoch milliseconds must be an integer");
    }
    // |ms| ≤ 8.64×10^15 ⇔ |ns| ≤ 8.64×10^21; the bound also keeps the
    // i128 conversion in range.
    if (d < -8_640_000_000_000_000.0 or d > 8_640_000_000_000_000.0) {
        return throwRangeError(realm, "epoch milliseconds are out of range");
    }
    const ns: i128 = @as(i128, @intFromFloat(d)) * 1_000_000;
    return createTemporalInstant(realm, ns);
}

/// §8.2.4 Temporal.Instant.fromEpochNanoseconds ( epochNanoseconds ).
fn instantFromEpochNanoseconds(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = this_value;
    const bi_val = try bigint_builtin.toBigIntValue(realm, argOr(args, 0, Value.undefined_));
    const ns = try epochNsFromBigInt(realm, bi_val);
    return createTemporalInstant(realm, ns);
}

/// §8.2.5 Temporal.Instant.compare ( one, two ).
fn instantCompare(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = this_value;
    const a = try toTemporalInstant(realm, argOr(args, 0, Value.undefined_));
    const b = try toTemporalInstant(realm, argOr(args, 1, Value.undefined_));
    return Value.fromInt32(temporal.compareInstant(a, b));
}

/// §8.4.9 Temporal.Instant.prototype.equals ( other ).
fn instantEquals(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const a = try requireInstant(realm, this_value);
    const b = try toTemporalInstant(realm, argOr(args, 0, Value.undefined_));
    return Value.fromBool(a == b);
}

fn instantAdd(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    return instantAddSubtract(realm, this_value, argOr(args, 0, Value.undefined_), 1);
}

fn instantSubtract(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    return instantAddSubtract(realm, this_value, argOr(args, 0, Value.undefined_), -1);
}

/// §8.4.6 / §8.4.7 AddDurationToInstant — fold a time-only Duration
/// into the epoch nanoseconds. `sign` is +1 for `add`, -1 for
/// `subtract`. §8 disallows calendar units (years / months / weeks /
/// days): a non-zero one throws RangeError.
fn instantAddSubtract(realm: *Realm, this_value: Value, duration_like: Value, sign: i128) NativeError!Value {
    const epoch_ns = try requireInstant(realm, this_value);
    const d = try toTemporalDuration(realm, duration_like);
    // ToTemporalDuration's property-bag path does not itself run
    // IsValidDuration, so a mixed-sign / out-of-range duration-like
    // reaches here unvalidated — reject it (RangeError).
    if (!temporal.isValidDuration(d)) {
        return throwRangeError(realm, "Duration values are out of range");
    }
    if (d.years != 0 or d.months != 0 or d.weeks != 0 or d.days != 0) {
        return throwRangeError(realm, "Temporal.Instant arithmetic does not allow calendar units (years/months/weeks/days)");
    }
    const delta = temporal.timeDurationNanoseconds(d) * sign;
    const result = temporal.addInstant(epoch_ns, delta) orelse
        return throwRangeError(realm, "Temporal.Instant arithmetic result is out of range");
    return createTemporalInstant(realm, result);
}

/// §8.4.10 Temporal.Instant.prototype.toString ( [options] ) — read
/// fractionalSecondDigits, roundingMode, smallestUnit, timeZone (in that
/// order, before any validation), round the instant to the resolved
/// unit/increment, then render. With no `timeZone` the output is the UTC
/// wall clock with a trailing `Z`; with one it is that zone's wall clock
/// plus its numeric `±HH:MM` offset.
fn instantToString(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const ns = try requireInstant(realm, this_value);
    const options = argOr(args, 0, Value.undefined_);
    const frac = try getFractionalSecondDigitsOption(realm, options);
    const opts_obj = try getOptionsObject(realm, options);
    const mode = try getRoundingModeOption(realm, opts_obj, .trunc);
    const smallest = try getTemporalUnitOption(realm, opts_obj, "smallestUnit");
    var time_zone: ?temporal.TimeZone = null;
    if (opts_obj) |o| {
        const tz_val = try getPropertyChain(realm, o, "timeZone");
        if (!tz_val.isUndefined()) time_zone = try toTimeZoneArg(realm, tz_val);
    }
    try requireToStringSmallestUnit(realm, smallest);

    const prec = toSecondsStringPrecision(smallest, frac);
    const inc_ns = prec.increment * temporal.unitNanoseconds(prec.unit);
    const rounded_ns = temporal.roundToIncrementAsIfPositive(ns, inc_ns, mode);
    if (!temporal.isValidEpochNanoseconds(rounded_ns)) {
        return throwRangeError(realm, "rounded Instant is out of range");
    }
    var buf: [48]u8 = undefined;
    const s = temporal.instantToString(rounded_ns, &buf, prec.precision, time_zone);
    const js = realm.heap.allocateString(s) catch return error.OutOfMemory;
    return Value.fromString(js);
}

/// §8.4.11 Temporal.Instant.prototype.toJSON — always `auto`, UTC.
fn instantToJSON(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    const ns = try requireInstant(realm, this_value);
    var buf: [48]u8 = undefined;
    const s = temporal.instantToString(ns, &buf, .auto, null);
    const js = realm.heap.allocateString(s) catch return error.OutOfMemory;
    return Value.fromString(js);
}

fn instantToLocaleString(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    return instantToJSON(realm, this_value, args);
}

/// §8.4.12 Temporal.Instant.prototype.valueOf — always throws
/// (Temporal values are not relationally comparable via the operators).
fn instantValueOf(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = this_value;
    _ = args;
    return throwTypeError(realm, "Called valueOf on a Temporal.Instant; use compare() instead");
}

// ── §13 Rounding / difference option parsing (shared) ─────────────────────

/// §13.x GetOptionsObject — the options object, or null when options is
/// undefined. A non-object, non-undefined value throws TypeError. A
/// callable options bag is tolerated as empty (property reads want a
/// plain object); function-valued options are a rare edge.
fn getOptionsObject(realm: *Realm, options: Value) NativeError!?*JSObject {
    if (options.isUndefined()) return null;
    if (heap_mod.valueAsPlainObject(options)) |o| return o;
    if (heap_mod.valueAsFunction(options) != null) return null;
    return throwTypeError(realm, "options must be an object or undefined");
}

/// §13.x GetRoundingModeOption.
fn getRoundingModeOption(realm: *Realm, opts: ?*JSObject, default_mode: temporal.RoundingMode) NativeError!temporal.RoundingMode {
    const obj = opts orelse return default_mode;
    const v = try getPropertyChain(realm, obj, "roundingMode");
    if (v.isUndefined()) return default_mode;
    const s = try stringifyArg(realm, v);
    return temporal.parseRoundingMode(s.flatBytes()) orelse
        throwRangeError(realm, "invalid roundingMode");
}

/// §13.x GetRoundingIncrementOption — ToNumber, reject non-finite,
/// truncate, then require an integer in [1, 1e9].
fn getRoundingIncrementOption(realm: *Realm, opts: ?*JSObject) NativeError!i128 {
    const obj = opts orelse return 1;
    const v = try getPropertyChain(realm, obj, "roundingIncrement");
    if (v.isUndefined()) return 1;
    const d = numberToF64(try toNumber(realm, v));
    if (!std.math.isFinite(d)) return throwRangeError(realm, "roundingIncrement must be finite");
    const t = std.math.trunc(d);
    if (t < 1 or t > 1_000_000_000) return throwRangeError(realm, "roundingIncrement is out of range");
    return @intFromFloat(t);
}

/// §13.x GetTemporalUnitValuedOption — read a unit option (ToString),
/// returning null for undefined / "auto". Rejects only an *unrecognised*
/// unit name here; the operation-specific allowed-range check is a later
/// algorithmic validation (see `requireUnitInRange`), so every option is
/// read before any range error fires.
fn getTemporalUnitOption(realm: *Realm, opts: ?*JSObject, key: []const u8) NativeError!?temporal.LargestUnit {
    const obj = opts orelse return null;
    const v = try getPropertyChain(realm, obj, key);
    if (v.isUndefined()) return null;
    const s = try stringifyArg(realm, v);
    const bytes = s.flatBytes();
    if (std.mem.eql(u8, bytes, "auto")) return null;
    return temporal.parseTemporalUnit(bytes) orelse
        throwRangeError(realm, "invalid unit value");
}

/// Reject a resolved unit outside the operation's allowed magnitude
/// range [largest_allowed, smallest_allowed]. Run after all options are
/// read, per GetDifferenceSettings' read-then-validate ordering.
fn requireUnitInRange(realm: *Realm, unit: temporal.LargestUnit, largest_allowed: temporal.LargestUnit, smallest_allowed: temporal.LargestUnit) NativeError!void {
    if (@intFromEnum(unit) < @intFromEnum(largest_allowed) or @intFromEnum(unit) > @intFromEnum(smallest_allowed)) {
        return throwRangeError(realm, "unit is outside the allowed range");
    }
}

/// §13.x NegateRoundingMode — lets `since` round in the reverse
/// direction of `until`. Only the directed ceil/floor pair flips; the
/// sign-symmetric modes are unchanged.
fn negateRoundingMode(mode: temporal.RoundingMode) temporal.RoundingMode {
    return switch (mode) {
        .ceil => .floor,
        .floor => .ceil,
        .half_ceil => .half_floor,
        .half_floor => .half_ceil,
        else => mode,
    };
}

/// §8.4.x Temporal.Instant.prototype.round ( roundTo ). A string
/// `roundTo` is shorthand for `{ smallestUnit }`; smallestUnit is
/// required (hour..nanosecond). roundingIncrement (default 1) must
/// divide a 24-hour day evenly; roundingMode defaults to halfExpand.
fn instantRound(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const ns = try requireInstant(realm, this_value);
    const round_to = argOr(args, 0, Value.undefined_);
    if (round_to.isUndefined()) {
        return throwTypeError(realm, "Temporal.Instant.prototype.round requires a smallestUnit");
    }

    var unit: temporal.LargestUnit = undefined;
    var increment: i128 = 1;
    var mode: temporal.RoundingMode = .half_expand;
    if (round_to.isString()) {
        const s: *JSString = @ptrCast(@alignCast(round_to.asString()));
        unit = temporal.parseTemporalUnit(s.flatBytes()) orelse
            return throwRangeError(realm, "invalid smallestUnit");
        if (@intFromEnum(unit) < @intFromEnum(temporal.LargestUnit.hour)) {
            return throwRangeError(realm, "smallestUnit is outside the allowed range");
        }
    } else {
        const opts = try getOptionsObject(realm, round_to);
        increment = try getRoundingIncrementOption(realm, opts);
        mode = try getRoundingModeOption(realm, opts, .half_expand);
        unit = (try getTemporalUnitOption(realm, opts, "smallestUnit")) orelse
            return throwRangeError(realm, "smallestUnit is required");
        try requireUnitInRange(realm, unit, .hour, .nanosecond);
    }

    // increment × unit-span must divide a solar day evenly (inclusive).
    const per_day = @divExact(@as(i128, 86_400_000_000_000), temporal.unitNanoseconds(unit));
    if (!temporal.validateRoundingIncrement(increment, per_day, true)) {
        return throwRangeError(realm, "roundingIncrement does not divide evenly into a day");
    }

    const rounded = temporal.roundToIncrementAsIfPositive(ns, increment * temporal.unitNanoseconds(unit), mode);
    if (!temporal.isValidEpochNanoseconds(rounded)) {
        return throwRangeError(realm, "rounded instant is out of range");
    }
    return createTemporalInstant(realm, rounded);
}

fn instantUntil(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    return differenceTemporalInstant(realm, this_value, args, false);
}

fn instantSince(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    return differenceTemporalInstant(realm, this_value, args, true);
}

/// Dividend for a difference roundingIncrement: the count of `unit` in
/// the next-larger unit (non-inclusive bound). Day and above are
/// disallowed for Instant differences.
fn differenceDividend(unit: temporal.LargestUnit) i128 {
    return switch (unit) {
        .hour => 24,
        .minute, .second => 60,
        .millisecond, .microsecond, .nanosecond => 1000,
        else => unreachable,
    };
}

/// §8.4.x DifferenceTemporalInstant — `until` (sign +) / `since` (sign
/// −). Reads the difference settings (largestUnit, increment, mode,
/// smallestUnit in that order), rounds the epoch-ns delta, and balances
/// it into a time-only Duration. `since` negates the rounding mode and
/// the result, so `a.since(b)` equals `a.until(b).negated()`.
fn differenceTemporalInstant(realm: *Realm, this_value: Value, args: []const Value, is_since: bool) NativeError!Value {
    const this_ns = try requireInstant(realm, this_value);
    const other_ns = try toTemporalInstant(realm, argOr(args, 0, Value.undefined_));
    const opts = try getOptionsObject(realm, argOr(args, 1, Value.undefined_));

    // GetDifferenceSettings read order: largestUnit, increment, mode,
    // smallestUnit. Allowed units: hour..nanosecond.
    const largest_opt = try getTemporalUnitOption(realm, opts, "largestUnit");
    const increment = try getRoundingIncrementOption(realm, opts);
    const mode = try getRoundingModeOption(realm, opts, .trunc);
    const smallest_opt = try getTemporalUnitOption(realm, opts, "smallestUnit");

    // All options read; now validate. Units must be in range (hour..ns).
    if (largest_opt) |lu| try requireUnitInRange(realm, lu, .hour, .nanosecond);
    const smallest = smallest_opt orelse temporal.LargestUnit.nanosecond;
    try requireUnitInRange(realm, smallest, .hour, .nanosecond);

    // Default largestUnit is the larger of smallestUnit and "second".
    const largest = largest_opt orelse (if (@intFromEnum(smallest) < @intFromEnum(temporal.LargestUnit.second))
        smallest
    else
        temporal.LargestUnit.second);
    if (@intFromEnum(largest) > @intFromEnum(smallest)) {
        return throwRangeError(realm, "largestUnit must not be smaller than smallestUnit");
    }
    if (!temporal.validateRoundingIncrement(increment, differenceDividend(smallest), false)) {
        return throwRangeError(realm, "invalid roundingIncrement for the smallestUnit");
    }

    const diff = other_ns - this_ns;
    const eff_mode = if (is_since) negateRoundingMode(mode) else mode;
    const rounded = temporal.roundToIncrement(diff, increment * temporal.unitNanoseconds(smallest), eff_mode);
    var d = temporal.balanceTimeDuration(rounded, largest);
    if (is_since) {
        d.days = negZero(d.days);
        d.hours = negZero(d.hours);
        d.minutes = negZero(d.minutes);
        d.seconds = negZero(d.seconds);
        d.milliseconds = negZero(d.milliseconds);
        d.microseconds = negZero(d.microseconds);
        d.nanoseconds = negZero(d.nanoseconds);
    }
    return createTemporalDuration(realm, d);
}

/// §8.3.x Temporal.Instant.prototype.toZonedDateTimeISO ( timeZone ) —
/// pair this instant with a time zone (ISO calendar) to form a
/// ZonedDateTime at the same epoch nanoseconds.
fn instantToZonedDateTimeISO(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const epoch = try requireInstant(realm, this_value);
    const tz = try toTimeZoneArg(realm, argOr(args, 0, Value.undefined_));
    return createTemporalZonedDateTime(realm, .{ .epoch_ns = epoch, .time_zone = tz });
}

// ── §3 Temporal.PlainDate (ISO calendar) ───────────────────────────────────

fn installPlainDate(realm: *Realm, ns: *JSObject) !void {
    // §3.1.1 — `new`-only constructor (year, month, day, [calendar]).
    const r = try installConstructor(realm, .{
        .name = "PlainDate",
        .ctor = plainDateConstructor,
        .arity = 3,
        .is_class = true,
        .set_home_object = true,
        .to_string_tag = "Temporal.PlainDate",
        .install_global = false,
    });
    const fn_obj = r.ctor;
    const proto = r.proto;

    try installNativeGetter(realm, proto, "calendarId", plainDateCalendarId);
    try installNativeGetter(realm, proto, "year", plainDateYear);
    try installNativeGetter(realm, proto, "month", plainDateMonth);
    try installNativeGetter(realm, proto, "monthCode", plainDateMonthCode);
    try installNativeGetter(realm, proto, "day", plainDateDay);
    try installNativeGetter(realm, proto, "dayOfWeek", plainDateDayOfWeek);
    try installNativeGetter(realm, proto, "dayOfYear", plainDateDayOfYear);
    try installNativeGetter(realm, proto, "weekOfYear", plainDateWeekOfYear);
    try installNativeGetter(realm, proto, "yearOfWeek", plainDateYearOfWeek);
    try installNativeGetter(realm, proto, "daysInWeek", plainDateDaysInWeek);
    try installNativeGetter(realm, proto, "daysInMonth", plainDateDaysInMonth);
    try installNativeGetter(realm, proto, "daysInYear", plainDateDaysInYear);
    try installNativeGetter(realm, proto, "monthsInYear", plainDateMonthsInYear);
    try installNativeGetter(realm, proto, "inLeapYear", plainDateInLeapYear);
    try installNativeGetter(realm, proto, "era", plainDateEra);
    try installNativeGetter(realm, proto, "eraYear", plainDateEraYear);

    try installNativeMethodOnProto(realm, proto, "with", plainDateWith, 1);
    try installNativeMethodOnProto(realm, proto, "equals", plainDateEquals, 1);
    try installNativeMethodOnProto(realm, proto, "toString", plainDateToString, 0);
    try installNativeMethodOnProto(realm, proto, "toJSON", plainDateToJSON, 0);
    try installNativeMethodOnProto(realm, proto, "toLocaleString", plainDateToLocaleString, 0);
    try installNativeMethodOnProto(realm, proto, "valueOf", plainDateValueOf, 0);
    // Deferred — date arithmetic / conversions to types Cynic doesn't ship yet.
    try installNativeMethodOnProto(realm, proto, "add", plainDateAdd, 1);
    try installNativeMethodOnProto(realm, proto, "subtract", plainDateSubtract, 1);
    try installNativeMethodOnProto(realm, proto, "until", plainDateUntil, 1);
    try installNativeMethodOnProto(realm, proto, "since", plainDateSince, 1);
    try installNativeMethodOnProto(realm, proto, "withCalendar", plainDateWithCalendar, 1);
    try installNativeMethodOnProto(realm, proto, "toPlainYearMonth", plainDateToPlainYearMonth, 0);
    try installNativeMethodOnProto(realm, proto, "toPlainMonthDay", plainDateToPlainMonthDay, 0);
    try installNativeMethodOnProto(realm, proto, "toPlainDateTime", plainDateToPlainDateTime, 1);
    try installNativeMethodOnProto(realm, proto, "toZonedDateTime", plainDateToZonedDateTime, 1);

    try installNativeMethod(realm, fn_obj, "from", plainDateFrom, 1);
    try installNativeMethod(realm, fn_obj, "compare", plainDateCompare, 2);

    realm.intrinsics.temporal_plain_date_constructor = fn_obj;
    realm.intrinsics.temporal_plain_date_prototype = proto;
    try setNonEnumerable(ns, realm.allocator, "PlainDate", heap_mod.taggedFunction(fn_obj));
}

/// Coerce a truncated date field to i64, rejecting values far outside
/// the representable range (which also guards the later i32 cast).
fn dateFieldToI64(realm: *Realm, v: f64) NativeError!i64 {
    if (v < -1_000_000_000.0 or v > 1_000_000_000.0) return throwRangeError(realm, "date field is out of range");
    return @intFromFloat(v);
}

/// ToPositiveIntegerWithTruncation — the conversion the Calendar Field
/// Descriptors table assigns to the `month` and `day` fields (whereas
/// `year` uses plain ToIntegerWithTruncation). The ≤ 0 RangeError fires
/// at field-read time, *before* the overflow option is read — pinned by
/// with/options-wrong-type.js (an out-of-range month throws RangeError
/// even when the options argument is a primitive that would otherwise
/// TypeError) and from/negative-month.js.
fn readPositiveDateField(realm: *Realm, v: Value) NativeError!i64 {
    const n = try dateFieldToI64(realm, try toIntegerWithTruncation(realm, v));
    if (n < 1) return throwRangeError(realm, "month and day fields must be positive integers");
    return n;
}

/// §3.1.1 — the `calendar` argument must be undefined or a string that
/// canonicalises to "iso8601" (Cynic ships only the ISO calendar). A
/// non-string is a TypeError; an unsupported/unknown calendar string is
/// a RangeError.
fn requireISOCalendar(realm: *Realm, calendar: Value) NativeError!void {
    if (calendar.isUndefined()) return;
    if (!calendar.isString()) return throwTypeError(realm, "calendar must be a string");
    const s: *JSString = @ptrCast(@alignCast(calendar.asString()));
    if (!std.ascii.eqlIgnoreCase(s.flatBytes(), "iso8601")) {
        return throwRangeError(realm, "only the iso8601 calendar is supported");
    }
}

/// ToTemporalCalendarIdentifier for the `calendar` field of a Temporal
/// date-like property bag (§12.2.x). `undefined` keeps the ISO default.
/// An object carrying a calendar-bearing Temporal internal slot
/// (PlainDate / PlainDateTime / PlainYearMonth / PlainMonthDay /
/// ZonedDateTime) contributes its `[[Calendar]]` — always "iso8601" in
/// Cynic — and is accepted via the internal-slot fast path; a
/// Temporal.Instant / Duration / PlainTime (no `[[Calendar]]`), any other
/// object, or any non-string primitive is a TypeError. A calendar
/// *string* is canonicalised (CanonicalizeCalendar): it must be the bare
/// ASCII "iso8601" id, or a parseable ISO 8601 string whose `[u-ca=…]`
/// annotation (when present) names the ISO calendar — every other string
/// (empty, unknown id, non-ASCII case fold like dotted-İ, year-zero,
/// unknown annotation) is a RangeError. Cynic ships only the ISO calendar.
/// (Distinct from the constructor's `requireISOCalendar`, which accepts a
/// bare calendar id only — no embedded ISO string.)
fn requireCalendarFieldType(realm: *Realm, calendar: Value) NativeError!void {
    if (calendar.isUndefined()) return;
    return toTemporalCalendarIdentifier(realm, calendar);
}

/// §13.x ToTemporalCalendarIdentifier — the bare abstract operation, with no
/// `undefined`-means-default special case. An object carrying a
/// calendar-bearing Temporal internal slot (PlainDate / PlainDateTime /
/// PlainYearMonth / PlainMonthDay / ZonedDateTime) contributes its
/// `[[Calendar]]` (always "iso8601" in Cynic) and is accepted; a
/// Temporal.Instant / Duration / PlainTime (no `[[Calendar]]`), any other
/// object, or any non-string primitive (including `undefined`) is a
/// TypeError. A calendar *string* must be the bare ASCII "iso8601" id or a
/// parseable ISO 8601 string whose `[u-ca=…]` annotation (when present)
/// names the ISO calendar — every other string is a RangeError. Used by
/// `withCalendar`, where the argument is a required value passed straight to
/// ToTemporalCalendarIdentifier; `requireCalendarFieldType` wraps this for the
/// property-bag `calendar` field, where an absent (`undefined`) field instead
/// keeps the ISO default.
fn toTemporalCalendarIdentifier(realm: *Realm, calendar: Value) NativeError!void {
    if (heap_mod.valueAsPlainObject(calendar)) |obj| {
        if (obj.getTemporalRecord()) |rec| switch (rec.*) {
            // §13.x ToTemporalCalendarIdentifier step 1.a — read the
            // `[[Calendar]]` of a calendar-bearing Temporal object.
            .plain_date, .plain_date_time, .plain_year_month, .plain_month_day, .zoned_date_time => return,
            // Instant / Duration / PlainTime have no `[[Calendar]]`.
            else => {},
        };
        return throwTypeError(realm, "calendar must be a string or a calendar-bearing Temporal object");
    }
    if (!calendar.isString()) return throwTypeError(realm, "calendar must be a string");
    const s: *JSString = @ptrCast(@alignCast(calendar.asString()));
    const bytes = s.flatBytes();
    // Bare calendar id — ASCII case-insensitive "iso8601" (the dotted-İ
    // fixture relies on this being ASCII-only, never a Unicode fold).
    if (std.ascii.eqlIgnoreCase(bytes, "iso8601")) return;
    // Otherwise it must be a full ISO 8601 string. The per-type parsers
    // each validate an embedded `[u-ca=…]` annotation against the ISO
    // calendar and reject malformed forms (year-zero extended year, …),
    // so any one accepting it proves the calendar is the ISO calendar.
    if (calendarStringIsISO(bytes)) return;
    return throwRangeError(realm, "invalid calendar identifier");
}

/// True when `bytes` parses as any ISO 8601 Temporal string whose calendar
/// (annotation, defaulting to ISO) is the supported ISO calendar — the
/// string branch of ParseTemporalCalendarString limited to Cynic's scope.
fn calendarStringIsISO(bytes: []const u8) bool {
    if (temporal.parseTemporalDateTimeString(bytes)) |_| return true else |_| {}
    if (temporal.parseTemporalDateString(bytes)) |_| return true else |_| {}
    if (temporal.parseTemporalYearMonthString(bytes)) |_| return true else |_| {}
    if (temporal.parseTemporalMonthDayString(bytes)) |_| return true else |_| {}
    if (temporal.parseTemporalTimeString(bytes)) |_| return true else |_| {}
    if (temporal.parseInstantString(bytes)) |_| return true else |_| {}
    return false;
}

fn storePlainDate(realm: *Realm, inst: *JSObject, rec: PlainDateRecord) NativeError!void {
    const r = realm.allocator.create(TemporalRecord) catch return error.OutOfMemory;
    r.* = .{ .plain_date = rec };
    inst.setTemporalRecord(realm.allocator, r) catch return error.OutOfMemory;
}

fn createTemporalDate(realm: *Realm, rec: PlainDateRecord) NativeError!Value {
    const inst = realm.heap.allocateObject() catch return error.OutOfMemory;
    realm.heap.setObjectPrototype(inst, realm.intrinsics.temporal_plain_date_prototype.?);
    try storePlainDate(realm, inst, rec);
    return heap_mod.taggedObject(inst);
}

fn requirePlainDate(realm: *Realm, this_value: Value) NativeError!PlainDateRecord {
    const obj = heap_mod.valueAsPlainObject(this_value) orelse
        return throwTypeError(realm, "not a Temporal.PlainDate");
    const rec = obj.getTemporalRecord() orelse
        return throwTypeError(realm, "not a Temporal.PlainDate");
    return switch (rec.*) {
        .plain_date => |pd| pd,
        else => throwTypeError(realm, "not a Temporal.PlainDate"),
    };
}

/// §3.1.1 Temporal.PlainDate ( isoYear, isoMonth, isoDay [, calendar] ).
fn plainDateConstructor(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const inst = heap_mod.valueAsPlainObject(this_value) orelse
        return throwTypeError(realm, "Temporal.PlainDate constructor requires 'new'");
    const y = try dateFieldToI64(realm, try toIntegerWithTruncation(realm, argOr(args, 0, Value.undefined_)));
    const m = try dateFieldToI64(realm, try toIntegerWithTruncation(realm, argOr(args, 1, Value.undefined_)));
    const d = try dateFieldToI64(realm, try toIntegerWithTruncation(realm, argOr(args, 2, Value.undefined_)));
    try requireISOCalendar(realm, argOr(args, 3, Value.undefined_));
    const rec = temporal.regulateISODate(y, m, d, true) orelse
        return throwRangeError(realm, "PlainDate is out of range");
    try storePlainDate(realm, inst, rec);
    return heap_mod.taggedObject(inst);
}

fn plainDateCalendarId(realm: *Realm, t: Value, a: []const Value) NativeError!Value {
    _ = a;
    _ = try requirePlainDate(realm, t);
    const js = realm.heap.allocateString("iso8601") catch return error.OutOfMemory;
    return Value.fromString(js);
}
fn plainDateYear(realm: *Realm, t: Value, a: []const Value) NativeError!Value {
    _ = a;
    return Value.fromInt32((try requirePlainDate(realm, t)).iso_year);
}
fn plainDateMonth(realm: *Realm, t: Value, a: []const Value) NativeError!Value {
    _ = a;
    return Value.fromInt32(@intCast((try requirePlainDate(realm, t)).iso_month));
}
fn plainDateDay(realm: *Realm, t: Value, a: []const Value) NativeError!Value {
    _ = a;
    return Value.fromInt32(@intCast((try requirePlainDate(realm, t)).iso_day));
}
fn plainDateMonthCode(realm: *Realm, t: Value, a: []const Value) NativeError!Value {
    _ = a;
    const rec = try requirePlainDate(realm, t);
    const mc = [_]u8{ 'M', '0' + @as(u8, @intCast(rec.iso_month / 10)), '0' + @as(u8, @intCast(rec.iso_month % 10)) };
    const js = realm.heap.allocateString(&mc) catch return error.OutOfMemory;
    return Value.fromString(js);
}
fn plainDateDayOfWeek(realm: *Realm, t: Value, a: []const Value) NativeError!Value {
    _ = a;
    const rec = try requirePlainDate(realm, t);
    return Value.fromInt32(temporal.isoDayOfWeek(rec.iso_year, rec.iso_month, rec.iso_day));
}
fn plainDateDayOfYear(realm: *Realm, t: Value, a: []const Value) NativeError!Value {
    _ = a;
    const rec = try requirePlainDate(realm, t);
    return Value.fromInt32(temporal.isoDayOfYear(rec.iso_year, rec.iso_month, rec.iso_day));
}
fn plainDateWeekOfYear(realm: *Realm, t: Value, a: []const Value) NativeError!Value {
    _ = a;
    const rec = try requirePlainDate(realm, t);
    return Value.fromInt32(temporal.isoWeekOfYear(rec.iso_year, rec.iso_month, rec.iso_day).week);
}
fn plainDateYearOfWeek(realm: *Realm, t: Value, a: []const Value) NativeError!Value {
    _ = a;
    const rec = try requirePlainDate(realm, t);
    return Value.fromInt32(temporal.isoWeekOfYear(rec.iso_year, rec.iso_month, rec.iso_day).year);
}
fn plainDateDaysInWeek(realm: *Realm, t: Value, a: []const Value) NativeError!Value {
    _ = a;
    _ = try requirePlainDate(realm, t);
    return Value.fromInt32(7);
}
fn plainDateDaysInMonth(realm: *Realm, t: Value, a: []const Value) NativeError!Value {
    _ = a;
    const rec = try requirePlainDate(realm, t);
    return Value.fromInt32(@intCast(temporal.daysInIsoMonth(rec.iso_year, rec.iso_month)));
}
fn plainDateDaysInYear(realm: *Realm, t: Value, a: []const Value) NativeError!Value {
    _ = a;
    const rec = try requirePlainDate(realm, t);
    return Value.fromInt32(temporal.isoDaysInYear(rec.iso_year));
}
fn plainDateMonthsInYear(realm: *Realm, t: Value, a: []const Value) NativeError!Value {
    _ = a;
    _ = try requirePlainDate(realm, t);
    return Value.fromInt32(12);
}
fn plainDateInLeapYear(realm: *Realm, t: Value, a: []const Value) NativeError!Value {
    _ = a;
    const rec = try requirePlainDate(realm, t);
    return Value.fromBool(temporal.isLeapYear(rec.iso_year));
}
fn plainDateEra(realm: *Realm, t: Value, a: []const Value) NativeError!Value {
    _ = a;
    _ = try requirePlainDate(realm, t);
    return Value.undefined_; // ISO calendar has no era
}
fn plainDateEraYear(realm: *Realm, t: Value, a: []const Value) NativeError!Value {
    _ = a;
    _ = try requirePlainDate(realm, t);
    return Value.undefined_;
}

/// §3.5.x parse an ISO monthCode ("M01".."M12"; no leap month in ISO).
/// The `monthCode` field must be a primitive String — a number, bigint,
/// boolean, Symbol, null, or object is a TypeError (it is never coerced),
/// distinct from the RangeError for a malformed string.
fn parseMonthCode(realm: *Realm, v: Value) NativeError!i64 {
    // §13.x ToMonthCode is ToPrimitiveAndRequireString: an object coerces via
    // its `toString`; a non-string primitive is a TypeError before any
    // format check. The grammar (`M` + two digits) is then validated here so
    // an ill-formed code is a RangeError before a later field is read.
    const prim = try intrinsics.toPrimitive(realm, v, .string);
    if (!prim.isString()) return throwTypeError(realm, "monthCode must be a string");
    const s: *JSString = @ptrCast(@alignCast(prim.asString()));
    const b = s.flatBytes();
    if (b.len != 3 or b[0] != 'M' or b[1] < '0' or b[1] > '9' or b[2] < '0' or b[2] > '9') {
        return throwRangeError(realm, "invalid monthCode");
    }
    const m: i64 = @as(i64, b[1] - '0') * 10 + @as(i64, b[2] - '0');
    if (m < 1 or m > 12) return throwRangeError(realm, "invalid monthCode");
    return m;
}

/// §3.5.x ISODateFromFields — read year, month/monthCode, day off a
/// property bag and regulate per `options`.
fn toISODateFields(realm: *Realm, obj: *JSObject, options: Value) NativeError!PlainDateRecord {
    // The calendar field (if present) must be undefined or a String;
    // the string's canonicalisation is deferred with calendar support.
    try requireCalendarFieldType(realm, try getPropertyChain(realm, obj, "calendar"));
    const day_v = try getPropertyChain(realm, obj, "day");
    const month_v = try getPropertyChain(realm, obj, "month");
    const month_code_v = try getPropertyChain(realm, obj, "monthCode");
    const year_v = try getPropertyChain(realm, obj, "year");
    if (year_v.isUndefined()) return throwTypeError(realm, "PlainDate-like is missing 'year'");
    if (day_v.isUndefined()) return throwTypeError(realm, "PlainDate-like is missing 'day'");
    const year = try dateFieldToI64(realm, try toIntegerWithTruncation(realm, year_v));
    const day = try dateFieldToI64(realm, try toIntegerWithTruncation(realm, day_v));
    var month: i64 = undefined;
    if (!month_code_v.isUndefined()) {
        month = try parseMonthCode(realm, month_code_v);
        if (!month_v.isUndefined()) {
            const m2 = try dateFieldToI64(realm, try toIntegerWithTruncation(realm, month_v));
            if (m2 != month) return throwRangeError(realm, "month and monthCode disagree");
        }
    } else if (!month_v.isUndefined()) {
        month = try dateFieldToI64(realm, try toIntegerWithTruncation(realm, month_v));
    } else {
        return throwTypeError(realm, "PlainDate-like is missing 'month' / 'monthCode'");
    }
    const overflow = try getTemporalOverflowOption(realm, options);
    return temporal.regulateISODate(year, month, day, overflow == .reject) orelse
        throwRangeError(realm, "PlainDate is out of range");
}

/// §3.5.x ToTemporalDate — a PlainDate (copy), a property bag, or an
/// ISO date string.
fn toTemporalDate(realm: *Realm, item: Value, options: Value) NativeError!PlainDateRecord {
    if (heap_mod.valueAsPlainObject(item)) |obj| {
        if (obj.getTemporalRecord()) |rec| {
            switch (rec.*) {
                .plain_date => |pd| {
                    _ = try getTemporalOverflowOption(realm, options);
                    return pd;
                },
                // §3.5.x ToTemporalDate — a PlainDateTime / ZonedDateTime
                // converts via its internal slots, never the user-facing
                // getters: the date part of the ISO date-time (the
                // ZonedDateTime first resolved to wall-clock via
                // GetISODateTimeFor). The overflow option is still read.
                .plain_date_time => |pdt| {
                    _ = try getTemporalOverflowOption(realm, options);
                    return pdt.date();
                },
                .zoned_date_time => |zdt| {
                    const iso = temporal.getISODateTimeFor(zdt.time_zone, zdt.epoch_ns);
                    _ = try getTemporalOverflowOption(realm, options);
                    return iso.date();
                },
                else => {},
            }
        }
        return toISODateFields(realm, obj, options);
    }
    if (!item.isString()) {
        return throwTypeError(realm, "Temporal.PlainDate.from expects an object or ISO 8601 string");
    }
    const s: *JSString = @ptrCast(@alignCast(item.asString()));
    const rec = temporal.parseTemporalDateString(s.flatBytes()) catch
        return throwRangeError(realm, "invalid ISO 8601 date string");
    _ = try getTemporalOverflowOption(realm, options);
    return rec;
}

fn compareISODate(a: PlainDateRecord, b: PlainDateRecord) i32 {
    if (a.iso_year != b.iso_year) return if (a.iso_year < b.iso_year) -1 else 1;
    if (a.iso_month != b.iso_month) return if (a.iso_month < b.iso_month) -1 else 1;
    if (a.iso_day != b.iso_day) return if (a.iso_day < b.iso_day) -1 else 1;
    return 0;
}

/// §3.2.2 Temporal.PlainDate.from ( item [, options] ).
fn plainDateFrom(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = this_value;
    const rec = try toTemporalDate(realm, argOr(args, 0, Value.undefined_), argOr(args, 1, Value.undefined_));
    return createTemporalDate(realm, rec);
}

/// §3.2.3 Temporal.PlainDate.compare ( one, two ).
fn plainDateCompare(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = this_value;
    const a = try toTemporalDate(realm, argOr(args, 0, Value.undefined_), Value.undefined_);
    const b = try toTemporalDate(realm, argOr(args, 1, Value.undefined_), Value.undefined_);
    return Value.fromInt32(compareISODate(a, b));
}

/// §3.3.x Temporal.PlainDate.prototype.equals ( other ).
fn plainDateEquals(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const a = try requirePlainDate(realm, this_value);
    const b = try toTemporalDate(realm, argOr(args, 0, Value.undefined_), Value.undefined_);
    return Value.fromBool(compareISODate(a, b) == 0);
}

/// §3.3.x Temporal.PlainDate.prototype.with ( temporalDateLike [, options] ).
fn plainDateWith(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const base = try requirePlainDate(realm, this_value);
    const like = argOr(args, 0, Value.undefined_);
    const obj = heap_mod.valueAsPlainObject(like) orelse
        return throwTypeError(realm, "PlainDate-like must be an object");
    try rejectTemporalLikeObject(realm, obj);

    var year: i64 = base.iso_year;
    var month: i64 = base.iso_month;
    var day: i64 = base.iso_day;
    var any = false;

    const day_v = try getPropertyChain(realm, obj, "day");
    if (!day_v.isUndefined()) {
        day = try dateFieldToI64(realm, try toIntegerWithTruncation(realm, day_v));
        any = true;
    }
    const month_v = try getPropertyChain(realm, obj, "month");
    const month_code_v = try getPropertyChain(realm, obj, "monthCode");
    if (!month_code_v.isUndefined()) {
        month = try parseMonthCode(realm, month_code_v);
        any = true;
        if (!month_v.isUndefined()) {
            const m2 = try dateFieldToI64(realm, try toIntegerWithTruncation(realm, month_v));
            if (m2 != month) return throwRangeError(realm, "month and monthCode disagree");
        }
    } else if (!month_v.isUndefined()) {
        month = try dateFieldToI64(realm, try toIntegerWithTruncation(realm, month_v));
        any = true;
    }
    const year_v = try getPropertyChain(realm, obj, "year");
    if (!year_v.isUndefined()) {
        year = try dateFieldToI64(realm, try toIntegerWithTruncation(realm, year_v));
        any = true;
    }
    if (!any) return throwTypeError(realm, "PlainDate-like must have at least one date property");

    const overflow = try getTemporalOverflowOption(realm, argOr(args, 1, Value.undefined_));
    const rec = temporal.regulateISODate(year, month, day, overflow == .reject) orelse
        return throwRangeError(realm, "PlainDate is out of range");
    return createTemporalDate(realm, rec);
}

/// §13.x GetTemporalShowCalendarNameOption — auto / always / never /
/// critical (default auto).
fn getCalendarNameOption(realm: *Realm, options: Value) NativeError!temporal.CalendarDisplay {
    const obj = (try getOptionsObject(realm, options)) orelse return .auto;
    const v = try getPropertyChain(realm, obj, "calendarName");
    if (v.isUndefined()) return .auto;
    const s = try stringifyArg(realm, v);
    const b = s.flatBytes();
    if (std.mem.eql(u8, b, "auto")) return .auto;
    if (std.mem.eql(u8, b, "always")) return .always;
    if (std.mem.eql(u8, b, "never")) return .never;
    if (std.mem.eql(u8, b, "critical")) return .critical;
    return throwRangeError(realm, "calendarName must be auto / always / never / critical");
}

/// §3.3.x Temporal.PlainDate.prototype.toString ( [options] ).
fn plainDateToString(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const rec = try requirePlainDate(realm, this_value);
    const cal = try getCalendarNameOption(realm, argOr(args, 0, Value.undefined_));
    var buf: [40]u8 = undefined;
    const s = temporal.isoDateToString(rec, &buf, cal);
    const js = realm.heap.allocateString(s) catch return error.OutOfMemory;
    return Value.fromString(js);
}
fn plainDateToJSON(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    const rec = try requirePlainDate(realm, this_value);
    var buf: [40]u8 = undefined;
    const s = temporal.isoDateToString(rec, &buf, .auto);
    const js = realm.heap.allocateString(s) catch return error.OutOfMemory;
    return Value.fromString(js);
}
fn plainDateToLocaleString(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    return plainDateToJSON(realm, this_value, args);
}
fn plainDateValueOf(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = this_value;
    _ = args;
    return throwTypeError(realm, "Called valueOf on a Temporal.PlainDate; use compare() instead");
}

// Deferred PlainDate methods — date arithmetic and conversions to types
// Cynic doesn't ship yet.
/// §3.3.x AddDurationToDate — shared by add (negate=false) and subtract
/// (negate=true). The duration's time components truncate toward zero
/// into whole days (a PlainDate has no time), then AddISODate folds in
/// years/months/weeks/days under the overflow option.
fn plainDateAddSubtract(realm: *Realm, this_value: Value, args: []const Value, negate: bool) NativeError!Value {
    const base = try requirePlainDate(realm, this_value);
    var dur = try toTemporalDuration(realm, argOr(args, 0, Value.undefined_));
    if (!temporal.isValidDuration(dur)) return throwRangeError(realm, "Duration values are out of range");
    const overflow = try getTemporalOverflowOption(realm, argOr(args, 1, Value.undefined_));
    if (negate) dur = temporal.negateDuration(dur);
    // §7.5.x ToDateDurationRecordWithoutTime — time units collapse to
    // whole days (truncated toward zero); 86_400_000_000_000 ns = 1 day.
    const time_days: i64 = @intCast(@divTrunc(temporal.timeDurationNanoseconds(dur), 86_400_000_000_000));
    const rec = temporal.addISODate(
        base,
        @intFromFloat(dur.years),
        @intFromFloat(dur.months),
        @intFromFloat(dur.weeks),
        @as(i64, @intFromFloat(dur.days)) + time_days,
        overflow == .reject,
    ) orelse return throwRangeError(realm, "PlainDate is out of range");
    return createTemporalDate(realm, rec);
}
fn plainDateAdd(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    return plainDateAddSubtract(realm, this_value, args, false);
}
fn plainDateSubtract(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    return plainDateAddSubtract(realm, this_value, args, true);
}
fn plainDateUntil(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    return differenceTemporalDate(realm, this_value, args, false);
}
fn plainDateSince(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    return differenceTemporalDate(realm, this_value, args, true);
}

/// §3.3.x DifferenceTemporalPlainDate — `until` (forward, this → other) /
/// `since` (reverse). Reads GetDifferenceSettings for the date unit group
/// (largestUnit, roundingIncrement, roundingMode, smallestUnit — in that
/// read order, every option read before any range validation), computes
/// the calendar difference via DifferenceISODate, and returns a date-only
/// Duration. Per §13 GetDifferenceSettings the result is always computed
/// in the this → other direction; `since` negates the rounding mode and
/// then the result fields, so `a.since(b)` equals `a.until(b).negated()`.
///
/// Calendar-unit rounding — a smallestUnit of year/month/week, or a day
/// increment that must bubble into a coarser largestUnit — needs
/// RoundRelativeDuration / NudgeToCalendarUnit, which is not wired yet.
/// Those option shapes throw a RangeError until that machinery lands; the
/// default (smallestUnit "day", increment 1) and pure-day increments are
/// handled here.
fn differenceTemporalDate(realm: *Realm, this_value: Value, args: []const Value, is_since: bool) NativeError!Value {
    const this_date = try requirePlainDate(realm, this_value);
    const other_date = try toTemporalDate(realm, argOr(args, 0, Value.undefined_), Value.undefined_);
    const opts = try getOptionsObject(realm, argOr(args, 1, Value.undefined_));

    // GetDifferenceSettings read order: largestUnit, increment, mode,
    // smallestUnit — read every option before any range validation.
    const largest_opt = try getTemporalUnitOption(realm, opts, "largestUnit");
    const increment = try getRoundingIncrementOption(realm, opts);
    const mode = try getRoundingModeOption(realm, opts, .trunc);
    const smallest_opt = try getTemporalUnitOption(realm, opts, "smallestUnit");

    if (largest_opt) |lu| try requireUnitInRange(realm, lu, .year, .day);
    const smallest = smallest_opt orelse temporal.LargestUnit.day;
    try requireUnitInRange(realm, smallest, .year, .day);
    // defaultLargestUnit = LargerOfTwoTemporalUnits("day", smallestUnit).
    // Within the date group "day" is the finest unit, so the coarser of
    // the two is always the smallestUnit itself.
    const largest = largest_opt orelse smallest;
    if (@intFromEnum(largest) > @intFromEnum(smallest)) {
        return throwRangeError(realm, "largestUnit must not be smaller than smallestUnit");
    }
    // Date units have no MaximumTemporalDurationRoundingIncrement, so the
    // increment is unconstrained beyond the [1, 1e9] range GetRounding-
    // IncrementOption already enforced.

    var diff = temporal.differenceISODate(this_date, other_date, largest);

    // §7.5.31 RoundRelativeDuration. For `since` the mode is negated before
    // rounding and the result negated after (§ NegateRoundingMode +
    // CreateNegatedDateDuration), so rounding `this → other` then flipping
    // matches rounding `other → this` directly.
    const eff_mode = if (is_since) negateRoundingMode(mode) else mode;
    if (smallest == .day) {
        // A "day" smallestUnit has fixed length, so it rounds by pure
        // day-count arithmetic (NudgeToDayOrTime) — no date is constructed, so
        // a large increment (e.g. 1e9) stays representable. increment 1 is a
        // no-op on the already whole-day difference.
        if (increment != 1) {
            const days_i: i128 = @intFromFloat(diff.days);
            diff.days = @floatFromInt(temporal.roundToIncrement(days_i, increment, eff_mode));
        }
    } else {
        // Calendar smallestUnits (year/month/week) round through NudgeToCalen-
        // darUnit, which re-expresses the span capped at largestUnit (folding
        // in BubbleRelativeDuration's unit promotion). A candidate end date
        // out of range yields RangeError, matching AddDate overflow.
        diff = temporal.roundRelativeDate(this_date, other_date, diff, smallest, increment, eff_mode, largest) orelse
            return throwRangeError(realm, "rounded date is outside the representable range");
    }

    if (is_since) {
        diff.years = negZero(diff.years);
        diff.months = negZero(diff.months);
        diff.weeks = negZero(diff.weeks);
        diff.days = negZero(diff.days);
    }
    return createTemporalDuration(realm, diff);
}
/// §3.3.x Temporal.PlainDate.prototype.withCalendar ( calendarLike ) — Cynic
/// ships only the ISO calendar, so any accepted identifier yields a copy of
/// the same ISO date. ToTemporalCalendarIdentifier validates the argument
/// (calendar-bearing object or ISO string ok; Instant / Duration / PlainTime
/// or non-string → TypeError; non-ISO string → RangeError).
fn plainDateWithCalendar(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const rec = try requirePlainDate(realm, this_value);
    try toTemporalCalendarIdentifier(realm, argOr(args, 0, Value.undefined_));
    return createTemporalDate(realm, rec);
}
/// §3.3.x Temporal.PlainDate.prototype.toPlainYearMonth ( ) — drop the
/// day, keeping the year-month. ISODateToFields(year-month) discards the
/// day; CalendarYearMonthFromFields for ISO fixes the reference day at 1
/// (matching the `Temporal.PlainYearMonth.from` path). The source year is
/// already within range, so the year-month is always in limits.
fn plainDateToPlainYearMonth(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    const d = try requirePlainDate(realm, this_value);
    return createTemporalYearMonth(realm, .{
        .iso_year = d.iso_year,
        .iso_month = d.iso_month,
        .ref_iso_day = 1,
    });
}
/// §3.3.x Temporal.PlainDate.prototype.toPlainMonthDay ( ) — drop the
/// year, keeping the month-day. ISODateToFields(month-day) discards the
/// year; CalendarMonthDayFromFields for ISO fixes the reference year at
/// 1972 (a leap year, so Feb 29 is representable — matching the
/// `Temporal.PlainMonthDay.from` path).
fn plainDateToPlainMonthDay(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    const d = try requirePlainDate(realm, this_value);
    return createTemporalMonthDay(realm, .{
        .ref_iso_year = 1972,
        .iso_month = d.iso_month,
        .iso_day = d.iso_day,
    });
}
/// §3.3.x Temporal.PlainDate.prototype.toPlainDateTime ( [ temporalTime ] )
/// — combine this date with a time (midnight when the argument is
/// undefined; otherwise ToTemporalTime) into a PlainDateTime.
fn plainDateToPlainDateTime(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const d = try requirePlainDate(realm, this_value);
    const arg = argOr(args, 0, Value.undefined_);
    const t: PlainTimeRecord = if (arg.isUndefined()) .{} else try toTemporalTime(realm, arg, Value.undefined_);
    return createTemporalDateTime(realm, PlainDateTimeRecord.combine(d, t));
}
/// §3.3.x Temporal.PlainDate.prototype.toZonedDateTime ( item ) — anchor
/// this date in a time zone. `item` is either a time-zone identifier
/// (string / ZonedDateTime) used at start-of-day, or a property bag
/// `{ timeZone, plainTime }`. For a fixed-offset zone start-of-day is just
/// midnight wall-clock mapped to the epoch.
fn plainDateToZonedDateTime(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const d = try requirePlainDate(realm, this_value);
    const item = argOr(args, 0, Value.undefined_);
    var tz: temporal.TimeZone = undefined;
    var time_arg = Value.undefined_;
    if (heap_mod.valueAsPlainObject(item)) |obj| {
        // A property bag carries an explicit `timeZone`; otherwise the
        // object is itself the identifier (e.g. a ZonedDateTime) used at
        // start-of-day.
        const tz_like = try getPropertyChain(realm, obj, "timeZone");
        if (tz_like.isUndefined()) {
            tz = try toTimeZoneArg(realm, item);
        } else {
            tz = try toTimeZoneArg(realm, tz_like);
            time_arg = try getPropertyChain(realm, obj, "plainTime");
        }
    } else {
        tz = try toTimeZoneArg(realm, item);
    }
    const t: PlainTimeRecord = if (time_arg.isUndefined()) .{} else try toTemporalTime(realm, time_arg, Value.undefined_);
    const wall = PlainDateTimeRecord.combine(d, t);
    if (!temporal.isoDateTimeWithinLimits(wall)) return throwRangeError(realm, "ZonedDateTime is out of range");
    const epoch = temporal.getEpochNanosecondsFor(tz, wall) orelse
        return throwRangeError(realm, "ZonedDateTime is out of range");
    return createTemporalZonedDateTime(realm, .{ .epoch_ns = epoch, .time_zone = tz });
}

// ── §5 Temporal.PlainDateTime (ISO calendar) ───────────────────────────────

fn installPlainDateTime(realm: *Realm, ns: *JSObject) !void {
    // §5.1.1 — `new`-only constructor (year, month, day, [hour, minute,
    // second, ms, µs, ns, calendar]); arity 3 (only the date is required).
    const r = try installConstructor(realm, .{
        .name = "PlainDateTime",
        .ctor = plainDateTimeConstructor,
        .arity = 3,
        .is_class = true,
        .set_home_object = true,
        .to_string_tag = "Temporal.PlainDateTime",
        .install_global = false,
    });
    const fn_obj = r.ctor;
    const proto = r.proto;

    // Date getters (delegating to the PlainDate ISO-calendar helpers).
    try installNativeGetter(realm, proto, "calendarId", plainDateTimeCalendarId);
    try installNativeGetter(realm, proto, "year", plainDateTimeYear);
    try installNativeGetter(realm, proto, "month", plainDateTimeMonth);
    try installNativeGetter(realm, proto, "monthCode", plainDateTimeMonthCode);
    try installNativeGetter(realm, proto, "day", plainDateTimeDay);
    // Time getters.
    try installNativeGetter(realm, proto, "hour", plainDateTimeHour);
    try installNativeGetter(realm, proto, "minute", plainDateTimeMinute);
    try installNativeGetter(realm, proto, "second", plainDateTimeSecond);
    try installNativeGetter(realm, proto, "millisecond", plainDateTimeMillisecond);
    try installNativeGetter(realm, proto, "microsecond", plainDateTimeMicrosecond);
    try installNativeGetter(realm, proto, "nanosecond", plainDateTimeNanosecond);
    // Derived calendar getters.
    try installNativeGetter(realm, proto, "dayOfWeek", plainDateTimeDayOfWeek);
    try installNativeGetter(realm, proto, "dayOfYear", plainDateTimeDayOfYear);
    try installNativeGetter(realm, proto, "weekOfYear", plainDateTimeWeekOfYear);
    try installNativeGetter(realm, proto, "yearOfWeek", plainDateTimeYearOfWeek);
    try installNativeGetter(realm, proto, "daysInWeek", plainDateTimeDaysInWeek);
    try installNativeGetter(realm, proto, "daysInMonth", plainDateTimeDaysInMonth);
    try installNativeGetter(realm, proto, "daysInYear", plainDateTimeDaysInYear);
    try installNativeGetter(realm, proto, "monthsInYear", plainDateTimeMonthsInYear);
    try installNativeGetter(realm, proto, "inLeapYear", plainDateTimeInLeapYear);
    try installNativeGetter(realm, proto, "era", plainDateTimeEra);
    try installNativeGetter(realm, proto, "eraYear", plainDateTimeEraYear);

    try installNativeMethodOnProto(realm, proto, "with", plainDateTimeWith, 1);
    try installNativeMethodOnProto(realm, proto, "withPlainTime", plainDateTimeWithPlainTime, 0);
    try installNativeMethodOnProto(realm, proto, "withCalendar", plainDateTimeWithCalendar, 1);
    try installNativeMethodOnProto(realm, proto, "add", plainDateTimeAdd, 1);
    try installNativeMethodOnProto(realm, proto, "subtract", plainDateTimeSubtract, 1);
    try installNativeMethodOnProto(realm, proto, "until", plainDateTimeUntil, 1);
    try installNativeMethodOnProto(realm, proto, "since", plainDateTimeSince, 1);
    try installNativeMethodOnProto(realm, proto, "round", plainDateTimeRound, 1);
    try installNativeMethodOnProto(realm, proto, "equals", plainDateTimeEquals, 1);
    try installNativeMethodOnProto(realm, proto, "toString", plainDateTimeToString, 0);
    try installNativeMethodOnProto(realm, proto, "toJSON", plainDateTimeToJSON, 0);
    try installNativeMethodOnProto(realm, proto, "toLocaleString", plainDateTimeToLocaleString, 0);
    try installNativeMethodOnProto(realm, proto, "valueOf", plainDateTimeValueOf, 0);
    try installNativeMethodOnProto(realm, proto, "toPlainDate", plainDateTimeToPlainDate, 0);
    try installNativeMethodOnProto(realm, proto, "toPlainTime", plainDateTimeToPlainTime, 0);
    try installNativeMethodOnProto(realm, proto, "toZonedDateTime", plainDateTimeToZonedDateTime, 1);

    try installNativeMethod(realm, fn_obj, "from", plainDateTimeFrom, 1);
    try installNativeMethod(realm, fn_obj, "compare", plainDateTimeCompare, 2);

    realm.intrinsics.temporal_plain_date_time_constructor = fn_obj;
    realm.intrinsics.temporal_plain_date_time_prototype = proto;
    try setNonEnumerable(ns, realm.allocator, "PlainDateTime", heap_mod.taggedFunction(fn_obj));
}

fn storePlainDateTime(realm: *Realm, inst: *JSObject, rec: PlainDateTimeRecord) NativeError!void {
    const r = realm.allocator.create(TemporalRecord) catch return error.OutOfMemory;
    r.* = .{ .plain_date_time = rec };
    inst.setTemporalRecord(realm.allocator, r) catch return error.OutOfMemory;
}

/// §5.5.x CreateTemporalDateTime — allocate a fresh PlainDateTime,
/// throwing RangeError when the composed wall-clock date-time leaves the
/// representable range (every derived-value path funnels through here).
fn createTemporalDateTime(realm: *Realm, rec: PlainDateTimeRecord) NativeError!Value {
    if (!temporal.isoDateTimeWithinLimits(rec)) {
        return throwRangeError(realm, "PlainDateTime is out of range");
    }
    const inst = realm.heap.allocateObject() catch return error.OutOfMemory;
    realm.heap.setObjectPrototype(inst, realm.intrinsics.temporal_plain_date_time_prototype.?);
    try storePlainDateTime(realm, inst, rec);
    return heap_mod.taggedObject(inst);
}

fn requirePlainDateTime(realm: *Realm, this_value: Value) NativeError!PlainDateTimeRecord {
    const obj = heap_mod.valueAsPlainObject(this_value) orelse
        return throwTypeError(realm, "not a Temporal.PlainDateTime");
    const rec = obj.getTemporalRecord() orelse
        return throwTypeError(realm, "not a Temporal.PlainDateTime");
    return switch (rec.*) {
        .plain_date_time => |pdt| pdt,
        else => throwTypeError(realm, "not a Temporal.PlainDateTime"),
    };
}

/// §5.1.1 Temporal.PlainDateTime ( isoYear, isoMonth, isoDay [, hour [,
/// minute [, second [, millisecond [, microsecond [, nanosecond [,
/// calendar ]]]]]]] ). The numeric fields coerce in positional order
/// (year..nanosecond) before the calendar identifier is read, matching
/// `order-of-operations.js`. There is no overflow option — the
/// constructor always rejects out-of-range fields.
fn plainDateTimeConstructor(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const inst = heap_mod.valueAsPlainObject(this_value) orelse
        return throwTypeError(realm, "Temporal.PlainDateTime constructor requires 'new'");
    const y = try dateFieldToI64(realm, try toIntegerWithTruncation(realm, argOr(args, 0, Value.undefined_)));
    const mo = try dateFieldToI64(realm, try toIntegerWithTruncation(realm, argOr(args, 1, Value.undefined_)));
    const d = try dateFieldToI64(realm, try toIntegerWithTruncation(realm, argOr(args, 2, Value.undefined_)));
    const hour = try toIntegerWithTruncation(realm, argDefault0(args, 3));
    const minute = try toIntegerWithTruncation(realm, argDefault0(args, 4));
    const second = try toIntegerWithTruncation(realm, argDefault0(args, 5));
    const millisecond = try toIntegerWithTruncation(realm, argDefault0(args, 6));
    const microsecond = try toIntegerWithTruncation(realm, argDefault0(args, 7));
    const nanosecond = try toIntegerWithTruncation(realm, argDefault0(args, 8));
    try requireISOCalendar(realm, argOr(args, 9, Value.undefined_));

    const date = temporal.regulateISODate(y, mo, d, true) orelse
        return throwRangeError(realm, "PlainDateTime date is out of range");
    const time = try rejectTime(realm, hour, minute, second, millisecond, microsecond, nanosecond);
    const rec = PlainDateTimeRecord.combine(date, time);
    if (!temporal.isoDateTimeWithinLimits(rec)) {
        return throwRangeError(realm, "PlainDateTime is out of range");
    }
    try storePlainDateTime(realm, inst, rec);
    return heap_mod.taggedObject(inst);
}

// Getters — date half delegates to the shared ISO-calendar helpers, time
// half reads the record field directly.
fn plainDateTimeCalendarId(realm: *Realm, t: Value, a: []const Value) NativeError!Value {
    _ = a;
    _ = try requirePlainDateTime(realm, t);
    const js = realm.heap.allocateString("iso8601") catch return error.OutOfMemory;
    return Value.fromString(js);
}
fn plainDateTimeYear(realm: *Realm, t: Value, a: []const Value) NativeError!Value {
    _ = a;
    return Value.fromInt32((try requirePlainDateTime(realm, t)).iso_year);
}
fn plainDateTimeMonth(realm: *Realm, t: Value, a: []const Value) NativeError!Value {
    _ = a;
    return Value.fromInt32(@intCast((try requirePlainDateTime(realm, t)).iso_month));
}
fn plainDateTimeDay(realm: *Realm, t: Value, a: []const Value) NativeError!Value {
    _ = a;
    return Value.fromInt32(@intCast((try requirePlainDateTime(realm, t)).iso_day));
}
fn plainDateTimeMonthCode(realm: *Realm, t: Value, a: []const Value) NativeError!Value {
    _ = a;
    const rec = try requirePlainDateTime(realm, t);
    const mc = [_]u8{ 'M', '0' + @as(u8, @intCast(rec.iso_month / 10)), '0' + @as(u8, @intCast(rec.iso_month % 10)) };
    const js = realm.heap.allocateString(&mc) catch return error.OutOfMemory;
    return Value.fromString(js);
}
fn plainDateTimeHour(realm: *Realm, t: Value, a: []const Value) NativeError!Value {
    _ = a;
    return Value.fromInt32(@intCast((try requirePlainDateTime(realm, t)).hour));
}
fn plainDateTimeMinute(realm: *Realm, t: Value, a: []const Value) NativeError!Value {
    _ = a;
    return Value.fromInt32(@intCast((try requirePlainDateTime(realm, t)).minute));
}
fn plainDateTimeSecond(realm: *Realm, t: Value, a: []const Value) NativeError!Value {
    _ = a;
    return Value.fromInt32(@intCast((try requirePlainDateTime(realm, t)).second));
}
fn plainDateTimeMillisecond(realm: *Realm, t: Value, a: []const Value) NativeError!Value {
    _ = a;
    return Value.fromInt32(@intCast((try requirePlainDateTime(realm, t)).millisecond));
}
fn plainDateTimeMicrosecond(realm: *Realm, t: Value, a: []const Value) NativeError!Value {
    _ = a;
    return Value.fromInt32(@intCast((try requirePlainDateTime(realm, t)).microsecond));
}
fn plainDateTimeNanosecond(realm: *Realm, t: Value, a: []const Value) NativeError!Value {
    _ = a;
    return Value.fromInt32(@intCast((try requirePlainDateTime(realm, t)).nanosecond));
}
fn plainDateTimeDayOfWeek(realm: *Realm, t: Value, a: []const Value) NativeError!Value {
    _ = a;
    const rec = try requirePlainDateTime(realm, t);
    return Value.fromInt32(temporal.isoDayOfWeek(rec.iso_year, rec.iso_month, rec.iso_day));
}
fn plainDateTimeDayOfYear(realm: *Realm, t: Value, a: []const Value) NativeError!Value {
    _ = a;
    const rec = try requirePlainDateTime(realm, t);
    return Value.fromInt32(temporal.isoDayOfYear(rec.iso_year, rec.iso_month, rec.iso_day));
}
fn plainDateTimeWeekOfYear(realm: *Realm, t: Value, a: []const Value) NativeError!Value {
    _ = a;
    const rec = try requirePlainDateTime(realm, t);
    return Value.fromInt32(temporal.isoWeekOfYear(rec.iso_year, rec.iso_month, rec.iso_day).week);
}
fn plainDateTimeYearOfWeek(realm: *Realm, t: Value, a: []const Value) NativeError!Value {
    _ = a;
    const rec = try requirePlainDateTime(realm, t);
    return Value.fromInt32(temporal.isoWeekOfYear(rec.iso_year, rec.iso_month, rec.iso_day).year);
}
fn plainDateTimeDaysInWeek(realm: *Realm, t: Value, a: []const Value) NativeError!Value {
    _ = a;
    _ = try requirePlainDateTime(realm, t);
    return Value.fromInt32(7);
}
fn plainDateTimeDaysInMonth(realm: *Realm, t: Value, a: []const Value) NativeError!Value {
    _ = a;
    const rec = try requirePlainDateTime(realm, t);
    return Value.fromInt32(@intCast(temporal.daysInIsoMonth(rec.iso_year, rec.iso_month)));
}
fn plainDateTimeDaysInYear(realm: *Realm, t: Value, a: []const Value) NativeError!Value {
    _ = a;
    const rec = try requirePlainDateTime(realm, t);
    return Value.fromInt32(temporal.isoDaysInYear(rec.iso_year));
}
fn plainDateTimeMonthsInYear(realm: *Realm, t: Value, a: []const Value) NativeError!Value {
    _ = a;
    _ = try requirePlainDateTime(realm, t);
    return Value.fromInt32(12);
}
fn plainDateTimeInLeapYear(realm: *Realm, t: Value, a: []const Value) NativeError!Value {
    _ = a;
    const rec = try requirePlainDateTime(realm, t);
    return Value.fromBool(temporal.isLeapYear(rec.iso_year));
}
fn plainDateTimeEra(realm: *Realm, t: Value, a: []const Value) NativeError!Value {
    _ = a;
    _ = try requirePlainDateTime(realm, t);
    return Value.undefined_; // ISO calendar has no era
}
fn plainDateTimeEraYear(realm: *Realm, t: Value, a: []const Value) NativeError!Value {
    _ = a;
    _ = try requirePlainDateTime(realm, t);
    return Value.undefined_;
}

/// The ZonedDateTime-only fields a property bag carries on top of the
/// PlainDateTime set — `offset` and the required `time-zone` — captured by
/// `toISODateTimeFields` as it walks the alphabetical read order so a
/// ZonedDateTime-like reads its fields in one pass (§6.5.x
/// PrepareCalendarFields with `« …, offset, time-zone »`).
const ZonedFieldExtras = struct {
    time_zone: temporal.TimeZone = undefined,
    behaviour: temporal.OffsetBehaviour = .wall,
    offset_ns: i128 = 0,
    /// When false an absent `timeZone` is tolerated (the bag is a
    /// relativeTo, which may be either zoned or plain); `time_zone_present`
    /// then reports which. ToTemporalZonedDateTime keeps the default `true`
    /// (a ZonedDateTime-like requires its time zone).
    time_zone_required: bool = true,
    time_zone_present: bool = false,
};

/// The raw, un-resolved field set read off a Temporal property bag in one
/// alphabetical pass (§13.x PrepareCalendarFields). `monthCode` is kept as
/// its well-formed bytes + length; its *suitability* (ISO has no leap
/// month; the numeric month is 1..12) is deferred to
/// `resolveDateTimeFields`, which runs only after every option getter has
/// fired. The year/day-required TypeErrors and the regulate / within-limits
/// checks are deferred for the same reason — order-of-operations fixtures
/// observe the option reads happening before any algorithmic validation.
const RawDateTimeFields = struct {
    year: i64 = 0,
    year_set: bool = false,
    month_int: i64 = 0,
    month_int_set: bool = false,
    month_code_buf: [8]u8 = undefined,
    month_code_len: ?usize = null,
    day: i64 = 1,
    day_set: bool = false,
    hour: f64 = 0,
    minute: f64 = 0,
    second: f64 = 0,
    millisecond: f64 = 0,
    microsecond: f64 = 0,
    nanosecond: f64 = 0,
};

/// §13.x PrepareCalendarFields — validate the calendar, then read + coerce
/// every date/time field off `obj` in alphabetical code-unit order, with no
/// required-field checks, no `monthCode` suitability, no overflow and no
/// regulate (all deferred to `resolveDateTimeFields` so the option getters
/// fire first). When `zoned` is non-null the bag is a ZonedDateTime-like:
/// `offset` (between `nanosecond` and `second`) and the required `timeZone`
/// (between `second` and `year`) are captured into it.
fn readDateTimeFieldsRaw(realm: *Realm, obj: *JSObject, zoned: ?*ZonedFieldExtras) NativeError!RawDateTimeFields {
    try requireCalendarFieldType(realm, try getPropertyChain(realm, obj, "calendar"));
    var f: RawDateTimeFields = .{};

    const day_v = try getPropertyChain(realm, obj, "day");
    if (!day_v.isUndefined()) {
        f.day = try dateFieldToI64(realm, try toIntegerWithTruncation(realm, day_v));
        f.day_set = true;
    }
    const hour_v = try getPropertyChain(realm, obj, "hour");
    if (!hour_v.isUndefined()) f.hour = try toIntegerWithTruncation(realm, hour_v);
    const microsecond_v = try getPropertyChain(realm, obj, "microsecond");
    if (!microsecond_v.isUndefined()) f.microsecond = try toIntegerWithTruncation(realm, microsecond_v);
    const millisecond_v = try getPropertyChain(realm, obj, "millisecond");
    if (!millisecond_v.isUndefined()) f.millisecond = try toIntegerWithTruncation(realm, millisecond_v);
    const minute_v = try getPropertyChain(realm, obj, "minute");
    if (!minute_v.isUndefined()) f.minute = try toIntegerWithTruncation(realm, minute_v);
    const month_v = try getPropertyChain(realm, obj, "month");
    if (!month_v.isUndefined()) {
        f.month_int = try dateFieldToI64(realm, try toIntegerWithTruncation(realm, month_v));
        f.month_int_set = true;
    }
    const month_code_v = try getPropertyChain(realm, obj, "monthCode");
    f.month_code_len = try readMonthCodeField(realm, month_code_v, &f.month_code_buf);
    const nanosecond_v = try getPropertyChain(realm, obj, "nanosecond");
    if (!nanosecond_v.isUndefined()) f.nanosecond = try toIntegerWithTruncation(realm, nanosecond_v);
    // §6.5.x — a ZonedDateTime-like reads `offset` here (after `nanosecond`,
    // before `second`). ToPrimitiveAndRequireString: an object coerces via
    // its `toString`; a non-string primitive throws. Absent ⇒ wall-clock.
    if (zoned) |z| {
        const off_v = try getPropertyChain(realm, obj, "offset");
        if (!off_v.isUndefined()) {
            const prim = try intrinsics.toPrimitive(realm, off_v, .string);
            if (!prim.isString()) return throwTypeError(realm, "offset must be a string");
            const off_s: *JSString = @ptrCast(@alignCast(prim.asString()));
            z.offset_ns = temporal.parseOffsetString(off_s.flatBytes()) orelse
                return throwRangeError(realm, "invalid offset string");
            z.behaviour = .option;
        }
    }
    const second_v = try getPropertyChain(realm, obj, "second");
    if (!second_v.isUndefined()) f.second = try toIntegerWithTruncation(realm, second_v);
    // §6.5.x — `timeZone` is read here (after `second`, before `year`). For a
    // ZonedDateTime-like it is required; for a relativeTo bag
    // (`time_zone_required == false`) it is optional — present ⇒ a zoned
    // relativeTo, absent ⇒ a plain one (`time_zone_present` reports which).
    // The calendar was validated at the top, so an invalid calendar is a
    // RangeError before an absent time zone could become a TypeError.
    if (zoned) |z| {
        const tz_v = try getPropertyChain(realm, obj, "timeZone");
        if (tz_v.isUndefined()) {
            if (z.time_zone_required) return throwTypeError(realm, "ZonedDateTime-like is missing 'timeZone'");
        } else {
            if (!tz_v.isString()) return throwTypeError(realm, "time zone must be a string");
            const tz_s: *JSString = @ptrCast(@alignCast(tz_v.asString()));
            z.time_zone = temporal.parseTimeZoneString(tz_s.flatBytes()) orelse
                return throwRangeError(realm, "invalid time zone identifier");
            z.time_zone_present = true;
        }
    }
    const year_v = try getPropertyChain(realm, obj, "year");
    if (!year_v.isUndefined()) {
        f.year = try dateFieldToI64(realm, try toIntegerWithTruncation(realm, year_v));
        f.year_set = true;
    }
    return f;
}

/// §13.x CalendarResolveFields (ISO, date type) + RegulateISODateTime — run
/// *after* every option has been read. The error order is proven by
/// from/calendarresolvefields-error-ordering.js: year-required TypeError →
/// day-required TypeError → `monthCode` suitability RangeError →
/// month/monthCode reconcile → regulate (per `overflow`) → within-limits.
fn resolveDateTimeFields(realm: *Realm, f: RawDateTimeFields, overflow: Overflow) NativeError!PlainDateTimeRecord {
    const rec = try resolveDateTimeFieldsNoRange(realm, f, overflow);
    if (!temporal.isoDateTimeWithinLimits(rec)) return throwRangeError(realm, "PlainDateTime is out of range");
    return rec;
}

/// As `resolveDateTimeFields`, but without the final RejectDateTimeRange
/// (`isoDateTimeWithinLimits`) gate — the field resolution + regulation only.
/// The relativeTo bag path uses this because InterpretTemporalDateTimeFields
/// applies no PlainDateTime-range check itself: a *plain* anchor range-checks
/// later through CreateTemporalDate (the wider noon-based PlainDate range —
/// e.g. the minimum `-271821-04-19` is a valid PlainDate but its midnight sits
/// one ISO day below the PlainDateTime floor), and a *zoned* anchor through
/// InterpretISODateTimeOffset.
fn resolveDateTimeFieldsNoRange(realm: *Realm, f: RawDateTimeFields, overflow: Overflow) NativeError!PlainDateTimeRecord {
    if (!f.year_set) return throwTypeError(realm, "PlainDateTime-like is missing 'year'");
    if (!f.day_set) return throwTypeError(realm, "PlainDateTime-like is missing 'day'");
    var month: i64 = undefined;
    if (f.month_code_len) |len| {
        month = try monthFromCodeBytes(realm, &f.month_code_buf, len);
        if (f.month_int_set and f.month_int != month) return throwRangeError(realm, "month and monthCode disagree");
    } else if (f.month_int_set) {
        month = f.month_int;
    } else {
        return throwTypeError(realm, "PlainDateTime-like is missing 'month' / 'monthCode'");
    }

    const date = temporal.regulateISODate(f.year, month, f.day, overflow == .reject) orelse
        return throwRangeError(realm, "PlainDateTime date is out of range");
    const time = try regulateTime(realm, f.hour, f.minute, f.second, f.millisecond, f.microsecond, f.nanosecond, overflow);
    return PlainDateTimeRecord.combine(date, time);
}

/// §5.5.x InterpretTemporalDateTimeFields — read a PlainDateTime-like
/// property bag (alphabetical coerce), read the `overflow` option, then
/// resolve + regulate. Absent time fields default to 0; year + day +
/// (month or monthCode) are required.
fn toISODateTimeFields(realm: *Realm, obj: *JSObject, options: Value) NativeError!PlainDateTimeRecord {
    const f = try readDateTimeFieldsRaw(realm, obj, null);
    const overflow = try getTemporalOverflowOption(realm, options);
    return resolveDateTimeFields(realm, f, overflow);
}

/// §5.5.x ToTemporalDateTime — a PlainDateTime (copy), a PlainDate
/// (combined with midnight), a property bag, or an ISO 8601 string.
fn toTemporalDateTime(realm: *Realm, item: Value, options: Value) NativeError!PlainDateTimeRecord {
    if (heap_mod.valueAsPlainObject(item)) |obj| {
        if (obj.getTemporalRecord()) |rec| {
            switch (rec.*) {
                .plain_date_time => |pdt| {
                    _ = try getTemporalOverflowOption(realm, options);
                    return pdt;
                },
                .plain_date => |pd| {
                    // A PlainDate maps to that date at midnight.
                    _ = try getTemporalOverflowOption(realm, options);
                    return PlainDateTimeRecord.combine(pd, .{});
                },
                else => {},
            }
        }
        return toISODateTimeFields(realm, obj, options);
    }
    if (!item.isString()) {
        return throwTypeError(realm, "Temporal.PlainDateTime.from expects an object or ISO 8601 string");
    }
    const s: *JSString = @ptrCast(@alignCast(item.asString()));
    const rec = temporal.parseTemporalDateTimeString(s.flatBytes()) catch
        return throwRangeError(realm, "invalid ISO 8601 date-time string");
    _ = try getTemporalOverflowOption(realm, options);
    return rec;
}

/// §5.2.2 Temporal.PlainDateTime.from ( item [, options] ).
fn plainDateTimeFrom(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = this_value;
    const rec = try toTemporalDateTime(realm, argOr(args, 0, Value.undefined_), argOr(args, 1, Value.undefined_));
    return createTemporalDateTime(realm, rec);
}

/// §5.2.3 Temporal.PlainDateTime.compare ( one, two ).
fn plainDateTimeCompare(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = this_value;
    const a = try toTemporalDateTime(realm, argOr(args, 0, Value.undefined_), Value.undefined_);
    const b = try toTemporalDateTime(realm, argOr(args, 1, Value.undefined_), Value.undefined_);
    return Value.fromInt32(temporal.compareISODateTime(a, b));
}

/// §5.3.x Temporal.PlainDateTime.prototype.equals ( other ).
fn plainDateTimeEquals(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const a = try requirePlainDateTime(realm, this_value);
    const b = try toTemporalDateTime(realm, argOr(args, 0, Value.undefined_), Value.undefined_);
    return Value.fromBool(temporal.compareISODateTime(a, b) == 0);
}

/// §5.3.x Temporal.PlainDateTime.prototype.with ( temporalDateTimeLike
/// [, options] ). Reads the full interleaved date + time field set in
/// alphabetical order, merging present fields over the receiver, then
/// regulates per `overflow`.
fn plainDateTimeWith(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const base = try requirePlainDateTime(realm, this_value);
    const like = argOr(args, 0, Value.undefined_);
    const obj = heap_mod.valueAsPlainObject(like) orelse
        return throwTypeError(realm, "PlainDateTime-like must be an object");
    // RejectObjectWithCalendarOrTimeZone — get calendar, get timeZone,
    // and reject a branded Temporal value.
    try rejectTemporalLikeObject(realm, obj);

    var year: i64 = base.iso_year;
    var month_int: i64 = base.iso_month;
    var month_int_set = false;
    var month_code_buf: [8]u8 = undefined;
    var month_code_len: ?usize = null;
    var day: i64 = base.iso_day;
    var hour: f64 = @floatFromInt(base.hour);
    var minute: f64 = @floatFromInt(base.minute);
    var second: f64 = @floatFromInt(base.second);
    var millisecond: f64 = @floatFromInt(base.millisecond);
    var microsecond: f64 = @floatFromInt(base.microsecond);
    var nanosecond: f64 = @floatFromInt(base.nanosecond);
    var any = false;

    // Alphabetical: day, hour, microsecond, millisecond, minute, month,
    // monthCode, nanosecond, second, year.
    const day_v = try getPropertyChain(realm, obj, "day");
    if (!day_v.isUndefined()) {
        day = try dateFieldToI64(realm, try toIntegerWithTruncation(realm, day_v));
        any = true;
    }
    const hour_v = try getPropertyChain(realm, obj, "hour");
    if (!hour_v.isUndefined()) {
        hour = try toIntegerWithTruncation(realm, hour_v);
        any = true;
    }
    const microsecond_v = try getPropertyChain(realm, obj, "microsecond");
    if (!microsecond_v.isUndefined()) {
        microsecond = try toIntegerWithTruncation(realm, microsecond_v);
        any = true;
    }
    const millisecond_v = try getPropertyChain(realm, obj, "millisecond");
    if (!millisecond_v.isUndefined()) {
        millisecond = try toIntegerWithTruncation(realm, millisecond_v);
        any = true;
    }
    const minute_v = try getPropertyChain(realm, obj, "minute");
    if (!minute_v.isUndefined()) {
        minute = try toIntegerWithTruncation(realm, minute_v);
        any = true;
    }
    const month_v = try getPropertyChain(realm, obj, "month");
    if (!month_v.isUndefined()) {
        month_int = try dateFieldToI64(realm, try toIntegerWithTruncation(realm, month_v));
        month_int_set = true;
        any = true;
    }
    const month_code_v = try getPropertyChain(realm, obj, "monthCode");
    month_code_len = try readMonthCodeField(realm, month_code_v, &month_code_buf);
    if (month_code_len != null) any = true;
    const nanosecond_v = try getPropertyChain(realm, obj, "nanosecond");
    if (!nanosecond_v.isUndefined()) {
        nanosecond = try toIntegerWithTruncation(realm, nanosecond_v);
        any = true;
    }
    const second_v = try getPropertyChain(realm, obj, "second");
    if (!second_v.isUndefined()) {
        second = try toIntegerWithTruncation(realm, second_v);
        any = true;
    }
    const year_v = try getPropertyChain(realm, obj, "year");
    if (!year_v.isUndefined()) {
        year = try dateFieldToI64(realm, try toIntegerWithTruncation(realm, year_v));
        any = true;
    }
    if (!any) return throwTypeError(realm, "PlainDateTime-like must have at least one recognized property");

    const overflow = try getTemporalOverflowOption(realm, argOr(args, 1, Value.undefined_));

    // §5.3.x — `monthCode` suitability is validated only after the overflow
    // option has been read (per with/options-read-before-algorithmic-
    // validation.js); regulate then runs on the resolved month.
    var month: i64 = base.iso_month;
    if (month_code_len) |len| {
        month = try monthFromCodeBytes(realm, &month_code_buf, len);
        if (month_int_set and month_int != month) return throwRangeError(realm, "month and monthCode disagree");
    } else if (month_int_set) {
        month = month_int;
    }
    const date = temporal.regulateISODate(year, month, day, overflow == .reject) orelse
        return throwRangeError(realm, "PlainDateTime date is out of range");
    const time = try regulateTime(realm, hour, minute, second, millisecond, microsecond, nanosecond, overflow);
    return createTemporalDateTime(realm, PlainDateTimeRecord.combine(date, time));
}

/// §5.3.x Temporal.PlainDateTime.prototype.withPlainTime ( [ plainTimeLike ] )
/// — replace the time half. An undefined argument means midnight;
/// otherwise ToTemporalTime.
fn plainDateTimeWithPlainTime(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const base = try requirePlainDateTime(realm, this_value);
    const arg = argOr(args, 0, Value.undefined_);
    const t: PlainTimeRecord = if (arg.isUndefined()) .{} else try toTemporalTime(realm, arg, Value.undefined_);
    return createTemporalDateTime(realm, PlainDateTimeRecord.combine(base.date(), t));
}

/// §5.3.x Temporal.PlainDateTime.prototype.withCalendar ( calendar ) —
/// Cynic ships only the ISO calendar, so any accepted identifier yields a
/// copy. A calendar-bearing Temporal object resolves to its calendar
/// (always ISO here); a non-ISO string is RangeError; a non-string,
/// non-Temporal value is TypeError.
fn plainDateTimeWithCalendar(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const rec = try requirePlainDateTime(realm, this_value);
    try toTemporalCalendarIdentifier(realm, argOr(args, 0, Value.undefined_));
    return createTemporalDateTime(realm, rec);
}

/// §5.3.x AddDurationToDateTime — `add` (negate=false) / `subtract`
/// (negate=true). AddDateTime folds the duration's time part into a
/// within-day remainder with a whole-day carry, then AddISODate applies
/// the calendar units under `overflow`.
fn plainDateTimeAddSubtract(realm: *Realm, this_value: Value, args: []const Value, negate: bool) NativeError!Value {
    const base = try requirePlainDateTime(realm, this_value);
    var dur = try toTemporalDuration(realm, argOr(args, 0, Value.undefined_));
    if (!temporal.isValidDuration(dur)) return throwRangeError(realm, "Duration values are out of range");
    const overflow = try getTemporalOverflowOption(realm, argOr(args, 1, Value.undefined_));
    if (negate) dur = temporal.negateDuration(dur);
    const rec = temporal.addDateTime(base, dur, overflow == .reject) orelse
        return throwRangeError(realm, "PlainDateTime is out of range");
    return createTemporalDateTime(realm, rec);
}
fn plainDateTimeAdd(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    return plainDateTimeAddSubtract(realm, this_value, args, false);
}
fn plainDateTimeSubtract(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    return plainDateTimeAddSubtract(realm, this_value, args, true);
}
fn plainDateTimeUntil(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    return differenceTemporalDateTime(realm, this_value, args, false);
}
fn plainDateTimeSince(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    return differenceTemporalDateTime(realm, this_value, args, true);
}

/// §5.3.x DifferenceTemporalPlainDateTime — `until` / `since`.
///
/// A difference whose largestUnit and smallestUnit are both "day" or
/// finer has no calendar component (every day is a uniform 24 h), so it
/// reduces to the same epoch-nanosecond arithmetic the Instant difference
/// uses: subtract the two wall-clock instants, round at the smallestUnit,
/// and balance into the largestUnit (which may be "day"). A year / month
/// / week unit (as largest OR smallest) routes through DifferenceISODateTime
/// + RoundRelativeDateTime, which carries the calendar context. For `since`
/// the rounding mode is negated and the result negated after, matching the
/// spec's NegateRoundingMode + negated-duration construction.
fn differenceTemporalDateTime(realm: *Realm, this_value: Value, args: []const Value, is_since: bool) NativeError!Value {
    const this_dt = try requirePlainDateTime(realm, this_value);
    const other_dt = try toTemporalDateTime(realm, argOr(args, 0, Value.undefined_), Value.undefined_);
    const opts = try getOptionsObject(realm, argOr(args, 1, Value.undefined_));

    // GetDifferenceSettings read order: largestUnit, increment, mode,
    // smallestUnit — every option read before any validation.
    const largest_opt = try getTemporalUnitOption(realm, opts, "largestUnit");
    const increment = try getRoundingIncrementOption(realm, opts);
    const mode = try getRoundingModeOption(realm, opts, .trunc);
    const smallest_opt = try getTemporalUnitOption(realm, opts, "smallestUnit");

    if (largest_opt) |lu| try requireUnitInRange(realm, lu, .year, .nanosecond);
    const smallest = smallest_opt orelse temporal.LargestUnit.nanosecond;
    try requireUnitInRange(realm, smallest, .year, .nanosecond);
    // defaultLargestUnit = LargerOfTwoTemporalUnits("day", smallestUnit):
    // the coarser (smaller enum index) of "day" and the smallestUnit.
    const default_largest: temporal.LargestUnit = @enumFromInt(@min(@intFromEnum(temporal.LargestUnit.day), @intFromEnum(smallest)));
    const largest = largest_opt orelse default_largest;
    if (@intFromEnum(largest) > @intFromEnum(smallest)) {
        return throwRangeError(realm, "largestUnit must not be smaller than smallestUnit");
    }

    // smallestUnit "day" has no maximum increment; the finer units must
    // divide their next-larger unit evenly (non-inclusive). Calendar units
    // (year/month/week) likewise carry no increment ceiling.
    if (smallest != .day and @intFromEnum(smallest) >= @intFromEnum(temporal.LargestUnit.day)) {
        if (!temporal.validateRoundingIncrement(increment, differenceDividend(smallest), false)) {
            return throwRangeError(realm, "invalid roundingIncrement for the smallestUnit");
        }
    }

    const eff_mode = if (is_since) negateRoundingMode(mode) else mode;

    // Calendar units (year/month/week as either bound) need calendar-aware
    // relative rounding: difference the two wall clocks, then round/bubble.
    if (@intFromEnum(largest) < @intFromEnum(temporal.LargestUnit.day) or
        @intFromEnum(smallest) < @intFromEnum(temporal.LargestUnit.day))
    {
        const base_diff = temporal.differenceISODateTime(this_dt, other_dt, largest);
        var dr = if (smallest == .nanosecond and increment == 1)
            base_diff
        else
            temporal.roundRelativeDateTime(this_dt, other_dt, base_diff, largest, smallest, increment, eff_mode) orelse
                return throwRangeError(realm, "rounded PlainDateTime is outside the representable range");
        if (is_since) {
            dr.years = negZero(dr.years);
            dr.months = negZero(dr.months);
            dr.weeks = negZero(dr.weeks);
            dr.days = negZero(dr.days);
            dr.hours = negZero(dr.hours);
            dr.minutes = negZero(dr.minutes);
            dr.seconds = negZero(dr.seconds);
            dr.milliseconds = negZero(dr.milliseconds);
            dr.microseconds = negZero(dr.microseconds);
            dr.nanoseconds = negZero(dr.nanoseconds);
        }
        return createTemporalDuration(realm, dr);
    }

    // Uniform span (day-or-finer both bounds): collapse each side to an
    // epoch-nanosecond count — every day is a flat 24 h.
    const ns1 = @as(i128, temporal.daysFromCivil(this_dt.iso_year, this_dt.iso_month, this_dt.iso_day)) * temporal.ns_per_day +
        temporal.timeRecordToNanoseconds(this_dt.time());
    const ns2 = @as(i128, temporal.daysFromCivil(other_dt.iso_year, other_dt.iso_month, other_dt.iso_day)) * temporal.ns_per_day +
        temporal.timeRecordToNanoseconds(other_dt.time());
    const diff = ns2 - ns1;
    const rounded = temporal.roundToIncrement(diff, increment * temporal.unitNanoseconds(smallest), eff_mode);
    var dr = temporal.balanceTimeDuration(rounded, largest);
    if (is_since) {
        dr.days = negZero(dr.days);
        dr.hours = negZero(dr.hours);
        dr.minutes = negZero(dr.minutes);
        dr.seconds = negZero(dr.seconds);
        dr.milliseconds = negZero(dr.milliseconds);
        dr.microseconds = negZero(dr.microseconds);
        dr.nanoseconds = negZero(dr.nanoseconds);
    }
    return createTemporalDuration(realm, dr);
}

/// §5.3.x Temporal.PlainDateTime.prototype.round ( roundTo ). A string
/// `roundTo` is shorthand for `{ smallestUnit }`; smallestUnit is
/// required (day..nanosecond). The increment × unit-span must divide a
/// solar day evenly (a "day" smallestUnit therefore permits only
/// increment 1); roundingMode defaults to halfExpand. Rounding the upper
/// edge up can exceed the representable range → RangeError.
fn plainDateTimeRound(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const rec = try requirePlainDateTime(realm, this_value);
    const round_to = argOr(args, 0, Value.undefined_);
    if (round_to.isUndefined()) {
        return throwTypeError(realm, "Temporal.PlainDateTime.prototype.round requires a smallestUnit");
    }
    var unit: temporal.LargestUnit = undefined;
    var increment: i128 = 1;
    var mode: temporal.RoundingMode = .half_expand;
    if (round_to.isString()) {
        const s: *JSString = @ptrCast(@alignCast(round_to.asString()));
        unit = temporal.parseTemporalUnit(s.flatBytes()) orelse
            return throwRangeError(realm, "invalid smallestUnit");
    } else {
        const opts = try getOptionsObject(realm, round_to);
        increment = try getRoundingIncrementOption(realm, opts);
        mode = try getRoundingModeOption(realm, opts, .half_expand);
        unit = (try getTemporalUnitOption(realm, opts, "smallestUnit")) orelse
            return throwRangeError(realm, "smallestUnit is required");
    }
    try requireUnitInRange(realm, unit, .day, .nanosecond);
    // §5.3.x increment validation splits by unit: "day" caps at 1
    // (maximum 1, inclusive — only increment 1 passes); every finer unit
    // uses MaximumTemporalDurationRoundingIncrement with inclusive=false,
    // so the increment must divide its next-larger unit and stay strictly
    // below it (hour < 24, minute/second < 60, sub-second < 1000).
    const increment_ok = if (unit == .day)
        temporal.validateRoundingIncrement(increment, 1, true)
    else
        temporal.validateRoundingIncrement(increment, differenceDividend(unit), false);
    if (!increment_ok) {
        return throwRangeError(realm, "roundingIncrement is out of range for the smallestUnit");
    }
    const rounded = temporal.roundISODateTime(rec, unit, increment, mode) orelse
        return throwRangeError(realm, "rounded PlainDateTime is out of range");
    return createTemporalDateTime(realm, rounded);
}

/// §5.3.x Temporal.PlainDateTime.prototype.toString ( [options] ) — read
/// calendarName, fractionalSecondDigits, roundingMode, smallestUnit (in
/// that order, before any validation), round the wall-clock date-time to
/// the resolved unit/increment, then render with the calendar annotation.
fn plainDateTimeToString(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const rec = try requirePlainDateTime(realm, this_value);
    const options = argOr(args, 0, Value.undefined_);
    const cal = try getCalendarNameOption(realm, options);
    const frac = try getFractionalSecondDigitsOption(realm, options);
    const opts_obj = try getOptionsObject(realm, options);
    const mode = try getRoundingModeOption(realm, opts_obj, .trunc);
    const smallest = try getTemporalUnitOption(realm, opts_obj, "smallestUnit");
    try requireToStringSmallestUnit(realm, smallest);

    const prec = toSecondsStringPrecision(smallest, frac);
    const rounded = temporal.roundISODateTime(rec, prec.unit, prec.increment, mode) orelse
        return throwRangeError(realm, "rounded PlainDateTime is out of range");
    if (!temporal.isoDateTimeWithinLimits(rounded)) {
        return throwRangeError(realm, "rounded PlainDateTime is out of range");
    }
    var buf: [48]u8 = undefined;
    const s = temporal.isoDateTimeToString(rounded, &buf, cal, prec.precision);
    const js = realm.heap.allocateString(s) catch return error.OutOfMemory;
    return Value.fromString(js);
}
fn plainDateTimeToJSON(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    const rec = try requirePlainDateTime(realm, this_value);
    var buf: [48]u8 = undefined;
    const s = temporal.isoDateTimeToString(rec, &buf, .auto, .auto);
    const js = realm.heap.allocateString(s) catch return error.OutOfMemory;
    return Value.fromString(js);
}
fn plainDateTimeToLocaleString(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    return plainDateTimeToJSON(realm, this_value, args);
}
fn plainDateTimeValueOf(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = this_value;
    _ = args;
    return throwTypeError(realm, "Called valueOf on a Temporal.PlainDateTime; use compare() instead");
}

/// §5.3.x Temporal.PlainDateTime.prototype.toPlainDate — the date half.
fn plainDateTimeToPlainDate(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    const rec = try requirePlainDateTime(realm, this_value);
    return createTemporalDate(realm, rec.date());
}
/// §5.3.x Temporal.PlainDateTime.prototype.toPlainTime — the time half.
fn plainDateTimeToPlainTime(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    const rec = try requirePlainDateTime(realm, this_value);
    return createTemporalTime(realm, rec.time());
}
/// §5.3.x Temporal.PlainDateTime.prototype.toZonedDateTime ( timeZone [,
/// options] ). The receiver's wall-clock date-time is interpreted in the
/// target zone (no offset is supplied, so the zone alone places the
/// instant — `disambiguation` is validated but never bites a fixed-offset
/// zone).
fn plainDateTimeToZonedDateTime(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const rec = try requirePlainDateTime(realm, this_value);
    const tz_arg = argOr(args, 0, Value.undefined_);
    if (!tz_arg.isString()) return throwTypeError(realm, "time zone must be a string");
    const tz_s: *JSString = @ptrCast(@alignCast(tz_arg.asString()));
    const tz = temporal.parseTimeZoneString(tz_s.flatBytes()) orelse
        return throwRangeError(realm, "invalid time zone identifier");
    try getDisambiguationOption(realm, argOr(args, 1, Value.undefined_));
    const epoch = temporal.getEpochNanosecondsFor(tz, rec) orelse
        return throwRangeError(realm, "ZonedDateTime is out of range");
    return createTemporalZonedDateTime(realm, .{ .epoch_ns = epoch, .time_zone = tz });
}

// ── §9 Temporal.PlainYearMonth (ISO calendar) ──────────────────────────────

const PlainYearMonthRecord = temporal.PlainYearMonthRecord;

fn installPlainYearMonth(realm: *Realm, ns: *JSObject) !void {
    // §9.1.1 — `new`-only constructor (year, month, [calendar, refISODay]).
    const r = try installConstructor(realm, .{
        .name = "PlainYearMonth",
        .ctor = plainYearMonthConstructor,
        .arity = 2,
        .is_class = true,
        .set_home_object = true,
        .to_string_tag = "Temporal.PlainYearMonth",
        .install_global = false,
    });
    const fn_obj = r.ctor;
    const proto = r.proto;

    try installNativeGetter(realm, proto, "calendarId", plainYearMonthCalendarId);
    try installNativeGetter(realm, proto, "era", plainYearMonthEra);
    try installNativeGetter(realm, proto, "eraYear", plainYearMonthEraYear);
    try installNativeGetter(realm, proto, "year", plainYearMonthYear);
    try installNativeGetter(realm, proto, "month", plainYearMonthMonth);
    try installNativeGetter(realm, proto, "monthCode", plainYearMonthMonthCode);
    try installNativeGetter(realm, proto, "daysInMonth", plainYearMonthDaysInMonth);
    try installNativeGetter(realm, proto, "daysInYear", plainYearMonthDaysInYear);
    try installNativeGetter(realm, proto, "monthsInYear", plainYearMonthMonthsInYear);
    try installNativeGetter(realm, proto, "inLeapYear", plainYearMonthInLeapYear);

    try installNativeMethodOnProto(realm, proto, "with", plainYearMonthWith, 1);
    try installNativeMethodOnProto(realm, proto, "add", plainYearMonthAdd, 1);
    try installNativeMethodOnProto(realm, proto, "subtract", plainYearMonthSubtract, 1);
    try installNativeMethodOnProto(realm, proto, "until", plainYearMonthUntil, 1);
    try installNativeMethodOnProto(realm, proto, "since", plainYearMonthSince, 1);
    try installNativeMethodOnProto(realm, proto, "equals", plainYearMonthEquals, 1);
    try installNativeMethodOnProto(realm, proto, "toString", plainYearMonthToString, 0);
    try installNativeMethodOnProto(realm, proto, "toJSON", plainYearMonthToJSON, 0);
    try installNativeMethodOnProto(realm, proto, "toLocaleString", plainYearMonthToLocaleString, 0);
    try installNativeMethodOnProto(realm, proto, "valueOf", plainYearMonthValueOf, 0);
    try installNativeMethodOnProto(realm, proto, "toPlainDate", plainYearMonthToPlainDate, 1);

    try installNativeMethod(realm, fn_obj, "from", plainYearMonthFrom, 1);
    try installNativeMethod(realm, fn_obj, "compare", plainYearMonthCompare, 2);

    realm.intrinsics.temporal_plain_year_month_constructor = fn_obj;
    realm.intrinsics.temporal_plain_year_month_prototype = proto;
    try setNonEnumerable(ns, realm.allocator, "PlainYearMonth", heap_mod.taggedFunction(fn_obj));
}

fn storePlainYearMonth(realm: *Realm, inst: *JSObject, rec: PlainYearMonthRecord) NativeError!void {
    const r = realm.allocator.create(TemporalRecord) catch return error.OutOfMemory;
    r.* = .{ .plain_year_month = rec };
    inst.setTemporalRecord(realm.allocator, r) catch return error.OutOfMemory;
}

fn createTemporalYearMonth(realm: *Realm, rec: PlainYearMonthRecord) NativeError!Value {
    const inst = realm.heap.allocateObject() catch return error.OutOfMemory;
    realm.heap.setObjectPrototype(inst, realm.intrinsics.temporal_plain_year_month_prototype.?);
    try storePlainYearMonth(realm, inst, rec);
    return heap_mod.taggedObject(inst);
}

fn requirePlainYearMonth(realm: *Realm, this_value: Value) NativeError!PlainYearMonthRecord {
    const obj = heap_mod.valueAsPlainObject(this_value) orelse
        return throwTypeError(realm, "not a Temporal.PlainYearMonth");
    const rec = obj.getTemporalRecord() orelse
        return throwTypeError(realm, "not a Temporal.PlainYearMonth");
    return switch (rec.*) {
        .plain_year_month => |pym| pym,
        else => throwTypeError(realm, "not a Temporal.PlainYearMonth"),
    };
}

/// Read a `monthCode` field per the calendar-field conversion
/// ToPrimitiveAndRequireString: ToPrimitive(string), then the result —
/// or a primitive input — must already be a String, else TypeError. A
/// bare number / bigint / boolean / Symbol / null monthCode, or an
/// object whose ToPrimitive yields a non-string, is a TypeError *before*
/// any format validation.
///
/// The code's *well-formedness* (the `MonthCode :::` grammar — `M`, two
/// ASCII digits, an optional `L` leap marker) is validated HERE, while
/// the field is read, so an ill-formed code is a RangeError before any
/// later field (e.g. `year`) is coerced — the `monthcode-invalid.js`
/// fixtures pin "syntax is validated before year type is validated".
/// The code's *suitability* for the ISO calendar (month in 1..12, no
/// leap month) is a separate RangeError deferred to `monthFromCodeBytes`
/// so it lands after the year coercion and the overflow option are read.
/// The string's bytes are copied into `buf` (truncated to its capacity);
/// any code longer than the 4-byte grammar is caught by the length check
/// before indexing. Returns the field's true byte length, or null when
/// it is absent.
fn readMonthCodeField(realm: *Realm, v: Value, buf: []u8) NativeError!?usize {
    if (v.isUndefined()) return null;
    const prim = try intrinsics.toPrimitive(realm, v, .string);
    if (!prim.isString()) return throwTypeError(realm, "monthCode must be a string");
    const s: *JSString = @ptrCast(@alignCast(prim.asString()));
    const b = s.flatBytes();
    const n = @min(b.len, buf.len);
    @memcpy(buf[0..n], b[0..n]);
    const len = b.len;
    const well_formed = (len == 3 or len == 4) and buf[0] == 'M' and
        buf[1] >= '0' and buf[1] <= '9' and buf[2] >= '0' and buf[2] <= '9' and
        (len == 3 or buf[3] == 'L');
    if (!well_formed) return throwRangeError(realm, "invalid monthCode");
    return len;
}

/// Resolve a *well-formed* `monthCode` (already syntax-checked by
/// `readMonthCodeField`) to its 1-based month, enforcing ISO-calendar
/// *suitability*: a leap-month marker (`actual_len == 4`) is never valid
/// (ISO has no leap months) and the numeric month must be 1..12. This
/// suitability RangeError is intentionally deferred — it fires only after
/// the overflow option has been read.
fn monthFromCodeBytes(realm: *Realm, buf: []const u8, actual_len: usize) NativeError!i64 {
    if (actual_len == 4) return throwRangeError(realm, "invalid monthCode"); // ISO has no leap month
    const m: i64 = @as(i64, buf[1] - '0') * 10 + @as(i64, buf[2] - '0');
    if (m < 1 or m > 12) return throwRangeError(realm, "invalid monthCode");
    return m;
}

/// §9.5.x ISOYearMonthFromFields' regulation — clamp / reject the month
/// (the reference day is fixed at 1 for the ISO calendar) and confirm
/// the year-month is representable. Distinct from `regulateISODate`,
/// which range-checks the full ISO *date* (day 1 of the minimum
/// year-month, April -271821, falls below the absolute ISO date floor of
/// April 19, so a year-month must be checked with ISOYearMonthWithinLimits).
fn regulateYearMonth(realm: *Realm, year: i64, month: i64, reject: bool) NativeError!PlainYearMonthRecord {
    var m = month;
    if (reject) {
        if (m < 1 or m > 12) return throwRangeError(realm, "month is out of range");
    } else {
        // `constrain` clamps only the upper bound; a non-positive month is a
        // RangeError even under constrain (mirrors RegulateISODate, exercised
        // by from/negative-month.js and from/overflow-constrain.js).
        if (m < 1) return throwRangeError(realm, "month is out of range");
        if (m > 12) m = 12;
    }
    if (!temporal.isoYearMonthWithinLimits(year, m)) {
        return throwRangeError(realm, "PlainYearMonth is out of range");
    }
    return .{ .iso_year = @intCast(year), .iso_month = @intCast(m), .ref_iso_day = 1 };
}

/// §9.1.1 Temporal.PlainYearMonth ( isoYear, isoMonth [, calendar, refISODay ] ).
/// The reference ISO day (4th arg, default 1) is a non-observable slot;
/// the constructor still validates it as a real day of the month
/// (IsValidISODate) and the year-month against ISOYearMonthWithinLimits.
fn plainYearMonthConstructor(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const inst = heap_mod.valueAsPlainObject(this_value) orelse
        return throwTypeError(realm, "Temporal.PlainYearMonth constructor requires 'new'");
    const y = try dateFieldToI64(realm, try toIntegerWithTruncation(realm, argOr(args, 0, Value.undefined_)));
    const m = try dateFieldToI64(realm, try toIntegerWithTruncation(realm, argOr(args, 1, Value.undefined_)));
    try requireISOCalendar(realm, argOr(args, 2, Value.undefined_));
    const ref_v = argOr(args, 3, Value.undefined_);
    const ref: i64 = if (ref_v.isUndefined()) 1 else try dateFieldToI64(realm, try toIntegerWithTruncation(realm, ref_v));
    if (!temporal.isValidISODate(y, m, ref)) return throwRangeError(realm, "invalid reference ISO date");
    if (!temporal.isoYearMonthWithinLimits(y, m)) return throwRangeError(realm, "PlainYearMonth is out of range");
    try storePlainYearMonth(realm, inst, .{ .iso_year = @intCast(y), .iso_month = @intCast(m), .ref_iso_day = @intCast(ref) });
    return heap_mod.taggedObject(inst);
}

fn plainYearMonthCalendarId(realm: *Realm, t: Value, a: []const Value) NativeError!Value {
    _ = a;
    _ = try requirePlainYearMonth(realm, t);
    const js = realm.heap.allocateString("iso8601") catch return error.OutOfMemory;
    return Value.fromString(js);
}
fn plainYearMonthYear(realm: *Realm, t: Value, a: []const Value) NativeError!Value {
    _ = a;
    return Value.fromInt32((try requirePlainYearMonth(realm, t)).iso_year);
}
fn plainYearMonthMonth(realm: *Realm, t: Value, a: []const Value) NativeError!Value {
    _ = a;
    return Value.fromInt32(@intCast((try requirePlainYearMonth(realm, t)).iso_month));
}
fn plainYearMonthMonthCode(realm: *Realm, t: Value, a: []const Value) NativeError!Value {
    _ = a;
    const rec = try requirePlainYearMonth(realm, t);
    const mc = [_]u8{ 'M', '0' + @as(u8, @intCast(rec.iso_month / 10)), '0' + @as(u8, @intCast(rec.iso_month % 10)) };
    const js = realm.heap.allocateString(&mc) catch return error.OutOfMemory;
    return Value.fromString(js);
}
fn plainYearMonthDaysInMonth(realm: *Realm, t: Value, a: []const Value) NativeError!Value {
    _ = a;
    const rec = try requirePlainYearMonth(realm, t);
    return Value.fromInt32(@intCast(temporal.daysInIsoMonth(rec.iso_year, rec.iso_month)));
}
fn plainYearMonthDaysInYear(realm: *Realm, t: Value, a: []const Value) NativeError!Value {
    _ = a;
    const rec = try requirePlainYearMonth(realm, t);
    return Value.fromInt32(temporal.isoDaysInYear(rec.iso_year));
}
fn plainYearMonthMonthsInYear(realm: *Realm, t: Value, a: []const Value) NativeError!Value {
    _ = a;
    _ = try requirePlainYearMonth(realm, t);
    return Value.fromInt32(12);
}
fn plainYearMonthInLeapYear(realm: *Realm, t: Value, a: []const Value) NativeError!Value {
    _ = a;
    const rec = try requirePlainYearMonth(realm, t);
    return Value.fromBool(temporal.isLeapYear(rec.iso_year));
}
fn plainYearMonthEra(realm: *Realm, t: Value, a: []const Value) NativeError!Value {
    _ = a;
    _ = try requirePlainYearMonth(realm, t);
    return Value.undefined_; // ISO calendar has no era
}
fn plainYearMonthEraYear(realm: *Realm, t: Value, a: []const Value) NativeError!Value {
    _ = a;
    _ = try requirePlainYearMonth(realm, t);
    return Value.undefined_;
}

/// §9.5.x ISOYearMonthFromFields — read year and month/monthCode off a
/// property bag (alphabetical order: month, monthCode, year), regulate
/// per `options`. The reference day is fixed at 1; a `day` field is not
/// in the year-month field list and is never read. The monthCode format
/// RangeError is deferred until after the overflow option is read.
fn toYearMonthFields(realm: *Realm, obj: *JSObject, options: Value) NativeError!PlainYearMonthRecord {
    try requireCalendarFieldType(realm, try getPropertyChain(realm, obj, "calendar"));

    const month_v = try getPropertyChain(realm, obj, "month");
    var month_present = false;
    var month_val: i64 = 0;
    if (!month_v.isUndefined()) {
        month_val = try readPositiveDateField(realm, month_v);
        month_present = true;
    }

    var mc_buf: [8]u8 = undefined;
    const mc_len = try readMonthCodeField(realm, try getPropertyChain(realm, obj, "monthCode"), &mc_buf);

    const year_v = try getPropertyChain(realm, obj, "year");
    if (year_v.isUndefined()) return throwTypeError(realm, "PlainYearMonth-like is missing 'year'");
    const year = try dateFieldToI64(realm, try toIntegerWithTruncation(realm, year_v));

    const overflow = try getTemporalOverflowOption(realm, options);

    var month: i64 = undefined;
    if (mc_len) |len| {
        month = try monthFromCodeBytes(realm, &mc_buf, len);
        if (month_present and month_val != month) return throwRangeError(realm, "month and monthCode disagree");
    } else if (month_present) {
        month = month_val;
    } else {
        return throwTypeError(realm, "PlainYearMonth-like is missing 'month' / 'monthCode'");
    }
    return regulateYearMonth(realm, year, month, overflow == .reject);
}

/// §9.5.x ToTemporalYearMonth — a PlainYearMonth (copy), a property bag,
/// or an ISO year-month string. For the object and string paths the
/// reference day is reset to 1 (CalendarYearMonthFromFields), so only the
/// constructor's explicit 4th argument yields a non-1 reference day.
fn toTemporalYearMonth(realm: *Realm, item: Value, options: Value) NativeError!PlainYearMonthRecord {
    if (heap_mod.valueAsPlainObject(item)) |obj| {
        if (obj.getTemporalRecord()) |rec| {
            switch (rec.*) {
                .plain_year_month => |pym| {
                    _ = try getTemporalOverflowOption(realm, options);
                    return pym;
                },
                else => {},
            }
        }
        return toYearMonthFields(realm, obj, options);
    }
    if (!item.isString()) {
        return throwTypeError(realm, "Temporal.PlainYearMonth.from expects an object or ISO 8601 string");
    }
    const s: *JSString = @ptrCast(@alignCast(item.asString()));
    const parsed = temporal.parseTemporalYearMonthString(s.flatBytes()) catch
        return throwRangeError(realm, "invalid ISO 8601 year-month string");
    _ = try getTemporalOverflowOption(realm, options);
    return .{ .iso_year = parsed.iso_year, .iso_month = parsed.iso_month, .ref_iso_day = 1 };
}

/// §9.2.2 Temporal.PlainYearMonth.from ( item [, options] ).
fn plainYearMonthFrom(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = this_value;
    const rec = try toTemporalYearMonth(realm, argOr(args, 0, Value.undefined_), argOr(args, 1, Value.undefined_));
    return createTemporalYearMonth(realm, rec);
}

/// §9.2.3 Temporal.PlainYearMonth.compare ( one, two ). Compares the full
/// backing ISODate (reference day included), per CompareISODate.
fn plainYearMonthCompare(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = this_value;
    const a = try toTemporalYearMonth(realm, argOr(args, 0, Value.undefined_), Value.undefined_);
    const b = try toTemporalYearMonth(realm, argOr(args, 1, Value.undefined_), Value.undefined_);
    return Value.fromInt32(compareISODate(a.date(), b.date()));
}

/// §9.3.x Temporal.PlainYearMonth.prototype.equals ( other ). Takes the
/// reference day into account (CompareISODate over the full ISODate).
fn plainYearMonthEquals(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const a = try requirePlainYearMonth(realm, this_value);
    const b = try toTemporalYearMonth(realm, argOr(args, 0, Value.undefined_), Value.undefined_);
    return Value.fromBool(compareISODate(a.date(), b.date()) == 0);
}

/// §9.3.x Temporal.PlainYearMonth.prototype.with ( temporalYearMonthLike
/// [, options] ). Merges the receiver's {year, month} with the partial's
/// year / month / monthCode (alphabetical read order), rejecting an
/// argument that carries a calendar / timeZone field or is itself a
/// branded Temporal value. The reference day is reset to 1.
fn plainYearMonthWith(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const base = try requirePlainYearMonth(realm, this_value);
    const like = argOr(args, 0, Value.undefined_);
    const obj = heap_mod.valueAsPlainObject(like) orelse
        return throwTypeError(realm, "PlainYearMonth-like must be an object");
    try rejectTemporalLikeObject(realm, obj);

    var year: i64 = base.iso_year;
    var any = false;

    const month_v = try getPropertyChain(realm, obj, "month");
    var month_present = false;
    var month_val: i64 = 0;
    if (!month_v.isUndefined()) {
        month_val = try readPositiveDateField(realm, month_v);
        month_present = true;
        any = true;
    }

    var mc_buf: [8]u8 = undefined;
    const mc_len = try readMonthCodeField(realm, try getPropertyChain(realm, obj, "monthCode"), &mc_buf);
    if (mc_len != null) any = true;

    const year_v = try getPropertyChain(realm, obj, "year");
    if (!year_v.isUndefined()) {
        year = try dateFieldToI64(realm, try toIntegerWithTruncation(realm, year_v));
        any = true;
    }
    if (!any) return throwTypeError(realm, "PlainYearMonth-like must have at least one recognized property");

    const overflow = try getTemporalOverflowOption(realm, argOr(args, 1, Value.undefined_));

    var month: i64 = base.iso_month;
    if (mc_len) |len| {
        month = try monthFromCodeBytes(realm, &mc_buf, len);
        if (month_present and month_val != month) return throwRangeError(realm, "month and monthCode disagree");
    } else if (month_present) {
        month = month_val;
    }
    return createTemporalYearMonth(realm, try regulateYearMonth(realm, year, month, overflow == .reject));
}

/// §9.5.x AddDurationToYearMonth — shared by add (negate=false) and
/// subtract (negate=true). A year-month carries only years and months:
/// per the current spec a nonzero weeks / days / time component is a
/// RangeError. The source year-month is anchored at day 1, which must
/// itself be a representable ISO date — so the minimum year-month
/// (April -271821, whose day 1 falls below the April-19 ISO floor)
/// throws even for a zero duration.
fn plainYearMonthAddSubtract(realm: *Realm, this_value: Value, args: []const Value, negate: bool) NativeError!Value {
    const base = try requirePlainYearMonth(realm, this_value);
    var dur = try toTemporalDuration(realm, argOr(args, 0, Value.undefined_));
    if (!temporal.isValidDuration(dur)) return throwRangeError(realm, "Duration values are out of range");
    const overflow = try getTemporalOverflowOption(realm, argOr(args, 1, Value.undefined_));
    if (negate) dur = temporal.negateDuration(dur);
    // §9.5.x AddDurationToYearMonth step 7 — reject any unit finer than a
    // month.
    if (dur.weeks != 0 or dur.days != 0 or temporal.timeDurationNanoseconds(dur) != 0) {
        return throwRangeError(realm, "PlainYearMonth arithmetic does not support weeks, days, or time units");
    }
    // step 9 — the day-1 anchor must be a representable ISO date.
    if (!temporal.isoDateWithinLimits(base.iso_year, base.iso_month, 1)) {
        return throwRangeError(realm, "PlainYearMonth is out of range");
    }
    // step 12 — CalendarDateAdd adds only the years + months (day stays 1,
    // so no overflow clamping is observable); BalanceISOYearMonth carries
    // the month into the year.
    const bal = temporal.balanceISOYearMonth(
        @as(i64, base.iso_year) + @as(i64, @intFromFloat(dur.years)),
        @as(i64, base.iso_month) + @as(i64, @intFromFloat(dur.months)),
    );
    return createTemporalYearMonth(realm, try regulateYearMonth(realm, bal.year, bal.month, overflow == .reject));
}
fn plainYearMonthAdd(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    return plainYearMonthAddSubtract(realm, this_value, args, false);
}
fn plainYearMonthSubtract(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    return plainYearMonthAddSubtract(realm, this_value, args, true);
}
fn plainYearMonthUntil(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    return differenceTemporalYearMonth(realm, this_value, args, false);
}
fn plainYearMonthSince(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    return differenceTemporalYearMonth(realm, this_value, args, true);
}

/// §9.5.x DifferenceTemporalPlainYearMonth — `until` / `since`. Difference
/// settings allow only year / month units (week, day, and finer are
/// disallowed; default smallestUnit = month, default largestUnit = year).
/// Both year-months are anchored at day 1 and the calendar difference is
/// taken with weeks + days forced to zero. Equal year-months short-circuit
/// to a zero Duration *before* the day-1 range check, so the minimum
/// year-month differenced against itself returns zero rather than throwing.
fn differenceTemporalYearMonth(realm: *Realm, this_value: Value, args: []const Value, is_since: bool) NativeError!Value {
    const this_ym = try requirePlainYearMonth(realm, this_value);
    const other_ym = try toTemporalYearMonth(realm, argOr(args, 0, Value.undefined_), Value.undefined_);
    const opts = try getOptionsObject(realm, argOr(args, 1, Value.undefined_));

    const largest_opt = try getTemporalUnitOption(realm, opts, "largestUnit");
    const increment = try getRoundingIncrementOption(realm, opts);
    const mode = try getRoundingModeOption(realm, opts, .trunc);
    const smallest_opt = try getTemporalUnitOption(realm, opts, "smallestUnit");

    if (largest_opt) |lu| try requireUnitInRange(realm, lu, .year, .month);
    const smallest = smallest_opt orelse temporal.LargestUnit.month;
    try requireUnitInRange(realm, smallest, .year, .month);
    // §9.5.x GetDifferenceSettings(…, smallestLargestDefaultUnit = "year").
    // defaultLargestUnit = LargerOfTwoTemporalUnits("year", smallestUnit),
    // and "year" is the coarsest unit, so the default largest is always
    // "year" regardless of smallestUnit.
    const largest = largest_opt orelse temporal.LargestUnit.year;
    if (@intFromEnum(largest) > @intFromEnum(smallest)) {
        return throwRangeError(realm, "largestUnit must not be smaller than smallestUnit");
    }

    // Equal ISODates → zero Duration, before the day-1 anchor range check.
    if (compareISODate(this_ym.date(), other_ym.date()) == 0) {
        return createTemporalDuration(realm, .{});
    }

    const this_anchor = PlainDateRecord{ .iso_year = this_ym.iso_year, .iso_month = this_ym.iso_month, .iso_day = 1 };
    const other_anchor = PlainDateRecord{ .iso_year = other_ym.iso_year, .iso_month = other_ym.iso_month, .iso_day = 1 };
    if (!temporal.isoDateWithinLimits(this_anchor.iso_year, this_anchor.iso_month, 1) or
        !temporal.isoDateWithinLimits(other_anchor.iso_year, other_anchor.iso_month, 1))
    {
        return throwRangeError(realm, "PlainYearMonth is out of range");
    }

    var diff = temporal.differenceISODate(this_anchor, other_anchor, largest);
    // AdjustDateDurationRecord(_, 0, 0) — a year-month difference has no
    // weeks or days.
    diff.weeks = 0;
    diff.days = 0;

    const eff_mode = if (is_since) negateRoundingMode(mode) else mode;
    if (smallest != .month or increment != 1) {
        diff = temporal.roundRelativeDate(this_anchor, other_anchor, diff, smallest, increment, eff_mode, largest) orelse
            return throwRangeError(realm, "rounded date is outside the representable range");
    }

    if (is_since) {
        diff.years = negZero(diff.years);
        diff.months = negZero(diff.months);
        diff.weeks = negZero(diff.weeks);
        diff.days = negZero(diff.days);
    }
    return createTemporalDuration(realm, diff);
}

/// §9.3.x Temporal.PlainYearMonth.prototype.toString ( [options] ).
fn plainYearMonthToString(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const rec = try requirePlainYearMonth(realm, this_value);
    const cal = try getCalendarNameOption(realm, argOr(args, 0, Value.undefined_));
    var buf: [40]u8 = undefined;
    const s = temporal.isoYearMonthToString(rec, &buf, cal);
    const js = realm.heap.allocateString(s) catch return error.OutOfMemory;
    return Value.fromString(js);
}
fn plainYearMonthToJSON(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    const rec = try requirePlainYearMonth(realm, this_value);
    var buf: [40]u8 = undefined;
    const s = temporal.isoYearMonthToString(rec, &buf, .auto);
    const js = realm.heap.allocateString(s) catch return error.OutOfMemory;
    return Value.fromString(js);
}
fn plainYearMonthToLocaleString(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    return plainYearMonthToJSON(realm, this_value, args);
}
fn plainYearMonthValueOf(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = this_value;
    _ = args;
    return throwTypeError(realm, "Called valueOf on a Temporal.PlainYearMonth; use compare() instead");
}

/// §9.3.x Temporal.PlainYearMonth.prototype.toPlainDate ( item ). Combines
/// the receiver's year+month with a `day` read off `item` (required),
/// resolving under constrain; the resulting PlainDate is range-checked.
fn plainYearMonthToPlainDate(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const ym = try requirePlainYearMonth(realm, this_value);
    const obj = heap_mod.valueAsPlainObject(argOr(args, 0, Value.undefined_)) orelse
        return throwTypeError(realm, "Temporal.PlainYearMonth.prototype.toPlainDate expects an object");
    const day_v = try getPropertyChain(realm, obj, "day");
    if (day_v.isUndefined()) return throwTypeError(realm, "argument is missing 'day'");
    const day = try readPositiveDateField(realm, day_v);
    const rec = temporal.regulateISODate(ym.iso_year, ym.iso_month, day, false) orelse
        return throwRangeError(realm, "PlainDate is out of range");
    return createTemporalDate(realm, rec);
}

// ── §10 Temporal.PlainMonthDay ─────────────────────────────────────────────

const PlainMonthDayRecord = temporal.PlainMonthDayRecord;

fn installPlainMonthDay(realm: *Realm, ns: *JSObject) !void {
    // §10.1.1 — `new`-only constructor (month, day, [calendar, refISOYear]).
    const r = try installConstructor(realm, .{
        .name = "PlainMonthDay",
        .ctor = plainMonthDayConstructor,
        .arity = 2,
        .is_class = true,
        .set_home_object = true,
        .to_string_tag = "Temporal.PlainMonthDay",
        .install_global = false,
    });
    const fn_obj = r.ctor;
    const proto = r.proto;

    // A PlainMonthDay exposes only calendarId, monthCode, and day — its
    // year is a non-observable reference (1972), so there is no `year` or
    // `month` getter, no arithmetic (add / subtract / until / since), and
    // no static `compare`.
    try installNativeGetter(realm, proto, "calendarId", plainMonthDayCalendarId);
    try installNativeGetter(realm, proto, "monthCode", plainMonthDayMonthCode);
    try installNativeGetter(realm, proto, "day", plainMonthDayDay);

    try installNativeMethodOnProto(realm, proto, "with", plainMonthDayWith, 1);
    try installNativeMethodOnProto(realm, proto, "equals", plainMonthDayEquals, 1);
    try installNativeMethodOnProto(realm, proto, "toString", plainMonthDayToString, 0);
    try installNativeMethodOnProto(realm, proto, "toJSON", plainMonthDayToJSON, 0);
    try installNativeMethodOnProto(realm, proto, "toLocaleString", plainMonthDayToLocaleString, 0);
    try installNativeMethodOnProto(realm, proto, "valueOf", plainMonthDayValueOf, 0);
    try installNativeMethodOnProto(realm, proto, "toPlainDate", plainMonthDayToPlainDate, 1);

    try installNativeMethod(realm, fn_obj, "from", plainMonthDayFrom, 1);

    realm.intrinsics.temporal_plain_month_day_constructor = fn_obj;
    realm.intrinsics.temporal_plain_month_day_prototype = proto;
    try setNonEnumerable(ns, realm.allocator, "PlainMonthDay", heap_mod.taggedFunction(fn_obj));
}

fn storePlainMonthDay(realm: *Realm, inst: *JSObject, rec: PlainMonthDayRecord) NativeError!void {
    const r = realm.allocator.create(TemporalRecord) catch return error.OutOfMemory;
    r.* = .{ .plain_month_day = rec };
    inst.setTemporalRecord(realm.allocator, r) catch return error.OutOfMemory;
}

fn createTemporalMonthDay(realm: *Realm, rec: PlainMonthDayRecord) NativeError!Value {
    const inst = realm.heap.allocateObject() catch return error.OutOfMemory;
    realm.heap.setObjectPrototype(inst, realm.intrinsics.temporal_plain_month_day_prototype.?);
    try storePlainMonthDay(realm, inst, rec);
    return heap_mod.taggedObject(inst);
}

fn requirePlainMonthDay(realm: *Realm, this_value: Value) NativeError!PlainMonthDayRecord {
    const obj = heap_mod.valueAsPlainObject(this_value) orelse
        return throwTypeError(realm, "not a Temporal.PlainMonthDay");
    const rec = obj.getTemporalRecord() orelse
        return throwTypeError(realm, "not a Temporal.PlainMonthDay");
    return switch (rec.*) {
        .plain_month_day => |pmd| pmd,
        else => throwTypeError(realm, "not a Temporal.PlainMonthDay"),
    };
}

/// §10.5.x ISOMonthDayFromFields' regulation. The `year_for_overflow`
/// argument is the input `year` field when present, else the ISO leap
/// reference 1972; it is used ONLY to size February for the overflow
/// option and is NOT range-checked (so a wildly out-of-range input year
/// is accepted, per `from/iso-year-used-only-for-overflow.js`). A
/// non-positive month or day is a RangeError even under constrain; under
/// constrain an over-large month clamps to 12 and an over-large day to
/// the month's length. The stored reference year is always 1972, which is
/// trivially within the ISO date limits — so no further range check is
/// needed on the result.
fn regulateMonthDay(realm: *Realm, year_for_overflow: i64, month: i64, day: i64, reject: bool) NativeError!PlainMonthDayRecord {
    var m = month;
    var d = day;
    if (reject) {
        if (m < 1 or m > 12) return throwRangeError(realm, "month is out of range");
        if (d < 1 or d > daysInIsoMonthI64(year_for_overflow, m)) return throwRangeError(realm, "day is out of range");
    } else {
        if (m < 1 or d < 1) return throwRangeError(realm, "month and day must be positive");
        if (m > 12) m = 12;
        const max_day = daysInIsoMonthI64(year_for_overflow, m);
        if (d > max_day) d = max_day;
    }
    return .{ .ref_iso_year = 1972, .iso_month = @intCast(m), .iso_day = @intCast(d) };
}

fn daysInIsoMonthI64(year: i64, month: i64) i64 {
    return @intCast(temporal.daysInIsoMonth(year, @intCast(month)));
}

/// §10.1.1 Temporal.PlainMonthDay ( isoMonth, isoDay [, calendar, refISOYear ] ).
/// The reference ISO year (4th arg, default 1972) IS a real, range-checked
/// year here: the constructor validates the full ISO date (refYear, month,
/// day) with IsValidISODate and ISODateWithinLimits — unlike the from /
/// with / string paths, where the year is only an overflow hint.
fn plainMonthDayConstructor(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const inst = heap_mod.valueAsPlainObject(this_value) orelse
        return throwTypeError(realm, "Temporal.PlainMonthDay constructor requires 'new'");
    const m = try dateFieldToI64(realm, try toIntegerWithTruncation(realm, argOr(args, 0, Value.undefined_)));
    const d = try dateFieldToI64(realm, try toIntegerWithTruncation(realm, argOr(args, 1, Value.undefined_)));
    try requireISOCalendar(realm, argOr(args, 2, Value.undefined_));
    const ref_v = argOr(args, 3, Value.undefined_);
    const ref: i64 = if (ref_v.isUndefined()) 1972 else try dateFieldToI64(realm, try toIntegerWithTruncation(realm, ref_v));
    if (!temporal.isValidISODate(ref, m, d)) return throwRangeError(realm, "invalid month-day");
    if (!temporal.isoDateWithinLimits(ref, @intCast(m), @intCast(d))) return throwRangeError(realm, "PlainMonthDay is out of range");
    try storePlainMonthDay(realm, inst, .{ .ref_iso_year = @intCast(ref), .iso_month = @intCast(m), .iso_day = @intCast(d) });
    return heap_mod.taggedObject(inst);
}

fn plainMonthDayCalendarId(realm: *Realm, t: Value, a: []const Value) NativeError!Value {
    _ = a;
    _ = try requirePlainMonthDay(realm, t);
    const js = realm.heap.allocateString("iso8601") catch return error.OutOfMemory;
    return Value.fromString(js);
}
fn plainMonthDayMonthCode(realm: *Realm, t: Value, a: []const Value) NativeError!Value {
    _ = a;
    const rec = try requirePlainMonthDay(realm, t);
    const mc = [_]u8{ 'M', '0' + @as(u8, @intCast(rec.iso_month / 10)), '0' + @as(u8, @intCast(rec.iso_month % 10)) };
    const js = realm.heap.allocateString(&mc) catch return error.OutOfMemory;
    return Value.fromString(js);
}
fn plainMonthDayDay(realm: *Realm, t: Value, a: []const Value) NativeError!Value {
    _ = a;
    return Value.fromInt32(@intCast((try requirePlainMonthDay(realm, t)).iso_day));
}

/// §10.5.x ISOMonthDayFromFields — read day, month / monthCode, and an
/// optional year off a property bag (alphabetical read order: day, month,
/// monthCode, year), regulate per `options`. `day` is required (TypeError
/// if absent); at least one of month / monthCode is required (TypeError if
/// both absent). The year, when present, only sizes February for the
/// overflow option; the stored reference year is always 1972. The
/// monthCode *suitability* RangeError is deferred until after the overflow
/// option is read.
fn toMonthDayFields(realm: *Realm, obj: *JSObject, options: Value) NativeError!PlainMonthDayRecord {
    try requireCalendarFieldType(realm, try getPropertyChain(realm, obj, "calendar"));

    const day_v = try getPropertyChain(realm, obj, "day");
    if (day_v.isUndefined()) return throwTypeError(realm, "PlainMonthDay-like is missing 'day'");
    const day = try readPositiveDateField(realm, day_v);

    const month_v = try getPropertyChain(realm, obj, "month");
    var month_present = false;
    var month_val: i64 = 0;
    if (!month_v.isUndefined()) {
        month_val = try readPositiveDateField(realm, month_v);
        month_present = true;
    }

    var mc_buf: [8]u8 = undefined;
    const mc_len = try readMonthCodeField(realm, try getPropertyChain(realm, obj, "monthCode"), &mc_buf);

    const year_v = try getPropertyChain(realm, obj, "year");
    const year_for_overflow: i64 = if (year_v.isUndefined())
        1972
    else
        try dateFieldToI64(realm, try toIntegerWithTruncation(realm, year_v));

    const overflow = try getTemporalOverflowOption(realm, options);

    var month: i64 = undefined;
    if (mc_len) |len| {
        month = try monthFromCodeBytes(realm, &mc_buf, len);
        if (month_present and month_val != month) return throwRangeError(realm, "month and monthCode disagree");
    } else if (month_present) {
        month = month_val;
    } else {
        return throwTypeError(realm, "PlainMonthDay-like is missing 'month' / 'monthCode'");
    }
    return regulateMonthDay(realm, year_for_overflow, month, day, overflow == .reject);
}

/// §10.5.x ToTemporalMonthDay — a PlainMonthDay (copy, preserving its
/// reference year), a property bag, or an ISO month-day string. For the
/// string path the reference year is the ISO leap reference 1972.
fn toTemporalMonthDay(realm: *Realm, item: Value, options: Value) NativeError!PlainMonthDayRecord {
    if (heap_mod.valueAsPlainObject(item)) |obj| {
        if (obj.getTemporalRecord()) |rec| {
            switch (rec.*) {
                .plain_month_day => |pmd| {
                    _ = try getTemporalOverflowOption(realm, options);
                    return pmd;
                },
                else => {},
            }
        }
        return toMonthDayFields(realm, obj, options);
    }
    if (!item.isString()) {
        return throwTypeError(realm, "Temporal.PlainMonthDay.from expects an object or ISO 8601 string");
    }
    const s: *JSString = @ptrCast(@alignCast(item.asString()));
    const parsed = temporal.parseTemporalMonthDayString(s.flatBytes()) catch
        return throwRangeError(realm, "invalid ISO 8601 month-day string");
    _ = try getTemporalOverflowOption(realm, options);
    return parsed;
}

/// §10.2.2 Temporal.PlainMonthDay.from ( item [, options] ).
fn plainMonthDayFrom(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = this_value;
    const rec = try toTemporalMonthDay(realm, argOr(args, 0, Value.undefined_), argOr(args, 1, Value.undefined_));
    return createTemporalMonthDay(realm, rec);
}

/// §10.3.x Temporal.PlainMonthDay.prototype.equals ( other ). Compares the
/// full backing ISODate (reference year included), so two month-days with
/// the same month / day but different reference years are NOT equal.
fn plainMonthDayEquals(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const a = try requirePlainMonthDay(realm, this_value);
    const b = try toTemporalMonthDay(realm, argOr(args, 0, Value.undefined_), Value.undefined_);
    return Value.fromBool(compareISODate(a.date(), b.date()) == 0);
}

/// §10.3.x Temporal.PlainMonthDay.prototype.with ( temporalMonthDayLike
/// [, options] ). Merges the receiver's month / day with the partial's
/// day / month / monthCode / year (alphabetical read order), rejecting an
/// argument that carries a calendar / timeZone field or is itself a
/// branded Temporal value. The receiver contributes no year, so an absent
/// partial year falls back to the ISO reference 1972 for overflow sizing.
fn plainMonthDayWith(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const base = try requirePlainMonthDay(realm, this_value);
    const like = argOr(args, 0, Value.undefined_);
    const obj = heap_mod.valueAsPlainObject(like) orelse
        return throwTypeError(realm, "PlainMonthDay-like must be an object");
    try rejectTemporalLikeObject(realm, obj);

    var any = false;

    const day_v = try getPropertyChain(realm, obj, "day");
    var day_present = false;
    var day_val: i64 = 0;
    if (!day_v.isUndefined()) {
        day_val = try readPositiveDateField(realm, day_v);
        day_present = true;
        any = true;
    }

    const month_v = try getPropertyChain(realm, obj, "month");
    var month_present = false;
    var month_val: i64 = 0;
    if (!month_v.isUndefined()) {
        month_val = try readPositiveDateField(realm, month_v);
        month_present = true;
        any = true;
    }

    var mc_buf: [8]u8 = undefined;
    const mc_len = try readMonthCodeField(realm, try getPropertyChain(realm, obj, "monthCode"), &mc_buf);
    if (mc_len != null) any = true;

    const year_v = try getPropertyChain(realm, obj, "year");
    var year_for_overflow: i64 = 1972;
    if (!year_v.isUndefined()) {
        year_for_overflow = try dateFieldToI64(realm, try toIntegerWithTruncation(realm, year_v));
        any = true;
    }
    if (!any) return throwTypeError(realm, "PlainMonthDay-like must have at least one recognized property");

    const overflow = try getTemporalOverflowOption(realm, argOr(args, 1, Value.undefined_));

    var month: i64 = base.iso_month;
    if (mc_len) |len| {
        month = try monthFromCodeBytes(realm, &mc_buf, len);
        if (month_present and month_val != month) return throwRangeError(realm, "month and monthCode disagree");
    } else if (month_present) {
        month = month_val;
    }
    const day: i64 = if (day_present) day_val else base.iso_day;
    return createTemporalMonthDay(realm, try regulateMonthDay(realm, year_for_overflow, month, day, overflow == .reject));
}

/// §10.3.x Temporal.PlainMonthDay.prototype.toString ( [options] ).
fn plainMonthDayToString(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const rec = try requirePlainMonthDay(realm, this_value);
    const cal = try getCalendarNameOption(realm, argOr(args, 0, Value.undefined_));
    var buf: [40]u8 = undefined;
    const s = temporal.isoMonthDayToString(rec, &buf, cal);
    const js = realm.heap.allocateString(s) catch return error.OutOfMemory;
    return Value.fromString(js);
}
fn plainMonthDayToJSON(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    const rec = try requirePlainMonthDay(realm, this_value);
    var buf: [40]u8 = undefined;
    const s = temporal.isoMonthDayToString(rec, &buf, .auto);
    const js = realm.heap.allocateString(s) catch return error.OutOfMemory;
    return Value.fromString(js);
}
fn plainMonthDayToLocaleString(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    return plainMonthDayToJSON(realm, this_value, args);
}
fn plainMonthDayValueOf(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = this_value;
    _ = args;
    return throwTypeError(realm, "Called valueOf on a Temporal.PlainMonthDay; use equals() instead");
}

/// §10.3.x Temporal.PlainMonthDay.prototype.toPlainDate ( item ). Combines
/// the receiver's month + day with a `year` read off `item` (the only
/// field read; required). The result is always resolved under constrain —
/// no overflow option is consulted — so e.g. Feb 29 + a common year folds
/// to Feb 28.
fn plainMonthDayToPlainDate(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const md = try requirePlainMonthDay(realm, this_value);
    const obj = heap_mod.valueAsPlainObject(argOr(args, 0, Value.undefined_)) orelse
        return throwTypeError(realm, "Temporal.PlainMonthDay.prototype.toPlainDate expects an object");
    const year_v = try getPropertyChain(realm, obj, "year");
    if (year_v.isUndefined()) return throwTypeError(realm, "argument is missing 'year'");
    const year = try dateFieldToI64(realm, try toIntegerWithTruncation(realm, year_v));
    const rec = temporal.regulateISODate(year, md.iso_month, md.iso_day, false) orelse
        return throwRangeError(realm, "PlainDate is out of range");
    return createTemporalDate(realm, rec);
}

// ── §6 Temporal.ZonedDateTime ───────────────────────────────────────────────
// An exact instant ([[EpochNanoseconds]]) viewed through a [[TimeZone]]
// (offset-only scope) and the ISO [[Calendar]]. Date/time field getters
// derive a local wall-clock PlainDateTimeRecord via the §6 core AO
// `getISODateTimeFor`, then reuse the same ISO-calendar field helpers the
// other plain types use. Conversions, formatting, and arithmetic land in
// follow-up commits.

const ZonedDateTimeRecord = temporal.ZonedDateTimeRecord;

fn installZonedDateTime(realm: *Realm, ns: *JSObject) !void {
    // §6.1.1 — `new`-only constructor; length 2 (epochNanoseconds,
    // timeZone), with an optional trailing calendar.
    const r = try installConstructor(realm, .{
        .name = "ZonedDateTime",
        .ctor = zonedDateTimeConstructor,
        .arity = 2,
        .is_class = true,
        .set_home_object = true,
        .to_string_tag = "Temporal.ZonedDateTime",
        .install_global = false,
    });
    const fn_obj = r.ctor;
    const proto = r.proto;

    try installNativeGetter(realm, proto, "calendarId", zonedDateTimeCalendarId);
    try installNativeGetter(realm, proto, "timeZoneId", zonedDateTimeTimeZoneId);
    try installNativeGetter(realm, proto, "year", zonedDateTimeYear);
    try installNativeGetter(realm, proto, "month", zonedDateTimeMonth);
    try installNativeGetter(realm, proto, "monthCode", zonedDateTimeMonthCode);
    try installNativeGetter(realm, proto, "day", zonedDateTimeDay);
    try installNativeGetter(realm, proto, "hour", zonedDateTimeHour);
    try installNativeGetter(realm, proto, "minute", zonedDateTimeMinute);
    try installNativeGetter(realm, proto, "second", zonedDateTimeSecond);
    try installNativeGetter(realm, proto, "millisecond", zonedDateTimeMillisecond);
    try installNativeGetter(realm, proto, "microsecond", zonedDateTimeMicrosecond);
    try installNativeGetter(realm, proto, "nanosecond", zonedDateTimeNanosecond);
    try installNativeGetter(realm, proto, "epochMilliseconds", zonedDateTimeEpochMilliseconds);
    try installNativeGetter(realm, proto, "epochNanoseconds", zonedDateTimeEpochNanoseconds);
    try installNativeGetter(realm, proto, "dayOfWeek", zonedDateTimeDayOfWeek);
    try installNativeGetter(realm, proto, "dayOfYear", zonedDateTimeDayOfYear);
    try installNativeGetter(realm, proto, "weekOfYear", zonedDateTimeWeekOfYear);
    try installNativeGetter(realm, proto, "yearOfWeek", zonedDateTimeYearOfWeek);
    try installNativeGetter(realm, proto, "hoursInDay", zonedDateTimeHoursInDay);
    try installNativeGetter(realm, proto, "daysInWeek", zonedDateTimeDaysInWeek);
    try installNativeGetter(realm, proto, "daysInMonth", zonedDateTimeDaysInMonth);
    try installNativeGetter(realm, proto, "daysInYear", zonedDateTimeDaysInYear);
    try installNativeGetter(realm, proto, "monthsInYear", zonedDateTimeMonthsInYear);
    try installNativeGetter(realm, proto, "inLeapYear", zonedDateTimeInLeapYear);
    try installNativeGetter(realm, proto, "offset", zonedDateTimeOffset);
    try installNativeGetter(realm, proto, "offsetNanoseconds", zonedDateTimeOffsetNanoseconds);
    try installNativeGetter(realm, proto, "era", zonedDateTimeEra);
    try installNativeGetter(realm, proto, "eraYear", zonedDateTimeEraYear);

    // §6.3 conversions, serialization, and comparison.
    try installNativeMethodOnProto(realm, proto, "equals", zonedDateTimeEquals, 1);
    try installNativeMethodOnProto(realm, proto, "toString", zonedDateTimeToString, 0);
    try installNativeMethodOnProto(realm, proto, "toJSON", zonedDateTimeToJSON, 0);
    try installNativeMethodOnProto(realm, proto, "toLocaleString", zonedDateTimeToLocaleString, 0);
    try installNativeMethodOnProto(realm, proto, "valueOf", zonedDateTimeValueOf, 0);
    try installNativeMethodOnProto(realm, proto, "toInstant", zonedDateTimeToInstant, 0);
    try installNativeMethodOnProto(realm, proto, "toPlainDate", zonedDateTimeToPlainDate, 0);
    try installNativeMethodOnProto(realm, proto, "toPlainTime", zonedDateTimeToPlainTime, 0);
    try installNativeMethodOnProto(realm, proto, "toPlainDateTime", zonedDateTimeToPlainDateTime, 0);

    // §6.3 field replacement, arithmetic, rounding, and transitions.
    try installNativeMethodOnProto(realm, proto, "with", zonedDateTimeWith, 1);
    try installNativeMethodOnProto(realm, proto, "withPlainTime", zonedDateTimeWithPlainTime, 0);
    try installNativeMethodOnProto(realm, proto, "withTimeZone", zonedDateTimeWithTimeZone, 1);
    try installNativeMethodOnProto(realm, proto, "withCalendar", zonedDateTimeWithCalendar, 1);
    try installNativeMethodOnProto(realm, proto, "add", zonedDateTimeAdd, 1);
    try installNativeMethodOnProto(realm, proto, "subtract", zonedDateTimeSubtract, 1);
    try installNativeMethodOnProto(realm, proto, "until", zonedDateTimeUntil, 1);
    try installNativeMethodOnProto(realm, proto, "since", zonedDateTimeSince, 1);
    try installNativeMethodOnProto(realm, proto, "round", zonedDateTimeRound, 1);
    try installNativeMethodOnProto(realm, proto, "startOfDay", zonedDateTimeStartOfDay, 0);
    try installNativeMethodOnProto(realm, proto, "getTimeZoneTransition", zonedDateTimeGetTimeZoneTransition, 1);

    try installNativeMethod(realm, fn_obj, "from", zonedDateTimeFrom, 1);
    try installNativeMethod(realm, fn_obj, "compare", zonedDateTimeCompare, 2);

    realm.intrinsics.temporal_zoned_date_time_constructor = fn_obj;
    realm.intrinsics.temporal_zoned_date_time_prototype = proto;
    try setNonEnumerable(ns, realm.allocator, "ZonedDateTime", heap_mod.taggedFunction(fn_obj));
}

/// §6.1.1 Temporal.ZonedDateTime ( epochNanoseconds, timeZone [, calendar] ).
/// `new`-only. ToBigInt-coerces + range-checks the epoch ns first (so a
/// Number throws TypeError, an out-of-range BigInt a RangeError), then
/// requires `timeZone` to be a String it can parse as a time-zone
/// identifier — a non-string is a TypeError, and a string that is not a
/// bare identifier (empty, a full ISO date-time, or a named IANA zone) is
/// a RangeError. Finally only the ISO calendar is accepted.
fn zonedDateTimeConstructor(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const inst = heap_mod.valueAsPlainObject(this_value) orelse
        return throwTypeError(realm, "Temporal.ZonedDateTime constructor requires 'new'");
    // §6.1.1 step 2-3 — ToBigInt(epochNanoseconds) then IsValidEpochNanoseconds.
    const bi_val = try bigint_builtin.toBigIntValue(realm, argOr(args, 0, Value.undefined_));
    const epoch_ns = try epochNsFromBigInt(realm, bi_val);
    // step 4-5 — timeZone must be a String; parse it as an identifier.
    const tz_arg = argOr(args, 1, Value.undefined_);
    if (!tz_arg.isString()) return throwTypeError(realm, "time zone must be a string");
    const tz_str: *JSString = @ptrCast(@alignCast(tz_arg.asString()));
    const tz = temporal.parseTimeZoneString(tz_str.flatBytes()) orelse
        return throwRangeError(realm, "invalid time zone identifier");
    // step 7-9 — calendar defaults to iso8601; only the ISO calendar ships.
    try requireISOCalendar(realm, argOr(args, 2, Value.undefined_));
    try storeZonedDateTime(realm, inst, .{ .epoch_ns = epoch_ns, .time_zone = tz });
    return heap_mod.taggedObject(inst);
}

fn storeZonedDateTime(realm: *Realm, inst: *JSObject, rec: ZonedDateTimeRecord) NativeError!void {
    const r = realm.allocator.create(TemporalRecord) catch return error.OutOfMemory;
    r.* = .{ .zoned_date_time = rec };
    inst.setTemporalRecord(realm.allocator, r) catch return error.OutOfMemory;
}

/// §6.5.x CreateTemporalZonedDateTime — allocate a fresh ZonedDateTime with
/// the realm prototype. `pub` so future Instant / PlainDateTime bridges
/// (`toZonedDateTimeISO`, …) can mint one.
pub fn createTemporalZonedDateTime(realm: *Realm, rec: ZonedDateTimeRecord) NativeError!Value {
    const inst = realm.heap.allocateObject() catch return error.OutOfMemory;
    realm.heap.setObjectPrototype(inst, realm.intrinsics.temporal_zoned_date_time_prototype.?);
    try storeZonedDateTime(realm, inst, rec);
    return heap_mod.taggedObject(inst);
}

/// §6.x RequireInternalSlot(zdt, [[InitializedTemporalZonedDateTime]]).
fn requireZonedDateTime(realm: *Realm, this_value: Value) NativeError!ZonedDateTimeRecord {
    const obj = heap_mod.valueAsPlainObject(this_value) orelse
        return throwTypeError(realm, "not a Temporal.ZonedDateTime");
    const rec = obj.getTemporalRecord() orelse
        return throwTypeError(realm, "not a Temporal.ZonedDateTime");
    return switch (rec.*) {
        .zoned_date_time => |z| z,
        else => throwTypeError(realm, "not a Temporal.ZonedDateTime"),
    };
}

/// The local (wall-clock) ISO date-time the receiver's zone shows — the
/// basis for every date/time field getter (§6.5.x GetISODateTimeFor).
fn zonedDateTimeFields(realm: *Realm, this_value: Value) NativeError!PlainDateTimeRecord {
    const z = try requireZonedDateTime(realm, this_value);
    return temporal.getISODateTimeFor(z.time_zone, z.epoch_ns);
}

// Getters — calendar/zone identity, the local date/time fields (derived
// through the zone offset), and the epoch read-throughs.
fn zonedDateTimeCalendarId(realm: *Realm, t: Value, a: []const Value) NativeError!Value {
    _ = a;
    _ = try requireZonedDateTime(realm, t);
    const js = realm.heap.allocateString("iso8601") catch return error.OutOfMemory;
    return Value.fromString(js);
}
fn zonedDateTimeTimeZoneId(realm: *Realm, t: Value, a: []const Value) NativeError!Value {
    _ = a;
    const z = try requireZonedDateTime(realm, t);
    var buf: [16]u8 = undefined;
    const s = temporal.timeZoneIdentifierString(z.time_zone, &buf);
    const js = realm.heap.allocateString(s) catch return error.OutOfMemory;
    return Value.fromString(js);
}
fn zonedDateTimeYear(realm: *Realm, t: Value, a: []const Value) NativeError!Value {
    _ = a;
    return Value.fromInt32((try zonedDateTimeFields(realm, t)).iso_year);
}
fn zonedDateTimeMonth(realm: *Realm, t: Value, a: []const Value) NativeError!Value {
    _ = a;
    return Value.fromInt32(@intCast((try zonedDateTimeFields(realm, t)).iso_month));
}
fn zonedDateTimeMonthCode(realm: *Realm, t: Value, a: []const Value) NativeError!Value {
    _ = a;
    const rec = try zonedDateTimeFields(realm, t);
    const mc = [_]u8{ 'M', '0' + @as(u8, @intCast(rec.iso_month / 10)), '0' + @as(u8, @intCast(rec.iso_month % 10)) };
    const js = realm.heap.allocateString(&mc) catch return error.OutOfMemory;
    return Value.fromString(js);
}
fn zonedDateTimeDay(realm: *Realm, t: Value, a: []const Value) NativeError!Value {
    _ = a;
    return Value.fromInt32(@intCast((try zonedDateTimeFields(realm, t)).iso_day));
}
fn zonedDateTimeHour(realm: *Realm, t: Value, a: []const Value) NativeError!Value {
    _ = a;
    return Value.fromInt32(@intCast((try zonedDateTimeFields(realm, t)).hour));
}
fn zonedDateTimeMinute(realm: *Realm, t: Value, a: []const Value) NativeError!Value {
    _ = a;
    return Value.fromInt32(@intCast((try zonedDateTimeFields(realm, t)).minute));
}
fn zonedDateTimeSecond(realm: *Realm, t: Value, a: []const Value) NativeError!Value {
    _ = a;
    return Value.fromInt32(@intCast((try zonedDateTimeFields(realm, t)).second));
}
fn zonedDateTimeMillisecond(realm: *Realm, t: Value, a: []const Value) NativeError!Value {
    _ = a;
    return Value.fromInt32(@intCast((try zonedDateTimeFields(realm, t)).millisecond));
}
fn zonedDateTimeMicrosecond(realm: *Realm, t: Value, a: []const Value) NativeError!Value {
    _ = a;
    return Value.fromInt32(@intCast((try zonedDateTimeFields(realm, t)).microsecond));
}
fn zonedDateTimeNanosecond(realm: *Realm, t: Value, a: []const Value) NativeError!Value {
    _ = a;
    return Value.fromInt32(@intCast((try zonedDateTimeFields(realm, t)).nanosecond));
}
fn zonedDateTimeEpochMilliseconds(realm: *Realm, t: Value, a: []const Value) NativeError!Value {
    _ = a;
    const z = try requireZonedDateTime(realm, t);
    const ms = @divFloor(z.epoch_ns, 1_000_000);
    return Value.fromDouble(@floatFromInt(ms));
}
fn zonedDateTimeEpochNanoseconds(realm: *Realm, t: Value, a: []const Value) NativeError!Value {
    _ = a;
    const z = try requireZonedDateTime(realm, t);
    const bi = realm.heap.allocateBigInt(z.epoch_ns) catch return error.OutOfMemory;
    return heap_mod.taggedBigInt(bi);
}
fn zonedDateTimeDayOfWeek(realm: *Realm, t: Value, a: []const Value) NativeError!Value {
    _ = a;
    const rec = try zonedDateTimeFields(realm, t);
    return Value.fromInt32(temporal.isoDayOfWeek(rec.iso_year, rec.iso_month, rec.iso_day));
}
fn zonedDateTimeDayOfYear(realm: *Realm, t: Value, a: []const Value) NativeError!Value {
    _ = a;
    const rec = try zonedDateTimeFields(realm, t);
    return Value.fromInt32(temporal.isoDayOfYear(rec.iso_year, rec.iso_month, rec.iso_day));
}
fn zonedDateTimeWeekOfYear(realm: *Realm, t: Value, a: []const Value) NativeError!Value {
    _ = a;
    const rec = try zonedDateTimeFields(realm, t);
    return Value.fromInt32(temporal.isoWeekOfYear(rec.iso_year, rec.iso_month, rec.iso_day).week);
}
fn zonedDateTimeYearOfWeek(realm: *Realm, t: Value, a: []const Value) NativeError!Value {
    _ = a;
    const rec = try zonedDateTimeFields(realm, t);
    return Value.fromInt32(temporal.isoWeekOfYear(rec.iso_year, rec.iso_month, rec.iso_day).year);
}
fn zonedDateTimeHoursInDay(realm: *Realm, t: Value, a: []const Value) NativeError!Value {
    _ = a;
    _ = try requireZonedDateTime(realm, t);
    // A constant-offset zone has no DST transition, so every day is exactly
    // 24 hours. (A future tzdata build would diff this day's start-of-day
    // epoch from the next day's via getEpochNanosecondsFor.)
    return Value.fromInt32(24);
}
fn zonedDateTimeDaysInWeek(realm: *Realm, t: Value, a: []const Value) NativeError!Value {
    _ = a;
    _ = try requireZonedDateTime(realm, t);
    return Value.fromInt32(7);
}
fn zonedDateTimeDaysInMonth(realm: *Realm, t: Value, a: []const Value) NativeError!Value {
    _ = a;
    const rec = try zonedDateTimeFields(realm, t);
    return Value.fromInt32(@intCast(temporal.daysInIsoMonth(rec.iso_year, rec.iso_month)));
}
fn zonedDateTimeDaysInYear(realm: *Realm, t: Value, a: []const Value) NativeError!Value {
    _ = a;
    const rec = try zonedDateTimeFields(realm, t);
    return Value.fromInt32(temporal.isoDaysInYear(rec.iso_year));
}
fn zonedDateTimeMonthsInYear(realm: *Realm, t: Value, a: []const Value) NativeError!Value {
    _ = a;
    _ = try requireZonedDateTime(realm, t);
    return Value.fromInt32(12);
}
fn zonedDateTimeInLeapYear(realm: *Realm, t: Value, a: []const Value) NativeError!Value {
    _ = a;
    const rec = try zonedDateTimeFields(realm, t);
    return Value.fromBool(temporal.isLeapYear(rec.iso_year));
}
fn zonedDateTimeOffset(realm: *Realm, t: Value, a: []const Value) NativeError!Value {
    _ = a;
    const z = try requireZonedDateTime(realm, t);
    // §6.5.x get offset — FormatUTCOffsetNanoseconds of the numeric offset.
    // Whole-minute offsets render as ±HH:MM; the UTC zone reports "+00:00"
    // here (distinct from its "UTC" timeZoneId).
    const off_ns = temporal.getOffsetNanosecondsFor(z.time_zone, z.epoch_ns);
    const off_min: i32 = @intCast(@divTrunc(off_ns, 60_000_000_000));
    var buf: [16]u8 = undefined;
    const s = temporal.timeZoneIdentifierString(.{ .offset_minutes = off_min }, &buf);
    const js = realm.heap.allocateString(s) catch return error.OutOfMemory;
    return Value.fromString(js);
}
fn zonedDateTimeOffsetNanoseconds(realm: *Realm, t: Value, a: []const Value) NativeError!Value {
    _ = a;
    const z = try requireZonedDateTime(realm, t);
    // |offset| ≤ 1439 min ⇒ |ns| ≤ 8.6×10^13 < 2^53, so the Number is exact.
    const off_ns = temporal.getOffsetNanosecondsFor(z.time_zone, z.epoch_ns);
    return Value.fromDouble(@floatFromInt(off_ns));
}
fn zonedDateTimeEra(realm: *Realm, t: Value, a: []const Value) NativeError!Value {
    _ = a;
    _ = try requireZonedDateTime(realm, t);
    return Value.undefined_; // ISO calendar has no era
}
fn zonedDateTimeEraYear(realm: *Realm, t: Value, a: []const Value) NativeError!Value {
    _ = a;
    _ = try requireZonedDateTime(realm, t);
    return Value.undefined_;
}

// ── §6 option readers + conversions ────────────────────────────────────────

/// §13.x GetTemporalDisambiguationOption — read + validate `disambiguation`
/// ("compatible" / "earlier" / "later" / "reject"). Cynic ships fixed-offset
/// zones only, so there is never a DST gap/overlap and the resolved value is
/// never consulted; we still read and range-check it for the observable
/// side effect (a getter on the options bag) and the RangeError on a bad
/// value that fixtures assert.
fn getDisambiguationOption(realm: *Realm, options: Value) NativeError!void {
    const obj = (try getOptionsObject(realm, options)) orelse return;
    const v = try getPropertyChain(realm, obj, "disambiguation");
    if (v.isUndefined()) return;
    const s = try stringifyArg(realm, v);
    const b = s.flatBytes();
    if (std.mem.eql(u8, b, "compatible") or std.mem.eql(u8, b, "earlier") or
        std.mem.eql(u8, b, "later") or std.mem.eql(u8, b, "reject")) return;
    return throwRangeError(realm, "disambiguation must be compatible / earlier / later / reject");
}

/// §13.x GetTemporalOffsetOption — read + validate the `offset` resolution
/// option ("prefer" / "use" / "ignore" / "reject"), falling back to
/// `fallback` when absent.
fn getOffsetOption(realm: *Realm, options: Value, fallback: temporal.OffsetOption) NativeError!temporal.OffsetOption {
    const obj = (try getOptionsObject(realm, options)) orelse return fallback;
    const v = try getPropertyChain(realm, obj, "offset");
    if (v.isUndefined()) return fallback;
    const s = try stringifyArg(realm, v);
    const b = s.flatBytes();
    if (std.mem.eql(u8, b, "prefer")) return .prefer;
    if (std.mem.eql(u8, b, "use")) return .use;
    if (std.mem.eql(u8, b, "ignore")) return .ignore;
    if (std.mem.eql(u8, b, "reject")) return .reject;
    return throwRangeError(realm, "offset must be prefer / use / ignore / reject");
}

/// §13.x GetTemporalTimeZoneNameOption — `timeZoneName` for toString
/// ("auto" / "never" / "critical"; default "auto").
fn getTimeZoneNameOption(realm: *Realm, options: Value) NativeError!temporal.TimeZoneNameDisplay {
    const obj = (try getOptionsObject(realm, options)) orelse return .auto;
    const v = try getPropertyChain(realm, obj, "timeZoneName");
    if (v.isUndefined()) return .auto;
    const s = try stringifyArg(realm, v);
    const b = s.flatBytes();
    if (std.mem.eql(u8, b, "auto")) return .auto;
    if (std.mem.eql(u8, b, "never")) return .never;
    if (std.mem.eql(u8, b, "critical")) return .critical;
    return throwRangeError(realm, "timeZoneName must be auto / never / critical");
}

/// §13.x GetTemporalShowOffsetOption — the toString `offset` knob
/// ("auto" ⇒ show, "never" ⇒ hide; default "auto"). Distinct option space
/// from `getOffsetOption`, which reads the same key for the `from` family.
fn getShowOffsetOption(realm: *Realm, options: Value) NativeError!bool {
    const obj = (try getOptionsObject(realm, options)) orelse return true;
    const v = try getPropertyChain(realm, obj, "offset");
    if (v.isUndefined()) return true;
    const s = try stringifyArg(realm, v);
    const b = s.flatBytes();
    if (std.mem.eql(u8, b, "auto")) return true;
    if (std.mem.eql(u8, b, "never")) return false;
    return throwRangeError(realm, "offset must be auto / never");
}

/// §13.x GetTemporalFractionalSecondDigitsOption — null ⇒ "auto"; otherwise
/// an integer 0..9 (truncated). A non-Number value must stringify to "auto".
fn getFractionalSecondDigitsOption(realm: *Realm, options: Value) NativeError!?u4 {
    const obj = (try getOptionsObject(realm, options)) orelse return null;
    const v = try getPropertyChain(realm, obj, "fractionalSecondDigits");
    if (v.isUndefined()) return null;
    if (!v.isInt32() and !v.isDouble()) {
        const s = try stringifyArg(realm, v);
        if (std.mem.eql(u8, s.flatBytes(), "auto")) return null;
        return throwRangeError(realm, "fractionalSecondDigits must be 'auto' or an integer 0..9");
    }
    // §13.x GetStringOrNumberOption: reject non-finite, then FLOOR (not
    // truncate) — so -0.6 floors to -1 and is rejected, 2.5 floors to 2.
    const d = numberToF64(try toNumber(realm, v));
    if (!std.math.isFinite(d)) return throwRangeError(realm, "fractionalSecondDigits must be finite");
    const floored = std.math.floor(d);
    if (!(floored >= 0 and floored <= 9)) return throwRangeError(realm, "fractionalSecondDigits must be 0..9");
    return @as(u4, @intFromFloat(floored));
}

/// §13.x ToSecondsStringPrecisionRecord — fold a resolved `smallestUnit`
/// (minute..nanosecond, or null) and `fractionalSecondDigits` (0..9 digits,
/// or null ⇒ "auto") into the display precision plus the unit / increment
/// the value is rounded to before formatting. `smallestUnit` wins when set.
const SecondsStringPrecision = struct {
    precision: temporal.Precision,
    unit: temporal.LargestUnit,
    increment: i128,
};
fn toSecondsStringPrecision(smallest: ?temporal.LargestUnit, digits: ?u4) SecondsStringPrecision {
    if (smallest) |u| {
        return switch (u) {
            .minute => .{ .precision = .minute, .unit = .minute, .increment = 1 },
            .second => .{ .precision = .{ .digits = 0 }, .unit = .second, .increment = 1 },
            .millisecond => .{ .precision = .{ .digits = 3 }, .unit = .millisecond, .increment = 1 },
            .microsecond => .{ .precision = .{ .digits = 6 }, .unit = .microsecond, .increment = 1 },
            .nanosecond => .{ .precision = .{ .digits = 9 }, .unit = .nanosecond, .increment = 1 },
            // hour / day / week / month / year are rejected before this point.
            else => unreachable,
        };
    }
    const d = digits orelse return .{ .precision = .auto, .unit = .nanosecond, .increment = 1 };
    if (d == 0) return .{ .precision = .{ .digits = 0 }, .unit = .second, .increment = 1 };
    if (d <= 3) return .{ .precision = .{ .digits = d }, .unit = .millisecond, .increment = pow10(3 - d) };
    if (d <= 6) return .{ .precision = .{ .digits = d }, .unit = .microsecond, .increment = pow10(6 - d) };
    return .{ .precision = .{ .digits = d }, .unit = .nanosecond, .increment = pow10(9 - d) };
}
fn pow10(e: u4) i128 {
    var r: i128 = 1;
    var i: u4 = 0;
    while (i < e) : (i += 1) r *= 10;
    return r;
}

/// Reject a `smallestUnit` toString option coarser than `minute`
/// (year..hour). Per GetTemporalUnitValuedOption's read-then-validate
/// ordering this must run only after every other option has been read and
/// cast — the order-of-operations fixtures observe `timeZoneName` /
/// `timeZone` being read even when `smallestUnit` is an invalid date unit.
fn requireToStringSmallestUnit(realm: *Realm, unit: ?temporal.LargestUnit) NativeError!void {
    const u = unit orelse return;
    if (@intFromEnum(u) < @intFromEnum(temporal.LargestUnit.minute)) {
        return throwRangeError(realm, "smallestUnit must be minute, second, millisecond, microsecond, or nanosecond");
    }
}

/// §7.3.x Temporal.Duration.prototype.toString rejects a `smallestUnit`
/// coarser than `second` (year..hour). Unlike the PlainTime form it does
/// not accept `minute` — the duration grammar has no minute-only seconds
/// suppression. The spec reads `smallestUnit` with the `time` unit group
/// (so year/month/week/day fail the group) then throws for hour/minute;
/// both paths surface a RangeError, so one coarser-than-second guard
/// reproduces the observable result. Run after every other option is read.
fn requireDurationToStringSmallestUnit(realm: *Realm, unit: ?temporal.LargestUnit) NativeError!void {
    const u = unit orelse return;
    if (@intFromEnum(u) < @intFromEnum(temporal.LargestUnit.second)) {
        return throwRangeError(realm, "smallestUnit must be second, millisecond, microsecond, or nanosecond");
    }
}

/// §11.x TimeZoneEquals — for the offset-only scope two zones are equal when
/// both are the named UTC zone or both carry the same whole-minute offset.
fn timeZoneEquals(a: temporal.TimeZone, b: temporal.TimeZone) bool {
    return switch (a) {
        .utc => std.meta.activeTag(b) == .utc,
        .offset_minutes => |am| switch (b) {
            .offset_minutes => |bm| am == bm,
            else => false,
        },
    };
}

/// §6.5.x ToTemporalZonedDateTime, property-bag branch — read `timeZone`
/// (required) and `offset` (optional) off the item alongside the calendar
/// date/time fields via the shared raw reader, read the three options in
/// their fixed order (disambiguation → offset → overflow), resolve +
/// regulate, then anchor to an instant via InterpretISODateTimeOffset.
fn toZonedDateTimeFields(realm: *Realm, obj: *JSObject, options: Value) NativeError!ZonedDateTimeRecord {
    // §6.5.x ToTemporalZonedDateTime: read the calendar + full field set
    // (date/time + `offset` + required `time-zone`) in one alphabetical
    // pass, then the three resolved options in their fixed order
    // (disambiguation → offset → overflow, per from/order-of-operations.js),
    // and only then resolve + regulate. Reading every field before the
    // options matters for `from(item, null)`, which must observe all field
    // gets before the options-object TypeError.
    var extras: ZonedFieldExtras = .{};
    const f = try readDateTimeFieldsRaw(realm, obj, &extras);
    try getDisambiguationOption(realm, options);
    const offset_opt = try getOffsetOption(realm, options, .reject);
    const overflow = try getTemporalOverflowOption(realm, options);
    const dt = try resolveDateTimeFields(realm, f, overflow);
    const epoch = temporal.interpretISODateTimeOffset(dt, extras.behaviour, extras.offset_ns, extras.time_zone, offset_opt) catch |e| switch (e) {
        error.OffsetMismatch => return throwRangeError(realm, "offset does not match the time zone"),
        error.Invalid => return throwRangeError(realm, "ZonedDateTime is out of range"),
    };
    return .{ .epoch_ns = epoch, .time_zone = extras.time_zone };
}

/// §6.5.x ToTemporalZonedDateTime — a ZonedDateTime (copy, options read for
/// side effects), a property bag, or an ISO 8601 string with a required
/// `[time-zone]` annotation.
fn toTemporalZonedDateTime(realm: *Realm, item: Value, options: Value) NativeError!ZonedDateTimeRecord {
    if (heap_mod.valueAsPlainObject(item)) |obj| {
        if (obj.getTemporalRecord()) |rec| {
            switch (rec.*) {
                .zoned_date_time => |z| {
                    try getDisambiguationOption(realm, options);
                    _ = try getOffsetOption(realm, options, .reject);
                    _ = try getTemporalOverflowOption(realm, options);
                    return z;
                },
                else => {},
            }
        }
        return toZonedDateTimeFields(realm, obj, options);
    }
    if (!item.isString()) return throwTypeError(realm, "Temporal.ZonedDateTime.from expects an object or ISO 8601 string");
    const s: *JSString = @ptrCast(@alignCast(item.asString()));
    const parsed = temporal.parseTemporalZonedDateTimeString(s.flatBytes()) catch
        return throwRangeError(realm, "invalid ISO 8601 ZonedDateTime string");
    try getDisambiguationOption(realm, options);
    const offset_opt = try getOffsetOption(realm, options, .reject);
    _ = try getTemporalOverflowOption(realm, options);
    const epoch = temporal.interpretISODateTimeOffset(parsed.date_time, parsed.behaviour, parsed.offset_ns, parsed.time_zone, offset_opt) catch |e| switch (e) {
        error.OffsetMismatch => return throwRangeError(realm, "offset does not match the time zone"),
        error.Invalid => return throwRangeError(realm, "ZonedDateTime is out of range"),
    };
    return .{ .epoch_ns = epoch, .time_zone = parsed.time_zone };
}

/// §6.2.x Temporal.ZonedDateTime.from ( item [ , options ] ).
fn zonedDateTimeFrom(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = this_value;
    const rec = try toTemporalZonedDateTime(realm, argOr(args, 0, Value.undefined_), argOr(args, 1, Value.undefined_));
    return createTemporalZonedDateTime(realm, rec);
}

/// §6.2.x Temporal.ZonedDateTime.compare ( one, two ) — ordered by the
/// underlying epoch nanoseconds (the zone and calendar are irrelevant).
fn zonedDateTimeCompare(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = this_value;
    const one = try toTemporalZonedDateTime(realm, argOr(args, 0, Value.undefined_), Value.undefined_);
    const two = try toTemporalZonedDateTime(realm, argOr(args, 1, Value.undefined_), Value.undefined_);
    const cmp: i32 = if (one.epoch_ns < two.epoch_ns) -1 else if (one.epoch_ns > two.epoch_ns) @as(i32, 1) else 0;
    return Value.fromInt32(cmp);
}

/// §6.3.x Temporal.ZonedDateTime.prototype.equals ( other ) — same instant,
/// same time zone, same calendar (always ISO here).
fn zonedDateTimeEquals(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const z = try requireZonedDateTime(realm, this_value);
    const other = try toTemporalZonedDateTime(realm, argOr(args, 0, Value.undefined_), Value.undefined_);
    const eq = z.epoch_ns == other.epoch_ns and timeZoneEquals(z.time_zone, other.time_zone);
    return Value.fromBool(eq);
}

/// §6.3.x Temporal.ZonedDateTime.prototype.toString ( [ options ] ).
fn zonedDateTimeToString(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const z = try requireZonedDateTime(realm, this_value);
    const options = argOr(args, 0, Value.undefined_);
    // §6.3.x — read every option (in the spec's alphabetical order) before
    // any algorithmic validation: calendarName, fractionalSecondDigits,
    // offset, roundingMode, smallestUnit, timeZoneName.
    const cal = try getCalendarNameOption(realm, options);
    const frac = try getFractionalSecondDigitsOption(realm, options);
    const show_off = try getShowOffsetOption(realm, options);
    const opts_obj = try getOptionsObject(realm, options);
    const mode = try getRoundingModeOption(realm, opts_obj, .trunc);
    const smallest = try getTemporalUnitOption(realm, opts_obj, "smallestUnit");
    const tz_name = try getTimeZoneNameOption(realm, options);
    try requireToStringSmallestUnit(realm, smallest);

    const prec = toSecondsStringPrecision(smallest, frac);
    const inc_ns = prec.increment * temporal.unitNanoseconds(prec.unit);
    const rounded_ns = temporal.roundToIncrementAsIfPositive(z.epoch_ns, inc_ns, mode);
    if (!temporal.isValidEpochNanoseconds(rounded_ns)) {
        return throwRangeError(realm, "rounded ZonedDateTime is out of range");
    }
    var buf: [80]u8 = undefined;
    const out = temporal.zonedDateTimeToString(.{ .epoch_ns = rounded_ns, .time_zone = z.time_zone }, &buf, .{
        .calendar = cal,
        .time_zone_name = tz_name,
        .show_offset = show_off,
        .precision = prec.precision,
    });
    const js = realm.heap.allocateString(out) catch return error.OutOfMemory;
    return Value.fromString(js);
}

/// §6.3.x Temporal.ZonedDateTime.prototype.toJSON ( ) — the default
/// serialization (no options).
fn zonedDateTimeToJSON(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    const z = try requireZonedDateTime(realm, this_value);
    var buf: [80]u8 = undefined;
    const out = temporal.zonedDateTimeToString(z, &buf, .{});
    const js = realm.heap.allocateString(out) catch return error.OutOfMemory;
    return Value.fromString(js);
}

/// §6.3.x Temporal.ZonedDateTime.prototype.toLocaleString ( ) — without an
/// Intl build, this is the default ISO serialization (locale/options ignored).
fn zonedDateTimeToLocaleString(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    const z = try requireZonedDateTime(realm, this_value);
    var buf: [80]u8 = undefined;
    const out = temporal.zonedDateTimeToString(z, &buf, .{});
    const js = realm.heap.allocateString(out) catch return error.OutOfMemory;
    return Value.fromString(js);
}

/// §6.3.x Temporal.ZonedDateTime.prototype.valueOf — always throws, to head
/// off the implicit relational comparison `zdt1 < zdt2` losing information.
fn zonedDateTimeValueOf(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = this_value;
    _ = args;
    return throwTypeError(realm, "Temporal.ZonedDateTime does not support implicit conversion; use compare() or equals()");
}

/// §6.3.x Temporal.ZonedDateTime.prototype.toInstant ( ) — the same instant.
fn zonedDateTimeToInstant(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    const z = try requireZonedDateTime(realm, this_value);
    return createTemporalInstant(realm, z.epoch_ns);
}

/// §6.3.x Temporal.ZonedDateTime.prototype.toPlainDate ( ) — the local
/// (wall-clock) ISO date the zone shows at the instant.
fn zonedDateTimeToPlainDate(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    const z = try requireZonedDateTime(realm, this_value);
    const dt = temporal.getISODateTimeFor(z.time_zone, z.epoch_ns);
    return createTemporalDate(realm, dt.date());
}

/// §6.3.x Temporal.ZonedDateTime.prototype.toPlainTime ( ) — the local
/// wall-clock time the zone shows at the instant.
fn zonedDateTimeToPlainTime(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    const z = try requireZonedDateTime(realm, this_value);
    const dt = temporal.getISODateTimeFor(z.time_zone, z.epoch_ns);
    return createTemporalTime(realm, dt.time());
}

/// §6.3.x Temporal.ZonedDateTime.prototype.toPlainDateTime ( ) — the local
/// wall-clock date-time the zone shows at the instant.
fn zonedDateTimeToPlainDateTime(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    const z = try requireZonedDateTime(realm, this_value);
    const dt = temporal.getISODateTimeFor(z.time_zone, z.epoch_ns);
    return createTemporalDateTime(realm, dt);
}

/// §11.x ToTemporalTimeZoneIdentifier — a ZonedDateTime-bearing object
/// yields its own [[TimeZone]]; a String is parsed as an identifier (bare
/// or extracted from an ISO date-time string); anything else is a
/// TypeError. The offset-only scope means the parse rejects named IANA
/// zones and sub-minute precision.
fn toTimeZoneArg(realm: *Realm, arg: Value) NativeError!temporal.TimeZone {
    if (heap_mod.valueAsPlainObject(arg)) |o| {
        if (o.getTemporalRecord()) |rec| {
            if (rec.* == .zoned_date_time) return rec.zoned_date_time.time_zone;
        }
    }
    if (!arg.isString()) return throwTypeError(realm, "time zone must be a string or Temporal.ZonedDateTime");
    const s: *JSString = @ptrCast(@alignCast(arg.asString()));
    return temporal.parseTimeZoneString(s.flatBytes()) orelse
        return throwRangeError(realm, "invalid time zone identifier");
}

/// §6.3.x Temporal.ZonedDateTime.prototype.with ( temporalZonedDateTimeLike
/// [ , options ] ) — merge partial fields over the receiver's wall-clock
/// fields (and offset), then re-anchor to an instant via
/// InterpretISODateTimeOffset. The `offset` field defaults to the
/// receiver's current offset; the `offset` resolution option defaults to
/// "prefer". `calendar` / `timeZone` keys on the like-object are rejected.
fn zonedDateTimeWith(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const z = try requireZonedDateTime(realm, this_value);
    const like = argOr(args, 0, Value.undefined_);
    const obj = heap_mod.valueAsPlainObject(like) orelse
        return throwTypeError(realm, "ZonedDateTime-like must be an object");
    try rejectTemporalLikeObject(realm, obj);

    const base = temporal.getISODateTimeFor(z.time_zone, z.epoch_ns);
    var year: i64 = base.iso_year;
    var month_int: i64 = base.iso_month;
    var month_int_set = false;
    var month_code_buf: [8]u8 = undefined;
    var month_code_len: ?usize = null;
    var day: i64 = base.iso_day;
    var hour: f64 = @floatFromInt(base.hour);
    var minute: f64 = @floatFromInt(base.minute);
    var second: f64 = @floatFromInt(base.second);
    var millisecond: f64 = @floatFromInt(base.millisecond);
    var microsecond: f64 = @floatFromInt(base.microsecond);
    var nanosecond: f64 = @floatFromInt(base.nanosecond);
    // The offset field defaults to the receiver's current offset; a
    // supplied numeric offset overrides it. Either way the behaviour is
    // "option" (an explicit offset to reconcile with the zone).
    var offset_ns: i128 = @as(i128, temporal.getOffsetNanosecondsFor(z.time_zone, z.epoch_ns));
    var any = false;

    // Alphabetical field order (PrepareTemporalFields): day, hour,
    // microsecond, millisecond, minute, month, monthCode, nanosecond,
    // offset, second, year.
    const day_v = try getPropertyChain(realm, obj, "day");
    if (!day_v.isUndefined()) {
        day = try dateFieldToI64(realm, try toIntegerWithTruncation(realm, day_v));
        any = true;
    }
    const hour_v = try getPropertyChain(realm, obj, "hour");
    if (!hour_v.isUndefined()) {
        hour = try toIntegerWithTruncation(realm, hour_v);
        any = true;
    }
    const microsecond_v = try getPropertyChain(realm, obj, "microsecond");
    if (!microsecond_v.isUndefined()) {
        microsecond = try toIntegerWithTruncation(realm, microsecond_v);
        any = true;
    }
    const millisecond_v = try getPropertyChain(realm, obj, "millisecond");
    if (!millisecond_v.isUndefined()) {
        millisecond = try toIntegerWithTruncation(realm, millisecond_v);
        any = true;
    }
    const minute_v = try getPropertyChain(realm, obj, "minute");
    if (!minute_v.isUndefined()) {
        minute = try toIntegerWithTruncation(realm, minute_v);
        any = true;
    }
    const month_v = try getPropertyChain(realm, obj, "month");
    if (!month_v.isUndefined()) {
        month_int = try dateFieldToI64(realm, try toIntegerWithTruncation(realm, month_v));
        month_int_set = true;
        any = true;
    }
    const month_code_v = try getPropertyChain(realm, obj, "monthCode");
    month_code_len = try readMonthCodeField(realm, month_code_v, &month_code_buf);
    if (month_code_len != null) any = true;
    const nanosecond_v = try getPropertyChain(realm, obj, "nanosecond");
    if (!nanosecond_v.isUndefined()) {
        nanosecond = try toIntegerWithTruncation(realm, nanosecond_v);
        any = true;
    }
    const offset_v = try getPropertyChain(realm, obj, "offset");
    if (!offset_v.isUndefined()) {
        const prim = try intrinsics.toPrimitive(realm, offset_v, .string);
        if (!prim.isString()) return throwTypeError(realm, "offset must be a string");
        const os: *JSString = @ptrCast(@alignCast(prim.asString()));
        offset_ns = temporal.parseOffsetString(os.flatBytes()) orelse
            return throwRangeError(realm, "invalid offset string");
        any = true;
    }
    const second_v = try getPropertyChain(realm, obj, "second");
    if (!second_v.isUndefined()) {
        second = try toIntegerWithTruncation(realm, second_v);
        any = true;
    }
    const year_v = try getPropertyChain(realm, obj, "year");
    if (!year_v.isUndefined()) {
        year = try dateFieldToI64(realm, try toIntegerWithTruncation(realm, year_v));
        any = true;
    }
    if (!any) return throwTypeError(realm, "ZonedDateTime-like must have at least one recognized property");

    // §6.3.x — the three resolved-options reads (disambiguation → offset →
    // overflow) run before any algorithmic validation: a bad `monthCode` is
    // a RangeError only after all three have fired (per
    // with/options-read-before-algorithmic-validation.js).
    try getDisambiguationOption(realm, argOr(args, 1, Value.undefined_));
    const offset_opt = try getOffsetOption(realm, argOr(args, 1, Value.undefined_), .prefer);
    const overflow = try getTemporalOverflowOption(realm, argOr(args, 1, Value.undefined_));

    var month: i64 = base.iso_month;
    if (month_code_len) |len| {
        month = try monthFromCodeBytes(realm, &month_code_buf, len);
        if (month_int_set and month_int != month) return throwRangeError(realm, "month and monthCode disagree");
    } else if (month_int_set) {
        month = month_int;
    }

    const new_date = temporal.regulateISODate(year, month, day, overflow == .reject) orelse
        return throwRangeError(realm, "ZonedDateTime date is out of range");
    const new_time = try regulateTime(realm, hour, minute, second, millisecond, microsecond, nanosecond, overflow);
    const wall = PlainDateTimeRecord.combine(new_date, new_time);
    const epoch = temporal.interpretISODateTimeOffset(wall, .option, offset_ns, z.time_zone, offset_opt) catch |e| switch (e) {
        error.OffsetMismatch => return throwRangeError(realm, "offset does not match the time zone"),
        error.Invalid => return throwRangeError(realm, "ZonedDateTime is out of range"),
    };
    return createTemporalZonedDateTime(realm, .{ .epoch_ns = epoch, .time_zone = z.time_zone });
}

/// §6.3.x Temporal.ZonedDateTime.prototype.withPlainTime ( [ plainTimeLike ] )
/// — keep the wall-clock date, replace the time (undefined ⇒ start of day,
/// i.e. midnight for a fixed-offset zone), re-anchor to an instant.
fn zonedDateTimeWithPlainTime(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const z = try requireZonedDateTime(realm, this_value);
    const arg = argOr(args, 0, Value.undefined_);
    const t: PlainTimeRecord = if (arg.isUndefined()) .{} else try toTemporalTime(realm, arg, Value.undefined_);
    const base = temporal.getISODateTimeFor(z.time_zone, z.epoch_ns);
    const wall = PlainDateTimeRecord.combine(base.date(), t);
    const epoch = temporal.getEpochNanosecondsFor(z.time_zone, wall) orelse
        return throwRangeError(realm, "ZonedDateTime is out of range");
    return createTemporalZonedDateTime(realm, .{ .epoch_ns = epoch, .time_zone = z.time_zone });
}

/// §6.3.x Temporal.ZonedDateTime.prototype.withTimeZone ( timeZoneLike ) —
/// same instant, different zone.
fn zonedDateTimeWithTimeZone(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const z = try requireZonedDateTime(realm, this_value);
    const tz = try toTimeZoneArg(realm, argOr(args, 0, Value.undefined_));
    return createTemporalZonedDateTime(realm, .{ .epoch_ns = z.epoch_ns, .time_zone = tz });
}

/// §6.3.x Temporal.ZonedDateTime.prototype.withCalendar ( calendarLike ) —
/// Cynic ships only the ISO calendar, so any accepted identifier yields a
/// copy with the same instant + zone.
fn zonedDateTimeWithCalendar(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const z = try requireZonedDateTime(realm, this_value);
    try toTemporalCalendarIdentifier(realm, argOr(args, 0, Value.undefined_));
    return createTemporalZonedDateTime(realm, z);
}

/// §6.5.x AddDurationToZonedDateTime — `add` (negate=false) / `subtract`
/// (negate=true). The date part is applied in wall clock, the time part in
/// exact time (see temporal.addZonedDateTime).
fn zonedDateTimeAddSubtract(realm: *Realm, this_value: Value, args: []const Value, negate: bool) NativeError!Value {
    const z = try requireZonedDateTime(realm, this_value);
    var dur = try toTemporalDuration(realm, argOr(args, 0, Value.undefined_));
    if (!temporal.isValidDuration(dur)) return throwRangeError(realm, "Duration values are out of range");
    const overflow = try getTemporalOverflowOption(realm, argOr(args, 1, Value.undefined_));
    if (negate) dur = temporal.negateDuration(dur);
    const epoch = temporal.addZonedDateTime(z.epoch_ns, z.time_zone, dur, overflow == .reject) orelse
        return throwRangeError(realm, "ZonedDateTime is out of range");
    return createTemporalZonedDateTime(realm, .{ .epoch_ns = epoch, .time_zone = z.time_zone });
}
fn zonedDateTimeAdd(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    return zonedDateTimeAddSubtract(realm, this_value, args, false);
}
fn zonedDateTimeSubtract(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    return zonedDateTimeAddSubtract(realm, this_value, args, true);
}
fn zonedDateTimeUntil(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    return differenceTemporalZonedDateTime(realm, this_value, args, false);
}
fn zonedDateTimeSince(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    return differenceTemporalZonedDateTime(realm, this_value, args, true);
}

/// §6.5.x DifferenceTemporalZonedDateTime — `until` / `since`.
///
/// The default largestUnit is "hour" (not "day"), so the common case is a
/// pure exact-time difference: subtract the two instants, round at the
/// smallestUnit, balance into the largestUnit. A "day" largestUnit is
/// handled too — every day in a fixed-offset zone is a uniform 24 h — but
/// only when both ZonedDateTimes share a time zone (a date unit spanning
/// two zones is a RangeError per spec). Year / month / week units need the
/// calendar-relative rounding that is not wired yet and throw a RangeError.
fn differenceTemporalZonedDateTime(realm: *Realm, this_value: Value, args: []const Value, is_since: bool) NativeError!Value {
    const z = try requireZonedDateTime(realm, this_value);
    const other = try toTemporalZonedDateTime(realm, argOr(args, 0, Value.undefined_), Value.undefined_);
    const opts = try getOptionsObject(realm, argOr(args, 1, Value.undefined_));

    const largest_opt = try getTemporalUnitOption(realm, opts, "largestUnit");
    const increment = try getRoundingIncrementOption(realm, opts);
    const mode = try getRoundingModeOption(realm, opts, .trunc);
    const smallest_opt = try getTemporalUnitOption(realm, opts, "smallestUnit");

    if (largest_opt) |lu| try requireUnitInRange(realm, lu, .year, .nanosecond);
    const smallest = smallest_opt orelse temporal.LargestUnit.nanosecond;
    try requireUnitInRange(realm, smallest, .year, .nanosecond);
    // smallestLargestDefaultUnit for ZonedDateTime is "hour".
    const default_largest: temporal.LargestUnit = @enumFromInt(@min(@intFromEnum(temporal.LargestUnit.hour), @intFromEnum(smallest)));
    const largest = largest_opt orelse default_largest;
    if (@intFromEnum(largest) > @intFromEnum(smallest)) {
        return throwRangeError(realm, "largestUnit must not be smaller than smallestUnit");
    }

    // A date-category largestUnit (year/month/week/day) requires both
    // instants be measured in the same zone: a calendar difference across
    // two zones is undefined per spec.
    if (@intFromEnum(largest) <= @intFromEnum(temporal.LargestUnit.day) and
        !timeZoneEquals(z.time_zone, other.time_zone))
    {
        return throwRangeError(realm, "cannot compute a calendar difference between ZonedDateTimes in different time zones");
    }

    // Time / day smallestUnits cap their increment at the next-larger unit;
    // calendar units (year/month/week) carry no ceiling.
    if (smallest != .day and @intFromEnum(smallest) >= @intFromEnum(temporal.LargestUnit.day)) {
        if (!temporal.validateRoundingIncrement(increment, differenceDividend(smallest), false)) {
            return throwRangeError(realm, "invalid roundingIncrement for the smallestUnit");
        }
    }

    const eff_mode = if (is_since) negateRoundingMode(mode) else mode;

    // Calendar units (year/month/week as either bound): a constant offset
    // cancels in every epoch difference the Nudge/Bubble AOs use, so the
    // zoned difference equals the PlainDateTime difference of the two
    // wall-clock times.
    if (@intFromEnum(largest) < @intFromEnum(temporal.LargestUnit.day) or
        @intFromEnum(smallest) < @intFromEnum(temporal.LargestUnit.day))
    {
        const start_wall = temporal.getISODateTimeFor(z.time_zone, z.epoch_ns);
        const end_wall = temporal.getISODateTimeFor(other.time_zone, other.epoch_ns);
        const base_diff = temporal.differenceISODateTime(start_wall, end_wall, largest);
        var dr = if (smallest == .nanosecond and increment == 1)
            base_diff
        else
            temporal.roundRelativeDateTime(start_wall, end_wall, base_diff, largest, smallest, increment, eff_mode) orelse
                return throwRangeError(realm, "rounded ZonedDateTime is outside the representable range");
        if (is_since) {
            dr.years = negZero(dr.years);
            dr.months = negZero(dr.months);
            dr.weeks = negZero(dr.weeks);
            dr.days = negZero(dr.days);
            dr.hours = negZero(dr.hours);
            dr.minutes = negZero(dr.minutes);
            dr.seconds = negZero(dr.seconds);
            dr.milliseconds = negZero(dr.milliseconds);
            dr.microseconds = negZero(dr.microseconds);
            dr.nanoseconds = negZero(dr.nanoseconds);
        }
        return createTemporalDuration(realm, dr);
    }

    // Pure exact-time / uniform-day span: subtract the instants directly.
    const diff = other.epoch_ns - z.epoch_ns;
    const rounded = temporal.roundToIncrement(diff, increment * temporal.unitNanoseconds(smallest), eff_mode);
    var dr = temporal.balanceTimeDuration(rounded, largest);
    if (is_since) {
        dr.days = negZero(dr.days);
        dr.hours = negZero(dr.hours);
        dr.minutes = negZero(dr.minutes);
        dr.seconds = negZero(dr.seconds);
        dr.milliseconds = negZero(dr.milliseconds);
        dr.microseconds = negZero(dr.microseconds);
        dr.nanoseconds = negZero(dr.nanoseconds);
    }
    return createTemporalDuration(realm, dr);
}

/// §6.3.x Temporal.ZonedDateTime.prototype.round ( roundTo ) — round the
/// instant in the zone's wall clock. smallestUnit is required (day..
/// nanosecond); for a fixed-offset zone a day is exactly 24 h.
fn zonedDateTimeRound(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const z = try requireZonedDateTime(realm, this_value);
    const round_to = argOr(args, 0, Value.undefined_);
    if (round_to.isUndefined()) {
        return throwTypeError(realm, "Temporal.ZonedDateTime.prototype.round requires a smallestUnit");
    }
    var unit: temporal.LargestUnit = undefined;
    var increment: i128 = 1;
    var mode: temporal.RoundingMode = .half_expand;
    if (round_to.isString()) {
        const s: *JSString = @ptrCast(@alignCast(round_to.asString()));
        unit = temporal.parseTemporalUnit(s.flatBytes()) orelse
            return throwRangeError(realm, "invalid smallestUnit");
    } else {
        const opts = try getOptionsObject(realm, round_to);
        increment = try getRoundingIncrementOption(realm, opts);
        mode = try getRoundingModeOption(realm, opts, .half_expand);
        unit = (try getTemporalUnitOption(realm, opts, "smallestUnit")) orelse
            return throwRangeError(realm, "smallestUnit is required");
    }
    try requireUnitInRange(realm, unit, .day, .nanosecond);
    const increment_ok = if (unit == .day)
        temporal.validateRoundingIncrement(increment, 1, true)
    else
        temporal.validateRoundingIncrement(increment, differenceDividend(unit), false);
    if (!increment_ok) {
        return throwRangeError(realm, "roundingIncrement is out of range for the smallestUnit");
    }
    const epoch = temporal.roundZonedDateTime(z.epoch_ns, z.time_zone, unit, increment, mode) orelse
        return throwRangeError(realm, "rounded ZonedDateTime is out of range");
    return createTemporalZonedDateTime(realm, .{ .epoch_ns = epoch, .time_zone = z.time_zone });
}

/// §6.3.x Temporal.ZonedDateTime.prototype.startOfDay ( ) — the instant of
/// the first wall-clock moment (midnight) of the current calendar day.
fn zonedDateTimeStartOfDay(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    const z = try requireZonedDateTime(realm, this_value);
    const epoch = temporal.zonedStartOfDay(z.epoch_ns, z.time_zone) orelse
        return throwRangeError(realm, "ZonedDateTime is out of range");
    return createTemporalZonedDateTime(realm, .{ .epoch_ns = epoch, .time_zone = z.time_zone });
}

/// §6.3.x Temporal.ZonedDateTime.prototype.getTimeZoneTransition
/// ( directionParam ) — a UTC or fixed-offset zone never changes offset, so
/// there is no next/previous transition: the result is always null. The
/// `direction` argument is still validated (required; "next" / "previous",
/// as a bare string or a `{ direction }` bag).
fn zonedDateTimeGetTimeZoneTransition(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = try requireZonedDateTime(realm, this_value);
    const arg = argOr(args, 0, Value.undefined_);
    // §6.3.x step 3 — a missing direction argument is a TypeError.
    if (arg.isUndefined()) return throwTypeError(realm, "getTimeZoneTransition requires a direction");
    // A bare string is shorthand for `{ direction: <string> }`; otherwise
    // the argument is an options bag (GetOptionsObject rejects a non-object,
    // non-string primitive with a TypeError).
    var dir_v = arg;
    if (!arg.isString()) {
        const opts = try getOptionsObject(realm, arg);
        dir_v = if (opts) |o| try getPropertyChain(realm, o, "direction") else Value.undefined_;
        // GetDirectionOption reads a *required* option, so a missing value
        // is a RangeError (not a TypeError).
        if (dir_v.isUndefined()) return throwRangeError(realm, "the 'direction' option is required");
    }
    // GetOption coerces with ToString (a Symbol throws TypeError), then the
    // value must be one of the allowed strings.
    const s = try stringifyArg(realm, dir_v);
    const b = s.flatBytes();
    if (!std.mem.eql(u8, b, "next") and !std.mem.eql(u8, b, "previous")) {
        return throwRangeError(realm, "direction must be 'next' or 'previous'");
    }
    // A UTC / fixed-offset zone never changes its offset — no transition.
    return Value.null_;
}
