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
| D1 | **Intrinsics sharing** | **Copy-on-write, with shared frozen base under hardened posture.** Per-realm `intrinsics` struct; the *prototype objects* themselves are shared frozen heap allocations *iff* both realms run hardened (the SES guarantee — no mutation possible). Unhardened realms get full copies. | Memory: 1 KB per realm beats N×500 KB. Correctness: a hardened realm is by definition not mutating Object.prototype, so the prototype object can be physically shared. Unhardened can't share — mutation on one would leak to the other. |
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
