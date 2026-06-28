//! Temporal.PlainTime — constructor, prototype methods, statics, and the
//! ToTemporalTime / regulate / overflow plumbing local to wall-clock time.

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

const PlainTimeRecord = temporal.PlainTimeRecord;
const DurationRecord = temporal.DurationRecord;
const TemporalRecord = temporal.TemporalRecord;

const shared = @import("shared.zig");
const duration_mod = @import("duration.zig");
const instant_mod = @import("instant.zig");

const argDefault0 = shared.argDefault0;
const toIntegerWithTruncation = shared.toIntegerWithTruncation;
const negZero = shared.negZero;
const Overflow = shared.Overflow;
const rejectTime = shared.rejectTime;
const regulateTime = shared.regulateTime;
const getTemporalOverflowOption = shared.getTemporalOverflowOption;
const rejectTemporalLikeObject = shared.rejectTemporalLikeObject;
const getOptionsObject = shared.getOptionsObject;
const getRoundingModeOption = shared.getRoundingModeOption;
const getRoundingIncrementOption = shared.getRoundingIncrementOption;
const getTemporalUnitOption = shared.getTemporalUnitOption;
const requireUnitInRange = shared.requireUnitInRange;
const negateRoundingMode = shared.negateRoundingMode;
const getFractionalSecondDigitsOption = shared.getFractionalSecondDigitsOption;
const toSecondsStringPrecision = shared.toSecondsStringPrecision;
const requireToStringSmallestUnit = shared.requireToStringSmallestUnit;

const toTemporalDuration = duration_mod.toTemporalDuration;
const createTemporalDuration = duration_mod.createTemporalDuration;
const differenceDividend = instant_mod.differenceDividend;

pub fn install(realm: *Realm, ns: *JSObject) !void {
    // §4.2.1 — `new`-only constructor, arity 0 (all 6 components
    // optional, default 0).
    const r = try installConstructor(realm, .{
        .name = "PlainTime",
        .ctor = plainTimeConstructor,
        .arity = 0,
        .is_class = true,
        .set_home_object = true,
        .to_string_tag = "Temporal.PlainTime",
        .install_global = false,
    });
    const fn_obj = r.ctor;
    const proto = r.proto;

    try installNativeGetter(realm, proto, "hour", plainTimeHour);
    try installNativeGetter(realm, proto, "minute", plainTimeMinute);
    try installNativeGetter(realm, proto, "second", plainTimeSecond);
    try installNativeGetter(realm, proto, "millisecond", plainTimeMillisecond);
    try installNativeGetter(realm, proto, "microsecond", plainTimeMicrosecond);
    try installNativeGetter(realm, proto, "nanosecond", plainTimeNanosecond);

    try installNativeMethodOnProto(realm, proto, "with", plainTimeWith, 1);
    try installNativeMethodOnProto(realm, proto, "equals", plainTimeEquals, 1);
    try installNativeMethodOnProto(realm, proto, "toString", plainTimeToString, 0);
    try installNativeMethodOnProto(realm, proto, "toJSON", plainTimeToJSON, 0);
    try installNativeMethodOnProto(realm, proto, "toLocaleString", plainTimeToLocaleString, 0);
    try installNativeMethodOnProto(realm, proto, "valueOf", plainTimeValueOf, 0);
    // Deferred deep-end methods.
    try installNativeMethodOnProto(realm, proto, "add", plainTimeAdd, 1);
    try installNativeMethodOnProto(realm, proto, "subtract", plainTimeSubtract, 1);
    try installNativeMethodOnProto(realm, proto, "round", plainTimeRound, 1);
    try installNativeMethodOnProto(realm, proto, "until", plainTimeUntil, 1);
    try installNativeMethodOnProto(realm, proto, "since", plainTimeSince, 1);

    try installNativeMethod(realm, fn_obj, "from", plainTimeFrom, 1);
    try installNativeMethod(realm, fn_obj, "compare", plainTimeCompare, 2);

    realm.intrinsics.temporal_plain_time_constructor = fn_obj;
    realm.intrinsics.temporal_plain_time_prototype = proto;

    try setNonEnumerable(ns, realm.allocator, "PlainTime", heap_mod.taggedFunction(fn_obj));
}

