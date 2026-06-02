# Multi-realm — design & phased plan

Goal: Cynic supports **multiple coexisting `Realm` instances per
engine process**, with disciplined sharing of intrinsics, isolated
mutable state, and a typed `Compartment` API on top. Every phase
lands TDD-first — failing tests pinning the contract before any
production code goes in.

Sister doc to [ses-alignment.md](ses-alignment.md) (Compartments
sit on top of this), [handbook/environments.md](handbook/environments.md)
(the GlobalEnvironmentRecord split becomes per-realm), and
[handbook/gc.md](handbook/gc.md) (Metla roots become per-realm).
This doc is the durable plan — a fresh session should be able to
pick up the next phase from here without re-deriving the design.

## Current state (snapshot 2026-05-31)

| Phase | State | Landing commits |
|---|---|---|
| 0 — coexisting realms | ✅ pinned | `c174d06` |
| 1 — D1 intrinsics | ✅ **revised** → per-realm prototypes, shared shapes (Cynic already has the latter via per-`Heap` `ShapeTree` + `Realm.initChild`). The original "shared frozen prototype subgraph" is **forbidden, not deferred** per §6.1.7.4, §9.3.2, §20.1.3.1, §23.1.3.3 + five-engine consensus. | `ae847a8`, `0b4d2c7`, `6a00337` |
| 2 — D3 modules | ✅ substrate pinned (`Realm.modules` already per-instance); `StaticModuleRecord` deferred to Compartments | `928b4c3` |
| sibling — cross-realm error attribution | ✅ `CallFrame.running_realm` reads `callee.realm` so error makers attribute to the callee's realm; per-frame thread of attribution. Unblocked several test262 fixtures. | `b95694b` |
| 3 — D2 RealmStack + per-fn [[Realm]] | ✅ shipped — `[[Realm]]` set at native + ordinary function allocation; free-global resolution (read **and** write), Error-constructor intrinsics, and §23.1.3.34 ArraySpeciesCreate resolve via the executing function's realm (its `CallFrame.running_realm` / `active_native_fn_realm`), not the dispatch realm. All four Phase-3 contract tests in `realm_test.zig` green. | (multi-realm consumption effort) |
| 4 — D4 endowments | sketched | — |
| 5 — Compartments | sketched | — |
| 6 — per-realm teardown (memory lifecycle) | ✅ shipped — `Heap.realms` + `markAllSharingRealmRoots` (the global GC marks every sharing realm's roots; also a latent cross-realm UAF fix) + a ShadowRealm `HandleScope` fix, then the teardown finalizer: a collected `ShadowRealm` wrapper queues its child realm on `Heap.pending_realm_teardown` during the sweep and `Realm.drainRealmTeardown` frees it afterward (deferred; `created_by` back-link unlinks it from the owner's `child_realms`). Clean under `test262-safe --gc-threshold=1`. Compartments remain the only deferred piece. | (multi-realm teardown effort) |

The cross-realm-error commit `b95694b` reaches partway into D2 — `callee.realm` is already consumed for error attribution and native-callback realm tracking — but `JSFunction.realm` itself remains `null` at every allocation site because `Heap.allocateFunction*` doesn't take a realm parameter. Phase 3 closes that gap.

## Why now — the position statement

Cynic today exposes a single user-visible `Realm` per engine
process. The single-realm assumption is wired through dozens of
sites: every `builtin.install(realm)` call, the test262 harness's
`new Realm` ceremony, `intrinsics.install` (which freezes one set
of primordials), the GC's root walker (which knows about *the*
microtask queue), and the module cache (one map per process).

The doc [ses-alignment.md §Compartments — why deferred](ses-alignment.md#compartments--why-deferred)
explicitly punts multi-realm "until a real user pulls on it." The
trigger for *this* plan is: that pull arrived. Recording the
trigger here matters because the design choices below
(sharing-policy decision, endowment surface, the §10.2.4 species
plumbing) bias differently for different users — high-integrity
computation (Agoric-style), per-tenant host embedding, or a
hardened plugin system would each push the boundary in different
directions, and the phase plan below assumes a host-embedding
shape (per-tenant realms, identity-preserved interop, shared
intrinsics where memory-safe to share).

If a different concrete user pulls on this before the plan ships,
revisit § *Decisions up front* before phase 0 begins.

## Position relative to ses-alignment.md

```
                  ses-alignment.md                multi-realm.md
                  -----------------               ----------------
  Phase 1 ──► frozen primordials                  (depends on:)
  Phase 2 ──► harden() global                    
  Phase 3 ──► override-mistake fix
  Phase 4 ──► tame error stacks ────────►  Phase 0 (this doc)
  Phase 5 ──► [...]                       ───►  Phase 1 (this doc)
                                           ───►  Phase 2 (this doc)
                                           ───►  Phase 3 (this doc)
                                           ───►  Phase 4 (Compartment ctor)
                                           ───►  Phase 5 (test262 realm fixtures)
```

`ses-alignment.md`'s deferred Phase 7 (`Compartment` class) maps to
Phase 4 here — i.e. Compartments are this plan's *result*, not its
goal. The plan's goal is the substrate Compartments stand on. SES
Phase 8 (taming ambient state) lights up trivially once Phase 4
ships, because Compartments are the unit you tame against.

## What "multi-realm" means concretely

Three observable properties, in priority order:

1. **N user-visible `Realm` instances per engine process.** Each
   has its own `globalThis`, own `intrinsics` (potentially
   shared — see § Decisions), own module graph, own microtask
   queue, own per-realm SES posture flag, own `[[VarNames]]` set,
   own `print` / `console.log` output buffer.
2. **Spec-faithful cross-realm identity.** A function created in
   realm A retains realm A as its `[[Realm]]` even when called
   from realm B; `instanceof` across realms still works via the
   §23.1.3.34 `GetFunctionRealm` species carve-out, generalized
   from the partial form Cynic ships today.
3. **A typed endowment surface.** Cross-realm value passing
   preserves identity (an object passed A → B doesn't get
   copied), preserves frozenness, and propagates exceptions
   correctly. This is what the eventual `Compartment` constructor
   sits on.

Non-goals for this plan:

- **Per-realm JIT compilation scope.** When Bistromath / Ohaimark
  ship, the code-cache scoping decision is its own design doc.
  This plan stays interpreter-only (Lantern).
- **Concurrent execution across realms.** Realms coexist; only
  one runs at a time per OS thread. The microtask drain owner
  is the active realm.
- **Cross-process realms.** Realms live in a single process.
  Multi-process isolation is the embedder's job (Worker per
  process, etc.).

## Decisions up front (not deferrable to phases)

