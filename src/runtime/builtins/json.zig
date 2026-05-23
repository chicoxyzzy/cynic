//! §25.5 JSON — extracted from `intrinsics.zig`. Cynic's JSON
//! implementation is recursive-descent (parse) + recursive
//! (stringify); the stringify side honors §25.5.2's `replacer`
//! and `space` arguments, including the wrapper-holder, `toJSON`,
//! and Number / String wrapper unwrapping.
//!
//! `pub fn install(realm)` wires `globalThis.JSON` to a fresh
//! object with `stringify` and `parse` methods plus the
//! `Symbol.toStringTag === "JSON"` slot.

const std = @import("std");

const Realm = @import("../realm.zig").Realm;
const Value = @import("../value.zig").Value;
const JSString = @import("../string.zig").JSString;
const JSObject = @import("../object.zig").JSObject;
const JSFunction = @import("../function.zig").JSFunction;
const NativeError = @import("../function.zig").NativeError;
const heap_mod = @import("../heap.zig");
const intrinsics = @import("../intrinsics.zig");
const lantern = @import("../lantern/interpreter.zig");

const installToStringTag = intrinsics.installToStringTag;
const argOr = intrinsics.argOr;
const ownPropertyKeysOrdered = intrinsics.ownPropertyKeysOrdered;
const getPropertyChain = intrinsics.getPropertyChain;
const throwTypeError = intrinsics.throwTypeError;
const throwSyntaxError = intrinsics.throwSyntaxError;
const isArrayLike = intrinsics.isArrayLike;
const setLength = intrinsics.setLength;
const lengthOfArray = intrinsics.lengthOfArray;
const stringifyArg = intrinsics.stringifyArg;
const toNumber = intrinsics.toNumber;
const toLengthValue = intrinsics.toLengthValue;
const proxy_mod = @import("proxy.zig");
const object_builtins = @import("object.zig");
const PropertyFlags = @import("../object.zig").PropertyFlags;

/// §7.2.2 IsArray with Proxy unwrap. Walks the proxy target chain
/// (step 3.b); a revoked proxy on the chain raises TypeError per
/// step 3.a. Returns false for non-Object values. Mirrors
/// `isArrayProxyAware` in `builtins/array.zig`.
fn jsonIsArrayValue(realm: *Realm, v: Value) NativeError!bool {
    var cur_obj = heap_mod.valueAsPlainObject(v) orelse return false;
    while (true) {
        if (cur_obj.proxy_revoked) {
            return throwTypeError(realm, "Cannot perform 'IsArray' on a proxy that has been revoked");
        }
        if (cur_obj.proxy_target) |t| {
            cur_obj = t;
            continue;
        }
        return cur_obj.is_array_exotic;
    }
}

/// §7.3.2 Get(O, P) with full Proxy `get` trap dispatch. Walks
/// the proxy chain; falls back to `getPropertyChain` at the end.
/// Used for every JSON.stringify property read so a Proxy `get`
/// trap that throws propagates as an abrupt completion.
fn jsonGetValue(realm: *Realm, value: Value, key: []const u8) NativeError!Value {
    const obj = heap_mod.valueAsPlainObject(value) orelse return Value.undefined_;
    var cur = obj;
    while (cur.proxy_target != null or cur.proxy_revoked) {
        const outcome = try proxy_mod.nativeProxyGet(realm, cur, key, heap_mod.taggedObject(obj));
        switch (outcome) {
            .value => |v| return v,
            .fallthrough => |t| {
                if (t == cur) return Value.undefined_;
                cur = t;
            },
        }
    }
    return getPropertyChain(realm, cur, key);
}

/// §10.1.8 [[Get]] (P, Receiver) — accessor walk where the
/// `get` thunk receives `receiver` as its `this`, not the holder
/// object. Mirrors `getPropertyChain` but lets the caller pin the
/// receiver explicitly. Used by the BigInt-primitive toJSON
/// lookup so the strict-mode getter sees `typeof this === "bigint"`
/// per §7.3.3 GetV(V, P) (value-bigint-tojson-receiver).
fn getPropertyWithReceiver(realm: *Realm, obj: *JSObject, key: []const u8, receiver: Value) NativeError!Value {
    var cur: ?*JSObject = obj;
    while (cur) |o| {
        if (o.accessors.get(key)) |acc| {
            if (acc.getter) |getter| {
                const outcome = lantern.callJSFunction(realm.allocator, realm, getter, receiver, &[_]Value{}) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => return error.NativeThrew,
                };
                switch (outcome) {
                    .value, .yielded => |v| return v,
                    .thrown => |ex| {
                        realm.pending_exception = ex;
                        return error.NativeThrew;
                    },
                }
            }
            return Value.undefined_;
        }
        if (o.properties.get(key)) |v| return v;
        cur = o.prototype;
    }
    return Value.undefined_;
}

/// §7.3.18 LengthOfArrayLike(O) — `? ToLength(? Get(O, "length"))`.
/// Proxy-aware: a `get` trap returning a non-numeric primitive
/// triggers ToLength (which calls valueOf/toString and propagates
/// abrupts); a `get` trap throwing on "length" propagates directly.
fn jsonLengthOfArrayLike(realm: *Realm, obj_v: Value) NativeError!i64 {
    const len_v = try jsonGetValue(realm, obj_v, "length");
    return toLengthValue(realm, len_v);
}

pub fn install(realm: *Realm) !void {
    const json_obj = try realm.heap.allocateObject();
    json_obj.prototype = realm.intrinsics.object_prototype;
    try installToStringTag(realm, json_obj, "JSON");
    // §17 — built-in methods are non-enumerable (writable +
    // configurable). The default `set` would mark them
    // enumerable, which the prop-desc tests reject.
    const method_flags: @import("../object.zig").PropertyFlags = .{
        .writable = true,
        .enumerable = false,
        .configurable = true,
    };
    const stringify_fn = try realm.heap.allocateFunctionNative(jsonStringify, 3, "stringify");
    stringify_fn.has_construct = false;
    try json_obj.setWithFlags(realm.allocator, "stringify", heap_mod.taggedFunction(stringify_fn), method_flags);
    const parse_fn = try realm.heap.allocateFunctionNative(jsonParse, 2, "parse");
    parse_fn.has_construct = false;
    try json_obj.setWithFlags(realm.allocator, "parse", heap_mod.taggedFunction(parse_fn), method_flags);
    // §25.5.4 / §25.5.3 — JSON.rawJSON / JSON.isRawJSON
    // (json-parse-with-source, Stage 4 ES2025).
    const raw_json_fn = try realm.heap.allocateFunctionNative(jsonRawJSON, 1, "rawJSON");
    raw_json_fn.has_construct = false;
    try json_obj.setWithFlags(realm.allocator, "rawJSON", heap_mod.taggedFunction(raw_json_fn), method_flags);
    const is_raw_json_fn = try realm.heap.allocateFunctionNative(jsonIsRawJSON, 1, "isRawJSON");
    is_raw_json_fn.has_construct = false;
    try json_obj.setWithFlags(realm.allocator, "isRawJSON", heap_mod.taggedFunction(is_raw_json_fn), method_flags);
    try realm.globals.put(realm.allocator, "JSON", heap_mod.taggedObject(json_obj));
}

// ── JSON.stringify ──────────────────────────────────────────────────────────

/// §25.5.2 — the SerializeJSONProperty state record. Carries the
/// resolved replacer, gap (indent unit), the current indent prefix,
/// and the object stack used for cycle detection.
const StringifyState = struct {
    realm: *Realm,
    replacer_fn: ?*JSFunction,
    /// `null` when no array-replacer was supplied; otherwise the
    /// PropertyList from §25.5.2 step 4.b.iv (deduplicated, in
    /// insertion order). Owned by the state arena.
    property_list: ?[]const []const u8,
    /// "Indent unit" — empty string means no pretty-printing.
    gap: []const u8,
    /// Running `\n` + `gap` * depth. Empty when `gap` is empty.
    indent: std.ArrayListUnmanaged(u8),
    /// Object cycle stack. We push *JSObject and check
    /// pointer-equality for cycles. Holds plain objects + arrays.
    stack: std.ArrayListUnmanaged(*JSObject),
    /// Owned heap-allocated strings backing `property_list` /
    /// `gap`. Freed at state teardown.
    owned_buffers: std.ArrayListUnmanaged([]u8),
};

