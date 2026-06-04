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
const ta = @import("builtins/typed_array.zig");
const heap_mod = @import("heap.zig");
const JSString = @import("string.zig").JSString;

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

/// Build a fresh Realm whose `globalThis.sab` wraps `block`, evaluate
/// `src` (which references `sab`), and store the int completion in `out`.
fn agentOverBlock(block: *SharedDataBlock, src: []const u8, out: *i32) void {
    var realm = Realm.init(std.heap.page_allocator);
    defer realm.deinit();
    realm.installBuiltins() catch {
        out.* = -1;
        return;
    };
    const sab = ta.wrapSharedBlock(&realm, block) catch {
        out.* = -2;
        return;
    };
    realm.globals.put(realm.allocator, "sab", sab) catch {
        out.* = -3;
        return;
    };
    const outcome = lantern.evaluateScript(std.heap.page_allocator, &realm, src) catch {
        out.* = -4;
        return;
    };
    out.* = switch (outcome) {
        .value, .yielded => |v| if (v.isInt32()) v.asInt32() else -5,
        .thrown => -6,
    };
}

test "multi-agent: Atomics.wait parks and a cross-thread notify wakes it (ok)" {
    // Slot 0 is the wait location; slot 1 is a RUNNING handshake flag.
    // The waiter sets RUNNING then waits on slot 0; the notifier spins
    // until RUNNING, then notifies slot 0 — the test262 wait/notify
    // pattern. The 5s timeout bounds the test if notify never lands.
    const block = try SharedDataBlock.create(16, 16);
    defer block.release();

    var wait_result: i32 = 0;
    var notify_result: i32 = 0;
    const waiter = try std.Thread.spawn(.{}, agentOverBlock, .{
        block,
        \\var i32 = new Int32Array(sab);
        \\Atomics.store(i32, 1, 1);          // RUNNING
        \\var r = Atomics.wait(i32, 0, 0, 10000);
        \\Atomics.store(i32, 2, 1);          // DONE (woke / timed out)
        \\r === 'ok' ? 1 : (r === 'timed-out' ? 2 : (r === 'not-equal' ? 3 : 9));
        ,
        &wait_result,
    });
    const notifier = try std.Thread.spawn(.{}, agentOverBlock, .{
        block,
        // Spin until RUNNING, then RETRY notify until the waiter signals
        // DONE — robust against the notify-before-park race: once the
        // waiter is parked, the next notify's seq-bump wakes it. Returns
        // 1 if any notify woke a parked agent. Both loops carry a large
        // but finite backstop so that a waiter thread that never starts
        // (or never parks) makes this test FAIL fast instead of spinning
        // forever and hanging the whole `zig build test` run — a test
        // must never be able to wedge the suite.
        \\var i32 = new Int32Array(sab);
        \\var guard = 0;
        \\while (Atomics.load(i32, 1) !== 1) { if (++guard > 500000000) break; }
        \\var woke = 0, tries = 0;
        \\while (Atomics.load(i32, 2) !== 1) {
        \\  woke += Atomics.notify(i32, 0, 1);
        \\  for (var k = 0; k < 200000; k++) {}
        \\  if (++tries > 1000000) break;
        \\}
        \\woke > 0 ? 1 : 0;
        ,
        &notify_result,
    });
    waiter.join();
    notifier.join();
    // The real guarantee: the waiter was woken by a notify → "ok"
    // (code 1). `Atomics.wait` returns "ok" ONLY when the slot's
    // notify-sequence changed, and ONLY `Atomics.notify` ever bumps it,
    // so wait_result == 1 proves a cross-thread notify woke a parked
    // agent. notify_result (the woken count) is NOT asserted: notify
    // returns min(waiters[slot], count), and whether a given notify
    // observes the waiter's `waiters[slot]` increment before the waiter
    // parks is an inherent race — the seq-bump still wakes it, so the
    // count can legitimately read 0 on an otherwise-successful wake. (A
    // real test262 wait/notify fixture avoids the race by reporting
    // "about to wait" and spinning until the waiter is parked.)
    try testing.expectEqual(@as(i32, 1), wait_result);
}

