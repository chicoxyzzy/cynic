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

const CountingExecutionControl = struct {
    polls: u32 = 0,

    fn poll(ctx: *anyopaque) wasm.ExecutionPoll {
        const self: *CountingExecutionControl = @ptrCast(@alignCast(ctx));
        self.polls +%= 1;
        return .proceed;
    }

    fn armed(_: *anyopaque) bool {
        return true;
    }

    fn control(self: *CountingExecutionControl) wasm.ExecutionControl {
        return .{ .ctx = self, .poll_fn = poll, .armed_fn = armed };
    }
};

const DeferredInterruptControl = struct {
    requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    fn poll(ctx: *anyopaque) wasm.ExecutionPoll {
        const self: *DeferredInterruptControl = @ptrCast(@alignCast(ctx));
        return if (self.requested.load(.acquire)) .cooperative_interrupted else .proceed;
    }

    fn armed(ctx: *anyopaque) bool {
        const self: *DeferredInterruptControl = @ptrCast(@alignCast(ctx));
        return self.requested.load(.acquire);
    }

    fn control(self: *DeferredInterruptControl) wasm.ExecutionControl {
        return .{
            .ctx = self,
            .poll_fn = poll,
            .armed_fn = armed,
            .wake_flag = &self.requested,
        };
    }
};

const SpasmInterruptBarrier = struct {
    enabled: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    entered: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    released: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    fn call(ctx: ?*anyopaque, args: []const u128, results: []u128) wasm.TrapError!void {
        _ = args;
        _ = results;
        const self: *SpasmInterruptBarrier = @ptrCast(@alignCast(ctx.?));
        if (!self.enabled.load(.acquire)) return;
        self.entered.store(true, .release);
        while (!self.released.load(.acquire)) std.atomic.spinLoopHint();
    }
};

const SpasmInterruptWorker = struct {
    instance: *interp.Instance,
    allocator: std.mem.Allocator,
    func_index: u32,
    status: std.atomic.Value(u8) = std.atomic.Value(u8).init(0),

    fn run(self: *SpasmInterruptWorker) void {
        const result = interp.invoke(self.instance, self.allocator, self.func_index, &.{}) catch |err| {
            self.status.store(if (err == error.ExecutionInterrupted) 1 else 3, .release);
            return;
        };
        self.allocator.free(result);
        self.status.store(2, .release);
    }
};

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

fn buildSpasmCapacityModule(a: std.mem.Allocator) ![]const u8 {
    var functions: List = .empty;
    var code: List = .empty;
    const function_count = 256;
    try uleb(a, &functions, function_count);
    try functions.appendNTimes(a, 0, function_count);
    try uleb(a, &code, function_count);
    for (0..function_count) |index| {
        var body: List = .empty;
        try body.appendSlice(a, &.{ 0, 0x20, 0 }); // local.get 0
        for (0..128) |_| try body.appendSlice(a, &.{ 0x41, 1, 0x6a }); // add 1
        if (index == 0) try body.appendSlice(a, &.{ 0x10, 1 }); // cold/warm gate to function 1
        try body.append(a, 0x0b);
        try uleb(a, &code, body.items.len);
        try code.appendSlice(a, body.items);
    }
    return assemble(a, &.{
        .{ .id = 1, .body = &.{ 1, 0x60, 1, 0x7f, 1, 0x7f } },
        .{ .id = 3, .body = functions.items },
        .{ .id = 10, .body = code.items },
    });
}

test "wasm spasm: code reserve grows without moving live entries or call gates" {
    if (comptime !@import("spasm.zig").supported) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const bytes = try buildSpasmCapacityModule(a);
    const module = try a.create(wasm.Module);
    module.* = try wasm.decode(a, bytes);
    var instance: interp.Instance = undefined;
    try interp.instantiate(&instance, a, testing.allocator, module, .{});
    defer instance.deinit();
    instance.spasm_enabled = true;
    instance.spasm_diagnostics = true;

    const first = try interp.invoke(&instance, a, 0, &.{7});
    try testing.expectEqual(@as(u128, 263), first[0]);
    const cache = &(instance.spasm_cache orelse return error.TestUnexpectedResult);
    const region = cache.ca.region.ptr;
    const entry = cache.gates[0].entry;
    const gates = cache.gates.ptr;
    for (1..instance.funcs.len) |index| {
        const result = try interp.invoke(&instance, a, @intCast(index), &.{7});
        try testing.expectEqual(@as(u128, 135), result[0]);
    }
    try testing.expectEqual(@as(u32, @intCast(instance.funcs.len)), instance.spasm_compiles);
    try testing.expectEqual(@as(u32, 0), instance.spasm_refusals);
    try testing.expect(instance.spasm_cache.?.ca.top > 64 * 1024);
    try testing.expect(instance.spasm_cache.?.ca.region.len <= 4 * 1024 * 1024);
    try testing.expectEqual(region, instance.spasm_cache.?.ca.region.ptr);
    try testing.expectEqual(entry, instance.spasm_cache.?.gates[0].entry);
    try testing.expectEqual(gates, instance.spasm_cache.?.gates.ptr);
    const helper_calls = instance.spasm_native_calls;
    const warm = try interp.invoke(&instance, a, 0, &.{9});
    try testing.expectEqual(@as(u128, 265), warm[0]);
    try testing.expectEqual(helper_calls, instance.spasm_native_calls);
    try testing.expectEqual(@as(u32, @intCast(instance.funcs.len)), instance.spasm_compiles);
}

test "wasm spasm: code reserve obeys Realm limits and releases its full charge" {
    if (comptime !@import("spasm.zig").supported) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const bytes = try buildSpasmCapacityModule(a);
    const module = try a.create(wasm.Module);
    module.* = try wasm.decode(a, bytes);
    var realm = @import("../realm.zig").Realm.init(testing.allocator);
    defer realm.deinit();
    var instance: interp.Instance = undefined;
    try interp.instantiate(&instance, a, testing.allocator, module, .{});
    defer instance.deinit();
    instance.spasm_enabled = true;
    instance.spasm_diagnostics = true;
    instance.spasm_memory_ledger = realm.wasmCodeMemoryLedger();
    const baseline = realm.heap.bytes_live;
    realm.setMemoryLimit(baseline + 64 * 1024);

    // Refusing the larger mapping must retain interpreter execution and charge nothing.
    const fallback = try interp.invoke(&instance, a, 0, &.{7});
    try testing.expectEqual(@as(u128, 263), fallback[0]);
    try testing.expectEqual(@as(u32, 0), instance.spasm_runs);
    try testing.expect(instance.spasm_cache == null);
    try testing.expectEqual(@as(usize, 0), realm.wasm_code_bytes_live);
    try testing.expectEqual(baseline, realm.heap.bytes_live);
    try testing.expectEqual(@as(u64, 0), realm.wasm_code_reservations_total);

    realm.setMemoryLimit(baseline + 4 * 1024 * 1024);
    const native = try interp.invoke(&instance, a, 0, &.{7});
    try testing.expectEqual(@as(u128, 263), native[0]);
    try testing.expect(instance.spasm_runs > 0);
    const mapped = instance.spasm_cache.?.ca.region.len;
    try testing.expect(mapped > 64 * 1024);
    try testing.expectEqual(mapped, realm.wasm_code_bytes_live);
    try testing.expectEqual(baseline + mapped, realm.heap.bytes_live);
    try testing.expectEqual(@as(u64, 1), realm.wasm_code_reservations_total);
    instance.releaseExecutableCode();
    instance.releaseExecutableCode();
    try testing.expectEqual(@as(usize, 0), realm.wasm_code_bytes_live);
    try testing.expectEqual(baseline, realm.heap.bytes_live);
}

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
    // the callee inline, so `spasm_runs` stayed 0. With the direct-call
    // ABI, "main" runs via Spasm and the leaf enters its cached native
    // EntryFn without re-entering `invoke`.
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
    try testing.expectEqual(@as(u32, 1), instance.spasm_native_calls);

    // The first edge compiles `square` through the cold helper. Once its
    // native entry is cached, a second `main` invocation must enter it through
    // the same-instance native link rather than crossing `spasmCall` again.
    const warm_res = try interp.invoke(&instance, testing.allocator, fidx, cells);
    defer testing.allocator.free(warm_res);
    try testing.expectEqual(@as(u32, 25), @as(u32, @truncate(warm_res[0])));
    try testing.expectEqual(@as(u32, 1), instance.spasm_native_calls);

    // The warm gate carries both the armed execution controller and its stable
    // gate record through the backend's private ABI. Both functions poll at entry.
    var control: CountingExecutionControl = .{};
    instance.execution_control = control.control();
    const metered_res = try interp.invoke(&instance, testing.allocator, fidx, cells);
    defer testing.allocator.free(metered_res);
    try testing.expectEqual(@as(u32, 25), @as(u32, @truncate(metered_res[0])));
    try testing.expectEqual(@as(u32, 2), control.polls);
    instance.execution_control = null;

    // Production keeps the counters off unless a host asks for diagnostics.
    // The compiled main and its native-linked leaf call still run normally;
    // only their observational telemetry stays unchanged.
    const runs_before = instance.spasm_runs;
    const native_calls_before = instance.spasm_native_calls;
    instance.spasm_diagnostics = false;
    const quiet_res = try interp.invoke(&instance, testing.allocator, fidx, cells);
    defer testing.allocator.free(quiet_res);
    try testing.expectEqual(@as(u32, 25), @as(u32, @truncate(quiet_res[0])));
    try testing.expectEqual(runs_before, instance.spasm_runs);
    try testing.expectEqual(native_calls_before, instance.spasm_native_calls);
}

// Both backends have a seven-operand native stack. Force a structural refusal
// independently of which SIMD opcodes have gained lowering support.
const simd_fallback_stack_pressure = blk: {
    var bytes: [24]u8 = @splat(0x1a);
    for (0..8) |index| {
        bytes[index * 2] = 0x41;
        bytes[index * 2 + 1] = 0;
    }
    break :blk bytes;
};

test "wasm spasm: SIMD cold gate preserves interpreter fallback for a refused callee" {
    const spasm = @import("spasm.zig");
    if (comptime !spasm.supported) return error.SkipZigTest;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // The caller is emittable; the callee exceeds the native operand limit.
    // Its cold gate must resolve through Sarcasm without publishing a bogus native entry or
    // changing the scalar result.
    const tbody = [_]u8{ 0x01, 0x60, 0x01, 0x7f, 0x01, 0x7f };
    const fbody = [_]u8{ 0x02, 0x00, 0x00 };
    const xbody = [_]u8{ 0x01, 0x04, 'm', 'a', 'i', 'n', 0x00, 0x00 };
    const cbody = [_]u8{
        0x02,
        0x06,
        0x00,
        0x20,
        0x00,
        0x10,
        0x01,
        0x0b,
        0x31,
        0x00,
        0x20,
        0x00,
        0xfd,
        0x0c,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0xfd,
        0x62,
        0x1a,
    } ++ simd_fallback_stack_pressure ++ [_]u8{0x0b};
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
    instance.spasm_enabled = true;

    const fidx = funcExport(mp, "main") orelse return error.NoSuchExport;
    const cells = try a.alloc(u128, 1);
    cells[0] = 21;

    var invocation: usize = 0;
    while (invocation < 2) : (invocation += 1) {
        const result = try interp.invoke(&instance, testing.allocator, fidx, cells);
        defer testing.allocator.free(result);
        try testing.expectEqual(@as(u32, 21), @as(u32, @truncate(result[0])));
    }
    try testing.expectEqual(@as(u32, 2), instance.spasm_runs);
    try testing.expectEqual(@as(u32, 1), instance.spasm_compiles);
    try testing.expectEqual(@as(u32, 0), instance.spasm_native_calls);
    try testing.expectEqual(@as(u32, 1), instance.spasm_refusals);
    try testing.expectEqual(spasm.RefusalStage.limits, instance.spasm_last_refusal_stage);
}

test "wasm spasm: x86 unreachable raises a catchable trap without fallback" {
    const spasm = @import("spasm.zig");
    if (comptime !spasm.supported or spasm.full_coverage_supported) return error.SkipZigTest;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const bytes = try buildFunc(a, &.{}, &.{}, &.{ 0x00, 0x00, 0x0b }, "trap");
    const instance = try instOf(a, bytes, .{});
    defer instance.deinit();
    instance.spasm_enabled = true;
    instance.spasm_diagnostics = true;

    const fidx = funcExport(instance.module, "trap") orelse return error.NoSuchExport;
    try testing.expectError(error.Unreachable, interp.invoke(instance, testing.allocator, fidx, &.{}));
    try testing.expectEqual(@as(u32, 1), instance.spasm_compiles);
    try testing.expectEqual(@as(u32, 0), instance.spasm_refusals);
}

test "wasm spasm: warm mutually recursive calls use same-instance native links" {
    // §4.4.1 / §5.4.1 — `even(n)` and `odd(n)` call one another. Unlike a
    // self-recursive BL, each edge needs a stable target entry that survives
    // the lazy compilation order. The first invocation may visit the cold
    // helper while it compiles `odd`; after that, no recursive edge may do so.
    if (comptime !@import("spasm.zig").supported) return error.SkipZigTest;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // type 0: (i32)->(i32); two defined funcs, both type 0; export even.
    const tbody = [_]u8{ 0x01, 0x60, 0x01, 0x7f, 0x01, 0x7f };
    const fbody = [_]u8{ 0x02, 0x00, 0x00 };
    const xbody = [_]u8{ 0x01, 0x04, 'e', 'v', 'e', 'n', 0x00, 0x00 };
    // even(n): n == 0 ? 1 : odd(n - 1)
    // odd(n):  n == 0 ? 0 : even(n - 1)
    const cbody = [_]u8{
        0x02,
        0x12,
        0x00,
        0x20,
        0x00,
        0x45,
        0x04,
        0x7f,
        0x41,
        0x01,
        0x05,
        0x20,
        0x00,
        0x41,
        0x01,
        0x6b,
        0x10,
        0x01,
        0x0b,
        0x0b,
        0x12,
        0x00,
        0x20,
        0x00,
        0x45,
        0x04,
        0x7f,
        0x41,
        0x00,
        0x05,
        0x20,
        0x00,
        0x41,
        0x01,
        0x6b,
        0x10,
        0x00,
        0x0b,
        0x0b,
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
    instance.spasm_enabled = true;

    const fidx = funcExport(mp, "even") orelse return error.NoSuchExport;
    const cells = try a.alloc(u128, 1);
    cells[0] = @as(u128, 8);

    const cold = try interp.invoke(&instance, testing.allocator, fidx, cells);
    defer testing.allocator.free(cold);
    try testing.expectEqual(@as(u32, 1), @as(u32, @truncate(cold[0])));
    const calls_after_cold = instance.spasm_native_calls;
    try testing.expect(calls_after_cold > 0);

    const warm = try interp.invoke(&instance, testing.allocator, fidx, cells);
    defer testing.allocator.free(warm);
    try testing.expectEqual(@as(u32, 1), @as(u32, @truncate(warm[0])));
    try testing.expectEqual(calls_after_cold, instance.spasm_native_calls);

    // The gate's hot tail path has no C helper depth cap. Its projected-SP
    // guard must still make pathological mutual recursion catchable rather
    // than exhausting the host stack.
    cells[0] = @as(u128, 1_000_000);
    try testing.expectError(error.CallStackExhausted, interp.invoke(&instance, testing.allocator, fidx, cells));
}

test "wasm spasm: a warm native link reinitializes declared callee locals" {
    // §4.6.5 — a direct target owns one i32 local. It returns that local's
    // initial value, then writes 42 into it. The cold helper initializes the
    // first frame; the second call reuses the native stack area and proves the
    // hot gate emits the same zero-initialization before entering the target.
    if (comptime !@import("spasm.zig").supported) return error.SkipZigTest;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // type 0: (i32)->(i32); func 0 main calls func 1 target; export main.
    const tbody = [_]u8{ 0x01, 0x60, 0x01, 0x7f, 0x01, 0x7f };
    const fbody = [_]u8{ 0x02, 0x00, 0x00 };
    const xbody = [_]u8{ 0x01, 0x04, 'm', 'a', 'i', 'n', 0x00, 0x00 };
    // main: local.get 0; call 1
    // target: local.get 1; i32.const 42; local.set 1
    const cbody = [_]u8{
        0x02,
        0x06,
        0x00,
        0x20,
        0x00,
        0x10,
        0x01,
        0x0b,
        0x0a,
        0x01,
        0x01,
        0x7f,
        0x20,
        0x01,
        0x41,
        0x2a,
        0x21,
        0x01,
        0x0b,
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
    instance.spasm_enabled = true;

    const fidx = funcExport(mp, "main") orelse return error.NoSuchExport;
    const cells = try a.alloc(u128, 1);
    cells[0] = @as(u128, 99);

    const cold = try interp.invoke(&instance, testing.allocator, fidx, cells);
    defer testing.allocator.free(cold);
    try testing.expectEqual(@as(u32, 0), @as(u32, @truncate(cold[0])));
    const calls_after_cold = instance.spasm_native_calls;
    try testing.expectEqual(@as(u32, 1), calls_after_cold);

    const warm = try interp.invoke(&instance, testing.allocator, fidx, cells);
    defer testing.allocator.free(warm);
    try testing.expectEqual(@as(u32, 0), @as(u32, @truncate(warm[0])));
    try testing.expectEqual(calls_after_cold, instance.spasm_native_calls);
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
        0x41, 0x07,
        0x20, 0x00,
        0x04, 0x7f,
        0x10, 0x01,
        0x41, 0x01,
        0x05, 0x10,
        0x01, 0x41,
        0x00, 0x0b,
        0x6a, 0x0b,
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
    instance.spasm_diagnostics = true;

    const fidx = funcExport(mp, "main") orelse return error.NoSuchExport;
    const cells = try a.alloc(u128, 1);
    cells[0] = @as(u128, 5);
    const res = try interp.invoke(&instance, testing.allocator, fidx, cells);
    defer testing.allocator.free(res);

    // table[0] == add10, add10(5) == 15, the same the interpreter gives...
    try testing.expectEqual(@as(u32, 15), @as(u32, @truncate(res[0])));
    // ...and "main" (a `call_indirect`) ran Spasm-compiled, not degraded.
    try testing.expect(instance.spasm_runs >= 1);
    try testing.expectEqual(@as(u32, 0), instance.spasm_refusals);
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
        0x0c,
        'i',
        's',
        '_',
        'n',
        'u',
        'l',
        'l',
        '_',
        'n',
        'u',
        'l',
        'l',
        0x00,
        0x00,
        0x0c,
        'i',
        's',
        '_',
        'n',
        'u',
        'l',
        'l',
        '_',
        'f',
        'u',
        'n',
        'c',
        0x00,
        0x01,
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
    instance.spasm_diagnostics = true;

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
    try testing.expectEqual(@as(u32, 0), instance.spasm_refusals);
}

test "wasm spasm: a self-recursive call traps CallStackExhausted, never crashes" {
    // Host-safety (AGENTS.md never-abort-the-host): a Spasm-compiled body
    // that recurses unboundedly adds native call frames through the helper.
    // Without the stack guard that is a SIGSEGV; the guard must turn
    // pathological depth into a catchable trap instead.
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
        var control: CountingExecutionControl = .{};
        instance.execution_control = control.control();
        const cells = try a.alloc(u128, 1);
        cells[0] = @as(u128, 8);
        const res = try interp.invoke(&instance, testing.allocator, fidx, cells);
        defer testing.allocator.free(res);
        try testing.expectEqual(@as(u32, 0), @as(u32, @truncate(res[0])));
        try testing.expectEqual(@as(u32, 9), control.polls);
        instance.execution_control = null;

        // `rec(8)` has eight nested calls. The self-recursive native link
        // must stay entirely inside the generated code, rather than going
        // through the direct-call helper once per depth.
        try testing.expectEqual(@as(u32, 0), instance.spasm_native_calls);
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
    if (comptime !@import("spasm.zig").full_coverage_supported) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // The Spasm-compiled body's explicit b==0 check (AArch64 sdiv would
    // otherwise return 0) routes through the trap channel to this error.
    try testing.expectError(error.IntegerDivideByZero, runSpasmDiv(arena.allocator(), 1, 0));
}

test "wasm spasm: i32.div_s INT_MIN / -1 raises a catchable integer-overflow trap" {
    if (comptime !@import("spasm.zig").full_coverage_supported) return error.SkipZigTest;
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
        0x41, 0x08,
        0x41, 0x00,
        0x41, 0x04,
        0xfc, 0x08,
        0x00, 0x00,
        0x20, 0x00,
        0x2d, 0x00,
        0x00, 0x0b,
        0x07, 0x00, // dr: 7 bytes, 0 locals
        0xfc, 0x09,
        0x00, 0x41,
        0x2a, 0x0b,
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
    instance.spasm_diagnostics = true;

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
    try testing.expectEqual(@as(u32, 0), instance.spasm_refusals);
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
        0xfc, 0x10,
        0x00, 0x0b,
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
    instance.spasm_diagnostics = true;

    const fidx = funcExport(mp, "sz") orelse return error.NoSuchExport;
    const res = try interp.invoke(&instance, testing.allocator, fidx, &.{});
    defer testing.allocator.free(res);

    // The table was declared with min 3 elements...
    try testing.expectEqual(@as(u32, 3), @as(u32, @truncate(res[0])));
    // ...and "sz" (a `table.size`) ran Spasm-compiled, not degraded.
    try testing.expect(instance.spasm_runs >= 1);
    try testing.expectEqual(@as(u32, 0), instance.spasm_refusals);
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
        0x02,
        'g',
        'o',
        0x00,
        0x02,
        0x05,
        'a',
        'g',
        'a',
        'i',
        'n',
        0x00,
        0x03,
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
    instance.spasm_diagnostics = true;

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
    try testing.expectEqual(@as(u32, 0), instance.spasm_refusals);
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
    instance.spasm_diagnostics = true;

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
    try testing.expectEqual(@as(u32, 0), instance.spasm_refusals);
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
        0x07,
        's',
        'e',
        't',
        'c',
        'a',
        'l',
        'l',
        0x00,
        0x01,
        0x05,
        's',
        'e',
        't',
        'r',
        't',
        0x00,
        0x02,
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
    instance.spasm_diagnostics = true;

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
    try testing.expectEqual(@as(u32, 0), instance.spasm_refusals);
}

test "wasm spasm: reference locals round-trip through local.get/set/tee, declared ref local defaults to null" {
    // §5.4.2 — local.get / local.set / local.tee of a REFERENCE-typed local,
    // and §4.4.10 the default value of a declared (non-parameter) reference
    // local. A reference local lives in its own scalar-local cell (128 bits
    // wide, the over-allocated locals buffer), addressed off x0 exactly like
    // a numeric local; the ops copy the whole 128-bit value to/from the
    // operand's depth-keyed cell. Functions exercised (one funcref table,
    // table[0] = ref.func dummy via an active element segment so table.get
    // yields a genuine RUNTIME funcref; the funcs are exported so ref.func
    // validates per §3.4.1.3):
    //   roundtrip(r): local.set the funcref param into a declared funcref
    //       local, local.get it back, ref.is_null — so roundtrip(null) == 1
    //       and roundtrip(non-null) == 0, the local faithfully carrying the
    //       reference across set/get.
    //   teetest(r):  local.tee the param into the declared local and drop the
    //       left-on-stack copy, then local.get the local and ref.is_null —
    //       proving tee WROTE the local (and left a value), so teetest(non-
    //       null) == 0.
    //   uninit():    a declared funcref local with no initializer, never
    //       written, fed to ref.is_null — its default is ref.null (§4.4.10),
    //       so uninit() == 1. This pins the declared-ref-local zero-vs-null
    //       initialization: a zeroed (not all-ones) cell would wrongly read
    //       as non-null and return 0.
    if (comptime !@import("spasm.zig").supported) return error.SkipZigTest;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // type 0: (funcref)->(i32); type 1: ()->(i32); type 2: (i32)->(i32).
    const tbody = [_]u8{
        0x03,
        0x60, 0x01, 0x70, 0x01, 0x7f, // (funcref)->(i32)
        0x60, 0x00, 0x01, 0x7f, // ()->(i32)
        0x60, 0x01, 0x7f, 0x01, 0x7f, // (i32)->(i32)
    };
    // func section: func0 dummy:t2, func1 roundtrip:t0, func2 teetest:t0,
    // func3 uninit:t1.
    const fbody = [_]u8{ 0x04, 0x02, 0x00, 0x00, 0x01 };
    // table section: 1 table, funcref (0x70), min-only (0x00) min 2.
    const tablebody = [_]u8{ 0x01, 0x70, 0x00, 0x02 };
    // export dummy(0), roundtrip(1), teetest(2), uninit(3) — exporting puts
    // dummy's index in the §3.4.1.3 reference set so ref.func 0 validates.
    const xbody = [_]u8{
        0x04,
        0x05,
        'd',
        'u',
        'm',
        'm',
        'y',
        0x00,
        0x00,
        0x09,
        'r',
        'o',
        'u',
        'n',
        'd',
        't',
        'r',
        'i',
        'p',
        0x00,
        0x01,
        0x07,
        't',
        'e',
        'e',
        't',
        'e',
        's',
        't',
        0x00,
        0x02,
        0x06,
        'u',
        'n',
        'i',
        'n',
        'i',
        't',
        0x00,
        0x03,
    };
    // element section: 1 active segment, table 0, offset i32.const 0, funcs
    // [0 (dummy)] — fills table[0], leaves table[1] null.
    const ebody = [_]u8{ 0x01, 0x00, 0x41, 0x00, 0x0b, 0x01, 0x00 };
    // code section: four bodies.
    //   func0 dummy:     local.get 0; end                            (0 locals)
    //   func1 roundtrip: local.get 0; local.set 1; local.get 1; ref.is_null; end
    //   func2 teetest:   local.get 0; local.tee 1; drop; local.get 1; ref.is_null; end
    //   func3 uninit:    local.get 0; ref.is_null; end               (1 funcref local)
    const cbody = [_]u8{
        0x04, // four code entries
        0x04, 0x00, 0x20, 0x00, 0x0b, // dummy: 4 bytes, 0 locals
        0x0b, 0x01, 0x01, 0x70, 0x20, 0x00, 0x21, 0x01, 0x20, 0x01, 0xd1, 0x0b, // roundtrip: 1 funcref local
        0x0c, 0x01, 0x01, 0x70, 0x20, 0x00, 0x22, 0x01, 0x1a, 0x20, 0x01, 0xd1, 0x0b, // teetest: 1 funcref local
        0x07, 0x01, 0x01, 0x70, 0x20, 0x00, 0xd1, 0x0b, // uninit: 1 funcref local
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

    const REF_NULL: u128 = std.math.maxInt(u128);

    // roundtrip: a null funcref arg round-trips to null (is_null 1); a
    // non-null funcref arg (any value that is not REF_NULL) round-trips to
    // non-null (is_null 0).
    const rt_idx = funcExport(mp, "roundtrip") orelse return error.NoSuchExport;
    {
        const args = try a.alloc(u128, 1);
        args[0] = REF_NULL;
        const r = try interp.invoke(&instance, testing.allocator, rt_idx, args);
        defer testing.allocator.free(r);
        try testing.expectEqual(@as(u32, 1), @as(u32, @truncate(r[0])));
    }
    {
        const args = try a.alloc(u128, 1);
        args[0] = 0; // a non-null reference value
        const r = try interp.invoke(&instance, testing.allocator, rt_idx, args);
        defer testing.allocator.free(r);
        try testing.expectEqual(@as(u32, 0), @as(u32, @truncate(r[0])));
    }

    // teetest: tee writes the local AND leaves a copy on the stack; reading
    // the local back proves the write. A non-null arg yields is_null 0.
    const tee_idx = funcExport(mp, "teetest") orelse return error.NoSuchExport;
    {
        const args = try a.alloc(u128, 1);
        args[0] = 0; // non-null
        const r = try interp.invoke(&instance, testing.allocator, tee_idx, args);
        defer testing.allocator.free(r);
        try testing.expectEqual(@as(u32, 0), @as(u32, @truncate(r[0])));
    }
    {
        const args = try a.alloc(u128, 1);
        args[0] = REF_NULL; // null
        const r = try interp.invoke(&instance, testing.allocator, tee_idx, args);
        defer testing.allocator.free(r);
        try testing.expectEqual(@as(u32, 1), @as(u32, @truncate(r[0])));
    }

    // uninit: a declared funcref local with no initializer defaults to
    // ref.null (§4.4.10), so ref.is_null == 1. A zeroed cell would read as a
    // non-null reference and return 0 — this is the differential-visible
    // initialization bug guard.
    const uninit_idx = funcExport(mp, "uninit") orelse return error.NoSuchExport;
    {
        const r = try interp.invoke(&instance, testing.allocator, uninit_idx, &.{});
        defer testing.allocator.free(r);
        try testing.expectEqual(@as(u32, 1), @as(u32, @truncate(r[0])));
    }

    // All four bodies ran Spasm-compiled (the ref-local ops emitted native
    // code), not degraded to the interpreter.
    try testing.expect(instance.spasm_runs >= 1);
}

test "wasm spasm: typed select picks a reference operand by the condition" {
    // §4.2.4 typed select (`select t`, 0x1c) on REFERENCE operands. The
    // untyped `select` (0x1b) is invalid for references in core wasm
    // (§3.3.4 restricts it to numeric / vector operands), so only the typed
    // form is exercised. Stack is [val1, val2, cond(i32)]; the result is val1
    // when cond != 0 else val2, landing as a reference whose 128-bit value is
    // chosen half-by-half. Both operand shapes Spasm must handle are covered
    // (one funcref table, table[0] = ref.func dummy via an active element
    // segment; the funcs are exported so ref.func validates per §3.4.1.3):
    //   selt(cond):   constant ref operands — `ref.func dummy` (non-null) vs
    //       `ref.null func`. cond != 0 -> is_null 0; cond == 0 -> is_null 1.
    //   seltrt(cond): a RUNTIME `.ref` first operand (read with table.get) vs
    //       `ref.null func`, proving the slot-copy path. cond != 0 ->
    //       is_null(table[0]) 0; cond == 0 -> is_null(null) 1.
    if (comptime !@import("spasm.zig").supported) return error.SkipZigTest;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // type 0: (i32)->(i32) — dummy + both selt funcs take the condition.
    const tbody = [_]u8{ 0x01, 0x60, 0x01, 0x7f, 0x01, 0x7f };
    // func section: func0 dummy:t0, func1 selt:t0, func2 seltrt:t0.
    const fbody = [_]u8{ 0x03, 0x00, 0x00, 0x00 };
    // table section: 1 table, funcref (0x70), min-only (0x00) min 2.
    const tablebody = [_]u8{ 0x01, 0x70, 0x00, 0x02 };
    // export dummy(0) (so ref.func 0 validates), selt(1), seltrt(2).
    const xbody = [_]u8{
        0x03,
        0x05,
        'd',
        'u',
        'm',
        'm',
        'y',
        0x00,
        0x00,
        0x04,
        's',
        'e',
        'l',
        't',
        0x00,
        0x01,
        0x06,
        's',
        'e',
        'l',
        't',
        'r',
        't',
        0x00,
        0x02,
    };
    // element section: 1 active segment, table 0, offset i32.const 0, funcs
    // [0 (dummy)] — fills table[0], leaves table[1] null.
    const ebody = [_]u8{ 0x01, 0x00, 0x41, 0x00, 0x0b, 0x01, 0x00 };
    // code section: three bodies.
    //   func0 dummy:  local.get 0; end
    //   func1 selt:   ref.func 0; ref.null func; local.get 0;
    //                 select (result funcref); ref.is_null; end
    //   func2 seltrt: i32.const 0; table.get 0; ref.null func; local.get 0;
    //                 select (result funcref); ref.is_null; end
    const cbody = [_]u8{
        0x03, // three code entries
        0x04, 0x00, 0x20, 0x00, 0x0b, // dummy: 4 bytes
        0x0c, 0x00, 0xd2, 0x00, 0xd0, 0x70, 0x20, 0x00, 0x1c, 0x01, 0x70, 0xd1, 0x0b, // selt
        0x0e, 0x00, 0x41, 0x00, 0x25, 0x00, 0xd0, 0x70, 0x20, 0x00, 0x1c, 0x01, 0x70, 0xd1, 0x0b, // seltrt
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

    inline for (.{ "selt", "seltrt" }) |name| {
        const idx = funcExport(mp, name) orelse return error.NoSuchExport;
        // cond != 0 -> the non-null reference -> is_null 0.
        {
            const args = try a.alloc(u128, 1);
            args[0] = 1;
            const r = try interp.invoke(&instance, testing.allocator, idx, args);
            defer testing.allocator.free(r);
            try testing.expectEqual(@as(u32, 0), @as(u32, @truncate(r[0])));
        }
        // cond == 0 -> ref.null func (null) -> is_null 1.
        {
            const args = try a.alloc(u128, 1);
            args[0] = 0;
            const r = try interp.invoke(&instance, testing.allocator, idx, args);
            defer testing.allocator.free(r);
            try testing.expectEqual(@as(u32, 1), @as(u32, @truncate(r[0])));
        }
    }

    // selt/seltrt ran Spasm-compiled (the typed-select ref path emitted native
    // code), not degraded to the interpreter.
    try testing.expect(instance.spasm_runs >= 1);
}

test "wasm spasm: SIMD locals select branches and returns preserve full vectors" {
    if (comptime !@import("spasm.zig").supported) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const bodies = [_][]const u8{
        // Untyped and typed select, followed by local.tee and explicit return.
        &.{ 1, 1, 0x7b, 0x20, 0, 0x21, 3, 0x20, 3, 0x20, 1, 0x20, 2, 0x1b, 0x22, 3, 0x0f, 0x0b },
        &.{ 0, 0x20, 0, 0x20, 1, 0x20, 2, 0x1c, 1, 0x7b, 0x0b },
        &.{ 0, 0x02, 0x7b, 0x41, 42, 0x20, 0, 0x20, 2, 0x0d, 0, 0x1a, 0x1a, 0x20, 1, 0x0b, 0x0b },
        &.{ 0, 0x20, 2, 0x04, 0x7b, 0x20, 0, 0x0f, 0x05, 0x20, 1, 0x0b, 0x0b },
        &.{ 0, 0x02, 0x7b, 0x41, 42, 0x20, 0, 0x20, 2, 0x0e, 1, 0, 0, 0x0b, 0x0b },
        &.{ 0, 0x03, 0x7b, 0x20, 0, 0x0b, 0x0b },
    };
    const left: u128 = 0x1234_5678_9abc_def0_ffff_ffff_ffff_ffff;
    const right: u128 = 0xfedc_ba98_7654_3210_0123_4567_89ab_cdef;
    for (bodies, 0..) |body, index| {
        const bytes = try buildFunc(a, &.{ 0x7b, 0x7b, 0x7f }, &.{0x7b}, body, "vector");
        const module = try wasm.decode(a, bytes);
        var instance: interp.Instance = undefined;
        try interp.instantiate(&instance, a, testing.allocator, &module, .{});
        defer instance.deinit();
        instance.spasm_enabled = true;
        for ([_]u128{ 0, 1 }) |condition| {
            const before = instance.spasm_runs;
            const result = try interp.invoke(&instance, testing.allocator, 0, &.{ left, right, condition });
            defer testing.allocator.free(result);
            try testing.expectEqual(if (index >= 4 or condition != 0) left else right, result[0]);
            try testing.expect(instance.spasm_runs > before);
        }
    }
}

test "wasm spasm: SIMD native calls preserve vectors and zero local defaults" {
    if (comptime !@import("spasm.zig").supported) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const bodies = [_][]const u8{
        &.{ 1, 1, 0x7b, 0x20, 0, 0x20, 2, 0x20, 1, 0x1b, 0x0b },
        &.{ 0, 0x20, 0, 0x20, 1, 0x10, 0, 0x0b },
        &.{ 0, 0x20, 0, 0x20, 1, 0x41, 0, 0x11, 0, 0, 0x0b },
        &.{ 0, 0x20, 1, 0x45, 0x04, 0x7b, 0x20, 0, 0x05, 0x20, 0, 0x20, 1, 0x41, 1, 0x6b, 0x10, 3, 0x0b, 0x0b },
    };
    var code: List = .empty;
    try uleb(a, &code, bodies.len);
    for (bodies) |body| {
        try uleb(a, &code, body.len);
        try code.appendSlice(a, body);
    }
    const bytes = try assemble(a, &.{
        .{ .id = 1, .body = &.{ 1, 0x60, 2, 0x7b, 0x7f, 1, 0x7b } },
        .{ .id = 3, .body = &.{ 4, 0, 0, 0, 0 } },
        .{ .id = 4, .body = &.{ 1, 0x70, 0, 1 } },
        .{ .id = 9, .body = &.{ 1, 0, 0x41, 0, 0x0b, 1, 0 } },
        .{ .id = 10, .body = code.items },
    });
    const module = try wasm.decode(a, bytes);
    var instance: interp.Instance = undefined;
    try interp.instantiate(&instance, a, testing.allocator, &module, .{});
    defer instance.deinit();
    instance.spasm_enabled = true;
    const vector: u128 = 0x1234_5678_9abc_def0_ffff_ffff_ffff_ffff;
    for ([_]u32{ 1, 1, 2, 3 }) |index| {
        for ([_]u128{ 0, 3 }) |condition| {
            const result = try interp.invoke(&instance, testing.allocator, index, &.{ vector, condition });
            defer testing.allocator.free(result);
            try testing.expectEqual(if (index == 3 or condition != 0) vector else 0, result[0]);
        }
    }
    try testing.expectEqual(@as(u32, 4), instance.spasm_compiles);
}

test "wasm spasm: SIMD live vector crosses armed loop polls" {
    if (comptime !@import("spasm.zig").supported) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const bytes = try buildFunc(a, &.{ 0x7b, 0x7f }, &.{0x7b}, &.{
        0, 0x20, 0, 0x03, 0x40, 0x20, 1, 0x41, 1, 0x6b, 0x22, 1, 0x0d, 0, 0x0b, 0x0b,
    }, "loop");
    const module = try wasm.decode(a, bytes);
    var instance: interp.Instance = undefined;
    try interp.instantiate(&instance, a, testing.allocator, &module, .{});
    defer instance.deinit();
    instance.spasm_enabled = true;
    var control: CountingExecutionControl = .{};
    instance.execution_control = control.control();
    const vector: u128 = 0x1234_5678_9abc_def0_ffff_ffff_ffff_ffff;
    const result = try interp.invoke(&instance, testing.allocator, 0, &.{ vector, 3 });
    defer testing.allocator.free(result);
    try testing.expectEqual(vector, result[0]);
    try testing.expectEqual(@as(u32, 3), control.polls);
    try testing.expectEqual(@as(u32, 1), instance.spasm_runs);
}

test "wasm spasm: SIMD globals preserve imported and defined vectors" {
    if (comptime !@import("spasm.zig").supported) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const bytes = try assemble(a, &.{
        .{ .id = 1, .body = &.{ 1, 0x60, 1, 0x7b, 1, 0x7b } },
        .{ .id = 2, .body = &.{ 1, 1, 'h', 1, 'g', 3, 0x7b, 1 } },
        .{ .id = 3, .body = &.{ 1, 0 } },
        .{ .id = 6, .body = &([_]u8{ 1, 0x7b, 1, 0xfd, 12 } ++ @as([16]u8, @splat(0)) ++ [_]u8{0x0b}) },
        .{ .id = 10, .body = &.{ 1, 12, 0, 0x20, 0, 0x24, 0, 0x23, 0, 0x24, 1, 0x23, 1, 0x0b } },
    });
    const module = try wasm.decode(a, bytes);
    var imported: interp.Global = .{ .value = 0, .mutable = true };
    var instance: interp.Instance = undefined;
    try interp.instantiate(&instance, a, testing.allocator, &module, .{ .globals = &.{&imported} });
    defer instance.deinit();
    instance.spasm_enabled = true;
    for ([_]u128{ 0x1234_5678_9abc_def0_ffff_ffff_ffff_ffff, 0, std.math.maxInt(u128) }) |vector| {
        const result = try interp.invoke(&instance, testing.allocator, 0, &.{vector});
        defer testing.allocator.free(result);
        try testing.expectEqual(vector, result[0]);
        try testing.expectEqual(vector, imported.value);
        try testing.expectEqual(vector, instance.globals[1].value);
    }
    try testing.expectEqual(@as(u32, 1), instance.spasm_compiles);
}

test "wasm spasm: SIMD lane addition wraps independently and memory is unaligned" {
    if (comptime !@import("spasm.zig").supported) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const body = [_]u8{ 0, 0x20, 2, 0x20, 0, 0x20, 1, 0xfd, 0xae, 1, 0xfd, 11, 0, 0, 0x20, 2, 0xfd, 0, 0, 0, 0x0b };
    const bytes = try assemble(a, &.{
        .{ .id = 1, .body = &.{ 1, 0x60, 3, 0x7b, 0x7b, 0x7f, 1, 0x7b } },
        .{ .id = 3, .body = &.{ 1, 0 } },
        .{ .id = 5, .body = &.{ 1, 0, 1 } },
        .{ .id = 10, .body = &([_]u8{ 1, body.len } ++ body) },
    });
    const module = try wasm.decode(a, bytes);
    var instance: interp.Instance = undefined;
    try interp.instantiate(&instance, a, testing.allocator, &module, .{});
    defer instance.deinit();
    instance.spasm_enabled = true;
    const left: u128 = 0x7fff_ffff_ffff_ffff_0000_0000_ffff_ffff;
    const right: u128 = 0x0000_0001_0000_0002_ffff_ffff_0000_0001;
    const expected: u128 = 0x8000_0000_0000_0001_ffff_ffff_0000_0000;
    for ([_]u128{ 1, 65520 }) |address| {
        const result = try interp.invoke(&instance, testing.allocator, 0, &.{ left, right, address });
        defer testing.allocator.free(result);
        try testing.expectEqual(expected, result[0]);
    }
    try testing.expectError(error.OutOfBoundsMemoryAccess, interp.invoke(&instance, testing.allocator, 0, &.{ left, right, 65521 }));
    try testing.expectEqual(@as(u32, 1), instance.spasm_compiles);
}

const simd_memory_load_ops = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 92, 93 };

const SimdMemoryLoadConfig = struct {
    sub: u8,
    memory64: bool = false,
    offset: u64 = 0,
    dead: bool = false,
    memory_index: ?u32 = null,
};

fn buildSimdMemoryLoadFunc(a: std.mem.Allocator, config: SimdMemoryLoadConfig) ![]const u8 {
    var body: List = .empty;
    // Keep scalar/vector neighbors live, with enough locals to exercise
    // full-Cell offsets beyond the short x86 displacement range.
    try body.appendSlice(a, &.{ 1, 32, 0x7f, 0x20, 0, 0x20, 1 });
    if (config.dead) try body.appendSlice(a, &.{ 0x02, 0x7b, 0x20, 1, 0x0c, 0 });
    try body.appendSlice(a, &.{ 0x20, 2, 0xfd, config.sub, if (config.memory_index != null) 0x40 else 0 });
    if (config.memory_index) |index| try uleb(a, &body, index);
    try uleb(a, &body, @intCast(config.offset));
    if (config.dead) try body.append(a, 0x0b);
    try body.append(a, 0x0b);
    var code: List = .empty;
    try uleb(a, &code, 1);
    try uleb(a, &code, body.items.len);
    try code.appendSlice(a, body.items);
    const memory_type: u8 = if (config.memory64) 4 else 0;
    return assemble(a, &.{
        .{ .id = 1, .body = &.{ 1, 0x60, 3, 0x7e, 0x7b, if (config.memory64) 0x7e else 0x7f, 3, 0x7e, 0x7b, 0x7b } },
        .{ .id = 3, .body = &.{ 1, 0 } },
        .{ .id = 5, .body = if (config.memory_index != null) &.{ 2, memory_type, 1, memory_type, 1 } else &.{ 1, memory_type, 1 } },
        .{ .id = 10, .body = code.items },
    });
}

fn simdMemoryLoadWidth(sub: u8) usize {
    return switch (sub) {
        7...10 => @as(usize, 1) << @as(u3, @intCast(sub - 7)),
        92 => 4,
        else => 8,
    };
}

fn expectedSimdMemoryLoad(sub: u8, source: u64) u128 {
    if (sub == 92) return @as(u32, @truncate(source));
    if (sub == 93) return source;
    if (sub >= 7 and sub <= 10) {
        const bits: u7 = @intCast(simdMemoryLoadWidth(sub) * 8);
        const lane = source & ((@as(u128, 1) << bits) - 1);
        var result: u128 = 0;
        for (0..128 / @as(usize, bits)) |i| result |= lane << @as(u7, @intCast(i * bits));
        return result;
    }
    const bits: u7 = @as(u7, 8) << @as(u3, @intCast((sub - 1) / 2));
    const mask = (@as(u128, 1) << bits) - 1;
    const wide_mask = (@as(u128, 1) << (bits * 2)) - 1;
    var result: u128 = 0;
    for (0..64 / @as(usize, bits)) |lane| {
        var value = (@as(u128, source) >> @as(u7, @intCast(lane * bits))) & mask;
        if (sub % 2 == 1 and value & (@as(u128, 1) << (bits - 1)) != 0) value |= wide_mask ^ mask;
        result |= value << @as(u7, @intCast(lane * bits * 2));
    }
    return result;
}

test "wasm spasm: SIMD memory loads preserve lane bits and live neighbors" {
    if (comptime !@import("spasm.zig").supported) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_]bool{ false, true }) |memory64| {
        for (simd_memory_load_ops) |sub| {
            const module = try wasm.decode(a, try buildSimdMemoryLoadFunc(a, .{ .sub = sub, .memory64 = memory64, .offset = 3 }));
            var instance: interp.Instance = undefined;
            try interp.instantiate(&instance, a, testing.allocator, &module, .{});
            defer instance.deinit();
            instance.spasm_enabled = true;
            for ([_]usize{ 0, 1, 65525 }) |address| {
                for (0..68) |pattern| {
                    const source: u64 = switch (pattern) {
                        64 => 0,
                        65 => std.math.maxInt(u64),
                        66 => 0x807fff00_80007fff,
                        67 => 0x7fffffff_80000000,
                        else => @as(u64, 1) << @as(u6, @intCast(pattern)),
                    };
                    const memory = instance.memories[0].data;
                    @memset(memory, 0x5a);
                    std.mem.writeInt(u64, memory[address + 3 ..][0..8], source, .little);
                    const before = instance.spasm_runs;
                    const result = try interp.invoke(&instance, testing.allocator, 0, &.{ 37, simd_live_vector, address });
                    defer testing.allocator.free(result);
                    try testing.expectEqualSlices(u128, &.{ 37, simd_live_vector, expectedSimdMemoryLoad(sub, source) }, result);
                    try testing.expectEqual(before + 1, instance.spasm_runs);
                    try testing.expectEqual(source, std.mem.readInt(u64, memory[address + 3 ..][0..8], .little));
                    try testing.expect(std.mem.allEqual(u8, memory[0 .. address + 3], 0x5a));
                    try testing.expect(std.mem.allEqual(u8, memory[address + 11 ..], 0x5a));
                }
            }
            try testing.expectEqual(@as(u32, 1), instance.spasm_compiles);
        }
    }
}

test "wasm spasm: SIMD memory loads check exact widths without overflow" {
    if (comptime !@import("spasm.zig").supported) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_]bool{ false, true }) |memory64| {
        for (simd_memory_load_ops) |sub| {
            const limit = 65536 - simdMemoryLoadWidth(sub);
            for ([_]u64{ 0, 8, 0xffff_ffff, 0x1_0000_0000, std.math.maxInt(u64) }) |offset| {
                if (!memory64 and offset > std.math.maxInt(u32)) continue;
                const module = try wasm.decode(a, try buildSimdMemoryLoadFunc(a, .{ .sub = sub, .memory64 = memory64, .offset = offset }));
                var instance: interp.Instance = undefined;
                try interp.instantiate(&instance, a, testing.allocator, &module, .{});
                defer instance.deinit();
                instance.spasm_enabled = true;
                @memset(instance.memories[0].data, 0x5a);
                for ([_]u64{ 0, 1, limit, limit + 1, 0xffff_ffff, 0x1_0000_0000, std.math.maxInt(u64) }) |address| {
                    if (!memory64 and address > std.math.maxInt(u32)) continue;
                    const before = instance.spasm_runs;
                    const result = interp.invoke(&instance, testing.allocator, 0, &.{ 37, simd_live_vector, address });
                    defer if (result) |values| testing.allocator.free(values) else |_| {};
                    if (offset <= limit and address <= limit - offset) {
                        try testing.expectEqualSlices(u128, &.{ 37, simd_live_vector, expectedSimdMemoryLoad(sub, 0x5a5a5a5a5a5a5a5a) }, try result);
                    } else {
                        try testing.expectError(error.OutOfBoundsMemoryAccess, result);
                    }
                    try testing.expectEqual(before + 1, instance.spasm_runs);
                    try testing.expect(std.mem.allEqual(u8, instance.memories[0].data, 0x5a));
                }
                try testing.expectEqual(@as(u32, 1), instance.spasm_compiles);
            }
        }
    }
}

