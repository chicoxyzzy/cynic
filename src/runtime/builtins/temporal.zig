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
const bigint_builtin = @import("bigint.zig");

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
const PlainDateRecord = temporal.PlainDateRecord;
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
    try installInstant(realm, ns);
    try installPlainDate(realm, ns);

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

/// Whether an options bag carries a present `relativeTo` — the
/// calendar / zoned-anchored path, which Cynic defers.
fn relativeToPresent(realm: *Realm, opts: ?*JSObject) NativeError!bool {
    const obj = opts orelse return false;
    const v = try getPropertyChain(realm, obj, "relativeTo");
    return !v.isUndefined();
}

/// The larger-magnitude of two largest units (smaller enum index wins).
fn largerLargestUnit(a: temporal.LargestUnit, b: temporal.LargestUnit) temporal.LargestUnit {
    return if (@intFromEnum(a) < @intFromEnum(b)) a else b;
}

/// §7.3.x Temporal.Duration.compare ( one, two [, options] ). Without a
/// relativeTo, calendar units (years/months/weeks) can't be ordered and
/// throw; day-and-smaller durations compare by total nanoseconds (each
/// day a fixed 24 h). The relativeTo path is deferred.
fn durationCompare(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = this_value;
    const one = try toTemporalDuration(realm, argOr(args, 0, Value.undefined_));
    if (!temporal.isValidDuration(one)) return throwRangeError(realm, "Duration values are out of range");
    const two = try toTemporalDuration(realm, argOr(args, 1, Value.undefined_));
    if (!temporal.isValidDuration(two)) return throwRangeError(realm, "Duration values are out of range");
    const opts = try getOptionsObject(realm, argOr(args, 2, Value.undefined_));
    if (try relativeToPresent(realm, opts)) {
        return throwTypeError(realm, "Temporal.Duration.compare with relativeTo is not yet implemented");
    }
    if (temporal.hasCalendarUnits(one) or temporal.hasCalendarUnits(two)) {
        return throwRangeError(realm, "a relativeTo is required to compare durations with calendar units");
    }
    const ns_one = temporal.dayTimeDurationNanoseconds(one);
    const ns_two = temporal.dayTimeDurationNanoseconds(two);
    const cmp: i32 = if (ns_one < ns_two) -1 else if (ns_one > ns_two) 1 else 0;
    return Value.fromInt32(cmp);
}

/// §7.3.x AddDurations — `add` (sign +1) / `subtract` (−1). These take
/// no relativeTo, so calendar units (years/months/weeks) are
/// unorderable and throw; day-and-smaller durations combine by total
/// nanoseconds and re-balance to the larger of the two largest units.
fn durationAddSubtract(realm: *Realm, this_value: Value, other_v: Value, sign: i128) NativeError!Value {
    const a = try requireDuration(realm, this_value);
    const b = try toTemporalDuration(realm, other_v);
    if (!temporal.isValidDuration(b)) return throwRangeError(realm, "Duration values are out of range");
    if (temporal.hasCalendarUnits(a) or temporal.hasCalendarUnits(b)) {
        return throwRangeError(realm, "a relativeTo is required to add durations with calendar units");
    }
    const total = temporal.dayTimeDurationNanoseconds(a) + temporal.dayTimeDurationNanoseconds(b) * sign;
    const largest = largerLargestUnit(temporal.defaultTemporalLargestUnit(a), temporal.defaultTemporalLargestUnit(b));
    return createTemporalDuration(realm, temporal.balanceTimeDuration(total, largest));
}

fn durationAdd(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    return durationAddSubtract(realm, this_value, argOr(args, 0, Value.undefined_), 1);
}

fn durationSubtract(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    return durationAddSubtract(realm, this_value, argOr(args, 0, Value.undefined_), -1);
}

/// Deferred — rounding/balancing calendar units against a relativeTo
/// reference still needs the calendar path.
fn durationRound(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    _ = try requireDuration(realm, this_value);
    return throwTypeError(realm, "Temporal.Duration.prototype.round is not yet implemented");
}

