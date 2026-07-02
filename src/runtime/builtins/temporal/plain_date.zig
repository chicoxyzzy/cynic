//! Temporal.PlainDate — ISO-calendar wall-clock date constructor, prototype
//! methods, statics, and the field / property-bag reading helpers.

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

const PlainDateRecord = temporal.PlainDateRecord;
const PlainDateTimeRecord = temporal.PlainDateTimeRecord;
const PlainTimeRecord = temporal.PlainTimeRecord;
const TemporalRecord = temporal.TemporalRecord;

const shared = @import("shared.zig");
const duration_mod = @import("duration.zig");
const plain_time_mod = @import("plain_time.zig");
const plain_date_time_mod = @import("plain_date_time.zig");
const plain_year_month_mod = @import("plain_year_month.zig");
const plain_month_day_mod = @import("plain_month_day.zig");
const zoned_date_time_mod = @import("zoned_date_time.zig");

const toIntegerWithTruncation = shared.toIntegerWithTruncation;
const negZero = shared.negZero;
const dateFieldToI64 = shared.dateFieldToI64;
const readPositiveDateField = shared.readPositiveDateField;
const readMonthCodeField = shared.readMonthCodeField;
const monthFromCodeBytes = shared.monthFromCodeBytes;
const Overflow = shared.Overflow;
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
const toTimeZoneArg = shared.toTimeZoneArg;

const toTemporalDuration = duration_mod.toTemporalDuration;
const createTemporalDuration = duration_mod.createTemporalDuration;
const toTemporalTime = plain_time_mod.toTemporalTime;
const createTemporalDateTime = plain_date_time_mod.createTemporalDateTime;
const createTemporalYearMonth = plain_year_month_mod.createTemporalYearMonth;
const createTemporalMonthDay = plain_month_day_mod.createTemporalMonthDay;
const createTemporalZonedDateTime = zoned_date_time_mod.createTemporalZonedDateTime;

pub fn install(realm: *Realm, ns: *JSObject) !void {
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
    // §3.3.20 toPlainDateTime ( [ temporalTime ] ) — the sole
    // parameter is optional, so the function .length is 0.
    try installNativeMethodOnProto(realm, proto, "toPlainDateTime", plainDateToPlainDateTime, 0);
    try installNativeMethodOnProto(realm, proto, "toZonedDateTime", plainDateToZonedDateTime, 1);

    try installNativeMethod(realm, fn_obj, "from", plainDateFrom, 1);
    try installNativeMethod(realm, fn_obj, "compare", plainDateCompare, 2);

    realm.intrinsics.temporal_plain_date_constructor = fn_obj;
    realm.intrinsics.temporal_plain_date_prototype = proto;
    try setNonEnumerable(ns, realm.allocator, "PlainDate", heap_mod.taggedFunction(fn_obj));
}

fn storePlainDate(realm: *Realm, inst: *JSObject, rec: PlainDateRecord) NativeError!void {
    const r = realm.allocator.create(TemporalRecord) catch return error.OutOfMemory;
    r.* = .{ .plain_date = rec };
    inst.setTemporalRecord(realm.allocator, r) catch return error.OutOfMemory;
}

pub fn createTemporalDate(realm: *Realm, rec: PlainDateRecord) NativeError!Value {
    const inst = realm.heap.allocateObject() catch return error.OutOfMemory;
    realm.heap.setObjectPrototype(inst, realm.intrinsics.temporal_plain_date_prototype.?);
    try storePlainDate(realm, inst, rec);
    return heap_mod.taggedObject(inst);
}

pub fn requirePlainDate(realm: *Realm, this_value: Value) NativeError!PlainDateRecord {
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
    const cal = try requireISOCalendar(realm, argOr(args, 3, Value.undefined_));
    var rec = temporal.regulateISODate(y, m, d, true) orelse
        return throwRangeError(realm, "PlainDate is out of range");
    rec.calendar = cal;
    try storePlainDate(realm, inst, rec);
    return heap_mod.taggedObject(inst);
}

