# Inline property caches — design & plan

Goal: collapse property access from a per-`.x` hashtable lookup to a
guarded one-compare-one-load. ROADMAP "Performance" calls this the
biggest single interpreter win; the `prop_access` micro-bench
(~49 ms, ~3× behind QuickJS-NG) is the target.

This doc is the durable plan — a fresh session should be able to
pick up the next sub-step from here without re-deriving the design.

## Approach

Two pieces, in order:

1. **Shapes** (hidden classes / structures) — a transition tree
   describing each object's named-property layout. Self / V8
   lineage (Chambers & Ungar); `Shape = (parent, key, attrs,
   slot)`. Necessary substrate; on its own it does **not** speed
   up reads.
2. **Monomorphic inline cache** — per-callsite cached `(shape,
   slot)`; the read becomes `if obj.shape == cached: load
   slots[cached_slot]`.

Target model is **Hermes**: shapes + a monomorphic interpreter IC,
no JIT. Polymorphic and prototype-load ICs are deliberately
out of scope — their main consumer is JIT speculation, which Cynic
doesn't have. Revisit only if profiling shows polymorphic callsites
dominate, or if a JIT ever lands.

## Landed so far

Commit `51f03a6` on `main`:

- `src/runtime/shape.zig` — `Shape` transition node + `ShapeTree`
  (realm-lifetime arena + root shape + find-or-create
  `transition`); 6 unit tests.
- `JSObject.shape: ?*Shape` + `JSObject.slots: []Value`, and
  `Realm.shapes: ShapeTree` — additive scaffolding, **unused**.
  Every object still has `shape == null`; access is on the
  `properties` hash.

## Architecture decisions

- **`ShapeTree` lives on the `Heap`, not the `Realm`.** Agent-scoped,
  like V8's per-Isolate Maps; `Heap` is also pointer-stable whereas
  `Realm` moves by value. (The scaffolding commit put it on `Realm`
  as a placeholder — sub-step 2b-0 moves it.)
- **`JSObject` gets a `*Heap` back-pointer**, stamped in
  `Heap.allocateObject`. This is what lets the realm-agnostic
  `JSObject.set(allocator, key, v)` API — called from hundreds of
  builtin sites — reach `heap.shapes` without a signature change.
- **Dual representation.** `shape == null` → dictionary mode (the
  existing `properties` / `property_flags` hash). `shape != null` →
  `slots`. `get` / `set` handle both. Standard (V8 fast vs.
  dictionary objects); also the landing zone for `delete` and
  churn-heavy objects.
- **Shapes are realm/agent-lifetime** — arena-allocated, never
  collected individually. The GC does not trace into shapes.

## Remaining sub-steps

Each builds green and is gated on `zig build test` + a full
`zig build test262 -- --quiet` sweep (`fail` must not regress).

- **2b-0** — move `ShapeTree` `Realm` → `Heap`; add the
  `JSObject` → `*Heap` back-pointer (stamp in `allocateObject`).
  Additive, no behaviour change.
- **2b-1** — `get` / `getOwn` read both representations
  (`shape` → `slots`, else the hash).
- **2b-2** — `set` / `setWithFlags` build shapes (transition +
  slot write) as the source of truth; objects become shaped. The
  high-risk sub-step.
- **2b-3** — `delete`, `defineProperty`, and dictionary-mode
  demotion (delete → demote to the hash; shapes are append-only).
- **2b-4** — §10.1.11 enumeration order from the transition
  chain; GC object-marker walks `slots`.
- **IC** — `Chunk` grows a mutable `inline_caches: []ICCell`
  side-table (the `Chunk` is otherwise immutable); `lda_property`
  / `sta_property` gain an `ic:u16` operand. Fast path: shape
  pointer compare + `slots` load. Own data properties only; a
  miss falls through to the full lookup and refills the cell.

## Conformance risks (where 2b can break test262)

- **§10.1.11 enumeration order** — integer keys ascending, then
  string/symbol keys in insertion order. The transition chain *is*
  insertion order for named keys; integer keys stay in `elements`.
  Watch `built-ins/Object/keys`, `getOwnPropertyNames`,
  `language/expressions/object`.
- **§6.2.6 descriptor flags** — attrs live in the shape; a
  redefine with different flags is a distinct transition. Watch
  `built-ins/Object/defineProperty`.
- **`delete`** — append-only shapes can't drop a property; delete
  demotes the object to dictionary mode. Watch
  `language/expressions/delete`.
- **Accessors** — accessor properties carry `kind = .accessor` in
  the shape so a data-property IC never fires on them.
- **GC** — the object-marker must walk `slots` instead of the
  `properties` map once an object is shaped.

## Verification

- `prop_access` micro-bench is the headline number; expect a large
  drop only once the IC (not just shapes) is in.
- test262 gate every sub-step — 2b-2/2b-3/2b-4 are where a shape
  bug surfaces.
