//! Engine-level tests for Perlex — compile + exec + captures, with no
//! JS engine in the loop. The JS-visible behaviour is covered
//! end-to-end in `runtime/lantern/tests.zig`; these are the fast inner
//! loop and the differential reference for the matcher itself.

const std = @import("std");
const testing = std.testing;
const perlex = @import("perlex.zig");

const Outcome = union(enum) {
    /// Capture substrings joined by ',', mirroring `String(execResult)`
    /// (an unset capture contributes the empty string).
    match: []u8,
    no_match,
    unsupported,
    syntax_error,
};

/// Compile `pattern` and run it from offset 0 over an ASCII `input`,
/// instantiated at code-unit width `Unit` (`u8` or `u16`).
fn runUnit(comptime Unit: type, gpa: std.mem.Allocator, pattern: []const u8, input: []const u8) !Outcome {
    var res = try perlex.compile(gpa, pattern, .{});
    switch (res) {
        .unsupported => return .unsupported,
        .syntax_error => return .syntax_error,
        .ok => |*prog| {
            defer prog.deinit();
            const units = try gpa.alloc(Unit, input.len);
            defer gpa.free(units);
            for (input, 0..) |b, i| units[i] = @as(Unit, b);

            var m = (try perlex.exec(Unit, gpa, prog, units, 0)) orelse return .no_match;
            defer m.deinit(gpa);

            var out: std.ArrayListUnmanaged(u8) = .empty;
            errdefer out.deinit(gpa);
            var g: usize = 0;
            while (g < prog.group_count) : (g += 1) {
                if (g != 0) try out.append(gpa, ',');
                const cs = m.slots[2 * g];
                const ce = m.slots[2 * g + 1];
                if (cs != perlex.none and ce != perlex.none) {
                    for (units[cs..ce]) |u| try out.append(gpa, @intCast(u));
                }
            }
            return .{ .match = try out.toOwnedSlice(gpa) };
        },
    }
}

fn run(gpa: std.mem.Allocator, pattern: []const u8, input: []const u8) !Outcome {
    return runUnit(u16, gpa, pattern, input);
}

fn expectMatch(pattern: []const u8, input: []const u8, expected: []const u8) !void {
    const o = try run(testing.allocator, pattern, input);
    switch (o) {
        .match => |s| {
            defer testing.allocator.free(s);
            try testing.expectEqualStrings(expected, s);
        },
        else => return error.ExpectedMatch,
    }
}

fn expectNoMatch(pattern: []const u8, input: []const u8) !void {
    const o = try run(testing.allocator, pattern, input);
    if (o != .no_match) return error.ExpectedNoMatch;
}

fn expectCompile(pattern: []const u8, want: std.meta.Tag(Outcome)) !void {
    // Compile only; an empty input is enough to classify the outcome
    // for the syntax-error / unsupported cases.
    var res = try perlex.compile(testing.allocator, pattern, .{});
    switch (res) {
        .ok => |*prog| {
            prog.deinit();
            try testing.expect(want == .match);
        },
        .unsupported => try testing.expect(want == .unsupported),
        .syntax_error => try testing.expect(want == .syntax_error),
    }
}

// ── Plain matching sanity ───────────────────────────────────────────

test "perlex: literal sequence" {
    try expectMatch("abc", "abc", "abc");
    try expectNoMatch("abc", "abx");
}

test "perlex: leftmost scan finds a later start" {
    try expectMatch("bc", "abc", "bc");
}

test "perlex: alternation" {
    try expectMatch("a|b", "b", "b");
    try expectMatch("ab|cd", "cd", "cd");
}

test "perlex: capturing group substring" {
    try expectMatch("(?<a>ab)c", "abc", "abc,ab");
}

test "perlex: anchors are input-relative" {
    try expectMatch("^a$", "a", "a");
    try expectNoMatch("^a$", "ab");
    try expectNoMatch("^b", "ab");
}

test "perlex: exact {n} repetition" {
    try expectMatch("(?:ab){2}", "abab", "abab");
    try expectNoMatch("(?:ab){2}", "ab");
}

// ── §22.2.1.1 duplicate named groups ────────────────────────────────

test "perlex: duplicate name across alternatives picks the participant" {
    try expectMatch("(?<x>a)|(?<x>b)", "bab", "b,,b");
    try expectMatch("(?<x>b)|(?<x>a)", "bab", "b,b,");
}

test "perlex: same-alternative duplicate name is a syntax error" {
    try expectCompile("(?<x>a)(?<x>b)", .syntax_error);
    try expectCompile("(?<x>(?<x>a))", .syntax_error);
}

test "perlex: backreference resolves the participating duplicate" {
    try expectMatch("(?:(?<x>a)|(?<x>b))\\k<x>", "aa", "aa,a,");
    try expectMatch("(?:(?<x>a)|(?<x>b))\\k<x>", "bb", "bb,,b");
    try expectNoMatch("(?:(?<x>a)|(?<x>b))\\k<x>", "ab");
}

test "perlex: backreference to unset duplicate matches empty" {
    try expectMatch("(?<a>x)|(?:zy\\k<a>)", "zy", "zy,");
}

test "perlex: duplicate name across three alternatives with backref" {
    try expectMatch("^(?:(?<a>x)|(?<a>y)|z)\\k<a>$", "xx", "xx,x,");
    try expectMatch("^(?:(?<a>x)|(?<a>y)|z)\\k<a>$", "yy", "yy,,y");
}

test "perlex: iterated duplicate group clears captures each iteration" {
    // Second iteration takes the `c` branch, so neither x slot is set.
    try expectMatch("(?:(?:(?<x>a)|(?<x>b)|c)\\k<x>){2}", "aac", "aac,,");
}

// ── Fallback routing — constructs outside the v1 grammar ─────────────

test "perlex: unsupported constructs fall back" {
    try expectCompile("[a-z]", .unsupported); // character class
    try expectCompile("a.c", .unsupported); // dot
    try expectCompile("a*", .unsupported); // star quantifier
    try expectCompile("a+", .unsupported); // plus quantifier
    try expectCompile("(?=a)", .unsupported); // lookahead
    try expectCompile("(?<=a)", .unsupported); // lookbehind
    try expectCompile("\\d", .unsupported); // class escape
}

test "perlex: u8 fast path matches like the u16 path" {
    const o = try runUnit(u8, testing.allocator, "(?:(?<x>a)|(?<x>b))\\k<x>", "bb");
    switch (o) {
        .match => |s| {
            defer testing.allocator.free(s);
            try testing.expectEqualStrings("bb,,b", s);
        },
        else => return error.ExpectedMatch,
    }
}

test "perlex: classifier flags regular vs backtracking patterns" {
    {
        var res = try perlex.compile(testing.allocator, "(?<a>ab)c", .{});
        try testing.expect(res == .ok);
        defer res.ok.deinit();
        try testing.expect(res.ok.is_regular); // no backref
    }
    {
        var res = try perlex.compile(testing.allocator, "(?:(?<x>a)|(?<x>b))\\k<x>", .{});
        try testing.expect(res == .ok);
        defer res.ok.deinit();
        try testing.expect(!res.ok.is_regular); // backref → needs backtracking
    }
}
