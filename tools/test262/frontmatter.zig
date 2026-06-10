//! YAML-subset parser for test262's `/*--- … ---*/` frontmatter block.
//!
//! Cynic only consumes the keys it actually classifies on:
//! • `flags` — flow-list `[a, b]` or block-list ` - item`
//! • `features` — same shape as `flags`
//! • `negative` — block-map: indented `phase:` and `type:`
//! • `includes` — same shape as `flags`; presence is the signal
//!
//! Multiline scalars (`info: |`, `description: >`) are deliberately
//! skipped: the parser tracks indentation and ignores any indented
//! content under unrecognised top-level keys. Quoting, anchors, and
//! mid-block comments are not supported (test262 frontmatter doesn't
//! use them in the keys we read). Malformed input is degraded to
//! `error.MalformedFrontmatter` and the caller skips the test.

const std = @import("std");

pub const Phase = enum { parse, early, resolution, runtime };

pub const Negative = struct {
    phase: Phase,
    type_name: []const u8, // e.g. "SyntaxError"
};

pub const Flags = packed struct {
    only_strict: bool = false,
    no_strict: bool = false,
    module: bool = false,
    raw: bool = false,
    async_flag: bool = false,
    generated: bool = false,
    /// `CanBlockIsFalse` — the fixture requires an agent that cannot
    /// block (Atomics.wait must throw). Used only to classify a
    /// failure as a policy fail in the results breakdown.
    can_block_is_false: bool = false,
};

pub const Frontmatter = struct {
    flags: Flags = .{},
    features: [][]const u8 = &.{},
    /// Names of harness files this test depends on (e.g.
    /// `compareArray.js`, `testTypedArray.js`). Each name is
    /// resolved by the runner against `harness/<name>` and
    /// evaluated as its own Script before the test source. An
    /// empty slice means no includes.
    includes: [][]const u8 = &.{},
    negative: ?Negative = null,
};

pub const Error = error{
    /// No `/*---` block found. The caller treats this as a missing
    /// frontmatter (skip with reason `no_frontmatter`).
    NoFrontmatter,
    /// `/*---` opened but no closing `---*/` — corrupt fixture.
    UnterminatedFrontmatter,
    OutOfMemory,
};

