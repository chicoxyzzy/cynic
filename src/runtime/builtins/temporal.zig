//! Temporal — the JS-visible surface for the plain (calendar-free,
//! time-zone-free) value types Cynic ships so far.
//!
//! The `Temporal` global is a namespace object (like `Math`), not a
//! constructor. It currently exposes:
//!   • `Temporal.Duration`  (§7  proposal-temporal)
//!   • `Temporal.PlainTime` (§4  proposal-temporal)
//!
//! Data + pure abstract operations live in `runtime/temporal.zig`;
//! this file holds the constructors, prototype methods, statics, and
//! the namespace wiring. The instance state is a heap-allocated
//! `TemporalRecord` reached through `JSObject.temporal_record` — never
//! a `__cynic_*` property-bag key (AGENTS.md "no engine state on
//! user-visible objects").
//!
//! Deferred (the deep end — needs the TimeDuration BigInt math,
//! rounding machinery, and options parsing): `add` / `subtract` /
//! `round` / `total` / `until` / `since` on both types, and
//! `Duration.compare` / `PlainTime.compare`'s relative-to handling.
//! These throw a clear "not yet implemented" TypeError so a fixture
//! that reaches them fails loudly rather than silently misbehaving.

const std = @import("std");

const Realm = @import("../realm.zig").Realm;
const Value = @import("../value.zig").Value;
const JSString = @import("../string.zig").JSString;
const JSObject = @import("../object.zig").JSObject;
const JSFunction = @import("../function.zig").JSFunction;
const NativeError = @import("../function.zig").NativeError;
const NativeFn = @import("../function.zig").NativeFn;
const heap_mod = @import("../heap.zig");
const intrinsics = @import("../intrinsics.zig");
const temporal = @import("../temporal.zig");

const installConstructor = intrinsics.installConstructor;
const installNativeMethod = intrinsics.installNativeMethod;
const installNativeMethodOnProto = intrinsics.installNativeMethodOnProto;
const installNativeGetter = intrinsics.installNativeGetter;
const installToStringTag = intrinsics.installToStringTag;
const setNonEnumerable = intrinsics.setNonEnumerable;
const throwTypeError = intrinsics.throwTypeError;
const throwRangeError = intrinsics.throwRangeError;
const argOr = intrinsics.argOr;
const getPropertyChain = intrinsics.getPropertyChain;
const toNumber = intrinsics.toNumber;
const stringifyArg = intrinsics.stringifyArg;

const DurationRecord = temporal.DurationRecord;
const PlainTimeRecord = temporal.PlainTimeRecord;
const TemporalRecord = temporal.TemporalRecord;

/// Extract the f64 mathematical value from a Number `Value` (the
/// result of `toNumber`, which is either an Int32 or a Double).
fn numberToF64(v: Value) f64 {
    if (v.isInt32()) return @floatFromInt(v.asInt32());
    return v.asDouble();
}

/// Positional constructor parameter with a spec default of 0. ES
/// default-parameter semantics: a *missing* argument OR an explicit
/// `undefined` both trigger the `= 0` default — so `new Duration()`,
/// `new Duration(undefined)`, and the implicit tail all coerce to 0
/// rather than `ToNumber(undefined) = NaN`. (`years-undefined.js`
/// et al. assert this.)
fn argDefault0(args: []const Value, i: usize) Value {
    const v = argOr(args, i, Value.fromInt32(0));
    if (v.isUndefined()) return Value.fromInt32(0);
    return v;
}

// ── Namespace install ─────────────────────────────────────────────────────

pub fn install(realm: *Realm) !void {
    // The `Temporal` namespace object — a plain object inheriting
    // %Object.prototype% with a `Symbol.toStringTag` of "Temporal"
    // and the per-type constructors as non-enumerable data
    // properties.
    const ns = try realm.heap.allocateObject();
    realm.heap.setObjectPrototype(ns, realm.intrinsics.object_prototype);
    try installToStringTag(realm, ns, "Temporal");
    realm.intrinsics.temporal_namespace = ns;

    try installDuration(realm, ns);
    try installPlainTime(realm, ns);

    // `Temporal` is a non-enumerable, writable, configurable global
    // (§17 namespace-object convention, matching the property
    // descriptor of `Math` / `JSON` / `Reflect`).
    try realm.globals.put(realm.allocator, "Temporal", heap_mod.taggedObject(ns));
}

