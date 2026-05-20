//! UTF-16 code-unit views over Cynic's WTF-8 byte storage.
//!
//! ECMA-262 §6.1.4 defines the String type as "the set of all
//! ordered sequences of zero or more 16-bit unsigned integer
//! values" — every position-aware `String.prototype` method
//! (charAt, slice, indexOf, …) indexes those 16-bit units, not
//! the underlying bytes. Cynic stores strings as WTF-8 (UTF-8 +
//! 3-byte CESU-8 lone-surrogate escapes); this module bridges the
//! two views.
//!
//! Mapping:
//! - A 1/2/3-byte WTF-8 sequence ⇒ exactly 1 UTF-16 code unit
//!   (BMP scalar or lone surrogate D800-DFFF).
//! - A 4-byte UTF-8 sequence (supplementary code point) ⇒ 2
//!   UTF-16 code units (a high+low surrogate pair). The lead
//!   surrogate sits at unit index `i`, the trail at `i+1`; both
//!   point at the *same* 4-byte WTF-8 sequence in the storage.
//!
//! Used by `String.prototype.{length,charAt,charCodeAt,at,slice,
//! substring,indexOf,lastIndexOf,startsWith,endsWith,includes,
//! padStart,padEnd}` (and prior art in
//! `string.prototype.codePointAt` / `isWellFormed` /
//! `toWellFormed`). Functions on byte slices for parity with the
//! existing builtins surface; callers in `builtins/string.zig`
//! pass `JSString.bytes` directly.

const std = @import("std");

/// UTF-8 leading-byte → byte-sequence length (1..4). Returns 1
/// for bytes that don't start a valid lead so callers always
/// make progress on malformed input. Mirrors the helper of the
/// same name in `builtins/string.zig` (kept duplicated so this
/// module is self-contained at unit-test time).
pub fn utf8SeqLen(b: u8) usize {
    if (b < 0x80) return 1;
    if (b < 0xC0) return 1;
    if (b < 0xE0) return 2;
    if (b < 0xF0) return 3;
    return 4;
}

/// Count UTF-16 code units in the WTF-8 byte slice. §6.1.4 — a
/// String value's `length` is the number of code units. Used by
/// the `length` property of String primitives and the wrapper
/// objects allocated via `ToObject(string)`.
pub fn lengthInCodeUnits(bytes: []const u8) usize {
    var units: usize = 0;
    var i: usize = 0;
    while (i < bytes.len) {
        const seq_len = utf8SeqLen(bytes[i]);
        units += if (seq_len == 4) 2 else 1;
        i += seq_len;
        // Guard against a malformed lead byte that would
        // otherwise step past the end of the slice.
        if (i > bytes.len) break;
    }
    return units;
}

/// Return the UTF-16 code-unit offset that corresponds to byte
/// offset `byte_idx`. The byte offset must land on a leading
/// byte of a WTF-8 sequence (i.e. an offset previously
/// produced by `byteIndexForCodeUnit` or `std.mem.indexOf` over
/// the bytes); otherwise the result counts to the nearest
/// preceding leading byte. Used by `indexOf` / `lastIndexOf` to
/// translate a byte-level `std.mem.indexOf` hit back to the
/// spec's code-unit index.
pub fn codeUnitIndexForByte(bytes: []const u8, byte_idx: usize) usize {
    var units: usize = 0;
    var i: usize = 0;
    while (i < bytes.len and i < byte_idx) {
        const seq_len = utf8SeqLen(bytes[i]);
        units += if (seq_len == 4) 2 else 1;
        i += seq_len;
    }
    return units;
}

/// Return the byte offset where UTF-16 code unit `cu_idx` starts.
///
/// For a 4-byte UTF-8 sequence at code-unit positions `(i, i+1)`,
/// both `byteIndexForCodeUnit(bytes, i)` and `(bytes, i+1)` return
/// the byte offset of the *4-byte sequence itself* — callers
/// distinguish "lead vs trail" via the unit count consumed so far.
/// (`charCodeAt` / `codePointAt` walk a parallel `(byte_pos,
/// unit_pos)` cursor to make that distinction directly.)
///
/// Returns `null` when `cu_idx` is past the last code unit
/// (callers translate that to the spec's "out of range").
pub fn byteIndexForCodeUnit(bytes: []const u8, cu_idx: usize) ?usize {
    var byte_pos: usize = 0;
    var unit_pos: usize = 0;
    while (byte_pos < bytes.len) {
        if (unit_pos == cu_idx) return byte_pos;
        const seq_len = utf8SeqLen(bytes[byte_pos]);
        const units_here: usize = if (seq_len == 4) 2 else 1;
        if (cu_idx == unit_pos + 1 and units_here == 2) {
            // Trail surrogate of a supplementary pair — the
            // 4-byte sequence still starts at byte_pos.
            return byte_pos;
        }
        byte_pos += seq_len;
        unit_pos += units_here;
    }
    if (unit_pos == cu_idx) return byte_pos; // end-position (one past).
    return null;
}

