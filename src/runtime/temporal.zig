//! Temporal — heap-side data structures + pure abstract operations.
//!
//! This file holds the engine-internal Zig structs for the Temporal
//! proposal's plain (calendar-free, time-zone-free) value types and
//! the abstract operations that are pure data computations — no JS
//! re-entry, no allocation of user-visible objects. The JS-visible
//! surface (constructors, prototype methods, `Temporal` namespace)
//! lives in `builtins/temporal.zig`.
//!
//! Implemented so far:
//!   • Temporal.Duration  (§7  proposal-temporal)
//!   • Temporal.PlainTime (§4  proposal-temporal)
//!
//! Both are immutable records of numeric fields. Duration fields are
//! ℝ-valued integers held as `f64` (they range up to 2^53 and the
//! spec's getters return Numbers); PlainTime fields are small
//! integers (0..59 / 0..999) held as `u32`. Neither carries a heap
//! pointer, so the GC marker needs no new mark edge — the record is
//! a plain side allocation freed in `JSObjectExtension.deinit`,
//! exactly like `MapData` / `SetData`.

const std = @import("std");
const intl_config = @import("intl_config.zig");

/// Brand discriminator for a Temporal instance. Stored alongside the
/// payload so a prototype method's `RequireInternalSlot` check is a
/// single tagged-union comparison that `Object.setPrototypeOf`
/// cannot defeat (mirrors the DisposableStack brand discipline).
pub const TemporalKind = enum {
    duration,
    plain_time,
    instant,
    plain_date,
    plain_date_time,
    plain_year_month,
    plain_month_day,
    zoned_date_time,
};

/// §7.5 Temporal.Duration internal slots. Each field is the ℝ
/// mathematical value the spec stores; the getters return them as
/// Numbers. Held as `f64` because the magnitude can reach 2^53 (the
/// max safe integer) and `seconds` etc. legitimately exceed `i32`.
pub const DurationRecord = struct {
    years: f64 = 0,
    months: f64 = 0,
    weeks: f64 = 0,
    days: f64 = 0,
    hours: f64 = 0,
    minutes: f64 = 0,
    seconds: f64 = 0,
    milliseconds: f64 = 0,
    microseconds: f64 = 0,
    nanoseconds: f64 = 0,
};

/// §4.5 Temporal.PlainTime internal slots ([[Time]] record). Every
/// field is range-validated at construction (`RejectTime`), so the
/// narrow integer widths are always in range.
pub const PlainTimeRecord = struct {
    hour: u32 = 0,
    minute: u32 = 0,
    second: u32 = 0,
    millisecond: u32 = 0,
    microsecond: u32 = 0,
    nanosecond: u32 = 0,
};

/// §8.1 Temporal.Instant internal slot ([[EpochNanoseconds]]). The
/// representable range is ±(86400 × 10^17) ns = ±8.64×10^21, which
/// fits an `i128` with room to spare, so the record carries no heap
/// pointer and adds no GC mark edge; it converts to/from a `JSBigInt`
/// only at the JS boundary, like the other plain records.
pub const InstantRecord = struct {
    epoch_ns: i128 = 0,
};

/// Maximum bytes for a stored calendar identifier (longest supported id is
/// `islamic-umalqura`). Fixed buffer keeps calendar-bearing records
/// allocator-free and GC-mark-free, matching the other Temporal payloads.
pub const max_calendar_id_bytes: usize = 24;

/// Default calendar id bytes: `"iso8601"` then zeros (comptime-init so
/// record field defaults compare cleanly).
const iso8601_calendar_bytes: [max_calendar_id_bytes]u8 = blk: {
    var b = std.mem.zeroes([max_calendar_id_bytes]u8);
    @memcpy(b[0..7], "iso8601");
    break :blk b;
};

/// Calendar identifier carried on calendar-bearing Temporal records.
/// Internally arithmetic stays ISO; the id is structural for Intl /
/// `calendarId` / serialization annotations only. `bytes` is always
/// zero-padded so struct equality is well-defined.
pub const CalendarId = struct {
    bytes: [max_calendar_id_bytes]u8 = iso8601_calendar_bytes,
    len: u8 = 7,

    pub fn iso8601() CalendarId {
        return .{ .bytes = iso8601_calendar_bytes, .len = 7 };
    }

    pub fn fromSlice(s: []const u8) ?CalendarId {
        if (s.len == 0 or s.len > max_calendar_id_bytes) return null;
        var b = std.mem.zeroes([max_calendar_id_bytes]u8);
        @memcpy(b[0..s.len], s);
        return .{ .bytes = b, .len = @intCast(s.len) };
    }

    pub fn slice(self: *const CalendarId) []const u8 {
        return self.bytes[0..self.len];
    }

    pub fn isIso(self: *const CalendarId) bool {
        return std.ascii.eqlIgnoreCase(self.slice(), "iso8601");
    }

    pub fn eql(self: *const CalendarId, other: *const CalendarId) bool {
        return std.ascii.eqlIgnoreCase(self.slice(), other.slice());
    }
};

/// ECMA-402 / Temporal supported calendar catalog (structural; matches
/// `Intl.supportedValuesOf("calendar")` / `intl.supported_calendars`).
// The generic "islamic" and sighting-based "islamic-rgsa" ids are DateTimeFormat
// fallbacks only — Temporal rejects them (intl402 .../from/islamic{,-rgsa}.js).
pub const supported_calendars = [_][]const u8{
    "buddhist", "chinese",  "coptic",  "dangi",         "ethioaa",      "ethiopic",
    "gregory",  "hebrew",   "indian",  "islamic-civil", "islamic-tbla", "islamic-umalqura",
    "iso8601",  "japanese", "persian", "roc",
};

/// Legacy aliases canonicalised at accept time (§Temporal calendar id +
/// ECMA-402 issues/285 aliases).
const calendar_aliases = [_]struct { from: []const u8, to: []const u8 }{
    .{ .from = "islamicc", .to = "islamic-civil" },
    .{ .from = "ethiopic-amete-alem", .to = "ethioaa" },
};

/// True when `id` is a supported calendar (case-insensitive), possibly via alias.
pub fn isSupportedCalendarId(id: []const u8) bool {
    return canonicalizeCalendarId(id) != null;
}

/// Return the canonical calendar id slice (static storage) or null.
pub fn canonicalizeCalendarId(id: []const u8) ?[]const u8 {
    for (calendar_aliases) |a| {
        if (std.ascii.eqlIgnoreCase(id, a.from)) return a.to;
    }
    for (supported_calendars) |c| {
        if (std.ascii.eqlIgnoreCase(id, c)) return c;
    }
    return null;
}

/// Build a `CalendarId` from a user/parser string, or null if unsupported.
pub fn calendarIdFromString(id: []const u8) ?CalendarId {
    const canon = canonicalizeCalendarId(id) orelse return null;
    return CalendarId.fromSlice(canon);
}

/// §3.5 Temporal.PlainDate internal slots ([[ISOYear]], [[ISOMonth]],
/// [[ISODay]], [[Calendar]]). Arithmetic uses ISO fields; `calendar`
/// is structural for Intl / `calendarId` only.
pub const PlainDateRecord = struct {
    iso_year: i32 = 0,
    iso_month: u8 = 1,
    iso_day: u8 = 1,
    calendar: CalendarId = .{},
};

/// §5.3 Temporal.PlainDateTime internal slots — an ISO date paired
/// with an ISO time ([[ISOYear]]…[[ISONanosecond]]) plus structural
/// [[Calendar]]. The split `date()` / `time()` helpers hand the existing
/// PlainDate / PlainTime abstract operations their narrower records, and
/// `combine` reassembles one after date- or time-only arithmetic.
pub const PlainDateTimeRecord = struct {
    iso_year: i32 = 0,
    iso_month: u8 = 1,
    iso_day: u8 = 1,
    hour: u32 = 0,
    minute: u32 = 0,
    second: u32 = 0,
    millisecond: u32 = 0,
    microsecond: u32 = 0,
    nanosecond: u32 = 0,
    calendar: CalendarId = .{},

    pub fn date(self: PlainDateTimeRecord) PlainDateRecord {
        return .{ .iso_year = self.iso_year, .iso_month = self.iso_month, .iso_day = self.iso_day, .calendar = self.calendar };
    }

    pub fn time(self: PlainDateTimeRecord) PlainTimeRecord {
        return .{
            .hour = self.hour,
            .minute = self.minute,
            .second = self.second,
            .millisecond = self.millisecond,
            .microsecond = self.microsecond,
            .nanosecond = self.nanosecond,
        };
    }

    pub fn combine(d: PlainDateRecord, t: PlainTimeRecord) PlainDateTimeRecord {
        return .{
            .iso_year = d.iso_year,
            .iso_month = d.iso_month,
            .iso_day = d.iso_day,
            .hour = t.hour,
            .minute = t.minute,
            .second = t.second,
            .millisecond = t.millisecond,
            .microsecond = t.microsecond,
            .nanosecond = t.nanosecond,
            .calendar = d.calendar,
        };
    }
};

/// §9.3 Temporal.PlainYearMonth internal slots — an ISO date whose day
/// is a *reference* day (the calendar's first-of-month, day 1 for ISO)
/// rather than an observable field. The year-month is the meaningful
/// part; `ref_iso_day` only fixes the underlying ISODate so the type can
/// reuse the PlainDate arithmetic / comparison AOs. `calendar` is structural.
pub const PlainYearMonthRecord = struct {
    iso_year: i32 = 0,
    iso_month: u8 = 1,
    ref_iso_day: u8 = 1,
    calendar: CalendarId = .{},

    pub fn date(self: PlainYearMonthRecord) PlainDateRecord {
        return .{ .iso_year = self.iso_year, .iso_month = self.iso_month, .iso_day = self.ref_iso_day, .calendar = self.calendar };
    }
};

/// §10.3 Temporal.PlainMonthDay internal slots — an ISO date whose year
/// is a *reference* year (1972 for ISO — a leap year, so Feb 29 is
/// representable) rather than an observable field. The month-day is the
/// meaningful part; `ref_iso_year` only fixes the underlying ISODate.
/// `calendar` is structural.
pub const PlainMonthDayRecord = struct {
    ref_iso_year: i32 = 1972,
    iso_month: u8 = 1,
    iso_day: u8 = 1,
    calendar: CalendarId = .{},

    pub fn date(self: PlainMonthDayRecord) PlainDateRecord {
        return .{ .iso_year = self.ref_iso_year, .iso_month = self.iso_month, .iso_day = self.iso_day, .calendar = self.calendar };
    }
};

/// Maximum bytes stored for a structural IANA zone identifier (fits in
/// the ZonedDateTime record without an extra allocator edge). Real
/// IANA names are well under this; anything longer is rejected.
pub const max_iana_zone_bytes: usize = 64;

/// The time zone of a `ZonedDateTimeRecord`. Offset / UTC zones have a
/// constant UTC offset. Named IANA zones are accepted structurally at
/// `-Dintl=stub` (identifier stored; offset treated as UTC); at
/// `-Dintl=full` the identifier must exist in the embedded tzdb and
/// `getOffsetNanosecondsFor` consults TZif transitions.
pub const TimeZone = union(enum) {
    /// The "UTC" named zone. A distinct identifier from the "+00:00"
    /// offset zone (the `timeZoneId` getters differ) though numerically
    /// the same offset.
    utc,
    /// An offset time-zone identifier, stored as whole minutes east of
    /// UTC in -1439..+1439.
    offset_minutes: i32,
    /// Structural IANA identifier (`America/New_York`, …). `len` is the
    /// live prefix of `bytes`; offset resolution is UTC (0) for now.
    named: struct {
        bytes: [max_iana_zone_bytes]u8 = undefined,
        len: u8 = 0,

        pub fn slice(self: *const @This()) []const u8 {
            return self.bytes[0..self.len];
        }
    },
};

/// §6.3 Temporal.ZonedDateTime internal slots — an exact instant
/// ([[EpochNanoseconds]]) paired with a [[TimeZone]] and structural
/// [[Calendar]]. No GC mark edge (all fields are plain / fixed buffers).
pub const ZonedDateTimeRecord = struct {
    epoch_ns: i128 = 0,
    time_zone: TimeZone = .utc,
    calendar: CalendarId = .{},
};

/// The side allocation a Temporal instance's `JSObject` points to
/// through `JSObjectExtension.temporal_record`. A tagged union so
/// the single slot serves every plain Temporal type.
pub const TemporalRecord = union(TemporalKind) {
    duration: DurationRecord,
    plain_time: PlainTimeRecord,
    instant: InstantRecord,
    plain_date: PlainDateRecord,
    plain_date_time: PlainDateTimeRecord,
    plain_year_month: PlainYearMonthRecord,
    plain_month_day: PlainMonthDayRecord,
    zoned_date_time: ZonedDateTimeRecord,

    pub fn deinit(self: *TemporalRecord, allocator: std.mem.Allocator) void {
        // No owned heap memory inside any variant today; the record
        // struct itself is freed by the extension via `destroy`.
        _ = self;
        _ = allocator;
    }
};

// ── §7.5 Duration abstract operations (pure) ──────────────────────────────

/// §7.5.10 DurationSign — returns -1, 0, or +1 by the sign of the
/// first non-zero field (date fields take precedence, then time).
pub fn durationSign(d: DurationRecord) i32 {
    const fields = [_]f64{
        d.years,        d.months,      d.weeks,   d.days,
        d.hours,        d.minutes,     d.seconds, d.milliseconds,
        d.microseconds, d.nanoseconds,
    };
    for (fields) |v| {
        if (v < 0) return -1;
        if (v > 0) return 1;
    }
    return 0;
}

/// §7.5.x CreateNegatedTemporalDuration — flip the sign of every field.
/// Used by the `subtract` methods, which negate the operand duration
/// and reuse the `add` path.
pub fn negateDuration(d: DurationRecord) DurationRecord {
    return .{
        .years = -d.years,
        .months = -d.months,
        .weeks = -d.weeks,
        .days = -d.days,
        .hours = -d.hours,
        .minutes = -d.minutes,
        .seconds = -d.seconds,
        .milliseconds = -d.milliseconds,
        .microseconds = -d.microseconds,
        .nanoseconds = -d.nanoseconds,
    };
}

/// §7.5.x IsValidDuration — the validity predicate `CreateTemporal
/// Duration` (and the `RejectDuration` polyfill helper) enforce.
///
/// Two independent checks:
///   1. All fields share a single sign (no mixed-sign duration).
///   2. years / months / weeks each have magnitude < 2^32, and the
///      total of all time + day units, normalised to seconds, is a
///      safe integer (≤ 9007199254740991.999999999 s).
///
/// Returns `false` when either check fails (the caller throws
/// RangeError). Infinite / NaN fields must be rejected by the
/// caller's `ToIntegerIfIntegral` before reaching here; this
/// predicate additionally guards against them for safety.
pub fn isValidDuration(d: DurationRecord) bool {
    const fields = [_]f64{
        d.years,        d.months,      d.weeks,   d.days,
        d.hours,        d.minutes,     d.seconds, d.milliseconds,
        d.microseconds, d.nanoseconds,
    };
    // Single-sign check (§ RejectDuration step 2).
    var sign: i32 = 0;
    for (fields) |v| {
        if (!std.math.isFinite(v)) return false;
        const s: i32 = if (v < 0) -1 else if (v > 0) 1 else 0;
        if (s != 0) {
            if (sign != 0 and s != sign) return false;
            sign = s;
        }
    }
    // years / months / weeks magnitude < 2^32.
    const two_pow_32: f64 = 4294967296.0;
    if (@abs(d.years) >= two_pow_32 or @abs(d.months) >= two_pow_32 or @abs(d.weeks) >= two_pow_32) {
        return false;
    }
    // Total of time units (with days as 86400 s) must be a safe
    // integer in seconds. The spec (§ IsValidDuration via
    // TruncatingDivModByPowerOf10) computes this on the *exact*
    // mathematical value of each Number field — it stringifies
    // the double with toFixed(0) and slices decimal digits, which
    // is exact integer arithmetic. f64 division can't reproduce
    // that: `µs / 1e6` rounds the quotient to nearest, so a true
    // value of …495.9999 rounds up to …496 and `trunc` then
    // reports one second too many, falsely rejecting a duration
    // whose real second-total is a safe integer. Do the split in
    // i128 instead — `@intFromFloat` yields the double's exact
    // integer value and `@divTrunc` / `@rem` truncate exactly,
    // matching the spec's digit-slice div/mod to the unit.
    //
    // Fields large enough to overflow the i128 products are also
    // far too large to be valid (the biggest a valid field can be
    // is ~9e24 ns ≈ 2^83, since the second-total must stay ≤ 2^53);
    // `durationFieldToI128` rejects anything ≥ 2^100, which both
    // guards the arithmetic and never refuses a representable
    // valid duration.
    const days_i = durationFieldToI128(d.days) orelse return false;
    const hours_i = durationFieldToI128(d.hours) orelse return false;
    const minutes_i = durationFieldToI128(d.minutes) orelse return false;
    const seconds_i = durationFieldToI128(d.seconds) orelse return false;
    const ms_i = durationFieldToI128(d.milliseconds) orelse return false;
    const us_i = durationFieldToI128(d.microseconds) orelse return false;
    const ns_i = durationFieldToI128(d.nanoseconds) orelse return false;

    const ms_div = @divTrunc(ms_i, 1_000);
    const ms_mod = @rem(ms_i, 1_000); // (-999..999) ms
    const us_div = @divTrunc(us_i, 1_000_000);
    const us_mod = @rem(us_i, 1_000_000); // (-999999..999999) µs
    const ns_div = @divTrunc(ns_i, 1_000_000_000);
    const ns_mod = @rem(ns_i, 1_000_000_000); // ns leftover
    // Sub-second leftovers, expressed in nanoseconds, contribute
    // their whole-second carry to the seconds total; the fractional
    // residue (< 1 s) is discarded, as the spec allows (…991.999999999).
    const remainder_ns = ms_mod * 1_000_000 + us_mod * 1_000 + ns_mod;
    const remainder_sec = @divTrunc(remainder_ns, 1_000_000_000);
    const total_sec = days_i * 86_400 + hours_i * 3_600 + minutes_i * 60 +
        seconds_i + ms_div + us_div + ns_div + remainder_sec;
    const max_safe: i128 = 9_007_199_254_740_991; // 2^53 − 1
    if (total_sec > max_safe or total_sec < -max_safe) return false;
    return true;
}

/// Convert a duration field (an integral, finite f64) to i128 for
/// exact arithmetic, returning null when the magnitude is so large
/// (≥ 2^100) that the value can't belong to a valid duration and
/// would risk overflowing the second-total products. No valid
/// duration field exceeds ~2^83, so this never rejects a
/// representable valid duration.
fn durationFieldToI128(v: f64) ?i128 {
    if (!std.math.isFinite(v)) return null;
    if (@abs(v) >= 0x1p100) return null;
    return @intFromFloat(v);
}

/// §7 maxTimeDuration — the largest magnitude, in nanoseconds, that
/// a TimeDuration record may hold: 2^53 × 10^9 − 1 =
/// 9007199254740991999999999. Add24HourDaysToTimeDuration and the
/// other time-duration constructors throw RangeError when a result
/// exceeds it in magnitude.
pub const max_time_duration_ns: i128 = 9_007_199_254_740_991_999_999_999;

/// §7.1 NumberIsSafeInteger — integral and |n| ≤ 2^53 − 1.
fn isSafeInteger(n: f64) bool {
    if (!std.math.isFinite(n)) return false;
    if (std.math.trunc(n) != n) return false;
    return @abs(n) <= 9007199254740991.0;
}

/// §7.5.x DefaultTemporalLargestUnit — the largest non-zero unit in
/// a duration. Only the "is it a sub-second-or-smaller unit" answer
/// is needed by `temporalDurationToString` (to decide whether a
/// `0S` seconds part is emitted for an all-zero duration), so this
/// returns a coarse classification.
pub const LargestUnit = enum { year, month, week, day, hour, minute, second, millisecond, microsecond, nanosecond };

pub fn defaultTemporalLargestUnit(d: DurationRecord) LargestUnit {
    if (d.years != 0) return .year;
    if (d.months != 0) return .month;
    if (d.weeks != 0) return .week;
    if (d.days != 0) return .day;
    if (d.hours != 0) return .hour;
    if (d.minutes != 0) return .minute;
    if (d.seconds != 0) return .second;
    if (d.milliseconds != 0) return .millisecond;
    if (d.microseconds != 0) return .microsecond;
    return .nanosecond;
}

// ── §7.5.x TemporalDurationToString (precision = "auto") ──────────────────

/// Format a Duration to its ISO-8601 string with `precision="auto"`
/// — the form `Temporal.Duration.prototype.toJSON` and the default
/// `toString()` produce. Writes into `buf` and returns the slice.
///
/// `buf` must be large enough; 128 bytes is ample (each of the four
/// date components and three time components is ≤ 11 digits, plus a
/// 9-digit fraction). The algorithm mirrors §7.5.x:
///   • sign prefix from DurationSign
///   • date part: Y / M / W / D for each non-zero field
///   • time part (after `T`): H / M, then a seconds part that
///     balances ms/µs/ns into whole seconds + a trimmed fraction.
pub fn temporalDurationToString(d: DurationRecord, buf: []u8, precision: Precision) []const u8 {
    var w = Writer{ .buf = buf, .len = 0 };
    const sign = durationSign(d);
    if (sign < 0) w.byte('-');
    w.byte('P');

    if (d.years != 0) {
        w.decimal(@abs(d.years));
        w.byte('Y');
    }
    if (d.months != 0) {
        w.decimal(@abs(d.months));
        w.byte('M');
    }
    if (d.weeks != 0) {
        w.decimal(@abs(d.weeks));
        w.byte('W');
    }
    if (d.days != 0) {
        w.decimal(@abs(d.days));
        w.byte('D');
    }

    // Time part. Keep sub-second units separate from `seconds` to
    // avoid precision loss when balancing into whole seconds.
    var time_buf: [96]u8 = undefined;
    var tw = Writer{ .buf = &time_buf, .len = 0 };
    if (d.hours != 0) {
        tw.decimal(@abs(d.hours));
        tw.byte('H');
    }
    if (d.minutes != 0) {
        tw.decimal(@abs(d.minutes));
        tw.byte('M');
    }

    // §7.5.x — total sub-second value in nanoseconds, balanced into
    // a whole-seconds part and a 0..999999999 nanosecond remainder.
    // Use i128 so the ms*1e6 product stays exact for the full safe-
    // integer range.
    const sec_whole = absI128(d.seconds);
    const sub_ns: i128 = absI128(d.milliseconds) * 1_000_000 +
        absI128(d.microseconds) * 1_000 +
        absI128(d.nanoseconds);
    const carry_sec = @divTrunc(sub_ns, 1_000_000_000);
    const frac_ns: i128 = @mod(sub_ns, 1_000_000_000);
    const seconds_total = sec_whole + carry_sec;

    const largest = defaultTemporalLargestUnit(d);
    const sub_second_largest = switch (largest) {
        .second, .millisecond, .microsecond, .nanosecond => true,
        else => false,
    };
    // Emit the seconds part when there's a non-zero seconds value, the
    // largest unit is second-or-smaller (so an all-zero duration still
    // renders "PT0S"), OR an explicit `fractionalSecondDigits` /
    // `smallestUnit` was given (a fixed precision always shows seconds).
    const auto_emit = seconds_total != 0 or frac_ns != 0 or sub_second_largest;
    const emit_seconds = switch (precision) {
        .auto, .minute => auto_emit,
        .digits => true,
    };
    if (emit_seconds) {
        tw.decimalI128(seconds_total);
        switch (precision) {
            .auto, .minute => if (frac_ns != 0) {
                tw.byte('.');
                tw.fraction9(@intCast(frac_ns));
            },
            .digits => |dd| if (dd > 0) {
                tw.byte('.');
                tw.fractionN(@intCast(frac_ns), dd);
            },
        }
        tw.byte('S');
    }

    if (tw.len != 0) {
        w.byte('T');
        w.bytes(time_buf[0..tw.len]);
    }
    return w.buf[0..w.len];
}

fn absI128(v: f64) i128 {
    return @intFromFloat(@abs(v));
}

/// Tiny fixed-buffer writer for the formatter — avoids an allocator
/// in a pure string-building routine.
const Writer = struct {
    buf: []u8,
    len: usize,

    fn byte(self: *Writer, c: u8) void {
        self.buf[self.len] = c;
        self.len += 1;
    }
    fn bytes(self: *Writer, s: []const u8) void {
        @memcpy(self.buf[self.len .. self.len + s.len], s);
        self.len += s.len;
    }
    /// Format a non-negative integral f64 in base 10. For values ≤
    /// 2^53 this is exact.
    fn decimal(self: *Writer, v: f64) void {
        self.decimalI128(@intFromFloat(v));
    }
    fn decimalI128(self: *Writer, v: i128) void {
        const s = std.fmt.bufPrint(self.buf[self.len..], "{d}", .{v}) catch unreachable;
        self.len += s.len;
    }
    /// Two-digit zero-padded field (`HH` / `MM` / `SS`).
    fn pad2(self: *Writer, v: u32) void {
        self.byte('0' + @as(u8, @intCast((v / 10) % 10)));
        self.byte('0' + @as(u8, @intCast(v % 10)));
    }
    /// Emit a 9-digit zero-padded fraction with trailing zeroes
    /// stripped (`precision="auto"`). Caller guarantees `ns` is in
    /// 1..999999999.
    fn fraction9(self: *Writer, ns: u32) void {
        var tmp: [9]u8 = undefined;
        var n = ns;
        var i: usize = 9;
        while (i > 0) {
            i -= 1;
            tmp[i] = '0' + @as(u8, @intCast(n % 10));
            n /= 10;
        }
        // Strip trailing zeroes.
        var end: usize = 9;
        while (end > 1 and tmp[end - 1] == '0') end -= 1;
        self.bytes(tmp[0..end]);
    }
    /// Emit exactly `digits` (1..9) most-significant digits of the
    /// nanosecond fraction `ns` (0..999999999), zero-padded, no trailing
    /// trim — the fixed-width form an explicit `fractionalSecondDigits`
    /// requests.
    fn fractionN(self: *Writer, ns: u32, digits: u4) void {
        var scale: u32 = 100_000_000; // 1e8 — most-significant of nine
        var rem = ns;
        var i: u4 = 0;
        while (i < digits) : (i += 1) {
            const digit = rem / scale;
            self.byte('0' + @as(u8, @intCast(digit)));
            rem -= digit * scale;
            scale /= 10;
        }
    }
};

// ── §7.5.x ParseTemporalDurationString ────────────────────────────────────

pub const ParseError = error{Invalid};

/// Apply a sign (+1 / -1) to a magnitude while normalising a zero
/// magnitude to +0 (never -0). The spec stores duration fields as ℝ
/// values, and a parsed `-PT1.03125H` has +0 microseconds, not -0 —
/// `assert.sameValue` distinguishes the two.
fn applySign(magnitude: f64, sign: f64) f64 {
    if (magnitude == 0) return 0;
    return magnitude * sign;
}

/// Parse an ISO-8601 duration string into a `DurationRecord`. Does
/// NOT validate magnitude limits — the caller runs `isValidDuration`
/// afterward (matching the polyfill's `RejectDuration` call inside
/// the raw parser, but kept separate here so the builtin can throw
/// the right error class).
///
/// Grammar (case-insensitive, §ISO 8601 duration as restricted by
/// the proposal):
///   sign? 'P' (n 'Y')? (n 'M')? (n 'W')? (n 'D')?
///         ('T' (nf 'H')? (nf 'M')? (nf 'S')?)?
/// where `nf` permits a `.`/`,` fraction of 1..9 digits, and only
/// the smallest present time unit may be fractional. At least one
/// component must be present.
pub fn parseTemporalDurationString(s: []const u8) ParseError!DurationRecord {
    var p = Parser{ .s = s, .i = 0 };

    var sign: f64 = 1;
    if (p.peek()) |c| {
        if (c == '+') {
            p.i += 1;
        } else if (c == '-' or c == 0xE2) {
            // ASCII '-' only (U+2212 minus is not accepted by the
            // duration grammar — only date/time offset grammars take
            // it). Treat a leading non-ASCII byte as invalid.
            if (c == '-') {
                sign = -1;
                p.i += 1;
            } else return error.Invalid;
        }
    }
    if (!p.eatIgnoreCase('P')) return error.Invalid;

    var d = DurationRecord{};
    var any = false;

    // Date part: Y, M, W, D — each an integer (no fraction).
    if (try p.intDesignator('Y')) |v| {
        d.years = applySign(v, sign);
        any = true;
    }
    if (try p.intDesignator('M')) |v| {
        d.months = applySign(v, sign);
        any = true;
    }
    if (try p.intDesignator('W')) |v| {
        d.weeks = applySign(v, sign);
        any = true;
    }
    if (try p.intDesignator('D')) |v| {
        d.days = applySign(v, sign);
        any = true;
    }

    // Time part: optional 'T' then H, M, S (each may carry a
    // fraction, but only the smallest present one).
    if (p.eatIgnoreCase('T')) {
        var saw_time = false;
        var excess_ns: i128 = 0; // fractional carry, in ns × multiplier
        var fraction_consumed = false;

        // Hours.
        if (try p.numDesignator('H')) |hn| {
            if (fraction_consumed) return error.Invalid;
            d.hours = applySign(hn.int, sign);
            saw_time = true;
            if (hn.frac_ns) |f| {
                excess_ns = @as(i128, f) * 3600;
                fraction_consumed = true;
            }
        }
        // Minutes.
        if (try p.numDesignator('M')) |mn| {
            if (fraction_consumed) return error.Invalid;
            d.minutes = applySign(mn.int, sign);
            saw_time = true;
            if (mn.frac_ns) |f| {
                excess_ns = @as(i128, f) * 60;
                fraction_consumed = true;
            }
        }
        // Seconds.
        if (try p.numDesignator('S')) |sn| {
            if (fraction_consumed) return error.Invalid;
            d.seconds = applySign(sn.int, sign);
            saw_time = true;
            if (sn.frac_ns) |f| {
                excess_ns = @as(i128, f);
                fraction_consumed = true;
            }
        }
        if (!saw_time) return error.Invalid; // 'T' with no component
        any = true;

        // Distribute the fractional carry. `excess_ns` is the
        // fraction expressed in whole nanoseconds, scaled by the
        // unit (×3600 for fractional hours, ×60 for minutes, ×1 for
        // seconds). Decompose per the polyfill:
        //   ns      = excess % 1000
        //   µs      = trunc(excess/1e3) % 1000
        //   ms      = trunc(excess/1e6) % 1000
        //   seconds += trunc(excess/1e9) % 60
        //   minutes += trunc(excess/60e9)
        if (excess_ns != 0) {
            const sgn: f64 = sign;
            const ns = @mod(excess_ns, 1000);
            const us = @mod(@divTrunc(excess_ns, 1000), 1000);
            const ms = @mod(@divTrunc(excess_ns, 1_000_000), 1000);
            const sec = @mod(@divTrunc(excess_ns, 1_000_000_000), 60);
            const min = @divTrunc(excess_ns, 60_000_000_000);
            d.nanoseconds = applySign(@floatFromInt(ns), sgn);
            d.microseconds = applySign(@floatFromInt(us), sgn);
            d.milliseconds = applySign(@floatFromInt(ms), sgn);
            // `seconds` / `minutes` already carry their (possibly +0)
            // integer part; add the fractional carry (sign-applied,
            // +0-normalised) on top.
            d.seconds += applySign(@floatFromInt(sec), sgn);
            d.minutes += applySign(@floatFromInt(min), sgn);
        }
    }

    if (!any) return error.Invalid; // bare "P" / "+P" is invalid
    if (p.i != p.s.len) return error.Invalid; // trailing junk
    return d;
}

const NumComponent = struct {
    int: f64,
    /// Fractional part scaled to whole nanoseconds (1..999999999),
    /// or null when there was no fraction.
    frac_ns: ?u32,
};

const Parser = struct {
    s: []const u8,
    i: usize,

    fn peek(self: *const Parser) ?u8 {
        if (self.i >= self.s.len) return null;
        return self.s[self.i];
    }

    fn eatIgnoreCase(self: *Parser, comptime upper: u8) bool {
        const c = self.peek() orelse return false;
        const lower = upper | 0x20;
        if (c == upper or c == lower) {
            self.i += 1;
            return true;
        }
        return false;
    }

    /// Parse `digits Designator` where Designator is a fixed letter
    /// (case-insensitive) and no fraction is allowed. Returns the
    /// integer value, or null if the next token isn't this
    /// designator. Errors only on a malformed number.
    fn intDesignator(self: *Parser, comptime designator: u8) ParseError!?f64 {
        const start = self.i;
        const digits = self.scanDigits();
        if (digits.len == 0) return null;
        // Must be followed by the designator letter.
        const c = self.peek() orelse {
            self.i = start;
            return null;
        };
        const lower = designator | 0x20;
        if (c != designator and c != lower) {
            self.i = start;
            return null;
        }
        self.i += 1; // consume designator
        return parseDigitsToF64(digits) catch error.Invalid;
    }

    /// Parse `digits ('.'|',') frac? Designator` for a time unit
    /// that may carry a fraction.
    fn numDesignator(self: *Parser, comptime designator: u8) ParseError!?NumComponent {
        const start = self.i;
        const digits = self.scanDigits();
        if (digits.len == 0) return null;
        var frac_ns: ?u32 = null;
        if (self.peek()) |c| {
            if (c == '.' or c == ',') {
                self.i += 1;
                const frac = self.scanDigits();
                if (frac.len == 0 or frac.len > 9) {
                    self.i = start;
                    return error.Invalid;
                }
                frac_ns = fractionToNanos(frac);
            }
        }
        const c = self.peek() orelse {
            self.i = start;
            return null;
        };
        const lower = designator | 0x20;
        if (c != designator and c != lower) {
            self.i = start;
            return null;
        }
        self.i += 1; // consume designator
        const int_val = parseDigitsToF64(digits) catch return error.Invalid;
        return NumComponent{ .int = int_val, .frac_ns = frac_ns };
    }

    fn scanDigits(self: *Parser) []const u8 {
        const start = self.i;
        while (self.i < self.s.len and self.s[self.i] >= '0' and self.s[self.i] <= '9') {
            self.i += 1;
        }
        return self.s[start..self.i];
    }
};

