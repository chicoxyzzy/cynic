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
const lantern = @import("../lantern/interpreter.zig");

const argOr = intrinsics.argOr;
const coerceToNumber = intrinsics.coerceToNumber;
const installToStringTag = intrinsics.installToStringTag;
const throwTypeError = intrinsics.throwTypeError;
const getPropertyChain = intrinsics.getPropertyChain;

// ── Math object ─────────────────────────────────────────────────────────────

pub fn install(realm: *Realm) !void {
    const math_obj = try realm.heap.allocateObject();
    realm.heap.setObjectPrototype(math_obj, realm.intrinsics.object_prototype);
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
        // §21.3.2 Math.f16round — round to IEEE 754 binary16 then
        // back to f64. Ships paired with `Float16Array` /
        // `DataView.{get,set}Float16` (ES2024 Stage 4). Same shape
        // as `fround`, just `f16` instead of `f32`.
        .{ .name = "f16round", .fn_ptr = mathF16round, .params = 1 },
        .{ .name = "imul", .fn_ptr = mathImul, .params = 2 },
        // §21.3.2.21 Math.sumPrecise — reproducible Shewchuk
        // summation over an iterable of Numbers.
        .{ .name = "sumPrecise", .fn_ptr = mathSumPrecise, .params = 1 },
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
    // §21.3.2.27 — values in (0, 0.5) round to +0. The naïve
    // `floor(x + 0.5)` rounds, e.g., `0.5 - Number.EPSILON/4`
    // (which is < 0.5 but very close) up to 1 because
    // `0.5 - 2^-54 + 0.5` is IEEE-rounded to exactly 1.0
    // (Sputnik `S15.8.2.15_A7` CHECK#4).
    if (x > 0 and x < 0.5) return Value.fromInt32(0);
    // §21.3.2.27 — "If x is an integer, the result is x." For
    // large-magnitude integers near 2^53, the naïve `floor(x + 0.5)`
    // loses the last bit of precision in the addition and rounds odd
    // integers to the next even value (Sputnik `S15.8.2.15_A7` checks
    // values like `2 / Number.EPSILON - 1` = 2^53 - 1, which would
    // collapse to 2^53). Short-circuit when `x` is already an
    // integral float.
    if (@floor(x) == x) return mathDouble(x);
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
fn mathF16round(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = realm;
    _ = this_value;
    const x = toF64(argOr(args, 0, Value.fromDouble(std.math.nan(f64))));
    // §21.3.2 Math.f16round: ToNumber → round to nearest binary16
    // → return as Number (f64). IEEE 754 round-half-to-even falls
    // out of Zig's `@floatCast f64 → f16` lowering, same as the
    // f32 path above. Same shape as `Float16Array` indexed writes
    // (see `typed_array.zig` value-conversion path), so binary16
    // semantics stay in lockstep between the array-store path and
    // this rounding helper.
    const f: f16 = @floatCast(x);
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

// ── §21.3.2.21 Math.sumPrecise ──────────────────────────────────────────────

/// §21.3.2.21 Math.sumPrecise(items). Reproducible summation:
/// every conforming implementation returns the same Number for
/// the same finite-Number input sequence (modulo iteration order
/// over user-supplied iterables). Backed by Shewchuk's
/// exact-floating-sum (the algorithm Python's `math.fsum`
/// references): maintain a list of non-overlapping doubles whose
/// exact sum equals the running total; absorb each new term via
/// FastTwoSum sweeps; final round-to-nearest folds the partials.
///
/// State machine for non-finite inputs (§21.3.2.21 step 4):
///   minus-zero (initial) → finite (any finite) →
///     plus-infinity (after +∞ seen) /
///     minus-infinity (after -∞ seen) /
///     not-a-number (mixed infinities, or any NaN).
/// Once `not-a-number` is reached, remaining numeric inputs are
/// still consumed (so valueOf side effects on later items don't
/// happen — but elements must still be Number-typed; the
/// "throws-on-non-number with NaN-poisoned state" fixture
/// asserts this).
fn mathSumPrecise(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = this_value;

    // §21.3.2.21 step 1 — RequireObjectCoercible(items). undefined
    // / null produce the "Cannot convert ... to object" TypeError;
    // primitives that are not coercible (none, in current spec) too.
    // The fixture `Math.sumPrecise()` exercises the undefined path.
    const items = if (args.len == 0) Value.undefined_ else args[0];
    if (items.isUndefined() or items.isNull()) {
        return throwTypeError(realm, "Math.sumPrecise: items is not iterable");
    }

    // §21.3.2.21 step 2 — `iteratorRecord = ? GetIterator(items, sync)`.
    // Pin the iterable across the iteration loop because user code
    // (`next`, `return`) re-enters JS and may trigger a GC sweep.
    const scope = realm.heap.openScope() catch return error.OutOfMemory;
    defer scope.close();
    scope.push(items) catch return error.OutOfMemory;

    const iter = lantern.openIterator(realm.allocator, realm, items) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.NotIterable => return throwTypeError(realm, "Math.sumPrecise: items is not iterable"),
        error.Propagated => return error.NativeThrew,
        error.InvalidOpcode => return error.NativeThrew,
    };
    scope.push(iter) catch return error.OutOfMemory;
    const iter_obj = heap_mod.valueAsPlainObject(iter) orelse {
        return throwTypeError(realm, "Math.sumPrecise: iterator method did not return an object");
    };
    const next_v = try getPropertyChain(realm, iter_obj, "next");
    const next_fn = heap_mod.valueAsFunction(next_v) orelse {
        return throwTypeError(realm, "Math.sumPrecise: iterator missing callable 'next'");
    };

    // §21.3.2.21 step 3 — `state` starts at "minus-zero".
    var state: SumState = .minus_zero;
    // Shewchuk's exact-floating-point summation (Robust Arithmetic,
    // CMU 1996), adapted to handle overflow per the TC39 reference
    // polyfill: an `overflow` counter tracks excess 2^1024 multiples
    // that the cascade couldn't accommodate. Final rounding folds
    // the partials + the biased overflow into a single Number,
    // breaking ties to even.
    var partials: std.ArrayListUnmanaged(f64) = .empty;
    defer partials.deinit(realm.allocator);
    // `overflow` records signed multiples of 2^1024 — when a
    // FastTwoSum step would have landed at ±Inf, we bias `x` by
    // ∓2^1024 and bump this counter accordingly. The final step
    // unbiases. |overflow| > 2^53 is unrecoverable → ±Inf.
    var overflow: f64 = 0;

    const max_iter: usize = 1 << 24;
    var step: usize = 0;
    while (step < max_iter) : (step += 1) {
        const result_outcome = lantern.callJSFunction(realm.allocator, realm, next_fn, iter, &.{}) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.NativeThrew,
        };
        const result = switch (result_outcome) {
            .value, .yielded => |v| v,
            .thrown => |ex| {
                realm.pending_exception = ex;
                return error.NativeThrew;
            },
        };
        const result_obj = heap_mod.valueAsPlainObject(result) orelse {
            return throwTypeError(realm, "Math.sumPrecise: iterator next() did not return an object");
        };
        const done_v = try getPropertyChain(realm, result_obj, "done");
        if (intrinsics.toBoolean(done_v)) break;
        const value = try getPropertyChain(realm, result_obj, "value");

        // §21.3.2.21 step 4.b — type check WITHOUT coercion. If
        // not a Number, IteratorClose the source and throw
        // TypeError. The fixture asserts `valueOf` is NOT called —
        // so check the type tag directly, no `coerceToNumber`.
        if (!(value.isInt32() or value.isDouble())) {
            // §7.4.11 IteratorClose — call iter.return(); ignore
            // any throw from return() (original abrupt wins).
            closeIteratorSwallow(realm, iter);
            return throwTypeError(realm, "Math.sumPrecise: every element must be a Number");
        }
        const x: f64 = if (value.isInt32()) @floatFromInt(value.asInt32()) else value.asDouble();

        // Update infinite / NaN state per §21.3.2.21 step 4.c.
        if (std.math.isNan(x)) {
            state = .not_a_number;
        } else if (std.math.isInf(x)) {
            if (x > 0) {
                switch (state) {
                    .minus_infinity, .not_a_number => state = .not_a_number,
                    else => state = .plus_infinity,
                }
            } else {
                switch (state) {
                    .plus_infinity, .not_a_number => state = .not_a_number,
                    else => state = .minus_infinity,
                }
            }
        } else {
            // Finite — feed the Shewchuk accumulator. The state
            // bumps from `minus-zero` to `finite` on the first
            // non-zero or +0 input; -0 alone stays minus-zero.
            if (state == .minus_zero) {
                // Pre-step: any finite +/- non-zero or +0 promotes
                // to `finite`. A bare -0 leaves state alone.
                if (!(x == 0 and std.math.signbit(x))) state = .finite;
            }
            const ov_delta = try shewchukAdd(realm.allocator, &partials, x);
            overflow += ov_delta;
            // |overflow| ≥ 2^53 means cumulative excess beyond what
            // the Number range can recover from — clamp to ±Inf via
            // the state machine immediately.
            if (@abs(overflow) >= 0x1.0p53) {
                state = if (overflow > 0) .plus_infinity else .minus_infinity;
            }
        }
    }

    // §21.3.2.21 step 5 — terminal state dispatch.
    return switch (state) {
        .not_a_number => mathDouble(std.math.nan(f64)),
        .plus_infinity => mathDouble(std.math.inf(f64)),
        .minus_infinity => mathDouble(-std.math.inf(f64)),
        // `minus-zero` means we never saw a +0 or any non-zero
        // finite; the partials list is empty.
        .minus_zero => mathDouble(-0.0),
        .finite => mathDouble(shewchukRound(partials.items, overflow)),
    };
}

