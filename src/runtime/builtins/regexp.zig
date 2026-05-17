//! §22.2 RegExp — bridges to QuickJS-NG's `libregexp.c` (vendored
//! under `vendor/quickjs/`). The vendored code is pure-C, MIT-
//! licensed, ~3500 LOC. This file owns the JS-visible surface
//! (constructor, prototype, statics) and translates between
//! Cynic UTF-8 strings and `lre_*` UTF-16 buffers.
//!
//! ECMA-262 specifies regex indices in UTF-16 code units, so we
//! transcode the JS input string to UTF-16 for matching, then
//! report indices in those units. Substring slicing converts
//! back to UTF-8 byte offsets via an index correspondence table.

const std = @import("std");

const Realm = @import("../realm.zig").Realm;
const Value = @import("../value.zig").Value;
const JSString = @import("../string.zig").JSString;
const JSObject = @import("../object.zig").JSObject;
const JSFunction = @import("../function.zig").JSFunction;
const NativeError = @import("../function.zig").NativeError;
const heap_mod = @import("../heap.zig");
const intrinsics = @import("../intrinsics.zig");

const installConstructor = intrinsics.installConstructor;
const installNativeMethod = intrinsics.installNativeMethod;
const installNativeMethodOnProto = intrinsics.installNativeMethodOnProto;
const installNativeGetter = intrinsics.installNativeGetter;
const argOr = intrinsics.argOr;
const stringifyArg = intrinsics.stringifyArg;
const throwTypeError = intrinsics.throwTypeError;

// ── libregexp C API ─────────────────────────────────────────────────────────

// Build-system `translate-c` step (`b.addTranslateC` in build.zig)
// produces this module from `vendor/quickjs/libregexp.h`. Zig 0.17
// removed the `@cImport` builtin in favor of this approach.
const c = @import("c");

const LRE_FLAG_GLOBAL: c_int = 1 << 0;
const LRE_FLAG_IGNORECASE: c_int = 1 << 1;
const LRE_FLAG_MULTILINE: c_int = 1 << 2;
const LRE_FLAG_DOTALL: c_int = 1 << 3;
const LRE_FLAG_UNICODE: c_int = 1 << 4;
const LRE_FLAG_STICKY: c_int = 1 << 5;
const LRE_FLAG_INDICES: c_int = 1 << 6;
const LRE_FLAG_NAMED_GROUPS: c_int = 1 << 7;
const LRE_FLAG_UNICODE_SETS: c_int = 1 << 8;

// ── Host hooks called by libregexp ─────────────────────────────────────────

/// libregexp uses this for memory allocation. The `opaque`
/// pointer passed through `lre_compile` / `lre_exec` is our
/// `*Realm`. Cynic's allocator is realm-scoped; we reach it
/// via the opaque pointer.
export fn lre_realloc(opaque_ptr: ?*anyopaque, ptr: ?*anyopaque, size: usize) ?*anyopaque {
    _ = opaque_ptr;
    if (size == 0) {
        if (ptr) |p| std.c.free(p);
        return null;
    }
    if (ptr) |p| {
        return std.c.realloc(p, size);
    }
    return std.c.malloc(size);
}

/// libregexp calls this from `lre_exec` — we can refuse a deep
/// alloca by returning true. Cynic doesn't enforce a stack
/// budget on regex execution today; report "no overflow" so
/// matching always proceeds. Pathological patterns are bounded
/// by the engine's interrupt counter (~5 million ops).
export fn lre_check_stack_overflow(opaque_ptr: ?*anyopaque, alloca_size: usize) bool {
    _ = opaque_ptr;
    _ = alloca_size;
    return false;
}

/// libregexp's interrupt callback — returning non-zero aborts
/// the match with `LRE_RET_TIMEOUT`. We don't enforce timeouts
/// yet; let every match run to completion.
export fn lre_check_timeout(opaque_ptr: ?*anyopaque) c_int {
    _ = opaque_ptr;
    return 0;
}

// ── §22.2 RegExp install ────────────────────────────────────────────────────

pub fn install(realm: *Realm) !void {
    // §22.2.4.1 RegExp(pattern, flags) — callable both with and
    // without `new`. The constructor body handles the no-NewTarget
    // path (it's an "if NewTarget is undefined" branch in spec).
    const r = try installConstructor(realm, .{
        .name = "RegExp", .ctor = regexpConstructor, .arity = 2,
        .is_class = false,
        .set_home_object = false,
    });
    const fn_obj = r.ctor;
    const proto = r.proto;
    realm.intrinsics.regexp_prototype = proto;

    try installNativeMethodOnProto(realm, proto, "test", regexpTest, 1);
    try installNativeMethodOnProto(realm, proto, "exec", regexpExec, 1);
    try installNativeMethodOnProto(realm, proto, "toString", regexpToString, 0);
    // §22.2.6.{7, 10, 12, 13} RegExp.prototype[@@{match, replace,
    // search, split}] — required by the spec architecture (String
    // methods delegate to these). The implementations here are
    // minimal: each Symbol method delegates to the existing
    // String.prototype.X path with `this` swapped. The String
    // paths already consult `re.get("exec")` dynamically and walk
    // `re.flags` / `re.lastIndex` via `get`, so user-overridden
    // subclass behaviour mostly works through the back door.
    // §17 — the spec mandates that well-known-symbol-keyed methods
    // have a `name` property of `"[Symbol.X]"`, not the internal
    // canonical `"@@X"` key Cynic uses for dispatch. Install via a
    // helper that registers the function under the `"@@X"` key but
    // sets its `name` property to the bracketed form.
    try installSymbolMethod(realm, proto, "@@match", "[Symbol.match]", regexpProtoMatch, 1);
    try installSymbolMethod(realm, proto, "@@replace", "[Symbol.replace]", regexpProtoReplace, 2);
    try installSymbolMethod(realm, proto, "@@search", "[Symbol.search]", regexpProtoSearch, 1);
    try installSymbolMethod(realm, proto, "@@split", "[Symbol.split]", regexpProtoSplit, 2);
    // §22.2.5.9 RegExp.prototype[@@matchAll] — step-by-step traversal
    // of the spec algorithm so the species-ctor, flag-cloning, and
    // cached-lastIndex side effects line up with the fixtures.
    try installSymbolMethod(realm, proto, "@@matchAll", "[Symbol.matchAll]", regexpProtoMatchAll, 1);

    // §22.2.6.{3, 4, 5, 6, 7, 9, 10, 11, 13, 14} — accessors on
    // RegExp.prototype that surface the instance's
    // `[[OriginalSource]]` / `[[OriginalFlags]]` slots. Each is
    // installed via `installNativeGetter` which marks the
    // descriptor `{ enumerable: false, configurable: true }`
    // and clears `writable` (N/A on accessors).
    try installNativeGetter(realm, proto, "source", regexpSourceGetter);
    try installNativeGetter(realm, proto, "flags", regexpFlagsGetter);
    try installNativeGetter(realm, proto, "global", regexpGlobalGetter);
    try installNativeGetter(realm, proto, "hasIndices", regexpHasIndicesGetter);
    try installNativeGetter(realm, proto, "ignoreCase", regexpIgnoreCaseGetter);
    try installNativeGetter(realm, proto, "multiline", regexpMultilineGetter);
    try installNativeGetter(realm, proto, "dotAll", regexpDotAllGetter);
    try installNativeGetter(realm, proto, "unicode", regexpUnicodeGetter);
    try installNativeGetter(realm, proto, "unicodeSets", regexpUnicodeSetsGetter);
    try installNativeGetter(realm, proto, "sticky", regexpStickyGetter);

    try installNativeMethod(realm, fn_obj, "escape", regexpEscape, 1);

    // §22.2.4.2 get RegExp [ @@species ] — accessor on the
    // constructor whose getter returns the `this` value. The
    // built-in name is `"get [Symbol.species]"` (§22.2.4.2),
    // descriptor `{ get, set: undefined, enumerable: false,
    // configurable: true }`.
    const species_getter = try realm.heap.allocateFunctionNative(regexpSpeciesGetter, 0, "get [Symbol.species]");
    species_getter.proto = realm.intrinsics.function_prototype;
    const species_entry = try fn_obj.accessors.getOrPut(realm.allocator, "@@species");
    species_entry.value_ptr.* = .{ .getter = species_getter };
    try fn_obj.property_flags.put(realm.allocator, "@@species", .{
        .writable = false, .enumerable = false, .configurable = true,
    });
}

/// §22.2.4.2 get RegExp [ @@species ] — `return this value`.
fn regexpSpeciesGetter(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = realm;
    _ = args;
    return this_value;
}

/// Install a method whose property key is Cynic's `"@@<name>"`
/// canonical form for a well-known Symbol, but whose `name`
/// property reports the spec-mandated `"[Symbol.<name>]"`.
/// §17 — built-in function `name` must match the spec table.
fn installSymbolMethod(
    realm: *Realm,
    proto: *JSObject,
    key: []const u8,
    display_name: []const u8,
    native: @import("../function.zig").NativeFn,
    params: u8,
) !void {
    // Allocate the function with the spec-mandated display name so
    // `f.name` and the `name` own-property point at the same JSString.
    const fn_obj = try realm.heap.allocateFunctionNative(native, params, display_name);
    fn_obj.has_construct = false;
    try proto.setWithFlags(realm.allocator, key, heap_mod.taggedFunction(fn_obj), .{
        .writable = true,
        .enumerable = false,
        .configurable = true,
    });
}

/// §22.2.5.8 RegExp.prototype [ @@match ] ( string ). A step-by-
/// step traversal of the spec algorithm so each observable side
/// effect (`Get(rx, "flags")`, the global-only `Get(rx,
/// "unicode")`, the per-iteration `Set(rx, "lastIndex", …)` /
/// `RegExpExec(rx, S)` / `Get(result, "0")` chain, the zero-width
/// `Get(rx, "lastIndex")` ToLength + `AdvanceStringIndex`
/// reset) lines up with the fixtures under
/// `built-ins/RegExp/prototype/Symbol.match/`.
///
/// We can't just delegate to `string.zig:stringMatch` (the old
/// implementation): it shortcuts the `flags` ToString, never
/// reads `unicode`, and writes `lastIndex` via the bypass `set`
/// (so a non-writable `lastIndex` is silently swallowed instead
/// of throwing).
fn regexpProtoMatch(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    // step 1 — `Let rx be the this value`. step 2 — `If rx is not
    // an Object, throw a TypeError`.
    const rx = heap_mod.valueAsPlainObject(this_value) orelse return throwTypeError(realm, "RegExp.prototype[Symbol.match] called on non-object");

    // step 3 — `Let S be ? ToString(string)`.
    const s = try stringifyArg(realm, argOr(args, 0, Value.undefined_));

    // step 4 — `Let flags be ? ToString(? Get(rx, "flags"))`. The
    // `flags-tostring-error` / `get-flags-err` fixtures rely on
    // the `flags` getter / its `toString` propagating through the
    // accessor-aware chain walk.
    const flags_v = try intrinsics.getPropertyChain(realm, rx, "flags");
    const flags_s = try intrinsics.stringifyArg(realm, flags_v);

    // step 5 — `If flags does not contain "g", return ?
    // RegExpExec(rx, S)`.
    const is_global = std.mem.indexOfScalar(u8, flags_s.bytes, 'g') != null;
    if (!is_global) return try regExpExecGeneric(realm, rx, s);

    // step 6.a — `If flags contains "u" or "v", let fullUnicode
    // be true; else false`. Per §22.2.5.8 step 6 (ES2024+), the
    // `unicode` *property* is no longer consulted — only the
    // `flags` string. The `get-global-err` fixture explicitly
    // asserts `unicode` is not read.
    const full_unicode = std.mem.indexOfScalar(u8, flags_s.bytes, 'u') != null or
        std.mem.indexOfScalar(u8, flags_s.bytes, 'v') != null;

    // step 6.b — `Perform ? Set(rx, "lastIndex", +0𝔽, true)`. A
    // non-writable `lastIndex` raises TypeError per `g-init-
    // lastindex-err.js`.
    try setPropertyChainOrThrow(realm, rx, "lastIndex", Value.fromInt32(0));

    // step 6.c — `Let A be ! ArrayCreate(0)`. Allocate an array-
    // exotic JSObject so `Array.isArray(result)` is true.
    const out = realm.heap.allocateObject() catch return error.OutOfMemory;
    out.prototype = realm.intrinsics.array_prototype;
    out.markAsArrayExotic(realm.allocator) catch return error.OutOfMemory;

    // step 6.d — `Let n be 0`.
    var n: i32 = 0;
    var ibuf: [24]u8 = undefined;
    // step 6.e — `Repeat`.
    while (true) {
        // step 6.e.i — `Let result be ? RegExpExec(rx, S)`.
        const result_v = try regExpExecGeneric(realm, rx, s);
        // step 6.e.ii — `If result is null`:
        if (result_v.isNull()) {
            // `If n = 0, return null`.
            if (n == 0) return Value.null_;
            // `Return A`.
            intrinsics.setLength(realm, out, n) catch return error.OutOfMemory;
            return heap_mod.taggedObject(out);
        }
        // step 6.e.iii — `Else`:
        const result_obj = heap_mod.valueAsPlainObject(result_v) orelse return throwTypeError(realm, "RegExp.prototype[Symbol.match]: RegExpExec returned non-Object");
        // step 6.e.iii.1 — `Let matchStr be ?
        // ToString(? Get(result, "0"))`. Accessor-aware Get so a
        // `get 0()` poisoned getter (g-get-result-err.js)
        // propagates; ToString coerces a non-string match value
        // (g-coerce-result-err.js).
        const zero_v = try intrinsics.getPropertyChain(realm, result_obj, "0");
        const match_str = try intrinsics.stringifyArg(realm, zero_v);
        // step 6.e.iii.2 — `Perform
        // CreateDataPropertyOrThrow(A, ToString(n), matchStr)`.
        const name_slice = std.fmt.bufPrint(&ibuf, "{d}", .{n}) catch unreachable;
        const key = realm.heap.allocateString(name_slice) catch return error.OutOfMemory;
        out.set(realm.allocator, key.bytes, Value.fromString(match_str)) catch return error.OutOfMemory;
        // step 6.e.iii.3 — `If matchStr is the empty String`:
        if (match_str.bytes.len == 0) {
            // step 6.e.iii.3.a — `Let thisIndex be ?
            // ToLength(? Get(rx, "lastIndex"))`. Throwing
            // valueOf surfaces here (g-match-empty-coerce-
            // lastindex-err.js).
            const li_v = try intrinsics.getPropertyChain(realm, rx, "lastIndex");
            const this_index = try intrinsics.toLengthValue(realm, li_v);
            // step 6.e.iii.3.b — `Let nextIndex be
            // AdvanceStringIndex(S, thisIndex, fullUnicode)`.
            const next_index = advanceStringIndex(s.bytes, this_index, full_unicode);
            // step 6.e.iii.3.c — `Perform
            // ? Set(rx, "lastIndex", nextIndex, true)`. A non-
            // writable `lastIndex` here surfaces TypeError
            // (g-match-empty-set-lastindex-err.js).
            const ni_v: Value = if (next_index <= @as(i64, std.math.maxInt(i32)))
                Value.fromInt32(@intCast(next_index))
            else
                Value.fromDouble(@floatFromInt(next_index));
            try setPropertyChainOrThrow(realm, rx, "lastIndex", ni_v);
        }
        // step 6.e.iii.4 — `Set n to n + 1`.
        n += 1;
    }
}

