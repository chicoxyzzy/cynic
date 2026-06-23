//! ECMA-402 structural `Intl` — namespace + service constructors.
//!
//! No CLDR/ICU: constructors accept locales/options, store internal
//! slots, expose `resolvedOptions` / `supportedLocalesOf`, and implement
//! format/compare/select/segment as implementation-defined minimal
//! behaviour (typically `ToString` of the input, or always `"other"`
//! for plurals). Tag validation and canonicalization live in
//! `runtime/intl.zig`.

const std = @import("std");

const Realm = @import("../realm.zig").Realm;
const Value = @import("../value.zig").Value;
const JSString = @import("../string.zig").JSString;
const JSObject = @import("../object.zig").JSObject;
const JSFunction = @import("../function.zig").JSFunction;
const NativeError = @import("../function.zig").NativeError;
const NativeFn = @import("../function.zig").NativeFn;
const heap_mod = @import("../heap.zig");
const intrinsics = @import("../intrinsics.zig");
const lantern = @import("../lantern/interpreter.zig");
const intl = @import("../intl.zig");
const cldr = @import("../cldr.zig");

const installConstructor = intrinsics.installConstructor;
const installNativeMethod = intrinsics.installNativeMethod;
const installNativeMethodOnProto = intrinsics.installNativeMethodOnProto;
const installNativeGetter = intrinsics.installNativeGetter;
const installToStringTag = intrinsics.installToStringTag;
const setNonEnumerable = intrinsics.setNonEnumerable;
const argOr = intrinsics.argOr;
const throwTypeError = intrinsics.throwTypeError;
const throwRangeError = intrinsics.throwRangeError;
const getPropertyChain = intrinsics.getPropertyChain;
const stringifyArg = intrinsics.stringifyArg;
const toNumber = intrinsics.toNumber;
const allocateArray = intrinsics.allocateArray;
const toBoolean = @import("array.zig").toBoolean;

// ── Install ────────────────────────────────────────────────────────────────

pub fn install(realm: *Realm) !void {
    const ns = try realm.heap.allocateObject();
    realm.heap.setObjectPrototype(ns, realm.intrinsics.object_prototype);
    try installToStringTag(realm, ns, "Intl");
    realm.intrinsics.intl_namespace = ns;

    try installNativeMethodOnProto(realm, ns, "getCanonicalLocales", intlGetCanonicalLocales, 1);
    try installNativeMethodOnProto(realm, ns, "supportedValuesOf", intlSupportedValuesOf, 1);

    try installLocale(realm, ns);
    try installCollator(realm, ns);
    try installNumberFormat(realm, ns);
    try installDateTimeFormat(realm, ns);
    try installPluralRules(realm, ns);
    try installRelativeTimeFormat(realm, ns);
    try installListFormat(realm, ns);
    try installDisplayNames(realm, ns);
    try installSegmenter(realm, ns);
    try installDurationFormat(realm, ns);

    try realm.globals.put(realm.allocator, "Intl", heap_mod.taggedObject(ns));
}

fn putCtorOnIntl(realm: *Realm, ns: *JSObject, name: []const u8, ctor: *JSFunction) !void {
    try setNonEnumerable(ns, realm.allocator, name, heap_mod.taggedFunction(ctor));
}

// ── Helpers ────────────────────────────────────────────────────────────────

fn dupeOrEmpty(allocator: std.mem.Allocator, s: []const u8) ![]const u8 {
    if (s.len == 0) return "";
    return try allocator.dupe(u8, s);
}

fn dupeSlice(allocator: std.mem.Allocator, s: []const u8) ![]const u8 {
    if (s.len == 0) return "";
    return try allocator.dupe(u8, s);
}

fn valueToStringSlice(realm: *Realm, v: Value) NativeError![]const u8 {
    const s = try stringifyArg(realm, v);
    return s.flatBytes();
}

fn makeStringValue(realm: *Realm, bytes: []const u8) NativeError!Value {
    const s = realm.heap.allocateString(bytes) catch return error.OutOfMemory;
    return Value.fromString(s);
}

fn makeBoolValue(b: bool) Value {
    return Value.fromBool(b);
}

fn makeNumberValue(n: f64) Value {
    if (n == @trunc(n) and n >= @as(f64, @floatFromInt(std.math.minInt(i32))) and n <= @as(f64, @floatFromInt(std.math.maxInt(i32)))) {
        return Value.fromInt32(@intFromFloat(n));
    }
    return Value.fromDouble(n);
}

fn setDataProp(realm: *Realm, obj: *JSObject, key: []const u8, v: Value) NativeError!void {
    obj.setWithFlags(realm.allocator, key, v, .{
        .writable = true,
        .enumerable = true,
        .configurable = true,
    }) catch return error.OutOfMemory;
}

fn setDataPropStr(realm: *Realm, obj: *JSObject, key: []const u8, bytes: []const u8) NativeError!void {
    if (bytes.len == 0) return;
    try setDataProp(realm, obj, key, try makeStringValue(realm, bytes));
}

fn getOptionsObject(realm: *Realm, options: Value) NativeError!?*JSObject {
    if (options.isUndefined()) return null;
    if (heap_mod.valueAsPlainObject(options)) |o| return o;
    if (heap_mod.valueAsFunction(options) != null) {
        return throwTypeError(realm, "options must be an object or undefined");
    }
    return throwTypeError(realm, "options must be an object or undefined");
}

fn getOptionString(
    realm: *Realm,
    opts: ?*JSObject,
    property: []const u8,
    values: ?[]const []const u8,
    fallback: []const u8,
) NativeError![]const u8 {
    const obj = opts orelse return fallback;
    const v = try getPropertyChain(realm, obj, property);
    if (v.isUndefined()) return fallback;
    const s = try valueToStringSlice(realm, v);
    if (values) |allowed| {
        for (allowed) |a| {
            if (std.mem.eql(u8, s, a)) return a; // interned allowed value
        }
        return throwRangeError(realm, "invalid option value");
    }
    // Caller may need owned copy — return temporary slice from JSString
    // which lives on the heap; we dupe when storing in slots.
    return s;
}

fn getOptionStringOwned(
    realm: *Realm,
    opts: ?*JSObject,
    property: []const u8,
    values: ?[]const []const u8,
    fallback: []const u8,
) NativeError![]const u8 {
    const s = try getOptionString(realm, opts, property, values, fallback);
    // Always own — never return interned option table / fallback pointers
    // (IntlRecord.deinit frees every non-empty slice).
    return realm.allocator.dupe(u8, s) catch return error.OutOfMemory;
}

fn getBooleanOption(realm: *Realm, opts: ?*JSObject, property: []const u8, fallback: bool) NativeError!bool {
    const obj = opts orelse return fallback;
    const v = try getPropertyChain(realm, obj, property);
    if (v.isUndefined()) return fallback;
    return toBoolean(v);
}

fn getLocaleMatcher(realm: *Realm, opts: ?*JSObject) NativeError!intl.LocaleMatcher {
    const s = try getOptionString(realm, opts, "localeMatcher", &.{ "lookup", "best fit" }, "best fit");
    if (std.mem.eql(u8, s, "lookup")) return .lookup;
    return .best_fit;
}

fn requireNew(realm: *Realm, this_value: Value, name: []const u8) NativeError!*JSObject {
    return heap_mod.valueAsPlainObject(this_value) orelse
        throwTypeError(realm, try fmtRequiresNew(realm, name));
}

fn fmtRequiresNew(realm: *Realm, name: []const u8) ![]const u8 {
    // Message is only for the throw helper path; use static-ish via class arena when possible.
    _ = realm;
    _ = name;
    return "Intl constructor requires 'new'";
}

/// §9.2.1 CanonicalizeLocaleList — returns owned slice of owned tags.
fn canonicalizeLocaleList(realm: *Realm, locales: Value) NativeError![]const []const u8 {
    const allocator = realm.allocator;
    if (locales.isUndefined()) {
        return allocator.alloc([]const u8, 0) catch return error.OutOfMemory;
    }

    // Single string shortcut.
    if (locales.isString()) {
        const tag = try valueToStringSlice(realm, locales);
        if (!intl.isStructurallyValidLanguageTag(tag)) return throwRangeError(realm, "invalid language tag");
        const canon = intl.canonicalizeUnicodeLocaleId(allocator, tag) catch return throwRangeError(realm, "invalid language tag");
        const arr = allocator.alloc([]const u8, 1) catch {
            allocator.free(canon);
            return error.OutOfMemory;
        };
        arr[0] = canon;
        return arr;
    }

    // Intl.Locale instance.
    if (heap_mod.valueAsPlainObject(locales)) |obj| {
        if (obj.getIntlRecord()) |rec| {
            if (rec.* == .locale) {
                const tag = rec.locale.locale;
                const canon = allocator.dupe(u8, tag) catch return error.OutOfMemory;
                const arr = allocator.alloc([]const u8, 1) catch {
                    allocator.free(canon);
                    return error.OutOfMemory;
                };
                arr[0] = canon;
                return arr;
            }
        }
    }

    if (!locales.isObject()) return throwTypeError(realm, "locales must be a string or object");

    const obj = heap_mod.valueAsPlainObject(locales) orelse
        return throwTypeError(realm, "locales must be a string or object");

    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(allocator);
    var list: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer {
        for (list.items) |t| allocator.free(t);
        list.deinit(allocator);
    }

    // Array-like: prefer length + indexed access when it looks like an array.
    if (obj.is_array_exotic) {
        const len_v = try getPropertyChain(realm, obj, "length");
        const len_n = try toNumber(realm, len_v);
        const len_f: f64 = if (len_n.isInt32()) @floatFromInt(len_n.asInt32()) else len_n.asDouble();
        const len: usize = if (len_f > 0 and len_f < 1e6) @intFromFloat(len_f) else 0;
        var i: usize = 0;
        while (i < len) : (i += 1) {
            var idx_buf: [24]u8 = undefined;
            const idx_key = std.fmt.bufPrint(&idx_buf, "{d}", .{i}) catch unreachable;
            const el = try getPropertyChain(realm, obj, idx_key);
            if (el.isUndefined()) continue;
            try appendLocaleElement(realm, &list, &seen, el);
        }
        return list.toOwnedSlice(allocator) catch return error.OutOfMemory;
    }

    // Iterator protocol for non-array objects.
    const iter_v = lantern.openIterator(allocator, realm, locales) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.NotIterable => return throwTypeError(realm, "locales is not iterable"),
        error.Propagated => return error.NativeThrew,
        else => return error.NativeThrew,
    };
    const iter_obj = heap_mod.valueAsPlainObject(iter_v) orelse return throwTypeError(realm, "iterator is not an object");
    const next_fn_v = try getPropertyChain(realm, iter_obj, "next");
    const next_fn = heap_mod.valueAsFunction(next_fn_v) orelse return throwTypeError(realm, "iterator.next is not callable");

    var guard: usize = 0;
    while (guard < 10000) : (guard += 1) {
        const outcome = lantern.callJSFunction(allocator, realm, next_fn, iter_v, &.{}) catch return error.NativeThrew;
        const step = switch (outcome) {
            .value => |v| v,
            .thrown => return error.NativeThrew,
            .yielded => return error.NativeThrew,
        };
        const step_obj = heap_mod.valueAsPlainObject(step) orelse return throwTypeError(realm, "iterator result is not an object");
        const done_v = try getPropertyChain(realm, step_obj, "done");
        if (toBoolean(done_v)) break;
        const value_v = try getPropertyChain(realm, step_obj, "value");
        try appendLocaleElement(realm, &list, &seen, value_v);
    }
    return list.toOwnedSlice(allocator) catch return error.OutOfMemory;
}

