# Parallel GC for Metla — design note

Status: **design only.** Cynic's GC (*Metla*) is a stop-the-world,
non-moving, generational mark-sweep collector over per-type pools
([docs/handbook/gc.md](handbook/gc.md), [ARCHITECTURE.md](ARCHITECTURE.md)
§Garbage collection). Parallel/concurrent collection is listed as
future work (gc.md §Future work; ARCHITECTURE.md "Concurrent collection
is M5+"; ROADMAP.md "Incremental / concurrent GC marking") with prior-art
pointers but no detailed plan. This note is that plan, and — importantly
— the **honest case for when it does and does not pay off**, so we don't
repeat the aging mistake of assuming a win and measuring last
([gc-generational-aging.md](gc-generational-aging.md)).

## What "parallel GC" means here (three distinct things)

These are routinely conflated; we want only the first two, and only the
first to start:

1. **Parallel marking (stop-the-world).** The mutator is *paused*; N GC
   threads cooperatively trace the live graph. No mutator/collector
   interleaving, so **no write-barrier changes** — the existing
   dirty-container barrier (`4ce56ff`) is untouched. This is the cheap,
   safe win and the only thing Stage 1 does.
2. **Parallel sweep (stop-the-world).** N threads reclaim dead slots
   across the per-type pools after marking. Embarrassingly parallel.
3. **Concurrent marking.** GC threads trace *while the mutator runs*.
   Requires a tricolor-invariant write barrier (SATB / Dijkstra) so the
   mutator can't hide a live object from the collector. This is the hard
   one — it targets **pause latency**, not throughput — and is deferred
   (M5+). Do NOT start here.

## Prior art (what to borrow, and from where)

- **V8 *Orinoco*.** Parallel Scavenger (young gen, *moving* — multiple
  threads evacuate), concurrent + parallel major marking (Dijkstra
  incremental-update barrier), concurrent/parallel sweep. The marking
  *parallelisation* is the relevant part; the *moving* nursery is not
  (see below).
- **JSC *Riptide*.** Concurrent, generational, mostly-copying Eden +
  **non-moving old gen**, lock-free-ish concurrent marker with a
  Dijkstra barrier and a per-thread mark stack. Riptide's *non-moving
  old gen* is the closest analogue to all of Metla and the best model
  for our marker.
- **SpiderMonkey.** Parallel marking (work-stealing mark stacks) +
  background (off-thread) sweeping + incremental GC with a snapshot
  barrier. Their parallel-marking work-stealing design is a good
  reference for Stage 1.
- **Hermes *Hades*.** Concurrent mark-sweep old gen + a young gen — a
  good example of a small-footprint engine adding concurrency.
- **Foundations.** Tricolor abstraction (Dijkstra et al.), work-stealing
  deques (Arora/Blumofe/Plaxton; Chase/Lev), SATB (Yuasa) vs
  incremental-update (Dijkstra-Steele) barriers. See
  [handbook/prior-art.md](handbook/prior-art.md) §academic-literature and
  the `arxiv` MCP for the papers.

**Key leverage Metla already has: it is non-moving.** Objects never
change address (promotion is a list relink, addresses stable). So
parallel marking is *only* "trace + dedup the grey set" — there is **no
evacuation, no forwarding pointers, no pointer-update race**, which is
the single hardest part of V8's parallel Scavenger. Metla's generic
`markAllPointerFields` (factored out for the dirty-container barrier) is
already the per-object trace function a parallel marker drives. This is
why parallel *marking* is the tractable first step for Cynic
specifically.

## The honest performance case (read this before writing code)

Parallel marking trades **thread wake-up + work-distribution + sync
overhead** for **divided marking wall-time**. It is a net win **only when
single-threaded marking is itself a meaningful fraction of wall-time** —
i.e. a **large live set**. Concretely:

- For the bench-fixture-sized heaps (a few hundred KB, live sets in the
  thousands of objects), a single-threaded mark is microseconds. Spinning
  up worker threads to split that **will regress** — the sync overhead
  dominates. Most short-lived JS programs live here.
- The win appears for **large, long-lived heaps** (hundreds of MB, live
  sets in the millions) where a single mark is milliseconds and the
  mutator pause is user-visible. That is a real target for *some*
  embeddings (a long-running Worker, a server holding a big object
  graph) but **not** the alloc-churn cross-bench fixtures.

**Therefore parallel GC must be gated on a live-set-size threshold** —
single-threaded below it (the default, the reference path), parallel
above it. Always-on parallel GC is a pessimisation for the common case.
This is the aging lesson made concrete: *measure the win on the actual
target workload before assuming it; a GC change that's correct can still
be a net loss.* If the target embeddings don't have large heaps, parallel
GC may not be worth its maintenance cost at all — decide that first.

## Stage 1 — parallel stop-the-world marking

### Mark-bit thread-safety (the one real correctness hazard)

Today `JSObject.mark_color: u1` (and the per-type equivalents) is written
non-atomically. Under parallel marking, two threads can reach the same
object concurrently. Marking is *idempotent* (both set
`mark_color = live_color`), so the value is never wrong — but both
threads would also **push the object onto their grey deque**, double-
tracing it (wasteful) and, worse, racing the read-modify-write of the
mark field with a torn result on some ABIs.

Fix: an **atomic claim**. Widen the mark field to an atomic-addressable
unit and claim each object exactly once:

```
claim(obj):                       // returns true iff this thread greys it
    return @cmpxchgStrong(&obj.mark_atom, unmarked, live_color, .acq_rel, .monotonic) == null
```

The winner greys the object (pushes its children); losers skip. Roots are
claimed the same way. This keeps the grey set deduplicated and the mark
race benign-by-construction. (Single-threaded mode keeps the cheap
non-atomic path via comptime/flag, so the default loses nothing.)

### Work distribution: work-stealing deques

Each GC worker owns a **Chase-Lev work-stealing deque** of grey objects.
A worker pops from its own bottom (LIFO, cache-friendly); idle workers
**steal** from the top of others' deques. Termination via a shared
"active worker" counter (a worker that finds all deques empty + zero
active others is done). Seed by partitioning the roots across workers.
The whole driver is a thin layer over the existing
`markRoots` + `markAllPointerFields` — keep those unchanged.

### Threading substrate + the per-realm-pool interaction

The test262 harness already runs N worker *threads*, each with its own
realm + heap, each able to collect. If every realm's GC spun up its own
helpers, that is N×M thread explosion. So:

- **One shared, bounded GC thread pool** (sized to `cpu_count`), borrowed
  for the duration of a collection. A realm that wants to parallelise a
  collection acquires workers from the pool; if none are free (other
  realms collecting), it falls back to single-threaded. No nested
  parallelism, no oversubscription.
- For the **product** (an embedder running one or a few realms) this is
  the right model; for the **harness** (many small realms) the size
  threshold above means most collections stay single-threaded anyway, so
  the pool is rarely contended.

### Maintainability rules (the "smart way")

- The single-threaded marker stays the **default and the reference**.
  Parallel is a flag + threshold opt-in. Both call the *same*
  `markAllPointerFields` — no forked per-type marking logic to drift.
- No new write barrier in Stage 1 (STW). The dirty-container barrier is
  untouched.
- The atomic-claim is the *only* new invariant; document it next to
  `mark_color` and assert it in the GC verifiers.

## Stage 2 — parallel sweep

Partition each per-type young/mature list into ranges; each worker sweeps
a range, freeing dead slots. The pools' free-lists are the contention
point — give each worker a **thread-local free batch** and splice them
into the pool free-list once at the end (single lock), instead of locking
per free. Non-moving means no compaction to coordinate.

## Stage 3 — concurrent marking (deferred, M5+)

Only when pause *latency* (not throughput) is the goal. Mark on
background threads while the mutator runs; the dirty-container barrier
gets extended to also satisfy the tricolor invariant (SATB: shade the
*overwritten* referent grey at each store; or Dijkstra: shade the *new*
referent). The existing barrier funnel is the natural hook, but this
re-opens a large correctness surface (floating garbage, the
snapshot-at-the-beginning vs incremental-update choice, the
mark-stack/mutator races) and should get its **own** note when its day
comes.

## Phased implementation plan

1. **Atomic mark-claim**, behind a comptime/flag so single-threaded stays
   non-atomic and free. Land + gate this alone first (it's
   behaviour-preserving single-threaded).
2. **Work-stealing parallel mark, STW, threshold-gated.** Shared GC
   thread pool. Parallelise only the mark phase; sweep stays serial.
3. **Parallel sweep.**
4. (Deferred) **concurrent marking** — separate note.

## Hard validation gate

- `zig build test-fast` + new unit tests for the work-stealing deque
  (push/pop/steal under contention, with a finite backstop) and the
  atomic claim.
- gc-stress `--gc-threshold=1` ReleaseSafe, **single- and multi-threaded
  harness**, across `built-ins/{Object,Array,Promise}`,
  `language/expressions`, `language/statements/class` — filtered +
  `timeout`-wrapped (never the unfiltered sweep). The GC verifiers +
  `0xaa` free-poison must stay clean under the parallel marker.
- A **race audit** — ideally a ThreadSanitizer build of the marker path,
  or a stress harness that forces many small parallel marks; the
  atomic-claim is the whole correctness story, so prove it.
- A **new large-heap bench** (build a multi-million-object graph, force a
  full mark) to exercise + measure parallelism — the existing micros are
  too small to show anything.
- Bench A/B: **no regression on the small-heap micros** (proves the
  threshold gate works) **and** a measured win on the large-heap bench.
- Full `zig build test262` ≥ baseline. **Revert on any race or crash.**

## Honest caveat (the aging lesson, restated)

Parallel marking is correct-and-useful technology, but its payoff is
**workload-dependent and large-heap-only**. On Cynic's typical
small-heap, short-lived workloads it does nothing (and, un-gated, hurts).
Before investing, decide whether large-heap, pause-sensitive embeddings
are a real target — if they are, Stage 1 (threshold-gated parallel mark)
is the right, bounded, maintainable first step; if they aren't, the
maintenance cost may not be worth it. Either way: **gate on heap size,
keep the single-threaded path the default, and measure on the real target
before committing.**
