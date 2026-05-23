//! Standalone helpers extracted from `lantern.zig` — accessor
//! lookup, double formatting, array-length coercion + truncation,
//! error makers. No dispatch-loop state; each function is callable
//! from the interpreter, the JITs (when they land), or any
//! built-in.
//!
//! The originals lived intermixed with the dispatch loop; pulling
//! them here keeps `lantern.zig` focused on the loop itself.
//! Public names are re-exported from `lantern.zig` so external
//! callers (built-ins reaching for `lantern.makeTypeError`,
//! `lantern.lookupAccessor`, etc.) keep working unchanged.

const std = @import("std");

const Realm = @import("../realm.zig").Realm;
const Value = @import("../value.zig").Value;
const JSString = @import("../string.zig").JSString;
const JSObject = @import("../object.zig").JSObject;
const JSFunction = @import("../function.zig").JSFunction;
const Accessor = @import("../object.zig").Accessor;
const PropertyFlags = @import("../object.zig").PropertyFlags;
const intrinsics_mod = @import("../intrinsics.zig");
const heap_mod = @import("../heap.zig");

const RunError = @import("lantern.zig").RunError;
const arith = @import("arith.zig");

// ── Pending exception drain ─────────────────────────────────────────

pub fn consumePendingException(realm: *Realm) ?Value {
    const v = realm.pending_exception;
    realm.pending_exception = null;
    return v;
}

// ── Accessor lookup (prototype-chain walks) ─────────────────────────

/// Walk `obj` and its prototype chain looking for an accessor
/// (getter/setter) descriptor for `key`. Returns the
/// `Accessor` if found, else null. §10.1.8 / §10.1.9.
///
/// §10.1.8.1 OrdinaryGet — an own *data* property on a level
/// shadows any inherited accessor further up the chain. So at
/// each cursor, an own accessor wins, an own data short-circuits
/// to null (caller falls through to the data-lookup path), and
/// only a complete miss continues up.
pub fn lookupAccessor(obj: *JSObject, key: []const u8) ?Accessor {
    var cursor: ?*JSObject = obj;
    while (cursor) |c| : (cursor = c.prototype) {
        if (c.accessors.get(key)) |a| return a;
        if (c.hasOwn(key)) return null;
        // §10.4.5.4 Integer-Indexed Exotic Object [[GetOwnProperty]]:
        // a typed array owns every canonical numeric index in
        // [0, length) as a writable data descriptor, even though the
        // slot isn't in `properties` / `accessors`. Treat as
        // shadowing — a setter installed on the typed-array
        // prototype must NOT fire for inherited writes via
        // `Object.create(ta)[0] = v` (§10.4.5.5 IIE [[Set]] falls
        // through to OrdinarySet which sees the IIE data
        // descriptor and creates the property on the receiver).
        if (c.typed_view != null) {
            const ta_mod = @import("../builtins/typed_array.zig");
            if (ta_mod.canonicalNumericIndex(key)) |_| return null;
        }
    }
    return null;
}

/// §10.1.8.1 OrdinaryGet — locate an accessor descriptor for `key`
/// starting at `fn_obj`, walking the function's full prototype chain
/// (own → `static_parent` → `proto`). An own *data* property on the
/// receiver shadows any inherited accessor (step 1 returns that own
/// descriptor, step 2 short-circuits the parent walk), so this
/// returns `null` once we've confirmed the key is owned by the
/// receiver as plain data — the caller will then fall through to the
/// regular data-lookup path.
pub fn lookupFunctionAccessor(fn_obj: *JSFunction, key: []const u8) ?Accessor {
    if (fn_obj.accessors.get(key)) |a| return a;
    // Own data (or the dedicated `prototype` slot) shadows any
    // inherited accessor — `hasOwn` covers all three storage spots
    // (`properties`, `accessors`, the typed `prototype` field).
    if (fn_obj.hasOwn(key)) return null;
    var sp: ?*JSFunction = fn_obj.static_parent;
    while (sp) |p| : (sp = p.static_parent) {
        if (p.accessors.get(key)) |a| return a;
        if (p.hasOwn(key)) return null;
    }
    if (fn_obj.proto) |proto| {
        return lookupAccessor(proto, key);
    }
    return null;
}

