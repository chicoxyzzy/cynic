//! Stage 4 — Uint8Array ↔ base64/hex (ES2025 ArrayBuffer ↔ base64/hex
//! proposal — https://tc39.es/proposal-arraybuffer-base64/spec/).
//!
//! Wires six methods onto `Uint8Array` and `Uint8Array.prototype`:
//!   • Static:  `fromBase64`, `fromHex`
//!   • Method:  `setFromBase64`, `setFromHex`, `toBase64`, `toHex`
//!
//! Brand checks per spec key on `[[TypedArrayName]] === "Uint8Array"`
//! — Uint8ClampedArray shares `kind = .uint8` but must NOT pass.
//! Static methods ignore their receiver and always allocate a fresh
//! `Uint8Array` (its `prototype` resolved off the realm globals).
//!
//! Codec is hand-rolled (not `std.base64`) because the spec's
//! `lastChunkHandling` modes (`loose` / `strict` / `stop-before-partial`)
//! and ASCII-whitespace skipping aren't representable through
//! `std.base64.Decoder.options`.

const std = @import("std");

const Realm = @import("../realm.zig").Realm;
const Value = @import("../value.zig").Value;
const JSString = @import("../string.zig").JSString;
const JSObject = @import("../object.zig").JSObject;
const JSFunction = @import("../function.zig").JSFunction;
const NativeError = @import("../function.zig").NativeError;
const heap_mod = @import("../heap.zig");
const intrinsics = @import("../intrinsics.zig");
const ObjMod = @import("../object.zig");

const throwTypeError = intrinsics.throwTypeError;
const throwSyntaxError = intrinsics.throwSyntaxError;
const installNativeMethod = intrinsics.installNativeMethod;
const installNativeMethodOnProto = intrinsics.installNativeMethodOnProto;
const argOr = intrinsics.argOr;
const getPropertyChain = intrinsics.getPropertyChain;
const toBoolean = intrinsics.toBoolean;

// ── Entry point ─────────────────────────────────────────────────────

pub fn installOnUint8Array(realm: *Realm, ctor: *JSFunction, proto: *JSObject) !void {
    try installNativeMethod(realm, ctor, "fromBase64", uint8FromBase64, 1);
    try installNativeMethod(realm, ctor, "fromHex", uint8FromHex, 1);
    try installNativeMethodOnProto(realm, proto, "setFromBase64", uint8SetFromBase64, 1);
    try installNativeMethodOnProto(realm, proto, "setFromHex", uint8SetFromHex, 1);
    try installNativeMethodOnProto(realm, proto, "toBase64", uint8ToBase64, 0);
    try installNativeMethodOnProto(realm, proto, "toHex", uint8ToHex, 0);
}

// ── Option parsing helpers ──────────────────────────────────────────

const Alphabet = enum { base64, base64url };
const LastChunk = enum { loose, strict, stop_before_partial };

/// Spec — only accept a *string primitive* for `alphabet` /
/// `lastChunkHandling`. Object-boxed strings (`Object("base64")`)
/// and `toString`-able values throw TypeError without invoking
/// the conversion. See `option-coercion.js`.
fn requireStringOption(v: Value) ?[]const u8 {
    if (!v.isString()) return null;
    const s: *JSString = @ptrCast(@alignCast(v.asString()));
    return s.flatBytes();
}

fn readAlphabetOption(realm: *Realm, options: Value) NativeError!Alphabet {
    const obj = heap_mod.valueAsPlainObject(options) orelse return .base64;
    const v = try getPropertyChain(realm, obj, "alphabet");
    if (v.isUndefined()) return .base64;
    const s = requireStringOption(v) orelse
        return throwTypeError(realm, "alphabet option must be a string");
    if (std.mem.eql(u8, s, "base64")) return .base64;
    if (std.mem.eql(u8, s, "base64url")) return .base64url;
    return throwTypeError(realm, "alphabet must be \"base64\" or \"base64url\"");
}