/// Convert a 1..9-digit fraction string to whole nanoseconds by
/// right-padding to 9 digits (`"5"` → 500000000 ns).
fn fractionToNanos(frac: []const u8) u32 {
    var padded: [9]u8 = .{ '0', '0', '0', '0', '0', '0', '0', '0', '0' };
    @memcpy(padded[0..frac.len], frac);
    var n: u32 = 0;
    for (padded) |c| n = n * 10 + (c - '0');
    return n;
}

fn parseDigitsToF64(digits: []const u8) !f64 {
    // The grammar permits arbitrarily many digits; values beyond
    // 2^53 are caught later by `isValidDuration`. `parseFloat` on a
    // pure-digit string gives the nearest f64, which matches
    // `ToIntegerWithTruncation`'s behaviour for an integer literal.
    return std.fmt.parseFloat(f64, digits);
}

// ── §4.5 PlainTime abstract operations (pure) ─────────────────────────────

/// §4.5.x RejectTime — every field must be in its ISO range. Returns
/// `false` (caller throws RangeError) on any out-of-range component.
pub fn isValidTime(t: PlainTimeRecord) bool {
    return t.hour <= 23 and t.minute <= 59 and t.second <= 59 and
        t.millisecond <= 999 and t.microsecond <= 999 and t.nanosecond <= 999;
}

/// Error set for the PlainTime ISO parser. `Invalid` ⇒ RangeError
/// (malformed / unsupported string); `UTCDesignator` ⇒ RangeError
/// too, but kept distinct so a caller could message it specifically.
pub const TimeParseError = error{ Invalid, UTCDesignator };

/// §4.5.x ParseTemporalTimeString — parse the time component of an
/// ISO-8601 string into a `PlainTimeRecord`. Handles the shapes the
/// PlainTime `from` / `equals` / `compare` string paths accept:
///
///   • bare time:        `HH`, `HH:MM`, `HH:MM:SS`, `HH:MM:SS.fff`
///                       (and the compact `HHMMSS` forms)
///   • date-time:        `YYYY-MM-DD` + (`T` | `t` | space) + time
///   • a leading `T`/`t` time designator
///   • a trailing UTC offset: `+HH…` / `-HH…` (parsed, discarded)
///   • trailing annotations: `[…]` (one or more, discarded)
///
/// A `Z`/`z` UTC designator is rejected (`error.UTCDesignator`) —
/// §4.5.x forbids it for a PlainTime. A `60` seconds value (leap
/// second) is clamped to `59` per the spec's leap-second handling.
pub fn parseTemporalTimeString(input: []const u8) TimeParseError!PlainTimeRecord {
    var s = input;

    // Split off the trailing RFC 9557 annotation blocks at the first `[`
    // and validate them with the shared grammar (consumeAnnotations):
    // duplicate time-zone annotations, a time-zone annotation following a
    // key=value one, capitalised annotation keys, unknown critical
    // annotations, and >1 critical calendar are all rejected. The time /
    // UTC-offset portion preceding the annotations never contains a `[`,
    // so the first one cleanly delimits them. (A bare strip-and-discard
    // accepted every malformed block.)
    if (std.mem.indexOfScalar(u8, s, '[')) |ann_start| {
        var c = Cursor{ .s = s[ann_start..] };
        _ = consumeAnnotations(&c) catch return error.Invalid;
        if (!c.done()) return error.Invalid; // trailing junk after the annotations
        s = s[0..ann_start];
    }

    // A date-time string starts with a date (`YYYY-MM-DD` or the
    // compact `YYYYMMDD` / `±YYYYYY-MM-DD`). Detect a date prefix
    // followed by a `T`/`t`/space separator and skip to the time.
    // `had_designator` tracks whether a `T` (or date+separator)
    // preceded the time — that disambiguates the colon-free compact
    // forms (`1214`), which are otherwise ambiguous with a calendar
    // date (MMDD) and rejected for a bare PlainTime string.
    var had_designator = false;
    switch (classifyDatePrefix(s)) {
        .time_after_date => |rest| {
            s = rest;
            had_designator = true;
        },
        // A date with no time separator (`2022-09-15`,
        // `2022-09-15+00:00`) carries no time component — invalid
        // for a PlainTime.
        .date_only => return error.Invalid,
        .no_date => if (s.len > 0 and (s[0] == 'T' or s[0] == 't')) {
            s = s[1..];
            had_designator = true;
        },
    }

    // §ISO 8601 ambiguity (Temporal grammar): with no `T` designator,
    // a dashed `YYYY-MM` (DateSpecYearMonth) or `MM-DD`
    // (DateSpecMonthDay) is ambiguous with a date spec and must be
    // rejected for a bare PlainTime — only a `T` prefix forces the
    // time reading. These dashed forms reach here because the
    // `-MM` / `-DD` tail would otherwise be mis-read as a UTC offset
    // below, parsing the prefix as a compact `HHMM` time. (The
    // colon-free compact `YYYYMM` / `MMDD` equivalents are
    // disambiguated inside parseBareTime.)
    if (!had_designator and isAmbiguousExtendedDateSpec(s)) return error.Invalid;

    // Split off a trailing UTC offset or `Z` designator. The
    // offset (when present) MUST consume the rest of the string —
    // trailing junk (`00:00:00+00:00junk`) is invalid.
    var time_part = s;
    // `Z` / `z` UTC designator: only valid as the final character.
    if (s.len > 0 and (s[s.len - 1] == 'Z' or s[s.len - 1] == 'z')) {
        return error.UTCDesignator;
    }
    // A `+`/`-` begins a UTC offset suffix; validate it to end.
    var sign_idx: ?usize = null;
    for (s, 0..) |c, k| {
        if (c == '+' or c == '-') {
            sign_idx = k;
            break;
        }
        // A stray `Z` mid-string (e.g. `00:00Zjunk`) is rejected by
        // parseBareTime below; we only special-case the offset sign
        // here.
    }
    if (sign_idx) |idx| {
        if (!isValidUtcOffset(s[idx..])) return error.Invalid;
        time_part = s[0..idx];
    }

    return parseBareTime(time_part, had_designator) catch error.Invalid;
}

/// Validate a UTC offset suffix `[+-]HH`, `[+-]HH:MM`,
/// `[+-]HH:MM:SS`, `[+-]HH:MM:SS(.|,)fff`, or the compact colon-free
/// forms — and require it to consume the whole slice. Hours ≤ 23,
/// minutes/seconds ≤ 59. Colon-consistency must hold (either every
/// separator present or none). The numeric value is discarded; only
/// well-formedness matters for a PlainTime.
fn isValidUtcOffset(s: []const u8) bool {
    if (s.len < 3) return false; // at least sign + HH
    if (s[0] != '+' and s[0] != '-') return false;
    var i: usize = 1;
    const hour = read2(s, &i) orelse return false;
    if (hour > 23) return false;
    if (i == s.len) return true; // [+-]HH
    const extended = s[i] == ':';
    if (extended) {
        i += 1;
        const minute = read2(s, &i) orelse return false;
        if (minute > 59) return false;
        if (i == s.len) return true; // [+-]HH:MM
        if (s[i] != ':') return false; // separator must be consistent
        i += 1;
        const second = read2(s, &i) orelse return false;
        if (second > 59) return false;
    } else {
        // Compact: HHMM or HHMMSS.
        const minute = read2(s, &i) orelse return false;
        if (minute > 59) return false;
        if (i == s.len) return true; // [+-]HHMM
        const second = read2(s, &i) orelse return false;
        if (second > 59) return false;
    }
    // Optional sub-second fraction on the offset seconds.
    const sub = readFraction(s, &i) catch return false;
    _ = sub;
    return i == s.len;
}

const DatePrefix = union(enum) {
    /// `s` had a date prefix followed by a `T`/`t`/space separator;
    /// payload is the slice after the separator (the time portion).
    time_after_date: []const u8,
    /// `s` had a date prefix but NO time separator — a date-only
    /// string (invalid for a PlainTime).
    date_only,
    /// `s` did not start with a date.
    no_date,
};

/// Classify the leading date portion of `s`. Recognises the
/// extended `YYYY-MM-DD` form and the compact `YYYYMMDD` form, with
/// an optional `±` six-digit expanded year, followed (or not) by a
/// `T`/`t`/space separator.
fn classifyDatePrefix(s: []const u8) DatePrefix {
    var i: usize = 0;
    var neg_zero_year = false;
    // Optional expanded-year sign.
    if (i < s.len and (s[i] == '+' or s[i] == '-')) {
        // Expanded year is ±YYYYYY (six digits). A `-000000` (minus
        // zero) expanded year is forbidden (§ISO 8601 / year-zero.js).
        const sign_minus = s[i] == '-';
        i += 1;
        const year_start = i;
        if (!skipDigits(s, &i, 6)) return .no_date;
        if (sign_minus) {
            var all_zero = true;
            for (s[year_start..i]) |c| {
                if (c != '0') {
                    all_zero = false;
                    break;
                }
            }
            if (all_zero) neg_zero_year = true;
        }
    } else {
        if (!skipDigits(s, &i, 4)) return .no_date;
    }
    // A forbidden negative-zero expanded year makes the whole string
    // invalid — surface as `.date_only` (PlainTime maps both to
    // RangeError).
    if (neg_zero_year) return .date_only;
    // `-MM-DD` extended or `MMDD` compact.
    if (i < s.len and s[i] == '-') {
        i += 1;
        if (!skipDigits(s, &i, 2)) return .no_date;
        if (i >= s.len or s[i] != '-') return .no_date;
        i += 1;
        if (!skipDigits(s, &i, 2)) return .no_date;
    } else {
        if (!skipDigits(s, &i, 2)) return .no_date;
        if (!skipDigits(s, &i, 2)) return .no_date;
    }
    // Separator decides date-time vs date-only.
    if (i < s.len and (s[i] == 'T' or s[i] == 't' or s[i] == ' ')) {
        return .{ .time_after_date = s[i + 1 ..] };
    }
    return .date_only;
}

fn skipDigits(s: []const u8, i: *usize, n: usize) bool {
    if (i.* + n > s.len) return false;
    var k: usize = 0;
    while (k < n) : (k += 1) {
        const c = s[i.* + k];
        if (c < '0' or c > '9') return false;
    }
    i.* += n;
    return true;
}

/// Whether `m` is a valid ISO month (1..12). Used by the compact
/// time/date disambiguation.
fn isValidMonth(m: u32) bool {
    return m >= 1 and m <= 12;
}

/// Whether `(month, day)` could be a valid ISO calendar date in some
/// year (the disambiguation uses the most-permissive year, so Feb
/// allows 29). A compact `MMDD` that satisfies this is ambiguous
/// with a date and rejected as a bare PlainTime string.
fn isValidMonthDay(month: u32, day: u32) bool {
    if (!isValidMonth(month)) return false;
    const max_day: u32 = switch (month) {
        1, 3, 5, 7, 8, 10, 12 => 31,
        4, 6, 9, 11 => 30,
        2 => 29, // leap-permissive
        else => 0,
    };
    return day >= 1 and day <= max_day;
}

/// Whether `s` is a bare extended date-spec — `YYYY-MM`
/// (DateSpecYearMonth) or `MM-DD` (DateSpecMonthDay). A PlainTime
/// string treats both as ambiguous and rejects them unless a `T`
/// designator forces the time reading. The colon-free compact
/// equivalents (`YYYYMM`, `MMDD`) are handled in parseBareTime; these
/// dashed forms would otherwise be mis-parsed as a compact `HHMM`
/// time plus a `-MM` / `-DD` UTC offset.
fn isAmbiguousExtendedDateSpec(s: []const u8) bool {
    // YYYY-MM : four digits, '-', two-digit month in 1..12.
    if (s.len == 7 and s[4] == '-') {
        var i: usize = 0;
        if (!skipDigits(s, &i, 4)) return false;
        i += 1; // skip the '-'
        const month = read2(s, &i) orelse return false;
        return i == s.len and isValidMonth(month);
    }
    // MM-DD : two-digit month, '-', two-digit day valid for the month.
    if (s.len == 5 and s[2] == '-') {
        var i: usize = 0;
        const month = read2(s, &i) orelse return false;
        i += 1; // skip the '-'
        const day = read2(s, &i) orelse return false;
        return i == s.len and isValidMonthDay(month, day);
    }
    return false;
}

/// Parse the bare time portion: `HH`, `HH:MM`, `HH:MM:SS`,
/// `HH:MM:SS(.|,)fff`, or the compact colon-free forms. Clamps a
/// `60` seconds value (leap second) to 59.
///
/// `had_designator` — whether a `T` (or date + separator) preceded
/// this time. A colon-free compact form (`1214`, `202112`) that
/// follows no designator is ambiguous with a calendar date and is
/// rejected when the same digits could spell a valid date
/// (`1214` = Dec 14; `202112` = 2021-12) per §ISO 8601 disambiguation
/// — only a `T` prefix disambiguates it as a time.
fn parseBareTime(s: []const u8, had_designator: bool) error{Invalid}!PlainTimeRecord {
    if (s.len < 2) return error.Invalid;
    var i: usize = 0;
    const hour = read2(s, &i) orelse return error.Invalid;
    var minute: u32 = 0;
    var second: u32 = 0;
    var sub_ns: u32 = 0;
    const extended = i < s.len and s[i] == ':';
    var compact_digits: usize = 2; // count of bare HH..SS digits

    if (i < s.len) {
        if (extended) {
            i += 1;
            minute = read2(s, &i) orelse return error.Invalid;
            if (i < s.len and s[i] == ':') {
                i += 1;
                second = read2(s, &i) orelse return error.Invalid;
                sub_ns = try readFraction(s, &i);
            }
        } else if (s[i] >= '0' and s[i] <= '9') {
            // Compact `HHMM` / `HHMMSS`.
            minute = read2(s, &i) orelse return error.Invalid;
            compact_digits = 4;
            if (i < s.len and s[i] >= '0' and s[i] <= '9') {
                second = read2(s, &i) orelse return error.Invalid;
                compact_digits = 6;
            }
            sub_ns = try readFraction(s, &i);
        } else if (s[i] == '.' or s[i] == ',') {
            // `HH.fff` — no minutes/seconds but a fraction is invalid
            // for the bare-hour form per the grammar.
            return error.Invalid;
        }
    }
    if (i != s.len) return error.Invalid;

    // §ISO 8601 date/time disambiguation — a colon-free compact time
    // with no `T` designator and no fraction that could equally spell
    // a valid calendar date is rejected as ambiguous (the caller must
    // add a `T`). Only the no-fraction case is ambiguous; a fraction
    // forces the time reading.
    if (!had_designator and !extended and sub_ns == 0) {
        if (compact_digits == 4 and isValidMonthDay(hour, minute)) return error.Invalid;
        if (compact_digits == 6 and isValidMonth(second)) return error.Invalid;
    }

    // Leap second: clamp 60 → 59.
    if (second == 60) second = 59;

    const t = PlainTimeRecord{
        .hour = hour,
        .minute = minute,
        .second = second,
        .millisecond = sub_ns / 1_000_000,
        .microsecond = (sub_ns / 1_000) % 1_000,
        .nanosecond = sub_ns % 1_000,
    };
    if (!isValidTime(t)) return error.Invalid;
    return t;
}

/// Read exactly two ASCII digits at `*i`, advancing it.
fn read2(s: []const u8, i: *usize) ?u32 {
    if (i.* + 2 > s.len) return null;
    const a = s[i.*];
    const b = s[i.* + 1];
    if (a < '0' or a > '9' or b < '0' or b > '9') return null;
    i.* += 2;
    return (a - '0') * @as(u32, 10) + (b - '0');
}

/// Read an optional `.`/`,` fraction (1..9 digits) at `*i`. Returns
/// the value in whole nanoseconds, or 0 when no fraction follows.
fn readFraction(s: []const u8, i: *usize) error{Invalid}!u32 {
    if (i.* >= s.len or (s[i.*] != '.' and s[i.*] != ',')) return 0;
    i.* += 1;
    const start = i.*;
    while (i.* < s.len and s[i.*] >= '0' and s[i.*] <= '9') i.* += 1;
    const len = i.* - start;
    if (len == 0 or len > 9) return error.Invalid;
    return fractionToNanos(s[start..i.*]);
}

/// §4.5.x CompareTimeRecord — lexicographic by field, returns -1/0/1.
pub fn compareTime(a: PlainTimeRecord, b: PlainTimeRecord) i32 {
    if (a.hour != b.hour) return if (a.hour < b.hour) -1 else 1;
    if (a.minute != b.minute) return if (a.minute < b.minute) -1 else 1;
    if (a.second != b.second) return if (a.second < b.second) -1 else 1;
    if (a.millisecond != b.millisecond) return if (a.millisecond < b.millisecond) -1 else 1;
    if (a.microsecond != b.microsecond) return if (a.microsecond < b.microsecond) -1 else 1;
    if (a.nanosecond != b.nanosecond) return if (a.nanosecond < b.nanosecond) -1 else 1;
    return 0;
}

/// §4.5.x TimeRecordToString with `precision="auto"` — the form
/// `PlainTime.prototype.toJSON` / default `toString` produce:
/// `HH:MM:SS` plus a trimmed sub-second fraction when any sub-second
/// field is non-zero.
/// §4.3.x TimeRecordToString — format a wall-clock time at `precision`
/// (FormatTimeString). `.auto` emits `HH:MM:SS` and trims the fraction
/// (omitting it when zero); `.minute` stops after `HH:MM`; `.digits`
/// emits exactly N fractional digits.
pub fn plainTimeToString(t: PlainTimeRecord, buf: []u8, precision: Precision) []const u8 {
    var w = Writer{ .buf = buf, .len = 0 };
    const sub_ns: u32 = t.millisecond * 1_000_000 + t.microsecond * 1_000 + t.nanosecond;
    writeTimeFields(&w, t.hour, t.minute, t.second, sub_ns, precision);
    return w.buf[0..w.len];
}

// ── §8 Temporal.Instant abstract operations (pure) ────────────────────────

/// §8.x nsMinInstant / nsMaxInstant — the inclusive epoch-nanosecond
/// bounds of a representable Instant: ±(86400 × 10^17) ns (±10^8 days
/// from the epoch). Equal to the nanosecond form of the legacy Date
/// ±8.64×10^15 ms range, so `Date.prototype.toTemporalInstant` never
/// overflows.
pub const ns_min_instant: i128 = -8_640_000_000_000_000_000_000;
pub const ns_max_instant: i128 = 8_640_000_000_000_000_000_000;

/// §8.x IsValidEpochNanoseconds — within the inclusive instant bounds.
pub fn isValidEpochNanoseconds(ns: i128) bool {
    return ns >= ns_min_instant and ns <= ns_max_instant;
}

/// §8.x AddInstant — add a signed nanosecond delta to an epoch-ns
/// value, returning null when the result leaves the representable
/// range (the caller throws RangeError). The i128 sum cannot overflow:
/// a valid Instant is ≤ 8.64×10^21 and a valid Duration's time total
/// is ≤ ~9×10^24 ns, both far inside i128.
pub fn addInstant(epoch_ns: i128, delta_ns: i128) ?i128 {
    const sum = epoch_ns + delta_ns;
    if (!isValidEpochNanoseconds(sum)) return null;
    return sum;
}

/// Total nanoseconds contributed by a duration's time components
/// (hours and smaller). Callers performing Instant arithmetic must
/// first verify the date components (years/months/weeks/days) are
/// zero — §8 disallows calendar units. Exact for the valid duration
/// range (each field is an integer ≤ 2^53).
pub fn timeDurationNanoseconds(d: DurationRecord) i128 {
    return f64ToI128(d.hours) * 3_600_000_000_000 +
        f64ToI128(d.minutes) * 60_000_000_000 +
        f64ToI128(d.seconds) * 1_000_000_000 +
        f64ToI128(d.milliseconds) * 1_000_000 +
        f64ToI128(d.microseconds) * 1_000 +
        f64ToI128(d.nanoseconds);
}

fn f64ToI128(v: f64) i128 {
    return @intFromFloat(v);
}

/// §8.x CompareEpochNanoseconds — -1 / 0 / +1.
pub fn compareInstant(a: i128, b: i128) i32 {
    if (a < b) return -1;
    if (a > b) return 1;
    return 0;
}

// ── Proleptic-Gregorian civil-date math (Howard Hinnant) ──────────────────
// Implemented here in the runtime layer so Temporal stays independent
// of `builtins/date.zig` (runtime must not depend on the builtins
// layer). Valid across the whole Temporal year range.

const Ymd = struct { year: i64, month: u32, day: u32 };

/// Days from 1970-01-01 to a proleptic-Gregorian date. `month` is
/// 1..12, `day` 1..31.
pub fn daysFromCivil(year: i64, month: u32, day: u32) i64 {
    const m: i64 = @intCast(month);
    const d: i64 = @intCast(day);
    const y: i64 = year - (if (month <= 2) @as(i64, 1) else 0);
    const era: i64 = @divTrunc(if (y >= 0) y else y - 399, 400);
    const yoe: i64 = y - era * 400; // [0, 399]
    const doy: i64 = @divTrunc(153 * (if (m > 2) m - 3 else m + 9) + 2, 5) + d - 1; // [0, 365]
    const doe: i64 = yoe * 365 + @divTrunc(yoe, 4) - @divTrunc(yoe, 100) + doy; // [0, 146096]
    return era * 146097 + doe - 719468;
}

/// Inverse of `daysFromCivil`.
pub fn civilFromDays(z_in: i64) Ymd {
    const z: i64 = z_in + 719468;
    const era: i64 = @divTrunc(if (z >= 0) z else z - 146096, 146097);
    const doe: i64 = z - era * 146097; // [0, 146096]
    const yoe: i64 = @divTrunc(doe - @divTrunc(doe, 1460) + @divTrunc(doe, 36524) - @divTrunc(doe, 146096), 365); // [0, 399]
    const y: i64 = yoe + era * 400;
    const doy: i64 = doe - (365 * yoe + @divTrunc(yoe, 4) - @divTrunc(yoe, 100)); // [0, 365]
    const mp: i64 = @divTrunc(5 * doy + 2, 153); // [0, 11]
    const d: i64 = doy - @divTrunc(153 * mp + 2, 5) + 1; // [1, 31]
    const m: i64 = if (mp < 10) mp + 3 else mp - 9; // [1, 12]
    return .{ .year = y + (if (m <= 2) @as(i64, 1) else 0), .month = @intCast(m), .day = @intCast(d) };
}

pub fn isLeapYear(y: i64) bool {
    return (@mod(y, 4) == 0 and @mod(y, 100) != 0) or @mod(y, 400) == 0;
}

pub fn daysInIsoMonth(y: i64, m: u32) u32 {
    return switch (m) {
        1, 3, 5, 7, 8, 10, 12 => 31,
        4, 6, 9, 11 => 30,
        2 => if (isLeapYear(y)) @as(u32, 29) else 28,
        else => 0,
    };
}

// ── §6 Temporal.ZonedDateTime core operations ─────────────────────────────
// An exact instant viewed through a time zone. The offset-only `TimeZone`
// scope keeps every operation a pure i128 computation; the named-IANA-zone
// path a future Intl build would add funnels through the one offset seam,
// `getOffsetNanosecondsFor`.

/// §11.x GetOffsetNanosecondsFor — the signed UTC offset, in nanoseconds,
/// that `tz` applies at `epoch_ns`. UTC and offset zones have a constant
/// offset. Named IANA zones consult embedded tzdata at `-Dintl=full`; at
/// `stub` they remain structural (offset 0 / UTC math).
pub fn getOffsetNanosecondsFor(tz: TimeZone, epoch_ns: i128) i64 {
    return switch (tz) {
        .utc => 0,
        .offset_minutes => |m| @as(i64, m) * 60_000_000_000,
        .named => |n| blk: {
            if (intl_config.has_locale_data) {
                break :blk @import("tzdata.zig").offsetNanosecondsFor(n.slice(), epoch_ns);
            }
            break :blk 0;
        },
    };
}

/// Decompose an epoch-nanosecond value into ISO date-time fields,
/// flooring toward −∞ so pre-epoch instants land on the correct civil
/// day. Inverse of `isoDateTimeToEpochNs`.
pub fn isoDateTimeFromEpochNs(ns: i128) PlainDateTimeRecord {
    const sec = @divFloor(ns, 1_000_000_000);
    const sub_ns: u32 = @intCast(ns - sec * 1_000_000_000); // [0, 10^9)
    const days = @divFloor(sec, 86400);
    const sod = sec - days * 86400; // [0, 86399]
    const ymd = civilFromDays(@intCast(days));
    return .{
        .iso_year = @intCast(ymd.year),
        .iso_month = @intCast(ymd.month),
        .iso_day = @intCast(ymd.day),
        .hour = @intCast(@divTrunc(sod, 3600)),
        .minute = @intCast(@divTrunc(@mod(sod, 3600), 60)),
        .second = @intCast(@mod(sod, 60)),
        .millisecond = sub_ns / 1_000_000,
        .microsecond = (sub_ns / 1_000) % 1_000,
        .nanosecond = sub_ns % 1_000,
    };
}

/// The epoch-nanosecond value of an ISO date-time read as UTC wall-clock
/// (no zone offset applied). Inverse of `isoDateTimeFromEpochNs`.
pub fn isoDateTimeToEpochNs(dt: PlainDateTimeRecord) i128 {
    const epoch_days = daysFromCivil(dt.iso_year, dt.iso_month, dt.iso_day);
    const sec: i128 = @as(i128, epoch_days) * 86400 +
        @as(i128, dt.hour) * 3600 + @as(i128, dt.minute) * 60 + @as(i128, dt.second);
    return sec * 1_000_000_000 +
        @as(i128, dt.millisecond) * 1_000_000 +
        @as(i128, dt.microsecond) * 1_000 +
        @as(i128, dt.nanosecond);
}

/// §6.5.x GetISODateTimeFor — the local (wall-clock) ISO date-time that
/// `tz` shows at `epoch_ns`: shift the instant by the zone offset, then
/// decompose into ISO fields.
pub fn getISODateTimeFor(tz: TimeZone, epoch_ns: i128) PlainDateTimeRecord {
    const local = epoch_ns + @as(i128, getOffsetNanosecondsFor(tz, epoch_ns));
    return isoDateTimeFromEpochNs(local);
}

/// §6.5.x GetEpochNanosecondsFor for a constant-offset zone — interpret
/// `dt` as wall-clock in `tz` and return the epoch ns, or null when the
/// result leaves the representable Instant range. Offset zones have no
/// DST gap/overlap, so exactly one instant maps to any wall-clock time
/// and the `disambiguation` option never changes the answer.
pub fn getEpochNanosecondsFor(tz: TimeZone, dt: PlainDateTimeRecord) ?i128 {
    const wall_ns = isoDateTimeToEpochNs(dt);
    const epoch = wall_ns - @as(i128, getOffsetNanosecondsFor(tz, wall_ns));
    if (!isValidEpochNanoseconds(epoch)) return null;
    return epoch;
}

/// §11.x ParseTimeZoneIdentifier — UTC, offset (`±HH` / `±HH:MM` /
/// `±HHMM`), or a structural IANA identifier (`Area/Location…`).
/// Sub-minute offsets are rejected. Unknown/malformed input returns null.
pub fn parseTimeZoneIdentifier(s: []const u8) ?TimeZone {
    if (std.ascii.eqlIgnoreCase(s, "UTC")) return .utc;
    if (s.len == 0) return null;
    if (s[0] == '+' or s[0] == '-') {
        const neg = s[0] == '-';
        var i: usize = 1;
        const hour = read2(s, &i) orelse return null;
        if (hour > 23) return null;
        var minute: u32 = 0;
        if (i < s.len) {
            if (s[i] == ':') i += 1;
            minute = read2(s, &i) orelse return null;
            if (minute > 59) return null;
        }
        if (i != s.len) return null; // trailing bytes (sub-minute, garbage) → reject
        const total: i32 = @intCast(hour * 60 + minute);
        return .{ .offset_minutes = if (neg) -total else total };
    }
    // Structural IANA — only when built with `-Dintl=stub`/`full`
    // (ROADMAP: named zones are the Intl-enabled build payoff).
    if (!intl_config.temporal_intl_extras) return null;
    // Accept identifiers that look like zone names (must contain '/',
    // components are alnum/_/-/+; first segment alpha).
    return parseIanaTimeZoneIdentifier(s);
}

