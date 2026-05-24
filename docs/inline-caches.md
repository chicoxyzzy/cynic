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

## Remaining IC frontier

Stack-ranked by expected impact, biggest first.

### Tier 1 — biggest single remaining win

**Fused `call_property` opcode.** Combines
`lda_property + star + call_method` into a single dispatch.
Compiler detects `Call(MemberExpr(obj, name), args)` in the AST
and emits `call_property [k:u16] [r_recv:u8] [argc:u8] [ic:u16]`
instead of the three-op sequence. Cell reuses the existing
proto-load `ICCell` — fast path: receiver-shape compare → load
callee via own or proto slot → call directly.

Hermes ships exactly this; Ignition ships a near-equivalent
(`CallProperty0`/`CallProperty1`). Two implementation paths:

- **Clean: factor `lookupProperty` out of `lda_property`.** The
  current 250-line handler interleaves IC fill, proxy [[Get]],
  module-namespace [[Get]], `chainHasProxy` walk, accessor
  dispatch, AND primitive-receiver auto-box paths. Extract the
  slow-path lookup into a helper that returns
  `enum { value: Value, handled, uncaught: Value }` so both
  `lda_property` and `call_property` share semantics. Invasive
  but clean.
- **Pragmatic: duplicate the slow path inline.** Copy-paste ~250
  lines; drift risk on every future `lda_property` change.

Expected: meaningful single-digit % across method-heavy
fixtures; bigger on tight monomorphic call loops.

### Tier 2 — medium

**Global-property IC** (`lda_global`). `globalThis` is one shared
object; every script touches it repeatedly (`console.log`,
`Object`, `Array`, …). Cache `(globalThis_shape, slot)` per
`lda_global` site. Same machinery as `lda_property` against a
fixed receiver.

**`call` opcode IC** (free-function calls — `f(x)` not
`obj.f(x)`). Same call-IC cell pattern as `call_method`: cache
the last plain callee pointer, skip exotic-callee dispatch.
Useful for direct calls to closure-captured functions and locals.

**`new_call` IC.** Caches `(ctor_fn, proto)` so the fast path
skips `valueAsFunction` + `OrdinaryCreateFromConstructor`'s
prototype lookup. Constructor-heavy code (`new ClassName(…)`
loops) benefits.

### Tier 3 — niche

**Polymorphic IC.** Allow 2-4 cells per callsite. Mostly a
JIT-speculation optimization; marginal in a pure interpreter
unless profiling shows polymorphic sites dominating a workload
we care about.

**`hasOwn` / `in` ICs.** Cache shape-presence for
`Object.hasOwn(obj, "x")` and `"x" in obj`. Niche.

**Computed-property IC** (`obj[k]` where `k` is a hot constant
string). Cache `(shape, key_intern, slot)`. Requires string
interning first.

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
- test262 runtime gate every new IC chunk — `fail` must not
  regress from the established baseline (currently 9 fail,
  all pre-existing RegExp property-escapes).
