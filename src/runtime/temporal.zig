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

/// Brand discriminator for a Temporal instance. Stored alongside the
/// payload so a prototype method's `RequireInternalSlot` check is a
/// single tagged-union comparison that `Object.setPrototypeOf`
/// cannot defeat (mirrors the DisposableStack brand discipline).
pub const TemporalKind = enum {
    duration,
    plain_time,
    instant,
    plain_date,
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

/// §3.5 Temporal.PlainDate internal slots ([[ISOYear]], [[ISOMonth]],
/// [[ISODay]]). The calendar is always the ISO 8601 calendar, so no
/// calendar pointer is stored; the record carries no heap reference.
pub const PlainDateRecord = struct {
    iso_year: i32 = 0,
    iso_month: u8 = 1,
    iso_day: u8 = 1,
};

/// The side allocation a Temporal instance's `JSObject` points to
/// through `JSObjectExtension.temporal_record`. A tagged union so
/// the single slot serves every plain Temporal type.
pub const TemporalRecord = union(TemporalKind) {
    duration: DurationRecord,
    plain_time: PlainTimeRecord,
    instant: InstantRecord,
    plain_date: PlainDateRecord,

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
        d.years,    d.months,       d.weeks,        d.days,
        d.hours,    d.minutes,      d.seconds,      d.milliseconds,
        d.microseconds, d.nanoseconds,
    };
    for (fields) |v| {
        if (v < 0) return -1;
        if (v > 0) return 1;
    }
    return 0;
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
        d.years,    d.months,       d.weeks,        d.days,
        d.hours,    d.minutes,      d.seconds,      d.milliseconds,
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
    // integer in seconds. Compute the integer part exactly with
    // i128 so the bound check isn't fooled by f64 rounding near
    // 2^53; the sub-second remainder only affects the fractional
    // part, which the spec allows (…991.999999999).
    //
    // Mirrors the polyfill's RejectDuration: split ms/µs/ns into
    // (div = whole seconds contributed, mod = sub-second leftover),
    // sum the whole-second contributions, and require the seconds
    // total to be a safe integer.
    const ms_div = std.math.trunc(d.milliseconds / 1000.0);
    const ms_mod = d.milliseconds - ms_div * 1000.0; // (-999..999) ms
    const us_div = std.math.trunc(d.microseconds / 1.0e6);
    const us_mod = d.microseconds - us_div * 1.0e6; // (-999999..999999) µs
    const ns_div = std.math.trunc(d.nanoseconds / 1.0e9);
    const ns_mod = d.nanoseconds - ns_div * 1.0e9; // ns leftover
    // Sub-second leftovers, expressed in nanoseconds, contribute
    // their whole-second carry to the seconds total.
    const remainder_ns = ms_mod * 1.0e6 + us_mod * 1.0e3 + ns_mod;
    const remainder_sec = std.math.trunc(remainder_ns / 1.0e9);
    const total_sec = d.days * 86400.0 + d.hours * 3600.0 + d.minutes * 60.0 +
        d.seconds + ms_div + us_div + ns_div + remainder_sec;
    if (!isSafeInteger(total_sec)) return false;
    return true;
}

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
pub fn temporalDurationToString(d: DurationRecord, buf: []u8) []const u8 {
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
    // Emit the seconds part when there's a non-zero seconds value,
    // OR the largest unit is second-or-smaller (so an all-zero
    // duration still renders "PT0S").
    if (seconds_total != 0 or frac_ns != 0 or sub_second_largest) {
        tw.decimalI128(seconds_total);
        if (frac_ns != 0) {
            tw.byte('.');
            tw.fraction9(@intCast(frac_ns));
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

    // Strip trailing annotation blocks `[...]` (calendar / time-zone
    // annotations). There may be more than one; each is balanced.
    s = stripAnnotations(s) catch return error.Invalid;

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

/// Strip one or more trailing `[...]` annotation blocks. Errors if a
/// `[` is unbalanced.
fn stripAnnotations(s: []const u8) error{Invalid}![]const u8 {
    var end = s.len;
    while (end > 0 and s[end - 1] == ']') {
        // Find the matching `[`.
        var i = end - 1;
        while (i > 0 and s[i] != '[') i -= 1;
        if (s[i] != '[') return error.Invalid;
        end = i;
    }
    return s[0..end];
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
pub fn plainTimeToString(t: PlainTimeRecord, buf: []u8) []const u8 {
    var w = Writer{ .buf = buf, .len = 0 };
    w.pad2(t.hour);
    w.byte(':');
    w.pad2(t.minute);
    w.byte(':');
    w.pad2(t.second);
    const sub_ns: u32 = t.millisecond * 1_000_000 + t.microsecond * 1_000 + t.nanosecond;
    if (sub_ns != 0) {
        w.byte('.');
        w.fraction9(sub_ns);
    }
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

// ── §8.x TemporalInstantToString (UTC, precision = "auto") ────────────────

/// Format an epoch-ns value to its UTC ISO-8601 string — the form
/// `Temporal.Instant.prototype.toString` / `toJSON` produce with no
/// time-zone and `precision="auto"`: `YYYY-MM-DDTHH:MM:SS` plus a
/// trimmed sub-second fraction and a trailing `Z`. Years outside
/// 0000..9999 use the expanded `±YYYYYY` form.
pub fn instantToString(epoch_ns: i128, buf: []u8) []const u8 {
    const sec = @divFloor(epoch_ns, 1_000_000_000);
    const sub_ns: u32 = @intCast(epoch_ns - sec * 1_000_000_000); // [0, 999999999]
    const days = @divFloor(sec, 86400);
    const sod = sec - days * 86400; // [0, 86399]
    const ymd = civilFromDays(@intCast(days));
    const hour: u32 = @intCast(@divTrunc(sod, 3600));
    const minute: u32 = @intCast(@divTrunc(@mod(sod, 3600), 60));
    const second: u32 = @intCast(@mod(sod, 60));

    var w = Writer{ .buf = buf, .len = 0 };
    writeIsoYear(&w, ymd.year);
    w.byte('-');
    w.pad2(ymd.month);
    w.byte('-');
    w.pad2(ymd.day);
    w.byte('T');
    w.pad2(hour);
    w.byte(':');
    w.pad2(minute);
    w.byte(':');
    w.pad2(second);
    if (sub_ns != 0) {
        w.byte('.');
        w.fraction9(sub_ns);
    }
    w.byte('Z');
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
pub fn isoDateToString(rec: PlainDateRecord, buf: []u8, calendar: CalendarDisplay) []const u8 {
    var w = Writer{ .buf = buf, .len = 0 };
    writeIsoYear(&w, rec.iso_year);
    w.byte('-');
    w.pad2(rec.iso_month);
    w.byte('-');
    w.pad2(rec.iso_day);
    switch (calendar) {
        .auto, .never => {},
        .always => w.bytes("[u-ca=iso8601]"),
        .critical => w.bytes("[!u-ca=iso8601]"),
    }
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
    // supported calendar. Cynic ships only the ISO 8601 calendar, so an
    // unknown calendar (`[u-ca=notexist]`) is a parse error.
    if (calendar) |cal| {
        if (!std.ascii.eqlIgnoreCase(cal, "iso8601")) return error.Invalid;
    }
    if (!isoDateWithinLimits(date.year, date.month, date.day)) return error.Invalid;
    return .{
        .iso_year = @intCast(date.year),
        .iso_month = @intCast(date.month),
        .iso_day = @intCast(date.day),
    };
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
    try testing.expectEqualStrings("PT0S", temporalDurationToString(.{}, &buf));
    try testing.expectEqualStrings("P1Y", temporalDurationToString(.{ .years = 1 }, &buf));
    try testing.expectEqualStrings("-P1Y", temporalDurationToString(.{ .years = -1 }, &buf));
    try testing.expectEqualStrings("P1Y2M3W4D", temporalDurationToString(.{ .years = 1, .months = 2, .weeks = 3, .days = 4 }, &buf));
    try testing.expectEqualStrings("PT5H", temporalDurationToString(.{ .hours = 5 }, &buf));
    try testing.expectEqualStrings("PT6M", temporalDurationToString(.{ .minutes = 6 }, &buf));
    try testing.expectEqualStrings("PT7S", temporalDurationToString(.{ .seconds = 7 }, &buf));
}

test "temporalDurationToString: sub-second balancing" {
    var buf: [128]u8 = undefined;
    try testing.expectEqualStrings("PT0.008S", temporalDurationToString(.{ .milliseconds = 8 }, &buf));
    try testing.expectEqualStrings("PT0.000009S", temporalDurationToString(.{ .microseconds = 9 }, &buf));
    try testing.expectEqualStrings("PT0.000000001S", temporalDurationToString(.{ .nanoseconds = 1 }, &buf));
    try testing.expectEqualStrings("PT4.003002001S", temporalDurationToString(.{ .seconds = 4, .milliseconds = 3, .microseconds = 2, .nanoseconds = 1 }, &buf));
    // 999 ms + 999999 µs + 999999999 ns balances to 2.998998999 s.
    try testing.expectEqualStrings("PT2.998998999S", temporalDurationToString(.{ .milliseconds = 999, .microseconds = 999999, .nanoseconds = 999999999 }, &buf));
    try testing.expectEqualStrings("-PT2.998998999S", temporalDurationToString(.{ .milliseconds = -999, .microseconds = -999999, .nanoseconds = -999999999 }, &buf));
    // All fields large.
    try testing.expectEqualStrings(
        "P1234Y2345M3456W4567DT5678H6789M7890.890901123S",
        temporalDurationToString(.{ .years = 1234, .months = 2345, .weeks = 3456, .days = 4567, .hours = 5678, .minutes = 6789, .seconds = 7890, .milliseconds = 890, .microseconds = 901, .nanoseconds = 123 }, &buf),
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
    try testing.expectEqualStrings("00:00:00", plainTimeToString(.{}, &buf));
    try testing.expectEqualStrings("15:23:30.123456789", plainTimeToString(.{ .hour = 15, .minute = 23, .second = 30, .millisecond = 123, .microsecond = 456, .nanosecond = 789 }, &buf));
    try testing.expectEqualStrings("01:02:03", plainTimeToString(.{ .hour = 1, .minute = 2, .second = 3 }, &buf));
    try testing.expectEqualStrings("12:00:00.5", plainTimeToString(.{ .hour = 12, .millisecond = 500 }, &buf));
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
    try testing.expectEqualStrings("1970-01-01T00:00:00Z", instantToString(0, &buf));
    try testing.expectEqualStrings("1976-11-18T14:23:30.123456789Z", instantToString(217175010123456789, &buf));
    try testing.expectEqualStrings("1963-02-13T09:36:29.123456789Z", instantToString(-217175010876543211, &buf));
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
        "",                          "invalid iso8601",
        "2020-01-00T00:00Z",         "2020-01-32T00:00Z",
        "2020-02-30T00:00Z",         "2021-02-29T00:00Z",
        "2020-00-01T00:00Z",         "2020-13-01T00:00Z",
        "2020-01-01TZ",              "2020-01-01T25:00:00Z",
        "2020-01-01T01:60:00Z",      "2020-01-01T00:00Zjunk",
        "2020-01-01T00:00:00+00:00junk", "2020-01-01T00:00:00+00:00[UTC]junk",
        "02020-01-01T00:00Z",        "2020-001-01T00:00Z",
        "2020-01-001T00:00Z",        "2020-01-01T001Z",
        "2020-01-01T00:00-24:00",    "2020-01-01T00:00+24:00",
        "2020-W01-1T00:00Z",         "2020-001T00:00Z",
        "+0002020-01-01T00:00Z",     "2020-01",
        "01-01",                     "P1Y",
        "2020-01-01",                "2020-01-01T00",
        "2020-01-01T00:00",          "2020-01-01T00:00:00",
        "2020-01-01T00:00:00.000000000", "-999999-01-01T00:00Z",
        "+999999-01-01T00:00Z",      "2025-01-01T00:00:00+00:0000",
        "2022-09-15Z",               "2022-09-15+00:00",
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
