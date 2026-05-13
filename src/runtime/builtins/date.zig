//! §21.4 Date — extracted from `intrinsics.zig` to keep that
//! module focused on the cross-builtin orchestration. Cynic's
//! Date is UTC-only (`getTimezoneOffset` returns 0); the `set*`
//! / `getUTC*` setters and getters alias the local-time variants.

const std = @import("std");

const Realm = @import("../realm.zig").Realm;
const Value = @import("../value.zig").Value;
const JSString = @import("../string.zig").JSString;
const JSObject = @import("../object.zig").JSObject;
const JSFunction = @import("../function.zig").JSFunction;
const NativeError = @import("../function.zig").NativeError;
const heap_mod = @import("../heap.zig");
const intrinsics = @import("../intrinsics.zig");
const installConstructor = intrinsics.installConstructor;
const installNativeMethod = intrinsics.installNativeMethod;
const installNativeMethodOnProto = intrinsics.installNativeMethodOnProto;
const numberFromI64 = intrinsics.numberFromI64;
const coerceToNumber = intrinsics.coerceToNumber;
const throwTypeError = intrinsics.throwTypeError;
const throwRangeError = intrinsics.throwRangeError;
const argOr = intrinsics.argOr;

// ── §21.4 Date ──────────────────────────────────────────────────────────────

pub fn install(realm: *Realm) !void {
    // Date is callable both ways (`new Date()` constructs;
    // `Date()` returns a string). Mark `is_class = false` so
    // `is_class_constructor` stays at its default — the
    // class-only-via-new check doesn't apply.
    const r = try installConstructor(realm, .{
        .name = "Date", .ctor = dateConstructor, .arity = 7,
        .is_class = false,
        // §21.4.4 — `[object Date]` via @@toStringTag.
        .to_string_tag = "Date",
    });
    const fn_obj = r.ctor;
    const proto = r.proto;

    // Static methods.
    try installNativeMethod(realm, fn_obj, "now", dateNow, 0);
    try installNativeMethod(realm, fn_obj, "parse", dateParse, 1);
    try installNativeMethod(realm, fn_obj, "UTC", dateUTC, 7);

    // Instance methods.
    try installNativeMethodOnProto(realm, proto, "getTime", dateGetTime, 0);
    try installNativeMethodOnProto(realm, proto, "valueOf", dateGetTime, 0);
    try installNativeMethodOnProto(realm, proto, "toString", dateToString, 0);
    try installNativeMethodOnProto(realm, proto, "toISOString", dateToISOString, 0);
    try installNativeMethodOnProto(realm, proto, "toJSON", dateToISOString, 1);
    try installNativeMethodOnProto(realm, proto, "getFullYear", dateGetFullYear, 0);
    try installNativeMethodOnProto(realm, proto, "getMonth", dateGetMonth, 0);
    try installNativeMethodOnProto(realm, proto, "getDate", dateGetDate, 0);
    try installNativeMethodOnProto(realm, proto, "getDay", dateGetDay, 0);
    try installNativeMethodOnProto(realm, proto, "getHours", dateGetHours, 0);
    try installNativeMethodOnProto(realm, proto, "getMinutes", dateGetMinutes, 0);
    try installNativeMethodOnProto(realm, proto, "getSeconds", dateGetSeconds, 0);
    try installNativeMethodOnProto(realm, proto, "getMilliseconds", dateGetMs, 0);
    try installNativeMethodOnProto(realm, proto, "getTimezoneOffset", dateGetTzOffset, 0);
    try installNativeMethodOnProto(realm, proto, "getUTCFullYear", dateGetFullYear, 0);
    try installNativeMethodOnProto(realm, proto, "getUTCMonth", dateGetMonth, 0);
    try installNativeMethodOnProto(realm, proto, "getUTCDate", dateGetDate, 0);
    try installNativeMethodOnProto(realm, proto, "getUTCDay", dateGetDay, 0);
    try installNativeMethodOnProto(realm, proto, "getUTCHours", dateGetHours, 0);
    try installNativeMethodOnProto(realm, proto, "getUTCMinutes", dateGetMinutes, 0);
    try installNativeMethodOnProto(realm, proto, "getUTCSeconds", dateGetSeconds, 0);
    try installNativeMethodOnProto(realm, proto, "getUTCMilliseconds", dateGetMs, 0);

    // Setters — modify the instance's `[[DateValue]]`
    // and return the new ms timestamp. UTC variants alias the
    // local-time setters since Cynic's date math is UTC-only
    // (matches `getTimezoneOffset → 0`).
    try installNativeMethodOnProto(realm, proto, "setTime", dateSetTime, 1);
    try installNativeMethodOnProto(realm, proto, "setMilliseconds", dateSetMs, 1);
    try installNativeMethodOnProto(realm, proto, "setSeconds", dateSetSeconds, 2);
    try installNativeMethodOnProto(realm, proto, "setMinutes", dateSetMinutes, 3);
    try installNativeMethodOnProto(realm, proto, "setHours", dateSetHours, 4);
    try installNativeMethodOnProto(realm, proto, "setDate", dateSetDate, 1);
    try installNativeMethodOnProto(realm, proto, "setMonth", dateSetMonth, 2);
    try installNativeMethodOnProto(realm, proto, "setFullYear", dateSetFullYear, 3);
    try installNativeMethodOnProto(realm, proto, "setUTCMilliseconds", dateSetMs, 1);
    try installNativeMethodOnProto(realm, proto, "setUTCSeconds", dateSetSeconds, 2);
    try installNativeMethodOnProto(realm, proto, "setUTCMinutes", dateSetMinutes, 3);
    try installNativeMethodOnProto(realm, proto, "setUTCHours", dateSetHours, 4);
    try installNativeMethodOnProto(realm, proto, "setUTCDate", dateSetDate, 1);
    try installNativeMethodOnProto(realm, proto, "setUTCMonth", dateSetMonth, 2);
    try installNativeMethodOnProto(realm, proto, "setUTCFullYear", dateSetFullYear, 3);

    // §B.2.4 — `toGMTString` is a no-cost alias of
    // `toUTCString`; we ship it. `getYear` (returns
    // year - 1900) and `setYear` (Y2K-quirky) are
    // intentionally NOT installed — pre-Y2K legacy that
    // doesn't make sense on modern non-browser hosts.
    try installNativeMethodOnProto(realm, proto, "toGMTString", dateToUTCString, 0);
    try installNativeMethodOnProto(realm, proto, "toUTCString", dateToUTCString, 0);
    try installNativeMethodOnProto(realm, proto, "toDateString", dateToDateString, 0);
    try installNativeMethodOnProto(realm, proto, "toTimeString", dateToTimeString, 0);
    try installNativeMethodOnProto(realm, proto, "toLocaleString", dateToString, 0);
    try installNativeMethodOnProto(realm, proto, "toLocaleDateString", dateToDateString, 0);
    try installNativeMethodOnProto(realm, proto, "toLocaleTimeString", dateToTimeString, 0);

    // §21.4.4.45 Date.prototype[@@toPrimitive] — overrides the
    // default ordinary toPrimitive to flip "default" → "string"
    // (Date is the one builtin where unhinted primitive coercion
    // prefers string, so `${date}` and `Date + ""` work).
    try installNativeMethodOnProto(realm, proto, "@@toPrimitive", dateToPrimitive, 1);
}