/// §22.2.5.11 RegExp.prototype [ @@replace ] ( string, replaceValue ).
/// A step-by-step traversal of the spec so each observable side
/// effect lines up with the fixtures under
/// `built-ins/RegExp/prototype/Symbol.replace/`:
///   • step 6 — non-functional ToString-coerces replaceValue *up
///     front* (`fn-err` keeps the functional path; the ToString
///     branch runs before any matching).
///   • step 7 — `flags = ? ToString(? Get(rx, "flags"))`
///     (`get-flags-err`).
///   • step 8-9 — derive `global` / `fullUnicode` from the *flags
///     string* only (`get-global-err` asserts both `global` and
///     `unicode` are unread).
///   • step 9.b — `Set(rx, "lastIndex", 0, true)` honors writable
///     (`g-init-lastindex-err`).
///   • step 12 — RegExpExec loop, with empty-match
///     `AdvanceStringIndex` + `Set(rx, "lastIndex", nextIndex,
///     true)`.
///   • step 15 — per-result substitution. `LengthOfArrayLike` /
///     each capture `Get + ToString` / `Get(result, "groups")` /
///     functional `Call(replacer, undefined, …)` all surface user
///     throws (`result-get-length-err`, `result-get-capture-err`,
///     `result-coerce-capture-err`, `result-get-groups-err`,
///     `result-coerce-groups-err`, `result-get-groups-prop-err`,
///     `fn-err`).
///
/// We can't delegate to `string.zig:stringReplace` (the old
/// implementation): that path shortcuts the `flags` ToString,
/// reads `Get(rx, "global")` directly, writes `lastIndex` via the
/// bypass `set` (so a non-writable `lastIndex` is silently
/// swallowed), and re-reads `match_arr["1"]` inside the
/// substitution expander rather than pre-coercing per
/// step 15.i.
fn regexpProtoReplace(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    // step 1-2 — `Let rx be the this value`; non-Object →
    // TypeError.
    const rx = heap_mod.valueAsPlainObject(this_value) orelse return throwTypeError(realm, "RegExp.prototype[Symbol.replace] called on non-object");

    // step 3 — `Let S be ? ToString(string)`.
    const s = try stringifyArg(realm, argOr(args, 0, Value.undefined_));

    // step 4 — `Let lengthS be the number of code unit elements
    // in S`.
    const utf16 = @import("../utf16.zig");
    const length_s_usize = utf16.lengthInCodeUnits(s.bytes);
    const length_s: i64 = @intCast(length_s_usize);

    // step 5 — `Let functionalReplace be IsCallable(replaceValue)`.
    const repl_v_in = argOr(args, 1, Value.undefined_);
    const functional = heap_mod.valueAsFunction(repl_v_in) != null;
    // step 6 — `If functionalReplace is false, set replaceValue to
    // ? ToString(replaceValue)`. Run eagerly so a poisoned
    // `toString` on the replacement fires before any matching
    // (mirrors `String.prototype.replace`).
    const repl_template: ?*JSString = if (functional) null else try intrinsics.stringifyArg(realm, repl_v_in);

    // step 7 — `flags = ? ToString(? Get(rx, "flags"))`.
    const flags_v = try intrinsics.getPropertyChain(realm, rx, "flags");
    const flags_s = try intrinsics.stringifyArg(realm, flags_v);

    // step 8 — `If flags contains "g", let global be true; else
    // false`.
    const is_global = std.mem.indexOfScalar(u8, flags_s.bytes, 'g') != null;
    // step 9.a — `If flags contains "u" or "v", let fullUnicode be
    // true`.
    const full_unicode = std.mem.indexOfScalar(u8, flags_s.bytes, 'u') != null or
        std.mem.indexOfScalar(u8, flags_s.bytes, 'v') != null;

    // step 9.b — `If global is true, perform ? Set(rx,
    // "lastIndex", +0𝔽, true)`. Honors writable.
    if (is_global) {
        try setPropertyChainOrThrow(realm, rx, "lastIndex", Value.fromInt32(0));
    }

    // step 10-12 — collect results. Each iteration may throw from
    // RegExpExec or from the empty-match `lastIndex` Set.
    var results: std.ArrayListUnmanaged(*JSObject) = .empty;
    defer results.deinit(realm.allocator);
    while (true) {
        // step 12.a — `Let result be ? RegExpExec(rx, S)`.
        const result_v = try regExpExecGeneric(realm, rx, s);
        // step 12.b — `If result is null, set done to true`.
        if (result_v.isNull()) break;
        const result_obj = heap_mod.valueAsPlainObject(result_v) orelse return throwTypeError(realm, "RegExp.prototype[Symbol.replace]: RegExpExec returned non-Object");
        results.append(realm.allocator, result_obj) catch return error.OutOfMemory;
        // step 12.c.ii — `If global is false, set done to true`.
        if (!is_global) break;
        // step 12.c.iii — `Let matchStr be ? ToString(? Get(result,
        // "0"))`. Then if matchStr is "", advance lastIndex.
        const zero_v = try intrinsics.getPropertyChain(realm, result_obj, "0");
        const match_str = try intrinsics.stringifyArg(realm, zero_v);
        if (match_str.bytes.len == 0) {
            // §22.2.5.11 step 12.c.iii.2.a — `thisIndex = ?
            // ToLength(? Get(rx, "lastIndex"))`. §7.1.20 ToLength
            // clamps to `min(len, 2^53 - 1)`; `toLengthValue` only
            // saturates to i64, so apply the spec cap here. The
            // `coerce-lastindex` fixture exercises 2^54 → 2^53.
            const li_v = try intrinsics.getPropertyChain(realm, rx, "lastIndex");
            const this_index_raw = try intrinsics.toLengthValue(realm, li_v);
            const max_safe_integer: i64 = (1 << 53) - 1;
            const this_index: i64 = @min(this_index_raw, max_safe_integer);
            const next_index_d: f64 = @as(f64, @floatFromInt(this_index)) + 1.0;
            // For large indices the surrogate-pair branch is
            // unobservable (S is shorter); collapse to `+1`.
            // For typical sub-2^31 indices we route through
            // `advanceStringIndex` which handles fullUnicode.
            const ni_v: Value = blk: {
                if (this_index <= @as(i64, std.math.maxInt(i32)) - 1) {
                    const ni = advanceStringIndex(s.bytes, this_index, full_unicode);
                    if (ni <= @as(i64, std.math.maxInt(i32)))
                        break :blk Value.fromInt32(@intCast(ni))
                    else
                        break :blk Value.fromDouble(@floatFromInt(ni));
                }
                break :blk Value.fromDouble(next_index_d);
            };
            try setPropertyChainOrThrow(realm, rx, "lastIndex", ni_v);
        }
    }

    // step 13-14 — accumulator buffer + `nextSourcePosition`. The
    // buffer is WTF-8 bytes; `next_src_unit` is the next code-unit
    // index in S we haven't yet flushed.
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(realm.allocator);
    var next_src_unit: i64 = 0;

    // step 15 — `For each result of results, do`.
    var captures_buf: std.ArrayListUnmanaged(Value) = .empty;
    defer captures_buf.deinit(realm.allocator);
    for (results.items) |result_obj| {
        // step 15.a-b — `nCaptures = max(LengthOfArrayLike(result)
        // - 1, 0)`.
        const len_v = try intrinsics.getPropertyChain(realm, result_obj, "length");
        const len_raw = try intrinsics.toLengthValue(realm, len_v);
        const n_captures: i64 = if (len_raw > 0) len_raw - 1 else 0;

        // step 15.c — `Let matched be ? ToString(? Get(result,
        // "0"))`.
        const zero_v = try intrinsics.getPropertyChain(realm, result_obj, "0");
        const matched = try intrinsics.stringifyArg(realm, zero_v);

        // step 15.d — `Let matchLength be the number of code unit
        // elements in matched`.
        const match_length: i64 = @intCast(utf16.lengthInCodeUnits(matched.bytes));

        // step 15.e — `Let position be ? ToIntegerOrInfinity(?
        // Get(result, "index"))`. ToIntegerOrInfinity on a non-
        // finite double yields ±∞; we then clamp to [0, lengthS].
        const idx_v = try intrinsics.getPropertyChain(realm, result_obj, "index");
        const idx_num_v = try intrinsics.toNumber(realm, idx_v);
        const idx_d: f64 = if (idx_num_v.isInt32())
            @floatFromInt(idx_num_v.asInt32())
        else if (idx_num_v.isDouble())
            idx_num_v.asDouble()
        else
            0.0;
        const position: i64 = if (std.math.isNan(idx_d))
            0
        else if (!std.math.isFinite(idx_d))
            (if (idx_d > 0) length_s else 0)
        else clamp: {
            const trunc_d = @trunc(idx_d);
            if (trunc_d <= 0) break :clamp 0;
            if (trunc_d >= @as(f64, @floatFromInt(length_s))) break :clamp length_s;
            break :clamp @as(i64, @intFromFloat(trunc_d));
        };

        // step 15.g-i — collect captures. Each `Get(result, n)`
        // surfaces accessor throws; ToString runs on non-undefined
        // values.
        captures_buf.clearRetainingCapacity();
        var n: i64 = 1;
        var cap_key_buf: [24]u8 = undefined;
        while (n <= n_captures) : (n += 1) {
            const cap_key = std.fmt.bufPrint(&cap_key_buf, "{d}", .{n}) catch unreachable;
            const cap_n = try intrinsics.getPropertyChain(realm, result_obj, cap_key);
            const cap_coerced: Value = if (cap_n.isUndefined())
                Value.undefined_
            else
                Value.fromString(try intrinsics.stringifyArg(realm, cap_n));
            captures_buf.append(realm.allocator, cap_coerced) catch return error.OutOfMemory;
        }

        // step 15.j — `Let namedCaptures be ? Get(result, "groups")`.
        const named_captures_raw = try intrinsics.getPropertyChain(realm, result_obj, "groups");

        // step 15.k / 15.l — compute replacement.
        var replacement_owned: ?*JSString = null;
        if (functional) {
            // step 15.k — `replacerArgs = « matched, …captures,
            // position, S »`, then namedCaptures if not undefined.
            var rargs: std.ArrayListUnmanaged(Value) = .empty;
            defer rargs.deinit(realm.allocator);
            rargs.append(realm.allocator, Value.fromString(matched)) catch return error.OutOfMemory;
            for (captures_buf.items) |cv| {
                rargs.append(realm.allocator, cv) catch return error.OutOfMemory;
            }
            rargs.append(realm.allocator, Value.fromInt32(@intCast(position))) catch return error.OutOfMemory;
            rargs.append(realm.allocator, Value.fromString(s)) catch return error.OutOfMemory;
            if (!named_captures_raw.isUndefined()) {
                rargs.append(realm.allocator, named_captures_raw) catch return error.OutOfMemory;
            }
            const interp = @import("../interpreter.zig");
            const fn_obj = heap_mod.valueAsFunction(repl_v_in).?;
            const outcome = interp.callJSFunction(realm.allocator, realm, fn_obj, Value.undefined_, rargs.items) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.NativeThrew,
            };
            const ret_v: Value = switch (outcome) {
                .value, .yielded => |v| v,
                .thrown => |ex| {
                    realm.pending_exception = ex;
                    return error.NativeThrew;
                },
            };
            replacement_owned = try intrinsics.stringifyArg(realm, ret_v);
        } else {
            // step 15.l.i — `If namedCaptures is not undefined,
            // set namedCaptures to ? ToObject(namedCaptures)`. A
            // null `groups` raises TypeError per
            // `result-coerce-groups-err`. A string / number gets
            // wrapped to its boxed object so `getNameProperty`
            // sees properties (`result-coerce-groups`).
            const named_captures: Value = if (named_captures_raw.isUndefined())
                Value.undefined_
            else if (named_captures_raw.isNull())
                return throwTypeError(realm, "@@replace: groups is null")
            else
                heap_mod.taggedObject(try intrinsics.toObjectThis(realm, named_captures_raw));
            // step 15.l.ii — `GetSubstitution(matched, S, position,
            // captures, namedCaptures, replaceValue)`.
            replacement_owned = try getSubstitution(
                realm,
                repl_template.?.bytes,
                matched,
                s,
                position,
                captures_buf.items,
                named_captures,
            );
        }

        // step 15.m — `If position ≥ nextSourcePosition`:
        if (position >= next_src_unit) {
            // Append S[nextSourcePosition..position] + replacement.
            const tail_slice = utf16.sliceCodeUnits(s.bytes, @intCast(next_src_unit), @intCast(position));
            try appendUtf16SliceBytes(realm, &out, tail_slice);
            out.appendSlice(realm.allocator, replacement_owned.?.bytes) catch return error.OutOfMemory;
            next_src_unit = position + match_length;
        }
    }

    // step 16-17 — `If nextSourcePosition < lengthS`, append the
    // tail substring.
    if (next_src_unit < length_s) {
        const tail_slice = utf16.sliceCodeUnits(s.bytes, @intCast(next_src_unit), length_s_usize);
        try appendUtf16SliceBytes(realm, &out, tail_slice);
    }
    const out_str = realm.heap.allocateString(out.items) catch return error.OutOfMemory;
    return Value.fromString(out_str);
}

