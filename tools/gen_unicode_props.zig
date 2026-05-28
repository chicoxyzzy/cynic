//! Generate `src/unicode/property_tables.zig` from the vendored UCD files.
//! Backs RegExp `\p{…}` / `\P{…}` Unicode property escapes (ECMA-262
//! §22.2.1.1). Same model as `gen_unicode_idents.zig`: parse the UCD, emit
//! sorted code-point ranges into a committed Zig source file, binary-search
//! it at runtime. Run on demand when bumping the Unicode target:
//!
//!     zig build gen-unicode
//!
//! The *names* a property exposes (abbreviation, long name, aliases), the
//! membership of grouped General_Category values, and the set of binary
//! properties ECMA-262 recognises are all fixed by the spec, so they are
//! hardcoded here; only the code-point ranges are version data, parsed from
//! the UCD. Args: <out> <DerivedGeneralCategory> <DerivedCoreProperties>
//! <PropList> <emoji-data> <DerivedBinaryProperties> <DerivedNormalizationProps>.

const std = @import("std");

const Range = struct { start: u21, end: u21 };
const max_cp: u32 = 0x10FFFF;

// ── General_Category ────────────────────────────────────────────────

/// One General_Category value ECMA-262 §22.2.1.1 recognises. `members` is
/// empty for an atomic category; a non-empty `members` marks a grouped value
/// synthesised as the union of those atomic categories' ranges.
const Category = struct {
    abbr: []const u8,
    names: []const []const u8,
    members: []const []const u8 = &.{},
};

const categories = [_]Category{
    .{ .abbr = "Lu", .names = &.{ "Lu", "Uppercase_Letter" } },
    .{ .abbr = "Ll", .names = &.{ "Ll", "Lowercase_Letter" } },
    .{ .abbr = "Lt", .names = &.{ "Lt", "Titlecase_Letter" } },
    .{ .abbr = "Lm", .names = &.{ "Lm", "Modifier_Letter" } },
    .{ .abbr = "Lo", .names = &.{ "Lo", "Other_Letter" } },
    .{ .abbr = "Mn", .names = &.{ "Mn", "Nonspacing_Mark" } },
    .{ .abbr = "Mc", .names = &.{ "Mc", "Spacing_Mark" } },
    .{ .abbr = "Me", .names = &.{ "Me", "Enclosing_Mark" } },
    .{ .abbr = "Nd", .names = &.{ "Nd", "Decimal_Number", "digit" } },
    .{ .abbr = "Nl", .names = &.{ "Nl", "Letter_Number" } },
    .{ .abbr = "No", .names = &.{ "No", "Other_Number" } },
    .{ .abbr = "Pc", .names = &.{ "Pc", "Connector_Punctuation" } },
    .{ .abbr = "Pd", .names = &.{ "Pd", "Dash_Punctuation" } },
    .{ .abbr = "Ps", .names = &.{ "Ps", "Open_Punctuation" } },
    .{ .abbr = "Pe", .names = &.{ "Pe", "Close_Punctuation" } },
    .{ .abbr = "Pi", .names = &.{ "Pi", "Initial_Punctuation" } },
    .{ .abbr = "Pf", .names = &.{ "Pf", "Final_Punctuation" } },
    .{ .abbr = "Po", .names = &.{ "Po", "Other_Punctuation" } },
    .{ .abbr = "Sm", .names = &.{ "Sm", "Math_Symbol" } },
    .{ .abbr = "Sc", .names = &.{ "Sc", "Currency_Symbol" } },
    .{ .abbr = "Sk", .names = &.{ "Sk", "Modifier_Symbol" } },
    .{ .abbr = "So", .names = &.{ "So", "Other_Symbol" } },
    .{ .abbr = "Zs", .names = &.{ "Zs", "Space_Separator" } },
    .{ .abbr = "Zl", .names = &.{ "Zl", "Line_Separator" } },
    .{ .abbr = "Zp", .names = &.{ "Zp", "Paragraph_Separator" } },
    .{ .abbr = "Cc", .names = &.{ "Cc", "Control", "cntrl" } },
    .{ .abbr = "Cf", .names = &.{ "Cf", "Format" } },
    .{ .abbr = "Cs", .names = &.{ "Cs", "Surrogate" } },
    .{ .abbr = "Co", .names = &.{ "Co", "Private_Use" } },
    .{ .abbr = "Cn", .names = &.{ "Cn", "Unassigned" } },
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
    for (categories, 0..) |c, i| if (std.mem.eql(u8, c.abbr, abbr)) return i;
    return null;
}