fn dateToPrimitive(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    if (heap_mod.valueAsPlainObject(this_value) == null) {
        return throwTypeError(realm, "Date.prototype[@@toPrimitive] called on non-object");
    }
    const hint_v = argOr(args, 0, Value.undefined_);
    const hint: enum { number, string } = blk: {
        if (hint_v.isString()) {
            const s: *JSString = @ptrCast(@alignCast(hint_v.asString()));
            if (std.mem.eql(u8, s.bytes, "string")) break :blk .string;
            if (std.mem.eql(u8, s.bytes, "default")) break :blk .string; // Date defaults to string.
            if (std.mem.eql(u8, s.bytes, "number")) break :blk .number;
        }
        return throwTypeError(realm, "Date.prototype[@@toPrimitive]: invalid hint");
    };
    return switch (hint) {
        .string => dateToString(realm, this_value, &.{}),
        .number => dateGetTime(realm, this_value, &.{}),
    };
}

// (dateToDateString / dateToTimeString — moved below
// dateToString to keep the spec-formatted variants together.
// Previous YYYY-MM-DD / HH:mm:ss implementations were wrong:
// §21.4.4.{35,42} mandate the locale-fixed English forms.)

// ── Date setters (§21.4.4 — UTC-only since `getTimezoneOffset` is 0) ────────

/// Pre-coerce-and-snapshot helper for the §21.4.4 setters. Spec
/// order is: read [[DateValue]] (snapshot), then ? ToNumber each
/// *present* argument in source order, *then* check whether the
/// snapshot was NaN. Side-effects in valueOf can mutate the
/// receiver's [[DateValue]] mid-coercion (test262
/// `date-value-read-before-tonumber-when-date-is-{valid,invalid}`)
/// — the snapshot wins. ToNumber abrupt-completes propagate.
///
/// `arity` is the number of arguments the setter consumes; the
/// returned `coerced` array has exactly that many entries, with
/// indices ≥ args.len filled with NaN (a sentinel for "not
/// present" — distinct from a present `undefined`, which ToNumber
/// also turns into NaN, but presence is tracked separately via
/// `present_count`).
const SetterPrelude = struct {
    inst: *JSObject,
    snapshot: f64,
    coerced: [4]f64,
    present_count: usize,
};

fn setterPrelude(realm: *Realm, this_value: Value, args: []const Value, arity: usize) NativeError!SetterPrelude {
    const inst = heap_mod.valueAsPlainObject(this_value) orelse
        return throwTypeError(realm, "Date.prototype setter called on non-Date");
    const snapshot = inst.date_ms orelse
        return throwTypeError(realm, "Date.prototype setter called on non-Date");
    var coerced: [4]f64 = .{ std.math.nan(f64), std.math.nan(f64), std.math.nan(f64), std.math.nan(f64) };
    const present = @min(args.len, arity);
    var i: usize = 0;
    while (i < present) : (i += 1) {
        const v = try intrinsics.toNumber(realm, args[i]);
        coerced[i] = if (v.isInt32()) @as(f64, @floatFromInt(v.asInt32())) else v.asDouble();
    }
    return .{ .inst = inst, .snapshot = snapshot, .coerced = coerced, .present_count = present };
}

