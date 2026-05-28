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
const perlex_parser = @import("../perlex/parser.zig");

const ClassRange = perlex_parser.Node.ClassRange;

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
) std.mem.Allocator.Error!?[]const ClassRange {
    const ranges: []const properties.Range = if (key) |k| blk: {
        if (std.mem.eql(u8, k, "gc") or std.mem.eql(u8, k, "General_Category"))
            break :blk (properties.generalCategory(value) orelse return null);
        if (std.mem.eql(u8, k, "sc") or std.mem.eql(u8, k, "Script"))
            break :blk (properties.script(value) orelse return null);
        if (std.mem.eql(u8, k, "scx") or std.mem.eql(u8, k, "Script_Extensions"))
            break :blk (properties.scriptExtensions(value) orelse return null);
        return null;
    } else
        // Lone form: a binary property, else a gc value.
        properties.binaryProperty(value) orelse
            properties.generalCategory(value) orelse return null;

    const out = try gpa.alloc(ClassRange, ranges.len);
    for (ranges, out) |r, *o| o.* = .{ .lo = r.start, .hi = r.end };
    return out;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "Script=Unknown / Zzzz resolve to non-empty ranges" {
    // The exact divergence this module closes: the vendored libregexp
    // rejects `Script=Unknown`, but Cynic's tables model it as the
    // @missing complement (§22.2.1.1). Both key spellings and the short
    // code resolve.
    for ([_][]const u8{ "Unknown", "Zzzz" }) |val| {
        const ranges = (try resolve(testing.allocator, "Script", val)) orelse
            return error.ShouldResolve;
        defer testing.allocator.free(ranges);
        try testing.expect(ranges.len > 0);
    }
    const sc = (try resolve(testing.allocator, "sc", "Unknown")) orelse
        return error.ShouldResolve;
    defer testing.allocator.free(sc);
    try testing.expect(sc.len > 0);

    // Script_Extensions=Unknown is the sibling fixture and must also
    // resolve through the keyed-scx branch.
    const scx = (try resolve(testing.allocator, "Script_Extensions", "Unknown")) orelse
        return error.ShouldResolve;
    defer testing.allocator.free(scx);
    try testing.expect(scx.len > 0);
}

test "lone gc value and binary property resolve" {
    const lu = (try resolve(testing.allocator, null, "Lu")) orelse
        return error.ShouldResolve;
    defer testing.allocator.free(lu);
    try testing.expect(lu.len > 0);

    const ws = (try resolve(testing.allocator, null, "White_Space")) orelse
        return error.ShouldResolve;
    defer testing.allocator.free(ws);
    try testing.expect(ws.len > 0);
}

test "unknown names and keys defer (null)" {
    try testing.expectEqual(
        @as(?[]const ClassRange, null),
        try resolve(testing.allocator, null, "NotAProperty"),
    );
    try testing.expectEqual(
        @as(?[]const ClassRange, null),
        try resolve(testing.allocator, "Script", "NotAScript"),
    );
    try testing.expectEqual(
        @as(?[]const ClassRange, null),
        try resolve(testing.allocator, "boguskey", "Latin"),
    );
}

test "produced ranges mirror the source table verbatim" {
    const src = properties.script("Greek").?;
    const got = (try resolve(testing.allocator, "Script", "Greek")).?;
    defer testing.allocator.free(got);
    try testing.expectEqual(src.len, got.len);
    for (src, got) |s, g| {
        try testing.expectEqual(s.start, g.lo);
        try testing.expectEqual(s.end, g.hi);
    }
}
