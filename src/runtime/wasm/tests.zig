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

test "wasm spasm: a compilable function runs Spasm-compiled with an identical result" {
    if (comptime !@import("spasm.zig").supported) return error.SkipZigTest;
    var buf: [8 + adder_body.len]u8 = undefined;
    const bytes = withPreamble(&buf, &adder_body);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const m = try wasm.decode(a, bytes);
    const mp = try a.create(wasm.Module);
    mp.* = m;

    var instance: interp.Instance = undefined;
    try interp.instantiate(&instance, a, testing.allocator, mp, .{});
    defer instance.deinit();
    instance.spasm_enabled = true; // force the baseline tier

    const fidx = funcExport(mp, "add") orelse return error.NoSuchExport;
    const cells = try a.alloc(u128, 2);
    cells[0] = @as(u128, 7);
    cells[1] = @as(u128, 35);

    const res = try interp.invoke(&instance, testing.allocator, fidx, cells);
    defer testing.allocator.free(res);

    // Same answer as the interpreter (the baseline's whole contract)...
    try testing.expectEqual(@as(u32, 42), @as(u32, @truncate(res[0])));
    // ...and the compiled path was actually taken, not the interpreter.
    try testing.expectEqual(@as(u32, 1), instance.spasm_runs);
}

test "wasm spasm: the per-function code cache compiles once across repeated invokes" {
    if (comptime !@import("spasm.zig").supported) return error.SkipZigTest;
    var buf: [8 + adder_body.len]u8 = undefined;
    const bytes = withPreamble(&buf, &adder_body);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const m = try wasm.decode(a, bytes);
    const mp = try a.create(wasm.Module);
    mp.* = m;

    var instance: interp.Instance = undefined;
    try interp.instantiate(&instance, a, testing.allocator, mp, .{});
    defer instance.deinit();
    instance.spasm_enabled = true; // force the baseline tier

    const fidx = funcExport(mp, "add") orelse return error.NoSuchExport;
    const cells = try a.alloc(u128, 2);
    cells[0] = @as(u128, 7);
    cells[1] = @as(u128, 35);

    // Repeated invokes of the same function each run native code, but the
    // function is compiled exactly once and its EntryFn reused — the
    // whole point of the per-function code cache.
    var i: usize = 0;
    while (i < 3) : (i += 1) {
        const res = try interp.invoke(&instance, testing.allocator, fidx, cells);
        defer testing.allocator.free(res);
        try testing.expectEqual(@as(u32, 42), @as(u32, @truncate(res[0])));
    }

    try testing.expectEqual(@as(u32, 3), instance.spasm_runs);
    try testing.expectEqual(@as(u32, 1), instance.spasm_compiles);
}

// An `(i32,i32)->i32` signed-divide module exported as "div" — the body
// is `local.get 0; local.get 1; i32.div_s; end`.
const div_s_body = [_]u8{
    0x01, 0x07, 0x01, 0x60, 0x02, 0x7f, 0x7f, 0x01, 0x7f, // type (i32,i32)->i32
    0x03, 0x02, 0x01, 0x00, // func 0 : type 0
    0x07, 0x07, 0x01, 0x03, 0x64, 0x69, 0x76, 0x00, 0x00, // export "div" -> 0
    0x0a, 0x09, 0x01, 0x07, 0x00, 0x20, 0x00, 0x20, 0x01, 0x6d, 0x0b, // local.get 0; local.get 1; i32.div_s; end
};

test "wasm spasm: i32.div_s compiles and runs Spasm-compiled" {
    if (comptime !@import("spasm.zig").supported) return error.SkipZigTest;
    var buf: [8 + div_s_body.len]u8 = undefined;
    const bytes = withPreamble(&buf, &div_s_body);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const m = try wasm.decode(a, bytes);
    const mp = try a.create(wasm.Module);
    mp.* = m;

    var instance: interp.Instance = undefined;
    try interp.instantiate(&instance, a, testing.allocator, mp, .{});
    defer instance.deinit();
    instance.spasm_enabled = true;

    const fidx = funcExport(mp, "div") orelse return error.NoSuchExport;
    const cells = try a.alloc(u128, 2);
    cells[0] = @as(u128, 20);
    cells[1] = @as(u128, 4);

    const res = try interp.invoke(&instance, testing.allocator, fidx, cells);
    defer testing.allocator.free(res);

    // 20 / 4 == 5, computed by Spasm-compiled native code (not degraded).
    try testing.expectEqual(@as(u32, 5), @as(u32, @truncate(res[0])));
    try testing.expect(instance.spasm_runs >= 1);
}

test "wasm spasm: a direct call to a leaf function runs Spasm-compiled" {
    // §4.4.1 / §5.4.1 — `call fidx` (the first non-leaf Spasm op). Two
    // `(i32)->i32` functions: func 0 "main" calls func 1 (a leaf that
    // squares its argument). Before the call arm shipped, "main" was
    // non-emittable and degraded — the interpreter ran it and interpreted
    // the callee inline, so `spasm_runs` stayed 0. With the call arm,
    // "main" runs via Spasm and its helper re-enters `invoke`, which runs
    // the leaf via Spasm too.
    if (comptime !@import("spasm.zig").supported) return error.SkipZigTest;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // type 0: (i32)->(i32)
    const tbody = [_]u8{ 0x01, 0x60, 0x01, 0x7f, 0x01, 0x7f };
    // func section: two funcs, both type 0
    const fbody = [_]u8{ 0x02, 0x00, 0x00 };
    // export "main" -> func 0
    const xbody = [_]u8{ 0x01, 0x04, 'm', 'a', 'i', 'n', 0x00, 0x00 };
    // code section: two bodies.
    //   func 0 (main):   locals(0) local.get 0; call 1; end
    //   func 1 (square): locals(0) local.get 0; local.get 0; i32.mul; end
    const cbody = [_]u8{
        0x02, // two code entries
        0x06, 0x00, 0x20, 0x00, 0x10, 0x01, 0x0b, // main: 6 bytes
        0x07, 0x00, 0x20, 0x00, 0x20, 0x00, 0x6c, 0x0b, // square: 7 bytes
    };
    const bytes = try assemble(a, &.{
        .{ .id = 1, .body = &tbody },
        .{ .id = 3, .body = &fbody },
        .{ .id = 7, .body = &xbody },
        .{ .id = 10, .body = &cbody },
    });

    const m = try wasm.decode(a, bytes);
    const mp = try a.create(wasm.Module);
    mp.* = m;

    var instance: interp.Instance = undefined;
    try interp.instantiate(&instance, a, testing.allocator, mp, .{});
    defer instance.deinit();
    instance.spasm_enabled = true; // force the baseline tier

    const fidx = funcExport(mp, "main") orelse return error.NoSuchExport;
    const cells = try a.alloc(u128, 1);
    cells[0] = @as(u128, 5);

    const res = try interp.invoke(&instance, testing.allocator, fidx, cells);
    defer testing.allocator.free(res);

    // square(5) == 25, the same answer the interpreter gives...
    try testing.expectEqual(@as(u32, 25), @as(u32, @truncate(res[0])));
    // ...and "main" (which has a `call`) ran Spasm-compiled, not degraded.
    try testing.expect(instance.spasm_runs >= 1);
}

test "wasm spasm: a call with a live operand under the args runs Spasm-compiled" {
    // §5.4.1 — a `call` whose result feeds a pending operand. "main"
    // computes x + square(x): it keeps a copy of x on the operand stack
    // *under* the call's argument, so at the call site the stack is deeper
    // than the callee's arity (sp=2, nparams=1). The call arm must spill the
    // live operand below the args across the helper call and reload it
    // after, then `i32.add` it to the result. Before this, a deeper-than-
    // arity stack at a call degraded to the interpreter.
    if (comptime !@import("spasm.zig").supported) return error.SkipZigTest;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // type 0: (i32)->(i32)
    const tbody = [_]u8{ 0x01, 0x60, 0x01, 0x7f, 0x01, 0x7f };
    // func section: two funcs, both type 0
    const fbody = [_]u8{ 0x02, 0x00, 0x00 };
    // export "main" -> func 0
    const xbody = [_]u8{ 0x01, 0x04, 'm', 'a', 'i', 'n', 0x00, 0x00 };
    // code section: two bodies.
    //   func 0 (main):   local.get 0; local.get 0; call 1; i32.add; end
    //   func 1 (square): local.get 0; local.get 0; i32.mul; end
    const cbody = [_]u8{
        0x02, // two code entries
        0x09, 0x00, 0x20, 0x00, 0x20, 0x00, 0x10, 0x01, 0x6a, 0x0b, // main: 9 bytes
        0x07, 0x00, 0x20, 0x00, 0x20, 0x00, 0x6c, 0x0b, // square: 7 bytes
    };
    const bytes = try assemble(a, &.{
        .{ .id = 1, .body = &tbody },
        .{ .id = 3, .body = &fbody },
        .{ .id = 7, .body = &xbody },
        .{ .id = 10, .body = &cbody },
    });

    const m = try wasm.decode(a, bytes);
    const mp = try a.create(wasm.Module);
    mp.* = m;

    var instance: interp.Instance = undefined;
    try interp.instantiate(&instance, a, testing.allocator, mp, .{});
    defer instance.deinit();
    instance.spasm_enabled = true; // force the baseline tier

    const fidx = funcExport(mp, "main") orelse return error.NoSuchExport;
    const cells = try a.alloc(u128, 1);
    cells[0] = @as(u128, 5);

    const res = try interp.invoke(&instance, testing.allocator, fidx, cells);
    defer testing.allocator.free(res);

    // 5 + square(5) == 5 + 25 == 30, the same answer the interpreter gives...
    try testing.expectEqual(@as(u32, 30), @as(u32, @truncate(res[0])));
    // ...and "main" (deeper-than-arity stack at the call) ran Spasm-compiled.
    try testing.expect(instance.spasm_runs >= 1);
}

test "wasm spasm: a constant under an if/else with calls in both arms is not corrupted" {
    // §5.4.1 regression (the if.json `as-select-mid`/`as-store-last` class).
    // main(x) = 7 + (if x then { dummy(); 1 } else { dummy(); 0 }). The
    // constant 7 sits *below* the if-block; both arms contain a `call`, so
    // the call's below-operand handling runs on each arm. A constant
    // below-operand must NOT be materialized-and-pinned by the call: doing
    // so on the then-arm (compiled first) would leak a `.reg` Loc into the
    // else-arm, whose path never ran the `mov`, so main(0) would read a
    // garbage "7". The const must stay a const, re-materialized after the
    // call on whichever arm runs. main(0) == 7 (else), main(1) == 8 (then).
    if (comptime !@import("spasm.zig").supported) return error.SkipZigTest;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // type 0: (i32)->(i32); type 1: ()->()
    const tbody = [_]u8{ 0x02, 0x60, 0x01, 0x7f, 0x01, 0x7f, 0x60, 0x00, 0x00 };
    // func section: func0 "main" type0, func1 "dummy" type1
    const fbody = [_]u8{ 0x02, 0x00, 0x01 };
    // export "main" -> func 0
    const xbody = [_]u8{ 0x01, 0x04, 'm', 'a', 'i', 'n', 0x00, 0x00 };
    // code section: two bodies.
    //   func 0 (main): i32.const 7; local.get 0; if (result i32);
    //     then: call 1; i32.const 1; else: call 1; i32.const 0; end;
    //     i32.add; end
    //   func 1 (dummy): end
    const cbody = [_]u8{
        0x02, // two code entries
        0x13, 0x00, // main: 19 bytes, 0 locals
        0x41, 0x07, 0x20, 0x00, 0x04, 0x7f, 0x10, 0x01, 0x41, 0x01,
        0x05, 0x10, 0x01, 0x41, 0x00, 0x0b, 0x6a, 0x0b,
        0x02, 0x00, 0x0b, // dummy: 2 bytes, 0 locals, end
    };
    const bytes = try assemble(a, &.{
        .{ .id = 1, .body = &tbody },
        .{ .id = 3, .body = &fbody },
        .{ .id = 7, .body = &xbody },
        .{ .id = 10, .body = &cbody },
    });

    const m = try wasm.decode(a, bytes);
    const mp = try a.create(wasm.Module);
    mp.* = m;

    var instance: interp.Instance = undefined;
    try interp.instantiate(&instance, a, testing.allocator, mp, .{});
    defer instance.deinit();
    instance.spasm_enabled = true; // force the baseline tier

    const fidx = funcExport(mp, "main") orelse return error.NoSuchExport;
    inline for (.{ .{ 0, 7 }, .{ 1, 8 } }) |case| {
        const cells = try a.alloc(u128, 1);
        cells[0] = @as(u128, case[0]);
        const res = try interp.invoke(&instance, testing.allocator, fidx, cells);
        defer testing.allocator.free(res);
        try testing.expectEqual(@as(u32, case[1]), @as(u32, @truncate(res[0])));
    }
    // "main" (a `call` under an `if`) ran Spasm-compiled, not degraded.
    try testing.expect(instance.spasm_runs >= 1);
}

test "wasm spasm: call_indirect dispatches through a table, runs Spasm-compiled" {
    // §5.4.1 — `call_indirect` reads a function reference from a table at a
    // runtime index, type-checks it, and calls it. main(x) loads x, pushes
    // the table index 0, and `call_indirect (type 0)`s — table[0] is
    // `add10`, so main(x) == x + 10. The index is the top operand (consumed);
    // the arg sits under it. A Spasm `call_indirect` resolves the element +
    // type via a native helper, then dispatches like a direct call.
    if (comptime !@import("spasm.zig").supported) return error.SkipZigTest;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // type 0: (i32)->(i32)
    const tbody = [_]u8{ 0x01, 0x60, 0x01, 0x7f, 0x01, 0x7f };
    // func section: func0 "add10" type0, func1 "main" type0
    const fbody = [_]u8{ 0x02, 0x00, 0x00 };
    // table section: 1 table, funcref (0x70), limits min-only (0x00) min 1
    const tablebody = [_]u8{ 0x01, 0x70, 0x00, 0x01 };
    // export "main" -> func 1
    const xbody = [_]u8{ 0x01, 0x04, 'm', 'a', 'i', 'n', 0x00, 0x01 };
    // element section: 1 active segment, table 0, offset (i32.const 0),
    // funcs [0 (add10)]
    const ebody = [_]u8{ 0x01, 0x00, 0x41, 0x00, 0x0b, 0x01, 0x00 };
    // code section: two bodies.
    //   func 0 (add10): local.get 0; i32.const 10; i32.add; end
    //   func 1 (main):  local.get 0; i32.const 0; call_indirect 0 0; end
    const cbody = [_]u8{
        0x02, // two code entries
        0x07, 0x00, 0x20, 0x00, 0x41, 0x0a, 0x6a, 0x0b, // add10: 7 bytes
        0x09, 0x00, 0x20, 0x00, 0x41, 0x00, 0x11, 0x00, 0x00, 0x0b, // main: 9 bytes
    };
    const bytes = try assemble(a, &.{
        .{ .id = 1, .body = &tbody },
        .{ .id = 3, .body = &fbody },
        .{ .id = 4, .body = &tablebody },
        .{ .id = 7, .body = &xbody },
        .{ .id = 9, .body = &ebody },
        .{ .id = 10, .body = &cbody },
    });

    const m = try wasm.decode(a, bytes);
    const mp = try a.create(wasm.Module);
    mp.* = m;

    var instance: interp.Instance = undefined;
    try interp.instantiate(&instance, a, testing.allocator, mp, .{});
    defer instance.deinit();
    instance.spasm_enabled = true; // force the baseline tier

    const fidx = funcExport(mp, "main") orelse return error.NoSuchExport;
    const cells = try a.alloc(u128, 1);
    cells[0] = @as(u128, 5);
    const res = try interp.invoke(&instance, testing.allocator, fidx, cells);
    defer testing.allocator.free(res);

    // table[0] == add10, add10(5) == 15, the same the interpreter gives...
    try testing.expectEqual(@as(u32, 15), @as(u32, @truncate(res[0])));
    // ...and "main" (a `call_indirect`) ran Spasm-compiled, not degraded.
    try testing.expect(instance.spasm_runs >= 1);
}

test "wasm spasm: ref.is_null folds ref.null to 1 and ref.func to 0, runs Spasm-compiled" {
    // §4.2.4 / §5.4.2 — the reference-type producers `ref.null t` and
    // `ref.func f` are both compile-time-known: `ref.null` is always the
    // null reference, and `ref.func f` names a defined function, so it is
    // always non-null. `ref.is_null` (§4.2.4) therefore folds at compile
    // time — its operand's nullity is statically known — to the i32 result
    // 1 (for `ref.null`) or 0 (for `ref.func`), with no runtime 128-bit
    // reference value materialized. Both functions return i32, so the body
    // never has to place a reference into a runtime location; the slice
    // stays inside the scalar operand bank.
    if (comptime !@import("spasm.zig").supported) return error.SkipZigTest;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // type 0: ()->(i32)
    const tbody = [_]u8{ 0x01, 0x60, 0x00, 0x01, 0x7f };
    // func section: two funcs, both type 0
    const fbody = [_]u8{ 0x02, 0x00, 0x00 };
    // export both funcs — an export puts the index in §3.4.1.3's reference
    // set, so `ref.func 0` below validates as a declared reference.
    const xbody = [_]u8{
        0x02,
        0x0c, 'i', 's', '_', 'n', 'u', 'l', 'l', '_', 'n', 'u', 'l', 'l', 0x00, 0x00,
        0x0c, 'i', 's', '_', 'n', 'u', 'l', 'l', '_', 'f', 'u', 'n', 'c', 0x00, 0x01,
    };
    // code section: two bodies.
    //   func 0 (is_null_of_null): ref.null func; ref.is_null; end
    //   func 1 (is_null_of_func): ref.func 0;     ref.is_null; end
    const cbody = [_]u8{
        0x02, // two code entries
        0x05, 0x00, 0xd0, 0x70, 0xd1, 0x0b, // is_null_of_null: 5 bytes
        0x05, 0x00, 0xd2, 0x00, 0xd1, 0x0b, // is_null_of_func: 5 bytes
    };
    const bytes = try assemble(a, &.{
        .{ .id = 1, .body = &tbody },
        .{ .id = 3, .body = &fbody },
        .{ .id = 7, .body = &xbody },
        .{ .id = 10, .body = &cbody },
    });

    const m = try wasm.decode(a, bytes);
    const mp = try a.create(wasm.Module);
    mp.* = m;

    var instance: interp.Instance = undefined;
    try interp.instantiate(&instance, a, testing.allocator, mp, .{});
    defer instance.deinit();
    instance.spasm_enabled = true; // force the baseline tier

    const null_idx = funcExport(mp, "is_null_null") orelse return error.NoSuchExport;
    const func_idx = funcExport(mp, "is_null_func") orelse return error.NoSuchExport;

    const r_null = try interp.invoke(&instance, testing.allocator, null_idx, &.{});
    defer testing.allocator.free(r_null);
    const r_func = try interp.invoke(&instance, testing.allocator, func_idx, &.{});
    defer testing.allocator.free(r_func);

    // ref.is_null(ref.null func) == 1; ref.is_null(ref.func $f) == 0.
    try testing.expectEqual(@as(u32, 1), @as(u32, @truncate(r_null[0])));
    try testing.expectEqual(@as(u32, 0), @as(u32, @truncate(r_func[0])));
    // Both ran Spasm-compiled (the fold emitted real native code), not degraded.
    try testing.expect(instance.spasm_runs >= 1);
}