/// §21.4.1.31 TimeClip — abs(t) > 8.64e15 or non-finite ⇒ NaN,
/// otherwise ToInteger(t).
fn timeClip(t: f64) f64 {
    if (!std.math.isFinite(t)) return std.math.nan(f64);
    if (@abs(t) > 8.64e15) return std.math.nan(f64);
    return @trunc(t) + 0.0; // Normalize -0 to +0 via the +0.0.
}

fn dateSetTime(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const inst = heap_mod.valueAsPlainObject(this_value) orelse
        return throwTypeError(realm, "Date.prototype.setTime called on non-Date");
    if (inst.date_ms == null) return throwTypeError(realm, "Date.prototype.setTime called on non-Date");
    const arg_v = if (args.len == 0) Value.undefined_ else args[0];
    const v = try intrinsics.toNumber(realm, arg_v);
    const t = if (v.isInt32()) @as(f64, @floatFromInt(v.asInt32())) else v.asDouble();
    const clipped = timeClip(t);
    inst.date_ms = clipped;
    return Value.fromDouble(clipped);
}

fn dateSetMs(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const p = try setterPrelude(realm, this_value, args, 1);
    const cur = p.snapshot;
    if (std.math.isNan(cur)) return Value.fromDouble(cur);
    const new_ms_part = p.coerced[0];
    const old_ms_part = @floor(@mod(cur, 1000.0));
    const new_ms = timeClip(cur - old_ms_part + new_ms_part);
    p.inst.date_ms = new_ms;
    return Value.fromDouble(new_ms);
}

fn dateSetSeconds(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const p = try setterPrelude(realm, this_value, args, 2);
    const cur = p.snapshot;
    if (std.math.isNan(cur)) return Value.fromDouble(cur);
    const sec = p.coerced[0];
    const ms_arg = if (p.present_count > 1) p.coerced[1] else @floor(@mod(cur, 1000.0));
    const day_minute_part = @floor(cur / 60000.0) * 60000.0;
    const new_ms = timeClip(day_minute_part + sec * 1000.0 + ms_arg);
    p.inst.date_ms = new_ms;
    return Value.fromDouble(new_ms);
}

fn dateSetMinutes(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const p = try setterPrelude(realm, this_value, args, 3);
    const cur = p.snapshot;
    if (std.math.isNan(cur)) return Value.fromDouble(cur);
    const minute = p.coerced[0];
    const sec = if (p.present_count > 1) p.coerced[1] else @floor(@mod(cur, 60000.0) / 1000.0);
    const ms_arg = if (p.present_count > 2) p.coerced[2] else @floor(@mod(cur, 1000.0));
    const hour_part = @floor(cur / 3600000.0) * 3600000.0;
    const new_ms = timeClip(hour_part + minute * 60000.0 + sec * 1000.0 + ms_arg);
    p.inst.date_ms = new_ms;
    return Value.fromDouble(new_ms);
}

fn dateSetHours(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const p = try setterPrelude(realm, this_value, args, 4);
    const cur = p.snapshot;
    if (std.math.isNan(cur)) return Value.fromDouble(cur);
    const hour = p.coerced[0];
    const minute = if (p.present_count > 1) p.coerced[1] else @floor(@mod(cur, 3600000.0) / 60000.0);
    const sec = if (p.present_count > 2) p.coerced[2] else @floor(@mod(cur, 60000.0) / 1000.0);
    const ms_arg = if (p.present_count > 3) p.coerced[3] else @floor(@mod(cur, 1000.0));
    const day_part = @floor(cur / 86400000.0) * 86400000.0;
    const new_ms = timeClip(day_part + hour * 3600000.0 + minute * 60000.0 + sec * 1000.0 + ms_arg);
    p.inst.date_ms = new_ms;
    return Value.fromDouble(new_ms);
}

fn dateSetDate(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const p = try setterPrelude(realm, this_value, args, 1);
    const cur = p.snapshot;
    if (std.math.isNan(cur)) return Value.fromDouble(cur);
    const ymd = msToYMD(cur);
    const time_part = @mod(cur, 86400000.0);
    const new_day = p.coerced[0];
    const new_ms = timeClip(ymdToMs(@floatFromInt(ymd.year), @floatFromInt(ymd.month), new_day) * 86400000.0 + time_part);
    p.inst.date_ms = new_ms;
    return Value.fromDouble(new_ms);
}

fn dateSetMonth(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const p = try setterPrelude(realm, this_value, args, 2);
    const cur = p.snapshot;
    if (std.math.isNan(cur)) return Value.fromDouble(cur);
    const ymd = msToYMD(cur);
    const time_part = @mod(cur, 86400000.0);
    const new_month = p.coerced[0];
    const new_day = if (p.present_count > 1) p.coerced[1] else @as(f64, @floatFromInt(ymd.day));
    const new_ms = timeClip(ymdToMs(@floatFromInt(ymd.year), new_month, new_day) * 86400000.0 + time_part);
    p.inst.date_ms = new_ms;
    return Value.fromDouble(new_ms);
}

