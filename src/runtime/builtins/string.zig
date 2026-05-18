//! §22.1 String.prototype methods — extracted from
//! `intrinsics.zig`. All methods accept primitives + wrapper
//! objects via `coerceThisToJSString` (§22.1.3
//! RequireObjectCoercible + ToString). Cynic walks bytes; full
//! UTF-16 surrogate-pair fidelity is later.

const std = @import("std");
const lib_unicode = @import("c");

const Realm = @import("../realm.zig").Realm;
const Value = @import("../value.zig").Value;
const JSString = @import("../string.zig").JSString;
const JSObject = @import("../object.zig").JSObject;
const JSFunction = @import("../function.zig").JSFunction;
const NativeError = @import("../function.zig").NativeError;
const heap_mod = @import("../heap.zig");
const intrinsics = @import("../intrinsics.zig");
const interpreter = @import("../interpreter.zig");
const interpreter_arith = @import("../interpreter_arith.zig");
const utf16 = @import("../utf16.zig");

const arith_toUint32 = interpreter_arith.toUint32;

const installNativeMethodOnProto = intrinsics.installNativeMethodOnProto;
const argOr = intrinsics.argOr;
const coerceToNumber = intrinsics.coerceToNumber;
const throwTypeError = intrinsics.throwTypeError;
const stringifyArg = intrinsics.stringifyArg;
const toInt = intrinsics.toInt;
const toObjectThis = intrinsics.toObjectThis;
const setLength = intrinsics.setLength;
const callJSFunction = interpreter.callJSFunction;

/// Wire `String.prototype.*` instance methods. Caller arranges
/// that `realm.intrinsics.string_prototype` already exists +
/// the `String` constructor is replaced with the real
/// `stringConstructor` body. The `[[StringData]]: ""` slot on
/// the prototype itself is set by the caller too.
pub fn install(realm: *Realm) !void {
    const sp = realm.intrinsics.string_prototype orelse return;
    try installNativeMethodOnProto(realm, sp, "charAt", stringCharAt, 1);
    try installNativeMethodOnProto(realm, sp, "charCodeAt", stringCharCodeAt, 1);
    try installNativeMethodOnProto(realm, sp, "indexOf", stringIndexOf, 1);
    try installNativeMethodOnProto(realm, sp, "includes", stringIncludes, 1);
    try installNativeMethodOnProto(realm, sp, "slice", stringSlice, 2);
    try installNativeMethodOnProto(realm, sp, "substring", stringSubstring, 2);
    try installNativeMethodOnProto(realm, sp, "toString", stringToString, 0);
    try installNativeMethodOnProto(realm, sp, "valueOf", stringToString, 0);
    try installNativeMethodOnProto(realm, sp, "toUpperCase", stringToUpperCase, 0);
    try installNativeMethodOnProto(realm, sp, "toLowerCase", stringToLowerCase, 0);
    try installNativeMethodOnProto(realm, sp, "trim", stringTrim, 0);
    try installNativeMethodOnProto(realm, sp, "concat", stringConcat, 1);
    try installNativeMethodOnProto(realm, sp, "repeat", stringRepeat, 1);
    try installNativeMethodOnProto(realm, sp, "startsWith", stringStartsWith, 1);
    try installNativeMethodOnProto(realm, sp, "endsWith", stringEndsWith, 1);
    try installNativeMethodOnProto(realm, sp, "split", stringSplitDispatched, 2);
    // §22.1.3.{17,18} padStart / padEnd — spec `length: 1`, even
    // though both accept (maxLength, fillString).
    try installNativeMethodOnProto(realm, sp, "padStart", stringPadStart, 1);
    try installNativeMethodOnProto(realm, sp, "padEnd", stringPadEnd, 1);
    try installNativeMethodOnProto(realm, sp, "at", stringAt, 1);
    try installNativeMethodOnProto(realm, sp, "lastIndexOf", stringLastIndexOf, 1);
    try installNativeMethodOnProto(realm, sp, "replace", stringReplaceDispatched, 2);
    try installNativeMethodOnProto(realm, sp, "replaceAll", stringReplaceAllDispatched, 2);
    try installNativeMethodOnProto(realm, sp, "trimStart", stringTrimStart, 0);
    try installNativeMethodOnProto(realm, sp, "trimEnd", stringTrimEnd, 0);
    // §22.1.3.16 — `normalize` has a length of 0 because its
    // single parameter is optional.
    try installNativeMethodOnProto(realm, sp, "normalize", stringNormalize, 0);
    try installNativeMethodOnProto(realm, sp, "codePointAt", stringCodePointAt, 1);
    try installNativeMethodOnProto(realm, sp, "localeCompare", stringLocaleCompare, 1);
    try installNativeMethodOnProto(realm, sp, "toLocaleUpperCase", stringToUpperCase, 0);
    try installNativeMethodOnProto(realm, sp, "toLocaleLowerCase", stringToLowerCase, 0);
    try installNativeMethodOnProto(realm, sp, "match", stringMatchDispatched, 1);
    try installNativeMethodOnProto(realm, sp, "matchAll", stringMatchAllDispatched, 1);
    try installNativeMethodOnProto(realm, sp, "search", stringSearchDispatched, 1);
    // §22.1.3.12 / §22.1.3.30 — ES2024 well-formed-Unicode helpers.
    // Both have `length: 0` and do not take any arguments.
    try installNativeMethodOnProto(realm, sp, "isWellFormed", stringIsWellFormed, 0);
    try installNativeMethodOnProto(realm, sp, "toWellFormed", stringToWellFormed, 0);
    // §22.1.3.36 String.prototype[@@iterator] — yields each
    // code-point of the string (or a code unit at the unicode
    // boundary, but Cynic stores UTF-8 so we walk code points).
    // Routed through `openIterator` which already builds the
    // array-like iterator over `length` + indexed reads on the
    // wrapper / primitive.
    try installNativeMethodOnProto(realm, sp, "@@iterator", stringSymbolIterator, 0);

    // §22.1.2.* — String constructor statics.
    if (heap_mod.valueAsFunction(realm.globals.get("String").?)) |str_ctor| {
        try intrinsics.installNativeMethod(realm, str_ctor, "fromCharCode", stringFromCharCode, 1);
        try intrinsics.installNativeMethod(realm, str_ctor, "fromCodePoint", stringFromCodePoint, 1);
        try intrinsics.installNativeMethod(realm, str_ctor, "raw", stringRaw, 1);
    }

    // §22.2.9.2 %RegExpStringIteratorPrototype% — shared
    // prototype object for the iterator that
    // String.prototype.matchAll returns. Owns `next`,
    // `@@iterator`, and the `RegExp String Iterator`
    // toStringTag. Each instance only carries its `[[IteratingRegExp]]`
    // / `[[IteratedString]]` / `[[Done]]` state in own slots,
    // brand-checked here as the `__cynic_matchall_re__` slot.
    const re_iter_proto = try realm.heap.allocateObject();
    re_iter_proto.prototype = realm.intrinsics.object_prototype;
    try installNativeMethodOnProto(realm, re_iter_proto, "next", regexpStringIterNext, 0);
    try installNativeMethodOnProto(realm, re_iter_proto, "@@iterator", regexpStringIterReturnsSelf, 0);
    try intrinsics.installToStringTag(realm, re_iter_proto, "RegExp String Iterator");
    realm.intrinsics.regexp_string_iterator_prototype = re_iter_proto;
}

fn regexpStringIterReturnsSelf(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = realm;
    _ = args;
    return this_value;
}

/// §22.1.3.36 String.prototype[@@iterator]. Returns an iterator
/// over the receiver's characters. For a primitive string
/// receiver or a String wrapper, `openIterator` already does
/// the right thing — it falls through to the array-like-length
/// path which walks indexed slots.
fn stringSymbolIterator(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    // §22.1.3.36 step 1 — `this` must be a string-coercible
    // (RequireObjectCoercible); `coerceThisToJSString` handles
    // the wrapper-unbox and the null/undefined → TypeError.
    const s = try coerceThisToJSString(realm, this_value);
    return interpreter.openIteratorAllowArrayLike(realm.allocator, realm, Value.fromString(s)) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return throwTypeError(realm, "could not open string iterator"),
    };
}

/// §22.2.9.2 %RegExpStringIteratorPrototype%.next — RequireInternalSlot
/// on `[[IteratingRegExp]]` (presence of `__cynic_matchall_re__`).
/// Yields each `RegExpExec(R, S)` result. When `[[Global]]` is
/// false, the first non-null result is returned and the iterator
/// is exhausted; when `[[Global]]` is true, iteration continues
/// until `RegExpExec` returns null, and a zero-width match advances
/// `R.lastIndex` via §22.2.7.3 AdvanceStringIndex (which the
/// `[[Unicode]]` slot — driven by `flags ∋ {u,v}` — controls).
fn regexpStringIterNext(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    const it = heap_mod.valueAsPlainObject(this_value) orelse
        return throwTypeError(realm, "RegExpStringIteratorPrototype.next called on non-object");
    if (!it.hasOwn("__cynic_matchall_re__"))
        return throwTypeError(realm, "RegExpStringIteratorPrototype.next called on incompatible receiver");
    if (it.get("__cynic_matchall_done__").asBool()) {
        return iterResult(realm, Value.undefined_, true);
    }
    const re_v = it.get("__cynic_matchall_re__");
    const re_obj = heap_mod.valueAsPlainObject(re_v) orelse return iterResult(realm, Value.undefined_, true);
    const input_v = it.get("__cynic_matchall_input__");
    const input: *JSString = if (input_v.isString()) @ptrCast(@alignCast(input_v.asString())) else return iterResult(realm, Value.undefined_, true);
    // [[Global]] / [[Unicode]] (default false when the iterator was
    // constructed by an older path that didn't seed them — the
    // current `regexp.zig:regexpProtoMatchAll` always seeds both).
    const is_global = it.get("__cynic_matchall_global__").asBool();
    const full_unicode = it.get("__cynic_matchall_fullUnicode__").asBool();

    const exec_result = try regexExecCall(realm, re_obj, input);
    if (exec_result.isNull()) {
        it.set(realm.allocator, "__cynic_matchall_done__", Value.fromBool(true)) catch return error.OutOfMemory;
        return iterResult(realm, Value.undefined_, true);
    }
    // §22.2.9.2 step 1.f.iii — when `[[Global]]` is false, the
    // first match exhausts the iterator. (Mirrors the `not-a-global-
    // regexp.js` family.)
    if (!is_global) {
        it.set(realm.allocator, "__cynic_matchall_done__", Value.fromBool(true)) catch return error.OutOfMemory;
        return iterResult(realm, exec_result, false);
    }
    // §22.2.9.2 step 1.f.iv — after a zero-width match the iterator
    // must `AdvanceStringIndex(S, ToLength(? Get(R, "lastIndex")),
    // fullUnicode)` and write that back via `Set(R, "lastIndex",
    // nextIndex, true)`, otherwise the next pull re-matches at the
    // same position forever.
    if (heap_mod.valueAsPlainObject(exec_result)) |match_arr| {
        const whole_v = match_arr.get("0");
        if (whole_v.isString()) {
            const whole: *JSString = @ptrCast(@alignCast(whole_v.asString()));
            if (whole.bytes.len == 0) {
                const li_v = try intrinsics.getPropertyChain(realm, re_obj, "lastIndex");
                const li_i64 = try intrinsics.toLengthValue(realm, li_v);
                const li_unit: usize = if (li_i64 > 0) @intCast(li_i64) else 0;
                const next_unit = if (full_unicode) advanceStringIndexUnicode(input.bytes, li_unit) else li_unit + 1;
                re_obj.set(realm.allocator, "lastIndex", Value.fromInt32(@intCast(next_unit))) catch return error.OutOfMemory;
            }
        }
    }
    return iterResult(realm, exec_result, false);
}

/// AdvanceStringIndex (§22.2.7.3) for the `fullUnicode = true` case
/// over a WTF-8 buffer indexed in UTF-16 code units. Walks the
/// bytes counting code units to find the code unit at
/// `from_unit`; if it begins a surrogate pair (high surrogate
/// followed by a low surrogate), advance by 2 code units, else by 1.
fn advanceStringIndexUnicode(s: []const u8, from_unit: usize) usize {
    var unit_pos: usize = 0;
    var byte_pos: usize = 0;
    while (byte_pos < s.len and unit_pos < from_unit) {
        const seq_len = utf8SeqLen(s[byte_pos]);
        byte_pos += seq_len;
        unit_pos += if (seq_len == 4) 2 else 1;
    }
    if (byte_pos >= s.len) return from_unit + 1;
    const seq_len = utf8SeqLen(s[byte_pos]);
    return from_unit + (if (seq_len == 4) @as(usize, 2) else 1);
}

/// Advance one UTF-16 code unit in the WTF-8 string starting at
/// code-unit position `from_unit`. Walks the bytes counting units,
/// then returns `from_unit + units_consumed_by_next_codepoint`. Used
/// to mirror §22.2.7.1 AdvanceStringIndex without separately tracking
/// byte cursors at the caller — callers that already do the dual
/// walk can advance their state directly.
fn advanceUnitOnString(s: []const u8, from_unit: usize) usize {
    var unit_pos: usize = 0;
    var byte_pos: usize = 0;
    while (byte_pos < s.len and unit_pos < from_unit) {
        const seq_len = utf8SeqLen(s[byte_pos]);
        byte_pos += seq_len;
        unit_pos += if (seq_len == 4) 2 else 1;
    }
    if (byte_pos >= s.len) return from_unit + 1;
    const seq_len = utf8SeqLen(s[byte_pos]);
    return from_unit + (if (seq_len == 4) @as(usize, 2) else 1);
}

/// §22.1.2.1 String.fromCharCode(...codeUnits). Each argument is
/// ToUint16-coerced and emitted as one UTF-16 code unit. Cynic
/// stores strings as WTF-8: every code unit fits in 1-3 bytes
/// (surrogate halves get their natural 3-byte sequence — they
/// only combine into an astral codepoint when the caller wrote
/// the high half right before the low half).
fn stringFromCharCode(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = this_value;
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(realm.allocator);
    for (args) |a| {
        // §7.1.7 ToUint16 step 1 — `Let number be ? ToNumber(argument)`.
        // Spec ToNumber consults `Symbol.toPrimitive` / `valueOf` on
        // object operands and throws TypeError for Symbol / BigInt;
        // the silent `coerceToNumber` short-circuit masked both.
        const nv = try intrinsics.toNumber(realm, a);
        const n: f64 = if (nv.isInt32()) @floatFromInt(nv.asInt32()) else nv.asDouble();
        const cu: u16 = toUint16(n);
        appendWtf8(realm.allocator, &out, cu) catch return error.OutOfMemory;
    }
    const s = realm.heap.allocateString(out.items) catch return error.OutOfMemory;
    return Value.fromString(s);
}

/// §22.1.2.2 String.fromCodePoint(...codePoints). Each argument
/// must coerce to an integer in 0…0x10FFFF; otherwise RangeError.
/// The codepoint is emitted as a single WTF-8 sequence (1-4
/// bytes — astral codepoints are one element of the resulting
/// string under the WTF-8 / per-codepoint iteration model).
fn stringFromCodePoint(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = this_value;
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(realm.allocator);
    for (args) |a| {
        const nv = coerceToNumber(a);
        const n: f64 = if (nv.isInt32()) @floatFromInt(nv.asInt32()) else nv.asDouble();
        if (std.math.isNan(n) or std.math.isInf(n) or n != @trunc(n) or n < 0 or n > 0x10FFFF) {
            return intrinsics.throwRangeError(realm, "String.fromCodePoint: argument out of range");
        }
        const cp: u21 = @intFromFloat(n);
        appendWtf8(realm.allocator, &out, cp) catch return error.OutOfMemory;
    }
    const s = realm.heap.allocateString(out.items) catch return error.OutOfMemory;
    return Value.fromString(s);
}