These four bind the rest of the plan. Each gets settled in the
ADR's *Decisions* section before phase 0 begins, because phasing
the implementation can't paper over a wrong call here.

| # | Decision | Choice | Why |
|---|---|---|---|
| D1 | **Intrinsics sharing** | ~~Copy-on-write, with shared frozen base under hardened posture.~~ **REVISED 2026-05-31 → Per-realm prototypes, shared shapes (already done).** Every realm allocates its own `%Object.prototype%` etc., matching V8 / JSC / SpiderMonkey. The shared substrate is the per-`Heap` `ShapeTree` (hidden-class tree), which `Realm.initChild` already shares with the parent. See "D1 revision" sub-section below. | Spec-correct: `Array.prototype.constructor === Array` would diverge under prototype sharing without RealmStack (a §9.4.1.1 violation) — and `.constructor` is a single slot on a single shared JSObject, not realm-aware. Production engines all picked per-realm prototypes for the same reason. Memory: the headline "100 realms ≈ 1 realm" was based on sharing prototype *objects*; the actual per-realm cost is constructors + prototype JSObjects + method JSFunctions, which is smaller than D1's original framing implied. |
| D2 | **"Current realm" tracking** | **Implicit + on every `JSFunction`.** Every function carries `[[Realm]]`. The "active realm" is `realm_stack.top()` — pushed on call-entry, popped on call-return. Native callbacks see `realm = call_site.callee.realm`, not the active one. | Spec-faithful (§9.4.1.1 `[[Call]]` reads the callee's realm). Implicit beats requiring `realm: *Realm` on every native — that breaks every existing builtin signature. |
| D3 | **Module graph scope** | **Per-realm by default; embedder can declare shared.** Each realm's `module_loader` callback resolves independently; the embedder *may* return a shared `ModuleRecord` for cross-realm modules (StaticModuleRecord-style), but identity is opt-in, not default. | Compartments want sharing for the SES initial-modules pattern; tenant isolation wants strictness. Both fall out of "the loader decides." |
| D4 | **Endowment surface** | **Plain `JSObject` passed at realm-construction time, deep-frozen by the engine on entry.** Endowments become installed-on-globalThis at realm init. No special "endowments" type — it's just an object the embedder hands in. | Matches `Compartment({ globals: { fetch: limitedFetch } })` shape. Frozen-on-entry stops the endowment-by-reference leak Bare and Agoric both warn about. |

Each row above is a future ADR section with the trade-offs spelled
out. The choices listed are the *current* recommendation; the
phase plan is written against them. If any decision flips, the
phase that depends on it inherits the rewrite.

## Phase 0 — coexisting `Realm` instances (foundation)

**Goal.** Two `Realm` structs can be instantiated in one process
without interference. No user-visible API yet — this is purely
structural: every site that assumes "the realm" gets audited and
parameterized.

**API additions (none user-visible).** `Realm.init` continues to
exist; nothing changes at the embedder level. Internal changes
only:

```zig
// src/runtime/realm.zig
pub fn init(...) !Realm { ... }            // unchanged signature
pub fn deinit(self: *Realm) void { ... }    // unchanged

// New invariant: every call into `*Realm`'s public API takes the
// realm explicitly. No `current_realm()` accessor at this phase;
// the active-realm tracker (D2) ships in phase 3.
```

**Failing tests — write these first** (`src/runtime/realm_test.zig`,
new file):

```zig
test "phase 0: two realms have distinct intrinsic pointers" {
    var ra = try Realm.init(testing.allocator);
    defer ra.deinit();
    var rb = try Realm.init(testing.allocator);
    defer rb.deinit();
    try intrinsics.install(&ra);
    try intrinsics.install(&rb);

    // Distinct heap objects, distinct globalThis.
    try testing.expect(ra.intrinsics.object_prototype != rb.intrinsics.object_prototype);
    try testing.expect(ra.globals.get("globalThis") != rb.globals.get("globalThis"));
}

test "phase 0: mutating ra's Array.prototype does not affect rb (unhardened)" {
    var ra = try Realm.init(testing.allocator);
    defer ra.deinit();
    var rb = try Realm.init(testing.allocator);
    defer rb.deinit();
    ra.hardened = false; rb.hardened = false;
    try intrinsics.install(&ra);
    try intrinsics.install(&rb);

    // Evaluate `Array.prototype.foo = 42` in ra.
    _ = try lantern.evaluateScript(testing.allocator, &ra,
        "Array.prototype.foo = 42;");

    // rb's Array.prototype must be untouched.
    const v = try lantern.evaluateScript(testing.allocator, &rb,
        "typeof Array.prototype.foo");
    try testing.expectEqualStrings("undefined", value_to_string(v));
}

test "phase 0: each realm has its own microtask queue" {
    var ra = try Realm.init(testing.allocator);
    defer ra.deinit();
    var rb = try Realm.init(testing.allocator);
    defer rb.deinit();
    try intrinsics.install(&ra);
    try intrinsics.install(&rb);

    // Queue a callback into ra; rb's queue must stay empty.
    _ = try lantern.evaluateScript(testing.allocator, &ra,
        "queueMicrotask(() => globalThis.__seen = true);");
    try testing.expect(ra.microtask_queue.items.len == 1);
    try testing.expect(rb.microtask_queue.items.len == 0);
}

test "phase 0: each realm has its own output buffer" {
    var ra = try Realm.init(testing.allocator);
    defer ra.deinit();
    var rb = try Realm.init(testing.allocator);
    defer rb.deinit();
    try intrinsics.install(&ra);
    try intrinsics.install(&rb);

    _ = try lantern.evaluateScript(testing.allocator, &ra,
        "print('hello from ra');");
    try testing.expect(std.mem.indexOf(u8, ra.output.items, "hello from ra") != null);
    try testing.expect(rb.output.items.len == 0);
}
```

**Implementation pointers.**

- Audit every `*Realm` consumer for accidental singleton
  assumptions. `rtk proxy grep -rn '\.global\.' src/` is the
  starting list — most sites read `realm.intrinsics` /
  `realm.heap` correctly already.
- `intrinsics.install(realm)` already takes the realm; verify
  it doesn't reach a process-global anywhere.
- The biggest probable surprise: the heap. Today `Realm.heap`
  is per-realm but its allocator is the host allocator. Verify
  GC root walks for realm A don't traverse realm B's roots
  (they shouldn't — root walking starts from the realm — but
  audit).

**Exit criteria.** All four tests above green. No new public
API. `zig build test262` regression: zero (single-realm callers
unchanged).

## Phase 1 — per-realm intrinsics with the D1 sharing policy

**Goal.** Realm initialization installs intrinsics correctly under
the D1 decision: hardened realms share prototype objects with each
other (memory win); unhardened realms get full copies.

**API additions.**

```zig
// src/runtime/intrinsics.zig
pub const IntrinsicsBase = struct {
    /// A pre-built, frozen intrinsics tree that hardened realms can
    /// reference instead of allocating their own. Built once per
    /// process, lifetime-managed by the host.
    object_prototype: *JSObject,
    array_prototype: *JSObject,
    // ... (every spec-defined prototype, frozen)
};

/// Install intrinsics into realm. If `base != null` and
/// `realm.hardened` is true, share `base`'s prototype objects
/// (D1 fast path). Otherwise allocate fresh, frozen-if-hardened.
pub fn installWithBase(realm: *Realm, base: ?*const IntrinsicsBase) !void;
```

**Failing tests — write these first**:

```zig
test "phase 1: two hardened realms share Object.prototype pointer (D1)" {
    var base = try intrinsics.buildBase(testing.allocator);
    defer base.deinit(testing.allocator);

    var ra = try Realm.init(testing.allocator);
    defer ra.deinit();
    ra.hardened = true;
    try intrinsics.installWithBase(&ra, &base);

    var rb = try Realm.init(testing.allocator);
    defer rb.deinit();
    rb.hardened = true;
    try intrinsics.installWithBase(&rb, &base);

    // Hardened sharing: same pointer.
    try testing.expect(ra.intrinsics.object_prototype == rb.intrinsics.object_prototype);
}

test "phase 1: hardened + unhardened do not share (D1)" {
    var base = try intrinsics.buildBase(testing.allocator);
    defer base.deinit(testing.allocator);

    var ra = try Realm.init(testing.allocator);
    defer ra.deinit();
    ra.hardened = true;
    try intrinsics.installWithBase(&ra, &base);

    var rb = try Realm.init(testing.allocator);
    defer rb.deinit();
    rb.hardened = false;  // unhardened can't share — would expose mutation
    try intrinsics.installWithBase(&rb, &base);

    try testing.expect(ra.intrinsics.object_prototype != rb.intrinsics.object_prototype);
}

test "phase 1: two unhardened realms each get distinct primordials" {
    var ra = try Realm.init(testing.allocator);
    defer ra.deinit();
    var rb = try Realm.init(testing.allocator);
    defer rb.deinit();
    ra.hardened = false; rb.hardened = false;
    try intrinsics.installWithBase(&ra, null);
    try intrinsics.installWithBase(&rb, null);

    try testing.expect(ra.intrinsics.object_prototype != rb.intrinsics.object_prototype);
}

test "phase 1: hardened-shared base survives realm deinit of one party" {
    var base = try intrinsics.buildBase(testing.allocator);
    defer base.deinit(testing.allocator);

    var ra = try Realm.init(testing.allocator);
    ra.hardened = true;
    try intrinsics.installWithBase(&ra, &base);

    // Snapshot the shared pointer.
    const shared = ra.intrinsics.object_prototype;
    ra.deinit();

    // A second realm using the same base must still see a valid
    // object_prototype — base owns lifetime, not ra.
    var rb = try Realm.init(testing.allocator);
    defer rb.deinit();
    rb.hardened = true;
    try intrinsics.installWithBase(&rb, &base);
    try testing.expect(rb.intrinsics.object_prototype == shared);
    // Accessing it must not segfault.
    try testing.expect(rb.intrinsics.object_prototype.hasOwn("toString"));
}
```

**Implementation pointers.**

- `IntrinsicsBase` is a frozen heap subgraph. Build once via a
  scratch `Realm`, freeze, extract the prototype pointers,
  retain the heap.
- Lifetime: `IntrinsicsBase` owns its heap; realm `deinit` must
  NOT deinit shared objects. Use a refcount or a single-owner
  pointer plus an "external" flag on heap allocations.
- The GC root walker (Metla) needs to know which objects are
  externally-owned: don't sweep them.
- Frozen state means the override-mistake-fix accessor pairs
  (`ses-alignment.md` Phase 3) are baked into the shared base.
  Re-verify under hardened sharing — the synthetic accessors are
  per-prototype, so they share too.

**Exit criteria.** Four tests above green. Sharing is observably a
memory win (a benchmark verifying RSS for N=100 hardened realms is
roughly RSS(1 realm) + small overhead). Existing single-realm
test262 sweep unchanged.

### Phase 1 implementation notes (added 2026-05-31)

Surveying today's `intrinsics.zig` (2,292 lines) + `heap.zig`
(4,031 lines) + `realm.zig` (1,617 lines) before writing code
turned up four implementation decisions that the high-level
plan above leaves implicit. Pinning them here so the
implementation commits can cite this section rather than
re-relitigating.

**(a) Sharing scope: prototypes only, NOT constructors.**

A constructor object closes over realm-specific state — most
visibly its `[[Prototype]]` and its `[[Realm]]` slot (§9.3.1),
but also its `.constructor` back-edge to a prototype that may
itself share state with the current realm's globals via
internal slot bookkeeping. Sharing the constructor function
object across realms would let realm A's `Error` constructor
observe realm B's globals through the back-edge, which breaks
both spec literally (each realm gets its own `%Error%`) and
isolation in practice.

`IntrinsicsBase` therefore shares only the *prototype
subgraph*: `%Object.prototype%`, `%Array.prototype%`,
`%Function.prototype%`, `%Error.prototype%`, the four typed-
error prototypes, `%Iterator.prototype%`, etc. — every slot in
`Intrinsics` whose Zig type is `?*JSObject`. Constructors
(`?*JSFunction` slots) are allocated per-realm and their
`.prototype` is set to the shared base's prototype object;
their `.constructor` back-edge is the per-realm constructor.
This matches QuickJS's "context-shared atoms" pattern and
JavaScriptCore's `JSGlobalObject`-per-realm-with-shared-
`Structure` design.

**(b) GC lifetime: a separate, non-collected heap.**

The "external" flag on heap allocations approach from the
original plan adds a per-object branch to Metla's sweep
walker, and the alternative — refcounting individual shared
objects — leaks the realm/heap boundary into every native
that touches a prototype.

Cleaner: `IntrinsicsBase` owns its own `Heap`, but flagged
`gc_disabled = true` (a single check at the top of
`Heap.collect`) so the sweep walker on a per-realm heap never
sees the shared objects in the first place. The shared heap
is constructed once at process startup via a scratch `Realm`,
frozen, and persisted for the lifetime of the host. Per-realm
heaps reference shared `*JSObject` pointers but never own or
sweep them.

This needs one heap-level change: shape pointers, hidden-
class transitions, and the (shipped) lazy-property-bag layer
all need to tolerate a `*JSObject` whose `heap` field points
to the shared base. Today every code path assumes one heap
per realm; the audit pass surfaces every site that calls back
into `obj.heap.<X>` and confirms it's safe across heaps (or
refactors to take an explicit heap parameter).