fn dateSetFullYear(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    // setFullYear is special: per §21.4.4.21, if t is NaN we
    // *don't* return NaN — we treat t as +0 and continue. So no
    // snapshot-NaN bail. Args still coerce in spec order before
    // the t-check.
    const p = try setterPrelude(realm, this_value, args, 3);
    const cur = p.snapshot;
    const ymd = if (std.math.isNan(cur)) YMD{ .year = 1970, .month = 0, .day = 1 } else msToYMD(cur);
    const time_part = if (std.math.isNan(cur)) 0.0 else @mod(cur, 86400000.0);
    const new_year = p.coerced[0];
    const new_month = if (p.present_count > 1) p.coerced[1] else @as(f64, @floatFromInt(ymd.month));
    const new_day = if (p.present_count > 2) p.coerced[2] else @as(f64, @floatFromInt(ymd.day));
    const new_ms = timeClip(ymdToMs(new_year, new_month, new_day) * 86400000.0 + time_part);
    p.inst.date_ms = new_ms;
    return Value.fromDouble(new_ms);
}

const YMD = struct { year: i32, month: i32, day: i32 };

/// Howard Hinnant's "civil_from_days" — same algorithm we use
/// for `getFullYear` / `getMonth` etc. Returns the (year,
/// month-0-indexed, day) for an absolute days-since-epoch.
fn msToYMD(ms: f64) YMD {
    const days_since_epoch = std.math.floor(ms / 86400000.0);
    const z = @as(i64, @intFromFloat(days_since_epoch)) + 719468;
    const era_d: i64 = if (z >= 0) z else z - 146096;
    const era = @divTrunc(era_d, 146097);
    const doe = z - era * 146097;
    const yoe_num = doe - @divTrunc(doe, 1460) + @divTrunc(doe, 36524) - @divTrunc(doe, 146096);
    const yoe = @divTrunc(yoe_num, 365);
    const y = yoe + era * 400;
    const doy = doe - (365 * yoe + @divTrunc(yoe, 4) - @divTrunc(yoe, 100));
    const mp = @divTrunc(5 * doy + 2, 153);
    const d = doy - @divTrunc(153 * mp + 2, 5) + 1;
    const m = if (mp < 10) mp + 3 else mp - 9;
    const year = if (m <= 2) y + 1 else y;
    return .{
        .year = @intCast(year),
        .month = @intCast(m - 1),
        .day = @intCast(d),
    };
}

/// Inverse of `msToYMD` — returns days-since-epoch (as a f64
/// to handle out-of-range values without panicking on i64
/// overflow). Multiply by 86400000 to get ms.
fn ymdToMs(year_f: f64, month_f: f64, day_f: f64) f64 {
    const y_in: f64 = year_f;
    const m_in: f64 = month_f;
    const d_in: f64 = day_f;
    // Normalize month into 0..11, carrying into year.
    const m_offset = std.math.floor(m_in / 12.0);
    const y = y_in + m_offset;
    const m = m_in - m_offset * 12.0;
    // m: 0..11 → spec uses March-based year offset
    const yy = if (m <= 1.0) y - 1.0 else y;
    const era = std.math.floor(yy / 400.0);
    const yoe = yy - era * 400.0;
    const mp = if (m >= 2.0) m - 2.0 else m + 10.0;
    const doy = std.math.floor((153.0 * mp + 2.0) / 5.0) + d_in - 1.0;
    const doe = yoe * 365.0 + std.math.floor(yoe / 4.0) - std.math.floor(yoe / 100.0) + doy;
    const days = era * 146097.0 + doe - 719468.0;
    return days;
}

fn dateConstructor(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const inst = heap_mod.valueAsPlainObject(this_value) orelse return throwTypeError(realm, "Date constructor requires 'new'");
    var ms: f64 = 0;
    if (args.len == 0) {
        ms = currentTimeMs();
    } else if (args.len == 1) {
        // §21.4.2.1 step 3 — `Date(value)`. If value is a Date
        // instance, copy its date_ms slot (skip ToPrimitive).
        // Otherwise, ToPrimitive(value) → if String, parse; else
        // ToNumber.
        const arg = args[0];
        if (heap_mod.valueAsPlainObject(arg)) |o| {
            if (o.date_ms) |dms| {
                inst.date_ms = dms;
                return this_value;
            }
        }
        const prim = try intrinsics.toPrimitive(realm, arg, .default);
        if (prim.isString()) {
            const s_obj: *JSString = @ptrCast(@alignCast(prim.asString()));
            ms = parseIsoDate(s_obj.bytes);
        } else {
            const nv = try intrinsics.toNumber(realm, prim);
            ms = if (nv.isInt32()) @floatFromInt(nv.asInt32()) else nv.asDouble();
        }
    } else {
        // (year, month, day, hours, minutes, seconds, ms) — UTC
        // construction. later punts on full §21.4.1.13 and uses
        // a simple arithmetic mapping (no DST / leap-second
        // weirdness). Years < 100 are NOT offset by 1900.
        const y = numberArg(args, 0, std.math.nan(f64));
        const m = numberArg(args, 1, 0);
        const d = numberArg(args, 2, 1);
        const h = numberArg(args, 3, 0);
        const mi = numberArg(args, 4, 0);
        const sec = numberArg(args, 5, 0);
        const msec = numberArg(args, 6, 0);
        ms = makeUTC(y, m, d, h, mi, sec, msec);
    }
    inst.date_ms = ms;
    return this_value;
}