test "wasm spasm: a self-recursive call traps CallStackExhausted, never crashes" {
    // Host-safety (AGENTS.md never-abort-the-host): a Spasm-compiled body
    // that recurses unboundedly nests `invoke` on the *native* stack via
    // the call helper. Without the depth guard that is a SIGSEGV; the
    // guard must turn pathological depth into a catchable trap instead.
    // The function `f(n)` returns 0 at n==0 and otherwise calls f(n-1):
    //   block (result i32)
    //     local.get 0; i32.eqz; br_if 0 (drop-through pushes 0? no —)
    //   ...
    // Simpler shape: `local.get 0; if (result i32) ... else 0 end`. We
    // hand-assemble: if n==0 return 0, else return f(n-1).
    if (comptime !@import("spasm.zig").supported) return error.SkipZigTest;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // type 0: (i32)->(i32)
    const tbody = [_]u8{ 0x01, 0x60, 0x01, 0x7f, 0x01, 0x7f };
    const fbody = [_]u8{ 0x01, 0x00 }; // one func, type 0
    const xbody = [_]u8{ 0x01, 0x03, 'r', 'e', 'c', 0x00, 0x00 }; // export "rec" -> 0
    // f(n): if (n == 0) 0 else f(n - 1)
    //   local.get 0            20 00
    //   i32.eqz                45
    //   if (result i32)        04 7f
    //     i32.const 0          41 00
    //   else                   05
    //     local.get 0          20 00
    //     i32.const 1          41 01
    //     i32.sub              6b
    //     call 0               10 00
    //   end                    0b
    //   end                    0b   (function body end)
    const expr = [_]u8{
        0x20, 0x00, 0x45, 0x04, 0x7f, 0x41, 0x00, 0x05,
        0x20, 0x00, 0x41, 0x01, 0x6b, 0x10, 0x00, 0x0b,
        0x0b,
    };
    var cb: List = .empty;
    try cb.append(a, 0x01); // one code entry
    try uleb(a, &cb, expr.len + 1); // body size: locals header (1) + expr
    try cb.append(a, 0x00); // locals(0)
    try cb.appendSlice(a, &expr);
    const bytes = try assemble(a, &.{
        .{ .id = 1, .body = &tbody },
        .{ .id = 3, .body = &fbody },
        .{ .id = 7, .body = &xbody },
        .{ .id = 10, .body = cb.items },
    });

    const m = try wasm.decode(a, bytes);
    const mp = try a.create(wasm.Module);
    mp.* = m;

    var instance: interp.Instance = undefined;
    try interp.instantiate(&instance, a, testing.allocator, mp, .{});
    defer instance.deinit();
    instance.spasm_enabled = true;

    const fidx = funcExport(mp, "rec") orelse return error.NoSuchExport;

    // Safe depth returns normally (the recursion bottoms out at n==0).
    {
        const cells = try a.alloc(u128, 1);
        cells[0] = @as(u128, 8);
        const res = try interp.invoke(&instance, testing.allocator, fidx, cells);
        defer testing.allocator.free(res);
        try testing.expectEqual(@as(u32, 0), @as(u32, @truncate(res[0])));
    }

    // Pathological depth traps (a catchable error), it does not SIGSEGV.
    {
        const cells = try a.alloc(u128, 1);
        cells[0] = @as(u128, 1_000_000); // far past the native-stack guard
        try testing.expectError(error.CallStackExhausted, interp.invoke(&instance, testing.allocator, fidx, cells));
    }
}

/// Run the Spasm-compiled "div" export of `div_s_body` with `(a, b)` and
/// return whatever `invoke` returns — a result slice or a trap error.
fn runSpasmDiv(a_alloc: std.mem.Allocator, arg_a: u32, arg_b: u32) ![]u128 {
    var buf: [8 + div_s_body.len]u8 = undefined;
    const bytes = withPreamble(&buf, &div_s_body);
    const m = try wasm.decode(a_alloc, bytes);
    const mp = try a_alloc.create(wasm.Module);
    mp.* = m;
    var instance: interp.Instance = undefined;
    try interp.instantiate(&instance, a_alloc, testing.allocator, mp, .{});
    defer instance.deinit();
    instance.spasm_enabled = true;
    const fidx = funcExport(mp, "div") orelse return error.NoSuchExport;
    const cells = try a_alloc.alloc(u128, 2);
    cells[0] = @as(u128, arg_a);
    cells[1] = @as(u128, arg_b);
    return interp.invoke(&instance, testing.allocator, fidx, cells);
}

test "wasm spasm: i32.div_s by zero raises a catchable divide-by-zero trap" {
    if (comptime !@import("spasm.zig").supported) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // The Spasm-compiled body's explicit b==0 check (AArch64 sdiv would
    // otherwise return 0) routes through the trap channel to this error.
    try testing.expectError(error.IntegerDivideByZero, runSpasmDiv(arena.allocator(), 1, 0));
}

test "wasm spasm: i32.div_s INT_MIN / -1 raises a catchable integer-overflow trap" {
    if (comptime !@import("spasm.zig").supported) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // INT_MIN / -1 overflows i32; AArch64 sdiv returns INT_MIN, so the
    // explicit overflow check is what produces the spec-mandated trap.
    try testing.expectError(error.IntegerOverflow, runSpasmDiv(arena.allocator(), 0x8000_0000, 0xFFFF_FFFF));
}

// A module with one page of memory exporting `load`/`store`:
//   (func (param i32) (result i32) local.get 0  i32.load  align=2 off=0)
//   (func (param i32 i32)          local.get 0  local.get 1  i32.store)
const mem_module_body = [_]u8{
    // type section (payload 11): type 0 = (i32)->i32, type 1 = (i32,i32)->()
    0x01, 0x0b, 0x02, 0x60, 0x01, 0x7f, 0x01, 0x7f, 0x60, 0x02, 0x7f, 0x7f, 0x00,
    // func section: func 0 : type 0, func 1 : type 1
    0x03, 0x03, 0x02, 0x00, 0x01,
    // memory section: one page, no max
    0x05, 0x03, 0x01, 0x00, 0x01,
    // export section (payload 16): "load" -> 0, "store" -> 1
    0x07, 0x10, 0x02,
    0x04, 0x6c, 0x6f, 0x61, 0x64, 0x00, 0x00, 0x05, 0x73, 0x74, 0x6f, 0x72, 0x65,
    0x00, 0x01,
    // code section (payload 19)
    0x0a, 0x13, 0x02,
    0x07, 0x00, 0x20, 0x00, 0x28, 0x02, 0x00, 0x0b, // load (body 7): local.get 0; i32.load a=2 o=0; end
    0x09, 0x00, 0x20, 0x00, 0x20, 0x01, 0x36, 0x02, 0x00, 0x0b, // store (body 9): local.get 0; local.get 1; i32.store a=2 o=0; end
};

test "wasm spasm: i32.load compiles and reads linear memory" {
    if (comptime !@import("spasm.zig").supported) return error.SkipZigTest;
    var buf: [8 + mem_module_body.len]u8 = undefined;
    const bytes = withPreamble(&buf, &mem_module_body);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const m = try wasm.decode(a, bytes);
    const mp = try a.create(wasm.Module);
    mp.* = m;

    var instance: interp.Instance = undefined;
    try interp.instantiate(&instance, a, testing.allocator, mp, .{});
    defer instance.deinit();
    instance.spasm_enabled = true;

    // Seed four bytes at offset 8, then load them back through Spasm.
    std.mem.writeInt(u32, instance.memories[0].data[8..][0..4], 0xCAFE_BABE, .little);
    const fidx = funcExport(mp, "load") orelse return error.NoSuchExport;
    const cells = try a.alloc(u128, 1);
    cells[0] = @as(u128, 8);

    const res = try interp.invoke(&instance, testing.allocator, fidx, cells);
    defer testing.allocator.free(res);

    try testing.expectEqual(@as(u32, 0xCAFE_BABE), @as(u32, @truncate(res[0])));
    try testing.expect(instance.spasm_runs >= 1);
}

/// Decode + instantiate `mem_module_body` (caller owns `bytes`, which the
/// decoded module borrows), forcing Spasm on. Returns the module handle.
fn setupMemModule(instance: *interp.Instance, a: std.mem.Allocator, bytes: []const u8) !*wasm.Module {
    const m = try wasm.decode(a, bytes);
    const mp = try a.create(wasm.Module);
    mp.* = m;
    try interp.instantiate(instance, a, testing.allocator, mp, .{});
    instance.spasm_enabled = true;
    return mp;
}

test "wasm spasm: i32.store compiles and writes linear memory" {
    if (comptime !@import("spasm.zig").supported) return error.SkipZigTest;
    var buf: [8 + mem_module_body.len]u8 = undefined;
    const bytes = withPreamble(&buf, &mem_module_body);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var instance: interp.Instance = undefined;
    const mp = try setupMemModule(&instance, a, bytes);
    defer instance.deinit();

    const fidx = funcExport(mp, "store") orelse return error.NoSuchExport;
    const cells = try a.alloc(u128, 2);
    cells[0] = @as(u128, 16); // address
    cells[1] = @as(u128, 0xDEAD_BEEF); // value

    const res = try interp.invoke(&instance, testing.allocator, fidx, cells);
    defer testing.allocator.free(res);

    // The Spasm-compiled store landed the bytes at offset 16.
    try testing.expectEqual(@as(u32, 0xDEAD_BEEF), std.mem.readInt(u32, instance.memories[0].data[16..][0..4], .little));
    try testing.expect(instance.spasm_runs >= 1);
}

test "wasm spasm: an out-of-bounds load raises a catchable trap" {
    if (comptime !@import("spasm.zig").supported) return error.SkipZigTest;
    var buf: [8 + mem_module_body.len]u8 = undefined;
    const bytes = withPreamble(&buf, &mem_module_body);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var instance: interp.Instance = undefined;
    const mp = try setupMemModule(&instance, a, bytes);
    defer instance.deinit();

    const fidx = funcExport(mp, "load") orelse return error.NoSuchExport;
    const cells = try a.alloc(u128, 1);
    // One page is 65536 bytes; a 4-byte load at 65536 runs off the end and
    // the compiled bounds check routes it through the trap channel.
    cells[0] = @as(u128, 65536);

    try testing.expectError(error.OutOfBoundsMemoryAccess, interp.invoke(&instance, testing.allocator, fidx, cells));
}

// A one-page-memory module exporting the sub-width accessors:
//   "lu" (i32)->i32     : local.get 0  i32.load8_u
//   "ls" (i32)->i32     : local.get 0  i32.load8_s
//   "s8" (i32,i32)->()  : local.get 0  local.get 1  i32.store8
const subwidth_module_body = [_]u8{
    // type (payload 11): type0=(i32)->i32, type1=(i32,i32)->()
    0x01, 0x0b, 0x02, 0x60, 0x01, 0x7f, 0x01, 0x7f, 0x60, 0x02, 0x7f, 0x7f, 0x00,
    // func: 3 funcs (types 0,0,1)
    0x03, 0x04, 0x03, 0x00, 0x00, 0x01,
    // memory: one page
    0x05, 0x03, 0x01, 0x00, 0x01,
    // export (payload 16): "lu"->0, "ls"->1, "s8"->2
    0x07, 0x10,
    0x03, 0x02, 0x6c, 0x75, 0x00, 0x00, 0x02, 0x6c, 0x73, 0x00, 0x01, 0x02, 0x73,
    0x38, 0x00, 0x02,
    // code (payload 27)
    0x0a, 0x1b, 0x03,
    0x07, 0x00, 0x20, 0x00, 0x2d, 0x00, 0x00, 0x0b, // lu: local.get 0; i32.load8_u; end
    0x07, 0x00, 0x20, 0x00, 0x2c, 0x00, 0x00, 0x0b, // ls: local.get 0; i32.load8_s; end
    0x09, 0x00, 0x20, 0x00, 0x20, 0x01, 0x3a, 0x00, 0x00, 0x0b, // s8: local.get 0; local.get 1; i32.store8; end
};

test "wasm spasm: i32.load8_u compiles and zero-extends a byte" {
    if (comptime !@import("spasm.zig").supported) return error.SkipZigTest;
    var buf: [8 + subwidth_module_body.len]u8 = undefined;
    const bytes = withPreamble(&buf, &subwidth_module_body);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var instance: interp.Instance = undefined;
    const mp = try setupMemModule(&instance, a, bytes);
    defer instance.deinit();

    instance.memories[0].data[5] = 0xFF;
    const fidx = funcExport(mp, "lu") orelse return error.NoSuchExport;
    const cells = try a.alloc(u128, 1);
    cells[0] = @as(u128, 5);

    const res = try interp.invoke(&instance, testing.allocator, fidx, cells);
    defer testing.allocator.free(res);

    // 0xFF zero-extended is 255, computed by Spasm-compiled native code.
    try testing.expectEqual(@as(u32, 0xFF), @as(u32, @truncate(res[0])));
    try testing.expect(instance.spasm_runs >= 1);
}

// A one-page-memory module whose `(i32)->i32` export "fl" fills bytes
// [0,4) with 0xAB (the 0xFC-prefixed memory.fill, sub-opcode 11) then
// loads the byte at the argument offset back, to witness the fill.
const memfill_body = [_]u8{
    0x01, 0x06, 0x01, 0x60, 0x01, 0x7f, 0x01, 0x7f, // type (i32)->i32
    0x03, 0x02, 0x01, 0x00, // func 0 : type 0
    0x05, 0x03, 0x01, 0x00, 0x01, // memory: 1 page
    0x07, 0x06, 0x01, 0x02, 0x66, 0x6c, 0x00, 0x00, // export "fl" -> 0
    0x0a, 0x13, 0x01, 0x11, // code: 1 func, body size 17
    0x00, // 0 locals
    0x41, 0x00, // i32.const 0 (dst)
    0x41, 0xab, 0x01, // i32.const 171 (val)
    0x41, 0x04, // i32.const 4 (n)
    0xfc, 0x0b, 0x00, // memory.fill (memory 0)
    0x20, 0x00, // local.get 0
    0x2d, 0x00, 0x00, // i32.load8_u align=0 offset=0
    0x0b, // end
};

test "wasm spasm: memory.fill writes the byte range, then loads it back" {
    if (comptime !@import("spasm.zig").supported) return error.SkipZigTest;
    var buf: [8 + memfill_body.len]u8 = undefined;
    const bytes = withPreamble(&buf, &memfill_body);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var instance: interp.Instance = undefined;
    const mp = try setupMemModule(&instance, a, bytes);
    defer instance.deinit();

    const fidx = funcExport(mp, "fl") orelse return error.NoSuchExport;
    const cells = try a.alloc(u128, 1);
    cells[0] = @as(u128, 2); // read back byte index 2, inside the filled range

    const res = try interp.invoke(&instance, testing.allocator, fidx, cells);
    defer testing.allocator.free(res);

    // memory.fill set bytes 0..3 to 0xAB; the load8_u reads 0xAB (171).
    try testing.expectEqual(@as(u32, 0xab), @as(u32, @truncate(res[0])));
    try testing.expect(instance.spasm_runs >= 1);
}

// A one-page-memory module whose `(i32)->i32` export "cp" copies 4 bytes
// from src=0 to dst=8 (the 0xFC-prefixed memory.copy, sub-opcode 10) then
// loads the byte at the argument offset back.
const memcopy_body = [_]u8{
    0x01, 0x06, 0x01, 0x60, 0x01, 0x7f, 0x01, 0x7f, // type (i32)->i32
    0x03, 0x02, 0x01, 0x00, // func 0 : type 0
    0x05, 0x03, 0x01, 0x00, 0x01, // memory: 1 page
    0x07, 0x06, 0x01, 0x02, 0x63, 0x70, 0x00, 0x00, // export "cp" -> 0
    0x0a, 0x13, 0x01, 0x11, // code: 1 func, body size 17
    0x00, // 0 locals
    0x41, 0x08, // i32.const 8 (dst)
    0x41, 0x00, // i32.const 0 (src)
    0x41, 0x04, // i32.const 4 (n)
    0xfc, 0x0a, 0x00, 0x00, // memory.copy (dst memory 0, src memory 0)
    0x20, 0x00, // local.get 0
    0x2d, 0x00, 0x00, // i32.load8_u align=0 offset=0
    0x0b, // end
};

test "wasm spasm: memory.copy moves a byte range" {
    if (comptime !@import("spasm.zig").supported) return error.SkipZigTest;
    var buf: [8 + memcopy_body.len]u8 = undefined;
    const bytes = withPreamble(&buf, &memcopy_body);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var instance: interp.Instance = undefined;
    const mp = try setupMemModule(&instance, a, bytes);
    defer instance.deinit();

    // Source bytes the copy will move from [0,4) to [8,12).
    instance.memories[0].data[0] = 0x11;
    instance.memories[0].data[1] = 0x22;
    instance.memories[0].data[2] = 0x33;
    instance.memories[0].data[3] = 0x44;

    const fidx = funcExport(mp, "cp") orelse return error.NoSuchExport;
    const cells = try a.alloc(u128, 1);
    cells[0] = @as(u128, 9); // read dst+1 == byte copied from src+1 (0x22)

    const res = try interp.invoke(&instance, testing.allocator, fidx, cells);
    defer testing.allocator.free(res);

    // dst byte 9 holds what was at src byte 1, 0x22.
    try testing.expectEqual(@as(u32, 0x22), @as(u32, @truncate(res[0])));
    try testing.expect(instance.spasm_runs >= 1);
}