fn appendLocaleElement(
    realm: *Realm,
    list: *std.ArrayListUnmanaged([]const u8),
    seen: *std.StringHashMapUnmanaged(void),
    el: Value,
) NativeError!void {
    const allocator = realm.allocator;

    const tag_slice: []const u8 = blk: {
        if (heap_mod.valueAsPlainObject(el)) |o| {
            if (o.getIntlRecord()) |rec| {
                if (rec.* == .locale) break :blk rec.locale.locale;
            }
        }
        if (el.isUndefined() or el.isNull()) return throwTypeError(realm, "locale must be a string or object");
        // ToString coerces primitives; objects go through ToPrimitive.
        const s = try valueToStringSlice(realm, el);
        break :blk s;
    };

    if (!intl.isStructurallyValidLanguageTag(tag_slice)) return throwRangeError(realm, "invalid language tag");
    const canon = intl.canonicalizeUnicodeLocaleId(allocator, tag_slice) catch return throwRangeError(realm, "invalid language tag");
    const gop = seen.getOrPut(allocator, canon) catch {
        allocator.free(canon);
        return error.OutOfMemory;
    };
    if (gop.found_existing) {
        allocator.free(canon);
        return;
    }
    gop.key_ptr.* = canon;
    list.append(allocator, canon) catch {
        _ = seen.remove(canon);
        allocator.free(canon);
        return error.OutOfMemory;
    };
}

fn freeLocaleList(allocator: std.mem.Allocator, list: []const []const u8) void {
    for (list) |t| allocator.free(t);
    allocator.free(list);
}

fn resolveServiceLocale(
    realm: *Realm,
    locales: Value,
    opts: ?*JSObject,
) NativeError!struct { locale: []const u8, matcher: intl.LocaleMatcher } {
    const matcher = try getLocaleMatcher(realm, opts);
    const requested = try canonicalizeLocaleList(realm, locales);
    defer freeLocaleList(realm.allocator, requested);
    const r = switch (matcher) {
        .lookup => intl.lookupMatcher(requested),
        .best_fit => intl.bestFitMatcher(requested),
    };
    const canon = intl.canonicalizeUnicodeLocaleId(realm.allocator, r) catch
        realm.allocator.dupe(u8, intl.default_locale) catch return error.OutOfMemory;
    return .{ .locale = canon, .matcher = matcher };
}

fn storeRecord(realm: *Realm, inst: *JSObject, rec: intl.IntlRecord) NativeError!void {
    const box = realm.allocator.create(intl.IntlRecord) catch return error.OutOfMemory;
    box.* = rec;
    inst.setIntlRecord(realm.allocator, box) catch {
        box.deinit(realm.allocator);
        realm.allocator.destroy(box);
        return error.OutOfMemory;
    };
}

fn requireKind(realm: *Realm, this_value: Value, kind: intl.IntlKind) NativeError!*intl.IntlRecord {
    const obj = heap_mod.valueAsPlainObject(this_value) orelse
        return throwTypeError(realm, "Incompatible Receiver");
    const rec = obj.getIntlRecord() orelse return throwTypeError(realm, "Incompatible Receiver");
    if (std.meta.activeTag(rec.*) != kind) return throwTypeError(realm, "Incompatible Receiver");
    return rec;
}

/// Return `locale` with the `-u-` keyword for `key` (and its
/// continuation `type` subtags) removed. Caller owns the slice;
/// preserves the rest of the tag verbatim so a subsequent re-
/// canonicalisation can re-sort the new keyword in.
fn stripUnicodeExtensionKeyword(allocator: std.mem.Allocator, locale: []const u8, key: []const u8) ![]const u8 {
    if (key.len != 2) return allocator.dupe(u8, locale);
    const u_at = std.mem.indexOf(u8, locale, "-u-") orelse return allocator.dupe(u8, locale);
    // Find the start of the key within the `-u-` extension.
    var i = u_at + 3;
    while (i < locale.len) {
        // End of -u- block at the next singleton extension.
        if (i + 1 < locale.len and locale[i] == '-' and locale[i + 2] == '-' and locale[i + 1] != 'u') break;
        const seg_start = i;
        while (i < locale.len and locale[i] != '-') : (i += 1) {}
        const seg = locale[seg_start..i];
        const is_key = seg.len == 2;
        if (is_key and std.mem.eql(u8, seg, key)) {
            // Found the key — extend through following type subtags
            // (3-8 alphanum), stopping at the next 2-ALPHA key or end.
            var rm_end = i;
            while (rm_end < locale.len) {
                if (locale[rm_end] != '-') break;
                const t_start = rm_end + 1;
                if (t_start >= locale.len) break;
                var t_end = t_start;
                while (t_end < locale.len and locale[t_end] != '-') : (t_end += 1) {}
                const t_len = t_end - t_start;
                if (t_len == 2 or t_len == 1) break; // next key or singleton
                rm_end = t_end;
            }
            // Slice out [seg_start - 1, rm_end) — include the preceding '-'.
            const cut_start = seg_start - 1;
            const cut_end = rm_end;
            const out = try allocator.alloc(u8, locale.len - (cut_end - cut_start));
            @memcpy(out[0..cut_start], locale[0..cut_start]);
            @memcpy(out[cut_start..], locale[cut_end..]);
            // If the -u- now has no keywords left, drop it.
            const u_block_start = u_at;
            const u_after_dash = u_at + 2; // points at second '-' after `u`
            if (u_after_dash < out.len and out[u_after_dash] == '-') {
                // Empty -u- (e.g. `en-u-en-US`): adjacent dash means no keyword followed.
                if (u_after_dash + 1 < out.len) {
                    // Singleton extension follows directly — drop the `-u`.
                    const drop = try allocator.alloc(u8, out.len - 2);
                    @memcpy(drop[0..u_block_start], out[0..u_block_start]);
                    @memcpy(drop[u_block_start..], out[u_block_start + 2 ..]);
                    allocator.free(out);
                    return drop;
                }
                // -u- at end of tag — drop trailing `-u`.
                const trimmed = try allocator.alloc(u8, out.len - 2);
                @memcpy(trimmed, out[0 .. out.len - 2]);
                allocator.free(out);
                return trimmed;
            }
            // Or if -u- is at end of tag now.
            if (u_after_dash >= out.len) {
                const trimmed = try allocator.alloc(u8, out.len - 2);
                @memcpy(trimmed, out[0 .. out.len - 2]);
                allocator.free(out);
                return trimmed;
            }
            return out;
        }
        if (i >= locale.len) break;
        i += 1; // skip '-'
    }
    return allocator.dupe(u8, locale);
}

fn supportedLocalesOfImpl(realm: *Realm, args: []const Value) NativeError!Value {
    const locales = argOr(args, 0, Value.undefined_);
    const options = argOr(args, 1, Value.undefined_);
    const opts = try getOptionsObject(realm, options);
    _ = try getLocaleMatcher(realm, opts);
    const list = try canonicalizeLocaleList(realm, locales);
    defer freeLocaleList(realm.allocator, list);

    const arr = allocateArray(realm) catch return error.OutOfMemory;
    var i: i32 = 0;
    for (list) |tag| {
        // Structural: every structurally valid canonical tag is "supported".
        var idx_buf: [24]u8 = undefined;
        const idx_key = std.fmt.bufPrint(&idx_buf, "{d}", .{i}) catch unreachable;
        const sv = try makeStringValue(realm, tag);
        arr.set(realm.allocator, idx_key, sv) catch return error.OutOfMemory;
        i += 1;
    }
    arr.setArrayLength(realm.allocator, @intCast(i)) catch return error.OutOfMemory;
    return heap_mod.taggedObject(arr);
}

