//! Arithmetic + coercion helpers — extracted from
//! `interpreter.zig`. Pure(-ish) functions called from inside
//! the dispatch loop's `add` / `sub` / `mul` / `eq` / `lt` /
//! etc. handlers. They take `Value`s and return `Value`s; the
//! BigInt-aware ones thread `realm` through for heap
//! allocation. No `CallFrame` access, no opcode-pointer
//! manipulation — those stay in `interpreter.zig`.
//!
//! Spec anchors mostly in §13 (operators) and §7.1
//! (abstract conversion operations: ToNumber, ToInt32,
//! ToUint32, ToBoolean).

const std = @import("std");

const Value = @import("../value.zig").Value;
const JSString = @import("../string.zig").JSString;
const Realm = @import("../realm.zig").Realm;
const heap_mod = @import("../heap.zig");
const intrinsics_mod = @import("../intrinsics.zig");
const utf16 = @import("../utf16.zig");
const bigint_mod = @import("../bigint.zig");
const JSBigInt = bigint_mod.JSBigInt;
const BigIntValue = bigint_mod.BigIntValue;

/// View a `JSBigInt` as a borrowed `BigIntValue` — the limb slice
/// is shared, NOT copied, so the view is only valid while the
/// `JSBigInt` lives. The arbitrary-precision ops in `bigint_mod`
/// never mutate their inputs, so a borrowed view is safe to pass.
fn borrowBigInt(bi: *const JSBigInt) BigIntValue {
    return .{ .sign = bi.sign, .limbs = bi.limbs };
}

pub const RunError = @import("interpreter.zig").RunError;
pub const NativeError = @import("../function.zig").NativeError;
const makeTypeError = @import("interpreter.zig").makeTypeError;
const makeRangeError = @import("interpreter.zig").makeRangeError;
const formatDoubleSafe = @import("interpreter.zig").formatDoubleSafe;

pub fn toBoolean(v: Value) bool {
    if (v.isString()) {
        const s: *JSString = @ptrCast(@alignCast(v.asString()));
        return !s.isEmpty();
    }
    // §7.1.2 ToBoolean — BigInts are stored as Object-tagged
    // values in Cynic; the spec treats 0n as falsy and every
    // other BigInt as truthy. Symbols are always truthy. Plain
    // objects (including wrappers like `new Boolean(false)`) are
    // truthy per spec.
    if (heap_mod.valueAsBigInt(v)) |bi| return !bi.isZero();
    if (v.isObject()) return true;
    return v.toBooleanPrimitive();
}

/// §12.5 WhiteSpace + §12.7 LineTerminator — the StrWhiteSpace
/// codepoint set §7.1.4.1.1 StringToNumber trims from both ends
/// before parsing. Mirrors the table in `builtins/number.zig`;
/// kept inline here so `toNumber` doesn't have to reach into the
/// builtins layer.
fn isStrWhiteSpace(cp: u21) bool {
    return switch (cp) {
        // §12.5 ASCII WhiteSpace + §12.7 LineTerminator.
        0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x20 => true,
        // §12.5 — NBSP and ZWNBSP (BOM).
        0x00A0, 0xFEFF => true,
        // §12.5 — Unicode Space_Separator (Zs) enumerated; Cynic
        // tracks the Unicode 15 set without pulling the full UCD.
        0x1680, 0x2000, 0x2001, 0x2002, 0x2003, 0x2004, 0x2005, 0x2006, 0x2007, 0x2008, 0x2009, 0x200A, 0x202F, 0x205F, 0x3000 => true,
        // §12.7 — LineTerminator LS / PS.
        0x2028, 0x2029 => true,
        else => false,
    };
}

fn skipStrWhiteSpaceFwd(bytes: []const u8) usize {
    var view = std.unicode.Utf8View.initUnchecked(bytes).iterator();
    while (true) {
        const before = view.i;
        const cp = view.nextCodepoint() orelse return bytes.len;
        if (!isStrWhiteSpace(cp)) return before;
    }
}

fn skipStrWhiteSpaceRev(bytes: []const u8) usize {
    // Walk backwards through valid UTF-8 sequences. A continuation
    // byte starts with `10xxxxxx`; back up over those to find the
    // start of the last code point.
    var end = bytes.len;
    while (end > 0) {
        var start = end - 1;
        while (start > 0 and (bytes[start] & 0xC0) == 0x80) start -= 1;
        const cp = std.unicode.utf8Decode(bytes[start..end]) catch return end;
        if (!isStrWhiteSpace(cp)) return end;
        end = start;
    }
    return 0;
}

/// §7.1.4 ToNumber. Object-typed coercion (which can call user
/// code via ToPrimitive) lands with later; until then objects fall
/// back to NaN unless they're a primitive wrapper (§7.1.1
/// OrdinaryToPrimitive — we look at `[[NumberData]]` /
/// `[[StringData]]` / `[[BooleanData]]` directly via the
/// `boxed_primitive` slot).
pub fn toNumber(v: Value) f64 {
    if (v.isInt32()) return @floatFromInt(v.asInt32());
    if (v.isDouble()) return v.asDouble();
    if (v.isBool()) return if (v.asBool()) 1.0 else 0.0;
    if (v.isNull()) return 0.0;
    if (v.isUndefined()) return std.math.nan(f64);
    if (v.isString()) {
        const s: *JSString = @ptrCast(@alignCast(v.asString()));
        // §7.1.4.1.1 StringToNumber. Empty / whitespace-only strings
        // are 0; otherwise std.fmt.parseFloat. Trim StrWhiteSpace +
        // StrLineTerminator from both ends per §12.5 / §12.7 — the
        // full Unicode set, not just ASCII tab/space/CR/LF (the
        // Sputnik S9.3.1_A3 fixtures pass NBSP, the Zs block, and
        // LS/PS as whitespace).
        const s_bytes = s.flatBytes();
        const start_idx = skipStrWhiteSpaceFwd(s_bytes);
        const end_idx = skipStrWhiteSpaceRev(s_bytes);
        if (start_idx >= end_idx) return 0.0;
        const trimmed = s_bytes[start_idx..end_idx];
        // §7.1.4.1.1 StringToNumber — the StrUnsignedDecimalLiteral
        // grammar accepts only the case-sensitive `Infinity`. Zig's
        // `parseFloat` accepts `INFINITY`/`inf` etc.; pre-check the
        // literal forms ourselves and return NaN for anything that
        // would case-fold into `inf`/`nan`.
        const infinity_form = std.mem.eql(u8, trimmed, "Infinity") or
            std.mem.eql(u8, trimmed, "+Infinity") or
            std.mem.eql(u8, trimmed, "-Infinity");
        if (!infinity_form) {
            // Reject any string that's a case-insensitive match for
            // an inf/nan literal but isn't the canonical `Infinity`.
            const body = if (trimmed.len > 0 and (trimmed[0] == '+' or trimmed[0] == '-'))
                trimmed[1..]
            else
                trimmed;
            if (std.ascii.eqlIgnoreCase(body, "inf") or
                std.ascii.eqlIgnoreCase(body, "infinity") or
                std.ascii.eqlIgnoreCase(body, "nan"))
            {
                return std.math.nan(f64);
            }
        }
        return std.fmt.parseFloat(f64, trimmed) catch std.math.nan(f64);
    }
    if (heap_mod.valueAsPlainObject(v)) |obj| {
        if (obj.getBoxedPrimitive()) |p| return toNumber(p);
    }
    return std.math.nan(f64);
}