fn plainTimeConstructor(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const inst = heap_mod.valueAsPlainObject(this_value) orelse
        return throwTypeError(realm, "Temporal.PlainTime constructor requires 'new'");

    const hour = try toIntegerWithTruncation(realm, argDefault0(args, 0));
    const minute = try toIntegerWithTruncation(realm, argDefault0(args, 1));
    const second = try toIntegerWithTruncation(realm, argDefault0(args, 2));
    const millisecond = try toIntegerWithTruncation(realm, argDefault0(args, 3));
    const microsecond = try toIntegerWithTruncation(realm, argDefault0(args, 4));
    const nanosecond = try toIntegerWithTruncation(realm, argDefault0(args, 5));

    const t = try rejectTime(realm, hour, minute, second, millisecond, microsecond, nanosecond);
    try storePlainTime(realm, inst, t);
    return heap_mod.taggedObject(inst);
}

pub fn createTemporalTime(realm: *Realm, t: PlainTimeRecord) NativeError!Value {
    const inst = realm.heap.allocateObject() catch return error.OutOfMemory;
    realm.heap.setObjectPrototype(inst, realm.intrinsics.temporal_plain_time_prototype.?);
    try storePlainTime(realm, inst, t);
    return heap_mod.taggedObject(inst);
}

fn storePlainTime(realm: *Realm, inst: *JSObject, t: PlainTimeRecord) NativeError!void {
    const rec = realm.allocator.create(TemporalRecord) catch return error.OutOfMemory;
    rec.* = .{ .plain_time = t };
    inst.setTemporalRecord(realm.allocator, rec) catch return error.OutOfMemory;
}

pub fn requirePlainTime(realm: *Realm, this_value: Value) NativeError!PlainTimeRecord {
    const obj = heap_mod.valueAsPlainObject(this_value) orelse
        return throwTypeError(realm, "not a Temporal.PlainTime");
    const rec = obj.getTemporalRecord() orelse
        return throwTypeError(realm, "not a Temporal.PlainTime");
    return switch (rec.*) {
        .plain_time => |t| t,
        else => throwTypeError(realm, "not a Temporal.PlainTime"),
    };
}

fn plainTimeHour(realm: *Realm, t: Value, a: []const Value) NativeError!Value {
    _ = a;
    return Value.fromInt32(@intCast((try requirePlainTime(realm, t)).hour));
}
fn plainTimeMinute(realm: *Realm, t: Value, a: []const Value) NativeError!Value {
    _ = a;
    return Value.fromInt32(@intCast((try requirePlainTime(realm, t)).minute));
}
fn plainTimeSecond(realm: *Realm, t: Value, a: []const Value) NativeError!Value {
    _ = a;
    return Value.fromInt32(@intCast((try requirePlainTime(realm, t)).second));
}
fn plainTimeMillisecond(realm: *Realm, t: Value, a: []const Value) NativeError!Value {
    _ = a;
    return Value.fromInt32(@intCast((try requirePlainTime(realm, t)).millisecond));
}
fn plainTimeMicrosecond(realm: *Realm, t: Value, a: []const Value) NativeError!Value {
    _ = a;
    return Value.fromInt32(@intCast((try requirePlainTime(realm, t)).microsecond));
}
fn plainTimeNanosecond(realm: *Realm, t: Value, a: []const Value) NativeError!Value {
    _ = a;
    return Value.fromInt32(@intCast((try requirePlainTime(realm, t)).nanosecond));
}