test "wasm spasm: SIMD memory loads skip unreachable memory64 immediates" {
    if (comptime !@import("spasm.zig").supported) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for (simd_memory_load_ops) |sub| {
        for ([_]u64{ 11, std.math.maxInt(u64) }) |offset| {
            const module = try wasm.decode(a, try buildSimdMemoryLoadFunc(a, .{ .sub = sub, .memory64 = true, .offset = offset, .dead = true }));
            var instance: interp.Instance = undefined;
            try interp.instantiate(&instance, a, testing.allocator, &module, .{});
            defer instance.deinit();
            instance.spasm_enabled = true;
            const result = try interp.invoke(&instance, testing.allocator, 0, &.{ 37, simd_live_vector, std.math.maxInt(u64) });
            defer testing.allocator.free(result);
            try testing.expectEqualSlices(u128, &.{ 37, simd_live_vector, simd_live_vector }, result);
            try testing.expectEqual(@as(u32, 1), instance.spasm_runs);
        }
    }
}

test "wasm spasm: SIMD multi-memory loads enter native code" {
    if (comptime !@import("spasm.zig").supported) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for (simd_memory_load_ops) |sub| {
        const module = try wasm.decode(a, try buildSimdMemoryLoadFunc(a, .{ .sub = sub, .memory_index = 1 }));
        var instance: interp.Instance = undefined;
        try interp.instantiate(&instance, a, testing.allocator, &module, .{});
        defer instance.deinit();
        instance.spasm_enabled = true;
        @memset(instance.memories[0].data, 0);
        @memset(instance.memories[1].data, 0x81);
        const result = try interp.invoke(&instance, testing.allocator, 0, &.{ 37, simd_live_vector, 0 });
        defer testing.allocator.free(result);
        try testing.expectEqualSlices(u128, &.{ 37, simd_live_vector, expectedSimdMemoryLoad(sub, 0x8181818181818181) }, result);
        try testing.expectEqual(@as(u32, 1), instance.spasm_runs);
    }
}

const simd_memory_ops = [_]u8{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 84, 85, 86, 87, 88, 89, 90, 91, 92, 93 };

const SimdAuditOp = struct {
    inputs: []const u8,
    output: ?u8 = 0x7b,
    immediate: enum { none, memory, lane, memory_lane, constant, shuffle } = .none,
};

// Independent of the compiler's classifiers: Core's accepted SIMD signatures.
fn simdAuditOp(sub: u32) ?SimdAuditOp {
    return switch (sub) {
        0...10, 92, 93 => .{ .inputs = &.{0x7f}, .immediate = .memory },
        11 => .{ .inputs = &.{ 0x7f, 0x7b }, .output = null, .immediate = .memory },
        12 => .{ .inputs = &.{}, .immediate = .constant },
        13 => .{ .inputs = &.{ 0x7b, 0x7b }, .immediate = .shuffle },
        15...17 => .{ .inputs = &.{0x7f} },
        18 => .{ .inputs = &.{0x7e} },
        19 => .{ .inputs = &.{0x7d} },
        20 => .{ .inputs = &.{0x7c} },
        21, 22, 24, 25, 27 => .{ .inputs = &.{0x7b}, .output = 0x7f, .immediate = .lane },
        29 => .{ .inputs = &.{0x7b}, .output = 0x7e, .immediate = .lane },
        31 => .{ .inputs = &.{0x7b}, .output = 0x7d, .immediate = .lane },
        33 => .{ .inputs = &.{0x7b}, .output = 0x7c, .immediate = .lane },
        23, 26, 28 => .{ .inputs = &.{ 0x7b, 0x7f }, .immediate = .lane },
        30 => .{ .inputs = &.{ 0x7b, 0x7e }, .immediate = .lane },
        32 => .{ .inputs = &.{ 0x7b, 0x7d }, .immediate = .lane },
        34 => .{ .inputs = &.{ 0x7b, 0x7c }, .immediate = .lane },
        82, 261...268, 275 => .{ .inputs = &.{ 0x7b, 0x7b, 0x7b } },
        83, 99, 100, 131, 132, 163, 164, 195, 196 => .{ .inputs = &.{0x7b}, .output = 0x7f },
        84...87 => .{ .inputs = &.{ 0x7f, 0x7b }, .immediate = .memory_lane },
        88...91 => .{ .inputs = &.{ 0x7f, 0x7b }, .output = null, .immediate = .memory_lane },
        107...109, 139...141, 171...173, 203...205 => .{ .inputs = &.{ 0x7b, 0x7f } },
        77,
        94...98,
        103...106,
        116,
        117,
        122,
        124...129,
        135...138,
        148,
        160,
        161,
        167...170,
        192,
        193,
        199...202,
        224,
        225,
        227,
        236,
        237,
        239,
        248...255,
        257...260,
        => .{ .inputs = &.{0x7b} },
        14,
        35...76,
        78...81,
        101,
        102,
        110...115,
        118...121,
        123,
        130,
        133,
        134,
        142...147,
        149...153,
        155...159,
        174,
        177,
        181...186,
        188...191,
        206,
        209,
        213...223,
        228...235,
        240...247,
        256,
        269...274,
        => .{ .inputs = &.{ 0x7b, 0x7b } },
        else => null,
    };
}

fn simdAuditParam(value_type: u8) u8 {
    return switch (value_type) {
        0x7f => 2,
        0x7e => 3,
        0x7d => 4,
        0x7c => 5,
        else => 6,
    };
}

fn buildSimdAuditFunc(a: std.mem.Allocator, sub: u32, op: SimdAuditOp, count: usize, dead: bool) ![]const u8 {
    var body: List = .empty;
    try body.appendSlice(a, &.{ 1, 32, 0x7f, 0x20, 0, 0x20, 1 });
    if (dead) {
        try body.appendSlice(a, &.{ 0x02, op.output orelse 0x40 });
        if (op.output) |value_type| try body.appendSlice(a, &.{ 0x20, simdAuditParam(value_type) });
        try body.appendSlice(a, &.{ 0x0c, 0 });
    }
    const chain = op.output == 0x7b and op.inputs.len > 0 and op.inputs[0] == 0x7b;
    for (0..count) |iteration| {
        if (iteration > 0 and !chain and op.output != null) try body.append(a, 0x1a);
        for (op.inputs, 0..) |value_type, input| {
            if (iteration > 0 and chain and input == 0) continue;
            try body.appendSlice(a, &.{ 0x20, simdAuditParam(value_type) });
        }
        try body.append(a, 0xfd);
        try uleb(a, &body, sub);
        switch (op.immediate) {
            .none => {},
            .memory => try body.appendSlice(a, &.{ 0, 0 }),
            .lane => try body.append(a, 0),
            .memory_lane => try body.appendSlice(a, &.{ 0, 0, 0 }),
            .constant => try body.appendSlice(a, &@as([16]u8, @splat(0))),
            .shuffle => for (0..16) |lane| try body.append(a, @intCast(lane)),
        }
    }
    if (dead) try body.append(a, 0x0b);
    try body.append(a, 0x0b);
    var code: List = .empty;
    try uleb(a, &code, 1);
    try uleb(a, &code, body.items.len);
    try code.appendSlice(a, body.items);
    var types: List = .empty;
    try types.appendSlice(a, &.{ 1, 0x60, 7, 0x7e, 0x7b, 0x7f, 0x7e, 0x7d, 0x7c, 0x7b, if (op.output != null) 3 else 2, 0x7e, 0x7b });
    if (op.output) |value_type| try types.append(a, value_type);
    return assemble(a, &.{
        .{ .id = 1, .body = types.items },
        .{ .id = 3, .body = &.{ 1, 0 } },
        .{ .id = 5, .body = &.{ 1, 0, 1 } },
        .{ .id = 10, .body = code.items },
    });
}

fn expectSimdAuditValue(sub: u32, expected: u128, actual: u128) !void {
    const float_width: u8 = switch (sub) {
        94, 103...106, 224, 225, 227...235, 250, 251, 261, 262, 269, 270 => 32,
        95, 116, 117, 122, 148, 236, 237, 239...247, 254, 255, 263, 264, 271, 272 => 64,
        else => 0,
    };
    if (float_width == 0) return testing.expectEqual(expected, actual);
    inline for (.{ u32, u64 }) |U| {
        if (float_width == @bitSizeOf(U)) {
            const F = if (U == u32) f32 else f64;
            const x: [128 / @bitSizeOf(U)]U = @bitCast(expected);
            const y: [128 / @bitSizeOf(U)]U = @bitCast(actual);
            for (x, y) |left, right| {
                if (std.math.isNan(@as(F, @bitCast(left)))) {
                    try testing.expect(std.math.isNan(@as(F, @bitCast(right))));
                    const quiet: U = if (U == u32) 0x00400000 else 0x0008000000000000;
                    try testing.expect(right & quiet != 0);
                } else try testing.expectEqual(left, right);
            }
        }
    }
}

fn testSimdAuditCase(sub: u32, op: SimdAuditOp, count: usize, dead: bool) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const module = try wasm.decode(a, try buildSimdAuditFunc(a, sub, op, count, dead));
    var instance: interp.Instance = undefined;
    try interp.instantiate(&instance, a, testing.allocator, &module, .{});
    defer instance.deinit();
    const args = [_]u128{ 37, simd_live_vector, 1, 1, 0x3f800000, 0x3ff0000000000000, 0x3ff000003f8000003ff000003f800000 };
    instance.spasm_enabled = false;
    @memset(instance.memories[0].data, 0x81);
    const expected = try interp.invoke(&instance, testing.allocator, 0, &args);
    defer testing.allocator.free(expected);
    const expected_memory = try a.dupe(u8, instance.memories[0].data);
    instance.spasm_enabled = true;
    @memset(instance.memories[0].data, 0x81);
    const actual = try interp.invoke(&instance, testing.allocator, 0, &args);
    defer testing.allocator.free(actual);
    try testing.expectEqual(@import("spasm.zig").RefusalStage.none, instance.spasm_last_refusal_stage);
    try testing.expectEqual(@as(u32, 1), instance.spasm_compiles);
    try testing.expectEqual(@as(u32, 1), instance.spasm_runs);
    try testing.expectEqual(expected.len, actual.len);
    try testing.expectEqualSlices(u128, &.{ 37, simd_live_vector }, actual[0..2]);
    if (op.output != null) try expectSimdAuditValue(sub, expected[2], actual[2]);
    try testing.expectEqualSlices(u8, expected_memory, instance.memories[0].data);
}

fn testSimdAudit(count: usize, dead: bool) !void {
    if (comptime !@import("spasm.zig").supported) return error.SkipZigTest;
    var covered: usize = 0;
    var failed: usize = 0;
    for (0..276) |opcode| {
        const sub: u32 = @intCast(opcode);
        const op = simdAuditOp(sub) orelse continue;
        testSimdAuditCase(sub, op, count, dead) catch |err| {
            std.debug.print("SIMD audit sub={d}, count={d}, dead={}: {s}\n", .{ sub, count, dead, @errorName(err) });
            failed += 1;
        };
        covered += 1;
    }
    try testing.expectEqual(@as(usize, 256), covered);
    try testing.expectEqual(@as(usize, 0), failed);
}

test "wasm spasm: SIMD opcode audit requires native entry for all 256 accepted operations" {
    try testSimdAudit(1, false);
}

test "wasm spasm: SIMD opcode audit skips all accepted dead immediates" {
    try testSimdAudit(1, true);
}

test "wasm spasm: SIMD opcode audit checks dense reservations without unary padding" {
    try testSimdAudit(128, false);
    try testSimdAudit(1024, false);
}

const ScalarMultiMemoryConfig = struct {
    memories: []const bool,
    imports: u32 = 0,
    params: []const u8 = &.{},
    results: []const u8 = &.{},
    ops: []const u8,
    alias: bool = false,
};

fn buildScalarMultiMemoryFunc(a: std.mem.Allocator, config: ScalarMultiMemoryConfig) ![]const u8 {
    var types: List = .empty;
    try types.appendSlice(a, &.{ 1, 0x60 });
    try uleb(a, &types, config.params.len);
    try types.appendSlice(a, config.params);
    try uleb(a, &types, config.results.len);
    try types.appendSlice(a, config.results);
    var imports: List = .empty;
    var memories: List = .empty;
    try uleb(a, &imports, config.imports);
    try uleb(a, &memories, config.memories.len - config.imports);
    for (config.memories, 0..) |memory64, index| {
        const section_body = if (index < config.imports) &imports else &memories;
        if (index < config.imports) try section_body.appendSlice(a, &.{ 1, 'm', 1, 'm', 2 });
        try section_body.appendSlice(a, &.{ if (memory64) 5 else 1, 1, 3 });
    }
    var code: List = .empty;
    try code.append(a, 1);
    try uleb(a, &code, config.ops.len + 4);
    try code.appendSlice(a, &.{ 1, 32, 0x7f }); // nonzero Cell offsets
    try code.appendSlice(a, config.ops);
    try code.append(a, 0x0b);
    return assemble(a, &.{
        .{ .id = 1, .body = types.items },
        .{ .id = 2, .body = imports.items },
        .{ .id = 3, .body = &.{ 1, 0 } },
        .{ .id = 5, .body = memories.items },
        .{ .id = 12, .body = &.{1} },
        .{ .id = 10, .body = code.items },
        .{ .id = 11, .body = &.{ 1, 1, 8, 1, 2, 3, 4, 5, 6, 7, 8 } },
    });
}

fn checkScalarMultiMemory(config: ScalarMultiMemoryConfig, args: []const u128, expected: ?[]const u128, trap: bool) !void {
    if (comptime !@import("spasm.zig").supported) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const module = try wasm.decode(a, try buildScalarMultiMemoryFunc(a, config));
    var provider_config = config;
    provider_config.imports = 0;
    const provider_module = try wasm.decode(a, try buildScalarMultiMemoryFunc(a, provider_config));
    var reference_result: []const u128 = &.{};
    var reference_memories: std.ArrayListUnmanaged([]const u8) = .empty;
    for ([_]bool{ false, true }) |native| {
        var provider: interp.Instance = undefined;
        try interp.instantiate(&provider, a, testing.allocator, &provider_module, .{});
        defer provider.deinit();
        const imported = try a.dupe(*interp.Memory, provider.memories[0..config.imports]);
        if (config.alias) imported[1] = imported[0];
        var instance: interp.Instance = undefined;
        try interp.instantiate(&instance, a, testing.allocator, &module, .{ .memories = imported, .share_memory = true });
        defer instance.deinit();
        for (instance.memories) |memory| {
            for (memory.data, 0..) |*byte, index| byte.* = @truncate(index);
        }
        instance.spasm_enabled = native;
        const outcome = interp.invoke(&instance, testing.allocator, 0, args);
        defer if (outcome) |values| testing.allocator.free(values) else |_| {};
        if (trap) {
            try testing.expectError(error.OutOfBoundsMemoryAccess, outcome);
        } else {
            const result = try outcome;
            if (expected) |values| try testing.expectEqualSlices(u128, values, result);
            if (native) try testing.expectEqualSlices(u128, reference_result, result) else reference_result = try a.dupe(u128, result);
        }
        if (native) try testing.expectEqual(@as(u32, 1), instance.spasm_runs);
        for (instance.memories, 0..) |memory, index| {
            if (native) try testing.expectEqualSlices(u8, reference_memories.items[index], memory.data) else try reference_memories.append(a, try a.dupe(u8, memory.data));
            if (trap) for (memory.data, 0..) |byte, offset| {
                try testing.expectEqual(@as(u8, @truncate(offset)), byte);
            };
        }
    }
}

test "wasm spasm: scalar multi-memory loads and stores use selected widths and exact bounds" {
    const value_types = [_]u8{ 0x7f, 0x7e, 0x7d, 0x7c, 0x7f, 0x7f, 0x7f, 0x7f, 0x7e, 0x7e, 0x7e, 0x7e, 0x7e, 0x7e, 0x7f, 0x7e, 0x7d, 0x7c, 0x7f, 0x7f, 0x7e, 0x7e, 0x7e };
    const widths = [_]u8{ 4, 8, 4, 8, 1, 1, 2, 2, 1, 1, 2, 2, 4, 4, 4, 8, 4, 8, 1, 2, 1, 2, 4 };
    for (value_types, widths, 0..) |value_type, width, op_index| {
        for ([_]bool{ false, true }) |memory64| {
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            const a = arena.allocator();
            const store = op_index >= 14;
            var ops: List = .empty;
            try ops.appendSlice(a, &.{ 0x20, 0, 0x20, 1, 0x20, 2 });
            if (store) try ops.appendSlice(a, &.{ 0x20, 3 });
            try ops.appendSlice(a, &.{ @as(u8, @intCast(0x28 + op_index)), 0x40, 1, 3 });
            if (store) try ops.appendSlice(a, &.{ 0x20, 3 });
            try ops.appendSlice(a, &.{ if (memory64) 0x41 else 0x42, 0, 0x28, 0, 0 });
            const config: ScalarMultiMemoryConfig = .{
                .memories = &.{ !memory64, memory64 },
                .imports = 2,
                .params = &.{ 0x7e, 0x7b, if (memory64) 0x7e else 0x7f, value_type },
                .results = &.{ 0x7e, 0x7b, value_type, 0x7f },
                .ops = ops.items,
            };
            for ([_]u64{ 1, 65536 - @as(u64, width) - 3, 65536 - @as(u64, width) - 2, if (memory64) std.math.maxInt(u64) else std.math.maxInt(u32) }) |address| {
                const value: u128 = if (value_type == 0x7e or value_type == 0x7c) 0x89abcdef01234567 else 0xdeadbeef;
                try checkScalarMultiMemory(config, &.{ 37, simd_live_vector, address, value }, null, address > 65536 - @as(u64, width) - 3);
            }
        }
    }
}

test "wasm spasm: scalar multi-memory decodes long indices and offsets in dense bodies" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var memories: [129]bool = @splat(false);
    memories[128] = true;
    var ops: List = .empty;
    for (0..1024) |_| try ops.appendSlice(a, &.{ 0x42, 0, 0x29, 0x40, 0x80, 1, 0, 0x1a });
    try checkScalarMultiMemory(.{ .memories = &memories, .ops = ops.items }, &.{}, &.{}, false);
    ops.clearRetainingCapacity();
    try ops.appendSlice(a, &.{ 0x20, 0, 0x29, 0x40, 0x80, 1 });
    try uleb(a, &ops, std.math.maxInt(u64));
    try ops.append(a, 0x1a);
    try checkScalarMultiMemory(.{ .memories = &memories, .params = &.{0x7e}, .ops = ops.items }, &.{1}, null, true);
}

test "wasm spasm: scalar multi-memory grow preserves memory zero including imported aliases" {
    for ([_]bool{ false, true }) |memory64| {
        for ([_]bool{ false, true }) |alias| {
            const ty: u8 = if (memory64) 0x7e else 0x7f;
            const zero: u8 = if (memory64) 0x42 else 0x41;
            const body = [_]u8{ 0x20, 0, 0x3f, 1, zero, 1, 0x40, 1, 0x3f, 1, 0x3f, 0, zero, 0, 0x28, 0, 0, zero, 0x7f, 0x40, 1 };
            const failure: u128 = if (memory64) std.math.maxInt(u64) else std.math.maxInt(u32);
            try checkScalarMultiMemory(.{ .memories = &.{ memory64, memory64 }, .imports = 2, .alias = alias, .params = &.{0x7e}, .results = &.{ 0x7e, ty, ty, ty, ty, 0x7f, ty }, .ops = &body }, &.{37}, &.{ 37, 1, 1, 2, if (alias) 2 else 1, 0x03020100, failure }, false);
        }
    }
}

test "wasm spasm: scalar multi-memory fill copy init and alias overlap" {
    for ([_]bool{ false, true }) |dst64| {
        for ([_]bool{ false, true }) |src64| {
            const dt: u8 = if (dst64) 0x7e else 0x7f;
            const st: u8 = if (src64) 0x7e else 0x7f;
            const nt: u8 = if (dst64 and src64) 0x7e else 0x7f;
            for ([_]bool{ false, true }) |alias| {
                if (alias and dst64 != src64) continue;
                const config: ScalarMultiMemoryConfig = .{
                    .memories = &.{ src64, dst64 },
                    .imports = 2,
                    .alias = alias,
                    .params = &.{ 0x7e, 0x7b, dt, st, nt },
                    .results = &.{ 0x7e, 0x7b },
                    .ops = &.{ 0x20, 0, 0x20, 1, 0x20, 2, 0x20, 3, 0x20, 4, 0xfc, 10, 1, 0 },
                };
                for ([_][3]u128{ .{ 1, 0, 12000 }, .{ 0, 1, 12000 }, .{ 65536, 65536, 0 }, .{ 65535, 0, 2 }, .{ 0, 65535, 2 }, .{ if (dst64) std.math.maxInt(u64) else std.math.maxInt(u32), 0, 1 }, .{ 0, if (src64) std.math.maxInt(u64) else std.math.maxInt(u32), 1 }, .{ 0, 0, if (dst64 and src64) std.math.maxInt(u64) else std.math.maxInt(u32) } }) |args|
                    try checkScalarMultiMemory(config, &.{ 37, simd_live_vector, args[0], args[1], args[2] }, &.{ 37, simd_live_vector }, args[0] + args[2] > 65536 or args[1] + args[2] > 65536);
            }
        }
        const ty: u8 = if (dst64) 0x7e else 0x7f;
        for ([_]u8{ 8, 11 }) |sub| {
            const ops = [_]u8{ 0x20, 0, 0x20, 1, 0x20, 2, 0x20, 3, 0x20, 4, 0xfc, sub, if (sub == 8) 0 else 1, 1 };
            const config: ScalarMultiMemoryConfig = .{ .memories = &.{ !dst64, dst64 }, .params = &.{ 0x7e, 0x7b, ty, 0x7f, if (sub == 8) 0x7f else ty }, .results = &.{ 0x7e, 0x7b }, .ops = ops[0 .. ops.len - @intFromBool(sub == 11)] };
            try checkScalarMultiMemory(config, &.{ 37, simd_live_vector, 65532, 0, 4 }, &.{ 37, simd_live_vector }, false);
            try checkScalarMultiMemory(config, &.{ 37, simd_live_vector, 65533, 0, 4 }, null, true);
            try checkScalarMultiMemory(config, &.{ 37, simd_live_vector, if (dst64) std.math.maxInt(u64) else std.math.maxInt(u32), 0, 1 }, null, true);
            try checkScalarMultiMemory(config, &.{ 37, simd_live_vector, 65536, if (sub == 8) 8 else 0, 0 }, &.{ 37, simd_live_vector }, false);
            if (sub == 11) try checkScalarMultiMemory(config, &.{ 37, simd_live_vector, 3, 0x1ab, 12000 }, &.{ 37, simd_live_vector }, false);
        }
    }
    // Explicit expected bytes catch an alias bug shared by both execution tiers.
    try checkScalarMultiMemory(.{ .memories = &.{ false, false }, .imports = 2, .alias = true, .results = &.{0x7e}, .ops = &.{ 0x41, 1, 0x41, 0, 0x41, 7, 0xfc, 10, 1, 0, 0x41, 0, 0x29, 0, 0 } }, &.{}, &.{0x0605040302010000}, false);
    try checkScalarMultiMemory(.{ .memories = &.{ false, true, true }, .params = &.{ 0x7e, 0x7e, 0x7e }, .ops = &.{ 0x20, 0, 0x20, 1, 0x20, 2, 0xfc, 10, 2, 1 } }, &.{ 1, 0, 12000 }, &.{}, false);
}