/// §7.1.6 ToInt32. Modular truncation to a 32-bit signed integer.
pub fn toInt32(v: Value) i32 {
    if (v.isInt32()) return v.asInt32();
    const d = toNumber(v);
    if (std.math.isNan(d) or std.math.isInf(d)) return 0;
    const trunc = @trunc(d);
    // Modulo 2**32 in unsigned space, then re-bitcast.
    const two_32: f64 = 4294967296.0;
    const mod = @mod(trunc, two_32);
    const non_neg = if (mod < 0) mod + two_32 else mod;
    const u: u32 = @intFromFloat(non_neg);
    return @bitCast(u);
}

/// §7.1.7 ToUint32. Same as ToInt32 but reinterpreted unsigned.
pub fn toUint32(v: Value) u32 {
    return @bitCast(toInt32(v));
}

// ── Numeric helpers ─────────────────────────────────────────────────────

pub const NumericOp = enum { sub, mul, div, mod, pow };
pub const BigIntOp = enum { add, sub, mul, div, mod, pow };

/// §6.1.6.2 BigInt operations. At least one of `lhs`/`rhs` is
/// BigInt — the caller checks. Returns `null` and sets
/// `realm.pending_exception` to TypeError on mixed Number+BigInt
/// or on division/mod by zero. Returns the result Value on
/// success.
pub fn bigintArith(realm: *Realm, comptime op: BigIntOp, lhs: Value, rhs: Value) RunError!?Value {
    const a_bi = heap_mod.valueAsBigInt(lhs);
    const b_bi = heap_mod.valueAsBigInt(rhs);
    if (a_bi == null or b_bi == null) {
        // §6.1.6.2 — mixing BigInt with Number is a TypeError.
        realm.pending_exception = try makeTypeError(realm, "Cannot mix BigInt and other types");
        return null;
    }
    const a = borrowBigInt(a_bi.?);
    const b = borrowBigInt(b_bi.?);
    const alloc = realm.heap.allocator;
    // Every `bigint_mod.*` op allocates a fresh result magnitude;
    // `allocateBigIntValue` takes ownership of it. The only failure
    // before allocation is RangeError on div/mod-by-zero or a
    // negative exponent (§6.1.6.2.3 / §6.1.6.2.5).
    const result: BigIntValue = switch (op) {
        .add => bigint_mod.add(alloc, a, b) catch return error.OutOfMemory,
        .sub => bigint_mod.sub(alloc, a, b) catch return error.OutOfMemory,
        .mul => bigint_mod.mul(alloc, a, b) catch return error.OutOfMemory,
        .div => blk: {
            if (b.isZero()) {
                realm.pending_exception = try makeRangeError(realm, "Division by zero");
                return null;
            }
            break :blk bigint_mod.divide(alloc, a, b) catch return error.OutOfMemory;
        },
        .mod => blk: {
            if (b.isZero()) {
                realm.pending_exception = try makeRangeError(realm, "Modulo by zero");
                return null;
            }
            break :blk bigint_mod.remainder(alloc, a, b) catch return error.OutOfMemory;
        },
        .pow => blk: {
            // §6.1.6.2.3 — a negative exponent is a RangeError.
            if (b.sign) {
                realm.pending_exception = try makeRangeError(realm, "Exponent must be non-negative");
                return null;
            }
            break :blk bigint_mod.pow(alloc, a, b) catch return error.OutOfMemory;
        },
    };
    const out = realm.heap.allocateBigIntValue(result) catch return error.OutOfMemory;
    return heap_mod.taggedBigInt(out);
}
pub const BitwiseOp = enum { bit_and, bit_or, bit_xor, shl, shr, shr_u };
pub const RelOp = enum { lt, gt, le, ge };

/// §7.1.4 ToNumeric — coerce a Value to a primitive that the
/// numeric / bitwise operators can consume. Lands a TypeError on
/// the realm and returns null when the operand is a Symbol (or an
/// object whose `Symbol.toPrimitive` / `valueOf` / `toString`
/// returns a Symbol), so callers can distinguish "operand ready"
/// from "exception in flight". Other thrown completions from user
/// code (a `valueOf` body that throws) propagate the same way.
pub fn toNumericPrimitive(realm: *Realm, value: Value) RunError!?Value {
    if (heap_mod.isSymbol(value)) {
        realm.pending_exception = try makeTypeError(realm, "Cannot convert a Symbol to a number");
        return null;
    }
    if (!value.isObject()) return value;
    // BigInts are technically `isObject()==true` here (they live
    // on the heap with the same top tag) but ToPrimitive is a
    // no-op for them.
    if (heap_mod.isBigInt(value)) return value;
    if (heap_mod.isFunction(value) or heap_mod.isPlainObject(value)) {
        const prim = intrinsics_mod.toPrimitive(realm, value, .number) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.NativeThrew => return null,
        };
        if (heap_mod.isSymbol(prim)) {
            realm.pending_exception = try makeTypeError(realm, "Cannot convert a Symbol to a number");
            return null;
        }
        return prim;
    }
    return value;
}

