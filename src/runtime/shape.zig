//! Property shapes — transition-tree object layout (a.k.a. hidden
//! classes / structures). A `Shape` describes the ordered set of
//! own named properties an object has: each node adds exactly one
//! property to its parent, so the chain root → … → S enumerates an
//! object's properties in insertion order — the §10.1.11
//! OrdinaryOwnPropertyKeys order for the string-keyed part.
//!
//! Design — Self / V8 lineage (Chambers & Ungar; see ARCHITECTURE.md):
//! `Shape = (parent, key, attrs, slot)` transition nodes with a
//! per-node forward-transition cache, so two objects built by the
//! same sequence of property additions share one `Shape`. That
//! shared identity is what an inline cache guards on — a single
//! pointer compare in place of a hashtable lookup.
//!
//! Shapes are realm-lifetime: allocated from an arena, never
//! collected individually, freed wholesale with the realm. The
//! transition tree only grows; a pathological property-churn
//! workload is bounded by demoting the *object* to dictionary mode
//! (a plain hash map), not by collecting shapes.
//!
//! This module is the data structure only. Wiring it into
//! `JSObject` storage is a separate step.

const std = @import("std");
const PropertyFlags = @import("object.zig").PropertyFlags;

/// Whether a shape slot holds a plain data value or an accessor
/// (getter/setter) pair. Distinguishing them at the shape level
/// keeps a data-property inline cache from firing on an accessor.
pub const PropKind = enum(u1) { data, accessor };

/// Chains shorter than this stay on the plain linear walk — a
/// few `mem.eql`s beat a hash + probe at low depth. V8 cuts over
/// from linear DescriptorArray search at 8 descriptors, but its
/// keys are interned Names with a *cached* hash; Cynic hashes the
/// key bytes on every probe (atom interning was a measured
/// dead-end — docs/interned-keys.md §11), which moves the
/// break-even up. Measured on this codebase: indexing depth-8-12
/// chains regressed deltablue ~9% (the probe's Wyhash matches the
/// short walk it replaces, and the anchor bookkeeping taxes every
/// lookup), while the depth-25+ global-object chain won ~30%
/// (string_concat). 16 keeps both.
pub const index_min_depth: u32 = 16;

/// Don't bother building a leaf index when the un-indexed tail
/// above the nearest indexed ancestor is this short — the tail
/// scan is already cheap and the ancestor probe does the rest.
pub const index_min_tail: u32 = 4;

/// Index-memory budget (in table slots) that lazy builds may
/// consume freely: `base + per_node × node_count`. Within the
/// budget every slow-lookup-hit shape gets its own index (tail
/// collapses to zero); past it, only the geometric
/// distance-doubling rule below builds, so total index memory
/// stays O(node_count) even under an adversarial
/// add-one-property-then-lookup loop (the never-unbounded-growth
/// contract, docs/handbook/host-safety.md).
pub const index_budget_base: u64 = 64;
pub const index_budget_per_node: u64 = 8;

/// Shapes wider than this never get an index (the table would be
/// multi-MiB; a linear walk that long is a degenerate object the
/// caller should have demoted to dictionary mode anyway).
const index_max_indexed_props: u32 = 1 << 20;

pub inline fn hashKey(key: []const u8) u32 {
    return @truncate(std.hash.Wyhash.hash(0, key));
}

/// Tree-wide shared state: the (pointer-stable) arena every shape
/// and index is allocated from, plus the counters the index-budget
/// rule reads. One per `ShapeTree`, allocated from its own arena.
pub const ShapeCtx = struct {
    arena: *std.heap.ArenaAllocator,
    node_count: u64 = 0,
    index_slots_total: u64 = 0,
};

