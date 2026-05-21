//! `JSBigInt` — arbitrary-precision integer primitive (§6.1.6.2).
//!
//! Representation: sign-magnitude. A `sign` flag (true = negative)
//! plus a heap-owned little-endian `limbs: []Limb` magnitude. The
//! magnitude is always *normalized* — the most-significant limb is
//! non-zero, so a zero BigInt has `limbs.len == 0` and `sign ==
//! false`. This mirrors V8's `JSBigInt` (sign bit + digit array)
//! and JavaScriptCore's `JSBigInt` (sign flag + `Digit` array);
//! QuickJS instead delegates to `libbf`. Sign-magnitude is the
//! standard choice for a from-scratch bignum because every JS
//! operator (§6.1.6.2) is defined on the *mathematical* integer,
//! so a two's-complement backing would force constant
//! normalization at every boundary.
//!
//! The limb array is owned by the `JSBigInt`: `init*` allocates it,
//! `deinit` frees it. The GC marker (`Heap.markValue`) only sets
//! the `marked` bit — a BigInt holds no nested heap pointers, so
//! the limb slice never needs a separate mark walk, but it MUST be
//! freed in `deinit` when the object is swept.
//!
//! Identity is by-value, NOT by-pointer (§7.2.13 IsLooselyEqual
//! step 8 + SameValue rules treat BigInts numerically). Two
//! `1n` literals compare strict-equal even if allocated as
//! distinct heap entries.
//!
//! Encoding: pointer-tagged in the NaN-boxed `Value` via the
//! `tag_object` value-tag plus a 3-bit pointer-tag (`0b11`)
//! to distinguish from JSFunction (`0b00`) / JSObject (`0b01`)
//! / JSSymbol (`0b10`). See heap.zig for the full layout.

const std = @import("std");

const HeapKind = @import("function.zig").HeapKind;

/// A single magnitude limb. 64-bit; the magnitude is the
/// little-endian base-2^64 expansion of |value|.
pub const Limb = u64;
const limb_bits = 64;

pub const ParseError = error{ InvalidBigInt, OutOfMemory };

pub const JSBigInt = struct {
    /// Discriminator — must remain the first field. Mirrors the
    /// shape of `JSFunction` / `JSObject` / `JSSymbol`.
    kind: HeapKind = .bigint,
    /// Sign of the value: true ⇒ negative. Zero is always
    /// `sign == false` (there is no negative zero BigInt).
    sign: bool = false,
    /// Little-endian base-2^64 magnitude, normalized: the last
    /// limb (most significant) is non-zero. An empty slice is the
    /// canonical zero. Heap-owned; freed by `deinit`.
    limbs: []Limb = &.{},
    /// Mark-sweep bit, written by `Heap.markValue`.
    marked: bool = false,
    /// Generational-GC age. Fresh allocations start `.young`; a
    /// young bigint surviving a `collectYoung` is promoted to
    /// `.mature` and relinked into the mature list.
    generation: @import("heap.zig").Generation = .young,
    /// Set when this bigint is in the heap's remembered set as a
    /// known old→young store source. BigInts are immutable so
    /// this stays `false`; the field keeps headers uniform.
    in_remembered_set: bool = false,

    // ── Construction ────────────────────────────────────────────

    /// Allocate a `JSBigInt` from a signed 128-bit value. The
    /// historical entry point — kept so call sites that already
    /// have an `i128` (typed-array reads, small literals) don't
    /// need to build a limb array by hand.
    pub fn init(allocator: std.mem.Allocator, value: i128) !*JSBigInt {
        const neg = value < 0;
        // Take the magnitude in u128 space. `-minInt(i128)` would
        // overflow i128, so cast through u128 before negating.
        const mag: u128 = if (neg)
            (~@as(u128, @bitCast(value))) +% 1
        else
            @intCast(value);
        var limbs_buf: [2]Limb = .{
            @truncate(mag),
            @truncate(mag >> 64),
        };
        const used = magUsedLen(&limbs_buf);
        return initFromLimbs(allocator, neg and used != 0, limbs_buf[0..used]);
    }

    /// Allocate a `JSBigInt` taking ownership of a normalized
    /// limb slice. `limbs_owned` must already be heap-allocated by
    /// `allocator` and normalized (no trailing zero limb); the new
    /// `JSBigInt` owns it directly — no copy.
    pub fn initOwned(allocator: std.mem.Allocator, sign: bool, limbs_owned: []Limb) !*JSBigInt {
        std.debug.assert(limbs_owned.len == 0 or limbs_owned[limbs_owned.len - 1] != 0);
        const b = try allocator.create(JSBigInt);
        b.* = .{ .sign = if (limbs_owned.len == 0) false else sign, .limbs = limbs_owned };
        return b;
    }

    /// Allocate a `JSBigInt` copying `limbs_src` (which need not be
    /// pre-normalized — trailing zero limbs are dropped).
    pub fn initFromLimbs(allocator: std.mem.Allocator, sign: bool, limbs_src: []const Limb) !*JSBigInt {
        const used = magUsedLen(limbs_src);
        if (used == 0) return initOwned(allocator, false, &.{});
        const owned = try allocator.alloc(Limb, used);
        @memcpy(owned, limbs_src[0..used]);
        return initOwned(allocator, sign, owned);
    }

    pub fn deinit(self: *JSBigInt, allocator: std.mem.Allocator) void {
        if (self.limbs.len != 0) allocator.free(self.limbs);
        allocator.destroy(self);
    }

    // ── Observers ───────────────────────────────────────────────

    pub fn isZero(self: *const JSBigInt) bool {
        return self.limbs.len == 0;
    }

    pub fn isNegative(self: *const JSBigInt) bool {
        return self.sign;
    }

    /// Bit length of the magnitude (§6.1.6.2 — number of bits in
    /// |value|). Zero has bit length 0.
    pub fn bitLength(self: *const JSBigInt) usize {
        return magBitLength(self.limbs);
    }

    /// Truncate the value to a signed 64-bit two's-complement
    /// integer — exactly what `BigInt64Array` element stores and
    /// `DataView.prototype.setBigInt64` need (§6.1.6.2 / §25.x).
    /// Wraps mod 2^64.
    pub fn toI64Truncating(self: *const JSBigInt) i64 {
        return @bitCast(self.toU64Truncating());
    }

    /// Truncate the value to an unsigned 64-bit integer (mod 2^64).
    pub fn toU64Truncating(self: *const JSBigInt) u64 {
        const low: u64 = if (self.limbs.len == 0) 0 else self.limbs[0];
        if (!self.sign) return low;
        // Negative: two's-complement of the low limb.
        return (~low) +% 1;
    }

    /// Convert to f64 (§6.1.6.2 — used by Number(bigint) and
    /// BigInt-vs-Number comparison fallbacks). Lossy for
    /// magnitudes beyond 2^53; rounds toward the nearest double
    /// the way `@floatFromInt` would for an exact integer.
    pub fn toF64(self: *const JSBigInt) f64 {
        if (self.limbs.len == 0) return 0.0;
        var acc: f64 = 0.0;
        var i: usize = self.limbs.len;
        while (i > 0) {
            i -= 1;
            acc = acc * 18446744073709551616.0 + @as(f64, @floatFromInt(self.limbs[i]));
        }
        return if (self.sign) -acc else acc;
    }

    /// True iff the value fits exactly in an i128 — lets callers
    /// keep the cheap fixed-width path when possible.
    pub fn fitsI128(self: *const JSBigInt) bool {
        if (self.limbs.len < 2) return true;
        if (self.limbs.len > 2) return false;
        const hi = self.limbs[1];
        // i128 magnitude max is 2^127; the negative side reaches
        // exactly 2^127.
        if (self.sign) return hi <= (@as(u64, 1) << 63);
        return hi < (@as(u64, 1) << 63);
    }

    /// Return the exact i128 value. Caller must have checked
    /// `fitsI128()`.
    pub fn toI128(self: *const JSBigInt) i128 {
        var mag: u128 = 0;
        if (self.limbs.len >= 1) mag |= self.limbs[0];
        if (self.limbs.len >= 2) mag |= @as(u128, self.limbs[1]) << 64;
        if (self.sign) {
            return @bitCast((~mag) +% 1);
        }
        return @intCast(mag);
    }
};