test "wasm spasm: memory.init copies from a passive data segment, then data.drop empties it" {
    // §4.4.7 memory.init (0xFC sub 8) + §4.4.7 data.drop (0xFC sub 9). The
    // module carries a passive data segment [0x11,0x22,0x33,0x44] and a
    // data-count section (id 12, required for the two ops to validate).
    //   "mi"(x): memory.init copies the 4 segment bytes from src=0 to dst=8,
    //            then loads the byte at offset x — proving the copy landed.
    //   "dr"():  data.drop 0, then returns 42 — proving the op compiled.
    // Both must run Spasm-compiled (spasm_runs counts each compiled entry).
    if (comptime !@import("spasm.zig").supported) return error.SkipZigTest;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // type 0: (i32)->i32  (mi);  type 1: ()->i32  (dr)
    const tbody = [_]u8{ 0x02, 0x60, 0x01, 0x7f, 0x01, 0x7f, 0x60, 0x00, 0x01, 0x7f };
    // func section: func0 type0, func1 type1
    const fbody = [_]u8{ 0x02, 0x00, 0x01 };
    // memory section: 1 memory, min-only, min 1 page
    const membody = [_]u8{ 0x01, 0x00, 0x01 };
    // export "mi" -> func0, "dr" -> func1
    const xbody = [_]u8{ 0x02, 0x02, 'm', 'i', 0x00, 0x00, 0x02, 'd', 'r', 0x00, 0x01 };
    // data-count section (id 12): one data segment
    const dcbody = [_]u8{0x01};
    // code section: two bodies.
    //   func0 (mi): i32.const 8; i32.const 0; i32.const 4; memory.init 0 0;
    //               local.get 0; i32.load8_u align=0 offset=0; end
    //   func1 (dr): data.drop 0; i32.const 42; end
    const cbody = [_]u8{
        0x02, // two code entries
        0x11, 0x00, // mi: 17 bytes, 0 locals
        0x41, 0x08, 0x41, 0x00, 0x41, 0x04, 0xfc, 0x08, 0x00, 0x00,
        0x20, 0x00, 0x2d, 0x00, 0x00, 0x0b,
        0x07, 0x00, // dr: 7 bytes, 0 locals
        0xfc, 0x09, 0x00, 0x41, 0x2a, 0x0b,
    };
    // data section (id 11): 1 passive segment, 4 bytes [0x11,0x22,0x33,0x44]
    const dbody = [_]u8{ 0x01, 0x01, 0x04, 0x11, 0x22, 0x33, 0x44 };
    const bytes = try assemble(a, &.{
        .{ .id = 1, .body = &tbody },
        .{ .id = 3, .body = &fbody },
        .{ .id = 5, .body = &membody },
        .{ .id = 7, .body = &xbody },
        .{ .id = 12, .body = &dcbody },
        .{ .id = 10, .body = &cbody },
        .{ .id = 11, .body = &dbody },
    });

    var instance: interp.Instance = undefined;
    const mp = try setupMemModule(&instance, a, bytes);
    defer instance.deinit();

    // memory.init copied [0x11,0x22,0x33,0x44] to [8,12); read back byte 9.
    const mi_idx = funcExport(mp, "mi") orelse return error.NoSuchExport;
    const mi_cells = try a.alloc(u128, 1);
    mi_cells[0] = @as(u128, 9); // dst+1 == segment byte 1 == 0x22
    const mi_res = try interp.invoke(&instance, testing.allocator, mi_idx, mi_cells);
    defer testing.allocator.free(mi_res);
    try testing.expectEqual(@as(u32, 0x22), @as(u32, @truncate(mi_res[0])));

    // data.drop returns the trailing constant and runs Spasm-compiled.
    const dr_idx = funcExport(mp, "dr") orelse return error.NoSuchExport;
    const dr_res = try interp.invoke(&instance, testing.allocator, dr_idx, &.{});
    defer testing.allocator.free(dr_res);
    try testing.expectEqual(@as(u32, 42), @as(u32, @truncate(dr_res[0])));

    // After data.drop the passive segment is empty (§4.4.7), so a fresh
    // non-zero-length memory.init now traps OutOfBoundsMemoryAccess — the
    // same outcome the interpreter gives. This proves the drop took effect
    // through the compiled `dr`.
    try testing.expectError(error.OutOfBoundsMemoryAccess, interp.invoke(&instance, testing.allocator, mi_idx, mi_cells));

    // Every compiled entry (mi twice + dr) ran Spasm-compiled, not degraded.
    try testing.expect(instance.spasm_runs >= 1);
}

test "wasm spasm: table.size returns the table length" {
    // §4.4.x table.size (0xFC sub 16) — push the current element count of
    // table 0 as i32. The module declares a funcref table with min 3 and
    // no element segment, so the size is exactly 3. "sz"() must run
    // Spasm-compiled (spasm_runs counts each compiled entry).
    if (comptime !@import("spasm.zig").supported) return error.SkipZigTest;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // type 0: ()->i32
    const tbody = [_]u8{ 0x01, 0x60, 0x00, 0x01, 0x7f };
    // func section: func0 type0
    const fbody = [_]u8{ 0x01, 0x00 };
    // table section: 1 table, funcref (0x70), limits min-only (0x00) min 3
    const tablebody = [_]u8{ 0x01, 0x70, 0x00, 0x03 };
    // export "sz" -> func0
    const xbody = [_]u8{ 0x01, 0x02, 's', 'z', 0x00, 0x00 };
    // code section: one body.
    //   func0 (sz): table.size 0; end
    const cbody = [_]u8{
        0x01, // one code entry
        0x05, 0x00, // sz: 5 bytes, 0 locals
        0xfc, 0x10, 0x00, 0x0b,
    };
    const bytes = try assemble(a, &.{
        .{ .id = 1, .body = &tbody },
        .{ .id = 3, .body = &fbody },
        .{ .id = 4, .body = &tablebody },
        .{ .id = 7, .body = &xbody },
        .{ .id = 10, .body = &cbody },
    });

    const m = try wasm.decode(a, bytes);
    const mp = try a.create(wasm.Module);
    mp.* = m;

    var instance: interp.Instance = undefined;
    try interp.instantiate(&instance, a, testing.allocator, mp, .{});
    defer instance.deinit();
    instance.spasm_enabled = true; // force the baseline tier

    const fidx = funcExport(mp, "sz") orelse return error.NoSuchExport;
    const res = try interp.invoke(&instance, testing.allocator, fidx, &.{});
    defer testing.allocator.free(res);

    // The table was declared with min 3 elements...
    try testing.expectEqual(@as(u32, 3), @as(u32, @truncate(res[0])));
    // ...and "sz" (a `table.size`) ran Spasm-compiled, not degraded.
    try testing.expect(instance.spasm_runs >= 1);
}

test "wasm spasm: table.init then table.copy populate the table, then elem.drop empties the segment" {
    // §4.4.x table.init (0xFC sub 12), table.copy (0xFC sub 14), and
    // elem.drop (0xFC sub 13) — all scalar-operand bulk-table ops (only i32
    // indices cross the operand stack; the references stay table-internal).
    // The module declares a funcref table (min 4, no active segment, so
    // every slot starts null) and a *passive* element segment [add10, add20].
    //   "go"(): table.init copies elem[0..2] -> table[0..2]; table.copy
    //           copies table[0] -> table[2]; elem.drop 0; then dispatches
    //           call_indirect through table[2] (now add10) with arg 5 — so
    //           go() == add10(5) == 15, observing every op landed.
    //   "again"(): a fresh table.init of length 2 — after "go" dropped the
    //           segment it now traps OutOfBoundsTableAccess, proving the drop.
    // Both must run Spasm-compiled (spasm_runs counts each compiled entry).
    if (comptime !@import("spasm.zig").supported) return error.SkipZigTest;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // type 0: (i32)->i32  (add10/add20 + the call_indirect signature);
    // type 1: ()->i32     (go/again).
    const tbody = [_]u8{ 0x02, 0x60, 0x01, 0x7f, 0x01, 0x7f, 0x60, 0x00, 0x01, 0x7f };
    // func section: func0 add10 type0, func1 add20 type0, func2 go type1,
    // func3 again type1.
    const fbody = [_]u8{ 0x04, 0x00, 0x00, 0x01, 0x01 };
    // table section: 1 table, funcref (0x70), limits min-only (0x00) min 4
    const tablebody = [_]u8{ 0x01, 0x70, 0x00, 0x04 };
    // export "go" -> func2, "again" -> func3
    const xbody = [_]u8{
        0x02,
        0x02, 'g', 'o', 0x00, 0x02,
        0x05, 'a', 'g', 'a', 'i', 'n', 0x00, 0x03,
    };
    // element section: 1 *passive* segment (flag 0x01, index form), elemkind
    // 0x00 (funcref), funcs [0 (add10), 1 (add20)].
    const ebody = [_]u8{ 0x01, 0x01, 0x00, 0x02, 0x00, 0x01 };
    // code section: four bodies.
    //   func0 (add10): local.get 0; i32.const 10; i32.add; end
    //   func1 (add20): local.get 0; i32.const 20; i32.add; end
    //   func2 (go):
    //     i32.const 0; i32.const 0; i32.const 2; table.init 0 0; (table[0..2])
    //     i32.const 2; i32.const 0; i32.const 1; table.copy 0 0; (table[2]=table[0])
    //     elem.drop 0;
    //     i32.const 5; i32.const 2; call_indirect (type 0) (table 0); end
    //   func3 (again): i32.const 0; i32.const 0; i32.const 2; table.init 0 0;
    //     i32.const 0; end
    const cbody = [_]u8{
        0x04, // four code entries
        0x07, 0x00, 0x20, 0x00, 0x41, 0x0a, 0x6a, 0x0b, // add10: 7 bytes
        0x07, 0x00, 0x20, 0x00, 0x41, 0x14, 0x6a, 0x0b, // add20: 7 bytes
        0x20, 0x00, // go: 32 bytes, 0 locals
        0x41, 0x00, 0x41, 0x00, 0x41, 0x02, 0xfc, 0x0c, 0x00, 0x00, // table.init 0 0
        0x41, 0x02, 0x41, 0x00, 0x41, 0x01, 0xfc, 0x0e, 0x00, 0x00, // table.copy 0 0
        0xfc, 0x0d, 0x00, // elem.drop 0
        0x41, 0x05, 0x41, 0x02, 0x11, 0x00, 0x00, 0x0b, // i32.const 5; i32.const 2; call_indirect 0 0; end
        0x0e, 0x00, // again: 14 bytes, 0 locals
        0x41, 0x00, 0x41, 0x00, 0x41, 0x02, 0xfc, 0x0c, 0x00, 0x00, // table.init 0 0
        0x41, 0x00, 0x0b, // i32.const 0; end
    };
    const bytes = try assemble(a, &.{
        .{ .id = 1, .body = &tbody },
        .{ .id = 3, .body = &fbody },
        .{ .id = 4, .body = &tablebody },
        .{ .id = 7, .body = &xbody },
        .{ .id = 9, .body = &ebody },
        .{ .id = 10, .body = &cbody },
    });

    const m = try wasm.decode(a, bytes);
    const mp = try a.create(wasm.Module);
    mp.* = m;

    var instance: interp.Instance = undefined;
    try interp.instantiate(&instance, a, testing.allocator, mp, .{});
    defer instance.deinit();
    instance.spasm_enabled = true; // force the baseline tier

    // go(): table.init + table.copy place add10 at table[2]; the trailing
    // call_indirect dispatches through it. add10(5) == 15, the same the
    // interpreter gives.
    const go_idx = funcExport(mp, "go") orelse return error.NoSuchExport;
    const go_res = try interp.invoke(&instance, testing.allocator, go_idx, &.{});
    defer testing.allocator.free(go_res);
    try testing.expectEqual(@as(u32, 15), @as(u32, @truncate(go_res[0])));

    // After elem.drop the passive segment is empty (§4.4.x), so "again"'s
    // fresh non-zero-length table.init now traps OutOfBoundsTableAccess —
    // the same outcome the interpreter gives. This proves the drop took
    // effect through the compiled "go".
    const again_idx = funcExport(mp, "again") orelse return error.NoSuchExport;
    try testing.expectError(error.OutOfBoundsTableAccess, interp.invoke(&instance, testing.allocator, again_idx, &.{}));

    // Every compiled entry (go + again) ran Spasm-compiled, not degraded.
    try testing.expect(instance.spasm_runs >= 1);
}

test "wasm spasm: table.get reads a runtime funcref, ref.is_null inspects it" {
    // §4.4.x table.get (0x25) + §4.2.4 ref.is_null on a RUNTIME reference —
    // the first ops to put a 128-bit reference value onto Spasm's operand
    // stack. `table.get` pops an i32 index and pushes the reference at
    // `tables[0][index]` (trapping OOB); `ref.is_null` then folds it to 1 if
    // null, else 0. The reference lives in a depth-keyed cell appended to the
    // heap locals buffer, never a register, so it survives no calls here but
    // proves the runtime-ref representation end to end.
    //   main(x): local.get 0; table.get 0; ref.is_null; end
    // The module's funcref table (min 2) gets an active element segment
    // filling table[0] with `ref.func 0` (the defined function `dummy`),
    // leaving table[1] null. So main(0) == 0 (populated, non-null) and
    // main(1) == 1 (null) — the same the interpreter gives.
    if (comptime !@import("spasm.zig").supported) return error.SkipZigTest;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // type 0: (i32)->(i32)  (dummy's signature and main's signature)
    const tbody = [_]u8{ 0x01, 0x60, 0x01, 0x7f, 0x01, 0x7f };
    // func section: func0 "dummy" type0, func1 "main" type0
    const fbody = [_]u8{ 0x02, 0x00, 0x00 };
    // table section: 1 table, funcref (0x70), limits min-only (0x00) min 2
    const tablebody = [_]u8{ 0x01, 0x70, 0x00, 0x02 };
    // export "main" -> func 1
    const xbody = [_]u8{ 0x01, 0x04, 'm', 'a', 'i', 'n', 0x00, 0x01 };
    // element section: 1 active segment, table 0, offset (i32.const 0),
    // funcs [0 (dummy)] — fills table[0], leaves table[1] null.
    const ebody = [_]u8{ 0x01, 0x00, 0x41, 0x00, 0x0b, 0x01, 0x00 };
    // code section: two bodies.
    //   func 0 (dummy): local.get 0; end  (never called; only ref'd)
    //   func 1 (main):  local.get 0; table.get 0; ref.is_null; end
    const cbody = [_]u8{
        0x02, // two code entries
        0x04, 0x00, 0x20, 0x00, 0x0b, // dummy: 4 bytes, 0 locals
        0x07, 0x00, 0x20, 0x00, 0x25, 0x00, 0xd1, 0x0b, // main: 7 bytes, 0 locals
    };
    const bytes = try assemble(a, &.{
        .{ .id = 1, .body = &tbody },
        .{ .id = 3, .body = &fbody },
        .{ .id = 4, .body = &tablebody },
        .{ .id = 7, .body = &xbody },
        .{ .id = 9, .body = &ebody },
        .{ .id = 10, .body = &cbody },
    });

    const m = try wasm.decode(a, bytes);
    const mp = try a.create(wasm.Module);
    mp.* = m;

    var instance: interp.Instance = undefined;
    try interp.instantiate(&instance, a, testing.allocator, mp, .{});
    defer instance.deinit();
    instance.spasm_enabled = true; // force the baseline tier

    const fidx = funcExport(mp, "main") orelse return error.NoSuchExport;

    // table[0] is populated (ref.func dummy), so ref.is_null is 0.
    const populated = try a.alloc(u128, 1);
    populated[0] = @as(u128, 0);
    const r_pop = try interp.invoke(&instance, testing.allocator, fidx, populated);
    defer testing.allocator.free(r_pop);
    try testing.expectEqual(@as(u32, 0), @as(u32, @truncate(r_pop[0])));

    // table[1] is null (no segment filled it), so ref.is_null is 1.
    const empty = try a.alloc(u128, 1);
    empty[0] = @as(u128, 1);
    const r_null = try interp.invoke(&instance, testing.allocator, fidx, empty);
    defer testing.allocator.free(r_null);
    try testing.expectEqual(@as(u32, 1), @as(u32, @truncate(r_null[0])));

    // "main" (a `table.get` feeding `ref.is_null`) ran Spasm-compiled, not
    // degraded — the runtime reference crossed the operand stack natively.
    try testing.expect(instance.spasm_runs >= 1);
}

test "wasm spasm: table.set writes a funcref, then call_indirect dispatches through it" {
    // §4.4.x table.set (0x26) — the first ref-WRITING table op on Spasm's
    // operand stack. Stack order is [index(i32), ref] with the ref on top.
    // Two ways the ref-to-write reaches the op are covered:
    //   "setcall"(): writes a COMPILE-TIME ref (`ref.func add10`, a .ref_func
    //       Loc) into table[1], then `call_indirect`s through table[1] with
    //       arg 5 → add10(5) == 15, proving the slot now holds a callable ref.
    //   "setrt"():  populates table[0] from a passive elem (table.init), reads
    //       it back with `table.get` (a RUNTIME .ref operand), writes THAT into
    //       table[1] with table.set, then call_indirect table[1](5) == 15 —
    //       proving the runtime-.ref write path too.
    // Both must run Spasm-compiled (spasm_runs counts each compiled entry).
    if (comptime !@import("spasm.zig").supported) return error.SkipZigTest;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // type 0: (i32)->i32 (add10 + the call_indirect signature);
    // type 1: ()->i32    (setcall/setrt).
    const tbody = [_]u8{ 0x02, 0x60, 0x01, 0x7f, 0x01, 0x7f, 0x60, 0x00, 0x01, 0x7f };
    // func section: func0 add10 type0, func1 setcall type1, func2 setrt type1.
    const fbody = [_]u8{ 0x03, 0x00, 0x01, 0x01 };
    // table section: 1 table, funcref (0x70), limits min-only (0x00) min 4.
    const tablebody = [_]u8{ 0x01, 0x70, 0x00, 0x04 };
    // export "setcall" -> func1, "setrt" -> func2.
    const xbody = [_]u8{
        0x02,
        0x07, 's', 'e', 't', 'c', 'a', 'l', 'l', 0x00, 0x01,
        0x05, 's', 'e', 't', 'r', 't', 0x00, 0x02,
    };
    // element section: 1 *passive* segment (flag 0x01), elemkind 0x00
    // (funcref), funcs [0 (add10)].
    const ebody = [_]u8{ 0x01, 0x01, 0x00, 0x01, 0x00 };
    // code section: three bodies.
    //   func0 (add10): local.get 0; i32.const 10; i32.add; end
    //   func1 (setcall):
    //     i32.const 1; ref.func 0; table.set 0;          (table[1] = add10)
    //     i32.const 5; i32.const 1; call_indirect 0 0; end
    //   func2 (setrt):
    //     i32.const 0; i32.const 0; i32.const 1; table.init 0 0; (table[0]=add10)
    //     i32.const 1; i32.const 0; table.get 0; table.set 0;    (table[1]=table[0])
    //     i32.const 5; i32.const 1; call_indirect 0 0; end
    const cbody = [_]u8{
        0x03, // three code entries
        0x07, 0x00, 0x20, 0x00, 0x41, 0x0a, 0x6a, 0x0b, // add10: 7 bytes
        0x0f, 0x00, // setcall: 15 bytes, 0 locals
        0x41, 0x01, 0xd2, 0x00, 0x26, 0x00, // i32.const 1; ref.func 0; table.set 0
        0x41, 0x05, 0x41, 0x01, 0x11, 0x00, 0x00, 0x0b, // i32.const 5; i32.const 1; call_indirect 0 0; end
        0x1b, 0x00, // setrt: 27 bytes, 0 locals
        0x41, 0x00, 0x41, 0x00, 0x41, 0x01, 0xfc, 0x0c, 0x00, 0x00, // table.init 0 0
        0x41, 0x01, 0x41, 0x00, 0x25, 0x00, 0x26, 0x00, // i32.const 1; i32.const 0; table.get 0; table.set 0
        0x41, 0x05, 0x41, 0x01, 0x11, 0x00, 0x00, 0x0b, // i32.const 5; i32.const 1; call_indirect 0 0; end
    };
    const bytes = try assemble(a, &.{
        .{ .id = 1, .body = &tbody },
        .{ .id = 3, .body = &fbody },
        .{ .id = 4, .body = &tablebody },
        .{ .id = 7, .body = &xbody },
        .{ .id = 9, .body = &ebody },
        .{ .id = 10, .body = &cbody },
    });

    const m = try wasm.decode(a, bytes);
    const mp = try a.create(wasm.Module);
    mp.* = m;

    var instance: interp.Instance = undefined;
    try interp.instantiate(&instance, a, testing.allocator, mp, .{});
    defer instance.deinit();
    instance.spasm_enabled = true; // force the baseline tier

    // setcall: a compile-time `ref.func` written by table.set, then dispatched
    // through. add10(5) == 15, the same the interpreter gives.
    const setcall_idx = funcExport(mp, "setcall") orelse return error.NoSuchExport;
    const r_setcall = try interp.invoke(&instance, testing.allocator, setcall_idx, &.{});
    defer testing.allocator.free(r_setcall);
    try testing.expectEqual(@as(u32, 15), @as(u32, @truncate(r_setcall[0])));

    // setrt: a runtime `.ref` (read via table.get) written by table.set, then
    // dispatched through. Same answer, proving the runtime-ref write path.
    const setrt_idx = funcExport(mp, "setrt") orelse return error.NoSuchExport;
    const r_setrt = try interp.invoke(&instance, testing.allocator, setrt_idx, &.{});
    defer testing.allocator.free(r_setrt);
    try testing.expectEqual(@as(u32, 15), @as(u32, @truncate(r_setrt[0])));

    try testing.expect(instance.spasm_runs >= 1);
}

