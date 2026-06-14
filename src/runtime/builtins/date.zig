//! §21.4 Date — extracted from `intrinsics.zig` to keep that
//! module focused on the cross-builtin orchestration. Cynic's
//! Date is UTC-only (`getTimezoneOffset` returns 0); the `set*`
//! / `getUTC*` setters and getters alias the local-time variants.

const std = @import("std");

const Realm = @import("../realm.zig").Realm;
const Value = @import("../value.zig").Value;
const JSString = @import("../string.zig").JSString;
const JSObject = @import("../object.zig").JSObject;
const JSFunction = @import("../function.zig").JSFunction;
const NativeError = @import("../function.zig").NativeError;
const heap_mod = @import("../heap.zig");
const intrinsics = @import("../intrinsics.zig");
const temporal_builtin = @import("temporal.zig");
const installConstructor = intrinsics.installConstructor;
const installNativeMethod = intrinsics.installNativeMethod;
const installNativeMethodOnProto = intrinsics.installNativeMethodOnProto;
const numberFromI64 = intrinsics.numberFromI64;
const coerceToNumber = intrinsics.coerceToNumber;
const throwTypeError = intrinsics.throwTypeError;
const throwRangeError = intrinsics.throwRangeError;
const argOr = intrinsics.argOr;

// ── §21.4 Date ──────────────────────────────────────────────────────────────

pub fn install(realm: *Realm) !void {
    // Date is callable both ways (`new Date()` constructs;
    // `Date()` returns a string). Mark `is_class = false` so
    // `is_class_constructor` stays at its default — the
    // class-only-via-new check doesn't apply.
    const r = try installConstructor(realm, .{
        .name = "Date",
        .ctor = dateConstructor,
        .arity = 7,
        .is_class = false,
        // §21.4.4 — Date.prototype does NOT have a @@toStringTag
        // entry; `Object.prototype.toString` derives `[object Date]`
        // from the `[[DateValue]]` internal slot (step 14 of
        // §20.1.3.6). The slot-based path lets user code install
        // its own toStringTag via `d[Symbol.toStringTag] = "..."`,
        // since no non-writable inherited descriptor blocks the
        // assignment.
    });
    const fn_obj = r.ctor;
    const proto = r.proto;

    // §17 — built-in constructors have a non-writable / non-enumerable
    // / non-configurable `prototype` data property. `installConstructor`
    // leaves the flag synthesizer at its `is_class_constructor`-gated
    // default (writable: true for non-class ctors); patch it directly
    // for Date so `Date.prototype/prop-desc.js` passes.
    try fn_obj.property_flags.put(realm.allocator, "prototype", .{
        .writable = false,
        .enumerable = false,
        .configurable = false,
    });

    // Static methods.
    try installNativeMethod(realm, fn_obj, "now", dateNow, 0);
    try installNativeMethod(realm, fn_obj, "parse", dateParse, 1);
    try installNativeMethod(realm, fn_obj, "UTC", dateUTC, 7);

    // Instance methods.
    try installNativeMethodOnProto(realm, proto, "getTime", dateGetTime, 0);
    try installNativeMethodOnProto(realm, proto, "valueOf", dateGetTime, 0);
    try installNativeMethodOnProto(realm, proto, "toString", dateToString, 0);
    try installNativeMethodOnProto(realm, proto, "toISOString", dateToISOString, 0);
    // §21.4.4.37 — toJSON is its own method that calls Invoke(O,
    // "toISOString"), NOT a delegate to dateToISOString. Aliasing
    // breaks the fixtures that swap toISOString on a plain object
    // and expect toJSON to dispatch through the receiver.
    try installNativeMethodOnProto(realm, proto, "toJSON", dateToJSON, 1);
    try installNativeMethodOnProto(realm, proto, "getFullYear", dateGetFullYear, 0);
    try installNativeMethodOnProto(realm, proto, "getMonth", dateGetMonth, 0);
    try installNativeMethodOnProto(realm, proto, "getDate", dateGetDate, 0);
    try installNativeMethodOnProto(realm, proto, "getDay", dateGetDay, 0);
    try installNativeMethodOnProto(realm, proto, "getHours", dateGetHours, 0);
    try installNativeMethodOnProto(realm, proto, "getMinutes", dateGetMinutes, 0);
    try installNativeMethodOnProto(realm, proto, "getSeconds", dateGetSeconds, 0);
    try installNativeMethodOnProto(realm, proto, "getMilliseconds", dateGetMs, 0);
    try installNativeMethodOnProto(realm, proto, "getTimezoneOffset", dateGetTzOffset, 0);
    try installNativeMethodOnProto(realm, proto, "getUTCFullYear", dateGetFullYear, 0);
    try installNativeMethodOnProto(realm, proto, "getUTCMonth", dateGetMonth, 0);
    try installNativeMethodOnProto(realm, proto, "getUTCDate", dateGetDate, 0);
    try installNativeMethodOnProto(realm, proto, "getUTCDay", dateGetDay, 0);
    try installNativeMethodOnProto(realm, proto, "getUTCHours", dateGetHours, 0);
    try installNativeMethodOnProto(realm, proto, "getUTCMinutes", dateGetMinutes, 0);
    try installNativeMethodOnProto(realm, proto, "getUTCSeconds", dateGetSeconds, 0);
    try installNativeMethodOnProto(realm, proto, "getUTCMilliseconds", dateGetMs, 0);

    // Setters — modify the instance's `[[DateValue]]`
    // and return the new ms timestamp. UTC variants alias the
    // local-time setters since Cynic's date math is UTC-only
    // (matches `getTimezoneOffset → 0`).
    try installNativeMethodOnProto(realm, proto, "setTime", dateSetTime, 1);
    try installNativeMethodOnProto(realm, proto, "setMilliseconds", dateSetMs, 1);
    try installNativeMethodOnProto(realm, proto, "setSeconds", dateSetSeconds, 2);
    try installNativeMethodOnProto(realm, proto, "setMinutes", dateSetMinutes, 3);
    try installNativeMethodOnProto(realm, proto, "setHours", dateSetHours, 4);
    try installNativeMethodOnProto(realm, proto, "setDate", dateSetDate, 1);
    try installNativeMethodOnProto(realm, proto, "setMonth", dateSetMonth, 2);
    try installNativeMethodOnProto(realm, proto, "setFullYear", dateSetFullYear, 3);
    try installNativeMethodOnProto(realm, proto, "setUTCMilliseconds", dateSetMs, 1);
    try installNativeMethodOnProto(realm, proto, "setUTCSeconds", dateSetSeconds, 2);
    try installNativeMethodOnProto(realm, proto, "setUTCMinutes", dateSetMinutes, 3);
    try installNativeMethodOnProto(realm, proto, "setUTCHours", dateSetHours, 4);
    try installNativeMethodOnProto(realm, proto, "setUTCDate", dateSetDate, 1);
    try installNativeMethodOnProto(realm, proto, "setUTCMonth", dateSetMonth, 2);
    try installNativeMethodOnProto(realm, proto, "setUTCFullYear", dateSetFullYear, 3);

    try installNativeMethodOnProto(realm, proto, "toUTCString", dateToUTCString, 0);
    try installNativeMethodOnProto(realm, proto, "toDateString", dateToDateString, 0);
    try installNativeMethodOnProto(realm, proto, "toTimeString", dateToTimeString, 0);
    try installNativeMethodOnProto(realm, proto, "toLocaleString", dateToString, 0);
    try installNativeMethodOnProto(realm, proto, "toLocaleDateString", dateToDateString, 0);
    try installNativeMethodOnProto(realm, proto, "toLocaleTimeString", dateToTimeString, 0);
    // Temporal proposal — `Date.prototype.toTemporalInstant` bridges a
    // legacy Date to a Temporal.Instant (epoch ms → epoch ns).
    try installNativeMethodOnProto(realm, proto, "toTemporalInstant", dateToTemporalInstant, 0);

    // §21.4.4.45 Date.prototype[@@toPrimitive] — OrdinaryToPrimitive
    // on the receiver with `tryFirst` determined by the hint. Spec
    // descriptor is `{ w: false, e: false, c: true }`, distinct
    // from the `installNativeMethodOnProto` default of writable: true.
    // The function's own `.name` is `"[Symbol.toPrimitive]"`, not
    // the raw `@@toPrimitive` slot key.
    const tp_fn = try realm.heap.allocateFunctionNative(realm, dateToPrimitive, 1, "[Symbol.toPrimitive]");
    tp_fn.has_construct = false;
    try proto.setWithFlags(realm.allocator, "@@toPrimitive", heap_mod.taggedFunction(tp_fn), .{
        .writable = false,
        .enumerable = false,
        .configurable = true,
    });
}

