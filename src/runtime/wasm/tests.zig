//! Unit tests for the WebAssembly engine. Sibling files (`reader.zig`,
//! `decoder.zig`, …) also carry their own `test` blocks; this file
//! aggregates higher-level behavioural tests that span more than one
//! module.

const std = @import("std");
const testing = std.testing;

const wasm = @import("wasm.zig");
const ValType = wasm.ValType;

/// The eight-byte preamble of every well-formed wasm binary:
/// `\0asm\x01\x00\x00\x00` (magic + version 1, little-endian).
const preamble = [_]u8{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 };

/// Concatenate the preamble with `body` into an owned buffer.
fn withPreamble(buf: []u8, body: []const u8) []const u8 {
    @memcpy(buf[0..8], &preamble);
    @memcpy(buf[8..][0..body.len], body);
    return buf[0 .. 8 + body.len];
}

/// Decode under a throwaway arena and assert the expected error. The
/// real caller (the JS `WebAssembly.Module` object) owns a decode
/// arena that is dropped wholesale, so partial allocations before an
/// error are reclaimed by the arena, not freed individually — these
/// tests mirror that ownership rather than charging leaks to the
/// testing allocator.
fn expectDecodeError(expected: anyerror, bytes: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(expected, wasm.decode(arena.allocator(), bytes));
}

// ── preamble ────────────────────────────────────────────────────────

test "wasm decoder: accepts the empty-module preamble" {
    const m = try wasm.decode(testing.allocator, &preamble);
    try testing.expectEqual(@as(u32, 1), m.version);
}

test "wasm decoder: rejects an input shorter than the preamble" {
    const truncated: []const u8 = &.{ 0x00, 0x61, 0x73, 0x6d };
    try expectDecodeError(error.Truncated, truncated);
}

test "wasm decoder: rejects an empty input" {
    const empty: []const u8 = &.{};
    try expectDecodeError(error.Truncated, empty);
}

test "wasm decoder: rejects a bad magic number" {
    const bad_magic: []const u8 = &.{ 0xde, 0xad, 0xbe, 0xef, 0x01, 0x00, 0x00, 0x00 };
    try expectDecodeError(error.BadMagic, bad_magic);
}

test "wasm decoder: rejects wire version 2" {
    const v2: []const u8 = &.{ 0x00, 0x61, 0x73, 0x6d, 0x02, 0x00, 0x00, 0x00 };
    try expectDecodeError(error.BadVersion, v2);
}

test "wasm decoder: rejects wire version 0" {
    const v0: []const u8 = &.{ 0x00, 0x61, 0x73, 0x6d, 0x00, 0x00, 0x00, 0x00 };
    try expectDecodeError(error.BadVersion, v0);
}

// ── a complete (i32, i32) -> i32 adder ──────────────────────────────

// type:     (func (param i32 i32) (result i32))
// function: func 0 : type 0
// export:   "add" -> func 0
// code:     local.get 0; local.get 1; i32.add; end
const adder_body = [_]u8{
    // type section (id 1)
    0x01, 0x07, 0x01, 0x60, 0x02, 0x7f, 0x7f, 0x01, 0x7f,
    // function section (id 3)
    0x03, 0x02, 0x01, 0x00,
    // export section (id 7): "add" -> func 0
    0x07, 0x07, 0x01, 0x03, 0x61, 0x64, 0x64, 0x00, 0x00,
    // code section (id 10)
    0x0a, 0x09, 0x01, 0x07, 0x00, 0x20, 0x00, 0x20, 0x01, 0x6a, 0x0b,
};

test "wasm decoder: decodes a full adder module" {
    var buf: [8 + adder_body.len]u8 = undefined;
    const bytes = withPreamble(&buf, &adder_body);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const m = try wasm.decode(arena.allocator(), bytes);

    try testing.expectEqual(@as(usize, 1), m.types.len);
    try testing.expectEqualSlices(ValType, &.{ .i32, .i32 }, m.types[0].params);
    try testing.expectEqualSlices(ValType, &.{.i32}, m.types[0].results);

    try testing.expectEqualSlices(u32, &.{0}, m.funcs);

    try testing.expectEqual(@as(usize, 1), m.exports.len);
    try testing.expectEqualStrings("add", m.exports[0].name);
    try testing.expectEqual(@as(u32, 0), m.exports[0].desc.func);

    try testing.expectEqual(@as(usize, 1), m.code.len);
    // locals(0) local.get 0; local.get 1; i32.add; end
    try testing.expectEqualSlices(u8, &.{ 0x00, 0x20, 0x00, 0x20, 0x01, 0x6a, 0x0b }, m.code[0].bytes);
}

// ── imports, memories, tables, globals ──────────────────────────────

test "wasm decoder: decodes an import section" {
    // import "env" "mem" (memory 1) ; import "env" "g" (global i32 mut)
    const body = [_]u8{
        0x02, 0x15, 0x02,
        // "env" "mem" mem {min 1}
        0x03, 0x65, 0x6e, 0x76, 0x03, 0x6d, 0x65, 0x6d, 0x02, 0x00, 0x01,
        // "env" "g" global i32 var
        0x03, 0x65, 0x6e, 0x76, 0x01, 0x67, 0x03, 0x7f, 0x01,
    };
    var buf: [8 + body.len]u8 = undefined;
    const bytes = withPreamble(&buf, &body);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const m = try wasm.decode(arena.allocator(), bytes);

    try testing.expectEqual(@as(usize, 2), m.imports.len);
    try testing.expectEqualStrings("env", m.imports[0].module);
    try testing.expectEqualStrings("mem", m.imports[0].name);
    try testing.expectEqual(@as(u32, 1), m.imports[0].desc.mem.limits.min);
    try testing.expectEqual(@as(?u32, null), m.imports[0].desc.mem.limits.max);

    try testing.expectEqualStrings("g", m.imports[1].name);
    try testing.expectEqual(ValType.i32, m.imports[1].desc.global.val);
    try testing.expectEqual(@import("types.zig").Mutability.mutable, m.imports[1].desc.global.mut);
}