/// True when `s` is a plausible IANA time-zone identifier. At `-Dintl=full`
/// the name must also exist in the embedded tzdb; at `stub` only the
/// structural shape is checked (no tzdata consult).
fn parseIanaTimeZoneIdentifier(s: []const u8) ?TimeZone {
    if (s.len == 0 or s.len > max_iana_zone_bytes) return null;
    // Single-segment identifiers (EST, MST7MDT, ...) exist in the tzdb; when
    // the embedded data is present it is authoritative, so the slash is only
    // required structurally on the data-less stub tier.
    if (!intl_config.has_locale_data and std.mem.indexOfScalar(u8, s, '/') == null) return null;
    // No leading/trailing slash; no empty segments; segments are [A-Za-z0-9_+-].
    var i: usize = 0;
    var seg_start: usize = 0;
    var segs: usize = 0;
    while (i <= s.len) : (i += 1) {
        if (i == s.len or s[i] == '/') {
            const seg_len = i - seg_start;
            if (seg_len == 0) return null;
            const seg = s[seg_start..i];
            for (seg) |c| {
                const ok = (c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z') or
                    (c >= '0' and c <= '9') or c == '_' or c == '-' or c == '+' or c == '.';
                if (!ok) return null;
            }
            if (segs == 0) {
                // First segment must start with a letter (Etc, America, …).
                const c0 = seg[0];
                if (!((c0 >= 'A' and c0 <= 'Z') or (c0 >= 'a' and c0 <= 'z'))) return null;
            }
            segs += 1;
            seg_start = i + 1;
        }
    }
    if (!intl_config.has_locale_data and segs < 2) return null;
    // At `-Dintl=full`, only accept zones present in the embedded tzdb. The
    // match is case-insensitive and the stored identifier takes the tzdb's
    // canonical casing ("AMERICA/NEW_YORK" is accepted and reads back as
    // "America/New_York").
    var canonical: []const u8 = s;
    if (intl_config.has_locale_data) {
        canonical = @import("tzdata.zig").canonicalZoneName(s) orelse return null;
    }
    var named: TimeZone = .{ .named = .{} };
    @memcpy(named.named.bytes[0..canonical.len], canonical);
    named.named.len = @intCast(canonical.len);
    return named;
}

/// §11.x ParseTemporalTimeZoneString — the time-zone *argument* form, broader
/// than `parseTimeZoneIdentifier`: a bare identifier ("UTC", "+05:30"), or a
/// full ISO date-time string from which the zone is extracted. Precedence: a
/// `[...]` time-zone annotation wins; else a `Z` designator is UTC; else a
/// numeric offset is the offset zone; else (a bare date-time with no zone
/// determinant) it is rejected. The zone determinant must be minute-precise —
/// a `±HH:MM:SS[.fff]` offset is a sub-minute *precision* and invalid as a
/// time zone even when its value lands on a whole minute (`-07:00:00` throws),
/// so the candidate offset slice is re-validated through the strict
/// identifier parser rather than checked by value.
pub fn parseTimeZoneString(s: []const u8) ?TimeZone {
    // Bare identifier fast path ("UTC", "+05:30").
    if (parseTimeZoneIdentifier(s)) |tz| return tz;

    var c = Cursor{ .s = s };
    _ = parseIsoDate(&c) catch return null;
    var saw_z = false;
    var offset_slice: ?[]const u8 = null;
    if (c.eatAny("Tt ")) {
        _ = parseIsoTime(&c) catch return null;
        if (c.eatAny("Zz")) {
            saw_z = true;
        } else if (c.peek()) |ch| {
            if (ch == '+' or ch == '-') {
                const off_start = c.i;
                _ = parseUtcOffsetNs(&c) catch return null;
                offset_slice = c.s[off_start..c.i];
            }
        }
    }
    var tz_body: ?[]const u8 = null;
    _ = consumeAnnotationsImpl(&c, &tz_body) catch return null;
    if (!c.done()) return null;

    // A bracket annotation wins outright over Z / the time offset.
    if (tz_body) |body| return parseTimeZoneIdentifier(body);
    if (saw_z) return .utc;
    // The offset slice is the zone only when minute-precise — feed it back
    // through the strict identifier parser so `-07:00:00` (seconds field
    // present) is rejected the same as garbage.
    if (offset_slice) |slice| return parseTimeZoneIdentifier(slice);
    return null; // bare date-time, no zone determinant
}

/// The canonical time-zone identifier string for `tz`: "UTC", or an
/// offset identifier in the always-extended `±HH:MM` form (the form
/// `get Temporal.ZonedDateTime.prototype.timeZoneId` returns). Writes into
/// `buf` (≥ 6 bytes) and returns the populated slice.
pub fn timeZoneIdentifierString(tz: TimeZone, buf: []u8) []const u8 {
    switch (tz) {
        .utc => {
            @memcpy(buf[0..3], "UTC");
            return buf[0..3];
        },
        .offset_minutes => |m| {
            var w = Writer{ .buf = buf, .len = 0 };
            const abs: u32 = @intCast(if (m < 0) -m else m);
            w.byte(if (m < 0) '-' else '+');
            w.pad2(abs / 60);
            w.byte(':');
            w.pad2(abs % 60);
            return w.buf[0..w.len];
        },
        .named => |n| {
            const sl = n.slice();
            if (sl.len > buf.len) return buf[0..0];
            @memcpy(buf[0..sl.len], sl);
            return buf[0..sl.len];
        },
    }
}

// ── §6.5.x ZonedDateTime epoch interpretation + formatting ────────────────

/// How a parsed (or property-bag) wall-clock + offset combine into an
/// exact epoch instant. `wall` — no offset was supplied, so the zone
/// computes the instant. `exact` — a `Z` designator, so the wall time is
/// already UTC. `option` — an explicit numeric offset whose treatment is
/// governed by the `offset` resolution option.
pub const OffsetBehaviour = enum { wall, exact, option };

/// §13.x The four `offset` resolution options (default `reject`).
pub const OffsetOption = enum { prefer, use, ignore, reject };

/// §13.x The `timeZoneName` display option (default `auto`).
pub const TimeZoneNameDisplay = enum { auto, never, critical };

/// §13.x ToSecondsStringPrecisionRecord's `[[Precision]]` — how the
/// sub-minute portion of a Temporal ToString renders. Shared by every
/// serializer (Instant, PlainTime, PlainDateTime, ZonedDateTime).
pub const Precision = union(enum) {
    /// Trim trailing zeros; omit the fraction (and its `.`) entirely when
    /// the sub-second value is zero. Still always emits `:SS`.
    auto,
    /// Stop after `HH:MM` — no `:SS`, no fraction (smallestUnit "minute").
    minute,
    /// Exactly `n` ∈ 0..9 truncated fractional digits. `0` ⇒ `:SS` with no
    /// fraction.
    digits: u4,
};

/// Options bag for `zonedDateTimeToString` — what the four display knobs
/// (`calendarName`, `timeZoneName`, `offset`, precision) resolve to.
pub const ZonedToStringOptions = struct {
    calendar: CalendarDisplay = .auto,
    time_zone_name: TimeZoneNameDisplay = .auto,
    show_offset: bool = true,
    precision: Precision = .auto,
};

/// §6.5.x InterpretISODateTimeOffset — fold a wall-clock ISO date-time and
/// an optional offset into epoch nanoseconds for `timeZone`. Returns
/// `error.OffsetMismatch` when `behaviour` is `option`, the option is
/// `reject`, and the supplied offset disagrees with the zone; returns
/// `error.Invalid` when the resulting instant falls outside the
/// representable range. For a fixed-offset zone there is exactly one
/// candidate instant (no DST gaps/overlaps), so `disambiguation` never
/// applies.
pub fn interpretISODateTimeOffset(
    dt: PlainDateTimeRecord,
    behaviour: OffsetBehaviour,
    offset_ns: i128,
    tz: TimeZone,
    offset_option: OffsetOption,
) error{ Invalid, OffsetMismatch }!i128 {
    // Wall clock, or the supplied offset is explicitly ignored: the zone
    // alone places the instant.
    if (behaviour == .wall or offset_option == .ignore) {
        return getEpochNanosecondsFor(tz, dt) orelse error.Invalid;
    }
    // Exact UTC (`Z`), or the supplied offset is taken verbatim (`use`).
    if (behaviour == .exact or offset_option == .use) {
        const e = isoDateTimeToEpochNs(dt) - offset_ns;
        if (!isValidEpochNanoseconds(e)) return error.Invalid;
        return e;
    }
    // behaviour == option, offset_option is prefer or reject.
    // §6.5.x CheckISODaysRange on the *wall* date: symmetric |days| ≤ 1e8,
    // tighter than the noon-based PlainDate range — it rejects the boundary
    // days (e.g. -271821-04-19) a bare PlainDate alone still allows, since a
    // zoned wall clock must round-trip through an in-range instant.
    const wall_days = daysFromCivil(dt.iso_year, dt.iso_month, dt.iso_day);
    if (wall_days > 100_000_000 or wall_days < -100_000_000) return error.Invalid;
    const candidate = getEpochNanosecondsFor(tz, dt) orelse return error.Invalid;
    const cand_off: i128 = getOffsetNanosecondsFor(tz, candidate);
    if (cand_off == offset_ns) return candidate;
    if (offset_option == .reject) return error.OffsetMismatch;
    return candidate; // prefer — fall back to the zone's own offset
}

/// §6.5.x AddZonedDateTime — add a calendar + time duration to an exact
/// instant in `tz`. The date component (years / months / weeks / days)
/// is applied to the wall-clock date and re-anchored to an instant; the
/// time component is then added in exact time, where it can span a wider
/// range than any single PlainDateTime. For a fixed-offset zone the
/// offset is constant, so there are no DST gaps / overlaps to
/// disambiguate. Returns null when an intermediate date-time or the final
/// instant leaves the representable range.
pub fn addZonedDateTime(epoch_ns: i128, tz: TimeZone, dur: DurationRecord, reject: bool) ?i128 {
    const time_ns = timeDurationNanoseconds(dur);
    // Pure time shift adds directly in exact time.
    if (dur.years == 0 and dur.months == 0 and dur.weeks == 0 and dur.days == 0) {
        return addInstant(epoch_ns, time_ns);
    }
    const wall = getISODateTimeFor(tz, epoch_ns);
    const new_date = addISODate(
        wall.date(),
        @intFromFloat(dur.years),
        @intFromFloat(dur.months),
        @intFromFloat(dur.weeks),
        @intFromFloat(dur.days),
        reject,
    ) orelse return null;
    const intermediate = PlainDateTimeRecord.combine(new_date, wall.time());
    if (!isoDateTimeWithinLimits(intermediate)) return null;
    const intermediate_epoch = getEpochNanosecondsFor(tz, intermediate) orelse return null;
    return addInstant(intermediate_epoch, time_ns);
}

/// §6.5.x RoundZonedDateTime — round an exact instant to a multiple of
/// `increment` of `unit` (day..nanosecond) under `mode`, measured in the
/// zone's wall clock. For a fixed-offset zone every day is exactly 24 h,
/// so rounding the wall-clock date-time and re-anchoring it is exact.
/// Returns null when the rounded instant leaves the representable range.
pub fn roundZonedDateTime(epoch_ns: i128, tz: TimeZone, unit: LargestUnit, increment: i128, mode: RoundingMode) ?i128 {
    const wall = getISODateTimeFor(tz, epoch_ns);
    if (unit == .day) {
        // Day rounding measures progress through the *actual* span between
        // the start of this day and the start of the next (GetStartOfDay for
        // both boundaries). For a fixed-offset zone the span is 24 h, but
        // either boundary can leave the valid epoch range — the upper bound
        // in particular, near the +8.64×10^21 ns limit. The day increment is
        // capped at 1, so the rounding increment is the whole day length.
        const start_ns = getEpochNanosecondsFor(tz, PlainDateTimeRecord{
            .iso_year = wall.iso_year,
            .iso_month = wall.iso_month,
            .iso_day = wall.iso_day,
        }) orelse return null;
        const tomorrow = addISODate(wall.date(), 0, 0, 0, 1, false) orelse return null;
        const end_ns = getEpochNanosecondsFor(tz, PlainDateTimeRecord.combine(tomorrow, .{})) orelse return null;
        const day_len = end_ns - start_ns;
        const rounded = roundToIncrement(epoch_ns - start_ns, day_len * increment, mode);
        const result = start_ns + rounded;
        if (!isValidEpochNanoseconds(result)) return null;
        return result;
    }
    const rounded = roundISODateTime(wall, unit, increment, mode) orelse return null;
    return getEpochNanosecondsFor(tz, rounded);
}

/// §6.5.x — the instant of the first wall-clock moment (midnight,
/// 00:00:00.000000000) of `epoch_ns`'s calendar day in `tz`. For a
/// fixed-offset zone midnight always exists and is unique.
pub fn zonedStartOfDay(epoch_ns: i128, tz: TimeZone) ?i128 {
    const wall = getISODateTimeFor(tz, epoch_ns);
    const midnight = PlainDateTimeRecord{
        .iso_year = wall.iso_year,
        .iso_month = wall.iso_month,
        .iso_day = wall.iso_day,
    };
    return getEpochNanosecondsFor(tz, midnight);
}

/// §6.3.4 get hoursInDay — the number of hours spanned by `epoch_ns`'s
/// calendar day in `tz`: the gap between the start of that day and the
/// start of the next one (GetStartOfDay of `today`, and of the balanced
/// `today + 1 day`). A fixed-offset day is always exactly 24 h, but either
/// boundary can leave the representable Instant range near the ±8.64×10^21
/// ns limits — when `today + 1 day` overflows the ISO date range, or when
/// either midnight maps outside the valid epoch. Returns the ns difference,
/// or null in that case so the caller throws RangeError.
pub fn zonedHoursInDay(epoch_ns: i128, tz: TimeZone) ?i128 {
    const wall = getISODateTimeFor(tz, epoch_ns);
    const today_ns = getEpochNanosecondsFor(tz, PlainDateTimeRecord{
        .iso_year = wall.iso_year,
        .iso_month = wall.iso_month,
        .iso_day = wall.iso_day,
    }) orelse return null;
    const tomorrow = addISODate(wall.date(), 0, 0, 0, 1, false) orelse return null;
    const tomorrow_ns = getEpochNanosecondsFor(tz, PlainDateTimeRecord.combine(tomorrow, .{})) orelse return null;
    return tomorrow_ns - today_ns;
}

/// §6.5.x TemporalZonedDateTimeToString — `<localISO><±HH:MM>[<tzid>]`
/// plus an optional `[u-ca=…]` calendar annotation. The local wall-clock
/// fields come from `GetISODateTimeFor`; the offset is the zone's offset
/// at the instant (`+00:00` for the UTC zone, distinct from its `[UTC]`
/// annotation). `buf` must hold ≥ 80 bytes.
pub fn zonedDateTimeToString(rec: ZonedDateTimeRecord, buf: []u8, opts: ZonedToStringOptions) []const u8 {
    const local = getISODateTimeFor(rec.time_zone, rec.epoch_ns);
    var w = Writer{ .buf = buf, .len = 0 };
    writeIsoYear(&w, local.iso_year);
    w.byte('-');
    w.pad2(local.iso_month);
    w.byte('-');
    w.pad2(local.iso_day);
    w.byte('T');
    const sub_ns: u32 = local.millisecond * 1_000_000 + local.microsecond * 1_000 + local.nanosecond;
    writeTimeFields(&w, local.hour, local.minute, local.second, sub_ns, opts.precision);
    if (opts.show_offset) {
        const off_min: i32 = @intCast(@divTrunc(getOffsetNanosecondsFor(rec.time_zone, rec.epoch_ns), 60_000_000_000));
        writeOffsetMinutes(&w, off_min);
    }
    switch (opts.time_zone_name) {
        .never => {},
        .auto, .critical => {
            var tzbuf: [16]u8 = undefined;
            const tzid = timeZoneIdentifierString(rec.time_zone, &tzbuf);
            w.byte('[');
            if (opts.time_zone_name == .critical) w.byte('!');
            w.bytes(tzid);
            w.byte(']');
        },
    }
    writeCalendarAnnotation(&w, rec.calendar, opts.calendar);
    return w.buf[0..w.len];
}

/// Write a `±HH:MM` numeric UTC offset (whole-minute precision).
fn writeOffsetMinutes(w: *Writer, off_min: i32) void {
    w.byte(if (off_min < 0) '-' else '+');
    const abs: u32 = @intCast(if (off_min < 0) -off_min else off_min);
    w.pad2(abs / 60);
    w.byte(':');
    w.pad2(abs % 60);
}

/// Write `HH:MM`, then — unless `precision` is `.minute` — `:SS` and the
/// sub-second fraction `precision` dictates. Shared by every Temporal
/// serializer's time portion (FormatTimeString, §13.x).
fn writeTimeFields(w: *Writer, hour: u32, minute: u32, second: u32, sub_ns: u32, precision: Precision) void {
    w.pad2(hour);
    w.byte(':');
    w.pad2(minute);
    if (precision == .minute) return;
    w.byte(':');
    w.pad2(second);
    switch (precision) {
        .minute => unreachable,
        .auto => {
            if (sub_ns == 0) return;
            w.byte('.');
            w.fraction9(sub_ns);
        },
        .digits => |d| {
            if (d == 0) return;
            w.byte('.');
            var scale: u32 = 100_000_000; // 1e8 — most-significant of nine
            var rem = sub_ns;
            var i: u4 = 0;
            while (i < d) : (i += 1) {
                const digit = rem / scale;
                w.byte('0' + @as(u8, @intCast(digit)));
                rem -= digit * scale;
                scale /= 10;
            }
        },
    }
}

// ── §8.x TemporalInstantToString ──────────────────────────────────────────

/// Format an epoch-ns value to an ISO-8601 string. With `time_zone` null
/// the output is the UTC wall clock plus a trailing `Z` (the form
/// `Temporal.Instant.prototype.toString` / `toJSON` default to); with a
/// time zone the output is that zone's wall clock plus its numeric
/// `±HH:MM` offset (no `Z`, no `[...]` annotation — an Instant carries
/// none). `precision` controls the sub-second portion; years outside
/// 0000..9999 use the expanded `±YYYYYY` form. `buf` must hold ≥ 48 bytes.
pub fn instantToString(epoch_ns: i128, buf: []u8, precision: Precision, time_zone: ?TimeZone) []const u8 {
    const tz = time_zone orelse TimeZone.utc;
    const local = getISODateTimeFor(tz, epoch_ns);
    var w = Writer{ .buf = buf, .len = 0 };
    writeIsoYear(&w, local.iso_year);
    w.byte('-');
    w.pad2(local.iso_month);
    w.byte('-');
    w.pad2(local.iso_day);
    w.byte('T');
    const sub_ns: u32 = local.millisecond * 1_000_000 + local.microsecond * 1_000 + local.nanosecond;
    writeTimeFields(&w, local.hour, local.minute, local.second, sub_ns, precision);
    if (time_zone == null) {
        w.byte('Z');
    } else {
        const off_min: i32 = @intCast(@divTrunc(getOffsetNanosecondsFor(tz, epoch_ns), 60_000_000_000));
        writeOffsetMinutes(&w, off_min);
    }
    return w.buf[0..w.len];
}

fn writeIsoYear(w: *Writer, year: i64) void {
    if (year >= 0 and year <= 9999) {
        var tmp: [4]u8 = undefined;
        var y: u32 = @intCast(year);
        var i: usize = 4;
        while (i > 0) {
            i -= 1;
            tmp[i] = '0' + @as(u8, @intCast(y % 10));
            y /= 10;
        }
        w.bytes(&tmp);
        return;
    }
    w.byte(if (year < 0) '-' else '+');
    var y: u64 = @intCast(if (year < 0) -year else year);
    var tmp: [6]u8 = undefined;
    var i: usize = 6;
    while (i > 0) {
        i -= 1;
        tmp[i] = '0' + @as(u8, @intCast(y % 10));
        y /= 10;
    }
    w.bytes(&tmp);
}

// ── §8.x ParseTemporalInstantString ───────────────────────────────────────

/// Parse an ISO-8601 / RFC 9557 date-time that carries BOTH a time and
/// a UTC offset (or `Z`), then fold the offset in to yield the epoch
/// nanoseconds. Returns `error.Invalid` (caller throws RangeError) on
/// any malformed / unsupported form, or when the resulting instant is
/// out of range.
///
/// Required shape: a calendar date (`YYYY-MM-DD`, basic `YYYYMMDD`, or
/// expanded `±YYYYYY-MM-DD`), a `T`/`t`/space separator, a time
/// (`HH[:MM[:SS[.fraction]]]` or the compact colon-free forms), and a
/// trailing `Z`/`z` or numeric offset. Optional `[...]` annotations
/// (a time-zone identifier, then `key=value` pairs) follow and are
/// validated then discarded. A date with no time, or a date-time with
/// no offset, is rejected — an Instant needs an exact point in time.
pub fn parseInstantString(input: []const u8) error{Invalid}!i128 {
    var c = Cursor{ .s = input };

    const date = try parseIsoDate(&c);

    // Date-time separator (required — an Instant must have a time).
    if (!c.eatAny("Tt ")) return error.Invalid;

    const time = try parseIsoTime(&c);

    // Offset (required) — `Z`/`z` or a signed numeric offset.
    var offset_ns: i128 = 0;
    if (c.eatAny("Zz")) {
        offset_ns = 0;
    } else if (c.peek()) |ch| {
        if (ch == '+' or ch == '-') {
            offset_ns = try parseUtcOffsetNs(&c);
        } else return error.Invalid;
    } else return error.Invalid;

    // Optional annotations, then the string must end. Instant is
    // calendar-free, so the `u-ca` value (if any) is discarded — an
    // unknown calendar like `[u-ca=discord]` is still a valid Instant
    // string per the grammar.
    _ = try consumeAnnotations(&c);
    if (!c.done()) return error.Invalid;

    // Fold the offset in: epoch = wall-clock-as-UTC − offset.
    const epoch_days = daysFromCivil(date.year, date.month, date.day);
    const wall_sec: i128 = @as(i128, epoch_days) * 86400 +
        @as(i128, time.hour) * 3600 + @as(i128, time.minute) * 60 + @as(i128, time.second);
    const wall_ns: i128 = wall_sec * 1_000_000_000 + @as(i128, time.sub_ns);
    const epoch_ns = wall_ns - offset_ns;
    if (!isValidEpochNanoseconds(epoch_ns)) return error.Invalid;
    return epoch_ns;
}

const Cursor = struct {
    s: []const u8,
    i: usize = 0,

    fn done(self: *const Cursor) bool {
        return self.i >= self.s.len;
    }
    fn peek(self: *const Cursor) ?u8 {
        return if (self.i < self.s.len) self.s[self.i] else null;
    }
    fn eat(self: *Cursor, ch: u8) bool {
        if (self.i < self.s.len and self.s[self.i] == ch) {
            self.i += 1;
            return true;
        }
        return false;
    }
    fn eatAny(self: *Cursor, set: []const u8) bool {
        const ch = self.peek() orelse return false;
        for (set) |x| {
            if (ch == x) {
                self.i += 1;
                return true;
            }
        }
        return false;
    }
    fn isDigit(self: *const Cursor) bool {
        const ch = self.peek() orelse return false;
        return ch >= '0' and ch <= '9';
    }
    /// Read EXACTLY n decimal digits as a u64; null (no advance) if
    /// fewer than n digits are available at the cursor.
    fn fixedDigits(self: *Cursor, n: usize) ?u64 {
        if (self.i + n > self.s.len) return null;
        var v: u64 = 0;
        var k: usize = 0;
        while (k < n) : (k += 1) {
            const ch = self.s[self.i + k];
            if (ch < '0' or ch > '9') return null;
            v = v * 10 + (ch - '0');
        }
        self.i += n;
        return v;
    }
};

const ParsedDate = struct { year: i64, month: u32, day: u32 };
const ParsedTime = struct { hour: u32, minute: u32, second: u32, sub_ns: u32 };

fn parseIsoDate(c: *Cursor) error{Invalid}!ParsedDate {
    var year: i64 = undefined;
    var expanded = false;
    const lead = c.peek() orelse return error.Invalid;
    if (lead == '+' or lead == '-') {
        // Expanded year: ASCII sign + exactly six digits. A `-000000`
        // (negative zero) expanded year is forbidden.
        const neg = lead == '-';
        c.i += 1;
        const y = c.fixedDigits(6) orelse return error.Invalid;
        if (neg and y == 0) return error.Invalid;
        year = if (neg) -@as(i64, @intCast(y)) else @as(i64, @intCast(y));
        expanded = true;
    } else {
        const y = c.fixedDigits(4) orelse return error.Invalid;
        year = @intCast(y);
    }

    // Extended (`-` separators) vs basic (none). An expanded `±YYYYYY`
    // year may be followed by either form (`+001976-11-18` and the
    // dash-free `+0019761118` are both valid).
    const extended = c.eat('-');
    const month_u = c.fixedDigits(2) orelse return error.Invalid;
    if (extended and !c.eat('-')) return error.Invalid;
    const day_u = c.fixedDigits(2) orelse return error.Invalid;

    const month: u32 = @intCast(month_u);
    const day: u32 = @intCast(day_u);
    if (month < 1 or month > 12) return error.Invalid;
    if (day < 1 or day > daysInIsoMonth(year, month)) return error.Invalid;
    return .{ .year = year, .month = month, .day = day };
}

fn parseIsoTime(c: *Cursor) error{Invalid}!ParsedTime {
    const hour_u = c.fixedDigits(2) orelse return error.Invalid;
    var minute: u32 = 0;
    var second: u32 = 0;
    var sub_ns: u32 = 0;

    if (c.eat(':')) {
        minute = @intCast(c.fixedDigits(2) orelse return error.Invalid);
        if (c.eat(':')) {
            second = @intCast(c.fixedDigits(2) orelse return error.Invalid);
            sub_ns = try parseFractionNs(c);
        }
    } else if (c.isDigit()) {
        minute = @intCast(c.fixedDigits(2) orelse return error.Invalid);
        if (c.isDigit()) {
            second = @intCast(c.fixedDigits(2) orelse return error.Invalid);
            sub_ns = try parseFractionNs(c);
        }
    }

    const hour: u32 = @intCast(hour_u);
    if (hour > 23 or minute > 59 or second > 60) return error.Invalid;
    if (second == 60) second = 59; // leap second → clamp (Temporal has none)
    return .{ .hour = hour, .minute = minute, .second = second, .sub_ns = sub_ns };
}

/// Parse a numeric UTC offset at the cursor (`+`/`-` already peeked):
/// `±HH`, `±HH:MM`, `±HH:MM:SS`, `±HH:MM:SS(.|,)fraction`, or the
/// compact colon-free forms. Returns the offset in signed nanoseconds.
fn parseUtcOffsetNs(c: *Cursor) error{Invalid}!i128 {
    const sign = c.peek() orelse return error.Invalid;
    if (sign != '+' and sign != '-') return error.Invalid;
    c.i += 1;
    const neg = sign == '-';

    const hour: u32 = @intCast(c.fixedDigits(2) orelse return error.Invalid);
    var minute: u32 = 0;
    var second: u32 = 0;
    var sub_ns: u32 = 0;

    if (c.eat(':')) {
        minute = @intCast(c.fixedDigits(2) orelse return error.Invalid);
        if (c.eat(':')) {
            second = @intCast(c.fixedDigits(2) orelse return error.Invalid);
            sub_ns = try parseFractionNs(c);
        }
    } else if (c.isDigit()) {
        minute = @intCast(c.fixedDigits(2) orelse return error.Invalid);
        if (c.isDigit()) {
            second = @intCast(c.fixedDigits(2) orelse return error.Invalid);
            sub_ns = try parseFractionNs(c);
        }
    }

    if (hour > 23 or minute > 59 or second > 59) return error.Invalid;
    const total: i128 = (@as(i128, hour) * 3600 + @as(i128, minute) * 60 + @as(i128, second)) *
        1_000_000_000 + @as(i128, sub_ns);
    return if (neg) -total else total;
}

/// Read an optional `.`/`,` fraction (1..9 digits) at the cursor,
/// returning whole nanoseconds (0 when no fraction follows).
fn parseFractionNs(c: *Cursor) error{Invalid}!u32 {
    const ch = c.peek() orelse return 0;
    if (ch != '.' and ch != ',') return 0;
    c.i += 1;
    const start = c.i;
    while (c.isDigit()) c.i += 1;
    const len = c.i - start;
    if (len == 0 or len > 9) return error.Invalid;
    return fractionToNanos(c.s[start..c.i]);
}

/// Validate the trailing `[...]` annotation blocks per the RFC 9557
/// grammar: an optional leading time-zone annotation (an identifier, no
/// `=`), then zero or more `key=value` annotations. At most one
/// time-zone and at most one `u-ca` calendar annotation; a `[!key=…]`
/// critical flag on an unknown key is rejected. Leaves the cursor at the
/// first non-`[` byte (the caller requires end-of-input). Returns the
/// first `u-ca` calendar value (a slice into the input) or null when no
/// calendar annotation is present — the calendar-aware callers (e.g.
/// PlainDate) validate it against the supported calendars, while
/// calendar-free callers (e.g. Instant) discard it.
fn consumeAnnotations(c: *Cursor) error{Invalid}!?[]const u8 {
    var tz_unused: ?[]const u8 = null;
    return consumeAnnotationsImpl(c, &tz_unused);
}

/// As `consumeAnnotations`, but also writes the time-zone annotation body
/// (an identifier or numeric offset, sans brackets) to `tz_out` when one
/// is present — the ZonedDateTime parser needs to keep it.
fn consumeAnnotationsImpl(c: *Cursor, tz_out: *?[]const u8) error{Invalid}!?[]const u8 {
    var saw_tz = false;
    var calendars: usize = 0;
    var critical_calendar = false;
    var first = true;
    var calendar: ?[]const u8 = null;
    while (c.peek()) |ch| {
        if (ch != '[') break;
        c.i += 1; // consume '['
        const critical = c.eat('!');
        const start = c.i;
        while (c.peek()) |x| {
            if (x == ']') break;
            c.i += 1;
        }
        if (c.peek() != ']') return error.Invalid; // unterminated
        const body = c.s[start..c.i];
        c.i += 1; // consume ']'
        if (body.len == 0) return error.Invalid;

        if (std.mem.indexOfScalar(u8, body, '=')) |eq| {
            // key=value annotation. The key must match the lowercase
            // AnnotationKey grammar; a non-empty value is required.
            const key = body[0..eq];
            const value = body[eq + 1 ..];
            if (!isValidAnnotationKey(key) or value.len == 0) return error.Invalid;
            if (std.mem.eql(u8, key, "u-ca")) {
                calendars += 1;
                if (calendars == 1) calendar = value;
                if (critical) critical_calendar = true;
                // Two or more calendar annotations are only syntactical
                // if none carries the critical flag.
                if (calendars > 1 and critical_calendar) return error.Invalid;
            } else if (critical) {
                return error.Invalid; // unknown critical annotation
            }
        } else {
            // Time-zone annotation (an identifier or a numeric offset):
            // at most one, and it must precede any key=value
            // annotations. A numeric offset must not carry sub-minute
            // precision.
            if (saw_tz or !first) return error.Invalid;
            if (!isValidTimeZoneAnnotation(body)) return error.Invalid;
            saw_tz = true;
            tz_out.* = body;
        }
        first = false;
    }
    return calendar;
}

/// AnnotationKey :: AKeyLeadingChar (AKeyChar)*, where AKeyLeadingChar
/// is a lowercase letter or `_`, and AKeyChar adds digits and `-`.
/// Capitalised keys (`U-CA`, `u-CA`) are not valid; `_foo-bar0` is.
fn isValidAnnotationKey(key: []const u8) bool {
    if (key.len == 0) return false;
    if (!((key[0] >= 'a' and key[0] <= 'z') or key[0] == '_')) return false;
    for (key[1..]) |ch| {
        const ok = (ch >= 'a' and ch <= 'z') or ch == '_' or
            (ch >= '0' and ch <= '9') or ch == '-';
        if (!ok) return false;
    }
    return true;
}

/// A time-zone annotation is either an IANA-style identifier or a
/// numeric UTC offset. A numeric offset (`±HH`, `±HH:MM`, `±HHMM`) must
/// NOT carry sub-minute precision — `[-07:00:01]` is rejected. Other
/// identifier shapes are accepted and discarded (Instant is
/// time-zone-free).
fn isValidTimeZoneAnnotation(body: []const u8) bool {
    if (body.len == 0) return false;
    if (body[0] != '+' and body[0] != '-') return true; // IANA-style name
    var k: usize = 1;
    if (k + 2 > body.len or !isAsciiDigit(body[k]) or !isAsciiDigit(body[k + 1])) return false;
    k += 2;
    if (k == body.len) return true; // ±HH
    if (body[k] == ':') k += 1;
    if (k + 2 > body.len or !isAsciiDigit(body[k]) or !isAsciiDigit(body[k + 1])) return false;
    k += 2;
    return k == body.len; // ±HH:MM / ±HHMM — seconds are not allowed
}

fn isAsciiDigit(ch: u8) bool {
    return ch >= '0' and ch <= '9';
}

// ── §13 Rounding primitives ───────────────────────────────────────────────

/// §13.x The nine ECMAScript rounding modes.
pub const RoundingMode = enum {
    ceil,
    floor,
    expand,
    trunc,
    half_ceil,
    half_floor,
    half_expand,
    half_trunc,
    half_even,
};

/// §13.x RoundNumberToIncrement — round `value` to the nearest multiple
/// of `increment` (which must be > 0) per `mode`, in exact i128
/// arithmetic. Multiples are measured from zero, so rounding an
/// epoch-nanosecond value lands on boundaries aligned with the Unix
/// epoch. Sign-aware: `trunc` rounds toward zero, `expand` away from it,
/// and the half-* ties resolve by the named direction relative to zero.
pub fn roundToIncrement(value: i128, increment: i128, mode: RoundingMode) i128 {
    return roundToIncrementImpl(value, increment, mode, false);
}

/// §13.x RoundNumberToIncrementAsIfPositive — like `roundToIncrement`
/// but evaluates the directed / half-tie modes as though `value` were
/// non-negative, so `floor`/`trunc` always round toward −∞ and
/// `ceil`/`expand` toward +∞. `Temporal.Instant.prototype.round` uses
/// this: rounding is anchored to the timeline (the epoch), not mirrored
/// about zero.
pub fn roundToIncrementAsIfPositive(value: i128, increment: i128, mode: RoundingMode) i128 {
    return roundToIncrementImpl(value, increment, mode, true);
}

/// `@divFloor` for the lower multiple makes `lower ≤ value` hold for
/// negative values too, so the sign handling is uniform.
fn roundToIncrementImpl(value: i128, increment: i128, mode: RoundingMode, as_if_positive: bool) i128 {
    const quotient = @divFloor(value, increment);
    const lower = quotient * increment; // greatest multiple ≤ value
    if (lower == value) return value; // already an exact multiple
    const upper = lower + increment;
    const remainder = value - lower; // in (0, increment)
    const twice = remainder * 2;
    const positive = as_if_positive or value > 0;
    const negative = !as_if_positive and value < 0;
    const pick_upper = switch (mode) {
        .ceil => true,
        .floor => false,
        .trunc => negative, // toward zero
        .expand => positive, // away from zero
        .half_ceil => twice >= increment,
        .half_floor => twice > increment,
        .half_expand => if (positive) twice >= increment else twice > increment,
        .half_trunc => if (positive) twice > increment else twice >= increment,
        .half_even => if (twice != increment) twice > increment else @mod(quotient, 2) != 0,
    };
    return if (pick_upper) upper else lower;
}

/// Nanoseconds in one fixed-length time unit (day and below). Calendar
/// units have no fixed length and never reach the time-only balancing
/// path.
pub fn unitNanoseconds(unit: LargestUnit) i128 {
    return switch (unit) {
        .day => 86_400_000_000_000,
        .hour => 3_600_000_000_000,
        .minute => 60_000_000_000,
        .second => 1_000_000_000,
        .millisecond => 1_000_000,
        .microsecond => 1_000,
        .nanosecond => 1,
        .year, .month, .week => unreachable,
    };
}

/// Correctly-rounded round-to-nearest-even division of two i128 values to a
/// double — the exact rational `num / den` rounded once to f64, matching the
/// spec's `TimeDuration.fdiv` (and `RoundNumberToIncrement`'s fractional
/// totals). Converting each operand to f64 *before* dividing rounds twice and
/// drifts by 1–2 ULP once a quotient exceeds 2^53; an f128 intermediate avoids
/// that. Every in-range Temporal total stays well under f128's 113-bit exact
/// integer range (the largest day-time span is ≈2^100 ns and calendar-unit
/// counts are ≈2^20), so the i128→f128 widening is exact and only the final
/// f128→f64 narrowing rounds.
pub fn divRoundToF64(num: i128, den: i128) f64 {
    const q: f128 = @as(f128, @floatFromInt(num)) / @as(f128, @floatFromInt(den));
    return @floatCast(q);
}

fn timeUnitIncluded(unit: LargestUnit, largest: LargestUnit) bool {
    // `unit` participates when its magnitude is no larger than
    // `largest` — i.e. its enum index is at or past `largest`'s.
    return @intFromEnum(unit) >= @intFromEnum(largest);
}

fn takeTimeUnit(rem: *i128, scale: i128) f64 {
    const q = @divTrunc(rem.*, scale);
    rem.* = @rem(rem.*, scale);
    return @floatFromInt(q);
}

/// §7.5.x BalanceTimeDuration — distribute a signed nanosecond total
/// into a Duration's time fields, with the highest field capped at
/// `largest` (one of day..nanosecond). Every field takes the sign of
/// `total_ns`. Fields are exact for `largest` ≥ second; for a smaller
/// `largest` a very large field rounds to the nearest f64, which is the
/// Number the spec stores.
pub fn balanceTimeDuration(total_ns: i128, largest: LargestUnit) DurationRecord {
    var rem = total_ns;
    var d = DurationRecord{};
    if (timeUnitIncluded(.day, largest)) d.days = takeTimeUnit(&rem, 86_400_000_000_000);
    if (timeUnitIncluded(.hour, largest)) d.hours = takeTimeUnit(&rem, 3_600_000_000_000);
    if (timeUnitIncluded(.minute, largest)) d.minutes = takeTimeUnit(&rem, 60_000_000_000);
    if (timeUnitIncluded(.second, largest)) d.seconds = takeTimeUnit(&rem, 1_000_000_000);
    if (timeUnitIncluded(.millisecond, largest)) d.milliseconds = takeTimeUnit(&rem, 1_000_000);
    if (timeUnitIncluded(.microsecond, largest)) d.microseconds = takeTimeUnit(&rem, 1_000);
    d.nanoseconds = @floatFromInt(rem);
    return d;
}

/// §13.x ValidateTemporalRoundingIncrement — `increment` must divide
/// `dividend` evenly; when `inclusive` is false it must also be strictly
/// less than `dividend`. (`increment` ≥ 1 is enforced when the option is
/// read.)
pub fn validateRoundingIncrement(increment: i128, dividend: i128, inclusive: bool) bool {
    if (@mod(dividend, increment) != 0) return false;
    if (!inclusive and increment == dividend) return false;
    return true;
}

/// §13.x MaximumTemporalDurationRoundingIncrement — the exclusive upper
/// bound a `roundingIncrement` must stay under for a given smallest unit.
/// Calendar units and `day` have no maximum (null — any positive integer is
/// allowed); each time unit's maximum is the count that fills one of the
/// next-coarser unit (24 hours, 60 minutes/seconds, 1000 sub-second steps).
pub fn maximumTemporalDurationRoundingIncrement(unit: LargestUnit) ?i128 {
    return switch (unit) {
        .year, .month, .week, .day => null,
        .hour => 24,
        .minute, .second => 60,
        .millisecond, .microsecond, .nanosecond => 1000,
    };
}

/// Map a Temporal unit name (singular or plural) to its `LargestUnit`;
/// null for an unrecognised name.
pub fn parseTemporalUnit(s: []const u8) ?LargestUnit {
    const entries = .{
        .{ "year", LargestUnit.year },               .{ "years", LargestUnit.year },
        .{ "month", LargestUnit.month },             .{ "months", LargestUnit.month },
        .{ "week", LargestUnit.week },               .{ "weeks", LargestUnit.week },
        .{ "day", LargestUnit.day },                 .{ "days", LargestUnit.day },
        .{ "hour", LargestUnit.hour },               .{ "hours", LargestUnit.hour },
        .{ "minute", LargestUnit.minute },           .{ "minutes", LargestUnit.minute },
        .{ "second", LargestUnit.second },           .{ "seconds", LargestUnit.second },
        .{ "millisecond", LargestUnit.millisecond }, .{ "milliseconds", LargestUnit.millisecond },
        .{ "microsecond", LargestUnit.microsecond }, .{ "microseconds", LargestUnit.microsecond },
        .{ "nanosecond", LargestUnit.nanosecond },   .{ "nanoseconds", LargestUnit.nanosecond },
    };
    inline for (entries) |e| {
        if (std.mem.eql(u8, s, e[0])) return e[1];
    }
    return null;
}

/// Map a `roundingMode` option string to its `RoundingMode`; null for an
/// unrecognised name.
pub fn parseRoundingMode(s: []const u8) ?RoundingMode {
    const entries = .{
        .{ "ceil", RoundingMode.ceil },              .{ "floor", RoundingMode.floor },
        .{ "expand", RoundingMode.expand },          .{ "trunc", RoundingMode.trunc },
        .{ "halfCeil", RoundingMode.half_ceil },     .{ "halfFloor", RoundingMode.half_floor },
        .{ "halfExpand", RoundingMode.half_expand }, .{ "halfTrunc", RoundingMode.half_trunc },
        .{ "halfEven", RoundingMode.half_even },
    };
    inline for (entries) |e| {
        if (std.mem.eql(u8, s, e[0])) return e[1];
    }
    return null;
}

/// §4.5.x Total nanoseconds of a PlainTime within its day (0..86400×10^9).
pub fn timeRecordToNanoseconds(t: PlainTimeRecord) i128 {
    return @as(i128, t.hour) * 3_600_000_000_000 +
        @as(i128, t.minute) * 60_000_000_000 +
        @as(i128, t.second) * 1_000_000_000 +
        @as(i128, t.millisecond) * 1_000_000 +
        @as(i128, t.microsecond) * 1_000 +
        @as(i128, t.nanosecond);
}

/// §4.5.x Build a PlainTime from a within-day nanosecond count
/// (0..86399999999999). The caller wraps any day overflow first.
pub fn nanosecondsToTimeRecord(ns_in_day: i128) PlainTimeRecord {
    var rem = ns_in_day;
    const hour: u32 = @intCast(@divTrunc(rem, 3_600_000_000_000));
    rem = @mod(rem, 3_600_000_000_000);
    const minute: u32 = @intCast(@divTrunc(rem, 60_000_000_000));
    rem = @mod(rem, 60_000_000_000);
    const second: u32 = @intCast(@divTrunc(rem, 1_000_000_000));
    rem = @mod(rem, 1_000_000_000);
    const millisecond: u32 = @intCast(@divTrunc(rem, 1_000_000));
    rem = @mod(rem, 1_000_000);
    const microsecond: u32 = @intCast(@divTrunc(rem, 1_000));
    const nanosecond: u32 = @intCast(@mod(rem, 1_000));
    return .{
        .hour = hour,
        .minute = minute,
        .second = second,
        .millisecond = millisecond,
        .microsecond = microsecond,
        .nanosecond = nanosecond,
    };
}

/// Whether a duration carries calendar units (years/months/weeks),
/// which need a relativeTo reference to interpret.
pub fn hasCalendarUnits(d: DurationRecord) bool {
    return d.years != 0 or d.months != 0 or d.weeks != 0;
}

/// Total nanoseconds of a calendar-unit-free duration, each day a fixed
/// 24 h. Callers must verify `hasCalendarUnits(d)` is false first.
pub fn dayTimeDurationNanoseconds(d: DurationRecord) i128 {
    return f64ToI128(d.days) * 86_400_000_000_000 + timeDurationNanoseconds(d);
}

// ── §3.5 PlainDate (ISO calendar) abstract operations ─────────────────────

/// Inclusive day-number bounds of a representable PlainDate
/// (-271821-04-19 .. +275760-09-13) — one ISO day beyond the
/// representable instant range on each side.
const iso_date_min_days: i64 = daysFromCivil(-271821, 4, 19);
const iso_date_max_days: i64 = daysFromCivil(275760, 9, 13);

/// §3.5.x IsValidISODate — structural validity: month 1..12, day within
/// that month (leap-aware). Independent of the representable-range limit.
pub fn isValidISODate(year: i64, month: i64, day: i64) bool {
    if (month < 1 or month > 12) return false;
    return day >= 1 and day <= daysInIsoMonth(year, @intCast(month));
}

/// §3.5.x ISODateWithinLimits — the date is representable.
pub fn isoDateWithinLimits(year: i64, month: u32, day: u32) bool {
    const d = daysFromCivil(year, month, day);
    return d >= iso_date_min_days and d <= iso_date_max_days;
}

/// §12.x ISO weekday, 1 = Monday … 7 = Sunday (1970-01-01 was Thursday).
pub fn isoDayOfWeek(year: i64, month: u32, day: u32) u8 {
    return @intCast(@mod(daysFromCivil(year, month, day) + 3, 7) + 1);
}

/// §12.x Day of the year, 1-based.
pub fn isoDayOfYear(year: i64, month: u32, day: u32) u16 {
    return @intCast(daysFromCivil(year, month, day) - daysFromCivil(year, 1, 1) + 1);
}

pub fn isoDaysInYear(year: i64) u16 {
    return if (isLeapYear(year)) 366 else 365;
}

fn isoYearStartShift(y: i64) i64 {
    return @mod(y + @divFloor(y, 4) - @divFloor(y, 100) + @divFloor(y, 400), 7);
}

/// ISO weeks in a given week-year — 53 when the year starts on a
/// Thursday (or a leap year starting Wednesday), otherwise 52.
fn isoWeeksInYear(year: i64) i64 {
    return if (isoYearStartShift(year) == 4 or isoYearStartShift(year - 1) == 3) 53 else 52;
}

pub const IsoWeek = struct { week: u16, year: i32 };

/// §12.x ISO 8601 week-of-year + week-year. Week 1 holds the year's
/// first Thursday; the first/last days of a calendar year can fall in
/// the adjacent week-year.
pub fn isoWeekOfYear(year: i64, month: u32, day: u32) IsoWeek {
    const dow: i64 = isoDayOfWeek(year, month, day);
    const doy: i64 = isoDayOfYear(year, month, day);
    var week: i64 = @divFloor(doy - dow + 10, 7);
    var wyear: i64 = year;
    if (week < 1) {
        wyear = year - 1;
        week = isoWeeksInYear(wyear);
    } else if (week > isoWeeksInYear(year)) {
        wyear = year + 1;
        week = 1;
    }
    return .{ .week = @intCast(week), .year = @intCast(wyear) };
}

/// How the ISO calendar is rendered in a date string.
pub const CalendarDisplay = enum { auto, always, never, critical };

/// §3.5.x TemporalDateToString — `YYYY-MM-DD` (expanded year when out of
/// 0000..9999), with the ISO calendar annotation appended per
/// `calendar` (auto/never omit it for the ISO calendar).
fn writeCalendarAnnotation(w: *Writer, cal: CalendarId, display: CalendarDisplay) void {
    const is_iso = cal.isIso();
    switch (display) {
        .never => {},
        .auto => if (!is_iso) {
            w.bytes("[u-ca=");
            w.bytes(cal.slice());
            w.byte(']');
        },
        .always => {
            w.bytes("[u-ca=");
            w.bytes(cal.slice());
            w.byte(']');
        },
        .critical => {
            w.bytes("[!u-ca=");
            w.bytes(cal.slice());
            w.byte(']');
        },
    }
}

pub fn isoDateToString(rec: PlainDateRecord, buf: []u8, calendar: CalendarDisplay) []const u8 {
    var w = Writer{ .buf = buf, .len = 0 };
    writeIsoYear(&w, rec.iso_year);
    w.byte('-');
    w.pad2(rec.iso_month);
    w.byte('-');
    w.pad2(rec.iso_day);
    writeCalendarAnnotation(&w, rec.calendar, calendar);
    return w.buf[0..w.len];
}

/// §3.5.x ParseTemporalDateString — parse the date portion of an ISO /
/// RFC 9557 string (`YYYY-MM-DD`, expanded `±YYYYYY`, or basic),
/// discarding (but validating) any time / offset / annotation tail.
pub fn parseTemporalDateString(input: []const u8) error{Invalid}!PlainDateRecord {
    var c = Cursor{ .s = input };
    const date = try parseIsoDate(&c);
    if (c.eatAny("Tt ")) {
        _ = try parseIsoTime(&c);
        // A `Z`/`z` UTC designator is rejected: a PlainDate has no time
        // zone, so a UTC point-in-time string is ambiguous as a date
        // (§3.5.x — ToTemporalDate throws when [[Z]] is present).
        if (c.eatAny("Zz")) {
            return error.Invalid;
        } else if (c.peek()) |ch| {
            if (ch == '+' or ch == '-') _ = try parseUtcOffsetNs(&c);
        }
    }
    const calendar = try consumeAnnotations(&c);
    if (!c.done()) return error.Invalid;
    // PlainDate is calendar-aware: a `[u-ca=…]` annotation must name a
    // supported calendar (structural accept; arithmetic stays ISO).
    const cal_id = try calendarIdFromAnnotation(calendar);
    if (!isoDateWithinLimits(date.year, date.month, date.day)) return error.Invalid;
    return .{
        .iso_year = @intCast(date.year),
        .iso_month = @intCast(date.month),
        .iso_day = @intCast(date.day),
        .calendar = cal_id,
    };
}

/// Map an optional `[u-ca=…]` annotation value to a stored calendar id.
/// Absent annotation ⇒ ISO; unsupported / off-tier id ⇒ Invalid.
fn calendarIdFromAnnotation(calendar: ?[]const u8) error{Invalid}!CalendarId {
    const cal = calendar orelse return CalendarId.iso8601();
    if (!intl_config.temporal_intl_extras) {
        if (!std.ascii.eqlIgnoreCase(cal, "iso8601")) return error.Invalid;
        return CalendarId.iso8601();
    }
    return calendarIdFromString(cal) orelse error.Invalid;
}

/// §3.5.x RegulateISODate — apply an overflow option to raw (possibly
/// out-of-range) fields. `reject` returns null on any out-of-range
/// field; otherwise `constrain` clamps only the *upper* bound (month to
/// ≤12, day to ≤ that month's length). A non-positive month or day is a
/// RangeError even under constrain (the test262 `with/overflow.js` and
/// `from/negative-month-or-day.js` fixtures), so those return null too.
/// Returns null when the result leaves the representable range — which
/// also guards the i32 year cast against a huge input year.
pub fn regulateISODate(year: i64, month: i64, day: i64, reject: bool) ?PlainDateRecord {
    var m = month;
    var d = day;
    if (reject) {
        if (!isValidISODate(year, month, day)) return null;
    } else {
        if (month < 1 or day < 1) return null;
        m = @min(month, 12);
        d = @min(day, daysInIsoMonth(year, @intCast(m)));
    }
    if (!isoDateWithinLimits(year, @intCast(m), @intCast(d))) return null;
    return .{ .iso_year = @intCast(year), .iso_month = @intCast(m), .iso_day = @intCast(d) };
}

/// §3.5.x BalanceISOYearMonth — fold an out-of-range month into the
/// year so the month lands in 1..12 (carrying whole years; works for
/// negative months too via floored division).
pub fn balanceISOYearMonth(year: i64, month: i64) struct { year: i64, month: i64 } {
    return .{
        .year = year + @divFloor(month - 1, 12),
        .month = @mod(month - 1, 12) + 1,
    };
}

/// §3.5.x AddISODate — add a date duration (years, months, weeks, days)
/// to an ISO date under `overflow`. Years/months shift the year-month
/// first, with the original day constrained into (or rejected against)
/// the target month; then weeks·7 + days are folded in through the
/// civil-day calendar. Returns null when the result leaves the
/// representable range (→ the caller raises RangeError). Components are
/// the already-validated integer parts of a duration; the valid
/// duration range keeps every intermediate inside i64.
pub fn addISODate(rec: PlainDateRecord, years: i64, months: i64, weeks: i64, days: i64, reject: bool) ?PlainDateRecord {
    const bym = balanceISOYearMonth(@as(i64, rec.iso_year) + years, @as(i64, rec.iso_month) + months);
    const anchored = regulateISODate(bym.year, bym.month, rec.iso_day, reject) orelse return null;
    const epoch = daysFromCivil(anchored.iso_year, anchored.iso_month, anchored.iso_day) + days + weeks * 7;
    if (epoch < iso_date_min_days or epoch > iso_date_max_days) return null;
    const ymd = civilFromDays(epoch);
    return .{
        .iso_year = @intCast(ymd.year),
        .iso_month = @intCast(ymd.month),
        .iso_day = @intCast(ymd.day),
    };
}

/// §3.5.x CompareISODate — total order on ISO dates (year, then month,
/// then day). Compares raw integer fields so the difference constrain-loop
/// can test an unregulated (year, month, day) tuple whose day may exceed
/// the month's length.
fn compareISODateTuple(ay: i64, am: i64, ad: i64, by: i64, bm: i64, bd: i64) i32 {
    if (ay != by) return if (ay < by) -1 else 1;
    if (am != bm) return if (am < bm) -1 else 1;
    if (ad != bd) return if (ad < bd) -1 else 1;
    return 0;
}

pub fn compareISODate(a: PlainDateRecord, b: PlainDateRecord) i32 {
    return compareISODateTuple(a.iso_year, a.iso_month, a.iso_day, b.iso_year, b.iso_month, b.iso_day);
}

/// Did stepping to year-month (y0, m0) with anchor day `d0` reach or pass
/// `target` in the direction `sign`? The per-step test inside
/// DifferenceISODate's year/month constrain-loops: balance the year-month,
/// then compare against the *unregulated* anchor day (compareISODateTuple
/// tolerates a day beyond the month's length).
fn isoDateSurpasses(sign: i32, y0: i64, m0: i64, d0: i64, target: PlainDateRecord) bool {
    const bym = balanceISOYearMonth(y0, m0);
    const c = compareISODateTuple(bym.year, bym.month, d0, target.iso_year, target.iso_month, target.iso_day);
    return sign * c > 0;
}

/// §3.5.x DifferenceISODate — the ISO-calendar CalendarDateUntil: the date
/// duration {years, months, weeks, days} from `d1` to `d2`, with the
/// coarsest component capped at `largest`. Years and months come from an
/// estimate-then-correct constrain-loop (so Jan-31 → Mar-01 across a short
/// February yields one month, not two); the leftover whole days are an
/// exact epoch-day subtraction from the day-constrained year-month anchor;
/// weeks peel off only when `largest` is `week`. The result is
/// sign-consistent — every field shares the direction of travel — and the
/// time fields stay zero (a date has no time-of-day).
pub fn differenceISODate(d1: PlainDateRecord, d2: PlainDateRecord, largest: LargestUnit) DurationRecord {
    const cmp = compareISODate(d1, d2);
    if (cmp == 0) return .{};
    const sign: i32 = -cmp; // +1 when d2 is after d1
    const sg: i64 = sign; // widened for the index arithmetic

    var years: i64 = 0;
    var months: i64 = 0;
    if (largest == .year or largest == .month) {
        // Year estimate: jump to the raw year delta, back off one step
        // toward d1, then advance while we have not yet passed d2.
        var candidate_years: i64 = @as(i64, d2.iso_year) - @as(i64, d1.iso_year);
        if (candidate_years != 0) candidate_years -= sg;
        while (!isoDateSurpasses(sign, @as(i64, d1.iso_year) + candidate_years, d1.iso_month, d1.iso_day, d2)) {
            years = candidate_years;
            candidate_years += sg;
        }
        // Month estimate: advance month-by-month from the year anchor.
        var candidate_months: i64 = sg;
        var inter = balanceISOYearMonth(@as(i64, d1.iso_year) + years, @as(i64, d1.iso_month) + candidate_months);
        while (!isoDateSurpasses(sign, inter.year, inter.month, d1.iso_day, d2)) {
            months = candidate_months;
            candidate_months += sg;
            inter = balanceISOYearMonth(inter.year, inter.month + sg);
        }
        if (largest == .month) {
            months += years * 12;
            years = 0;
        }
    }

    // Whole days: exact epoch-day delta from the constrained year-month
    // anchor (clamps e.g. Jan-31 + 1 month to Feb-28/29) to d2.
    const bym = balanceISOYearMonth(@as(i64, d1.iso_year) + years, @as(i64, d1.iso_month) + months);
    const anchor = regulateISODate(bym.year, bym.month, d1.iso_day, false).?;
    var days: i64 = daysFromCivil(d2.iso_year, d2.iso_month, d2.iso_day) -
        daysFromCivil(anchor.iso_year, anchor.iso_month, anchor.iso_day);

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

/// Advance `start` by the held coarser units plus `r` of the `smallest`
/// calendar unit — the candidate end date NudgeToCalendarUnit measures
/// against. Returns null when the result leaves the representable range.
fn addCalendarUnit(start: PlainDateRecord, smallest: LargestUnit, hy: i64, hm: i64, r: i64) ?PlainDateRecord {
    return switch (smallest) {
        .year => addISODate(start, hy + r, 0, 0, 0, false),
        .month => addISODate(start, hy, hm + r, 0, 0, false),
        .week => addISODate(start, hy, hm, r, 0, false),
        else => unreachable, // irregular-length calendar units only.
    };
}

/// §7.5.31 RoundRelativeDuration / §7.5.34 NudgeToCalendarUnit — the
/// date-only (ISO calendar, no wall-clock time, no time zone)
/// specialization for an irregular-length calendar `smallest` unit
/// (year/month/week). `diff` is the unrounded DifferenceISODate(start, dest,
/// largest) span; round its `smallest` unit to a multiple of `increment`
/// under `mode`, then re-express the rounded span from `start` capped at
/// `largest`. Re-differencing the rounded end date folds in
/// BubbleRelativeDuration's promotion (e.g. 1 year 12 months → 2 years) for
/// free. A `day` smallest unit has fixed length, so it rounds by pure
/// day-count arithmetic in the caller (NudgeToDayOrTime), not here.
///
/// For a date with no time-of-day the epoch-nanosecond ratios of the spec
/// collapse to epoch-day ratios — the 86400×10^9 ns/day factor cancels in
/// every comparison — so progress between the two candidate end dates is
/// measured directly in days. The nine rounding modes are reused exactly by
/// scaling the candidate values by the (positive) day-span denominator and
/// deferring to `roundToIncrement`.
///
/// Returns null when a candidate end date leaves the representable ISO date
/// range (→ the caller raises RangeError, matching AddDate overflow).
pub fn roundRelativeDate(
    start: PlainDateRecord,
    dest: PlainDateRecord,
    diff: DurationRecord,
    smallest: LargestUnit,
    increment: i128,
    mode: RoundingMode,
    largest: LargestUnit,
) ?DurationRecord {
    const sign: i64 = durationSign(diff);
    if (sign == 0) return diff; // start == dest: nothing to round.

    // DifferenceISODate populates only the fields from `largest` down to
    // day, so a year/month-capped diff carries weeks == 0 and folds the
    // sub-month remainder into days. Pick out the unit being rounded and the
    // coarser units held fixed while it rounds.
    const dy: i64 = @intFromFloat(diff.years);
    const dm: i64 = @intFromFloat(diff.months);
    const dw: i64 = @intFromFloat(diff.weeks);
    const dd: i64 = @intFromFloat(diff.days);

    var hy: i64 = 0;
    var hm: i64 = 0;
    var unit_val: i64 = 0;
    switch (smallest) {
        .year => unit_val = dy,
        .month => {
            hy = dy;
            unit_val = dm;
        },
        .week => {
            hy = dy;
            hm = dm;
            // Whole weeks in the sub-month remainder. When `largest` is week
            // the remainder is already split (dw weeks + dd days, |dd| < 7);
            // when it is year/month the weeks sit unsplit inside dd.
            unit_val = @divTrunc(dw * 7 + dd, 7);
        },
        else => unreachable, // irregular-length calendar units only.
    }

    // r1 = unit_val truncated toward zero to a multiple of `increment`;
    // r2 = the next multiple one increment further in the sign direction.
    const inc: i64 = @intCast(increment);
    const r1: i64 = @divTrunc(unit_val, inc) * inc;
    const r2: i64 = r1 + inc * sign;

    const end1 = addCalendarUnit(start, smallest, hy, hm, r1) orelse return null;
    const end2 = addCalendarUnit(start, smallest, hy, hm, r2) orelse return null;

    // Progress of `dest` between the candidates, in epoch days, normalised so
    // the denominator is positive regardless of travel direction. `dest`
    // always lies between end1 and end2, so num ∈ [0, denom].
    const e1: i128 = daysFromCivil(end1.iso_year, end1.iso_month, end1.iso_day);
    const e2: i128 = daysFromCivil(end2.iso_year, end2.iso_month, end2.iso_day);
    const ed: i128 = daysFromCivil(dest.iso_year, dest.iso_month, dest.iso_day);
    const sg: i128 = sign;
    const denom: i128 = sg * (e2 - e1); // > 0
    const num: i128 = sg * (ed - e1); // in [0, denom]

    // total = r1 + (num/denom)·increment·sign. Scale by denom so the nine
    // rounding modes reuse roundToIncrement exactly, then divide back out:
    // rounding total to a multiple of `inc` is rounding (total·denom) to a
    // multiple of (inc·denom). The result is r1 or r2.
    const scaled: i128 = @as(i128, r1) * denom + sg * @as(i128, inc) * num;
    const rounded_scaled = roundToIncrement(scaled, @as(i128, inc) * denom, mode);
    const rounded_unit: i64 = @intCast(@divExact(rounded_scaled, denom));

    // §7.5 NudgeToCalendarUnit steps 18-20: emit the held-units start/end
    // duration verbatim — re-differencing through `differenceISODate` is
    // lossy at end-of-month (rounding 2023-05-31 up to 11 months lands on
    // 2024-04-30, whose `until` is 10mo30d — `until` and `round` legitimately
    // disagree). r1 is the contracted unit, r2 the expanded one.
    const result: DurationRecord = switch (smallest) {
        .year => .{ .years = @floatFromInt(rounded_unit) },
        .month => .{ .years = @floatFromInt(hy), .months = @floatFromInt(rounded_unit) },
        .week => .{ .years = @floatFromInt(hy), .months = @floatFromInt(hm), .weeks = @floatFromInt(rounded_unit) },
        else => unreachable,
    };

    // §7.5 RoundRelativeDuration step 9: bubble an expanded calendar unit up
    // toward `largest` (week never bubbles — it doesn't compose with months).
    // The date has no time-of-day, so the bubble compares end-of-unit
    // boundaries in the midnight frame (epoch-day × ns/day).
    if (rounded_unit == r2 and smallest != .week) {
        const start_dt = PlainDateTimeRecord{
            .iso_year = start.iso_year,
            .iso_month = start.iso_month,
            .iso_day = start.iso_day,
        };
        return bubbleRelativeDateTime(start_dt, result, e2 * ns_per_day, largest, smallest, @intCast(sign));
    }
    return result;
}

// ── §5.5 PlainDateTime (ISO calendar) abstract operations ─────────────────

/// Nanoseconds in one 24-hour day — the carry unit between the date
/// and time halves of a PlainDateTime.
pub const ns_per_day: i128 = 86_400_000_000_000;

/// §5.5.x ISODateTimeWithinLimits — a PlainDateTime is representable
/// when its date sits within ±(10^8 + 1) days of the epoch AND the
/// wall-clock instant (taken as UTC) stays within one day of the
/// Instant range. The one-day slop on each side mirrors the spec: a
/// PlainDateTime at the very edge can still map to an in-range Instant
/// once a time-zone offset is applied.
pub fn isoDateTimeWithinLimits(dt: PlainDateTimeRecord) bool {
    const epoch_days = daysFromCivil(dt.iso_year, dt.iso_month, dt.iso_day);
    if (epoch_days > 100_000_001 or epoch_days < -100_000_001) return false;
    const ns = @as(i128, epoch_days) * ns_per_day + timeRecordToNanoseconds(dt.time());
    if (ns <= ns_min_instant - ns_per_day) return false;
    if (ns >= ns_max_instant + ns_per_day) return false;
    return true;
}

/// §5.5.x AddDateTime — add a Duration to a PlainDateTime. The time
/// fields fold into a within-day nanosecond total whose whole-day
/// overflow (`@divFloor`, so a negative duration borrows correctly)
/// carries into the date half; the date half then reuses AddISODate
/// under `reject` (the overflow option). Returns null when AddISODate
/// leaves the representable range OR the composed result is out of
/// limits (→ the caller raises RangeError).
pub fn addDateTime(dt: PlainDateTimeRecord, dur: DurationRecord, reject: bool) ?PlainDateTimeRecord {
    const result = addDateTimeDateChecked(dt, dur, reject) orelse return null;
    if (!isoDateTimeWithinLimits(result)) return null;
    return result;
}

/// §5.5.x AddDateTime, *date-range only* — identical to AddDateTime but
/// WITHOUT the closing isoDateTimeWithinLimits (RejectDateTimeRange) gate.
/// AddISODate still rejects the date half when it leaves the noon-based
/// PlainDate window, but the composed PlainDateTime may sit in the one-day
/// overflow slop just beyond the Instant limits. DifferencePlainDateTime-
/// WithRounding applies RejectDateTimeRange itself, and only AFTER the
/// CompareISODateTime zero short-circuit — so an empty Duration on an edge
/// relativeTo (whose midnight sits one day below the Instant floor) must not
/// be rejected here.
pub fn addDateTimeDateChecked(dt: PlainDateTimeRecord, dur: DurationRecord, reject: bool) ?PlainDateTimeRecord {
    const time_ns = timeRecordToNanoseconds(dt.time()) + timeDurationNanoseconds(dur);
    const day_carry: i64 = @intCast(@divFloor(time_ns, ns_per_day));
    const within = time_ns - @as(i128, day_carry) * ns_per_day; // [0, ns_per_day)
    const new_time = nanosecondsToTimeRecord(within);
    const new_date = addISODate(
        dt.date(),
        @intFromFloat(dur.years),
        @intFromFloat(dur.months),
        @intFromFloat(dur.weeks),
        @as(i64, @intFromFloat(dur.days)) + day_carry,
        reject,
    ) orelse return null;
    return PlainDateTimeRecord.combine(new_date, new_time);
}

/// The day-carry + rounded time a RoundTime step produces.
pub const RoundTimeResult = struct { days: i64, time: PlainTimeRecord };

/// §5.5.x RoundTime — round a wall-clock time to a multiple of
/// `increment` of `unit` (day..nanosecond) under `mode`. The within-day
/// nanosecond total rounds to the requested boundary measured from
/// midnight; any whole-day overflow becomes the `days` carry (rounding
/// 23:59 up to the next day yields `days = 1`, `time = 00:00`). A `day`
/// unit collapses the time to midnight. `increment` must already be a
/// validated divisor of the unit's day-span.
pub fn roundTime(t: PlainTimeRecord, unit: LargestUnit, increment: i128, mode: RoundingMode) RoundTimeResult {
    const total_ns = timeRecordToNanoseconds(t);
    const rounded = roundToIncrement(total_ns, unitNanoseconds(unit) * increment, mode);
    const days: i64 = @intCast(@divFloor(rounded, ns_per_day));
    const within = rounded - @as(i128, days) * ns_per_day;
    return .{ .days = days, .time = nanosecondsToTimeRecord(within) };
}

/// §5.5.x RoundISODateTime — round the time half (carrying whole days
/// into the date half via AddISODate) and recombine. Returns null when
/// the carried date leaves the representable range.
pub fn roundISODateTime(dt: PlainDateTimeRecord, unit: LargestUnit, increment: i128, mode: RoundingMode) ?PlainDateTimeRecord {
    const rt = roundTime(dt.time(), unit, increment, mode);
    const new_date = addISODate(dt.date(), 0, 0, 0, rt.days, false) orelse return null;
    return PlainDateTimeRecord.combine(new_date, rt.time);
}

/// §5.5.x CompareISODateTime — total order: date first, then wall-clock
/// time. Returns -1 / 0 / +1.
pub fn compareISODateTime(a: PlainDateTimeRecord, b: PlainDateTimeRecord) i32 {
    const c = compareISODate(a.date(), b.date());
    if (c != 0) return c;
    return compareTime(a.time(), b.time());
}

/// §5.5.x DifferenceISODateTime — the Duration from `dt1` to `dt2`,
/// coarsest field capped at `largest`. The time halves differ by a
/// signed nanosecond delta in (-ns_per_day, ns_per_day); when that delta
/// opposes the date direction one day is borrowed from the date half
/// into the time half (so every output field shares a single sign). The
/// date half then defers to DifferenceISODate (capped no finer than
/// `day`), and the borrowed-balanced time delta to BalanceTimeDuration
/// (capped no coarser than `hour`, since whole days live in the date
/// half). The two partial Durations share no field, so the merge is a
/// plain field-wise sum.
pub fn differenceISODateTime(dt1: PlainDateTimeRecord, dt2: PlainDateTimeRecord, largest: LargestUnit) DurationRecord {
    const time_delta = timeRecordToNanoseconds(dt2.time()) - timeRecordToNanoseconds(dt1.time());
    const time_sign: i32 = if (time_delta < 0) -1 else if (time_delta > 0) 1 else 0;
    const date_sign = compareISODate(dt2.date(), dt1.date()); // +1 when dt2 is later

    var adjusted_date1 = dt1.date();
    var time_rem = time_delta;
    if (time_sign != 0 and time_sign == -date_sign) {
        // The time goes one way while the date goes the other: roll
        // `dt1`'s date one day toward `dt2` and add that day back into
        // the time remainder, leaving the total span unchanged.
        adjusted_date1 = addISODate(adjusted_date1, 0, 0, 0, date_sign, false).?;
        time_rem += @as(i128, date_sign) * ns_per_day;
    }

    // dateLargestUnit = LargerOfTwoTemporalUnits("day", largest): the
    // coarser of the two (smaller enum index), but never finer than day.
    const date_largest: LargestUnit = @enumFromInt(@min(@intFromEnum(largest), @intFromEnum(LargestUnit.day)));
    const date_diff = differenceISODate(adjusted_date1, dt2.date(), date_largest);

    // The time remainder is < 1 day, so it never produces a `days`
    // field; balance it with the largest time unit no coarser than hour.
    const time_largest: LargestUnit = @enumFromInt(@max(@intFromEnum(largest), @intFromEnum(LargestUnit.hour)));
    const time_dur = balanceTimeDuration(time_rem, time_largest);

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

/// GetUTCEpochNanoseconds for a PlainDateTime read as a UTC wall clock.
/// `roundRelativeDateTime` only ever compares *differences* of these
/// epochs, so a constant time-zone offset cancels out — which is why a
/// fixed-offset (or UTC) ZonedDateTime difference can delegate to the
/// PlainDateTime computation over its two wall-clock times.
fn utcEpochNsOf(dt: PlainDateTimeRecord) i128 {
    return @as(i128, daysFromCivil(dt.iso_year, dt.iso_month, dt.iso_day)) * ns_per_day +
        timeRecordToNanoseconds(dt.time());
}

/// §7.5.x ComputeNudgeWindow candidate epoch: `start.date` advanced by the
/// held coarser units (`hy`, `hm`) plus `r` of the `smallest` calendar
/// unit, recombined with `start`'s time-of-day. Null on range overflow.
fn calendarWindowEpoch(start_date: PlainDateRecord, smallest: LargestUnit, hy: i64, hm: i64, r: i64, time_ns: i128) ?i128 {
    const d = addCalendarUnit(start_date, smallest, hy, hm, r) orelse return null;
    return @as(i128, daysFromCivil(d.iso_year, d.iso_month, d.iso_day)) * ns_per_day + time_ns;
}

/// Does `dest` lie within the inclusive [start, end] candidate window,
/// oriented by the travel direction `sign`?
fn destInWindow(sign: i32, start_epoch: i128, end_epoch: i128, dest: i128) bool {
    return if (sign == 1)
        (start_epoch <= dest and dest <= end_epoch)
    else
        (end_epoch <= dest and dest <= start_epoch);
}

/// §7.5.x NudgeToCalendarUnit specialised to the ISO calendar with the
/// time zone unset / fixed-offset (see `utcEpochNsOf`). Rounds the
/// irregular-length `smallest` unit (year / month / week) of `diff` to a
/// multiple of `increment` under `mode`, measuring progress toward `end`
/// in nanoseconds (so the time-of-day participates). The held coarser
/// units stay fixed. For year / month, re-differencing the rounded end
/// date folds BubbleRelativeDuration's promotion into the canonical
/// largest-capped form; week never bubbles (§7.5 RoundRelativeDuration
/// step 9 excludes it), so its result is assembled verbatim.
fn nudgeToCalendarUnitDateTime(
    start: PlainDateTimeRecord,
    diff: DurationRecord,
    largest: LargestUnit,
    smallest: LargestUnit,
    increment: i128,
    mode: RoundingMode,
    sign: i32,
    dest_epoch: i128,
) ?DurationRecord {
    const start_date = start.date();
    const start_time_ns = timeRecordToNanoseconds(start.time());

    const dy: i64 = @intFromFloat(diff.years);
    const dm: i64 = @intFromFloat(diff.months);
    const dw: i64 = @intFromFloat(diff.weeks);
    const dd: i64 = @intFromFloat(diff.days);

    var hy: i64 = 0;
    var hm: i64 = 0;
    var unit_val: i64 = 0;
    switch (smallest) {
        .year => unit_val = dy,
        .month => {
            hy = dy;
            unit_val = dm;
        },
        .week => {
            hy = dy;
            hm = dm;
            unit_val = @divTrunc(dw * 7 + dd, 7);
        },
        else => unreachable, // irregular-length calendar units only.
    }

    const inc: i64 = @intCast(increment);
    const base: i64 = @divTrunc(unit_val, inc) * inc; // trunc toward zero

    // ComputeNudgeWindow(additionalShift=false), then the spec's retry:
    // if `dest` is not bracketed by the truncated window (a calendar
    // irregularity), recompute one increment further out.
    var r1: i64 = base;
    var r2: i64 = base + inc * sign;
    var start_epoch = calendarWindowEpoch(start_date, smallest, hy, hm, r1, start_time_ns) orelse return null;
    var end_epoch = calendarWindowEpoch(start_date, smallest, hy, hm, r2, start_time_ns) orelse return null;
    var did_expand = false;
    if (!destInWindow(sign, start_epoch, end_epoch, dest_epoch)) {
        r1 = base + inc * sign;
        r2 = r1 + inc * sign;
        start_epoch = calendarWindowEpoch(start_date, smallest, hy, hm, r1, start_time_ns) orelse return null;
        end_epoch = calendarWindowEpoch(start_date, smallest, hy, hm, r2, start_time_ns) orelse return null;
        did_expand = true; // the retry shift is itself a calendar expansion.
    }

    // progress = (dest - start)/(end - start); total = r1 + progress·inc·sign.
    // Scale by the positive denominator so `roundToIncrement` applies the
    // nine modes exactly, then divide back out → r1 or r2.
    const sg: i128 = sign;
    const denom: i128 = sg * (end_epoch - start_epoch); // > 0
    const num: i128 = sg * (dest_epoch - start_epoch); // in [0, denom]
    const scaled: i128 = @as(i128, r1) * denom + sg * @as(i128, inc) * num;
    const rounded_scaled = roundToIncrement(scaled, @as(i128, inc) * denom, mode);
    const rounded_unit: i64 = @intCast(@divExact(rounded_scaled, denom));

    // §7.5 NudgeToCalendarUnit steps 18-20: emit the held-units start/end
    // duration verbatim — NOT a re-differenced date. Re-differencing through
    // `differenceISODate` is lossy at end-of-month (e.g. 2023-05-31 rounded
    // up to 11 months lands on 2024-04-30, whose `until` from the start is
    // 10mo30d — `until` and `round` legitimately disagree there). The
    // rounded unit is r1 (contracted) or r2 (expanded); the coarser held
    // units stay fixed.
    did_expand = did_expand or (rounded_unit == r2);
    const result: DurationRecord = switch (smallest) {
        .year => .{ .years = @floatFromInt(rounded_unit) },
        .month => .{ .years = @floatFromInt(hy), .months = @floatFromInt(rounded_unit) },
        .week => .{ .years = @floatFromInt(hy), .months = @floatFromInt(hm), .weeks = @floatFromInt(rounded_unit) },
        else => unreachable,
    };

    // §7.5 RoundRelativeDuration step 9: when the calendar unit expanded,
    // bubble it up toward `largest` (week never bubbles — it doesn't compose
    // with months). Per NudgeToCalendarUnit the nudged epoch when expanded is
    // always the window end (`didExpandCalendarUnit ? endEpochNs : …`).
    if (did_expand and smallest != .week) {
        return bubbleRelativeDateTime(start, result, end_epoch, largest, smallest, sign);
    }
    return result;
}

/// §7.5.x BubbleRelativeDuration specialised to the ISO calendar with the
/// time zone unset / fixed-offset. After a nudge has expanded the rounded
/// unit, promote it up toward `largest` wherever the rounded instant has
/// reached the next coarser boundary. `smallest_bubble` is the unit just
/// rounded — LargerOfTwoTemporalUnits(smallestUnit, "day"): `day` for the
/// NudgeToDayOrTime / NudgeToZonedTime paths (start the scan at week), or
/// the calendar `smallest` itself (year / month) for the NudgeToCalendarUnit
/// path (start the scan one unit coarser). Weeks are only promoted when
/// `largest` is week (they don't compose with months). Null on range
/// overflow.
fn bubbleRelativeDateTime(
    start: PlainDateTimeRecord,
    duration: DurationRecord,
    nudged_epoch: i128,
    largest: LargestUnit,
    smallest_bubble: LargestUnit,
    sign: i32,
) ?DurationRecord {
    const largest_idx: i64 = @intFromEnum(largest);
    const start_unit_idx: i64 = @intFromEnum(smallest_bubble);
    if (start_unit_idx == largest_idx) return duration; // startUnit == largestUnit.

    const start_date = start.date();
    const start_time_ns = timeRecordToNanoseconds(start.time());

    var result = duration;
    var unit_idx: i64 = start_unit_idx - 1; // one unit coarser than the start
    var done = false;
    while (unit_idx >= largest_idx and !done) : (unit_idx -= 1) {
        const unit: LargestUnit = @enumFromInt(@as(u4, @intCast(unit_idx)));
        if (unit == .week and largest != .week) continue;

        const cy: i64 = @intFromFloat(result.years);
        const cm: i64 = @intFromFloat(result.months);
        const cw: i64 = @intFromFloat(result.weeks);
        var end_dur: DurationRecord = undefined;
        var end_date_opt: ?PlainDateRecord = null;
        switch (unit) {
            .year => {
                end_dur = .{ .years = @floatFromInt(cy + sign) };
                end_date_opt = addISODate(start_date, cy + sign, 0, 0, 0, false);
            },
            .month => {
                end_dur = .{ .years = result.years, .months = @floatFromInt(cm + sign) };
                end_date_opt = addISODate(start_date, cy, cm + sign, 0, 0, false);
            },
            .week => {
                end_dur = .{ .years = result.years, .months = result.months, .weeks = @floatFromInt(cw + sign) };
                end_date_opt = addISODate(start_date, cy, cm, cw + sign, 0, false);
            },
            else => unreachable,
        }
        const end_date = end_date_opt orelse return null;
        const end_epoch = @as(i128, daysFromCivil(end_date.iso_year, end_date.iso_month, end_date.iso_day)) * ns_per_day + start_time_ns;
        const beyond = nudged_epoch - end_epoch;
        const beyond_sign: i32 = if (beyond < 0) -1 else if (beyond > 0) 1 else 0;
        if (beyond_sign != -sign) {
            result = end_dur; // the rounded instant still reaches this boundary.
        } else {
            done = true;
        }
    }
    return result;
}

/// §7.5.x NudgeToDayOrTime specialised to the ISO calendar with the time
/// zone unset / fixed-offset. Rounds the combined day+time span (days fold
/// into nanoseconds at 24 h each) to a multiple of `increment` of the
/// `smallest` time unit (day … nanosecond) under `mode`. When `largest`
/// is a date unit the whole-day carry stays in the date half and the
/// sub-day remainder balances into hours-and-finer; a day expansion then
/// bubbles up. When `largest` is a time unit the whole span balances into
/// time fields. Null on range overflow (via the bubble step).
fn nudgeToDayOrTimeDateTime(
    start: PlainDateTimeRecord,
    diff: DurationRecord,
    largest: LargestUnit,
    smallest: LargestUnit,
    increment: i128,
    mode: RoundingMode,
    sign: i32,
    dest_epoch: i128,
) ?DurationRecord {
    const diff_days: i64 = @intFromFloat(diff.days);
    const time_total: i128 = timeDurationNanoseconds(diff) + @as(i128, diff_days) * ns_per_day;
    const unit_len = unitNanoseconds(smallest); // day … nanosecond
    const rounded = roundToIncrement(time_total, unit_len * increment, mode);
    const diff_time = rounded - time_total;
    const whole_days = @divTrunc(time_total, ns_per_day);
    const rounded_whole_days = @divTrunc(rounded, ns_per_day);
    const day_delta = rounded_whole_days - whole_days;

    const tsign: i32 = if (time_total < 0) -1 else if (time_total > 0) 1 else 0;
    const ddsign: i32 = if (day_delta < 0) -1 else if (day_delta > 0) 1 else 0;
    const did_expand_days = ddsign == tsign;
    const nudged_epoch = dest_epoch + diff_time;

    const date_category = @intFromEnum(largest) <= @intFromEnum(LargestUnit.day);
    var days_field: i64 = 0;
    var remainder: i128 = rounded;
    var time_largest = largest;
    if (date_category) {
        days_field = @intCast(rounded_whole_days);
        remainder = rounded - rounded_whole_days * ns_per_day;
        time_largest = .hour;
    }

    const time_dur = balanceTimeDuration(remainder, time_largest);
    var result = DurationRecord{
        .years = diff.years,
        .months = diff.months,
        .weeks = diff.weeks,
        .days = @floatFromInt(days_field),
        .hours = time_dur.hours,
        .minutes = time_dur.minutes,
        .seconds = time_dur.seconds,
        .milliseconds = time_dur.milliseconds,
        .microseconds = time_dur.microseconds,
        .nanoseconds = time_dur.nanoseconds,
    };

    // §7.5 RoundRelativeDuration step 9: smallest is day-or-finer here, so
    // it is never week → always bubble-eligible. Bubbling only has an
    // effect when `largest` is a date unit (else it is a no-op).
    if (did_expand_days and date_category) {
        result = bubbleRelativeDateTime(start, result, nudged_epoch, largest, .day, sign) orelse return null;
    }
    return result;
}

/// §7.5.x RoundRelativeDuration specialised to the ISO calendar with the
/// time zone unset (PlainDateTime) or fixed-offset/UTC (ZonedDateTime — a
/// constant offset cancels in every epoch difference, so the zoned
/// difference equals the PlainDateTime difference of the two wall-clock
/// times). `diff` is the unrounded span `differenceISODateTime(start, end,
/// largest)`; this rounds its `smallest` unit to a multiple of `increment`
/// under `mode` and bubbles overflow up to `largest`. Returns null when a
/// candidate date leaves the representable range (→ caller raises
/// RangeError).
pub fn roundRelativeDateTime(
    start: PlainDateTimeRecord,
    end: PlainDateTimeRecord,
    diff: DurationRecord,
    largest: LargestUnit,
    smallest: LargestUnit,
    increment: i128,
    mode: RoundingMode,
) ?DurationRecord {
    const sign: i32 = durationSign(diff);
    if (sign == 0) return diff;
    const dest_epoch = utcEpochNsOf(end);

    // IsCalendarUnit(smallest): year / month / week have irregular length
    // and route through NudgeToCalendarUnit; day-or-finer through
    // NudgeToDayOrTime. (Day is irregular only under a real time zone,
    // which the fixed-offset scope never has.)
    if (@intFromEnum(smallest) < @intFromEnum(LargestUnit.day)) {
        return nudgeToCalendarUnitDateTime(start, diff, largest, smallest, increment, mode, sign, dest_epoch);
    }
    return nudgeToDayOrTimeDateTime(start, diff, largest, smallest, increment, mode, sign, dest_epoch);
}

/// §7.5.x NudgeToZonedTime specialised to fixed-offset / UTC time zones,
/// where every day is exactly 24 h. The zoned branch of RoundRelativeDuration
/// rounds only the sub-day *time* component of `diff`, holding the date
/// (years/months/weeks/days) fixed except for a possible ±1-day carry when
/// the rounded time reaches the 24 h day boundary — unlike NudgeToDayOrTime,
/// which folds whole days into the rounded span (so a ZonedDateTime
/// relativeTo accounts days separately even when, as here, every day is the
/// same length). `smallest` is a time unit (hour … nanosecond). A whole-day
/// carry then bubbles up toward `largest`. Null on range overflow.
pub fn nudgeToZonedTimeDateTime(
    start: PlainDateTimeRecord,
    tz: TimeZone,
    diff: DurationRecord,
    largest: LargestUnit,
    smallest: LargestUnit,
    increment: i128,
    mode: RoundingMode,
) ?DurationRecord {
    // §7.5.x RoundRelativeDuration: a zero duration takes sign +1 (the nudge
    // still runs), so even an empty duration probes the next-day boundary.
    const sign: i32 = if (durationSign(diff) < 0) -1 else 1;

    const dy: i64 = @intFromFloat(diff.years);
    const dm: i64 = @intFromFloat(diff.months);
    const dw: i64 = @intFromFloat(diff.weeks);
    const dd: i64 = @intFromFloat(diff.days);

    // start = CalendarDateAdd(start.date, diff.date); end = start ± 1 day.
    // Both whole-day boundaries must anchor to in-range instants: when the
    // next day overflows the Instant limits GetEpochNanosecondsFor fails and
    // the entire round is a RangeError (e.g. a relativeTo at the max instant
    // whose following midnight is unrepresentable).
    const anchor_date = addISODate(start.date(), dy, dm, dw, dd, false) orelse return null;
    const end_date = addISODate(anchor_date, 0, 0, 0, sign, false) orelse return null;
    const start_dt = PlainDateTimeRecord.combine(anchor_date, start.time());
    const end_dt = PlainDateTimeRecord.combine(end_date, start.time());
    const start_epoch = getEpochNanosecondsFor(tz, start_dt) orelse return null;
    const end_epoch = getEpochNanosecondsFor(tz, end_dt) orelse return null;
    const day_span: i128 = end_epoch - start_epoch; // ±ns_per_day for a fixed offset

    const unit_inc = unitNanoseconds(smallest) * increment;
    const time_ns = timeDurationNanoseconds(diff);

    var rounded = roundToIncrement(time_ns, unit_inc, mode);
    const beyond = rounded - day_span;
    const beyond_sign: i32 = if (beyond < 0) -1 else if (beyond > 0) 1 else 0;
    const did_round_beyond = beyond_sign != -sign;

    var day_delta: i64 = 0;
    if (did_round_beyond) {
        day_delta = sign;
        rounded = roundToIncrement(beyond, unit_inc, mode);
    }

    const time_dur = balanceTimeDuration(rounded, .hour);
    var result = DurationRecord{
        .years = diff.years,
        .months = diff.months,
        .weeks = diff.weeks,
        .days = @floatFromInt(dd + day_delta),
        .hours = time_dur.hours,
        .minutes = time_dur.minutes,
        .seconds = time_dur.seconds,
        .milliseconds = time_dur.milliseconds,
        .microseconds = time_dur.microseconds,
        .nanoseconds = time_dur.nanoseconds,
    };

    if (did_round_beyond) {
        // BubbleRelativeDuration compares end-of-unit boundaries in the
        // UTC-wall frame, so recompute the nudged instant there: the wall
        // epoch of `end_dt` (the anchor advanced one day) plus the rounded
        // sub-day remainder.
        const start_time_ns = timeRecordToNanoseconds(start.time());
        const end_wall_epoch = @as(i128, daysFromCivil(end_date.iso_year, end_date.iso_month, end_date.iso_day)) * ns_per_day + start_time_ns;
        const nudged_epoch = end_wall_epoch + rounded;
        result = bubbleRelativeDateTime(start, result, nudged_epoch, largest, .day, sign) orelse return null;
    }
    return result;
}

/// §7.5.x DateDurationDays — the whole-day span of a duration's date
/// component: the years / months / weeks balanced down to days through the
/// ISO calendar from `anchor` (under `constrain`), plus the duration's
/// literal `days`. Temporal.Duration.compare uses this to place two
/// calendar-bearing durations on a common day axis before adding their
/// sub-day time. Null when the balanced date leaves the representable range.
pub fn dateDurationDays(anchor: PlainDateRecord, dur: DurationRecord) ?i128 {
    const dd: i128 = f64ToI128(dur.days);
    if (dur.years == 0 and dur.months == 0 and dur.weeks == 0) return dd;
    const later = addISODate(
        anchor,
        @intFromFloat(dur.years),
        @intFromFloat(dur.months),
        @intFromFloat(dur.weeks),
        0,
        false,
    ) orelse return null;
    const ymw_days: i128 = @as(i128, daysFromCivil(later.iso_year, later.iso_month, later.iso_day)) -
        @as(i128, daysFromCivil(anchor.iso_year, anchor.iso_month, anchor.iso_day));
    return dd + ymw_days;
}

/// §7.5.x TotalRelativeDuration for an irregular calendar unit
/// (year / month / week) — the *fractional* count of `unit` between `start`
/// and `dest_epoch`, matching NudgeToCalendarUnit's `total` output at
/// increment 1. `diff` is the already-balanced difference
/// (DifferenceISODateTime at largestUnit = `unit`); `dest_epoch` is the
/// destination's UTC-wall epoch (`isoDateTimeToEpochNs` of the target wall
/// clock — a constant zone offset cancels in the ratio, so the wall frame is
/// exact for the fixed-offset / unset scope). The window is the pair of
/// integer-unit boundaries bracketing `dest_epoch`; the total interpolates
/// linearly between them. Null on range overflow.
pub fn totalRelativeDateTime(start: PlainDateTimeRecord, diff: DurationRecord, dest_epoch: i128, unit: LargestUnit) ?f64 {
    const start_date = start.date();
    const start_time_ns = timeRecordToNanoseconds(start.time());
    const sign: i32 = if (durationSign(diff) < 0) -1 else 1;

    const dy: i64 = @intFromFloat(diff.years);
    const dm: i64 = @intFromFloat(diff.months);
    const dw: i64 = @intFromFloat(diff.weeks);
    const dd: i64 = @intFromFloat(diff.days);

    var hy: i64 = 0;
    var hm: i64 = 0;
    var unit_val: i64 = 0;
    switch (unit) {
        .year => unit_val = dy,
        .month => {
            hy = dy;
            unit_val = dm;
        },
        .week => {
            hy = dy;
            hm = dm;
            unit_val = @divTrunc(dw * 7 + dd, 7);
        },
        else => unreachable, // irregular-length calendar units only.
    }

    // ComputeNudgeWindow at increment 1, then the spec's retry when `dest`
    // is not bracketed by the truncated window (a calendar irregularity).
    var r1: i64 = unit_val;
    var start_epoch = calendarWindowEpoch(start_date, unit, hy, hm, r1, start_time_ns) orelse return null;
    var end_epoch = calendarWindowEpoch(start_date, unit, hy, hm, r1 + sign, start_time_ns) orelse return null;
    if (!destInWindow(sign, start_epoch, end_epoch, dest_epoch)) {
        r1 = unit_val + sign;
        start_epoch = calendarWindowEpoch(start_date, unit, hy, hm, r1, start_time_ns) orelse return null;
        end_epoch = calendarWindowEpoch(start_date, unit, hy, hm, r1 + sign, start_time_ns) orelse return null;
    }

    // total = r1 + sign·(dest − start)/(end − start), formed as the single
    // fraction (denominator·r1 + numerator·sign) ⁄ denominator to mirror the
    // spec's `fakeNumerator.fdiv(denominator)` shape.
    const denom: i128 = end_epoch - start_epoch;
    const numer: i128 = dest_epoch - start_epoch;
    const fake: i128 = denom * @as(i128, r1) + numer * @as(i128, sign);
    return divRoundToF64(fake, denom);
}

/// §7.5.x ComputeNudgeWindow candidate end date: `start_date` advanced by the
/// held coarser units plus `r` of `unit`. Generalises `addCalendarUnit` to
/// the `day` unit (holding weeks as well), as the zoned `day` total needs.
/// Null on ISO-date overflow.
fn windowBoundaryDate(start_date: PlainDateRecord, unit: LargestUnit, hy: i64, hm: i64, hw: i64, r: i64) ?PlainDateRecord {
    return switch (unit) {
        .year => addISODate(start_date, r, 0, 0, 0, false),
        .month => addISODate(start_date, hy, r, 0, 0, false),
        .week => addISODate(start_date, hy, hm, r, 0, false),
        .day => addISODate(start_date, hy, hm, hw, r, false),
        else => unreachable, // year / month / week / day windows only.
    };
}

/// Is ComputeNudgeWindow's start duration all zero? When so the spec reuses
/// `originEpochNs` directly rather than round-tripping the start date through
/// the zone (§7.5.x ComputeNudgeWindow, the `DateDurationSign === 0` branch).
fn windowStartIsOrigin(unit: LargestUnit, hy: i64, hm: i64, hw: i64, r1: i64) bool {
    return switch (unit) {
        .year => r1 == 0,
        .month => hy == 0 and r1 == 0,
        .week => hy == 0 and hm == 0 and r1 == 0,
        .day => hy == 0 and hm == 0 and hw == 0 and r1 == 0,
        else => unreachable,
    };
}

const ZonedWindowBounds = struct { start_epoch: i128, end_epoch: i128 };

/// §7.5.x ComputeNudgeWindow for a fixed-offset (or UTC) zone: the window's
/// start (`r1` units from the origin) and end (`r1 + sign` units) boundaries
/// re-anchored to epoch nanoseconds *through the time zone*. Returns null when
/// either boundary leaves the representable Instant range — the overflow path
/// that distinguishes a zoned total from the wall-frame one.
fn zonedWindowBounds(
    start_date: PlainDateRecord,
    start_time: PlainTimeRecord,
    tz: TimeZone,
    unit: LargestUnit,
    hy: i64,
    hm: i64,
    hw: i64,
    r1: i64,
    sign: i64,
    origin_epoch: i128,
) ?ZonedWindowBounds {
    const start_epoch = if (windowStartIsOrigin(unit, hy, hm, hw, r1))
        origin_epoch
    else blk: {
        const d = windowBoundaryDate(start_date, unit, hy, hm, hw, r1) orelse return null;
        break :blk getEpochNanosecondsFor(tz, PlainDateTimeRecord.combine(d, start_time)) orelse return null;
    };
    const end_date = windowBoundaryDate(start_date, unit, hy, hm, hw, r1 + sign) orelse return null;
    const end_epoch = getEpochNanosecondsFor(tz, PlainDateTimeRecord.combine(end_date, start_time)) orelse return null;
    return .{ .start_epoch = start_epoch, .end_epoch = end_epoch };
}

/// §7.5.x TotalRelativeDuration / NudgeToCalendarUnit for a fixed-offset (or
/// UTC) time zone and the ISO calendar — the fractional count of an
/// irregular-length calendar unit (year / month / week) OR a `day` unit
/// between `origin_epoch` and `dest_epoch`. Unlike `totalRelativeDateTime`
/// (the time-zone-free wall-frame total) the window boundaries are re-anchored
/// through the zone with `getEpochNanosecondsFor`, so a boundary instant past
/// the representable Instant range yields null and the caller raises
/// RangeError. This is the one observable divergence between a zoned and a
/// plain `day` total: DifferenceZonedDateTimeWithTotal routes a `day` unit
/// through this calendar-window technique (the `timeZone && unit === "day"`
/// branch of TotalRelativeDuration) precisely so a next-day boundary past the
/// Instant range throws, whereas the plain `day` total is a pure wall span.
///
/// For a fixed-offset zone every day is exactly 24 h and the constant offset
/// cancels in the (dest − start)/(end − start) ratio, so `diff` — the
/// DifferenceISODateTime of the two wall clocks capped at `unit` — and the
/// resulting value match the instant-frame computation exactly. `start` is the
/// origin wall clock (GetISODateTimeFor at `origin_epoch`); the spec's
/// `originEpochNs` short-circuit reuses `origin_epoch` when the window's start
/// duration is zero.
pub fn totalRelativeZonedDateTime(
    start: PlainDateTimeRecord,
    tz: TimeZone,
    origin_epoch: i128,
    diff: DurationRecord,
    dest_epoch: i128,
    unit: LargestUnit,
) ?f64 {
    const start_date = start.date();
    const start_time = start.time();
    const sign: i64 = if (durationSign(diff) < 0) -1 else 1;

    const dy: i64 = @intFromFloat(diff.years);
    const dm: i64 = @intFromFloat(diff.months);
    const dw: i64 = @intFromFloat(diff.weeks);
    const dd: i64 = @intFromFloat(diff.days);

    // Held coarser units + the value of the unit being totalled, matching
    // ComputeNudgeWindow's per-unit start/end duration construction. `day`
    // holds years/months/weeks; week folds the sub-month day remainder in.
    var hy: i64 = 0;
    var hm: i64 = 0;
    var hw: i64 = 0;
    var unit_val: i64 = 0;
    switch (unit) {
        .year => unit_val = dy,
        .month => {
            hy = dy;
            unit_val = dm;
        },
        .week => {
            hy = dy;
            hm = dm;
            unit_val = @divTrunc(dw * 7 + dd, 7);
        },
        .day => {
            hy = dy;
            hm = dm;
            hw = dw;
            unit_val = dd;
        },
        else => unreachable, // calendar units + day only.
    }

    // ComputeNudgeWindow at increment 1, then the spec's retry when `dest`
    // is not bracketed by the truncated window (a calendar irregularity).
    var r1: i64 = unit_val;
    var bounds = zonedWindowBounds(start_date, start_time, tz, unit, hy, hm, hw, r1, sign, origin_epoch) orelse return null;
    if (!destInWindow(@intCast(sign), bounds.start_epoch, bounds.end_epoch, dest_epoch)) {
        r1 = unit_val + sign;
        bounds = zonedWindowBounds(start_date, start_time, tz, unit, hy, hm, hw, r1, sign, origin_epoch) orelse return null;
    }

    // total = r1 + sign·(dest − start)/(end − start), formed as the single
    // fraction (denominator·r1 + numerator·sign) ⁄ denominator to mirror the
    // spec's `fakeNumerator.fdiv(denominator)` shape.
    const denom: i128 = bounds.end_epoch - bounds.start_epoch;
    const numer: i128 = dest_epoch - bounds.start_epoch;
    const fake: i128 = denom * @as(i128, r1) + numer * @as(i128, sign);
    return divRoundToF64(fake, denom);
}

/// §5.5.x ISODateTimeToString with `precision="auto"` — the form
/// `Temporal.PlainDateTime.prototype.toString` / `toJSON` produce:
/// `YYYY-MM-DDTHH:MM:SS` plus a trimmed sub-second fraction, then the
/// ISO calendar annotation per `calendar`. Years outside 0000..9999 use
/// the expanded `±YYYYYY` form.
pub fn isoDateTimeToString(dt: PlainDateTimeRecord, buf: []u8, calendar: CalendarDisplay, precision: Precision) []const u8 {
    var w = Writer{ .buf = buf, .len = 0 };
    writeIsoYear(&w, dt.iso_year);
    w.byte('-');
    w.pad2(dt.iso_month);
    w.byte('-');
    w.pad2(dt.iso_day);
    w.byte('T');
    const sub_ns: u32 = dt.millisecond * 1_000_000 + dt.microsecond * 1_000 + dt.nanosecond;
    writeTimeFields(&w, dt.hour, dt.minute, dt.second, sub_ns, precision);
    writeCalendarAnnotation(&w, dt.calendar, calendar);
    return w.buf[0..w.len];
}

/// §5.5.x ParseTemporalDateTimeString — parse an ISO / RFC 9557 string
/// into an ISO date-time. The time is optional (a bare date defaults to
/// midnight); any UTC offset is validated then discarded (a PlainDateTime
/// carries no offset), but a `Z`/`z` UTC designator is rejected as
/// ambiguous. A `[u-ca=…]` annotation must name the ISO calendar.
pub fn parseTemporalDateTimeString(input: []const u8) error{Invalid}!PlainDateTimeRecord {
    var c = Cursor{ .s = input };
    const date = try parseIsoDate(&c);
    var time = ParsedTime{ .hour = 0, .minute = 0, .second = 0, .sub_ns = 0 };
    if (c.eatAny("Tt ")) {
        time = try parseIsoTime(&c);
        if (c.eatAny("Zz")) {
            return error.Invalid;
        } else if (c.peek()) |ch| {
            if (ch == '+' or ch == '-') _ = try parseUtcOffsetNs(&c);
        }
    }
    const calendar = try consumeAnnotations(&c);
    if (!c.done()) return error.Invalid;
    const cal_id = try calendarIdFromAnnotation(calendar);
    const rec = PlainDateTimeRecord{
        .iso_year = @intCast(date.year),
        .iso_month = @intCast(date.month),
        .iso_day = @intCast(date.day),
        .hour = time.hour,
        .minute = time.minute,
        .second = time.second,
        .millisecond = time.sub_ns / 1_000_000,
        .microsecond = (time.sub_ns / 1_000) % 1_000,
        .nanosecond = time.sub_ns % 1_000,
        .calendar = cal_id,
    };
    if (!isoDateTimeWithinLimits(rec)) return error.Invalid;
    return rec;
}

/// The pieces a ZonedDateTime string yields: the wall-clock ISO date-time,
/// how its offset should be interpreted, the parsed offset (signed ns,
/// meaningful only when `behaviour == .option`), and the bracketed time
/// zone. Folding these into an epoch is `interpretISODateTimeOffset`'s job
/// (it needs the `offset` resolution option, which lives JS-side).
pub const ParsedZonedDateTime = struct {
    date_time: PlainDateTimeRecord,
    behaviour: OffsetBehaviour,
    offset_ns: i128,
    time_zone: TimeZone,
};

/// §6.5.x ParseTemporalZonedDateTimeString — an ISO / RFC 9557 date-time
/// with a **required** `[time-zone]` annotation. The time is optional (a
/// bare date is midnight); a `Z`/`z` designator marks the wall time as
/// exact UTC, a numeric offset is resolved per the caller's `offset`
/// option, and absence of both means the zone alone places the instant.
/// Named IANA zones are accepted structurally (UTC offset until tzdata).
/// A `[u-ca=…]` annotation must name a supported calendar.
pub fn parseTemporalZonedDateTimeString(input: []const u8) error{Invalid}!ParsedZonedDateTime {
    var c = Cursor{ .s = input };
    const date = try parseIsoDate(&c);
    var time = ParsedTime{ .hour = 0, .minute = 0, .second = 0, .sub_ns = 0 };
    var behaviour: OffsetBehaviour = .wall;
    var offset_ns: i128 = 0;
    if (c.eatAny("Tt ")) {
        time = try parseIsoTime(&c);
        if (c.eatAny("Zz")) {
            behaviour = .exact;
        } else if (c.peek()) |ch| {
            if (ch == '+' or ch == '-') {
                offset_ns = try parseUtcOffsetNs(&c);
                behaviour = .option;
            }
        }
    }
    var tz_body: ?[]const u8 = null;
    const calendar = try consumeAnnotationsImpl(&c, &tz_body);
    if (!c.done()) return error.Invalid;
    const body = tz_body orelse return error.Invalid; // the annotation is required
    const tz = parseTimeZoneIdentifier(body) orelse return error.Invalid;
    const cal_id = try calendarIdFromAnnotation(calendar);
    const rec = PlainDateTimeRecord{
        .iso_year = @intCast(date.year),
        .iso_month = @intCast(date.month),
        .iso_day = @intCast(date.day),
        .hour = time.hour,
        .minute = time.minute,
        .second = time.second,
        .millisecond = time.sub_ns / 1_000_000,
        .microsecond = (time.sub_ns / 1_000) % 1_000,
        .nanosecond = time.sub_ns % 1_000,
        .calendar = cal_id,
    };
    // No PlainDateTime-range gate here: ParseISODateTime does not range-check,
    // and the wall clock of a valid zoned string can legitimately sit one ISO
    // day below the PlainDateTime floor (e.g. `-271821-04-19T00:00`, whose
    // midnight is one day under the floor but whose instant after the offset is
    // representable). InterpretISODateTimeOffset applies the right bound
    // (CheckISODaysRange for an `option` offset, IsValidEpochNanoseconds for an
    // exact `Z`), so a genuinely out-of-range value still rejects — just later.
    return .{ .date_time = rec, .behaviour = behaviour, .offset_ns = offset_ns, .time_zone = tz };
}

/// Parse a standalone numeric UTC-offset string (`±HH`, `±HH:MM`,
/// `±HH:MM:SS[.fraction]`, or the colon-free forms) — the value of a
/// property bag's `offset` field — into signed nanoseconds. Returns null
/// on any malformed input or trailing garbage.
pub fn parseOffsetString(input: []const u8) ?i128 {
    var c = Cursor{ .s = input };
    const ch = c.peek() orelse return null;
    if (ch != '+' and ch != '-') return null;
    const ns = parseUtcOffsetNs(&c) catch return null;
    if (!c.done()) return null;
    return ns;
}

// ── §9 Temporal.PlainYearMonth abstract operations (pure) ──────────────────

/// §9.5.x ISOYearMonthWithinLimits — the year-month is representable iff
/// it overlaps the ISODate range; the spec checks only year+month (the
/// reference day is irrelevant). Limits: April -271821 … September 275760.
pub fn isoYearMonthWithinLimits(year: i64, month: i64) bool {
    if (year < -271821 or year > 275760) return false;
    if (year == -271821 and month < 4) return false;
    if (year == 275760 and month > 9) return false;
    return true;
}

/// §9.5.x TemporalYearMonthToString — `YYYY-MM`, expanding the year past
/// 0000..9999. The reference day is appended (`YYYY-MM-DD`) only when the
/// calendar annotation is shown (always / critical), per the spec's
/// "show calendar OR non-ISO calendar" condition — Cynic is ISO-only, so
/// auto / never omit both day and annotation.
pub fn isoYearMonthToString(rec: PlainYearMonthRecord, buf: []u8, calendar: CalendarDisplay) []const u8 {
    var w = Writer{ .buf = buf, .len = 0 };
    writeIsoYear(&w, rec.iso_year);
    w.byte('-');
    w.pad2(rec.iso_month);
    // The reference day appears whenever the annotation does (always /
    // critical, or a non-ISO calendar under auto).
    const show_day = switch (calendar) {
        .always, .critical => true,
        .auto => !rec.calendar.isIso(),
        .never => false,
    };
    if (show_day) {
        w.byte('-');
        w.pad2(rec.ref_iso_day);
    }
    writeCalendarAnnotation(&w, rec.calendar, calendar);
    return w.buf[0..w.len];
}

/// Parse year, month, and an OPTIONAL reference day (default 1) at the
/// cursor — the DateSpecYearMonth (`YYYY-MM`, `YYYYMM`) grammar plus the
/// full-date form an AnnotatedDateTime allows. A `±YYYYYY` expanded year
/// is accepted in either separator style.
fn parseIsoYearMonth(c: *Cursor) error{Invalid}!ParsedDate {
    var year: i64 = undefined;
    const lead = c.peek() orelse return error.Invalid;
    if (lead == '+' or lead == '-') {
        const neg = lead == '-';
        c.i += 1;
        const y = c.fixedDigits(6) orelse return error.Invalid;
        if (neg and y == 0) return error.Invalid;
        year = if (neg) -@as(i64, @intCast(y)) else @as(i64, @intCast(y));
    } else {
        const y = c.fixedDigits(4) orelse return error.Invalid;
        year = @intCast(y);
    }
    const extended = c.eat('-');
    const month: u32 = @intCast(c.fixedDigits(2) orelse return error.Invalid);
    if (month < 1 or month > 12) return error.Invalid;
    var day: u32 = 1;
    if (extended) {
        if (c.eat('-')) day = @intCast(c.fixedDigits(2) orelse return error.Invalid);
    } else if (c.isDigit()) {
        day = @intCast(c.fixedDigits(2) orelse return error.Invalid);
    }
    if (day < 1 or day > daysInIsoMonth(year, month)) return error.Invalid;
    return .{ .year = year, .month = month, .day = day };
}

/// §9.5.x ParseTemporalYearMonthString — the reference day comes from the
/// string when it carried a full date, else defaults to 1. A trailing
/// time / offset / annotation block is validated but discarded; a `Z`
/// UTC designator is rejected (a year-month has no time zone).
pub fn parseTemporalYearMonthString(input: []const u8) error{Invalid}!PlainYearMonthRecord {
    var c = Cursor{ .s = input };
    const date = try parseIsoYearMonth(&c);
    if (c.eatAny("Tt ")) {
        _ = try parseIsoTime(&c);
        if (c.eatAny("Zz")) {
            return error.Invalid;
        } else if (c.peek()) |ch| {
            if (ch == '+' or ch == '-') _ = try parseUtcOffsetNs(&c);
        }
    }
    const calendar = try consumeAnnotations(&c);
    if (!c.done()) return error.Invalid;
    const cal_id = try calendarIdFromAnnotation(calendar);
    if (!isoYearMonthWithinLimits(date.year, date.month)) return error.Invalid;
    return .{
        .iso_year = @intCast(date.year),
        .iso_month = @intCast(date.month),
        .ref_iso_day = @intCast(date.day),
        .calendar = cal_id,
    };
}

// ── §10 Temporal.PlainMonthDay abstract operations (pure) ──────────────────

/// §10.5.x TemporalMonthDayToString — `MM-DD`. The reference year is
/// prepended (`YYYY-MM-DD`) only when the calendar annotation is shown
/// (always / critical), mirroring the year-month rule.
pub fn isoMonthDayToString(rec: PlainMonthDayRecord, buf: []u8, calendar: CalendarDisplay) []const u8 {
    var w = Writer{ .buf = buf, .len = 0 };
    const cal_slice = rec.calendar.slice();
    const is_iso = rec.calendar.isIso();
    // §IsoDateToString: a non-ISO calendar's reference year is meaningful, so it
    // (and the annotation) appear even under "auto"; ISO keeps the bare MM-DD.
    if (calendar == .always or calendar == .critical or !is_iso) {
        writeIsoYear(&w, rec.ref_iso_year);
        w.byte('-');
    }
    w.pad2(rec.iso_month);
    w.byte('-');
    w.pad2(rec.iso_day);
    switch (calendar) {
        .never => {},
        .auto => if (!is_iso) {
            w.bytes("[u-ca=");
            w.bytes(cal_slice);
            w.byte(']');
        },
        .always => {
            w.bytes("[u-ca=");
            w.bytes(cal_slice);
            w.byte(']');
        },
        .critical => {
            w.bytes("[!u-ca=");
            w.bytes(cal_slice);
            w.byte(']');
        },
    }
    return w.buf[0..w.len];
}

/// Parse a month-day body (`MM-DD` or `MMDD`) at the cursor, validating
/// the day against the leap-year reference 1972 (so Feb 29 is accepted).
fn parseMonthDayBody(c: *Cursor) error{Invalid}!ParsedDate {
    const month: u32 = @intCast(c.fixedDigits(2) orelse return error.Invalid);
    _ = c.eat('-');
    const day: u32 = @intCast(c.fixedDigits(2) orelse return error.Invalid);
    if (month < 1 or month > 12) return error.Invalid;
    if (day < 1 or day > daysInIsoMonth(1972, month)) return error.Invalid;
    return .{ .year = 1972, .month = month, .day = day };
}

/// Parse the date portion of a TemporalMonthDayString: the
/// DateSpecMonthDay forms (`--MM-DD`, `MM-DD`, `--MMDD`, `MMDD`) or a
/// full date (`YYYY-MM-DD`, expanded `±YYYYYY-MM-DD`, basic `YYYYMMDD`).
/// Disambiguation rests on the first numeric field width: a 2-digit
/// field then `-`, or a bare 4-digit field, is a month-day; a sign or a
/// wider leading field is a full date (whose year validates the day).
fn parseIsoMonthDay(c: *Cursor) error{Invalid}!ParsedDate {
    // Explicit `--` prefix is unambiguously a month-day.
    if (c.peek() == '-' and c.i + 1 < c.s.len and c.s[c.i + 1] == '-') {
        c.i += 2;
        return parseMonthDayBody(c);
    }
    const lead = c.peek() orelse return error.Invalid;
    if (lead == '+' or lead == '-') return parseIsoDate(c); // expanded-year full date
    var n: usize = 0;
    while (c.i + n < c.s.len and c.s[c.i + n] >= '0' and c.s[c.i + n] <= '9') : (n += 1) {}
    const dash_follows = c.i + n < c.s.len and c.s[c.i + n] == '-';
    if ((dash_follows and n == 2) or (!dash_follows and n == 4)) {
        return parseMonthDayBody(c);
    }
    return parseIsoDate(c);
}

/// §10.5.x ParseTemporalMonthDayString — the reference year is always
/// 1972 (the ISO leap reference); a year present in a full-date string
/// is used only to validate the day (`parseIsoDate` already did), then
/// discarded. A `Z` UTC designator is rejected.
pub fn parseTemporalMonthDayString(input: []const u8) error{Invalid}!PlainMonthDayRecord {
    var c = Cursor{ .s = input };
    const date = try parseIsoMonthDay(&c);
    if (c.eatAny("Tt ")) {
        _ = try parseIsoTime(&c);
        if (c.eatAny("Zz")) {
            return error.Invalid;
        } else if (c.peek()) |ch| {
            if (ch == '+' or ch == '-') _ = try parseUtcOffsetNs(&c);
        }
    }
    const calendar = try consumeAnnotations(&c);
    if (!c.done()) return error.Invalid;
    const cal_id = try calendarIdFromAnnotation(calendar);
    return .{
        .ref_iso_year = 1972,
        .iso_month = @intCast(date.month),
        .iso_day = @intCast(date.day),
        .calendar = cal_id,
    };
}

// ── Tests ─────────────────────────────────────────────────────────────────

const testing = std.testing;

test "roundToIncrement: exact multiples are unchanged" {
    inline for (.{ RoundingMode.ceil, .floor, .trunc, .expand, .half_even, .half_expand }) |m| {
        try testing.expectEqual(@as(i128, 90), roundToIncrement(90, 30, m));
        try testing.expectEqual(@as(i128, 0), roundToIncrement(0, 7, m));
        try testing.expectEqual(@as(i128, -60), roundToIncrement(-60, 30, m));
    }
}

test "roundToIncrement: directed modes" {
    // value 100, increment 30 → lower 90, upper 120.
    try testing.expectEqual(@as(i128, 120), roundToIncrement(100, 30, .ceil));
    try testing.expectEqual(@as(i128, 90), roundToIncrement(100, 30, .floor));
    try testing.expectEqual(@as(i128, 90), roundToIncrement(100, 30, .trunc));
    try testing.expectEqual(@as(i128, 120), roundToIncrement(100, 30, .expand));
    // value -100, increment 30 → lower -120, upper -90.
    try testing.expectEqual(@as(i128, -90), roundToIncrement(-100, 30, .ceil));
    try testing.expectEqual(@as(i128, -120), roundToIncrement(-100, 30, .floor));
    try testing.expectEqual(@as(i128, -90), roundToIncrement(-100, 30, .trunc));
    try testing.expectEqual(@as(i128, -120), roundToIncrement(-100, 30, .expand));
}

test "roundToIncrement: half modes on an exact tie" {
    // value 15, increment 10 → lower 10, upper 20 (tie).
    try testing.expectEqual(@as(i128, 20), roundToIncrement(15, 10, .half_ceil));
    try testing.expectEqual(@as(i128, 10), roundToIncrement(15, 10, .half_floor));
    try testing.expectEqual(@as(i128, 20), roundToIncrement(15, 10, .half_expand));
    try testing.expectEqual(@as(i128, 10), roundToIncrement(15, 10, .half_trunc));
    try testing.expectEqual(@as(i128, 20), roundToIncrement(15, 10, .half_even)); // 10 is odd multiple → 20
    try testing.expectEqual(@as(i128, 20), roundToIncrement(25, 10, .half_even)); // 20 is even multiple → 20
    // negative tie: value -15, increment 10 → lower -20, upper -10.
    try testing.expectEqual(@as(i128, -10), roundToIncrement(-15, 10, .half_ceil));
    try testing.expectEqual(@as(i128, -20), roundToIncrement(-15, 10, .half_floor));
    try testing.expectEqual(@as(i128, -20), roundToIncrement(-15, 10, .half_expand));
    try testing.expectEqual(@as(i128, -10), roundToIncrement(-15, 10, .half_trunc));
    try testing.expectEqual(@as(i128, -20), roundToIncrement(-15, 10, .half_even));
}

test "roundToIncrement: half modes off a tie pick the nearer multiple" {
    try testing.expectEqual(@as(i128, 10), roundToIncrement(12, 10, .half_expand));
    try testing.expectEqual(@as(i128, 20), roundToIncrement(18, 10, .half_expand));
    try testing.expectEqual(@as(i128, 10), roundToIncrement(12, 10, .half_even));
    try testing.expectEqual(@as(i128, 20), roundToIncrement(18, 10, .half_even));
}

test "roundToIncrement: matches the Instant halfExpand fixture" {
    const ns: i128 = 217175010123987500; // 1976-11-18T14:23:30.1239875Z
    try testing.expectEqual(@as(i128, 217173600000000000), roundToIncrement(ns, 3_600_000_000_000, .half_expand)); // hour
    try testing.expectEqual(@as(i128, 217175040000000000), roundToIncrement(ns, 60_000_000_000, .half_expand)); // minute
    try testing.expectEqual(@as(i128, 217175010000000000), roundToIncrement(ns, 1_000_000_000, .half_expand)); // second
    try testing.expectEqual(@as(i128, 217175010124000000), roundToIncrement(ns, 1_000_000, .half_expand)); // ms
    try testing.expectEqual(@as(i128, 217175010123988000), roundToIncrement(ns, 1_000, .half_expand)); // µs
}

test "balanceTimeDuration: caps at largestUnit, carries sign" {
    {
        const d = balanceTimeDuration(3_600_000_000_000, .hour);
        try testing.expectEqual(@as(f64, 1), d.hours);
        try testing.expectEqual(@as(f64, 0), d.minutes);
    }
    {
        const d = balanceTimeDuration(90 * 60_000_000_000, .hour);
        try testing.expectEqual(@as(f64, 1), d.hours);
        try testing.expectEqual(@as(f64, 30), d.minutes);
    }
    {
        const d = balanceTimeDuration(90 * 60_000_000_000, .minute);
        try testing.expectEqual(@as(f64, 0), d.hours);
        try testing.expectEqual(@as(f64, 90), d.minutes);
    }
    {
        // 366-day span, matching the Instant until minutes-and-hours fixture.
        const total: i128 = @as(i128, 366) * 86400 * 1_000_000_000;
        try testing.expectEqual(@as(f64, 8784), balanceTimeDuration(total, .hour).hours);
        try testing.expectEqual(@as(f64, 527040), balanceTimeDuration(total, .minute).minutes);
    }
    {
        const d = balanceTimeDuration(-(1_000_000_000 + 123_456_789), .second);
        try testing.expectEqual(@as(f64, -1), d.seconds);
        try testing.expectEqual(@as(f64, -123), d.milliseconds);
        try testing.expectEqual(@as(f64, -456), d.microseconds);
        try testing.expectEqual(@as(f64, -789), d.nanoseconds);
    }
}

test "validateRoundingIncrement: round (inclusive) vs difference (exclusive)" {
    try testing.expect(validateRoundingIncrement(24, 24, true)); // round hour: 24 ok
    try testing.expect(validateRoundingIncrement(4, 24, true));
    try testing.expect(!validateRoundingIncrement(7, 24, true)); // 7 ∤ 24
    try testing.expect(!validateRoundingIncrement(24, 24, false)); // until hour: 24 rejected
    try testing.expect(validateRoundingIncrement(12, 24, false));
    try testing.expect(!validateRoundingIncrement(60, 60, false)); // until minute: 60 rejected
    try testing.expect(validateRoundingIncrement(30, 60, false));
    try testing.expect(!validateRoundingIncrement(29, 60, false));
}

test "parseTemporalUnit + parseRoundingMode" {
    try testing.expectEqual(@as(?LargestUnit, .hour), parseTemporalUnit("hour"));
    try testing.expectEqual(@as(?LargestUnit, .hour), parseTemporalUnit("hours"));
    try testing.expectEqual(@as(?LargestUnit, .nanosecond), parseTemporalUnit("nanoseconds"));
    try testing.expectEqual(@as(?LargestUnit, null), parseTemporalUnit("fortnight"));
    try testing.expectEqual(@as(?RoundingMode, .half_expand), parseRoundingMode("halfExpand"));
    try testing.expectEqual(@as(?RoundingMode, .trunc), parseRoundingMode("trunc"));
    try testing.expectEqual(@as(?RoundingMode, null), parseRoundingMode("nearest"));
}

test "roundToIncrementAsIfPositive: directed modes ignore sign" {
    // -65261246399.5 s rounded to the second (matches Instant rounding-direction.js).
    const v: i128 = -65261246399500000000;
    const inc: i128 = 1_000_000_000;
    const down: i128 = -65261246400000000000; // toward -∞
    const up: i128 = -65261246399000000000; // toward +∞
    try testing.expectEqual(down, roundToIncrementAsIfPositive(v, inc, .floor));
    try testing.expectEqual(down, roundToIncrementAsIfPositive(v, inc, .trunc));
    try testing.expectEqual(up, roundToIncrementAsIfPositive(v, inc, .ceil));
    try testing.expectEqual(up, roundToIncrementAsIfPositive(v, inc, .expand));
    try testing.expectEqual(up, roundToIncrementAsIfPositive(v, inc, .half_expand)); // tie → +∞
    // Sign-aware contrast: trunc → toward zero (+∞ side), expand → away (-∞ side).
    try testing.expectEqual(up, roundToIncrement(v, inc, .trunc));
    try testing.expectEqual(down, roundToIncrement(v, inc, .expand));
}

test "time record <-> nanoseconds round trip" {
    const t = PlainTimeRecord{ .hour = 14, .minute = 23, .second = 30, .millisecond = 123, .microsecond = 456, .nanosecond = 789 };
    try testing.expectEqual(@as(i128, 51810123456789), timeRecordToNanoseconds(t));
    const back = nanosecondsToTimeRecord(timeRecordToNanoseconds(t));
    try testing.expectEqual(@as(u32, 14), back.hour);
    try testing.expectEqual(@as(u32, 23), back.minute);
    try testing.expectEqual(@as(u32, 789), back.nanosecond);
    try testing.expectEqual(@as(i128, 0), timeRecordToNanoseconds(.{}));
    try testing.expectEqual(@as(u32, 23), nanosecondsToTimeRecord(86_399_999_999_999).hour);
}

test "dayTimeDurationNanoseconds + hasCalendarUnits" {
    try testing.expect(!hasCalendarUnits(.{ .days = 5, .hours = 1 }));
    try testing.expect(hasCalendarUnits(.{ .years = 1 }));
    try testing.expect(hasCalendarUnits(.{ .weeks = 1 }));
    try testing.expectEqual(@as(i128, 90_000_000_000_000), dayTimeDurationNanoseconds(.{ .days = 1, .hours = 1 }));
    try testing.expectEqual(@as(i128, -86_400_000_000_000), dayTimeDurationNanoseconds(.{ .days = -1 }));
}

test "isValidISODate + isoDateWithinLimits" {
    try testing.expect(isValidISODate(2021, 2, 28));
    try testing.expect(!isValidISODate(2021, 2, 29)); // not a leap year
    try testing.expect(isValidISODate(2004, 2, 29)); // leap
    try testing.expect(!isValidISODate(2021, 13, 1));
    try testing.expect(!isValidISODate(2021, 4, 31));
    try testing.expect(isoDateWithinLimits(-271821, 4, 19));
    try testing.expect(!isoDateWithinLimits(-271821, 4, 18));
    try testing.expect(isoDateWithinLimits(275760, 9, 13));
    try testing.expect(!isoDateWithinLimits(275760, 9, 14));
}

test "isoDayOfWeek + isoDayOfYear + daysInYear" {
    try testing.expectEqual(@as(u8, 4), isoDayOfWeek(1970, 1, 1)); // Thursday
    try testing.expectEqual(@as(u8, 3), isoDayOfWeek(1969, 12, 31)); // Wednesday
    try testing.expectEqual(@as(u16, 1), isoDayOfYear(2020, 1, 1));
    try testing.expectEqual(@as(u16, 366), isoDayOfYear(2020, 12, 31)); // leap
    try testing.expectEqual(@as(u16, 365), isoDayOfYear(2021, 12, 31));
    try testing.expectEqual(@as(u16, 366), isoDaysInYear(2020));
    try testing.expectEqual(@as(u16, 365), isoDaysInYear(2021));
}

test "isoWeekOfYear: boundary weeks (matches weekOfYear/basic.js)" {
    {
        const w = isoWeekOfYear(1975, 12, 29);
        try testing.expectEqual(@as(u16, 1), w.week);
        try testing.expectEqual(@as(i32, 1976), w.year);
    }
    try testing.expectEqual(@as(u16, 1), isoWeekOfYear(1976, 1, 1).week);
    try testing.expectEqual(@as(u16, 2), isoWeekOfYear(1976, 1, 5).week);
    try testing.expectEqual(@as(u16, 52), isoWeekOfYear(1976, 12, 26).week);
    try testing.expectEqual(@as(u16, 53), isoWeekOfYear(1976, 12, 27).week);
    {
        const w = isoWeekOfYear(1977, 1, 2);
        try testing.expectEqual(@as(u16, 53), w.week);
        try testing.expectEqual(@as(i32, 1976), w.year);
    }
}

test "isoDateToString" {
    var buf: [40]u8 = undefined;
    try testing.expectEqualStrings("2000-05-02", isoDateToString(.{ .iso_year = 2000, .iso_month = 5, .iso_day = 2 }, &buf, .auto));
    try testing.expectEqualStrings("2000-05-02[u-ca=iso8601]", isoDateToString(.{ .iso_year = 2000, .iso_month = 5, .iso_day = 2 }, &buf, .always));
    try testing.expectEqualStrings("-009999-01-01", isoDateToString(.{ .iso_year = -9999, .iso_month = 1, .iso_day = 1 }, &buf, .never));
}

test "parseTemporalDateString + regulateISODate" {
    {
        const d = try parseTemporalDateString("2020-12-24");
        try testing.expectEqual(@as(i32, 2020), d.iso_year);
        try testing.expectEqual(@as(u8, 12), d.iso_month);
        try testing.expectEqual(@as(u8, 24), d.iso_day);
    }
    // A bare time component is fine; a UTC designator (`Z`) is not — a
    // PlainDate is time-zone-free, so a UTC point-in-time is ambiguous.
    try testing.expectEqual(@as(u8, 18), (try parseTemporalDateString("1976-11-18T14:23:30")).iso_day);
    try testing.expectError(error.Invalid, parseTemporalDateString("1976-11-18T14:23:30Z"));
    try testing.expectError(error.Invalid, parseTemporalDateString("1976-11-18T14:23:30Z[UTC]"));
    // A `u-ca` calendar annotation must name the ISO calendar.
    try testing.expectEqual(@as(u8, 1), (try parseTemporalDateString("2020-01-01[u-ca=iso8601]")).iso_day);
    try testing.expectError(error.Invalid, parseTemporalDateString("2020-01-01[u-ca=notexist]"));
    try testing.expectError(error.Invalid, parseTemporalDateString("2021-02-29"));
    try testing.expectError(error.Invalid, parseTemporalDateString("2020-13-01"));
    try testing.expect(regulateISODate(2021, 2, 29, true) == null);
    try testing.expectEqual(@as(u8, 28), regulateISODate(2021, 2, 29, false).?.iso_day);
    try testing.expectEqual(@as(u8, 12), regulateISODate(2021, 20, 1, false).?.iso_month);
    // Non-positive month/day reject even under constrain.
    try testing.expect(regulateISODate(2000, -1, 1, false) == null);
    try testing.expect(regulateISODate(2000, 0, 1, false) == null);
    try testing.expect(regulateISODate(2000, 1, -1, false) == null);
    try testing.expect(regulateISODate(2000, 1, 0, false) == null);
    try testing.expect(regulateISODate(1_000_000_000, 1, 1, true) == null);
}

test "balanceISOYearMonth" {
    try testing.expectEqual(@as(i64, 1977), balanceISOYearMonth(1976, 14).year);
    try testing.expectEqual(@as(i64, 2), balanceISOYearMonth(1976, 14).month);
    try testing.expectEqual(@as(i64, 1975), balanceISOYearMonth(1976, 0).year);
    try testing.expectEqual(@as(i64, 12), balanceISOYearMonth(1976, 0).month);
    try testing.expectEqual(@as(i64, 1976), balanceISOYearMonth(1976, 6).year);
    try testing.expectEqual(@as(i64, 6), balanceISOYearMonth(1976, 6).month);
}

test "addISODate" {
    const base: PlainDateRecord = .{ .iso_year = 1976, .iso_month = 11, .iso_day = 18 };
    // +43 years: only the year moves (basic.js).
    {
        const r = addISODate(base, 43, 0, 0, 0, false).?;
        try testing.expectEqual(@as(i32, 2019), r.iso_year);
        try testing.expectEqual(@as(u8, 11), r.iso_month);
        try testing.expectEqual(@as(u8, 18), r.iso_day);
    }
    // +3 months wraps the year (Nov → Feb next year).
    {
        const r = addISODate(base, 0, 3, 0, 0, false).?;
        try testing.expectEqual(@as(i32, 1977), r.iso_year);
        try testing.expectEqual(@as(u8, 2), r.iso_month);
    }
    // +20 days balances into the next month.
    {
        const r = addISODate(base, 0, 0, 0, 20, false).?;
        try testing.expectEqual(@as(u8, 12), r.iso_month);
        try testing.expectEqual(@as(u8, 8), r.iso_day);
    }
    // +1 week.
    try testing.expectEqual(@as(u8, 25), addISODate(base, 0, 0, 1, 0, false).?.iso_day);
    // Jan 31 + 1 month: constrain clamps the day to Feb 28; reject → null.
    {
        const jan31: PlainDateRecord = .{ .iso_year = 2019, .iso_month = 1, .iso_day = 31 };
        try testing.expectEqual(@as(u8, 28), addISODate(jan31, 0, 1, 0, 0, false).?.iso_day);
        try testing.expect(addISODate(jan31, 0, 1, 0, 0, true) == null);
    }
    // Negative months symmetric (Feb 28 − 1 month → Jan 28).
    {
        const feb: PlainDateRecord = .{ .iso_year = 2019, .iso_month = 2, .iso_day = 28 };
        const r = addISODate(feb, 0, -1, 0, 0, false).?;
        try testing.expectEqual(@as(u8, 1), r.iso_month);
        try testing.expectEqual(@as(u8, 28), r.iso_day);
    }
    // Leap-day clamp: 2020-02-29 + 1 year → 2021-02-28.
    {
        const leap: PlainDateRecord = .{ .iso_year = 2020, .iso_month = 2, .iso_day = 29 };
        const r = addISODate(leap, 1, 0, 0, 0, false).?;
        try testing.expectEqual(@as(i32, 2021), r.iso_year);
        try testing.expectEqual(@as(u8, 28), r.iso_day);
    }
    // Out of range → null.
    try testing.expect(addISODate(base, 1_000_000, 0, 0, 0, false) == null);
}

test "differenceISODate" {
    const mk = struct {
        fn f(y: i32, m: u8, dd: u8) PlainDateRecord {
            return .{ .iso_year = y, .iso_month = m, .iso_day = dd };
        }
    }.f;
    // largestUnit=year: 1997-12-01 → 2001-06-18 = 3y 6m 17d (until/basic.js).
    {
        const r = differenceISODate(mk(1997, 12, 1), mk(2001, 6, 18), .year);
        try testing.expectEqual(@as(f64, 3), r.years);
        try testing.expectEqual(@as(f64, 6), r.months);
        try testing.expectEqual(@as(f64, 0), r.weeks);
        try testing.expectEqual(@as(f64, 17), r.days);
    }
    // largestUnit=month: 2000-12-01 → 2001-06-01 = 6 months.
    {
        const r = differenceISODate(mk(2000, 12, 1), mk(2001, 6, 1), .month);
        try testing.expectEqual(@as(f64, 0), r.years);
        try testing.expectEqual(@as(f64, 6), r.months);
        try testing.expectEqual(@as(f64, 0), r.days);
    }
    // week/day: 2000-01-01 → 2000-10-07 = 40w / 280d.
    {
        const w = differenceISODate(mk(2000, 1, 1), mk(2000, 10, 7), .week);
        try testing.expectEqual(@as(f64, 40), w.weeks);
        try testing.expectEqual(@as(f64, 0), w.days);
        const d = differenceISODate(mk(2000, 1, 1), mk(2000, 10, 7), .day);
        try testing.expectEqual(@as(f64, 280), d.days);
    }
    // weeks/months don't mix (weeks-months.js): 1969-07-24 → 1969-09-04.
    {
        const w = differenceISODate(mk(1969, 7, 24), mk(1969, 9, 4), .week);
        try testing.expectEqual(@as(f64, 6), w.weeks);
        try testing.expectEqual(@as(f64, 0), w.days);
        const mo = differenceISODate(mk(1969, 7, 24), mk(1969, 9, 4), .month);
        try testing.expectEqual(@as(f64, 1), mo.months);
        try testing.expectEqual(@as(f64, 11), mo.days);
    }
    // Jan-31 +1mo constrains to Feb-29: 2020-01-31 → 2020-03-01 = 1m 1d.
    {
        const r = differenceISODate(mk(2020, 1, 31), mk(2020, 3, 1), .month);
        try testing.expectEqual(@as(f64, 1), r.months);
        try testing.expectEqual(@as(f64, 1), r.days);
    }
    // Negative direction mirrors.
    {
        const d = differenceISODate(mk(1969, 10, 5), mk(1969, 7, 24), .day);
        try testing.expectEqual(@as(f64, -73), d.days);
        const big = differenceISODate(mk(1996, 3, 3), mk(1969, 7, 24), .day);
        try testing.expectEqual(@as(f64, -9719), big.days);
        const y = differenceISODate(mk(2001, 6, 18), mk(1997, 12, 1), .year);
        try testing.expectEqual(@as(f64, -3), y.years);
        try testing.expectEqual(@as(f64, -6), y.months);
        try testing.expectEqual(@as(f64, -17), y.days);
    }
    // Equal dates → zero.
    {
        const r = differenceISODate(mk(2020, 5, 5), mk(2020, 5, 5), .year);
        try testing.expectEqual(@as(f64, 0), r.years);
        try testing.expectEqual(@as(f64, 0), r.days);
    }
}

test "roundRelativeDate: calendar-unit rounding (until/since fixtures)" {
    const mk = struct {
        fn f(y: i32, m: u8, dd: u8) PlainDateRecord {
            return .{ .iso_year = y, .iso_month = m, .iso_day = dd };
        }
    }.f;
    // Round start→dest under (smallest, increment, mode), capped at largest,
    // and assert the {years, months, weeks, days} of the rounded duration.
    const check = struct {
        fn f(
            start: PlainDateRecord,
            dest: PlainDateRecord,
            smallest: LargestUnit,
            increment: i128,
            mode: RoundingMode,
            largest: LargestUnit,
            ey: f64,
            em: f64,
            ew: f64,
            ed: f64,
        ) !void {
            const diff = differenceISODate(start, dest, largest);
            const r = roundRelativeDate(start, dest, diff, smallest, increment, mode, largest).?;
            try testing.expectEqual(ey, r.years);
            try testing.expectEqual(em, r.months);
            try testing.expectEqual(ew, r.weeks);
            try testing.expectEqual(ed, r.days);
        }
    }.f;

    // roundingmode-ceil.js: 2019-01-08 → 2021-09-07 (1y/31m/139w/973d raw).
    try check(mk(2019, 1, 8), mk(2021, 9, 7), .year, 1, .ceil, .year, 3, 0, 0, 0);
    try check(mk(2019, 1, 8), mk(2021, 9, 7), .month, 1, .ceil, .month, 0, 32, 0, 0);
    try check(mk(2019, 1, 8), mk(2021, 9, 7), .week, 1, .ceil, .week, 0, 0, 139, 0);
    // reverse direction (later → earlier): ceil rounds toward zero.
    try check(mk(2021, 9, 7), mk(2019, 1, 8), .year, 1, .ceil, .year, -2, 0, 0, 0);
    try check(mk(2021, 9, 7), mk(2019, 1, 8), .month, 1, .ceil, .month, 0, -31, 0, 0);
    try check(mk(2021, 9, 7), mk(2019, 1, 8), .week, 1, .ceil, .week, 0, 0, -139, 0);

    // roundingincrement.js: same dates, halfExpand with various increments.
    try check(mk(2019, 1, 8), mk(2021, 9, 7), .year, 4, .half_expand, .year, 4, 0, 0, 0);
    try check(mk(2019, 1, 8), mk(2021, 9, 7), .month, 10, .half_expand, .month, 0, 30, 0, 0);
    try check(mk(2019, 1, 8), mk(2021, 9, 7), .week, 12, .half_expand, .week, 0, 0, 144, 0);

    // round-cross-unit-boundary.js: largestUnit=year bubbles 1y 12m → 2y.
    try check(mk(2022, 1, 1), mk(2023, 12, 25), .month, 1, .expand, .year, 2, 0, 0, 0);

    // rounding-relative.js: half ties decided by the day fraction.
    try check(mk(2019, 1, 1), mk(2019, 2, 15), .month, 1, .half_expand, .month, 0, 2, 0, 0); // 14/28 = 0.5 → up
    try check(mk(2019, 2, 15), mk(2019, 1, 1), .month, 1, .half_expand, .month, 0, -1, 0, 0); // 14/31 < 0.5 → toward zero
}

test "durationSign: first non-zero field decides" {
    try testing.expectEqual(@as(i32, 0), durationSign(.{}));
    try testing.expectEqual(@as(i32, 1), durationSign(.{ .nanoseconds = 1 }));
    try testing.expectEqual(@as(i32, -1), durationSign(.{ .years = -1, .months = 0 }));
    try testing.expectEqual(@as(i32, 1), durationSign(.{ .years = 1 }));
}

test "isValidDuration: mixed sign rejected" {
    try testing.expect(isValidDuration(.{ .years = 1, .months = 2 }));
    try testing.expect(!isValidDuration(.{ .years = -1, .months = 1 }));
    try testing.expect(isValidDuration(.{ .years = -1, .months = -2 }));
    try testing.expect(isValidDuration(.{})); // all-zero is valid (blank)
}

test "isValidDuration: 2^32 magnitude limit on y/m/w" {
    try testing.expect(isValidDuration(.{ .years = 4294967295 }));
    try testing.expect(!isValidDuration(.{ .years = 4294967296 }));
    try testing.expect(!isValidDuration(.{ .months = 4294967296 }));
    try testing.expect(!isValidDuration(.{ .weeks = -4294967296 }));
}

test "isValidDuration: seconds safe-integer balancing limit" {
    // From test262 out-of-range.js: these exact boundaries.
    try testing.expect(!isValidDuration(.{ .days = 104249991375 }));
    try testing.expect(isValidDuration(.{ .days = 104249991374, .hours = 7, .minutes = 36, .seconds = 31, .milliseconds = 999, .microseconds = 999, .nanoseconds = 999 }));
    try testing.expect(!isValidDuration(.{ .seconds = 9007199254740992 }));
    try testing.expect(isValidDuration(.{ .seconds = 9007199254740991, .milliseconds = 999, .microseconds = 999, .nanoseconds = 999 }));
    // ms balance into seconds > max.
    try testing.expect(!isValidDuration(.{ .seconds = 9007199254740991, .milliseconds = 1000 }));
}

test "temporalDurationToString: basic forms" {
    var buf: [128]u8 = undefined;
    try testing.expectEqualStrings("PT0S", temporalDurationToString(.{}, &buf, .auto));
    try testing.expectEqualStrings("P1Y", temporalDurationToString(.{ .years = 1 }, &buf, .auto));
    try testing.expectEqualStrings("-P1Y", temporalDurationToString(.{ .years = -1 }, &buf, .auto));
    try testing.expectEqualStrings("P1Y2M3W4D", temporalDurationToString(.{ .years = 1, .months = 2, .weeks = 3, .days = 4 }, &buf, .auto));
    try testing.expectEqualStrings("PT5H", temporalDurationToString(.{ .hours = 5 }, &buf, .auto));
    try testing.expectEqualStrings("PT6M", temporalDurationToString(.{ .minutes = 6 }, &buf, .auto));
    try testing.expectEqualStrings("PT7S", temporalDurationToString(.{ .seconds = 7 }, &buf, .auto));
}

test "temporalDurationToString: sub-second balancing" {
    var buf: [128]u8 = undefined;
    try testing.expectEqualStrings("PT0.008S", temporalDurationToString(.{ .milliseconds = 8 }, &buf, .auto));
    try testing.expectEqualStrings("PT0.000009S", temporalDurationToString(.{ .microseconds = 9 }, &buf, .auto));
    try testing.expectEqualStrings("PT0.000000001S", temporalDurationToString(.{ .nanoseconds = 1 }, &buf, .auto));
    try testing.expectEqualStrings("PT4.003002001S", temporalDurationToString(.{ .seconds = 4, .milliseconds = 3, .microseconds = 2, .nanoseconds = 1 }, &buf, .auto));
    // 999 ms + 999999 µs + 999999999 ns balances to 2.998998999 s.
    try testing.expectEqualStrings("PT2.998998999S", temporalDurationToString(.{ .milliseconds = 999, .microseconds = 999999, .nanoseconds = 999999999 }, &buf, .auto));
    try testing.expectEqualStrings("-PT2.998998999S", temporalDurationToString(.{ .milliseconds = -999, .microseconds = -999999, .nanoseconds = -999999999 }, &buf, .auto));
    // All fields large.
    try testing.expectEqualStrings(
        "P1234Y2345M3456W4567DT5678H6789M7890.890901123S",
        temporalDurationToString(.{ .years = 1234, .months = 2345, .weeks = 3456, .days = 4567, .hours = 5678, .minutes = 6789, .seconds = 7890, .milliseconds = 890, .microseconds = 901, .nanoseconds = 123 }, &buf, .auto),
    );
}

test "parseTemporalDurationString: basic" {
    const a = try parseTemporalDurationString("P1D");
    try testing.expectEqual(@as(f64, 1), a.days);
    const b = try parseTemporalDurationString("P1Y1M1W1DT1H1M1.123456789S");
    try testing.expectEqual(@as(f64, 1), b.years);
    try testing.expectEqual(@as(f64, 1), b.seconds);
    try testing.expectEqual(@as(f64, 123), b.milliseconds);
    try testing.expectEqual(@as(f64, 456), b.microseconds);
    try testing.expectEqual(@as(f64, 789), b.nanoseconds);
}

test "parseTemporalDurationString: case-insensitive and signs" {
    const a = try parseTemporalDurationString("p1y1m1dt1h1m1s");
    try testing.expectEqual(@as(f64, 1), a.years);
    try testing.expectEqual(@as(f64, 1), a.months);
    try testing.expectEqual(@as(f64, 0), a.weeks);
    try testing.expectEqual(@as(f64, 1), a.days);
    const neg = try parseTemporalDurationString("-P1D");
    try testing.expectEqual(@as(f64, -1), neg.days);
    const plus = try parseTemporalDurationString("+P1D");
    try testing.expectEqual(@as(f64, 1), plus.days);
}

test "parseTemporalDurationString: fractional unit balancing" {
    // "P1DT0.5M" => 30 seconds (half a minute).
    const a = try parseTemporalDurationString("P1DT0.5M");
    try testing.expectEqual(@as(f64, 1), a.days);
    try testing.expectEqual(@as(f64, 30), a.seconds);
    try testing.expectEqual(@as(f64, 0), a.minutes);
    // "P1DT0,5H" => 30 minutes.
    const b = try parseTemporalDurationString("P1DT0,5H");
    try testing.expectEqual(@as(f64, 30), b.minutes);
    try testing.expectEqual(@as(f64, 0), b.seconds);
    // comma decimal separator.
    const c = try parseTemporalDurationString("P1Y1M1W1DT1H1M1,12S");
    try testing.expectEqual(@as(f64, 120), c.milliseconds);
}

test "parseTemporalDurationString: invalid forms" {
    try testing.expectError(error.Invalid, parseTemporalDurationString("P"));
    try testing.expectError(error.Invalid, parseTemporalDurationString("+P"));
    try testing.expectError(error.Invalid, parseTemporalDurationString("PT"));
    try testing.expectError(error.Invalid, parseTemporalDurationString("1D"));
    try testing.expectError(error.Invalid, parseTemporalDurationString("P1H")); // hours need T
    try testing.expectError(error.Invalid, parseTemporalDurationString("P1DT1.5H1M")); // fractional not smallest
    try testing.expectError(error.Invalid, parseTemporalDurationString("P1Dgarbage"));
}

test "isValidTime + compareTime" {
    try testing.expect(isValidTime(.{ .hour = 23, .minute = 59, .second = 59, .millisecond = 999, .microsecond = 999, .nanosecond = 999 }));
    try testing.expect(!isValidTime(.{ .hour = 24 }));
    try testing.expect(!isValidTime(.{ .minute = 60 }));
    try testing.expectEqual(@as(i32, 0), compareTime(.{ .hour = 1 }, .{ .hour = 1 }));
    try testing.expectEqual(@as(i32, -1), compareTime(.{ .hour = 1 }, .{ .hour = 2 }));
    try testing.expectEqual(@as(i32, 1), compareTime(.{ .second = 5 }, .{ .second = 4 }));
}

test "plainTimeToString: forms" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("00:00:00", plainTimeToString(.{}, &buf, .auto));
    try testing.expectEqualStrings("15:23:30.123456789", plainTimeToString(.{ .hour = 15, .minute = 23, .second = 30, .millisecond = 123, .microsecond = 456, .nanosecond = 789 }, &buf, .auto));
    try testing.expectEqualStrings("01:02:03", plainTimeToString(.{ .hour = 1, .minute = 2, .second = 3 }, &buf, .auto));
    try testing.expectEqualStrings("12:00:00.5", plainTimeToString(.{ .hour = 12, .millisecond = 500 }, &buf, .auto));
    // Precision knobs: minute stops at HH:MM; fixed digits pad/truncate.
    try testing.expectEqualStrings("15:23", plainTimeToString(.{ .hour = 15, .minute = 23, .second = 30 }, &buf, .minute));
    try testing.expectEqualStrings("12:00:00.500", plainTimeToString(.{ .hour = 12, .millisecond = 500 }, &buf, .{ .digits = 3 }));
    try testing.expectEqualStrings("12:00:00", plainTimeToString(.{ .hour = 12, .millisecond = 500 }, &buf, .{ .digits = 0 }));
}

test "parseTemporalTimeString: bare time forms" {
    const a = try parseTemporalTimeString("12:34:56");
    try testing.expectEqual(@as(u32, 12), a.hour);
    try testing.expectEqual(@as(u32, 34), a.minute);
    try testing.expectEqual(@as(u32, 56), a.second);
    const b = try parseTemporalTimeString("12:34:56.987654321");
    try testing.expectEqual(@as(u32, 987), b.millisecond);
    try testing.expectEqual(@as(u32, 654), b.microsecond);
    try testing.expectEqual(@as(u32, 321), b.nanosecond);
    const c = try parseTemporalTimeString("12:34");
    try testing.expectEqual(@as(u32, 34), c.minute);
    try testing.expectEqual(@as(u32, 0), c.second);
    const d = try parseTemporalTimeString("T12:34:56");
    try testing.expectEqual(@as(u32, 12), d.hour);
}

test "parseTemporalTimeString: date-time prefix" {
    const a = try parseTemporalTimeString("1976-11-18T12:34:56.987654321");
    try testing.expectEqual(@as(u32, 12), a.hour);
    try testing.expectEqual(@as(u32, 987), a.millisecond);
    const b = try parseTemporalTimeString("1976-11-18 12:34:56");
    try testing.expectEqual(@as(u32, 56), b.second);
    const c = try parseTemporalTimeString("1976-11-18t12:34");
    try testing.expectEqual(@as(u32, 34), c.minute);
}

test "parseTemporalTimeString: offset + annotations discarded" {
    const a = try parseTemporalTimeString("12:34:56.987654321+00:00");
    try testing.expectEqual(@as(u32, 12), a.hour);
    try testing.expectEqual(@as(u32, 987), a.millisecond);
    const b = try parseTemporalTimeString("12:34:56.987654321+00:00[America/Sao_Paulo]");
    try testing.expectEqual(@as(u32, 56), b.second);
    const c = try parseTemporalTimeString("12:34:56.987654321[Asia/Kolkata]");
    try testing.expectEqual(@as(u32, 34), c.minute);
    const d = try parseTemporalTimeString("12:34:56-02:30[America/St_Johns]");
    try testing.expectEqual(@as(u32, 12), d.hour);
    const e = try parseTemporalTimeString("T12:34:56[!Africa/Abidjan]");
    try testing.expectEqual(@as(u32, 56), e.second);
}

test "parseTemporalTimeString: malformed annotations rejected (RFC 9557)" {
    // The trailing `[...]` blocks must satisfy the RFC 9557 grammar — a
    // bare strip-and-discard accepted these. Each is a RangeError source
    // in ToTemporalTime / the *ISO conversions (e.g. withPlainTime).
    // More than one time-zone annotation.
    try testing.expectError(error.Invalid, parseTemporalTimeString("00:00[UTC][UTC]"));
    try testing.expectError(error.Invalid, parseTemporalTimeString("00:00[!UTC][UTC]"));
    // A time-zone annotation must precede any key=value annotation.
    try testing.expectError(error.Invalid, parseTemporalTimeString("00:00[foo=bar][UTC]"));
    // Annotation keys are lowercase only.
    try testing.expectError(error.Invalid, parseTemporalTimeString("00:00[U-CA=iso8601]"));
    // Unknown annotation carrying the critical `!` flag.
    try testing.expectError(error.Invalid, parseTemporalTimeString("00:00[!foo=bar]"));
    // Two calendar annotations are only syntactical if neither is critical.
    try testing.expectError(error.Invalid, parseTemporalTimeString("00:00[u-ca=iso8601][!u-ca=iso8601]"));
    // Empty annotation / unterminated bracket / trailing junk.
    try testing.expectError(error.Invalid, parseTemporalTimeString("00:00[]"));
    try testing.expectError(error.Invalid, parseTemporalTimeString("00:00[UTC"));
    try testing.expectError(error.Invalid, parseTemporalTimeString("00:00[UTC]junk"));
    // Valid multi-annotation forms still parse (tz then calendar).
    const a = try parseTemporalTimeString("00:00[UTC][u-ca=iso8601]");
    try testing.expectEqual(@as(u32, 0), a.hour);
    const b = try parseTemporalTimeString("00:00[u-ca=iso8601][u-ca=iso8601]");
    try testing.expectEqual(@as(u32, 0), b.minute);
}

test "parseTemporalTimeString: leap second clamps to 59" {
    const a = try parseTemporalTimeString("2016-12-31T23:59:60");
    try testing.expectEqual(@as(u32, 23), a.hour);
    try testing.expectEqual(@as(u32, 59), a.minute);
    try testing.expectEqual(@as(u32, 59), a.second);
}

test "parseTemporalTimeString: Z designator rejected" {
    try testing.expectError(error.UTCDesignator, parseTemporalTimeString("09:00:00Z"));
    try testing.expectError(error.UTCDesignator, parseTemporalTimeString("2019-10-01T09:00:00Z"));
    try testing.expectError(error.UTCDesignator, parseTemporalTimeString("09:00:00Z[UTC]"));
}

test "parseTemporalTimeString: invalid" {
    try testing.expectError(error.Invalid, parseTemporalTimeString(""));
    try testing.expectError(error.Invalid, parseTemporalTimeString("24:00:00"));
    try testing.expectError(error.Invalid, parseTemporalTimeString("12:60:00"));
    try testing.expectError(error.Invalid, parseTemporalTimeString("garbage"));
    // Date-only (no time component) is invalid for a PlainTime.
    try testing.expectError(error.Invalid, parseTemporalTimeString("2022-09-15"));
    try testing.expectError(error.Invalid, parseTemporalTimeString("2022-09-15+00:00"));
}

test "parseTemporalTimeString: malformed offset / trailing junk rejected" {
    try testing.expectError(error.Invalid, parseTemporalTimeString("00:00:00+00:00junk"));
    try testing.expectError(error.Invalid, parseTemporalTimeString("00:00-24:00"));
    try testing.expectError(error.Invalid, parseTemporalTimeString("00:00+24:00"));
    try testing.expectError(error.Invalid, parseTemporalTimeString("00:00:00+00:0000"));
    try testing.expectError(error.Invalid, parseTemporalTimeString("0000:00"));
    try testing.expectError(error.Invalid, parseTemporalTimeString("00:0000"));
    try testing.expectError(error.Invalid, parseTemporalTimeString("00:00:00+0000:00"));
    // Valid offsets still parse (offset discarded).
    const a = try parseTemporalTimeString("12:34:56+00");
    try testing.expectEqual(@as(u32, 56), a.second);
    const b = try parseTemporalTimeString("12:34:56-0230");
    try testing.expectEqual(@as(u32, 34), b.minute);
    const c = try parseTemporalTimeString("12:34:56+00:00:00.000000000");
    try testing.expectEqual(@as(u32, 12), c.hour);
}

test "parseTemporalTimeString: compact-form date/time disambiguation" {
    // Ambiguous (could be a valid MMDD / YYYYMM) — rejected without T.
    try testing.expectError(error.Invalid, parseTemporalTimeString("1214")); // Dec 14
    try testing.expectError(error.Invalid, parseTemporalTimeString("0229")); // Feb 29
    try testing.expectError(error.Invalid, parseTemporalTimeString("1130")); // Nov 30
    try testing.expectError(error.Invalid, parseTemporalTimeString("202112")); // 2021-12
    // Unambiguous (cannot be a valid date) — accepted as a time.
    const a = try parseTemporalTimeString("1314"); // 13 is not a month
    try testing.expectEqual(@as(u32, 13), a.hour);
    try testing.expectEqual(@as(u32, 14), a.minute);
    const b = try parseTemporalTimeString("1232"); // 32 not a day
    try testing.expectEqual(@as(u32, 12), b.hour);
    try testing.expectEqual(@as(u32, 32), b.minute); // wait: 32 > 59? no, minute=32 ok
    const c = try parseTemporalTimeString("0230"); // Feb 30 invalid date
    try testing.expectEqual(@as(u32, 2), c.hour);
    try testing.expectEqual(@as(u32, 30), c.minute);
    const d = try parseTemporalTimeString("202113"); // month 13 invalid
    try testing.expectEqual(@as(u32, 20), d.hour);
    try testing.expectEqual(@as(u32, 21), d.minute);
    try testing.expectEqual(@as(u32, 13), d.second);
    // A `T` designator disambiguates a compact form as a time.
    const e = try parseTemporalTimeString("T1214");
    try testing.expectEqual(@as(u32, 12), e.hour);
    try testing.expectEqual(@as(u32, 14), e.minute);
}

test "parseTemporalTimeString: extended-form date/time disambiguation" {
    // Dashed `YYYY-MM` (DateSpecYearMonth) and `MM-DD`
    // (DateSpecMonthDay) are ambiguous with a date spec — the `-MM` /
    // `-DD` tail would otherwise be mis-read as a UTC offset, parsing
    // the prefix as a compact time. Rejected unless a `T` forces it.
    try testing.expectError(error.Invalid, parseTemporalTimeString("2021-12")); // YYYY-MM
    try testing.expectError(error.Invalid, parseTemporalTimeString("12-14")); // Dec 14 (MM-DD)
    // Annotation variants reduce to the bare ambiguous form once the
    // `[…]` block is stripped.
    try testing.expectError(error.Invalid, parseTemporalTimeString("2021-12[-12:00]"));
    try testing.expectError(error.Invalid, parseTemporalTimeString("12-14[-14:00]"));
    try testing.expectError(error.Invalid, parseTemporalTimeString("2021-12[u-ca=iso8601]"));
    // Unambiguous extended forms (month / day out of range) stay times.
    const a = try parseTemporalTimeString("2021-13"); // month 13 invalid → 20:21
    try testing.expectEqual(@as(u32, 20), a.hour);
    try testing.expectEqual(@as(u32, 21), a.minute);
    const b = try parseTemporalTimeString("13-14"); // month 13 invalid → 13:00
    try testing.expectEqual(@as(u32, 13), b.hour);
    const c = try parseTemporalTimeString("0000-00"); // month 00 invalid → 00:00
    try testing.expectEqual(@as(u32, 0), c.hour);
    try testing.expectEqual(@as(u32, 0), c.minute);
    // A `T` designator forces the time reading of a dashed form.
    const d = try parseTemporalTimeString("T2021-13");
    try testing.expectEqual(@as(u32, 20), d.hour);
}

test "parseTemporalTimeString: negative-zero expanded year rejected" {
    try testing.expectError(error.Invalid, parseTemporalTimeString("-000000-12-07T03:24:30"));
    try testing.expectError(error.Invalid, parseTemporalTimeString("-000000-12-07T03:24:30+01:00"));
    // A positive expanded year date-time is fine.
    const a = try parseTemporalTimeString("+000000-12-07T03:24:30");
    try testing.expectEqual(@as(u32, 3), a.hour);
}

test "parseTemporalTimeString: Z designator (trailing) rejected as UTC" {
    // Pure-Z forms map to UTCDesignator; mid-string Z (junk) is
    // plain Invalid.
    try testing.expectError(error.UTCDesignator, parseTemporalTimeString("00:00:00Z"));
    try testing.expectError(error.Invalid, parseTemporalTimeString("00:00:00Zjunk"));
    try testing.expectError(error.Invalid, parseTemporalTimeString("00:00Zjunk"));
}

test "isValidEpochNanoseconds: inclusive bounds" {
    try testing.expect(isValidEpochNanoseconds(0));
    try testing.expect(isValidEpochNanoseconds(ns_max_instant));
    try testing.expect(isValidEpochNanoseconds(ns_min_instant));
    try testing.expect(!isValidEpochNanoseconds(ns_max_instant + 1));
    try testing.expect(!isValidEpochNanoseconds(ns_min_instant - 1));
}

test "civil-date round trip" {
    try testing.expectEqual(@as(i64, 0), daysFromCivil(1970, 1, 1));
    try testing.expectEqual(@as(i64, -1), daysFromCivil(1969, 12, 31));
    const r = civilFromDays(2513);
    try testing.expectEqual(@as(i64, 1976), r.year);
    try testing.expectEqual(@as(u32, 11), r.month);
    try testing.expectEqual(@as(u32, 18), r.day);
    var d: i64 = -2_000_000;
    while (d < 2_000_000) : (d += 7919) {
        const ymd = civilFromDays(d);
        try testing.expectEqual(d, daysFromCivil(ymd.year, ymd.month, ymd.day));
    }
}

test "instantToString: UTC forms with trimmed fraction" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("1970-01-01T00:00:00Z", instantToString(0, &buf, .auto, null));
    try testing.expectEqualStrings("1976-11-18T14:23:30.123456789Z", instantToString(217175010123456789, &buf, .auto, null));
    try testing.expectEqualStrings("1963-02-13T09:36:29.123456789Z", instantToString(-217175010876543211, &buf, .auto, null));
    // With a fixed-offset time zone: that zone's wall clock + `±HH:MM`.
    try testing.expectEqualStrings("1970-01-01T05:30:00+05:30", instantToString(0, &buf, .auto, .{ .offset_minutes = 330 }));
    try testing.expectEqualStrings("1970-01-01T00:00:00+00:00", instantToString(0, &buf, .auto, .utc));
    // Explicit precision digits truncate the fraction.
    try testing.expectEqualStrings("1976-11-18T14:23:30.123Z", instantToString(217175010123456789, &buf, .{ .digits = 3 }, null));
    try testing.expectEqualStrings("1976-11-18T14:23Z", instantToString(217175010123456789, &buf, .minute, null));
}

test "compareInstant" {
    try testing.expectEqual(@as(i32, 0), compareInstant(5, 5));
    try testing.expectEqual(@as(i32, -1), compareInstant(-1, 1));
    try testing.expectEqual(@as(i32, 1), compareInstant(2, -2));
}

test "timeDurationNanoseconds" {
    try testing.expectEqual(@as(i128, 3_600_000_000_000), timeDurationNanoseconds(.{ .hours = 1 }));
    try testing.expectEqual(@as(i128, -1_000_000_000), timeDurationNanoseconds(.{ .seconds = -1 }));
    try testing.expectEqual(@as(i128, 1_001_001_001), timeDurationNanoseconds(.{ .seconds = 1, .milliseconds = 1, .microseconds = 1, .nanoseconds = 1 }));
}

test "parseInstantString: valid forms fold the offset" {
    try testing.expectEqual(@as(i128, 0), try parseInstantString("1970-01-01T00:00Z"));
    try testing.expectEqual(@as(i128, 0), try parseInstantString("1970-01-01T00Z"));
    try testing.expectEqual(@as(i128, 0), try parseInstantString("1970-01-01T00+00:00"));
    try testing.expectEqual(@as(i128, 0), try parseInstantString("1969-12-31T16-08[America/Vancouver]"));
    try testing.expectEqual(@as(i128, 0), try parseInstantString("1970-01-01T00:00:00+00:00[UTC][u-ca=iso8601]"));
    try testing.expectEqual(@as(i128, 217175010123456789), try parseInstantString("1976-11-18T14:23:30.123456789Z"));
    // Range edges (inclusive).
    try testing.expectEqual(ns_min_instant, try parseInstantString("-271821-04-20T00:00Z"));
    try testing.expectEqual(ns_max_instant, try parseInstantString("+275760-09-13T00:00Z"));
    try testing.expectEqual(ns_min_instant, try parseInstantString("-271821-04-19T23:00-01:00"));
}

test "parseInstantString: invalid forms reject" {
    const bad = [_][]const u8{
        "",                              "invalid iso8601",
        "2020-01-00T00:00Z",             "2020-01-32T00:00Z",
        "2020-02-30T00:00Z",             "2021-02-29T00:00Z",
        "2020-00-01T00:00Z",             "2020-13-01T00:00Z",
        "2020-01-01TZ",                  "2020-01-01T25:00:00Z",
        "2020-01-01T01:60:00Z",          "2020-01-01T00:00Zjunk",
        "2020-01-01T00:00:00+00:00junk", "2020-01-01T00:00:00+00:00[UTC]junk",
        "02020-01-01T00:00Z",            "2020-001-01T00:00Z",
        "2020-01-001T00:00Z",            "2020-01-01T001Z",
        "2020-01-01T00:00-24:00",        "2020-01-01T00:00+24:00",
        "2020-W01-1T00:00Z",             "2020-001T00:00Z",
        "+0002020-01-01T00:00Z",         "2020-01",
        "01-01",                         "P1Y",
        "2020-01-01",                    "2020-01-01T00",
        "2020-01-01T00:00",              "2020-01-01T00:00:00",
        "2020-01-01T00:00:00.000000000", "-999999-01-01T00:00Z",
        "+999999-01-01T00:00Z",          "2025-01-01T00:00:00+00:0000",
        "2022-09-15Z",                   "2022-09-15+00:00",
    };
    for (bad) |s| {
        try testing.expectError(error.Invalid, parseInstantString(s));
    }
}

test "parseInstantString: non-ASCII minus sign rejected" {
    try testing.expectError(error.Invalid, parseInstantString("1976-11-18T15:23:30.12\u{2212}02:00"));
    try testing.expectError(error.Invalid, parseInstantString("\u{2212}009999-11-18T15:23:30.12Z"));
}

test "parseInstantString: annotations + expanded basic year accepted" {
    // Two non-critical calendar annotations are allowed (first wins,
    // rest ignored); numeric-offset and IANA-style time-zone
    // annotations are accepted and discarded.
    try testing.expectEqual(@as(i128, 0), try parseInstantString("1970-01-01T00:00Z[u-ca=iso8601][u-ca=discord]"));
    try testing.expectEqual(@as(i128, 0), try parseInstantString("1970-01-01T00:00Z[+00]"));
    try testing.expectEqual(@as(i128, 0), try parseInstantString("1970-01-01T00:00Z[-00:00]"));
    try testing.expectEqual(@as(i128, 0), try parseInstantString("1970-01-01T00:00Z[NotATimeZone]"));
    // Unknown annotation keys may lead with `_` and carry mixed-case values.
    try testing.expectEqual(@as(i128, 0), try parseInstantString("1970-01-01T00:00Z[foo=bar][_foo-bar0=Ignore-This-999999999999]"));
    // Expanded year followed by basic (dash-free) date + time.
    try testing.expectEqual(@as(i128, 217178610100000000), try parseInstantString("+0019761118T15:23:30.1+00:00"));
}

test "parseInstantString: annotation rule violations reject" {
    const bad = [_][]const u8{
        "1970-01-01T00:00Z[U-CA=iso8601]", // uppercase key
        "1970-01-01T00:00Z[u-CA=iso8601]", // partially capitalised key
        "1970-01-01T00:00Z[FOO=bar]", // capitalised unknown key
        "1970-01-01T00:00Z[u-ca=iso8601][!u-ca=iso8601]", // 2 calendars, one critical
        "1970-01-01T00:00Z[!u-ca=iso8601][u-ca=iso8601]",
        "1970-01-01T00:00Z[!unknown=x]", // critical unknown annotation
        "2021-08-19T17:30-07:00:01[-07:00:01]", // sub-minute time-zone offset annotation
    };
    for (bad) |s| try testing.expectError(error.Invalid, parseInstantString(s));
}

// ── PlainDateTime AO tests ────────────────────────────────────────────────

fn pdt(y: i32, mo: u8, d: u8, h: u32, mi: u32, s: u32, ms: u32, us: u32, ns: u32) PlainDateTimeRecord {
    return .{ .iso_year = y, .iso_month = mo, .iso_day = d, .hour = h, .minute = mi, .second = s, .millisecond = ms, .microsecond = us, .nanosecond = ns };
}

test "isoDateTimeWithinLimits: representable edges (test262 from/argument-string-limits)" {
    try testing.expect(isoDateTimeWithinLimits(pdt(2024, 1, 1, 0, 0, 0, 0, 0, 0)));
    try testing.expect(isoDateTimeWithinLimits(pdt(1970, 1, 1, 0, 0, 0, 0, 0, 0)));
    // Max edge: +275760-09-13T23:59:59.999999999 in; +275760-09-14 out.
    try testing.expect(isoDateTimeWithinLimits(pdt(275760, 9, 13, 23, 59, 59, 999, 999, 999)));
    try testing.expect(!isoDateTimeWithinLimits(pdt(275760, 9, 14, 0, 0, 0, 0, 0, 0)));
    // Min edge: midnight on -271821-04-19 is OUT (one day beyond the
    // Instant range maps to exactly nsMinInstant − nsPerDay, which the
    // ≤ bound rejects); one nanosecond later, and the next midnight, are in.
    try testing.expect(!isoDateTimeWithinLimits(pdt(-271821, 4, 19, 0, 0, 0, 0, 0, 0)));
    try testing.expect(isoDateTimeWithinLimits(pdt(-271821, 4, 19, 0, 0, 0, 0, 0, 1)));
    try testing.expect(isoDateTimeWithinLimits(pdt(-271821, 4, 20, 0, 0, 0, 0, 0, 0)));
}

test "addDateTime: time carry across the day boundary" {
    // 15:00 + 19h → next day 10:00.
    var dur = DurationRecord{ .hours = 19 };
    try testing.expectEqual(pdt(2024, 1, 2, 10, 0, 0, 0, 0, 0), addDateTime(pdt(2024, 1, 1, 15, 0, 0, 0, 0, 0), dur, false).?);
    // 10:00 − 19h → previous day 15:00 (negative carry via @divFloor).
    dur = DurationRecord{ .hours = -19 };
    try testing.expectEqual(pdt(2024, 1, 1, 15, 0, 0, 0, 0, 0), addDateTime(pdt(2024, 1, 2, 10, 0, 0, 0, 0, 0), dur, false).?);
}

test "addDateTime: day + time carry compose, leap February" {
    // 2020-02-28T23:30 + P1DT1H → +2 civil days across the leap day → 2020-03-01T00:30.
    const dur = DurationRecord{ .days = 1, .hours = 1 };
    try testing.expectEqual(pdt(2020, 3, 1, 0, 30, 0, 0, 0, 0), addDateTime(pdt(2020, 2, 28, 23, 30, 0, 0, 0, 0), dur, false).?);
}

test "addDateTime: month add constrains day, time untouched" {
    // 2024-01-31T12:00 + P1M (constrain) → 2024-02-29T12:00 (leap clamp).
    const dur = DurationRecord{ .months = 1 };
    try testing.expectEqual(pdt(2024, 2, 29, 12, 0, 0, 0, 0, 0), addDateTime(pdt(2024, 1, 31, 12, 0, 0, 0, 0, 0), dur, false).?);
}

test "roundTime: day carry, day unit, sub-second" {
    // 23:59:59 ceil to minute → next day midnight.
    var r = roundTime(.{ .hour = 23, .minute = 59, .second = 59 }, .minute, 1, .ceil);
    try testing.expectEqual(@as(i64, 1), r.days);
    try testing.expectEqual(PlainTimeRecord{}, r.time);
    // 12:34:56 to whole day, half_expand → past noon rounds up.
    r = roundTime(.{ .hour = 12, .minute = 34, .second = 56 }, .day, 1, .half_expand);
    try testing.expectEqual(@as(i64, 1), r.days);
    try testing.expectEqual(PlainTimeRecord{}, r.time);
    // 12:34:56.789 to nearest second, half_expand → 12:34:57.
    r = roundTime(.{ .hour = 12, .minute = 34, .second = 56, .millisecond = 789 }, .second, 1, .half_expand);
    try testing.expectEqual(@as(i64, 0), r.days);
    try testing.expectEqual(PlainTimeRecord{ .hour = 12, .minute = 34, .second = 57 }, r.time);
}

test "roundISODateTime: time carry advances the date" {
    try testing.expectEqual(
        pdt(2024, 1, 2, 0, 0, 0, 0, 0, 0),
        roundISODateTime(pdt(2024, 1, 1, 23, 59, 59, 0, 0, 0), .minute, 1, .ceil).?,
    );
}

test "compareISODateTime: date dominates, then time" {
    try testing.expectEqual(@as(i32, -1), compareISODateTime(pdt(2024, 1, 1, 12, 0, 0, 0, 0, 0), pdt(2024, 1, 1, 13, 0, 0, 0, 0, 0)));
    try testing.expectEqual(@as(i32, 1), compareISODateTime(pdt(2024, 1, 2, 0, 0, 0, 0, 0, 0), pdt(2024, 1, 1, 23, 59, 0, 0, 0, 0)));
    try testing.expectEqual(@as(i32, 0), compareISODateTime(pdt(2024, 1, 1, 5, 6, 7, 0, 0, 0), pdt(2024, 1, 1, 5, 6, 7, 0, 0, 0)));
}

test "differenceISODateTime: time opposes date → borrow a day (forward)" {
    // 2024-01-01T15:00 → 2024-01-02T10:00 is +19h, not 1 day − 5h.
    const d = differenceISODateTime(pdt(2024, 1, 1, 15, 0, 0, 0, 0, 0), pdt(2024, 1, 2, 10, 0, 0, 0, 0, 0), .day);
    try testing.expectEqual(@as(f64, 0), d.days);
    try testing.expectEqual(@as(f64, 19), d.hours);
    try testing.expectEqual(@as(f64, 0), d.minutes);
}

test "differenceISODateTime: time opposes date → borrow a day (backward)" {
    // 2024-01-02T10:00 → 2024-01-01T15:00 is −19h.
    const d = differenceISODateTime(pdt(2024, 1, 2, 10, 0, 0, 0, 0, 0), pdt(2024, 1, 1, 15, 0, 0, 0, 0, 0), .day);
    try testing.expectEqual(@as(f64, 0), d.days);
    try testing.expectEqual(@as(f64, -19), d.hours);
}

test "differenceISODateTime: same direction keeps the day" {
    // 2024-01-01T10:00 → 2024-01-02T15:00 is 1 day + 5h.
    const d = differenceISODateTime(pdt(2024, 1, 1, 10, 0, 0, 0, 0, 0), pdt(2024, 1, 2, 15, 0, 0, 0, 0, 0), .day);
    try testing.expectEqual(@as(f64, 1), d.days);
    try testing.expectEqual(@as(f64, 5), d.hours);
}

test "differenceISODateTime: multi-unit span with largest=year" {
    const d = differenceISODateTime(pdt(2020, 1, 15, 10, 30, 0, 0, 0, 0), pdt(2021, 3, 20, 14, 45, 30, 0, 0, 0), .year);
    try testing.expectEqual(@as(f64, 1), d.years);
    try testing.expectEqual(@as(f64, 2), d.months);
    try testing.expectEqual(@as(f64, 0), d.weeks);
    try testing.expectEqual(@as(f64, 5), d.days);
    try testing.expectEqual(@as(f64, 4), d.hours);
    try testing.expectEqual(@as(f64, 15), d.minutes);
    try testing.expectEqual(@as(f64, 30), d.seconds);
}

test "parseTemporalDateTimeString: date-only defaults to midnight" {
    try testing.expectEqual(pdt(2024, 1, 15, 0, 0, 0, 0, 0, 0), try parseTemporalDateTimeString("2024-01-15"));
}

test "parseTemporalDateTimeString: full form with sub-second split" {
    try testing.expectEqual(pdt(2024, 1, 15, 13, 45, 30, 123, 456, 789), try parseTemporalDateTimeString("2024-01-15T13:45:30.123456789"));
    try testing.expectEqual(pdt(2024, 1, 15, 13, 45, 30, 500, 0, 0), try parseTemporalDateTimeString("2024-01-15T13:45:30.5"));
}

test "parseTemporalDateTimeString: offset discarded, ISO calendar ok" {
    try testing.expectEqual(pdt(2024, 1, 15, 13, 45, 30, 0, 0, 0), try parseTemporalDateTimeString("2024-01-15T13:45:30+05:00"));
    try testing.expectEqual(pdt(2024, 1, 15, 13, 45, 0, 0, 0, 0), try parseTemporalDateTimeString("2024-01-15T13:45[u-ca=iso8601]"));
}

test "parseTemporalDateTimeString: Z designator rejects; calendar tier gates non-ISO" {
    try testing.expectError(error.Invalid, parseTemporalDateTimeString("2024-01-15T13:45:30Z"));
    if (intl_config.temporal_intl_extras) {
        try testing.expectEqual(@as(u8, 15), (try parseTemporalDateTimeString("2024-01-15T13:45[u-ca=gregory]")).iso_day);
    } else {
        try testing.expectError(error.Invalid, parseTemporalDateTimeString("2024-01-15T13:45[u-ca=gregory]"));
    }
    try testing.expectError(error.Invalid, parseTemporalDateTimeString("2024-01-15T13:45[u-ca=notexist]"));
    try testing.expectError(error.Invalid, parseTemporalDateTimeString("2024-13-01"));
}

test "isoDateTimeToString: auto precision + calendar annotation" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("2024-01-15T13:45:30", isoDateTimeToString(pdt(2024, 1, 15, 13, 45, 30, 0, 0, 0), &buf, .auto, .auto));
    try testing.expectEqualStrings("2024-01-15T13:45:30.5", isoDateTimeToString(pdt(2024, 1, 15, 13, 45, 30, 500, 0, 0), &buf, .auto, .auto));
    try testing.expectEqualStrings("2024-01-15T00:00:00[u-ca=iso8601]", isoDateTimeToString(pdt(2024, 1, 15, 0, 0, 0, 0, 0, 0), &buf, .always, .auto));
    try testing.expectEqualStrings("-000001-01-01T00:00:00", isoDateTimeToString(pdt(-1, 1, 1, 0, 0, 0, 0, 0, 0), &buf, .auto, .auto));
    // Explicit precision: fixed digits, and `.minute` drops the seconds.
    try testing.expectEqualStrings("2024-01-15T13:45:30.500", isoDateTimeToString(pdt(2024, 1, 15, 13, 45, 30, 500, 0, 0), &buf, .auto, .{ .digits = 3 }));
    try testing.expectEqualStrings("2024-01-15T13:45", isoDateTimeToString(pdt(2024, 1, 15, 13, 45, 30, 500, 0, 0), &buf, .auto, .minute));
}

