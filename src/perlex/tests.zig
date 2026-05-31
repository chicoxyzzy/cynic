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

/// `s` repeated `n` times as a comptime-known string (this Zig dev build
/// mis-tokenizes the `**` array-repeat operator). Returns a pointer to a
/// fixed-size array so the length lives in the type — that lets callers
/// `++` a suffix on (slice concatenation needs comptime-known lengths).
/// Used to build the long inputs the counted-loop quantifier tests need.
fn rep(comptime s: []const u8, comptime n: usize) *const [s.len * n]u8 {
    const buf = comptime blk: {
        @setEvalBranchQuota(s.len * n * 4 + 1000);
        var b: [s.len * n]u8 = undefined;
        var i: usize = 0;
        while (i < n) : (i += 1) @memcpy(b[i * s.len ..][0..s.len], s);
        break :blk b;
    };
    return &buf;
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

/// Render every capture group so the §22.2.2.3 zero-width distinction is
/// visible: a *participating* group prints as its substring in single
/// quotes (an empty capture shows as `''`), a *non-participating* group
/// prints as `undef`. Groups are space-joined. The comma-joined
/// `expectMatch` renders both unset and empty-captured as "", so it can't
/// tell a guarded empty iteration (group stays undefined) from a mandatory
/// empty iteration (group captures ""). The expected strings come from the
/// cross-engine differential (engine262 authority).
fn expectCaps(pattern: []const u8, input: []const u8, expected: []const u8) !void {
    return expectCapsFlags(pattern, .{}, input, expected);
}

fn expectCapsFlags(pattern: []const u8, flags: perlex.Flags, input: []const u8, expected: []const u8) !void {
    const gpa = testing.allocator;
    var res = try perlex.compile(gpa, pattern, flags);
    switch (res) {
        .ok => |*prog| {
            defer prog.deinit();
            const units = try gpa.alloc(u16, input.len);
            defer gpa.free(units);
            for (input, 0..) |b, i| units[i] = @as(u16, b);

            var m = (try perlex.exec(u16, gpa, prog, units, 0)) orelse return error.ExpectedMatch;
            defer m.deinit(gpa);

            var out: std.ArrayListUnmanaged(u8) = .empty;
            defer out.deinit(gpa);
            var g: usize = 0;
            while (g < prog.group_count) : (g += 1) {
                if (g != 0) try out.append(gpa, ' ');
                const cs = m.slots[2 * g];
                const ce = m.slots[2 * g + 1];
                if (cs == perlex.none or ce == perlex.none) {
                    try out.appendSlice(gpa, "undef");
                } else {
                    try out.append(gpa, '\'');
                    for (units[cs..ce]) |u| try out.append(gpa, @intCast(u));
                    try out.append(gpa, '\'');
                }
            }
            try testing.expectEqualStrings(expected, out.items);
        },
        else => return error.ExpectedMatch,
    }
}

// ── §22.2.1.1 \p{} property escapes ─────────────────────────────────
// A tiny stub resolver exercises the parser / compiler / VM property
// path without pulling the real Unicode tables (those are tested in
// `unicode/properties.zig`; the table-backed resolver via test262).

const CR = perlex.parser.Node.ClassRange;

fn stubResolver(gpa: std.mem.Allocator, key: ?[]const u8, value: []const u8) std.mem.Allocator.Error!?perlex.ResolvedProperty {
    // A §22.2.1.1 *property of strings*: a real name ("Basic_Emoji") backed by
    // tiny fake data so the parser's name-based early-error gating fires while
    // the compiler's alternation lowering is exercised without real tables.
    // Single chars [a-c] fold into ranges; "xy" and "123" are string members.
    if (key == null and std.mem.eql(u8, value, "Basic_Emoji")) {
        const ranges = try gpa.dupe(CR, &[_]CR{.{ .lo = 'a', .hi = 'c' }});
        const seqs = try gpa.alloc([]const u21, 2);
        seqs[0] = &[_]u21{ 'x', 'y' };
        seqs[1] = &[_]u21{ '1', '2', '3' };
        return .{ .ranges = ranges, .strings = seqs };
    }
    if (key) |k| {
        if (!std.mem.eql(u8, k, "gc") and !std.mem.eql(u8, k, "General_Category")) return null;
    }
    const lu = [_]CR{.{ .lo = 'A', .hi = 'Z' }};
    const ll = [_]CR{.{ .lo = 'a', .hi = 'z' }};
    const l = [_]CR{ .{ .lo = 'A', .hi = 'Z' }, .{ .lo = 'a', .hi = 'z' } };
    const ranges: []const CR =
        if (std.mem.eql(u8, value, "Lu")) &lu else if (std.mem.eql(u8, value, "Ll")) &ll else if (std.mem.eql(u8, value, "L")) &l else return null;
    return .{ .ranges = try gpa.dupe(CR, ranges), .strings = &.{} };
}

/// A §22.2.2.9 case-folding orbit resolver backed by tiny fake data, so
/// the VM's `/iu`/`/iv` folding is exercised without the real CaseFolding
/// tables. Returns the orbit members *excluding* `cp` (empty when `cp`
/// folds only to itself), mirroring `perlex.CaseFoldFn`. The orbits:
/// `k`/`K`/KELVIN SIGN (U+212A); the three ASCII letter pairs a/b/c; and a
/// supplementary Deseret pair (U+10400 LONG I ↔ U+10428 long i) to cover
/// per-code-point folding across a surrogate pair.
fn stubFolder(cp: u21) []const u21 {
    return switch (cp) {
        'k' => &.{ 'K', 0x212A },
        'K' => &.{ 'k', 0x212A },
        0x212A => &.{ 'k', 'K' },
        'a' => &.{'A'},
        'A' => &.{'a'},
        'b' => &.{'B'},
        'B' => &.{'b'},
        'c' => &.{'C'},
        'C' => &.{'c'},
        0x10400 => &.{0x10428},
        0x10428 => &.{0x10400},
        else => &.{},
    };
}

/// A §22.2.2.7.3 *non-Unicode* Canonicalize orbit resolver backed by tiny
/// fake data, so the VM's non-`/u` `i` folding over non-ASCII units is
/// exercised without the real toUppercase tables. Returns the orbit
/// members *excluding* `cp` (the set of units that share its non-Unicode
/// Canonicalize), mirroring `perlex.CaseFoldFn`. The orbits differ from
/// `stubFolder` (the `/iu` mapping): U+212A KELVIN has an *empty* orbit
/// here — toUppercase(U+212A) is ASCII `K`, and the ASCII-exclusion keeps
/// it itself, so `/K/i` matches only the Kelvin sign. The pairs:
/// à↔À (U+00E0↔U+00C0); the Greek three-way σ/ς/Σ (U+03C3, U+03C2, U+03A3
/// all uppercase to Σ).
fn stubNonUFold(cp: u21) []const u21 {
    return switch (cp) {
        0x00E0 => &.{0x00C0}, // à → À
        0x00C0 => &.{0x00E0}, // À → à
        0x03C3 => &.{ 0x03C2, 0x03A3 }, // σ → ς, Σ
        0x03C2 => &.{ 0x03C3, 0x03A3 }, // ς → σ, Σ
        0x03A3 => &.{ 0x03C3, 0x03C2 }, // Σ → σ, ς
        else => &.{}, // incl. U+212A KELVIN: empty (ASCII-exclusion)
    };
}

/// Compile with both the stub property resolver and the stub case folder,
/// then run over a UTF-16 `units` input (passed directly so supplementary
/// code points can be expressed as surrogate pairs). Returns the same
/// comma-joined capture rendering as `runUnit`/`runProp`.
fn runHooks(gpa: std.mem.Allocator, pattern: []const u8, flags: perlex.Flags, units: []const u16) !Outcome {
    var res = try perlex.compileWithHooks(gpa, pattern, flags, .{ .resolver = stubResolver, .case_folder = stubFolder, .nonunicode_fold = stubNonUFold });
    switch (res) {
        .unsupported => return .unsupported,
        .syntax_error => return .syntax_error,
        .ok => |*prog| {
            defer prog.deinit();
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
                    for (units[cs..ce]) |u| {
                        // Render only BMP units as bytes; supplementary
                        // matches are asserted by capture span, not text.
                        if (u <= 0x7F) try out.append(gpa, @intCast(u));
                    }
                }
            }
            return .{ .match = try out.toOwnedSlice(gpa) };
        },
    }
}

fn expectFoldMatch(pattern: []const u8, flags: perlex.Flags, units: []const u16, expected: []const u8) !void {
    const o = try runHooks(testing.allocator, pattern, flags, units);
    switch (o) {
        .match => |s| {
            defer testing.allocator.free(s);
            try testing.expectEqualStrings(expected, s);
        },
        else => return error.ExpectedMatch,
    }
}