/// Append the bytes of a `utf16.Slice` (head/tail surrogate halves
/// + body) to an output buffer. Mirrors `jsStringFromUtf16Slice`
/// but writes into the caller's buffer rather than allocating a
/// fresh JSString.
fn appendUtf16SliceBytes(
    realm: *Realm,
    out: *std.ArrayListUnmanaged(u8),
    sl: @import("../utf16.zig").Slice,
) NativeError!void {
    const utf16 = @import("../utf16.zig");
    if (sl.head_surrogate != 0)
        utf16.appendCodeUnitAsWtf8(realm.allocator, out, sl.head_surrogate) catch return error.OutOfMemory;
    out.appendSlice(realm.allocator, sl.bytes) catch return error.OutOfMemory;
    if (sl.tail_surrogate != 0)
        utf16.appendCodeUnitAsWtf8(realm.allocator, out, sl.tail_surrogate) catch return error.OutOfMemory;
}

/// §22.1.3.19.1 GetSubstitution — string-template path. Walks the
/// template, expanding `$&`, `$\``, `$'`, `$N`, `$NN`, `$<name>`
/// per Table 64. `captures` is the pre-coerced capture list (each
/// element is a String value or `undefined`); `namedCaptures` is
/// either `undefined` or an Object.
///
/// `position` is in UTF-16 code units; substring slicing for
/// `$\`` / `$'` runs through `utf16.sliceCodeUnits` so a cut at a
/// mid-pair boundary lands on a well-formed WTF-8 slice.
fn getSubstitution(
    realm: *Realm,
    template: []const u8,
    matched: *JSString,
    source: *JSString,
    position: i64,
    captures: []const Value,
    named_captures: Value,
) NativeError!*JSString {
    const utf16 = @import("../utf16.zig");
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(realm.allocator);

    const match_length: i64 = @intCast(utf16.lengthInCodeUnits(matched.bytes));
    const tail_pos: i64 = position + match_length;
    const source_unit_len: i64 = @intCast(utf16.lengthInCodeUnits(source.bytes));

    var i: usize = 0;
    while (i < template.len) {
        const ch = template[i];
        if (ch != '$' or i + 1 >= template.len) {
            out.append(realm.allocator, ch) catch return error.OutOfMemory;
            i += 1;
            continue;
        }
        const next = template[i + 1];
        switch (next) {
            '$' => {
                out.append(realm.allocator, '$') catch return error.OutOfMemory;
                i += 2;
            },
            '&' => {
                out.appendSlice(realm.allocator, matched.bytes) catch return error.OutOfMemory;
                i += 2;
            },
            '`' => {
                // §22.1.3.19.1 Table 64 — `$\`` is the substring
                // of S from 0 to position (in code units).
                const sl = utf16.sliceCodeUnits(source.bytes, 0, @intCast(position));
                try appendUtf16SliceBytes(realm, &out, sl);
                i += 2;
            },
            '\'' => {
                // `$'` — substring from (position + matchLength)
                // to end. Clamp the start to lengthS.
                const start_u: i64 = if (tail_pos > source_unit_len) source_unit_len else tail_pos;
                const sl = utf16.sliceCodeUnits(source.bytes, @intCast(start_u), @intCast(source_unit_len));
                try appendUtf16SliceBytes(realm, &out, sl);
                i += 2;
            },
            '0'...'9' => {
                // Two-digit form takes precedence when the
                // resulting index is within captures.length.
                var digit_count: usize = 1;
                var index: usize = next - '0';
                if (i + 2 < template.len and template[i + 2] >= '0' and template[i + 2] <= '9') {
                    const two_digit = index * 10 + (template[i + 2] - '0');
                    if (two_digit >= 1 and two_digit <= captures.len) {
                        digit_count = 2;
                        index = two_digit;
                    }
                }
                if (index >= 1 and index <= captures.len) {
                    const cap = captures[index - 1];
                    if (cap.isString()) {
                        const cs: *JSString = @ptrCast(@alignCast(cap.asString()));
                        out.appendSlice(realm.allocator, cs.bytes) catch return error.OutOfMemory;
                    }
                    // `undefined` capture → empty (no append).
                    i += 1 + digit_count;
                } else {
                    out.appendSlice(realm.allocator, template[i .. i + 1 + digit_count]) catch return error.OutOfMemory;
                    i += 1 + digit_count;
                }
            },
            '<' => {
                // §22.1.3.19.1 — `$<name>`. With namedCaptures
                // undefined the ref is literal. Otherwise scan to
                // the next `>` and look up the name; on miss or
                // unterminated, the ref expands per spec table.
                if (named_captures.isUndefined()) {
                    out.appendSlice(realm.allocator, "$<") catch return error.OutOfMemory;
                    i += 2;
                    continue;
                }
                var j: usize = i + 2;
                while (j < template.len and template[j] != '>') : (j += 1) {}
                if (j >= template.len) {
                    // Unterminated `$<…` — Cynic treats it as the
                    // literal `$<…` rest. Matches the v8 / JSC
                    // observable behaviour: the entire `$<` plus
                    // trailing characters land in the output.
                    out.appendSlice(realm.allocator, template[i..]) catch return error.OutOfMemory;
                    i = template.len;
                    continue;
                }
                const name = template[i + 2 .. j];
                const named_obj = heap_mod.valueAsPlainObject(named_captures) orelse {
                    i = j + 1;
                    continue;
                };
                // The named-captures object may be a boxed String
                // (per step 15.l.i ToObject); read via the
                // accessor-aware chain walk so a `get foo()`
                // throw on the `groups` object propagates
                // (`result-get-groups-prop-err`).
                const cap_v = try intrinsics.getPropertyChain(realm, named_obj, name);
                if (!cap_v.isUndefined()) {
                    const cs = try intrinsics.stringifyArg(realm, cap_v);
                    out.appendSlice(realm.allocator, cs.bytes) catch return error.OutOfMemory;
                }
                i = j + 1;
            },
            else => {
                // Bare `$X` — keep both chars literal.
                out.append(realm.allocator, '$') catch return error.OutOfMemory;
                i += 1;
            },
        }
    }
    return realm.heap.allocateString(out.items) catch return error.OutOfMemory;
}

/// §22.2.6.13 RegExp.prototype [ @@search ] ( string ). A step-by-
/// step traversal so each observable side effect (`Get(rx,
/// "lastIndex")` / SameValue gate on the `Set(rx, "lastIndex",
/// 0)` / RegExpExec via `Get(rx, "exec")` / `Get(result,
/// "index")` / the SameValue-gated `Set(rx, "lastIndex",
/// previousLastIndex)` restore) lines up with the fixtures under
/// `built-ins/RegExp/prototype/Symbol.search/`.
///
/// We can't delegate to `string.zig:stringSearch`: it writes
/// `lastIndex` via the bypass `set` (so a non-writable
/// `lastIndex` is silently swallowed instead of throwing), and it
/// unconditionally writes the pre-exec 0 and the post-exec
/// restore — the SameValue gates per §22.2.6.13 step 5 / step 8
/// require the writes to be skipped when the value is already
/// where the spec wants it (`lastindex-no-restore` exercises both
/// gates).
fn regexpProtoSearch(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    // step 1-2 — `Let rx be the this value`. step 2 — non-Object
    // → TypeError.
    const rx = heap_mod.valueAsPlainObject(this_value) orelse
        return throwTypeError(realm, "RegExp.prototype[Symbol.search] called on non-object");

    // step 3 — `Let S be ? ToString(string)`.
    const s = try stringifyArg(realm, argOr(args, 0, Value.undefined_));

    // step 4 — `Let previousLastIndex be ? Get(rx, "lastIndex")`.
    // The `get-lastindex-err` fixture throws from the getter; it
    // surfaces through `getPropertyChain`.
    const previous_last_index = try intrinsics.getPropertyChain(realm, rx, "lastIndex");

    // step 5 — `If SameValue(previousLastIndex, +0𝔽) is false,
    // perform ? Set(rx, "lastIndex", +0𝔽, true)`. The SameValue
    // gate is observable: `lastindex-no-restore` asserts the
    // setter fires *zero* times when `lastIndex` is already 0,
    // and exactly once otherwise. `set-lastindex-init-err`
    // exercises both the poisoned-setter and the non-writable
    // path (where `setPropertyChainOrThrow` raises TypeError).
    const zero = Value.fromInt32(0);
    if (!intrinsics.sameValue(previous_last_index, zero)) {
        try setPropertyChainOrThrow(realm, rx, "lastIndex", zero);
    }

    // step 6 — `Let result be ? RegExpExec(rx, S)`. Goes through
    // `Get(rx, "exec")` per §22.2.7.1 step 3; the
    // `cstm-exec-return-invalid` fixture asserts the post-call
    // Object-or-Null check raises TypeError.
    const result_v = try regExpExecGeneric(realm, rx, s);

    // step 7 — `Let currentLastIndex be ? Get(rx, "lastIndex")`.
    const current_last_index = try intrinsics.getPropertyChain(realm, rx, "lastIndex");

    // step 8 — `If SameValue(currentLastIndex, previousLastIndex)
    // is false, perform ? Set(rx, "lastIndex", previousLastIndex,
    // true)`. `set-lastindex-restore` asserts the setter fires
    // exactly once when `exec` mutated `lastIndex`;
    // `set-lastindex-restore-err` exercises the poisoned-setter
    // and the non-writable-after-exec paths.
    if (!intrinsics.sameValue(current_last_index, previous_last_index)) {
        try setPropertyChainOrThrow(realm, rx, "lastIndex", previous_last_index);
    }

    // step 9 — `If result is null, return -1𝔽`.
    if (result_v.isNull()) return Value.fromInt32(-1);

    // step 10 — `Return ? Get(result, "index")`. The
    // `success-get-index-err` fixture throws from the `index`
    // getter; `getPropertyChain` propagates.
    const result_obj = heap_mod.valueAsPlainObject(result_v) orelse
        return throwTypeError(realm, "RegExp.prototype[Symbol.search]: RegExpExec returned non-Object");
    return try intrinsics.getPropertyChain(realm, result_obj, "index");
}