pub fn numericBinary(realm: *Realm, comptime op: NumericOp, lhs: Value, rhs: Value) RunError!?Value {
    // §13.15.4 ApplyStringOrNumericBinaryOperator step 1 — call
    // ToPrimitive on each operand (hint "number") before any
    // numeric coercion. Spec sequencing matters: lhs first, then
    // rhs. A throw inside `valueOf` / `toString` / Symbol.toPrim
    // bubbles via `pending_exception`.
    const l = (try toNumericPrimitive(realm, lhs)) orelse return null;
    const r = (try toNumericPrimitive(realm, rhs)) orelse return null;

    // §6.1.6.2 — once both sides are primitives, BigInt + Number
    // is an unconditional TypeError. Pure-BigInt math went through
    // `bigintArith` upstream already; this branch only fires when
    // one operand was a Number until valueOf produced a BigInt
    // (or the reverse).
    const l_is_bigint = heap_mod.isBigInt(l);
    const r_is_bigint = heap_mod.isBigInt(r);
    if (l_is_bigint and r_is_bigint) {
        return (try bigintArith(realm, switch (op) {
            .sub => .sub,
            .mul => .mul,
            .div => .div,
            .mod => .mod,
            .pow => .pow,
        }, l, r)) orelse return null;
    }
    if (l_is_bigint != r_is_bigint) {
        realm.pending_exception = try makeTypeError(realm, "Cannot mix BigInt and other types");
        return null;
    }

    // Int32 fast path — only safe when both are int32 AND the
    // mathematical result also fits without overflow / float
    // promotion. Cheaper than the double path on cold caches.
    if (l.isInt32() and r.isInt32() and op != .div and op != .pow) {
        const a = l.asInt32();
        const b = r.asInt32();
        switch (op) {
            .sub => {
                const o = @subWithOverflow(a, b);
                if (o[1] == 0) return Value.fromInt32(o[0]);
            },
            .mul => {
                const o = @mulWithOverflow(a, b);
                if (o[1] == 0) return Value.fromInt32(o[0]);
            },
            .mod => {
                // §13.6.2 / §6.1.6.1.5 Number::remainder — JS
                // modulus is truncated, not Euclidean: the
                // result's sign follows the dividend (a). `@mod`
                // is Euclidean (always non-negative when b > 0);
                // `@rem` is the C-style truncated remainder that
                // matches JS.
                if (b != 0) {
                    const rem = @rem(a, b);
                    // §6.1.6.1.5 — when the result is zero, its
                    // sign tracks the dividend: `(-1) % 1 === -0`,
                    // `(-1) % (-1) === -0`. The int32 representation
                    // collapses ±0 to +0, so a negative dividend
                    // with zero remainder must escape to a Double
                    // to preserve sign.
                    if (rem == 0 and a < 0) return Value.fromDouble(-0.0);
                    return Value.fromInt32(rem);
                }
            },
            .div, .pow => unreachable,
        }
        // fall through to double path
    }

    const a = toNumber(l);
    const b = toNumber(r);
    return Value.fromDouble(switch (op) {
        .sub => a - b,
        .mul => a * b,
        .div => a / b,
        // §13.6.2 — truncated remainder (sign follows dividend),
        // not Euclidean. `@rem` for f64 yields IEEE 754
        // remainder by truncated division, matching `Math.fmod`
        // / V8 / SM behaviour.
        .mod => @rem(a, b),
        .pow => jsPow(a, b),
    });
}

/// §6.1.6.1.3 Number::exponentiate — adds the JS spec's special
/// cases on top of IEEE 754 `pow`. The relevant divergence:
/// when `|base| == 1` and the exponent is ±∞, the spec returns
/// NaN. `std.math.pow` returns 1 in that case (and 0 for `0 ** anything`
/// which is correct).
fn jsPow(a: f64, b: f64) f64 {
    if (std.math.isNan(b)) return std.math.nan(f64);
    if (std.math.isInf(b) and (a == 1.0 or a == -1.0)) return std.math.nan(f64);
    return std.math.pow(f64, a, b);
}

/// True iff the shift magnitude is large enough that the resulting
/// BigInt would exceed a sane size budget. V8 caps a BigInt at
/// roughly 2^30 bits; a left shift past that point is reported as a
/// RangeError rather than attempting a multi-gigabyte allocation.
fn bigintShiftTooLarge(shift: BigIntValue) bool {
    // Anything wider than a single limb is astronomically large.
    if (shift.limbs.len > 1) return true;
    if (shift.limbs.len == 0) return false;
    return shift.limbs[0] > (1 << 30);
}

pub fn bitwiseBinary(realm: *Realm, comptime op: BitwiseOp, lhs: Value, rhs: Value) RunError!?Value {
    // §13.12 BitwiseOp — spec evaluates lhs then rhs, then
    // ToNumeric on each. We already have the bytecode-evaluated
    // values in registers, so we only owe the ToNumeric step.
    const l = (try toNumericPrimitive(realm, lhs)) orelse return null;
    const r = (try toNumericPrimitive(realm, rhs)) orelse return null;

    // BigInt mixing — bitwise ops on BigInt are not yet supported
    // by the interpreter, but mixed Number+BigInt must still throw
    // TypeError per §6.1.6.2.
    const l_is_bigint = heap_mod.isBigInt(l);
    const r_is_bigint = heap_mod.isBigInt(r);
    if (l_is_bigint != r_is_bigint) {
        realm.pending_exception = try makeTypeError(realm, "Cannot mix BigInt and other types");
        return null;
    }
    if (l_is_bigint and r_is_bigint) {
        // §6.1.6.2.{9,10,17,18,19} BigInt::leftShift /
        // signedRightShift / bitwise{AND,OR,XOR}. `>>>`
        // (unsignedRightShift) is §6.1.6.2.11 — defined to throw
        // TypeError on BigInt operands because BigInts have no
        // fixed width.
        const a = borrowBigInt(heap_mod.valueAsBigInt(l).?);
        const b = borrowBigInt(heap_mod.valueAsBigInt(r).?);
        const alloc = realm.heap.allocator;
        const result: BigIntValue = switch (op) {
            // Arbitrary-width two's-complement bitwise — `bigint_mod`
            // materialises the infinite sign-extension model per the
            // spec's "infinite-length two's-complement" wording.
            .bit_and => bigint_mod.bitwise(alloc, .@"and", a, b) catch return error.OutOfMemory,
            .bit_or => bigint_mod.bitwise(alloc, .@"or", a, b) catch return error.OutOfMemory,
            .bit_xor => bigint_mod.bitwise(alloc, .xor, a, b) catch return error.OutOfMemory,
            // §6.1.6.2.9 — a negative shift count shifts the other
            // way (handled inside `leftShift` / `signedRightShift`).
            // A huge positive left shift would allocate unbounded
            // memory; cap it as a RangeError once the result would
            // exceed a sane bit budget.
            .shl => blk: {
                if (!b.sign and bigintShiftTooLarge(b)) {
                    realm.pending_exception = try makeRangeError(realm, "Maximum BigInt size exceeded");
                    return null;
                }
                break :blk bigint_mod.leftShift(alloc, a, b) catch return error.OutOfMemory;
            },
            .shr => blk: {
                if (b.sign and bigintShiftTooLarge(b)) {
                    realm.pending_exception = try makeRangeError(realm, "Maximum BigInt size exceeded");
                    return null;
                }
                break :blk bigint_mod.signedRightShift(alloc, a, b) catch return error.OutOfMemory;
            },
            .shr_u => {
                // §6.1.6.2.11 BigInt::unsignedRightShift always
                // throws TypeError — BigInts are not fixed-width.
                realm.pending_exception = try makeTypeError(realm, "BigInts have no unsigned right shift, use >> instead");
                return null;
            },
        };
        const out = realm.heap.allocateBigIntValue(result) catch return error.OutOfMemory;
        return heap_mod.taggedBigInt(out);
    }

    const a = toInt32(l);
    const b = toInt32(r);
    return switch (op) {
        .bit_and => Value.fromInt32(a & b),
        .bit_or => Value.fromInt32(a | b),
        .bit_xor => Value.fromInt32(a ^ b),
        // §13.10: shift counts mask to 5 bits.
        .shl => Value.fromInt32(a << @as(u5, @intCast(@as(u32, @bitCast(b)) & 0x1F))),
        .shr => Value.fromInt32(a >> @as(u5, @intCast(@as(u32, @bitCast(b)) & 0x1F))),
        .shr_u => blk: {
            // §13.10 / §6.1.6.1.10 Number::unsignedRightShift —
            // ToUint32 on both operands, mask the shift count to
            // 5 bits, then perform a logical right shift. The
            // result is a u32 that the spec returns as a Number;
            // values ≥ 2^31 don't fit in the signed-int32 Smi
            // representation (`-1 >>> 0 === 4294967295`, not -1),
            // so escape to a Double when the high bit is set.
            const ua: u32 = @bitCast(a);
            const ub: u32 = @bitCast(b);
            const result = ua >> @as(u5, @intCast(ub & 0x1F));
            if (result > std.math.maxInt(i32)) {
                break :blk Value.fromDouble(@floatFromInt(result));
            }
            break :blk Value.fromInt32(@intCast(result));
        },
    };
}