/// Return the UTF-16 code unit value at index `cu_idx`, or null if
/// the index is past the last unit. Mirrors §22.1.3.2
/// String.prototype.charCodeAt's "code unit at position" read.
pub fn codeUnitAt(bytes: []const u8, cu_idx: usize) ?u16 {
    var byte_pos: usize = 0;
    var unit_pos: usize = 0;
    while (byte_pos < bytes.len) {
        const seq_len = utf8SeqLen(bytes[byte_pos]);
        if (byte_pos + seq_len > bytes.len) return null;
        if (seq_len == 4) {
            // Supplementary code point — decode and emit a
            // surrogate half.
            const cp = std.unicode.utf8Decode(bytes[byte_pos .. byte_pos + 4]) catch return null;
            const adjusted: u32 = @as(u32, @intCast(cp)) - 0x10000;
            if (unit_pos == cu_idx) {
                const lead: u16 = @intCast(0xD800 + (adjusted >> 10));
                return lead;
            }
            if (unit_pos + 1 == cu_idx) {
                const trail: u16 = @intCast(0xDC00 + (adjusted & 0x3FF));
                return trail;
            }
            byte_pos += 4;
            unit_pos += 2;
        } else {
            if (unit_pos == cu_idx) {
                return decodeBmpUnit(bytes[byte_pos .. byte_pos + seq_len]);
            }
            byte_pos += seq_len;
            unit_pos += 1;
        }
    }
    return null;
}

/// Decode a 1/2/3-byte WTF-8 sequence into a single UTF-16 code
/// unit. Returns null on malformed input. 3-byte sequences whose
/// codepoint is in 0xD800..0xDFFF round-trip as the lone surrogate
/// (Cynic's WTF-8 storage). Kept private — callers route through
/// `codeUnitAt`.
fn decodeBmpUnit(bytes: []const u8) ?u16 {
    if (bytes.len == 0) return null;
    const b0 = bytes[0];
    if (b0 < 0x80) return @intCast(b0);
    if (bytes.len == 2) {
        return (@as(u16, b0 & 0x1F) << 6) | @as(u16, bytes[1] & 0x3F);
    }
    if (bytes.len == 3) {
        return (@as(u16, b0 & 0x0F) << 12) | (@as(u16, bytes[1] & 0x3F) << 6) | @as(u16, bytes[2] & 0x3F);
    }
    return null;
}

/// Result of `sliceCodeUnits` — caller-borrowed view into the
/// source bytes, plus an optional surrogate half that the caller
/// must prepend/append to preserve a code-unit-precise slice
/// across a supplementary code point. `head_surrogate` is set when
/// `start_cu` landed mid-sequence (on the trail half of a 4-byte
/// run): the slice's first logical code unit is a lone trail
/// surrogate that has to be encoded as a 3-byte WTF-8 sequence.
/// `tail_surrogate` is set symmetrically when `end_cu` landed on
/// the lead half. When both halves are zero the byte slice is
/// already a complete code-unit slice.
pub const Slice = struct {
    bytes: []const u8,
    /// Lone trail surrogate to prepend (D800..DFFF) when nonzero.
    head_surrogate: u16,
    /// Lone lead surrogate to append (D800..DFFF) when nonzero.
    tail_surrogate: u16,
};