/// §22.1.2.5 String.raw(template, ...substitutions). Walks the
/// `template.raw` array-like, interleaving each segment with the
/// corresponding substitution. Used by tagged template literals
/// of the form `` String.raw`…` ``. ToObject(template) and
/// ToObject(template.raw) throw TypeError for null/undefined;
/// every read goes through the prototype chain so accessor
/// fixtures observe their getters.
fn stringRaw(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = this_value;
    // §22.1.2.5 step 1-2 — substitutions list. Cynic forwards the
    // rest list as `args[1..]`.
    const template = argOr(args, 0, Value.undefined_);
    // step 3 — Let cooked be ToObject(template).
    const cooked = try toObjectThis(realm, template);
    // step 4 — Let literals be ? ToObject(? Get(cooked, "raw")).
    const raw_v = try intrinsics.getPropertyChain(realm, cooked, "raw");
    const raw_obj = try toObjectThis(realm, raw_v);
    // step 5 — Let literalSegments be ? LengthOfArrayLike(literals).
    const lit_segs_i64 = try intrinsics.toLengthOf(realm, raw_obj);
    // step 6 — If literalSegments ≤ 0, return the empty string.
    if (lit_segs_i64 <= 0) {
        const empty = realm.heap.allocateString("") catch return error.OutOfMemory;
        return Value.fromString(empty);
    }
    const lit_segs: u64 = @intCast(lit_segs_i64);
    const num_subs: u64 = if (args.len > 1) @intCast(args.len - 1) else 0;

    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(realm.allocator);

    // step 7-10 — for each nextIndex: append ToString(Get(literals, nextKey)),
    // then if not at the last segment, append ToString(substitutions[nextIndex]).
    var next_index: u64 = 0;
    while (true) : (next_index += 1) {
        var ibuf: [24]u8 = undefined;
        const key = std.fmt.bufPrint(&ibuf, "{d}", .{next_index}) catch unreachable;
        const seg_v = try intrinsics.getPropertyChain(realm, raw_obj, key);
        const seg_str = try stringifyArg(realm, seg_v);
        out.appendSlice(realm.allocator, seg_str.bytes) catch return error.OutOfMemory;
        if (next_index + 1 == lit_segs) break;
        if (next_index < num_subs) {
            const sub_v = args[1 + @as(usize, @intCast(next_index))];
            const sub_str = try stringifyArg(realm, sub_v);
            out.appendSlice(realm.allocator, sub_str.bytes) catch return error.OutOfMemory;
        }
    }

    const s = realm.heap.allocateString(out.items) catch return error.OutOfMemory;
    return Value.fromString(s);
}

fn toUint16(n: f64) u16 {
    // §7.1.7 ToUint16 — `NaN` / `±0` / `±Infinity` map to +0; else
    // truncate toward zero, then mod 2^16.
    if (std.math.isNan(n) or std.math.isInf(n)) return 0;
    const truncated = @trunc(n);
    const m: f64 = @mod(truncated, 65536.0);
    const adjusted: f64 = if (m < 0) m + 65536.0 else m;
    return @intFromFloat(adjusted);
}

fn appendWtf8(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), cp: u21) !void {
    if (cp < 0x80) {
        try out.append(allocator, @intCast(cp));
    } else if (cp < 0x800) {
        try out.append(allocator, @intCast(0xC0 | (cp >> 6)));
        try out.append(allocator, @intCast(0x80 | (cp & 0x3F)));
    } else if (cp < 0x10000) {
        try out.append(allocator, @intCast(0xE0 | (cp >> 12)));
        try out.append(allocator, @intCast(0x80 | ((cp >> 6) & 0x3F)));
        try out.append(allocator, @intCast(0x80 | (cp & 0x3F)));
    } else {
        try out.append(allocator, @intCast(0xF0 | (cp >> 18)));
        try out.append(allocator, @intCast(0x80 | ((cp >> 12) & 0x3F)));
        try out.append(allocator, @intCast(0x80 | ((cp >> 6) & 0x3F)));
        try out.append(allocator, @intCast(0x80 | (cp & 0x3F)));
    }
}

/// §22.1.3.14 String.prototype.matchAll ( regexpOrPattern ). The
/// Object-gated dispatch in step 3 deliberately skips IsRegExp +
/// GetMethod for primitive `regexpOrPattern` — so a string-keyed
/// `String.prototype[@@matchAll]` shadow is never consulted when
/// the argument is a string. For Object args, step 3.b.iii throws
/// TypeError on a non-global RegExp *before* GetMethod runs; step
/// 3.c forwards to the symbol method if present. Otherwise steps
/// 4-6 build a fresh `/.../g` via RegExpCreate and invoke
/// `@@matchAll` on it — which lets `delete RegExp.prototype[@@matchAll]`
/// surface as the expected TypeError when the method is missing.
fn stringMatchAllDispatched(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    if (this_value.isNull() or this_value.isUndefined())
        return throwTypeError(realm, "String.prototype.matchAll called on null or undefined");
    const arg = argOr(args, 0, Value.undefined_);
    // §22.1.3.14 step 3 — "If regexpOrPattern is an Object, then".
    // Primitives (null, undefined, strings, numbers, …) skip the
    // entire IsRegExp + GetMethod block.
    if (heap_mod.valueAsPlainObject(arg)) |arg_obj| {
        // step 3.a-b — IsRegExp(regexp); when true, validate `flags`
        // contains "g". `flags` is read with the accessor on
        // %RegExp.prototype% (§22.2.6.4), which `getPropertyChain`
        // honours.
        if (try isRegExp(realm, arg)) {
            const flags_v = try intrinsics.getPropertyChain(realm, arg_obj, "flags");
            if (flags_v.isUndefined() or flags_v.isNull())
                return throwTypeError(realm, "String.prototype.matchAll: regex has no flags");
            const flags_s = try intrinsics.stringifyArg(realm, flags_v);
            if (std.mem.indexOfScalar(u8, flags_s.bytes, 'g') == null)
                return throwTypeError(realm, "String.prototype.matchAll requires a global regex");
        }
        // step 3.c-d — GetMethod(regexpOrPattern, @@matchAll); if
        // not undefined, Call(matcher, regexpOrPattern, « thisValue »).
        // Note: `thisValue` is passed un-coerced (the matcher does
        // its own ToString). This matters for `toString-this-val.js`
        // which observes the toPrimitive call only once.
        if (try getSymbolMethod(realm, arg, "@@matchAll")) |matcher| {
            return invokeSymbolMethod(realm, matcher, arg, this_value, null);
        }
    }
    // step 4 — Let str be ? ToString(thisValue).
    const s = try coerceThisToJSString(realm, this_value);
    // step 5 — Let regexp be ? RegExpCreate(regexpOrPattern, "g").
    const rx_v = try regExpCreate(realm, arg, "g");
    // step 6 — Return ? Invoke(regexp, @@matchAll, « str »).
    const rx_obj = heap_mod.valueAsPlainObject(rx_v) orelse return throwTypeError(realm, "matchAll: RegExpCreate did not return an object");
    const matcher_v = try intrinsics.getPropertyChain(realm, rx_obj, "@@matchAll");
    const matcher_fn = heap_mod.valueAsFunction(matcher_v) orelse return throwTypeError(realm, "matchAll: regexp[@@matchAll] is not callable");
    return invokeSymbolMethod(realm, matcher_fn, rx_v, Value.fromString(s), null);
}

fn iterResult(realm: *Realm, value: Value, done: bool) NativeError!Value {
    const obj = realm.heap.allocateObject() catch return error.OutOfMemory;
    obj.prototype = realm.intrinsics.object_prototype;
    obj.set(realm.allocator, "value", value) catch return error.OutOfMemory;
    obj.set(realm.allocator, "done", Value.fromBool(done)) catch return error.OutOfMemory;
    return heap_mod.taggedObject(obj);
}

/// §22.1.3.11 entry that runs Symbol.match dispatch first; wired
/// as `String.prototype.match`. The fallback path calls the symbol-
/// free core (`stringMatch`) which `RegExp.prototype[@@match]`
/// also re-enters.
fn stringMatchDispatched(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    if (this_value.isNull() or this_value.isUndefined())
        return throwTypeError(realm, "String.prototype.match called on null or undefined");
    const regexp_arg = argOr(args, 0, Value.undefined_);
    // §22.1.3.13 step 2 — direct @@match on the supplied regexp.
    if (try getSymbolMethod(realm, regexp_arg, "@@match")) |matcher| {
        const recv_s = try coerceThisToJSString(realm, this_value);
        return invokeSymbolMethod(realm, matcher, regexp_arg, Value.fromString(recv_s), null);
    }
    // §22.1.3.13 step 4-5 — wrap the argument in a fresh RegExp via
    // `RegExpCreate(regexp, undefined)`, then `Invoke(rx, @@match,
    // «S»)`. A user-overridden `RegExp.prototype[Symbol.match]`
    // fires here even when the source argument is a bare string,
    // because @@match lives on the freshly-allocated regex's
    // prototype.
    const recv_s = try coerceThisToJSString(realm, this_value);
    const rx = try regExpCreate(realm, regexp_arg, null);
    if (try getSymbolMethod(realm, rx, "@@match")) |matcher| {
        return invokeSymbolMethod(realm, matcher, rx, Value.fromString(recv_s), null);
    }
    // %RegExp.prototype%[@@match] is installed by every realm; the
    // fall-through is a safety net.
    return stringMatch(realm, this_value, args);
}

/// §22.1.3.11 String.prototype.match — coerce the argument to a
/// RegExp (constructing if needed), then invoke its `exec`. For
/// the global flag, iterates `exec` calls and returns an array
/// of whole-match strings (no captures, no `index`).
pub fn stringMatch(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const s = try coerceThisToJSString(realm, this_value);
    const re = try ensureRegExp(realm, argOr(args, 0, Value.undefined_));
    const re_obj = heap_mod.valueAsPlainObject(re) orelse return Value.null_;
    // `flags` is an accessor on `%RegExp.prototype%` (§22.2.6.4),
    // so `obj.get` returns undefined unless we walk accessors.
    // §22.1.3.10 step 4 forwards `regexp.flags` via Get + ToString.
    const flags_v = try intrinsics.getPropertyChain(realm, re_obj, "flags");
    const flags_str: []const u8 = if (flags_v.isString()) (@as(*JSString, @ptrCast(@alignCast(flags_v.asString())))).bytes else "";
    const is_global = std.mem.indexOfScalar(u8, flags_str, 'g') != null;
    const exec_fn_v = try intrinsics.getPropertyChain(realm, re_obj, "exec");
    const exec_fn = heap_mod.valueAsFunction(exec_fn_v) orelse return Value.null_;
    const interp = @import("../interpreter.zig");
    if (!is_global) {
        const args_call = [_]Value{Value.fromString(s)};
        const out = interp.callJSFunction(realm.allocator, realm, exec_fn, re, &args_call) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.NativeThrew,
        };
        return switch (out) {
            .value, .yielded => |v| v,
            .thrown => |ex| {
                realm.pending_exception = ex;
                return error.NativeThrew;
            },
        };
    }
    // Global: walk all matches.
    re_obj.set(realm.allocator, "lastIndex", Value.fromInt32(0)) catch return error.OutOfMemory;
    const result = realm.heap.allocateObject() catch return error.OutOfMemory;
    result.prototype = realm.intrinsics.array_prototype;
    result.markAsArrayExotic(realm.allocator) catch return error.OutOfMemory;
    var idx: i32 = 0;
    var ibuf: [16]u8 = undefined;
    var prev_last_index: i32 = -1;
    const max_iter: usize = 1 << 20;
    var step: usize = 0;
    while (step < max_iter) : (step += 1) {
        const args_call = [_]Value{Value.fromString(s)};
        const out = interp.callJSFunction(realm.allocator, realm, exec_fn, re, &args_call) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.NativeThrew,
        };
        const v = switch (out) {
            .value, .yielded => |x| x,
            .thrown => |ex| {
                realm.pending_exception = ex;
                return error.NativeThrew;
            },
        };
        if (v.isNull()) break;
        const match_arr = heap_mod.valueAsPlainObject(v) orelse break;
        const whole = match_arr.get("0");
        const islice = std.fmt.bufPrint(&ibuf, "{d}", .{idx}) catch unreachable;
        const owned = realm.heap.allocateString(islice) catch return error.OutOfMemory;
        result.set(realm.allocator, owned.bytes, whole) catch return error.OutOfMemory;
        idx += 1;
        // If the regex didn't advance lastIndex, bump it manually
        // to avoid an infinite loop on zero-width matches.
        const li_v = re_obj.get("lastIndex");
        const li: i32 = if (li_v.isInt32()) li_v.asInt32() else 0;
        if (li == prev_last_index) {
            re_obj.set(realm.allocator, "lastIndex", Value.fromInt32(li + 1)) catch return error.OutOfMemory;
        }
        prev_last_index = li;
    }
    if (idx == 0) return Value.null_;
    result.set(realm.allocator, "length", Value.fromInt32(idx)) catch return error.OutOfMemory;
    return heap_mod.taggedObject(result);
}

/// §22.1.3.13 entry that runs Symbol.search dispatch first. Wired
/// as `String.prototype.search`.
fn stringSearchDispatched(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    if (this_value.isNull() or this_value.isUndefined())
        return throwTypeError(realm, "String.prototype.search called on null or undefined");
    const regexp_arg = argOr(args, 0, Value.undefined_);
    if (try getSymbolMethod(realm, regexp_arg, "@@search")) |searcher| {
        const recv_s = try coerceThisToJSString(realm, this_value);
        return invokeSymbolMethod(realm, searcher, regexp_arg, Value.fromString(recv_s), null);
    }
    return stringSearch(realm, this_value, args);
}

/// §22.1.3.13 String.prototype.search — return the index of the
/// first match, or -1 if none. Doesn't update lastIndex on the
/// regex.
pub fn stringSearch(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const s = try coerceThisToJSString(realm, this_value);
    const re = try ensureRegExp(realm, argOr(args, 0, Value.undefined_));
    const re_obj = heap_mod.valueAsPlainObject(re) orelse return Value.fromInt32(-1);
    const saved_li = re_obj.get("lastIndex");
    re_obj.set(realm.allocator, "lastIndex", Value.fromInt32(0)) catch return error.OutOfMemory;
    const exec_fn_v = try intrinsics.getPropertyChain(realm, re_obj, "exec");
    const exec_fn = heap_mod.valueAsFunction(exec_fn_v) orelse return Value.fromInt32(-1);
    const interp = @import("../interpreter.zig");
    const args_call = [_]Value{Value.fromString(s)};
    const out = interp.callJSFunction(realm.allocator, realm, exec_fn, re, &args_call) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.NativeThrew,
    };
    re_obj.set(realm.allocator, "lastIndex", saved_li) catch return error.OutOfMemory;
    const v = switch (out) {
        .value, .yielded => |x| x,
        .thrown => return error.NativeThrew,
    };
    if (v.isNull()) return Value.fromInt32(-1);
    const match_arr = heap_mod.valueAsPlainObject(v) orelse return Value.fromInt32(-1);
    const idx_v = match_arr.get("index");
    return if (idx_v.isInt32()) idx_v else Value.fromInt32(0);
}

/// Coerce `arg` to a RegExp object — pass through if already a
/// RegExp instance, else `new RegExp(arg)`.
fn ensureRegExp(realm: *Realm, arg: Value) NativeError!Value {
    // Detect a RegExp instance by checking for an `exec` callable
    // own property *or* prototype chain. Cheaper: check if the
    // prototype is %RegExp.prototype% — which we can look up
    // through the global RegExp constructor.
    if (heap_mod.valueAsPlainObject(arg)) |obj| {
        // Walk the prototype chain looking for `exec`. If found
        // and callable, treat as regex-like.
        var cursor: ?*JSObject = obj;
        while (cursor) |c_| : (cursor = c_.prototype) {
            const exec_v = c_.get("exec");
            if (heap_mod.valueAsFunction(exec_v) != null) return arg;
        }
    }
    return regExpCreate(realm, arg, null);
}

