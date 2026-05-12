//! §22.1 String.prototype methods — extracted from
//! `intrinsics.zig`. All methods accept primitives + wrapper
//! objects via `coerceThisToJSString` (§22.1.3
//! RequireObjectCoercible + ToString). Cynic walks bytes; full
//! UTF-16 surrogate-pair fidelity is later.

const std = @import("std");

const Realm = @import("../realm.zig").Realm;
const Value = @import("../value.zig").Value;
const JSString = @import("../string.zig").JSString;
const JSObject = @import("../object.zig").JSObject;
const JSFunction = @import("../function.zig").JSFunction;
const NativeError = @import("../function.zig").NativeError;
const heap_mod = @import("../heap.zig");
const intrinsics = @import("../intrinsics.zig");
const interpreter = @import("../interpreter.zig");

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
    try installNativeMethodOnProto(realm, sp, "split", stringSplit, 2);
    // §22.1.3.{17,18} padStart / padEnd — spec `length: 1`, even
    // though both accept (maxLength, fillString).
    try installNativeMethodOnProto(realm, sp, "padStart", stringPadStart, 1);
    try installNativeMethodOnProto(realm, sp, "padEnd", stringPadEnd, 1);
    try installNativeMethodOnProto(realm, sp, "at", stringAt, 1);
    try installNativeMethodOnProto(realm, sp, "lastIndexOf", stringLastIndexOf, 1);
    try installNativeMethodOnProto(realm, sp, "replace", stringReplace, 2);
    try installNativeMethodOnProto(realm, sp, "replaceAll", stringReplaceAll, 2);
    try installNativeMethodOnProto(realm, sp, "trimStart", stringTrimStart, 0);
    try installNativeMethodOnProto(realm, sp, "trimEnd", stringTrimEnd, 0);
    // §B.2.2 — kept Annex B aliases.
    try installNativeMethodOnProto(realm, sp, "trimLeft", stringTrimStart, 0);
    try installNativeMethodOnProto(realm, sp, "trimRight", stringTrimEnd, 0);
    try installNativeMethodOnProto(realm, sp, "substr", stringSubstr, 2);
    try installNativeMethodOnProto(realm, sp, "normalize", stringNormalize, 1);
    try installNativeMethodOnProto(realm, sp, "codePointAt", stringCodePointAt, 1);
    try installNativeMethodOnProto(realm, sp, "localeCompare", stringLocaleCompare, 1);
    try installNativeMethodOnProto(realm, sp, "toLocaleUpperCase", stringToUpperCase, 0);
    try installNativeMethodOnProto(realm, sp, "toLocaleLowerCase", stringToLowerCase, 0);
    try installNativeMethodOnProto(realm, sp, "match", stringMatch, 1);
    try installNativeMethodOnProto(realm, sp, "matchAll", stringMatchAll, 1);
    try installNativeMethodOnProto(realm, sp, "search", stringSearch, 1);
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
    return interpreter.openIterator(realm.allocator, realm, Value.fromString(s)) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return throwTypeError(realm, "could not open string iterator"),
    };
}

/// §22.2.9.1 %RegExpStringIteratorPrototype%.next — RequireInternalSlot
/// on `[[IteratingRegExp]]` (presence of `__cynic_matchall_re__`).
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
    const exec_result = try regexExecCall(realm, re_obj, input);
    if (exec_result.isNull()) {
        it.set(realm.allocator, "__cynic_matchall_done__", Value.fromBool(true)) catch return error.OutOfMemory;
        return iterResult(realm, Value.undefined_, true);
    }
    return iterResult(realm, exec_result, false);
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
        const nv = coerceToNumber(a);
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

/// §22.1.3.12 String.prototype.matchAll(regex) — return an
/// iterator that yields each `regex.exec` result. Per spec the
/// regex must carry the global flag (otherwise TypeError).
fn stringMatchAll(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const s = try coerceThisToJSString(realm, this_value);
    const arg = argOr(args, 0, Value.undefined_);
    const regex_obj = if (isRegexLike(arg)) |r| r else blk: {
        const re_v = try ensureRegExp(realm, arg);
        break :blk heap_mod.valueAsPlainObject(re_v) orelse return throwTypeError(realm, "matchAll target is not a regex");
    };
    if (!flagsHas(realm, regex_obj, 'g')) {
        return throwTypeError(realm, "String.prototype.matchAll requires a global regex");
    }
    // §22.2.9.1 CreateRegExpStringIterator — allocate the
    // iterator with its `[[IteratingRegExp]]`, `[[IteratedString]]`,
    // and `[[Done]]` slots. `next` / `@@iterator` /
    // `Symbol.toStringTag` come from %RegExpStringIteratorPrototype%
    // (§22.2.9.2), wired by `install` above.
    const iter = realm.heap.allocateObject() catch return error.OutOfMemory;
    iter.prototype = realm.intrinsics.regexp_string_iterator_prototype orelse realm.intrinsics.object_prototype;
    iter.set(realm.allocator, "__cynic_matchall_re__", heap_mod.taggedObject(regex_obj)) catch return error.OutOfMemory;
    iter.set(realm.allocator, "__cynic_matchall_input__", Value.fromString(s)) catch return error.OutOfMemory;
    iter.set(realm.allocator, "__cynic_matchall_done__", Value.fromBool(false)) catch return error.OutOfMemory;
    regex_obj.set(realm.allocator, "lastIndex", Value.fromInt32(0)) catch return error.OutOfMemory;
    return heap_mod.taggedObject(iter);
}