**(c) Symbols are shared too.**

Well-known symbols (`Symbol.iterator`, `Symbol.asyncIterator`,
`Symbol.toPrimitive`, …) are spec-literally per-realm but
observably interchangeable — they're identity-distinct in
`a === b` only because §6.1.5 specifies fresh values per
realm. Production engines vary: V8 ships shared, JSC ships
shared, SpiderMonkey ships per-realm. Cynic ships shared
under `IntrinsicsBase` to keep the cross-realm `for…of`
ergonomic; the spec text doesn't observably differ for any
code that doesn't reach into two realms' `Symbol.iterator`
and compare them with `===`, and the practical wins (one
allocation for the most-used pseudo-private slot key in the
language) are large.

**(d) Override-mistake accessors travel with the prototype.**

`ses-alignment.md` Phase 3 wires synthetic accessor pairs
onto every frozen prototype slot so `obj.x = 2` shadows
instead of throwing. The accessors are *per-slot, per-
prototype* — not realm-aware — so once they're baked into
the shared prototypes inside `IntrinsicsBase` they share for
free. The Phase 1 verification needs a regression test for
the override-mistake fix triggered from realm A against a
prototype shared with realm B; if the synthetic getter/setter
is on the shared graph, both realms see the same fix.

**Test scaffold landing order — ~~original plan~~ (superseded; see D1 revision below).**