pub fn unaryNegate(realm: *Realm, v: Value) RunError!?Value {
    if (v.isInt32()) {
        const i = v.asInt32();
        // -INT_MIN overflows; promote to double in that case.
        if (i == std.math.minInt(i32)) return Value.fromDouble(-@as(f64, @floatFromInt(i)));
        // -0 must round-trip as Double — the SMI representation
        // collapses sign on zero, but §6.1.6.1 NumberValue
        // distinguishes +0 from -0 so `Object.is(-0, 0)` is false
        // and `1 / (-0) === -Infinity`.
        if (i == 0) return Value.fromDouble(-0.0);
        return Value.fromInt32(-i);
    }
    // §13.5.5 Unary `-` — ToNumeric first; BigInt negation is
    // handled by the caller in the dispatch loop. Plain primitives
    // and objects-with-valueOf land here.
    const prim = (try toNumericPrimitive(realm, v)) orelse return null;
    if (heap_mod.valueAsBigInt(prim)) |bi| {
        // §6.1.6.2.1 BigInt::unaryMinus.
        const neg = bigint_mod.negate(realm.heap.allocator, borrowBigInt(bi)) catch return error.OutOfMemory;
        const out = realm.heap.allocateBigIntValue(neg) catch return error.OutOfMemory;
        return heap_mod.taggedBigInt(out);
    }
    return Value.fromDouble(-toNumber(prim));
}

pub fn unaryBitNot(realm: *Realm, v: Value) RunError!?Value {
    const prim = (try toNumericPrimitive(realm, v)) orelse return null;
    if (heap_mod.valueAsBigInt(prim)) |bi| {
        // §6.1.6.2.2 BigInt::bitwiseNOT(x) = -x - 1.
        const r = bigint_mod.bitwiseNot(realm.heap.allocator, borrowBigInt(bi)) catch return error.OutOfMemory;
        const out = realm.heap.allocateBigIntValue(r) catch return error.OutOfMemory;
        return heap_mod.taggedBigInt(out);
    }
    return Value.fromInt32(~toInt32(prim));
}

pub fn unaryToNumber(realm: *Realm, v: Value) RunError!?Value {
    if (v.isInt32() or v.isDouble()) return v;
    const prim = (try toNumericPrimitive(realm, v)) orelse return null;
    // §13.5.4 Unary `+` — runs ToNumber on the operand. §7.1.4
    // ToNumber rejects BigInt with a TypeError. Note this differs
    // from prefix `++` / postfix `++` which dispatch via ToNumeric
    // (see `unaryToNumeric`) and DO accept BigInt. Test262
    // `language/expressions/unary-plus/bigint-throws.js`.
    if (heap_mod.isBigInt(prim)) {
        realm.pending_exception = try makeTypeError(realm, "Cannot convert a BigInt to a number");
        return null;
    }
    const d = toNumber(prim);
    // Try int32 fast path on the way out.
    if (!std.math.isNan(d) and d == @trunc(d) and d >= std.math.minInt(i32) and d <= std.math.maxInt(i32)) {
        return Value.fromInt32(@intFromFloat(d));
    }
    return Value.fromDouble(d);
}

/// §7.1.4.1 ToNumeric — like ToNumber but a BigInt operand
/// passes through. Emitted by `++` / `--` so the subsequent
/// `inc` / `dec` opcode can dispatch on the operand's numeric
/// type without TypeError-ing a BigInt at the coerce step.
pub fn unaryToNumeric(realm: *Realm, v: Value) RunError!?Value {
    if (v.isInt32() or v.isDouble()) return v;
    const prim = (try toNumericPrimitive(realm, v)) orelse return null;
    if (heap_mod.isBigInt(prim)) return prim;
    const d = toNumber(prim);
    if (!std.math.isNan(d) and d == @trunc(d) and d >= std.math.minInt(i32) and d <= std.math.maxInt(i32)) {
        return Value.fromInt32(@intFromFloat(d));
    }
    return Value.fromDouble(d);
}

