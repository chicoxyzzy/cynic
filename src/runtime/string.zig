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
    /// Permanently-live: never collected, never needs marking.
    /// Set on chunk-constant strings at chunk-finalize time, since
    /// chunks are realm-lifetime and their constant pool can't
    /// outlive the realm. Saves the per-GC-cycle `markChunk`
    /// recursion (which would otherwise walk every nested
    /// function / class template's constants on every collect).
    pinned: bool = false,

    /// Allocate a new `JSString` whose contents are a copy of `src`.
    /// `struct_allocator` owns the `*JSString` header; `bytes_allocator`
    /// owns the `.bytes` slice. Splitting the two lets the host place
    /// the (often large) `.bytes` in a real page-returning allocator
    /// even when the header itself lives in a per-fixture arena —
    /// `arena.free()` is a no-op and would otherwise pin GC-freed
    /// string payloads to the arena's resident pages.
    pub fn init(
        struct_allocator: std.mem.Allocator,
        bytes_allocator: std.mem.Allocator,
        src: []const u8,
    ) !*JSString {
        const owned = try bytes_allocator.dupe(u8, src);
        errdefer bytes_allocator.free(owned);
        const s = try struct_allocator.create(JSString);
        s.* = .{ .bytes = owned };
        return s;
    }

    pub fn deinit(
        self: *JSString,
        struct_allocator: std.mem.Allocator,
        bytes_allocator: std.mem.Allocator,
    ) void {
        bytes_allocator.free(self.bytes);
        struct_allocator.destroy(self);
    }

    /// Internal byte length of the WTF-8 buffer. NOT the spec
    /// `String.prototype.length` — that's counted in UTF-16 code
    /// units (§22.1.5.1) and lives in `runtime/utf16.zig`'s
    /// `lengthInCodeUnits`. Callers exposing the JS-visible
    /// `length` MUST go through utf16; this one is for the heap /
    /// arena layer that operates on the byte buffer directly.
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
    pub fn concat(
        struct_allocator: std.mem.Allocator,
        bytes_allocator: std.mem.Allocator,
        a: *const JSString,
        b: *const JSString,
    ) !*JSString {
        return concatBytes(struct_allocator, bytes_allocator, a.bytes, b.bytes);
    }

    /// §13.5.3 — concatenate two raw WTF-8 byte slices into a fresh
    /// `JSString` in a *single* allocation. Used by `addValues`
    /// (the `+` operator) where one or both operands were
    /// ToString-coerced into scratch slices that aren't
    /// `JSString`s — concatenating directly avoids materialising a
    /// throwaway intermediate buffer that `allocateString` would
    /// then copy a second time.
    ///
    /// §6.1.4 WTF-8 invariant: a *valid* surrogate pair is always
    /// stored as the single 4-byte UTF-8 form, never two adjacent
    /// 3-byte CESU-8 escapes. A plain `a ++ b` violates that when
    /// `a` ends with a lone high surrogate and `b` starts with a
    /// lone low surrogate — `utf16.wtf8ConcatInto` merges that seam.
    pub fn concatBytes(
        struct_allocator: std.mem.Allocator,
        bytes_allocator: std.mem.Allocator,
        a: []const u8,
        b: []const u8,
    ) !*JSString {
        const utf16 = @import("utf16.zig");
        const total = utf16.wtf8ConcatLen(a, b);
        const owned = try bytes_allocator.alloc(u8, total);
        errdefer bytes_allocator.free(owned);
        utf16.wtf8ConcatInto(owned, a, b);
        const s = try struct_allocator.create(JSString);
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
    const s = try JSString.init(testing.allocator, testing.allocator, &src_buf);
    defer s.deinit(testing.allocator, testing.allocator);

    // Mutating the source buffer must not affect the JSString.
    src_buf[0] = 'X';
    try testing.expectEqualStrings("hello", s.bytes);
}

test "JSString: length matches input slice length" {
    const s = try JSString.init(testing.allocator, testing.allocator, "abc");
    defer s.deinit(testing.allocator, testing.allocator);
    try testing.expectEqual(@as(usize, 3), s.length());
}

test "JSString: empty string round-trips" {
    const s = try JSString.init(testing.allocator, testing.allocator, "");
    defer s.deinit(testing.allocator, testing.allocator);
    try testing.expectEqual(@as(usize, 0), s.length());
    try testing.expect(s.isEmpty());
}

test "JSString: equals is byte-wise" {
    const a = try JSString.init(testing.allocator, testing.allocator, "foo");
    defer a.deinit(testing.allocator, testing.allocator);
    const b = try JSString.init(testing.allocator, testing.allocator, "foo");
    defer b.deinit(testing.allocator, testing.allocator);
    const c = try JSString.init(testing.allocator, testing.allocator, "bar");
    defer c.deinit(testing.allocator, testing.allocator);

    try testing.expect(a.equals(b));
    try testing.expect(!a.equals(c));
}

test "JSString: concat preserves order and total length" {
    const a = try JSString.init(testing.allocator, testing.allocator, "Hello, ");
    defer a.deinit(testing.allocator, testing.allocator);
    const b = try JSString.init(testing.allocator, testing.allocator, "world!");
    defer b.deinit(testing.allocator, testing.allocator);

    const ab = try JSString.concat(testing.allocator, testing.allocator, a, b);
    defer ab.deinit(testing.allocator, testing.allocator);

    try testing.expectEqualStrings("Hello, world!", ab.bytes);
    try testing.expectEqual(a.length() + b.length(), ab.length());
}

test "JSString: concat with empty operands is a no-op-ish copy" {
    const empty = try JSString.init(testing.allocator, testing.allocator, "");
    defer empty.deinit(testing.allocator, testing.allocator);
    const x = try JSString.init(testing.allocator, testing.allocator, "abc");
    defer x.deinit(testing.allocator, testing.allocator);

    const left = try JSString.concat(testing.allocator, testing.allocator, empty, x);
    defer left.deinit(testing.allocator, testing.allocator);
    const right = try JSString.concat(testing.allocator, testing.allocator, x, empty);
    defer right.deinit(testing.allocator, testing.allocator);

    try testing.expectEqualStrings("abc", left.bytes);
    try testing.expectEqualStrings("abc", right.bytes);
}

test "JSString: concatBytes merges a paired surrogate seam (§6.1.4)" {
    // `a` ends with a lone high surrogate U+D800 (`ED A0 80`), `b`
    // starts with a lone low surrogate U+DC00 (`ED B0 80`). The pair
    // is the supplementary U+10000 — the WTF-8 invariant requires
    // the single 4-byte form `F0 90 80 80`, not two 3-byte escapes.
    const a = [_]u8{ 'x', 0xED, 0xA0, 0x80 };
    const b = [_]u8{ 0xED, 0xB0, 0x80, 'y' };
    const s = try JSString.concatBytes(testing.allocator, testing.allocator, &a, &b);
    defer s.deinit(testing.allocator, testing.allocator);
    try testing.expectEqualSlices(u8, &[_]u8{ 'x', 0xF0, 0x90, 0x80, 0x80, 'y' }, s.bytes);
}

test "JSString: concatBytes leaves a non-paired surrogate seam intact" {
    // Two lone *high* surrogates do not pair — plain join, 6 bytes.
    const hi = [_]u8{ 0xED, 0xA0, 0x80 };
    const s = try JSString.concatBytes(testing.allocator, testing.allocator, &hi, &hi);
    defer s.deinit(testing.allocator, testing.allocator);
    try testing.expectEqual(@as(usize, 6), s.bytes.len);
}
