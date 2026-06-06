//! Temporal.Duration — constructor, prototype methods, statics, and the
//! relative-to anchor handling used by add/subtract/round/total/until/since.

const std = @import("std");

const Realm = @import("../../realm.zig").Realm;
const Value = @import("../../value.zig").Value;
const JSString = @import("../../string.zig").JSString;
const JSObject = @import("../../object.zig").JSObject;
const NativeError = @import("../../function.zig").NativeError;
const heap_mod = @import("../../heap.zig");
const intrinsics = @import("../../intrinsics.zig");
const temporal = @import("../../temporal.zig");

const installConstructor = intrinsics.installConstructor;
const installNativeMethod = intrinsics.installNativeMethod;
const installNativeMethodOnProto = intrinsics.installNativeMethodOnProto;
const installNativeGetter = intrinsics.installNativeGetter;
const setNonEnumerable = intrinsics.setNonEnumerable;
const throwTypeError = intrinsics.throwTypeError;
const throwRangeError = intrinsics.throwRangeError;
const argOr = intrinsics.argOr;
const getPropertyChain = intrinsics.getPropertyChain;
const toNumber = intrinsics.toNumber;
const stringifyArg = intrinsics.stringifyArg;

const DurationRecord = temporal.DurationRecord;
const PlainDateTimeRecord = temporal.PlainDateTimeRecord;
const TemporalRecord = temporal.TemporalRecord;

const shared = @import("shared.zig");
const plain_date_time_mod = @import("plain_date_time.zig");

const numberToF64 = shared.numberToF64;
const argDefault0 = shared.argDefault0;
const negZero = shared.negZero;
const getOptionsObject = shared.getOptionsObject;
const getRoundingModeOption = shared.getRoundingModeOption;
const getRoundingIncrementOption = shared.getRoundingIncrementOption;
const getTemporalUnitOption = shared.getTemporalUnitOption;
const requireUnitInRange = shared.requireUnitInRange;
const negateRoundingMode = shared.negateRoundingMode;
const getFractionalSecondDigitsOption = shared.getFractionalSecondDigitsOption;
const toSecondsStringPrecision = shared.toSecondsStringPrecision;

const ZonedFieldExtras = plain_date_time_mod.ZonedFieldExtras;
const readDateTimeFieldsRaw = plain_date_time_mod.readDateTimeFieldsRaw;
const resolveDateTimeFieldsNoRange = plain_date_time_mod.resolveDateTimeFieldsNoRange;

pub fn install(realm: *Realm, ns: *JSObject) !void {
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
pub fn createTemporalDuration(realm: *Realm, d: DurationRecord) NativeError!Value {
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
pub fn toTemporalDuration(realm: *Realm, item: Value) NativeError!DurationRecord {
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