test "isoYearMonthWithinLimits: April -271821 … September 275760" {
    try testing.expect(isoYearMonthWithinLimits(2020, 6));
    try testing.expect(!isoYearMonthWithinLimits(-271822, 12)); // year below floor
    try testing.expect(!isoYearMonthWithinLimits(275761, 1)); // year above ceiling
    try testing.expect(isoYearMonthWithinLimits(-271821, 4)); // April is the floor month
    try testing.expect(!isoYearMonthWithinLimits(-271821, 3)); // March falls outside
    try testing.expect(isoYearMonthWithinLimits(275760, 9)); // September is the ceiling month
    try testing.expect(!isoYearMonthWithinLimits(275760, 10)); // October falls outside
}

test "isoYearMonthToString: day + annotation shown only for always/critical" {
    var buf: [40]u8 = undefined;
    const rec: PlainYearMonthRecord = .{ .iso_year = 2020, .iso_month = 6, .ref_iso_day = 15 };
    try testing.expectEqualStrings("2020-06", isoYearMonthToString(rec, &buf, .auto));
    try testing.expectEqualStrings("2020-06", isoYearMonthToString(rec, &buf, .never));
    try testing.expectEqualStrings("2020-06-15[u-ca=iso8601]", isoYearMonthToString(rec, &buf, .always));
    try testing.expectEqualStrings("2020-06-15[!u-ca=iso8601]", isoYearMonthToString(rec, &buf, .critical));
    // Expanded year, default reference day 1.
    try testing.expectEqualStrings("-009999-01", isoYearMonthToString(.{ .iso_year = -9999, .iso_month = 1, .ref_iso_day = 1 }, &buf, .auto));
}

