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
const build_options = @import("build_options");

/// Property-key interning (atoms) — Phase 1. See docs/interned-keys.md.
/// When `intern_keys` is on, each shape node carries the canonical
/// interned-atom identity for its key alongside the key bytes, so
/// `lookup` collapses the per-node `std.mem.eql` to a pointer compare
/// for static (compile-time-constant) property names. When off the
/// field is a zero-size `void`, so the shape layout — and every
/// existing byte-compare path — is unchanged.
pub const intern_keys = build_options.intern_keys;

/// Identity token for a key's canonical interned atom. It is an opaque
/// pointer (the atom is a pinned `*JSString`, but the shape only needs
/// pointer identity, so it stays type-erased to avoid a string.zig
/// import cycle). `null` means the key has no atom — a computed or
/// otherwise non-interned key, which keeps the byte-compare path.
pub const AtomId = if (intern_keys) ?*anyopaque else void;
pub const atom_none: AtomId = if (intern_keys) null else {};

/// Build an `AtomId` from a canonical atom pointer (or null). Type-
/// erases the pointer and collapses to a zero-size `void` when
/// interning is off, so call sites stay uniform across both build
/// flavours. The pointer MUST be canonical (from `Heap.internLookup`
/// / `internProperty`) — see `Shape.lookupAtom`.
pub inline fn atomId(p: ?*anyopaque) AtomId {
    return if (intern_keys) p else {};
}

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
    /// Canonical interned-atom identity for `key` (or `null` for a
    /// non-interned / computed key); a zero-size `void` when
    /// `intern_keys` is off. See `lookupAtom`.
    key_atom: AtomId = atom_none,
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
        key_atom: AtomId = atom_none,
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
        return self.lookupAtom(key, atom_none);
    }

    /// `lookup`, accelerated by atom identity. `atom`, when non-null,
    /// MUST be the canonical interned atom for `key` (obtained from
    /// `Heap.internLookup` / `internProperty`). Canonicality is the
    /// load-bearing invariant: the table holds exactly one atom per
    /// byte string, so two distinct non-null atoms always denote
    /// distinct keys — that is what lets a per-node compare reduce to
    /// a pointer compare and skip `std.mem.eql`. If EITHER side lacks
    /// an atom (this `atom` is null, or the node was built on the byte
    /// path), the node falls back to a byte compare, so non-interned,
    /// computed, and mixed-provenance keys stay correct. Passing a
    /// non-canonical pointer as `atom` is a contract violation that
    /// would make the fast path miss a real match.
    pub fn lookupAtom(self: *const Shape, key: []const u8, atom: AtomId) ?Entry {
        var node: ?*const Shape = self;
        while (node) |n| : (node = n.parent) {
            if (n.parent == null) break; // root adds no property
            if (intern_keys) {
                if (atom != null and n.key_atom != null) {
                    if (n.key_atom == atom) {
                        return .{ .slot = n.slot, .attrs = n.attrs, .kind = n.kind };
                    }
                    // Both sides canonical atoms with distinct
                    // identity ⇒ distinct key bytes. Skip `eql`.
                    continue;
                }
            }
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
        return self.transitionAtom(from, key, attrs, kind, atom_none);
    }

    /// `transition`, recording the canonical interned `atom` for `key`
    /// on the new (or matched) node so a later `lookupAtom` can
    /// pointer-compare. `atom` must be `key`'s canonical atom or null
    /// (see `lookupAtom`). The forward-transition cache scan uses the
    /// same atom-identity fast path. The key bytes are still duped into
    /// the realm arena and kept as the byte-compare fallback, so a
    /// later lookup with a null atom (a computed key with the same
    /// bytes) still resolves.
    pub fn transitionAtom(
        self: *ShapeTree,
        from: *Shape,
        key: []const u8,
        attrs: PropertyFlags,
        kind: PropKind,
        atom: AtomId,
    ) !*Shape {
        for (from.transitions.items) |t| {
            if (t.kind == kind and flagsEql(t.attrs, attrs)) {
                if (intern_keys) {
                    if (atom != null and t.key_atom != null) {
                        if (t.key_atom == atom) return t.child;
                        // Distinct canonical atoms ⇒ distinct keys.
                        continue;
                    }
                }
                if (std.mem.eql(u8, t.key, key)) return t.child;
            }
        }
        const a = self.arena.allocator();
        const owned_key = try a.dupe(u8, key);
        const child = try a.create(Shape);
        child.* = .{
            .parent = from,
            .key = owned_key,
            .key_atom = atom,
            .attrs = attrs,
            .kind = kind,
            .slot = from.property_count,
            .property_count = from.property_count + 1,
            .transitions = .empty,
        };
        try from.transitions.append(a, .{
            .key = owned_key,
            .key_atom = atom,
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

// Property-key interning (atoms) — Phase 1. These exercise
// `lookupAtom` / `transitionAtom` and compile under both `intern_keys`
// states: with the flag off the atom args are zero-size `void` and
// every assertion resolves through the byte-compare fallback (the
// transparency property at the shape layer). `@ptrFromInt` tokens stand
// in for canonical atoms — distinct pointer per byte string, never
// dereferenced (only identity-compared).
test "lookupAtom: atom identity resolves; byte fallback still works" {
    var tree = try ShapeTree.init(testing.allocator);
    defer tree.deinit();
    const ax: AtomId = if (intern_keys) @ptrFromInt(0x1001) else {};
    const ay: AtomId = if (intern_keys) @ptrFromInt(0x1002) else {};
    const az: AtomId = if (intern_keys) @ptrFromInt(0x1003) else {};

    const s1 = try tree.transitionAtom(tree.root, "x", .{}, .data, ax);
    const s2 = try tree.transitionAtom(s1, "y", .{}, .data, ay);

    // Atom-identity hit (byte hit when the flag is off).
    try testing.expectEqual(@as(u32, 0), s2.lookupAtom("x", ax).?.slot);
    try testing.expectEqual(@as(u32, 1), s2.lookupAtom("y", ay).?.slot);
    // A canonical atom for an absent key resolves to null.
    try testing.expect(s2.lookupAtom("z", az) == null);
    // Byte fallback: a null atom (computed key) with matching bytes
    // still resolves against an atom-built node.
    try testing.expectEqual(@as(u32, 0), s2.lookupAtom("x", atom_none).?.slot);
    try testing.expect(s2.lookupAtom("z", atom_none) == null);
    // `lookup` (the byte entry point) sees the atom-built nodes too.
    try testing.expectEqual(@as(u32, 1), s2.lookup("y").?.slot);

    // Shared-shape convergence holds with atoms: same atom + bytes +
    // attrs reach one shape.
    const s2b = try tree.transitionAtom(
        try tree.transitionAtom(tree.root, "x", .{}, .data, ax),
        "y",
        .{},
        .data,
        ay,
    );
    try testing.expectEqual(s2, s2b);
}

test "lookupAtom: byte-built node resolves under an atom lookup" {
    var tree = try ShapeTree.init(testing.allocator);
    defer tree.deinit();
    const ax: AtomId = if (intern_keys) @ptrFromInt(0x2001) else {};
    // Node built on the byte path (no atom) — e.g. defineProperty /
    // promoteToShape. A later atom lookup must still resolve it via the
    // byte fallback (`n.key_atom == null` forces the eql compare).
    const s1 = try tree.transition(tree.root, "x", .{}, .data);
    try testing.expectEqual(@as(u32, 0), s1.lookupAtom("x", ax).?.slot);
    // And an atom-store onto the same byte-built edge converges.
    const s1b = try tree.transitionAtom(tree.root, "x", .{}, .data, ax);
    try testing.expectEqual(s1, s1b);
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
