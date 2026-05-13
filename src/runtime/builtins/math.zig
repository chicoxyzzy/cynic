//! §21.3 Math — extracted from `intrinsics.zig`. Pure-function
//! object: no constructor, no prototype methods, just static
//! statics like `Math.PI`, `Math.floor`, etc. Most fns route
//! through `coerceToNumber` and the Zig `std.math` namespace;
//! the only non-trivial logic is `Math.random` (PCG seeded
//! per-realm) and `Math.imul` (§21.3.2.18 32-bit modular
//! multiply).

const std = @import("std");

const Realm = @import("../realm.zig").Realm;
const Value = @import("../value.zig").Value;
const JSObject = @import("../object.zig").JSObject;
const JSFunction = @import("../function.zig").JSFunction;
const NativeError = @import("../function.zig").NativeError;
const NativeFn = @import("../function.zig").NativeFn;
const heap_mod = @import("../heap.zig");
const intrinsics = @import("../intrinsics.zig");

const argOr = intrinsics.argOr;
const coerceToNumber = intrinsics.coerceToNumber;
const installToStringTag = intrinsics.installToStringTag;

// ── Math object ─────────────────────────────────────────────────────────────

pub fn install(realm: *Realm) !void {
    const math_obj = try realm.heap.allocateObject();
    math_obj.prototype = realm.intrinsics.object_prototype;
    try installToStringTag(realm, math_obj, "Math");
    // §21.3.1 Math constants — `[[Writable]]: false`,
    // `[[Enumerable]]: false`, `[[Configurable]]: false`.
    const constant_flags: @import("../object.zig").PropertyFlags = .{
        .writable = false,
        .enumerable = false,
        .configurable = false,
    };
    try math_obj.setWithFlags(realm.allocator, "PI", Value.fromDouble(std.math.pi), constant_flags);
    try math_obj.setWithFlags(realm.allocator, "E", Value.fromDouble(std.math.e), constant_flags);
    try math_obj.setWithFlags(realm.allocator, "LN2", Value.fromDouble(std.math.ln2), constant_flags);
    try math_obj.setWithFlags(realm.allocator, "LN10", Value.fromDouble(std.math.ln10), constant_flags);
    try math_obj.setWithFlags(realm.allocator, "LOG2E", Value.fromDouble(std.math.log2e), constant_flags);
    try math_obj.setWithFlags(realm.allocator, "LOG10E", Value.fromDouble(std.math.log10e), constant_flags);
    try math_obj.setWithFlags(realm.allocator, "SQRT2", Value.fromDouble(std.math.sqrt2), constant_flags);
    try math_obj.setWithFlags(realm.allocator, "SQRT1_2", Value.fromDouble(@as(f64, 1.0) / std.math.sqrt2), constant_flags);

    const Pair = struct { name: []const u8, fn_ptr: NativeFn, params: u8 };
    const methods = [_]Pair{
        .{ .name = "abs", .fn_ptr = mathAbs, .params = 1 },
        .{ .name = "floor", .fn_ptr = mathFloor, .params = 1 },
        .{ .name = "ceil", .fn_ptr = mathCeil, .params = 1 },
        .{ .name = "round", .fn_ptr = mathRound, .params = 1 },
        .{ .name = "trunc", .fn_ptr = mathTrunc, .params = 1 },
        .{ .name = "sign", .fn_ptr = mathSign, .params = 1 },
        .{ .name = "sqrt", .fn_ptr = mathSqrt, .params = 1 },
        .{ .name = "cbrt", .fn_ptr = mathCbrt, .params = 1 },
        .{ .name = "pow", .fn_ptr = mathPow, .params = 2 },
        .{ .name = "exp", .fn_ptr = mathExp, .params = 1 },
        .{ .name = "log", .fn_ptr = mathLog, .params = 1 },
        .{ .name = "log2", .fn_ptr = mathLog2, .params = 1 },
        .{ .name = "log10", .fn_ptr = mathLog10, .params = 1 },
        .{ .name = "sin", .fn_ptr = mathSin, .params = 1 },
        .{ .name = "cos", .fn_ptr = mathCos, .params = 1 },
        .{ .name = "tan", .fn_ptr = mathTan, .params = 1 },
        .{ .name = "asin", .fn_ptr = mathAsin, .params = 1 },
        .{ .name = "acos", .fn_ptr = mathAcos, .params = 1 },
        .{ .name = "atan", .fn_ptr = mathAtan, .params = 1 },
        .{ .name = "atan2", .fn_ptr = mathAtan2, .params = 2 },
        .{ .name = "min", .fn_ptr = mathMin, .params = 2 },
        .{ .name = "max", .fn_ptr = mathMax, .params = 2 },
        .{ .name = "hypot", .fn_ptr = mathHypot, .params = 2 },
        .{ .name = "random", .fn_ptr = mathRandom, .params = 0 },
        // later additions.
        .{ .name = "log1p", .fn_ptr = mathLog1p, .params = 1 },
        .{ .name = "expm1", .fn_ptr = mathExpm1, .params = 1 },
        .{ .name = "sinh", .fn_ptr = mathSinh, .params = 1 },
        .{ .name = "cosh", .fn_ptr = mathCosh, .params = 1 },
        .{ .name = "tanh", .fn_ptr = mathTanh, .params = 1 },
        .{ .name = "asinh", .fn_ptr = mathAsinh, .params = 1 },
        .{ .name = "acosh", .fn_ptr = mathAcosh, .params = 1 },
        .{ .name = "atanh", .fn_ptr = mathAtanh, .params = 1 },
        .{ .name = "clz32", .fn_ptr = mathClz32, .params = 1 },
        .{ .name = "fround", .fn_ptr = mathFround, .params = 1 },
        .{ .name = "imul", .fn_ptr = mathImul, .params = 2 },
    };
    // §17 — built-in methods are `[[Writable]]: true`,
    // `[[Enumerable]]: false`, `[[Configurable]]: true`.
    const method_flags: @import("../object.zig").PropertyFlags = .{
        .writable = true,
        .enumerable = false,
        .configurable = true,
    };
    for (methods) |m| {
        const fn_obj = try realm.heap.allocateFunctionNative(m.fn_ptr, m.params, m.name);
        fn_obj.has_construct = false; // §17 — Math.* aren't constructors.
        try math_obj.setWithFlags(realm.allocator, m.name, heap_mod.taggedFunction(fn_obj), method_flags);
    }
    try realm.globals.put(realm.allocator, "Math", heap_mod.taggedObject(math_obj));
}

