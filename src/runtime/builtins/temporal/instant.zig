//! Temporal.Instant — fixed point on the time line (epoch ns), constructor,
//! prototype methods, statics, round / since / until / toZonedDateTimeISO.

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
const toNumber = intrinsics.toNumber;
const stringifyArg = intrinsics.stringifyArg;

const TemporalRecord = temporal.TemporalRecord;

const shared = @import("shared.zig");
const duration_mod = @import("duration.zig");
const zoned_date_time_mod = @import("zoned_date_time.zig");

const numberToF64 = shared.numberToF64;
const negZero = shared.negZero;
const getOptionsObject = shared.getOptionsObject;
const getRoundingModeOption = shared.getRoundingModeOption;
const getRoundingIncrementOption = shared.getRoundingIncrementOption;
const getTemporalUnitOption = shared.getTemporalUnitOption;
const requireUnitInRange = shared.requireUnitInRange;
const negateRoundingMode = shared.negateRoundingMode;
const getFractionalSecondDigitsOption = shared.getFractionalSecondDigitsOption;
const toSecondsStringPrecision = shared.toSecondsStringPrecision;
const requireToStringSmallestUnit = shared.requireToStringSmallestUnit;
const toTimeZoneArg = shared.toTimeZoneArg;

const toTemporalDuration = duration_mod.toTemporalDuration;
const createTemporalDuration = duration_mod.createTemporalDuration;
const createTemporalZonedDateTime = zoned_date_time_mod.createTemporalZonedDateTime;

pub fn install(realm: *Realm, ns: *JSObject) !void {
    // §8.1.1 — `new`-only constructor, arity 1 (the epoch-nanoseconds
    // BigInt).
    const r = try installConstructor(realm, .{
        .name = "Instant",
        .ctor = instantConstructor,
        .arity = 1,
        .is_class = true,
        .set_home_object = true,
        .to_string_tag = "Temporal.Instant",
        .install_global = false,
    });
    const fn_obj = r.ctor;
    const proto = r.proto;

    try installNativeGetter(realm, proto, "epochMilliseconds", instantEpochMilliseconds);
    try installNativeGetter(realm, proto, "epochNanoseconds", instantEpochNanoseconds);

    try installNativeMethodOnProto(realm, proto, "add", instantAdd, 1);
    try installNativeMethodOnProto(realm, proto, "subtract", instantSubtract, 1);
    try installNativeMethodOnProto(realm, proto, "equals", instantEquals, 1);
    try installNativeMethodOnProto(realm, proto, "toString", instantToString, 0);
    try installNativeMethodOnProto(realm, proto, "toJSON", instantToJSON, 0);
    try installNativeMethodOnProto(realm, proto, "toLocaleString", instantToLocaleString, 0);
    try installNativeMethodOnProto(realm, proto, "valueOf", instantValueOf, 0);
    // Deferred deep-end methods — present with the right shape, but
    // they throw until the rounding / time-zone machinery lands.
    try installNativeMethodOnProto(realm, proto, "round", instantRound, 1);
    try installNativeMethodOnProto(realm, proto, "until", instantUntil, 1);
    try installNativeMethodOnProto(realm, proto, "since", instantSince, 1);
    try installNativeMethodOnProto(realm, proto, "toZonedDateTimeISO", instantToZonedDateTimeISO, 1);

    try installNativeMethod(realm, fn_obj, "from", instantFrom, 1);
    try installNativeMethod(realm, fn_obj, "fromEpochMilliseconds", instantFromEpochMilliseconds, 1);
    try installNativeMethod(realm, fn_obj, "fromEpochNanoseconds", instantFromEpochNanoseconds, 1);
    try installNativeMethod(realm, fn_obj, "compare", instantCompare, 2);

    realm.intrinsics.temporal_instant_constructor = fn_obj;
    realm.intrinsics.temporal_instant_prototype = proto;

    try setNonEnumerable(ns, realm.allocator, "Instant", heap_mod.taggedFunction(fn_obj));
}

/// §8.1.1 Temporal.Instant ( epochNanoseconds ). `new`-only. ToBigInt-
/// coerces the argument (so a numeric string parses as a BigInt and a
/// Number throws TypeError), then validates the epoch-ns range.
fn instantConstructor(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const inst = heap_mod.valueAsPlainObject(this_value) orelse
        return throwTypeError(realm, "Temporal.Instant constructor requires 'new'");
    // §8.1.1 step 2 — ToBigInt(epochNanoseconds) (§7.1.13).
    const bi_val = try bigint_builtin.toBigIntValue(realm, argOr(args, 0, Value.undefined_));
    const epoch_ns = try epochNsFromBigInt(realm, bi_val);
    try storeInstant(realm, inst, epoch_ns);
    return heap_mod.taggedObject(inst);
}