fn plainTimeWith(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const base = try requirePlainTime(realm, this_value);
    const like = argOr(args, 0, Value.undefined_);
    const obj = heap_mod.valueAsPlainObject(like) orelse
        return throwTypeError(realm, "PlainTime-like must be an object");

    // §4.5.x RejectTemporalLikeObject — a property bag carrying a
    // `calendar` or `timeZone` own property (or a branded Temporal
    // value) is not a plain time-like and is rejected. The two
    // reads happen first per the order-of-operations fixture.
    try rejectTemporalLikeObject(realm, obj);

    // Start from the receiver's fields (as f64 so a present partial
    // value can override).
    var hour: f64 = @floatFromInt(base.hour);
    var minute: f64 = @floatFromInt(base.minute);
    var second: f64 = @floatFromInt(base.second);
    var millisecond: f64 = @floatFromInt(base.millisecond);
    var microsecond: f64 = @floatFromInt(base.microsecond);
    var nanosecond: f64 = @floatFromInt(base.nanosecond);

    var any = false;
    const Field = struct { key: []const u8, ptr: *f64 };
    var fields = [_]Field{
        .{ .key = "hour", .ptr = &hour },
        .{ .key = "microsecond", .ptr = &microsecond },
        .{ .key = "millisecond", .ptr = &millisecond },
        .{ .key = "minute", .ptr = &minute },
        .{ .key = "nanosecond", .ptr = &nanosecond },
        .{ .key = "second", .ptr = &second },
    };
    for (&fields) |f| {
        const v = try getPropertyChain(realm, obj, f.key);
        if (!v.isUndefined()) {
            any = true;
            f.ptr.* = try toIntegerWithTruncation(realm, v);
        }
    }
    if (!any) return throwTypeError(realm, "PlainTime-like must have at least one time property");

    // §4.3.x step — the overflow option is read AFTER every field
    // (the order-of-operations fixture pins this sequence).
    const overflow = try getTemporalOverflowOption(realm, argOr(args, 1, Value.undefined_));
    const t = try regulateTime(realm, hour, minute, second, millisecond, microsecond, nanosecond, overflow);
    return createTemporalTime(realm, t);
}

/// §4.3.x Temporal.PlainTime.prototype.equals ( other ).
fn plainTimeEquals(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const a = try requirePlainTime(realm, this_value);
    const b = try toTemporalTime(realm, argOr(args, 0, Value.undefined_), Value.undefined_);
    return Value.fromBool(temporal.compareTime(a, b) == 0);
}

/// §4.3.x Temporal.PlainTime.prototype.toString — read the
/// `fractionalSecondDigits` / `roundingMode` / `smallestUnit` options (in
/// that order, each read before `smallestUnit` is validated), round the
/// time to the resulting precision (any whole-day carry is discarded — a
/// PlainTime has no date), and format.
fn plainTimeToString(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const t = try requirePlainTime(realm, this_value);
    const options = argOr(args, 0, Value.undefined_);
    const frac = try getFractionalSecondDigitsOption(realm, options);
    const opts_obj = try getOptionsObject(realm, options);
    const mode = try getRoundingModeOption(realm, opts_obj, .trunc);
    const smallest = try getTemporalUnitOption(realm, opts_obj, "smallestUnit");
    try requireToStringSmallestUnit(realm, smallest);

    const prec = toSecondsStringPrecision(smallest, frac);
    const rt = temporal.roundTime(t, prec.unit, prec.increment, mode);
    var buf: [64]u8 = undefined;
    const s = temporal.plainTimeToString(rt.time, &buf, prec.precision);
    const js = realm.heap.allocateString(s) catch return error.OutOfMemory;
    return Value.fromString(js);
}

fn plainTimeToJSON(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    const t = try requirePlainTime(realm, this_value);
    var buf: [64]u8 = undefined;
    const s = temporal.plainTimeToString(t, &buf, .auto);
    const js = realm.heap.allocateString(s) catch return error.OutOfMemory;
    return Value.fromString(js);
}

fn plainTimeToLocaleString(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    // §4.3.x — FormatDateTime via DateTimeFormat when CLDR is present; without
    // it (no `Intl`) fall back to the ISO string.
    if (@import("../../cldr.zig").available)
        return @import("../intl.zig").temporalToLocaleString(realm, this_value, args);
    return plainTimeToJSON(realm, this_value, args);
}

fn plainTimeValueOf(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = this_value;
    _ = args;
    return throwTypeError(realm, "Called valueOf on a Temporal.PlainTime; use compare() instead");
}

