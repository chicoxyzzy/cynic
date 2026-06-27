# Reference counting — GC rearchitecture scope

Status: **scoping** (no code; measure-first). Owner: the GC track
(user-directed). Prerequisite reading: [handbook/gc.md](handbook/gc.md) (the
shipped collector), [gc-immix-rearchitecture.md](gc-immix-rearchitecture.md)
(the Phase 0 (a) measurement that redirected here — allocation is not the
bottleneck; the *mark* is, and only RC reduces it), and
[gc-generational-major.md](gc-generational-major.md) (the non-moving floor).

## Why RC — and why it's the *only* GC lever the data justifies

The Immix Phase 0 (a) breakdown found `splay`'s GC cost is ~62% **mark** —
re-tracing the stable retained tree every major — with allocation a ~2–5%
sliver. A tracing collector must re-establish reachability every cycle;
**reference counting does not.** Each object knows its own in-degree; it dies the
moment its last referrer drops it (refcount→0), reclaimed with *no trace*. For
`splay` — an acyclic tree with acyclic payloads — RC reclaims the churn
immediately and the retained tree is **never re-examined**, cutting the ~62% mark
to near-zero. This is the one rearchitecture the measured costs support.

The catch the same measurement surfaced: RC's cost is a **barrier on every
pointer store**, and that taxes *every* workload — including the compute-bound
ones (`richards`, ~85% mutator) that get **no** RC benefit. So RC is a bet that
the barrier is cheap enough that the retained-set win outweighs the universal
tax. That is exactly what Phase 0 must measure before any rewrite.

## The design — coalescing RC + the existing tracer as the cycle backstop (LXR shape)

Naive RC (inc/dec on every store, free-on-zero with a recursive dec cascade) is
correct but its per-store arithmetic is a known throughput loser. The affordable
form is **coalescing RC** (Levanoni & Petrank 2001; the scheme LXR builds on):

- **Coalescing log barrier.** On the *first* modification of an object in a GC
  epoch, log its current pointer-slot values and set a *logged* bit; subsequent
  stores to that object skip the log. At the epoch boundary the collector
  computes, per logged object, the net refcount delta (epoch-start logged slots
  vs current slots — dec the dropped referents, inc the added). All intra-epoch
  churn to a slot collapses to one net inc/dec. The hot-path barrier is a
  bit-test + an occasional slot-copy, **not** per-store refcount math.
- **Free-on-zero with cascade.** When a decrement drives a refcount to zero, the
  object is reclaimed and its children decremented (via a work list) — prompt
  per-object reclaim, which also dissolves the external-resource
  deinit-promptness problem the Immix doc flagged (`deinit` fires exactly at
  death, not at line-reclaim).
- **Cycles → the existing tracer, run infrequently.** RC cannot reclaim cycles
  (a cycle keeps its own refcounts > 0 when unreachable). Cynic already has a
  complete mark-sweep tracer; **reuse it as the periodic backup cycle collector**
  (the LXR shape: RC for the common case, tracing only for cycles). Cadence is a
  tunable — too rare floats cyclic garbage (RSS), too frequent reintroduces the
  trace cost RC removed.

This is a **hybrid, not a replacement**: RC drives common-case reclaim; the
shipped tracer demotes to the infrequent cycle backstop.

## What stays / what changes

- **Stays:** the mark substrate (`markValue`, the worklist, weak-aware marking,
  the ephemeron fixpoint, handle scopes) — now the *cycle collector*, run on a
  long cadence rather than every major.
