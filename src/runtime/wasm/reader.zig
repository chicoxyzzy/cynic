//! Byte cursor over a WebAssembly binary, with the LEB128 readers the
//! format is built on (§5.2.2 Integers, §5.2.4 Names).
//!
//! Every primitive bounds-checks and reports a typed error instead of
//! panicking — malformed input is expected, not exceptional. Slices
//! returned by `bytesN` / `name` borrow the underlying buffer; the
//! caller keeps that buffer alive for as long as the decoded module
//! is used.

const std = @import("std");

pub const Error = error{
    /// Buffer ended before the requested bytes were available.
    Truncated,
    /// An LEB128 value's significant bits exceed the target width.
    IntTooLarge,
    /// An LEB128 value used more bytes than the target width permits.
    LebTooLong,
    /// A name (§5.2.4) was not well-formed UTF-8.
    BadUtf8,
};

pub const Reader = struct {
    bytes: []const u8,
    pos: usize = 0,

    pub fn init(bytes: []const u8) Reader {
        return .{ .bytes = bytes };
    }

    pub fn remaining(self: *const Reader) usize {
        return self.bytes.len - self.pos;
    }

    pub fn atEnd(self: *const Reader) bool {
        return self.pos >= self.bytes.len;
    }

    /// Read a single byte.
    pub fn byte(self: *Reader) Error!u8 {
        if (self.pos >= self.bytes.len) return error.Truncated;
        const b = self.bytes[self.pos];
        self.pos += 1;
        return b;
    }

    /// Peek the next byte without advancing.
    pub fn peek(self: *const Reader) Error!u8 {
        if (self.pos >= self.bytes.len) return error.Truncated;
        return self.bytes[self.pos];
    }

    /// Borrow the next `n` bytes from the underlying buffer.
    pub fn bytesN(self: *Reader, n: usize) Error![]const u8 {
        if (self.remaining() < n) return error.Truncated;
        const s = self.bytes[self.pos .. self.pos + n];
        self.pos += n;
        return s;
    }

    /// A fixed-width little-endian u32 (used for f32 bit patterns and
    /// the module version word).
    pub fn u32le(self: *Reader) Error!u32 {
        const s = try self.bytesN(4);
        return std.mem.readInt(u32, s[0..4], .little);
    }

    /// Unsigned LEB128 into the integer type `T`. Enforces the byte
    /// budget implied by `T` (no overlong encodings) and rejects
    /// significant bits beyond the type width. Non-minimal encodings
    /// within budget are accepted, per §5.2.2.
    pub fn uleb(self: *Reader, comptime T: type) Error!T {
        const info = @typeInfo(T).int;
        comptime std.debug.assert(info.signedness == .unsigned);
        const bits = info.bits;
        const max_bytes = (bits + 6) / 7;
        const Shift = std.math.Log2Int(T);
        var result: T = 0;
        var shift: u32 = 0;
        var i: usize = 0;
        while (i < max_bytes) : (i += 1) {
            const b = try self.byte();
            const low: u8 = b & 0x7f;
            if (i == max_bytes - 1) {
                // Final permissible byte: bits above the type width must
                // be zero, and the continuation bit must be clear.
                const used_bits: u32 = bits - shift; // 1..7
                if ((low >> @as(u3, @intCast(used_bits))) != 0) return error.IntTooLarge;
                if (b & 0x80 != 0) return error.LebTooLong;
                result |= @as(T, low) << @as(Shift, @intCast(shift));
                return result;
            }
            result |= @as(T, low) << @as(Shift, @intCast(shift));
            shift += 7;
            if (b & 0x80 == 0) return result;
        }
        unreachable;
    }

    /// Signed LEB128 into the signed integer type `T`. Same budget and
    /// width discipline as `uleb`, with the final byte's surplus bits
    /// required to be a faithful sign extension.
    pub fn sleb(self: *Reader, comptime T: type) Error!T {
        const info = @typeInfo(T).int;
        comptime std.debug.assert(info.signedness == .signed);
        const bits = info.bits;
        const max_bytes = (bits + 6) / 7;
        const U = @Int(.unsigned, bits);
        const Shift = std.math.Log2Int(U);
        var result: U = 0;
        var shift: u32 = 0;
        var i: usize = 0;
        while (i < max_bytes) : (i += 1) {
            const b = try self.byte();
            const low: u8 = b & 0x7f;
            if (i == max_bytes - 1) {
                // Final byte: bits [used_bits-1, 7) must all equal the
                // sign bit — i.e. they are 0…0 or 1…1.
                const used_bits: u32 = bits - shift; // 1..7
                const sign_region: u8 = low >> @as(u3, @intCast(used_bits - 1));
                const region_width: u3 = @intCast(7 - (used_bits - 1));
                const all_ones: u8 = (@as(u8, 1) << region_width) - 1;
                if (sign_region != 0 and sign_region != all_ones) return error.IntTooLarge;
                if (b & 0x80 != 0) return error.LebTooLong;
                result |= @as(U, low) << @as(Shift, @intCast(shift));
                break;
            }
            result |= @as(U, low) << @as(Shift, @intCast(shift));
            shift += 7;
            if (b & 0x80 == 0) {
                // Sign-extend the high bits if the value is negative and
                // there is room left in the target width.
                if (shift < bits and (low & 0x40) != 0) {
                    result |= ~@as(U, 0) << @as(Shift, @intCast(shift));
                }
                break;
            }
        }
        return @bitCast(result);
    }

    /// A name: a UTF-8 byte vector (§5.2.4). The returned slice borrows
    /// the buffer; the bytes are validated as UTF-8.
    pub fn name(self: *Reader) Error![]const u8 {
        const len = try self.uleb(u32);
        const s = try self.bytesN(len);
        if (!std.unicode.utf8ValidateSlice(s)) return error.BadUtf8;
        return s;
    }
};