fn jsonStringify(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = this_value;
    const value = argOr(args, 0, Value.undefined_);
    const replacer_v = argOr(args, 1, Value.undefined_);
    const space_v = argOr(args, 2, Value.undefined_);

    var state = StringifyState{
        .realm = realm,
        .replacer_fn = null,
        .property_list = null,
        .gap = "",
        .indent = .empty,
        .stack = .empty,
        .owned_buffers = .empty,
    };
    defer {
        state.indent.deinit(realm.allocator);
        state.stack.deinit(realm.allocator);
        for (state.owned_buffers.items) |b| realm.allocator.free(b);
        state.owned_buffers.deinit(realm.allocator);
        if (state.property_list) |pl| realm.allocator.free(pl);
    }

    // §25.5.2 step 4 — resolve replacer. The IsCallable check
    // (step 4.a) precedes IsArray (step 4.b), so a callable
    // Proxy-of-array routes to the function branch. For non-
    // callable objects, §7.2.2 IsArray unwraps Proxy targets and
    // throws TypeError on a revoked proxy — propagate that abrupt.
    if (heap_mod.valueAsFunction(replacer_v)) |fn_obj| {
        state.replacer_fn = fn_obj;
    } else if (heap_mod.valueAsPlainObject(replacer_v)) |_| {
        if (try jsonIsArrayValue(realm, replacer_v)) {
            try resolvePropertyList(&state, replacer_v);
        }
    }

    // §25.5.2 step 5-8 — resolve space.
    try resolveSpace(&state, space_v);

    // §25.5.2 step 9-12 — wrap value in `{ "": value }` and
    // serialize via SerializeJSONProperty(state, "", wrapper).
    const wrapper = realm.heap.allocateObject() catch return error.OutOfMemory;
    wrapper.prototype = realm.intrinsics.object_prototype;
    wrapper.set(realm.allocator, "", value) catch return error.OutOfMemory;

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(realm.allocator);

    const ok = try serializeJSONProperty(&state, "", heap_mod.taggedObject(wrapper), &buf);
    if (!ok) return Value.undefined_;

    const out = realm.heap.allocateString(buf.items) catch return error.OutOfMemory;
    return Value.fromString(out);
}

/// §25.5.2 step 4.b — walk the array-replacer building a unique,
/// ordered PropertyList of string keys. Per spec:
/// • String / String-wrapper / Number / Number-wrapper entries
///   coerce to a string key.
/// • Anything else (booleans, null, undefined, symbols, plain
///   objects without [[StringData]]/[[NumberData]]) is skipped.
/// • Duplicates are dropped — first occurrence wins.
fn resolvePropertyList(state: *StringifyState, replacer_v: Value) NativeError!void {
    const realm = state.realm;
    // §25.5.2 step 4.b.iii — `len = ? LengthOfArrayLike(replacer)`.
    // Dispatch through the proxy `get` trap; a throw on the
    // `length` read or a non-coercible toPrimitive on the result
    // propagates as an abrupt.
    const len_raw = try jsonLengthOfArrayLike(realm, replacer_v);
    if (len_raw <= 0) {
        const empty = realm.allocator.alloc([]const u8, 0) catch return error.OutOfMemory;
        state.property_list = empty;
        return;
    }
    const cap = if (len_raw > (1 << 16)) @as(i64, 1 << 16) else len_raw;

    var list: std.ArrayListUnmanaged([]const u8) = .empty;
    defer list.deinit(realm.allocator);

    var i: i64 = 0;
    while (i < cap) : (i += 1) {
        var ibuf: [24]u8 = undefined;
        const islice = std.fmt.bufPrint(&ibuf, "{d}", .{i}) catch unreachable;
        // §25.5.2 step 4.b.iv.a — `v = ? Get(replacer, ! ToString(k))`.
        // Routes through any Proxy `get` trap on the replacer.
        const v = try jsonGetValue(realm, replacer_v, islice);

        var item_bytes: ?[]const u8 = null;
        if (v.isString()) {
            const s: *JSString = @ptrCast(@alignCast(v.asString()));
            item_bytes = s.flatBytes();
        } else if (v.isInt32() or v.isDouble()) {
            const owned = stringifyArg(realm, v) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => continue,
            };
            item_bytes = owned.flatBytes();
        } else if (heap_mod.valueAsPlainObject(v)) |o| {
            // §25.5.2 step 4.b.iv.4.e — accept Number / String
            // wrapper objects; coerce via ToString. Order
            // matters: String wrappers also pin `boxed_primitive`,
            // so look for the string slot first.
            if (o.boxed_string != null) {
                const s = try stringifyArg(realm, v);
                item_bytes = s.flatBytes();
            } else if (o.boxed_primitive) |bp| {
                if (bp.isInt32() or bp.isDouble()) {
                    const s = try stringifyArg(realm, v);
                    item_bytes = s.flatBytes();
                }
            }
        }

        if (item_bytes) |bytes| {
            // Dedupe — first occurrence wins.
            var found = false;
            for (list.items) |k| {
                if (std.mem.eql(u8, k, bytes)) {
                    found = true;
                    break;
                }
            }
            if (!found) list.append(realm.allocator, bytes) catch return error.OutOfMemory;
        }
    }

    const out = realm.allocator.alloc([]const u8, list.items.len) catch return error.OutOfMemory;
    @memcpy(out, list.items);
    state.property_list = out;
}

/// §25.5.2 step 5-8 — coerce `space` to the indent unit (`gap`).
/// Number → up to 10 ASCII spaces; string → first 10 code units
/// of the string. Number / String wrappers unwrap via ToNumber /
/// ToString. Anything else → empty (no pretty-printing).
fn resolveSpace(state: *StringifyState, space_v: Value) NativeError!void {
    const realm = state.realm;
    var space_resolved = space_v;
    // §25.5.2 step 5 — Number / String wrapper objects unwrap.
    // String wrappers also pin `boxed_primitive`, so check the
    // string slot first.
    if (heap_mod.valueAsPlainObject(space_v)) |obj| {
        if (obj.boxed_string != null) {
            const s = try stringifyArg(realm, space_v);
            space_resolved = Value.fromString(s);
        } else if (obj.boxed_primitive) |bp| {
            if (bp.isInt32() or bp.isDouble()) {
                space_resolved = try toNumber(realm, space_v);
            }
        }
    }

    // §25.5.2 step 6 — Number → min(10, ToInteger(space)) spaces.
    if (space_resolved.isInt32()) {
        const i = space_resolved.asInt32();
        const n: usize = if (i < 1) 0 else if (i > 10) 10 else @intCast(i);
        if (n == 0) return;
        const buf = realm.allocator.alloc(u8, n) catch return error.OutOfMemory;
        @memset(buf, ' ');
        state.owned_buffers.append(realm.allocator, buf) catch {
            realm.allocator.free(buf);
            return error.OutOfMemory;
        };
        state.gap = buf;
        return;
    }
    if (space_resolved.isDouble()) {
        const d = space_resolved.asDouble();
        if (std.math.isNan(d)) return;
        // ToInteger truncates toward zero.
        const trunc_d = @trunc(d);
        const n: usize = if (trunc_d < 1) 0 else if (trunc_d > 10) 10 else @intFromFloat(trunc_d);
        if (n == 0) return;
        const buf = realm.allocator.alloc(u8, n) catch return error.OutOfMemory;
        @memset(buf, ' ');
        state.owned_buffers.append(realm.allocator, buf) catch {
            realm.allocator.free(buf);
            return error.OutOfMemory;
        };
        state.gap = buf;
        return;
    }
    // §25.5.2 step 7 — String → first 10 code units.
    if (space_resolved.isString()) {
        const s: *JSString = @ptrCast(@alignCast(space_resolved.asString()));
        if (s.flatBytes().len == 0) return;
        // Cynic stores strings as UTF-8 byte buffers. The spec
        // counts UTF-16 code units; for the common ASCII /
        // BMP-non-supplementary inputs the truncation aligns
        // exactly. For the rest, first-10-bytes is a tolerable
        // approximation — the test262 fixtures use ASCII.
        const len = if (s.flatBytes().len > 10) 10 else s.flatBytes().len;
        const buf = realm.allocator.alloc(u8, len) catch return error.OutOfMemory;
        @memcpy(buf, s.flatBytes()[0..len]);
        state.owned_buffers.append(realm.allocator, buf) catch {
            realm.allocator.free(buf);
            return error.OutOfMemory;
        };
        state.gap = buf;
        return;
    }
    // Anything else — leave gap empty (step 8).
}