const SimdMultiMemoryConfig = struct {
    sub: u8,
    index: u32 = 1,
    memory64: bool = false,
    offset: u64 = 0,
    imports: u32 = 0,
    dead: bool = false,
    grow: bool = false,
    repetitions: usize = 1,

    fn is64(self: @This(), index: usize) bool {
        return if (index == self.index) self.memory64 else !self.memory64;
    }

    fn store(self: @This()) bool {
        return self.sub == 11 or (self.sub >= 88 and self.sub <= 91);
    }

    fn lane(self: @This()) bool {
        return self.sub >= 84 and self.sub <= 91;
    }

    fn width(self: @This()) usize {
        if (self.sub == 0 or self.sub == 11) return 16;
        if (self.lane()) return @as(usize, 1) << @as(u3, @intCast((self.sub - 84) % 4));
        return simdMemoryLoadWidth(self.sub);
    }
};

fn buildSimdMultiMemoryFunc(a: std.mem.Allocator, config: SimdMultiMemoryConfig) ![]const u8 {
    var body: List = .empty;
    try body.appendSlice(a, &.{ 1, 32, 0x7f, 0x20, 0, 0x20, 1 });
    if (config.grow) try body.appendSlice(a, &.{ 0x10, 1 });
    if (config.dead) try body.appendSlice(a, &.{ 0x02, 0x7b, 0x20, 3, 0x0c, 0 });
    for (0..config.repetitions) |iteration| {
        try body.appendSlice(a, &.{ 0x20, 2 });
        if (config.store() or config.lane()) try body.appendSlice(a, &.{ 0x20, 3 });
        try body.appendSlice(a, &.{ 0xfd, config.sub, 0x40 });
        try uleb(a, &body, config.index);
        try uleb(a, &body, @intCast(config.offset));
        if (config.lane()) try body.append(a, @intCast(16 / config.width() - 1));
        if (config.store()) try body.appendSlice(a, &.{ 0x20, 3 });
        if (iteration + 1 != config.repetitions) try body.append(a, 0x1a);
    }
    if (config.dead) try body.append(a, 0x0b);
    // A memory-zero access after the selected access detects cache corruption.
    try body.appendSlice(a, &.{ if (config.is64(0)) 0x42 else 0x41, 0, 0xfd, 0, 0, 0, 0x0b });
    var code: List = .empty;
    try uleb(a, &code, if (config.grow) 2 else 1);
    try uleb(a, &code, body.items.len);
    try code.appendSlice(a, body.items);
    if (config.grow) {
        var grow: List = .empty;
        try grow.appendSlice(a, &.{ 0, if (config.memory64) 0x42 else 0x41, 1, 0x40 });
        try uleb(a, &grow, config.index);
        try grow.appendSlice(a, &.{ 0x1a, 0x0b });
        try uleb(a, &code, grow.items.len);
        try code.appendSlice(a, grow.items);
    }
    var types: List = .empty;
    try types.appendSlice(a, &.{ if (config.grow) 2 else 1, 0x60, 4, 0x7e, 0x7b, if (config.memory64) 0x7e else 0x7f, 0x7b, 4, 0x7e, 0x7b, 0x7b, 0x7b });
    if (config.grow) try types.appendSlice(a, &.{ 0x60, 0, 0 });
    const count = @max(2, config.index + 1);
    var imports: List = .empty;
    var memories: List = .empty;
    try uleb(a, &imports, config.imports);
    try uleb(a, &memories, count - config.imports);
    for (0..count) |index| {
        const memory_section = if (index < config.imports) &imports else &memories;
        if (index < config.imports) try memory_section.appendSlice(a, &.{ 1, 'm', 1, 'm', 2 });
        try memory_section.appendSlice(a, &.{ if (config.is64(index)) 4 else 0, if (index == 0 or index == config.index) 1 else 0 });
    }
    return assemble(a, &.{
        .{ .id = 1, .body = types.items },
        .{ .id = 2, .body = imports.items },
        .{ .id = 3, .body = if (config.grow) &.{ 2, 0, 1 } else &.{ 1, 0 } },
        .{ .id = 5, .body = memories.items },
        .{ .id = 10, .body = code.items },
    });
}

fn checkSimdMultiMemory(instance: *interp.Instance, config: SimdMultiMemoryConfig, address: u64) !void {
    errdefer std.debug.print("SIMD memory sub={d}, index={d}, memory64={}, offset={d}, address={d}\n", .{ config.sub, config.index, config.memory64, config.offset, address });
    for (instance.memories, 0..) |memory, index| @memset(memory.data, if (index == config.index) 0x81 else 0x35);
    const memory = instance.memories[config.index].data;
    const width = config.width();
    const in_bounds = config.offset <= memory.len - width and address <= memory.len - width - config.offset;
    const before = instance.spasm_runs;
    const outcome = interp.invoke(instance, testing.allocator, 0, &.{ 37, simd_live_vector, address, ~simd_live_vector });
    defer if (outcome) |values| testing.allocator.free(values) else |_| {};
    try testing.expectEqual(before + 1, instance.spasm_runs);
    if (in_bounds) {
        const start: usize = @intCast(address + config.offset);
        var expected: u128 = if (config.store()) ~simd_live_vector else if (config.sub == 0) @bitCast(@as([16]u8, @splat(0x81))) else if (config.lane()) blk: {
            var bytes: [16]u8 = @bitCast(~simd_live_vector);
            @memset(bytes[16 - width ..], 0x81);
            break :blk @bitCast(bytes);
        } else expectedSimdMemoryLoad(config.sub, 0x8181818181818181);
        if (config.dead) expected = ~simd_live_vector;
        const result = try outcome;
        try testing.expectEqualSlices(u128, &.{ 37, simd_live_vector, expected, std.mem.readInt(u128, instance.memories[0].data[0..16], .little) }, result);
        if (config.store() and !config.dead) {
            const input: [16]u8 = @bitCast(~simd_live_vector);
            try testing.expectEqualSlices(u8, input[16 - width ..], memory[start..][0..width]);
            try testing.expect(std.mem.allEqual(u8, memory[0..start], 0x81));
            try testing.expect(std.mem.allEqual(u8, memory[start + width ..], 0x81));
        } else try testing.expect(std.mem.allEqual(u8, memory, 0x81));
    } else {
        try testing.expectError(error.OutOfBoundsMemoryAccess, outcome);
        try testing.expect(std.mem.allEqual(u8, memory, 0x81));
    }
    for (instance.memories, 0..) |other, index| {
        if (index != config.index) try testing.expect(std.mem.allEqual(u8, other.data, 0x35));
    }
}

test "wasm spasm: SIMD multi-memory selects the address width and preserves memory zero" {
    if (comptime !@import("spasm.zig").supported) return error.SkipZigTest;
    for (simd_memory_ops) |sub| {
        for ([_]bool{ false, true }) |memory64| {
            for ([_]u32{ 0, 1, 128 }) |index| {
                var arena = std.heap.ArenaAllocator.init(testing.allocator);
                defer arena.deinit();
                const a = arena.allocator();
                const config: SimdMultiMemoryConfig = .{ .sub = sub, .index = index, .memory64 = memory64, .offset = 3 };
                const module = try wasm.decode(a, try buildSimdMultiMemoryFunc(a, config));
                var instance: interp.Instance = undefined;
                try interp.instantiate(&instance, a, testing.allocator, &module, .{});
                defer instance.deinit();
                instance.spasm_enabled = true;
                try checkSimdMultiMemory(&instance, config, 1);
                try checkSimdMultiMemory(&instance, config, 65536 - config.width() - config.offset);
            }
        }
    }
}

test "wasm spasm: SIMD multi-memory traps before partial stores or address overflow" {
    if (comptime !@import("spasm.zig").supported) return error.SkipZigTest;
    for (simd_memory_ops) |sub| {
        for ([_]bool{ false, true }) |memory64| {
            for ([_]u64{ 0, 8, 0xffffffff, 0x100000000, std.math.maxInt(u64) }) |offset| {
                if (!memory64 and offset > std.math.maxInt(u32)) continue;
                var arena = std.heap.ArenaAllocator.init(testing.allocator);
                defer arena.deinit();
                const a = arena.allocator();
                const config: SimdMultiMemoryConfig = .{ .sub = sub, .memory64 = memory64, .offset = offset };
                const module = try wasm.decode(a, try buildSimdMultiMemoryFunc(a, config));
                var instance: interp.Instance = undefined;
                try interp.instantiate(&instance, a, testing.allocator, &module, .{});
                defer instance.deinit();
                instance.spasm_enabled = true;
                for ([_]u64{ 0, 1, 65536 - config.width(), 65537 - config.width(), 0xffffffff, 0x100000000, std.math.maxInt(u64) }) |address| {
                    if (!memory64 and address > std.math.maxInt(u32)) continue;
                    try checkSimdMultiMemory(&instance, config, address);
                }
            }
        }
    }
}

test "wasm spasm: SIMD multi-memory skips complete unreachable immediates" {
    if (comptime !@import("spasm.zig").supported) return error.SkipZigTest;
    for (simd_memory_ops) |sub| {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const config: SimdMultiMemoryConfig = .{ .sub = sub, .index = 128, .memory64 = true, .offset = std.math.maxInt(u64), .dead = true };
        const module = try wasm.decode(a, try buildSimdMultiMemoryFunc(a, config));
        var instance: interp.Instance = undefined;
        try interp.instantiate(&instance, a, testing.allocator, &module, .{});
        defer instance.deinit();
        instance.spasm_enabled = true;
        const result = try interp.invoke(&instance, testing.allocator, 0, &.{ 37, simd_live_vector, std.math.maxInt(u64), ~simd_live_vector });
        defer testing.allocator.free(result);
        try testing.expectEqualSlices(u128, &.{ 37, simd_live_vector, ~simd_live_vector, 0 }, result);
        try testing.expectEqual(@as(u32, 1), instance.spasm_runs);
    }
}

test "wasm spasm: SIMD multi-memory resolves imported and defined memory indices" {
    if (comptime !@import("spasm.zig").supported) return error.SkipZigTest;
    for (simd_memory_ops) |sub| {
        for ([_]bool{ false, true }) |memory64| {
            for ([_]u32{ 1, 2 }) |imports| {
                var arena = std.heap.ArenaAllocator.init(testing.allocator);
                defer arena.deinit();
                const a = arena.allocator();
                const config: SimdMultiMemoryConfig = .{ .sub = sub, .memory64 = memory64, .imports = imports };
                var provider_config = config;
                provider_config.imports = 0;
                const provider_module = try wasm.decode(a, try buildSimdMultiMemoryFunc(a, provider_config));
                var provider: interp.Instance = undefined;
                try interp.instantiate(&provider, a, testing.allocator, &provider_module, .{});
                defer provider.deinit();
                const module = try wasm.decode(a, try buildSimdMultiMemoryFunc(a, config));
                var instance: interp.Instance = undefined;
                try interp.instantiate(&instance, a, testing.allocator, &module, .{ .memories = provider.memories[0..imports], .share_memory = true });
                defer instance.deinit();
                instance.spasm_enabled = true;
                try checkSimdMultiMemory(&instance, config, 1);
                try testing.expect(instance.memories[0] == provider.memories[0]);
                if (imports == 2) try testing.expect(instance.memories[1] == provider.memories[1]);
            }
        }
    }
}

test "wasm spasm: SIMD multi-memory refreshes the selected view after a callee grows it" {
    if (comptime !@import("spasm.zig").supported) return error.SkipZigTest;
    for ([_]bool{ false, true }) |memory64| {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const config: SimdMultiMemoryConfig = .{ .sub = 0, .memory64 = memory64, .grow = true, .imports = 2 };
        var provider_config = config;
        provider_config.imports = 0;
        provider_config.grow = false;
        const provider_module = try wasm.decode(a, try buildSimdMultiMemoryFunc(a, provider_config));
        var provider: interp.Instance = undefined;
        try interp.instantiate(&provider, a, testing.allocator, &provider_module, .{});
        defer provider.deinit();
        const module = try wasm.decode(a, try buildSimdMultiMemoryFunc(a, config));
        var instance: interp.Instance = undefined;
        try interp.instantiate(&instance, a, testing.allocator, &module, .{ .memories = provider.memories, .share_memory = true });
        defer instance.deinit();
        instance.spasm_enabled = true;
        @memset(instance.memories[0].data, 0x35);
        for ([_]u64{ 65536, 131072 }) |address| {
            const before = instance.spasm_runs;
            const result = try interp.invoke(&instance, testing.allocator, 0, &.{ 37, simd_live_vector, address, ~simd_live_vector });
            defer testing.allocator.free(result);
            try testing.expectEqualSlices(u128, &.{ 37, simd_live_vector, 0, @bitCast(@as([16]u8, @splat(0x35))) }, result);
            // The cold callee enters through the helper; its hot direct link
            // bypasses the top-level entry counter on the second invocation.
            try testing.expectEqual(before + @as(u32, if (address == 65536) 2 else 1), instance.spasm_runs);
            try testing.expectEqual(@as(u32, 2), instance.spasm_compiles);
            try testing.expectEqual(@as(u32, 0), instance.spasm_refusals);
            try testing.expectEqual(address + 65536, instance.memories[1].data.len);
            try testing.expectEqual(address + 65536, provider.memories[1].data.len);
            try testing.expectEqual(@as(usize, 65536), instance.memories[0].data.len);
        }
    }
}

test "wasm spasm: SIMD multi-memory dense bodies fit the code reservation" {
    if (comptime !@import("spasm.zig").supported) return error.SkipZigTest;
    for (simd_memory_ops) |sub| {
        for ([_]bool{ false, true }) |memory64| {
            for ([_]usize{ 128, 1024 }) |repetitions| {
                var arena = std.heap.ArenaAllocator.init(testing.allocator);
                defer arena.deinit();
                const a = arena.allocator();
                const config: SimdMultiMemoryConfig = .{ .sub = sub, .memory64 = memory64, .repetitions = repetitions };
                const module = try wasm.decode(a, try buildSimdMultiMemoryFunc(a, config));
                var instance: interp.Instance = undefined;
                try interp.instantiate(&instance, a, testing.allocator, &module, .{});
                defer instance.deinit();
                instance.spasm_enabled = true;
                try checkSimdMultiMemory(&instance, config, 1);
                try testing.expectEqual(@import("spasm.zig").RefusalStage.none, instance.spasm_last_refusal_stage);
                try testing.expectEqual(@as(u32, 1), instance.spasm_compiles);
            }
        }
    }
}

fn buildSimdLaneFunc(a: std.mem.Allocator, memory64: bool, store: bool, size_log2: u2, lane: u8, offset: u64) ![]const u8 {
    var body: List = .empty;
    try body.appendSlice(a, &.{ 0, 0x20, 0, 0x20, 1, 0xfd, @as(u8, if (store) 88 else 84) + size_log2, 0 });
    try uleb(a, &body, @intCast(offset));
    try body.appendSlice(a, &.{ lane, 0x0b });
    var code: List = .empty;
    try uleb(a, &code, 1);
    try uleb(a, &code, body.items.len);
    try code.appendSlice(a, body.items);
    var types: List = .empty;
    try types.appendSlice(a, &.{ 1, 0x60, 2, if (memory64) 0x7e else 0x7f, 0x7b });
    try types.appendSlice(a, if (store) &.{0} else &.{ 1, 0x7b });
    return assemble(a, &.{
        .{ .id = 1, .body = types.items },
        .{ .id = 3, .body = &.{ 1, 0 } },
        .{ .id = 5, .body = &.{ 1, if (memory64) 4 else 0, 1 } },
        .{ .id = 10, .body = code.items },
    });
}

test "wasm spasm: SIMD lane loads and stores preserve every other byte" {
    if (comptime !@import("spasm.zig").supported) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const vector_bytes = [_]u8{ 0xf0, 1, 0xe2, 3, 0xd4, 5, 0xc6, 7, 0xb8, 9, 0xaa, 11, 0x9c, 13, 0x8e, 15 };
    const memory_bytes = [_]u8{ 0x87, 0x32, 0xa9, 0x54, 0xcb, 0x76, 0xed, 0x98 };
    const vector = std.mem.readInt(u128, &vector_bytes, .little);
    for ([_]bool{ false, true }) |memory64| {
        for ([_]bool{ false, true }) |store| {
            for (0..4) |size_log2| {
                const width = @as(usize, 1) << @as(u6, @intCast(size_log2));
                for (0..16 / width) |lane| {
                    const bytes = try buildSimdLaneFunc(a, memory64, store, @intCast(size_log2), @intCast(lane), 8);
                    const module = try wasm.decode(a, bytes);
                    var instance: interp.Instance = undefined;
                    try interp.instantiate(&instance, a, testing.allocator, &module, .{});
                    defer instance.deinit();
                    instance.spasm_enabled = true;
                    for ([_]usize{ 1, 65536 - width - 8 }) |address| {
                        const memory = instance.memories[0].data;
                        @memset(memory, 0x5a);
                        const start = address + 8;
                        if (!store) @memcpy(memory[start..][0..width], memory_bytes[0..width]);
                        const result = try interp.invoke(&instance, testing.allocator, 0, &.{ address, vector });
                        defer testing.allocator.free(result);
                        if (store) {
                            try testing.expectEqualSlices(u8, vector_bytes[lane * width ..][0..width], memory[start..][0..width]);
                            try testing.expect(std.mem.allEqual(u8, memory[0..start], 0x5a));
                            try testing.expect(std.mem.allEqual(u8, memory[start + width ..], 0x5a));
                        } else {
                            var expected = vector_bytes;
                            @memcpy(expected[lane * width ..][0..width], memory_bytes[0..width]);
                            try testing.expectEqual(std.mem.readInt(u128, &expected, .little), result[0]);
                            try testing.expectEqualSlices(u8, memory_bytes[0..width], memory[start..][0..width]);
                            try testing.expect(std.mem.allEqual(u8, memory[0..start], 0x5a));
                            try testing.expect(std.mem.allEqual(u8, memory[start + width ..], 0x5a));
                        }
                    }
                    try testing.expectEqual(@as(u32, 1), instance.spasm_compiles);
                    try testing.expectEqual(@as(u32, 2), instance.spasm_runs);
                }
            }
        }
    }
}

test "wasm spasm: SIMD lane bounds use the lane width and reject address overflow" {
    if (comptime !@import("spasm.zig").supported) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_]bool{ false, true }) |memory64| {
        for ([_]bool{ false, true }) |store| {
            for (0..4) |size_log2| {
                const width = @as(usize, 1) << @as(u6, @intCast(size_log2));
                const limit = 65536 - width;
                for ([_]u64{ 0, 8, 0xffff_ffff, 0x1_0000_0000, std.math.maxInt(u64) }) |offset| {
                    if (!memory64 and offset > std.math.maxInt(u32)) continue;
                    const bytes = try buildSimdLaneFunc(a, memory64, store, @intCast(size_log2), @intCast(16 / width - 1), offset);
                    const module = try wasm.decode(a, bytes);
                    var instance: interp.Instance = undefined;
                    try interp.instantiate(&instance, a, testing.allocator, &module, .{});
                    defer instance.deinit();
                    instance.spasm_enabled = true;
                    for ([_]u64{ 0, 1, limit, limit + 1, 0xffff_ffff, 0x1_0000_0000, std.math.maxInt(u64) }) |address| {
                        if (!memory64 and address > std.math.maxInt(u32)) continue;
                        @memset(instance.memories[0].data, 0x5a);
                        const result = interp.invoke(&instance, testing.allocator, 0, &.{ address, std.math.maxInt(u128) });
                        defer if (result) |values| testing.allocator.free(values) else |_| {};
                        if (offset <= limit and address <= limit - offset) {
                            _ = try result;
                        } else {
                            try testing.expectError(error.OutOfBoundsMemoryAccess, result);
                            try testing.expect(std.mem.allEqual(u8, instance.memories[0].data, 0x5a));
                        }
                    }
                    try testing.expectEqual(@as(u32, 1), instance.spasm_compiles);
                }
            }
        }
    }
}

test "wasm spasm: SIMD any_true checks all 128 bits and preserves a live scalar" {
    if (comptime !@import("spasm.zig").supported) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const bytes = try buildFunc(a, &.{ 0x7f, 0x7b }, &.{0x7f}, &.{ 0, 0x20, 0, 0x20, 1, 0xfd, 83, 0x6a, 0x0b }, "any");
    const module = try wasm.decode(a, bytes);
    var instance: interp.Instance = undefined;
    try interp.instantiate(&instance, a, testing.allocator, &module, .{});
    defer instance.deinit();
    instance.spasm_enabled = true;
    for (0..130) |index| {
        const vector: u128 = if (index == 128) 0 else if (index == 129) std.math.maxInt(u128) else @as(u128, 1) << @as(u7, @intCast(index));
        const result = try interp.invoke(&instance, testing.allocator, 0, &.{ 37, vector });
        defer testing.allocator.free(result);
        try testing.expectEqual(@as(u128, if (vector == 0) 37 else 38), result[0]);
    }
    try testing.expectEqual(@as(u32, 1), instance.spasm_compiles);
    try testing.expectEqual(@as(u32, 130), instance.spasm_runs);
}

const simd_scalar_cases = [_]struct { splat: u8, extract: u8, replace: u8, width: usize, scalar: u8 }{
    .{ .splat = 15, .extract = 22, .replace = 23, .width = 1, .scalar = 0x7f },
    .{ .splat = 16, .extract = 25, .replace = 26, .width = 2, .scalar = 0x7f },
    .{ .splat = 17, .extract = 27, .replace = 28, .width = 4, .scalar = 0x7f },
    .{ .splat = 18, .extract = 29, .replace = 30, .width = 8, .scalar = 0x7e },
    .{ .splat = 19, .extract = 31, .replace = 32, .width = 4, .scalar = 0x7d },
    .{ .splat = 20, .extract = 33, .replace = 34, .width = 8, .scalar = 0x7c },
};

const simd_scalar_bits = [_]u64{
    0,           1,                     0xffff_ffff_ffff_ffff, 0x0123_4567_89ab_cdef,
    0x8000_0000, 0x8000_0000_0000_0000, 0x7f80_0001,           0x7ff0_0000_0000_0001,
};
const simd_live_vector: u128 = 0x0123_4567_89ab_cdef_fedc_ba98_7654_3210;

const simd_reduction_cases = [_]struct { all_true: u32, bitmask: u32, bits: usize }{
    .{ .all_true = 99, .bitmask = 100, .bits = 8 },
    .{ .all_true = 131, .bitmask = 132, .bits = 16 },
    .{ .all_true = 163, .bitmask = 164, .bits = 32 },
    .{ .all_true = 195, .bitmask = 196, .bits = 64 },
};

fn buildSimdReductionFunc(a: std.mem.Allocator, sub: u32) ![]const u8 {
    var body: List = .empty;
    // Extra locals exercise nonzero vector-home offsets as well as live
    // scalar/vector values below the operand being reduced.
    try body.appendSlice(a, &.{ 1, 32, 0x7f, 0x20, 0, 0x20, 1, 0x20, 2, 0xfd });
    try uleb(a, &body, sub);
    try body.append(a, 0x0b);
    return buildFunc(a, &.{ 0x7e, 0x7b, 0x7b }, &.{ 0x7e, 0x7b, 0x7f }, body.items, "reduce");
}

fn expectSimdReduction(instance: *interp.Instance, input: u128, expected: u128) !void {
    const before = instance.spasm_runs;
    const result = try interp.invoke(instance, testing.allocator, 0, &.{ 37, simd_live_vector, input });
    defer testing.allocator.free(result);
    try testing.expectEqualSlices(u128, &.{ 37, simd_live_vector, expected }, result);
    try testing.expectEqual(before + 1, instance.spasm_runs);
}

test "wasm spasm: SIMD reductions all_true checks every bit and every zero lane" {
    if (comptime !@import("spasm.zig").supported) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for (simd_reduction_cases) |op| {
        const module = try wasm.decode(a, try buildSimdReductionFunc(a, op.all_true));
        var instance: interp.Instance = undefined;
        try interp.instantiate(&instance, a, testing.allocator, &module, .{});
        defer instance.deinit();
        instance.spasm_enabled = true;
        try expectSimdReduction(&instance, 0, 0);
        try expectSimdReduction(&instance, std.math.maxInt(u128), 1);
        const lanes = 128 / op.bits;
        const lane_mask = (@as(u128, 1) << @as(u7, @intCast(op.bits))) - 1;
        for (0..op.bits) |bit| {
            var vector: u128 = 0;
            for (0..lanes) |lane| vector |= @as(u128, 1) << @as(u7, @intCast(lane * op.bits + bit));
            try expectSimdReduction(&instance, vector, 1);
            for (0..lanes) |lane| {
                const mask = lane_mask << @as(u7, @intCast(lane * op.bits));
                try expectSimdReduction(&instance, vector & ~mask, 0);
                try expectSimdReduction(&instance, vector & mask, 0);
            }
        }
        try testing.expectEqual(@as(u32, 1), instance.spasm_compiles);
    }
}

test "wasm spasm: SIMD reductions bitmask exhausts sign combinations with lower bit noise" {
    if (comptime !@import("spasm.zig").supported) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for (simd_reduction_cases) |op| {
        const module = try wasm.decode(a, try buildSimdReductionFunc(a, op.bitmask));
        var instance: interp.Instance = undefined;
        try interp.instantiate(&instance, a, testing.allocator, &module, .{});
        defer instance.deinit();
        instance.spasm_enabled = true;
        const lanes = 128 / op.bits;
        const combinations = @as(usize, 1) << @as(u6, @intCast(lanes));
        var sign_bits: u128 = 0;
        for (0..lanes) |lane| sign_bits |= @as(u128, 1) << @as(u7, @intCast((lane + 1) * op.bits - 1));
        for (0..combinations) |mask| {
            var vector: u128 = 0;
            for (0..lanes) |lane| {
                if ((mask & (@as(usize, 1) << @as(u6, @intCast(lane)))) != 0)
                    vector |= @as(u128, 1) << @as(u7, @intCast((lane + 1) * op.bits - 1));
            }
            try expectSimdReduction(&instance, vector, mask);
            try expectSimdReduction(&instance, vector | ~sign_bits, mask);
        }
        try testing.expectEqual(@as(u32, 1), instance.spasm_compiles);
    }
}

test "wasm spasm: SIMD reductions are skipped after a terminating branch" {
    if (comptime !@import("spasm.zig").supported) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for (simd_reduction_cases) |op| {
        for ([_]u32{ op.all_true, op.bitmask }) |sub| {
            var body: List = .empty;
            try body.appendSlice(a, &.{ 0, 0x02, 0x7f, 0x41, 37, 0x0c, 0, 0x20, 0, 0xfd });
            try uleb(a, &body, sub);
            try body.appendSlice(a, &.{ 0x0b, 0x0b });
            const module = try wasm.decode(a, try buildFunc(a, &.{0x7b}, &.{0x7f}, body.items, "dead"));
            var instance: interp.Instance = undefined;
            try interp.instantiate(&instance, a, testing.allocator, &module, .{});
            defer instance.deinit();
            instance.spasm_enabled = true;
            const result = try interp.invoke(&instance, testing.allocator, 0, &.{simd_live_vector});
            defer testing.allocator.free(result);
            try testing.expectEqualSlices(u128, &.{37}, result);
            try testing.expectEqual(@as(u32, 1), instance.spasm_compiles);
            try testing.expectEqual(@as(u32, 1), instance.spasm_runs);
        }
    }
}

fn expectFloatMinMaxLane(comptime U: type, left: U, right: U, actual: U, maximum: bool) !void {
    const sign: U = @as(U, 1) << (@bitSizeOf(U) - 1);
    const exponent: U = if (U == u32) 0x7f80_0000 else 0x7ff0_0000_0000_0000;
    const fraction = (sign - 1) & ~exponent;
    const quiet = (fraction + 1) / 2;
    const left_nan = (left & ~sign) > exponent;
    const right_nan = (right & ~sign) > exponent;
    if (left_nan or right_nan) {
        // Core nans: canonical inputs require a canonical output; otherwise
        // any arithmetic NaN is valid, but its quiet bit must be set.
        try testing.expectEqual(exponent | quiet, actual & (exponent | quiet));
        if ((!left_nan or (left & fraction) == quiet) and (!right_nan or (right & fraction) == quiet)) {
            try testing.expectEqual(exponent | quiet, actual & ~sign);
        }
        return;
    }
    if ((left & ~sign) == 0 and (right & ~sign) == 0) {
        try testing.expectEqual(if (maximum) left & right else left | right, actual);
        return;
    }
    // IEEE bit ordering after sign normalization, independent of host FP
    // comparisons (especially flush-to-zero behavior for subnormal inputs).
    const left_key = if (left & sign != 0) ~left else left ^ sign;
    const right_key = if (right & sign != 0) ~right else right ^ sign;
    const choose_left = if (maximum) left_key > right_key else left_key < right_key;
    try testing.expectEqual(if (choose_left) left else right, actual);
}

fn expectSimdFloatMinMax(comptime U: type, instance: *interp.Instance, maximum: bool, left: u128, right: u128) !void {
    const before = instance.spasm_runs;
    const result = try interp.invoke(instance, testing.allocator, 0, &.{ 37, simd_live_vector, left, right });
    defer testing.allocator.free(result);
    try testing.expectEqual(@as(usize, 3), result.len);
    try testing.expectEqual(@as(u128, 37), result[0]);
    try testing.expectEqual(simd_live_vector, result[1]);
    for (0..128 / @bitSizeOf(U)) |lane| {
        const shift: u7 = @intCast(lane * @bitSizeOf(U));
        try expectFloatMinMaxLane(U, @truncate(left >> shift), @truncate(right >> shift), @truncate(result[2] >> shift), maximum);
    }
    try testing.expectEqual(before + 1, instance.spasm_runs);
}

fn testSimdFloatMinMax(comptime U: type) !void {
    if (comptime !@import("spasm.zig").supported) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const sign: U = @as(U, 1) << (@bitSizeOf(U) - 1);
    const exponent: U = if (U == u32) 0x7f80_0000 else 0x7ff0_0000_0000_0000;
    const quiet: U = if (U == u32) 0x0040_0000 else 0x0008_0000_0000_0000;
    const one: U = if (U == u32) 0x3f80_0000 else 0x3ff0_0000_0000_0000;
    const values = [_]U{
        0,                    sign,                            1,            sign | 1,            quiet * 2 - 1,          sign | (quiet * 2 - 1),
        quiet * 2,            sign | (quiet * 2),              one - 1,      one,                 one + 1,                sign | one,
        exponent - 1,         sign | (exponent - 1),           exponent,     sign | exponent,     exponent | quiet,       sign | exponent | quiet,
        exponent | quiet | 1, sign | exponent | quiet | 0x123, exponent | 1, sign | exponent | 1, exponent | (quiet - 1), sign | exponent | (quiet - 1),
    };
    for ([_]bool{ false, true }) |maximum| {
        const sub: u32 = if (U == u32) (if (maximum) 233 else 232) else (if (maximum) 245 else 244);
        const module = try wasm.decode(a, try buildSimdBinaryFunc(a, sub));
        var instance: interp.Instance = undefined;
        try interp.instantiate(&instance, a, testing.allocator, &module, .{});
        defer instance.deinit();
        instance.spasm_enabled = true;
        for (0..values.len) |li| {
            for (0..values.len) |ri| {
                var left: u128 = 0;
                var right: u128 = 0;
                for (0..128 / @bitSizeOf(U)) |lane| {
                    const shift: u7 = @intCast(lane * @bitSizeOf(U));
                    left |= @as(u128, values[(li + lane * 3) % values.len]) << shift;
                    right |= @as(u128, values[(ri + lane * 5) % values.len]) << shift;
                }
                try expectSimdFloatMinMax(U, &instance, maximum, left, right);
                try expectSimdFloatMinMax(U, &instance, maximum, right, left);
                try expectSimdFloatMinMax(U, &instance, maximum, left, left);
            }
        }
        // Sweep payload bits with quiet/signaling NaNs, including the last
        // payload bit, without requiring an implementation-specific payload.
        for (0..@bitSizeOf(U) - (if (U == u32) @as(usize, 9) else 12)) |bit| {
            const payload = @as(U, 1) << @as(std.math.Log2Int(U), @intCast(bit));
            var left: u128 = 0;
            var right: u128 = 0;
            for (0..128 / @bitSizeOf(U)) |lane| {
                const shift: u7 = @intCast(lane * @bitSizeOf(U));
                left |= @as(u128, exponent | payload | (if (lane % 2 == 0) @as(U, 0) else sign)) << shift;
                right |= @as(u128, values[lane]) << shift;
            }
            try expectSimdFloatMinMax(U, &instance, maximum, left, right);
            try expectSimdFloatMinMax(U, &instance, maximum, right, left);
        }
        try testing.expectEqual(@as(u32, 1), instance.spasm_compiles);
    }
}

test "wasm spasm: SIMD float minmax f32 handles NaNs zeros subnormals and live lanes" {
    try testSimdFloatMinMax(u32);
}

test "wasm spasm: SIMD float minmax f64 handles NaNs zeros subnormals and live lanes" {
    try testSimdFloatMinMax(u64);
}

test "wasm spasm: SIMD float minmax skips unreachable code" {
    if (comptime !@import("spasm.zig").supported) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_]u32{ 232, 233, 244, 245 }) |sub| {
        var body: List = .empty;
        try body.appendSlice(a, &.{ 0, 0x02, 0x7b, 0x20, 0, 0x0c, 0, 0x20, 0, 0x20, 0, 0xfd });
        try uleb(a, &body, sub);
        try body.appendSlice(a, &.{ 0x0b, 0x0b });
        const module = try wasm.decode(a, try buildFunc(a, &.{0x7b}, &.{0x7b}, body.items, "dead"));
        var instance: interp.Instance = undefined;
        try interp.instantiate(&instance, a, testing.allocator, &module, .{});
        defer instance.deinit();
        instance.spasm_enabled = true;
        const result = try interp.invoke(&instance, testing.allocator, 0, &.{simd_live_vector});
        defer testing.allocator.free(result);
        try testing.expectEqualSlices(u128, &.{simd_live_vector}, result);
        try testing.expectEqual(@as(u32, 1), instance.spasm_compiles);
        try testing.expectEqual(@as(u32, 1), instance.spasm_runs);
    }
}

