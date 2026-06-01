//! Generate `src/unicode/normalization_tables.zig` from the vendored
//! `UnicodeData.txt` and `DerivedNormalizationProps.txt`. Backs
//! §22.1.3.16 String.prototype.normalize (NFC / NFD / NFKC / NFKD,
//! Unicode §3.11 / UAX #15) and the localeCompare NFD fast path.
//!
//!     zig build gen-unicode
//!
//! Emits four tables:
//!   * `combiningClass(cp)` — Canonical_Combining_Class (UnicodeData
//!     field 3), for the canonical ordering step. Default 0.
//!   * canonical decomposition — fully recursive (UnicodeData field 5
//!     entries with NO `<tag>`), for NFD/NFC.
//!   * compatibility decomposition — fully recursive over BOTH canonical
//!     and `<tag>` mappings, for NFKD/NFKC.
//!   * `compose(a, b)` — primary composite of a starter/back pair, built
//!     from the *raw* length-2 canonical decompositions minus the
//!     Full_Composition_Exclusion set (DerivedNormalizationProps).
//!
//! Hangul L/V/T syllables (§3.12) compose / decompose algorithmically at
//! runtime, so they never enter these tables.
//!
//! Args: <out> <UnicodeData.txt> <DerivedNormalizationProps.txt>.

const std = @import("std");