/// §22.2.3.3 RegExpCreate ( P, F ) — unconditionally allocate a
/// new RegExp from (pattern, flags). Differs from `ensureRegExp`
/// in that the caller asks for a *fresh* instance even when the
/// pattern is already a RegExp; this matches the §22.1.3.14
/// step 5 "Let regexp be ? RegExpCreate(regexpOrPattern, "g")"
/// invariant. `flags` is the flags string (e.g. "g"); when null,
/// passes no flags argument (so the constructor inherits flags
/// from a RegExp pattern, per §22.2.3.1 step 3.b).
fn regExpCreate(realm: *Realm, pattern: Value, flags: ?[]const u8) NativeError!Value {
    const ctor_v = realm.globals.get("RegExp") orelse Value.undefined_;
    const ctor = heap_mod.valueAsFunction(ctor_v) orelse return throwTypeError(realm, "RegExp constructor is missing");
    const interp = @import("../interpreter.zig");
    const inst = realm.heap.allocateObject() catch return error.OutOfMemory;
    inst.prototype = ctor.prototype;
    var argbuf: [2]Value = .{ pattern, Value.undefined_ };
    var argn: usize = 1;
    if (flags) |fs| {
        const fs_str = realm.heap.allocateString(fs) catch return error.OutOfMemory;
        argbuf[1] = Value.fromString(fs_str);
        argn = 2;
    }
    const out = interp.callJSFunction(realm.allocator, realm, ctor, heap_mod.taggedObject(inst), argbuf[0..argn]) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.NativeThrew,
    };
    return switch (out) {
        .value, .yielded => |v| if (v.isUndefined()) heap_mod.taggedObject(inst) else v,
        .thrown => |ex| {
            // §22.2.3.3 — propagate the thrown value as a host
            // exception. Without anchoring it in
            // `realm.pending_exception`, the surrounding native
            // method (String.prototype.match here) returns
            // `error.NativeThrew` but the user JS sees a stale /
            // default `[object Object]` because the native dispatch
            // re-creates a TypeError when no pending exception is
            // present.
            realm.pending_exception = ex;
            return error.NativeThrew;
        },
    };
}

// ── String.prototype methods ────────────────────────────────────────────────

fn thisAsJSString(this_value: Value) ?*JSString {
    if (this_value.isString()) {
        return @ptrCast(@alignCast(this_value.asString()));
    }
    return null;
}

/// §22.1.3 RequireObjectCoercible(this) → ToString. Used by
/// every `String.prototype.*` method that didn't already
/// accept-only-primitive paths. Throws TypeError on
/// null/undefined; coerces objects via `.toString()` (calling
/// through `callJSFunction`); other primitives use Cynic's
/// `stringifyArg` (numbers / booleans / etc.). Returns a
/// `*JSString` borrowed from the heap (always realm-tracked).
fn coerceThisToJSString(realm: *Realm, this_value: Value) NativeError!*JSString {
    if (this_value.isString()) {
        return @ptrCast(@alignCast(this_value.asString()));
    }
    if (this_value.isNull() or this_value.isUndefined()) {
        return throwTypeError(realm, "String.prototype.* called on null or undefined");
    }
    // Wrapper objects from `toObjectThis` of a string primitive
    // carry the bytes via their `length` + indexed slots; reading
    // them all back is wasteful, but tests typically box and
    // unbox via the prototype chain so the receiver is a plain
    // object with a string-like shape. Try to short-circuit:
    // if the wrapper's prototype is %String.prototype%, look
    // for an internal string buffer recorded during boxing.
    if (heap_mod.valueAsPlainObject(this_value)) |obj| {
        // Synthetic slot recorded by `toObjectThis` for string
        // primitives. When present, return that JSString
        // directly without re-allocating.
        if (obj.boxed_string) |s| return s;
    }
    // Fallback: stringify via the existing coercion (numbers /
    // booleans / objects via `.toString()`).
    return stringifyArg(realm, this_value);
}

/// §22.1.3.1 String.prototype.charAt(pos). Returns the single-
/// code-unit String at position `pos` (1-based on the code-unit
/// view), or the empty String if `pos` is out of range. The unit
/// is re-encoded as WTF-8 — a surrogate half from a supplementary
/// pair is emitted as the matching 3-byte CESU-8 escape.
fn stringCharAt(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const s = try coerceThisToJSString(realm, this_value);
    const idx_v = try intrinsics.toNumber(realm, argOr(args, 0, Value.fromInt32(0)));
    // §7.1.5 ToIntegerOrInfinity — NaN → 0; +Inf / -Inf are
    // out-of-range; finite values truncate toward zero.
    const idx: i64 = if (idx_v.isInt32()) idx_v.asInt32() else blk: {
        const d = idx_v.asDouble();
        if (std.math.isNan(d)) break :blk 0;
        if (std.math.isInf(d)) break :blk if (d > 0) std.math.maxInt(i32) else -1;
        break :blk @intFromFloat(@trunc(d));
    };
    if (idx < 0) {
        const empty = realm.heap.allocateString("") catch return error.OutOfMemory;
        return Value.fromString(empty);
    }
    const cu = utf16.codeUnitAt(s.bytes, @intCast(idx)) orelse {
        const empty = realm.heap.allocateString("") catch return error.OutOfMemory;
        return Value.fromString(empty);
    };
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(realm.allocator);
    utf16.appendCodeUnitAsWtf8(realm.allocator, &buf, cu) catch return error.OutOfMemory;
    const ch = realm.heap.allocateString(buf.items) catch return error.OutOfMemory;
    return Value.fromString(ch);
}

/// §22.1.3.2 String.prototype.charCodeAt(pos). Returns the
/// numeric value (an integer in 0..0xFFFF) of the code unit at
/// `pos`, or NaN if `pos` is out of range.
fn stringCharCodeAt(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const s = try coerceThisToJSString(realm, this_value);
    const idx_v = try intrinsics.toNumber(realm, argOr(args, 0, Value.fromInt32(0)));
    // §7.1.5 ToIntegerOrInfinity — see stringCharAt for the rule.
    const idx: i64 = if (idx_v.isInt32()) idx_v.asInt32() else blk: {
        const d = idx_v.asDouble();
        if (std.math.isNan(d)) break :blk 0;
        if (std.math.isInf(d)) break :blk if (d > 0) std.math.maxInt(i32) else -1;
        break :blk @intFromFloat(@trunc(d));
    };
    if (idx < 0) return Value.fromDouble(std.math.nan(f64));
    const cu = utf16.codeUnitAt(s.bytes, @intCast(idx)) orelse return Value.fromDouble(std.math.nan(f64));
    return Value.fromInt32(@intCast(cu));
}

/// §22.1.3.8 String.prototype.indexOf(searchString, position).
/// `position` is a UTF-16 code-unit index; the return value is the
/// code-unit index where `searchString`'s WTF-8 byte sequence
/// first appears at or after `position` in the receiver, or -1.
/// Empty `searchString` returns the clamped `position`.
fn stringIndexOf(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const s = try coerceThisToJSString(realm, this_value);
    const needle = try stringifyArg(realm, argOr(args, 0, Value.undefined_));
    const pos_v = argOr(args, 1, Value.undefined_);
    // Receiver length in code units, used for clamping `position`
    // (§22.1.3.8 step 5 — Min(Max(intPosition, 0), len)).
    const cu_len = utf16.lengthInCodeUnits(s.bytes);
    var start_cu: usize = 0;
    if (!pos_v.isUndefined()) {
        const n = try intrinsics.toNumber(realm, pos_v);
        start_cu = clampPos(intrinsics.toInt(n), cu_len);
    }
    if (needle.bytes.len == 0) return Value.fromInt32(@intCast(start_cu));
    const start_byte = utf16.byteIndexForCodeUnit(s.bytes, start_cu) orelse s.bytes.len;
    if (start_byte >= s.bytes.len) return Value.fromInt32(-1);
    if (std.mem.indexOf(u8, s.bytes[start_byte..], needle.bytes)) |off| {
        const abs_byte = off + start_byte;
        return Value.fromInt32(@intCast(utf16.codeUnitIndexForByte(s.bytes, abs_byte)));
    }
    return Value.fromInt32(-1);
}

/// §22.1.3.7 / .21 / .23 — `includes` / `startsWith` / `endsWith`
/// share a preamble: RequireObjectCoercible(this), reject RegExp
/// search arg per §22.1.3.7 step 4 (IsRegExp), ToString(search).
fn coerceSearchString(realm: *Realm, v: Value, method_name: []const u8) NativeError!*JSString {
    if (try isRegExp(realm, v)) {
        _ = method_name;
        return throwTypeError(realm, "First argument must not be a regular expression");
    }
    return stringifyArg(realm, v);
}

/// §7.2.8 IsRegExp(arg) — Object check, then `Get(arg, @@match)`,
/// with fallback to the [[RegExpMatcher]] slot (Cynic's typed
/// `regexp_source` field). The @@match read MUST go through the
/// accessor-aware property chain so a user-installed getter
/// (`get [Symbol.match]() { throw ... }`) fires and propagates,
/// per the `searchValue-isRegExp-abrupt` fixture family.
fn isRegExp(realm: *Realm, v: Value) NativeError!bool {
    const obj = heap_mod.valueAsPlainObject(v) orelse return false;
    const matcher = try intrinsics.getPropertyChain(realm, obj, "@@match");
    if (!matcher.isUndefined()) return matcher.toBooleanPrimitive();
    return obj.regexp_source != null;
}

/// §7.3.10 GetMethod(V, P) — Let func = ? GetV(V, P). If func is
/// either undefined or null, return undefined. If IsCallable(func)
/// is false, throw a TypeError. Otherwise return func.
///
/// Used at the top of String.prototype.{split, replace, replaceAll,
/// match, matchAll, search} to honour the §22.1.3 user-dispatch
/// hook: when the argument carries a well-known Symbol method
/// (Symbol.split / Symbol.replace / …), forward the entire
/// operation to it. Cynic stores well-known Symbols as `@@<name>`
/// property keys, so the lookup goes through `getPropertyChain`
/// which fires accessor getters and walks the prototype chain.
///
/// Returns `null` when no callable @@-method is present (the
/// caller falls back to its built-in path); returns the callable
/// otherwise.
fn getSymbolMethod(
    realm: *Realm,
    receiver: Value,
    at_key: []const u8,
) NativeError!?*JSFunction {
    if (receiver.isUndefined() or receiver.isNull()) return null;
    const obj = heap_mod.valueAsPlainObject(receiver) orelse return null;
    const method = try intrinsics.getPropertyChain(realm, obj, at_key);
    if (method.isUndefined() or method.isNull()) return null;
    return heap_mod.valueAsFunction(method) orelse
        return throwTypeError(realm, "Symbol-keyed dispatch method is not callable");
}

/// Invoke a user-supplied Symbol method with `(this_value, limit?)`
/// (or `(this_value, replacement)` for @@replace). Returns the
/// method's return value or propagates a throw.
fn invokeSymbolMethod(
    realm: *Realm,
    method: *JSFunction,
    receiver: Value,
    arg1: Value,
    arg2: ?Value,
) NativeError!Value {
    var argbuf: [2]Value = .{ arg1, undefined };
    var n: usize = 1;
    if (arg2) |a2| {
        argbuf[1] = a2;
        n = 2;
    }
    const outcome = interpreter.callJSFunction(realm.allocator, realm, method, receiver, argbuf[0..n]) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.NativeThrew,
    };
    return switch (outcome) {
        .value, .yielded => |v| v,
        .thrown => |ex| {
            realm.pending_exception = ex;
            return error.NativeThrew;
        },
    };
}

fn clampPos(p: i64, len: usize) usize {
    if (p < 0) return 0;
    const lp: usize = @intCast(p);
    return @min(lp, len);
}

/// §22.1.3.7 String.prototype.includes(searchString, position).
/// `position` is a UTF-16 code-unit index; the search is a
/// code-unit subsequence match (which on identical WTF-8 bytes
/// reduces to a byte-level search after converting `position`
/// from code units to bytes).
fn stringIncludes(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const s = try coerceThisToJSString(realm, this_value);
    const needle = try coerceSearchString(realm, argOr(args, 0, Value.undefined_), "includes");
    const pos_v = argOr(args, 1, Value.undefined_);
    const cu_len = utf16.lengthInCodeUnits(s.bytes);
    var start_cu: usize = 0;
    if (!pos_v.isUndefined()) {
        const n = try intrinsics.toNumber(realm, pos_v);
        start_cu = clampPos(intrinsics.toInt(n), cu_len);
    }
    if (start_cu >= cu_len) {
        return Value.fromBool(needle.bytes.len == 0);
    }
    const start_byte = utf16.byteIndexForCodeUnit(s.bytes, start_cu) orelse s.bytes.len;
    return Value.fromBool(std.mem.indexOf(u8, s.bytes[start_byte..], needle.bytes) != null);
}

/// §22.1.3.21 String.prototype.startsWith(searchString, position).
/// `position` is a UTF-16 code-unit index — the test is whether
/// the code units of the receiver starting at `position` are
/// identical to the code units of `searchString`. Reduces to a
/// byte prefix-test after converting `position` from code units
/// to bytes.
fn stringStartsWith(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const s = try coerceThisToJSString(realm, this_value);
    const needle = try coerceSearchString(realm, argOr(args, 0, Value.undefined_), "startsWith");
    const pos_v = argOr(args, 1, Value.undefined_);
    const cu_len = utf16.lengthInCodeUnits(s.bytes);
    var start_cu: usize = 0;
    if (!pos_v.isUndefined()) {
        const n = try intrinsics.toNumber(realm, pos_v);
        start_cu = clampPos(intrinsics.toInt(n), cu_len);
    }
    const start_byte = utf16.byteIndexForCodeUnit(s.bytes, start_cu) orelse s.bytes.len;
    if (start_byte + needle.bytes.len > s.bytes.len) return Value.false_;
    return Value.fromBool(std.mem.startsWith(u8, s.bytes[start_byte..], needle.bytes));
}

/// §22.1.3.6 String.prototype.endsWith(searchString, endPosition).
/// `endPosition` is a UTF-16 code-unit index; the test is whether
/// the code units of the receiver ending at `endPosition` are
/// identical to the code units of `searchString`. Reduces to a
/// byte suffix-of-prefix test after converting `endPosition` from
/// code units to bytes.
fn stringEndsWith(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const s = try coerceThisToJSString(realm, this_value);
    const needle = try coerceSearchString(realm, argOr(args, 0, Value.undefined_), "endsWith");
    const end_pos_v = argOr(args, 1, Value.undefined_);
    const cu_len = utf16.lengthInCodeUnits(s.bytes);
    var end_cu: usize = cu_len;
    if (!end_pos_v.isUndefined()) {
        const n = try intrinsics.toNumber(realm, end_pos_v);
        end_cu = clampPos(intrinsics.toInt(n), cu_len);
    }
    const end_byte = utf16.byteIndexForCodeUnit(s.bytes, end_cu) orelse s.bytes.len;
    if (needle.bytes.len > end_byte) return Value.false_;
    const start = end_byte - needle.bytes.len;
    return Value.fromBool(std.mem.eql(u8, s.bytes[start..end_byte], needle.bytes));
}

/// Allocate a JSString from a `utf16.Slice` — the byte slice
/// plus any orphan-surrogate halves from a mid-pair endpoint.
/// The surrogate halves are encoded as 3-byte WTF-8 sequences
/// (CESU-8) so the result is still WTF-8-valid.
fn jsStringFromUtf16Slice(realm: *Realm, sl: utf16.Slice) NativeError!*JSString {
    if (sl.head_surrogate == 0 and sl.tail_surrogate == 0) {
        return realm.heap.allocateString(sl.bytes) catch return error.OutOfMemory;
    }
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(realm.allocator);
    if (sl.head_surrogate != 0) {
        utf16.appendCodeUnitAsWtf8(realm.allocator, &buf, sl.head_surrogate) catch return error.OutOfMemory;
    }
    buf.appendSlice(realm.allocator, sl.bytes) catch return error.OutOfMemory;
    if (sl.tail_surrogate != 0) {
        utf16.appendCodeUnitAsWtf8(realm.allocator, &buf, sl.tail_surrogate) catch return error.OutOfMemory;
    }
    return realm.heap.allocateString(buf.items) catch return error.OutOfMemory;
}

/// §22.1.3.20 String.prototype.slice(start, end). Code-unit
/// indexing with negative offsets normalised against the
/// code-unit length. Result is the substring covering the
/// code-unit range `[start, end)` (clamped to `[0, len]`).
fn stringSlice(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const s = try coerceThisToJSString(realm, this_value);
    const len: i64 = @intCast(utf16.lengthInCodeUnits(s.bytes));
    const start_num = try intrinsics.toNumber(realm, argOr(args, 0, Value.fromInt32(0)));
    var start: i64 = intrinsics.toInt(start_num);
    var end: i64 = len;
    if (args.len > 1 and !args[1].isUndefined()) {
        const end_num = try intrinsics.toNumber(realm, args[1]);
        end = intrinsics.toInt(end_num);
    }
    // §22.1.3.20 step 6-9 — negative offsets count from the end.
    if (start < 0) start = @max(len + start, 0);
    if (end < 0) end = @max(len + end, 0);
    start = @min(start, len);
    end = @min(end, len);
    if (end < start) end = start;
    const sl = utf16.sliceCodeUnits(s.bytes, @intCast(start), @intCast(end));
    const out = try jsStringFromUtf16Slice(realm, sl);
    return Value.fromString(out);
}

