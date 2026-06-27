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
    attrs: PropertyFlags,
    kind: PropKind,
    /// Index into `JSObject.slots` where this property's value
    /// lives. Stable for the life of the shape.
    slot: u32,
    /// Number of own properties this shape describes — also the
    /// slot count an object of this shape needs.
    property_count: u32,
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

    /// Resolve own property `key` by walking the transition chain
    /// to the root. O(depth in the chain); an inline cache keyed
    /// on the shape collapses the hot path to O(1).
    pub fn lookup(self: *const Shape, key: []const u8) ?Entry {
        var node: ?*const Shape = self;
        while (node) |n| : (node = n.parent) {
            if (n.parent == null) break; // root adds no property
            if (std.mem.eql(u8, n.key, key)) {
                return .{ .slot = n.slot, .attrs = n.attrs, .kind = n.kind };
            }
        }
        return null;
    }
};

fn flagsEql(a: PropertyFlags, b: PropertyFlags) bool {
    return a.writable == b.writable and
        a.enumerable == b.enumerable and
        a.configurable == b.configurable;
}

/// Owns one realm's transition tree: the root shape plus the arena
/// every `Shape` (and its duped key bytes) is allocated from.
pub const ShapeTree = struct {
    arena: std.heap.ArenaAllocator,
    root: *Shape,

    pub fn init(backing: std.mem.Allocator) !ShapeTree {
        var arena = std.heap.ArenaAllocator.init(backing);
        errdefer arena.deinit();
        const root = try arena.allocator().create(Shape);
        root.* = .{
            .parent = null,
            .key = "",
            .attrs = .{},
            .kind = .data,
            .slot = 0,
            .property_count = 0,
            .transitions = .empty,
        };
        return .{ .arena = arena, .root = root };
    }

    pub fn deinit(self: *ShapeTree) void {
        self.arena.deinit();
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
            .attrs = attrs,
            .kind = kind,
            .slot = from.property_count,
            .property_count = from.property_count + 1,
            .transitions = .empty,
        };
        try from.transitions.append(a, .{
            .key = owned_key,
            .attrs = attrs,
            .kind = kind,
            .child = child,
        });
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
            .attrs = attrs,
            .kind = .data,
            .slot = existing.slot,
            .property_count = from.property_count,
            .transitions = .empty,
        };
        try from.transitions.append(a, .{
            .key = owned_key,
            .attrs = attrs,
            .kind = .data,
            .child = child,
        });
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
