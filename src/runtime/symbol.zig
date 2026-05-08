//! `JSSymbol` — Cynic's primitive Symbol (§20.4).
//!
//! Each `JSSymbol` is a unique value. Identity is by pointer; two
//! `Symbol("x")` calls produce distinct symbols even though their
//! descriptions match. `Symbol.for(k)` interns into a per-realm
//! registry so `Symbol.for("k") === Symbol.for("k")`.
//!
//! Cynic encodes Symbols in the NaN-boxed `Value` via the
//! "tag_object" tag plus a two-bit pointer-tag (`0b10`) to
//! distinguish them from JSFunction (`0b00`) and JSObject
//! (`0b01`). See heap.zig for the bit layout.
//!
//! Spec anchors: §20.4 Symbol Objects, §6.1.5 Symbol type.

const std = @import("std");

const Value = @import("value.zig").Value;
const HeapKind = @import("function.zig").HeapKind;

pub const JSSymbol = struct {
    /// Discriminator — must remain the first field. Mirrors the
    /// `kind` field on `JSFunction` / `JSObject` so a heap walk
    /// can read the leading byte if it ever needs to determine
    /// the variant from a raw pointer (currently the
    /// pointer-tag bit suffices and `kind` is informational).
    kind: HeapKind = .symbol,
    /// Optional description supplied to `Symbol(desc)`. Owned
    /// by the heap's strings list (interned through allocation;
    /// no per-Symbol allocation).
    description: ?[]const u8,
    /// Stable property-key string used when this Symbol is the
    /// computed-key argument to `obj[sym]`. For well-known
    /// symbols this is the conventional `@@iterator` / `@@match`
    /// / etc. — so existing intrinsics installations under those
    /// string keys keep working. For user-created symbols this
    /// is a unique pointer-derived synthetic key (e.g.
    /// `<sym:0x12345678>`) so two `Symbol("k")` calls never
    /// collide. Owned by the realm's allocator (heap strings
    /// list); lifetime is the realm's.
    prop_key: []const u8,
    /// Whether this symbol was registered via `Symbol.for(k)` —
    /// `Symbol.keyFor(s)` consults this. Plain `Symbol(desc)`
    /// produces non-registered symbols.
    is_registered: bool = false,
    /// Mark-sweep bit, written by `Heap.markValue` and cleared
    /// after each sweep.
    marked: bool = false,

    pub fn init(allocator: std.mem.Allocator, description: ?[]const u8, prop_key: []const u8) !*JSSymbol {
        const s = try allocator.create(JSSymbol);
        s.* = .{ .description = description, .prop_key = prop_key };
        return s;
    }

    pub fn deinit(self: *JSSymbol, allocator: std.mem.Allocator) void {
        allocator.free(self.prop_key);
        allocator.destroy(self);
    }
};