/// §22.2.5.13 RegExp.prototype [ @@split ] ( string, limit ). A
/// step-by-step traversal of the spec algorithm so each observable
/// side effect (`Get(rx, "constructor")`, `Get(rx, "flags")`,
/// `Construct(C, «rx, newFlags»)`, the per-iteration
/// `Set(splitter, "lastIndex", q)` / `Get(splitter, "lastIndex")`,
/// the result-array capture-property reads) lines up with the
/// fixtures under `built-ins/RegExp/prototype/Symbol.split/`.
///
/// We can't just delegate to `string.zig:stringSplit` (the old
/// implementation): that path hard-uses `%RegExp%` to build the
/// splitter and shortcuts the per-step `Set` / `Get` calls, so the
/// species-ctor and abrupt-completion fixtures all see fast-path
/// behaviour rather than spec behaviour.
fn regexpProtoSplit(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    // §22.2.5.13 step 1 — `Let rx be the this value`. step 2 —
    // `If rx is not an Object, throw a TypeError`.
    const rx = heap_mod.valueAsPlainObject(this_value) orelse return throwTypeError(realm, "RegExp.prototype[Symbol.split] called on non-object");

    // step 3 — `Let S be ? ToString(string)`.
    const s = try stringifyArg(realm, argOr(args, 0, Value.undefined_));

    // step 4 — `Let C be ? SpeciesConstructor(rx, %RegExp%)`.
    const builtin_regexp = blk: {
        const ctor_v = realm.globals.get("RegExp") orelse return throwTypeError(realm, "RegExp.prototype[Symbol.split]: %RegExp% missing");
        break :blk heap_mod.valueAsFunction(ctor_v) orelse return throwTypeError(realm, "RegExp.prototype[Symbol.split]: %RegExp% is not callable");
    };
    const c_fn = try speciesConstructor(realm, rx, builtin_regexp);

    // steps 5-6 — `Let flags be ? ToString(? Get(rx, "flags"))`.
    const flags_v = try intrinsics.getPropertyChain(realm, rx, "flags");
    const flags_s = try intrinsics.stringifyArg(realm, flags_v);

    // step 7 — `If flags contains "u" or flags contains "v", let
    // unicodeMatching be true; else false`.
    const unicode_matching = std.mem.indexOfScalar(u8, flags_s.bytes, 'u') != null or
        std.mem.indexOfScalar(u8, flags_s.bytes, 'v') != null;

    // steps 8-9 — `If flags contains "y", let newFlags be flags;
    // else newFlags be the string-concatenation of flags and "y"`.
    const has_y = std.mem.indexOfScalar(u8, flags_s.bytes, 'y') != null;
    const new_flags_js: *JSString = if (has_y) flags_s else nf: {
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        defer buf.deinit(realm.allocator);
        buf.appendSlice(realm.allocator, flags_s.bytes) catch return error.OutOfMemory;
        buf.append(realm.allocator, 'y') catch return error.OutOfMemory;
        break :nf realm.heap.allocateString(buf.items) catch return error.OutOfMemory;
    };

    // step 10 — `Let splitter be ? Construct(C, « rx, newFlags »)`.
    const splitter_args = [_]Value{ heap_mod.taggedObject(rx), Value.fromString(new_flags_js) };
    const interp = @import("../interpreter.zig");
    const ctor_v = heap_mod.taggedFunction(c_fn);
    const ctor_outcome = interp.constructValue(realm.allocator, realm, ctor_v, &splitter_args, ctor_v) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.NativeThrew,
    };
    const splitter_v: Value = switch (ctor_outcome) {
        .value, .yielded => |v| v,
        .thrown => |ex| {
            realm.pending_exception = ex;
            return error.NativeThrew;
        },
    };
    // step 10 implies the result of Construct must be an Object —
    // §10.5.14 [[Construct]] already enforces it for built-in
    // constructors, but a user-supplied species constructor that
    // returns a primitive would land here. Be defensive.
    const splitter = heap_mod.valueAsPlainObject(splitter_v) orelse return throwTypeError(realm, "RegExp.prototype[Symbol.split]: species constructor returned non-Object");

    // step 11 — `Let A be ! ArrayCreate(0)`. Allocate an array-
    // exotic JSObject so `Array.isArray(result)` is true.
    const out = realm.heap.allocateObject() catch return error.OutOfMemory;
    out.prototype = realm.intrinsics.array_prototype;
    out.markAsArrayExotic(realm.allocator) catch return error.OutOfMemory;

    // step 12 — `Let lengthA be 0`.
    var length_a: i32 = 0;

    // step 13 — `If limit is undefined, let lim be 2^32 - 1; else
    // lim be ! ToUint32(limit)`.
    const limit_v = argOr(args, 1, Value.undefined_);
    const lim: u32 = if (limit_v.isUndefined())
        std.math.maxInt(u32)
    else lim: {
        const num_v = try intrinsics.toNumber(realm, limit_v);
        break :lim arithToUint32(num_v);
    };

    // step 14 — `If lim is 0, return A`.
    if (lim == 0) {
        intrinsics.setLength(realm, out, 0) catch return error.OutOfMemory;
        return heap_mod.taggedObject(out);
    }

    // step 15 — `Let size be the length of S`. ECMA-262 indices are
    // UTF-16 code units. Cynic stores WTF-8; `utf16.lengthInCodeUnits`
    // converts.
    const utf16 = @import("../utf16.zig");
    const size_usize = utf16.lengthInCodeUnits(s.bytes);
    const size: i64 = @intCast(size_usize);

    // step 16 — `If size = 0, then
    //   a. Let z be ? RegExpExec(splitter, S).
    //   b. If z is not null, return A.
    //   c. Perform ! CreateDataPropertyOrThrow(A, "0", S).
    //   d. Return A.`.
    if (size == 0) {
        const z = try regExpExecGeneric(realm, splitter, s);
        if (!z.isNull()) {
            intrinsics.setLength(realm, out, 0) catch return error.OutOfMemory;
            return heap_mod.taggedObject(out);
        }
        out.set(realm.allocator, "0", Value.fromString(s)) catch return error.OutOfMemory;
        intrinsics.setLength(realm, out, 1) catch return error.OutOfMemory;
        return heap_mod.taggedObject(out);
    }

    // step 17 — `Let p be 0`. step 18 — `Let q be p`. Both indices
    // are in UTF-16 code units.
    var p: i64 = 0;
    var q: i64 = 0;

    // step 19 — `Repeat, while q < size`.
    var ibuf: [24]u8 = undefined;
    while (q < size) {
        // step 19.a — `Perform ? Set(splitter, "lastIndex", q, true)`.
        try setPropertyChainOrThrow(realm, splitter, "lastIndex", Value.fromInt32(@intCast(q)));
        // step 19.b-c — `Let z be ? RegExpExec(splitter, S)`.
        const z = try regExpExecGeneric(realm, splitter, s);
        if (z.isNull()) {
            // step 19.d — `If z is null, set q to
            // AdvanceStringIndex(S, q, unicodeMatching)`.
            q = advanceStringIndex(s.bytes, q, unicode_matching);
            continue;
        }
        const z_obj = heap_mod.valueAsPlainObject(z) orelse return throwTypeError(realm, "RegExp.prototype[Symbol.split]: RegExpExec returned non-Object");
        // step 19.e.i — `Let e be ? ToLength(? Get(splitter,
        // "lastIndex"))`. Then `e = min(e, size)`.
        const li_v = try intrinsics.getPropertyChain(realm, splitter, "lastIndex");
        const e_raw = try intrinsics.toLengthValue(realm, li_v);
        const e: i64 = @min(e_raw, size);
        // step 19.e.iii — `If e = p, set q to
        // AdvanceStringIndex(S, q, unicodeMatching)`.
        if (e == p) {
            q = advanceStringIndex(s.bytes, q, unicode_matching);
            continue;
        }
        // step 19.e.iv — `Else,
        //   1. Let T be the substring of S from p to q.`.
        // Substring is in code-unit space. Convert UTF-16 indices
        // to byte offsets through the WTF-8 buffer.
        const t_slice = utf16.sliceCodeUnits(s.bytes, @intCast(p), @intCast(q));
        const t_str = try jsStringFromUtf16Slice(realm, t_slice);
        //   2. Perform ! CreateDataPropertyOrThrow(A, ToString(lengthA), T).
        var name_slice = std.fmt.bufPrint(&ibuf, "{d}", .{length_a}) catch unreachable;
        const t_key = realm.heap.allocateString(name_slice) catch return error.OutOfMemory;
        out.set(realm.allocator, t_key.bytes, Value.fromString(t_str)) catch return error.OutOfMemory;
        //   3. Set lengthA to lengthA + 1.
        length_a += 1;
        //   4. If lengthA = lim, return A.
        if (@as(u32, @intCast(length_a)) == lim) {
            intrinsics.setLength(realm, out, length_a) catch return error.OutOfMemory;
            return heap_mod.taggedObject(out);
        }
        //   5. Set p to e.
        p = e;
        //   6. Let numberOfCaptures be ? LengthOfArrayLike(z) − 1.
        //      (LengthOfArrayLike: ToLength(? Get(z, "length"))).
        const len_v = try intrinsics.getPropertyChain(realm, z_obj, "length");
        const len_raw = try intrinsics.toLengthValue(realm, len_v);
        const ncap: i64 = if (len_raw > 0) len_raw - 1 else 0;
        //   8. Let i be 1.
        var i: i64 = 1;
        //   9. Repeat, while i ≤ numberOfCaptures.
        while (i <= ncap) : (i += 1) {
            //  9.a — Let nextCapture be ? Get(z, ! ToString(i)).
            var cap_key_buf: [24]u8 = undefined;
            const cap_key = std.fmt.bufPrint(&cap_key_buf, "{d}", .{i}) catch unreachable;
            const next_capture = try intrinsics.getPropertyChain(realm, z_obj, cap_key);
            //  9.c — Perform ! CreateDataPropertyOrThrow(A,
            //         ToString(lengthA), nextCapture).
            name_slice = std.fmt.bufPrint(&ibuf, "{d}", .{length_a}) catch unreachable;
            const cap_idx_key = realm.heap.allocateString(name_slice) catch return error.OutOfMemory;
            out.set(realm.allocator, cap_idx_key.bytes, next_capture) catch return error.OutOfMemory;
            length_a += 1;
            //  9.e — If lengthA = lim, return A.
            if (@as(u32, @intCast(length_a)) == lim) {
                intrinsics.setLength(realm, out, length_a) catch return error.OutOfMemory;
                return heap_mod.taggedObject(out);
            }
        }
        // step 19.e.iv.7 — `Set q to p`.
        q = p;
    }

    // step 20 — `Let T be the substring of S from p to size`.
    const tail_slice = utf16.sliceCodeUnits(s.bytes, @intCast(p), size_usize);
    const tail_str = try jsStringFromUtf16Slice(realm, tail_slice);
    // step 21 — `Perform ! CreateDataPropertyOrThrow(A,
    // ToString(lengthA), T)`.
    const tail_key_slice = std.fmt.bufPrint(&ibuf, "{d}", .{length_a}) catch unreachable;
    const tail_key = realm.heap.allocateString(tail_key_slice) catch return error.OutOfMemory;
    out.set(realm.allocator, tail_key.bytes, Value.fromString(tail_str)) catch return error.OutOfMemory;
    length_a += 1;
    intrinsics.setLength(realm, out, length_a) catch return error.OutOfMemory;
    // step 22 — `Return A`.
    return heap_mod.taggedObject(out);
}

/// §7.3.22 SpeciesConstructor ( O, defaultConstructor ).
///   1. Let C be ? Get(O, "constructor").
///   2. If C is undefined, return defaultConstructor.
///   3. If C is not an Object, throw a TypeError.
///   4. Let S be ? Get(C, @@species).
///   5. If S is undefined or null, return defaultConstructor.
///   6. If IsConstructor(S) is true, return S.
///   7. Throw a TypeError.
fn speciesConstructor(realm: *Realm, source: *JSObject, default_ctor: *JSFunction) NativeError!*JSFunction {
    const ctor_v = try intrinsics.getPropertyChain(realm, source, "constructor");
    if (ctor_v.isUndefined()) return default_ctor;
    // step 3 — non-Object → TypeError. A function value is an
    // Object per §7.2.5; that's the typical RegExp.constructor case.
    var ctor_fn: ?*JSFunction = null;
    var ctor_obj: ?*JSObject = null;
    if (heap_mod.valueAsFunction(ctor_v)) |f| {
        ctor_fn = f;
    } else if (heap_mod.valueAsPlainObject(ctor_v)) |o| {
        ctor_obj = o;
    } else {
        return throwTypeError(realm, "constructor is not an Object");
    }
    // step 4 — `Get(C, @@species)`. For a function-valued ctor,
    // walk function-side properties; for a plain-object ctor, walk
    // the property chain.
    const species_v: Value = if (ctor_fn) |f| blk: {
        // Function objects store own properties on the JSFunction —
        // surface `@@species` via its `.get` (which doesn't fire
        // accessors). For accessor support route through a getter
        // walk on the function's accessors table.
        if (f.accessors.get("@@species")) |acc| {
            if (acc.getter) |getter| {
                const interp = @import("../interpreter.zig");
                const outcome = interp.callJSFunction(realm.allocator, realm, getter, heap_mod.taggedFunction(f), &.{}) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => return error.NativeThrew,
                };
                break :blk switch (outcome) {
                    .value, .yielded => |vv| vv,
                    .thrown => |ex| {
                        realm.pending_exception = ex;
                        return error.NativeThrew;
                    },
                };
            }
            break :blk Value.undefined_;
        }
        break :blk f.get("@@species");
    } else blk: {
        break :blk try intrinsics.getPropertyChain(realm, ctor_obj.?, "@@species");
    };
    // step 5 — undefined / null → default.
    if (species_v.isUndefined() or species_v.isNull()) return default_ctor;
    // step 6 — IsConstructor.
    const species_fn = heap_mod.valueAsFunction(species_v) orelse return throwTypeError(realm, "Symbol.species value is not a constructor");
    if (!species_fn.has_construct or species_fn.is_arrow) return throwTypeError(realm, "Symbol.species value is not a constructor");
    return species_fn;
}

/// §22.2.7.1 RegExpExec ( R, S ).
///   1. Let exec be ? Get(R, "exec").
///   2. If IsCallable(exec), let result be ? Call(exec, R, « S »).
///      Result must be Object or null, else TypeError.
///   3. Else, if R has [[RegExpMatcher]] internal slot, run the
///      built-in RegExpBuiltinExec.
///   4. Else, throw TypeError.
///
/// `regexpProtoSplit`'s receivers are arbitrary objects (the
/// fixtures pass plain `{ exec: function() { ... } }` shells), so
/// we always go through the user-`exec` path when one is callable.
/// When it's not, we fall through to `regexExec` on the JSObject's
/// own `[[RegExpMatcher]]` (Cynic stores this as `regex_bytecode`).
fn regExpExecGeneric(realm: *Realm, r: *JSObject, s: *JSString) NativeError!Value {
    const exec_v = try intrinsics.getPropertyChain(realm, r, "exec");
    if (heap_mod.valueAsFunction(exec_v)) |exec_fn| {
        const interp = @import("../interpreter.zig");
        const call_args = [_]Value{Value.fromString(s)};
        const outcome = interp.callJSFunction(realm.allocator, realm, exec_fn, heap_mod.taggedObject(r), &call_args) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.NativeThrew,
        };
        const v: Value = switch (outcome) {
            .value, .yielded => |x| x,
            .thrown => |ex| {
                realm.pending_exception = ex;
                return error.NativeThrew;
            },
        };
        if (!v.isNull() and heap_mod.valueAsPlainObject(v) == null) {
            return throwTypeError(realm, "RegExpExec: exec must return Object or null");
        }
        return v;
    }
    // No callable `exec` — require a [[RegExpMatcher]]-bearing object.
    if (r.regex_bytecode == null and r.regexp_source == null) {
        return throwTypeError(realm, "RegExpExec: receiver lacks [[RegExpMatcher]]");
    }
    // Fall through to the built-in exec by re-routing through the
    // intrinsic %RegExp.prototype.exec%. This mirrors §22.2.7.2
    // RegExpBuiltinExec without re-implementing it inline.
    const proto = realm.intrinsics.regexp_prototype orelse return throwTypeError(realm, "RegExpExec: %RegExp.prototype% missing");
    const proto_exec = proto.get("exec");
    const exec_proto_fn = heap_mod.valueAsFunction(proto_exec) orelse return throwTypeError(realm, "RegExpExec: %RegExp.prototype.exec% missing");
    const interp = @import("../interpreter.zig");
    const call_args = [_]Value{Value.fromString(s)};
    const outcome = interp.callJSFunction(realm.allocator, realm, exec_proto_fn, heap_mod.taggedObject(r), &call_args) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.NativeThrew,
    };
    return switch (outcome) {
        .value, .yielded => |x| x,
        .thrown => |ex| blk: {
            realm.pending_exception = ex;
            break :blk error.NativeThrew;
        },
    };
}

/// `Set(O, P, V, Throw)` — accessor-chain-aware write. The setter,
/// if any, fires with `this = O`; absent that, the property is
/// written as a data property on `O` *honoring writable*: an
/// existing own data property with `writable: false` raises
/// TypeError per §10.1.9 step 4.b. Spec §7.3.4 propagates a
/// thrown completion from the setter.
fn setPropertyChainOrThrow(realm: *Realm, obj: *JSObject, key: []const u8, value: Value) NativeError!void {
    // Walk the prototype chain looking for an accessor with a
    // setter. If found, invoke it with `this = obj`.
    var cur: ?*JSObject = obj;
    while (cur) |o| {
        if (o.accessors.get(key)) |acc| {
            if (acc.setter) |setter| {
                const interp = @import("../interpreter.zig");
                const args_one = [_]Value{value};
                const outcome = interp.callJSFunction(realm.allocator, realm, setter, heap_mod.taggedObject(obj), &args_one) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => return error.NativeThrew,
                };
                switch (outcome) {
                    .value, .yielded => return,
                    .thrown => |ex| {
                        realm.pending_exception = ex;
                        return error.NativeThrew;
                    },
                }
            }
            // Getter-only accessor — §10.1.9 [[Set]] step 6.c
            // returns false. With Throw=true (the case here) we
            // raise TypeError.
            return throwTypeError(realm, "Cannot set property: accessor has no setter");
        }
        cur = o.prototype;
    }
    // No accessor — §10.1.9 step 4: OrdinaryDefineOwnProperty with
    // a value descriptor. An existing own data property with
    // `writable: false` returns false; under Throw=true that's a
    // TypeError. `setIfWritable` already enforces this.
    const ok = obj.setIfWritable(realm.allocator, key, value) catch return error.OutOfMemory;
    if (!ok) return throwTypeError(realm, "Cannot assign to read-only property");
}

