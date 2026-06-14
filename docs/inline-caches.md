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
  is authoritative; `properties` is currently mirrored for the
  paths that still consult it (the *flip* — retire `properties`
  for shaped objects — is the next structural step; see
  [docs/lazy-property-bag.md](lazy-property-bag.md)).
- **Shapes are arena-allocated, agent-lifetime** — never collected
  individually. The GC does not trace into shapes.
- **`verifyShapeInvariant`** runs on every reachable shaped
  `JSObject` during the GC mark phase (debug builds only, gated
  on `std.debug.runtime_safety`). Catches any future direct
  `properties` mutation that bypasses `shadowSet` /
  `demoteFromShape` — the most common way the shape goes stale.
- **`Chunk.inline_caches: []ICCell` + `Chunk.inline_call_caches:
  []CallICCell`** are mutable side-tables on the otherwise-immutable
  chunk. Both are zeroed at chunk finalisation. GC weak-clears the
  call-IC's callee pointer and the proto-load IC's proto pointer.
- **`ICCell` is multi-use.** Same struct serves four modes — the
  consumer opcode picks which fields are valid:
    * `lda_property` / `sta_property` same-shape (own-data) mode:
      `shape` matches the receiver; `slot` indexes `recv.slots`;
      `pre_shape` / `post_shape` null; `bag_index` is the
      `sta_property` hot path's cached `properties` array index.
    * `lda_property` proto-load mode: `shape` (receiver) +
      `proto != null` + `proto_shape` (snapshot at fill) +
      `proto_rev` (snapshot of `realm.proto_revision_counter`).
      `slot` indexes `proto.slots`.
    * `sta_property` transition mode: `pre_shape != null` AND
      `post_shape != null`. Fast path stamps `post_shape` on the
      receiver, resizes `slots`, writes `slots[slot]`. Same
      `proto` + `proto_shape` + `proto_rev` snapshot as the
      proto-load mode — adding an accessor to any proto changes
      that proto's shape; `setPrototypeOf` bumps the counter.
    * `lda_global` / `lda_global_or_undef`: `proto == null`,
      `shape` is the global object's shape, `proto_rev` is
      repurposed to record `GlobalBindings.decl_revision`. A
      future `lda_global` proto-walk variant would set `proto`
      like `lda_property`.
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
Tier 2 / 3 below or to non-IC axes (leaf-call register-file
inlining, threaded dispatch).

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

**`hasOwn` / `in` ICs.** Cache shape-presence for
`Object.hasOwn(obj, "x")` and `"x" in obj`. Niche.

## The flip — retire `properties` for shaped objects

Today's design keeps `properties` populated as a mirror even when
`shape` is authoritative. The *flip* drops that mirror:

- `JSObject.get` / `.hasOwn` already shape-first
  (`4133c7f`, `4b06eb4`).
- Direct `obj.properties.get(key)` call sites (~27 across
  builtins — Reflect, JSON, Proxy traps, `Object.defineProperty`)
  need auditing.
- Write path stops mirroring once the audit closes.

Memory win, not perf — but unlocks computed-property IC and
makes the JIT-tier work tractable. Phased plan + invariants in
[docs/lazy-property-bag.md](lazy-property-bag.md).

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