/// Open-addressed key→entry hash table over one shape's full
/// chain (self → root), replacing the O(depth) parent walk with
/// O(1) probes. Analogue of V8's hash-mode descriptor lookup /
/// JSC's `PropertyTable` / SpiderMonkey's `PropertyMap` table.
/// Immutable once published on the shape (shapes never change
/// after creation; descendants layer a linear tail on top).
/// Slots hold shape nodes — key, cached hash, slot, attrs, kind
/// all live on the node. Load factor ≤ ~0.5, so a probe always
/// terminates on an empty slot.
pub const KeyIndex = struct {
    slots: []?*const Shape,
    mask: u32,

    fn find(self: *const KeyIndex, key: []const u8, hash: u32) ?Shape.Entry {
        var i: u32 = hash & self.mask;
        while (self.slots[i]) |n| : (i = (i +% 1) & self.mask) {
            if (n.key_hash == hash and std.mem.eql(u8, n.key, key)) {
                return .{ .slot = n.slot, .attrs = n.attrs, .kind = n.kind };
            }
        }
        return null;
    }
};

/// A node in the transition tree. The root (`parent == null`)
/// describes the empty object; every other node adds exactly one
/// property — `key` with `attrs`/`kind` — at index `slot` to its
/// parent's layout.
pub const Shape = struct {
    parent: ?*Shape,
    /// The property this node adds to its parent. Empty for the
    /// root. Owned by the `ShapeTree` arena (duped on transition)
    /// so it outlives any caller's key buffer.
    key: []const u8,
    /// Wyhash of `key`, computed once at creation — feeds the
    /// `KeyIndex` build and the probe's early-out compare.
    key_hash: u32,
    attrs: PropertyFlags,
    kind: PropKind,
    /// Index into `JSObject.slots` where this property's value
    /// lives. Stable for the life of the shape.
    slot: u32,
    /// Number of own properties this shape describes — also the
    /// slot count an object of this shape needs.
    property_count: u32,
    /// Chain length from the root (root = 0). Counts redefine
    /// nodes too, so it can exceed `property_count`.
    depth: u32,
    /// Tree-shared arena + index-budget counters (see `ShapeCtx`).
    ctx: *ShapeCtx,
    /// Lazily-built key→entry hash table covering the FULL chain
    /// (this shape → root). Null until a slow lookup at this shape
    /// crosses the build thresholds; immutable once set.
    index: ?*KeyIndex,
    /// Forward-transition cache: the shapes reached by adding one
    /// more property to THIS shape. Append-only; scanned linearly
    /// — a given key is almost always added with a single
    /// (attrs, kind) combination, so the scan is over ~1 entry.
    transitions: std.ArrayListUnmanaged(Transition),

    pub const Transition = struct {
        key: []const u8,
        attrs: PropertyFlags,
        kind: PropKind,
        child: *Shape,
    };

    /// A resolved own-property lookup.
    pub const Entry = struct {
        slot: u32,
        attrs: PropertyFlags,
        kind: PropKind,
    };

    /// Resolve own property `key`. Chains shallower than
    /// `index_min_depth` take exactly the pre-index linear walk —
    /// one extra `depth` compare is the whole cost of the feature
    /// on small shapes (nearest node wins, which is what makes
    /// redefine transitions shadow their ancestor entry). Deep
    /// chains route to `lookupDeep`, which resolves through the
    /// lazily built `KeyIndex`. An inline cache keyed on the shape
    /// still collapses the hot monomorphic path to O(1) before any
    /// of this runs; the index is the megamorphic-miss path's
    /// rescue.
    pub fn lookup(self: *Shape, key: []const u8) ?Entry {
        if (self.depth >= index_min_depth) return self.lookupDeep(key);
        var node: *const Shape = self;
        while (true) {
            if (node.parent == null) return null; // root adds no property
            if (std.mem.eql(u8, node.key, key)) {
                return .{ .slot = node.slot, .attrs = node.attrs, .kind = node.kind };
            }
            node = node.parent.?;
        }
    }

    /// Deep-chain resolution: probe this shape's own index, else
    /// scan the un-indexed tail linearly (nearest-wins shadowing
    /// is preserved because the tail is scanned FIRST) and probe
    /// the nearest indexed ancestor. A lookup that paid for the
    /// whole tail tries to materialise a leaf index so the next
    /// one is a pure probe. Kept out of `lookup` so the shallow
    /// path stays tight in the i-cache.
    noinline fn lookupDeep(self: *Shape, key: []const u8) ?Entry {
        if (self.index) |idx| return idx.find(key, hashKey(key));
        var node: *Shape = self;
        var anchor: ?*Shape = null;
        var result: ?Entry = null;
        var walked_full_tail = true;
        while (true) {
            if (node.parent == null) break; // root adds no property
            if (node.index != null) {
                anchor = node;
                break;
            }
            if (std.mem.eql(u8, node.key, key)) {
                result = .{ .slot = node.slot, .attrs = node.attrs, .kind = node.kind };
                walked_full_tail = false;
                break;
            }
            node = node.parent.?;
        }
        // Only a lookup that paid for the whole un-indexed tail is
        // evidence this shape is hot enough to index. Build BEFORE
        // probing the ancestor so the fresh leaf index serves this
        // resolution too.
        if (walked_full_tail and self.maybeBuildIndex(if (anchor) |a| a.depth else 0)) {
            return self.index.?.find(key, hashKey(key));
        }
        if (anchor) |a| result = a.index.?.find(key, hashKey(key));
        return result;
    }

    /// Decide whether the walk `lookupDeep` just paid justifies
    /// materialising an index at this shape; returns true when one
    /// was built. Two throttles keep index memory O(node_count)
    /// under adversarial add-then-lookup loops
    /// (never-unbounded-growth, docs/handbook/host-safety.md): a
    /// tree-wide slot budget linear in the node count, and past it
    /// a geometric rule — only build when the un-indexed tail is
    /// more than half the chain, so index depths at least double
    /// along any path.
    fn maybeBuildIndex(self: *Shape, anchor_depth: u32) bool {
        const tail = self.depth - anchor_depth;
        if (tail < index_min_tail) return false;
        const cap = indexCapacity(self.property_count) orelse return false;
        const under_budget = self.ctx.index_slots_total + cap <=
            index_budget_base + index_budget_per_node * self.ctx.node_count;
        const geometric = 2 * @as(u64, tail) > self.depth;
        if (!under_budget and !geometric) return false;
        // OOM → skip the index; the linear walk stays correct.
        self.buildIndex(cap) catch return false;
        return self.index != null;
    }

    /// Power-of-two table size with load factor ≤ ~0.5. The chain
    /// holds exactly `property_count` distinct keys (appends add a
    /// new key; redefines re-add an existing one), so the table
    /// always keeps empty slots and probes terminate.
    fn indexCapacity(property_count: u32) ?u32 {
        if (property_count >= index_max_indexed_props) return null;
        const want = @max(16, (@as(u64, property_count) + 1) * 2);
        return @intCast(std.math.ceilPowerOfTwoAssert(u64, want));
    }

    fn buildIndex(self: *Shape, cap: u32) !void {
        const a = self.ctx.arena.allocator();
        const slots = try a.alloc(?*const Shape, cap);
        @memset(slots, null);
        const mask: u32 = cap - 1;
        var inserted: u32 = 0;
        // Walk self → root inserting each key once; the FIRST
        // (nearest) node wins, mirroring the linear walk's
        // shadowing order for redefine transitions.
        var node: ?*Shape = self;
        walk: while (node) |n| : (node = n.parent) {
            if (n.parent == null) break; // root adds no property
            var i: u32 = n.key_hash & mask;
            while (slots[i]) |occ| : (i = (i +% 1) & mask) {
                if (occ.key_hash == n.key_hash and std.mem.eql(u8, occ.key, n.key)) {
                    continue :walk; // nearer node already inserted
                }
            }
            // Defensive load-factor guard — unreachable while the
            // distinct-keys == property_count invariant holds, but
            // a full table would make `find` spin, so bail to the
            // linear walk instead.
            if (2 * (@as(u64, inserted) + 1) > cap) return;
            slots[i] = n;
            inserted += 1;
        }
        const idx = try a.create(KeyIndex);
        idx.* = .{ .slots = slots, .mask = mask };
        self.index = idx;
        self.ctx.index_slots_total += cap;
    }
};

