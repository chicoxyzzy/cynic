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

    var instance = try interp.instantiate(a, testing.allocator, mp);
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
    var instance = try interp.instantiate(a, testing.allocator, modp);
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
        0x0a, 0x00, 0x00, 0x00, 0x14, 0x00, 0x00, 0x00, 0x1e, 0x00, 0x00, 0x00, 0x28, 0x00, 0x00, 0x00,
        0xfd, 0x1b, 0x02, 0x0b,
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
        0x41, 0x00,
        0xfd, 0x0c, 0x0a, 0x00, 0x00, 0x00, 0x14, 0x00, 0x00, 0x00, 0x1e, 0x00, 0x00, 0x00, 0x28, 0x00, 0x00, 0x00,
        0xfd, 0x0b, 0x04, 0x00, // v128.store align=4 offset=0
        0x41, 0x00,
        0xfd, 0x00, 0x04, 0x00, // v128.load align=4 offset=0
        0xfd, 0x1b, 0x03, 0x0b,
    };
    try testing.expectEqual(@as(i32, 40), asI32(try callCells(&.{}, &.{I32}, &code, "f", 1, &.{})));
}