test "wasm spasm: table.set out of bounds raises a catchable trap" {
    // §4.4.x table.set traps OutOfBoundsTableAccess when the index is past the
    // table — the same the interpreter gives. "oob"() writes ref.func 0 at
    // index 9 of a min-2 table.
    if (comptime !@import("spasm.zig").supported) return error.SkipZigTest;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const tbody = [_]u8{ 0x02, 0x60, 0x01, 0x7f, 0x01, 0x7f, 0x60, 0x00, 0x01, 0x7f };
    const fbody = [_]u8{ 0x02, 0x00, 0x01 };
    const tablebody = [_]u8{ 0x01, 0x70, 0x00, 0x02 };
    const xbody = [_]u8{ 0x01, 0x03, 'o', 'o', 'b', 0x00, 0x01 };
    // declarative element segment so `ref.func 0` validates (§3.3.2.4 — the
    // index must be in C.refs); it does not initialize the table.
    const ebody = [_]u8{ 0x01, 0x03, 0x00, 0x01, 0x00 };
    // func0 (dummy add10), func1 (oob): i32.const 9; ref.func 0; table.set 0; i32.const 0; end
    const cbody = [_]u8{
        0x02,
        0x07, 0x00, 0x20, 0x00, 0x41, 0x0a, 0x6a, 0x0b, // add10
        0x0a, 0x00, // oob: 10 bytes, 0 locals
        0x41, 0x09, 0xd2, 0x00, 0x26, 0x00, 0x41, 0x00, 0x0b, // i32.const 9; ref.func 0; table.set 0; i32.const 0; end
    };
    const bytes = try assemble(a, &.{
        .{ .id = 1, .body = &tbody },
        .{ .id = 3, .body = &fbody },
        .{ .id = 4, .body = &tablebody },
        .{ .id = 7, .body = &xbody },
        .{ .id = 9, .body = &ebody },
        .{ .id = 10, .body = &cbody },
    });

    const m = try wasm.decode(a, bytes);
    const mp = try a.create(wasm.Module);
    mp.* = m;

    var instance: interp.Instance = undefined;
    try interp.instantiate(&instance, a, testing.allocator, mp, .{});
    defer instance.deinit();
    instance.spasm_enabled = true;

    const fidx = funcExport(mp, "oob") orelse return error.NoSuchExport;
    try testing.expectError(error.OutOfBoundsTableAccess, interp.invoke(&instance, testing.allocator, fidx, &.{}));
}

test "wasm spasm: table.grow grows the table and returns the previous size" {
    // §4.4.x table.grow (0xFC sub 15) — pops [init(ref), delta(i32)] (delta on
    // top), grows the table by `delta` filling new slots with `init`, pushes
    // the PREVIOUS element count (or -1 on failure; it never traps). The init
    // ref here is a COMPILE-TIME `ref.func add10` (.ref_func Loc).
    //   "grow"(): ref.func 0; i32.const 1; table.grow 0; end — the table starts
    //       at 4 elements, so the old size is 4 and the table grows to 5.
    // The only exported/invoked function is "grow" itself, and it is otherwise
    // leaf (no call), so `spasm_runs >= 1` is a true signal that `table.grow`
    // compiled — not an unrelated function inflating the counter. The grown
    // slot's content (the `init` funcref) is checked directly from Zig.
    if (comptime !@import("spasm.zig").supported) return error.SkipZigTest;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // type 0: (i32)->i32 (add10, the ref.func target); type 1: ()->i32 (grow).
    const tbody = [_]u8{ 0x02, 0x60, 0x01, 0x7f, 0x01, 0x7f, 0x60, 0x00, 0x01, 0x7f };
    const fbody = [_]u8{ 0x02, 0x00, 0x01 };
    const tablebody = [_]u8{ 0x01, 0x70, 0x00, 0x04 };
    const xbody = [_]u8{ 0x01, 0x04, 'g', 'r', 'o', 'w', 0x00, 0x01 };
    // declarative element segment so `ref.func 0` validates (§3.3.2.4); it
    // does not initialize the table.
    const ebody = [_]u8{ 0x01, 0x03, 0x00, 0x01, 0x00 };
    // code: func0 add10 (only ref'd, never called); func1 grow.
    //   grow: ref.func 0; i32.const 1; table.grow 0; end
    const cbody = [_]u8{
        0x02,
        0x07, 0x00, 0x20, 0x00, 0x41, 0x0a, 0x6a, 0x0b, // add10
        0x09, 0x00, // grow: 9 bytes, 0 locals
        0xd2, 0x00, 0x41, 0x01, 0xfc, 0x0f, 0x00, 0x0b, // ref.func 0; i32.const 1; table.grow 0; end
    };
    const bytes = try assemble(a, &.{
        .{ .id = 1, .body = &tbody },
        .{ .id = 3, .body = &fbody },
        .{ .id = 4, .body = &tablebody },
        .{ .id = 7, .body = &xbody },
        .{ .id = 9, .body = &ebody },
        .{ .id = 10, .body = &cbody },
    });

    const m = try wasm.decode(a, bytes);
    const mp = try a.create(wasm.Module);
    mp.* = m;

    var instance: interp.Instance = undefined;
    try interp.instantiate(&instance, a, testing.allocator, mp, .{});
    defer instance.deinit();
    instance.spasm_enabled = true;

    // grow returns the previous size (4) and grows the table to 5 — the same
    // the interpreter gives.
    const grow_idx = funcExport(mp, "grow") orelse return error.NoSuchExport;
    const r_grow = try interp.invoke(&instance, testing.allocator, grow_idx, &.{});
    defer testing.allocator.free(r_grow);
    try testing.expectEqual(@as(u32, 4), @as(u32, @truncate(r_grow[0])));
    try testing.expectEqual(@as(usize, 5), instance.tables[0].elems.len);

    // The grown slot (index 4) holds the `init` ref — `ref.func 0`, i.e.
    // makeFuncRef(defining-instance, 0), which is non-null. Checking the cell
    // directly (rather than dispatching through it) keeps the only invoked
    // function "grow" itself, so the spasm_runs assertion stays load-bearing.
    try testing.expectEqual(interp.makeFuncRef(&instance, 0), instance.tables[0].elems[4]);

    try testing.expect(instance.spasm_runs >= 1);
}

test "wasm spasm: table.fill fills a range, observed via call_indirect" {
    // §4.4.x table.fill (0xFC sub 17) — pops [index(i32), val(ref), count(i32)]
    // (count on top, val in the middle, index at the bottom), filling `count`
    // entries from `index` with `val`, trapping OOB. The fill value here is a
    // COMPILE-TIME `ref.func add10` (.ref_func Loc).
    //   "fill"(): i32.const 1; ref.func 0; i32.const 2; table.fill 0 — fills
    //       table[1] and table[2] with add10; then call_indirect through
    //       table[2] with arg 5 → add10(5) == 15, observing the fill landed.
    if (comptime !@import("spasm.zig").supported) return error.SkipZigTest;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const tbody = [_]u8{ 0x02, 0x60, 0x01, 0x7f, 0x01, 0x7f, 0x60, 0x00, 0x01, 0x7f };
    const fbody = [_]u8{ 0x02, 0x00, 0x01 };
    const tablebody = [_]u8{ 0x01, 0x70, 0x00, 0x04 };
    const xbody = [_]u8{ 0x01, 0x04, 'f', 'i', 'l', 'l', 0x00, 0x01 };
    // declarative element segment so `ref.func 0` validates (§3.3.2.4); it
    // does not initialize the table.
    const ebody = [_]u8{ 0x01, 0x03, 0x00, 0x01, 0x00 };
    // code: func0 add10; func1 fill.
    //   fill: i32.const 1; ref.func 0; i32.const 2; table.fill 0;
    //         i32.const 5; i32.const 2; call_indirect 0 0; end
    const cbody = [_]u8{
        0x02,
        0x07, 0x00, 0x20, 0x00, 0x41, 0x0a, 0x6a, 0x0b, // add10
        0x12, 0x00, // fill: 18 bytes, 0 locals
        0x41, 0x01, 0xd2, 0x00, 0x41, 0x02, 0xfc, 0x11, 0x00, // i32.const 1; ref.func 0; i32.const 2; table.fill 0
        0x41, 0x05, 0x41, 0x02, 0x11, 0x00, 0x00, 0x0b, // i32.const 5; i32.const 2; call_indirect 0 0; end
    };
    const bytes = try assemble(a, &.{
        .{ .id = 1, .body = &tbody },
        .{ .id = 3, .body = &fbody },
        .{ .id = 4, .body = &tablebody },
        .{ .id = 7, .body = &xbody },
        .{ .id = 9, .body = &ebody },
        .{ .id = 10, .body = &cbody },
    });

    const m = try wasm.decode(a, bytes);
    const mp = try a.create(wasm.Module);
    mp.* = m;

    var instance: interp.Instance = undefined;
    try interp.instantiate(&instance, a, testing.allocator, mp, .{});
    defer instance.deinit();
    instance.spasm_enabled = true;

    // table.fill places add10 at table[1..3]; dispatching through table[2]
    // gives add10(5) == 15, the same the interpreter gives.
    const fidx = funcExport(mp, "fill") orelse return error.NoSuchExport;
    const res = try interp.invoke(&instance, testing.allocator, fidx, &.{});
    defer testing.allocator.free(res);
    try testing.expectEqual(@as(u32, 15), @as(u32, @truncate(res[0])));
    try testing.expect(instance.spasm_runs >= 1);
}

// A one-page-memory module whose `()->i32` export "sz" returns the current
// memory size in pages (memory.size, 0x3f) — the byte length >> 16.
const memsize_body = [_]u8{
    0x01, 0x05, 0x01, 0x60, 0x00, 0x01, 0x7f, // type ()->i32
    0x03, 0x02, 0x01, 0x00, // func 0 : type 0
    0x05, 0x03, 0x01, 0x00, 0x01, // memory: 1 page
    0x07, 0x06, 0x01, 0x02, 0x73, 0x7a, 0x00, 0x00, // export "sz" -> 0
    0x0a, 0x06, 0x01, 0x04, 0x00, 0x3f, 0x00, 0x0b, // memory.size; end
};

test "wasm spasm: memory.size returns the page count" {
    if (comptime !@import("spasm.zig").supported) return error.SkipZigTest;
    var buf: [8 + memsize_body.len]u8 = undefined;
    const bytes = withPreamble(&buf, &memsize_body);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var instance: interp.Instance = undefined;
    const mp = try setupMemModule(&instance, a, bytes);
    defer instance.deinit();

    const fidx = funcExport(mp, "sz") orelse return error.NoSuchExport;
    const res = try interp.invoke(&instance, testing.allocator, fidx, &.{});
    defer testing.allocator.free(res);

    // One page of linear memory, so memory.size == 1.
    try testing.expectEqual(@as(u32, 1), @as(u32, @truncate(res[0])));
    try testing.expect(instance.spasm_runs >= 1);
}

// `()->i32` that grows the (min-1-page) memory by one page and returns
// the previous page count: `i32.const 1; memory.grow 0; end` (§4.4.7).
const memgrow_body = [_]u8{
    0x01, 0x05, 0x01, 0x60, 0x00, 0x01, 0x7f, // type ()->i32
    0x03, 0x02, 0x01, 0x00, // func 0 : type 0
    0x05, 0x03, 0x01, 0x00, 0x01, // memory: 1 page
    0x07, 0x06, 0x01, 0x02, 0x67, 0x72, 0x00, 0x00, // export "gr" -> 0
    0x0a, 0x08, 0x01, 0x06, 0x00, 0x41, 0x01, 0x40, 0x00, 0x0b, // i32.const 1; memory.grow 0; end
};

test "wasm spasm: memory.grow grows the memory and returns the previous page count" {
    if (comptime !@import("spasm.zig").supported) return error.SkipZigTest;
    var buf: [8 + memgrow_body.len]u8 = undefined;
    const bytes = withPreamble(&buf, &memgrow_body);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var instance: interp.Instance = undefined;
    const mp = try setupMemModule(&instance, a, bytes);
    defer instance.deinit();

    const fidx = funcExport(mp, "gr") orelse return error.NoSuchExport;
    const res = try interp.invoke(&instance, testing.allocator, fidx, &.{});
    defer testing.allocator.free(res);

    // memory.grow returns the previous size (1 page) and the memory now
    // holds two pages — proving the realloc happened and Spasm reloaded
    // the stale mem_base/mem_len after the helper.
    try testing.expectEqual(@as(u32, 1), @as(u32, @truncate(res[0])));
    try testing.expectEqual(@as(u64, 2 * interp.PAGE_SIZE), @as(u64, instance.memories[0].data.len));
    try testing.expect(instance.spasm_runs >= 1);
}

// `(i32,i32)->i32` adders for the rotates: "rl" = i32.rotl (0x77),
// "rr" = i32.rotr (0x78).
const i32_rotl_body = [_]u8{
    0x01, 0x07, 0x01, 0x60, 0x02, 0x7f, 0x7f, 0x01, 0x7f, // type (i32,i32)->i32
    0x03, 0x02, 0x01, 0x00, // func 0 : type 0
    0x07, 0x06, 0x01, 0x02, 0x72, 0x6c, 0x00, 0x00, // export "rl" -> 0
    0x0a, 0x09, 0x01, 0x07, 0x00, 0x20, 0x00, 0x20, 0x01, 0x77, 0x0b, // local.get 0; local.get 1; i32.rotl; end
};

test "wasm spasm: i32.rotl rotates left via RORV by (32 - count)" {
    if (comptime !@import("spasm.zig").supported) return error.SkipZigTest;
    var buf: [8 + i32_rotl_body.len]u8 = undefined;
    const bytes = withPreamble(&buf, &i32_rotl_body);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const m = try wasm.decode(a, bytes);
    const mp = try a.create(wasm.Module);
    mp.* = m;

    var instance: interp.Instance = undefined;
    try interp.instantiate(&instance, a, testing.allocator, mp, .{});
    defer instance.deinit();
    instance.spasm_enabled = true;

    const fidx = funcExport(mp, "rl") orelse return error.NoSuchExport;
    const cells = try a.alloc(u128, 2);
    cells[0] = @as(u128, @as(u32, 0x12345678));
    cells[1] = @as(u128, 8);

    const res = try interp.invoke(&instance, testing.allocator, fidx, cells);
    defer testing.allocator.free(res);

    // rotl(0x12345678, 8) == 0x34567812.
    try testing.expectEqual(@as(u32, 0x34567812), @as(u32, @truncate(res[0])));
    try testing.expect(instance.spasm_runs >= 1);
}

const i32_rotr_body = [_]u8{
    0x01, 0x07, 0x01, 0x60, 0x02, 0x7f, 0x7f, 0x01, 0x7f, // type (i32,i32)->i32
    0x03, 0x02, 0x01, 0x00, // func 0 : type 0
    0x07, 0x06, 0x01, 0x02, 0x72, 0x72, 0x00, 0x00, // export "rr" -> 0
    0x0a, 0x09, 0x01, 0x07, 0x00, 0x20, 0x00, 0x20, 0x01, 0x78, 0x0b, // local.get 0; local.get 1; i32.rotr; end
};

test "wasm spasm: i32.rotr rotates right via RORV" {
    if (comptime !@import("spasm.zig").supported) return error.SkipZigTest;
    var buf: [8 + i32_rotr_body.len]u8 = undefined;
    const bytes = withPreamble(&buf, &i32_rotr_body);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const m = try wasm.decode(a, bytes);
    const mp = try a.create(wasm.Module);
    mp.* = m;

    var instance: interp.Instance = undefined;
    try interp.instantiate(&instance, a, testing.allocator, mp, .{});
    defer instance.deinit();
    instance.spasm_enabled = true;

    const fidx = funcExport(mp, "rr") orelse return error.NoSuchExport;
    const cells = try a.alloc(u128, 2);
    cells[0] = @as(u128, @as(u32, 0x12345678));
    cells[1] = @as(u128, 8);

    const res = try interp.invoke(&instance, testing.allocator, fidx, cells);
    defer testing.allocator.free(res);

    // rotr(0x12345678, 8) == 0x78123456.
    try testing.expectEqual(@as(u32, 0x78123456), @as(u32, @truncate(res[0])));
    try testing.expect(instance.spasm_runs >= 1);
}

test "wasm spasm: i32.load8_s sign-extends a byte" {
    if (comptime !@import("spasm.zig").supported) return error.SkipZigTest;
    var buf: [8 + subwidth_module_body.len]u8 = undefined;
    const bytes = withPreamble(&buf, &subwidth_module_body);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var instance: interp.Instance = undefined;
    const mp = try setupMemModule(&instance, a, bytes);
    defer instance.deinit();

    instance.memories[0].data[5] = 0xFF;
    const fidx = funcExport(mp, "ls") orelse return error.NoSuchExport;
    const cells = try a.alloc(u128, 1);
    cells[0] = @as(u128, 5);

    const res = try interp.invoke(&instance, testing.allocator, fidx, cells);
    defer testing.allocator.free(res);

    // 0xFF sign-extended is -1; the LDRSB result fills the i32.
    try testing.expectEqual(@as(i32, -1), @as(i32, @bitCast(@as(u32, @truncate(res[0])))));
    try testing.expect(instance.spasm_runs >= 1);
}

test "wasm spasm: i32.store8 writes only the low byte" {
    if (comptime !@import("spasm.zig").supported) return error.SkipZigTest;
    var buf: [8 + subwidth_module_body.len]u8 = undefined;
    const bytes = withPreamble(&buf, &subwidth_module_body);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var instance: interp.Instance = undefined;
    const mp = try setupMemModule(&instance, a, bytes);
    defer instance.deinit();

    // A sentinel above the target byte must survive the byte-width store.
    instance.memories[0].data[10] = 0xAA;
    const fidx = funcExport(mp, "s8") orelse return error.NoSuchExport;
    const cells = try a.alloc(u128, 2);
    cells[0] = @as(u128, 9); // address
    cells[1] = @as(u128, 0x1234); // value — only 0x34 should land

    const res = try interp.invoke(&instance, testing.allocator, fidx, cells);
    defer testing.allocator.free(res);

    try testing.expectEqual(@as(u8, 0x34), instance.memories[0].data[9]);
    try testing.expectEqual(@as(u8, 0xAA), instance.memories[0].data[10]); // untouched
    try testing.expect(instance.spasm_runs >= 1);
}

// An `(i64,i64)->i64` adder exported as "add": local.get 0; local.get 1;
// i64.add; end. The 0x7e value types and 0x7c opcode are the i64 forms.
const i64_add_body = [_]u8{
    0x01, 0x07, 0x01, 0x60, 0x02, 0x7e, 0x7e, 0x01, 0x7e, // type (i64,i64)->i64
    0x03, 0x02, 0x01, 0x00, // func 0 : type 0
    0x07, 0x07, 0x01, 0x03, 0x61, 0x64, 0x64, 0x00, 0x00, // export "add" -> 0
    0x0a, 0x09, 0x01, 0x07, 0x00, 0x20, 0x00, 0x20, 0x01, 0x7c, 0x0b, // local.get 0; local.get 1; i64.add; end
};