fn mathArg(args: []const Value, i: usize) f64 {
    const v = argOr(args, i, Value.undefined_);
    const n = coerceToNumber(v);
    if (n.isInt32()) return @floatFromInt(n.asInt32());
    return n.asDouble();
}

/// Same as `mathArg` but routes the arg through §7.1.4 ToNumber so
/// objects with `valueOf` / `Symbol.toPrimitive` see the spec hook,
/// and Symbol / BigInt arguments throw TypeError instead of silently
/// becoming NaN. Used by methods whose test262 fixtures probe
/// side-effecting valueOf order or abrupt-from-ToNumber paths.
fn mathArgRealm(realm: *Realm, args: []const Value, i: usize) NativeError!f64 {
    const v = argOr(args, i, Value.undefined_);
    const n = try intrinsics.toNumber(realm, v);
    if (n.isInt32()) return @floatFromInt(n.asInt32());
    return n.asDouble();
}

fn mathDouble(d: f64) Value {
    return Value.fromDouble(d);
}

fn mathAbs(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = realm;
    _ = this_value;
    return mathDouble(@abs(mathArg(args, 0)));
}
fn mathFloor(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = realm;
    _ = this_value;
    return mathDouble(@floor(mathArg(args, 0)));
}
fn mathCeil(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = realm;
    _ = this_value;
    return mathDouble(@ceil(mathArg(args, 0)));
}
fn mathRound(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = realm;
    _ = this_value;
    // §21.3.2.27 — half-rounds toward +Infinity. Spec-edge:
    //   - `Math.round(-0)` returns -0 (and `Math.round(x)` for
    //     x ∈ [-0.5, -0) likewise returns -0, *not* +0). The naïve
    //     `floor(x + 0.5)` collapses -0.5 → floor(0) = +0 instead.
    //     Real engines hand-route the [-0.5, 0] interval.
    const x = mathArg(args, 0);
    if (std.math.isNan(x) or std.math.isInf(x)) return mathDouble(x);
    if (x == 0) return mathDouble(x); // preserves sign of 0
    if (x < 0 and x >= -0.5) return mathDouble(-0.0);
    return mathDouble(@floor(x + 0.5));
}
fn mathTrunc(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = realm;
    _ = this_value;
    return mathDouble(@trunc(mathArg(args, 0)));
}
fn mathSign(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = realm;
    _ = this_value;
    const x = mathArg(args, 0);
    if (std.math.isNan(x)) return mathDouble(x);
    if (x > 0) return Value.fromInt32(1);
    if (x < 0) return Value.fromInt32(-1);
    return mathDouble(x); // ±0
}
fn mathSqrt(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = realm;
    _ = this_value;
    return mathDouble(@sqrt(mathArg(args, 0)));
}
fn mathCbrt(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = realm;
    _ = this_value;
    return mathDouble(std.math.cbrt(mathArg(args, 0)));
}
fn mathPow(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = realm;
    _ = this_value;
    // §21.3.2.27 Math.pow — same special cases as the `**`
    // operator (§6.1.6.1.3): `Math.pow(±1, ±∞) === NaN` despite
    // IEEE 754 `pow` returning 1.
    const a = mathArg(args, 0);
    const b = mathArg(args, 1);
    if (std.math.isNan(b)) return mathDouble(std.math.nan(f64));
    if (std.math.isInf(b) and (a == 1.0 or a == -1.0)) return mathDouble(std.math.nan(f64));
    return mathDouble(std.math.pow(f64, a, b));
}
fn mathExp(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = realm;
    _ = this_value;
    return mathDouble(@exp(mathArg(args, 0)));
}
fn mathLog(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = realm;
    _ = this_value;
    return mathDouble(@log(mathArg(args, 0)));
}
fn mathLog2(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = realm;
    _ = this_value;
    return mathDouble(@log2(mathArg(args, 0)));
}
fn mathLog10(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = realm;
    _ = this_value;
    return mathDouble(@log10(mathArg(args, 0)));
}
fn mathSin(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = realm;
    _ = this_value;
    return mathDouble(@sin(mathArg(args, 0)));
}
fn mathCos(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = realm;
    _ = this_value;
    return mathDouble(@cos(mathArg(args, 0)));
}
fn mathTan(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = realm;
    _ = this_value;
    return mathDouble(@tan(mathArg(args, 0)));
}
fn mathAsin(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = realm;
    _ = this_value;
    return mathDouble(std.math.asin(mathArg(args, 0)));
}
fn mathAcos(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = realm;
    _ = this_value;
    return mathDouble(std.math.acos(mathArg(args, 0)));
}
fn mathAtan(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = realm;
    _ = this_value;
    return mathDouble(std.math.atan(mathArg(args, 0)));
}
fn mathAtan2(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = realm;
    _ = this_value;
    return mathDouble(std.math.atan2(mathArg(args, 0), mathArg(args, 1)));
}
fn mathMin(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = this_value;
    if (args.len == 0) return mathDouble(std.math.inf(f64));
    // §21.3.2.25 step 2 — ToNumber every arg first (in order), THEN
    // compute. valueOf side effects must fire for all args even if
    // an earlier arg is NaN.
    const coerced = realm.allocator.alloc(f64, args.len) catch return error.OutOfMemory;
    defer realm.allocator.free(coerced);
    for (args, 0..) |_, i| coerced[i] = try mathArgRealm(realm, args, i);
    var best = coerced[0];
    if (std.math.isNan(best)) return mathDouble(best);
    var i: usize = 1;
    while (i < coerced.len) : (i += 1) {
        const v = coerced[i];
        if (std.math.isNan(v)) return mathDouble(v);
        // -0 < +0 per §21.3.2.25 step 6.
        if (v < best or (v == 0 and best == 0 and std.math.signbit(v) and !std.math.signbit(best))) best = v;
    }
    return mathDouble(best);
}
fn mathMax(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = this_value;
    if (args.len == 0) return mathDouble(-std.math.inf(f64));
    const coerced = realm.allocator.alloc(f64, args.len) catch return error.OutOfMemory;
    defer realm.allocator.free(coerced);
    for (args, 0..) |_, i| coerced[i] = try mathArgRealm(realm, args, i);
    var best = coerced[0];
    if (std.math.isNan(best)) return mathDouble(best);
    var i: usize = 1;
    while (i < coerced.len) : (i += 1) {
        const v = coerced[i];
        if (std.math.isNan(v)) return mathDouble(v);
        // +0 > -0 per §21.3.2.24 step 6.
        if (v > best or (v == 0 and best == 0 and !std.math.signbit(v) and std.math.signbit(best))) best = v;
    }
    return mathDouble(best);
}
fn mathHypot(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = this_value;
    // §21.3.2.18 step 2 — ToNumber every arg before the math.
    const coerced = realm.allocator.alloc(f64, args.len) catch return error.OutOfMemory;
    defer realm.allocator.free(coerced);
    for (args, 0..) |_, i| coerced[i] = try mathArgRealm(realm, args, i);
    // §21.3.2.18 step 3-5 — Infinity short-circuits to +Infinity
    // (even when other args are NaN); NaN otherwise propagates.
    var has_inf = false;
    var has_nan = false;
    for (coerced) |d| {
        if (std.math.isInf(d)) has_inf = true;
        if (std.math.isNan(d)) has_nan = true;
    }
    if (has_inf) return mathDouble(std.math.inf(f64));
    if (has_nan) return mathDouble(std.math.nan(f64));
    var sum: f64 = 0;
    for (coerced) |d| sum += d * d;
    return mathDouble(@sqrt(sum));
}