// ─────────────────────────────────────────────────────────────────
// Magnitude helpers — operate on `[]const Limb` little-endian
// slices. `mag*` functions never look at sign; the signed
// operations layer on top.
// ─────────────────────────────────────────────────────────────────

/// Number of significant limbs in `m` (drops trailing zeros).
fn magUsedLen(m: []const Limb) usize {
    var n = m.len;
    while (n > 0 and m[n - 1] == 0) n -= 1;
    return n;
}

/// Bit length of the magnitude slice (already-or-not normalized).
fn magBitLength(m: []const Limb) usize {
    const used = magUsedLen(m);
    if (used == 0) return 0;
    const top = m[used - 1];
    return (used - 1) * limb_bits + (limb_bits - @clz(top));
}

/// Compare two magnitudes. Returns .lt / .eq / .gt.
fn magCmp(a: []const Limb, b: []const Limb) std.math.Order {
    const an = magUsedLen(a);
    const bn = magUsedLen(b);
    if (an != bn) return if (an < bn) .lt else .gt;
    var i = an;
    while (i > 0) {
        i -= 1;
        if (a[i] != b[i]) return if (a[i] < b[i]) .lt else .gt;
    }
    return .eq;
}

/// Allocate a normalized magnitude = a + b.
fn magAdd(allocator: std.mem.Allocator, a: []const Limb, b: []const Limb) ![]Limb {
    const an = magUsedLen(a);
    const bn = magUsedLen(b);
    const n = @max(an, bn);
    var out = try allocator.alloc(Limb, n + 1);
    errdefer allocator.free(out);
    var carry: u1 = 0;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const av: Limb = if (i < an) a[i] else 0;
        const bv: Limb = if (i < bn) b[i] else 0;
        const s1 = @addWithOverflow(av, bv);
        const s2 = @addWithOverflow(s1[0], carry);
        out[i] = s2[0];
        carry = s1[1] | s2[1];
    }
    out[n] = carry;
    return normalizeOwned(allocator, out);
}

/// Allocate a normalized magnitude = a - b. Caller MUST guarantee
/// magCmp(a, b) != .lt (a ≥ b).
fn magSub(allocator: std.mem.Allocator, a: []const Limb, b: []const Limb) ![]Limb {
    const an = magUsedLen(a);
    const bn = magUsedLen(b);
    std.debug.assert(an >= bn);
    var out = try allocator.alloc(Limb, an);
    errdefer allocator.free(out);
    var borrow: u1 = 0;
    var i: usize = 0;
    while (i < an) : (i += 1) {
        const av: Limb = a[i];
        const bv: Limb = if (i < bn) b[i] else 0;
        const d1 = @subWithOverflow(av, bv);
        const d2 = @subWithOverflow(d1[0], borrow);
        out[i] = d2[0];
        borrow = d1[1] | d2[1];
    }
    std.debug.assert(borrow == 0);
    return normalizeOwned(allocator, out);
}

/// Allocate a normalized magnitude = a * b (schoolbook O(n·m)).
fn magMul(allocator: std.mem.Allocator, a: []const Limb, b: []const Limb) ![]Limb {
    const an = magUsedLen(a);
    const bn = magUsedLen(b);
    if (an == 0 or bn == 0) return allocator.alloc(Limb, 0);
    var out = try allocator.alloc(Limb, an + bn);
    errdefer allocator.free(out);
    @memset(out, 0);
    var i: usize = 0;
    while (i < an) : (i += 1) {
        var carry: Limb = 0;
        const av: u128 = a[i];
        var j: usize = 0;
        while (j < bn) : (j += 1) {
            const prod: u128 = av * @as(u128, b[j]) + @as(u128, out[i + j]) + @as(u128, carry);
            out[i + j] = @truncate(prod);
            carry = @truncate(prod >> 64);
        }
        out[i + bn] += carry;
    }
    return normalizeOwned(allocator, out);
}

/// Shift a magnitude left by `bits`. Allocates a normalized result.
fn magShlBits(allocator: std.mem.Allocator, a: []const Limb, bits: usize) ![]Limb {
    const an = magUsedLen(a);
    if (an == 0) return allocator.alloc(Limb, 0);
    const limb_shift = bits / limb_bits;
    const bit_shift: u6 = @intCast(bits % limb_bits);
    var out = try allocator.alloc(Limb, an + limb_shift + 1);
    errdefer allocator.free(out);
    @memset(out, 0);
    if (bit_shift == 0) {
        @memcpy(out[limb_shift..][0..an], a[0..an]);
    } else {
        var carry: Limb = 0;
        var i: usize = 0;
        while (i < an) : (i += 1) {
            const v = a[i];
            out[limb_shift + i] = (v << bit_shift) | carry;
            carry = v >> @intCast(limb_bits - @as(usize, bit_shift));
        }
        out[limb_shift + an] = carry;
    }
    return normalizeOwned(allocator, out);
}

/// Logical right shift of a magnitude by `bits` (drops low bits).
/// Allocates a normalized result.
fn magShrBits(allocator: std.mem.Allocator, a: []const Limb, bits: usize) ![]Limb {
    const an = magUsedLen(a);
    const limb_shift = bits / limb_bits;
    if (limb_shift >= an) return allocator.alloc(Limb, 0);
    const bit_shift: u6 = @intCast(bits % limb_bits);
    const rem = an - limb_shift;
    var out = try allocator.alloc(Limb, rem);
    errdefer allocator.free(out);
    if (bit_shift == 0) {
        @memcpy(out, a[limb_shift..][0..rem]);
    } else {
        var i: usize = 0;
        while (i < rem) : (i += 1) {
            const lo = a[limb_shift + i] >> bit_shift;
            const hi: Limb = if (limb_shift + i + 1 < an)
                a[limb_shift + i + 1] << @intCast(limb_bits - @as(usize, bit_shift))
            else
                0;
            out[i] = lo | hi;
        }
    }
    return normalizeOwned(allocator, out);
}