/// §21.4.4.45 Date.prototype[@@toPrimitive] ( hint )
///
/// 1. Let O be the this value.
/// 2. If O is not an Object, throw TypeError.
/// 3. If hint is "string" or "default", tryFirst = "string".
/// 4. Else if hint is "number", tryFirst = "number".
/// 5. Else throw TypeError.
/// 6. Return OrdinaryToPrimitive(O, tryFirst).
///
/// Note: this calls OrdinaryToPrimitive — NOT ToPrimitive. The
/// receiver's own `@@toPrimitive` (if it has one — common when this
/// method is .call'd on a plain object) MUST be bypassed here.
/// Cynic's `intrinsics.toPrimitive` would re-trigger the trap; do
/// the valueOf/toString walk inline instead.
fn dateToPrimitive(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const obj = heap_mod.valueAsPlainObject(this_value) orelse
        return throwTypeError(realm, "Date.prototype[Symbol.toPrimitive] called on non-object");
    const hint_v = argOr(args, 0, Value.undefined_);
    const try_first_string: bool = blk: {
        if (hint_v.isString()) {
            const s: *JSString = @ptrCast(@alignCast(hint_v.asString()));
            if (std.mem.eql(u8, s.flatBytes(), "string") or std.mem.eql(u8, s.flatBytes(), "default")) break :blk true;
            if (std.mem.eql(u8, s.flatBytes(), "number")) break :blk false;
        }
        return throwTypeError(realm, "Date.prototype[Symbol.toPrimitive]: invalid hint");
    };
    return ordinaryToPrimitive(realm, obj, this_value, try_first_string);
}

/// §7.1.1.1 OrdinaryToPrimitive(O, hint). `try_first_string` true
/// means try `toString` then `valueOf`; false means `valueOf` then
/// `toString`. Inlined here so `Date.prototype[@@toPrimitive]` can
/// bypass the user-installed `@@toPrimitive` trap on the receiver.
fn ordinaryToPrimitive(realm: *Realm, obj: *JSObject, this_value: Value, try_first_string: bool) NativeError!Value {
    const interp = @import("../lantern/interpreter.zig");
    const first_name: []const u8 = if (try_first_string) "toString" else "valueOf";
    const second_name: []const u8 = if (try_first_string) "valueOf" else "toString";
    for ([_][]const u8{ first_name, second_name }) |name| {
        const method = intrinsics.getPropertyChain(realm, obj, name) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.NativeThrew,
        };
        if (heap_mod.valueAsFunction(method)) |fn_obj| {
            const outcome = interp.callJSFunction(realm.allocator, realm, fn_obj, this_value, &[_]Value{}) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.NativeThrew,
            };
            switch (outcome) {
                .value, .yielded => |v| {
                    if (!heap_mod.isJSObject(v)) return v;
                },
                .thrown => |ex| {
                    realm.pending_exception = ex;
                    return error.NativeThrew;
                },
            }
        }
    }
    return throwTypeError(realm, "Cannot convert object to primitive value");
}

// ── Date setters (§21.4.4 — UTC-only since `getTimezoneOffset` is 0) ────────

/// Pre-coerce-and-snapshot helper for the §21.4.4 setters. Spec
/// order is: read [[DateValue]] (snapshot), then ? ToNumber each
/// *present* argument in source order, *then* check whether the
/// snapshot was NaN. Side-effects in valueOf can mutate the
/// receiver's [[DateValue]] mid-coercion (test262
/// `date-value-read-before-tonumber-when-date-is-{valid,invalid}`)
/// — the snapshot wins. ToNumber abrupt-completes propagate.
///
/// `arity` is the number of arguments the setter consumes; the
/// returned `coerced` array has exactly that many entries, with
/// indices ≥ args.len filled with NaN (a sentinel for "not
/// present" — distinct from a present `undefined`, which ToNumber
/// also turns into NaN, but presence is tracked separately via
/// `present_count`).
const SetterPrelude = struct {
    inst: *JSObject,
    snapshot: f64,
    coerced: [4]f64,
    present_count: usize,
};

fn setterPrelude(realm: *Realm, this_value: Value, args: []const Value, arity: usize) NativeError!SetterPrelude {
    const inst = heap_mod.valueAsPlainObject(this_value) orelse
        return throwTypeError(realm, "Date.prototype setter called on non-Date");
    const snapshot = inst.getDateMs() orelse
        return throwTypeError(realm, "Date.prototype setter called on non-Date");
    var coerced: [4]f64 = .{ std.math.nan(f64), std.math.nan(f64), std.math.nan(f64), std.math.nan(f64) };
    const present = @min(args.len, arity);
    var i: usize = 0;
    while (i < present) : (i += 1) {
        const v = try intrinsics.toNumber(realm, args[i]);
        coerced[i] = if (v.isInt32()) @as(f64, @floatFromInt(v.asInt32())) else v.asDouble();
    }
    return .{ .inst = inst, .snapshot = snapshot, .coerced = coerced, .present_count = present };
}

/// §21.4.1.31 TimeClip — abs(t) > 8.64e15 or non-finite ⇒ NaN,
/// otherwise ToInteger(t). The `+ 0.0` normalises a result of
/// `-0` (e.g. `@trunc(-0.5) == -0.0`) to `+0` per spec.
fn timeClip(t: f64) f64 {
    if (!std.math.isFinite(t)) return std.math.nan(f64);
    if (@abs(t) > 8.64e15) return std.math.nan(f64);
    return @trunc(t) + 0.0;
}

fn dateSetTime(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const inst = heap_mod.valueAsPlainObject(this_value) orelse
        return throwTypeError(realm, "Date.prototype.setTime called on non-Date");
    if (inst.getDateMs() == null) return throwTypeError(realm, "Date.prototype.setTime called on non-Date");
    const arg_v = if (args.len == 0) Value.undefined_ else args[0];
    const v = try intrinsics.toNumber(realm, arg_v);
    const t = if (v.isInt32()) @as(f64, @floatFromInt(v.asInt32())) else v.asDouble();
    const clipped = timeClip(t);
    try inst.setDateMs(realm.allocator, clipped);
    return Value.fromDouble(clipped);
}

fn dateSetMs(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const p = try setterPrelude(realm, this_value, args, 1);
    const cur = p.snapshot;
    if (std.math.isNan(cur)) return Value.fromDouble(cur);
    const new_ms_part = p.coerced[0];
    const old_ms_part = @floor(@mod(cur, 1000.0));
    const new_ms = timeClip(cur - old_ms_part + new_ms_part);
    try p.inst.setDateMs(realm.allocator, new_ms);
    return Value.fromDouble(new_ms);
}