test "wasm interp: scalar float minmax quiets signaling NaNs" {
    inline for (.{ u32, u64 }) |U| {
        const exponent: U = if (U == u32) 0x7f80_0000 else 0x7ff0_0000_0000_0000;
        const one: U = if (U == u32) 0x3f80_0000 else 0x3ff0_0000_0000_0000;
        const snan = exponent | 1;
        const ty: u8 = if (U == u32) 0x7d else 0x7c;
        for ([_]bool{ false, true }) |maximum| {
            const op: u8 = if (U == u32) (if (maximum) 0x97 else 0x96) else (if (maximum) 0xa5 else 0xa4);
            for ([_]bool{ false, true }) |swap| {
                const left = if (swap) one else snan;
                const right = if (swap) snan else one;
                const actual = try callCells(&.{ ty, ty }, &.{ty}, &.{ 0, 0x20, 0, 0x20, 1, op, 0x0b }, "f", null, &.{ left, right });
                try expectFloatMinMaxLane(U, left, right, @truncate(actual), maximum);
            }
        }
    }
}

test "wasm interp: SIMD float minmax quiets signaling NaNs" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    inline for (.{ u32, u64 }) |U| {
        const exponent: U = if (U == u32) 0x7f80_0000 else 0x7ff0_0000_0000_0000;
        const one: U = if (U == u32) 0x3f80_0000 else 0x3ff0_0000_0000_0000;
        const snan = exponent | 1;
        for ([_]bool{ false, true }) |maximum| {
            const sub: u32 = if (U == u32) (if (maximum) 233 else 232) else (if (maximum) 245 else 244);
            const module = try wasm.decode(a, try buildSimdBinaryFunc(a, sub));
            var instance: interp.Instance = undefined;
            try interp.instantiate(&instance, a, testing.allocator, &module, .{});
            defer instance.deinit();
            instance.spasm_enabled = false;
            for ([_]bool{ false, true }) |swap| {
                const left = if (swap) one else snan;
                const right = if (swap) snan else one;
                const result = try interp.invoke(&instance, testing.allocator, 0, &.{ 37, simd_live_vector, left, right });
                defer testing.allocator.free(result);
                try expectFloatMinMaxLane(U, left, right, @truncate(result[2]), maximum);
            }
            try testing.expectEqual(@as(u32, 0), instance.spasm_runs);
        }
    }
}

const SimdProductCase = struct {
    sub: u32,
    bits: u7,
    kind: enum { extmul, dot, q15 },
    signed: bool = true,
    high: bool = false,
};

const simd_product_cases = [_]SimdProductCase{
    .{ .sub = 156, .bits = 8, .kind = .extmul },
    .{ .sub = 157, .bits = 8, .kind = .extmul, .high = true },
    .{ .sub = 158, .bits = 8, .kind = .extmul, .signed = false },
    .{ .sub = 159, .bits = 8, .kind = .extmul, .signed = false, .high = true },
    .{ .sub = 188, .bits = 16, .kind = .extmul },
    .{ .sub = 189, .bits = 16, .kind = .extmul, .high = true },
    .{ .sub = 190, .bits = 16, .kind = .extmul, .signed = false },
    .{ .sub = 191, .bits = 16, .kind = .extmul, .signed = false, .high = true },
    .{ .sub = 220, .bits = 32, .kind = .extmul },
    .{ .sub = 221, .bits = 32, .kind = .extmul, .high = true },
    .{ .sub = 222, .bits = 32, .kind = .extmul, .signed = false },
    .{ .sub = 223, .bits = 32, .kind = .extmul, .signed = false, .high = true },
    .{ .sub = 186, .bits = 16, .kind = .dot },
    .{ .sub = 130, .bits = 16, .kind = .q15 },
};

fn expectedSimdProduct(op: SimdProductCase, left: u128, right: u128) u128 {
    const out_bits: u7 = if (op.kind == .q15) 16 else op.bits * 2;
    const out_lanes = 128 / @as(usize, out_bits);
    const mask = (@as(u128, 1) << out_bits) - 1;
    var expected: u128 = 0;
    for (0..out_lanes) |lane| {
        const source = if (op.kind == .dot) lane * 2 else lane + (if (op.high) out_lanes else 0);
        var value = simdLaneInteger(left, op.bits, source, op.signed) * simdLaneInteger(right, op.bits, source, op.signed);
        if (op.kind == .dot) value += simdLaneInteger(left, op.bits, source + 1, true) * simdLaneInteger(right, op.bits, source + 1, true);
        if (op.kind == .q15) value = std.math.clamp(@divFloor(value + 16384, 32768), -32768, 32767);
        expected |= (@as(u128, @bitCast(value)) & mask) << @as(u7, @intCast(lane * out_bits));
    }
    return expected;
}

fn expectSimdProduct(instance: *interp.Instance, op: SimdProductCase, left: u128, right: u128) !void {
    const before = instance.spasm_runs;
    const result = try interp.invoke(instance, testing.allocator, 0, &.{ 37, simd_live_vector, left, right });
    defer testing.allocator.free(result);
    try testing.expectEqualSlices(u128, &.{ 37, simd_live_vector, expectedSimdProduct(op, left, right) }, result);
    try testing.expectEqual(before + 1, instance.spasm_runs);
}

test "wasm spasm: SIMD products preserve overflow rounding order and live lanes" {
    if (comptime !@import("spasm.zig").supported) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for (simd_product_cases) |op| {
        const module = try wasm.decode(a, try buildSimdBinaryFunc(a, op.sub));
        var instance: interp.Instance = undefined;
        try interp.instantiate(&instance, a, testing.allocator, &module, .{});
        defer instance.deinit();
        instance.spasm_enabled = true;
        const sign = @as(u128, 1) << (op.bits - 1);
        const mask = sign * 2 - 1;
        const values = [_]u128{ 0, 1, 2, 3, sign - 1, sign, sign + 1, mask - 1, mask, sign / 2 - 1, sign / 2, sign / 2 + 1, 0x55555555 & mask, 0xaaaaaaaa & mask };
        for (0..values.len) |li| {
            for (0..values.len) |ri| {
                for ([_]bool{ false, true }) |mixed| {
                    var left: u128 = 0;
                    var right: u128 = 0;
                    for (0..128 / @as(usize, op.bits)) |lane| {
                        const shift: u7 = @intCast(lane * op.bits);
                        left |= values[(li + (if (mixed) lane * 3 else 0)) % values.len] << shift;
                        right |= values[(ri + (if (mixed) lane * 5 else 0)) % values.len] << shift;
                    }
                    try expectSimdProduct(&instance, op, left, right);
                }
            }
        }
        for (0..128) |bit| {
            const single = @as(u128, 1) << @as(u7, @intCast(bit));
            try expectSimdProduct(&instance, op, single, ~single);
            try expectSimdProduct(&instance, op, ~single, single);
        }
        try testing.expectEqual(@as(u32, 1), instance.spasm_compiles);
    }
}

test "wasm spasm: SIMD products exhaust extended byte pairs" {
    if (comptime !@import("spasm.zig").supported) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for (simd_product_cases[0..4]) |op| {
        const module = try wasm.decode(a, try buildSimdBinaryFunc(a, op.sub));
        var instance: interp.Instance = undefined;
        try interp.instantiate(&instance, a, testing.allocator, &module, .{});
        defer instance.deinit();
        instance.spasm_enabled = true;
        for (0..256) |lhs| {
            for (0..32) |batch| {
                var left: u128 = 0;
                var right: u128 = 0;
                for (0..16) |lane| {
                    const lv: u8 = @truncate(lhs + lane * 17);
                    const rv: u8 = @intCast(batch * 8 + lane % 8);
                    left |= @as(u128, lv) << @as(u7, @intCast(lane * 8));
                    right |= @as(u128, rv) << @as(u7, @intCast(lane * 8));
                }
                try expectSimdProduct(&instance, op, left, right);
            }
        }
    }
}

test "wasm spasm: SIMD products exhaust Q15 inputs against rounding multipliers" {
    if (comptime !@import("spasm.zig").supported) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const op: SimdProductCase = .{ .sub = 130, .bits = 16, .kind = .q15 };
    const module = try wasm.decode(a, try buildSimdBinaryFunc(a, op.sub));
    var instance: interp.Instance = undefined;
    try interp.instantiate(&instance, a, testing.allocator, &module, .{});
    defer instance.deinit();
    instance.spasm_enabled = true;
    for ([_]u16{ 0, 1, 0x3fff, 0x4000, 0x4001, 0x7fff, 0x8000, 0x8001, 0xc000, 0xffff }) |multiplier| {
        for (0..8192) |batch| {
            var left: u128 = 0;
            var right: u128 = 0;
            for (0..8) |lane| {
                const shift: u7 = @intCast(lane * 16);
                left |= @as(u128, batch * 8 + lane) << shift;
                right |= @as(u128, multiplier) << shift;
            }
            try expectSimdProduct(&instance, op, left, right);
        }
    }
}

test "wasm spasm: SIMD products cover mixed wide multiplication bits" {
    if (comptime !@import("spasm.zig").supported) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var state: u128 = 0x92d68ca2f73edabc94d049bb133111eb;
    for (simd_product_cases[4..]) |op| {
        const module = try wasm.decode(a, try buildSimdBinaryFunc(a, op.sub));
        var instance: interp.Instance = undefined;
        try interp.instantiate(&instance, a, testing.allocator, &module, .{});
        defer instance.deinit();
        instance.spasm_enabled = true;
        for (0..1024) |_| {
            state = state *% 0x2360ed051fc65da44385df649fccf645 +% 0xda3e39cb94b95bdb;
            const left = state;
            state = state *% 0x2360ed051fc65da44385df649fccf645 +% 0xda3e39cb94b95bdb;
            try expectSimdProduct(&instance, op, left, state);
        }
    }
}

test "wasm spasm: SIMD products skip unreachable operations" {
    if (comptime !@import("spasm.zig").supported) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for (simd_product_cases) |op| {
        var body: List = .empty;
        try body.appendSlice(a, &.{ 1, 32, 0x7f, 0x20, 0, 0x20, 1, 0x02, 0x7b, 0x20, 2, 0x0c, 0, 0x20, 2, 0x20, 3, 0xfd });
        try uleb(a, &body, op.sub);
        try body.appendSlice(a, &.{ 0x0b, 0x0b });
        const module = try wasm.decode(a, try buildFunc(a, &.{ 0x7e, 0x7b, 0x7b, 0x7b }, &.{ 0x7e, 0x7b, 0x7b }, body.items, "product"));
        var instance: interp.Instance = undefined;
        try interp.instantiate(&instance, a, testing.allocator, &module, .{});
        defer instance.deinit();
        instance.spasm_enabled = true;
        const result = try interp.invoke(&instance, testing.allocator, 0, &.{ 37, simd_live_vector, ~simd_live_vector, 0 });
        defer testing.allocator.free(result);
        try testing.expectEqualSlices(u128, &.{ 37, simd_live_vector, ~simd_live_vector }, result);
        try testing.expectEqual(@as(u32, 1), instance.spasm_runs);
    }
}

test "wasm: SIMD dot fallback wraps its pairwise sum" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const module = try wasm.decode(a, try buildSimdBinaryFunc(a, 186));
    var instance: interp.Instance = undefined;
    try interp.instantiate(&instance, a, testing.allocator, &module, .{});
    defer instance.deinit();
    instance.spasm_enabled = false;
    const minima: u128 = 0x80008000800080008000800080008000;
    const result = try interp.invoke(&instance, testing.allocator, 0, &.{ 37, simd_live_vector, minima, minima });
    defer testing.allocator.free(result);
    try testing.expectEqualSlices(u128, &.{ 37, simd_live_vector, 0x80000000800000008000000080000000 }, result);
    try testing.expectEqual(@as(u32, 0), instance.spasm_runs);
}

const SimdLaneConversionCase = struct {
    sub: u32,
    bits: u7,
    kind: enum { narrow, extend, pairwise },
    signed: bool,
    high: bool = false,
};

const simd_lane_conversion_cases = [_]SimdLaneConversionCase{
    .{ .sub = 101, .bits = 16, .kind = .narrow, .signed = true },
    .{ .sub = 102, .bits = 16, .kind = .narrow, .signed = false },
    .{ .sub = 133, .bits = 32, .kind = .narrow, .signed = true },
    .{ .sub = 134, .bits = 32, .kind = .narrow, .signed = false },
    .{ .sub = 135, .bits = 8, .kind = .extend, .signed = true },
    .{ .sub = 136, .bits = 8, .kind = .extend, .signed = true, .high = true },
    .{ .sub = 137, .bits = 8, .kind = .extend, .signed = false },
    .{ .sub = 138, .bits = 8, .kind = .extend, .signed = false, .high = true },
    .{ .sub = 167, .bits = 16, .kind = .extend, .signed = true },
    .{ .sub = 168, .bits = 16, .kind = .extend, .signed = true, .high = true },
    .{ .sub = 169, .bits = 16, .kind = .extend, .signed = false },
    .{ .sub = 170, .bits = 16, .kind = .extend, .signed = false, .high = true },
    .{ .sub = 199, .bits = 32, .kind = .extend, .signed = true },
    .{ .sub = 200, .bits = 32, .kind = .extend, .signed = true, .high = true },
    .{ .sub = 201, .bits = 32, .kind = .extend, .signed = false },
    .{ .sub = 202, .bits = 32, .kind = .extend, .signed = false, .high = true },
    .{ .sub = 124, .bits = 8, .kind = .pairwise, .signed = true },
    .{ .sub = 125, .bits = 8, .kind = .pairwise, .signed = false },
    .{ .sub = 126, .bits = 16, .kind = .pairwise, .signed = true },
    .{ .sub = 127, .bits = 16, .kind = .pairwise, .signed = false },
};

fn buildSimdLaneConversionFunc(a: std.mem.Allocator, op: SimdLaneConversionCase, dead: bool) ![]const u8 {
    var body: List = .empty;
    try body.appendSlice(a, &.{ 1, 32, 0x7f, 0x20, 0, 0x20, 1 });
    if (dead) try body.appendSlice(a, &.{ 0x02, 0x7b, 0x20, 2, 0x0c, 0 });
    try body.appendSlice(a, &.{ 0x20, 2 });
    if (op.kind == .narrow) try body.appendSlice(a, &.{ 0x20, 3 });
    try body.append(a, 0xfd);
    try uleb(a, &body, op.sub);
    if (dead) try body.append(a, 0x0b);
    try body.append(a, 0x0b);
    return buildFunc(a, &.{ 0x7e, 0x7b, 0x7b, 0x7b }, &.{ 0x7e, 0x7b, 0x7b }, body.items, "lanes");
}

fn simdLaneInteger(value: u128, bits: u7, lane: usize, signed: bool) i128 {
    const modulus = @as(u128, 1) << bits;
    const raw = (value >> @as(u7, @intCast(lane * bits))) & (modulus - 1);
    return @as(i128, @intCast(raw)) - (if (signed and raw >= modulus / 2) @as(i128, @intCast(modulus)) else 0);
}

fn expectedSimdLaneConversion(op: SimdLaneConversionCase, left: u128, right: u128) u128 {
    const out_bits: u7 = if (op.kind == .narrow) op.bits / 2 else op.bits * 2;
    const modulus = @as(u128, 1) << out_bits;
    const out_lanes = 128 / @as(usize, out_bits);
    var expected: u128 = 0;
    for (0..out_lanes) |lane| {
        const value = switch (op.kind) {
            .narrow => blk: {
                // Core narrow_u also interprets its *source* as signed.
                const input = if (lane < out_lanes / 2) left else right;
                const number = simdLaneInteger(input, op.bits, lane % (out_lanes / 2), true);
                const lower: i128 = if (op.signed) -@as(i128, @intCast(modulus / 2)) else 0;
                const upper: i128 = @intCast((if (op.signed) modulus / 2 else modulus) - 1);
                break :blk std.math.clamp(number, lower, upper);
            },
            .extend => simdLaneInteger(left, op.bits, lane + (if (op.high) out_lanes else 0), op.signed),
            .pairwise => simdLaneInteger(left, op.bits, lane * 2, op.signed) + simdLaneInteger(left, op.bits, lane * 2 + 1, op.signed),
        };
        expected |= (@as(u128, @bitCast(value)) & (modulus - 1)) << @as(u7, @intCast(lane * out_bits));
    }
    return expected;
}

fn expectSimdLaneConversion(instance: *interp.Instance, op: SimdLaneConversionCase, left: u128, right: u128) !void {
    const before = instance.spasm_runs;
    const result = try interp.invoke(instance, testing.allocator, 0, &.{ 37, simd_live_vector, left, right });
    defer testing.allocator.free(result);
    try testing.expectEqualSlices(u128, &.{ 37, simd_live_vector, expectedSimdLaneConversion(op, left, right) }, result);
    try testing.expectEqual(before + 1, instance.spasm_runs);
}

test "wasm spasm: SIMD lane conversions preserve saturation boundaries order and live lanes" {
    if (comptime !@import("spasm.zig").supported) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for (simd_lane_conversion_cases) |op| {
        const module = try wasm.decode(a, try buildSimdLaneConversionFunc(a, op, false));
        var instance: interp.Instance = undefined;
        try interp.instantiate(&instance, a, testing.allocator, &module, .{});
        defer instance.deinit();
        instance.spasm_enabled = true;
        const sign = @as(u128, 1) << (op.bits - 1);
        const mask = sign * 2 - 1;
        const narrow_limit = @as(u128, 1) << (op.bits / 2);
        const values = [_]u128{ 0, 1, 2, sign - 1, sign, sign + 1, mask - 1, mask, narrow_limit / 2 - 1, narrow_limit / 2, narrow_limit - 1, narrow_limit, (mask - narrow_limit / 2) & mask, (mask - narrow_limit / 2 + 1) & mask, 0x55555555 & mask, 0xaaaaaaaa & mask };
        for (0..values.len) |li| {
            for (0..values.len) |ri| {
                var left: u128 = 0;
                var right: u128 = 0;
                for (0..128 / @as(usize, op.bits)) |lane| {
                    const shift: u7 = @intCast(lane * op.bits);
                    left |= values[(li + lane * 3) % values.len] << shift;
                    right |= values[(ri + lane * 5) % values.len] << shift;
                }
                try expectSimdLaneConversion(&instance, op, left, right);
            }
        }
        for (0..128) |bit| {
            const single = @as(u128, 1) << @as(u7, @intCast(bit));
            try expectSimdLaneConversion(&instance, op, single, ~single);
            try expectSimdLaneConversion(&instance, op, ~single, single);
        }
        try testing.expectEqual(@as(u32, 1), instance.spasm_compiles);
    }
}

test "wasm spasm: SIMD lane conversions exhaust narrow halfwords and extended bytes" {
    if (comptime !@import("spasm.zig").supported) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for (simd_lane_conversion_cases) |op| {
        if (!(op.kind == .narrow and op.bits == 16) and !(op.kind == .extend and op.bits <= 16)) continue;
        const module = try wasm.decode(a, try buildSimdLaneConversionFunc(a, op, false));
        var instance: interp.Instance = undefined;
        try interp.instantiate(&instance, a, testing.allocator, &module, .{});
        defer instance.deinit();
        instance.spasm_enabled = true;
        const lanes = 128 / @as(usize, op.bits);
        const count = @as(usize, 1) << @as(u6, @intCast(op.bits));
        for (0..count) |base| {
            var left: u128 = 0;
            for (0..lanes) |lane| left |= @as(u128, (base + lane * 17) % count) << @as(u7, @intCast(lane * op.bits));
            try expectSimdLaneConversion(&instance, op, left, ~left);
        }
        try testing.expectEqual(@as(u32, 1), instance.spasm_compiles);
    }
}

test "wasm spasm: SIMD lane conversions exhaust pairwise byte pairs" {
    if (comptime !@import("spasm.zig").supported) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for (simd_lane_conversion_cases) |op| {
        if (op.kind != .pairwise or op.bits != 8) continue;
        const module = try wasm.decode(a, try buildSimdLaneConversionFunc(a, op, false));
        var instance: interp.Instance = undefined;
        try interp.instantiate(&instance, a, testing.allocator, &module, .{});
        defer instance.deinit();
        instance.spasm_enabled = true;
        for (0..256) |left| {
            for (0..32) |batch| {
                var input: u128 = 0;
                for (0..8) |lane| {
                    const low: u8 = @truncate(left + lane * 17);
                    const high: u8 = @intCast(batch * 8 + lane);
                    input |= (@as(u128, low) | (@as(u128, high) << 8)) << @as(u7, @intCast(lane * 16));
                }
                try expectSimdLaneConversion(&instance, op, input, 0);
            }
        }
        try testing.expectEqual(@as(u32, 8192), instance.spasm_runs);
    }
}

test "wasm spasm: SIMD lane conversions skip unreachable code" {
    if (comptime !@import("spasm.zig").supported) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for (simd_lane_conversion_cases) |op| {
        const module = try wasm.decode(a, try buildSimdLaneConversionFunc(a, op, true));
        var instance: interp.Instance = undefined;
        try interp.instantiate(&instance, a, testing.allocator, &module, .{});
        defer instance.deinit();
        instance.spasm_enabled = true;
        const result = try interp.invoke(&instance, testing.allocator, 0, &.{ 37, simd_live_vector, ~simd_live_vector, 0 });
        defer testing.allocator.free(result);
        try testing.expectEqualSlices(u128, &.{ 37, simd_live_vector, ~simd_live_vector }, result);
        try testing.expectEqual(@as(u32, 1), instance.spasm_runs);
    }
}

const simd_float_arithmetic_ops = [_]u32{ 224, 225, 227, 228, 229, 230, 231, 236, 237, 239, 240, 241, 242, 243 };

fn buildSimdFloatArithmeticFunc(a: std.mem.Allocator, sub: u32, dead: bool) ![]const u8 {
    const unary = (sub - (if (sub < 236) @as(u32, 224) else 236)) < 4;
    return buildSimdFloatFunc(a, sub, unary, dead);
}

fn buildSimdFloatFunc(a: std.mem.Allocator, sub: u32, unary: bool, dead: bool) ![]const u8 {
    var body: List = .empty;
    try body.appendSlice(a, &.{ 1, 32, 0x7f, 0x20, 0, 0x20, 1 });
    if (dead) try body.appendSlice(a, &.{ 0x02, 0x7b, 0x20, 2, 0x0c, 0 });
    try body.appendSlice(a, &.{ 0x20, 2 });
    if (!unary) try body.appendSlice(a, &.{ 0x20, 3 });
    try body.append(a, 0xfd);
    try uleb(a, &body, sub);
    if (dead) try body.append(a, 0x0b);
    try body.append(a, 0x0b);
    return buildFunc(a, &.{ 0x7e, 0x7b, 0x7b, 0x7b }, &.{ 0x7e, 0x7b, 0x7b }, body.items, "float");
}

fn expectSimdFloatArithmeticLane(comptime U: type, sub: u32, left: U, right: U, actual: U) !void {
    const sign: U = @as(U, 1) << (@bitSizeOf(U) - 1);
    const exponent: U = if (U == u32) 0x7f80_0000 else 0x7ff0_0000_0000_0000;
    const quiet: U = if (U == u32) 0x0040_0000 else 0x0008_0000_0000_0000;
    const op = sub - (if (U == u32) @as(u32, 224) else 236);
    if (op == 0 or op == 1) {
        // abs/neg are bit operations, including on signaling NaNs.
        try testing.expectEqual(if (op == 0) left & ~sign else left ^ sign, actual);
        return;
    }
    const F = if (U == u32) f32 else f64;
    const lhs: F = @bitCast(left);
    const rhs: F = @bitCast(right);
    const expected: F = switch (op) {
        3 => @sqrt(lhs),
        4 => lhs + rhs,
        5 => lhs - rhs,
        6 => lhs * rhs,
        7 => lhs / rhs,
        else => unreachable,
    };
    if (std.math.isNan(expected)) {
        if ((left & ~sign) > exponent or (op != 3 and (right & ~sign) > exponent)) {
            try expectFloatMinMaxLane(U, left, if (op == 3) 0 else right, actual, false);
        } else {
            // Invalid arithmetic without NaN inputs produces a canonical NaN.
            try testing.expectEqual(exponent | quiet, actual & ~sign);
        }
    } else try testing.expectEqual(@as(U, @bitCast(expected)), actual);
}

fn testSimdFloatArithmetic(comptime U: type) !void {
    if (comptime !@import("spasm.zig").supported) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const sign: U = @as(U, 1) << (@bitSizeOf(U) - 1);
    const exponent: U = if (U == u32) 0x7f80_0000 else 0x7ff0_0000_0000_0000;
    const quiet: U = if (U == u32) 0x0040_0000 else 0x0008_0000_0000_0000;
    const one: U = if (U == u32) 0x3f80_0000 else 0x3ff0_0000_0000_0000;
    const values = [_]U{
        0,               sign,                1,                sign | 1,                quiet * 2 - 1,        sign | (quiet * 2 - 1),
        quiet * 2,       sign | (quiet * 2),  one - 1,          one,                     one + 1,              sign | one,
        one + quiet * 2, one - quiet * 2,     one + quiet * 4,  one + quiet * 3,         exponent - 1,         sign | (exponent - 1),
        exponent,        sign | exponent,     exponent | quiet, sign | exponent | quiet, exponent | quiet | 1, sign | exponent | quiet | 0x123,
        exponent | 1,    sign | exponent | 1,
    };
    for (simd_float_arithmetic_ops) |sub| {
        if ((sub < 236) != (U == u32)) continue;
        const module = try wasm.decode(a, try buildSimdFloatArithmeticFunc(a, sub, false));
        var instance: interp.Instance = undefined;
        try interp.instantiate(&instance, a, testing.allocator, &module, .{});
        defer instance.deinit();
        instance.spasm_enabled = true;
        for (0..values.len) |li| {
            for (0..values.len) |ri| {
                var left: u128 = 0;
                var right: u128 = 0;
                for (0..128 / @bitSizeOf(U)) |lane| {
                    const shift: u7 = @intCast(lane * @bitSizeOf(U));
                    left |= @as(u128, values[(li + lane * 3) % values.len]) << shift;
                    right |= @as(u128, values[(ri + lane * 5) % values.len]) << shift;
                }
                const before = instance.spasm_runs;
                const result = try interp.invoke(&instance, testing.allocator, 0, &.{ 37, simd_live_vector, left, right });
                defer testing.allocator.free(result);
                try testing.expectEqual(@as(usize, 3), result.len);
                try testing.expectEqual(@as(u128, 37), result[0]);
                try testing.expectEqual(simd_live_vector, result[1]);
                for (0..128 / @bitSizeOf(U)) |lane| {
                    const shift: u7 = @intCast(lane * @bitSizeOf(U));
                    try expectSimdFloatArithmeticLane(U, sub, @truncate(left >> shift), @truncate(right >> shift), @truncate(result[2] >> shift));
                }
                try testing.expectEqual(before + 1, instance.spasm_runs);
            }
        }
        try testing.expectEqual(@as(u32, 1), instance.spasm_compiles);
    }
}

test "wasm spasm: SIMD float arithmetic f32 preserves IEEE results and live lanes" {
    try testSimdFloatArithmetic(u32);
}

test "wasm spasm: SIMD float arithmetic f64 preserves IEEE results and live lanes" {
    try testSimdFloatArithmetic(u64);
}

test "wasm spasm: SIMD float arithmetic skips unreachable code" {
    if (comptime !@import("spasm.zig").supported) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for (simd_float_arithmetic_ops) |sub| {
        const module = try wasm.decode(a, try buildSimdFloatArithmeticFunc(a, sub, true));
        var instance: interp.Instance = undefined;
        try interp.instantiate(&instance, a, testing.allocator, &module, .{});
        defer instance.deinit();
        instance.spasm_enabled = true;
        const result = try interp.invoke(&instance, testing.allocator, 0, &.{ 37, simd_live_vector, ~simd_live_vector, 0 });
        defer testing.allocator.free(result);
        try testing.expectEqualSlices(u128, &.{ 37, simd_live_vector, ~simd_live_vector }, result);
        try testing.expectEqual(@as(u32, 1), instance.spasm_runs);
    }
}

fn simdRelaxedTernary(sub: u32) bool {
    return sub <= 268 or sub == 275;
}

fn buildSimdRelaxedFunc(a: std.mem.Allocator, sub: u32, repetitions: usize, dead: bool) ![]const u8 {
    var body: List = .empty;
    try body.appendSlice(a, &.{ 1, 32, 0x7f, 0x20, 0, 0x20, 1 });
    if (dead) try body.appendSlice(a, &.{ 0x02, 0x7b, 0x20, 2, 0x0c, 0 });
    try body.appendSlice(a, &.{ 0x20, 2 });
    for (0..repetitions) |_| {
        try body.appendSlice(a, &.{ 0x20, 3 });
        if (simdRelaxedTernary(sub)) try body.appendSlice(a, &.{ 0x20, 4 });
        try body.append(a, 0xfd);
        try uleb(a, &body, sub);
    }
    if (dead) try body.append(a, 0x0b);
    try body.append(a, 0x0b);
    return buildFunc(a, &.{ 0x7e, 0x7b, 0x7b, 0x7b, 0x7b }, &.{ 0x7e, 0x7b, 0x7b }, body.items, "relaxed");
}

fn expectSimdRelaxedFloatLane(comptime U: type, sub: u32, left: U, right: U, third: U, actual: U) !void {
    @setFloatMode(.strict);
    if (sub >= 269) return expectFloatMinMaxLane(U, left, right, actual, sub % 2 == 0);
    const F = if (U == u32) f32 else f64;
    const lhs: F = @bitCast(left);
    const rhs: F = @bitCast(right);
    const acc: F = @bitCast(third);
    const product: F = (if (sub % 2 == 0) -lhs else lhs) * rhs;
    const expected: F = product + acc;
    if (!std.math.isNan(expected)) return testing.expectEqual(@as(U, @bitCast(expected)), actual);
    const sign: U = @as(U, 1) << (@bitSizeOf(U) - 1);
    const exponent: U = if (U == u32) 0x7f800000 else 0x7ff0000000000000;
    const quiet: U = if (U == u32) 0x00400000 else 0x0008000000000000;
    var canonical = true;
    for ([_]U{ left, right, third }) |input| {
        const magnitude = input & ~sign;
        if (magnitude > exponent and magnitude != exponent | quiet) canonical = false;
    }
    try testing.expectEqual(exponent | quiet, actual & (if (canonical) ~sign else exponent | quiet));
}

fn expectedSimdRelaxedInteger(sub: u32, left: u128, right: u128, third: u128) u128 {
    if (sub <= 268) return (left & third) | (right & ~third);
    if (sub == 273) {
        const x: [8]i16 = @bitCast(left);
        const y: [8]i16 = @bitCast(right);
        var r: [8]i16 = undefined;
        for (&r, 0..) |*lane, i| {
            const product = (@as(i64, x[i]) * y[i] + 16384) >> 15;
            lane.* = @intCast(std.math.clamp(product, -32768, 32767));
        }
        return @bitCast(r);
    }
    const x: [16]i8 = @bitCast(left);
    const y: [16]i8 = @bitCast(right);
    var pairs: [8]i16 = undefined;
    for (&pairs, 0..) |*lane, i| {
        const sum = @as(i32, x[i * 2]) * y[i * 2] + @as(i32, x[i * 2 + 1]) * y[i * 2 + 1];
        lane.* = @intCast(std.math.clamp(sum, -32768, 32767));
    }
    if (sub == 274) return @bitCast(pairs);
    const acc: [4]u32 = @bitCast(third);
    var result: [4]u32 = undefined;
    for (&result, 0..) |*lane, i| {
        const widened: i64 = @as(i64, pairs[i * 2]) + pairs[i * 2 + 1] + acc[i];
        lane.* = @truncate(@as(u64, @bitCast(widened)));
    }
    return @bitCast(result);
}

fn expectSimdRelaxed(instance: *interp.Instance, sub: u32, left: u128, right: u128, third: u128, native: bool) !void {
    errdefer std.debug.print("SIMD relaxed subopcode {d}, inputs {x} {x} {x}\n", .{ sub, left, right, third });
    const before = instance.spasm_runs;
    const result = try interp.invoke(instance, testing.allocator, 0, &.{ 37, simd_live_vector, left, right, third });
    defer testing.allocator.free(result);
    try testing.expectEqual(@as(usize, 3), result.len);
    try testing.expectEqual(@as(u128, 37), result[0]);
    try testing.expectEqual(simd_live_vector, result[1]);
    try testing.expectEqual(before + @intFromBool(native), instance.spasm_runs);
    if (sub <= 264 or (sub >= 269 and sub <= 272)) {
        const wide = sub == 263 or sub == 264 or sub == 271 or sub == 272;
        inline for (.{ u32, u64 }) |U| {
            if (wide == (U == u64)) {
                const lhs: [128 / @bitSizeOf(U)]U = @bitCast(left);
                const rhs: [128 / @bitSizeOf(U)]U = @bitCast(right);
                const acc: [128 / @bitSizeOf(U)]U = @bitCast(third);
                const out: [128 / @bitSizeOf(U)]U = @bitCast(result[2]);
                for (out, 0..) |lane, i| try expectSimdRelaxedFloatLane(U, sub, lhs[i], rhs[i], acc[i], lane);
            }
        }
    } else try testing.expectEqual(expectedSimdRelaxedInteger(sub, left, right, third), result[2]);
}

fn testSimdRelaxedFloats(native: bool) !void {
    if (native and !@import("spasm.zig").supported) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    inline for (.{ u32, u64 }) |U| {
        const sign: U = @as(U, 1) << (@bitSizeOf(U) - 1);
        const exp: U = if (U == u32) 0x7f800000 else 0x7ff0000000000000;
        const quiet: U = if (U == u32) 0x00400000 else 0x0008000000000000;
        const one: U = if (U == u32) 0x3f800000 else 0x3ff0000000000000;
        const values = [_]U{ 0, sign, 1, sign | 1, quiet * 2 - 1, quiet * 2, one - 2, one - 1, one, one + 1, sign | one, exp - 1, sign | (exp - 1), exp, sign | exp, exp | quiet, sign | exp | quiet, exp | 1, exp | quiet | 123 };
        for ([_]u32{ 261, 262, 263, 264, 269, 270, 271, 272 }) |sub| {
            if ((sub == 263 or sub == 264 or sub == 271 or sub == 272) != (U == u64)) continue;
            const module = try wasm.decode(a, try buildSimdRelaxedFunc(a, sub, 1, false));
            var instance: interp.Instance = undefined;
            try interp.instantiate(&instance, a, testing.allocator, &module, .{});
            defer instance.deinit();
            instance.spasm_enabled = native;
            for (0..values.len) |x| {
                for (0..values.len) |y| {
                    for (0..values.len) |z| {
                        var left: [128 / @bitSizeOf(U)]U = undefined;
                        var right = left;
                        var third = left;
                        for (0..left.len) |lane| {
                            left[lane] = values[(x + lane) % values.len];
                            right[lane] = values[(y + lane * 3) % values.len];
                            third[lane] = values[(z + lane * 5) % values.len];
                        }
                        try expectSimdRelaxed(&instance, sub, @bitCast(left), @bitCast(right), @bitCast(third), native);
                    }
                }
            }
            if (sub <= 264) {
                // Non-fused cancellation: the product rounds to 1 before the add.
                const left: @Vector(128 / @bitSizeOf(U), U) = @splat(one + 1);
                const right: @Vector(128 / @bitSizeOf(U), U) = @splat(one - 2);
                const third: @Vector(128 / @bitSizeOf(U), U) = @splat(one | (if (sub % 2 == 1) sign else 0));
                const result = try interp.invoke(&instance, testing.allocator, 0, &.{ 37, simd_live_vector, @bitCast(left), @bitCast(right), @bitCast(third) });
                defer testing.allocator.free(result);
                try testing.expectEqual(@as(u128, 0), result[2]);
            }
        }
    }
}