fn makeResolvedBase(realm: *Realm, locale: []const u8) NativeError!*JSObject {
    const obj = realm.heap.allocateObject() catch return error.OutOfMemory;
    realm.heap.setObjectPrototype(obj, realm.intrinsics.object_prototype);
    try setDataProp(realm, obj, "locale", try makeStringValue(realm, locale));
    return obj;
}

// ── Intl namespace methods ──────────────────────────────────────────────────

fn intlGetCanonicalLocales(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = this_value;
    const locales = argOr(args, 0, Value.undefined_);
    const list = try canonicalizeLocaleList(realm, locales);
    defer freeLocaleList(realm.allocator, list);
    const arr = allocateArray(realm) catch return error.OutOfMemory;
    var i: i32 = 0;
    for (list) |tag| {
        var idx_buf: [24]u8 = undefined;
        const idx_key = std.fmt.bufPrint(&idx_buf, "{d}", .{i}) catch unreachable;
        arr.set(realm.allocator, idx_key, try makeStringValue(realm, tag)) catch return error.OutOfMemory;
        i += 1;
    }
    arr.setArrayLength(realm.allocator, @intCast(i)) catch return error.OutOfMemory;
    return heap_mod.taggedObject(arr);
}

fn intlSupportedValuesOf(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = this_value;
    const key_v = argOr(args, 0, Value.undefined_);
    const key = try valueToStringSlice(realm, key_v);
    const values: []const []const u8 = if (std.mem.eql(u8, key, "calendar"))
        &intl.supported_calendars
    else if (std.mem.eql(u8, key, "collation"))
        &intl.supported_collations
    else if (std.mem.eql(u8, key, "currency"))
        &intl.supported_currencies
    else if (std.mem.eql(u8, key, "numberingSystem"))
        &intl.supported_numbering_systems
    else if (std.mem.eql(u8, key, "timeZone"))
        &intl.supported_time_zones
    else if (std.mem.eql(u8, key, "unit"))
        &intl.supported_units
    else
        return throwRangeError(realm, "invalid key for supportedValuesOf");

    const arr = allocateArray(realm) catch return error.OutOfMemory;
    var i: i32 = 0;
    for (values) |v| {
        var idx_buf: [24]u8 = undefined;
        const idx_key = std.fmt.bufPrint(&idx_buf, "{d}", .{i}) catch unreachable;
        arr.set(realm.allocator, idx_key, try makeStringValue(realm, v)) catch return error.OutOfMemory;
        i += 1;
    }
    arr.setArrayLength(realm.allocator, @intCast(i)) catch return error.OutOfMemory;
    return heap_mod.taggedObject(arr);
}

// ── Intl.Locale ────────────────────────────────────────────────────────────

fn installLocale(realm: *Realm, ns: *JSObject) !void {
    const r = try installConstructor(realm, .{
        .name = "Locale",
        .ctor = localeConstructor,
        .arity = 1,
        .is_class = true,
        .set_home_object = true,
        .to_string_tag = "Intl.Locale",
        .install_global = false,
    });
    const proto = r.proto;
    try installNativeGetter(realm, proto, "baseName", localeBaseName);
    try installNativeGetter(realm, proto, "calendar", localeCalendar);
    try installNativeGetter(realm, proto, "caseFirst", localeCaseFirst);
    try installNativeGetter(realm, proto, "collation", localeCollation);
    try installNativeGetter(realm, proto, "hourCycle", localeHourCycle);
    try installNativeGetter(realm, proto, "language", localeLanguage);
    try installNativeGetter(realm, proto, "numberingSystem", localeNumberingSystem);
    try installNativeGetter(realm, proto, "numeric", localeNumeric);
    try installNativeGetter(realm, proto, "region", localeRegion);
    try installNativeGetter(realm, proto, "script", localeScript);
    try installNativeMethodOnProto(realm, proto, "toString", localeToString, 0);
    try installNativeMethodOnProto(realm, proto, "maximize", localeMaximize, 0);
    try installNativeMethodOnProto(realm, proto, "minimize", localeMinimize, 0);
    realm.intrinsics.intl_locale_constructor = r.ctor;
    realm.intrinsics.intl_locale_prototype = proto;
    try putCtorOnIntl(realm, ns, "Locale", r.ctor);
}

fn localeConstructor(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const inst = try requireNew(realm, this_value, "Locale");
    const tag_v = argOr(args, 0, Value.undefined_);
    if (tag_v.isUndefined()) return throwTypeError(realm, "Intl.Locale requires a tag argument");

    const options = argOr(args, 1, Value.undefined_);
    const opts = try getOptionsObject(realm, options);

    var tag_slice: []const u8 = undefined;
    if (heap_mod.valueAsPlainObject(tag_v)) |o| {
        if (o.getIntlRecord()) |rec| {
            if (rec.* == .locale) {
                tag_slice = rec.locale.locale;
            } else {
                tag_slice = try valueToStringSlice(realm, tag_v);
            }
        } else {
            tag_slice = try valueToStringSlice(realm, tag_v);
        }
    } else {
        tag_slice = try valueToStringSlice(realm, tag_v);
    }

    if (!intl.isStructurallyValidLanguageTag(tag_slice)) return throwRangeError(realm, "invalid language tag");
    var canon = intl.canonicalizeUnicodeLocaleId(realm.allocator, tag_slice) catch return throwRangeError(realm, "invalid language tag");
    errdefer realm.allocator.free(canon);

    // Apply option overrides by appending unicode extensions (structural).
    if (opts) |o| {
        // §14.1.1 InitializeLocale + §14.1.3 ApplyUnicodeExtensionToTag —
        // validate every option value before it lands in the tag.
        // `kind` chooses the validator: .type for the open `alphanum{3,8}`
        // grammar (calendar / collation / numberingSystem); the rest are
        // closed enumerations from the spec.
        const ValueKind = enum { type, hour_cycle, case_first };
        const apply = struct {
            fn kw(realm2: *Realm, locale_in: []const u8, key: []const u8, prop: []const u8, kind: ValueKind, o2: *JSObject) NativeError![]const u8 {
                const v = try getPropertyChain(realm2, o2, prop);
                if (v.isUndefined()) return locale_in;
                const s = try valueToStringSlice(realm2, v);
                const ok = switch (kind) {
                    .type => intl.isValidUnicodeType(s),
                    .hour_cycle => std.mem.eql(u8, s, "h11") or std.mem.eql(u8, s, "h12") or std.mem.eql(u8, s, "h23") or std.mem.eql(u8, s, "h24"),
                    .case_first => std.mem.eql(u8, s, "upper") or std.mem.eql(u8, s, "lower") or std.mem.eql(u8, s, "false"),
                };
                if (!ok) return throwRangeError(realm2, "invalid Locale option value");
                // §14.1.3 ApplyUnicodeExtensionToTag — the option value
                // overrides any existing -u- keyword for the same key.
                // Strip the existing keyword (if any) so the new one wins
                // after re-canonicalisation.
                const stripped = if (intl.unicodeExtensionValue(locale_in, key) != null)
                    stripUnicodeExtensionKeyword(realm2.allocator, locale_in, key) catch return error.OutOfMemory
                else
                    locale_in;
                if (stripped.ptr != locale_in.ptr) realm2.allocator.free(locale_in);
                const has_u = std.mem.indexOf(u8, stripped, "-u-") != null;
                const out = if (has_u)
                    std.fmt.allocPrint(realm2.allocator, "{s}-{s}-{s}", .{ stripped, key, s })
                else
                    std.fmt.allocPrint(realm2.allocator, "{s}-u-{s}-{s}", .{ stripped, key, s });
                const owned = out catch return error.OutOfMemory;
                realm2.allocator.free(stripped);
                return owned;
            }
        }.kw;
        canon = try apply(realm, canon, "ca", "calendar", .type, o);
        canon = try apply(realm, canon, "co", "collation", .type, o);
        canon = try apply(realm, canon, "hc", "hourCycle", .hour_cycle, o);
        canon = try apply(realm, canon, "kf", "caseFirst", .case_first, o);
        canon = try apply(realm, canon, "nu", "numberingSystem", .type, o);

        // §14.1.2 ApplyOptionsToTag — language/script/region options
        // are validated structurally and rejected on grammar mismatch.
        // Full tag rewrite (replace components in `canon`) is structural
        // future work; we already throw on the failure modes test262
        // exercises (empty string / wrong shape).
        const opt_lang_v = try getPropertyChain(realm, o, "language");
        if (!opt_lang_v.isUndefined()) {
            const s = try valueToStringSlice(realm, opt_lang_v);
            if (!intl.isValidLanguageSubtag(s)) return throwRangeError(realm, "invalid Locale language option");
        }
        const opt_script_v = try getPropertyChain(realm, o, "script");
        if (!opt_script_v.isUndefined()) {
            const s = try valueToStringSlice(realm, opt_script_v);
            if (!intl.isValidScriptSubtag(s)) return throwRangeError(realm, "invalid Locale script option");
        }
        const opt_region_v = try getPropertyChain(realm, o, "region");
        if (!opt_region_v.isUndefined()) {
            const s = try valueToStringSlice(realm, opt_region_v);
            if (!intl.isValidRegionSubtag(s)) return throwRangeError(realm, "invalid Locale region option");
        }
        const num_v = try getPropertyChain(realm, o, "numeric");
        if (!num_v.isUndefined()) {
            const b = toBoolean(num_v);
            const val: []const u8 = if (b) "true" else "false";
            if (intl.unicodeExtensionValue(canon, "kn") == null) {
                const has_u = std.mem.indexOf(u8, canon, "-u-") != null;
                const out = if (has_u)
                    std.fmt.allocPrint(realm.allocator, "{s}-kn-{s}", .{ canon, val })
                else
                    std.fmt.allocPrint(realm.allocator, "{s}-u-kn-{s}", .{ canon, val });
                const owned = out catch return error.OutOfMemory;
                realm.allocator.free(canon);
                canon = owned;
            }
        }
        const recanon = intl.canonicalizeUnicodeLocaleId(realm.allocator, canon) catch canon;
        if (recanon.ptr != canon.ptr) {
            realm.allocator.free(canon);
            canon = recanon;
        }
    }

    const slots = intl.parseLocaleComponents(realm.allocator, canon) catch return error.OutOfMemory;
    realm.allocator.free(canon); // parseLocaleComponents dupes locale
    try storeRecord(realm, inst, .{ .locale = slots });
    return heap_mod.taggedObject(inst);
}