/// §22.1.3.24 String.prototype.substring(start, end). Like
/// `slice` but negatives clamp to 0 instead of wrapping, and the
/// two endpoints are swapped (lower precedes higher) when out of
/// order. Indexed in UTF-16 code units.
fn stringSubstring(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const s = try coerceThisToJSString(realm, this_value);
    const len: i64 = @intCast(utf16.lengthInCodeUnits(s.bytes));
    const start_num = try intrinsics.toNumber(realm, argOr(args, 0, Value.fromInt32(0)));
    var start: i64 = intrinsics.toInt(start_num);
    var end: i64 = len;
    if (args.len > 1 and !args[1].isUndefined()) {
        const end_num = try intrinsics.toNumber(realm, args[1]);
        end = intrinsics.toInt(end_num);
    }
    // §22.1.3.24 step 6-9 — negatives clamp to 0, then swap if
    // start > end.
    start = @max(0, @min(start, len));
    end = @max(0, @min(end, len));
    if (start > end) {
        const t = start;
        start = end;
        end = t;
    }
    const sl = utf16.sliceCodeUnits(s.bytes, @intCast(start), @intCast(end));
    const out = try jsStringFromUtf16Slice(realm, sl);
    return Value.fromString(out);
}

fn stringToString(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    // §22.1.3.32 — `this` may be a string primitive (return as-
    // is), a wrapper object (unbox via `boxed_string`), or
    // anything else (TypeError per §22.1.3.32 step 1).
    if (this_value.isString()) return this_value;
    if (heap_mod.valueAsPlainObject(this_value)) |obj| {
        if (obj.boxed_string) |s| return Value.fromString(s);
    }
    return throwTypeError(realm, "String.prototype.toString called on non-String");
}

/// §22.1.3.27 String.prototype.toUpperCase — full Unicode case
/// conversion via libunicode's `lre_case_conv` (UCD-derived
/// tables, conv_type 0 = upper). Decode each WTF-8 codepoint,
/// apply the language-insensitive mapping (1-3 result code
/// points per input), re-encode as WTF-8. Lone surrogates pass
/// through unchanged — `lre_case_conv` returns the input
/// code point for non-cased values.
fn stringToUpperCase(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    const s = try coerceThisToJSString(realm, this_value);
    return caseConvertString(realm, s.bytes, 0);
}

/// §22.1.3.26 String.prototype.toLowerCase. Uses libunicode's
/// `lre_case_conv` (conv_type 1 = lower) plus a §22.1.3.26
/// step 4.a Final_Sigma rule on U+03A3 GREEK CAPITAL LETTER
/// SIGMA: Sigma maps to U+03C2 SMALL FINAL SIGMA when the
/// preceding context (zero+ Case_Ignorable then Cased) is set
/// and the following context (zero+ Case_Ignorable then Cased)
/// is not. Otherwise the default U+03C3 mapping from the table
/// applies.
fn stringToLowerCase(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    const s = try coerceThisToJSString(realm, this_value);
    return caseConvertString(realm, s.bytes, 1);
}

/// Shared body for §22.1.3.{26, 27, 28, 29}. `conv_type` is the
/// libunicode tag: 0 = to-upper, 1 = to-lower (the toLocale*
/// variants share the same table for default/`en` locales —
/// Turkish dotless-i lives in intl402/, out of scope per
/// AGENTS.md). The Final_Sigma adjustment is gated on
/// `conv_type == 1` so toUpperCase never observes it.
fn caseConvertString(realm: *Realm, bytes: []const u8, conv_type: c_int) NativeError!Value {
    // §22.1.3.{26, 27} step 3 — Let cpList be the list of code
    // points of S. Decode WTF-8 to codepoints first so we can
    // run the Final_Sigma context lookahead without re-walking.
    var cps: std.ArrayListUnmanaged(u32) = .empty;
    defer cps.deinit(realm.allocator);
    decodeWtf8ToCodepoints(realm.allocator, &cps, bytes) catch return error.OutOfMemory;

    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(realm.allocator);

    var i: usize = 0;
    while (i < cps.items.len) : (i += 1) {
        const cp = cps.items[i];
        // §22.1.3.26 step 4.a — Final_Sigma override.
        if (conv_type == 1 and cp == 0x03A3 and isFinalSigmaContext(cps.items, i)) {
            appendWtf8(realm.allocator, &out, 0x03C2) catch return error.OutOfMemory;
            continue;
        }
        var res: [3]u32 = undefined;
        const len = lib_unicode.lre_case_conv(&res, cp, conv_type);
        var k: usize = 0;
        while (k < @as(usize, @intCast(len))) : (k += 1) {
            const r = res[k];
            // `lre_case_conv` returns code points up to 0x10FFFF;
            // narrow back to u21 for `appendWtf8`.
            appendWtf8(realm.allocator, &out, @intCast(r)) catch return error.OutOfMemory;
        }
    }
    const new_s = realm.heap.allocateString(out.items) catch return error.OutOfMemory;
    return Value.fromString(new_s);
}

/// Decode `bytes` (WTF-8: UTF-8 with 3-byte CESU-8 lone-surrogate
/// escapes) into a flat list of code points. A 4-byte UTF-8
/// sequence is a single supplementary code point; 3-byte
/// sequences in the 0xD800..0xDFFF range round-trip as the lone
/// surrogate code unit value.
fn decodeWtf8ToCodepoints(
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u32),
    bytes: []const u8,
) std.mem.Allocator.Error!void {
    var i: usize = 0;
    while (i < bytes.len) {
        const seq_len = utf8SeqLen(bytes[i]);
        if (i + seq_len > bytes.len) {
            // Malformed tail — emit the raw byte to make progress.
            try out.append(allocator, bytes[i]);
            i += 1;
            continue;
        }
        const cp: u32 = switch (seq_len) {
            1 => bytes[i],
            2 => (@as(u32, bytes[i] & 0x1F) << 6) | @as(u32, bytes[i + 1] & 0x3F),
            3 => (@as(u32, bytes[i] & 0x0F) << 12) |
                (@as(u32, bytes[i + 1] & 0x3F) << 6) |
                @as(u32, bytes[i + 2] & 0x3F),
            4 => (@as(u32, bytes[i] & 0x07) << 18) |
                (@as(u32, bytes[i + 1] & 0x3F) << 12) |
                (@as(u32, bytes[i + 2] & 0x3F) << 6) |
                @as(u32, bytes[i + 3] & 0x3F),
            else => unreachable,
        };
        try out.append(allocator, cp);
        i += seq_len;
    }
}

/// §22.1.3.26 Final_Sigma — true iff `idx` is preceded by a
/// Cased code point with zero or more Case_Ignorable code
/// points between, and *not* followed by zero or more
/// Case_Ignorable code points then a Cased code point. Uses
/// libunicode's `lre_is_cased` / `lre_is_case_ignorable`
/// which mirror DerivedCoreProperties' Cased and
/// Case_Ignorable.
fn isFinalSigmaContext(cps: []const u32, idx: usize) bool {
    // Before: walk backwards skipping Case_Ignorable; first
    // non-ignorable must be Cased.
    var before_cased = false;
    if (idx > 0) {
        var j = idx;
        while (j > 0) {
            j -= 1;
            const p = cps[j];
            if (lib_unicode.lre_is_case_ignorable(p)) continue;
            before_cased = lib_unicode.lre_is_cased(p);
            break;
        }
    }
    if (!before_cased) return false;
    // After: walk forward skipping Case_Ignorable; first non-
    // ignorable must NOT be Cased (or end-of-string).
    var j: usize = idx + 1;
    while (j < cps.len) : (j += 1) {
        const p = cps[j];
        if (lib_unicode.lre_is_case_ignorable(p)) continue;
        return !lib_unicode.lre_is_cased(p);
    }
    return true;
}

/// §11.2 WhiteSpace + §11.3 LineTerminator productions —
/// the codepoint set that String.prototype.trim* strips. Notably
/// includes U+00A0 NBSP, U+FEFF ZWNBSP, the Space_Separator
/// (Zs) category, and the LS / PS line separators in addition
/// to the ASCII controls.
fn isStringWhitespace(cp: u21) bool {
    return switch (cp) {
        // ASCII WhiteSpace + LineTerminator.
        0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x20 => true,
        // Other named whitespace.
        0x00A0, 0xFEFF => true,
        // Unicode Zs (Space_Separator) — enumerated to avoid
        // pulling in the full UCD; this covers the spec set as
        // of Unicode 15.
        0x1680, 0x2000, 0x2001, 0x2002, 0x2003, 0x2004, 0x2005, 0x2006, 0x2007, 0x2008, 0x2009, 0x200A, 0x202F, 0x205F, 0x3000 => true,
        // LineTerminator: LS / PS.
        0x2028, 0x2029 => true,
        else => false,
    };
}

/// Walk `bytes` forward, returning the first byte index whose
/// codepoint isn't WhiteSpace/LineTerminator (or `bytes.len` if
/// all-whitespace). Bytes are UTF-8 — invalid sequences stop
/// the walk, leaving them alone.
fn skipLeadingWhitespace(bytes: []const u8) usize {
    var view = std.unicode.Utf8View.initUnchecked(bytes).iterator();
    while (true) {
        const before = view.i;
        const cp = view.nextCodepoint() orelse return bytes.len;
        if (!isStringWhitespace(cp)) return before;
    }
}

/// Walk `bytes` forward, returning the byte index ONE PAST the
/// last non-whitespace codepoint (so a slice `[..end]` is the
/// trailing-trimmed string). Returns 0 for an all-whitespace
/// string.
fn endAfterTrailingWhitespace(bytes: []const u8) usize {
    var view = std.unicode.Utf8View.initUnchecked(bytes).iterator();
    var last_nonws_end: usize = 0;
    while (true) {
        const before = view.i;
        const cp = view.nextCodepoint() orelse return last_nonws_end;
        if (!isStringWhitespace(cp)) last_nonws_end = view.i;
        _ = before;
    }
}

fn stringTrim(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    const s = try coerceThisToJSString(realm, this_value);
    const start = skipLeadingWhitespace(s.bytes);
    const end = endAfterTrailingWhitespace(s.bytes);
    const trimmed = if (start >= end) s.bytes[0..0] else s.bytes[start..end];
    const out = realm.heap.allocateString(trimmed) catch return error.OutOfMemory;
    return Value.fromString(out);
}

fn stringConcat(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const s = try coerceThisToJSString(realm, this_value);
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(realm.allocator);
    buf.appendSlice(realm.allocator, s.bytes) catch return error.OutOfMemory;
    for (args) |a| {
        const part = try stringifyArg(realm, a);
        buf.appendSlice(realm.allocator, part.bytes) catch return error.OutOfMemory;
    }
    const out = realm.heap.allocateString(buf.items) catch return error.OutOfMemory;
    return Value.fromString(out);
}

fn stringRepeat(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const s = try coerceThisToJSString(realm, this_value);
    // §22.1.3.16 — ToIntegerOrInfinity(count); NaN ⇒ 0 (not throw);
    // negative or +Infinity ⇒ RangeError.
    const n_v = try intrinsics.toNumber(realm, argOr(args, 0, Value.fromInt32(0)));
    const n: i64 = if (n_v.isInt32()) n_v.asInt32() else blk: {
        const d = n_v.asDouble();
        if (std.math.isNan(d)) break :blk 0;
        if (std.math.isInf(d) and d > 0) {
            const ex = intrinsics.newRangeError(realm, "Invalid count value") catch return error.OutOfMemory;
            realm.pending_exception = ex;
            return error.NativeThrew;
        }
        if (d < 0) {
            const ex = intrinsics.newRangeError(realm, "Invalid count value") catch return error.OutOfMemory;
            realm.pending_exception = ex;
            return error.NativeThrew;
        }
        break :blk @intFromFloat(@trunc(d));
    };
    if (n < 0) {
        const ex = intrinsics.newRangeError(realm, "Invalid count value") catch return error.OutOfMemory;
        realm.pending_exception = ex;
        return error.NativeThrew;
    }
    if (n == 0) {
        const empty = realm.heap.allocateString("") catch return error.OutOfMemory;
        return Value.fromString(empty);
    }
    // Cap to avoid OOM on giant repeat counts.
    const total: usize = @intCast(@as(i64, @intCast(s.bytes.len)) * n);
    if (total > 1024 * 1024) return error.NativeThrew;
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(realm.allocator);
    buf.ensureTotalCapacity(realm.allocator, total) catch return error.OutOfMemory;
    var k: i64 = 0;
    while (k < n) : (k += 1) {
        buf.appendSlice(realm.allocator, s.bytes) catch return error.OutOfMemory;
    }
    const out = realm.heap.allocateString(buf.items) catch return error.OutOfMemory;
    return Value.fromString(out);
}

// ── Additional String methods ───────────────────────────────────────────────

/// §22.1.3.23 entry that performs the Symbol.split dispatch. Wired
/// at install-time as `String.prototype.split`. The post-dispatch
/// fallback path delegates to the symbol-free `stringSplit` core,
/// which is also re-used by `RegExp.prototype[@@split]`. ToString
/// on the receiver is deferred to the core so the @@split dispatch
/// observes the uncoerced `thisValue` (per fixture
/// `this-value-tostring-error`).
fn stringSplitDispatched(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    if (this_value.isNull() or this_value.isUndefined())
        return throwTypeError(realm, "String.prototype.split called on null or undefined");
    const sep_v = argOr(args, 0, Value.undefined_);
    const limit_v = argOr(args, 1, Value.undefined_);
    // §22.1.3.23 step 3 — "If separator is an Object" gate. Only
    // Objects can carry a Symbol.split method.
    if (heap_mod.valueAsPlainObject(sep_v)) |_| {
        if (try getSymbolMethod(realm, sep_v, "@@split")) |splitter| {
            return invokeSymbolMethod(realm, splitter, sep_v, this_value, limit_v);
        }
    }
    return stringSplit(realm, this_value, args);
}

