//! `JSString` — Cynic's runtime string heap object.
//!
//! A `JSString` is a node in a (potentially lazy) string tree. The
//! ECMA-262 String type (§6.1.4) is a sequence of UTF-16 code units;
//! Cynic stores the realised bytes as WTF-8 (UTF-8 with 3-byte
//! CESU-8 lone-surrogate escapes — see AGENTS.md "Strings are
//! UTF-16 code units …").
//!
//! Two payload kinds:
//!
//! - **`flat`** — an owned WTF-8 byte buffer.
//! - **`cons`** — a lazy concatenation node `(left, right)` whose
//!   realised bytes are `left ++ right`. This is the rope
//!   representation (JSC `JSRopeString`, V8 `ConsString`) that lets
//!   `a + b` be amortised O(1). Stage 2 of the ConsString effort
//!   builds real cons nodes from `+` / `+=` / `String.prototype.
//!   concat` — subject to three gates: a min-length threshold
//!   (`min_cons_byte_len`), the WTF-8 dirty-surrogate-seam rule
//!   (§6.1.4 — a paired seam eager-flattens so every cons tree is
//!   trivially clean), and a depth cap (`max_rope_depth`) that
//!   eager-flattens one operand before the tree would grow past it.
//!
//! `length_cu` (UTF-16 code-unit count, the JS-visible
//! `String.prototype.length` per §22.1.5) and `byte_len` (WTF-8
//! byte length) are computed once at construction and stored, so
//! both are O(1) regardless of payload kind. Both are `u32`:
//! a concat whose result would overflow `u32` throws RangeError
//! (V8-style `kMaxLength`).
//!
//! `bytes` is intentionally NOT a field name — the migration from
//! the old flat-only `JSString` relies on the compiler flagging
//! every former `.bytes` reader so it can be routed through
//! `flatten(bytes_allocator)` (materialise + cache) or
//! `flatBytesIfFlat()` (fast read-only branch).

const std = @import("std");
const Heap = @import("heap.zig").Heap;

/// Maximum string length in WTF-8 bytes. A concatenation whose
/// result would exceed this overflows `byte_len` (`u32`) and is
/// rejected with `error.StringTooLong` — callers translate that to
/// a RangeError (§6.1.4 note "the maximum length … is
/// implementation-defined"; V8 / JSC both cap and throw).
pub const max_byte_len: usize = std.math.maxInt(u32);

/// ConsString Stage 2 — minimum total WTF-8 byte length below which
/// `Heap.allocateConsString` eager-flattens instead of building a
/// `.cons` node. A cons header is two pointers plus the JSString
/// header (~32 B); below this threshold the rope costs more than the
/// byte copy it would save and only deepens the tree. V8's
/// `ConsString::kMinLength` is 13; Cynic picks 16. Left a named
/// const for Stage 3 tuning.
pub const min_cons_byte_len: usize = 16;

/// ConsString Stage 2 — maximum cons-tree depth. A `result += chunk`
/// loop builds a strictly left-leaning spine of depth = iteration
/// count; `flatten` / `markString` walk that depth. When a new cons
/// node would exceed this cap, `Heap.allocateConsString` flattens
/// one operand first so the resulting depth stays bounded. The
/// `+=` loop then periodically flattens and keeps going — still
/// amortised O(1) per `+=`, but no rope ever exceeds the cap.
///
/// The depth-cap flatten is the cost ceiling: every `cap` rope
/// nodes, the whole rope's bytes get copied into a fresh flat
/// buffer. For a steady `s = s + tiny` loop, total bytes copied
/// is `O(N^2 / cap)` (each flatten copies the cumulative rope).
/// Raising the cap from 96 to 8192 cut the `string_concat` bench
/// from 80 ms to 57 ms (-29 %) — `_platform_memmove` (74 % of
/// samples on the un-raised cap) is no longer the bottleneck.
/// `markString` is iterative (worklist-based), so a deeper tree
/// is safe; `copyConsBytes`'s on-stack work buffer at this depth
/// is ~64 KB, well within any target's default stack.
pub const max_rope_depth: u16 = 8192;

