//! Unit tests for the WebAssembly engine. Sibling files (`reader.zig`,
//! `decoder.zig`, …) also carry their own `test` blocks; this file
//! aggregates higher-level behavioural tests that span more than one
//! module.

const std = @import("std");
const testing = std.testing;

const wasm = @import("wasm.zig");
const interp = @import("interpreter.zig");
const ValType = wasm.ValType;

// ── execution harness ───────────────────────────────────────────────

/// Decode + validate + instantiate `bytes`, invoke the i32-returning
/// export `name` with i32 `args`, and return the i32 result.
fn runI32(bytes: []const u8, name: []const u8, args: []const i32) !i32 {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const m = try wasm.decode(a, bytes);
    const mp = try a.create(wasm.Module);
    mp.* = m;

    var instance: interp.Instance = undefined;
    try interp.instantiate(&instance, a, testing.allocator, mp, .{});
    defer instance.deinit();

    const fidx = funcExport(mp, name) orelse return error.NoSuchExport;

    const cells = try a.alloc(u128, args.len);
    for (args, 0..) |x, i| cells[i] = @as(u32, @bitCast(x));

    const res = try interp.invoke(&instance, testing.allocator, fidx, cells);
    defer testing.allocator.free(res);
    return @bitCast(@as(u32, @truncate(res[0])));
}

/// Same, but surface the trap/validate error instead of a value.
fn runI32Err(bytes: []const u8, name: []const u8, args: []const i32) anyerror!void {
    _ = try runI32(bytes, name, args);
}

fn funcExport(m: *const wasm.Module, name: []const u8) ?u32 {
    for (m.exports) |e| {
        if (e.desc == .func and std.mem.eql(u8, e.name, name)) return e.desc.func;
    }
    return null;
}

// ── module builder (computes section/LEB sizes so tests don't) ───────

const List = std.ArrayListUnmanaged(u8);

fn uleb(a: std.mem.Allocator, l: *List, value: usize) !void {
    var v = value;
    while (true) {
        var byte: u8 = @intCast(v & 0x7f);
        v >>= 7;
        if (v != 0) byte |= 0x80;
        try l.append(a, byte);
        if (v == 0) break;
    }
}

fn section(a: std.mem.Allocator, out: *List, id: u8, body: []const u8) !void {
    try out.append(a, id);
    try uleb(a, out, body.len);
    try out.appendSlice(a, body);
}

/// Assemble a single-function module: one type `(params)->(results)`,
/// `func 0`, an export, and a code body (locals header + expression).
/// All section and LEB lengths are computed here.
fn buildFunc(
    a: std.mem.Allocator,
    params: []const u8,
    results: []const u8,
    code_body: []const u8,
    export_name: []const u8,
) ![]const u8 {
    var out: List = .empty;
    try out.appendSlice(a, &preamble);

    var ty: List = .empty;
    try uleb(a, &ty, 1); // one type
    try ty.append(a, 0x60);
    try uleb(a, &ty, params.len);
    try ty.appendSlice(a, params);
    try uleb(a, &ty, results.len);
    try ty.appendSlice(a, results);
    try section(a, &out, 1, ty.items);

    try section(a, &out, 3, &.{ 0x01, 0x00 }); // function: func 0 : type 0

    var ex: List = .empty;
    try uleb(a, &ex, 1);
    try uleb(a, &ex, export_name.len);
    try ex.appendSlice(a, export_name);
    try ex.append(a, 0x00); // export kind: func
    try ex.append(a, 0x00); // func 0
    try section(a, &out, 7, ex.items);

    var co: List = .empty;
    try uleb(a, &co, 1); // one code entry
    try uleb(a, &co, code_body.len);
    try co.appendSlice(a, code_body);
    try section(a, &out, 10, co.items);

    return out.items;
}

/// Build + run a single-function i32 module in one call.
fn runFunc(
    params: []const u8,
    results: []const u8,
    code_body: []const u8,
    name: []const u8,
    args: []const i32,
) !i32 {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const bytes = try buildFunc(arena.allocator(), params, results, code_body, name);
    return runI32(bytes, name, args);
}

/// Like `buildFunc`, but also declares a linear memory of `min_pages`.
fn buildMemFunc(
    a: std.mem.Allocator,
    params: []const u8,
    results: []const u8,
    code_body: []const u8,
    export_name: []const u8,
    min_pages: u32,
) ![]const u8 {
    var out: List = .empty;
    try out.appendSlice(a, &preamble);

    var ty: List = .empty;
    try uleb(a, &ty, 1);
    try ty.append(a, 0x60);
    try uleb(a, &ty, params.len);
    try ty.appendSlice(a, params);
    try uleb(a, &ty, results.len);
    try ty.appendSlice(a, results);
    try section(a, &out, 1, ty.items);

    try section(a, &out, 3, &.{ 0x01, 0x00 });

    // memory section: one memory, limits {min}.
    var me: List = .empty;
    try uleb(a, &me, 1);
    try me.append(a, 0x00); // limits flag: min only
    try uleb(a, &me, min_pages);
    try section(a, &out, 5, me.items);

    var ex: List = .empty;
    try uleb(a, &ex, 1);
    try uleb(a, &ex, export_name.len);
    try ex.appendSlice(a, export_name);
    try ex.append(a, 0x00);
    try ex.append(a, 0x00);
    try section(a, &out, 7, ex.items);

    var co: List = .empty;
    try uleb(a, &co, 1);
    try uleb(a, &co, code_body.len);
    try co.appendSlice(a, code_body);
    try section(a, &out, 10, co.items);

    return out.items;
}

fn runMemFunc(
    params: []const u8,
    results: []const u8,
    code_body: []const u8,
    name: []const u8,
    min_pages: u32,
    args: []const i32,
) !i32 {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const bytes = try buildMemFunc(arena.allocator(), params, results, code_body, name, min_pages);
    return runI32(bytes, name, args);
}

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

/// Decode + validate + instantiate `bytes` under a throwaway arena (used
/// for both allocators, so a partial allocation before a rejection is
/// reclaimed wholesale). The positive path returns void; the negative
/// path surfaces the decode or validation error. Mirrors the spec's
/// `assert_invalid` / `assert_malformed`.
fn loadErr(bytes: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const m = try wasm.decode(a, bytes);
    const mp = try a.create(wasm.Module);
    mp.* = m;
    var instance: interp.Instance = undefined;
    try interp.instantiate(&instance, a, a, mp, .{});
}

/// Assemble a single function `(params)->(results)` with `code_body` and
/// assert that loading it (decode → validate → instantiate) fails with
/// `want` — the function-body equivalent of `assert_invalid`.
fn expectFuncInvalid(want: anyerror, params: []const u8, results: []const u8, code_body: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const bytes = try buildFunc(arena.allocator(), params, results, code_body, "f");
    try testing.expectError(want, loadErr(bytes));
}

/// Run a single export and return all of its raw result cells (for
/// multi-value functions). The returned slice is owned by
/// `testing.allocator`; the caller frees it.
fn runRaw(bytes: []const u8, name: []const u8, arg_cells: []const u128) ![]u128 {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const m = try wasm.decode(a, bytes);
    const mp = try a.create(wasm.Module);
    mp.* = m;
    var instance: interp.Instance = undefined;
    try interp.instantiate(&instance, a, testing.allocator, mp, .{});
    defer instance.deinit();
    const fidx = funcExport(mp, name) orelse return error.NoSuchExport;
    return interp.invoke(&instance, testing.allocator, fidx, arg_cells);
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
    0x07, 0x07, 0x01, 0x03, 0x61,
    0x64, 0x64, 0x00, 0x00,
    // code section (id 10)
    0x0a, 0x09, 0x01, 0x07, 0x00,
    0x20, 0x00, 0x20, 0x01, 0x6a, 0x0b,
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
        0x03, 0x65, 0x6e,
        0x76, 0x03, 0x6d,
        0x65, 0x6d, 0x02,
        0x00, 0x01,
        // "env" "g" global i32 var
        0x03,
        0x65, 0x6e, 0x76,
        0x01, 0x67, 0x03,
        0x7f, 0x01,
    };
    var buf: [8 + body.len]u8 = undefined;
    const bytes = withPreamble(&buf, &body);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const m = try wasm.decode(arena.allocator(), bytes);

    try testing.expectEqual(@as(usize, 2), m.imports.len);
    try testing.expectEqualStrings("env", m.imports[0].module);
    try testing.expectEqualStrings("mem", m.imports[0].name);
    try testing.expectEqual(@as(u64, 1), m.imports[0].desc.mem.limits.min);
    try testing.expectEqual(@as(?u64, null), m.imports[0].desc.mem.limits.max);

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
    try testing.expectEqual(@as(u64, 1), m.tables[0].limits.min);
    try testing.expectEqual(@as(?u64, 2), m.tables[0].limits.max);

    try testing.expectEqual(@as(usize, 1), m.mems.len);
    try testing.expectEqual(@as(u64, 1), m.mems[0].limits.min);
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
    const body = [_]u8{ 0x0e, 0x01, 0x00 }; // id 14 does not exist (13 is now the tag section)
    var buf: [8 + body.len]u8 = undefined;
    const bytes = withPreamble(&buf, &body);
    try expectDecodeError(error.BadSectionId, bytes);
}

// ── unimplemented post-MVP features are rejected, never crash ─────────
//
// Sarcasm decodes the standardized MVP-plus baseline (see wasm.zig). A
// module using a feature outside that scope — WasmGC, function-references
// — must surface a catchable decode/validate error, never an
// `@enumFromInt` trap, an `unreachable`, or an out-of-bounds access. The
// engine runs untrusted modules inside the host process, so an
// unsupported construct is ordinary input, not an exceptional one.

test "wasm validator: rejects a WasmGC opcode (struct.new) as an unknown opcode" {
    // §5.4 — `struct.new` is the 0xFB GC prefix (0xFB 0x00 <typeidx>),
    // unimplemented here. The validator's instruction switch must fall
    // through to the unknown-opcode error rather than mis-decode it.
    // body: 0 locals, struct.new 0, drop, end
    const code_body = [_]u8{ 0x00, 0xfb, 0x00, 0x00, 0x1a, 0x0b };
    try expectFuncInvalid(error.UnknownOpcode, &.{}, &.{}, &code_body);
}

test "wasm validator: rejects a function-references opcode (call_ref) as an unknown opcode" {
    // §5.4 — `call_ref` (0x14) belongs to the function-references
    // proposal, unimplemented here. It must be refused as an unknown
    // opcode, not @enumFromInt-trapped.
    // body: 0 locals, call_ref 0, end
    const code_body = [_]u8{ 0x00, 0x14, 0x00, 0x0b };
    try expectFuncInvalid(error.UnknownOpcode, &.{}, &.{}, &code_body);
}

test "wasm decoder: rejects a function-references typed reference value type" {
    // §5.3.1 — `(ref null $t)` is encoded as 0x63 followed by a heap
    // type. The function-references proposal is unimplemented, so the
    // value-type decoder refuses the 0x63 tag rather than mis-parsing it.
    // type section: 1 type (func ()->((ref null 0)))
    const body = [_]u8{ 0x01, 0x06, 0x01, 0x60, 0x00, 0x01, 0x63, 0x00 };
    var buf: [8 + body.len]u8 = undefined;
    const bytes = withPreamble(&buf, &body);
    try expectDecodeError(error.BadValType, bytes);
}