fn dateSetSeconds(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const p = try setterPrelude(realm, this_value, args, 2);
    const cur = p.snapshot;
    if (std.math.isNan(cur)) return Value.fromDouble(cur);
    const sec = p.coerced[0];
    const ms_arg = if (p.present_count > 1) p.coerced[1] else @floor(@mod(cur, 1000.0));
    const day_minute_part = @floor(cur / 60000.0) * 60000.0;
    const new_ms = timeClip(day_minute_part + sec * 1000.0 + ms_arg);
    try p.inst.setDateMs(realm.allocator, new_ms);
    return Value.fromDouble(new_ms);
}

fn dateSetMinutes(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const p = try setterPrelude(realm, this_value, args, 3);
    const cur = p.snapshot;
    if (std.math.isNan(cur)) return Value.fromDouble(cur);
    const minute = p.coerced[0];
    const sec = if (p.present_count > 1) p.coerced[1] else @floor(@mod(cur, 60000.0) / 1000.0);
    const ms_arg = if (p.present_count > 2) p.coerced[2] else @floor(@mod(cur, 1000.0));
    const hour_part = @floor(cur / 3600000.0) * 3600000.0;
    const new_ms = timeClip(hour_part + minute * 60000.0 + sec * 1000.0 + ms_arg);
    try p.inst.setDateMs(realm.allocator, new_ms);
    return Value.fromDouble(new_ms);
}

fn dateSetHours(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const p = try setterPrelude(realm, this_value, args, 4);
    const cur = p.snapshot;
    if (std.math.isNan(cur)) return Value.fromDouble(cur);
    const hour = p.coerced[0];
    const minute = if (p.present_count > 1) p.coerced[1] else @floor(@mod(cur, 3600000.0) / 60000.0);
    const sec = if (p.present_count > 2) p.coerced[2] else @floor(@mod(cur, 60000.0) / 1000.0);
    const ms_arg = if (p.present_count > 3) p.coerced[3] else @floor(@mod(cur, 1000.0));
    const day_part = @floor(cur / 86400000.0) * 86400000.0;
    const new_ms = timeClip(day_part + hour * 3600000.0 + minute * 60000.0 + sec * 1000.0 + ms_arg);
    try p.inst.setDateMs(realm.allocator, new_ms);
    return Value.fromDouble(new_ms);
}

fn dateSetDate(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const p = try setterPrelude(realm, this_value, args, 1);
    const cur = p.snapshot;
    if (std.math.isNan(cur)) return Value.fromDouble(cur);
    const ymd = msToYMD(cur);
    const time_part = @mod(cur, 86400000.0);
    const new_day = p.coerced[0];
    const new_ms = timeClip(ymdToMs(@floatFromInt(ymd.year), @floatFromInt(ymd.month), new_day) * 86400000.0 + time_part);
    try p.inst.setDateMs(realm.allocator, new_ms);
    return Value.fromDouble(new_ms);
}

fn dateSetMonth(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const p = try setterPrelude(realm, this_value, args, 2);
    const cur = p.snapshot;
    if (std.math.isNan(cur)) return Value.fromDouble(cur);
    const ymd = msToYMD(cur);
    const time_part = @mod(cur, 86400000.0);
    const new_month = p.coerced[0];
    const new_day = if (p.present_count > 1) p.coerced[1] else @as(f64, @floatFromInt(ymd.day));
    const new_ms = timeClip(ymdToMs(@floatFromInt(ymd.year), new_month, new_day) * 86400000.0 + time_part);
    try p.inst.setDateMs(realm.allocator, new_ms);
    return Value.fromDouble(new_ms);
}

fn dateSetFullYear(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    // setFullYear is special: per §21.4.4.21, if t is NaN we
    // *don't* return NaN — we treat t as +0 and continue. So no
    // snapshot-NaN bail. Args still coerce in spec order before
    // the t-check.
    const p = try setterPrelude(realm, this_value, args, 3);
    const cur = p.snapshot;
    const ymd = if (std.math.isNan(cur)) YMD{ .year = 1970, .month = 0, .day = 1 } else msToYMD(cur);
    const time_part = if (std.math.isNan(cur)) 0.0 else @mod(cur, 86400000.0);
    const new_year = p.coerced[0];
    const new_month = if (p.present_count > 1) p.coerced[1] else @as(f64, @floatFromInt(ymd.month));
    const new_day = if (p.present_count > 2) p.coerced[2] else @as(f64, @floatFromInt(ymd.day));
    const new_ms = timeClip(ymdToMs(new_year, new_month, new_day) * 86400000.0 + time_part);
    try p.inst.setDateMs(realm.allocator, new_ms);
    return Value.fromDouble(new_ms);
}

const YMD = struct { year: i32, month: i32, day: i32 };

/// Howard Hinnant's "civil_from_days" — same algorithm we use
/// for `getFullYear` / `getMonth` etc. Returns the (year,
/// month-0-indexed, day) for an absolute days-since-epoch.
fn msToYMD(ms: f64) YMD {
    const days_since_epoch = std.math.floor(ms / 86400000.0);
    const z = @as(i64, @intFromFloat(days_since_epoch)) + 719468;
    const era_d: i64 = if (z >= 0) z else z - 146096;
    const era = @divTrunc(era_d, 146097);
    const doe = z - era * 146097;
    const yoe_num = doe - @divTrunc(doe, 1460) + @divTrunc(doe, 36524) - @divTrunc(doe, 146096);
    const yoe = @divTrunc(yoe_num, 365);
    const y = yoe + era * 400;
    const doy = doe - (365 * yoe + @divTrunc(yoe, 4) - @divTrunc(yoe, 100));
    const mp = @divTrunc(5 * doy + 2, 153);
    const d = doy - @divTrunc(153 * mp + 2, 5) + 1;
    const m = if (mp < 10) mp + 3 else mp - 9;
    const year = if (m <= 2) y + 1 else y;
    return .{
        .year = @intCast(year),
        .month = @intCast(m - 1),
        .day = @intCast(d),
    };
}

/// Inverse of `msToYMD` — returns days-since-epoch (as a f64
/// to handle out-of-range values without panicking on i64
/// overflow). Multiply by 86400000 to get ms.
fn ymdToMs(year_f: f64, month_f: f64, day_f: f64) f64 {
    const y_in: f64 = year_f;
    const m_in: f64 = month_f;
    const d_in: f64 = day_f;
    // Normalize month into 0..11, carrying into year.
    const m_offset = std.math.floor(m_in / 12.0);
    const y = y_in + m_offset;
    const m = m_in - m_offset * 12.0;
    // m: 0..11 → spec uses March-based year offset
    const yy = if (m <= 1.0) y - 1.0 else y;
    const era = std.math.floor(yy / 400.0);
    const yoe = yy - era * 400.0;
    const mp = if (m >= 2.0) m - 2.0 else m + 10.0;
    const doy = std.math.floor((153.0 * mp + 2.0) / 5.0) + d_in - 1.0;
    const doe = yoe * 365.0 + std.math.floor(yoe / 4.0) - std.math.floor(yoe / 100.0) + doy;
    const days = era * 146097.0 + doe - 719468.0;
    return days;
}