// ── Binary properties ───────────────────────────────────────────────

/// How a binary property's ranges are produced when not read from a file.
const Synth = enum { none, ascii, any, assigned };

/// One binary Unicode property ECMA-262 §22.2.1.1 recognises. `ucd` is the
/// property's name in the UCD files (empty when synthesised); `names` is
/// every spelling ECMA-262 accepts (canonical long name + aliases).
const BinProp = struct {
    ucd: []const u8,
    names: []const []const u8,
    synth: Synth = .none,
};

const bin_props = [_]BinProp{
    .{ .ucd = "", .names = &.{"ASCII"}, .synth = .ascii },
    .{ .ucd = "ASCII_Hex_Digit", .names = &.{ "ASCII_Hex_Digit", "AHex" } },
    .{ .ucd = "Alphabetic", .names = &.{ "Alphabetic", "Alpha" } },
    .{ .ucd = "", .names = &.{"Any"}, .synth = .any },
    .{ .ucd = "", .names = &.{"Assigned"}, .synth = .assigned },
    .{ .ucd = "Bidi_Control", .names = &.{ "Bidi_Control", "Bidi_C" } },
    .{ .ucd = "Bidi_Mirrored", .names = &.{ "Bidi_Mirrored", "Bidi_M" } },
    .{ .ucd = "Case_Ignorable", .names = &.{ "Case_Ignorable", "CI" } },
    .{ .ucd = "Cased", .names = &.{"Cased"} },
    .{ .ucd = "Changes_When_Casefolded", .names = &.{ "Changes_When_Casefolded", "CWCF" } },
    .{ .ucd = "Changes_When_Casemapped", .names = &.{ "Changes_When_Casemapped", "CWCM" } },
    .{ .ucd = "Changes_When_Lowercased", .names = &.{ "Changes_When_Lowercased", "CWL" } },
    .{ .ucd = "Changes_When_NFKC_Casefolded", .names = &.{ "Changes_When_NFKC_Casefolded", "CWKCF" } },
    .{ .ucd = "Changes_When_Titlecased", .names = &.{ "Changes_When_Titlecased", "CWT" } },
    .{ .ucd = "Changes_When_Uppercased", .names = &.{ "Changes_When_Uppercased", "CWU" } },
    .{ .ucd = "Dash", .names = &.{"Dash"} },
    .{ .ucd = "Default_Ignorable_Code_Point", .names = &.{ "Default_Ignorable_Code_Point", "DI" } },
    .{ .ucd = "Deprecated", .names = &.{ "Deprecated", "Dep" } },
    .{ .ucd = "Diacritic", .names = &.{ "Diacritic", "Dia" } },
    .{ .ucd = "Emoji", .names = &.{"Emoji"} },
    .{ .ucd = "Emoji_Component", .names = &.{ "Emoji_Component", "EComp" } },
    .{ .ucd = "Emoji_Modifier", .names = &.{ "Emoji_Modifier", "EMod" } },
    .{ .ucd = "Emoji_Modifier_Base", .names = &.{ "Emoji_Modifier_Base", "EBase" } },
    .{ .ucd = "Emoji_Presentation", .names = &.{ "Emoji_Presentation", "EPres" } },
    .{ .ucd = "Extended_Pictographic", .names = &.{ "Extended_Pictographic", "ExtPict" } },
    .{ .ucd = "Extender", .names = &.{ "Extender", "Ext" } },
    .{ .ucd = "Grapheme_Base", .names = &.{ "Grapheme_Base", "Gr_Base" } },
    .{ .ucd = "Grapheme_Extend", .names = &.{ "Grapheme_Extend", "Gr_Ext" } },
    .{ .ucd = "Hex_Digit", .names = &.{ "Hex_Digit", "Hex" } },
    .{ .ucd = "IDS_Binary_Operator", .names = &.{ "IDS_Binary_Operator", "IDSB" } },
    .{ .ucd = "IDS_Trinary_Operator", .names = &.{ "IDS_Trinary_Operator", "IDST" } },
    .{ .ucd = "ID_Continue", .names = &.{ "ID_Continue", "IDC" } },
    .{ .ucd = "ID_Start", .names = &.{ "ID_Start", "IDS" } },
    .{ .ucd = "Ideographic", .names = &.{ "Ideographic", "Ideo" } },
    .{ .ucd = "Join_Control", .names = &.{ "Join_Control", "Join_C" } },
    .{ .ucd = "Logical_Order_Exception", .names = &.{ "Logical_Order_Exception", "LOE" } },
    .{ .ucd = "Lowercase", .names = &.{ "Lowercase", "Lower" } },
    .{ .ucd = "Math", .names = &.{"Math"} },
    .{ .ucd = "Noncharacter_Code_Point", .names = &.{ "Noncharacter_Code_Point", "NChar" } },
    .{ .ucd = "Pattern_Syntax", .names = &.{ "Pattern_Syntax", "Pat_Syn" } },
    .{ .ucd = "Pattern_White_Space", .names = &.{ "Pattern_White_Space", "Pat_WS" } },
    .{ .ucd = "Quotation_Mark", .names = &.{ "Quotation_Mark", "QMark" } },
    .{ .ucd = "Radical", .names = &.{"Radical"} },
    .{ .ucd = "Regional_Indicator", .names = &.{ "Regional_Indicator", "RI" } },
    .{ .ucd = "Sentence_Terminal", .names = &.{ "Sentence_Terminal", "STerm" } },
    .{ .ucd = "Soft_Dotted", .names = &.{ "Soft_Dotted", "SD" } },
    .{ .ucd = "Terminal_Punctuation", .names = &.{ "Terminal_Punctuation", "Term" } },
    .{ .ucd = "Unified_Ideograph", .names = &.{ "Unified_Ideograph", "UIdeo" } },
    .{ .ucd = "Uppercase", .names = &.{ "Uppercase", "Upper" } },
    .{ .ucd = "Variation_Selector", .names = &.{ "Variation_Selector", "VS" } },
    .{ .ucd = "White_Space", .names = &.{ "White_Space", "space", "WSpace" } },
    .{ .ucd = "XID_Continue", .names = &.{ "XID_Continue", "XIDC" } },
    .{ .ucd = "XID_Start", .names = &.{ "XID_Start", "XIDS" } },
};