fn localeSlots(realm: *Realm, this_value: Value) NativeError!*intl.LocaleSlots {
    const rec = try requireKind(realm, this_value, .locale);
    return &rec.locale;
}

fn localeBaseName(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    const s = try localeSlots(realm, this_value);
    return makeStringValue(realm, s.base_name);
}
fn localeCalendar(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    const s = try localeSlots(realm, this_value);
    if (s.calendar.len == 0) return Value.undefined_;
    return makeStringValue(realm, s.calendar);
}
fn localeCaseFirst(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    const s = try localeSlots(realm, this_value);
    if (s.case_first.len == 0) return Value.undefined_;
    return makeStringValue(realm, s.case_first);
}
fn localeCollation(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    const s = try localeSlots(realm, this_value);
    if (s.collation.len == 0) return Value.undefined_;
    return makeStringValue(realm, s.collation);
}
fn localeHourCycle(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    const s = try localeSlots(realm, this_value);
    if (s.hour_cycle.len == 0) return Value.undefined_;
    return makeStringValue(realm, s.hour_cycle);
}
fn localeLanguage(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    const s = try localeSlots(realm, this_value);
    return makeStringValue(realm, s.language);
}
fn localeNumberingSystem(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    const s = try localeSlots(realm, this_value);
    if (s.numbering_system.len == 0) return Value.undefined_;
    return makeStringValue(realm, s.numbering_system);
}
fn localeNumeric(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    const s = try localeSlots(realm, this_value);
    return makeBoolValue(s.numeric);
}
fn localeRegion(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    const s = try localeSlots(realm, this_value);
    if (s.region.len == 0) return Value.undefined_;
    return makeStringValue(realm, s.region);
}
fn localeScript(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    const s = try localeSlots(realm, this_value);
    if (s.script.len == 0) return Value.undefined_;
    return makeStringValue(realm, s.script);
}
fn localeToString(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    const s = try localeSlots(realm, this_value);
    return makeStringValue(realm, s.locale);
}
fn localeMaximize(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    // Structural: no likelySubtags — return a new Locale with same tag.
    const s = try localeSlots(realm, this_value);
    return createLocaleFromTag(realm, s.locale);
}
fn localeMinimize(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    const s = try localeSlots(realm, this_value);
    return createLocaleFromTag(realm, s.locale);
}

fn createLocaleFromTag(realm: *Realm, tag: []const u8) NativeError!Value {
    const inst = realm.heap.allocateObject() catch return error.OutOfMemory;
    realm.heap.setObjectPrototype(inst, realm.intrinsics.intl_locale_prototype.?);
    const slots = intl.parseLocaleComponents(realm.allocator, tag) catch return error.OutOfMemory;
    try storeRecord(realm, inst, .{ .locale = slots });
    return heap_mod.taggedObject(inst);
}

// ── Service constructor install helpers ────────────────────────────────────

const ServiceSpec = struct {
    name: []const u8,
    ctor: NativeFn,
    arity: u8,
    to_string_tag: []const u8,
    methods: []const struct { name: []const u8, fn_ptr: NativeFn, params: u8 },
    supported_locales_of: NativeFn,
    set_ctor_intrinsic: *const fn (*Realm, *JSFunction) void,
    set_proto_intrinsic: *const fn (*Realm, *JSObject) void,
};

fn installService(realm: *Realm, ns: *JSObject, spec: ServiceSpec) !void {
    const r = try installConstructor(realm, .{
        .name = spec.name,
        .ctor = spec.ctor,
        .arity = spec.arity,
        .is_class = true,
        .set_home_object = true,
        .to_string_tag = spec.to_string_tag,
        .install_global = false,
    });
    for (spec.methods) |m| {
        try installNativeMethodOnProto(realm, r.proto, m.name, m.fn_ptr, m.params);
    }
    try installNativeMethod(realm, r.ctor, "supportedLocalesOf", spec.supported_locales_of, 1);
    spec.set_ctor_intrinsic(realm, r.ctor);
    spec.set_proto_intrinsic(realm, r.proto);
    try putCtorOnIntl(realm, ns, spec.name, r.ctor);
}

/// §10.3.5 (Collator) / §11.3.5 (NumberFormat) / §12.3.5 (DateTimeFormat)
/// — the spec exposes `compare` / `format` as **accessor** properties
/// whose get returns a function bound to the service instance, so user
/// code may pull the function off the receiver and call it free:
///
///   var f = collator.compare;
///   sorted.sort(f);   // `this === undefined` here, but f still uses
///                     // the collator captured at the getter call.
///
/// Mirror that here: a getter brand-checks `this`, then allocates a
/// bound wrapper whose `[[BoundThis]]` is the service instance. The
/// interpreter's existing bound-function dispatch unwraps before the
/// worker runs, so the worker still sees `this_value = service`. We
/// allocate fresh on every access (no cache) — caching the bound
/// function on the receiver would need a GC mark walk for the cached
/// `Value`, which is the Metla agent's domain. Identity
/// (`c.compare === c.compare`) is therefore observably false here; the
/// failing test262 fixtures that motivated this fix do not depend on
/// identity, only on detached invocation working.
fn makeBoundServiceFunction(
    realm: *Realm,
    this_value: Value,
    worker: NativeFn,
    name: []const u8,
    params: u8,
) NativeError!Value {
    const inner = realm.heap.allocateFunctionNative(realm, worker, params, name) catch return error.OutOfMemory;
    const bound = realm.heap.allocateFunctionNative(realm, worker, params, name) catch return error.OutOfMemory;
    realm.heap.setBoundTarget(bound, inner);
    realm.heap.setBoundThis(bound, this_value);
    bound.has_construct = false;
    return heap_mod.taggedFunction(bound);
}

// ── Collator ───────────────────────────────────────────────────────────────

fn installCollator(realm: *Realm, ns: *JSObject) !void {
    try installService(realm, ns, .{
        .name = "Collator",
        .ctor = collatorConstructor,
        .arity = 0,
        .to_string_tag = "Intl.Collator",
        .methods = &.{
            // §10.3.5 — `compare` is an accessor (getter returning a bound
            // function), installed below once installService has set
            // intl_collator_prototype.
            .{ .name = "resolvedOptions", .fn_ptr = collatorResolvedOptions, .params = 0 },
        },
        .supported_locales_of = anySupportedLocalesOf,
        .set_ctor_intrinsic = struct {
            fn f(r: *Realm, c: *JSFunction) void {
                r.intrinsics.intl_collator_constructor = c;
            }
        }.f,
        .set_proto_intrinsic = struct {
            fn f(r: *Realm, p: *JSObject) void {
                r.intrinsics.intl_collator_prototype = p;
            }
        }.f,
    });
    // §10.3.5 — `Intl.Collator.prototype.compare` is an accessor.
    const proto = realm.intrinsics.intl_collator_prototype.?;
    try installNativeGetter(realm, proto, "compare", collatorCompareGetter);
}

fn collatorCompareGetter(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    _ = try requireKind(realm, this_value, .collator);
    return makeBoundServiceFunction(realm, this_value, collatorCompare, "compare", 2);
}

fn anySupportedLocalesOf(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = this_value;
    return supportedLocalesOfImpl(realm, args);
}

fn collatorConstructor(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    // Callable without new? Spec allows legacy; we require new via is_class.
    const inst = try requireNew(realm, this_value, "Collator");
    const locales = argOr(args, 0, Value.undefined_);
    const options = argOr(args, 1, Value.undefined_);
    const opts = try getOptionsObject(realm, options);
    const resolved = try resolveServiceLocale(realm, locales, opts);

    var slots: intl.CollatorSlots = .{};
    slots.base.locale = resolved.locale;
    slots.usage = try getOptionStringOwned(realm, opts, "usage", &.{ "sort", "search" }, "sort");
    slots.sensitivity = try getOptionStringOwned(realm, opts, "sensitivity", &.{ "base", "accent", "case", "variant" }, "variant");
    slots.ignore_punctuation = try getBooleanOption(realm, opts, "ignorePunctuation", false);
    slots.numeric = try getBooleanOption(realm, opts, "numeric", false);
    slots.case_first = try getOptionStringOwned(realm, opts, "caseFirst", &.{ "upper", "lower", "false" }, "false");
    slots.collation = realm.allocator.dupe(u8, "default") catch return error.OutOfMemory;

    try storeRecord(realm, inst, .{ .collator = slots });
    return heap_mod.taggedObject(inst);
}

fn collatorCompare(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = try requireKind(realm, this_value, .collator);
    const x = try valueToStringSlice(realm, argOr(args, 0, Value.undefined_));
    const y = try valueToStringSlice(realm, argOr(args, 1, Value.undefined_));
    const ord = std.mem.order(u8, x, y);
    const n: i32 = switch (ord) {
        .lt => -1,
        .eq => 0,
        .gt => 1,
    };
    return Value.fromInt32(n);
}