/// Return the byte sub-slice covering UTF-16 code units
/// `[start_cu, end_cu)`. Out-of-range indices clamp to
/// `lengthInCodeUnits(bytes)`. If `end_cu <= start_cu` the result
/// is the empty slice (any positions are clamped to that).
///
/// Edge case — if `start_cu` or `end_cu` falls between the lead
/// and trail of a supplementary code point's 4-byte UTF-8
/// sequence, the corresponding surrogate half is reported in
/// `head_surrogate` / `tail_surrogate` so the caller can append a
/// 3-byte WTF-8 sequence for it. The 4-byte sequence itself is
/// excluded from `bytes` in that case (it's whichever half is
/// outside the requested range, the surrogate's mate is encoded as
/// the 3-byte CESU-8 escape).
pub fn sliceCodeUnits(bytes: []const u8, start_cu: usize, end_cu: usize) Slice {
    if (end_cu <= start_cu) return .{ .bytes = bytes[0..0], .head_surrogate = 0, .tail_surrogate = 0 };

    var byte_pos: usize = 0;
    var unit_pos: usize = 0;
    var start_byte: usize = bytes.len;
    var end_byte: usize = bytes.len;
    var head_surr: u16 = 0;
    var tail_surr: u16 = 0;
    var start_done = false;
    var end_done = false;

    while (byte_pos < bytes.len) {
        if (!start_done and unit_pos == start_cu) {
            start_byte = byte_pos;
            start_done = true;
        }
        if (!end_done and unit_pos == end_cu) {
            end_byte = byte_pos;
            end_done = true;
            break;
        }
        const seq_len = utf8SeqLen(bytes[byte_pos]);
        if (byte_pos + seq_len > bytes.len) break;

        if (seq_len == 4) {
            // Astral codepoint occupies 2 UTF-16 units.
            // Decode once so we can produce surrogate halves on
            // demand when start_cu/end_cu lands mid-pair.
            if (!start_done and unit_pos + 1 == start_cu) {
                // Skip the lead surrogate; the trail surrogate
                // becomes the slice's first code unit. Encode it
                // as a 3-byte WTF-8 escape.
                const cp = std.unicode.utf8Decode(bytes[byte_pos .. byte_pos + 4]) catch unreachable;
                const adjusted: u32 = @as(u32, @intCast(cp)) - 0x10000;
                head_surr = @intCast(0xDC00 + (adjusted & 0x3FF));
                start_byte = byte_pos + 4;
                start_done = true;
            }
            if (!end_done and unit_pos + 1 == end_cu) {
                // Include the lead surrogate (and not the trail).
                // The 4-byte sequence itself stays out of the
                // byte range; the lead is emitted as a 3-byte
                // escape in `tail_surrogate`.
                const cp = std.unicode.utf8Decode(bytes[byte_pos .. byte_pos + 4]) catch unreachable;
                const adjusted: u32 = @as(u32, @intCast(cp)) - 0x10000;
                tail_surr = @intCast(0xD800 + (adjusted >> 10));
                end_byte = byte_pos;
                end_done = true;
                break;
            }
            byte_pos += 4;
            unit_pos += 2;
        } else {
            byte_pos += seq_len;
            unit_pos += 1;
        }
    }
    if (!start_done) {
        // Walked past the end without finding start — clamp to
        // the end of the buffer, empty result.
        return .{ .bytes = bytes[bytes.len..bytes.len], .head_surrogate = 0, .tail_surrogate = 0 };
    }
    if (!end_done) {
        end_byte = bytes.len;
    }
    if (end_byte < start_byte) end_byte = start_byte;
    return .{
        .bytes = bytes[start_byte..end_byte],
        .head_surrogate = head_surr,
        .tail_surrogate = tail_surr,
    };
}

/// Append a single UTF-16 code unit to `out` as WTF-8. BMP
/// scalars and lone surrogates fit in 1-3 bytes. The encoding
/// matches Cynic's storage convention used by
/// `String.fromCharCode` and the iterator-yield path. Used by
/// `sliceCodeUnits` callers to materialize the head/tail
/// surrogate escapes.
pub fn appendCodeUnitAsWtf8(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), cu: u16) !void {
    if (cu < 0x80) {
        try out.append(allocator, @intCast(cu));
    } else if (cu < 0x800) {
        try out.append(allocator, @intCast(0xC0 | (cu >> 6)));
        try out.append(allocator, @intCast(0x80 | (cu & 0x3F)));
    } else {
        try out.append(allocator, @intCast(0xE0 | (cu >> 12)));
        try out.append(allocator, @intCast(0x80 | ((cu >> 6) & 0x3F)));
        try out.append(allocator, @intCast(0x80 | (cu & 0x3F)));
    }
}