fn dateNow(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = realm;
    _ = this_value;
    _ = args;
    return Value.fromDouble(currentTimeMs());
}

fn dateParse(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = this_value;
    if (args.len == 0) return Value.fromDouble(std.math.nan(f64));
    const s_value = intrinsics.stringifyArg(realm, args[0]) catch return error.OutOfMemory;
    const s = s_value.bytes;
    // §21.4.1.18 simplified ISO format. Real engines also accept
    // RFC 2822-style ("Mon, 01 Jan 2024 00:00:00 GMT"), but the
    // ISO branch covers nearly every test262 fixture and most
    // real-world `JSON.stringify(new Date()).slice(1,-1)` round
    // trips.
    return Value.fromDouble(parseIsoDate(s));
}

/// §21.4.1.18 Date Time String Format. Accepts:
///   YYYY              — year-only
///   YYYY-MM           — year + month
///   YYYY-MM-DD        — full date
///   YYYY-MM-DDTHH:mm[:ss[.sss]][Z|±HH:mm]   — date + time + tz
///   THH:mm[:ss[.sss]] — time-only (today's date in UTC)
/// Extended-year form `±YYYYYY` (six digits, signed) covers years
/// outside 0001-9999 (e.g. `-000001-01-01T00:00:00Z`).
fn parseIsoDate(src: []const u8) f64 {
    var p: usize = 0;
    if (src.len == 0) return std.math.nan(f64);

    // Year — optional sign + 4 or 6 digits.
    var year_sign: f64 = 1;
    if (p < src.len and (src[p] == '+' or src[p] == '-')) {
        if (src[p] == '-') year_sign = -1;
        p += 1;
        // Expanded year: must be 6 digits.
        const year = parseFixedDigits(src, &p, 6) orelse return std.math.nan(f64);
        if (year_sign == -1 and year == 0) return std.math.nan(f64); // §21.4.1.18 — `-000000` is invalid
        return continueIsoDate(src, p, year_sign * @as(f64, @floatFromInt(year)));
    }
    const year = parseFixedDigits(src, &p, 4) orelse return std.math.nan(f64);
    return continueIsoDate(src, p, @floatFromInt(year));
}

fn continueIsoDate(src: []const u8, start: usize, year: f64) f64 {
    var p = start;
    var month: i64 = 1;
    var day: i64 = 1;
    var hour: f64 = 0;
    var minute: f64 = 0;
    var second: f64 = 0;
    var ms: f64 = 0;
    var tz_offset_min: f64 = 0; // negative = east of UTC

    if (p < src.len and src[p] == '-') {
        p += 1;
        const m = parseFixedDigits(src, &p, 2) orelse return std.math.nan(f64);
        if (m < 1 or m > 12) return std.math.nan(f64);
        month = m;
        if (p < src.len and src[p] == '-') {
            p += 1;
            const d = parseFixedDigits(src, &p, 2) orelse return std.math.nan(f64);
            if (d < 1 or d > 31) return std.math.nan(f64);
            day = d;
        }
    }

    if (p < src.len and src[p] == 'T') {
        p += 1;
        const h = parseFixedDigits(src, &p, 2) orelse return std.math.nan(f64);
        if (h > 24) return std.math.nan(f64);
        hour = @floatFromInt(h);
        if (p >= src.len or src[p] != ':') return std.math.nan(f64);
        p += 1;
        const mi = parseFixedDigits(src, &p, 2) orelse return std.math.nan(f64);
        if (mi > 59) return std.math.nan(f64);
        minute = @floatFromInt(mi);
        if (p < src.len and src[p] == ':') {
            p += 1;
            const sec = parseFixedDigits(src, &p, 2) orelse return std.math.nan(f64);
            if (sec > 59) return std.math.nan(f64);
            second = @floatFromInt(sec);
            if (p < src.len and src[p] == '.') {
                p += 1;
                // Fractional seconds — read 1+ digits, treat as
                // milliseconds (.sss). Per spec exactly 3 digits,
                // but real engines accept any.
                const frac_start = p;
                while (p < src.len and src[p] >= '0' and src[p] <= '9') p += 1;
                if (p == frac_start) return std.math.nan(f64);
                // Convert e.g. "5" → 500ms, "50" → 500ms, "500" → 500ms.
                var ms_f: f64 = 0;
                var mult: f64 = 100.0;
                for (src[frac_start..@min(frac_start + 3, p)]) |c| {
                    ms_f += @as(f64, @floatFromInt(c - '0')) * mult;
                    mult /= 10.0;
                }
                ms = ms_f;
            }
        }

        // Timezone designator.
        if (p < src.len) {
            if (src[p] == 'Z') {
                p += 1;
            } else if (src[p] == '+' or src[p] == '-') {
                const sign: f64 = if (src[p] == '-') 1 else -1; // negate: east of UTC subtracts
                p += 1;
                const tzh = parseFixedDigits(src, &p, 2) orelse return std.math.nan(f64);
                if (p >= src.len or src[p] != ':') return std.math.nan(f64);
                p += 1;
                const tzm = parseFixedDigits(src, &p, 2) orelse return std.math.nan(f64);
                if (tzh > 23 or tzm > 59) return std.math.nan(f64);
                tz_offset_min = sign * (@as(f64, @floatFromInt(tzh * 60 + tzm)));
            } else {
                return std.math.nan(f64);
            }
        } else {
            // §21.4.1.18 step 7 — date-with-time but no TZ
            // designator is interpreted as LOCAL time. Cynic
            // doesn't carry locale; treat as UTC for simplicity
            // (matches V8 behavior in most server timezones).
        }
    }

    if (p != src.len) return std.math.nan(f64);

    const t = makeUTC(year, @floatFromInt(month - 1), @floatFromInt(day), hour, minute, second, ms);
    if (std.math.isNan(t)) return t;
    return t + tz_offset_min * 60000.0;
}