/// True iff bit `idx` of the magnitude is set.
fn magBitIsSet(m: []const Limb, idx: usize) bool {
    const limb_idx = idx / limb_bits;
    if (limb_idx >= m.len) return false;
    const bit: u6 = @intCast(idx % limb_bits);
    return (m[limb_idx] >> bit) & 1 == 1;
}

/// Divide magnitude `a` by magnitude `b`, returning normalized
/// (quotient, remainder). Caller owns both. `b` must be non-zero.
fn magDivRem(allocator: std.mem.Allocator, a: []const Limb, b: []const Limb) !struct { q: []Limb, r: []Limb } {
    const an = magUsedLen(a);
    const bn = magUsedLen(b);
    std.debug.assert(bn != 0);
    if (magCmp(a, b) == .lt) {
        // a < b ⇒ quotient 0, remainder a.
        const q = try allocator.alloc(Limb, 0);
        errdefer allocator.free(q);
        const r = try allocator.alloc(Limb, an);
        @memcpy(r, a[0..an]);
        return .{ .q = q, .r = normalizeOwned(allocator, r) catch unreachable };
    }
    if (bn == 1) {
        // Fast path: single-limb divisor.
        const d: Limb = b[0];
        var q = try allocator.alloc(Limb, an);
        errdefer allocator.free(q);
        var rem: Limb = 0;
        var i: usize = an;
        while (i > 0) {
            i -= 1;
            const cur: u128 = (@as(u128, rem) << 64) | a[i];
            q[i] = @truncate(cur / d);
            rem = @truncate(cur % d);
        }
        var r = try allocator.alloc(Limb, 1);
        r[0] = rem;
        return .{
            .q = try normalizeOwned(allocator, q),
            .r = try normalizeOwned(allocator, r),
        };
    }
    // Knuth Algorithm D (TAOCP Vol. 2 §4.3.1) — normalize the
    // divisor so its top limb has its high bit set, then do
    // limb-at-a-time long division with a two-limb estimate.
    const shift: u6 = @intCast(@clz(b[bn - 1]));
    const u_norm = try magShlBits(allocator, a[0..an], shift);
    defer allocator.free(u_norm);
    const v_norm = try magShlBits(allocator, b[0..bn], shift);
    defer allocator.free(v_norm);
    const vn = magUsedLen(v_norm);
    // `u` working buffer: needs an+1 limbs (an − bn + 1 quotient
    // digits, indexed from the high end).
    var u = try allocator.alloc(Limb, an + 1);
    defer allocator.free(u);
    @memset(u, 0);
    @memcpy(u[0..u_norm.len], u_norm);
    const m = an - vn; // quotient has m+1 digits
    var q = try allocator.alloc(Limb, m + 1);
    errdefer allocator.free(q);
    @memset(q, 0);

    const v_top: u128 = v_norm[vn - 1];
    const v_second: u128 = v_norm[vn - 2];

    var j: usize = m + 1;
    while (j > 0) {
        j -= 1;
        // Estimate q̂ from the top two limbs of the current window.
        const num: u128 = (@as(u128, u[j + vn]) << 64) | u[j + vn - 1];
        var qhat: u128 = num / v_top;
        var rhat: u128 = num % v_top;
        while (qhat >> 64 != 0 or
            qhat * v_second > (rhat << 64) + u[j + vn - 2])
        {
            qhat -= 1;
            rhat += v_top;
            if (rhat >> 64 != 0) break;
        }
        // Multiply-and-subtract q̂·v from the window.
        var borrow: i128 = 0;
        var carry: u128 = 0;
        var i: usize = 0;
        while (i < vn) : (i += 1) {
            const p: u128 = qhat * @as(u128, v_norm[i]) + carry;
            carry = p >> 64;
            const diff: i128 = @as(i128, u[j + i]) - @as(i128, @as(u64, @truncate(p))) - borrow;
            u[j + i] = @bitCast(@as(u64, @truncate(@as(u128, @bitCast(diff)))));
            borrow = if (diff < 0) 1 else 0;
        }
        const sub_top: i128 = @as(i128, u[j + vn]) - @as(i128, @as(u64, @truncate(carry))) - borrow;
        u[j + vn] = @bitCast(@as(u64, @truncate(@as(u128, @bitCast(sub_top)))));
        if (sub_top < 0) {
            // Estimate was one too large — add v back.
            qhat -= 1;
            var add_carry: u1 = 0;
            i = 0;
            while (i < vn) : (i += 1) {
                const s1 = @addWithOverflow(u[j + i], v_norm[i]);
                const s2 = @addWithOverflow(s1[0], add_carry);
                u[j + i] = s2[0];
                add_carry = s1[1] | s2[1];
            }
            u[j + vn] +%= add_carry;
        }
        q[j] = @truncate(qhat);
    }
    // Remainder = (normalized u, low vn limbs) >> shift.
    const r = try magShrBits(allocator, u[0..vn], shift);
    return .{
        .q = try normalizeOwned(allocator, q),
        .r = r,
    };
}

/// Re-slice `owned` down to its used length, freeing the tail.
/// Takes ownership; returns a slice the caller owns. An all-zero
/// input is freed entirely and replaced with an empty slice.
fn normalizeOwned(allocator: std.mem.Allocator, owned: []Limb) ![]Limb {
    const used = magUsedLen(owned);
    if (used == owned.len) return owned;
    if (used == 0) {
        allocator.free(owned);
        return allocator.alloc(Limb, 0);
    }
    // `realloc` to shrink — guaranteed to succeed for a shrink.
    return allocator.realloc(owned, used) catch owned[0..used];
}

// ─────────────────────────────────────────────────────────────────
// Signed arithmetic — `BigIntValue` is a sign + owned magnitude
// pair the runtime layer turns into a `JSBigInt`. Every `*` here
// allocates a fresh result; the caller owns the returned `limbs`.
// ─────────────────────────────────────────────────────────────────

pub const BigIntValue = struct {
    sign: bool,
    limbs: []Limb,

    pub fn isZero(self: BigIntValue) bool {
        return self.limbs.len == 0;
    }
};

/// §6.1.6.2.7 BigInt::add.
pub fn add(allocator: std.mem.Allocator, a: BigIntValue, b: BigIntValue) !BigIntValue {
    if (a.sign == b.sign) {
        return .{ .sign = a.sign, .limbs = try magAdd(allocator, a.limbs, b.limbs) };
    }
    // Opposite signs → subtract the smaller magnitude.
    return subMagnitudes(allocator, a, b);
}

/// §6.1.6.2.8 BigInt::subtract.
pub fn sub(allocator: std.mem.Allocator, a: BigIntValue, b: BigIntValue) !BigIntValue {
    if (a.sign != b.sign) {
        return .{ .sign = a.sign, .limbs = try magAdd(allocator, a.limbs, b.limbs) };
    }
    // Same sign → subtract magnitudes; result sign follows which
    // magnitude is larger.
    return subMagnitudes(allocator, a, .{ .sign = !b.sign, .limbs = b.limbs });
}