test "parseTemporalYearMonthString: optional day → reference day, default 1" {
    {
        const r = try parseTemporalYearMonthString("2020-06");
        try testing.expectEqual(@as(i32, 2020), r.iso_year);
        try testing.expectEqual(@as(u8, 6), r.iso_month);
        try testing.expectEqual(@as(u8, 1), r.ref_iso_day); // absent day defaults to 1
    }
    // Basic form `YYYYMM` and full date `YYYY-MM-DD` (the day becomes the reference).
    try testing.expectEqual(@as(u8, 6), (try parseTemporalYearMonthString("202006")).iso_month);
    try testing.expectEqual(@as(u8, 15), (try parseTemporalYearMonthString("2020-06-15")).ref_iso_day);
    try testing.expectEqual(@as(i32, 2020), (try parseTemporalYearMonthString("+002020-06")).iso_year);
    // A trailing time block is validated then discarded; a `Z` UTC designator is not.
    try testing.expectEqual(@as(u8, 15), (try parseTemporalYearMonthString("2020-06-15T12:30:00")).ref_iso_day);
    try testing.expectError(error.Invalid, parseTemporalYearMonthString("2020-06-15T00:00Z"));
    // A `u-ca` annotation must name the ISO calendar.
    try testing.expectEqual(@as(u8, 6), (try parseTemporalYearMonthString("2020-06[u-ca=iso8601]")).iso_month);
    try testing.expectError(error.Invalid, parseTemporalYearMonthString("2020-06[u-ca=notexist]"));
    try testing.expectError(error.Invalid, parseTemporalYearMonthString("2020-13")); // month out of range
    try testing.expectError(error.Invalid, parseTemporalYearMonthString("2020-06-31")); // June has 30 days
    try testing.expectError(error.Invalid, parseTemporalYearMonthString("2020-06X")); // trailing junk
}

