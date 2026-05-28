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

/// The side allocation a Temporal instance's `JSObject` points to
/// through `JSObjectExtension.temporal_record`. A tagged union so
/// the single slot serves every plain Temporal type.
pub const TemporalRecord = union(TemporalKind) {
    duration: DurationRecord,
    plain_time: PlainTimeRecord,

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
    switch (classifyDatePrefix(s)) {
        .time_after_date => |rest| s = rest,
        // A date with no time separator (`2022-09-15`,
        // `2022-09-15+00:00`) carries no time component — invalid
        // for a PlainTime.
        .date_only => return error.Invalid,
        .no_date => if (s.len > 0 and (s[0] == 'T' or s[0] == 't')) {
            s = s[1..];
        },
    }

    // Split off a trailing UTC offset or `Z` designator.
    var time_part = s;
    if (splitOffset(s)) |split| {
        if (split.is_z) return error.UTCDesignator;
        time_part = split.time;
    }

    return parseBareTime(time_part) catch error.Invalid;
}

const OffsetSplit = struct { time: []const u8, is_z: bool };

/// Detect and remove a trailing UTC offset / `Z` from a time string.
/// Returns the bare-time prefix and whether a `Z` was seen. Returns
/// null when there's no offset suffix.
fn splitOffset(s: []const u8) ?OffsetSplit {
    if (s.len == 0) return null;
    const last = s[s.len - 1];
    if (last == 'Z' or last == 'z') return .{ .time = s[0 .. s.len - 1], .is_z = true };
    // Find the offset sign that begins the offset suffix. The time
    // itself never contains `+`; a `-` only appears in a date prefix
    // (already stripped). Scan from the start past the time digits /
    // colons / fraction to the first `+` or `-`.
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        if (c == '+' or c == '-') {
            return .{ .time = s[0..i], .is_z = false };
        }
    }
    return null;
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
    // Optional expanded-year sign.
    if (i < s.len and (s[i] == '+' or s[i] == '-')) {
        // Expanded year is ±YYYYYY (six digits).
        i += 1;
        if (!skipDigits(s, &i, 6)) return .no_date;
    } else {
        if (!skipDigits(s, &i, 4)) return .no_date;
    }
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

/// Parse the bare time portion: `HH`, `HH:MM`, `HH:MM:SS`,
/// `HH:MM:SS(.|,)fff`, or the compact colon-free forms. Clamps a
/// `60` seconds value (leap second) to 59.
fn parseBareTime(s: []const u8) error{Invalid}!PlainTimeRecord {
    if (s.len < 2) return error.Invalid;
    var i: usize = 0;
    const hour = read2(s, &i) orelse return error.Invalid;
    var minute: u32 = 0;
    var second: u32 = 0;
    var sub_ns: u32 = 0;
    const extended = i < s.len and s[i] == ':';

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
            if (i < s.len and s[i] >= '0' and s[i] <= '9') {
                second = read2(s, &i) orelse return error.Invalid;
            }
            sub_ns = try readFraction(s, &i);
        } else if (s[i] == '.' or s[i] == ',') {
            // `HH.fff` — no minutes/seconds but a fraction is invalid
            // for the bare-hour form per the grammar.
            return error.Invalid;
        }
    }
    if (i != s.len) return error.Invalid;

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

// ── Tests ─────────────────────────────────────────────────────────────────

const testing = std.testing;

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
}
