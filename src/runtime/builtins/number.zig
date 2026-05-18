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
        if (num_ctor.prototype) |np| {
            try installNativeMethodOnProto(realm, np, "toFixed", numberToFixed, 1);
            try installNativeMethodOnProto(realm, np, "toPrecision", numberToPrecision, 1);
            try installNativeMethodOnProto(realm, np, "toExponential", numberToExponential, 1);
            try installNativeMethodOnProto(realm, np, "toString", numberToString, 1);
            // §21.1.3.4 Number.prototype.toLocaleString — Intl-aware
            // engines surface locale-specific digit separators and
            // grouping. Cynic doesn't ship Intl; the spec allows the
            // implementation-defined fallback to be ToString. Install
            // a thin shim that just calls `numberToString` so call
            // sites like `%TypedArray%.prototype.toLocaleString` and
            // user code expecting the method to exist see a callable.
            try installNativeMethodOnProto(realm, np, "toLocaleString", numberToLocaleString, 0);
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
    // §21.1.2.{12, 13} — `Number.parseInt === parseInt` and
    // `Number.parseFloat === parseFloat`: the SAME function
    // object on both bindings. Install once, then alias on
    // Number with the spec-mandated `{ w, !e, c }` flags.
    const pi = try realm.heap.allocateFunctionNative(parseIntNative, 2, "parseInt");
    // §20.1.1 — built-in function objects don't implement [[Construct]]
    // unless explicitly specified. `new parseInt(...)` must throw.
    pi.has_construct = false;
    try realm.globals.put(realm.allocator, "parseInt", heap_mod.taggedFunction(pi));
    const pf = try realm.heap.allocateFunctionNative(parseFloatNative, 1, "parseFloat");
    pf.has_construct = false;
    try realm.globals.put(realm.allocator, "parseFloat", heap_mod.taggedFunction(pf));
    if (heap_mod.valueAsFunction(realm.globals.get("Number").?)) |num_ctor| {
        try num_ctor.setWithFlags(realm.allocator, "parseInt", heap_mod.taggedFunction(pi), .{
            .writable = true, .enumerable = false, .configurable = true,
        });
        try num_ctor.setWithFlags(realm.allocator, "parseFloat", heap_mod.taggedFunction(pf), .{
            .writable = true, .enumerable = false, .configurable = true,
        });
    }
    const inn = try realm.heap.allocateFunctionNative(globalIsNaN, 1, "isNaN");
    inn.has_construct = false;
    try realm.globals.put(realm.allocator, "isNaN", heap_mod.taggedFunction(inn));
    const ifn = try realm.heap.allocateFunctionNative(globalIsFinite, 1, "isFinite");
    ifn.has_construct = false;
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
    // §21.1.3.3 step 2 — `Let f be ? ToIntegerOrInfinity(fractionDigits)`.
    // ToIntegerOrInfinity invokes ToNumber, which throws TypeError
    // for Symbol / BigInt arguments. `coerceToNumber` (the
    // non-throwing helper) returns NaN silently for those, so
    // route through the realm-aware `toNumber` instead.
    const digits_v = try intrinsics.toNumber(realm, argOr(args, 0, Value.fromInt32(0)));
    const raw: f64 = if (digits_v.isInt32()) @floatFromInt(digits_v.asInt32()) else digits_v.asDouble();
    const dd: f64 = if (std.math.isNan(raw)) 0 else @trunc(raw);
    if (std.math.isInf(dd) or dd < 0 or dd > 100)
        return throwRangeError(realm, "toFixed digits out of range [0, 100]");
    const digits: i32 = @intFromFloat(dd);
    if (std.math.isNan(x)) {
        const s = realm.heap.allocateString("NaN") catch return error.OutOfMemory;
        return Value.fromString(s);
    }
    if (std.math.isInf(x)) {
        const s = realm.heap.allocateString(if (x > 0) "Infinity" else "-Infinity") catch return error.OutOfMemory;
        return Value.fromString(s);
    }
    // §21.1.3.3 step 9 — if |x| ≥ 10^21, return Number::toString(x).
    // (The fixed-point representation would need more digits than
    // a Number can resolve; the spec defers to ToString instead.)
    if (@abs(x) >= 1e21) {
        const s = try intrinsics.stringifyArg(realm, Value.fromDouble(x));
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
    // §21.1.3.2 step 2 — ToIntegerOrInfinity on fractionDigits
    // ALWAYS runs (its valueOf side effect must fire). The range
    // guard at step 7 comes AFTER step 4's NaN/Infinity fast-path,
    // so a NaN receiver returns "NaN" even when fractionDigits is
    // out of [0, 100].
    var digits_finite_in_range = true;
    if (!digits_arg.isUndefined()) {
        const dv = try intrinsics.toNumber(realm, digits_arg);
        const raw: f64 = if (dv.isInt32()) @floatFromInt(dv.asInt32()) else dv.asDouble();
        const dd: f64 = if (std.math.isNan(raw)) 0 else @trunc(raw);
        if (std.math.isInf(dd) or dd < 0 or dd > 100) {
            digits_finite_in_range = false;
        } else {
            digits = @intFromFloat(dd);
        }
    }
    if (std.math.isNan(x)) {
        const s = realm.heap.allocateString("NaN") catch return error.OutOfMemory;
        return Value.fromString(s);
    }
    if (std.math.isInf(x)) {
        const s = realm.heap.allocateString(if (x > 0) "Infinity" else "-Infinity") catch return error.OutOfMemory;
        return Value.fromString(s);
    }
    // §21.1.3.2 step 7 — finite x with out-of-range fractionDigits.
    if (!digits_finite_in_range) {
        return throwRangeError(realm, "toExponential digits out of range [0, 100]");
    }
    // §21.1.3.2 step 3 — `x < 0` controls the sign character; -0
    // is NOT < 0 and renders as `"0e+0"`, not `"-0e+0"`. Zig's
    // `{e}` formatter prints `-0e0` for IEEE -0, which would
    // otherwise leak through the normaliser. Special-case before
    // bufPrint so step 9 (`If x = 0`) routes through the
    // unsigned-zero formatter.
    var buf: [128]u8 = undefined;
    const x_for_print: f64 = if (x == 0) 0 else x;
    const raw = if (digits < 0)
        std.fmt.bufPrint(&buf, "{e}", .{x_for_print}) catch return error.OutOfMemory
    else
        std.fmt.bufPrint(&buf, "{e:.[1]}", .{ x_for_print, @as(usize, @intCast(digits)) }) catch return error.OutOfMemory;
    // §6.1.6.1.13 Number::toString — JS demands `1e+22` for
    // positive exponents; Zig's `{e}` emits a bare `1e22`. Patch
    // through the shared normaliser.
    const slice = intrinsics.normalizeExponentPub(&buf, raw);
    const s = realm.heap.allocateString(slice) catch return error.OutOfMemory;
    return Value.fromString(s);
}

fn numberToPrecision(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const x = primitiveNumberValue(this_value) orelse return throwTypeError(realm, "Number.prototype.toPrecision called on non-number");
    const prec_arg = argOr(args, 0, Value.undefined_);
    if (prec_arg.isUndefined()) {
        // §21.1.3.5 step 2 — fall back to ToString.
        const s = try intrinsics.stringifyArg(realm, Value.fromDouble(x));
        return Value.fromString(s);
    }
    // §21.1.3.5 toPrecision — ToIntegerOrInfinity routes through
    // ToNumber, which throws on Symbol / BigInt.
    const pv = try intrinsics.toNumber(realm, prec_arg);
    const pd: f64 = if (pv.isInt32()) @floatFromInt(pv.asInt32()) else pv.asDouble();
    // §21.1.3.5 step 4 — non-finite `x` returns Number::toString
    // BEFORE the precision range check, so `Infinity.toPrecision(1000)`
    // returns `"Infinity"` rather than throwing RangeError.
    if (std.math.isNan(x)) {
        const s = realm.heap.allocateString("NaN") catch return error.OutOfMemory;
        return Value.fromString(s);
    }
    if (std.math.isInf(x)) {
        const s = realm.heap.allocateString(if (x > 0) "Infinity" else "-Infinity") catch return error.OutOfMemory;
        return Value.fromString(s);
    }
    if (std.math.isNan(pd) or std.math.isInf(pd) or pd < 1 or pd > 100)
        return throwRangeError(realm, "toPrecision precision out of range [1, 100]");
    const prec: i32 = @intFromFloat(@trunc(pd));
    const p: usize = @intCast(prec);

    // §21.1.3.5 step 6 — `x = 0`: return s + "0" * p with optional
    // decimal point. e = 0. Special-case before the log10 logic
    // (which would underflow on zero).
    if (x == 0) {
        var buf: [128]u8 = undefined;
        if (p == 1) {
            const s = realm.heap.allocateString("0") catch return error.OutOfMemory;
            return Value.fromString(s);
        }
        // "0.0…0" with p-1 trailing zeros after the dot.
        var n: usize = 0;
        buf[n] = '0';
        n += 1;
        buf[n] = '.';
        n += 1;
        var k: usize = 0;
        while (k < p - 1) : (k += 1) {
            buf[n] = '0';
            n += 1;
        }
        const s = realm.heap.allocateString(buf[0..n]) catch return error.OutOfMemory;
        return Value.fromString(s);
    }
    // Non-zero, finite x. Round to p significant digits via
    // Zig's `{e:.[1]}` (which gives `<d>.<d…>e<sign><exp>`), then
    // unpack to (sign, mantissa-digits, exponent).
    var ebuf: [256]u8 = undefined;
    const exp_str = std.fmt.bufPrint(&ebuf, "{e:.[1]}", .{ x, p - 1 }) catch return error.OutOfMemory;
    // Parse: optional leading '-', then digits, optionally '.digits',
    // then 'e' sign, then digits.
    var i: usize = 0;
    var sign: []const u8 = "";
    if (exp_str[i] == '-') {
        sign = "-";
        i += 1;
    }
    // Mantissa digits — collect them with the dot skipped.
    var m_buf: [128]u8 = undefined;
    var m_len: usize = 0;
    while (i < exp_str.len and exp_str[i] != 'e' and exp_str[i] != 'E') : (i += 1) {
        const c = exp_str[i];
        if (c == '.') continue;
        if (c < '0' or c > '9') break;
        m_buf[m_len] = c;
        m_len += 1;
    }
    // Skip 'e'.
    if (i >= exp_str.len) {
        // No exponent — Zig should always emit one with `{e}`,
        // but guard for safety.
        const fallback = realm.heap.allocateString(exp_str) catch return error.OutOfMemory;
        return Value.fromString(fallback);
    }
    i += 1; // past 'e'
    var exp_sign: i32 = 1;
    if (i < exp_str.len and exp_str[i] == '-') {
        exp_sign = -1;
        i += 1;
    } else if (i < exp_str.len and exp_str[i] == '+') {
        i += 1;
    }
    var exp_v: i32 = 0;
    while (i < exp_str.len) : (i += 1) {
        if (exp_str[i] < '0' or exp_str[i] > '9') break;
        exp_v = exp_v * 10 + @as(i32, exp_str[i] - '0');
    }
    const e: i32 = exp_sign * exp_v;

    // §21.1.3.5 step 8 — if e < -6 or e ≥ p, use scientific.
    var out: [256]u8 = undefined;
    var ol: usize = 0;
    if (e < -6 or e >= @as(i32, @intCast(p))) {
        // s + m[0] + "." + m[1..] + "e" + sign(e) + |e|
        for (sign) |c| {
            out[ol] = c;
            ol += 1;
        }
        out[ol] = m_buf[0];
        ol += 1;
        if (p > 1) {
            out[ol] = '.';
            ol += 1;
            for (m_buf[1..m_len]) |c| {
                out[ol] = c;
                ol += 1;
            }
        }
        out[ol] = 'e';
        ol += 1;
        out[ol] = if (e >= 0) '+' else '-';
        ol += 1;
        const eabs: i32 = if (e >= 0) e else -e;
        var ebs: [16]u8 = undefined;
        const es = std.fmt.bufPrint(&ebs, "{d}", .{eabs}) catch unreachable;
        for (es) |c| {
            out[ol] = c;
            ol += 1;
        }
    } else if (e == @as(i32, @intCast(p)) - 1) {
        // e == p-1 → return s + m
        for (sign) |c| {
            out[ol] = c;
            ol += 1;
        }
        for (m_buf[0..m_len]) |c| {
            out[ol] = c;
            ol += 1;
        }
    } else if (e >= 0) {
        // s + m[0..e+1] + "." + m[e+1..]
        for (sign) |c| {
            out[ol] = c;
            ol += 1;
        }
        const dot_at: usize = @intCast(e + 1);
        for (m_buf[0..dot_at]) |c| {
            out[ol] = c;
            ol += 1;
        }
        out[ol] = '.';
        ol += 1;
        for (m_buf[dot_at..m_len]) |c| {
            out[ol] = c;
            ol += 1;
        }
    } else {
        // e < 0 → s + "0." + ("0" * -(e+1)) + m
        for (sign) |c| {
            out[ol] = c;
            ol += 1;
        }
        out[ol] = '0';
        ol += 1;
        out[ol] = '.';
        ol += 1;
        var zeros: i32 = -(e + 1);
        while (zeros > 0) : (zeros -= 1) {
            out[ol] = '0';
            ol += 1;
        }
        for (m_buf[0..m_len]) |c| {
            out[ol] = c;
            ol += 1;
        }
    }
    const s = realm.heap.allocateString(out[0..ol]) catch return error.OutOfMemory;
    return Value.fromString(s);
}

fn numberToString(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const x = primitiveNumberValue(this_value) orelse return throwTypeError(realm, "Number.prototype.toString called on non-number");
    var radix: u8 = 10;
    if (args.len > 0 and !args[0].isUndefined()) {
        // §21.1.3.6 step 3 → ToIntegerOrInfinity → ToNumber.
        // ToNumber rejects Symbol / BigInt with TypeError.
        const rv = try intrinsics.toNumber(realm, args[0]);
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

/// §21.1.3.4 Number.prototype.toLocaleString ( [ reserves ] ).
/// Without Intl (out of scope per AGENTS.md) the spec permits
/// ToString as the implementation-defined fallback; that's also
/// what V8 does in builds without ICU (`-no-icu`). Delegate to
/// `numberToString` without honoring any reserved args (radix
/// only applies to `toString`).
fn numberToLocaleString(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    return numberToString(realm, this_value, &.{});
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

/// §11.2 WhiteSpace + §11.3 LineTerminator — the codepoint set
/// `parseInt` / `parseFloat` strip from the leading edge of their
/// argument (StrWhiteSpace in the StringNumericLiteral grammar at
/// §7.1.4.1). Mirrors the table used by `String.prototype.trim`.
fn isStrWhiteSpace(cp: u21) bool {
    return switch (cp) {
        // ASCII WhiteSpace + LineTerminator.
        0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x20 => true,
        // Other named whitespace.
        0x00A0, 0xFEFF => true,
        // Unicode Space_Separator (Zs) — enumerated to avoid pulling
        // the full UCD; covers the Unicode 15 set.
        0x1680, 0x2000, 0x2001, 0x2002, 0x2003, 0x2004, 0x2005, 0x2006, 0x2007, 0x2008, 0x2009, 0x200A, 0x202F, 0x205F, 0x3000 => true,
        // LineTerminator: LS / PS.
        0x2028, 0x2029 => true,
        else => false,
    };
}

/// Return the byte index of the first non-StrWhiteSpace codepoint
/// in `bytes`, or `bytes.len` if all-whitespace. UTF-8; an invalid
/// sequence stops the scan.
fn skipStrWhiteSpace(bytes: []const u8) usize {
    var view = std.unicode.Utf8View.initUnchecked(bytes).iterator();
    while (true) {
        const before = view.i;
        const cp = view.nextCodepoint() orelse return bytes.len;
        if (!isStrWhiteSpace(cp)) return before;
    }
}

fn parseIntNative(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = this_value;
    const v = argOr(args, 0, Value.undefined_);
    // §19.2.5 step 1 — ToString the argument first. Booleans /
    // numbers / undefined / null all stringify and are then
    // parsed. `parseInt(true)` ends up with input "true" which
    // doesn't begin with a numeric prefix → NaN.
    const s = try stringifyArg(realm, v);
    const radix_v = argOr(args, 1, Value.undefined_);
    // §19.2.5 step 7 — `R = ToInt32(radix)`. step 8 — if R != 0
    // and (R < 2 or R > 36) return NaN. Booleans coerce to 0/1
    // through `coerceToNumber`, so `parseInt("11", true)` lands
    // here with R = 1 → NaN.
    var radix: u8 = 10;
    var explicit_radix = false;
    if (!radix_v.isUndefined()) {
        // §19.2.5 step 7 — `R = ToInt32(radix)`. ToInt32 routes
        // through ToNumber, which throws TypeError on Symbol /
        // BigInt operands. Use the realm-aware `toNumber` so
        // those throws propagate instead of being collapsed to
        // NaN.
        const rn = try intrinsics.toNumber(realm, radix_v);
        var r: i32 = 0;
        if (rn.isInt32()) {
            r = rn.asInt32();
        } else if (rn.isDouble()) {
            const d = rn.asDouble();
            if (!std.math.isNan(d) and !std.math.isInf(d)) {
                // ToInt32: truncate toward zero, mod 2^32.
                const t = @trunc(d);
                const m = @mod(t, 4294967296.0);
                var ri: i64 = @intFromFloat(m);
                if (ri >= 2147483648) ri -= 4294967296;
                r = @intCast(ri);
            }
        }
        if (r != 0) {
            if (r < 2 or r > 36) return Value.fromDouble(std.math.nan(f64));
            radix = @intCast(r);
            explicit_radix = true;
        }
    }
    // §19.2.5 step 2 — strip leading StrWhiteSpace (Unicode-aware).
    const start = skipStrWhiteSpace(s.bytes);
    const trimmed = s.bytes[start..];
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
        if (!explicit_radix or radix == 16) {
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

/// §19.2.4 step 4 — find the longest prefix of `bytes` that is a
/// valid StrDecimalLiteral. Returns the byte length of that prefix
/// (0 if none). `bytes` must already have leading whitespace and a
/// leading sign stripped; the caller handles "Infinity" itself.
fn longestStrDecimalLiteralPrefix(bytes: []const u8) usize {
    if (bytes.len == 0) return 0;
    var i: usize = 0;
    var saw_int_digit = false;
    while (i < bytes.len and bytes[i] >= '0' and bytes[i] <= '9') : (i += 1) {
        saw_int_digit = true;
    }
    var end = i;
    if (i < bytes.len and bytes[i] == '.') {
        i += 1;
        const frac_start = i;
        while (i < bytes.len and bytes[i] >= '0' and bytes[i] <= '9') : (i += 1) {}
        // The `.` is part of the literal only if either an integer
        // digit preceded it or at least one fractional digit follows.
        if (saw_int_digit or i > frac_start) {
            end = i;
        } else {
            return 0;
        }
    } else if (!saw_int_digit) {
        return 0;
    }
    // Optional ExponentPart: e/E [+/-]? <digits>+. Only commit the
    // exponent if it's well-formed; otherwise the literal ends at
    // the position before the `e`.
    if (end < bytes.len and (bytes[end] == 'e' or bytes[end] == 'E')) {
        var j = end + 1;
        if (j < bytes.len and (bytes[j] == '+' or bytes[j] == '-')) j += 1;
        const exp_digits_start = j;
        while (j < bytes.len and bytes[j] >= '0' and bytes[j] <= '9') : (j += 1) {}
        if (j > exp_digits_start) end = j;
    }
    return end;
}

fn parseFloatNative(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = this_value;
    const v = argOr(args, 0, Value.undefined_);
    // §19.2.4 — ToString first.
    const s = try stringifyArg(realm, v);
    // §19.2.4 step 2 — strip leading StrWhiteSpace (Unicode-aware).
    const start = skipStrWhiteSpace(s.bytes);
    const trimmed = s.bytes[start..];
    if (trimmed.len == 0) return Value.fromDouble(std.math.nan(f64));
    var slice = trimmed;
    var negative = false;
    if (slice[0] == '+') {
        slice = slice[1..];
    } else if (slice[0] == '-') {
        negative = true;
        slice = slice[1..];
    }
    if (slice.len == 0) return Value.fromDouble(std.math.nan(f64));
    // §19.2.4 — "Infinity" prefix has its own MV; Zig's parseFloat
    // doesn't recognise the bare word.
    if (std.mem.startsWith(u8, slice, "Infinity")) {
        return Value.fromDouble(if (negative) -std.math.inf(f64) else std.math.inf(f64));
    }
    const prefix_len = longestStrDecimalLiteralPrefix(slice);
    if (prefix_len == 0) return Value.fromDouble(std.math.nan(f64));
    const prefix = slice[0..prefix_len];
    const d = std.fmt.parseFloat(f64, prefix) catch return Value.fromDouble(std.math.nan(f64));
    return Value.fromDouble(if (negative) -d else d);
}

fn globalIsNaN(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = this_value;
    // §19.2.4 isNaN — ToNumber(arg) must fire ToPrimitive on
    // Object receivers, which can throw if @@toPrimitive /
    // valueOf / toString returns non-primitive or throws.
    const n = try intrinsics.toNumber(realm, argOr(args, 0, Value.undefined_));
    if (n.isInt32()) return Value.false_;
    if (n.isDouble()) return Value.fromBool(std.math.isNan(n.asDouble()));
    return Value.false_;
}

fn globalIsFinite(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = this_value;
    const n = try intrinsics.toNumber(realm, argOr(args, 0, Value.undefined_));
    if (n.isInt32()) return Value.true_;
    if (n.isDouble()) {
        const d = n.asDouble();
        return Value.fromBool(!std.math.isNan(d) and !std.math.isInf(d));
    }
    return Value.false_;
}

