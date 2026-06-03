//! Multi-agent GO/NO-GO — proves Cynic tolerates several agents (each
//! its own Realm + heap) running concurrently on OS threads, sharing
//! only a SharedArrayBuffer's bytes. This is the gate for the
//! real-threads `$262.agent` substrate (docs/multi-agent-atomics.md):
//! if concurrent isolated realms race on engine-global state, the
//! whole multi-agent phase is blocked.
//!
//! The engine has no top-level mutable globals except the Math.random
//! PRNG seed (a benign data race — torn reads just yield different
//! random numbers, no UB), so isolated realms should be race-free.

const std = @import("std");
const testing = std.testing;

const Realm = @import("realm.zig").Realm;
const lantern = @import("lantern/interpreter.zig");
const SharedDataBlock = @import("shared_data_block.zig").SharedDataBlock;

/// Each agent: a fresh Realm on its own thread, doing real allocating
/// work (objects + arrays + GC pressure) to shake out cross-thread
/// engine-state races. Writes its computed sum to `out`.
fn isolatedAgent(out: *i64) void {
    var realm = Realm.init(std.heap.page_allocator);
    defer realm.deinit();
    realm.installBuiltins() catch {
        out.* = -1;
        return;
    };
    const src =
        \\var s = 0;
        \\for (var i = 0; i < 20000; i++) {
        \\  var o = { a: i, b: [i, i + 1], c: "x" + i };
        \\  s += o.a + o.b[1];
        \\}
        \\s;
    ;
    const outcome = lantern.evaluateScript(std.heap.page_allocator, &realm, src) catch {
        out.* = -2;
        return;
    };
    out.* = switch (outcome) {
        .value, .yielded => |v| if (v.isInt32()) v.asInt32() else if (v.isDouble()) @intFromFloat(v.asDouble()) else -3,
        .thrown => -4,
    };
}

test "multi-agent: concurrent isolated realms are race-free" {
    // sum over i in [0,20000): a + b[1] = i + (i+1) = 2i+1
    // = 20000^2 = 400000000.
    const expected: i64 = 400000000;
    const N = 4;
    var results = std.mem.zeroes([N]i64);
    var threads: [N]std.Thread = undefined;
    for (0..N) |i| {
        threads[i] = try std.Thread.spawn(.{}, isolatedAgent, .{&results[i]});
    }
    for (0..N) |i| threads[i].join();
    for (results) |r| try testing.expectEqual(expected, r);
}

/// Agent that writes its index into a shared block slot, then reads
/// back its own slot — proves the shared bytes are coherent across
/// threads (the futex layer comes in Phase B).
fn sharedWriterAgent(block: *SharedDataBlock, idx: usize, out: *i32) void {
    var realm = Realm.init(std.heap.page_allocator);
    defer realm.deinit();
    realm.installBuiltins() catch {
        out.* = -1;
        return;
    };
    // Write a marker into the block at our slot and read it back.
    // (Disjoint slots + the join() barrier make this race-free without
    // atomics; the futex layer arrives in Phase B.)
    const marker: i32 = @intCast(idx * 100 + 7);
    std.mem.writeInt(i32, block.bytes[idx * 4 ..][0..4], marker, .little);
    out.* = std.mem.readInt(i32, block.bytes[idx * 4 ..][0..4], .little);
}

test "multi-agent: a SharedDataBlock is coherent across threads" {
    const block = try SharedDataBlock.create(16, 16);
    defer block.release();
    const N = 4;
    var results = std.mem.zeroes([N]i32);
    var threads: [N]std.Thread = undefined;
    for (0..N) |i| {
        threads[i] = try std.Thread.spawn(.{}, sharedWriterAgent, .{ block, i, &results[i] });
    }
    for (0..N) |i| threads[i].join();
    for (0..N) |i| try testing.expectEqual(@as(i32, @intCast(i * 100 + 7)), results[i]);
    // The block saw every agent's write.
    for (0..N) |i| try testing.expectEqual(@as(i32, @intCast(i * 100 + 7)), std.mem.readInt(i32, block.bytes[i * 4 ..][0..4], .little));
}