fn plainDateCalendarId(realm: *Realm, t: Value, a: []const Value) NativeError!Value {
    _ = a;
    const rec = try requirePlainDate(realm, t);
    return shared.calendarIdToValue(realm, rec.calendar);
}
fn plainDateYear(realm: *Realm, t: Value, a: []const Value) NativeError!Value {
    _ = a;
    const rec = try requirePlainDate(realm, t);
    return shared.yearValue(rec.calendar, rec.iso_year, rec.iso_month, rec.iso_day);
}
fn plainDateMonth(realm: *Realm, t: Value, a: []const Value) NativeError!Value {
    _ = a;
    const rec = try requirePlainDate(realm, t);
    return shared.monthValue(rec.calendar, rec.iso_year, rec.iso_month, rec.iso_day);
}
fn plainDateDay(realm: *Realm, t: Value, a: []const Value) NativeError!Value {
    _ = a;
    const rec = try requirePlainDate(realm, t);
    return shared.dayValue(rec.calendar, rec.iso_year, rec.iso_month, rec.iso_day);
}
fn plainDateMonthCode(realm: *Realm, t: Value, a: []const Value) NativeError!Value {
    _ = a;
    const rec = try requirePlainDate(realm, t);
    return shared.monthCodeValue(realm, rec.calendar, rec.iso_year, rec.iso_month, rec.iso_day);
}
fn plainDateDayOfWeek(realm: *Realm, t: Value, a: []const Value) NativeError!Value {
    _ = a;
    const rec = try requirePlainDate(realm, t);
    return Value.fromInt32(temporal.isoDayOfWeek(rec.iso_year, rec.iso_month, rec.iso_day));
}
fn plainDateDayOfYear(realm: *Realm, t: Value, a: []const Value) NativeError!Value {
    _ = a;
    const rec = try requirePlainDate(realm, t);
    return shared.dayOfYearValue(rec.calendar, rec.iso_year, rec.iso_month, rec.iso_day);
}
fn plainDateWeekOfYear(realm: *Realm, t: Value, a: []const Value) NativeError!Value {
    _ = a;
    const rec = try requirePlainDate(realm, t);
    if (!shared.weekFieldsForCalendar(rec.calendar)) return Value.undefined_;
    return Value.fromInt32(temporal.isoWeekOfYear(rec.iso_year, rec.iso_month, rec.iso_day).week);
}
fn plainDateYearOfWeek(realm: *Realm, t: Value, a: []const Value) NativeError!Value {
    _ = a;
    const rec = try requirePlainDate(realm, t);
    if (!shared.weekFieldsForCalendar(rec.calendar)) return Value.undefined_;
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
    return shared.daysInMonthValue(rec.calendar, rec.iso_year, rec.iso_month, rec.iso_day);
}
fn plainDateDaysInYear(realm: *Realm, t: Value, a: []const Value) NativeError!Value {
    _ = a;
    const rec = try requirePlainDate(realm, t);
    return shared.daysInYearValue(rec.calendar, rec.iso_year, rec.iso_month, rec.iso_day);
}
fn plainDateMonthsInYear(realm: *Realm, t: Value, a: []const Value) NativeError!Value {
    _ = a;
    const rec = try requirePlainDate(realm, t);
    return shared.monthsInYearValue(rec.calendar, rec.iso_year, rec.iso_month, rec.iso_day);
}
fn plainDateInLeapYear(realm: *Realm, t: Value, a: []const Value) NativeError!Value {
    _ = a;
    const rec = try requirePlainDate(realm, t);
    return shared.inLeapYearValue(rec.calendar, rec.iso_year, rec.iso_month, rec.iso_day);
}
fn plainDateEra(realm: *Realm, t: Value, a: []const Value) NativeError!Value {
    _ = a;
    const rec = try requirePlainDate(realm, t);
    return shared.eraValue(realm, rec.calendar, rec.iso_year, rec.iso_month, rec.iso_day);
}
fn plainDateEraYear(realm: *Realm, t: Value, a: []const Value) NativeError!Value {
    _ = a;
    const rec = try requirePlainDate(realm, t);
    return shared.eraYearValue(rec.calendar, rec.iso_year, rec.iso_month, rec.iso_day);
}