/// Extract a validated epoch-ns `i128` from a BigInt `Value`, throwing
/// RangeError when it is outside the representable instant range —
/// including BigInts too large to fit `i128` (`2n ** 128n`).
pub fn epochNsFromBigInt(realm: *Realm, bi_val: Value) NativeError!i128 {
    const bi = heap_mod.valueAsBigInt(bi_val) orelse
        return throwTypeError(realm, "expected a BigInt");
    if (!bi.fitsI128()) return throwRangeError(realm, "epoch nanoseconds are out of range");
    const ns = bi.toI128();
    if (!temporal.isValidEpochNanoseconds(ns)) {
        return throwRangeError(realm, "epoch nanoseconds are out of range");
    }
    return ns;
}

fn storeInstant(realm: *Realm, inst: *JSObject, epoch_ns: i128) NativeError!void {
    const rec = realm.allocator.create(TemporalRecord) catch return error.OutOfMemory;
    rec.* = .{ .instant = .{ .epoch_ns = epoch_ns } };
    inst.setTemporalRecord(realm.allocator, rec) catch return error.OutOfMemory;
}

/// §8.1.x CreateTemporalInstant — allocate a fresh Instant with the
/// realm prototype. Exposed (`pub`) so `Date.prototype.toTemporalInstant`
/// can mint the bridged Instant.
pub fn createTemporalInstant(realm: *Realm, epoch_ns: i128) NativeError!Value {
    const inst = realm.heap.allocateObject() catch return error.OutOfMemory;
    realm.heap.setObjectPrototype(inst, realm.intrinsics.temporal_instant_prototype.?);
    try storeInstant(realm, inst, epoch_ns);
    return heap_mod.taggedObject(inst);
}

/// §8.x RequireInternalSlot(instant, [[InitializedTemporalInstant]]).
pub fn requireInstant(realm: *Realm, this_value: Value) NativeError!i128 {
    const obj = heap_mod.valueAsPlainObject(this_value) orelse
        return throwTypeError(realm, "not a Temporal.Instant");
    const rec = obj.getTemporalRecord() orelse
        return throwTypeError(realm, "not a Temporal.Instant");
    return switch (rec.*) {
        .instant => |i| i.epoch_ns,
        else => throwTypeError(realm, "not a Temporal.Instant"),
    };
}

/// §8.5.x ToTemporalInstant — a Temporal.Instant (copy), or any other
/// value coerced via ToPrimitive(string) and parsed as an ISO instant
/// string. A non-string primitive (Number, …) throws TypeError; a
/// malformed string throws RangeError. (Temporal.ZonedDateTime would
/// also resolve here once it ships.)
fn toTemporalInstant(realm: *Realm, item: Value) NativeError!i128 {
    var v = item;
    // Any Object — plain OR callable (a function is still an Object per
    // the spec) — coerces via ToPrimitive(string); a branded
    // Temporal.Instant short-circuits to its epoch ns. A non-string,
    // non-object primitive (Number, Symbol, …) falls through to the
    // TypeError below.
    if (heap_mod.valueAsPlainObject(v) != null or heap_mod.valueAsFunction(v) != null) {
        if (heap_mod.valueAsPlainObject(v)) |obj| {
            if (obj.getTemporalRecord()) |rec| {
                switch (rec.*) {
                    .instant => |i| return i.epoch_ns,
                    // §8.5.x ToTemporalInstant step 1.b — a ZonedDateTime
                    // converts via its [[EpochNanoseconds]] slot directly;
                    // no ToPrimitive / toString is observed.
                    .zoned_date_time => |zdt| return zdt.epoch_ns,
                    else => {},
                }
            }
        }
        v = try intrinsics.toPrimitive(realm, v, .string);
    }
    if (!v.isString()) {
        return throwTypeError(realm, "Temporal.Instant.from expects a Temporal.Instant or ISO 8601 string");
    }
    const s: *JSString = @ptrCast(@alignCast(v.asString()));
    return temporal.parseInstantString(s.flatBytes()) catch
        return throwRangeError(realm, "invalid ISO 8601 instant string");
}