/// Parse the frontmatter from `source`. Slices in the returned
/// `Frontmatter` borrow from `source` for unrecognised feature names;
/// the `features` array itself is allocated from `arena`.
pub fn parse(arena: std.mem.Allocator, source: []const u8) Error!Frontmatter {
    var bytes = source;
    // Optional UTF-8 BOM.
    if (bytes.len >= 3 and std.mem.eql(u8, bytes[0..3], "\xEF\xBB\xBF")) {
        bytes = bytes[3..];
    }

    const open_idx = std.mem.indexOf(u8, bytes, "/*---") orelse return error.NoFrontmatter;
    const after_open = bytes[open_idx + "/*---".len ..];
    const close_offset = std.mem.indexOf(u8, after_open, "---*/") orelse return error.UnterminatedFrontmatter;
    const block = after_open[0..close_offset];

    var fm: Frontmatter = .{};
    var features: std.ArrayListUnmanaged([]const u8) = .empty;
    var includes: std.ArrayListUnmanaged([]const u8) = .empty;

    // Per ECMA-262 §11.3 LineTerminator (and YAML's own line-folding
    // rules), CR / CRLF / LF are all valid line separators. The CR-only
    // `built-ins/Function/prototype/toString/line-terminator-normalisation-CR.js`
    // fixture embeds U+000D throughout including in its `/*---…---*/`
    // block, and a LF-only splitter collapses the whole frontmatter
    // into a single "line" with embedded CRs — `includes:` never
    // registers, the harness skips the include load, and the test
    // throws ReferenceError at runtime. `tokenizeAny` treats any run
    // of `\r` / `\n` (mixed or homogeneous, CRLF included) as a single
    // delimiter and skips empty tokens — matching how the parser
    // already short-circuits on empty / whitespace-only lines, so the
    // change is semantically transparent for LF-only fixtures.
    var line_iter = std.mem.tokenizeAny(u8, block, "\r\n");

    // The "scope" tracks what indented lines below the most recent
    // top-level key contribute to. `none` discards them (e.g. lines
    // under `description:` / `info:` / unrecognised keys).
    var scope: enum { none, flags, features_, includes, negative } = .none;

    while (line_iter.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        // Empty / whitespace-only lines reset nothing — keep current scope.
        if (line.len == 0 or isAllSpaces(line)) continue;

        const indent = leadingSpaces(line);
        const content = line[indent..];

        if (indent == 0) {
            // New top-level key. Reset scope.
            scope = .none;
            const colon = std.mem.indexOfScalar(u8, content, ':') orelse continue;
            const key = std.mem.trim(u8, content[0..colon], " \t");
            const value = std.mem.trim(u8, content[colon + 1 ..], " \t");

            if (std.mem.eql(u8, key, "flags")) {
                if (value.len == 0) {
                    scope = .flags;
                } else if (parseFlowList(value)) |items_str| {
                    var iter = splitFlowList(items_str);
                    while (iter.next()) |item| applyFlag(&fm.flags, item);
                }
            } else if (std.mem.eql(u8, key, "features")) {
                if (value.len == 0) {
                    scope = .features_;
                } else if (parseFlowList(value)) |items_str| {
                    var iter = splitFlowList(items_str);
                    while (iter.next()) |item| {
                        try features.append(arena, item);
                    }
                }
            } else if (std.mem.eql(u8, key, "includes")) {
                if (value.len == 0) {
                    scope = .includes;
                } else if (parseFlowList(value)) |items_str| {
                    var iter = splitFlowList(items_str);
                    while (iter.next()) |item| try includes.append(arena, item);
                }
            } else if (std.mem.eql(u8, key, "negative")) {
                scope = .negative;
                fm.negative = .{ .phase = .parse, .type_name = "" };
            }
            // Other keys (`description`, `info`, `esid`, etc.) — scope
            // stays `.none`, indented multiline content is skipped.
        } else {
            // Indented continuation line.
            switch (scope) {
                .flags => if (parseBlockListItem(content)) |item| applyFlag(&fm.flags, item),
                .features_ => if (parseBlockListItem(content)) |item| {
                    try features.append(arena, item);
                },
                .includes => if (parseBlockListItem(content)) |item| {
                    try includes.append(arena, item);
                },
                .negative => {
                    const colon = std.mem.indexOfScalar(u8, content, ':') orelse continue;
                    const key = std.mem.trim(u8, content[0..colon], " \t");
                    const value = std.mem.trim(u8, content[colon + 1 ..], " \t");
                    if (std.mem.eql(u8, key, "phase")) {
                        if (fm.negative) |*n| n.phase = parsePhase(value);
                    } else if (std.mem.eql(u8, key, "type")) {
                        if (fm.negative) |*n| n.type_name = value;
                    }
                },
                .none => {},
            }
        }
    }

    fm.features = try features.toOwnedSlice(arena);
    fm.includes = try includes.toOwnedSlice(arena);
    return fm;
}

fn isAllSpaces(s: []const u8) bool {
    for (s) |c| if (c != ' ' and c != '\t') return false;
    return true;
}

fn leadingSpaces(s: []const u8) usize {
    var i: usize = 0;
    while (i < s.len and (s[i] == ' ' or s[i] == '\t')) : (i += 1) {}
    return i;
}

/// `[a, b, c]` → returns the slice between brackets, or null if `s`
/// is not a flow-list. Trailing comma allowed.
fn parseFlowList(s: []const u8) ?[]const u8 {
    if (s.len < 2 or s[0] != '[' or s[s.len - 1] != ']') return null;
    return s[1 .. s.len - 1];
}

const FlowIter = struct {
    rest: []const u8,
    fn next(self: *FlowIter) ?[]const u8 {
        while (self.rest.len > 0) {
            const comma = std.mem.indexOfScalar(u8, self.rest, ',');
            const item_raw = if (comma) |c| self.rest[0..c] else self.rest;
            self.rest = if (comma) |c| self.rest[c + 1 ..] else "";
            const item = std.mem.trim(u8, item_raw, " \t");
            if (item.len == 0) continue;
            return item;
        }
        return null;
    }
};

fn splitFlowList(items: []const u8) FlowIter {
    return .{ .rest = items };
}

