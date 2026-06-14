//! Standalone micro-benchmark for the Sarcasm WebAssembly interpreter.
//!
//! Times two interpretation-bound workloads — a tight arithmetic loop
//! (local.get/set, i32 mul/add, compare, br_if/br) and recursive `fib`
//! (call + branch dispatch) — so a dispatch-loop change can be measured
//! against a fixed baseline. The absolute numbers are not portable; the
//! before/after delta on one machine is the signal. Build/run
//! ReleaseFast via `zig build wasm-bench`.

const std = @import("std");
const cynic = @import("cynic");
const wasm = cynic.wasm;

const preamble = [_]u8{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 };
const List = std.ArrayListUnmanaged(u8);

fn uleb(a: std.mem.Allocator, l: *List, v0: usize) !void {
    var v = v0;
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

/// Assemble a single exported `(i32)->(i32)` function `f` from `body`.
fn buildFunc(a: std.mem.Allocator, body: []const u8) ![]const u8 {
    var out: List = .empty;
    try out.appendSlice(a, &preamble);
    try section(a, &out, 1, &.{ 0x01, 0x60, 0x01, 0x7f, 0x01, 0x7f }); // type (i32)->(i32)
    try section(a, &out, 3, &.{ 0x01, 0x00 }); // func 0 : type 0
    try section(a, &out, 7, &.{ 0x01, 0x01, 0x66, 0x00, 0x00 }); // export "f" -> func 0
    var co: List = .empty;
    try uleb(a, &co, 1);
    try uleb(a, &co, body.len);
    try co.appendSlice(a, body);
    try section(a, &out, 10, co.items);
    return out.items;
}

/// `sum(n) = Σ i*i for i in 0..n` via a block/loop with br_if + br.
const sum_body = [_]u8{
    0x01, 0x02, 0x7f, // locals: i, acc
    0x02, 0x40, // block
    0x03, 0x40, // loop
    0x20, 0x01, 0x20, 0x00, 0x4e, // local.get i; local.get n; i32.ge_s
    0x0d, 0x01, // br_if 1 (break)
    0x20, 0x02, 0x20, 0x01, 0x20, 0x01, 0x6c, 0x6a, 0x21, 0x02, // acc += i*i
    0x20, 0x01, 0x41, 0x01, 0x6a, 0x21, 0x01, // i += 1
    0x0c, 0x00, // br 0 (continue)
    0x0b, // end loop
    0x0b, // end block
    0x20, 0x02, // local.get acc
    0x0b, // end func
};

/// `fib(n)` — recursive, exercising if/else, call, and the func end.
const fib_body = [_]u8{
    0x00,
    0x20, 0x00, 0x41, 0x02, 0x48, // local.get 0; i32.const 2; i32.lt_s
    0x04, 0x7f, 0x20, 0x00, // if (result i32) local.get 0
    0x05, // else
    0x20, 0x00, 0x41, 0x01, 0x6b, 0x10, 0x00, // local.get 0; i32.const 1; i32.sub; call 0
    0x20, 0x00, 0x41, 0x02, 0x6b, 0x10, 0x00, // local.get 0; i32.const 2; i32.sub; call 0
    0x6a, // i32.add
    0x0b, 0x0b, // end if; end func
};

const Bench = struct {
    name: []const u8,
    body: []const u8,
    arg: i32,
    reps: u32,
};

const Timing = struct { us: i64, checksum: u64, spasm_runs: u32 };

/// Warm up once (under Spasm this compiles + caches the function), then
/// time `reps` invocations. The warmup invoke is excluded, so a Spasm
/// run measures cached native execution — no per-rep compile.
fn timeReps(inst: *wasm.Instance, a: std.mem.Allocator, io: std.Io, args: []const u128, reps: u32) !Timing {
    _ = try wasm.invoke(inst, a, 0, args);
    const runs_before = inst.spasm_runs;
    var checksum: u64 = 0;
    const t0 = std.Io.Clock.now(.awake, io);
    var k: u32 = 0;
    while (k < reps) : (k += 1) {
        const res = try wasm.invoke(inst, a, 0, args);
        checksum +%= @truncate(res[0]);
    }
    const us = t0.untilNow(io, .awake).toMicroseconds();
    return .{ .us = us, .checksum = checksum, .spasm_runs = inst.spasm_runs - runs_before };
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const a = arena.allocator();

    const benches = [_]Bench{
        .{ .name = "loop   sum(i*i), n=2_000_000", .body = &sum_body, .arg = 2_000_000, .reps = 20 },
        .{ .name = "fib(32) recursive", .body = &fib_body, .arg = 32, .reps = 8 },
    };

    for (benches) |bench| {
        const bytes = try buildFunc(a, bench.body);
        const m = try wasm.decode(a, bytes);
        const mp = try a.create(wasm.Module);
        mp.* = m;
        const args = [_]u128{@as(u32, @bitCast(bench.arg))};

        // Interpreter baseline.
        const inst_i = try a.create(wasm.Instance);
        try wasm.instantiate(inst_i, a, a, mp, .{});
        const ti = try timeReps(inst_i, a, io, &args, bench.reps);

        // Spasm (baseline tier forced on). The function compiles once at
        // warmup and the cached EntryFn runs every timed rep.
        const inst_s = try a.create(wasm.Instance);
        try wasm.instantiate(inst_s, a, a, mp, .{});
        inst_s.spasm_enabled = true;
        const ts = try timeReps(inst_s, a, io, &args, bench.reps);

        const interp_per = @as(f64, @floatFromInt(ti.us)) / @as(f64, @floatFromInt(bench.reps));
        const spasm_per = @as(f64, @floatFromInt(ts.us)) / @as(f64, @floatFromInt(bench.reps));
        const speedup = if (spasm_per > 0.0) interp_per / spasm_per else 0.0;
        // The same answer interpreted vs compiled is the inline correctness
        // check; `native` confirms Spasm engaged (vs degrading to interp,
        // e.g. `call`-using bodies it can't emit yet).
        const tag = if (ts.spasm_runs > 0) "native" else "degraded";

        var line: [320]u8 = undefined;
        const msg = try std.fmt.bufPrint(&line, "{s:<30}  interp {d:>8.3}  spasm {d:>8.3} ms/rep  {d:>5.2}x  {s:<8} (chk {x}=={x})\n", .{
            bench.name,
            interp_per / 1_000.0,
            spasm_per / 1_000.0,
            speedup,
            tag,
            ti.checksum,
            ts.checksum,
        });
        try std.Io.File.stdout().writeStreamingAll(io, msg);
    }
}