const SumState = enum { minus_zero, finite, plus_infinity, minus_infinity, not_a_number };

/// Close the source iterator on an abrupt completion. Mirrors
/// `iterator.closeIteratorSwallow`: any throw from `return()`
/// itself is dropped (per §7.4.11 IteratorClose — the original
/// abrupt wins). Used by Math.sumPrecise's type-check path.
fn closeIteratorSwallow(realm: *Realm, iter: Value) void {
    const iter_obj = heap_mod.valueAsPlainObject(iter) orelse return;
    const ret_v = iter_obj.get("return");
    if (ret_v.isUndefined() or ret_v.isNull()) return;
    const ret_fn = heap_mod.valueAsFunction(ret_v) orelse return;
    const saved = realm.pending_exception;
    const result = lantern.callJSFunction(realm.allocator, realm, ret_fn, iter, &.{}) catch {
        realm.pending_exception = saved;
        return;
    };
    _ = result;
    realm.pending_exception = saved;
}

/// Shewchuk-Hickey exact-sum step. Walk `partials` swapping each
/// entry with `x` via FastTwoSum; the residual (`lo`) becomes the
/// new `x`. Zeros falling out compact the list. The final residual
/// `x` is appended. After N additions, the partials list holds at
/// most O(log(max/min)) entries; for IEEE-754 doubles this is
/// bounded by ~2046.
/// Mirrors `twosum(x, y)` from the TC39 polyfill. Precondition:
/// |x| ≥ |y|. Returns `(hi, lo)` where `hi + lo == x + y` exactly
/// (in real arithmetic) and `hi = roundToNearest(x + y)`.
fn twosum(x: f64, y: f64) struct { hi: f64, lo: f64 } {
    const hi = x + y;
    const lo = y - (hi - x);
    return .{ .hi = hi, .lo = lo };
}