/// Helper for add/sub: compute a + b where the two have opposite
/// signs (so the magnitudes subtract). Result sign = sign of the
/// operand with the larger magnitude.
fn subMagnitudes(allocator: std.mem.Allocator, a: BigIntValue, b: BigIntValue) !BigIntValue {
    switch (magCmp(a.limbs, b.limbs)) {
        .eq => return .{ .sign = false, .limbs = try allocator.alloc(Limb, 0) },
        .gt => return .{ .sign = a.sign, .limbs = try magSub(allocator, a.limbs, b.limbs) },
        .lt => return .{ .sign = b.sign, .limbs = try magSub(allocator, b.limbs, a.limbs) },
    }
}

/// §6.1.6.2.4 BigInt::multiply.
pub fn mul(allocator: std.mem.Allocator, a: BigIntValue, b: BigIntValue) !BigIntValue {
    const limbs = try magMul(allocator, a.limbs, b.limbs);
    const result_sign = (a.sign != b.sign) and limbs.len != 0;
    return .{ .sign = result_sign, .limbs = limbs };
}

/// §6.1.6.2.5 BigInt::divide — truncated toward zero. Caller must
/// reject a zero `b` (RangeError) before calling.
pub fn divide(allocator: std.mem.Allocator, a: BigIntValue, b: BigIntValue) !BigIntValue {
    std.debug.assert(!b.isZero());
    const dr = try magDivRem(allocator, a.limbs, b.limbs);
    allocator.free(dr.r);
    const result_sign = (a.sign != b.sign) and dr.q.len != 0;
    return .{ .sign = result_sign, .limbs = dr.q };
}

/// §6.1.6.2.6 BigInt::remainder — sign follows the dividend
/// (truncated division). Caller must reject a zero `b`.
pub fn remainder(allocator: std.mem.Allocator, a: BigIntValue, b: BigIntValue) !BigIntValue {
    std.debug.assert(!b.isZero());
    const dr = try magDivRem(allocator, a.limbs, b.limbs);
    allocator.free(dr.q);
    const result_sign = a.sign and dr.r.len != 0;
    return .{ .sign = result_sign, .limbs = dr.r };
}

/// §6.1.6.2.3 BigInt::exponentiate. `exp` must be non-negative
/// (caller throws RangeError otherwise). Square-and-multiply.
pub fn pow(allocator: std.mem.Allocator, base: BigIntValue, exp: BigIntValue) !BigIntValue {
    std.debug.assert(!exp.sign);
    // x ** 0n === 1n.
    if (exp.isZero()) {
        const one = try allocator.alloc(Limb, 1);
        one[0] = 1;
        return .{ .sign = false, .limbs = one };
    }
    if (base.isZero()) return .{ .sign = false, .limbs = try allocator.alloc(Limb, 0) };
    // Result sign: negative iff base negative AND exponent odd.
    const result_sign = base.sign and magBitIsSet(exp.limbs, 0);

    var acc_limbs = try allocator.alloc(Limb, 1);
    acc_limbs[0] = 1;
    var cur_limbs = try allocator.dupe(Limb, base.limbs);
    defer allocator.free(cur_limbs);
    defer allocator.free(acc_limbs);

    const bits = magBitLength(exp.limbs);
    var i: usize = 0;
    while (i < bits) : (i += 1) {
        if (magBitIsSet(exp.limbs, i)) {
            const next = try magMul(allocator, acc_limbs, cur_limbs);
            allocator.free(acc_limbs);
            acc_limbs = next;
        }
        if (i + 1 < bits) {
            const sq = try magMul(allocator, cur_limbs, cur_limbs);
            allocator.free(cur_limbs);
            cur_limbs = sq;
        }
    }
    const out = try allocator.dupe(Limb, acc_limbs);
    return .{ .sign = result_sign and out.len != 0, .limbs = out };
}

/// §6.1.6.2.1 BigInt::unaryMinus — negate. Allocates a copy.
pub fn negate(allocator: std.mem.Allocator, a: BigIntValue) !BigIntValue {
    const limbs = try allocator.dupe(Limb, a.limbs);
    return .{ .sign = if (limbs.len == 0) false else !a.sign, .limbs = limbs };
}

/// §6.1.6.2.2 BigInt::bitwiseNOT — ~x = -(x + 1).
pub fn bitwiseNot(allocator: std.mem.Allocator, a: BigIntValue) !BigIntValue {
    var one_mag = [_]Limb{1};
    const one = BigIntValue{ .sign = false, .limbs = one_mag[0..] };
    const inc = try add(allocator, a, one);
    return .{ .sign = if (inc.limbs.len == 0) false else !inc.sign, .limbs = inc.limbs };
}

/// Compare two BigInt values mathematically. Returns .lt / .eq / .gt.
pub fn compare(a: BigIntValue, b: BigIntValue) std.math.Order {
    if (a.sign != b.sign) {
        // Different signs: negative < non-negative. (Both zero is
        // sign false on both.)
        return if (a.sign) .lt else .gt;
    }
    const mag = magCmp(a.limbs, b.limbs);
    if (a.sign) {
        // Both negative — larger magnitude is the smaller value.
        return switch (mag) {
            .lt => .gt,
            .gt => .lt,
            .eq => .eq,
        };
    }
    return mag;
}

pub fn equals(a: BigIntValue, b: BigIntValue) bool {
    return compare(a, b) == .eq;
}

// ── Bitwise / shift — two's-complement over arbitrary width ──────
//
// §6.1.6.2 models BigInt bitwise ops on the *infinite-length
// two's-complement* representation of each value: a negative value
// behaves as if sign-extended with 1 bits forever. We materialise
// that view limb-by-limb: a negative magnitude `m` has
// two's-complement limbs equal to `~(m - 1)` (= `(~m) + 1`),
// truncated to whatever limb count the operation needs.

/// Produce the two's-complement limb view of `v`, sign-extended to
/// `n` limbs. Caller owns the returned slice.
fn twosComplement(allocator: std.mem.Allocator, v: BigIntValue, n: usize) ![]Limb {
    var out = try allocator.alloc(Limb, n);
    errdefer allocator.free(out);
    if (!v.sign) {
        var i: usize = 0;
        while (i < n) : (i += 1) out[i] = if (i < v.limbs.len) v.limbs[i] else 0;
        return out;
    }
    // Negative: out = ~(mag) + 1, extended with all-ones.
    var carry: u1 = 1;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const m: Limb = if (i < v.limbs.len) v.limbs[i] else 0;
        const inv = ~m;
        const s = @addWithOverflow(inv, carry);
        out[i] = s[0];
        carry = s[1];
    }
    return out;
}

