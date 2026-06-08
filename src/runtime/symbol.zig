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
    /// Optional description supplied to `Symbol(desc)`. Owned by
    /// the Symbol itself — duplicated into allocator memory at
    /// `init` and freed in `deinit`. It used to borrow a slice
    /// from a heap `JSString`, but `markValue` only sets a
    /// Symbol's mark bit (Symbols are leaves) and never traced
    /// that backing string, so a GC swept it and the description
    /// dangled — observed as garbled `String(symbol)` output.
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
    /// Permanently-live: never collected, never needs marking.
    /// Set on registered symbols (`Symbol.for("k")`) — §20.4.2.2
    /// GlobalSymbolRegistry has no spec'd eviction path, so a
    /// registered symbol is a strong root for the realm's lifetime.
    /// The sweep skips pinned symbols (same mechanism as chunk-
    /// constant strings); `isWeakReferentLive` short-circuits on
    /// pinned so `WeakRef(Symbol.for("k"))` keeps observing it
    /// even when its `mark_color` is stale.
    pinned: bool = false,
    /// Mark color. `sym.mark_color == heap.live_color` means "live
    /// this cycle". See `JSObject.mark_color` for the protocol.
    mark_color: u1 = 0,
    /// Generational-GC age. Fresh allocations start `.young`; a
    /// young symbol surviving a `collectYoung` is promoted to
    /// `.mature` and relinked into the mature list.
    generation: @import("heap.zig").Generation = .young,
    /// Set when this symbol is a known mature→young store source
    /// (in the heap's dirty-container list). Symbols are immutable
    /// so this stays `false`; the field keeps headers uniform.
    dirty: bool = false,

    pub fn init(allocator: std.mem.Allocator, description: ?[]const u8, prop_key: []const u8) !*JSSymbol {
        // Own the description: duplicate it so its lifetime is the
        // Symbol's, not some heap string the GC may reclaim.
        const owned_desc: ?[]const u8 = if (description) |d| try allocator.dupe(u8, d) else null;
        errdefer if (owned_desc) |d| allocator.free(d);
        const s = try allocator.create(JSSymbol);
        s.* = .{ .description = owned_desc, .prop_key = prop_key };
        return s;
    }

    pub fn deinit(self: *JSSymbol, allocator: std.mem.Allocator) void {
        if (self.description) |d| allocator.free(d);
        allocator.free(self.prop_key);
        allocator.destroy(self);
    }
};
