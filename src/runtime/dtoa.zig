//! Exact decimal conversion for the §21.1.3 Number formatters.
//!
//! ECMA-262 §21.1.3.3 (`toFixed`), §21.1.3.2 (`toExponential`) and
//! §21.1.3.5 (`toPrecision`) all phrase rounding in terms of the
//! *exact mathematical value* of the receiver: "Let n be an integer
//! for which n ÷ 10^f − x is as close to zero as possible. If there
//! are two such n, pick the larger n." A libc `printf`-style
//! conversion rounds shortest-round-trip instead, so
//! `(1000000000000000128).toFixed(0)` came out `"1000000000000000100"`
//! rather than the exact `"1000000000000000128"`.
//!
//! A finite IEEE-754 double is an exact dyadic rational
//! `mantissa × 2^exponent` (53-bit mantissa). Producing the exact
//! decimal therefore reduces to integer arithmetic on
//! `mantissa × 2^exponent × 10^k`, which overflows i128 for large
//! magnitudes / high precision. This module carries a small
//! fixed-capacity bignum — `[]u32` limbs with just the multiply /
//! shift / divmod / compare needed — modelled on V8's `bignum.cc`
//! and `BignumDtoa` in `BIGNUM_DTOA_FIXED` / `BIGNUM_DTOA_PRECISION`
//! mode. Prior art: V8 `src/numbers/bignum-dtoa.cc`,
//! `fixed-dtoa.cc`; Loitsch's Grisu and Adams's Ryū both target
//! *shortest* output and so don't apply to fixed-precision rounding.
//!
//! Self-contained: nothing here touches `JSBigInt` (i128-bounded).

const std = @import("std");

// ── Fixed-capacity bignum ───────────────────────────────────────────────────
//
// A non-negative integer as base-2^32 limbs, least-significant
// first. Capacity is sized for the worst case the formatters can
// produce: a double's mantissa is < 2^53; multiplying by 10^100
// (toFixed/toExponential/toPrecision cap fractionDigits/precision
// at 100) needs ~333 bits, and scaling by 2^exponent (|exponent|
// ≤ 1074 for subnormals, +971 for the max exponent) adds at most
// ~1075 more. Round generously: 4096 bits = 128 limbs covers
// every reachable case with wide margin.
const limb_capacity = 128;