/// Read exactly `n` decimal digits starting at `p.*`; advance
/// `p.*` past them on success. Returns null if there aren't
/// enough digits.
fn parseFixedDigits(src: []const u8, p: *usize, n: usize) ?i64 {
    if (p.* + n > src.len) return null;
    var acc: i64 = 0;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const c = src[p.* + i];
        if (c < '0' or c > '9') return null;
        acc = acc * 10 + @as(i64, c - '0');
    }
    p.* += n;
    return acc;
}

fn dateUTC(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = realm;
    _ = this_value;
    if (args.len == 0) return Value.fromDouble(std.math.nan(f64));
    const y = numberArg(args, 0, std.math.nan(f64));
    const m = numberArg(args, 1, 0);
    const d = numberArg(args, 2, 1);
    const h = numberArg(args, 3, 0);
    const mi = numberArg(args, 4, 0);
    const sec = numberArg(args, 5, 0);
    const msec = numberArg(args, 6, 0);
    return Value.fromDouble(makeUTC(y, m, d, h, mi, sec, msec));
}

fn numberArg(args: []const Value, i: usize, default: f64) f64 {
    if (i >= args.len) return default;
    if (args[i].isUndefined()) return default;
    const v = coerceToNumber(args[i]);
    if (v.isInt32()) return @floatFromInt(v.asInt32());
    return v.asDouble();
}

fn currentTimeMs() f64 {
    // §21.4.1.6 — wall-clock milliseconds since the Unix epoch.
    // Zig 0.16's `std.Io.Clock` requires an `io` handle that
    // natives don't carry; drop down to the libc shim.
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts) != 0) return 0;
    const sec_f: f64 = @floatFromInt(ts.sec);
    const nsec_f: f64 = @floatFromInt(ts.nsec);
    return sec_f * 1000.0 + nsec_f / 1_000_000.0;
}

/// Convert a (y, m, d, h, mi, s, ms) tuple to UTC milliseconds.
/// §21.4.1.13 — simplified: no timezone, no DST. Months are
/// 0-indexed; days 1-indexed.
fn makeUTC(y: f64, m: f64, d: f64, h: f64, mi: f64, s: f64, ms: f64) f64 {
    if (std.math.isNan(y) or std.math.isNan(m) or std.math.isNan(d) or std.math.isNan(h) or std.math.isNan(mi) or std.math.isNan(s) or std.math.isNan(ms)) {
        return std.math.nan(f64);
    }
    if (std.math.isInf(y) or std.math.isInf(m) or std.math.isInf(d)) return std.math.nan(f64);
    // §21.4.1.13 — silently treat "this is too far away to
    // representable" as Invalid Date. test262 fixtures pass
    // huge years (1e21+) to test edge cases; raw `@intFromFloat`
    // panics on those.
    const safe_year_max: f64 = 275760.0; // ~JS spec maximum year
    if (@abs(y) > safe_year_max) return std.math.nan(f64);
    const year_i: i64 = @intFromFloat(@trunc(y));
    const month_i: i64 = @intFromFloat(@trunc(m));
    const day_i: i64 = @intFromFloat(@trunc(d));
    const days = daysFromEpoch(year_i, month_i, day_i);
    const hours_total: f64 = h * 3600000.0 + mi * 60000.0 + s * 1000.0 + ms;
    const days_ms: f64 = @as(f64, @floatFromInt(days)) * 86400000.0;
    return days_ms + hours_total;
}