fn flagsEql(a: PropertyFlags, b: PropertyFlags) bool {
    return a.writable == b.writable and
        a.enumerable == b.enumerable and
        a.configurable == b.configurable;
}

/// Owns one realm's transition tree: the root shape plus the arena
/// every `Shape` (and its duped key bytes) is allocated from. The
/// arena lives behind a stable heap pointer (not by value) so each
/// `Shape.ctx` can reach it for lazy `KeyIndex` builds even though
/// the `ShapeTree` struct itself moves by value into `Heap`.
pub const ShapeTree = struct {
    backing: std.mem.Allocator,
    arena: *std.heap.ArenaAllocator,
    ctx: *ShapeCtx,
    root: *Shape,

    pub fn init(backing: std.mem.Allocator) !ShapeTree {
        const arena = try backing.create(std.heap.ArenaAllocator);
        errdefer backing.destroy(arena);
        arena.* = std.heap.ArenaAllocator.init(backing);
        errdefer arena.deinit();
        const a = arena.allocator();
        const ctx = try a.create(ShapeCtx);
        ctx.* = .{ .arena = arena };
        const root = try a.create(Shape);
        root.* = .{
            .parent = null,
            .key = "",
            .key_hash = 0,
            .attrs = .{},
            .kind = .data,
            .slot = 0,
            .property_count = 0,
            .depth = 0,
            .ctx = ctx,
            .index = null,
            .transitions = .empty,
        };
        return .{ .backing = backing, .arena = arena, .ctx = ctx, .root = root };
    }

    pub fn deinit(self: *ShapeTree) void {
        self.arena.deinit();
        self.backing.destroy(self.arena);
    }

    /// Return the shape reached by adding (`key`, `attrs`, `kind`)
    /// to `from`. Reuses the cached child when the same property
    /// was added to `from` before, so structurally identical
    /// objects converge on one shared shape.
    pub fn transition(
        self: *ShapeTree,
        from: *Shape,
        key: []const u8,
        attrs: PropertyFlags,
        kind: PropKind,
    ) !*Shape {
        for (from.transitions.items) |t| {
            if (t.kind == kind and flagsEql(t.attrs, attrs) and
                std.mem.eql(u8, t.key, key))
            {
                return t.child;
            }
        }
        const a = self.arena.allocator();
        const owned_key = try a.dupe(u8, key);
        const child = try a.create(Shape);
        child.* = .{
            .parent = from,
            .key = owned_key,
            .key_hash = hashKey(owned_key),
            .attrs = attrs,
            .kind = kind,
            .slot = from.property_count,
            .property_count = from.property_count + 1,
            .depth = from.depth + 1,
            .ctx = self.ctx,
            .index = null,
            .transitions = .empty,
        };
        try from.transitions.append(a, .{
            .key = owned_key,
            .attrs = attrs,
            .kind = kind,
            .child = child,
        });
        self.ctx.node_count += 1;
        return child;
    }

    /// Return the shape reached by REDEFINING `key`'s attributes
    /// to `attrs` in `from` — same slot, same property count, new
    /// attrs shadowing the ancestor entry on the lookup walk. The
    /// SES freeze (§20.1.2.5 descriptor locking via hardenWalk)
    /// uses this to lock descriptors WITHOUT demoting the object
    /// to dictionary mode — the demote was what kept every IC on
    /// a frozen object (most visibly the global object's
    /// `lda_global` cells) permanently cold. Cached in the same
    /// per-node transition list as appends: a key present in
    /// `from` can never collide with an append edge, because no
    /// caller appends an existing key. Redefining to the attrs
    /// the shape already has is the identity; a missing or
    /// accessor-kind key returns `from` unchanged (defensive — the
    /// callers only pass shape-resident data keys).
    pub fn redefineTransition(
        self: *ShapeTree,
        from: *Shape,
        key: []const u8,
        attrs: PropertyFlags,
    ) !*Shape {
        const existing = from.lookup(key) orelse return from;
        if (existing.kind != .data) return from;
        if (flagsEql(existing.attrs, attrs)) return from;
        for (from.transitions.items) |t| {
            if (t.kind == .data and flagsEql(t.attrs, attrs) and
                std.mem.eql(u8, t.key, key))
            {
                return t.child;
            }
        }
        const a = self.arena.allocator();
        const owned_key = try a.dupe(u8, key);
        const child = try a.create(Shape);
        child.* = .{
            .parent = from,
            .key = owned_key,
            .key_hash = hashKey(owned_key),
            .attrs = attrs,
            .kind = .data,
            .slot = existing.slot,
            .property_count = from.property_count,
            .depth = from.depth + 1,
            .ctx = self.ctx,
            .index = null,
            .transitions = .empty,
        };
        try from.transitions.append(a, .{
            .key = owned_key,
            .attrs = attrs,
            .kind = .data,
            .child = child,
        });
        self.ctx.node_count += 1;
        return child;
    }
};