test "isoMonthDayToString: reference year prepended only for always/critical" {
    var buf: [40]u8 = undefined;
    const rec: PlainMonthDayRecord = .{ .ref_iso_year = 1972, .iso_month = 6, .iso_day = 15 };
    try testing.expectEqualStrings("06-15", isoMonthDayToString(rec, &buf, .auto));
    try testing.expectEqualStrings("06-15", isoMonthDayToString(rec, &buf, .never));
    try testing.expectEqualStrings("1972-06-15[u-ca=iso8601]", isoMonthDayToString(rec, &buf, .always));
    try testing.expectEqualStrings("1972-06-15[!u-ca=iso8601]", isoMonthDayToString(rec, &buf, .critical));
}

test "parseTemporalMonthDayString: reference year always 1972" {
    {
        const r = try parseTemporalMonthDayString("06-15");
        try testing.expectEqual(@as(i32, 1972), r.ref_iso_year);
        try testing.expectEqual(@as(u8, 6), r.iso_month);
        try testing.expectEqual(@as(u8, 15), r.iso_day);
    }
    // `--MM-DD`, basic `MMDD`, and `--MMDD` all resolve to the same month-day.
    try testing.expectEqual(@as(u8, 15), (try parseTemporalMonthDayString("--06-15")).iso_day);
    try testing.expectEqual(@as(u8, 6), (try parseTemporalMonthDayString("0615")).iso_month);
    try testing.expectEqual(@as(u8, 15), (try parseTemporalMonthDayString("--0615")).iso_day);
    // Feb 29 is representable against the 1972 leap reference.
    try testing.expectEqual(@as(u8, 29), (try parseTemporalMonthDayString("02-29")).iso_day);
    // A full date: the year validates the day, then is discarded (refYear stays 1972).
    {
        const r = try parseTemporalMonthDayString("2020-02-29"); // 2020 is leap → day valid
        try testing.expectEqual(@as(i32, 1972), r.ref_iso_year);
        try testing.expectEqual(@as(u8, 2), r.iso_month);
        try testing.expectEqual(@as(u8, 29), r.iso_day);
    }
    try testing.expectError(error.Invalid, parseTemporalMonthDayString("2021-02-29")); // 2021 not leap
    try testing.expectError(error.Invalid, parseTemporalMonthDayString("13-01")); // month out of range
    try testing.expectError(error.Invalid, parseTemporalMonthDayString("06-31")); // June has 30 days
    try testing.expectError(error.Invalid, parseTemporalMonthDayString("06-15Z")); // trailing junk
}

