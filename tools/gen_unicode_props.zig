//! Generate `src/unicode/property_tables.zig` from the vendored UCD files.
//! Backs RegExp `\p{…}` / `\P{…}` Unicode property escapes (ECMA-262
//! §22.2.1.1). Same model as `gen_unicode_idents.zig`: parse the UCD, emit
//! sorted code-point ranges into a committed Zig source file, binary-search
//! it at runtime. Run on demand when bumping the Unicode target:
//!
//!     zig build gen-unicode
//!
//! The *names* a property exposes (abbreviation, long name, aliases) and the
//! membership of the grouped General_Category values are fixed by the spec,
//! so they are hardcoded here; only the code-point ranges are version data,
//! parsed from `vendor/unicode/DerivedGeneralCategory.txt`.

const std = @import("std");

const Range = struct { start: u21, end: u21 };

/// One General_Category value ECMA-262 §22.2.1.1 recognises. `members` is
/// empty for an atomic category; a non-empty `members` marks a grouped value
/// synthesised as the union of those atomic categories' ranges.
const Category = struct {
    abbr: []const u8,
    names: []const []const u8,
    members: []const []const u8 = &.{},
};

const categories = [_]Category{
    // Letters
    .{ .abbr = "Lu", .names = &.{ "Lu", "Uppercase_Letter" } },
    .{ .abbr = "Ll", .names = &.{ "Ll", "Lowercase_Letter" } },
    .{ .abbr = "Lt", .names = &.{ "Lt", "Titlecase_Letter" } },
    .{ .abbr = "Lm", .names = &.{ "Lm", "Modifier_Letter" } },
    .{ .abbr = "Lo", .names = &.{ "Lo", "Other_Letter" } },
    // Marks
    .{ .abbr = "Mn", .names = &.{ "Mn", "Nonspacing_Mark" } },
    .{ .abbr = "Mc", .names = &.{ "Mc", "Spacing_Mark" } },
    .{ .abbr = "Me", .names = &.{ "Me", "Enclosing_Mark" } },
    // Numbers
    .{ .abbr = "Nd", .names = &.{ "Nd", "Decimal_Number", "digit" } },
    .{ .abbr = "Nl", .names = &.{ "Nl", "Letter_Number" } },
    .{ .abbr = "No", .names = &.{ "No", "Other_Number" } },
    // Punctuation
    .{ .abbr = "Pc", .names = &.{ "Pc", "Connector_Punctuation" } },
    .{ .abbr = "Pd", .names = &.{ "Pd", "Dash_Punctuation" } },
    .{ .abbr = "Ps", .names = &.{ "Ps", "Open_Punctuation" } },
    .{ .abbr = "Pe", .names = &.{ "Pe", "Close_Punctuation" } },
    .{ .abbr = "Pi", .names = &.{ "Pi", "Initial_Punctuation" } },
    .{ .abbr = "Pf", .names = &.{ "Pf", "Final_Punctuation" } },
    .{ .abbr = "Po", .names = &.{ "Po", "Other_Punctuation" } },
    // Symbols
    .{ .abbr = "Sm", .names = &.{ "Sm", "Math_Symbol" } },
    .{ .abbr = "Sc", .names = &.{ "Sc", "Currency_Symbol" } },
    .{ .abbr = "Sk", .names = &.{ "Sk", "Modifier_Symbol" } },
    .{ .abbr = "So", .names = &.{ "So", "Other_Symbol" } },
    // Separators
    .{ .abbr = "Zs", .names = &.{ "Zs", "Space_Separator" } },
    .{ .abbr = "Zl", .names = &.{ "Zl", "Line_Separator" } },
    .{ .abbr = "Zp", .names = &.{ "Zp", "Paragraph_Separator" } },
    // Other
    .{ .abbr = "Cc", .names = &.{ "Cc", "Control", "cntrl" } },
    .{ .abbr = "Cf", .names = &.{ "Cf", "Format" } },
    .{ .abbr = "Cs", .names = &.{ "Cs", "Surrogate" } },
    .{ .abbr = "Co", .names = &.{ "Co", "Private_Use" } },
    .{ .abbr = "Cn", .names = &.{ "Cn", "Unassigned" } },
    // Groups (union of member categories) — §22.2.1.1 Table of gc values.
    .{ .abbr = "L", .names = &.{ "L", "Letter" }, .members = &.{ "Lu", "Ll", "Lt", "Lm", "Lo" } },
    .{ .abbr = "LC", .names = &.{ "LC", "Cased_Letter" }, .members = &.{ "Lu", "Ll", "Lt" } },
    .{ .abbr = "M", .names = &.{ "M", "Mark", "Combining_Mark" }, .members = &.{ "Mn", "Mc", "Me" } },
    .{ .abbr = "N", .names = &.{ "N", "Number" }, .members = &.{ "Nd", "Nl", "No" } },
    .{ .abbr = "P", .names = &.{ "P", "Punctuation", "punct" }, .members = &.{ "Pc", "Pd", "Ps", "Pe", "Pi", "Pf", "Po" } },
    .{ .abbr = "S", .names = &.{ "S", "Symbol" }, .members = &.{ "Sm", "Sc", "Sk", "So" } },
    .{ .abbr = "Z", .names = &.{ "Z", "Separator" }, .members = &.{ "Zs", "Zl", "Zp" } },
    .{ .abbr = "C", .names = &.{ "C", "Other" }, .members = &.{ "Cc", "Cf", "Cs", "Co", "Cn" } },
};