const Bignum = struct {
    limbs: [limb_capacity]u32 = std.mem.zeroes([limb_capacity]u32),
    /// Number of significant limbs; `len == 0` means the value 0.
    len: usize = 0,

    fn zero() Bignum {
        return .{};
    }

    fn fromU64(v: u64) Bignum {
        var b = Bignum{};
        if (v == 0) return b;
        b.limbs[0] = @truncate(v);
        const hi: u32 = @truncate(v >> 32);
        if (hi != 0) {
            b.limbs[1] = hi;
            b.len = 2;
        } else {
            b.len = 1;
        }
        return b;
    }

    fn isZero(self: *const Bignum) bool {
        return self.len == 0;
    }

    fn trim(self: *Bignum) void {
        while (self.len > 0 and self.limbs[self.len - 1] == 0) : (self.len -= 1) {}
    }

    /// self *= factor (a small scalar).
    fn mulSmall(self: *Bignum, factor: u32) void {
        if (factor == 0) {
            self.len = 0;
            return;
        }
        var carry: u64 = 0;
        var i: usize = 0;
        while (i < self.len) : (i += 1) {
            const prod = @as(u64, self.limbs[i]) * @as(u64, factor) + carry;
            self.limbs[i] = @truncate(prod);
            carry = prod >> 32;
        }
        while (carry != 0) {
            std.debug.assert(self.len < limb_capacity);
            self.limbs[self.len] = @truncate(carry);
            self.len += 1;
            carry >>= 32;
        }
    }

    /// self += addend (a small scalar).
    fn addSmall(self: *Bignum, addend: u32) void {
        if (addend == 0) return;
        var carry: u64 = addend;
        var i: usize = 0;
        while (carry != 0) : (i += 1) {
            if (i >= self.len) {
                std.debug.assert(i < limb_capacity);
                self.limbs[i] = 0;
                self.len = i + 1;
            }
            const sum = @as(u64, self.limbs[i]) + carry;
            self.limbs[i] = @truncate(sum);
            carry = sum >> 32;
        }
    }

    /// self <<= bits (an unbounded left shift).
    fn shiftLeft(self: *Bignum, bits: usize) void {
        if (self.isZero() or bits == 0) return;
        const limb_shift = bits / 32;
        const bit_shift: u5 = @intCast(bits % 32);
        if (bit_shift == 0) {
            // Pure limb move.
            std.debug.assert(self.len + limb_shift <= limb_capacity);
            var i: usize = self.len;
            while (i > 0) {
                i -= 1;
                self.limbs[i + limb_shift] = self.limbs[i];
            }
            var j: usize = 0;
            while (j < limb_shift) : (j += 1) self.limbs[j] = 0;
            self.len += limb_shift;
            return;
        }
        std.debug.assert(self.len + limb_shift + 1 <= limb_capacity);
        // Carry of the top limb first, then move limbs MSB→LSB so a
        // non-zero `limb_shift` never clobbers a not-yet-read source
        // limb (`limbs[i + limb_shift]` would otherwise overwrite
        // `limbs[i + 1]` before iteration i+1 reads it).
        var new_len = self.len + limb_shift;
        const top_carry = self.limbs[self.len - 1] >> @intCast(@as(u6, 32) - bit_shift);
        if (top_carry != 0) {
            self.limbs[new_len] = top_carry;
            new_len += 1;
        }
        var i: usize = self.len;
        while (i > 0) {
            i -= 1;
            const v = self.limbs[i];
            const low = if (i == 0) 0 else self.limbs[i - 1] >> @intCast(@as(u6, 32) - bit_shift);
            self.limbs[i + limb_shift] = (v << bit_shift) | low;
        }
        var j: usize = 0;
        while (j < limb_shift) : (j += 1) self.limbs[j] = 0;
        self.len = new_len;
    }

    /// self *= 10^power.
    fn mulPow10(self: *Bignum, power: u32) void {
        if (self.isZero()) return;
        var p = power;
        // 10^9 is the largest power of ten that fits a u32.
        while (p >= 9) : (p -= 9) self.mulSmall(1_000_000_000);
        if (p > 0) {
            const small: u32 = switch (p) {
                1 => 10,
                2 => 100,
                3 => 1_000,
                4 => 10_000,
                5 => 100_000,
                6 => 1_000_000,
                7 => 10_000_000,
                8 => 100_000_000,
                else => unreachable,
            };
            self.mulSmall(small);
        }
    }

    /// Compare |self| and |other|: -1, 0, or +1.
    fn compare(self: *const Bignum, other: *const Bignum) i8 {
        if (self.len != other.len) return if (self.len < other.len) -1 else 1;
        var i: usize = self.len;
        while (i > 0) {
            i -= 1;
            if (self.limbs[i] != other.limbs[i])
                return if (self.limbs[i] < other.limbs[i]) -1 else 1;
        }
        return 0;
    }

    /// self -= other. Requires self >= other.
    fn sub(self: *Bignum, other: *const Bignum) void {
        var borrow: i64 = 0;
        var i: usize = 0;
        while (i < self.len) : (i += 1) {
            const o: i64 = if (i < other.len) @as(i64, other.limbs[i]) else 0;
            var diff: i64 = @as(i64, self.limbs[i]) - o - borrow;
            if (diff < 0) {
                diff += 1 << 32;
                borrow = 1;
            } else {
                borrow = 0;
            }
            self.limbs[i] = @intCast(diff);
        }
        std.debug.assert(borrow == 0);
        self.trim();
    }

    /// Divide self by divisor (self becomes the quotient); returns
    /// the remainder. divisor must be non-zero.
    fn divModSmall(self: *Bignum, divisor: u32) u32 {
        var rem: u64 = 0;
        var i: usize = self.len;
        while (i > 0) {
            i -= 1;
            const cur = (rem << 32) | self.limbs[i];
            self.limbs[i] = @intCast(cur / divisor);
            rem = cur % divisor;
        }
        self.trim();
        return @intCast(rem);
    }
};