const testing = std.testing;

test "root shape describes the empty object" {
    var tree = try ShapeTree.init(testing.allocator);
    defer tree.deinit();
    try testing.expectEqual(@as(u32, 0), tree.root.property_count);
    try testing.expect(tree.root.lookup("x") == null);
}

test "transition adds a property at the next slot" {
    var tree = try ShapeTree.init(testing.allocator);
    defer tree.deinit();

    const s1 = try tree.transition(tree.root, "x", .{}, .data);
    try testing.expectEqual(@as(u32, 1), s1.property_count);
    try testing.expectEqual(@as(u32, 0), s1.lookup("x").?.slot);
    try testing.expect(s1.lookup("y") == null);

    const s2 = try tree.transition(s1, "y", .{}, .data);
    try testing.expectEqual(@as(u32, 2), s2.property_count);
    try testing.expectEqual(@as(u32, 0), s2.lookup("x").?.slot);
    try testing.expectEqual(@as(u32, 1), s2.lookup("y").?.slot);
}

test "structurally identical objects share a shape" {
    var tree = try ShapeTree.init(testing.allocator);
    defer tree.deinit();

    const a = try tree.transition(
        try tree.transition(tree.root, "x", .{}, .data),
        "y",
        .{},
        .data,
    );
    const b = try tree.transition(
        try tree.transition(tree.root, "x", .{}, .data),
        "y",
        .{},
        .data,
    );
    try testing.expectEqual(a, b);
}