test "wasm decoder: decodes a global with a constant initializer" {
    // global (mut i32) (i32.const 42)
    const body = [_]u8{ 0x06, 0x06, 0x01, 0x7f, 0x01, 0x41, 0x2a, 0x0b };
    var buf: [8 + body.len]u8 = undefined;
    const bytes = withPreamble(&buf, &body);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const m = try wasm.decode(arena.allocator(), bytes);

    try testing.expectEqual(@as(usize, 1), m.globals.len);
    try testing.expectEqual(ValType.i32, m.globals[0].type.val);
    // raw init expr keeps the terminating `end`
    try testing.expectEqualSlices(u8, &.{ 0x41, 0x2a, 0x0b }, m.globals[0].init_expr);
}

test "wasm decoder: decodes table and memory sections" {
    // table (funcref) {min 1, max 2} ; memory {min 1}
    const body = [_]u8{
        0x04, 0x05, 0x01, 0x70, 0x01, 0x01, 0x02, // table
        0x05, 0x03, 0x01, 0x00, 0x01, // memory
    };
    var buf: [8 + body.len]u8 = undefined;
    const bytes = withPreamble(&buf, &body);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const m = try wasm.decode(arena.allocator(), bytes);

    try testing.expectEqual(@as(usize, 1), m.tables.len);
    try testing.expectEqual(@import("types.zig").RefType.funcref, m.tables[0].elem);
    try testing.expectEqual(@as(u32, 1), m.tables[0].limits.min);
    try testing.expectEqual(@as(?u32, 2), m.tables[0].limits.max);

    try testing.expectEqual(@as(usize, 1), m.mems.len);
    try testing.expectEqual(@as(u32, 1), m.mems[0].limits.min);
}

// ── malformed inputs ────────────────────────────────────────────────

test "wasm decoder: rejects out-of-order sections" {
    // function section (id 3) before type section (id 1)
    const body = [_]u8{
        0x03, 0x02, 0x01, 0x00, // function
        0x01, 0x04, 0x01, 0x60, 0x00, 0x00, // type (empty)
    };
    var buf: [8 + body.len]u8 = undefined;
    const bytes = withPreamble(&buf, &body);
    try expectDecodeError(error.SectionOrder, bytes);
}

test "wasm decoder: rejects a duplicate section" {
    const body = [_]u8{
        0x01, 0x04, 0x01, 0x60, 0x00, 0x00, // type
        0x01, 0x04, 0x01, 0x60, 0x00, 0x00, // type again
    };
    var buf: [8 + body.len]u8 = undefined;
    const bytes = withPreamble(&buf, &body);
    try expectDecodeError(error.SectionOrder, bytes);
}

test "wasm decoder: rejects a section whose body underflows its size" {
    // type section declares size 8 but its content uses only 6 bytes.
    const body = [_]u8{ 0x01, 0x08, 0x01, 0x60, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 };
    var buf: [8 + body.len]u8 = undefined;
    const bytes = withPreamble(&buf, &body);
    try expectDecodeError(error.SectionSizeMismatch, bytes);
}

test "wasm decoder: rejects an unknown value type" {
    // type section, params vec [0x6e] (not a valtype)
    const body = [_]u8{ 0x01, 0x05, 0x01, 0x60, 0x01, 0x6e, 0x00 };
    var buf: [8 + body.len]u8 = undefined;
    const bytes = withPreamble(&buf, &body);
    try expectDecodeError(error.BadValType, bytes);
}

test "wasm decoder: rejects an unknown section id" {
    const body = [_]u8{ 0x0d, 0x01, 0x00 }; // id 13 does not exist
    var buf: [8 + body.len]u8 = undefined;
    const bytes = withPreamble(&buf, &body);
    try expectDecodeError(error.BadSectionId, bytes);
}

test "wasm decoder: rejects function count without matching code" {
    // function section declares one func; no code section follows.
    const body = [_]u8{
        0x01, 0x04, 0x01, 0x60, 0x00, 0x00, // type ()->()
        0x03, 0x02, 0x01, 0x00, // function: func 0 : type 0
    };
    var buf: [8 + body.len]u8 = undefined;
    const bytes = withPreamble(&buf, &body);
    try expectDecodeError(error.FuncCodeMismatch, bytes);
}

test "wasm decoder: rejects a data count that disagrees with the data section" {
    // data count section says 1; data section declares 0 segments.
    const body = [_]u8{
        0x0c, 0x01, 0x01, // data count = 1
        0x0b, 0x01, 0x00, // data section, 0 segments
    };
    var buf: [8 + body.len]u8 = undefined;
    const bytes = withPreamble(&buf, &body);
    try expectDecodeError(error.DataCountMismatch, bytes);
}

test "wasm decoder: tolerates custom sections between known ones" {
    const body = [_]u8{
        0x00, 0x05, 0x04, 0x6e, 0x61, 0x6d, 0x65, // custom "name"
        0x01, 0x04, 0x01, 0x60, 0x00, 0x00, // type
        0x00, 0x03, 0x02, 0x68, 0x69, // custom "hi"
    };
    var buf: [8 + body.len]u8 = undefined;
    const bytes = withPreamble(&buf, &body);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const m = try wasm.decode(arena.allocator(), bytes);
    try testing.expectEqual(@as(usize, 1), m.types.len);
}