// ── §7 Temporal.Duration ───────────────────────────────────────────────────

fn installDuration(realm: *Realm, ns: *JSObject) !void {
    // §7.2.1 — `new`-only constructor with arity 0 (all 10 numeric
    // parameters are optional and default to 0).
    const r = try installConstructor(realm, .{
        .name = "Duration",
        .ctor = durationConstructor,
        .arity = 0,
        .is_class = true,
        .set_home_object = true,
        .to_string_tag = "Temporal.Duration",
        .install_global = false,
    });
    const fn_obj = r.ctor;
    const proto = r.proto;

    // §7.3 prototype getters — years … nanoseconds, plus sign / blank.
    try installNativeGetter(realm, proto, "years", durationYears);
    try installNativeGetter(realm, proto, "months", durationMonths);
    try installNativeGetter(realm, proto, "weeks", durationWeeks);
    try installNativeGetter(realm, proto, "days", durationDays);
    try installNativeGetter(realm, proto, "hours", durationHours);
    try installNativeGetter(realm, proto, "minutes", durationMinutes);
    try installNativeGetter(realm, proto, "seconds", durationSeconds);
    try installNativeGetter(realm, proto, "milliseconds", durationMilliseconds);
    try installNativeGetter(realm, proto, "microseconds", durationMicroseconds);
    try installNativeGetter(realm, proto, "nanoseconds", durationNanoseconds);
    try installNativeGetter(realm, proto, "sign", durationSignGetter);
    try installNativeGetter(realm, proto, "blank", durationBlank);

    // §7.3 prototype methods (implemented subset).
    try installNativeMethodOnProto(realm, proto, "with", durationWith, 1);
    try installNativeMethodOnProto(realm, proto, "negated", durationNegated, 0);
    try installNativeMethodOnProto(realm, proto, "abs", durationAbs, 0);
    try installNativeMethodOnProto(realm, proto, "toString", durationToString, 0);
    try installNativeMethodOnProto(realm, proto, "toJSON", durationToJSON, 0);
    try installNativeMethodOnProto(realm, proto, "toLocaleString", durationToLocaleString, 0);
    try installNativeMethodOnProto(realm, proto, "valueOf", durationValueOf, 0);
    // Deferred deep-end methods — present so they exist on the
    // prototype with the right shape, but throw until the rounding
    // machinery lands.
    try installNativeMethodOnProto(realm, proto, "add", durationAdd, 1);
    try installNativeMethodOnProto(realm, proto, "subtract", durationSubtract, 1);
    try installNativeMethodOnProto(realm, proto, "round", durationRound, 1);
    try installNativeMethodOnProto(realm, proto, "total", durationTotal, 1);

    // §7.2 statics.
    try installNativeMethod(realm, fn_obj, "from", durationFrom, 1);
    try installNativeMethod(realm, fn_obj, "compare", durationCompare, 2);

    realm.intrinsics.temporal_duration_constructor = fn_obj;
    realm.intrinsics.temporal_duration_prototype = proto;

    // `Temporal.Duration` is a non-enumerable, writable,
    // configurable data property on the namespace (§17).
    try setNonEnumerable(ns, realm.allocator, "Duration", heap_mod.taggedFunction(fn_obj));
}

/// §7.5.x ToIntegerIfIntegral(value) — ToNumber, then RangeError on a
/// non-finite or non-integral result. Maps -0 to +0. Re-enters JS
/// via ToNumber (valueOf / @@toPrimitive), so the caller's instance
/// must be rooted across the loop (the interpreter roots `this` on
/// `native_ctor_roots`; we hold only stack-local f64 in between).
fn toIntegerIfIntegral(realm: *Realm, v: Value) NativeError!f64 {
    const num = try toNumber(realm, v);
    const n = numberToF64(num);
    if (!std.math.isFinite(n)) return throwRangeError(realm, "Duration field must be finite");
    if (std.math.trunc(n) != n) return throwRangeError(realm, "Duration field must be an integer");
    if (n == 0) return 0; // normalise -0 → +0
    return n;
}

