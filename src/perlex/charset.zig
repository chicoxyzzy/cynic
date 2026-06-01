//! Code-point set algebra over inclusive ranges — the substrate for
//! the `/v` (UnicodeSets) extended character classes (§22.2.1
//! ClassSetExpression) and for complementing `\D`/`\W`/`\S`.
//!
//! A set is a `[]ClassRange` of inclusive `[lo, hi]` intervals. The
//! operations normalize their inputs (sort + merge touching/overlapping
//! intervals) so callers may pass raw, unsorted, overlapping ranges
//! (e.g. the operands collected by the parser). Every result is freshly
//! allocated from the supplied allocator and is itself normalized.

const std = @import("std");
const parser = @import("parser.zig");

pub const ClassRange = parser.Node.ClassRange;

/// The `/u`/`/v` code-point universe — CharacterComplement (§22.2.2.9.1
/// "all characters") ranges over [0, U+10FFFF], surrogates included.
pub const max_code_point: u21 = 0x10FFFF;

fn lessThan(_: void, a: ClassRange, b: ClassRange) bool {
    return a.lo < b.lo;
}

/// Sort by `lo` and merge overlapping or adjacent intervals into a
/// minimal, ascending, disjoint set. `hi + 1` is computed in u32 so a
/// range ending at U+10FFFF doesn't overflow.
pub fn normalize(a: std.mem.Allocator, ranges: []const ClassRange) std.mem.Allocator.Error![]ClassRange {
    if (ranges.len == 0) return a.alloc(ClassRange, 0);
    const sorted = try a.dupe(ClassRange, ranges);
    defer a.free(sorted);
    std.mem.sort(ClassRange, sorted, {}, lessThan);

    var out: std.ArrayListUnmanaged(ClassRange) = .empty;
    errdefer out.deinit(a);
    var cur = sorted[0];
    for (sorted[1..]) |r| {
        // Adjacent (`cur.hi + 1 == r.lo`) or overlapping → coalesce.
        if (@as(u32, r.lo) <= @as(u32, cur.hi) + 1) {
            if (r.hi > cur.hi) cur.hi = r.hi;
        } else {
            try out.append(a, cur);
            cur = r;
        }
    }
    try out.append(a, cur);
    return out.toOwnedSlice(a);
}

/// [0, U+10FFFF] minus the set.
pub fn complement(a: std.mem.Allocator, ranges: []const ClassRange) std.mem.Allocator.Error![]ClassRange {
    const norm = try normalize(a, ranges);
    defer a.free(norm);

    var out: std.ArrayListUnmanaged(ClassRange) = .empty;
    errdefer out.deinit(a);
    var next: u32 = 0;
    for (norm) |r| {
        if (r.lo > next) try out.append(a, .{ .lo = @intCast(next), .hi = r.lo - 1 });
        next = @as(u32, r.hi) + 1;
    }
    if (next <= max_code_point) try out.append(a, .{ .lo = @intCast(next), .hi = max_code_point });
    return out.toOwnedSlice(a);
}

/// x ∪ y.
pub fn unionRanges(a: std.mem.Allocator, x: []const ClassRange, y: []const ClassRange) std.mem.Allocator.Error![]ClassRange {
    var both = try a.alloc(ClassRange, x.len + y.len);
    defer a.free(both);
    @memcpy(both[0..x.len], x);
    @memcpy(both[x.len..], y);
    return normalize(a, both);
}

/// x ∩ y, by a merge over the two normalized sets.
pub fn intersect(a: std.mem.Allocator, x: []const ClassRange, y: []const ClassRange) std.mem.Allocator.Error![]ClassRange {
    const nx = try normalize(a, x);
    defer a.free(nx);
    const ny = try normalize(a, y);
    defer a.free(ny);

    var out: std.ArrayListUnmanaged(ClassRange) = .empty;
    errdefer out.deinit(a);
    var i: usize = 0;
    var j: usize = 0;
    while (i < nx.len and j < ny.len) {
        const lo = @max(nx[i].lo, ny[j].lo);
        const hi = @min(nx[i].hi, ny[j].hi);
        if (lo <= hi) try out.append(a, .{ .lo = lo, .hi = hi });
        // Advance whichever range ends first.
        if (nx[i].hi < ny[j].hi) i += 1 else j += 1;
    }
    return out.toOwnedSlice(a);
}

/// x ∖ y, i.e. the elements of x not in y (= x ∩ ∁y).
pub fn subtract(a: std.mem.Allocator, x: []const ClassRange, y: []const ClassRange) std.mem.Allocator.Error![]ClassRange {
    const cy = try complement(a, y);
    defer a.free(cy);
    return intersect(a, x, cy);
}

const testing = std.testing;

fn expectRanges(got: []const ClassRange, want: []const ClassRange) !void {
    try testing.expectEqual(want.len, got.len);
    for (want, got) |w, g| {
        try testing.expectEqual(w.lo, g.lo);
        try testing.expectEqual(w.hi, g.hi);
    }
}

test "charset: normalize sorts and merges adjacent/overlapping" {
    const in = [_]ClassRange{ .{ .lo = 5, .hi = 7 }, .{ .lo = 0, .hi = 2 }, .{ .lo = 3, .hi = 4 }, .{ .lo = 6, .hi = 9 } };
    const got = try normalize(testing.allocator, &in);
    defer testing.allocator.free(got);
    try expectRanges(got, &.{.{ .lo = 0, .hi = 9 }});
}

test "charset: complement of [0-9]" {
    const in = [_]ClassRange{.{ .lo = '0', .hi = '9' }};
    const got = try complement(testing.allocator, &in);
    defer testing.allocator.free(got);
    try expectRanges(got, &.{ .{ .lo = 0, .hi = '0' - 1 }, .{ .lo = '9' + 1, .hi = max_code_point } });
}

test "charset: intersect" {
    const x = [_]ClassRange{.{ .lo = '0', .hi = '9' }};
    const y = [_]ClassRange{.{ .lo = '4', .hi = '8' }};
    const got = try intersect(testing.allocator, &x, &y);
    defer testing.allocator.free(got);
    try expectRanges(got, &.{.{ .lo = '4', .hi = '8' }});
}

test "charset: subtract carves a hole" {
    const x = [_]ClassRange{.{ .lo = '0', .hi = '9' }};
    const y = [_]ClassRange{.{ .lo = '3', .hi = '5' }};
    const got = try subtract(testing.allocator, &x, &y);
    defer testing.allocator.free(got);
    try expectRanges(got, &.{ .{ .lo = '0', .hi = '2' }, .{ .lo = '6', .hi = '9' } });
}

test "charset: self-difference is empty" {
    const x = [_]ClassRange{.{ .lo = '0', .hi = '9' }};
    const got = try subtract(testing.allocator, &x, &x);
    defer testing.allocator.free(got);
    try testing.expectEqual(@as(usize, 0), got.len);
}