/// §13.4 PostfixExpression / PrefixUpdateExpression evaluation —
/// `Type(oldValue)::add(oldValue, Type(oldValue)::unit)`. The unit
/// is `1n` for BigInts and `1` for Numbers, so the bump operator
/// must dispatch on the operand's numeric type rather than mixing
/// it with a Number-typed `1`. `delta` is `+1` (increment) or
/// `−1` (decrement). The input is assumed to be already coerced
/// via ToNumeric (the compiler emits a `to_number` immediately
/// before the bump).
pub fn incOrDec(realm: *Realm, v: Value, delta: i32) RunError!?Value {
    if (heap_mod.valueAsBigInt(v)) |bi| {
        // §6.1.6.2.7 BigInt::add(x, ±1n) — the §13.4 update unit.
        const delta_mag = [_]bigint_mod.Limb{1};
        const unit = BigIntValue{ .sign = delta < 0, .limbs = @constCast(delta_mag[0..]) };
        const sum = bigint_mod.add(realm.heap.allocator, borrowBigInt(bi), unit) catch return error.OutOfMemory;
        const out = realm.heap.allocateBigIntValue(sum) catch return error.OutOfMemory;
        return heap_mod.taggedBigInt(out);
    }
    if (v.isInt32()) {
        const ov = @addWithOverflow(v.asInt32(), delta);
        if (ov[1] == 0) return Value.fromInt32(ov[0]);
        return Value.fromDouble(@as(f64, @floatFromInt(v.asInt32())) + @as(f64, @floatFromInt(delta)));
    }
    if (v.isDouble()) {
        return Value.fromDouble(v.asDouble() + @as(f64, @floatFromInt(delta)));
    }
    // ToNumeric on an exotic that returned NaN-y value: treat as
    // NaN-arithmetic — the `to_number` op already produced this
    // shape, so just push NaN through.
    return Value.fromDouble(std.math.nan(f64));
}

/// §7.1.6 / §6.1.6.1 — addition is the only operator with the
/// string-concatenation shortcut. Returns null when an exception
/// is pending on the realm so the caller can unwind through the
/// dispatch loop.
pub fn addValues(realm: *Realm, lhs: Value, rhs: Value) RunError!?Value {
    // §13.15.4 ApplyStringOrNumericBinaryOperator. Both operands
    // go through ToPrimitive (which consults
    // `Symbol.toPrimitive` / `valueOf` / `toString` on objects)
    // before any numeric or string coercion. Throws inside user
    // code surface via `pending_exception`.
    var l = lhs;
    var r = rhs;
    // §13.15.4 step 1: `lprim = ? ToPrimitive(lval)`. Only fires when
    // a side is a JS Object — Symbol / BigInt primitives short-
    // circuit the no-op call (and a recursive `toPrimitive` on them
    // would still return the value as-is per §7.1.1 step 2).
    if (heap_mod.isJSObject(l) or heap_mod.isJSObject(r)) {
        l = intrinsics_mod.toPrimitive(realm, l, .default) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.NativeThrew => return null,
        };
        r = intrinsics_mod.toPrimitive(realm, r, .default) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.NativeThrew => return null,
        };
    }
    // §13.15.4 — Symbol primitives never participate in `+`. Even
    // when one side is already string-typed, a Symbol on the other
    // side is a TypeError per §7.1.4.1 (the eventual ToString /
    // ToNumber call rejects it).
    if (heap_mod.isSymbol(l) or heap_mod.isSymbol(r)) {
        realm.pending_exception = try makeTypeError(realm, "Cannot convert a Symbol to a primitive value");
        return null;
    }
    const l_is_bigint = heap_mod.isBigInt(l);
    const r_is_bigint = heap_mod.isBigInt(r);
    if (l_is_bigint and r_is_bigint) {
        return (try bigintArith(realm, .add, l, r)) orelse return null;
    }
    if (l_is_bigint != r_is_bigint and !l.isString() and !r.isString()) {
        // Mixed Number + BigInt is a TypeError; if either side is
        // a string the spec routes to string-concatenation
        // (BigInt's ToString is well-defined).
        realm.pending_exception = try makeTypeError(realm, "Cannot mix BigInt and other types");
        return null;
    }
    // Both numbers: int32 fast path with overflow fallback to f64.
    if ((l.isInt32() or l.isDouble()) and (r.isInt32() or r.isDouble())) {
        if (l.isInt32() and r.isInt32()) {
            const a = l.asInt32();
            const b = r.asInt32();
            const ov = @addWithOverflow(a, b);
            if (ov[1] == 0) return Value.fromInt32(ov[0]);
        }
        return Value.fromDouble(toNumber(l) + toNumber(r));
    }
    if (l.isString() or r.isString()) {
        // §13.15.4 — string concatenation. When *both* operands are
        // already `JSString`s — the dominant `result += chunk`
        // accumulator pattern (test262's `buildString` in
        // `regExpUtils.js`, JSON building, template assembly) — route
        // through `allocateConsString`, which builds a lazy rope
        // node so the `+` is amortised O(1) instead of an O(n) byte
        // copy. The ConsString gates (min length, WTF-8 seam, depth
        // cap) decide rope-vs-flat internally; see
        // `Heap.allocateConsString`.
        if (l.isString() and r.isString()) {
            const ls: *JSString = @ptrCast(@alignCast(l.asString()));
            const rs: *JSString = @ptrCast(@alignCast(r.asString()));
            const s = realm.heap.allocateConsString(ls, rs) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.StringTooLong => {
                    realm.pending_exception = try makeRangeError(realm, "Invalid string length");
                    return null;
                },
            };
            return Value.fromString(s);
        }

        // Mixed string / non-string. The non-string side coerces
        // (ToString) into a short scratch slice; building a throwaway
        // flat `JSString` for it just to cons would cost more than
        // it saves. Stay on the single-allocation `allocateStringConcat2`
        // path — it joins the two coerced byte slices directly, no
        // intermediate buffer.
        var lhs_buf: [64]u8 = undefined;
        var rhs_buf: [64]u8 = undefined;
        const lhs_str = try valueToOwnedString(realm, l, &lhs_buf);
        defer if (lhs_str.allocated) realm.allocator.free(lhs_str.bytes);
        const rhs_str = try valueToOwnedString(realm, r, &rhs_buf);
        defer if (rhs_str.allocated) realm.allocator.free(rhs_str.bytes);

        const s = realm.heap.allocateStringConcat2(lhs_str.bytes, rhs_str.bytes) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            // §6.1.4 — the concatenation would exceed the maximum
            // string length (`u32` byte cap). V8 / JSC throw a
            // RangeError ("Invalid string length") here.
            error.StringTooLong => {
                realm.pending_exception = try makeRangeError(realm, "Invalid string length");
                return null;
            },
        };
        return Value.fromString(s);
    }
    return Value.fromDouble(toNumber(l) + toNumber(r));
}