/// §7.2.1 Temporal.Duration ( years, months, …, nanoseconds ).
/// `new`-only. Coerces all 10 args left-to-right via
/// ToIntegerIfIntegral, then validates with IsValidDuration.
fn durationConstructor(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const inst = heap_mod.valueAsPlainObject(this_value) orelse
        return throwTypeError(realm, "Temporal.Duration constructor requires 'new'");

    // §7.2.1 steps 2-11 — ToIntegerIfIntegral on each field, in
    // argument order (the order-of-operations fixtures assert this
    // left-to-right valueOf sequence).
    var d = DurationRecord{};
    d.years = try toIntegerIfIntegral(realm, argDefault0(args, 0));
    d.months = try toIntegerIfIntegral(realm, argDefault0(args, 1));
    d.weeks = try toIntegerIfIntegral(realm, argDefault0(args, 2));
    d.days = try toIntegerIfIntegral(realm, argDefault0(args, 3));
    d.hours = try toIntegerIfIntegral(realm, argDefault0(args, 4));
    d.minutes = try toIntegerIfIntegral(realm, argDefault0(args, 5));
    d.seconds = try toIntegerIfIntegral(realm, argDefault0(args, 6));
    d.milliseconds = try toIntegerIfIntegral(realm, argDefault0(args, 7));
    d.microseconds = try toIntegerIfIntegral(realm, argDefault0(args, 8));
    d.nanoseconds = try toIntegerIfIntegral(realm, argDefault0(args, 9));

    // §7.5.x CreateTemporalDuration step 1 — IsValidDuration.
    if (!temporal.isValidDuration(d)) {
        return throwRangeError(realm, "Duration values are out of range");
    }
    try storeDuration(realm, inst, d);
    return heap_mod.taggedObject(inst);
}

/// Allocate a fresh `Temporal.Duration` instance with the realm's
/// prototype and the given record. Used by `from` / `with` /
/// `negated` / `abs` where the spec calls `CreateTemporalDuration`
/// without a user-facing NewTarget.
fn createTemporalDuration(realm: *Realm, d: DurationRecord) NativeError!Value {
    if (!temporal.isValidDuration(d)) {
        return throwRangeError(realm, "Duration values are out of range");
    }
    const inst = realm.heap.allocateObject() catch return error.OutOfMemory;
    realm.heap.setObjectPrototype(inst, realm.intrinsics.temporal_duration_prototype.?);
    try storeDuration(realm, inst, d);
    return heap_mod.taggedObject(inst);
}

fn storeDuration(realm: *Realm, inst: *JSObject, d: DurationRecord) NativeError!void {
    const rec = realm.allocator.create(TemporalRecord) catch return error.OutOfMemory;
    rec.* = .{ .duration = d };
    inst.setTemporalRecord(realm.allocator, rec) catch return error.OutOfMemory;
}

/// §7.3.x RequireInternalSlot(duration, [[InitializedTemporalDuration]]).
fn requireDuration(realm: *Realm, this_value: Value) NativeError!DurationRecord {
    const obj = heap_mod.valueAsPlainObject(this_value) orelse
        return throwTypeError(realm, "not a Temporal.Duration");
    const rec = obj.getTemporalRecord() orelse
        return throwTypeError(realm, "not a Temporal.Duration");
    return switch (rec.*) {
        .duration => |d| d,
        else => throwTypeError(realm, "not a Temporal.Duration"),
    };
}

