//! §21.2 BigInt — extracted from `intrinsics.zig`. The
//! BigInt constructor (`BigInt(n)` ToBigInts; `new BigInt()`
//! throws), prototype `toString` / `valueOf`, and statics
//! `BigInt.asIntN` / `BigInt.asUintN`. Cynic's BigInt storage
//! is `i128` (caps at ±2^127); arbitrary-precision is later.

const std = @import("std");

const Realm = @import("../realm.zig").Realm;
const Value = @import("../value.zig").Value;
const JSString = @import("../string.zig").JSString;
const JSObject = @import("../object.zig").JSObject;
const JSFunction = @import("../function.zig").JSFunction;
const JSBigInt = @import("../bigint.zig").JSBigInt;
const NativeError = @import("../function.zig").NativeError;
const heap_mod = @import("../heap.zig");
const intrinsics = @import("../intrinsics.zig");

const installConstructor = intrinsics.installConstructor;
const installNativeMethod = intrinsics.installNativeMethod;
const installNativeMethodOnProto = intrinsics.installNativeMethodOnProto;
const argOr = intrinsics.argOr;
const throwTypeError = intrinsics.throwTypeError;
const throwRangeError = intrinsics.throwRangeError;

// ── §21.2 BigInt ────────────────────────────────────────────────────

pub fn install(realm: *Realm) !void {
    // BigInt() called without `new` performs ToBigInt on the
    // arg and returns a primitive. `new BigInt()` is a
    // TypeError per §21.2.1 (the constructor is intentionally
    // not callable with `new`).
    const r = try installConstructor(realm, .{
        .name = "BigInt", .ctor = bigintConstructor, .arity = 1,
        .is_class = false,
        .set_home_object = false,
        .to_string_tag = "BigInt",
    });
    const fn_obj = r.ctor;
    const proto = r.proto;

    try installNativeMethodOnProto(realm, proto, "toString", bigintToString, 0);
    // §21.2.3.3 BigInt.prototype.toLocaleString — like Number's,
    // Intl-less builds fall back to ToString.
    try installNativeMethodOnProto(realm, proto, "toLocaleString", bigintToLocaleString, 0);
    try installNativeMethodOnProto(realm, proto, "valueOf", bigintValueOf, 0);

    try installNativeMethod(realm, fn_obj, "asIntN", bigintAsIntN, 2);
    try installNativeMethod(realm, fn_obj, "asUintN", bigintAsUintN, 2);
}

fn bigintConstructor(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = this_value;
    const arg = argOr(args, 0, Value.undefined_);
    // §21.2.1.1 BigInt(value) — step 1: prim = ? ToPrimitive(value, number).
    // Step 2: if prim is a Number, return ? NumberToBigInt(prim).
    // Step 3: else return ? ToBigInt(prim).
    const prim = if (heap_mod.valueAsPlainObject(arg) != null)
        intrinsics.toPrimitive(realm, arg, .number) catch return error.NativeThrew
    else
        arg;
    if (prim.isInt32()) {
        const bi = realm.heap.allocateBigInt(@intCast(prim.asInt32())) catch return error.OutOfMemory;
        return heap_mod.taggedBigInt(bi);
    }
    if (prim.isDouble()) {
        const d = prim.asDouble();
        // §21.2.1.1.1 NumberToBigInt — RangeError for NaN / ±Infinity / non-integer.
        if (std.math.isNan(d) or std.math.isInf(d) or d != @trunc(d)) {
            return throwRangeError(realm, "Cannot convert non-integer Number to BigInt");
        }
        if (d > @as(f64, @floatFromInt(std.math.maxInt(i128))) or d < @as(f64, @floatFromInt(std.math.minInt(i128)))) {
            return throwRangeError(realm, "Number out of BigInt i128 range");
        }
        const bi = realm.heap.allocateBigInt(@intFromFloat(d)) catch return error.OutOfMemory;
        return heap_mod.taggedBigInt(bi);
    }
    return toBigIntValue(realm, prim) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.NativeThrew,
    };
}

/// §7.1.13 ToBigInt. Returns the JSBigInt-tagged Value.
///
/// Spec table: undefined / null / Number / Symbol → TypeError;
/// Boolean → 0n / 1n; String → StringToBigInt (SyntaxError on
/// failure); BigInt → identity. The `BigInt(number)` constructor
/// path is a *separate* entry point that uses NumberToBigInt
/// (§21.2.1.1 step 2.b) — ToBigInt itself never coerces a
/// Number.
pub fn toBigIntValue(realm: *Realm, v_in: Value) !Value {
    // §7.1.13 step 1 — ToPrimitive(arg, hint "number") for objects.
    // Without this, ToBigInt({ valueOf: () => 1n }) takes the
    // throwTypeError fall-through instead of returning 1n.
    const v = if (heap_mod.valueAsPlainObject(v_in) != null)
        try intrinsics.toPrimitive(realm, v_in, .number)
    else
        v_in;
    if (heap_mod.valueAsBigInt(v)) |_| return v;
    if (v.isBool()) {
        const bi = try realm.heap.allocateBigInt(if (v.asBool()) 1 else 0);
        return heap_mod.taggedBigInt(bi);
    }
    if (v.isInt32() or v.isDouble()) {
        // §7.1.13 step 2 — Numbers throw TypeError, *not* RangeError.
        return throwTypeError(realm, "Cannot convert a Number to BigInt without explicit BigInt() call");
    }
    if (v.isUndefined() or v.isNull()) {
        return throwTypeError(realm, "Cannot convert undefined / null to BigInt");
    }
    if (v.isString()) {
        const s: *JSString = @ptrCast(@alignCast(v.asString()));
        // §7.1.14 StringToBigInt — replace
        // StrUnsignedDecimalLiteral with DecimalDigits (so no
        // `Infinity` / `.` / exponent). Failure is a SyntaxError,
        // *not* TypeError per §7.1.13 step 3.b.
        return stringToBigInt(realm, s.bytes);
    }
    return throwTypeError(realm, "Cannot convert value to BigInt");
}