// ── Double formatting + canonical numeric index ─────────────────────

/// Format an arbitrary finite double into the scratch buffer
/// without overflowing it. `{d}` on a huge magnitude (e.g.
/// 1.79e308) writes the full decimal expansion (~310 chars) and
/// blows past a 64-byte buffer. §6.1.6.1.20 NumberToString
/// switches to exponential notation past 10^21; we mirror that
/// (cheaply) by using `{e}` when the magnitude is out of the
/// safe range.
pub fn formatDoubleSafe(scratch: *[64]u8, d: f64) []const u8 {
    const a = @abs(d);
    // Threshold matches §6.1.6.1.20 step 6 (exponential when
    // `n - k <= -6` or `n > 21` on the spec's decomposition). We
    // approximate with absolute-value cutoffs that fit a 64-byte
    // buffer with `{d}` — anything outside uses `{e}` instead,
    // which is bounded.
    if (a != 0 and (a < 1e-6 or a >= 1e21)) {
        const raw = std.fmt.bufPrint(scratch, "{e}", .{d}) catch unreachable;
        // JS spec mandates `1e+22`-style sign on positive
        // exponents; Zig's `{e}` emits `1e22`. Insert the `+`
        // post-hoc using the same scratch buffer.
        const e_idx = std.mem.indexOfScalar(u8, raw, 'e') orelse return raw;
        const after = e_idx + 1;
        if (after >= raw.len) return raw;
        if (raw[after] == '+' or raw[after] == '-') return raw;
        if (raw.len + 1 > scratch.len) return raw;
        var i: usize = raw.len;
        while (i > after) : (i -= 1) scratch[i] = scratch[i - 1];
        scratch[after] = '+';
        return scratch[0 .. raw.len + 1];
    }
    return std.fmt.bufPrint(scratch, "{d}", .{d}) catch unreachable;
}

/// §7.1.21 CanonicalNumericIndexString — returns `true` when `s`
/// is "-0" or the result of `ToString(ToNumber(s))` (i.e., the
/// canonical string form of a Number). Used at TypedArray
/// `[[Set]]` to detect string keys that route to
/// IntegerIndexedElementSet (which still performs `ToNumber` on
/// the value but silently drops the store when the index is
/// invalid). Spec-faithful: matches the lexical shape of a JS
/// number literal in source form (sign + digits + optional `.`
/// + digits + optional exponent), plus the canonical sentinels
/// ("Infinity", "-Infinity", "NaN", "-0").
pub fn isCanonicalNumericIndexString(s: []const u8) bool {
    if (s.len == 0) return false;
    if (std.mem.eql(u8, s, "-0")) return true;
    if (std.mem.eql(u8, s, "NaN")) return true;
    if (std.mem.eql(u8, s, "Infinity")) return true;
    if (std.mem.eql(u8, s, "-Infinity")) return true;
    // §7.1.21 CanonicalNumericIndexString — the spec requires the
    // strict round-trip `ToString(ToNumber(S)) === S`. The test262
    // fixtures hand-pick keys that PARSE as numbers but FAIL the
    // round-trip (e.g. `"1.0"`, `"+1"`, `"1000000000000000000000"`,
    // `"0.0000001"`); those must NOT route to IntegerIndexedElementSet
    // — they're ordinary properties. `formatDoubleSafe` mirrors
    // §6.1.6.1.20 NumberToString (exponential notation past 10^21,
    // etc.), so it produces the JS canonical form for the
    // round-trip check.
    const d = std.fmt.parseFloat(f64, s) catch return false;
    if (std.math.isNan(d)) return false;
    var buf: [64]u8 = undefined;
    const printed = formatDoubleSafe(&buf, d);
    return std.mem.eql(u8, printed, s);
}