fn testSimdRelaxedIntegers(native: bool) !void {
    if (native and !@import("spasm.zig").supported) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const values = [_]i16{ -32768, -32767, -16384, -1, 0, 1, 127, 128, 16384, 32767 };
    for ([_]u32{ 265, 266, 267, 268, 273, 274, 275 }) |sub| {
        const module = try wasm.decode(a, try buildSimdRelaxedFunc(a, sub, 1, false));
        var instance: interp.Instance = undefined;
        try interp.instantiate(&instance, a, testing.allocator, &module, .{});
        defer instance.deinit();
        instance.spasm_enabled = native;
        for (0..values.len) |x| {
            for (0..values.len) |y| {
                var left: [8]i16 = undefined;
                var right: [8]i16 = undefined;
                for (0..8) |lane| {
                    left[lane] = values[(x + lane) % values.len];
                    right[lane] = values[(y + lane * 3) % values.len];
                }
                for ([_]u128{ 0, std.math.maxInt(u128), simd_live_vector, @bitCast([4]u32{ 0x7fffffff, 0x80000000, 0xffffffff, 0 }) }) |acc|
                    try expectSimdRelaxed(&instance, sub, @bitCast(left), @bitCast(right), acc, native);
            }
        }
        for (0..128) |bit| try expectSimdRelaxed(&instance, sub, simd_live_vector, ~simd_live_vector, @as(u128, 1) << @as(u7, @intCast(bit)), native);
        if (sub >= 274) {
            // Cover every signed byte-product pair, eight independent lanes at once.
            for (0..256) |x| {
                for (0..32) |batch| {
                    var left: [16]u8 = undefined;
                    var right: [16]u8 = undefined;
                    for (0..8) |lane| {
                        left[lane * 2] = @intCast(x);
                        left[lane * 2 + 1] = @intCast(x);
                        right[lane * 2] = @intCast(batch * 8 + lane);
                        right[lane * 2 + 1] = @intCast(batch * 8 + lane);
                    }
                    try expectSimdRelaxed(&instance, sub, @bitCast(left), @bitCast(right), simd_live_vector, native);
                }
            }
        }
    }
}

test "wasm spasm: SIMD relaxed floating operations keep deterministic IEEE behavior" {
    try testSimdRelaxedFloats(true);
}
test "wasm interpreter: SIMD relaxed floating operations keep deterministic IEEE behavior" {
    try testSimdRelaxedFloats(false);
}
test "wasm spasm: SIMD relaxed integer operations preserve masks, saturation and wrapping" {
    try testSimdRelaxedIntegers(true);
}
test "wasm interpreter: SIMD relaxed integer operations preserve masks, saturation and wrapping" {
    try testSimdRelaxedIntegers(false);
}
test "wasm interpreter: SIMD relaxed dot addition wraps at signed limits" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const module = try wasm.decode(a, try buildSimdRelaxedFunc(a, 275, 1, false));
    var instance: interp.Instance = undefined;
    try interp.instantiate(&instance, a, testing.allocator, &module, .{});
    defer instance.deinit();
    instance.spasm_enabled = false;
    const ones: [16]u8 = @splat(1);
    try expectSimdRelaxed(&instance, 275, @bitCast(ones), @bitCast(ones), @bitCast([4]u32{ 0x7fffffff, 0x80000000, 0xfffffffe, 0 }), false);
}
test "wasm spasm: SIMD relaxed operations skip dead code and fit dense reservations" {
    if (comptime !@import("spasm.zig").supported) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for (261..276) |opcode| {
        const sub: u32 = @intCast(opcode);
        for ([_]usize{ 1, 128, 1024 }) |count| {
            const dead = count == 1;
            const module = try wasm.decode(a, try buildSimdRelaxedFunc(a, sub, count, dead));
            var instance: interp.Instance = undefined;
            try interp.instantiate(&instance, a, testing.allocator, &module, .{});
            defer instance.deinit();
            instance.spasm_enabled = true;
            const input: u128 = if (dead) ~simd_live_vector else 0;
            const result = try interp.invoke(&instance, testing.allocator, 0, &.{ 37, simd_live_vector, input, 0, 0 });
            defer testing.allocator.free(result);
            try testing.expectEqualSlices(u128, &.{ 37, simd_live_vector, input }, result);
            try testing.expectEqual(@import("spasm.zig").RefusalStage.none, instance.spasm_last_refusal_stage);
            try testing.expectEqual(@as(u32, 1), instance.spasm_compiles);
            try testing.expectEqual(@as(u32, 1), instance.spasm_runs);
        }
    }
}

const SimdNumericConversion = struct {
    sub: u32,
    kind: enum { trunc_sat, convert, demote, promote },
    wide: bool = false,
    signed: bool = false,
};
const simd_numeric_conversions = [_]SimdNumericConversion{
    .{ .sub = 94, .kind = .demote, .wide = true },
    .{ .sub = 95, .kind = .promote },
    .{ .sub = 248, .kind = .trunc_sat, .signed = true },
    .{ .sub = 249, .kind = .trunc_sat },
    .{ .sub = 250, .kind = .convert, .signed = true },
    .{ .sub = 251, .kind = .convert },
    .{ .sub = 252, .kind = .trunc_sat, .wide = true, .signed = true },
    .{ .sub = 253, .kind = .trunc_sat, .wide = true },
    .{ .sub = 254, .kind = .convert, .wide = true, .signed = true },
    .{ .sub = 255, .kind = .convert, .wide = true },
    .{ .sub = 257, .kind = .trunc_sat, .signed = true },
    .{ .sub = 258, .kind = .trunc_sat },
    .{ .sub = 259, .kind = .trunc_sat, .wide = true, .signed = true },
    .{ .sub = 260, .kind = .trunc_sat, .wide = true },
};

fn buildSimdNumericConversionFunc(a: std.mem.Allocator, sub: u32, repetitions: usize, dead: bool) ![]const u8 {
    var body: List = .empty;
    try body.appendSlice(a, &.{ 1, 32, 0x7f, 0x20, 0, 0x20, 1 });
    if (dead) try body.appendSlice(a, &.{ 0x02, 0x7b, 0x20, 2, 0x0c, 0 });
    try body.appendSlice(a, &.{ 0x20, 2 });
    for (0..repetitions) |_| {
        try body.append(a, 0xfd);
        try uleb(a, &body, sub);
    }
    if (dead) try body.append(a, 0x0b);
    try body.append(a, 0x0b);
    return buildFunc(a, &.{ 0x7e, 0x7b, 0x7b }, &.{ 0x7e, 0x7b, 0x7b }, body.items, "convert");
}

/// Integer-bit oracle: never casts an unchecked float into a host integer.
fn expectedSimdTruncSat(comptime U: type, bits: U, signed: bool) u32 {
    const fraction = if (U == u32) 23 else 52;
    const bias = if (U == u32) 127 else 1023;
    const exponent_mask = if (U == u32) 255 else 2047;
    const negative = bits >> (@bitSizeOf(U) - 1) != 0;
    const exponent = (bits >> fraction) & exponent_mask;
    const mantissa = bits & ((@as(U, 1) << fraction) - 1);
    if (exponent == exponent_mask and mantissa != 0) return 0;
    if (negative and !signed) return 0;
    const power = @as(i32, @intCast(exponent)) - bias;
    if (power < 0) return 0;
    const limit: u32 = if (signed) (if (negative) 0x80000000 else 0x7fffffff) else 0xffffffff;
    const magnitude: u32 = if (power >= 32) limit else blk: {
        const significand: u64 = (@as(u64, 1) << fraction) | mantissa;
        const value = if (power >= fraction)
            significand << @as(u6, @intCast(power - fraction))
        else
            significand >> @as(u6, @intCast(fraction - power));
        break :blk @intCast(@min(value, limit));
    };
    return if (negative) 0 -% magnitude else magnitude;
}

fn expectSimdConvertedFloat(comptime U: type, expected: U, actual: U) !void {
    const exponent: U = if (U == u32) 0x7f800000 else 0x7ff0000000000000;
    const quiet: U = if (U == u32) 0x00400000 else 0x0008000000000000;
    const magnitude = expected & (std.math.maxInt(U) >> 1);
    if (magnitude > exponent) {
        if (magnitude == exponent | quiet)
            try testing.expectEqual(exponent | quiet, actual & (std.math.maxInt(U) >> 1))
        else
            try testing.expectEqual(exponent | quiet, actual & (exponent | quiet));
    } else try testing.expectEqual(expected, actual);
}

fn expectSimdNumericConversion(instance: *interp.Instance, op: SimdNumericConversion, input: u128, native: bool) !void {
    const before = instance.spasm_runs;
    const result = try interp.invoke(instance, testing.allocator, 0, &.{ 37, simd_live_vector, input });
    defer testing.allocator.free(result);
    try testing.expectEqual(@as(usize, 3), result.len);
    try testing.expectEqual(@as(u128, 37), result[0]);
    try testing.expectEqual(simd_live_vector, result[1]);
    const source32: [4]u32 = @bitCast(input);
    const source64: [2]u64 = @bitCast(input);
    const output32: [4]u32 = @bitCast(result[2]);
    const output64: [2]u64 = @bitCast(result[2]);
    const count: usize = if (op.wide or op.kind == .promote) 2 else 4;
    for (0..count) |lane| switch (op.kind) {
        .trunc_sat => try testing.expectEqual(if (op.wide)
            expectedSimdTruncSat(u64, source64[lane], op.signed)
        else
            expectedSimdTruncSat(u32, source32[lane], op.signed), output32[lane]),
        .convert => {
            const exact: f64 = if (op.signed) @floatFromInt(@as(i32, @bitCast(source32[lane]))) else @floatFromInt(source32[lane]);
            if (op.wide)
                try testing.expectEqual(@as(u64, @bitCast(exact)), output64[lane])
            else
                try testing.expectEqual(@as(u32, @bitCast(@as(f32, @floatCast(exact)))), output32[lane]);
        },
        .demote => try expectSimdConvertedFloat(u32, @bitCast(@as(f32, @floatCast(@as(f64, @bitCast(source64[lane]))))), output32[lane]),
        .promote => try expectSimdConvertedFloat(u64, @bitCast(@as(f64, @as(f32, @bitCast(source32[lane])))), output64[lane]),
    };
    if (op.kind == .demote or (op.kind == .trunc_sat and op.wide)) try testing.expectEqual(@as(u64, 0), output64[1]);
    try testing.expectEqual(before + @intFromBool(native), instance.spasm_runs);
}

fn testSimdNumericConversions(native: bool) !void {
    if (native and !@import("spasm.zig").supported) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const bits32 = [_]u32{
        0,          0x80000000, 1,          0x80000001, 0x007fffff, 0x00800000,
        0x3f000000, 0x3f7fffff, 0x3f800000, 0xbf800000, 0xbf7fffff, 0x4effffff,
        0x4f000000, 0x4f000001, 0x4f7fffff, 0x4f800000, 0xceffffff, 0xcf000000,
        0xcf000001, 0x7f7fffff, 0xff7fffff, 0x7f800000, 0xff800000, 0x7fc00000,
        0x7f800001, 0x7fc12345, 0xff800001, 0x00ffffff, 0x01000001, 0x01000003,
        0x7fffffff, 0x80000081, 0xffffff7f, 0xffffffff,
    };
    const bits64 = [_]u64{
        0,                  0x8000000000000000, 1,                  0x8000000000000001, 0x000fffffffffffff, 0x0010000000000000,
        0x3fefffffffffffff, 0x3ff0000000000000, 0xbfefffffffffffff, 0xbff0000000000000, 0x41dfffffffc00000, 0x41dfffffffffffff,
        0x41e0000000000000, 0x41e0000000000001, 0xc1dfffffffffffff, 0xc1e0000000000000, 0xc1e0000000000001, 0x41efffffffe00000,
        0x41efffffffffffff, 0x41f0000000000000, 0x47efffffe0000000, 0x47effffff0000000, 0x3690000000000000, 0x3690000000000001,
        0x3ff0000010000000, 0x3ff0000030000000, 0x7fefffffffffffff, 0x7ff0000000000000, 0xfff0000000000000, 0x7ff8000000000000,
        0x7ff0000000000001, 0xfff8123456789abc,
    };
    var random: u64 = 0xd17341b6092a7c85;
    for (simd_numeric_conversions) |op| {
        const module = try wasm.decode(a, try buildSimdNumericConversionFunc(a, op.sub, 1, false));
        var instance: interp.Instance = undefined;
        try interp.instantiate(&instance, a, testing.allocator, &module, .{});
        defer instance.deinit();
        instance.spasm_enabled = native;
        for (0..bits32.len) |base| {
            var input: [4]u32 = undefined;
            for (&input, 0..) |*lane, index| lane.* = bits32[(base + index) % bits32.len];
            try expectSimdNumericConversion(&instance, op, @bitCast(input), native);
        }
        for (0..bits64.len) |base| try expectSimdNumericConversion(&instance, op, @bitCast([2]u64{ bits64[base], bits64[(base + 1) % bits64.len] }), native);
        for (0..2048) |_| {
            var input: [2]u64 = undefined;
            for (&input) |*lane| {
                random ^= random << 13;
                random ^= random >> 7;
                random ^= random << 17;
                lane.* = random;
            }
            try expectSimdNumericConversion(&instance, op, @bitCast(input), native);
        }
    }
}

test "wasm spasm: SIMD numeric conversions preserve boundaries, NaNs and live values" {
    try testSimdNumericConversions(true);
}

test "wasm interpreter: SIMD numeric conversions satisfy an independent lane oracle" {
    try testSimdNumericConversions(false);
}

test "wasm spasm: SIMD numeric conversions skip dead code and fit dense reservations" {
    if (comptime !@import("spasm.zig").supported) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for (simd_numeric_conversions) |op| {
        for ([_]usize{ 1, 128, 1024 }) |count| {
            const dead = count == 1;
            const module = try wasm.decode(a, try buildSimdNumericConversionFunc(a, op.sub, count, dead));
            var instance: interp.Instance = undefined;
            try interp.instantiate(&instance, a, testing.allocator, &module, .{});
            defer instance.deinit();
            instance.spasm_enabled = true;
            const input: u128 = if (dead) ~simd_live_vector else 0;
            const result = try interp.invoke(&instance, testing.allocator, 0, &.{ 37, simd_live_vector, input });
            defer testing.allocator.free(result);
            try testing.expectEqualSlices(u128, &.{ 37, simd_live_vector, input }, result);
            try testing.expectEqual(@import("spasm.zig").RefusalStage.none, instance.spasm_last_refusal_stage);
            try testing.expectEqual(@as(u32, 0), instance.spasm_refusals);
            try testing.expectEqual(@as(u32, 1), instance.spasm_compiles);
            try testing.expectEqual(@as(u32, 1), instance.spasm_runs);
        }
    }
}

fn buildSimdPermutationFunc(a: std.mem.Allocator, sub: u32, selectors: [16]u8, dead: bool) ![]const u8 {
    var body: List = .empty;
    try body.appendSlice(a, &.{ 1, 32, 0x7f, 0x20, 0, 0x20, 1 });
    if (dead) try body.appendSlice(a, &.{ 0x02, 0x7b, 0x20, 2, 0x0c, 0 });
    try body.appendSlice(a, &.{ 0x20, 2, 0x20, 3, 0xfd });
    try uleb(a, &body, sub);
    if (sub == 13) try body.appendSlice(a, &selectors);
    if (dead) try body.append(a, 0x0b);
    try body.append(a, 0x0b);
    return buildFunc(a, &.{ 0x7e, 0x7b, 0x7b, 0x7b }, &.{ 0x7e, 0x7b, 0x7b }, body.items, "permute");
}

fn expectSimdPermutation(instance: *interp.Instance, sub: u32, selectors: [16]u8, left: [16]u8, right: [16]u8, native: bool) !void {
    var expected: [16]u8 = undefined;
    for (0..16) |lane| {
        const index = if (sub == 13) selectors[lane] else right[lane];
        expected[lane] = if (index < 16) left[index] else if (sub == 13) right[index - 16] else 0;
    }
    const before = instance.spasm_runs;
    const result = try interp.invoke(instance, testing.allocator, 0, &.{ 37, simd_live_vector, @bitCast(left), @bitCast(right) });
    defer testing.allocator.free(result);
    try testing.expectEqualSlices(u128, &.{ 37, simd_live_vector, @bitCast(expected) }, result);
    try testing.expectEqual(before + @intFromBool(native), instance.spasm_runs);
}

test "wasm spasm: SIMD permutation shuffle covers every source and destination byte" {
    if (comptime !@import("spasm.zig").supported) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for (0..32) |base| {
        for ([_]bool{ false, true }) |broadcast| {
            var selectors: [16]u8 = undefined;
            for (&selectors, 0..) |*index, lane| index.* = @intCast((base + (if (broadcast) @as(usize, 0) else 31 - lane)) % 32);
            const module = try wasm.decode(a, try buildSimdPermutationFunc(a, 13, selectors, false));
            var instance: interp.Instance = undefined;
            try interp.instantiate(&instance, a, testing.allocator, &module, .{});
            defer instance.deinit();
            instance.spasm_enabled = true;
            for (0..256) |seed| {
                var left: [16]u8 = undefined;
                var right: [16]u8 = undefined;
                for (0..16) |lane| {
                    left[lane] = @truncate(seed + lane * 17);
                    right[lane] = @truncate(seed + 113 + lane * 23);
                }
                try expectSimdPermutation(&instance, 13, selectors, left, right, true);
            }
            try testing.expectEqual(@as(u32, 1), instance.spasm_compiles);
        }
    }
}

test "wasm spasm: SIMD permutation swizzles exhaust byte values and indices" {
    if (comptime !@import("spasm.zig").supported) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_]u32{ 14, 256 }) |sub| {
        const module = try wasm.decode(a, try buildSimdPermutationFunc(a, sub, @splat(0), false));
        var instance: interp.Instance = undefined;
        try interp.instantiate(&instance, a, testing.allocator, &module, .{});
        defer instance.deinit();
        instance.spasm_enabled = true;
        for (0..256) |seed| {
            for (0..256) |base| {
                var left: [16]u8 = undefined;
                var right: [16]u8 = undefined;
                for (0..16) |lane| {
                    left[lane] = @truncate(seed + lane * 17);
                    right[lane] = @truncate(base + lane * 29);
                }
                try expectSimdPermutation(&instance, sub, @splat(0), left, right, true);
            }
        }
        try testing.expectEqual(@as(u32, 1), instance.spasm_compiles);
    }
}

test "wasm spasm: SIMD permutation dense swizzles fit the native code reservation" {
    if (comptime !@import("spasm.zig").supported) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_]usize{ 128, 1024 }) |repetitions| {
        for ([_]u32{ 14, 256 }) |sub| {
            var body: List = .empty;
            try body.appendSlice(a, &.{ 1, 32, 0x7f, 0x20, 0, 0x20, 1, 0x20, 2 });
            for (0..repetitions) |_| {
                try body.appendSlice(a, &.{ 0x20, 3, 0xfd });
                try uleb(a, &body, sub);
            }
            try body.append(a, 0x0b);
            const module = try wasm.decode(a, try buildFunc(a, &.{ 0x7e, 0x7b, 0x7b, 0x7b }, &.{ 0x7e, 0x7b, 0x7b }, body.items, "dense"));
            var instance: interp.Instance = undefined;
            try interp.instantiate(&instance, a, testing.allocator, &module, .{});
            defer instance.deinit();
            instance.spasm_enabled = true;
            const identity: u128 = 0x0f0e0d0c0b0a09080706050403020100;
            for ([_]u128{ identity, std.math.maxInt(u128) }, [_]u128{ simd_live_vector, 0 }) |indices, expected| {
                const before = instance.spasm_runs;
                const result = try interp.invoke(&instance, testing.allocator, 0, &.{ 37, ~simd_live_vector, simd_live_vector, indices });
                defer testing.allocator.free(result);
                try testing.expectEqualSlices(u128, &.{ 37, ~simd_live_vector, expected }, result);
                try testing.expectEqual(@import("spasm.zig").RefusalStage.none, instance.spasm_last_refusal_stage);
                try testing.expectEqual(@as(u32, 0), instance.spasm_refusals);
                try testing.expectEqual(before + 1, instance.spasm_runs);
            }
            try testing.expectEqual(@as(u32, 1), instance.spasm_compiles);
        }
    }
}

test "wasm interpreter: SIMD permutation relaxed swizzle keeps deterministic invalid lanes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_]u32{ 14, 256 }) |sub| {
        const module = try wasm.decode(a, try buildSimdPermutationFunc(a, sub, @splat(0), false));
        var instance: interp.Instance = undefined;
        try interp.instantiate(&instance, a, testing.allocator, &module, .{});
        defer instance.deinit();
        instance.spasm_enabled = false;
        for (0..256) |base| {
            var indices: [16]u8 = undefined;
            for (&indices, 0..) |*index, lane| index.* = @truncate(base + lane * 29);
            try expectSimdPermutation(&instance, sub, @splat(0), @bitCast(simd_live_vector), indices, false);
        }
    }
}

test "wasm spasm: SIMD permutation skips shuffle immediates and unreachable swizzles" {
    if (comptime !@import("spasm.zig").supported) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Includes control-opcode bytes: none may be interpreted as dead code.
    const selectors = [16]u8{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 30, 31 };
    for ([_]u32{ 13, 14, 256 }) |sub| {
        const module = try wasm.decode(a, try buildSimdPermutationFunc(a, sub, selectors, true));
        var instance: interp.Instance = undefined;
        try interp.instantiate(&instance, a, testing.allocator, &module, .{});
        defer instance.deinit();
        instance.spasm_enabled = true;
        const result = try interp.invoke(&instance, testing.allocator, 0, &.{ 37, simd_live_vector, ~simd_live_vector, 0 });
        defer testing.allocator.free(result);
        try testing.expectEqualSlices(u128, &.{ 37, simd_live_vector, ~simd_live_vector }, result);
        try testing.expectEqual(@as(u32, 1), instance.spasm_runs);
    }
}

const SimdFloatSelection = struct {
    sub: u32,
    double_precision: bool,
    op: enum { ceil, floor, trunc, nearest, pmin, pmax },

    fn isUnary(self: SimdFloatSelection) bool {
        return self.op != .pmin and self.op != .pmax;
    }
};
const simd_float_selection_cases = [_]SimdFloatSelection{
    .{ .sub = 103, .double_precision = false, .op = .ceil },
    .{ .sub = 104, .double_precision = false, .op = .floor },
    .{ .sub = 105, .double_precision = false, .op = .trunc },
    .{ .sub = 106, .double_precision = false, .op = .nearest },
    .{ .sub = 116, .double_precision = true, .op = .ceil },
    .{ .sub = 117, .double_precision = true, .op = .floor },
    .{ .sub = 122, .double_precision = true, .op = .trunc },
    .{ .sub = 148, .double_precision = true, .op = .nearest },
    .{ .sub = 234, .double_precision = false, .op = .pmin },
    .{ .sub = 235, .double_precision = false, .op = .pmax },
    .{ .sub = 246, .double_precision = true, .op = .pmin },
    .{ .sub = 247, .double_precision = true, .op = .pmax },
};

fn expectSimdFloatSelectionLane(comptime U: type, op: SimdFloatSelection, left: U, right: U, actual: U) !void {
    const sign: U = @as(U, 1) << (@bitSizeOf(U) - 1);
    const fraction_bits = if (U == u32) 23 else 52;
    const bias = if (U == u32) 127 else 1023;
    const exponent: U = if (U == u32) 0x7f80_0000 else 0x7ff0_0000_0000_0000;
    const quiet: U = @as(U, 1) << (fraction_bits - 1);
    const magnitude = left & ~sign;
    if (!op.isUnary()) {
        const F = if (U == u32) f32 else f64;
        const lhs: F = @bitCast(left);
        const rhs: F = @bitCast(right);
        const choose_right = magnitude <= exponent and (right & ~sign) <= exponent and
            (if (op.op == .pmin) rhs < lhs else lhs < rhs);
        // Core fpmin/fpmax select input bits, even for signaling NaNs.
        try testing.expectEqual(if (choose_right) right else left, actual);
        return;
    }
    if (magnitude > exponent) {
        if (magnitude == exponent | quiet)
            try testing.expectEqual(exponent | quiet, actual & ~sign)
        else
            try testing.expectEqual(exponent | quiet, actual & (exponent | quiet));
        return;
    }
    // Independent integer-bit oracle, not the runtime's floating helpers.
    const power = @as(i32, @intCast(magnitude >> fraction_bits)) - bias;
    if (power >= fraction_bits or magnitude == 0) {
        try testing.expectEqual(left, actual);
        return;
    }
    const negative = left & sign != 0;
    if (power < 0) {
        const round_to_one = switch (op.op) {
            .ceil => !negative,
            .floor => negative,
            .trunc => false,
            .nearest => magnitude > @as(U, bias - 1) << fraction_bits,
            else => unreachable,
        };
        try testing.expectEqual((left & sign) | (if (round_to_one) @as(U, bias) << fraction_bits else 0), actual);
        return;
    }
    const count: std.math.Log2Int(U) = @intCast(fraction_bits - power);
    const unit = @as(U, 1) << count;
    const discarded = left & (unit - 1);
    const truncated = left & ~(unit - 1);
    const increment = switch (op.op) {
        .ceil => !negative and discarded != 0,
        .floor => negative and discarded != 0,
        .trunc => false,
        .nearest => discarded > unit / 2 or (discarded == unit / 2 and truncated & unit != 0),
        else => unreachable,
    };
    try testing.expectEqual(truncated + (if (increment) unit else 0), actual);
}

fn expectSimdFloatSelection(comptime U: type, instance: *interp.Instance, op: SimdFloatSelection, left: u128, right: u128, native: bool) !void {
    const before = instance.spasm_runs;
    const result = try interp.invoke(instance, testing.allocator, 0, &.{ 37, simd_live_vector, left, right });
    defer testing.allocator.free(result);
    try testing.expectEqual(@as(usize, 3), result.len);
    try testing.expectEqual(@as(u128, 37), result[0]);
    try testing.expectEqual(simd_live_vector, result[1]);
    for (0..128 / @bitSizeOf(U)) |lane| {
        const shift: u7 = @intCast(lane * @bitSizeOf(U));
        try expectSimdFloatSelectionLane(U, op, @truncate(left >> shift), @truncate(right >> shift), @truncate(result[2] >> shift));
    }
    try testing.expectEqual(before + @intFromBool(native), instance.spasm_runs);
}

fn testSimdFloatSelection(comptime U: type, native: bool) !void {
    if (native and !@import("spasm.zig").supported) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const sign: U = @as(U, 1) << (@bitSizeOf(U) - 1);
    const fraction_bits = if (U == u32) 23 else 52;
    const bias = if (U == u32) 127 else 1023;
    const exponent: U = if (U == u32) 0x7f80_0000 else 0x7ff0_0000_0000_0000;
    const quiet: U = @as(U, 1) << (fraction_bits - 1);
    const one: U = @as(U, bias) << fraction_bits;
    const half: U = @as(U, bias - 1) << fraction_bits;
    const values = [_]U{
        0,                               sign,                 1,                   sign | 1,            quiet * 2 - 1,           sign | (quiet * 2 - 1),
        quiet * 2,                       sign | (quiet * 2),   half - 1,            half,                half + 1,                sign | (half - 1),
        sign | half,                     sign | (half + 1),    one - 1,             one,                 one + 1,                 sign | one,
        one + quiet,                     sign | (one + quiet), one + quiet * 2,     one + quiet * 5 / 2, one + quiet * 7 / 2,     exponent - 1,
        sign | (exponent - 1),           exponent,             sign | exponent,     exponent | quiet,    sign | exponent | quiet, exponent | quiet | 1,
        sign | exponent | quiet | 0x123, exponent | 1,         sign | exponent | 1,
    };
    for (simd_float_selection_cases) |op| {
        if (op.double_precision != (U == u64)) continue;
        const module = try wasm.decode(a, try buildSimdFloatFunc(a, op.sub, op.isUnary(), false));
        var instance: interp.Instance = undefined;
        try interp.instantiate(&instance, a, testing.allocator, &module, .{});
        defer instance.deinit();
        instance.spasm_enabled = native;
        for (0..values.len) |li| {
            for (0..if (op.isUnary()) @as(usize, 1) else values.len) |ri| {
                var left: u128 = 0;
                var right: u128 = 0;
                for (0..128 / @bitSizeOf(U)) |lane| {
                    const shift: u7 = @intCast(lane * @bitSizeOf(U));
                    left |= @as(u128, values[(li + lane * 3) % values.len]) << shift;
                    right |= @as(u128, values[(ri + lane * 5) % values.len]) << shift;
                }
                try expectSimdFloatSelection(U, &instance, op, left, right, native);
            }
        }
        if (op.isUnary()) {
            for (0..fraction_bits) |power| {
                const unit = @as(U, 1) << @as(std.math.Log2Int(U), @intCast(fraction_bits - power));
                for ([_]U{ 0, unit }) |parity| {
                    const tie = (@as(U, @intCast(bias + power)) << fraction_bits) + parity + unit / 2;
                    for ([_]U{ tie - 1, tie, tie + 1 }) |bits| {
                        var vector: u128 = 0;
                        for (0..128 / @bitSizeOf(U)) |lane| {
                            vector |= @as(u128, bits | (if (lane % 2 != 0) sign else 0)) << @as(u7, @intCast(lane * @bitSizeOf(U)));
                        }
                        try expectSimdFloatSelection(U, &instance, op, vector, 0, native);
                    }
                }
            }
        }
        try testing.expectEqual(@as(u32, @intFromBool(native)), instance.spasm_compiles);
    }
}

test "wasm spasm: SIMD float selection f32 preserves ties and NaN bits" {
    try testSimdFloatSelection(u32, true);
}

test "wasm spasm: SIMD float selection f64 preserves ties and NaN bits" {
    try testSimdFloatSelection(u64, true);
}

test "wasm interpreter: SIMD float selection preserves ties and NaN bits" {
    try testSimdFloatSelection(u32, false);
    try testSimdFloatSelection(u64, false);
}

test "wasm: SIMD float selection shared scalar rounds quiet signaling NaNs" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for (simd_float_selection_cases) |op| {
        if (!op.isUnary()) continue;
        const scalar: u8 = (if (op.double_precision) @as(u8, 0x9b) else 0x8d) + @intFromEnum(op.op);
        const ty: u8 = if (op.double_precision) 0x7c else 0x7d;
        const module = try wasm.decode(a, try buildFunc(a, &.{ty}, &.{ty}, &.{ 0, 0x20, 0, scalar, 0x0b }, "round"));
        for ([_]bool{ false, true }) |native| {
            if (native and !@import("spasm.zig").supported) continue;
            var instance: interp.Instance = undefined;
            try interp.instantiate(&instance, a, testing.allocator, &module, .{});
            defer instance.deinit();
            instance.spasm_enabled = native;
            const bits: u128 = if (op.double_precision) 0x7ff0_0000_0000_0001 else 0x7f80_0001;
            const result = try interp.invoke(&instance, testing.allocator, 0, &.{bits});
            defer testing.allocator.free(result);
            if (op.double_precision)
                try expectSimdFloatSelectionLane(u64, op, @truncate(bits), 0, @truncate(result[0]))
            else
                try expectSimdFloatSelectionLane(u32, op, @truncate(bits), 0, @truncate(result[0]));
            try testing.expectEqual(@as(u32, @intFromBool(native)), instance.spasm_runs);
        }
    }
}

test "wasm spasm: SIMD float selection skips unreachable code" {
    if (comptime !@import("spasm.zig").supported) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for (simd_float_selection_cases) |op| {
        const module = try wasm.decode(a, try buildSimdFloatFunc(a, op.sub, op.isUnary(), true));
        var instance: interp.Instance = undefined;
        try interp.instantiate(&instance, a, testing.allocator, &module, .{});
        defer instance.deinit();
        instance.spasm_enabled = true;
        const result = try interp.invoke(&instance, testing.allocator, 0, &.{ 37, simd_live_vector, ~simd_live_vector, 0 });
        defer testing.allocator.free(result);
        try testing.expectEqualSlices(u128, &.{ 37, simd_live_vector, ~simd_live_vector }, result);
        try testing.expectEqual(@as(u32, 1), instance.spasm_runs);
    }
}

const SimdIntegerCase = struct { sub: u32, bits: usize, op: enum { abs, neg, average, popcnt, add, sub, mul, add_sat_s, add_sat_u, sub_sat_s, sub_sat_u } };
const simd_integer_cases = [_]SimdIntegerCase{
    .{ .sub = 96, .bits = 8, .op = .abs },
    .{ .sub = 97, .bits = 8, .op = .neg },
    .{ .sub = 128, .bits = 16, .op = .abs },
    .{ .sub = 129, .bits = 16, .op = .neg },
    .{ .sub = 160, .bits = 32, .op = .abs },
    .{ .sub = 161, .bits = 32, .op = .neg },
    .{ .sub = 192, .bits = 64, .op = .abs },
    .{ .sub = 193, .bits = 64, .op = .neg },
    .{ .sub = 123, .bits = 8, .op = .average },
    .{ .sub = 155, .bits = 16, .op = .average },
    .{ .sub = 98, .bits = 8, .op = .popcnt },
    .{ .sub = 110, .bits = 8, .op = .add },
    .{ .sub = 113, .bits = 8, .op = .sub },
    .{ .sub = 142, .bits = 16, .op = .add },
    .{ .sub = 145, .bits = 16, .op = .sub },
    .{ .sub = 149, .bits = 16, .op = .mul },
    .{ .sub = 174, .bits = 32, .op = .add },
    .{ .sub = 177, .bits = 32, .op = .sub },
    .{ .sub = 181, .bits = 32, .op = .mul },
    .{ .sub = 206, .bits = 64, .op = .add },
    .{ .sub = 209, .bits = 64, .op = .sub },
    .{ .sub = 213, .bits = 64, .op = .mul },
    .{ .sub = 111, .bits = 8, .op = .add_sat_s },
    .{ .sub = 112, .bits = 8, .op = .add_sat_u },
    .{ .sub = 114, .bits = 8, .op = .sub_sat_s },
    .{ .sub = 115, .bits = 8, .op = .sub_sat_u },
    .{ .sub = 143, .bits = 16, .op = .add_sat_s },
    .{ .sub = 144, .bits = 16, .op = .add_sat_u },
    .{ .sub = 146, .bits = 16, .op = .sub_sat_s },
    .{ .sub = 147, .bits = 16, .op = .sub_sat_u },
};

fn simdIntegerIsBinary(op: SimdIntegerCase) bool {
    return switch (op.op) {
        .abs, .neg, .popcnt => false,
        else => true,
    };
}

fn buildSimdIntegerFunc(a: std.mem.Allocator, op: SimdIntegerCase) ![]const u8 {
    var body: List = .empty;
    try body.appendSlice(a, &.{ 1, 32, 0x7f, 0x20, 0, 0x20, 1, 0x20, 2 });
    if (simdIntegerIsBinary(op)) try body.appendSlice(a, &.{ 0x20, 3 });
    try body.append(a, 0xfd);
    try uleb(a, &body, op.sub);
    try body.append(a, 0x0b);
    const params: []const u8 = if (simdIntegerIsBinary(op)) &.{ 0x7e, 0x7b, 0x7b, 0x7b } else &.{ 0x7e, 0x7b, 0x7b };
    return buildFunc(a, params, &.{ 0x7e, 0x7b, 0x7b }, body.items, "integer");
}