/// §3.5.x ISODateFromFields — read the date fields off a property bag and
/// regulate per `options`. §13.x PrepareCalendarFields reads the calendar
/// field first, then each remaining field in alphabetical order (day,
/// month, monthCode, year), coercing each immediately after its Get so an
/// earlier field's type error surfaces before a later field is read.
/// `month` / `day` use ToPositiveIntegerWithTruncation (a < 1 RangeError at
/// read time); `monthCode` validates only its grammar here. The overflow
/// option is read before any algorithmic validation; the monthCode ISO
/// suitability, the month / monthCode reconciliation, and the required-field
/// checks are all part of CalendarResolveFields, after the overflow read.
fn toISODateFields(realm: *Realm, obj: *JSObject, options: Value) NativeError!PlainDateRecord {
    const cal = try requireCalendarFieldType(realm, try getPropertyChain(realm, obj, "calendar"));

    const day_v = try getPropertyChain(realm, obj, "day");
    var day_present = false;
    var day_val: i64 = 0;
    if (!day_v.isUndefined()) {
        day_val = try readPositiveDateField(realm, day_v);
        day_present = true;
    }

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
    var year_present = false;
    var year_val: i64 = 0;
    if (!year_v.isUndefined()) {
        year_val = try dateFieldToI64(realm, try toIntegerWithTruncation(realm, year_v));
        year_present = true;
    }

    // era + eraYear resolve to the calendar year when `year` is absent (and must
    // agree when both are given). PrepareCalendarFields lists era / eraYear only
    // for calendars that use eras, so an era-less calendar never reads them.
    if (shared.calendarHasEras(cal)) {
        const era_field = try getPropertyChain(realm, obj, "era");
        const era_year_field = try getPropertyChain(realm, obj, "eraYear");
        const ey_res = try shared.resolveEraYear(realm, cal, era_field, era_year_field, year_present, year_val, false);
        year_present = ey_res.present;
        year_val = ey_res.val;
    }

    const overflow = try getTemporalOverflowOption(realm, options);

    if (!year_present) return throwTypeError(realm, "PlainDate-like is missing 'year'");
    if (!day_present) return throwTypeError(realm, "PlainDate-like is missing 'day'");
    const max_mo = shared.monthsInYearForCalendar(cal);
    var month: i64 = undefined;
    if (mc_len) |len| {
        month = try monthFromCodeBytes(realm, cal, &mc_buf, len, max_mo);
        month = try shared.resolveMonthOrdinal(realm, cal, year_val, month, overflow == .reject);
        if (month_present and month_val != month) return throwRangeError(realm, "month and monthCode disagree");
    } else if (month_present) {
        month = month_val;
    } else {
        return throwTypeError(realm, "PlainDate-like is missing 'month' / 'monthCode'");
    }
    // Islamic tabular calendars convert the (year, month, day) field triple
    // through the day count (the day clamps to the Islamic month length).
    if (shared.isComputedCalendar(cal)) {
        const iso = shared.computedToIso(cal, year_val, month, day_val, overflow == .reject) orelse
            return throwRangeError(realm, "PlainDate is out of range");
        var rec = temporal.regulateISODate(iso.year, @intCast(iso.month), @intCast(iso.day), false) orelse
            return throwRangeError(realm, "PlainDate is out of range");
        rec.calendar = cal;
        return rec;
    }
    // The `year` field is in the calendar's own era-independent numbering;
    // convert it to the ISO year the gregorian-month machinery expects.
    const iso_year = shared.calendarYearToIso(cal, year_val);
    var rec = temporal.regulateISODate(iso_year, month, day_val, overflow == .reject) orelse
        return throwRangeError(realm, "PlainDate is out of range");
    rec.calendar = cal;
    return rec;
}

