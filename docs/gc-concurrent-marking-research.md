# Incremental / concurrent marking — research note

> Status: **research only** (2026-06-22). No code. This is the note that
> [gc-parallel.md](gc-parallel.md) §Stage 3 deferred ("concurrent marking
> … should get its **own** note when its day comes") — plus the option
> that note skips: **incremental** marking. It assesses both against
> Metla's actual substrate and recommends a path. The throughput GC work
> it builds on — sticky mark bits, card marking, the adaptive major
> trigger — is shipped ([handbook/gc.md](handbook/gc.md),
> [gc-generational-aging.md](gc-generational-aging.md)).

## Why — the problem this solves

A **latency** play, not throughput. After card marking made the minor
cycle O(young + dirty) and the adaptive trigger made majors rare, the
remaining GC cost is the **major** (`Heap.collectFull`): a
**stop-the-world** O(live) mark + sweep. On a large retained heap that is
the p99/p100 pause and it scales with the live set — Splay's ~250k tree
is a few ms STW; a server holding a big object graph is worse. Throughput
is competitive; what a latency-sensitive embedder (a request server, a
Worker) feels is that occasional freeze.

## Three ways to attack the pause (and how they relate)

Same goal — shrink the major pause — three different mechanisms:

1. **Parallel STW marking** — keep stopping the world, but trace with N
   threads so the pause is *shorter*. No write-barrier change (the mutator
   is paused). Covered by **[gc-parallel.md](gc-parallel.md) Stage 1**;
   win is large-heap-only and it is the cheap/safe first step *if* the
   target is throughput-of-the-pause.
2. **Incremental marking** — *slice* the mark into small increments
   interleaved with the mutator **on the same thread** (drain K worklist
   items at a safe-point, run JS, repeat). Bounds the *max* pause without
   a second thread. Needs a tri-color barrier (the mutator mutates between
   slices). **Neither existing doc covers this — it is the missing middle**
   and, per the substrate below, the best-fit first latency step for Cynic.
3. **Concurrent marking** — trace on a **separate thread** while JS runs.
   Hides nearly all mark pause; needs the tri-color barrier *and* a full
   thread-safety story. gc-parallel.md §Stage 3 / ROADMAP M5+ defers it;
   this note is its deep-dive.

Parallel-STW and incremental are *orthogonal* (you could do both); pick by
goal — parallel shortens the pause, incremental bounds it.

## Metla substrate — what helps (file:line)

- **Non-moving.** Promotion is a list relink, addresses never change
  (`promoteYoungList`, `heap.zig:3326`). So an incremental/concurrent
  *non-moving* marker needs **no read barrier and no forwarding pointers**
  — the hardest part of concurrent *moving* collectors is simply absent.
- **Worklist-driven trace.** `mark_worklist` (`heap.zig:751`) +
  `mark_env_worklist` (`:757`), pushed via `enqueue` (`:1606`), drained by
  `drainMarkWorklist` (`:2677`). The unbounded chains (proto, closure-env,
  promise-reaction) are already on the worklist; only *bounded* per-object
  recursions remain inline (`markGenerator`/`markEnvironment`, e.g.
  `:1862`, `:2395`). So the trace is **sliceable at object granularity**
  today.
- **A safe-point that already gates GC.** `runSafePoint`
  (`lantern/interpreter.zig:991`) runs at loop back-edges + frame entries
  (not every opcode) and already decides minor-vs-major. An increment
  (`if (marking) drainMarkWorklist(K)`) drops straight in; the
  accumulator/ip are synced there, so the live value is a root.
- **A write-barrier choke point, already incremental-update-shaped.**
  `Heap.writeBarrier` (`heap.zig:4573`) fires at every routed store and
  **already inspects the value being stored** (`isYoungHeapValue(v)`,
  `:4604`). All typed-slot setters + `storeProperty`/`storeElement` funnel
  through it. This shape *is* a Dijkstra barrier with a generational
  predicate — see the gap.
- **Single-threaded heap, zero GC synchronization.** Each realm-cluster
  owns its `Heap` (`heap.realms`, `heap.zig:413`; one thread, even across
  ShadowRealm children). The harness parallelism is *separate heaps per
  fixture* (`tools/test262.zig:2827`); `$262.agent`/Workers get their own
  heaps; `SharedArrayBuffer` shares raw **non-GC** bytes
  (`shared_data_block.zig`), never objects. `heap.zig` contains **zero**
  `Thread`/`atomic`/`Mutex` (the agent verified across 5736 lines). So
  *incremental* needs no synchronization at all; *concurrent* must import
  the entire thread-safety story from nothing.

## The gap — what's missing

**For incremental:**
1. **Tri-state color.** Today the mark is binary (`mark_color == live_color`,
   `object.zig:897`; `live_color`, `heap.zig:686`) — no white/**grey**/black
   distinction, so the barrier can't tell "queued-not-scanned" from
   "scanned." Need a grey state (a tri-state field, or treat
   worklist-membership as grey).
2. **A tri-color write barrier.** The existing barrier is *generational*
   (old→young only: the `container.generation() != .mature` reject at
   `heap.zig:4594` + the young-value reject at `:4604`). Add a color arm.
   **Dijkstra/incremental-update is the smaller delta** — it shades the
   *new* referent, reusing the existing "inspect the stored value at the
   store funnel" shape. **SATB is the larger delta** — it shades the
   *overwritten* referent, which means loading the old field value at
   every store site, which no funnel surfaces today. (gc-parallel.md:165
   lists both; for Cynic specifically, Dijkstra wins on delta size.)
   Dijkstra's cost — a STW mark-termination root re-scan — is cheap here
   because `markRoots` (`realm.zig:1820`) already does a precise root walk.
   The barrier must *layer* with the generational dirty-list barrier (keep
   the nursery win): "generational edge → remember; marking-active &
   tri-color violation → shade."
3. **Resumable marking state.** `collectFull` re-seeds all roots inline
   then drains in one shot (`:2888`). Incremental needs a persistent
   "marking active" flag, root seeding as a one-time start step, and the
   weak-ref pass (`processWeakReferences`, the ephemeron fixpoint
   `:2072`) re-timed off "mark complete" instead of atomic completion.
4. **Allocate-black.** Objects born during a marking phase must not be
   swept; the pool `create` paths (`heap.zig:782+`) need to stamp the
   marking color when marking is active. None today.

**For concurrent, additionally** (the much bigger leap):
5. **Atomic mark-claim** (`@cmpxchgStrong`) — and `mark_color` is packed
   in a byte with `generation`/`dirty`/`needs_internal_scan`
   (`object.zig:897-931`), so the mark bit must move to its own atomic
   word or those neighbours become torn-write data races.
6. **A GC thread pool** (gc-parallel.md:126-140 already specs one, shared
   + bounded, to avoid N×M realm explosion), work-stealing deques, a
   termination protocol, and **cross-thread stack-root publication** (the
   conservative native scan `heap.zig:2813` is thread-local — a marker
   thread can't see the mutator's native stack).
7. **Hardening.** A marker reading a heap mutated by *untrusted* JS must
   never race into a panic/segfault (never-abort-the-host); a missed
   tri-color barrier is a use-after-free, "worse than a SIGABRT." Mandates
   a ThreadSanitizer build + adversarial stress (gc-parallel.md:185-194).

## Prior art (non-moving matches are the relevant ones)

- **JSC Riptide** — concurrent, generational, **non-moving** old gen,
  Dijkstra barrier + per-thread mark stack. Closest twin to Metla.
- **Go** — concurrent tri-color, non-moving, **hybrid barrier** (Yuasa +
  Dijkstra, drops the stack re-scan). Cleanest non-moving concurrent ref.
- **Hermes (Hades)** — non-moving concurrent mark-sweep, same (JS) domain.
- **V8 Orinoco** — incremental → concurrent, Dijkstra barrier + worklist;
  the reference for incremental structure + generational interaction.
- **SpiderMonkey** — incremental in slices + an SATB barrier.
- Foundations (textbook/journal, not arXiv — it's classic systems work):
  Dijkstra/Lamport 1978 (tri-color/on-the-fly), Yuasa 1990 (SATB), Jones/
  Hosking/Moss *GC Handbook*. (arXiv searched — only tangential hits, e.g.
  incremental *copying* for Prolog, which is moving and N/A.)

## Recommendation

**Incremental major marking, Dijkstra barrier — and decide the motivation
first.**

0. **Confirm the target.** gc-parallel.md's honest caveat applies double
   here: incremental *adds* a per-store barrier arm (mutator overhead) to
   buy pause latency. It only pays for **large-heap, pause-sensitive**
   embeddings. Confirm such a workload is a real target before building —
   throughput is already good and this is not free.
1. **Marking state machine** — split `collectFull` into
   `idle → marking (drain K/safe-point) → termination (STW: drain + root
   re-scan) → sweep`; persistent marking flag; allocate-black.
2. **Dijkstra tri-color barrier** at the existing `writeBarrier` funnel
   (shade the stored referent grey when marking is active), layered over
   the generational barrier. Build the tri-color verifier (full-scan +
   "no black→white edge" assert in Debug/ReleaseSafe) and audit to clean —
   **the card-marking verifier-first methodology transfers directly**; a
   missed barrier is a swept-live bug caught as an assert, not a UAF.
3. **Measure pause distribution** (max/p99 STW, not throughput) on Splay +
   a large-heap synthetic; confirm the barrier overhead doesn't erode the
   card-marking/adaptive throughput wins.
4. **Concurrent (deferred, M5+)** — only if incremental's residual
   termination pause is still too high. Then import the gc-parallel.md
   Stage-1 substrate (atomic claim, thread pool) + the hardening review.

Keep minor cycles STW (already cheap) and the single-threaded marker the
default/reference. Note: **parallel-STW marking (gc-parallel.md Stage 1)
is the lower-risk move if the goal is throughput-of-the-pause** rather than
bounded latency — choose the axis by the actual requirement.

## Open questions / risks

- **Is the pause a real pain point?** (settle before building — see step 0).
- **Barrier overhead** — Dijkstra fires on pointer stores during marking;
  measure net vs the throughput gains.
- **Floating garbage** — incremental retains mid-mark deaths to the next
  cycle; bounded, but quantify on churny workloads.
- **Generational interaction** — the incremental target is the *major*;
  minors stay STW and feed the snapshot. Confirm the sticky-mark colour
  flip composes with a paused mark wavefront.
- **Weak refs / FinalizationRegistry timing** — re-derive off "mark
  complete" (`processWeakReferences`, ephemeron fixpoint); spec timing is
  implementation-defined (§26.1) so this is legal, but the code assumes
  atomic completion.