fn expectSimdInteger(instance: *interp.Instance, op: SimdIntegerCase, left: u128, right: u128) !void {
    const modulus = @as(u128, 1) << @as(u7, @intCast(op.bits));
    const mask = modulus - 1;
    var expected: u128 = 0;
    for (0..128 / op.bits) |lane| {
        const shift: u7 = @intCast(lane * op.bits);
        const lhs = (left >> shift) & mask;
        const rhs = (right >> shift) & mask;
        const value = switch (op.op) {
            .abs => if (lhs >= modulus / 2) (modulus - lhs) & mask else lhs,
            .neg => (modulus - lhs) & mask,
            .average => (lhs + rhs + 1) / 2,
            .popcnt => @popCount(lhs),
            .add => (lhs + rhs) & mask,
            .sub => (lhs + modulus - rhs) & mask,
            .mul => (lhs * rhs) & mask,
            .add_sat_u => @min(lhs + rhs, mask),
            .sub_sat_u => lhs -| rhs,
            .add_sat_s, .sub_sat_s => blk: {
                const mod: i128 = @intCast(modulus);
                const l = @as(i128, @intCast(lhs)) - (if (lhs >= modulus / 2) mod else 0);
                const r = @as(i128, @intCast(rhs)) - (if (rhs >= modulus / 2) mod else 0);
                const value = if (op.op == .add_sat_s) l + r else l - r;
                const saturated = std.math.clamp(value, -@divExact(mod, 2), @divExact(mod, 2) - 1);
                break :blk @as(u128, @bitCast(saturated)) & mask;
            },
        };
        expected |= value << shift;
    }
    const args = [_]u128{ 37, simd_live_vector, left, right };
    const before = instance.spasm_runs;
    const result = try interp.invoke(instance, testing.allocator, 0, args[0..if (simdIntegerIsBinary(op)) @as(usize, 4) else 3]);
    defer testing.allocator.free(result);
    try testing.expectEqualSlices(u128, &.{ 37, simd_live_vector, expected }, result);
    try testing.expectEqual(before + 1, instance.spasm_runs);
}

test "wasm spasm: SIMD integer operations preserve boundaries and live lanes" {
    if (comptime !@import("spasm.zig").supported) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for (simd_integer_cases) |op| {
        const module = try wasm.decode(a, try buildSimdIntegerFunc(a, op));
        var instance: interp.Instance = undefined;
        try interp.instantiate(&instance, a, testing.allocator, &module, .{});
        defer instance.deinit();
        instance.spasm_enabled = true;
        const sign = @as(u128, 1) << @as(u7, @intCast(op.bits - 1));
        const mask = sign * 2 - 1;
        const values = [_]u128{ 0, 1, 2, 3, sign - 1, sign, sign + 1, mask - 1, mask, 0x5555_5555_5555_5555 & mask, 0xaaaa_aaaa_aaaa_aaaa & mask, 0x0000_0000_8000_0000 & mask, 0xffff_ffff_0000_0000 & mask };
        for (0..values.len) |li| {
            for (0..values.len) |ri| {
                var left: u128 = 0;
                var right: u128 = 0;
                for (0..128 / op.bits) |lane| {
                    const shift: u7 = @intCast(lane * op.bits);
                    left |= values[(li + lane * 3) % values.len] << shift;
                    right |= values[(ri + lane) % values.len] << shift;
                }
                try expectSimdInteger(&instance, op, left, right);
            }
        }
        for (0..128) |bit| {
            const single = @as(u128, 1) << @as(u7, @intCast(bit));
            try expectSimdInteger(&instance, op, single, ~single);
            try expectSimdInteger(&instance, op, ~single, single);
        }
        try testing.expectEqual(@as(u32, 1), instance.spasm_compiles);
    }
}

test "wasm spasm: SIMD integer unary exhausts byte and halfword inputs" {
    if (comptime !@import("spasm.zig").supported) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for (simd_integer_cases[0..4]) |op| {
        const module = try wasm.decode(a, try buildSimdIntegerFunc(a, op));
        var instance: interp.Instance = undefined;
        try interp.instantiate(&instance, a, testing.allocator, &module, .{});
        defer instance.deinit();
        instance.spasm_enabled = true;
        const lanes = 128 / op.bits;
        const count = @as(usize, 1) << @as(u6, @intCast(op.bits));
        for (0..count / lanes) |batch| {
            var input: u128 = 0;
            for (0..lanes) |lane| input |= @as(u128, batch * lanes + lane) << @as(u7, @intCast(lane * op.bits));
            try expectSimdInteger(&instance, op, input, 0);
        }
        try testing.expectEqual(@as(u32, 1), instance.spasm_compiles);
    }
}

test "wasm spasm: SIMD integer binary operations exhaust byte pairs" {
    if (comptime !@import("spasm.zig").supported) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for (simd_integer_cases) |op| {
        if (op.bits != 8 or !simdIntegerIsBinary(op)) continue;
        const module = try wasm.decode(a, try buildSimdIntegerFunc(a, op));
        var instance: interp.Instance = undefined;
        try interp.instantiate(&instance, a, testing.allocator, &module, .{});
        defer instance.deinit();
        instance.spasm_enabled = true;
        for (0..256) |lhs| {
            for (0..16) |batch| {
                var left: [16]u8 = undefined;
                var right: [16]u8 = undefined;
                for (0..16) |lane| {
                    left[lane] = @truncate(lhs + 17 * lane);
                    right[lane] = @intCast(batch * 16 + lane);
                }
                try expectSimdInteger(&instance, op, std.mem.readInt(u128, &left, .little), std.mem.readInt(u128, &right, .little));
            }
        }
        try testing.expectEqual(@as(u32, 1), instance.spasm_compiles);
        try testing.expectEqual(@as(u32, 4096), instance.spasm_runs);
    }
}

test "wasm spasm: SIMD integer operations skip unreachable code" {
    if (comptime !@import("spasm.zig").supported) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for (simd_integer_cases) |op| {
        var body: List = .empty;
        try body.appendSlice(a, &.{ 0, 0x02, 0x7b, 0x20, 0, 0x0c, 0, 0x20, 0 });
        if (simdIntegerIsBinary(op)) try body.appendSlice(a, &.{ 0x20, 0 });
        try body.append(a, 0xfd);
        try uleb(a, &body, op.sub);
        try body.appendSlice(a, &.{ 0x0b, 0x0b });
        const module = try wasm.decode(a, try buildFunc(a, &.{0x7b}, &.{0x7b}, body.items, "dead"));
        var instance: interp.Instance = undefined;
        try interp.instantiate(&instance, a, testing.allocator, &module, .{});
        defer instance.deinit();
        instance.spasm_enabled = true;
        const result = try interp.invoke(&instance, testing.allocator, 0, &.{simd_live_vector});
        defer testing.allocator.free(result);
        try testing.expectEqualSlices(u128, &.{simd_live_vector}, result);
        try testing.expectEqual(@as(u32, 1), instance.spasm_compiles);
        try testing.expectEqual(@as(u32, 1), instance.spasm_runs);
    }
}

test "wasm spasm: SIMD integer popcount exhausts bytes" {
    if (comptime !@import("spasm.zig").supported) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const op: SimdIntegerCase = .{ .sub = 98, .bits = 8, .op = .popcnt };
    const module = try wasm.decode(a, try buildSimdIntegerFunc(a, op));
    var instance: interp.Instance = undefined;
    try interp.instantiate(&instance, a, testing.allocator, &module, .{});
    defer instance.deinit();
    instance.spasm_enabled = true;
    for (0..256) |base| {
        var value: u128 = 0;
        for (0..16) |lane| value |= @as(u128, @as(u8, @truncate(base + lane * 17))) << @as(u7, @intCast(lane * 8));
        try expectSimdInteger(&instance, op, value, 0);
    }
}

const simd_shift_ops = [_]u32{ 107, 108, 109, 139, 140, 141, 171, 172, 173, 203, 204, 205 };

fn buildSimdShiftFunc(a: std.mem.Allocator, sub: u32, dead: bool) ![]const u8 {
    var body: List = .empty;
    try body.appendSlice(a, &.{ 1, 32, 0x7f, 0x20, 0, 0x20, 1 });
    if (dead) try body.appendSlice(a, &.{ 0x02, 0x7b, 0x20, 2, 0x0c, 0 });
    try body.appendSlice(a, &.{ 0x20, 2, 0x20, 3, 0xfd });
    try uleb(a, &body, sub);
    if (dead) try body.append(a, 0x0b);
    try body.append(a, 0x0b);
    return buildFunc(a, &.{ 0x7e, 0x7b, 0x7b, 0x7f }, &.{ 0x7e, 0x7b, 0x7b }, body.items, "shift");
}

fn expectedSimdShift(sub: u32, value: u128, count: u32) u128 {
    const bits: u7 = @as(u7, 8) << @as(u2, @intCast((sub - 107) / 32));
    const amount: u7 = @intCast(count % @as(u32, bits));
    const modulus = @as(u128, 1) << bits;
    const mask = modulus - 1;
    var expected: u128 = 0;
    for (0..128 / @as(usize, bits)) |lane| {
        const shift: u7 = @intCast(lane * bits);
        const input = (value >> shift) & mask;
        const output = switch ((sub - 107) % 32) {
            0 => (input << amount) & mask,
            1 => blk: {
                const signed = @as(i128, @intCast(input)) - (if (input >= modulus / 2) @as(i128, @intCast(modulus)) else 0);
                break :blk @as(u128, @bitCast(signed >> amount)) & mask;
            },
            2 => input >> amount,
            else => unreachable,
        };
        expected |= output << shift;
    }
    return expected;
}

test "wasm spasm: SIMD integer shifts mask counts and preserve lane boundaries" {
    if (comptime !@import("spasm.zig").supported) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for (simd_shift_ops) |sub| {
        const module = try wasm.decode(a, try buildSimdShiftFunc(a, sub, false));
        var instance: interp.Instance = undefined;
        try interp.instantiate(&instance, a, testing.allocator, &module, .{});
        defer instance.deinit();
        instance.spasm_enabled = true;
        for (0..132) |ci| {
            const count: u32 = switch (ci) {
                128 => 0xffff_ffff,
                129 => 0x8000_0000,
                130 => 0x8000_0021,
                131 => 0xffff_ffc0,
                else => @intCast(ci),
            };
            for (0..132) |vi| {
                const value: u128 = switch (vi) {
                    128 => 0,
                    129 => std.math.maxInt(u128),
                    130 => simd_live_vector,
                    131 => ~simd_live_vector,
                    else => @as(u128, 1) << @as(u7, @intCast(vi)),
                };
                const before = instance.spasm_runs;
                const result = try interp.invoke(&instance, testing.allocator, 0, &.{ 37, simd_live_vector, value, count });
                defer testing.allocator.free(result);
                try testing.expectEqualSlices(u128, &.{ 37, simd_live_vector, expectedSimdShift(sub, value, count) }, result);
                try testing.expectEqual(before + 1, instance.spasm_runs);
            }
        }
        try testing.expectEqual(@as(u32, 1), instance.spasm_compiles);
    }
}

test "wasm spasm: SIMD integer shifts skip unreachable code" {
    if (comptime !@import("spasm.zig").supported) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for (simd_shift_ops) |sub| {
        const module = try wasm.decode(a, try buildSimdShiftFunc(a, sub, true));
        var instance: interp.Instance = undefined;
        try interp.instantiate(&instance, a, testing.allocator, &module, .{});
        defer instance.deinit();
        instance.spasm_enabled = true;
        const result = try interp.invoke(&instance, testing.allocator, 0, &.{ 37, simd_live_vector, ~simd_live_vector, 0xffff_ffff });
        defer testing.allocator.free(result);
        try testing.expectEqualSlices(u128, &.{ 37, simd_live_vector, ~simd_live_vector }, result);
        try testing.expectEqual(@as(u32, 1), instance.spasm_runs);
    }
}

const simd_comparison_ops = blk: {
    var ops: [48]u32 = undefined;
    for (0..42) |i| ops[i] = @intCast(35 + i);
    for (0..6) |i| ops[42 + i] = @intCast(214 + i);
    break :blk ops;
};

fn expectedSimdComparison(sub: u32, left: u128, right: u128) u128 {
    const floating = sub >= 65 and sub <= 76;
    const bits: u7 = if (sub >= 214) 64 else if (sub < 45) 8 else if (sub < 55) 16 else if (sub < 71) 32 else 64;
    const index = if (sub >= 214) sub - 214 else if (floating) (sub - 65) % 6 else (sub - 35) % 10;
    const mask = (@as(u128, 1) << bits) - 1;
    const sign = @as(u128, 1) << (bits - 1);
    const signed = sub >= 214 or (!floating and index >= 2 and index % 2 == 0);
    const relation = if (floating or sub >= 214) index else if (index < 2) index else 2 + (index - 2) / 2;
    var expected: u128 = 0;
    for (0..128 / @as(usize, bits)) |lane| {
        const shift: u7 = @intCast(lane * bits);
        const l = (left >> shift) & mask;
        const r = (right >> shift) & mask;
        var equal = l == r;
        var less = (l ^ (if (signed) sign else 0)) < (r ^ (if (signed) sign else 0));
        var greater = (l ^ (if (signed) sign else 0)) > (r ^ (if (signed) sign else 0));
        if (floating) {
            const infinity: u128 = if (bits == 32) 0x7f800000 else 0x7ff0000000000000;
            const unordered = l & (sign - 1) > infinity or r & (sign - 1) > infinity;
            const both_zero = (l | r) & (sign - 1) == 0;
            equal = !unordered and (l == r or both_zero);
            const lk = if (l & sign != 0) l ^ mask else l ^ sign;
            const rk = if (r & sign != 0) r ^ mask else r ^ sign;
            less = !unordered and !both_zero and lk < rk;
            greater = !unordered and !both_zero and lk > rk;
        }
        const selected = switch (relation) {
            0 => equal,
            1 => !equal,
            2 => less,
            3 => greater,
            4 => less or equal,
            5 => greater or equal,
            else => unreachable,
        };
        if (selected) expected |= mask << shift;
    }
    return expected;
}

fn expectSimdComparison(instance: *interp.Instance, sub: u32, left: u128, right: u128) !void {
    const before = instance.spasm_runs;
    const result = try interp.invoke(instance, testing.allocator, 0, &.{ 37, simd_live_vector, left, right });
    defer testing.allocator.free(result);
    try testing.expectEqualSlices(u128, &.{ 37, simd_live_vector, expectedSimdComparison(sub, left, right) }, result);
    try testing.expectEqual(before + 1, instance.spasm_runs);
}

test "wasm spasm: SIMD comparisons cover boundaries NaNs and mixed live lanes" {
    if (comptime !@import("spasm.zig").supported) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for (simd_comparison_ops) |sub| {
        const module = try wasm.decode(a, try buildSimdBinaryFunc(a, sub));
        var instance: interp.Instance = undefined;
        try interp.instantiate(&instance, a, testing.allocator, &module, .{});
        defer instance.deinit();
        instance.spasm_enabled = true;
        const bits: u7 = if (sub >= 214) 64 else if (sub < 45) 8 else if (sub < 55) 16 else if (sub < 71) 32 else 64;
        const mask = (@as(u128, 1) << bits) - 1;
        const sign = @as(u128, 1) << (bits - 1);
        const infinity: u128 = if (bits == 32) 0x7f800000 else 0x7ff0000000000000;
        const quiet: u128 = if (bits == 32) 0x400000 else 0x8000000000000;
        const patterns = [_]u128{ 0, 1, mask, sign, sign - 1, sign + 1, sign - 2, 0xffffffff, 0x100000000, 0x7fffffff, infinity, infinity | sign, infinity | 1, infinity | quiet, infinity | quiet | sign | 42, infinity - 1, 0x3f800000, 0x3ff0000000000000 };
        for (0..patterns.len) |l| {
            for (0..patterns.len) |r| {
                var left: u128 = 0;
                var right: u128 = 0;
                for (0..128 / @as(usize, bits)) |lane| {
                    const shift: u7 = @intCast(lane * bits);
                    left |= (patterns[(l + lane) % patterns.len] & mask) << shift;
                    right |= (patterns[(r + lane * 3) % patterns.len] & mask) << shift;
                }
                try expectSimdComparison(&instance, sub, left, right);
                try expectSimdComparison(&instance, sub, right, left);
                try expectSimdComparison(&instance, sub, left, left);
            }
        }
        try testing.expectEqual(@as(u32, 1), instance.spasm_compiles);
    }
}

test "wasm spasm: SIMD comparisons exhaust all byte pairs" {
    if (comptime !@import("spasm.zig").supported) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for (simd_comparison_ops[0..10]) |sub| {
        const module = try wasm.decode(a, try buildSimdBinaryFunc(a, sub));
        var instance: interp.Instance = undefined;
        try interp.instantiate(&instance, a, testing.allocator, &module, .{});
        defer instance.deinit();
        instance.spasm_enabled = true;
        for (0..256) |l| {
            for (0..16) |group| {
                var left: u128 = 0;
                var right: u128 = 0;
                for (0..16) |lane| {
                    left |= @as(u128, l) << @as(u7, @intCast(lane * 8));
                    right |= @as(u128, group * 16 + lane) << @as(u7, @intCast(lane * 8));
                }
                try expectSimdComparison(&instance, sub, left, right);
            }
        }
    }
}

test "wasm spasm: SIMD comparisons skip unreachable code" {
    if (comptime !@import("spasm.zig").supported) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for (simd_comparison_ops) |sub| {
        var body: List = .empty;
        try body.appendSlice(a, &.{ 0, 0x02, 0x7b, 0x20, 0, 0x0c, 0, 0x20, 0, 0x20, 0, 0xfd });
        try uleb(a, &body, sub);
        try body.appendSlice(a, &.{ 0x0b, 0x0b });
        const module = try wasm.decode(a, try buildFunc(a, &.{0x7b}, &.{0x7b}, body.items, "dead"));
        var instance: interp.Instance = undefined;
        try interp.instantiate(&instance, a, testing.allocator, &module, .{});
        defer instance.deinit();
        instance.spasm_enabled = true;
        const result = try interp.invoke(&instance, testing.allocator, 0, &.{simd_live_vector});
        defer testing.allocator.free(result);
        try testing.expectEqualSlices(u128, &.{simd_live_vector}, result);
        try testing.expectEqual(@as(u32, 1), instance.spasm_runs);
    }
}

const SimdMinMaxCase = struct { sub: u32, bits: usize, signed: bool, maximum: bool };
const simd_minmax_cases = [_]SimdMinMaxCase{
    .{ .sub = 118, .bits = 8, .signed = true, .maximum = false },
    .{ .sub = 119, .bits = 8, .signed = false, .maximum = false },
    .{ .sub = 120, .bits = 8, .signed = true, .maximum = true },
    .{ .sub = 121, .bits = 8, .signed = false, .maximum = true },
    .{ .sub = 150, .bits = 16, .signed = true, .maximum = false },
    .{ .sub = 151, .bits = 16, .signed = false, .maximum = false },
    .{ .sub = 152, .bits = 16, .signed = true, .maximum = true },
    .{ .sub = 153, .bits = 16, .signed = false, .maximum = true },
    .{ .sub = 182, .bits = 32, .signed = true, .maximum = false },
    .{ .sub = 183, .bits = 32, .signed = false, .maximum = false },
    .{ .sub = 184, .bits = 32, .signed = true, .maximum = true },
    .{ .sub = 185, .bits = 32, .signed = false, .maximum = true },
};

fn buildSimdBinaryFunc(a: std.mem.Allocator, sub: u32) ![]const u8 {
    var body: List = .empty;
    try body.appendSlice(a, &.{ 1, 32, 0x7f, 0x20, 0, 0x20, 1, 0x20, 2, 0x20, 3, 0xfd });
    try uleb(a, &body, sub);
    try body.append(a, 0x0b);
    return buildFunc(a, &.{ 0x7e, 0x7b, 0x7b, 0x7b }, &.{ 0x7e, 0x7b, 0x7b }, body.items, "binary");
}

fn expectSimdMinMax(instance: *interp.Instance, op: SimdMinMaxCase, left: u128, right: u128) !void {
    const modulus = @as(i64, 1) << @as(u6, @intCast(op.bits));
    const mask: u128 = @intCast(modulus - 1);
    var expected: u128 = 0;
    for (0..128 / op.bits) |lane| {
        const shift: u7 = @intCast(lane * op.bits);
        const lhs = (left >> shift) & mask;
        const rhs = (right >> shift) & mask;
        var l: i64 = @intCast(lhs);
        var r: i64 = @intCast(rhs);
        if (op.signed) {
            if (l >= @divExact(modulus, 2)) l -= modulus;
            if (r >= @divExact(modulus, 2)) r -= modulus;
        }
        const choose_left = if (op.maximum) l > r else l < r;
        expected |= (if (choose_left) lhs else rhs) << shift;
    }
    const before = instance.spasm_runs;
    const result = try interp.invoke(instance, testing.allocator, 0, &.{ 37, simd_live_vector, left, right });
    defer testing.allocator.free(result);
    try testing.expectEqualSlices(u128, &.{ 37, simd_live_vector, expected }, result);
    try testing.expectEqual(before + 1, instance.spasm_runs);
}

test "wasm spasm: SIMD integer minmax handles boundaries and mixed live lanes" {
    if (comptime !@import("spasm.zig").supported) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for (simd_minmax_cases) |op| {
        const module = try wasm.decode(a, try buildSimdBinaryFunc(a, op.sub));
        var instance: interp.Instance = undefined;
        try interp.instantiate(&instance, a, testing.allocator, &module, .{});
        defer instance.deinit();
        instance.spasm_enabled = true;
        const sign = @as(u128, 1) << @as(u7, @intCast(op.bits - 1));
        const mask = sign * 2 - 1;
        const values = [_]u128{ 0, 1, 2, sign - 1, sign, sign + 1, mask - 1, mask, 0x5555_5555 & mask, 0xaaaa_aaaa & mask };
        for (0..values.len) |li| {
            for (0..values.len) |ri| {
                var left: u128 = 0;
                var right: u128 = 0;
                for (0..128 / op.bits) |lane| {
                    const shift: u7 = @intCast(lane * op.bits);
                    left |= values[(li + lane) % values.len] << shift;
                    right |= values[(ri + lane * 3) % values.len] << shift;
                }
                try expectSimdMinMax(&instance, op, left, right);
                try expectSimdMinMax(&instance, op, left, left);
            }
        }
        // Every individual bit can distinguish the two candidates, including
        // the upper half and low bits below a differing signed/unsigned MSB.
        for (0..128) |bit| {
            const single = @as(u128, 1) << @as(u7, @intCast(bit));
            try expectSimdMinMax(&instance, op, single, ~single);
            try expectSimdMinMax(&instance, op, ~single, single);
        }
        try testing.expectEqual(@as(u32, 1), instance.spasm_compiles);
    }
}

test "wasm spasm: SIMD integer minmax exhausts all byte pairs" {
    if (comptime !@import("spasm.zig").supported) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for (simd_minmax_cases[0..4]) |op| {
        const module = try wasm.decode(a, try buildSimdBinaryFunc(a, op.sub));
        var instance: interp.Instance = undefined;
        try interp.instantiate(&instance, a, testing.allocator, &module, .{});
        defer instance.deinit();
        instance.spasm_enabled = true;
        for (0..256) |lhs| {
            for (0..16) |batch| {
                var left: [16]u8 = undefined;
                var right: [16]u8 = undefined;
                for (0..16) |lane| {
                    left[lane] = @truncate(lhs + 17 * lane);
                    right[lane] = @intCast(batch * 16 + lane);
                }
                try expectSimdMinMax(&instance, op, std.mem.readInt(u128, &left, .little), std.mem.readInt(u128, &right, .little));
            }
        }
        try testing.expectEqual(@as(u32, 1), instance.spasm_compiles);
        try testing.expectEqual(@as(u32, 4096), instance.spasm_runs);
    }
}

test "wasm spasm: SIMD integer minmax is skipped after a terminating branch" {
    if (comptime !@import("spasm.zig").supported) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for (simd_minmax_cases) |op| {
        var body: List = .empty;
        try body.appendSlice(a, &.{ 0, 0x02, 0x7b, 0x20, 0, 0x0c, 0, 0x20, 0, 0x20, 0, 0xfd });
        try uleb(a, &body, op.sub);
        try body.appendSlice(a, &.{ 0x0b, 0x0b });
        const module = try wasm.decode(a, try buildFunc(a, &.{0x7b}, &.{0x7b}, body.items, "dead"));
        var instance: interp.Instance = undefined;
        try interp.instantiate(&instance, a, testing.allocator, &module, .{});
        defer instance.deinit();
        instance.spasm_enabled = true;
        const result = try interp.invoke(&instance, testing.allocator, 0, &.{simd_live_vector});
        defer testing.allocator.free(result);
        try testing.expectEqualSlices(u128, &.{simd_live_vector}, result);
        try testing.expectEqual(@as(u32, 1), instance.spasm_compiles);
        try testing.expectEqual(@as(u32, 1), instance.spasm_runs);
    }
}

test "wasm spasm: SIMD splats truncate integers and preserve floating bit patterns" {
    if (comptime !@import("spasm.zig").supported) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for (simd_scalar_cases) |op| {
        const bytes = try buildFunc(a, &.{ 0x7e, 0x7b, op.scalar }, &.{ 0x7e, 0x7b, 0x7b }, &.{
            0, 0x20, 0, 0x20, 1, 0x20, 2, 0xfd, op.splat, 0x0b,
        }, "splat");
        const module = try wasm.decode(a, bytes);
        var instance: interp.Instance = undefined;
        try interp.instantiate(&instance, a, testing.allocator, &module, .{});
        defer instance.deinit();
        instance.spasm_enabled = true;
        for (simd_scalar_bits) |bits| {
            var scalar: [8]u8 = undefined;
            std.mem.writeInt(u64, &scalar, bits, .little);
            var expected: [16]u8 = undefined;
            for (&expected, 0..) |*byte, index| byte.* = scalar[index % op.width];
            const result = try interp.invoke(&instance, testing.allocator, 0, &.{ 37, simd_live_vector, bits });
            defer testing.allocator.free(result);
            try testing.expectEqualSlices(u128, &.{ 37, simd_live_vector, std.mem.readInt(u128, &expected, .little) }, result);
        }
        try testing.expectEqual(@as(u32, 1), instance.spasm_compiles);
        try testing.expectEqual(@as(u32, simd_scalar_bits.len), instance.spasm_runs);
    }
}

test "wasm spasm: SIMD extracts every lane with signed and unsigned scalar results" {
    if (comptime !@import("spasm.zig").supported) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for (simd_scalar_cases) |op| {
        for ([_]bool{ false, true }) |signed| {
            if (signed and op.width > 2) continue;
            for (0..16 / op.width) |lane| {
                const bytes = try buildFunc(a, &.{ 0x7e, 0x7b, 0x7b }, &.{ 0x7e, 0x7b, op.scalar }, &.{
                    0, 0x20, 0, 0x20, 1, 0x20, 2, 0xfd, op.extract - @intFromBool(signed), @intCast(lane), 0x0b,
                }, "extract");
                const module = try wasm.decode(a, bytes);
                var instance: interp.Instance = undefined;
                try interp.instantiate(&instance, a, testing.allocator, &module, .{});
                defer instance.deinit();
                instance.spasm_enabled = true;
                for ([_]u128{ simd_live_vector, ~simd_live_vector, 0x8000_0000_0000_0000_8000_0000_8000_0000, 0x7ff0_0000_0000_0001_7f80_0001_7fc1_2345 }) |vector| {
                    const shift: u7 = @intCast(lane * op.width * 8);
                    const mask = (@as(u128, 1) << @as(u7, @intCast(op.width * 8))) - 1;
                    var expected = (vector >> shift) & mask;
                    if (signed and expected & (@as(u128, 1) << @as(u7, @intCast(op.width * 8 - 1))) != 0)
                        expected |= @as(u128, 0xffff_ffff) ^ mask;
                    const result = try interp.invoke(&instance, testing.allocator, 0, &.{ 37, simd_live_vector, vector });
                    defer testing.allocator.free(result);
                    try testing.expectEqualSlices(u128, &.{ 37, simd_live_vector, expected }, result);
                }
                try testing.expectEqual(@as(u32, 1), instance.spasm_compiles);
                try testing.expectEqual(@as(u32, 4), instance.spasm_runs);
            }
        }
    }
}

test "wasm spasm: SIMD replaces every lane without changing the other bits" {
    if (comptime !@import("spasm.zig").supported) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for (simd_scalar_cases) |op| {
        for (0..16 / op.width) |lane| {
            const bytes = try buildFunc(a, &.{ 0x7e, 0x7b, 0x7b, op.scalar }, &.{ 0x7e, 0x7b, 0x7b }, &.{
                0, 0x20, 0, 0x20, 1, 0x20, 2, 0x20, 3, 0xfd, op.replace, @intCast(lane), 0x0b,
            }, "replace");
            const module = try wasm.decode(a, bytes);
            var instance: interp.Instance = undefined;
            try interp.instantiate(&instance, a, testing.allocator, &module, .{});
            defer instance.deinit();
            instance.spasm_enabled = true;
            for (simd_scalar_bits) |bits| {
                var scalar: [8]u8 = undefined;
                std.mem.writeInt(u64, &scalar, bits, .little);
                var expected: [16]u8 = undefined;
                std.mem.writeInt(u128, &expected, ~simd_live_vector, .little);
                @memcpy(expected[lane * op.width ..][0..op.width], scalar[0..op.width]);
                const result = try interp.invoke(&instance, testing.allocator, 0, &.{ 37, simd_live_vector, ~simd_live_vector, bits });
                defer testing.allocator.free(result);
                try testing.expectEqualSlices(u128, &.{ 37, simd_live_vector, std.mem.readInt(u128, &expected, .little) }, result);
            }
            try testing.expectEqual(@as(u32, 1), instance.spasm_compiles);
            try testing.expectEqual(@as(u32, simd_scalar_bits.len), instance.spasm_runs);
        }
    }
}

test "wasm spasm: SIMD bitwise operations preserve all bits and live operands" {
    if (comptime !@import("spasm.zig").supported) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for (77..83) |sub| {
        var body: List = .empty;
        try body.appendSlice(a, &.{ 0, 0x20, 0, 0x20, 1, 0x20, 2 });
        if (sub != 77) try body.appendSlice(a, &.{ 0x20, 3 });
        if (sub == 82) try body.appendSlice(a, &.{ 0x20, 4 });
        try body.appendSlice(a, &.{ 0xfd, @intCast(sub), 0x0b });
        const bytes = try buildFunc(a, &.{ 0x7e, 0x7b, 0x7b, 0x7b, 0x7b }, &.{ 0x7e, 0x7b, 0x7b }, body.items, "bits");
        const module = try wasm.decode(a, bytes);
        var instance: interp.Instance = undefined;
        try interp.instantiate(&instance, a, testing.allocator, &module, .{});
        defer instance.deinit();
        instance.spasm_enabled = true;
        for ([_]u128{ 0, std.math.maxInt(u128), simd_live_vector }) |left| {
            for ([_]u128{ 0, std.math.maxInt(u128), ~simd_live_vector, simd_live_vector }) |right| {
                for (0..132) |index| {
                    const mask: u128 = switch (index) {
                        128 => 0,
                        129 => std.math.maxInt(u128),
                        130 => left,
                        131 => right,
                        else => @as(u128, 1) << @as(u7, @intCast(index)),
                    };
                    const expected = switch (sub) {
                        77 => ~left,
                        78 => left & right,
                        79 => left & ~right,
                        80 => left | right,
                        81 => left ^ right,
                        82 => (left & mask) | (right & ~mask),
                        else => unreachable,
                    };
                    const result = try interp.invoke(&instance, testing.allocator, 0, &.{ 37, simd_live_vector, left, right, mask });
                    defer testing.allocator.free(result);
                    try testing.expectEqualSlices(u128, &.{ 37, simd_live_vector, expected }, result);
                    if (sub != 82) break;
                }
            }
        }
        try testing.expectEqual(@as(u32, 1), instance.spasm_compiles);
        try testing.expectEqual(@as(u32, if (sub == 82) 1584 else 12), instance.spasm_runs);
    }
}

test "wasm spasm: SIMD constant replacement survives branches and dead lane immediates" {
    if (comptime !@import("spasm.zig").supported) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // The dead lane index 11 must not be mistaken for the block's end.
    const bytes = try buildFunc(a, &.{0x7b}, &.{0x7f}, &.{
        0,    0x41, 37,   0x02, 0x7b, 0x20, 0,    0x0c, 0,
        0x41, 0,    0xfd, 15,   0xfd, 21,   11,   0x1a, 0x20,
        0,    0xfd, 77,   0x0b, 0x41, 0x7f, 0xfd, 23,   11,
        0xfd, 21,   11,   0x6a, 0x0b,
    }, "constant");
    const module = try wasm.decode(a, bytes);
    var instance: interp.Instance = undefined;
    try interp.instantiate(&instance, a, testing.allocator, &module, .{});
    defer instance.deinit();
    instance.spasm_enabled = true;
    const result = try interp.invoke(&instance, testing.allocator, 0, &.{simd_live_vector});
    defer testing.allocator.free(result);
    try testing.expectEqual(@as(u128, 36), result[0]);
    try testing.expectEqual(@as(u32, 1), instance.spasm_runs);
}

test "wasm spasm: SIMD permutation swizzle clears refusal diagnostics" {
    if (comptime !@import("spasm.zig").supported) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const bytes = try buildFunc(a, &.{ 0x7b, 0x7b }, &.{0x7b}, &.{ 0, 0x20, 0, 0x20, 1, 0xfd, 14, 0x0b }, "swizzle");
    const module = try wasm.decode(a, bytes);
    var instance: interp.Instance = undefined;
    try interp.instantiate(&instance, a, testing.allocator, &module, .{});
    defer instance.deinit();
    instance.spasm_enabled = true;
    instance.spasm_diagnostics = true;
    const result = try interp.invoke(&instance, testing.allocator, 0, &.{ 0, 0 });
    defer testing.allocator.free(result);
    try testing.expectEqual(@as(u128, 0), result[0]);
    try testing.expectEqual(@as(u32, 1), instance.spasm_runs);
    try testing.expectEqual(@as(u32, 0), instance.spasm_refusals);
    try testing.expectEqual(@import("spasm.zig").RefusalStage.none, instance.spasm_last_refusal_stage);
    try testing.expect(!instance.spasm_last_refusal_has_subopcode);
    try testing.expectEqual(@as(u32, 0), instance.spasm_refused_simd_subopcodes[14]);
    try testing.expectEqual(@as(u32, 0), instance.spasm_refused_vector_signatures);
}