test "multi-agent: concurrent Atomics.add is atomic (no lost updates)" {
    // §25.4 memory model: an RMW must be a single indivisible
    // read-modify-write. N agents each add 1 to the SAME shared slot
    // `iters` times; with genuine hardware atomics the final value is
    // EXACTLY N*iters. A plain (non-atomic) read-modify-write loses
    // updates under contention, so this is the executable spec for the
    // atomic op — it fails before atomics.zig uses real `@atomicRmw`.
    const block = try SharedDataBlock.create(8, 8);
    defer block.release();
    const N = 4;
    const iters = 20000;
    var outs = std.mem.zeroes([N]i32);
    var threads: [N]std.Thread = undefined;
    const src =
        \\var i32 = new Int32Array(sab);
        \\for (var k = 0; k < 20000; k++) Atomics.add(i32, 0, 1);
        \\0;
    ;
    for (0..N) |i| threads[i] = try std.Thread.spawn(.{}, agentOverBlock, .{ block, src, &outs[i] });
    for (0..N) |i| threads[i].join();
    for (outs) |o| try testing.expectEqual(@as(i32, 0), o); // no agent errored
    const total = std.mem.readInt(i32, block.bytes[0..4], .little);
    try testing.expectEqual(@as(i32, N * iters), total);
}

test "multi-agent: Atomics.compareExchange serializes a shared counter" {
    // Each agent increments slot 0 via a compareExchange CAS-retry loop
    // `iters` times. A correct CAS never double-counts or drops an
    // increment, so the total is exactly N*iters — proving the
    // compare-and-swap is a single atomic step, not a racy read/compare/
    // write.
    const block = try SharedDataBlock.create(8, 8);
    defer block.release();
    const N = 4;
    const iters = 8000;
    var outs = std.mem.zeroes([N]i32);
    var threads: [N]std.Thread = undefined;
    const src =
        \\var i32 = new Int32Array(sab);
        \\for (var k = 0; k < 8000; k++) {
        \\  var old;
        \\  do { old = Atomics.load(i32, 0); }
        \\  while (Atomics.compareExchange(i32, 0, old, old + 1) !== old);
        \\}
        \\0;
    ;
    for (0..N) |i| threads[i] = try std.Thread.spawn(.{}, agentOverBlock, .{ block, src, &outs[i] });
    for (0..N) |i| threads[i].join();
    for (outs) |o| try testing.expectEqual(@as(i32, 0), o);
    const total = std.mem.readInt(i32, block.bytes[0..4], .little);
    try testing.expectEqual(@as(i32, N * iters), total);
}


// ── async `Atomics.waitAsync` across threads ─────────────────────────
// Engine-level companions to the sync wait/notify test above. The sync
// node blocks its thread; an async node has no blocking frame, so it
// lives on the block's wait list while the waiting agent drives its own
// microtask drain + §25.4.1.4 settlement. These prove that path without
// the test262 harness — the go/no-go gate for the cross-agent surface.

fn napMs(ms: u64) void {
    var req: std.c.timespec = .{ .sec = @intCast(ms / 1000), .nsec = @intCast((ms % 1000) * std.time.ns_per_ms) };
    _ = std.c.nanosleep(&req, null);
}

/// Read the JS global `outcome`: 0 still unset (null), 1 "ok",
/// 2 "timed-out", 3 "not-equal", 9 anything else.
fn readOutcomeCode(realm: *Realm) i32 {
    const v = realm.globals.get("outcome") orelse return 0;
    if (!v.isString()) return 0;
    const str: *JSString = @ptrCast(@alignCast(v.asString()));
    const b = str.flatBytes();
    if (std.mem.eql(u8, b, "ok")) return 1;
    if (std.mem.eql(u8, b, "timed-out")) return 2;
    if (std.mem.eql(u8, b, "not-equal")) return 3;
    return 9;
}