// ── Double decomposition ────────────────────────────────────────────────────

const Decomposed = struct {
    /// Significand as an integer; the double's value is
    /// `mantissa × 2^exponent` (for the non-negative |x|).
    mantissa: u64,
    exponent: i32,
};

/// Decompose a finite, non-zero, positive double into
/// `mantissa × 2^exponent` exactly. IEEE-754 binary64: 52 stored
/// fraction bits, 11 exponent bits, bias 1023.
fn decompose(x: f64) Decomposed {
    const bits: u64 = @bitCast(x);
    const raw_exp: u32 = @truncate((bits >> 52) & 0x7FF);
    const raw_frac: u64 = bits & 0xF_FFFF_FFFF_FFFF;
    if (raw_exp == 0) {
        // Subnormal: value = raw_frac × 2^(1 - 1023 - 52).
        return .{ .mantissa = raw_frac, .exponent = 1 - 1023 - 52 };
    }
    // Normal: value = (2^52 + raw_frac) × 2^(raw_exp - 1023 - 52).
    return .{
        .mantissa = raw_frac | (1 << 52),
        .exponent = @as(i32, @intCast(raw_exp)) - 1023 - 52,
    };
}

// ── Exact fixed-point conversion (toFixed) ──────────────────────────────────

/// Result of an exact decimal conversion: the significant digits
/// (no leading zero, no sign) and a base-10 point exponent. The
/// represented magnitude is `0.<digits> × 10^(point_exp)` — i.e.
/// `point_exp` is the power of ten of the digit just left of the
/// decimal point + 1. For `digits = "123"`, `point_exp = 3` means
/// `123`, `point_exp = 1` means `1.23`, `point_exp = 0` means
/// `0.123`. `digits` is empty only for the value zero.
pub const Decimal = struct {
    buf: [128]u8 = undefined,
    len: usize = 0,
    point_exp: i32 = 0,

    pub fn digits(self: *const Decimal) []const u8 {
        return self.buf[0..self.len];
    }
};

/// §21.1.3.3 toFixed step 8 — compute `n`, the integer for which
/// `n ÷ 10^f − x` is closest to zero (ties → larger n), for a
/// finite, non-negative `x` with `x < 10^21`. Returns `n`'s decimal
/// digits with no leading zeros ("0" for n = 0).
///
/// `x = mantissa × 2^exponent`, so
/// `x × 10^f = mantissa × 2^exponent × 10^f`. We form numerator and
/// denominator integers, then `n = round(numerator / denominator)`
/// with ties-to-larger.
pub fn fixedDigits(x: f64, frac_digits: u32, out: *Decimal) void {
    std.debug.assert(x >= 0);
    if (x == 0) {
        out.buf[0] = '0';
        out.len = 1;
        out.point_exp = 1;
        return;
    }
    const d = decompose(x);

    // n = round(mantissa × 2^exponent × 10^frac_digits).
    // Split the binary exponent into the numerator (positive part)
    // and the denominator (negative part). 10^f always lands in the
    // numerator.
    var numerator = Bignum.fromU64(d.mantissa);
    var denominator = Bignum.fromU64(1);

    if (d.exponent >= 0) {
        numerator.shiftLeft(@intCast(d.exponent));
    } else {
        denominator.shiftLeft(@intCast(-d.exponent));
    }
    numerator.mulPow10(frac_digits);

    // n = numerator / denominator, rounded to nearest, ties up.
    var quotient = divRoundNearestTiesUp(&numerator, &denominator);
    writeBignumDigits(&quotient, out);
    out.point_exp = @intCast(out.len); // integer value
}