test "wasm spasm: SIMD vectors survive host calls fallback and aliased multi-results" {
    if (comptime !@import("spasm.zig").supported) return error.SkipZigTest;
    const Host = struct {
        fn call(_: ?*anyopaque, args: []const u128, results: []u128) wasm.TrapError!void {
            if (args[0] == std.math.maxInt(u128)) return error.Unreachable;
            results[0] = ~args[0];
        }
    };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    inline for (.{ true, false }) |host_call| {
        const types = [_]u8{ 2, 0x60, 1, 0x7b, 1, 0x7b, 0x60, 2, 0x7b, 0x7b, 2, 0x7b, 0x7b };
        const wrapper = [_]u8{ 8, 0, 0x20, 0, 0x20, 1, 0x10, 0, 0x0b };
        const sections = if (host_call) &[_]Section{
            .{ .id = 1, .body = &types },
            .{ .id = 2, .body = &.{ 1, 1, 'h', 1, 'f', 0, 0 } },
            .{ .id = 3, .body = &.{ 1, 1 } },
            .{ .id = 10, .body = &([_]u8{1} ++ wrapper) },
        } else &[_]Section{
            .{ .id = 1, .body = &types },
            .{ .id = 3, .body = &.{ 2, 0, 1 } },
            .{ .id = 10, .body = &([_]u8{ 2, 35, 0, 0x20, 0, 0xfd, 77, 0x20, 0, 0xfd, 98, 0x1a } ++ simd_fallback_stack_pressure ++ [_]u8{0x0b} ++ wrapper) },
        };
        const bytes = try assemble(a, sections);
        const module = try wasm.decode(a, bytes);
        const host: wasm.FuncRef = .{ .host = .{ .fn_ptr = Host.call, .params = 1, .results = 1 } };
        var instance: interp.Instance = undefined;
        try interp.instantiate(&instance, a, testing.allocator, &module, if (host_call) .{ .funcs = &.{host} } else .{});
        defer instance.deinit();
        instance.spasm_enabled = true;
        const args = [_]u128{ 0x1234_5678_9abc_def0_ffff_ffff_ffff_ffff, 0xabcd_ef01_2345_6789_0123_4567_89ab_cdef };
        for (0..2) |_| {
            const before = instance.spasm_runs;
            const results = try interp.invoke(&instance, testing.allocator, 1, &args);
            defer testing.allocator.free(results);
            try testing.expectEqualSlices(u128, &.{ args[0], ~args[1] }, results);
            try testing.expect(instance.spasm_runs > before);
        }
        if (host_call) try testing.expectError(error.Unreachable, interp.invoke(&instance, testing.allocator, 1, &.{ args[0], std.math.maxInt(u128) }));
        try testing.expectEqual(@as(u32, 1), instance.spasm_compiles);
        if (!host_call) try testing.expectEqual(@import("spasm.zig").RefusalStage.limits, instance.spasm_last_refusal_stage);
    }
}

test "wasm spasm: SIMD memory32 and memory64 bounds preserve full addresses" {
    if (comptime !@import("spasm.zig").supported) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    inline for (.{ false, true }) |memory64| {
        inline for (.{ false, true }) |store| {
            for ([_]u64{ 0, 8, 0x1_0000_0000, std.math.maxInt(u64) }) |offset| {
                if (!memory64 and offset > std.math.maxInt(u32)) continue;
                var body: List = .empty;
                try body.appendSlice(a, &.{ 0, 0x20, 0 });
                if (store) try body.appendSlice(a, &.{ 0x20, 1 });
                try body.appendSlice(a, &.{ 0xfd, if (store) 11 else 0, 0 });
                try uleb(a, &body, @intCast(offset));
                try body.append(a, 0x0b);
                var code: List = .empty;
                try uleb(a, &code, 1);
                try uleb(a, &code, body.items.len);
                try code.appendSlice(a, body.items);
                const types = [_]u8{ 1, 0x60, 2, if (memory64) 0x7e else 0x7f, 0x7b } ++
                    (if (store) [_]u8{0} else [_]u8{ 1, 0x7b });
                const bytes = try assemble(a, &.{
                    .{ .id = 1, .body = &types },
                    .{ .id = 3, .body = &.{ 1, 0 } },
                    .{ .id = 5, .body = &.{ 1, if (memory64) 4 else 0, 1 } },
                    .{ .id = 10, .body = code.items },
                });
                const module = try wasm.decode(a, bytes);
                var instance: interp.Instance = undefined;
                try interp.instantiate(&instance, a, testing.allocator, &module, .{});
                defer instance.deinit();
                instance.spasm_enabled = true;
                for ([_]u64{ 1, 65520, 65521, if (memory64) 0x1_0000_0000 else 0xffff_ffff }) |address| {
                    const result = interp.invoke(&instance, testing.allocator, 0, &.{ address, 0x1234_5678_9abc_def0_ffff_ffff_ffff_ffff });
                    defer if (result) |values| testing.allocator.free(values) else |_| {};
                    if (offset <= 65520 and address <= 65520 - offset) {
                        _ = try result;
                    } else {
                        try testing.expectError(error.OutOfBoundsMemoryAccess, result);
                    }
                }
                try testing.expectEqual(@as(u32, 1), instance.spasm_compiles);
            }
        }
    }
}

test "wasm spasm: reference values preserve both halves through locals select and returns" {
    if (comptime !@import("spasm.zig").supported) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // (externref, externref, i32) -> externref, with a declared ref local.
    const bytes = try buildFunc(a, &.{ 0x6f, 0x6f, 0x7f }, &.{0x6f}, &.{
        0x01, 0x01, 0x6f, // one externref local
        0x20, 0x00, 0x21, 0x03, // local 3 = first reference
        0x20, 0x03, 0x20, 0x01,
        0x20, 0x02,
        0x1c, 0x01, 0x6f, // select externref
        0x22, 0x03, 0x0f, 0x0b, // tee and explicit return
    }, "select");
    const module = try wasm.decode(a, bytes);
    var instance: interp.Instance = undefined;
    try interp.instantiate(&instance, a, testing.allocator, &module, .{});
    defer instance.deinit();
    instance.spasm_enabled = true;

    const first: u128 = 0x1234_5678_9abc_def0_ffff_ffff_ffff_ffff;
    const second: u128 = 0xfedc_ba98_7654_3210_0123_4567_89ab_cdef;
    for ([_]u128{ first, std.math.maxInt(u128) }) |left| {
        for ([_]u128{ 0, 1, 0xffff_ffff }) |condition| {
            const before = instance.spasm_runs;
            const results = try interp.invoke(&instance, testing.allocator, 0, &.{ left, second, condition });
            defer testing.allocator.free(results);
            try testing.expectEqual(if (condition != 0) left else second, results[0]);
            try testing.expect(instance.spasm_runs > before);
        }
    }
    try testing.expectEqual(@as(u32, 0), instance.spasm_refusals);
}

test "wasm spasm: reference branch merges preserve complete cells" {
    if (comptime !@import("spasm.zig").supported) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const bodies = [_][]const u8{
        // The taken br_if discards a numeric value below the reference.
        &.{ 0x00, 0x02, 0x6f, 0x41, 0x2a, 0x20, 0x00, 0x20, 0x02, 0x0d, 0x00, 0x1a, 0x1a, 0x20, 0x01, 0x0b, 0x0b },
        // Merge references from two arms, including a terminating return.
        &.{ 0x00, 0x20, 0x02, 0x04, 0x6f, 0x20, 0x00, 0x0f, 0x05, 0x20, 0x01, 0x0b, 0x0b },
        // br_table must move a reference into its label's result cell.
        &.{ 0x00, 0x02, 0x6f, 0x41, 0x2a, 0x20, 0x00, 0x20, 0x02, 0x0e, 0x01, 0x00, 0x00, 0x0b, 0x0b },
        // Both a branch and the fallthrough arm feed a null test.
        &.{ 0x00, 0x02, 0x6f, 0x20, 0x00, 0x0c, 0x00, 0x0b, 0xd1, 0x04, 0x6f, 0x20, 0x01, 0x05, 0x20, 0x00, 0x0b, 0x0b },
    };
    const left: u128 = 0x1234_5678_9abc_def0_ffff_ffff_ffff_ffff;
    const right: u128 = std.math.maxInt(u128);
    for (bodies, 0..) |body, body_index| {
        const bytes = try buildFunc(a, &.{ 0x6f, 0x6f, 0x7f }, &.{0x6f}, body, "branch");
        const module = try wasm.decode(a, bytes);
        var instance: interp.Instance = undefined;
        try interp.instantiate(&instance, a, testing.allocator, &module, .{});
        defer instance.deinit();
        instance.spasm_enabled = true;
        for ([_]u128{ 0, 1 }) |condition| {
            const before = instance.spasm_runs;
            const results = try interp.invoke(&instance, testing.allocator, 0, &.{ left, right, condition });
            defer testing.allocator.free(results);
            const expected = if (body_index >= 2 or condition != 0) left else right;
            try testing.expectEqual(expected, results[0]);
            try testing.expect(instance.spasm_runs > before);
        }
        try testing.expectEqual(@as(u32, 0), instance.spasm_refusals);
    }
}

test "wasm spasm: reference loop results and survivors cross execution polls" {
    if (comptime !@import("spasm.zig").supported) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const bodies = [_][]const u8{
        // Reference result produced after the final backedge.
        &.{ 0x00, 0x03, 0x6f, 0x20, 0x01, 0x41, 0x01, 0x6b, 0x22, 0x01, 0x0d, 0x00, 0x20, 0x00, 0x0b, 0x0b },
        // A reference stays live below the loop frame throughout every poll.
        &.{ 0x00, 0x20, 0x00, 0x03, 0x40, 0x20, 0x01, 0x41, 0x01, 0x6b, 0x22, 0x01, 0x0d, 0x00, 0x0b, 0x0b },
    };
    for (bodies) |body| {
        const bytes = try buildFunc(a, &.{ 0x6f, 0x7f }, &.{0x6f}, body, "loop");
        const module = try wasm.decode(a, bytes);
        var instance: interp.Instance = undefined;
        try interp.instantiate(&instance, a, testing.allocator, &module, .{});
        defer instance.deinit();
        instance.spasm_enabled = true;
        var control: CountingExecutionControl = .{};
        instance.execution_control = control.control();
        const reference: u128 = 0x1234_5678_9abc_def0_ffff_ffff_ffff_ffff;
        const results = try interp.invoke(&instance, testing.allocator, 0, &.{ reference, 3 });
        defer testing.allocator.free(results);
        try testing.expectEqual(reference, results[0]);
        try testing.expectEqual(@as(u32, 3), control.polls);
        try testing.expectEqual(@as(u32, 1), instance.spasm_compiles);
        try testing.expectEqual(@as(u32, 1), instance.spasm_runs);
    }
}

test "wasm spasm: reference calls preserve arguments results and null local defaults" {
    if (comptime !@import("spasm.zig").supported) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const bodies = [_][]const u8{
        // (externref, i32) -> externref. The declared local defaults to null.
        &.{ 0x01, 0x01, 0x6f, 0x20, 0x00, 0x20, 0x02, 0x20, 0x01, 0x1c, 0x01, 0x6f, 0x0b },
        &.{ 0x00, 0x20, 0x00, 0x20, 0x01, 0x10, 0x00, 0x0b },
        &.{ 0x00, 0x20, 0x00, 0x20, 0x01, 0x41, 0x00, 0x11, 0x00, 0x00, 0x0b },
        // Recurse through the native self-link with the reference argument.
        &.{ 0x00, 0x20, 0x01, 0x45, 0x04, 0x6f, 0x20, 0x00, 0x05, 0x20, 0x00, 0x20, 0x01, 0x41, 0x01, 0x6b, 0x10, 0x03, 0x0b, 0x0b },
    };
    var code: List = .empty;
    try uleb(a, &code, bodies.len);
    for (bodies) |body| {
        try uleb(a, &code, body.len);
        try code.appendSlice(a, body);
    }
    const bytes = try assemble(a, &.{
        .{ .id = 1, .body = &.{ 0x01, 0x60, 0x02, 0x6f, 0x7f, 0x01, 0x6f } },
        .{ .id = 3, .body = &.{ 0x04, 0x00, 0x00, 0x00, 0x00 } },
        .{ .id = 4, .body = &.{ 0x01, 0x70, 0x00, 0x01 } },
        .{ .id = 9, .body = &.{ 0x01, 0x00, 0x41, 0x00, 0x0b, 0x01, 0x00 } },
        .{ .id = 10, .body = code.items },
    });
    const module = try wasm.decode(a, bytes);
    var instance: interp.Instance = undefined;
    try interp.instantiate(&instance, a, testing.allocator, &module, .{});
    defer instance.deinit();
    instance.spasm_enabled = true;
    const reference: u128 = 0x1234_5678_9abc_def0_ffff_ffff_ffff_ffff;
    // First direct call resolves a cold gate; later calls enter its hot path.
    for ([_]u32{ 1, 1, 2, 3 }) |index| {
        for ([_]u128{ 0, 3 }) |condition| {
            const before = instance.spasm_runs;
            const results = try interp.invoke(&instance, testing.allocator, index, &.{ reference, condition });
            defer testing.allocator.free(results);
            const expected = if (index == 3 or condition != 0) reference else std.math.maxInt(u128);
            try testing.expectEqual(expected, results[0]);
            try testing.expect(instance.spasm_runs > before);
        }
    }
    try testing.expectEqual(@as(u32, 4), instance.spasm_compiles);
    try testing.expectEqual(@as(u32, 0), instance.spasm_refusals);
}

test "wasm spasm: reference table roundtrip retains a foreign function instance" {
    if (comptime !@import("spasm.zig").supported) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const bytes = try assemble(a, &.{
        .{ .id = 1, .body = &.{ 0x02, 0x60, 0x00, 0x01, 0x70, 0x60, 0x01, 0x70, 0x01, 0x70 } },
        .{ .id = 3, .body = &.{ 0x02, 0x00, 0x01 } },
        .{ .id = 4, .body = &.{ 0x01, 0x70, 0x00, 0x01 } },
        .{ .id = 9, .body = &.{ 0x01, 0x03, 0x00, 0x01, 0x00 } },
        .{
            .id = 10,
            .body = &.{
                0x02,
                0x04, 0x00, 0xd2, 0x00, 0x0b, // ref.func 0
                0x13, 0x00,
                0x41, 0x00, 0x20, 0x00, 0x26, 0x00, // table[0] = argument
                0x41, 0x00, 0x25, 0x00, 0x21, 0x00, // argument = table[0]
                0x41, 0x00, 0x11, 0x00, 0x00, 0x0b, // call_indirect ()->funcref
            },
        },
    });
    const module = try wasm.decode(a, bytes);
    var provider: interp.Instance = undefined;
    try interp.instantiate(&provider, a, testing.allocator, &module, .{});
    defer provider.deinit();
    provider.spasm_enabled = true;
    var consumer: interp.Instance = undefined;
    try interp.instantiate(&consumer, a, testing.allocator, &module, .{});
    defer consumer.deinit();
    consumer.spasm_enabled = true;

    const reference = try interp.invoke(&provider, testing.allocator, 0, &.{});
    defer testing.allocator.free(reference);
    try testing.expectEqual(interp.makeFuncRef(&provider, 0), reference[0]);
    const results = try interp.invoke(&consumer, testing.allocator, 1, reference);
    defer testing.allocator.free(results);
    try testing.expectEqual(reference[0], results[0]);
    try testing.expect(provider.spasm_runs > 0);
    try testing.expect(consumer.spasm_runs > 0);
    try testing.expectEqual(@as(u32, 0), provider.spasm_refusals);
    try testing.expectEqual(@as(u32, 0), consumer.spasm_refusals);
}

test "wasm spasm: reference host calls preserve live operands and propagate traps" {
    if (comptime !@import("spasm.zig").supported) return error.SkipZigTest;
    const Host = struct {
        fn call(_: ?*anyopaque, args: []const u128, results: []u128) wasm.TrapError!void {
            if (args[0] == interp.REF_NULL) return error.Unreachable;
            results[0] = args[0];
        }
    };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const bytes = try assemble(a, &.{
        .{ .id = 1, .body = &.{ 0x02, 0x60, 0x01, 0x6f, 0x01, 0x6f, 0x60, 0x02, 0x6f, 0x6f, 0x02, 0x6f, 0x6f } },
        .{ .id = 2, .body = &.{ 0x01, 0x01, 'h', 0x01, 'f', 0x00, 0x00 } },
        .{ .id = 3, .body = &.{ 0x01, 0x01 } },
        .{ .id = 10, .body = &.{ 0x01, 0x08, 0x00, 0x20, 0x00, 0x20, 0x01, 0x10, 0x00, 0x0b } },
    });
    const module = try wasm.decode(a, bytes);
    const host: wasm.FuncRef = .{ .host = .{ .fn_ptr = Host.call, .params = 1, .results = 1 } };
    var instance: interp.Instance = undefined;
    try interp.instantiate(&instance, a, testing.allocator, &module, .{ .funcs = &.{host} });
    defer instance.deinit();
    instance.spasm_enabled = true;
    const args = [_]u128{ 0x1234_5678_9abc_def0_ffff_ffff_ffff_ffff, 0xabcd_ef01_2345_6789_0123_4567_89ab_cdef };
    const results = try interp.invoke(&instance, testing.allocator, 1, &args);
    defer testing.allocator.free(results);
    try testing.expectEqualSlices(u128, &args, results);
    try testing.expectError(error.Unreachable, interp.invoke(&instance, testing.allocator, 1, &.{ args[0], interp.REF_NULL }));
    try testing.expect(instance.spasm_runs > 0);
    try testing.expectEqual(@as(u32, 0), instance.spasm_refusals);
}

test "wasm spasm: reference calls preserve values through interpreter fallback" {
    if (comptime !@import("spasm.zig").supported) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const bytes = try assemble(a, &.{
        .{ .id = 1, .body = &.{ 0x01, 0x60, 0x01, 0x6f, 0x01, 0x6f } },
        .{ .id = 3, .body = &.{ 0x02, 0x00, 0x00 } },
        .{
            .id = 10,
            .body = &.{
                0x02,
                0x05, 0x00, 0x20, 0x00, 0xd4, 0x0b, // unsupported ref.as_non_null
                0x06, 0x00, 0x20, 0x00, 0x10, 0x00,
                0x0b,
            },
        },
    });
    const module = try wasm.decode(a, bytes);
    var instance: interp.Instance = undefined;
    try interp.instantiate(&instance, a, testing.allocator, &module, .{});
    defer instance.deinit();
    instance.spasm_enabled = true;
    const reference: u128 = 0x1234_5678_9abc_def0_ffff_ffff_ffff_ffff;
    for (0..2) |_| {
        const before = instance.spasm_runs;
        const results = try interp.invoke(&instance, testing.allocator, 1, &.{reference});
        defer testing.allocator.free(results);
        try testing.expectEqual(reference, results[0]);
        try testing.expect(instance.spasm_runs > before);
    }
    try testing.expectError(error.NullReference, interp.invoke(&instance, testing.allocator, 1, &.{interp.REF_NULL}));
    try testing.expectEqual(@as(u32, 1), instance.spasm_compiles);
    try testing.expect(instance.spasm_cache.?.slots[0] == .failed);
    if (comptime @import("builtin").cpu.arch == .x86_64) {
        try testing.expectEqual(@as(u32, 1), instance.spasm_refusals);
        try testing.expectEqual(@as(u8, 0xd4), instance.spasm_last_refused_opcode);
    }
}

test "wasm spasm: reference select and blocks decode constructed value types" {
    if (comptime !@import("spasm.zig").supported) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const bytes = try assemble(a, &.{
        .{ .id = 1, .body = &.{ 0x02, 0x60, 0x00, 0x01, 0x7f, 0x60, 0x03, 0x63, 0x00, 0x63, 0x00, 0x7f, 0x01, 0x63, 0x00 } },
        .{ .id = 3, .body = &.{ 0x02, 0x00, 0x01 } },
        .{
            .id = 10,
            .body = &.{
                0x02,
                0x04,
                0x00,
                0x41,
                0x00,
                0x0b,
                0x10, 0x00, 0x02, 0x63, 0x00, // block (result (ref null 0))
                0x20, 0x00, 0x20, 0x01, 0x20,
                0x02, 0x1c, 0x01, 0x63, 0x00,
                0x0b, 0x0b,
            },
        },
    });
    const module = try wasm.decode(a, bytes);
    var instance: interp.Instance = undefined;
    try interp.instantiate(&instance, a, testing.allocator, &module, .{});
    defer instance.deinit();
    instance.spasm_enabled = true;
    const reference = interp.makeFuncRef(&instance, 0);
    for ([_]u128{ 0, 1 }) |condition| {
        const before = instance.spasm_runs;
        const results = try interp.invoke(&instance, testing.allocator, 1, &.{ reference, interp.REF_NULL, condition });
        defer testing.allocator.free(results);
        try testing.expectEqual(if (condition == 0) interp.REF_NULL else reference, results[0]);
        try testing.expect(instance.spasm_runs > before);
    }
    try testing.expectEqual(@as(u32, 0), instance.spasm_refusals);
}

test "wasm spasm: reference table64 access cannot truncate an i64 index" {
    if (comptime !@import("spasm.zig").supported) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const bytes = try assemble(a, &.{
        .{ .id = 1, .body = &.{ 0x01, 0x60, 0x01, 0x7e, 0x01, 0x7f } },
        .{ .id = 3, .body = &.{ 0x01, 0x00 } },
        .{ .id = 4, .body = &.{ 0x01, 0x6f, 0x04, 0x01 } },
        .{ .id = 10, .body = &.{ 0x01, 0x07, 0x00, 0x20, 0x00, 0x25, 0x00, 0xd1, 0x0b } },
    });
    const module = try wasm.decode(a, bytes);
    var instance: interp.Instance = undefined;
    try interp.instantiate(&instance, a, testing.allocator, &module, .{});
    defer instance.deinit();
    instance.spasm_enabled = true;
    const result = interp.invoke(&instance, testing.allocator, 0, &.{0x1_0000_0000});
    defer if (result) |values| testing.allocator.free(values) else |_| {};
    try testing.expectError(error.OutOfBoundsTableAccess, result);
    try testing.expectEqual(@as(u32, 0), instance.spasm_runs);
    try testing.expect(instance.spasm_cache.?.slots[0] == .failed);
}

test "wasm spasm: reference globals preserve imported and defined cells" {
    if (comptime !@import("spasm.zig").supported) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const bytes = try assemble(a, &.{
        .{ .id = 1, .body = &.{ 0x01, 0x60, 0x01, 0x6f, 0x01, 0x6f } },
        .{ .id = 2, .body = &.{ 0x01, 0x01, 'h', 0x01, 'g', 0x03, 0x6f, 0x01 } },
        .{ .id = 3, .body = &.{ 0x01, 0x00 } },
        .{ .id = 6, .body = &.{ 0x01, 0x6f, 0x01, 0xd0, 0x6f, 0x0b } },
        .{
            .id = 10,
            .body = &.{
                0x01, 0x0c, 0x00,
                0x20, 0x00, 0x24, 0x00, // imported global = argument
                0x23, 0x00, 0x24, 0x01, // defined global = imported global
                0x23, 0x01, 0x0b,
            },
        },
    });
    const module = try wasm.decode(a, bytes);
    var imported: interp.Global = .{ .value = interp.REF_NULL, .mutable = true };
    var instance: interp.Instance = undefined;
    try interp.instantiate(&instance, a, testing.allocator, &module, .{ .globals = &.{&imported} });
    defer instance.deinit();
    instance.spasm_enabled = true;
    for ([_]u128{ 0x1234_5678_9abc_def0_ffff_ffff_ffff_ffff, interp.REF_NULL, 0 }) |reference| {
        const before = instance.spasm_runs;
        const results = try interp.invoke(&instance, testing.allocator, 0, &.{reference});
        defer testing.allocator.free(results);
        try testing.expectEqual(reference, results[0]);
        try testing.expectEqual(reference, imported.value);
        try testing.expectEqual(reference, instance.globals[1].value);
        try testing.expect(instance.spasm_runs > before);
    }
    try testing.expectEqual(@as(u32, 0), instance.spasm_refusals);
}

test "wasm spasm: reference globals preserve null constants and foreign function identity" {
    if (comptime !@import("spasm.zig").supported) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const bytes = try assemble(a, &.{
        .{ .id = 1, .body = &.{ 0x02, 0x60, 0x00, 0x01, 0x70, 0x60, 0x01, 0x70, 0x01, 0x70 } },
        .{ .id = 3, .body = &.{ 0x03, 0x00, 0x01, 0x00 } },
        .{ .id = 6, .body = &.{ 0x01, 0x70, 0x01, 0xd0, 0x70, 0x0b } },
        .{ .id = 9, .body = &.{ 0x01, 0x03, 0x00, 0x01, 0x00 } },
        .{ .id = 10, .body = &.{
            0x03,
            0x08,
            0x00,
            0xd2,
            0x00,
            0x24,
            0x00,
            0x23,
            0x00,
            0x0b,
            0x08,
            0x00,
            0x20,
            0x00,
            0x24,
            0x00,
            0x23,
            0x00,
            0x0b,
            0x08,
            0x00,
            0xd0,
            0x70,
            0x24,
            0x00,
            0x23,
            0x00,
            0x0b,
        } },
    });
    const module = try wasm.decode(a, bytes);
    var provider: interp.Instance = undefined;
    try interp.instantiate(&provider, a, testing.allocator, &module, .{});
    defer provider.deinit();
    provider.spasm_enabled = true;
    var consumer: interp.Instance = undefined;
    try interp.instantiate(&consumer, a, testing.allocator, &module, .{});
    defer consumer.deinit();
    consumer.spasm_enabled = true;
    const reference = try interp.invoke(&provider, testing.allocator, 0, &.{});
    defer testing.allocator.free(reference);
    try testing.expectEqual(interp.makeFuncRef(&provider, 0), reference[0]);
    const copied = try interp.invoke(&consumer, testing.allocator, 1, reference);
    defer testing.allocator.free(copied);
    try testing.expectEqual(reference[0], copied[0]);
    try testing.expectEqual(reference[0], consumer.globals[0].value);
    const cleared = try interp.invoke(&consumer, testing.allocator, 2, &.{});
    defer testing.allocator.free(cleared);
    try testing.expectEqual(interp.REF_NULL, cleared[0]);
    try testing.expectEqual(interp.REF_NULL, consumer.globals[0].value);
    try testing.expectEqual(@as(u32, 1), provider.spasm_compiles);
    try testing.expectEqual(@as(u32, 2), consumer.spasm_compiles);
}

test "wasm spasm: reference and scalar multi-results survive aliased call buffers" {
    if (comptime !@import("spasm.zig").supported) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const bytes = try assemble(a, &.{
        .{ .id = 1, .body = &.{ 0x01, 0x60, 0x00, 0x03, 0x6f, 0x7e, 0x6f } },
        .{ .id = 3, .body = &.{ 0x02, 0x00, 0x00 } },
        .{ .id = 10, .body = &.{
            0x02,
            0x09,
            0x00,
            0xd0,
            0x6f,
            0x42,
            0x2a,
            0xd0,
            0x6f,
            0x0f,
            0x0b,
            0x04,
            0x00,
            0x10,
            0x00,
            0x0b,
        } },
    });
    const module = try wasm.decode(a, bytes);
    var instance: interp.Instance = undefined;
    try interp.instantiate(&instance, a, testing.allocator, &module, .{});
    defer instance.deinit();
    instance.spasm_enabled = true;
    for (0..2) |_| {
        const results = try interp.invoke(&instance, testing.allocator, 1, &.{});
        defer testing.allocator.free(results);
        try testing.expectEqualSlices(u128, &.{ interp.REF_NULL, 42, interp.REF_NULL }, results);
    }
    try testing.expectEqual(@as(u32, 2), instance.spasm_compiles);
}