/// §7.1.14 StringToBigInt. The grammar is roughly:
///
///     StrNumericLiteral :=
///       StrDecimalLiteral             ([+-]? DecimalDigits)
///       NonDecimalIntegerLiteral      (no sign, 0b… / 0o… / 0x…)
///
/// Failures throw SyntaxError. Whitespace-only / empty strings
/// map to 0n.
fn stringToBigInt(realm: *Realm, bytes: []const u8) NativeError!Value {
    const trimmed = std.mem.trim(u8, bytes, " \t\n\r\u{000B}\u{000C}\u{00A0}\u{FEFF}");
    if (trimmed.len == 0) {
        const bi = realm.heap.allocateBigInt(0) catch return error.OutOfMemory;
        return heap_mod.taggedBigInt(bi);
    }
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
    if (rest.len == 0) return throwSyntaxError(realm, "Cannot convert string to BigInt");
    // Non-decimal radix prefixes (0b / 0o / 0x): sign is forbidden,
    // and the body must be at least one digit in that radix.
    if (rest.len >= 2 and rest[0] == '0') {
        const radix: ?u8 = switch (rest[1]) {
            'b', 'B' => @as(u8, 2),
            'o', 'O' => @as(u8, 8),
            'x', 'X' => @as(u8, 16),
            else => null,
        };
        if (radix) |r| {
            if (has_sign) return throwSyntaxError(realm, "Cannot convert signed radix-prefixed string to BigInt");
            const body = rest[2..];
            if (body.len == 0) return throwSyntaxError(realm, "Empty radix-prefixed BigInt literal");
            const value = std.fmt.parseInt(i128, body, r) catch return throwSyntaxError(realm, "Invalid BigInt string");
            const bi = realm.heap.allocateBigInt(value) catch return error.OutOfMemory;
            return heap_mod.taggedBigInt(bi);
        }
    }
    // Decimal — DecimalDigits only (no `.`, no exponent, no `Infinity`).
    for (rest) |c| {
        if (c < '0' or c > '9') return throwSyntaxError(realm, "Invalid BigInt string");
    }
    const value = std.fmt.parseInt(i128, rest, 10) catch return throwSyntaxError(realm, "BigInt string out of range");
    const bi = realm.heap.allocateBigInt(if (negate) -value else value) catch return error.OutOfMemory;
    return heap_mod.taggedBigInt(bi);
}

const throwSyntaxError = intrinsics.throwSyntaxError;

fn bigintToString(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const bi = heap_mod.valueAsBigInt(this_value) orelse blk: {
        if (heap_mod.valueAsPlainObject(this_value)) |obj| {
            if (obj.boxed_primitive) |bp| {
                if (heap_mod.valueAsBigInt(bp)) |inner| break :blk inner;
            }
        }
        return throwTypeError(realm, "BigInt.prototype.toString called on non-BigInt");
    };
    var radix: u8 = 10;
    if (args.len > 0 and !args[0].isUndefined()) {
        // §21.1.3.6 step 3 → ToIntegerOrInfinity → ToNumber.
        // ToNumber throws TypeError for Symbol / BigInt — must
        // surface here rather than silently coercing to NaN.
        const rv = try intrinsics.toNumber(realm, args[0]);
        const rd: f64 = if (rv.isInt32()) @floatFromInt(rv.asInt32()) else rv.asDouble();
        if (std.math.isNan(rd) or std.math.isInf(rd) or rd < 2 or rd > 36)
            return throwRangeError(realm, "toString radix out of range [2, 36]");
        radix = @intFromFloat(@trunc(rd));
    }
    var buf: [256]u8 = undefined;
    var n: usize = 0;
    var negate = false;
    var u: u128 = 0;
    if (bi.value < 0) {
        negate = true;
        u = @intCast(-bi.value);
    } else {
        u = @intCast(bi.value);
    }
    if (u == 0) {
        buf[0] = '0';
        n = 1;
    } else {
        var tmp: [256]u8 = undefined;
        var t: usize = 0;
        while (u > 0) : (u /= radix) {
            const d: u8 = @intCast(u % radix);
            tmp[t] = if (d < 10) '0' + d else 'a' + (d - 10);
            t += 1;
        }
        if (negate) {
            buf[0] = '-';
            n = 1;
        }
        var k: usize = 0;
        while (k < t) : (k += 1) {
            buf[n + k] = tmp[t - 1 - k];
        }
        n += t;
    }
    const s = realm.heap.allocateString(buf[0..n]) catch return error.OutOfMemory;
    return Value.fromString(s);
}

