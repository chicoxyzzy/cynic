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
    // Resolve the stored reference ISO date back into the calendar's month code
    // (iso8601 / gregorian-month calendars round-trip to the ISO month).
    return shared.monthCodeValue(realm, rec.calendar, rec.ref_iso_year, rec.iso_month, rec.iso_day);
}
fn plainMonthDayDay(realm: *Realm, t: Value, a: []const Value) NativeError!Value {
    _ = a;
    const rec = try requirePlainMonthDay(realm, t);
    return shared.dayValue(rec.calendar, rec.ref_iso_year, rec.iso_month, rec.iso_day);
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
    var year_present = !year_v.isUndefined();
    var year_val: i64 = if (year_present)
        try dateFieldToI64(realm, try toIntegerWithTruncation(realm, year_v))
    else
        1972;
    // era + eraYear resolve to the calendar year exactly as in the other
    // from-fields readers (a lone era or eraYear is a TypeError); the reads
    // happen only for calendars with an era system, so era-less calendars
    // add no observable property gets.
    var era_field: Value = Value.undefined_;
    var era_year_field: Value = Value.undefined_;
    if (shared.calendarHasEras(cal)) {
        era_field = try getPropertyChain(realm, obj, "era");
        era_year_field = try getPropertyChain(realm, obj, "eraYear");
    }
    const ey_res = try shared.resolveEraYear(realm, cal, era_field, era_year_field, year_present, if (year_present) year_val else 0, true);
    if (ey_res.present) {
        year_present = true;
        year_val = ey_res.val;
    }
    const year_for_overflow: i64 = year_val;

    const overflow = try getTemporalOverflowOption(realm, options);

    const max_month: i64 = shared.monthsInYearForCalendar(cal);
    var month: i64 = undefined;
    const has_code = mc_len != null;
    // §CalendarResolveFields: a numeric month is ambiguous for ANY non-ISO
    // calendar without a year (month ordinals shift with eras and leap
    // months) — TypeError, checked before the month/monthCode agreement
    // (error-ordering fixtures).
    if (!cal.isIso() and month_present and !year_present)
        return throwTypeError(realm, "a numeric month for this calendar requires a year");
    if (mc_len) |len| {
        month = try monthFromCodeBytes(realm, cal, &mc_buf, len, max_month);
        if (month_present and month_val != try shared.resolveMonthOrdinal(realm, cal, year_for_overflow, month, false))
            return throwRangeError(realm, "month and monthCode disagree");
    } else if (month_present) {
        month = month_val;
    } else {
        return throwTypeError(realm, "PlainMonthDay-like is missing 'month' / 'monthCode'");
    }
    // §12.2.x CalendarResolveFields — a non-ISO year whose ISO projection
    // cannot lie within the representable date range is a RangeError before
    // any month-info computation (every calendar-to-ISO epoch shift is
    // < 10^4, so ±300000 over-covers the ±275760 ISO limit). The ISO
    // calendar consults the year only for overflow regulation, so any
    // integer is fine there.
    if (year_present and !cal.isIso() and (year_val > 300000 or year_val < -300000))
        return throwRangeError(realm, "year is out of range");
    // Non-ISO calendars resolve a canonical reference ISO date for the
    // (calendar month, day) pair; gregorian-month calendars keep the ISO
    // month/day with the 1972 reference and just carry the calendar.
    if (shared.isComputedCalendar(cal)) {
        // A plain `month` integer is an ordinal IN THE GIVEN YEAR (the
        // leap-month calendars require a year alongside it), so it converts to
        // the year-independent CODE space through that year — ordinal 5 of a
        // chinese year whose leap month sits at 5 means "M04L", not "M05";
        // an ordinal past the year's month count constrains to the last
        // month (or rejects).
        const code_month: i64 = if (has_code)
            month
        else if (year_present) blk: {
            const miy = shared.monthsInCalendarYear(cal, year_for_overflow);
            var ord = month;
            if (ord > miy) {
                if (overflow == .reject) return throwRangeError(realm, "month is out of range for the year");
                ord = miy;
            }
            break :blk shared.monthOrdinalToCode(cal, year_for_overflow, @intCast(ord));
        } else month;
        // A given year sizes the day first (§: year and monthCode determine
        // whether the calendar date exists): Cheshvan 5781 has 29 days, so
        // day 30 constrains to 29 (or rejects) before the reference walk.
        var day_c = day;
        if (year_present) {
            const ord_in_year = try shared.resolveMonthOrdinal(realm, cal, year_for_overflow, code_month, overflow == .reject);
            const dim = shared.daysInCalendarMonth(cal, year_for_overflow, ord_in_year);
            if (day_c > dim) {
                if (overflow == .reject) return throwRangeError(realm, "day is out of range for the month");
                day_c = dim;
            }
        }
        const ref = shared.computedMonthDayRef(cal, code_month, day_c, overflow == .reject) orelse
            return throwRangeError(realm, "PlainMonthDay day is out of range for the calendar");
        return .{ .ref_iso_year = @intCast(ref.iso_year), .iso_month = @intCast(ref.iso_month), .iso_day = @intCast(ref.iso_day), .calendar = cal };
    }
    var rec = try regulateMonthDay(realm, year_for_overflow, month, day, overflow == .reject);
    rec.calendar = cal;
    return rec;
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
    // A full-date string with a non-ISO calendar annotation carries an ISO
    // date; its CALENDAR (month, day) re-anchors on the canonical reference
    // date ("2023-01-01[u-ca=hebrew]" is 8 Tevet -> M04-08).
    if (shared.isComputedCalendar(parsed.calendar)) {
        const cf = shared.calendarFields(parsed.calendar, parsed.ref_iso_year, parsed.iso_month, parsed.iso_day);
        const code = shared.monthOrdinalToCode(parsed.calendar, cf.year, cf.month);
        const ref = shared.computedMonthDayRef(parsed.calendar, code, cf.day, false) orelse
            return throwRangeError(realm, "PlainMonthDay day is out of range for the calendar");
        return .{ .ref_iso_year = @intCast(ref.iso_year), .iso_month = @intCast(ref.iso_month), .iso_day = @intCast(ref.iso_day), .calendar = parsed.calendar };
    }
    // §10.5.x — a non-computed (ISO / gregorian-family) month-day keeps the ISO
    // month/day against the 1972 leap reference, whatever year the string named.
    return .{ .ref_iso_year = 1972, .iso_month = parsed.iso_month, .iso_day = parsed.iso_day, .calendar = parsed.calendar };
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
    // §10.3.x — the reference ISO date (year included) AND the calendar
    // both participate ("2-07[u-ca=gregory]" != the iso8601 2-07).
    return Value.fromBool(compareISODate(a.date(), b.date()) == 0 and a.calendar.eql(&b.calendar));
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

    if (shared.isComputedCalendar(base.calendar)) {
        // Merge against the receiver's calendar fields and re-anchor via the
        // canonical reference-date walk (code space, year-independent).
        const cf = shared.calendarFields(base.calendar, base.ref_iso_year, base.iso_month, base.iso_day);
        var code_month: i64 = shared.monthOrdinalToCode(base.calendar, cf.year, cf.month);
        if (mc_len) |len| {
            code_month = try monthFromCodeBytes(realm, base.calendar, &mc_buf, len, 13);
        } else if (month_present) {
            // §12.2.x CalendarResolveFields — a numeric month is ambiguous
            // for a non-ISO calendar without a year (ordinals shift with
            // leap months): TypeError; with a year it converts through that
            // year to the year-independent code space.
            if (year_v.isUndefined())
                return throwTypeError(realm, "a numeric month for this calendar requires a year");
            code_month = shared.monthOrdinalToCode(base.calendar, year_for_overflow, @intCast(month_val));
        }
        const id: i64 = if (day_present) day_val else cf.day;
        const ref = shared.computedMonthDayRef(base.calendar, code_month, id, overflow == .reject) orelse
            return throwRangeError(realm, "PlainMonthDay day is out of range for the calendar");
        return createTemporalMonthDay(realm, .{ .ref_iso_year = @intCast(ref.iso_year), .iso_month = @intCast(ref.iso_month), .iso_day = @intCast(ref.iso_day), .calendar = base.calendar });
    }
    var month: i64 = base.iso_month;
    if (mc_len) |len| {
        month = try monthFromCodeBytes(realm, base.calendar, &mc_buf, len, 12);
        if (month_present and month_val != month) return throwRangeError(realm, "month and monthCode disagree");
    } else if (month_present) {
        // §CalendarMergeFields treats month/monthCode as one unit: a partial
        // month evicts the receiver's monthCode, and a bare numeric month
        // needs a year on every non-ISO calendar — TypeError.
        if (!base.calendar.isIso() and year_v.isUndefined())
            return throwTypeError(realm, "a numeric month for this calendar requires a year");
        month = month_val;
    }
    const day: i64 = if (day_present) day_val else base.iso_day;
    var rec = try regulateMonthDay(realm, year_for_overflow, month, day, overflow == .reject);
    rec.calendar = base.calendar;
    return createTemporalMonthDay(realm, rec);
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
    var year_present = !year_v.isUndefined();
    var year: i64 = if (year_present) try dateFieldToI64(realm, try toIntegerWithTruncation(realm, year_v)) else 0;
    // era / eraYear participate for era calendars exactly as in from(), so a
    // non-integral eraYear surfaces as the same RangeError.
    if (shared.calendarHasEras(md.calendar)) {
        const era_field = try getPropertyChain(realm, obj, "era");
        const era_year_field = try getPropertyChain(realm, obj, "eraYear");
        const ey = try shared.resolveEraYear(realm, md.calendar, era_field, era_year_field, year_present, year, false);
        year_present = ey.present;
        year = ey.val;
    }
    if (!year_present) return throwTypeError(realm, "argument is missing 'year'");
    // §10.3.x — the receiver holds a CALENDAR month-day; combine it with the
    // calendar year (constrain overflow) and convert to ISO.
    if (shared.isComputedCalendar(md.calendar)) {
        const cf = shared.calendarFields(md.calendar, md.ref_iso_year, md.iso_month, md.iso_day);
        const code = shared.monthOrdinalToCode(md.calendar, cf.year, cf.month);
        const ord = try shared.resolveMonthOrdinal(realm, md.calendar, year, code, false);
        const iso = shared.computedToIso(md.calendar, year, ord, cf.day, false) orelse
            return throwRangeError(realm, "PlainDate is out of range");
        var rec = temporal.regulateISODate(iso.year, @intCast(iso.month), @intCast(iso.day), false) orelse
            return throwRangeError(realm, "PlainDate is out of range");
        rec.calendar = md.calendar;
        return createTemporalDate(realm, rec);
    }
    const iso_year = shared.calendarYearToIso(md.calendar, year);
    var rec = temporal.regulateISODate(iso_year, md.iso_month, md.iso_day, false) orelse
        return throwRangeError(realm, "PlainDate is out of range");
    rec.calendar = md.calendar;
    return createTemporalDate(realm, rec);
}