test "wasm instantiate: an under-provided table import is a catchable error, not a host abort" {
    // §4.5.4 — a declared table import must be matched by a host
    // provision. Instantiating with an empty `Imports` (the shape the
    // conformance harness's assert_invalid probe uses, and any embedder
    // that wires too few tables) must surface a catchable error rather
    // than read past the zero-length provider slice and abort the host.
    // import section: 1 import "a"."t" : (table funcref {min 0})
    const body = [_]u8{
        0x02, 0x09, 0x01, // import section, size 9, 1 import
        0x01, 0x61, // module "a"
        0x01, 0x74, // field "t"
        0x01, // external kind: table
        0x70, 0x00, 0x00, // funcref element, limits {min 0}
    };
    var buf: [8 + body.len]u8 = undefined;
    const bytes = withPreamble(&buf, &body);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const m = try wasm.decode(a, bytes);
    const mp = try a.create(wasm.Module);
    mp.* = m;
    var instance: interp.Instance = undefined;
    try testing.expectError(
        error.UnsupportedImportCall,
        interp.instantiate(&instance, a, a, mp, .{}),
    );
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

// ── execution: integer + control subset ─────────────────────────────

test "wasm interp: the adder computes 2 + 3" {
    var buf: [8 + adder_body.len]u8 = undefined;
    const bytes = withPreamble(&buf, &adder_body);
    try testing.expectEqual(@as(i32, 5), try runI32(bytes, "add", &.{ 2, 3 }));
    try testing.expectEqual(@as(i32, -1), try runI32(bytes, "add", &.{ 2, -3 }));
}

// fib(n) = n<2 ? n : fib(n-1)+fib(n-2). Exercises if/else with a
// result, recursive call, and the function's own terminating `end`.
const fib_code = [_]u8{
    0x00, // 0 local groups
    0x20, 0x00, // local.get 0
    0x41, 0x02, // i32.const 2
    0x48, // i32.lt_s
    0x04, 0x7f, // if (result i32)
    0x20, 0x00, //   local.get 0
    0x05, // else
    0x20, 0x00, //   local.get 0
    0x41, 0x01, //   i32.const 1
    0x6b, //   i32.sub
    0x10, 0x00, //   call 0
    0x20, 0x00, //   local.get 0
    0x41, 0x02, //   i32.const 2
    0x6b, //   i32.sub
    0x10, 0x00, //   call 0
    0x6a, //   i32.add
    0x0b, // end (if)
    0x0b, // end (func)
};

test "wasm interp: recursive fib exercises if/else/call" {
    const want = [_]i32{ 0, 1, 1, 2, 3, 5, 8 };
    for (want, 0..) |w, n| {
        try testing.expectEqual(w, try runFunc(&.{0x7f}, &.{0x7f}, &fib_code, "fib", &.{@intCast(n)}));
    }
    try testing.expectEqual(@as(i32, 55), try runFunc(&.{0x7f}, &.{0x7f}, &fib_code, "fib", &.{10}));
    try testing.expectEqual(@as(i32, 832040), try runFunc(&.{0x7f}, &.{0x7f}, &fib_code, "fib", &.{30}));
}

// sum(n) = 0+1+…+(n-1) via block/loop with br_if (break) and br (continue).
// locals: 0 = n (param), 1 = i, 2 = acc.
const sum_code = [_]u8{
    0x01, 0x02, 0x7f, // locals: 2 × i32
    0x02, 0x40, // block
    0x03, 0x40, // loop
    0x20, 0x01, 0x20, 0x00, 0x4e, // local.get i; local.get n; i32.ge_s
    0x0d, 0x01, // br_if 1   (i>=n → break block)
    0x20, 0x02, 0x20, 0x01, 0x6a, 0x21, 0x02, // acc += i
    0x20, 0x01, 0x41, 0x01, 0x6a, 0x21, 0x01, // i += 1
    0x0c, 0x00, // br 0   (continue loop)
    0x0b, // end loop
    0x0b, // end block
    0x20, 0x02, // local.get acc
    0x0b, // end func
};

test "wasm interp: loop + br_if sums 0..n-1" {
    try testing.expectEqual(@as(i32, 0), try runFunc(&.{0x7f}, &.{0x7f}, &sum_code, "sum", &.{0}));
    try testing.expectEqual(@as(i32, 0), try runFunc(&.{0x7f}, &.{0x7f}, &sum_code, "sum", &.{1}));
    try testing.expectEqual(@as(i32, 10), try runFunc(&.{0x7f}, &.{0x7f}, &sum_code, "sum", &.{5}));
    try testing.expectEqual(@as(i32, 4950), try runFunc(&.{0x7f}, &.{0x7f}, &sum_code, "sum", &.{100}));
}

// div(a,b) = a / b (signed), trapping on /0 and INT_MIN/-1.
const div_code = [_]u8{ 0x00, 0x20, 0x00, 0x20, 0x01, 0x6d, 0x0b };

test "wasm interp: i32.div_s computes and traps" {
    try testing.expectEqual(@as(i32, 3), try runFunc(&.{ 0x7f, 0x7f }, &.{0x7f}, &div_code, "div", &.{ 7, 2 }));
    try testing.expectEqual(@as(i32, -4), try runFunc(&.{ 0x7f, 0x7f }, &.{0x7f}, &div_code, "div", &.{ 8, -2 }));
    try testing.expectError(error.IntegerDivideByZero, runFunc(&.{ 0x7f, 0x7f }, &.{0x7f}, &div_code, "div", &.{ 1, 0 }));
    try testing.expectError(error.IntegerOverflow, runFunc(&.{ 0x7f, 0x7f }, &.{0x7f}, &div_code, "div", &.{ -2147483648, -1 }));
}

// ── execution: linear memory ────────────────────────────────────────

// store(addr,val) then load(addr): local.get 0; local.get 1; i32.store;
// local.get 0; i32.load.  memargs are (align=2, offset=0).
const store_load_code = [_]u8{
    0x00,
    0x20, 0x00, // local.get 0 (addr)
    0x20, 0x01, // local.get 1 (val)
    0x36, 0x02, 0x00, // i32.store align=2 offset=0
    0x20, 0x00, // local.get 0
    0x28, 0x02, 0x00, // i32.load align=2 offset=0
    0x0b,
};

test "wasm interp: i32.store then i32.load round-trips" {
    try testing.expectEqual(@as(i32, 0x12345678), try runMemFunc(&.{ 0x7f, 0x7f }, &.{0x7f}, &store_load_code, "f", 1, &.{ 8, 0x12345678 }));
    try testing.expectEqual(@as(i32, -1), try runMemFunc(&.{ 0x7f, 0x7f }, &.{0x7f}, &store_load_code, "f", 1, &.{ 65532, -1 }));
}

// store8(addr,val); load8_u(addr): exercises sub-width access.
const store8_code = [_]u8{
    0x00,
    0x20, 0x00, 0x20, 0x01, 0x3a, 0x00, 0x00, // i32.store8
    0x20, 0x00, 0x2d, 0x00, 0x00, // i32.load8_u
    0x0b,
};

test "wasm interp: i32.store8 / load8_u keep only the low byte" {
    try testing.expectEqual(@as(i32, 0xAB), try runMemFunc(&.{ 0x7f, 0x7f }, &.{0x7f}, &store8_code, "f", 1, &.{ 3, 0x12AB }));
}

// memory.size (in pages).
const size_code = [_]u8{ 0x00, 0x3f, 0x00, 0x0b };

test "wasm interp: memory.size reports the page count" {
    try testing.expectEqual(@as(i32, 1), try runMemFunc(&.{}, &.{0x7f}, &size_code, "f", 1, &.{}));
    try testing.expectEqual(@as(i32, 3), try runMemFunc(&.{}, &.{0x7f}, &size_code, "f", 3, &.{}));
}

// memory.grow(delta) returns the previous page count.
const grow_code = [_]u8{ 0x00, 0x20, 0x00, 0x40, 0x00, 0x0b };

test "wasm interp: memory.grow returns the old size" {
    try testing.expectEqual(@as(i32, 1), try runMemFunc(&.{0x7f}, &.{0x7f}, &grow_code, "f", 1, &.{2}));
    try testing.expectEqual(@as(i32, 2), try runMemFunc(&.{0x7f}, &.{0x7f}, &grow_code, "f", 2, &.{0}));
}

// memory.fill(0, val, 4); i32.load8_u(0).
const fill_code = [_]u8{
    0x00,
    0x41, 0x00, // i32.const 0 (dst)
    0x20, 0x00, // local.get 0 (val)
    0x41, 0x04, // i32.const 4 (n)
    0xfc, 0x0b, 0x00, // memory.fill
    0x41, 0x00, 0x2d, 0x00, 0x00, // i32.load8_u 0
    0x0b,
};

test "wasm interp: memory.fill writes the low byte" {
    try testing.expectEqual(@as(i32, 0xCD), try runMemFunc(&.{0x7f}, &.{0x7f}, &fill_code, "f", 1, &.{0xCD}));
}

// store at 0; memory.copy(32, 0, 4); load at 32.
// (32 keeps the SLEB constant to a single byte; 64 would be read as -64.)
const copy_code = [_]u8{
    0x00,
    0x41, 0x00, 0x20, 0x00, 0x36, 0x02, 0x00, // i32.store [0] = val
    0x41, 0x20, // i32.const 32 (dst)
    0x41, 0x00, // i32.const 0 (src)
    0x41, 0x04, // i32.const 4 (n)
    0xfc, 0x0a, 0x00, 0x00, // memory.copy
    0x41, 0x20, 0x28, 0x02, 0x00, // i32.load [32]
    0x0b,
};

test "wasm interp: memory.copy moves bytes" {
    try testing.expectEqual(@as(i32, 0x0BADF00D), try runMemFunc(&.{0x7f}, &.{0x7f}, &copy_code, "f", 1, &.{0x0BADF00D}));
}

// store(addr, 0): traps when addr+4 exceeds the single page.
const oob_code = [_]u8{
    0x00, 0x20, 0x00, 0x41, 0x00, 0x36, 0x02, 0x00, 0x41, 0x00, 0x0b,
};

test "wasm interp: out-of-bounds store traps" {
    try testing.expectEqual(@as(i32, 0), try runMemFunc(&.{0x7f}, &.{0x7f}, &oob_code, "f", 1, &.{65532}));
    try testing.expectError(error.OutOfBoundsMemoryAccess, runMemFunc(&.{0x7f}, &.{0x7f}, &oob_code, "f", 1, &.{65533}));
}

// ── execution: floats, numeric unary, sign extension ────────────────

/// Invoke a single-function module, passing raw arg cells and
/// returning the first result cell raw (caller interprets the bits).
fn callCells(
    params: []const u8,
    results: []const u8,
    code_body: []const u8,
    name: []const u8,
    min_pages: ?u32,
    arg_cells: []const u128,
) !u128 {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const bytes = if (min_pages) |mp|
        try buildMemFunc(a, params, results, code_body, name, mp)
    else
        try buildFunc(a, params, results, code_body, name);
    const m = try wasm.decode(a, bytes);
    const modp = try a.create(wasm.Module);
    modp.* = m;
    var instance: interp.Instance = undefined;
    try interp.instantiate(&instance, a, testing.allocator, modp, .{});
    defer instance.deinit();
    const fidx = funcExport(modp, name) orelse return error.NoSuchExport;
    const res = try interp.invoke(&instance, testing.allocator, fidx, arg_cells);
    defer testing.allocator.free(res);
    return res[0];
}

fn f64c(x: f64) u128 {
    return @as(u64, @bitCast(x));
}
fn f32c(x: f32) u128 {
    return @as(u32, @bitCast(x));
}
fn asF64(c: u128) f64 {
    return @bitCast(@as(u64, @truncate(c)));
}
fn asF32(c: u128) f32 {
    return @bitCast(@as(u32, @truncate(c)));
}
fn asI32(c: u128) i32 {
    return @bitCast(@as(u32, @truncate(c)));
}

const F64 = 0x7c;
const F32 = 0x7d;
const I32 = 0x7f;

test "wasm interp: f64 arithmetic" {
    // local.get 0; local.get 1; f64.<op>
    const ops = [_]struct { code: u8, a: f64, b: f64, want: f64 }{
        .{ .code = 0xa0, .a = 1.5, .b = 2.25, .want = 3.75 }, // add
        .{ .code = 0xa1, .a = 5.0, .b = 1.5, .want = 3.5 }, // sub
        .{ .code = 0xa2, .a = 3.0, .b = 4.0, .want = 12.0 }, // mul
        .{ .code = 0xa3, .a = 9.0, .b = 2.0, .want = 4.5 }, // div
    };
    for (ops) |o| {
        const code = [_]u8{ 0x00, 0x20, 0x00, 0x20, 0x01, o.code, 0x0b };
        const r = asF64(try callCells(&.{ F64, F64 }, &.{F64}, &code, "f", null, &.{ f64c(o.a), f64c(o.b) }));
        try testing.expectEqual(o.want, r);
    }
}

test "wasm interp: f64.sqrt" {
    const code = [_]u8{ 0x00, 0x20, 0x00, 0x9f, 0x0b };
    try testing.expectEqual(@as(f64, 3.0), asF64(try callCells(&.{F64}, &.{F64}, &code, "f", null, &.{f64c(9.0)})));
}

test "wasm interp: f64.nearest rounds ties to even" {
    const code = [_]u8{ 0x00, 0x20, 0x00, 0x9e, 0x0b };
    const cases = [_]struct { x: f64, want: f64 }{
        .{ .x = 2.5, .want = 2.0 },
        .{ .x = 3.5, .want = 4.0 },
        .{ .x = 0.5, .want = 0.0 },
        .{ .x = -2.5, .want = -2.0 },
        .{ .x = 2.4, .want = 2.0 },
        .{ .x = 2.6, .want = 3.0 },
    };
    for (cases) |c| {
        try testing.expectEqual(c.want, asF64(try callCells(&.{F64}, &.{F64}, &code, "f", null, &.{f64c(c.x)})));
    }
}

test "wasm interp: f64.min/max signed zero and NaN" {
    const min_code = [_]u8{ 0x00, 0x20, 0x00, 0x20, 0x01, 0xa4, 0x0b };
    const max_code = [_]u8{ 0x00, 0x20, 0x00, 0x20, 0x01, 0xa5, 0x0b };
    // min(-0, +0) = -0  (signbit set)
    const mz = asF64(try callCells(&.{ F64, F64 }, &.{F64}, &min_code, "f", null, &.{ f64c(-0.0), f64c(0.0) }));
    try testing.expect(std.math.signbit(mz) and mz == 0.0);
    // max(-0, +0) = +0
    const pz = asF64(try callCells(&.{ F64, F64 }, &.{F64}, &max_code, "f", null, &.{ f64c(-0.0), f64c(0.0) }));
    try testing.expect(!std.math.signbit(pz) and pz == 0.0);
    // min(NaN, 1) = NaN
    const nan = asF64(try callCells(&.{ F64, F64 }, &.{F64}, &min_code, "f", null, &.{ f64c(std.math.nan(f64)), f64c(1.0) }));
    try testing.expect(std.math.isNan(nan));
}

test "wasm interp: f64 comparison yields i32" {
    const lt = [_]u8{ 0x00, 0x20, 0x00, 0x20, 0x01, 0x63, 0x0b }; // f64.lt
    try testing.expectEqual(@as(i32, 1), asI32(try callCells(&.{ F64, F64 }, &.{I32}, &lt, "f", null, &.{ f64c(1.0), f64c(2.0) })));
    try testing.expectEqual(@as(i32, 0), asI32(try callCells(&.{ F64, F64 }, &.{I32}, &lt, "f", null, &.{ f64c(2.0), f64c(1.0) })));
    // NaN comparisons are false
    try testing.expectEqual(@as(i32, 0), asI32(try callCells(&.{ F64, F64 }, &.{I32}, &lt, "f", null, &.{ f64c(std.math.nan(f64)), f64c(1.0) })));
}

test "wasm interp: f32 add round-trips through 32-bit cells" {
    const code = [_]u8{ 0x00, 0x20, 0x00, 0x20, 0x01, 0x92, 0x0b }; // f32.add
    const r = asF32(try callCells(&.{ F32, F32 }, &.{F32}, &code, "f", null, &.{ f32c(1.5), f32c(2.25) }));
    try testing.expectEqual(@as(f32, 3.75), r);
}

test "wasm interp: i32.clz/ctz/popcnt" {
    const clz = [_]u8{ 0x00, 0x20, 0x00, 0x67, 0x0b };
    const ctz = [_]u8{ 0x00, 0x20, 0x00, 0x68, 0x0b };
    const pop = [_]u8{ 0x00, 0x20, 0x00, 0x69, 0x0b };
    try testing.expectEqual(@as(i32, 24), asI32(try callCells(&.{I32}, &.{I32}, &clz, "f", null, &.{0x80}))); // 0x80 → 24 leading zeros
    try testing.expectEqual(@as(i32, 7), asI32(try callCells(&.{I32}, &.{I32}, &ctz, "f", null, &.{0x80})));
    try testing.expectEqual(@as(i32, 4), asI32(try callCells(&.{I32}, &.{I32}, &pop, "f", null, &.{0x0F})));
}

test "wasm interp: sign-extension ops" {
    const e8 = [_]u8{ 0x00, 0x20, 0x00, 0xc0, 0x0b }; // i32.extend8_s
    try testing.expectEqual(@as(i32, -1), asI32(try callCells(&.{I32}, &.{I32}, &e8, "f", null, &.{0xFF})));
    try testing.expectEqual(@as(i32, 127), asI32(try callCells(&.{I32}, &.{I32}, &e8, "f", null, &.{0x7F})));
    const e16 = [_]u8{ 0x00, 0x20, 0x00, 0xc1, 0x0b }; // i32.extend16_s
    try testing.expectEqual(@as(i32, -1), asI32(try callCells(&.{I32}, &.{I32}, &e16, "f", null, &.{0xFFFF})));
}

test "wasm interp: f64 store then load round-trips" {
    // (i32 addr, f64 val) -> f64
    const code = [_]u8{
        0x00,
        0x20, 0x00, // local.get 0 (addr)
        0x20, 0x01, // local.get 1 (val)
        0x39, 0x03, 0x00, // f64.store align=3 offset=0
        0x20, 0x00, // local.get 0
        0x2b, 0x03, 0x00, // f64.load align=3 offset=0
        0x0b,
    };
    const r = asF64(try callCells(&.{ I32, F64 }, &.{F64}, &code, "f", 1, &.{ 16, f64c(3.141592653589793) }));
    try testing.expectEqual(@as(f64, 3.141592653589793), r);
}

// ── execution: conversions ──────────────────────────────────────────

const I64 = 0x7e;

fn asI64(c: u128) i64 {
    return @bitCast(@as(u64, @truncate(c)));
}

test "wasm interp: i32.wrap_i64" {
    const code = [_]u8{ 0x00, 0x20, 0x00, 0xa7, 0x0b };
    try testing.expectEqual(@as(i32, 1), asI32(try callCells(&.{I64}, &.{I32}, &code, "f", null, &.{0x1_0000_0001})));
}

test "wasm interp: i64.extend_i32_s/u" {
    const es = [_]u8{ 0x00, 0x20, 0x00, 0xac, 0x0b };
    const eu = [_]u8{ 0x00, 0x20, 0x00, 0xad, 0x0b };
    const neg1: u64 = @as(u32, @bitCast(@as(i32, -1)));
    try testing.expectEqual(@as(i64, -1), asI64(try callCells(&.{I32}, &.{I64}, &es, "f", null, &.{neg1})));
    try testing.expectEqual(@as(i64, 0xFFFFFFFF), asI64(try callCells(&.{I32}, &.{I64}, &eu, "f", null, &.{neg1})));
}

test "wasm interp: i32.trunc_f64_s computes and traps" {
    const code = [_]u8{ 0x00, 0x20, 0x00, 0xaa, 0x0b };
    try testing.expectEqual(@as(i32, 3), asI32(try callCells(&.{F64}, &.{I32}, &code, "f", null, &.{f64c(3.7)})));
    try testing.expectEqual(@as(i32, -3), asI32(try callCells(&.{F64}, &.{I32}, &code, "f", null, &.{f64c(-3.7)})));
    try testing.expectError(error.InvalidConversionToInteger, callCells(&.{F64}, &.{I32}, &code, "f", null, &.{f64c(std.math.nan(f64))}));
    try testing.expectError(error.IntegerOverflow, callCells(&.{F64}, &.{I32}, &code, "f", null, &.{f64c(1e30)}));
}

test "wasm interp: i32.trunc_sat_f64_s saturates instead of trapping" {
    const code = [_]u8{ 0x00, 0x20, 0x00, 0xfc, 0x02, 0x0b };
    try testing.expectEqual(@as(i32, 3), asI32(try callCells(&.{F64}, &.{I32}, &code, "f", null, &.{f64c(3.7)})));
    try testing.expectEqual(@as(i32, 0), asI32(try callCells(&.{F64}, &.{I32}, &code, "f", null, &.{f64c(std.math.nan(f64))})));
    try testing.expectEqual(@as(i32, 2147483647), asI32(try callCells(&.{F64}, &.{I32}, &code, "f", null, &.{f64c(1e30)})));
    try testing.expectEqual(@as(i32, -2147483648), asI32(try callCells(&.{F64}, &.{I32}, &code, "f", null, &.{f64c(-1e30)})));
}

test "wasm interp: f64.convert_i32_u treats the operand as unsigned" {
    const code = [_]u8{ 0x00, 0x20, 0x00, 0xb8, 0x0b };
    const neg1: u64 = @as(u32, @bitCast(@as(i32, -1)));
    try testing.expectEqual(@as(f64, 4294967295.0), asF64(try callCells(&.{I32}, &.{F64}, &code, "f", null, &.{neg1})));
}

test "wasm interp: demote / promote between f32 and f64" {
    const demote = [_]u8{ 0x00, 0x20, 0x00, 0xb6, 0x0b };
    const promote = [_]u8{ 0x00, 0x20, 0x00, 0xbb, 0x0b };
    try testing.expectEqual(@as(f32, 1.5), asF32(try callCells(&.{F64}, &.{F32}, &demote, "f", null, &.{f64c(1.5)})));
    try testing.expectEqual(@as(f64, 1.5), asF64(try callCells(&.{F32}, &.{F64}, &promote, "f", null, &.{f32c(1.5)})));
}

test "wasm interp: reinterpret preserves the bit pattern" {
    const i32_from_f32 = [_]u8{ 0x00, 0x20, 0x00, 0xbc, 0x0b };
    try testing.expectEqual(@as(i32, @bitCast(@as(u32, 0x3f800000))), asI32(try callCells(&.{F32}, &.{I32}, &i32_from_f32, "f", null, &.{f32c(1.0)})));
    const f32_from_i32 = [_]u8{ 0x00, 0x20, 0x00, 0xbe, 0x0b };
    try testing.expectEqual(@as(f32, 1.0), asF32(try callCells(&.{I32}, &.{F32}, &f32_from_i32, "f", null, &.{0x3f800000})));
}

// ── execution: SIMD (v128) ──────────────────────────────────────────
// Results are read back through extract_lane so the scalar invoke
// boundary can verify v128 computation.

const V128 = 0x7b;

test "wasm interp: i32x4.splat + extract_lane" {
    // local.get 0; i32x4.splat; i32x4.extract_lane 2
    const code = [_]u8{ 0x00, 0x20, 0x00, 0xfd, 0x11, 0xfd, 0x1b, 0x02, 0x0b };
    try testing.expectEqual(@as(i32, 7), asI32(try callCells(&.{I32}, &.{I32}, &code, "f", null, &.{7})));
}

test "wasm interp: i32x4.add lanewise" {
    // splat a; splat b; i32x4.add; extract_lane 0
    const code = [_]u8{ 0x00, 0x20, 0x00, 0xfd, 0x11, 0x20, 0x01, 0xfd, 0x11, 0xfd, 0xae, 0x01, 0xfd, 0x1b, 0x00, 0x0b };
    try testing.expectEqual(@as(i32, 7), asI32(try callCells(&.{ I32, I32 }, &.{I32}, &code, "f", null, &.{ 3, 4 })));
}

test "wasm interp: f32x4.mul lanewise" {
    // splat a; splat b; f32x4.mul; f32x4.extract_lane 1
    const code = [_]u8{ 0x00, 0x20, 0x00, 0xfd, 0x13, 0x20, 0x01, 0xfd, 0x13, 0xfd, 0xe6, 0x01, 0xfd, 0x1f, 0x01, 0x0b };
    try testing.expectEqual(@as(f32, 6.0), asF32(try callCells(&.{ F32, F32 }, &.{F32}, &code, "f", null, &.{ f32c(2.0), f32c(3.0) })));
}

test "wasm interp: v128.const + extract_lane" {
    // v128.const i32x4 {10,20,30,40}; i32x4.extract_lane 2
    const code = [_]u8{
        0x00, 0xfd, 0x0c,
        0x0a, 0x00, 0x00,
        0x00, 0x14, 0x00,
        0x00, 0x00, 0x1e,
        0x00, 0x00, 0x00,
        0x28, 0x00, 0x00,
        0x00, 0xfd, 0x1b,
        0x02, 0x0b,
    };
    try testing.expectEqual(@as(i32, 30), asI32(try callCells(&.{}, &.{I32}, &code, "f", null, &.{})));
}

test "wasm interp: i8x16.add wraps per lane" {
    // splat x; splat x; i8x16.add; i8x16.extract_lane_s 0
    const code = [_]u8{ 0x00, 0x20, 0x00, 0xfd, 0x0f, 0x20, 0x00, 0xfd, 0x0f, 0xfd, 0x6e, 0xfd, 0x15, 0x00, 0x0b };
    // 100 + 100 = 200, wraps to -56 as i8
    try testing.expectEqual(@as(i32, -56), asI32(try callCells(&.{I32}, &.{I32}, &code, "f", null, &.{100})));
}

test "wasm interp: i32x4.eq yields an all-ones lane mask" {
    // splat x; splat x; i32x4.eq; extract_lane 0
    const code = [_]u8{ 0x00, 0x20, 0x00, 0xfd, 0x11, 0x20, 0x00, 0xfd, 0x11, 0xfd, 0x37, 0xfd, 0x1b, 0x00, 0x0b };
    try testing.expectEqual(@as(i32, -1), asI32(try callCells(&.{I32}, &.{I32}, &code, "f", null, &.{5})));
}

test "wasm interp: i32x4.shl shifts each lane" {
    // splat x; i32.const 4; i32x4.shl; extract_lane 0
    const code = [_]u8{ 0x00, 0x20, 0x00, 0xfd, 0x11, 0x41, 0x04, 0xfd, 0xab, 0x01, 0xfd, 0x1b, 0x00, 0x0b };
    try testing.expectEqual(@as(i32, 16), asI32(try callCells(&.{I32}, &.{I32}, &code, "f", null, &.{1})));
}

test "wasm interp: v128 store then load round-trips" {
    // i32.const 0; v128.const{10,20,30,40}; v128.store; i32.const 0; v128.load; extract_lane 3
    const code = [_]u8{
        0x00,
        0x41,
        0x00,
        0xfd,
        0x0c,
        0x0a,
        0x00,
        0x00,
        0x00,
        0x14,
        0x00,
        0x00,
        0x00,
        0x1e,
        0x00,
        0x00,
        0x00,
        0x28,
        0x00,
        0x00,
        0x00,
        0xfd, 0x0b, 0x04, 0x00, // v128.store align=4 offset=0
        0x41, 0x00,
        0xfd, 0x00, 0x04, 0x00, // v128.load align=4 offset=0
        0xfd, 0x1b, 0x03, 0x0b,
    };
    try testing.expectEqual(@as(i32, 40), asI32(try callCells(&.{}, &.{I32}, &code, "f", 1, &.{})));
}

// ── validator: function-body type checking (assert_invalid) ─────────

/// `f64.const 1.0` — the 0x44 opcode plus its 8 little-endian bytes.
const f64_one = [_]u8{ 0x44, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xf0, 0x3f };

/// Build a single memory-bearing function and assert it fails to load.
fn expectMemFuncInvalid(want: anyerror, params: []const u8, results: []const u8, code_body: []const u8, min_pages: u32) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const bytes = try buildMemFunc(arena.allocator(), params, results, code_body, "f", min_pages);
    try testing.expectError(want, loadErr(bytes));
}