pub const StringSlice = struct { bytes: []const u8, allocated: bool };

/// ToString for primitive values. Returns a slice that lives
/// either in the supplied scratch buffer (cheap path) or in a
/// freshly-allocated buffer (the `allocated` flag marks the
/// latter — caller must free).
pub fn valueToOwnedString(realm: *Realm, v: Value, scratch: *[64]u8) RunError!StringSlice {
    if (v.isString()) {
        const s: *JSString = @ptrCast(@alignCast(v.asString()));
        // A `JSString` may be a lazy cons (rope) node — materialise
        // it. `flatten` is O(1) for an already-flat node and caches
        // the result on a cons, so the returned slice is heap-owned
        // and outlives this call (the `allocated` flag stays false:
        // the caller must NOT free a slice owned by the GC heap).
        const bytes = s.flatten(realm.heap.bytes_allocator) catch return error.OutOfMemory;
        return .{ .bytes = bytes, .allocated = false };
    }
    if (v.isInt32()) {
        const written = std.fmt.bufPrint(scratch, "{d}", .{v.asInt32()}) catch unreachable;
        return .{ .bytes = written, .allocated = false };
    }
    if (v.isDouble()) {
        const d = v.asDouble();
        if (std.math.isNan(d)) return .{ .bytes = "NaN", .allocated = false };
        if (std.math.isInf(d)) return .{ .bytes = if (d > 0) "Infinity" else "-Infinity", .allocated = false };
        // Integer-valued doubles in the IEEE-754-exact range render
        // without a fractional part to match V8 / SM (§6.1.6.1
        // NumberToString — "1.0" prints as "1"). Outside the safe
        // range we let `std.fmt`'s default float format handle it.
        const safe_int_max: f64 = 9007199254740992.0; // 2^53
        if (d == @trunc(d) and d >= -safe_int_max and d <= safe_int_max) {
            const i: i64 = @intFromFloat(d);
            const written = std.fmt.bufPrint(scratch, "{d}", .{i}) catch unreachable;
            return .{ .bytes = written, .allocated = false };
        }
        const written = formatDoubleSafe(scratch, d);
        return .{ .bytes = written, .allocated = false };
    }
    if (v.isBool()) return .{ .bytes = if (v.asBool()) "true" else "false", .allocated = false };
    if (v.isNull()) return .{ .bytes = "null", .allocated = false };
    if (v.isUndefined()) return .{ .bytes = "undefined", .allocated = false };
    if (heap_mod.valueAsBigInt(v)) |bi| {
        // §6.1.6.2.21 BigInt::toString(10). An arbitrary-precision
        // value can exceed the 64-byte scratch buffer, so always
        // allocate — the caller frees when `allocated` is set.
        const written = bigint_mod.toStringAlloc(realm.allocator, bi, 10) catch return error.OutOfMemory;
        return .{ .bytes = written, .allocated = true };
    }
    if (heap_mod.valueAsPlainObject(v)) |obj| {
        // Primitive wrapper — unwrap.
        if (obj.getBoxedPrimitive()) |p| {
            return valueToOwnedString(realm, p, scratch);
        }
    }
    // §20.2.3.5 — real source for user functions, native-function
    // format otherwise. Matches `Function.prototype.toString` and
    // `stringifyArg` so all three string-conversion paths agree.
    if (heap_mod.valueAsFunction(v)) |fn_obj| {
        if (fn_obj.source) |src| {
            return .{ .bytes = src, .allocated = false };
        }
        // `nameBytes` (not the raw `name` slice) so a bound function
        // whose "bound …" rope name was left lazy still prints its name.
        const display_name: []const u8 = fn_obj.nameBytes() orelse "";
        const formatted = if (display_name.len == 0)
            std.fmt.allocPrint(realm.allocator, "function () {{ [native code] }}", .{}) catch return error.OutOfMemory
        else
            std.fmt.allocPrint(realm.allocator, "function {s}() {{ [native code] }}", .{display_name}) catch return error.OutOfMemory;
        return .{ .bytes = formatted, .allocated = true };
    }
    return .{ .bytes = "[object Object]", .allocated = false };
}

/// §7.2.15 IsStrictlyEqual. Same-type strict comparison; mixed
/// types are always unequal.
pub fn strictEq(a: Value, b: Value) bool {
    if (a.isInt32() and b.isInt32()) return a.asInt32() == b.asInt32();
    if (a.isInt32() and b.isDouble()) {
        const ad: f64 = @floatFromInt(a.asInt32());
        return ad == b.asDouble();
    }
    if (a.isDouble() and b.isInt32()) {
        const bd: f64 = @floatFromInt(b.asInt32());
        return a.asDouble() == bd;
    }
    if (a.isDouble() and b.isDouble()) return a.asDouble() == b.asDouble();
    if (a.isBool() and b.isBool()) return a.asBool() == b.asBool();
    if (a.isNull() and b.isNull()) return true;
    if (a.isUndefined() and b.isUndefined()) return true;
    if (a.isString() and b.isString()) {
        const as: *JSString = @ptrCast(@alignCast(a.asString()));
        const bs: *JSString = @ptrCast(@alignCast(b.asString()));
        return as.equals(bs);
    }
    // §6.1.6.2 — BigInts compare by numeric value, not pointer.
    if (heap_mod.valueAsBigInt(a)) |ab| {
        if (heap_mod.valueAsBigInt(b)) |bb| {
            return bigint_mod.equals(borrowBigInt(ab), borrowBigInt(bb));
        }
        return false;
    }
    if (a.isObject() and b.isObject()) return a.bits == b.bits;
    return false;
}