/// §7.1.19 ToPropertyKey-ish coercion for computed key access.
/// Returns a slice that borrows from `scratch` for primitives and
/// from the original `JSString.flatBytes()` for string keys. Caller
/// must not retain the slice past the next allocation that could
/// invalidate the JSString contents — at sta_computed sites we
/// re-allocate before storing.
pub fn computedKeyToString(v: Value, scratch: *[64]u8) []const u8 {
    if (v.isString()) {
        const s: *JSString = @ptrCast(@alignCast(v.asString()));
        return s.flatBytes();
    }
    if (v.isInt32()) {
        return std.fmt.bufPrint(scratch, "{d}", .{v.asInt32()}) catch unreachable;
    }
    if (v.isDouble()) {
        const d = v.asDouble();
        if (std.math.isNan(d)) return "NaN";
        if (std.math.isInf(d)) return if (d > 0) "Infinity" else "-Infinity";
        // Integer-valued doubles render without a fractional part —
        // matches §7.1.4 ToString and avoids `arr["0.0"]` mismatches.
        const safe_int_max: f64 = 9007199254740992.0;
        if (d == @trunc(d) and d >= -safe_int_max and d <= safe_int_max) {
            const i: i64 = @intFromFloat(d);
            return std.fmt.bufPrint(scratch, "{d}", .{i}) catch unreachable;
        }
        return formatDoubleSafe(scratch, d);
    }
    if (v.isBool()) return if (v.asBool()) "true" else "false";
    if (v.isNull()) return "null";
    if (v.isUndefined()) return "undefined";
    // §6.1.5.1 Well-Known Symbols + §7.1.19 ToPropertyKey for
    // user Symbols. Each Symbol carries a stable `prop_key`
    // string: the conventional `@@iterator` etc. for well-known
    // ones, a unique `<sym:N>` for user-created ones. So
    // `obj[Symbol.iterator]` and `obj["@@iterator"]` resolve to
    // the same slot (well-known), while two `Symbol("k")` calls
    // produce distinct keys (`<sym:0>` vs `<sym:1>`).
    if (heap_mod.valueAsSymbol(v)) |sym| {
        return sym.prop_key;
    }
    return "[object]";
}

// ── Array length coercion + truncation ──────────────────────────────

/// §10.4.2.4 step 3 — spec-faithful ToUint32-for-array-length.
/// Calls `ToPrimitive(value, hint=number)` *twice*, with each
/// invocation observably re-entering user `valueOf`. Returns
/// `null` when the resulting number isn't a clean uint32 index
/// (NaN, infinity, fractional, negative, or >= 2^32), in which
/// case the caller throws RangeError.
pub fn arrayLengthCoerceSpec(realm: *Realm, value: Value) @import("../function.zig").NativeError!?u32 {
    // §7.1.6 ToUint32 first ⇒ first ToNumber (step 3).
    const prim1 = try intrinsics_mod.toPrimitive(realm, value, .number);
    if (heap_mod.valueAsSymbol(prim1) != null) {
        return intrinsics_mod.throwTypeError(realm, "Cannot convert a Symbol value to a number");
    }
    const num1 = arith.toNumber(prim1);
    // §10.4.2.4 step 4 — standalone ToNumber. Observably distinct
    // from the ToUint32 call: a user's `valueOf` runs again here
    // and can mutate `arr.length` writability mid-flight.
    const prim2 = try intrinsics_mod.toPrimitive(realm, value, .number);
    if (heap_mod.valueAsSymbol(prim2) != null) {
        return intrinsics_mod.throwTypeError(realm, "Cannot convert a Symbol value to a number");
    }
    const num2 = arith.toNumber(prim2);
    if (std.math.isNan(num1) or std.math.isInf(num1)) return null;
    if (num1 < 0 or @trunc(num1) != num1 or num1 > @as(f64, @floatFromInt(std.math.maxInt(u32)))) return null;
    const new_len: u32 = @intFromFloat(num1);
    // §10.4.2.4 step 5 — SameValueZero(newLen, numberLen).
    if (@as(f64, @floatFromInt(new_len)) != num2) return null;
    return new_len;
}