test "wasm validator: result type mismatch is rejected" {
    // body yields f64 where the signature promises i32.
    try expectFuncInvalid(error.TypeMismatch, &.{}, &.{I32}, &([_]u8{0x00} ++ f64_one ++ [_]u8{0x0b}));
}

test "wasm validator: binary-op operand type mismatch is rejected" {
    // i32.const 1; f64.const 1.0; i32.add — second operand is f64.
    const body = [_]u8{ 0x00, 0x41, 0x01 } ++ f64_one ++ [_]u8{ 0x6a, 0x0b };
    try expectFuncInvalid(error.TypeMismatch, &.{}, &.{I32}, &body);
}

test "wasm validator: stack underflow is rejected" {
    // i32.add with nothing on the stack.
    try expectFuncInvalid(error.StackUnderflow, &.{}, &.{I32}, &.{ 0x00, 0x6a, 0x0b });
}

test "wasm validator: leftover operands at function end are rejected" {
    // two i32 values remain where one result is expected.
    try expectFuncInvalid(error.TypeMismatch, &.{}, &.{I32}, &.{ 0x00, 0x41, 0x01, 0x41, 0x02, 0x0b });
}

test "wasm validator: non-i32 if condition is rejected" {
    // f64.const 1.0; if (result i32) i32.const 1 else i32.const 2 end
    const body = [_]u8{0x00} ++ f64_one ++ [_]u8{ 0x04, 0x7f, 0x41, 0x01, 0x05, 0x41, 0x02, 0x0b, 0x0b };
    try expectFuncInvalid(error.TypeMismatch, &.{}, &.{I32}, &body);
}

test "wasm validator: local index out of range is rejected" {
    // (param i32) local.get 5
    try expectFuncInvalid(error.UnknownLocal, &.{I32}, &.{I32}, &.{ 0x00, 0x20, 0x05, 0x0b });
}

test "wasm validator: global index out of range is rejected" {
    // global.get 0 with no globals declared
    try expectFuncInvalid(error.UnknownGlobal, &.{}, &.{I32}, &.{ 0x00, 0x23, 0x00, 0x0b });
}

test "wasm validator: branch to a non-existent label is rejected" {
    // i32.const 0; br 5 — only the function block (label 0) exists.
    try expectFuncInvalid(error.UnknownLabel, &.{}, &.{I32}, &.{ 0x00, 0x41, 0x00, 0x0c, 0x05, 0x0b });
}

test "wasm validator: SIMD lane index out of range is rejected" {
    // i32.const 0; i32x4.splat; i32x4.extract_lane 5  (only lanes 0..3)
    try expectFuncInvalid(error.BadLane, &.{}, &.{I32}, &.{ 0x00, 0x41, 0x00, 0xfd, 0x11, 0xfd, 0x1b, 0x05, 0x0b });
}

test "wasm validator: i8x16.shuffle lane >= 32 is rejected" {
    // two v128s then shuffle with a lane index of 32 (out of 0..31).
    var body: [64]u8 = undefined;
    var n: usize = 0;
    body[n] = 0x00;
    n += 1; // 0 locals
    // v128.const 0 (16 zero bytes), twice
    inline for (0..2) |_| {
        body[n] = 0xfd;
        body[n + 1] = 0x0c;
        n += 2;
        @memset(body[n .. n + 16], 0);
        n += 16;
    }
    body[n] = 0xfd;
    body[n + 1] = 0x0d; // i8x16.shuffle
    n += 2;
    @memset(body[n .. n + 16], 0);
    body[n] = 32; // first lane out of range
    n += 16;
    body[n] = 0xfd;
    body[n + 1] = 0x1b;
    body[n + 2] = 0x00; // i32x4.extract_lane 0 → i32 result
    n += 3;
    body[n] = 0x0b;
    n += 1;
    try expectFuncInvalid(error.BadLane, &.{}, &.{I32}, body[0..n]);
}

test "wasm validator: over-aligned load is rejected" {
    // i32.const 0; i32.load align=3 offset=0 — natural alignment is 2.
    try expectMemFuncInvalid(error.BadAlign, &.{}, &.{I32}, &.{ 0x00, 0x41, 0x00, 0x28, 0x03, 0x00, 0x0b }, 1);
}

test "wasm validator: load without a memory is rejected" {
    // i32.const 0; i32.load — no memory section.
    try expectFuncInvalid(error.NoMemory, &.{}, &.{I32}, &.{ 0x00, 0x41, 0x00, 0x28, 0x02, 0x00, 0x0b });
}

test "wasm validator: unreachable makes following code polymorphic" {
    // unreachable; i32.add (no operands) — valid because unreachable
    // poisons the stack; the function never returns at runtime.
    try testing.expectError(error.Unreachable, runFunc(&.{}, &.{I32}, &.{ 0x00, 0x00, 0x6a, 0x0b }, "f", &.{}));
}

// ── validator: module-level rejection (assert_invalid) ──────────────

const Section = struct { id: u8, body: []const u8 };

/// Assemble a module from the preamble plus the given sections (in the
/// order supplied), computing each section's length.
fn assemble(a: std.mem.Allocator, sections: []const Section) ![]const u8 {
    var out: List = .empty;
    try out.appendSlice(a, &preamble);
    for (sections) |s| try section(a, &out, s.id, s.body);
    return out.items;
}

/// Build a module from `sections` and assert that loading it fails with
/// `want`.
fn expectModuleInvalid(want: anyerror, sections: []const Section) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const bytes = try assemble(arena.allocator(), sections);
    try testing.expectError(want, loadErr(bytes));
}

test "wasm validator: global initializer type mismatch is rejected" {
    // global (i32) (f64.const 1.0) — initializer yields f64.
    const gbody = [_]u8{ 0x01, 0x7f, 0x00 } ++ f64_one ++ [_]u8{0x0b};
    try expectModuleInvalid(error.TypeMismatch, &.{.{ .id = 6, .body = &gbody }});
}