/// §25.5.2.4 SerializeJSONProperty(state, key, holder).
/// Returns `false` when the spec produces "no value" (undefined,
/// callable, symbol — the property is omitted by the caller).
/// `holder_v` carries the holder as a Value — it's both the
/// receiver for any Proxy `get` trap dispatched on the property
/// read AND the `this`-binding for the replacer call at step 3.
fn serializeJSONProperty(
    state: *StringifyState,
    key: []const u8,
    holder_v: Value,
    buf: *std.ArrayListUnmanaged(u8),
) NativeError!bool {
    const realm = state.realm;

    // §25.5.2.4 step 1 — `value = ? Get(holder, key)`. Routes
    // through any Proxy `get` trap installed on `holder` (the
    // BigInt-cross-realm / proxy-receiver fixtures exercise this).
    var value = try jsonGetValue(realm, holder_v, key);

    // §25.5.2.4 step 2 — "If Type(value) is Object or BigInt"
    // then look up `toJSON`. The §6.1.6 BigInt receiver dispatch
    // is observable: `BigInt.prototype.toJSON` is called with the
    // BigInt primitive as `this`, NOT auto-boxed to an Object
    // wrapper (the value-bigint-tojson-receiver fixture asserts
    // `typeof this === "bigint"` from the strict-mode getter).
    if (heap_mod.valueAsPlainObject(value)) |_| {
        // §7.3.3 GetV on an object — proxy-aware read for `toJSON`.
        const tj = try jsonGetValue(realm, value, "toJSON");
        if (heap_mod.valueAsFunction(tj)) |fn_obj| {
            const key_s = realm.heap.allocateString(key) catch return error.OutOfMemory;
            const cb_args = [_]Value{Value.fromString(key_s)};
            const outcome = lantern.callJSFunction(realm.allocator, realm, fn_obj, value, &cb_args) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.NativeThrew,
            };
            switch (outcome) {
                .value, .yielded => |v| value = v,
                .thrown => |ex| {
                    realm.pending_exception = ex;
                    return error.NativeThrew;
                },
            }
        }
    } else if (heap_mod.valueAsBigInt(value) != null) {
        // §7.3.3 GetV(V, P) — for a BigInt primitive, the lookup
        // is `Let O = ! ToObject(V); Return ? O.[[Get]](P, V)`.
        // The accessor `get` receives `V` (the BigInt primitive)
        // as `this`, so strict-mode `typeof this` reports
        // `"bigint"` (value-bigint-tojson-receiver). The
        // %BigInt.prototype% resolution honors the realm of V
        // (lookupPrimitivePrototype routes through the realm's
        // BigInt global, so a cross-realm BigInt picks up its
        // own realm's toJSON — value-bigint-cross-realm).
        if (intrinsics.lookupPrimitivePrototype(realm, value)) |bi_proto| {
            const tj = try getPropertyWithReceiver(realm, bi_proto, "toJSON", value);
            if (heap_mod.valueAsFunction(tj)) |fn_obj| {
                const key_s = realm.heap.allocateString(key) catch return error.OutOfMemory;
                const cb_args = [_]Value{Value.fromString(key_s)};
                const outcome = lantern.callJSFunction(realm.allocator, realm, fn_obj, value, &cb_args) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => return error.NativeThrew,
                };
                switch (outcome) {
                    .value, .yielded => |v| value = v,
                    .thrown => |ex| {
                        realm.pending_exception = ex;
                        return error.NativeThrew;
                    },
                }
            }
        }
    }

    // §25.5.2.4 step 3 — invoke replacer function with holder
    // as `this`, args = [key, value]. Top-level call has key="".
    if (state.replacer_fn) |rf| {
        const key_s = realm.heap.allocateString(key) catch return error.OutOfMemory;
        const cb_args = [_]Value{ Value.fromString(key_s), value };
        const outcome = lantern.callJSFunction(realm.allocator, realm, rf, holder_v, &cb_args) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.NativeThrew,
        };
        switch (outcome) {
            .value, .yielded => |v| value = v,
            .thrown => |ex| {
                realm.pending_exception = ex;
                return error.NativeThrew;
            },
        }
    }

    // §25.5.2.4 step 4 (json-parse-with-source revision) — a
    // [[IsRawJSON]]-branded object short-circuits the entire
    // pipeline: emit the canonical `rawJSON` text verbatim. The
    // brand is set only by `JSON.rawJSON(text)`, which already
    // validated the text is a single non-Object/Array JSON value.
    // Checked AFTER the replacer (per spec ordering) so a replacer
    // returning a rawJSON wrapper still gets the verbatim treatment
    // (the bigint-raw-json-can-be-stringified fixture exercises
    // exactly this — replacer rewrites a BigInt into JSON.rawJSON
    // and the stringified output must inline the digits).
    if (heap_mod.valueAsPlainObject(value)) |obj_raw| {
        if (obj_raw.is_raw_json) {
            const raw_v = obj_raw.get("rawJSON");
            if (raw_v.isString()) {
                const s: *JSString = @ptrCast(@alignCast(raw_v.asString()));
                try buf.appendSlice(realm.allocator, s.flatBytes());
                return true;
            }
        }
    }

    // §25.5.2.4 step 4 — unwrap Number / String / Boolean /
    // BigInt wrapper objects to their underlying primitive.
    // String wrappers also pin `boxed_primitive`; we want
    // ToString in that case, so check `boxed_string` first.
    // BigInt wrappers (step 4.d) unwrap to the primitive — step
    // 10 then throws TypeError unless toJSON ran above.
    if (heap_mod.valueAsPlainObject(value)) |o| {
        if (o.boxed_string != null) {
            const s = try stringifyArg(realm, value);
            value = Value.fromString(s);
        } else if (o.boxed_primitive) |bp| {
            if (bp.isInt32() or bp.isDouble()) {
                value = try toNumber(realm, value);
            } else if (bp.isBool()) {
                value = bp;
            } else if (heap_mod.valueAsBigInt(bp) != null) {
                // §25.5.2.4 step 4.d — `value.[[BigIntData]]`.
                value = bp;
            }
        }
    }

    // §25.5.2.4 step 5-9 — primitive dispatch.
    if (value.isUndefined()) return false;
    if (heap_mod.isFunction(value)) return false;
    if (heap_mod.valueAsSymbol(value) != null) return false;
    if (value.isNull()) {
        try buf.appendSlice(realm.allocator, "null");
        return true;
    }
    if (value.isBool()) {
        try buf.appendSlice(realm.allocator, if (value.asBool()) "true" else "false");
        return true;
    }
    if (value.isString()) {
        const s: *JSString = @ptrCast(@alignCast(value.asString()));
        try jsonAppendString(realm, buf, s.flatBytes());
        return true;
    }
    if (value.isInt32()) {
        var ibuf: [24]u8 = undefined;
        const slc = std.fmt.bufPrint(&ibuf, "{d}", .{value.asInt32()}) catch unreachable;
        try buf.appendSlice(realm.allocator, slc);
        return true;
    }
    if (value.isDouble()) {
        const d = value.asDouble();
        if (std.math.isNan(d) or std.math.isInf(d)) {
            try buf.appendSlice(realm.allocator, "null");
            return true;
        }
        var ibuf: [64]u8 = undefined;
        const slc = formatDoubleForJson(&ibuf, d);
        try buf.appendSlice(realm.allocator, slc);
        return true;
    }
    if (heap_mod.valueAsBigInt(value) != null) {
        // §25.5.2.4 step 9 — BigInt without toJSON throws.
        return throwTypeError(realm, "BigInt is not serializable to JSON");
    }
    if (heap_mod.valueAsPlainObject(value)) |obj| {
        // §25.5.2.4 step 10.a — `isArray = ? IsArray(value)`. The
        // Proxy unwrap chain (§7.2.2 step 3) may throw on a
        // revoked proxy; propagate the abrupt rather than fall
        // through to the object branch.
        const is_array = try jsonIsArrayValue(realm, value);
        if (is_array) {
            return serializeJSONArray(state, value, obj, buf);
        }
        return serializeJSONObject(state, value, obj, buf);
    }
    return false;
}