1. ~~Land `src/runtime/intrinsics_phase1_test.zig` with the
   four ADR tests + override-mistake regression. Stubs for
   `IntrinsicsBase`, `buildBase`, `installWithBase` go in
   `intrinsics.zig`; `installWithBase` delegates to today's
   `install` and ignores `base`. Tests 1 + 4 + 5 go red.~~
   *(Landed in `007182c`. Steps 2-6 superseded.)*
2. ~~Wire the separate-heap (`gc_disabled`) machinery.~~
   *(Landed in `e90d406`. The `gc_disabled` knob remains
   useful for any future "stable scratch heap" use case.)*
3. ~~Build the frozen prototype subgraph, return
   `IntrinsicsBase`.~~ *(Landed in `340438e`. The pre-built
   subgraph still exists in code but no per-realm install
   adopts it — it's dead weight pending the D1 revision.)*
4. ~~Rewrite `installWithBase` to adopt shared pointers
   under hardened + non-null base.~~ **BLOCKED.** Threading
   sharing through `install` requires either accepting
   stale `.constructor` back-edges (off-spec per §22.1.3)
   or having a `RealmStack` to make `.constructor` a
   realm-aware accessor. The latter is Phase 3 work. See
   "D1 revision" below for the resolution.
5. ~~RSS benchmark.~~ *(Skipped — the memory win disappears
   once D1 is revised away.)*
6. ~~Test262 sweep stays unchanged.~~ *(Unchanged but for
   different reasons — see revision.)*

### D1 revision — drop prototype sharing, match production engines (added 2026-05-31)

The original D1 promised "100 hardened realms ≈ RSS of 1
realm" via a shared, frozen prototype subgraph. Implementing
step 4 surfaced a §22.1.3 spec violation that the original
plan didn't account for: `Array.prototype.constructor` is a
single property slot on a single JSObject, so a shared
`%Array.prototype%` can only resolve `.constructor` to *one*
constructor — but every realm needs to see *its own*
`Array`. Making `.constructor` a realm-aware accessor
requires knowing the *calling* realm at property-read time,
which is D2's `RealmStack` (originally Phase 3 work, not a
Phase 1 prerequisite). The original plan had the dependency
upside-down.

Prior-art check (added retroactively — should have led the
ADR):

- **V8** — each native context (≈ realm) allocates its own
  intrinsics. Hidden classes (`Map`) are shared at the isolate
  level. No prototype sharing across contexts.
- **JavaScriptCore** — each realm has its own
  `JSGlobalObject` carrying its intrinsics. `Structure`
  (hidden class) is shared at the VM level. No prototype
  sharing.
- **SpiderMonkey** — same posture. Per-realm prototypes,
  shared `Shape` trees.

The substrate every shipping engine actually shares is
*shape information*, not prototype objects. Cynic already
ships this: `Heap.shapes` is a per-`Heap` `ShapeTree`, and
`Realm.initChild` shares the heap (`realm.zig:951`) — so
child realms already share shapes with their parent today.
The "agent-scoped, like a V8 Isolate's Maps" comment on
the `shapes` field calls this out explicitly.

**Resolution.** D1 is revised to: **each realm allocates
its own prototypes; the shared substrate is the per-Heap
`ShapeTree`.** This matches every production engine, removes
the spec dependency on RealmStack, and lets Phase 1 close
with steps 1-3 already landed plus a small follow-up commit
that removes the now-dead `IntrinsicsBase` / `buildBase` /
`installWithBase` plumbing.

What changes on `main`:

- `IntrinsicsBase` + `buildBase` + `installWithBase` get
  retired (the slot snapshot + scratch realm aren't used by
  anything that escapes the test file).
- `Heap.gc_disabled` stays — it's a generally useful knob
  (an embedder pinning a known-immutable subgraph for some
  other reason; future "snapshot" support).
- The two skipped tests in `intrinsics_phase1_test.zig`
  get removed; the three passing ones (hardened+unhardened
  distinct, two-unhardened distinct, override-mistake fix)
  fold into `realm_test.zig` because they're now just D1-
  revised contracts ("per-realm prototypes always") and
  no longer need their own file.
- A new Phase 1' goal: confirm shape-tree sharing across
  `initChild` realms via a regression test (allocate the
  same object shape in parent + child, assert the shape
  pointer is identical).

What carries forward unchanged:

- Phases 2-5 still depend on D2 / D3 / D4; their text is
  unaffected.
- Phase 0 (coexisting realms) was the real foundation; it
  stays as-is.

## Phase 2 — per-realm module graph