test "wasm validator: non-constant global initializer is rejected" {
    // global (i32) (local.get 0) — local.get is not a constant instr.
    const gbody = [_]u8{ 0x01, 0x7f, 0x00, 0x20, 0x00, 0x0b };
    try expectModuleInvalid(error.BadConstExpr, &.{.{ .id = 6, .body = &gbody }});
}

test "wasm validator: global.get of a later global in an initializer is rejected" {
    // two globals; the first reads the second (forward reference).
    // g0 (i32) (global.get 1); g1 (i32) (i32.const 7)
    const gbody = [_]u8{
        0x02,
        0x7f, 0x00, 0x23, 0x01, 0x0b, // g0 = global.get 1
        0x7f, 0x00, 0x41, 0x07, 0x0b, // g1 = i32.const 7
    };
    try expectModuleInvalid(error.UnknownGlobal, &.{.{ .id = 6, .body = &gbody }});
}

test "wasm validator: active data segment with no memory is rejected" {
    // data segment (active, offset i32.const 0, 0 bytes) but no memory.
    const dbody = [_]u8{ 0x01, 0x00, 0x41, 0x00, 0x0b, 0x00 };
    try expectModuleInvalid(error.UnknownMemory, &.{.{ .id = 11, .body = &dbody }});
}

test "wasm validator: active data offset of the wrong type is rejected" {
    // memory {min 1}; data (active, offset i64.const 0) — needs i32.
    const mbody = [_]u8{ 0x01, 0x00, 0x01 };
    const dbody = [_]u8{ 0x01, 0x00, 0x42, 0x00, 0x0b, 0x00 };
    try expectModuleInvalid(error.TypeMismatch, &.{
        .{ .id = 5, .body = &mbody },
        .{ .id = 11, .body = &dbody },
    });
}

test "wasm validator: active element segment with no table is rejected" {
    // element (active, table 0, offset i32.const 0, 0 funcs) but no table.
    const ebody = [_]u8{ 0x01, 0x00, 0x41, 0x00, 0x0b, 0x00 };
    try expectModuleInvalid(error.UnknownTable, &.{.{ .id = 9, .body = &ebody }});
}

test "wasm validator: memory.init without a data count section is rejected" {
    // i32.const 0 ×3; memory.init 0 0 — no data count section present.
    const body = [_]u8{ 0x00, 0x41, 0x00, 0x41, 0x00, 0x41, 0x00, 0xfc, 0x08, 0x00, 0x00, 0x0b };
    try expectMemFuncInvalid(error.DataCountMissing, &.{}, &.{}, &body, 1);
}

test "wasm validator: call_indirect with no table is rejected" {
    // i32.const 0; call_indirect (type 0) (table 0) — no table declared.
    try expectFuncInvalid(error.UnknownTable, &.{}, &.{}, &.{ 0x00, 0x41, 0x00, 0x11, 0x00, 0x00, 0x0b });
}

test "wasm validator: ref.func to an out-of-range function is rejected" {
    // ref.func 5; drop — only one function exists.
    try expectFuncInvalid(error.UnknownFunc, &.{}, &.{}, &.{ 0x00, 0xd2, 0x05, 0x1a, 0x0b });
}

test "wasm validator: ref.func to an undeclared function is rejected" {
    // Two funcs; func 0 takes ref.func 1, but func 1 is not exported,
    // global-, or element-referenced, so it is not in the reference set.
    const tbody = [_]u8{ 0x01, 0x60, 0x00, 0x00 }; // type 0: () -> ()
    const fbody = [_]u8{ 0x02, 0x00, 0x00 }; // funcs 0,1 : type 0
    const xbody = [_]u8{ 0x01, 0x01, 0x66, 0x00, 0x00 }; // export "f" -> func 0
    const cbody = [_]u8{
        0x02,
        0x05, 0x00, 0xd2, 0x01, 0x1a, 0x0b, // func 0: ref.func 1; drop
        0x02, 0x00, 0x0b, // func 1: (empty)
    };
    try expectModuleInvalid(error.UnknownFunc, &.{
        .{ .id = 1, .body = &tbody },
        .{ .id = 3, .body = &fbody },
        .{ .id = 7, .body = &xbody },
        .{ .id = 10, .body = &cbody },
    });
}

test "wasm validator: start function with a non-empty type is rejected" {
    // start references func 0, whose type is (i32) -> () — must be ()->().
    const tbody = [_]u8{ 0x01, 0x60, 0x01, 0x7f, 0x00 }; // type 0: (i32)->()
    const fbody = [_]u8{ 0x01, 0x00 }; // func 0 : type 0
    const sbody = [_]u8{0x00}; // start = func 0
    const cbody = [_]u8{ 0x01, 0x02, 0x00, 0x0b }; // func 0: (empty)
    try expectModuleInvalid(error.TypeMismatch, &.{
        .{ .id = 1, .body = &tbody },
        .{ .id = 3, .body = &fbody },
        .{ .id = 8, .body = &sbody },
        .{ .id = 10, .body = &cbody },
    });
}

// §3.4.11 — an export must name an entity that exists in the relevant
// index space (imports followed by module-local definitions). An index
// past the end of its space is rejected at validation time, even though
// lookups are otherwise resolved lazily at instantiation/call time.

test "wasm validator: export of an out-of-range function index is rejected" {
    // export "a" (func 0) with no functions declared.
    const xbody = [_]u8{ 0x01, 0x01, 0x61, 0x00, 0x00 };
    try expectModuleInvalid(error.UnknownFunc, &.{.{ .id = 7, .body = &xbody }});
}

test "wasm validator: export of an out-of-range table index is rejected" {
    // table (funcref) {min 0}; export "a" (table 1) — only table 0 exists.
    const tbody = [_]u8{ 0x01, 0x70, 0x00, 0x00 };
    const xbody = [_]u8{ 0x01, 0x01, 0x61, 0x01, 0x01 };
    try expectModuleInvalid(error.UnknownTable, &.{
        .{ .id = 4, .body = &tbody },
        .{ .id = 7, .body = &xbody },
    });
}

test "wasm validator: export of an out-of-range memory index is rejected" {
    // export "a" (memory 0) with no memory declared.
    const xbody = [_]u8{ 0x01, 0x01, 0x61, 0x02, 0x00 };
    try expectModuleInvalid(error.UnknownMemory, &.{.{ .id = 7, .body = &xbody }});
}

test "wasm validator: export of an out-of-range global index is rejected" {
    // export "a" (global 0) with no globals declared.
    const xbody = [_]u8{ 0x01, 0x01, 0x61, 0x03, 0x00 };
    try expectModuleInvalid(error.UnknownGlobal, &.{.{ .id = 7, .body = &xbody }});
}

test "wasm validator: export of an out-of-range tag index is rejected" {
    // export "a" (tag 0) with no tags declared.
    const xbody = [_]u8{ 0x01, 0x01, 0x61, 0x04, 0x00 };
    try expectModuleInvalid(error.UnknownTag, &.{.{ .id = 7, .body = &xbody }});
}

test "wasm validator: in-range exports of every kind validate" {
    // type ()->(); func 0; table (funcref){min 0}; memory {min 0};
    // global i32 (i32.const 0); export each at its valid index 0.
    const tbody = [_]u8{ 0x01, 0x60, 0x00, 0x00 }; // type 0: ()->()
    const fbody = [_]u8{ 0x01, 0x00 }; // func 0 : type 0
    const tabody = [_]u8{ 0x01, 0x70, 0x00, 0x00 }; // table 0: funcref {min 0}
    const mbody = [_]u8{ 0x01, 0x00, 0x00 }; // memory 0: {min 0}
    const gbody = [_]u8{ 0x01, 0x7f, 0x00, 0x41, 0x00, 0x0b }; // global 0: i32 (i32.const 0)
    const xbody = [_]u8{
        0x04,
        0x01, 0x66, 0x00, 0x00, // "f" -> func 0
        0x01, 0x74, 0x01, 0x00, // "t" -> table 0
        0x01, 0x6d, 0x02, 0x00, // "m" -> mem 0
        0x01, 0x67, 0x03, 0x00, // "g" -> global 0
    };
    const cbody = [_]u8{ 0x01, 0x02, 0x00, 0x0b }; // func 0: (empty)
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const bytes = try assemble(arena.allocator(), &.{
        .{ .id = 1, .body = &tbody },
        .{ .id = 3, .body = &fbody },
        .{ .id = 4, .body = &tabody },
        .{ .id = 5, .body = &mbody },
        .{ .id = 6, .body = &gbody },
        .{ .id = 7, .body = &xbody },
        .{ .id = 10, .body = &cbody },
    });
    try loadErr(bytes); // succeeds: every export index is in range
}

// §2.5.10 — the names of all exports in a module must be distinct, even
// when the repeated name points at the same (valid) entity.

test "wasm validator: duplicate export name is rejected" {
    // (table 0 funcref) exported twice under the same name "a". Both
    // indices are in range, so the distinctness rule is what rejects it.
    const tbody = [_]u8{ 0x01, 0x70, 0x00, 0x00 }; // one table: funcref, {min 0}
    const xbody = [_]u8{
        0x02, // two exports
        0x01, 0x61, 0x01, 0x00, // "a" -> table 0
        0x01, 0x61, 0x01, 0x00, // "a" -> table 0 (duplicate name)
    };
    try expectModuleInvalid(error.DuplicateExportName, &.{
        .{ .id = 4, .body = &tbody },
        .{ .id = 7, .body = &xbody },
    });
}

test "wasm validator: distinct export names sharing one target are accepted" {
    // The same table exported under two different names is valid — only
    // the names must be distinct, not their targets. Guards the
    // duplicate-name check against over-rejecting.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const tbody = [_]u8{ 0x01, 0x70, 0x00, 0x00 };
    const xbody = [_]u8{
        0x02,
        0x01, 0x61, 0x01, 0x00, // "a" -> table 0
        0x01, 0x62, 0x01, 0x00, // "b" -> table 0
    };
    const bytes = try assemble(arena.allocator(), &.{
        .{ .id = 4, .body = &tbody },
        .{ .id = 7, .body = &xbody },
    });
    try loadErr(bytes);
}

// ── execution: i32 / i64 arithmetic, bitwise, shifts ────────────────

/// Run `(i32,i32)->i32` whose body is `local.get 0; local.get 1; op`.
fn i32op(op: u8, x: i32, y: i32) !i32 {
    const code = [_]u8{ 0x00, 0x20, 0x00, 0x20, 0x01, op, 0x0b };
    return runFunc(&.{ I32, I32 }, &.{I32}, &code, "f", &.{ x, y });
}

/// Run `(i64,i64)->i64` whose body is `local.get 0; local.get 1; op`.
fn i64op(op: u8, x: i64, y: i64) !i64 {
    const code = [_]u8{ 0x00, 0x20, 0x00, 0x20, 0x01, op, 0x0b };
    const args = [_]u128{ @as(u64, @bitCast(x)), @as(u64, @bitCast(y)) };
    return asI64(try callCells(&.{ I64, I64 }, &.{I64}, &code, "f", null, &args));
}

test "wasm interp: i32 arithmetic and bitwise ops" {
    try testing.expectEqual(@as(i32, 7), try i32op(0x6b, 10, 3)); // sub
    try testing.expectEqual(@as(i32, 30), try i32op(0x6c, 10, 3)); // mul
    try testing.expectEqual(@as(i32, 3), try i32op(0x6d, 10, 3)); // div_s
    try testing.expectEqual(@as(i32, -3), try i32op(0x6d, -10, 3)); // div_s
    try testing.expectEqual(@as(i32, 1), try i32op(0x6f, 10, 3)); // rem_s
    try testing.expectEqual(@as(i32, 0x0c), try i32op(0x71, 0x1c, 0x0d)); // and
    try testing.expectEqual(@as(i32, 0x1d), try i32op(0x72, 0x1c, 0x0d)); // or
    try testing.expectEqual(@as(i32, 0x11), try i32op(0x73, 0x1c, 0x0d)); // xor
}

test "wasm interp: i32 div_u / rem_u treat operands as unsigned" {
    try testing.expectEqual(@as(i32, 0x7fffffff), try i32op(0x6e, -1, 2)); // div_u 0xffffffff/2
    try testing.expectEqual(@as(i32, 1), try i32op(0x70, -1, 2)); // rem_u 0xffffffff%2
}

test "wasm interp: i32 shifts and rotates" {
    try testing.expectEqual(@as(i32, 0x40), try i32op(0x74, 1, 6)); // shl
    try testing.expectEqual(@as(i32, -1), try i32op(0x75, -2, 1)); // shr_s sign-extends
    try testing.expectEqual(@as(i32, 0x7fffffff), try i32op(0x76, -2, 1)); // shr_u
    try testing.expectEqual(@as(i32, 1), try i32op(0x77, -2147483648, 1)); // rotl wraps MSB to LSB
    try testing.expectEqual(@as(i32, -2147483648), try i32op(0x78, 1, 1)); // rotr wraps LSB to MSB
}

test "wasm interp: i32 shift count is taken modulo 32" {
    // shifting by 33 is the same as shifting by 1.
    try testing.expectEqual(@as(i32, 2), try i32op(0x74, 1, 33));
}

test "wasm interp: i32 comparisons yield 0/1" {
    try testing.expectEqual(@as(i32, 1), try i32op(0x46, 5, 5)); // eq
    try testing.expectEqual(@as(i32, 0), try i32op(0x47, 5, 5)); // ne
    try testing.expectEqual(@as(i32, 1), try i32op(0x48, -1, 0)); // lt_s
    try testing.expectEqual(@as(i32, 0), try i32op(0x49, -1, 0)); // lt_u (0xffffffff<0)
    try testing.expectEqual(@as(i32, 1), try i32op(0x4a, 5, 3)); // gt_s
    try testing.expectEqual(@as(i32, 1), try i32op(0x4f, -1, 0)); // ge_u
}

test "wasm interp: i32.div_s by zero and overflow trap" {
    try testing.expectError(error.IntegerDivideByZero, i32op(0x6d, 1, 0));
    try testing.expectError(error.IntegerDivideByZero, i32op(0x6f, 1, 0)); // rem_s by 0
    try testing.expectError(error.IntegerOverflow, i32op(0x6d, -2147483648, -1));
}

test "wasm interp: i32.rem_s of INT_MIN by -1 is 0, not a trap" {
    try testing.expectEqual(@as(i32, 0), try i32op(0x6f, -2147483648, -1));
}

test "wasm interp: i64 arithmetic across the 32-bit boundary" {
    try testing.expectEqual(@as(i64, 0x1_0000_0000), try i64op(0x7c, 0xffff_ffff, 1)); // add
    try testing.expectEqual(@as(i64, 0x1_0000_0000), try i64op(0x7e, 0x1_0000, 0x1_0000)); // mul
    try testing.expectEqual(@as(i64, -1), try i64op(0x7d, 0, 1)); // sub
    try testing.expectEqual(@as(i64, 0x2_0000_0000), try i64op(0x7f, 0x4_0000_0000, 2)); // div_s
}

test "wasm interp: i64 shifts and div traps" {
    try testing.expectEqual(@as(i64, 0x1_0000_0000), try i64op(0x86, 1, 32)); // shl
    try testing.expectError(error.IntegerDivideByZero, i64op(0x7f, 1, 0));
    try testing.expectError(error.IntegerOverflow, i64op(0x7f, std.math.minInt(i64), -1));
}