/// True when WTF-8 slice `s` ends with a 3-byte CESU-8 escape for a
/// lone *high* surrogate (U+D800..U+DBFF): bytes `ED A0..AF 8x`.
fn endsWithHighSurrogate(s: []const u8) bool {
    if (s.len < 3) return false;
    const t = s[s.len - 3 ..];
    return t[0] == 0xED and t[1] >= 0xA0 and t[1] <= 0xAF;
}

/// True when WTF-8 slice `s` starts with a 3-byte CESU-8 escape for
/// a lone *low* surrogate (U+DC00..U+DFFF): bytes `ED B0..BF 8x`.
fn startsWithLowSurrogate(s: []const u8) bool {
    if (s.len < 3) return false;
    return s[0] == 0xED and s[1] >= 0xB0 and s[1] <= 0xBF;
}

/// Whether concatenating WTF-8 `a ++ b` pairs a lone high surrogate
/// at the end of `a` with a lone low surrogate at the start of `b`.
/// Cynic's WTF-8 storage invariant (AGENTS.md §6.1.4) requires a
/// *valid* surrogate pair to be the single 4-byte UTF-8 form, never
/// two adjacent 3-byte CESU-8 escapes — so a plain byte-wise concat
/// is wrong exactly in this case and the seam must be merged.
pub fn wtf8ConcatSeamPairs(a: []const u8, b: []const u8) bool {
    return endsWithHighSurrogate(a) and startsWithLowSurrogate(b);
}

/// Byte length of the well-formed WTF-8 concatenation `a ++ b`.
/// Equal to `a.len + b.len`, minus 2 when the seam pairs (the two
/// 3-byte CESU-8 escapes — 6 bytes — collapse to one 4-byte form).
pub fn wtf8ConcatLen(a: []const u8, b: []const u8) usize {
    return if (wtf8ConcatSeamPairs(a, b)) a.len + b.len - 2 else a.len + b.len;
}

/// Write the well-formed WTF-8 concatenation of `a` and `b` into
/// `dst`, merging a paired surrogate seam (§6.1.4) into the 4-byte
/// supplementary form. `dst.len` must equal `wtf8ConcatLen(a, b)`.
pub fn wtf8ConcatInto(dst: []u8, a: []const u8, b: []const u8) void {
    if (!wtf8ConcatSeamPairs(a, b)) {
        @memcpy(dst[0..a.len], a);
        @memcpy(dst[a.len..], b);
        return;
    }
    // Decode the two halves out of their 3-byte CESU-8 escapes and
    // re-encode the supplementary code point as one 4-byte sequence.
    const hi: u21 = decodeBmpUnit(a[a.len - 3 ..]) orelse unreachable;
    const lo: u21 = decodeBmpUnit(b[0..3]) orelse unreachable;
    const cp: u21 = 0x10000 + ((hi - 0xD800) << 10) + (lo - 0xDC00);
    const head = a.len - 3;
    @memcpy(dst[0..head], a[0..head]);
    dst[head + 0] = @intCast(0xF0 | (cp >> 18));
    dst[head + 1] = @intCast(0x80 | ((cp >> 12) & 0x3F));
    dst[head + 2] = @intCast(0x80 | ((cp >> 6) & 0x3F));
    dst[head + 3] = @intCast(0x80 | (cp & 0x3F));
    @memcpy(dst[head + 4 ..], b[3..]);
}

/// §7.2.13 IsLessThan / §22.1.3.10 String.prototype.localeCompare
/// abstract lexicographic comparison of two String values. The
/// spec compares by UTF-16 code-unit *integer values*; WTF-8 byte
/// ordering diverges as soon as a supplementary code point is
/// involved (4-byte UTF-8 starts with 0xF0..0xF4 which sorts
/// *after* 3-byte BMP 0xE0..0xEF, but the surrogate pair 0xD800..
/// 0xDFFF sorts *before* 0xE000..0xFFFF in code-unit order). This
/// helper walks both strings in lockstep emitting the next UTF-16
/// code unit (1 unit per 1/2/3-byte sequence, 2 units per 4-byte
/// sequence — lead then trail surrogate) and returns the first
/// position they differ. Empty / shorter prefix sorts less than a
/// longer string with the same prefix.
pub fn compareCodeUnits(a: []const u8, b: []const u8) std.math.Order {
    var ai: usize = 0;
    var bi: usize = 0;
    // Pending trail surrogate for either side when the previous
    // step emitted the lead half of a supplementary pair.
    var a_pending: ?u16 = null;
    var b_pending: ?u16 = null;
    while (true) {
        const a_unit = nextCodeUnit(a, &ai, &a_pending);
        const b_unit = nextCodeUnit(b, &bi, &b_pending);
        if (a_unit == null and b_unit == null) return .eq;
        if (a_unit == null) return .lt;
        if (b_unit == null) return .gt;
        if (a_unit.? < b_unit.?) return .lt;
        if (a_unit.? > b_unit.?) return .gt;
    }
}