/// §7.1.5 ToUint32 — coerces to u32 with the round-toward-zero,
/// modulo 2^32 semantics. For our array-length usage we need to
/// reject NaN, Infinity, fractional, and negative inputs (the
/// spec throws RangeError when ToUint32(value) !== ToNumber(value)).
/// Returns null on rejection. **Primitive-only** — does NOT call
/// user-side coercion hooks; for spec-faithful ToNumber dispatch
/// (which fires `valueOf` etc.) use `arrayLengthCoerceSpec`.
pub fn arrayLengthCoerce(v: Value) ?u32 {
    if (v.isInt32()) {
        const i = v.asInt32();
        if (i < 0) return null;
        return @intCast(i);
    }
    if (v.isDouble()) {
        const d = v.asDouble();
        if (std.math.isNan(d) or std.math.isInf(d)) return null;
        if (d < 0) return null;
        if (d > @as(f64, @floatFromInt(std.math.maxInt(u32)))) return null;
        if (@trunc(d) != d) return null;
        return @intFromFloat(d);
    }
    if (v.isBool()) return if (v.asBool()) 1 else 0;
    if (v.isString()) {
        const s: *JSString = @ptrCast(@alignCast(v.asString()));
        const n = std.fmt.parseFloat(f64, s.flatBytes()) catch return null;
        if (std.math.isNan(n) or std.math.isInf(n) or n < 0 or @trunc(n) != n) return null;
        if (n > @as(f64, @floatFromInt(std.math.maxInt(u32)))) return null;
        return @intFromFloat(n);
    }
    return null;
}

/// Result of an §10.4.2.4 ArraySetLength truncate.
/// `final_length` is the new `length` value the caller must
/// store: equals `target_len` on full success, or `blocker_idx + 1`
/// on a stuck non-configurable element. `blocked` tells the
/// strict-mode setter to throw TypeError.
pub const TruncateResult = struct {
    final_length: u32,
    blocked: bool,
};