fn indexOfAbbr(abbr: []const u8) ?usize {
    for (categories, 0..) |c, i| {
        if (std.mem.eql(u8, c.abbr, abbr)) return i;
    }
    return null;
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    var args_iter = init.minimal.args.iterate();
    _ = args_iter.next();
    const out_path = args_iter.next() orelse fatal("usage: gen_unicode_props <output> <DerivedGeneralCategory.txt>", .{});
    const gc_path = args_iter.next() orelse fatal("usage: gen_unicode_props <output> <DerivedGeneralCategory.txt>", .{});

    const data = try std.Io.Dir.cwd().readFileAlloc(io, gc_path, allocator, .unlimited);
    defer allocator.free(data);

    var lists: [categories.len]std.ArrayListUnmanaged(Range) = undefined;
    for (&lists) |*l| l.* = .empty;
    defer for (&lists) |*l| l.deinit(allocator);

    var unicode_version: []const u8 = "unknown";

    var line_iter = std.mem.splitScalar(u8, data, '\n');
    while (line_iter.next()) |line_raw| {
        const line = std.mem.trimEnd(u8, line_raw, "\r");

        if (std.mem.startsWith(u8, line, "# DerivedGeneralCategory-") and std.mem.eql(u8, unicode_version, "unknown")) {
            const tail = line["# DerivedGeneralCategory-".len..];
            const dot = std.mem.indexOf(u8, tail, ".txt") orelse tail.len;
            unicode_version = tail[0..dot];
            continue;
        }
        if (line.len == 0 or line[0] == '#') continue;

        const semi = std.mem.indexOfScalar(u8, line, ';') orelse continue;
        const cps = std.mem.trim(u8, line[0..semi], " \t");
        var abbr_part = line[semi + 1 ..];
        if (std.mem.indexOfScalar(u8, abbr_part, '#')) |hash| abbr_part = abbr_part[0..hash];
        const abbr = std.mem.trim(u8, abbr_part, " \t");

        const idx = indexOfAbbr(abbr) orelse {
            std.debug.print("warning: unrecognised gc value '{s}'\n", .{abbr});
            continue;
        };
        const range = parseCodepointRange(cps) catch |err| {
            std.debug.print("warning: skipping malformed line '{s}': {t}\n", .{ line, err });
            continue;
        };
        try lists[idx].append(allocator, range);
    }

    // Atomic categories first, so grouped values can union finished ranges.
    for (categories, 0..) |c, i| {
        if (c.members.len == 0) sortAndMerge(&lists[i]);
    }
    for (categories, 0..) |c, i| {
        if (c.members.len == 0) continue;
        for (c.members) |m| {
            const mi = indexOfAbbr(m) orelse fatal("group '{s}' references unknown member '{s}'", .{ c.abbr, m });
            try lists[i].appendSlice(allocator, lists[mi].items);
        }
        sortAndMerge(&lists[i]);
    }

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);

    try buf.appendSlice(allocator,
        \\//! GENERATED FILE — DO NOT EDIT BY HAND.
        \\//!
        \\//! Produced by `zig build gen-unicode` from
        \\//! `vendor/unicode/DerivedGeneralCategory.txt`. Backs RegExp `\p{…}`
        \\//! General_Category escapes (ECMA-262 §22.2.1.1).
        \\//!
        \\
    );
    try buf.print(allocator, "//! Unicode version: {s}\n\n", .{unicode_version});
    try buf.appendSlice(allocator,
        \\pub const Range = struct {
        \\    start: u21,
        \\    end: u21,
        \\};
        \\
        \\
    );

    var total: usize = 0;
    for (categories, 0..) |c, i| {
        try emitRanges(allocator, &buf, c.abbr, lists[i].items);
        try buf.append(allocator, '\n');
        total += lists[i].items.len;
    }

    try buf.appendSlice(allocator,
        \\/// Resolve a General_Category value name to its sorted ranges, or null
        \\/// if `name` is not a value ECMA-262 §22.2.1.1 recognises. Exact,
        \\/// case-sensitive match (no loose UCD matching).
        \\pub fn generalCategory(name: []const u8) ?[]const Range {
        \\
    );
    for (categories) |c| {
        for (c.names) |n| {
            try buf.print(allocator, "    if (std.mem.eql(u8, name, \"{s}\")) return &gc_{s};\n", .{ n, c.abbr });
        }
    }
    try buf.appendSlice(allocator,
        \\    return null;
        \\}
        \\
        \\const std = @import("std");
        \\
    );

    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = out_path, .data = buf.items });
    std.debug.print("wrote {s}: {d} General_Category values, {d} total ranges (Unicode {s})\n", .{
        out_path, categories.len, total, unicode_version,
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
    abbr: []const u8,
    ranges: []const Range,
) !void {
    try buf.print(allocator, "pub const gc_{s} = [_]Range{{\n", .{abbr});
    for (ranges) |r| {
        try buf.print(allocator, "    .{{ .start = 0x{X:0>4}, .end = 0x{X:0>4} }},\n", .{ r.start, r.end });
    }
    try buf.appendSlice(allocator, "};\n");
}

fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("error: " ++ fmt ++ "\n", args);
    std.process.exit(1);
}