/// Error set of the `concat` family. `StringTooLong` is raised when
/// joining two valid strings would exceed `max_byte_len`; the
/// runtime maps it to a RangeError. `init` / `initOwned` take an
/// already-realised buffer and only ever return `OutOfMemory` — a
/// single source buffer past `max_byte_len` (4 GiB) is treated as
/// an allocation failure, not a distinct error.
pub const StringError = error{ OutOfMemory, StringTooLong };
pub const AllocError = error{OutOfMemory};

pub const JSString = struct {
    /// Mark color. `s.mark_color == heap.live_color` means "live
    /// this cycle". See `JSObject.mark_color` for the protocol —
    /// no explicit clear; the cycle-start `live_color` flip ages
    /// every entry to "unmarked" automatically.
    mark_color: u1 = 0,
    /// Permanently-live: never collected, never needs marking.
    /// Set on chunk-constant strings at chunk-finalize time, since
    /// chunks are realm-lifetime and their constant pool can't
    /// outlive the realm.
    pinned: bool = false,
    /// Generational-GC age. Fresh allocations start `.young`; a
    /// young object that survives a `collectYoung` is promoted to
    /// `.mature` and relinked into the mature list. Pinned strings
    /// (chunk constants) allocate straight to `.mature`.
    generation: @import("heap.zig").Generation = .young,
    /// Set when this object is recorded in the heap's remembered
    /// set as a known old→young store source. Guards against
    /// double-insertion on the write-barrier hot path. Strings are
    /// immutable post-build so this stays `false` for them today;
    /// the field keeps every header shape uniform.
    in_remembered_set: bool = false,
    /// UTF-16 code-unit count — the JS-visible `String.prototype.
    /// length` (§22.1.5). Computed once at construction via
    /// `utf16.lengthInCodeUnits`; O(1) for any payload kind.
    length_cu: u32,
    /// WTF-8 byte length of the realised string. Stored so callers
    /// that only need the length don't have to flatten a cons.
    byte_len: u32,
    /// Cons-tree depth: 0 for a flat node, `1 + max(left, right)`
    /// for a cons. Stage 1 keeps it for the later balancing /
    /// flatten-recursion-bound logic; flat nodes always read 0.
    depth: u16 = 0,
    /// The payload — flat owned bytes, or a lazy cons of two
    /// children.
    payload: Payload,

    pub const Payload = union(enum) {
        /// Owned WTF-8 buffer. Empty string ⇒ `flat.len == 0`.
        flat: []const u8,
        /// Lazy concatenation node. `left` and `right` are
        /// heap-tracked `JSString`s; the realised bytes are
        /// `left ++ right` (WTF-8-seam-merged — see `flatten`).
        cons: Cons,
    };

    pub const Cons = struct {
        left: *JSString,
        right: *JSString,
        /// The heap that owns this rope. Stored so `flatBytes()` /
        /// `equals()` — heap-free read accessors — can reach
        /// `heap.bytes_allocator` and materialise the rope on demand
        /// (V8 / JSC treat ropes as fully transparent: every byte
        /// reader flattens). A bare `*Heap` (8 bytes) rather than an
        /// embedded `std.mem.Allocator` (16) — the heap is a stable
        /// `allocator.create(Heap)` pointer, so this never dangles
        /// and keeps the `JSString` header to 48 bytes.
        heap: *Heap,
    };

    /// Allocate a new flat `JSString` whose contents are a copy of
    /// `src`. `struct_allocator` owns the `*JSString` header;
    /// `bytes_allocator` owns the byte slice. Splitting the two lets
    /// the host place the (often large) bytes in a real
    /// page-returning allocator even when the header lives in a
    /// per-fixture arena — `arena.free()` is a no-op and would
    /// otherwise pin GC-freed string payloads to the arena's pages.
    pub fn init(
        struct_allocator: std.mem.Allocator,
        bytes_allocator: std.mem.Allocator,
        src: []const u8,
    ) AllocError!*JSString {
        const utf16 = @import("utf16.zig");
        // A single source buffer past `max_byte_len` (4 GiB) is
        // effectively an allocation failure — no real code path
        // produces one and the `dupe` below would OOM regardless.
        if (src.len > max_byte_len) return error.OutOfMemory;
        const owned = try bytes_allocator.dupe(u8, src);
        errdefer bytes_allocator.free(owned);
        const s = try struct_allocator.create(JSString);
        s.* = .{
            .length_cu = @intCast(utf16.lengthInCodeUnits(owned)),
            .byte_len = @intCast(owned.len),
            .payload = .{ .flat = owned },
        };
        return s;
    }

    /// Allocate a flat `JSString` that takes ownership of `owned`
    /// directly (no copy). The caller must have allocated `owned`
    /// via the heap's `bytes_allocator`. Used by the concat
    /// helpers, which build the result buffer in one allocation.
    pub fn initOwned(
        struct_allocator: std.mem.Allocator,
        owned: []const u8,
    ) AllocError!*JSString {
        const utf16 = @import("utf16.zig");
        // `owned` is an already-realised buffer — its length fits
        // `u32` by construction (the `concat` family checks before
        // allocating). The assert documents that invariant.
        std.debug.assert(owned.len <= max_byte_len);
        const s = try struct_allocator.create(JSString);
        s.* = .{
            .length_cu = @intCast(utf16.lengthInCodeUnits(owned)),
            .byte_len = @intCast(owned.len),
            .payload = .{ .flat = owned },
        };
        return s;
    }

    pub fn deinit(
        self: *JSString,
        struct_allocator: std.mem.Allocator,
        bytes_allocator: std.mem.Allocator,
    ) void {
        switch (self.payload) {
            // Flat: free the owned byte buffer.
            .flat => |b| bytes_allocator.free(b),
            // Cons: nothing payload-side. `left` / `right` are
            // separate heap-tracked `JSString`s the sweep frees
            // on their own.
            .cons => {},
        }
        struct_allocator.destroy(self);
    }

    /// Internal WTF-8 byte length. NOT the spec
    /// `String.prototype.length` — that is `length_cu`, counted in
    /// UTF-16 code units (§22.1.5). O(1): `byte_len` is stored.
    pub fn length(self: *const JSString) usize {
        return self.byte_len;
    }

    pub fn isEmpty(self: *const JSString) bool {
        return self.byte_len == 0;
    }

    /// True when the payload is already a flat buffer (no
    /// materialisation needed). Stage 1: always true in practice.
    pub fn isFlat(self: *const JSString) bool {
        return self.payload == .flat;
    }

    /// Fast read-only access to the WTF-8 bytes when the node is
    /// already flat; `null` for a cons node. Hot paths that only
    /// read (and have no heap in scope) branch on this; when it
    /// returns `null` the caller must fall back to
    /// `flatten(bytes_allocator)`. Stage 1: every live `JSString`
    /// is flat, so this never returns `null` outside the
    /// hand-built-cons unit tests.
    pub fn flatBytesIfFlat(self: *const JSString) ?[]const u8 {
        return switch (self.payload) {
            .flat => |b| b,
            .cons => null,
        };
    }

    /// Heap-free WTF-8 byte accessor — the workhorse every former
    /// `JSString.bytes` reader uses.
    ///
    /// For a flat node this is a direct slice return, no allocation.
    /// For a cons (rope) node it materialises the subtree on demand
    /// — Stage 2 makes ropes fully transparent the way V8 / JSC do:
    /// every byte reader flattens, so callers never have to thread a
    /// heap through. The cons node carries its own `bytes_allocator`
    /// (see `Cons`) precisely so this accessor can flatten without a
    /// `Heap` in scope. After the first call the node is degenerated
    /// to flat and the result cached, so repeat reads are O(1).
    ///
    /// On the (practically unreachable) allocation failure while
    /// materialising a rope, this falls back to the empty slice
    /// rather than crashing — a wrong-but-safe answer. Callers that
    /// must distinguish OOM should use `flatten` directly.
    ///
    /// The signature stays `*const` even though flattening a rope
    /// mutates `payload` (`@constCast` below): the mutation is a
    /// benign, idempotent cache fill — the realised bytes and every
    /// stored length are unchanged — so a `*const JSString` reader
    /// is not lying. V8's `String::Flatten` does the same on a
    /// nominally-const string.
    pub fn flatBytes(self: *const JSString) []const u8 {
        switch (self.payload) {
            .flat => |b| return b,
            .cons => |c| {
                const mutable: *JSString = @constCast(self);
                return mutable.flatten(c.heap.bytes_allocator) catch "";
            },
        }
    }

    /// Walk the right spine of a (possibly cons) tree and return its
    /// rightmost flat leaf — the node whose bytes end the realised
    /// string. O(depth): one pointer chase per cons level. Used by
    /// `Heap.allocateConsString` to inspect the WTF-8 seam (§6.1.4)
    /// without materialising either operand.
    pub fn rightmostLeaf(self: *JSString) *JSString {
        var cursor: *JSString = self;
        while (true) {
            switch (cursor.payload) {
                .flat => return cursor,
                .cons => |c| cursor = c.right,
            }
        }
    }

    /// Walk the left spine of a (possibly cons) tree and return its
    /// leftmost flat leaf — the node whose bytes begin the realised
    /// string. Dual of `rightmostLeaf`; O(depth).
    pub fn leftmostLeaf(self: *JSString) *JSString {
        var cursor: *JSString = self;
        while (true) {
            switch (cursor.payload) {
                .flat => return cursor,
                .cons => |c| cursor = c.left,
            }
        }
    }

    /// Return the realised contiguous WTF-8 bytes of this string.
    ///
    /// - flat node: returns the owned slice directly, no allocation.
    /// - cons node: materialises the whole subtree into one
    ///   `byte_len`-sized buffer, then degenerates this node into a
    ///   `flat` node in place (caching the result so a second
    ///   `flatten` is O(1)). The children are left untouched — the
    ///   GC will collect them once nothing else references them.
    ///
    /// The materialisation is iterative with an explicit work-stack
    /// (never recursive) so a deeply left/right-leaning cons tree
    /// cannot overflow the Zig call stack.
    ///
    /// WTF-8 seam (§6.1.4): a cons is only ever built when the
    /// left/right seam is *clean* — `allocateConsString` eager-
    /// flattens a dirty seam (left ends lone-high, right starts
    /// lone-low) so it never becomes a cons. Therefore the
    /// in-order byte copy here is correct without re-running the
    /// seam merge. (Stage 1 builds no cons at all, so this is a
    /// forward-looking invariant; the dirty-seam fixtures live in
    /// `utf16.zig`'s `wtf8Concat*` tests.)
    ///
    /// `bytes_allocator` must be the same allocator the heap used
    /// for the existing flat payloads — the materialised buffer is
    /// freed by `deinit` through that allocator.
    pub fn flatten(
        self: *JSString,
        bytes_allocator: std.mem.Allocator,
    ) AllocError![]const u8 {
        switch (self.payload) {
            .flat => |b| return b,
            .cons => {},
        }
        // Materialise. One allocation of the already-known length.
        const out = try bytes_allocator.alloc(u8, self.byte_len);
        errdefer bytes_allocator.free(out);
        copyConsBytes(self, out);
        // Degenerate in place: this node becomes flat, caching the
        // realised bytes. `length_cu` / `byte_len` are unchanged.
        self.payload = .{ .flat = out };
        self.depth = 0;
        return out;
    }

    /// Iterative in-order copy of a cons tree's realised bytes into
    /// `dst` (`dst.len` must equal the root's `byte_len`). Uses an
    /// explicit fixed work-stack — a cons tree's depth is bounded
    /// by `depth` (a `u16`), so a small on-stack buffer suffices
    /// and there is no recursion.
    fn copyConsBytes(root: *JSString, dst: []u8) void {
        // The stack holds at most one right-child per level of the
        // current descent. `Heap.allocateConsString` caps cons depth
        // at `max_rope_depth`, so `max_rope_depth + 16` frames are
        // always ample; an overflow here would be a depth-cap bug,
        // asserted below.
        var stack_buf: [max_rope_depth + 16]*JSString = undefined;
        var sp: usize = 0;
        var cursor: *JSString = root;
        var offset: usize = 0;
        while (true) {
            switch (cursor.payload) {
                .flat => |b| {
                    @memcpy(dst[offset .. offset + b.len], b);
                    offset += b.len;
                    if (sp == 0) break;
                    sp -= 1;
                    cursor = stack_buf[sp];
                },
                .cons => |c| {
                    // Visit left first, then right — push right,
                    // descend left.
                    std.debug.assert(sp < stack_buf.len);
                    stack_buf[sp] = c.right;
                    sp += 1;
                    cursor = c.left;
                },
            }
        }
    }

    /// §7.2.13 / §7.2.10 string equality used by `===` and
    /// `Object.is`. Pointer-equal short-circuits to `true`;
    /// differing `length_cu` or `byte_len` short-circuits to
    /// `false`. Otherwise both operands are materialised via
    /// `flatBytes` (O(1) for a flat node, a one-time rope flatten
    /// for a cons — see `flatBytes`) and byte-compared. Ropes are
    /// transparent here: a cons operand flattens itself.
    pub fn equals(self: *const JSString, other: *const JSString) bool {
        if (self == other) return true;
        if (self.length_cu != other.length_cu) return false;
        if (self.byte_len != other.byte_len) return false;
        return std.mem.eql(u8, self.flatBytes(), other.flatBytes());
    }

    /// Heap-aware string equality — flattens both operands, then
    /// byte-compares. Same fast pre-checks as `equals`. This is the
    /// form a later stage's `===` will call once cons nodes can be
    /// observed; Stage 1 keeps `strictEq` on `equals` because no
    /// cons ever reaches it.
    pub fn equalsFlatten(
        self: *JSString,
        other: *JSString,
        bytes_allocator: std.mem.Allocator,
    ) AllocError!bool {
        if (self == other) return true;
        if (self.length_cu != other.length_cu) return false;
        if (self.byte_len != other.byte_len) return false;
        const a = try self.flatten(bytes_allocator);
        const b = try other.flatten(bytes_allocator);
        return std.mem.eql(u8, a, b);
    }

    /// §13.5.3 / §22.1.3.1 — string concatenation. Allocates a new
    /// *flat* `JSString` in a single allocation (Stage 1 builds no
    /// ropes). Caller owns the result and must `deinit` it.
    pub fn concat(
        struct_allocator: std.mem.Allocator,
        bytes_allocator: std.mem.Allocator,
        a: *JSString,
        b: *JSString,
    ) StringError!*JSString {
        const a_bytes = try a.flatten(bytes_allocator);
        const b_bytes = try b.flatten(bytes_allocator);
        return concatBytes(struct_allocator, bytes_allocator, a_bytes, b_bytes);
    }

    /// §13.5.3 — concatenate two raw WTF-8 byte slices into a fresh
    /// flat `JSString` in a *single* allocation. Used by `addValues`
    /// (the `+` operator) where one or both operands were
    /// ToString-coerced into scratch slices that aren't
    /// `JSString`s.
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
    ) StringError!*JSString {
        const utf16 = @import("utf16.zig");
        const total = utf16.wtf8ConcatLen(a, b);
        if (total > max_byte_len) return error.StringTooLong;
        const owned = try bytes_allocator.alloc(u8, total);
        errdefer bytes_allocator.free(owned);
        utf16.wtf8ConcatInto(owned, a, b);
        return initOwned(struct_allocator, owned);
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

/// A bare `Heap` for cons-node tests. A cons node's `.heap`
/// back-pointer is read only by `flatten` (to reach
/// `bytes_allocator`), so this heap carries no registered strings —
/// the tests create their `JSString`s directly with
/// `testing.allocator` and deinit them by hand.
fn makeTestHeap() *Heap {
    const h = testing.allocator.create(Heap) catch unreachable;
    h.* = Heap.init(testing.allocator);
    return h;
}

fn destroyTestHeap(h: *Heap) void {
    h.deinit();
    testing.allocator.destroy(h);
}

/// Hand-build a cons node over two children. Production code builds
/// cons nodes via `Heap.allocateConsString`; this test-only helper
/// exercises the cons arm of `flatten` / `markString` directly.
fn makeConsForTest(heap: *Heap, left: *JSString, right: *JSString) !*JSString {
    const cons = try testing.allocator.create(JSString);
    cons.* = .{
        .length_cu = left.length_cu + right.length_cu,
        .byte_len = left.byte_len + right.byte_len,
        .depth = 1 + @max(left.depth, right.depth),
        .payload = .{ .cons = .{
            .left = left,
            .right = right,
            .heap = heap,
        } },
    };
    return cons;
}

test "JSString: init copies the source bytes (no aliasing)" {
    var src_buf = [_]u8{ 'h', 'e', 'l', 'l', 'o' };
    const s = try JSString.init(testing.allocator, testing.allocator, &src_buf);
    defer s.deinit(testing.allocator, testing.allocator);

    // Mutating the source buffer must not affect the JSString.
    src_buf[0] = 'X';
    try testing.expectEqualStrings("hello", s.flatBytesIfFlat().?);
}

test "JSString: header stays compact" {
    // Regression guard: the `cons` arm holds a bare `*Heap`
    // (8 bytes), not an embedded `std.mem.Allocator` (16). Keep the
    // header from creeping back up — every live string pays it.
    try testing.expect(@sizeOf(JSString) <= 48);
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

test "JSString: flat node is flat, exposes bytes via flatBytesIfFlat" {
    const s = try JSString.init(testing.allocator, testing.allocator, "hi");
    defer s.deinit(testing.allocator, testing.allocator);
    try testing.expect(s.isFlat());
    try testing.expectEqualStrings("hi", s.flatBytesIfFlat().?);
    try testing.expectEqual(@as(u16, 0), s.depth);
}

test "JSString: length_cu counts UTF-16 code units, not bytes" {
    // ASCII — code units == bytes.
    const ascii = try JSString.init(testing.allocator, testing.allocator, "abc");
    defer ascii.deinit(testing.allocator, testing.allocator);
    try testing.expectEqual(@as(u32, 3), ascii.length_cu);
    try testing.expectEqual(@as(u32, 3), ascii.byte_len);

    // BMP non-ASCII U+00FF — 1 code unit, 2 bytes.
    const bmp = try JSString.init(testing.allocator, testing.allocator, "a\xC3\xBFc");
    defer bmp.deinit(testing.allocator, testing.allocator);
    try testing.expectEqual(@as(u32, 3), bmp.length_cu);
    try testing.expectEqual(@as(u32, 4), bmp.byte_len);

    // Supplementary U+1F600 — 2 code units, 4 bytes.
    const astral = try JSString.init(testing.allocator, testing.allocator, "a\xF0\x9F\x98\x80c");
    defer astral.deinit(testing.allocator, testing.allocator);
    try testing.expectEqual(@as(u32, 4), astral.length_cu);
    try testing.expectEqual(@as(u32, 6), astral.byte_len);
}

test "JSString: flatten on a flat node returns the slice directly" {
    const s = try JSString.init(testing.allocator, testing.allocator, "flat");
    defer s.deinit(testing.allocator, testing.allocator);
    const b = try s.flatten(testing.allocator);
    try testing.expectEqualStrings("flat", b);
    // Still flat, no behavioural change.
    try testing.expect(s.isFlat());
}

test "JSString: flatten materialises a hand-built cons node" {
    const heap = makeTestHeap();
    defer destroyTestHeap(heap);
    const left = try JSString.init(testing.allocator, testing.allocator, "Hello, ");
    const right = try JSString.init(testing.allocator, testing.allocator, "world!");
    const cons = try makeConsForTest(heap, left, right);

    try testing.expect(!cons.isFlat());
    try testing.expect(cons.flatBytesIfFlat() == null);
    try testing.expectEqual(@as(u32, 13), cons.byte_len);
    try testing.expectEqual(@as(u32, 13), cons.length_cu);

    const b = try cons.flatten(testing.allocator);
    try testing.expectEqualStrings("Hello, world!", b);
    // flatten degenerated the node to flat and cached the result.
    try testing.expect(cons.isFlat());
    try testing.expectEqual(@as(u16, 0), cons.depth);
    // A second flatten is O(1) and returns the cached slice.
    const b2 = try cons.flatten(testing.allocator);
    try testing.expectEqual(b.ptr, b2.ptr);

    // Tear down. The cons node now owns a flat buffer; the
    // children are still independent flat nodes.
    cons.deinit(testing.allocator, testing.allocator);
    left.deinit(testing.allocator, testing.allocator);
    right.deinit(testing.allocator, testing.allocator);
}

test "JSString: flatten a nested cons tree (iterative work-stack)" {
    // Build ((\"a\" + \"b\") + (\"c\" + \"d\")) by hand.
    const a = try JSString.init(testing.allocator, testing.allocator, "a");
    const b = try JSString.init(testing.allocator, testing.allocator, "b");
    const c = try JSString.init(testing.allocator, testing.allocator, "c");
    const d = try JSString.init(testing.allocator, testing.allocator, "d");

    const heap = makeTestHeap();
    defer destroyTestHeap(heap);
    const ab = try makeConsForTest(heap, a, b);
    const cd = try makeConsForTest(heap, c, d);
    const root = try makeConsForTest(heap, ab, cd);
    try testing.expectEqual(@as(u16, 2), root.depth);

    const flat = try root.flatten(testing.allocator);
    try testing.expectEqualStrings("abcd", flat);

    root.deinit(testing.allocator, testing.allocator);
    ab.deinit(testing.allocator, testing.allocator);
    cd.deinit(testing.allocator, testing.allocator);
    a.deinit(testing.allocator, testing.allocator);
    b.deinit(testing.allocator, testing.allocator);
    c.deinit(testing.allocator, testing.allocator);
    d.deinit(testing.allocator, testing.allocator);
}

test "JSString: equals — fast pre-checks and byte compare" {
    const a = try JSString.init(testing.allocator, testing.allocator, "foo");
    defer a.deinit(testing.allocator, testing.allocator);
    const b = try JSString.init(testing.allocator, testing.allocator, "foo");
    defer b.deinit(testing.allocator, testing.allocator);
    const c = try JSString.init(testing.allocator, testing.allocator, "bar");
    defer c.deinit(testing.allocator, testing.allocator);
    const longer = try JSString.init(testing.allocator, testing.allocator, "foobar");
    defer longer.deinit(testing.allocator, testing.allocator);

    // Pointer-equal short circuit.
    try testing.expect(a.equals(a));
    // Equal value, distinct pointers.
    try testing.expect(a.equals(b));
    // Same length, different bytes.
    try testing.expect(!a.equals(c));
    // Different length — short-circuits on byte_len.
    try testing.expect(!a.equals(longer));
}

test "JSString: equalsFlatten works across a hand-built cons" {
    const heap = makeTestHeap();
    defer destroyTestHeap(heap);
    const lhs_l = try JSString.init(testing.allocator, testing.allocator, "ab");
    const lhs_r = try JSString.init(testing.allocator, testing.allocator, "cd");
    const lhs = try makeConsForTest(heap, lhs_l, lhs_r);
    const rhs = try JSString.init(testing.allocator, testing.allocator, "abcd");

    try testing.expect(try lhs.equalsFlatten(rhs, testing.allocator));

    lhs.deinit(testing.allocator, testing.allocator);
    lhs_l.deinit(testing.allocator, testing.allocator);
    lhs_r.deinit(testing.allocator, testing.allocator);
    rhs.deinit(testing.allocator, testing.allocator);
}

test "JSString: concat preserves order and total length" {
    const a = try JSString.init(testing.allocator, testing.allocator, "Hello, ");
    defer a.deinit(testing.allocator, testing.allocator);
    const b = try JSString.init(testing.allocator, testing.allocator, "world!");
    defer b.deinit(testing.allocator, testing.allocator);

    const ab = try JSString.concat(testing.allocator, testing.allocator, a, b);
    defer ab.deinit(testing.allocator, testing.allocator);

    try testing.expectEqualStrings("Hello, world!", ab.flatBytesIfFlat().?);
    try testing.expectEqual(a.length() + b.length(), ab.length());
    // Stage 1: concat produces a flat string, never a rope.
    try testing.expect(ab.isFlat());
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

    try testing.expectEqualStrings("abc", left.flatBytesIfFlat().?);
    try testing.expectEqualStrings("abc", right.flatBytesIfFlat().?);
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
    try testing.expectEqualSlices(u8, &[_]u8{ 'x', 0xF0, 0x90, 0x80, 0x80, 'y' }, s.flatBytesIfFlat().?);
}

test "JSString: concatBytes leaves a non-paired surrogate seam intact" {
    // Two lone *high* surrogates do not pair — plain join, 6 bytes.
    const hi = [_]u8{ 0xED, 0xA0, 0x80 };
    const s = try JSString.concatBytes(testing.allocator, testing.allocator, &hi, &hi);
    defer s.deinit(testing.allocator, testing.allocator);
    try testing.expectEqual(@as(usize, 6), s.byte_len);
}

test "JSString: rightmostLeaf / leftmostLeaf walk a flat node to itself" {
    const s = try JSString.init(testing.allocator, testing.allocator, "solo");
    defer s.deinit(testing.allocator, testing.allocator);
    try testing.expectEqual(s, s.rightmostLeaf());
    try testing.expectEqual(s, s.leftmostLeaf());
}

test "JSString: rightmostLeaf / leftmostLeaf walk a nested cons tree" {
    // ((a + b) + (c + d)) — leftmost leaf is `a`, rightmost is `d`.
    const a = try JSString.init(testing.allocator, testing.allocator, "a");
    const b = try JSString.init(testing.allocator, testing.allocator, "b");
    const c = try JSString.init(testing.allocator, testing.allocator, "c");
    const d = try JSString.init(testing.allocator, testing.allocator, "d");
    const heap = makeTestHeap();
    defer destroyTestHeap(heap);
    const ab = try makeConsForTest(heap, a, b);
    const cd = try makeConsForTest(heap, c, d);
    const root = try makeConsForTest(heap, ab, cd);

    try testing.expectEqual(a, root.leftmostLeaf());
    try testing.expectEqual(d, root.rightmostLeaf());

    root.deinit(testing.allocator, testing.allocator);
    ab.deinit(testing.allocator, testing.allocator);
    cd.deinit(testing.allocator, testing.allocator);
    a.deinit(testing.allocator, testing.allocator);
    b.deinit(testing.allocator, testing.allocator);
    c.deinit(testing.allocator, testing.allocator);
    d.deinit(testing.allocator, testing.allocator);
}

test "JSString: flatten a deep left-leaning rope (no stack overflow)" {
    // Build a strictly left-leaning spine of `max_rope_depth` cons
    // levels by hand — the shape a `result += chunk` loop produces.
    // `flatten` must walk it iteratively without overflowing.
    const heap = makeTestHeap();
    defer destroyTestHeap(heap);
    var leaves: [max_rope_depth + 1]*JSString = undefined;
    for (&leaves) |*slot| {
        slot.* = try JSString.init(testing.allocator, testing.allocator, "x");
    }
    var spine: *JSString = leaves[0];
    var built: [max_rope_depth]*JSString = undefined;
    var i: usize = 0;
    while (i < max_rope_depth) : (i += 1) {
        const node = try makeConsForTest(heap, spine, leaves[i + 1]);
        built[i] = node;
        spine = node;
    }
    try testing.expectEqual(@as(u16, max_rope_depth), spine.depth);

    const flat = try spine.flatten(testing.allocator);
    try testing.expectEqual(@as(usize, max_rope_depth + 1), flat.len);
    for (flat) |ch| try testing.expectEqual(@as(u8, 'x'), ch);

    // Tear down: the spine root now owns a flat buffer; the cons
    // nodes and leaves are still independent.
    for (built) |node| node.deinit(testing.allocator, testing.allocator);
    for (leaves) |leaf| leaf.deinit(testing.allocator, testing.allocator);
}