fn indexOfUcd(name: []const u8) ?usize {
    if (name.len == 0) return null;
    for (bin_props, 0..) |p, i| if (p.synth == .none and std.mem.eql(u8, p.ucd, name)) return i;
    return null;
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    var args_iter = init.minimal.args.iterate();
    _ = args_iter.next();
    const out_path = nextArg(&args_iter);
    const gc_path = nextArg(&args_iter);
    const dcp_path = nextArg(&args_iter);
    const proplist_path = nextArg(&args_iter);
    const emoji_path = nextArg(&args_iter);
    const dbp_path = nextArg(&args_iter);
    const dnp_path = nextArg(&args_iter);
    const pva_path = nextArg(&args_iter);
    const scripts_path = nextArg(&args_iter);
    const scx_path = nextArg(&args_iter);

    // ── General_Category ──
    const gc_data = try std.Io.Dir.cwd().readFileAlloc(io, gc_path, allocator, .unlimited);
    defer allocator.free(gc_data);

    var gc_lists: [categories.len]std.ArrayListUnmanaged(Range) = undefined;
    for (&gc_lists) |*l| l.* = .empty;
    defer for (&gc_lists) |*l| l.deinit(allocator);

    var unicode_version: []const u8 = "unknown";
    {
        var it = std.mem.splitScalar(u8, gc_data, '\n');
        while (it.next()) |line_raw| {
            const line = std.mem.trimEnd(u8, line_raw, "\r");
            if (std.mem.startsWith(u8, line, "# DerivedGeneralCategory-") and std.mem.eql(u8, unicode_version, "unknown")) {
                const tail = line["# DerivedGeneralCategory-".len..];
                const dot = std.mem.indexOf(u8, tail, ".txt") orelse tail.len;
                unicode_version = tail[0..dot];
                continue;
            }
            const pl = parsePropLine(line) orelse continue;
            const idx = indexOfAbbr(pl.name) orelse continue;
            const range = parseCodepointRange(pl.cps) catch continue;
            try gc_lists[idx].append(allocator, range);
        }
    }
    for (categories, 0..) |c, i| if (c.members.len == 0) sortAndMerge(&gc_lists[i]);
    for (categories, 0..) |c, i| {
        if (c.members.len == 0) continue;
        for (c.members) |m| {
            const mi = indexOfAbbr(m) orelse fatal("group '{s}' references unknown member '{s}'", .{ c.abbr, m });
            try gc_lists[i].appendSlice(allocator, gc_lists[mi].items);
        }
        sortAndMerge(&gc_lists[i]);
    }

    // ── Binary properties ──
    var bin_lists: [bin_props.len]std.ArrayListUnmanaged(Range) = undefined;
    for (&bin_lists) |*l| l.* = .empty;
    defer for (&bin_lists) |*l| l.deinit(allocator);

    for ([_][]const u8{ dcp_path, proplist_path, emoji_path, dbp_path, dnp_path }) |path| {
        const data = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .unlimited);
        defer allocator.free(data);
        var it = std.mem.splitScalar(u8, data, '\n');
        while (it.next()) |line_raw| {
            const line = std.mem.trimEnd(u8, line_raw, "\r");
            const pl = parsePropLine(line) orelse continue;
            const idx = indexOfUcd(pl.name) orelse continue;
            const range = parseCodepointRange(pl.cps) catch continue;
            try bin_lists[idx].append(allocator, range);
        }
    }
    for (&bin_lists) |*l| sortAndMerge(l);

    // Synthesised properties: ASCII, Any, and Assigned (= ¬Cn).
    for (bin_props, 0..) |p, i| switch (p.synth) {
        .none => {},
        .ascii => try bin_lists[i].append(allocator, .{ .start = 0x00, .end = 0x7F }),
        .any => try bin_lists[i].append(allocator, .{ .start = 0x00, .end = @intCast(max_cp) }),
        .assigned => {
            const cn = gc_lists[indexOfAbbr("Cn").?].items;
            try complementInto(allocator, &bin_lists[i], cn);
        },
    };

    // ── Scripts & Script_Extensions ──
    // The script name taxonomy is data-driven from PropertyValueAliases `sc`
    // rows (short code, long name, aliases) — too many to hardcode. Tables
    // key off the short code. Scripts.txt uses long names; ScriptExtensions
    // uses short codes; both resolve through the one alias map.
    const pva = try std.Io.Dir.cwd().readFileAlloc(io, pva_path, allocator, .unlimited);
    defer allocator.free(pva);

    var script_codes: std.ArrayListUnmanaged([]const u8) = .empty; // canonical short code per index
    defer script_codes.deinit(allocator);
    var script_names: std.ArrayListUnmanaged([]const []const u8) = .empty; // every spelling per index
    defer {
        for (script_names.items) |ns| allocator.free(ns);
        script_names.deinit(allocator);
    }
    var name2idx: std.StringHashMapUnmanaged(usize) = .empty;
    defer name2idx.deinit(allocator);
    {
        var it = std.mem.splitScalar(u8, pva, '\n');
        while (it.next()) |line_raw| {
            const line = std.mem.trimEnd(u8, line_raw, "\r");
            if (!std.mem.startsWith(u8, line, "sc ;")) continue;
            var body = line["sc ;".len..];
            if (std.mem.indexOfScalar(u8, body, '#')) |h| body = body[0..h];
            const idx = script_codes.items.len;
            var names: std.ArrayListUnmanaged([]const u8) = .empty;
            var fit = std.mem.splitScalar(u8, body, ';');
            while (fit.next()) |f| {
                const name = std.mem.trim(u8, f, " \t");
                if (name.len == 0) continue;
                try names.append(allocator, name);
                try name2idx.put(allocator, name, idx);
            }
            if (names.items.len == 0) continue;
            try script_codes.append(allocator, names.items[0]);
            try script_names.append(allocator, try names.toOwnedSlice(allocator));
        }
    }
    const nscript = script_codes.items.len;

    const script_lists = try allocator.alloc(std.ArrayListUnmanaged(Range), nscript);
    defer allocator.free(script_lists);
    for (script_lists) |*l| l.* = .empty;
    defer for (script_lists) |*l| l.deinit(allocator);
    const scx_lists = try allocator.alloc(std.ArrayListUnmanaged(Range), nscript);
    defer allocator.free(scx_lists);
    for (scx_lists) |*l| l.* = .empty;
    defer for (scx_lists) |*l| l.deinit(allocator);

    // Scripts.txt → base Script value (long names).
    {
        const data = try std.Io.Dir.cwd().readFileAlloc(io, scripts_path, allocator, .unlimited);
        defer allocator.free(data);
        var it = std.mem.splitScalar(u8, data, '\n');
        while (it.next()) |line_raw| {
            const line = std.mem.trimEnd(u8, line_raw, "\r");
            const pl = parsePropLine(line) orelse continue;
            const idx = name2idx.get(pl.name) orelse continue;
            const range = parseCodepointRange(pl.cps) catch continue;
            try script_lists[idx].append(allocator, range);
        }
    }
    for (script_lists) |*l| sortAndMerge(l);
    // Scripts.txt @missing default is Unknown (Zzzz): the complement of all
    // assigned-script ranges.
    {
        var all: std.ArrayListUnmanaged(Range) = .empty;
        defer all.deinit(allocator);
        for (script_lists) |l| try all.appendSlice(allocator, l.items);
        sortAndMerge(&all);
        const uk = name2idx.get("Unknown") orelse fatal("no Unknown script in PropertyValueAliases", .{});
        script_lists[uk].clearRetainingCapacity();
        try complementInto(allocator, &script_lists[uk], all.items);
    }

    // ScriptExtensions.txt → explicit scx sets (short codes). `escx` is the
    // explicitly-listed domain; cps outside it default to their Script value.
    var escx: std.ArrayListUnmanaged(Range) = .empty;
    defer escx.deinit(allocator);
    {
        const data = try std.Io.Dir.cwd().readFileAlloc(io, scx_path, allocator, .unlimited);
        defer allocator.free(data);
        var it = std.mem.splitScalar(u8, data, '\n');
        while (it.next()) |line_raw| {
            const line = std.mem.trimEnd(u8, line_raw, "\r");
            const pl = parsePropLine(line) orelse continue;
            const range = parseCodepointRange(pl.cps) catch continue;
            try escx.append(allocator, range);
            var cit = std.mem.tokenizeScalar(u8, pl.name, ' ');
            while (cit.next()) |code| {
                const idx = name2idx.get(code) orelse continue;
                try scx_lists[idx].append(allocator, range);
            }
        }
    }
    sortAndMerge(&escx);
    // scx(S) = explicit(S) ∪ (Script(S) \ E): §22.2.1.1 with the default rule.
    for (0..nscript) |i| {
        sortAndMerge(&scx_lists[i]);
        var defaulted: std.ArrayListUnmanaged(Range) = .empty;
        defer defaulted.deinit(allocator);
        try subtractInto(allocator, &defaulted, script_lists[i].items, escx.items);
        try scx_lists[i].appendSlice(allocator, defaulted.items);
        sortAndMerge(&scx_lists[i]);
    }

    // ── Emit ──
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);

    try buf.appendSlice(allocator,
        \\//! GENERATED FILE — DO NOT EDIT BY HAND.
        \\//!
        \\//! Produced by `zig build gen-unicode` from the vendored UCD files.
        \\//! Backs RegExp `\p{…}` Unicode property escapes (ECMA-262 §22.2.1.1):
        \\//! General_Category values and the binary properties.
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

    var gc_total: usize = 0;
    for (categories, 0..) |c, i| {
        try emitRanges(allocator, &buf, "gc_", c.abbr, gc_lists[i].items);
        try buf.append(allocator, '\n');
        gc_total += gc_lists[i].items.len;
    }
    var bp_total: usize = 0;
    for (bin_props, 0..) |p, i| {
        try emitRanges(allocator, &buf, "bp_", p.names[0], bin_lists[i].items);
        try buf.append(allocator, '\n');
        bp_total += bin_lists[i].items.len;
    }
    var sc_total: usize = 0;
    for (0..nscript) |i| {
        try emitRanges(allocator, &buf, "script_", script_codes.items[i], script_lists[i].items);
        try buf.append(allocator, '\n');
        try emitRanges(allocator, &buf, "scx_", script_codes.items[i], scx_lists[i].items);
        try buf.append(allocator, '\n');
        sc_total += script_lists[i].items.len + scx_lists[i].items.len;
    }

    try buf.appendSlice(allocator,
        \\/// Resolve a General_Category value name to its sorted ranges, or null
        \\/// if `name` is not a value ECMA-262 §22.2.1.1 recognises. Exact,
        \\/// case-sensitive match (no loose UCD matching).
        \\pub fn generalCategory(name: []const u8) ?[]const Range {
        \\
    );
    for (categories) |c| for (c.names) |n|
        try buf.print(allocator, "    if (std.mem.eql(u8, name, \"{s}\")) return &gc_{s};\n", .{ n, c.abbr });
    try buf.appendSlice(allocator,
        \\    return null;
        \\}
        \\
        \\/// Resolve a binary Unicode property name to its sorted ranges, or null
        \\/// if `name` is not a binary property ECMA-262 §22.2.1.1 recognises.
        \\pub fn binaryProperty(name: []const u8) ?[]const Range {
        \\
    );
    for (bin_props) |p| for (p.names) |n|
        try buf.print(allocator, "    if (std.mem.eql(u8, name, \"{s}\")) return &bp_{s};\n", .{ n, p.names[0] });
    try buf.appendSlice(allocator,
        \\    return null;
        \\}
        \\
        \\/// Resolve a Script value (long name, short code, or alias) to its
        \\/// sorted ranges, or null if not a script ECMA-262 §22.2.1.1 lists.
        \\pub fn script(name: []const u8) ?[]const Range {
        \\
    );
    for (0..nscript) |i| for (script_names.items[i]) |n|
        try buf.print(allocator, "    if (std.mem.eql(u8, name, \"{s}\")) return &script_{s};\n", .{ n, script_codes.items[i] });
    try buf.appendSlice(allocator,
        \\    return null;
        \\}
        \\
        \\/// Resolve a Script_Extensions value to its sorted ranges, or null if
        \\/// not a script ECMA-262 §22.2.1.1 lists.
        \\pub fn scriptExtensions(name: []const u8) ?[]const Range {
        \\
    );
    for (0..nscript) |i| for (script_names.items[i]) |n|
        try buf.print(allocator, "    if (std.mem.eql(u8, name, \"{s}\")) return &scx_{s};\n", .{ n, script_codes.items[i] });
    try buf.appendSlice(allocator,
        \\    return null;
        \\}
        \\
        \\const std = @import("std");
        \\
    );

    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = out_path, .data = buf.items });
    std.debug.print("wrote {s}: {d} gc ({d} ranges), {d} binary ({d} ranges), {d} scripts ({d} ranges) (Unicode {s})\n", .{
        out_path, categories.len, gc_total, bin_props.len, bp_total, nscript, sc_total, unicode_version,
    });
}