/// §8.4.4 get Temporal.Instant.prototype.epochMilliseconds — floor of
/// the epoch ns divided by 10^6, as a Number (always exact: |ms| ≤
/// 8.64×10^15 < 2^53).
fn instantEpochMilliseconds(realm: *Realm, t: Value, a: []const Value) NativeError!Value {
    _ = a;
    const ns = try requireInstant(realm, t);
    const ms = @divFloor(ns, 1_000_000);
    return Value.fromDouble(@floatFromInt(ms));
}

/// §8.4.5 get Temporal.Instant.prototype.epochNanoseconds — the slot
/// value as a BigInt.
fn instantEpochNanoseconds(realm: *Realm, t: Value, a: []const Value) NativeError!Value {
    _ = a;
    const ns = try requireInstant(realm, t);
    const bi = realm.heap.allocateBigInt(ns) catch return error.OutOfMemory;
    return heap_mod.taggedBigInt(bi);
}

/// §8.2.2 Temporal.Instant.from ( item ).
fn instantFrom(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = this_value;
    const ns = try toTemporalInstant(realm, argOr(args, 0, Value.undefined_));
    return createTemporalInstant(realm, ns);
}

/// §8.2.3 Temporal.Instant.fromEpochMilliseconds ( epochMilliseconds ).
fn instantFromEpochMilliseconds(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = this_value;
    const num = try toNumber(realm, argOr(args, 0, Value.undefined_));
    const d = numberToF64(num);
    // §21.2.1.1.1 NumberToBigInt — RangeError on a non-finite or
    // non-integral Number.
    if (!std.math.isFinite(d) or @trunc(d) != d) {
        return throwRangeError(realm, "epoch milliseconds must be an integer");
    }
    // |ms| ≤ 8.64×10^15 ⇔ |ns| ≤ 8.64×10^21; the bound also keeps the
    // i128 conversion in range.
    if (d < -8_640_000_000_000_000.0 or d > 8_640_000_000_000_000.0) {
        return throwRangeError(realm, "epoch milliseconds are out of range");
    }
    const ns: i128 = @as(i128, @intFromFloat(d)) * 1_000_000;
    return createTemporalInstant(realm, ns);
}

/// §8.2.4 Temporal.Instant.fromEpochNanoseconds ( epochNanoseconds ).
fn instantFromEpochNanoseconds(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = this_value;
    const bi_val = try bigint_builtin.toBigIntValue(realm, argOr(args, 0, Value.undefined_));
    const ns = try epochNsFromBigInt(realm, bi_val);
    return createTemporalInstant(realm, ns);
}

/// §8.2.5 Temporal.Instant.compare ( one, two ).
fn instantCompare(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = this_value;
    const a = try toTemporalInstant(realm, argOr(args, 0, Value.undefined_));
    const b = try toTemporalInstant(realm, argOr(args, 1, Value.undefined_));
    return Value.fromInt32(temporal.compareInstant(a, b));
}

/// §8.4.9 Temporal.Instant.prototype.equals ( other ).
fn instantEquals(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const a = try requireInstant(realm, this_value);
    const b = try toTemporalInstant(realm, argOr(args, 0, Value.undefined_));
    return Value.fromBool(a == b);
}

fn instantAdd(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    return instantAddSubtract(realm, this_value, argOr(args, 0, Value.undefined_), 1);
}

fn instantSubtract(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    return instantAddSubtract(realm, this_value, argOr(args, 0, Value.undefined_), -1);
}

/// §8.4.6 / §8.4.7 AddDurationToInstant — fold a time-only Duration
/// into the epoch nanoseconds. `sign` is +1 for `add`, -1 for
/// `subtract`. §8 disallows calendar units (years / months / weeks /
/// days): a non-zero one throws RangeError.
fn instantAddSubtract(realm: *Realm, this_value: Value, duration_like: Value, sign: i128) NativeError!Value {
    const epoch_ns = try requireInstant(realm, this_value);
    const d = try toTemporalDuration(realm, duration_like);
    // ToTemporalDuration's property-bag path does not itself run
    // IsValidDuration, so a mixed-sign / out-of-range duration-like
    // reaches here unvalidated — reject it (RangeError).
    if (!temporal.isValidDuration(d)) {
        return throwRangeError(realm, "Duration values are out of range");
    }
    if (d.years != 0 or d.months != 0 or d.weeks != 0 or d.days != 0) {
        return throwRangeError(realm, "Temporal.Instant arithmetic does not allow calendar units (years/months/weeks/days)");
    }
    const delta = temporal.timeDurationNanoseconds(d) * sign;
    const result = temporal.addInstant(epoch_ns, delta) orelse
        return throwRangeError(realm, "Temporal.Instant arithmetic result is out of range");
    return createTemporalInstant(realm, result);
}

