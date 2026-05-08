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
    try installNativeMethodOnProto(realm, proto, "toJSON", dateToISOString, 0);
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
    try installNativeMethodOnProto(realm, proto, "toGMTString", dateToString, 0);
    try installNativeMethodOnProto(realm, proto, "toUTCString", dateToString, 0);
    try installNativeMethodOnProto(realm, proto, "toDateString", dateToDateString, 0);
    try installNativeMethodOnProto(realm, proto, "toTimeString", dateToTimeString, 0);
    try installNativeMethodOnProto(realm, proto, "toLocaleString", dateToString, 0);
    try installNativeMethodOnProto(realm, proto, "toLocaleDateString", dateToDateString, 0);
    try installNativeMethodOnProto(realm, proto, "toLocaleTimeString", dateToTimeString, 0);
}

fn dateToDateString(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    const ms = try requireDateMs(realm, this_value);
    if (std.math.isNan(ms)) {
        const s = realm.heap.allocateString("Invalid Date") catch return error.OutOfMemory;
        return Value.fromString(s);
    }
    const p = dateParts(ms);
    var buf: [40]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, "{d:0>4}-{d:0>2}-{d:0>2}", .{ p.year, p.month + 1, p.day }) catch return throwRangeError(realm, "Invalid Date");
    const s = realm.heap.allocateString(text) catch return error.OutOfMemory;
    return Value.fromString(s);
}

fn dateToTimeString(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    const ms = try requireDateMs(realm, this_value);
    if (std.math.isNan(ms)) {
        const s = realm.heap.allocateString("Invalid Date") catch return error.OutOfMemory;
        return Value.fromString(s);
    }
    const p = dateParts(ms);
    var buf: [40]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, "{d:0>2}:{d:0>2}:{d:0>2}", .{ p.hours, p.minutes, p.seconds }) catch return throwRangeError(realm, "Invalid Date");
    const s = realm.heap.allocateString(text) catch return error.OutOfMemory;
    return Value.fromString(s);
}

// ── Date setters (§21.4.4 — UTC-only since `getTimezoneOffset` is 0) ────────

fn dateNumArg(args: []const Value, i: usize, default_d: f64) f64 {
    if (i >= args.len or args[i].isUndefined()) return default_d;
    const v = coerceToNumber(args[i]);
    return if (v.isInt32()) @floatFromInt(v.asInt32()) else v.asDouble();
}

fn dateSetTime(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = realm;
    const inst = heap_mod.valueAsPlainObject(this_value) orelse return error.NativeThrew;
    if (inst.date_ms == null) return error.NativeThrew;
    const ms = dateNumArg(args, 0, std.math.nan(f64));
    inst.date_ms = ms;
    return Value.fromDouble(ms);
}

fn dateSetMs(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = realm;
    const inst = heap_mod.valueAsPlainObject(this_value) orelse return error.NativeThrew;
    const cur = inst.date_ms orelse return error.NativeThrew;
    if (std.math.isNan(cur)) return Value.fromDouble(cur);
    const new_ms_part = dateNumArg(args, 0, 0);
    const old_ms_part = @floor(@mod(cur, 1000.0));
    const ms = cur - old_ms_part + new_ms_part;
    inst.date_ms = ms;
    return Value.fromDouble(ms);
}

fn dateSetSeconds(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = realm;
    const inst = heap_mod.valueAsPlainObject(this_value) orelse return error.NativeThrew;
    const cur = inst.date_ms orelse return error.NativeThrew;
    if (std.math.isNan(cur)) return Value.fromDouble(cur);
    const sec = dateNumArg(args, 0, 0);
    const ms_arg = dateNumArg(args, 1, @floor(@mod(cur, 1000.0)));
    // Replace the seconds + ms component of cur.
    const day_minute_part = @floor(cur / 60000.0) * 60000.0;
    const new_ms = day_minute_part + sec * 1000.0 + ms_arg;
    inst.date_ms = new_ms;
    return Value.fromDouble(new_ms);
}

fn dateSetMinutes(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = realm;
    const inst = heap_mod.valueAsPlainObject(this_value) orelse return error.NativeThrew;
    const cur = inst.date_ms orelse return error.NativeThrew;
    if (std.math.isNan(cur)) return Value.fromDouble(cur);
    const minute = dateNumArg(args, 0, 0);
    const sec = dateNumArg(args, 1, @floor(@mod(cur, 60000.0) / 1000.0));
    const ms_arg = dateNumArg(args, 2, @floor(@mod(cur, 1000.0)));
    const hour_part = @floor(cur / 3600000.0) * 3600000.0;
    const new_ms = hour_part + minute * 60000.0 + sec * 1000.0 + ms_arg;
    inst.date_ms = new_ms;
    return Value.fromDouble(new_ms);
}