fn iterResult(realm: *Realm, value: Value, done: bool) NativeError!Value {
    const obj = realm.heap.allocateObject() catch return error.OutOfMemory;
    obj.prototype = realm.intrinsics.object_prototype;
    obj.set(realm.allocator, "value", value) catch return error.OutOfMemory;
    obj.set(realm.allocator, "done", Value.fromBool(done)) catch return error.OutOfMemory;
    return heap_mod.taggedObject(obj);
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
            .thrown => return error.NativeThrew,
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
            .thrown => return error.NativeThrew,
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
    const ctor_v = realm.globals.get("RegExp") orelse Value.undefined_;
    const ctor = heap_mod.valueAsFunction(ctor_v) orelse return throwTypeError(realm, "RegExp constructor is missing");
    const interp = @import("../interpreter.zig");
    const inst = realm.heap.allocateObject() catch return error.OutOfMemory;
    inst.prototype = ctor.prototype;
    const args_call = [_]Value{arg};
    const out = interp.callJSFunction(realm.allocator, realm, ctor, heap_mod.taggedObject(inst), &args_call) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.NativeThrew,
    };
    return switch (out) {
        .value, .yielded => |v| if (v.isUndefined()) heap_mod.taggedObject(inst) else v,
        .thrown => return error.NativeThrew,
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

fn stringCharAt(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const s = try coerceThisToJSString(realm, this_value);
    const idx_v = coerceToNumber(argOr(args, 0, Value.fromInt32(0)));
    // §7.1.5 ToIntegerOrInfinity — NaN → 0; +Inf / -Inf are
    // out-of-range; finite values truncate toward zero.
    const idx: i64 = if (idx_v.isInt32()) idx_v.asInt32() else blk: {
        const d = idx_v.asDouble();
        if (std.math.isNan(d)) break :blk 0;
        if (std.math.isInf(d)) break :blk if (d > 0) std.math.maxInt(i32) else -1;
        break :blk @intFromFloat(@trunc(d));
    };
    if (idx < 0 or @as(usize, @intCast(idx)) >= s.bytes.len) {
        const empty = realm.heap.allocateString("") catch return error.OutOfMemory;
        return Value.fromString(empty);
    }
    const i: usize = @intCast(idx);
    const ch = realm.heap.allocateString(s.bytes[i .. i + 1]) catch return error.OutOfMemory;
    return Value.fromString(ch);
}

fn stringCharCodeAt(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const s = try coerceThisToJSString(realm, this_value);
    const idx_v = coerceToNumber(argOr(args, 0, Value.fromInt32(0)));
    // §7.1.5 ToIntegerOrInfinity — see stringCharAt for the rule.
    const idx: i64 = if (idx_v.isInt32()) idx_v.asInt32() else blk: {
        const d = idx_v.asDouble();
        if (std.math.isNan(d)) break :blk 0;
        if (std.math.isInf(d)) break :blk if (d > 0) std.math.maxInt(i32) else -1;
        break :blk @intFromFloat(@trunc(d));
    };
    if (idx < 0 or @as(usize, @intCast(idx)) >= s.bytes.len) {
        return Value.fromDouble(std.math.nan(f64));
    }
    return Value.fromInt32(@intCast(s.bytes[@intCast(idx)]));
}

fn stringIndexOf(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const s = try coerceThisToJSString(realm, this_value);
    const needle_v = argOr(args, 0, Value.undefined_);
    if (!needle_v.isString()) return Value.fromInt32(-1);
    const needle: *JSString = @ptrCast(@alignCast(needle_v.asString()));
    const start_v = argOr(args, 1, Value.fromInt32(0));
    var start: usize = 0;
    if (start_v.isInt32()) {
        const i = start_v.asInt32();
        start = if (i < 0) 0 else @intCast(i);
    }
    if (start > s.bytes.len) start = s.bytes.len;
    const slice = s.bytes[start..];
    if (std.mem.indexOf(u8, slice, needle.bytes)) |pos| {
        return Value.fromInt32(@intCast(pos + start));
    }
    return Value.fromInt32(-1);
}

fn stringIncludes(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const s = try coerceThisToJSString(realm, this_value);
    const needle_v = argOr(args, 0, Value.undefined_);
    if (!needle_v.isString()) return Value.false_;
    const needle: *JSString = @ptrCast(@alignCast(needle_v.asString()));
    return Value.fromBool(std.mem.indexOf(u8, s.bytes, needle.bytes) != null);
}

fn stringStartsWith(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const s = try coerceThisToJSString(realm, this_value);
    const needle_v = argOr(args, 0, Value.undefined_);
    if (!needle_v.isString()) return Value.false_;
    const needle: *JSString = @ptrCast(@alignCast(needle_v.asString()));
    return Value.fromBool(std.mem.startsWith(u8, s.bytes, needle.bytes));
}

fn stringEndsWith(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const s = try coerceThisToJSString(realm, this_value);
    const needle_v = argOr(args, 0, Value.undefined_);
    if (!needle_v.isString()) return Value.false_;
    const needle: *JSString = @ptrCast(@alignCast(needle_v.asString()));
    return Value.fromBool(std.mem.endsWith(u8, s.bytes, needle.bytes));
}

fn stringSlice(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const s = try coerceThisToJSString(realm, this_value);
    const len: i64 = @intCast(s.bytes.len);
    var start: i64 = if (args.len > 0) toInt(args[0]) else 0;
    var end: i64 = if (args.len > 1 and !args[1].isUndefined()) toInt(args[1]) else len;
    if (start < 0) start = @max(len + start, 0);
    if (end < 0) end = @max(len + end, 0);
    start = @min(start, len);
    end = @min(end, len);
    if (end < start) end = start;
    const out = realm.heap.allocateString(s.bytes[@intCast(start)..@intCast(end)]) catch return error.OutOfMemory;
    return Value.fromString(out);
}

fn stringSubstring(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const s = try coerceThisToJSString(realm, this_value);
    const len: i64 = @intCast(s.bytes.len);
    var start: i64 = if (args.len > 0) toInt(args[0]) else 0;
    var end: i64 = if (args.len > 1 and !args[1].isUndefined()) toInt(args[1]) else len;
    start = @max(0, @min(start, len));
    end = @max(0, @min(end, len));
    if (start > end) {
        const t = start;
        start = end;
        end = t;
    }
    const out = realm.heap.allocateString(s.bytes[@intCast(start)..@intCast(end)]) catch return error.OutOfMemory;
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

fn stringToUpperCase(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    const s = try coerceThisToJSString(realm, this_value);
    const buf = realm.allocator.alloc(u8, s.bytes.len) catch return error.OutOfMemory;
    defer realm.allocator.free(buf);
    for (s.bytes, 0..) |c, i| {
        buf[i] = if (c >= 'a' and c <= 'z') c - 32 else c;
    }
    const out = realm.heap.allocateString(buf) catch return error.OutOfMemory;
    return Value.fromString(out);
}

fn stringToLowerCase(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    const s = try coerceThisToJSString(realm, this_value);
    const buf = realm.allocator.alloc(u8, s.bytes.len) catch return error.OutOfMemory;
    defer realm.allocator.free(buf);
    for (s.bytes, 0..) |c, i| {
        buf[i] = if (c >= 'A' and c <= 'Z') c + 32 else c;
    }
    const out = realm.heap.allocateString(buf) catch return error.OutOfMemory;
    return Value.fromString(out);
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
        const part = stringifyArg(realm, a) catch return error.OutOfMemory;
        buf.appendSlice(realm.allocator, part.bytes) catch return error.OutOfMemory;
    }
    const out = realm.heap.allocateString(buf.items) catch return error.OutOfMemory;
    return Value.fromString(out);
}

fn stringRepeat(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const s = try coerceThisToJSString(realm, this_value);
    const n_v = coerceToNumber(argOr(args, 0, Value.fromInt32(0)));
    const n: i64 = if (n_v.isInt32()) n_v.asInt32() else blk: {
        const d = n_v.asDouble();
        if (std.math.isNan(d) or d < 0 or std.math.isInf(d)) return error.NativeThrew;
        break :blk @intFromFloat(@trunc(d));
    };
    if (n < 0) return error.NativeThrew;
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

pub fn stringSplit(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const s = try coerceThisToJSString(realm, this_value);
    const sep_v = argOr(args, 0, Value.undefined_);
    const limit_v = argOr(args, 1, Value.undefined_);
    const limit: i64 = if (limit_v.isUndefined())
        std.math.maxInt(i32)
    else if (limit_v.isInt32())
        limit_v.asInt32()
    else if (limit_v.isDouble()) blk: {
        const d = limit_v.asDouble();
        if (std.math.isNan(d) or d < 0) break :blk 0;
        if (d > @as(f64, @floatFromInt(std.math.maxInt(i32)))) break :blk std.math.maxInt(i32);
        break :blk @intFromFloat(d);
    } else std.math.maxInt(i32);
    const out = realm.heap.allocateObject() catch return error.OutOfMemory;
    out.prototype = realm.intrinsics.array_prototype;

    out.markAsArrayExotic(realm.allocator) catch return error.OutOfMemory;
    if (limit == 0) {
        setLength(realm, out, 0) catch return error.OutOfMemory;
        return heap_mod.taggedObject(out);
    }

    if (sep_v.isUndefined()) {
        const owned = realm.heap.allocateString("0") catch return error.OutOfMemory;
        const cs = realm.heap.allocateString(s.bytes) catch return error.OutOfMemory;
        out.set(realm.allocator, owned.bytes, Value.fromString(cs)) catch return error.OutOfMemory;
        setLength(realm, out, 1) catch return error.OutOfMemory;
        return heap_mod.taggedObject(out);
    }

    // §22.1.3.23 — when separator is a regex, walk matches via
    // `regex.exec`. Empty input still produces `[""]` unless the
    // regex matches the empty string (in which case `[]`).
    if (isRegexLike(sep_v)) |regex_obj| {
        return regexSplit(realm, s, regex_obj, limit, out);
    }

    // §22.1.3.21 step 6 — separator that's neither a regex nor
    // a string gets ToString'd. Booleans, numbers, BigInts, and
    // most objects (with the regex-like fast path already taken
    // above) all flow through here.
    const sep_str_v: Value = if (sep_v.isString())
        sep_v
    else
        Value.fromString(stringifyArg(realm, sep_v) catch return error.OutOfMemory);
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
fn stringPad(realm: *Realm, this_value: Value, args: []const Value, start: bool) NativeError!Value {
    const s = try coerceThisToJSString(realm, this_value);
    const target_v = argOr(args, 0, Value.fromInt32(0));
    const target_len: i64 = if (target_v.isInt32()) target_v.asInt32() else if (target_v.isDouble()) blk: {
        const d = target_v.asDouble();
        if (std.math.isNan(d) or std.math.isInf(d) or d < 0) break :blk 0;
        break :blk @intFromFloat(@trunc(d));
    } else 0;
    if (target_len <= @as(i64, @intCast(s.bytes.len))) {
        const out = realm.heap.allocateString(s.bytes) catch return error.OutOfMemory;
        return Value.fromString(out);
    }
    const fill_v = argOr(args, 1, Value.undefined_);
    const fill_slice: []const u8 = if (fill_v.isUndefined())
        " "
    else if (fill_v.isString()) blk: {
        const f: *JSString = @ptrCast(@alignCast(fill_v.asString()));
        break :blk f.bytes;
    } else " ";
    if (fill_slice.len == 0) {
        const out = realm.heap.allocateString(s.bytes) catch return error.OutOfMemory;
        return Value.fromString(out);
    }
    const total: usize = @intCast(target_len);
    if (total > 1024 * 1024) return error.NativeThrew; // sanity cap
    const buf = realm.allocator.alloc(u8, total) catch return error.OutOfMemory;
    defer realm.allocator.free(buf);
    const pad_total = total - s.bytes.len;
    var i: usize = 0;
    while (i < pad_total) : (i += 1) {
        buf[if (start) i else (s.bytes.len + i)] = fill_slice[i % fill_slice.len];
    }
    const start_offset: usize = if (start) pad_total else 0;
    @memcpy(buf[start_offset .. start_offset + s.bytes.len], s.bytes);
    const out = realm.heap.allocateString(buf) catch return error.OutOfMemory;
    return Value.fromString(out);
}

fn stringAt(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const s = try coerceThisToJSString(realm, this_value);
    var idx: i64 = if (args.len > 0) toInt(args[0]) else 0;
    if (idx < 0) idx += @as(i64, @intCast(s.bytes.len));
    if (idx < 0 or idx >= @as(i64, @intCast(s.bytes.len))) return Value.undefined_;
    const i: usize = @intCast(idx);
    const out = realm.heap.allocateString(s.bytes[i .. i + 1]) catch return error.OutOfMemory;
    return Value.fromString(out);
}

fn stringLastIndexOf(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const s = try coerceThisToJSString(realm, this_value);
    const needle_v = argOr(args, 0, Value.undefined_);
    if (!needle_v.isString()) return Value.fromInt32(-1);
    const needle: *JSString = @ptrCast(@alignCast(needle_v.asString()));
    if (needle.bytes.len > s.bytes.len) return Value.fromInt32(-1);
    if (std.mem.lastIndexOf(u8, s.bytes, needle.bytes)) |pos| {
        return Value.fromInt32(@intCast(pos));
    }
    return Value.fromInt32(-1);
}

/// §22.1.3.23 String.prototype.split with a regex separator.
/// Pre-allocated `out` is the result Array; we populate it.
fn regexSplit(
    realm: *Realm,
    s: *JSString,
    regex_obj: *JSObject,
    limit: i64,
    out: *JSObject,
) NativeError!Value {
    // Spec §22.1.3.23 ignores `g` flag — we drive matching by
    // slicing the source after each match. The match position
    // reported by exec is relative to the slice; we add `cursor`
    // for the absolute offset.
    regex_obj.set(realm.allocator, "lastIndex", Value.fromInt32(0)) catch return error.OutOfMemory;
    var idx: i32 = 0;
    var cursor: usize = 0;
    var ibuf: [24]u8 = undefined;
    const max_iter: usize = 1 << 20;
    var step: usize = 0;
    while (step < max_iter) : (step += 1) {
        if (idx >= limit) break;
        if (cursor >= s.bytes.len) break;
        const tail = realm.heap.allocateString(s.bytes[cursor..]) catch return error.OutOfMemory;
        const exec_result = try regexExecCall(realm, regex_obj, tail);
        if (exec_result.isNull()) break;
        const match_arr = heap_mod.valueAsPlainObject(exec_result) orelse break;
        const m_idx_v = match_arr.get("index");
        const m_off: usize = if (m_idx_v.isInt32() and m_idx_v.asInt32() >= 0) @intCast(m_idx_v.asInt32()) else 0;
        const m_idx: usize = cursor + m_off;
        const whole_v = match_arr.get("0");
        const whole: *JSString = if (whole_v.isString()) @ptrCast(@alignCast(whole_v.asString())) else return error.NativeThrew;

        // Spec: zero-width match at cursor is skipped.
        if (m_idx == cursor and whole.bytes.len == 0) {
            cursor += 1;
            continue;
        }

        // Append the substring before the match as a result element.
        const part = s.bytes[cursor..m_idx];
        const islice = std.fmt.bufPrint(&ibuf, "{d}", .{idx}) catch unreachable;
        const owned = realm.heap.allocateString(islice) catch return error.OutOfMemory;
        const part_str = realm.heap.allocateString(part) catch return error.OutOfMemory;
        out.set(realm.allocator, owned.bytes, Value.fromString(part_str)) catch return error.OutOfMemory;
        idx += 1;

        // Spec also pushes any capture groups as result elements.
        const cap_count_v = match_arr.get("length");
        const cap_count: i32 = if (cap_count_v.isInt32()) cap_count_v.asInt32() else 1;
        var ci: i32 = 1;
        while (ci < cap_count) : (ci += 1) {
            if (idx >= limit) break;
            const ci_buf_islice = std.fmt.bufPrint(&ibuf, "{d}", .{ci}) catch unreachable;
            const cap_v = match_arr.get(ci_buf_islice);
            const out_islice = std.fmt.bufPrint(&ibuf, "{d}", .{idx}) catch unreachable;
            const out_owned = realm.heap.allocateString(out_islice) catch return error.OutOfMemory;
            out.set(realm.allocator, out_owned.bytes, cap_v) catch return error.OutOfMemory;
            idx += 1;
        }
        cursor = m_idx + whole.bytes.len;
    }
    if (idx < limit) {
        // Push the remainder.
        const part = s.bytes[cursor..];
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

/// Run `regex.exec(input)` and return the result Value. Caller
/// inspects for null vs match-array.
fn regexExecCall(realm: *Realm, regex_obj: *JSObject, input: *JSString) NativeError!Value {
    const exec_fn = heap_mod.valueAsFunction(regex_obj.get("exec")) orelse return throwTypeError(realm, "regex has no exec method");
    const args_call = [_]Value{Value.fromString(input)};
    const out = interpreter.callJSFunction(realm.allocator, realm, exec_fn, heap_mod.taggedObject(regex_obj), &args_call) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.NativeThrew,
    };
    return switch (out) {
        .value, .yielded => |v| v,
        .thrown => return error.NativeThrew,
    };
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

pub fn stringReplace(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const s = try coerceThisToJSString(realm, this_value);
    const pat_v = argOr(args, 0, Value.undefined_);
    const repl_v = argOr(args, 1, Value.undefined_);
    // §22.1.3.18 — when the pattern is a regex, dispatch through
    // its `exec`. Global flag → iterate all matches; otherwise
    // replace just the first.
    if (isRegexLike(pat_v)) |regex_obj| {
        return regexReplace(realm, s, regex_obj, repl_v, false);
    }
    const pat = if (pat_v.isString())
        @as(*JSString, @ptrCast(@alignCast(pat_v.asString())))
    else
        intrinsics.stringifyArg(realm, pat_v) catch return error.OutOfMemory;
    if (std.mem.indexOf(u8, s.bytes, pat.bytes)) |pos| {
        const replacement = try resolveReplacer(realm, s, pat, pos, repl_v);
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        defer buf.deinit(realm.allocator);
        buf.appendSlice(realm.allocator, s.bytes[0..pos]) catch return error.OutOfMemory;
        buf.appendSlice(realm.allocator, replacement) catch return error.OutOfMemory;
        buf.appendSlice(realm.allocator, s.bytes[pos + pat.bytes.len ..]) catch return error.OutOfMemory;
        const out = realm.heap.allocateString(buf.items) catch return error.OutOfMemory;
        return Value.fromString(out);
    }
    const out = realm.heap.allocateString(s.bytes) catch return error.OutOfMemory;
    return Value.fromString(out);
}

/// §22.1.3.18 — `regex` branch of `String.prototype.{replace,
/// replaceAll}`. Iterates `regex.exec(input)`, splicing the
/// replacement at each match position. `force_all` mirrors
/// `replaceAll` (which requires a global regex anyway).
fn regexReplace(
    realm: *Realm,
    s: *JSString,
    regex_obj: *JSObject,
    repl_v: Value,
    force_all: bool,
) NativeError!Value {
    const is_global = flagsHas(realm, regex_obj, 'g');
    const all = is_global or force_all;
    // Reset lastIndex so we always start at 0.
    regex_obj.set(realm.allocator, "lastIndex", Value.fromInt32(0)) catch return error.OutOfMemory;

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(realm.allocator);
    var cursor: usize = 0;
    const max_iter: usize = 1 << 20;
    var step: usize = 0;
    while (step < max_iter) : (step += 1) {
        const exec_result = try regexExecCall(realm, regex_obj, s);
        if (exec_result.isNull()) break;
        const match_arr = heap_mod.valueAsPlainObject(exec_result) orelse break;
        const idx_v = match_arr.get("index");
        const m_idx: usize = if (idx_v.isInt32() and idx_v.asInt32() >= 0) @intCast(idx_v.asInt32()) else cursor;
        const whole_v = match_arr.get("0");
        const whole: *JSString = if (whole_v.isString())
            @ptrCast(@alignCast(whole_v.asString()))
        else
            return error.NativeThrew;

        // Append everything before this match, then the replacement.
        if (m_idx > cursor) buf.appendSlice(realm.allocator, s.bytes[cursor..m_idx]) catch return error.OutOfMemory;
        const replacement = try resolveRegexReplacer(realm, s, match_arr, whole, m_idx, repl_v);
        buf.appendSlice(realm.allocator, replacement) catch return error.OutOfMemory;
        cursor = m_idx + whole.bytes.len;
        if (whole.bytes.len == 0) {
            // Zero-width match — bump cursor by one byte to avoid
            // infinite loop. (Spec advances by one UTF-16 unit;
            // we approximate with one UTF-8 byte.)
            if (cursor < s.bytes.len) {
                buf.append(realm.allocator, s.bytes[cursor]) catch return error.OutOfMemory;
                cursor += 1;
            }
        }
        if (!all) break;
    }
    if (cursor < s.bytes.len) buf.appendSlice(realm.allocator, s.bytes[cursor..]) catch return error.OutOfMemory;
    const out = realm.heap.allocateString(buf.items) catch return error.OutOfMemory;
    return Value.fromString(out);
}

/// §22.1.3.18.1 GetSubstitution — for a regex match, the
/// callable replacer receives `(match,...captures, offset,
/// source)`. Cynic's `match_arr` is `[whole, c1, c2,...]`, so
/// we walk it.
fn resolveRegexReplacer(
    realm: *Realm,
    source: *JSString,
    match_arr: *JSObject,
    whole: *JSString,
    pos: usize,
    repl_v: Value,
) NativeError![]const u8 {
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
        args.append(realm.allocator, Value.fromInt32(@intCast(pos))) catch return error.OutOfMemory;
        args.append(realm.allocator, Value.fromString(source)) catch return error.OutOfMemory;
        const outcome = interpreter.callJSFunction(realm.allocator, realm, fn_obj, Value.undefined_, args.items) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.NativeThrew,
        };
        const ret = switch (outcome) {
            .value, .yielded => |v| v,
            .thrown => return error.NativeThrew,
        };
        const ret_s = intrinsics.stringifyArg(realm, ret) catch return error.OutOfMemory;
        return ret_s.bytes;
    }
    // String replacement — `$&`, `$1`...`$9`, `$$`, `$\``,
    // `$'` substitutions per §22.1.3.18.1.
    const repl_s = intrinsics.stringifyArg(realm, repl_v) catch return error.OutOfMemory;
    return try expandSubstitution(realm, repl_s.bytes, source, match_arr, whole, pos);
}

fn expandSubstitution(
    realm: *Realm,
    template: []const u8,
    source: *JSString,
    match_arr: *JSObject,
    whole: *JSString,
    pos: usize,
) NativeError![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(realm.allocator);
    var i: usize = 0;
    while (i < template.len) : (i += 1) {
        const c = template[i];
        if (c != '$' or i + 1 >= template.len) {
            out.append(realm.allocator, c) catch return error.OutOfMemory;
            continue;
        }
        const n = template[i + 1];
        switch (n) {
            '$' => {
                out.append(realm.allocator, '$') catch return error.OutOfMemory;
                i += 1;
            },
            '&' => {
                out.appendSlice(realm.allocator, whole.bytes) catch return error.OutOfMemory;
                i += 1;
            },
            '`' => {
                out.appendSlice(realm.allocator, source.bytes[0..pos]) catch return error.OutOfMemory;
                i += 1;
            },
            '\'' => {
                const tail_start = pos + whole.bytes.len;
                if (tail_start < source.bytes.len) out.appendSlice(realm.allocator, source.bytes[tail_start..]) catch return error.OutOfMemory;
                i += 1;
            },
            '0'...'9' => {
                // Single or double-digit capture reference.
                var idx: usize = n - '0';
                var consumed: usize = 1;
                if (i + 2 < template.len and template[i + 2] >= '0' and template[i + 2] <= '9') {
                    const idx2 = idx * 10 + (template[i + 2] - '0');
                    const len_v = match_arr.get("length");
                    const arr_len: i32 = if (len_v.isInt32()) len_v.asInt32() else 1;
                    if (idx2 < @as(usize, @intCast(arr_len))) {
                        idx = idx2;
                        consumed = 2;
                    }
                }
                if (idx == 0) {
                    out.appendSlice(realm.allocator, whole.bytes) catch return error.OutOfMemory;
                } else {
                    var ibuf: [16]u8 = undefined;
                    const islice = std.fmt.bufPrint(&ibuf, "{d}", .{idx}) catch unreachable;
                    const cap_v = match_arr.get(islice);
                    if (cap_v.isString()) {
                        const cs: *JSString = @ptrCast(@alignCast(cap_v.asString()));
                        out.appendSlice(realm.allocator, cs.bytes) catch return error.OutOfMemory;
                    }
                    // undefined captures contribute nothing.
                }
                i += consumed;
            },
            else => {
                out.append(realm.allocator, c) catch return error.OutOfMemory;
            },
        }
    }
    return try realm.allocator.dupe(u8, out.items);
}

/// §22.1.3.18 — produce the replacement bytes for a single
/// match. When `repl` is callable, `Call(repl, undefined,
/// «match, position, source»)` runs and the result is
/// stringified. Otherwise `repl` is coerced to string with no
/// `$&` / `$1` substitution (later will add full
/// GetSubstitution semantics).
fn resolveReplacer(
    realm: *Realm,
    source: *JSString,
    matched: *JSString,
    pos: usize,
    repl_v: Value,
) NativeError![]const u8 {
    if (heap_mod.valueAsFunction(repl_v)) |fn_obj| {
        const args = [_]Value{
            Value.fromString(matched),
            Value.fromInt32(@intCast(pos)),
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
        const ret_s = intrinsics.stringifyArg(realm, ret) catch return error.OutOfMemory;
        return ret_s.bytes;
    }
    const repl_s = intrinsics.stringifyArg(realm, repl_v) catch return error.OutOfMemory;
    return repl_s.bytes;
}

fn stringReplaceAll(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const s = try coerceThisToJSString(realm, this_value);
    const pat_v = argOr(args, 0, Value.undefined_);
    const repl_v = argOr(args, 1, Value.undefined_);
    if (isRegexLike(pat_v)) |regex_obj| {
        // §22.1.3.19 — regex argument MUST have the global flag.
        if (!flagsHas(realm, regex_obj, 'g')) {
            return throwTypeError(realm, "String.prototype.replaceAll requires a global regex");
        }
        return regexReplace(realm, s, regex_obj, repl_v, true);
    }
    const pat = if (pat_v.isString())
        @as(*JSString, @ptrCast(@alignCast(pat_v.asString())))
    else
        intrinsics.stringifyArg(realm, pat_v) catch return error.OutOfMemory;
    if (pat.bytes.len == 0) {
        // Empty pattern — interleave the replacement between every
        // character. The replacer fires once per insertion point;
        // for callable replacers each call gets the empty string,
        // pos = byte offset, and the source.
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        defer buf.deinit(realm.allocator);
        const empty = realm.heap.allocateString("") catch return error.OutOfMemory;
        var cursor: usize = 0;
        while (cursor <= s.bytes.len) : (cursor += 1) {
            const replacement = try resolveReplacer(realm, s, empty, cursor, repl_v);
            buf.appendSlice(realm.allocator, replacement) catch return error.OutOfMemory;
            if (cursor < s.bytes.len) buf.append(realm.allocator, s.bytes[cursor]) catch return error.OutOfMemory;
        }
        const out = realm.heap.allocateString(buf.items) catch return error.OutOfMemory;
        return Value.fromString(out);
    }
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(realm.allocator);
    var cursor: usize = 0;
    while (cursor <= s.bytes.len) {
        const remaining = s.bytes[cursor..];
        if (std.mem.indexOf(u8, remaining, pat.bytes)) |pos| {
            buf.appendSlice(realm.allocator, remaining[0..pos]) catch return error.OutOfMemory;
            const replacement = try resolveReplacer(realm, s, pat, cursor + pos, repl_v);
            buf.appendSlice(realm.allocator, replacement) catch return error.OutOfMemory;
            cursor += pos + pat.bytes.len;
        } else {
            buf.appendSlice(realm.allocator, remaining) catch return error.OutOfMemory;
            break;
        }
    }
    const out = realm.heap.allocateString(buf.items) catch return error.OutOfMemory;
    return Value.fromString(out);
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

// ── Annex B String additions (§B.2.2 / §B.2.3, later) ───────────────────────

fn stringSubstr(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const s = try coerceThisToJSString(realm, this_value);
    const total: i64 = @intCast(s.bytes.len);
    var start_d: f64 = 0;
    if (args.len > 0) {
        const v = coerceToNumber(args[0]);
        start_d = if (v.isInt32()) @floatFromInt(v.asInt32()) else v.asDouble();
    }
    var len_d: f64 = @floatFromInt(total);
    if (args.len > 1 and !args[1].isUndefined()) {
        const v = coerceToNumber(args[1]);
        len_d = if (v.isInt32()) @floatFromInt(v.asInt32()) else v.asDouble();
    }
    if (std.math.isNan(start_d)) start_d = 0;
    if (std.math.isNan(len_d)) len_d = 0;
    var start_i: i64 = if (std.math.isInf(start_d)) (if (start_d > 0) total else 0) else @intFromFloat(@trunc(start_d));
    if (start_i < 0) start_i = @max(total + start_i, 0);
    if (start_i > total) start_i = total;
    var len_i: i64 = if (std.math.isInf(len_d)) (if (len_d > 0) total - start_i else 0) else @intFromFloat(@trunc(len_d));
    if (len_i < 0) len_i = 0;
    if (start_i + len_i > total) len_i = total - start_i;
    const a: usize = @intCast(start_i);
    const b: usize = @intCast(start_i + len_i);
    const out = realm.heap.allocateString(s.bytes[a..b]) catch return error.OutOfMemory;
    return Value.fromString(out);
}

/// §22.1.3.13 String.prototype.normalize — without an ICU/UCD
/// normaliser, return the receiver unchanged. Tests that just
/// check method shape and ASCII-passthrough behaviour pass; full
/// NFC/NFD/NFKC/NFKD is a later task. The form argument is
/// validated per spec to throw RangeError on unknown values.
fn stringNormalize(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const s = try coerceThisToJSString(realm, this_value);
    const form_v = argOr(args, 0, Value.undefined_);
    if (!form_v.isUndefined()) {
        const form_s = intrinsics.stringifyArg(realm, form_v) catch return error.OutOfMemory;
        const f = form_s.bytes;
        if (!std.mem.eql(u8, f, "NFC") and !std.mem.eql(u8, f, "NFD") and
            !std.mem.eql(u8, f, "NFKC") and !std.mem.eql(u8, f, "NFKD"))
        {
            return intrinsics.throwRangeError(realm, "String.prototype.normalize: invalid form");
        }
    }
    return Value.fromString(s);
}

/// §22.1.3.4 String.prototype.codePointAt — UTF-8-aware.
/// Returns the code point starting at byte index `pos` (treating
/// `pos` as a UTF-16 code-unit index doesn't apply since Cynic
/// strings are UTF-8). Out-of-range → undefined.
fn stringCodePointAt(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const s = try coerceThisToJSString(realm, this_value);
    const pos_v = argOr(args, 0, Value.fromInt32(0));
    const pos = toInt(pos_v);
    if (pos < 0 or pos >= s.bytes.len) return Value.undefined_;
    const idx: usize = @intCast(pos);
    const seq_len = std.unicode.utf8ByteSequenceLength(s.bytes[idx]) catch return Value.undefined_;
    if (idx + seq_len > s.bytes.len) return Value.undefined_;
    const cp = std.unicode.utf8Decode(s.bytes[idx .. idx + seq_len]) catch return Value.undefined_;
    return Value.fromInt32(@intCast(cp));
}

/// §22.1.3.10 String.prototype.localeCompare — without ICU,
/// fall back to byte-wise compare. Returns -1/0/+1 per spec.
fn stringLocaleCompare(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const s = try coerceThisToJSString(realm, this_value);
    const other_s = intrinsics.stringifyArg(realm, argOr(args, 0, Value.undefined_)) catch return error.OutOfMemory;
    const cmp = std.mem.order(u8, s.bytes, other_s.bytes);
    return Value.fromInt32(switch (cmp) {
        .lt => -1,
        .eq => 0,
        .gt => 1,
    });
}