// §7.3.{4-13} — the field getters. Each requires the brand then
// returns the slot value as a Number.
fn durationYears(realm: *Realm, t: Value, a: []const Value) NativeError!Value {
    _ = a;
    return Value.fromDouble((try requireDuration(realm, t)).years);
}
fn durationMonths(realm: *Realm, t: Value, a: []const Value) NativeError!Value {
    _ = a;
    return Value.fromDouble((try requireDuration(realm, t)).months);
}
fn durationWeeks(realm: *Realm, t: Value, a: []const Value) NativeError!Value {
    _ = a;
    return Value.fromDouble((try requireDuration(realm, t)).weeks);
}
fn durationDays(realm: *Realm, t: Value, a: []const Value) NativeError!Value {
    _ = a;
    return Value.fromDouble((try requireDuration(realm, t)).days);
}
fn durationHours(realm: *Realm, t: Value, a: []const Value) NativeError!Value {
    _ = a;
    return Value.fromDouble((try requireDuration(realm, t)).hours);
}
fn durationMinutes(realm: *Realm, t: Value, a: []const Value) NativeError!Value {
    _ = a;
    return Value.fromDouble((try requireDuration(realm, t)).minutes);
}
fn durationSeconds(realm: *Realm, t: Value, a: []const Value) NativeError!Value {
    _ = a;
    return Value.fromDouble((try requireDuration(realm, t)).seconds);
}
fn durationMilliseconds(realm: *Realm, t: Value, a: []const Value) NativeError!Value {
    _ = a;
    return Value.fromDouble((try requireDuration(realm, t)).milliseconds);
}
fn durationMicroseconds(realm: *Realm, t: Value, a: []const Value) NativeError!Value {
    _ = a;
    return Value.fromDouble((try requireDuration(realm, t)).microseconds);
}
fn durationNanoseconds(realm: *Realm, t: Value, a: []const Value) NativeError!Value {
    _ = a;
    return Value.fromDouble((try requireDuration(realm, t)).nanoseconds);
}

/// §7.3.2 get Temporal.Duration.prototype.sign.
fn durationSignGetter(realm: *Realm, t: Value, a: []const Value) NativeError!Value {
    _ = a;
    const d = try requireDuration(realm, t);
    return Value.fromInt32(temporal.durationSign(d));
}

/// §7.3.3 get Temporal.Duration.prototype.blank.
fn durationBlank(realm: *Realm, t: Value, a: []const Value) NativeError!Value {
    _ = a;
    const d = try requireDuration(realm, t);
    return Value.fromBool(temporal.durationSign(d) == 0);
}

/// §7.5.x ToTemporalPartialDurationRecord — read each duration field
/// off `like`, applying ToIntegerIfIntegral to present (non-
/// undefined) values, and require at least one present. Singular
/// keys (`year`, `month`, …) are NOT read — only the plural slots.
/// Returns the merged record (starting from `base`).
fn toTemporalPartialDurationRecord(realm: *Realm, base: DurationRecord, like: Value) NativeError!DurationRecord {
    const obj = heap_mod.valueAsPlainObject(like) orelse
        return throwTypeError(realm, "Duration-like must be an object");
    var d = base;
    var any = false;
    // Spec reads the fields in alphabetical order (DURATION_FIELDS):
    // days, hours, microseconds, milliseconds, minutes, months,
    // nanoseconds, seconds, weeks, years.
    const Field = struct { key: []const u8, ptr: *f64 };
    var fields = [_]Field{
        .{ .key = "days", .ptr = &d.days },
        .{ .key = "hours", .ptr = &d.hours },
        .{ .key = "microseconds", .ptr = &d.microseconds },
        .{ .key = "milliseconds", .ptr = &d.milliseconds },
        .{ .key = "minutes", .ptr = &d.minutes },
        .{ .key = "months", .ptr = &d.months },
        .{ .key = "nanoseconds", .ptr = &d.nanoseconds },
        .{ .key = "seconds", .ptr = &d.seconds },
        .{ .key = "weeks", .ptr = &d.weeks },
        .{ .key = "years", .ptr = &d.years },
    };
    for (&fields) |f| {
        const v = try getPropertyChain(realm, obj, f.key);
        if (!v.isUndefined()) {
            any = true;
            f.ptr.* = try toIntegerIfIntegral(realm, v);
        }
    }
    if (!any) return throwTypeError(realm, "Duration-like must have at least one duration property");
    return d;
}

/// §7.3.26 Temporal.Duration.prototype.with ( durationLike ).
fn durationWith(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const d = try requireDuration(realm, this_value);
    const merged = try toTemporalPartialDurationRecord(realm, d, argOr(args, 0, Value.undefined_));
    return createTemporalDuration(realm, merged);
}