fn dateSetHours(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = realm;
    const inst = heap_mod.valueAsPlainObject(this_value) orelse return error.NativeThrew;
    const cur = inst.date_ms orelse return error.NativeThrew;
    if (std.math.isNan(cur)) return Value.fromDouble(cur);
    const hour = dateNumArg(args, 0, 0);
    const minute = dateNumArg(args, 1, @floor(@mod(cur, 3600000.0) / 60000.0));
    const sec = dateNumArg(args, 2, @floor(@mod(cur, 60000.0) / 1000.0));
    const ms_arg = dateNumArg(args, 3, @floor(@mod(cur, 1000.0)));
    const day_part = @floor(cur / 86400000.0) * 86400000.0;
    const new_ms = day_part + hour * 3600000.0 + minute * 60000.0 + sec * 1000.0 + ms_arg;
    inst.date_ms = new_ms;
    return Value.fromDouble(new_ms);
}

fn dateSetDate(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = realm;
    const inst = heap_mod.valueAsPlainObject(this_value) orelse return error.NativeThrew;
    const cur = inst.date_ms orelse return error.NativeThrew;
    if (std.math.isNan(cur)) return Value.fromDouble(cur);
    // Decompose cur to (year, month, day) then re-encode with new day.
    const ymd = msToYMD(cur);
    const time_part = @mod(cur, 86400000.0);
    const new_day = dateNumArg(args, 0, @floatFromInt(ymd.day));
    const new_ms = ymdToMs(ymd.year, ymd.month, new_day) * 86400000.0 + time_part;
    inst.date_ms = new_ms;
    return Value.fromDouble(new_ms);
}

fn dateSetMonth(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = realm;
    const inst = heap_mod.valueAsPlainObject(this_value) orelse return error.NativeThrew;
    const cur = inst.date_ms orelse return error.NativeThrew;
    if (std.math.isNan(cur)) return Value.fromDouble(cur);
    const ymd = msToYMD(cur);
    const time_part = @mod(cur, 86400000.0);
    const new_month = dateNumArg(args, 0, @floatFromInt(ymd.month));
    const new_day = dateNumArg(args, 1, @floatFromInt(ymd.day));
    const new_ms = ymdToMs(ymd.year, new_month, new_day) * 86400000.0 + time_part;
    inst.date_ms = new_ms;
    return Value.fromDouble(new_ms);
}

fn dateSetFullYear(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = realm;
    const inst = heap_mod.valueAsPlainObject(this_value) orelse return error.NativeThrew;
    const cur = inst.date_ms orelse return error.NativeThrew;
    const ymd = if (std.math.isNan(cur)) YMD{ .year = 1970, .month = 0, .day = 1 } else msToYMD(cur);
    const time_part = if (std.math.isNan(cur)) 0.0 else @mod(cur, 86400000.0);
    const new_year = dateNumArg(args, 0, @floatFromInt(ymd.year));
    const new_month = dateNumArg(args, 1, @floatFromInt(ymd.month));
    const new_day = dateNumArg(args, 2, @floatFromInt(ymd.day));
    const new_ms = ymdToMs(new_year, new_month, new_day) * 86400000.0 + time_part;
    inst.date_ms = new_ms;
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
        const v = coerceToNumber(args[0]);
        ms = if (v.isInt32()) @floatFromInt(v.asInt32()) else v.asDouble();
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
    _ = realm;
    _ = this_value;
    _ = args;
    // later returns NaN — full ISO-8601 parsing is non-trivial.
    return Value.fromDouble(std.math.nan(f64));
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
    return dateToISOString(realm, this_value, &.{});
}

fn dateToISOString(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    const ms = getDateMs(this_value) orelse return throwTypeError(realm, "Date.prototype.toISOString called on non-Date");
    if (std.math.isNan(ms)) return throwRangeError(realm, "Invalid Date");
    const p = dateParts(ms);
    var buf: [40]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}Z", .{
        p.year, p.month + 1, p.day, p.hours, p.minutes, p.seconds, p.ms,
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