**Goal.** Each realm resolves modules through its own
`module_loader` callback by default; the embedder may declare
shared modules across realms via the StaticModuleRecord-shaped
API. Today's `Realm.module_loader` becomes per-realm naturally
(it's already per-instance), but the *cache* is currently per-
process; this phase splits it.

**API additions.**

```zig
// src/runtime/module.zig

pub const StaticModuleRecord = struct {
    /// The Realm-independent compiled-once record. Embedders
    /// can hand the same instance to multiple realms; the engine
    /// will instantiate per-realm namespace exotics from it.
    chunk: *const Chunk,
    requested_modules: []const []const u8,
    // ... (the §16.2.1.4 Cyclic Module Record fields that don't
    // depend on the loading realm)
};

pub fn createModuleFromStatic(realm: *Realm, smr: *StaticModuleRecord) !*ModuleRecord;
```

**Failing tests — write these first**:

```zig
test "phase 2: same specifier in distinct realms resolves to distinct ModuleRecords by default" {
    var ra = try Realm.init(testing.allocator);
    defer ra.deinit();
    var rb = try Realm.init(testing.allocator);
    defer rb.deinit();
    try intrinsics.install(&ra);
    try intrinsics.install(&rb);

    // Both realms have a loader that returns the same source.
    ra.module_loader = simpleSourceLoader(.{ "./mod.js" = "export const x = 42;" });
    rb.module_loader = simpleSourceLoader(.{ "./mod.js" = "export const x = 42;" });

    const mod_a = try lantern.loadModule(testing.allocator, &ra, "./mod.js", null);
    const mod_b = try lantern.loadModule(testing.allocator, &rb, "./mod.js", null);

    try testing.expect(mod_a.mr.? != mod_b.mr.?);  // distinct records
}

test "phase 2: embedder-declared shared StaticModuleRecord yields distinct namespaces but shared chunk" {
    var smr = try compileStatic("./shared.js", "export const x = 1;");
    defer smr.deinit();

    var ra = try Realm.init(testing.allocator);
    defer ra.deinit();
    var rb = try Realm.init(testing.allocator);
    defer rb.deinit();
    try intrinsics.install(&ra);
    try intrinsics.install(&rb);

    const mr_a = try module.createModuleFromStatic(&ra, &smr);
    const mr_b = try module.createModuleFromStatic(&rb, &smr);

    // Same compiled chunk (memory win)…
    try testing.expect(mr_a.chunk == mr_b.chunk);
    // …distinct namespace exotic objects (identity per realm).
    try testing.expect(mr_a.namespace != mr_b.namespace);
}

test "phase 2: module errored in realm A doesn't poison realm B" {
    var ra = try Realm.init(testing.allocator);
    defer ra.deinit();
    var rb = try Realm.init(testing.allocator);
    defer rb.deinit();
    try intrinsics.install(&ra);
    try intrinsics.install(&rb);

    ra.module_loader = simpleSourceLoader(.{ "./mod.js" = "throw new Error('a-only');" });
    rb.module_loader = simpleSourceLoader(.{ "./mod.js" = "export const ok = true;" });

    const a_outcome = try lantern.loadModule(testing.allocator, &ra, "./mod.js", null);
    try testing.expect(a_outcome.threw);

    const b_outcome = try lantern.loadModule(testing.allocator, &rb, "./mod.js", null);
    try testing.expect(!b_outcome.threw);
}
```

**Implementation pointers.**

- `Realm.modules` (the cache) is already per-realm. Confirm no
  process-global module cache leaked through (e.g. in
  `intrinsics.zig`).
- `StaticModuleRecord` separates the *compiled* chunk from the
  *per-realm* `ModuleRecord` that carries the namespace and the
  environment. This mirrors §16.2.1.4 and SES's StaticModuleRecord.
- TLA: the per-realm evaluation Promise lives on the per-realm
  `ModuleRecord`, not the shared `StaticModuleRecord`. Cycles
  involving shared records but distinct realm namespaces must
  not deadlock.

**Exit criteria.** Three tests above green. Test262 module
fixtures unchanged. Memory: N realms loading the same shared
module use one chunk allocation, N namespace objects.

## Phase 3 — cross-realm Function identity + active-realm tracking (D2)

**Goal.** A function created in realm A retains realm A as its
`[[Realm]]` when called from realm B. §10.2.4 `OrdinaryFunctionCreate`
and §10.2.3 `[[Call]]` honor the function's realm, not the caller's.
This is what makes cross-realm `instanceof`, species, and exception
classification work.

**API additions.**

```zig
// src/runtime/function.zig
pub const JSFunction = struct {
    // ... existing fields ...

    /// §10.2.4 OrdinaryFunctionCreate step 8 — the function's
    /// realm. Set at creation, frozen for life. Used by §10.2.3
    /// step 2 (`callerContext` switches to callee's realm).
    realm: *Realm,
};

// src/runtime/realm.zig
pub const RealmStack = struct {
    /// Push on call entry, pop on call exit. `top()` is the
    /// active realm. Native callbacks read `callee.realm`
    /// directly — they do NOT consult `top()`.
    ...
};
```

**Failing tests — write these first**:

```zig
test "phase 3: function created in ra has ra as [[Realm]] even when called from rb" {
    var ra = try Realm.init(testing.allocator);
    defer ra.deinit();
    var rb = try Realm.init(testing.allocator);
    defer rb.deinit();
    try intrinsics.install(&ra);
    try intrinsics.install(&rb);

    // Create a function in ra.
    const f_v = try lantern.evaluateScript(testing.allocator, &ra,
        "(function f() { return 1; })");
    const f = heap_mod.valueAsFunction(f_v).?;
    try testing.expect(f.realm == &ra);

    // Hand f to rb (mechanism: embedder passes the value across).
    try rb.globals.put(testing.allocator, "fromA", f_v);

    // Call from rb. f's [[Realm]] must still be ra.
    _ = try lantern.evaluateScript(testing.allocator, &rb, "fromA();");
    try testing.expect(f.realm == &ra);
}

test "phase 3: error thrown by ra's code is instanceof ra.Error, not rb.Error" {
    var ra = try Realm.init(testing.allocator);
    defer ra.deinit();
    var rb = try Realm.init(testing.allocator);
    defer rb.deinit();
    try intrinsics.install(&ra);
    try intrinsics.install(&rb);

    const thrower_v = try lantern.evaluateScript(testing.allocator, &ra,
        "() => { throw new Error('from ra'); }");
    try rb.globals.put(testing.allocator, "boom", thrower_v);

    // §10.2.3 §10.2.4: the Error must be ra's Error, not rb's.
    const probe = try lantern.evaluateScript(testing.allocator, &rb,
        "try { boom(); } catch (e) { e.constructor === Error; }");
    try testing.expect(value_as_bool(probe) == false);  // rb's Error !== ra's Error
}

test "phase 3: §23.1.3.34 species across realms — Array.prototype.map" {
    // From ra, an Array created in ra, mapped to a new array — that
    // new array must use ra's %Array% as its species, not rb's.
    var ra = try Realm.init(testing.allocator);
    defer ra.deinit();
    var rb = try Realm.init(testing.allocator);
    defer rb.deinit();
    try intrinsics.install(&ra);
    try intrinsics.install(&rb);

    const arr_v = try lantern.evaluateScript(testing.allocator, &ra, "[1, 2, 3]");
    try rb.globals.put(testing.allocator, "arrA", arr_v);

    const probe = try lantern.evaluateScript(testing.allocator, &rb,
        "const m = arrA.map(x => x*2); m.constructor === Array;");
    try testing.expect(value_as_bool(probe) == false);
}

test "phase 3: native callback sees its function's realm, not the caller's" {
    var ra = try Realm.init(testing.allocator);
    defer ra.deinit();
    var rb = try Realm.init(testing.allocator);
    defer rb.deinit();
    try intrinsics.install(&ra);
    try intrinsics.install(&rb);

    // Install a native that returns its own callee.realm.
    var observed_realm: ?*Realm = null;
    const native = struct {
        fn cb(state: *NativeState) Value {
            observed_realm.?.* = state.callee.realm;
            return Value.undefined_;
        }
    }.cb;
    try ra.globals.installNative("probe", native);

    try rb.globals.put(testing.allocator, "probeFromA", ra.globals.get("probe"));
    _ = try lantern.evaluateScript(testing.allocator, &rb, "probeFromA();");

    try testing.expect(observed_realm == &ra);
}
```

**Implementation pointers.**

- Add `realm: *Realm` to `JSFunction`. Every function-creation
  site sets it: `OrdinaryFunctionCreate` (parser-level), bound
  function (the bound target's realm), native (the installer's
  realm).
- `RealmStack` lives on the engine (not on a single realm).
  `lantern.runFrames` pushes the callee's realm on call entry,
  pops on return. Native callbacks read `callee.realm`
  directly — they MUST NOT consult `RealmStack.top()` (D2).
- §10.2.3 step 2 (`callerContext` switches realm) is the trigger.
- §23.1.3.34 species: already has partial implementation; this
  phase makes it work across user-visible realms.
- Cross-realm exceptions: the thrown value's `[[Prototype]]` is
  the throwing realm's `Error.prototype`. Don't rewrite it on
  the boundary.

**Exit criteria.** Four tests above green. `proto-from-ctor-realm*`
skips in `tools/test262/skip.zig` (currently in
`single_realm_exact_paths`) can be removed; verify they pass.
Test262 `ShadowRealm` bucket scores ≥ the current `--enable=ShadowRealm`
gated row.

### Phase 3 implementation plan (added 2026-05-31)

Pre-plan survey, grounded in the actual code:

- **`JSFunction.realm: ?*Realm = null`** — already declared at
  `src/runtime/function.zig:177`. The doc comment explicitly
  flags it as "backward-compat for callers that haven't been
  threaded through yet."
- **109 `Heap.allocateFunction*` call sites** across ~30 files.
  Every one already has a `realm: *Realm` in lexical scope —
  call sites read `realm.heap.allocateFunction(...)`. The
  refactor to thread `realm` is mechanical.
- **`b95694b` already consumes `callee.realm`** in three places
  (`src/runtime/lantern/call.zig` lines ~800, 874, 960):
  `Realm.active_native_fn_realm` for native callbacks,
  `CallFrame.running_realm` for error attribution. Phase 3
  finishes the consumption side once 3.2 lands the production
  side.
- **Tests must use `Realm.initChild`**, not two independent
  `Realm.init` instances. Cross-realm value sharing without a
  shared heap is unsound (the value's pointer lives in the
  source realm's heap; the target realm's GC can't trace it
  safely). `initChild` is also what `ShadowRealm` uses
  internally, so the tests double as the spec-correct cross-
  realm boundary contract. The doc tests above (lines 668-749)
  predate this realization and use two `Realm.init` — they are
  retained as historical design sketches; the actual landed
  tests will mirror `realm_test.zig`'s `initChild` pattern.

#### Commit-by-commit landing order

| # | Title | Files | Test Δ | Risk |
|---|---|---|---|---|
| 3.1 | Phase 3 contract tests, gated | `src/runtime/realm_test.zig` | +4 (skipped pending 3.3) | Low — TDD pattern matched in Phase 0/1/2 |
| 3.2 | Thread `realm` through `Heap.allocateFunction*` | `heap.zig` + `function.zig` + ~28 builtin/class/intrinsic/lantern files | 0 (mechanical) | Bootstrap edge: `Heap.allocateFunction` runs *during* `intrinsics.install` before `realm.heap.function_prototype` is set. Decision (b) below. |
| 3.3 | Wire `RealmStack` + un-skip tests | `realm.zig` (RealmStack type), `lantern/call.zig`, `builtins/array.zig` (species §23.1.3.34), `builtins/error.zig` (classification §10.2.3) | +4 turn green | The "natives must read `callee.realm`, NOT `RealmStack.top()`" invariant — audit every existing native callback to confirm none consult a global current-realm accessor. |
| 3.4 | Remove `proto-from-ctor-realm-*` skiplist; refresh score row | `tools/test262/skip.zig`, `test262-results.md` | +N test262 passes (≈40-80 by skiplist comment) | Negative Δ blocks; if any fixture regresses, file a pragmatist finding before unblocking. |
| 3.5 | Graduate `ShadowRealm` to default-on | `src/runtime/features.zig`, `src/runtime/builtins/shadow_realm.zig` | ShadowRealm fixtures move from gated phase to main phase | Low if 3.3 lands correctly. Recommended to land with Phase 3 since 3.3 is the natural enabling commit. |

Total scope: ~5 commits, the largest (3.2) is purely
mechanical, the highest-risk (3.3) is bounded by an explicit
invariant audit.

#### Decisions to ratify before commit 3.1

These are the four open questions the plan rests on. Resolve
in a session-opening discussion or fold into the first
commit's design comment:

(a) **`RealmStack` ownership.** Per-engine or per-`Heap`?
  Recommendation: **per-`Heap`.** Rationale: `Realm.initChild`
  shares a heap; tying the call stack to the heap matches the
  structural reality that the realms sharing a stack are the
  realms that can legitimately exchange Values.

(b) **`Heap.allocateFunction*` signature.** Required `*Realm`
  or optional `?*Realm` for the bootstrap edge? Recommendation:
  **`?*Realm`**, with a debug-assert that confirms non-null
  outside the `intrinsics.install` bootstrap window. The early
  prototype-creation path inside `intrinsics.install` cannot
  pass a real realm pointer to `allocateFunction` because the
  realm's `intrinsics.function_prototype` doesn't exist yet —
  forcing `*Realm` here would either require a two-pass init
  or a sentinel realm.

(c) **RED-then-GREEN split.** Single commit (tests + impl
  together) or gated-then-flip (3.1 lands skipped tests, 3.3
  unskips)? Recommendation: **gated-then-flip.** Matches the
  Phase 1 step 1 pattern (`007182c`) — CI bisect cleanly walks
  the design surface separately from the implementation.

(d) **3.5 timing.** Graduate ShadowRealm in Phase 3's
  closing commit or split to Phase 5? Recommendation: **with
  Phase 3.** Commit 3.3 is what makes ShadowRealm
  spec-conformant; graduating it is the natural exit criterion,
  not a follow-up.

#### Pragmatist re-audit triggers

The pragmatist MCP (sibling spec-auditing project; see local
notes) is the right tool to validate cross-engine spec
behaviour when something looks off. Triggers during Phase 3:

- **Negative test262 Δ in 3.4.** Any fixture that regresses
  on the `proto-from-ctor-realm-*` skiplist removal should be
  cross-checked against engine262, V8, JSC, SM before any
  unblock heuristic.
- **Cross-realm exception flip outside `Error.prototype`.** If
  3.3's exception-classification change affects
  `AggregateError`, `SuppressedError`, or any typed Error
  subclass differently from `Error` itself, audit
  §20.5.5–§20.5.8 first.

## Phase 4 — Compartment constructor (the SES API)

**Goal.** A user-visible `Compartment` constructor that wraps
phases 0-3 into the API shape SES users expect:

```js
const c = new Compartment({
    globals: { fetch: limitedFetch },     // D4: deep-frozen on entry
    modules: { './shared': sharedSMR },   // D3: shared StaticModuleRecord
});
c.evaluate('await fetch("/api")');
```

**API additions.**

```zig
// src/runtime/builtins/compartment.zig (new file)
pub fn install(realm: *Realm) !void {
    // %Compartment% intrinsic. Constructor allocates a fresh
    // child Realm under the current process; new realm inherits
    // the parent's hardened posture.
}
```

**Failing tests — write these first**:

```js
// In src/runtime/lantern/tests.zig, as JS fixtures evaluated via
// the bench-style script harness.

test "phase 4: Compartment ctor creates a new realm with own globalThis" {
    try expectScriptInt(
        \\const c = new Compartment({});
        \\c.evaluate("globalThis !== globalThis_outer");  // we wire globalThis_outer pre-test
    , 1);
}

test "phase 4: Compartment endowments visible inside" {
    try expectScriptInt(
        \\const c = new Compartment({ globals: { x: 42 } });
        \\c.evaluate("x");
    , 42);
}

test "phase 4: Compartment endowments are frozen on entry (D4)" {
    try expectScriptThrows(
        \\const obj = { x: 1 };
        \\const c = new Compartment({ globals: { obj } });
        \\c.evaluate("obj.x = 2;");  // throws — endowment frozen on entry
    , "TypeError");
}

test "phase 4: outside-frozen object stays frozen inside" {
    try expectScriptBool(
        \\const obj = Object.freeze({ x: 1 });
        \\const c = new Compartment({ globals: { obj } });
        \\c.evaluate("Object.isFrozen(obj)");
    , true);
}

test "phase 4: Compartment shared StaticModuleRecord" {
    try expectScriptInt(
        \\const smr = new StaticModuleRecord("export const x = 7;");
        \\const c = new Compartment({ modules: { './shared': smr } });
        \\const ns = await c.import('./shared');
        \\ns.x;
    , 7);
}
```

**Implementation pointers.**

- `Compartment` is an exotic object whose internal slot is a
  child `Realm` pointer. Allocate the child realm with the
  parent's `IntrinsicsBase` (D1 sharing).
- `.evaluate(source)` calls `lantern.evaluateScript` on the
  child realm.
- `.import(specifier)` returns a Promise that resolves to the
  namespace via the child realm's `module_loader`.
- Endowment freezing (D4): walk the endowments object on entry,
  apply `harden()` — same deep-freeze the global `harden()` does.
- StaticModuleRecord constructor: parse + compile the source
  *once*; the chunk becomes the shared body. Phase 2's
  `createModuleFromStatic` is what each compartment uses.

**Exit criteria.** Five tests above green. SES test262 fixtures
under `built-ins/Compartment` (when test262 ships them) score
nonzero. The `Compartment` row in
`docs/handbook/ses-test262-policy.md` flips from "deferred" to
shipped.

## Phase 5 — test262 realm-related fixtures back in scope

**Goal.** Reactivate the test262 fixtures Cynic skips today
because it can't synthesize a cross-realm scenario.

**Skiplist removals** (these come out of `tools/test262/skip.zig`
once phases 0-4 ship — one removal per phase):

```zig
// Phase 0+1: prove the `proto-from-ctor-realm*` family compiles
// and runs even though the harness's `$262.createRealm` is still
// a stub — at this point Cynic has the *capability*, just not the
// host hook.

// Phase 3: $262.createRealm gets a real implementation. The full
// `single_realm_path_contains` list comes out.
//   - "proto-from-ctor-realm-"
//   - "cross-realm-"
//   - "SharedArrayBuffer/cross-realm"
//   - the §23.1.3.34 species-across-realms cluster

// Phase 4: ShadowRealm gating relaxes from --enable to default-on
// (matches the published spec edition). The shadow_realm
// `FeatureFlag` variant is removed from `src/runtime/features.zig`.
```

**Tests as score-row contracts.** Each phase exit, the test262
sweep row in `test262-results.md` must show a Δ pass ≥ the
fixture count that came out of the skiplist. Negative Δ means a
regression — block the phase.

**Exit criteria.** Skiplist's `single_realm_path_contains` is
empty. `ShadowRealm` removed from `FeatureFlag`. The runtime
sweep gains ~N fixtures (count TBD per submodule version).

## Out of scope (deferred or rejected)

| | Why |
|---|---|
| **Per-realm JIT scope** (Bistromath / Ohaimark) | The JITs aren't shipped. Code-cache scoping decision is its own ADR when the tiers land. |
| **Concurrent execution across realms** | Realms coexist; only one runs at a time per OS thread. Multi-threaded JS is its own design. |
| **Cross-process realms** | Process boundary is the embedder's job (Worker per process, etc.). |
| **Per-realm GC** (separate heaps) | Single heap, multiple roots — what we already have, scaled. Per-realm heaps would be a Mark IV change. |
| **Realm-scoped intrinsic mutation under hardened** | D1 forbids it (sharing requires immutability). An embedder that wants per-realm intrinsic patches uses unhardened realms. |
| **The full eval-implementation work** for `--allow=eval` | Independent track ([ses-alignment.md](ses-alignment.md) calls this out). Compartments don't require eval. |

## Sister docs

- [ses-alignment.md](ses-alignment.md) — SES baseline + Compartments
  deferral rationale this plan inherits and unblocks.
- [handbook/environments.md](handbook/environments.md) — the
  GlobalEnvironmentRecord split becomes per-realm in phase 0.
- [handbook/gc.md](handbook/gc.md) — Metla's root walker becomes
  per-realm in phase 0; the `IntrinsicsBase` sharing in phase 1
  introduces externally-owned heap objects the sweep must respect.
- [handbook/tdd.md](handbook/tdd.md) — every phase opens with the
  failing tests above; production code follows.

## Phase 6 — per-realm teardown (memory lifecycle)

Phases 0–3 make multiple realms *coexist and interoperate*
correctly on a shared `Heap`. They do not address what happens
to a child realm's memory when it dies. Two distinct problems,
both real, surfaced while validating Phase 3:

1. **Child-realm lifecycle isn't tied to its owning object.**
   A child `Realm` (`$262.createRealm()` / `new ShadowRealm()`)
   is appended to `parent.child_realms` at creation and freed
   only in the parent's `deinit` — i.e. at program end. There is
   no finalizer when the owning `ShadowRealm` JS object is
   collected. A long-running host that mints a ShadowRealm
   per request therefore accumulates child `Realm` records —
   each carrying its own intrinsics + globals maps — **without
   bound**. This is a genuine leak, not just delayed reclamation.

2. **Child heap objects aren't eagerly reclaimed.** Children
   borrow the parent's `Heap` (`initChild`: `owns_heap = false`),
   whose object pools (`objects_young` / `objects_mature`) are
   **flat and untagged by realm**. A dead child's objects persist
   until the next parent GC sweeps them as unreachable — bounded
   bloat between collections, not a permanent leak.

**Prior-art survey (2026-06) revised the design.** No major
engine uses a per-object realm tag + a scoped per-realm sweep:

- **V8** — one heap per Isolate shared across Contexts; a single
  global GC marks every live Context's roots and reclaims a dead
  Context's objects when they become unreachable. No per-object
  realm field; detached-context *leaks* are a diagnostics concern,
  not eagerly swept.
- **JavaScriptCore** — one heap per VM; an object's realm is found
  via its (shared) Structure's `globalObject()`, not a per-object
  field; single global GC.
- **SpiderMonkey** — the only engine with genuine per-realm GC,
  achieved by **zone-partitioned allocation**: the object's
  arena/chunk header identifies its Zone, so realm is O(1) from the
  address (zero per-object cost) and a zone-local GC sweeps only
  that zone's arenas.

Cynic's shared flat-pool heap already matches the **V8/JSC shape**,
so the right design is the V8/JSC one — *not* the per-object-tag +
scoped-sweep this section originally sketched (which matches no
engine). That means problem #2 needs **no** new mechanism beyond
making the global GC mark every sharing realm's roots.

**Foundation — shipped (and it was a latent UAF fix, not just a
teardown prerequisite).** The collector triggered on the *running*
realm and marked only its roots, but all sharing realms put objects
in the same pools — so a GC during a child realm's execution swept
the parent's live objects (and vice-versa): a cross-realm
use-after-free, confirmed by the 0xaa free-poison under
`test262-safe`. Fixed by `Heap.realms` (the set of realms sharing
the heap) + `markAllSharingRealmRoots`, which marks every sharing
realm's roots before the single sweep — V8's global-GC model.
Realms register at `installBuiltins` and deregister at `deinit`
(`Realm.registerWithHeap` / `deregisterFromHeap`). A companion fix
anchors the ShadowRealm wrapped function across CopyNameAndLength
(a separate missing `HandleScope`). With both, the ShadowRealm
phase runs clean under `test262-safe --gc-threshold=1`.

This **dissolves problem #2**: once a dead child is deregistered,
its now-unreachable objects are reclaimed by the next ordinary GC —
the V8/JSC behaviour, no per-object tag, no scoped sweep.

**ShadowRealm finalizer — shipped.** When the sweep frees a
`is_shadow_realm` object, `Heap.queueShadowRealmTeardown` reads its
`host_data` child realm (before `deinitFields` drops the extension) and
queues it on `Heap.pending_realm_teardown`; `Realm.drainRealmTeardown`
empties that queue *after* `collectFull` / `collectYoung` return —
deferred, because freeing a `Realm` (its globals/intrinsics maps point at
heap objects the sweep is mid-walk over) is reentrant heap mutation. The
drain unlinks the child from its `created_by.child_realms` (so the
eventual parent `deinit` doesn't double-free), then `deinit` + `destroy`.
Both object free paths are hooked (`sweepList` for mature,
`promoteYoungList` for young); a failed enqueue (OOM) falls back to the
parent-`deinit` free. The child's heap objects survived this cycle (it
was still registered when roots were marked); once `deinit` deregisters
it, the next GC reclaims them.

Of the two candidate designs originally weighed — the sweep-hook + drain
above vs. reusing the `FinalizationRegistry` job machinery — the
sweep-hook one shipped: self-contained, no entanglement with the
user-facing FR code, and verified clean under `test262-safe
--gc-threshold=1`. `$262.createRealm` children (no wrapper object) are
never enqueued and keep their parent-`deinit` lifetime.

**Still open (optional):** a "N short-lived ShadowRealms in a loop"
bench asserting steady-state RSS is flat across iterations.

The per-object realm tag and scoped sweep from the original sketch
are **dropped** — over-engineering vs. what V8/JSC do. SpiderMonkey-
style zone-partitioned allocation remains a "someday, if per-realm
GC *latency* ever matters" option; it is a large allocator
restructure, not warranted now.

**Test-first contracts** (gated, like every other phase):

- A `ShadowRealm` created, used, then dropped and GC'd frees its
  child `Realm` record (probe: `parent.child_realms.items.len`
  returns to baseline after collection).
- A child value still referenced by the parent (a wrapped
  function) survives the child's teardown sweep — no
  use-after-free under `test262-safe`.
- Steady-state RSS over a create/drop loop is bounded.

**Dependency note.** This phase is orthogonal to Compartments
(Phase 5) but shares the realm-id tagging; landing it first gives
Compartments a teardown story for free.

## Verification cadence

- `zig build test` after each phase — unit-level guarantees.
- `zig build test262 -- --quiet` after each phase — regression
  check. Any negative `Δ pass` blocks the phase.
- `zig build bench` after phase 1 — measure RSS for N=100
  hardened realms (sharing target: < 1.5× single-realm RSS).
- `zig build bench` after phase 3 — measure call-overhead under
  cross-realm calls (regression target: < 2× single-realm call).
- `zig build test262 -- --filter=ShadowRealm --quiet` after
  phase 3 — confirms gated row collapses into default-on row.