/// §7.2.14 IsLooselyEqual. Object → primitive coercion happens at
/// the call site; this handles the primitive subset. `allocator`
/// is used only for the BigInt-vs-String path (§7.2.14 step 12),
/// which must parse the string as a BigInt; every other branch is
/// allocation-free.
pub fn looseEq(allocator: std.mem.Allocator, a: Value, b: Value) bool {
    if (strictEq(a, b)) return true;
    if (a.isNull() and b.isUndefined()) return true;
    if (a.isUndefined() and b.isNull()) return true;
    if ((a.isInt32() or a.isDouble()) and b.isString()) {
        return strictEq(a, Value.fromDouble(toNumber(b)));
    }
    if (a.isString() and (b.isInt32() or b.isDouble())) {
        return strictEq(Value.fromDouble(toNumber(a)), b);
    }
    // §7.2.14 IsLooselyEqual steps 12-13: BigInt vs String —
    // convert the String via StringToBigInt; mismatch on parse
    // failure is `false`, not coerced. BigInt vs Number — compare
    // mathematical values (§6.1.6.1.13 / §6.1.6.2.13 are exact).
    if (heap_mod.valueAsBigInt(a)) |abi| {
        if (b.isString()) {
            const s: *JSString = @ptrCast(@alignCast(b.asString()));
            return stringEqualsBigInt(allocator, s.flatBytes(), abi);
        }
        if (b.isInt32()) return bigintEqualsI64(abi, b.asInt32());
        if (b.isDouble()) return bigintEqualsDouble(allocator, abi, b.asDouble());
        if (b.isBool()) return bigintEqualsI64(abi, if (b.asBool()) 1 else 0);
    }
    if (heap_mod.valueAsBigInt(b)) |bbi| {
        if (a.isString()) {
            const s: *JSString = @ptrCast(@alignCast(a.asString()));
            return stringEqualsBigInt(allocator, s.flatBytes(), bbi);
        }
        if (a.isInt32()) return bigintEqualsI64(bbi, a.asInt32());
        if (a.isDouble()) return bigintEqualsDouble(allocator, bbi, a.asDouble());
        if (a.isBool()) return bigintEqualsI64(bbi, if (a.asBool()) 1 else 0);
    }
    if (a.isBool()) return looseEq(allocator, Value.fromInt32(if (a.asBool()) 1 else 0), b);
    if (b.isBool()) return looseEq(allocator, a, Value.fromInt32(if (b.asBool()) 1 else 0));
    return false;
}

/// §7.1.14 StringToBigInt + §7.2.14 BigInt/String comparison.
/// Returns true iff `s` parses (per StringToBigInt — optional
/// sign + decimal / hex / oct / bin, whitespace-trimmed) into a
/// BigInt whose mathematical value equals `bi`. A parse failure
/// is `false`, not coerced.
fn stringEqualsBigInt(allocator: std.mem.Allocator, s: []const u8, bi: *const JSBigInt) bool {
    const parsed = bigint_mod.parseStringToValue(allocator, s) catch return false;
    defer if (parsed.limbs.len != 0) allocator.free(parsed.limbs);
    return bigint_mod.equals(parsed, borrowBigInt(bi));
}

/// §6.1.6.2.13 BigInt::equal cross-type with Number: equal iff
/// y is finite, y has no fractional part, and x = ℝ(y).
fn bigintEqualsDouble(allocator: std.mem.Allocator, bi: *const JSBigInt, d: f64) bool {
    if (std.math.isNan(d) or std.math.isInf(d)) return false;
    if (d != @trunc(d)) return false;
    // Compare via the bit-exact integer order: a BigInt equals an
    // integral double iff cmp == .eq.
    return bigintCompareDouble(allocator, bi, d) == .eq;
}

/// §6.1.6.2.13 BigInt::equal — compare a BigInt against a small
/// signed integer.
fn bigintEqualsI64(bi: *const JSBigInt, n: i64) bool {
    if (n == 0) return bi.isZero();
    const neg = n < 0;
    if (bi.sign != neg) return false;
    const mag: u64 = if (neg) (~@as(u64, @bitCast(n))) +% 1 else @intCast(n);
    if (bi.limbs.len != 1) return false;
    return bi.limbs[0] == mag;
}

/// §7.2.13 — order a BigInt against a finite double by exact
/// mathematical value. The integral part is compared exactly by
/// converting `trunc(d)` to a BigInt; a fractional part on `d`
/// only matters when the integral parts tie. `allocator` is used
/// for the exact conversion (a stack-bounded amount of memory,
/// freed before return).
fn bigintCompareDouble(allocator: std.mem.Allocator, bi: *const JSBigInt, d: f64) std.math.Order {
    // §7.2.13 steps 4.f/4.g — ±Infinity dominates any finite
    // BigInt. (NaN is filtered by the caller before this point.)
    if (std.math.isInf(d)) {
        return if (d > 0) .lt else .gt; // bigint < +inf, bigint > -inf
    }
    // Sign disagreement is decisive.
    const d_neg = std.math.signbit(d) and d != 0;
    if (bi.isZero()) {
        if (d == 0) return .eq;
        return if (d_neg) .gt else .lt;
    }
    if (bi.sign and !d_neg) return .lt;
    if (!bi.sign and d_neg) return .gt;
    // Same sign — compare magnitudes. Small BigInts and small
    // integral doubles round-trip exactly through f64.
    const bi_bits = bi.bitLength();
    const trunc_d = @trunc(d);
    if (bi_bits <= 52 and @abs(trunc_d) < 9007199254740992.0) {
        const bf = bi.toF64();
        if (bf < trunc_d) return .lt;
        if (bf > trunc_d) return .gt;
        // Integral parts tie — the double's fraction breaks it.
        if (d == trunc_d) return .eq;
        // bi == trunc(d) < d  ⇒  bi < d  (for positive d);
        // for negative d, trunc(d) > d so bi > d.
        return if (d > trunc_d) .lt else .gt;
    }
    // Large operand: convert trunc(d) to an exact BigInt and
    // compare BigInt-to-BigInt. trunc(d) is an integer here.
    const d_as_bi = bigint_mod.fromDouble(allocator, trunc_d) catch {
        // On OOM fall back to the lossy bit-length heuristic.
        return bigintCompareDoubleApprox(bi, d);
    };
    defer if (d_as_bi.limbs.len != 0) allocator.free(d_as_bi.limbs);
    const ord = bigint_mod.compare(borrowBigInt(bi), d_as_bi);
    if (ord != .eq) return ord;
    // Integral parts equal — the double's fractional part decides.
    if (d == trunc_d) return .eq;
    return if (d > trunc_d) .lt else .gt;
}

/// Lossy fallback used only when an exact conversion can't
/// allocate — compares by bit length, then by f64 projection.
fn bigintCompareDoubleApprox(bi: *const JSBigInt, d: f64) std.math.Order {
    const ad = @abs(d);
    const d_exp = std.math.frexp(ad).exponent;
    const d_bits: usize = if (d_exp <= 0) 0 else @intCast(d_exp);
    const bi_bits = bi.bitLength();
    if (bi_bits != d_bits) {
        const mag_order: std.math.Order = if (bi_bits < d_bits) .lt else .gt;
        return if (bi.sign) reverseOrder(mag_order) else mag_order;
    }
    const bf = @abs(bi.toF64());
    const mag_order: std.math.Order = if (bf < ad) .lt else if (bf > ad) .gt else .eq;
    return if (bi.sign) reverseOrder(mag_order) else mag_order;
}

