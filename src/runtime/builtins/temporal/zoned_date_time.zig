//! Temporal.ZonedDateTime — epoch-anchored, time-zone-aware date+time:
//! constructor, prototype methods, statics, plus the ZDT-only option
//! readers (disambiguation, offset, timeZoneName, …) and the conversions
//! between wall-clock fields and the epoch-ns + time-zone slot.

const std = @import("std");

const Realm = @import("../../realm.zig").Realm;
const Value = @import("../../value.zig").Value;
const JSString = @import("../../string.zig").JSString;
const JSObject = @import("../../object.zig").JSObject;
const NativeError = @import("../../function.zig").NativeError;
const heap_mod = @import("../../heap.zig");
const intrinsics = @import("../../intrinsics.zig");
const temporal = @import("../../temporal.zig");
const bigint_builtin = @import("../bigint.zig");

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

const ZonedDateTimeRecord = temporal.ZonedDateTimeRecord;
const PlainDateTimeRecord = temporal.PlainDateTimeRecord;
const PlainDateRecord = temporal.PlainDateRecord;
const PlainTimeRecord = temporal.PlainTimeRecord;
const TemporalRecord = temporal.TemporalRecord;

const shared = @import("shared.zig");
const duration_mod = @import("duration.zig");
const plain_time_mod = @import("plain_time.zig");
const plain_date_mod = @import("plain_date.zig");
const plain_date_time_mod = @import("plain_date_time.zig");
const instant_mod = @import("instant.zig");

const toIntegerWithTruncation = shared.toIntegerWithTruncation;
const negZero = shared.negZero;
const dateFieldToI64 = shared.dateFieldToI64;
const readPositiveDateField = shared.readPositiveDateField;
const readMonthCodeField = shared.readMonthCodeField;
const monthFromCodeBytes = shared.monthFromCodeBytes;
const Overflow = shared.Overflow;
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
const getOffsetOption = shared.getOffsetOption;
const getTimeZoneNameOption = shared.getTimeZoneNameOption;
const getShowOffsetOption = shared.getShowOffsetOption;
const getFractionalSecondDigitsOption = shared.getFractionalSecondDigitsOption;
const toSecondsStringPrecision = shared.toSecondsStringPrecision;
const requireToStringSmallestUnit = shared.requireToStringSmallestUnit;
const timeZoneEquals = shared.timeZoneEquals;
const toTimeZoneArg = shared.toTimeZoneArg;

const toTemporalDuration = duration_mod.toTemporalDuration;
const createTemporalDuration = duration_mod.createTemporalDuration;
const toTemporalTime = plain_time_mod.toTemporalTime;
const createTemporalTime = plain_time_mod.createTemporalTime;
const createTemporalDate = plain_date_mod.createTemporalDate;
const createTemporalDateTime = plain_date_time_mod.createTemporalDateTime;
const resolveDateTimeFields = plain_date_time_mod.resolveDateTimeFields;
const readDateTimeFieldsRaw = plain_date_time_mod.readDateTimeFieldsRaw;
const ZonedFieldExtras = plain_date_time_mod.ZonedFieldExtras;
const createTemporalInstant = instant_mod.createTemporalInstant;
const epochNsFromBigInt = instant_mod.epochNsFromBigInt;
const differenceDividend = instant_mod.differenceDividend;

