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
fn runUnit(comptime Unit: type, gpa: std.mem.Allocator, pattern: []const u8, flags: perlex.Flags, input: []const u8) !Outcome {
    var res = try perlex.compile(gpa, pattern, flags);
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
    return runUnit(u16, gpa, pattern, .{}, input);
}

fn expectMatch(pattern: []const u8, input: []const u8, expected: []const u8) !void {
    return expectMatchFlags(pattern, .{}, input, expected);
}

fn expectMatchFlags(pattern: []const u8, flags: perlex.Flags, input: []const u8, expected: []const u8) !void {
    const o = try runUnit(u16, testing.allocator, pattern, flags, input);
    switch (o) {
        .match => |s| {
            defer testing.allocator.free(s);
            try testing.expectEqualStrings(expected, s);
        },
        else => return error.ExpectedMatch,
    }
}

fn expectNoMatch(pattern: []const u8, input: []const u8) !void {
    return expectNoMatchFlags(pattern, .{}, input);
}

fn expectNoMatchFlags(pattern: []const u8, flags: perlex.Flags, input: []const u8) !void {
    const o = try runUnit(u16, testing.allocator, pattern, flags, input);
    if (o != .no_match) return error.ExpectedNoMatch;
}

fn expectCompile(pattern: []const u8, want: std.meta.Tag(Outcome)) !void {
    return expectCompileFlags(pattern, .{}, want);
}

fn expectCompileFlags(pattern: []const u8, flags: perlex.Flags, want: std.meta.Tag(Outcome)) !void {
    var res = try perlex.compile(testing.allocator, pattern, flags);
    switch (res) {
        .ok => |*prog| {
            prog.deinit();
            try testing.expect(want == .match);
        },
        .unsupported => try testing.expect(want == .unsupported),
        .syntax_error => try testing.expect(want == .syntax_error),
    }
}

// ── §22.2.1.1 \p{} property escapes ─────────────────────────────────
// A tiny stub resolver exercises the parser / compiler / VM property
// path without pulling the real Unicode tables (those are tested in
// `unicode/properties.zig`; the table-backed resolver via test262).

const CR = perlex.parser.Node.ClassRange;

fn stubResolver(gpa: std.mem.Allocator, key: ?[]const u8, value: []const u8) std.mem.Allocator.Error!?[]const CR {
    if (key) |k| {
        if (!std.mem.eql(u8, k, "gc") and !std.mem.eql(u8, k, "General_Category")) return null;
    }
    const lu = [_]CR{.{ .lo = 'A', .hi = 'Z' }};
    const ll = [_]CR{.{ .lo = 'a', .hi = 'z' }};
    const l = [_]CR{ .{ .lo = 'A', .hi = 'Z' }, .{ .lo = 'a', .hi = 'z' } };
    const ranges: []const CR =
        if (std.mem.eql(u8, value, "Lu")) &lu else if (std.mem.eql(u8, value, "Ll")) &ll else if (std.mem.eql(u8, value, "L")) &l else return null;
    return try gpa.dupe(CR, ranges);
}

const uflags = perlex.Flags{ .unicode = true };

