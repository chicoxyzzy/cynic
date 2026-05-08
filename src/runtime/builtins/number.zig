//! §21.1 Number — extracted from `intrinsics.zig`. Includes:
//! • Number.prototype methods (`toFixed`, `toPrecision`,
//! `toExponential`, `toString`, `valueOf`).
//! • Number static methods (`isFinite`, `isNaN`, `isInteger`,
//! `isSafeInteger`, `parseInt`, `parseFloat`).
//! • Top-level globals (`parseInt`, `parseFloat`, `isNaN`,
//! `isFinite`).

const std = @import("std");

const Realm = @import("../realm.zig").Realm;
const Value = @import("../value.zig").Value;
const JSString = @import("../string.zig").JSString;
const JSObject = @import("../object.zig").JSObject;
const JSFunction = @import("../function.zig").JSFunction;
const NativeError = @import("../function.zig").NativeError;
const heap_mod = @import("../heap.zig");
const intrinsics = @import("../intrinsics.zig");

const installNativeMethod = intrinsics.installNativeMethod;
const installNativeMethodOnProto = intrinsics.installNativeMethodOnProto;
const argOr = intrinsics.argOr;
const coerceToNumber = intrinsics.coerceToNumber;
const numberFromI64 = intrinsics.numberFromI64;
const throwTypeError = intrinsics.throwTypeError;
const throwRangeError = intrinsics.throwRangeError;
const stringifyArg = intrinsics.stringifyArg;

pub fn install(realm: *Realm) !void {
    if (heap_mod.valueAsFunction(realm.globals.get("Number").?)) |num_ctor| {
        try installNativeMethod(realm, num_ctor, "isFinite", numberIsFinite, 1);
        try installNativeMethod(realm, num_ctor, "isNaN", numberIsNaN, 1);
        try installNativeMethod(realm, num_ctor, "isInteger", numberIsInteger, 1);
        try installNativeMethod(realm, num_ctor, "isSafeInteger", numberIsSafeInteger, 1);
        try installNativeMethod(realm, num_ctor, "parseInt", parseIntNative, 2);
        try installNativeMethod(realm, num_ctor, "parseFloat", parseFloatNative, 1);
        if (num_ctor.prototype) |np| {
            try installNativeMethodOnProto(realm, np, "toFixed", numberToFixed, 1);
            try installNativeMethodOnProto(realm, np, "toPrecision", numberToPrecision, 1);
            try installNativeMethodOnProto(realm, np, "toExponential", numberToExponential, 1);
            try installNativeMethodOnProto(realm, np, "toString", numberToString, 1);
            try installNativeMethodOnProto(realm, np, "valueOf", numberValueOf, 0);
            // §21.1.3 — `%Number.prototype%` itself has
            // `[[NumberData]]: +0`. Calling
            // `Number.prototype.toString(2)` directly returns
            // `"0"`; without this, `primitiveNumberValue` would
            // see no `boxed_primitive` and throw.
            np.boxed_primitive = Value.fromInt32(0);
        }
    }
    // Top-level parseInt / parseFloat / isNaN / isFinite globals.
    const pi = try realm.heap.allocateFunctionNative(parseIntNative, 2, "parseInt");
    try realm.globals.put(realm.allocator, "parseInt", heap_mod.taggedFunction(pi));
    const pf = try realm.heap.allocateFunctionNative(parseFloatNative, 1, "parseFloat");
    try realm.globals.put(realm.allocator, "parseFloat", heap_mod.taggedFunction(pf));
    const inn = try realm.heap.allocateFunctionNative(globalIsNaN, 1, "isNaN");
    try realm.globals.put(realm.allocator, "isNaN", heap_mod.taggedFunction(inn));
    const ifn = try realm.heap.allocateFunctionNative(globalIsFinite, 1, "isFinite");
    try realm.globals.put(realm.allocator, "isFinite", heap_mod.taggedFunction(ifn));
}

// ── Number.prototype formatters (§21.1.3, later) ────────────────────────────

fn primitiveNumberValue(this_value: Value) ?f64 {
    if (this_value.isInt32()) return @floatFromInt(this_value.asInt32());
    if (this_value.isDouble()) return this_value.asDouble();
    if (heap_mod.valueAsPlainObject(this_value)) |obj| {
        if (obj.boxed_primitive) |bp| {
            if (bp.isInt32()) return @floatFromInt(bp.asInt32());
            if (bp.isDouble()) return bp.asDouble();
        }
    }
    return null;
}

