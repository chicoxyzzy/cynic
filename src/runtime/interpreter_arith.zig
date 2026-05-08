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

pub const RunError = @import("interpreter.zig").RunError;
const makeTypeError = @import("interpreter.zig").makeTypeError;
const makeRangeError = @import("interpreter.zig").makeRangeError;
const formatDoubleSafe = @import("interpreter.zig").formatDoubleSafe;


pub fn toBoolean(v: Value) bool {
    if (v.isString()) {
        const s: *JSString = @ptrCast(@alignCast(v.asString()));
        return !s.isEmpty();
    }
    // §7.1.2 — every Object is truthy, EXCEPT a `new Boolean(false)`
    // wrapper. Per spec all wrappers are still truthy as objects;
    // tests check this — `if (new Boolean(false))` runs the
    // consequent. We follow spec: object always truthy.
    if (v.isObject()) return true;
    return v.toBooleanPrimitive();
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
        // are 0; otherwise std.fmt.parseFloat. The full spec rules
        // (sign-prefix tolerance, hex `0x`, infinity literal) get
        // filled in with the `Number.parseFloat` work later.
        const trimmed = std.mem.trim(u8, s.bytes, " \t\r\n");
        if (trimmed.len == 0) return 0.0;
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

pub fn numericBinary(comptime op: NumericOp, lhs: Value, rhs: Value) Value {
    // Int32 fast path — only safe when both are int32 AND the
    // mathematical result also fits without overflow / float
    // promotion. Cheaper than the double path on cold caches.
    if (lhs.isInt32() and rhs.isInt32() and op != .div and op != .pow) {
        const a = lhs.asInt32();
        const b = rhs.asInt32();
        switch (op) {
            .sub => {
                const r = @subWithOverflow(a, b);
                if (r[1] == 0) return Value.fromInt32(r[0]);
            },
            .mul => {
                const r = @mulWithOverflow(a, b);
                if (r[1] == 0) return Value.fromInt32(r[0]);
            },
            .mod => {
                if (b != 0) return Value.fromInt32(@mod(a, b));
            },
            .div, .pow => unreachable,
        }
        // fall through to double path
    }

    const a = toNumber(lhs);
    const b = toNumber(rhs);
    return Value.fromDouble(switch (op) {
        .sub => a - b,
        .mul => a * b,
        .div => a / b,
        .mod => @mod(a, b),
        .pow => std.math.pow(f64, a, b),
    });
}

pub fn bitwiseBinary(comptime op: BitwiseOp, lhs: Value, rhs: Value) Value {
    const a = toInt32(lhs);
    const b = toInt32(rhs);
    return switch (op) {
        .bit_and => Value.fromInt32(a & b),
        .bit_or => Value.fromInt32(a | b),
        .bit_xor => Value.fromInt32(a ^ b),
        // §13.10: shift counts mask to 5 bits.
        .shl => Value.fromInt32(a << @as(u5, @intCast(@as(u32, @bitCast(b)) & 0x1F))),
        .shr => Value.fromInt32(a >> @as(u5, @intCast(@as(u32, @bitCast(b)) & 0x1F))),
        .shr_u => blk: {
            const ua: u32 = @bitCast(a);
            const ub: u32 = @bitCast(b);
            const result = ua >> @as(u5, @intCast(ub & 0x1F));
            break :blk Value.fromInt32(@bitCast(result));
        },
    };
}

pub fn unaryNegate(v: Value) Value {
    if (v.isInt32()) {
        const i = v.asInt32();
        // -INT_MIN overflows; promote to double in that case.
        if (i == std.math.minInt(i32)) return Value.fromDouble(-@as(f64, @floatFromInt(i)));
        return Value.fromInt32(-i);
    }
    return Value.fromDouble(-toNumber(v));
}

pub fn unaryBitNot(v: Value) Value {
    return Value.fromInt32(~toInt32(v));
}

pub fn unaryToNumber(v: Value) Value {
    if (v.isInt32() or v.isDouble()) return v;
    const d = toNumber(v);
    // Try int32 fast path on the way out.
    if (!std.math.isNan(d) and d == @trunc(d) and d >= std.math.minInt(i32) and d <= std.math.maxInt(i32)) {
        return Value.fromInt32(@intFromFloat(d));
    }
    return Value.fromDouble(d);
}

/// §7.1.6 / §6.1.6.1 — addition is the only operator with the
/// string-concatenation shortcut.
pub fn addValues(realm: *Realm, lhs: Value, rhs: Value) RunError!Value {
    // §13.15.4 ApplyStringOrNumericBinaryOperator. Both
    // operands first go through ToPrimitive (which consults
    // Symbol.toPrimitive / valueOf / toString on objects).
    var l = lhs;
    var r = rhs;
    if (l.isObject() or r.isObject()) {
        l = intrinsics_mod.toPrimitive(realm, l, .default) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.NativeThrew => {
                const ex = realm.pending_exception orelse try makeTypeError(realm, "ToPrimitive failed");
                realm.pending_exception = null;
                return ex;
            },
        };
        r = intrinsics_mod.toPrimitive(realm, r, .default) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.NativeThrew => {
                const ex = realm.pending_exception orelse try makeTypeError(realm, "ToPrimitive failed");
                realm.pending_exception = null;
                return ex;
            },
        };
    }
    if (heap_mod.isBigInt(l) and heap_mod.isBigInt(r)) {
        return (try bigintArith(realm, .add, l, r)) orelse {
            const ex = realm.pending_exception orelse try makeTypeError(realm, "BigInt op");
            realm.pending_exception = null;
            return ex;
        };
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
    if (a.isBool()) return looseEq(Value.fromInt32(if (a.asBool()) 1 else 0), b);
    if (b.isBool()) return looseEq(a, Value.fromInt32(if (b.asBool()) 1 else 0));
    return false;
}