const CpList = std.ArrayListUnmanaged(u21);
const DecompMap = std.AutoArrayHashMapUnmanaged(u21, []u21);

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    var args_iter = init.minimal.args.iterate();
    _ = args_iter.next();
    const out_path = nextArg(&args_iter);
    const ud_path = nextArg(&args_iter);
    const dnp_path = nextArg(&args_iter);

    const ud_data = try std.Io.Dir.cwd().readFileAlloc(io, ud_path, allocator, .unlimited);
    defer allocator.free(ud_data);
    const dnp_data = try std.Io.Dir.cwd().readFileAlloc(io, dnp_path, allocator, .unlimited);
    defer allocator.free(dnp_data);

    // ── parse UnicodeData.txt ──
    var ccc = std.AutoArrayHashMapUnmanaged(u21, u8){};
    defer ccc.deinit(allocator);
    // Raw (non-recursive) maps as listed in field 5.
    var canon_raw: DecompMap = .empty; // no-tag decompositions only
    var compat_raw: DecompMap = .empty; // `<tag>` decompositions only
    defer {
        for (canon_raw.values()) |v| allocator.free(v);
        for (compat_raw.values()) |v| allocator.free(v);
        canon_raw.deinit(allocator);
        compat_raw.deinit(allocator);
    }

    {
        var it = std.mem.splitScalar(u8, ud_data, '\n');
        while (it.next()) |line_raw| {
            const line = std.mem.trimEnd(u8, line_raw, "\r");
            if (line.len == 0) continue;
            var fi = std.mem.splitScalar(u8, line, ';');
            var fields: [15][]const u8 = @splat("");
            var n: usize = 0;
            while (fi.next()) |f| : (n += 1) {
                if (n < fields.len) fields[n] = f;
            }
            if (n < 6) continue;
            const code = std.fmt.parseInt(u21, fields[0], 16) catch continue;

            // field 3 — Canonical_Combining_Class (decimal).
            const klass = std.fmt.parseInt(u8, fields[3], 10) catch 0;
            if (klass != 0) try ccc.put(allocator, code, klass);

            // field 5 — Decomposition_Mapping.
            const d = std.mem.trim(u8, fields[5], " \t");
            if (d.len == 0) continue;
            if (d[0] == '<') {
                // `<tag> cps…` — compatibility mapping. Skip the tag.
                const close = std.mem.indexOfScalar(u8, d, '>') orelse continue;
                const cps = try parseCps(allocator, d[close + 1 ..]);
                try compat_raw.put(allocator, code, cps);
            } else {
                const cps = try parseCps(allocator, d);
                try canon_raw.put(allocator, code, cps);
            }
        }
    }

    // ── parse Full_Composition_Exclusion ──
    var excl = std.AutoHashMapUnmanaged(u21, void){};
    defer excl.deinit(allocator);
    var version: []const u8 = "unknown";
    {
        var it = std.mem.splitScalar(u8, dnp_data, '\n');
        while (it.next()) |line_raw| {
            const line = std.mem.trimEnd(u8, line_raw, "\r");
            if (std.mem.startsWith(u8, line, "# DerivedNormalizationProps-") and std.mem.eql(u8, version, "unknown")) {
                const tail = line["# DerivedNormalizationProps-".len..];
                const dot = std.mem.indexOf(u8, tail, ".txt") orelse tail.len;
                version = tail[0..dot];
                continue;
            }
            if (line.len == 0 or line[0] == '#') continue;
            var rest = line;
            if (std.mem.indexOfScalar(u8, rest, '#')) |h| rest = rest[0..h];
            var fi = std.mem.splitScalar(u8, rest, ';');
            const range_s = std.mem.trim(u8, fi.next() orelse continue, " \t");
            const prop = std.mem.trim(u8, fi.next() orelse continue, " \t");
            if (!std.mem.eql(u8, prop, "Full_Composition_Exclusion")) continue;
            const r = parseRange(range_s) orelse continue;
            var cp = r.lo;
            while (cp <= r.hi) : (cp += 1) try excl.put(allocator, cp, {});
        }
    }

    // ── fully-recursive decompositions ──
    var canon_full: DecompMap = .empty;
    var compat_full: DecompMap = .empty;
    defer {
        for (canon_full.values()) |v| allocator.free(v);
        for (compat_full.values()) |v| allocator.free(v);
        canon_full.deinit(allocator);
        compat_full.deinit(allocator);
    }
    {
        // NFD: expand canonical mappings recursively.
        var it = canon_raw.iterator();
        while (it.next()) |e| {
            var out: CpList = .empty;
            try expand(allocator, &out, e.key_ptr.*, canon_raw, null);
            try canon_full.put(allocator, e.key_ptr.*, try out.toOwnedSlice(allocator));
        }
    }
    {
        // NFKD: expand using compatibility mappings, falling back to
        // canonical, recursively. Every char with ANY decomposition gets
        // a self-contained fully-expanded entry.
        var seen = std.AutoHashMapUnmanaged(u21, void){};
        defer seen.deinit(allocator);
        for ([_]*const DecompMap{ &canon_raw, &compat_raw }) |m| {
            var it = m.iterator();
            while (it.next()) |e| {
                const cp = e.key_ptr.*;
                if (seen.contains(cp)) continue;
                try seen.put(allocator, cp, {});
                var out: CpList = .empty;
                try expand(allocator, &out, cp, canon_raw, &compat_raw);
                try compat_full.put(allocator, cp, try out.toOwnedSlice(allocator));
            }
        }
    }

    // ── composition pairs ──
    const ComposeEntry = struct { a: u21, b: u21, c: u21 };
    var compose_list: std.ArrayListUnmanaged(ComposeEntry) = .empty;
    defer compose_list.deinit(allocator);
    {
        var it = canon_raw.iterator();
        while (it.next()) |e| {
            const s = e.key_ptr.*;
            const d = e.value_ptr.*;
            if (d.len != 2) continue; // singletons never compose
            if (excl.contains(s)) continue; // Full_Composition_Exclusion
            try compose_list.append(allocator, .{ .a = d[0], .b = d[1], .c = s });
        }
    }
    std.mem.sort(ComposeEntry, compose_list.items, {}, struct {
        fn lt(_: void, x: ComposeEntry, y: ComposeEntry) bool {
            if (x.a != y.a) return x.a < y.a;
            return x.b < y.b;
        }
    }.lt);

    // sorted CCC entries
    const CccEntry = struct { cp: u21, klass: u8 };
    var ccc_list: std.ArrayListUnmanaged(CccEntry) = .empty;
    defer ccc_list.deinit(allocator);
    {
        var it = ccc.iterator();
        while (it.next()) |e| try ccc_list.append(allocator, .{ .cp = e.key_ptr.*, .klass = e.value_ptr.* });
    }
    std.mem.sort(CccEntry, ccc_list.items, {}, struct {
        fn lt(_: void, x: CccEntry, y: CccEntry) bool {
            return x.cp < y.cp;
        }
    }.lt);

    // ── emit ──
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);

    try buf.print(allocator,
        \\//! GENERATED by `zig build gen-unicode` from vendor/unicode/
        \\//! {{UnicodeData,DerivedNormalizationProps}}.txt (Unicode {s}).
        \\//! Do not edit by hand.
        \\//!
        \\//! Unicode Normalization tables (§3.11 / UAX #15): combining
        \\//! class, fully-recursive canonical (NFD) + compatibility (NFKD)
        \\//! decompositions, and primary-composite pairs (NFC/NFKC). Hangul
        \\//! syllables are handled algorithmically in `normalization.zig`.
        \\
        \\const std = @import("std");
        \\
        \\pub const MapEntry = struct {{ cp: u21, off: u32, len: u8 }};
        \\pub const CccEntry = struct {{ cp: u21, klass: u8 }};
        \\pub const ComposeEntry = struct {{ a: u21, b: u21, c: u21 }};
        \\
        \\
    , .{version});

    // CCC
    try buf.print(allocator, "pub const ccc_entries = [_]CccEntry{{\n", .{});
    for (ccc_list.items) |e| try buf.print(allocator, "    .{{ .cp = 0x{X:0>4}, .klass = {d} }},\n", .{ e.cp, e.klass });
    try buf.appendSlice(allocator, "};\n\n");

    try emitDecomp(allocator, &buf, "canon", canon_full);
    try emitDecomp(allocator, &buf, "compat", compat_full);

    // compose
    try buf.print(allocator, "pub const compose_entries = [_]ComposeEntry{{\n", .{});
    for (compose_list.items) |e| try buf.print(allocator, "    .{{ .a = 0x{X:0>4}, .b = 0x{X:0>4}, .c = 0x{X:0>4} }},\n", .{ e.a, e.b, e.c });
    try buf.appendSlice(allocator, "};\n\n");

    try buf.appendSlice(allocator,
        \\/// Canonical_Combining_Class of `cp` (0 for the vast majority).
        \\pub fn combiningClass(cp: u21) u8 {
        \\    var lo: usize = 0;
        \\    var hi: usize = ccc_entries.len;
        \\    while (lo < hi) {
        \\        const mid = lo + (hi - lo) / 2;
        \\        const e = ccc_entries[mid];
        \\        if (cp < e.cp) {
        \\            hi = mid;
        \\        } else if (cp > e.cp) {
        \\            lo = mid + 1;
        \\        } else return e.klass;
        \\    }
        \\    return 0;
        \\}
        \\
        \\fn lookupDecomp(entries: []const MapEntry, data: []const u21, cp: u21) ?[]const u21 {
        \\    var lo: usize = 0;
        \\    var hi: usize = entries.len;
        \\    while (lo < hi) {
        \\        const mid = lo + (hi - lo) / 2;
        \\        const e = entries[mid];
        \\        if (cp < e.cp) {
        \\            hi = mid;
        \\        } else if (cp > e.cp) {
        \\            lo = mid + 1;
        \\        } else return data[e.off..][0..e.len];
        \\    }
        \\    return null;
        \\}
        \\
        \\/// Fully-recursive canonical decomposition of `cp` (NFD), or null.
        \\pub fn canonicalDecomposition(cp: u21) ?[]const u21 {
        \\    return lookupDecomp(&canon_entries, &canon_data, cp);
        \\}
        \\
        \\/// Fully-recursive compatibility decomposition of `cp` (NFKD), or null.
        \\pub fn compatibilityDecomposition(cp: u21) ?[]const u21 {
        \\    return lookupDecomp(&compat_entries, &compat_data, cp);
        \\}
        \\
        \\/// Primary composite of the ordered pair (a, b), or null if the pair
        \\/// has no canonical composition (or is composition-excluded).
        \\pub fn compose(a: u21, b: u21) ?u21 {
        \\    var lo: usize = 0;
        \\    var hi: usize = compose_entries.len;
        \\    while (lo < hi) {
        \\        const mid = lo + (hi - lo) / 2;
        \\        const e = compose_entries[mid];
        \\        if (a < e.a or (a == e.a and b < e.b)) {
        \\            hi = mid;
        \\        } else if (a > e.a or (a == e.a and b > e.b)) {
        \\            lo = mid + 1;
        \\        } else return e.c;
        \\    }
        \\    return null;
        \\}
        \\
    );

    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = out_path, .data = buf.items });
    std.debug.print("wrote {s}: {d} ccc, {d} canon, {d} compat decomps, {d} compose pairs (Unicode {s})\n", .{
        out_path, ccc_list.items.len, canon_full.count(), compat_full.count(), compose_list.items.len, version,
    });
}

