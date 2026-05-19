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

const Value = @import("value.zig").Value;
const JSString = @import("string.zig").JSString;
const Realm = @import("realm.zig").Realm;
const heap_mod = @import("heap.zig");
const intrinsics_mod = @import("intrinsics.zig");
const utf16 = @import("utf16.zig");

pub const RunError = @import("interpreter.zig").RunError;
pub const NativeError = @import("function.zig").NativeError;
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
    if (heap_mod.valueAsBigInt(v)) |bi| return bi.value != 0;
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
        const start_idx = skipStrWhiteSpaceFwd(s.bytes);
        const end_idx = skipStrWhiteSpaceRev(s.bytes);
        if (start_idx >= end_idx) return 0.0;
        const trimmed = s.bytes[start_idx..end_idx];
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
        if (obj.boxed_primitive) |p| return toNumber(p);
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
    const a = a_bi.?.value;
    const b = b_bi.?.value;
    const result: i128 = switch (op) {
        .add => std.math.add(i128, a, b) catch {
            realm.pending_exception = try makeRangeError(realm, "BigInt arithmetic overflow");
            return null;
        },
        .sub => std.math.sub(i128, a, b) catch {
            realm.pending_exception = try makeRangeError(realm, "BigInt arithmetic overflow");
            return null;
        },
        .mul => std.math.mul(i128, a, b) catch {
            realm.pending_exception = try makeRangeError(realm, "BigInt arithmetic overflow");
            return null;
        },
        .div => blk: {
            if (b == 0) {
                realm.pending_exception = try makeRangeError(realm, "Division by zero");
                return null;
            }
            break :blk @divTrunc(a, b);
        },
        .mod => blk: {
            if (b == 0) {
                realm.pending_exception = try makeRangeError(realm, "Modulo by zero");
                return null;
            }
            break :blk @rem(a, b);
        },
        .pow => blk: {
            if (b < 0) {
                realm.pending_exception = try makeRangeError(realm, "BigInt exponent must be non-negative");
                return null;
            }
            // Cap exponent — i128 overflows quickly.
            if (b > 200) {
                realm.pending_exception = try makeRangeError(realm, "BigInt exponent too large");
                return null;
            }
            var acc: i128 = 1;
            var i: i128 = 0;
            while (i < b) : (i += 1) {
                acc = std.math.mul(i128, acc, a) catch {
                    realm.pending_exception = try makeRangeError(realm, "BigInt arithmetic overflow");
                    return null;
                };
            }
            break :blk acc;
        },
    };
    const out = realm.heap.allocateBigInt(result) catch return error.OutOfMemory;
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
        // §6.1.6.2.{17,18,19,20,21} BigInt::bitwise{AND,OR,XOR} /
        // leftShift / signedRightShift. `>>>` (unsignedRightShift)
        // is §6.1.6.2.22 — defined to throw TypeError on BigInt
        // operands because BigInts have no fixed width.
        const a_bi = heap_mod.valueAsBigInt(l).?;
        const b_bi = heap_mod.valueAsBigInt(r).?;
        const a_val = a_bi.value;
        const b_val = b_bi.value;
        const result: i128 = switch (op) {
            // Two's-complement bitwise on i128 matches the spec's
            // "infinite-length two's-complement string of bits"
            // model exactly while the magnitude fits.
            .bit_and => a_val & b_val,
            .bit_or => a_val | b_val,
            .bit_xor => a_val ^ b_val,
            .shl => blk: {
                // §6.1.6.2.20 BigInt::leftShift: negative y shifts
                // right with floor rounding (equivalent to signed
                // arithmetic shift right by |y|).
                if (b_val == 0) break :blk a_val;
                if (b_val > 0) {
                    if (b_val >= 128) {
                        realm.pending_exception = try makeRangeError(realm, "BigInt arithmetic overflow");
                        return null;
                    }
                    const sh: u7 = @intCast(b_val);
                    const shifted = std.math.shl(i128, a_val, sh);
                    // Detect overflow: shifting back must reproduce a_val.
                    if (a_val != 0 and std.math.shr(i128, shifted, sh) != a_val) {
                        realm.pending_exception = try makeRangeError(realm, "BigInt arithmetic overflow");
                        return null;
                    }
                    break :blk shifted;
                }
                // Negative shift count: arithmetic shift right by |b_val|.
                const neg = -b_val;
                if (neg >= 128) {
                    break :blk if (a_val < 0) @as(i128, -1) else @as(i128, 0);
                }
                const sh: u7 = @intCast(neg);
                break :blk std.math.shr(i128, a_val, sh);
            },
            .shr => blk: {
                // §6.1.6.2.21 BigInt::signedRightShift(x, y) ≡
                // leftShift(x, -y). Reuse the leftShift logic by
                // negating y.
                if (b_val == 0) break :blk a_val;
                if (b_val > 0) {
                    if (b_val >= 128) {
                        break :blk if (a_val < 0) @as(i128, -1) else @as(i128, 0);
                    }
                    const sh: u7 = @intCast(b_val);
                    break :blk std.math.shr(i128, a_val, sh);
                }
                // Negative right shift = left shift by |b_val|.
                const neg = -b_val;
                if (neg >= 128) {
                    realm.pending_exception = try makeRangeError(realm, "BigInt arithmetic overflow");
                    return null;
                }
                const sh: u7 = @intCast(neg);
                const shifted = std.math.shl(i128, a_val, sh);
                if (a_val != 0 and std.math.shr(i128, shifted, sh) != a_val) {
                    realm.pending_exception = try makeRangeError(realm, "BigInt arithmetic overflow");
                    return null;
                }
                break :blk shifted;
            },
            .shr_u => {
                // §6.1.6.2.22 BigInt::unsignedRightShift always
                // throws TypeError — BigInts are not fixed-width.
                realm.pending_exception = try makeTypeError(realm, "BigInts have no unsigned right shift, use >> instead");
                return null;
            },
        };
        const out = realm.heap.allocateBigInt(result) catch return error.OutOfMemory;
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
        const neg = realm.heap.allocateBigInt(-bi.value) catch return error.OutOfMemory;
        return heap_mod.taggedBigInt(neg);
    }
    return Value.fromDouble(-toNumber(prim));
}