test "differing attributes or kind fork the transition" {
    var tree = try ShapeTree.init(testing.allocator);
    defer tree.deinit();

    const data_default = try tree.transition(tree.root, "x", .{}, .data);
    const data_nonenum = try tree.transition(tree.root, "x", .{ .enumerable = false }, .data);
    const accessor = try tree.transition(tree.root, "x", .{}, .accessor);

    try testing.expect(data_default != data_nonenum);
    try testing.expect(data_default != accessor);
    try testing.expect(data_nonenum != accessor);

    // The cache still dedups within each variant.
    try testing.expectEqual(data_default, try tree.transition(tree.root, "x", .{}, .data));
    try testing.expectEqual(accessor, try tree.transition(tree.root, "x", .{}, .accessor));
}

test "redefine transition keeps slot and count, shadows attrs" {
    var tree = try ShapeTree.init(testing.allocator);
    defer tree.deinit();

    const s1 = try tree.transition(tree.root, "x", .{}, .data);
    const s2 = try tree.transition(s1, "y", .{}, .data);

    const frozen_attrs: PropertyFlags = .{ .writable = false, .enumerable = true, .configurable = false };
    const s3 = try tree.redefineTransition(s2, "x", frozen_attrs);

    // Same layout — no new slot, no count change.
    try testing.expectEqual(@as(u32, 2), s3.property_count);
    const e = s3.lookup("x").?;
    try testing.expectEqual(@as(u32, 0), e.slot);
    try testing.expect(!e.attrs.writable);
    try testing.expect(!e.attrs.configurable);
    // The sibling key is untouched.
    try testing.expectEqual(@as(u32, 1), s3.lookup("y").?.slot);
    try testing.expect(s3.lookup("y").?.attrs.writable);
}