test "wasm spasm: i64.add compiles and runs Spasm-compiled (full 64-bit)" {
    if (comptime !@import("spasm.zig").supported) return error.SkipZigTest;
    var buf: [8 + i64_add_body.len]u8 = undefined;
    const bytes = withPreamble(&buf, &i64_add_body);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const m = try wasm.decode(a, bytes);
    const mp = try a.create(wasm.Module);
    mp.* = m;

    var instance: interp.Instance = undefined;
    try interp.instantiate(&instance, a, testing.allocator, mp, .{});
    defer instance.deinit();
    instance.spasm_enabled = true;

    const fidx = funcExport(mp, "add") orelse return error.NoSuchExport;
    const cells = try a.alloc(u128, 2);
    // Operands above 2^32 prove the add is genuinely 64-bit, not truncated.
    cells[0] = @as(u128, 0x1_0000_0000);
    cells[1] = @as(u128, 0x2_0000_0007);

    const res = try interp.invoke(&instance, testing.allocator, fidx, cells);
    defer testing.allocator.free(res);

    try testing.expectEqual(@as(u64, 0x3_0000_0007), @as(u64, @truncate(res[0])));
    try testing.expect(instance.spasm_runs >= 1);
}

// An `(i64,i64)->i32` signed less-than exported as "lt": local.get 0;
// local.get 1; i64.lt_s; end. The result type is i32 (a comparison).
const i64_lt_s_body = [_]u8{
    0x01, 0x07, 0x01, 0x60, 0x02, 0x7e, 0x7e, 0x01, 0x7f, // type (i64,i64)->i32
    0x03, 0x02, 0x01, 0x00, // func 0 : type 0
    0x07, 0x06, 0x01, 0x02, 0x6c, 0x74, 0x00, 0x00, // export "lt" -> 0
    0x0a, 0x09, 0x01, 0x07, 0x00, 0x20, 0x00, 0x20, 0x01, 0x53, 0x0b, // local.get 0; local.get 1; i64.lt_s; end
};

test "wasm spasm: i64.lt_s compiles and compares the full 64 bits" {
    if (comptime !@import("spasm.zig").supported) return error.SkipZigTest;
    var buf: [8 + i64_lt_s_body.len]u8 = undefined;
    const bytes = withPreamble(&buf, &i64_lt_s_body);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const m = try wasm.decode(a, bytes);
    const mp = try a.create(wasm.Module);
    mp.* = m;

    var instance: interp.Instance = undefined;
    try interp.instantiate(&instance, a, testing.allocator, mp, .{});
    defer instance.deinit();
    instance.spasm_enabled = true;

    const fidx = funcExport(mp, "lt") orelse return error.NoSuchExport;
    const cells = try a.alloc(u128, 2);
    // 2^32 vs 1: a truncated 32-bit compare would see 0 < 1 and answer 1;
    // the real 64-bit signed compare answers 0 (2^32 is not < 1).
    cells[0] = @as(u128, 0x1_0000_0000);
    cells[1] = @as(u128, 1);

    const res = try interp.invoke(&instance, testing.allocator, fidx, cells);
    defer testing.allocator.free(res);

    try testing.expectEqual(@as(u32, 0), @as(u32, @truncate(res[0])));
    try testing.expect(instance.spasm_runs >= 1);
}

// An `(i64,i64)->i64` signed divide exported as "div": local.get 0;
// local.get 1; i64.div_s; end.
const i64_div_s_body = [_]u8{
    0x01, 0x07, 0x01, 0x60, 0x02, 0x7e, 0x7e, 0x01, 0x7e, // type (i64,i64)->i64
    0x03, 0x02, 0x01, 0x00, // func 0 : type 0
    0x07, 0x07, 0x01, 0x03, 0x64, 0x69, 0x76, 0x00, 0x00, // export "div" -> 0
    0x0a, 0x09, 0x01, 0x07, 0x00, 0x20, 0x00, 0x20, 0x01, 0x7f, 0x0b, // local.get 0; local.get 1; i64.div_s; end
};

/// Build + instantiate the i64 divide module (Spasm forced on) and invoke
/// "div" with `(a, b)`, returning the result slice or a trap error.
fn runSpasmI64Div(a_alloc: std.mem.Allocator, arg_a: u64, arg_b: u64) ![]u128 {
    var buf: [8 + i64_div_s_body.len]u8 = undefined;
    const bytes = withPreamble(&buf, &i64_div_s_body);
    const m = try wasm.decode(a_alloc, bytes);
    const mp = try a_alloc.create(wasm.Module);
    mp.* = m;
    var instance: interp.Instance = undefined;
    try interp.instantiate(&instance, a_alloc, testing.allocator, mp, .{});
    defer instance.deinit();
    instance.spasm_enabled = true;
    const fidx = funcExport(mp, "div") orelse return error.NoSuchExport;
    const cells = try a_alloc.alloc(u128, 2);
    cells[0] = @as(u128, arg_a);
    cells[1] = @as(u128, arg_b);
    return interp.invoke(&instance, testing.allocator, fidx, cells);
}

test "wasm spasm: i64.div_s compiles and divides the full 64 bits" {
    if (comptime !@import("spasm.zig").supported) return error.SkipZigTest;
    var buf: [8 + i64_div_s_body.len]u8 = undefined;
    const bytes = withPreamble(&buf, &i64_div_s_body);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const m = try wasm.decode(a, bytes);
    const mp = try a.create(wasm.Module);
    mp.* = m;

    var instance: interp.Instance = undefined;
    try interp.instantiate(&instance, a, testing.allocator, mp, .{});
    defer instance.deinit();
    instance.spasm_enabled = true;

    const fidx = funcExport(mp, "div") orelse return error.NoSuchExport;
    const cells = try a.alloc(u128, 2);
    // (6 * 2^32) / 2 == 3 * 2^32; a truncated 32-bit divide would see 0 / 2.
    cells[0] = @as(u128, 0x6_0000_0000);
    cells[1] = @as(u128, 2);

    const res = try interp.invoke(&instance, testing.allocator, fidx, cells);
    defer testing.allocator.free(res);

    try testing.expectEqual(@as(u64, 0x3_0000_0000), @as(u64, @truncate(res[0])));
    try testing.expect(instance.spasm_runs >= 1);
}

test "wasm spasm: i64.div_s by zero raises a catchable trap" {
    if (comptime !@import("spasm.zig").supported) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(error.IntegerDivideByZero, runSpasmI64Div(arena.allocator(), 5, 0));
}

// A one-page-memory module exporting i64 memory accessors:
//   "ld" (i32)->i64     : local.get 0  i64.load     align=3 off=0
//   "st" (i32,i64)->()  : local.get 0  local.get 1  i64.store align=3 off=0
const i64_mem_module_body = [_]u8{
    // type (payload 11): type0=(i32)->i64, type1=(i32,i64)->()
    0x01, 0x0b, 0x02, 0x60, 0x01, 0x7f, 0x01, 0x7e, 0x60, 0x02, 0x7f, 0x7e, 0x00,
    // func: 2 funcs (types 0,1)
    0x03, 0x03, 0x02, 0x00, 0x01,
    // memory: one page
    0x05, 0x03, 0x01, 0x00, 0x01,
    // export (payload 11): "ld"->0, "st"->1
    0x07, 0x0b, 0x02,
    0x02, 0x6c, 0x64, 0x00, 0x00, 0x02, 0x73, 0x74, 0x00, 0x01,
    // code (payload 19)
    0x0a, 0x13, 0x02,
    0x07, 0x00, 0x20, 0x00, 0x29, 0x03, 0x00, 0x0b, // ld: local.get 0; i64.load a=3 o=0; end
    0x09, 0x00, 0x20, 0x00, 0x20, 0x01, 0x37, 0x03, 0x00, 0x0b, // st: local.get 0; local.get 1; i64.store a=3 o=0; end
};

test "wasm spasm: i64.load compiles and reads eight bytes" {
    if (comptime !@import("spasm.zig").supported) return error.SkipZigTest;
    var buf: [8 + i64_mem_module_body.len]u8 = undefined;
    const bytes = withPreamble(&buf, &i64_mem_module_body);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const m = try wasm.decode(a, bytes);
    const mp = try a.create(wasm.Module);
    mp.* = m;

    var instance: interp.Instance = undefined;
    try interp.instantiate(&instance, a, testing.allocator, mp, .{});
    defer instance.deinit();
    instance.spasm_enabled = true;

    // A full 64-bit value at offset 8; a 4-byte load would drop the high word.
    std.mem.writeInt(u64, instance.memories[0].data[8..][0..8], 0xCAFE_BABE_DEAD_BEEF, .little);
    const fidx = funcExport(mp, "ld") orelse return error.NoSuchExport;
    const cells = try a.alloc(u128, 1);
    cells[0] = @as(u128, 8);

    const res = try interp.invoke(&instance, testing.allocator, fidx, cells);
    defer testing.allocator.free(res);

    try testing.expectEqual(@as(u64, 0xCAFE_BABE_DEAD_BEEF), @as(u64, @truncate(res[0])));
    try testing.expect(instance.spasm_runs >= 1);
}

// An `(i32)->i64` exported as "ext": local.get 0; i64.extend_i32_s; end.
const i64_extend_body = [_]u8{
    0x01, 0x06, 0x01, 0x60, 0x01, 0x7f, 0x01, 0x7e, // type (i32)->i64
    0x03, 0x02, 0x01, 0x00, // func 0 : type 0
    0x07, 0x07, 0x01, 0x03, 0x65, 0x78, 0x74, 0x00, 0x00, // export "ext" -> 0
    0x0a, 0x07, 0x01, 0x05, 0x00, 0x20, 0x00, 0xac, 0x0b, // local.get 0; i64.extend_i32_s; end
};

test "wasm spasm: i64.extend_i32_s sign-extends a negative i32" {
    if (comptime !@import("spasm.zig").supported) return error.SkipZigTest;
    var buf: [8 + i64_extend_body.len]u8 = undefined;
    const bytes = withPreamble(&buf, &i64_extend_body);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const m = try wasm.decode(a, bytes);
    const mp = try a.create(wasm.Module);
    mp.* = m;

    var instance: interp.Instance = undefined;
    try interp.instantiate(&instance, a, testing.allocator, mp, .{});
    defer instance.deinit();
    instance.spasm_enabled = true;

    const fidx = funcExport(mp, "ext") orelse return error.NoSuchExport;
    const cells = try a.alloc(u128, 1);
    cells[0] = @as(u128, 0xFFFF_FFFF); // the i32 -1

    const res = try interp.invoke(&instance, testing.allocator, fidx, cells);
    defer testing.allocator.free(res);

    // -1 (i32) sign-extends to -1 (i64); a zero-extend would give 0xFFFFFFFF.
    try testing.expectEqual(@as(u64, 0xFFFF_FFFF_FFFF_FFFF), @as(u64, @truncate(res[0])));
    try testing.expect(instance.spasm_runs >= 1);
}

// An `(f64,f64)->f64` adder exported as "add": local.get 0; local.get 1;
// f64.add; end. (0x7c is the f64 value type, 0xa0 is f64.add.)
const f64_add_body = [_]u8{
    0x01, 0x07, 0x01, 0x60, 0x02, 0x7c, 0x7c, 0x01, 0x7c, // type (f64,f64)->f64
    0x03, 0x02, 0x01, 0x00, // func 0 : type 0
    0x07, 0x07, 0x01, 0x03, 0x61, 0x64, 0x64, 0x00, 0x00, // export "add" -> 0
    0x0a, 0x09, 0x01, 0x07, 0x00, 0x20, 0x00, 0x20, 0x01, 0xa0, 0x0b, // local.get 0; local.get 1; f64.add; end
};

test "wasm spasm: f64.add compiles and runs Spasm-compiled" {
    if (comptime !@import("spasm.zig").supported) return error.SkipZigTest;
    var buf: [8 + f64_add_body.len]u8 = undefined;
    const bytes = withPreamble(&buf, &f64_add_body);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const m = try wasm.decode(a, bytes);
    const mp = try a.create(wasm.Module);
    mp.* = m;

    var instance: interp.Instance = undefined;
    try interp.instantiate(&instance, a, testing.allocator, mp, .{});
    defer instance.deinit();
    instance.spasm_enabled = true;

    const fidx = funcExport(mp, "add") orelse return error.NoSuchExport;
    const cells = try a.alloc(u128, 2);
    cells[0] = @as(u128, @as(u64, @bitCast(@as(f64, 1.5))));
    cells[1] = @as(u128, @as(u64, @bitCast(@as(f64, 2.25))));

    const res = try interp.invoke(&instance, testing.allocator, fidx, cells);
    defer testing.allocator.free(res);

    // 1.5 + 2.25 == 3.75, computed in the FP unit via the fmov bridge.
    try testing.expectEqual(@as(f64, 3.75), @as(f64, @bitCast(@as(u64, @truncate(res[0])))));
    try testing.expect(instance.spasm_runs >= 1);
}

// An `(f64)->f64` unary exported as "op": local.get 0; f64.sqrt; end.
// (0x7c = f64 value type, 0x9f = f64.sqrt.)
const f64_sqrt_body = [_]u8{
    0x01, 0x06, 0x01, 0x60, 0x01, 0x7c, 0x01, 0x7c, // type (f64)->f64
    0x03, 0x02, 0x01, 0x00, // func 0 : type 0
    0x07, 0x06, 0x01, 0x02, 0x6f, 0x70, 0x00, 0x00, // export "op" -> 0
    0x0a, 0x07, 0x01, 0x05, 0x00, 0x20, 0x00, 0x9f, 0x0b, // local.get 0; f64.sqrt; end
};

test "wasm spasm: f64.sqrt compiles and runs in the FP unit" {
    if (comptime !@import("spasm.zig").supported) return error.SkipZigTest;
    var buf: [8 + f64_sqrt_body.len]u8 = undefined;
    const bytes = withPreamble(&buf, &f64_sqrt_body);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const m = try wasm.decode(a, bytes);
    const mp = try a.create(wasm.Module);
    mp.* = m;

    var instance: interp.Instance = undefined;
    try interp.instantiate(&instance, a, testing.allocator, mp, .{});
    defer instance.deinit();
    instance.spasm_enabled = true;

    const fidx = funcExport(mp, "op") orelse return error.NoSuchExport;
    const cells = try a.alloc(u128, 1);
    cells[0] = @as(u128, @as(u64, @bitCast(@as(f64, 16.0))));

    const res = try interp.invoke(&instance, testing.allocator, fidx, cells);
    defer testing.allocator.free(res);

    // sqrt(16.0) == 4.0, via FSQRT through the fmov bridge.
    try testing.expectEqual(@as(f64, 4.0), @as(f64, @bitCast(@as(u64, @truncate(res[0])))));
    try testing.expect(instance.spasm_runs >= 1);
}

// An `(f64,f64)->f64` minimum exported as "min" (0xa4 = f64.min).
const f64_min_body = [_]u8{
    0x01, 0x07, 0x01, 0x60, 0x02, 0x7c, 0x7c, 0x01, 0x7c, // type (f64,f64)->f64
    0x03, 0x02, 0x01, 0x00, // func 0 : type 0
    0x07, 0x07, 0x01, 0x03, 0x6d, 0x69, 0x6e, 0x00, 0x00, // export "min" -> 0
    0x0a, 0x09, 0x01, 0x07, 0x00, 0x20, 0x00, 0x20, 0x01, 0xa4, 0x0b, // local.get 0; local.get 1; f64.min; end
};

test "wasm spasm: f64.min compiles and runs in the FP unit" {
    if (comptime !@import("spasm.zig").supported) return error.SkipZigTest;
    var buf: [8 + f64_min_body.len]u8 = undefined;
    const bytes = withPreamble(&buf, &f64_min_body);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const m = try wasm.decode(a, bytes);
    const mp = try a.create(wasm.Module);
    mp.* = m;

    var instance: interp.Instance = undefined;
    try interp.instantiate(&instance, a, testing.allocator, mp, .{});
    defer instance.deinit();
    instance.spasm_enabled = true;

    const fidx = funcExport(mp, "min") orelse return error.NoSuchExport;
    const cells = try a.alloc(u128, 2);
    cells[0] = @as(u128, @as(u64, @bitCast(@as(f64, 3.0))));
    cells[1] = @as(u128, @as(u64, @bitCast(@as(f64, 5.0))));

    const res = try interp.invoke(&instance, testing.allocator, fidx, cells);
    defer testing.allocator.free(res);

    // min(3.0, 5.0) == 3.0, via FMIN.
    try testing.expectEqual(@as(f64, 3.0), @as(f64, @bitCast(@as(u64, @truncate(res[0])))));
    try testing.expect(instance.spasm_runs >= 1);
}

// An `(f64,f64)->f64` copysign exported as "cs" (0xa6 = f64.copysign).
const f64_copysign_body = [_]u8{
    0x01, 0x07, 0x01, 0x60, 0x02, 0x7c, 0x7c, 0x01, 0x7c, // type (f64,f64)->f64
    0x03, 0x02, 0x01, 0x00, // func 0 : type 0
    0x07, 0x06, 0x01, 0x02, 0x63, 0x73, 0x00, 0x00, // export "cs" -> 0
    0x0a, 0x09, 0x01, 0x07, 0x00, 0x20, 0x00, 0x20, 0x01, 0xa6, 0x0b, // local.get 0; local.get 1; f64.copysign; end
};

test "wasm spasm: f64.copysign combines magnitude and sign by bit ops" {
    if (comptime !@import("spasm.zig").supported) return error.SkipZigTest;
    var buf: [8 + f64_copysign_body.len]u8 = undefined;
    const bytes = withPreamble(&buf, &f64_copysign_body);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const m = try wasm.decode(a, bytes);
    const mp = try a.create(wasm.Module);
    mp.* = m;

    var instance: interp.Instance = undefined;
    try interp.instantiate(&instance, a, testing.allocator, mp, .{});
    defer instance.deinit();
    instance.spasm_enabled = true;

    const fidx = funcExport(mp, "cs") orelse return error.NoSuchExport;
    const cells = try a.alloc(u128, 2);
    cells[0] = @as(u128, @as(u64, @bitCast(@as(f64, 3.0))));
    cells[1] = @as(u128, @as(u64, @bitCast(@as(f64, -5.0))));

    const res = try interp.invoke(&instance, testing.allocator, fidx, cells);
    defer testing.allocator.free(res);

    // copysign(3.0, -5.0) == -3.0 — magnitude of a, sign of b.
    try testing.expectEqual(@as(f64, -3.0), @as(f64, @bitCast(@as(u64, @truncate(res[0])))));
    try testing.expect(instance.spasm_runs >= 1);
}

// An `(f32)->i32` reinterpret exported as "ri" (0xbc = i32.reinterpret_f32);
// the bits pass through unchanged.
const reinterpret_body = [_]u8{
    0x01, 0x06, 0x01, 0x60, 0x01, 0x7d, 0x01, 0x7f, // type (f32)->i32
    0x03, 0x02, 0x01, 0x00, // func 0 : type 0
    0x07, 0x06, 0x01, 0x02, 0x72, 0x69, 0x00, 0x00, // export "ri" -> 0
    0x0a, 0x07, 0x01, 0x05, 0x00, 0x20, 0x00, 0xbc, 0x0b, // local.get 0; i32.reinterpret_f32; end
};

