//! Temporal.Now — clock readings (instant, time-zone id, ISO date/time
//! snapshots) on a frozen namespace under `Temporal`.

const std = @import("std");

const Realm = @import("../../realm.zig").Realm;
const Value = @import("../../value.zig").Value;
const JSObject = @import("../../object.zig").JSObject;
const NativeError = @import("../../function.zig").NativeError;
const heap_mod = @import("../../heap.zig");
const intrinsics = @import("../../intrinsics.zig");
const temporal = @import("../../temporal.zig");

const installNativeMethodOnProto = intrinsics.installNativeMethodOnProto;
const installToStringTag = intrinsics.installToStringTag;
const setNonEnumerable = intrinsics.setNonEnumerable;
const argOr = intrinsics.argOr;

const shared = @import("shared.zig");
const instant_mod = @import("instant.zig");
const zoned_date_time_mod = @import("zoned_date_time.zig");
const plain_date_time_mod = @import("plain_date_time.zig");
const plain_date_mod = @import("plain_date.zig");
const plain_time_mod = @import("plain_time.zig");

const toTimeZoneArg = shared.toTimeZoneArg;
const createTemporalInstant = instant_mod.createTemporalInstant;
const createTemporalZonedDateTime = zoned_date_time_mod.createTemporalZonedDateTime;
const createTemporalDateTime = plain_date_time_mod.createTemporalDateTime;
const createTemporalDate = plain_date_mod.createTemporalDate;
const createTemporalTime = plain_time_mod.createTemporalTime;

/// §2.1 The `Temporal.Now` namespace object — a plain object inheriting
/// %Object.prototype% with a `Symbol.toStringTag` of "Temporal.Now" and
/// the six clock-reading methods as non-enumerable data properties. Like
/// `Math` / `JSON`, it is not a constructor (no `[[Construct]]`, no
/// `prototype`). Stored in an intrinsic slot before its methods install
/// so it stays a GC root throughout (and the SES freeze pass reaches it
/// via the `Temporal` namespace).
pub fn install(realm: *Realm, ns: *JSObject) !void {
    const now = try realm.heap.allocateObject();
    realm.heap.setObjectPrototype(now, realm.intrinsics.object_prototype);
    realm.intrinsics.temporal_now_namespace = now;
    try installToStringTag(realm, now, "Temporal.Now");

    try installNativeMethodOnProto(realm, now, "instant", nowInstant, 0);
    try installNativeMethodOnProto(realm, now, "timeZoneId", nowTimeZoneId, 0);
    try installNativeMethodOnProto(realm, now, "zonedDateTimeISO", nowZonedDateTimeISO, 0);
    try installNativeMethodOnProto(realm, now, "plainDateTimeISO", nowPlainDateTimeISO, 0);
    try installNativeMethodOnProto(realm, now, "plainDateISO", nowPlainDateISO, 0);
    try installNativeMethodOnProto(realm, now, "plainTimeISO", nowPlainTimeISO, 0);

    // Non-enumerable, writable, configurable data property on the
    // namespace (§17), matching the per-type constructors.
    try setNonEnumerable(ns, realm.allocator, "Now", heap_mod.taggedObject(now));
}

/// §2.x SystemUTCEpochNanoseconds — the host wall clock as nanoseconds
/// since the Unix epoch. Mirrors `Date`'s host hook (libc
/// `clock_gettime(CLOCK_REALTIME)`); the freestanding playground build
/// has no ambient clock and resolves to the epoch (0), exactly like
/// `Date.now()` there. The value always lies well within the
/// ±8.64×10^21 ns Instant range, so no clamping is needed.
fn systemUTCEpochNanoseconds() i128 {
    if (@import("builtin").os.tag == .freestanding) return 0;
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts) != 0) return 0;
    const sec: i128 = ts.sec;
    const nsec: i128 = ts.nsec;
    return sec * 1_000_000_000 + nsec;
}

/// §2.x Resolve the optional `temporalTimeZoneLike` argument of the
/// `*ISO` Now methods. A missing argument or explicit `undefined` →
/// the system time zone (UTC in Cynic's no-tzdata scope); anything
/// else goes through ToTemporalTimeZoneIdentifier (string or
/// ZonedDateTime-bearing object; TypeError / RangeError otherwise).
fn nowTimeZoneArg(realm: *Realm, args: []const Value) NativeError!temporal.TimeZone {
    const arg = argOr(args, 0, Value.undefined_);
    if (arg.isUndefined()) return .utc;
    return toTimeZoneArg(realm, arg);
}

/// §2.3 Temporal.Now.instant ( ).
fn nowInstant(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = this_value;
    _ = args;
    return createTemporalInstant(realm, systemUTCEpochNanoseconds());
}

/// §2.2 Temporal.Now.timeZoneId ( ). Cynic's host ships no IANA tzdata,
/// so SystemTimeZoneIdentifier is always the UTC zone.
fn nowTimeZoneId(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = this_value;
    _ = args;
    var buf: [16]u8 = undefined;
    const s = temporal.timeZoneIdentifierString(.utc, &buf);
    const js = realm.heap.allocateString(s) catch return error.OutOfMemory;
    return Value.fromString(js);
}

/// §2.6 Temporal.Now.zonedDateTimeISO ( [ temporalTimeZoneLike ] ).
fn nowZonedDateTimeISO(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = this_value;
    const tz = try nowTimeZoneArg(realm, args);
    return createTemporalZonedDateTime(realm, .{ .epoch_ns = systemUTCEpochNanoseconds(), .time_zone = tz });
}

/// §2.4 Temporal.Now.plainDateTimeISO ( [ temporalTimeZoneLike ] ).
fn nowPlainDateTimeISO(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = this_value;
    const tz = try nowTimeZoneArg(realm, args);
    const dt = temporal.getISODateTimeFor(tz, systemUTCEpochNanoseconds());
    return createTemporalDateTime(realm, dt);
}

/// §2.5 Temporal.Now.plainDateISO ( [ temporalTimeZoneLike ] ).
fn nowPlainDateISO(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = this_value;
    const tz = try nowTimeZoneArg(realm, args);
    const dt = temporal.getISODateTimeFor(tz, systemUTCEpochNanoseconds());
    return createTemporalDate(realm, dt.date());
}

/// §2.x Temporal.Now.plainTimeISO ( [ temporalTimeZoneLike ] ). Derives
/// the wall-clock time directly from the system instant — it does not
/// route through PlainDateTime.prototype.toPlainTime (an observable
/// difference the `toPlainTime-override.js` fixture checks).
fn nowPlainTimeISO(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = this_value;
    const tz = try nowTimeZoneArg(realm, args);
    const dt = temporal.getISODateTimeFor(tz, systemUTCEpochNanoseconds());
    return createTemporalTime(realm, dt.time());
}