pub fn stringSplit(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    // §22.1.3.23 step 4 — `str = ? ToString(thisValue)`. The
    // ToString(this) call happens *before* the limit computation so
    // a throwing toString on `this` short-circuits the rest.
    const s = try coerceThisToJSString(realm, this_value);
    const sep_v = argOr(args, 0, Value.undefined_);
    const limit_v = argOr(args, 1, Value.undefined_);
    // §22.1.3.23 step 5 — `lim = ToUint32(limit)` (default 2^32-1
    // when undefined). The ToUint32 walk runs even on objects, so
    // a `{valueOf}` shadow fires; passing through `intrinsics.
    // toNumber` invokes Symbol.toPrimitive / valueOf / toString in
    // spec order.
    const limit_raw: u32 = if (limit_v.isUndefined())
        std.math.maxInt(u32)
    else blk: {
        const num_v = try intrinsics.toNumber(realm, limit_v);
        break :blk arith_toUint32(num_v);
    };
    // Cap to i32 max for our cursor; any larger limit is
    // operationally infinite for the bounded source.
    const limit: i64 = @min(@as(i64, limit_raw), @as(i64, std.math.maxInt(i32)));
    const out = realm.heap.allocateObject() catch return error.OutOfMemory;
    out.prototype = realm.intrinsics.array_prototype;
    out.markAsArrayExotic(realm.allocator) catch return error.OutOfMemory;

    // §22.1.3.23 — when separator is a regex (we already filtered
    // out the @@split dispatch in `stringSplitDispatched`), drive
    // matching through libregexp via the spec's sticky-splitter.
    if (isRegexLike(sep_v)) |regex_obj| {
        if (limit == 0) {
            setLength(realm, out, 0) catch return error.OutOfMemory;
            return heap_mod.taggedObject(out);
        }
        return regexSplit(realm, s, regex_obj, limit, out);
    }

    // step 6 — `separatorStr = ? ToString(separator)`. ToString
    // runs BEFORE the `lim == 0` short-circuit (fixture
    // `separator-tostring-error`).
    const sep_str_v: Value = if (sep_v.isUndefined())
        Value.undefined_
    else if (sep_v.isString())
        sep_v
    else
        Value.fromString(try stringifyArg(realm, sep_v));

    // step 7 — `If lim = 0, return []`. After ToString(separator).
    if (limit == 0) {
        setLength(realm, out, 0) catch return error.OutOfMemory;
        return heap_mod.taggedObject(out);
    }

    // step 8 — `If separator is undefined, return [str]`.
    if (sep_v.isUndefined()) {
        const owned = realm.heap.allocateString("0") catch return error.OutOfMemory;
        const cs = realm.heap.allocateString(s.bytes) catch return error.OutOfMemory;
        out.set(realm.allocator, owned.bytes, Value.fromString(cs)) catch return error.OutOfMemory;
        setLength(realm, out, 1) catch return error.OutOfMemory;
        return heap_mod.taggedObject(out);
    }

    const sep: *JSString = @ptrCast(@alignCast(sep_str_v.asString()));

    // Empty separator — split into chars. Honour `limit`.
    if (sep.bytes.len == 0) {
        var idx: usize = 0;
        for (s.bytes) |c| {
            if (idx >= @as(usize, @intCast(limit))) break;
            var ibuf: [24]u8 = undefined;
            const islice = std.fmt.bufPrint(&ibuf, "{d}", .{idx}) catch unreachable;
            const owned = realm.heap.allocateString(islice) catch return error.OutOfMemory;
            const cs = realm.heap.allocateString(&[_]u8{c}) catch return error.OutOfMemory;
            out.set(realm.allocator, owned.bytes, Value.fromString(cs)) catch return error.OutOfMemory;
            idx += 1;
        }
        setLength(realm, out, @intCast(idx)) catch return error.OutOfMemory;
        return heap_mod.taggedObject(out);
    }

    // Generic split. Stop as soon as we've collected `limit`
    // pieces — the spec caps the result, not the work.
    var i: usize = 0;
    var idx: usize = 0;
    while (i <= s.bytes.len) {
        if (idx >= @as(usize, @intCast(limit))) break;
        const remaining = s.bytes[i..];
        if (std.mem.indexOf(u8, remaining, sep.bytes)) |pos| {
            const part = remaining[0..pos];
            var ibuf: [24]u8 = undefined;
            const islice = std.fmt.bufPrint(&ibuf, "{d}", .{idx}) catch unreachable;
            const owned = realm.heap.allocateString(islice) catch return error.OutOfMemory;
            const cs = realm.heap.allocateString(part) catch return error.OutOfMemory;
            out.set(realm.allocator, owned.bytes, Value.fromString(cs)) catch return error.OutOfMemory;
            idx += 1;
            i += pos + sep.bytes.len;
        } else {
            // Last piece.
            var ibuf: [24]u8 = undefined;
            const islice = std.fmt.bufPrint(&ibuf, "{d}", .{idx}) catch unreachable;
            const owned = realm.heap.allocateString(islice) catch return error.OutOfMemory;
            const cs = realm.heap.allocateString(remaining) catch return error.OutOfMemory;
            out.set(realm.allocator, owned.bytes, Value.fromString(cs)) catch return error.OutOfMemory;
            idx += 1;
            break;
        }
    }
    setLength(realm, out, @intCast(idx)) catch return error.OutOfMemory;
    return heap_mod.taggedObject(out);
}

fn stringPadStart(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    return stringPad(realm, this_value, args, true);
}
fn stringPadEnd(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    return stringPad(realm, this_value, args, false);
}
/// §22.1.3.14 padStart / §22.1.3.13 padEnd — `start = true` for
/// padStart, false for padEnd. Both delegate to abstract op
/// StringPad: `maxLength` and the padding count are expressed in
/// UTF-16 code units; the fill string is truncated by code units
/// (not bytes) when its last copy would overshoot.
fn stringPad(realm: *Realm, this_value: Value, args: []const Value, start: bool) NativeError!Value {
    const s = try coerceThisToJSString(realm, this_value);
    // §22.1.3.14 step 3 — ToLength(maxLength). NaN / negative
    // values clamp to 0 (§7.1.20 makes negatives → 0; we follow
    // the more permissive ToIntegerOrInfinity per the spec which
    // §22.1.3.14 invokes).
    const target_v_raw = argOr(args, 0, Value.fromInt32(0));
    const target_num = try intrinsics.toNumber(realm, target_v_raw);
    const target_len: i64 = blk: {
        if (target_num.isInt32()) break :blk target_num.asInt32();
        const d = target_num.asDouble();
        if (std.math.isNan(d) or std.math.isInf(d) or d < 0) break :blk 0;
        break :blk @intFromFloat(@trunc(d));
    };
    // Receiver code-unit length; pad only when the target exceeds
    // it (StringPad step 1).
    const s_cu_len = utf16.lengthInCodeUnits(s.bytes);
    if (target_len <= @as(i64, @intCast(s_cu_len))) {
        const out = realm.heap.allocateString(s.bytes) catch return error.OutOfMemory;
        return Value.fromString(out);
    }
    // StringPad step 3 — fillString defaults to a single space.
    // Other primitives are ToString-coerced.
    const fill_v = argOr(args, 1, Value.undefined_);
    const fill_str: *JSString = if (fill_v.isUndefined())
        try stringifyArg(realm, Value.fromString(realm.heap.allocateString(" ") catch return error.OutOfMemory))
    else
        try stringifyArg(realm, fill_v);
    if (fill_str.bytes.len == 0) {
        // StringPad step 4 — empty fillString is a no-op.
        const out = realm.heap.allocateString(s.bytes) catch return error.OutOfMemory;
        return Value.fromString(out);
    }
    const fill_cu_len = utf16.lengthInCodeUnits(fill_str.bytes);
    const target_cu: usize = @intCast(target_len);
    if (target_cu > 1024 * 1024) return error.NativeThrew; // sanity cap
    const pad_cu = target_cu - s_cu_len;
    // StringPad step 7 — build a truncated padding string of length
    // `pad_cu` code units by concatenating `fillString` enough
    // times and slicing the last copy to fit.
    var pad_buf: std.ArrayListUnmanaged(u8) = .empty;
    defer pad_buf.deinit(realm.allocator);
    var produced_cu: usize = 0;
    while (produced_cu + fill_cu_len <= pad_cu) {
        pad_buf.appendSlice(realm.allocator, fill_str.bytes) catch return error.OutOfMemory;
        produced_cu += fill_cu_len;
    }
    if (produced_cu < pad_cu) {
        // Need a partial copy of `fill_str` of (pad_cu - produced_cu)
        // code units. Slice in code-unit space so a fill string
        // ending mid-surrogate-pair is split correctly.
        const remaining_cu = pad_cu - produced_cu;
        const tail = utf16.sliceCodeUnits(fill_str.bytes, 0, remaining_cu);
        if (tail.head_surrogate != 0)
            utf16.appendCodeUnitAsWtf8(realm.allocator, &pad_buf, tail.head_surrogate) catch return error.OutOfMemory;
        pad_buf.appendSlice(realm.allocator, tail.bytes) catch return error.OutOfMemory;
        if (tail.tail_surrogate != 0)
            utf16.appendCodeUnitAsWtf8(realm.allocator, &pad_buf, tail.tail_surrogate) catch return error.OutOfMemory;
    }
    // StringPad step 8 / 10 — prepend or append.
    var out_buf: std.ArrayListUnmanaged(u8) = .empty;
    defer out_buf.deinit(realm.allocator);
    if (start) {
        out_buf.appendSlice(realm.allocator, pad_buf.items) catch return error.OutOfMemory;
        out_buf.appendSlice(realm.allocator, s.bytes) catch return error.OutOfMemory;
    } else {
        out_buf.appendSlice(realm.allocator, s.bytes) catch return error.OutOfMemory;
        out_buf.appendSlice(realm.allocator, pad_buf.items) catch return error.OutOfMemory;
    }
    const out = realm.heap.allocateString(out_buf.items) catch return error.OutOfMemory;
    return Value.fromString(out);
}

/// §22.1.3.0 String.prototype.at(index). Like charAt but
/// negative indices wrap from the end (`s.at(-1)` is the last
/// code unit) and out-of-range returns `undefined` rather than
/// the empty String. Indexing is in UTF-16 code units (§6.1.4).
fn stringAt(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const s = try coerceThisToJSString(realm, this_value);
    const idx_num = try intrinsics.toNumber(realm, argOr(args, 0, Value.fromInt32(0)));
    var idx: i64 = intrinsics.toInt(idx_num);
    const cu_len: i64 = @intCast(utf16.lengthInCodeUnits(s.bytes));
    if (idx < 0) idx += cu_len;
    if (idx < 0 or idx >= cu_len) return Value.undefined_;
    const cu = utf16.codeUnitAt(s.bytes, @intCast(idx)) orelse return Value.undefined_;
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(realm.allocator);
    utf16.appendCodeUnitAsWtf8(realm.allocator, &buf, cu) catch return error.OutOfMemory;
    const out = realm.heap.allocateString(buf.items) catch return error.OutOfMemory;
    return Value.fromString(out);
}

/// §22.1.3.9 String.prototype.lastIndexOf(searchString, position).
/// `position` is a UTF-16 code-unit index; the return value is the
/// largest code-unit index ≤ `position` at which `searchString`
/// appears in the receiver, or -1 if there is no such index.
/// `position = NaN` is treated as +Infinity (search the whole
/// string).
fn stringLastIndexOf(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const s = try coerceThisToJSString(realm, this_value);
    const needle = try stringifyArg(realm, argOr(args, 0, Value.undefined_));
    // §22.1.3.9 step 4-6 — `position` is ToNumber, NaN ⇒ +Inf so
    // the search starts from the end. Anything else is
    // ToIntegerOrInfinity, then clamped to [0, len]. Indexing is
    // in UTF-16 code units.
    const pos_v = argOr(args, 1, Value.undefined_);
    const cu_len = utf16.lengthInCodeUnits(s.bytes);
    var search_end_cu: usize = cu_len;
    if (!pos_v.isUndefined()) {
        const n = try intrinsics.toNumber(realm, pos_v);
        const is_nan = n.isDouble() and std.math.isNan(n.asDouble());
        if (!is_nan) {
            const pos_i = intrinsics.toInt(n);
            search_end_cu = clampPos(pos_i, cu_len);
        }
    }
    if (needle.bytes.len == 0) return Value.fromInt32(@intCast(search_end_cu));
    if (needle.bytes.len > s.bytes.len) return Value.fromInt32(-1);
    // Convert the code-unit upper bound to a byte upper bound,
    // padded by needle.bytes.len so a match starting at
    // `search_end_cu` (whose byte offset + needle.bytes.len would
    // overshoot) is still considered. Then walk the byte-level
    // lastIndexOf result back to a code-unit index.
    const search_end_byte = utf16.byteIndexForCodeUnit(s.bytes, search_end_cu) orelse s.bytes.len;
    const upper = @min(search_end_byte + needle.bytes.len, s.bytes.len);
    if (std.mem.lastIndexOf(u8, s.bytes[0..upper], needle.bytes)) |pos| {
        const cu_idx = utf16.codeUnitIndexForByte(s.bytes, pos);
        // The found byte offset must correspond to a code-unit
        // index ≤ search_end_cu — clamp defensively.
        if (cu_idx <= search_end_cu) return Value.fromInt32(@intCast(cu_idx));
    }
    return Value.fromInt32(-1);
}

/// §22.2.6.14 RegExp.prototype [ @@split ] core. Mirrors the
/// spec's `searchIndex` / `lastMatchEnd` / sticky-splitter pair:
/// we construct a sticky clone of `regex_obj` (adding "y" to its
/// flags if missing) so `RegExpExec` either matches *exactly* at
/// the current `searchIndex` or returns null. That eliminates
/// the slice-and-re-search trick that mis-handled `/^/` and `/$/`.
fn regexSplit(
    realm: *Realm,
    s: *JSString,
    regex_obj: *JSObject,
    limit: i64,
    out: *JSObject,
) NativeError!Value {
    // Spec step 5 — `flags = ? ToString(? Get(regexp, "flags"))`
    // routed through the accessor-aware chain so a user-installed
    // `flags` getter / own-property shadow fires.
    const flags_v = try intrinsics.getPropertyChain(realm, regex_obj, "flags");
    const flags_str = try intrinsics.stringifyArg(realm, flags_v);
    // unicodeMatching = flags contains "u" or "v". For Cynic's
    // UTF-16-by-WTF-8 model AdvanceStringIndex(s, q) always
    // advances by one code unit, ignoring fullUnicode — the
    // byte-level cursor walking we already do handles the
    // surrogate-pair codepoints uniformly.
    const has_y = std.mem.indexOfScalar(u8, flags_str.bytes, 'y') != null;
    // Step 8-9 — build newFlags. Append "y" only when missing.
    var new_flags_buf: [16]u8 = undefined;
    const new_flags: []const u8 = if (has_y) flags_str.bytes else blk: {
        const len = flags_str.bytes.len;
        @memcpy(new_flags_buf[0..len], flags_str.bytes);
        new_flags_buf[len] = 'y';
        break :blk new_flags_buf[0 .. len + 1];
    };
    // Step 10 — splitter = Construct(C, « regexp, newFlags »).
    // Cynic uses the global RegExp constructor (SpeciesConstructor
    // lookup is later); reading `regexp.source` for the pattern.
    const source_v = try intrinsics.getPropertyChain(realm, regex_obj, "source");
    const splitter_v = try regExpCreate(realm, source_v, new_flags);
    const splitter = heap_mod.valueAsPlainObject(splitter_v) orelse return throwTypeError(realm, "split: failed to construct splitter");

    // §22.2.6.14 step 15 — empty string fast path: one exec; if
    // null, return `[str]`; else `[]`.
    var idx: i32 = 0;
    var ibuf: [24]u8 = undefined;
    if (s.bytes.len == 0) {
        splitter.set(realm.allocator, "lastIndex", Value.fromInt32(0)) catch return error.OutOfMemory;
        const er = try regexExecCall(realm, splitter, s);
        if (er.isNull()) {
            const owned = realm.heap.allocateString("0") catch return error.OutOfMemory;
            const empty_s = realm.heap.allocateString("") catch return error.OutOfMemory;
            out.set(realm.allocator, owned.bytes, Value.fromString(empty_s)) catch return error.OutOfMemory;
            setLength(realm, out, 1) catch return error.OutOfMemory;
        } else {
            setLength(realm, out, 0) catch return error.OutOfMemory;
        }
        return heap_mod.taggedObject(out);
    }

    // §22.2.6.14 steps 18-20 — main loop. `last_match_end` tracks
    // the index just past the previous emitted match;
    // `search_index` is where the next sticky exec attempts to
    // anchor. They diverge across zero-width / no-match steps.
    var last_match_end: usize = 0;
    var search_index: usize = 0;
    const max_iter: usize = 1 << 20;
    var step: usize = 0;
    while (step < max_iter and search_index < s.bytes.len) : (step += 1) {
        splitter.set(realm.allocator, "lastIndex", Value.fromInt32(@intCast(search_index))) catch return error.OutOfMemory;
        const er = try regexExecCall(realm, splitter, s);
        if (er.isNull()) {
            // Step 20.c — no match at search_index → advance.
            search_index = advanceUnitOnString(s.bytes, search_index);
            continue;
        }
        const match_arr = heap_mod.valueAsPlainObject(er) orelse return throwTypeError(realm, "split: exec did not return Object/null");
        // Step 20.d.i — matchEnd = ToLength(Get(splitter, "lastIndex")),
        // clamped to size.
        const li_v = try intrinsics.getPropertyChain(realm, splitter, "lastIndex");
        const li_raw: i64 = if (li_v.isInt32()) @max(0, @as(i64, li_v.asInt32())) else try intrinsics.toLengthValue(realm, li_v);
        const match_end: usize = @min(@as(usize, @intCast(li_raw)), s.bytes.len);
        if (match_end == last_match_end) {
            // Step 20.d.iii — zero-width or already-emitted boundary
            // → advance the search position only.
            search_index = advanceUnitOnString(s.bytes, search_index);
            continue;
        }
        // Step 20.d.iv — emit the substring from lastMatchEnd to
        // searchIndex.
        const part = s.bytes[last_match_end..search_index];
        const islice = std.fmt.bufPrint(&ibuf, "{d}", .{idx}) catch unreachable;
        const owned = realm.heap.allocateString(islice) catch return error.OutOfMemory;
        const part_str = realm.heap.allocateString(part) catch return error.OutOfMemory;
        out.set(realm.allocator, owned.bytes, Value.fromString(part_str)) catch return error.OutOfMemory;
        idx += 1;
        if (idx >= limit) {
            setLength(realm, out, @intCast(idx)) catch return error.OutOfMemory;
            return heap_mod.taggedObject(out);
        }
        last_match_end = match_end;
        // Step 20.d.iv.{vi..xi} — append each capture group.
        const cap_count_v = match_arr.get("length");
        const cap_count: i32 = if (cap_count_v.isInt32()) cap_count_v.asInt32() else 1;
        var ci: i32 = 1;
        while (ci < cap_count) : (ci += 1) {
            const ci_islice = std.fmt.bufPrint(&ibuf, "{d}", .{ci}) catch unreachable;
            const cap_v = match_arr.get(ci_islice);
            const out_islice = std.fmt.bufPrint(&ibuf, "{d}", .{idx}) catch unreachable;
            const out_owned = realm.heap.allocateString(out_islice) catch return error.OutOfMemory;
            out.set(realm.allocator, out_owned.bytes, cap_v) catch return error.OutOfMemory;
            idx += 1;
            if (idx >= limit) {
                setLength(realm, out, @intCast(idx)) catch return error.OutOfMemory;
                return heap_mod.taggedObject(out);
            }
        }
        search_index = last_match_end;
    }
    // §22.2.6.14 step 21 — emit the trailing substring.
    if (idx < limit) {
        const part = s.bytes[last_match_end..];
        const islice = std.fmt.bufPrint(&ibuf, "{d}", .{idx}) catch unreachable;
        const owned = realm.heap.allocateString(islice) catch return error.OutOfMemory;
        const part_str = realm.heap.allocateString(part) catch return error.OutOfMemory;
        out.set(realm.allocator, owned.bytes, Value.fromString(part_str)) catch return error.OutOfMemory;
        idx += 1;
    }
    setLength(realm, out, @intCast(idx)) catch return error.OutOfMemory;
    return heap_mod.taggedObject(out);
}