/// §4.5.x ToTemporalTime — accept a PlainTime (copy), an object
/// (time record + overflow regulation), or a string (ISO time
/// parse). `options` carries the `overflow` option (default
/// `constrain`); the copy/string paths validate it but ignore the
/// overflow value, matching the spec.
pub fn toTemporalTime(realm: *Realm, item: Value, options: Value) NativeError!PlainTimeRecord {
    if (heap_mod.valueAsPlainObject(item)) |obj| {
        if (obj.getTemporalRecord()) |rec| {
            switch (rec.*) {
                .plain_time => |t| {
                    // Validate (and ignore) options on the copy path.
                    _ = try getTemporalOverflowOption(realm, options);
                    return t;
                },
                // §4.5.x ToTemporalTime — a PlainDateTime / ZonedDateTime
                // converts via its internal slots, never the user-facing
                // getters: the time part of the ISO date-time (the
                // ZonedDateTime first resolved to wall-clock via
                // GetISODateTimeFor).
                .plain_date_time => |pdt| {
                    _ = try getTemporalOverflowOption(realm, options);
                    return pdt.time();
                },
                .zoned_date_time => |zdt| {
                    const iso = temporal.getISODateTimeFor(zdt.time_zone, zdt.epoch_ns);
                    _ = try getTemporalOverflowOption(realm, options);
                    return iso.time();
                },
                else => {},
            }
        }
        // Object — complete time record (absent fields default 0).
        var hour: f64 = 0;
        var minute: f64 = 0;
        var second: f64 = 0;
        var millisecond: f64 = 0;
        var microsecond: f64 = 0;
        var nanosecond: f64 = 0;
        var any = false;
        const Field = struct { key: []const u8, ptr: *f64 };
        var fields = [_]Field{
            .{ .key = "hour", .ptr = &hour },
            .{ .key = "microsecond", .ptr = &microsecond },
            .{ .key = "millisecond", .ptr = &millisecond },
            .{ .key = "minute", .ptr = &minute },
            .{ .key = "nanosecond", .ptr = &nanosecond },
            .{ .key = "second", .ptr = &second },
        };
        for (&fields) |f| {
            const v = try getPropertyChain(realm, obj, f.key);
            if (!v.isUndefined()) {
                any = true;
                f.ptr.* = try toIntegerWithTruncation(realm, v);
            }
        }
        if (!any) return throwTypeError(realm, "PlainTime-like must have at least one time property");
        const overflow = try getTemporalOverflowOption(realm, options);
        return regulateTime(realm, hour, minute, second, millisecond, microsecond, nanosecond, overflow);
    }
    if (!item.isString()) {
        return throwTypeError(realm, "Temporal.PlainTime.from expects an object or string");
    }
    // §4.5.x ToTemporalTime string path — `ParseTemporalTimeString`
    // runs BEFORE `GetTemporalOverflowOption`, so an invalid string
    // throws RangeError even when the options argument is a wrong
    // type (which would otherwise throw TypeError). `options-wrong-
    // type.js` pins this order with `from("T99:99", badOptions)`.
    const s: *JSString = @ptrCast(@alignCast(item.asString()));
    const t = temporal.parseTemporalTimeString(s.flatBytes()) catch |e| switch (e) {
        // Both Invalid and UTCDesignator surface as RangeError per
        // §4.5.x; the distinct error tags let the messages differ.
        error.UTCDesignator => return throwRangeError(realm, "Z designator is not valid for a PlainTime"),
        error.Invalid => return throwRangeError(realm, "invalid ISO 8601 time string"),
    };
    _ = try getTemporalOverflowOption(realm, options);
    return t;
}

/// §4.2.2 Temporal.PlainTime.from ( item [, options] ). The
/// `overflow` option (default `constrain`) regulates an object
/// argument's fields; the copy / string paths validate it but ignore
/// the value.
fn plainTimeFrom(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = this_value;
    const t = try toTemporalTime(realm, argOr(args, 0, Value.undefined_), argOr(args, 1, Value.undefined_));
    return createTemporalTime(realm, t);
}

/// §4.2.3 Temporal.PlainTime.compare ( one, two ).
fn plainTimeCompare(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = this_value;
    const a = try toTemporalTime(realm, argOr(args, 0, Value.undefined_), Value.undefined_);
    const b = try toTemporalTime(realm, argOr(args, 1, Value.undefined_), Value.undefined_);
    return Value.fromInt32(temporal.compareTime(a, b));
}

