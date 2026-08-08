//! Opt-in execution witness for Bistromath.
//!
//! The test262 differential must prove that at least one published T1 entry
//! was actually crossed.  Counting compilation attempts or installed code is
//! insufficient because a dispatch regression could leave the entire sweep
//! interpreted while preserving an identical pass set.

const std = @import("std");

pub const Stats = struct {
    enabled: bool = false,
    executed_entries: u64 = 0,
    /// Optional cross-heap witness used by hosts that create independent
    /// agent realms. The owner must keep the atomic alive until every realm
    /// carrying this pointer has stopped executing generated code.
    shared_entries: ?*std.atomic.Value(u64) = null,

    pub fn recordEntry(self: *Stats) void {
        if (!self.enabled) return;
        self.executed_entries +|= 1;
        if (self.shared_entries) |shared| incrementSaturating(shared);
    }

    /// Saturating aggregation for fixture heaps and test262 workers.
    pub fn merge(self: *Stats, other: Stats) void {
        self.enabled = self.enabled or other.enabled;
        self.executed_entries +|= other.executed_entries;
    }
};

fn incrementSaturating(counter: *std.atomic.Value(u64)) void {
    var current = counter.load(.monotonic);
    while (current != std.math.maxInt(u64)) {
        if (counter.cmpxchgWeak(current, current + 1, .monotonic, .monotonic)) |observed| {
            current = observed;
        } else return;
    }
}

test "Bistromath stats stay inert while disabled" {
    var stats: Stats = .{};
    stats.recordEntry();
    try std.testing.expectEqual(@as(u64, 0), stats.executed_entries);
}

test "Bistromath stats merge saturates executed entries" {
    var total: Stats = .{
        .enabled = true,
        .executed_entries = std.math.maxInt(u64) - 1,
    };
    total.merge(.{ .enabled = true, .executed_entries = 5 });
    try std.testing.expect(total.enabled);
    try std.testing.expectEqual(std.math.maxInt(u64), total.executed_entries);
}

test "Bistromath stats publish to a shared cross-heap witness" {
    var shared = std.atomic.Value(u64).init(0);
    var stats: Stats = .{ .enabled = true, .shared_entries = &shared };
    stats.recordEntry();
    try std.testing.expectEqual(@as(u64, 1), stats.executed_entries);
    try std.testing.expectEqual(@as(u64, 1), shared.load(.monotonic));
}