fn nextCodeUnit(bytes: []const u8, idx: *usize, pending: *?u16) ?u16 {
    if (pending.*) |trail| {
        pending.* = null;
        return trail;
    }
    if (idx.* >= bytes.len) return null;
    const seq_len = utf8SeqLen(bytes[idx.*]);
    if (idx.* + seq_len > bytes.len) {
        // Malformed tail — emit the raw byte and advance one.
        const raw: u16 = bytes[idx.*];
        idx.* += 1;
        return raw;
    }
    if (seq_len == 4) {
        const cp = std.unicode.utf8Decode(bytes[idx.* .. idx.* + 4]) catch {
            const raw: u16 = bytes[idx.*];
            idx.* += 1;
            return raw;
        };
        idx.* += 4;
        const adjusted: u32 = @as(u32, @intCast(cp)) - 0x10000;
        const lead: u16 = @intCast(0xD800 + (adjusted >> 10));
        const trail: u16 = @intCast(0xDC00 + (adjusted & 0x3FF));
        pending.* = trail;
        return lead;
    }
    const unit = decodeBmpUnit(bytes[idx.* .. idx.* + seq_len]) orelse blk: {
        const raw: u16 = bytes[idx.*];
        break :blk raw;
    };
    idx.* += seq_len;
    return unit;
}

// ---------------------------------------------------------------------------
// Tests — focused on the (ASCII, BMP non-ASCII, supplementary, lone
// surrogate) coverage matrix required by the work item.
// ---------------------------------------------------------------------------

const testing = std.testing;

// Sample inputs used across tests.
//
// `"abc"`                 — pure ASCII, 3 code units, 3 bytes.
// `"aÿc"`            — BMP non-ASCII, 3 code units, 4 bytes.
// `"a\u{1F600}c"`         — supplementary code point (U+1F600 grinning face),
//                           4 code units (1 + 2 + 1), 6 bytes (1 + 4 + 1).
// `"a\uD83Dc"`            — lone high surrogate, 3 code units, 5 bytes
//                           (1 + 3 + 1) under WTF-8.

const ascii_bytes = "abc";
const bmp_bytes = "a\xC3\xBFc"; // U+00FF
const astral_bytes = "a\xF0\x9F\x98\x80c"; // U+1F600
const lone_high_bytes = "a\xED\xA0\xBDc"; // U+D83D as lone surrogate

test "utf16: lengthInCodeUnits — ASCII" {
    try testing.expectEqual(@as(usize, 3), lengthInCodeUnits(ascii_bytes));
}

test "utf16: lengthInCodeUnits — BMP non-ASCII counts as one unit" {
    try testing.expectEqual(@as(usize, 3), lengthInCodeUnits(bmp_bytes));
}

test "utf16: lengthInCodeUnits — supplementary counts as two units" {
    try testing.expectEqual(@as(usize, 4), lengthInCodeUnits(astral_bytes));
}

test "utf16: lengthInCodeUnits — lone surrogate is one unit" {
    try testing.expectEqual(@as(usize, 3), lengthInCodeUnits(lone_high_bytes));
}

test "utf16: codeUnitAt — ASCII indices" {
    try testing.expectEqual(@as(u16, 'a'), codeUnitAt(ascii_bytes, 0).?);
    try testing.expectEqual(@as(u16, 'b'), codeUnitAt(ascii_bytes, 1).?);
    try testing.expectEqual(@as(u16, 'c'), codeUnitAt(ascii_bytes, 2).?);
    try testing.expect(codeUnitAt(ascii_bytes, 3) == null);
}

test "utf16: codeUnitAt — BMP non-ASCII" {
    try testing.expectEqual(@as(u16, 'a'), codeUnitAt(bmp_bytes, 0).?);
    try testing.expectEqual(@as(u16, 0x00FF), codeUnitAt(bmp_bytes, 1).?);
    try testing.expectEqual(@as(u16, 'c'), codeUnitAt(bmp_bytes, 2).?);
}