/// §3.5.x ToTemporalDate — a PlainDate (copy), a property bag, or an
/// ISO date string.
pub fn toTemporalDate(realm: *Realm, item: Value, options: Value) NativeError!PlainDateRecord {
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

pub fn compareISODate(a: PlainDateRecord, b: PlainDateRecord) i32 {
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

    // §13.x PrepareCalendarFields ('partial') — read each field in
    // alphabetical order (day, month, monthCode, year), coercing each
    // immediately after its Get. At least one field must be present, and
    // that check precedes the overflow read; the monthCode ISO suitability
    // and the month / monthCode reconciliation follow it (CalendarDateFromFields).
    const day_v = try getPropertyChain(realm, obj, "day");
    var day_present = false;
    var day_val: i64 = 0;
    if (!day_v.isUndefined()) {
        day_val = try readPositiveDateField(realm, day_v);
        day_present = true;
    }

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
    var year_present = false;
    var year_val: i64 = 0;
    if (!year_v.isUndefined()) {
        year_val = try dateFieldToI64(realm, try toIntegerWithTruncation(realm, year_v));
        year_present = true;
    }

    // era + eraYear count as date fields (calendars with eras only) and resolve
    // to the calendar year.
    if (shared.calendarHasEras(base.calendar)) {
        const era_field = try getPropertyChain(realm, obj, "era");
        const era_year_field = try getPropertyChain(realm, obj, "eraYear");
        const ey_res = try shared.resolveEraYear(realm, base.calendar, era_field, era_year_field, year_present, year_val, true);
        year_present = ey_res.present;
        year_val = ey_res.val;
    }

    if (!day_present and !month_present and mc_len == null and !year_present)
        return throwTypeError(realm, "PlainDate-like must have at least one date property");

    const overflow = try getTemporalOverflowOption(realm, argOr(args, 1, Value.undefined_));

    const max_mo = shared.monthsInYearForCalendar(base.calendar);
    // Islamic tabular calendars: merge against the receiver's *Islamic* fields,
    // then convert the triple back to ISO (the day clamps to the month length).
    if (shared.isComputedCalendar(base.calendar)) {
        const cf = shared.calendarFields(base.calendar, base.iso_year, base.iso_month, base.iso_day);
        var im: i64 = cf.month;
        var im_is_code = false;
        if (mc_len) |len| {
            im = try monthFromCodeBytes(realm, base.calendar, &mc_buf, len, max_mo);
            im_is_code = true;
        } else if (month_present) {
            im = month_val;
        }
        const iy: i64 = if (year_present) year_val else cf.year;
        if (im_is_code) {
            im = try shared.resolveMonthOrdinal(realm, base.calendar, iy, im, overflow == .reject);
            if (month_present and month_val != im) return throwRangeError(realm, "month and monthCode disagree");
        } else if (!month_present) {
            // The receiver's month follows its CODE into the new year (a
            // leap-only month rejects or constrains to Adar).
            im = try shared.resolveMonthOrdinal(realm, base.calendar, iy, shared.monthOrdinalToCode(base.calendar, cf.year, cf.month), overflow == .reject);
        }
        const id: i64 = if (day_present) day_val else cf.day;
        const iso = shared.computedToIso(base.calendar, iy, im, id, overflow == .reject) orelse
            return throwRangeError(realm, "PlainDate is out of range");
        var rec = temporal.regulateISODate(iso.year, @intCast(iso.month), @intCast(iso.day), false) orelse
            return throwRangeError(realm, "PlainDate is out of range");
        rec.calendar = base.calendar;
        return createTemporalDate(realm, rec);
    }

    var month: i64 = base.iso_month;
    if (mc_len) |len| {
        month = try monthFromCodeBytes(realm, base.calendar, &mc_buf, len, max_mo);
        if (month_present and month_val != month) return throwRangeError(realm, "month and monthCode disagree");
    } else if (month_present) {
        month = month_val;
    }
    // `year` overrides are in the calendar's numbering; an absent year keeps
    // the receiver's ISO year. The result inherits the receiver's calendar.
    const iso_year = if (year_present) shared.calendarYearToIso(base.calendar, year_val) else base.iso_year;
    var rec = temporal.regulateISODate(
        iso_year,
        month,
        if (day_present) day_val else base.iso_day,
        overflow == .reject,
    ) orelse return throwRangeError(realm, "PlainDate is out of range");
    if (shared.calendarSupported(base.calendar)) rec.calendar = base.calendar;
    return createTemporalDate(realm, rec);
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
    // §3.3.x — FormatDateTime via DateTimeFormat when CLDR is present; without
    // it (no `Intl`) fall back to the ISO string.
    if (@import("../../cldr.zig").available)
        return @import("../intl.zig").temporalToLocaleString(realm, this_value, args);
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
    // Islamic tabular calendars add years + months in Islamic terms (ISO months
    // would land on the wrong Islamic month), then fold in weeks + days.
    if (shared.isComputedCalendar(base.calendar)) {
        const iso = shared.addComputed(
            base.calendar,
            base.iso_year,
            base.iso_month,
            base.iso_day,
            @intFromFloat(dur.years),
            @intFromFloat(dur.months),
            @intFromFloat(dur.weeks),
            @as(i64, @intFromFloat(dur.days)) + time_days,
            overflow == .reject,
        ) orelse return throwRangeError(realm, "PlainDate is out of range");
        var rec = temporal.regulateISODate(iso.year, @intCast(iso.month), @intCast(iso.day), false) orelse
            return throwRangeError(realm, "PlainDate is out of range");
        rec.calendar = base.calendar;
        return createTemporalDate(realm, rec);
    }
    var rec = temporal.addISODate(
        base,
        @intFromFloat(dur.years),
        @intFromFloat(dur.months),
        @intFromFloat(dur.weeks),
        @as(i64, @intFromFloat(dur.days)) + time_days,
        overflow == .reject,
    ) orelse return throwRangeError(realm, "PlainDate is out of range");
    // add/subtract preserve the receiver's calendar (roc + 6mo is still roc).
    // Unsupported calendars keep the ISO fallback until their arithmetic lands.
    if (shared.calendarSupported(base.calendar)) rec.calendar = base.calendar;
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

    var diff = if (shared.isComputedCalendar(this_date.calendar))
        shared.differenceComputedDate(this_date.calendar, this_date, other_date, largest)
    else
        temporal.differenceISODate(this_date, other_date, largest);

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
/// §3.3.x Temporal.PlainDate.prototype.withCalendar ( calendarLike ) —
/// re-stamps the receiver with a supported calendar id; ISO fields unchanged.
fn plainDateWithCalendar(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    var rec = try requirePlainDate(realm, this_value);
    rec.calendar = try toTemporalCalendarIdentifier(realm, argOr(args, 0, Value.undefined_));
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
    // Islamic tabular calendars: the reference ISO day is where the Islamic
    // year-month's day 1 lands, so the year-month round-trips its calendar.
    if (shared.isComputedCalendar(d.calendar)) {
        const cf = shared.calendarFields(d.calendar, d.iso_year, d.iso_month, d.iso_day);
        const iso = shared.computedToIso(d.calendar, cf.year, cf.month, 1, false) orelse
            return throwRangeError(realm, "PlainYearMonth is out of range");
        return createTemporalYearMonth(realm, .{
            .iso_year = @intCast(iso.year),
            .iso_month = @intCast(iso.month),
            .ref_iso_day = @intCast(iso.day),
            .calendar = d.calendar,
        });
    }
    return createTemporalYearMonth(realm, .{
        .iso_year = d.iso_year,
        .iso_month = d.iso_month,
        .ref_iso_day = 1,
        .calendar = d.calendar,
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