fn collatorResolvedOptions(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    const rec = try requireKind(realm, this_value, .collator);
    const s = rec.collator;
    const obj = try makeResolvedBase(realm, s.base.locale);
    try setDataProp(realm, obj, "usage", try makeStringValue(realm, if (s.usage.len > 0) s.usage else "sort"));
    try setDataProp(realm, obj, "sensitivity", try makeStringValue(realm, if (s.sensitivity.len > 0) s.sensitivity else "variant"));
    try setDataProp(realm, obj, "ignorePunctuation", makeBoolValue(s.ignore_punctuation));
    try setDataProp(realm, obj, "collation", try makeStringValue(realm, if (s.collation.len > 0) s.collation else "default"));
    try setDataProp(realm, obj, "numeric", makeBoolValue(s.numeric));
    try setDataProp(realm, obj, "caseFirst", try makeStringValue(realm, if (s.case_first.len > 0) s.case_first else "false"));
    return heap_mod.taggedObject(obj);
}

// ── NumberFormat ───────────────────────────────────────────────────────────

fn installNumberFormat(realm: *Realm, ns: *JSObject) !void {
    try installService(realm, ns, .{
        .name = "NumberFormat",
        .ctor = numberFormatConstructor,
        .arity = 0,
        .to_string_tag = "Intl.NumberFormat",
        .methods = &.{
            // §11.3.5 — `format` is an accessor (see `makeBoundServiceFunction`).
            .{ .name = "formatToParts", .fn_ptr = numberFormatFormatToParts, .params = 1 },
            .{ .name = "resolvedOptions", .fn_ptr = numberFormatResolvedOptions, .params = 0 },
        },
        .supported_locales_of = anySupportedLocalesOf,
        .set_ctor_intrinsic = struct {
            fn f(r: *Realm, c: *JSFunction) void {
                r.intrinsics.intl_number_format_constructor = c;
            }
        }.f,
        .set_proto_intrinsic = struct {
            fn f(r: *Realm, p: *JSObject) void {
                r.intrinsics.intl_number_format_prototype = p;
            }
        }.f,
    });
    // §11.3.5 — `Intl.NumberFormat.prototype.format` is an accessor.
    const proto = realm.intrinsics.intl_number_format_prototype.?;
    try installNativeGetter(realm, proto, "format", numberFormatFormatGetter);
}

fn numberFormatFormatGetter(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    _ = try requireKind(realm, this_value, .number_format);
    return makeBoundServiceFunction(realm, this_value, numberFormatFormat, "format", 1);
}

fn numberFormatConstructor(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const inst = try requireNew(realm, this_value, "NumberFormat");
    const locales = argOr(args, 0, Value.undefined_);
    const options = argOr(args, 1, Value.undefined_);
    const opts = try getOptionsObject(realm, options);
    const resolved = try resolveServiceLocale(realm, locales, opts);

    var slots: intl.NumberFormatSlots = .{};
    slots.base.locale = resolved.locale;
    slots.base.numbering_system = realm.allocator.dupe(u8, "latn") catch return error.OutOfMemory;
    slots.style = try getOptionStringOwned(realm, opts, "style", &.{ "decimal", "percent", "currency", "unit" }, "decimal");
    if (std.mem.eql(u8, slots.style, "currency")) {
        const cur = try getOptionString(realm, opts, "currency", null, "");
        if (cur.len == 0) return throwTypeError(realm, "currency option required for currency style");
        if (cur.len != 3) return throwRangeError(realm, "invalid currency code");
        var up: [3]u8 = undefined;
        for (cur, 0..) |c, i| {
            if (c >= 'a' and c <= 'z') up[i] = c - 32 else if (c >= 'A' and c <= 'Z') up[i] = c else return throwRangeError(realm, "invalid currency code");
        }
        slots.currency = try realm.allocator.dupe(u8, &up);
        slots.currency_display = try getOptionStringOwned(realm, opts, "currencyDisplay", &.{ "code", "symbol", "narrowSymbol", "name" }, "symbol");
        slots.currency_sign = try getOptionStringOwned(realm, opts, "currencySign", &.{ "standard", "accounting" }, "standard");
    }
    if (std.mem.eql(u8, slots.style, "unit")) {
        const u = try getOptionString(realm, opts, "unit", null, "");
        if (u.len == 0) return throwTypeError(realm, "unit option required for unit style");
        slots.unit = try realm.allocator.dupe(u8, u);
        slots.unit_display = try getOptionStringOwned(realm, opts, "unitDisplay", &.{ "short", "narrow", "long" }, "short");
    }
    slots.notation = try getOptionStringOwned(realm, opts, "notation", &.{ "standard", "scientific", "engineering", "compact" }, "standard");
    slots.sign_display = try getOptionStringOwned(realm, opts, "signDisplay", &.{ "auto", "never", "always", "exceptZero", "negative" }, "auto");

    try storeRecord(realm, inst, .{ .number_format = slots });
    return heap_mod.taggedObject(inst);
}

fn numberFormatFormat(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = try requireKind(realm, this_value, .number_format);
    const v = argOr(args, 0, Value.undefined_);
    // Structural: ToString(ToNumber(value)) / BigInt ToString.
    if (heap_mod.isBigInt(v)) {
        return makeStringValue(realm, try valueToStringSlice(realm, v));
    }
    const n = try toNumber(realm, v);
    return makeStringValue(realm, try valueToStringSlice(realm, n));
}

fn numberFormatFormatToParts(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const formatted = try numberFormatFormat(realm, this_value, args);
    const arr = allocateArray(realm) catch return error.OutOfMemory;
    const part = realm.heap.allocateObject() catch return error.OutOfMemory;
    realm.heap.setObjectPrototype(part, realm.intrinsics.object_prototype);
    try setDataProp(realm, part, "type", try makeStringValue(realm, "integer"));
    try setDataProp(realm, part, "value", formatted);
    arr.set(realm.allocator, "0", heap_mod.taggedObject(part)) catch return error.OutOfMemory;
    arr.setArrayLength(realm.allocator, 1) catch return error.OutOfMemory;
    return heap_mod.taggedObject(arr);
}

fn numberFormatResolvedOptions(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    const rec = try requireKind(realm, this_value, .number_format);
    const s = rec.number_format;
    const obj = try makeResolvedBase(realm, s.base.locale);
    try setDataProp(realm, obj, "numberingSystem", try makeStringValue(realm, if (s.base.numbering_system.len > 0) s.base.numbering_system else "latn"));
    try setDataProp(realm, obj, "style", try makeStringValue(realm, if (s.style.len > 0) s.style else "decimal"));
    if (s.currency.len > 0) try setDataProp(realm, obj, "currency", try makeStringValue(realm, s.currency));
    try setDataProp(realm, obj, "minimumIntegerDigits", makeNumberValue(1));
    try setDataProp(realm, obj, "minimumFractionDigits", makeNumberValue(0));
    try setDataProp(realm, obj, "maximumFractionDigits", makeNumberValue(3));
    try setDataProp(realm, obj, "useGrouping", try makeStringValue(realm, "auto"));
    try setDataProp(realm, obj, "notation", try makeStringValue(realm, if (s.notation.len > 0) s.notation else "standard"));
    try setDataProp(realm, obj, "signDisplay", try makeStringValue(realm, if (s.sign_display.len > 0) s.sign_display else "auto"));
    try setDataProp(realm, obj, "roundingMode", try makeStringValue(realm, "halfExpand"));
    try setDataProp(realm, obj, "roundingIncrement", makeNumberValue(1));
    try setDataProp(realm, obj, "trailingZeroDisplay", try makeStringValue(realm, "auto"));
    try setDataProp(realm, obj, "roundingType", try makeStringValue(realm, "fractionDigits"));
    return heap_mod.taggedObject(obj);
}

// ── DateTimeFormat ─────────────────────────────────────────────────────────

fn installDateTimeFormat(realm: *Realm, ns: *JSObject) !void {
    try installService(realm, ns, .{
        .name = "DateTimeFormat",
        .ctor = dateTimeFormatConstructor,
        .arity = 0,
        .to_string_tag = "Intl.DateTimeFormat",
        .methods = &.{
            // §12.3.5 — `format` is an accessor (see `makeBoundServiceFunction`).
            .{ .name = "formatToParts", .fn_ptr = dateTimeFormatFormatToParts, .params = 1 },
            .{ .name = "formatRange", .fn_ptr = dateTimeFormatFormatRange, .params = 2 },
            .{ .name = "formatRangeToParts", .fn_ptr = dateTimeFormatFormatRangeToParts, .params = 2 },
            .{ .name = "resolvedOptions", .fn_ptr = dateTimeFormatResolvedOptions, .params = 0 },
        },
        .supported_locales_of = anySupportedLocalesOf,
        .set_ctor_intrinsic = struct {
            fn f(r: *Realm, c: *JSFunction) void {
                r.intrinsics.intl_date_time_format_constructor = c;
            }
        }.f,
        .set_proto_intrinsic = struct {
            fn f(r: *Realm, p: *JSObject) void {
                r.intrinsics.intl_date_time_format_prototype = p;
            }
        }.f,
    });
    // §12.3.5 — `Intl.DateTimeFormat.prototype.format` is an accessor.
    const proto = realm.intrinsics.intl_date_time_format_prototype.?;
    try installNativeGetter(realm, proto, "format", dateTimeFormatFormatGetter);
}

fn dateTimeFormatFormatGetter(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    _ = try requireKind(realm, this_value, .date_time_format);
    return makeBoundServiceFunction(realm, this_value, dateTimeFormatFormat, "format", 1);
}