test "wasm spasm: i32.reinterpret_f32 passes the bits through" {
    if (comptime !@import("spasm.zig").supported) return error.SkipZigTest;
    var buf: [8 + reinterpret_body.len]u8 = undefined;
    const bytes = withPreamble(&buf, &reinterpret_body);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const m = try wasm.decode(a, bytes);
    const mp = try a.create(wasm.Module);
    mp.* = m;

    var instance: interp.Instance = undefined;
    try interp.instantiate(&instance, a, testing.allocator, mp, .{});
    defer instance.deinit();
    instance.spasm_enabled = true;

    const fidx = funcExport(mp, "ri") orelse return error.NoSuchExport;
    const cells = try a.alloc(u128, 1);
    cells[0] = @as(u128, @as(u32, @bitCast(@as(f32, 1.0))));

    const res = try interp.invoke(&instance, testing.allocator, fidx, cells);
    defer testing.allocator.free(res);

    // reinterpret(1.0f) == 0x3f80_0000 — the f32 bit pattern of 1.0, as i32.
    try testing.expectEqual(@as(u32, 0x3f800000), @as(u32, @truncate(res[0])));
    try testing.expect(instance.spasm_runs >= 1);
}

// An `(f32)->f64` promote exported as "pr" (0xbb = f64.promote_f32).
const promote_body = [_]u8{
    0x01, 0x06, 0x01, 0x60, 0x01, 0x7d, 0x01, 0x7c, // type (f32)->f64
    0x03, 0x02, 0x01, 0x00, // func 0 : type 0
    0x07, 0x06, 0x01, 0x02, 0x70, 0x72, 0x00, 0x00, // export "pr" -> 0
    0x0a, 0x07, 0x01, 0x05, 0x00, 0x20, 0x00, 0xbb, 0x0b, // local.get 0; f64.promote_f32; end
};

test "wasm spasm: f64.promote_f32 widens via FCVT" {
    if (comptime !@import("spasm.zig").supported) return error.SkipZigTest;
    var buf: [8 + promote_body.len]u8 = undefined;
    const bytes = withPreamble(&buf, &promote_body);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const m = try wasm.decode(a, bytes);
    const mp = try a.create(wasm.Module);
    mp.* = m;

    var instance: interp.Instance = undefined;
    try interp.instantiate(&instance, a, testing.allocator, mp, .{});
    defer instance.deinit();
    instance.spasm_enabled = true;

    const fidx = funcExport(mp, "pr") orelse return error.NoSuchExport;
    const cells = try a.alloc(u128, 1);
    cells[0] = @as(u128, @as(u32, @bitCast(@as(f32, 1.5))));

    const res = try interp.invoke(&instance, testing.allocator, fidx, cells);
    defer testing.allocator.free(res);

    // promote(1.5f) == 1.5 in double precision.
    try testing.expectEqual(@as(f64, 1.5), @as(f64, @bitCast(@as(u64, @truncate(res[0])))));
    try testing.expect(instance.spasm_runs >= 1);
}

// An `(f64)->f32` demote exported as "dm" (0xb6 = f32.demote_f64).
const demote_body = [_]u8{
    0x01, 0x06, 0x01, 0x60, 0x01, 0x7c, 0x01, 0x7d, // type (f64)->f32
    0x03, 0x02, 0x01, 0x00, // func 0 : type 0
    0x07, 0x06, 0x01, 0x02, 0x64, 0x6d, 0x00, 0x00, // export "dm" -> 0
    0x0a, 0x07, 0x01, 0x05, 0x00, 0x20, 0x00, 0xb6, 0x0b, // local.get 0; f32.demote_f64; end
};

test "wasm spasm: f32.demote_f64 narrows via FCVT" {
    if (comptime !@import("spasm.zig").supported) return error.SkipZigTest;
    var buf: [8 + demote_body.len]u8 = undefined;
    const bytes = withPreamble(&buf, &demote_body);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const m = try wasm.decode(a, bytes);
    const mp = try a.create(wasm.Module);
    mp.* = m;

    var instance: interp.Instance = undefined;
    try interp.instantiate(&instance, a, testing.allocator, mp, .{});
    defer instance.deinit();
    instance.spasm_enabled = true;

    const fidx = funcExport(mp, "dm") orelse return error.NoSuchExport;
    const cells = try a.alloc(u128, 1);
    cells[0] = @as(u128, @as(u64, @bitCast(@as(f64, 1.5))));

    const res = try interp.invoke(&instance, testing.allocator, fidx, cells);
    defer testing.allocator.free(res);

    // demote(1.5) == 1.5f in single precision.
    try testing.expectEqual(@as(f32, 1.5), @as(f32, @bitCast(@as(u32, @truncate(res[0])))));
    try testing.expect(instance.spasm_runs >= 1);
}

// An `(i32)->f64` signed convert exported as "s" (0xb7 = f64.convert_i32_s).
const convert_i32_s_body = [_]u8{
    0x01, 0x06, 0x01, 0x60, 0x01, 0x7f, 0x01, 0x7c, // type (i32)->f64
    0x03, 0x02, 0x01, 0x00, // func 0 : type 0
    0x07, 0x05, 0x01, 0x01, 0x73, 0x00, 0x00, // export "s" -> 0
    0x0a, 0x07, 0x01, 0x05, 0x00, 0x20, 0x00, 0xb7, 0x0b, // local.get 0; f64.convert_i32_s; end
};

test "wasm spasm: f64.convert_i32_s widens a signed i32 via SCVTF" {
    if (comptime !@import("spasm.zig").supported) return error.SkipZigTest;
    var buf: [8 + convert_i32_s_body.len]u8 = undefined;
    const bytes = withPreamble(&buf, &convert_i32_s_body);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const m = try wasm.decode(a, bytes);
    const mp = try a.create(wasm.Module);
    mp.* = m;

    var instance: interp.Instance = undefined;
    try interp.instantiate(&instance, a, testing.allocator, mp, .{});
    defer instance.deinit();
    instance.spasm_enabled = true;

    const fidx = funcExport(mp, "s") orelse return error.NoSuchExport;
    const cells = try a.alloc(u128, 1);
    cells[0] = @as(u128, @as(u32, @bitCast(@as(i32, -5))));

    const res = try interp.invoke(&instance, testing.allocator, fidx, cells);
    defer testing.allocator.free(res);

    // (f64)(i32)-5 == -5.0 — the signed conversion.
    try testing.expectEqual(@as(f64, -5.0), @as(f64, @bitCast(@as(u64, @truncate(res[0])))));
    try testing.expect(instance.spasm_runs >= 1);
}

// An `(i32)->f32` unsigned convert exported as "u" (0xb3 = f32.convert_i32_u);
// 0x8000_0000 distinguishes the unsigned path (signed would give -2^31).
const convert_i32_u_body = [_]u8{
    0x01, 0x06, 0x01, 0x60, 0x01, 0x7f, 0x01, 0x7d, // type (i32)->f32
    0x03, 0x02, 0x01, 0x00, // func 0 : type 0
    0x07, 0x05, 0x01, 0x01, 0x75, 0x00, 0x00, // export "u" -> 0
    0x0a, 0x07, 0x01, 0x05, 0x00, 0x20, 0x00, 0xb3, 0x0b, // local.get 0; f32.convert_i32_u; end
};

test "wasm spasm: f32.convert_i32_u widens an unsigned i32 via UCVTF" {
    if (comptime !@import("spasm.zig").supported) return error.SkipZigTest;
    var buf: [8 + convert_i32_u_body.len]u8 = undefined;
    const bytes = withPreamble(&buf, &convert_i32_u_body);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const m = try wasm.decode(a, bytes);
    const mp = try a.create(wasm.Module);
    mp.* = m;

    var instance: interp.Instance = undefined;
    try interp.instantiate(&instance, a, testing.allocator, mp, .{});
    defer instance.deinit();
    instance.spasm_enabled = true;

    const fidx = funcExport(mp, "u") orelse return error.NoSuchExport;
    const cells = try a.alloc(u128, 1);
    cells[0] = @as(u128, @as(u32, 0x80000000));

    const res = try interp.invoke(&instance, testing.allocator, fidx, cells);
    defer testing.allocator.free(res);

    // (f32)(u32)0x8000_0000 == 2147483648.0 (2^31), not the signed -2^31.
    try testing.expectEqual(@as(f32, 2147483648.0), @as(f32, @bitCast(@as(u32, @truncate(res[0])))));
    try testing.expect(instance.spasm_runs >= 1);
}

// An `(i64)->f64` signed convert exported as "l" (0xb9 = f64.convert_i64_s).
const convert_i64_s_body = [_]u8{
    0x01, 0x06, 0x01, 0x60, 0x01, 0x7e, 0x01, 0x7c, // type (i64)->f64
    0x03, 0x02, 0x01, 0x00, // func 0 : type 0
    0x07, 0x05, 0x01, 0x01, 0x6c, 0x00, 0x00, // export "l" -> 0
    0x0a, 0x07, 0x01, 0x05, 0x00, 0x20, 0x00, 0xb9, 0x0b, // local.get 0; f64.convert_i64_s; end
};

test "wasm spasm: f64.convert_i64_s widens a signed i64 via SCVTF (X-form)" {
    if (comptime !@import("spasm.zig").supported) return error.SkipZigTest;
    var buf: [8 + convert_i64_s_body.len]u8 = undefined;
    const bytes = withPreamble(&buf, &convert_i64_s_body);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const m = try wasm.decode(a, bytes);
    const mp = try a.create(wasm.Module);
    mp.* = m;

    var instance: interp.Instance = undefined;
    try interp.instantiate(&instance, a, testing.allocator, mp, .{});
    defer instance.deinit();
    instance.spasm_enabled = true;

    const fidx = funcExport(mp, "l") orelse return error.NoSuchExport;
    const cells = try a.alloc(u128, 1);
    cells[0] = @as(u128, @as(u64, @bitCast(@as(i64, -5))));

    const res = try interp.invoke(&instance, testing.allocator, fidx, cells);
    defer testing.allocator.free(res);

    // (f64)(i64)-5 == -5.0 — the 64-bit signed conversion.
    try testing.expectEqual(@as(f64, -5.0), @as(f64, @bitCast(@as(u64, @truncate(res[0])))));
    try testing.expect(instance.spasm_runs >= 1);
}

// An `(f32)->i32` saturating truncation exported as "ts": local.get 0;
// i32.trunc_sat_f32_s; end. The op is the 0xFC prefix + sub-opcode 0.
const trunc_sat_s_body = [_]u8{
    0x01, 0x06, 0x01, 0x60, 0x01, 0x7d, 0x01, 0x7f, // type (f32)->i32
    0x03, 0x02, 0x01, 0x00, // func 0 : type 0
    0x07, 0x06, 0x01, 0x02, 0x74, 0x73, 0x00, 0x00, // export "ts" -> 0
    0x0a, 0x08, 0x01, 0x06, 0x00, 0x20, 0x00, 0xfc, 0x00, 0x0b, // local.get 0; i32.trunc_sat_f32_s; end
};

test "wasm spasm: i32.trunc_sat_f32_s saturates out-of-range via FCVTZS" {
    if (comptime !@import("spasm.zig").supported) return error.SkipZigTest;
    var buf: [8 + trunc_sat_s_body.len]u8 = undefined;
    const bytes = withPreamble(&buf, &trunc_sat_s_body);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const m = try wasm.decode(a, bytes);
    const mp = try a.create(wasm.Module);
    mp.* = m;

    var instance: interp.Instance = undefined;
    try interp.instantiate(&instance, a, testing.allocator, mp, .{});
    defer instance.deinit();
    instance.spasm_enabled = true;

    const fidx = funcExport(mp, "ts") orelse return error.NoSuchExport;
    const cells = try a.alloc(u128, 1);
    cells[0] = @as(u128, @as(u32, @bitCast(@as(f32, 1e30))));

    const res = try interp.invoke(&instance, testing.allocator, fidx, cells);
    defer testing.allocator.free(res);

    // 1e30 is far past INT32_MAX, so the saturating truncation clamps to it.
    try testing.expectEqual(@as(u32, 0x7fffffff), @as(u32, @truncate(res[0])));
    try testing.expect(instance.spasm_runs >= 1);
}

// An `(f64)->i64` saturating truncation exported as "tu": local.get 0;
// i64.trunc_sat_f64_u; end. The op is the 0xFC prefix + sub-opcode 7.
const trunc_sat_u_body = [_]u8{
    0x01, 0x06, 0x01, 0x60, 0x01, 0x7c, 0x01, 0x7e, // type (f64)->i64
    0x03, 0x02, 0x01, 0x00, // func 0 : type 0
    0x07, 0x06, 0x01, 0x02, 0x74, 0x75, 0x00, 0x00, // export "tu" -> 0
    0x0a, 0x08, 0x01, 0x06, 0x00, 0x20, 0x00, 0xfc, 0x07, 0x0b, // local.get 0; i64.trunc_sat_f64_u; end
};

test "wasm spasm: i64.trunc_sat_f64_u maps NaN to zero via FCVTZU" {
    if (comptime !@import("spasm.zig").supported) return error.SkipZigTest;
    var buf: [8 + trunc_sat_u_body.len]u8 = undefined;
    const bytes = withPreamble(&buf, &trunc_sat_u_body);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const m = try wasm.decode(a, bytes);
    const mp = try a.create(wasm.Module);
    mp.* = m;

    var instance: interp.Instance = undefined;
    try interp.instantiate(&instance, a, testing.allocator, mp, .{});
    defer instance.deinit();
    instance.spasm_enabled = true;

    const fidx = funcExport(mp, "tu") orelse return error.NoSuchExport;
    const cells = try a.alloc(u128, 1);
    cells[0] = @as(u128, @as(u64, 0x7ff8000000000000)); // canonical f64 NaN

    const res = try interp.invoke(&instance, testing.allocator, fidx, cells);
    defer testing.allocator.free(res);

    // The saturating truncation maps NaN to 0 (FCVTZU's NaN behavior).
    try testing.expectEqual(@as(u64, 0), @as(u64, @truncate(res[0])));
    try testing.expect(instance.spasm_runs >= 1);
}

// An `(f32)->i32` trapping truncation exported as "t": local.get 0;
// i32.trunc_f32_s; end. (0xa8 = i32.trunc_f32_s.) Reused by the three
// trapping-truncation tests below (in-range, NaN, overflow).
const trunc_trap_body = [_]u8{
    0x01, 0x06, 0x01, 0x60, 0x01, 0x7d, 0x01, 0x7f, // type (f32)->i32
    0x03, 0x02, 0x01, 0x00, // func 0 : type 0
    0x07, 0x05, 0x01, 0x01, 0x74, 0x00, 0x00, // export "t" -> 0
    0x0a, 0x07, 0x01, 0x05, 0x00, 0x20, 0x00, 0xa8, 0x0b, // local.get 0; i32.trunc_f32_s; end
};

fn truncTrapInstance(a: std.mem.Allocator, mp: **wasm.Module) !interp.Instance {
    // The module bytes must outlive this helper — the decoded Module
    // borrows slices into them — so allocate them in the caller's arena
    // rather than this frame's stack.
    const buf = try a.alloc(u8, 8 + trunc_trap_body.len);
    const bytes = withPreamble(buf, &trunc_trap_body);
    const m = try wasm.decode(a, bytes);
    const p = try a.create(wasm.Module);
    p.* = m;
    mp.* = p;
    var instance: interp.Instance = undefined;
    try interp.instantiate(&instance, a, testing.allocator, p, .{});
    instance.spasm_enabled = true;
    return instance;
}

test "wasm spasm: i32.trunc_f32_s converts an in-range value via FCVTZS" {
    if (comptime !@import("spasm.zig").supported) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var mp: *wasm.Module = undefined;
    var instance = try truncTrapInstance(a, &mp);
    defer instance.deinit();

    const fidx = funcExport(mp, "t") orelse return error.NoSuchExport;
    const cells = try a.alloc(u128, 1);
    cells[0] = @as(u128, @as(u32, @bitCast(@as(f32, 3.7))));

    const res = try interp.invoke(&instance, testing.allocator, fidx, cells);
    defer testing.allocator.free(res);

    // trunc(3.7) == 3, in range, so no trap.
    try testing.expectEqual(@as(u32, 3), @as(u32, @truncate(res[0])));
    try testing.expect(instance.spasm_runs >= 1);
}

test "wasm spasm: i32.trunc_f32_s traps on NaN (invalid conversion)" {
    if (comptime !@import("spasm.zig").supported) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var mp: *wasm.Module = undefined;
    var instance = try truncTrapInstance(a, &mp);
    defer instance.deinit();

    const fidx = funcExport(mp, "t") orelse return error.NoSuchExport;
    const cells = try a.alloc(u128, 1);
    cells[0] = @as(u128, @as(u32, 0x7fc00000)); // f32 qNaN

    try testing.expectError(error.InvalidConversionToInteger, interp.invoke(&instance, testing.allocator, fidx, cells));
    // The trap came from Spasm-compiled code, not a degrade to the interpreter.
    try testing.expect(instance.spasm_runs >= 1);
}

test "wasm spasm: i32.trunc_f32_s traps on overflow (out of range)" {
    if (comptime !@import("spasm.zig").supported) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var mp: *wasm.Module = undefined;
    var instance = try truncTrapInstance(a, &mp);
    defer instance.deinit();

    const fidx = funcExport(mp, "t") orelse return error.NoSuchExport;
    const cells = try a.alloc(u128, 1);
    cells[0] = @as(u128, @as(u32, @bitCast(@as(f32, 1e30)))); // far past INT32_MAX

    try testing.expectError(error.IntegerOverflow, interp.invoke(&instance, testing.allocator, fidx, cells));
    try testing.expect(instance.spasm_runs >= 1);
}

// An `(i32)->i32` count-leading-zeros exported as "op" (0x67 = i32.clz).
const i32_clz_body = [_]u8{
    0x01, 0x06, 0x01, 0x60, 0x01, 0x7f, 0x01, 0x7f, // type (i32)->i32
    0x03, 0x02, 0x01, 0x00, // func 0 : type 0
    0x07, 0x06, 0x01, 0x02, 0x6f, 0x70, 0x00, 0x00, // export "op" -> 0
    0x0a, 0x07, 0x01, 0x05, 0x00, 0x20, 0x00, 0x67, 0x0b, // local.get 0; i32.clz; end
};

test "wasm spasm: i32.clz counts leading zeros via CLZ" {
    if (comptime !@import("spasm.zig").supported) return error.SkipZigTest;
    var buf: [8 + i32_clz_body.len]u8 = undefined;
    const bytes = withPreamble(&buf, &i32_clz_body);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const m = try wasm.decode(a, bytes);
    const mp = try a.create(wasm.Module);
    mp.* = m;

    var instance: interp.Instance = undefined;
    try interp.instantiate(&instance, a, testing.allocator, mp, .{});
    defer instance.deinit();
    instance.spasm_enabled = true;

    const fidx = funcExport(mp, "op") orelse return error.NoSuchExport;
    const cells = try a.alloc(u128, 1);
    cells[0] = @as(u128, @as(u32, 1));

    const res = try interp.invoke(&instance, testing.allocator, fidx, cells);
    defer testing.allocator.free(res);

    // clz(0x00000001) == 31.
    try testing.expectEqual(@as(u32, 31), @as(u32, @truncate(res[0])));
    try testing.expect(instance.spasm_runs >= 1);
}

// An `(i32)->i32` count-trailing-zeros exported as "op" (0x68 = i32.ctz).
const i32_ctz_body = [_]u8{
    0x01, 0x06, 0x01, 0x60, 0x01, 0x7f, 0x01, 0x7f, // type (i32)->i32
    0x03, 0x02, 0x01, 0x00, // func 0 : type 0
    0x07, 0x06, 0x01, 0x02, 0x6f, 0x70, 0x00, 0x00, // export "op" -> 0
    0x0a, 0x07, 0x01, 0x05, 0x00, 0x20, 0x00, 0x68, 0x0b, // local.get 0; i32.ctz; end
};