/// Cascade `x_in` through the partials list. Returns the change to
/// the overflow counter (±1 per overflow recovery, 0 otherwise).
/// On overflow, biases x by ∓2^1024 (exactly representable as two
/// 2^1023 subtractions) and continues — preserving the exact sum
/// modulo the recorded overflow multiples.
fn shewchukAdd(allocator: std.mem.Allocator, partials: *std.ArrayListUnmanaged(f64), x_in: f64) std.mem.Allocator.Error!f64 {
    var x = x_in;
    var overflow_delta: f64 = 0;
    var write: usize = 0;
    var i: usize = 0;
    while (i < partials.items.len) : (i += 1) {
        var y = partials.items[i];
        if (@abs(x) < @abs(y)) {
            const tmp = x;
            x = y;
            y = tmp;
        }
        var ts = twosum(x, y);
        if (std.math.isInf(ts.hi)) {
            // Overflow recovery (TC39 polyfill §main-loop): bias
            // `x` by ∓2^1024 so the cascade can continue. The
            // 2^1024 value isn't representable in f64, so subtract
            // 2^1023 twice; both subtractions are exact (the
            // affected bits are below the operand magnitudes).
            const sign: f64 = if (ts.hi == std.math.inf(f64)) 1.0 else -1.0;
            overflow_delta += sign;
            const big: f64 = 0x1.0p1023;
            x = (x - sign * big) - sign * big;
            if (@abs(x) < @abs(y)) {
                const tmp = x;
                x = y;
                y = tmp;
            }
            ts = twosum(x, y);
        }
        if (ts.lo != 0) {
            partials.items[write] = ts.lo;
            write += 1;
        }
        x = ts.hi;
    }
    partials.shrinkRetainingCapacity(write);
    if (x != 0) {
        try partials.append(allocator, x);
    }
    return overflow_delta;
}

