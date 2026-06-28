//! Temporal — cross-type helpers (option getters, field readers, calendar
//! checks, time-zone helpers) shared by ≥ 2 of the per-type builtin files.

const std = @import("std");

const Realm = @import("../../realm.zig").Realm;
const Value = @import("../../value.zig").Value;
const JSString = @import("../../string.zig").JSString;
const JSObject = @import("../../object.zig").JSObject;
const NativeError = @import("../../function.zig").NativeError;
const heap_mod = @import("../../heap.zig");
const intrinsics = @import("../../intrinsics.zig");
const temporal = @import("../../temporal.zig");

pub const throwTypeError = intrinsics.throwTypeError;
pub const throwRangeError = intrinsics.throwRangeError;
pub const argOr = intrinsics.argOr;
pub const getPropertyChain = intrinsics.getPropertyChain;
pub const toNumber = intrinsics.toNumber;
pub const stringifyArg = intrinsics.stringifyArg;

pub const PlainTimeRecord = temporal.PlainTimeRecord;

/// Extract the f64 mathematical value from a Number `Value` (the
/// result of `toNumber`, which is either an Int32 or a Double).
pub fn numberToF64(v: Value) f64 {
    if (v.isInt32()) return @floatFromInt(v.asInt32());
    return v.asDouble();
}

/// Positional constructor parameter with a spec default of 0. ES
/// default-parameter semantics: a *missing* argument OR an explicit
/// `undefined` both trigger the `= 0` default — so `new Duration()`,
/// `new Duration(undefined)`, and the implicit tail all coerce to 0
/// rather than `ToNumber(undefined) = NaN`. (`years-undefined.js`
/// et al. assert this.)
pub fn argDefault0(args: []const Value, i: usize) Value {
    const v = argOr(args, i, Value.fromInt32(0));
    if (v.isUndefined()) return Value.fromInt32(0);
    return v;
}

/// §13.x ToIntegerWithTruncation — ToNumber, reject NaN/±∞, then
/// truncate toward zero. The truncation makes negative-zero and tiny
/// fractional inputs collapse to +0, matching the spec's MV → integer
/// projection.
pub fn toIntegerWithTruncation(realm: *Realm, v: Value) NativeError!f64 {
    const n = numberToF64(try toNumber(realm, v));
    if (std.math.isNan(n) or std.math.isInf(n)) return throwRangeError(realm, "value must be a finite integer");
    return std.math.trunc(n);
}

pub const Overflow = enum { constrain, reject };

/// §4.5.x RejectTime — throw RangeError on out-of-range time fields.
pub fn rejectTime(realm: *Realm, hour: f64, minute: f64, second: f64, millisecond: f64, microsecond: f64, nanosecond: f64) NativeError!PlainTimeRecord {
    if (!rangeOk(hour, 23) or !rangeOk(minute, 59) or !rangeOk(second, 59) or
        !rangeOk(millisecond, 999) or !rangeOk(microsecond, 999) or !rangeOk(nanosecond, 999))
        return throwRangeError(realm, "time field out of range");
    return PlainTimeRecord{
        .hour = @intFromFloat(hour),
        .minute = @intFromFloat(minute),
        .second = @intFromFloat(second),
        .millisecond = @intFromFloat(millisecond),
        .microsecond = @intFromFloat(microsecond),
        .nanosecond = @intFromFloat(nanosecond),
    };
}