fn nextArg(it: anytype) []const u8 {
    return it.next() orelse fatal("usage: gen_unicode_props <out> <DerivedGeneralCategory> <DerivedCoreProperties> <PropList> <emoji-data> <DerivedBinaryProperties> <DerivedNormalizationProps>", .{});
}

const PropLine = struct { cps: []const u8, name: []const u8 };

/// Parse a UCD data line `cps ; PropName [; value] # comment` into its
/// code-point field and property name, or null for blank/comment lines.
fn parsePropLine(line: []const u8) ?PropLine {
    if (line.len == 0 or line[0] == '#') return null;
    const semi = std.mem.indexOfScalar(u8, line, ';') orelse return null;
    const cps = std.mem.trim(u8, line[0..semi], " \t");
    var rest = line[semi + 1 ..];
    if (std.mem.indexOfScalar(u8, rest, '#')) |h| rest = rest[0..h];
    if (std.mem.indexOfScalar(u8, rest, ';')) |s| rest = rest[0..s]; // drop value field
    return .{ .cps = cps, .name = std.mem.trim(u8, rest, " \t") };
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

/// Append the complement of `ranges` (sorted, merged) over [0, max_cp].
fn complementInto(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(Range), ranges: []const Range) !void {
    var next: u32 = 0;
    for (ranges) |r| {
        if (r.start > next) try out.append(allocator, .{ .start = @intCast(next), .end = @intCast(r.start - 1) });
        next = @as(u32, r.end) + 1;
    }
    if (next <= max_cp) try out.append(allocator, .{ .start = @intCast(next), .end = @intCast(max_cp) });
}

/// Append `ranges \ exclude` (set difference). Both inputs sorted, merged.
fn subtractInto(
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(Range),
    ranges: []const Range,
    exclude: []const Range,
) !void {
    for (ranges) |r| {
        var lo: u32 = r.start;
        const hi: u32 = r.end;
        for (exclude) |e| {
            if (@as(u32, e.end) < lo) continue;
            if (@as(u32, e.start) > hi) break;
            if (e.start > lo) try out.append(allocator, .{ .start = @intCast(lo), .end = @intCast(@as(u32, e.start) - 1) });
            if (@as(u32, e.end) >= hi) {
                lo = hi + 1;
                break;
            }
            lo = @as(u32, e.end) + 1;
        }
        if (lo <= hi) try out.append(allocator, .{ .start = @intCast(lo), .end = @intCast(hi) });
    }
}

fn emitRanges(
    allocator: std.mem.Allocator,
    buf: *std.ArrayListUnmanaged(u8),
    prefix: []const u8,
    name: []const u8,
    ranges: []const Range,
) !void {
    try buf.print(allocator, "pub const {s}{s} = [_]Range{{\n", .{ prefix, name });
    for (ranges) |r| {
        try buf.print(allocator, "    .{{ .start = 0x{X:0>4}, .end = 0x{X:0>4} }},\n", .{ r.start, r.end });
    }
    try buf.appendSlice(allocator, "};\n");
}

fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("error: " ++ fmt ++ "\n", args);
    std.process.exit(1);
}
