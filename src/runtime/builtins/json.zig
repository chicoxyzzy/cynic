//! §25.5 JSON — extracted from `intrinsics.zig`. Cynic's JSON
//! implementation is recursive-descent (parse) + recursive
//! (stringify); replacer / reviver hooks are later.
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

const installToStringTag = intrinsics.installToStringTag;
const argOr = intrinsics.argOr;
const ownPropertyKeysOrdered = intrinsics.ownPropertyKeysOrdered;
const getPropertyChain = intrinsics.getPropertyChain;
const throwTypeError = intrinsics.throwTypeError;
const isArrayLike = intrinsics.isArrayLike;
const setLength = intrinsics.setLength;
const lengthOfArray = intrinsics.lengthOfArray;

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
    const stringify_fn = try realm.heap.allocateFunctionNative(jsonStringify, 1, "stringify");
    stringify_fn.has_construct = false;
    try json_obj.setWithFlags(realm.allocator, "stringify", heap_mod.taggedFunction(stringify_fn), method_flags);
    const parse_fn = try realm.heap.allocateFunctionNative(jsonParse, 1, "parse");
    parse_fn.has_construct = false;
    try json_obj.setWithFlags(realm.allocator, "parse", heap_mod.taggedFunction(parse_fn), method_flags);
    try realm.globals.put(realm.allocator, "JSON", heap_mod.taggedObject(json_obj));
}

// ── JSON.{stringify, parse} ─────────────────────────────────────────────────

fn jsonStringify(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = this_value;
    const v = argOr(args, 0, Value.undefined_);
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(realm.allocator);
    const ok = jsonStringifyInto(realm, v, &buf, 0) catch return error.OutOfMemory;
    if (!ok) return Value.undefined_;
    const out = realm.heap.allocateString(buf.items) catch return error.OutOfMemory;
    return Value.fromString(out);
}

fn jsonStringifyInto(realm: *Realm, v: Value, buf: *std.ArrayListUnmanaged(u8), depth: u32) !bool {
    if (depth > 100) return error.NativeThrew; // cycle / too-deep
    if (v.isUndefined() or heap_mod.isFunction(v)) return false; // §25.5.2 — undefined / function → omit
    if (v.isNull()) {
        try buf.appendSlice(realm.allocator, "null");
        return true;
    }
    if (v.isBool()) {
        try buf.appendSlice(realm.allocator, if (v.asBool()) "true" else "false");
        return true;
    }
    if (v.isInt32()) {
        var ibuf: [24]u8 = undefined;
        const slc = std.fmt.bufPrint(&ibuf, "{d}", .{v.asInt32()}) catch unreachable;
        try buf.appendSlice(realm.allocator, slc);
        return true;
    }
    if (v.isDouble()) {
        const d = v.asDouble();
        if (std.math.isNan(d) or std.math.isInf(d)) {
            try buf.appendSlice(realm.allocator, "null");
            return true;
        }
        var ibuf: [64]u8 = undefined;
        const slc = formatDoubleForJson(&ibuf, d);
        try buf.appendSlice(realm.allocator, slc);
        return true;
    }
    if (v.isString()) {
        const s: *JSString = @ptrCast(@alignCast(v.asString()));
        try jsonAppendString(realm, buf, s.bytes);
        return true;
    }
    if (heap_mod.valueAsPlainObject(v)) |obj| {
        if (isArrayLike(v)) {
            try buf.append(realm.allocator, '[');
            const len = lengthOfArray(obj);
            const cap = if (len > (1 << 16)) 1 << 16 else len;
            var i: i64 = 0;
            while (i < cap) : (i += 1) {
                if (i != 0) try buf.append(realm.allocator, ',');
                var ibuf: [24]u8 = undefined;
                const islice = std.fmt.bufPrint(&ibuf, "{d}", .{i}) catch unreachable;
                const elem = obj.get(islice);
                const rendered = try jsonStringifyInto(realm, elem, buf, depth + 1);
                if (!rendered) try buf.appendSlice(realm.allocator, "null");
            }
            try buf.append(realm.allocator, ']');
            return true;
        }
        try buf.append(realm.allocator, '{');
        var first = true;
        // §25.5.2.4 SerializeJSONObject — walks own enumerable
        // keys in OrdinaryOwnPropertyKeys order (integer-indexed
        // first, then strings).
        const keys = try ownPropertyKeysOrdered(realm, obj);
        defer realm.allocator.free(keys);
        for (keys) |key| {
            if (!obj.flagsFor(key).enumerable) continue;
            const val = try getPropertyChain(realm, obj, key);
            if (val.isUndefined() or heap_mod.isFunction(val)) continue;
            if (!first) try buf.append(realm.allocator, ',');
            first = false;
            try jsonAppendString(realm, buf, key);
            try buf.append(realm.allocator, ':');
            const rendered = try jsonStringifyInto(realm, val, buf, depth + 1);
            if (!rendered) try buf.appendSlice(realm.allocator, "null");
        }
        try buf.append(realm.allocator, '}');
        return true;
    }
    return false;
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
        if (d == @trunc(d) and d >= std.math.minInt(i32) and d <= std.math.maxInt(i32)) {
            return Value.fromInt32(@intFromFloat(d));
        }
        return Value.fromDouble(d);
    }
};