fn readLastChunkHandling(realm: *Realm, options: Value) NativeError!LastChunk {
    const obj = heap_mod.valueAsPlainObject(options) orelse return .loose;
    const v = try getPropertyChain(realm, obj, "lastChunkHandling");
    if (v.isUndefined()) return .loose;
    const s = requireStringOption(v) orelse
        return throwTypeError(realm, "lastChunkHandling option must be a string");
    if (std.mem.eql(u8, s, "loose")) return .loose;
    if (std.mem.eql(u8, s, "strict")) return .strict;
    if (std.mem.eql(u8, s, "stop-before-partial")) return .stop_before_partial;
    return throwTypeError(realm, "lastChunkHandling must be \"loose\", \"strict\", or \"stop-before-partial\"");
}

fn readOmitPadding(realm: *Realm, options: Value) NativeError!bool {
    const obj = heap_mod.valueAsPlainObject(options) orelse return false;
    const v = try getPropertyChain(realm, obj, "omitPadding");
    return toBoolean(v);
}

// ── Receiver / argument helpers ─────────────────────────────────────

/// Brand-check: must be a TypedArray whose `[[TypedArrayName]]` is
/// exactly `"Uint8Array"`. Uint8ClampedArray shares `kind = .uint8`
/// but is told apart by `tv.name`.
fn requireUint8ArrayReceiver(realm: *Realm, this_value: Value, comptime label: []const u8) NativeError!*JSObject {
    const obj = heap_mod.valueAsPlainObject(this_value) orelse
        return throwTypeError(realm, label ++ " called on non-object");
    const tv = obj.getTypedView() orelse
        return throwTypeError(realm, label ++ " called on non-Uint8Array");
    if (!std.mem.eql(u8, tv.name, "Uint8Array"))
        return throwTypeError(realm, label ++ " called on non-Uint8Array");
    return obj;
}

/// Re-fetch the live view + writable byte slice after any
/// re-entry into JS (option getters can detach the buffer or
/// resize the backing ArrayBuffer). Returns null if the view is
/// out of bounds (detached or shrunk past).
fn liveUint8View(obj: *JSObject) ?struct { tv: ObjMod.TypedView, bytes: []u8 } {
    const tv = obj.getTypedView() orelse return null;
    const buf = tv.viewed.getArrayBuffer() orelse return null;
    const elem_size = tv.kind.elementSize();
    var length: usize = tv.length;
    if (tv.length_tracking) {
        if (tv.byte_offset > buf.len) return null;
        length = (buf.len - tv.byte_offset) / elem_size;
    } else {
        if (tv.byte_offset + tv.length * elem_size > buf.len) return null;
    }
    if (tv.byte_offset > buf.len) return null;
    return .{ .tv = tv, .bytes = buf[tv.byte_offset .. tv.byte_offset + length] };
}

/// Require an argument that is a real string primitive. Spec
/// short-circuits before any `toString`-able coercion (see
/// `string-coercion.js`).
fn requireStringArg(realm: *Realm, v: Value, comptime label: []const u8) NativeError![]const u8 {
    if (!v.isString())
        return throwTypeError(realm, label ++ " requires a string argument");
    const s: *JSString = @ptrCast(@alignCast(v.asString()));
    return s.flatBytes();
}

// ── Base64 alphabet tables ──────────────────────────────────────────

const STD_ALPHA = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
const URL_ALPHA = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";

/// Returns 0..63 on hit, 0xFF on miss.
fn decodeBase64Char(c: u8, alphabet: Alphabet) u8 {
    switch (c) {
        'A'...'Z' => return c - 'A',
        'a'...'z' => return c - 'a' + 26,
        '0'...'9' => return c - '0' + 52,
        else => {},
    }
    switch (alphabet) {
        .base64 => switch (c) {
            '+' => return 62,
            '/' => return 63,
            else => return 0xFF,
        },
        .base64url => switch (c) {
            '-' => return 62,
            '_' => return 63,
            else => return 0xFF,
        },
    }
}

fn isAsciiWhitespace(c: u8) bool {
    return c == 0x09 or c == 0x0A or c == 0x0C or c == 0x0D or c == 0x20;
}

// ── FromBase64 core decoder ─────────────────────────────────────────

const DecodeResult = struct {
    /// Bytes written into `out`.
    written: usize,
    /// Code units (== bytes here, the input is ASCII when no
    /// throw) consumed from the input string.
    read: usize,
    /// Non-null when decoding hit an error. The error is reported
    /// only if no `out` slot remained — partial writes from
    /// earlier chunks have already happened.
    err: ?ErrorKind,
};
const ErrorKind = enum { invalid_char, bad_padding, excess_padding, incomplete_chunk, nonzero_padding_bits };