/// Round the (partials, overflow) state to a single f64. Mirrors
/// the final-rounding section of the TC39 reference polyfill. The
/// `overflow` is a signed integer counting biased 2^1024 multiples
/// (each one was recorded when the cascade had to subtract a 2^1024
/// to avoid landing at ±Inf). The MAX_DOUBLE rounding boundary is
/// hand-coded because the generic round-to-nearest-even would
/// over-step it under ties.
fn shewchukRound(partials_const: []const f64, overflow: f64) f64 {
    if (partials_const.len == 0 and overflow == 0) return 0.0;
    // Partials list is in *insertion* order (smallest magnitudes
    // were recorded as cascade residuals first, larger sums tacked
    // on at the end). We walk from the largest partial (index
    // `len - 1`) down to the smallest.
    var n: isize = @as(isize, @intCast(partials_const.len)) - 1;
    var hi: f64 = 0;
    var lo: f64 = 0;

    if (overflow != 0) {
        const next: f64 = if (n >= 0) partials_const[@intCast(n)] else 0;
        n -= 1;
        // If |overflow| > 1, or |overflow| == 1 with `next` of the
        // same sign, the magnitude is irrecoverably outside Number
        // range. Saturate to ±Inf.
        if (@abs(overflow) > 1 or (overflow > 0 and next > 0) or (overflow < 0 and next < 0)) {
            return if (overflow > 0) std.math.inf(f64) else -std.math.inf(f64);
        }
        // |overflow| == 1 and `next` is opposite-signed (or zero).
        // Drop a factor of 2 from both arms so the FastTwoSum
        // can run without overflowing.
        const big: f64 = 0x1.0p1023;
        const ts = twosum(overflow * big, next / 2.0);
        hi = ts.hi;
        lo = ts.lo * 2.0;
        // Edge case: `2 * hi` overflows. The TC39 polyfill notes
        // MAX_DOUBLE has a 1 in the last significand bit — exactly
        // half a ULP below 2^1024 rounds AWAY from MAX_DOUBLE
        // (toward +Inf) under tie-to-even. But when the residual
        // disagrees in sign, the correct rounding direction lands
        // back on ±MAX_DOUBLE.
        if (std.math.isInf(2.0 * hi)) {
            const MAX_DOUBLE: f64 = 1.7976931348623157e+308;
            // 2^(1023 - 52) — the ULP at MAX_DOUBLE magnitude.
            const MAX_ULP: f64 = 1.99584030953471981166e+292;
            if (hi > 0) {
                if (hi == big and lo == -(MAX_ULP / 2.0) and n >= 0 and partials_const[@intCast(n)] < 0) {
                    return MAX_DOUBLE;
                }
                return std.math.inf(f64);
            } else {
                if (hi == -big and lo == (MAX_ULP / 2.0) and n >= 0 and partials_const[@intCast(n)] > 0) {
                    return -MAX_DOUBLE;
                }
                return -std.math.inf(f64);
            }
        }
        if (lo != 0) {
            // We've consumed `next` from the list but still owe one
            // more partial below the current `hi`. The polyfill
            // pushes `lo` back into the partials slot we just read;
            // we mirror that with a local re-cast (avoid mutating
            // the const slice — copy `next` slot into a scratch
            // we own).
            // To keep things simple we just remember `lo` for the
            // tie-rounding step below; treat `partials[n + 1]` as if
            // it were `lo`. The polyfill restores partials[n+1] = lo
            // and bumps n; we do the equivalent by entering the
            // cascade-down loop with `lo` injected.
            // Inject via a synthesised one-slot extension below.
            return cascadeDownWithInject(partials_const, n, hi * 2.0, lo, true);
        }
        hi *= 2.0;
        return cascadeDownPure(partials_const, n, hi);
    }

    return cascadeDownPure(partials_const, n, 0);
}