pub fn install(realm: *Realm, ns: *JSObject) !void {
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
    // §6.1.1 step 5 — ParseTimeZoneIdentifier, NOT the broad
    // ParseTemporalTimeZoneString: the constructor accepts only a bare
    // identifier ("UTC", "±HH:MM"), so a full ISO date-time string is a
    // RangeError (timezone-iso-string.js).
    const tz = temporal.parseTimeZoneIdentifier(tz_str.flatBytes()) orelse
        return throwRangeError(realm, "invalid time zone identifier");
    // step 7-9 — calendar defaults to iso8601; supported calendars accepted structurally.
    const cal = try requireISOCalendar(realm, argOr(args, 2, Value.undefined_));
    try storeZonedDateTime(realm, inst, .{ .epoch_ns = epoch_ns, .time_zone = tz, .calendar = cal });
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
pub fn requireZonedDateTime(realm: *Realm, this_value: Value) NativeError!ZonedDateTimeRecord {
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
    const z = try requireZonedDateTime(realm, t);
    return shared.calendarIdToValue(realm, z.calendar);
}
fn zonedDateTimeTimeZoneId(realm: *Realm, t: Value, a: []const Value) NativeError!Value {
    _ = a;
    const z = try requireZonedDateTime(realm, t);
    var buf: [64]u8 = undefined;
    const s = temporal.timeZoneIdentifierString(z.time_zone, &buf);
    const js = realm.heap.allocateString(s) catch return error.OutOfMemory;
    return Value.fromString(js);
}
fn zonedDateTimeYear(realm: *Realm, t: Value, a: []const Value) NativeError!Value {
    _ = a;
    const z = try requireZonedDateTime(realm, t);
    const rec = temporal.getISODateTimeFor(z.time_zone, z.epoch_ns);
    return shared.yearValue(z.calendar, rec.iso_year, rec.iso_month, rec.iso_day);
}
fn zonedDateTimeMonth(realm: *Realm, t: Value, a: []const Value) NativeError!Value {
    _ = a;
    const z = try requireZonedDateTime(realm, t);
    const rec = temporal.getISODateTimeFor(z.time_zone, z.epoch_ns);
    return shared.monthValue(z.calendar, rec.iso_year, rec.iso_month, rec.iso_day);
}
fn zonedDateTimeMonthCode(realm: *Realm, t: Value, a: []const Value) NativeError!Value {
    _ = a;
    const z = try requireZonedDateTime(realm, t);
    const rec = temporal.getISODateTimeFor(z.time_zone, z.epoch_ns);
    return shared.monthCodeValue(realm, z.calendar, rec.iso_year, rec.iso_month, rec.iso_day);
}
fn zonedDateTimeDay(realm: *Realm, t: Value, a: []const Value) NativeError!Value {
    _ = a;
    const z = try requireZonedDateTime(realm, t);
    const rec = temporal.getISODateTimeFor(z.time_zone, z.epoch_ns);
    return shared.dayValue(z.calendar, rec.iso_year, rec.iso_month, rec.iso_day);
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
    const z = try requireZonedDateTime(realm, t);
    const rec = temporal.getISODateTimeFor(z.time_zone, z.epoch_ns);
    return shared.dayOfYearValue(z.calendar, rec.iso_year, rec.iso_month, rec.iso_day);
}
fn zonedDateTimeWeekOfYear(realm: *Realm, t: Value, a: []const Value) NativeError!Value {
    _ = a;
    const z = try requireZonedDateTime(realm, t);
    if (!shared.weekFieldsForCalendar(z.calendar)) return Value.undefined_;
    const rec = temporal.getISODateTimeFor(z.time_zone, z.epoch_ns);
    return Value.fromInt32(temporal.isoWeekOfYear(rec.iso_year, rec.iso_month, rec.iso_day).week);
}
fn zonedDateTimeYearOfWeek(realm: *Realm, t: Value, a: []const Value) NativeError!Value {
    _ = a;
    const z = try requireZonedDateTime(realm, t);
    if (!shared.weekFieldsForCalendar(z.calendar)) return Value.undefined_;
    const rec = temporal.getISODateTimeFor(z.time_zone, z.epoch_ns);
    return Value.fromInt32(temporal.isoWeekOfYear(rec.iso_year, rec.iso_month, rec.iso_day).year);
}
fn zonedDateTimeHoursInDay(realm: *Realm, t: Value, a: []const Value) NativeError!Value {
    _ = a;
    const z = try requireZonedDateTime(realm, t);
    // §6.3.4 get hoursInDay — GetStartOfDay for today and the next day. A
    // constant-offset zone yields exactly 24 h, but either start-of-day
    // boundary can leave the representable Instant range near the limits
    // (get-start-of-day-throws.js, next-day-out-of-range.js → RangeError).
    const diff_ns = temporal.zonedHoursInDay(z.epoch_ns, z.time_zone) orelse
        return throwRangeError(realm, "ZonedDateTime day boundary is out of range");
    const hours = @as(f64, @floatFromInt(diff_ns)) / 3_600_000_000_000.0;
    return Value.fromDouble(hours);
}
fn zonedDateTimeDaysInWeek(realm: *Realm, t: Value, a: []const Value) NativeError!Value {
    _ = a;
    _ = try requireZonedDateTime(realm, t);
    return Value.fromInt32(7);
}
fn zonedDateTimeDaysInMonth(realm: *Realm, t: Value, a: []const Value) NativeError!Value {
    _ = a;
    const z = try requireZonedDateTime(realm, t);
    const rec = temporal.getISODateTimeFor(z.time_zone, z.epoch_ns);
    return shared.daysInMonthValue(z.calendar, rec.iso_year, rec.iso_month, rec.iso_day);
}
fn zonedDateTimeDaysInYear(realm: *Realm, t: Value, a: []const Value) NativeError!Value {
    _ = a;
    const z = try requireZonedDateTime(realm, t);
    const rec = temporal.getISODateTimeFor(z.time_zone, z.epoch_ns);
    return shared.daysInYearValue(z.calendar, rec.iso_year, rec.iso_month, rec.iso_day);
}
fn zonedDateTimeMonthsInYear(realm: *Realm, t: Value, a: []const Value) NativeError!Value {
    _ = a;
    const z = try requireZonedDateTime(realm, t);
    const rec = temporal.getISODateTimeFor(z.time_zone, z.epoch_ns);
    return shared.monthsInYearValue(z.calendar, rec.iso_year, rec.iso_month, rec.iso_day);
}
fn zonedDateTimeInLeapYear(realm: *Realm, t: Value, a: []const Value) NativeError!Value {
    _ = a;
    const z = try requireZonedDateTime(realm, t);
    const rec = temporal.getISODateTimeFor(z.time_zone, z.epoch_ns);
    return shared.inLeapYearValue(z.calendar, rec.iso_year, rec.iso_month, rec.iso_day);
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
    const z = try requireZonedDateTime(realm, t);
    const rec = temporal.getISODateTimeFor(z.time_zone, z.epoch_ns);
    return shared.eraValue(realm, z.calendar, rec.iso_year, rec.iso_month, rec.iso_day);
}
fn zonedDateTimeEraYear(realm: *Realm, t: Value, a: []const Value) NativeError!Value {
    _ = a;
    const z = try requireZonedDateTime(realm, t);
    const rec = temporal.getISODateTimeFor(z.time_zone, z.epoch_ns);
    return shared.eraYearValue(z.calendar, rec.iso_year, rec.iso_month, rec.iso_day);
}

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
    return .{ .epoch_ns = epoch, .time_zone = extras.time_zone, .calendar = dt.calendar };
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
    return .{ .epoch_ns = epoch, .time_zone = parsed.time_zone, .calendar = parsed.date_time.calendar };
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
    var d = dt.date();
    if (shared.calendarSupported(z.calendar) or shared.isComputedCalendar(z.calendar)) d.calendar = z.calendar;
    return createTemporalDate(realm, d);
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
    var dt = temporal.getISODateTimeFor(z.time_zone, z.epoch_ns);
    if (shared.calendarSupported(z.calendar) or shared.isComputedCalendar(z.calendar)) dt.calendar = z.calendar;
    return createTemporalDateTime(realm, dt);
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
    var year_present = false;
    var month_int: i64 = base.iso_month;
    var month_int_set = false;
    var month_code_buf: [8]u8 = undefined;
    var month_code_len: ?usize = null;
    var day: i64 = base.iso_day;
    var day_present = false;
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
        day = try readPositiveDateField(realm, day_v);
        day_present = true;
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
        year_present = true;
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
    const month_given = month_code_len != null or month_int_set;
    if (month_code_len) |len| {
        month = try monthFromCodeBytes(realm, &month_code_buf, len);
        if (month_int_set and month_int != month) return throwRangeError(realm, "month and monthCode disagree");
    } else if (month_int_set) {
        month = month_int;
    }

    const new_date = if (shared.isComputedCalendar(z.calendar)) blk: {
        // Merge against the receiver's Islamic fields, then convert to ISO.
        const cf = shared.calendarFields(z.calendar, base.iso_year, base.iso_month, base.iso_day);
        const iy: i64 = if (year_present) year else cf.year;
        const im: i64 = if (month_given) month else cf.month;
        const id: i64 = if (day_present) day else cf.day;
        const iso = shared.computedToIso(z.calendar, iy, im, id, overflow == .reject) orelse
            return throwRangeError(realm, "ZonedDateTime date is out of range");
        break :blk temporal.regulateISODate(iso.year, @intCast(iso.month), @intCast(iso.day), false) orelse
            return throwRangeError(realm, "ZonedDateTime date is out of range");
    } else blk: {
        const iso_year = if (year_present) shared.calendarYearToIso(z.calendar, year) else year;
        break :blk temporal.regulateISODate(iso_year, month, day, overflow == .reject) orelse
            return throwRangeError(realm, "ZonedDateTime date is out of range");
    };
    const new_time = try regulateTime(realm, hour, minute, second, millisecond, microsecond, nanosecond, overflow);
    const wall = PlainDateTimeRecord.combine(new_date, new_time);
    const epoch = temporal.interpretISODateTimeOffset(wall, .option, offset_ns, z.time_zone, offset_opt) catch |e| switch (e) {
        error.OffsetMismatch => return throwRangeError(realm, "offset does not match the time zone"),
        error.Invalid => return throwRangeError(realm, "ZonedDateTime is out of range"),
    };
    return createTemporalZonedDateTime(realm, .{ .epoch_ns = epoch, .time_zone = z.time_zone, .calendar = z.calendar });
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
    return createTemporalZonedDateTime(realm, .{ .epoch_ns = epoch, .time_zone = z.time_zone, .calendar = z.calendar });
}

