# Generational-incremental major marking — design scope

Status: **CLOSED — not viable for a non-moving collector.** Phase 0 measured
GO and Phase 1 (the mature→mature remembered set) was built + fully validated;
then a careful read of the Phase 2 marking mechanism found a fundamental
obstruction, and the effort was reverted. See **Outcome** immediately below —
the rest of the doc is the historical record of how we got there. Owner: the
GC track. Prerequisite reading: [handbook/gc.md](handbook/gc.md) (sticky mark
bits, card marking, incremental major mark, lazy sweep — all shipped).

## Outcome — closed (the negative result)

Building Phase 2 surfaced a fundamental obstruction: **a non-moving mark-sweep
collector cannot reclaim old-generation garbage without re-tracing the old
set.** The generational-incremental major — "skip re-tracing the unchanged old
set, keep its sticky marks" — does not deliver a cheap *reclaiming* major.
Concretely, the three realizations all fail:

- **Keep all sticky marks (no colour flip) ⇒ a no-op.** Between full majors
  every live mature object is already `live_color` (the last full major marked
  it; promotion marks survivors; allocate-black marks new objects). A dead
  mature object — a removed `splay` payload — keeps its sticky mark too. A major
  that only *adds* marks from (dirtied-old ∪ roots) marks nothing new and frees
  nothing; it is provably identical to *skipping the major* and floating the
  garbage.
- **Flip only the dirtied set ⇒ reclaims the wrong objects.** `splay`'s actual
  garbage is a *removed node*, whose own pointers never changed — only its
  parent's did. The removed node is therefore **clean**, never flipped, never
  reclaimed. The dirtied set is the rotated/relinked nodes, which mostly stay
  live.
- **Flip everything, prune the trace at clean subgraphs ⇒ use-after-free.** A
  clean old object C can point to D whose only path is through C (the C→D edge
  predates the last full major, so C is clean). Stopping the trace at C leaves D
  unmarked → swept while reachable. Marking a clean subgraph live *without
  visiting each object* needs region/page contiguity — a moving/region heap,
  which Cynic's per-object pools are not.

The root cause is information-theoretic, not implementation-specific: **deciding
an object is unreachable requires either tracing every path to it (a full
old-gen trace) or reference-counting it.** Sticky marks supply neither for the
clean old set, so a major that skips the clean old trace cannot observe old
garbage dead.