/// Recursively expand `cp` into `out` using `primary` (and `secondary`
/// taking precedence when non-null) decomposition maps. A code point
/// with no mapping appends itself.
fn expand(
    allocator: std.mem.Allocator,
    out: *CpList,
    cp: u21,
    primary: DecompMap,
    secondary: ?*const DecompMap,
) !void {
    if (secondary) |sec| {
        if (sec.get(cp)) |d| {
            for (d) |c| try expand(allocator, out, c, primary, secondary);
            return;
        }
    }
    if (primary.get(cp)) |d| {
        for (d) |c| try expand(allocator, out, c, primary, secondary);
        return;
    }
    try out.append(allocator, cp);
}

fn emitDecomp(
    allocator: std.mem.Allocator,
    buf: *std.ArrayListUnmanaged(u8),
    comptime name: []const u8,
    map: DecompMap,
) !void {
    const keys = try allocator.dupe(u21, map.keys());
    defer allocator.free(keys);
    std.mem.sort(u21, keys, {}, struct {
        fn lt(_: void, a: u21, b: u21) bool {
            return a < b;
        }
    }.lt);

    try buf.print(allocator, "pub const {s}_data = [_]u21{{\n", .{name});
    for (keys) |cp| {
        for (map.get(cp).?) |c| try buf.print(allocator, "    0x{X},\n", .{c});
    }
    try buf.appendSlice(allocator, "};\n\n");

    try buf.print(allocator, "pub const {s}_entries = [_]MapEntry{{\n", .{name});
    var off: u32 = 0;
    for (keys) |cp| {
        const d = map.get(cp).?;
        try buf.print(allocator, "    .{{ .cp = 0x{X:0>4}, .off = {d}, .len = {d} }},\n", .{ cp, off, d.len });
        off += @intCast(d.len);
    }
    try buf.appendSlice(allocator, "};\n\n");
}

fn parseCps(allocator: std.mem.Allocator, s: []const u8) ![]u21 {
    var list: CpList = .empty;
    errdefer list.deinit(allocator);
    var it = std.mem.tokenizeAny(u8, s, " \t");
    while (it.next()) |tok| {
        const cp = std.fmt.parseInt(u21, tok, 16) catch continue;
        try list.append(allocator, cp);
    }
    return list.toOwnedSlice(allocator);
}

const Range = struct { lo: u21, hi: u21 };

fn parseRange(s: []const u8) ?Range {
    if (std.mem.indexOf(u8, s, "..")) |dd| {
        const lo = std.fmt.parseInt(u21, s[0..dd], 16) catch return null;
        const hi = std.fmt.parseInt(u21, s[dd + 2 ..], 16) catch return null;
        return .{ .lo = lo, .hi = hi };
    }
    const v = std.fmt.parseInt(u21, s, 16) catch return null;
    return .{ .lo = v, .hi = v };
}

fn nextArg(it: anytype) []const u8 {
    return it.next() orelse {
        std.debug.print("error: missing argument\n", .{});
        std.process.exit(1);
    };
}
