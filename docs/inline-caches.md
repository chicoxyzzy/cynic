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

Target model is **Hermes**: shapes + a monomorphic interpreter IC,
no JIT. Polymorphic ICs are deliberately out of scope today —
their main consumer is JIT speculation. Revisit only if profiling
shows polymorphic callsites dominate, or if a JIT ever lands.

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
- **`ICCell` is dual-use.** Same struct serves three opcodes — its
  fields are reinterpreted by the consumer:
    * `lda_property` / `sta_property` own-data mode: `proto == null`,
      `slot` indexes `recv.slots`, `bag_index` is the `sta_property`
      hot path's cached `properties` array index.
    * `lda_property` proto-load mode: `proto != null` + `proto_shape`
      + `proto_rev` (snapshot of `realm.proto_revision_counter`).
    * `lda_global` / `lda_global_or_undef`: `proto == null`, `shape`
      is the global object's shape, `proto_rev` is repurposed to
      record `GlobalBindings.decl_revision`. A future `lda_global`
      proto-walk variant would set `proto` like `lda_property`.
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

### Tier 1 — biggest single remaining wins

**Free-function `call` opcode IC.** Mirror `call_method`'s
`CallICCell` pattern on the bare `call` op for `f(x)` (closure-
captured functions, helper functions, callbacks). Cache the last
plain callee pointer; cell hit skips the proxy / revocable /
bound / `valueAsFunction` exotic dispatch. ~50 lines, parallels
existing code closely. Helps FP-style and parser / traversal
code.

**`new_call` IC.** Caches `(ctor_fn, proto)` so the fast path
skips `valueAsFunction` + `OrdinaryCreateFromConstructor`'s
prototype lookup. Constructor-heavy code (`new ClassName(…)`
loops — object pools, `new URL()`, `new Date()`) benefits.
Moderate complexity (~80 lines).

### Tier 2 — medium

**Computed-property IC** (`obj[k]` where `k` is a hot constant
string). Cache `(shape, key_intern, slot)`. Requires string
interning first; unlocked once *the flip* (below) makes
shape-mode reads independent of `properties`.

### Tier 3 — niche

**Polymorphic IC.** Allow 2-4 cells per callsite. Mostly a
JIT-speculation optimization; marginal in a pure interpreter
unless profiling shows polymorphic sites dominating a workload
we care about.

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
