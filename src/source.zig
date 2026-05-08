//! Source representation: raw bytes plus byte-offset / line-column lookup.
//!
//! References ECMA-262 §11.3 (Line Terminators) for the line-terminator set.
//! Cynic currently recognises LF, CR, and CRLF; LS (U+2028) and PS (U+2029)
//! will be added with full Unicode support.

const std = @import("std");

pub const Span = struct {
    start: u32,
    end: u32,

    pub fn empty(at: u32) Span {
        return .{ .start = at, .end = at };
    }

    pub fn slice(self: Span, source: []const u8) []const u8 {
        return source[self.start..self.end];
    }
};

/// A loaded source file. Owns its `line_starts` slice; does not own `name`
/// or `bytes` (callers retain those).
pub const Source = struct {
    name: []const u8,
    bytes: []const u8,
    /// `line_starts[i]` is the byte offset at the start of line (i+1).
    /// `line_starts[0] == 0`. Always non-empty.
    line_starts: []const u32,

    pub fn init(allocator: std.mem.Allocator, name: []const u8, bytes: []const u8) !Source {
        // Two passes: count lines, then fill the table. This avoids ArrayList
        // and lets us return an immutable slice.
        var count: u32 = 1;
        {
            var i: u32 = 0;
            while (i < bytes.len) {
                const c = bytes[i];
                if (c == '\n') {
                    count += 1;
                    i += 1;
                } else if (c == '\r') {
                    count += 1;
                    i += if (i + 1 < bytes.len and bytes[i + 1] == '\n') 2 else 1;
                } else {
                    i += 1;
                }
            }
        }

        const starts = try allocator.alloc(u32, count);
        starts[0] = 0;
        var idx: u32 = 1;
        var i: u32 = 0;
        while (i < bytes.len) {
            const c = bytes[i];
            if (c == '\n') {
                i += 1;
                starts[idx] = i;
                idx += 1;
            } else if (c == '\r') {
                i += if (i + 1 < bytes.len and bytes[i + 1] == '\n') 2 else 1;
                starts[idx] = i;
                idx += 1;
            } else {
                i += 1;
            }
        }
        std.debug.assert(idx == count);

        return .{ .name = name, .bytes = bytes, .line_starts = starts };
    }

    pub fn deinit(self: *Source, allocator: std.mem.Allocator) void {
        allocator.free(self.line_starts);
    }

    pub const LineCol = struct { line: u32, col: u32 };

    /// 1-based line and column for a byte offset. `offset` may be at most
    /// `bytes.len` (one past the end is allowed, e.g. for diagnostics on EOF).
    pub fn lineColAt(self: *const Source, offset: u32) LineCol {
        std.debug.assert(self.line_starts.len > 0);
        // Binary search for the greatest line_start <= offset.
        var lo: usize = 0;
        var hi: usize = self.line_starts.len;
        while (lo + 1 < hi) {
            const mid = lo + (hi - lo) / 2;
            if (self.line_starts[mid] <= offset) {
                lo = mid;
            } else {
                hi = mid;
            }
        }
        return .{
            .line = @intCast(lo + 1),
            .col = offset - self.line_starts[lo] + 1,
        };
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "Source: lineColAt across LF / CRLF / CR" {
    var src = try Source.init(testing.allocator, "<input>", "abc\ndef\r\nghi\rjkl");
    defer src.deinit(testing.allocator);

    try testing.expectEqual(Source.LineCol{ .line = 1, .col = 1 }, src.lineColAt(0));
    try testing.expectEqual(Source.LineCol{ .line = 1, .col = 3 }, src.lineColAt(2));
    try testing.expectEqual(Source.LineCol{ .line = 2, .col = 1 }, src.lineColAt(4));
    // After CRLF (positions 7..9), line 3 starts at offset 9.
    try testing.expectEqual(Source.LineCol{ .line = 3, .col = 1 }, src.lineColAt(9));
    // After bare CR at offset 12, line 4 starts at 13.
    try testing.expectEqual(Source.LineCol{ .line = 4, .col = 1 }, src.lineColAt(13));
}

test "Source: empty input yields a single line" {
    var src = try Source.init(testing.allocator, "<input>", "");
    defer src.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), src.line_starts.len);
    try testing.expectEqual(Source.LineCol{ .line = 1, .col = 1 }, src.lineColAt(0));
}