/// §4.5.x AddDurationToTime — add (`sign` +1) or subtract (−1) a
/// duration's time part to a PlainTime, wrapping mod 24 h. A PlainTime
/// has no date, so the duration's calendar units (years/months/weeks/
/// days) are ignored, not rejected.
fn plainTimeAddSubtract(realm: *Realm, this_value: Value, duration_like: Value, sign: i128) NativeError!Value {
    const base = try requirePlainTime(realm, this_value);
    const d = try toTemporalDuration(realm, duration_like);
    if (!temporal.isValidDuration(d)) return throwRangeError(realm, "Duration values are out of range");
    const total = temporal.timeRecordToNanoseconds(base) + temporal.timeDurationNanoseconds(d) * sign;
    const wrapped = @mod(total, @as(i128, 86_400_000_000_000));
    return createTemporalTime(realm, temporal.nanosecondsToTimeRecord(wrapped));
}

fn plainTimeAdd(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    return plainTimeAddSubtract(realm, this_value, argOr(args, 0, Value.undefined_), 1);
}

fn plainTimeSubtract(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    return plainTimeAddSubtract(realm, this_value, argOr(args, 0, Value.undefined_), -1);
}

/// §4.5.x Temporal.PlainTime.prototype.round ( roundTo ). String
/// shorthand for `{ smallestUnit }`; smallestUnit required (hour..ns).
/// A rounding that reaches 24 h wraps back to 00:00.
fn plainTimeRound(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const t = try requirePlainTime(realm, this_value);
    const round_to = argOr(args, 0, Value.undefined_);
    if (round_to.isUndefined()) {
        return throwTypeError(realm, "Temporal.PlainTime.prototype.round requires a smallestUnit");
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
    try requireUnitInRange(realm, unit, .hour, .nanosecond);
    // §4.3.x ValidateTemporalRoundingIncrement(increment,
    // MaximumTemporalDurationRoundingIncrement(smallestUnit), false): the
    // increment must divide the next-larger unit and stay strictly below
    // it (hour < 24, minute/second < 60, sub-second < 1000) — NOT the
    // per-day "inclusive" rule Instant.round uses.
    if (!temporal.validateRoundingIncrement(increment, differenceDividend(unit), false)) {
        return throwRangeError(realm, "roundingIncrement is out of range for the smallestUnit");
    }
    const rounded = temporal.roundToIncrement(temporal.timeRecordToNanoseconds(t), increment * temporal.unitNanoseconds(unit), mode);
    const wrapped = @mod(rounded, @as(i128, 86_400_000_000_000));
    return createTemporalTime(realm, temporal.nanosecondsToTimeRecord(wrapped));
}

fn plainTimeUntil(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    return differenceTemporalTime(realm, this_value, args, false);
}

fn plainTimeSince(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    return differenceTemporalTime(realm, this_value, args, true);
}

/// §4.5.x DifferenceTemporalPlainTime — like the Instant difference, but
/// the operands are times-of-day (delta within ±24 h) and the default
/// largestUnit is "hour".
fn differenceTemporalTime(realm: *Realm, this_value: Value, args: []const Value, is_since: bool) NativeError!Value {
    const this_t = try requirePlainTime(realm, this_value);
    const other_t = try toTemporalTime(realm, argOr(args, 0, Value.undefined_), Value.undefined_);
    const opts = try getOptionsObject(realm, argOr(args, 1, Value.undefined_));

    const largest_opt = try getTemporalUnitOption(realm, opts, "largestUnit");
    const increment = try getRoundingIncrementOption(realm, opts);
    const mode = try getRoundingModeOption(realm, opts, .trunc);
    const smallest_opt = try getTemporalUnitOption(realm, opts, "smallestUnit");

    if (largest_opt) |lu| try requireUnitInRange(realm, lu, .hour, .nanosecond);
    const smallest = smallest_opt orelse temporal.LargestUnit.nanosecond;
    try requireUnitInRange(realm, smallest, .hour, .nanosecond);
    const largest = largest_opt orelse temporal.LargestUnit.hour;
    if (@intFromEnum(largest) > @intFromEnum(smallest)) {
        return throwRangeError(realm, "largestUnit must not be smaller than smallestUnit");
    }
    if (!temporal.validateRoundingIncrement(increment, differenceDividend(smallest), false)) {
        return throwRangeError(realm, "invalid roundingIncrement for the smallestUnit");
    }

    const diff = temporal.timeRecordToNanoseconds(other_t) - temporal.timeRecordToNanoseconds(this_t);
    const eff_mode = if (is_since) negateRoundingMode(mode) else mode;
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
