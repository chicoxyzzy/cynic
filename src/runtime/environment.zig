//! Declarative Environment Record (§9.1.1.1) — Cynic's runtime
//! representation of a lexical scope's named bindings.
//!
//! later puts every named binding (params, `var`, `let`, `const`,
//! function declarations) into an `Environment`. Functions capture
//! the surrounding `Environment` at `MakeFunction` time and, on
//! invocation, build a child `Environment` for their own bindings
//! chained through the captured one. Cross-frame variable access
//! walks this chain at runtime.
//!
//! Performance note: this is the simple "everything-on-the-heap"
//! scheme. Escape analysis (M5+) will promote non-captured locals
//! back to register slots; the compiler already keeps temporary
//! values in the register file, so only named bindings pay the
//! heap-deref cost.
//!
//! Mark-sweep tracked alongside `JSString` and `JSFunction`. The
//! parent pointer is followed during marking to keep the whole
//! lexical chain alive while any captured function is reachable.

const std = @import("std");

const Value = @import("value.zig").Value;

pub const Environment = struct {
    /// Outer environment in the lexical chain. `null` for the
    /// outermost (script) environment.
    parent: ?*Environment,
    /// Named-binding slots. Indexing is fixed at compile time;
    /// the slot count is part of the chunk's `MakeEnvironment`
    /// instruction.
    slots: []Value,
    /// Mark color. `env.mark_color == heap.live_color` means "live
    /// this cycle". See `JSObject.mark_color` for the protocol.
    mark_color: u1 = 0,
    /// Generational-GC age. Fresh allocations start `.young`; a
    /// young environment surviving a `collectYoung` is promoted to
    /// `.mature` and relinked into the mature list.
    generation: @import("heap.zig").Generation = .young,
    /// Set when this environment is in the heap's remembered set
    /// as a known old→young store source.
    in_remembered_set: bool = false,

    pub fn init(allocator: std.mem.Allocator, parent: ?*Environment, slot_count: u8) !*Environment {
        const env = try allocator.create(Environment);
        const slots = try allocator.alloc(Value, slot_count);
        // Bindings begin as the TDZ Hole — `let` / `const` reads
        // before the initialiser runs throw. The compiler emits
        // `Sta` for `var` / function-decl bindings to overwrite
        // the Hole with `undefined` / the function value at the
        // moment of declaration.
        @memset(slots, Value.hole_);
        env.* = .{
            .parent = parent,
            .slots = slots,
        };
        return env;
    }

    pub fn deinit(self: *Environment, allocator: std.mem.Allocator) void {
        allocator.free(self.slots);
        allocator.destroy(self);
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "Environment: init / deinit allocates Hole-filled slots" {
    const env = try Environment.init(testing.allocator, null, 3);
    defer env.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 3), env.slots.len);
    for (env.slots) |s| try testing.expect(s.isHole());
    try testing.expect(env.parent == null);
}

test "Environment: parent pointer round-trip" {
    const outer = try Environment.init(testing.allocator, null, 1);
    defer outer.deinit(testing.allocator);
    const inner = try Environment.init(testing.allocator, outer, 2);
    defer inner.deinit(testing.allocator);
    try testing.expect(inner.parent.? == outer);
}

test "Environment: slots are mutable" {
    const env = try Environment.init(testing.allocator, null, 2);
    defer env.deinit(testing.allocator);
    env.slots[0] = Value.fromInt32(42);
    env.slots[1] = Value.true_;
    try testing.expectEqual(@as(i32, 42), env.slots[0].asInt32());
    try testing.expect(env.slots[1].asBool());
}
