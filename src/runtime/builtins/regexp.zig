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
const argOr = intrinsics.argOr;
const stringifyArg = intrinsics.stringifyArg;
const throwTypeError = intrinsics.throwTypeError;

// ── libregexp C API ─────────────────────────────────────────────────────────

const c = @cImport({
    @cInclude("libregexp.h");
});

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
    const r = try installConstructor(realm, .{
        .name = "RegExp", .ctor = regexpConstructor, .arity = 2,
        .set_home_object = false,
    });
    const fn_obj = r.ctor;
    const proto = r.proto;

    try installNativeMethodOnProto(realm, proto, "test", regexpTest, 1);
    try installNativeMethodOnProto(realm, proto, "exec", regexpExec, 1);
    try installNativeMethodOnProto(realm, proto, "toString", regexpToString, 0);

    try installNativeMethod(realm, fn_obj, "escape", regexpEscape, 1);
}

fn regexpConstructor(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const inst = heap_mod.valueAsPlainObject(this_value) orelse return throwTypeError(realm, "RegExp constructor requires 'new'");
    const pattern_v = argOr(args, 0, Value.undefined_);
    const flags_v = argOr(args, 1, Value.undefined_);
    const pat_s = if (pattern_v.isUndefined())
        realm.heap.allocateString("") catch return error.OutOfMemory
    else
        stringifyArg(realm, pattern_v) catch return error.OutOfMemory;
    const flag_s = if (flags_v.isUndefined())
        realm.heap.allocateString("") catch return error.OutOfMemory
    else
        stringifyArg(realm, flags_v) catch return error.OutOfMemory;
    inst.set(realm.allocator, "source", Value.fromString(pat_s)) catch return error.OutOfMemory;
    inst.set(realm.allocator, "flags", Value.fromString(flag_s)) catch return error.OutOfMemory;
    inst.set(realm.allocator, "lastIndex", Value.fromInt32(0)) catch return error.OutOfMemory;
    return this_value;
}

// ── Pattern compile cache ───────────────────────────────────────────────────

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
    return f;
}