fn numberToFixed(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const x = primitiveNumberValue(this_value) orelse return throwTypeError(realm, "Number.prototype.toFixed called on non-number");
    const digits_v = coerceToNumber(argOr(args, 0, Value.fromInt32(0)));
    const dd: f64 = if (digits_v.isInt32()) @floatFromInt(digits_v.asInt32()) else digits_v.asDouble();
    if (std.math.isNan(dd) or std.math.isInf(dd) or dd < 0 or dd > 100)
        return throwRangeError(realm, "toFixed digits out of range [0, 100]");
    const digits: i32 = @intFromFloat(@trunc(dd));
    if (std.math.isNan(x)) {
        const s = realm.heap.allocateString("NaN") catch return error.OutOfMemory;
        return Value.fromString(s);
    }
    if (std.math.isInf(x)) {
        const s = realm.heap.allocateString(if (x > 0) "Infinity" else "-Infinity") catch return error.OutOfMemory;
        return Value.fromString(s);
    }
    var buf: [128]u8 = undefined;
    const slice = std.fmt.bufPrint(&buf, "{d:.[1]}", .{ x, @as(usize, @intCast(digits)) }) catch return error.OutOfMemory;
    const s = realm.heap.allocateString(slice) catch return error.OutOfMemory;
    return Value.fromString(s);
}

fn numberToExponential(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const x = primitiveNumberValue(this_value) orelse return throwTypeError(realm, "Number.prototype.toExponential called on non-number");
    const digits_arg = argOr(args, 0, Value.undefined_);
    var digits: i32 = -1;
    if (!digits_arg.isUndefined()) {
        const dv = coerceToNumber(digits_arg);
        const dd: f64 = if (dv.isInt32()) @floatFromInt(dv.asInt32()) else dv.asDouble();
        if (std.math.isNan(dd) or std.math.isInf(dd) or dd < 0 or dd > 100)
            return throwRangeError(realm, "toExponential digits out of range [0, 100]");
        digits = @intFromFloat(@trunc(dd));
    }
    if (std.math.isNan(x)) {
        const s = realm.heap.allocateString("NaN") catch return error.OutOfMemory;
        return Value.fromString(s);
    }
    if (std.math.isInf(x)) {
        const s = realm.heap.allocateString(if (x > 0) "Infinity" else "-Infinity") catch return error.OutOfMemory;
        return Value.fromString(s);
    }
    var buf: [128]u8 = undefined;
    const slice = if (digits < 0)
        std.fmt.bufPrint(&buf, "{e}", .{x}) catch return error.OutOfMemory
    else
        std.fmt.bufPrint(&buf, "{e:.[1]}", .{ x, @as(usize, @intCast(digits)) }) catch return error.OutOfMemory;
    const s = realm.heap.allocateString(slice) catch return error.OutOfMemory;
    return Value.fromString(s);
}

fn numberToPrecision(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const x = primitiveNumberValue(this_value) orelse return throwTypeError(realm, "Number.prototype.toPrecision called on non-number");
    const prec_arg = argOr(args, 0, Value.undefined_);
    if (prec_arg.isUndefined()) {
        // §21.1.3.5 step 2 — fall back to ToString.
        var buf: [64]u8 = undefined;
        const slice = std.fmt.bufPrint(&buf, "{d}", .{x}) catch return error.OutOfMemory;
        const s = realm.heap.allocateString(slice) catch return error.OutOfMemory;
        return Value.fromString(s);
    }
    const pv = coerceToNumber(prec_arg);
    const pd: f64 = if (pv.isInt32()) @floatFromInt(pv.asInt32()) else pv.asDouble();
    if (std.math.isNan(pd) or std.math.isInf(pd) or pd < 1 or pd > 100)
        return throwRangeError(realm, "toPrecision precision out of range [1, 100]");
    const prec: i32 = @intFromFloat(@trunc(pd));
    if (std.math.isNan(x)) {
        const s = realm.heap.allocateString("NaN") catch return error.OutOfMemory;
        return Value.fromString(s);
    }
    if (std.math.isInf(x)) {
        const s = realm.heap.allocateString(if (x > 0) "Infinity" else "-Infinity") catch return error.OutOfMemory;
        return Value.fromString(s);
    }
    // For later we approximate via Zig's default formatter
    // truncated to `prec` digits. Real spec semantics
    // (§21.1.3.5) round + decide between fixed / exponential
    // based on the exponent — that's later.
    var buf: [128]u8 = undefined;
    const slice = std.fmt.bufPrint(&buf, "{d:.[1]}", .{ x, @as(usize, @intCast(@max(prec - 1, 0))) }) catch return error.OutOfMemory;
    const s = realm.heap.allocateString(slice) catch return error.OutOfMemory;
    return Value.fromString(s);
}