fn dateTimeFormatConstructor(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const inst = try requireNew(realm, this_value, "DateTimeFormat");
    const locales = argOr(args, 0, Value.undefined_);
    const options = argOr(args, 1, Value.undefined_);
    const opts = try getOptionsObject(realm, options);
    const resolved = try resolveServiceLocale(realm, locales, opts);

    var slots: intl.DateTimeFormatSlots = .{};
    slots.base.locale = resolved.locale;
    slots.calendar = realm.allocator.dupe(u8, "iso8601") catch return error.OutOfMemory;
    slots.numbering_system = realm.allocator.dupe(u8, "latn") catch return error.OutOfMemory;
    slots.time_zone = realm.allocator.dupe(u8, "UTC") catch return error.OutOfMemory;
    if (opts) |o| {
        const tz_v = try getPropertyChain(realm, o, "timeZone");
        if (!tz_v.isUndefined()) {
            const tz = try valueToStringSlice(realm, tz_v);
            // Structural: accept any non-empty string; store canonical-ish.
            if (tz.len == 0) return throwRangeError(realm, "invalid time zone");
            slots.time_zone = try realm.allocator.dupe(u8, tz);
        }
        const cal_v = try getPropertyChain(realm, o, "calendar");
        if (!cal_v.isUndefined()) {
            const cal = try valueToStringSlice(realm, cal_v);
            slots.calendar = try realm.allocator.dupe(u8, cal);
        }
        slots.date_style = blk: {
            const s = try getOptionString(realm, opts, "dateStyle", &.{ "full", "long", "medium", "short" }, "");
            if (s.len == 0) break :blk "";
            break :blk try realm.allocator.dupe(u8, s);
        };
        slots.time_style = blk: {
            const s = try getOptionString(realm, opts, "timeStyle", &.{ "full", "long", "medium", "short" }, "");
            if (s.len == 0) break :blk "";
            break :blk try realm.allocator.dupe(u8, s);
        };
    }

    try storeRecord(realm, inst, .{ .date_time_format = slots });
    return heap_mod.taggedObject(inst);
}

fn dateTimeFormatFormat(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = try requireKind(realm, this_value, .date_time_format);
    const v = argOr(args, 0, Value.undefined_);
    if (v.isUndefined()) {
        // Current time — structural: return ISO-like from Date.now semantics via toString fallback.
        return makeStringValue(realm, "Invalid Date"); // simplified; prefer ToString(Date)
    }
    return makeStringValue(realm, try valueToStringSlice(realm, try toNumber(realm, v)));
}

fn dateTimeFormatFormatToParts(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const formatted = try dateTimeFormatFormat(realm, this_value, args);
    const arr = allocateArray(realm) catch return error.OutOfMemory;
    const part = realm.heap.allocateObject() catch return error.OutOfMemory;
    realm.heap.setObjectPrototype(part, realm.intrinsics.object_prototype);
    try setDataProp(realm, part, "type", try makeStringValue(realm, "literal"));
    try setDataProp(realm, part, "value", formatted);
    arr.set(realm.allocator, "0", heap_mod.taggedObject(part)) catch return error.OutOfMemory;
    arr.setArrayLength(realm.allocator, 1) catch return error.OutOfMemory;
    return heap_mod.taggedObject(arr);
}

fn dateTimeFormatFormatRange(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = try requireKind(realm, this_value, .date_time_format);
    const a = try valueToStringSlice(realm, try toNumber(realm, argOr(args, 0, Value.undefined_)));
    const b = try valueToStringSlice(realm, try toNumber(realm, argOr(args, 1, Value.undefined_)));
    const joined = std.fmt.allocPrint(realm.allocator, "{s} – {s}", .{ a, b }) catch return error.OutOfMemory;
    defer realm.allocator.free(joined);
    return makeStringValue(realm, joined);
}

fn dateTimeFormatFormatRangeToParts(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const formatted = try dateTimeFormatFormatRange(realm, this_value, args);
    const arr = allocateArray(realm) catch return error.OutOfMemory;
    const part = realm.heap.allocateObject() catch return error.OutOfMemory;
    realm.heap.setObjectPrototype(part, realm.intrinsics.object_prototype);
    try setDataProp(realm, part, "type", try makeStringValue(realm, "literal"));
    try setDataProp(realm, part, "value", formatted);
    arr.set(realm.allocator, "0", heap_mod.taggedObject(part)) catch return error.OutOfMemory;
    arr.setArrayLength(realm.allocator, 1) catch return error.OutOfMemory;
    return heap_mod.taggedObject(arr);
}

fn dateTimeFormatResolvedOptions(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    const rec = try requireKind(realm, this_value, .date_time_format);
    const s = rec.date_time_format;
    const obj = try makeResolvedBase(realm, s.base.locale);
    try setDataProp(realm, obj, "calendar", try makeStringValue(realm, if (s.calendar.len > 0) s.calendar else "iso8601"));
    try setDataProp(realm, obj, "numberingSystem", try makeStringValue(realm, if (s.numbering_system.len > 0) s.numbering_system else "latn"));
    try setDataProp(realm, obj, "timeZone", try makeStringValue(realm, if (s.time_zone.len > 0) s.time_zone else "UTC"));
    return heap_mod.taggedObject(obj);
}

// ── PluralRules ────────────────────────────────────────────────────────────

fn installPluralRules(realm: *Realm, ns: *JSObject) !void {
    try installService(realm, ns, .{
        .name = "PluralRules",
        .ctor = pluralRulesConstructor,
        .arity = 0,
        .to_string_tag = "Intl.PluralRules",
        .methods = &.{
            .{ .name = "select", .fn_ptr = pluralRulesSelect, .params = 1 },
            .{ .name = "selectRange", .fn_ptr = pluralRulesSelectRange, .params = 2 },
            .{ .name = "resolvedOptions", .fn_ptr = pluralRulesResolvedOptions, .params = 0 },
        },
        .supported_locales_of = anySupportedLocalesOf,
        .set_ctor_intrinsic = struct {
            fn f(r: *Realm, c: *JSFunction) void {
                r.intrinsics.intl_plural_rules_constructor = c;
            }
        }.f,
        .set_proto_intrinsic = struct {
            fn f(r: *Realm, p: *JSObject) void {
                r.intrinsics.intl_plural_rules_prototype = p;
            }
        }.f,
    });
}

fn pluralRulesConstructor(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const inst = try requireNew(realm, this_value, "PluralRules");
    const locales = argOr(args, 0, Value.undefined_);
    const options = argOr(args, 1, Value.undefined_);
    const opts = try getOptionsObject(realm, options);
    const resolved = try resolveServiceLocale(realm, locales, opts);
    var slots: intl.PluralRulesSlots = .{};
    slots.base.locale = resolved.locale;
    slots.type_name = try getOptionStringOwned(realm, opts, "type", &.{ "cardinal", "ordinal" }, "cardinal");
    try storeRecord(realm, inst, .{ .plural_rules = slots });
    return heap_mod.taggedObject(inst);
}

/// Coerce a numeric Value (the result of ToNumber) to f64.
fn numberToF64(v: Value) f64 {
    return if (v.isInt32()) @floatFromInt(v.asInt32()) else v.asDouble();
}

/// §16.5.6 ResolvePlural — operands from FormatNumericToString, then
/// PluralRuleSelect against the locale's CLDR rules. Non-finite → "other".
/// Without CLDR data (`-Dintl=stub`) every value is "other".
fn pluralRulesSelect(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const rec = try requireKind(realm, this_value, .plural_rules);
    const num = try toNumber(realm, argOr(args, 0, Value.undefined_));
    const x = numberToF64(num);
    const s = rec.plural_rules;
    if (!std.math.isFinite(x) or !cldr.available) return makeStringValue(realm, "other");
    const ordinal = std.mem.eql(u8, s.type_name, "ordinal");
    const ops = cldr.computeOperands(x, s.minimum_fraction_digits, s.maximum_fraction_digits);
    const cat = cldr.selectPlural(s.base.locale, ordinal, ops);
    return makeStringValue(realm, cat.name());
}

/// §16.5.4 selectRange → §16.5.5 ResolvePluralRange. Undefined endpoints are a
/// TypeError; NaN endpoints a RangeError. CLDR plural-range tables aren't packed
/// yet, so we fall back to the end value's category (the CLDR root behaviour).
fn pluralRulesSelectRange(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const rec = try requireKind(realm, this_value, .plural_rules);
    const start_v = argOr(args, 0, Value.undefined_);
    const end_v = argOr(args, 1, Value.undefined_);
    if (start_v.isUndefined() or end_v.isUndefined())
        return throwTypeError(realm, "Intl.PluralRules.prototype.selectRange: start and end are required");
    const x = numberToF64(try toNumber(realm, start_v));
    const y = numberToF64(try toNumber(realm, end_v));
    if (std.math.isNan(x) or std.math.isNan(y))
        return throwRangeError(realm, "Intl.PluralRules.prototype.selectRange: start and end must be numbers");
    const s = rec.plural_rules;
    if (!cldr.available) return makeStringValue(realm, "other");
    const ordinal = std.mem.eql(u8, s.type_name, "ordinal");
    const yp = cldr.selectPlural(s.base.locale, ordinal, cldr.computeOperands(y, s.minimum_fraction_digits, s.maximum_fraction_digits));
    return makeStringValue(realm, yp.name());
}

