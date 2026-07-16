# Inline property caches — design & remaining work

Goal: collapse property access from a per-`.x` hashtable lookup to a
guarded one-compare-one-load. ROADMAP "Performance" called this the
single biggest interpreter win; the `prop_access` micro-bench
(~49 ms, ~3× behind QuickJS-NG pre-IC) was the headline target.

The monomorphic interpreter IC is shipped — see *Shipped* below.
This doc is the durable reference for what's done, the design
decisions behind it, and what's left on the IC frontier.

## Approach

Two pieces, in order:

1. **Shapes** (hidden classes / structures) — a transition tree
   describing each object's named-property layout. Self / V8
   lineage (Chambers & Ungar); `Shape = (parent, key, attrs,
   slot)`. Necessary substrate; on its own it doesn't speed
   up reads.
2. **Monomorphic inline cache** — per-callsite cached cell;
   the read becomes `if obj.shape == cell.shape: load
   slots[cell.slot]`.

Target model was **Hermes**: shapes + a monomorphic interpreter
IC. Bistromath — the baseline JIT, behind `--jit` — now reads the
same cells as data (the docs/jit.md §4.4 design), so one IC
substrate serves both tiers unchanged. Polymorphic ICs stay
deliberately out of scope: their consumer is Ohaimark-tier
speculation (docs/jit.md §5); revisit when that ADR lands or when
profiling shows polymorphic callsites dominating.

## Shipped

All on `origin/main`:

- `51f03a6` — `src/runtime/shape.zig`: `Shape` transition node +
  `ShapeTree` (arena + root shape + find-or-create `transition`).
  `JSObject.shape: ?*Shape` + `JSObject.slots: ArrayList(Value)`.
- `7b7bcad` — `ShapeTree` moved `Realm` → `Heap`; `JSObject` gains
  a `heap` back-pointer stamped in `Heap.allocateObject`.
- `742035e` — `set` / `setWithFlags` build a shadow shape +
  `slots` alongside `properties`. Behaviour-neutral.
- `39b5e31` — `setIfWritable` shadow path; `deleteOwnProperty`
  demotes the receiver's shape.
- `c8d96e3` — `def_property` / `def_computed` /
  `def_accessor` / `def_computed_accessor` opcodes demote
  before direct `properties` / `accessors` mutation.
- `e03f5cd` — `lda_property` carries a 2-byte `ic` operand
  (now 4 bytes total: `k:u16 + ic:u16`); chunk-local IC cell
  table; fast path is shape pointer compare → `slots[slot]`
  load. Adds `verifyShapeInvariant` (debug-only, wired into
  the GC mark walk).
  **`prop_access` measured at -66 % (48.94 → 16.47 ms).**
- `7bad504` — `sta_property` carries the symmetric write-side
  IC; fast path is shape compare → slot write + bag mirror.
  **`prop_write` measured at -63 % (92.24 → 33.70 ms).**
- `2c89781` — `call_method` carries a call-IC cell caching the
  last plain (non-bound, non-proxy, non-revoked) callee.
  Cell-hit path skips the proxy / `valueAsFunction` /
  revocable / bound-target exotic dispatch. GC weak-clear
  on the cell's callee pointer between mark and sweep.
- `9ee68fc` — `lda_property` IC extended with a prototype-load
  mode. Cell grows `proto: ?*JSObject`, `proto_shape: ?*Shape`,
  `proto_rev: u64`. Hit when receiver shape matches AND
  receiver's prototype identity matches AND the cached proto's
  shape matches AND `realm.proto_revision_counter` is unchanged
  since fill. Bumped on `Object.setPrototypeOf` /
  `Reflect.setPrototypeOf` / `set_proto_literal`. Covers
  prototype-inherited reads (`arr.push`, `instance.m`,
  `String.prototype.constructor`) — the dominant real-world
  case the own-data IC missed.
- **Hardened synthetic-accessor load mode (2026-07).** The SES
  override-mistake fix represents each frozen primordial data property as
  an internal synthetic accessor, so ordinary prototype-data filling cannot
  cache reads such as `o.hasOwnProperty("x")`. `LoadICCell.Kind` now has a
  `synthetic_accessor` mode that stores the getter's immutable captured
  value. Fill accepts only an immediate non-extensible prototype with a
  non-configurable descriptor and Cynic's internal non-setter
  `SyntheticAccessor`; it refuses ordinary user accessors. Hits guard the
  receiver shape, prototype identity/shape, and realm prototype revision.
  The prototype pointer is weak-cleared by GC; while live, its getter owns
  the cached value through the same internal slot. Lantern and Bistromath
  share the mode. A same-tree ReleaseFast A/B on 5M
  `hasOwnProperty` calls measured **304.6 → 152.8 ms p50 (-49.8%)**.