/// Exact `floor(log10(x))` for a finite, positive `x` decomposed
/// into `mantissa × 2^exponent`. `std.math.log10` is used as a fast
/// first guess, then corrected against exact bignum comparisons so
/// the result is right at every decimal boundary (e.g. the f64
/// nearest `1e-21` is just below `1e-21`, so its true exponent is
/// −22, not −21).
fn exactFloorLog10(d: Decomposed, x: f64) i32 {
    var e: i32 = @intFromFloat(@floor(std.math.log10(x)));
    // Invariant we want: 10^e ≤ x < 10^(e+1), i.e.
    //   numerator / denominator ∈ [10^e, 10^(e+1)).
    // x = mantissa · 2^exponent. Compare against 10^e by clearing
    // denominators: build `value = mantissa · 2^exponent` as a
    // num/den pair and `pow = 10^e` likewise.
    while (true) {
        // lo = x ≥ 10^e ?  hi = x < 10^(e+1) ?
        if (compareValueToPow10(d, e) < 0) {
            e -= 1;
        } else if (compareValueToPow10(d, e + 1) >= 0) {
            e += 1;
        } else {
            return e;
        }
    }
}

/// Compare `x` (= `d.mantissa · 2^d.exponent`) against `10^p`.
/// Returns -1, 0, +1. `p` may be negative.
fn compareValueToPow10(d: Decomposed, p: i32) i8 {
    // x vs 10^p  ⇔  mantissa·2^exponent vs 10^p.
    // Clear the negative exponents: build
    //   lhs = mantissa · 2^max(exponent,0) · 10^max(-p,0)
    //   rhs = 1        · 2^max(-exponent,0) · 10^max(p,0)
    var lhs = Bignum.fromU64(d.mantissa);
    var rhs = Bignum.fromU64(1);
    if (d.exponent >= 0) {
        lhs.shiftLeft(@intCast(d.exponent));
    } else {
        rhs.shiftLeft(@intCast(-d.exponent));
    }
    if (p >= 0) {
        rhs.mulPow10(@intCast(p));
    } else {
        lhs.mulPow10(@intCast(-p));
    }
    return lhs.compare(&rhs);
}

/// §21.1.3.2 / §21.1.3.5 — produce exactly `count` significant
/// decimal digits of a finite, non-negative, non-zero `x`, rounded
/// to nearest with ties-to-larger, and the corresponding base-10
/// point exponent. `count` is in [1, 101].
///
/// Strategy mirrors V8's BignumDtoa precision mode: find the
/// decimal exponent `e = floor(log10(x))` exactly, then compute
/// `n = round(x / 10^(e + 1 - count))` — an integer with `count`
/// digits (occasionally `count + 1` after a rounding carry, e.g.
/// 9.99→10.0, which we renormalise by bumping `e`).
pub fn precisionDigits(x: f64, count: u32, out: *Decimal) void {
    std.debug.assert(x > 0);
    std.debug.assert(count >= 1);
    const d = decompose(x);

    var e: i32 = exactFloorLog10(d, x);

    while (true) {
        var numerator = Bignum.fromU64(d.mantissa);
        var denominator = Bignum.fromU64(1);
        if (d.exponent >= 0) {
            numerator.shiftLeft(@intCast(d.exponent));
        } else {
            denominator.shiftLeft(@intCast(-d.exponent));
        }
        // scale = count - 1 - e. Positive → multiply numerator by
        // 10^scale; negative → multiply denominator by 10^-scale.
        const scale: i32 = @as(i32, @intCast(count)) - 1 - e;
        if (scale >= 0) {
            numerator.mulPow10(@intCast(scale));
        } else {
            denominator.mulPow10(@intCast(-scale));
        }
        var quotient = divRoundNearestTiesUp(&numerator, &denominator);
        writeBignumDigits(&quotient, out);
        if (out.len == count + 1) {
            // Rounding carried into a new digit (e.g. 9.99→10.0 at
            // count=2). The true exponent is e+1; recompute with the
            // bumped exponent so the digit string is `count` long.
            e += 1;
            continue;
        }
        // `exactFloorLog10` pins `e` exactly, so `n` has `count`
        // digits in every other case.
        std.debug.assert(out.len == count);
        out.point_exp = e + 1;
        return;
    }
}

