# Generational aging via card marking — design note

Status: **deferred / design only.** Two implementation attempts (this
is the write-up of why they failed and what the correct shape is) were
reverted at the `--gc-threshold=1` gate. This note exists so the next
effort starts from the root-cause diagnosis, not from scratch.

## The problem this targets

Cynic's interpreter-tier cross-engine compass
([`bench-cross-results.md`](../bench-cross-results.md)) shows allocation
churn is the engine's clearest relative weakness against the JIT-off
big-engine interpreters (JSC `JSC_useJIT=0`, SpiderMonkey
`--no-baseline --no-ion`, Hermes):

| fixture | cynic | best peer | gap |
|---|---:|---:|---|
| `ctor_array_build` | ~600 | ~110 | **~5×** |
| `object_alloc` | ~34 | ~16 | ~2× |
| `class_instantiate` | ~36 | ~22 | ~1.6× |
| `promise_chain` | ~19 | ~10 | ~1.9× |

(Cynic is competitive-to-leading on the compute / IC-cached fixtures —
`arith_loop`, `prop_access`, `method_call`, `tail_recursion`. The gap
is specifically alloc-bound work.)

Root cause: **premature promotion.** `promoteYoungList`
([`src/runtime/heap.zig`](../src/runtime/heap.zig)) tenures *every*
young survivor into the mature list on its **first** `collectYoung`.
A per-iteration temp (the `new Point(...)` and the `[p.x, p.y]` in
`ctor_array_build`) survives the one minor cycle it's live for, gets
promoted, then dies — but as **mature garbage** that only an
`O(mature)` full cycle reclaims. The big-engine interpreters keep that
churn in cheap young space via a real generational nursery with
**aging**: an object must survive *N* young cycles before tenuring, so
short-lived churn is swept by the cheap minor cycle and never pollutes
mature space.

## Why naive aging fails (the actual defect)

Aging itself is the textbook-correct fix. The blocker is that Cynic's
**remembered-set / write-barrier coverage is a hand-maintained
patchwork that is only sound because survivors promote immediately.**

The minor cycle (`collectYoung`) finds mature→young edges from two
sources:

1. the **remembered set** — populated by the barriered store helpers
   (`storeProperty` / `storePropertyWithFlags` / the typed-setter
   funnels) for *named* property edges; and
2. an **unconditional per-cycle scan** of every mature container's
   *typed* internal slots (`markObjectInternalSlots`,
   `markFunctionInternalSlots`, the environment-slot loop, generator
   internal slots, promise reactions).

This split works today **only** because a young object never persists
across a cycle: at end of `collectYoung` the remembered set is
*consumed and cleared* (`for (remembered) setInRememberedSet(false);
clearRetainingCapacity()`), and the comment there spells out the load-
bearing assumption — *"an edge created before this cycle and not
re-stored is still safe because the referent was promoted to mature
this cycle."*

Aging removes that crutch (a survivor stays young), which exposes that
the "every mature→young edge is tracked" invariant is enforced **per
edge class, by hand** — and the set of edge classes is large and
keeps growing. The two attempts hit them one crash at a time:

- **Attempt 1** added aging + remembered-set *retention* (keep a
  remembered entry whose referent stayed young). `verifyRememberedSet`
  tripped: a container **tenured this cycle** while its referent aged
  forms a fresh mature→young edge the barrier never recorded
  (young→young at store time). Fix = *promotion-time remembering*
  (mechanism 3): after promotion, scan the newly-tenured tail of each
  mature list and remember any with a young referent. With all three
  mechanisms the verifier passed and Object / Array / class /
  language / deep-graph gc-stress were clean.
- **Attempt 2** (with mechanism 3) then crashed `built-ins/Promise`
  gc-stress single-threaded in the **`finally` reaction path**
  (`finallyThenReaction → chainFinallyResult → promiseThen`, swept
  referent). The finally / capability / `promise_store` reaction
  machinery is *another* edge class the per-class predicates didn't
  cover.

The pattern is **whack-a-mole** — each fix surfaces the next uncovered
edge class (typed slots → named slots → promotion-time → promise
reactions → capability records → finally fields → the realm
`value_stack` → …). Whack-a-mole is evidence the *design* is wrong,
not the implementation. Per-edge-class enumeration cannot be made
complete by inspection.

## The correct design: card marking

Make "find every mature→young edge" **complete by construction** with a
card-marking remembered set, then layer aging on top.

### Card table

- Divide the mature heap (or the whole address space the pooled object
  / function / environment / string slabs live in) into fixed-size
  **cards** (commonly 512 B or one OS page). A `card_table: []u1` (or
  `[]u8` for cheaper stores) has one dirty bit per card.
- A card is **dirty** if any pointer-bearing field of an object in that
  card may have been written since the last minor cycle.

### Write barrier

Replace the per-edge-class `in_remembered_set` bookkeeping with one
uniform barrier at every store of a heap value into a heap object:

```
store(container_field, value):
    *container_field = value
    if isMature(container) and isYoungHeapValue(value):
        card_table[cardOf(container)] = dirty
```

Crucially this is **edge-class-agnostic** — it fires on *any* write
into a mature object regardless of whether the field is a named slot,
a typed internal slot, a promise reaction, a capability record, or a
finally field. The funnel already exists in spirit (the typed-setter
helpers / `storeProperty*`); card marking unifies them and lets the
hand-maintained `in_remembered_set` flag + the four-arm rebuild in
`collectYoung` be deleted.

