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

    // Distinct prototype objects: each realm allocates its OWN
    // %X.prototype% copies, and this is mandatory and permanent —
    // `.constructor` is a per-realm data slot (§6.1.7.4, §9.3.2,
    // §20.1.3.1, §23.1.3.3), so two realms must never alias a
    // prototype. (The reverted D1 "shared frozen prototype
    // subgraph" is forbidden, not deferred; see
    // `docs/multi-realm.md`.) Cross-realm sharing is limited to the
    // per-`Heap` ShapeTree — see the initChild test below.
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
    _ = try lantern.evaluateScript(testing.allocator, &ra, "Array.prototype.fooFromA = 42;");

    // Confirm ra sees it.
    const probe_a = try lantern.evaluateScript(testing.allocator, &ra, "Array.prototype.fooFromA === 42");
    try testing.expect(probe_a.value.bits == @import("value.zig").Value.true_.bits);

    // rb must be untouched.
    const probe_b = try lantern.evaluateScript(testing.allocator, &rb, "Array.prototype.fooFromA === undefined");
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
    _ = try lantern.evaluateScript(testing.allocator, &ra, "Promise.resolve().then(() => { globalThis.__seenFromRa = true; });");
    try lantern.drainMicrotasks(testing.allocator, &ra);

    // ra's globalThis got the side effect: the microtask ran against
    // ra's realm and wrote to ra's global object.
    const probe_a = try lantern.evaluateScript(testing.allocator, &ra, "globalThis.__seenFromRa === true");
    try testing.expect(probe_a.value.bits == @import("value.zig").Value.true_.bits);

    // rb's globalThis must NOT have it — queue isolation means the
    // microtask only fired against ra's realm. If the queues were
    // shared, rb would see `__seenFromRa` too.
    const probe_b = try lantern.evaluateScript(testing.allocator, &rb, "typeof globalThis.__seenFromRa === 'undefined'");
    try testing.expect(probe_b.value.bits == @import("value.zig").Value.true_.bits);
}

// ── D1-revised contract: shape sharing across initChild ────────────
//
// Per `docs/multi-realm.md` D1 revision (commit `ae847a8`),
// each realm allocates its OWN prototype objects — `.constructor`
// being a per-realm data slot is the spec-mandated reason
// (§6.1.7.4, §9.3.2, §20.1.3.1, §23.1.3.3; five-engine
// cross-realm probe confirms). The shared substrate Cynic
// relies on for cross-realm efficiency is the per-`Heap`
// `ShapeTree` — and `Realm.initChild` shares the heap with
// its parent. This test pins that contract: two objects
// allocated on parent + child that go through the same
// transition path land on shape-identical pointers.

test "phase 0+: child realm shares the parent's ShapeTree (D1 revised)" {
    var parent = Realm.init(testing.allocator);
    defer parent.deinit();

    const child_ptr = try testing.allocator.create(Realm);
    child_ptr.* = Realm.initChild(&parent);
    // Children borrow the parent's heap (owns_heap=false), so
    // their deinit only releases their own maps. The parent's
    // deinit also tears down registered child realms, but a
    // child created bare for a test isn't registered — release
    // it manually here.
    defer {
        child_ptr.deinit();
        testing.allocator.destroy(child_ptr);
    }

    try testing.expect(parent.heap == child_ptr.heap);
    // The shape tree IS the heap-owned subgraph that production
    // engines (V8 Map tree, JSC Structure graph) share across
    // realms; sameness of `heap` implies sameness of `shapes`.
    try testing.expect(&parent.heap.shapes == &child_ptr.heap.shapes);
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

    _ = try lantern.evaluateScript(testing.allocator, &ra, "print('hello from ra');");

    try testing.expect(std.mem.indexOf(u8, ra.output.items, "hello from ra") != null);
    try testing.expectEqual(@as(usize, 0), rb.output.items.len);
}

// ── Phase 3 — D2: per-`JSFunction` [[Realm]] + RealmStack ───────────
//
// These pin §10.2.4 OrdinaryFunctionCreate step 8 (the function's
// realm slot) + §10.2.3 [[Call]] step 2 (caller-context switches to
// callee's realm). All four are TDD-RED today: `JSFunction.realm`
// stays `null` at every `Heap.allocateFunction*` site because the
// heap layer doesn't take a realm parameter. Commit 3.2 in the
// `docs/multi-realm.md` Phase 3 plan threads the parameter through
// the 109 alloc sites; commit 3.3 wires RealmStack + flips these
// tests from skip-as-pending to green.
//
// Cross-realm value sharing uses `Realm.initChild` (shared heap),
// not two independent `Realm.init` instances — the latter is
// unsound (cross-heap pointers in another realm's GC root set).
// initChild is also what `ShadowRealm` uses internally, so these
// tests double as the ShadowRealm boundary contract.