test "wasm spasm: i32.ctz counts trailing zeros via RBIT+CLZ" {
    if (comptime !@import("spasm.zig").supported) return error.SkipZigTest;
    var buf: [8 + i32_ctz_body.len]u8 = undefined;
    const bytes = withPreamble(&buf, &i32_ctz_body);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const m = try wasm.decode(a, bytes);
    const mp = try a.create(wasm.Module);
    mp.* = m;

    var instance: interp.Instance = undefined;
    try interp.instantiate(&instance, a, testing.allocator, mp, .{});
    defer instance.deinit();
    instance.spasm_enabled = true;

    const fidx = funcExport(mp, "op") orelse return error.NoSuchExport;
    const cells = try a.alloc(u128, 1);
    cells[0] = @as(u128, @as(u32, 8)); // 0b1000

    const res = try interp.invoke(&instance, testing.allocator, fidx, cells);
    defer testing.allocator.free(res);

    // ctz(0b1000) == 3.
    try testing.expectEqual(@as(u32, 3), @as(u32, @truncate(res[0])));
    try testing.expect(instance.spasm_runs >= 1);
}

// An `(i64)->i64` count-leading-zeros exported as "op" (0x79 = i64.clz).
const i64_clz_body = [_]u8{
    0x01, 0x06, 0x01, 0x60, 0x01, 0x7e, 0x01, 0x7e, // type (i64)->i64
    0x03, 0x02, 0x01, 0x00, // func 0 : type 0
    0x07, 0x06, 0x01, 0x02, 0x6f, 0x70, 0x00, 0x00, // export "op" -> 0
    0x0a, 0x07, 0x01, 0x05, 0x00, 0x20, 0x00, 0x79, 0x0b, // local.get 0; i64.clz; end
};

test "wasm spasm: i64.clz counts leading zeros via CLZ (X-form)" {
    if (comptime !@import("spasm.zig").supported) return error.SkipZigTest;
    var buf: [8 + i64_clz_body.len]u8 = undefined;
    const bytes = withPreamble(&buf, &i64_clz_body);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const m = try wasm.decode(a, bytes);
    const mp = try a.create(wasm.Module);
    mp.* = m;

    var instance: interp.Instance = undefined;
    try interp.instantiate(&instance, a, testing.allocator, mp, .{});
    defer instance.deinit();
    instance.spasm_enabled = true;

    const fidx = funcExport(mp, "op") orelse return error.NoSuchExport;
    const cells = try a.alloc(u128, 1);
    cells[0] = @as(u128, @as(u64, 1));

    const res = try interp.invoke(&instance, testing.allocator, fidx, cells);
    defer testing.allocator.free(res);

    // clz(0x0000000000000001) == 63.
    try testing.expectEqual(@as(u64, 63), @as(u64, @truncate(res[0])));
    try testing.expect(instance.spasm_runs >= 1);
}

// An `(i32)->i32` sign-extend-byte exported as "op" (0xc0 = i32.extend8_s).
const i32_extend8_body = [_]u8{
    0x01, 0x06, 0x01, 0x60, 0x01, 0x7f, 0x01, 0x7f, // type (i32)->i32
    0x03, 0x02, 0x01, 0x00, // func 0 : type 0
    0x07, 0x06, 0x01, 0x02, 0x6f, 0x70, 0x00, 0x00, // export "op" -> 0
    0x0a, 0x07, 0x01, 0x05, 0x00, 0x20, 0x00, 0xc0, 0x0b, // local.get 0; i32.extend8_s; end
};

test "wasm spasm: i32.extend8_s sign-extends the low byte via SXTB" {
    if (comptime !@import("spasm.zig").supported) return error.SkipZigTest;
    var buf: [8 + i32_extend8_body.len]u8 = undefined;
    const bytes = withPreamble(&buf, &i32_extend8_body);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const m = try wasm.decode(a, bytes);
    const mp = try a.create(wasm.Module);
    mp.* = m;

    var instance: interp.Instance = undefined;
    try interp.instantiate(&instance, a, testing.allocator, mp, .{});
    defer instance.deinit();
    instance.spasm_enabled = true;

    const fidx = funcExport(mp, "op") orelse return error.NoSuchExport;
    const cells = try a.alloc(u128, 1);
    cells[0] = @as(u128, @as(u32, 0xff)); // low byte 0xFF = -1 as i8

    const res = try interp.invoke(&instance, testing.allocator, fidx, cells);
    defer testing.allocator.free(res);

    // extend8_s(0xff) sign-extends to 0xffffffff (-1).
    try testing.expectEqual(@as(u32, 0xffffffff), @as(u32, @truncate(res[0])));
    try testing.expect(instance.spasm_runs >= 1);
}

// An `(i64)->i64` sign-extend-word exported as "op" (0xc4 = i64.extend32_s).
const i64_extend32_body = [_]u8{
    0x01, 0x06, 0x01, 0x60, 0x01, 0x7e, 0x01, 0x7e, // type (i64)->i64
    0x03, 0x02, 0x01, 0x00, // func 0 : type 0
    0x07, 0x06, 0x01, 0x02, 0x6f, 0x70, 0x00, 0x00, // export "op" -> 0
    0x0a, 0x07, 0x01, 0x05, 0x00, 0x20, 0x00, 0xc4, 0x0b, // local.get 0; i64.extend32_s; end
};

test "wasm spasm: i64.extend32_s sign-extends the low word via SXTW" {
    if (comptime !@import("spasm.zig").supported) return error.SkipZigTest;
    var buf: [8 + i64_extend32_body.len]u8 = undefined;
    const bytes = withPreamble(&buf, &i64_extend32_body);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const m = try wasm.decode(a, bytes);
    const mp = try a.create(wasm.Module);
    mp.* = m;

    var instance: interp.Instance = undefined;
    try interp.instantiate(&instance, a, testing.allocator, mp, .{});
    defer instance.deinit();
    instance.spasm_enabled = true;

    const fidx = funcExport(mp, "op") orelse return error.NoSuchExport;
    const cells = try a.alloc(u128, 1);
    cells[0] = @as(u128, @as(u64, 0x80000000)); // low word's sign bit set

    const res = try interp.invoke(&instance, testing.allocator, fidx, cells);
    defer testing.allocator.free(res);

    // extend32_s(0x80000000) sign-extends to 0xffffffff80000000 (-2^31).
    try testing.expectEqual(@as(u64, 0xffffffff80000000), @as(u64, @truncate(res[0])));
    try testing.expect(instance.spasm_runs >= 1);
}

// An `(i32)->i32` population-count exported as "op" (0x69 = i32.popcnt).
const i32_popcnt_body = [_]u8{
    0x01, 0x06, 0x01, 0x60, 0x01, 0x7f, 0x01, 0x7f, // type (i32)->i32
    0x03, 0x02, 0x01, 0x00, // func 0 : type 0
    0x07, 0x06, 0x01, 0x02, 0x6f, 0x70, 0x00, 0x00, // export "op" -> 0
    0x0a, 0x07, 0x01, 0x05, 0x00, 0x20, 0x00, 0x69, 0x0b, // local.get 0; i32.popcnt; end
};

test "wasm spasm: i32.popcnt counts set bits via CNT+ADDV" {
    if (comptime !@import("spasm.zig").supported) return error.SkipZigTest;
    var buf: [8 + i32_popcnt_body.len]u8 = undefined;
    const bytes = withPreamble(&buf, &i32_popcnt_body);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const m = try wasm.decode(a, bytes);
    const mp = try a.create(wasm.Module);
    mp.* = m;

    var instance: interp.Instance = undefined;
    try interp.instantiate(&instance, a, testing.allocator, mp, .{});
    defer instance.deinit();
    instance.spasm_enabled = true;

    const fidx = funcExport(mp, "op") orelse return error.NoSuchExport;
    const cells = try a.alloc(u128, 1);
    cells[0] = @as(u128, @as(u32, 0xffffffff)); // all 32 bits set

    const res = try interp.invoke(&instance, testing.allocator, fidx, cells);
    defer testing.allocator.free(res);

    // popcnt(0xffffffff) == 32 — the cross-byte sum of four 0xff bytes.
    try testing.expectEqual(@as(u32, 32), @as(u32, @truncate(res[0])));
    try testing.expect(instance.spasm_runs >= 1);
}

// An `(i64)->i64` population-count exported as "op" (0x7b = i64.popcnt).
const i64_popcnt_body = [_]u8{
    0x01, 0x06, 0x01, 0x60, 0x01, 0x7e, 0x01, 0x7e, // type (i64)->i64
    0x03, 0x02, 0x01, 0x00, // func 0 : type 0
    0x07, 0x06, 0x01, 0x02, 0x6f, 0x70, 0x00, 0x00, // export "op" -> 0
    0x0a, 0x07, 0x01, 0x05, 0x00, 0x20, 0x00, 0x7b, 0x0b, // local.get 0; i64.popcnt; end
};

test "wasm spasm: i64.popcnt counts set bits via CNT+ADDV (X-form)" {
    if (comptime !@import("spasm.zig").supported) return error.SkipZigTest;
    var buf: [8 + i64_popcnt_body.len]u8 = undefined;
    const bytes = withPreamble(&buf, &i64_popcnt_body);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const m = try wasm.decode(a, bytes);
    const mp = try a.create(wasm.Module);
    mp.* = m;

    var instance: interp.Instance = undefined;
    try interp.instantiate(&instance, a, testing.allocator, mp, .{});
    defer instance.deinit();
    instance.spasm_enabled = true;

    const fidx = funcExport(mp, "op") orelse return error.NoSuchExport;
    const cells = try a.alloc(u128, 1);
    cells[0] = @as(u128, @as(u64, 0xffffffffffffffff)); // all 64 bits set

    const res = try interp.invoke(&instance, testing.allocator, fidx, cells);
    defer testing.allocator.free(res);

    // popcnt(~0) == 64 — the cross-byte sum of eight 0xff bytes.
    try testing.expectEqual(@as(u64, 64), @as(u64, @truncate(res[0])));
    try testing.expect(instance.spasm_runs >= 1);
}

// A `()->i32` reading a mutable i32 global initialized to 42: a global
// section (id 6) declares one mutable i32 (init `i32.const 42`), and the
// body is `global.get 0; end`. (0x23 = global.get.)
const global_get_body = [_]u8{
    0x01, 0x05, 0x01, 0x60, 0x00, 0x01, 0x7f, // type ()->i32
    0x03, 0x02, 0x01, 0x00, // func 0 : type 0
    0x06, 0x06, 0x01, 0x7f, 0x01, 0x41, 0x2a, 0x0b, // global: mutable i32 = 42
    0x07, 0x05, 0x01, 0x01, 0x67, 0x00, 0x00, // export "g" -> 0
    0x0a, 0x06, 0x01, 0x04, 0x00, 0x23, 0x00, 0x0b, // global.get 0; end
};

test "wasm spasm: global.get reads the instance global" {
    if (comptime !@import("spasm.zig").supported) return error.SkipZigTest;
    var buf: [8 + global_get_body.len]u8 = undefined;
    const bytes = withPreamble(&buf, &global_get_body);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const m = try wasm.decode(a, bytes);
    const mp = try a.create(wasm.Module);
    mp.* = m;

    var instance: interp.Instance = undefined;
    try interp.instantiate(&instance, a, testing.allocator, mp, .{});
    defer instance.deinit();
    instance.spasm_enabled = true;

    const fidx = funcExport(mp, "g") orelse return error.NoSuchExport;
    const res = try interp.invoke(&instance, testing.allocator, fidx, &.{});
    defer testing.allocator.free(res);

    // global.get 0 reads the init value, 42.
    try testing.expectEqual(@as(u32, 42), @as(u32, @truncate(res[0])));
    try testing.expect(instance.spasm_runs >= 1);
}

// An `(i32)->i32` round-trip through a mutable i32 global (init 0): the
// body is `local.get 0; global.set 0; global.get 0; end`, so it stores the
// argument and reads it back. (0x24 = global.set, 0x23 = global.get.)
const global_set_body = [_]u8{
    0x01, 0x06, 0x01, 0x60, 0x01, 0x7f, 0x01, 0x7f, // type (i32)->i32
    0x03, 0x02, 0x01, 0x00, // func 0 : type 0
    0x06, 0x06, 0x01, 0x7f, 0x01, 0x41, 0x00, 0x0b, // global: mutable i32 = 0
    0x07, 0x05, 0x01, 0x01, 0x67, 0x00, 0x00, // export "g" -> 0
    0x0a, 0x0a, 0x01, 0x08, 0x00, 0x20, 0x00, 0x24, 0x00, 0x23, 0x00, 0x0b, // local.get 0; global.set 0; global.get 0; end
};

test "wasm spasm: global.set then global.get round-trips" {
    if (comptime !@import("spasm.zig").supported) return error.SkipZigTest;
    var buf: [8 + global_set_body.len]u8 = undefined;
    const bytes = withPreamble(&buf, &global_set_body);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const m = try wasm.decode(a, bytes);
    const mp = try a.create(wasm.Module);
    mp.* = m;

    var instance: interp.Instance = undefined;
    try interp.instantiate(&instance, a, testing.allocator, mp, .{});
    defer instance.deinit();
    instance.spasm_enabled = true;

    const fidx = funcExport(mp, "g") orelse return error.NoSuchExport;
    const cells = try a.alloc(u128, 1);
    cells[0] = @as(u128, @as(u32, 99));

    const res = try interp.invoke(&instance, testing.allocator, fidx, cells);
    defer testing.allocator.free(res);

    // The global was set to 99, then read back.
    try testing.expectEqual(@as(u32, 99), @as(u32, @truncate(res[0])));
    try testing.expect(instance.spasm_runs >= 1);
}

// An `(f64,f64)->i32` ordered less-than exported as "lt": local.get 0;
// local.get 1; f64.lt; end. (0x63 is f64.lt; the result is an i32.)
const f64_lt_body = [_]u8{
    0x01, 0x07, 0x01, 0x60, 0x02, 0x7c, 0x7c, 0x01, 0x7f, // type (f64,f64)->i32
    0x03, 0x02, 0x01, 0x00, // func 0 : type 0
    0x07, 0x06, 0x01, 0x02, 0x6c, 0x74, 0x00, 0x00, // export "lt" -> 0
    0x0a, 0x09, 0x01, 0x07, 0x00, 0x20, 0x00, 0x20, 0x01, 0x63, 0x0b, // local.get 0; local.get 1; f64.lt; end
};

test "wasm spasm: f64.lt compiles and compares in the FP unit" {
    if (comptime !@import("spasm.zig").supported) return error.SkipZigTest;
    var buf: [8 + f64_lt_body.len]u8 = undefined;
    const bytes = withPreamble(&buf, &f64_lt_body);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const m = try wasm.decode(a, bytes);
    const mp = try a.create(wasm.Module);
    mp.* = m;

    var instance: interp.Instance = undefined;
    try interp.instantiate(&instance, a, testing.allocator, mp, .{});
    defer instance.deinit();
    instance.spasm_enabled = true;

    const fidx = funcExport(mp, "lt") orelse return error.NoSuchExport;
    const cells = try a.alloc(u128, 2);
    cells[0] = @as(u128, @as(u64, @bitCast(@as(f64, 1.5))));
    cells[1] = @as(u128, @as(u64, @bitCast(@as(f64, 2.5))));

    const res = try interp.invoke(&instance, testing.allocator, fidx, cells);
    defer testing.allocator.free(res);

    try testing.expectEqual(@as(u32, 1), @as(u32, @truncate(res[0]))); // 1.5 < 2.5
    try testing.expect(instance.spasm_runs >= 1);
}

// A one-page-memory module: `(i32)->f64` exported as "ld" — local.get 0;
// f64.load align=3 off=0; end.
const f64_load_body = [_]u8{
    0x01, 0x06, 0x01, 0x60, 0x01, 0x7f, 0x01, 0x7c, // type (i32)->f64
    0x03, 0x02, 0x01, 0x00, // func 0 : type 0
    0x05, 0x03, 0x01, 0x00, 0x01, // memory: one page
    0x07, 0x06, 0x01, 0x02, 0x6c, 0x64, 0x00, 0x00, // export "ld" -> 0
    0x0a, 0x09, 0x01, 0x07, 0x00, 0x20, 0x00, 0x2b, 0x03, 0x00, 0x0b, // local.get 0; f64.load a=3 o=0; end
};

test "wasm spasm: f64.load reads an eight-byte double" {
    if (comptime !@import("spasm.zig").supported) return error.SkipZigTest;
    var buf: [8 + f64_load_body.len]u8 = undefined;
    const bytes = withPreamble(&buf, &f64_load_body);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const m = try wasm.decode(a, bytes);
    const mp = try a.create(wasm.Module);
    mp.* = m;

    var instance: interp.Instance = undefined;
    try interp.instantiate(&instance, a, testing.allocator, mp, .{});
    defer instance.deinit();
    instance.spasm_enabled = true;

    std.mem.writeInt(u64, instance.memories[0].data[8..][0..8], @as(u64, @bitCast(@as(f64, 3.14159))), .little);
    const fidx = funcExport(mp, "ld") orelse return error.NoSuchExport;
    const cells = try a.alloc(u128, 1);
    cells[0] = @as(u128, 8);

    const res = try interp.invoke(&instance, testing.allocator, fidx, cells);
    defer testing.allocator.free(res);

    try testing.expectEqual(@as(f64, 3.14159), @as(f64, @bitCast(@as(u64, @truncate(res[0])))));
    try testing.expect(instance.spasm_runs >= 1);
}

// An `(f32,f32)->f32` adder exported as "add" (0x7d = f32, 0x92 = f32.add).
const f32_add_body = [_]u8{
    0x01, 0x07, 0x01, 0x60, 0x02, 0x7d, 0x7d, 0x01, 0x7d, // type (f32,f32)->f32
    0x03, 0x02, 0x01, 0x00, // func 0 : type 0
    0x07, 0x07, 0x01, 0x03, 0x61, 0x64, 0x64, 0x00, 0x00, // export "add" -> 0
    0x0a, 0x09, 0x01, 0x07, 0x00, 0x20, 0x00, 0x20, 0x01, 0x92, 0x0b, // local.get 0; local.get 1; f32.add; end
};

test "wasm spasm: f32.add compiles and runs Spasm-compiled" {
    if (comptime !@import("spasm.zig").supported) return error.SkipZigTest;
    var buf: [8 + f32_add_body.len]u8 = undefined;
    const bytes = withPreamble(&buf, &f32_add_body);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const m = try wasm.decode(a, bytes);
    const mp = try a.create(wasm.Module);
    mp.* = m;

    var instance: interp.Instance = undefined;
    try interp.instantiate(&instance, a, testing.allocator, mp, .{});
    defer instance.deinit();
    instance.spasm_enabled = true;

    const fidx = funcExport(mp, "add") orelse return error.NoSuchExport;
    const cells = try a.alloc(u128, 2);
    cells[0] = @as(u128, @as(u32, @bitCast(@as(f32, 1.5))));
    cells[1] = @as(u128, @as(u32, @bitCast(@as(f32, 2.25))));

    const res = try interp.invoke(&instance, testing.allocator, fidx, cells);
    defer testing.allocator.free(res);

    // 1.5 + 2.25 == 3.75 in single precision, via the S-register bridge.
    try testing.expectEqual(@as(f32, 3.75), @as(f32, @bitCast(@as(u32, @truncate(res[0])))));
    try testing.expect(instance.spasm_runs >= 1);
}

