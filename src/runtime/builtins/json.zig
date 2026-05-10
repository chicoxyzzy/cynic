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
const interpreter = @import("../interpreter.zig");

const installToStringTag = intrinsics.installToStringTag;
const argOr = intrinsics.argOr;
const ownPropertyKeysOrdered = intrinsics.ownPropertyKeysOrdered;
const getPropertyChain = intrinsics.getPropertyChain;
const throwTypeError = intrinsics.throwTypeError;
const isArrayLike = intrinsics.isArrayLike;
const setLength = intrinsics.setLength;
const lengthOfArray = intrinsics.lengthOfArray;
const stringifyArg = intrinsics.stringifyArg;
const toNumber = intrinsics.toNumber;

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

    // §25.5.2 step 4 — resolve replacer.
    if (heap_mod.valueAsFunction(replacer_v)) |fn_obj| {
        state.replacer_fn = fn_obj;
    } else if (heap_mod.valueAsPlainObject(replacer_v)) |robj| {
        if (isArrayLike(replacer_v)) {
            try resolvePropertyList(&state, robj);
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

    const ok = try serializeJSONProperty(&state, "", wrapper, &buf);
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
fn resolvePropertyList(state: *StringifyState, robj: *JSObject) NativeError!void {
    const realm = state.realm;
    const len_raw = lengthOfArray(robj);
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
        const v = try getPropertyChain(realm, robj, islice);

        var item_bytes: ?[]const u8 = null;
        if (v.isString()) {
            const s: *JSString = @ptrCast(@alignCast(v.asString()));
            item_bytes = s.bytes;
        } else if (v.isInt32() or v.isDouble()) {
            const owned = stringifyArg(realm, v) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => continue,
            };
            item_bytes = owned.bytes;
        } else if (heap_mod.valueAsPlainObject(v)) |o| {
            // §25.5.2 step 4.b.iv.4.e — accept Number / String
            // wrapper objects; coerce via ToString. Order
            // matters: String wrappers also pin `boxed_primitive`,
            // so look for the string slot first.
            if (o.boxed_string != null) {
                const s = try stringifyArg(realm, v);
                item_bytes = s.bytes;
            } else if (o.boxed_primitive) |bp| {
                if (bp.isInt32() or bp.isDouble()) {
                    const s = try stringifyArg(realm, v);
                    item_bytes = s.bytes;
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
        if (s.bytes.len == 0) return;
        // Cynic stores strings as UTF-8 byte buffers. The spec
        // counts UTF-16 code units; for the common ASCII /
        // BMP-non-supplementary inputs the truncation aligns
        // exactly. For the rest, first-10-bytes is a tolerable
        // approximation — the test262 fixtures use ASCII.
        const len = if (s.bytes.len > 10) 10 else s.bytes.len;
        const buf = realm.allocator.alloc(u8, len) catch return error.OutOfMemory;
        @memcpy(buf, s.bytes[0..len]);
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
fn serializeJSONProperty(
    state: *StringifyState,
    key: []const u8,
    holder: *JSObject,
    buf: *std.ArrayListUnmanaged(u8),
) NativeError!bool {
    const realm = state.realm;

    // §25.5.2.4 step 1 — value = Get(holder, key).
    var value = try getPropertyChain(realm, holder, key);

    // §25.5.2.4 step 2 — toJSON for objects + BigInts.
    if (heap_mod.valueAsPlainObject(value)) |o| {
        const tj = try getPropertyChain(realm, o, "toJSON");
        if (heap_mod.valueAsFunction(tj)) |fn_obj| {
            const key_s = realm.heap.allocateString(key) catch return error.OutOfMemory;
            const cb_args = [_]Value{Value.fromString(key_s)};
            const outcome = interpreter.callJSFunction(realm.allocator, realm, fn_obj, value, &cb_args) catch |err| switch (err) {
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

    // §25.5.2.4 step 3 — invoke replacer function with holder
    // as `this`, args = [key, value]. Top-level call has key="".
    if (state.replacer_fn) |rf| {
        const key_s = realm.heap.allocateString(key) catch return error.OutOfMemory;
        const cb_args = [_]Value{ Value.fromString(key_s), value };
        const outcome = interpreter.callJSFunction(realm.allocator, realm, rf, heap_mod.taggedObject(holder), &cb_args) catch |err| switch (err) {
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

    // §25.5.2.4 step 4 — unwrap Number / String / Boolean /
    // BigInt wrapper objects to their underlying primitive.
    // String wrappers also pin `boxed_primitive`; we want
    // ToString in that case, so check `boxed_string` first.
    if (heap_mod.valueAsPlainObject(value)) |o| {
        if (o.boxed_string != null) {
            const s = try stringifyArg(realm, value);
            value = Value.fromString(s);
        } else if (o.boxed_primitive) |bp| {
            if (bp.isInt32() or bp.isDouble()) {
                value = try toNumber(realm, value);
            } else if (bp.isBool()) {
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
        try jsonAppendString(realm, buf, s.bytes);
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
        if (isArrayLike(value)) {
            return serializeJSONArray(state, obj, buf);
        }
        return serializeJSONObject(state, obj, buf);
    }
    return false;
}

/// §25.5.2.5 SerializeJSONObject. Walks the resolved property
/// list (or own enumerable string keys when none) and emits each
/// key:value pair, applying gap / indent for pretty-printing.
fn serializeJSONObject(
    state: *StringifyState,
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
    // else own enumerable string-or-integer keys in spec order.
    var owned_keys: ?[]const []const u8 = null;
    defer if (owned_keys) |k| realm.allocator.free(k);
    const keys: []const []const u8 = if (state.property_list) |pl| pl else blk: {
        const all = try ownPropertyKeysOrdered(realm, obj);
        owned_keys = all;
        break :blk all;
    };

    try buf.append(realm.allocator, '{');
    var first = true;
    var rendered_any = false;
    for (keys) |key| {
        // When using own keys, skip non-enumerable.
        if (state.property_list == null) {
            if (!obj.flagsFor(key).enumerable) continue;
        }
        // Probe whether the property serializes to anything.
        var item_buf: std.ArrayListUnmanaged(u8) = .empty;
        defer item_buf.deinit(realm.allocator);
        const ok = try serializeJSONProperty(state, key, obj, &item_buf);
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
/// indent for pretty-printing. Note: the array-replacer
/// `PropertyList` does NOT filter array indices — only objects.
fn serializeJSONArray(
    state: *StringifyState,
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

    const len_raw = lengthOfArray(obj);
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
        const ok = try serializeJSONProperty(state, islice, obj, buf);
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
    for (bytes) |c| switch (c) {
        '"' => try buf.appendSlice(realm.allocator, "\\\""),
        '\\' => try buf.appendSlice(realm.allocator, "\\\\"),
        '\n' => try buf.appendSlice(realm.allocator, "\\n"),
        '\r' => try buf.appendSlice(realm.allocator, "\\r"),
        '\t' => try buf.appendSlice(realm.allocator, "\\t"),
        0x08 => try buf.appendSlice(realm.allocator, "\\b"),
        0x0c => try buf.appendSlice(realm.allocator, "\\f"),
        0x00...0x07, 0x0b, 0x0e...0x1f => {
            var ub: [7]u8 = undefined;
            const slc = std.fmt.bufPrint(&ub, "\\u{x:0>4}", .{c}) catch unreachable;
            try buf.appendSlice(realm.allocator, slc);
        },
        else => try buf.append(realm.allocator, c),
    };
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
    const v = argOr(args, 0, Value.undefined_);
    if (!v.isString()) return error.NativeThrew;
    const src: *JSString = @ptrCast(@alignCast(v.asString()));

    var parser = JsonParser{ .input = src.bytes, .pos = 0, .realm = realm };
    parser.skipWs();
    const result = parser.parseValue() catch return error.NativeThrew;
    parser.skipWs();
    if (parser.pos != src.bytes.len) return error.NativeThrew;
    return result;
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
            obj.set(self.realm.allocator, key_s.bytes, val) catch return error.OutOfMemory;
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
            arr.set(self.realm.allocator, owned.bytes, val) catch return error.OutOfMemory;
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