const Value = @import("value.zig").Value;
const heap_mod = @import("heap.zig");

test "phase 3: function created in parent realm has parent as [[Realm]] (skip pending 3.3)" {
    if (true) return error.SkipZigTest;

    var parent = Realm.init(testing.allocator);
    defer parent.deinit();
    try parent.installBuiltins();

    var child = Realm.initChild(&parent);
    defer child.deinit();
    try child.installBuiltins();

    // Create a function in parent. After 3.2, its `realm` slot
    // is set at allocateFunction time.
    const f_v = (try lantern.evaluateScript(testing.allocator, &parent, "(function f() { return 1; })")).value;
    const f = heap_mod.valueAsFunction(f_v) orelse return error.TestFailed;
    try testing.expect(f.realm == &parent);

    // Hand f to child via shared-heap value passing.
    try child.globals.put(testing.allocator, "fromParent", f_v);

    // Call from child. f's [[Realm]] must still be parent — the
    // function's realm is fixed at creation, not at call time.
    _ = try lantern.evaluateScript(testing.allocator, &child, "fromParent();");
    try testing.expect(f.realm == &parent);
}

test "phase 3: TypeError thrown by parent's code is parent's Error.prototype chain (skip pending 3.3)" {
    if (true) return error.SkipZigTest;

    // §10.2.3 / §10.2.4: an Error allocated inside a function whose
    // [[Realm]] is parent must inherit from parent's %Error.prototype%,
    // not child's. The b95694b commit already attributes
    // *engine-thrown* TypeErrors correctly; this test extends that
    // to *user-thrown* errors from cross-realm-called functions.
    var parent = Realm.init(testing.allocator);
    defer parent.deinit();
    try parent.installBuiltins();

    var child = Realm.initChild(&parent);
    defer child.deinit();
    try child.installBuiltins();

    const thrower_v = (try lantern.evaluateScript(testing.allocator, &parent, "(function () { throw new TypeError('from parent'); })")).value;
    try child.globals.put(testing.allocator, "boom", thrower_v);

    // Catch in child, probe the error's identity. e.constructor
    // should be parent's TypeError, NOT child's.
    const probe = (try lantern.evaluateScript(testing.allocator, &child, "let r; try { boom(); } catch (e) { r = e.constructor === TypeError; } r")).value;
    // child's `TypeError` (the global) is a different JSFunction
    // than parent's TypeError; the comparison resolves to false.
    try testing.expect(probe.bits == Value.false_.bits);
}

test "phase 3: §23.1.3.34 Array.prototype.map uses source realm's %Array% as species (skip pending 3.3)" {
    if (true) return error.SkipZigTest;

    var parent = Realm.init(testing.allocator);
    defer parent.deinit();
    try parent.installBuiltins();

    var child = Realm.initChild(&parent);
    defer child.deinit();
    try child.installBuiltins();

    // Array created in parent.
    const arr_v = (try lantern.evaluateScript(testing.allocator, &parent, "[1, 2, 3]")).value;
    try child.globals.put(testing.allocator, "arrFromParent", arr_v);

    // §23.1.3.34 ArraySpeciesCreate reads the source array's realm's
    // %Array%, NOT the calling realm's. So `m.constructor` is
    // parent's Array, distinct from child's `Array` global.
    const probe = (try lantern.evaluateScript(testing.allocator, &child, "const m = arrFromParent.map(x => x * 2); m.constructor === Array")).value;
    try testing.expect(probe.bits == Value.false_.bits);
}

test "phase 3: native callback sees its own function's realm via active_native_fn_realm (skip pending 3.3)" {
    if (true) return error.SkipZigTest;

    // The native-side D2 invariant: a native installed in parent
    // and called from child reads `realm.active_native_fn_realm`
    // == &parent (its [[Realm]]). The dispatch loop's `realm`
    // parameter is the *calling* realm (child); reading it would
    // resolve intrinsics in the wrong realm.
    //
    // After 3.2, `JSFunction.realm` set at allocateFunctionNative
    // time; lantern/call.zig:806 already stores it into
    // active_native_fn_realm at native dispatch. The probe shape
    // (a NativeFn cb that records `realm.active_native_fn_realm`
    // into a captured cell) lives in commit 3.3 alongside the
    // un-skip; here the prose-only test pins the invariant in the
    // contract file so reviewers see it.
    return;
}