/// §8.4.10 Temporal.Instant.prototype.toString ( [options] ) — read
/// fractionalSecondDigits, roundingMode, smallestUnit, timeZone (in that
/// order, before any validation), round the instant to the resolved
/// unit/increment, then render. With no `timeZone` the output is the UTC
/// wall clock with a trailing `Z`; with one it is that zone's wall clock
/// plus its numeric `±HH:MM` offset.
fn instantToString(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const ns = try requireInstant(realm, this_value);
    const options = argOr(args, 0, Value.undefined_);
    const frac = try getFractionalSecondDigitsOption(realm, options);
    const opts_obj = try getOptionsObject(realm, options);
    const mode = try getRoundingModeOption(realm, opts_obj, .trunc);
    const smallest = try getTemporalUnitOption(realm, opts_obj, "smallestUnit");
    var time_zone: ?temporal.TimeZone = null;
    if (opts_obj) |o| {
        const tz_val = try getPropertyChain(realm, o, "timeZone");
        if (!tz_val.isUndefined()) time_zone = try toTimeZoneArg(realm, tz_val);
    }
    try requireToStringSmallestUnit(realm, smallest);

    const prec = toSecondsStringPrecision(smallest, frac);
    const inc_ns = prec.increment * temporal.unitNanoseconds(prec.unit);
    const rounded_ns = temporal.roundToIncrementAsIfPositive(ns, inc_ns, mode);
    if (!temporal.isValidEpochNanoseconds(rounded_ns)) {
        return throwRangeError(realm, "rounded Instant is out of range");
    }
    var buf: [48]u8 = undefined;
    const s = temporal.instantToString(rounded_ns, &buf, prec.precision, time_zone);
    const js = realm.heap.allocateString(s) catch return error.OutOfMemory;
    return Value.fromString(js);
}

/// §8.4.11 Temporal.Instant.prototype.toJSON — always `auto`, UTC.
fn instantToJSON(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    const ns = try requireInstant(realm, this_value);
    var buf: [48]u8 = undefined;
    const s = temporal.instantToString(ns, &buf, .auto, null);
    const js = realm.heap.allocateString(s) catch return error.OutOfMemory;
    return Value.fromString(js);
}

fn instantToLocaleString(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    // §8.3.x — FormatDateTime via DateTimeFormat when CLDR is present; without
    // it (no `Intl`) fall back to the ISO string.
    if (@import("../../cldr.zig").available)
        return @import("../intl.zig").temporalToLocaleString(realm, this_value, args);
    return instantToJSON(realm, this_value, args);
}

/// §8.4.12 Temporal.Instant.prototype.valueOf — always throws
/// (Temporal values are not relationally comparable via the operators).
fn instantValueOf(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = this_value;
    _ = args;
    return throwTypeError(realm, "Called valueOf on a Temporal.Instant; use compare() instead");
}

/// §8.4.x Temporal.Instant.prototype.round ( roundTo ). A string
/// `roundTo` is shorthand for `{ smallestUnit }`; smallestUnit is
/// required (hour..nanosecond). roundingIncrement (default 1) must
/// divide a 24-hour day evenly; roundingMode defaults to halfExpand.
fn instantRound(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const ns = try requireInstant(realm, this_value);
    const round_to = argOr(args, 0, Value.undefined_);
    if (round_to.isUndefined()) {
        return throwTypeError(realm, "Temporal.Instant.prototype.round requires a smallestUnit");
    }

    var unit: temporal.LargestUnit = undefined;
    var increment: i128 = 1;
    var mode: temporal.RoundingMode = .half_expand;
    if (round_to.isString()) {
        const s: *JSString = @ptrCast(@alignCast(round_to.asString()));
        unit = temporal.parseTemporalUnit(s.flatBytes()) orelse
            return throwRangeError(realm, "invalid smallestUnit");
        if (@intFromEnum(unit) < @intFromEnum(temporal.LargestUnit.hour)) {
            return throwRangeError(realm, "smallestUnit is outside the allowed range");
        }
    } else {
        const opts = try getOptionsObject(realm, round_to);
        increment = try getRoundingIncrementOption(realm, opts);
        mode = try getRoundingModeOption(realm, opts, .half_expand);
        unit = (try getTemporalUnitOption(realm, opts, "smallestUnit")) orelse
            return throwRangeError(realm, "smallestUnit is required");
        try requireUnitInRange(realm, unit, .hour, .nanosecond);
    }

    // increment × unit-span must divide a solar day evenly (inclusive).
    const per_day = @divExact(@as(i128, 86_400_000_000_000), temporal.unitNanoseconds(unit));
    if (!temporal.validateRoundingIncrement(increment, per_day, true)) {
        return throwRangeError(realm, "roundingIncrement does not divide evenly into a day");
    }

    const rounded = temporal.roundToIncrementAsIfPositive(ns, increment * temporal.unitNanoseconds(unit), mode);
    if (!temporal.isValidEpochNanoseconds(rounded)) {
        return throwRangeError(realm, "rounded instant is out of range");
    }
    return createTemporalInstant(realm, rounded);
}