/// Divide `num` by `den`, rounding the quotient to the nearest
/// integer with ties resolved toward the larger value. Both are
/// consumed. Returns the quotient as a Bignum.
fn divRoundNearestTiesUp(num: *Bignum, den: *const Bignum) Bignum {
    // Long division by repeated subtraction would be O(quotient);
    // instead divide limb-aware. The denominator here is at most a
    // shifted power of two times a power of ten — but to stay
    // general we use schoolbook division via binary search per
    // quotient limb. Simpler and sufficient for these magnitudes:
    // a normalising-shift Knuth division.
    var quotient = Bignum.zero();
    if (num.compare(den) < 0) {
        // Quotient is 0; check whether remainder ≥ den/2 → round to 1.
        if (remainderGEHalf(num, den)) quotient = Bignum.fromU64(1);
        return quotient;
    }
    // General case: compute quotient and remainder by binary long
    // division, MSB-first, one bit at a time. The bit count is
    // bounded (≤ ~4400 here) so this is fast enough for a formatter.
    const num_bits = bitLength(num);
    var rem = Bignum.zero();
    var bit: usize = num_bits;
    while (bit > 0) {
        bit -= 1;
        rem.shiftLeft(1);
        if (getBit(num, bit)) rem.addSmall(1);
        if (rem.compare(den) >= 0) {
            rem.sub(den);
            setBit(&quotient, bit);
        }
    }
    quotient.trim();
    // Round: compare 2*rem with den.
    var twice = rem;
    twice.shiftLeft(1);
    const cmp = twice.compare(den);
    if (cmp > 0 or cmp == 0) {
        // rem > den/2, or exactly den/2 (tie → larger) → round up.
        quotient.addSmall(1);
    }
    return quotient;
}

/// True iff `rem` (a value < den) is ≥ den/2 — used when the
/// quotient is 0 and we still need ties-to-larger rounding.
fn remainderGEHalf(rem: *const Bignum, den: *const Bignum) bool {
    var twice = rem.*;
    twice.shiftLeft(1);
    return twice.compare(den) >= 0;
}

fn bitLength(b: *const Bignum) usize {
    if (b.isZero()) return 0;
    const top = b.limbs[b.len - 1];
    const top_bits: usize = 32 - @clz(top);
    return (b.len - 1) * 32 + top_bits;
}

fn getBit(b: *const Bignum, bit: usize) bool {
    const limb = bit / 32;
    if (limb >= b.len) return false;
    return (b.limbs[limb] >> @intCast(bit % 32)) & 1 == 1;
}

fn setBit(b: *Bignum, bit: usize) void {
    const limb = bit / 32;
    std.debug.assert(limb < limb_capacity);
    if (limb >= b.len) {
        var i = b.len;
        while (i <= limb) : (i += 1) b.limbs[i] = 0;
        b.len = limb + 1;
    }
    b.limbs[limb] |= @as(u32, 1) << @intCast(bit % 32);
}

/// Render `value`'s decimal digits into `out.buf` (no leading
/// zeros; "0" for zero). Sets only `out.buf` / `out.len`.
fn writeBignumDigits(value: *Bignum, out: *Decimal) void {
    if (value.isZero()) {
        out.buf[0] = '0';
        out.len = 1;
        return;
    }
    // Extract digits least-significant-first, then reverse.
    var tmp: [128]u8 = undefined;
    var n: usize = 0;
    while (!value.isZero()) {
        const digit = value.divModSmall(10);
        tmp[n] = '0' + @as(u8, @intCast(digit));
        n += 1;
    }
    var i: usize = 0;
    while (i < n) : (i += 1) out.buf[i] = tmp[n - 1 - i];
    out.len = n;
}

// ── Unit tests ──────────────────────────────────────────────────────────────

test "Bignum: fromU64 / digits round-trip" {
    var b = Bignum.fromU64(1234567890123456789);
    var out = Decimal{};
    writeBignumDigits(&b, &out);
    try std.testing.expectEqualStrings("1234567890123456789", out.digits());
}