test "wasm interp: i64.eqz and i64 comparisons" {
    // i64.eqz: local.get 0; i64.eqz
    const code = [_]u8{ 0x00, 0x20, 0x00, 0x50, 0x0b };
    try testing.expectEqual(@as(i32, 1), asI32(try callCells(&.{I64}, &.{I32}, &code, "f", null, &.{0})));
    try testing.expectEqual(@as(i32, 0), asI32(try callCells(&.{I64}, &.{I32}, &code, "f", null, &.{99})));
}

// ── execution: control flow ─────────────────────────────────────────

test "wasm interp: br_table selects a branch by index" {
    // input 0 → 10 (inner block), anything else → 20 (outer block).
    const code = [_]u8{
        0x00,
        0x02, 0x40, // block (outer)
        0x02, 0x40, // block (inner)
        0x20, 0x00, // local.get 0
        0x0e, 0x01, 0x00, 0x01, // br_table count=1 [0] default 1
        0x0b, // end inner
        0x41, 0x0a, 0x0f, // i32.const 10; return
        0x0b, // end outer
        0x41, 0x14, 0x0f, // i32.const 20; return
        0x0b, // end func
    };
    try testing.expectEqual(@as(i32, 10), try runFunc(&.{I32}, &.{I32}, &code, "f", &.{0}));
    try testing.expectEqual(@as(i32, 20), try runFunc(&.{I32}, &.{I32}, &code, "f", &.{1}));
    try testing.expectEqual(@as(i32, 20), try runFunc(&.{I32}, &.{I32}, &code, "f", &.{7}));
}

test "wasm interp: select picks by condition" {
    // i32.const 10; i32.const 20; local.get 0; select
    const code = [_]u8{ 0x00, 0x41, 0x0a, 0x41, 0x14, 0x20, 0x00, 0x1b, 0x0b };
    try testing.expectEqual(@as(i32, 10), try runFunc(&.{I32}, &.{I32}, &code, "f", &.{1}));
    try testing.expectEqual(@as(i32, 20), try runFunc(&.{I32}, &.{I32}, &code, "f", &.{0}));
}

test "wasm interp: typed select picks by condition" {
    // i32.const 10; i32.const 20; local.get 0; select (result i32)
    const code = [_]u8{ 0x00, 0x41, 0x0a, 0x41, 0x14, 0x20, 0x00, 0x1c, 0x01, 0x7f, 0x0b };
    try testing.expectEqual(@as(i32, 20), try runFunc(&.{I32}, &.{I32}, &code, "f", &.{0}));
}

test "wasm interp: return exits early" {
    // local.get 0; return; (dead) i32.const 99
    const code = [_]u8{ 0x00, 0x20, 0x00, 0x0f, 0x41, 0x63, 0x0b };
    try testing.expectEqual(@as(i32, 7), try runFunc(&.{I32}, &.{I32}, &code, "f", &.{7}));
}

test "wasm interp: a function returns multiple values" {
    // () -> (i32, i32): i32.const 1; i32.const 2
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const code = [_]u8{ 0x00, 0x41, 0x01, 0x41, 0x02, 0x0b };
    const bytes = try buildFunc(arena.allocator(), &.{}, &.{ I32, I32 }, &code, "f");
    const res = try runRaw(bytes, "f", &.{});
    defer testing.allocator.free(res);
    try testing.expectEqual(@as(usize, 2), res.len);
    try testing.expectEqual(@as(i32, 1), asI32(res[0]));
    try testing.expectEqual(@as(i32, 2), asI32(res[1]));
}

// ── execution: globals ──────────────────────────────────────────────

test "wasm interp: a mutable global round-trips through global.set/get" {
    // module: (global (mut i32) (i32.const 0))
    //         (func (param i32) (result i32)
    //            local.get 0; global.set 0; global.get 0)
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const tbody = [_]u8{ 0x01, 0x60, 0x01, 0x7f, 0x01, 0x7f };
    const fbody = [_]u8{ 0x01, 0x00 };
    const gbody = [_]u8{ 0x01, 0x7f, 0x01, 0x41, 0x00, 0x0b };
    const xbody = [_]u8{ 0x01, 0x01, 0x66, 0x00, 0x00 };
    const cbody = [_]u8{ 0x01, 0x08, 0x00, 0x20, 0x00, 0x24, 0x00, 0x23, 0x00, 0x0b };
    const bytes = try assemble(arena.allocator(), &.{
        .{ .id = 1, .body = &tbody },
        .{ .id = 3, .body = &fbody },
        .{ .id = 6, .body = &gbody },
        .{ .id = 7, .body = &xbody },
        .{ .id = 10, .body = &cbody },
    });
    try testing.expectEqual(@as(i32, 42), try runI32(bytes, "f", &.{42}));
}

test "wasm interp: an extended-const global initializer is evaluated" {
    // (global i32 (i32.const 20) (i32.const 2) (i32.mul))  ;; = 40
    // exported via a getter function.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const tbody = [_]u8{ 0x01, 0x60, 0x00, 0x01, 0x7f };
    const fbody = [_]u8{ 0x01, 0x00 };
    const gbody = [_]u8{ 0x01, 0x7f, 0x00, 0x41, 0x14, 0x41, 0x02, 0x6c, 0x0b };
    const xbody = [_]u8{ 0x01, 0x01, 0x66, 0x00, 0x00 };
    const cbody = [_]u8{ 0x01, 0x04, 0x00, 0x23, 0x00, 0x0b };
    const bytes = try assemble(arena.allocator(), &.{
        .{ .id = 1, .body = &tbody },
        .{ .id = 3, .body = &fbody },
        .{ .id = 6, .body = &gbody },
        .{ .id = 7, .body = &xbody },
        .{ .id = 10, .body = &cbody },
    });
    try testing.expectEqual(@as(i32, 40), try runI32(bytes, "f", &.{}));
}

// ── execution: reference types, tables, call_indirect ───────────────

test "wasm interp: ref.null is null, ref.func is not" {
    // ref.null func; ref.is_null  → 1
    try testing.expectEqual(@as(i32, 1), try runFunc(&.{}, &.{I32}, &.{ 0x00, 0xd0, 0x70, 0xd1, 0x0b }, "f", &.{}));
    // ref.func 0; ref.is_null  → 0  (func 0 is exported, hence declared)
    try testing.expectEqual(@as(i32, 0), try runFunc(&.{}, &.{I32}, &.{ 0x00, 0xd2, 0x00, 0xd1, 0x0b }, "f", &.{}));
}

test "wasm interp: table.size reports the table's length" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const tbody = [_]u8{ 0x01, 0x60, 0x00, 0x01, 0x7f };
    const fbody = [_]u8{ 0x01, 0x00 };
    const tabbody = [_]u8{ 0x01, 0x70, 0x00, 0x03 }; // funcref, min 3
    const xbody = [_]u8{ 0x01, 0x01, 0x66, 0x00, 0x00 };
    const cbody = [_]u8{ 0x01, 0x05, 0x00, 0xfc, 0x10, 0x00, 0x0b }; // table.size 0
    const bytes = try assemble(arena.allocator(), &.{
        .{ .id = 1, .body = &tbody },
        .{ .id = 3, .body = &fbody },
        .{ .id = 4, .body = &tabbody },
        .{ .id = 7, .body = &xbody },
        .{ .id = 10, .body = &cbody },
    });
    try testing.expectEqual(@as(i32, 3), try runI32(bytes, "f", &.{}));
}

test "wasm interp: table.grow returns the old size and extends the table" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const tbody = [_]u8{ 0x01, 0x60, 0x01, 0x7f, 0x01, 0x7f };
    const fbody = [_]u8{ 0x01, 0x00 };
    const tabbody = [_]u8{ 0x01, 0x70, 0x01, 0x02, 0x0a }; // funcref, min 2 max 10
    const xbody = [_]u8{ 0x01, 0x01, 0x66, 0x00, 0x00 };
    // ref.null func; local.get 0; table.grow 0
    const cbody = [_]u8{ 0x01, 0x09, 0x00, 0xd0, 0x70, 0x20, 0x00, 0xfc, 0x0f, 0x00, 0x0b };
    const bytes = try assemble(arena.allocator(), &.{
        .{ .id = 1, .body = &tbody },
        .{ .id = 3, .body = &fbody },
        .{ .id = 4, .body = &tabbody },
        .{ .id = 7, .body = &xbody },
        .{ .id = 10, .body = &cbody },
    });
    try testing.expectEqual(@as(i32, 2), try runI32(bytes, "f", &.{3})); // old size 2
}

test "wasm interp: table.grow past the maximum returns -1" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const tbody = [_]u8{ 0x01, 0x60, 0x01, 0x7f, 0x01, 0x7f };
    const fbody = [_]u8{ 0x01, 0x00 };
    const tabbody = [_]u8{ 0x01, 0x70, 0x01, 0x02, 0x03 }; // funcref, min 2 max 3
    const xbody = [_]u8{ 0x01, 0x01, 0x66, 0x00, 0x00 };
    const cbody = [_]u8{ 0x01, 0x09, 0x00, 0xd0, 0x70, 0x20, 0x00, 0xfc, 0x0f, 0x00, 0x0b };
    const bytes = try assemble(arena.allocator(), &.{
        .{ .id = 1, .body = &tbody },
        .{ .id = 3, .body = &fbody },
        .{ .id = 4, .body = &tabbody },
        .{ .id = 7, .body = &xbody },
        .{ .id = 10, .body = &cbody },
    });
    try testing.expectEqual(@as(i32, -1), try runI32(bytes, "f", &.{5})); // 2+5 > max 3
}

/// A module with two no-arg i32 callees (func 0 → 42, func 1 → 99), a
/// funcref table of size 4 with indices 0 and 1 filled by an active
/// element segment, and an exported `(i32)->(i32)` dispatcher (func 2)
/// that does `call_indirect` on its argument.
fn dispatcherModule(a: std.mem.Allocator) ![]const u8 {
    const tbody = [_]u8{ 0x02, 0x60, 0x00, 0x01, 0x7f, 0x60, 0x01, 0x7f, 0x01, 0x7f };
    const fbody = [_]u8{ 0x03, 0x00, 0x00, 0x01 }; // funcs 0,1: type 0; func 2: type 1
    const tabbody = [_]u8{ 0x01, 0x70, 0x00, 0x04 }; // funcref min 4
    const xbody = [_]u8{ 0x01, 0x08, 0x64, 0x69, 0x73, 0x70, 0x61, 0x74, 0x63, 0x68, 0x00, 0x02 };
    const ebody = [_]u8{ 0x01, 0x00, 0x41, 0x00, 0x0b, 0x02, 0x00, 0x01 }; // active, [0,1] at 0
    const cbody = [_]u8{
        0x03,
        0x04, 0x00, 0x41, 0x2a, 0x0b, // func 0 → 42
        0x05, 0x00, 0x41, 0xe3, 0x00, 0x0b, // func 1 → 99 (SLEB 0xe3 0x00)
        0x07, 0x00, 0x20, 0x00, 0x11, 0x00, 0x00, 0x0b, // func 2: call_indirect type 0
    };
    return assemble(a, &.{
        .{ .id = 1, .body = &tbody },
        .{ .id = 3, .body = &fbody },
        .{ .id = 4, .body = &tabbody },
        .{ .id = 7, .body = &xbody },
        .{ .id = 9, .body = &ebody },
        .{ .id = 10, .body = &cbody },
    });
}

test "wasm interp: call_indirect dispatches through the table" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const bytes = try dispatcherModule(arena.allocator());
    try testing.expectEqual(@as(i32, 42), try runI32(bytes, "dispatch", &.{0}));
    try testing.expectEqual(@as(i32, 99), try runI32(bytes, "dispatch", &.{1}));
}

test "wasm interp: call_indirect on a null element traps" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const bytes = try dispatcherModule(arena.allocator());
    // index 2 is in bounds (table size 4) but never initialized.
    try testing.expectError(error.UninitializedElement, runI32(bytes, "dispatch", &.{2}));
}

test "wasm interp: call_indirect out of bounds traps" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const bytes = try dispatcherModule(arena.allocator());
    try testing.expectError(error.UndefinedElement, runI32(bytes, "dispatch", &.{9}));
}

// ── cross-module linking ────────────────────────────────────────────

/// Decode + instantiate `bytes` (all allocations from `a`, so dropping
/// the arena reclaims them) and return the heap-stable instance.
fn instOf(a: std.mem.Allocator, bytes: []const u8, imports: wasm.Imports) !*interp.Instance {
    const m = try wasm.decode(a, bytes);
    const mp = try a.create(wasm.Module);
    mp.* = m;
    const ip = try a.create(interp.Instance);
    try interp.instantiate(ip, a, a, mp, imports);
    try interp.runStart(ip, a); // §5.5.11 — runs the start function, if any
    return ip;
}

/// Invoke an export on an already-instantiated instance, returning the
/// first result as i32. Results are arena-allocated by the caller's `a`.
fn invokeInst(a: std.mem.Allocator, ip: *interp.Instance, name: []const u8, arg_cells: []const u128) !i32 {
    const fidx = funcExport(ip.module, name) orelse return error.NoSuchExport;
    const res = try interp.invoke(ip, a, fidx, arg_cells);
    return asI32(res[0]);
}

/// A host function for import tests: ignores its arguments and returns 7.
fn hostReturns7(ctx: ?*anyopaque, args: []const u128, results: []u128) wasm.TrapError!void {
    _ = ctx;
    _ = args;
    results[0] = 7;
}

test "wasm link: an imported function is called across instances" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // provider: (func (export "callee") (result i32) i32.const 7)
    const provider = try instOf(a, try buildFunc(a, &.{}, &.{I32}, &.{ 0x00, 0x41, 0x07, 0x0b }, "callee"), .{});

    // importer: import "p"."callee"; (func (export "run") (result i32) call 0)
    const tbody = [_]u8{ 0x01, 0x60, 0x00, 0x01, 0x7f };
    const ibody = [_]u8{ 0x01, 0x01, 0x70, 0x06, 0x63, 0x61, 0x6c, 0x6c, 0x65, 0x65, 0x00, 0x00 }; // "p"."callee" func type 0
    const fbody = [_]u8{ 0x01, 0x00 };
    const xbody = [_]u8{ 0x01, 0x03, 0x72, 0x75, 0x6e, 0x00, 0x01 }; // "run" -> func 1
    const cbody = [_]u8{ 0x01, 0x04, 0x00, 0x10, 0x00, 0x0b }; // call 0
    const ibytes = try assemble(a, &.{
        .{ .id = 1, .body = &tbody },
        .{ .id = 2, .body = &ibody },
        .{ .id = 3, .body = &fbody },
        .{ .id = 7, .body = &xbody },
        .{ .id = 10, .body = &cbody },
    });
    const fref = provider.exportedFuncRef("callee").?;
    const importer = try instOf(a, ibytes, .{ .funcs = &.{fref} });
    try testing.expectEqual(@as(i32, 7), try invokeInst(a, importer, "run", &.{}));
}