/// §21.2.3.3 BigInt.prototype.toLocaleString. Intl-less builds
/// permit ToString as the implementation-defined fallback (V8
/// builds with `-no-icu` do the same). Delegate to
/// `bigintToString` ignoring reserved args.
fn bigintToLocaleString(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    return bigintToString(realm, this_value, &.{});
}

fn bigintValueOf(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = realm;
    _ = args;
    if (heap_mod.valueAsBigInt(this_value)) |_| return this_value;
    if (heap_mod.valueAsPlainObject(this_value)) |obj| {
        if (obj.boxed_primitive) |bp| {
            if (heap_mod.valueAsBigInt(bp)) |_| return bp;
        }
    }
    return error.NativeThrew;
}

/// §7.1.22 ToIndex — coerce to a non-negative integer in
/// [0, 2^53-1]. Returns the integer as an i64. Throws RangeError
/// on negative input or overflow. `value === undefined` → 0.
fn toIndex(realm: *Realm, value: Value) NativeError!i64 {
    if (value.isUndefined()) return 0;
    // §7.1.5 ToIntegerOrInfinity → ToNumber first (consults
    // Symbol.toPrimitive / valueOf / toString for objects).
    const num_v = try intrinsics.toNumber(realm, value);
    const num: f64 = if (num_v.isInt32()) @floatFromInt(num_v.asInt32()) else num_v.asDouble();
    if (std.math.isNan(num)) return 0;
    // ToIntegerOrInfinity → truncate toward 0.
    const trunc_v = if (num >= 0) @floor(num) else @ceil(num);
    if (trunc_v == 0) return 0;
    if (trunc_v < 0) return throwRangeError(realm, "ToIndex: negative");
    // ToIndex bounds: must be ≤ 2^53 - 1.
    const max_safe: f64 = @as(f64, @floatFromInt((@as(u64, 1) << 53) - 1));
    if (std.math.isInf(trunc_v) or trunc_v > max_safe) {
        return throwRangeError(realm, "ToIndex: out of bounds");
    }
    return @intFromFloat(trunc_v);
}

fn bigintAsIntN(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = this_value;
    // §21.2.2.1 step 1 — `bits = ? ToIndex(bits)` happens *before*
    // ToBigInt(bigint), so coercion order matters for fixtures
    // that observe call sequence on their valueOf hooks.
    const bits_i = try toIndex(realm, argOr(args, 0, Value.fromInt32(0)));
    const bi_v = try toBigIntValue(realm, argOr(args, 1, Value.undefined_));
    const bi = heap_mod.valueAsBigInt(bi_v) orelse return throwTypeError(realm, "BigInt.asIntN: ToBigInt failed");
    if (bits_i == 0) {
        const out = realm.heap.allocateBigInt(0) catch return error.OutOfMemory;
        return heap_mod.taggedBigInt(out);
    }
    // Cynic stores BigInt as i128; mod 2^bits is only representable
    // for bits ≤ 127. Saturating gracefully would require arbitrary
    // precision; for now reject beyond 127 as RangeError (the
    // alternative would be a silent truncation that masks bugs).
    if (bits_i > 127) return throwRangeError(realm, "BigInt.asIntN bits exceed i128 storage");
    const bits: u7 = @intCast(bits_i);
    const mod_amount: i128 = @as(i128, 1) << bits;
    var v = @rem(bi.value, mod_amount);
    if (bits >= 1) {
        const half: i128 = @as(i128, 1) << @intCast(bits - 1);
        if (v >= half) v -= mod_amount else if (v < -half) v += mod_amount;
    }
    const out = realm.heap.allocateBigInt(v) catch return error.OutOfMemory;
    return heap_mod.taggedBigInt(out);
}

fn bigintAsUintN(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = this_value;
    const bits_i = try toIndex(realm, argOr(args, 0, Value.fromInt32(0)));
    const bi_v = try toBigIntValue(realm, argOr(args, 1, Value.undefined_));
    const bi = heap_mod.valueAsBigInt(bi_v) orelse return throwTypeError(realm, "BigInt.asUintN: ToBigInt failed");
    if (bits_i == 0) {
        const out = realm.heap.allocateBigInt(0) catch return error.OutOfMemory;
        return heap_mod.taggedBigInt(out);
    }
    if (bits_i > 127) return throwRangeError(realm, "BigInt.asUintN bits exceed i128 storage");
    const bits: u7 = @intCast(bits_i);
    const mod_amount: i128 = @as(i128, 1) << bits;
    var v = @rem(bi.value, mod_amount);
    if (v < 0) v += mod_amount;
    const out = realm.heap.allocateBigInt(v) catch return error.OutOfMemory;
    return heap_mod.taggedBigInt(out);
}