/// Walk partials from index `n` down to 0 accumulating into `hi`
/// via FastTwoSum, stopping at the first non-zero residual. Apply
/// the round-half-to-even tie-break using the next-lower partial.
fn cascadeDownPure(partials: []const f64, n_in: isize, hi_in: f64) f64 {
    var hi = hi_in;
    var lo: f64 = 0;
    var n = n_in;
    while (n >= 0) {
        const x = hi;
        const y = partials[@intCast(n)];
        n -= 1;
        const ts = twosum(x, y);
        hi = ts.hi;
        lo = ts.lo;
        if (lo != 0) break;
    }
    // Round-half-to-even tie correction. When `lo` is half a ULP of
    // `hi` and the next-lower partial agrees in sign, bump `hi` away
    // from zero by one ULP.
    if (n >= 0 and ((lo < 0 and partials[@intCast(n)] < 0) or (lo > 0 and partials[@intCast(n)] > 0))) {
        const y = lo * 2.0;
        const x = hi + y;
        const yr = x - hi;
        if (y == yr) hi = x;
    }
    return hi;
}

/// Variant of `cascadeDownPure` that prepends an injected partial
/// (the polyfill's `partials[n+1] = lo; ++n;` trick) before the
/// down-cascade. Used by the overflow-recovery branch to feed the
/// residual from the biased twosum back in without mutating the
/// const slice.
fn cascadeDownWithInject(partials: []const f64, n_in: isize, hi_in: f64, injected: f64, has_inject: bool) f64 {
    var hi = hi_in;
    var lo: f64 = 0;
    var n = n_in;
    var injected_pending = has_inject;
    var inject_val = injected;

    while (injected_pending or n >= 0) {
        const x = hi;
        const y: f64 = if (injected_pending) inject_val else partials[@intCast(n)];
        if (injected_pending) {
            injected_pending = false;
            inject_val = 0;
        } else {
            n -= 1;
        }
        const ts = twosum(x, y);
        hi = ts.hi;
        lo = ts.lo;
        if (lo != 0) break;
    }
    if (n >= 0 and ((lo < 0 and partials[@intCast(n)] < 0) or (lo > 0 and partials[@intCast(n)] > 0))) {
        const y = lo * 2.0;
        const x = hi + y;
        const yr = x - hi;
        if (y == yr) hi = x;
    }
    return hi;
}