pub fn unaryBitNot(realm: *Realm, v: Value) RunError!?Value {
    const prim = (try toNumericPrimitive(realm, v)) orelse return null;
    if (heap_mod.valueAsBigInt(prim)) |bi| {
        // §6.1.6.2.23 BigInt::bitwiseNOT(x) = -x - 1. The i128
        // backing matches: `~x` in two's complement is exactly
        // `-x - 1`, with no overflow except at i128 min/max which
        // are well beyond practical use.
        const neg = std.math.sub(i128, -bi.value, 1) catch {
            realm.pending_exception = try makeRangeError(realm, "BigInt arithmetic overflow");
            return null;
        };
        const out = realm.heap.allocateBigInt(neg) catch return error.OutOfMemory;
        return heap_mod.taggedBigInt(out);
    }
    return Value.fromInt32(~toInt32(prim));
}

pub fn unaryToNumber(realm: *Realm, v: Value) RunError!?Value {
    if (v.isInt32() or v.isDouble()) return v;
    const prim = (try toNumericPrimitive(realm, v)) orelse return null;
    if (heap_mod.isBigInt(prim)) return prim;
    const d = toNumber(prim);
    // Try int32 fast path on the way out.
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
        // §6.1.6.2.7 BigInt::add(x, 1n) — i128 with overflow trap.
        const sum = std.math.add(i128, bi.value, @as(i128, delta)) catch {
            realm.pending_exception = try makeRangeError(realm, "BigInt arithmetic overflow");
            return null;
        };
        const out = realm.heap.allocateBigInt(sum) catch return error.OutOfMemory;
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
        var lhs_buf: [64]u8 = undefined;
        var rhs_buf: [64]u8 = undefined;
        const lhs_str = try valueToOwnedString(realm, l, &lhs_buf);
        defer if (lhs_str.allocated) realm.allocator.free(lhs_str.bytes);
        const rhs_str = try valueToOwnedString(realm, r, &rhs_buf);
        defer if (rhs_str.allocated) realm.allocator.free(rhs_str.bytes);

        const total = lhs_str.bytes.len + rhs_str.bytes.len;
        const buf = realm.allocator.alloc(u8, total) catch return error.OutOfMemory;
        @memcpy(buf[0..lhs_str.bytes.len], lhs_str.bytes);
        @memcpy(buf[lhs_str.bytes.len..], rhs_str.bytes);
        defer realm.allocator.free(buf);
        const s = realm.heap.allocateString(buf) catch return error.OutOfMemory;
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
        return .{ .bytes = s.bytes, .allocated = false };
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
        const written = std.fmt.bufPrint(scratch, "{d}", .{bi.value}) catch unreachable;
        return .{ .bytes = written, .allocated = false };
    }
    if (heap_mod.valueAsPlainObject(v)) |obj| {
        // Primitive wrapper — unwrap.
        if (obj.boxed_primitive) |p| {
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
        const display_name: []const u8 = if (fn_obj.name) |n| n else "";
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
        if (heap_mod.valueAsBigInt(b)) |bb| return ab.value == bb.value;
        return false;
    }
    if (a.isObject() and b.isObject()) return a.bits == b.bits;
    return false;
}