/// §21.4.2.1 — Date constructor. Three shapes:
/// • 0 args: current time.
/// • 1 arg `value`: if Date instance, copy [[DateValue]]; else
///   ToPrimitive(value) then either parse string or ToNumber.
/// • 2+ args: (year, month, [date], [hours], [min], [sec], [ms])
///   — ToNumber each in source order, apply +1900 year offset
///   when 0 ≤ ToInteger(year) ≤ 99, build via MakeDate / TimeClip.
///
/// When NewTarget is undefined (i.e. `Date()` called as a plain
/// function), spec returns ToDateString of the current time and
/// the arguments are completely ignored. Cynic detects that path
/// by `this_value` not being a plain object (the constructor
/// machinery installs the freshly-allocated `[[DateValue]]`
/// receiver when invoked via `new`).
fn dateConstructor(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const inst_opt = heap_mod.valueAsPlainObject(this_value);
    const is_construct = inst_opt != null and inst_opt.?.getDateMs() == null;

    // §21.4.2.1 step 1 — `Date()` (no `new`) returns the current
    // time formatted as a date string, ignoring ALL arguments.
    if (!is_construct) {
        const now_ms = currentTimeMs();
        return formatDateString(realm, now_ms);
    }
    const inst = inst_opt.?;

    var ms: f64 = 0;
    if (args.len == 0) {
        ms = currentTimeMs();
    } else if (args.len == 1) {
        // §21.4.2.1 step 3 — `Date(value)`. If value is a Date
        // instance, copy its date_ms slot (skip ToPrimitive).
        // Otherwise, ToPrimitive(value) → if String, parse; else
        // ToNumber.
        const arg = args[0];
        if (heap_mod.valueAsPlainObject(arg)) |o| {
            if (o.getDateMs()) |dms| {
                try inst.setDateMs(realm.allocator, timeClip(dms));
                return this_value;
            }
        }
        const prim = try intrinsics.toPrimitive(realm, arg, .default);
        if (prim.isString()) {
            const s_obj: *JSString = @ptrCast(@alignCast(prim.asString()));
            ms = parseIsoDate(s_obj.flatBytes());
        } else {
            const nv = try intrinsics.toNumber(realm, prim);
            ms = if (nv.isInt32()) @floatFromInt(nv.asInt32()) else nv.asDouble();
        }
        ms = timeClip(ms);
    } else {
        // §21.4.2.1 step 3.a-i — multi-arg form. Coerce each
        // PRESENT arg in spec order via ToNumber (so abrupt
        // completions short-circuit at the first poisoned valueOf,
        // and side-effects in valueOf log in source order). Missing
        // trailing args (`undefined` is NOT missing — argument
        // position present takes precedence) default to spec
        // values (date=1, others=0).
        const y = try coerceArg(realm, args, 0, std.math.nan(f64));
        const m = try coerceArg(realm, args, 1, 0);
        const d = try coerceArg(realm, args, 2, 1);
        const h = try coerceArg(realm, args, 3, 0);
        const mi = try coerceArg(realm, args, 4, 0);
        const sec = try coerceArg(realm, args, 5, 0);
        const msec = try coerceArg(realm, args, 6, 0);
        // §21.4.2.1 step 3.h — year offset: if y is not NaN and
        // 0 ≤ ToInteger(y) ≤ 99, yr = 1900 + ToInteger(y).
        const yr = applyYearOffset(y);
        ms = timeClip(makeUTC(yr, m, d, h, mi, sec, msec));
    }
    try inst.setDateMs(realm.allocator, ms);
    return this_value;
}

/// §21.4.2.1 step 3.h / §21.4.3.4 step 8 — year offset.
fn applyYearOffset(y: f64) f64 {
    if (std.math.isNan(y)) return y;
    const yi = @trunc(y);
    if (yi >= 0 and yi <= 99) return 1900 + yi;
    return y;
}

/// ToNumber an argument at position `i` if supplied (i.e. the
/// argument position is present, regardless of whether the value
/// is `undefined`). Missing → `default` (no coercion side-effect).
fn coerceArg(realm: *Realm, args: []const Value, i: usize, default: f64) NativeError!f64 {
    if (i >= args.len) return default;
    const v = try intrinsics.toNumber(realm, args[i]);
    return if (v.isInt32()) @as(f64, @floatFromInt(v.asInt32())) else v.asDouble();
}

fn formatDateString(realm: *Realm, ms: f64) NativeError!Value {
    if (std.math.isNan(ms)) {
        const s = realm.heap.allocateString("Invalid Date") catch return error.OutOfMemory;
        return Value.fromString(s);
    }
    const p = dateParts(ms);
    var buf: [96]u8 = undefined;
    var year_buf: [16]u8 = undefined;
    const year_str = formatYear(&year_buf, p.year);
    const text = std.fmt.bufPrint(&buf, "{s} {s} {d:0>2} {s} {d:0>2}:{d:0>2}:{d:0>2} GMT+0000 (Coordinated Universal Time)", .{
        weekdayName(p.weekday), monthName(p.month), u(p.day), year_str, u(p.hours), u(p.minutes), u(p.seconds),
    }) catch return throwRangeError(realm, "Invalid Date");
    const s = realm.heap.allocateString(text) catch return error.OutOfMemory;
    return Value.fromString(s);
}

fn dateNow(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = realm;
    _ = this_value;
    _ = args;
    return Value.fromDouble(currentTimeMs());
}

fn dateParse(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = this_value;
    if (args.len == 0) return Value.fromDouble(std.math.nan(f64));
    const s_value = try intrinsics.stringifyArg(realm, args[0]);
    const s = s_value.flatBytes();
    // §21.4.1.18 simplified ISO format. Real engines also accept
    // RFC 2822-style ("Mon, 01 Jan 2024 00:00:00 GMT"), but the
    // ISO branch covers nearly every test262 fixture and most
    // real-world `JSON.stringify(new Date()).slice(1,-1)` round
    // trips.
    var result = parseIsoDate(s);
    if (std.math.isNan(result)) {
        // Fallback — try the RFC 7231 IMF-fixdate / toUTCString
        // / toString forms ("Day, DD Mon YYYY HH:MM:SS GMT" and
        // "Day Mon DD YYYY HH:MM:SS GMT+0000 …"). zero.js round-
        // trips through both.
        result = parseRfcOrToString(s);
    }
    // §21.4.1.31 TimeClip — parse must clip the resulting time
    // value to the §6.1.6.1.1 maximum range. ISO `±275760-09-13`
    // happens to fit; +1 ms over either bound must read NaN.
    if (!std.math.isNan(result)) result = timeClip(result);
    return Value.fromDouble(result);
}

/// §21.4.1.18 Date Time String Format. Accepts:
///   YYYY              — year-only
///   YYYY-MM           — year + month
///   YYYY-MM-DD        — full date
///   YYYY-MM-DDTHH:mm[:ss[.sss]][Z|±HH:mm]   — date + time + tz
///   THH:mm[:ss[.sss]] — time-only (today's date in UTC)
/// Extended-year form `±YYYYYY` (six digits, signed) covers years
/// outside 0001-9999 (e.g. `-000001-01-01T00:00:00Z`).
fn parseIsoDate(src: []const u8) f64 {
    var p: usize = 0;
    if (src.len == 0) return std.math.nan(f64);

    // Year — optional sign + 4 or 6 digits.
    var year_sign: f64 = 1;
    if (p < src.len and (src[p] == '+' or src[p] == '-')) {
        if (src[p] == '-') year_sign = -1;
        p += 1;
        // Expanded year: must be 6 digits.
        const year = parseFixedDigits(src, &p, 6) orelse return std.math.nan(f64);
        if (year_sign == -1 and year == 0) return std.math.nan(f64); // §21.4.1.18 — `-000000` is invalid
        return continueIsoDate(src, p, year_sign * @as(f64, @floatFromInt(year)));
    }
    const year = parseFixedDigits(src, &p, 4) orelse return std.math.nan(f64);
    return continueIsoDate(src, p, @floatFromInt(year));
}

