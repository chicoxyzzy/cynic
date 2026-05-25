# Lazy property bag — design & plan

Goal: skip the per-property `properties.put` hashmap insert on
shape-mode objects, so `{ a: i, b: i + 1 }` allocates faster. The
`object_alloc` micro-bench (~59 ms, ~5 % behind QuickJS-NG today,
was ~30 % at design time) and **`class_instantiate` (~131 ms,
~2× behind QuickJS-NG)** are the targets; the same hot path runs
in every literal-heavy program (DOM-shaped record construction,
JSON-like factory functions, the React `createElement` pattern,
class-based allocations under load, etc.).

A fresh samply on `class_instantiate` (6M `new Point(i, i+1)`
iterations) attributes inclusive cost roughly as:

| bucket | % | what |
|---|---:|---|
| `strictSetPropertyAnchored` family | ~41 % | the `this.x = x; this.y = y;` writes in the constructor body |
| `JSObject.set` (split across paths) | ~16 % | downstream of strictSetPropertyAnchored — the bag insert + shape transition + flags update |
| `Heap.collectYoung` | ~10 % | GC sweep walking the per-iteration JSObject churn |
| `JSObject.hasOwn` | ~8 % | bag lookup inside `set` (existence check for the redefine-vs-add fork) |
| `lookupAccessor` | ~7 % | accessor-check before falling back to the data slot |
| `array_hash_map.getIndexAdapted` | ~6 % | the bag's `wyhash` + bucket walk |

The lazy-bag refactor below targets the **`hasOwn` + `getIndexAdapted`
+ half of `JSObject.set`** cluster — every line that touches
`obj.properties` for a shape-mode object becomes a no-op when
the bag isn't there.

This doc is the durable plan — a fresh session should be able to
pick up the next sub-step from here without re-deriving the design.
Sister doc to [inline-caches.md](inline-caches.md), which built the
shape substrate this refactor exploits.

## Motivation — what the profile says

A samply run on a 6 M-iteration `{ a: i, b: i + 1 }` loop
(`tools/profile.sh`-style, but pointed at the bench binary)
attributes inclusive cost roughly as:

| bucket | % | what |
|---|---:|---|
| `JSObject.setWithFlags` family | ~38 % | the 2 property-add calls per object |
| `Heap.collectYoung` + `deinitFields` | ~40 % | GC sweep walking dead objects |
| `interpreter.runFrames` self | ~25 % | dispatch overhead (overlap with above) |

Inside `setWithFlags`, three things happen per added property:

1. `self.properties.put(allocator, key, v)` — `StringArrayHashMap`
   insert. Hash + bucket walk + key compare + insert.
2. `self.recordKey(allocator, key)` — linear-scan dedupe over
   `own_key_order` (cheap for small N), then append.
3. `self.shadowSet(allocator, key, v, flags)` — shape lookup
   (`heap.shapes.transition(parent, key, ...)` is itself a hashmap
   probe) + slot write + barrier.

Steps 1 + 3 are the same shape of work — two hashmap inserts per
property. Step 3 also writes the slot. **For a shape-mode object
both maps carry the same authoritative answer**: shape-first reads
(landed in `4133c7f` / `4b06eb4` for `get` / `hasOwn`) made the bag
a *mirror*, not the source of truth. The bag's only remaining
consumers are enumeration, descriptor accessors, and a few
direct-mutation sites in builtins / the GC marker.

If we can stop writing to the bag for shape-mode objects, we cut
step 1 entirely. Profile says the saving is in the 25-35 %
neighbourhood of `object_alloc` wall-time, which also clips the GC
sweep cost (no bag to tear down per object). A naive **pre-size
the bag** experiment (`properties.ensureTotalCapacity(4)` at
allocation) measured *negatively* — the upfront alloc costs more
than the 0→4 rehash it saves. The win is in skipping the bag, not
sizing it.

## Audit — every place the bag is read or written today

This is the hard part. The bag is the source of truth for several
spec surfaces that the shape doesn't model directly. Each call site
needs a deliberate decision: route to shape, route to bag (after
demote-if-needed), or accept that the path forces a demote.

Run `grep -n "properties\.put\|properties\.get\|properties\.swap\|properties\.contains\|properties\.values\|properties\.entries\|properties\.iterator\|properties\.count" src/` and walk the hit list. Bucketed below:

### Bag *writes* — must route through `setWithFlags` or demote

These already go through the engine `set` family (`set`,
`setWithFlags`, `setComputedOwned`, `setIfWritable`, …) — the
shape-aware path. Some builtins still touch `properties.put`
directly; those will need to either become `setWithFlags` calls or
explicitly `demoteFromShape()` first.

- `src/runtime/object.zig` — `setWithFlags`, `set`, `setIfWritable`,
  `setComputedOwned`, the `delete` / `defineProperty` family,
  `recordKey` / `forgetKey`.
- `src/runtime/realm.zig` — `GlobalBindings.bindToObject` (raw
  `properties.put` on the globals namespace).