test "wasm spasm: reference table64 helpers refuse defined and imported wide tables" {
    if (comptime !@import("spasm.zig").supported) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const table = [_]u8{ 0x01, 0x70, 0x04, 0x01 };
    const provider_bytes = try assemble(a, &.{.{ .id = 4, .body = &table }});
    const provider_module = try wasm.decode(a, provider_bytes);
    var provider: interp.Instance = undefined;
    try interp.instantiate(&provider, a, testing.allocator, &provider_module, .{});
    defer provider.deinit();
    const Case = struct { body: []const u8, traps: bool = true, trap: wasm.TrapError = error.OutOfBoundsTableAccess };
    const cases = [_]Case{
        .{ .body = &.{ 0x00, 0x20, 0x00, 0x25, 0x00, 0xd1, 0x0b } }, // get
        .{ .body = &.{ 0x00, 0x20, 0x00, 0xd0, 0x70, 0x26, 0x00, 0x41, 0x00, 0x0b } }, // set
        .{ .body = &.{ 0x00, 0x20, 0x00, 0xd0, 0x70, 0x42, 0x01, 0xfc, 0x11, 0x00, 0x41, 0x00, 0x0b } }, // fill
        .{ .body = &.{ 0x00, 0x20, 0x00, 0x42, 0x00, 0x42, 0x01, 0xfc, 0x0e, 0x00, 0x00, 0x41, 0x00, 0x0b } }, // copy
        .{ .body = &.{ 0x00, 0x20, 0x00, 0x41, 0x00, 0x41, 0x01, 0xfc, 0x0c, 0x00, 0x00, 0x41, 0x00, 0x0b } }, // init
        .{ .body = &.{ 0x00, 0x20, 0x00, 0x11, 0x01, 0x00, 0x0b }, .trap = error.UndefinedElement }, // indirect call
        .{ .body = &.{ 0x00, 0xd0, 0x70, 0x20, 0x00, 0xfc, 0x0f, 0x00, 0x42, 0x7f, 0x51, 0x0b }, .traps = false }, // grow
        .{ .body = &.{ 0x00, 0xfc, 0x10, 0x00, 0xa7, 0x0b }, .traps = false }, // size
    };
    for ([_]bool{ false, true }) |imported| {
        for (cases) |case| {
            var code: List = .empty;
            try uleb(a, &code, 1);
            try uleb(a, &code, case.body.len);
            try code.appendSlice(a, case.body);
            const bytes = try assemble(a, &.{
                .{ .id = 1, .body = &.{ 0x02, 0x60, 0x01, 0x7e, 0x01, 0x7f, 0x60, 0x00, 0x01, 0x7f } },
                .{ .id = 2, .body = if (imported) &.{ 0x01, 0x01, 'h', 0x01, 't', 0x01, 0x70, 0x04, 0x01 } else &.{0x00} },
                .{ .id = 3, .body = &.{ 0x01, 0x00 } },
                .{ .id = 4, .body = if (imported) &.{0x00} else &table },
                .{ .id = 9, .body = &.{ 0x01, 0x01, 0x00, 0x01, 0x00 } }, // passive elem segment
                .{ .id = 10, .body = code.items },
            });
            const module = try wasm.decode(a, bytes);
            var instance: interp.Instance = undefined;
            try interp.instantiate(&instance, a, testing.allocator, &module, .{
                .tables = if (imported) &.{provider.tables[0]} else &.{},
            });
            defer instance.deinit();
            instance.spasm_enabled = true;
            const result = interp.invoke(&instance, testing.allocator, 0, &.{0x1_0000_0000});
            defer if (result) |values| testing.allocator.free(values) else |_| {};
            if (case.traps) {
                try testing.expectError(case.trap, result);
            } else {
                try testing.expectEqual(@as(u128, 1), (try result)[0]);
            }
            try testing.expectEqual(@as(u32, 0), instance.spasm_runs);
            try testing.expect(instance.spasm_cache.?.slots[0] == .failed);
        }
    }
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
    instance.spasm_diagnostics = true;

    const fidx = funcExport(mp, "oob") orelse return error.NoSuchExport;
    try testing.expectError(error.OutOfBoundsTableAccess, interp.invoke(&instance, testing.allocator, fidx, &.{}));
    try testing.expectEqual(@as(u32, 0), instance.spasm_refusals);
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
    instance.spasm_diagnostics = true;

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
    try testing.expectEqual(@as(u32, 0), instance.spasm_refusals);
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
    instance.spasm_diagnostics = true;

    // table.fill places add10 at table[1..3]; dispatching through table[2]
    // gives add10(5) == 15, the same the interpreter gives.
    const fidx = funcExport(mp, "fill") orelse return error.NoSuchExport;
    const res = try interp.invoke(&instance, testing.allocator, fidx, &.{});
    defer testing.allocator.free(res);
    try testing.expectEqual(@as(u32, 15), @as(u32, @truncate(res[0])));
    try testing.expect(instance.spasm_runs >= 1);
    try testing.expectEqual(@as(u32, 0), instance.spasm_refusals);
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

test "wasm spasm: caller refreshes memory after callee growth" {
    if (comptime !@import("spasm.zig").supported) return error.SkipZigTest;

    // f() calls g(), then reads the first byte of the page g() added. A
    // compiled caller that retained its pre-call base/length would report an
    // OOB trap here (or use a stale pointer for an address in the old page).
    const module_body = [_]u8{
        0x01, 0x08, 0x02,
        0x60, 0x00, 0x01, 0x7f, // type 0: () -> i32
        0x60, 0x00, 0x00, // type 1: () -> ()
        0x03, 0x03, 0x02, 0x00, 0x01, // funcs: f(type 0), g(type 1)
        0x05, 0x04, 0x01, 0x01, 0x01, 0x02, // memory: min 1, max 2
        0x07, 0x05, 0x01, 0x01, 0x66, 0x00, 0x00, // export f
        0x0a, 0x15, 0x02, 0x0b, 0x00, 0x10, 0x01,
        0x41, 0x80, 0x80, 0x04, 0x2d, 0x00, 0x00,
        0x0b, 0x07, 0x00, 0x41, 0x01, 0x40, 0x00,
        0x1a, 0x0b,
    };
    var buf: [8 + module_body.len]u8 = undefined;
    const bytes = withPreamble(&buf, &module_body);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var instance: interp.Instance = undefined;
    const mp = try setupMemModule(&instance, a, bytes);
    defer instance.deinit();

    const fidx = funcExport(mp, "f") orelse return error.NoSuchExport;
    const result = try interp.invoke(&instance, testing.allocator, fidx, &.{});
    defer testing.allocator.free(result);

    try testing.expectEqual(@as(u32, 0), @as(u32, @truncate(result[0])));
    try testing.expectEqual(@as(u64, 2 * interp.PAGE_SIZE), @as(u64, instance.memories[0].data.len));
    try testing.expect(instance.spasm_runs >= 2);
}

// `(i32,i32)->i32` adders for the rotates: "rl" = i32.rotl (0x77),
// "rr" = i32.rotr (0x78).
const i32_rotl_body = [_]u8{
    0x01, 0x07, 0x01, 0x60, 0x02, 0x7f, 0x7f, 0x01, 0x7f, // type (i32,i32)->i32
    0x03, 0x02, 0x01, 0x00, // func 0 : type 0
    0x07, 0x06, 0x01, 0x02, 0x72, 0x6c, 0x00, 0x00, // export "rl" -> 0
    0x0a, 0x09, 0x01, 0x07, 0x00, 0x20, 0x00, 0x20, 0x01, 0x77, 0x0b, // local.get 0; local.get 1; i32.rotl; end
};

test "wasm spasm: i32.rotl rotates left by the variable count" {
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

test "wasm spasm: i32.rotr rotates right by the variable count" {
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

test "wasm spasm: i64.store compiles and writes eight bytes" {
    if (comptime !@import("spasm.zig").supported) return error.SkipZigTest;
    var buf: [8 + i64_mem_module_body.len]u8 = undefined;
    const bytes = withPreamble(&buf, &i64_mem_module_body);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var instance: interp.Instance = undefined;
    const mp = try setupMemModule(&instance, a, bytes);
    defer instance.deinit();

    const fidx = funcExport(mp, "st") orelse return error.NoSuchExport;
    const cells = try a.alloc(u128, 2);
    cells[0] = 24;
    cells[1] = 0x0123_4567_89AB_CDEF;
    const res = try interp.invoke(&instance, testing.allocator, fidx, cells);
    defer testing.allocator.free(res);

    try testing.expectEqual(
        @as(u64, 0x0123_4567_89AB_CDEF),
        std.mem.readInt(u64, instance.memories[0].data[24..][0..8], .little),
    );
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
    if (comptime !@import("spasm.zig").full_coverage_supported) return error.SkipZigTest;
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
    if (comptime !@import("spasm.zig").full_coverage_supported) return error.SkipZigTest;
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

    cells[0] = @as(u128, @as(u64, @bitCast(@as(f64, -0.0))));
    cells[1] = @as(u128, @as(u64, @bitCast(@as(f64, 0.0))));
    const zero_res = try interp.invoke(&instance, testing.allocator, fidx, cells);
    defer testing.allocator.free(zero_res);
    try testing.expect(std.math.signbit(@as(f64, @bitCast(@as(u64, @truncate(zero_res[0]))))));

    cells[0] = @as(u128, @as(u64, @bitCast(std.math.nan(f64))));
    cells[1] = @as(u128, @as(u64, @bitCast(@as(f64, 1.0))));
    const nan_res = try interp.invoke(&instance, testing.allocator, fidx, cells);
    defer testing.allocator.free(nan_res);
    try testing.expect(std.math.isNan(@as(f64, @bitCast(@as(u64, @truncate(nan_res[0]))))));
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

// An `(i64)->f64` unsigned convert exported as "u64" (0xba =
// f64.convert_i64_u). maxInt(u64) rounds to 2^64 in binary64.
const convert_i64_u_body = [_]u8{
    0x01, 0x06, 0x01, 0x60, 0x01, 0x7e, 0x01, 0x7c, // type (i64)->f64
    0x03, 0x02, 0x01, 0x00, // func 0 : type 0
    0x07, 0x07, 0x01, 0x03, 0x75, 0x36, 0x34, 0x00, 0x00, // export "u64" -> 0
    0x0a, 0x07, 0x01, 0x05, 0x00, 0x20, 0x00, 0xba, 0x0b, // local.get 0; f64.convert_i64_u; end
};

test "wasm spasm: f64.convert_i64_u handles the unsigned high half" {
    if (comptime !@import("spasm.zig").supported) return error.SkipZigTest;
    var buf: [8 + convert_i64_u_body.len]u8 = undefined;
    const bytes = withPreamble(&buf, &convert_i64_u_body);

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

    const fidx = funcExport(mp, "u64") orelse return error.NoSuchExport;
    const cells = try a.alloc(u128, 1);
    cells[0] = std.math.maxInt(u64);

    const res = try interp.invoke(&instance, testing.allocator, fidx, cells);
    defer testing.allocator.free(res);

    try testing.expectEqual(@as(f64, 18446744073709551616.0), @as(f64, @bitCast(@as(u64, @truncate(res[0])))));
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

test "wasm spasm: i32.trunc_sat_f32_s clamps both bounds" {
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

    cells[0] = @as(u128, @as(u32, @bitCast(@as(f32, -1e30))));
    const negative_res = try interp.invoke(&instance, testing.allocator, fidx, cells);
    defer testing.allocator.free(negative_res);
    try testing.expectEqual(@as(u32, 0x80000000), @as(u32, @truncate(negative_res[0])));
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

test "wasm spasm: i64.trunc_sat_f64_u handles NaN, bounds, and the high half" {
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

    // Saturating truncation maps NaN to 0 on every backend.
    try testing.expectEqual(@as(u64, 0), @as(u64, @truncate(res[0])));

    cells[0] = @as(u128, @as(u64, @bitCast(@as(f64, 9223372036854779904.0))));
    const high_res = try interp.invoke(&instance, testing.allocator, fidx, cells);
    defer testing.allocator.free(high_res);
    try testing.expectEqual(@as(u64, 0x8000_0000_0000_1000), @as(u64, @truncate(high_res[0])));

    cells[0] = @as(u128, @as(u64, @bitCast(@as(f64, -1.5))));
    const negative_res = try interp.invoke(&instance, testing.allocator, fidx, cells);
    defer testing.allocator.free(negative_res);
    try testing.expectEqual(@as(u64, 0), @as(u64, @truncate(negative_res[0])));

    cells[0] = @as(u128, @as(u64, @bitCast(@as(f64, 18446744073709551616.0))));
    const overflow_res = try interp.invoke(&instance, testing.allocator, fidx, cells);
    defer testing.allocator.free(overflow_res);
    try testing.expectEqual(std.math.maxInt(u64), @as(u64, @truncate(overflow_res[0])));
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

test "wasm spasm: i32.trunc_f32_s converts an in-range value natively" {
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

// An `(f64)->i64` unsigned trapping truncation exported as "tu64"
// (0xb1 = i64.trunc_f64_u). This exercises the range above INT64_MAX,
// which x86_64's signed CVTTSD2SI instruction cannot convert directly.
const trunc_u64_body = [_]u8{
    0x01, 0x06, 0x01, 0x60, 0x01, 0x7c, 0x01, 0x7e, // type (f64)->i64
    0x03, 0x02, 0x01, 0x00, // func 0 : type 0
    0x07, 0x08, 0x01, 0x04, 0x74, 0x75, 0x36, 0x34, 0x00, 0x00, // export "tu64" -> 0
    0x0a, 0x07, 0x01, 0x05, 0x00, 0x20, 0x00, 0xb1, 0x0b, // local.get 0; i64.trunc_f64_u; end
};

test "wasm spasm: i64.trunc_f64_u handles the unsigned high half and bounds" {
    if (comptime !@import("spasm.zig").supported) return error.SkipZigTest;
    var buf: [8 + trunc_u64_body.len]u8 = undefined;
    const bytes = withPreamble(&buf, &trunc_u64_body);

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

    const fidx = funcExport(mp, "tu64") orelse return error.NoSuchExport;
    const cells = try a.alloc(u128, 1);
    const high_value: f64 = 9223372036854779904.0; // 2^63 + 4096
    cells[0] = @as(u128, @as(u64, @bitCast(high_value)));

    const high_res = try interp.invoke(&instance, testing.allocator, fidx, cells);
    defer testing.allocator.free(high_res);
    try testing.expectEqual(@as(u64, 0x8000_0000_0000_1000), @as(u64, @truncate(high_res[0])));

    cells[0] = @as(u128, @as(u64, @bitCast(@as(f64, -0.5))));
    const negative_fraction_res = try interp.invoke(&instance, testing.allocator, fidx, cells);
    defer testing.allocator.free(negative_fraction_res);
    try testing.expectEqual(@as(u64, 0), @as(u64, @truncate(negative_fraction_res[0])));

    cells[0] = @as(u128, @as(u64, @bitCast(@as(f64, 18446744073709551616.0))));
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
    if (comptime !@import("spasm.zig").full_coverage_supported) return error.SkipZigTest;
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
    if (comptime !@import("spasm.zig").full_coverage_supported) return error.SkipZigTest;
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
    if (comptime !@import("spasm.zig").full_coverage_supported) return error.SkipZigTest;
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
    if (comptime !@import("spasm.zig").full_coverage_supported) return error.SkipZigTest;
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
    if (comptime !@import("spasm.zig").full_coverage_supported) return error.SkipZigTest;
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
    if (comptime !@import("spasm.zig").full_coverage_supported) return error.SkipZigTest;
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
    if (comptime !@import("spasm.zig").full_coverage_supported) return error.SkipZigTest;
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

    cells[0] = @as(u128, @as(u64, @bitCast(std.math.nan(f64))));
    const nan_res = try interp.invoke(&instance, testing.allocator, fidx, cells);
    defer testing.allocator.free(nan_res);
    try testing.expectEqual(@as(u32, 0), @as(u32, @truncate(nan_res[0])));
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

// An `(f32)->f32` ceil exported as "ceil" (0x8d = f32.ceil).
const f32_ceil_body = [_]u8{
    0x01, 0x06, 0x01, 0x60, 0x01, 0x7d, 0x01, 0x7d, // type (f32)->f32
    0x03, 0x02, 0x01, 0x00, // func 0 : type 0
    0x07, 0x08, 0x01, 0x04, 0x63, 0x65, 0x69, 0x6c, 0x00, 0x00, // export "ceil" -> 0
    0x0a, 0x07, 0x01, 0x05, 0x00, 0x20, 0x00, 0x8d, 0x0b, // local.get 0; f32.ceil; end
};

test "wasm spasm: f32.ceil preserves directed rounding and negative zero" {
    if (comptime !@import("spasm.zig").supported) return error.SkipZigTest;
    var buf: [8 + f32_ceil_body.len]u8 = undefined;
    const bytes = withPreamble(&buf, &f32_ceil_body);

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

    const fidx = funcExport(mp, "ceil") orelse return error.NoSuchExport;
    const cells = try a.alloc(u128, 1);
    cells[0] = @as(u128, @as(u32, @bitCast(@as(f32, 1.25))));
    const positive_res = try interp.invoke(&instance, testing.allocator, fidx, cells);
    defer testing.allocator.free(positive_res);
    try testing.expectEqual(@as(f32, 2.0), @as(f32, @bitCast(@as(u32, @truncate(positive_res[0])))));

    cells[0] = @as(u128, @as(u32, @bitCast(@as(f32, -0.25))));
    const zero_res = try interp.invoke(&instance, testing.allocator, fidx, cells);
    defer testing.allocator.free(zero_res);
    try testing.expect(std.math.signbit(@as(f32, @bitCast(@as(u32, @truncate(zero_res[0]))))));
    try testing.expect(instance.spasm_runs >= 1);
}

// An `(f64)->f64` nearest exported as "near" (0x9e = f64.nearest).
const f64_nearest_body = [_]u8{
    0x01, 0x06, 0x01, 0x60, 0x01, 0x7c, 0x01, 0x7c, // type (f64)->f64
    0x03, 0x02, 0x01, 0x00, // func 0 : type 0
    0x07, 0x08, 0x01, 0x04, 0x6e, 0x65, 0x61, 0x72, 0x00, 0x00, // export "near" -> 0
    0x0a, 0x07, 0x01, 0x05, 0x00, 0x20, 0x00, 0x9e, 0x0b, // local.get 0; f64.nearest; end
};

test "wasm spasm: f64.nearest rounds ties to even" {
    if (comptime !@import("spasm.zig").supported) return error.SkipZigTest;
    var buf: [8 + f64_nearest_body.len]u8 = undefined;
    const bytes = withPreamble(&buf, &f64_nearest_body);

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

    const fidx = funcExport(mp, "near") orelse return error.NoSuchExport;
    const cells = try a.alloc(u128, 1);
    cells[0] = @as(u128, @as(u64, @bitCast(@as(f64, 2.5))));
    const even_res = try interp.invoke(&instance, testing.allocator, fidx, cells);
    defer testing.allocator.free(even_res);
    try testing.expectEqual(@as(f64, 2.0), @as(f64, @bitCast(@as(u64, @truncate(even_res[0])))));

    cells[0] = @as(u128, @as(u64, @bitCast(@as(f64, -3.5))));
    const negative_res = try interp.invoke(&instance, testing.allocator, fidx, cells);
    defer testing.allocator.free(negative_res);
    try testing.expectEqual(@as(f64, -4.0), @as(f64, @bitCast(@as(u64, @truncate(negative_res[0])))));
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

test "wasm spasm: an imported call keeps the generic invocation boundary" {
    // An import has no caller-known local layout. Seven scalar results make
    // the compact call buffer coincidentally as large as a leaf EntryFn's
    // scratch requirement, so this proves direct entry is gated on instance
    // identity rather than buffer capacity alone.
    if (comptime !@import("spasm.zig").full_coverage_supported) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const seven_i32 = [_]u8{ I32, I32, I32, I32, I32, I32, I32 };
    // provider: (func (export "callee") (result i32 i32 i32 i32 i32 i32 i32)
    //   i32.const 1 ... i32.const 7)
    const provider = try instOf(a, try buildFunc(a, &.{}, &seven_i32, &.{
        0x00,
        0x41,
        0x01,
        0x41,
        0x02,
        0x41,
        0x03,
        0x41,
        0x04,
        0x41,
        0x05,
        0x41,
        0x06,
        0x41,
        0x07,
        0x0b,
    }, "callee"), .{});
    provider.spasm_enabled = true;

    // importer: import "p"."callee"; (func (export "run") (result x7) call 0)
    const tbody = [_]u8{ 0x01, 0x60, 0x00, 0x07, I32, I32, I32, I32, I32, I32, I32 };
    const ibody = [_]u8{ 0x01, 0x01, 0x70, 0x06, 0x63, 0x61, 0x6c, 0x6c, 0x65, 0x65, 0x00, 0x00 };
    const fbody = [_]u8{ 0x01, 0x00 };
    const xbody = [_]u8{ 0x01, 0x03, 0x72, 0x75, 0x6e, 0x00, 0x01 };
    const cbody = [_]u8{ 0x01, 0x04, 0x00, 0x10, 0x00, 0x0b };
    const ibytes = try assemble(a, &.{
        .{ .id = 1, .body = &tbody },
        .{ .id = 2, .body = &ibody },
        .{ .id = 3, .body = &fbody },
        .{ .id = 7, .body = &xbody },
        .{ .id = 10, .body = &cbody },
    });
    const importer = try instOf(a, ibytes, .{ .funcs = &.{provider.exportedFuncRef("callee").?} });
    importer.spasm_enabled = true;
    importer.invocation_allocator = testing.allocator;

    const fidx = funcExport(importer.module, "run") orelse return error.NoSuchExport;
    const out = try interp.invoke(importer, testing.allocator, fidx, &.{});
    defer testing.allocator.free(out);
    try testing.expectEqual(@as(usize, 7), out.len);
    for (out, 1..) |value, want| {
        try testing.expectEqual(@as(u32, @intCast(want)), @as(u32, @truncate(value)));
    }
    try testing.expect(importer.spasm_runs >= 1);
    try testing.expectEqual(@as(u32, 0), provider.spasm_native_calls);

    // The first call warms every native cache. Repeating the generic import
    // fallback must use short-lived invocation storage, not retain another
    // 64K-cell interpreter stack in the instance's realm-lifetime arena.
    const warm_capacity = arena.queryCapacity();
    for (0..8) |_| {
        const repeated = try interp.invoke(importer, testing.allocator, fidx, &.{});
        testing.allocator.free(repeated);
    }
    try testing.expectEqual(warm_capacity, arena.queryCapacity());
}

test "wasm spasm: imported execution control reaches a cold native callee" {
    if (comptime !@import("spasm.zig").supported) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // provider.outer calls provider.leaf. Both entries are cold when the
    // importer first invokes outer, so the call-gate slow path must preserve
    // the importer's effective execution controller while compiling leaf.
    const ptypes = [_]u8{ 0x01, 0x60, 0x00, 0x01, I32 };
    const pfuncs = [_]u8{ 0x02, 0x00, 0x00 };
    const pexports = [_]u8{ 0x01, 0x05, 'o', 'u', 't', 'e', 'r', 0x00, 0x00 };
    const pcodes = [_]u8{
        0x02,
        0x04, 0x00, 0x10, 0x01, 0x0b, // outer: call leaf
        0x04, 0x00, 0x41, 0x07, 0x0b, // leaf: i32.const 7
    };
    const pbytes = try assemble(a, &.{
        .{ .id = 1, .body = &ptypes },
        .{ .id = 3, .body = &pfuncs },
        .{ .id = 7, .body = &pexports },
        .{ .id = 10, .body = &pcodes },
    });
    const provider = try instOf(a, pbytes, .{});
    provider.spasm_enabled = true;

    // importer.run calls the provider's exported outer function.
    const itypes = [_]u8{ 0x01, 0x60, 0x00, 0x01, I32 };
    const iimports = [_]u8{ 0x01, 0x01, 'p', 0x05, 'o', 'u', 't', 'e', 'r', 0x00, 0x00 };
    const ifuncs = [_]u8{ 0x01, 0x00 };
    const iexports = [_]u8{ 0x01, 0x03, 'r', 'u', 'n', 0x00, 0x01 };
    const icodes = [_]u8{ 0x01, 0x04, 0x00, 0x10, 0x00, 0x0b };
    const ibytes = try assemble(a, &.{
        .{ .id = 1, .body = &itypes },
        .{ .id = 2, .body = &iimports },
        .{ .id = 3, .body = &ifuncs },
        .{ .id = 7, .body = &iexports },
        .{ .id = 10, .body = &icodes },
    });
    const importer = try instOf(a, ibytes, .{ .funcs = &.{provider.exportedFuncRef("outer").?} });
    importer.spasm_enabled = true;

    var control: CountingExecutionControl = .{};
    importer.execution_control = control.control();
    try testing.expectEqual(@as(i32, 7), try invokeInst(a, importer, "run", &.{}));
    try testing.expectEqual(@as(u32, 3), control.polls);
}

test "wasm spasm: an interrupt raised after native entry stops the next backedge" {
    if (comptime !@import("spasm.zig").supported) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // import host.barrier : () -> (); export run : () -> i32. The barrier
    // holds the compiled body after its entry poll. Once released, the
    // two-trip loop guarantees one taken native backedge.
    const tbody = [_]u8{
        0x02,
        0x60,
        0x00,
        0x00,
        0x60,
        0x00,
        0x01,
        I32,
    };
    const ibody = [_]u8{
        0x01,
        0x04,
        'h',
        'o',
        's',
        't',
        0x07,
        'b',
        'a',
        'r',
        'r',
        'i',
        'e',
        'r',
        0x00,
        0x00,
    };
    const fbody = [_]u8{ 0x01, 0x01 };
    const xbody = [_]u8{ 0x01, 0x03, 'r', 'u', 'n', 0x00, 0x01 };
    const cbody = [_]u8{
        0x01, 0x18,
        0x01, 0x01,
        I32,  0x10,
        0x00, 0x41,
        0x02, 0x21,
        0x00, 0x03,
        0x40, 0x20,
        0x00, 0x41,
        0x01, 0x6b,
        0x22, 0x00,
        0x0d, 0x00,
        0x0b, 0x20,
        0x00, 0x0b,
    };
    const bytes = try assemble(a, &.{
        .{ .id = 1, .body = &tbody },
        .{ .id = 2, .body = &ibody },
        .{ .id = 3, .body = &fbody },
        .{ .id = 7, .body = &xbody },
        .{ .id = 10, .body = &cbody },
    });

    var barrier: SpasmInterruptBarrier = .{};
    const host = wasm.FuncRef{ .host = .{
        .fn_ptr = &SpasmInterruptBarrier.call,
        .ctx = &barrier,
        .params = 0,
        .results = 0,
    } };
    const instance = try instOf(a, bytes, .{ .funcs = &.{host} });
    instance.spasm_enabled = true;
    instance.invocation_allocator = testing.allocator;
    const fidx = funcExport(instance.module, "run") orelse return error.NoSuchExport;

    // Compile and warm the call gate before involving another thread.
    const warm = try interp.invoke(instance, testing.allocator, fidx, &.{});
    testing.allocator.free(warm);
    try testing.expect(instance.spasm_runs >= 1);

    var control: DeferredInterruptControl = .{};
    instance.execution_control = control.control();
    barrier.enabled.store(true, .release);
    var worker: SpasmInterruptWorker = .{
        .instance = instance,
        .allocator = testing.allocator,
        .func_index = fidx,
    };
    const thread = try std.Thread.spawn(.{}, SpasmInterruptWorker.run, .{&worker});
    while (!barrier.entered.load(.acquire)) std.atomic.spinLoopHint();
    control.requested.store(true, .release);
    barrier.released.store(true, .release);
    thread.join();

    try testing.expectEqual(@as(u8, 1), worker.status.load(.acquire));
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

test "wasm validator: memory and table limits reject invalid ranges" {
    // memory32 is bounded to 2^16 pages by the core validation rule.
    const memory32_too_large = [_]u8{ 0x01, 0x00, 0x81, 0x80, 0x04 }; // min 65,537
    try expectModuleInvalid(error.InvalidLimits, &.{.{ .id = 5, .body = &memory32_too_large }});

    // memory64 is bounded to 2^48 pages. 2^48 + 1 must be rejected before
    // instantiation can narrow the page count or multiply it by PAGE_SIZE.
    const memory64_too_large = [_]u8{ 0x01, 0x04, 0x81, 0x80, 0x80, 0x80, 0x80, 0x80, 0x40 };
    try expectModuleInvalid(error.InvalidLimits, &.{.{ .id = 5, .body = &memory64_too_large }});

    const memory_min_above_max = [_]u8{ 0x01, 0x01, 0x02, 0x01 };
    try expectModuleInvalid(error.InvalidLimits, &.{.{ .id = 5, .body = &memory_min_above_max }});

    const table_min_above_max = [_]u8{ 0x01, 0x70, 0x01, 0x02, 0x01 };
    try expectModuleInvalid(error.InvalidLimits, &.{.{ .id = 4, .body = &table_min_above_max }});
}

test "wasm validator: table64 accepts the core u64 maximum" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const table64_max = [_]u8{
        0x01, 0x70, 0x05, 0x00,
        0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff,
        0xff, 0x01,
    };
    const bytes = try assemble(arena.allocator(), &.{.{ .id = 4, .body = &table64_max }});
    try loadErr(bytes);
}

test "wasm spasm: a memory64 store/load round-trips with i64 addressing" {
    if (comptime !@import("spasm.zig").supported) return error.SkipZigTest;
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
    const instance = try instOf(arena.allocator(), bytes, .{});
    defer instance.deinit();
    instance.spasm_enabled = true;
    instance.spasm_diagnostics = true;

    const fidx = funcExport(instance.module, "f") orelse return error.NoSuchExport;
    const res = try interp.invoke(instance, testing.allocator, fidx, &.{});
    defer testing.allocator.free(res);
    try testing.expectEqual(@as(i64, 42), asI64(res[0]));
    try testing.expect(instance.spasm_runs >= 1);
    try testing.expectEqual(@as(u32, 1), instance.spasm_compiles);
    try testing.expectEqual(@as(u32, 0), instance.spasm_refusals);
}

test "wasm spasm: a memory64 memarg preserves u64 offset overflow" {
    const spasm = @import("spasm.zig");
    if (comptime !spasm.supported) return error.SkipZigTest;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // (memory i64 1)
    // (func (export "f") (param i64) (result i32)
    //   local.get 0
    //   i32.load8_u offset=0xffffffffffffffff)
    // The dynamic address 1 makes address+offset wrap to zero. The native
    // effective-address check must trap on the carry rather than read byte 0.
    const tbody = [_]u8{ 0x01, 0x60, 0x01, 0x7e, 0x01, 0x7f };
    const fbody = [_]u8{ 0x01, 0x00 };
    const mbody = [_]u8{ 0x01, 0x04, 0x01 };
    const xbody = [_]u8{ 0x01, 0x01, 0x66, 0x00, 0x00 };
    const cbody = [_]u8{
        0x01, 0x10, 0x00,
        0x20, 0x00, 0x2d,
        0x00, 0xff, 0xff,
        0xff, 0xff, 0xff,
        0xff, 0xff, 0xff,
        0xff, 0x01, 0x0b,
    };
    const bytes = try assemble(a, &.{
        .{ .id = 1, .body = &tbody },
        .{ .id = 3, .body = &fbody },
        .{ .id = 5, .body = &mbody },
        .{ .id = 7, .body = &xbody },
        .{ .id = 10, .body = &cbody },
    });
    const instance = try instOf(a, bytes, .{});
    defer instance.deinit();
    instance.spasm_enabled = true;
    instance.spasm_diagnostics = true;

    const fidx = funcExport(instance.module, "f") orelse return error.NoSuchExport;
    try testing.expectError(error.OutOfBoundsMemoryAccess, interp.invoke(instance, testing.allocator, fidx, &.{1}));
    try testing.expect(instance.spasm_runs >= 1);
    try testing.expectEqual(@as(u32, 1), instance.spasm_compiles);
    try testing.expectEqual(@as(u32, 0), instance.spasm_refusals);
}

test "wasm spasm: memory64 bulk memory operations preserve 64-bit operands" {
    if (comptime !@import("spasm.zig").supported) return error.SkipZigTest;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // memory.init [8,12), memory.fill [16,20), memory.copy [8,12) to
    // [24,28), then load byte 25. All memory offsets and bulk lengths are i64.
    const tbody = [_]u8{ 0x01, 0x60, 0x00, 0x01, 0x7f };
    const fbody = [_]u8{ 0x01, 0x00 };
    const mbody = [_]u8{ 0x01, 0x04, 0x01 };
    const xbody = [_]u8{ 0x01, 0x01, 0x66, 0x00, 0x00 };
    const dcbody = [_]u8{0x01};
    const cbody = [_]u8{
        0x01, 0x25, 0x00,
        0x42, 0x08, 0x41,
        0x00, 0x41, 0x04,
        0xfc, 0x08, 0x00,
        0x00, 0x42, 0x10,
        0x41, 0xaa, 0x01,
        0x42, 0x04, 0xfc,
        0x0b, 0x00, 0x42,
        0x18, 0x42, 0x08,
        0x42, 0x04, 0xfc,
        0x0a, 0x00, 0x00,
        0x42, 0x19, 0x2d,
        0x00, 0x00, 0x0b,
    };
    const dbody = [_]u8{ 0x01, 0x01, 0x04, 0x11, 0x22, 0x33, 0x44 };
    const bytes = try assemble(a, &.{
        .{ .id = 1, .body = &tbody },
        .{ .id = 3, .body = &fbody },
        .{ .id = 5, .body = &mbody },
        .{ .id = 7, .body = &xbody },
        .{ .id = 12, .body = &dcbody },
        .{ .id = 10, .body = &cbody },
        .{ .id = 11, .body = &dbody },
    });
    const instance = try instOf(a, bytes, .{});
    defer instance.deinit();
    instance.spasm_enabled = true;
    instance.spasm_diagnostics = true;

    const fidx = funcExport(instance.module, "f") orelse return error.NoSuchExport;
    const res = try interp.invoke(instance, testing.allocator, fidx, &.{});
    defer testing.allocator.free(res);
    try testing.expectEqual(@as(i32, 0x22), asI32(res[0]));
    try testing.expectEqualSlices(u8, &.{ 0xaa, 0xaa, 0xaa, 0xaa }, instance.memories[0].data[16..20]);
    try testing.expect(instance.spasm_runs >= 1);
    try testing.expectEqual(@as(u32, 1), instance.spasm_compiles);
    try testing.expectEqual(@as(u32, 0), instance.spasm_refusals);
}

test "wasm spasm: memory64 memory.init passes the full destination to its helper" {
    if (comptime !@import("spasm.zig").supported) return error.SkipZigTest;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tbody = [_]u8{ 0x01, 0x60, 0x01, 0x7e, 0x00 };
    const fbody = [_]u8{ 0x01, 0x00 };
    const mbody = [_]u8{ 0x01, 0x04, 0x01 };
    const xbody = [_]u8{ 0x01, 0x01, 0x66, 0x00, 0x00 };
    const dcbody = [_]u8{0x01};
    const cbody = [_]u8{
        0x01, 0x0c, 0x00,
        0x20, 0x00, 0x41,
        0x00, 0x41, 0x01,
        0xfc, 0x08, 0x00,
        0x00, 0x0b,
    };
    const dbody = [_]u8{ 0x01, 0x01, 0x01, 0x7f };
    const bytes = try assemble(a, &.{
        .{ .id = 1, .body = &tbody },
        .{ .id = 3, .body = &fbody },
        .{ .id = 5, .body = &mbody },
        .{ .id = 7, .body = &xbody },
        .{ .id = 12, .body = &dcbody },
        .{ .id = 10, .body = &cbody },
        .{ .id = 11, .body = &dbody },
    });
    const instance = try instOf(a, bytes, .{});
    defer instance.deinit();
    instance.spasm_enabled = true;
    instance.spasm_diagnostics = true;

    const fidx = funcExport(instance.module, "f") orelse return error.NoSuchExport;
    try testing.expectError(error.OutOfBoundsMemoryAccess, interp.invoke(instance, testing.allocator, fidx, &.{0x1_0000_0000}));
    try testing.expect(instance.spasm_runs >= 1);
    try testing.expectEqual(@as(u32, 1), instance.spasm_compiles);
    try testing.expectEqual(@as(u32, 0), instance.spasm_refusals);
}

test "wasm spasm: overflowing memory64 grow delta returns i64 minus one" {
    if (comptime !@import("spasm.zig").supported) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tbody = [_]u8{ 0x01, 0x60, 0x01, 0x7e, 0x01, 0x7e };
    const fbody = [_]u8{ 0x01, 0x00 };
    const mbody = [_]u8{ 0x01, 0x04, 0x01 };
    const xbody = [_]u8{ 0x01, 0x01, 0x66, 0x00, 0x00 };
    const cbody = [_]u8{ 0x01, 0x06, 0x00, 0x20, 0x00, 0x40, 0x00, 0x0b };
    const bytes = try assemble(a, &.{
        .{ .id = 1, .body = &tbody },
        .{ .id = 3, .body = &fbody },
        .{ .id = 5, .body = &mbody },
        .{ .id = 7, .body = &xbody },
        .{ .id = 10, .body = &cbody },
    });
    const instance = try instOf(a, bytes, .{});
    defer instance.deinit();
    instance.spasm_enabled = true;
    instance.spasm_diagnostics = true;

    const fidx = funcExport(instance.module, "f") orelse return error.NoSuchExport;
    const res = try interp.invoke(instance, testing.allocator, fidx, &.{std.math.maxInt(u64)});
    defer testing.allocator.free(res);
    try testing.expectEqual(@as(i64, -1), asI64(res[0]));
    try testing.expect(instance.spasm_runs >= 1);
    try testing.expectEqual(@as(u32, 1), instance.spasm_compiles);
    try testing.expectEqual(@as(u32, 0), instance.spasm_refusals);
}

test "wasm interp: overflowing table64 grow delta returns -1" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tbody = [_]u8{ 0x01, 0x60, 0x01, 0x7e, 0x01, 0x7e };
    const fbody = [_]u8{ 0x01, 0x00 };
    const tabbody = [_]u8{ 0x01, 0x70, 0x04, 0x01 };
    const xbody = [_]u8{ 0x01, 0x01, 0x66, 0x00, 0x00 };
    const cbody = [_]u8{ 0x01, 0x09, 0x00, 0xd0, 0x70, 0x20, 0x00, 0xfc, 0x0f, 0x00, 0x0b };
    const bytes = try assemble(a, &.{
        .{ .id = 1, .body = &tbody },
        .{ .id = 3, .body = &fbody },
        .{ .id = 4, .body = &tabbody },
        .{ .id = 7, .body = &xbody },
        .{ .id = 10, .body = &cbody },
    });
    const res = try runRaw(bytes, "f", &.{std.math.maxInt(u64)});
    defer testing.allocator.free(res);
    try testing.expectEqual(@as(i64, -1), asI64(res[0]));
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

test "wasm spasm: SIMD i32x4.add constants stored and lane-read run natively" {
    // §4.4 SIMD — the v128 data path plus the first NEON compute op. "f"
    // builds two i32x4 vectors with `v128.const`, lane-wise adds them with
    // `i32x4.add` (the NEON `ADD Vd.4S`), stores the 128-bit result to
    // linear memory with `v128.store`, then reads lane 1 back out with
    // `i32.load` and returns it. `i32x4.extract_lane` is out of scope, so
    // the store+scalar-load round-trip is how the test observes one lane.
    // [1,2,3,4] + [10,20,30,40] = [11,22,33,44]; lane 1 = 2+20 = 22.
    if (comptime !@import("spasm.zig").supported) return error.SkipZigTest;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // type 0: () -> (i32)
    const tbody = [_]u8{ 0x01, 0x60, 0x00, 0x01, 0x7f };
    // func section: func 0 : type 0
    const fbody = [_]u8{ 0x01, 0x00 };
    // memory section: one page, min only
    const mbody = [_]u8{ 0x01, 0x00, 0x01 };
    // export "f" -> func 0
    const xbody = [_]u8{ 0x01, 0x01, 'f', 0x00, 0x00 };
    // code: func 0, 0 locals:
    //   i32.const 0                      ;; store address
    //   v128.const i32x4 1 2 3 4
    //   v128.const i32x4 10 20 30 40
    //   i32x4.add                        ;; 0xFD 0xAE 0x01
    //   v128.store align=4 offset=0      ;; 0xFD 0x0B 0x04 0x00
    //   i32.const 0                      ;; load address
    //   i32.load align=2 offset=4        ;; lane 1
    //   end
    const cbody = [_]u8{
        0x01, // one code entry
        0x34, // body length (52 bytes)
        0x00, // 0 local groups
        0x41, 0x00, // i32.const 0
        0xfd, 0x0c, // v128.const
        0x01, 0x00,
        0x00, 0x00,
        0x02, 0x00,
        0x00, 0x00,
        0x03, 0x00,
        0x00, 0x00,
        0x04, 0x00,
        0x00, 0x00,
        0xfd, 0x0c, // v128.const
        0x0a, 0x00,
        0x00, 0x00,
        0x14, 0x00,
        0x00, 0x00,
        0x1e, 0x00,
        0x00, 0x00,
        0x28, 0x00,
        0x00, 0x00,
        0xfd, 0xae, 0x01, // i32x4.add
        0xfd, 0x0b, 0x04, 0x00, // v128.store a=4 o=0
        0x41, 0x00, // i32.const 0
        0x28, 0x02, 0x04, // i32.load a=2 o=4
        0x0b, // end
    };
    const bytes = try assemble(a, &.{
        .{ .id = 1, .body = &tbody },
        .{ .id = 3, .body = &fbody },
        .{ .id = 5, .body = &mbody },
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

    const fidx = funcExport(mp, "f") orelse return error.NoSuchExport;
    const res = try interp.invoke(&instance, testing.allocator, fidx, &.{});
    defer testing.allocator.free(res);

    try testing.expectEqual(@as(u32, 22), @as(u32, @truncate(res[0])));
    // The whole body — v128.const/add/store + i32.load — ran Spasm-compiled.
    try testing.expect(instance.spasm_runs >= 1);
}

test "wasm spasm: SIMD parameter flows through a local and out as the result" {
    // §4.4 SIMD — exercises a v128 parameter, a 128-bit operand on the
    // stack, and a v128 result, all of which reuse the depth-keyed cell
    // machinery. "id" is `(param v128) (result v128) local.get 0` — the
    // whole 128-bit value must round-trip unchanged. A v128 param seeds its
    // cell from the args buffer; `local.get` copies cell→operand-slot; the
    // epilogue copies the result operand's cell back to the results buffer.
    if (comptime !@import("spasm.zig").supported) return error.SkipZigTest;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // type 0: (v128) -> (v128)
    const tbody = [_]u8{ 0x01, 0x60, 0x01, 0x7b, 0x01, 0x7b };
    // func section: func 0 : type 0
    const fbody = [_]u8{ 0x01, 0x00 };
    // export "id" -> func 0
    const xbody = [_]u8{ 0x01, 0x02, 'i', 'd', 0x00, 0x00 };
    // code: func 0, 0 locals: local.get 0; end
    const cbody = [_]u8{ 0x01, 0x04, 0x00, 0x20, 0x00, 0x0b };
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

    const fidx = funcExport(mp, "id") orelse return error.NoSuchExport;
    const cells = try a.alloc(u128, 1);
    // A value whose two 64-bit halves differ, so a half-only copy would show.
    const want: u128 = 0x0123_4567_89AB_CDEF_FEDC_BA98_7654_3210;
    cells[0] = want;
    const res = try interp.invoke(&instance, testing.allocator, fidx, cells);
    defer testing.allocator.free(res);

    try testing.expectEqual(want, res[0]);
    try testing.expect(instance.spasm_runs >= 1);
}
