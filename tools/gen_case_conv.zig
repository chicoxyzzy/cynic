//! Generate `src/unicode/case_conv_tables.zig` from the vendored
//! `UnicodeData.txt`, `SpecialCasing.txt`, and `DerivedCoreProperties.txt`.
//! Backs §22.1.3.{26,27,28,29} String.prototype.to{Lower,Upper}Case (and
//! the toLocale* variants for the default / `en` locale) plus the non-`/u`
//! RegExp Canonicalize (§22.2.2.7.3 toUppercase) in `perlex_props`.
//!
//!     zig build gen-unicode
//!
//! Case CONVERSION (toUpper / toLower) is distinct from case FOLDING
//! (`gen_case_fold`): conversion uses the language-independent Default
//! Case Conversion (Unicode §3.13). The simple 1:1 mappings come from
//! UnicodeData fields 12 (uppercase) / 13 (lowercase); the *unconditional*
//! full mappings (e.g. ß→"SS", ﬀ→"FF", İ→"i̇") come from SpecialCasing and
//! override the simple ones. SpecialCasing's CONDITIONAL entries are
//! dropped: Final_Sigma is handled by `string.zig`'s context lookahead
//! (using the Cased / Case_Ignorable tables emitted here), and the
//! locale-specific `lt` / `tr` / `az` entries are out of scope (Intl).
//!
//! Args: <out> <UnicodeData.txt> <SpecialCasing.txt> <DerivedCoreProperties.txt>.

const std = @import("std");