test "wasm link: an imported global value is read" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // provider: (global (export "g") i32 (i32.const 42))
    const pgbody = [_]u8{ 0x01, 0x7f, 0x00, 0x41, 0x2a, 0x0b };
    const pxbody = [_]u8{ 0x01, 0x01, 0x67, 0x03, 0x00 }; // "g" -> global 0
    const pbytes = try assemble(a, &.{
        .{ .id = 6, .body = &pgbody },
        .{ .id = 7, .body = &pxbody },
    });
    const provider = try instOf(a, pbytes, .{});

    // importer: import "p"."g" (global i32); (func (export "run") global.get 0)
    const tbody = [_]u8{ 0x01, 0x60, 0x00, 0x01, 0x7f };
    const ibody = [_]u8{ 0x01, 0x01, 0x70, 0x01, 0x67, 0x03, 0x7f, 0x00 }; // "p"."g" global i32 const
    const fbody = [_]u8{ 0x01, 0x00 };
    const xbody = [_]u8{ 0x01, 0x03, 0x72, 0x75, 0x6e, 0x00, 0x00 }; // "run" -> func 0
    const cbody = [_]u8{ 0x01, 0x04, 0x00, 0x23, 0x00, 0x0b }; // global.get 0
    const ibytes = try assemble(a, &.{
        .{ .id = 1, .body = &tbody },
        .{ .id = 2, .body = &ibody },
        .{ .id = 3, .body = &fbody },
        .{ .id = 7, .body = &xbody },
        .{ .id = 10, .body = &cbody },
    });
    const importer = try instOf(a, ibytes, .{ .globals = &.{provider.exportedGlobalValue("g").?} });
    try testing.expectEqual(@as(i32, 42), try invokeInst(a, importer, "run", &.{}));
}

test "wasm link: a host function import is callable" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // import "host"."f" (func (result i32)); (func (export "run") call 0)
    const tbody = [_]u8{ 0x01, 0x60, 0x00, 0x01, 0x7f };
    const ibody = [_]u8{ 0x01, 0x04, 0x68, 0x6f, 0x73, 0x74, 0x01, 0x66, 0x00, 0x00 }; // "host"."f" func type 0
    const fbody = [_]u8{ 0x01, 0x00 };
    const xbody = [_]u8{ 0x01, 0x03, 0x72, 0x75, 0x6e, 0x00, 0x01 }; // "run" -> func 1
    const cbody = [_]u8{ 0x01, 0x04, 0x00, 0x10, 0x00, 0x0b }; // call 0
    const ibytes = try assemble(a, &.{
        .{ .id = 1, .body = &tbody },
        .{ .id = 2, .body = &ibody },
        .{ .id = 3, .body = &fbody },
        .{ .id = 7, .body = &xbody },
        .{ .id = 10, .body = &cbody },
    });
    const host = wasm.FuncRef{ .host = .{ .fn_ptr = &hostReturns7, .params = 0, .results = 1 } };
    const importer = try instOf(a, ibytes, .{ .funcs = &.{host} });
    try testing.expectEqual(@as(i32, 7), try invokeInst(a, importer, "run", &.{}));
}

test "wasm link: a funcref written into a shared table runs in its own instance" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // provider owns a funcref table and a dispatcher; it does NOT fill
    // the table — the importer does, with a function of its own.
    const ptbody = [_]u8{ 0x02, 0x60, 0x00, 0x01, 0x7f, 0x60, 0x01, 0x7f, 0x01, 0x7f };
    const pfbody = [_]u8{ 0x01, 0x01 }; // func 0 : type 1 (dispatcher)
    const ptab = [_]u8{ 0x01, 0x70, 0x00, 0x04 }; // funcref min 4
    const pxbody = [_]u8{ 0x02, 0x03, 0x74, 0x61, 0x62, 0x01, 0x00, 0x04, 0x63, 0x61, 0x6c, 0x6c, 0x00, 0x00 }; // "tab"->table 0, "call"->func 0
    const pcbody = [_]u8{ 0x01, 0x07, 0x00, 0x20, 0x00, 0x11, 0x00, 0x00, 0x0b }; // local.get 0; call_indirect type 0 table 0
    const pbytes = try assemble(a, &.{
        .{ .id = 1, .body = &ptbody },
        .{ .id = 3, .body = &pfbody },
        .{ .id = 4, .body = &ptab },
        .{ .id = 7, .body = &pxbody },
        .{ .id = 10, .body = &pcbody },
    });
    const provider = try instOf(a, pbytes, .{});

    // importer imports the table and writes ref.func of its own func
    // (returns 50) into index 0 via an active element segment.
    const itbody = [_]u8{ 0x01, 0x60, 0x00, 0x01, 0x7f };
    const iibody = [_]u8{ 0x01, 0x01, 0x70, 0x03, 0x74, 0x61, 0x62, 0x01, 0x70, 0x00, 0x04 }; // import "p"."tab" table funcref min 4
    const ifbody = [_]u8{ 0x01, 0x00 }; // func 0 : type 0
    const iebody = [_]u8{ 0x01, 0x00, 0x41, 0x00, 0x0b, 0x01, 0x00 }; // active table 0, [func 0] at 0
    const icbody = [_]u8{ 0x01, 0x04, 0x00, 0x41, 0x32, 0x0b }; // func 0 → 50
    const ibytes = try assemble(a, &.{
        .{ .id = 1, .body = &itbody },
        .{ .id = 2, .body = &iibody },
        .{ .id = 3, .body = &ifbody },
        .{ .id = 9, .body = &iebody },
        .{ .id = 10, .body = &icbody },
    });
    const tab = provider.exportedTable("tab").?;
    _ = try instOf(a, ibytes, .{ .tables = &.{tab} }); // its element segment fills the shared table

    // Now the provider dispatches index 0 → the importer's function.
    try testing.expectEqual(@as(i32, 50), try invokeInst(a, provider, "call", &.{0}));
}

// ── memory64 ────────────────────────────────────────────────────────

test "wasm decoder: a 64-bit memory limit sets is_64" {
    // memory section: one memory, flag 0x04 (64-bit, min only), min 1.
    const body = [_]u8{ 0x05, 0x03, 0x01, 0x04, 0x01 };
    var buf: [8 + body.len]u8 = undefined;
    const bytes = withPreamble(&buf, &body);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const m = try wasm.decode(arena.allocator(), bytes);
    try testing.expectEqual(@as(usize, 1), m.mems.len);
    try testing.expect(m.mems[0].limits.is_64);
    try testing.expectEqual(@as(u64, 1), m.mems[0].limits.min);
}

test "wasm interp: a memory64 store/load round-trips with i64 addressing" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // (memory i64 1)
    // (func (export "f") (result i64)
    //    i64.const 8; i64.const 42; i64.store; i64.const 8; i64.load)
    const tbody = [_]u8{ 0x01, 0x60, 0x00, 0x01, 0x7e }; // () -> (i64)
    const fbody = [_]u8{ 0x01, 0x00 };
    const mbody = [_]u8{ 0x01, 0x04, 0x01 }; // 64-bit memory, min 1
    const xbody = [_]u8{ 0x01, 0x01, 0x66, 0x00, 0x00 };
    const cbody = [_]u8{
        0x01, 0x0e, 0x00,
        0x42, 0x08, // i64.const 8 (addr)
        0x42, 0x2a, // i64.const 42 (value)
        0x37, 0x03, 0x00, // i64.store align=3 offset=0
        0x42, 0x08, // i64.const 8 (addr)
        0x29, 0x03, 0x00, // i64.load align=3 offset=0
        0x0b,
    };
    const bytes = try assemble(arena.allocator(), &.{
        .{ .id = 1, .body = &tbody },
        .{ .id = 3, .body = &fbody },
        .{ .id = 5, .body = &mbody },
        .{ .id = 7, .body = &xbody },
        .{ .id = 10, .body = &cbody },
    });
    const res = try runRaw(bytes, "f", &.{});
    defer testing.allocator.free(res);
    try testing.expectEqual(@as(i64, 42), asI64(res[0]));
}

// ── memory.init / data.drop and start function ──────────────────────

test "wasm interp: memory.init copies a passive data segment into memory" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // passive data segment = i32 42 (little-endian); memory.init then load.
    const tbody = [_]u8{ 0x01, 0x60, 0x00, 0x01, 0x7f };
    const fbody = [_]u8{ 0x01, 0x00 };
    const mbody = [_]u8{ 0x01, 0x00, 0x01 }; // memory min 1
    const xbody = [_]u8{ 0x01, 0x01, 0x66, 0x00, 0x00 };
    const dcbody = [_]u8{0x01}; // data count = 1
    const cbody = [_]u8{
        0x01, 0x11, 0x00,
        0x41, 0x00, // dst 0
        0x41, 0x00, // src 0
        0x41, 0x04, // n 4
        0xfc, 0x08, 0x00, 0x00, // memory.init data 0 mem 0
        0x41, 0x00, // addr 0
        0x28, 0x02, 0x00, // i32.load
        0x0b,
    };
    const dbody = [_]u8{ 0x01, 0x01, 0x04, 0x2a, 0x00, 0x00, 0x00 }; // passive, 4 bytes = i32 42
    const bytes = try assemble(arena.allocator(), &.{
        .{ .id = 1, .body = &tbody },
        .{ .id = 3, .body = &fbody },
        .{ .id = 5, .body = &mbody },
        .{ .id = 7, .body = &xbody },
        .{ .id = 12, .body = &dcbody },
        .{ .id = 10, .body = &cbody },
        .{ .id = 11, .body = &dbody },
    });
    try testing.expectEqual(@as(i32, 42), try runI32(bytes, "f", &.{}));
}

test "wasm interp: the start function runs during instantiation" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // func 0 (start): global.set 0 = 7; func 1 (get): global.get 0.
    const tbody = [_]u8{ 0x02, 0x60, 0x00, 0x00, 0x60, 0x00, 0x01, 0x7f };
    const fbody = [_]u8{ 0x02, 0x00, 0x01 };
    const gbody = [_]u8{ 0x01, 0x7f, 0x01, 0x41, 0x00, 0x0b }; // mut i32 = 0
    const xbody = [_]u8{ 0x01, 0x03, 0x67, 0x65, 0x74, 0x00, 0x01 }; // "get" -> func 1
    const sbody = [_]u8{0x00}; // start = func 0
    const cbody = [_]u8{
        0x02,
        0x06, 0x00, 0x41, 0x07, 0x24, 0x00, 0x0b, // func 0: i32.const 7; global.set 0
        0x04, 0x00, 0x23, 0x00, 0x0b, // func 1: global.get 0
    };
    const bytes = try assemble(a, &.{
        .{ .id = 1, .body = &tbody },
        .{ .id = 3, .body = &fbody },
        .{ .id = 6, .body = &gbody },
        .{ .id = 7, .body = &xbody },
        .{ .id = 8, .body = &sbody },
        .{ .id = 10, .body = &cbody },
    });
    // instOf runs the start function as part of instantiation.
    const ip = try instOf(a, bytes, .{});
    try testing.expectEqual(@as(i32, 7), try invokeInst(a, ip, "get", &.{}));
}

// ── more SIMD: boolean reductions and bitselect ─────────────────────

test "wasm interp: v128.any_true reports a non-zero lane" {
    // local.get 0; i32x4.splat; v128.any_true
    const code = [_]u8{ 0x00, 0x20, 0x00, 0xfd, 0x11, 0xfd, 0x53, 0x0b };
    try testing.expectEqual(@as(i32, 0), asI32(try callCells(&.{I32}, &.{I32}, &code, "f", null, &.{0})));
    try testing.expectEqual(@as(i32, 1), asI32(try callCells(&.{I32}, &.{I32}, &code, "f", null, &.{9})));
}

test "wasm interp: i8x16.all_true requires every lane non-zero" {
    // local.get 0; i8x16.splat; i8x16.all_true
    const code = [_]u8{ 0x00, 0x20, 0x00, 0xfd, 0x0f, 0xfd, 0x63, 0x0b };
    try testing.expectEqual(@as(i32, 1), asI32(try callCells(&.{I32}, &.{I32}, &code, "f", null, &.{1})));
    try testing.expectEqual(@as(i32, 0), asI32(try callCells(&.{I32}, &.{I32}, &code, "f", null, &.{0})));
}

test "wasm interp: v128.bitselect merges by mask" {
    // splat a; splat b; splat mask; v128.bitselect; extract_lane 0
    const code = [_]u8{
        0x00,
        0x20, 0x00, 0xfd, 0x11, // splat a
        0x20, 0x01, 0xfd, 0x11, // splat b
        0x20, 0x02, 0xfd, 0x11, // splat mask
        0xfd, 0x52, // v128.bitselect
        0xfd, 0x1b, 0x00, // extract_lane 0
        0x0b,
    };
    // mask all-ones → a; mask zero → b
    try testing.expectEqual(@as(i32, 0x12), asI32(try callCells(&.{ I32, I32, I32 }, &.{I32}, &code, "f", null, &.{ 0x12, 0x34, 0xffff_ffff })));
    try testing.expectEqual(@as(i32, 0x34), asI32(try callCells(&.{ I32, I32, I32 }, &.{I32}, &code, "f", null, &.{ 0x12, 0x34, 0 })));
}

// ── traps, recursion limit, and memory edge cases ───────────────────

test "wasm interp: unbounded recursion exhausts the call stack" {
    // (func (call 0)) — calls itself forever.
    try testing.expectError(error.CallStackExhausted, runFunc(&.{}, &.{}, &.{ 0x00, 0x10, 0x00, 0x0b }, "f", &.{}));
}

test "wasm interp: unreachable traps" {
    // unreachable
    try testing.expectError(error.Unreachable, runFunc(&.{}, &.{}, &.{ 0x00, 0x00, 0x0b }, "f", &.{}));
}

test "wasm interp: memory.grow past the maximum returns -1" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const tbody = [_]u8{ 0x01, 0x60, 0x01, 0x7f, 0x01, 0x7f };
    const fbody = [_]u8{ 0x01, 0x00 };
    const mbody = [_]u8{ 0x01, 0x01, 0x01, 0x01 }; // memory min 1 max 1
    const xbody = [_]u8{ 0x01, 0x01, 0x66, 0x00, 0x00 };
    const cbody = [_]u8{ 0x01, 0x06, 0x00, 0x20, 0x00, 0x40, 0x00, 0x0b }; // local.get 0; memory.grow 0
    const bytes = try assemble(arena.allocator(), &.{
        .{ .id = 1, .body = &tbody },
        .{ .id = 3, .body = &fbody },
        .{ .id = 5, .body = &mbody },
        .{ .id = 7, .body = &xbody },
        .{ .id = 10, .body = &cbody },
    });
    try testing.expectEqual(@as(i32, -1), try runI32(bytes, "f", &.{5})); // can't grow past max
}

test "wasm interp: i32.load8_s sign-extends the byte" {
    // store 0xff at 0; load8_s → -1
    const code = [_]u8{
        0x00,
        0x41, 0x00, 0x41, 0xff, 0x01, 0x3a, 0x00, 0x00, // i32.store8 0xff at 0
        0x41, 0x00, 0x2c, 0x00, 0x00, // i32.load8_s at 0
        0x0b,
    };
    try testing.expectEqual(@as(i32, -1), try runMemFunc(&.{}, &.{I32}, &code, "f", 1, &.{}));
}