/// AdvanceStringIndex(S, index, unicode) — §22.2.7.3. When the
/// `unicode` flag is set and the current code unit starts a high
/// surrogate followed by a low surrogate, the cursor steps two
/// units. Otherwise it always steps one code unit.
fn advanceStringIndex(s_bytes: []const u8, index: i64, unicode: bool) i64 {
    if (!unicode) return index + 1;
    const utf16 = @import("../utf16.zig");
    const cu_len: i64 = @intCast(utf16.lengthInCodeUnits(s_bytes));
    if (index + 1 >= cu_len) return index + 1;
    const cu_hi = utf16.codeUnitAt(s_bytes, @intCast(index)) orelse return index + 1;
    if (cu_hi < 0xD800 or cu_hi > 0xDBFF) return index + 1;
    const cu_lo = utf16.codeUnitAt(s_bytes, @intCast(index + 1)) orelse return index + 1;
    if (cu_lo < 0xDC00 or cu_lo > 0xDFFF) return index + 1;
    return index + 2;
}

/// Materialize a UTF-16 code-unit substring (held in `utf16.Slice`
/// form) as a JSString with WTF-8 storage. Mirrors the helper in
/// `string.zig` (private there) so split's substring extraction
/// handles mid-surrogate cuts identically.
fn jsStringFromUtf16Slice(realm: *Realm, sl: @import("../utf16.zig").Slice) NativeError!*JSString {
    const utf16 = @import("../utf16.zig");
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(realm.allocator);
    if (sl.head_surrogate != 0)
        utf16.appendCodeUnitAsWtf8(realm.allocator, &buf, sl.head_surrogate) catch return error.OutOfMemory;
    buf.appendSlice(realm.allocator, sl.bytes) catch return error.OutOfMemory;
    if (sl.tail_surrogate != 0)
        utf16.appendCodeUnitAsWtf8(realm.allocator, &buf, sl.tail_surrogate) catch return error.OutOfMemory;
    return realm.heap.allocateString(buf.items) catch return error.OutOfMemory;
}

/// §7.1.7 ToUint32 — the limit argument is coerced through ToNumber
/// (which `regexpProtoSplit` does up-front) and then ToUint32. This
/// is a value-level form mirroring `arith_toUint32` in `string.zig`.
fn arithToUint32(v: Value) u32 {
    if (v.isInt32()) {
        const i = v.asInt32();
        return @bitCast(i);
    }
    if (v.isDouble()) {
        const d = v.asDouble();
        if (std.math.isNan(d) or !std.math.isFinite(d) or d == 0) return 0;
        const sign: f64 = if (d < 0) -1 else 1;
        const abs_d = @abs(d);
        const trunc_d = @trunc(abs_d);
        const reduced = @mod(trunc_d, 4294967296.0);
        const signed = sign * reduced;
        const final = @mod(signed + 4294967296.0, 4294967296.0);
        return @intFromFloat(final);
    }
    if (v.isBool()) return if (v.asBool()) 1 else 0;
    return 0;
}

/// §22.2.5.9 RegExp.prototype [ @@matchAll ] ( string ). A step-by-
/// step traversal of the spec algorithm so each observable side
/// effect (`Get(R, "constructor")`, `Get(R, "flags")`, the per-
/// invocation `Construct(C, « R, flags »)`, the `ToLength(? Get(R,
/// "lastIndex"))` cache, the `Set(matcher, "lastIndex", lastIndex)`
/// write) lines up with the fixtures under
/// `built-ins/RegExp/prototype/Symbol.matchAll/`.
///
/// Returns a fresh RegExpStringIterator chained to
/// `%RegExpStringIteratorPrototype%` whose own slots carry the
/// matcher, the iterated string, the cached `global` /
/// `fullUnicode` booleans, and the `done` flag. The shared `next`
/// (in `string.zig:regexpStringIterNext`) drives `RegExpExec` per
/// pull, advancing zero-width matches via `AdvanceStringIndex`.
fn regexpProtoMatchAll(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    // step 1 — `Let R be the this value`. step 2 — `If R is not
    // an Object, throw a TypeError`.
    const r = heap_mod.valueAsPlainObject(this_value) orelse return throwTypeError(realm, "RegExp.prototype[Symbol.matchAll] called on non-object");

    // step 3 — `Let S be ? ToString(string)`. The `string-tostring-
    // throws` fixture relies on this firing before any other
    // accessor on `R`.
    const s = try stringifyArg(realm, argOr(args, 0, Value.undefined_));

    // step 4 — `Let C be ? SpeciesConstructor(R, %RegExp%)`.
    const builtin_regexp = blk: {
        const ctor_v = realm.globals.get("RegExp") orelse return throwTypeError(realm, "RegExp.prototype[Symbol.matchAll]: %RegExp% missing");
        break :blk heap_mod.valueAsFunction(ctor_v) orelse return throwTypeError(realm, "RegExp.prototype[Symbol.matchAll]: %RegExp% is not callable");
    };
    const c_fn = try speciesConstructor(realm, r, builtin_regexp);

    // step 5 — `Let flags be ? ToString(? Get(R, "flags"))`. The
    // `this-get-flags-throws` / `this-tostring-flags-throws`
    // fixtures rely on these firing in this order.
    const flags_v = try intrinsics.getPropertyChain(realm, r, "flags");
    const flags_s = try intrinsics.stringifyArg(realm, flags_v);

    // step 6 — `Let matcher be ? Construct(C, « R, flags »)`. The
    // `species-constructor` fixture observes the two-argument
    // call shape with the original RegExp and the cloned flag
    // string.
    const splitter_args = [_]Value{ heap_mod.taggedObject(r), Value.fromString(flags_s) };
    const interp = @import("../interpreter.zig");
    const ctor_v = heap_mod.taggedFunction(c_fn);
    const ctor_outcome = interp.constructValue(realm.allocator, realm, ctor_v, &splitter_args, ctor_v) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.NativeThrew,
    };
    const matcher_v: Value = switch (ctor_outcome) {
        .value, .yielded => |v| v,
        .thrown => |ex| {
            realm.pending_exception = ex;
            return error.NativeThrew;
        },
    };
    const matcher = heap_mod.valueAsPlainObject(matcher_v) orelse return throwTypeError(realm, "RegExp.prototype[Symbol.matchAll]: species constructor returned non-Object");

    // step 7 — `Let lastIndex be ? ToLength(? Get(R, "lastIndex"))`.
    // The `this-lastindex-cached` fixture relies on this capturing
    // the value *at @@matchAll time* — a later assignment to
    // `R.lastIndex` must not perturb the iterator.
    // step 8 — `Perform ? Set(matcher, "lastIndex", lastIndex, true)`.
    const li_v = try intrinsics.getPropertyChain(realm, r, "lastIndex");
    const li_i64 = try intrinsics.toLengthValue(realm, li_v);
    try setPropertyChainOrThrow(realm, matcher, "lastIndex", Value.fromInt32(@intCast(@min(li_i64, std.math.maxInt(i32)))));

    // step 9 — `If flags contains "g", let global be true; else
    // false`. step 10 — `If flags contains "u" or "v", let
    // fullUnicode be true; else false`. Per `species-regexp-get-
    // global-throws.js`, `global` is NOT re-read from `matcher`
    // — both flags come from the cloned `flags` string.
    const is_global = std.mem.indexOfScalar(u8, flags_s.bytes, 'g') != null;
    const full_unicode = std.mem.indexOfScalar(u8, flags_s.bytes, 'u') != null or
        std.mem.indexOfScalar(u8, flags_s.bytes, 'v') != null;

    // step 11 — `Return CreateRegExpStringIterator(matcher, S,
    // global, fullUnicode)`. Allocate an iterator object chained to
    // `%RegExpStringIteratorPrototype%`; its own slots carry the
    // [[IteratingRegExp]] / [[IteratedString]] / [[Global]] /
    // [[Unicode]] / [[Done]] state. `string.zig:regexpStringIterNext`
    // reads them.
    const iter = realm.heap.allocateObject() catch return error.OutOfMemory;
    iter.prototype = realm.intrinsics.regexp_string_iterator_prototype orelse realm.intrinsics.object_prototype;
    iter.set(realm.allocator, "__cynic_matchall_re__", heap_mod.taggedObject(matcher)) catch return error.OutOfMemory;
    iter.set(realm.allocator, "__cynic_matchall_input__", Value.fromString(s)) catch return error.OutOfMemory;
    iter.set(realm.allocator, "__cynic_matchall_global__", Value.fromBool(is_global)) catch return error.OutOfMemory;
    iter.set(realm.allocator, "__cynic_matchall_fullUnicode__", Value.fromBool(full_unicode)) catch return error.OutOfMemory;
    iter.set(realm.allocator, "__cynic_matchall_done__", Value.fromBool(false)) catch return error.OutOfMemory;
    return heap_mod.taggedObject(iter);
}

fn regexpConstructor(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const pattern_v = argOr(args, 0, Value.undefined_);
    const flags_v = argOr(args, 1, Value.undefined_);
    // §22.2.4.1 step 4 — if pattern is a RegExp (has [[OriginalSource]] /
    // [[OriginalFlags]] slots), reuse its source and (when flags is
    // undefined) its flags string rather than stringifying the whole
    // regex via `RegExp.prototype.toString`. This is the path
    // SpeciesConstructor in `@@split` / `@@matchAll` takes when it
    // hands `rx` back to `new C(rx, newFlags)`.
    const pattern_is_regex: ?*JSObject = if (heap_mod.valueAsPlainObject(pattern_v)) |po|
        if (po.regexp_source != null) po else null
    else
        null;
    // §22.2.4.1 step 1-3 — when NewTarget is undefined and pattern is
    // already a RegExp with `flags` also undefined, return the
    // pattern unchanged. Otherwise (step 5.a) RegExpAlloc(NewTarget)
    // allocates a fresh instance. Without `new`, `this_value` is the
    // global object (or undefined under strict-mode call); allocate
    // a fresh instance with `%RegExp.prototype%` so the no-new path
    // works like every other "callable constructor" (Boolean, Number,
    // Date, Array, ...).
    const this_obj = heap_mod.valueAsPlainObject(this_value);
    const global_obj: ?*JSObject = realm.globals.target;
    const called_with_new = this_obj != null and this_obj.? != global_obj;
    const inst = if (called_with_new) this_obj.? else blk: {
        if (pattern_is_regex) |po| if (flags_v.isUndefined()) return heap_mod.taggedObject(po);
        const fresh = realm.heap.allocateObject() catch return error.OutOfMemory;
        fresh.prototype = realm.intrinsics.regexp_prototype;
        break :blk fresh;
    };
    const pat_s = if (pattern_v.isUndefined())
        realm.heap.allocateString("") catch return error.OutOfMemory
    else if (pattern_is_regex) |po|
        po.regexp_source.?
    else
        try stringifyArg(realm, pattern_v);
    const flag_s = if (flags_v.isUndefined()) blk: {
        if (pattern_is_regex) |po| if (po.regexp_flags) |f| break :blk f;
        break :blk realm.heap.allocateString("") catch return error.OutOfMemory;
    } else try stringifyArg(realm, flags_v);
    // §22.2.3.4 RegExpInitialize step 1 — reject unknown / duplicate
    // / mutually-exclusive flags at construction time with a
    // SyntaxError, before any bytecode work. The Sputnik
    // `S15.10.4.1_A5_T*` and `S15.10.4.1_A2_T2` fixtures observe
    // this — `new RegExp(".", null)` (flags = "null"), `new
    // RegExp(undefined, "ii")` (dup), `new RegExp("a|b", "z")`,
    // `new RegExp(/1?1/mig, {})` (flags = "[object Object]") all
    // must throw.
    _ = try parseFlagsStrict(realm, flag_s.bytes);
    // §22.2.4 `[[OriginalSource]]` / `[[OriginalFlags]]` — typed
    // JSObject slots, not properties. Surfaced to JS only through
    // the accessors on `RegExp.prototype`.
    inst.regexp_source = pat_s;
    inst.regexp_flags = flag_s;
    // §22.2.4 step 13 — `lastIndex` is `{ w:true, e:false, c:false }`.
    // Default `set` lands at all-true, so JSON.stringify({toJSON: /re/})
    // surfaced "lastIndex" as an enumerable own key.
    inst.setWithFlags(realm.allocator, "lastIndex", Value.fromInt32(0), .{
        .writable = true, .enumerable = false, .configurable = false,
    }) catch return error.OutOfMemory;
    // §22.2.3.2 RegExpInitialize step 12 — compile the pattern
    // eagerly so syntactic errors raise SyntaxError at
    // construction time rather than on the first match. The
    // bytecode is cached on the instance, so methods that go
    // through `ensureBytecode` reuse it.
    _ = try ensureBytecode(realm, inst);
    return heap_mod.taggedObject(inst);
}

// ── Pattern compile cache ───────────────────────────────────────────────────