/// §7.3.20 Temporal.Duration.prototype.negated ( ).
fn durationNegated(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    const d = try requireDuration(realm, this_value);
    const n = DurationRecord{
        .years = negZero(d.years),
        .months = negZero(d.months),
        .weeks = negZero(d.weeks),
        .days = negZero(d.days),
        .hours = negZero(d.hours),
        .minutes = negZero(d.minutes),
        .seconds = negZero(d.seconds),
        .milliseconds = negZero(d.milliseconds),
        .microseconds = negZero(d.microseconds),
        .nanoseconds = negZero(d.nanoseconds),
    };
    return createTemporalDuration(realm, n);
}

/// Negate but keep -0 → +0 (the spec's negated duration normalises
/// signed zero: `new Temporal.Duration(0).negated()` has +0 years).
fn negZero(v: f64) f64 {
    if (v == 0) return 0;
    return -v;
}

/// §7.3.21 Temporal.Duration.prototype.abs ( ).
fn durationAbs(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    const d = try requireDuration(realm, this_value);
    const a = DurationRecord{
        .years = @abs(d.years),
        .months = @abs(d.months),
        .weeks = @abs(d.weeks),
        .days = @abs(d.days),
        .hours = @abs(d.hours),
        .minutes = @abs(d.minutes),
        .seconds = @abs(d.seconds),
        .milliseconds = @abs(d.milliseconds),
        .microseconds = @abs(d.microseconds),
        .nanoseconds = @abs(d.nanoseconds),
    };
    return createTemporalDuration(realm, a);
}

/// §7.3.24 Temporal.Duration.prototype.toString — default / `auto`
/// precision path. Options-driven rounding is deferred; an options
/// argument that requests a non-default precision / smallestUnit /
/// roundingMode is rejected with a clear TypeError so the fixture
/// fails loudly rather than returning a wrong (un-rounded) string.
fn durationToString(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const d = try requireDuration(realm, this_value);
    const opts = argOr(args, 0, Value.undefined_);
    if (!opts.isUndefined()) {
        return throwTypeError(realm, "Temporal.Duration.prototype.toString options are not yet supported");
    }
    var buf: [128]u8 = undefined;
    const s = temporal.temporalDurationToString(d, &buf);
    const js = realm.heap.allocateString(s) catch return error.OutOfMemory;
    return Value.fromString(js);
}

/// §7.3.25 Temporal.Duration.prototype.toJSON — always `auto`.
fn durationToJSON(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    const d = try requireDuration(realm, this_value);
    var buf: [128]u8 = undefined;
    const s = temporal.temporalDurationToString(d, &buf);
    const js = realm.heap.allocateString(s) catch return error.OutOfMemory;
    return Value.fromString(js);
}

/// §7.3.x Temporal.Duration.prototype.toLocaleString — without
/// Intl.DurationFormat, the spec polyfill falls back to the ISO
/// `auto` string. Cynic has no Intl, so use that fallback.
fn durationToLocaleString(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    return durationToJSON(realm, this_value, args);
}

/// §7.3.23 Temporal.Duration.prototype.valueOf — always throws
/// TypeError (Temporal values are not relationally comparable via
/// the primitive operators).
fn durationValueOf(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = this_value;
    _ = args;
    return throwTypeError(realm, "Called valueOf on a Temporal.Duration; use compare() instead");
}

/// §7.5.x ToTemporalDuration — accept a Duration (copy), an object
/// (partial record from a zeroed base), or a string (ISO parse).
fn toTemporalDuration(realm: *Realm, item: Value) NativeError!DurationRecord {
    if (heap_mod.valueAsPlainObject(item)) |obj| {
        if (obj.getTemporalRecord()) |rec| {
            switch (rec.*) {
                .duration => |d| return d,
                else => {},
            }
        }
        // Object (not a Duration) — partial record from a zeroed
        // base. (The spec's ToTemporalDuration on a non-Duration
        // object builds from zero, so any absent field stays 0.)
        return toTemporalPartialDurationRecord(realm, .{}, item);
    }
    // String path. ToString-coerce non-strings (a number throws via
    // the parse failure; the spec requires a String here).
    if (!item.isString()) {
        return throwTypeError(realm, "Temporal.Duration.from expects an object or string");
    }
    const s: *JSString = @ptrCast(@alignCast(item.asString()));
    const d = temporal.parseTemporalDurationString(s.flatBytes()) catch
        return throwRangeError(realm, "invalid ISO 8601 duration string");
    if (!temporal.isValidDuration(d)) {
        return throwRangeError(realm, "Duration values are out of range");
    }
    return d;
}

