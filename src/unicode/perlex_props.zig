//! Shared `\p{…}` / `\P{…}` property resolver bridging Cynic's generated
//! Unicode tables (`unicode/properties.zig`) to Perlex's compiler
//! (ECMA-262 §22.2.1.1 UnicodePropertyValueExpression).
//!
//! Perlex carries no Unicode data: its compiler asks an injected
//! `PropertyResolver` for the code-point ranges of a property and bakes
//! them into a character-class instruction. The two regex-compilation
//! paths — the parse-time early-error validator
//! (`parser/regex_validate.zig`) and the runtime bridge
//! (`runtime/builtins/regexp.zig`) — share this one resolver so they can
//! never disagree about which property escapes are valid. A *null*
//! resolver, by contrast, defers every `\p{…}` to the libregexp
//! fallback, which rejects values Cynic's own tables recognise (e.g.
//! `Script=Unknown`, the @missing complement) — the divergence this
//! shared seam closes.

const std = @import("std");

const properties = @import("properties.zig");
const perlex = @import("../perlex/perlex.zig");
const perlex_parser = perlex.parser;

const ClassRange = perlex_parser.Node.ClassRange;
const ResolvedProperty = perlex.ResolvedProperty;

/// Resolve a property escape to its sorted code-point ranges, allocated
/// from `gpa` (the caller owns the returned slice). A lone
/// `\p{NameOrValue}` is a binary property or a General_Category value
/// (disjoint name spaces); `\p{gc=…}`, `\p{Script=…}` / `\p{sc=…}`, and
/// `\p{Script_Extensions=…}` / `\p{scx=…}` select the keyed property.
/// Returns null for names Cynic's tables don't recognise and for the
/// `/v`-only string properties, so the pattern defers to the libregexp
/// fallback (authoritative for the SyntaxError verdict). The signature
/// matches `perlex.PropertyResolver`.
pub fn resolve(
    gpa: std.mem.Allocator,
    key: ?[]const u8,
    value: []const u8,
) std.mem.Allocator.Error!?ResolvedProperty {
    if (key) |k| {
        const ranges: []const properties.Range =
            if (std.mem.eql(u8, k, "gc") or std.mem.eql(u8, k, "General_Category"))
                (properties.generalCategory(value) orelse return null)
            else if (std.mem.eql(u8, k, "sc") or std.mem.eql(u8, k, "Script"))
                (properties.script(value) orelse return null)
            else if (std.mem.eql(u8, k, "scx") or std.mem.eql(u8, k, "Script_Extensions"))
                (properties.scriptExtensions(value) orelse return null)
            else
                return null;
        return try rangesOnly(gpa, ranges);
    }
    // Lone form: a binary property or a General_Category value (both
    // char-only), then a `/v`-only property of strings (e.g. `RGI_Emoji`,
    // which carries string members). The three name spaces are disjoint
    // (§22.2.1.1), so the order only decides which lookup finds it.
    if (properties.binaryProperty(value)) |ranges| return try rangesOnly(gpa, ranges);
    if (properties.generalCategory(value)) |ranges| return try rangesOnly(gpa, ranges);
    return try resolveStringProperty(gpa, value); // null when not a string prop
}

/// Wrap source-table `ranges` as a char-only `ResolvedProperty` (no string
/// members), copying into a fresh slice the caller owns.
fn rangesOnly(
    gpa: std.mem.Allocator,
    ranges: []const properties.Range,
) std.mem.Allocator.Error!ResolvedProperty {
    const out = try gpa.alloc(ClassRange, ranges.len);
    for (ranges, out) |r, *o| o.* = .{ .lo = r.start, .hi = r.end };
    return .{ .ranges = out, .strings = &.{} };
}