- `fdf3940` — Fused `call_property` opcode for the simple
  `obj.method(args)` shape. Replaces a 4-op `ldar + lda_property
  + star + call_method` sequence (15 bytes operand, 4 dispatches)
  with one `[k:u16] [r_recv:u8] [argc:u8] [ic_load:u16]
  [ic_call:u16]` dispatch (8 bytes operand). Shares the proto-load
  `ICCell` with `lda_property` and the call IC with `call_method`.
  Slow path: a factored `slowLookupForCallProperty` helper mirrors
  `lda_property`'s 11-arm receiver-type matrix (plain / proxy /
  module-namespace / chainHasProxy / accessor /
  function-poison-pill / string / number / bool / bigint /
  symbol). Compiler gates the fused emission on the simple shape
  (plain ident key, no `#private`, no optional, no `super`, not
  in tail position); every other shape falls back to the legacy
  emission unchanged. Hermes ships exactly this (`CallBuiltin` /
  `CallPropertyN`); Ignition ships `CallProperty0/1/2`.
  **`method_call` p50 -3.1 % (~22.7 → ~22.0 ms).**
- `e2c5b59` — `lda_global` / `lda_global_or_undef` IC. Cache
  `(globalThis_shape, slot, decl_revision)` at each callsite.
  Wire format grows to `[k:u16] [ic:u16]`. Fast path: shape
  compare on `gr.globals.target` + `decl_revision` snapshot
  match → `gt.slots[cell.slot]`. Slow path: factored
  `slowLdaGlobal` helper (decl_env first per §9.1.1.4 — does NOT
  fill the cell so a top-level `let X = …` keeps shadowing the
  cached object-env slot — then shape lookup, then accessor /
  bootstrap-fallback). `GlobalBindings.decl_revision` is a new
  counter on the realm's globals struct, bumped exactly once per
  fresh `installScriptLexBinding` (`!found_existing` branch);
  `putDecl` reassignments don't bump because they don't change
  which env a free-identifier lookup resolves through. The
  slow-path-factoring is load-bearing: an earlier inlined-handler
  version added ~85 lines per opcode to the dispatch loop and
  i-cache pressure regressed unrelated fixtures (e.g.
  `class_instantiate` +12 % despite zero `lda_global` in its hot
  loop); pulling the slow path out collapsed that footprint.
  **Bench wins (p50 / min vs pre-IC baseline, --runs=30):**
  `prop_access` -9.6 % / -7.3 %, `prop_write` -7.8 % / -4.5 %,
  `array_iter` -8.4 % / -4.3 %, `string_concat` -12.8 % / -4.7 %,
  `object_alloc` -5.8 % / -3.2 %, `method_call` -5.7 % / -4.2 %.
- `e44870f` — Free-function `call` opcode IC. Mirrors
  `call_method`'s `CallICCell` pattern on the bare `.call` op for
  `f(args)` (closure-captured functions, helper functions,
  callbacks). Cell hit is a single pointer-compare on the cached
  callee → straight to the generator / native / async / regular
  dispatch arms, skipping the proxy / `%Function.prototype%` /
  revocable / wrapped / bound / class-constructor /
  `valueAsFunction` exotic-dispatch chain. Wire grew from
  `[r_callee:u8] [argc:u8]` (2 bytes) to `[r_callee:u8] [argc:u8]
  [ic:u16]` (4 bytes). Handler restructures around a `blk:` that
  yields a vetted `JSFunction*`, mirroring `call_method`'s shape;
  the class-constructor TypeError check lives inside the blk so
  the IC never caches a class-ctor callee.
- `90b6f5b` — `new_call` IC. Extends `CallICCell` with a
  `proto: ?*JSObject` slot to cache the
  `(constructor, resolved-prototype)` pair so each iteration of
  a hot `new C(…)` loop skips both the `valueAsFunction` decode
  AND the §10.1.14 GetPrototypeFromConstructor accessor walk —
  straight from the cell hit into instance allocation + JS body
  frame setup, bypassing every exotic-construct gate (proxy,
  bound, arrow, no-construct, deferred-proto native, native
  callback). Invalidation: cell hit verifies
  `cached_callee == observed_callee` AND
  `cached_proto == cached_callee.prototype` — the latter catches
  `C.prototype = newProto` reassignments. Wire grew from
  `[r_callee:u8] [argc:u8]` (2 bytes) to `[r_callee:u8] [argc:u8]
  [ic:u16]` (4 bytes). The handler structure keeps the slow path
  inline (no helper extracted yet) — the dispatch loop footprint
  grew but no i-cache regressions surfaced in benches; if a
  future change adds more to the handler, factor like
  `slowLdaGlobal`.

