//! Generate `src/unicode/case_fold_tables.zig` from the vendored
//! `CaseFolding.txt`. Backs §22.2.2.9 Canonicalize under the `/iu` and
//! `/iv` RegExp flags: the matcher folds a code point to the other
//! members of its case-folding *orbit* (its equivalence class) so a
//! pattern char matches any case variant.
//!
//!     zig build gen-unicode
//!
//! ECMA-262 §22.2.2.9 uses only the *simple* case folding: CaseFolding.txt
//! statuses C (common) and S (simple). The F (full, length-changing, e.g.
//! ß→"ss") and T (Turkic) statuses are excluded — so ß (U+00DF) folds only
//! to itself, while capital ẞ (U+1E9E, status S → 00DF) shares ß's orbit.
//! Each C/S line maps one code point to a single fully-folded target;
//! grouping all sources by target (plus the target itself) yields the
//! orbit. We emit, for each member, the orbit *excluding* that member,
//! binary-searched at runtime. Args: <out> <CaseFolding.txt>.

const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    var args_iter = init.minimal.args.iterate();
    _ = args_iter.next();
    const out_path = nextArg(&args_iter);
    const cf_path = nextArg(&args_iter);

    const data = try std.Io.Dir.cwd().readFileAlloc(io, cf_path, allocator, .unlimited);
    defer allocator.free(data);

    // target (fully-folded root) → the orbit members folding to it. The
    // root is seeded as its own first member, so an orbit is never empty.
    var groups: std.AutoArrayHashMapUnmanaged(u21, std.ArrayListUnmanaged(u21)) = .empty;
    defer {
        for (groups.values()) |*v| v.deinit(allocator);
        groups.deinit(allocator);
    }

    var unicode_version: []const u8 = "unknown";
    var it = std.mem.splitScalar(u8, data, '\n');
    while (it.next()) |line_raw| {
        const line = std.mem.trimEnd(u8, line_raw, "\r");
        if (std.mem.startsWith(u8, line, "# CaseFolding-") and std.mem.eql(u8, unicode_version, "unknown")) {
            const tail = line["# CaseFolding-".len..];
            const dot = std.mem.indexOf(u8, tail, ".txt") orelse tail.len;
            unicode_version = tail[0..dot];
            continue;
        }
        if (line.len == 0 or line[0] == '#') continue;

        var f = std.mem.splitScalar(u8, line, ';');
        const code_s = std.mem.trim(u8, f.next() orelse continue, " \t");
        const status_s = std.mem.trim(u8, f.next() orelse continue, " \t");
        const map_s = std.mem.trim(u8, f.next() orelse continue, " \t");

        // §22.2.2.9 uses simple case folding only: keep C and S, drop F
        // (length-changing) and T (Turkic).
        if (!std.mem.eql(u8, status_s, "C") and !std.mem.eql(u8, status_s, "S")) continue;
        // C/S mappings are always a single code point; a space would mean
        // a full (F) mapping slipped through — skip defensively.
        if (std.mem.indexOfScalar(u8, map_s, ' ') != null) continue;

        const code = std.fmt.parseInt(u21, code_s, 16) catch continue;
        const target = std.fmt.parseInt(u21, map_s, 16) catch continue;

        const gop = try groups.getOrPut(allocator, target);
        if (!gop.found_existing) {
            gop.value_ptr.* = .empty;
            try gop.value_ptr.append(allocator, target); // root is its own member
        }
        try gop.value_ptr.append(allocator, code);
    }

    // Flatten to one (cp, orbit-without-cp) entry per code point. A member
    // belongs to exactly one orbit (targets are fully folded, never a
    // source), so no code point repeats; assert that as we go.
    const Entry = struct { cp: u21, partners: []const u21 };
    var entries: std.ArrayListUnmanaged(Entry) = .empty;
    defer {
        for (entries.items) |e| allocator.free(e.partners);
        entries.deinit(allocator);
    }

    for (groups.values()) |*members| {
        std.mem.sort(u21, members.items, {}, std.sort.asc(u21));
        // dedupe in place (a code could appear twice if listed oddly)
        var w: usize = 0;
        for (members.items, 0..) |m, i| {
            if (i == 0 or m != members.items[i - 1]) {
                members.items[w] = m;
                w += 1;
            }
        }
        members.items.len = w;

        for (members.items, 0..) |m, mi| {
            const partners = try allocator.alloc(u21, members.items.len - 1);
            var k: usize = 0;
            for (members.items, 0..) |p, pi| {
                if (pi == mi) continue;
                partners[k] = p;
                k += 1;
            }
            try entries.append(allocator, .{ .cp = m, .partners = partners });
        }
    }

    std.mem.sort(Entry, entries.items, {}, struct {
        fn lt(_: void, a: Entry, b: Entry) bool {
            return a.cp < b.cp;
        }
    }.lt);
    for (entries.items, 0..) |e, i| {
        if (i != 0 and e.cp == entries.items[i - 1].cp)
            fatal("code point U+{X:0>4} appears in two orbits", .{e.cp});
    }

    // ── Emit ──
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);

    try buf.print(allocator,
        \\//! GENERATED by `zig build gen-unicode` from vendor/unicode/CaseFolding.txt
        \\//! (Unicode {s}). Do not edit by hand.
        \\//!
        \\//! Simple/common case-folding orbits (statuses C and S) backing
        \\//! §22.2.2.9 Canonicalize for the RegExp `/iu` and `/iv` flags.
        \\//! `caseFoldPartners(cp)` returns the other members of `cp`'s orbit
        \\//! (empty when `cp` folds only to itself).
        \\
        \\const std = @import("std");
        \\
        \\pub const Entry = struct {{ cp: u21, off: u32, len: u16 }};
        \\
        \\
    , .{unicode_version});

    // Flat partner pool plus the sorted lookup table.
    try buf.appendSlice(allocator, "pub const partners = [_]u21{\n");
    var total: usize = 0;
    for (entries.items) |e| {
        for (e.partners) |p| try buf.print(allocator, "    0x{X},\n", .{p});
        total += e.partners.len;
    }
    try buf.appendSlice(allocator, "};\n\n");

    try buf.appendSlice(allocator, "pub const entries = [_]Entry{\n");
    var off: u32 = 0;
    for (entries.items) |e| {
        try buf.print(allocator, "    .{{ .cp = 0x{X:0>4}, .off = {d}, .len = {d} }},\n", .{ e.cp, off, e.partners.len });
        off += @intCast(e.partners.len);
    }
    try buf.appendSlice(allocator, "};\n\n");

    try buf.appendSlice(allocator,
        \\/// The other members of `cp`'s simple case-folding orbit (§22.2.2.9),
        \\/// or an empty slice when `cp` folds only to itself. The returned
        \\/// slice points into the static `partners` pool.
        \\pub fn caseFoldPartners(cp: u21) []const u21 {
        \\    var lo: usize = 0;
        \\    var hi: usize = entries.len;
        \\    while (lo < hi) {
        \\        const mid = lo + (hi - lo) / 2;
        \\        const e = entries[mid];
        \\        if (cp < e.cp) {
        \\            hi = mid;
        \\        } else if (cp > e.cp) {
        \\            lo = mid + 1;
        \\        } else {
        \\            return partners[e.off..][0..e.len];
        \\        }
        \\    }
        \\    return &.{};
        \\}
        \\
    );

    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = out_path, .data = buf.items });
    std.debug.print("wrote {s}: {d} folded code points, {d} partner entries (Unicode {s})\n", .{
        out_path, entries.items.len, total, unicode_version,
    });
}

fn nextArg(it: anytype) []const u8 {
    return it.next() orelse fatal("usage: gen_case_fold <out> <CaseFolding.txt>", .{});
}

fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("error: " ++ fmt ++ "\n", args);
    std.process.exit(1);
}