/// Days from 1970-01-01 (UTC) to (year, month-0-indexed, day-1-indexed).
fn daysFromEpoch(year: i64, month: i64, day: i64) i64 {
    // Howard Hinnant's days_from_civil. Treats March as month 0
    // internally for the leap-day arithmetic. Handles negative
    // years.
    var y = year;
    var m = month;
    if (m < 2) {
        y -= 1;
        m += 12;
    }
    const era = @divFloor(if (y >= 0) y else y - 399, 400);
    const yoe: i64 = y - era * 400;
    const doy: i64 = @divFloor(153 * (m - 2) + 2, 5) + day - 1;
    const doe: i64 = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

const DateParts = struct { year: i64, month: i64, day: i64, weekday: i64, hours: i64, minutes: i64, seconds: i64, ms: i64 };

fn dateParts(ms_v: f64) DateParts {
    if (std.math.isNan(ms_v) or std.math.isInf(ms_v)) {
        return .{ .year = 0, .month = 0, .day = 0, .weekday = 0, .hours = 0, .minutes = 0, .seconds = 0, .ms = 0 };
    }
    const total: i64 = @intFromFloat(@trunc(ms_v));
    var days = @divFloor(total, 86400000);
    var rem = @mod(total, 86400000);
    if (rem < 0) {
        rem += 86400000;
        days -= 1;
    }
    const hours = @divFloor(rem, 3600000);
    rem = @mod(rem, 3600000);
    const minutes = @divFloor(rem, 60000);
    rem = @mod(rem, 60000);
    const seconds = @divFloor(rem, 1000);
    const millis = @mod(rem, 1000);

    // Weekday (1970-01-01 was a Thursday → 4).
    const weekday = @mod(days + 4, 7);
    const wd = if (weekday < 0) weekday + 7 else weekday;

    // Civil from days (inverse of daysFromEpoch).
    const z: i64 = days + 719468;
    const era = @divFloor(if (z >= 0) z else z - 146096, 146097);
    const doe: i64 = z - era * 146097;
    const yoe: i64 = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
    var y: i64 = yoe + era * 400;
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const d_ret = doy - @divFloor(153 * mp + 2, 5) + 1;
    const m_ret: i64 = if (mp < 10) mp + 2 else mp - 10;
    if (m_ret <= 1) y += 1;

    return .{
        .year = y,
        .month = m_ret,
        .day = d_ret,
        .weekday = wd,
        .hours = hours,
        .minutes = minutes,
        .seconds = seconds,
        .ms = millis,
    };
}

fn getDateMs(this_value: Value) ?f64 {
    const obj = heap_mod.valueAsPlainObject(this_value) orelse return null;
    return obj.date_ms;
}

/// §21.4.4.X — every Date.prototype getter requires a brand-
/// checked Date receiver. Calling on a plain object / array /
/// non-Date wrapper throws TypeError per spec.
fn requireDateMs(realm: *Realm, this_value: Value) NativeError!f64 {
    const obj = heap_mod.valueAsPlainObject(this_value) orelse return throwTypeError(realm, "Date.prototype method called on non-Date");
    return obj.date_ms orelse return throwTypeError(realm, "Date.prototype method called on non-Date");
}

fn dateGetTime(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    const ms = try requireDateMs(realm, this_value);
    return Value.fromDouble(ms);
}

fn dateToString(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    const ms = getDateMs(this_value) orelse return throwTypeError(realm, "Date.prototype.toString called on non-Date");
    if (std.math.isNan(ms)) {
        const s = realm.heap.allocateString("Invalid Date") catch return error.OutOfMemory;
        return Value.fromString(s);
    }
    // §21.4.4.41 — `Day Mon DD YYYY HH:mm:ss GMT+0000 (Coordinated Universal Time)`
    // Cynic doesn't carry locale; the timezone is always UTC.
    const p = dateParts(ms);
    var buf: [80]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, "{s} {s} {d:0>2} {d:0>4} {d:0>2}:{d:0>2}:{d:0>2} GMT+0000 (Coordinated Universal Time)", .{
        weekdayName(p.weekday), monthName(p.month), u(p.day), u(p.year), u(p.hours), u(p.minutes), u(p.seconds),
    }) catch return throwRangeError(realm, "Invalid Date");
    const s = realm.heap.allocateString(text) catch return error.OutOfMemory;
    return Value.fromString(s);
}

/// §21.4.4.43 Date.prototype.toUTCString. Format
/// `Day, DD Mon YYYY HH:mm:ss GMT` per the RFC 7231 IMF-fixdate
/// production. (Used as the date format in HTTP headers.)
fn dateToUTCString(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    const ms = getDateMs(this_value) orelse return throwTypeError(realm, "Date.prototype.toUTCString called on non-Date");
    if (std.math.isNan(ms)) {
        const s = realm.heap.allocateString("Invalid Date") catch return error.OutOfMemory;
        return Value.fromString(s);
    }
    const p = dateParts(ms);
    var buf: [64]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, "{s}, {d:0>2} {s} {d:0>4} {d:0>2}:{d:0>2}:{d:0>2} GMT", .{
        weekdayName(p.weekday), u(p.day), monthName(p.month), u(p.year), u(p.hours), u(p.minutes), u(p.seconds),
    }) catch return throwRangeError(realm, "Invalid Date");
    const s = realm.heap.allocateString(text) catch return error.OutOfMemory;
    return Value.fromString(s);
}

