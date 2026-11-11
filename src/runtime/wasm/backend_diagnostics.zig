//! Bounded, allocation-free compile-refusal diagnostics for the shared tier.
const std = @import("std");

pub const Stage = enum { cache, lowering, compilation };
pub const Site = struct { offset: u32, opcode: u8, subopcode: ?u32 = null };
pub const Lowering = struct { site: ?Site = null };
pub const Key = struct {
    stage: Stage,
    reason: anyerror,
    opcode: ?u8 = null,
    subopcode: ?u32 = null,
};

pub const Refusals = struct {
    pub const capacity = 32;
    pub const Entry = struct {
        key: Key = .{ .stage = .lowering, .reason = error.UnsupportedOpcode },
        count: u64 = 0,
    };
    entries: [capacity]Entry = @splat(.{}),
    other: u64 = 0,

    pub fn record(self: *Refusals, key: Key, count: u64) void {
        if (count == 0) return;
        for (&self.entries) |*entry| {
            if (entry.count == 0) {
                entry.* = .{ .key = key, .count = count };
                return;
            }
            if (std.meta.eql(entry.key, key)) {
                entry.count +|= count;
                return;
            }
        }
        self.other +|= count;
    }

    pub fn add(self: *Refusals, other: *const Refusals) void {
        for (other.entries) |entry| self.record(entry.key, entry.count);
        self.other +|= other.other;
    }
};
