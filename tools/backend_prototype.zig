//! Isolated shared-backend smoke experiment, not a throughput benchmark.
const std = @import("std");
const wasm = @import("cynic").wasm;
const prototype = wasm.backend_prototype;

// (i32 n) -> sum(i*i, i=0..n), with two zero-initialized i32 locals.
const body = [_]u8{
    1,    2,    0x7f,
    0x02, 0x40, 0x03,
    0x40, 0x20, 1,
    0x20, 0,    0x4e,
    0x0d, 1,    0x20,
    2,    0x20, 1,
    0x20, 1,    0x6c,
    0x6a, 0x21, 2,
    0x20, 1,    0x41,
    1,    0x6a, 0x21,
    1,    0x0c, 0,
    0x0b, 0x0b, 0x20,
    2,    0x0b,
};
const module_bytes = [_]u8{
    0, 0x61, 0x73, 0x6d, 1,  0,            0, 0,
    1, 6,    1,    0x60, 1,  0x7f,         1, 0x7f,
    3, 2,    1,    0,    10, body.len + 2, 1, body.len,
} ++ body;

pub fn main(init: std.process.Init) !void {
    if (comptime !prototype.native.supported) return error.UnsupportedTarget;
    const a = init.gpa;
    const compile_start = std.Io.Clock.now(.awake, init.io);
    var graph = try prototype.lowerModule(a, &module_bytes, 0);
    defer graph.deinit();
    var owner = try prototype.CodeAllocator.init(a, 256 * 1024);
    defer owner.deinit();
    var compiled = try prototype.native.compile(a, &owner, graph.graph);
    defer compiled.deinit();
    const compile_us = compile_start.untilNow(init.io, .awake).toMicroseconds();

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const module = try wasm.decode(arena.allocator(), &module_bytes);
    var instance: wasm.Instance = undefined;
    try wasm.instantiate(&instance, arena.allocator(), a, &module, .{});
    defer instance.deinit();
    instance.spasm_diagnostics = true;
    var native_entries: u32 = 0;
    for ([_]u32{ 0, 1, 2, 10, 100, 1000 }) |n| {
        var expected: u32 = 0;
        for (0..n) |i| expected +%= @as(u32, @intCast(i)) *% @as(u32, @intCast(i));
        const actual = try compiled.run(&.{n}, 10_000);
        native_entries += 1;
        if (actual != expected) return error.ResultMismatch;
        for ([_]bool{ false, true }) |spasm| {
            instance.spasm_enabled = spasm;
            const result = try wasm.invoke(&instance, a, 0, &.{n});
            defer a.free(result);
            if (result.len != 1 or result[0] != actual) return error.ResultMismatch;
        }
    }
    if (instance.spasm_runs != native_entries) return error.MissingSpasmEntry;
    const run_start = std.Io.Clock.now(.awake, init.io);
    var checksum: u64 = 0;
    for (0..100) |_| checksum +%= try compiled.run(&.{1000}, 10_000);
    const run_us = run_start.untilNow(init.io, .awake).toMicroseconds();
    std.debug.print(
        "Shared backend experiment (not a production tier)\n" ++
            "  verified SSA: {d} blocks, {d} values\n" ++
            "  decode + validate + lower + emit: {d} us; installed code: {d} bytes\n" ++
            "  matching results: {d}; backend entries: {d}; Spasm entries: {d}\n" ++
            "  100 bounded calls (scratch allocation included): {d} us; checksum: {d}\n" ++
            "  Normal tier selection is unchanged. These are diagnostics, not a speedup claim.\n",
        .{ graph.graph.blocks.len, graph.graph.types.len, compile_us, compiled.code.bytes().?.len, native_entries, native_entries, instance.spasm_runs, run_us, checksum },
    );
}
