//! Temporal.PlainDateTime — ISO-calendar wall-clock date-and-time constructor,
//! prototype methods, the raw date-time field reader, and the resolve-fields
//! pipeline shared with ZonedDateTime / Duration's relativeTo.

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
const stringifyArg = intrinsics.stringifyArg;

const PlainDateTimeRecord = temporal.PlainDateTimeRecord;
const PlainDateRecord = temporal.PlainDateRecord;
const PlainTimeRecord = temporal.PlainTimeRecord;
const TemporalRecord = temporal.TemporalRecord;

const shared = @import("shared.zig");
const duration_mod = @import("duration.zig");
const plain_time_mod = @import("plain_time.zig");
const plain_date_mod = @import("plain_date.zig");
const zoned_date_time_mod = @import("zoned_date_time.zig");
const instant_mod = @import("instant.zig");

const argDefault0 = shared.argDefault0;
const toIntegerWithTruncation = shared.toIntegerWithTruncation;
const negZero = shared.negZero;
const dateFieldToI64 = shared.dateFieldToI64;
const readPositiveDateField = shared.readPositiveDateField;
const readMonthCodeField = shared.readMonthCodeField;
const monthFromCodeBytes = shared.monthFromCodeBytes;
const Overflow = shared.Overflow;
const rejectTime = shared.rejectTime;
const regulateTime = shared.regulateTime;
const getTemporalOverflowOption = shared.getTemporalOverflowOption;
const rejectTemporalLikeObject = shared.rejectTemporalLikeObject;
const requireISOCalendar = shared.requireISOCalendar;
const requireCalendarFieldType = shared.requireCalendarFieldType;
const toTemporalCalendarIdentifier = shared.toTemporalCalendarIdentifier;
const getCalendarNameOption = shared.getCalendarNameOption;
const getOptionsObject = shared.getOptionsObject;
const getRoundingModeOption = shared.getRoundingModeOption;
const getRoundingIncrementOption = shared.getRoundingIncrementOption;
const getTemporalUnitOption = shared.getTemporalUnitOption;
const requireUnitInRange = shared.requireUnitInRange;
const negateRoundingMode = shared.negateRoundingMode;
const getDisambiguationOption = shared.getDisambiguationOption;
const getFractionalSecondDigitsOption = shared.getFractionalSecondDigitsOption;
const toSecondsStringPrecision = shared.toSecondsStringPrecision;
const requireToStringSmallestUnit = shared.requireToStringSmallestUnit;
const toTimeZoneArg = shared.toTimeZoneArg;

const toTemporalDuration = duration_mod.toTemporalDuration;
const createTemporalDuration = duration_mod.createTemporalDuration;
const toTemporalTime = plain_time_mod.toTemporalTime;
const createTemporalTime = plain_time_mod.createTemporalTime;
const createTemporalDate = plain_date_mod.createTemporalDate;
const createTemporalZonedDateTime = zoned_date_time_mod.createTemporalZonedDateTime;
const differenceDividend = instant_mod.differenceDividend;