test "utf16: codeUnitAt — supplementary yields surrogate halves" {
    try testing.expectEqual(@as(u16, 'a'), codeUnitAt(astral_bytes, 0).?);
    try testing.expectEqual(@as(u16, 0xD83D), codeUnitAt(astral_bytes, 1).?);
    try testing.expectEqual(@as(u16, 0xDE00), codeUnitAt(astral_bytes, 2).?);
    try testing.expectEqual(@as(u16, 'c'), codeUnitAt(astral_bytes, 3).?);
    try testing.expect(codeUnitAt(astral_bytes, 4) == null);
}

test "utf16: codeUnitAt — lone surrogate round-trips" {
    try testing.expectEqual(@as(u16, 0xD83D), codeUnitAt(lone_high_bytes, 1).?);
}

test "utf16: byteIndexForCodeUnit — ASCII is identity" {
    try testing.expectEqual(@as(usize, 0), byteIndexForCodeUnit(ascii_bytes, 0).?);
    try testing.expectEqual(@as(usize, 2), byteIndexForCodeUnit(ascii_bytes, 2).?);
    try testing.expectEqual(@as(usize, 3), byteIndexForCodeUnit(ascii_bytes, 3).?);
}

test "utf16: codeUnitIndexForByte — inverse of byteIndexForCodeUnit" {
    // byte 0 → unit 0; byte 1 (start of 4-byte) → unit 1;
    // byte 5 (after astral) → unit 3 (one BMP + supplementary pair).
    try testing.expectEqual(@as(usize, 0), codeUnitIndexForByte(astral_bytes, 0));
    try testing.expectEqual(@as(usize, 1), codeUnitIndexForByte(astral_bytes, 1));
    try testing.expectEqual(@as(usize, 3), codeUnitIndexForByte(astral_bytes, 5));
    try testing.expectEqual(@as(usize, 4), codeUnitIndexForByte(astral_bytes, 6));
}

test "utf16: byteIndexForCodeUnit — supplementary trail returns same start" {
    // unit 1 (lead) and unit 2 (trail) both point at the same 4-byte sequence
    // starting at byte offset 1.
    try testing.expectEqual(@as(usize, 1), byteIndexForCodeUnit(astral_bytes, 1).?);
    try testing.expectEqual(@as(usize, 1), byteIndexForCodeUnit(astral_bytes, 2).?);
    try testing.expectEqual(@as(usize, 5), byteIndexForCodeUnit(astral_bytes, 3).?);
}

test "utf16: sliceCodeUnits — ASCII whole range" {
    const r = sliceCodeUnits(ascii_bytes, 0, 3);
    try testing.expectEqualStrings("abc", r.bytes);
    try testing.expectEqual(@as(u16, 0), r.head_surrogate);
    try testing.expectEqual(@as(u16, 0), r.tail_surrogate);
}

test "utf16: sliceCodeUnits — supplementary, full pair included" {
    // codeUnits [0..4) = the entire astral string. The 4-byte
    // sequence sits between unit positions 1 and 2; both endpoints
    // of [0..4) are on code-unit boundaries so no surrogate halves.
    const r = sliceCodeUnits(astral_bytes, 0, 4);
    try testing.expectEqualStrings("a\xF0\x9F\x98\x80c", r.bytes);
    try testing.expectEqual(@as(u16, 0), r.head_surrogate);
    try testing.expectEqual(@as(u16, 0), r.tail_surrogate);
}

test "utf16: sliceCodeUnits — start mid-supplementary emits trail" {
    // start_cu=2 is the trail surrogate of U+1F600. The 4-byte
    // sequence is dropped; the trail surrogate is reported via
    // head_surrogate (caller encodes as 3-byte WTF-8 = U+DE00).
    const r = sliceCodeUnits(astral_bytes, 2, 4);
    try testing.expectEqualStrings("c", r.bytes);
    try testing.expectEqual(@as(u16, 0xDE00), r.head_surrogate);
    try testing.expectEqual(@as(u16, 0), r.tail_surrogate);
}