pub fn relational(comptime op: RelOp, lhs: Value, rhs: Value) Value {
    // §7.2.13 IsLessThan with the standard four-direction
    // generalisation. later handles number-number and string-string;
    // mixed types coerce via ToNumber.
    if (heap_mod.valueAsBigInt(lhs)) |a| {
        if (heap_mod.valueAsBigInt(rhs)) |b| {
            const result = switch (op) {
                .lt => a.value < b.value,
                .gt => a.value > b.value,
                .le => a.value <= b.value,
                .ge => a.value >= b.value,
            };
            return Value.fromBool(result);
        }
        // BigInt vs Number — compare numerically with the BigInt
        // converted to f64 (lossy for large BigInts but matches
        // V8 / SM behaviour for the common cases test262 hits).
        const af: f64 = @floatFromInt(a.value);
        const bn = toNumber(rhs);
        if (std.math.isNan(bn)) return Value.false_;
        const result = switch (op) {
            .lt => af < bn,
            .gt => af > bn,
            .le => af <= bn,
            .ge => af >= bn,
        };
        return Value.fromBool(result);
    }
    if (heap_mod.valueAsBigInt(rhs)) |b| {
        const bf: f64 = @floatFromInt(b.value);
        const an = toNumber(lhs);
        if (std.math.isNan(an)) return Value.false_;
        const result = switch (op) {
            .lt => an < bf,
            .gt => an > bf,
            .le => an <= bf,
            .ge => an >= bf,
        };
        return Value.fromBool(result);
    }
    if (lhs.isString() and rhs.isString()) {
        const ls: *JSString = @ptrCast(@alignCast(lhs.asString()));
        const rs: *JSString = @ptrCast(@alignCast(rhs.asString()));
        const cmp = std.mem.order(u8, ls.bytes, rs.bytes);
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
    const result = switch (op) {
        .lt => a < b,
        .gt => a > b,
        .le => a <= b,
        .ge => a >= b,
    };
    return Value.fromBool(result);
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
    else if (heap_mod.isPlainObject(v))
        "object"
    else
        "undefined";
    const s = realm.heap.allocateString(name) catch return error.OutOfMemory;
    return Value.fromString(s);
}
