//! Generate `src/unicode/ident_tables.zig` from a UCD `DerivedCoreProperties.txt`
//! file. Mirrors the JavaScriptCore approach: a small generator emits sorted
//! codepoint ranges into a Zig source file, the result is committed, and the
//! lexer binary-searches it. Run on demand when bumping the Unicode target:
//!
//! zig build gen-unicode
//!
//! Cynic tracks the Unicode "latest" version per §3 of ECMA-262 (currently
//! Unicode 17.0). When a new Unicode version ships, replace the file under
//! `vendor/unicode/DerivedCoreProperties.txt` and re-run this generator.

const std = @import("std");

const Range = struct { start: u21, end: u21 };

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    var args_iter = init.minimal.args.iterate();
    _ = args_iter.next();
    const ucd_path = args_iter.next() orelse fatal("usage: gen_unicode_idents <ucd-file> <output-file>", .{});
    const out_path = args_iter.next() orelse fatal("usage: gen_unicode_idents <ucd-file> <output-file>", .{});

    const data = try std.Io.Dir.cwd().readFileAlloc(io, ucd_path, allocator, .unlimited);
    defer allocator.free(data);

    var unicode_version: []const u8 = "unknown";

    var id_start: std.ArrayListUnmanaged(Range) = .empty;
    defer id_start.deinit(allocator);
    var id_continue: std.ArrayListUnmanaged(Range) = .empty;
    defer id_continue.deinit(allocator);

    var line_iter = std.mem.splitScalar(u8, data, '\n');
    while (line_iter.next()) |line_raw| {
        const line = std.mem.trimEnd(u8, line_raw, "\r");

        if (std.mem.startsWith(u8, line, "# DerivedCoreProperties-") and std.mem.eql(u8, unicode_version, "unknown")) {
            const tail = line["# DerivedCoreProperties-".len..];
            const dot_txt = std.mem.indexOf(u8, tail, ".txt") orelse tail.len;
            unicode_version = tail[0..dot_txt];
            continue;
        }
        if (line.len == 0 or line[0] == '#') continue;

        const semi = std.mem.indexOfScalar(u8, line, ';') orelse continue;
        const cps = std.mem.trim(u8, line[0..semi], " \t");
        var prop_part = line[semi + 1 ..];
        if (std.mem.indexOfScalar(u8, prop_part, '#')) |hash| prop_part = prop_part[0..hash];
        const prop = std.mem.trim(u8, prop_part, " \t");

        const list: ?*std.ArrayListUnmanaged(Range) = blk: {
            if (std.mem.eql(u8, prop, "ID_Start")) break :blk &id_start;
            if (std.mem.eql(u8, prop, "ID_Continue")) break :blk &id_continue;
            break :blk null;
        };
        if (list == null) continue;

        const range = parseCodepointRange(cps) catch |err| {
            std.debug.print("warning: skipping malformed line '{s}': {t}\n", .{ line, err });
            continue;
        };
        try list.?.append(allocator, range);
    }

    sortAndMerge(&id_start);
    sortAndMerge(&id_continue);

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);

    try buf.appendSlice(allocator,
        \\//! GENERATED FILE — DO NOT EDIT BY HAND.
        \\//!
        \\//! Produced by `zig build gen-unicode` from
        \\//! `vendor/unicode/DerivedCoreProperties.txt`.
        \\//!
        \\
    );
    try buf.print(allocator, "//! Unicode version: {s}\n\n",.{unicode_version});
    try buf.appendSlice(allocator,
        \\pub const Range = struct {
        \\    start: u21,
        \\    end: u21,
        \\};
        \\
        \\
    );
    try emitRanges(allocator, &buf, "id_start_ranges", id_start.items);
    try buf.append(allocator, '\n');
    try emitRanges(allocator, &buf, "id_continue_ranges", id_continue.items);

    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = out_path, .data = buf.items });

    std.debug.print("wrote {s}: {d} ID_Start ranges, {d} ID_Continue ranges (Unicode {s})\n", .{
        out_path,
        id_start.items.len,
        id_continue.items.len,
        unicode_version,
    });
}

fn parseCodepointRange(s: []const u8) !Range {
    if (std.mem.indexOf(u8, s, "..")) |i| {
        const start = try std.fmt.parseInt(u21, s[0..i], 16);
        const end = try std.fmt.parseInt(u21, s[i + 2 ..], 16);
        return .{ .start = start, .end = end };
    }
    const cp = try std.fmt.parseInt(u21, s, 16);
    return .{ .start = cp, .end = cp };
}

fn lessRange(_: void, a: Range, b: Range) bool {
    return a.start < b.start;
}

fn sortAndMerge(list: *std.ArrayListUnmanaged(Range)) void {
    std.mem.sort(Range, list.items, {}, lessRange);
    if (list.items.len <= 1) return;
    var write: usize = 0;
    var i: usize = 1;
    while (i < list.items.len) : (i += 1) {
        const cur = &list.items[write];
        const next = list.items[i];
        // Merge adjacent or overlapping ranges.
        if (next.start <= @as(u32, cur.end) + 1) {
            if (next.end > cur.end) cur.end = next.end;
        } else {
            write += 1;
            list.items[write] = next;
        }
    }
    list.items.len = write + 1;
}

fn emitRanges(
    allocator: std.mem.Allocator,
    buf: *std.ArrayListUnmanaged(u8),
    name: []const u8,
    ranges: []const Range,
) !void {
    try buf.print(allocator, "pub const {s} = [_]Range{{\n", .{name});
    for (ranges) |r| {
        try buf.print(allocator, "    .{{ .start = 0x{X:0>4}, .end = 0x{X:0>4} }},\n", .{ r.start, r.end });
    }
    try buf.appendSlice(allocator, "};\n");
}

fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("error: " ++ fmt ++ "\n", args);
    std.process.exit(1);
}