/// Interpret an `n`-limb two's-complement slice (high bit of the
/// top limb is the sign) back into a sign + normalized magnitude.
/// Frees `tc`.
fn fromTwosComplement(allocator: std.mem.Allocator, tc: []Limb) !BigIntValue {
    defer allocator.free(tc);
    if (tc.len == 0) return .{ .sign = false, .limbs = try allocator.alloc(Limb, 0) };
    const negative = (tc[tc.len - 1] >> 63) & 1 == 1;
    if (!negative) {
        return .{ .sign = false, .limbs = try JSBigIntMagDup(allocator, tc) };
    }
    // Negative: magnitude = ~(tc) + 1.
    var mag = try allocator.alloc(Limb, tc.len);
    errdefer allocator.free(mag);
    var carry: u1 = 1;
    var i: usize = 0;
    while (i < tc.len) : (i += 1) {
        const s = @addWithOverflow(~tc[i], carry);
        mag[i] = s[0];
        carry = s[1];
    }
    const norm = try normalizeOwned(allocator, mag);
    return .{ .sign = norm.len != 0, .limbs = norm };
}

/// Copy a slice down to its normalized length.
fn JSBigIntMagDup(allocator: std.mem.Allocator, src: []const Limb) ![]Limb {
    const used = magUsedLen(src);
    const out = try allocator.alloc(Limb, used);
    @memcpy(out, src[0..used]);
    return out;
}

pub const BitOp = enum { @"and", @"or", xor };

/// §6.1.6.2.17/18/19 BigInt::bitwise{AND,OR,XOR}.
pub fn bitwise(allocator: std.mem.Allocator, comptime op: BitOp, a: BigIntValue, b: BigIntValue) !BigIntValue {
    // Width: enough limbs for both magnitudes, plus one guard limb
    // so a negative operand's sign bit is always representable.
    const n = @max(a.limbs.len, b.limbs.len) + 1;
    const ta = try twosComplement(allocator, a, n);
    defer allocator.free(ta);
    const tb = try twosComplement(allocator, b, n);
    defer allocator.free(tb);
    var out = try allocator.alloc(Limb, n);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        out[i] = switch (op) {
            .@"and" => ta[i] & tb[i],
            .@"or" => ta[i] | tb[i],
            .xor => ta[i] ^ tb[i],
        };
    }
    return fromTwosComplement(allocator, out);
}

/// §6.1.6.2.9 BigInt::leftShift. A negative `shift` shifts right
/// (arithmetic, floor-rounding). `shift` is the *signed* shift
/// amount as an i128 — callers pass the second operand's value.
pub fn leftShift(allocator: std.mem.Allocator, a: BigIntValue, shift: BigIntValue) !BigIntValue {
    if (shift.isZero() or a.isZero()) {
        return .{ .sign = a.sign, .limbs = try allocator.dupe(Limb, a.limbs) };
    }
    if (!shift.sign) {
        const amt = magToUsizeClamped(shift.limbs);
        const limbs = try magShlBits(allocator, a.limbs, amt);
        return .{ .sign = a.sign and limbs.len != 0, .limbs = limbs };
    }
    // Negative shift ⇒ arithmetic right shift by |shift|.
    return rightShiftByMagnitude(allocator, a, shift.limbs);
}

/// §6.1.6.2.10 BigInt::signedRightShift(x, y) = leftShift(x, -y).
pub fn signedRightShift(allocator: std.mem.Allocator, a: BigIntValue, shift: BigIntValue) !BigIntValue {
    if (shift.isZero() or a.isZero()) {
        return .{ .sign = a.sign, .limbs = try allocator.dupe(Limb, a.limbs) };
    }
    if (!shift.sign) {
        return rightShiftByMagnitude(allocator, a, shift.limbs);
    }
    const amt = magToUsizeClamped(shift.limbs);
    const limbs = try magShlBits(allocator, a.limbs, amt);
    return .{ .sign = a.sign and limbs.len != 0, .limbs = limbs };
}

/// Arithmetic (floor-rounding) right shift of `a` by the magnitude
/// `shift_mag`. For a negative `a`, shifting right floors toward
/// negative infinity: `-5n >> 1n === -3n`, not `-2n`.
fn rightShiftByMagnitude(allocator: std.mem.Allocator, a: BigIntValue, shift_mag: []const Limb) !BigIntValue {
    const amt = magToUsizeClamped(shift_mag);
    if (!a.sign) {
        const limbs = try magShrBits(allocator, a.limbs, amt);
        return .{ .sign = false, .limbs = limbs };
    }
    // Negative: floor((-mag) / 2^amt) = -ceil(mag / 2^amt).
    // ceil = (mag >> amt) + 1 iff any low bit was dropped.
    var dropped = false;
    var i: usize = 0;
    while (i < amt) : (i += 1) {
        if (magBitIsSet(a.limbs, i)) {
            dropped = true;
            break;
        }
    }
    const shifted = try magShrBits(allocator, a.limbs, amt);
    defer allocator.free(shifted);
    if (!dropped) {
        const out = try allocator.dupe(Limb, shifted);
        return .{ .sign = out.len != 0, .limbs = out };
    }
    const one = [_]Limb{1};
    const incremented = try magAdd(allocator, shifted, &one);
    return .{ .sign = incremented.len != 0, .limbs = incremented };
}

/// Collapse a magnitude to a usize shift count. A magnitude larger
/// than addressable memory is clamped — the result would OOM long
/// before producing a value, and shifts that large are caught by
/// the caller as RangeError anyway.
fn magToUsizeClamped(m: []const Limb) usize {
    const used = magUsedLen(m);
    if (used == 0) return 0;
    if (used > 1 or m[0] > std.math.maxInt(usize)) return std.math.maxInt(usize);
    return @intCast(m[0]);
}

// ── asIntN / asUintN (§21.2.2.1 / §21.2.2.2) ────────────────────

/// §21.2.2.1 BigInt.asIntN(bits, x) — x mod 2^bits, reinterpreted
/// as a signed `bits`-bit two's-complement integer.
pub fn asIntN(allocator: std.mem.Allocator, bits: usize, x: BigIntValue) !BigIntValue {
    if (bits == 0) return .{ .sign = false, .limbs = try allocator.alloc(Limb, 0) };
    const m = try modPow2(allocator, x, bits); // 0 ≤ m < 2^bits
    // If m ≥ 2^(bits-1), the result is m - 2^bits.
    if (magBitIsSet(m.limbs, bits - 1)) {
        // result = m - 2^bits  (a negative value)
        const pow2 = try makePow2(allocator, bits);
        defer allocator.free(pow2);
        // |result| = 2^bits - m.
        const neg_mag = try magSub(allocator, pow2, m.limbs);
        allocator.free(m.limbs);
        return .{ .sign = neg_mag.len != 0, .limbs = neg_mag };
    }
    return m;
}

/// §21.2.2.2 BigInt.asUintN(bits, x) — x mod 2^bits, non-negative.
pub fn asUintN(allocator: std.mem.Allocator, bits: usize, x: BigIntValue) !BigIntValue {
    if (bits == 0) return .{ .sign = false, .limbs = try allocator.alloc(Limb, 0) };
    return modPow2(allocator, x, bits);
}