- `db6cfcb` — `sta_property` transition IC. The original IC
  explicitly refused to cache shape transitions ("the cached
  post-shape never matches the next pre-shape … e.g.
  literal-construction loops"), which meant every iteration of
  a class constructor's `this.x = …; this.y = …` writes took
  the slow path: `lookupAccessor` chain walk + `Wyhash` on the
  key + `ShapeTree.transition` lookup + `obj.slots.resize` per
  write. On `class_instantiate.js` (10M `new Point(i, i+1)`),
  samply showed Wyhash back at ~6.4 % of CPU plus another
  ~13 % across accessor maps, properties maps, Shape.lookup,
  hasOwn/flagsFor — roughly 23 % of CPU in slow-write
  machinery that should be a tight transition. Add a third
  mode to `ICCell`: `(pre_shape, post_shape, slot)` paired
  with the same `(proto, proto_shape, proto_rev)` snapshot the
  proto-load IC uses. Fast path stamps `post_shape` on the
  receiver, resizes `slots` to its property_count, writes the
  slot — skipping every hash, accessor walk, and transition
  lookup. Slow-path fill walks the FULL proto chain once at
  fill time to verify no accessor exists for the key
  anywhere; if so, the cell is filled. Adding an accessor on
  any proto later changes that proto's shape (accessor
  entries are part of the shape), so the `proto.shape`
  snapshot catches it; `setPrototypeOf` anywhere bumps
  `proto_revision_counter` to catch deeper-chain mutations.
  **`class_instantiate` p50 -20.9 % (116.24 → 91.99 ms).**

- `fb952c5` — `sta_property` transition IC: §10.1.9 epoch guard, plus
  the per-prototype-validity-cell decision. The `(proto, proto_shape,
  proto_rev)` snapshot above misses one §10.1.9 case: a non-writable
  data property (or accessor) installed on a *dictionary-mode* proto
  (null shape → `proto_shape` unchanged) or a *non-immediate* proto
  (not snapshotted) would let the fast path keep stamping an own slot
  where `OrdinarySetWithOwnDescriptor` mandates a `TypeError`. Closed
  with a realm-wide `heap.proto_struct_epoch`, bumped at the structural
  funnels in `object.zig` (accessor install, non-default
  `defineProperty`, `demoteFromShape`, named `deleteOwn`); the cell
  snapshots it as `guard_epoch` and the hot path adds one `u64 ==`.

  **Why a global epoch and not per-prototype validity cells**
  (V8/JSC-style; the deliberately-deferred follow-up). The global
  counter is maximally coarse — *any* structural mutation to *any*
  object invalidates *every* transition cell — so it looks like a prime
  candidate for fine-grained per-proto cells. A deterministic
  measurement says no. Counting fast-path hits vs epoch-forced
  fallbacks over a 2,000,000-iteration loop: `new C()` alone →
  1,999,999 hits / 0 fallbacks; the same loop with one non-writable
  `defineProperty` on an *unrelated* (non-prototype) object per
  iteration → 0 hits / 1,999,999 fallbacks — a total IC kill. Yet the
  wall-time gap between that full-thrash loop and an identical
  `defineProperty(writable:true)` loop (0 fallbacks, same machinery) is
  within the ±100 ms run-to-run noise: 2 M forced refills add ≈0 ms.
  The reason — every epoch bump originates in a structural mutation
  (~600 ns) that dwarfs the <50 ns refill it triggers, and under
  hardened-by-default frozen primordials such mutations are rare
  post-init anyway. Per-proto cells would convert those fallbacks back
  to hits (sub-noise saving) while taxing *every* common-case fast hit
  with a proto-chain validity walk plus per-cell memory + GC. Net loss
  for Cynic's target; revisit only if a real workload shows
  transition-IC refills surfacing above noise.

## Architecture decisions

- **`ShapeTree` lives on the `Heap`, not the `Realm`.** Agent-scoped,
  like V8's per-Isolate Maps; `Heap` is also pointer-stable whereas
  `Realm` moves by value.
- **`JSObject` has a `*Heap` back-pointer**, stamped in
  `Heap.allocateObject`. Lets the realm-agnostic
  `JSObject.set(allocator, key, v)` API — called from hundreds of
  builtin sites — reach `heap.shapes` without a signature change.
- **Dual representation.** `shape == null` → dictionary mode (the
  `properties` / `property_flags` hash). `shape != null` → `slots`
  is authoritative and named writes do not mirror into the property bag.
  Shape-mode objects normally keep the map at zero capacity;
  `demoteFromShape` materializes dictionary entries when an operation needs
  dictionary mode. See [docs/lazy-property-bag.md](lazy-property-bag.md).
- **Shapes are arena-allocated, agent-lifetime** — never collected
  individually. The GC does not trace into shapes.
- **`verifyShapeInvariant`** runs on every reachable shaped
  `JSObject` during the GC mark phase (debug builds only, gated
  on `std.debug.runtime_safety`). Catches any future direct
  `properties` mutation that bypasses `shadowSet` /
  `demoteFromShape` — the most common way the shape goes stale.