/// §4.5.x RegulateTime — `constrain` clamps each field into its ISO
/// range; `reject` throws (delegates to `rejectTime`). Used by
/// `with` / `from` (object path) where the `overflow` option
/// applies.
pub fn regulateTime(realm: *Realm, hour: f64, minute: f64, second: f64, millisecond: f64, microsecond: f64, nanosecond: f64, overflow: Overflow) NativeError!PlainTimeRecord {
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
pub fn getTemporalOverflowOption(realm: *Realm, options: Value) NativeError!Overflow {
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

/// §13.x GetOptionsObject — the options object, or null when options is
/// undefined. A non-object, non-undefined value throws TypeError. A
/// callable options bag is tolerated as empty (property reads want a
/// plain object); function-valued options are a rare edge.
pub fn getOptionsObject(realm: *Realm, options: Value) NativeError!?*JSObject {
    if (options.isUndefined()) return null;
    if (heap_mod.valueAsPlainObject(options)) |o| return o;
    if (heap_mod.valueAsFunction(options) != null) return null;
    return throwTypeError(realm, "options must be an object or undefined");
}

/// §13.x GetRoundingModeOption.
pub fn getRoundingModeOption(realm: *Realm, opts: ?*JSObject, default_mode: temporal.RoundingMode) NativeError!temporal.RoundingMode {
    const obj = opts orelse return default_mode;
    const v = try getPropertyChain(realm, obj, "roundingMode");
    if (v.isUndefined()) return default_mode;
    const s = try stringifyArg(realm, v);
    return temporal.parseRoundingMode(s.flatBytes()) orelse
        throwRangeError(realm, "invalid roundingMode");
}

/// §13.x GetRoundingIncrementOption — ToNumber, reject non-finite,
/// truncate, then require an integer in [1, 1e9].
pub fn getRoundingIncrementOption(realm: *Realm, opts: ?*JSObject) NativeError!i128 {
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
pub fn getTemporalUnitOption(realm: *Realm, opts: ?*JSObject, key: []const u8) NativeError!?temporal.LargestUnit {
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
pub fn requireUnitInRange(realm: *Realm, unit: temporal.LargestUnit, largest_allowed: temporal.LargestUnit, smallest_allowed: temporal.LargestUnit) NativeError!void {
    if (@intFromEnum(unit) < @intFromEnum(largest_allowed) or @intFromEnum(unit) > @intFromEnum(smallest_allowed)) {
        return throwRangeError(realm, "unit is outside the allowed range");
    }
}

/// §13.x NegateRoundingMode — lets `since` round in the reverse
/// direction of `until`. Only the directed ceil/floor pair flips; the
/// sign-symmetric modes are unchanged.
pub fn negateRoundingMode(mode: temporal.RoundingMode) temporal.RoundingMode {
    return switch (mode) {
        .ceil => .floor,
        .floor => .ceil,
        .half_ceil => .half_floor,
        .half_floor => .half_ceil,
        else => mode,
    };
}

/// Negate but keep -0 → +0 (the spec's negated duration normalises
/// signed zero: `new Temporal.Duration(0).negated()` has +0 years).
pub fn negZero(v: f64) f64 {
    if (v == 0) return 0;
    return -v;
}

/// Coerce a truncated date field to i64, rejecting values far outside
/// the representable range (which also guards the later i32 cast).
pub fn dateFieldToI64(realm: *Realm, v: f64) NativeError!i64 {
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
pub fn readPositiveDateField(realm: *Realm, v: Value) NativeError!i64 {
    const n = try dateFieldToI64(realm, try toIntegerWithTruncation(realm, v));
    if (n < 1) return throwRangeError(realm, "month and day fields must be positive integers");
    return n;
}

/// §13.x ReadMonthCodeField — read + well-formedness-check a property-bag
/// `monthCode`. A non-string (or a coercible object whose ToPrimitive yields
/// a non-string) is a TypeError *before* any format validation. The code's
/// *well-formedness* (the `MonthCode :::` grammar — `M`, two ASCII digits,
/// an optional `L` leap marker) is validated HERE, while the field is read,
/// so an ill-formed code is a RangeError before any later field (e.g.
/// `year`) is coerced — the `monthcode-invalid.js` fixtures pin "syntax is
/// validated before year type is validated". The code's *suitability* for
/// the ISO calendar (month in 1..12, no leap month) is a separate
/// RangeError deferred to `monthFromCodeBytes` so it lands after the year
/// coercion and the overflow option are read. The string's bytes are
/// copied into `buf` (truncated to its capacity); any code longer than the
/// 4-byte grammar is caught by the length check before indexing. Returns
/// the field's true byte length, or null when it is absent.
pub fn readMonthCodeField(realm: *Realm, v: Value, buf: []u8) NativeError!?usize {
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
pub fn monthFromCodeBytes(realm: *Realm, buf: []const u8, actual_len: usize) NativeError!i64 {
    if (actual_len == 4) return throwRangeError(realm, "invalid monthCode"); // ISO has no leap month
    const m: i64 = @as(i64, buf[1] - '0') * 10 + @as(i64, buf[2] - '0');
    if (m < 1 or m > 12) return throwRangeError(realm, "invalid monthCode");
    return m;
}

/// Reject a property-bag carrying a `calendar` or `timeZone` key — used by
/// `Type.prototype.with` to forbid silently changing either, since `with`
/// only updates the fields it documents (calendar / time zone get their
/// own setters).
pub fn rejectTemporalLikeObject(realm: *Realm, obj: *JSObject) NativeError!void {
    if (obj.getTemporalRecord() != null) {
        return throwTypeError(realm, "with() argument must be a plain options bag, not a Temporal value");
    }
    const cal = try getPropertyChain(realm, obj, "calendar");
    if (!cal.isUndefined()) {
        return throwTypeError(realm, "with() argument must not carry a calendar field");
    }
    const tz = try getPropertyChain(realm, obj, "timeZone");
    if (!tz.isUndefined()) {
        return throwTypeError(realm, "with() argument must not carry a timeZone field");
    }
}

const intl_config = @import("../../intl_config.zig");

/// §3.1.1 / constructor calendar arg — accept undefined (⇒ ISO) or a
/// calendar string. With `-Dintl=off` only ASCII `iso8601` is accepted
/// (ROADMAP shipped Temporal scope). With `stub`/`full`, any supported
/// calendar id is stored structurally (arithmetic stays ISO).
pub fn requireISOCalendar(realm: *Realm, calendar: Value) NativeError!temporal.CalendarId {
    if (calendar.isUndefined()) return temporal.CalendarId.iso8601();
    if (!calendar.isString()) return throwTypeError(realm, "calendar must be a string");
    const s: *JSString = @ptrCast(@alignCast(calendar.asString()));
    const bytes = s.flatBytes();
    if (!intl_config.temporal_intl_extras) {
        if (!std.ascii.eqlIgnoreCase(bytes, "iso8601")) {
            return throwRangeError(realm, "only the iso8601 calendar is supported");
        }
        return temporal.CalendarId.iso8601();
    }
    return temporal.calendarIdFromString(bytes) orelse
        return throwRangeError(realm, "unsupported calendar identifier");
}

/// Like `requireISOCalendar` but only validates (legacy void callers that
/// ignore the returned id — prefer the returning form when storing).
pub fn requireISOCalendarVoid(realm: *Realm, calendar: Value) NativeError!void {
    _ = try requireISOCalendar(realm, calendar);
}

/// ToTemporalCalendarIdentifier for the `calendar` field of a Temporal
/// date-like property bag (§12.2.x). `undefined` keeps the ISO default.
/// Returns the resolved calendar id for storage on the receiver.
pub fn requireCalendarFieldType(realm: *Realm, calendar: Value) NativeError!temporal.CalendarId {
    if (calendar.isUndefined()) return temporal.CalendarId.iso8601();
    return toTemporalCalendarIdentifier(realm, calendar);
}

/// Void wrapper for call sites that only validate (no store).
pub fn requireCalendarFieldTypeVoid(realm: *Realm, calendar: Value) NativeError!void {
    _ = try requireCalendarFieldType(realm, calendar);
}

/// §13.x ToTemporalCalendarIdentifier — returns the canonical calendar id.
/// An object carrying a calendar-bearing Temporal internal slot contributes
/// its `[[Calendar]]`; a string is a bare id or a parseable ISO 8601 temporal
/// string. With `-Dintl=off` only `iso8601` (bare or annotated) is accepted.
pub fn toTemporalCalendarIdentifier(realm: *Realm, calendar: Value) NativeError!temporal.CalendarId {
    if (heap_mod.valueAsPlainObject(calendar)) |obj| {
        if (obj.getTemporalRecord()) |rec| switch (rec.*) {
            .plain_date => |pd| return pd.calendar,
            .plain_date_time => |pdt| return pdt.calendar,
            .plain_year_month => |pym| return pym.calendar,
            .plain_month_day => |pmd| return pmd.calendar,
            .zoned_date_time => |z| return z.calendar,
            else => {},
        };
        return throwTypeError(realm, "calendar must be a string or a calendar-bearing Temporal object");
    }
    if (!calendar.isString()) return throwTypeError(realm, "calendar must be a string");
    const s: *JSString = @ptrCast(@alignCast(calendar.asString()));
    const bytes = s.flatBytes();
    if (!intl_config.temporal_intl_extras) {
        if (std.ascii.eqlIgnoreCase(bytes, "iso8601")) return temporal.CalendarId.iso8601();
        if (calendarStringIsSupported(bytes)) |c| {
            if (c.isIso()) return c;
        }
        return throwRangeError(realm, "invalid calendar identifier");
    }
    if (temporal.calendarIdFromString(bytes)) |c| return c;
    // Full ISO 8601 temporal string — any parser success implies the
    // embedded calendar (default ISO) is supported.
    if (calendarStringIsSupported(bytes)) |c| return c;
    return throwRangeError(realm, "invalid calendar identifier");
}

/// True when `bytes` parses as any ISO 8601 Temporal string whose calendar
/// annotation (defaulting to ISO) is supported. Returns that calendar.
pub fn calendarStringIsSupported(bytes: []const u8) ?temporal.CalendarId {
    if (temporal.parseTemporalDateTimeString(bytes)) |r| return r.calendar else |_| {}
    if (temporal.parseTemporalDateString(bytes)) |r| return r.calendar else |_| {}
    if (temporal.parseTemporalYearMonthString(bytes)) |r| return r.calendar else |_| {}
    if (temporal.parseTemporalMonthDayString(bytes)) |r| return r.calendar else |_| {}
    if (temporal.parseTemporalTimeString(bytes)) |_| return temporal.CalendarId.iso8601() else |_| {}
    if (temporal.parseInstantString(bytes)) |_| return temporal.CalendarId.iso8601() else |_| {}
    return null;
}

/// Legacy name — accepts any supported calendar string, not only ISO.
pub fn calendarStringIsISO(bytes: []const u8) bool {
    return calendarStringIsSupported(bytes) != null;
}

/// Allocate a JS string for a stored calendar id (calendarId getters).
pub fn calendarIdToValue(realm: *Realm, cal: temporal.CalendarId) NativeError!Value {
    const js = realm.heap.allocateString(cal.slice()) catch return error.OutOfMemory;
    return Value.fromString(js);
}

/// Era code for the gregorian-month calendars (gregory / roc / buddhist), or
/// null when the calendar has no era model yet. These three share the
/// gregorian month/day structure; only the year origin and era differ.
fn eraCode(cal: temporal.CalendarId, iso_year: i32) ?[]const u8 {
    if (std.ascii.eqlIgnoreCase(cal.slice(), "gregory")) return if (iso_year < 1) "bce" else "ce";
    if (std.ascii.eqlIgnoreCase(cal.slice(), "roc")) return if (iso_year - 1911 < 1) "broc" else "roc";
    if (std.ascii.eqlIgnoreCase(cal.slice(), "buddhist")) return "be";
    return null;
}

/// Era / eraYear / year helpers. The gregorian-month calendars (gregory, roc,
/// buddhist) are modelled; other non-ISO calendars still return undefined
/// (their arithmetic is not implemented yet).
pub fn eraForCalendar(realm: *Realm, cal: temporal.CalendarId, iso_year: i32) NativeError!Value {
    if (cal.isIso()) return Value.undefined_;
    const era = eraCode(cal, iso_year) orelse return Value.undefined_;
    const js = realm.heap.allocateString(era) catch return error.OutOfMemory;
    return Value.fromString(js);
}

pub fn eraYearForCalendar(cal: temporal.CalendarId, iso_year: i32) Value {
    if (cal.isIso()) return Value.undefined_;
    if (std.ascii.eqlIgnoreCase(cal.slice(), "gregory")) return Value.fromInt32(if (iso_year < 1) 1 - iso_year else iso_year);
    if (std.ascii.eqlIgnoreCase(cal.slice(), "roc")) {
        const y = iso_year - 1911;
        return Value.fromInt32(if (y < 1) 1 - y else y);
    }
    if (std.ascii.eqlIgnoreCase(cal.slice(), "buddhist")) return Value.fromInt32(iso_year + 543);
    return Value.undefined_;
}

/// The signed, era-independent calendar year for `iso_year` — for the
/// gregorian-month calendars this is just the year-origin shift.
pub fn calendarYear(cal: temporal.CalendarId, iso_year: i32) i32 {
    if (std.ascii.eqlIgnoreCase(cal.slice(), "roc")) return iso_year - 1911;
    if (std.ascii.eqlIgnoreCase(cal.slice(), "buddhist")) return iso_year + 543;
    return iso_year; // iso8601 / gregory share the ISO year
}

/// Inverse of calendarYear — the ISO year for a calendar `year` field, used by
/// the from-fields / with paths to convert a property bag's calendar year back
/// to the ISO year the rest of the date machinery operates on.
pub fn calendarYearToIso(cal: temporal.CalendarId, cal_year: i64) i64 {
    if (std.ascii.eqlIgnoreCase(cal.slice(), "roc")) return cal_year + 1911;
    if (std.ascii.eqlIgnoreCase(cal.slice(), "buddhist")) return cal_year - 543;
    return cal_year;
}

/// Whether Cynic models this calendar's arithmetic (year origin + era). Only
/// the gregorian-month calendars are implemented; operations on any other
/// non-ISO calendar fall back to the ISO behaviour until its arithmetic lands,
/// so a half-modelled calendar can't surface inconsistent year/era/month.
pub fn calendarSupported(cal: temporal.CalendarId) bool {
    if (cal.isIso()) return true;
    const s = cal.slice();
    return std.ascii.eqlIgnoreCase(s, "gregory") or std.ascii.eqlIgnoreCase(s, "roc") or std.ascii.eqlIgnoreCase(s, "buddhist");
}

// ── Islamic tabular calendars (islamic-civil + islamic-tbla) ─────────────────
// Both use the standard arithmetic ("tabular") algorithm and differ only in the
// epoch — islamic-civil starts Friday 622-07-16 (Julian), islamic-tbla one day
// earlier (Thursday). Epochs are expressed in days-since-1970-01-01
// (temporal.daysFromCivil space), calibrated against V8 / JSC / SpiderMonkey:
// islamic-civil 1445-06-19 = ISO 2024-01-01, islamic-tbla 1445-06-20 = ISO
// 2024-01-01 (verified 1420 / 1445 / 1446). Algorithm: Reingold & Dershowitz,
// *Calendrical Calculations* (fixed-from-islamic / islamic-from-fixed).

/// Epoch (days-since-1970) for the supported Islamic tabular calendars, or null
/// for any other calendar. islamic-umalqura / islamic-rgsa / bare islamic are
/// data/sighting-based and not modelled here.
fn islamicEpoch(cal: temporal.CalendarId) ?i64 {
    const s = cal.slice();
    if (std.ascii.eqlIgnoreCase(s, "islamic-civil") or std.ascii.eqlIgnoreCase(s, "islamicc")) return -492148;
    if (std.ascii.eqlIgnoreCase(s, "islamic-tbla")) return -492149;
    return null;
}

/// §islamic leap rule — 11 leap years per 30-year cycle.
fn islamicLeap(year: i64) bool {
    return @mod(14 + 11 * year, 30) < 11;
}

/// Odd months are 30 days, even months 29, except month 12 (Dhuʻl-Ḥijja) which
/// gains a 30th day in a leap year.
fn islamicDaysInMonth(year: i64, month: u32) u32 {
    if (month % 2 == 1) return 30;
    if (month == 12 and islamicLeap(year)) return 30;
    return 29;
}

/// fixed-from-islamic, in days-since-1970.
fn islamicToDays(epoch: i64, year: i64, month: i64, day: i64) i64 {
    return epoch - 1 + 354 * (year - 1) + @divFloor(3 + 11 * year, 30) + 29 * (month - 1) + @divFloor(month, 2) + day;
}

const IslamicYmd = struct { year: i64, month: u32, day: u32 };

/// islamic-from-fixed, from days-since-1970.
fn islamicFromDays(epoch: i64, date: i64) IslamicYmd {
    const year = @divFloor(30 * (date - epoch) + 10646, 10631);
    const prior = date - islamicToDays(epoch, year, 1, 1);
    const month = @divFloor(11 * prior + 330, 325);
    const day = date - islamicToDays(epoch, year, month, 1) + 1;
    return .{ .year = year, .month = @intCast(month), .day = @intCast(day) };
}

/// Calendar-resolved date fields for a stored ISO date — the single source of
/// truth behind every `Temporal.*` calendar getter. Gregorian-month calendars
/// (iso8601 / gregory / roc / buddhist) keep the ISO month/day and only shift
/// the year origin; the Islamic tabular calendars convert through the day count.
pub const CalDate = struct {
    year: i32,
    month: u32,
    day: u32,
    days_in_month: u32,
    days_in_year: u32,
    months_in_year: u32,
    day_of_year: u32,
    in_leap_year: bool,
    era: ?[]const u8,
    era_year: ?i32,
};

pub fn calendarFields(cal: temporal.CalendarId, iso_y: i32, iso_m: u32, iso_d: u32) CalDate {
    if (islamicEpoch(cal)) |epoch| {
        const date = temporal.daysFromCivil(iso_y, iso_m, iso_d);
        const i = islamicFromDays(epoch, date);
        const leap = islamicLeap(i.year);
        return .{
            .year = @intCast(i.year),
            .month = i.month,
            .day = i.day,
            .days_in_month = islamicDaysInMonth(i.year, i.month),
            .days_in_year = if (leap) 355 else 354,
            .months_in_year = 12,
            .day_of_year = @intCast(date - islamicToDays(epoch, i.year, 1, 1) + 1),
            .in_leap_year = leap,
            .era = "ah",
            .era_year = @intCast(i.year),
        };
    }
    // Gregorian-month family: iso8601 / gregory / roc / buddhist.
    return .{
        .year = calendarYear(cal, iso_y),
        .month = iso_m,
        .day = iso_d,
        .days_in_month = temporal.daysInIsoMonth(iso_y, iso_m),
        .days_in_year = @intCast(temporal.isoDaysInYear(iso_y)),
        .months_in_year = 12,
        .day_of_year = @intCast(temporal.isoDayOfYear(iso_y, iso_m, iso_d)),
        .in_leap_year = temporal.isLeapYear(iso_y),
        .era = eraCode(cal, iso_y),
        .era_year = if (cal.isIso()) null else eraYearInt(cal, iso_y),
    };
}

/// Integer form of eraYearForCalendar for the gregorian-month calendars (used
/// when building a CalDate; the public getter wraps this in a Value).
fn eraYearInt(cal: temporal.CalendarId, iso_year: i32) i32 {
    if (std.ascii.eqlIgnoreCase(cal.slice(), "gregory")) return if (iso_year < 1) 1 - iso_year else iso_year;
    if (std.ascii.eqlIgnoreCase(cal.slice(), "roc")) {
        const y = iso_year - 1911;
        return if (y < 1) 1 - y else y;
    }
    if (std.ascii.eqlIgnoreCase(cal.slice(), "buddhist")) return iso_year + 543;
    return iso_year;
}

const CalYmd = struct { year: i64, month: u32, day: u32 };

/// Inverse of calendarFields for an Islamic (year, month, day) field triple →
/// the ISO date, honouring `reject` (else constrain month ∈ [1,12] and day to
/// the month length). Returns null only under reject for an out-of-range field.
/// Gregorian-month calendars never reach here (they regulate via ISO directly).
pub fn islamicToIso(cal: temporal.CalendarId, cal_y: i64, cal_m: i64, cal_d: i64, reject: bool) ?CalYmd {
    const epoch = islamicEpoch(cal) orelse return null;
    var m = cal_m;
    if (m < 1 or m > 12) {
        if (reject) return null;
        m = std.math.clamp(m, 1, 12);
    }
    const dim: i64 = islamicDaysInMonth(cal_y, @intCast(m));
    var d = cal_d;
    if (d < 1 or d > dim) {
        if (reject) return null;
        d = std.math.clamp(d, 1, dim);
    }
    const ymd = temporal.civilFromDays(islamicToDays(epoch, cal_y, m, d));
    return .{ .year = ymd.year, .month = ymd.month, .day = ymd.day };
}

/// Whether `cal` needs the Islamic add/from path (non-gregorian month structure).
pub fn isIslamicTabular(cal: temporal.CalendarId) bool {
    return islamicEpoch(cal) != null;
}

/// Calendar-aware add for the Islamic tabular calendars: add years + months in
/// Islamic terms (normalising the month, constraining or rejecting the day to
/// the target month length), then add weeks + days as a plain day offset.
/// Returns the resulting ISO date. Gregorian-month calendars don't use this
/// (ISO months equal their calendar months, so addISODate already suffices).
pub fn addIslamic(cal: temporal.CalendarId, iso_y: i32, iso_m: u32, iso_d: u32, add_y: i64, add_mo: i64, add_w: i64, add_d: i64, reject: bool) ?CalYmd {
    const epoch = islamicEpoch(cal) orelse return null;
    const i = islamicFromDays(epoch, temporal.daysFromCivil(iso_y, iso_m, iso_d));
    var y = i.year + add_y;
    const m_total = (@as(i64, i.month) - 1) + add_mo; // 0-based month + delta
    y += @divFloor(m_total, 12);
    const m: i64 = @mod(m_total, 12) + 1; // 1..12
    const dim: i64 = islamicDaysInMonth(y, @intCast(m));
    var d: i64 = i.day;
    if (d > dim) {
        if (reject) return null;
        d = dim;
    }
    const days = islamicToDays(epoch, y, m, d) + add_w * 7 + add_d;
    const ymd = temporal.civilFromDays(days);
    return .{ .year = ymd.year, .month = ymd.month, .day = ymd.day };
}

/// weekOfYear / yearOfWeek are ISO-calendar concepts; non-ISO calendars
/// report undefined (matches gregory/hebrew behaviour in engines with
/// incomplete week numbering for non-ISO).
pub fn weekFieldsForCalendar(cal: temporal.CalendarId) bool {
    return cal.isIso();
}

/// §13.x GetTemporalShowCalendarNameOption — auto / always / never /
/// critical (default auto).
pub fn getCalendarNameOption(realm: *Realm, options: Value) NativeError!temporal.CalendarDisplay {
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

/// §13.x GetTemporalDisambiguationOption — read + validate `disambiguation`
/// ("compatible" / "earlier" / "later" / "reject"). Cynic ships fixed-offset
/// zones only, so there is never a DST gap/overlap and the resolved value is
/// never consulted; we still read and range-check it for the observable
/// side effect (a getter on the options bag) and the RangeError on a bad
/// value that fixtures assert.
pub fn getDisambiguationOption(realm: *Realm, options: Value) NativeError!void {
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
pub fn getOffsetOption(realm: *Realm, options: Value, fallback: temporal.OffsetOption) NativeError!temporal.OffsetOption {
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
pub fn getTimeZoneNameOption(realm: *Realm, options: Value) NativeError!temporal.TimeZoneNameDisplay {
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
pub fn getShowOffsetOption(realm: *Realm, options: Value) NativeError!bool {
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
pub fn getFractionalSecondDigitsOption(realm: *Realm, options: Value) NativeError!?u4 {
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
pub const SecondsStringPrecision = struct {
    precision: temporal.Precision,
    unit: temporal.LargestUnit,
    increment: i128,
};
pub fn toSecondsStringPrecision(smallest: ?temporal.LargestUnit, digits: ?u4) SecondsStringPrecision {
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
pub fn pow10(e: u4) i128 {
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
pub fn requireToStringSmallestUnit(realm: *Realm, unit: ?temporal.LargestUnit) NativeError!void {
    const u = unit orelse return;
    if (@intFromEnum(u) < @intFromEnum(temporal.LargestUnit.minute)) {
        return throwRangeError(realm, "smallestUnit must be minute, second, millisecond, microsecond, or nanosecond");
    }
}

/// §11.x TimeZoneEquals — UTC / same offset / same structural IANA name
/// (case-sensitive identifier compare; canonicalisation is not modelled
/// without tzdata, so `Africa/Cairo` ≠ `africa/cairo` here).
pub fn timeZoneEquals(a: temporal.TimeZone, b: temporal.TimeZone) bool {
    return switch (a) {
        .utc => std.meta.activeTag(b) == .utc,
        .offset_minutes => |am| switch (b) {
            .offset_minutes => |bm| am == bm,
            else => false,
        },
        .named => |an| switch (b) {
            .named => |bn| std.mem.eql(u8, an.slice(), bn.slice()),
            else => false,
        },
    };
}

/// Coerce `arg` into a Temporal time zone — a bare `Temporal.ZonedDateTime`
/// contributes its `[[TimeZone]]`; an IANA / `Z` / `±HH:MM` string is
/// parsed. Anything else throws TypeError. Used wherever the spec calls
/// ToTemporalTimeZoneIdentifier.
pub fn toTimeZoneArg(realm: *Realm, arg: Value) NativeError!temporal.TimeZone {
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