/// §7.3.x Temporal.Duration.prototype.total ( totalOf ). A string
/// selects the unit; an options bag may also carry relativeTo
/// (deferred). For a day-or-smaller unit and a calendar-unit-free
/// duration, returns the ratio as a Number.
fn durationTotal(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const d = try requireDuration(realm, this_value);
    const total_of = argOr(args, 0, Value.undefined_);
    if (total_of.isUndefined()) {
        return throwTypeError(realm, "Temporal.Duration.prototype.total requires a unit");
    }
    var unit_opt: ?temporal.LargestUnit = null;
    if (total_of.isString()) {
        const s: *JSString = @ptrCast(@alignCast(total_of.asString()));
        unit_opt = temporal.parseTemporalUnit(s.flatBytes());
    } else {
        const opts = try getOptionsObject(realm, total_of);
        if (try relativeToPresent(realm, opts)) {
            return throwTypeError(realm, "Temporal.Duration.prototype.total with relativeTo is not yet implemented");
        }
        unit_opt = try getTemporalUnitOption(realm, opts, "unit");
    }
    const unit = unit_opt orelse return throwRangeError(realm, "a unit is required");
    if (@intFromEnum(unit) < @intFromEnum(temporal.LargestUnit.day)) {
        return throwTypeError(realm, "totalling a calendar unit requires relativeTo (not yet implemented)");
    }
    if (temporal.hasCalendarUnits(d)) {
        return throwRangeError(realm, "a relativeTo is required to total a duration with calendar units");
    }
    const total_ns = temporal.dayTimeDurationNanoseconds(d);
    const unit_ns = temporal.unitNanoseconds(unit);
    const q = @divTrunc(total_ns, unit_ns);
    const r = @rem(total_ns, unit_ns);
    const result: f64 = @as(f64, @floatFromInt(q)) + @as(f64, @floatFromInt(r)) / @as(f64, @floatFromInt(unit_ns));
    return Value.fromDouble(result);
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
    const per_day = @divExact(@as(i128, 86_400_000_000_000), temporal.unitNanoseconds(unit));
    if (!temporal.validateRoundingIncrement(increment, per_day, true)) {
        return throwRangeError(realm, "roundingIncrement does not divide evenly into a day");
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

// ── §8 Temporal.Instant ────────────────────────────────────────────────────

fn installInstant(realm: *Realm, ns: *JSObject) !void {
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
fn epochNsFromBigInt(realm: *Realm, bi_val: Value) NativeError!i128 {
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
fn requireInstant(realm: *Realm, this_value: Value) NativeError!i128 {
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

/// §8.4.10 Temporal.Instant.prototype.toString — default / `auto`
/// precision (UTC, trailing `Z`). Options-driven rounding / time-zone
/// rendering is deferred; an options argument is rejected.
fn instantToString(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const ns = try requireInstant(realm, this_value);
    const opts = argOr(args, 0, Value.undefined_);
    if (!opts.isUndefined()) {
        return throwTypeError(realm, "Temporal.Instant.prototype.toString options are not yet supported");
    }
    var buf: [48]u8 = undefined;
    const s = temporal.instantToString(ns, &buf);
    const js = realm.heap.allocateString(s) catch return error.OutOfMemory;
    return Value.fromString(js);
}

/// §8.4.11 Temporal.Instant.prototype.toJSON — always `auto`, UTC.
fn instantToJSON(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    const ns = try requireInstant(realm, this_value);
    var buf: [48]u8 = undefined;
    const s = temporal.instantToString(ns, &buf);
    const js = realm.heap.allocateString(s) catch return error.OutOfMemory;
    return Value.fromString(js);
}

fn instantToLocaleString(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    return instantToJSON(realm, this_value, args);
}

/// §8.4.12 Temporal.Instant.prototype.valueOf — always throws
/// (Temporal values are not relationally comparable via the operators).
fn instantValueOf(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = this_value;
    _ = args;
    return throwTypeError(realm, "Called valueOf on a Temporal.Instant; use compare() instead");
}

// ── §13 Rounding / difference option parsing (shared) ─────────────────────

/// §13.x GetOptionsObject — the options object, or null when options is
/// undefined. A non-object, non-undefined value throws TypeError. A
/// callable options bag is tolerated as empty (property reads want a
/// plain object); function-valued options are a rare edge.
fn getOptionsObject(realm: *Realm, options: Value) NativeError!?*JSObject {
    if (options.isUndefined()) return null;
    if (heap_mod.valueAsPlainObject(options)) |o| return o;
    if (heap_mod.valueAsFunction(options) != null) return null;
    return throwTypeError(realm, "options must be an object or undefined");
}

/// §13.x GetRoundingModeOption.
fn getRoundingModeOption(realm: *Realm, opts: ?*JSObject, default_mode: temporal.RoundingMode) NativeError!temporal.RoundingMode {
    const obj = opts orelse return default_mode;
    const v = try getPropertyChain(realm, obj, "roundingMode");
    if (v.isUndefined()) return default_mode;
    const s = try stringifyArg(realm, v);
    return temporal.parseRoundingMode(s.flatBytes()) orelse
        throwRangeError(realm, "invalid roundingMode");
}

/// §13.x GetRoundingIncrementOption — ToNumber, reject non-finite,
/// truncate, then require an integer in [1, 1e9].
fn getRoundingIncrementOption(realm: *Realm, opts: ?*JSObject) NativeError!i128 {
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
fn getTemporalUnitOption(realm: *Realm, opts: ?*JSObject, key: []const u8) NativeError!?temporal.LargestUnit {
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
fn requireUnitInRange(realm: *Realm, unit: temporal.LargestUnit, largest_allowed: temporal.LargestUnit, smallest_allowed: temporal.LargestUnit) NativeError!void {
    if (@intFromEnum(unit) < @intFromEnum(largest_allowed) or @intFromEnum(unit) > @intFromEnum(smallest_allowed)) {
        return throwRangeError(realm, "unit is outside the allowed range");
    }
}

/// §13.x NegateRoundingMode — lets `since` round in the reverse
/// direction of `until`. Only the directed ceil/floor pair flips; the
/// sign-symmetric modes are unchanged.
fn negateRoundingMode(mode: temporal.RoundingMode) temporal.RoundingMode {
    return switch (mode) {
        .ceil => .floor,
        .floor => .ceil,
        .half_ceil => .half_floor,
        .half_floor => .half_ceil,
        else => mode,
    };
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
fn differenceDividend(unit: temporal.LargestUnit) i128 {
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

/// Deferred — needs the time-zone machinery + Temporal.ZonedDateTime.
fn instantToZonedDateTimeISO(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    _ = try requireInstant(realm, this_value);
    return throwTypeError(realm, "Temporal.Instant.prototype.toZonedDateTimeISO is not yet implemented");
}

// ── §3 Temporal.PlainDate (ISO calendar) ───────────────────────────────────

fn installPlainDate(realm: *Realm, ns: *JSObject) !void {
    // §3.1.1 — `new`-only constructor (year, month, day, [calendar]).
    const r = try installConstructor(realm, .{
        .name = "PlainDate",
        .ctor = plainDateConstructor,
        .arity = 3,
        .is_class = true,
        .set_home_object = true,
        .to_string_tag = "Temporal.PlainDate",
        .install_global = false,
    });
    const fn_obj = r.ctor;
    const proto = r.proto;

    try installNativeGetter(realm, proto, "calendarId", plainDateCalendarId);
    try installNativeGetter(realm, proto, "year", plainDateYear);
    try installNativeGetter(realm, proto, "month", plainDateMonth);
    try installNativeGetter(realm, proto, "monthCode", plainDateMonthCode);
    try installNativeGetter(realm, proto, "day", plainDateDay);
    try installNativeGetter(realm, proto, "dayOfWeek", plainDateDayOfWeek);
    try installNativeGetter(realm, proto, "dayOfYear", plainDateDayOfYear);
    try installNativeGetter(realm, proto, "weekOfYear", plainDateWeekOfYear);
    try installNativeGetter(realm, proto, "yearOfWeek", plainDateYearOfWeek);
    try installNativeGetter(realm, proto, "daysInWeek", plainDateDaysInWeek);
    try installNativeGetter(realm, proto, "daysInMonth", plainDateDaysInMonth);
    try installNativeGetter(realm, proto, "daysInYear", plainDateDaysInYear);
    try installNativeGetter(realm, proto, "monthsInYear", plainDateMonthsInYear);
    try installNativeGetter(realm, proto, "inLeapYear", plainDateInLeapYear);
    try installNativeGetter(realm, proto, "era", plainDateEra);
    try installNativeGetter(realm, proto, "eraYear", plainDateEraYear);

    try installNativeMethodOnProto(realm, proto, "with", plainDateWith, 1);
    try installNativeMethodOnProto(realm, proto, "equals", plainDateEquals, 1);
    try installNativeMethodOnProto(realm, proto, "toString", plainDateToString, 0);
    try installNativeMethodOnProto(realm, proto, "toJSON", plainDateToJSON, 0);
    try installNativeMethodOnProto(realm, proto, "toLocaleString", plainDateToLocaleString, 0);
    try installNativeMethodOnProto(realm, proto, "valueOf", plainDateValueOf, 0);
    // Deferred — date arithmetic / conversions to types Cynic doesn't ship yet.
    try installNativeMethodOnProto(realm, proto, "add", plainDateAdd, 1);
    try installNativeMethodOnProto(realm, proto, "subtract", plainDateSubtract, 1);
    try installNativeMethodOnProto(realm, proto, "until", plainDateUntil, 1);
    try installNativeMethodOnProto(realm, proto, "since", plainDateSince, 1);
    try installNativeMethodOnProto(realm, proto, "withCalendar", plainDateWithCalendar, 1);
    try installNativeMethodOnProto(realm, proto, "toPlainYearMonth", plainDateToPlainYearMonth, 0);
    try installNativeMethodOnProto(realm, proto, "toPlainMonthDay", plainDateToPlainMonthDay, 0);
    try installNativeMethodOnProto(realm, proto, "toPlainDateTime", plainDateToPlainDateTime, 1);
    try installNativeMethodOnProto(realm, proto, "toZonedDateTime", plainDateToZonedDateTime, 1);

    try installNativeMethod(realm, fn_obj, "from", plainDateFrom, 1);
    try installNativeMethod(realm, fn_obj, "compare", plainDateCompare, 2);

    realm.intrinsics.temporal_plain_date_constructor = fn_obj;
    realm.intrinsics.temporal_plain_date_prototype = proto;
    try setNonEnumerable(ns, realm.allocator, "PlainDate", heap_mod.taggedFunction(fn_obj));
}

/// Coerce a truncated date field to i64, rejecting values far outside
/// the representable range (which also guards the later i32 cast).
fn dateFieldToI64(realm: *Realm, v: f64) NativeError!i64 {
    if (v < -1_000_000_000.0 or v > 1_000_000_000.0) return throwRangeError(realm, "date field is out of range");
    return @intFromFloat(v);
}

/// §3.1.1 — the `calendar` argument must be undefined or a string that
/// canonicalises to "iso8601" (Cynic ships only the ISO calendar). A
/// non-string is a TypeError; an unsupported/unknown calendar string is
/// a RangeError.
fn requireISOCalendar(realm: *Realm, calendar: Value) NativeError!void {
    if (calendar.isUndefined()) return;
    if (!calendar.isString()) return throwTypeError(realm, "calendar must be a string");
    const s: *JSString = @ptrCast(@alignCast(calendar.asString()));
    if (!std.ascii.eqlIgnoreCase(s.flatBytes(), "iso8601")) {
        return throwRangeError(realm, "only the iso8601 calendar is supported");
    }
}

/// The `calendar` field of a Temporal-date-like property bag must be
/// undefined or a String; a non-string (number, bigint, boolean, Symbol,
/// null, or a non-calendar-bearing object) is a TypeError. Full
/// canonicalisation of a calendar *string* — which may be a bare ID or an
/// ISO string whose `[u-ca=…]` annotation names the calendar — is deferred
/// with the rest of calendar support, so any accepted string resolves to
/// the ISO calendar Cynic ships. (Distinct from the constructor's
/// `requireISOCalendar`, which canonicalises a calendar ID strictly.)
fn requireCalendarFieldType(realm: *Realm, calendar: Value) NativeError!void {
    if (calendar.isUndefined()) return;
    if (!calendar.isString()) return throwTypeError(realm, "calendar must be a string");
}

fn storePlainDate(realm: *Realm, inst: *JSObject, rec: PlainDateRecord) NativeError!void {
    const r = realm.allocator.create(TemporalRecord) catch return error.OutOfMemory;
    r.* = .{ .plain_date = rec };
    inst.setTemporalRecord(realm.allocator, r) catch return error.OutOfMemory;
}

fn createTemporalDate(realm: *Realm, rec: PlainDateRecord) NativeError!Value {
    const inst = realm.heap.allocateObject() catch return error.OutOfMemory;
    realm.heap.setObjectPrototype(inst, realm.intrinsics.temporal_plain_date_prototype.?);
    try storePlainDate(realm, inst, rec);
    return heap_mod.taggedObject(inst);
}

fn requirePlainDate(realm: *Realm, this_value: Value) NativeError!PlainDateRecord {
    const obj = heap_mod.valueAsPlainObject(this_value) orelse
        return throwTypeError(realm, "not a Temporal.PlainDate");
    const rec = obj.getTemporalRecord() orelse
        return throwTypeError(realm, "not a Temporal.PlainDate");
    return switch (rec.*) {
        .plain_date => |pd| pd,
        else => throwTypeError(realm, "not a Temporal.PlainDate"),
    };
}

/// §3.1.1 Temporal.PlainDate ( isoYear, isoMonth, isoDay [, calendar] ).
fn plainDateConstructor(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const inst = heap_mod.valueAsPlainObject(this_value) orelse
        return throwTypeError(realm, "Temporal.PlainDate constructor requires 'new'");
    const y = try dateFieldToI64(realm, try toIntegerWithTruncation(realm, argOr(args, 0, Value.undefined_)));
    const m = try dateFieldToI64(realm, try toIntegerWithTruncation(realm, argOr(args, 1, Value.undefined_)));
    const d = try dateFieldToI64(realm, try toIntegerWithTruncation(realm, argOr(args, 2, Value.undefined_)));
    try requireISOCalendar(realm, argOr(args, 3, Value.undefined_));
    const rec = temporal.regulateISODate(y, m, d, true) orelse
        return throwRangeError(realm, "PlainDate is out of range");
    try storePlainDate(realm, inst, rec);
    return heap_mod.taggedObject(inst);
}

fn plainDateCalendarId(realm: *Realm, t: Value, a: []const Value) NativeError!Value {
    _ = a;
    _ = try requirePlainDate(realm, t);
    const js = realm.heap.allocateString("iso8601") catch return error.OutOfMemory;
    return Value.fromString(js);
}
fn plainDateYear(realm: *Realm, t: Value, a: []const Value) NativeError!Value {
    _ = a;
    return Value.fromInt32((try requirePlainDate(realm, t)).iso_year);
}
fn plainDateMonth(realm: *Realm, t: Value, a: []const Value) NativeError!Value {
    _ = a;
    return Value.fromInt32(@intCast((try requirePlainDate(realm, t)).iso_month));
}
fn plainDateDay(realm: *Realm, t: Value, a: []const Value) NativeError!Value {
    _ = a;
    return Value.fromInt32(@intCast((try requirePlainDate(realm, t)).iso_day));
}
fn plainDateMonthCode(realm: *Realm, t: Value, a: []const Value) NativeError!Value {
    _ = a;
    const rec = try requirePlainDate(realm, t);
    const mc = [_]u8{ 'M', '0' + @as(u8, @intCast(rec.iso_month / 10)), '0' + @as(u8, @intCast(rec.iso_month % 10)) };
    const js = realm.heap.allocateString(&mc) catch return error.OutOfMemory;
    return Value.fromString(js);
}
fn plainDateDayOfWeek(realm: *Realm, t: Value, a: []const Value) NativeError!Value {
    _ = a;
    const rec = try requirePlainDate(realm, t);
    return Value.fromInt32(temporal.isoDayOfWeek(rec.iso_year, rec.iso_month, rec.iso_day));
}
fn plainDateDayOfYear(realm: *Realm, t: Value, a: []const Value) NativeError!Value {
    _ = a;
    const rec = try requirePlainDate(realm, t);
    return Value.fromInt32(temporal.isoDayOfYear(rec.iso_year, rec.iso_month, rec.iso_day));
}
fn plainDateWeekOfYear(realm: *Realm, t: Value, a: []const Value) NativeError!Value {
    _ = a;
    const rec = try requirePlainDate(realm, t);
    return Value.fromInt32(temporal.isoWeekOfYear(rec.iso_year, rec.iso_month, rec.iso_day).week);
}
fn plainDateYearOfWeek(realm: *Realm, t: Value, a: []const Value) NativeError!Value {
    _ = a;
    const rec = try requirePlainDate(realm, t);
    return Value.fromInt32(temporal.isoWeekOfYear(rec.iso_year, rec.iso_month, rec.iso_day).year);
}
fn plainDateDaysInWeek(realm: *Realm, t: Value, a: []const Value) NativeError!Value {
    _ = a;
    _ = try requirePlainDate(realm, t);
    return Value.fromInt32(7);
}
fn plainDateDaysInMonth(realm: *Realm, t: Value, a: []const Value) NativeError!Value {
    _ = a;
    const rec = try requirePlainDate(realm, t);
    return Value.fromInt32(@intCast(temporal.daysInIsoMonth(rec.iso_year, rec.iso_month)));
}
fn plainDateDaysInYear(realm: *Realm, t: Value, a: []const Value) NativeError!Value {
    _ = a;
    const rec = try requirePlainDate(realm, t);
    return Value.fromInt32(temporal.isoDaysInYear(rec.iso_year));
}
fn plainDateMonthsInYear(realm: *Realm, t: Value, a: []const Value) NativeError!Value {
    _ = a;
    _ = try requirePlainDate(realm, t);
    return Value.fromInt32(12);
}
fn plainDateInLeapYear(realm: *Realm, t: Value, a: []const Value) NativeError!Value {
    _ = a;
    const rec = try requirePlainDate(realm, t);
    return Value.fromBool(temporal.isLeapYear(rec.iso_year));
}
fn plainDateEra(realm: *Realm, t: Value, a: []const Value) NativeError!Value {
    _ = a;
    _ = try requirePlainDate(realm, t);
    return Value.undefined_; // ISO calendar has no era
}
fn plainDateEraYear(realm: *Realm, t: Value, a: []const Value) NativeError!Value {
    _ = a;
    _ = try requirePlainDate(realm, t);
    return Value.undefined_;
}

/// §3.5.x parse an ISO monthCode ("M01".."M12"; no leap month in ISO).
/// The `monthCode` field must be a primitive String — a number, bigint,
/// boolean, Symbol, null, or object is a TypeError (it is never coerced),
/// distinct from the RangeError for a malformed string.
fn parseMonthCode(realm: *Realm, v: Value) NativeError!i64 {
    if (!v.isString()) return throwTypeError(realm, "monthCode must be a string");
    const s: *JSString = @ptrCast(@alignCast(v.asString()));
    const b = s.flatBytes();
    if (b.len != 3 or b[0] != 'M' or b[1] < '0' or b[1] > '9' or b[2] < '0' or b[2] > '9') {
        return throwRangeError(realm, "invalid monthCode");
    }
    const m: i64 = @as(i64, b[1] - '0') * 10 + @as(i64, b[2] - '0');
    if (m < 1 or m > 12) return throwRangeError(realm, "invalid monthCode");
    return m;
}

/// §3.5.x ISODateFromFields — read year, month/monthCode, day off a
/// property bag and regulate per `options`.
fn toISODateFields(realm: *Realm, obj: *JSObject, options: Value) NativeError!PlainDateRecord {
    // The calendar field (if present) must be undefined or a String;
    // the string's canonicalisation is deferred with calendar support.
    try requireCalendarFieldType(realm, try getPropertyChain(realm, obj, "calendar"));
    const day_v = try getPropertyChain(realm, obj, "day");
    const month_v = try getPropertyChain(realm, obj, "month");
    const month_code_v = try getPropertyChain(realm, obj, "monthCode");
    const year_v = try getPropertyChain(realm, obj, "year");
    if (year_v.isUndefined()) return throwTypeError(realm, "PlainDate-like is missing 'year'");
    if (day_v.isUndefined()) return throwTypeError(realm, "PlainDate-like is missing 'day'");
    const year = try dateFieldToI64(realm, try toIntegerWithTruncation(realm, year_v));
    const day = try dateFieldToI64(realm, try toIntegerWithTruncation(realm, day_v));
    var month: i64 = undefined;
    if (!month_code_v.isUndefined()) {
        month = try parseMonthCode(realm, month_code_v);
        if (!month_v.isUndefined()) {
            const m2 = try dateFieldToI64(realm, try toIntegerWithTruncation(realm, month_v));
            if (m2 != month) return throwRangeError(realm, "month and monthCode disagree");
        }
    } else if (!month_v.isUndefined()) {
        month = try dateFieldToI64(realm, try toIntegerWithTruncation(realm, month_v));
    } else {
        return throwTypeError(realm, "PlainDate-like is missing 'month' / 'monthCode'");
    }
    const overflow = try getTemporalOverflowOption(realm, options);
    return temporal.regulateISODate(year, month, day, overflow == .reject) orelse
        throwRangeError(realm, "PlainDate is out of range");
}

/// §3.5.x ToTemporalDate — a PlainDate (copy), a property bag, or an
/// ISO date string.
fn toTemporalDate(realm: *Realm, item: Value, options: Value) NativeError!PlainDateRecord {
    if (heap_mod.valueAsPlainObject(item)) |obj| {
        if (obj.getTemporalRecord()) |rec| {
            switch (rec.*) {
                .plain_date => |pd| {
                    _ = try getTemporalOverflowOption(realm, options);
                    return pd;
                },
                else => {},
            }
        }
        return toISODateFields(realm, obj, options);
    }
    if (!item.isString()) {
        return throwTypeError(realm, "Temporal.PlainDate.from expects an object or ISO 8601 string");
    }
    const s: *JSString = @ptrCast(@alignCast(item.asString()));
    const rec = temporal.parseTemporalDateString(s.flatBytes()) catch
        return throwRangeError(realm, "invalid ISO 8601 date string");
    _ = try getTemporalOverflowOption(realm, options);
    return rec;
}

fn compareISODate(a: PlainDateRecord, b: PlainDateRecord) i32 {
    if (a.iso_year != b.iso_year) return if (a.iso_year < b.iso_year) -1 else 1;
    if (a.iso_month != b.iso_month) return if (a.iso_month < b.iso_month) -1 else 1;
    if (a.iso_day != b.iso_day) return if (a.iso_day < b.iso_day) -1 else 1;
    return 0;
}

/// §3.2.2 Temporal.PlainDate.from ( item [, options] ).
fn plainDateFrom(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = this_value;
    const rec = try toTemporalDate(realm, argOr(args, 0, Value.undefined_), argOr(args, 1, Value.undefined_));
    return createTemporalDate(realm, rec);
}

/// §3.2.3 Temporal.PlainDate.compare ( one, two ).
fn plainDateCompare(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = this_value;
    const a = try toTemporalDate(realm, argOr(args, 0, Value.undefined_), Value.undefined_);
    const b = try toTemporalDate(realm, argOr(args, 1, Value.undefined_), Value.undefined_);
    return Value.fromInt32(compareISODate(a, b));
}

/// §3.3.x Temporal.PlainDate.prototype.equals ( other ).
fn plainDateEquals(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const a = try requirePlainDate(realm, this_value);
    const b = try toTemporalDate(realm, argOr(args, 0, Value.undefined_), Value.undefined_);
    return Value.fromBool(compareISODate(a, b) == 0);
}

/// §3.3.x Temporal.PlainDate.prototype.with ( temporalDateLike [, options] ).
fn plainDateWith(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const base = try requirePlainDate(realm, this_value);
    const like = argOr(args, 0, Value.undefined_);
    const obj = heap_mod.valueAsPlainObject(like) orelse
        return throwTypeError(realm, "PlainDate-like must be an object");
    try rejectTemporalLikeObject(realm, obj);

    var year: i64 = base.iso_year;
    var month: i64 = base.iso_month;
    var day: i64 = base.iso_day;
    var any = false;

    const day_v = try getPropertyChain(realm, obj, "day");
    if (!day_v.isUndefined()) {
        day = try dateFieldToI64(realm, try toIntegerWithTruncation(realm, day_v));
        any = true;
    }
    const month_v = try getPropertyChain(realm, obj, "month");
    const month_code_v = try getPropertyChain(realm, obj, "monthCode");
    if (!month_code_v.isUndefined()) {
        month = try parseMonthCode(realm, month_code_v);
        any = true;
        if (!month_v.isUndefined()) {
            const m2 = try dateFieldToI64(realm, try toIntegerWithTruncation(realm, month_v));
            if (m2 != month) return throwRangeError(realm, "month and monthCode disagree");
        }
    } else if (!month_v.isUndefined()) {
        month = try dateFieldToI64(realm, try toIntegerWithTruncation(realm, month_v));
        any = true;
    }
    const year_v = try getPropertyChain(realm, obj, "year");
    if (!year_v.isUndefined()) {
        year = try dateFieldToI64(realm, try toIntegerWithTruncation(realm, year_v));
        any = true;
    }
    if (!any) return throwTypeError(realm, "PlainDate-like must have at least one date property");

    const overflow = try getTemporalOverflowOption(realm, argOr(args, 1, Value.undefined_));
    const rec = temporal.regulateISODate(year, month, day, overflow == .reject) orelse
        return throwRangeError(realm, "PlainDate is out of range");
    return createTemporalDate(realm, rec);
}

/// §13.x GetTemporalShowCalendarNameOption — auto / always / never /
/// critical (default auto).
fn getCalendarNameOption(realm: *Realm, options: Value) NativeError!temporal.CalendarDisplay {
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

/// §3.3.x Temporal.PlainDate.prototype.toString ( [options] ).
fn plainDateToString(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const rec = try requirePlainDate(realm, this_value);
    const cal = try getCalendarNameOption(realm, argOr(args, 0, Value.undefined_));
    var buf: [40]u8 = undefined;
    const s = temporal.isoDateToString(rec, &buf, cal);
    const js = realm.heap.allocateString(s) catch return error.OutOfMemory;
    return Value.fromString(js);
}
fn plainDateToJSON(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    const rec = try requirePlainDate(realm, this_value);
    var buf: [40]u8 = undefined;
    const s = temporal.isoDateToString(rec, &buf, .auto);
    const js = realm.heap.allocateString(s) catch return error.OutOfMemory;
    return Value.fromString(js);
}
fn plainDateToLocaleString(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    return plainDateToJSON(realm, this_value, args);
}
fn plainDateValueOf(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = this_value;
    _ = args;
    return throwTypeError(realm, "Called valueOf on a Temporal.PlainDate; use compare() instead");
}

// Deferred PlainDate methods — date arithmetic and conversions to types
// Cynic doesn't ship yet.
fn plainDateAdd(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    _ = try requirePlainDate(realm, this_value);
    return throwTypeError(realm, "Temporal.PlainDate.prototype.add is not yet implemented");
}
fn plainDateSubtract(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    _ = try requirePlainDate(realm, this_value);
    return throwTypeError(realm, "Temporal.PlainDate.prototype.subtract is not yet implemented");
}
fn plainDateUntil(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    _ = try requirePlainDate(realm, this_value);
    return throwTypeError(realm, "Temporal.PlainDate.prototype.until is not yet implemented");
}
fn plainDateSince(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    _ = try requirePlainDate(realm, this_value);
    return throwTypeError(realm, "Temporal.PlainDate.prototype.since is not yet implemented");
}
fn plainDateWithCalendar(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    _ = try requirePlainDate(realm, this_value);
    return throwTypeError(realm, "Temporal.PlainDate.prototype.withCalendar is not yet implemented");
}
fn plainDateToPlainYearMonth(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    _ = try requirePlainDate(realm, this_value);
    return throwTypeError(realm, "Temporal.PlainDate.prototype.toPlainYearMonth is not yet implemented");
}
fn plainDateToPlainMonthDay(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    _ = try requirePlainDate(realm, this_value);
    return throwTypeError(realm, "Temporal.PlainDate.prototype.toPlainMonthDay is not yet implemented");
}
fn plainDateToPlainDateTime(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    _ = try requirePlainDate(realm, this_value);
    return throwTypeError(realm, "Temporal.PlainDate.prototype.toPlainDateTime is not yet implemented");
}
fn plainDateToZonedDateTime(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    _ = try requirePlainDate(realm, this_value);
    return throwTypeError(realm, "Temporal.PlainDate.prototype.toZonedDateTime is not yet implemented");
}