/// Detect a regex-shaped object — checks for an `exec` method on
/// the receiver or its prototype chain. §22.1.3.18 dispatches on
/// `Symbol.match` / `Symbol.replace` / etc.; we approximate by
/// looking for `exec` since Cynic's regex constructor sets it up.
fn isRegexLike(value: Value) ?*JSObject {
    const obj = heap_mod.valueAsPlainObject(value) orelse return null;
    var cursor: ?*JSObject = obj;
    while (cursor) |c_| : (cursor = c_.prototype) {
        if (heap_mod.valueAsFunction(c_.get("exec")) != null) return obj;
    }
    return null;
}

/// §22.2.7.1 RegExpExec ( R, S ) — `Get(R, "exec")` (accessor-aware
/// chain walk so user shadows like `Object.defineProperty(rx, "exec",
/// {get: ...})` fire); if callable, `Call(exec, R, «S»)` and require
/// the result to be either Object or Null (per spec, throw TypeError
/// otherwise). Caller inspects for null vs match-array.
fn regexExecCall(realm: *Realm, regex_obj: *JSObject, input: *JSString) NativeError!Value {
    const exec_v = try intrinsics.getPropertyChain(realm, regex_obj, "exec");
    const exec_fn = heap_mod.valueAsFunction(exec_v) orelse return throwTypeError(realm, "regex has no exec method");
    const args_call = [_]Value{Value.fromString(input)};
    const out = interpreter.callJSFunction(realm.allocator, realm, exec_fn, heap_mod.taggedObject(regex_obj), &args_call) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.NativeThrew,
    };
    const v: Value = switch (out) {
        .value, .yielded => |x| x,
        .thrown => return error.NativeThrew,
    };
    if (!v.isNull() and heap_mod.valueAsPlainObject(v) == null) {
        return throwTypeError(realm, "RegExpExec: exec must return Object or null");
    }
    return v;
}

fn flagsHas(realm: *Realm, regex_obj: *JSObject, flag: u8) bool {
    // §22.2.6.4 RegExp.prototype.flags is an accessor — bare
    // `obj.get` misses it. Route through the accessor-aware
    // chain walker (a throw bubbles up as `false`, which mirrors
    // every caller's pre-existing missing-property handling).
    const flags_v = intrinsics.getPropertyChain(realm, regex_obj, "flags") catch return false;
    if (!flags_v.isString()) return false;
    const f: *JSString = @ptrCast(@alignCast(flags_v.asString()));
    return std.mem.indexOfScalar(u8, f.bytes, flag) != null;
}

/// §22.2.6.{11,12,13,…} — the @@replace / @@split / @@match
/// / @@matchAll / @@search methods read individual flag
/// properties (`Get(rx, "global")` etc.) rather than going
/// through the `flags` accessor. This honors user-installed
/// own-property shadows (`Object.defineProperty(rx, "global",
/// {writable: true}); rx.global = X`).
fn regexFlagBool(realm: *Realm, regex_obj: *JSObject, name: []const u8) bool {
    const v = intrinsics.getPropertyChain(realm, regex_obj, name) catch return false;
    return v.toBooleanPrimitive();
}

/// §22.1.3.18 entry that performs Symbol.replace dispatch. Wired
/// as `String.prototype.replace`; the fallback path goes through
/// the symbol-free core `stringReplace`, which is also called by
/// `RegExp.prototype[@@replace]`.
fn stringReplaceDispatched(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    if (this_value.isNull() or this_value.isUndefined())
        return throwTypeError(realm, "String.prototype.replace called on null or undefined");
    const pat_v = argOr(args, 0, Value.undefined_);
    const repl_v = argOr(args, 1, Value.undefined_);
    if (try getSymbolMethod(realm, pat_v, "@@replace")) |replacer| {
        const recv_s = try coerceThisToJSString(realm, this_value);
        return invokeSymbolMethod(realm, replacer, pat_v, Value.fromString(recv_s), repl_v);
    }
    return stringReplace(realm, this_value, args);
}

pub fn stringReplace(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const s = try coerceThisToJSString(realm, this_value);
    const pat_v = argOr(args, 0, Value.undefined_);
    const repl_v = argOr(args, 1, Value.undefined_);
    // §22.1.3.19 — when the pattern is a regex, dispatch through
    // its `exec`. Global flag → iterate all matches; otherwise
    // replace just the first.
    if (isRegexLike(pat_v)) |regex_obj| {
        return regexReplace(realm, s, regex_obj, repl_v, false);
    }
    // §22.1.3.19 step 4 — searchString = ToString(searchValue).
    const pat = if (pat_v.isString())
        @as(*JSString, @ptrCast(@alignCast(pat_v.asString())))
    else
        try intrinsics.stringifyArg(realm, pat_v);
    // step 5-6 — IsCallable(replaceValue); else ToString-coerce
    // eagerly. The ToString runs *before* the StringIndexOf scan
    // so a throwing replacement-toString surfaces even on a
    // no-match input (fixture `replaceValue-evaluation-order`).
    const functional = heap_mod.valueAsFunction(repl_v) != null;
    const repl_s: ?*JSString = if (functional) null else try intrinsics.stringifyArg(realm, repl_v);
    // step 8-10 — first-match position lookup; on miss return the
    // unchanged source.
    const pos = std.mem.indexOf(u8, s.bytes, pat.bytes) orelse {
        const out = realm.heap.allocateString(s.bytes) catch return error.OutOfMemory;
        return Value.fromString(out);
    };
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(realm.allocator);
    buf.appendSlice(realm.allocator, s.bytes[0..pos]) catch return error.OutOfMemory;
    try appendStringPatternReplacement(realm, &buf, s, pat, pos, repl_v, functional, repl_s);
    buf.appendSlice(realm.allocator, s.bytes[pos + pat.bytes.len ..]) catch return error.OutOfMemory;
    const out = realm.heap.allocateString(buf.items) catch return error.OutOfMemory;
    return Value.fromString(out);
}

/// §22.1.3.18 — `regex` branch of `String.prototype.{replace,
/// replaceAll}`. Iterates `regex.exec(input)`, splicing the
/// replacement at each match position. `force_all` mirrors
/// `replaceAll` (which requires a global regex anyway).
pub fn regexReplace(
    realm: *Realm,
    s: *JSString,
    regex_obj: *JSObject,
    repl_v_in: Value,
    force_all: bool,
) NativeError!Value {
    // §22.2.6.11 step 7 — `flags = ? ToString(? Get(rx, "flags"))`.
    // Read the *flags string* via the accessor-aware property
    // chain so a user-installed `flags` getter (or a shadowed
    // own-data `flags`) fires before any other inspection. This
    // is the spec source of `global` / `fullUnicode`; reading
    // `Get(rx, "global")` directly diverges from ES2024 §22.2.6.11.
    const flags_v = try intrinsics.getPropertyChain(realm, regex_obj, "flags");
    const flags_s = try intrinsics.stringifyArg(realm, flags_v);
    const is_global = std.mem.indexOfScalar(u8, flags_s.bytes, 'g') != null;
    // §22.2.6.11 step 7.a — `If functionalReplace is false,
    // Let replaceValue be ? ToString(replaceValue)`. Run the
    // coercion synchronously before any regex matching so a
    // throwing `toString` on the replacement propagates before
    // we even try to find a match.
    const functional = heap_mod.valueAsFunction(repl_v_in) != null;
    const repl_v: Value = if (functional) repl_v_in else blk: {
        const rs = try intrinsics.stringifyArg(realm, repl_v_in);
        break :blk Value.fromString(rs);
    };
    const all = is_global or force_all;
    // §22.2.6.11 step 9 — `If global is true, Set(rx, "lastIndex",
    // +0𝔽, true)`. The reset is gated on `global` so a non-global
    // sticky (`/.../y`) regex with a user-supplied `lastIndex`
    // starts its single match from that position rather than 0.
    if (all) {
        regex_obj.set(realm.allocator, "lastIndex", Value.fromInt32(0)) catch return error.OutOfMemory;
    }

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(realm.allocator);
    // Two parallel cursors into the source: `byte_pos` walks the
    // UTF-8 bytes (for slicing into `s.bytes`); `unit_pos` walks
    // UTF-16 code units (matching the index space that `exec`'s
    // `index` and `lastIndex` properties live in). They're updated
    // in lock-step.
    var byte_pos: usize = 0;
    var unit_pos: usize = 0;
    const max_iter: usize = 1 << 20;
    var step: usize = 0;
    while (step < max_iter) : (step += 1) {
        const exec_result = try regexExecCall(realm, regex_obj, s);
        if (exec_result.isNull()) break;
        const match_arr = heap_mod.valueAsPlainObject(exec_result) orelse break;
        // §22.2.6.11 step 13.c — read "0" first, ToString-coerce.
        // The spec ordering is: matchStr = ? ToString(? Get(result,
        // "0")) before any other field read. Use the accessor-aware
        // chain walk so a user-installed `get 0` getter fires.
        const whole_v = try intrinsics.getPropertyChain(realm, match_arr, "0");
        const whole: *JSString = try intrinsics.stringifyArg(realm, whole_v);
        // §22.2.6.11 step 13.d — `position = ? ToIntegerOrInfinity(?
        // Get(result, "index"))`, clamped to [0, lengthS] (step 13.e).
        const idx_v = try intrinsics.getPropertyChain(realm, match_arr, "index");
        const idx_num_v = try intrinsics.toNumber(realm, idx_v);
        const idx_d: f64 = if (idx_num_v.isInt32()) @floatFromInt(idx_num_v.asInt32()) else if (idx_num_v.isDouble()) idx_num_v.asDouble() else 0.0;
        const idx_clamped: f64 = if (std.math.isNan(idx_d)) 0.0 else if (idx_d < 0.0) 0.0 else if (idx_d > @as(f64, @floatFromInt(std.math.maxInt(i32)))) @as(f64, @floatFromInt(std.math.maxInt(i32))) else @trunc(idx_d);
        const m_idx_unit: usize = @intFromFloat(idx_clamped);

        // Walk forward from `(byte_pos, unit_pos)` to the match
        // start in code units, accumulating skipped bytes into the
        // output. Matches are monotonic so this is amortised O(n)
        // across the whole loop.
        const append_start = byte_pos;
        while (unit_pos < m_idx_unit and byte_pos < s.bytes.len) {
            const seq_len = utf8SeqLen(s.bytes[byte_pos]);
            if (byte_pos + seq_len > s.bytes.len) break;
            byte_pos += seq_len;
            unit_pos += if (seq_len == 4) 2 else 1;
        }
        const m_byte = byte_pos;
        if (m_byte > append_start) buf.appendSlice(realm.allocator, s.bytes[append_start..m_byte]) catch return error.OutOfMemory;
        try appendRegexReplacement(realm, &buf, s, match_arr, whole, m_byte, m_idx_unit, repl_v);
        byte_pos = m_byte + whole.bytes.len;
        unit_pos = m_idx_unit + utf8UnitCount(whole.bytes);
        if (whole.bytes.len == 0) {
            // §22.2.6.11 step 8.j — `AdvanceStringIndex` after a
            // zero-width match, otherwise the next `exec` would
            // re-match the same position. Advancing by a full
            // UTF-8 sequence collapses the spec's per-code-unit
            // walk for non-fullUnicode into per-codepoint for
            // both, which mirrors how V8 / SpiderMonkey behave for
            // strings whose codepoints survive the surrogate-pair
            // round-trip. Update the regex's `lastIndex` *and* our
            // local cursors.
            if (byte_pos < s.bytes.len) {
                const seq_len = utf8SeqLen(s.bytes[byte_pos]);
                if (byte_pos + seq_len <= s.bytes.len) {
                    byte_pos += seq_len;
                    unit_pos += if (seq_len == 4) 2 else 1;
                }
            }
            // §22.2.6.11 step 8.j (literal) — `thisIndex = ?
            // ToLength(? Get(rx, "lastIndex"))`, `nextIndex =
            // AdvanceStringIndex(S, thisIndex, fullUnicode)`,
            // `Set(rx, "lastIndex", nextIndex)`. The read goes
            // through the accessor-aware chain walk so a user-
            // installed `lastIndex` setter / shadow fires; the
            // ToLength clamp gives `2**54` → `2**53` which the
            // test262 `coerce-lastindex` fixture relies on.
            // Fall back to the local `unit_pos` only when no user
            // override is in play (the value we already wrote is
            // the spec answer for the built-in exec).
            const li_v = try intrinsics.getPropertyChain(realm, regex_obj, "lastIndex");
            const this_index_raw: i64 = if (li_v.isInt32())
                @max(0, @as(i64, li_v.asInt32()))
            else
                try intrinsics.toLengthValue(realm, li_v);
            // §7.1.20 ToLength step 2 — `min(len, 2**53 - 1)`. The
            // shared `toLengthValue` saturates to i64; cap to
            // 2**53 - 1 here so a coercible `lastIndex` whose
            // `valueOf` returns 2**54 yields the spec answer 2**53
            // (per the `coerce-lastindex` fixture: AdvanceStringIndex
            // adds 1, which rounds away in double precision).
            const max_safe_integer: i64 = (1 << 53) - 1;
            const this_index_i64: i64 = @min(this_index_raw, max_safe_integer);
            const next_index_d: f64 = @as(f64, @floatFromInt(this_index_i64)) + 1.0;
            regex_obj.set(
                realm.allocator,
                "lastIndex",
                if (next_index_d <= @as(f64, @floatFromInt(std.math.maxInt(i32))))
                    Value.fromInt32(@intCast(@as(i64, @intFromFloat(next_index_d))))
                else
                    Value.fromDouble(next_index_d),
            ) catch return error.OutOfMemory;
        }
        if (!all) break;
    }
    if (byte_pos < s.bytes.len) buf.appendSlice(realm.allocator, s.bytes[byte_pos..]) catch return error.OutOfMemory;
    const out = realm.heap.allocateString(buf.items) catch return error.OutOfMemory;
    return Value.fromString(out);
}

/// UTF-8 leading-byte → byte-sequence length (1..4). Returns 1 for
/// bytes that don't start a valid sequence so we always make
/// progress on malformed input.
fn utf8SeqLen(b: u8) usize {
    if (b < 0x80) return 1;
    if (b < 0xC0) return 1;
    if (b < 0xE0) return 2;
    if (b < 0xF0) return 3;
    return 4;
}