/// §21.4.4.35 Date.prototype.toDateString. Format
/// `Day Mon DD YYYY` (locale-fixed English per spec).
fn dateToDateString(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    const ms = getDateMs(this_value) orelse return throwTypeError(realm, "Date.prototype.toDateString called on non-Date");
    if (std.math.isNan(ms)) {
        const s = realm.heap.allocateString("Invalid Date") catch return error.OutOfMemory;
        return Value.fromString(s);
    }
    const p = dateParts(ms);
    var buf: [32]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, "{s} {s} {d:0>2} {d:0>4}", .{
        weekdayName(p.weekday), monthName(p.month), u(p.day), u(p.year),
    }) catch return throwRangeError(realm, "Invalid Date");
    const s = realm.heap.allocateString(text) catch return error.OutOfMemory;
    return Value.fromString(s);
}

/// §21.4.4.42 Date.prototype.toTimeString. Format
/// `HH:mm:ss GMT+0000 (Coordinated Universal Time)`.
fn dateToTimeString(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    const ms = getDateMs(this_value) orelse return throwTypeError(realm, "Date.prototype.toTimeString called on non-Date");
    if (std.math.isNan(ms)) {
        const s = realm.heap.allocateString("Invalid Date") catch return error.OutOfMemory;
        return Value.fromString(s);
    }
    const p = dateParts(ms);
    var buf: [64]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, "{d:0>2}:{d:0>2}:{d:0>2} GMT+0000 (Coordinated Universal Time)", .{
        u(p.hours), u(p.minutes), u(p.seconds),
    }) catch return throwRangeError(realm, "Invalid Date");
    const s = realm.heap.allocateString(text) catch return error.OutOfMemory;
    return Value.fromString(s);
}

/// Convert a non-negative i64 to u64 for `{d:0>N}` formatting.
/// Zig 0.17's signed formatter prints a leading `+` for
/// non-negative values, which corrupts every fixed-width Date
/// component ("+1970-+1-+1T+0..."). The Date parts (year, month,
/// day, hours, minutes, seconds, ms) are all non-negative for
/// any in-range Date, so casting to unsigned is safe.
fn u(v: i64) u64 {
    return @intCast(if (v < 0) 0 else v);
}

const day_names = [_][]const u8{ "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" };
const month_names = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };

fn weekdayName(w: i64) []const u8 {
    if (w < 0 or w > 6) return "???";
    return day_names[@intCast(w)];
}
fn monthName(m: i64) []const u8 {
    if (m < 0 or m > 11) return "???";
    return month_names[@intCast(m)];
}

fn dateToISOString(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    const ms = getDateMs(this_value) orelse return throwTypeError(realm, "Date.prototype.toISOString called on non-Date");
    if (std.math.isNan(ms)) return throwRangeError(realm, "Invalid Date");
    const p = dateParts(ms);
    var buf: [40]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}Z", .{
        u(p.year), u(p.month + 1), u(p.day), u(p.hours), u(p.minutes), u(p.seconds), u(p.ms),
    }) catch return throwRangeError(realm, "Invalid Date");
    const s = realm.heap.allocateString(text) catch return error.OutOfMemory;
    return Value.fromString(s);
}

fn dateGetFullYear(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    const ms = try requireDateMs(realm, this_value);
    if (std.math.isNan(ms)) return Value.fromDouble(std.math.nan(f64));
    return numberFromI64(dateParts(ms).year);
}
fn dateGetMonth(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    const ms = try requireDateMs(realm, this_value);
    if (std.math.isNan(ms)) return Value.fromDouble(std.math.nan(f64));
    return numberFromI64(dateParts(ms).month);
}
fn dateGetDate(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    const ms = try requireDateMs(realm, this_value);
    if (std.math.isNan(ms)) return Value.fromDouble(std.math.nan(f64));
    return numberFromI64(dateParts(ms).day);
}
fn dateGetDay(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    const ms = try requireDateMs(realm, this_value);
    if (std.math.isNan(ms)) return Value.fromDouble(std.math.nan(f64));
    return numberFromI64(dateParts(ms).weekday);
}
fn dateGetHours(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    const ms = try requireDateMs(realm, this_value);
    if (std.math.isNan(ms)) return Value.fromDouble(std.math.nan(f64));
    return numberFromI64(dateParts(ms).hours);
}
fn dateGetMinutes(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    const ms = try requireDateMs(realm, this_value);
    if (std.math.isNan(ms)) return Value.fromDouble(std.math.nan(f64));
    return numberFromI64(dateParts(ms).minutes);
}
fn dateGetSeconds(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    const ms = try requireDateMs(realm, this_value);
    if (std.math.isNan(ms)) return Value.fromDouble(std.math.nan(f64));
    return numberFromI64(dateParts(ms).seconds);
}
fn dateGetMs(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    const ms = try requireDateMs(realm, this_value);
    if (std.math.isNan(ms)) return Value.fromDouble(std.math.nan(f64));
    return numberFromI64(dateParts(ms).ms);
}
fn dateGetTzOffset(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    _ = try requireDateMs(realm, this_value);
    return Value.fromInt32(0); // UTC — Cynic doesn't model timezones at later.
}