/// §6.3.x Temporal.ZonedDateTime.prototype.withTimeZone ( timeZoneLike ) —
/// same instant, different zone.
fn zonedDateTimeWithTimeZone(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const z = try requireZonedDateTime(realm, this_value);
    const tz = try toTimeZoneArg(realm, argOr(args, 0, Value.undefined_));
    return createTemporalZonedDateTime(realm, .{ .epoch_ns = z.epoch_ns, .time_zone = tz, .calendar = z.calendar });
}

/// §6.3.x Temporal.ZonedDateTime.prototype.withCalendar ( calendarLike ) —
/// re-stamps the receiver with a supported calendar; instant + zone unchanged.
fn zonedDateTimeWithCalendar(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    var z = try requireZonedDateTime(realm, this_value);
    z.calendar = try toTemporalCalendarIdentifier(realm, argOr(args, 0, Value.undefined_));
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
    const epoch = if (shared.isComputedCalendar(z.calendar))
        (shared.addComputedZoned(z.epoch_ns, z.time_zone, z.calendar, dur, overflow == .reject) orelse
            return throwRangeError(realm, "ZonedDateTime is out of range"))
    else
        (temporal.addZonedDateTime(z.epoch_ns, z.time_zone, dur, overflow == .reject) orelse
            return throwRangeError(realm, "ZonedDateTime is out of range"));
    return createTemporalZonedDateTime(realm, .{ .epoch_ns = epoch, .time_zone = z.time_zone, .calendar = z.calendar });
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
    // §7.5.x A ZonedDateTime "day" difference routes through
    // NudgeToCalendarUnit (a zoned day has zone-dependent length), which
    // materialises the ending-bound instant — AddDateTime(reference,
    // ±increment days) from the receiver — before the mode picks between the
    // floor/ceil candidates. For a fixed-offset zone that bound is the
    // receiver's epoch ± r2·24h; when it leaves the valid range the whole
    // operation is a RangeError, mode-independently. (Finer time smallestUnits
    // cap their increment, so only `day` can blow the bound out of range.)
    if (smallest == .day) {
        const inc: i128 = increment;
        const dsign: i128 = if (diff < 0) -1 else if (diff > 0) 1 else 0;
        const base: i128 = @divTrunc(@divTrunc(diff, temporal.ns_per_day), inc) * inc;
        const bound_epoch: i128 = z.epoch_ns + (base + inc * dsign) * temporal.ns_per_day;
        if (!temporal.isValidEpochNanoseconds(bound_epoch)) {
            return throwRangeError(realm, "ZonedDateTime difference ending bound is out of range");
        }
    }
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
    return createTemporalZonedDateTime(realm, .{ .epoch_ns = epoch, .time_zone = z.time_zone, .calendar = z.calendar });
}

/// §6.3.x Temporal.ZonedDateTime.prototype.startOfDay ( ) — the instant of
/// the first wall-clock moment (midnight) of the current calendar day.
fn zonedDateTimeStartOfDay(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    const z = try requireZonedDateTime(realm, this_value);
    const epoch = temporal.zonedStartOfDay(z.epoch_ns, z.time_zone) orelse
        return throwRangeError(realm, "ZonedDateTime is out of range");
    return createTemporalZonedDateTime(realm, .{ .epoch_ns = epoch, .time_zone = z.time_zone, .calendar = z.calendar });
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