/// §7.2.2 Temporal.Duration.from ( item ).
fn durationFrom(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = this_value;
    const d = try toTemporalDuration(realm, argOr(args, 0, Value.undefined_));
    return createTemporalDuration(realm, d);
}

/// §7.2.3 Temporal.Duration.compare — without a relativeTo, only
/// durations whose largest unit is days-or-smaller can be compared
/// (calendar units need a reference point). Deferred: the full
/// TimeDuration normalisation. Throws for now.
fn durationCompare(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = this_value;
    _ = args;
    return throwTypeError(realm, "Temporal.Duration.compare is not yet implemented");
}

// Deferred arithmetic — present for shape, throw until the
// TimeDuration machinery lands.
fn durationAdd(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    _ = try requireDuration(realm, this_value);
    return throwTypeError(realm, "Temporal.Duration.prototype.add is not yet implemented");
}
fn durationSubtract(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    _ = try requireDuration(realm, this_value);
    return throwTypeError(realm, "Temporal.Duration.prototype.subtract is not yet implemented");
}
fn durationRound(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    _ = try requireDuration(realm, this_value);
    return throwTypeError(realm, "Temporal.Duration.prototype.round is not yet implemented");
}
fn durationTotal(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    _ = try requireDuration(realm, this_value);
    return throwTypeError(realm, "Temporal.Duration.prototype.total is not yet implemented");
}

// ── §4 Temporal.PlainTime ────────────────────────────────────────────────