const Map = std.AutoArrayHashMapUnmanaged(u21, []u21);
const Range = struct { lo: u21, hi: u21 };

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    var args_iter = init.minimal.args.iterate();
    _ = args_iter.next();
    const out_path = nextArg(&args_iter);
    const unicode_data_path = nextArg(&args_iter);
    const special_casing_path = nextArg(&args_iter);
    const dcp_path = nextArg(&args_iter);

    const ud_data = try std.Io.Dir.cwd().readFileAlloc(io, unicode_data_path, allocator, .unlimited);
    defer allocator.free(ud_data);
    const sc_data = try std.Io.Dir.cwd().readFileAlloc(io, special_casing_path, allocator, .unlimited);
    defer allocator.free(sc_data);
    const dcp_data = try std.Io.Dir.cwd().readFileAlloc(io, dcp_path, allocator, .unlimited);
    defer allocator.free(dcp_data);

    var upper: Map = .empty;
    var lower: Map = .empty;
    defer {
        for (upper.values()) |v| allocator.free(v);
        for (lower.values()) |v| allocator.free(v);
        upper.deinit(allocator);
        lower.deinit(allocator);
    }

    // ── UnicodeData.txt: simple (single code point) mappings ──
    // Fields: 0=code … 12=Simple_Uppercase, 13=Simple_Lowercase. Only
    // non-identity mappings are listed there, so a present field is a
    // real mapping. Range markers (`<…, First>` / `Last>`) carry empty
    // case fields, so they contribute nothing.
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
            if (n < 14) continue;
            const code = std.fmt.parseInt(u21, fields[0], 16) catch continue;
            if (fields[12].len != 0) {
                const u = std.fmt.parseInt(u21, fields[12], 16) catch continue;
                if (u != code) try putMap(allocator, &upper, code, &.{u});
            }
            if (fields[13].len != 0) {
                const l = std.fmt.parseInt(u21, fields[13], 16) catch continue;
                if (l != code) try putMap(allocator, &lower, code, &.{l});
            }
        }
    }

    // ── SpecialCasing.txt: unconditional full mappings override ──
    // `code; lower; title; upper; (condition;)? # comment`. A non-empty
    // condition (Final_Sigma / lt / tr / az) is dropped.
    {
        var it = std.mem.splitScalar(u8, sc_data, '\n');
        while (it.next()) |line_raw| {
            var line = std.mem.trimEnd(u8, line_raw, "\r");
            if (std.mem.indexOfScalar(u8, line, '#')) |h| line = line[0..h];
            line = std.mem.trim(u8, line, " \t");
            if (line.len == 0) continue;
            var fi = std.mem.splitScalar(u8, line, ';');
            const code_s = std.mem.trim(u8, fi.next() orelse continue, " \t");
            const lower_s = std.mem.trim(u8, fi.next() orelse continue, " \t");
            _ = fi.next() orelse continue; // title — unused (toUpper/toLower only)
            const upper_s = std.mem.trim(u8, fi.next() orelse continue, " \t");
            const cond_s = std.mem.trim(u8, fi.next() orelse "", " \t");
            if (cond_s.len != 0) continue; // conditional → skip

            const code = std.fmt.parseInt(u21, code_s, 16) catch continue;
            var ubuf: [8]u21 = undefined;
            var lbuf: [8]u21 = undefined;
            const us = parseCps(upper_s, &ubuf);
            const ls = parseCps(lower_s, &lbuf);
            if (!(us.len == 1 and us[0] == code)) try putMap(allocator, &upper, code, us);
            if (!(ls.len == 1 and ls[0] == code)) try putMap(allocator, &lower, code, ls);
        }
    }

    // ── DerivedCoreProperties.txt: Cased + Case_Ignorable ranges ──
    var cased: std.ArrayListUnmanaged(Range) = .empty;
    defer cased.deinit(allocator);
    var ignorable: std.ArrayListUnmanaged(Range) = .empty;
    defer ignorable.deinit(allocator);
    var version: []const u8 = "unknown";
    {
        var it = std.mem.splitScalar(u8, dcp_data, '\n');
        while (it.next()) |line_raw| {
            const line = std.mem.trimEnd(u8, line_raw, "\r");
            if (std.mem.startsWith(u8, line, "# DerivedCoreProperties-") and std.mem.eql(u8, version, "unknown")) {
                const tail = line["# DerivedCoreProperties-".len..];
                const dot = std.mem.indexOf(u8, tail, ".txt") orelse tail.len;
                version = tail[0..dot];
                continue;
            }
            if (line.len == 0 or line[0] == '#') continue;
            const semi = std.mem.indexOfScalar(u8, line, ';') orelse continue;
            const range_s = std.mem.trim(u8, line[0..semi], " \t");
            var rest = line[semi + 1 ..];
            if (std.mem.indexOfScalar(u8, rest, '#')) |h| rest = rest[0..h];
            const prop = std.mem.trim(u8, rest, " \t");
            const list = if (std.mem.eql(u8, prop, "Cased"))
                &cased
            else if (std.mem.eql(u8, prop, "Case_Ignorable"))
                &ignorable
            else
                continue;
            const r = parseRange(range_s) orelse continue;
            try list.append(allocator, r);
        }
    }
    std.mem.sort(Range, cased.items, {}, rangeLt);
    std.mem.sort(Range, ignorable.items, {}, rangeLt);

    // ── Emit ──
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);

    try buf.print(allocator,
        \\//! GENERATED by `zig build gen-unicode` from vendor/unicode/
        \\//! {{UnicodeData,SpecialCasing,DerivedCoreProperties}}.txt
        \\//! (Unicode {s}). Do not edit by hand.
        \\//!
        \\//! Language-independent Default Case Conversion (Unicode §3.13):
        \\//! `convert(res, cp, to_upper)` writes 1-3 result code points and
        \\//! returns the count (identity → the input). Backs String.prototype.
        \\//! to{{Lower,Upper}}Case (§22.1.3.26/27) and the non-/u RegExp
        \\//! Canonicalize (§22.2.2.7.3). `isCased` / `isCaseIgnorable` back the
        \\//! §22.1.3.26 Final_Sigma context check.
        \\
        \\const std = @import("std");
        \\
        \\pub const MapEntry = struct {{ cp: u21, off: u32, len: u8 }};
        \\pub const Range = struct {{ lo: u21, hi: u21 }};
        \\
        \\
    , .{version});

    try emitMap(allocator, &buf, "upper", upper);
    try emitMap(allocator, &buf, "lower", lower);
    try emitRanges(allocator, &buf, "cased", cased.items);
    try emitRanges(allocator, &buf, "case_ignorable", ignorable.items);

    try buf.appendSlice(allocator,
        \\fn lookup(entries: []const MapEntry, data: []const u21, res: *[3]u21, cp: u21) usize {
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
        \\            const m = data[e.off..][0..e.len];
        \\            for (m, 0..) |c, i| res[i] = c;
        \\            return e.len;
        \\        }
        \\    }
        \\    res[0] = cp;
        \\    return 1;
        \\}
        \\
        \\/// Write the unconditional Default Case Conversion of `cp` into
        \\/// `res` (1-3 code points) and return the count. `to_upper` selects
        \\/// uppercase, else lowercase; an uncased code point maps to itself.
        \\pub fn convert(res: *[3]u21, cp: u21, to_upper: bool) usize {
        \\    return if (to_upper)
        \\        lookup(&upper_entries, &upper_data, res, cp)
        \\    else
        \\        lookup(&lower_entries, &lower_data, res, cp);
        \\}
        \\
        \\fn inRanges(ranges: []const Range, cp: u21) bool {
        \\    var lo: usize = 0;
        \\    var hi: usize = ranges.len;
        \\    while (lo < hi) {
        \\        const mid = lo + (hi - lo) / 2;
        \\        const r = ranges[mid];
        \\        if (cp < r.lo) {
        \\            hi = mid;
        \\        } else if (cp > r.hi) {
        \\            lo = mid + 1;
        \\        } else {
        \\            return true;
        \\        }
        \\    }
        \\    return false;
        \\}
        \\
        \\/// §22.1.3.26 — the Unicode `Cased` derived property.
        \\pub fn isCased(cp: u21) bool {
        \\    return inRanges(&cased_ranges, cp);
        \\}
        \\
        \\/// §22.1.3.26 — the Unicode `Case_Ignorable` derived property.
        \\pub fn isCaseIgnorable(cp: u21) bool {
        \\    return inRanges(&case_ignorable_ranges, cp);
        \\}
        \\
    );

    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = out_path, .data = buf.items });
    std.debug.print("wrote {s}: {d} upper, {d} lower mappings; {d} cased, {d} case-ignorable ranges (Unicode {s})\n", .{
        out_path, upper.count(), lower.count(), cased.items.len, ignorable.items.len, version,
    });
}