test "parseTimeZoneIdentifier: UTC is ASCII case-insensitive" {
    try testing.expect(std.meta.activeTag(parseTimeZoneIdentifier("UTC").?) == .utc);
    try testing.expect(std.meta.activeTag(parseTimeZoneIdentifier("utc").?) == .utc);
    try testing.expect(std.meta.activeTag(parseTimeZoneIdentifier("Utc").?) == .utc);
}

test "parseTimeZoneIdentifier: offset forms resolve to whole-minute offsets" {
    const cases = [_]struct { s: []const u8, want: i32 }{
        .{ .s = "+01:00", .want = 60 },
        .{ .s = "+01", .want = 60 }, // minute block optional
        .{ .s = "+0130", .want = 90 }, // basic (colon-less) form
        .{ .s = "+05:30", .want = 330 },
        .{ .s = "-08:00", .want = -480 },
        .{ .s = "-00:02", .want = -2 }, // negative sign retained at zero hour
        .{ .s = "+00:00", .want = 0 }, // a positive zero offset, distinct from .utc
    };
    for (cases) |c| {
        const tz = parseTimeZoneIdentifier(c.s) orelse return error.TestUnexpectedNull;
        switch (tz) {
            .offset_minutes => |m| try testing.expectEqual(c.want, m),
            .utc, .named => return error.TestExpectedOffsetZone,
        }
    }
}

