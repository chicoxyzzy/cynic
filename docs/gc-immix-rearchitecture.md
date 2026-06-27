# Immix heap + reference counting — GC rearchitecture scope

Status: **scoping** (no code; measure-first). Owner: the GC track
(user-directed). Prerequisite reading: [handbook/gc.md](handbook/gc.md) (the
shipped collector) and
[gc-generational-major.md](gc-generational-major.md) (why the in-place,
non-moving major hit an architectural floor — the motivation for going deeper).

## Why

The shipped collector is a generational, **non-moving, per-object-pool**
mark-sweep: young/mature `ArrayList(*Kind)` lists per kind,
`std.heap.MemoryPool` slabs for three kinds (object / env / string-header) and
the bare allocator for four more, sticky-bit minors, card marking, incremental
major marking, lazy sweep. Two architectural weak points remain — and
[gc-generational-major.md](gc-generational-major.md) proved the in-place fix for
the second is *foreclosed* for a non-moving collector:

1. **Per-object pools.** Allocation is a pool free-list pop; freeing is a
   per-object pool destroy; objects of a kind are scattered (no contiguity);
   freed slots are never returned to the OS. Allocation is on the hot path of
   every `new`, every closure, every array growth.
2. **The mark is O(live), every major.** `markValue` re-traces the whole live
   set; on a large stable retained set (`splay`) that is ~34% of CPU re-marking
   an unchanged tree. The generational-major attempt to *skip* it is
   information-theoretically foreclosed non-moving (you cannot establish
   unreachability without a full trace or reference counting).

