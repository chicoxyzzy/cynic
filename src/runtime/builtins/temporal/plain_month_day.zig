//! Temporal.PlainMonthDay — ISO-calendar month+day value type:
//! constructor, prototype methods, statics, and the MD regulation helpers.

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

const PlainMonthDayRecord = temporal.PlainMonthDayRecord;
const PlainDateRecord = temporal.PlainDateRecord;
const TemporalRecord = temporal.TemporalRecord;

const shared = @import("shared.zig");
const plain_date_mod = @import("plain_date.zig");

const toIntegerWithTruncation = shared.toIntegerWithTruncation;
const dateFieldToI64 = shared.dateFieldToI64;
const readPositiveDateField = shared.readPositiveDateField;
const readMonthCodeField = shared.readMonthCodeField;
const monthFromCodeBytes = shared.monthFromCodeBytes;
const Overflow = shared.Overflow;
const getTemporalOverflowOption = shared.getTemporalOverflowOption;
const rejectTemporalLikeObject = shared.rejectTemporalLikeObject;
const requireISOCalendar = shared.requireISOCalendar;
const requireCalendarFieldType = shared.requireCalendarFieldType;
const getCalendarNameOption = shared.getCalendarNameOption;
const getOptionsObject = shared.getOptionsObject;

const createTemporalDate = plain_date_mod.createTemporalDate;
const compareISODate = plain_date_mod.compareISODate;

pub fn install(realm: *Realm, ns: *JSObject) !void {
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

pub fn createTemporalMonthDay(realm: *Realm, rec: PlainMonthDayRecord) NativeError!Value {
    const inst = realm.heap.allocateObject() catch return error.OutOfMemory;
    realm.heap.setObjectPrototype(inst, realm.intrinsics.temporal_plain_month_day_prototype.?);
    try storePlainMonthDay(realm, inst, rec);
    return heap_mod.taggedObject(inst);
}

pub fn requirePlainMonthDay(realm: *Realm, this_value: Value) NativeError!PlainMonthDayRecord {
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
    const cal = try requireISOCalendar(realm, argOr(args, 2, Value.undefined_));
    const ref_v = argOr(args, 3, Value.undefined_);
    const ref: i64 = if (ref_v.isUndefined()) 1972 else try dateFieldToI64(realm, try toIntegerWithTruncation(realm, ref_v));
    if (!temporal.isValidISODate(ref, m, d)) return throwRangeError(realm, "invalid month-day");
    if (!temporal.isoDateWithinLimits(ref, @intCast(m), @intCast(d))) return throwRangeError(realm, "PlainMonthDay is out of range");
    try storePlainMonthDay(realm, inst, .{ .ref_iso_year = @intCast(ref), .iso_month = @intCast(m), .iso_day = @intCast(d), .calendar = cal });
    return heap_mod.taggedObject(inst);
}

fn plainMonthDayCalendarId(realm: *Realm, t: Value, a: []const Value) NativeError!Value {
    _ = a;
    const rec = try requirePlainMonthDay(realm, t);
    return shared.calendarIdToValue(realm, rec.calendar);
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
    const cal = try requireCalendarFieldType(realm, try getPropertyChain(realm, obj, "calendar"));
    _ = cal;

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
pub fn toTemporalMonthDay(realm: *Realm, item: Value, options: Value) NativeError!PlainMonthDayRecord {
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
    // §10.3.x — FormatDateTime via DateTimeFormat when CLDR is present; without
    // it (no `Intl`) fall back to the ISO string.
    if (@import("../../cldr.zig").available)
        return @import("../intl.zig").temporalToLocaleString(realm, this_value, args);
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