// An `(f32)->f32` unary exported as "op": local.get 0; f32.sqrt; end.
// (0x7d = f32 value type, 0x91 = f32.sqrt.)
const f32_sqrt_body = [_]u8{
    0x01, 0x06, 0x01, 0x60, 0x01, 0x7d, 0x01, 0x7d, // type (f32)->f32
    0x03, 0x02, 0x01, 0x00, // func 0 : type 0
    0x07, 0x06, 0x01, 0x02, 0x6f, 0x70, 0x00, 0x00, // export "op" -> 0
    0x0a, 0x07, 0x01, 0x05, 0x00, 0x20, 0x00, 0x91, 0x0b, // local.get 0; f32.sqrt; end
};

test "wasm spasm: f32.sqrt compiles and runs in the FP unit" {
    if (comptime !@import("spasm.zig").supported) return error.SkipZigTest;
    var buf: [8 + f32_sqrt_body.len]u8 = undefined;
    const bytes = withPreamble(&buf, &f32_sqrt_body);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const m = try wasm.decode(a, bytes);
    const mp = try a.create(wasm.Module);
    mp.* = m;

    var instance: interp.Instance = undefined;
    try interp.instantiate(&instance, a, testing.allocator, mp, .{});
    defer instance.deinit();
    instance.spasm_enabled = true;

    const fidx = funcExport(mp, "op") orelse return error.NoSuchExport;
    const cells = try a.alloc(u128, 1);
    cells[0] = @as(u128, @as(u32, @bitCast(@as(f32, 16.0))));

    const res = try interp.invoke(&instance, testing.allocator, fidx, cells);
    defer testing.allocator.free(res);

    // sqrt(16.0) == 4.0 in single precision, via FSQRT through the W↔S bridge.
    try testing.expectEqual(@as(f32, 4.0), @as(f32, @bitCast(@as(u32, @truncate(res[0])))));
    try testing.expect(instance.spasm_runs >= 1);
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
    try testing.expectEqual(@import("types.zig").ValType.funcref, m.tables[0].elem);
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

test "wasm validator: call_ref on an empty stack is a type error" {
    // §3.3 — `call_ref $t` pops a (ref null $t); with nothing on the
    // stack the function is invalid (the opcode itself is implemented).
    // body: 0 locals, call_ref 0, end
    const code_body = [_]u8{ 0x00, 0x14, 0x00, 0x0b };
    try expectFuncInvalid(error.StackUnderflow, &.{}, &.{}, &code_body);
}

test "wasm decoder: accepts a typed reference value type (function-references)" {
    // §5.3.1 — `(ref null $t)` is 0x63 + an s33 heap type. The decoder
    // parses it; the type index is range-checked at validation.
    // type section: 1 type (func ()->((ref null 0)))
    const body = [_]u8{ 0x01, 0x06, 0x01, 0x60, 0x00, 0x01, 0x63, 0x00 };
    var buf: [8 + body.len]u8 = undefined;
    const bytes = withPreamble(&buf, &body);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const m = try wasm.decode(arena.allocator(), bytes);
    try testing.expectEqual(@as(usize, 1), m.types.len);
    try testing.expect(m.types[0].results[0].isRef());
    try testing.expectEqual(@as(?u32, 0), m.types[0].results[0].concreteIndex());
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
    try expectFuncInvalid(error.UnknownMemory, &.{}, &.{I32}, &.{ 0x00, 0x41, 0x00, 0x28, 0x02, 0x00, 0x0b });
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
    const importer = try instOf(a, ibytes, .{ .globals = &.{provider.exportedGlobal("g").?} });
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

test "wasm exceptions: throw with no handler is an uncaught trap" {
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

// ── multiple memories (§2.5.8 — Wasm 3.0 multi-memory) ───────────────

test "wasm multi-memory: stores route to distinct memories via the memarg index" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tbody = [_]u8{ 0x01, 0x60, 0x00, 0x01, 0x7f };
    const fbody = [_]u8{ 0x01, 0x00 };
    const mbody = [_]u8{ 0x02, 0x00, 0x01, 0x00, 0x01 }; // two memories, min 1 page each
    const xbody = [_]u8{ 0x01, 0x01, 0x66, 0x00, 0x00 };
    // store 42 -> mem1[0] (memarg bit 6 + memidx 1); store 7 -> mem0[0];
    // return load(mem1)[0] * 100 + load(mem0)[0]  ->  4207.
    const cbody = [_]u8{
        0x01, 0x21, 0x00,
        0x41, 0x00, 0x41, 0x2a, 0x36, 0x42, 0x01, 0x00, // i32.store (mem 1)
        0x41, 0x00, 0x41, 0x07, 0x36, 0x02, 0x00, // i32.store (mem 0)
        0x41, 0x00, 0x28, 0x42, 0x01, 0x00, // i32.load (mem 1)
        0x41, 0xe4, 0x00, 0x6c, // * 100
        0x41, 0x00, 0x28, 0x02, 0x00, // i32.load (mem 0)
        0x6a, 0x0b,
    };
    const bytes = try assemble(a, &.{
        .{ .id = 1, .body = &tbody },
        .{ .id = 3, .body = &fbody },
        .{ .id = 5, .body = &mbody },
        .{ .id = 7, .body = &xbody },
        .{ .id = 10, .body = &cbody },
    });
    try testing.expectEqual(@as(i32, 4207), try runI32(bytes, "f", &.{}));
}

test "wasm multi-memory: memory.size and memory.grow take a memory index" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tbody = [_]u8{ 0x01, 0x60, 0x00, 0x01, 0x7f };
    const fbody = [_]u8{ 0x01, 0x00 };
    const mbody = [_]u8{ 0x02, 0x00, 0x01, 0x00, 0x01 };
    const xbody = [_]u8{ 0x01, 0x01, 0x66, 0x00, 0x00 };
    // grow(mem1, 2) -> 1 (old);  * 10;  + size(mem1) -> 3  ->  13.
    // mem0 stays 1 page, proving the grow targeted mem1 only.
    const cbody = [_]u8{
        0x01, 0x0f, 0x00,
        0x41, 0x02, 0x40, 0x01, // memory.grow (mem 1)
        0x41, 0x0a, 0x6c, // * 10
        0x3f, 0x01, // memory.size (mem 1)
        0x6a, 0x3f, 0x00, 0x6c, // + size; * size(mem 0) == *1
        0x0b,
    };
    const bytes = try assemble(a, &.{
        .{ .id = 1, .body = &tbody },
        .{ .id = 3, .body = &fbody },
        .{ .id = 5, .body = &mbody },
        .{ .id = 7, .body = &xbody },
        .{ .id = 10, .body = &cbody },
    });
    try testing.expectEqual(@as(i32, 13), try runI32(bytes, "f", &.{}));
}

test "wasm multi-memory: memory.copy moves bytes across distinct memories" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tbody = [_]u8{ 0x01, 0x60, 0x00, 0x01, 0x7f };
    const fbody = [_]u8{ 0x01, 0x00 };
    const mbody = [_]u8{ 0x02, 0x00, 0x01, 0x00, 0x01 };
    const xbody = [_]u8{ 0x01, 0x01, 0x66, 0x00, 0x00 };
    // store 42 -> mem0[0]; memory.copy mem1 <- mem0 (4 bytes); load mem1[0].
    const cbody = [_]u8{
        0x01, 0x19, 0x00,
        0x41, 0x00, 0x41, 0x2a, 0x36, 0x02, 0x00, // i32.store (mem 0)
        0x41, 0x00, 0x41, 0x00, 0x41, 0x04, // dst, src, n
        0xfc, 0x0a, 0x01, 0x00, // memory.copy dst-mem 1, src-mem 0
        0x41, 0x00, 0x28, 0x42, 0x01, 0x00, // i32.load (mem 1)
        0x0b,
    };
    const bytes = try assemble(a, &.{
        .{ .id = 1, .body = &tbody },
        .{ .id = 3, .body = &fbody },
        .{ .id = 5, .body = &mbody },
        .{ .id = 7, .body = &xbody },
        .{ .id = 10, .body = &cbody },
    });
    try testing.expectEqual(@as(i32, 42), try runI32(bytes, "f", &.{}));
}

test "wasm multi-memory: an active data segment targets memory 1 via flag 2" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tbody = [_]u8{ 0x01, 0x60, 0x00, 0x01, 0x7f };
    const fbody = [_]u8{ 0x01, 0x00 };
    const mbody = [_]u8{ 0x02, 0x00, 0x01, 0x00, 0x01 };
    const xbody = [_]u8{ 0x01, 0x01, 0x66, 0x00, 0x00 };
    // load mem1[0] -> 44 (placed there by the flag-2 data segment).
    const cbody = [_]u8{ 0x01, 0x08, 0x00, 0x41, 0x00, 0x28, 0x42, 0x01, 0x00, 0x0b };
    // flag 2, memidx 1, offset i32.const 0, one byte 0x2c (44).
    const dbody = [_]u8{ 0x01, 0x02, 0x01, 0x41, 0x00, 0x0b, 0x01, 0x2c };
    const bytes = try assemble(a, &.{
        .{ .id = 1, .body = &tbody },
        .{ .id = 3, .body = &fbody },
        .{ .id = 5, .body = &mbody },
        .{ .id = 7, .body = &xbody },
        .{ .id = 10, .body = &cbody },
        .{ .id = 11, .body = &dbody },
    });
    try testing.expectEqual(@as(i32, 44), try runI32(bytes, "f", &.{}));
}

test "wasm multi-memory: a memarg memory index past the count is rejected" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tbody = [_]u8{ 0x01, 0x60, 0x00, 0x01, 0x7f };
    const fbody = [_]u8{ 0x01, 0x00 };
    const mbody = [_]u8{ 0x01, 0x00, 0x01 }; // one memory
    const xbody = [_]u8{ 0x01, 0x01, 0x66, 0x00, 0x00 };
    // i32.load with memarg memidx 1 in a one-memory module.
    const cbody = [_]u8{ 0x01, 0x08, 0x00, 0x41, 0x00, 0x28, 0x42, 0x01, 0x00, 0x0b };
    const bytes = try assemble(a, &.{
        .{ .id = 1, .body = &tbody },
        .{ .id = 3, .body = &fbody },
        .{ .id = 5, .body = &mbody },
        .{ .id = 7, .body = &xbody },
        .{ .id = 10, .body = &cbody },
    });
    try testing.expectError(error.UnknownMemory, runI32(bytes, "f", &.{}));
}

// ── function references (typed refs, call_ref, br_on_*) ─────────────

test "wasm function-references: call_ref calls through a typed reference" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tbody = [_]u8{ 0x02, 0x60, 0x01, 0x7f, 0x01, 0x7f, 0x60, 0x00, 0x01, 0x7f };
    const fbody = [_]u8{ 0x02, 0x00, 0x01 };
    const ebody = [_]u8{ 0x01, 0x03, 0x00, 0x01, 0x00 }; // declarative: func 0 referenced
    const xbody = [_]u8{ 0x01, 0x01, 0x66, 0x00, 0x01 };
    // func0 (type 0): doubles its arg. func1 "f": 5; ref.func 0; call_ref 0 -> 10.
    const cbody = [_]u8{
        0x02,
        0x07,
        0x00,
        0x20,
        0x00,
        0x20,
        0x00,
        0x6a,
        0x0b,
        0x08,
        0x00,
        0x41,
        0x05,
        0xd2,
        0x00,
        0x14,
        0x00,
        0x0b,
    };
    const bytes = try assemble(a, &.{
        .{ .id = 1, .body = &tbody },
        .{ .id = 3, .body = &fbody },
        .{ .id = 7, .body = &xbody },
        .{ .id = 9, .body = &ebody },
        .{ .id = 10, .body = &cbody },
    });
    try testing.expectEqual(@as(i32, 10), try runI32(bytes, "f", &.{}));
}

test "wasm function-references: call_ref on a null reference traps" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tbody = [_]u8{ 0x02, 0x60, 0x01, 0x7f, 0x01, 0x7f, 0x60, 0x00, 0x01, 0x7f };
    const fbody = [_]u8{ 0x02, 0x00, 0x01 };
    const xbody = [_]u8{ 0x01, 0x01, 0x66, 0x00, 0x01 };
    // func1 "f": 5; ref.null (type 0); call_ref 0 -> traps.
    const cbody = [_]u8{
        0x02,
        0x07,
        0x00,
        0x20,
        0x00,
        0x20,
        0x00,
        0x6a,
        0x0b,
        0x08,
        0x00,
        0x41,
        0x05,
        0xd0,
        0x00,
        0x14,
        0x00,
        0x0b,
    };
    const bytes = try assemble(a, &.{
        .{ .id = 1, .body = &tbody },
        .{ .id = 3, .body = &fbody },
        .{ .id = 7, .body = &xbody },
        .{ .id = 10, .body = &cbody },
    });
    try testing.expectError(error.NullReference, runI32(bytes, "f", &.{}));
}

test "wasm function-references: br_on_null branches on a null reference" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tbody = [_]u8{ 0x01, 0x60, 0x00, 0x01, 0x7f };
    const fbody = [_]u8{ 0x01, 0x00 };
    const xbody = [_]u8{ 0x01, 0x01, 0x66, 0x00, 0x00 };
    // block (i32) { 7; ref.null func; br_on_null 0; drop; drop; 99 } -> 7.
    const cbody = [_]u8{
        0x01, 0x10, 0x00,
        0x02, 0x7f, 0x41,
        0x07, 0xd0, 0x70,
        0xd5, 0x00, 0x1a,
        0x1a, 0x41, 0xe3,
        0x00, 0x0b, 0x0b,
    };
    const bytes = try assemble(a, &.{
        .{ .id = 1, .body = &tbody },
        .{ .id = 3, .body = &fbody },
        .{ .id = 7, .body = &xbody },
        .{ .id = 10, .body = &cbody },
    });
    try testing.expectEqual(@as(i32, 7), try runI32(bytes, "f", &.{}));
}

test "wasm function-references: br_on_non_null carries the reference to the label" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tbody = [_]u8{ 0x01, 0x60, 0x00, 0x01, 0x7f };
    const fbody = [_]u8{ 0x01, 0x00 };
    const ebody = [_]u8{ 0x01, 0x03, 0x00, 0x01, 0x00 }; // declarative: func 0
    const xbody = [_]u8{ 0x01, 0x01, 0x66, 0x00, 0x00 };
    // block (funcref) { ref.func 0; br_on_non_null 0; ref.null func } ; ref.is_null -> 0.
    const cbody = [_]u8{
        0x01, 0x0c, 0x00,
        0x02, 0x70, 0xd2,
        0x00, 0xd6, 0x00,
        0xd0, 0x70, 0x0b,
        0xd1, 0x0b,
    };
    const bytes = try assemble(a, &.{
        .{ .id = 1, .body = &tbody },
        .{ .id = 3, .body = &fbody },
        .{ .id = 7, .body = &xbody },
        .{ .id = 9, .body = &ebody },
        .{ .id = 10, .body = &cbody },
    });
    try testing.expectEqual(@as(i32, 0), try runI32(bytes, "f", &.{}));
}

test "wasm function-references: ref.as_non_null traps on null" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tbody = [_]u8{ 0x01, 0x60, 0x00, 0x01, 0x7f };
    const fbody = [_]u8{ 0x01, 0x00 };
    const xbody = [_]u8{ 0x01, 0x01, 0x66, 0x00, 0x00 };
    // ref.null func; ref.as_non_null -> traps before the result matters.
    const cbody = [_]u8{ 0x01, 0x08, 0x00, 0xd0, 0x70, 0xd4, 0x1a, 0x41, 0x2a, 0x0b };
    const bytes = try assemble(a, &.{
        .{ .id = 1, .body = &tbody },
        .{ .id = 3, .body = &fbody },
        .{ .id = 7, .body = &xbody },
        .{ .id = 10, .body = &cbody },
    });
    try testing.expectError(error.NullReference, runI32(bytes, "f", &.{}));
}

test "wasm function-references: a non-defaultable local must be set before use" {
    // §3.4.12 — a (ref $t) local has no default; local.get before
    // local.set is invalid.
    try expectFuncInvalid(error.UninitializedLocal, &.{}, &.{}, &.{ 0x01, 0x01, 0x64, 0x00, 0x20, 0x00, 0x1a, 0x0b });
}

test "wasm link: a mutable imported global is shared, not snapshotted" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // provider: (global (export "g") (mut i32) (i32.const 1))
    //           (func (export "bump") (global.set 0 (i32.const 42)))
    const ptbody = [_]u8{ 0x01, 0x60, 0x00, 0x00 };
    const pfbody = [_]u8{ 0x01, 0x00 };
    const pgbody = [_]u8{ 0x01, 0x7f, 0x01, 0x41, 0x01, 0x0b };
    const pxbody = [_]u8{ 0x02, 0x01, 0x67, 0x03, 0x00, 0x04, 0x62, 0x75, 0x6d, 0x70, 0x00, 0x00 };
    const pcbody = [_]u8{ 0x01, 0x06, 0x00, 0x41, 0x2a, 0x24, 0x00, 0x0b };
    const pbytes = try assemble(a, &.{
        .{ .id = 1, .body = &ptbody },
        .{ .id = 3, .body = &pfbody },
        .{ .id = 6, .body = &pgbody },
        .{ .id = 7, .body = &pxbody },
        .{ .id = 10, .body = &pcbody },
    });
    const provider = try instOf(a, pbytes, .{});

    // importer: import "p"."g" (global (mut i32)); (func (export "run") global.get 0)
    const tbody = [_]u8{ 0x01, 0x60, 0x00, 0x01, 0x7f };
    const ibody = [_]u8{ 0x01, 0x01, 0x70, 0x01, 0x67, 0x03, 0x7f, 0x01 }; // mut i32
    const fbody = [_]u8{ 0x01, 0x00 };
    const xbody = [_]u8{ 0x01, 0x03, 0x72, 0x75, 0x6e, 0x00, 0x00 };
    const cbody = [_]u8{ 0x01, 0x04, 0x00, 0x23, 0x00, 0x0b };
    const ibytes = try assemble(a, &.{
        .{ .id = 1, .body = &tbody },
        .{ .id = 2, .body = &ibody },
        .{ .id = 3, .body = &fbody },
        .{ .id = 7, .body = &xbody },
        .{ .id = 10, .body = &cbody },
    });
    const importer = try instOf(a, ibytes, .{ .globals = &.{provider.exportedGlobal("g").?} });

    // §4.5.4 — the provider's later write is visible through the importer.
    try testing.expectEqual(@as(i32, 1), try invokeInst(a, importer, "run", &.{}));
    _ = try interp.invoke(provider, a, funcExport(provider.module, "bump").?, &.{});
    try testing.expectEqual(@as(i32, 42), try invokeInst(a, importer, "run", &.{}));
}

test "wasm locals: a reference-typed local defaults to null" {
    // §4.4.10 — locals are initialized to their type's default value;
    // for a reference type that is ref.null, not the zero bit pattern
    // (REF_NULL is not zero in this engine).
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tbody = [_]u8{ 0x01, 0x60, 0x00, 0x01, 0x7f };
    const fbody = [_]u8{ 0x01, 0x00 };
    const xbody = [_]u8{ 0x01, 0x01, 0x66, 0x00, 0x00 };
    // (local funcref) local.get 0; ref.is_null  ->  1
    const cbody = [_]u8{ 0x01, 0x07, 0x01, 0x01, 0x70, 0x20, 0x00, 0xd1, 0x0b };
    const bytes = try assemble(a, &.{
        .{ .id = 1, .body = &tbody },
        .{ .id = 3, .body = &fbody },
        .{ .id = 7, .body = &xbody },
        .{ .id = 10, .body = &cbody },
    });
    try testing.expectEqual(@as(i32, 1), try runI32(bytes, "f", &.{}));
}