/// §7.2.14 IsLooselyEqual. later covers the primitive subset; the
/// object → primitive coercion (`ToPrimitive`) lands with the
/// object model later.
pub fn looseEq(a: Value, b: Value) bool {
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
            return stringEqualsBigInt(s.bytes, abi.value);
        }
        if (b.isInt32()) return abi.value == @as(i128, b.asInt32());
        if (b.isDouble()) return bigintEqualsDouble(abi.value, b.asDouble());
        if (b.isBool()) return abi.value == @as(i128, if (b.asBool()) 1 else 0);
    }
    if (heap_mod.valueAsBigInt(b)) |bbi| {
        if (a.isString()) {
            const s: *JSString = @ptrCast(@alignCast(a.asString()));
            return stringEqualsBigInt(s.bytes, bbi.value);
        }
        if (a.isInt32()) return bbi.value == @as(i128, a.asInt32());
        if (a.isDouble()) return bigintEqualsDouble(bbi.value, a.asDouble());
        if (a.isBool()) return bbi.value == @as(i128, if (a.asBool()) 1 else 0);
    }
    if (a.isBool()) return looseEq(Value.fromInt32(if (a.asBool()) 1 else 0), b);
    if (b.isBool()) return looseEq(a, Value.fromInt32(if (b.asBool()) 1 else 0));
    return false;
}

/// §7.1.14 StringToBigInt + §7.2.14 BigInt/Number comparison
/// fast-path. Returns true iff `s` parses as a finite integer
/// (per the BigInt-literal grammar: optional sign + decimal /
/// hex / oct / bin) whose mathematical value equals `bi`.
fn stringEqualsBigInt(s: []const u8, bi: i128) bool {
    const trimmed = std.mem.trim(u8, s, " \t\r\n");
    if (trimmed.len == 0) return bi == 0;
    var i: usize = 0;
    var negative = false;
    if (trimmed[i] == '+') {
        i += 1;
    } else if (trimmed[i] == '-') {
        negative = true;
        i += 1;
    }
    if (i >= trimmed.len) return false;
    var value: i128 = 0;
    while (i < trimmed.len) : (i += 1) {
        const c = trimmed[i];
        if (c < '0' or c > '9') return false;
        const digit: i128 = c - '0';
        value = std.math.mul(i128, value, 10) catch return false;
        value = std.math.add(i128, value, digit) catch return false;
    }
    if (negative) value = -value;
    return value == bi;
}

