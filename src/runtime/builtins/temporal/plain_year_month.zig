//! Temporal.PlainYearMonth — ISO-calendar year+month value type:
//! constructor, prototype methods, statics, and the YM regulation helpers.

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

const PlainYearMonthRecord = temporal.PlainYearMonthRecord;
const PlainDateRecord = temporal.PlainDateRecord;
const TemporalRecord = temporal.TemporalRecord;

const shared = @import("shared.zig");
const duration_mod = @import("duration.zig");
const plain_date_mod = @import("plain_date.zig");

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
const getCalendarNameOption = shared.getCalendarNameOption;
const getOptionsObject = shared.getOptionsObject;
const getRoundingModeOption = shared.getRoundingModeOption;
const getRoundingIncrementOption = shared.getRoundingIncrementOption;
const getTemporalUnitOption = shared.getTemporalUnitOption;
const requireUnitInRange = shared.requireUnitInRange;
const negateRoundingMode = shared.negateRoundingMode;

const toTemporalDuration = duration_mod.toTemporalDuration;
const createTemporalDuration = duration_mod.createTemporalDuration;
const createTemporalDate = plain_date_mod.createTemporalDate;
const compareISODate = plain_date_mod.compareISODate;

pub fn install(realm: *Realm, ns: *JSObject) !void {
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

pub fn createTemporalYearMonth(realm: *Realm, rec: PlainYearMonthRecord) NativeError!Value {
    const inst = realm.heap.allocateObject() catch return error.OutOfMemory;
    realm.heap.setObjectPrototype(inst, realm.intrinsics.temporal_plain_year_month_prototype.?);
    try storePlainYearMonth(realm, inst, rec);
    return heap_mod.taggedObject(inst);
}

pub fn requirePlainYearMonth(realm: *Realm, this_value: Value) NativeError!PlainYearMonthRecord {
    const obj = heap_mod.valueAsPlainObject(this_value) orelse
        return throwTypeError(realm, "not a Temporal.PlainYearMonth");
    const rec = obj.getTemporalRecord() orelse
        return throwTypeError(realm, "not a Temporal.PlainYearMonth");
    return switch (rec.*) {
        .plain_year_month => |pym| pym,
        else => throwTypeError(realm, "not a Temporal.PlainYearMonth"),
    };
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
    const cal = try requireISOCalendar(realm, argOr(args, 2, Value.undefined_));
    const ref_v = argOr(args, 3, Value.undefined_);
    const ref: i64 = if (ref_v.isUndefined()) 1 else try dateFieldToI64(realm, try toIntegerWithTruncation(realm, ref_v));
    if (!temporal.isValidISODate(y, m, ref)) return throwRangeError(realm, "invalid reference ISO date");
    if (!temporal.isoYearMonthWithinLimits(y, m)) return throwRangeError(realm, "PlainYearMonth is out of range");
    try storePlainYearMonth(realm, inst, .{ .iso_year = @intCast(y), .iso_month = @intCast(m), .ref_iso_day = @intCast(ref), .calendar = cal });
    return heap_mod.taggedObject(inst);
}

fn plainYearMonthCalendarId(realm: *Realm, t: Value, a: []const Value) NativeError!Value {
    _ = a;
    const rec = try requirePlainYearMonth(realm, t);
    return shared.calendarIdToValue(realm, rec.calendar);
}
fn plainYearMonthYear(realm: *Realm, t: Value, a: []const Value) NativeError!Value {
    _ = a;
    const rec = try requirePlainYearMonth(realm, t);
    return shared.yearValue(rec.calendar, rec.iso_year, rec.iso_month, rec.ref_iso_day);
}
fn plainYearMonthMonth(realm: *Realm, t: Value, a: []const Value) NativeError!Value {
    _ = a;
    const rec = try requirePlainYearMonth(realm, t);
    return shared.monthValue(rec.calendar, rec.iso_year, rec.iso_month, rec.ref_iso_day);
}
fn plainYearMonthMonthCode(realm: *Realm, t: Value, a: []const Value) NativeError!Value {
    _ = a;
    const rec = try requirePlainYearMonth(realm, t);
    return shared.monthCodeValue(realm, rec.calendar, rec.iso_year, rec.iso_month, rec.ref_iso_day);
}
fn plainYearMonthDaysInMonth(realm: *Realm, t: Value, a: []const Value) NativeError!Value {
    _ = a;
    const rec = try requirePlainYearMonth(realm, t);
    return shared.daysInMonthValue(rec.calendar, rec.iso_year, rec.iso_month, rec.ref_iso_day);
}
fn plainYearMonthDaysInYear(realm: *Realm, t: Value, a: []const Value) NativeError!Value {
    _ = a;
    const rec = try requirePlainYearMonth(realm, t);
    return shared.daysInYearValue(rec.calendar, rec.iso_year, rec.iso_month, rec.ref_iso_day);
}
fn plainYearMonthMonthsInYear(realm: *Realm, t: Value, a: []const Value) NativeError!Value {
    _ = a;
    const rec = try requirePlainYearMonth(realm, t);
    return shared.monthsInYearValue(rec.calendar, rec.iso_year, rec.iso_month, rec.ref_iso_day);
}
fn plainYearMonthInLeapYear(realm: *Realm, t: Value, a: []const Value) NativeError!Value {
    _ = a;
    const rec = try requirePlainYearMonth(realm, t);
    return shared.inLeapYearValue(rec.calendar, rec.iso_year, rec.iso_month, rec.ref_iso_day);
}
fn plainYearMonthEra(realm: *Realm, t: Value, a: []const Value) NativeError!Value {
    _ = a;
    const rec = try requirePlainYearMonth(realm, t);
    return shared.eraValue(realm, rec.calendar, rec.iso_year, rec.iso_month, rec.ref_iso_day);
}
fn plainYearMonthEraYear(realm: *Realm, t: Value, a: []const Value) NativeError!Value {
    _ = a;
    const rec = try requirePlainYearMonth(realm, t);
    return shared.eraYearValue(rec.calendar, rec.iso_year, rec.iso_month, rec.ref_iso_day);
}

/// §9.5.x ISOYearMonthFromFields — read year and month/monthCode off a
/// property bag (alphabetical order: month, monthCode, year), regulate
/// per `options`. The reference day is fixed at 1; a `day` field is not
/// in the year-month field list and is never read. The monthCode format
/// RangeError is deferred until after the overflow option is read.
fn toYearMonthFields(realm: *Realm, obj: *JSObject, options: Value) NativeError!PlainYearMonthRecord {
    const cal = try requireCalendarFieldType(realm, try getPropertyChain(realm, obj, "calendar"));

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
    var year: i64 = if (year_present) try dateFieldToI64(realm, try toIntegerWithTruncation(realm, year_v)) else 0;
    if (shared.calendarHasEras(cal)) {
        const era_field = try getPropertyChain(realm, obj, "era");
        const era_year_field = try getPropertyChain(realm, obj, "eraYear");
        const ey_res = try shared.resolveEraYear(realm, cal, era_field, era_year_field, year_present, year, false);
        year_present = ey_res.present;
        year = ey_res.val;
    }
    if (!year_present) return throwTypeError(realm, "PlainYearMonth-like is missing 'year'");

    const overflow = try getTemporalOverflowOption(realm, options);

    const max_mo = shared.monthsInYearForCalendar(cal);
    var month: i64 = undefined;
    if (mc_len) |len| {
        month = try monthFromCodeBytes(realm, cal, &mc_buf, len, max_mo);
        month = try shared.resolveMonthOrdinal(realm, cal, year, month, overflow == .reject);
        if (month_present and month_val != month) return throwRangeError(realm, "month and monthCode disagree");
    } else if (month_present) {
        month = month_val;
    } else {
        return throwTypeError(realm, "PlainYearMonth-like is missing 'month' / 'monthCode'");
    }
    // Islamic tabular calendars convert the (year, month) pair to ISO; the
    // reference ISO day is the day the Islamic month-1 lands on (not 1).
    if (shared.isComputedCalendar(cal)) {
        const iso = shared.computedToIso(cal, year, month, 1, overflow == .reject) orelse
            return throwRangeError(realm, "PlainYearMonth is out of range");
        if (!temporal.isoYearMonthWithinLimits(iso.year, @intCast(iso.month)))
            return throwRangeError(realm, "PlainYearMonth is out of range");
        return .{ .iso_year = @intCast(iso.year), .iso_month = @intCast(iso.month), .ref_iso_day = @intCast(iso.day), .calendar = cal };
    }
    // Gregorian-month calendars: convert the year origin, keep ref day 1, and
    // preserve the requested calendar (previously discarded → always iso8601).
    const iso_year = shared.calendarYearToIso(cal, year);
    var rec = try regulateYearMonth(realm, iso_year, month, overflow == .reject);
    rec.calendar = cal;
    return rec;
}

/// §9.5.x ToTemporalYearMonth — a PlainYearMonth (copy), a property bag,
/// or an ISO year-month string. For the object and string paths the
/// reference day is reset to 1 (CalendarYearMonthFromFields), so only the
/// constructor's explicit 4th argument yields a non-1 reference day.
pub fn toTemporalYearMonth(realm: *Realm, item: Value, options: Value) NativeError!PlainYearMonthRecord {
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
    var year_present = !year_v.isUndefined();
    if (year_present) {
        year = try dateFieldToI64(realm, try toIntegerWithTruncation(realm, year_v));
        any = true;
    }
    if (shared.calendarHasEras(base.calendar)) {
        const era_field = try getPropertyChain(realm, obj, "era");
        const era_year_field = try getPropertyChain(realm, obj, "eraYear");
        const ey_res = try shared.resolveEraYear(realm, base.calendar, era_field, era_year_field, year_present, year, true);
        year = ey_res.val;
        if (ey_res.present and !year_present) any = true;
        year_present = ey_res.present;
    }
    if (!any) return throwTypeError(realm, "PlainYearMonth-like must have at least one recognized property");

    const overflow = try getTemporalOverflowOption(realm, argOr(args, 1, Value.undefined_));

    const max_mo = shared.monthsInYearForCalendar(base.calendar);
    var month: i64 = base.iso_month;
    if (shared.isComputedCalendar(base.calendar)) {
        const cf = shared.calendarFields(base.calendar, base.iso_year, base.iso_month, base.ref_iso_day);
        var im: i64 = cf.month;
        var im_is_code = false;
        if (mc_len) |len| {
            im = try monthFromCodeBytes(realm, base.calendar, &mc_buf, len, max_mo);
            im_is_code = true;
        } else if (month_present) {
            im = month_val;
        }
        const iy: i64 = if (!year_present) cf.year else year;
        if (im_is_code) {
            im = try shared.resolveMonthOrdinal(realm, base.calendar, iy, im, overflow == .reject);
            if (month_present and month_val != im) return throwRangeError(realm, "month and monthCode disagree");
        } else if (!month_present) {
            // The receiver's month follows its CODE into the new year (a
            // leap-only month rejects or constrains to Adar).
            im = try shared.resolveMonthOrdinal(realm, base.calendar, iy, shared.monthOrdinalToCode(base.calendar, cf.year, cf.month), overflow == .reject);
        }
        const iso = shared.computedToIso(base.calendar, iy, im, 1, overflow == .reject) orelse
            return throwRangeError(realm, "PlainYearMonth is out of range");
        if (!temporal.isoYearMonthWithinLimits(iso.year, @intCast(iso.month)))
            return throwRangeError(realm, "PlainYearMonth is out of range");
        return createTemporalYearMonth(realm, .{ .iso_year = @intCast(iso.year), .iso_month = @intCast(iso.month), .ref_iso_day = @intCast(iso.day), .calendar = base.calendar });
    }
    if (mc_len) |len| {
        month = try monthFromCodeBytes(realm, base.calendar, &mc_buf, len, max_mo);
        if (month_present and month_val != month) return throwRangeError(realm, "month and monthCode disagree");
    } else if (month_present) {
        month = month_val;
    }
    const iso_year = if (!year_present) year else shared.calendarYearToIso(base.calendar, year);
    var rec = try regulateYearMonth(realm, iso_year, month, overflow == .reject);
    rec.calendar = base.calendar;
    return createTemporalYearMonth(realm, rec);
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
    // Islamic tabular calendars add years + months in Islamic terms.
    if (shared.isComputedCalendar(base.calendar)) {
        const iso = shared.addComputed(
            base.calendar,
            base.iso_year,
            base.iso_month,
            base.ref_iso_day,
            @intFromFloat(dur.years),
            @intFromFloat(dur.months),
            0,
            0,
            overflow == .reject,
        ) orelse return throwRangeError(realm, "PlainYearMonth is out of range");
        if (!temporal.isoYearMonthWithinLimits(iso.year, @intCast(iso.month)))
            return throwRangeError(realm, "PlainYearMonth is out of range");
        return createTemporalYearMonth(realm, .{ .iso_year = @intCast(iso.year), .iso_month = @intCast(iso.month), .ref_iso_day = @intCast(iso.day), .calendar = base.calendar });
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
    var rec = try regulateYearMonth(realm, bal.year, bal.month, overflow == .reject);
    rec.calendar = base.calendar;
    return createTemporalYearMonth(realm, rec);
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

    // AdjustDateDurationRecord(_, 0, 0) — a year-month difference has no
    // weeks or days. Islamic tabular calendars difference in Islamic
    // year-months (ISO months don't align with Islamic months).
    var diff = if (shared.isComputedCalendar(this_ym.calendar)) blk: {
        // Difference in the calendar's own year-months via the shared
        // code-preserving walk (hebrew years alternate 12/13 months, so a
        // flat year*monthsInYear index would miscount across leap years).
        const d1 = temporal.PlainDateRecord{ .iso_year = this_ym.iso_year, .iso_month = this_ym.iso_month, .iso_day = this_ym.ref_iso_day, .calendar = this_ym.calendar };
        const d2 = temporal.PlainDateRecord{ .iso_year = other_ym.iso_year, .iso_month = other_ym.iso_month, .iso_day = other_ym.ref_iso_day, .calendar = other_ym.calendar };
        var dd = shared.differenceComputedDate(this_ym.calendar, d1, d2, if (largest == .month) .month else .year);
        dd.weeks = 0;
        dd.days = 0;
        break :blk dd;
    } else blk: {
        var d = temporal.differenceISODate(this_anchor, other_anchor, largest);
        d.weeks = 0;
        d.days = 0;
        break :blk d;
    };

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
    // §9.3.x — FormatDateTime via DateTimeFormat when CLDR is present; without
    // it (no `Intl`) fall back to the ISO string.
    if (@import("../../cldr.zig").available)
        return @import("../intl.zig").temporalToLocaleString(realm, this_value, args);
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
    if (shared.isComputedCalendar(ym.calendar)) {
        const cf = shared.calendarFields(ym.calendar, ym.iso_year, ym.iso_month, ym.ref_iso_day);
        const iso = shared.computedToIso(ym.calendar, cf.year, cf.month, day, false) orelse
            return throwRangeError(realm, "PlainDate is out of range");
        var rec = temporal.regulateISODate(iso.year, @intCast(iso.month), @intCast(iso.day), false) orelse
            return throwRangeError(realm, "PlainDate is out of range");
        rec.calendar = ym.calendar;
        return createTemporalDate(realm, rec);
    }
    var rec = temporal.regulateISODate(ym.iso_year, ym.iso_month, day, false) orelse
        return throwRangeError(realm, "PlainDate is out of range");
    rec.calendar = ym.calendar; // preserve roc/buddhist/gregory
    return createTemporalDate(realm, rec);
}