/// Build a realm over `block`, run `src` (which parks an async waiter and
/// records its settled value in `outcome`), then host-drive the wait to
/// completion. Writes the outcome code to `out`. A finite iteration
/// backstop so a regression fails fast instead of hanging the suite.
fn asyncWaiterAgent(block: *SharedDataBlock, src: []const u8, out: *i32) void {
    var realm = Realm.init(std.heap.page_allocator);
    defer realm.deinit();
    realm.installBuiltins() catch {
        out.* = -1;
        return;
    };
    const sab = ta.wrapSharedBlock(&realm, block) catch {
        out.* = -2;
        return;
    };
    realm.globals.put(realm.allocator, "sab", sab) catch {
        out.* = -3;
        return;
    };
    _ = lantern.evaluateScript(std.heap.page_allocator, &realm, src) catch {
        out.* = -4;
        return;
    };
    var iters: usize = 0;
    while (iters < 5000) : (iters += 1) {
        lantern.drainMicrotasks(realm.allocator, &realm) catch {};
        _ = lantern.fireExpiredAsyncWaits(realm.allocator, &realm) catch {};
        lantern.drainMicrotasks(realm.allocator, &realm) catch {};
        if (readOutcomeCode(&realm) != 0) break;
        napMs(1);
    }
    out.* = readOutcomeCode(&realm);
}

test "multi-agent: a cross-thread notify wakes an async waitAsync (ok)" {
    const block = try SharedDataBlock.create(16, 16);
    defer block.release();

    var wait_result: i32 = 0;
    var notify_result: i32 = 0;
    // The waiter parks the async node BEFORE signalling RUNNING (index 1),
    // so a notifier that observes RUNNING is guaranteed to find the node —
    // notify returns exactly 1 (unlike the sync test, where the park
    // happens after RUNNING and the count can race).
    const waiter = try std.Thread.spawn(.{}, asyncWaiterAgent, .{
        block,
        \\var i32 = new Int32Array(sab);
        \\var outcome = null;
        \\Atomics.waitAsync(i32, 0, 0, 10000).value.then(function (v) { outcome = v; });
        \\Atomics.store(i32, 1, 1);
        ,
        &wait_result,
    });
    const notifier = try std.Thread.spawn(.{}, agentOverBlock, .{
        block,
        \\var i32 = new Int32Array(sab);
        \\var guard = 0;
        \\while (Atomics.load(i32, 1) !== 1) { if (++guard > 500000000) break; }
        \\Atomics.notify(i32, 0, 1);
        ,
        &notify_result,
    });
    waiter.join();
    notifier.join();
    // The async wait resolved "ok" (woken), and notify reported it woke 1.
    try testing.expectEqual(@as(i32, 1), wait_result);
    try testing.expectEqual(@as(i32, 1), notify_result);
}

test "multi-agent: an async waitAsync settles timed-out at its deadline" {
    const block = try SharedDataBlock.create(16, 16);
    defer block.release();

    var result: i32 = 0;
    // No notifier: a 50 ms timeout must settle "timed-out" on the
    // waiter's own thread as its drive loop's wall-clock passes the
    // deadline.
    const waiter = try std.Thread.spawn(.{}, asyncWaiterAgent, .{
        block,
        \\var i32 = new Int32Array(sab);
        \\var outcome = null;
        \\Atomics.waitAsync(i32, 0, 0, 50).value.then(function (v) { outcome = v; });
        \\Atomics.store(i32, 1, 1);
        ,
        &result,
    });
    waiter.join();
    try testing.expectEqual(@as(i32, 2), result);
}

test "multi-agent: clearPendingAsyncWaits unlinks the block node (no dangle)" {
    const block = try SharedDataBlock.create(8, 8);
    defer block.release();

    var realm = Realm.init(std.heap.page_allocator);
    defer realm.deinit();
    try realm.installBuiltins();
    const sab = try ta.wrapSharedBlock(&realm, block);
    try realm.globals.put(realm.allocator, "sab", sab);

    // Park an untimed async waiter, then abandon it without settling — as
    // a reaped fixture / torn-down realm would.
    _ = lantern.evaluateScript(std.heap.page_allocator, &realm, "var i32 = new Int32Array(sab); Atomics.waitAsync(i32, 0, 0);") catch {};
    try testing.expectEqual(@as(usize, 1), realm.pending_async_waits.items.len);

    // Teardown cleanup detaches + frees the node, so it can't dangle on
    // the still-shared block: a notify now finds nothing parked.
    realm.clearPendingAsyncWaits();
    try testing.expectEqual(@as(usize, 0), realm.pending_async_waits.items.len);
    block.lockWaiters();
    const woke = block.wakeWaiters(0, std.math.maxInt(u32));
    block.unlockWaiters();
    try testing.expectEqual(@as(u32, 0), woke);
}