fn expectFoldNoMatch(pattern: []const u8, flags: perlex.Flags, units: []const u16) !void {
    const o = try runHooks(testing.allocator, pattern, flags, units);
    if (o != .no_match) return error.ExpectedNoMatch;
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

test "perlex: \\p{} non-/u is a SyntaxError (§22.2.1.1)" {
    // `\p` needs +UnicodeMode; without it `p` is a UnicodeIDContinue letter,
    // an invalid IdentityEscape. Only Annex B reads `\p` as a literal 'p',
    // which Cynic's strict-only, non-browser target drops.
    try expectCompileProp("\\p{Lu}", .{}, .syntax_error);
}

test "perlex: a declined (unresolved) property defers to fallback" {
    // Valid syntax the stub resolver doesn't recognise — the fallback
    // resolves the property, so these defer rather than reject.
    try expectCompileProp("\\p{Nd}", uflags, .unsupported); // stub doesn't know Nd
    try expectCompileProp("\\p{Script=Greek}", uflags, .unsupported); // non-gc key
}

test "perlex: a malformed property escape is a /u early error" {
    // §22.2.1.1 CharacterClassEscape :: \p{ UnicodePropertyValueExpression }.
    // `scanProperty` is reached only from /u or /v contexts, so every
    // ill-formed shape — no brace, unterminated, empty, bad name char — is
    // an early error Perlex owns.
    try expectCompileProp("\\p", uflags, .syntax_error); // no brace
    try expectCompileProp("\\p{", uflags, .syntax_error); // unterminated
    try expectCompileProp("\\p{}", uflags, .syntax_error); // empty
    try expectCompileProp("\\p{Hex+}", uflags, .syntax_error); // invalid name char
    try expectCompileProp("\\p{=Lu}", uflags, .syntax_error); // empty key
    try expectCompileProp("\\p{gc=}", uflags, .syntax_error); // empty value
    try expectCompileProp("\\P{", uflags, .syntax_error); // negated, unterminated
}

test "perlex: a \\p escape non-/u is a SyntaxError before scanProperty (§22.2.1.1)" {
    // Without /u or /v the `\p` gate rejects before `scanProperty` runs:
    // `\p` matches no main-grammar production (the CharacterClassEscape needs
    // +UnicodeMode), so what follows is irrelevant — a bare `\p`, `\p{`, or
    // `\p{}` is the same early error. Only Annex B reads `\p` as literal 'p'.
    try expectCompileProp("\\p", .{}, .syntax_error);
    try expectCompileProp("\\p{", .{}, .syntax_error);
    try expectCompileProp("\\p{}", .{}, .syntax_error);
}

test "perlex: bare \\k (no group name) is a SyntaxError in every mode (§22.2.1)" {
    // §22.2.1 AtomEscape :: \k GroupName — `\k` must be followed by
    // `<GroupName>`. With no GroupName the only production left is
    // IdentityEscape, and `k` is UnicodeIDContinue — excluded under
    // +UnicodeMode (SyntaxCharacter or `/` only) and, in the main grammar,
    // under ~UnicodeMode too (SourceCharacter but not UnicodeIDContinue).
    // Only Annex B reread `\k` as a literal 'k', which Cynic's strict-only,
    // non-browser target rejects.
    try expectCompileFlags("\\k", uflags, .syntax_error);
    try expectCompileFlags("\\kab", uflags, .syntax_error);
    try expectCompileFlags("\\k", vflags, .syntax_error);
    try expectCompile("\\k", .syntax_error);
    try expectCompile("\\kab", .syntax_error);
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

test "perlex: an unmatched `)` is a syntax error (§22.2.1)" {
    // §22.2.1 — the Pattern grammar has no production for a `)` without a
    // matching `(`: a balanced group consumes its own `)`, so any `)` left
    // over after the top-level Disjunction is unmatched. It is a Syntax
    // Error in every mode — `)` is always a SyntaxCharacter, never an Annex
    // B ExtendedPatternCharacter — so Perlex owns the verdict directly
    // rather than deferring the leftover to the fallback.
    try expectCompile(")", .syntax_error);
    try expectCompile("a)", .syntax_error);
    try expectCompile("a)b", .syntax_error);
    try expectCompile("(a))", .syntax_error); // one closer too many
    try expectCompileFlags(")", uflags, .syntax_error); // also under /u
    try expectCompileFlags("(a))", uflags, .syntax_error);
    try expectCompileFlags(")", .{ .unicode_sets = true }, .syntax_error); // and /v
    // Balanced groups are unaffected.
    try expectMatch("(a)", "a", "a,a");
    try expectMatch("(?:a)b", "ab", "ab");
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

// ── §22.2.1 RegExpIdentifierName — non-ASCII & escaped group names ───

test "perlex: literal non-ASCII group name compiles and captures" {
    // π (U+03C0) is UnicodeIDStart; a name is legal in both modes.
    try expectMatch("(?<π>a)", "a", "a,a");
    try expectMatchFlags("(?<π>a)", .{ .unicode = true }, "a", "a,a");
    // A multi-code-point CJK name.
    try expectMatch("(?<狐狸>a)", "a", "a,a");
}

test "perlex: \\u{} group-name escape is accepted regardless of the u flag" {
    // §22.2.1: a RegExpIdentifier's `\ RegExpUnicodeEscapeSequence` is
    // always [+UnicodeMode], so `\u{}` names are legal without `/u`.
    try expectCompile("(?<\\u{03C0}>a)", .match);
    try expectCompileFlags("(?<\\u{03C0}>a)", .{ .unicode = true }, .match);
}

test "perlex: \\uHHHH BMP group-name escape" {
    // A == 'A'.
    try expectMatch("(?<\\u0041>.)", "x", "x,x");
}

test "perlex: \\uHHHH\\uHHHH surrogate pair combines into one name code point" {
    // 𝓑 == U+1D4D1 (MATH BOLD SCRIPT CAPITAL B), UnicodeIDStart.
    try expectMatch("(?<\\ud835\\udcd1>a)", "a", "a,a");
    try expectCompileFlags("(?<\\ud835\\udcd1>a)", .{ .unicode = true }, .match);
}

test "perlex: ZWNJ / ZWJ are IdentifierPart in a group name" {
    // `_` start, then ZWNJ (U+200C) / ZWJ (U+200D) as a continue char.
    try expectCompile("(?<_\\u200C>a)", .match);
    try expectCompile("(?<_\\u200D>a)", .match);
}

test "perlex: $ start then non-Start continue (Osmanya digit) in a name" {
    // \u{104A4} (Osmanya digit four) is UnicodeIDContinue but not Start;
    // legal only after a Start char.
    try expectCompileFlags("(?<$\\u{104A4}>a)", .{ .unicode = true }, .match);
}

test "perlex: escaped and literal spellings name the same group (\\k equality)" {
    // §22.2.1.1 GroupName equality is by StringValue, so `\u{03C0}` and a
    // literal `π` are the same name.
    try expectMatch("(?<\\u{03C0}>a)\\k<π>", "aa", "aa,a");
    try expectMatchFlags("(?<π>a)\\k<\\u{03C0}>", .{ .unicode = true }, "aa", "aa,a");
}

test "perlex: duplicate group name across escaped spellings is a syntax error" {
    // Same StringValue twice in one Alternative — §22.2.1.1 early error.
    try expectCompile("(?<π>a)(?<\\u{03C0}>b)", .syntax_error);
}

test "perlex: empty group name is a syntax error" {
    try expectCompile("(?<>a)", .syntax_error);
}

test "perlex: an invalid named-group name is a syntax error" {
    // §22.2.1.1: a GroupName must be a valid RegExpIdentifierName — its
    // first code point a RegExpIdentifierStart (UnicodeIDStart ∪ {$, _}),
    // the rest RegExpIdentifierPart. That rule is mode-independent, and
    // `(?<` has no Annex B reinterpretation (the only other `(?<…` Atoms
    // are the `(?<=` / `(?<!` lookbehinds, already routed away), so a
    // malformed name is a SyntaxError in every mode. Perlex implements the
    // whole name grammar, so it is authoritative.
    //
    // Pictographic code points (Extended_Pictographic, never ID_Start):
    try expectCompile("(?<🐕>dog)", .syntax_error);
    try expectCompile("(?<🦊>fox)", .syntax_error);
    try expectCompileFlags("(?<🐕>dog)", uf, .syntax_error);
    try expectCompileFlags("(?<🦊>fox)", uf, .syntax_error);
    // A decimal-number start (U+1D7DA MATHEMATICAL DOUBLE-STRUCK DIGIT
    // TWO, category Nd → IdentifierPart but not IdentifierStart):
    try expectCompile("(?<𝟚the>the)", .syntax_error);
    try expectCompileFlags("(?<𝟚the>the)", uf, .syntax_error);
    // An ASCII digit start.
    try expectCompile("(?<1a>x)", .syntax_error);
    // A lone surrogate (WTF-8 0xED 0xA0 0x80 = U+D800) is neither a valid
    // scalar identifier code point nor half of a valid pair → SyntaxError.
    try expectCompile("(?<\xed\xa0\x80>x)", .syntax_error);
    try expectCompileFlags("(?<\xed\xa0\x80>x)", uf, .syntax_error);
}

test "perlex: a malformed escape inside a group name is a syntax error" {
    // §22.2.1 RegExpIdentifierName admits only `\ RegExpUnicodeEscapeSequence`
    // (a `\u` / `\u{}` escape). Any other `\` escape, or a malformed `\u`,
    // cannot form a valid name, so it is a §22.2.1.1 SyntaxError everywhere.
    try expectCompile("(?<a\\db>x)", .syntax_error); // \d is not \u
    try expectCompile("(?<\\x41>x)", .syntax_error); // \x is not \u
    try expectCompile("(?<\\u{110000}>x)", .syntax_error); // out of range
    try expectCompile("(?<\\u{}>x)", .syntax_error); // empty \u{}
    try expectCompile("(?<\\uZZZZ>x)", .syntax_error); // not four hex digits
}

test "perlex: a \\k reference to a malformed name is a syntax error" {
    // Under ES2025 NamedCaptureGroups is always enabled, so a `\k` followed
    // by `<` always begins a `\k GroupName` — there is no Annex B
    // `\k`-as-identity-escape fallback in that position. A malformed
    // referenced name is therefore the same §22.2.1.1 SyntaxError as a
    // malformed definition.
    try expectCompile("\\k<🐕>", .syntax_error);
    try expectCompileFlags("\\k<🐕>", uf, .syntax_error);
}

test "perlex: a \\k reference to a name with no matching group is a syntax error" {
    // §22.2.1.1 — a `\k GroupName` must reference a group that exists in the
    // pattern; if none does, it is an early error in every mode. Only Annex B
    // §B.1.4 (when the pattern has *no* GroupName at all) rereads `\k` as a
    // literal 'k' — dropped here, like the rest of the Annex B regex grammar.
    try expectCompile("\\k<x>", .syntax_error); // no groups at all
    try expectCompileFlags("\\k<x>", uf, .syntax_error);
    try expectCompile("(?<y>a)\\k<x>", .syntax_error); // a group exists, not `x`
    // A reference that *does* resolve still compiles and matches.
    try expectMatch("(?<x>a)\\k<x>", "aa", "aa,a");
}

// ── Fallback routing — constructs outside the v1 grammar ─────────────

test "perlex: unsupported constructs fall back" {
    try expectCompileFlags("[\\D]", uf, .unsupported); // negated class escape under /u (off /u it's owned)
}

test "perlex: a quantified lookaround is a syntax error under /u, /v, or for any lookbehind" {
    // §22.2.1 Term: +UnicodeMode has no `Assertion Quantifier` production,
    // so quantifying a lookaround is a SyntaxError; ~UnicodeMode allows a
    // *lookahead* (QuantifiableAssertion, Annex B §B.1.2) but never a
    // lookbehind. Under /u — both lookahead and lookbehind, every shape:
    try expectCompileFlags("(?=a)*", uf, .syntax_error);
    try expectCompileFlags("(?!a)+", uf, .syntax_error);
    try expectCompileFlags("(?=a)?", uf, .syntax_error);
    try expectCompileFlags("(?=a){2,3}", uf, .syntax_error);
    try expectCompileFlags("(?=a)*?", uf, .syntax_error); // lazy too
    try expectCompileFlags("(?<=a)*", uf, .syntax_error);
    try expectCompileFlags("(?<!a)+", uf, .syntax_error);
    // Under /v — same.
    try expectCompileFlags("(?=a)*", vflags, .syntax_error);
    try expectCompileFlags("(?<=a){1,}", vflags, .syntax_error);
    // A quantified *lookbehind* is a SyntaxError even without /u — it is not
    // a QuantifiableAssertion in Annex B.
    try expectCompile("(?<=a)*", .syntax_error);
    try expectCompile("(?<!a)?", .syntax_error);
    try expectCompile("(?<=a){2}", .syntax_error);
    // Non-Unicode quantified *lookahead* stays the Annex-B defer (above).
}

test "perlex: a quantified anchor or word boundary is a syntax error in every mode (§22.2.1)" {
    // §22.2.1 Term: an anchor (`^` `$`) or word-boundary (`\b` `\B`) is an
    // Assertion, never an Atom or a QuantifiableAssertion (only a lookahead
    // is, in Annex B §B.1.2). So a quantifier on one has nothing to repeat —
    // a Syntax Error with or without /u, for every quantifier shape. Unlike
    // the lookahead case there is no Annex-B reading: a brace form such as
    // `^{2}` is rejected too (the `{` is not re-read as a literal). Confirmed
    // identical across the production engines.
    try expectCompile("^*", .syntax_error);
    try expectCompile("$+", .syntax_error);
    try expectCompile("\\b?", .syntax_error);
    try expectCompile("\\B{2,5}", .syntax_error);
    try expectCompile("^*?", .syntax_error); // lazy marker — still nothing to repeat
    try expectCompile("$+?", .syntax_error);
    try expectCompile("^{2}", .syntax_error); // brace form: no Annex-B literal `{`
    // Under /u and /v — same verdict, every shape.
    try expectCompileFlags("^*", uf, .syntax_error);
    try expectCompileFlags("\\b{3}", uf, .syntax_error);
    try expectCompileFlags("$+", vflags, .syntax_error);
    try expectCompileFlags("^{2}", uf, .syntax_error);
    // A quantified *lookahead* is now also a SyntaxError in every mode
    // (Annex B's QuantifiableAssertion dropped — see the dedicated test
    // below); an unquantified anchor still compiles.
    try expectCompile("(?=a)*", .syntax_error);
    try expectCompile("^$", .match);
    try expectCompile("\\bfoo\\b", .match);
}

test "perlex: large bounded quantifiers lower to a counted loop" {
    // §22.2.2.3 RepeatMatcher. Bounds past the inline-expansion cap
    // (`max_repeat_expand`) used to defer to the fallback because inlining
    // one body copy per iteration would emit thousands of instructions.
    // They now lower to a counted loop (the counter_init / counter_loop
    // opcodes), so the body is emitted once and a runtime counter bounds
    // the iterations — constant program size regardless of the bound.

    // Exact huge bound — the mandatory counted loop.
    try expectMatch("a{5000}", rep("a", 5000), rep("a", 5000));
    try expectNoMatch("a{5000}", rep("a", 4999)); // one short of the mandatory min
    try expectMatch("(a){2000}", rep("a", 2000), rep("a", 2000) ++ ",a"); // last iteration's capture

    // Large optional span (greedy) — the counted optional loop.
    try expectMatch("a{0,5000}", rep("a", 10), rep("a", 10));
    try expectMatch("a{0,5000}", "", ""); // zero iterations allowed
    try expectMatch("a{2,5000}b", "aaab", "aaab"); // small min inlined, large optional counted
    try expectMatch("a{2,5000}a", "aaa", "aaa"); // greedy gives one back to the trailing `a`
    try expectMatch("(a){2,5000}", "aaa", "aaa,a");

    // Large min with an unbounded tail — counted mandatory + star.
    try expectMatch("a{5000,}", rep("a", 6000), rep("a", 6000));
    try expectNoMatch("a{5000,}", rep("a", 4999));

    // Lazy large bound matches the minimum.
    try expectMatch("a{2,5000}?", "aaaa", "aa");

    // Nullable body under a large bound: the §22.2.2.3 progress guard
    // (prog_mark / prog_check) still stops the loop at the first empty
    // iteration, so it doesn't spin to the bound.
    try expectMatch("(?:a?){0,5000}b", "aaab", "aaab");
}

// ── §22.2.1 strict-grammar closure of the Annex B regex carve-outs ───
//
// Cynic drops Annex B regex leniency (§B.1.2) in every mode, not just
// under `/u` and `/v`. Perlex is authoritative for the forms the
// vendored fallback would otherwise accept in non-Unicode mode:
//   • the lower-bound-elided quantifier `{,n}` / `{,}` — every §22.2.1
//     Quantifier brace form requires DecimalDigits as the lower bound,
//     and `{` is a SyntaxCharacter, so `{,…` cannot be a literal and is
//     a Syntax Error (Annex B would read the `{` as a literal);
//   • any stray `]`, `{`, or `}` — these are exactly the SyntaxCharacters
//     that Annex B §B.1.2's ExtendedPatternCharacter reinterprets as
//     literals; outside a CharacterClass or a well-formed Quantifier they
//     have no main-grammar interpretation and are a Syntax Error;
//   • a DecimalEscape `\N` whose value exceeds the capture count —
//     §22.2.1.1's early error (Annex B would reinterpret it as a legacy
//     octal/identity escape).

test "perlex: lower-bound-elided quantifier {,n} is a syntax error" {
    try expectCompile("a{,3}", .syntax_error);
    try expectCompile("a{,}", .syntax_error);
    try expectCompileFlags("a{,3}", uflags, .syntax_error); // also under /u
    // Well-formed brace quantifiers are unaffected.
    try expectMatch("a{2,3}", "aaa", "aaa");
    try expectMatch("a{2}", "aa", "aa");
}

test "perlex: stray brace or bracket is a syntax error" {
    // The three Annex B ExtendedPatternCharacter literals (`] { }`), now
    // rejected in every mode rather than deferred to the fallback.
    try expectCompile("{", .syntax_error);
    try expectCompile("}", .syntax_error);
    try expectCompile("]", .syntax_error);
    try expectCompile("{foo}", .syntax_error);
    try expectCompile("a{b}", .syntax_error); // `{` that isn't a quantifier
    try expectCompile("a{}", .syntax_error);
    try expectCompile("a}", .syntax_error);
    try expectCompile("a]b", .syntax_error);
    try expectCompileFlags("a{b}", uflags, .syntax_error); // already so under /u
    // A well-formed class still consumes its own `]`, and a quantifier its
    // own braces, so neither reaches the stray-brace path.
    try expectMatch("[a]", "a", "a");
    try expectMatch("a{2}", "aa", "aa");
}

test "perlex: a quantifier with no preceding atom is a syntax error (§22.2.1)" {
    // §22.2.1 Term :: Atom Quantifier — a Quantifier (`*` `+` `?`) must
    // follow a quantifiable Atom. With nothing to its left there is no
    // Atom, so a leading quantifier metacharacter is a Syntax Error.
    // Unlike the stray `{`/`}`/`]` above, these are never literals in any
    // mode: Annex B §B.1.2's ExtendedPatternCharacter explicitly excludes
    // `* + ?`, so the fallback would reject them too — Perlex owns the
    // verdict directly rather than deferring.
    try expectCompile("*a", .syntax_error);
    try expectCompile("+a", .syntax_error);
    try expectCompile("?a", .syntax_error);
    try expectCompile("**a", .syntax_error);
    try expectCompile("++a", .syntax_error);
    try expectCompile("??a", .syntax_error);
    try expectCompile("??", .syntax_error); // a lazy `?` of nothing
    // Already a Syntax Error under /u — the verdict is mode-independent.
    try expectCompileFlags("*", uflags, .syntax_error);
    try expectCompileFlags("*?", uflags, .syntax_error);
    try expectCompileFlags("+", uflags, .syntax_error);
    try expectCompileFlags("+?", uflags, .syntax_error);
    try expectCompileFlags("?", uflags, .syntax_error);
    try expectCompileFlags("??", uflags, .syntax_error);
}

test "perlex: a stacked quantifier is a syntax error (§22.2.1)" {
    // `a**` parses `a*` as a Term, then meets a second `*` with no Atom
    // left to quantify — the §22.2.1 nothing-to-repeat early error again.
    // A lazy marker is a single trailing `?`, so `a??` is the lazy
    // optional and only the *third* `?` in `a???` is the dangling one.
    try expectCompile("a**", .syntax_error);
    try expectCompile("a++", .syntax_error);
    try expectCompile("a???", .syntax_error);
    try expectCompile("a????", .syntax_error);
    try expectCompile("a***", .syntax_error);
    try expectCompile("a+++", .syntax_error);
    // The single-quantifier forms these decay from still match.
    try expectMatch("a*", "aaa", "aaa");
    try expectMatch("a+?", "aaa", "a"); // lazy: minimum one
    try expectMatch("a??", "a", ""); // lazy optional: prefers empty
}

test "perlex: out-of-range numeric backreference is a syntax error" {
    try expectCompile("\\1", .syntax_error); // no capturing groups
    try expectCompile("(a)\\2", .syntax_error); // \2 past the one group
    try expectCompileFlags("\\1", uflags, .syntax_error); // also under /u
    // In-range references (including a forward reference) still compile.
    try expectMatch("(a)\\1", "aa", "aa,a");
    try expectMatch("\\1(a)", "a", "a,a");
}

test "perlex: \\u{} code point past 0x10FFFF is a syntax error (§22.2.1.1)" {
    // §22.2.1.1: a `\u{CodePoint}` whose MV exceeds 0x10FFFF is an early
    // error. Under /u (or /v) — past the non-Unicode Annex B identity-escape
    // gate — Perlex owns that verdict directly, exactly like the out-of-range
    // numeric backreference above; it does not defer. The accumulator must be
    // u32: a u21 `*%` would wrap a too-large value back under the 0x10FFFF cap
    // and silently match (`\u{200000}` → NUL, `\u{300000}` → U+100000).
    try expectCompileFlags("\\u{200000}", uflags, .syntax_error); // u21 *% wrapped to 0
    try expectCompileFlags("\\u{300000}", uflags, .syntax_error); // u21 *% wrapped to U+100000
    try expectCompileFlags("\\u{110000}", uflags, .syntax_error); // smallest over-range
    try expectCompileFlags("\\u{FFFFFF}", uflags, .syntax_error);
    try expectCompileFlags("\\u{200000}", .{ .unicode_sets = true }, .syntax_error); // also /v
    // Boundary + ordinary supplementary code points still compile (the guard
    // is `>`, not `>=`).
    try expectCompileFlags("\\u{10FFFF}", uflags, .match); // max valid code point
    try expectCompileFlags("\\u{1F600}", uflags, .match);
    // Without /u or /v, `\u{…}` matches no production (a §22.2.1.1 early
    // error; only Annex B reads `\u` as a literal 'u'), so it is a
    // SyntaxError before the code-point value is even examined.
    try expectCompile("\\u{200000}", .syntax_error);
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

test "perlex: lookahead snapshot survives a large slot array" {
    // The lookaround capture-snapshot buffer is inline up to
    // `lookaround_inline_slots`, then spills to the heap. This pattern
    // has 18 groups (incl. the whole match) → 36 slots > the inline
    // size, so it drives the heap-spill path: the positive lookahead's
    // capture (group 1) plus all 16 sequence captures must round-trip
    // through the heap-allocated snapshot intact.
    try expectMatch(
        "(?=(a))(a)(b)(c)(d)(e)(f)(g)(h)(i)(j)(k)(l)(m)(n)(o)(p)",
        "abcdefghijklmnop",
        "abcdefghijklmnop,a,a,b,c,d,e,f,g,h,i,j,k,l,m,n,o,p",
    );
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

// Backward matching enters a group at its right boundary, so capture
// saves are emitted end-slot-first; a backreference matches the captured
// text *ending* at the cursor; a nested assertion re-anchors with its own
// direction. Expected captures come from the cross-engine differential
// (engine262 authority). `expectCaps` renders each group as `'substr'`
// (participating) or `undef` (non-participating), space-joined.

test "perlex: capturing group inside a lookbehind" {
    try expectCaps("(?<=(\\w))f", "xf", "'f' 'x'");
    try expectCaps("(?<=(\\w(\\w)))def", "abdef", "'def' 'ab' 'b'");
    // Quantified capture: the leftmost (last-written, backward) iteration wins.
    try expectCaps("(?<=(\\w)+)f", "abcf", "'f' 'a'");
    // Alternation: only the taken branch's group participates.
    try expectCaps("(?<=(bc)|(cd)).", "bcX", "'X' 'bc' undef");
}

test "perlex: backreference inside a lookbehind" {
    // Group set *outside* the lookbehind, referenced within it.
    try expectCaps("(.)(?<=\\1\\1)", "aa", "'a' 'a'");
    // Source-order forward reference: backward execution sets the group
    // (rightmost) before the `\1` to its left runs.
    try expectCaps("(?<=\\1(\\w))d", "xxd", "'d' 'x'");
    try expectNoMatch("(?<=\\1(\\w))d", "xd"); // nothing to the left of the group
}

test "perlex: backreference inside a lookbehind under /i (ASCII fold)" {
    try expectCapsFlags("^(f)oo(?<=^\\1o+)$", .{ .ignore_case = true }, "Foo", "'Foo' 'F'");
}

test "perlex: nested assertion inside a lookbehind" {
    try expectMatch("(?<=ab(?=c)\\wd)\\w\\w", "abcdXY", "XY"); // nested lookahead
    try expectMatch("(?<=\\B)(?<=c(?<=\\w))\\w{3}", "abcdef", "def"); // nested lookbehind + \B
}

// ── §22.2.1 \c ControlLetter ────────────────────────────────────────
// CharacterEscape :: `c` ControlLetter — the value is the letter's code
// point mod 32, so `\cA`..`\cZ` (and lowercase) map to U+0001..U+001A.

test "perlex: \\c control-letter escapes" {
    try expectMatch("\\cA", "\x01", "\x01"); // 'A' % 32 = 1
    try expectMatch("\\cI", "\x09", "\x09"); // tab
    try expectMatch("\\cM", "\x0D", "\x0D"); // CR
    try expectMatch("\\cZ", "\x1A", "\x1A");
    try expectMatch("\\cj", "\x0A", "\x0A"); // lowercase: 'j' % 32 = 10 (LF)
    try expectMatch("[\\cI]", "\x09", "\x09"); // inside a class
}

test "perlex: \\c control-letter escapes under /u" {
    try expectMatchFlags("\\cA", uf, "\x01", "\x01");
    try expectMatchFlags("[\\cj]", uf, "\x0A", "\x0A");
}

test "perlex: \\c not followed by a letter is a /u early error" {
    // §22.2.1.1: under /u or /v, `\c` requires a ControlLetter.
    try expectCompileFlags("\\c", uf, .syntax_error);
    try expectCompileFlags("\\c0", uf, .syntax_error);
    try expectCompileFlags("\\c_", uf, .syntax_error);
    try expectCompileFlags("[\\c]", uf, .syntax_error);
    try expectCompileFlags("[\\c0]", uf, .syntax_error);
}

test "perlex: \\c not followed by a letter is a SyntaxError in every mode (§22.2.1)" {
    // §22.2.1 CharacterEscape :: `c` ControlLetter requires a [A-Za-z]; with
    // no letter the only production left is IdentityEscape, and `c` is
    // UnicodeIDContinue — excluded under +UnicodeMode (SyntaxCharacter or `/`
    // only) and, in the main grammar, under ~UnicodeMode too (SourceCharacter
    // but not UnicodeIDContinue). So `\c<non-letter>` / a bare `\c` is a
    // §22.2.1.1 early error in every mode. Only Annex B §B.1.4 reread it as a
    // literal (`\c0` → U+0010, bare `\c` → 'c'); Cynic's strict-only,
    // non-browser target rejects it (browser V8 / JSC / SpiderMonkey accept
    // the Annex B form).
    try expectCompile("\\c", .syntax_error);
    try expectCompile("\\c0", .syntax_error);
    try expectCompile("[\\c0]", .syntax_error);
    try expectCompile("[\\c_]", .syntax_error);
    // A `\c0` low bound makes the class a SyntaxError before the (separately
    // invalid, reversed) `d-G` range is even reached.
    try expectCompile("[\\c0001d-G]", .syntax_error);
}

// ── §22.2.1.1 incomplete \x / \u escapes ────────────────────────────
// A \x with fewer than two hex digits, a \u with fewer than four, or a
// malformed \u{…} is an early error under /u or /v. Without /u each is
// Annex B identity-escape leniency (`\x` → literal 'x', …) the libregexp
// fallback still owns.

test "perlex: incomplete \\x escape is a /u early error" {
    try expectCompileFlags("\\x", uf, .syntax_error);
    try expectCompileFlags("\\x1", uf, .syntax_error);
    try expectCompileFlags("[\\x]", uf, .syntax_error);
    try expectCompileFlags("[\\x1]", uf, .syntax_error);
}

test "perlex: incomplete \\u escape is a /u early error" {
    try expectCompileFlags("\\u", uf, .syntax_error);
    try expectCompileFlags("\\u1", uf, .syntax_error);
    try expectCompileFlags("\\u12", uf, .syntax_error);
    try expectCompileFlags("\\u123", uf, .syntax_error);
    try expectCompileFlags("[\\u123]", uf, .syntax_error);
}

test "perlex: malformed \\u{...} is a /u early error" {
    try expectCompileFlags("\\u{", uf, .syntax_error);
    try expectCompileFlags("\\u{1", uf, .syntax_error); // unterminated
    try expectCompileFlags("\\u{}", uf, .syntax_error); // empty
    try expectCompileFlags("[\\u{1]", uf, .syntax_error);
}

test "perlex: incomplete \\x / 4-digit \\u escapes are a SyntaxError in every mode (§22.2.1)" {
    // §22.2.1 main grammar: an incomplete `\x`/`\u` is not a valid
    // CharacterEscape, and the only remaining production — IdentityEscape —
    // excludes `x`/`u` (both UnicodeIDContinue) in every mode. Only Annex B
    // §B.1.2 rereads them as literals (`\x` → 'x'), which Cynic's strict-only,
    // non-browser target rejects.
    try expectCompile("\\x", .syntax_error);
    try expectCompile("\\x1", .syntax_error);
    try expectCompile("\\u", .syntax_error);
    try expectCompile("\\u12", .syntax_error);
}

test "perlex: a non-/u \\u{…} is a SyntaxError (§22.2.1.1)" {
    // Without /u, `\u{…}` matches no production under the main grammar
    // (RegExpUnicodeEscapeSequence[~UnicodeMode] is only `\u`Hex4Digits, and
    // `u` is UnicodeIDContinue so not a valid IdentityEscape). Only Annex B
    // §B.1.2 rereads `\u` as a literal 'u'; Cynic's strict-only target drops
    // that, so the `\u{` RegExpUnicodeEscapeSequence gate rejects directly.
    try expectCompile("\\u{1", .syntax_error);
}

test "perlex: well-formed \\x / \\u escapes still match under /u" {
    try expectMatchFlags("\\x61", uf, "a", "a"); // U+0061
    try expectMatchFlags("\\u0061", uf, "a", "a");
    try expectMatchFlags("\\u{61}", uf, "a", "a");
}

// ── §22.2.1.1 invalid IdentityEscape / DecimalEscape under /u ────────
// Under /u or /v, IdentityEscape is restricted to a SyntaxCharacter or
// `/`, and a class admits no DecimalEscape. So a `\` before a digit, or
// before an arbitrary letter, is an early error. Without /u each is
// Annex B identity/octal-escape leniency the libregexp fallback owns.

test "perlex: a DecimalEscape in a class is a /u early error" {
    // §22.2.1 ClassEscape has no DecimalEscape production under +UnicodeMode.
    try expectCompileFlags("[\\1]", uf, .syntax_error);
    try expectCompileFlags("[\\7]", uf, .syntax_error);
    try expectCompileFlags("[\\8]", uf, .syntax_error); // \8 / \9 aren't octal
    try expectCompileFlags("[\\9]", uf, .syntax_error);
    try expectCompileFlags("[a\\1b]", uf, .syntax_error);
}

test "perlex: an invalid IdentityEscape letter is a /u early error" {
    // `\X` / `\K` — a letter that is neither a recognised escape nor a
    // SyntaxCharacter is not a valid IdentityEscape under /u or /v, in
    // either the atom or the class context.
    try expectCompileFlags("\\X", uf, .syntax_error);
    try expectCompileFlags("[\\X]", uf, .syntax_error);
    try expectCompileFlags("\\K", uf, .syntax_error);
    try expectCompileFlags("[\\K]", uf, .syntax_error);
}

test "perlex: invalid digit / letter escapes are a SyntaxError in every mode (§22.2.1)" {
    // §22.2.1 main grammar: a `\` before an IDContinue letter (`\X`) or a
    // digit in a class (a DecimalEscape, for which ClassEscape has no
    // production) is not a valid escape in either mode — IdentityEscape[~U]
    // is SourceCharacter but not UnicodeIDContinue, IdentityEscape[+U] is a
    // SyntaxCharacter or `/`. Only Annex B rereads them (`\X` → 'X', `\1` →
    // legacy octal), which Cynic's strict-only, non-browser target rejects.
    try expectCompile("[\\1]", .syntax_error);
    try expectCompile("[\\8]", .syntax_error);
    try expectCompile("\\X", .syntax_error);
    try expectCompile("[\\X]", .syntax_error);
    try expectCompile("[\\10b-G]", .syntax_error); // legacy octal \10 in a class
}

test "perlex: ASCII-punctuation IdentityEscape matches its literal (§22.2.1 ~U)" {
    // §22.2.1 IdentityEscape[~UnicodeMode] :: SourceCharacter but not
    // UnicodeIDContinue — this is the *main* grammar, not an Annex B
    // broadening. A `\` before ASCII punctuation that is neither a
    // SyntaxCharacter nor an identifier char is that literal, so Perlex
    // owns the whole set rather than deferring. (The Annex B widening that
    // also makes `\X` for an IDContinue letter a literal stays deferred —
    // see the test above; `X` is alphanumeric, so it never reaches here.)
    try expectMatch("\\!", "!", "!");
    try expectMatch("\\\"", "\"", "\"");
    try expectMatch("\\#", "#", "#");
    try expectMatch("\\%", "%", "%");
    try expectMatch("\\&", "&", "&");
    try expectMatch("\\'", "'", "'");
    try expectMatch("\\,", ",", ",");
    try expectMatch("\\:", ":", ":");
    try expectMatch("\\;", ";", ";");
    try expectMatch("\\<", "<", "<");
    try expectMatch("\\=", "=", "=");
    try expectMatch("\\>", ">", ">");
    try expectMatch("\\@", "@", "@");
    try expectMatch("\\`", "`", "`");
    try expectMatch("\\~", "~", "~");
    // `\/` is a valid IdentityEscape in *both* modes: the grammar's
    // explicit `/` alternative under +UnicodeMode, a non-IDContinue
    // SourceCharacter under ~UnicodeMode.
    try expectMatch("\\/", "/", "/");
    try expectMatchFlags("\\/", uf, "/", "/");
}

test "perlex: ASCII-punctuation IdentityEscape is a /u early error" {
    // Under /u or /v the IdentityEscape grammar shrinks to SyntaxCharacter
    // or `/`; ordinary punctuation is no longer escapable, so each is a
    // §22.2.1.1 early error — the verdict the /u column already gave, now
    // owned by Perlex rather than the fallback. (`\/` above is exempt: `/`
    // is the one non-SyntaxCharacter the +UnicodeMode grammar still admits.)
    try expectCompileFlags("\\!", uf, .syntax_error);
    try expectCompileFlags("\\@", uf, .syntax_error);
    try expectCompileFlags("\\~", uf, .syntax_error);
    try expectCompileFlags("\\,", uf, .syntax_error);
    try expectCompileFlags("\\;", uf, .syntax_error);
    try expectCompileFlags("\\:", .{ .unicode_sets = true }, .syntax_error); // also /v
}

test "perlex: an escaped hyphen atom matches without /u, is a /u early error (§22.2.1)" {
    // §22.2.1 IdentityEscape[~UnicodeMode] :: SourceCharacter but not
    // UnicodeIDContinue. `-` (U+002D) is not UnicodeIDContinue, so as an
    // *atom* `\-` is a valid IdentityEscape matching '-' — main grammar,
    // not an Annex B widening. Under /u or /v the atom IdentityEscape
    // grammar shrinks to SyntaxCharacter or `/`, and `-` is neither, so an
    // atom `\-` is a §22.2.1.1 early error. (Inside a class `\-` is the
    // escaped literal '-' in every mode — a different production that still
    // defers; see the test below.) Confirmed identical across the
    // production engines.
    try expectMatch("\\-", "-", "-");
    try expectMatch("a\\-b", "a-b", "a-b");
    try expectCompile("\\-", .match);
    try expectNoMatch("\\-", "x");
    try expectCompileFlags("\\-", uf, .syntax_error);
    try expectCompileFlags("\\-", vflags, .syntax_error);
}

test "perlex: an escaped hyphen inside a class is left to the fallback in every mode" {
    // Inside `[ … ]`, `\-` is the escaped literal '-' in every mode (a
    // ClassEscape under +UnicodeMode, an identity escape without it). The
    // shared class-member decoder (parseEscapedChar) can't see the class
    // context the atom path now owns, so it stays deferred — no false
    // reject of `[\-]/u` — and the fallback decides.
    try expectCompile("[\\-]", .unsupported);
    try expectCompileFlags("[\\-]", uf, .unsupported);
}

test "perlex: \\0 before a DecimalDigit is a /u early error" {
    // §22.2.1.1 CharacterEscape: under +UnicodeMode `\0` is valid only with
    // [lookahead ∉ DecimalDigit], and there is no LegacyOctalEscapeSequence.
    // So `\0` immediately before a digit is an early error, in both the atom
    // and the class context, for every digit (8 / 9 aren't octal either).
    try expectCompileFlags("\\00", uf, .syntax_error);
    try expectCompileFlags("\\07", uf, .syntax_error);
    try expectCompileFlags("\\08", uf, .syntax_error);
    try expectCompileFlags("\\09", uf, .syntax_error);
    try expectCompileFlags("[\\00]", uf, .syntax_error);
    try expectCompileFlags("[\\05]", uf, .syntax_error);
    try expectCompileFlags("[\\09]", uf, .syntax_error);
    try expectCompileFlags("\\00", .{ .unicode_sets = true }, .syntax_error);
}

test "perlex: \\0 before a digit is a SyntaxError in every mode (§22.2.1.1)" {
    // §22.2.1.1 `\0` is U+0000 only with [lookahead ∉ DecimalDigit]; the main
    // grammar has no LegacyOctalEscapeSequence, so `\0` before a digit is an
    // early error in every mode. Only Annex B rereads `\00`…`\09` as legacy
    // octal, which Cynic's strict-only, non-browser target rejects.
    try expectCompile("\\00", .syntax_error);
    try expectCompile("\\07", .syntax_error);
    try expectCompile("[\\00]", .syntax_error);
    try expectCompile("[\\09]", .syntax_error);
}

test "perlex: a lone \\0 (no trailing digit) is NUL in every mode" {
    // §22.2.1.1 `\0` with [lookahead ∉ DecimalDigit] is U+0000 — unaffected.
    try expectMatch("\\0", "\x00", "\x00");
    try expectMatchFlags("\\0", uf, "\x00", "\x00");
    try expectMatchFlags("\\0a", uf, "\x00a", "\x00a"); // NUL then literal 'a'
    try expectMatchFlags("[\\0]", uf, "\x00", "\x00");
}

test "perlex: \\p / \\P in a class defers when no resolver is injected" {
    // §22.2.1 ClassEscape includes `\p{…}` / `\P{…}` under +UnicodeMode.
    // The class path resolves these via the injected resolver; with none
    // (this compile path), the property can't be placed, so the whole
    // pattern defers to the fallback rather than being rejected.
    try expectCompileFlags("[\\p{Hex}]", uf, .unsupported);
    try expectCompileFlags("[\\p{Hex}\\P{Hex}]", uf, .unsupported);
}

test "perlex: \\p{} property escapes resolve inside [ … ] under /u" {
    // §22.2.1 ClassRanges — a `\p{…}` ClassAtom contributes its resolved
    // code-point set to the union of the class members; `\P{…}` contributes
    // the complement. The stub resolver knows the gc values Lu / Ll / L.
    try expectMatchProp("[\\p{Lu}]", "A", "A");
    try expectNoMatchProp("[\\p{Lu}]", "a");
    // Union of two properties.
    try expectMatchProp("[\\p{Lu}\\p{Ll}]", "A", "A");
    try expectMatchProp("[\\p{Lu}\\p{Ll}]", "a", "a");
    // A property unioned with a literal range.
    try expectMatchProp("[\\p{Ll}0-9]", "5", "5");
    try expectMatchProp("[\\p{Ll}0-9]", "q", "q");
    try expectNoMatchProp("[\\p{Ll}0-9]", "A");
    // `\P{…}` (a negated property) inside a class is the complement set.
    try expectMatchProp("[\\P{Lu}]", "a", "a");
    try expectNoMatchProp("[\\P{Lu}]", "A");
    // `[^ … ]` negates the whole union.
    try expectMatchProp("[^\\p{Lu}]", "a", "a");
    try expectNoMatchProp("[^\\p{Lu}]", "A");
}

test "perlex: malformed \\p inside [ … ] under /u is a syntax error" {
    // A bare `\p`/`\P` with no `{…}` is a §22.2.1.1 early error — scanProperty
    // owns the verdict at parse time, before any resolver runs.
    try expectCompileProp("[\\p]", uflags, .syntax_error);
    try expectCompileProp("[\\P]", uflags, .syntax_error);
    try expectCompileProp("[\\p{}]", uflags, .syntax_error); // empty value
    // A `\p{…}` ClassAtom may not be a `-` range bound (§22.2.1.1).
    try expectCompileProp("[\\p{Lu}-a]", uflags, .syntax_error);
    try expectCompileProp("[a-\\p{Lu}]", uflags, .syntax_error);
}

test "perlex: \\p inside [ … ] non-/u is a SyntaxError; an unknown /u property defers" {
    // Without /u or /v, `\p` matches no production (a §22.2.1.1 early error;
    // only Annex B reads it as literal 'p') — rejected before scanProperty.
    try expectCompileProp("[\\p{Lu}]", .{}, .syntax_error);
    // Under /u, a well-formed name the resolver declines defers the whole
    // pattern (the production resolver knows it; the stub here does not).
    try expectCompileProp("[\\p{Nd}]", uflags, .unsupported);
}

// ── §22.2.1.1 a CharacterClassEscape as a class-range bound (/u) ─────
// NonemptyClassRanges (+UnicodeMode): it is a Syntax Error for either
// bound of a `-` range to be a CharacterClassEscape (\d \D \s \S \w \W),
// e.g. `[\d-a]` / `[a-\d]` / `[\D-\D]`. Without /u the `-` and the
// shorthand are matched literally (Annex B), which the fallback owns.

test "perlex: a class-escape low range bound is a /u early error" {
    try expectCompileFlags("[\\d-a]", uf, .syntax_error);
    try expectCompileFlags("[\\s-a]", uf, .syntax_error);
    try expectCompileFlags("[\\w-a]", uf, .syntax_error);
    try expectCompileFlags("[\\D-a]", uf, .syntax_error);
    try expectCompileFlags("[\\S-a]", uf, .syntax_error);
    try expectCompileFlags("[\\W-a]", uf, .syntax_error);
}

test "perlex: a class-escape high range bound is a /u early error" {
    try expectCompileFlags("[a-\\d]", uf, .syntax_error);
    try expectCompileFlags("[a-\\s]", uf, .syntax_error);
    try expectCompileFlags("[a-\\w]", uf, .syntax_error);
    try expectCompileFlags("[a-\\D]", uf, .syntax_error);
    try expectCompileFlags("[a-\\S]", uf, .syntax_error);
    try expectCompileFlags("[a-\\W]", uf, .syntax_error);
}

test "perlex: a class escape on both range bounds is a /u early error" {
    try expectCompileFlags("[\\d-\\d]", uf, .syntax_error);
    try expectCompileFlags("[\\D-\\D]", uf, .syntax_error);
    try expectCompileFlags("[\\s-\\s]", uf, .syntax_error);
    try expectCompileFlags("[\\S-\\S]", uf, .syntax_error);
    try expectCompileFlags("[\\w-\\w]", uf, .syntax_error);
    try expectCompileFlags("[\\W-\\W]", uf, .syntax_error);
}

test "perlex: a class-escape range bound defers without /u (Annex B)" {
    // The `-` and the shorthand are matched literally; the fallback owns it.
    try expectCompile("[\\d-a]", .unsupported);
    try expectCompile("[a-\\d]", .unsupported);
    try expectCompile("[\\D-a]", .unsupported);
    try expectCompile("[a-\\W]", .unsupported);
}

test "perlex: a standalone negated class escape under /u defers, not rejected" {
    // `\D \S \W` standalone is a valid class member. Under /u Perlex can't
    // complement it at parse time (it isn't handed `i`, so it can't rule out
    // the /iu fold orbits), so it defers to the fallback — but it must NOT
    // become a SyntaxError just because the range path owns class-escape
    // *bounds* under /u. Off /u the same member is owned (complemented in
    // place) — see "negated class shorthands \D \S \W owned in non-/u
    // classes".
    try expectCompileFlags("[\\D]", uf, .unsupported);
    try expectCompileFlags("[\\S]", uf, .unsupported);
    try expectCompileFlags("[\\W]", uf, .unsupported);
}

test "perlex: \\d \\s \\w still match standalone and with a trailing dash" {
    // No regression for the shorthands Perlex represents as ranges; a
    // trailing `-` before `]` is a literal, not a range bound.
    try expectMatchFlags("[\\d]", uf, "5", "5");
    try expectMatchFlags("[\\w]", uf, "a", "a");
    try expectMatch("[\\d-]", "-", "-");
    try expectMatch("[\\d-]", "7", "7");
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

// ── §22.2.1 non-ASCII literal PatternCharacters ─────────────────────

test "perlex: a BMP non-ASCII literal matches its code unit (§22.2.1)" {
    const gpa = testing.allocator;
    // U+03BB "λ" — one UTF-16 code unit, identical under code-unit and
    // code-point semantics, so it matches in every mode.
    const input = [_]u16{0x03BB};
    inline for ([_]perlex.Flags{ .{}, uf, .{ .unicode_sets = true } }) |fl| {
        var r = try perlex.compile(gpa, "λ", fl);
        try testing.expect(r == .ok);
        defer r.ok.deinit();
        var m = (try perlex.exec(u16, gpa, &r.ok, &input, 0)) orelse return error.ExpectedMatch;
        defer m.deinit(gpa);
        try testing.expectEqual(@as(usize, 0), m.slots[0]);
        try testing.expectEqual(@as(usize, 1), m.slots[1]);
    }
}

test "perlex: an astral literal is one code point under /u and /v (§22.2.1)" {
    const gpa = testing.allocator;
    // U+20BB7 "𠮷" — surrogate pair [0xD842, 0xDFB7]. Under code-point
    // semantics the literal spans the whole 2-unit pair.
    const input = [_]u16{ 0xD842, 0xDFB7 };
    inline for ([_]perlex.Flags{ uf, .{ .unicode_sets = true } }) |fl| {
        var r = try perlex.compile(gpa, "𠮷", fl);
        try testing.expect(r == .ok);
        defer r.ok.deinit();
        var m = (try perlex.exec(u16, gpa, &r.ok, &input, 0)) orelse return error.ExpectedMatch;
        defer m.deinit(gpa);
        try testing.expectEqual(@as(usize, 0), m.slots[0]);
        try testing.expectEqual(@as(usize, 2), m.slots[1]);
    }
}

test "perlex: a quantified astral literal repeats the whole code point under /u" {
    const gpa = testing.allocator;
    // U+1D306 "𝌆" = [0xD834, 0xDF06]; `{2}` matches the code point twice
    // (4 code units), confirming the quantifier binds the whole point.
    const input = [_]u16{ 0xD834, 0xDF06, 0xD834, 0xDF06 };
    var r = try perlex.compile(gpa, "𝌆{2}", uf);
    try testing.expect(r == .ok);
    defer r.ok.deinit();
    var m = (try perlex.exec(u16, gpa, &r.ok, &input, 0)) orelse return error.ExpectedMatch;
    defer m.deinit(gpa);
    try testing.expectEqual(@as(usize, 0), m.slots[0]);
    try testing.expectEqual(@as(usize, 4), m.slots[1]);
}

test "perlex: an astral literal is two code units without /u (§22.2.1)" {
    const gpa = testing.allocator;
    // Without a flag the source is a UTF-16 code-unit sequence, so "𠮷"
    // is the two units [0xD842, 0xDFB7] and a following quantifier binds
    // only the trailing (low) surrogate — `/𠮷+/` is `\uD842(\uDFB7)+`.
    // Cross-engine differential (engine262 + V8/JSC/SM/Hermes/QuickJS):
    // /𠮷/ → 2, /𠮷+/ over [hi,lo,lo] → 3, /𠮷/ over [hi] → no match.
    const pair = [_]u16{ 0xD842, 0xDFB7 };
    {
        var r = try perlex.compile(gpa, "𠮷", .{});
        try testing.expect(r == .ok);
        defer r.ok.deinit();
        var m = (try perlex.exec(u16, gpa, &r.ok, &pair, 0)) orelse return error.ExpectedMatch;
        defer m.deinit(gpa);
        try testing.expectEqual(@as(usize, 2), m.slots[1]);
    }
    {
        // `+` binds the low surrogate: high, then one-or-more lows.
        const input = [_]u16{ 0xD842, 0xDFB7, 0xDFB7 };
        var r = try perlex.compile(gpa, "𠮷+", .{});
        try testing.expect(r == .ok);
        defer r.ok.deinit();
        var m = (try perlex.exec(u16, gpa, &r.ok, &input, 0)) orelse return error.ExpectedMatch;
        defer m.deinit(gpa);
        try testing.expectEqual(@as(usize, 3), m.slots[1]);
    }
    {
        // The lone high surrogate alone is not the two-unit literal.
        const lone = [_]u16{0xD842};
        var r = try perlex.compile(gpa, "𠮷", .{});
        try testing.expect(r == .ok);
        defer r.ok.deinit();
        try testing.expect((try perlex.exec(u16, gpa, &r.ok, &lone, 0)) == null);
    }
}

// ── §22.2.1 non-ASCII literals inside [ … ] classes ─────────────────

test "perlex: a BMP non-ASCII class member matches its code unit (§22.2.1)" {
    const gpa = testing.allocator;
    // U+03BB "λ" is one of three BMP members in `[αλω]`; it matches as a
    // single code unit, identical under code-unit and code-point semantics.
    const input = [_]u16{0x03BB};
    inline for ([_]perlex.Flags{ .{}, uf }) |fl| {
        var r = try perlex.compile(gpa, "[αλω]", fl);
        try testing.expect(r == .ok);
        defer r.ok.deinit();
        var m = (try perlex.exec(u16, gpa, &r.ok, &input, 0)) orelse return error.ExpectedMatch;
        defer m.deinit(gpa);
        try testing.expectEqual(@as(usize, 0), m.slots[0]);
        try testing.expectEqual(@as(usize, 1), m.slots[1]);
    }
}

test "perlex: an astral class range matches a code point in bounds under /u (§22.2.1)" {
    const gpa = testing.allocator;
    // `[💩-💫]` is the range U+1F4A9..U+1F4AB. "💪" U+1F4AA is inside it
    // and matches as a whole 2-unit code point; "💚" U+1F49A is below it.
    var r = try perlex.compile(gpa, "[💩-💫]", uf);
    try testing.expect(r == .ok);
    defer r.ok.deinit();
    {
        const flexed = [_]u16{ 0xD83D, 0xDCAA }; // 💪 U+1F4AA, in range
        var m = (try perlex.exec(u16, gpa, &r.ok, &flexed, 0)) orelse return error.ExpectedMatch;
        defer m.deinit(gpa);
        try testing.expectEqual(@as(usize, 0), m.slots[0]);
        try testing.expectEqual(@as(usize, 2), m.slots[1]);
    }
    {
        const heart = [_]u16{ 0xD83D, 0xDC9A }; // 💚 U+1F49A, below range
        try testing.expect((try perlex.exec(u16, gpa, &r.ok, &heart, 0)) == null);
    }
}

test "perlex: a negated astral class excludes its member under /u (§22.2.1)" {
    const gpa = testing.allocator;
    // `[^𝌆]` excludes U+1D306 and matches any other code point. "𝌆" is
    // rejected; "💩" U+1F4A9 matches as a whole 2-unit code point.
    var r = try perlex.compile(gpa, "[^𝌆]", uf);
    try testing.expect(r == .ok);
    defer r.ok.deinit();
    {
        const tetragram = [_]u16{ 0xD834, 0xDF06 }; // 𝌆 U+1D306, excluded
        try testing.expect((try perlex.exec(u16, gpa, &r.ok, &tetragram, 0)) == null);
    }
    {
        const poo = [_]u16{ 0xD83D, 0xDCA9 }; // 💩 U+1F4A9, not excluded
        var m = (try perlex.exec(u16, gpa, &r.ok, &poo, 0)) orelse return error.ExpectedMatch;
        defer m.deinit(gpa);
        try testing.expectEqual(@as(usize, 0), m.slots[0]);
        try testing.expectEqual(@as(usize, 2), m.slots[1]);
    }
    {
        // §22.2.2.1: the scan steps over the excluded pair by a whole
        // code point (2 units), so a following 'a' matches at index 2 —
        // the leftmost start never lands on the mid-pair low surrogate.
        const after = [_]u16{ 0xD834, 0xDF06, 'a' }; // "𝌆a"
        var m = (try perlex.exec(u16, gpa, &r.ok, &after, 0)) orelse return error.ExpectedMatch;
        defer m.deinit(gpa);
        try testing.expectEqual(@as(usize, 2), m.slots[0]);
        try testing.expectEqual(@as(usize, 3), m.slots[1]);
    }
}

test "perlex: a non-/u astral class member matches either surrogate unit (§22.2.1)" {
    const gpa = testing.allocator;
    // Without /u or /v the pattern source is a code-unit sequence, so an
    // astral ClassAtom is two single-unit members — the alternatives of its
    // surrogate pair. `[𠮷]` (U+20BB7 → D842 DFB7) is the union of those two
    // members, so it matches a single code unit equal to either half. It
    // does NOT match the pair as one code point (that needs /u).
    var r = try perlex.compile(gpa, "[𠮷]", .{});
    try testing.expect(r == .ok);
    defer r.ok.deinit();
    {
        const lead = [_]u16{0xD842}; // lead surrogate alone — one unit
        var m = (try perlex.exec(u16, gpa, &r.ok, &lead, 0)) orelse return error.ExpectedMatch;
        defer m.deinit(gpa);
        try testing.expectEqual(@as(usize, 0), m.slots[0]);
        try testing.expectEqual(@as(usize, 1), m.slots[1]);
    }
    {
        const trail = [_]u16{0xDFB7}; // trail surrogate alone — one unit
        var m = (try perlex.exec(u16, gpa, &r.ok, &trail, 0)) orelse return error.ExpectedMatch;
        defer m.deinit(gpa);
        try testing.expectEqual(@as(usize, 0), m.slots[0]);
        try testing.expectEqual(@as(usize, 1), m.slots[1]);
    }
    {
        const other = [_]u16{'x'}; // neither half — no match
        try testing.expect((try perlex.exec(u16, gpa, &r.ok, &other, 0)) == null);
    }
}

test "perlex: a non-/u astral class member is one code unit, not the pair (§22.2.1)" {
    const gpa = testing.allocator;
    // `^[𠮷]$` matches only a one-unit input — a single surrogate half.
    // Given the whole pair (2 units) the anchored class fails: it consumes
    // exactly one unit, leaving `$` unsatisfied at index 1.
    var r = try perlex.compile(gpa, "^[𠮷]$", .{});
    try testing.expect(r == .ok);
    defer r.ok.deinit();
    {
        const half = [_]u16{0xD842}; // one unit — anchored match
        var m = (try perlex.exec(u16, gpa, &r.ok, &half, 0)) orelse return error.ExpectedMatch;
        defer m.deinit(gpa);
        try testing.expectEqual(@as(usize, 0), m.slots[0]);
        try testing.expectEqual(@as(usize, 1), m.slots[1]);
    }
    {
        const pair = [_]u16{ 0xD842, 0xDFB7 }; // two units — no anchored match
        try testing.expect((try perlex.exec(u16, gpa, &r.ok, &pair, 0)) == null);
    }
}

test "perlex: a non-/u negated astral class excludes both surrogate units (§22.2.1)" {
    const gpa = testing.allocator;
    // `[^𠮷]` excludes both D842 and DFB7; any other unit matches.
    var r = try perlex.compile(gpa, "[^𠮷]", .{});
    try testing.expect(r == .ok);
    defer r.ok.deinit();
    {
        const x = [_]u16{'x'}; // not excluded
        var m = (try perlex.exec(u16, gpa, &r.ok, &x, 0)) orelse return error.ExpectedMatch;
        defer m.deinit(gpa);
        try testing.expectEqual(@as(usize, 0), m.slots[0]);
        try testing.expectEqual(@as(usize, 1), m.slots[1]);
    }
    {
        const lead = [_]u16{0xD842}; // excluded
        try testing.expect((try perlex.exec(u16, gpa, &r.ok, &lead, 0)) == null);
    }
    {
        const trail = [_]u16{0xDFB7}; // excluded
        try testing.expect((try perlex.exec(u16, gpa, &r.ok, &trail, 0)) == null);
    }
}

test "perlex: an astral class member with /i or a range bound still defers (§22.2.1)" {
    // The owned path is the bare non-/u astral ClassAtom. With `i` the
    // surrogate units sit on the non-Unicode fold gate (the parser can't
    // rule out a non-ASCII fold orbit), and as a `-` range bound the source
    // splits across the dash — both keep deferring to the fallback.
    try expectCompileFlags("[𠮷]", .{ .ignore_case = true }, .unsupported);
    try expectCompile("[𠮷-a]", .unsupported);
    try expectCompile("[a-𠮷]", .unsupported);
}

// ── §22.2.1 \u surrogate escapes under /u (combine + lone) ──────────

test "perlex: a lone surrogate \\u escape matches its code unit under /u (§22.2.1)" {
    const gpa = testing.allocator;
    // `\uDF06` is a lone low surrogate; under /u it denotes code point
    // U+DF06 and matches a lone low-surrogate code unit.
    var r = try perlex.compile(gpa, "\\udf06", uf);
    try testing.expect(r == .ok);
    defer r.ok.deinit();
    {
        const lone = [_]u16{0xDF06};
        var m = (try perlex.exec(u16, gpa, &r.ok, &lone, 0)) orelse return error.ExpectedMatch;
        defer m.deinit(gpa);
        try testing.expectEqual(@as(usize, 0), m.slots[0]);
        try testing.expectEqual(@as(usize, 1), m.slots[1]);
    }
    {
        // After a non-surrogate the scan steps by one unit and matches at 1.
        const after = [_]u16{ 'a', 0xDF06 };
        var m = (try perlex.exec(u16, gpa, &r.ok, &after, 0)) orelse return error.ExpectedMatch;
        defer m.deinit(gpa);
        try testing.expectEqual(@as(usize, 1), m.slots[0]);
        try testing.expectEqual(@as(usize, 2), m.slots[1]);
    }
}

test "perlex: a \\u surrogate pair combines into one code point under /u (§22.2.1)" {
    const gpa = testing.allocator;
    // `𝌆` is the surrogate pair for U+1D306; under /u the two
    // escapes combine into that single supplementary code point (2 units).
    var r = try perlex.compile(gpa, "\\ud834\\udf06", uf);
    try testing.expect(r == .ok);
    defer r.ok.deinit();
    const tetragram = [_]u16{ 0xD834, 0xDF06 };
    var m = (try perlex.exec(u16, gpa, &r.ok, &tetragram, 0)) orelse return error.ExpectedMatch;
    defer m.deinit(gpa);
    try testing.expectEqual(@as(usize, 0), m.slots[0]);
    try testing.expectEqual(@as(usize, 2), m.slots[1]);
}

test "perlex: a \\u surrogate pair combines as one class member under /u (§22.2.1)" {
    const gpa = testing.allocator;
    // `[𐀀]` combines into the single member U+10000; a lone
    // surrogate half is not that code point, so it does not match.
    var r = try perlex.compile(gpa, "[\\ud800\\udc00]", uf);
    try testing.expect(r == .ok);
    defer r.ok.deinit();
    {
        const supp = [_]u16{ 0xD800, 0xDC00 }; // U+10000
        var m = (try perlex.exec(u16, gpa, &r.ok, &supp, 0)) orelse return error.ExpectedMatch;
        defer m.deinit(gpa);
        try testing.expectEqual(@as(usize, 0), m.slots[0]);
        try testing.expectEqual(@as(usize, 2), m.slots[1]);
    }
    {
        const lone_hi = [_]u16{0xD800};
        try testing.expect((try perlex.exec(u16, gpa, &r.ok, &lone_hi, 0)) == null);
    }
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

// ── §22.2.2.3 RepeatMatcher zero-width progress guard ───────────────
//
// Step 2.b: "If min = 0 and y.[[EndIndex]] = x.[[EndIndex]], return
// FAILURE." — an *optional* iteration of a body that can match the
// empty string fails the moment it consumes nothing, so the loop stops
// and that empty iteration's captures roll back to undefined. Step 4
// clears the body's groups before each iteration. A *mandatory*
// iteration (one of the first `min`) is not guarded: it participates
// even when empty, capturing "". The expected captures below come from
// the cross-engine differential (engine262 authority; V8 / JSC /
// SpiderMonkey / QuickJS unanimous). `expectCaps` renders a
// participating group as 'substring' (empty as '') and a
// non-participating group as `undef`, the distinction this guard turns on.

test "perlex: nullable star body stops on the first empty optional iteration" {
    // Each iteration consumes one 'a' until the input runs out; the final
    // empty iteration is rolled back, so the group holds the last
    // non-empty capture, never "".
    try expectCaps("(a?)*", "aaa", "'aaa' 'a'");
    try expectCaps("(a|)*", "aaa", "'aaa' 'a'");
    try expectCaps("(|a)*", "aaa", "'aaa' 'a'");
    // A greedy inner star swallows the whole run in one iteration.
    try expectCaps("(a*)*", "aaa", "'aaa' 'aaa'");
    try expectCaps("(a*)*", "aab", "'aa' 'aa'");
    try expectCaps("(a*)*", "aaab", "'aaa' 'aaa'");
    // No progress at all → zero iterations → the group never participates.
    try expectCaps("(a?)*", "", "'' undef");
    try expectCaps("(a?)*", "b", "'' undef");
    try expectCaps("(a*)*", "", "'' undef");
}

test "perlex: nullable body — mandatory iterations participate, optional ones are guarded" {
    // `{2}` / `{2,}` — the two mandatory iterations are unguarded, so an
    // empty body still captures "".
    try expectCaps("(a?){2}", "b", "'' ''");
    try expectCaps("(a?){2,}", "b", "'' ''");
    // `+` is min = 1: the one mandatory empty iteration captures "".
    try expectCaps("(a*)+", "", "'' ''");
    try expectCaps("(a?)+", "aaa", "'aaa' 'a'");
    // `{0,3}` — every iteration is optional, so the first empty one is
    // rolled back and the group stays undefined.
    try expectCaps("(a?){0,3}", "b", "'' undef");
}

test "perlex: nullable body — lazy, empty non-capture, and concat" {
    // Lazy `*?` prefers zero iterations: the group never participates.
    try expectCaps("(a?)*?", "aaa", "'' undef");
    // A capture-free nullable body: only the whole-match group exists.
    try expectCaps("(?:)*", "aaa", "''");
    // Concatenated nullable atoms inside the body.
    try expectCaps("(a?b?)*", "ab", "'ab' 'ab'");
}

test "perlex: nested nullable quantifier bodies use independent progress marks" {
    // Two nested guarded loops → two scratch slots; each tracks its own
    // iteration's start so an inner empty iteration can't fool the outer.
    try expectCaps("((a?)*)*", "aa", "'aa' 'aa' 'a'");
    try expectCaps("((a)?)*", "aa", "'aa' 'a' 'a'");
}

test "perlex: a nullable assertion wrapped in a group is owned, not deferred" {
    // §22.2.1: a *directly*-quantified assertion (`(?=a)?`) is a
    // QuantifiableAssertion — a /u-vs-non-/u mode split the fallback owns.
    // But wrapping it in a group makes the `?` bind the *group*, which is
    // always legal, and §22.2.2.3 step 2.b's zero-width guard handles the
    // empty loop. engine262 is the authority for the capture participation.

    // Optional (min = 0): the lookahead succeeds and captures "abc", but
    // the iteration is zero-width, so step 2.b skips it and group 1 rolls
    // back to undefined — the capture set inside the assertion must not
    // survive the guarded skip.
    try expectCaps("(?:(?=(abc)))?a", "abc", "'a' undef");
    try expectCaps("(?:(?=(abc))){0,1}a", "abc", "'a' undef");
    // The lookahead simply fails → group never set, `a` still matches.
    try expectCaps("(?:(?=(abc)))?a", "ade", "'a' undef");
    // `{1,1}` is min = 1: the one mandatory iteration is unguarded, so the
    // lookahead's group 1 *does* participate.
    try expectCaps("(?:(?=(abc))){1,1}a", "abc", "'a' 'abc'");

    // A group wrapping bare anchors (`($^)`) — same story: optional and
    // zero-width, so the inner capture rolls back to undefined.
    try expectCaps("(x)($^)?", "x", "'x' 'x' undef");
}

test "perlex: a directly-quantified lookahead is a SyntaxError in every mode" {
    // §22.2.1 has no `Assertion Quantifier` production; only Annex B §B.1.2
    // (QuantifiableAssertion) let a non-/u *lookahead* be quantified, and
    // Cynic's strict-only, non-browser target drops that. So a bare
    // quantified lookahead is a SyntaxError even without /u — wrapping it in
    // a group (above) is what makes the quantifier legal (it binds the
    // group, an Atom).
    try expectCompile("(?=a)?", .syntax_error);
    try expectCompile("(?=a)*", .syntax_error);
}

test "perlex: §22.2.1 quantified backreference bodies are owned, not deferred" {
    // A backreference's matched width is participation-dependent, but it is
    // *constant* for the duration of one quantifier evaluation when the
    // referenced group lies to its left — it only varies between evaluations
    // via that group's own backtracking. So `\1+` / `\1*` / `\k<x>+` are
    // ordinary repeats: the §22.2.2.3 progress guard handles the
    // empty-capture iteration, and standard backtracking handles the rest.
    // Captures match engine262.
    try expectCaps("(a*)b\\1+", "aabaaaa", "'aabaaaa' 'aa'");
    // Group 1 captured empty, so each `\1` iteration is zero-width: the
    // guard keeps the repeat from looping, but the literal `b` already
    // matched, so the whole match is just "b" with group 1 = "".
    try expectCaps("(a*)b\\1+", "b", "'b' ''");
    // `(a?)\1+` on "": group 1 = "", `\1+` matches empty once (guarded).
    try expectCaps("(a?)\\1+", "", "'' ''");
    try expectCaps("(a*)\\1+", "aaa", "'aaa' 'a'");
    // Lazy quantified backref.
    try expectCaps("(a*)b\\1+?", "aabaaaa", "'aabaa' 'aa'");
    // Named backref, quantified.
    try expectCaps("(?<x>a*)b\\k<x>+", "aabaaaa", "'aabaaaa' 'aa'");
    // Anchored, two quantified backrefs.
    try expectCaps("^(a+)\\1*,\\1+$", "aa,aaaa", "'aa,aaaa' 'aa'");
    // Self-referential backref inside a quantified group.
    try expectCaps("(a\\1*)+", "aaa", "'aaa' 'a'");
    try expectCaps("(\\1a)+", "aaa", "'aaa' 'a'");
    // A `{2,}` lower bound the input can't satisfy → no match.
    try expectNoMatch("(x)\\1{2,}", "xx");
}

test "perlex: §22.2.1 capture-group count up to the libregexp ceiling is owned" {
    @setEvalBranchQuota(100000);
    // The 64-group cap was a conservative deferral threshold, not a buffer
    // bound — the slot array and the per-lookaround snapshot are both
    // heap-sized at runtime. It now matches the vendored fallback's
    // CAPTURE_COUNT_MAX (255 groups including the implicit group 0, i.e.
    // ≤ 254 explicit), so any pattern the fallback would accept, Perlex
    // owns. A deeply-nested 70-group pattern (> the old 64) is owned, and
    // every group — including group 0 — captures the same span.
    const ncaps = 70;
    const pat = comptime blk: {
        var s: []const u8 = "";
        for (0..ncaps) |_| s = s ++ "(";
        s = s ++ "hello";
        for (0..ncaps) |_| s = s ++ ")";
        break :blk s;
    };
    try expectCompile(pat, .match);
    // Group 0 plus all 70 explicit groups → 71 captures, every one "hello".
    const expected = comptime blk: {
        var s: []const u8 = "'hello'";
        for (0..ncaps) |_| s = s ++ " 'hello'";
        break :blk s;
    };
    try expectCaps(pat, "hello", expected);

    // Small nested case, captures checked end-to-end.
    try expectCaps("(((x)))", "x", "'x' 'x' 'x' 'x'");

    // One past the ceiling still defers — 255 explicit groups is 256 total,
    // which the fallback also rejects ("too many captures"). Matching the
    // fallback's exact boundary keeps the deferral honest.
    const over = comptime blk: {
        var s: []const u8 = "";
        for (0..255) |_| s = s ++ "(";
        s = s ++ "x";
        for (0..255) |_| s = s ++ ")";
        break :blk s;
    };
    try expectCompile(over, .unsupported);
}

test "perlex: §22.2.1 negated class shorthands \\D \\S \\W owned in non-/u classes" {
    // A `\D \S \W` inside `[ … ]` is the set complement of `\d \s \w`.
    // Off `/u` Perlex complements the positive range set at parse time and
    // appends it as ordinary ranges, so the class is owned rather than
    // deferred. Every expectation here is engine262-authoritative (the
    // cross-engine differential agrees — node/JSC/SM/Hermes/QuickJS all
    // match).

    // Bare shorthand membership (the positive vs negated halves).
    try expectMatch("[\\D]", "a", "a");
    try expectNoMatch("[\\D]", "5");
    try expectMatch("[\\W]", "!", "!");
    try expectNoMatch("[\\W]", "_"); // `_` is a word char → excluded by \W
    try expectMatch("[\\S]", "x", "x");
    try expectNoMatch("[\\S]", " ");

    // `/i` leaves the complement unchanged: complement(\d), complement(\s)
    // and complement(\w) each contain a letter and its case-swap together
    // (or neither), so ASCII folding never flips membership. The VM's inline
    // ASCII fold is therefore a no-op on these sets.
    try expectNoMatchFlags("[\\W]", .{ .ignore_case = true }, "a");
    try expectMatchFlags("[\\W]", .{ .ignore_case = true }, "!", "!");
    try expectNoMatchFlags("[\\W]", .{ .ignore_case = true }, "A");
    try expectMatchFlags("[\\D]", .{ .ignore_case = true }, "a", "a");
    try expectNoMatchFlags("[\\D]", .{ .ignore_case = true }, "5");
    try expectMatchFlags("[\\S]", .{ .ignore_case = true }, "a", "a");
    try expectNoMatchFlags("[\\S]", .{ .ignore_case = true }, " ");

    // Mixed with a literal, combined shorthands, and double-negated.
    try expectNoMatch("[a\\S]", " "); // ` ` ∉ {a} ∪ \S
    try expectMatch("[a\\S]", "a", "a");
    try expectMatch("[\\D\\S]", " ", " "); // ` ` ∈ \D
    try expectMatch("[^\\S]", " ", " "); // ^ over \S → whitespace only
    try expectNoMatch("[^\\S]", "a");

    // The real-world census pattern that drove this increment: a config
    // line `key␣one␣=␣val` with nested `[\S]+`/whitespace groups. Group 1 is
    // the LHS run, group 2 the last ` one` repetition.
    try expectCaps(
        "([\\S]+([ \\t]+[\\S]+)*)[ \\t]*=[ \\t]*[\\S]+",
        "key one = val",
        "'key one = val' 'key one' ' one'",
    );

    // `/u` still defers. The parser is handed `unicode`/`unicode_sets` but
    // NOT `ignore_case`, so it can't tell `/u` from `/iu`; and `/iu` pulls
    // non-ASCII fold orbits (the Kelvin sign U+212A folds with `k`, so it
    // joins `\W`'s complement) that a parse-time ASCII complement can't
    // represent. Deferring all of `/u` keeps the fallback authoritative for
    // the one case that would diverge.
    try expectCompileFlags("[\\S]", .{ .unicode = true }, .unsupported);
    try expectCompileFlags("[\\W]", .{ .unicode = true }, .unsupported);
    try expectCompileFlags("[\\D]", .{ .unicode = true }, .unsupported);
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

test "perlex: out-of-order class ranges still match every member" {
    // The class lists the higher range `x-z` *before* `a-c`. The
    // compiler must sort+merge the ranges (charset.normalize) so the VM
    // can binary-search membership; without that, a search for 'y' — a
    // member of the leading-but-higher range — takes the wrong branch
    // (it compares against `a-c`, then walks right and falls off the
    // end) and falsely misses. Guards the sorted-and-disjoint invariant
    // the binary search relies on, independent of any one emission site.
    try expectMatch("[x-za-c]", "y", "y"); // in the leading, higher range
    try expectMatch("[x-za-c]", "a", "a");
    try expectMatch("[x-za-c]", "z", "z");
    try expectMatch("[x-za-c]", "c", "c");
    try expectNoMatch("[x-za-c]", "d"); // between the two ranges
    try expectNoMatch("[x-za-c]", "w"); // just below 'x'
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

// (Out-of-range `\N` is a §22.2.1.1 Syntax Error in every mode — see
// "out-of-range numeric backreference is a syntax error" above.)

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

test "perlex: non-/u i with non-ASCII units defers without an injected folder" {
    // Inline ASCII folding can't model à↔À, so without a non-Unicode
    // Canonicalize folder these defer to the fallback. The bridge always
    // injects one (see the orbit tests below); bare `compile` does not.
    try expectCompileFlags("\\u00e0", ci, .unsupported);
    try expectCompileFlags("[\\u00c0-\\u00ff]", ci, .unsupported);
    // …but the same patterns compile fine without `i`.
    try expectCompileFlags("\\u00e0", .{}, .match);
}

// ── §22.2.2.7.3 Canonicalize — non-/u i over non-ASCII units ─────────
// With an injected non-Unicode Canonicalize folder (the bridge supplies
// one), Perlex owns non-`/u` `i` patterns that carry a non-ASCII unit.
// The mapping is toUppercase + the ASCII-exclusion, distinct from the
// `/iu` orbit: U+212A KELVIN folds to `k` under `/iu` but to itself here.

const ci_nonu: perlex.Flags = .{ .ignore_case = true };

test "perlex: non-/u i folds a non-ASCII atom across its orbit (à↔À)" {
    try expectFoldMatch("\\u00e0", ci_nonu, &[_]u16{0x00C0}, ""); // à matches À
    try expectFoldMatch("\\u00c0", ci_nonu, &[_]u16{0x00E0}, ""); // À matches à
    try expectFoldMatch("\\u00e0", ci_nonu, &[_]u16{0x00E0}, ""); // à matches à
    // …but not an unrelated non-ASCII unit, nor an ASCII one.
    try expectFoldNoMatch("\\u00e0", ci_nonu, &[_]u16{0x00E1});
    try expectFoldNoMatch("\\u00e0", ci_nonu, &[_]u16{'a'});
}

test "perlex: non-/u i applies the §22.2.2.7.3 ASCII-exclusion (Kelvin)" {
    // toUppercase(U+212A) is ASCII `K`, but the exclusion keeps it itself,
    // so /K/i matches ONLY the Kelvin sign — not `k`/`K`. (This is
    // language/literals/regexp/u-case-mapping.js's non-/u assertions.)
    try expectFoldMatch("\\u212a", ci_nonu, &[_]u16{0x212A}, "");
    try expectFoldNoMatch("\\u212a", ci_nonu, &[_]u16{'k'});
    try expectFoldNoMatch("\\u212a", ci_nonu, &[_]u16{'K'});
}

test "perlex: non-/u i folds a non-ASCII class member three ways (σ/ς/Σ)" {
    // All three uppercase to Σ, so each matches the others in a class.
    try expectFoldMatch("[\\u03c3]", ci_nonu, &[_]u16{0x03C2}, ""); // [σ] matches ς
    try expectFoldMatch("[\\u03c3]", ci_nonu, &[_]u16{0x03A3}, ""); // [σ] matches Σ
    try expectFoldMatch("[\\u03a3]", ci_nonu, &[_]u16{0x03C2}, ""); // [Σ] matches ς
    try expectFoldNoMatch("[\\u03c3]", ci_nonu, &[_]u16{0x03B1}); // not α
}

test "perlex: non-/u i never folds a non-ASCII unit to ASCII (and vice versa)" {
    // The 0x80 boundary is never crossed: an ASCII pattern unit can't
    // match a non-ASCII input unit even when one uppercases toward the
    // other's block. `/[a-z]/i` does not match ſ (U+017F) or KELVIN.
    try expectFoldNoMatch("[a-z]", ci_nonu, &[_]u16{0x017F});
    try expectFoldNoMatch("[a-z]", ci_nonu, &[_]u16{0x212A});
    // An ASCII atom under non-/u i still folds ASCII-only, with a folder
    // present (the orbit covers non-ASCII; ASCII stays the inline path).
    try expectFoldMatch("k", ci_nonu, &[_]u16{'K'}, "K");
}

// ── §22.2.2.9 Canonicalize — /iu and /iv Unicode case folding ────────

const iu: perlex.Flags = .{ .unicode = true, .ignore_case = true };
const iv: perlex.Flags = .{ .unicode_sets = true, .ignore_case = true };

test "perlex: /iu defers without an injected folder" {
    // The bridge always injects one; bare `compile` does not, so a
    // folding pattern still defers to the fallback (unchanged contract).
    try expectCompileFlags("a", iu, .unsupported);
    try expectCompileFlags("k", iv, .unsupported);
}

test "perlex: /iu folds a literal across its whole orbit" {
    // /k/iu matches k, K, and U+212A KELVIN SIGN (one orbit).
    try expectFoldMatch("k", iu, &[_]u16{'k'}, "k");
    try expectFoldMatch("k", iu, &[_]u16{'K'}, "K");
    try expectFoldMatch("k", iu, &[_]u16{0x212A}, ""); // matches; non-ASCII renders empty
    try expectFoldMatch("K", iu, &[_]u16{0x212A}, "");
    // A code point outside the orbit does not match.
    try expectFoldNoMatch("k", iu, &[_]u16{'x'});
}

test "perlex: /iu folds a character class via orbit membership" {
    // [a-c] under fold matches the uppercase partners too.
    try expectFoldMatch("[a-c]", iu, &[_]u16{'B'}, "B");
    try expectFoldMatch("[a-c]", iu, &[_]u16{'c'}, "c");
    try expectFoldNoMatch("[a-c]", iu, &[_]u16{'D'});
    // Negated class is case-insensitive too: 'B' folds into [a-c].
    try expectFoldNoMatch("[^a-c]", iu, &[_]u16{'B'});
}

test "perlex: /iu folds a backreference across the orbit" {
    // Captured "k" matches a later "K"/U+212A under fold. The rendering is
    // whole-match (group 0) then group 1, comma-joined.
    try expectFoldMatch("(k)\\1", iu, &[_]u16{ 'k', 'K' }, "kK,k");
    try expectFoldMatch("(?<x>ab)\\k<x>", iu, &[_]u16{ 'a', 'b', 'A', 'B' }, "abAB,ab");
}

test "perlex: /iu folds a supplementary backreference per code point" {
    // U+10400 ↔ U+10428 are a fold pair, each a surrogate pair in UTF-16.
    // Per-code-unit folding would break; per-code-point folding matches.
    // Both captures are supplementary (>U+7F), so they render empty: the
    // assertion is that the match succeeds (group 0 then group 1 → ",").
    const cap = [_]u16{ 0xD801, 0xDC00 }; // U+10400
    const ref = [_]u16{ 0xD801, 0xDC28 }; // U+10428
    try expectFoldMatch("(.)\\1", iu, &(cap ++ ref), ",");
}

test "perlex: /iv folds \\q{} string members" {
    // [\q{ab}] lowers to the literal "ab"; under /iv each char folds.
    try expectFoldMatch("[\\q{ab}]", iv, &[_]u16{ 'A', 'B' }, "AB");
    try expectFoldMatch("[\\q{ab}]", iv, &[_]u16{ 'a', 'b' }, "ab");
    try expectFoldNoMatch("[\\q{ab}]", iv, &[_]u16{ 'A', 'x' });
}

test "perlex: /iu \\b/\\B fold word-char membership through the orbit (§22.2.2.9.3)" {
    // §22.2.2.9.3 WordCharacters — under /iu the word set extends to every
    // character whose Canonicalize is an ASCII word char. The stub folds
    // U+212A KELVIN SIGN to 'k', so it counts as a word char for \b/\B. With
    // "Z" (a word char) just before it there is no boundary between them: \B
    // matches at that position, \b does not.
    try expectFoldMatch("Z\\B", iu, &[_]u16{ 'Z', 0x212A }, "Z");
    try expectFoldNoMatch("Z\\b", iu, &[_]u16{ 'Z', 0x212A });
    // Against a non-word follower (space) the boundary is present again.
    try expectFoldMatch("Z\\b", iu, &[_]u16{ 'Z', ' ' }, "Z");
    try expectFoldNoMatch("Z\\B", iu, &[_]u16{ 'Z', ' ' });
    // The inline (?i:…) modifier scopes the same word-set fold for \b/\B
    // (ES2024 regexp-modifiers): under bare /u the group still folds.
    try expectFoldMatch("(?i:Z\\B)", uf, &[_]u16{ 'Z', 0x212A }, "Z");
    try expectFoldNoMatch("(?i:Z\\b)", uf, &[_]u16{ 'Z', 0x212A });
}

test "perlex: /iu \\P{property} is a complement set, not an inverted class (§22.2.2.7.1)" {
    // §22.2.2.7.1 — `\P{Lu}` builds the COMPLEMENT CharSet matched with
    // invert = false, whereas `[^…]` builds a base set matched with
    // invert = true. The two coincide without folding but DIVERGE under /iu
    // when the property isn't closed under Canonicalize: stub Lu = [A-Z]
    // contains 'A', whose fold 'a' ∉ Lu. So `\P{Lu}` matches both 'A' (some
    // orbit member lies outside Lu) and 'a'.
    try expectFoldMatch("\\P{Lu}", iu, &[_]u16{'A'}, "A");
    try expectFoldMatch("\\P{Lu}", iu, &[_]u16{'a'}, "a");
    try expectFoldMatch("\\P{Lu}", iu, &[_]u16{'5'}, "5"); // whole orbit outside Lu
    // The invert form `[^A-Z]` (same set, true invert) matches NEITHER 'A'
    // nor 'a' under fold: orbit('A') = {A, a} meets [A-Z] at 'A'.
    try expectFoldNoMatch("[^A-Z]", iu, &[_]u16{'A'});
    try expectFoldNoMatch("[^A-Z]", iu, &[_]u16{'a'});
    // Positive `\p{Lu}` is unaffected: it matches an uppercase letter and,
    // under fold, its lowercase orbit partner too.
    try expectFoldMatch("\\p{Lu}", iu, &[_]u16{'A'}, "A");
    try expectFoldMatch("\\p{Lu}", iu, &[_]u16{'a'}, "a");
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

// ── §22.2.1 inline pattern modifiers `(?ims-ims:…)` (ES2024) ─────────
//
// The two Atom productions `( ? RegularExpressionFlags : Disjunction )`
// and `( ? RegularExpressionFlags - RegularExpressionFlags : Disjunction )`
// add and/or remove the `i`/`m`/`s` flags for a scoped subpattern. Only
// those three flags are modifiable; the change affects local matching
// only and never the RegExp object's own flag properties (a runtime
// concern, covered by the test262 modifiers fixtures).

test "perlex: modifier group adds a flag locally" {
    // (?i:…) folds case only inside the group.
    try expectMatch("(?i:a)", "A", "A");
    try expectMatch("(?i:a)", "a", "a");
    try expectMatch("(?i:abc)", "AbC", "AbC");
    try expectNoMatch("(?i:a)", "b");
    // (?s:.) lets dot span a line terminator locally.
    try expectMatch("(?s:.)", "\n", "\n");
    // (?m:^a) anchors at a line boundary locally.
    try expectMatch("(?m:^a)", "b\na", "a");
}

test "perlex: a modifier's scope ends at its group" {
    // The `b` after the group stays case-sensitive.
    try expectMatch("(?i:a)b", "Ab", "Ab");
    try expectNoMatch("(?i:a)b", "AB");
    try expectNoMatch("(?i:a)b", "aB");
    // The `a` before the group stays case-sensitive too.
    try expectMatch("a(?i:b)", "ab", "ab");
    try expectMatch("a(?i:b)", "aB", "aB");
    try expectNoMatch("a(?i:b)", "Ab");
}

test "perlex: remove-flag modifier turns a program flag off locally" {
    // /(?-i:a)/i — the group opts out of folding.
    try expectMatchFlags("(?-i:a)", ci, "a", "a");
    try expectNoMatchFlags("(?-i:a)", ci, "A");
    // /(?-s:.)/s — dot excludes the newline again inside the group.
    try expectNoMatchFlags("(?-s:.)", .{ .dot_all = true }, "\n");
    try expectMatchFlags("(?-s:.)", .{ .dot_all = true }, "x", "x");
    // /(?-m:^a)/m — `^` is input-relative again inside the group.
    try expectMatchFlags("(?-m:^a)", .{ .multiline = true }, "ab", "a");
    try expectNoMatchFlags("(?-m:^a)", .{ .multiline = true }, "b\na");
}

test "perlex: add-remove modifier combines both in one group" {
    // /(?m-i:^a$)/i — add m, remove i: multiline + case-sensitive.
    try expectMatchFlags("(?m-i:^a$)", ci, "a\n", "a");
    try expectNoMatchFlags("(?m-i:^a$)", ci, "A\n");
}

test "perlex: modifiers nest and the inner scope wins" {
    // Outer folds; inner removes folding for `b` only.
    try expectMatch("(?i:a(?-i:b)c)", "AbC", "AbC");
    try expectNoMatch("(?i:a(?-i:b)c)", "ABC");
    // Inner adds folding back for `b` only, under a remove-i outer scope.
    try expectMatchFlags("(?-i:a(?i:b)c)", ci, "aBc", "aBc");
    try expectNoMatchFlags("(?-i:a(?i:b)c)", ci, "AbC");
}

test "perlex: modifier group carries captures and quantifies" {
    try expectMatch("(?i:(a)(b))", "AB", "AB,A,B");
    try expectMatch("(?i:ab)+", "ABab", "ABab");
}

test "perlex: modifier early errors are syntax errors (§22.2.1.1)" {
    try expectCompile("(?ii:a)", .syntax_error); // duplicate flag in add
    try expectCompile("(?ss:a)", .syntax_error);
    try expectCompile("(?i-mm:a)", .syntax_error); // duplicate in remove
    try expectCompile("(?i-i:a)", .syntax_error); // add ∩ remove ≠ ∅
    try expectCompile("(?ms-s:a)", .syntax_error); // overlap on s
    try expectCompile("(?-:a)", .syntax_error); // add and remove both empty
    try expectCompile("(?x:a)", .syntax_error); // non-ims flag
    try expectCompile("(?I:a)", .syntax_error); // flag letters are case-sensitive
    try expectCompile("(?im-x:a)", .syntax_error); // non-ims in remove
}

test "perlex: well-formed modifier flag spellings compile" {
    try expectCompile("(?ims:a)", .match);
    try expectCompile("(?smi:a)", .match); // order-independent
    try expectCompile("(?i-m:a)", .match);
    try expectCompile("(?-i:a)", .match); // empty add, non-empty remove
    try expectCompile("(?ims-:a)", .match); // non-empty add, empty remove
}

test "perlex: a modifier run not closed by `-`/`:` is a syntax error" {
    // §22.2.1: after `(?` the only productions are `(?:`, `(?=`, `(?!`,
    // `(?<…`, and the modifier group `(? ims (- ims)? : …)`. A modifier
    // run that reaches a byte other than `-` or `:` matches no production,
    // so the pattern is a SyntaxError in every mode (the form is not
    // `/u`-gated). ASCII representatives:
    try expectCompile("(?i)", .syntax_error); // no `:`-scoped body
    try expectCompile("(?i :a)", .syntax_error); // space breaks the run
    try expectCompile("(?s -:a)", .syntax_error);
    try expectCompile("(?foo)", .syntax_error); // not a modifier at all
    try expectCompile("(?P<n>x)", .syntax_error); // Python-style named group
    try expectCompile("(?)", .syntax_error); // empty
    // The exact non-ASCII bytes test262 exercises in the flag position: a
    // combining mark, ZWNJ, and a fold-only letter, bare and under /u.
    try expectCompile("(?i\xcd\xa5:a)", .syntax_error); // U+0365 after add
    try expectCompile("(?m\xcd\xab-:a)", .syntax_error); // U+036B before `-`
    try expectCompile("(?-s\xcc\x80:a)", .syntax_error); // U+0300 in remove
    try expectCompile("(?-s\xe2\x80\x8c:a)", .syntax_error); // U+200C ZWNJ
    try expectCompile("(?\xc4\xb0:a)", .syntax_error); // U+0130 İ
    // Mode-independent: a `/u` pattern reaches the parser and is rejected
    // just the same. (The matching `/iu` census case defers at the
    // match-capability gate under a folderless bare compile, but the
    // production bridge injects a folder, so it reaches this same verdict —
    // exercised by the built-ins/RegExp differential sweep.)
    try expectCompileFlags("(?\xc5\xbf:a)", uf, .syntax_error); // U+017F ſ /u
}

test "perlex: /u modifier folds across the orbit with an injected folder" {
    // The group adds `i`; under /u that needs the case folder the bridge
    // injects (bare compile defers — see the gate test below).
    try expectFoldMatch("(?i:a)", uf, &[_]u16{'A'}, "A");
    try expectFoldMatch("(?i:a)", uf, &[_]u16{'a'}, "a");
    try expectFoldNoMatch("(?i:a)", uf, &[_]u16{'x'});
}

test "perlex: /u modifier adding i defers without a folder" {
    // Same deferral contract as a program-level /iu pattern: no injected
    // folder → defer the whole pattern to the fallback.
    try expectCompileFlags("(?i:a)", uf, .unsupported);
    // A modifier that doesn't add folding still compiles under bare /u.
    try expectCompileFlags("(?m:^a)", uf, .match);
    try expectCompileFlags("(?-i:a)", uf, .match);
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

test "perlex/v: reserved double punctuators and unescaped syntax chars are a SyntaxError (§22.2.1.1)" {
    // §22.2.1 ClassSetReservedDoublePunctuator — a doubled punctuator is an
    // early error Perlex owns directly (only Annex B regex leniency, dropped
    // here, would read it as two literals).
    try expectCompileFlags("[a~~b]", vflags, .syntax_error);
    try expectCompileFlags("[a!!b]", vflags, .syntax_error);
    try expectCompileFlags("[a::b]", vflags, .syntax_error);
    try expectCompileFlags("[a==b]", vflags, .syntax_error);
    try expectCompileFlags("[a..b]", vflags, .syntax_error);
    // An unescaped ClassSetSyntaxCharacter (`( ) { } / | -`) is likewise an
    // early error: in /v it must be escaped (`\-`, `\(`, …).
    try expectCompileFlags("[-]", vflags, .syntax_error);
    try expectCompileFlags("[(]", vflags, .syntax_error);
    try expectCompileFlags("[)]", vflags, .syntax_error);
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

// ── §22.2.1 ClassStringDisjunction `\q{…}` (the may-contain-strings half
// of `/v`) — multi-code-point class members, set algebra over them, and
// the §22.2.1.1 negated-set-with-strings early error. ────────────────

test "perlex/v: \\q{} matches a multi-character string" {
    // A lone string disjunction is a class whose only member is "abc".
    try expectMatchFlags("[\\q{abc}]", vflags, "abc", "abc");
    // A prefix can't satisfy the whole string element.
    try expectNoMatchFlags("[\\q{abc}]", vflags, "ab");
    // Leftmost match consumes exactly the element.
    try expectMatchFlags("[\\q{abc}]", vflags, "abcd", "abc");
}

test "perlex/v: \\q{} tries longer alternatives first (§22.2.2.7)" {
    // §22.2.2.7 sorts string members by descending length, independent of
    // source order: "abc" is attempted before "ab" either way.
    try expectMatchFlags("[\\q{abc|ab}]", vflags, "abc", "abc");
    try expectMatchFlags("[\\q{ab|abc}]", vflags, "abc", "abc");
    // When the longer one can't match, the shorter still does.
    try expectMatchFlags("[\\q{abc|ab}]", vflags, "abx", "ab");
}

test "perlex/v: single-character \\q strings fold into the char set" {
    // A length-1 ClassString is just a character — `[\q{a}]` ≡ `[a]`.
    try expectMatchFlags("[\\q{a}]", vflags, "a", "a");
    try expectNoMatchFlags("[\\q{a}]", vflags, "b");
    // …so negating it is allowed (MayContainStrings is false).
    try expectMatchFlags("[^\\q{a}]", vflags, "b", "b");
    try expectNoMatchFlags("[^\\q{a}]", vflags, "a");
}

test "perlex/v: \\q{} in a union with characters and nested classes" {
    try expectMatchFlags("[[0-9]\\q{ab}]", vflags, "5", "5");
    try expectMatchFlags("[[0-9]\\q{ab}]", vflags, "ab", "ab");
    try expectNoMatchFlags("[[0-9]\\q{ab}]", vflags, "x");
    // The single chars in the union still match on their own.
    try expectMatchFlags("[x\\q{ab}]", vflags, "x", "x");
}

test "perlex/v: quantified may-contain-strings class" {
    // `+` over a class whose members include a 2-char string.
    try expectMatchFlags("^[[0-9]\\q{ab}]+$", vflags, "5ab9", "5ab9");
    try expectMatchFlags("^[[0-9]\\q{ab}]+$", vflags, "abab", "abab");
    try expectNoMatchFlags("^[[0-9]\\q{ab}]+$", vflags, "a");
}

test "perlex/v: §22.2.2.3 owns quantified empty-matching \\q{} sets" {
    // A `/v` set whose membership includes the empty string (a `\q{}` empty
    // alternative, or `\q{|a}` with an empty branch) is nullable — a
    // quantifier over it would spin a zero-width loop without the §22.2.2.3
    // progress guard. `compileRepeat` already emits that guard, so Perlex
    // owns these instead of deferring to the fallback (which can't compile
    // `\q{}` at all). The guard protects only the *optional* iterations.
    try expectMatchFlags("[\\q{}a]*", vflags, "aab", "aa");
    try expectMatchFlags("[\\q{}a]+", vflags, "aab", "aa");
    // A set whose ONLY member is the empty string: the star matches "" and
    // the guard stops it after one zero-width pass.
    try expectMatchFlags("[\\q{}]*", vflags, "abc", "");
    // `\q{|a}` ≡ {"", "a"}: an empty leading branch is a valid ClassString.
    try expectMatchFlags("[\\q{|a}]+", vflags, "aaa", "aaa");
    // The quantified set sits between consuming atoms.
    try expectMatchFlags("x[\\q{}a]*y", vflags, "xaay", "xaay");
    // Greedy `{2,3}` fills the optional third iteration (engine262, V8, SM,
    // Hermes, QuickJS agree on "aaa"; JSC is the lone "a" outlier).
    try expectMatchFlags("[\\q{}a]{2,3}", vflags, "aaaa", "aaa");
    // Lazy `*?` over a nullable set takes zero iterations.
    try expectMatchFlags("[\\q{}a]*?", vflags, "aa", "");
    // A captured nullable set: the last *participating* iteration before the
    // guard's zero-width skip wins the capture (the guarded empty pass rolls
    // its `''` capture back). Full match "aa", group 1 "a".
    try expectCapsFlags("([\\q{}a])*", vflags, "aa", "'aa' 'a'");
}

test "perlex/v: §22.2.2.3 mandatory \\q{} empty iterations participate (min > 0)" {
    // §22.2.2.3 step 2.b gates its zero-width-failure on `min = 0`, so the
    // mandatory `min` iterations run unconditionally and PARTICIPATE even
    // when they match empty (Note 4: the empty-match guard applies only once
    // the minimum is satisfied). engine262 returns `null` on all three of
    // these — it is the lone outlier; V8, JSC, SpiderMonkey, Hermes and
    // QuickJS all return the match below, and that is the spec reading.
    //
    // `+` (min 1) on "b": "a" can't match, but the one mandatory iteration
    // matches "" via the empty member — overall match "".
    try expectMatchFlags("[\\q{}a]+", vflags, "b", "");
    // `{2,3}` (min 2) on "a": iter 1 takes "a", iter 2 (mandatory) matches
    // "" at end-of-input — overall match "a".
    try expectMatchFlags("[\\q{}a]{2,3}", vflags, "a", "a");
    // `{2,3}` (min 2) on "": both mandatory iterations match "" — match "".
    try expectMatchFlags("[\\q{}a]{2,3}", vflags, "", "");
}

test "perlex/v: intersection keeps only shared members" {
    // Strings intersect by sequence equality.
    try expectMatchFlags("[\\q{ab|cd}&&\\q{ab|xy}]", vflags, "ab", "ab");
    try expectNoMatchFlags("[\\q{ab|cd}&&\\q{ab|xy}]", vflags, "cd");
    // A range-only operand drops every multi-char string (no overlap).
    try expectMatchFlags("[[0-9]&&\\q{1|ab}]", vflags, "1", "1");
    try expectNoMatchFlags("[[0-9]&&\\q{1|ab}]", vflags, "ab");
    try expectNoMatchFlags("[[0-9]&&\\q{1|ab}]", vflags, "5");
}

test "perlex/v: difference removes matching string members" {
    try expectMatchFlags("[\\q{ab|cd|ef}--\\q{cd}]", vflags, "ab", "ab");
    try expectMatchFlags("[\\q{ab|cd|ef}--\\q{cd}]", vflags, "ef", "ef");
    try expectNoMatchFlags("[\\q{ab|cd|ef}--\\q{cd}]", vflags, "cd");
}

test "perlex/v: negating a set that may contain strings is a SyntaxError" {
    // §22.2.1.1 — `[^…]` is a Syntax Error when MayContainStrings is true.
    try expectCompileFlags("[^\\q{ab}]", vflags, .syntax_error);
    try expectCompileFlags("[^[0-9]\\q{ab}]", vflags, .syntax_error);
    try expectCompileFlags("[[^\\q{ab}]]", vflags, .syntax_error);
    // §22.2.1.8 is structural, not resolved: an intersection MayContainStrings
    // iff BOTH operands do — so this is an error even though the resolved
    // intersection is empty of strings.
    try expectCompileFlags("[^\\q{ab}&&\\q{cd}]", vflags, .syntax_error);
    // …and a subtraction iff its LEFT operand does.
    try expectCompileFlags("[^\\q{ab}--\\q{ab}]", vflags, .syntax_error);
}

test "perlex/v: negation allowed when MayContainStrings is structurally false" {
    // Intersection with a range-only left operand: MayContainStrings false,
    // so the negation is legal (the resolved set is empty → complement is all).
    try expectCompileFlags("[^[0-9]&&\\q{ab}]", vflags, .match);
    // A single-char-only \q never makes a set may-contain-strings.
    try expectCompileFlags("[^\\q{a|b|c}]", vflags, .match);
}

test "perlex/v: \\q{} with a supplementary / multi-unit string" {
    // The keycap sequence "9️⃣" is a single 3-code-point member.
    const keycap = [_]u16{ 0x39, 0xFE0F, 0x20E3 };
    try testing.expect(.match == try runV16Tag(testing.allocator, "[\\q{9\\uFE0F\\u20E3}]", &keycap));
    // "9" alone is not the member (no single-char fold for a 3-char string).
    const just_nine = [_]u16{0x39};
    try testing.expect(.no_match == try runV16Tag(testing.allocator, "[\\q{9\\uFE0F\\u20E3}]", &just_nine));
    // The test262 calibration pattern, end to end.
    try testing.expect(.match == try runV16Tag(
        testing.allocator,
        "^[[0-9]\\q{0|2|4|9\\uFE0F\\u20E3}]+$",
        &keycap,
    ));
    const six_keycap = [_]u16{ 0x36, 0xFE0F, 0x20E3 }; // "6️⃣" — not a member
    try testing.expect(.no_match == try runV16Tag(
        testing.allocator,
        "^[[0-9]\\q{0|2|4|9\\uFE0F\\u20E3}]+$",
        &six_keycap,
    ));
}

// ── §22.2.1.1 properties of strings (`\p{RGI_Emoji}` …) as an atom. The
// stub resolver backs "Basic_Emoji" with chars [a-c] and the string
// members "xy" and "123". Valid only as a positive lone `\p{…}` under
// `/v`; `\P{…}`, a non-`/v` flag, and a negated enclosing set are all
// §22.2.1.1 early errors. ─────────────────────────────────────────────

test "perlex/v: \\p{stringprop} atom matches its string and char members" {
    // Multi-character members lower to an alternation (longest first).
    try expectMatchPropFlags("\\p{Basic_Emoji}", vflags, "xy", "xy");
    try expectMatchPropFlags("\\p{Basic_Emoji}", vflags, "123", "123");
    // Single-character members come from the folded ranges.
    try expectMatchPropFlags("\\p{Basic_Emoji}", vflags, "b", "b");
    try expectNoMatchPropFlags("\\p{Basic_Emoji}", vflags, "z");
    // A prefix of a string member is not the whole member on its own.
    try expectNoMatchPropFlags("\\p{Basic_Emoji}", vflags, "x");
}

test "perlex/v: quantified \\p{stringprop} backtracks through the concatenation" {
    // Mirrors the test262 harness: `^\p{X}+$` must consume the whole input.
    try expectMatchPropFlags("^\\p{Basic_Emoji}+$", vflags, "xy123a", "xy123a");
    try expectMatchPropFlags("^\\p{Basic_Emoji}+$", vflags, "abcxy", "abcxy");
    try expectNoMatchPropFlags("^\\p{Basic_Emoji}+$", vflags, "xyz"); // 'z' not a member
}

test "perlex/v: \\p{stringprop} inside a positive set unions its members" {
    try expectMatchPropFlags("[\\p{Basic_Emoji}[0-9]]", vflags, "xy", "xy");
    try expectMatchPropFlags("[\\p{Basic_Emoji}[0-9]]", vflags, "5", "5");
    try expectMatchPropFlags("[\\p{Basic_Emoji}[0-9]]", vflags, "a", "a");
    try expectNoMatchPropFlags("[\\p{Basic_Emoji}[0-9]]", vflags, "w");
}

test "perlex: \\P{stringprop} is a SyntaxError (no complement of strings)" {
    // §22.2.1.1 — a property of strings can't be negated, in either mode.
    try expectCompileProp("\\P{Basic_Emoji}", vflags, .syntax_error);
    try expectCompileProp("\\P{Basic_Emoji}", uflags, .syntax_error);
    // …and inside a `/v` class operand.
    try expectCompileProp("[\\P{Basic_Emoji}]", vflags, .syntax_error);
}

test "perlex: \\p{stringprop} without /v is a SyntaxError" {
    // Valid only under `/v`; under `/u` (or a class operand reached in /u)
    // it is an early error.
    try expectCompileProp("\\p{Basic_Emoji}", uflags, .syntax_error);
}

test "perlex/v: negated set containing \\p{stringprop} is a SyntaxError" {
    // §22.2.1.1 — `[^…]` is a Syntax Error when MayContainStrings is true,
    // and a positive property of strings makes the set may-contain-strings.
    try expectCompileProp("[^\\p{Basic_Emoji}]", vflags, .syntax_error);
    try expectCompileProp("[^\\p{Basic_Emoji}[0-9]]", vflags, .syntax_error);
}
