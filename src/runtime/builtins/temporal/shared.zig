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
/// Months in `cal`'s year — 13 for the coptic-type calendars (epagomenal M13),
/// 12 otherwise. Used to bound monthCode parsing per calendar.
pub fn monthsInYearForCalendar(cal: temporal.CalendarId) i64 {
    // Upper bound across years (per-year counts come from calendarFields):
    // 13 for the coptic family and for hebrew leap years, else 12.
    if (computedCal(cal)) |c| return switch (c.family) {
        .coptic, .hebrew, .chinese, .dangi => 13,
        else => 12,
    };
    return 12;
}

pub fn monthFromCodeBytes(realm: *Realm, cal: temporal.CalendarId, buf: []const u8, actual_len: usize, max_month: i64) NativeError!i64 {
    const fam: ?CompFamily = if (computedCal(cal)) |c| c.family else null;
    const has_leap_months = fam == .hebrew or fam == .chinese or fam == .dangi;
    if (actual_len == 4) {
        // Leap-suffixed codes ("MxxL") exist only for the lunisolar calendars:
        // hebrew has exactly one ("M05L", Adar I); chinese/dangi leap any month
        // (M01L-M12L). Encoded as the negative code number; resolveMonthOrdinal
        // maps it per target year.
        if (!has_leap_months or buf[3] != 'L') return throwRangeError(realm, "invalid monthCode");
        const n: i64 = @as(i64, buf[1] - '0') * 10 + @as(i64, buf[2] - '0');
        if (fam == .hebrew and n != 5) return throwRangeError(realm, "invalid monthCode");
        if (n < 1 or n > 12) return throwRangeError(realm, "invalid monthCode");
        return -n;
    }
    const m: i64 = @as(i64, buf[1] - '0') * 10 + @as(i64, buf[2] - '0');
    // Lunisolar month CODES run M01-M12 (+ the leap forms); ordinal 13 exists
    // only through the leap-month shift, never as a literal code.
    const code_max: i64 = if (has_leap_months) 12 else max_month;
    if (m < 1 or m > code_max) return throwRangeError(realm, "invalid monthCode");
    return m;
}

/// Map a monthCode number from `monthFromCodeBytes` (negative = leap-suffixed)
/// to the month ordinal in `year`. Identity for every calendar whose codes
/// equal ordinals; hebrew shifts post-Shevat codes up by one in leap years and
/// places "M05L" at ordinal 6. A leap code in a common year follows `reject`:
/// throw, or constrain to Adar (the month Adar I merges into).
/// Whether the calendar has leap months (month codes that exist only in some
/// years): hebrew today; the chinese/dangi lunisolar pair when they land.
pub fn calendarHasLeapMonths(cal: temporal.CalendarId) bool {
    const c = computedCal(cal) orelse return false;
    return switch (c.family) {
        .hebrew, .chinese, .dangi => true,
        else => false,
    };
}

/// Inverse of resolveMonthOrdinal: the year-independent monthCode NUMBER for a
/// month ordinal (hebrew leap: ordinal 6 → -5 ("M05L"), ordinals 7+ shift down).
/// CLDR `en` month display names for the hebrew calendar. Per CLDR-15510
/// hebrew months are never rendered numerically, so DateTimeFormat prints
/// these even for the "numeric" / "2-digit" month options.
pub fn hebrewMonthDisplayName(year: i64, ordinal: u32) []const u8 {
    const common = [_][]const u8{ "Tishri", "Heshvan", "Kislev", "Tevet", "Shevat", "Adar", "Nisan", "Iyar", "Sivan", "Tamuz", "Av", "Elul" };
    const leapy = [_][]const u8{ "Tishri", "Heshvan", "Kislev", "Tevet", "Shevat", "Adar I", "Adar II", "Nisan", "Iyar", "Sivan", "Tamuz", "Av", "Elul" };
    if (hebrewLeap(year)) return leapy[@min(ordinal, 13) - 1];
    return common[@min(ordinal, 12) - 1];
}

pub fn monthOrdinalToCode(cal: temporal.CalendarId, year: i64, ordinal: u32) i64 {
    const c = computedCal(cal) orelse return ordinal;
    return compCodeForOrd(c.family, year, ordinal);
}

/// Family-level code→ordinal: null when the coded month doesn't exist in
/// `year` (a leap code in a common year). Codes equal ordinals everywhere
/// except hebrew leap years.
fn compOrdForCode(f: CompFamily, year: i64, code: i64) ?i64 {
    const leap_ord: i64 = compLeapOrdFor(f, year);
    if (code < 0) {
        if (leap_ord > 0 and -code == leap_ord - 1) return leap_ord;
        return null;
    }
    if (leap_ord > 0 and code >= leap_ord) return code + 1;
    return code;
}

/// The ordinal of the year's leap month, or 0 (hebrew: Adar I at 6 in leap
/// years; chinese/dangi: table-driven, can follow any month).
fn compLeapOrdFor(f: CompFamily, year: i64) u32 {
    return switch (f) {
        .hebrew => if (hebrewLeap(year)) 6 else 0,
        .chinese, .dangi => lunisolarLeapOrd(f, year),
        else => 0,
    };
}

/// The constrained ordinal for a leap code in a year that lacks it: hebrew's
/// Adar I merges into Adar (ICU special case); the chinese family constrains
/// to the base month of the code.
fn constrainLeapOrd(f: CompFamily, year: i64, code: i64) i64 {
    if (f == .hebrew) return 6;
    if (code >= 0) return code;
    return compOrdForCode(f, year, -code) orelse -code;
}
/// Total order over month CODES: M05 < M05L < M06 (a leap code sorts after
/// its base month). Used by the whole-year candidate comparison in
/// differenceComputedDate, which per the leap-months fixtures compares code
/// positions, not resolved ordinals.
fn compCodeKey(code: i64) i64 {
    return if (code < 0) -code * 2 + 1 else code * 2;
}

/// Family-level ordinal→code (hebrew leap: ordinal 6 → -5 ("M05L"),
/// ordinals 7+ shift down one).
fn compCodeForOrd(f: CompFamily, year: i64, ordinal: i64) i64 {
    const leap_ord: i64 = compLeapOrdFor(f, year);
    if (leap_ord == 0) return ordinal;
    if (ordinal == leap_ord) return -(leap_ord - 1);
    return if (ordinal > leap_ord) ordinal - 1 else ordinal;
}