**Why Phase 0's GO was wrong.** Phase 0 measured the dirtied-old fraction
correctly (0.6% on `splay`), but a small dirtied set does not enable cheap
*reclaim*. "Skip the 99.4% re-trace" *is* "float the garbage in it" — the
marking-CPU saved is traded for RSS, which Phase 0 never measured — and the 0.6%
re-scan is itself the no-op above. The data was right; the inference ("⇒ a
~100–250× reclaiming major") was not.

**Prior art (the focused survey Phase 0 owed).** The state of the art for prompt
old-object reclamation without full-trace cost is **LXR** (Zhao, Blackburn &
McKinley, *Low-Latency, High-Throughput Garbage Collection*, 2022,
[arXiv:2210.17175](https://arxiv.org/abs/2210.17175)): it reclaims old objects
with **reference counting**, lays the heap out as **Immix regions** (a region
reclaims without per-object tracing), and uses **concurrent tracing only for
cyclic garbage**. Its own framing — *"they depend on tracing, which in the limit
and in practice does not scale"* — is exactly the `markValue` wall here. The
three escapes it uses are the only known ones: **region/line structure**
(Immix), **reference counting** (immediacy), or **concurrency** (hide the trace
off-thread). A non-moving, per-object-pool, single-threaded mark-sweep has none.
Textbook generational mark-sweep (Jones & Hosking, *The GC Handbook*) agrees:
cards make the *minor* cheap; the *major* is a full old-gen trace.

**What this means for Cynic.** The major's mark *CPU* on a large stable retained
set is a near-fixed cost for the current heap. The incremental major already
bounds the *pause* (~800 ms → ~1 ms); the CPU floor is inherent to a non-moving
full trace. The real levers — each a major architecture change, none needing
this remembered set — are an **Immix-style region heap** (region-granularity
reclaim), **reference counting** for the old gen (immediacy + a cycle
collector), or **concurrent/background marking** (move the trace off the mutator
thread — the route the multi-threaded production engines took, which Phase 0
flagged as a poor fit for a single-threaded mutator). Revisit only behind one of
those.

**Phase 1 disposition.** The mature→mature remembered set — the `dirty_old` bit
on the four container types, `old_dirty_list`, `rememberOldStore`, the 7 routed
barrier sites + the minor carry-over + the major-termination reset — was
implemented and fully validated (byte-identical by construction, `test-fast`
green, gc-stress `--gc-threshold=1` clean across
Map/class/Promise/Set/WeakRef/FinalizationRegistry), then **reverted**: it is
machinery for a major that cannot pay off. The barrier-site inventory in this
sentence is the reconstruction guide if a future region/RC effort wants it.

## The problem

The major cycle re-traces the **entire live set, O(live), from the roots,
every time**. For a workload with a large *stable retained set* — the Octane
`splay` tree, a long-lived cache, an app's module graph — most of that
re-tracing re-marks objects that did not change since the previous major.

A `sample` profile of `splay` at the bench iteration count puts `markValue`
at ~34% of CPU and GC+alloc together at ~60% — dominated by the major
re-walking the unchanged tree. The pause is already ~1 ms (incremental mark)
and the sweep is sliced (lazy sweep), so the residual cost is **marking
*work*, not pause**: the GC does the same O(live) traversal each cycle.

Sticky mark bits already eliminated the *minor* re-trace (mature marks
persist across minor cycles; `collectYoung` is O(young + dirty)). The
**major still re-walks all mature** on every cycle.

## The idea

Make the major incremental in the *generational* sense: re-mark only the old
objects that **changed since the previous major** (plus the roots), and keep
the sticky marks on the unchanged old subgraphs. The unchanged old set is
never re-walked.

The minor's win was "don't re-trace mature for a young collection." This is
the same move one level up: "don't re-trace *unchanged* mature for a major."

## What's missing today

The card-marking dirty list records **mature→young** edges only (it exists to
let `collectYoung` find young referents held by mature objects without an
O(mature) scan). It does **not** record **mature→mature** edges. `splay`'s
tree rotations rewrite `node.left` / `.right` — mature→mature pointer changes
— which the current barrier ignores (correctly, for the *generational*
purpose; a mature→mature store creates no old→young edge). A generational
major needs exactly those edges: an old object whose pointers changed is the
only old object that can make a previously-unmarked object newly reachable.

## Prior art (survey first — this is a non-trivial GC change)

Sketch from memory; **deepen before committing to a mechanism**:

- **V8 (Orinoco)** — incremental + concurrent old-space marking with a
  marking write barrier and a remembered set; majors are sliced and do not
  restart the trace from scratch within an incremental cycle.
- **JavaScriptCore (Riptide)** — concurrent generational mark-sweep; the Eden
  (young) is scavenged, the old space marked; a store barrier feeds the
  remembered set.
- **SpiderMonkey** — generational + incremental; a store buffer tracks
  tenured→nursery, the major is sliced.
- **The textbook mechanism** — a *card table* (or per-object dirty bit) over
  the old generation; at a major, re-scan only the dirty cards plus the
  roots, leaving clean old objects' marks intact. Jones & Hosking, *The
  Garbage Collection Handbook*, ch. on generational + incremental.

Open question the survey must answer: do the production engines actually
skip re-marking the clean old set per major, or do they rely on
*concurrency* (marking off-thread so the re-trace cost is hidden, not
removed)? If the latter, the lever for a single-threaded mutator is
different (concurrency, not generational-incremental), and #3 should pivot.

## Correctness — the two traps

1. **The generational-major invariant.** Every object reachable after the
   major must be marked. A clean (un-re-scanned) old object O keeps its mark;
   its referents were marked by the *previous* major and are still marked
   (sticky). The only way O can reach a *newly* live object is through a
   pointer that *changed* — and a changed pointer dirties O (the new
   mature→mature barrier), so O is re-scanned. So the invariant holds **iff
   the mature→mature barrier is complete** — the same completeness contract
   the card-marking verifier already enforces for mature→young, extended to
   mature→mature. The verifier-first gate (Debug/ReleaseSafe full re-scan +
   assert) carries straight over.

2. **Floating garbage.** An old object that became *unreachable* keeps its
   sticky mark (it's never re-traced, so it's never observed dead) and is
   not swept. A generational major therefore leaks until a periodic **full
   major** (re-trace everything, clear the sticky old marks) reclaims it.
   The interleave — N generational majors between full majors — is a
   tunable, exactly like the minor/major backstop (`gc_threshold`) today.

## The cost it trades against

- A **mature→mature write barrier** on every old-object pointer store —
  strictly more barrier work than today (which skips mature→mature). For
  `splay` (rotation-heavy mature→mature) that's a real per-store cost; it
  could *erase* the marking win. **Measure the mature→mature store rate
  before building** — if it's high relative to the marking saved, the trade
  is a loss.
- Floating garbage between full majors → higher peak RSS; bounded by the
  full-major interval.
- Real complexity + correctness risk in the most safety-critical engine
  path.

## Plan (phased; gate each on the verifier)

- **Phase 0 — measure, decide go/no-go.** Instrument two counters: (a) the
  mature→mature pointer-store rate per major (the new barrier's cost), and
  (b) the *dirtied-old fraction* per major (live set that actually changed —
  the marking saved). The change only pays if (b) ≫ (a)-equivalent. Run on
  `splay` / `richards` and a retained-cache micro. Also do the prior-art
  survey above. **If Phase 0 says no, stop here and write that up.**
- **Phase 1 — mature→mature card marking.** Extend the dirty-list barrier to
  record mature→mature stores (reuse the dirty list + the existing verifier,
  re-keyed to assert "a clean old object holds no edge to a newly-marked
  object"). No marking-policy change yet — just the remembered set, validated
  byte-identical.
- **Phase 2 — the generational major.** Re-mark from (dirtied-old ∪ roots);
  keep sticky old marks on clean objects; add the periodic full major for
  floating garbage. Differential-gate it: a generational major's surviving
  set must equal a full major's on the same heap.
- **Gate throughout:** gc-stress `--gc-threshold=1` + the differential
  (generational vs full major) + conformance byte-identical + the
  `splay`/`richards` A/B.

## Phase 0 result — GO

Instrumented the mature→mature pointer-store path (`writeBarrierRemember`'s
non-young early-return: at that point the container is already known mature
and the value a heap pointer, so a *non-young* value is exactly a
mature→mature edge) with two per-major counters — raw m2m stores, and
*distinct* m2m-dirtied containers (the set a generational major would
re-scan). Ran `splay` (40 iters, to clear the one-time setup and reach the
retained-set plateau) and `richards` (canonical 100) under `--no-jit
--unhardened --allow=eval --gc-stats`, ReleaseFast. The instrumentation is
throwaway — measured, then reverted; not merged.

**splay — the retained-set case (decisive win).** At steady state (live set
plateaued at ~913k objects plus ~600k immutable payload strings):

| metric | per major | vs live set |
|---|---:|---:|
| live objects a full major re-walks | ~913,000 | 100% |
| m2m pointer stores | ~107,000 | — |
| **distinct m2m-dirtied objects** | **~5,700** | **0.6%** |

Only ~5,700 distinct objects change between majors — the actively-rotated
splay-tree nodes (the tree is ~8k nodes, each rotated ~19× per major;
stores/distinct ≈ 19). The other 99.4% of the old object set, plus *every*
immutable payload string, is unchanged. A generational major re-scans ~5,700
nodes + roots instead of ~913k objects + ~600k strings: a **~100–250×
reduction in marking work** at steady state. This is precisely the cost the
splay profile flagged (~34% `markValue`) — almost all of it re-marking the
unchanged retained tree.

**richards — the churn / low-retention case (no benefit, no harm).** Live set
is only ~612 objects; m2m stores are huge (~195k/major) but land on just **288
distinct** objects (~690 stores each — the scheduler rewriting task/queue
links). There is nothing to save (612 objects mark in microseconds). The
barrier *sees* 195k stores, but those stores **already** run the expensive
`isYoungHeapValue` discrimination today (that early-return is where the
counter sits), so the *incremental* barrier cost over today is one dirty-bit
load per store + 288 dirty-list appends — negligible against richards'
interpreter work, and the marking it can't help was never a problem.

**Cost/benefit gate: passes decisively.** Marking saved (splay ~100–250×) ≫
barrier cost (a dirty-bit load that is ~90% already paid, plus ≤distinct
appends, repeats collapsed by the dirty bit). The mature→mature barrier reuses
the existing dirty-list + card-marking + verifier substrate, so it does not
erase the win (the lead risk below).

**Prior-art open question — answered: do *not* pivot to concurrency.** V8
(Orinoco), JavaScriptCore (Riptide), and SpiderMonkey hide the major's
old-space re-trace with **concurrent** (off-thread) marking, *not* by skipping
the clean old set — because they are multi-threaded runtimes where a GC thread
is available and concurrency hides the *whole* re-trace, not just the
clean-old portion. The "sticky marks across majors + card-mark the old gen +
periodic full major" mechanism here is the classic generational mark-sweep of
the literature (Jones & Hosking) that those engines passed over *in favour of*
concurrency. For Cynic the calculus inverts: the mutator is single-threaded by
design (one safe-point at the interpreter back-edge), so concurrency would
mean a new GC thread + concurrent-barrier races on every field — a large,
safety-critical departure. Generational-incremental-major needs none of that;
it extends the card-marking barrier and keeps sticky old marks, reusing the
incremental-mark + lazy-sweep substrate already shipped. Concurrency is the
wrong fit for a single-threaded engine; the generational path the
multi-threaded engines skipped is exactly Cynic's lever — and the measurement
says it pays. **Proceed to Phase 1.**

## Risk register

- **The mature→mature barrier erases the win** — *Phase 0 cleared this*: the
  dirtied-old fraction is ~0.6% on `splay` and the barrier reuses the existing
  dirty-list path (the costly `isYoungHeapValue` discrimination is already paid
  today). Re-check if a future barrier change adds per-store cost.
- **The invariant is subtler than the mature→young one** — the verifier-first
  discipline is mandatory, not optional.
- **The macros may not all benefit** — *confirmed by Phase 0*: `splay` is the
  clear win (retained tree, 0.6% dirtied); `richards`/`navier`/`crypto` retain
  little, so they see nothing — but also pay no meaningful barrier cost. Scope
  the *claim* to retained-set workloads.
- **Concurrency might be the real answer** — *Phase 0 answered no for Cynic*:
  the production engines went concurrent because they are multi-threaded;
  Cynic's single-threaded mutator makes generational-incremental (which reuses
  the shipped substrate) the right lever, not off-thread marking. See the
  Phase 0 result above.