/// §22.2.3.4 RegExpInitialize step 1.b — validate the flags
/// string strictly: every code unit must be one of
/// `d`, `g`, `i`, `m`, `s`, `u`, `v`, `y`, and no code unit
/// may appear more than once. `u` and `v` are mutually
/// exclusive (step 1.c). Any violation throws SyntaxError.
///
/// Used by the constructor (eagerly, so a bad flag rejects at
/// construction time) and by `ensureBytecode` (defensive — by
/// the time we get there `regexp_flags` has already been
/// vetted, but the bits are recomputed from the stored string).
fn parseFlagsStrict(realm: *Realm, s: []const u8) NativeError!c_int {
    var f: c_int = 0;
    for (s) |ch| {
        const bit: c_int = switch (ch) {
            'g' => LRE_FLAG_GLOBAL,
            'i' => LRE_FLAG_IGNORECASE,
            'm' => LRE_FLAG_MULTILINE,
            's' => LRE_FLAG_DOTALL,
            'u' => LRE_FLAG_UNICODE,
            'y' => LRE_FLAG_STICKY,
            'd' => LRE_FLAG_INDICES,
            'v' => LRE_FLAG_UNICODE_SETS,
            else => {
                const ex = intrinsics.newSyntaxError(realm, "Invalid flags supplied to RegExp constructor") catch return error.OutOfMemory;
                realm.pending_exception = ex;
                return error.NativeThrew;
            },
        };
        if ((f & bit) != 0) {
            const ex = intrinsics.newSyntaxError(realm, "Duplicate RegExp flag") catch return error.OutOfMemory;
            realm.pending_exception = ex;
            return error.NativeThrew;
        }
        f |= bit;
    }
    // §22.2.3.4 step 1.c — `u` and `v` cannot both be set.
    if ((f & LRE_FLAG_UNICODE) != 0 and (f & LRE_FLAG_UNICODE_SETS) != 0) {
        const ex = intrinsics.newSyntaxError(realm, "RegExp flags 'u' and 'v' are mutually exclusive") catch return error.OutOfMemory;
        realm.pending_exception = ex;
        return error.NativeThrew;
    }
    // §22.2.1.5 — `/v` (UnicodeSetsMode) is a Unicode mode: the
    // pattern is interpreted as a sequence of Unicode code points,
    // and matching is surrogate-pair-aware. libregexp gates both
    // of those behaviours on its internal `is_unicode` flag (driven
    // by `LRE_FLAG_UNICODE`), so pair `/v` with `/u` when handing
    // flags to lre_compile / lre_exec — otherwise `new RegExp('𠮷',
    // 'v')` rejects the non-BMP code point at parse time, and even
    // when the pattern is purely BMP the matcher walks the UTF-16
    // input as if non-Unicode, surfacing surrogate halves.
    if ((f & LRE_FLAG_UNICODE_SETS) != 0) f |= LRE_FLAG_UNICODE;
    return f;
}

/// Permissive fallback used after the strict validator has
/// already run on the same string. Same flag-to-bit mapping,
/// no error reporting, no duplicate / unknown check (won't
/// trip — the caller validated already).
fn parseFlags(s: []const u8) c_int {
    var f: c_int = 0;
    for (s) |ch| switch (ch) {
        'g' => f |= LRE_FLAG_GLOBAL,
        'i' => f |= LRE_FLAG_IGNORECASE,
        'm' => f |= LRE_FLAG_MULTILINE,
        's' => f |= LRE_FLAG_DOTALL,
        'u' => f |= LRE_FLAG_UNICODE,
        'y' => f |= LRE_FLAG_STICKY,
        'd' => f |= LRE_FLAG_INDICES,
        'v' => f |= LRE_FLAG_UNICODE_SETS,
        else => {},
    };
    if ((f & LRE_FLAG_UNICODE_SETS) != 0) f |= LRE_FLAG_UNICODE;
    return f;
}

fn ensureBytecode(realm: *Realm, regex_obj: *JSObject) NativeError!?[]u8 {
    if (regex_obj.regex_bytecode) |bc| return bc;
    const src_s = regex_obj.regexp_source orelse return null;
    const flag_str: []const u8 = if (regex_obj.regexp_flags) |f| f.bytes else "";
    const re_flags = parseFlags(flag_str);

    var err_buf: [128]u8 = undefined;
    @memset(&err_buf, 0);
    var bc_len: c_int = 0;
    // §22.2.1 — when the pattern is parsed without `/u` (and
    // `/v`, which is paired with `/u` by parseFlags above),
    // ECMA-262 treats the source as a sequence of UTF-16 code
    // units. libregexp's parser, in that mode, requires the bytes
    // to be CESU-8 — a non-BMP code point split into the two
    // surrogate halves, each encoded as a 3-byte UTF-8 sequence.
    // Cynic stores JSStrings as well-formed UTF-8 (a non-BMP
    // code point is a single 4-byte sequence), so transcode here
    // to keep libregexp happy. Under `/u`/`/v` the buffer is
    // passed through unchanged; libregexp consumes it as UTF-8.
    const fullUnicode = (re_flags & LRE_FLAG_UNICODE) != 0 or (re_flags & LRE_FLAG_UNICODE_SETS) != 0;
    const src_bytes = if (fullUnicode) src_s.bytes else try utf8ToCesu8(realm.allocator, src_s.bytes);
    defer if (!fullUnicode and src_bytes.ptr != src_s.bytes.ptr) realm.allocator.free(src_bytes);
    // libregexp's parser checks `*buf_ptr != '\0'` after the
    // outer disjunction to detect trailing junk, so the input
    // must be NUL-terminated. Copy into a heap buffer + null.
    const src_z = realm.allocator.alloc(u8, src_bytes.len + 1) catch return error.OutOfMemory;
    defer realm.allocator.free(src_z);
    @memcpy(src_z[0..src_bytes.len], src_bytes);
    src_z[src_bytes.len] = 0;
    const bc_ptr = c.lre_compile(
        &bc_len,
        &err_buf[0],
        @intCast(err_buf.len),
        @ptrCast(src_z.ptr),
        src_bytes.len,
        re_flags,
        @ptrCast(realm),
    );
    if (bc_ptr == null or bc_len <= 0) {
        // §22.2.3.2 step 12 — invalid pattern → SyntaxError.
        const msg_len = std.mem.indexOfScalar(u8, &err_buf, 0) orelse err_buf.len;
        const ex = intrinsics.newSyntaxError(realm, err_buf[0..msg_len]) catch return error.OutOfMemory;
        realm.pending_exception = ex;
        return error.NativeThrew;
    }
    const len_u: usize = @intCast(bc_len);
    const bc_slice = bc_ptr[0..len_u];
    regex_obj.regex_bytecode = bc_slice;
    return bc_slice;
}

/// Re-encode a UTF-8 string as CESU-8: every supplementary (non-BMP)
/// code point — a 4-byte UTF-8 sequence — is split into its UTF-16
/// surrogate pair, each surrogate emitted as a 3-byte UTF-8 sequence.
/// BMP code points pass through unchanged. The output is *not* well-
/// formed UTF-8 (the surrogate ranges D800-DFFF are invalid in UTF-8),
/// but libregexp's non-Unicode parser specifically requires this form
/// to count pattern positions in UTF-16 code units.
fn utf8ToCesu8(allocator: std.mem.Allocator, src: []const u8) std.mem.Allocator.Error![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.ensureTotalCapacity(allocator, src.len);
    var i: usize = 0;
    while (i < src.len) {
        const b = src[i];
        if (b < 0x80) {
            out.appendAssumeCapacity(b);
            i += 1;
            continue;
        }
        const seq_len: usize = if (b < 0xE0) 2 else if (b < 0xF0) 3 else 4;
        if (i + seq_len > src.len) {
            try out.appendSlice(allocator, src[i..]);
            break;
        }
        if (seq_len != 4) {
            try out.appendSlice(allocator, src[i .. i + seq_len]);
            i += seq_len;
            continue;
        }
        // 4-byte sequence — decode to codepoint, split into a
        // UTF-16 surrogate pair, emit each as 3-byte UTF-8.
        const cp = (@as(u32, src[i] & 0x07) << 18) |
            (@as(u32, src[i + 1] & 0x3F) << 12) |
            (@as(u32, src[i + 2] & 0x3F) << 6) |
            (@as(u32, src[i + 3] & 0x3F));
        const adjusted = cp - 0x10000;
        const hi: u16 = @intCast(0xD800 + (adjusted >> 10));
        const lo: u16 = @intCast(0xDC00 + (adjusted & 0x3FF));
        try out.ensureUnusedCapacity(allocator, 6);
        out.appendAssumeCapacity(@intCast(0xE0 | (hi >> 12)));
        out.appendAssumeCapacity(@intCast(0x80 | ((hi >> 6) & 0x3F)));
        out.appendAssumeCapacity(@intCast(0x80 | (hi & 0x3F)));
        out.appendAssumeCapacity(@intCast(0xE0 | (lo >> 12)));
        out.appendAssumeCapacity(@intCast(0x80 | ((lo >> 6) & 0x3F)));
        out.appendAssumeCapacity(@intCast(0x80 | (lo & 0x3F)));
        i += 4;
    }
    return out.toOwnedSlice(allocator);
}

// ── UTF-8 ↔ UTF-16 transcoding ──────────────────────────────────────────────

const InputBuf = struct {
    /// UTF-16 code units (matching ECMA-262's regex index space).
    units: []u16,
    /// `byte_for_unit[i]` = offset into the source UTF-8 string
    /// where unit `i` starts. `byte_for_unit[len]` = total UTF-8
    /// byte count, so a pair of unit indices slices cleanly.
    byte_for_unit: []usize,
    allocator: std.mem.Allocator,

    fn deinit(self: *InputBuf) void {
        self.allocator.free(self.units);
        self.allocator.free(self.byte_for_unit);
    }
};

fn buildInputBuf(allocator: std.mem.Allocator, utf8: []const u8) !InputBuf {
    var units: std.ArrayListUnmanaged(u16) = .empty;
    errdefer units.deinit(allocator);
    var map: std.ArrayListUnmanaged(usize) = .empty;
    errdefer map.deinit(allocator);

    var i: usize = 0;
    while (i < utf8.len) {
        const seq_len = std.unicode.utf8ByteSequenceLength(utf8[i]) catch {
            // Invalid UTF-8 — treat the byte as Latin-1.
            try units.append(allocator, utf8[i]);
            try map.append(allocator, i);
            i += 1;
            continue;
        };
        if (i + seq_len > utf8.len) break;
        const cp = std.unicode.utf8Decode(utf8[i .. i + seq_len]) catch {
            try units.append(allocator, utf8[i]);
            try map.append(allocator, i);
            i += 1;
            continue;
        };
        if (cp < 0x10000) {
            try units.append(allocator, @intCast(cp));
            try map.append(allocator, i);
        } else {
            // Encode as a UTF-16 surrogate pair. Both units map
            // back to the same UTF-8 byte (the leading byte of
            // the 4-byte sequence).
            const v = cp - 0x10000;
            const hi: u16 = @intCast(0xD800 + (v >> 10));
            const lo: u16 = @intCast(0xDC00 + (v & 0x3FF));
            try units.append(allocator, hi);
            try map.append(allocator, i);
            try units.append(allocator, lo);
            try map.append(allocator, i);
        }
        i += seq_len;
    }
    try map.append(allocator, utf8.len);

    return .{
        .units = try units.toOwnedSlice(allocator),
        .byte_for_unit = try map.toOwnedSlice(allocator),
        .allocator = allocator,
    };
}

// ── §22.2.5 RegExp.prototype.{exec, test} ──────────────────────────────────