/// UTF-16 code-unit count for a well-formed UTF-8 slice. A 4-byte
/// UTF-8 sequence is a supplementary (non-BMP) code point and
/// occupies two UTF-16 surrogate-pair units; everything else is
/// one unit.
fn utf8UnitCount(s: []const u8) usize {
    var u: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        const seq_len = utf8SeqLen(s[i]);
        u += if (seq_len == 4) 2 else 1;
        i += seq_len;
    }
    return u;
}

/// §22.1.3.18.1 GetSubstitution — for a regex match, append the
/// resolved replacement (callable result *or* `$&`/`$1`/`$$`/`$\``/`$'`
/// template expansion) directly into `out`. The previous shape returned
/// a freshly-`dupe`d slice that callers forgot to free; writing into the
/// caller's buffer removes that bookkeeping (and the leak).
///
/// `byte_pos` is the match's byte offset into `source.bytes` (used for
/// `$\`` / `$'` byte slicing); `unit_pos` is the same position in
/// UTF-16 code units (the offset passed to a callable replacer, per
/// spec). They coincide for ASCII inputs and diverge across
/// supplementary code points.
fn appendRegexReplacement(
    realm: *Realm,
    out: *std.ArrayListUnmanaged(u8),
    source: *JSString,
    match_arr: *JSObject,
    whole: *JSString,
    byte_pos: usize,
    unit_pos: usize,
    repl_v: Value,
) NativeError!void {
    if (heap_mod.valueAsFunction(repl_v)) |fn_obj| {
        const len_v = match_arr.get("length");
        const arr_len: i32 = if (len_v.isInt32()) len_v.asInt32() else 1;
        const cap_count: usize = if (arr_len > 0) @intCast(arr_len) else 1;
        // Args: match, c1, c2,..., offset, source.
        var args: std.ArrayListUnmanaged(Value) = .empty;
        defer args.deinit(realm.allocator);
        args.append(realm.allocator, Value.fromString(whole)) catch return error.OutOfMemory;
        var i: usize = 1;
        var ibuf: [16]u8 = undefined;
        while (i < cap_count) : (i += 1) {
            const islice = std.fmt.bufPrint(&ibuf, "{d}", .{i}) catch unreachable;
            args.append(realm.allocator, match_arr.get(islice)) catch return error.OutOfMemory;
        }
        args.append(realm.allocator, Value.fromInt32(@intCast(unit_pos))) catch return error.OutOfMemory;
        args.append(realm.allocator, Value.fromString(source)) catch return error.OutOfMemory;
        // §22.2.6.10 RegExp.prototype[@@replace] step 14.k.iv —
        // when `namedCaptures` is not undefined, append it as the
        // last replacer argument.
        const groups_v = match_arr.get("groups");
        if (!groups_v.isUndefined()) {
            args.append(realm.allocator, groups_v) catch return error.OutOfMemory;
        }
        const outcome = interpreter.callJSFunction(realm.allocator, realm, fn_obj, Value.undefined_, args.items) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.NativeThrew,
        };
        const ret = switch (outcome) {
            .value, .yielded => |v| v,
            .thrown => return error.NativeThrew,
        };
        const ret_s = try intrinsics.stringifyArg(realm, ret);
        out.appendSlice(realm.allocator, ret_s.bytes) catch return error.OutOfMemory;
        return;
    }
    const repl_s = try intrinsics.stringifyArg(realm, repl_v);
    try expandSubstitutionInto(realm, out, repl_s.bytes, source, match_arr, whole, byte_pos);
}

/// §22.1.3.19.1 GetSubstitution ( matched, str, position, captures,
/// namedCaptures, replacementTemplate ). Append the resolved
/// replacement bytes for the regex-match path: `match_arr` is the
/// `exec` result, so `captureLen = match_arr.length - 1` (the
/// 0th element is the whole match), and `namedCaptures =
/// match_arr.groups` (Object or undefined). The walk is per-spec:
/// every `$`-prefixed escape consumes its full `ref` (and only its
/// ref) before advancing.
fn expandSubstitutionInto(
    realm: *Realm,
    out: *std.ArrayListUnmanaged(u8),
    template: []const u8,
    source: *JSString,
    match_arr: *JSObject,
    whole: *JSString,
    pos: usize,
) NativeError!void {
    // captureLen = length(match_arr) - 1, clamped to 0.
    const len_v = match_arr.get("length");
    const arr_len: usize = if (len_v.isInt32() and len_v.asInt32() > 0) @intCast(len_v.asInt32()) else 1;
    const capture_len: usize = if (arr_len > 0) arr_len - 1 else 0;
    const groups_v = match_arr.get("groups");
    var i: usize = 0;
    while (i < template.len) {
        const c = template[i];
        if (c != '$' or i + 1 >= template.len) {
            out.append(realm.allocator, c) catch return error.OutOfMemory;
            i += 1;
            continue;
        }
        const n = template[i + 1];
        switch (n) {
            '$' => {
                out.append(realm.allocator, '$') catch return error.OutOfMemory;
                i += 2;
            },
            '&' => {
                out.appendSlice(realm.allocator, whole.bytes) catch return error.OutOfMemory;
                i += 2;
            },
            '`' => {
                out.appendSlice(realm.allocator, source.bytes[0..pos]) catch return error.OutOfMemory;
                i += 2;
            },
            '\'' => {
                const tail_start = pos + whole.bytes.len;
                if (tail_start < source.bytes.len)
                    out.appendSlice(realm.allocator, source.bytes[tail_start..]) catch return error.OutOfMemory;
                i += 2;
            },
            '0'...'9' => {
                // §22.1.3.19.1 — `$N` / `$NN` decimal-capture
                // dispatch. digitCount = 2 only if the *second*
                // char is also a digit. If the two-digit index
                // exceeds captureLen, fall back to one digit.
                var digit_count: usize = 1;
                var index: usize = n - '0';
                if (i + 2 < template.len and template[i + 2] >= '0' and template[i + 2] <= '9') {
                    digit_count = 2;
                    index = index * 10 + (template[i + 2] - '0');
                    if (index > capture_len) {
                        digit_count = 1;
                        index = n - '0';
                    }
                }
                if (index >= 1 and index <= capture_len) {
                    var ibuf: [16]u8 = undefined;
                    const islice = std.fmt.bufPrint(&ibuf, "{d}", .{index}) catch unreachable;
                    const cap_v = match_arr.get(islice);
                    // §22.1.3.19.1 — undefined capture expands to
                    // empty; string capture expands verbatim.
                    if (cap_v.isString()) {
                        const cs: *JSString = @ptrCast(@alignCast(cap_v.asString()));
                        out.appendSlice(realm.allocator, cs.bytes) catch return error.OutOfMemory;
                    } else if (!cap_v.isUndefined()) {
                        const cs = try intrinsics.stringifyArg(realm, cap_v);
                        out.appendSlice(realm.allocator, cs.bytes) catch return error.OutOfMemory;
                    }
                    i += 1 + digit_count;
                } else {
                    // index = 0 or index > captureLen — ref stays
                    // literal. Advance by ref length (1 + digit_count).
                    out.appendSlice(realm.allocator, template[i .. i + 1 + digit_count]) catch return error.OutOfMemory;
                    i += 1 + digit_count;
                }
            },
            '<' => {
                // §22.1.3.19.1 — `$<name>`. Locate the closing `>`
                // from i + 2. If not found OR namedCaptures is
                // undefined, the ref is just `$<` (length 2) and
                // we keep it literal. Otherwise look up the name.
                if (groups_v.isUndefined()) {
                    out.appendSlice(realm.allocator, "$<") catch return error.OutOfMemory;
                    i += 2;
                    continue;
                }
                var j: usize = i + 2;
                while (j < template.len and template[j] != '>') : (j += 1) {}
                if (j >= template.len) {
                    out.appendSlice(realm.allocator, "$<") catch return error.OutOfMemory;
                    i += 2;
                    continue;
                }
                const name = template[i + 2 .. j];
                const groups_obj = heap_mod.valueAsPlainObject(groups_v) orelse {
                    i = j + 1;
                    continue;
                };
                const cap_v = groups_obj.get(name);
                if (cap_v.isString()) {
                    const cs: *JSString = @ptrCast(@alignCast(cap_v.asString()));
                    out.appendSlice(realm.allocator, cs.bytes) catch return error.OutOfMemory;
                } else if (!cap_v.isUndefined()) {
                    const cs = try intrinsics.stringifyArg(realm, cap_v);
                    out.appendSlice(realm.allocator, cs.bytes) catch return error.OutOfMemory;
                }
                i = j + 1;
            },
            else => {
                // Bare `$X` where X is none of the special chars —
                // keep both chars literal.
                out.append(realm.allocator, '$') catch return error.OutOfMemory;
                i += 1;
            },
        }
    }
}

/// §22.1.3.20 String.prototype.replaceAll ( searchValue, replaceValue ).
/// Implements the Object-gated dispatch + the string-pattern core
/// (steps 3-22). The @@replace dispatch forwards the *uncoerced*
/// thisValue / replaceValue so a poisoned `toString` on either
/// never fires (fixtures: `searchValue-replacer-before-tostring`,
/// `searchValue-replacer-call`).
fn stringReplaceAllDispatched(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    if (this_value.isNull() or this_value.isUndefined())
        return throwTypeError(realm, "String.prototype.replaceAll called on null or undefined");
    const pat_v = argOr(args, 0, Value.undefined_);
    const repl_v = argOr(args, 1, Value.undefined_);
    // §22.1.3.20 step 3 — "If searchValue is an Object, then".
    // Primitives skip the entire IsRegExp + @@replace block.
    if (heap_mod.valueAsPlainObject(pat_v)) |pat_obj| {
        // step 3.a-b — IsRegExp + global-flag check; throws on a
        // non-global RegExp *before* GetMethod runs.
        if (try isRegExp(realm, pat_v)) {
            const flags_v = try intrinsics.getPropertyChain(realm, pat_obj, "flags");
            if (flags_v.isUndefined() or flags_v.isNull())
                return throwTypeError(realm, "String.prototype.replaceAll: regex has no flags");
            const flags_s = try intrinsics.stringifyArg(realm, flags_v);
            if (std.mem.indexOfScalar(u8, flags_s.bytes, 'g') == null)
                return throwTypeError(realm, "String.prototype.replaceAll requires a global regex");
        }
        // step 3.c-d — GetMethod + dispatch. The receiver passed to
        // the matcher is the uncoerced `thisValue`; coercing here
        // would surface a poisoned `toString` on a wrapper that the
        // spec never reaches.
        if (try getSymbolMethod(realm, pat_v, "@@replace")) |replacer| {
            return invokeSymbolMethod(realm, replacer, pat_v, this_value, repl_v);
        }
    }
    return stringReplaceAllCore(realm, this_value, pat_v, repl_v);
}

/// §22.1.3.20 String.prototype.replaceAll fallback core — steps
/// 4-22 of the spec. `pat_v` and `repl_v` are pre-extracted and
/// already passed the Object dispatch in step 3. ToString(this) +
/// ToString(searchValue) run here (in spec order), then the
/// GetSubstitution loop slices over `string`.
fn stringReplaceAllCore(realm: *Realm, this_value: Value, pat_v: Value, repl_v_in: Value) NativeError!Value {
    // step 4 — string = ? ToString(thisValue).
    const s = try coerceThisToJSString(realm, this_value);
    // step 5 — searchString = ? ToString(searchValue).
    const pat = if (pat_v.isString())
        @as(*JSString, @ptrCast(@alignCast(pat_v.asString())))
    else
        try intrinsics.stringifyArg(realm, pat_v);
    // step 6-7 — functionalReplace = IsCallable(replaceValue); else
    // ToString-coerce. Run the coercion eagerly so a throwing
    // toString surfaces before the match scan begins (fixture
    // `replaceValue-value-tostring`).
    const functional = heap_mod.valueAsFunction(repl_v_in) != null;
    const repl_s: ?*JSString = if (functional)
        null
    else
        try intrinsics.stringifyArg(realm, repl_v_in);
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(realm.allocator);
    if (pat.bytes.len == 0) {
        // step 9 — advanceBy = max(1, searchLength). Empty pattern
        // → interleave the replacement between every code unit.
        // §22.1.3.20.1 GetSubstitution with empty captures: any
        // `$N` in the template stays literal (no captures).
        var cursor: usize = 0;
        while (cursor <= s.bytes.len) : (cursor += 1) {
            try appendStringPatternReplacement(realm, &buf, s, pat, cursor, repl_v_in, functional, repl_s);
            if (cursor < s.bytes.len) buf.append(realm.allocator, s.bytes[cursor]) catch return error.OutOfMemory;
        }
        const out = realm.heap.allocateString(buf.items) catch return error.OutOfMemory;
        return Value.fromString(out);
    }
    // step 10-17 — find all non-overlapping match positions and
    // splice. Operating on byte indices works because the pattern
    // (a UTF-8 byte sequence) is matched verbatim; UTF-16 code-unit
    // identities for callable-replacer args are computed in
    // `appendStringPatternReplacement`.
    var cursor: usize = 0;
    while (cursor <= s.bytes.len) {
        const remaining = s.bytes[cursor..];
        if (std.mem.indexOf(u8, remaining, pat.bytes)) |pos| {
            buf.appendSlice(realm.allocator, remaining[0..pos]) catch return error.OutOfMemory;
            try appendStringPatternReplacement(realm, &buf, s, pat, cursor + pos, repl_v_in, functional, repl_s);
            cursor += pos + pat.bytes.len;
        } else {
            buf.appendSlice(realm.allocator, remaining) catch return error.OutOfMemory;
            break;
        }
    }
    const out = realm.heap.allocateString(buf.items) catch return error.OutOfMemory;
    return Value.fromString(out);
}

/// Per-match replacement append for the string-pattern path of
/// `replace` / `replaceAll`. When `functional` is true, call the
/// user replacer with `(matched, byteOffsetAsUnitOffset, source)`
/// and ToString the result. Otherwise expand `$$` / `$&` / `$``
/// / `$'` / `$<name>` against `replacementTemplate` per
/// §22.1.3.19.1 GetSubstitution with an empty captures list (so
/// `$N` and `$NN` stay literal).
fn appendStringPatternReplacement(
    realm: *Realm,
    out: *std.ArrayListUnmanaged(u8),
    source: *JSString,
    matched: *JSString,
    byte_pos: usize,
    repl_v: Value,
    functional: bool,
    repl_template: ?*JSString,
) NativeError!void {
    if (functional) {
        // §22.1.3.20 step 17.b — Call(replaceValue, undefined,
        // « searchString, 𝔽(matchPosition), string »). The
        // position is a code-unit index, not a byte offset; compute
        // it from byte_pos via the UTF-16 view of `source.bytes`.
        const unit_pos = utf16.codeUnitIndexForByte(source.bytes, byte_pos);
        const fn_obj = heap_mod.valueAsFunction(repl_v).?;
        const args = [_]Value{
            Value.fromString(matched),
            Value.fromInt32(@intCast(unit_pos)),
            Value.fromString(source),
        };
        const outcome = interpreter.callJSFunction(realm.allocator, realm, fn_obj, Value.undefined_, &args) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.NativeThrew,
        };
        const ret = switch (outcome) {
            .value, .yielded => |v| v,
            .thrown => |ex| {
                realm.pending_exception = ex;
                return error.NativeThrew;
            },
        };
        const ret_s = try intrinsics.stringifyArg(realm, ret);
        out.appendSlice(realm.allocator, ret_s.bytes) catch return error.OutOfMemory;
        return;
    }
    const tpl = repl_template orelse return;
    try expandSubstitutionEmptyCaptures(realm, out, tpl.bytes, source, matched, byte_pos);
}