- **Property ICs use typed mutable side tables.**
  `Chunk.inline_load_caches`, `inline_store_caches`, and
  `inline_computed_caches` give each opcode family a compact independent
  index space instead of charging every site for one union-like cell.
  `inline_call_caches` and `inline_forin_caches` remain separate. All are
  zeroed at chunk finalization. GC weak-clears load-cache prototype pointers
  and call-cache callee/prototype pointers.
- **`LoadICCell` has data and synthetic-accessor modes.** Own data uses
  `(shape, slot)`. Prototype data adds prototype identity/shape/revision and
  loads `proto.slots[slot]`. Frozen synthetic accessors use the same guards
  but load `synthetic_value`. Global loads reuse the data layout and store
  `GlobalBindings.decl_revision` in the revision field.
- **`StoreICCell` owns write-only state.** Same-shape writes cache the slot.
  Transition writes additionally cache
  `pre_shape`/`post_shape`, prototype guards, and `proto_struct_epoch` before
  stamping the new shape and slot.
- **`ComputedICCell` copies short dynamic keys inline.** Computed loads,
  stores, and positive-own `in` sites guard receiver shape plus key bytes.
  Four distinct-key refills park the cell as megamorphic instead of
  thrashing it; the cell contains no GC pointer.
- **`CallICCell` is also dual-use.** `call_method` / `call` use
  only `callee`; `new_call` sets `callee` AND `proto` (the
  cached `callee.prototype` snapshot, for the
  GetPrototypeFromConstructor skip). The GC's weak-clear pass
  drops both fields together when the callee gets swept (an
  orphan `proto` with `callee == null` would short-circuit
  unreachably).
- **Factor the slow path when the dispatch loop grows.** The lda_global
  IC ran into 5-15 % regressions on unrelated micros (e.g.
  `class_instantiate` +12 % despite zero `lda_global` in its hot
  loop) when its ~85 lines of slow path lived inline in the giant
  `switch :dispatch`. Pulling the slow path into a function
  (`slowLdaGlobal`) and keeping each handler at ~25 lines collapsed
  the i-cache footprint and turned the regressions into 5-13 % wins
  across the IC-exercising fixtures. Same lesson holds for any future
  IC: keep the per-op handler tight; helper-call the slow paths.

## Remaining IC frontier

Stack-ranked by expected impact, biggest first.

### Tier 1 — drained

Tier 1 is empty as of `90b6f5b` — the proto-load read IC,
own/write IC, `call_method` IC, fused `call_property`, global IC,
free-function `call` IC, and `new_call` IC are all on `main`. The
hot interpreter dispatch paths are IC-covered; future wins shift to
Tier 2 / 3 below or to non-IC axes (cheaper call frames —
see the leaf-call note at the end of this Tier — and threaded
dispatch).

The first non-IC axis landed across two commits — `realm.value_stack`,
a bump-allocated register-file stack that frame-push sites try
first for non-generator, non-async JS callees. Fall through to
`frame_pool` on overflow keeps the contract simple. Generators,
async functions, and tail-call register-file reallocations stay
on the pool because their register-file lifetime crosses the
LIFO discipline.

  • `2675a82` — MVP: `.call_method`'s plain JS callee. On a
    30M-call `method_call.js` samply trace the FramePool share
    dropped from 8.4 % to a much smaller fraction (the path now
    acquires via a pointer-bump instead of a hash-map-by-size).
    `cynic-bench --runs=30` showed `method_call` p50 -6.8 % plus
    3-11 % wins on `promise_chain`, `tail_recursion`,
    `json_stringify`, `array_iter`, `object_alloc`, and
    `string_concat`.
  • `8e8480a` — widening: `.call`, `.call_property`, `.new_call`
    (both the IC fast path and the slow-path JS-callee
    fall-through), `callJSFunction`, `callJSFunctionAsSuper`,
    `constructValue` all converted to the same template. Every
    bench fixture improved another 1.8-8.6 % p50. Also closed a
    pre-existing leak in the three `call.zig` sites where
    `try frames.append(...)` would propagate `error.OutOfMemory`
    without releasing the freshly-acquired register file.

Top-level `runFrames` entries (the one-shot allocations at realm
boot) and the tail-call register-file reallocations stay on the
pool by design.

**Leaf-call note — the next call-path win is a smaller `CallFrame`,
not arg-copy elision.** With `value_stack` landed, register *storage*
is already inlined (a bump, not a malloc), so the classic
"register-file inlining" via overlapping/coalesced register windows
would only shave the per-argument cost. A measurement says that's the
wrong target: a 0-arg leaf call in a 30M-iteration loop costs
~13.7 ns of pure call overhead per call (810 ms vs 400 ms for the
same loop inlined, no-jit ReleaseFast), and growing the call to
8 arguments adds only ~1 ns/arg (810 → 1030 ms). The **fixed**
per-call cost dominates — ~40-60 % of call-heavy code — and the
per-arg cost (the arg-copy loop + register `@memset`) is already
cheap. `reEnterDispatch` is an inline 6-field copy, also cheap. What
remains is the `CallFrame` struct itself: ≈30 fields / ~176 bytes
constructed and `append`ed on every call, plus the field loads off
`callee_fn` and the return teardown — a 176-byte struct copy is ~6 ns
on its own. Shrinking `CallFrame` (a hot/cold split moving rarely-read
fields behind a `cold: ?*ColdFrame` pointer) was the candidate lever —
**investigated and not pursued**, for two reasons found on inspection:

