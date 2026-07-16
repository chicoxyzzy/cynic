//! Shared bounds-checked primitives for Ohaimark deopt byte streams.

const std = @import("std");

pub fn appendU16(
    stream: *std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,
    value: u16,
) !void {
    var bytes: [2]u8 = undefined;
    std.mem.writeInt(u16, &bytes, value, .little);
    try stream.appendSlice(allocator, &bytes);
}

pub fn appendU32(
    stream: *std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,
    value: u32,
) !void {
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, value, .little);
    try stream.appendSlice(allocator, &bytes);
}

pub fn indexU32(index: usize) !u32 {
    if (index > std.math.maxInt(u32)) return error.GraphTooLarge;
    return @intCast(index);
}

pub fn checkedBytes(bytes: []const u8, raw_start: anytype, raw_len: anytype) ![]const u8 {
    const start: usize = @intCast(raw_start);
    const len: usize = @intCast(raw_len);
    if (start > bytes.len or len > bytes.len - start) return error.InvalidMetadata;
    return bytes[start..][0..len];
}

pub const Cursor = struct {
    bytes: []const u8,
    position: usize = 0,

    pub fn readByte(self: *Cursor) !u8 {
        if (self.position >= self.bytes.len) return error.InvalidMetadata;
        const value = self.bytes[self.position];
        self.position += 1;
        return value;
    }

    pub fn readU16(self: *Cursor) !u16 {
        if (self.position > self.bytes.len or self.bytes.len - self.position < 2) {
            return error.InvalidMetadata;
        }
        const value = std.mem.readInt(u16, self.bytes[self.position..][0..2], .little);
        self.position += 2;
        return value;
    }

    pub fn readU32(self: *Cursor) !u32 {
        if (self.position > self.bytes.len or self.bytes.len - self.position < 4) {
            return error.InvalidMetadata;
        }
        const value = std.mem.readInt(u32, self.bytes[self.position..][0..4], .little);
        self.position += 4;
        return value;
    }

    pub fn atEnd(self: *const Cursor) bool {
        return self.position == self.bytes.len;
    }
};