fn firstFlowItem(items: []const u8) ?[]const u8 {
    var iter = splitFlowList(items);
    return iter.next();
}

/// Block list line ` - item` (after indent already stripped).
fn parseBlockListItem(content: []const u8) ?[]const u8 {
    if (content.len < 2 or content[0] != '-' or content[1] != ' ') return null;
    return std.mem.trim(u8, content[2..], " \t");
}

fn applyFlag(flags: *Flags, name: []const u8) void {
    if (std.mem.eql(u8, name, "onlyStrict")) flags.only_strict = true;
    if (std.mem.eql(u8, name, "noStrict")) flags.no_strict = true;
    if (std.mem.eql(u8, name, "CanBlockIsFalse")) flags.can_block_is_false = true;
    if (std.mem.eql(u8, name, "module")) flags.module = true;
    if (std.mem.eql(u8, name, "raw")) flags.raw = true;
    if (std.mem.eql(u8, name, "async")) flags.async_flag = true;
    if (std.mem.eql(u8, name, "generated")) flags.generated = true;
}

fn parsePhase(s: []const u8) Phase {
    if (std.mem.eql(u8, s, "parse")) return .parse;
    if (std.mem.eql(u8, s, "early")) return .early;
    if (std.mem.eql(u8, s, "resolution")) return .resolution;
    if (std.mem.eql(u8, s, "runtime")) return .runtime;
    return .parse;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn parseStr(arena: std.mem.Allocator, s: []const u8) !Frontmatter {
    return parse(arena, s);
}

test "frontmatter: missing block returns NoFrontmatter" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(error.NoFrontmatter, parse(arena.allocator(), "let x = 1;"));
}

test "frontmatter: empty block parses to defaults" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const fm = try parseStr(arena.allocator(), "/*---\n---*/");
    try testing.expect(!fm.flags.only_strict);
    try testing.expect(!fm.flags.no_strict);
    try testing.expect(!fm.flags.module);
    try testing.expectEqual(@as(usize, 0), fm.features.len);
    try testing.expect(fm.includes.len == 0);
    try testing.expectEqual(@as(?Negative, null), fm.negative);
}

test "frontmatter: flow-list flags" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const fm = try parseStr(arena.allocator(),
        \\/*---
        \\flags: [onlyStrict, module]
        \\---*/
    );
    try testing.expect(fm.flags.only_strict);
    try testing.expect(fm.flags.module);
    try testing.expect(!fm.flags.no_strict);
}

test "frontmatter: block-list features" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const fm = try parseStr(arena.allocator(),
        \\/*---
        \\features:
        \\  - Symbol
        \\  - Symbol.iterator
        \\---*/
    );
    try testing.expectEqual(@as(usize, 2), fm.features.len);
    try testing.expectEqualStrings("Symbol", fm.features[0]);
    try testing.expectEqualStrings("Symbol.iterator", fm.features[1]);
}

test "frontmatter: flow-list features" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const fm = try parseStr(arena.allocator(),
        \\/*---
        \\features: [class, generators, async-functions]
        \\---*/
    );
    try testing.expectEqual(@as(usize, 3), fm.features.len);
    try testing.expectEqualStrings("class", fm.features[0]);
    try testing.expectEqualStrings("async-functions", fm.features[2]);
}

test "frontmatter: negative block" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const fm = try parseStr(arena.allocator(),
        \\/*---
        \\esid: prod-OptionalExpression
        \\negative:
        \\  phase: parse
        \\  type: SyntaxError
        \\---*/
    );
    try testing.expect(fm.negative != null);
    try testing.expectEqual(Phase.parse, fm.negative.?.phase);
    try testing.expectEqualStrings("SyntaxError", fm.negative.?.type_name);
}

test "frontmatter: negative early phase" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const fm = try parseStr(arena.allocator(),
        \\/*---
        \\negative:
        \\  phase: early
        \\  type: SyntaxError
        \\---*/
    );
    try testing.expectEqual(Phase.early, fm.negative.?.phase);
}

test "frontmatter: includes presence" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const fm = try parseStr(arena.allocator(),
        \\/*---
        \\includes: [tcoHelper.js, propertyHelper.js]
        \\---*/
    );
    try testing.expect(fm.includes.len > 0);
}