pub fn resolveMonthOrdinal(realm: *Realm, cal: temporal.CalendarId, year: i64, code: i64, reject: bool) NativeError!i64 {
    const c = computedCal(cal) orelse return code;
    if (compOrdForCode(c.family, year, code)) |ord| return ord;
    if (reject) return throwRangeError(realm, "monthCode does not exist in this year");
    return constrainLeapOrd(c.family, year, code);
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

/// Resolve an {era, eraYear} field pair to the calendar's signed year, or null
/// if the era name is not valid for the calendar. The two-era calendars
/// (gregory ce/bce, roc roc/broc, islamic ah/bh) flip sign on the inverse era;
/// the single-era calendars (buddhist, coptic/ethiopic, ethioaa, indian) map
/// eraYear directly to the year. Used by the from/with field readers when the
/// property bag supplies era+eraYear instead of (or alongside) year.
pub fn eraYearToYear(cal: temporal.CalendarId, era: []const u8, era_year: i64) ?i64 {
    if (cal.isIso()) return null;
    const s = cal.slice();
    if (std.ascii.eqlIgnoreCase(s, "gregory")) {
        if (std.ascii.eqlIgnoreCase(era, "ce") or std.ascii.eqlIgnoreCase(era, "ad") or std.ascii.eqlIgnoreCase(era, "gregory")) return era_year;
        if (std.ascii.eqlIgnoreCase(era, "bce") or std.ascii.eqlIgnoreCase(era, "bc") or std.ascii.eqlIgnoreCase(era, "gregory-inverse")) return 1 - era_year;
        return null;
    }
    if (std.ascii.eqlIgnoreCase(s, "roc")) {
        if (std.ascii.eqlIgnoreCase(era, "roc") or std.ascii.eqlIgnoreCase(era, "minguo")) return era_year;
        if (std.ascii.eqlIgnoreCase(era, "broc") or std.ascii.eqlIgnoreCase(era, "roc-inverse")) return 1 - era_year;
        return null;
    }
    if (std.ascii.eqlIgnoreCase(s, "buddhist")) {
        return if (std.ascii.eqlIgnoreCase(era, "be")) era_year else null;
    }
    if (islamicEpoch(cal) != null or std.ascii.eqlIgnoreCase(s, "islamic-umalqura")) {
        if (std.ascii.eqlIgnoreCase(era, "ah")) return era_year;
        if (std.ascii.eqlIgnoreCase(era, "bh")) return 1 - era_year;
        return null;
    }
    if (isJapanese(cal)) {
        if (std.ascii.eqlIgnoreCase(era, "reiwa")) return 2019 + era_year - 1;
        if (std.ascii.eqlIgnoreCase(era, "heisei")) return 1989 + era_year - 1;
        if (std.ascii.eqlIgnoreCase(era, "showa")) return 1926 + era_year - 1;
        if (std.ascii.eqlIgnoreCase(era, "taisho")) return 1912 + era_year - 1;
        if (std.ascii.eqlIgnoreCase(era, "meiji")) return 1868 + era_year - 1;
        if (std.ascii.eqlIgnoreCase(era, "ce") or std.ascii.eqlIgnoreCase(era, "japanese")) return era_year;
        if (std.ascii.eqlIgnoreCase(era, "bce") or std.ascii.eqlIgnoreCase(era, "japanese-inverse")) return 1 - era_year;
        return null;
    }
    if (std.ascii.eqlIgnoreCase(s, "ethiopic")) {
        // Dual era: Amete Mihret ("am") is the arithmetic year; Amete Alem
        // ("aa") is 5500 greater (so aa eraYear → am year − 5500).
        if (std.ascii.eqlIgnoreCase(era, "am")) return era_year;
        if (std.ascii.eqlIgnoreCase(era, "aa")) return era_year - 5500;
        return null;
    }
    if (computedCal(cal)) |c| {
        return if (std.ascii.eqlIgnoreCase(era, c.era)) era_year else null;
    }
    return null;
}

// ── Japanese imperial calendar ───────────────────────────────────────────────
// Gregorian months/days (year == gregorian year); only era + eraYear differ,
// from a date-based table of Gregorian era-start dates. Pre-Meiji dates fall
// back to the proleptic Gregorian "ce"/"bce" eras. Modern boundaries verified
// vs SpiderMonkey / Kiesel / libjs (showa→heisei 1989-01-08, heisei→reiwa
// 2019-05-01).
fn isJapanese(cal: temporal.CalendarId) bool {
    return std.ascii.eqlIgnoreCase(cal.slice(), "japanese");
}

const JapaneseEra = struct { name: []const u8, year: i32 };

fn japaneseEraInfo(iso_y: i32, iso_m: u32, iso_d: u32) JapaneseEra {
    const dn = temporal.daysFromCivil(iso_y, iso_m, iso_d);
    if (dn >= temporal.daysFromCivil(2019, 5, 1)) return .{ .name = "reiwa", .year = iso_y - 2019 + 1 };
    if (dn >= temporal.daysFromCivil(1989, 1, 8)) return .{ .name = "heisei", .year = iso_y - 1989 + 1 };
    if (dn >= temporal.daysFromCivil(1926, 12, 25)) return .{ .name = "showa", .year = iso_y - 1926 + 1 };
    if (dn >= temporal.daysFromCivil(1912, 7, 30)) return .{ .name = "taisho", .year = iso_y - 1912 + 1 };
    if (dn >= temporal.daysFromCivil(1868, 9, 8)) return .{ .name = "meiji", .year = iso_y - 1868 + 1 };
    return if (iso_y < 1) .{ .name = "bce", .year = 1 - iso_y } else .{ .name = "ce", .year = iso_y };
}

pub const EraYearResolution = struct { present: bool, val: i64 };

/// Whether `cal` has a modelled era system (so era / eraYear participate in
/// field resolution). iso8601 and the not-yet-modelled calendars (chinese,
/// dangi, persian, japanese, umalqura, …) report false — their era/eraYear are
/// ignored, never resolved.
pub fn calendarHasEras(cal: temporal.CalendarId) bool {
    if (cal.isIso()) return false;
    const s = cal.slice();
    if (std.ascii.eqlIgnoreCase(s, "gregory") or std.ascii.eqlIgnoreCase(s, "roc") or std.ascii.eqlIgnoreCase(s, "buddhist")) return true;
    if (isJapanese(cal)) return true;
    // The chinese family has no era system (era = "").
    if (computedCal(cal)) |c| return c.era.len > 0;
    return false;
}

/// Resolve an already-read {era, eraYear} field pair against an existing year,
/// returning the effective year. For a calendar with no era system, era/eraYear
/// are ignored — but they cannot substitute for an absent year (TypeError). For
/// an era calendar, a lone era/eraYear, an unknown era, or a year that disagrees
/// with era+eraYear all throw. Shared by every from/with field reader.
pub fn resolveEraYear(realm: *Realm, cal: temporal.CalendarId, era_v: Value, era_year_v: Value, year_present: bool, year_val: i64, allow_absent_year: bool) NativeError!EraYearResolution {
    const has_era = !era_v.isUndefined();
    const has_ey = !era_year_v.isUndefined();
    if (!calendarHasEras(cal)) {
        // `from` requires a year and era/eraYear can't supply one for an era-less
        // calendar (TypeError). `with` has the receiver's year as the base, so
        // era/eraYear are simply ignored — allow_absent_year suppresses the throw.
        if (!allow_absent_year and !year_present and (has_era or has_ey))
            return throwTypeError(realm, "era/eraYear cannot replace year for a calendar that does not use eras");
        return .{ .present = year_present, .val = year_val };
    }
    if (!has_era and !has_ey) return .{ .present = year_present, .val = year_val };
    if (has_era != has_ey) return throwTypeError(realm, "era and eraYear must be provided together");
    if (!era_v.isString()) return throwTypeError(realm, "era must be a string");
    const era_s: *JSString = @ptrCast(@alignCast(era_v.asString()));
    const ey = try dateFieldToI64(realm, try toIntegerWithTruncation(realm, era_year_v));
    const ry = eraYearToYear(cal, era_s.flatBytes(), ey) orelse return throwRangeError(realm, "invalid era for the calendar");
    if (year_present and year_val != ry) return throwRangeError(realm, "year does not agree with era/eraYear");
    return .{ .present = true, .val = ry };
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
    return std.ascii.eqlIgnoreCase(s, "gregory") or std.ascii.eqlIgnoreCase(s, "roc") or std.ascii.eqlIgnoreCase(s, "buddhist") or isJapanese(cal);
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

// ── Umm-al-Qura (islamic-umalqura) ───────────────────────────────────────────
// Data-driven: the Saudi Umm-al-Qura almanac month lengths for AH 1300-1600,
// tabulated per year as (year-start day number in days-since-1970, 12-bit mask
// with bit m-1 set when month m has 30 days; clear = 29). Extracted from the
// Temporal implementations of SpiderMonkey / Kiesel / Boa / LibJS — all four
// byte-identical. Outside the tabulated range the calendar continues with the
// islamic-civil tabular arithmetic; the almanac anchors to the civil calendar
// at both ends, so islamicToDays(civil, 1300, 1, 1) == the table's first start
// and the 1601 extrapolation == the table's end — no seam.
const umalqura_first_year: i64 = 1300;
const umalqura_year_starts = [301]i32{
    -31826, -31472, -31118, -30763, -30409, -30054, -29700, -29345, -28991, -28637,
    -28283, -27928, -27574, -27219, -26865, -26510, -26156, -25802, -25448, -25093,
    -24738, -24384, -24029, -23675, -23321, -22967, -22612, -22258, -21903, -21549,
    -21195, -20841, -20486, -20132, -19777, -19423, -19068, -18714, -18360, -18006,
    -17651, -17297, -16942, -16588, -16234, -15880, -15526, -15171, -14816, -14462,
    -14107, -13753, -13399, -13045, -12690, -12336, -11981, -11626, -11272, -10918,
    -10564, -10210, -9855,  -9501,  -9146,  -8792,  -8438,  -8084,  -7729,  -7375,
    -7020,  -6665,  -6311,  -5957,  -5603,  -5249,  -4894,  -4539,  -4185,  -3830,
    -3476,  -3122,  -2768,  -2414,  -2059,  -1704,  -1350,  -996,   -642,   -288,
    67,     422,    776,    1131,   1485,   1839,   2193,   2547,   2902,   3256,
    3611,   3965,   4319,   4673,   5028,   5382,   5737,   6092,   6446,   6800,
    7154,   7508,   7863,   8218,   8572,   8927,   9281,   9635,   9989,   10344,
    10698,  11053,  11407,  11761,  12115,  12469,  12824,  13179,  13533,  13888,
    14242,  14596,  14950,  15304,  15659,  16013,  16368,  16722,  17076,  17430,
    17785,  18139,  18494,  18848,  19203,  19557,  19911,  20265,  20620,  20975,
    21329,  21683,  22038,  22392,  22746,  23101,  23456,  23810,  24165,  24519,
    24873,  25227,  25581,  25936,  26291,  26645,  26999,  27353,  27708,  28062,
    28417,  28771,  29126,  29480,  29834,  30188,  30542,  30897,  31252,  31606,
    31960,  32314,  32668,  33023,  33378,  33732,  34087,  34441,  34795,  35149,
    35504,  35858,  36213,  36567,  36922,  37276,  37630,  37984,  38339,  38693,
    39048,  39402,  39756,  40110,  40465,  40819,  41174,  41529,  41883,  42237,
    42591,  42945,  43300,  43655,  44009,  44364,  44718,  45072,  45426,  45780,
    46135,  46490,  46844,  47198,  47552,  47906,  48261,  48615,  48970,  49325,
    49679,  50033,  50387,  50741,  51096,  51450,  51805,  52159,  52513,  52867,
    53222,  53576,  53931,  54286,  54640,  54994,  55348,  55702,  56057,  56412,
    56766,  57121,  57475,  57829,  58183,  58538,  58892,  59247,  59601,  59955,
    60309,  60664,  61018,  61373,  61727,  62082,  62436,  62790,  63144,  63498,
    63853,  64208,  64562,  64916,  65270,  65624,  65979,  66333,  66688,  67043,
    67397,  67751,  68105,  68459,  68814,  69169,  69524,  69878,  70232,  70586,
    70940,  71295,  71649,  72004,  72358,  72713,  73067,  73421,  73775,  74130,
    74485,
};
const umalqura_month_masks = [301]u16{
    1365, 683,  2359, 694,  1398, 876,  2901, 2730, 2390, 1182, 2397, 698,
    1461, 938,  2891, 2710, 1326, 685,  1389, 2906, 1874, 3877, 3722, 3350,
    2646, 2741, 1716, 3497, 2962, 2853, 1611, 2715, 858,  1753, 1492, 3493,
    3402, 2709, 1334, 2421, 756,  1769, 1748, 1705, 1333, 605,  1213, 2490,
    948,  2921, 2858, 2645, 1197, 2653, 730,  1753, 3754, 3732, 3370, 3158,
    1198, 2669, 1386, 3413, 3402, 2707, 1323, 2651, 1338, 1717, 3753, 3410,
    3369, 2645, 1197, 1389, 2794, 1764, 3793, 3490, 2730, 2394, 730,  1465,
    2994, 1892, 1737, 1365, 683,  1243, 2746, 1460, 3497, 3410, 2725, 2349,
    621,  2285, 730,  2773, 2725, 2635, 1175, 2359, 694,  2421, 3433, 3410,
    3221, 2347, 603,  1243, 2517, 1490, 3493, 3402, 2709, 1357, 2733, 938,
    3026, 3012, 2953, 2709, 1325, 1453, 2922, 1748, 3529, 3474, 2726, 2390,
    686,  1389, 874,  2901, 2730, 2381, 1181, 2397, 698,  1461, 1450, 3413,
    2714, 2350, 622,  1373, 2778, 1748, 1701, 2855, 2637, 1197, 1389, 2906,
    1876, 3913, 3730, 3366, 2646, 854,  1717, 2986, 2962, 2853, 1675, 2715,
    1370, 2778, 1460, 3497, 2898, 2714, 1334, 630,  1397, 2802, 1748, 1705,
    1365, 685,  1213, 2490, 1396, 2921, 2898, 2709, 1325, 2653, 1242, 2777,
    1714, 3733, 3626, 3222, 2350, 2733, 1386, 3429, 3402, 3349, 1579, 3163,
    1338, 1717, 3506, 3428, 3369, 2645, 1197, 2413, 2794, 1768, 3793, 3492,
    3402, 2666, 730,  1465, 2930, 2920, 1745, 1621, 1195, 2395, 698,  1461,
    3497, 3410, 3238, 2382, 1134, 2397, 1242, 2773, 2730, 2637, 1179, 2359,
    1206, 2421, 3434, 3410, 2725, 2379, 683,  1371, 2777, 1490, 3525, 3474,
    2853, 1365, 2741, 1460, 2985, 1954, 1861, 1427, 2731, 1238, 2518, 1490,
    2981, 2890, 2709, 1197, 349,  733,  2522, 1460, 1449, 1325, 603,  2231,
    374,  1389, 2922, 2762, 2710, 1323, 347,  699,  1462, 3498, 2964, 3398,
    2701, 1325, 2717, 1370, 1877, 1865, 3859, 3658, 2710, 1366, 1717, 2986,
    2964,
};

fn umalquraInRange(year: i64) bool {
    return year >= umalqura_first_year and year < umalqura_first_year + @as(i64, umalqura_year_starts.len);
}
fn umalquraDaysInMonth(year: i64, month: u32) u32 {
    if (!umalquraInRange(year)) return islamicDaysInMonth(year, month);
    const mask = umalqura_month_masks[@intCast(year - umalqura_first_year)];
    return 29 + @as(u32, (mask >> @intCast(month - 1)) & 1);
}
fn umalquraDaysInYear(year: i64) u32 {
    if (!umalquraInRange(year)) return if (islamicLeap(year)) 355 else 354;
    return 348 + @as(u32, @popCount(umalqura_month_masks[@intCast(year - umalqura_first_year)]));
}
fn umalquraToDays(year: i64, month: i64, day: i64) i64 {
    if (!umalquraInRange(year)) return islamicToDays(-492148, year, month, day);
    const idx: usize = @intCast(year - umalqura_first_year);
    var days: i64 = umalqura_year_starts[idx];
    const mask = umalqura_month_masks[idx];
    var m: i64 = 1;
    while (m < month) : (m += 1) days += 29 + @as(i64, (mask >> @intCast(m - 1)) & 1);
    return days + day - 1;
}
fn umalquraFromDays(date: i64) CompYmd {
    const last = umalqura_year_starts.len - 1;
    const table_end: i64 = umalqura_year_starts[last] + 348 + @as(i64, @popCount(umalqura_month_masks[last]));
    if (date < umalqura_year_starts[0] or date >= table_end) {
        const i = islamicFromDays(-492148, date);
        return .{ .year = i.year, .month = i.month, .day = i.day };
    }
    // Last year whose start <= date (binary search; lo stays a valid candidate).
    var lo: usize = 0;
    var hi: usize = umalqura_year_starts.len;
    while (lo + 1 < hi) {
        const mid = (lo + hi) / 2;
        if (umalqura_year_starts[mid] <= date) lo = mid else hi = mid;
    }
    var rem: i64 = date - umalqura_year_starts[lo];
    const mask = umalqura_month_masks[lo];
    var month: u32 = 1;
    while (month < 12) : (month += 1) {
        const dim: i64 = 29 + @as(i64, (mask >> @intCast(month - 1)) & 1);
        if (rem < dim) break;
        rem -= dim;
    }
    return .{ .year = umalqura_first_year + @as(i64, @intCast(lo)), .month = month, .day = @intCast(rem + 1) };
}

// ── Hebrew calendar ──────────────────────────────────────────────────────────
// Arithmetic (molad + dehiyyot postponements), Reingold & Dershowitz,
// *Calendrical Calculations* — validated 0/301 mismatches against the Temporal
// implementations of SpiderMonkey / Kiesel / LibJS over AM 5600-5900 (year
// starts, months-in-year, and every month length byte-identical). Months are
// numbered ordinally from Tishri (Temporal convention): in a leap year ordinal
// 6 is Adar I (monthCode "M05L") and ordinals 7-13 carry codes M06-M12.
const hebrew_epoch: i64 = -1373427 - 719163; // R.D. -1373427 (Tishri 1, AM 1) in days-since-1970

fn hebrewLeap(year: i64) bool {
    return @mod(7 * year + 1, 19) < 7;
}
/// Days from the Hebrew epoch to the molad-derived start of year `y`, before
/// the year-length postponements (R&D hebrew-calendar-elapsed-days).
fn hebrewElapsedDays(year: i64) i64 {
    const months_elapsed = @divFloor(235 * year - 234, 19);
    const parts = 12084 + 13753 * months_elapsed;
    var days = 29 * months_elapsed + @divFloor(parts, 25920);
    if (@mod(3 * (days + 1), 7) < 3) days += 1;
    return days;
}
/// Tishri 1 of year `y` in days-since-1970, with the two year-length
/// postponements applied (a 356-day year start delays 2, a 382-day prior
/// year delays 1).
fn hebrewNewYear(year: i64) i64 {
    const ny0 = hebrewElapsedDays(year - 1);
    const ny1 = hebrewElapsedDays(year);
    const ny2 = hebrewElapsedDays(year + 1);
    const delay: i64 = if (ny2 - ny1 == 356) 2 else if (ny1 - ny0 == 382) 1 else 0;
    return hebrew_epoch + ny1 + delay;
}
fn hebrewDaysInYear(year: i64) u32 {
    return @intCast(hebrewNewYear(year + 1) - hebrewNewYear(year));
}
fn hebrewDaysInMonth(year: i64, month: u32) u32 {
    const ylen = hebrewDaysInYear(year);
    return switch (month) {
        1 => 30, // Tishri
        2 => if (@mod(ylen, 10) == 5) @as(u32, 30) else 29, // Marcheshvan: 30 only in a complete year
        3 => if (@mod(ylen, 10) == 3) @as(u32, 29) else 30, // Kislev: 29 only in a deficient year
        4 => 29, // Tevet
        5 => 30, // Shevat
        6 => if (hebrewLeap(year)) @as(u32, 30) else 29, // leap: Adar I; common: Adar
        else => blk: {
            if (hebrewLeap(year)) {
                if (month == 7) break :blk 29; // Adar II
                break :blk if ((month - 8) % 2 == 0) @as(u32, 30) else 29; // Nisan..Elul
            }
            break :blk if ((month - 7) % 2 == 0) @as(u32, 30) else 29; // Nisan..Elul
        },
    };
}
fn hebrewToDays(year: i64, month: i64, day: i64) i64 {
    var days = hebrewNewYear(year);
    var m: u32 = 1;
    while (m < month) : (m += 1) days += hebrewDaysInMonth(year, m);
    return days + day - 1;
}
fn hebrewFromDays(date: i64) CompYmd {
    // Mean year 365.2468 days; estimate then correct (bounded by one step each way).
    var year: i64 = @divFloor((date - hebrew_epoch) * 98496, 35975351) + 1;
    while (hebrewNewYear(year) > date) year -= 1;
    while (hebrewNewYear(year + 1) <= date) year += 1;
    var rem: i64 = date - hebrewNewYear(year);
    const miy: u32 = if (hebrewLeap(year)) 13 else 12;
    var month: u32 = 1;
    while (month < miy) : (month += 1) {
        const dim: i64 = hebrewDaysInMonth(year, month);
        if (rem < dim) break;
        rem -= dim;
    }
    return .{ .year = year, .month = month, .day = @intCast(rem + 1) };
}

// ── Chinese / Dangi lunisolar calendars ──────────────────────────────────────
// Data-driven over 1900-2100: per year (start day number in days-since-1970,
// the ordinal of the leap month or 0, and a 12/13-bit mask of 30-day months).
// Extracted from the Temporal implementations of SpiderMonkey / Kiesel / LibJS
// — all three byte-identical for both calendars — and self-checked (every
// year-start delta equals 29·monthsInYear + popCount(mask)). Years are
// numbered by the Gregorian year containing the new year (the Temporal
// convention); dangi is the Korean variant and differs from chinese in a
// handful of years. Outside the table, from-fields rejects (computedToIso
// returns null) and day-count conversion saturates to the table edge so the
// getters stay total.
const chinese_year_starts = [301]i32{
    -43787, -43433, -43049, -42694, -42340, -41956, -41602, -41247, -40864, -40509,
    -40155, -39771, -39417, -39033, -38678, -38324, -37940, -37586, -37231, -36847,
    -36493, -36109, -35755, -35400, -35017, -34662, -34308, -33924, -33570, -33186,
    -32831, -32477, -32093, -31739, -31384, -31000, -30646, -30292, -29908, -29553,
    -29169, -28815, -28461, -28077, -27722, -27368, -26984, -26630, -26275, -25892,
    -25537, -25153, -24799, -24444, -24061, -23707, -23352, -22968, -22614, -22259,
    -21875, -21521, -21137, -20783, -20429, -20045, -19691, -19336, -18952, -18597,
    -18213, -17859, -17505, -17121, -16767, -16413, -16028, -15674, -15319, -14935,
    -14581, -14198, -13844, -13489, -13105, -12750, -12396, -12012, -11658, -11274,
    -10920, -10566, -10182, -9827,  -9473,  -9088,  -8734,  -8380,  -7996,  -7642,
    -7258,  -6904,  -6549,  -6165,  -5811,  -5456,  -5072,  -4718,  -4335,  -3980,
    -3626,  -3242,  -2887,  -2533,  -2149,  -1794,  -1441,  -1057,  -702,   -318,
    36,     391,    775,    1129,   1483,   1867,   2221,   2605,   2959,   3314,
    3698,   4053,   4407,   4791,   5145,   5529,   5883,   6237,   6621,   6976,
    7331,   7715,   8069,   8423,   8806,   9161,   9545,   9899,   10254,  10638,
    10992,  11346,  11730,  12084,  12439,  12823,  13177,  13562,  13916,  14270,
    14654,  15008,  15362,  15746,  16101,  16485,  16839,  17194,  17578,  17932,
    18286,  18670,  19024,  19379,  19763,  20117,  20501,  20855,  21209,  21593,
    21948,  22302,  22686,  23041,  23425,  23779,  24133,  24517,  24871,  25225,
    25609,  25964,  26319,  26703,  27057,  27441,  27795,  28149,  28533,  28887,
    29242,  29626,  29981,  30365,  30719,  31073,  31456,  31811,  32165,  32549,
    32904,  33258,  33642,  33996,  34380,  34734,  35089,  35473,  35827,  36182,
    36566,  36920,  37304,  37658,  38012,  38396,  38751,  39105,  39489,  39844,
    40198,  40582,  40936,  41320,  41674,  42029,  42413,  42767,  43122,  43505,
    43859,  44243,  44597,  44952,  45336,  45691,  46045,  46429,  46783,  47137,
    47521,  47875,  48259,  48614,  48968,  49352,  49707,  50061,  50445,  50799,
    51183,  51538,  51892,  52276,  52630,  52985,  53369,  53723,  54107,  54461,
    54816,  55199,  55554,  55908,  56292,  56646,  57001,  57385,  57739,  58123,
    58477,  58832,  59216,  59570,  59924,  60308,  60663,  61046,  61401,  61755,
    62139,  62493,  62848,  63232,  63586,  63940,  64324,  64679,  65063,  65417,
    65771,
};
const chinese_leap_ords = [301]u8{
    0,  12, 0, 0,  8,  0, 0,  5,  0,  0,  2, 0,  11, 0, 0,  7, 0, 0,  3,  0,
    12, 0,  0, 9,  0,  0, 5,  0,  13, 0,  0, 10, 0,  0, 7,  0, 0, 4,  0,  12,
    0,  0,  8, 0,  0,  6, 0,  0,  2,  0,  9, 0,  0,  6, 0,  0, 5, 0,  0,  3,
    0,  7,  0, 0,  6,  0, 0,  3,  0,  8,  0, 0,  6,  0, 0,  5, 0, 0,  3,  0,
    7,  0,  0, 6,  0,  0, 4,  0,  8,  0,  0, 7,  0,  0, 5,  0, 0, 3,  0,  8,
    0,  0,  6, 0,  0,  4, 0,  9,  0,  0,  7, 0,  0,  5, 0,  0, 4, 0,  8,  0,
    0,  6,  0, 0,  5,  0, 9,  0,  0,  7,  0, 0,  5,  0, 11, 0, 0, 7,  0,  0,
    6,  0,  0, 4,  0,  9, 0,  0,  6,  0,  0, 5,  0,  0, 3,  0, 8, 0,  0,  6,
    0,  0,  5, 0,  10, 0, 0,  7,  0,  0,  5, 0,  0,  3, 0,  7, 0, 0,  6,  0,
    0,  4,  0, 12, 0,  0, 7,  0,  0,  6,  0, 0,  3,  0, 8,  0, 0, 6,  0,  0,
    4,  0,  9, 0,  0,  7, 0,  0,  5,  0,  0, 4,  0,  8, 0,  0, 6, 0,  0,  5,
    0,  9,  0, 0,  7,  0, 0,  5,  0,  0,  4, 0,  8,  0, 0,  6, 0, 0,  5,  0,
    9,  0,  0, 7,  0,  0, 5,  0,  0,  3,  0, 8,  0,  0, 7,  0, 0, 3,  0,  11,
    0,  0,  8, 0,  0,  5, 0,  13, 0,  0,  9, 0,  0,  6, 0,  0, 3, 0,  12, 0,
    0,  8,  0, 0,  4,  0, 13, 0,  0,  10, 0, 0,  6,  0, 0,  3, 0, 12, 0,  0,
    9,
};
const chinese_month_masks = [301]u16{
    1370, 2901, 3413, 2730, 5466, 1450, 3413, 2730, 2733, 1450, 3413, 1365,
    2733, 2773, 2730, 5461, 1366, 2773, 6826, 2730, 5462, 1386, 3413, 2730,
    2731, 1386, 3413, 1365, 2731, 2741, 1706, 5461, 1365, 2741, 5802, 2730,
    1365, 2741, 2901, 6826, 2730, 1370, 2901, 3413, 2730, 5466, 1450, 3413,
    2730, 2733, 5842, 1874, 3749, 5706, 1611, 2715, 5462, 1386, 2905, 5970,
    1874, 6949, 2853, 2635, 5291, 685,  1387, 2921, 3497, 7570, 3730, 3365,
    6733, 2646, 694,  5557, 1748, 3753, 7826, 3730, 3366, 1323, 2647, 4790,
    2906, 1748, 3785, 1865, 5779, 2707, 1323, 2651, 2733, 1386, 6997, 2980,
    2889, 6803, 2709, 5421, 1334, 2733, 5546, 1458, 3493, 7498, 3402, 2709,
    2711, 1366, 2741, 2773, 1746, 3749, 3749, 1610, 3223, 2715, 5466, 1386,
    2921, 5970, 2898, 2853, 5707, 2635, 5291, 685,  1389, 2921, 3497, 3474,
    7461, 3365, 6733, 2646, 694,  1461, 1749, 3753, 7826, 3730, 3366, 2646,
    2647, 5334, 858,  1749, 5833, 1865, 1683, 5419, 1323, 2651, 5466, 1386,
    6997, 2980, 2889, 6803, 2709, 1325, 2733, 2741, 5546, 1490, 3493, 7498,
    3402, 3221, 5422, 1366, 2741, 5554, 1746, 3749, 1829, 1611, 3223, 3243,
    1370, 2774, 2921, 5970, 2898, 2853, 6731, 2635, 1195, 1371, 1453, 2922,
    6994, 3474, 7461, 3365, 2645, 5293, 1206, 1461, 3498, 3785, 7826, 3730,
    3366, 2646, 2647, 1366, 1749, 1877, 1865, 3731, 1683, 5419, 1323, 2651,
    5466, 1386, 2917, 5962, 2890, 6805, 2709, 1325, 2733, 2741, 1450, 2981,
    3493, 3402, 7317, 3222, 6478, 1366, 2741, 5554, 1746, 3749, 3658, 1675,
    3223, 1195, 1371, 2774, 2922, 1874, 5925, 2885, 2699, 5275, 1195, 2395,
    1453, 1365, 2731, 2741, 1450, 5461, 1365, 2741, 2901, 2730, 5461, 1370,
    2901, 6826, 2730, 5466, 1450, 3413, 2730, 2733, 1450, 3413, 1365, 2733,
    5546, 1706, 5461, 1366, 2773, 5802, 2730, 1366, 2773, 2901, 2730, 2731,
    1386, 2901, 1365, 2731, 5482, 1450, 1365, 2731, 2741, 5546, 2730, 1365,
    2741,
};
const dangi_year_starts = [301]i32{
    -43787, -43433, -43049, -42694, -42340, -41956, -41602, -41247, -40864, -40509,
    -40155, -39771, -39417, -39033, -38678, -38324, -37940, -37586, -37231, -36847,
    -36493, -36109, -35755, -35400, -35017, -34662, -34308, -33924, -33570, -33186,
    -32831, -32477, -32093, -31739, -31384, -31000, -30646, -30292, -29908, -29553,
    -29169, -28815, -28461, -28077, -27722, -27368, -26984, -26630, -26275, -25892,
    -25537, -25153, -24799, -24444, -24061, -23707, -23352, -22968, -22614, -22259,
    -21875, -21521, -21137, -20783, -20429, -20045, -19690, -19336, -18952, -18597,
    -18213, -17859, -17505, -17121, -16767, -16413, -16028, -15674, -15319, -14935,
    -14581, -14198, -13844, -13489, -13105, -12750, -12396, -12012, -11658, -11274,
    -10920, -10566, -10182, -9827,  -9472,  -9088,  -8734,  -8380,  -7996,  -7642,
    -7258,  -6904,  -6549,  -6165,  -5810,  -5456,  -5072,  -4718,  -4334,  -3980,
    -3626,  -3242,  -2887,  -2533,  -2149,  -1794,  -1440,  -1057,  -702,   -318,
    36,     391,    775,    1129,   1483,   1867,   2221,   2605,   2959,   3314,
    3698,   4053,   4407,   4791,   5145,   5529,   5883,   6237,   6622,   6976,
    7331,   7715,   8069,   8423,   8806,   9161,   9545,   9900,   10254,  10638,
    10992,  11346,  11730,  12084,  12439,  12823,  13177,  13562,  13916,  14270,
    14654,  15008,  15362,  15746,  16101,  16485,  16839,  17194,  17578,  17932,
    18286,  18670,  19024,  19379,  19763,  20117,  20501,  20856,  21210,  21593,
    21948,  22302,  22686,  23041,  23425,  23779,  24133,  24517,  24871,  25225,
    25609,  25964,  26319,  26703,  27057,  27441,  27795,  28149,  28533,  28887,
    29242,  29626,  29981,  30365,  30719,  31073,  31456,  31811,  32165,  32549,
    32904,  33259,  33642,  33996,  34380,  34734,  35089,  35473,  35827,  36182,
    36566,  36920,  37304,  37658,  38012,  38396,  38751,  39105,  39489,  39844,
    40198,  40582,  40936,  41320,  41674,  42029,  42413,  42767,  43122,  43506,
    43859,  44243,  44598,  44952,  45336,  45691,  46045,  46429,  46783,  47137,
    47521,  47875,  48259,  48614,  48969,  49352,  49707,  50061,  50445,  50799,
    51183,  51538,  51892,  52276,  52630,  52985,  53369,  53723,  54107,  54461,
    54816,  55199,  55554,  55908,  56292,  56646,  57001,  57385,  57739,  58123,
    58477,  58832,  59216,  59570,  59924,  60308,  60663,  61017,  61401,  61755,
    62139,  62494,  62848,  63232,  63586,  63941,  64324,  64679,  65063,  65417,
    65771,
};
const dangi_leap_ords = [301]u8{
    0,  12, 0, 0,  8,  0, 0, 5,  0,  0,  2, 0,  11, 0, 0,  7, 0, 0,  3,  0,
    12, 0,  0, 9,  0,  0, 5, 0,  13, 0,  0, 10, 0,  0, 7,  0, 0, 4,  0,  12,
    0,  0,  8, 0,  0,  6, 0, 0,  2,  0,  9, 0,  0,  6, 0,  0, 5, 0,  0,  3,
    0,  7,  0, 0,  6,  0, 0, 3,  0,  8,  0, 0,  6,  0, 0,  5, 0, 0,  3,  0,
    7,  0,  0, 6,  0,  0, 4, 0,  8,  0,  0, 7,  0,  0, 5,  0, 0, 3,  0,  8,
    0,  0,  6, 0,  0,  4, 0, 9,  0,  0,  7, 0,  0,  5, 0,  0, 4, 0,  8,  0,
    0,  6,  0, 0,  5,  0, 9, 0,  0,  7,  0, 0,  5,  0, 11, 0, 0, 7,  0,  0,
    6,  0,  0, 4,  0,  9, 0, 0,  6,  0,  0, 5,  0,  0, 3,  0, 8, 0,  0,  6,
    0,  0,  4, 0,  10, 0, 0, 6,  0,  0,  5, 0,  0,  3, 0,  7, 0, 0,  6,  0,
    0,  4,  0, 12, 0,  0, 7, 0,  0,  6,  0, 0,  3,  0, 8,  0, 0, 6,  0,  0,
    4,  0,  9, 0,  0,  7, 0, 0,  5,  0,  0, 4,  0,  8, 0,  0, 6, 0,  0,  5,
    0,  9,  0, 0,  7,  0, 0, 5,  0,  0,  4, 0,  8,  0, 0,  6, 0, 0,  5,  0,
    9,  0,  0, 7,  0,  0, 5, 0,  0,  4,  0, 8,  0,  0, 7,  0, 0, 3,  0,  11,
    0,  0,  8, 0,  0,  5, 0, 13, 0,  0,  9, 0,  0,  6, 0,  0, 3, 0,  12, 0,
    0,  8,  0, 0,  4,  0, 0, 2,  0,  10, 0, 0,  6,  0, 0,  3, 0, 12, 0,  0,
    8,
};
const dangi_month_masks = [301]u16{
    1370, 2901, 3413, 2730, 5466, 1450, 3413, 2730, 2733, 1450, 3413, 1365,
    2733, 2773, 2730, 5461, 1366, 2773, 6826, 2730, 5462, 1386, 3413, 2730,
    2731, 1386, 3413, 1365, 2731, 2741, 1706, 5461, 1365, 2741, 5802, 2730,
    1365, 2741, 2901, 6826, 2730, 1370, 2901, 3413, 2730, 5466, 1450, 3413,
    2730, 2733, 5842, 1874, 3749, 5706, 1611, 2715, 5462, 1386, 2905, 5970,
    1874, 6949, 2853, 2635, 4763, 2733, 1386, 2921, 2985, 6994, 3474, 3365,
    6733, 2390, 693,  5549, 1748, 3497, 7570, 3730, 3366, 1319, 2647, 4790,
    2778, 1748, 3753, 1865, 5779, 2707, 1323, 2651, 2413, 2922, 6996, 2980,
    2889, 6803, 2709, 5419, 1325, 2733, 5482, 3506, 3492, 7497, 3402, 6805,
    2710, 1366, 2741, 2773, 1746, 3749, 3749, 3658, 3222, 2715, 5462, 1386,
    2905, 5970, 1874, 1829, 5707, 2635, 4779, 685,  1387, 2921, 3497, 3474,
    6949, 3365, 6733, 2646, 694,  5549, 1748, 3497, 7570, 3730, 3366, 2646,
    2647, 4790, 2906, 1748, 3785, 1865, 1683, 5415, 1323, 2651, 5466, 874,
    6997, 2980, 2889, 6803, 2709, 1325, 2653, 2733, 5546, 1490, 3493, 7498,
    3402, 2709, 5421, 1366, 2741, 5546, 1746, 3749, 3749, 3658, 3222, 3227,
    1370, 2773, 2921, 5970, 1874, 2853, 5707, 2635, 1195, 1371, 1389, 2921,
    6994, 3474, 7461, 3365, 2637, 5293, 694,  1461, 3497, 3753, 7570, 3730,
    3366, 2646, 2647, 1238, 1717, 1749, 3785, 3730, 1683, 5419, 1323, 2651,
    5466, 1386, 2901, 5961, 2889, 6803, 2709, 1325, 2733, 2741, 1450, 2981,
    3493, 3402, 6805, 3221, 5422, 1366, 2741, 5554, 1746, 3749, 7754, 1610,
    3223, 3243, 1370, 2773, 2921, 1874, 5797, 2853, 1611, 5271, 1195, 1371,
    1453, 3413, 2730, 2733, 1450, 3413, 1365, 2733, 2773, 1706, 5461, 1366,
    2773, 6826, 2730, 5462, 1386, 3413, 2730, 2731, 1386, 3413, 1365, 2731,
    5482, 1706, 5461, 1365, 2741, 5802, 2730, 1365, 2741, 2901, 2730, 5461,
    1370, 2901, 3413, 2730, 5466, 1450, 3413, 2730, 2733, 5546, 1706, 1365,
    2733,
};

const LunisolarTable = struct {
    starts: []const i32,
    leaps: []const u8,
    masks: []const u16,
};
const chinese_table = LunisolarTable{ .starts = &chinese_year_starts, .leaps = &chinese_leap_ords, .masks = &chinese_month_masks };
const dangi_table = LunisolarTable{ .starts = &dangi_year_starts, .leaps = &dangi_leap_ords, .masks = &dangi_month_masks };
const lunisolar_first_year: i64 = 1850;

fn lunisolarTable(f: CompFamily) *const LunisolarTable {
    return if (f == .dangi) &dangi_table else &chinese_table;
}
fn lunisolarInRange(year: i64) bool {
    return year >= lunisolar_first_year and year < lunisolar_first_year + 301;
}
fn lunisolarClampYear(year: i64) usize {
    return @intCast(std.math.clamp(year, lunisolar_first_year, lunisolar_first_year + 300) - lunisolar_first_year);
}
fn lunisolarLeapOrd(f: CompFamily, year: i64) u32 {
    if (!lunisolarInRange(year)) return 0;
    return lunisolarTable(f).leaps[lunisolarClampYear(year)];
}
fn lunisolarMonthsInYear(f: CompFamily, year: i64) u32 {
    return if (lunisolarLeapOrd(f, year) > 0) 13 else 12;
}
fn lunisolarDaysInMonth(f: CompFamily, year: i64, month: u32) u32 {
    const t = lunisolarTable(f);
    const mask = t.masks[lunisolarClampYear(year)];
    return 29 + @as(u32, (mask >> @intCast(month - 1)) & 1);
}
fn lunisolarDaysInYear(f: CompFamily, year: i64) u32 {
    const t = lunisolarTable(f);
    const idx = lunisolarClampYear(year);
    return 29 * lunisolarMonthsInYear(f, year) + @as(u32, @popCount(t.masks[idx]));
}
fn lunisolarToDays(f: CompFamily, year: i64, month: i64, day: i64) i64 {
    const t = lunisolarTable(f);
    const idx = lunisolarClampYear(year);
    var days: i64 = t.starts[idx];
    const mask = t.masks[idx];
    var m: i64 = 1;
    while (m < month) : (m += 1) days += 29 + @as(i64, (mask >> @intCast(m - 1)) & 1);
    return days + day - 1;
}
fn lunisolarFromDays(f: CompFamily, date_in: i64) CompYmd {
    const t = lunisolarTable(f);
    const last = t.starts.len - 1;
    const table_end: i64 = t.starts[last] + 29 * 12 + @as(i64, @popCount(t.masks[last]));
    // Saturate outside the tabulated range: the getters must stay total, and
    // from-fields never reaches here for an out-of-range year.
    const date = std.math.clamp(date_in, t.starts[0], table_end - 1);
    var lo: usize = 0;
    var hi: usize = t.starts.len;
    while (lo + 1 < hi) {
        const mid = (lo + hi) / 2;
        if (t.starts[mid] <= date) lo = mid else hi = mid;
    }
    const year = lunisolar_first_year + @as(i64, @intCast(lo));
    var rem: i64 = date - t.starts[lo];
    const mask = t.masks[lo];
    const miy = lunisolarMonthsInYear(f, year);
    var month: u32 = 1;
    while (month < miy) : (month += 1) {
        const dim: i64 = 29 + @as(i64, (mask >> @intCast(month - 1)) & 1);
        if (rem < dim) break;
        rem -= dim;
    }
    return .{ .year = year, .month = month, .day = @intCast(rem + 1) };
}

// ── Computational calendar family ────────────────────────────────────────────
// A common dispatch over the calendars whose date is a closed-form function of
// the day count: the Islamic tabular pair (islamic-civil / islamic-tbla) and
// the Coptic-type pair (coptic / ethiopic — 13 months of 30 days + a 5/6-day
// epagomenal 13th month, leap every 4th year). Each member is fully described
// by an epoch (days-since-1970, daysFromCivil space), an era, and its family's
// fixed-from / from-fixed / month-length / leap rules. Coptic epochs verified
// against SpiderMonkey/Boa/Kiesel/libjs (coptic 1737-01-01 = ISO 2020-09-11,
// ethiopic 2013-01-01 = ISO 2020-09-11). Reingold & Dershowitz.
const CompFamily = enum { islamic, umalqura, hebrew, chinese, dangi, coptic, indian, persian };
const ComputedCal = struct { family: CompFamily, epoch: i64, era: []const u8 };

fn computedCal(cal: temporal.CalendarId) ?ComputedCal {
    const s = cal.slice();
    if (std.ascii.eqlIgnoreCase(s, "islamic-civil") or std.ascii.eqlIgnoreCase(s, "islamicc")) return .{ .family = .islamic, .epoch = -492148, .era = "ah" };
    if (std.ascii.eqlIgnoreCase(s, "islamic-tbla")) return .{ .family = .islamic, .epoch = -492149, .era = "ah" };
    if (std.ascii.eqlIgnoreCase(s, "islamic-umalqura")) return .{ .family = .umalqura, .epoch = -492148, .era = "ah" }; // epoch = the out-of-table civil fallback

    if (std.ascii.eqlIgnoreCase(s, "coptic")) return .{ .family = .coptic, .epoch = -615558, .era = "am" };
    if (std.ascii.eqlIgnoreCase(s, "ethiopic")) return .{ .family = .coptic, .epoch = -716367, .era = "am" };
    if (std.ascii.eqlIgnoreCase(s, "ethioaa")) return .{ .family = .coptic, .epoch = -2725242, .era = "aa" }; // Amete Alem (= ethiopic + 5500 yr)
    if (std.ascii.eqlIgnoreCase(s, "indian")) return .{ .family = .indian, .epoch = 0, .era = "shaka" }; // gregorian-tied, no fixed epoch
    if (std.ascii.eqlIgnoreCase(s, "persian")) return .{ .family = .persian, .epoch = 0, .era = "ap" }; // Solar Hijri; epoch baked into persianToDays
    if (std.ascii.eqlIgnoreCase(s, "hebrew")) return .{ .family = .hebrew, .epoch = 0, .era = "am" }; // epoch baked into hebrewToDays
    if (std.ascii.eqlIgnoreCase(s, "chinese")) return .{ .family = .chinese, .epoch = 0, .era = "" }; // no era system
    if (std.ascii.eqlIgnoreCase(s, "dangi")) return .{ .family = .dangi, .epoch = 0, .era = "" }; // no era system
    return null;
}

// Dual-era resolution for a computed calendar's arithmetic year. Islamic flips
// ah↔bh at year 1 (like gregory ce/bce); ethiopic flips Amete Mihret ("am") to
// Amete Alem ("aa", = year + 5500) at year ≤ 0. coptic / ethioaa / indian /
// persian keep their single era. Verified vs the era-boundary-*.js fixtures.
const ComputedEra = struct { era: []const u8, era_year: i64 };
fn computedEra(cal: temporal.CalendarId, c: ComputedCal, year: i64) ComputedEra {
    switch (c.family) {
        .islamic, .umalqura => return if (year >= 1)
            .{ .era = "ah", .era_year = year }
        else
            .{ .era = "bh", .era_year = 1 - year },
        .coptic => {
            if (std.ascii.eqlIgnoreCase(cal.slice(), "ethiopic") and year < 1)
                return .{ .era = "aa", .era_year = year + 5500 };
            return .{ .era = c.era, .era_year = year };
        },
        else => return .{ .era = c.era, .era_year = year },
    }
}

fn compMonthsInYear(f: CompFamily, year: i64) u32 {
    return switch (f) {
        .coptic => 13,
        .hebrew => if (hebrewLeap(year)) 13 else 12,
        .chinese, .dangi => lunisolarMonthsInYear(f, year),
        else => 12,
    };
}

/// Step one calendar month in `sign` direction, wrapping across year
/// boundaries with the destination year's own month count (hebrew years
/// alternate 12/13 months, so the wrap is year-aware).
fn compStepMonth(f: CompFamily, year: i64, month: i64, sign: i64) CompYearMonth {
    var y = year;
    var m = month + sign;
    if (m > compMonthsInYear(f, y)) {
        y += 1;
        m = 1;
    } else if (m < 1) {
        y -= 1;
        m = compMonthsInYear(f, y);
    }
    return .{ .year = y, .month = m };
}

fn compLeap(f: CompFamily, year: i64) bool {
    return switch (f) {
        .islamic => islamicLeap(year),
        .umalqura => umalquraDaysInYear(year) == 355,
        .hebrew => hebrewLeap(year),
        .chinese, .dangi => lunisolarLeapOrd(f, year) > 0,
        .coptic => @mod(year, 4) == 3,
        .indian => indianLeap(year),
        .persian => persianLeap(year),
    };
}

fn compDaysInMonth(f: CompFamily, year: i64, month: u32) u32 {
    return switch (f) {
        .islamic => islamicDaysInMonth(year, month),
        .umalqura => umalquraDaysInMonth(year, month),
        .hebrew => hebrewDaysInMonth(year, month),
        .chinese, .dangi => lunisolarDaysInMonth(f, year, month),
        .coptic => if (month <= 12) 30 else (if (compLeap(.coptic, year)) @as(u32, 6) else 5),
        .indian => indianDaysInMonth(year, month),
        .persian => persianDaysInMonth(year, month),
    };
}

fn compDaysInYear(f: CompFamily, year: i64) u32 {
    return switch (f) {
        .islamic => if (compLeap(.islamic, year)) @as(u32, 355) else 354,
        .umalqura => umalquraDaysInYear(year),
        .hebrew => hebrewDaysInYear(year),
        .chinese, .dangi => lunisolarDaysInYear(f, year),
        .coptic => if (compLeap(.coptic, year)) @as(u32, 366) else 365,
        .indian => if (compLeap(.indian, year)) @as(u32, 366) else 365,
        .persian => if (compLeap(.persian, year)) @as(u32, 366) else 365,
    };
}

/// fixed-from, days-since-1970.
fn compToDays(c: ComputedCal, year: i64, month: i64, day: i64) i64 {
    return switch (c.family) {
        .islamic => islamicToDays(c.epoch, year, month, day),
        .umalqura => umalquraToDays(year, month, day),
        .hebrew => hebrewToDays(year, month, day),
        .chinese, .dangi => lunisolarToDays(c.family, year, month, day),
        .coptic => c.epoch - 1 + 365 * (year - 1) + @divFloor(year, 4) + 30 * (month - 1) + day,
        .indian => indianToDays(year, month, day),
        .persian => persianToDays(year, month, day),
    };
}

const CompYmd = struct { year: i64, month: u32, day: u32 };

/// from-fixed, from days-since-1970.
fn compFromDays(c: ComputedCal, date: i64) CompYmd {
    switch (c.family) {
        .islamic => {
            const i = islamicFromDays(c.epoch, date);
            return .{ .year = i.year, .month = i.month, .day = i.day };
        },
        .umalqura => return umalquraFromDays(date),
        .hebrew => return hebrewFromDays(date),
        .chinese, .dangi => return lunisolarFromDays(c.family, date),
        .coptic => {
            const year = @divFloor(4 * (date - c.epoch) + 1463, 1461);
            const month = @divFloor(date - compToDays(c, year, 1, 1), 30) + 1;
            const day = date - compToDays(c, year, month, 1) + 1;
            return .{ .year = year, .month = @intCast(month), .day = @intCast(day) };
        },
        .indian => return indianFromDays(date),
        .persian => return persianFromDays(date),
    }
}

// ── Indian national calendar (Saka) ──────────────────────────────────────────
// Gregorian-tied: Saka year Y maps to gregorian Y+78, and Chaitra 1 falls on
// ISO Mar 21 when greg(Y+78) is leap, else Mar 22. Chaitra (M1) has 30 days (31
// in a leap year); M2-M6 have 31, M7-M12 have 30. Verified vs SpiderMonkey/Boa/
// Kiesel/libjs: Saka 1946-01-01 = ISO 2024-03-21, 1945-10-11 = 2024-01-01,
// 1942-06-20 = 2020-09-11. era "shaka".
fn indianLeap(year: i64) bool {
    return temporal.isLeapYear(year + 78);
}
fn indianDaysInMonth(year: i64, month: u32) u32 {
    if (month == 1) return if (indianLeap(year)) 31 else 30;
    if (month <= 6) return 31;
    return 30;
}
/// 0-based day-of-year offset of the first of `month`.
fn indianMonthStartOffset(month: i64, leap: bool) i64 {
    if (month <= 1) return 0;
    const chaitra: i64 = if (leap) 31 else 30;
    if (month <= 6) return chaitra + 31 * (month - 2);
    return chaitra + 31 * 5 + 30 * (month - 7);
}
/// ISO day-number (days-since-1970) of Chaitra 1 for Saka `year`.
fn indianNewYear(year: i64) i64 {
    const g = year + 78;
    return temporal.daysFromCivil(g, 3, if (temporal.isLeapYear(g)) 21 else 22);
}
fn indianToDays(year: i64, month: i64, day: i64) i64 {
    return indianNewYear(year) + indianMonthStartOffset(month, indianLeap(year)) + (day - 1);
}
fn indianFromDays(date: i64) CompYmd {
    var year: i64 = temporal.civilFromDays(date).year - 78;
    if (date < indianNewYear(year)) year -= 1; // Jan-early-Mar belongs to the prior Saka year
    const doy = date - indianNewYear(year);
    const leap = indianLeap(year);
    var month: i64 = 12;
    var mm: i64 = 1;
    while (mm < 12) : (mm += 1) {
        if (doy < indianMonthStartOffset(mm + 1, leap)) {
            month = mm;
            break;
        }
    }
    const day = doy - indianMonthStartOffset(month, leap) + 1;
    return .{ .year = year, .month = @intCast(month), .day = @intCast(day) };
}

// ── Persian (Solar Hijri) calendar ───────────────────────────────────────────
// Solar: 12 months (M1-6 = 31 days, M7-11 = 30, M12 = 29 / 30 in a leap year),
// the year starting at Nowruz (~Mar 20-21). The leap rule is the 33-year
// arithmetic cycle that tracks the astronomical (Tehran vernal-equinox) calendar
// over the modern range — verified vs SpiderMonkey/Kiesel/Boa/libjs (1403 leap;
// 1401/1402/1404/1405 not; 1403-01-01 = ISO 2024-03-20). era "ap".
fn persianLeap(year: i64) bool {
    return @mod(25 * year + 11, 33) < 8;
}
// Leap years in [1, year-1]. Each 33-year block holds exactly 8 leaps; the
// partial tail (≤32 iterations) is summed directly. Floor division keeps it
// consistent for negative years (the inverse persianFromDays relies on this).
fn persianLeapsBefore(year: i64) i64 {
    const m = year - 1;
    const cycles = @divFloor(m, 33);
    const rem = m - cycles * 33; // [0, 32]
    var count = cycles * 8;
    var j: i64 = 1;
    while (j <= rem) : (j += 1) {
        if (@mod(25 * j + 11, 33) < 8) count += 1;
    }
    return count;
}
// Fixed day of Persian year-01-01 (days-since-1970), baked from the verified
// anchor 1403-01-01 = ISO 2024-03-20.
const persian_epoch: i64 = temporal.daysFromCivil(2024, 3, 20) - (1402 * 365 + persianLeapsBefore(1403));
fn persianNewYear(year: i64) i64 {
    return persian_epoch + (year - 1) * 365 + persianLeapsBefore(year);
}
// Days in months [1, month-1] (month-1 ≤ 11, all ≤ 30-day months).
fn persianMonthStartOffset(month: i64) i64 {
    return if (month <= 7) (month - 1) * 31 else 186 + (month - 7) * 30;
}
fn persianDaysInMonth(year: i64, month: u32) u32 {
    if (month <= 6) return 31;
    if (month <= 11) return 30;
    return if (persianLeap(year)) @as(u32, 30) else 29; // M12
}
fn persianToDays(year: i64, month: i64, day: i64) i64 {
    return persianNewYear(year) + persianMonthStartOffset(month) + (day - 1);
}
fn persianFromDays(date: i64) CompYmd {
    // Estimate the year from the mean year length, then correct by ±1.
    var year: i64 = @divFloor((date - persian_epoch) * 10000, 3652422) + 1;
    while (persianNewYear(year) > date) year -= 1;
    while (persianNewYear(year + 1) <= date) year += 1;
    const doy = date - persianNewYear(year); // 0-based day of year
    var month: i64 = 12;
    var mm: i64 = 1;
    while (mm < 12) : (mm += 1) {
        if (doy < persianMonthStartOffset(mm + 1)) {
            month = mm;
            break;
        }
    }
    const day = doy - persianMonthStartOffset(month) + 1;
    return .{ .year = year, .month = @intCast(month), .day = @intCast(day) };
}

pub const MonthDayRef = struct { iso_year: i32, iso_month: u32, iso_day: u32 };

/// §12.x CalendarMonthDayToISOReferenceDate for a computational calendar: the
/// canonical ISO date backing a PlainMonthDay of (calendar month, day) — the
/// latest occurrence on or before ISO 1972-12-31 where the day is valid (so a
/// leap-only day such as coptic M13-06 anchors to a leap year → ref ISO 1971).
/// Returns null when the day exceeds every year's month length under reject.
pub fn computedMonthDayRef(cal: temporal.CalendarId, code_month: i64, day_in: i64, reject: bool) ?MonthDayRef {
    const c = computedCal(cal) orelse return null;
    const ref_limit = temporal.daysFromCivil(1972, 12, 31);
    const base_year = compFromDays(c, ref_limit).year;

    // The chinese/dangi reference search is bounded below at year 1900: the
    // pre-1900 proleptic data is where ICU4X and ICU4C disagree, so the
    // proposal pins "has not occurred since 1900" as unrepresentable. The
    // arithmetic calendars settle within 40 years (over an Islamic 30-year
    // cycle and two Metonic cycles).
    const bounded = c.family == .chinese or c.family == .dangi;
    const floor_year: i64 = if (bounded) 1900 else base_year - 40;
    var max_day: i64 = 0;
    var p: i64 = base_year;
    while (p >= floor_year) : (p -= 1) {
        if (compOrdForCode(c.family, p, code_month)) |ord| {
            const dim: i64 = compDaysInMonth(c.family, p, @intCast(ord));
            if (dim > max_day) max_day = dim;
        }
    }
    var code = code_month;
    if (max_day == 0) {
        // The coded month never occurs in the searchable window (a rare leap
        // month): reject throws; constrain falls back to the base month.
        if (reject or code_month >= 0) return null;
        code = -code_month;
        var p2: i64 = base_year;
        while (p2 >= floor_year) : (p2 -= 1) {
            if (compOrdForCode(c.family, p2, code)) |ord| {
                const dim: i64 = compDaysInMonth(c.family, p2, @intCast(ord));
                if (dim > max_day) max_day = dim;
            }
        }
        if (max_day == 0) return null;
    }
    var day = day_in;
    if (day > max_day) {
        if (reject) return null;
        day = max_day;
    }
    if (day < 1) return null;

    // Walk calendar years down from the reference epoch to the latest one whose
    // (month, day) is both valid and lands on or before the ISO limit.
    var cy: i64 = base_year;
    while (cy >= floor_year) {
        const ord = compOrdForCode(c.family, cy, code) orelse {
            cy -= 1;
            continue;
        };
        const dim: i64 = compDaysInMonth(c.family, cy, @intCast(ord));
        if (day <= dim) {
            const iso_days = compToDays(c, cy, ord, day);
            if (iso_days <= ref_limit) {
                const civ = temporal.civilFromDays(iso_days);
                return .{ .iso_year = @intCast(civ.year), .iso_month = @intCast(civ.month), .iso_day = @intCast(civ.day) };
            }
        }
        cy -= 1;
    }
    return null;
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
    if (computedCal(cal)) |c| {
        const date = temporal.daysFromCivil(iso_y, iso_m, iso_d);
        const cd = compFromDays(c, date);
        const ev = computedEra(cal, c, cd.year);
        return .{
            .year = @intCast(cd.year),
            .month = cd.month,
            .day = cd.day,
            .days_in_month = compDaysInMonth(c.family, cd.year, cd.month),
            .days_in_year = compDaysInYear(c.family, cd.year),
            .months_in_year = compMonthsInYear(c.family, cd.year),
            .day_of_year = @intCast(date - compToDays(c, cd.year, 1, 1) + 1),
            .in_leap_year = compLeap(c.family, cd.year),
            .era = if (c.era.len == 0) null else ev.era,
            .era_year = if (c.era.len == 0) null else @intCast(ev.era_year),
        };
    }
    // Japanese: gregorian structure with a date-based era overlay.
    if (isJapanese(cal)) {
        const je = japaneseEraInfo(iso_y, iso_m, iso_d);
        return .{
            .year = iso_y,
            .month = iso_m,
            .day = iso_d,
            .days_in_month = temporal.daysInIsoMonth(iso_y, iso_m),
            .days_in_year = @intCast(temporal.isoDaysInYear(iso_y)),
            .months_in_year = 12,
            .day_of_year = @intCast(temporal.isoDayOfYear(iso_y, iso_m, iso_d)),
            .in_leap_year = temporal.isLeapYear(iso_y),
            .era = je.name,
            .era_year = je.year,
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
        // eraYear tracks era: a calendar with no modelled era (iso8601 and the
        // not-yet-implemented non-gregorian calendars) reports undefined.
        .era_year = if (eraCode(cal, iso_y) == null) null else eraYearInt(cal, iso_y),
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

// Per-field calendar getters — thin Value wrappers over calendarFields, so a
// prototype getter is a one-liner. Correct for every modelled calendar
// (gregorian-month + Islamic tabular).
pub fn yearValue(cal: temporal.CalendarId, y: i32, m: u32, d: u32) Value {
    return Value.fromInt32(calendarFields(cal, y, m, d).year);
}
pub fn monthValue(cal: temporal.CalendarId, y: i32, m: u32, d: u32) Value {
    return Value.fromInt32(@intCast(calendarFields(cal, y, m, d).month));
}
pub fn dayValue(cal: temporal.CalendarId, y: i32, m: u32, d: u32) Value {
    return Value.fromInt32(@intCast(calendarFields(cal, y, m, d).day));
}
pub fn daysInMonthValue(cal: temporal.CalendarId, y: i32, m: u32, d: u32) Value {
    return Value.fromInt32(@intCast(calendarFields(cal, y, m, d).days_in_month));
}
pub fn daysInYearValue(cal: temporal.CalendarId, y: i32, m: u32, d: u32) Value {
    return Value.fromInt32(@intCast(calendarFields(cal, y, m, d).days_in_year));
}
pub fn dayOfYearValue(cal: temporal.CalendarId, y: i32, m: u32, d: u32) Value {
    return Value.fromInt32(@intCast(calendarFields(cal, y, m, d).day_of_year));
}
pub fn monthsInYearValue(cal: temporal.CalendarId, y: i32, m: u32, d: u32) Value {
    return Value.fromInt32(@intCast(calendarFields(cal, y, m, d).months_in_year));
}
pub fn inLeapYearValue(cal: temporal.CalendarId, y: i32, m: u32, d: u32) Value {
    return Value.fromBool(calendarFields(cal, y, m, d).in_leap_year);
}
pub fn monthCodeValue(realm: *Realm, cal: temporal.CalendarId, y: i32, m: u32, d: u32) NativeError!Value {
    const cf = calendarFields(cal, y, m, d);
    var mo = cf.month;
    var leap_suffix = false;
    if (computedCal(cal)) |c| {
        // Lunisolar leap years insert a leap month whose code repeats the
        // preceding month with an "L" suffix; later months keep their
        // common-year codes (ordinal - 1).
        const code = compCodeForOrd(c.family, cf.year, cf.month);
        if (code < 0) {
            leap_suffix = true;
            mo = @intCast(-code);
        } else {
            mo = @intCast(code);
        }
    }
    var mc: [4]u8 = .{ 'M', '0' + @as(u8, @intCast(mo / 10)), '0' + @as(u8, @intCast(mo % 10)), 'L' };
    const len: usize = if (leap_suffix) 4 else 3;
    const js = realm.heap.allocateString(mc[0..len]) catch return error.OutOfMemory;
    return Value.fromString(js);
}
pub fn eraValue(realm: *Realm, cal: temporal.CalendarId, y: i32, m: u32, d: u32) NativeError!Value {
    const e = calendarFields(cal, y, m, d).era orelse return Value.undefined_;
    const js = realm.heap.allocateString(e) catch return error.OutOfMemory;
    return Value.fromString(js);
}
pub fn eraYearValue(cal: temporal.CalendarId, y: i32, m: u32, d: u32) Value {
    const ey = calendarFields(cal, y, m, d).era_year orelse return Value.undefined_;
    return Value.fromInt32(ey);
}

const CalYmd = struct { year: i64, month: u32, day: u32 };

/// Inverse of calendarFields for a computational-calendar (year, month, day)
/// field triple → the ISO date, honouring `reject` (else constrain month ∈
/// [1, monthsInYear] and day to the month length). Returns null under reject for
/// an out-of-range field, or for a gregorian-month calendar (those regulate via
/// ISO directly and never reach here).
pub fn computedToIso(cal: temporal.CalendarId, cal_y: i64, cal_m: i64, cal_d: i64, reject: bool) ?CalYmd {
    const c = computedCal(cal) orelse return null;
    if ((c.family == .chinese or c.family == .dangi) and !lunisolarInRange(cal_y)) return null;
    const miy: i64 = compMonthsInYear(c.family, cal_y);
    var m = cal_m;
    if (m < 1 or m > miy) {
        if (reject) return null;
        m = std.math.clamp(m, 1, miy);
    }
    const dim: i64 = compDaysInMonth(c.family, cal_y, @intCast(m));
    var d = cal_d;
    if (d < 1 or d > dim) {
        if (reject) return null;
        d = std.math.clamp(d, 1, dim);
    }
    const ymd = temporal.civilFromDays(compToDays(c, cal_y, m, d));
    return .{ .year = ymd.year, .month = ymd.month, .day = ymd.day };
}

/// Whether `cal` needs the computational add/from path (a non-gregorian month
/// structure: the Islamic tabular pair or the Coptic-type pair).
pub fn isComputedCalendar(cal: temporal.CalendarId) bool {
    return computedCal(cal) != null;
}

/// Calendar-aware add for the computational calendars: add years + months in
/// the calendar's own terms (normalising the month over monthsInYear,
/// constraining or rejecting the day to the target month length), then add
/// weeks + days as a plain day offset. Returns the resulting ISO date.
/// Gregorian-month calendars don't use this (ISO months equal their calendar
/// months, so addISODate already suffices).
pub fn addComputed(cal: temporal.CalendarId, iso_y: i32, iso_m: u32, iso_d: u32, add_y: i64, add_mo: i64, add_w: i64, add_d: i64, reject: bool) ?CalYmd {
    const c = computedCal(cal) orelse return null;
    const start = compFromDays(c, temporal.daysFromCivil(iso_y, iso_m, iso_d));
    const y0 = start.year + add_y;
    // Adding years keeps the month CODE (common-year Adar "M06" + 1 year lands
    // on leap-year Adar II, ordinal 7); a leap-only month ("M05L") landing in a
    // common year rejects, or constrains to Adar. A 13th ordinal never carries
    // across (its code is M12, which every year has).
    const start_code = compCodeForOrd(c.family, start.year, start.month);
    const m_ord: i64 = compOrdForCode(c.family, y0, start_code) orelse blk: {
        if (reject and add_y != 0) return null;
        break :blk constrainLeapOrd(c.family, y0, start_code);
    };
    const bym = balanceCompYearMonth(c.family, y0, m_ord + add_mo);
    const y = bym.year;
    const m: i64 = bym.month;
    const dim: i64 = compDaysInMonth(c.family, y, @intCast(m));
    var d: i64 = start.day;
    if (d > dim) {
        if (reject) return null;
        d = dim;
    }
    const days = compToDays(c, y, m, d) + add_w * 7 + add_d;
    const ymd = temporal.civilFromDays(days);
    return .{ .year = ymd.year, .month = ymd.month, .day = ymd.day };
}

const CompYearMonth = struct { year: i64, month: i64 };

/// Carry a (possibly far out-of-range) 1-based month into the year, honouring
/// each crossed year's own month count. Any 19 consecutive hebrew years hold
/// exactly 235 months (leap years are fixed residues mod 19 — the Metonic
/// cycle), so huge deltas jump by whole cycles before the per-year walk.
fn balanceCompYearMonth(f: CompFamily, year_in: i64, month_in: i64) CompYearMonth {
    const year_varying = switch (f) {
        .hebrew, .chinese, .dangi => true,
        else => false,
    };
    if (!year_varying) {
        const miy: i64 = compMonthsInYear(f, 0);
        const m0 = month_in - 1;
        return .{ .year = year_in + @divFloor(m0, miy), .month = @mod(m0, miy) + 1 };
    }
    var y = year_in;
    var m0 = month_in - 1; // 0-based
    if (f == .hebrew) {
        // Any 19 consecutive hebrew years hold exactly 235 months (leap years
        // are fixed residues mod 19), so huge deltas jump by whole cycles.
        while (m0 >= 235) : (m0 -= 235) y += 19;
        while (m0 < -235) : (m0 += 235) y -= 19;
    }
    while (m0 >= compMonthsInYear(f, y)) {
        // Outside the chinese/dangi table every year reads as 12 months, so a
        // huge remaining delta jumps in bulk instead of walking year-by-year.
        if (f != .hebrew and !lunisolarInRange(y) and m0 >= 24) {
            const jump = @divFloor(m0, 12) - 1;
            y += jump;
            m0 -= jump * 12;
            continue;
        }
        m0 -= compMonthsInYear(f, y);
        y += 1;
    }
    while (m0 < 0) {
        if (f != .hebrew and !lunisolarInRange(y - 1) and m0 <= -24) {
            const jump = @divFloor(-m0, 12) - 1;
            y -= jump;
            m0 += jump * 12;
            continue;
        }
        y -= 1;
        m0 += compMonthsInYear(f, y);
    }
    return .{ .year = y, .month = m0 + 1 };
}

/// Whether the constrained calendar date (year, month, min(day, monthLen)) lies
/// strictly beyond `target` (a days-since-1970 number) in the `sign` direction.
fn compDateSurpasses(sign: i64, year: i64, month: i64, day: i64, ty: i64, tm: i64, td: i64) bool {
    // Lexicographic (year, month, day) comparison with the RAW start day — no
    // clamp to the candidate month — mirroring isoDateSurpasses. An over-long
    // start day in a shorter candidate month must register as surpassing:
    // coptic M12-28 + 1 month → "M13-28" surpasses M13-05, so the difference is
    // 7 days, not a clamped whole month.
    var c: i64 = 0;
    if (year != ty) {
        c = if (year < ty) -1 else 1;
    } else if (month != tm) {
        c = if (month < tm) -1 else 1;
    } else if (day != td) {
        c = if (day < td) -1 else 1;
    }
    return sign * c > 0;
}

/// Calendar-aware DifferenceISODate for the computational calendars — the
/// year/month components are counted in the calendar's own months (the
/// week/day remainder is a plain day count, calendar-independent). Mirrors
/// temporal.differenceISODate. Used by until/since when smallestUnit is "day"
/// (no calendar rounding); falls back to the ISO difference for any other
/// calendar.
pub fn differenceComputedDate(cal: temporal.CalendarId, d1: temporal.PlainDateRecord, d2: temporal.PlainDateRecord, largest: temporal.LargestUnit) temporal.DurationRecord {
    const c = computedCal(cal) orelse return temporal.differenceISODate(d1, d2, largest);
    const dn1 = temporal.daysFromCivil(d1.iso_year, d1.iso_month, d1.iso_day);
    const dn2 = temporal.daysFromCivil(d2.iso_year, d2.iso_month, d2.iso_day);
    if (dn1 == dn2) return .{};
    const sign: i64 = if (dn2 > dn1) 1 else -1;
    const cd1 = compFromDays(c, dn1);
    const cd2 = compFromDays(c, dn2);

    var years: i64 = 0;
    var months: i64 = 0;
    // Whole-year candidates preserve the month CODE in each candidate year
    // (constraining a leap-only month to Adar), mirroring the code-preserving
    // year add.
    const code1 = compCodeForOrd(c.family, cd1.year, cd1.month);
    const key1 = compCodeKey(code1);
    const key2 = compCodeKey(compCodeForOrd(c.family, cd2.year, cd2.month));
    if (largest == .year or largest == .month) {
        var cand_years: i64 = @as(i64, cd2.year) - @as(i64, cd1.year);
        if (cand_years != 0) cand_years -= sign;
        // A whole-year candidate is dead if it surpasses the target at EITHER
        // granularity: by month-CODE position (M05 < M05L < M06 — Adar I
        // carried backward into a common year surpasses that year's Adar even
        // though constraining lands exactly on it), or by the constrained
        // ordinal with the RAW start day (30 Adar I into a 29-day Adar
        // overshoots by a day). Both mirror CalendarDateAdd's constrain.
        while (true) {
            const cy = cd1.year + cand_years;
            if (compDateSurpasses(sign, cy, key1, 0, cd2.year, key2, 0)) break;
            const ord = compOrdForCode(c.family, cy, code1) orelse constrainLeapOrd(c.family, cy, code1);
            if (compDateSurpasses(sign, cy, ord, cd1.day, cd2.year, cd2.month, cd2.day)) break;
            years = cand_years;
            cand_years += sign;
        }
        const anchor_y = cd1.year + years;
        const anchor_m: i64 = compOrdForCode(c.family, anchor_y, code1) orelse constrainLeapOrd(c.family, anchor_y, code1);
        var cand_months: i64 = sign;
        var inter = compStepMonth(c.family, anchor_y, anchor_m, sign);
        while (!compDateSurpasses(sign, inter.year, inter.month, cd1.day, cd2.year, cd2.month, cd2.day)) {
            months = cand_months;
            cand_months += sign;
            inter = compStepMonth(c.family, inter.year, inter.month, sign);
        }
        if (largest == .month) {
            // Physical month distance of the code-preserving year walk: each
            // crossed year's own month count plus the ordinal shift the code
            // mapping introduces (common Adar M06 → leap Adar II is 13 months).
            var mo_delta: i64 = anchor_m - @as(i64, cd1.month);
            var yy = cd1.year;
            while (yy != anchor_y) {
                if (anchor_y > cd1.year) {
                    mo_delta += compMonthsInYear(c.family, yy);
                    yy += 1;
                } else {
                    yy -= 1;
                    mo_delta -= compMonthsInYear(c.family, yy);
                }
            }
            months += mo_delta;
            years = 0;
        }
    }

    const anchor2_y = cd1.year + years;
    const anchor2_m: i64 = compOrdForCode(c.family, anchor2_y, code1) orelse constrainLeapOrd(c.family, anchor2_y, code1);
    const bym = balanceCompYearMonth(c.family, anchor2_y, anchor2_m + months);
    const dim: i64 = compDaysInMonth(c.family, bym.year, @intCast(bym.month));
    const anchor = compToDays(c, bym.year, bym.month, @min(@as(i64, cd1.day), dim));
    var days: i64 = dn2 - anchor;
    var weeks: i64 = 0;
    if (largest == .week) {
        weeks = @divTrunc(days, 7);
        days -= weeks * 7;
    }
    return .{
        .years = @floatFromInt(years),
        .months = @floatFromInt(months),
        .weeks = @floatFromInt(weeks),
        .days = @floatFromInt(days),
    };
}

/// Calendar-aware DifferenceISODateTime for the computational calendars — the
/// time half and the one-day borrow are calendar-independent; only the date
/// difference is calendar-aware. Mirrors temporal.differenceISODateTime.
pub fn differenceComputedDateTime(cal: temporal.CalendarId, dt1: temporal.PlainDateTimeRecord, dt2: temporal.PlainDateTimeRecord, largest: temporal.LargestUnit) temporal.DurationRecord {
    const time_delta = temporal.timeRecordToNanoseconds(dt2.time()) - temporal.timeRecordToNanoseconds(dt1.time());
    const time_sign: i32 = if (time_delta < 0) -1 else if (time_delta > 0) 1 else 0;
    const date_sign = temporal.compareISODate(dt2.date(), dt1.date());
    var adjusted_date1 = dt1.date();
    var time_rem = time_delta;
    if (time_sign != 0 and time_sign == -date_sign) {
        adjusted_date1 = temporal.addISODate(adjusted_date1, 0, 0, 0, date_sign, false).?;
        time_rem += @as(i128, date_sign) * temporal.ns_per_day;
    }
    const date_largest: temporal.LargestUnit = @enumFromInt(@min(@intFromEnum(largest), @intFromEnum(temporal.LargestUnit.day)));
    const date_diff = differenceComputedDate(cal, adjusted_date1, dt2.date(), date_largest);
    const time_largest: temporal.LargestUnit = @enumFromInt(@max(@intFromEnum(largest), @intFromEnum(temporal.LargestUnit.hour)));
    const time_dur = temporal.balanceTimeDuration(time_rem, time_largest);
    return .{
        .years = date_diff.years,
        .months = date_diff.months,
        .weeks = date_diff.weeks,
        .days = date_diff.days,
        .hours = time_dur.hours,
        .minutes = time_dur.minutes,
        .seconds = time_dur.seconds,
        .milliseconds = time_dur.milliseconds,
        .microseconds = time_dur.microseconds,
        .nanoseconds = time_dur.nanoseconds,
    };
}

/// Calendar-aware AddDateTime for the computational calendars: fold the time
/// duration into the time half (carrying whole days), then add the date part in
/// the calendar's terms. Mirrors temporal.addDateTimeDateChecked.
pub fn addComputedDateTime(base: temporal.PlainDateTimeRecord, dur: temporal.DurationRecord, reject: bool) ?temporal.PlainDateTimeRecord {
    const ns_per_day: i128 = 86_400 * 1_000_000_000;
    const time_ns = temporal.timeRecordToNanoseconds(base.time()) + temporal.timeDurationNanoseconds(dur);
    const day_carry: i64 = @intCast(@divFloor(time_ns, ns_per_day));
    const within = time_ns - @as(i128, day_carry) * ns_per_day;
    const new_time = temporal.nanosecondsToTimeRecord(within);
    const iso = addComputed(
        base.calendar,
        base.iso_year,
        base.iso_month,
        base.iso_day,
        @intFromFloat(dur.years),
        @intFromFloat(dur.months),
        @intFromFloat(dur.weeks),
        @as(i64, @intFromFloat(dur.days)) + day_carry,
        reject,
    ) orelse return null;
    var date = temporal.regulateISODate(iso.year, @intCast(iso.month), @intCast(iso.day), false) orelse return null;
    date.calendar = base.calendar;
    return temporal.PlainDateTimeRecord.combine(date, new_time);
}

/// Calendar-aware AddZonedDateTime for the computational calendars: add the
/// calendar (year/month/week/day) part of the duration to the zone's wall date
/// in the calendar's terms, re-anchor to an instant, then add the exact-time
/// part. Mirrors temporal.addZonedDateTime. Returns the new epoch nanoseconds.
pub fn addComputedZoned(epoch_ns: i128, tz: temporal.TimeZone, calendar: temporal.CalendarId, dur: temporal.DurationRecord, reject: bool) ?i128 {
    const time_ns = temporal.timeDurationNanoseconds(dur);
    if (dur.years == 0 and dur.months == 0 and dur.weeks == 0 and dur.days == 0) {
        return temporal.addInstant(epoch_ns, time_ns);
    }
    const wall = temporal.getISODateTimeFor(tz, epoch_ns);
    const iso = addComputed(
        calendar,
        wall.iso_year,
        wall.iso_month,
        wall.iso_day,
        @intFromFloat(dur.years),
        @intFromFloat(dur.months),
        @intFromFloat(dur.weeks),
        @intFromFloat(dur.days),
        reject,
    ) orelse return null;
    var new_date = temporal.regulateISODate(iso.year, @intCast(iso.month), @intCast(iso.day), false) orelse return null;
    new_date.calendar = calendar;
    const intermediate = temporal.PlainDateTimeRecord.combine(new_date, wall.time());
    if (!temporal.isoDateTimeWithinLimits(intermediate)) return null;
    const intermediate_epoch = temporal.getEpochNanosecondsFor(tz, intermediate) orelse return null;
    return temporal.addInstant(intermediate_epoch, time_ns);
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