1. **The payoff is small.** A direct test — add 64 B of dead padding to
   `CallFrame`, rebuild ReleaseFast, measure — moved the leaf-call micro
   only +4 % and the 0-arg micro +5.6 % (~1.5 ns per 64 B). The frame
   *size* is a real but shallow cost. A clean cold-split can't halve the
   frame anyway (see below), so the recoverable slice is ~30-50 B →
   **~3-5 % on call-heavy code**, not the half-the-struct figure a naive
   reading suggests.
2. **A clean split moves far less than ~176 B.** `home_object`,
   `running_realm`, and `owning_module` are written on common / every-
   call paths, so making them cold would force a per-method-call
   allocation — a regression, not a win. `generator` and the async /
   `super` state entangle with generator/async **suspension
   persistence**: a cold struct on a suspending frame must outlive the
   call, breaking the LIFO bump discipline `value_stack` relies on. The
   genuinely-safe-to-move set is just the construct/super-rare fields
   (`new_target`, `is_construct`, `is_derived_ctor`, `super_called`,
   `super_called_cell`, `home_function`) — ~30-50 B.

So a ~3-5 % win on call-heavy code, gated behind an invasive, GC-
critical refactor (every cold-field read site + root-marking the cold
struct in the GC mark walk, with suspension-persistence corner cases) is
a poor trade. Left as documented; revisit only if a profile shows
call-frame construction dominating a workload we care about, or if the
GC mark walk is reworked for other reasons and the cold struct falls out
cheaply.

**Call-callee load: redundant-`ldar` drop shipped; a dedicated
register-receiver dispatch arm was built, measured, and NOT shipped.**
The legacy member-call path (`o.run(x)` / `Math.max(x)` — a non-literal
arg, where `call_property` fusion is inadmissible per §13.3.6.1) used to
load the callee with `ldar r_recv; lda_property k` — a redundant
receiver reload plus the acc-receiver IC. Two independent fixes were
explored; **only the cheap one shipped:**

1. **Shipped** — a compiler peephole keeps the acc-form `lda_property`
   and just deletes the dead `ldar`: `Star r_recv` already preserves the
   accumulator, so the receiver is still in acc at the load. One op
   dropped, **no new opcode, no dispatch-table growth.**