fn regexpExec(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const regex_obj = heap_mod.valueAsPlainObject(this_value) orelse return throwTypeError(realm, "RegExp.prototype.exec called on non-object");
    // §22.2.6.2 step 2 — RequireInternalSlot(R, [[RegExpMatcher]]).
    // The brand check reads the typed `regexp_source` slot, which
    // the RegExp constructor sets. Plain `{}` has it null →
    // TypeError, matching V8 / JSC / SpiderMonkey behavior.
    if (regex_obj.regexp_source == null) {
        return throwTypeError(realm, "RegExp.prototype.exec called on non-RegExp");
    }
    const input_s = try stringifyArg(realm, argOr(args, 0, Value.undefined_));
    const bc = (try ensureBytecode(realm, regex_obj)) orelse return Value.null_;

    var input = buildInputBuf(realm.allocator, input_s.bytes) catch return error.OutOfMemory;
    defer input.deinit();

    const re_flags = c.lre_get_flags(bc.ptr);
    const cap_count_c = c.lre_get_capture_count(bc.ptr);
    const cap_count: usize = @intCast(cap_count_c);
    const is_global = (re_flags & LRE_FLAG_GLOBAL) != 0;
    const is_sticky = (re_flags & LRE_FLAG_STICKY) != 0;

    // §22.2.7.2 RegExpBuiltinExec step 4 — `lastIndex = ?
    // ToLength(? Get(R, "lastIndex"))`. Use the accessor-aware
    // chain walk so a user-installed `lastIndex` getter (or a
    // shadow data property surfaced through the proto chain)
    // fires. ToLength coerces strings / valueOf-objects per spec.
    const last_index_v = try intrinsics.getPropertyChain(realm, regex_obj, "lastIndex");
    const last_index_i64: i64 = try intrinsics.toLengthValue(realm, last_index_v);
    var last_index: usize = if (last_index_i64 > 0) @intCast(last_index_i64) else 0;
    // §22.2.7.2 step 7 — `If global is false and sticky is false,
    // set lastIndex to 0`.
    if (!is_global and !is_sticky) last_index = 0;
    if (last_index > input.units.len) {
        if (is_global or is_sticky) {
            try setPropertyChainOrThrow(realm, regex_obj, "lastIndex", Value.fromInt32(0));
        }
        return Value.null_;
    }

    // `capture` is a 2*cap_count array of byte pointers into the
    // input buffer. Each pair is (start_ptr, end_ptr).
    const captures = realm.allocator.alloc(?[*]const u8, 2 * cap_count) catch return error.OutOfMemory;
    defer realm.allocator.free(captures);
    @memset(captures, null);

    const cbuf: [*]const u8 = @ptrCast(input.units.ptr);
    const ret = c.lre_exec(
        @ptrCast(captures.ptr),
        bc.ptr,
        cbuf,
        @intCast(last_index),
        @intCast(input.units.len),
        // cbuf_type = 1 → 2-byte units. The engine uses
        // `clen << cbuf_type` for the end-pointer math, so type
        // 1 means clen*2 bytes (correct for our u16 buffer).
        // libregexp internally promotes to 2 (UTF-16 with
        // surrogate decoding) when the regex has the `u` flag.
        1,
        @ptrCast(realm),
    );
    if (ret <= 0) {
        // §22.2.7.2 step 15.c.i (sticky failure) / step 16 — when
        // global or sticky, write lastIndex = 0 *honoring writable*:
        // a non-writable `lastIndex` becomes a TypeError. The
        // fixtures (`builtin-failure-y-set-lastindex-err`,
        // `builtin-failure-g-set-lastindex-err`) rely on this.
        if (is_global or is_sticky) {
            try setPropertyChainOrThrow(realm, regex_obj, "lastIndex", Value.fromInt32(0));
        }
        return Value.null_;
    }

    // Translate capture pointers to UTF-16 unit indices.
    const cbuf_addr: usize = @intFromPtr(cbuf);
    const whole_start: usize = if (captures[0]) |p| (@intFromPtr(p) - cbuf_addr) / 2 else 0;
    const whole_end: usize = if (captures[1]) |p| (@intFromPtr(p) - cbuf_addr) / 2 else 0;

    // §22.2.7.2 step 18 — `If global is true or sticky is true,
    // Set(R, "lastIndex", e, true)`. Throw=true → a non-writable
    // own `lastIndex` raises TypeError (per the `builtin-success-
    // {y,g}-set-lastindex-err` fixtures).
    if (is_global or is_sticky) {
        try setPropertyChainOrThrow(realm, regex_obj, "lastIndex", Value.fromInt32(@intCast(whole_end)));
    }

    // Build the result array per §22.2.7.2 — `[whole,...captures]`
    // with `index` and `input` properties on the result.
    const out = realm.heap.allocateObject() catch return error.OutOfMemory;
    out.prototype = realm.intrinsics.array_prototype;
    out.markAsArrayExotic(realm.allocator) catch return error.OutOfMemory;
    const whole_byte_start = input.byte_for_unit[whole_start];
    const whole_byte_end = input.byte_for_unit[whole_end];
    const whole_str = realm.heap.allocateString(input_s.bytes[whole_byte_start..whole_byte_end]) catch return error.OutOfMemory;
    out.set(realm.allocator, "0", Value.fromString(whole_str)) catch return error.OutOfMemory;

    var g: usize = 1;
    while (g < cap_count) : (g += 1) {
        var ibuf: [16]u8 = undefined;
        const islice = std.fmt.bufPrint(&ibuf, "{d}", .{g}) catch unreachable;
        const owned_idx = realm.heap.allocateString(islice) catch return error.OutOfMemory;
        const start_ptr = captures[2 * g];
        const end_ptr = captures[2 * g + 1];
        if (start_ptr == null or end_ptr == null) {
            out.set(realm.allocator, owned_idx.bytes, Value.undefined_) catch return error.OutOfMemory;
        } else {
            const u_start = (@intFromPtr(start_ptr.?) - cbuf_addr) / 2;
            const u_end = (@intFromPtr(end_ptr.?) - cbuf_addr) / 2;
            const b_start = input.byte_for_unit[u_start];
            const b_end = input.byte_for_unit[u_end];
            const cap_str = realm.heap.allocateString(input_s.bytes[b_start..b_end]) catch return error.OutOfMemory;
            out.set(realm.allocator, owned_idx.bytes, Value.fromString(cap_str)) catch return error.OutOfMemory;
        }
    }
    out.set(realm.allocator, "length", Value.fromInt32(@intCast(cap_count))) catch return error.OutOfMemory;
    out.set(realm.allocator, "index", Value.fromInt32(@intCast(whole_start))) catch return error.OutOfMemory;
    out.set(realm.allocator, "input", Value.fromString(input_s)) catch return error.OutOfMemory;

    // §22.2.7.2 RegExpBuiltinExec steps 33-35 — if the pattern
    // contains any GroupName, `groups` is an OrdinaryObject with
    // [[Prototype]] = null and a property per named capture set
    // via CreateDataProperty (so `Object.prototype` setters never
    // fire). When there are no named captures, `groups` is
    // `undefined`. Per step 36 the property is always defined on
    // the result via CreateDataProperty — even the `undefined`
    // case must be an own own property.
    const groups_v = try buildGroupsObject(realm, bc, captures, cap_count, cbuf_addr, &input, input_s);
    out.set(realm.allocator, "groups", groups_v) catch return error.OutOfMemory;

    // §22.2.7.2 step 8 / step 36 — when `hasIndices` (the `d`
    // flag), build the match-indices array per §22.2.7.7
    // MakeIndicesArray and attach it as the `"indices"` own
    // property via CreateDataProperty. The fixtures under
    // `built-ins/RegExp/match-indices/` exercise the
    // shape: each element is either `[startIndex, endIndex]` in
    // UTF-16 code units or `undefined` for an unmatched capture,
    // and `indices.groups` mirrors the named-capture map with the
    // same `[start, end]` pairs (or `undefined`).
    if ((re_flags & LRE_FLAG_INDICES) != 0) {
        const indices_v = try buildIndicesArray(realm, bc, captures, cap_count, cbuf_addr, &input);
        out.set(realm.allocator, "indices", indices_v) catch return error.OutOfMemory;
    }

    return heap_mod.taggedObject(out);
}

/// §22.2.7.7 MakeIndicesArray ( S, indices, groupNames, hasGroups ).
/// Builds the array exposed as `result.indices` on the exec result
/// when the regex has the `/d` flag. Each element is either an
/// Array `[startIndex, endIndex]` (UTF-16 code-unit positions, the
/// same space `result.index` lives in) or `undefined` for an
/// unmatched capture. When the pattern contains any GroupName,
/// `indices.groups` is a null-prototype Object mirroring the
/// named-capture map with the same `[start, end]` pairs (or
/// `undefined`); otherwise `indices.groups` is `undefined` and is
/// always defined via CreateDataProperty.
fn buildIndicesArray(
    realm: *Realm,
    bc: []const u8,
    captures: []const ?[*]const u8,
    cap_count: usize,
    cbuf_addr: usize,
    input: *const InputBuf,
) NativeError!Value {
    // step 6 — `Let A be ! ArrayCreate(n)`. Array-exotic so
    // `Array.isArray(indices)` is true (`indices-array.js`).
    const arr = realm.heap.allocateObject() catch return error.OutOfMemory;
    arr.prototype = realm.intrinsics.array_prototype;
    arr.markAsArrayExotic(realm.allocator) catch return error.OutOfMemory;

    var ibuf: [16]u8 = undefined;
    var g: usize = 0;
    while (g < cap_count) : (g += 1) {
        const start_ptr = captures[2 * g];
        const end_ptr = captures[2 * g + 1];
        const islice = std.fmt.bufPrint(&ibuf, "{d}", .{g}) catch unreachable;
        // step 13.b — unmatched capture (`null` start / end) → the
        // entry is `undefined` (`indices-array-unmatched.js`).
        if (start_ptr == null or end_ptr == null) {
            arr.set(realm.allocator, islice, Value.undefined_) catch return error.OutOfMemory;
            continue;
        }
        // step 13.a / §22.2.7.7 GetMatchIndicesArray — a fresh
        // ordinary Array of `[startIndex, endIndex]`, both
        // numbers (`indices-array-element.js`).
        const u_start = (@intFromPtr(start_ptr.?) - cbuf_addr) / 2;
        const u_end = (@intFromPtr(end_ptr.?) - cbuf_addr) / 2;
        _ = input; // unit indices already in UTF-16 code-unit space
        const pair = realm.heap.allocateObject() catch return error.OutOfMemory;
        pair.prototype = realm.intrinsics.array_prototype;
        pair.markAsArrayExotic(realm.allocator) catch return error.OutOfMemory;
        pair.set(realm.allocator, "0", Value.fromInt32(@intCast(u_start))) catch return error.OutOfMemory;
        pair.set(realm.allocator, "1", Value.fromInt32(@intCast(u_end))) catch return error.OutOfMemory;
        pair.set(realm.allocator, "length", Value.fromInt32(2)) catch return error.OutOfMemory;
        arr.set(realm.allocator, islice, heap_mod.taggedObject(pair)) catch return error.OutOfMemory;
    }
    arr.set(realm.allocator, "length", Value.fromInt32(@intCast(cap_count))) catch return error.OutOfMemory;

    // step 10-12 — `groups` is unconditionally a property on the
    // indices array; when the pattern has named captures it's a
    // null-prototype Object mirroring `result.groups`, else
    // `undefined` (`indices-groups-object-undefined.js`).
    const groups_v = try buildIndicesGroupsObject(realm, bc, captures, cap_count, cbuf_addr);
    arr.set(realm.allocator, "groups", groups_v) catch return error.OutOfMemory;

    return heap_mod.taggedObject(arr);
}

/// Mirror of `buildGroupsObject` but emitting `[startIndex,
/// endIndex]` pairs instead of captured substrings. Walks the
/// libregexp name table at the tail of the bytecode buffer; an
/// empty name entry is an anonymous capture (skipped).
fn buildIndicesGroupsObject(
    realm: *Realm,
    bc: []const u8,
    captures: []const ?[*]const u8,
    cap_count: usize,
    cbuf_addr: usize,
) NativeError!Value {
    const re_flags = c.lre_get_flags(bc.ptr);
    if ((re_flags & LRE_FLAG_NAMED_GROUPS) == 0) return Value.undefined_;
    if (cap_count <= 1) return Value.undefined_;
    const RE_HEADER_LEN: usize = 8;
    const RE_HEADER_BYTECODE_LEN: usize = 4;
    if (bc.len < RE_HEADER_LEN) return Value.undefined_;
    const bc_body_len: usize = @as(usize, bc[RE_HEADER_BYTECODE_LEN]) |
        (@as(usize, bc[RE_HEADER_BYTECODE_LEN + 1]) << 8) |
        (@as(usize, bc[RE_HEADER_BYTECODE_LEN + 2]) << 16) |
        (@as(usize, bc[RE_HEADER_BYTECODE_LEN + 3]) << 24);
    const names_start = RE_HEADER_LEN + bc_body_len;
    if (names_start > bc.len) return Value.undefined_;
    const names = bc[names_start..];

    const groups = realm.heap.allocateObject() catch return error.OutOfMemory;
    // Null prototype mirrors `result.groups` (§22.2.7.2 step 33.a),
    // so `__proto__` lands as a plain own property
    // (`indices-groups-object.js`).
    groups.prototype = null;

    var p: usize = 0;
    var g: usize = 1;
    while (g < cap_count) : (g += 1) {
        const start = p;
        while (p < names.len and names[p] != 0) : (p += 1) {}
        if (p > names.len) break;
        const name = names[start..p];
        if (p < names.len) p += 1;
        if (name.len == 0) continue; // anonymous capture
        const start_ptr = captures[2 * g];
        const end_ptr = captures[2 * g + 1];
        const pair_v: Value = if (start_ptr == null or end_ptr == null) Value.undefined_ else blk: {
            const u_start = (@intFromPtr(start_ptr.?) - cbuf_addr) / 2;
            const u_end = (@intFromPtr(end_ptr.?) - cbuf_addr) / 2;
            const pair = realm.heap.allocateObject() catch return error.OutOfMemory;
            pair.prototype = realm.intrinsics.array_prototype;
            pair.markAsArrayExotic(realm.allocator) catch return error.OutOfMemory;
            pair.set(realm.allocator, "0", Value.fromInt32(@intCast(u_start))) catch return error.OutOfMemory;
            pair.set(realm.allocator, "1", Value.fromInt32(@intCast(u_end))) catch return error.OutOfMemory;
            pair.set(realm.allocator, "length", Value.fromInt32(2)) catch return error.OutOfMemory;
            break :blk heap_mod.taggedObject(pair);
        };
        groups.set(realm.allocator, name, pair_v) catch return error.OutOfMemory;
    }
    return heap_mod.taggedObject(groups);
}

/// Read libregexp's name table appended after the bytecode body
/// when `LRE_FLAG_NAMED_GROUPS` is set. Each capture index
/// (1..capture_count-1) has a NUL-terminated entry — empty for
/// anonymous captures, the source-level name for named ones.
/// Returns `undefined` when the pattern contains no named groups.
fn buildGroupsObject(
    realm: *Realm,
    bc: []const u8,
    captures: []const ?[*]const u8,
    cap_count: usize,
    cbuf_addr: usize,
    input: *const InputBuf,
    input_s: *JSString,
) NativeError!Value {
    const re_flags = c.lre_get_flags(bc.ptr);
    if ((re_flags & LRE_FLAG_NAMED_GROUPS) == 0) return Value.undefined_;
    if (cap_count <= 1) return Value.undefined_;
    // Header is 8 bytes; `bytecode_len` at offset 4 is the bytecode
    // body size (excludes the header). Names start right after.
    const RE_HEADER_LEN: usize = 8;
    const RE_HEADER_BYTECODE_LEN: usize = 4;
    if (bc.len < RE_HEADER_LEN) return Value.undefined_;
    const bc_body_len: usize = @as(usize, bc[RE_HEADER_BYTECODE_LEN]) |
        (@as(usize, bc[RE_HEADER_BYTECODE_LEN + 1]) << 8) |
        (@as(usize, bc[RE_HEADER_BYTECODE_LEN + 2]) << 16) |
        (@as(usize, bc[RE_HEADER_BYTECODE_LEN + 3]) << 24);
    const names_start = RE_HEADER_LEN + bc_body_len;
    if (names_start > bc.len) return Value.undefined_;
    const names = bc[names_start..];

    const groups = realm.heap.allocateObject() catch return error.OutOfMemory;
    // §22.2.7.2 step 33.a — `OrdinaryObjectCreate(null)`. Groups
    // object has a null prototype so `__proto__` keys land as
    // ordinary own properties, not as prototype-chain reads.
    groups.prototype = null;

    var p: usize = 0;
    var g: usize = 1;
    while (g < cap_count) : (g += 1) {
        // Walk to the next NUL.
        const start = p;
        while (p < names.len and names[p] != 0) : (p += 1) {}
        if (p > names.len) break;
        const name = names[start..p];
        // Step past the NUL.
        if (p < names.len) p += 1;
        if (name.len == 0) continue; // anonymous capture
        // Per §22.2.7.2 step 33.b.iii — when the capture has no
        // match, the value is `undefined`; otherwise it's the
        // captured substring.
        const start_ptr = captures[2 * g];
        const end_ptr = captures[2 * g + 1];
        const cap_v: Value = if (start_ptr == null or end_ptr == null) Value.undefined_ else blk: {
            const u_start = (@intFromPtr(start_ptr.?) - cbuf_addr) / 2;
            const u_end = (@intFromPtr(end_ptr.?) - cbuf_addr) / 2;
            const b_start = input.byte_for_unit[u_start];
            const b_end = input.byte_for_unit[u_end];
            const cap_str = realm.heap.allocateString(input_s.bytes[b_start..b_end]) catch return error.OutOfMemory;
            break :blk Value.fromString(cap_str);
        };
        // CreateDataProperty (own, writable / enumerable /
        // configurable). The default `set` lands at all-true,
        // which matches.
        groups.set(realm.allocator, name, cap_v) catch return error.OutOfMemory;
    }
    return heap_mod.taggedObject(groups);
}

