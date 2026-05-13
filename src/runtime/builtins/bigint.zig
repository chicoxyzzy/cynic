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
const coerceToNumber = intrinsics.coerceToNumber;
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
    try installNativeMethodOnProto(realm, proto, "valueOf", bigintValueOf, 0);

    try installNativeMethod(realm, fn_obj, "asIntN", bigintAsIntN, 2);
    try installNativeMethod(realm, fn_obj, "asUintN", bigintAsUintN, 2);
}

fn bigintConstructor(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = this_value;
    const arg = argOr(args, 0, Value.undefined_);
    return toBigIntValue(realm, arg) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.NativeThrew,
    };
}

/// §7.1.13 ToBigInt. Returns the JSBigInt-tagged Value.
fn toBigIntValue(realm: *Realm, v_in: Value) !Value {
    // §7.1.13 step 1 — ToPrimitive(arg, hint "number") for objects.
    // Without this, BigInt({ valueOf: () => NaN }) takes the
    // throwTypeError fall-through instead of the spec-mandated
    // NumberToBigInt RangeError.
    const v = if (heap_mod.valueAsPlainObject(v_in) != null)
        try intrinsics.toPrimitive(realm, v_in, .number)
    else
        v_in;
    if (heap_mod.valueAsBigInt(v)) |_| return v;
    if (v.isBool()) {
        const bi = try realm.heap.allocateBigInt(if (v.asBool()) 1 else 0);
        return heap_mod.taggedBigInt(bi);
    }
    if (v.isInt32()) {
        const bi = try realm.heap.allocateBigInt(@intCast(v.asInt32()));
        return heap_mod.taggedBigInt(bi);
    }
    if (v.isDouble()) {
        const d = v.asDouble();
        // §21.2.1.1.1 NumberToBigInt — RangeError for NaN /
        // ±Infinity / non-integer.
        if (std.math.isNan(d) or std.math.isInf(d) or d != @trunc(d)) {
            return throwRangeError(realm, "Cannot convert non-integer Number to BigInt");
        }
        if (d > @as(f64, @floatFromInt(std.math.maxInt(i128))) or d < @as(f64, @floatFromInt(std.math.minInt(i128)))) {
            return throwRangeError(realm, "Number out of BigInt i128 range");
        }
        const bi = try realm.heap.allocateBigInt(@intFromFloat(d));
        return heap_mod.taggedBigInt(bi);
    }
    if (v.isString()) {
        const s: *JSString = @ptrCast(@alignCast(v.asString()));
        const trimmed = std.mem.trim(u8, s.bytes, " \t\n\r");
        if (trimmed.len == 0) {
            const bi = try realm.heap.allocateBigInt(0);
            return heap_mod.taggedBigInt(bi);
        }
        var negate = false;
        var rest = trimmed;
        if (rest[0] == '-') {
            negate = true;
            rest = rest[1..];
        } else if (rest[0] == '+') {
            rest = rest[1..];
        }
        if (rest.len == 0) return throwTypeError(realm, "Cannot convert string to BigInt");
        const value = std.fmt.parseInt(i128, rest, 0) catch return throwTypeError(realm, "Cannot convert string to BigInt");
        const bi = try realm.heap.allocateBigInt(if (negate) -value else value);
        return heap_mod.taggedBigInt(bi);
    }
    return throwTypeError(realm, "Cannot convert value to BigInt");
}

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

fn bigintAsIntN(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = this_value;
    const bits_v = coerceToNumber(argOr(args, 0, Value.fromInt32(0)));
    const bits: i32 = if (bits_v.isInt32()) bits_v.asInt32() else @intFromFloat(bits_v.asDouble());
    if (bits < 0 or bits > 127) return throwRangeError(realm, "BigInt.asIntN bits must be 0..127");
    const bi = heap_mod.valueAsBigInt(argOr(args, 1, Value.undefined_)) orelse return throwTypeError(realm, "BigInt.asIntN value must be a BigInt");
    if (bits == 0) {
        const out = realm.heap.allocateBigInt(0) catch return error.OutOfMemory;
        return heap_mod.taggedBigInt(out);
    }
    const mod_amount: i128 = @as(i128, 1) << @intCast(bits);
    var v = @rem(bi.value, mod_amount);
    const half: i128 = @as(i128, 1) << @intCast(bits - 1);
    if (v >= half) v -= mod_amount else if (v < -half) v += mod_amount;
    const out = realm.heap.allocateBigInt(v) catch return error.OutOfMemory;
    return heap_mod.taggedBigInt(out);
}

fn bigintAsUintN(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = this_value;
    const bits_v = coerceToNumber(argOr(args, 0, Value.fromInt32(0)));
    const bits: i32 = if (bits_v.isInt32()) bits_v.asInt32() else @intFromFloat(bits_v.asDouble());
    if (bits < 0 or bits > 127) return throwRangeError(realm, "BigInt.asUintN bits must be 0..127");
    const bi = heap_mod.valueAsBigInt(argOr(args, 1, Value.undefined_)) orelse return throwTypeError(realm, "BigInt.asUintN value must be a BigInt");
    if (bits == 0) {
        const out = realm.heap.allocateBigInt(0) catch return error.OutOfMemory;
        return heap_mod.taggedBigInt(out);
    }
    const mod_amount: i128 = @as(i128, 1) << @intCast(bits);
    var v = @rem(bi.value, mod_amount);
    if (v < 0) v += mod_amount;
    const out = realm.heap.allocateBigInt(v) catch return error.OutOfMemory;
    return heap_mod.taggedBigInt(out);
}