fn instantUntil(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    return differenceTemporalInstant(realm, this_value, args, false);
}

fn instantSince(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    return differenceTemporalInstant(realm, this_value, args, true);
}

/// Dividend for a difference roundingIncrement: the count of `unit` in
/// the next-larger unit (non-inclusive bound). Day and above are
/// disallowed for Instant differences.
pub fn differenceDividend(unit: temporal.LargestUnit) i128 {
    return switch (unit) {
        .hour => 24,
        .minute, .second => 60,
        .millisecond, .microsecond, .nanosecond => 1000,
        else => unreachable,
    };
}

/// §8.4.x DifferenceTemporalInstant — `until` (sign +) / `since` (sign
/// −). Reads the difference settings (largestUnit, increment, mode,
/// smallestUnit in that order), rounds the epoch-ns delta, and balances
/// it into a time-only Duration. `since` negates the rounding mode and
/// the result, so `a.since(b)` equals `a.until(b).negated()`.
fn differenceTemporalInstant(realm: *Realm, this_value: Value, args: []const Value, is_since: bool) NativeError!Value {
    const this_ns = try requireInstant(realm, this_value);
    const other_ns = try toTemporalInstant(realm, argOr(args, 0, Value.undefined_));
    const opts = try getOptionsObject(realm, argOr(args, 1, Value.undefined_));

    // GetDifferenceSettings read order: largestUnit, increment, mode,
    // smallestUnit. Allowed units: hour..nanosecond.
    const largest_opt = try getTemporalUnitOption(realm, opts, "largestUnit");
    const increment = try getRoundingIncrementOption(realm, opts);
    const mode = try getRoundingModeOption(realm, opts, .trunc);
    const smallest_opt = try getTemporalUnitOption(realm, opts, "smallestUnit");

    // All options read; now validate. Units must be in range (hour..ns).
    if (largest_opt) |lu| try requireUnitInRange(realm, lu, .hour, .nanosecond);
    const smallest = smallest_opt orelse temporal.LargestUnit.nanosecond;
    try requireUnitInRange(realm, smallest, .hour, .nanosecond);

    // Default largestUnit is the larger of smallestUnit and "second".
    const largest = largest_opt orelse (if (@intFromEnum(smallest) < @intFromEnum(temporal.LargestUnit.second))
        smallest
    else
        temporal.LargestUnit.second);
    if (@intFromEnum(largest) > @intFromEnum(smallest)) {
        return throwRangeError(realm, "largestUnit must not be smaller than smallestUnit");
    }
    if (!temporal.validateRoundingIncrement(increment, differenceDividend(smallest), false)) {
        return throwRangeError(realm, "invalid roundingIncrement for the smallestUnit");
    }

    const diff = other_ns - this_ns;
    const eff_mode = if (is_since) negateRoundingMode(mode) else mode;
    const rounded = temporal.roundToIncrement(diff, increment * temporal.unitNanoseconds(smallest), eff_mode);
    var d = temporal.balanceTimeDuration(rounded, largest);
    if (is_since) {
        d.days = negZero(d.days);
        d.hours = negZero(d.hours);
        d.minutes = negZero(d.minutes);
        d.seconds = negZero(d.seconds);
        d.milliseconds = negZero(d.milliseconds);
        d.microseconds = negZero(d.microseconds);
        d.nanoseconds = negZero(d.nanoseconds);
    }
    return createTemporalDuration(realm, d);
}

/// §8.3.x Temporal.Instant.prototype.toZonedDateTimeISO ( timeZone ) —
/// pair this instant with a time zone (ISO calendar) to form a
/// ZonedDateTime at the same epoch nanoseconds.
fn instantToZonedDateTimeISO(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const epoch = try requireInstant(realm, this_value);
    const tz = try toTimeZoneArg(realm, argOr(args, 0, Value.undefined_));
    return createTemporalZonedDateTime(realm, .{ .epoch_ns = epoch, .time_zone = tz });
}