fn runProp(gpa: std.mem.Allocator, pattern: []const u8, flags: perlex.Flags, input: []const u8) !Outcome {
    var res = try perlex.compileWithResolver(gpa, pattern, flags, stubResolver);
    switch (res) {
        .unsupported => return .unsupported,
        .syntax_error => return .syntax_error,
        .ok => |*prog| {
            defer prog.deinit();
            const units = try gpa.alloc(u16, input.len);
            defer gpa.free(units);
            for (input, 0..) |b, i| units[i] = @as(u16, b);
            var m = (try perlex.exec(u16, gpa, prog, units, 0)) orelse return .no_match;
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

fn expectMatchProp(pattern: []const u8, input: []const u8, expected: []const u8) !void {
    return expectMatchPropFlags(pattern, uflags, input, expected);
}

fn expectMatchPropFlags(pattern: []const u8, flags: perlex.Flags, input: []const u8, expected: []const u8) !void {
    const o = try runProp(testing.allocator, pattern, flags, input);
    switch (o) {
        .match => |s| {
            defer testing.allocator.free(s);
            try testing.expectEqualStrings(expected, s);
        },
        else => return error.ExpectedMatch,
    }
}

fn expectNoMatchProp(pattern: []const u8, input: []const u8) !void {
    return expectNoMatchPropFlags(pattern, uflags, input);
}

fn expectNoMatchPropFlags(pattern: []const u8, flags: perlex.Flags, input: []const u8) !void {
    const o = try runProp(testing.allocator, pattern, flags, input);
    if (o != .no_match) return error.ExpectedNoMatch;
}

fn expectCompileProp(pattern: []const u8, flags: perlex.Flags, want: std.meta.Tag(Outcome)) !void {
    var res = try perlex.compileWithResolver(testing.allocator, pattern, flags, stubResolver);
    switch (res) {
        .ok => |*prog| {
            prog.deinit();
            try testing.expect(want == .match);
        },
        .unsupported => try testing.expect(want == .unsupported),
        .syntax_error => try testing.expect(want == .syntax_error),
    }
}

test "perlex: \\p{} lone gc value matches and negates" {
    try expectMatchProp("\\p{Lu}", "A", "A");
    try expectNoMatchProp("\\p{Lu}", "a");
    try expectMatchProp("\\p{Ll}", "a", "a");
    try expectMatchProp("\\P{Lu}", "a", "a");
    try expectNoMatchProp("\\P{Lu}", "A");
}

test "perlex: \\p{} with gc= / General_Category= prefix" {
    try expectMatchProp("\\p{gc=Lu}", "A", "A");
    try expectMatchProp("\\p{General_Category=Ll}", "a", "a");
}

test "perlex: \\p{} group value, quantifier, and captures" {
    try expectMatchProp("\\p{L}+", "abcD", "abcD");
    try expectNoMatchProp("\\p{L}", "0");
    try expectMatchProp("(\\p{Lu})(\\p{Ll}+)", "Hello", "Hello,H,ello");
}

test "perlex: \\p{} only recognised under /u, else defers to fallback" {
    try expectCompileProp("\\p{Lu}", .{}, .unsupported);
}

test "perlex: declined or malformed property defers to fallback" {
    try expectCompileProp("\\p{Nd}", uflags, .unsupported); // stub doesn't know Nd
    try expectCompileProp("\\p{Script=Greek}", uflags, .unsupported); // non-gc key
    try expectCompileProp("\\p", uflags, .unsupported); // no brace
    try expectCompileProp("\\p{", uflags, .unsupported); // unterminated
    try expectCompileProp("\\p{}", uflags, .unsupported); // empty
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
    try expectCompile("[\\D]", .unsupported); // negated class escape in class
    try expectCompile("\\1", .unsupported); // numeric backreference (no groups)
    try expectCompile("\\p{L}", .unsupported); // property escape
    try expectCompile("(a?)*", .unsupported); // nullable quantifier body
    try expectCompile("(?:)*", .unsupported); // nullable quantifier body
    try expectCompile("(?=a)*", .unsupported); // quantified assertion (Annex B)
    try expectCompile("a{0,5000}", .unsupported); // bound exceeds inline-expansion cap
    try expectCompile("a{99999}", .unsupported); // huge exact bound
}

// ── §22.2.2.4 lookahead ─────────────────────────────────────────────

test "perlex: positive lookahead is zero-width" {
    try expectMatch("a(?=b)", "ab", "a"); // assertion not consumed
    try expectNoMatch("a(?=b)", "ac");
    try expectMatch("(?=ab)a", "ab", "a");
    try expectMatch("\\d+(?=px)", "10px", "10");
}

test "perlex: negative lookahead" {
    try expectMatch("a(?!b)", "ac", "a");
    try expectNoMatch("a(?!b)", "ab");
}

test "perlex: positive lookahead keeps captures, negative does not" {
    try expectMatch("(?=(a))a", "a", "a,a"); // group set by positive lookahead
    try expectMatch("(?!(a))b", "b", "b,"); // negative lookahead group undefined
}

test "perlex: duplicate name across a lookahead and the sequence errors" {
    try expectCompile("(?=(?<x>a))(?<x>b)", .syntax_error);
    // …but the same name across mutually exclusive alternatives is fine.
    try expectCompile("(?=(?<x>a))|(?<x>b)", .match);
}

// ── §22.2.2.4 lookbehind (backward matching) ────────────────────────

test "perlex: positive lookbehind" {
    try expectMatch("(?<=a)b", "ab", "b");
    try expectNoMatch("(?<=a)b", "cb");
    try expectMatch("(?<=ab)c", "abc", "c");
    try expectMatch("(?<=[0-9])x", "5x", "x");
}

test "perlex: negative lookbehind" {
    try expectMatch("(?<!a)b", "cb", "b");
    try expectNoMatch("(?<!a)b", "ab");
    try expectMatch("(?<!a)b", "b", "b"); // nothing before → not preceded by 'a'
}

test "perlex: variable-length lookbehind" {
    try expectMatch("(?<=a+)b", "aaab", "b");
    try expectMatch("(?<=ab|cd)x", "cdx", "x");
}

test "perlex: lookbehind with captures or assertions falls back" {
    try expectCompile("(?<=(a))b", .unsupported); // capture in lookbehind
    try expectCompile("(?<=(?=a))b", .unsupported); // nested assertion
}

// ── §22.2 Unicode mode (/u) — code-point matching ───────────────────

const uf: perlex.Flags = .{ .unicode = true };

test "perlex: /u matches ASCII and \\u{...} escapes" {
    try expectMatchFlags("a+", uf, "aaa", "aaa");
    try expectMatchFlags("\\u{61}", uf, "a", "a"); // U+0061 = 'a'
    try expectMatchFlags("[\\u{41}-\\u{5A}]", uf, "Q", "Q"); // [A-Z]
}

test "perlex: /u declines what needs more than code-point matching" {
    try expectCompileFlags("a", .{ .unicode = true, .ignore_case = true }, .unsupported); // /iu folding
    try expectCompileFlags("\\uD83D", uf, .unsupported); // lone surrogate escape
    try expectCompileFlags("\\p{L}", uf, .unsupported); // property escape (next increment)
}

test "perlex: /u treats a supplementary code point as one unit" {
    const gpa = testing.allocator;
    // U+1F600 "😀" is the surrogate pair [0xD83D, 0xDE00] in UTF-16.
    const input = [_]u16{ 0xD83D, 0xDE00 };

    // `^.$/u` — the single `.` spans the whole code point (2 units).
    var dot = try perlex.compile(gpa, "^.$", uf);
    try testing.expect(dot == .ok);
    defer dot.ok.deinit();
    var dm = (try perlex.exec(u16, gpa, &dot.ok, &input, 0)) orelse return error.ExpectedMatch;
    defer dm.deinit(gpa);
    try testing.expectEqual(@as(usize, 0), dm.slots[0]);
    try testing.expectEqual(@as(usize, 2), dm.slots[1]);

    // A `\u{1F600}` literal matches the same supplementary code point.
    var lit = try perlex.compile(gpa, "\\u{1F600}", uf);
    try testing.expect(lit == .ok);
    defer lit.ok.deinit();
    var lm = (try perlex.exec(u16, gpa, &lit.ok, &input, 0)) orelse return error.ExpectedMatch;
    defer lm.deinit(gpa);
    try testing.expectEqual(@as(usize, 2), lm.slots[1]);

    // Without /u the same `.` matches only one code unit (the high
    // surrogate), so `^.$` cannot reach the end.
    var nonu = try perlex.compile(gpa, "^.$", .{});
    try testing.expect(nonu == .ok);
    defer nonu.ok.deinit();
    try testing.expect((try perlex.exec(u16, gpa, &nonu.ok, &input, 0)) == null);
}

// ── §22.2.1 quantifiers (greedy / lazy / bounded) ───────────────────

test "perlex: greedy quantifiers" {
    try expectMatch("a*", "aaa", "aaa");
    try expectMatch("a*", "", "");
    try expectMatch("a*", "b", ""); // matches empty before 'b'
    try expectMatch("a+", "aaa", "aaa");
    try expectNoMatch("a+", "b");
    try expectMatch("a?", "a", "a");
    try expectMatch("a?", "b", "");
}

test "perlex: bounded quantifiers" {
    try expectMatch("a{2,4}", "aaaaa", "aaaa"); // greedy caps at 4
    try expectMatch("a{2,4}", "aa", "aa");
    try expectNoMatch("a{2,4}", "a"); // needs >= 2
    try expectMatch("a{2,}", "aaaa", "aaaa");
    try expectNoMatch("a{2,}", "a");
    try expectMatch("a{3}", "aaaa", "aaa"); // exact
}

test "perlex: lazy quantifiers" {
    try expectMatch("a*?", "aaa", ""); // as few as possible → empty
    try expectMatch("a+?", "aaa", "a"); // minimum one
    try expectMatch("a+?b", "aaab", "aaab"); // forced to extend to reach 'b'
}

test "perlex: greedy vs lazy capture distribution" {
    try expectMatch("(a+)(a+)", "aaa", "aaa,aa,a"); // greedy first grabs more
    try expectMatch("(a+?)(a+)", "aaa", "aaa,a,aa"); // lazy first grabs less
}

test "perlex: quantified class" {
    try expectMatch("[0-9]+", "123", "123");
    try expectMatch("\\d+", "42", "42");
    try expectMatch("[a-z]*", "abc", "abc");
    try expectMatch("a.*c", "abXYc", "abXYc");
}

test "perlex: quantifier clears captures each iteration" {
    // §22.2.2.3 step 4 — the last iteration takes the `b` branch, so
    // the group captured in an earlier iteration is left undefined.
    try expectMatch("(?:(a)|b)+", "ab", "ab,");
}

// ── §22.2.1 character classes, `.`, class escapes, boundaries ───────

test "perlex: dot matches any non-line-terminator" {
    try expectMatch("a.c", "axc", "axc");
    try expectMatch("a.c", "a c", "a c");
    try expectNoMatch("a.c", "a\nc");
}

test "perlex: character class membership" {
    try expectMatch("[abc]", "b", "b");
    try expectNoMatch("[abc]", "d");
    try expectMatch("[a-z]", "m", "m");
    try expectMatch("[0-9]", "5", "5");
    try expectNoMatch("[a-z]", "Q");
}

test "perlex: negated character class" {
    try expectMatch("[^abc]", "d", "d");
    try expectNoMatch("[^abc]", "a");
    try expectMatch("[^0-9]", "x", "x");
}

test "perlex: class escapes" {
    try expectMatch("\\d", "7", "7");
    try expectNoMatch("\\d", "a");
    try expectMatch("\\D", "a", "a");
    try expectNoMatch("\\D", "7");
    try expectMatch("\\w", "_", "_");
    try expectMatch("\\s", " ", " ");
    try expectNoMatch("\\s", "x");
}

test "perlex: class escapes inside a class" {
    try expectMatch("[\\d]", "3", "3");
    try expectMatch("[a\\d]", "5", "5");
    try expectMatch("[a\\d]", "a", "a");
    try expectNoMatch("[\\d]", "z");
}

test "perlex: a class escape as a range endpoint falls back (no Annex B)" {
    // §B.1.4 isn't applied: `[\d-a]` / `[a-\d]` are SyntaxErrors under
    // /u and an Annex B leniency otherwise — Perlex implements neither.
    try expectCompile("[\\d-a]", .unsupported);
    try expectCompile("[a-\\d]", .unsupported);
    // A `-` not forming such a range stays a literal and is ours.
    try expectMatch("[\\d-]", "-", "-");
    try expectMatch("[\\d-]", "7", "7");
    try expectMatch("[-\\d]", "-", "-");
}

test "perlex: escaped literals and hex/unicode escapes" {
    try expectMatch("a\\.c", "a.c", "a.c");
    try expectNoMatch("a\\.c", "axc");
    try expectMatch("\\(", "(", "(");
    try expectMatch("\\x41", "A", "A");
    try expectMatch("\\u0041", "A", "A");
}

test "perlex: word boundaries" {
    try expectMatch("\\bab", "ab", "ab"); // boundary before 'a'
    try expectNoMatch("a\\bb", "ab"); // no boundary between word chars
    try expectMatch("a\\Bb", "ab", "ab"); // \B matches the non-boundary
    try expectNoMatch("\\Bab", "ab"); // \B fails at the leading boundary
}

test "perlex: class participates in captures and groups" {
    try expectMatch("(?<d>[0-9])(?<l>[a-z])", "3q", "3q,3,q");
}

// ── §22.2.1 numeric backreferences ──────────────────────────────────

test "perlex: numeric backreference" {
    try expectMatch("(a)\\1", "aa", "aa,a");
    try expectNoMatch("(a)\\1", "ab");
    try expectMatch("(ab)\\1", "abab", "abab,ab");
    try expectMatch("(?<x>a)(b)\\2", "abb", "abb,a,b");
}

test "perlex: out-of-range numeric escape falls back" {
    // `\2` with one group is an Annex B octal escape, not a backref.
    try expectCompile("(a)\\2", .unsupported);
    try expectCompile("\\1", .unsupported);
}

// ── §22.2.2.7.1 `i` flag (ASCII case folding) ───────────────────────

const ci: perlex.Flags = .{ .ignore_case = true };

test "perlex: i flag folds literals" {
    try expectMatchFlags("abc", ci, "ABC", "ABC");
    try expectMatchFlags("abc", ci, "AbC", "AbC");
    try expectMatchFlags("ABC", ci, "abc", "abc");
    try expectNoMatchFlags("abc", ci, "abd");
}

test "perlex: i flag folds classes both directions" {
    try expectMatchFlags("[a-z]+", ci, "AbC", "AbC");
    try expectMatchFlags("[A-Z]", ci, "a", "a");
    try expectMatchFlags("[a-z]", ci, "A", "A");
    try expectNoMatchFlags("[a-z]", ci, "0");
    // Negated class is case-insensitive too.
    try expectNoMatchFlags("[^a-z]", ci, "A");
}

test "perlex: i flag folds backreferences" {
    try expectMatchFlags("(?<x>a)\\k<x>", ci, "aA", "aA,a");
    try expectMatchFlags("(?<x>ab)\\k<x>", ci, "abAB", "abAB,ab");
}

test "perlex: i flag leaves non-letters and dot/word unchanged" {
    try expectMatchFlags("\\w+", ci, "Ab_9", "Ab_9");
    try expectMatchFlags("a.c", ci, "AXC", "AXC");
    try expectMatchFlags("\\d+", ci, "42", "42");
}

test "perlex: i with non-ASCII units falls back" {
    // ASCII folding can't model à↔À, so these defer to the fallback.
    try expectCompileFlags("\\u00e0", ci, .unsupported);
    try expectCompileFlags("[\\u00c0-\\u00ff]", ci, .unsupported);
    // …but the same patterns compile fine without `i`.
    try expectCompileFlags("\\u00e0", .{}, .match);
}

// ── `s` (dotall) and `m` (multiline) flags ──────────────────────────

test "perlex: s flag makes dot match line terminators" {
    try expectMatchFlags(".", .{ .dot_all = true }, "\n", "\n");
    try expectMatchFlags("a.b", .{ .dot_all = true }, "a\nb", "a\nb");
    // Without `s`, dot still excludes the newline.
    try expectNoMatch(".", "\n");
}

test "perlex: m flag anchors at line boundaries" {
    try expectMatchFlags("^b", .{ .multiline = true }, "a\nb", "b");
    try expectMatchFlags("a$", .{ .multiline = true }, "a\nb", "a");
    // Without `m`, `^`/`$` are input-relative only.
    try expectNoMatch("^b", "a\nb");
    try expectNoMatch("a$", "a\nb");
}

test "perlex: u8 fast path matches like the u16 path" {
    const o = try runUnit(u8, testing.allocator, "(?:(?<x>a)|(?<x>b))\\k<x>", .{}, "bb");
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

// §22.2.1 ClassSetExpression — the `/v` (UnicodeSets) extended class
// grammar: nested classes, set operators (union / intersection `&&` /
// difference `--`), and `^` negation. Phase A covers char-only results
// (no `\q{}` string literals, no properties-of-strings — those defer to
// the fallback until the string-aware phase).

const vflags = perlex.Flags{ .unicode_sets = true };

/// Compile a `/v` pattern (property-resolver backed, so `\p{}` operands
/// work) and run it over a u16 input given directly as code units, so a
/// supplementary code point can be supplied as a surrogate pair. Returns
/// only the outcome tag (no captures), so there is nothing to free.
fn runV16Tag(gpa: std.mem.Allocator, pattern: []const u8, input: []const u16) !std.meta.Tag(Outcome) {
    var res = try perlex.compileWithResolver(gpa, pattern, vflags, stubResolver);
    switch (res) {
        .unsupported => return .unsupported,
        .syntax_error => return .syntax_error,
        .ok => |*prog| {
            defer prog.deinit();
            var m = (try perlex.exec(u16, gpa, prog, input, 0)) orelse return .no_match;
            m.deinit(gpa);
            return .match;
        },
    }
}

test "perlex/v: nested-class union" {
    try expectMatchFlags("[[0-9][a-c]]", vflags, "5", "5");
    try expectMatchFlags("[[0-9][a-c]]", vflags, "b", "b");
    try expectNoMatchFlags("[[0-9][a-c]]", vflags, "z");
    // Implicit union of a bare char with a nested class.
    try expectMatchFlags("[x[0-9]]", vflags, "x", "x");
    try expectNoMatchFlags("[x[0-9]]", vflags, "y");
}

test "perlex/v: intersection &&" {
    try expectMatchFlags("[[0-9]&&[4-8]]", vflags, "5", "5");
    try expectNoMatchFlags("[[0-9]&&[4-8]]", vflags, "2");
    try expectNoMatchFlags("[[0-9]&&[4-8]]", vflags, "9");
}

test "perlex/v: difference --" {
    try expectMatchFlags("[[0-9]--[3-5]]", vflags, "2", "2");
    try expectMatchFlags("[[0-9]--[3-5]]", vflags, "8", "8");
    try expectNoMatchFlags("[[0-9]--[3-5]]", vflags, "4");
    // Self-difference is empty: nothing matches.
    try expectNoMatchFlags("[[0-9]--[0-9]]", vflags, "5");
}

test "perlex/v: negated set complements the whole expression" {
    try expectMatchFlags("[^[0-9]]", vflags, "a", "a");
    try expectNoMatchFlags("[^[0-9]]", vflags, "5");
    try expectMatchFlags("[^[a-z]--[aeiou]]", vflags, "e", "e"); // 'e' removed → in complement
    try expectNoMatchFlags("[^[a-z]--[aeiou]]", vflags, "b");
}

test "perlex/v: class-escape operands and complement" {
    try expectMatchFlags("[\\d&&[4-8]]", vflags, "6", "6");
    try expectNoMatchFlags("[\\d&&[4-8]]", vflags, "1");
    // \D = all non-digits; intersect [a-c] → [a-c].
    try expectMatchFlags("[\\D&&[a-c]]", vflags, "b", "b");
    try expectNoMatchFlags("[\\D&&[a-c]]", vflags, "1");
    try expectNoMatchFlags("[\\D&&[a-c]]", vflags, "d");
}

test "perlex/v: deeply nested operators" {
    // ((0-9) − {5}) ∩ (3-8) = {3,4,6,7,8}
    try expectMatchFlags("[[[0-9]--[5]]&&[3-8]]", vflags, "4", "4");
    try expectMatchFlags("[[[0-9]--[5]]&&[3-8]]", vflags, "7", "7");
    try expectNoMatchFlags("[[[0-9]--[5]]&&[3-8]]", vflags, "5");
    try expectNoMatchFlags("[[[0-9]--[5]]&&[3-8]]", vflags, "2");
}

test "perlex/v: reserved double punctuators defer to the fallback" {
    // §22.2.1 ClassSetReservedDoublePunctuator — these are early errors;
    // Perlex defers so the fallback's table renders the SyntaxError.
    try expectCompileFlags("[a~~b]", vflags, .unsupported);
    try expectCompileFlags("[a!!b]", vflags, .unsupported);
    try expectCompileFlags("[a::b]", vflags, .unsupported);
    try expectCompileFlags("[a==b]", vflags, .unsupported);
    try expectCompileFlags("[a..b]", vflags, .unsupported);
}

test "perlex/v: single punctuators are ordinary class characters" {
    // A lone reserved punctuator is a valid ClassSetCharacter.
    try expectMatchFlags("[a~b]", vflags, "~", "~");
    try expectMatchFlags("[a&b]", vflags, "&", "&");
    // A punctuator range still parses (`!`..`~` spans ASCII punctuation).
    try expectMatchFlags("[!-~]", vflags, "#", "#");
    try expectNoMatchFlags("[!-~]", vflags, " ");
}

test "perlex/v: \\p{} operand resolves and combines" {
    // stubResolver knows Lu/Ll/L. [\p{L}&&[a-z]] = lowercase ASCII letters.
    try expectMatchPropFlags("[\\p{L}&&[a-z]]", vflags, "m", "m");
    try expectNoMatchPropFlags("[\\p{L}&&[a-z]]", vflags, "M");
    try expectNoMatchPropFlags("[\\p{L}&&[a-z]]", vflags, "5");
}

test "perlex/v: supplementary code points match as one element" {
    // U+1F603 as a surrogate pair; the class is a code-point range.
    const smile = [_]u16{ 0xD83D, 0xDE03 };
    try testing.expect(.match == try runV16Tag(testing.allocator, "[\\u{1F600}-\\u{1F610}]", &smile));
    const out_of_range = [_]u16{ 0xD83D, 0xDE20 }; // U+1F620, above the range
    try testing.expect(.no_match == try runV16Tag(testing.allocator, "[\\u{1F600}-\\u{1F610}]", &out_of_range));
}
