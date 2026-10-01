//! Module-aware type matching for the supported final function-type subset.
const std = @import("std");
const types = @import("types.zig");

pub const MatchError = error{ OutOfMemory, TypeComparisonLimit };
const max_pairs = 4096;
const max_values = 65536;
const Pair = struct { actual: u32, expected: u32 };

/// Core matching for the pre-GC subset: nullable widening and concrete
/// function refs below abstract func. Declared function types are final.
pub fn matchValueType(a: std.mem.Allocator, actual_types: []const types.FuncType, actual: types.ValType, expected_types: []const types.FuncType, expected: types.ValType) MatchError!bool {
    const ah = actual.heapOf() orelse return actual == expected;
    const eh = expected.heapOf() orelse return false;
    if (actual.isNullable() and !expected.isNullable()) return false;
    if (actual.concreteIndex()) |ai| {
        if (ai >= actual_types.len) return false;
        if (expected.concreteIndex()) |ei| return equivalentFunctionTypes(a, actual_types, ai, expected_types, ei);
        return eh == types.heap_abs_func;
    }
    return ah == eh;
}

/// Compare module-relative definitions without native recursion or an
/// attacker-sized unfolding. Explicit GC recursive groups/subtypes are not
/// decoded yet; each supported function type is a singleton final binder.
pub fn equivalentFunctionTypes(a: std.mem.Allocator, actual_types: []const types.FuncType, actual: u32, expected_types: []const types.FuncType, expected: u32) MatchError!bool {
    if (actual >= actual_types.len or expected >= expected_types.len) return false;
    if (actual_types.ptr == expected_types.ptr and actual == expected) return true;
    var matcher: Matcher = .{ .allocator = a, .actual = actual_types, .expected = expected_types };
    defer matcher.pending.deinit(a);
    defer matcher.seen.deinit(a);
    try matcher.enqueue(.{ .actual = actual, .expected = expected });
    var i: usize = 0;
    while (i < matcher.pending.items.len) : (i += 1) {
        const pair = matcher.pending.items[i];
        const lhs = actual_types[pair.actual];
        const rhs = expected_types[pair.expected];
        if (lhs.params.len != rhs.params.len or lhs.results.len != rhs.results.len) return false;
        for (lhs.params, rhs.params) |l, r| if (!try matcher.equalValue(pair, l, r)) return false;
        for (lhs.results, rhs.results) |l, r| if (!try matcher.equalValue(pair, l, r)) return false;
    }
    return true;
}

const Matcher = struct {
    allocator: std.mem.Allocator,
    actual: []const types.FuncType,
    expected: []const types.FuncType,
    pending: std.ArrayList(Pair) = .empty,
    seen: std.AutoHashMapUnmanaged(Pair, void) = .empty,
    remaining: usize = max_values,

    fn enqueue(self: *Matcher, pair: Pair) MatchError!void {
        if (self.seen.contains(pair)) return;
        if (self.pending.items.len == max_pairs) return error.TypeComparisonLimit;
        try self.seen.put(self.allocator, pair, {});
        try self.pending.append(self.allocator, pair);
    }

    fn equalValue(self: *Matcher, parent: Pair, l: types.ValType, r: types.ValType) MatchError!bool {
        if (self.remaining == 0) return error.TypeComparisonLimit;
        self.remaining -= 1;
        if (l.concreteIndex()) |li| {
            const ri = r.concreteIndex() orelse return false;
            if (l.isNullable() != r.isNullable() or li >= self.actual.len or ri >= self.expected.len) return false;
            // Rolled self references denote the current singleton binder,
            // not a structurally similar type outside it (Core type equality).
            if (li == parent.actual or ri == parent.expected)
                return li == parent.actual and ri == parent.expected;
            try self.enqueue(.{ .actual = li, .expected = ri });
            return true;
        }
        return l == r;
    }
};

test "typed reference matching: nested module-relative indices and nullability" {
    const a = [_]types.FuncType{
        .{ .params = &.{.i32}, .results = &.{.i32} },
        .{ .params = &.{types.ValType.refType(true, 0)}, .results = &.{} },
    };
    const b = [_]types.FuncType{
        .{ .params = &.{}, .results = &.{} },
        .{ .params = &.{.i32}, .results = &.{.i32} },
        .{ .params = &.{types.ValType.refType(true, 1)}, .results = &.{} },
    };
    try std.testing.expect(try equivalentFunctionTypes(std.testing.allocator, &a, 1, &b, 2));
    try std.testing.expect(!try equivalentFunctionTypes(std.testing.allocator, &a, 0, &b, 0));
    try std.testing.expect(try matchValueType(std.testing.allocator, &a, types.ValType.refType(false, 0), &b, types.ValType.refType(true, 1)));
    try std.testing.expect(!try matchValueType(std.testing.allocator, &a, types.ValType.refType(true, 0), &b, types.ValType.refType(false, 1)));
    try std.testing.expect(try matchValueType(std.testing.allocator, &a, types.ValType.refType(false, 0), &.{}, .funcref));
    try std.testing.expect(!try matchValueType(std.testing.allocator, &.{}, .funcref, &b, types.ValType.refType(true, 1)));
}

test "typed reference matching: singleton recursive binders remain distinct from outer references" {
    const a = [_]types.FuncType{.{ .params = &.{types.ValType.refType(true, 0)}, .results = &.{} }};
    const b = [_]types.FuncType{
        .{ .params = &.{}, .results = &.{} },
        .{ .params = &.{types.ValType.refType(true, 1)}, .results = &.{} },
        .{ .params = &.{types.ValType.refType(true, 1)}, .results = &.{} },
    };
    try std.testing.expect(try equivalentFunctionTypes(std.testing.allocator, &a, 0, &b, 1));
    try std.testing.expect(!try equivalentFunctionTypes(std.testing.allocator, &a, 0, &b, 2));
    try std.testing.expect(!try equivalentFunctionTypes(std.testing.allocator, &a, 9, &b, 1));
}

test "typed reference matching: attacker-sized type graphs have a bounded worklist" {
    const n = 5000;
    const refs = try std.testing.allocator.alloc(types.ValType, n);
    defer std.testing.allocator.free(refs);
    const a = try std.testing.allocator.alloc(types.FuncType, n);
    defer std.testing.allocator.free(a);
    const b = try std.testing.allocator.alloc(types.FuncType, n);
    defer std.testing.allocator.free(b);
    for (0..n) |i| {
        refs[i] = if (i + 1 < n) types.ValType.refType(true, @intCast(i + 1)) else .i32;
        a[i] = .{ .params = refs[i .. i + 1], .results = &.{} };
        b[i] = a[i];
    }
    try std.testing.expectError(error.TypeComparisonLimit, equivalentFunctionTypes(std.testing.allocator, a, 0, b, 0));
}

fn matchWithAllocationFailure(allocator: std.mem.Allocator) !void {
    const a = [_]types.FuncType{.{ .params = &.{.i32}, .results = &.{.i32} }};
    const b = [_]types.FuncType{ .{ .params = &.{}, .results = &.{} }, a[0] };
    try std.testing.expect(try equivalentFunctionTypes(allocator, &a, 0, &b, 1));
}

test "typed reference matching: allocation failures propagate without leaking" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, matchWithAllocationFailure, .{});
}