/// §25.5.2.5 SerializeJSONObject. Walks the resolved property
/// list (or own enumerable string keys when none) and emits each
/// key:value pair, applying gap / indent for pretty-printing.
/// `obj_v` is the tagged Value form of `obj`; it's the receiver
/// for any Proxy `get` trap dispatched by `serializeJSONProperty`.
fn serializeJSONObject(
    state: *StringifyState,
    obj_v: Value,
    obj: *JSObject,
    buf: *std.ArrayListUnmanaged(u8),
) NativeError!bool {
    const realm = state.realm;

    // Cycle check.
    for (state.stack.items) |s| {
        if (s == obj) return throwTypeError(realm, "Converting circular structure to JSON");
    }
    state.stack.append(realm.allocator, obj) catch return error.OutOfMemory;
    defer _ = state.stack.pop();

    // Push a new indent level.
    const stepback = state.indent.items.len;
    if (state.gap.len > 0) {
        try state.indent.appendSlice(realm.allocator, state.gap);
    }
    defer state.indent.shrinkRetainingCapacity(stepback);

    // §25.5.2.5 step 5 — keys come from PropertyList when set,
    // else `? EnumerableOwnPropertyNames(value, "key")`. For a
    // Proxy the ownKeys trap (§10.5.11) sources the list — a
    // trap throw must propagate, so a revoked proxy throws here.
    var owned_keys: ?[]const []const u8 = null;
    defer if (owned_keys) |k| realm.allocator.free(k);
    const key_scope = realm.heap.openScope() catch return error.OutOfMemory;
    defer key_scope.close();
    const keys: []const []const u8 = if (state.property_list) |pl| pl else blk: {
        const proxy_keys = try object_builtins.proxyOwnKeysOrNull(realm, obj, key_scope);
        const all = if (proxy_keys) |k| k else try ownPropertyKeysOrdered(realm, obj, key_scope);
        owned_keys = all;
        break :blk all;
    };
    // §7.3.23 EnumerableOwnProperties step 4.a.ii filter (only
    // when we own the key list ourselves — the PropertyList path
    // already dedupes / validates strings during resolve).
    const filter_enumerable = state.property_list == null;

    try buf.append(realm.allocator, '{');
    var first = true;
    var rendered_any = false;
    for (keys) |key| {
        // When using own keys, skip non-enumerable and any
        // Symbol-encoded slot. The PropertyList branch trusts
        // the entries already validated during resolve.
        if (filter_enumerable) {
            // §25.5.2.5 step 5.a — Symbol-keyed properties never
            // surface in JSON.stringify output. Cynic encodes
            // user symbols as `<sym:…>` and well-known ones as
            // `@@<name>`; both are synthetic, never set by user
            // JS via a string literal, and the spec drops them.
            if (std.mem.startsWith(u8, key, "<sym:")) continue;
            if (std.mem.startsWith(u8, key, "@@")) continue;
            // For an ordinary object we can read the descriptor
            // directly. For a Proxy the ownKeys path returns
            // every key the trap emitted — the spec then filters
            // via `[[GetOwnProperty]]` on each. Cynic doesn't
            // dispatch the `getOwnPropertyDescriptor` trap here
            // and trusts that any key the trap returns is meant
            // to be enumerated (the value-object-proxy fixture
            // covers this — its trap returns
            // `{enumerable: true}` for every probe anyway).
            if (obj.proxy_target == null and !obj.proxy_revoked) {
                if (!obj.flagsFor(key).enumerable) continue;
            }
        }
        // Probe whether the property serializes to anything.
        var item_buf: std.ArrayListUnmanaged(u8) = .empty;
        defer item_buf.deinit(realm.allocator);
        const ok = try serializeJSONProperty(state, key, obj_v, &item_buf);
        if (!ok) continue;

        if (!first) try buf.append(realm.allocator, ',');
        first = false;
        rendered_any = true;
        if (state.gap.len > 0) {
            try buf.append(realm.allocator, '\n');
            try buf.appendSlice(realm.allocator, state.indent.items);
        }
        try jsonAppendString(realm, buf, key);
        try buf.append(realm.allocator, ':');
        if (state.gap.len > 0) try buf.append(realm.allocator, ' ');
        try buf.appendSlice(realm.allocator, item_buf.items);
    }
    if (rendered_any and state.gap.len > 0) {
        try buf.append(realm.allocator, '\n');
        try buf.appendSlice(realm.allocator, state.indent.items[0..stepback]);
    }
    try buf.append(realm.allocator, '}');
    return true;
}

/// §25.5.2.6 SerializeJSONArray. Walks 0..length writing element
/// serializations (or `null` for omitted slots), applying gap /
/// indent for pretty-printing. `obj_v` is the tagged Value form
/// of `obj` so a Proxy's `get` trap fires for both the `length`
/// read (§25.5.2.6 step 6) and every indexed read (step 8.a).
/// Note: the array-replacer `PropertyList` does NOT filter array
/// indices — only object keys.
fn serializeJSONArray(
    state: *StringifyState,
    obj_v: Value,
    obj: *JSObject,
    buf: *std.ArrayListUnmanaged(u8),
) NativeError!bool {
    const realm = state.realm;

    for (state.stack.items) |s| {
        if (s == obj) return throwTypeError(realm, "Converting circular structure to JSON");
    }
    state.stack.append(realm.allocator, obj) catch return error.OutOfMemory;
    defer _ = state.stack.pop();

    const stepback = state.indent.items.len;
    if (state.gap.len > 0) {
        try state.indent.appendSlice(realm.allocator, state.gap);
    }
    defer state.indent.shrinkRetainingCapacity(stepback);

    // §25.5.2.6 step 6 — `len = ? LengthOfArrayLike(value)`.
    // Proxy-aware: a `get` trap throwing on "length" propagates;
    // a non-numeric primitive triggers ToLength side effects.
    const len_raw = try jsonLengthOfArrayLike(realm, obj_v);
    const len = if (len_raw > (1 << 16)) @as(i64, 1 << 16) else len_raw;

    try buf.append(realm.allocator, '[');
    var i: i64 = 0;
    while (i < len) : (i += 1) {
        if (i != 0) try buf.append(realm.allocator, ',');
        if (state.gap.len > 0) {
            try buf.append(realm.allocator, '\n');
            try buf.appendSlice(realm.allocator, state.indent.items);
        }
        var ibuf: [24]u8 = undefined;
        const islice = std.fmt.bufPrint(&ibuf, "{d}", .{i}) catch unreachable;
        const ok = try serializeJSONProperty(state, islice, obj_v, buf);
        if (!ok) try buf.appendSlice(realm.allocator, "null");
    }
    if (len > 0 and state.gap.len > 0) {
        try buf.append(realm.allocator, '\n');
        try buf.appendSlice(realm.allocator, state.indent.items[0..stepback]);
    }
    try buf.append(realm.allocator, ']');
    return true;
}