test "redefine transition is cached and no-ops on same attrs" {
    var tree = try ShapeTree.init(testing.allocator);
    defer tree.deinit();

    const s1 = try tree.transition(tree.root, "x", .{}, .data);
    const frozen_attrs: PropertyFlags = .{ .writable = false, .enumerable = true, .configurable = false };
    const a = try tree.redefineTransition(s1, "x", frozen_attrs);
    const b = try tree.redefineTransition(s1, "x", frozen_attrs);
    try testing.expectEqual(a, b);
    // Redefining to the attrs the shape already has is the
    // identity.
    try testing.expectEqual(a, try tree.redefineTransition(a, "x", frozen_attrs));
}

test "lookup resolves attributes and kind, not just the slot" {
    var tree = try ShapeTree.init(testing.allocator);
    defer tree.deinit();

    const s = try tree.transition(tree.root, "m", .{ .enumerable = false }, .accessor);
    const e = s.lookup("m").?;
    try testing.expectEqual(@as(u32, 0), e.slot);
    try testing.expect(!e.attrs.enumerable);
    try testing.expectEqual(PropKind.accessor, e.kind);
}

// —— key→slot hash index (the O(depth)-walk killer) ——————————————

/// Build a linear chain of `n` data properties "p0" … "p{n-1}"
/// off the root, returning the leaf shape.
fn buildChain(tree: *ShapeTree, n: u32) !*Shape {
    var s = tree.root;
    var buf: [16]u8 = undefined;
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const key = try std.fmt.bufPrint(&buf, "p{d}", .{i});
        s = try tree.transition(s, key, .{}, .data);
    }
    return s;
}

test "deep shape builds a hash index on lookup and resolves through it" {
    var tree = try ShapeTree.init(testing.allocator);
    defer tree.deinit();

    const leaf = try buildChain(&tree, 20);
    try testing.expect(leaf.index == null);

    // A full-walk lookup (miss) at an index-eligible depth builds
    // the index lazily.
    try testing.expect(leaf.lookup("absent") == null);
    try testing.expect(leaf.index != null);

    // Every key resolves to the same slot the linear walk gave,
    // now via the index probe.
    var buf: [16]u8 = undefined;
    var i: u32 = 0;
    while (i < 20) : (i += 1) {
        const key = try std.fmt.bufPrint(&buf, "p{d}", .{i});
        const e = leaf.lookup(key).?;
        try testing.expectEqual(i, e.slot);
        try testing.expectEqual(PropKind.data, e.kind);
    }
    try testing.expect(leaf.lookup("still-absent") == null);
    try testing.expect(leaf.lookup("") == null);
}

test "shallow shapes never build an index" {
    var tree = try ShapeTree.init(testing.allocator);
    defer tree.deinit();

    const leaf = try buildChain(&tree, index_min_depth - 1);
    try testing.expect(leaf.lookup("absent") == null);
    try testing.expect(leaf.lookup("p0") != null);
    try testing.expect(leaf.index == null);
    try testing.expect(tree.root.lookup("x") == null);
    try testing.expect(tree.root.index == null);
}

test "redefine transition shadows correctly through the index" {
    var tree = try ShapeTree.init(testing.allocator);
    defer tree.deinit();

    // Redefine BELOW the index build point: freeze p3, then look up
    // at the leaf — the index must carry the redefined attrs, not
    // the original ancestor entry.
    const base = try buildChain(&tree, 18);
    const frozen: PropertyFlags = .{ .writable = false, .enumerable = true, .configurable = false };
    const leaf = try tree.redefineTransition(base, "p3", frozen);

    try testing.expect(leaf.lookup("absent") == null); // builds index
    try testing.expect(leaf.index != null);
    const e = leaf.lookup("p3").?;
    try testing.expectEqual(@as(u32, 3), e.slot);
    try testing.expect(!e.attrs.writable);
    try testing.expect(!e.attrs.configurable);
    // A sibling key is untouched.
    try testing.expect(leaf.lookup("p4").?.attrs.writable);
    // The ancestor's own index (if any) still answers the ORIGINAL
    // attrs at `base`.
    try testing.expect(base.lookup("p3").?.attrs.writable);
}