The modern answer to both — and the current state of the art — is **LXR**
(Zhao, Blackburn & McKinley, *Low-Latency, High-Throughput Garbage Collection*,
2022, [arXiv:2210.17175](https://arxiv.org/abs/2210.17175)): an **Immix
region/line heap** (fixes #1; adds locality + bulk reclaim + optional defrag)
plus **reference counting** (fixes #2 — reclaim without tracing; *"they depend
on tracing, which in the limit and in practice does not scale"*) with
**concurrent tracing only for cycles**. This doc scopes adopting that design, in
two steps, **measure-first**.

## The clean part — what stays

The storage-survey is encouraging: the **mark substrate is interface-stable**
and carries over nearly unchanged, because it operates at the Value/pointer
level, not the storage level. KEEP:

- mark colour (`mark_color` / `live_color`), `marking_phase`, the mark worklists
  + `drainMarkWorklist[Budget]`, the **Dijkstra write barrier**, the
  **card-marking dirty list** remembered set, weak-aware marking + the ephemeron
  fixpoint, the conservative native-stack scan, handle scopes, and the
  incremental safe-point hooks.

REPLACE — purely the storage substrate: the 7 per-kind young/mature
`ArrayList(*Kind)` pairs, the 3 `QuarantinedPool`/`MemoryPool` slabs + the 4
direct-allocator kinds, the per-kind `allocate*` functions, and the
`sweepList`/`promoteYoungList` type-dispatch + swapRemove walk. The mark phase
touches storage through a **narrow interface** — iterate live objects;
read/write a per-object `mark_color`/`generation`/`dirty`/`pinned`; free dead —
so the swap is contained *in principle* (the friction is below).

## Step 1 — the Immix heap (foundation, non-moving first)

Replace the per-kind pools + lists with a single **block/line** heap:

- **Blocks** (e.g. 32 KiB) carved into **lines** (e.g. 128–256 B). Allocation
  bump-points into the current line's hole; an object that doesn't fit skips to
  the next hole/line; a fresh block is grabbed when the current fills.
- **Line marks** fall out of object marks (a line is live iff it holds a live
  object). Sweep reclaims **empty lines/blocks wholesale** (bulk, vs per-object
  pool destroy) and recycles partially-free blocks' holes.
- **Large-object space (LOS)** for objects above a line/block threshold (big
  `JSFunction`s, large `JSBigInt` limb arrays, ArrayBuffer payloads) —
  separately managed, not bump-allocated.
- **Generational, non-moving.** Keep the young/mature distinction at *block*
  granularity; the sticky-bit minors + card-marking remembered set carry over
  (they're mark substrate). **No evacuation in Step 1** — only fully-empty
  lines/blocks reclaim; fragmentation is accepted and addressed later (Step 3).
  This keeps the **non-moving contract** (FFI, handle scopes, raw native
  pointers held across safe-points) intact.

Standalone wins: bump allocation (vs pool pop), bulk empty-region reclaim,
allocation locality. **The mark is still a trace** — Step 1 does not reduce
`markValue`; it fixes allocation, reclaim, and locality. splay's mark CPU is
Step 2's job.

## Step 2 — reference counting on Immix (the trace-scaling fix)

LXR's core: reclaim most objects by **reference counting** (a coalescing inc/dec
barrier on pointer stores), reclaiming acyclic garbage *immediately* (no trace),
and run **tracing only to collect cycles** (infrequently, eventually
concurrently). For `splay` — an acyclic tree with acyclic payloads — RC reclaims
the churn directly and the trace all but disappears. This is the piece that
*reduces* the mark CPU rather than hiding it, and it is what makes the heap
scale. It is **not optional** here — see challenge #1.

## Cynic-specific challenges (the Phase 0 must weigh these honestly)

This is not a clean port; Cynic's object model adds real friction:

1. **Objects own external heap resources.** A `JSObject` owns a property map +
   accessor maps + element buffers; `JSString` owns its byte payload;
   `JSGenerator` a register file; `JSBigInt` a limb array. These need explicit
   `deinit` on object death. Immix reclaims at **line granularity** — a dead
   object sharing a line with a live one is not individually reclaimed, so its
   external resources would **leak until the line frees**. Mark-sweep Immix must
   therefore still per-object-sweep-for-deinit (eroding the bulk-reclaim win),
   *or* pull those resources into the managed heap, *or* lean on **RC** for
   prompt per-object deinit (refcount→0). This is the strongest reason Step 2
   (RC) is what makes the structure pay — and a reason Step 1 alone may
   underwhelm.
2. **No uniform object header.** Line sweep must identify an object's type +
   size from its address. Today only four kinds share a `HeapKind` tag
   (function/object/symbol/bigint); `JSString`/`Environment`/`JSGenerator` are
   distinguished by Value tag / context, not a header tag. Immix needs a
   **uniform header** (type + size) on every managed object — a layout change to
   every heap struct.
3. **Wide size variance.** `JSObject` ~408 B, several headers ~48 B, big
   `JSFunction`s / BigInts / ArrayBuffers far larger → the LOS split + the
   line-fit policy must be tuned to the real distribution (Phase 0 measures it).
4. **The RC barrier cost.** A coalescing inc/dec barrier runs on the
   interpreter's hot store path; it must not erase the win. Measure-first.
5. **Untrusted-input robustness.** Every change is in the never-abort-the-host
   path; a botched line-sweep or RC barrier is a UAF on adversarial JS. The
   verifier-first discipline + gc-stress `--gc-threshold=1` carry over, and (for
   the eventual concurrent cycle-tracer) extend to data races.

## Phase 0 — measure + prototype, decide go/no-go

Before any rewrite, establish that the foundation pays and size the design:

- **(a) Cost breakdown.** Instrument the macros (`splay`, `richards`,
  `ctor_array_build`) to split GC+alloc CPU into **alloc** (pool draw) vs
  **sweep/free** (per-object deinit + pool destroy) vs **mark** (`markValue`).
  If alloc+sweep is a meaningful slice, the Immix foundation pays directly; if
  it's almost all mark, Step 1 buys little and the value is concentrated in Step
  2 (RC) — which reframes the sequencing (maybe RC-first on the existing pools).
- **(b) Object-size + external-resource census.** Per kind: count, size
  distribution, and the fraction of objects owning external heap resources (the
  deinit-promptness exposure, challenge #1). Sizes the LOS threshold, the line
  size, and how badly #1 bites.
- **(c) Bump-allocator microprototype.** A standalone block/line bump allocator
  vs the current `MemoryPool`, on the measured size distribution — confirm the
  alloc-throughput delta in isolation before committing to the rewrite.
- **(d) Prior-art deep read.** LXR + the Immix paper (Blackburn & McKinley 2008)
  — block/line sizing, the hole-finding allocator, line marking, the RC
  coalescing barrier, cycle collection — pulled into the design before building.

**If Phase 0 shows the foundation doesn't pay** (mark-dominated, or the
external-resource friction outweighs the bump/locality win), **stop and write
that up** — exactly the discipline the generational-major Phase 0 owed (it
priced the marking saved but not the RSS traded).

## Phased plan (each gated)

1. **Immix heap, non-moving** — uniform header + block/line bump allocator + LOS
   + line-sweep, generational (block-level young/mature, card marking kept).
   Gate: conformance byte-identical, gc-stress `--gc-threshold=1`, an
   alloc/locality A/B on the macros.
2. **Reference counting on Immix** — coalescing inc/dec barrier + a cycle
   collector (backup trace). Gate: a differential against the tracing collector
   (identical surviving set), gc-stress, the macro A/B (the splay `markValue`
   fix).
3. **(optional) Opportunistic evacuation** — defrag fragmented blocks via
   limited copying; needs pointer-updating, so it **breaks non-moving** — gated
   separately, behind a full audit of raw pointers held across safe-points.
4. **(optional) Concurrent cycle tracing** — move the backup trace off-thread
   (the LXR design), with the race-robustness gate (ThreadSanitizer + concurrent
   interleaving stress + the verifier extended to the concurrent barrier).

## Risk register

- **Biggest blast radius in the engine** — a heap-storage *and* collector
  rewrite; months, not weeks. The keep/replace boundary (mark substrate stays)
  bounds it, but Step 1 alone touches every `allocate*`, the sweep, and every
  heap struct's header.
- **Value may be back-loaded.** External-resource ownership (challenge #1) can
  make Step 1 (mark-sweep Immix) underperform until Step 2 (RC) lands; the win
  may not show until the second phase.
- **The RC barrier** may tax the interpreter's hot path (Phase 0 (c)/(d) sizes
  it).
- **Non-moving contract** is preserved through Steps 1–2; Step 3 (evacuation)
  breaks it and must be gated behind the raw-pointer audit.
- **It may not pay at all.** Phase 0 is the gate. A well-supported "the
  per-object pools are not the bottleneck — the mark is, and only RC moves it,
  so do RC-first / don't bother with Immix" is a valid and cheaper-to-reach
  outcome, and writing *that* up is a real result.