test "wasm interp: i32.load16_u zero-extends the half-word" {
    // store 0xffff at 0; load16_u → 65535
    const code = [_]u8{
        0x00,
        0x41, 0x00, 0x41, 0xff, 0xff, 0x03, 0x3b, 0x01, 0x00, // i32.store16 0xffff at 0
        0x41, 0x00, 0x2f, 0x01, 0x00, // i32.load16_u at 0
        0x0b,
    };
    try testing.expectEqual(@as(i32, 65535), try runMemFunc(&.{}, &.{I32}, &code, "f", 1, &.{}));
}

test "wasm interp: out-of-bounds load traps" {
    // i32.load at the last page byte + 1 (offset 65536 of a 1-page memory)
    const code = [_]u8{ 0x00, 0x41, 0x80, 0x80, 0x04, 0x28, 0x02, 0x00, 0x0b }; // i32.const 65536; i32.load
    try testing.expectError(error.OutOfBoundsMemoryAccess, runMemFunc(&.{}, &.{I32}, &code, "f", 1, &.{}));
}

test "wasm tail call: return_call self-recursion is constant-stack (TCO)" {
    // countdown(n) = n==0 ? 42 : return_call countdown(n-1).
    // Depth 100000 ≫ MAX_FRAMES (4096): only a tail call (frame *replaced*,
    // not pushed) lets this return instead of trapping CallStackExhausted.
    const code = [_]u8{
        0x00, // no extra locals
        0x20, 0x00, // local.get 0
        0x45, // i32.eqz
        0x04, 0x7f, // if (result i32)
        0x41, 0x2a, //   i32.const 42
        0x05, // else
        0x20, 0x00, //   local.get 0
        0x41, 0x01, //   i32.const 1
        0x6b, //   i32.sub
        0x12, 0x00, //   return_call 0  (tail-call self)
        0x0b, // end if
        0x0b, // end func
    };
    try testing.expectEqual(@as(i32, 42), try runFunc(&.{I32}, &.{I32}, &code, "countdown", &.{100000}));
}

// Like `dispatcherModule`, but the dispatcher tail-calls via
// `return_call_indirect` (0x13). The callee's result (i32) matches the
// dispatcher's, so the tail call is well-typed.
fn returnCallIndirectModule(a: std.mem.Allocator) ![]const u8 {
    const tbody = [_]u8{ 0x02, 0x60, 0x00, 0x01, 0x7f, 0x60, 0x01, 0x7f, 0x01, 0x7f };
    const fbody = [_]u8{ 0x03, 0x00, 0x00, 0x01 };
    const tabbody = [_]u8{ 0x01, 0x70, 0x00, 0x04 };
    const xbody = [_]u8{ 0x01, 0x08, 0x64, 0x69, 0x73, 0x70, 0x61, 0x74, 0x63, 0x68, 0x00, 0x02 };
    const ebody = [_]u8{ 0x01, 0x00, 0x41, 0x00, 0x0b, 0x02, 0x00, 0x01 };
    const cbody = [_]u8{
        0x03,
        0x04, 0x00, 0x41, 0x2a, 0x0b, // func 0 → 42
        0x05, 0x00, 0x41, 0xe3, 0x00, 0x0b, // func 1 → 99
        0x07, 0x00, 0x20, 0x00, 0x13, 0x00, 0x00, 0x0b, // func 2: return_call_indirect type 0 table 0
    };
    return assemble(a, &.{
        .{ .id = 1, .body = &tbody },
        .{ .id = 3, .body = &fbody },
        .{ .id = 4, .body = &tabbody },
        .{ .id = 7, .body = &xbody },
        .{ .id = 9, .body = &ebody },
        .{ .id = 10, .body = &cbody },
    });
}

test "wasm tail call: return_call_indirect dispatches through the table" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const bytes = try returnCallIndirectModule(arena.allocator());
    try testing.expectEqual(@as(i32, 42), try runI32(bytes, "dispatch", &.{0}));
    try testing.expectEqual(@as(i32, 99), try runI32(bytes, "dispatch", &.{1}));
}

test "wasm relaxed-simd: i32x4.relaxed_laneselect picks lanes by mask" {
    // splat a, b, mask; i32x4.relaxed_laneselect; i32x4.extract_lane 0.
    const code = [_]u8{
        0x00,
        0x20, 0x00, 0xfd, 0x11, // local.get 0; i32x4.splat
        0x20, 0x01, 0xfd, 0x11, // local.get 1; i32x4.splat
        0x20, 0x02, 0xfd, 0x11, // local.get 2; i32x4.splat (mask)
        0xfd, 0x8b, 0x02, // i32x4.relaxed_laneselect (sub 267)
        0xfd, 0x1b, 0x00, // i32x4.extract_lane 0
        0x0b,
    };
    try testing.expectEqual(@as(i32, 7), try runFunc(&.{ I32, I32, I32 }, &.{I32}, &code, "f", &.{ 7, 9, -1 }));
    try testing.expectEqual(@as(i32, 9), try runFunc(&.{ I32, I32, I32 }, &.{I32}, &code, "f", &.{ 7, 9, 0 }));
}

test "wasm relaxed-simd: f32x4.relaxed_madd computes a*b+c" {
    const code = [_]u8{
        0x00,
        0x20, 0x00, 0xb2, 0xfd, 0x13, // local.get 0; f32.convert_i32_s; f32x4.splat
        0x20, 0x01, 0xb2, 0xfd, 0x13, // b
        0x20, 0x02, 0xb2, 0xfd, 0x13, // c
        0xfd, 0x85, 0x02, // f32x4.relaxed_madd (sub 261)
        0xfd, 0xf8, 0x01, // i32x4.trunc_sat_f32x4_s
        0xfd, 0x1b, 0x00, // i32x4.extract_lane 0
        0x0b,
    };
    try testing.expectEqual(@as(i32, 7), try runFunc(&.{ I32, I32, I32 }, &.{I32}, &code, "f", &.{ 2, 3, 1 })); // 2*3+1
}

test "wasm relaxed-simd: i16x8.relaxed_dot_i8x16_i7x16_s" {
    const code = [_]u8{
        0x00,
        0x20, 0x00, 0xfd, 0x0f, // local.get 0; i8x16.splat
        0x20, 0x01, 0xfd, 0x0f, // local.get 1; i8x16.splat
        0xfd, 0x92, 0x02, // i16x8.relaxed_dot_i8x16_i7x16_s (sub 274)
        0xfd, 0x18, 0x00, // i16x8.extract_lane_s 0
        0x0b,
    };
    try testing.expectEqual(@as(i32, 12), try runFunc(&.{ I32, I32 }, &.{I32}, &code, "f", &.{ 2, 3 })); // 2*3 + 2*3
}

test "wasm exceptions: a try_table around non-throwing code runs like a block" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // type 0: ()->i32 (the func); type 1: (i32)->() (the tag's signature).
    const tbody = [_]u8{ 0x02, 0x60, 0x00, 0x01, 0x7f, 0x60, 0x01, 0x7f, 0x00 };
    const fbody = [_]u8{ 0x01, 0x00 }; // func 0 : type 0
    const gbody = [_]u8{ 0x01, 0x00, 0x01 }; // tag 0: attribute 0, type 1
    const xbody = [_]u8{ 0x01, 0x01, 0x66, 0x00, 0x00 }; // export "f" func 0
    // try_table (result i32) (catch tag0 -> label0) i32.const 42 end ; end
    const cbody = [_]u8{ 0x01, 0x0b, 0x00, 0x1f, 0x7f, 0x01, 0x00, 0x00, 0x00, 0x41, 0x2a, 0x0b, 0x0b };
    const bytes = try assemble(a, &.{
        .{ .id = 1, .body = &tbody },
        .{ .id = 3, .body = &fbody },
        .{ .id = 13, .body = &gbody },
        .{ .id = 7, .body = &xbody },
        .{ .id = 10, .body = &cbody },
    });
    try testing.expectEqual(@as(i32, 42), try runI32(bytes, "f", &.{}));
}

test "wasm exceptions: throw with no handler is an uncaught trap (Phase-1a)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tbody = [_]u8{ 0x02, 0x60, 0x00, 0x01, 0x7f, 0x60, 0x01, 0x7f, 0x00 };
    const fbody = [_]u8{ 0x01, 0x00 };
    const gbody = [_]u8{ 0x01, 0x00, 0x01 };
    const xbody = [_]u8{ 0x01, 0x01, 0x66, 0x00, 0x00 };
    const cbody = [_]u8{ 0x01, 0x06, 0x00, 0x41, 0x05, 0x08, 0x00, 0x0b }; // i32.const 5; throw tag0
    const bytes = try assemble(a, &.{
        .{ .id = 1, .body = &tbody },
        .{ .id = 3, .body = &fbody },
        .{ .id = 13, .body = &gbody },
        .{ .id = 7, .body = &xbody },
        .{ .id = 10, .body = &cbody },
    });
    try testing.expectError(error.UncaughtException, runI32(bytes, "f", &.{}));
}

test "wasm exceptions: try_table catches its own throw, payload becomes the result" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tbody = [_]u8{ 0x02, 0x60, 0x00, 0x01, 0x7f, 0x60, 0x01, 0x7f, 0x00 };
    const fbody = [_]u8{ 0x01, 0x00 };
    const gbody = [_]u8{ 0x01, 0x00, 0x01 };
    const xbody = [_]u8{ 0x01, 0x01, 0x66, 0x00, 0x00 };
    // block $h (result i32) { try_table (result i32) (catch tag0 -> $h) i32.const 7; throw tag0 end } end
    const cbody = [_]u8{ 0x01, 0x10, 0x00, 0x02, 0x7f, 0x1f, 0x7f, 0x01, 0x00, 0x00, 0x00, 0x41, 0x07, 0x08, 0x00, 0x0b, 0x0b, 0x0b };
    const bytes = try assemble(a, &.{
        .{ .id = 1, .body = &tbody },
        .{ .id = 3, .body = &fbody },
        .{ .id = 13, .body = &gbody },
        .{ .id = 7, .body = &xbody },
        .{ .id = 10, .body = &cbody },
    });
    try testing.expectEqual(@as(i32, 7), try runI32(bytes, "f", &.{}));
}

test "wasm exceptions: catch_all catches a throw and resumes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tbody = [_]u8{ 0x02, 0x60, 0x00, 0x01, 0x7f, 0x60, 0x01, 0x7f, 0x00 };
    const fbody = [_]u8{ 0x01, 0x00 };
    const gbody = [_]u8{ 0x01, 0x00, 0x01 };
    const xbody = [_]u8{ 0x01, 0x01, 0x66, 0x00, 0x00 };
    // block { try_table (catch_all -> $block) i32.const 9; throw tag0 end } end ; i32.const 5
    const cbody = [_]u8{ 0x01, 0x11, 0x00, 0x02, 0x40, 0x1f, 0x40, 0x01, 0x02, 0x00, 0x41, 0x09, 0x08, 0x00, 0x0b, 0x0b, 0x41, 0x05, 0x0b };
    const bytes = try assemble(a, &.{
        .{ .id = 1, .body = &tbody },
        .{ .id = 3, .body = &fbody },
        .{ .id = 13, .body = &gbody },
        .{ .id = 7, .body = &xbody },
        .{ .id = 10, .body = &cbody },
    });
    try testing.expectEqual(@as(i32, 5), try runI32(bytes, "f", &.{}));
}

test "wasm exceptions: throw propagates across a call to the caller's try_table" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tbody = [_]u8{ 0x02, 0x60, 0x00, 0x01, 0x7f, 0x60, 0x01, 0x7f, 0x00 };
    const fbody = [_]u8{ 0x02, 0x00, 0x00 }; // func0 (g) and func1 (f), both type 0
    const gbody = [_]u8{ 0x01, 0x00, 0x01 };
    const xbody = [_]u8{ 0x01, 0x01, 0x66, 0x00, 0x01 }; // export "f" -> func 1
    // func0 g: i32.const 8; throw tag0
    // func1 f: block $h (result i32) { try_table (result i32) (catch tag0 -> $h) call g end } end
    const cbody = [_]u8{
        0x02,
        0x06,
        0x00,
        0x41,
        0x08,
        0x08,
        0x00,
        0x0b,
        0x0e,
        0x00,
        0x02,
        0x7f,
        0x1f,
        0x7f,
        0x01,
        0x00,
        0x00,
        0x00,
        0x10,
        0x00,
        0x0b,
        0x0b,
        0x0b,
    };
    const bytes = try assemble(a, &.{
        .{ .id = 1, .body = &tbody },
        .{ .id = 3, .body = &fbody },
        .{ .id = 13, .body = &gbody },
        .{ .id = 7, .body = &xbody },
        .{ .id = 10, .body = &cbody },
    });
    try testing.expectEqual(@as(i32, 8), try runI32(bytes, "f", &.{}));
}

test "wasm exceptions: a normally-completed try_table does not catch a later throw" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tbody = [_]u8{ 0x02, 0x60, 0x00, 0x01, 0x7f, 0x60, 0x01, 0x7f, 0x00 };
    const fbody = [_]u8{ 0x01, 0x00 };
    const gbody = [_]u8{ 0x01, 0x00, 0x01 };
    const xbody = [_]u8{ 0x01, 0x01, 0x66, 0x00, 0x00 };
    // block { try_table (catch_all -> $block) nop end } end ; i32.const 1; throw tag0
    // The try_table completes normally (nop never throws), so its handler
    // must be out of scope by the time the later throw runs -> uncaught.
    const cbody = [_]u8{ 0x01, 0x10, 0x00, 0x02, 0x40, 0x1f, 0x40, 0x01, 0x02, 0x00, 0x01, 0x0b, 0x0b, 0x41, 0x01, 0x08, 0x00, 0x0b };
    const bytes = try assemble(a, &.{
        .{ .id = 1, .body = &tbody },
        .{ .id = 3, .body = &fbody },
        .{ .id = 13, .body = &gbody },
        .{ .id = 7, .body = &xbody },
        .{ .id = 10, .body = &cbody },
    });
    try testing.expectError(error.UncaughtException, runI32(bytes, "f", &.{}));
}

test "wasm exceptions: a second try_table still catches after a sibling completed" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tbody = [_]u8{ 0x02, 0x60, 0x00, 0x01, 0x7f, 0x60, 0x01, 0x7f, 0x00 };
    const fbody = [_]u8{ 0x01, 0x00 };
    const gbody = [_]u8{ 0x01, 0x00, 0x01 };
    const xbody = [_]u8{ 0x01, 0x01, 0x66, 0x00, 0x00 };
    // block { try_table (catch_all -> blk) nop end } end   ; A completes
    // block (i32) { try_table (i32) (catch tag0 -> blk) i32.const 3; throw tag0 end } end   ; B catches
    const cbody = [_]u8{
        0x01, 0x1a, 0x00,
        0x02, 0x40, 0x1f,
        0x40, 0x01, 0x02,
        0x00, 0x01, 0x0b,
        0x0b, 0x02, 0x7f,
        0x1f, 0x7f, 0x01,
        0x00, 0x00, 0x00,
        0x41, 0x03, 0x08,
        0x00, 0x0b, 0x0b,
        0x0b,
    };
    const bytes = try assemble(a, &.{
        .{ .id = 1, .body = &tbody },
        .{ .id = 3, .body = &fbody },
        .{ .id = 13, .body = &gbody },
        .{ .id = 7, .body = &xbody },
        .{ .id = 10, .body = &cbody },
    });
    try testing.expectEqual(@as(i32, 3), try runI32(bytes, "f", &.{}));
}