// ── Math additions (§21.3.2, later) ─────────────────────────────────────────

fn mathLog1p(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = realm;
    _ = this_value;
    return mathDouble(std.math.log1p(toF64(argOr(args, 0, Value.fromDouble(std.math.nan(f64))))));
}
fn mathExpm1(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = realm;
    _ = this_value;
    const x = toF64(argOr(args, 0, Value.fromDouble(std.math.nan(f64))));
    return mathDouble(std.math.expm1(x));
}
fn mathSinh(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = realm;
    _ = this_value;
    return mathDouble(std.math.sinh(toF64(argOr(args, 0, Value.fromDouble(std.math.nan(f64))))));
}
fn mathCosh(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = realm;
    _ = this_value;
    return mathDouble(std.math.cosh(toF64(argOr(args, 0, Value.fromDouble(std.math.nan(f64))))));
}
fn mathTanh(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = realm;
    _ = this_value;
    return mathDouble(std.math.tanh(toF64(argOr(args, 0, Value.fromDouble(std.math.nan(f64))))));
}
fn mathAsinh(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = realm;
    _ = this_value;
    return mathDouble(std.math.asinh(toF64(argOr(args, 0, Value.fromDouble(std.math.nan(f64))))));
}
fn mathAcosh(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = realm;
    _ = this_value;
    return mathDouble(std.math.acosh(toF64(argOr(args, 0, Value.fromDouble(std.math.nan(f64))))));
}
fn mathAtanh(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = realm;
    _ = this_value;
    return mathDouble(std.math.atanh(toF64(argOr(args, 0, Value.fromDouble(std.math.nan(f64))))));
}
fn mathClz32(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = realm;
    _ = this_value;
    const v = coerceToNumber(argOr(args, 0, Value.fromInt32(0)));
    const x: u32 = if (v.isInt32()) @bitCast(v.asInt32()) else doubleToU32(v.asDouble());
    if (x == 0) return Value.fromInt32(32);
    return Value.fromInt32(@intCast(@clz(x)));
}