test "utf16: sliceCodeUnits — end mid-supplementary emits lead" {
    // end_cu=2 lands on the trail surrogate; the lead surrogate
    // (last unit included) becomes the tail_surrogate hint.
    const r = sliceCodeUnits(astral_bytes, 0, 2);
    try testing.expectEqualStrings("a", r.bytes);
    try testing.expectEqual(@as(u16, 0), r.head_surrogate);
    try testing.expectEqual(@as(u16, 0xD83D), r.tail_surrogate);
}

test "utf16: sliceCodeUnits — empty range yields empty" {
    const r = sliceCodeUnits(astral_bytes, 1, 1);
    try testing.expectEqual(@as(usize, 0), r.bytes.len);
    try testing.expectEqual(@as(u16, 0), r.head_surrogate);
    try testing.expectEqual(@as(u16, 0), r.tail_surrogate);
}

test "utf16: sliceCodeUnits — lone surrogate preserved" {
    const r = sliceCodeUnits(lone_high_bytes, 0, 3);
    try testing.expectEqualStrings(lone_high_bytes, r.bytes);
    try testing.expectEqual(@as(u16, 0), r.head_surrogate);
    try testing.expectEqual(@as(u16, 0), r.tail_surrogate);
}

test "utf16: appendCodeUnitAsWtf8 — ASCII single byte" {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(testing.allocator);
    try appendCodeUnitAsWtf8(testing.allocator, &buf, 'A');
    try testing.expectEqualStrings("A", buf.items);
}

test "utf16: appendCodeUnitAsWtf8 — lone trail surrogate is 3-byte WTF-8" {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(testing.allocator);
    try appendCodeUnitAsWtf8(testing.allocator, &buf, 0xDC00);
    try testing.expectEqualSlices(u8, &[_]u8{ 0xED, 0xB0, 0x80 }, buf.items);
}

// WTF-8 concat-seam merge (§6.1.4). U+D800 lone high = `ED A0 80`;
// U+DC00 lone low = `ED B0 80`; the pair is the supplementary
// U+10000, whose 4-byte UTF-8 form is `F0 90 80 80`.
const lone_high_d800 = [_]u8{ 0xED, 0xA0, 0x80 };
const lone_low_dc00 = [_]u8{ 0xED, 0xB0, 0x80 };
const supp_10000 = [_]u8{ 0xF0, 0x90, 0x80, 0x80 };

test "utf16: wtf8ConcatSeamPairs — high+low seam pairs" {
    try testing.expect(wtf8ConcatSeamPairs(&lone_high_d800, &lone_low_dc00));
}

test "utf16: wtf8ConcatSeamPairs — clean seams do not pair" {
    try testing.expect(!wtf8ConcatSeamPairs("abc", "def"));
    // high + non-low
    try testing.expect(!wtf8ConcatSeamPairs(&lone_high_d800, &lone_high_d800));
    // non-high + low
    try testing.expect(!wtf8ConcatSeamPairs(&lone_low_dc00, &lone_low_dc00));
    // empty operands
    try testing.expect(!wtf8ConcatSeamPairs("", &lone_low_dc00));
    try testing.expect(!wtf8ConcatSeamPairs(&lone_high_d800, ""));
}

test "utf16: wtf8ConcatLen — paired seam collapses 6 bytes to 4" {
    try testing.expectEqual(@as(usize, 4), wtf8ConcatLen(&lone_high_d800, &lone_low_dc00));
    try testing.expectEqual(@as(usize, 6), wtf8ConcatLen("abc", "def"));
}

test "utf16: wtf8ConcatInto — paired seam merges to the 4-byte form" {
    var dst: [4]u8 = undefined;
    wtf8ConcatInto(&dst, &lone_high_d800, &lone_low_dc00);
    try testing.expectEqualSlices(u8, &supp_10000, &dst);
}

test "utf16: wtf8ConcatInto — paired seam with surrounding text" {
    const a = "x" ++ lone_high_d800;
    const b = lone_low_dc00 ++ "y";
    var dst: [@as(usize, 8)]u8 = undefined; // 1 + 4 + 1 = 6 used
    const used = dst[0..wtf8ConcatLen(a, b)];
    wtf8ConcatInto(used, a, b);
    try testing.expectEqualSlices(u8, "x" ++ supp_10000 ++ "y", used);
}

test "utf16: wtf8ConcatInto — clean seam is a plain join" {
    var dst: [6]u8 = undefined;
    wtf8ConcatInto(&dst, "abc", "def");
    try testing.expectEqualStrings("abcdef", &dst);
}