fn numberToString(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const x = primitiveNumberValue(this_value) orelse return throwTypeError(realm, "Number.prototype.toString called on non-number");
    var radix: u8 = 10;
    if (args.len > 0 and !args[0].isUndefined()) {
        const rv = coerceToNumber(args[0]);
        const rd: f64 = if (rv.isInt32()) @floatFromInt(rv.asInt32()) else rv.asDouble();
        if (std.math.isNan(rd) or std.math.isInf(rd) or rd < 2 or rd > 36)
            return throwRangeError(realm, "toString radix out of range [2, 36]");
        radix = @intFromFloat(@trunc(rd));
    }
    if (std.math.isNan(x)) {
        const s = realm.heap.allocateString("NaN") catch return error.OutOfMemory;
        return Value.fromString(s);
    }
    if (std.math.isInf(x)) {
        const s = realm.heap.allocateString(if (x > 0) "Infinity" else "-Infinity") catch return error.OutOfMemory;
        return Value.fromString(s);
    }
    var buf: [128]u8 = undefined;
    if (radix == 10) {
        const slice = std.fmt.bufPrint(&buf, "{d}", .{x}) catch return error.OutOfMemory;
        const s = realm.heap.allocateString(slice) catch return error.OutOfMemory;
        return Value.fromString(s);
    }
    // Non-decimal: integer-only path. Fractional non-decimal
    // is rare in tests; we truncate.
    if (x == @trunc(x)) {
        const i: i64 = @intFromFloat(x);
        var u: u64 = 0;
        var negate = false;
        if (i < 0) {
            negate = true;
            u = @intCast(-i);
        } else {
            u = @intCast(i);
        }
        var tmp: [64]u8 = undefined;
        var n: usize = 0;
        if (u == 0) {
            tmp[0] = '0';
            n = 1;
        } else {
            while (u > 0) : (u /= radix) {
                const d: u8 = @intCast(u % radix);
                tmp[n] = if (d < 10) '0' + d else 'a' + (d - 10);
                n += 1;
            }
        }
        var len: usize = 0;
        if (negate) {
            buf[0] = '-';
            len = 1;
        }
        var k: usize = 0;
        while (k < n) : (k += 1) {
            buf[len + k] = tmp[n - 1 - k];
        }
        const s = realm.heap.allocateString(buf[0 .. len + n]) catch return error.OutOfMemory;
        return Value.fromString(s);
    }
    // Fractional non-decimal — fall back to base 10 for now.
    const slice = std.fmt.bufPrint(&buf, "{d}", .{x}) catch return error.OutOfMemory;
    const s = realm.heap.allocateString(slice) catch return error.OutOfMemory;
    return Value.fromString(s);
}

fn numberValueOf(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = realm;
    _ = args;
    if (this_value.isInt32() or this_value.isDouble()) return this_value;
    if (heap_mod.valueAsPlainObject(this_value)) |obj| {
        if (obj.boxed_primitive) |bp| {
            if (bp.isInt32() or bp.isDouble()) return bp;
        }
    }
    return error.NativeThrew;
}

// ── Number static methods + parseInt/parseFloat globals ─────────────────────

fn numberIsFinite(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = realm;
    _ = this_value;
    const v = argOr(args, 0, Value.undefined_);
    if (!v.isInt32() and !v.isDouble()) return Value.false_;
    if (v.isInt32()) return Value.true_;
    const d = v.asDouble();
    return Value.fromBool(!std.math.isNan(d) and !std.math.isInf(d));
}

fn numberIsNaN(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = realm;
    _ = this_value;
    const v = argOr(args, 0, Value.undefined_);
    if (!v.isDouble()) return Value.false_;
    return Value.fromBool(std.math.isNan(v.asDouble()));
}

fn numberIsInteger(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = realm;
    _ = this_value;
    const v = argOr(args, 0, Value.undefined_);
    if (v.isInt32()) return Value.true_;
    if (v.isDouble()) {
        const d = v.asDouble();
        if (std.math.isNan(d) or std.math.isInf(d)) return Value.false_;
        return Value.fromBool(d == @trunc(d));
    }
    return Value.false_;
}