- **Changes:** every heap object gains a **refcount + a logged bit** (a layout
  change to each struct, like Immix's uniform-header need); the **store path**
  gains the coalescing log barrier (subsuming the card-marking dirty barrier —
  the remembered set folds into the modified-object log); reclaim flips from
  sweep-driven to refcount-zero-driven, with the tracer only for cycles.

## Cynic-specific challenges (the Phase 0 must weigh these)

1. **Barrier completeness on *every* pointer store.** A missed log → a wrong
   refcount → a premature free (UAF) or a leak. This is far broader than card
   marking (mature→young only): *every* pointer-field write in the engine (object
   slots, array elements, environment slots, every typed internal slot) must
   route through the log barrier. The completeness audit + the verifier (a
   periodic refcount-vs-trace recount under ReleaseSafe) are mandatory and larger
   than the card-marking audit. **This is the most safety-critical change the GC
   has taken on** — in the never-abort-the-host path, every missed site is a UAF
   on adversarial JS.
2. **A universal tax for a narrow benefit.** The log barrier costs every
   workload; only retained-set workloads (`splay`) benefit. `richards`-class
   (compute-bound, store-heavy scheduler) pays and gains nothing — it could
   *regress*. The net is workload-mix-dependent — **the decisive Phase 0
   measurement.**
3. **Cycle-collection cadence + floating cyclic garbage.** JS is cycle-rich
   (closures capturing each other, back-references, the realm graph). The backup
   trace must run often enough to bound cyclic-garbage RSS but rarely enough to
   keep RC's win — a tunable like the full-major interval, measured.
4. **The refcount + logged-bit layout** — per-object overhead on every heap
   struct.
5. **Robustness under untrusted JS** — verifier-first + gc-stress
   `--gc-threshold=1` + a refcount-vs-trace differential, throughout.

## Phase 0 — prototype the barrier, measure the tax, decide go/no-go

Unlike the Immix Phase 0 (a) (measurable on the shipped engine), RC's go/no-go
needs a **prototype of the hot-path barrier** — not the full collector:

- **(a) Barrier-cost prototype.** Implement the coalescing log barrier (the
  modified-object log + the logged bit + the slot-copy) on the store path,
  *without* the refcount reclaim (the barrier is the hot-path variable; the
  reclaim is off the hot path). Measure the throughput hit on the macros + the
  property/array micros.
- **(b) The trade.** Weigh the barrier tax (every workload) against the mark
  saved (`splay` ~62%, `richards` ~1%). Go only if the net is positive across the
  workload mix — specifically **if the `richards`-class regression < the
  `splay`-class gain.** If the barrier taxes compute-bound workloads more than it
  frees retained-set ones, RC is a net loss and we stop — a valid, cheap-to-reach
  outcome, exactly as Immix Phase 0 (a) was.
- **(c) Prior-art deep read.** Levanoni & Petrank (coalescing / sliding-views
  RC), Bacon & Rajan (cycle collection by trial deletion), LXR (the RC + backup
  trace hybrid, [arXiv:2210.17175](https://arxiv.org/abs/2210.17175)) — pulled
  into the design before building.

## Phased plan (each gated)

1. **Coalescing log barrier + modified-object log** (no reclaim yet) —
   byte-identical conformance, the barrier-cost A/B (Phase 0 (a)). Gate.
2. **Refcount maintenance + free-on-zero cascade** — the refcount field, the
   epoch-boundary net-delta processing, prompt reclaim. Gate: a
   refcount-vs-trace differential (every object's computed refcount equals its
   true in-degree), gc-stress, the macro A/B (`splay`'s mark fix).
3. **The tracer as cycle backstop** — run it on a cadence to collect cycles; tune
   the interval against cyclic-garbage RSS. Gate: no leak of cyclic garbage (a
   stress with deliberate cycles), conformance.

## Risk register

- **The barrier tax may exceed the win** (Phase 0 (a) catches this) — RC helps a
  narrow workload class and taxes all; the net is not obvious and must be
  measured before any rewrite.
- **Every-store barrier completeness** is the largest robustness surface the GC
  has taken on; a single missed site is a UAF. Verifier-first is mandatory, not
  optional.
- **Cyclic garbage floats** between backup traces — bounded by the cadence, an
  RSS/throughput tunable.
- **Biggest collector-core change** — flips reclaim from sweep- to
  refcount-driven; the tracer demotes to a cycle backstop. Months, high blast
  radius.
- **Narrow payoff** — even if it pays, it helps retained-set workloads;
  compute-bound workloads (the `richards` class) are bottlenecked on the
  interpreter/JIT, untouched by any GC change. This bounds the *claim*, not just
  the work.