test "Bignum: mulPow10 produces exact powers of ten" {
    var b = Bignum.fromU64(1);
    b.mulPow10(30);
    var out = Decimal{};
    writeBignumDigits(&b, &out);
    try std.testing.expectEqualStrings("1000000000000000000000000000000", out.digits());
}

test "Bignum: shiftLeft by a large bit count" {
    var b = Bignum.fromU64(1);
    b.shiftLeft(100); // 2^100 = 1267650600228229401496703205376
    var out = Decimal{};
    writeBignumDigits(&b, &out);
    try std.testing.expectEqualStrings("1267650600228229401496703205376", out.digits());
}

test "fixedDigits: exact representable integer beyond f64 precision" {
    // §21.1.3.3 — (1000000000000000128).toFixed(0). The exact f64
    // value is 1000000000000000128; ToString rounds it shortest to
    // 1000000000000000100, but toFixed must emit the exact value.
    const x: f64 = 1000000000000000128.0;
    var out = Decimal{};
    fixedDigits(x, 0, &out);
    try std.testing.expectEqualStrings("1000000000000000128", out.digits());
}

test "fixedDigits: simple fractions round per spec" {
    // (1.005).toFixed(2) — the f64 nearest 1.005 is slightly below,
    // so the exact answer is "100" scaled (1.00), not 1.01.
    {
        var out = Decimal{};
        fixedDigits(1.005, 2, &out);
        try std.testing.expectEqualStrings("100", out.digits());
    }
    // (2.5).toFixed(0) — exact 2.5, tie → larger → 3.
    {
        var out = Decimal{};
        fixedDigits(2.5, 0, &out);
        try std.testing.expectEqualStrings("3", out.digits());
    }
    // (0.1).toFixed(1) → 1 (i.e. 0.1).
    {
        var out = Decimal{};
        fixedDigits(0.1, 1, &out);
        try std.testing.expectEqualStrings("1", out.digits());
    }
    // (123.456).toFixed(2) → 12346 (12346 / 100 = 123.46).
    {
        var out = Decimal{};
        fixedDigits(123.456, 2, &out);
        try std.testing.expectEqualStrings("12346", out.digits());
    }
}

test "fixedDigits: zero" {
    var out = Decimal{};
    fixedDigits(0.0, 5, &out);
    try std.testing.expectEqualStrings("0", out.digits());
}

test "precisionDigits: exact significant digits of 123.456" {
    // (123.456).toExponential(17) → 1.23456000000000003e+2.
    var out = Decimal{};
    precisionDigits(123.456, 18, &out);
    try std.testing.expectEqualStrings("123456000000000003", out.digits());
    try std.testing.expectEqual(@as(i32, 3), out.point_exp);
}

test "precisionDigits: rounding carries into a new digit" {
    // (0.9999).toExponential(2) → "1.00e+0": 4 sig digits of 0.9999
    // rounds 9999→10000, so 3-digit request 999.9→1.00.
    var out = Decimal{};
    precisionDigits(0.9999, 3, &out);
    try std.testing.expectEqualStrings("100", out.digits());
    try std.testing.expectEqual(@as(i32, 1), out.point_exp);
}

test "precisionDigits: 25 to one significant digit rounds to 3e+1" {
    var out = Decimal{};
    precisionDigits(25.0, 1, &out);
    try std.testing.expectEqualStrings("3", out.digits());
    try std.testing.expectEqual(@as(i32, 2), out.point_exp);
}

test "precisionDigits: large magnitude exact digits" {
    // (1.2345e+27).toPrecision(20) → "1.2344999999999999618e+27".
    var out = Decimal{};
    precisionDigits(1.2345e27, 20, &out);
    try std.testing.expectEqualStrings("12344999999999999618", out.digits());
    try std.testing.expectEqual(@as(i32, 28), out.point_exp);
}

test "precisionDigits: tiny subnormal-range magnitude" {
    // (1e-21).toPrecision(16) → "9.999999999999999e-22".
    var out = Decimal{};
    precisionDigits(1e-21, 16, &out);
    try std.testing.expectEqualStrings("9999999999999999", out.digits());
    try std.testing.expectEqual(@as(i32, -21), out.point_exp);
}