/// Compute x mod 2^bits as a non-negative BigIntValue. For a
/// negative x, this is the two's-complement low `bits` bits.
fn modPow2(allocator: std.mem.Allocator, x: BigIntValue, bits: usize) !BigIntValue {
    const limb_count = (bits + limb_bits - 1) / limb_bits;
    const tc = try twosComplement(allocator, x, limb_count + 1);
    defer allocator.free(tc);
    var out = try allocator.alloc(Limb, limb_count);
    errdefer allocator.free(out);
    @memcpy(out, tc[0..limb_count]);
    // Mask off the bits above `bits` in the top limb.
    const top_bits: u6 = @intCast(bits % limb_bits);
    if (top_bits != 0) {
        const mask: Limb = (@as(Limb, 1) << top_bits) - 1;
        out[limb_count - 1] &= mask;
    }
    const norm = try normalizeOwned(allocator, out);
    return .{ .sign = false, .limbs = norm };
}

/// Allocate the magnitude of 2^bits.
fn makePow2(allocator: std.mem.Allocator, bits: usize) ![]Limb {
    const limb_idx = bits / limb_bits;
    const bit: u6 = @intCast(bits % limb_bits);
    var out = try allocator.alloc(Limb, limb_idx + 1);
    @memset(out, 0);
    out[limb_idx] = @as(Limb, 1) << bit;
    return out;
}

// ── String ⇄ BigInt ─────────────────────────────────────────────

/// Parse a magnitude from `digits` in `radix` (2/8/10/16). Skips
/// `_` separators. Returns a normalized owned magnitude. Errors on
/// any invalid digit or an empty body.
fn parseMagnitude(allocator: std.mem.Allocator, digits: []const u8, radix: u8) ParseError![]Limb {
    var acc = try allocator.alloc(Limb, 1);
    errdefer allocator.free(acc);
    acc[0] = 0;
    var saw_digit = false;
    for (digits) |c| {
        if (c == '_') continue;
        const d: u8 = switch (c) {
            '0'...'9' => c - '0',
            'a'...'f' => c - 'a' + 10,
            'A'...'F' => c - 'A' + 10,
            else => return error.InvalidBigInt,
        };
        if (d >= radix) return error.InvalidBigInt;
        saw_digit = true;
        // acc = acc * radix + d.
        const scaled = try mulSmall(allocator, acc, radix);
        allocator.free(acc);
        acc = scaled;
        const added = try addSmall(allocator, acc, d);
        allocator.free(acc);
        acc = added;
    }
    if (!saw_digit) return error.InvalidBigInt;
    return normalizeOwned(allocator, acc);
}

/// Multiply a magnitude by a small (< 2^64) constant. Owned result.
fn mulSmall(allocator: std.mem.Allocator, m: []const Limb, x: Limb) ![]Limb {
    const n = magUsedLen(m);
    var out = try allocator.alloc(Limb, n + 1);
    errdefer allocator.free(out);
    var carry: Limb = 0;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const p: u128 = @as(u128, m[i]) * @as(u128, x) + @as(u128, carry);
        out[i] = @truncate(p);
        carry = @truncate(p >> 64);
    }
    out[n] = carry;
    return normalizeOwned(allocator, out);
}

/// Add a small (< 2^64) constant to a magnitude. Owned result.
fn addSmall(allocator: std.mem.Allocator, m: []const Limb, x: Limb) ![]Limb {
    const n = magUsedLen(m);
    var out = try allocator.alloc(Limb, n + 1);
    errdefer allocator.free(out);
    var carry: Limb = x;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const s = @addWithOverflow(m[i], carry);
        out[i] = s[0];
        carry = s[1];
    }
    out[n] = carry;
    return normalizeOwned(allocator, out);
}

/// §7.1.14 StringToBigInt result, ready to hand to the heap.
pub fn parseStringToValue(allocator: std.mem.Allocator, bytes: []const u8) ParseError!BigIntValue {
    const trimmed = std.mem.trim(u8, bytes, " \t\n\r\u{000B}\u{000C}\u{00A0}\u{FEFF}");
    if (trimmed.len == 0) return .{ .sign = false, .limbs = try allocator.alloc(Limb, 0) };
    var rest = trimmed;
    var negate_it = false;
    var has_sign = false;
    if (rest[0] == '-') {
        negate_it = true;
        has_sign = true;
        rest = rest[1..];
    } else if (rest[0] == '+') {
        has_sign = true;
        rest = rest[1..];
    }
    if (rest.len == 0) return error.InvalidBigInt;
    // Non-decimal radix prefixes (0b / 0o / 0x): sign forbidden.
    if (rest.len >= 2 and rest[0] == '0') {
        const radix: ?u8 = switch (rest[1]) {
            'b', 'B' => @as(u8, 2),
            'o', 'O' => @as(u8, 8),
            'x', 'X' => @as(u8, 16),
            else => null,
        };
        if (radix) |rdx| {
            if (has_sign) return error.InvalidBigInt;
            const body = rest[2..];
            if (body.len == 0) return error.InvalidBigInt;
            const limbs = try parseMagnitude(allocator, body, rdx);
            return .{ .sign = false, .limbs = limbs };
        }
    }
    // Decimal — DecimalDigits only.
    const limbs = try parseMagnitude(allocator, rest, 10);
    return .{ .sign = negate_it and limbs.len != 0, .limbs = limbs };
}

/// §21.2.1.1.1 NumberToBigInt — convert an integral, finite f64
/// to an arbitrary-precision `BigIntValue`. The caller must have
/// rejected NaN / ±Infinity / non-integers. Used both by the
/// `BigInt(number)` constructor and by the exact BigInt-vs-Number
/// comparison path (§7.2.13).
pub fn fromDouble(allocator: std.mem.Allocator, d: f64) !BigIntValue {
    if (d == 0) return .{ .sign = false, .limbs = try allocator.alloc(Limb, 0) };
    const neg = d < 0;
    var mag = @abs(d);
    // `frexp` gives mag = frac·2^exp with frac in [0.5, 1); the
    // value's integer bit length is `exp`.
    const exp = std.math.frexp(mag).exponent;
    const bit_len: usize = @intCast(@max(exp, 0));
    const limb_count = bit_len / limb_bits + 2;
    var limbs = try allocator.alloc(Limb, limb_count);
    errdefer allocator.free(limbs);
    @memset(limbs, 0);
    // Peel ≤53-bit integer chunks off the top of the magnitude.
    var remaining_bits: isize = @intCast(bit_len);
    while (remaining_bits > 0 and mag != 0) {
        const take: u6 = @intCast(@min(remaining_bits, 32));
        const shift_down: isize = remaining_bits - @as(isize, take);
        // chunk = floor(mag / 2^shift_down), a `take`-bit integer.
        const scaled = std.math.ldexp(mag, @intCast(-shift_down));
        const chunk: u64 = @intFromFloat(@floor(scaled));
        mag -= @as(f64, @floatFromInt(chunk)) * std.math.ldexp(@as(f64, 1.0), @intCast(shift_down));
        // Place `chunk` at bit position `shift_down`.
        const limb_idx: usize = @intCast(@divFloor(shift_down, limb_bits));
        const bit_off: u6 = @intCast(@mod(shift_down, limb_bits));
        if (limb_idx < limb_count) {
            limbs[limb_idx] |= chunk << bit_off;
            if (bit_off != 0 and limb_idx + 1 < limb_count) {
                limbs[limb_idx + 1] |= chunk >> @intCast(limb_bits - @as(usize, bit_off));
            }
        }
        remaining_bits = shift_down;
    }
    const norm = try normalizeOwned(allocator, limbs);
    return .{ .sign = neg and norm.len != 0, .limbs = norm };
}