test "wasm exceptions: catch_all_ref binds an exnref that throw_ref re-raises" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tbody = [_]u8{ 0x02, 0x60, 0x00, 0x01, 0x7f, 0x60, 0x01, 0x7f, 0x00 };
    const fbody = [_]u8{ 0x01, 0x00 };
    const gbody = [_]u8{ 0x01, 0x00, 0x01 };
    const xbody = [_]u8{ 0x01, 0x01, 0x66, 0x00, 0x00 };
    // block $outer (i32) { try_table (i32) (catch tag0 -> $outer)
    //   block $inner (exnref) { try_table (exnref) (catch_all_ref -> $inner)
    //     i32.const 5; throw tag0 end } end
    //   throw_ref   ;; re-raise the bound exnref -> outer catch -> result 5
    // end } end
    const cbody = [_]u8{
        0x01, 0x1a, 0x00,
        0x02, 0x7f, 0x1f,
        0x7f, 0x01, 0x00,
        0x00, 0x00, 0x02,
        0x69, 0x1f, 0x69,
        0x01, 0x03, 0x00,
        0x41, 0x05, 0x08,
        0x00, 0x0b, 0x0b,
        0x0a, 0x0b, 0x0b,
        0x0b,
    };
    const bytes = try assemble(a, &.{
        .{ .id = 1, .body = &tbody },
        .{ .id = 3, .body = &fbody },
        .{ .id = 13, .body = &gbody },
        .{ .id = 7, .body = &xbody },
        .{ .id = 10, .body = &cbody },
    });
    try testing.expectEqual(@as(i32, 5), try runI32(bytes, "f", &.{}));
}

test "wasm exceptions: catch_ref binds an exnref for an empty-payload tag" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // type0 ()->i32 (func); type1 (i32)->(); type2 ()->() (the tag, no payload)
    const tbody = [_]u8{ 0x03, 0x60, 0x00, 0x01, 0x7f, 0x60, 0x01, 0x7f, 0x00, 0x60, 0x00, 0x00 };
    const fbody = [_]u8{ 0x01, 0x00 };
    const gbody = [_]u8{ 0x01, 0x00, 0x02 }; // tag0 : type2
    const xbody = [_]u8{ 0x01, 0x01, 0x66, 0x00, 0x00 };
    // block $inner (exnref) { try_table (exnref) (catch_ref tag0 -> $inner) throw tag0 end } end
    // drop ; i32.const 7   ;; reaching here means catch_ref caught + bound an exnref
    const cbody = [_]u8{
        0x01, 0x11, 0x00,
        0x02, 0x69, 0x1f,
        0x69, 0x01, 0x01,
        0x00, 0x00, 0x08,
        0x00, 0x0b, 0x0b,
        0x1a, 0x41, 0x07,
        0x0b,
    };
    const bytes = try assemble(a, &.{
        .{ .id = 1, .body = &tbody },
        .{ .id = 3, .body = &fbody },
        .{ .id = 13, .body = &gbody },
        .{ .id = 7, .body = &xbody },
        .{ .id = 10, .body = &cbody },
    });
    try testing.expectEqual(@as(i32, 7), try runI32(bytes, "f", &.{}));
}

test "wasm exceptions: a non-matching catch falls through to a later catch_all" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // type0 ()->i32; type1 ()->() (both tags). tag0, tag1.
    const tbody = [_]u8{ 0x02, 0x60, 0x00, 0x01, 0x7f, 0x60, 0x00, 0x00 };
    const fbody = [_]u8{ 0x01, 0x00 };
    const gbody = [_]u8{ 0x02, 0x00, 0x01, 0x00, 0x01 };
    const xbody = [_]u8{ 0x01, 0x01, 0x66, 0x00, 0x00 };
    // block $b { try_table (catch tag0 -> $b)(catch_all -> $b) throw tag1 end } end ; i32.const 42
    // throw tag1 skips the tag0 catch and is taken by catch_all -> 42 (else: uncaught trap).
    const cbody = [_]u8{ 0x01, 0x12, 0x00, 0x02, 0x40, 0x1f, 0x40, 0x02, 0x00, 0x00, 0x00, 0x02, 0x00, 0x08, 0x01, 0x0b, 0x0b, 0x41, 0x2a, 0x0b };
    const bytes = try assemble(a, &.{
        .{ .id = 1, .body = &tbody }, .{ .id = 3, .body = &fbody },  .{ .id = 13, .body = &gbody },
        .{ .id = 7, .body = &xbody }, .{ .id = 10, .body = &cbody },
    });
    try testing.expectEqual(@as(i32, 42), try runI32(bytes, "f", &.{}));
}

test "wasm exceptions: try_table with block-type params restores the operand stack" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // type0 ()->i32; type1 (i32)->() (tag); type2 (i32)->(i32) (the try_table block type).
    const tbody = [_]u8{ 0x03, 0x60, 0x00, 0x01, 0x7f, 0x60, 0x01, 0x7f, 0x00, 0x60, 0x01, 0x7f, 0x01, 0x7f };
    const fbody = [_]u8{ 0x01, 0x00 };
    const gbody = [_]u8{ 0x01, 0x00, 0x01 };
    const xbody = [_]u8{ 0x01, 0x01, 0x66, 0x00, 0x00 };
    // block $h (i32) { i32.const 9; try_table (type2)(catch tag0 -> $h) throw tag0 end } end
    // the param 9 is the throw payload, delivered to $h -> result 9.
    const cbody = [_]u8{ 0x01, 0x10, 0x00, 0x02, 0x7f, 0x41, 0x09, 0x1f, 0x02, 0x01, 0x00, 0x00, 0x00, 0x08, 0x00, 0x0b, 0x0b, 0x0b };
    const bytes = try assemble(a, &.{
        .{ .id = 1, .body = &tbody }, .{ .id = 3, .body = &fbody },  .{ .id = 13, .body = &gbody },
        .{ .id = 7, .body = &xbody }, .{ .id = 10, .body = &cbody },
    });
    try testing.expectEqual(@as(i32, 9), try runI32(bytes, "f", &.{}));
}

test "wasm exceptions: throw_ref of a null exnref traps" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tbody = [_]u8{ 0x01, 0x60, 0x00, 0x01, 0x7f };
    const fbody = [_]u8{ 0x01, 0x00 };
    const xbody = [_]u8{ 0x01, 0x01, 0x66, 0x00, 0x00 };
    // ref.null exn ; throw_ref
    const cbody = [_]u8{ 0x01, 0x05, 0x00, 0xd0, 0x69, 0x0a, 0x0b };
    const bytes = try assemble(a, &.{
        .{ .id = 1, .body = &tbody }, .{ .id = 3, .body = &fbody },
        .{ .id = 7, .body = &xbody }, .{ .id = 10, .body = &cbody },
    });
    try testing.expectError(error.NullExnRef, runI32(bytes, "f", &.{}));
}

test "wasm exceptions: validator rejects throw of an out-of-range tag" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tbody = [_]u8{ 0x01, 0x60, 0x00, 0x00 };
    const fbody = [_]u8{ 0x01, 0x00 };
    const cbody = [_]u8{ 0x01, 0x04, 0x00, 0x08, 0x00, 0x0b }; // throw tag0 — no tags defined
    const bytes = try assemble(a, &.{
        .{ .id = 1, .body = &tbody }, .{ .id = 3, .body = &fbody }, .{ .id = 10, .body = &cbody },
    });
    try testing.expectError(error.UnknownTag, loadErr(bytes));
}

test "wasm exceptions: validator rejects a bad catch kind" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tbody = [_]u8{ 0x01, 0x60, 0x00, 0x00 };
    const fbody = [_]u8{ 0x01, 0x00 };
    const cbody = [_]u8{ 0x01, 0x07, 0x00, 0x1f, 0x40, 0x01, 0x05, 0x0b, 0x0b }; // try_table catch kind 5
    const bytes = try assemble(a, &.{
        .{ .id = 1, .body = &tbody }, .{ .id = 3, .body = &fbody }, .{ .id = 10, .body = &cbody },
    });
    try testing.expectError(error.BadCatchKind, loadErr(bytes));
}

test "wasm exceptions: catch_ref binds payload and exnref together (multi-value)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // type0 ()->i32; type1 (i32)->() (tag); type2 ()->(i32 exnref) (the multi-value block type).
    const tbody = [_]u8{ 0x03, 0x60, 0x00, 0x01, 0x7f, 0x60, 0x01, 0x7f, 0x00, 0x60, 0x00, 0x02, 0x7f, 0x69 };
    const fbody = [_]u8{ 0x01, 0x00 };
    const gbody = [_]u8{ 0x01, 0x00, 0x01 };
    const xbody = [_]u8{ 0x01, 0x01, 0x66, 0x00, 0x00 };
    // block $h (i32 exnref) { try_table (type2)(catch_ref tag0 -> $h) i32.const 5; throw tag0 end } end
    // $h receives [i32(5), exnref]; drop the exnref, return the payload 5.
    const cbody = [_]u8{ 0x01, 0x11, 0x00, 0x02, 0x02, 0x1f, 0x02, 0x01, 0x01, 0x00, 0x00, 0x41, 0x05, 0x08, 0x00, 0x0b, 0x0b, 0x1a, 0x0b };
    const bytes = try assemble(a, &.{
        .{ .id = 1, .body = &tbody }, .{ .id = 3, .body = &fbody },  .{ .id = 13, .body = &gbody },
        .{ .id = 7, .body = &xbody }, .{ .id = 10, .body = &cbody },
    });
    try testing.expectEqual(@as(i32, 5), try runI32(bytes, "f", &.{}));
}

test "wasm exceptions: a throw unwinds across three frames" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // type0 ()->() (h,g); type1 (i32)->() (tag); type2 ()->i32 (f).
    const tbody = [_]u8{ 0x03, 0x60, 0x00, 0x00, 0x60, 0x01, 0x7f, 0x00, 0x60, 0x00, 0x01, 0x7f };
    const fbody = [_]u8{ 0x03, 0x00, 0x00, 0x02 }; // h:t0, g:t0, f:t2
    const gbody = [_]u8{ 0x01, 0x00, 0x01 }; // tag0:t1
    const xbody = [_]u8{ 0x01, 0x01, 0x66, 0x00, 0x02 }; // export "f" -> func 2
    // h: i32.const 8; throw tag0 | g: call h | f: block(i32){ try_table(i32)(catch tag0 ->blk) call g; i32.const 0 end }
    const cbody = [_]u8{
        0x03,
        0x06,
        0x00,
        0x41,
        0x08,
        0x08,
        0x00,
        0x0b,
        0x04,
        0x00,
        0x10,
        0x00,
        0x0b,
        0x10,
        0x00,
        0x02,
        0x7f,
        0x1f,
        0x7f,
        0x01,
        0x00,
        0x00,
        0x00,
        0x10,
        0x01,
        0x41,
        0x00,
        0x0b,
        0x0b,
        0x0b,
    };
    const bytes = try assemble(a, &.{
        .{ .id = 1, .body = &tbody }, .{ .id = 3, .body = &fbody },  .{ .id = 13, .body = &gbody },
        .{ .id = 7, .body = &xbody }, .{ .id = 10, .body = &cbody },
    });
    try testing.expectEqual(@as(i32, 8), try runI32(bytes, "f", &.{}));
}

test "wasm exceptions: a loop re-entering a try_table does not accumulate handlers" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tbody = [_]u8{ 0x01, 0x60, 0x00, 0x01, 0x7f }; // ()->i32
    const fbody = [_]u8{ 0x01, 0x00 };
    const xbody = [_]u8{ 0x01, 0x01, 0x66, 0x00, 0x00 };
    // (local i32) loop { try_table end ; i++ ; if i<2000 br loop } ; return i
    // 2000 iterations > MAX_HANDLERS (1024): completes only if entry-cleanup pops
    // the prior handler each re-entry (else CallStackExhausted).
    const cbody = [_]u8{
        0x01, 0x1c,
        0x01, 0x01,
        0x7f, 0x03,
        0x40, 0x1f,
        0x40, 0x00,
        0x0b, 0x20,
        0x00, 0x41,
        0x01, 0x6a,
        0x21, 0x00,
        0x20, 0x00,
        0x41, 0xd0,
        0x0f, 0x48,
        0x0d, 0x00,
        0x0b, 0x20,
        0x00, 0x0b,
    };
    const bytes = try assemble(a, &.{
        .{ .id = 1, .body = &tbody }, .{ .id = 3, .body = &fbody },
        .{ .id = 7, .body = &xbody }, .{ .id = 10, .body = &cbody },
    });
    try testing.expectEqual(@as(i32, 2000), try runI32(bytes, "f", &.{}));
}

test "wasm exceptions: throw propagates across a return_call tail call to the grandparent's try_table" {
    // PTC semantics: a `return_call` semantically pops the caller's frame
    // before the callee runs (§4.4.10.1). A throw in the callee unwinds
    // past the (now-gone) caller, so it's the *grandparent's* try_table
    // that catches.
    //
    //   func $G (result i32): block (i32) { try_table (i32) (catch $t -> $h) call $F end } end
    //   func $F:              return_call $F2                  ; caller frame popped first
    //   func $F2:             i32.const 5 ; throw $t            ; payload 5 lands in G's catch
    //
    // (Validates both the host-arm fix and the `tailReplaceFrame`
    // parallel fix that drops the replaced frame's handlers — without
    // them this test would either bogus-match an F-installed handler or
    // crash on a stale stp_idx.)
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tbody = [_]u8{ 0x02, 0x60, 0x00, 0x01, 0x7f, 0x60, 0x01, 0x7f, 0x00 };
    const fbody = [_]u8{ 0x03, 0x00, 0x00, 0x00 }; // 3 funcs, all type 0
    const gbody = [_]u8{ 0x01, 0x00, 0x01 }; // 1 tag, type 1
    const xbody = [_]u8{ 0x01, 0x01, 0x66, 0x00, 0x00 }; // export "f" -> func 0 ($G)
    // func0 G: block (i32) { try_table (i32) (catch tag0 -> $block) call F end } end
    // func1 F: return_call F2
    // func2 F2: i32.const 5; throw tag0
    const cbody = [_]u8{
        0x03, // 3 funcs
        0x0e,
        0x00,
        0x02,
        0x7f,
        0x1f,
        0x7f,
        0x01,
        0x00,
        0x00,
        0x00,
        0x10,
        0x01,
        0x0b,
        0x0b,
        0x0b,
        0x04,
        0x00,
        0x12,
        0x02,
        0x0b,
        0x06,
        0x00,
        0x41,
        0x05,
        0x08,
        0x00,
        0x0b,
    };
    const bytes = try assemble(a, &.{
        .{ .id = 1, .body = &tbody },
        .{ .id = 3, .body = &fbody },
        .{ .id = 13, .body = &gbody },
        .{ .id = 7, .body = &xbody },
        .{ .id = 10, .body = &cbody },
    });
    try testing.expectEqual(@as(i32, 5), try runI32(bytes, "f", &.{}));
}