fn numberIsSafeInteger(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = realm;
    _ = this_value;
    const v = argOr(args, 0, Value.undefined_);
    if (v.isInt32()) return Value.true_;
    if (v.isDouble()) {
        const d = v.asDouble();
        if (std.math.isNan(d) or std.math.isInf(d)) return Value.false_;
        if (d != @trunc(d)) return Value.false_;
        const safe_max: f64 = 9007199254740991.0;
        return Value.fromBool(d >= -safe_max and d <= safe_max);
    }
    return Value.false_;
}

fn parseIntNative(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = this_value;
    const v = argOr(args, 0, Value.undefined_);
    // §19.2.5 step 1 — ToString the argument first. Booleans /
    // numbers / undefined / null all stringify and are then
    // parsed. `parseInt(true)` ends up with input "true" which
    // doesn't begin with a numeric prefix → NaN.
    const s = stringifyArg(realm, v) catch return error.OutOfMemory;
    const radix_v = argOr(args, 1, Value.undefined_);
    var radix: u8 = 10;
    if (!radix_v.isUndefined()) {
        const rn = coerceToNumber(radix_v);
        if (rn.isInt32()) {
            const r = rn.asInt32();
            if (r >= 2 and r <= 36) radix = @intCast(r);
        }
    }
    const trimmed = std.mem.trim(u8, s.bytes, " \t\r\n");
    if (trimmed.len == 0) return Value.fromDouble(std.math.nan(f64));
    var slice = trimmed;
    var negative = false;
    if (slice[0] == '+') {
        slice = slice[1..];
    } else if (slice[0] == '-') {
        negative = true;
        slice = slice[1..];
    }
    // §19.2.5 — `0x` / `0X` prefix → hex. Don't allow '0o'/'0b'
    // for parseInt (§19.2.5 step 12 only mentions HexIntegerLiteral).
    if (slice.len >= 2 and slice[0] == '0' and (slice[1] == 'x' or slice[1] == 'X')) {
        if (radix == 10 or radix == 16) {
            radix = 16;
            slice = slice[2..];
        }
    }
    if (slice.len == 0) return Value.fromDouble(std.math.nan(f64));

    // Take the longest prefix of valid digits.
    var i: usize = 0;
    while (i < slice.len) : (i += 1) {
        const ch = slice[i];
        const digit: i32 = switch (ch) {
            '0'...'9' => @intCast(ch - '0'),
            'a'...'z' => @intCast(ch - 'a' + 10),
            'A'...'Z' => @intCast(ch - 'A' + 10),
            else => -1,
        };
        if (digit < 0 or digit >= @as(i32, radix)) break;
    }
    if (i == 0) return Value.fromDouble(std.math.nan(f64));
    const prefix = slice[0..i];
    const value = std.fmt.parseInt(i64, prefix, radix) catch {
        // Probably overflowed. Fall back to f64.
        const d = std.fmt.parseFloat(f64, prefix) catch return Value.fromDouble(std.math.nan(f64));
        return Value.fromDouble(if (negative) -d else d);
    };
    const signed = if (negative) -value else value;
    return numberFromI64(signed);
}

fn parseFloatNative(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = this_value;
    const v = argOr(args, 0, Value.undefined_);
    // §19.2.4 — ToString first.
    const s = stringifyArg(realm, v) catch return error.OutOfMemory;
    const trimmed = std.mem.trim(u8, s.bytes, " \t\r\n");
    if (trimmed.len == 0) return Value.fromDouble(std.math.nan(f64));
    const d = std.fmt.parseFloat(f64, trimmed) catch return Value.fromDouble(std.math.nan(f64));
    return Value.fromDouble(d);
}

fn globalIsNaN(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = realm;
    _ = this_value;
    const n = coerceToNumber(argOr(args, 0, Value.undefined_));
    if (!n.isDouble()) return Value.false_;
    return Value.fromBool(std.math.isNan(n.asDouble()));
}

fn globalIsFinite(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = realm;
    _ = this_value;
    const n = coerceToNumber(argOr(args, 0, Value.undefined_));
    if (n.isInt32()) return Value.true_;
    if (n.isDouble()) {
        const d = n.asDouble();
        return Value.fromBool(!std.math.isNan(d) and !std.math.isInf(d));
    }
    return Value.false_;
}