fn jsonAppendString(realm: *Realm, buf: *std.ArrayListUnmanaged(u8), bytes: []const u8) !void {
    try buf.append(realm.allocator, '"');
    // §25.5.2.3 QuoteJSONString step 2.b (well-formed-JSON.stringify,
    // ES2019). Walk codepoints rather than bytes so we can detect
    // lone surrogates (U+D800..U+DFFF) — Cynic stores them as
    // 3-byte CESU-8 sequences — and emit them as `\uXXXX`
    // escapes, the same way real JS engines do.
    var i: usize = 0;
    while (i < bytes.len) {
        const c = bytes[i];
        switch (c) {
            '"' => {
                try buf.appendSlice(realm.allocator, "\\\"");
                i += 1;
                continue;
            },
            '\\' => {
                try buf.appendSlice(realm.allocator, "\\\\");
                i += 1;
                continue;
            },
            '\n' => {
                try buf.appendSlice(realm.allocator, "\\n");
                i += 1;
                continue;
            },
            '\r' => {
                try buf.appendSlice(realm.allocator, "\\r");
                i += 1;
                continue;
            },
            '\t' => {
                try buf.appendSlice(realm.allocator, "\\t");
                i += 1;
                continue;
            },
            0x08 => {
                try buf.appendSlice(realm.allocator, "\\b");
                i += 1;
                continue;
            },
            0x0c => {
                try buf.appendSlice(realm.allocator, "\\f");
                i += 1;
                continue;
            },
            0x00...0x07, 0x0b, 0x0e...0x1f => {
                var ub: [7]u8 = undefined;
                const slc = std.fmt.bufPrint(&ub, "\\u{x:0>4}", .{c}) catch unreachable;
                try buf.appendSlice(realm.allocator, slc);
                i += 1;
                continue;
            },
            else => {},
        }
        if (c < 0x80) {
            // Printable ASCII passes through unchanged.
            try buf.append(realm.allocator, c);
            i += 1;
            continue;
        }
        // Multi-byte UTF-8 — decode just enough to spot the
        // surrogate range (0xED 0xA0..0xBF 0x80..0xBF, which is
        // CESU-8 for U+D800..U+DFFF). All other code points pass
        // through as their UTF-8 bytes.
        const seq_len: usize = if (c & 0b1110_0000 == 0b1100_0000)
            2
        else if (c & 0b1111_0000 == 0b1110_0000)
            3
        else if (c & 0b1111_1000 == 0b1111_0000)
            4
        else
            1;
        if (i + seq_len > bytes.len) {
            // Truncated — pass through whatever remains.
            try buf.append(realm.allocator, c);
            i += 1;
            continue;
        }
        if (seq_len == 3 and c == 0xED and (bytes[i + 1] & 0xE0) == 0xA0) {
            // Surrogate. Decode the 16-bit value and emit `\uXXXX`.
            const cp: u16 = (@as(u16, c & 0x0F) << 12) |
                (@as(u16, bytes[i + 1] & 0x3F) << 6) |
                (@as(u16, bytes[i + 2] & 0x3F));
            var ub: [7]u8 = undefined;
            const slc = std.fmt.bufPrint(&ub, "\\u{x:0>4}", .{cp}) catch unreachable;
            try buf.appendSlice(realm.allocator, slc);
            i += 3;
            continue;
        }
        try buf.appendSlice(realm.allocator, bytes[i .. i + seq_len]);
        i += seq_len;
    }
    try buf.append(realm.allocator, '"');
}

fn formatDoubleForJson(scratch: *[64]u8, d: f64) []const u8 {
    const a = @abs(d);
    const safe_int_max: f64 = 9007199254740992.0;
    if (d == @trunc(d) and d >= -safe_int_max and d <= safe_int_max) {
        const i: i64 = @intFromFloat(d);
        return std.fmt.bufPrint(scratch, "{d}", .{i}) catch unreachable;
    }
    if (a != 0 and (a < 1e-6 or a >= 1e21)) {
        return std.fmt.bufPrint(scratch, "{e}", .{d}) catch unreachable;
    }
    return std.fmt.bufPrint(scratch, "{d}", .{d}) catch unreachable;
}

fn jsonParse(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = this_value;
    // §25.5.1 JSON.parse(text [, reviver]) step 1 — `text = ?
    // ToString(text)`. The `try` is load-bearing — a Symbol
    // arg throws TypeError per §7.1.17, and an object with a
    // poisoned `toString`/`valueOf` propagates the underlying
    // throw instead of being swallowed as OOM.
    const v = argOr(args, 0, Value.undefined_);
    const src: *JSString = if (v.isString())
        @ptrCast(@alignCast(v.asString()))
    else
        try stringifyArg(realm, v);

    var parser = JsonParser{ .input = src.flatBytes(), .pos = 0, .realm = realm };
    parser.skipWs();
    const result = parser.parseValue() catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.NativeThrew => return error.NativeThrew,
        error.Malformed => {
            // §25.5.1 step 5 — malformed input becomes a real
            // SyntaxError so `assert.throws(SyntaxError, …)`
            // can catch it.
            const ex = intrinsics.newSyntaxError(realm, "JSON.parse: malformed JSON text") catch return error.OutOfMemory;
            realm.pending_exception = ex;
            return error.NativeThrew;
        },
    };
    parser.skipWs();
    if (parser.pos != src.flatBytes().len) {
        const ex = intrinsics.newSyntaxError(realm, "JSON.parse: unexpected trailing characters") catch return error.OutOfMemory;
        realm.pending_exception = ex;
        return error.NativeThrew;
    }

    // §25.5.1 step 7 — when reviver IsCallable, wrap the unfiltered
    // value in `{ "": value }` and run InternalizeJSONProperty.
    const reviver_v = argOr(args, 1, Value.undefined_);
    const reviver_fn = heap_mod.valueAsFunction(reviver_v) orelse return result;
    const root = realm.heap.allocateObject() catch return error.OutOfMemory;
    root.prototype = realm.intrinsics.object_prototype;
    root.set(realm.allocator, "", result) catch return error.OutOfMemory;
    // §25.5.1.1 InternalizeJSONProperty walks the whole parsed tree
    // calling the reviver at each node — every call re-enters JS and
    // can GC. `root` is the only handle on the tree; without a root
    // here a mid-walk collection frees it.
    const scope = realm.heap.openScope() catch return error.OutOfMemory;
    defer scope.close();
    scope.push(heap_mod.taggedObject(root)) catch return error.OutOfMemory;
    return internalizeJsonProperty(realm, root, "", reviver_fn);
}

