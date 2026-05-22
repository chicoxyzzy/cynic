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

On `main` (`51f03a6`):

- `src/runtime/shape.zig` — `Shape` transition node + `ShapeTree`
  (arena + root shape + find-or-create `transition`); 6 unit tests.
- `JSObject.shape: ?*Shape` + `JSObject.slots: []Value` — additive
  scaffolding.

On branch `worktree-inline-caches` (committed, not yet merged):

- `7b7bcad` — `ShapeTree` moved `Realm` → `Heap`; `JSObject` gains a
  `heap` back-pointer stamped in `Heap.allocateObject`.
- `7a98b4d` — `JSObject.get` reads `slots` for a shaped object,
  else `properties`. Inert today — nothing builds shapes yet.

Every object still has `shape == null`; all property access is on
the `properties` hash. `zig build test` green at this checkpoint.

## Architecture decisions

- **`ShapeTree` lives on the `Heap`, not the `Realm`.** Agent-scoped,
  like V8's per-Isolate Maps; `Heap` is also pointer-stable whereas
  `Realm` moves by value. (Done in `7b7bcad`.)
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

### 2b-2 — `set` builds shapes (the core; audit-heavy)

`set` / `setWithFlags` build a shape (transition + slot write) for
an eligible object. **This step cannot be salami-sliced** the way
2b-0 / 2b-1 were, for a specific reason:

`JSObject.get` (since `7a98b4d`) reads a shaped object's values
from `slots`. So once an object is shaped its shape MUST stay
consistent with *every* mutation — and several paths mutate
`properties` **directly, bypassing `JSObject.set`**:

- the `del_named_property` opcode (`delete obj.x`);
- `Object.defineProperty` and the descriptor-define paths;
- raw `obj.properties.put(...)` call sites (e.g.
  `GlobalBindings.bindToObject` in `realm.zig`).

Run on a shaped object without updating or demoting the shape,
each leaves the shape stale → `get` returns a deleted / wrong
value. **2b-2 therefore requires auditing every direct
`properties` / `property_flags` / `accessors` mutation site** and
giving each a demote-to-dictionary (or update-the-shape) step.

Recommended sequencing — build the shape as a *write-only shadow*
first, so the audit and the flip are separable:

1. Make `get` read `properties` first again (the shape branch
   non-authoritative) — `7a98b4d` wired `get` shape-first
   prematurely; reorder it so a stale shadow shape has no effect.
2. `set` builds the shadow shape + `slots` alongside `properties`.
   Behaviour-neutral — commit; test262 confirms `set` still works.
3. Audit the direct-mutation sites; add demote / update discipline.
4. Flip: `get` / `hasOwn` / enumeration / the GC marker read the
   shape; retire `properties` for shaped objects. test262 gates.

Keep the *shaped* set of objects small at first — shape only a
plain object gaining default-attribute data properties from an
empty start; demote on anything else (accessors, non-default
flags, `__cynic_*` keys, array exotics).

### 2b-3 — `delete` / `defineProperty` / dictionary demotion

In practice folded into the 2b-2 audit (step 3) above.

### 2b-4 — enumeration + GC marker

§10.1.11 enumeration order from the transition chain; the GC
object-marker walks `slots` instead of `properties` for a shaped
object. Part of the 2b-2 flip (step 4).

### IC — monomorphic inline cache

`Chunk` grows a mutable `inline_caches: []ICCell` side-table (the
`Chunk` is otherwise immutable); `lda_property` / `sta_property`
gain an `ic:u16` operand. Fast path: shape pointer compare +
`slots` load. Own data properties only; a miss falls through to
the full lookup and refills the cell.

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