test "frontmatter: includes block-list" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const fm = try parseStr(arena.allocator(),
        \\/*---
        \\includes:
        \\  - tcoHelper.js
        \\---*/
    );
    try testing.expect(fm.includes.len > 0);
}

test "frontmatter: multiline info: | does not leak into features" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    // The `- bullet` lines under `info: |` are multiline-scalar content
    // and must NOT be picked up as feature items.
    const fm = try parseStr(arena.allocator(),
        \\/*---
        \\esid: sec-foo
        \\info: |
        \\  Some Spec Section
        \\
        \\  - bullet one
        \\  - bullet two
        \\features: [class]
        \\---*/
    );
    try testing.expectEqual(@as(usize, 1), fm.features.len);
    try testing.expectEqualStrings("class", fm.features[0]);
}

test "frontmatter: description with > folded scalar is ignored" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const fm = try parseStr(arena.allocator(),
        \\/*---
        \\description: >
        \\  This is a multi-line
        \\  folded description.
        \\flags: [module]
        \\---*/
    );
    try testing.expect(fm.flags.module);
}

test "frontmatter: real-world test262 sample (early-error)" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const fm = try parseStr(arena.allocator(),
        \\/*---
        \\esid: prod-OptionalExpression
        \\description: >
        \\  template string passed to tail position of optional chain
        \\info: |
        \\  Static Semantics: Early Errors
        \\    OptionalChain:
        \\      ?.TemplateLiteral
        \\
        \\  It is a Syntax Error if any code matches this production.
        \\features: [optional-chaining]
        \\negative:
        \\  phase: parse
        \\  type: SyntaxError
        \\---*/
    );
    try testing.expectEqual(@as(usize, 1), fm.features.len);
    try testing.expectEqualStrings("optional-chaining", fm.features[0]);
    try testing.expect(fm.negative != null);
    try testing.expectEqual(Phase.parse, fm.negative.?.phase);
    try testing.expectEqualStrings("SyntaxError", fm.negative.?.type_name);
}

test "frontmatter: unterminated returns error" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(error.UnterminatedFrontmatter, parse(arena.allocator(),
        \\/*---
        \\flags: [module]
        \\
    ));
}

test "frontmatter: CR-only line terminators (built-ins/Function/prototype/toString/line-terminator-normalisation-CR.js)" {
    // The CR-only fixture under `built-ins/Function/prototype/toString/`
    // embeds CR (U+000D) as its sole line terminator throughout the
    // frontmatter block. Per ECMA-262 §11.3 LineTerminator and YAML's
    // own line-folding rules, CR / CRLF / LF are all valid line
    // separators — and a frontmatter parser that only splits on LF
    // collapses the whole block to one "line", drops `includes:`,
    // and the fixture later throws ReferenceError at runtime for an
    // undefined helper. Regression caught by §13.3.1 / §16.1.7.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const cr_block = "/*---\resid: sec-fn\rdescription: CR fixture\rincludes: [nativeFunctionMatcher.js]\rfeatures: [class]\r---*/";
    const fm = try parseStr(arena.allocator(), cr_block);
    try testing.expectEqual(@as(usize, 1), fm.includes.len);
    try testing.expectEqualStrings("nativeFunctionMatcher.js", fm.includes[0]);
    try testing.expectEqual(@as(usize, 1), fm.features.len);
    try testing.expectEqualStrings("class", fm.features[0]);
}

test "frontmatter: CRLF line terminators" {
    // CRLF is the dominant line ending on Windows and shows up in
    // checked-out files that crossed `core.autocrlf=true`. The parser
    // must treat `\r\n` as ONE separator (not two), otherwise the
    // intervening empty token confuses the scope tracker.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const crlf_block = "/*---\r\nincludes: [tcoHelper.js, propertyHelper.js]\r\nflags: [module]\r\n---*/";
    const fm = try parseStr(arena.allocator(), crlf_block);
    try testing.expectEqual(@as(usize, 2), fm.includes.len);
    try testing.expectEqualStrings("tcoHelper.js", fm.includes[0]);
    try testing.expectEqualStrings("propertyHelper.js", fm.includes[1]);
    try testing.expect(fm.flags.module);
}