fn continueIsoDate(src: []const u8, start: usize, year: f64) f64 {
    var p = start;
    var month: i64 = 1;
    var day: i64 = 1;
    var hour: f64 = 0;
    var minute: f64 = 0;
    var second: f64 = 0;
    var ms: f64 = 0;
    var tz_offset_min: f64 = 0; // negative = east of UTC

    if (p < src.len and src[p] == '-') {
        p += 1;
        const m = parseFixedDigits(src, &p, 2) orelse return std.math.nan(f64);
        if (m < 1 or m > 12) return std.math.nan(f64);
        month = m;
        if (p < src.len and src[p] == '-') {
            p += 1;
            const d = parseFixedDigits(src, &p, 2) orelse return std.math.nan(f64);
            if (d < 1 or d > 31) return std.math.nan(f64);
            day = d;
        }
    }

    if (p < src.len and src[p] == 'T') {
        p += 1;
        const h = parseFixedDigits(src, &p, 2) orelse return std.math.nan(f64);
        if (h > 24) return std.math.nan(f64);
        hour = @floatFromInt(h);
        if (p >= src.len or src[p] != ':') return std.math.nan(f64);
        p += 1;
        const mi = parseFixedDigits(src, &p, 2) orelse return std.math.nan(f64);
        if (mi > 59) return std.math.nan(f64);
        minute = @floatFromInt(mi);
        if (p < src.len and src[p] == ':') {
            p += 1;
            const sec = parseFixedDigits(src, &p, 2) orelse return std.math.nan(f64);
            if (sec > 59) return std.math.nan(f64);
            second = @floatFromInt(sec);
            if (p < src.len and src[p] == '.') {
                p += 1;
                // Fractional seconds — read 1+ digits, treat as
                // milliseconds (.sss). Per spec exactly 3 digits,
                // but real engines accept any.
                const frac_start = p;
                while (p < src.len and src[p] >= '0' and src[p] <= '9') p += 1;
                if (p == frac_start) return std.math.nan(f64);
                // Convert e.g. "5" → 500ms, "50" → 500ms, "500" → 500ms.
                var ms_f: f64 = 0;
                var mult: f64 = 100.0;
                for (src[frac_start..@min(frac_start + 3, p)]) |c| {
                    ms_f += @as(f64, @floatFromInt(c - '0')) * mult;
                    mult /= 10.0;
                }
                ms = ms_f;
            }
        }

        // Timezone designator.
        if (p < src.len) {
            if (src[p] == 'Z') {
                p += 1;
            } else if (src[p] == '+' or src[p] == '-') {
                const sign: f64 = if (src[p] == '-') 1 else -1; // negate: east of UTC subtracts
                p += 1;
                const tzh = parseFixedDigits(src, &p, 2) orelse return std.math.nan(f64);
                if (p >= src.len or src[p] != ':') return std.math.nan(f64);
                p += 1;
                const tzm = parseFixedDigits(src, &p, 2) orelse return std.math.nan(f64);
                if (tzh > 23 or tzm > 59) return std.math.nan(f64);
                tz_offset_min = sign * (@as(f64, @floatFromInt(tzh * 60 + tzm)));
            } else {
                return std.math.nan(f64);
            }
        } else {
            // §21.4.1.18 step 7 — date-with-time but no TZ
            // designator is interpreted as LOCAL time. Cynic
            // doesn't carry locale; treat as UTC for simplicity
            // (matches V8 behavior in most server timezones).
        }
    }

    if (p != src.len) return std.math.nan(f64);

    const t = makeUTC(year, @floatFromInt(month - 1), @floatFromInt(day), hour, minute, second, ms);
    if (std.math.isNan(t)) return t;
    return t + tz_offset_min * 60000.0;
}

/// Best-effort parse of the toString / toUTCString output formats.
/// Used as a fallback by `Date.parse` so the round-trip
/// `Date.parse(d.toString()) === d.valueOf()` holds for any d
/// produced by Cynic's formatters. Returns NaN on no match.
///
/// Accepts:
///   "Day Mon DD YYYY HH:MM:SS GMT+0000 (Coordinated Universal Time)"
///     — Date.prototype.toString output (UTC-only, per Cynic).
///   "Day, DD Mon YYYY HH:MM:SS GMT"  — toUTCString output.
fn parseRfcOrToString(src: []const u8) f64 {
    var s = src;
    // Skip leading weekday + comma if any ("Mon, " or "Mon ").
    var first_space: ?usize = null;
    for (s, 0..) |c, i| {
        if (c == ' ') {
            first_space = i;
            break;
        }
    }
    const fs = first_space orelse return std.math.nan(f64);
    s = std.mem.trim(u8, s[fs + 1 ..], " ");
    if (s.len > 0 and s[0] == ',') s = std.mem.trim(u8, s[1..], " ");

    // Two grammars after the weekday token:
    //  toUTCString: DD Mon YYYY HH:MM:SS GMT
    //  toString:    Mon DD YYYY HH:MM:SS GMT+0000 (...)
    // Distinguish by whether s[0..2] is digits.
    var idx: usize = 0;
    var month_i: i32 = -1;
    var day_i: i32 = 0;
    var year_f: f64 = 0;
    var year_sign: f64 = 1;

    if (s.len >= 2 and isDigit(s[0])) {
        // toUTCString form: "DD Mon YYYY HH:MM:SS GMT"
        const dd = parseUintField(s, &idx) orelse return std.math.nan(f64);
        day_i = @intCast(dd);
        idx = skipSpaces(s, idx);
        const mon = parseMonthAbbrev(s, &idx) orelse return std.math.nan(f64);
        month_i = mon;
        idx = skipSpaces(s, idx);
    } else {
        // toString form: "Mon DD YYYY ..."
        const mon = parseMonthAbbrev(s, &idx) orelse return std.math.nan(f64);
        month_i = mon;
        idx = skipSpaces(s, idx);
        const dd = parseUintField(s, &idx) orelse return std.math.nan(f64);
        day_i = @intCast(dd);
        idx = skipSpaces(s, idx);
    }

    // Year — may have a leading sign for negative years.
    if (idx < s.len and (s[idx] == '-' or s[idx] == '+')) {
        if (s[idx] == '-') year_sign = -1;
        idx += 1;
    }
    const yr = parseUintField(s, &idx) orelse return std.math.nan(f64);
    year_f = year_sign * @as(f64, @floatFromInt(yr));
    idx = skipSpaces(s, idx);

    // HH:MM:SS
    const hh = parseUintField(s, &idx) orelse return std.math.nan(f64);
    if (idx >= s.len or s[idx] != ':') return std.math.nan(f64);
    idx += 1;
    const mm = parseUintField(s, &idx) orelse return std.math.nan(f64);
    if (idx >= s.len or s[idx] != ':') return std.math.nan(f64);
    idx += 1;
    const ss = parseUintField(s, &idx) orelse return std.math.nan(f64);
    idx = skipSpaces(s, idx);

    // Timezone — either "GMT" (UTC) or "GMT+0000" / "GMT-0500".
    var tz_off_min: f64 = 0;
    if (idx + 3 <= s.len and std.mem.eql(u8, s[idx .. idx + 3], "GMT")) {
        idx += 3;
        if (idx < s.len and (s[idx] == '+' or s[idx] == '-')) {
            const tz_sign: f64 = if (s[idx] == '-') 1 else -1;
            idx += 1;
            if (idx + 4 > s.len) return std.math.nan(f64);
            const tz_hh = (s[idx] - '0') * 10 + (s[idx + 1] - '0');
            const tz_mm = (s[idx + 2] - '0') * 10 + (s[idx + 3] - '0');
            idx += 4;
            tz_off_min = tz_sign * @as(f64, @floatFromInt(@as(i32, tz_hh) * 60 + @as(i32, tz_mm)));
        }
    } else {
        return std.math.nan(f64);
    }

    const t = makeUTC(year_f, @floatFromInt(month_i), @floatFromInt(day_i), @floatFromInt(hh), @floatFromInt(mm), @floatFromInt(ss), 0);
    if (std.math.isNan(t)) return t;
    return t + tz_off_min * 60000.0;
}

fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

fn skipSpaces(s: []const u8, start: usize) usize {
    var i = start;
    while (i < s.len and s[i] == ' ') : (i += 1) {}
    return i;
}