/// §10.4.2.4 step 16-17 — walk own integer-indexed properties in
/// descending order, deleting each whose index is `>= target_len`.
/// On a non-configurable element, stop and return its index + 1
/// as the floor.
pub fn truncateArrayAtLength(allocator: std.mem.Allocator, obj: *JSObject, target_len: u32) TruncateResult {
    // §10.4.2.4 — Array exotic: walk the packed `elements`
    // vector AND any promoted-into-`properties` indexed keys
    // (slots that became non-default via
    // `Object.defineProperty(arr, "<idx>", {configurable:false, …})`
    // get demoted to the named-property bag — see
    // `JSObject.setWithFlags`). The spec descends from the
    // highest index ≥ target_len; the first non-configurable
    // stops the walk and sets length to that index + 1.
    if (obj.is_array_exotic) {
        // Collect promoted integer-indexed keys ≥ target_len so
        // we can fold them into the descending walk. Without
        // this, a non-configurable promoted index (e.g. via
        // `Object.defineProperty(arr, "1", {configurable:false})`)
        // would be silently bypassed and the truncate would
        // succeed instead of throwing. Accessor descriptors live
        // in a separate map (`accessors`), so walk that too —
        // a non-configurable accessor at index N still blocks
        // truncation per §10.4.2.4 step 17.b.ii.
        var promoted: std.ArrayListUnmanaged(u32) = .empty;
        defer promoted.deinit(allocator);
        {
            var it = obj.properties.iterator();
            while (it.next()) |entry| {
                const k = entry.key_ptr.*;
                if (canonicalIntegerIndexInterp(k)) |idx| {
                    if (idx >= target_len) {
                        promoted.append(allocator, idx) catch return .{ .final_length = target_len, .blocked = false };
                    }
                }
            }
        }
        {
            var it = obj.accessors.iterator();
            while (it.next()) |entry| {
                const k = entry.key_ptr.*;
                if (canonicalIntegerIndexInterp(k)) |idx| {
                    if (idx >= target_len) {
                        promoted.append(allocator, idx) catch return .{ .final_length = target_len, .blocked = false };
                    }
                }
            }
        }
        std.mem.sort(u32, promoted.items, {}, std.sort.desc(u32));

        // Find the highest non-configurable promoted index ≥
        // target_len. Everything strictly above it can be
        // deleted (promoted slots are explicitly configurable
        // when their flags say so; packed `elements` slots are
        // always configurable today). That gives us the floor.
        var floor: ?u32 = null;
        var buf: [16]u8 = undefined;
        for (promoted.items) |idx| {
            const key = std.fmt.bufPrint(&buf, "{d}", .{idx}) catch continue;
            const flags = obj.property_flags.get(key) orelse PropertyFlags.default;
            if (!flags.configurable) {
                floor = idx + 1;
                break;
            }
            // Configurable promoted index above any non-conf
            // floor — delete it from the bag. The packed
            // `elements` slot at this index is already a hole
            // (`setWithFlags` calls `holeIndexed` when demoting).
            _ = obj.properties.swapRemove(key);
            _ = obj.accessors.swapRemove(key);
            _ = obj.property_flags.swapRemove(key);
        }
        const final_len = floor orelse target_len;
        _ = obj.truncateIndexed(allocator, final_len) catch return .{ .final_length = final_len, .blocked = floor != null };
        return .{ .final_length = final_len, .blocked = floor != null };
    }
    // Pre-array-exotic fallback for any object (e.g. an array-
    // like with stringified-index own properties) that ended up
    // routed through ArraySetLength via prototype chaining.
    var indices: std.ArrayListUnmanaged(u32) = .empty;
    defer indices.deinit(allocator);
    var it = obj.properties.iterator();
    while (it.next()) |entry| {
        const k = entry.key_ptr.*;
        if (canonicalIntegerIndexInterp(k)) |idx| {
            if (idx >= target_len) {
                indices.append(allocator, idx) catch return .{ .final_length = target_len, .blocked = false };
            }
        }
    }
    std.mem.sort(u32, indices.items, {}, std.sort.desc(u32));

    var buf: [16]u8 = undefined;
    for (indices.items) |idx| {
        const key = std.fmt.bufPrint(&buf, "{d}", .{idx}) catch continue;
        if (obj.property_flags.get(key)) |flags| {
            if (!flags.configurable) {
                return .{ .final_length = idx + 1, .blocked = true };
            }
        }
        _ = obj.properties.swapRemove(key);
        _ = obj.property_flags.swapRemove(key);
    }
    return .{ .final_length = target_len, .blocked = false };
}

/// §7.1.21 CanonicalNumericIndexString. Local copy for the
/// interpreter's for-in walker (the equivalent in
/// `intrinsics.zig` is module-private). Returns the u32 value
/// when `s` is a canonical integer-index string, else null.
pub fn canonicalIntegerIndexInterp(s: []const u8) ?u32 {
    // §6.1.7 — an "array index" is a string whose canonical
    // numeric value is in the inclusive range [+0, 2^32-2]. The
    // value 2^32-1 is reserved as the maximum array length and
    // is NOT an array index; "4294967295" must round-trip as a
    // named property, not a slot in the indexed backing.
    if (s.len == 0) return null;
    if (s.len > 10) return null;
    if (s[0] == '0' and s.len > 1) return null;
    var n: u64 = 0;
    for (s) |c| {
        if (c < '0' or c > '9') return null;
        n = n * 10 + (c - '0');
        if (n > 0xFFFFFFFE) return null;
    }
    return @intCast(n);
}

// ── Error makers — wrappers that map intrinsics's wider error set
// ── to the interpreter's `RunError`. Heavily used by the dispatch
// ── loop where the surrounding error union is `RunError!Value`.

pub fn makeTypeError(realm: *Realm, msg: []const u8) RunError!Value {
    return intrinsics_mod.newTypeError(realm, msg) catch return error.OutOfMemory;
}

pub fn makeRangeError(realm: *Realm, msg: []const u8) RunError!Value {
    return intrinsics_mod.newRangeError(realm, msg) catch return error.OutOfMemory;
}

pub fn makeSyntaxError(realm: *Realm, msg: []const u8) RunError!Value {
    return intrinsics_mod.newSyntaxError(realm, msg) catch return error.OutOfMemory;
}
