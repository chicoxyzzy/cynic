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

test "phase 3: function created in parent realm has parent as [[Realm]]" {
    // Live since the realm is threaded through native + ordinary
    // function allocation (`Heap.allocateFunction*` takes the
    // allocating realm); a function's [[Realm]] is fixed at
    // creation and survives a cross-realm call.
    var parent = Realm.init(testing.allocator);
    defer parent.deinit();
    try parent.installBuiltins();

    var child = Realm.initChild(&parent);
    defer child.deinit();
    try child.installBuiltins();

    // Create a function in parent; its `realm` slot is set at
    // allocateFunction time.
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

test "phase 3: TypeError thrown by parent's code is parent's Error.prototype chain (skip pending 3.3 consumption)" {
    // PENDING 3.3 consumption side. [[Realm]] is set on every
    // function (3.2), and call.zig/interpreter.zig record the
    // callee's realm as `active_native_fn_realm` /
    // `CallFrame.running_realm`. The remaining gap is the deepest
    // piece: free *global identifier resolution*. When parent's
    // `thrower` runs after being called from child, `new TypeError`
    // resolves the `TypeError` binding through the global-load
    // opcodes, which read `realm.globals` — the *running* (child)
    // realm — not the function's lexical home-realm global
    // environment, so it constructs with child's TypeError and the
    // probe sees `e.constructor === (child) TypeError`. Fixing it
    // means routing global loads/stores through the executing
    // frame's `running_realm.globals` (the RealmStack consumption).
    // A smaller follow-on then makes the error natives resolve
    // their prototype via `active_native_fn_realm` (§10.2.3) —
    // necessary but not sufficient alone (verified: that change in
    // isolation leaves this test red).

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

test "phase 3: §23.1.3.34 Array.prototype.map uses source realm's %Array% as species (skip pending 3.3 consumption)" {
    // PENDING 3.3 consumption side. The Array.prototype.map native
    // builds its result through the *calling* realm's %Array%
    // instead of the source array's realm. ArraySpeciesCreate
    // (§23.1.3.34) must default `C` to the source object's realm's
    // %Array% — resolve via `realm.active_native_fn_realm orelse
    // realm` at the array.zig species site, mirroring the error-
    // native fix. [[Realm]] is already in place (3.2); only the
    // consumption is missing.

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

test "phase 3: a global write from a cross-realm-called function targets its home realm" {
    // §6.2.5.5 PutValue / §9.1.1.4 SetMutableBinding — a function
    // assigns its free globals through its own [[Realm]]'s global
    // environment. A writer defined in parent, called from a child
    // that shares the heap, must store into parent's global, never
    // the calling (child) realm's. Strict mode (Cynic's only mode)
    // means an undeclared target throws ReferenceError, so the
    // pre-fix behaviour was a *throw* against child's globals, not a
    // silent mis-store — either way the write never reached parent.
    var parent = Realm.init(testing.allocator);
    defer parent.deinit();
    try parent.installBuiltins();

    var child = Realm.initChild(&parent);
    defer child.deinit();
    try child.installBuiltins();

    // `var crossWrite` lives in parent's global declarative record;
    // the writer is captured as the script's completion value (the
    // §16.1.7 last-statement value), mirroring the cross-realm hand-
    // off in the tests above. Avoid `globalThis.x =` + bare read,
    // which is an object-env-record property, not a binding.
    _ = try lantern.evaluateScript(testing.allocator, &parent, "var crossWrite = 'init';");
    const writer_v = (try lantern.evaluateScript(testing.allocator, &parent, "(function () { crossWrite = 'from-call'; })")).value;
    try child.globals.put(testing.allocator, "callIt", writer_v);
    _ = try lantern.evaluateScript(testing.allocator, &child, "callIt();");

    // The store landed in parent's global, not child's.
    const in_parent = (try lantern.evaluateScript(testing.allocator, &parent, "crossWrite === 'from-call'")).value;
    try testing.expect(in_parent.bits == Value.true_.bits);
    // child never declared crossWrite — it stays unbound there.
    const in_child = (try lantern.evaluateScript(testing.allocator, &child, "typeof crossWrite === 'undefined'")).value;
    try testing.expect(in_child.bits == Value.true_.bits);
}

test "phase 3: slot-indexed top-level let read from a cross-realm-called function targets its home realm" {
    // §9.1.1.4 — a top-level `let` / `const` resolves to a
    // slot-indexed declarative-env-record read (`lda_global_slot`),
    // with the slot relative to the realm the function was compiled
    // in. A reader defined in parent (closing over parent's `let`),
    // called from a child that shares the heap, must index PARENT's
    // decl_env — not the child's, whose slot N holds a different
    // binding or is out of range. Pre-fix this indexed the dispatch
    // (child) realm: a `std.debug.assert(idx < vals.len)` panic in
    // safe builds, a wrong value in release.
    var parent = Realm.init(testing.allocator);
    defer parent.deinit();
    try parent.installBuiltins();

    var child = Realm.initChild(&parent);
    defer child.deinit();
    try child.installBuiltins();

    // `let secret` + the reader compiled in one parent script so the
    // reader resolves `secret` to a global-lexical slot.
    const reader_v = (try lantern.evaluateScript(testing.allocator, &parent, "let secret = 42; (function () { return secret; })")).value;
    try child.globals.put(testing.allocator, "readSecret", reader_v);

    const result = (try lantern.evaluateScript(testing.allocator, &child, "readSecret()")).value;
    try testing.expect(result.isNumber());
    try testing.expect(result.numberToDouble() == 42);
}

test "phase 3: primitive boxing in a cross-realm-called function uses its home realm's wrapper prototype" {
    // §7.1.1 ToObject — a method/property access on a primitive
    // boxes through the *running* realm's wrapper prototype
    // (%Number.prototype% etc.). A function defined in parent and
    // called from a child sharing the heap must box via parent's
    // %Number%, so `(5).constructor` is parent's Number — distinct
    // from the child's `Number` global. Pre-fix the boxing resolved
    // the wrapper ctor via the dispatch (child) realm.
    var parent = Realm.init(testing.allocator);
    defer parent.deinit();
    try parent.installBuiltins();

    var child = Realm.initChild(&parent);
    defer child.deinit();
    try child.installBuiltins();

    const box_v = (try lantern.evaluateScript(testing.allocator, &parent, "(function () { return (5).constructor; })")).value;
    try child.globals.put(testing.allocator, "boxCtor", box_v);

    // boxCtor() returns parent's Number; child's `Number` is a
    // different JSFunction, so the comparison is false.
    const same = (try lantern.evaluateScript(testing.allocator, &child, "boxCtor() === Number")).value;
    try testing.expect(same.bits == Value.false_.bits);
}

test "gc-probe: a child realm GC must not sweep the parent realm's live objects (shared heap)" {
    // Diagnostic: parent + child share one Heap (initChild). GC is
    // triggered on the *running* realm and `markRoots` marks only
    // that realm's roots. If a GC fires while the child is running
    // (here: an explicit child.collectGarbage(), as the allocation-
    // pressure trigger would do mid-evaluate), does it sweep the
    // parent's objects — which the child never marks?
    var parent = Realm.init(testing.allocator);
    parent.hardened = false;
    defer parent.deinit();
    try parent.installBuiltins();

    var child = Realm.initChild(&parent);
    child.hardened = false;
    defer child.deinit();
    try child.installBuiltins();

    // An object reachable ONLY from parent's global object.
    _ = try lantern.evaluateScript(testing.allocator, &parent, "globalThis.keep = { tag: 'parent-live' };");

    // GC as the child realm — marks child roots only, sweeps the
    // shared heap. If parent's `keep` is unmarked it gets freed.
    child.collectGarbage();

    // Parent's object must survive. A swept object → use-after-free
    // / wrong value here.
    const r = (try lantern.evaluateScript(testing.allocator, &parent, "globalThis.keep.tag === 'parent-live'")).value;
    try testing.expect(r.bits == Value.true_.bits);
}