2. **Built and dropped** — a dedicated `lda_property_reg_call` opcode
   (byte-identical to `lda_property_reg`; slow path shared with
   `call_property` via `slowLookupForCallProperty`; Bistromath compiles
   it identically) with its OWN interpreter dispatch arm. The motivation
   is the documented mispredict that keeps resurfacing: routing the
   callee load through the *shared* `lda_property` / `lda_property_reg`
   arm mispredicts on the reg/acc alternation that mixed leaf-read +
   method-call code creates — a prior method-callee conversion regressed
   on exactly this, and "dedicated arms" was the proposed remedy. It was
   correct (test262 transparent, `--jit` byte-identical, full unit pins)
   but, on top of fix (1), its only delta is the arm isolation — a
   permanent extra opcode. **Verdict: flat on a uniform call-heavy micro**
   (the callee load is a small fraction of per-call cost; the isolation
   benefit needs reg/acc *alternation*, which a uniform loop can't
   exercise). The deciding test — an **alternation micro**
   `for(...){ x = o.a; y = o.run(z); }`, dedicated-arm vs plain main,
   with the `arith_loop` dispatch-bloat canary — **could not be run**: a
   quiet machine never materialised (sustained multi-agent load all
   session; A/A noise floor ~33 % ≫ the ~10 % signal needed). Dropped
   rather than ship a permanent opcode on an unmeasured benefit.

   **To settle it for good** (don't rebuild from scratch): rebase the
   dedicated arm onto main (fix (1) already did the op-drop, so the arm
   is the *only* delta), and on a genuinely idle machine run the
   alternation micro vs plain main. **Ship bar (both required):**
   alternation ≥ ~10 % faster, repeatable, well outside noise, AND
   `arith_loop` flat (no global dispatch tax). Flat or marginal, or any
   `arith_loop` regression → the dedicated arm is dead; keep fix (1) and
   close this for good.

### Tier 2 — drained

**Computed-property read + write IC** (`obj[k]` / `obj[k] = v`,
dynamic string key) — **shipped** (read `lda_computed`, write
`sta_computed`). The cell caches `(shape, slot)` guarded by the
runtime key. The original
plan ("cache `(shape, key_intern, slot)`; requires string interning
first") was sidestepped: rather than build an interning subsystem,
the cell stores the key **bytes inline** (`cached_key_buf`, capped
at `computed_key_cap = 23`; longer keys aren't cached). That keeps
the cell allocation-free and GC-anchor-free — no JSString pointer to
root — at the cost of a byte-compare guard instead of a pointer
compare. The flip's Phase 3 already made shape reads authoritative,
so the other prerequisite was met. A monomorphic site fills on the
cold miss, then serves `recv.slotAt(slot)` after a shape + key-bytes
match (own-data only; accessors / proxies / inherited keys fall to
the slow path, which refills). A **megamorphic guard**
(`computed_key_megamorphic_after = 4`) parks a rotating-key
(`obj[keys[i]]`) site on the slow path so it stops thrashing.
Bistromath needed no codegen change — its loop advances via
`Op.operandSize`, so the wider opcode is skipped automatically and
the `--jit` differential stays byte-identical; `sta_computed` isn't
Bistromath-compiled at all, so the write IC is differential-neutral by
construction. The write fast path does `setSlot` + write barrier on an
existing **writable** own-data slot (writability is part of the matched
shape, so a frozen / non-writable slot never hits it); transitions
(new key), setters, proxies, and numeric keys take the slow path. A/B
(interp): monomorphic `obj[k]` −57% read, `obj[k] = v` −90% write (the
write slow path allocates a key-anchor JSString per store that the IC
skips); rotating-key sites return to baseline (megamorphic guard, no
regression).

### Tier 3 — niche

**Polymorphic IC.** Allow 2-4 cells per callsite. An
optimizing-tier speculation feature: Bistromath deliberately reads
the monomorphic cells as-is (docs/jit.md §4.4) and Ohaimark is the
intended consumer (docs/jit.md §5). Marginal below that tier
unless profiling shows polymorphic sites dominating a workload we
care about.

A 4-way interpreter-tier read IC (probe the set on a primary
miss, rotate the matched cell to the front, park the receiver
shape) was built and measured against the Octane `deltablue` /
`raytrace` macros, which spend their time in subclass property
loads. It was correct and transparent — test262 byte-identical
across the affected slices, the `--jit` differential exact
(Bistromath reads the primary cell at the same fixed offsets), and
gc-stress clean (the extra cells weak-clear with the primary). But
it **regressed** `deltablue` ~+3.6-4.2% (reproduced, against a
±0.5% A/A control) and left `raytrace` flat-to-slower. The sites
are *megamorphic*, not tidily 2-4 polymorphic: the working set is
wider than any small cell count, so the probe loop + rotation +
park is pure overhead on the miss path without converting misses
to hits — the monomorphic primary already served the common shape.
Conclusion confirmed empirically: the lever for these sites is
optimizing-tier polymorphic dispatch (Ohaimark's data-driven IC),
not the interpreter. Reverted; do not rebuild at the interpreter
tier.

**`in` IC — shipped (own-positive).** `"x" in obj` carries an IC
(`in_op` → `[op] [r:u8] [ic:u16]`) that caches the **own-positive**
result — `x` is an own property of `obj`'s shape — guarded by the
receiver shape + the runtime key bytes captured inline. Own presence
⟺ the shape contains the key, so a shape guard alone is sound; the
cold fill confirms the key is shape-tracked (`shape.lookup`), gated on
a `found_on_receiver` flag so the negative / proto-positive paths skip
that probe. The negative, proto-positive, function, and proxy cases
never fill — a plain `Proto.x = 1` on a shape-mode proto bumps neither
`proto_revision_counter` nor `proto_struct_epoch`, so a cached negative
would go stale. `in_op` isn't Bistromath-compiled (it walks the proto
chain / dispatches the `has` trap), so the wider opcode is differential-
neutral via `Op.operandSize`. A/B (interp): own-positive `"x" in o`
−37% in a hot loop; negative ~neutral. test262 transparent.

**`Object.hasOwn` / `hasOwnProperty`.** Not IC'd — they are native
calls (`objectHasOwn` etc.), outside the bytecode-opcode IC model. The
`call_property` / `call` ICs already cache the *callee*; a shape→
presence cache inside the native would need a per-realm `(shape, key)`
table rather than a per-callsite cell. Niche; deferred.
This refers to the native function's own-property test; the hardened
prototype lookup that obtains `hasOwnProperty` itself is covered by the
synthetic-accessor load mode above.

**for-in enumeration cache — shipped (frozen-proto guard).**
`for_in_open` carries an IC (`[op] [ic:u16]` → `Chunk.inline_forin_caches`,
a weak `ForInICCell` table mirroring `CallICCell`) that caches the
§14.7.5.6 EnumerateObjectProperties key snapshot, so a hot `for (k in o)`
loop over a stable object served by a frozen prototype skips the array
alloc + own/inherited key walk + per-key string copies on re-entry —
serving a *fresh* iterator over the cached key-array after a guard match
(the array is never mutated). The cell holds
`(recv_shape, proto, snapshot, guard_epoch)`.

This is the corrected design after the earlier revert. The reverted
attempt guarded on the receiver's [[Prototype]] being the realm's
*shape-mode* `%Object.prototype%` (`proto.shape != null`), but Cynic is
SES-by-default and the realm-init freeze demotes the primordial
prototypes to **dictionary mode** (`shape == null`) — so the fill-gate
never held and it ran as pure overhead (a 5-key micro regressed ~8 %).
The corrected gate keys on the proto being **frozen** (`!extensible`)
with a `null` [[Prototype]] — a one-level frozen chain, e.g. `obj` →
frozen `%Object.prototype%` → null. A frozen proto's enumerable
contribution is immutable, so the snapshot stays valid while the
receiver's own shape is unchanged. Fill conditions (all must hold):
receiver is a plain shape-mode object (`shape != null`), not a proxy /
array-exotic / typed-view / module-namespace, with no integer-indexed
elements (for-in includes own indices ascending from `elements`, which
the shape doesn't capture); its [[Prototype]] is a frozen one-level
chain. Guard on hit re-verifies receiver shape == cell.recv_shape,
proto identity, proto still `!extensible`, `heap.proto_struct_epoch`
unchanged (catches any enumerable-flag flip / delete / accessor install
on the proto via the same structural funnels the `sta_property`
transition IC uses), and no integer elements on the receiver. The
`proto` + `snapshot` pointers are GC-heap and held **weakly** —
`weakClearChunkICs` (heap.zig) nulls the whole cell if either is swept,
so the cache never roots a dead snapshot and never dangles. `for_in_open`
isn't Bistromath-compiled (it walks the proto chain / allocates), so the
wider opcode is differential-neutral via `Op.operandSize`. A/B (interp,
min-of-7, --no-jit): count-only `for (k in o)` over `{a,b,c}` −58 %,
with-keys (`s += k.length; s += o[k]`) −55 %, both vs the alloc-reduction
baseline. test262 transparent (45335, byte-identical pass-set; --jit
matches). The key-snapshot **allocation reduction** that does *not* need
a cache — `storeElement` straight into the result array, in
`buildForInSnapshot` — landed separately (`33f974a`, ~6-8 %) and is the
baseline the A/B beats.

## The flip — retire `properties` for shaped objects (effectively done)

The flip dropped the bag mirror for shape-mode objects. Phases 1-3
shipped (`cbf1402`, `6e07ab7`, `8b8c605`): `get` / `hasOwn` /
`lookupOwn` / `iterOwnNamedKeys` are shape-first, shape-mode writes
skip the bag, and the **GC marker walks `slots[0..property_count]`**
for shape-mode objects (the Phase 4 marker work was absorbed into
Phase 3 — splitting would have left an inconsistent transient). The
`properties` field stays `.empty`-defaulted rather than `?…` optional;
an empty `StringArrayHashMapUnmanaged` allocates nothing (capacity 0),
so a shape-mode object pays **no bag allocation** — the same memory
outcome as the optional design, minus the compile-time "bag null ⟹
shape mode" guarantee (a runtime convention every write upholds via
`setWithFlags`).

What remains (lazy-property-bag.md Phases 4-5) is **not worth doing**:
the only Phase-4 residual is skipping the no-op `properties.deinit()`
on the `.empty` bag in `deinitFields` (the doc's own "~free but not
zero"), a GC-delicate change for a negligible win, and its abort
criterion (`object_alloc` must move ≥15 %) is unmeetable — Phase 3
measured the alloc path flat (the `sta_property` IC already bypasses
the bag). Phase 5 is a `properties.put` / `.get` survivor audit;
mixed-mode is tolerated by design, so it's low-value housekeeping. The
bag retirement's substance is complete; the `?…` flip is left as an
optional type-system tightening if a coherence regression ever traces
here. Phased plan + invariants in
[docs/lazy-property-bag.md](lazy-property-bag.md).

## The shape key index — killing the O(depth) miss walk

`Shape.lookup` resolves an own property by walking the transition
chain to the root, one `std.mem.eql` per node. That's fine on IC
hits (the key is never consulted) and on small objects, but the
megamorphic-miss path pays it in full — and callgrind put the walk
plus its memcmp at ~16 % of `deltablue` and ~12 % of
`string_concat` instructions, the exact residue the interned-keys
post-mortem said future property work must target
([interned-keys.md](interned-keys.md) §11: kill the walk length;
atom identity alone was a measured dead-end).

The fix is the standard one — V8 switches DescriptorArray search
from linear to hash-based past a size threshold, JSC materialises
a `PropertyTable` on its Structures, SpiderMonkey keeps a
`PropertyMap` table — adapted to Cynic's substrate in
`shape.zig`:

- **`KeyIndex`** — an open-addressed key→entry table covering one
  shape's FULL chain (self → root), built lazily by the first slow
  lookup that pays for a whole un-indexed walk. Slots hold shape
  nodes; each node caches its key's Wyhash (`key_hash`) for the
  build and the probe's early-out. Nearest-node-wins insertion
  reproduces the linear walk's shadowing order, so
  `redefineTransition` chains (the SES freeze path) resolve
  byte-identically.
- **Depth gate at 16, not V8's 8.** V8's linear cutoff assumes
  interned Names with a *cached* hash; Cynic hashes the key bytes
  per probe, which moves the break-even up. Measured: indexing
  depth-8-12 chains regressed `deltablue` ~9 % (the probe's
  Wyhash matches the short walk it replaces, and the anchor
  bookkeeping taxed every lookup); at 16 the sub-threshold path
  is the exact pre-index walk — one u32 depth compare is the
  whole feature cost — and the deep-chain machinery lives in a
  `noinline` `lookupDeep` (the `slowLdaGlobal` i-cache lesson).
- **Descendants reuse an ancestor's index**: scan the short
  un-indexed tail linearly first (preserving nearest-wins), then
  probe the nearest indexed ancestor; a leaf builds its own index
  once its full-tail walks cross the thresholds, converging hot
  shapes to a pure probe.
- **Bounded under hostile input** (the never-unbounded-growth
  contract, [handbook/host-safety.md](handbook/host-safety.md)):
  builds draw from a tree-wide slot budget linear in the node
  count, then fall back to a geometric distance-doubling rule, so
  an adversarial add-one-property-then-lookup loop gets O(n)
  total index memory, not O(n²). An OOM during a build just skips
  the index — `lookup` itself cannot fail.
- **No GC interaction.** Indexes and keys are `ShapeTree`-arena
  allocations (realm-lifetime, untraced), same as the shapes
  themselves. The arena moved behind a stable heap pointer so a
  bare `*Shape` can reach it for lazy builds.

Measured (interleaved A/B vs the pre-index baseline, with an A/A
control at ±2-3 %): `string_concat` **−30 %** (its
`(n).toString()` loop resolves the `Number` ctor through the
~25-deep global-object shape every iteration — the walk was 252
Ir/call, now a probe), `deltablue` +0.7 % Ir (neutral — its
chains sit below the gate by design), every other micro/macro
within noise. The dictionary-mode bag probes that share the
`string_concat` cluster (`decl_env` + demoted primordial
prototypes) are a separate, still-open target.

## Conformance risks (where IC changes can break test262)

- **§10.1.11 enumeration order** — integer keys ascending, then
  string/symbol keys in insertion order. The transition chain *is*
  insertion order for named keys; integer keys stay in `elements`.
  Watch `built-ins/Object/keys`, `getOwnPropertyNames`,
  `language/expressions/object`.
- **§6.2.6 descriptor flags** — attrs live in the shape; a
  redefine with different flags is a distinct transition. Watch
  `built-ins/Object/defineProperty`.
- **`delete`** — append-only shapes can't drop a property; delete
  demotes the receiver to dictionary mode. Watch
  `language/expressions/delete`.
- **Accessors** — accessor properties carry `kind = .accessor` in
  the shape so a data-property IC never fires on them. Receiver's
  own accessor for a key shadows an inherited data property — the
  proto-load walk must skip when `obj.accessors.contains(key)`.
- **Dictionary-mode protos** — a proto whose `properties` carries
  the key but whose shape doesn't (e.g. `%String.prototype%`
  after its String-exotic mark demote) must BREAK the proto-load
  walk, not skip past it. Otherwise the walk miscaches a deeper
  proto's same-named property — covered by the
  `proto.properties.contains(key)` break-out in
  `lda_property`'s slow path.
- **Polymorphic receivers at one site** — two receivers can share
  an own shape (both empty, both at the root) but inherit from
  different prototypes (`new String(x)` vs `new Number(y)`).
  Fast-path proto-load must verify `obj_in.prototype == cell.proto`
  alongside the shape compare.
- **GC weak-clear** — IC cells caching GC-heap pointers (call
  IC's callee, proto-load IC's proto) must be weak-cleared
  between mark and sweep. Cells caching arena-stable Shape
  pointers (own-data IC) don't.

## Verification

- `prop_access` / `prop_write` micro-benches — headline numbers
  for the read/write ICs. Targets met
  (-66 % / -63 % vs pre-IC baseline).
- `bench-results.md` records per-commit deltas.
- Cross-engine comparison via `tools/bench-cross.sh` per
  [docs/benchmarking.md](benchmarking.md).
- test262 runtime gate every new IC chunk — pass / fail counts must
  match the row recorded in
  [test262-results.md](../test262-results.md). Each landed IC in
  the *Shipped* list above kept the count byte-for-byte stable;
  any future IC must do the same.