/// Parse a BigInt *literal* digit-text (the `n`-suffix already
/// stripped). Used by the bytecode compiler. Accepts the same
/// 0x/0o/0b prefixes plus `_` separators; no sign (the lexer
/// routes a leading `-` through unary negate).
pub fn parseLiteralToValue(allocator: std.mem.Allocator, text: []const u8) ParseError!BigIntValue {
    var radix: u8 = 10;
    var rest = text;
    if (text.len >= 2 and text[0] == '0') {
        switch (text[1]) {
            'x', 'X' => {
                radix = 16;
                rest = text[2..];
            },
            'o', 'O' => {
                radix = 8;
                rest = text[2..];
            },
            'b', 'B' => {
                radix = 2;
                rest = text[2..];
            },
            else => {},
        }
    }
    if (rest.len == 0) return error.InvalidBigInt;
    const limbs = try parseMagnitude(allocator, rest, radix);
    return .{ .sign = false, .limbs = limbs };
}

/// §6.1.6.2.21 BigInt::toString — render `bi` in `radix` (2..36).
/// Allocates the result; caller frees.
pub fn toStringAlloc(allocator: std.mem.Allocator, bi: *const JSBigInt, radix: u8) ![]u8 {
    std.debug.assert(radix >= 2 and radix <= 36);
    if (bi.isZero()) return allocator.dupe(u8, "0");
    // Work on a mutable copy of the magnitude, repeatedly dividing
    // by the largest power of `radix` that fits in a single limb —
    // this batches divisions so the inner loop is O(limbs) per
    // chunk instead of O(limbs) per digit.
    var work = try allocator.dupe(Limb, bi.limbs);
    defer allocator.free(work);
    var work_len = work.len;

    // Largest radix^k < 2^64.
    var chunk_base: u64 = radix;
    var digits_per_chunk: usize = 1;
    while (true) {
        const next = @mulWithOverflow(chunk_base, radix);
        if (next[1] != 0) break;
        chunk_base = next[0];
        digits_per_chunk += 1;
    }

    var digits: std.ArrayListUnmanaged(u8) = .empty;
    defer digits.deinit(allocator);

    while (work_len > 0) {
        // Divide `work` (in place) by `chunk_base`, capturing the
        // remainder.
        var rem: u64 = 0;
        var i: usize = work_len;
        while (i > 0) {
            i -= 1;
            const cur: u128 = (@as(u128, rem) << 64) | work[i];
            work[i] = @truncate(cur / chunk_base);
            rem = @truncate(cur % chunk_base);
        }
        while (work_len > 0 and work[work_len - 1] == 0) work_len -= 1;
        // Emit `digits_per_chunk` digits from `rem` (low-to-high).
        var k: usize = 0;
        while (k < digits_per_chunk) : (k += 1) {
            const d: u8 = @intCast(rem % radix);
            rem /= radix;
            try digits.append(allocator, if (d < 10) '0' + d else 'a' + (d - 10));
            // The final (most-significant) chunk may have fewer
            // than `digits_per_chunk` digits — stop once the
            // remainder is exhausted and no more limbs remain.
            if (rem == 0 and work_len == 0) break;
        }
    }
    // `digits` is little-endian; reverse, prepend sign.
    const total = digits.items.len + @as(usize, if (bi.sign) 1 else 0);
    var out = try allocator.alloc(u8, total);
    var pos: usize = 0;
    if (bi.sign) {
        out[0] = '-';
        pos = 1;
    }
    var j: usize = digits.items.len;
    while (j > 0) {
        j -= 1;
        out[pos] = digits.items[j];
        pos += 1;
    }
    return out;
}

// ─────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────

const testing = std.testing;

/// Build a BigIntValue from a decimal string for test convenience.
fn tv(allocator: std.mem.Allocator, s: []const u8) !BigIntValue {
    return parseStringToValue(allocator, s);
}

fn expectDecimal(allocator: std.mem.Allocator, v: BigIntValue, expected: []const u8) !void {
    const b = try JSBigInt.initFromLimbs(allocator, v.sign, v.limbs);
    defer b.deinit(allocator);
    const s = try toStringAlloc(allocator, b, 10);
    defer allocator.free(s);
    try testing.expectEqualStrings(expected, s);
}

test "bigint: parse and roundtrip decimal" {
    const a = testing.allocator;
    {
        const v = try tv(a, "0");
        defer a.free(v.limbs);
        try expectDecimal(a, v, "0");
    }
    {
        const v = try tv(a, "123456789012345678901234567890");
        defer a.free(v.limbs);
        try expectDecimal(a, v, "123456789012345678901234567890");
    }
    {
        const v = try tv(a, "-987654321098765432109876543210");
        defer a.free(v.limbs);
        try expectDecimal(a, v, "-987654321098765432109876543210");
    }
}

test "bigint: parse hex/oct/bin" {
    const a = testing.allocator;
    {
        const v = try tv(a, "0xffffffffffffffffff");
        defer a.free(v.limbs);
        try expectDecimal(a, v, "4722366482869645213695");
    }
    {
        const v = try tv(a, "0o777");
        defer a.free(v.limbs);
        try expectDecimal(a, v, "511");
    }
    {
        const v = try tv(a, "0b101010");
        defer a.free(v.limbs);
        try expectDecimal(a, v, "42");
    }
}

test "bigint: add crosses limb boundary" {
    const a = testing.allocator;
    const x = try tv(a, "18446744073709551615"); // 2^64-1
    defer a.free(x.limbs);
    const y = try tv(a, "1");
    defer a.free(y.limbs);
    const r = try add(a, x, y);
    defer a.free(r.limbs);
    try expectDecimal(a, r, "18446744073709551616"); // 2^64
}

test "bigint: subtract with sign flip" {
    const a = testing.allocator;
    const x = try tv(a, "5");
    defer a.free(x.limbs);
    const y = try tv(a, "8");
    defer a.free(y.limbs);
    const r = try sub(a, x, y);
    defer a.free(r.limbs);
    try expectDecimal(a, r, "-3");
}

test "bigint: multiply 200-bit" {
    const a = testing.allocator;
    // 0xFEDCBA9876543210 ** 2 = 0xFDBAC097C8DC5ACCDEEC6CD7A44A4100
    const x = try tv(a, "0xFEDCBA9876543210");
    defer a.free(x.limbs);
    const r = try mul(a, x, x);
    defer a.free(r.limbs);
    const b = try JSBigInt.initFromLimbs(a, r.sign, r.limbs);
    defer b.deinit(a);
    const s = try toStringAlloc(a, b, 16);
    defer a.free(s);
    try testing.expectEqualStrings("fdbac097c8dc5accdeec6cd7a44a4100", s);
}

