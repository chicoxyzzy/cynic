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

const c = @import("c");
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
/// Cynic's tables cover the full ES2025 set of binary properties,
/// General_Category values, Script / Script_Extensions values, and
/// properties of strings, so a name/value none of them recognise is an
/// invalid UnicodePropertyValueExpression: `resolve` raises
/// `error.SyntaxError` (§22.2.1.1) rather than deferring. It never returns
/// null — the optional return matches `perlex.PropertyResolver` (a test
/// stub with partial data does return null, which defers). The /v-only
/// restriction on properties of strings is enforced by the parser, not
/// here.
pub fn resolve(
    gpa: std.mem.Allocator,
    key: ?[]const u8,
    value: []const u8,
) (std.mem.Allocator.Error || error{SyntaxError})!?ResolvedProperty {
    if (key) |k| {
        const ranges: []const properties.Range =
            if (std.mem.eql(u8, k, "gc") or std.mem.eql(u8, k, "General_Category"))
                (properties.generalCategory(value) orelse return error.SyntaxError)
            else if (std.mem.eql(u8, k, "sc") or std.mem.eql(u8, k, "Script"))
                (properties.script(value) orelse return error.SyntaxError)
            else if (std.mem.eql(u8, k, "scx") or std.mem.eql(u8, k, "Script_Extensions"))
                (properties.scriptExtensions(value) orelse return error.SyntaxError)
            else
                return error.SyntaxError; // unrecognised property key
        return try rangesOnly(gpa, ranges);
    }
    // Lone form: a binary property or a General_Category value (both
    // char-only), then a `/v`-only property of strings (e.g. `RGI_Emoji`,
    // which carries string members). The three name spaces are disjoint
    // (§22.2.1.1), so the order only decides which lookup finds it.
    if (properties.binaryProperty(value)) |ranges| return try rangesOnly(gpa, ranges);
    if (properties.generalCategory(value)) |ranges| return try rangesOnly(gpa, ranges);
    if (try resolveStringProperty(gpa, value)) |sp| return sp;
    // §22.2.1.1 — the name matches no binary property, General_Category
    // value, or property of strings Cynic's tables (the full ES set)
    // recognise, so it is an invalid UnicodePropertyValueExpression.
    return error.SyntaxError;
}

/// The other members of `cp`'s §22.2.2.9 simple case-folding orbit (empty
/// when `cp` folds only to itself), forwarded from Cynic's generated tables.
/// Injected into Perlex's compiler as `perlex.CaseFoldFn` so the matcher can
/// fold `/iu`/`/iv` literals, classes, and backreferences at match time
/// without carrying any Unicode data of its own. The returned slice is
/// static table data — never freed, never mutated.
pub fn caseFold(cp: u21) []const u21 {
    return properties.caseFoldPartners(cp);
}

// ── §22.2.2.7.3 non-Unicode Canonicalize orbits ─────────────────────
//
// Under a non-`/u`/`/v` `i` pattern, two UTF-16 code units match when
// their Canonicalize images coincide. Canonicalize here is toUppercase
// with a length-≠-1 guard and the ASCII-exclusion: a unit ≥ 128 whose
// uppercase is a single ASCII unit stays *itself* (so U+212A KELVIN and
// U+017F ſ are not matched by `/[a-z]/i`), and a multi-unit uppercase
// (ß → "SS") leaves the unit unchanged. Distinct from `caseFold`'s `/iu`
// orbit (where KELVIN folds to `k`). Perlex carries no case data, so the
// matcher folds non-ASCII units through this injected resolver. The orbit
// of a unit is every *other* unit sharing its Canonicalize; it is built
// once from libunicode's toUppercase — the same primitive backing
// `String.prototype.toUpperCase`, so the two never diverge — by scanning
// the BMP and bucketing by Canonicalize value. Singleton orbits (the vast
// majority) are omitted; a miss returns the empty slice.

/// §22.2.2.7.3 step 3, for a single UTF-16 code unit.
fn nonUnicodeCanonicalize(cu: u16) u16 {
    var res: [3]u32 = undefined;
    const n = c.lre_case_conv(&res, @as(u32, cu), 0); // 0 = to-upper
    if (n != 1) return cu; // uStr length ≠ 1 (multi-code-point uppercase)
    const u = res[0];
    if (u > 0xFFFF) return cu; // a supplementary uppercase is two code units
    const up: u16 = @intCast(u);
    if (cu >= 128 and up < 128) return cu; // the ASCII-exclusion
    return up;
}