fn installPlainTime(realm: *Realm, ns: *JSObject) !void {
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

/// §7.1.x ToIntegerWithTruncation(value) — ToNumber, RangeError on a
/// non-finite result, then truncate toward zero. (Used by PlainTime,
/// which truncates fractional components rather than rejecting them
/// — distinct from Duration's ToIntegerIfIntegral.)
fn toIntegerWithTruncation(realm: *Realm, v: Value) NativeError!f64 {
    const num = try toNumber(realm, v);
    const n = numberToF64(num);
    if (!std.math.isFinite(n)) return throwRangeError(realm, "time field must be finite");
    return std.math.trunc(n);
}

/// §4.2.1 Temporal.PlainTime ( hour, minute, second, ms, µs, ns ).
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

/// §4.5.x RejectTime — build a `PlainTimeRecord` from coerced f64
/// components, throwing RangeError on any out-of-range value. Used
/// by the constructor (which has no `overflow` option — it always
/// rejects).
fn rejectTime(realm: *Realm, hour: f64, minute: f64, second: f64, millisecond: f64, microsecond: f64, nanosecond: f64) NativeError!PlainTimeRecord {
    if (!rangeOk(hour, 23) or !rangeOk(minute, 59) or !rangeOk(second, 59) or
        !rangeOk(millisecond, 999) or !rangeOk(microsecond, 999) or !rangeOk(nanosecond, 999))
    {
        return throwRangeError(realm, "PlainTime field is out of range");
    }
    return PlainTimeRecord{
        .hour = @intFromFloat(hour),
        .minute = @intFromFloat(minute),
        .second = @intFromFloat(second),
        .millisecond = @intFromFloat(millisecond),
        .microsecond = @intFromFloat(microsecond),
        .nanosecond = @intFromFloat(nanosecond),
    };
}

const Overflow = enum { constrain, reject };

/// §4.5.x RegulateTime — `constrain` clamps each field into its ISO
/// range; `reject` throws (delegates to `rejectTime`). Used by
/// `with` / `from` (object path) where the `overflow` option
/// applies.
fn regulateTime(realm: *Realm, hour: f64, minute: f64, second: f64, millisecond: f64, microsecond: f64, nanosecond: f64, overflow: Overflow) NativeError!PlainTimeRecord {
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
fn getTemporalOverflowOption(realm: *Realm, options: Value) NativeError!Overflow {
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

fn createTemporalTime(realm: *Realm, t: PlainTimeRecord) NativeError!Value {
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

fn requirePlainTime(realm: *Realm, this_value: Value) NativeError!PlainTimeRecord {
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

/// §13.x RejectTemporalLikeObject — throw TypeError if `obj` carries
/// a `calendar` or `timeZone` own property (reading `calendar` then
/// `timeZone` in that order, per the order-of-operations fixture) or
/// is itself a branded Temporal value. Used by `PlainTime.prototype.
/// with` to reject a date-ish / Temporal bag.
fn rejectTemporalLikeObject(realm: *Realm, obj: *JSObject) NativeError!void {
    if (obj.getTemporalRecord() != null) {
        return throwTypeError(realm, "a Temporal object is not a valid PlainTime-like property bag");
    }
    const cal = try getPropertyChain(realm, obj, "calendar");
    if (!cal.isUndefined()) {
        return throwTypeError(realm, "PlainTime-like must not have a calendar property");
    }
    const tz = try getPropertyChain(realm, obj, "timeZone");
    if (!tz.isUndefined()) {
        return throwTypeError(realm, "PlainTime-like must not have a timeZone property");
    }
}

/// §4.5.x ToTemporalTimeRecord(bag, 'partial') — read present time
/// fields off `like` (ToIntegerWithTruncation each), require at
/// least one. Singular spec keys only (hour, microsecond,
/// millisecond, minute, nanosecond, second).
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

/// §4.3.x Temporal.PlainTime.prototype.toString — `auto` precision
/// path. Options-driven rounding is deferred; an options argument is
/// rejected with a TypeError.
fn plainTimeToString(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const t = try requirePlainTime(realm, this_value);
    const opts = argOr(args, 0, Value.undefined_);
    if (!opts.isUndefined()) {
        return throwTypeError(realm, "Temporal.PlainTime.prototype.toString options are not yet supported");
    }
    var buf: [64]u8 = undefined;
    const s = temporal.plainTimeToString(t, &buf);
    const js = realm.heap.allocateString(s) catch return error.OutOfMemory;
    return Value.fromString(js);
}

fn plainTimeToJSON(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    const t = try requirePlainTime(realm, this_value);
    var buf: [64]u8 = undefined;
    const s = temporal.plainTimeToString(t, &buf);
    const js = realm.heap.allocateString(s) catch return error.OutOfMemory;
    return Value.fromString(js);
}

fn plainTimeToLocaleString(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
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
fn toTemporalTime(realm: *Realm, item: Value, options: Value) NativeError!PlainTimeRecord {
    if (heap_mod.valueAsPlainObject(item)) |obj| {
        if (obj.getTemporalRecord()) |rec| {
            switch (rec.*) {
                .plain_time => |t| {
                    // Validate (and ignore) options on the copy path.
                    _ = try getTemporalOverflowOption(realm, options);
                    return t;
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

// Deferred PlainTime arithmetic / difference.
fn plainTimeAdd(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    _ = try requirePlainTime(realm, this_value);
    return throwTypeError(realm, "Temporal.PlainTime.prototype.add is not yet implemented");
}
fn plainTimeSubtract(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    _ = try requirePlainTime(realm, this_value);
    return throwTypeError(realm, "Temporal.PlainTime.prototype.subtract is not yet implemented");
}
fn plainTimeRound(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    _ = try requirePlainTime(realm, this_value);
    return throwTypeError(realm, "Temporal.PlainTime.prototype.round is not yet implemented");
}
fn plainTimeUntil(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    _ = try requirePlainTime(realm, this_value);
    return throwTypeError(realm, "Temporal.PlainTime.prototype.until is not yet implemented");
}
fn plainTimeSince(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    _ = try requirePlainTime(realm, this_value);
    return throwTypeError(realm, "Temporal.PlainTime.prototype.since is not yet implemented");
}