test "bigint: divide and remainder truncated" {
    const a = testing.allocator;
    const x = try tv(a, "100000000000000000000000");
    defer a.free(x.limbs);
    const y = try tv(a, "7");
    defer a.free(y.limbs);
    const q = try divide(a, x, y);
    defer a.free(q.limbs);
    try expectDecimal(a, q, "14285714285714285714285");
    const rm = try remainder(a, x, y);
    defer a.free(rm.limbs);
    try expectDecimal(a, rm, "5");

    // Negative dividend: remainder sign follows dividend.
    const nx = try tv(a, "-17");
    defer a.free(nx.limbs);
    const ny = try tv(a, "5");
    defer a.free(ny.limbs);
    const nq = try divide(a, nx, ny);
    defer a.free(nq.limbs);
    try expectDecimal(a, nq, "-3");
    const nr = try remainder(a, nx, ny);
    defer a.free(nr.limbs);
    try expectDecimal(a, nr, "-2");
}

test "bigint: exponentiation 2^128" {
    const a = testing.allocator;
    const base = try tv(a, "2");
    defer a.free(base.limbs);
    const exp = try tv(a, "128");
    defer a.free(exp.limbs);
    const r = try pow(a, base, exp);
    defer a.free(r.limbs);
    try expectDecimal(a, r, "340282366920938463463374607431768211456");
}

test "bigint: bitwise on negatives (two's complement)" {
    const a = testing.allocator;
    // -1n & 5n === 5n  (-1 is all-ones)
    {
        const x = try tv(a, "-1");
        defer a.free(x.limbs);
        const y = try tv(a, "5");
        defer a.free(y.limbs);
        const r = try bitwise(a, .@"and", x, y);
        defer a.free(r.limbs);
        try expectDecimal(a, r, "5");
    }
    // -5n | 3n === -5n  (… per two's complement)
    {
        const x = try tv(a, "-5");
        defer a.free(x.limbs);
        const y = try tv(a, "3");
        defer a.free(y.limbs);
        const r = try bitwise(a, .@"or", x, y);
        defer a.free(r.limbs);
        try expectDecimal(a, r, "-5");
    }
    // ~5n === -6n
    {
        const x = try tv(a, "5");
        defer a.free(x.limbs);
        const r = try bitwiseNot(a, x);
        defer a.free(r.limbs);
        try expectDecimal(a, r, "-6");
    }
    // ~(-1n) === 0n
    {
        const x = try tv(a, "-1");
        defer a.free(x.limbs);
        const r = try bitwiseNot(a, x);
        defer a.free(r.limbs);
        try expectDecimal(a, r, "0");
    }
}

test "bigint: shifts" {
    const a = testing.allocator;
    // 1n << 100n
    {
        const x = try tv(a, "1");
        defer a.free(x.limbs);
        const s = try tv(a, "100");
        defer a.free(s.limbs);
        const r = try leftShift(a, x, s);
        defer a.free(r.limbs);
        try expectDecimal(a, r, "1267650600228229401496703205376");
    }
    // -5n >> 1n === -3n (floor)
    {
        const x = try tv(a, "-5");
        defer a.free(x.limbs);
        const s = try tv(a, "1");
        defer a.free(s.limbs);
        const r = try signedRightShift(a, x, s);
        defer a.free(r.limbs);
        try expectDecimal(a, r, "-3");
    }
    // 0xFF00n >> 8n === 0xFFn
    {
        const x = try tv(a, "65280");
        defer a.free(x.limbs);
        const s = try tv(a, "8");
        defer a.free(s.limbs);
        const r = try signedRightShift(a, x, s);
        defer a.free(r.limbs);
        try expectDecimal(a, r, "255");
    }
}

test "bigint: asIntN / asUintN" {
    const a = testing.allocator;
    // asUintN(64, -1n) === 18446744073709551615n
    {
        const x = try tv(a, "-1");
        defer a.free(x.limbs);
        const r = try asUintN(a, 64, x);
        defer a.free(r.limbs);
        try expectDecimal(a, r, "18446744073709551615");
    }
    // asIntN(64, 18446744073709551615n) === -1n
    {
        const x = try tv(a, "18446744073709551615");
        defer a.free(x.limbs);
        const r = try asIntN(a, 64, x);
        defer a.free(r.limbs);
        try expectDecimal(a, r, "-1");
    }
    // asIntN(3, 25n): 25 mod 8 = 1 → 1n
    {
        const x = try tv(a, "25");
        defer a.free(x.limbs);
        const r = try asIntN(a, 3, x);
        defer a.free(r.limbs);
        try expectDecimal(a, r, "1");
    }
    // asIntN(3, 5n): 5 mod 8 = 5 ≥ 4 → 5-8 = -3n
    {
        const x = try tv(a, "5");
        defer a.free(x.limbs);
        const r = try asIntN(a, 3, x);
        defer a.free(r.limbs);
        try expectDecimal(a, r, "-3");
    }
    // asIntN over a value beyond i128: 2^130 + 5, asIntN(4, .) = 5
    {
        const base = try tv(a, "2");
        defer a.free(base.limbs);
        const e = try tv(a, "130");
        defer a.free(e.limbs);
        const big = try pow(a, base, e);
        defer a.free(big.limbs);
        const five = try tv(a, "5");
        defer a.free(five.limbs);
        const sum = try add(a, big, five);
        defer a.free(sum.limbs);
        const r = try asUintN(a, 4, sum);
        defer a.free(r.limbs);
        try expectDecimal(a, r, "5");
    }
}

test "bigint: compare crosses sign and magnitude" {
    const a = testing.allocator;
    const neg_big = try tv(a, "-340282366920938463463374607431768211456");
    defer a.free(neg_big.limbs);
    const pos_small = try tv(a, "1");
    defer a.free(pos_small.limbs);
    try testing.expect(compare(neg_big, pos_small) == .lt);
    try testing.expect(compare(pos_small, neg_big) == .gt);

    const same1 = try tv(a, "999999999999999999999999");
    defer a.free(same1.limbs);
    const same2 = try tv(a, "999999999999999999999999");
    defer a.free(same2.limbs);
    try testing.expect(equals(same1, same2));
}

test "bigint: JSBigInt i128 roundtrip" {
    const a = testing.allocator;
    {
        const b = try JSBigInt.init(a, -170141183460469231731687303715884105728); // i128 min
        defer b.deinit(a);
        try testing.expect(b.fitsI128());
        try testing.expectEqual(@as(i128, -170141183460469231731687303715884105728), b.toI128());
    }
    {
        const b = try JSBigInt.init(a, 0);
        defer b.deinit(a);
        try testing.expect(b.isZero());
        try testing.expectEqual(@as(i64, 0), b.toI64Truncating());
    }
    {
        const b = try JSBigInt.init(a, -1);
        defer b.deinit(a);
        try testing.expectEqual(@as(u64, 0xFFFFFFFFFFFFFFFF), b.toU64Truncating());
    }
}