/// Resolve one of the §22.2.1.1 properties of strings (the emoji-sequence
/// set: `Basic_Emoji`, `RGI_Emoji`, …) to its single-code-point ranges
/// plus multi-code-point sequence members, both allocated from `gpa`.
/// Returns null for every other name. These are valid only under the `/v`
/// flag and only in positive form; the parser enforces those early errors,
/// so this resolver is purely the data lookup.
fn resolveStringProperty(
    gpa: std.mem.Allocator,
    value: []const u8,
) std.mem.Allocator.Error!?ResolvedProperty {
    const sp = properties.stringProperty(value) orelse return null;

    const ranges = try gpa.alloc(ClassRange, sp.ranges.len);
    errdefer gpa.free(ranges);
    for (sp.ranges, ranges) |r, *o| o.* = .{ .lo = r.start, .hi = r.end };

    const strings = try gpa.alloc([]const u21, sp.sequences.len);
    errdefer gpa.free(strings);
    for (sp.sequences, strings) |seq, *o| o.* = seq; // table data is static

    return .{ .ranges = ranges, .strings = strings };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

/// Free a resolved property's caller-owned slices (the inner sequence
/// slices point at static table data and are never freed).
fn freeResolved(rp: ResolvedProperty) void {
    testing.allocator.free(rp.ranges);
    if (rp.strings.len != 0) testing.allocator.free(rp.strings);
}

test "Script=Unknown / Zzzz resolve to non-empty ranges" {
    // The exact divergence this module closes: the vendored libregexp
    // rejects `Script=Unknown`, but Cynic's tables model it as the
    // @missing complement (§22.2.1.1). Both key spellings and the short
    // code resolve.
    for ([_][]const u8{ "Unknown", "Zzzz" }) |val| {
        const rp = (try resolve(testing.allocator, "Script", val)) orelse
            return error.ShouldResolve;
        defer freeResolved(rp);
        try testing.expect(rp.ranges.len > 0);
        try testing.expectEqual(@as(usize, 0), rp.strings.len);
    }
    const sc = (try resolve(testing.allocator, "sc", "Unknown")) orelse
        return error.ShouldResolve;
    defer freeResolved(sc);
    try testing.expect(sc.ranges.len > 0);

    // Script_Extensions=Unknown is the sibling fixture and must also
    // resolve through the keyed-scx branch.
    const scx = (try resolve(testing.allocator, "Script_Extensions", "Unknown")) orelse
        return error.ShouldResolve;
    defer freeResolved(scx);
    try testing.expect(scx.ranges.len > 0);
}

test "lone gc value and binary property resolve (char-only, no strings)" {
    const lu = (try resolve(testing.allocator, null, "Lu")) orelse
        return error.ShouldResolve;
    defer freeResolved(lu);
    try testing.expect(lu.ranges.len > 0);
    try testing.expectEqual(@as(usize, 0), lu.strings.len);

    const ws = (try resolve(testing.allocator, null, "White_Space")) orelse
        return error.ShouldResolve;
    defer freeResolved(ws);
    try testing.expect(ws.ranges.len > 0);
    try testing.expectEqual(@as(usize, 0), ws.strings.len);
}

test "lone property of strings resolves with ranges and sequences" {
    // Basic_Emoji carries both single-code-point members (ranges) and
    // multi-code-point sequences (§22.2.1.1).
    const be = (try resolve(testing.allocator, null, "Basic_Emoji")) orelse
        return error.ShouldResolve;
    defer freeResolved(be);
    try testing.expect(be.ranges.len > 0);
    try testing.expect(be.strings.len > 0);
    // A keyed form of the same name is not a property of strings → null.
    try testing.expectEqual(
        @as(?ResolvedProperty, null),
        try resolve(testing.allocator, "gc", "Basic_Emoji"),
    );

    // RGI_Emoji (the union) resolves too, with sequence members.
    const rgi = (try resolve(testing.allocator, null, "RGI_Emoji")) orelse
        return error.ShouldResolve;
    defer freeResolved(rgi);
    try testing.expect(rgi.strings.len > 0);
}

test "unknown names and keys defer (null)" {
    try testing.expectEqual(
        @as(?ResolvedProperty, null),
        try resolve(testing.allocator, null, "NotAProperty"),
    );
    try testing.expectEqual(
        @as(?ResolvedProperty, null),
        try resolve(testing.allocator, "Script", "NotAScript"),
    );
    try testing.expectEqual(
        @as(?ResolvedProperty, null),
        try resolve(testing.allocator, "boguskey", "Latin"),
    );
}

test "produced ranges mirror the source table verbatim" {
    const src = properties.script("Greek").?;
    const got = (try resolve(testing.allocator, "Script", "Greek")).?;
    defer freeResolved(got);
    try testing.expectEqual(src.len, got.ranges.len);
    for (src, got.ranges) |s, g| {
        try testing.expectEqual(s.start, g.lo);
        try testing.expectEqual(s.end, g.hi);
    }
}