### Minor cycle

```
collectYoung():
    beginMinorCycle()              // live_color flip
    markRoots()                    // realm roots, handle scopes, etc.
    for card in dirty_cards:
        for obj in objectsInCard(card):
            markAllPointerFields(obj)   // generic, every field
    drainMarkWorklist()
    sweepYoung(); promoteOrAge()
    clearDirtyCards()              // re-armed by the barrier next cycle
```

`markAllPointerFields` walks **every** outgoing pointer of the object
(the union of what `markValue`'s per-type arm + `markObjectInternalSlots`
already enumerate). Because the dirty-card scan is generic, a young
referent reached through *any* field of a dirty mature object is found
— no per-edge-class predicate, so no whack-a-mole and no
`verifyRememberedSet` arm to keep in lockstep.

### Aging on top

With a complete remembered set the aging policy is trivial and was
already proven correct in the spike:

- `JSObject.age: u8` (start 0). `promote_age = 1` ("survive two minor
  cycles": age 0→1 on the first survival, tenure on the second).
- `promoteYoungList(..., age_survivors: bool)`: in a **minor** cycle a
  live survivor with `age < promote_age` increments `age` and stays in
  the young list; otherwise it tenures (reset `age = 0`). A **full**
  cycle passes `age_survivors = false` and tenures outright (no aged-
  young objects exist after a full cycle, so card state is moot there).
- Only `JSObject` ages initially (it dominates churn); functions /
  environments tenure on first survival. Extending aging to them later
  is free — card marking already covers their edges.

This is exactly the JSC-Riptide / SpiderMonkey generational shape and
is why their interpreters win the alloc-churn fixtures above.

## Alternative considered (rejected)

**Complete the per-edge-class barrier instead of card marking.** Keep
the remembered set + the three aging mechanisms, and add a predicate
arm for every remaining edge class (promise reactions, capability
records, finally fields, value_stack, …). Rejected: it's the whack-a-
mole the two attempts demonstrated. You can never prove by inspection
that the enumeration is complete, and every new pointer-bearing field
added to a heap type silently re-opens a use-after-free under aging.
Card marking is complete-by-construction; that property is the whole
point.

**Escape analysis / scalar replacement** is a *complementary*, not
substitute, technique: it eliminates the *non-escaping* allocation
subset (`ctor_array_build`'s array) entirely, but does nothing for
escaping churn, and is a larger compiler analysis. Production engines
do both; card-marking aging is the foundational half and should land
first.

## Implementation plan

1. **Card table + barrier, no aging.** Add the card table, route the
   existing store funnels through the dirty-mark, and switch
   `collectYoung`'s mature-root discovery from the remembered set +
   per-cycle typed-slot scan to the dirty-card scan. This is
   behaviour-preserving (still promote-on-first) and must keep
   `gc-threshold=1` green single- **and** multi-threaded before
   proceeding. Delete `in_remembered_set` and the consume-and-clear /
   retention machinery.
2. **Aging.** Add `JSObject.age` + the `age_survivors` parameter; age
   in minor cycles only. Re-run the full gate.
3. **Extend aging to functions / environments** once (1)+(2) are
   stable, if the churn data justifies it.

## Validation gate (hard)

- `zig build test-fast` — including updated promote-timing unit tests
  (aging shifts tenure from one cycle to two; ~4 Heap tests need the
  two-cycle update, and add the promotion-time / retention regression
  tests from the spike).
- `gc-threshold=1` ReleaseSafe (`cynic-test262-safe`) across
  `language/expressions`, `built-ins/{Object,Array,Promise}`,
  `language/statements/class`, **both `--threads=1` and the default
  multi-threaded harness** — the multi-threaded path matters because a
  remembered-set/barrier change interacts with the per-worker realm
  pool. `verifyRememberedSet` is retired by card marking, but the
  `0xaa` free-poison still catches a swept-but-referenced object.
- `--leak-check`, full `zig build test262` (≥ baseline pass count),
  and the bench A/B on `ctor_array_build` / `object_alloc` /
  `class_instantiate` / `promise_chain`.
- **Revert on any gc-stress crash** — the discipline that caught both
  prior attempts.

## Expected payoff

The whole alloc-churn cluster at once: `ctor_array_build` (the ~5×
outlier), `object_alloc`, `class_instantiate`, `promise_chain`. The
card table costs one bit per card (negligible) plus a barrier branch
already paid by the current `in_remembered_set` check.

## Code pointers

- Promotion + the consume-and-clear / aging hooks:
  `promoteYoungList`, `collectYoung`, `collectFull` in
  [`src/runtime/heap.zig`](../src/runtime/heap.zig).
- The invariant a card table replaces: `verifyRememberedSet` (the
  exact per-type edge classes it checks — objects' slots/bag/elements,
  function properties, environment slots).
- Store funnels to route through the barrier: the typed-setter helpers
  + `storeProperty` / `storePropertyWithFlags` (see
  [`handbook/gc.md`](handbook/gc.md) "Typed-setter helpers").
- Per-cycle typed-slot scan the card scan subsumes:
  `markObjectInternalSlots` / `markFunctionInternalSlots` and the
  environment/generator loops in `collectYoung`.
