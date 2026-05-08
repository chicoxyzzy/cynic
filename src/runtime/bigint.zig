//! `JSBigInt` — arbitrary-precision integer primitive (§6.1.6.2).
//!
//! later uses an `i128` backing for simplicity — covers the
//! overwhelming majority of test262 BigInt fixtures (which fit
//! easily within 128 bits) without the bookkeeping of true
//! variable-length integers. Real arbitrary-precision (via
//! `std.math.big.int.Managed`) is later.
//!
//! Identity is by-value, NOT by-pointer (§7.2.13 IsLooselyEqual
//! step 8 + SameValue rules treat BigInts numerically). Two
//! `1n` literals compare strict-equal even if allocated as
//! distinct heap entries.
//!
//! Encoding: pointer-tagged in the NaN-boxed `Value` via the
//! `tag_object` value-tag plus a 3-bit pointer-tag (`0b11`)
//! to distinguish from JSFunction (`0b00`) / JSObject (`0b01`)
//! / JSSymbol (`0b10`). See heap.zig for the full layout.

const std = @import("std");

const HeapKind = @import("function.zig").HeapKind;

pub const JSBigInt = struct {
    /// Discriminator — must remain the first field. Mirrors the
    /// shape of `JSFunction` / `JSObject` / `JSSymbol`.
    kind: HeapKind = .bigint,
    /// Backing integer. later caps at i128; tests that
    /// require larger magnitudes will throw on overflow.
    value: i128,
    /// Mark-sweep bit, written by `Heap.markValue`.
    marked: bool = false,

    pub fn init(allocator: std.mem.Allocator, value: i128) !*JSBigInt {
        const b = try allocator.create(JSBigInt);
        b.* = .{ .value = value };
        return b;
    }

    pub fn deinit(self: *JSBigInt, allocator: std.mem.Allocator) void {
        allocator.destroy(self);
    }
};