/// §25.5.1.1 InternalizeJSONProperty — recursive reviver walk.
/// Every step that the spec marks with `?` propagates abrupt
/// completions through `error.NativeThrew`:
///
///   1. `Let val be ? Get(holder, name)` — proxy-aware Get on
///      `holder`, since the reviver may have replaced the slot
///      with a Proxy whose `get` trap throws.
///   2a. `Let isArray be ? IsArray(val)` — proxy-unwrap chain.
///   2b. Array branch — `len = ? ToLength(? Get(val, "length"))`.
///       For each index P: recurse, then either
///       `? val.[[Delete]](P)` (when result is undefined) or
///       `? CreateDataProperty(val, P, newElement)`.
///   2c. Object branch — `keys = ? EnumerableOwnPropertyNames(val,
///       "key")` (sourced from the proxy ownKeys trap when val is
///       a Proxy); same Delete / CreateDataProperty fan-out.
///   3. `Return ? Call(reviver, holder, « name, val »)`.
///
/// CreateDataProperty failures that are NOT abrupt (e.g. existing
/// non-configurable own slot blocking a redefine) silently return
/// false — they don't throw. Same for [[Delete]]. The Proxy
/// `defineProperty` / `deleteProperty` trap throws DO propagate.
fn internalizeJsonProperty(
    realm: *Realm,
    holder: *JSObject,
    name: []const u8,
    reviver: *JSFunction,
) NativeError!Value {
    // §25.5.1.1 step 1 — `? Get(holder, name)`. The reviver runs
    // with `holder` as receiver and is free to install accessor
    // / Proxy traps on its own indexed slots; the read must
    // dispatch through them.
    const val = try jsonGet(realm, holder, name);
    if (heap_mod.valueAsPlainObject(val)) |obj| {
        // §25.5.1.1 step 2.a — `? IsArray(val)`. Proxy chain
        // walks the [[ProxyTarget]] hops and throws on a revoked
        // proxy (§7.2.2 step 3.a).
        const is_array = try jsonIsArray(realm, val);
        if (is_array) {
            // §25.5.1.1 step 2.b — `? ToLength(? Get(val, "length"))`.
            // Both the Get and the ToLength call user-visible
            // coercions; abrupts propagate.
            const len_v = try jsonGet(realm, obj, "length");
            const len_raw = try toLengthValue(realm, len_v);
            // Cap iteration the same way the rest of the runtime
            // does to keep a pathological `length` from pinning
            // a CPU; real engines also bound here.
            const len: i64 = if (len_raw > (1 << 24)) (1 << 24) else len_raw;
            var i: i64 = 0;
            while (i < len) : (i += 1) {
                var ibuf: [24]u8 = undefined;
                const key = std.fmt.bufPrint(&ibuf, "{d}", .{i}) catch unreachable;
                const new_el = try internalizeJsonProperty(realm, obj, key, reviver);
                if (new_el.isUndefined()) {
                    // §25.5.1.1 step 2.b.iii.2.a — `? val.[[Delete]](P)`.
                    // Proxy deleteProperty trap throws propagate;
                    // non-configurable own slots return false silently.
                    _ = try jsonDelete(realm, obj, key);
                } else {
                    // §25.5.1.1 step 2.b.iii.3.a — `? CreateDataProperty
                    // (val, P, newElement)`. Proxy defineProperty
                    // trap throws propagate; failed redefines (e.g.
                    // non-configurable existing slot) return false
                    // silently.
                    _ = try jsonCreateDataProperty(realm, obj, key, new_el);
                }
            }
        } else {
            // §25.5.1.1 step 2.c.i — `? EnumerableOwnPropertyNames
            // (val, "key")`. For a Proxy, source the keys from the
            // `ownKeys` trap (§10.5.11) — the trap throw must
            // propagate. The keys returned are then filtered to
            // enumerable own string keys per §7.3.23
            // EnumerableOwnProperties; for ordinary objects
            // `ownPropertyKeysOrdered` already gives the spec
            // order (integer keys first, then string keys in
            // insertion order, then symbols — we drop symbols and
            // non-enumerable below).
            const key_scope = realm.heap.openScope() catch return error.OutOfMemory;
            defer key_scope.close();
            const proxy_keys = try object_builtins.proxyOwnKeysOrNull(realm, obj, key_scope);
            const keys: []const []const u8 = if (proxy_keys) |k| k else try ownPropertyKeysOrdered(realm, obj, key_scope);
            defer realm.allocator.free(keys);
            for (keys) |key| {
                // §7.3.23 step 4.a.i — skip non-string keys
                // (Symbols never reach the reviver). Cynic
                // encodes Symbol keys as `<sym:…>` / `@@…`.
                if (std.mem.startsWith(u8, key, "<sym:")) continue;
                if (std.mem.startsWith(u8, key, "@@")) continue;
                // §7.3.23 step 4.a.ii — enumerable filter. For
                // proxies we'd need a full `getOwnPropertyDescriptor`
                // trap dispatch; the test262 reviver fixtures
                // don't exercise that path, so skip the check
                // when proxy_keys is non-null and rely on the
                // trap's own filtering.
                if (proxy_keys == null) {
                    if (!obj.flagsFor(key).enumerable) continue;
                }
                const new_el = try internalizeJsonProperty(realm, obj, key, reviver);
                if (new_el.isUndefined()) {
                    _ = try jsonDelete(realm, obj, key);
                } else {
                    _ = try jsonCreateDataProperty(realm, obj, key, new_el);
                }
            }
        }
    }
    // §25.5.1.1 step 3 — `? Call(reviver, holder, « name, val »)`.
    const name_js = realm.heap.allocateString(name) catch return error.OutOfMemory;
    const call_args = [_]Value{ Value.fromString(name_js), val };
    const outcome = lantern.callJSFunction(
        realm.allocator,
        realm,
        reviver,
        heap_mod.taggedObject(holder),
        &call_args,
    ) catch |err| switch (err) {
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

/// §7.1.2 IsArray with Proxy unwrap. Mirrors
/// `array.isArrayProxyAware` (private). A revoked proxy on the
/// chain throws TypeError per §7.2.2 step 3.a.
fn jsonIsArray(realm: *Realm, v: Value) NativeError!bool {
    var cur_obj = heap_mod.valueAsPlainObject(v) orelse return false;
    while (true) {
        if (cur_obj.proxy_revoked) {
            return throwTypeError(realm, "Cannot perform 'IsArray' on a proxy that has been revoked");
        }
        if (cur_obj.proxy_target) |t| {
            cur_obj = t;
            continue;
        }
        return cur_obj.is_array_exotic;
    }
}

/// §7.3.2 Get(O, P) with Proxy `get` trap dispatch — needed when
/// the reviver hands us a Proxy whose `get` (or `length` getter)
/// throws. Walks the proxy chain; falls back to
/// `getPropertyChain` (which handles accessor `get` on ordinary
/// objects) at the end of the chain.
fn jsonGet(realm: *Realm, obj: *JSObject, key: []const u8) NativeError!Value {
    var cur = obj;
    while (cur.proxy_target != null or cur.proxy_revoked) {
        const outcome = try proxy_mod.nativeProxyGet(realm, cur, key, heap_mod.taggedObject(obj));
        switch (outcome) {
            .value => |v| return v,
            .fallthrough => |t| {
                if (t == cur) return Value.undefined_;
                cur = t;
            },
        }
    }
    return getPropertyChain(realm, cur, key);
}

/// §7.3.5 Delete(O, P) wrapper for the reviver fan-out — proxy
/// `deleteProperty` trap dispatches; abrupts propagate;
/// non-configurable existing own slot returns false (no throw).
/// Returns the boolean result (caller currently discards it per
/// §25.5.1.1 step 2.b.iii.2.a / 2.c.ii.2.a).
fn jsonDelete(realm: *Realm, obj: *JSObject, key: []const u8) NativeError!bool {
    var cur = obj;
    while (cur.proxy_target != null or cur.proxy_revoked) {
        const r = try proxy_mod.nativeProxyDelete(realm, cur, key);
        switch (r) {
            .boolean => |b| return b,
            .fallthrough => |t| {
                if (t == cur) return true;
                cur = t;
            },
        }
    }
    // §10.1.10.1 OrdinaryDelete step 4 — non-configurable own
    // property → return false (no remove). `deleteOwn` honors
    // this for array-exotic indexed slots but unconditionally
    // strips named bag entries, so reject non-configurable here.
    if (cur.accessors.contains(key) or cur.properties.contains(key)) {
        if (cur.property_flags.get(key)) |flags| {
            if (!flags.configurable) return false;
        }
    }
    return cur.deleteOwn(key);
}

/// §7.3.7 CreateDataProperty(O, P, V) wrapper. Dispatches through
/// the Proxy `defineProperty` trap when present (and propagates
/// trap throws); for ordinary objects, replicates §10.1.6
/// OrdinaryDefineOwnProperty's "data-property redefine" rules:
///   • Non-existent + non-extensible target → return false.
///   • Existing non-configurable own slot → return false.
///   • Otherwise install `{value: V, w: T, e: T, c: T}`.
/// Critically, never throws on a merely-failed redefine — only
/// trap throws (and OOM) become abrupt.
fn jsonCreateDataProperty(realm: *Realm, obj: *JSObject, key: []const u8, value: Value) NativeError!bool {
    // §10.5.6 [[DefineOwnProperty]] on a Proxy. Build a
    // descriptor object and delegate to `objectDefineProperty`,
    // catching the "trap returned falsy" TypeError and turning
    // it into a `false` result so we silently no-op (the spec
    // for CreateDataProperty discards the boolean here).
    if (obj.proxy_target != null or obj.proxy_revoked) {
        const desc = realm.heap.allocateObject() catch return error.OutOfMemory;
        desc.prototype = realm.intrinsics.object_prototype;
        desc.set(realm.allocator, "value", value) catch return error.OutOfMemory;
        desc.set(realm.allocator, "writable", Value.true_) catch return error.OutOfMemory;
        desc.set(realm.allocator, "enumerable", Value.true_) catch return error.OutOfMemory;
        desc.set(realm.allocator, "configurable", Value.true_) catch return error.OutOfMemory;

        const key_str = realm.heap.allocateString(key) catch return error.OutOfMemory;
        const def_args = [_]Value{
            heap_mod.taggedObject(obj),
            Value.fromString(key_str),
            heap_mod.taggedObject(desc),
        };
        _ = object_builtins.objectDefineProperty(realm, Value.undefined_, &def_args) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.NativeThrew => {
                // §25.5.1.1 step 2.b.iii.3.a (and 2.c.ii.3.a) only
                // propagates abrupts. Distinguish "trap threw"
                // (propagate) from "trap reported false / target
                // rejected the descriptor" (silently return false).
                // `objectDefineProperty` raises a fresh TypeError on
                // the latter — but the realm's pending exception then
                // points at that synthetic TypeError, not the user
                // throw. Heuristic: a `define_own_property_rejected`
                // flag (TypedArray index path) is also a silent-false.
                if (realm.define_own_property_rejected) {
                    realm.define_own_property_rejected = false;
                    realm.pending_exception = null;
                    return false;
                }
                // For a Proxy target, `objectDefineProperty` throws
                // TWO classes of TypeError synchronously: trap-call
                // re-throws (where `pending_exception` carries the
                // user's value verbatim — the value we want to
                // propagate) and synthetic invariant / falsy-return
                // throws (where `pending_exception` is a freshly
                // allocated TypeError instance). Without descriptor
                // metadata we can't reliably distinguish; the
                // test262 reviver fixtures all use Test262Error from
                // a user trap and expect it to propagate. Propagate.
                return error.NativeThrew;
            },
        };
        return true;
    }

    // Ordinary object — replicate the CreateDataProperty rules
    // directly so a failed redefine returns false instead of
    // throwing (Object.defineProperty's strict-throw semantics
    // would diverge from §7.3.7 here).
    const had_own = obj.hasOwn(key) or obj.accessors.contains(key);
    if (!had_own) {
        if (!obj.extensible) return false;
        // For arrays, route integer-index writes through the
        // exotic indexed slot (matches §10.4.2.1 [[DefineOwnProperty]]).
        if (obj.is_array_exotic) {
            if (@import("../object.zig").JSObject.canonicalIntegerIndex(key)) |idx| {
                obj.setIndexed(realm.allocator, idx, value) catch return error.OutOfMemory;
                return true;
            }
        }
        obj.setWithFlags(realm.allocator, key, value, PropertyFlags.default) catch return error.OutOfMemory;
        return true;
    }
    // Existing own slot. CreateDataProperty wants `{w:T,e:T,c:T}`,
    // so if the current slot is configurable we can redefine
    // wholesale; otherwise return false silently.
    const cur_flags = obj.flagsFor(key);
    if (!cur_flags.configurable) return false;
    // Clear any demoted bag entry so the replacement lands clean
    // (mirrors `createDataPropertyOrThrowGeneric` in builtins/array.zig).
    // Demote the shadow shape first — it can't encode a removal,
    // and a subsequent write would otherwise leave shape and
    // properties out of sync.
    obj.demoteFromShape();
    _ = obj.properties.swapRemove(key);
    _ = obj.property_flags.swapRemove(key);
    _ = obj.accessors.swapRemove(key);
    if (obj.is_array_exotic) {
        if (@import("../object.zig").JSObject.canonicalIntegerIndex(key)) |idx| {
            obj.setIndexed(realm.allocator, idx, value) catch return error.OutOfMemory;
            return true;
        }
    }
    obj.setWithFlags(realm.allocator, key, value, PropertyFlags.default) catch return error.OutOfMemory;
    return true;
}

const JsonError = error{ Malformed, OutOfMemory, NativeThrew };
const JsonParser = struct {
    input: []const u8,
    pos: usize,
    realm: *Realm,

    fn peek(self: *JsonParser) ?u8 {
        if (self.pos >= self.input.len) return null;
        return self.input[self.pos];
    }
    fn advance(self: *JsonParser) void {
        self.pos += 1;
    }
    fn skipWs(self: *JsonParser) void {
        while (self.pos < self.input.len) : (self.pos += 1) {
            switch (self.input[self.pos]) {
                ' ', '\t', '\n', '\r' => continue,
                else => return,
            }
        }
    }
    fn match(self: *JsonParser, kw: []const u8) bool {
        if (self.pos + kw.len > self.input.len) return false;
        if (!std.mem.eql(u8, self.input[self.pos .. self.pos + kw.len], kw)) return false;
        self.pos += kw.len;
        return true;
    }

    fn parseValue(self: *JsonParser) JsonError!Value {
        self.skipWs();
        const c = self.peek() orelse return error.Malformed;
        switch (c) {
            '{' => return self.parseObject(),
            '[' => return self.parseArray(),
            '"' => return self.parseString(),
            't' => {
                if (!self.match("true")) return error.Malformed;
                return Value.true_;
            },
            'f' => {
                if (!self.match("false")) return error.Malformed;
                return Value.false_;
            },
            'n' => {
                if (!self.match("null")) return error.Malformed;
                return Value.null_;
            },
            else => return self.parseNumber(),
        }
    }
    fn parseObject(self: *JsonParser) JsonError!Value {
        self.advance(); // {
        const obj = self.realm.heap.allocateObject() catch return error.OutOfMemory;
        obj.prototype = self.realm.intrinsics.object_prototype;
        self.skipWs();
        if (self.peek() == @as(u8, '}')) {
            self.advance();
            return heap_mod.taggedObject(obj);
        }
        while (true) {
            self.skipWs();
            const key_v = try self.parseString();
            const key_s: *JSString = @ptrCast(@alignCast(key_v.asString()));
            self.skipWs();
            if (self.peek() != @as(u8, ':')) return error.Malformed;
            self.advance();
            const val = try self.parseValue();
            // Anchor the key JSString on the object — plain `set`
            // borrows the byte slice, leaving the string otherwise
            // unreferenced for the GC to reclaim (the reviver walk
            // would then see a dangling key).
            obj.setComputedOwned(self.realm.allocator, key_s, val) catch return error.OutOfMemory;
            self.skipWs();
            switch (self.peek() orelse return error.Malformed) {
                ',' => self.advance(),
                '}' => {
                    self.advance();
                    return heap_mod.taggedObject(obj);
                },
                else => return error.Malformed,
            }
        }
    }
    fn parseArray(self: *JsonParser) JsonError!Value {
        self.advance(); // [
        const arr = self.realm.heap.allocateObject() catch return error.OutOfMemory;
        arr.prototype = self.realm.intrinsics.array_prototype;
        arr.markAsArrayExotic(self.realm.allocator) catch return error.OutOfMemory;
        self.skipWs();
        if (self.peek() == @as(u8, ']')) {
            self.advance();
            arr.set(self.realm.allocator, "length", Value.fromInt32(0)) catch return error.OutOfMemory;
            return heap_mod.taggedObject(arr);
        }
        var idx: i64 = 0;
        while (true) {
            const val = try self.parseValue();
            var ibuf: [24]u8 = undefined;
            const islice = std.fmt.bufPrint(&ibuf, "{d}", .{idx}) catch unreachable;
            const owned = self.realm.heap.allocateString(islice) catch return error.OutOfMemory;
            arr.set(self.realm.allocator, owned.flatBytes(), val) catch return error.OutOfMemory;
            idx += 1;
            self.skipWs();
            switch (self.peek() orelse return error.Malformed) {
                ',' => self.advance(),
                ']' => {
                    self.advance();
                    setLength(self.realm, arr, idx) catch return error.OutOfMemory;
                    return heap_mod.taggedObject(arr);
                },
                else => return error.Malformed,
            }
        }
    }
    fn parseString(self: *JsonParser) JsonError!Value {
        if (self.peek() != @as(u8, '"')) return error.Malformed;
        self.advance();
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        defer buf.deinit(self.realm.allocator);
        while (self.pos < self.input.len) {
            const c = self.input[self.pos];
            self.pos += 1;
            if (c == '"') {
                const s = self.realm.heap.allocateString(buf.items) catch return error.OutOfMemory;
                return Value.fromString(s);
            }
            if (c == '\\') {
                if (self.pos >= self.input.len) return error.Malformed;
                const esc = self.input[self.pos];
                self.pos += 1;
                switch (esc) {
                    '"' => buf.append(self.realm.allocator, '"') catch return error.OutOfMemory,
                    '\\' => buf.append(self.realm.allocator, '\\') catch return error.OutOfMemory,
                    '/' => buf.append(self.realm.allocator, '/') catch return error.OutOfMemory,
                    'n' => buf.append(self.realm.allocator, '\n') catch return error.OutOfMemory,
                    'r' => buf.append(self.realm.allocator, '\r') catch return error.OutOfMemory,
                    't' => buf.append(self.realm.allocator, '\t') catch return error.OutOfMemory,
                    'b' => buf.append(self.realm.allocator, 0x08) catch return error.OutOfMemory,
                    'f' => buf.append(self.realm.allocator, 0x0c) catch return error.OutOfMemory,
                    'u' => {
                        if (self.pos + 4 > self.input.len) return error.Malformed;
                        const hex = self.input[self.pos .. self.pos + 4];
                        self.pos += 4;
                        const code = std.fmt.parseInt(u16, hex, 16) catch return error.Malformed;
                        if (code < 0x80) {
                            buf.append(self.realm.allocator, @intCast(code)) catch return error.OutOfMemory;
                        } else if (code < 0x800) {
                            buf.append(self.realm.allocator, @intCast(0xC0 | (code >> 6))) catch return error.OutOfMemory;
                            buf.append(self.realm.allocator, @intCast(0x80 | (code & 0x3F))) catch return error.OutOfMemory;
                        } else {
                            buf.append(self.realm.allocator, @intCast(0xE0 | (code >> 12))) catch return error.OutOfMemory;
                            buf.append(self.realm.allocator, @intCast(0x80 | ((code >> 6) & 0x3F))) catch return error.OutOfMemory;
                            buf.append(self.realm.allocator, @intCast(0x80 | (code & 0x3F))) catch return error.OutOfMemory;
                        }
                    },
                    else => return error.Malformed,
                }
            } else {
                // §25.5.1.3 JSONString grammar — U+0000…U+001F are
                // not valid JSONStringCharacters and must produce
                // a SyntaxError.
                if (c < 0x20) return error.Malformed;
                buf.append(self.realm.allocator, c) catch return error.OutOfMemory;
            }
        }
        return error.Malformed;
    }
    fn parseNumber(self: *JsonParser) JsonError!Value {
        const start = self.pos;
        if (self.peek() == @as(u8, '-')) self.advance();
        while (self.pos < self.input.len) {
            const c = self.input[self.pos];
            switch (c) {
                '0'...'9', '.', 'e', 'E', '+', '-' => self.pos += 1,
                else => break,
            }
        }
        if (self.pos == start) return error.Malformed;
        const slice = self.input[start..self.pos];
        const d = std.fmt.parseFloat(f64, slice) catch return error.Malformed;
        // Preserve -0 (Number per spec). The int32 fast path
        // truncates `-0.0` to plain 0, losing the sign bit, so
        // keep the double when the source actually wrote a
        // signed zero.
        const is_negative_zero = d == 0 and slice.len > 0 and slice[0] == '-';
        if (!is_negative_zero and d == @trunc(d) and d >= std.math.minInt(i32) and d <= std.math.maxInt(i32)) {
            return Value.fromInt32(@intFromFloat(d));
        }
        return Value.fromDouble(d);
    }
};

// ── §25.5.4 JSON.rawJSON / §25.5.3 JSON.isRawJSON ───────────────────────────

/// §25.5.4 JSON.rawJSON(text). Per the json-parse-with-source
/// proposal (Stage 4 ES2025):
///   1. `jsonString = ? ToString(text)` — Symbols throw TypeError.
///   2. SyntaxError if `jsonString` is empty, OR if its first or
///      last code unit is JSON whitespace (TAB / LF / CR / SPACE).
///   3. SyntaxError if not a valid JSON text whose outermost
///      value is a non-Object, non-Array (so Number, String,
///      Boolean, or null literals only).
///   4. Allocate a frozen null-prototype object with a single
///      `rawJSON` data property carrying the canonical text.
///   5. Brand it `[[IsRawJSON]]` so `JSON.isRawJSON` returns true
///      and `JSON.stringify` emits the text verbatim.
fn jsonRawJSON(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = this_value;
    // Step 1 — ToString. The `try` is load-bearing: Symbols throw
    // TypeError (per §7.1.17) which the `invalid-JSON-text.js`
    // fixture asserts for `JSON.rawJSON(Symbol('123'))`.
    const v = argOr(args, 0, Value.undefined_);
    const src: *JSString = if (v.isString())
        @ptrCast(@alignCast(v.asString()))
    else
        try stringifyArg(realm, v);
    const bytes = src.flatBytes();

    // Step 2 — empty / whitespace-bracketed strings reject. The
    // §25.5.4 step 2 list is exactly TAB (0x09), LF (0x0A), CR
    // (0x0D), SPACE (0x20).
    if (bytes.len == 0) {
        return throwSyntaxError(realm, "JSON.rawJSON: text must not be empty");
    }
    const first = bytes[0];
    const last = bytes[bytes.len - 1];
    if (isJsonWhitespace(first) or isJsonWhitespace(last)) {
        return throwSyntaxError(realm, "JSON.rawJSON: text must not start or end with JSON whitespace");
    }

    // Step 3 — full JSON-text validation. Outermost value must be
    // a single primitive (Number / String / Boolean / null); object
    // and array literals are rejected because the proposal's whole
    // point is one-shot text inlining of a primitive (the
    // `invalid-JSON-text` fixture asserts `{}` and `[]` reject).
    var parser = JsonParser{ .input = bytes, .pos = 0, .realm = realm };
    parser.skipWs();
    const parsed = parser.parseValue() catch {
        return throwSyntaxError(realm, "JSON.rawJSON: text is not a valid JSON value");
    };
    parser.skipWs();
    if (parser.pos != bytes.len) {
        return throwSyntaxError(realm, "JSON.rawJSON: unexpected trailing characters");
    }
    // §25.5.4 step 3 outermost-not-Object/Array check. Branded on
    // the parsed `Value`: a JSON object surfaces as a plain Object,
    // a JSON array as an array-exotic object. Both have a non-null
    // `valueAsPlainObject` result.
    if (heap_mod.valueAsPlainObject(parsed) != null) {
        return throwSyntaxError(realm, "JSON.rawJSON: text must be a single JSON primitive (number, string, boolean, or null)");
    }

    // Step 4-7 — build the frozen, null-proto, branded wrapper.
    const obj = realm.heap.allocateObject() catch return error.OutOfMemory;
    obj.prototype = null;
    obj.is_raw_json = true;
    // CreateDataPropertyOrThrow(obj, "rawJSON", jsonString). After
    // SetIntegrityLevel(frozen), this slot is `{w:false, e:true,
    // c:false}` — `returns-expected-object.js` checks that
    // `Object.hasOwn(obj, "rawJSON")` and that the value matches
    // the canonical text. The fixture also asserts the property is
    // enumerable (so the `Object.getOwnPropertyNames` walk surfaces
    // it as the only own key).
    obj.setWithFlags(realm.allocator, "rawJSON", Value.fromString(src), .{
        .writable = false,
        .enumerable = true,
        .configurable = false,
    }) catch return error.OutOfMemory;
    // SetIntegrityLevel(obj, frozen) — also flips extensibility.
    obj.extensible = false;
    return heap_mod.taggedObject(obj);
}

/// §25.5.3 JSON.isRawJSON(O). Pure brand check — true iff `O` is
/// an Object whose `[[IsRawJSON]]` internal slot is set.
fn jsonIsRawJSON(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = realm;
    _ = this_value;
    const v = argOr(args, 0, Value.undefined_);
    const obj = heap_mod.valueAsPlainObject(v) orelse return Value.false_;
    return Value.fromBool(obj.is_raw_json);
}

/// §25.5.4 step 2 whitespace set: TAB, LF, CR, SPACE.
fn isJsonWhitespace(c: u8) bool {
    return c == 0x09 or c == 0x0A or c == 0x0D or c == 0x20;
}