pub fn install(realm: *Realm, ns: *JSObject) !void {
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
pub fn createTemporalDateTime(realm: *Realm, rec: PlainDateTimeRecord) NativeError!Value {
    if (!temporal.isoDateTimeWithinLimits(rec)) {
        return throwRangeError(realm, "PlainDateTime is out of range");
    }
    const inst = realm.heap.allocateObject() catch return error.OutOfMemory;
    realm.heap.setObjectPrototype(inst, realm.intrinsics.temporal_plain_date_time_prototype.?);
    try storePlainDateTime(realm, inst, rec);
    return heap_mod.taggedObject(inst);
}

pub fn requirePlainDateTime(realm: *Realm, this_value: Value) NativeError!PlainDateTimeRecord {
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
    const cal = try requireISOCalendar(realm, argOr(args, 9, Value.undefined_));

    var date = temporal.regulateISODate(y, mo, d, true) orelse
        return throwRangeError(realm, "PlainDateTime date is out of range");
    date.calendar = cal;
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
    const rec = try requirePlainDateTime(realm, t);
    return shared.calendarIdToValue(realm, rec.calendar);
}
fn plainDateTimeYear(realm: *Realm, t: Value, a: []const Value) NativeError!Value {
    _ = a;
    const rec = try requirePlainDateTime(realm, t);
    return shared.yearValue(rec.calendar, rec.iso_year, rec.iso_month, rec.iso_day);
}
fn plainDateTimeMonth(realm: *Realm, t: Value, a: []const Value) NativeError!Value {
    _ = a;
    const rec = try requirePlainDateTime(realm, t);
    return shared.monthValue(rec.calendar, rec.iso_year, rec.iso_month, rec.iso_day);
}
fn plainDateTimeDay(realm: *Realm, t: Value, a: []const Value) NativeError!Value {
    _ = a;
    const rec = try requirePlainDateTime(realm, t);
    return shared.dayValue(rec.calendar, rec.iso_year, rec.iso_month, rec.iso_day);
}
fn plainDateTimeMonthCode(realm: *Realm, t: Value, a: []const Value) NativeError!Value {
    _ = a;
    const rec = try requirePlainDateTime(realm, t);
    return shared.monthCodeValue(realm, rec.calendar, rec.iso_year, rec.iso_month, rec.iso_day);
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
    return shared.dayOfYearValue(rec.calendar, rec.iso_year, rec.iso_month, rec.iso_day);
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
    return shared.daysInMonthValue(rec.calendar, rec.iso_year, rec.iso_month, rec.iso_day);
}
fn plainDateTimeDaysInYear(realm: *Realm, t: Value, a: []const Value) NativeError!Value {
    _ = a;
    const rec = try requirePlainDateTime(realm, t);
    return shared.daysInYearValue(rec.calendar, rec.iso_year, rec.iso_month, rec.iso_day);
}
fn plainDateTimeMonthsInYear(realm: *Realm, t: Value, a: []const Value) NativeError!Value {
    _ = a;
    _ = try requirePlainDateTime(realm, t);
    return Value.fromInt32(12);
}
fn plainDateTimeInLeapYear(realm: *Realm, t: Value, a: []const Value) NativeError!Value {
    _ = a;
    const rec = try requirePlainDateTime(realm, t);
    return shared.inLeapYearValue(rec.calendar, rec.iso_year, rec.iso_month, rec.iso_day);
}
fn plainDateTimeEra(realm: *Realm, t: Value, a: []const Value) NativeError!Value {
    _ = a;
    const rec = try requirePlainDateTime(realm, t);
    return shared.eraValue(realm, rec.calendar, rec.iso_year, rec.iso_month, rec.iso_day);
}
fn plainDateTimeEraYear(realm: *Realm, t: Value, a: []const Value) NativeError!Value {
    _ = a;
    const rec = try requirePlainDateTime(realm, t);
    return shared.eraYearValue(rec.calendar, rec.iso_year, rec.iso_month, rec.iso_day);
}

/// The ZonedDateTime-only fields a property bag carries on top of the
/// PlainDateTime set — `offset` and the required `time-zone` — captured by
/// `toISODateTimeFields` as it walks the alphabetical read order so a
/// ZonedDateTime-like reads its fields in one pass (§6.5.x
/// PrepareCalendarFields with `« …, offset, time-zone »`).
pub const ZonedFieldExtras = struct {
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
pub const RawDateTimeFields = struct {
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
    calendar: temporal.CalendarId = temporal.CalendarId.iso8601(),
};

/// §13.x PrepareCalendarFields — validate the calendar, then read + coerce
/// every date/time field off `obj` in alphabetical code-unit order, with no
/// required-field checks, no `monthCode` suitability, no overflow and no
/// regulate (all deferred to `resolveDateTimeFields` so the option getters
/// fire first). When `zoned` is non-null the bag is a ZonedDateTime-like:
/// `offset` (between `nanosecond` and `second`) and the required `timeZone`
/// (between `second` and `year`) are captured into it.
pub fn readDateTimeFieldsRaw(realm: *Realm, obj: *JSObject, zoned: ?*ZonedFieldExtras) NativeError!RawDateTimeFields {
    const cal = try requireCalendarFieldType(realm, try getPropertyChain(realm, obj, "calendar"));
    var f: RawDateTimeFields = .{ .calendar = cal };

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
            // §11 ToTemporalTimeZoneIdentifier — a ZonedDateTime-bearing
            // object yields its own [[TimeZone]]; a String routes through
            // the broad ParseTemporalTimeZoneString
            // (from/argument-propertybag-timezone-object.js).
            z.time_zone = try toTimeZoneArg(realm, tz_v);
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
pub fn resolveDateTimeFields(realm: *Realm, f: RawDateTimeFields, overflow: Overflow) NativeError!PlainDateTimeRecord {
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
pub fn resolveDateTimeFieldsNoRange(realm: *Realm, f: RawDateTimeFields, overflow: Overflow) NativeError!PlainDateTimeRecord {
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

    const time = try regulateTime(realm, f.hour, f.minute, f.second, f.millisecond, f.microsecond, f.nanosecond, overflow);
    if (shared.isIslamicTabular(f.calendar)) {
        const iso = shared.islamicToIso(f.calendar, f.year, month, f.day, overflow == .reject) orelse
            return throwRangeError(realm, "PlainDateTime date is out of range");
        var date = temporal.regulateISODate(iso.year, @intCast(iso.month), @intCast(iso.day), false) orelse
            return throwRangeError(realm, "PlainDateTime date is out of range");
        date.calendar = f.calendar;
        return PlainDateTimeRecord.combine(date, time);
    }
    const iso_y = shared.calendarYearToIso(f.calendar, f.year);
    var date = temporal.regulateISODate(iso_y, month, f.day, overflow == .reject) orelse
        return throwRangeError(realm, "PlainDateTime date is out of range");
    date.calendar = f.calendar;
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
pub fn toTemporalDateTime(realm: *Realm, item: Value, options: Value) NativeError!PlainDateTimeRecord {
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
        day = try readPositiveDateField(realm, day_v);
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
        month_int = try readPositiveDateField(realm, month_v);
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

    // Islamic tabular calendars: merge against the receiver's *Islamic* fields,
    // then convert the triple back to ISO (the time half is unaffected).
    if (shared.isIslamicTabular(base.calendar)) {
        const cf = shared.calendarFields(base.calendar, base.iso_year, base.iso_month, base.iso_day);
        var im: i64 = cf.month;
        if (month_code_len) |len| {
            im = try monthFromCodeBytes(realm, &month_code_buf, len);
            if (month_int_set and month_int != im) return throwRangeError(realm, "month and monthCode disagree");
        } else if (month_int_set) {
            im = month_int;
        }
        const iy: i64 = if (year_v.isUndefined()) cf.year else year;
        const id: i64 = if (day_v.isUndefined()) cf.day else day;
        const iso = shared.islamicToIso(base.calendar, iy, im, id, overflow == .reject) orelse
            return throwRangeError(realm, "PlainDateTime date is out of range");
        var date = temporal.regulateISODate(iso.year, @intCast(iso.month), @intCast(iso.day), false) orelse
            return throwRangeError(realm, "PlainDateTime date is out of range");
        date.calendar = base.calendar;
        const time = try regulateTime(realm, hour, minute, second, millisecond, microsecond, nanosecond, overflow);
        return createTemporalDateTime(realm, PlainDateTimeRecord.combine(date, time));
    }

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
/// re-stamps the receiver with a supported calendar; ISO fields unchanged.
fn plainDateTimeWithCalendar(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    var rec = try requirePlainDateTime(realm, this_value);
    rec.calendar = try toTemporalCalendarIdentifier(realm, argOr(args, 0, Value.undefined_));
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
    // Islamic tabular calendars add the date part in Islamic terms.
    if (shared.isIslamicTabular(base.calendar)) {
        const rec = shared.addIslamicDateTime(base, dur, overflow == .reject) orelse
            return throwRangeError(realm, "PlainDateTime is out of range");
        return createTemporalDateTime(realm, rec);
    }
    var rec = temporal.addDateTime(base, dur, overflow == .reject) orelse
        return throwRangeError(realm, "PlainDateTime is out of range");
    // add/subtract preserve the receiver's calendar; unsupported calendars keep
    // the ISO fallback until their arithmetic lands.
    if (shared.calendarSupported(base.calendar)) rec.calendar = base.calendar;
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
    // §5.3.x — FormatDateTime via DateTimeFormat when CLDR is present; without
    // it (no `Intl`) fall back to the ISO string.
    if (@import("../../cldr.zig").available)
        return @import("../intl.zig").temporalToLocaleString(realm, this_value, args);
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