const testing = std.testing;

test "reader uleb: single-byte values" {
    var r = Reader.init(&.{0x00});
    try testing.expectEqual(@as(u32, 0), try r.uleb(u32));

    var r2 = Reader.init(&.{0x7f});
    try testing.expectEqual(@as(u32, 127), try r2.uleb(u32));
}

test "reader uleb: multi-byte value 624485" {
    // 624485 = 0xE5 0x8E 0x26 (classic LEB128 example).
    var r = Reader.init(&.{ 0xe5, 0x8e, 0x26 });
    try testing.expectEqual(@as(u32, 624485), try r.uleb(u32));
}

test "reader uleb: non-minimal padded zero is accepted within budget" {
    var r = Reader.init(&.{ 0x80, 0x00 });
    try testing.expectEqual(@as(u32, 0), try r.uleb(u32));
}

test "reader uleb: overlong past budget is rejected" {
    // Six continuation bytes for a u32 (budget is five).
    var r = Reader.init(&.{ 0x80, 0x80, 0x80, 0x80, 0x80, 0x00 });
    try testing.expectError(error.LebTooLong, r.uleb(u32));
}

test "reader uleb: value overflowing the width is rejected" {
    // The fifth byte of a u32 holds only 4 value bits; 0x0f yields the
    // maximum, while 0x1f (a 5th bit) overflows the width.
    var r = Reader.init(&.{ 0xff, 0xff, 0xff, 0xff, 0x0f });
    try testing.expectEqual(@as(u32, 0xffff_ffff), try r.uleb(u32));
    var r2 = Reader.init(&.{ 0xff, 0xff, 0xff, 0xff, 0x1f });
    try testing.expectError(error.IntTooLarge, r2.uleb(u32));
}

test "reader uleb: truncated continuation" {
    var r = Reader.init(&.{0x80});
    try testing.expectError(error.Truncated, r.uleb(u32));
}

test "reader sleb: small positives and negatives" {
    var r = Reader.init(&.{0x00});
    try testing.expectEqual(@as(i32, 0), try r.sleb(i32));

    var r1 = Reader.init(&.{0x7f});
    try testing.expectEqual(@as(i32, -1), try r1.sleb(i32));

    var r2 = Reader.init(&.{0x40});
    try testing.expectEqual(@as(i32, -64), try r2.sleb(i32));
}

test "reader sleb: multi-byte -128" {
    var r = Reader.init(&.{ 0x80, 0x7f });
    try testing.expectEqual(@as(i32, -128), try r.sleb(i32));
}

test "reader sleb: multi-byte 63 and -65" {
    var r = Reader.init(&.{ 0xbf, 0x00 }); // 0x3f with a padding byte
    try testing.expectEqual(@as(i32, 63), try r.sleb(i32));

    var r2 = Reader.init(&.{ 0xc1, 0x7f });
    try testing.expectEqual(@as(i32, -63), try r2.sleb(i32));
}

test "reader sleb: i64 round trips a large magnitude" {
    // -9223372036854775808 (i64 min) encodes in ten bytes.
    var r = Reader.init(&.{ 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x7f });
    try testing.expectEqual(@as(i64, std.math.minInt(i64)), try r.sleb(i64));
}

test "reader name: valid utf8 borrowed" {
    var r = Reader.init(&.{ 0x03, 'a', 'b', 'c' });
    try testing.expectEqualStrings("abc", try r.name());
}

test "reader name: invalid utf8 rejected" {
    var r = Reader.init(&.{ 0x01, 0xff });
    try testing.expectError(error.BadUtf8, r.name());
}

test "reader bytesN: borrows and advances" {
    var r = Reader.init(&.{ 0xaa, 0xbb, 0xcc });
    const two = try r.bytesN(2);
    try testing.expectEqualSlices(u8, &.{ 0xaa, 0xbb }, two);
    try testing.expectEqual(@as(usize, 1), r.remaining());
}
