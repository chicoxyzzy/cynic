//! §19.2.6 URI handling globals — extracted from
//! `intrinsics.zig`. `encodeURI` / `encodeURIComponent` /
//! `decodeURI` / `decodeURIComponent` are installed on
//! `globalThis` directly. Cynic targets non-browser hosts
//! where the legacy `escape` / `unescape` aren't useful, so
//! they're omitted by design.

const std = @import("std");

const Realm = @import("../realm.zig").Realm;
const Value = @import("../value.zig").Value;
const JSString = @import("../string.zig").JSString;
const JSObject = @import("../object.zig").JSObject;
const NativeError = @import("../function.zig").NativeError;
const heap_mod = @import("../heap.zig");
const intrinsics = @import("../intrinsics.zig");

const argOr = intrinsics.argOr;
const stringifyArg = intrinsics.stringifyArg;
const throwTypeError = intrinsics.throwTypeError;
const newURIError = intrinsics.newURIError;

pub fn install(realm: *Realm) !void {
    // §20.1.1 — none of these globals implement [[Construct]];
    // `new encodeURI(...)` etc. must throw TypeError.
    const eu = try realm.heap.allocateFunctionNative(globalEncodeURI, 1, "encodeURI");
    eu.has_construct = false;
    try realm.globals.put(realm.allocator, "encodeURI", heap_mod.taggedFunction(eu));
    const euc = try realm.heap.allocateFunctionNative(globalEncodeURIComponent, 1, "encodeURIComponent");
    euc.has_construct = false;
    try realm.globals.put(realm.allocator, "encodeURIComponent", heap_mod.taggedFunction(euc));
    const du = try realm.heap.allocateFunctionNative(globalDecodeURI, 1, "decodeURI");
    du.has_construct = false;
    try realm.globals.put(realm.allocator, "decodeURI", heap_mod.taggedFunction(du));
    const duc = try realm.heap.allocateFunctionNative(globalDecodeURIComponent, 1, "decodeURIComponent");
    duc.has_construct = false;
    try realm.globals.put(realm.allocator, "decodeURIComponent", heap_mod.taggedFunction(duc));
}

// ── §19.2 URI handling globals ──────────────────────────────────────────────