/// SkipAsciiWhitespace — advance `i` past any run of ASCII
/// whitespace (`0x09 0x0A 0x0C 0x0D 0x20`).
fn skipWhitespace(input: []const u8, i: usize) usize {
    var j = i;
    while (j < input.len and isAsciiWhitespace(input[j])) j += 1;
    return j;
}

/// Spec-faithful FromBase64 — see §10.3 of the proposal. Writes
/// at most `out.len` bytes (this is the `maxLength` parameter)
/// into `out`. Returns:
///   • written — bytes appended to `out`
///   • read    — code units consumed (== bytes, ASCII input only)
///   • err     — null on success; an `ErrorKind` if validation
///               failed AFTER any partial writes already landed.
fn fromBase64(
    input: []const u8,
    out: []u8,
    alphabet: Alphabet,
    last_chunk: LastChunk,
) DecodeResult {
    const max_len = out.len;
    // §10.3 step 1 — maxLength = 0 short-circuit. Return early
    // without consuming any input (trailing-garbage-empty.js).
    if (max_len == 0) {
        return .{ .written = 0, .read = 0, .err = null };
    }

    // §10.3 steps 2-7 — initialise locals.
    var read: usize = 0;
    var written: usize = 0;
    var chunk: [4]u8 = undefined;
    var chunk_len: usize = 0;
    var index: usize = 0;

    while (true) {
        // §10.3 step 10.a — SkipAsciiWhitespace.
        index = skipWhitespace(input, index);
        // §10.3 step 10.b — `If index = length, …`
        if (index >= input.len) {
            if (chunk_len > 0) {
                if (last_chunk == .stop_before_partial) {
                    return .{ .written = written, .read = read, .err = null };
                }
                if (last_chunk == .loose) {
                    if (chunk_len == 1) {
                        return .{ .written = written, .read = read, .err = .incomplete_chunk };
                    }
                    // Decode partial chunk with throwOnExtraBits = false.
                    emitPartialChunk(&chunk, chunk_len, out, &written, false) catch unreachable;
                } else { // strict
                    return .{ .written = written, .read = read, .err = .bad_padding };
                }
            }
            return .{ .written = written, .read = input.len, .err = null };
        }
        // §10.3 step 10.c — `Let char be the substring at index`.
        const c = input[index];
        index += 1;
        // §10.3 step 10.d — `If char is "=", …`
        if (c == '=') {
            if (chunk_len < 2) {
                return .{ .written = written, .read = read, .err = .bad_padding };
            }
            // §10.3 — Set index to SkipAsciiWhitespace(string, index).
            index = skipWhitespace(input, index);
            if (chunk_len == 2) {
                // Need a second '=' to complete padding.
                if (index >= input.len) {
                    if (last_chunk == .stop_before_partial) {
                        return .{ .written = written, .read = read, .err = null };
                    }
                    return .{ .written = written, .read = read, .err = .bad_padding };
                }
                if (input[index] == '=') {
                    // Consume the second '=' and any trailing WS.
                    index = skipWhitespace(input, index + 1);
                }
                // Note: if char is NOT '=' here, we fall through
                // to the `index < length` check below — that's
                // the spec's `Zg=&` rejection path.
            }
            // §10.3 — `If index < length, error`.
            if (index < input.len) {
                return .{ .written = written, .read = read, .err = .excess_padding };
            }
            // Decode with throwOnExtraBits = (strict mode).
            const throw_on_extra = last_chunk == .strict;
            emitPartialChunk(&chunk, chunk_len, out, &written, throw_on_extra) catch {
                return .{ .written = written, .read = read, .err = .nonzero_padding_bits };
            };
            return .{ .written = written, .read = input.len, .err = null };
        }
        // §10.3 step 10.e — alphabet validation.
        var ch = c;
        if (alphabet == .base64url) {
            if (c == '+' or c == '/') {
                return .{ .written = written, .read = read, .err = .invalid_char };
            }
            if (c == '-') ch = '+';
            if (c == '_') ch = '/';
        }
        const sextet = decodeBase64Char(ch, .base64);
        if (sextet == 0xFF) {
            return .{ .written = written, .read = read, .err = .invalid_char };
        }
        // §10.3 step 10.f — `Let remaining be maxLength - bytes`.
        const remaining = max_len - written;
        if ((remaining == 1 and chunk_len == 2) or (remaining == 2 and chunk_len == 3)) {
            // §10.3 step 10.g — short-circuit. Note: `read` stays
            // at the position before this char was consumed —
            // BUT spec says "Return … [[Read]]: read" (the cached
            // read pointer). `read` was last updated after the
            // previous chunk-of-4. Don't advance it.
            return .{ .written = written, .read = read, .err = null };
        }
        // §10.3 step 10.h-i — append to chunk, bump chunkLength.
        chunk[chunk_len] = sextet;
        chunk_len += 1;
        if (chunk_len == 4) {
            // §10.3 step 10.j — emit 3 bytes, reset, advance read.
            const b0 = (chunk[0] << 2) | (chunk[1] >> 4);
            const b1 = (chunk[1] << 4) | (chunk[2] >> 2);
            const b2 = (chunk[2] << 6) | chunk[3];
            // Caller-allocated `out` is at least max_len; we just
            // checked remaining ≥ 3 (no short-circuit fired).
            out[written + 0] = b0;
            out[written + 1] = b1;
            out[written + 2] = b2;
            written += 3;
            chunk_len = 0;
            read = index;
            // §10.3 step 10.k — `If length of bytes = maxLength,
            // return`. Buffer just filled exactly.
            if (written == max_len) {
                // Per spec, `read` stops at last successfully
                // decoded chunk. Don't advance further.
                return .{ .written = written, .read = read, .err = null };
            }
        }
    }
}

