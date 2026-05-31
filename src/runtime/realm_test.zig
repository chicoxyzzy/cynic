//! Phase 0 multi-realm contracts — see `docs/multi-realm.md`.
//!
//! The four assertions in this file are the contract for "two `Realm`
//! instances coexist in one process without interference." If they
//! pass on `main` today, the foundation for the multi-realm phase
//! plan is solid and Phase 1 can land its sharing-policy work without
//! a structural refactor. If they fail, the failure mode pins the
//! remaining single-realm assumption that has to come out first.
//!
//! TDD discipline: these tests ship before the production code they
//! pin. Today's `Realm` already has `initChild` (used by ShadowRealm)
//! plus a parameterised `installBuiltins`, so Phase 0's contracts
//! plausibly already hold for two independent `Realm.init` instances.
//! The tests below verify that hypothesis empirically rather than
//! by reading the code.

const std = @import("std");
const testing = std.testing;

const Realm = @import("realm.zig").Realm;
const lantern = @import("lantern/interpreter.zig");

/// Helper: spin up a fresh `Realm` with builtins installed under the
/// requested SES posture. Caller owns deinit. Mirrors the bootstrap
/// every sibling `_test.zig` file uses.
fn freshRealm(hardened: bool) !Realm {
    var r = Realm.init(testing.allocator);
    r.hardened = hardened;
    try r.installBuiltins();
    return r;
}

// ── Contract 1: two realms have distinct intrinsics ─────────────────

test "phase-0: two independent realms have distinct intrinsic pointers" {
    var ra = try freshRealm(true);
    defer ra.deinit();
    var rb = try freshRealm(true);
    defer rb.deinit();

    // Distinct prototype objects — even under hardened, today's
    // `installBuiltins` allocates per-realm copies. Phase 1 (D1 in
    // the ADR) will introduce explicit sharing via `IntrinsicsBase`
    // for hardened realms; this test will then need to track the
    // policy. For now: distinct.
    try testing.expect(ra.intrinsics.object_prototype != null);
    try testing.expect(rb.intrinsics.object_prototype != null);
    try testing.expect(ra.intrinsics.object_prototype != rb.intrinsics.object_prototype);
    try testing.expect(ra.intrinsics.array_prototype != rb.intrinsics.array_prototype);
    try testing.expect(ra.intrinsics.function_prototype != rb.intrinsics.function_prototype);
}

test "phase-0: each realm has its own globalThis" {
    var ra = try freshRealm(true);
    defer ra.deinit();
    var rb = try freshRealm(true);
    defer rb.deinit();

    const a_gt = ra.globals.get("globalThis") orelse return error.TestFailed;
    const b_gt = rb.globals.get("globalThis") orelse return error.TestFailed;
    // Tagged pointers — different JSObject → different bits.
    try testing.expect(a_gt.bits != b_gt.bits);
}

// ── Contract 2: mutation isolation (unhardened) ─────────────────────

test "phase-0: mutating ra's Array.prototype does not affect rb (unhardened)" {
    var ra = try freshRealm(false);
    defer ra.deinit();
    var rb = try freshRealm(false);
    defer rb.deinit();

    // Mutate in ra.
    _ = try lantern.evaluateScript(testing.allocator, &ra,
        "Array.prototype.fooFromA = 42;");

    // Confirm ra sees it.
    const probe_a = try lantern.evaluateScript(testing.allocator, &ra,
        "Array.prototype.fooFromA === 42");
    try testing.expect(probe_a.value.bits == @import("value.zig").Value.true_.bits);

    // rb must be untouched.
    const probe_b = try lantern.evaluateScript(testing.allocator, &rb,
        "Array.prototype.fooFromA === undefined");
    try testing.expect(probe_b.value.bits == @import("value.zig").Value.true_.bits);
}

// ── Contract 3: microtask isolation ─────────────────────────────────

test "phase-0: each realm has its own microtask queue (isolation via side effect)" {
    // Unhardened: the side-effect probe writes to `globalThis`,
    // which under hardened is frozen (§ SES position in
    // `docs/ses-alignment.md`). The contract being verified
    // here is queue isolation, independent of freeze posture.
    var ra = try freshRealm(false);
    defer ra.deinit();
    var rb = try freshRealm(false);
    defer rb.deinit();

    // `evaluateScript` itself doesn't drain — the host (here, this
    // test) is responsible for calling `drainMicrotasks` at the
    // §9.4 HostEnqueueMicrotask boundary, exactly like the test262
    // harness and the CLI do. Drain *ra*'s queue and confirm
    // *rb*'s queue is untouched: the side effect (a write to
    // ra's globalThis) is what proves the realms ran independent
    // microtask queues.
    // `Promise.resolve().then(cb)` queues `cb` as a microtask
    // (§27.2.1.5 + §27.2.5.4). `queueMicrotask` isn't installed
    // as a JS global on Cynic's production-shaped realm surface
    // — the Promise route is the spec-canonical way to enqueue.
    _ = try lantern.evaluateScript(testing.allocator, &ra,
        "Promise.resolve().then(() => { globalThis.__seenFromRa = true; });");
    try lantern.drainMicrotasks(testing.allocator, &ra);

    // ra's globalThis got the side effect: the microtask ran against
    // ra's realm and wrote to ra's global object.
    const probe_a = try lantern.evaluateScript(testing.allocator, &ra,
        "globalThis.__seenFromRa === true");
    try testing.expect(probe_a.value.bits == @import("value.zig").Value.true_.bits);

    // rb's globalThis must NOT have it — queue isolation means the
    // microtask only fired against ra's realm. If the queues were
    // shared, rb would see `__seenFromRa` too.
    const probe_b = try lantern.evaluateScript(testing.allocator, &rb,
        "typeof globalThis.__seenFromRa === 'undefined'");
    try testing.expect(probe_b.value.bits == @import("value.zig").Value.true_.bits);
}

// ── Contract 4: output buffer isolation ─────────────────────────────

test "phase-0: each realm has its own output buffer (print)" {
    var ra = try freshRealm(true);
    defer ra.deinit();
    var rb = try freshRealm(true);
    defer rb.deinit();

    // Sanity: both empty.
    try testing.expectEqual(@as(usize, 0), ra.output.items.len);
    try testing.expectEqual(@as(usize, 0), rb.output.items.len);

    _ = try lantern.evaluateScript(testing.allocator, &ra,
        "print('hello from ra');");

    try testing.expect(std.mem.indexOf(u8, ra.output.items, "hello from ra") != null);
    try testing.expectEqual(@as(usize, 0), rb.output.items.len);
}