test "parseTimeZoneIdentifier: IANA gated by intl tier; rejects sub-minute and garbage" {
    try testing.expect(parseTimeZoneIdentifier("+01:00:00") == null); // sub-minute precision
    if (intl_config.temporal_intl_extras) {
        try testing.expect(std.meta.activeTag(parseTimeZoneIdentifier("America/New_York").?) == .named);
    } else {
        try testing.expect(parseTimeZoneIdentifier("America/New_York") == null);
    }
    try testing.expect(parseTimeZoneIdentifier("") == null); // empty
    try testing.expect(parseTimeZoneIdentifier("+24:00") == null); // hour out of range
    try testing.expect(parseTimeZoneIdentifier("+01:60") == null); // minute out of range
    try testing.expect(parseTimeZoneIdentifier("Z") == null); // UTC designator is not an identifier
    try testing.expect(parseTimeZoneIdentifier("+1:00") == null); // single-digit hour
}

test "parseTimeZoneString: bare identifier and zone extracted from a date-time string" {
    // Bare identifiers still work (the fast path).
    try testing.expect(std.meta.activeTag(parseTimeZoneString("UTC").?) == .utc);
    try testing.expectEqual(@as(i32, 330), parseTimeZoneString("+05:30").?.offset_minutes);

    // Annotation wins over the time portion's Z / offset.
    try testing.expect(std.meta.activeTag(parseTimeZoneString("2021-08-19T17:30[UTC]").?) == .utc);
    try testing.expect(std.meta.activeTag(parseTimeZoneString("2021-08-19T17:30-07:00[UTC]").?) == .utc);
    try testing.expectEqual(@as(i32, 106), parseTimeZoneString("2021-08-19T17:30:45.123456789-12:12[+01:46]").?.offset_minutes);

    // No annotation: Z ⇒ UTC, a minute-precise offset ⇒ that offset.
    try testing.expect(std.meta.activeTag(parseTimeZoneString("2021-08-19T17:30Z").?) == .utc);
    try testing.expectEqual(@as(i32, -420), parseTimeZoneString("2021-08-19T17:30-07:00").?.offset_minutes);

    // A bare date-time has no zone determinant.
    try testing.expect(parseTimeZoneString("2021-08-19T17:30") == null);
    // A sub-minute-*precision* offset (seconds field present, even ":00") is
    // not a valid zone, regardless of value.
    try testing.expect(parseTimeZoneString("2021-08-19T17:30-07:00:00") == null);
    try testing.expect(parseTimeZoneString("2021-08-19T17:30-07:00:01") == null);
    try testing.expect(parseTimeZoneString("2021-08-19T17:30-07:00:00.000000000") == null);
    // A leap-second / sub-minute in the annotation name is invalid.
    try testing.expect(parseTimeZoneString("2021-08-19T17:30:45+23:59[+23:59:60]") == null);
}

test "timeZoneIdentifierString: UTC named vs extended ±HH:MM offset" {
    var buf: [16]u8 = undefined;
    try testing.expectEqualStrings("UTC", timeZoneIdentifierString(.utc, &buf));
    try testing.expectEqualStrings("+01:00", timeZoneIdentifierString(.{ .offset_minutes = 60 }, &buf));
    try testing.expectEqualStrings("-08:00", timeZoneIdentifierString(.{ .offset_minutes = -480 }, &buf));
    try testing.expectEqualStrings("+05:30", timeZoneIdentifierString(.{ .offset_minutes = 330 }, &buf));
    // A zero offset still renders "+00:00" — only the .utc variant prints "UTC".
    try testing.expectEqualStrings("+00:00", timeZoneIdentifierString(.{ .offset_minutes = 0 }, &buf));
    try testing.expectEqualStrings("-00:02", timeZoneIdentifierString(.{ .offset_minutes = -2 }, &buf));
}

test "isoDateTimeFromEpochNs/isoDateTimeToEpochNs: round trip and floor toward -inf" {
    // Epoch 0 is the Unix epoch.
    {
        const dt = isoDateTimeFromEpochNs(0);
        try testing.expectEqual(@as(i32, 1970), dt.iso_year);
        try testing.expectEqual(@as(u8, 1), dt.iso_month);
        try testing.expectEqual(@as(u8, 1), dt.iso_day);
        try testing.expectEqual(@as(u32, 0), dt.hour);
        try testing.expectEqual(@as(i128, 0), isoDateTimeToEpochNs(dt));
    }
    // One nanosecond before the epoch floors onto the prior civil day.
    {
        const dt = isoDateTimeFromEpochNs(-1);
        try testing.expectEqual(@as(i32, 1969), dt.iso_year);
        try testing.expectEqual(@as(u8, 12), dt.iso_month);
        try testing.expectEqual(@as(u8, 31), dt.iso_day);
        try testing.expectEqual(@as(u32, 23), dt.hour);
        try testing.expectEqual(@as(u32, 59), dt.minute);
        try testing.expectEqual(@as(u32, 59), dt.second);
        try testing.expectEqual(@as(u32, 999), dt.millisecond);
        try testing.expectEqual(@as(u32, 999), dt.microsecond);
        try testing.expectEqual(@as(u32, 999), dt.nanosecond);
        try testing.expectEqual(@as(i128, -1), isoDateTimeToEpochNs(dt));
    }
    // A representative instant with a sub-second fraction, both directions.
    {
        const ns: i128 = 1_597_494_896_789_000_000; // 2020-08-15T12:34:56.789Z
        const dt = isoDateTimeFromEpochNs(ns);
        try testing.expectEqual(@as(i32, 2020), dt.iso_year);
        try testing.expectEqual(@as(u8, 8), dt.iso_month);
        try testing.expectEqual(@as(u8, 15), dt.iso_day);
        try testing.expectEqual(@as(u32, 12), dt.hour);
        try testing.expectEqual(@as(u32, 34), dt.minute);
        try testing.expectEqual(@as(u32, 56), dt.second);
        try testing.expectEqual(@as(u32, 789), dt.millisecond);
        try testing.expectEqual(@as(u32, 0), dt.microsecond);
        try testing.expectEqual(@as(u32, 0), dt.nanosecond);
        try testing.expectEqual(ns, isoDateTimeToEpochNs(dt));
    }
}

test "getISODateTimeFor/getEpochNanosecondsFor: apply the constant zone offset" {
    try testing.expectEqual(@as(i64, 0), getOffsetNanosecondsFor(.utc, 0));
    try testing.expectEqual(@as(i64, 19_800_000_000_000), getOffsetNanosecondsFor(.{ .offset_minutes = 330 }, 0));
    try testing.expectEqual(@as(i64, -28_800_000_000_000), getOffsetNanosecondsFor(.{ .offset_minutes = -480 }, 0));

    const noon: i128 = 1_597_494_896_000_000_000; // 2020-08-15T12:34:56Z
    // UTC shows wall-clock equal to the instant.
    {
        const dt = getISODateTimeFor(.utc, noon);
        try testing.expectEqual(@as(u8, 15), dt.iso_day);
        try testing.expectEqual(@as(u32, 12), dt.hour);
        try testing.expectEqual(@as(u32, 34), dt.minute);
    }
    // +05:30 advances the wall clock by five and a half hours.
    {
        const dt = getISODateTimeFor(.{ .offset_minutes = 330 }, noon);
        try testing.expectEqual(@as(u8, 15), dt.iso_day);
        try testing.expectEqual(@as(u32, 18), dt.hour);
        try testing.expectEqual(@as(u32, 4), dt.minute);
        try testing.expectEqual(@as(u32, 56), dt.second);
    }
    // A negative offset can push the wall clock back across a day boundary.
    {
        const midnight_2020: i128 = 1_577_836_800_000_000_000; // 2020-01-01T00:00:00Z
        const dt = getISODateTimeFor(.{ .offset_minutes = -480 }, midnight_2020);
        try testing.expectEqual(@as(i32, 2019), dt.iso_year);
        try testing.expectEqual(@as(u8, 12), dt.iso_month);
        try testing.expectEqual(@as(u8, 31), dt.iso_day);
        try testing.expectEqual(@as(u32, 16), dt.hour);
        // Wall clock back to the source instant: getEpochNanosecondsFor inverts the shift.
        try testing.expectEqual(midnight_2020, getEpochNanosecondsFor(.{ .offset_minutes = -480 }, dt).?);
    }
}

test "interpretISODateTimeOffset: behaviour + offset option matrix" {
    const dt = PlainDateTimeRecord{
        .iso_year = 2020,
        .iso_month = 1,
        .iso_day = 1,
        .hour = 0,
        .minute = 0,
        .second = 0,
        .millisecond = 0,
        .microsecond = 0,
        .nanosecond = 0,
    };
    const w: i128 = 1_577_836_800_000_000_000; // 2020-01-01T00:00:00 as if UTC
    const o: i128 = 19_800_000_000_000; // +05:30
    const plus530 = TimeZone{ .offset_minutes = 330 };

    // wall — the zone places the instant (offset arg irrelevant).
    try testing.expectEqual(w, try interpretISODateTimeOffset(dt, .wall, 0, .utc, .reject));
    try testing.expectEqual(w - o, try interpretISODateTimeOffset(dt, .wall, 0, plus530, .reject));
    // exact (`Z`) — wall time is UTC, shifted by the parsed offset (0 here).
    try testing.expectEqual(w, try interpretISODateTimeOffset(dt, .exact, 0, plus530, .reject));
    // option + reject — must match the zone's offset, else OffsetMismatch.
    try testing.expectEqual(w - o, try interpretISODateTimeOffset(dt, .option, o, plus530, .reject));
    try testing.expectError(error.OffsetMismatch, interpretISODateTimeOffset(dt, .option, 0, plus530, .reject));
    // option + use — take the supplied offset verbatim.
    try testing.expectEqual(w, try interpretISODateTimeOffset(dt, .option, 0, plus530, .use));
    // option + ignore — discard the supplied offset, defer to the zone.
    try testing.expectEqual(w - o, try interpretISODateTimeOffset(dt, .option, 0, plus530, .ignore));
    // option + prefer — mismatch falls back to the zone offset (no throw).
    try testing.expectEqual(w - o, try interpretISODateTimeOffset(dt, .option, 0, plus530, .prefer));
}

test "parseTemporalZonedDateTimeString: offset / Z / bare-date forms" {
    {
        const p = try parseTemporalZonedDateTimeString("2020-01-01T00:00:00+05:30[+05:30]");
        try testing.expectEqual(OffsetBehaviour.option, p.behaviour);
        try testing.expectEqual(@as(i128, 19_800_000_000_000), p.offset_ns);
        switch (p.time_zone) {
            .offset_minutes => |m| try testing.expectEqual(@as(i32, 330), m),
            else => return error.TestUnexpectedResult,
        }
    }
    {
        const p = try parseTemporalZonedDateTimeString("2020-01-01T00:00:00Z[UTC]");
        try testing.expectEqual(OffsetBehaviour.exact, p.behaviour);
        try testing.expect(std.meta.activeTag(p.time_zone) == .utc);
    }
    {
        // Bare date → midnight, no offset ⇒ wall behaviour.
        const p = try parseTemporalZonedDateTimeString("2020-01-01[+05:30]");
        try testing.expectEqual(OffsetBehaviour.wall, p.behaviour);
        try testing.expectEqual(@as(u32, 0), p.date_time.hour);
    }
    // ISO calendar annotation is accepted.
    _ = try parseTemporalZonedDateTimeString("2020-01-01T00:00:00+05:30[+05:30][u-ca=iso8601]");
}

test "parseTemporalZonedDateTimeString: rejects missing annotation; IANA/calendars tier-gated" {
    try testing.expectError(error.Invalid, parseTemporalZonedDateTimeString("2020-01-01T00:00:00"));
    if (intl_config.temporal_intl_extras) {
        _ = try parseTemporalZonedDateTimeString("2020-01-01T00:00:00[America/New_York]");
        _ = try parseTemporalZonedDateTimeString("2020-01-01T00:00:00+05:30[+05:30][u-ca=hebrew]");
    } else {
        try testing.expectError(error.Invalid, parseTemporalZonedDateTimeString("2020-01-01T00:00:00[America/New_York]"));
        try testing.expectError(error.Invalid, parseTemporalZonedDateTimeString("2020-01-01T00:00:00+05:30[+05:30][u-ca=hebrew]"));
    }
    try testing.expectError(error.Invalid, parseTemporalZonedDateTimeString("2020-01-01T00:00:00+05:30[+05:30][u-ca=notexist]"));
}

test "parseOffsetString: numeric offset field, signed nanoseconds" {
    try testing.expectEqual(@as(?i128, 19_800_000_000_000), parseOffsetString("+05:30"));
    try testing.expectEqual(@as(?i128, -28_800_000_000_000), parseOffsetString("-08:00"));
    try testing.expectEqual(@as(?i128, 0), parseOffsetString("+00:00"));
    try testing.expectEqual(@as(?i128, null), parseOffsetString("05:30")); // no sign
    try testing.expectEqual(@as(?i128, null), parseOffsetString("+05:30x")); // trailing junk
}

test "zonedDateTimeToString: local fields + offset + zone annotation" {
    var buf: [80]u8 = undefined;
    // UTC zone renders its offset as +00:00, annotated [UTC].
    try testing.expectEqualStrings(
        "1970-01-01T00:00:00+00:00[UTC]",
        zonedDateTimeToString(.{ .epoch_ns = 0, .time_zone = .utc }, &buf, .{}),
    );
    // +05:30 advances the wall clock and shows the matching offset.
    try testing.expectEqualStrings(
        "1970-01-01T05:30:00+05:30[+05:30]",
        zonedDateTimeToString(.{ .epoch_ns = 0, .time_zone = .{ .offset_minutes = 330 } }, &buf, .{}),
    );
    // offset:never + timeZoneName:never strips both annotations.
    try testing.expectEqualStrings(
        "1970-01-01T05:30:00",
        zonedDateTimeToString(.{ .epoch_ns = 0, .time_zone = .{ .offset_minutes = 330 } }, &buf, .{
            .show_offset = false,
            .time_zone_name = .never,
        }),
    );
    // calendarName:always appends the ISO calendar annotation.
    try testing.expectEqualStrings(
        "1970-01-01T00:00:00+00:00[UTC][u-ca=iso8601]",
        zonedDateTimeToString(.{ .epoch_ns = 0, .time_zone = .utc }, &buf, .{ .calendar = .always }),
    );
}

test "zonedDateTimeToString: fractional-second precision" {
    var buf: [80]u8 = undefined;
    const rec = ZonedDateTimeRecord{ .epoch_ns = 789_000_000, .time_zone = .utc }; // 0.789s
    // auto trims trailing zeros.
    try testing.expectEqualStrings(
        "1970-01-01T00:00:00.789+00:00[UTC]",
        zonedDateTimeToString(rec, &buf, .{}),
    );
    // explicit 2 digits truncates.
    try testing.expectEqualStrings(
        "1970-01-01T00:00:00.78+00:00[UTC]",
        zonedDateTimeToString(rec, &buf, .{ .precision = .{ .digits = 2 } }),
    );
    // 0 digits omits the fraction entirely.
    try testing.expectEqualStrings(
        "1970-01-01T00:00:00+00:00[UTC]",
        zonedDateTimeToString(rec, &buf, .{ .precision = .{ .digits = 0 } }),
    );
    // `.minute` precision stops at HH:MM.
    try testing.expectEqualStrings(
        "1970-01-01T00:00+00:00[UTC]",
        zonedDateTimeToString(rec, &buf, .{ .precision = .minute }),
    );
}

test "addZonedDateTime: time part in exact time, date part in wall clock" {
    // Pure time shift: +2h in UTC is exact-time arithmetic.
    try testing.expectEqual(@as(?i128, 2 * 3_600_000_000_000), addZonedDateTime(0, .utc, .{ .hours = 2 }, false));
    // In a +05:00 zone every day is exactly 24 h (no DST), so +P1D from
    // epoch 0 advances exactly one solar day.
    const plus5 = TimeZone{ .offset_minutes = 300 };
    try testing.expectEqual(@as(?i128, ns_per_day), addZonedDateTime(0, plus5, .{ .days = 1 }, false));
    // Date then time: +P1DT2H = one day + two hours.
    try testing.expectEqual(
        @as(?i128, ns_per_day + 2 * 3_600_000_000_000),
        addZonedDateTime(0, plus5, .{ .days = 1, .hours = 2 }, false),
    );
}

test "roundZonedDateTime: round in the zone's wall clock" {
    // 01:30 UTC rounds up to 02:00 at hour granularity (halfExpand).
    try testing.expectEqual(
        @as(?i128, 2 * 3_600_000_000_000),
        roundZonedDateTime(5_400_000_000_000, .utc, .hour, 1, .half_expand),
    );
    // Day rounding in a +05:00 zone: wall 05:00 floors to wall midnight,
    // whose instant is one zone-offset (5 h) before the UTC day start.
    const plus5 = TimeZone{ .offset_minutes = 300 };
    try testing.expectEqual(
        @as(?i128, -5 * 3_600_000_000_000),
        roundZonedDateTime(0, plus5, .day, 1, .half_expand),
    );
}

test "zonedStartOfDay: wall midnight re-anchored to an instant" {
    // 1970-01-02T01:00Z → 1970-01-02T00:00Z.
    try testing.expectEqual(@as(?i128, ns_per_day), zonedStartOfDay(90_000_000_000_000, .utc));
    // +05:00 zone, epoch 0 (wall 05:00) → wall midnight = epoch −5 h.
    const plus5 = TimeZone{ .offset_minutes = 300 };
    try testing.expectEqual(@as(?i128, -5 * 3_600_000_000_000), zonedStartOfDay(0, plus5));
}

fn expectDur(expected: DurationRecord, got: ?DurationRecord) !void {
    const d = got orelse return error.TestUnexpectedNull;
    try testing.expectEqual(expected.years, d.years);
    try testing.expectEqual(expected.months, d.months);
    try testing.expectEqual(expected.weeks, d.weeks);
    try testing.expectEqual(expected.days, d.days);
    try testing.expectEqual(expected.hours, d.hours);
    try testing.expectEqual(expected.minutes, d.minutes);
    try testing.expectEqual(expected.seconds, d.seconds);
    try testing.expectEqual(expected.milliseconds, d.milliseconds);
    try testing.expectEqual(expected.microseconds, d.microseconds);
    try testing.expectEqual(expected.nanoseconds, d.nanoseconds);
}

fn roundDT(
    start: PlainDateTimeRecord,
    end: PlainDateTimeRecord,
    largest: LargestUnit,
    smallest: LargestUnit,
    inc: i128,
    mode: RoundingMode,
) ?DurationRecord {
    const diff = differenceISODateTime(start, end, largest);
    return roundRelativeDateTime(start, end, diff, largest, smallest, inc, mode);
}

test "roundRelativeDateTime: year smallest rounds up past the half mark" {
    // 2000-01-01 → 2001-09-01 is 1y8m; rounding to whole years (halfExpand)
    // sits at ~1.67 years → 2 years.
    const start = PlainDateTimeRecord{ .iso_year = 2000, .iso_month = 1, .iso_day = 1 };
    const end = PlainDateTimeRecord{ .iso_year = 2001, .iso_month = 9, .iso_day = 1 };
    try expectDur(.{ .years = 2 }, roundDT(start, end, .year, .year, 1, .half_expand));
}

test "roundRelativeDateTime: month smallest truncates toward zero" {
    // 2000-01-15 → 2000-04-10 is 2m26d; trunc to whole months → 2 months.
    const start = PlainDateTimeRecord{ .iso_year = 2000, .iso_month = 1, .iso_day = 15 };
    const end = PlainDateTimeRecord{ .iso_year = 2000, .iso_month = 4, .iso_day = 10 };
    try expectDur(.{ .months = 2 }, roundDT(start, end, .month, .month, 1, .trunc));
}

test "roundRelativeDateTime: month rounding bubbles 12 months up to a year" {
    // 2000-01-01 → 2000-12-20, largestUnit year: 11m19d. Rounding the month
    // up (halfExpand, ~0.61 into December) yields 12 months, which the
    // re-difference promotes to 1 year.
    const start = PlainDateTimeRecord{ .iso_year = 2000, .iso_month = 1, .iso_day = 1 };
    const end = PlainDateTimeRecord{ .iso_year = 2000, .iso_month = 12, .iso_day = 20 };
    try expectDur(.{ .years = 1 }, roundDT(start, end, .year, .month, 1, .half_expand));
}

test "roundRelativeDateTime: week smallest stays unbubbled under month largest" {
    // 2000-01-01 → 2000-02-10, largestUnit month: 1m9d. Rounding to weeks
    // keeps the held month and the rounded week count (no promotion to
    // months/days — §7.5 step 9 excludes week from bubbling).
    const start = PlainDateTimeRecord{ .iso_year = 2000, .iso_month = 1, .iso_day = 1 };
    const end = PlainDateTimeRecord{ .iso_year = 2000, .iso_month = 2, .iso_day = 10 };
    try expectDur(.{ .months = 1, .weeks = 1 }, roundDT(start, end, .month, .week, 1, .trunc));
}

test "roundRelativeDateTime: day smallest rounds the time-of-day carry" {
    // 2000-01-01T00:00 → 2000-01-10T12:00 is 9d12h; rounding to whole days
    // (halfExpand) lands on 10 days.
    const start = PlainDateTimeRecord{ .iso_year = 2000, .iso_month = 1, .iso_day = 1 };
    const end = PlainDateTimeRecord{ .iso_year = 2000, .iso_month = 1, .iso_day = 10, .hour = 12 };
    try expectDur(.{ .days = 10 }, roundDT(start, end, .day, .day, 1, .half_expand));
}

test "roundRelativeDateTime: hour rounding expands a day, no bubble at day largest" {
    // 2000-01-01T00:00 → 2000-01-05T23:30 is 4d23h30m; rounding to the hour
    // rolls 23:30 up to a full day → exactly 5 days.
    const start = PlainDateTimeRecord{ .iso_year = 2000, .iso_month = 1, .iso_day = 1 };
    const end = PlainDateTimeRecord{ .iso_year = 2000, .iso_month = 1, .iso_day = 5, .hour = 23, .minute = 30 };
    try expectDur(.{ .days = 5 }, roundDT(start, end, .day, .hour, 1, .half_expand));
}

test "roundRelativeDateTime: hour largest keeps the whole span in time fields" {
    // 2000-01-01T00:00 → 2000-01-02T05:30, largestUnit hour: 29h30m; the
    // day stays folded into hours, rounding half-up to 30 hours.
    const start = PlainDateTimeRecord{ .iso_year = 2000, .iso_month = 1, .iso_day = 1 };
    const end = PlainDateTimeRecord{ .iso_year = 2000, .iso_month = 1, .iso_day = 2, .hour = 5, .minute = 30 };
    try expectDur(.{ .hours = 30 }, roundDT(start, end, .hour, .hour, 1, .half_expand));
}