fn regexpTest(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const result = try regexpExec(realm, this_value, args);
    return Value.fromBool(!result.isNull());
}

fn regexpToString(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    const obj = heap_mod.valueAsPlainObject(this_value) orelse return throwTypeError(realm, "RegExp.toString on non-object");
    // §22.2.6.15 step 3-4 — `Get(R, "source")` / `Get(R, "flags")`
    // route through the prototype accessor chain so user-overridden
    // getters fire. Use accessor-aware lookups instead of the raw
    // internal slot reads.
    const src_v = intrinsics.getPropertyChain(realm, obj, "source") catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.NativeThrew,
    };
    const flags_v = intrinsics.getPropertyChain(realm, obj, "flags") catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.NativeThrew,
    };
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(realm.allocator);
    out.append(realm.allocator, '/') catch return error.OutOfMemory;
    if (src_v.isString()) {
        const s: *JSString = @ptrCast(@alignCast(src_v.asString()));
        out.appendSlice(realm.allocator, s.bytes) catch return error.OutOfMemory;
    }
    out.append(realm.allocator, '/') catch return error.OutOfMemory;
    if (flags_v.isString()) {
        const s: *JSString = @ptrCast(@alignCast(flags_v.asString()));
        out.appendSlice(realm.allocator, s.bytes) catch return error.OutOfMemory;
    }
    const r = realm.heap.allocateString(out.items) catch return error.OutOfMemory;
    return Value.fromString(r);
}

/// §22.2.7.1 RegExp.escape ( S ) — ES2025. Per-codepoint
/// transform of `S` so the result, used as a regex pattern,
// ── RegExp.prototype getters (§22.2.6.{3,4,5,6,7,9,10,11,13,14}) ───
//
// Each accessor reads from the instance's `[[OriginalSource]]` /
// `[[OriginalFlags]]` internal slots (typed `regexp_source` /
// `regexp_flags` fields on JSObject — never user-visible). The
// receiver must be a RegExp instance; `RegExp.prototype.source`
// called with `this` = the prototype itself (no internal slots)
// is special-cased to return `(?:)` and `""` respectively.

/// `this` is the RegExp.prototype object itself — used by the
/// spec-mandated `RegExp.prototype.source === "(?:)"` invariant.
fn isRegExpPrototypeReceiver(realm: *Realm, this_value: Value) bool {
    const this_obj = heap_mod.valueAsPlainObject(this_value) orelse return false;
    if (realm.intrinsics.regexp_prototype) |p| return this_obj == p;
    return false;
}

/// Read `[[OriginalSource]]` from a RegExp receiver. Returns
/// the underlying string slice when the receiver is a real
/// RegExp instance (typed slot set by the constructor), null
/// otherwise (e.g. `RegExp.prototype` itself, or a plain `{}`).
fn regexpInternalSource(this_value: Value) ?[]const u8 {
    const obj = heap_mod.valueAsPlainObject(this_value) orelse return null;
    const s = obj.regexp_source orelse return null;
    return s.bytes;
}

/// Read `[[OriginalFlags]]`. Same shape as `regexpInternalSource`.
fn regexpInternalFlagsStr(this_value: Value) ?[]const u8 {
    const obj = heap_mod.valueAsPlainObject(this_value) orelse return null;
    const f = obj.regexp_flags orelse return null;
    return f.bytes;
}

fn regexpInternalFlagHas(this_value: Value, ch: u8) ?bool {
    const flags = regexpInternalFlagsStr(this_value) orelse return null;
    return std.mem.indexOfScalar(u8, flags, ch) != null;
}

/// §22.2.6.10 — `EscapeRegExpPattern(P, F)`. Per spec, escape
/// `/` and line terminators in the source so the result, when
/// embedded between forward slashes, parses back to an
/// equivalent pattern. Empty source maps to `(?:)`.
fn escapeRegExpPattern(realm: *Realm, src: []const u8) NativeError!*JSString {
    if (src.len == 0) {
        return realm.heap.allocateString("(?:)") catch return error.OutOfMemory;
    }
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(realm.allocator);
    var i: usize = 0;
    var prev_backslash = false;
    while (i < src.len) : (i += 1) {
        const ch = src[i];
        if (ch == '/' and !prev_backslash) {
            out.appendSlice(realm.allocator, "\\/") catch return error.OutOfMemory;
        } else if (ch == '\n' and !prev_backslash) {
            out.appendSlice(realm.allocator, "\\n") catch return error.OutOfMemory;
        } else if (ch == '\r' and !prev_backslash) {
            out.appendSlice(realm.allocator, "\\r") catch return error.OutOfMemory;
        } else {
            out.append(realm.allocator, ch) catch return error.OutOfMemory;
        }
        prev_backslash = (ch == '\\') and !prev_backslash;
    }
    return realm.heap.allocateString(out.items) catch return error.OutOfMemory;
}

/// §22.2.6.10 `get RegExp.prototype.source`.
fn regexpSourceGetter(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    if (isRegExpPrototypeReceiver(realm, this_value)) {
        const s = realm.heap.allocateString("(?:)") catch return error.OutOfMemory;
        return Value.fromString(s);
    }
    const src = regexpInternalSource(this_value) orelse return throwTypeError(realm, "RegExp.prototype.source called on non-RegExp");
    const escaped = try escapeRegExpPattern(realm, src);
    return Value.fromString(escaped);
}

/// §22.2.6.4 `get RegExp.prototype.flags` — synthesises the
/// flag string from the individual boolean accessors in spec
/// order (`d g i m s u v y`). Reads via `Get(R, "X")` so a
/// user-overridden boolean getter participates.
fn regexpFlagsGetter(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    const obj = heap_mod.valueAsPlainObject(this_value) orelse return throwTypeError(realm, "RegExp.prototype.flags called on non-object");
    var buf: [8]u8 = undefined;
    var n: usize = 0;
    const keys = [_]struct { name: []const u8, ch: u8 }{
        .{ .name = "hasIndices", .ch = 'd' },
        .{ .name = "global", .ch = 'g' },
        .{ .name = "ignoreCase", .ch = 'i' },
        .{ .name = "multiline", .ch = 'm' },
        .{ .name = "dotAll", .ch = 's' },
        .{ .name = "unicode", .ch = 'u' },
        .{ .name = "unicodeSets", .ch = 'v' },
        .{ .name = "sticky", .ch = 'y' },
    };
    for (keys) |k| {
        const v = intrinsics.getPropertyChain(realm, obj, k.name) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.NativeThrew,
        };
        if (intrinsics.toBoolean(v)) {
            buf[n] = k.ch;
            n += 1;
        }
    }
    const s = realm.heap.allocateString(buf[0..n]) catch return error.OutOfMemory;
    return Value.fromString(s);
}

fn regexpFlagBoolGetter(realm: *Realm, this_value: Value, flag_char: u8, name: []const u8) NativeError!Value {
    if (isRegExpPrototypeReceiver(realm, this_value)) return Value.undefined_;
    const has = regexpInternalFlagHas(this_value, flag_char) orelse {
        const msg = std.fmt.allocPrint(realm.allocator, "RegExp.prototype.{s} called on non-RegExp", .{name}) catch return error.OutOfMemory;
        defer realm.allocator.free(msg);
        return throwTypeError(realm, msg);
    };
    return Value.fromBool(has);
}

fn regexpGlobalGetter(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    return regexpFlagBoolGetter(realm, this_value, 'g', "global");
}
fn regexpIgnoreCaseGetter(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    return regexpFlagBoolGetter(realm, this_value, 'i', "ignoreCase");
}
fn regexpMultilineGetter(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    return regexpFlagBoolGetter(realm, this_value, 'm', "multiline");
}
fn regexpDotAllGetter(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    return regexpFlagBoolGetter(realm, this_value, 's', "dotAll");
}
fn regexpUnicodeGetter(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    return regexpFlagBoolGetter(realm, this_value, 'u', "unicode");
}
fn regexpUnicodeSetsGetter(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    return regexpFlagBoolGetter(realm, this_value, 'v', "unicodeSets");
}
fn regexpStickyGetter(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    return regexpFlagBoolGetter(realm, this_value, 'y', "sticky");
}
fn regexpHasIndicesGetter(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    return regexpFlagBoolGetter(realm, this_value, 'd', "hasIndices");
}

/// matches the original string literally. Cynic strings are
/// UTF-8 internally; the spec talks in codepoints + UTF-16
/// units, so we decode → branch → re-encode.
fn regexpEscape(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = this_value;
    const arg = argOr(args, 0, Value.undefined_);
    if (!arg.isString()) return throwTypeError(realm, "RegExp.escape argument must be a string");
    const s: *JSString = @ptrCast(@alignCast(arg.asString()));

    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(realm.allocator);

    var it = std.unicode.Utf8View.initUnchecked(s.bytes).iterator();
    var first = true;
    while (it.nextCodepoint()) |cp| {
        // §22.2.7.1 step 4.a — when the leading codepoint is an
        // ASCII letter or digit, escape it as `\xHH` so the
        // result can be safely concatenated with another regex.
        if (first and isAsciiLetterOrDigit(cp)) {
            try appendHexX(realm, &out, cp);
            first = false;
            continue;
        }
        first = false;
        try encodeForRegExpEscape(realm, &out, cp);
    }

    const r = realm.heap.allocateString(out.items) catch return error.OutOfMemory;
    return Value.fromString(r);
}

fn isAsciiLetterOrDigit(cp: u21) bool {
    return (cp >= '0' and cp <= '9') or (cp >= 'a' and cp <= 'z') or (cp >= 'A' and cp <= 'Z');
}

fn appendHexX(realm: *Realm, out: *std.ArrayListUnmanaged(u8), cp: u21) NativeError!void {
    const hex = "0123456789abcdef";
    out.appendSlice(realm.allocator, "\\x") catch return error.OutOfMemory;
    out.append(realm.allocator, hex[(cp >> 4) & 0xF]) catch return error.OutOfMemory;
    out.append(realm.allocator, hex[cp & 0xF]) catch return error.OutOfMemory;
}

fn appendHexU(realm: *Realm, out: *std.ArrayListUnmanaged(u8), unit: u16) NativeError!void {
    const hex = "0123456789abcdef";
    out.appendSlice(realm.allocator, "\\u") catch return error.OutOfMemory;
    out.append(realm.allocator, hex[(unit >> 12) & 0xF]) catch return error.OutOfMemory;
    out.append(realm.allocator, hex[(unit >> 8) & 0xF]) catch return error.OutOfMemory;
    out.append(realm.allocator, hex[(unit >> 4) & 0xF]) catch return error.OutOfMemory;
    out.append(realm.allocator, hex[unit & 0xF]) catch return error.OutOfMemory;
}

/// §22.2.7.1 EncodeForRegExpEscape ( c ).
fn encodeForRegExpEscape(realm: *Realm, out: *std.ArrayListUnmanaged(u8), cp: u21) NativeError!void {
    // SyntaxCharacter (§22.2.1) + `/` — backslash-prefix.
    switch (cp) {
        '^', '$', '\\', '.', '*', '+', '?', '(', ')', '[', ']', '{', '}', '|', '/' => {
            out.append(realm.allocator, '\\') catch return error.OutOfMemory;
            try appendUtf8(realm, out, cp);
            return;
        },
        else => {},
    }
    // ControlEscape table — \t \n \v \f \r.
    const ctrl: ?u8 = switch (cp) {
        0x09 => 't',
        0x0A => 'n',
        0x0B => 'v',
        0x0C => 'f',
        0x0D => 'r',
        else => null,
    };
    if (ctrl) |ce| {
        out.append(realm.allocator, '\\') catch return error.OutOfMemory;
        out.append(realm.allocator, ce) catch return error.OutOfMemory;
        return;
    }
    // Other punctuators that pair with regex syntax in dangerous
    // ways: `,-=<>#&!%:;@~'\`"`. Plus whitespace / line
    // terminator / surrogate halves.
    if (isOtherPunctuator(cp) or isRegexpEscapeWhitespace(cp) or isLineTerminator(cp) or isSurrogate(cp)) {
        if (cp <= 0xFF) {
            try appendHexX(realm, out, cp);
            return;
        }
        if (cp <= 0xFFFF) {
            try appendHexU(realm, out, @intCast(cp));
            return;
        }
        // Codepoint above the BMP — emit the UTF-16 surrogate
        // pair as `\uHHHH\uHHHH`.
        const adjusted: u21 = cp - 0x10000;
        const hi: u16 = @as(u16, @intCast(0xD800 + (adjusted >> 10)));
        const lo: u16 = @as(u16, @intCast(0xDC00 + (adjusted & 0x3FF)));
        try appendHexU(realm, out, hi);
        try appendHexU(realm, out, lo);
        return;
    }
    // Default: emit the codepoint as-is.
    try appendUtf8(realm, out, cp);
}

fn appendUtf8(realm: *Realm, out: *std.ArrayListUnmanaged(u8), cp: u21) NativeError!void {
    var buf: [4]u8 = undefined;
    const n = std.unicode.utf8Encode(cp, &buf) catch return error.NativeThrew;
    out.appendSlice(realm.allocator, buf[0..n]) catch return error.OutOfMemory;
}

fn isOtherPunctuator(cp: u21) bool {
    return switch (cp) {
        ',', '-', '=', '<', '>', '#', '&', '!', '%', ':', ';', '@', '~', '\'', '`', '"' => true,
        else => false,
    };
}

fn isRegexpEscapeWhitespace(cp: u21) bool {
    // ECMA-262 WhiteSpace production; the controls (\t,\v,\f)
    // are caught by ControlEscape upstream so they never get
    // here.
    return switch (cp) {
        0x0020, 0x00A0, 0x1680, 0x2000, 0x2001, 0x2002, 0x2003, 0x2004, 0x2005, 0x2006, 0x2007, 0x2008, 0x2009, 0x200A, 0x202F, 0x205F, 0x3000, 0xFEFF => true,
        else => false,
    };
}

fn isLineTerminator(cp: u21) bool {
    // \n / \r are caught by ControlEscape upstream; we get LS / PS here.
    return cp == 0x2028 or cp == 0x2029;
}

fn isSurrogate(cp: u21) bool {
    return cp >= 0xD800 and cp <= 0xDFFF;
}