fn putMap(allocator: std.mem.Allocator, map: *Map, cp: u21, cps: []const u21) !void {
    const gop = try map.getOrPut(allocator, cp);
    if (gop.found_existing) allocator.free(gop.value_ptr.*);
    gop.value_ptr.* = try allocator.dupe(u21, cps);
}

fn parseCps(s: []const u8, buf: []u21) []u21 {
    var n: usize = 0;
    var it = std.mem.tokenizeScalar(u8, s, ' ');
    while (it.next()) |tok| {
        if (n >= buf.len) break;
        buf[n] = std.fmt.parseInt(u21, tok, 16) catch continue;
        n += 1;
    }
    return buf[0..n];
}

fn parseRange(s: []const u8) ?Range {
    if (std.mem.indexOf(u8, s, "..")) |dd| {
        const lo = std.fmt.parseInt(u21, s[0..dd], 16) catch return null;
        const hi = std.fmt.parseInt(u21, s[dd + 2 ..], 16) catch return null;
        return .{ .lo = lo, .hi = hi };
    }
    const cp = std.fmt.parseInt(u21, s, 16) catch return null;
    return .{ .lo = cp, .hi = cp };
}

fn rangeLt(_: void, a: Range, b: Range) bool {
    return a.lo < b.lo;
}

fn emitMap(allocator: std.mem.Allocator, buf: *std.ArrayListUnmanaged(u8), comptime name: []const u8, map: Map) !void {
    // Sort code points so the runtime can binary-search.
    const keys = try allocator.dupe(u21, map.keys());
    defer allocator.free(keys);
    std.mem.sort(u21, keys, {}, std.sort.asc(u21));

    try buf.print(allocator, "pub const {s}_data = [_]u21{{\n", .{name});
    for (keys) |cp| {
        for (map.get(cp).?) |c| try buf.print(allocator, "    0x{X},\n", .{c});
    }
    try buf.appendSlice(allocator, "};\n\n");

    try buf.print(allocator, "pub const {s}_entries = [_]MapEntry{{\n", .{name});
    var off: u32 = 0;
    for (keys) |cp| {
        const m = map.get(cp).?;
        try buf.print(allocator, "    .{{ .cp = 0x{X:0>4}, .off = {d}, .len = {d} }},\n", .{ cp, off, m.len });
        off += @intCast(m.len);
    }
    try buf.appendSlice(allocator, "};\n\n");
}

fn emitRanges(allocator: std.mem.Allocator, buf: *std.ArrayListUnmanaged(u8), comptime name: []const u8, ranges: []const Range) !void {
    try buf.print(allocator, "pub const {s}_ranges = [_]Range{{\n", .{name});
    for (ranges) |r| try buf.print(allocator, "    .{{ .lo = 0x{X:0>4}, .hi = 0x{X:0>4} }},\n", .{ r.lo, r.hi });
    try buf.appendSlice(allocator, "};\n\n");
}

fn nextArg(it: anytype) []const u8 {
    return it.next() orelse fatal("usage: gen_case_conv <out> <UnicodeData.txt> <SpecialCasing.txt> <DerivedCoreProperties.txt>", .{});
}

fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("error: " ++ fmt ++ "\n", args);
    std.process.exit(1);
}