const PartialChunkError = error{NonZeroPaddingBits};

/// DecodeBase64Chunk for a partial last chunk (chunkLength = 2
/// or 3). When `throw_on_extra` is true (strict mode), the
/// trailing padding bits must be zero.
fn emitPartialChunk(
    chunk: *const [4]u8,
    chunk_len: usize,
    out: []u8,
    written: *usize,
    throw_on_extra: bool,
) PartialChunkError!void {
    if (chunk_len == 2) {
        const b0 = (chunk[0] << 2) | (chunk[1] >> 4);
        const tail_bits: u8 = chunk[1] & 0x0F;
        if (throw_on_extra and tail_bits != 0) return error.NonZeroPaddingBits;
        if (written.* < out.len) {
            out[written.*] = b0;
            written.* += 1;
        }
    } else { // chunk_len == 3
        const b0 = (chunk[0] << 2) | (chunk[1] >> 4);
        const b1 = (chunk[1] << 4) | (chunk[2] >> 2);
        const tail_bits: u8 = chunk[2] & 0x03;
        if (throw_on_extra and tail_bits != 0) return error.NonZeroPaddingBits;
        if (written.* < out.len) {
            out[written.*] = b0;
            written.* += 1;
        }
        if (written.* < out.len) {
            out[written.*] = b1;
            written.* += 1;
        }
    }
}

// ── FromHex core decoder ────────────────────────────────────────────

const HexDecodeResult = struct {
    written: usize,
    read: usize,
    err: ?HexErrorKind,
};
const HexErrorKind = enum { odd_length, invalid_char };