fn reverseOrder(o: std.math.Order) std.math.Order {
    return switch (o) {
        .lt => .gt,
        .gt => .lt,
        .eq => .eq,
    };
}

pub fn relational(comptime op: RelOp, realm: *Realm, lhs: Value, rhs: Value) NativeError!Value {
    // §7.2.13 IsLessThan with the standard four-direction
    // generalisation. The spec funnels every result of the abstract
    // "Less-Than" through a "false-if-undefined" filter: pairs whose
    // comparison is *undefined* (NaN involvement, StringToBigInt
    // parse failure, etc.) collapse to `false` for `<` / `>` and to
    // `false` for `<=` / `>=` as well — the §13.10 spec text negates
    // the LessThan result only when it's `true` / `false`.
    //
    // Symbol operands of any flavour throw TypeError (§7.1.4
    // ToNumber, §7.1.13 ToNumeric — Symbols can't be numerified).
    if (heap_mod.valueAsSymbol(lhs) != null or heap_mod.valueAsSymbol(rhs) != null) {
        realm.pending_exception = try intrinsics_mod.newTypeError(realm, "Cannot convert a Symbol value to a number");
        return error.NativeThrew;
    }

    if (heap_mod.valueAsBigInt(lhs)) |a| {
        if (heap_mod.valueAsBigInt(rhs)) |b| {
            // §6.1.6.2.12 BigInt::lessThan — exact mathematical order.
            return Value.fromBool(applyRelOpOrder(op, bigint_mod.compare(borrowBigInt(a), borrowBigInt(b))));
        }
        // §7.2.13 step 3.b — BigInt vs String: StringToBigInt the
        // string; on failure the result is undefined → false.
        if (rhs.isString()) {
            const s: *JSString = @ptrCast(@alignCast(rhs.asString()));
            const parsed = bigint_mod.parseStringToValue(realm.heap.allocator, s.flatBytes()) catch return Value.false_;
            defer if (parsed.limbs.len != 0) realm.heap.allocator.free(parsed.limbs);
            return Value.fromBool(applyRelOpOrder(op, bigint_mod.compare(borrowBigInt(a), parsed)));
        }
        // §7.2.13 — BigInt vs Number: compare mathematical values
        // exactly (NOT by coercion). A NaN on the Number side makes
        // the comparison undefined → false.
        const bn = toNumber(rhs);
        if (std.math.isNan(bn)) return Value.false_;
        return Value.fromBool(applyRelOpDouble(realm.heap.allocator, op, a, bn, true));
    }
    if (heap_mod.valueAsBigInt(rhs)) |b| {
        if (lhs.isString()) {
            const s: *JSString = @ptrCast(@alignCast(lhs.asString()));
            const parsed = bigint_mod.parseStringToValue(realm.heap.allocator, s.flatBytes()) catch return Value.false_;
            defer if (parsed.limbs.len != 0) realm.heap.allocator.free(parsed.limbs);
            return Value.fromBool(applyRelOpOrder(op, bigint_mod.compare(parsed, borrowBigInt(b))));
        }
        const an = toNumber(lhs);
        if (std.math.isNan(an)) return Value.false_;
        return Value.fromBool(applyRelOpDouble(realm.heap.allocator, op, b, an, false));
    }
    if (lhs.isString() and rhs.isString()) {
        // §6.1.4 — Strings are sequences of 16-bit code units;
        // compare by UTF-16 code-unit value, not WTF-8 byte order.
        const ls: *JSString = @ptrCast(@alignCast(lhs.asString()));
        const rs: *JSString = @ptrCast(@alignCast(rhs.asString()));
        const cmp = utf16.compareCodeUnits(ls.flatBytes(), rs.flatBytes());
        const result = switch (op) {
            .lt => cmp == .lt,
            .gt => cmp == .gt,
            .le => cmp != .gt,
            .ge => cmp != .lt,
        };
        return Value.fromBool(result);
    }
    const a = toNumber(lhs);
    const b = toNumber(rhs);
    if (std.math.isNan(a) or std.math.isNan(b)) return Value.false_;
    return Value.fromBool(applyRelOpFloat(op, a, b));
}

inline fn applyRelOpFloat(comptime op: RelOp, a: f64, b: f64) bool {
    return switch (op) {
        .lt => a < b,
        .gt => a > b,
        .le => a <= b,
        .ge => a >= b,
    };
}

/// Map a §7.2.13 mathematical `Order` (lhs vs rhs) to the boolean
/// result of the requested relational operator.
inline fn applyRelOpOrder(comptime op: RelOp, ord: std.math.Order) bool {
    return switch (op) {
        .lt => ord == .lt,
        .gt => ord == .gt,
        .le => ord != .gt,
        .ge => ord != .lt,
    };
}

/// §7.2.13 — relational compare a BigInt against a finite Number
/// by exact mathematical value. `bigint_is_lhs` records operand
/// order so `<` / `>` come out right.
fn applyRelOpDouble(allocator: std.mem.Allocator, comptime op: RelOp, bi: *const JSBigInt, d: f64, bigint_is_lhs: bool) bool {
    // `bigintCompareDouble` already accounts for the double's
    // fractional part, returning the exact (bigint, double) order.
    var ord = bigintCompareDouble(allocator, bi, d);
    if (!bigint_is_lhs) ord = reverseOrder(ord);
    return applyRelOpOrder(op, ord);
}

pub fn typeOf(realm: *Realm, v: Value) RunError!Value {
    const name: []const u8 = if (v.isUndefined())
        "undefined"
    else if (v.isNull())
        "object" // §13.5.3 — historical quirk.
    else if (v.isBool())
        "boolean"
    else if (v.isInt32() or v.isDouble())
        "number"
    else if (v.isString())
        "string"
    else if (heap_mod.isFunction(v))
        "function"
    else if (heap_mod.isSymbol(v))
        "symbol"
    else if (heap_mod.isBigInt(v))
        "bigint"
    else if (heap_mod.valueAsPlainObject(v)) |po|
        // §13.5.3 — typeof on a plain JSObject is "object"
        // unless the object carries callable-exotic semantics:
        // §10.5.x — a Proxy reports "function" iff its target was
        //   callable at construction time;
        // §20.2.3 — %Function.prototype% is itself a built-in
        //   function. Both cases ride the same `proxy_callable`
        //   flag.
        if (po.brand.proxy_callable) "function" else "object"
    else
        "undefined";
    const s = realm.heap.allocateString(name) catch return error.OutOfMemory;
    return Value.fromString(s);
}
