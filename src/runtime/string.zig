//! `JSString` — Cynic's runtime string heap object.
//!
//! later keeps the layout deliberately small: a single owned byte
//! buffer holding the StringValue (§6.1.4). Ropes (concatenation
//! deferred via tree of segments — JSC `JSRopeString`, V8
//! `ConsString`) are an obvious later optimisation; we don't need
//! them for an interpreter that only just learned how to add 1+1.
//!
//! Encoding: raw UTF-16-code-unit semantics aren't realised yet —
//! ECMA-262 strings are *sequences of UTF-16 code units* (§6.1.4)
//! and most operations happen at that granularity. later stores
//! and compares the raw source bytes; full UTF-16 handling lands
//! with `String.prototype` later alongside `charCodeAt` / `length`.
//! Tests that exercise non-ASCII strings will need that work first.
//!
//! Allocation flows directly through `std.mem.Allocator` for now.
//! Once `runtime/heap.zig` lands (the mark-sweep heap), `JSString`
//! becomes a heap-managed object and ownership of the byte buffer
//! transfers to the heap arena.

const std = @import("std");

pub const JSString = struct {
    /// Owned byte buffer. Empty string ⇒ `bytes.len == 0`.
    bytes: []const u8,
    /// Mark-sweep bit, written by `Heap.markValue` and cleared by
    /// `Heap.collect` after each sweep. `false` when freshly
    /// allocated and after every full GC cycle.
    marked: bool = false,

    /// Allocate a new `JSString` whose contents are a copy of `src`.
    /// The returned pointer and its `bytes` are both owned by
    /// `allocator`; pair with `deinit`.
    pub fn init(allocator: std.mem.Allocator, src: []const u8) !*JSString {
        const owned = try allocator.dupe(u8, src);
        errdefer allocator.free(owned);
        const s = try allocator.create(JSString);
        s.* = .{ .bytes = owned };
        return s;
    }

    pub fn deinit(self: *JSString, allocator: std.mem.Allocator) void {
        allocator.free(self.bytes);
        allocator.destroy(self);
    }

    pub fn length(self: *const JSString) usize {
        return self.bytes.len;
    }

    pub fn isEmpty(self: *const JSString) bool {
        return self.bytes.len == 0;
    }

    /// §7.2.13 IsStringWellFormedUnicode — defer until we have
    /// runtime UTF-16 semantics. later's compare is byte-wise.
    pub fn equals(self: *const JSString, other: *const JSString) bool {
        return std.mem.eql(u8, self.bytes, other.bytes);
    }

    /// §13.5.3 / §22.1.3.1 — string concatenation. Allocates a new
    /// `JSString`; the inputs are unmodified. Caller owns the
    /// result and must `deinit` it.
    pub fn concat(allocator: std.mem.Allocator, a: *const JSString, b: *const JSString) !*JSString {
        const total = a.bytes.len + b.bytes.len;
        const owned = try allocator.alloc(u8, total);
        errdefer allocator.free(owned);
        @memcpy(owned[0..a.bytes.len], a.bytes);
        @memcpy(owned[a.bytes.len..], b.bytes);
        const s = try allocator.create(JSString);
        s.* = .{ .bytes = owned };
        return s;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "JSString: init copies the source bytes (no aliasing)" {
    var src_buf = [_]u8{ 'h', 'e', 'l', 'l', 'o' };
    const s = try JSString.init(testing.allocator, &src_buf);
    defer s.deinit(testing.allocator);

    // Mutating the source buffer must not affect the JSString.
    src_buf[0] = 'X';
    try testing.expectEqualStrings("hello", s.bytes);
}

test "JSString: length matches input slice length" {
    const s = try JSString.init(testing.allocator, "abc");
    defer s.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 3), s.length());
}

test "JSString: empty string round-trips" {
    const s = try JSString.init(testing.allocator, "");
    defer s.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), s.length());
    try testing.expect(s.isEmpty());
}

test "JSString: equals is byte-wise" {
    const a = try JSString.init(testing.allocator, "foo");
    defer a.deinit(testing.allocator);
    const b = try JSString.init(testing.allocator, "foo");
    defer b.deinit(testing.allocator);
    const c = try JSString.init(testing.allocator, "bar");
    defer c.deinit(testing.allocator);

    try testing.expect(a.equals(b));
    try testing.expect(!a.equals(c));
}

test "JSString: concat preserves order and total length" {
    const a = try JSString.init(testing.allocator, "Hello, ");
    defer a.deinit(testing.allocator);
    const b = try JSString.init(testing.allocator, "world!");
    defer b.deinit(testing.allocator);

    const ab = try JSString.concat(testing.allocator, a, b);
    defer ab.deinit(testing.allocator);

    try testing.expectEqualStrings("Hello, world!", ab.bytes);
    try testing.expectEqual(a.length() + b.length(), ab.length());
}

test "JSString: concat with empty operands is a no-op-ish copy" {
    const empty = try JSString.init(testing.allocator, "");
    defer empty.deinit(testing.allocator);
    const x = try JSString.init(testing.allocator, "abc");
    defer x.deinit(testing.allocator);

    const left = try JSString.concat(testing.allocator, empty, x);
    defer left.deinit(testing.allocator);
    const right = try JSString.concat(testing.allocator, x, empty);
    defer right.deinit(testing.allocator);

    try testing.expectEqualStrings("abc", left.bytes);
    try testing.expectEqualStrings("abc", right.bytes);
}