test "descendant reuses an ancestor's index through the tail walk" {
    var tree = try ShapeTree.init(testing.allocator);
    defer tree.deinit();

    const mid = try buildChain(&tree, 20);
    try testing.expect(mid.lookup("absent") == null); // builds at depth 20
    try testing.expect(mid.index != null);

    // Two more appends + one redefine: short tail above the anchor.
    var leaf = try tree.transition(mid, "q0", .{}, .data);
    leaf = try tree.transition(leaf, "q1", .{ .enumerable = false }, .data);
    const frozen: PropertyFlags = .{ .writable = false, .enumerable = true, .configurable = false };
    leaf = try tree.redefineTransition(leaf, "p5", frozen);

    // Tail keys (nearest) win; anchored keys resolve via the probe.
    try testing.expectEqual(@as(u32, 20), leaf.lookup("q0").?.slot);
    try testing.expect(!leaf.lookup("q1").?.attrs.enumerable);
    try testing.expect(!leaf.lookup("p5").?.attrs.writable); // tail redefine shadows index
    try testing.expectEqual(@as(u32, 0), leaf.lookup("p0").?.slot); // via ancestor index
    try testing.expect(leaf.lookup("absent") == null);
    // The short tail must NOT have built a fresh index at the leaf.
    try testing.expect(leaf.index == null);
}

test "accessor kind survives the index" {
    var tree = try ShapeTree.init(testing.allocator);
    defer tree.deinit();

    var s = try buildChain(&tree, 17);
    s = try tree.transition(s, "getterProp", .{ .enumerable = false }, .accessor);
    try testing.expect(s.lookup("absent") == null); // builds
    const e = s.lookup("getterProp").?;
    try testing.expectEqual(PropKind.accessor, e.kind);
    try testing.expect(!e.attrs.enumerable);
}

test "index memory stays linearly bounded under add+lookup alternation" {
    var tree = try ShapeTree.init(testing.allocator);
    defer tree.deinit();

    // Adversarial pattern from docs/handbook/host-safety.md's
    // never-unbounded-growth contract: interleave one property add
    // with one full-walk lookup, which would build an index at
    // EVERY shape without the budget + geometric throttles
    // (O(n²) slots). Pin the linear bound.
    var s = tree.root;
    var buf: [16]u8 = undefined;
    var i: u32 = 0;
    while (i < 400) : (i += 1) {
        const key = try std.fmt.bufPrint(&buf, "k{d}", .{i});
        s = try tree.transition(s, key, .{}, .data);
        try testing.expect(s.lookup("absent") == null);
        try testing.expect(s.lookup("k0") != null);
    }
    const bound = index_budget_base + (index_budget_per_node + 8) * tree.ctx.node_count;
    try testing.expect(tree.ctx.index_slots_total <= bound);
    // …and the index still answers correctly at the leaf.
    try testing.expectEqual(@as(u32, 399), s.lookup("k399").?.slot);
    try testing.expectEqual(@as(u32, 17), s.lookup("k17").?.slot);
}

test "hash collisions in the index still resolve by key bytes" {
    var tree = try ShapeTree.init(testing.allocator);
    defer tree.deinit();

    // With a 400-key chain the table has plenty of same-bucket
    // (masked) collisions; every key must still resolve to its own
    // slot via the linear probe + byte-compare confirm.
    const leaf = try buildChain(&tree, 400);
    try testing.expect(leaf.lookup("absent") == null); // builds
    try testing.expect(leaf.index != null);
    var buf: [16]u8 = undefined;
    var i: u32 = 0;
    while (i < 400) : (i += 1) {
        const key = try std.fmt.bufPrint(&buf, "p{d}", .{i});
        try testing.expectEqual(i, leaf.lookup(key).?.slot);
    }
}