fn pluralRulesResolvedOptions(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    const rec = try requireKind(realm, this_value, .plural_rules);
    const s = rec.plural_rules;
    const ordinal = std.mem.eql(u8, s.type_name, "ordinal");
    const obj = try makeResolvedBase(realm, s.base.locale);
    try setDataProp(realm, obj, "type", try makeStringValue(realm, if (s.type_name.len > 0) s.type_name else "cardinal"));
    try setDataProp(realm, obj, "minimumIntegerDigits", makeNumberValue(1));
    try setDataProp(realm, obj, "minimumFractionDigits", makeNumberValue(@floatFromInt(s.minimum_fraction_digits)));
    try setDataProp(realm, obj, "maximumFractionDigits", makeNumberValue(@floatFromInt(s.maximum_fraction_digits)));

    // pluralCategories: the categories the locale defines, canonical order,
    // "other" always last. From the CLDR mask (or just "other" without data).
    const mask: u8 = if (cldr.available) cldr.pluralCategoriesMask(s.base.locale, ordinal) else 0;
    const cats = allocateArray(realm) catch return error.OutOfMemory;
    var idx: u32 = 0;
    const order = [_]cldr.PluralCategory{ .zero, .one, .two, .few, .many };
    for (order) |c| {
        if (mask & (@as(u8, 1) << @as(u3, @intCast(@intFromEnum(c)))) != 0) {
            var key_buf: [12]u8 = undefined;
            const key = std.fmt.bufPrint(&key_buf, "{d}", .{idx}) catch unreachable;
            cats.set(realm.allocator, key, try makeStringValue(realm, c.name())) catch return error.OutOfMemory;
            idx += 1;
        }
    }
    {
        var key_buf: [12]u8 = undefined;
        const key = std.fmt.bufPrint(&key_buf, "{d}", .{idx}) catch unreachable;
        cats.set(realm.allocator, key, try makeStringValue(realm, "other")) catch return error.OutOfMemory;
        idx += 1;
    }
    cats.setArrayLength(realm.allocator, idx) catch return error.OutOfMemory;
    try setDataProp(realm, obj, "pluralCategories", heap_mod.taggedObject(cats));
    return heap_mod.taggedObject(obj);
}

// ── RelativeTimeFormat ─────────────────────────────────────────────────────

fn installRelativeTimeFormat(realm: *Realm, ns: *JSObject) !void {
    try installService(realm, ns, .{
        .name = "RelativeTimeFormat",
        .ctor = rtfConstructor,
        .arity = 0,
        .to_string_tag = "Intl.RelativeTimeFormat",
        .methods = &.{
            .{ .name = "format", .fn_ptr = rtfFormat, .params = 2 },
            .{ .name = "formatToParts", .fn_ptr = rtfFormatToParts, .params = 2 },
            .{ .name = "resolvedOptions", .fn_ptr = rtfResolvedOptions, .params = 0 },
        },
        .supported_locales_of = anySupportedLocalesOf,
        .set_ctor_intrinsic = struct {
            fn f(r: *Realm, c: *JSFunction) void {
                r.intrinsics.intl_relative_time_format_constructor = c;
            }
        }.f,
        .set_proto_intrinsic = struct {
            fn f(r: *Realm, p: *JSObject) void {
                r.intrinsics.intl_relative_time_format_prototype = p;
            }
        }.f,
    });
}

fn rtfConstructor(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const inst = try requireNew(realm, this_value, "RelativeTimeFormat");
    const locales = argOr(args, 0, Value.undefined_);
    const options = argOr(args, 1, Value.undefined_);
    const opts = try getOptionsObject(realm, options);
    const resolved = try resolveServiceLocale(realm, locales, opts);
    var slots: intl.RelativeTimeFormatSlots = .{};
    slots.base.locale = resolved.locale;
    slots.style = try getOptionStringOwned(realm, opts, "style", &.{ "long", "short", "narrow" }, "long");
    slots.numeric = try getOptionStringOwned(realm, opts, "numeric", &.{ "always", "auto" }, "always");
    try storeRecord(realm, inst, .{ .relative_time_format = slots });
    return heap_mod.taggedObject(inst);
}

fn rtfFormat(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = try requireKind(realm, this_value, .relative_time_format);
    const n = try valueToStringSlice(realm, try toNumber(realm, argOr(args, 0, Value.undefined_)));
    const unit = try valueToStringSlice(realm, argOr(args, 1, Value.undefined_));
    const out = std.fmt.allocPrint(realm.allocator, "{s} {s}", .{ n, unit }) catch return error.OutOfMemory;
    defer realm.allocator.free(out);
    return makeStringValue(realm, out);
}

fn rtfFormatToParts(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const formatted = try rtfFormat(realm, this_value, args);
    const arr = allocateArray(realm) catch return error.OutOfMemory;
    const part = realm.heap.allocateObject() catch return error.OutOfMemory;
    realm.heap.setObjectPrototype(part, realm.intrinsics.object_prototype);
    try setDataProp(realm, part, "type", try makeStringValue(realm, "literal"));
    try setDataProp(realm, part, "value", formatted);
    arr.set(realm.allocator, "0", heap_mod.taggedObject(part)) catch return error.OutOfMemory;
    arr.setArrayLength(realm.allocator, 1) catch return error.OutOfMemory;
    return heap_mod.taggedObject(arr);
}

fn rtfResolvedOptions(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    const rec = try requireKind(realm, this_value, .relative_time_format);
    const s = rec.relative_time_format;
    const obj = try makeResolvedBase(realm, s.base.locale);
    try setDataProp(realm, obj, "style", try makeStringValue(realm, if (s.style.len > 0) s.style else "long"));
    try setDataProp(realm, obj, "numeric", try makeStringValue(realm, if (s.numeric.len > 0) s.numeric else "always"));
    try setDataProp(realm, obj, "numberingSystem", try makeStringValue(realm, "latn"));
    return heap_mod.taggedObject(obj);
}

// ── ListFormat ─────────────────────────────────────────────────────────────

fn installListFormat(realm: *Realm, ns: *JSObject) !void {
    try installService(realm, ns, .{
        .name = "ListFormat",
        .ctor = listFormatConstructor,
        .arity = 0,
        .to_string_tag = "Intl.ListFormat",
        .methods = &.{
            .{ .name = "format", .fn_ptr = listFormatFormat, .params = 1 },
            .{ .name = "formatToParts", .fn_ptr = listFormatFormatToParts, .params = 1 },
            .{ .name = "resolvedOptions", .fn_ptr = listFormatResolvedOptions, .params = 0 },
        },
        .supported_locales_of = anySupportedLocalesOf,
        .set_ctor_intrinsic = struct {
            fn f(r: *Realm, c: *JSFunction) void {
                r.intrinsics.intl_list_format_constructor = c;
            }
        }.f,
        .set_proto_intrinsic = struct {
            fn f(r: *Realm, p: *JSObject) void {
                r.intrinsics.intl_list_format_prototype = p;
            }
        }.f,
    });
}

fn listFormatConstructor(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const inst = try requireNew(realm, this_value, "ListFormat");
    const locales = argOr(args, 0, Value.undefined_);
    const options = argOr(args, 1, Value.undefined_);
    const opts = try getOptionsObject(realm, options);
    const resolved = try resolveServiceLocale(realm, locales, opts);
    var slots: intl.ListFormatSlots = .{};
    slots.base.locale = resolved.locale;
    slots.type_name = try getOptionStringOwned(realm, opts, "type", &.{ "conjunction", "disjunction", "unit" }, "conjunction");
    slots.style = try getOptionStringOwned(realm, opts, "style", &.{ "long", "short", "narrow" }, "long");
    try storeRecord(realm, inst, .{ .list_format = slots });
    return heap_mod.taggedObject(inst);
}

fn listFormatFormat(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = try requireKind(realm, this_value, .list_format);
    const list_v = argOr(args, 0, Value.undefined_);
    // Structural: join with ", ".
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(realm.allocator);

    if (heap_mod.valueAsPlainObject(list_v)) |obj| {
        if (obj.is_array_exotic) {
            const len_v = try getPropertyChain(realm, obj, "length");
            const len_n = try toNumber(realm, len_v);
            const len_f: f64 = if (len_n.isInt32()) @floatFromInt(len_n.asInt32()) else len_n.asDouble();
            const len: usize = if (len_f > 0 and len_f < 10000) @intFromFloat(len_f) else 0;
            var i: usize = 0;
            while (i < len) : (i += 1) {
                var idx_buf: [24]u8 = undefined;
                const idx_key = std.fmt.bufPrint(&idx_buf, "{d}", .{i}) catch unreachable;
                const el = try getPropertyChain(realm, obj, idx_key);
                const s = try valueToStringSlice(realm, el);
                if (i > 0) out.appendSlice(realm.allocator, ", ") catch return error.OutOfMemory;
                out.appendSlice(realm.allocator, s) catch return error.OutOfMemory;
            }
        }
    }
    return makeStringValue(realm, out.items);
}

fn listFormatFormatToParts(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const formatted = try listFormatFormat(realm, this_value, args);
    const arr = allocateArray(realm) catch return error.OutOfMemory;
    const part = realm.heap.allocateObject() catch return error.OutOfMemory;
    realm.heap.setObjectPrototype(part, realm.intrinsics.object_prototype);
    try setDataProp(realm, part, "type", try makeStringValue(realm, "element"));
    try setDataProp(realm, part, "value", formatted);
    arr.set(realm.allocator, "0", heap_mod.taggedObject(part)) catch return error.OutOfMemory;
    arr.setArrayLength(realm.allocator, 1) catch return error.OutOfMemory;
    return heap_mod.taggedObject(arr);
}

fn listFormatResolvedOptions(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    const rec = try requireKind(realm, this_value, .list_format);
    const s = rec.list_format;
    const obj = try makeResolvedBase(realm, s.base.locale);
    try setDataProp(realm, obj, "type", try makeStringValue(realm, if (s.type_name.len > 0) s.type_name else "conjunction"));
    try setDataProp(realm, obj, "style", try makeStringValue(realm, if (s.style.len > 0) s.style else "long"));
    return heap_mod.taggedObject(obj);
}