/// `unreserved` per RFC 3986: ALPHA / DIGIT / "-" / "_" / "."
/// / "~". URI-encoding leaves these alone.
fn isUnreservedURI(c: u8) bool {
    return (c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z') or
        (c >= '0' and c <= '9') or c == '-' or c == '_' or c == '.' or c == '~';
}

/// Reserved set for `encodeURI` (these stay un-encoded too;
/// they're URI-syntax-significant). `encodeURIComponent` escapes
/// these.
fn isUriReserved(c: u8) bool {
    return c == ';' or c == ',' or c == '/' or c == '?' or c == ':' or c == '@' or
        c == '&' or c == '=' or c == '+' or c == '$' or c == '#' or c == '!' or
        c == '*' or c == '\'' or c == '(' or c == ')';
}

fn encodeURIImpl(realm: *Realm, src: []const u8, full_uri: bool) NativeError!Value {
    // §19.2.6.5 Encode. Walk codepoints (Cynic strings are UTF-8;
    // an unpaired surrogate shows up as a single 3-byte 0xED 0xAX/BX
    // 0x8X sequence — invalid UTF-8 in std.unicode but a valid JS
    // code point in CESU-8 form). For each code point:
    // • ASCII char in `unescapedSet` → pass through.
    // • Unpaired surrogate → URIError per step 6.b.
    // • Anything else → emit one %XX per UTF-8 byte.
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(realm.allocator);
    const hex = "0123456789ABCDEF";
    var i: usize = 0;
    while (i < src.len) {
        const b0 = src[i];
        // ASCII (high bit clear) — single byte.
        if (b0 < 0x80) {
            if (isUnreservedURI(b0) or (full_uri and isUriReserved(b0))) {
                out.append(realm.allocator, b0) catch return error.OutOfMemory;
            } else {
                out.append(realm.allocator, '%') catch return error.OutOfMemory;
                out.append(realm.allocator, hex[b0 >> 4]) catch return error.OutOfMemory;
                out.append(realm.allocator, hex[b0 & 0x0F]) catch return error.OutOfMemory;
            }
            i += 1;
            continue;
        }
        // Multi-byte UTF-8 leader.
        const seq_len: usize = if (b0 & 0b1110_0000 == 0b1100_0000)
            2
        else if (b0 & 0b1111_0000 == 0b1110_0000)
            3
        else if (b0 & 0b1111_1000 == 0b1111_0000)
            4
        else
            return throwURIMalformed(realm);
        if (i + seq_len > src.len) return throwURIMalformed(realm);
        // Decode the codepoint.
        var cp: u32 = switch (seq_len) {
            2 => @as(u32, b0 & 0x1F),
            3 => @as(u32, b0 & 0x0F),
            4 => @as(u32, b0 & 0x07),
            else => unreachable,
        };
        var j: usize = 1;
        while (j < seq_len) : (j += 1) {
            const cb = src[i + j];
            if (cb & 0b1100_0000 != 0b1000_0000) return throwURIMalformed(realm);
            cp = (cp << 6) | (cb & 0x3F);
        }
        // §19.2.6.5 step 6.b — unpaired surrogate is a URIError.
        // (Cynic doesn't yet pair surrogates back into supplementary
        // codepoints at parse time, so any 3-byte D800-DFFF here is
        // by definition unpaired.)
        if (cp >= 0xD800 and cp <= 0xDFFF) return throwURIMalformed(realm);
        // Emit one %XX per UTF-8 byte.
        var k: usize = 0;
        while (k < seq_len) : (k += 1) {
            const b = src[i + k];
            out.append(realm.allocator, '%') catch return error.OutOfMemory;
            out.append(realm.allocator, hex[b >> 4]) catch return error.OutOfMemory;
            out.append(realm.allocator, hex[b & 0x0F]) catch return error.OutOfMemory;
        }
        i += seq_len;
    }
    const s = realm.heap.allocateString(out.items) catch return error.OutOfMemory;
    return Value.fromString(s);
}

fn throwURIMalformed(realm: *Realm) NativeError {
    const ex = makeURIError(realm, "URI malformed") catch return error.OutOfMemory;
    realm.pending_exception = ex;
    return error.NativeThrew;
}

/// §19.2.6.4 Decode — read the next %HH escape at `i`, returning
/// the decoded byte. Throws URIError on truncation / non-hex.
fn readPercentEscape(realm: *Realm, src: []const u8, i: usize) NativeError!u8 {
    if (i + 2 >= src.len) return throwURIMalformed(realm);
    const hi = hexDigit(src[i + 1]) orelse return throwURIMalformed(realm);
    const lo = hexDigit(src[i + 2]) orelse return throwURIMalformed(realm);
    return (hi << 4) | lo;
}

fn decodeURIImpl(realm: *Realm, src: []const u8, full_uri: bool) NativeError!Value {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(realm.allocator);
    var i: usize = 0;
    while (i < src.len) {
        const c = src[i];
        if (c != '%') {
            out.append(realm.allocator, c) catch return error.OutOfMemory;
            i += 1;
            continue;
        }
        const decoded = try readPercentEscape(realm, src, i);
        // §19.2.6.4 step 4.d: ASCII bytes (high bit clear) decode
        // directly. For `decodeURI`, the reserved set + `#`
        // survives in its %XX form so round-tripping doesn't lose
        // delimiters.
        if (decoded < 0x80) {
            if (full_uri and (isUriReserved(decoded) or decoded == '#')) {
                out.append(realm.allocator, '%') catch return error.OutOfMemory;
                out.append(realm.allocator, src[i + 1]) catch return error.OutOfMemory;
                out.append(realm.allocator, src[i + 2]) catch return error.OutOfMemory;
            } else {
                out.append(realm.allocator, decoded) catch return error.OutOfMemory;
            }
            i += 3;
            continue;
        }
        // §19.2.6.4 step 4.e–4.l: high bit set → leading byte of
        // a UTF-8 multi-byte sequence. Determine the length from
        // the leading 1-bits, then read that many %HH escapes,
        // each with the 10xxxxxx continuation pattern.
        const seq_len: usize = if (decoded & 0b1110_0000 == 0b1100_0000)
            2
        else if (decoded & 0b1111_0000 == 0b1110_0000)
            3
        else if (decoded & 0b1111_1000 == 0b1111_0000)
            4
        else
            return throwURIMalformed(realm);
        var bytes: [4]u8 = undefined;
        bytes[0] = decoded;
        var j: usize = 1;
        var k: usize = i + 3;
        while (j < seq_len) : (j += 1) {
            if (k >= src.len or src[k] != '%') return throwURIMalformed(realm);
            const cont = try readPercentEscape(realm, src, k);
            if (cont & 0b1100_0000 != 0b1000_0000) return throwURIMalformed(realm);
            bytes[j] = cont;
            k += 3;
        }
        // Verify the assembled bytes form a valid scalar (catches
        // overlongs, surrogates U+D800..U+DFFF, and codepoints
        // beyond U+10FFFF).
        if (!std.unicode.utf8ValidateSlice(bytes[0..seq_len])) return throwURIMalformed(realm);
        out.appendSlice(realm.allocator, bytes[0..seq_len]) catch return error.OutOfMemory;
        i = k;
    }
    const s = realm.heap.allocateString(out.items) catch return error.OutOfMemory;
    return Value.fromString(s);
}

fn hexDigit(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

fn makeURIError(realm: *Realm, msg: []const u8) !Value {
    return newURIError(realm, msg);
}

fn globalEncodeURI(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = this_value;
    const s = try stringifyArg(realm, argOr(args, 0, Value.undefined_));
    return encodeURIImpl(realm, s.bytes, true);
}
fn globalEncodeURIComponent(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = this_value;
    const s = try stringifyArg(realm, argOr(args, 0, Value.undefined_));
    return encodeURIImpl(realm, s.bytes, false);
}
fn globalDecodeURI(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = this_value;
    const s = try stringifyArg(realm, argOr(args, 0, Value.undefined_));
    return decodeURIImpl(realm, s.bytes, true);
}
fn globalDecodeURIComponent(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = this_value;
    const s = try stringifyArg(realm, argOr(args, 0, Value.undefined_));
    return decodeURIImpl(realm, s.bytes, false);
}