fn hexValue(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

/// Decode `input` (must be even-length, no whitespace allowed) into
/// `out`. Stops at `out.len` and reports any post-fill garbage as a
/// non-error short-circuit (per §FromHex maxLength clause).
fn fromHex(input: []const u8, out: []u8) HexDecodeResult {
    if (input.len % 2 != 0) {
        return .{ .written = 0, .read = 0, .err = .odd_length };
    }
    var i: usize = 0;
    var written: usize = 0;
    while (i + 1 < input.len) : (i += 2) {
        if (written == out.len) {
            // Spec's maxLength short-circuit — return without
            // looking at the remaining input. `read` stays at
            // the start of this unconsumed pair.
            return .{ .written = written, .read = i, .err = null };
        }
        const hi = hexValue(input[i]) orelse
            return .{ .written = written, .read = i, .err = .invalid_char };
        const lo = hexValue(input[i + 1]) orelse
            return .{ .written = written, .read = i, .err = .invalid_char };
        out[written] = (hi << 4) | lo;
        written += 1;
    }
    return .{ .written = written, .read = input.len, .err = null };
}

// ── Helpers for building output values ──────────────────────────────

fn syntaxErrorFor(realm: *Realm, kind: ErrorKind) NativeError {
    return switch (kind) {
        .invalid_char => throwSyntaxError(realm, "Uint8Array.fromBase64: invalid character"),
        .bad_padding => throwSyntaxError(realm, "Uint8Array.fromBase64: incorrect padding"),
        .excess_padding => throwSyntaxError(realm, "Uint8Array.fromBase64: trailing characters after padding"),
        .incomplete_chunk => throwSyntaxError(realm, "Uint8Array.fromBase64: incomplete chunk"),
        .nonzero_padding_bits => throwSyntaxError(realm, "Uint8Array.fromBase64: non-zero padding bits"),
    };
}

fn hexSyntaxErrorFor(realm: *Realm, kind: HexErrorKind) NativeError {
    return switch (kind) {
        .odd_length => throwSyntaxError(realm, "Uint8Array.fromHex: input has odd length"),
        .invalid_char => throwSyntaxError(realm, "Uint8Array.fromHex: invalid hex character"),
    };
}

/// Allocate a fresh `Uint8Array` of `length` bytes, copy `bytes_in`
/// into its buffer (must be `length` long), return the instance.
fn makeUint8ArrayFromBytes(realm: *Realm, bytes_in: []const u8) NativeError!*JSObject {
    const ctor_v = realm.globals.get("Uint8Array") orelse
        return throwTypeError(realm, "Uint8Array constructor missing");
    const ctor = heap_mod.valueAsFunction(ctor_v) orelse
        return throwTypeError(realm, "Uint8Array constructor not callable");
    const inst = realm.heap.allocateObject() catch return error.OutOfMemory;
    realm.heap.setObjectPrototype(inst, ctor.prototype);
    const buf_obj = realm.heap.allocateObject() catch return error.OutOfMemory;
    if (heap_mod.valueAsFunction(realm.globals.get("ArrayBuffer") orelse Value.undefined_)) |ab| {
        realm.heap.setObjectPrototype(buf_obj, ab.prototype);
    }
    const buf_bytes = realm.allocator.alloc(u8, bytes_in.len) catch return error.OutOfMemory;
    if (bytes_in.len > 0) @memcpy(buf_bytes, bytes_in);
    buf_obj.setArrayBuffer(realm.allocator, buf_bytes) catch return error.OutOfMemory;
    buf_obj.brand.has_array_buffer_data = true;
    inst.setTypedView(realm.allocator, .{
        .kind = .uint8,
        .viewed = buf_obj,
        .byte_offset = 0,
        .length = bytes_in.len,
        .name = "Uint8Array",
    }) catch return error.OutOfMemory;
    return inst;
}

fn makeReadWrittenObject(realm: *Realm, read: usize, written: usize) NativeError!Value {
    const obj = realm.heap.allocateObject() catch return error.OutOfMemory;
    realm.heap.setObjectPrototype(obj, realm.intrinsics.object_prototype);
    const read_v = if (read <= std.math.maxInt(i32))
        Value.fromInt32(@as(i32, @intCast(read)))
    else
        Value.fromDouble(@floatFromInt(read));
    const written_v = if (written <= std.math.maxInt(i32))
        Value.fromInt32(@as(i32, @intCast(written)))
    else
        Value.fromDouble(@floatFromInt(written));
    obj.set(realm.allocator, "read", read_v) catch return error.OutOfMemory;
    obj.set(realm.allocator, "written", written_v) catch return error.OutOfMemory;
    return heap_mod.taggedObject(obj);
}

// ── Encoders for toBase64 / toHex ───────────────────────────────────

fn encodeBase64(bytes: []const u8, alphabet: Alphabet, omit_padding: bool, allocator: std.mem.Allocator) ![]u8 {
    const alpha = switch (alphabet) {
        .base64 => STD_ALPHA,
        .base64url => URL_ALPHA,
    };
    const full_triples = bytes.len / 3;
    const tail = bytes.len % 3;
    // Worst case: 4 chars per triple, plus up to 4 for the tail.
    const out_len: usize = blk: {
        if (tail == 0) break :blk full_triples * 4;
        if (omit_padding) break :blk full_triples * 4 + (if (tail == 1) @as(usize, 2) else 3);
        break :blk full_triples * 4 + 4;
    };
    const out = try allocator.alloc(u8, out_len);
    var oi: usize = 0;
    var i: usize = 0;
    while (i + 3 <= bytes.len) : (i += 3) {
        const b0 = bytes[i];
        const b1 = bytes[i + 1];
        const b2 = bytes[i + 2];
        out[oi + 0] = alpha[b0 >> 2];
        out[oi + 1] = alpha[((b0 & 0x03) << 4) | (b1 >> 4)];
        out[oi + 2] = alpha[((b1 & 0x0F) << 2) | (b2 >> 6)];
        out[oi + 3] = alpha[b2 & 0x3F];
        oi += 4;
    }
    if (tail == 1) {
        const b0 = bytes[i];
        out[oi + 0] = alpha[b0 >> 2];
        out[oi + 1] = alpha[(b0 & 0x03) << 4];
        oi += 2;
        if (!omit_padding) {
            out[oi + 0] = '=';
            out[oi + 1] = '=';
            oi += 2;
        }
    } else if (tail == 2) {
        const b0 = bytes[i];
        const b1 = bytes[i + 1];
        out[oi + 0] = alpha[b0 >> 2];
        out[oi + 1] = alpha[((b0 & 0x03) << 4) | (b1 >> 4)];
        out[oi + 2] = alpha[(b1 & 0x0F) << 2];
        oi += 3;
        if (!omit_padding) {
            out[oi] = '=';
            oi += 1;
        }
    }
    std.debug.assert(oi == out_len);
    return out;
}

fn encodeHex(bytes: []const u8, allocator: std.mem.Allocator) ![]u8 {
    const hex = "0123456789abcdef";
    const out = try allocator.alloc(u8, bytes.len * 2);
    for (bytes, 0..) |b, i| {
        out[i * 2 + 0] = hex[b >> 4];
        out[i * 2 + 1] = hex[b & 0x0F];
    }
    return out;
}

// ── Native function bodies ──────────────────────────────────────────

fn uint8FromBase64(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = this_value; // §uint8array.frombase64 — ignores receiver.
    // §sec-uint8array.frombase64 step 1 — `If Type(string) is not
    // String, throw a TypeError exception`. Check BEFORE any option
    // getters run (string-coercion.js).
    const input_v = argOr(args, 0, Value.undefined_);
    const input = try requireStringArg(realm, input_v, "Uint8Array.fromBase64");
    // step 2-3 — read options.
    const opts = argOr(args, 1, Value.undefined_);
    const alphabet = try readAlphabetOption(realm, opts);
    const last_chunk = try readLastChunkHandling(realm, opts);

    // Upper-bound output size: ceil(input_len * 3 / 4). Whitespace
    // and `=` will leave the buffer under-filled — we resize-by-copy
    // at the end before handing back the typed array.
    var scratch = std.array_list.Managed(u8).init(realm.allocator);
    defer scratch.deinit();
    const cap: usize = (input.len / 4 + 1) * 3 + 3;
    scratch.ensureTotalCapacity(cap) catch return error.OutOfMemory;
    scratch.items.len = cap;
    const r = fromBase64(input, scratch.items, alphabet, last_chunk);
    if (r.err) |kind| return syntaxErrorFor(realm, kind);
    const inst = try makeUint8ArrayFromBytes(realm, scratch.items[0..r.written]);
    return heap_mod.taggedObject(inst);
}

fn uint8FromHex(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = this_value;
    const input_v = argOr(args, 0, Value.undefined_);
    const input = try requireStringArg(realm, input_v, "Uint8Array.fromHex");
    // Allocate exact output size — input must be even-length to
    // succeed at all.
    if (input.len % 2 != 0) return throwSyntaxError(realm, "Uint8Array.fromHex: input has odd length");
    const out = realm.allocator.alloc(u8, input.len / 2) catch return error.OutOfMemory;
    defer realm.allocator.free(out);
    const r = fromHex(input, out);
    if (r.err) |kind| return hexSyntaxErrorFor(realm, kind);
    const inst = try makeUint8ArrayFromBytes(realm, out[0..r.written]);
    return heap_mod.taggedObject(inst);
}

fn uint8SetFromBase64(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    // Spec — brand-check before any other side effect.
    const receiver = try requireUint8ArrayReceiver(realm, this_value, "Uint8Array.prototype.setFromBase64");
    const input_v = argOr(args, 0, Value.undefined_);
    const input = try requireStringArg(realm, input_v, "Uint8Array.prototype.setFromBase64");
    const opts = argOr(args, 1, Value.undefined_);
    const alphabet = try readAlphabetOption(realm, opts);
    const last_chunk = try readLastChunkHandling(realm, opts);

    // Detached / OOB check fires *after* the option getters per
    // detached-buffer.js (the alphabet getter is observed even
    // when it detaches). The fetch is also what captures the
    // post-getter view of the buffer length — option getters
    // could resize the backing ArrayBuffer before we reach here.
    //
    // Decode into a scratch buffer first, then copy. We can't
    // decode straight into the target buffer because the spec
    // (writes-up-to-error.js) requires partial writes even on
    // error — those go in.
    const cur = liveUint8View(receiver) orelse
        return throwTypeError(realm, "Uint8Array.prototype.setFromBase64: detached buffer");
    var scratch = realm.allocator.alloc(u8, cur.bytes.len) catch return error.OutOfMemory;
    defer realm.allocator.free(scratch);
    const r = fromBase64(input, scratch[0..cur.bytes.len], alphabet, last_chunk);
    // Copy whatever was written (partial-on-error semantics).
    if (r.written > 0) @memcpy(cur.bytes[0..r.written], scratch[0..r.written]);
    if (r.err) |kind| return syntaxErrorFor(realm, kind);
    return try makeReadWrittenObject(realm, r.read, r.written);
}

fn uint8SetFromHex(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const receiver = try requireUint8ArrayReceiver(realm, this_value, "Uint8Array.prototype.setFromHex");
    const input_v = argOr(args, 0, Value.undefined_);
    const input = try requireStringArg(realm, input_v, "Uint8Array.prototype.setFromHex");

    const cur = liveUint8View(receiver) orelse
        return throwTypeError(realm, "Uint8Array.prototype.setFromHex: detached buffer");

    // Odd-length input is rejected before any byte is written.
    if (input.len % 2 != 0) {
        return throwSyntaxError(realm, "Uint8Array.prototype.setFromHex: input has odd length");
    }
    var scratch = realm.allocator.alloc(u8, cur.bytes.len) catch return error.OutOfMemory;
    defer realm.allocator.free(scratch);
    const r = fromHex(input, scratch[0..cur.bytes.len]);
    if (r.written > 0) @memcpy(cur.bytes[0..r.written], scratch[0..r.written]);
    if (r.err) |kind| return hexSyntaxErrorFor(realm, kind);
    return try makeReadWrittenObject(realm, r.read, r.written);
}

fn uint8ToBase64(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const receiver = try requireUint8ArrayReceiver(realm, this_value, "Uint8Array.prototype.toBase64");
    // Read options BEFORE the detached-buffer check, per
    // detached-buffer.js ("checks for detachedness after side-
    // effects are finished").
    const opts = argOr(args, 0, Value.undefined_);
    const alphabet = try readAlphabetOption(realm, opts);
    const omit_padding = try readOmitPadding(realm, opts);

    const live = liveUint8View(receiver) orelse
        return throwTypeError(realm, "Uint8Array.prototype.toBase64: detached buffer");

    const out = encodeBase64(live.bytes, alphabet, omit_padding, realm.allocator) catch return error.OutOfMemory;
    defer realm.allocator.free(out);
    const s = realm.heap.allocateString(out) catch return error.OutOfMemory;
    return Value.fromString(s);
}

fn uint8ToHex(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    const receiver = try requireUint8ArrayReceiver(realm, this_value, "Uint8Array.prototype.toHex");
    const live = liveUint8View(receiver) orelse
        return throwTypeError(realm, "Uint8Array.prototype.toHex: detached buffer");
    const out = encodeHex(live.bytes, realm.allocator) catch return error.OutOfMemory;
    defer realm.allocator.free(out);
    const s = realm.heap.allocateString(out) catch return error.OutOfMemory;
    return Value.fromString(s);
}