// ── DisplayNames ───────────────────────────────────────────────────────────

fn installDisplayNames(realm: *Realm, ns: *JSObject) !void {
    try installService(realm, ns, .{
        .name = "DisplayNames",
        .ctor = displayNamesConstructor,
        .arity = 2,
        .to_string_tag = "Intl.DisplayNames",
        .methods = &.{
            .{ .name = "of", .fn_ptr = displayNamesOf, .params = 1 },
            .{ .name = "resolvedOptions", .fn_ptr = displayNamesResolvedOptions, .params = 0 },
        },
        .supported_locales_of = anySupportedLocalesOf,
        .set_ctor_intrinsic = struct {
            fn f(r: *Realm, c: *JSFunction) void {
                r.intrinsics.intl_display_names_constructor = c;
            }
        }.f,
        .set_proto_intrinsic = struct {
            fn f(r: *Realm, p: *JSObject) void {
                r.intrinsics.intl_display_names_prototype = p;
            }
        }.f,
    });
}

fn displayNamesConstructor(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const inst = try requireNew(realm, this_value, "DisplayNames");
    const locales = argOr(args, 0, Value.undefined_);
    const options = argOr(args, 1, Value.undefined_);
    if (options.isUndefined()) return throwTypeError(realm, "Intl.DisplayNames requires options with type");
    const opts = try getOptionsObject(realm, options);
    const o = opts orelse return throwTypeError(realm, "Intl.DisplayNames requires options with type");
    const type_v = try getPropertyChain(realm, o, "type");
    if (type_v.isUndefined()) return throwTypeError(realm, "Intl.DisplayNames options.type is required");
    const resolved = try resolveServiceLocale(realm, locales, opts);
    var slots: intl.DisplayNamesSlots = .{};
    slots.base.locale = resolved.locale;
    slots.type_name = try getOptionStringOwned(realm, opts, "type", &.{ "language", "region", "script", "currency", "calendar", "dateTimeField" }, "language");
    slots.style = try getOptionStringOwned(realm, opts, "style", &.{ "narrow", "short", "long" }, "long");
    slots.fallback = try getOptionStringOwned(realm, opts, "fallback", &.{ "code", "none" }, "code");
    slots.language_display = try getOptionStringOwned(realm, opts, "languageDisplay", &.{ "dialect", "standard" }, "dialect");
    try storeRecord(realm, inst, .{ .display_names = slots });
    return heap_mod.taggedObject(inst);
}

fn displayNamesOf(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const rec = try requireKind(realm, this_value, .display_names);
    const code = try valueToStringSlice(realm, argOr(args, 0, Value.undefined_));
    if (std.mem.eql(u8, rec.display_names.fallback, "none")) return Value.undefined_;
    // Structural: return the code itself.
    return makeStringValue(realm, code);
}

fn displayNamesResolvedOptions(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    const rec = try requireKind(realm, this_value, .display_names);
    const s = rec.display_names;
    const obj = try makeResolvedBase(realm, s.base.locale);
    try setDataProp(realm, obj, "style", try makeStringValue(realm, if (s.style.len > 0) s.style else "long"));
    try setDataProp(realm, obj, "type", try makeStringValue(realm, if (s.type_name.len > 0) s.type_name else "language"));
    try setDataProp(realm, obj, "fallback", try makeStringValue(realm, if (s.fallback.len > 0) s.fallback else "code"));
    try setDataProp(realm, obj, "languageDisplay", try makeStringValue(realm, if (s.language_display.len > 0) s.language_display else "dialect"));
    return heap_mod.taggedObject(obj);
}

// ── Segmenter ──────────────────────────────────────────────────────────────

fn installSegmenter(realm: *Realm, ns: *JSObject) !void {
    try installService(realm, ns, .{
        .name = "Segmenter",
        .ctor = segmenterConstructor,
        .arity = 0,
        .to_string_tag = "Intl.Segmenter",
        .methods = &.{
            .{ .name = "segment", .fn_ptr = segmenterSegment, .params = 1 },
            .{ .name = "resolvedOptions", .fn_ptr = segmenterResolvedOptions, .params = 0 },
        },
        .supported_locales_of = anySupportedLocalesOf,
        .set_ctor_intrinsic = struct {
            fn f(r: *Realm, c: *JSFunction) void {
                r.intrinsics.intl_segmenter_constructor = c;
            }
        }.f,
        .set_proto_intrinsic = struct {
            fn f(r: *Realm, p: *JSObject) void {
                r.intrinsics.intl_segmenter_prototype = p;
            }
        }.f,
    });
}

fn segmenterConstructor(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const inst = try requireNew(realm, this_value, "Segmenter");
    const locales = argOr(args, 0, Value.undefined_);
    const options = argOr(args, 1, Value.undefined_);
    const opts = try getOptionsObject(realm, options);
    const resolved = try resolveServiceLocale(realm, locales, opts);
    var slots: intl.SegmenterSlots = .{};
    slots.base.locale = resolved.locale;
    slots.granularity = try getOptionStringOwned(realm, opts, "granularity", &.{ "grapheme", "word", "sentence" }, "grapheme");
    try storeRecord(realm, inst, .{ .segmenter = slots });
    return heap_mod.taggedObject(inst);
}

fn segmenterSegment(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = try requireKind(realm, this_value, .segmenter);
    const str = try valueToStringSlice(realm, argOr(args, 0, Value.undefined_));
    // Structural: Segments object holding the source string; full
    // Segment Iterator / containing() deferred with ICU work.
    const segs = realm.heap.allocateObject() catch return error.OutOfMemory;
    realm.heap.setObjectPrototype(segs, realm.intrinsics.object_prototype);
    try installToStringTag(realm, segs, "Segments");
    segs.setWithFlags(realm.allocator, "__str", try makeStringValue(realm, str), .{
        .writable = false,
        .enumerable = false,
        .configurable = false,
    }) catch return error.OutOfMemory;
    return heap_mod.taggedObject(segs);
}

fn segmenterResolvedOptions(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    const rec = try requireKind(realm, this_value, .segmenter);
    const s = rec.segmenter;
    const obj = try makeResolvedBase(realm, s.base.locale);
    try setDataProp(realm, obj, "granularity", try makeStringValue(realm, if (s.granularity.len > 0) s.granularity else "grapheme"));
    return heap_mod.taggedObject(obj);
}

// ── DurationFormat ─────────────────────────────────────────────────────────

fn installDurationFormat(realm: *Realm, ns: *JSObject) !void {
    try installService(realm, ns, .{
        .name = "DurationFormat",
        .ctor = durationFormatConstructor,
        .arity = 0,
        .to_string_tag = "Intl.DurationFormat",
        .methods = &.{
            .{ .name = "format", .fn_ptr = durationFormatFormat, .params = 1 },
            .{ .name = "formatToParts", .fn_ptr = durationFormatFormatToParts, .params = 1 },
            .{ .name = "resolvedOptions", .fn_ptr = durationFormatResolvedOptions, .params = 0 },
        },
        .supported_locales_of = anySupportedLocalesOf,
        .set_ctor_intrinsic = struct {
            fn f(r: *Realm, c: *JSFunction) void {
                r.intrinsics.intl_duration_format_constructor = c;
            }
        }.f,
        .set_proto_intrinsic = struct {
            fn f(r: *Realm, p: *JSObject) void {
                r.intrinsics.intl_duration_format_prototype = p;
            }
        }.f,
    });
}

fn durationFormatConstructor(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const inst = try requireNew(realm, this_value, "DurationFormat");
    const locales = argOr(args, 0, Value.undefined_);
    const options = argOr(args, 1, Value.undefined_);
    const opts = try getOptionsObject(realm, options);
    const resolved = try resolveServiceLocale(realm, locales, opts);
    var slots: intl.DurationFormatSlots = .{};
    slots.base.locale = resolved.locale;
    slots.style = try getOptionStringOwned(realm, opts, "style", &.{ "long", "short", "narrow", "digital" }, "short");
    try storeRecord(realm, inst, .{ .duration_format = slots });
    return heap_mod.taggedObject(inst);
}

fn durationFormatFormat(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = try requireKind(realm, this_value, .duration_format);
    const dur = argOr(args, 0, Value.undefined_);
    if (!dur.isObject()) return throwTypeError(realm, "DurationFormat.format requires a duration-like object");
    // Structural: JSON-ish ToString of object fields if present.
    return makeStringValue(realm, try valueToStringSlice(realm, dur));
}

fn durationFormatFormatToParts(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const formatted = try durationFormatFormat(realm, this_value, args);
    const arr = allocateArray(realm) catch return error.OutOfMemory;
    const part = realm.heap.allocateObject() catch return error.OutOfMemory;
    realm.heap.setObjectPrototype(part, realm.intrinsics.object_prototype);
    try setDataProp(realm, part, "type", try makeStringValue(realm, "literal"));
    try setDataProp(realm, part, "value", formatted);
    arr.set(realm.allocator, "0", heap_mod.taggedObject(part)) catch return error.OutOfMemory;
    arr.setArrayLength(realm.allocator, 1) catch return error.OutOfMemory;
    return heap_mod.taggedObject(arr);
}

fn durationFormatResolvedOptions(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    const rec = try requireKind(realm, this_value, .duration_format);
    const s = rec.duration_format;
    const obj = try makeResolvedBase(realm, s.base.locale);
    try setDataProp(realm, obj, "style", try makeStringValue(realm, if (s.style.len > 0) s.style else "short"));
    try setDataProp(realm, obj, "numberingSystem", try makeStringValue(realm, "latn"));
    return heap_mod.taggedObject(obj);
}