fn parseUintField(s: []const u8, p: *usize) ?u64 {
    var i = p.*;
    if (i >= s.len or !isDigit(s[i])) return null;
    var acc: u64 = 0;
    while (i < s.len and isDigit(s[i])) : (i += 1) {
        acc = acc * 10 + (s[i] - '0');
    }
    p.* = i;
    return acc;
}

fn parseMonthAbbrev(s: []const u8, p: *usize) ?i32 {
    if (p.* + 3 > s.len) return null;
    const abbrev = s[p.* .. p.* + 3];
    inline for (month_names, 0..) |name, i| {
        if (std.mem.eql(u8, abbrev, name)) {
            p.* += 3;
            return @intCast(i);
        }
    }
    return null;
}

/// Read exactly `n` decimal digits starting at `p.*`; advance
/// `p.*` past them on success. Returns null if there aren't
/// enough digits.
fn parseFixedDigits(src: []const u8, p: *usize, n: usize) ?i64 {
    if (p.* + n > src.len) return null;
    var acc: i64 = 0;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const c = src[p.* + i];
        if (c < '0' or c > '9') return null;
        acc = acc * 10 + @as(i64, c - '0');
    }
    p.* += n;
    return acc;
}

fn dateUTC(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = this_value;
    if (args.len == 0) return Value.fromDouble(std.math.nan(f64));
    // §21.4.3.4 — coerce in spec order, then apply +1900 year
    // offset for 0 ≤ ToInteger(y) ≤ 99 before MakeDate / TimeClip.
    const y = try coerceArg(realm, args, 0, std.math.nan(f64));
    const m = try coerceArg(realm, args, 1, 0);
    const d = try coerceArg(realm, args, 2, 1);
    const h = try coerceArg(realm, args, 3, 0);
    const mi = try coerceArg(realm, args, 4, 0);
    const sec = try coerceArg(realm, args, 5, 0);
    const msec = try coerceArg(realm, args, 6, 0);
    const yr = applyYearOffset(y);
    return Value.fromDouble(timeClip(makeUTC(yr, m, d, h, mi, sec, msec)));
}

fn currentTimeMs() f64 {
    // §21.4.1.6 — wall-clock milliseconds since the Unix epoch.
    // Zig 0.16's `std.Io.Clock` requires an `io` handle that
    // natives don't carry; drop down to the libc shim.
    //
    // On a freestanding target with no libc (the
    // `wasm32-freestanding` playground build) there is no
    // `clock_gettime` — `std.c.timespec` is `void`. The playground
    // sandbox deliberately has no ambient wall clock anyway, so
    // `Date.now()` and `new Date()` resolve to the epoch (0). A
    // host that wants a real clock there would import a `now` hook;
    // the playground does not need one.
    if (@import("builtin").os.tag == .freestanding) return 0;
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts) != 0) return 0;
    const sec_f: f64 = @floatFromInt(ts.sec);
    const nsec_f: f64 = @floatFromInt(ts.nsec);
    // §21.4.1.6 SystemUTCEpochMilliseconds is floor(nowNs / 10^6) — an
    // integral millisecond count. Drop the sub-millisecond remainder so
    // `Date.now()` returns an integer (§21.4.3.1 returns 𝔽 of it) rather
    // than leaking nanosecond precision as a fractional Number.
    return @floor(sec_f * 1000.0 + nsec_f / 1_000_000.0);
}

/// Convert a (y, m, d, h, mi, s, ms) tuple to UTC milliseconds.
/// §21.4.1.13 — simplified: no timezone, no DST. Months are
/// 0-indexed; days 1-indexed. ToInteger truncation on each
/// component matches `Date.UTC/non-integer-values.js`.
fn makeUTC(y: f64, m: f64, d: f64, h: f64, mi: f64, s: f64, ms: f64) f64 {
    if (std.math.isNan(y) or std.math.isNan(m) or std.math.isNan(d)) {
        return std.math.nan(f64);
    }
    // §21.4.1.14 MakeTime step 1 — any non-finite time component
    // poisons the result to NaN.
    if (!std.math.isFinite(h) or !std.math.isFinite(mi) or !std.math.isFinite(s) or !std.math.isFinite(ms)) {
        return std.math.nan(f64);
    }
    if (std.math.isInf(y) or std.math.isInf(m) or std.math.isInf(d)) return std.math.nan(f64);
    // ToInteger truncation on each component (§21.4.1.13 step 1).
    const yi = @trunc(y);
    const mi_int = @trunc(m);
    const di = @trunc(d);
    const hi = @trunc(h);
    const mn = @trunc(mi);
    const si = @trunc(s);
    const msi = @trunc(ms);
    // §21.4.1.13 — silently treat "this is too far away to be
    // representable" as Invalid Date. test262 fixtures pass
    // huge years (1e21+) to test edge cases; raw `@intFromFloat`
    // panics on those.
    const safe_year_max: f64 = 275760.0; // ~JS spec maximum year
    if (@abs(yi) > safe_year_max) return std.math.nan(f64);
    // Month and day inherit the same "too far away to be a valid time"
    // envelope. Without these guards Fuzzilli inputs like
    // `new Date(0, -2.3e307)` panic on the @intFromFloat cast — host-
    // safety violation per AGENTS.md (never abort on untrusted input).
    // 9e15 sits well below both i64 saturation (~9.2e18) and the
    // downstream era*146097 overflow threshold (~6.3e13 for era), so
    // daysFromEpoch's i64 arithmetic stays bounded; it's also large
    // enough that legitimate test262 fixtures (`Date.UTC(1970,0,2e11,
    // 0,0,0,-1.8e19)` — fp-evaluation-order.js) pass through without
    // being clamped to NaN.
    const safe_md_max: f64 = 9.0e15;
    if (@abs(mi_int) > safe_md_max or @abs(di) > safe_md_max) return std.math.nan(f64);
    const year_i: i64 = @intFromFloat(yi);
    const month_i: i64 = @intFromFloat(mi_int);
    const day_i: i64 = @intFromFloat(di);
    const days = daysFromEpoch(year_i, month_i, day_i);
    const hours_total: f64 = hi * 3600000.0 + mn * 60000.0 + si * 1000.0 + msi;
    const days_ms: f64 = @as(f64, @floatFromInt(days)) * 86400000.0;
    return days_ms + hours_total;
}