/// §6.1.6.2.13 BigInt::equal cross-type with Number: equal iff
/// y is finite, y has no fractional part, and x = ℝ(y).
fn bigintEqualsDouble(bi: i128, d: f64) bool {
    if (std.math.isNan(d) or std.math.isInf(d)) return false;
    if (d != @trunc(d)) return false;
    // Range guard — i128 fits any safe-integer double exactly.
    if (d > 1.7e38 or d < -1.7e38) return false;
    const as_int: i128 = @intFromFloat(d);
    return as_int == bi;
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
            return Value.fromBool(applyRelOp(op, a.value, b.value));
        }
        // §7.2.13 step 3.b — BigInt vs String: StringToBigInt the
        // string; on failure the result is undefined → false.
        if (rhs.isString()) {
            const s: *JSString = @ptrCast(@alignCast(rhs.asString()));
            const parsed = tryStringToBigInt(s.bytes) orelse return Value.false_;
            return Value.fromBool(applyRelOp(op, a.value, parsed));
        }
        // BigInt vs Number — compare numerically with the BigInt
        // converted to f64 (lossy for large BigInts but matches
        // V8 / SM behaviour for the common cases test262 hits).
        const af: f64 = @floatFromInt(a.value);
        const bn = toNumber(rhs);
        if (std.math.isNan(bn)) return Value.false_;
        return Value.fromBool(applyRelOpFloat(op, af, bn));
    }
    if (heap_mod.valueAsBigInt(rhs)) |b| {
        if (lhs.isString()) {
            const s: *JSString = @ptrCast(@alignCast(lhs.asString()));
            const parsed = tryStringToBigInt(s.bytes) orelse return Value.false_;
            return Value.fromBool(applyRelOp(op, parsed, b.value));
        }
        const bf: f64 = @floatFromInt(b.value);
        const an = toNumber(lhs);
        if (std.math.isNan(an)) return Value.false_;
        return Value.fromBool(applyRelOpFloat(op, an, bf));
    }
    if (lhs.isString() and rhs.isString()) {
        // §6.1.4 — Strings are sequences of 16-bit code units;
        // compare by UTF-16 code-unit value, not WTF-8 byte order.
        const ls: *JSString = @ptrCast(@alignCast(lhs.asString()));
        const rs: *JSString = @ptrCast(@alignCast(rhs.asString()));
        const cmp = utf16.compareCodeUnits(ls.bytes, rs.bytes);
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

inline fn applyRelOp(comptime op: RelOp, a: i128, b: i128) bool {
    return switch (op) {
        .lt => a < b,
        .gt => a > b,
        .le => a <= b,
        .ge => a >= b,
    };
}

inline fn applyRelOpFloat(comptime op: RelOp, a: f64, b: f64) bool {
    return switch (op) {
        .lt => a < b,
        .gt => a > b,
        .le => a <= b,
        .ge => a >= b,
    };
}

/// §7.1.14 StringToBigInt — returns null when the trimmed string
/// is not a StringIntegerLiteral. Decimal point, exponent,
/// `Infinity`, and any non-digit produce null. Whitespace-only /
/// empty string maps to 0 (matches the constructor path).
fn tryStringToBigInt(bytes: []const u8) ?i128 {
    const trimmed = std.mem.trim(u8, bytes, " \t\n\r\u{000B}\u{000C}\u{00A0}\u{FEFF}");
    if (trimmed.len == 0) return 0;
    var rest = trimmed;
    var negate = false;
    var has_sign = false;
    if (rest[0] == '-') {
        negate = true;
        has_sign = true;
        rest = rest[1..];
    } else if (rest[0] == '+') {
        has_sign = true;
        rest = rest[1..];
    }
    if (rest.len == 0) return null;
    if (rest.len >= 2 and rest[0] == '0') {
        const radix: ?u8 = switch (rest[1]) {
            'b', 'B' => @as(u8, 2),
            'o', 'O' => @as(u8, 8),
            'x', 'X' => @as(u8, 16),
            else => null,
        };
        if (radix) |r| {
            if (has_sign) return null;
            const body = rest[2..];
            if (body.len == 0) return null;
            const v = std.fmt.parseInt(i128, body, r) catch return null;
            return v;
        }
    }
    for (rest) |c| {
        if (c < '0' or c > '9') return null;
    }
    const v = std.fmt.parseInt(i128, rest, 10) catch return null;
    return if (negate) -v else v;
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
        if (po.proxy_callable) "function" else "object"
    else
        "undefined";
    const s = realm.heap.allocateString(name) catch return error.OutOfMemory;
    return Value.fromString(s);
}