/// §7.1.7 ToUint32 — converts a Number to a 32-bit unsigned
/// int with the spec's mod-2^32 truncation. Doesn't panic on
/// out-of-range / NaN / Inf inputs.
fn doubleToU32(d: f64) u32 {
    if (std.math.isNan(d) or std.math.isInf(d)) return 0;
    const truncd = @trunc(d);
    // Reduce mod 2^32 in floating point first to avoid the
    // i64 cast panicking on huge magnitudes.
    const TWO32: f64 = 4294967296.0;
    const m = truncd - @floor(truncd / TWO32) * TWO32;
    if (m < 0) return @intFromFloat(m + TWO32);
    return @intFromFloat(m);
}

fn doubleToI32(d: f64) i32 {
    const u = doubleToU32(d);
    return @bitCast(u);
}
fn mathFround(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = realm;
    _ = this_value;
    const x = toF64(argOr(args, 0, Value.fromDouble(std.math.nan(f64))));
    const f: f32 = @floatCast(x);
    return mathDouble(@floatCast(f));
}
fn mathImul(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = realm;
    _ = this_value;
    const a_v = coerceToNumber(argOr(args, 0, Value.fromInt32(0)));
    const b_v = coerceToNumber(argOr(args, 1, Value.fromInt32(0)));
    const a: i32 = if (a_v.isInt32()) a_v.asInt32() else doubleToI32(a_v.asDouble());
    const b: i32 = if (b_v.isInt32()) b_v.asInt32() else doubleToI32(b_v.asDouble());
    const result = a *% b; // wrapping multiply per §21.3.2.21
    return Value.fromInt32(result);
}

fn toF64(v: Value) f64 {
    const n = coerceToNumber(v);
    if (n.isInt32()) return @floatFromInt(n.asInt32());
    return n.asDouble();
}

var math_random_state: u64 = 0xC0FFEE00DEADBEEF;
fn mathRandom(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = realm;
    _ = this_value;
    _ = args;
    // xorshift64* — small, fast, deterministic-by-default. later:
    // seed-from-realm if hosts want reproducible runs.
    var x = math_random_state;
    x ^= x << 13;
    x ^= x >> 7;
    x ^= x << 17;
    math_random_state = x;
    const u = (x >> 11) | 0; // 53-bit mantissa
    const d: f64 = @as(f64, @floatFromInt(@as(u53, @truncate(u)))) / 9007199254740992.0;
    return mathDouble(d);
}