- `src/runtime/builtins/object.zig` — `Object.defineProperty`,
  `Object.defineProperties`, `Object.assign` fast paths.
- `src/runtime/builtins/proxy.zig` — handler trap dispatch.
- `src/runtime/builtins/typed_array.zig` — view installation.
- A handful of `__cynic_*` slot uses (already on engine-internal
  objects that don't reach user JS — no shape concern).

### Bag *reads*

These need to route to the shape when the object is shape-mode:

- `JSObject.get`, `JSObject.hasOwn` — **already shape-first** (see
  `4133c7f`, `4b06eb4`). Keep the bag fallback for dictionary mode.
- Enumeration paths:
  - `Object.keys`, `Object.values`, `Object.entries`,
    `Reflect.ownKeys`, `Object.getOwnPropertyNames`,
    `for-in` (compiler-emitted), `Object.getOwnPropertyDescriptor`.
  - Today these read `properties.entries` + `own_key_order`. With a
    lazy bag, enumeration must walk the shape chain instead (each
    shape descendant carries the key it added; walk parent-most-
    first for insertion order).
- `Object.getOwnPropertyDescriptor` — needs the value + flags. With
  a lazy bag, `(slots[shape.lookup(key).slot], shape.lookup(key).attrs)`
  is the source.
- `Object.prototype.propertyIsEnumerable` — flag lookup; same.
- `JSON.stringify` — own enumerable key walk; same.
- The `in` operator — already routes to `hasOwn` / `has`, fine.

### GC marker

`runtime/heap.zig` `markObject` currently walks
`obj.properties.values()` to mark each child Value. For shape-mode
objects it must walk `obj.slots.items[0..obj.shape.property_count]`
instead. (The shape itself is realm-lifetime, not GC-managed, so
no extra trace.)

`deinitFields` likewise has to skip the bag teardown when the bag
is empty / never allocated.

## Proposed change

Make `JSObject.properties` *optional* — `properties:
?std.StringArrayHashMapUnmanaged(Value) = null`. Lifecycle:

1. **Fresh object** — `properties = null`. `slots`, `shape` start
   empty (already are).
2. **First property add via `setWithFlags`** with a shape-eligible
   key + default flags — `shadowSet` builds the shape + writes the
   slot. **The bag is not allocated.** `own_key_order` continues
   to be appended (insertion order is needed for enumeration; the
   shape chain *is* this order, but materialising the chain on
   each enumeration call is O(depth) — keep the parallel list for
   now and revisit).
3. **Demote-to-dictionary trigger** (accessor write, non-default
   flags, `__cynic_*` key, exotic, proto trap, etc.) — `properties`
   is lazily allocated and back-filled from `slots` + `shape`.
   Subsequent writes follow today's bag path.
4. **Dictionary-mode objects** — `properties` is non-null and the
   bag is authoritative, as today.

`property_flags` follows the same lazy treatment — only allocated
when at least one descriptor diverges from `PropertyFlags.default`.

### New invariants

- `obj.properties == null` ⟹ object is in shape mode (or empty).
  Shape may also be `null` for a still-empty object.
- `obj.properties != null` and `obj.shape == null` ⟹ dictionary
  mode.
- Mixed mode is illegal: any path that would write to the bag must
  first `demoteFromShape`, which back-fills + nulls the shape.

### Helper functions (likely)

- `JSObject.ensureBag(allocator)` — lazily allocate `properties`
  (and back-fill from shape, calling `demoteFromShape` if needed).
- `JSObject.iterOwnNamedKeys()` — single enumeration iterator that
  walks the shape chain for shape-mode, or `properties.iterator()`
  for dict-mode. Every Object.keys / for-in / JSON consumer routes
  through here.
- `JSObject.lookupOwn(key) ?LookupResult` — `{ slot, attrs, value }`
  for shape-mode (cheap), or bag lookup for dict-mode. Today's
  consumers of `properties.get` switch to this.

## Migration phases

Each phase builds green and is gated on `zig build test` + a
filtered `--only-failing` sweep, with a full sweep at the end of
each phase to refresh the pass-cache and confirm no buckets moved
that the filter missed.

### Phase 1 — extract the enumeration iterator (refactor only)

No behaviour change. Introduce `iterOwnNamedKeys` (and the
descriptor sibling) that today just wraps `properties.iterator()`.
Migrate every enumeration consumer to it. Once landed, this is the
single place to add the shape-walk branch in Phase 3.

**Risk:** low — pure refactor. **Test262 risk:** zero.

### Phase 2 — extract `lookupOwn` + helper LookupResult

Wrap today's `properties.getPtr` / `getFlags` accesses behind one
helper. Same low-risk refactor; sets up the shape-mode branch.

**Risk:** low. **Test262 risk:** zero.

### Phase 3 — flip `properties` to `?…`, lazy-allocate on demote

Behavioural change but bounded — the lazy branch only fires for
objects that never write through a bag-only path. Demote sites
(`Object.defineProperty` with non-default flags, accessor add,
direct `properties.put` callers in builtins) call `ensureBag`,
which materialises the bag from `slots` + `shape` and demotes.

This is the audit-heavy step. Every direct `properties.put` in
the audit list above gets an `ensureBag` call (or is migrated to
`setWithFlags`). Every direct `properties.get` becomes
`lookupOwn`. Every enumeration becomes `iterOwnNamedKeys`.

**Risk:** medium-high. **Test262 risk:** moderate — the spec
surfaces that depend on bag insertion order (`Object.keys`,
`for-in`, `Reflect.ownKeys`, `JSON.stringify`) are the ones to
watch. The `built-ins/Object/keys/property-traps.js`-shape tests
catch shape-vs-bag drift cleanly.

### Phase 4 — GC marker + `deinitFields` skip the bag

`markObject` reads `slots[0..shape.property_count]` for shape
mode. `deinitFields` `?.deinit` on the optional bag.

**Risk:** low — small mechanical change once Phase 3 has flipped
the bag to optional. **Test262 risk:** low; the GC stress harness
(`--gc-threshold=1`) catches a missed slot trace fast.

### Phase 5 — bench + cleanup

Measure `object_alloc` against the QuickJS-NG line. Audit for
any remaining `properties.put` / `properties.get` survivors that
the Phase 3 sweep missed; either kill them or document why they
need the bag.

If `object_alloc` moves the expected 20-30 %, also re-run the
full bench suite (other fixtures are non-obvious — `prop_access`
shouldn't move (already IC-served), `prop_write` should be flat
(IC-served), `array_iter` is array exotic (dict-mode, unaffected)).

## Conformance risks

- **§10.1.11 enumeration order** — own integer keys ascending,
  then string keys in insertion order. The shape transition chain
  *is* insertion order for named keys (each transition appends one
  key), so a shape-mode walk parent-most-first reproduces the bag
  order. Test262 area: `built-ins/Object/keys`,
  `built-ins/Object/getOwnPropertyNames`,
  `built-ins/Reflect/ownKeys`,
  `language/statements/for-in/order-*`.

- **§6.2.6 descriptor flags** — attrs travel with the shape (see
  `shape.zig`). A redefine with different flags is a distinct
  shape transition or a demote; the descriptor surface reads from
  the shape entry's `attrs` field. Watch `built-ins/Object/defineProperty`.

- **`delete` invariants** — append-only shapes can't drop a slot.
  `JSObject.deleteOwn` already calls `demoteFromShape` (fixed in
  `24f10be`); the lazy-bag work doesn't change that. Watch
  `language/expressions/delete`.

- **`Object.assign` shape transitions** — assign-into-fresh
  enumerates source own keys and copies. With lazy bag, the
  enumeration walks the shape chain; iteration order must match
  the pre-refactor bag walk.

- **`__cynic_*` slot keys** — these are tolerated only on
  engine-internal objects (see `AGENTS.md`). `shadowSet` already
  demotes when it sees one; lazy bag preserves this.

- **Proxy targets** — every proxy trap forces dictionary mode
  (`shadowSet` demotes when `proxy_target != null`). Unchanged.

- **TypedArray + ArrayBuffer exotics** — `is_array_exotic` /
  `getTypedView()` already demote in `shadowSet`. Unchanged.

## Abort criteria

Pull the change at any phase where:

1. test262 `fail` count climbs by >5 in the filtered sweep and the
   regressions don't cluster around a single fixable mistake.
2. `object_alloc` doesn't move ≥15 % by end of Phase 4 — the
   structural cost we modelled was wrong; rethink before grinding
   on enumeration micro-optimisations.
3. Phase 3's audit surfaces a builtin (e.g. proxy, typed-array)
   that needs *two* representations live simultaneously — a sign
   the invariant ("`properties == null` ⟺ shape mode") is too
   strict; back up and find a less ambitious split.

## Verification

- `object_alloc` micro-bench is the headline number — expect
  ~15-25 % drop after Phase 4 (the inclusive 38 % of `setWithFlags`
  shrinks to ~one hashmap insert per property; GC sweep also
  trims).
- `arith_loop` / `prop_access` / `prop_write` / `array_iter`
  should be flat — they don't construct objects in the hot loop.
- test262 sweep after every phase. Phase 3 is the one most likely
  to drop bucket scores; Phase 4 less so but the GC stress
  threshold (`--gc-threshold=1`) is the safety check.
- Bench RSS — the `properties` map allocation today is ~64 B per
  object. Skipping it on shape-mode literals should shrink steady-
  state RSS by ~half on object-heavy workloads.

## Out of scope (note for later)

- **Cross-realm shape sharing** — shapes are already realm-lifetime
  and shared across objects with identical layouts; no change.
- **Polymorphic IC** — same scope as `inline-caches.md`; out for
  now.
- **`elements` (indexed-key vector) packing** — separate gap, see
  ROADMAP "Packed JSArray".
- **Own-key-order list retirement** — could derive from shape
  chain on demand instead of paralleling the list. Saves ~24 B
  per object header, but the shape walk is O(depth). Defer until
  bench shows the list is hot.