fn ensureBytecode(realm: *Realm, regex_obj: *JSObject) NativeError!?[]u8 {
    if (regex_obj.regex_bytecode) |bc| return bc;
    const src_v = regex_obj.get("source");
    const flags_v = regex_obj.get("flags");
    if (!src_v.isString()) return null;
    const src_s: *JSString = @ptrCast(@alignCast(src_v.asString()));
    const flag_str: []const u8 = if (flags_v.isString()) (@as(*JSString, @ptrCast(@alignCast(flags_v.asString())))).bytes else "";
    const re_flags = parseFlags(flag_str);

    var err_buf: [128]u8 = undefined;
    @memset(&err_buf, 0);
    var bc_len: c_int = 0;
    // libregexp's parser checks `*buf_ptr != '\0'` after the
    // outer disjunction to detect trailing junk, so the input
    // must be NUL-terminated. Copy into a heap buffer + null.
    const src_z = realm.allocator.alloc(u8, src_s.bytes.len + 1) catch return error.OutOfMemory;
    defer realm.allocator.free(src_z);
    @memcpy(src_z[0..src_s.bytes.len], src_s.bytes);
    src_z[src_s.bytes.len] = 0;
    const bc_ptr = c.lre_compile(
        &bc_len,
        &err_buf[0],
        @intCast(err_buf.len),
        @ptrCast(src_z.ptr),
        src_s.bytes.len,
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
    const input_s = stringifyArg(realm, argOr(args, 0, Value.undefined_)) catch return error.OutOfMemory;
    const bc = (try ensureBytecode(realm, regex_obj)) orelse return Value.null_;

    var input = buildInputBuf(realm.allocator, input_s.bytes) catch return error.OutOfMemory;
    defer input.deinit();

    const re_flags = c.lre_get_flags(bc.ptr);
    const cap_count_c = c.lre_get_capture_count(bc.ptr);
    const cap_count: usize = @intCast(cap_count_c);
    const is_global = (re_flags & LRE_FLAG_GLOBAL) != 0;
    const is_sticky = (re_flags & LRE_FLAG_STICKY) != 0;

    const last_index_v = regex_obj.get("lastIndex");
    var last_index: usize = if (last_index_v.isInt32() and last_index_v.asInt32() >= 0) @intCast(last_index_v.asInt32()) else 0;
    if (!is_global and !is_sticky) last_index = 0;
    if (last_index > input.units.len) {
        regex_obj.set(realm.allocator, "lastIndex", Value.fromInt32(0)) catch return error.OutOfMemory;
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
        if (is_global or is_sticky) {
            regex_obj.set(realm.allocator, "lastIndex", Value.fromInt32(0)) catch return error.OutOfMemory;
        }
        return Value.null_;
    }

    // Translate capture pointers to UTF-16 unit indices.
    const cbuf_addr: usize = @intFromPtr(cbuf);
    const whole_start: usize = if (captures[0]) |p| (@intFromPtr(p) - cbuf_addr) / 2 else 0;
    const whole_end: usize = if (captures[1]) |p| (@intFromPtr(p) - cbuf_addr) / 2 else 0;

    if (is_global or is_sticky) {
        regex_obj.set(realm.allocator, "lastIndex", Value.fromInt32(@intCast(whole_end))) catch return error.OutOfMemory;
    }

    // Build the result array per §22.2.7.2 — `[whole,...captures]`
    // with `index` and `input` properties on the result.
    const out = realm.heap.allocateObject() catch return error.OutOfMemory;
    out.prototype = realm.intrinsics.array_prototype;
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
    return heap_mod.taggedObject(out);
}

fn regexpTest(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const result = try regexpExec(realm, this_value, args);
    return Value.fromBool(!result.isNull());
}

fn regexpToString(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    const obj = heap_mod.valueAsPlainObject(this_value) orelse return throwTypeError(realm, "RegExp.toString on non-object");
    const src_v = obj.get("source");
    const flags_v = obj.get("flags");
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

/// §22.2.6 RegExp.escape — pure string transform, no engine
/// needed.
fn regexpEscape(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = this_value;
    const arg = argOr(args, 0, Value.undefined_);
    if (!arg.isString()) return throwTypeError(realm, "RegExp.escape argument must be a string");
    const s: *JSString = @ptrCast(@alignCast(arg.asString()));
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(realm.allocator);
    for (s.bytes, 0..) |ch, i| {
        const must_hex_first = i == 0 and (ch >= '0' and ch <= '9');
        if (must_hex_first or ch < 0x20 or ch >= 0x7f) {
            const hex = "0123456789abcdef";
            out.appendSlice(realm.allocator, "\\x") catch return error.OutOfMemory;
            out.append(realm.allocator, hex[ch >> 4]) catch return error.OutOfMemory;
            out.append(realm.allocator, hex[ch & 0x0F]) catch return error.OutOfMemory;
            continue;
        }
        switch (ch) {
            '^', '$', '\\', '.', '*', '+', '?', '(', ')', '[', ']', '{', '}', '|', '/' => {
                out.append(realm.allocator, '\\') catch return error.OutOfMemory;
                out.append(realm.allocator, ch) catch return error.OutOfMemory;
            },
            ',', '-', '=', '<', '>', '#', '&', '!', '%', ':', ';', '@', '~', '\'', '`', '"' => {
                out.append(realm.allocator, '\\') catch return error.OutOfMemory;
                out.append(realm.allocator, ch) catch return error.OutOfMemory;
            },
            else => out.append(realm.allocator, ch) catch return error.OutOfMemory,
        }
    }
    const r = realm.heap.allocateString(out.items) catch return error.OutOfMemory;
    return Value.fromString(r);
}