var orbit_arena: std.heap.ArenaAllocator = undefined;
var orbit_map: std.AutoHashMapUnmanaged(u21, []const u21) = .empty;
// The map is built once on first use and only read thereafter, so the hot
// path is a lock-free acquire-load. The one-time build is serialised across
// the test262 worker pool without a mutex: one thread CAS-claims the build,
// any racers spin until it publishes `done`.
const OrbitState = enum(u8) { uninit, building, done };
var orbit_state = std.atomic.Value(u8).init(@intFromEnum(OrbitState.uninit));

fn buildOrbitMap() void {
    orbit_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const a = orbit_arena.allocator();

    // Temporary buckets: Canonicalize value → the units that map to it.
    // Freed once the per-unit orbit slices have been materialised.
    var tmp = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer tmp.deinit();
    const ta = tmp.allocator();
    var buckets: std.AutoHashMapUnmanaged(u16, std.ArrayListUnmanaged(u21)) = .empty;

    var cu: u32 = 0;
    while (cu <= 0xFFFF) : (cu += 1) {
        const unit: u16 = @intCast(cu);
        const k = nonUnicodeCanonicalize(unit);
        const gop = buckets.getOrPut(ta, k) catch @panic("perlex: non-/u canon orbit OOM");
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        gop.value_ptr.append(ta, @as(u21, unit)) catch @panic("perlex: non-/u canon orbit OOM");
    }

    var it = buckets.valueIterator();
    while (it.next()) |members_ptr| {
        const members = members_ptr.items;
        if (members.len < 2) continue; // singleton: folds only to itself
        for (members) |m| {
            const orbit = a.alloc(u21, members.len - 1) catch @panic("perlex: non-/u canon orbit OOM");
            var j: usize = 0;
            for (members) |other| {
                if (other != m) {
                    orbit[j] = other;
                    j += 1;
                }
            }
            orbit_map.put(a, m, orbit) catch @panic("perlex: non-/u canon orbit OOM");
        }
    }
}

/// The non-Unicode Canonicalize orbit of `cp` — every other UTF-16 code
/// unit that canonicalizes to the same value (§22.2.2.7.3), empty when
/// `cp` folds only to itself. Non-`/u` matching is per code unit, so `cp`
/// is always ≤ 0xFFFF here. Signature matches `perlex.CaseFoldFn`; the map
/// is built lazily (thread-safe via `std.once`) and never freed.
pub fn nonUnicodeCanonFold(cp: u21) []const u21 {
    if (cp > 0xFFFF) return &.{};
    if (orbit_state.load(.acquire) != @intFromEnum(OrbitState.done)) ensureOrbit();
    return orbit_map.get(cp) orelse &.{};
}

/// Build the orbit map exactly once across threads. The winner of the CAS
/// from `uninit`→`building` runs `buildOrbitMap` then publishes `done`;
/// racers spin until the map is visible (`release`/`acquire` pair the
/// build's writes to the reading thread).
fn ensureOrbit() void {
    if (orbit_state.cmpxchgStrong(
        @intFromEnum(OrbitState.uninit),
        @intFromEnum(OrbitState.building),
        .acq_rel,
        .acquire,
    ) == null) {
        buildOrbitMap();
        orbit_state.store(@intFromEnum(OrbitState.done), .release);
        return;
    }
    while (orbit_state.load(.acquire) != @intFromEnum(OrbitState.done)) {
        std.atomic.spinLoopHint();
    }
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
    // A keyed form of the same name is not a General_Category value, so it
    // is a §22.2.1.1 SyntaxError (not a deferral).
    try testing.expectError(error.SyntaxError, resolve(testing.allocator, "gc", "Basic_Emoji"));

    // RGI_Emoji (the union) resolves too, with sequence members.
    const rgi = (try resolve(testing.allocator, null, "RGI_Emoji")) orelse
        return error.ShouldResolve;
    defer freeResolved(rgi);
    try testing.expect(rgi.strings.len > 0);
}

test "unknown names, values, and keys are a §22.2.1.1 SyntaxError" {
    // Cynic's tables are the full ES set, so an unrecognised lone name, a
    // bad keyed value, or an unknown key is an invalid
    // UnicodePropertyValueExpression — resolve raises SyntaxError directly
    // rather than deferring (which previously punted the verdict to libregexp).
    try testing.expectError(error.SyntaxError, resolve(testing.allocator, null, "NotAProperty"));
    try testing.expectError(error.SyntaxError, resolve(testing.allocator, "Script", "NotAScript"));
    try testing.expectError(error.SyntaxError, resolve(testing.allocator, "boguskey", "Latin"));
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