/// Days from 1970-01-01 (UTC) to (year, month-0-indexed, day-1-indexed).
fn daysFromEpoch(year: i64, month: i64, day: i64) i64 {
    // §21.4.1.13 MakeDay step 5 — normalize month overflow into
    // year first. Without this, `new Date(2016, 12)` (month=12,
    // "January of next year") would walk into Hinnant's algorithm
    // with an invalid month index. Use floor-mod so negative
    // months also carry correctly (e.g. month=-1 → previous year
    // December).
    const month_carry = @divFloor(month, 12);
    var y = year + month_carry;
    var m = month - month_carry * 12;
    // Howard Hinnant's days_from_civil. Treats March as month 0
    // internally for the leap-day arithmetic. Handles negative
    // years.
    if (m < 2) {
        y -= 1;
        m += 12;
    }
    // Hinnant's `civil_from_days` inverse uses C-style truncating
    // division ("y/400 toward zero"), not floor division. With
    // `@divFloor`, year -1 (= adjusted y=-2 → y-399=-401) gives
    // era=-2, yoe=798 — off by one full 400-year cycle from the
    // expected era=-1, yoe=398. `@divTrunc` matches the reference.
    const era = @divTrunc(if (y >= 0) y else y - 399, 400);
    const yoe: i64 = y - era * 400;
    const doy: i64 = @divTrunc(153 * (m - 2) + 2, 5) + day - 1;
    const doe: i64 = yoe * 365 + @divTrunc(yoe, 4) - @divTrunc(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

/// Broken-down civil-calendar fields for an epoch-ms value. `pub` so
/// the playground's value-hint formatter (`src/wasm_format.zig`) can
/// render a Date's ISO string from the same pure math the
/// `toISOString` builtin uses, instead of duplicating the
/// days-to-y/m/d algorithm.
pub const DateParts = struct { year: i64, month: i64, day: i64, weekday: i64, hours: i64, minutes: i64, seconds: i64, ms: i64 };

pub fn dateParts(ms_v: f64) DateParts {
    if (std.math.isNan(ms_v) or std.math.isInf(ms_v)) {
        return .{ .year = 0, .month = 0, .day = 0, .weekday = 0, .hours = 0, .minutes = 0, .seconds = 0, .ms = 0 };
    }
    const total: i64 = @intFromFloat(@trunc(ms_v));
    var days = @divFloor(total, 86400000);
    var rem = @mod(total, 86400000);
    if (rem < 0) {
        rem += 86400000;
        days -= 1;
    }
    const hours = @divFloor(rem, 3600000);
    rem = @mod(rem, 3600000);
    const minutes = @divFloor(rem, 60000);
    rem = @mod(rem, 60000);
    const seconds = @divFloor(rem, 1000);
    const millis = @mod(rem, 1000);

    // Weekday (1970-01-01 was a Thursday → 4).
    const weekday = @mod(days + 4, 7);
    const wd = if (weekday < 0) weekday + 7 else weekday;

    // Civil from days (inverse of daysFromEpoch). Hinnant's
    // reference uses C-style truncating division throughout; with
    // `@divFloor`, the negative-z boundary (e.g. ms = -8.64e15,
    // days = -100000000, z = -99280532) misclassifies the era by
    // one cycle and the resulting `doe = -78` underflows the
    // subsequent positive-yoe formulas. Match the reference.
    const z: i64 = days + 719468;
    const era = @divTrunc(if (z >= 0) z else z - 146096, 146097);
    const doe: i64 = z - era * 146097;
    const yoe: i64 = @divTrunc(doe - @divTrunc(doe, 1460) + @divTrunc(doe, 36524) - @divTrunc(doe, 146096), 365);
    var y: i64 = yoe + era * 400;
    const doy = doe - (365 * yoe + @divTrunc(yoe, 4) - @divTrunc(yoe, 100));
    const mp = @divTrunc(5 * doy + 2, 153);
    const d_ret = doy - @divTrunc(153 * mp + 2, 5) + 1;
    const m_ret: i64 = if (mp < 10) mp + 2 else mp - 10;
    if (m_ret <= 1) y += 1;

    return .{
        .year = y,
        .month = m_ret,
        .day = d_ret,
        .weekday = wd,
        .hours = hours,
        .minutes = minutes,
        .seconds = seconds,
        .ms = millis,
    };
}

fn getDateMs(this_value: Value) ?f64 {
    const obj = heap_mod.valueAsPlainObject(this_value) orelse return null;
    return obj.getDateMs();
}

/// §21.4.4.X — every Date.prototype getter requires a brand-
/// checked Date receiver. Calling on a plain object / array /
/// non-Date wrapper throws TypeError per spec.
fn requireDateMs(realm: *Realm, this_value: Value) NativeError!f64 {
    const obj = heap_mod.valueAsPlainObject(this_value) orelse return throwTypeError(realm, "Date.prototype method called on non-Date");
    return obj.getDateMs() orelse return throwTypeError(realm, "Date.prototype method called on non-Date");
}

fn dateGetTime(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    const ms = try requireDateMs(realm, this_value);
    return Value.fromDouble(ms);
}

fn dateToString(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    const ms = getDateMs(this_value) orelse return throwTypeError(realm, "Date.prototype.toString called on non-Date");
    return formatDateString(realm, ms);
}

/// §21.4.4.43 Date.prototype.toUTCString. Format
/// `Day, DD Mon YYYY HH:mm:ss GMT` per the RFC 7231 IMF-fixdate
/// production. (Used as the date format in HTTP headers.)
fn dateToUTCString(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    const ms = getDateMs(this_value) orelse return throwTypeError(realm, "Date.prototype.toUTCString called on non-Date");
    if (std.math.isNan(ms)) {
        const s = realm.heap.allocateString("Invalid Date") catch return error.OutOfMemory;
        return Value.fromString(s);
    }
    const p = dateParts(ms);
    var buf: [80]u8 = undefined;
    var year_buf: [16]u8 = undefined;
    const year_str = formatYear(&year_buf, p.year);
    const text = std.fmt.bufPrint(&buf, "{s}, {d:0>2} {s} {s} {d:0>2}:{d:0>2}:{d:0>2} GMT", .{
        weekdayName(p.weekday), u(p.day), monthName(p.month), year_str, u(p.hours), u(p.minutes), u(p.seconds),
    }) catch return throwRangeError(realm, "Invalid Date");
    const s = realm.heap.allocateString(text) catch return error.OutOfMemory;
    return Value.fromString(s);
}

/// §21.4.4.35 Date.prototype.toDateString. Format
/// `Day Mon DD YYYY` (locale-fixed English per spec).
fn dateToDateString(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    const ms = getDateMs(this_value) orelse return throwTypeError(realm, "Date.prototype.toDateString called on non-Date");
    if (std.math.isNan(ms)) {
        const s = realm.heap.allocateString("Invalid Date") catch return error.OutOfMemory;
        return Value.fromString(s);
    }
    const p = dateParts(ms);
    var buf: [48]u8 = undefined;
    var year_buf: [16]u8 = undefined;
    const year_str = formatYear(&year_buf, p.year);
    const text = std.fmt.bufPrint(&buf, "{s} {s} {d:0>2} {s}", .{
        weekdayName(p.weekday), monthName(p.month), u(p.day), year_str,
    }) catch return throwRangeError(realm, "Invalid Date");
    const s = realm.heap.allocateString(text) catch return error.OutOfMemory;
    return Value.fromString(s);
}

/// §21.4.4.42 Date.prototype.toTimeString. Format
/// `HH:mm:ss GMT+0000 (Coordinated Universal Time)`.
fn dateToTimeString(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    const ms = getDateMs(this_value) orelse return throwTypeError(realm, "Date.prototype.toTimeString called on non-Date");
    if (std.math.isNan(ms)) {
        const s = realm.heap.allocateString("Invalid Date") catch return error.OutOfMemory;
        return Value.fromString(s);
    }
    const p = dateParts(ms);
    var buf: [64]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, "{d:0>2}:{d:0>2}:{d:0>2} GMT+0000 (Coordinated Universal Time)", .{
        u(p.hours), u(p.minutes), u(p.seconds),
    }) catch return throwRangeError(realm, "Invalid Date");
    const s = realm.heap.allocateString(text) catch return error.OutOfMemory;
    return Value.fromString(s);
}

/// Convert a non-negative i64 to u64 for `{d:0>N}` formatting.
/// Zig 0.17's signed formatter prints a leading `+` for
/// non-negative values, which corrupts every fixed-width Date
/// component ("+1970-+1-+1T+0..."). The Date parts (year, month,
/// day, hours, minutes, seconds, ms) are all non-negative for
/// any in-range Date, so casting to unsigned is safe.
fn u(v: i64) u64 {
    return @intCast(if (v < 0) 0 else v);
}

/// Format a year for the toString / toUTCString / toDateString
/// outputs. Per §21.4.4.41 step 8 (YearFromTime), negative years
/// render as `-YYYY[YY]` (minimum 4 digits, sign prefix). Positive
/// years zero-pad to at least 4 digits. The fixture
/// `prototype/toString/negative-year.js` expects "-0001",
/// "-12345", etc.
fn formatYear(buf: []u8, year: i64) []const u8 {
    if (year < 0) {
        const abs_year = @as(u64, @intCast(-year));
        return std.fmt.bufPrint(buf, "-{d:0>4}", .{abs_year}) catch buf[0..0];
    }
    return std.fmt.bufPrint(buf, "{d:0>4}", .{@as(u64, @intCast(year))}) catch buf[0..0];
}

const day_names = [_][]const u8{ "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" };
const month_names = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };

fn weekdayName(w: i64) []const u8 {
    if (w < 0 or w > 6) return "???";
    return day_names[@intCast(w)];
}
fn monthName(m: i64) []const u8 {
    if (m < 0 or m > 11) return "???";
    return month_names[@intCast(m)];
}

fn dateToISOString(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    const ms = getDateMs(this_value) orelse return throwTypeError(realm, "Date.prototype.toISOString called on non-Date");
    if (!std.math.isFinite(ms)) return throwRangeError(realm, "Invalid Date");
    // §21.4.1.31 TimeClip — the spec range is ±8.64e15. Anything
    // outside (even between 8.64e15 and 8.64e15+0.999) is invalid.
    if (@abs(ms) > 8.64e15) return throwRangeError(realm, "Invalid Date");
    const p = dateParts(ms);
    var buf: [40]u8 = undefined;
    // §21.4.4.36 step 4 — year sign-prefix for extended years.
    // Years outside [0, 9999] render as `±YYYYYY` (six digits +
    // sign). The standard range renders as `YYYY` (four digits).
    const text = if (p.year >= 0 and p.year <= 9999)
        std.fmt.bufPrint(&buf, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}Z", .{
            @as(u64, @intCast(p.year)), u(p.month + 1), u(p.day), u(p.hours), u(p.minutes), u(p.seconds), u(p.ms),
        }) catch return throwRangeError(realm, "Invalid Date")
    else if (p.year < 0)
        std.fmt.bufPrint(&buf, "-{d:0>6}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}Z", .{
            @as(u64, @intCast(-p.year)), u(p.month + 1), u(p.day), u(p.hours), u(p.minutes), u(p.seconds), u(p.ms),
        }) catch return throwRangeError(realm, "Invalid Date")
    else
        std.fmt.bufPrint(&buf, "+{d:0>6}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}Z", .{
            @as(u64, @intCast(p.year)), u(p.month + 1), u(p.day), u(p.hours), u(p.minutes), u(p.seconds), u(p.ms),
        }) catch return throwRangeError(realm, "Invalid Date");
    const s = realm.heap.allocateString(text) catch return error.OutOfMemory;
    return Value.fromString(s);
}

/// §21.4.4.37 Date.prototype.toJSON ( key )
///
/// 1. Let O be ? ToObject(this value).
/// 2. Let tv be ? ToPrimitive(O, Number).
/// 3. If Type(tv) is Number and tv is not finite, return null.
/// 4. Return ? Invoke(O, "toISOString").
///
/// Note: this dispatches through the receiver's *own* toISOString
/// (Invoke = `Call(Get(O, P), O, args)`); the global Date.prototype.
/// toISOString brand check would throw on a plain object, but the
/// fixture installs its own toISOString.
fn dateToJSON(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    // Step 1 — ToObject (throws TypeError on null/undefined).
    const obj = try intrinsics.toObjectThis(realm, this_value);
    // Step 2 — ToPrimitive(O, hint Number). Returns whatever the
    // user's @@toPrimitive / valueOf / toString cooked up. We use
    // a fresh tagged-object value so any rewrite during ToObject
    // (boxing a Symbol primitive into a wrapper) is visible to the
    // ToPrimitive trap lookup.
    const o_val = heap_mod.taggedObject(obj);
    const tv = try intrinsics.toPrimitive(realm, o_val, .number);
    // Step 3 — non-finite Number tv ⇒ null.
    if (tv.isInt32()) {
        // Int32 is always finite.
    } else if (tv.isDouble()) {
        const d = tv.asDouble();
        if (!std.math.isFinite(d)) return Value.null_;
    }
    // Step 4 — Invoke(O, "toISOString"). Spec uses `Invoke`, which
    // walks the prototype chain and calls the resolved function
    // with `O` as the this-value.
    const iso_v = intrinsics.getPropertyChain(realm, obj, "toISOString") catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.NativeThrew,
    };
    const iso_fn = heap_mod.valueAsFunction(iso_v) orelse
        return throwTypeError(realm, "toISOString is not callable");
    const interp = @import("../lantern/interpreter.zig");
    const outcome = interp.callJSFunction(realm.allocator, realm, iso_fn, o_val, &[_]Value{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.NativeThrew,
    };
    return switch (outcome) {
        .value, .yielded => |v| v,
        .thrown => |ex| blk: {
            realm.pending_exception = ex;
            break :blk error.NativeThrew;
        },
    };
}

fn dateGetFullYear(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    const ms = try requireDateMs(realm, this_value);
    if (std.math.isNan(ms)) return Value.fromDouble(std.math.nan(f64));
    return numberFromI64(dateParts(ms).year);
}
fn dateGetMonth(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    const ms = try requireDateMs(realm, this_value);
    if (std.math.isNan(ms)) return Value.fromDouble(std.math.nan(f64));
    return numberFromI64(dateParts(ms).month);
}
fn dateGetDate(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    const ms = try requireDateMs(realm, this_value);
    if (std.math.isNan(ms)) return Value.fromDouble(std.math.nan(f64));
    return numberFromI64(dateParts(ms).day);
}
fn dateGetDay(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    const ms = try requireDateMs(realm, this_value);
    if (std.math.isNan(ms)) return Value.fromDouble(std.math.nan(f64));
    return numberFromI64(dateParts(ms).weekday);
}
fn dateGetHours(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    const ms = try requireDateMs(realm, this_value);
    if (std.math.isNan(ms)) return Value.fromDouble(std.math.nan(f64));
    return numberFromI64(dateParts(ms).hours);
}
fn dateGetMinutes(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    const ms = try requireDateMs(realm, this_value);
    if (std.math.isNan(ms)) return Value.fromDouble(std.math.nan(f64));
    return numberFromI64(dateParts(ms).minutes);
}
fn dateGetSeconds(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    const ms = try requireDateMs(realm, this_value);
    if (std.math.isNan(ms)) return Value.fromDouble(std.math.nan(f64));
    return numberFromI64(dateParts(ms).seconds);
}
fn dateGetMs(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    const ms = try requireDateMs(realm, this_value);
    if (std.math.isNan(ms)) return Value.fromDouble(std.math.nan(f64));
    return numberFromI64(dateParts(ms).ms);
}
fn dateGetTzOffset(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    const ms = try requireDateMs(realm, this_value);
    // §21.4.4.7 — if t is NaN, return NaN. UTC-only engine
    // otherwise returns +0 (no local offset to report).
    if (std.math.isNan(ms)) return Value.fromDouble(std.math.nan(f64));
    return Value.fromInt32(0);
}

/// Date.prototype.toTemporalInstant ( ) — the Temporal proposal's
/// bridge from a legacy Date: `ns = NumberToBigInt([[DateValue]]) ×
/// 10^6`. An invalid (NaN) Date throws RangeError. A finite Date value
/// is always integral and within ±8.64×10^15 ms, so the resulting
/// epoch ns is always inside the representable Instant range.
fn dateToTemporalInstant(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    const ms = try requireDateMs(realm, this_value);
    if (std.math.isNan(ms)) {
        return throwRangeError(realm, "Cannot convert an invalid Date to a Temporal.Instant");
    }
    const ns: i128 = @as(i128, @intFromFloat(ms)) * 1_000_000;
    return temporal_builtin.createTemporalInstant(realm, ns);
}