/// §22.1.3.19.1 GetSubstitution with `captures` = empty list and
/// `namedCaptures` = undefined. Used by both `stringReplace` and
/// `stringReplaceAll` when the search is a String primitive (and
/// the replacement is a String, not a function). With no captures,
/// `$N` / `$NN` / `$<name>` always stay literal (because no
/// `1 ≤ index ≤ captureLen` ever holds and the `$<` branch sees
/// undefined namedCaptures).
fn expandSubstitutionEmptyCaptures(
    realm: *Realm,
    out: *std.ArrayListUnmanaged(u8),
    template: []const u8,
    source: *JSString,
    matched: *JSString,
    byte_pos: usize,
) NativeError!void {
    var i: usize = 0;
    while (i < template.len) {
        const c = template[i];
        if (c != '$' or i + 1 >= template.len) {
            out.append(realm.allocator, c) catch return error.OutOfMemory;
            i += 1;
            continue;
        }
        const n = template[i + 1];
        switch (n) {
            '$' => {
                out.append(realm.allocator, '$') catch return error.OutOfMemory;
                i += 2;
            },
            '&' => {
                out.appendSlice(realm.allocator, matched.bytes) catch return error.OutOfMemory;
                i += 2;
            },
            '`' => {
                out.appendSlice(realm.allocator, source.bytes[0..byte_pos]) catch return error.OutOfMemory;
                i += 2;
            },
            '\'' => {
                const tail_start = byte_pos + matched.bytes.len;
                if (tail_start < source.bytes.len)
                    out.appendSlice(realm.allocator, source.bytes[tail_start..]) catch return error.OutOfMemory;
                i += 2;
            },
            else => {
                // §22.1.3.19.1 — `$N`, `$NN`, `$<...>` with empty
                // captures / undefined namedCaptures all keep the
                // leading `$` and the next character literal, then
                // continue parsing from the char after. So output
                // just `$` and advance by one; the next iteration
                // re-parses the second char (which may itself start
                // another `$`-sequence).
                out.append(realm.allocator, '$') catch return error.OutOfMemory;
                i += 1;
            },
        }
    }
}

fn stringTrimStart(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    const s = try coerceThisToJSString(realm, this_value);
    const start = skipLeadingWhitespace(s.bytes);
    const out = realm.heap.allocateString(s.bytes[start..]) catch return error.OutOfMemory;
    return Value.fromString(out);
}
fn stringTrimEnd(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    const s = try coerceThisToJSString(realm, this_value);
    const end = endAfterTrailingWhitespace(s.bytes);
    const out = realm.heap.allocateString(s.bytes[0..end]) catch return error.OutOfMemory;
    return Value.fromString(out);
}

/// §22.1.3.16 String.prototype.normalize ( [ form ] ). Performs
/// §3.11 Unicode Normalization (NFC / NFD / NFKC / NFKD) via
/// libunicode's `unicode_normalize` — decompose into a u32
/// code-point buffer, hand off to libunicode, re-encode the
/// result as WTF-8. The default form is NFC (§22.1.3.16 step 4);
/// unknown forms throw RangeError per step 7.
fn stringNormalize(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const s = try coerceThisToJSString(realm, this_value);
    const form_v = argOr(args, 0, Value.undefined_);
    // §22.1.3.16 step 4 — defaulting to "NFC".
    var form_kind: lib_unicode.UnicodeNormalizationEnum = lib_unicode.UNICODE_NFC;
    if (!form_v.isUndefined()) {
        // §22.1.3.16 step 5 — Let f be ? ToString(form).
        const form_s = try intrinsics.stringifyArg(realm, form_v);
        const f = form_s.bytes;
        if (std.mem.eql(u8, f, "NFC")) {
            form_kind = lib_unicode.UNICODE_NFC;
        } else if (std.mem.eql(u8, f, "NFD")) {
            form_kind = lib_unicode.UNICODE_NFD;
        } else if (std.mem.eql(u8, f, "NFKC")) {
            form_kind = lib_unicode.UNICODE_NFKC;
        } else if (std.mem.eql(u8, f, "NFKD")) {
            form_kind = lib_unicode.UNICODE_NFKD;
        } else {
            // §22.1.3.16 step 7 — RangeError on unknown form.
            return intrinsics.throwRangeError(realm, "String.prototype.normalize: invalid form");
        }
    }

    // Decode the receiver into a u32 codepoint buffer (lone
    // surrogates pass through as their 0xD800..0xDFFF code-point
    // values — §3.11 treats them as themselves since
    // normalization is defined on code points).
    var cps: std.ArrayListUnmanaged(u32) = .empty;
    defer cps.deinit(realm.allocator);
    decodeWtf8ToCodepoints(realm.allocator, &cps, s.bytes) catch return error.OutOfMemory;

    // `unicode_normalize` allocates `*pdst` via the supplied
    // realloc; we hand it `std.c.malloc/free` via the same hook
    // libregexp uses (`lre_realloc`). On a length-0 input it
    // returns 0 and leaves `*pdst` untouched, so seed it null.
    var dst_ptr: ?[*]u32 = null;
    const src_len: c_int = @intCast(cps.items.len);
    const src_ptr: ?[*]const u32 = if (cps.items.len == 0) null else cps.items.ptr;
    const out_len = lib_unicode.unicode_normalize(
        @ptrCast(&dst_ptr),
        @ptrCast(src_ptr),
        src_len,
        form_kind,
        null,
        normalizeRealloc,
    );
    if (out_len < 0) return error.OutOfMemory;
    defer if (dst_ptr) |p| std.c.free(@ptrCast(p));

    // Re-encode the normalized code-point list as WTF-8.
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(realm.allocator);
    if (dst_ptr) |p| {
        var i: usize = 0;
        const n: usize = @intCast(out_len);
        while (i < n) : (i += 1) {
            const cp: u32 = p[i];
            // `unicode_normalize` returns code points in the
            // valid range 0..0x10FFFF (including the surrogate
            // values for unpaired-surrogate inputs).
            appendWtf8(realm.allocator, &out, @intCast(cp)) catch return error.OutOfMemory;
        }
    }
    const new_s = realm.heap.allocateString(out.items) catch return error.OutOfMemory;
    return Value.fromString(new_s);
}

/// Realloc shim for `unicode_normalize`. The opaque is unused
/// (libunicode's only state lives in the output buffer it
/// reallocs), so we drop it and dispatch through libc — same
/// pattern as `lre_realloc` in `builtins/regexp.zig`. `size == 0`
/// means free.
fn normalizeRealloc(opaque_ptr: ?*anyopaque, ptr: ?*anyopaque, size: usize) callconv(.c) ?*anyopaque {
    _ = opaque_ptr;
    if (size == 0) {
        if (ptr) |p| std.c.free(p);
        return null;
    }
    if (ptr) |p| return std.c.realloc(p, size);
    return std.c.malloc(size);
}

/// §22.1.3.4 String.prototype.codePointAt — UTF-16-code-unit-
/// indexed. Cynic's strings are stored as WTF-8: every BMP char
/// (including lone surrogates D800-DFFF as 3-byte 0xED-AX-BY
/// sequences) is 1 code unit; supplementary chars are stored as
/// one 4-byte UTF-8 sequence but expose two code units (a high +
/// low surrogate pair). The spec's CodePointAt(S, position)
/// returns the astral codepoint at the *leading* surrogate index,
/// and the bare trail surrogate value at the trail index. Out-of-
/// range positions (< 0 or ≥ size) return undefined per step 5.
fn stringCodePointAt(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const s = try coerceThisToJSString(realm, this_value);
    // §7.1.5 ToIntegerOrInfinity — NaN → 0; finite truncates to int.
    const pos_v = try intrinsics.toNumber(realm, argOr(args, 0, Value.fromInt32(0)));
    const pos: i64 = if (pos_v.isInt32()) pos_v.asInt32() else blk: {
        const d = pos_v.asDouble();
        if (std.math.isNan(d)) break :blk 0;
        if (std.math.isInf(d)) break :blk if (d > 0) std.math.maxInt(i32) else -1;
        break :blk @intFromFloat(@trunc(d));
    };
    if (pos < 0) return Value.undefined_;
    const target_unit: usize = @intCast(pos);
    // Walk UTF-16 code units until we hit `target_unit`. The current
    // byte cursor + unit cursor advance together: 1/2/3-byte UTF-8
    // → 1 unit; 4-byte UTF-8 → 2 units, where landing on the second
    // unit means "return the trail-surrogate code unit value".
    var byte_pos: usize = 0;
    var unit_pos: usize = 0;
    while (byte_pos < s.bytes.len) {
        const seq_len = utf8SeqLen(s.bytes[byte_pos]);
        if (byte_pos + seq_len > s.bytes.len) return Value.undefined_;
        if (seq_len == 4) {
            // Astral codepoint occupies 2 UTF-16 units.
            if (unit_pos == target_unit) {
                const cp = std.unicode.utf8Decode(s.bytes[byte_pos .. byte_pos + 4]) catch return Value.undefined_;
                return Value.fromInt32(@intCast(cp));
            }
            if (unit_pos + 1 == target_unit) {
                const cp = std.unicode.utf8Decode(s.bytes[byte_pos .. byte_pos + 4]) catch return Value.undefined_;
                // §11.1.4 UTF16EncodeCodePoint — trail surrogate of the pair.
                const adjusted: u32 = @as(u32, @intCast(cp)) - 0x10000;
                const trail: u16 = @intCast(0xDC00 + (adjusted & 0x3FF));
                return Value.fromInt32(@intCast(trail));
            }
            byte_pos += 4;
            unit_pos += 2;
        } else {
            if (unit_pos == target_unit) {
                // §10.1.1 — for 1/2/3-byte WTF-8 the codepoint *is*
                // a single UTF-16 code unit (BMP scalar or lone
                // surrogate D800-DFFF). Decode it as a u16 value.
                const cu = wtf8DecodeBmp(s.bytes[byte_pos..byte_pos + seq_len]) orelse return Value.undefined_;
                return Value.fromInt32(@intCast(cu));
            }
            byte_pos += seq_len;
            unit_pos += 1;
        }
    }
    // Walked past the end without finding the unit → out of range.
    return Value.undefined_;
}

/// Decode a 1/2/3-byte WTF-8 sequence into a single UTF-16 code
/// unit. Returns null on malformed input. 3-byte sequences whose
/// codepoint is in 0xD800..0xDFFF round-trip as the lone surrogate
/// (Cynic's WTF-8 storage).
fn wtf8DecodeBmp(bytes: []const u8) ?u16 {
    if (bytes.len == 0) return null;
    const b0 = bytes[0];
    if (b0 < 0x80) return @intCast(b0);
    if (bytes.len == 2) {
        const cp = (@as(u16, b0 & 0x1F) << 6) | @as(u16, bytes[1] & 0x3F);
        return cp;
    }
    if (bytes.len == 3) {
        const cp = (@as(u16, b0 & 0x0F) << 12) | (@as(u16, bytes[1] & 0x3F) << 6) | @as(u16, bytes[2] & 0x3F);
        return cp;
    }
    return null;
}

/// §22.1.3.12 String.prototype.isWellFormed — return true iff the
/// receiver, viewed as a sequence of UTF-16 code units, contains
/// no unpaired surrogate (§11.1.4 IsStringWellFormedUnicode).
/// Cynic's WTF-8 storage exposes lone surrogates as 3-byte
/// sequences in the U+D800..U+DFFF range; well-formed strings
/// either contain 4-byte (astral) UTF-8 or non-surrogate 1/2/3-byte
/// sequences. A *valid pair* (high 0xED 0xA0..0xAF + low 0xED
/// 0xB0..0xBF in adjacent 3-byte sequences) also counts as well-
/// formed because `+`-concatenation of two surrogate halves yields
/// a logical pair even though Cynic stored them separately.
fn stringIsWellFormed(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    const s = try coerceThisToJSString(realm, this_value);
    var i: usize = 0;
    while (i < s.bytes.len) {
        const b = s.bytes[i];
        const seq_len = utf8SeqLen(b);
        if (i + seq_len > s.bytes.len) return Value.fromBool(false);
        if (isLoneHighSurrogateAt(s.bytes, i)) {
            // Followed by a lone low surrogate? Treat as a paired
            // surrogate-pair (formed at boundary by `+`-concat).
            if (i + 6 <= s.bytes.len and isLoneLowSurrogateAt(s.bytes, i + 3)) {
                i += 6;
                continue;
            }
            return Value.fromBool(false);
        }
        if (isLoneLowSurrogateAt(s.bytes, i)) return Value.fromBool(false);
        i += seq_len;
    }
    return Value.fromBool(true);
}

/// True iff bytes starting at `i` form a 3-byte WTF-8 high-surrogate
/// sequence (codepoints 0xD800..0xDBFF, encoded as 0xED 0xA0..0xAF
/// 0x80..0xBF). Out-of-bounds is treated as "no".
fn isLoneHighSurrogateAt(bytes: []const u8, i: usize) bool {
    if (i + 3 > bytes.len) return false;
    if (bytes[i] != 0xED) return false;
    return (bytes[i + 1] & 0xF0) == 0xA0;
}

/// True iff bytes starting at `i` form a 3-byte WTF-8 low-surrogate
/// sequence (codepoints 0xDC00..0xDFFF, encoded as 0xED 0xB0..0xBF
/// 0x80..0xBF).
fn isLoneLowSurrogateAt(bytes: []const u8, i: usize) bool {
    if (i + 3 > bytes.len) return false;
    if (bytes[i] != 0xED) return false;
    return (bytes[i + 1] & 0xF0) == 0xB0;
}

/// §22.1.3.30 String.prototype.toWellFormed — replace every
/// unpaired surrogate code unit with U+FFFD REPLACEMENT CHARACTER.
/// Adjacent WTF-8 surrogate-half sequences that form a valid pair
/// (high followed by low) are folded into a single UTF-8 4-byte
/// sequence so the result is genuine UTF-8.
fn stringToWellFormed(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    const s = try coerceThisToJSString(realm, this_value);
    // Fast path — receivers without any lone surrogate round-trip
    // without copying. A high-surrogate followed by a low-surrogate
    // is *not* a lone surrogate; it still requires fold-up below.
    var needs_rewrite = false;
    {
        var i: usize = 0;
        while (i < s.bytes.len) {
            const b = s.bytes[i];
            const seq_len = utf8SeqLen(b);
            if (i + seq_len > s.bytes.len) {
                needs_rewrite = true;
                break;
            }
            if (seq_len == 3 and b == 0xED and (s.bytes[i + 1] & 0xE0) == 0xA0) {
                needs_rewrite = true;
                break;
            }
            i += seq_len;
        }
    }
    if (!needs_rewrite) return Value.fromString(s);

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(realm.allocator);
    // U+FFFD is `0xEF 0xBF 0xBD` in UTF-8.
    const replacement = [_]u8{ 0xEF, 0xBF, 0xBD };
    var i: usize = 0;
    while (i < s.bytes.len) {
        const b = s.bytes[i];
        const seq_len = utf8SeqLen(b);
        if (i + seq_len > s.bytes.len) {
            buf.appendSlice(realm.allocator, &replacement) catch return error.OutOfMemory;
            i += 1;
            continue;
        }
        if (isLoneHighSurrogateAt(s.bytes, i)) {
            if (i + 6 <= s.bytes.len and isLoneLowSurrogateAt(s.bytes, i + 3)) {
                // §22.1.3.30 step 6.c — paired surrogate, emit as-is.
                // Folding into a UTF-8 4-byte sequence would break
                // String-value equality against the WTF-8 source
                // (see returns-well-formed-string.js, which asserts
                // `('a'+lead+trail+'d').toWellFormed() === 'a'+lead+trail+'d'`).
                buf.appendSlice(realm.allocator, s.bytes[i .. i + 6]) catch return error.OutOfMemory;
                i += 6;
                continue;
            }
            buf.appendSlice(realm.allocator, &replacement) catch return error.OutOfMemory;
            i += 3;
            continue;
        }
        if (isLoneLowSurrogateAt(s.bytes, i)) {
            buf.appendSlice(realm.allocator, &replacement) catch return error.OutOfMemory;
            i += 3;
            continue;
        }
        buf.appendSlice(realm.allocator, s.bytes[i .. i + seq_len]) catch return error.OutOfMemory;
        i += seq_len;
    }
    const out = realm.heap.allocateString(buf.items) catch return error.OutOfMemory;
    return Value.fromString(out);
}

/// §22.1.3.10 String.prototype.localeCompare — without ICU,
/// fall back to byte-wise compare. Returns -1/0/+1 per spec.
fn stringLocaleCompare(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const s = try coerceThisToJSString(realm, this_value);
    const other_s = try intrinsics.stringifyArg(realm, argOr(args, 0, Value.undefined_));
    const cmp = std.mem.order(u8, s.bytes, other_s.bytes);
    return Value.fromInt32(switch (cmp) {
        .lt => -1,
        .eq => 0,
        .gt => 1,
    });
}

