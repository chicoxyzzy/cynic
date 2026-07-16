# Garbage collection

Generational mark-sweep (the *Metla* GC), triggered on allocation
pressure. The minor cycle is stop-the-world; the **major mark is
incremental** — sliced across interpreter safe-points to bound the pause
(see *Incremental major marking* below). Each per-kind heap list is split into a `_young`
and a `_mature` half; allocations land in `_young`, and survivors of
a minor cycle are spliced into `_mature` by `promoteYoungList`. Lives
in [`src/runtime/heap.zig`](../../src/runtime/heap.zig); the trigger
and root walker live in
[`src/runtime/realm.zig`](../../src/runtime/realm.zig) and
[`src/runtime/lantern/interpreter.zig`](../../src/runtime/lantern/interpreter.zig).

A **minor cycle** (`Heap.collectYoung`) marks reachable young
objects, promotes them, and frees the rest. **Sticky mark bits:** a
minor cycle does *not* flip the mark colour, so the mature generation
keeps its marks and `markValue` short-circuits a mature object on the
`mark_color == live_color` check instead of re-tracing the whole
retained graph from roots every nursery cycle. (Re-tracing the mature
set on every minor — the old behaviour — was O(live heap) and the
dominant GC cost on a large stable retained set; this is the
generational invariant JSC-Riptide's Eden collection / SpiderMonkey's
nursery also rely on.) A minor instead clears only the young
generation in `beginMinorCycle` (`O(young)`, bounded by churn) so the
mark can tell a live young object from a dead one. A **major cycle**
(`Heap.collectFull`) marks across both halves, sweeps everything
unreachable, and flips the mark colour + clears the mature lists so
the previously-marked bit ages back to "unmarked" — the `O(1)`-on-the-
mature-side reset that the minor's stickiness depends on. The dirty-container list
(`Heap.dirty_list: ArrayListUnmanaged(Container)`) — the pooled-heap
adaptation of a card-marking remembered set — tracks mature→young
edges recorded by the generational write barrier
(`Heap.writeBarrier`, plus the low-level `JSObject.set` /
`setIndexed` store funnels). Each mature container with a young
referent carries a `dirty` flag and appears once in the list;
`collectYoung` scans each entry with the generic
`markAllPointerFields` (every outgoing pointer, no per-edge-class
predicate), so a young object reachable through *any* field of a
dirty mature container is rooted. It's seeded as a root source on
every minor cycle and cleared at the end of one.

Beyond the dirty list, `collectYoung` historically also scanned the
typed internal slots of **every mature object** (`markObjectInternalSlots`)
as a second mature→young root source — a backstop for raw
`container.field = young` writes into typed slots that bypass the value
write barrier. For a large stable retained set (Splay's payload tree is
~250k plain `{key,left,right,value}` nodes that hold no typed slots),
iterating all of them every minor cycle was the dominant minor-cycle cost
even with a cheap per-object early-return.

**Card marking retires that scan in ReleaseFast.** Every typed-slot write
now routes through the card-marking barrier — `JSObject.noteInternalSlotWrite`
(set the `needs_internal_scan` flag + remember the holder),
`JSObject.anchorKey` (borrowed property-key strings), or the value-aware
`Heap.writeBarrier` (the prototype / proxy / regexp / settled-promise
setters) — which puts a *mature* holder on the dirty list. A mature
object that takes a young typed-slot write is therefore already a dirty-
list entry, and `markAllPointerFields` (Root source 1) roots it. So the
`for (objects_mature) markObjectInternalSlots` loop is **compiled out in
ReleaseFast**: the minor cycle is O(young + dirty list + the small
function / generator mature lists), no longer O(mature objects).
Functions and generators keep their own mature scans — both lists are
small, and a generator's registers churn every cycle so barriering them
would be self-defeating.

Completeness of the barrier audit (every site that stores a young
referent into a mature typed slot must remember the holder) is enforced
the same way the scan-skip shipped: Debug / ReleaseSafe keep the full
`markObjectInternalSlots` scan AND a verifier asserting, for every mature
object, `objectYoungTypedSlot(o) != null ⇒ o.dirty`. A missed barrier
surfaces as a named gc-stress assert, never a ReleaseFast use-after-free.
(`markObjectInternalSlots` and `objectYoungTypedSlot` are kept exact
twins so the verifier has no blind spot.) Under promote-on-first a
dirtied holder pays the full `markAllPointerFields` walk only in the one
cycle it took the write — its young referent tenures that same cycle — so
the barrier is near-free; if aging ever replaces promote-on-first, a
typed-slots-only remembered set becomes preferable again.

## What it does

Each `Heap.allocateX` (object, function, environment, generator,
string, symbol, BigInt) increments a per-heap counter
(`allocs_since_gc`). String bytes and ArrayBuffer slabs additionally
`charge(n)` the byte counterpart (`bytes_since_gc`). At the top of
the interpreter's dispatch loop — the only safe point Cynic has —
the loop checks **either** the allocation count against `gc_threshold`
(default 16,384) **or** the charged bytes against `gc_byte_threshold`
(default 16 MiB). When either crosses, `Realm.collectGarbage` walks
every root, marks reachable objects, and sweeps the rest. `heap.collect`
resets both counters at the end.

The byte trigger keeps allocate-and-discard string concat patterns
(`result += chunk` loops) under control even though they don't tick
the count trigger fast enough — one big allocation that dies a moment
later still moves `bytes_since_gc`.

**Minor vs major — the adaptive trigger.** A collection is a *minor*
(`collectYoung`) by default, promoted to a *major* (`collectFull`) when
any of: the byte threshold trips, the major allocation count is crossed,
a `full_every_n_minor` (32) backstop of minor cycles elapses, OR the
mature set grows past `2× its post-last-major size + 16384`. The last is
the **adaptive** trigger. Once card marking made minor cycles O(young +
dirty), a forced major over a *stable* live retained set (Splay's tree)
is pure O(live) waste, so the backstop was relaxed from 8 to 32 minors
(Splay ~2×). But a churning workload — small live set, fast
mature-garbage production — must not defer majors that long or its
garbage balloons RSS, so the growth trigger fires a major once the
mature set roughly doubles (the additive floor handles a tiny-live
workload and avoids a zero-baseline startup major). Net: rare majors
when the retained set is stable, prompt majors when it churns; RSS stays
bounded (`mature ≲ 2× live`) either way. A small-live churn microbench:
peak RSS 115 MB at a fixed 32-minor interval → 32 MB adaptive, Splay
unaffected.

Always-on counters track sweep-level activity: `bytes_alloc_total`,
`bytes_live_peak`, `gc_cycles_total`, and `gc_time_ns_total` are
surfaced by the test262 harness flags `--mem-summary` /
`--top-alloc=<N>` / `--gc-stats`.

A loop like

```js
while (true) { let x = { a: i++ }; }
```

used to grow the host process's RSS linearly with iterations — the
collector existed but nothing ever called it. Now memory plateaus
within a few thousand iterations and stays put.

## Incremental major marking

The major **mark** is sliced, not stop-the-world. A monolithic major over
a large heap was the dominant pause — marking ~2M objects (cache-bound
pointer-chasing) measured **~800 ms STW** on the bigheap synthetic.
`runSafePoint` now drives the major incrementally: at the `force_full`
trigger it calls `Realm.beginIncrementalMajor` (arm the cycle, mark the
roots, seed the worklist, arm the write barrier) and drains the mark
worklist in bounded ~8192-item slices across subsequent safe-point
crossings, then runs `Realm.finishIncrementalMajor` — the stop-the-world
termination — once the worklist empties. Explicit collects
(`collectGarbage` / `__collectGarbage`) stay monolithic STW. On the 2M
synthetic the **max GC pause dropped ~800 ms → ~1 ms (~800×)**: the mark
is ~1 ms slices (`slice_max` under `--gc-stats`), and the termination
**sweep** — the residual ~9.6 ms STW after the mark went incremental — is
itself sliced by **lazy sweep** (below), dropping `term` ~9.6 ms → ~0.2 ms
with the sweep running as ~50 µs slices (`lazy-sweep done: max_slice`). The
~1 ms mark slice is the ceiling.

**The barrier — Dijkstra (incremental-update).** A store into an
already-scanned (black) container during the mark can hide a white
referent the mark won't revisit, breaking the strong tri-color invariant.
`Heap.writeBarrier` shades the newly-stored value grey — one unified
barrier carrying both the generational and the marking duty (JSC's reuse
insight). Cynic's barrier carries the *new* value, so Dijkstra is ~4
centralized arms vs a Yuasa/SATB deletion barrier's ~25 per-funnel
old-value loads; the termination root-re-scan Dijkstra needs is O(roots),
small for a single mutator stack. (A web-sourced 5-engine survey leaned
SATB but explicitly conditioned it on the old value being cheap at the
barrier — it isn't here; see
[gc-concurrent-marking-research.md](../gc-concurrent-marking-research.md).)

**Minors are deferred while a major is in flight** — a minor would sweep
the young generation against the major's incomplete mark, and a *grey*
object (queued, not yet `mark_color == live_color`) reads as unmarked, so
freeing it would dangle the worklist. Young objects born mid-mark are
allocate-black (the existing default — a fresh object carries
`live_color`), so they survive to the termination sweep, at the cost of
bounded floating garbage (one major's worth), reclaimed next major.

**Barrier/root completeness is the use-after-free surface** — and exactly
what STW marking hides, because no mutator runs *during* an STW mark. Two
gaps the `--gc-threshold=1` verifier gate caught *after* the barrier
passed test-fast, a 400k-node deep-interleaving stress, and byte-identical
conformance: (1) the card-marking typed-slot path
(`rememberTypedSlotWrite`) had only the generational arm — it records the
container, not the value, so its marking arm re-scans the container's
typed slots (`markObjectInternalSlots` — the Steele-style re-grey); (2)
`finishIncrementalMajor`'s termination re-scan covered only the realm
(interpreter-stack) roots, not the **transient heap-side roots** — handle
scopes and in-flight native-ctor instances the mutator changes between
slices — so `markTransientRoots` re-scans them too (the Dijkstra barrier
doesn't cover a pointer pinned only in a native local). Both are invisible
to a normal run; both surface only under allocation-pressure GC with the
mutator interleaved. The verifiers (full-scan + 0xaa free-poison in
Debug / ReleaseSafe) are the net — the same verifier-first discipline that
shipped card marking.

**Throughput trade-off.** The latency win is bought with the write barrier
active across the whole (now long) marking window — the STW major paused the
mutator and never barriered. A remote A/B (the incremental commit vs its
rebase base, 12 back-to-back runs per iteration) puts the cost where
expected: the realistic Octane macros (crypto / deltablue / raytrace /
richards / navier_stokes) are unchanged within noise and non-allocation
micros are flat; allocation-heavy micros lean ~3–5% slower, with
`class_instantiate` the ~13% outlier — its class-setup typed-slot writes
trip the `rememberTypedSlotWrite` re-grey (a full `markObjectInternalSlots`
re-scan per typed-slot write mid-mark). Accepted as the
latency-for-throughput trade: realistic workloads are unaffected and the
~83× pause win is the goal. If the outlier ever matters, the known fix is to
defer the re-grey to the termination (re-scan a written container once, not
per write).

**Lazy sweep — the termination sweep, sliced.** With the mark incremental,
`finishIncrementalMajor`'s O(heap) `sweepList` was the residual ~9.6 ms
pause, dominated by `objects_mature` (the 2M-node case). `collectFullTail`
now defers **only** that list — the small mature kinds
(strings/functions/env/gen/sym/bigint) stay STW, they're tiny — arming
`sweep_phase = .sweeping` with `sweep_cursor` at the post-promote length;
`runSafePoint` drains `sweepObjectsMatureBudget` in ~8192-object slices (dead
`swapRemove`d + freed, marked survivors kept). The slice is bit-identical to
the monolithic `sweepList` paused/resumed because **no other GC fires while
sweeping** — the mark/minor/major branches gate behind not-sweeping, so the
list can't shift under the cursor. `beginIncrementalMajor` finishes any
pending sweep STW *before* the next `live_color` flip — the central
correctness point: after a flip the pending sweep would free
`mark_color != live_color` against the *new* color, i.e. objects the next
mark hasn't reached (a use-after-free); the backstop keeps the heap clean per
mark, bounding the residual if the sweep fell behind. The card-marking dirty
bit needs care: the dirty list is emptied at the termination, so its members'
bits are reset there too (O(dirty-list), pre-sweep, before any free) — a
stale `dirty == true` would make the barrier skip a fresh mature→young store
during the slice (a dropped edge = use-after-free) — and the slice must
**not** clear a survivor's bit (the mutator may have re-dirtied it mid-sweep).
On the 2M synthetic `term` drops ~9.6 ms → ~0.2 ms and the sweep runs as
~50 µs slices (`lazy-sweep done: max_slice`, max 122 µs), leaving the ~1 ms
mark slice as the max GC pause — both halves of the cycle sliced. Explicit
collects (`collectGarbage` / `__collectGarbage`) finish any pending sweep
then sweep synchronously, so WeakRef / FinalizationRegistry timing is
unchanged.

## Why allocation-pressure

It's the baseline pattern every production engine uses. V8's young-gen
Scavenger fires whenever the nursery fills; JavaScriptCore's Riptide
Eden GC the same; SpiderMonkey's Nursery, Hermes's Hades — all
allocation-rate-driven. None of them poll user code, none demand a
safepoint dance for the trigger itself; the allocator's own bookkeeping
is the signal. Cynic's flat object lists and stop-the-world cycle are
much cruder, but the trigger discipline is identical.

The interpreter dispatch loop is a natural safe point because every
opcode is atomic from the GC's perspective: pointers held in registers
or the accumulator are part of the active frame's marked roots, and no
opcode hands a raw heap pointer back across a `runFrames` boundary.
Native calls do — see "natives and `HandleScope`" below.

Bistromath keeps the same Lantern `CallFrame` authoritative. Ohaimark can keep
tagged values in machine registers, so its first executable subset uses a
stricter boundary: generated code never calls a helper or collector. Every
taken backedge polls pending GC/host work; a slow poll boxes the target block's
accumulator and liveness-derived register parameters into the Lantern frame,
sets the loop-header bytecode offset, and returns before `runSafePoint` can
collect. Thus the collector still sees only the root set below. A future
helper-backed Ohaimark node must add rooted call-safepoint metadata; it may not
reuse the backedge policy while retaining an optimized-only pointer.

## What gets marked

`Realm.collectGarbage(frames)` walks:

- **Globals** — every binding in `realm.globals`.
- **Intrinsics** — every `?*JSObject` and `?*JSFunction` field in
  `Intrinsics`. Walked via comptime reflection so a new prototype slot
  doesn't silently leave a root unmarked.
- **Microtask queue** — each `Microtask`'s `callback`, `arg`,
  `reaction_handler`, `reaction_result`, plus `async_gen` if set.
- **Per-realm singletons** — `pending_exception`, `async_done_error`.
- **Modules** — `realm.current_module` and every entry in
  `realm.modules`; each `ModuleRecord.exports` is a real `JSObject`.
- **Top-level chunks** — every `Chunk` in `realm.script_chunks`, plus
  every nested `FunctionTemplate` / `ClassTemplate` chunk transitively
  (see `Heap.markChunk`).
- **Active call frames** — for every nested `runFrames` stack
  registered on `realm.frame_stacks`, each `CallFrame`'s
  `accumulator`, `this_value`, every register, the env chain,
  `home_object`, the owning `JSGenerator` (when running a
  generator body), and the executing chunk's constants. Walking
  every nested stack (not just the "current" one) is required
  for re-entrant patterns — see "Re-entrant dispatch and nested
  frame stacks" below.
- **Open handle scopes** — `heap.collect` walks `heap.handle_scopes`
  itself (see below).

Marking on an object cascades through its property bag, accessors,
private properties, prototype chain, captured environments, bound-
function metadata, Map / Set entries, generator references, and class
field initialisers — `Heap.markValue` and `Heap.markChunk` do the
work; `Realm.collectGarbage` only seeds the roots.

### Multiple realms on one heap

A child realm created with `Realm.initChild` (`$262.createRealm`,
`ShadowRealm`) shares the parent's `Heap` and its flat object pools.
The sweep frees every unmarked object regardless of which realm
allocated it, so a collection must seed roots from **every** realm
sharing the heap — marking only the running realm's roots would
reclaim a sibling realm's live objects (a cross-realm use-after-free).
The `Heap.realms` list holds the coexisting realms (each registers at
`installBuiltins`, deregisters at `deinit`), and
`Realm.markAllSharingRealmRoots` runs the per-realm walk above for each
before the single sweep — the same model as V8's global GC marking
every live Context. (This is also the hook for future per-realm
teardown: dropping a realm from the list lets the next GC reclaim its
now-unreachable objects.)

Each per-kind heap is split `_young` / `_mature`. `promoteYoungList`
runs at the end of the mark phase: it walks the young half,
`swapRemove`s any unmarked entry (freed via the kind's `deinit`),
and *appends* the marked survivors onto the mature half. A minor
cycle never touches the mature lists; a major cycle sweeps both
halves and (still) routes survivors through the same per-kind list.
Marked entries don't get their bit cleared on a per-entry basis —
the mark-colour flip at the top of the next *major* cycle ages the
whole mature set back to "unmarked" in `O(1)`. A *minor* cycle keeps
the colour stable (sticky mark bits) and never touches the mature
lists, so a large stable retained set is not re-traced on every
nursery cycle; only the young generation is cleared and marked.

## Natives and `HandleScope`

The hazard the new trigger introduces: a native function (anything
under `runtime/builtins/`) that allocates a heap value, holds a Zig
pointer to it across a call back into JS (typically via
`interpreter.callJSFunction`), and then reuses the pointer afterward,
is now exposed to mid-call collection. Before the trigger landed,
`heap.collect` was effectively unreachable, so this category of bug
was silently inert.

The contract: any native that holds a heap pointer (`*JSObject`,
`*JSString`, …) across an operation that can re-enter JS must keep
it reachable from a GC root for that window. The usual tool is a
`HandleScope`: open one with `heap.openScope()`, push values via
`scope.push(v)`, close it with `scope.close()` (`defer scope.close()`
for the common case). Open scopes are walked as roots by every
collection. A native that allocates and immediately uses a value
without re-entering JS in between needs no scope.

"Re-enters JS" is broader than an explicit `callJSFunction`: a
`ToString` / `ToNumber` / `@@toPrimitive` argument coercion, an
accessor getter reached through `getPropertyChain`, the iterator
protocol, a Proxy trap, and a user callback all run JS and so all
can trigger a collection. Three recurring shapes:

  * **Result builders** — a native allocates an output object /
    array, then loops calling user code (a comparator, a mapper,
    `next()`); the output and any accumulators must be on a scope.
  * **Native constructors** — the *interpreter* pre-allocates the
    instance and hands it to the native as `this`; if the native
    re-enters JS while coercing an argument the instance can be
    swept. The `new_call` opcode and `constructValue` root it on the
    `Heap.native_ctor_roots` stack; a native that allocates its own
    instance (the `defers_proto_lookup` path) roots it itself.
  * **Constants** — objects and BigInt literals parked in a chunk's
    constant pool are not pinned the way constant strings are; they
    are registered in `Heap.const_roots`. A new kind of heap
    constant needs the same treatment.

Two failure modes live next door but are NOT `HandleScope` bugs:
a missing **generational write barrier** on a raw write into a
property bag / indexed slot / typed internal slot (route through
the Heap helpers — see "Typed-setter helpers" below — or fall back
to `heap.writeBarrier` before the raw store); and a **missing
mark edge** — a typed slot `markValue` / `markObjectInternalSlots`
forgot to trace (e.g. a function's `home_object`, a symbol's
description).

### Finding these bugs

Run any suspect area under maximum allocation pressure. The
dedicated ReleaseSafe harness is the fastest way, with the
verifiers armed:

    zig build test262-safe -- --gc-threshold=1 --filter=<area>

That installs `zig-out/bin/cynic-test262-safe` at a distinct path
— it does **not** clobber the ReleaseFast `cynic-test262`, so keep
both and invoke either directly. For a stack trace on a panic
inside the engine, the Debug harness works too:

    zig build test262 -Dtest262-debug=true -- \
      --gc-threshold=1 --filter=<area>

`--gc-threshold=1` collects on every allocation, so a pointer held
unrooted across a re-entry is freed immediately — the failure is
deterministic instead of a rare flake. The ReleaseSafe or Debug
harness also arms `Heap.verifyRememberedSet`,
which before every minor cycle asserts every routed-setter
mature→young edge is remembered and names the exact
`(container, field, young-target)` triple of an un-barriered store.
A use-after-free surfaces as a segfault at `0xaa…` (freed-memory
poison) whose backtrace names the native. The verifier and the
poison are compiled out of the default ReleaseFast harness, so a
clean `zig build test262` does **not** prove the rooting contract
holds — only the `--gc-threshold=1` Debug/ReleaseSafe run does.

## Tunables

```zig
realm.heap.gc_threshold = 16384;            // allocations between collections
realm.heap.gc_byte_threshold = 16 * 1024 * 1024;  // bytes charged between collections
realm.heap.max_bytes = std.math.maxInt(usize);    // hard ceiling; OOM beyond this
```

`std.math.maxInt(u32)` on `gc_threshold` effectively disables the count
trigger; a few unit tests in `heap.zig` set it that way when they want
to call `collect` explicitly with a tailored root set. Real hosts (the
CLI, the test262 harness) leave it at the defaults.

The 16,384 count default is the smallest power of two where the
per-iteration bookkeeping is invisible in the test262 wall-time (vs
`gc_threshold = 1` which doubles the runtime). It collects often enough
that an empty allocating loop's RSS stays under 20 MB and rare enough
that scripts churning through a few thousand short-lived objects don't
pay for GC at all.

The 16 MiB byte trigger catches a different shape: string concat /
ArrayBuffer / TypedArray fill patterns that move a small number of
huge payloads. One `result += big_chunk` step might charge 4 MiB on its
own; without the byte trigger, 80 such steps accumulate ~320 MiB of
dead intermediates before the count threshold fires. With it, GC kicks
in promptly. The combined effect: per-fixture RSS in the runtime sweep
stays bounded even for the heaviest fixtures.

## Sweep-level memory profiling

Four always-on counters track activity:

| Field | What |
|---|---|
| `bytes_alloc_total` | cumulative bytes charged (never reset by GC) |
| `bytes_live_peak` | high-water mark of `bytes_live` |
| `gc_cycles_total` | total `collect()` cycles |
| `gc_time_ns_total` | accumulated GC pause time |

Bumped from `charge()` and `collect()`; surfaced by the test262
harness via `--mem-summary` (end-of-sweep one-pager), `--top-alloc=<N>`
(top-N fixtures by cumulative bytes), and `--gc-stats` (per-cycle
counts plus `live=KB peak=KB alloc_total=KB`). `--top-alloc` is the
complement to `--top-rss`: RSS shows peak live; alloc shows total
churn — a fixture with 1 GiB cumulative alloc but 10 MiB peak (all
freed by GC) is invisible to RSS but obvious here.

For deeper call-stack allocation profiling on macOS, the harness binary
runs cleanly under Instruments:

```sh
xcrun xctrace record --template Allocations --launch \
  -- ./.zig-cache/o/<hash>/test262 --quiet --filter=<x>
```

## Re-entrant dispatch and nested frame stacks

A native callback that re-enters JS — `gen.next()` from a
`for-of`, a Promise reaction handler, an iterator-protocol step
call — opens a child `runFrames` invocation under the parent's.
The child's `frames.items` is a *different* ArrayList from the
parent's, so a naïve "walk the current frame stack" GC roots only
the child. The parent's registers (which hold the for-of's
`r_iter`, the spread's target array, the Promise wrapper, …)
become invisible roots and get swept under high allocation
pressure.

The fix lives on the realm: `realm.frame_stacks` is a stack of
every live `runFrames` invocation's frame list. `runFrames`
pushes its own `*ArrayListUnmanaged(CallFrame)` on entry and pops
on return; `Realm.collectGarbage` walks every entry. So child
allocations can never collect parent registers.

## Key-anchor strings on JSObject

`JSObject.properties` is `StringArrayHashMapUnmanaged(Value)` —
keyed on `[]const u8`, NOT `*JSString`. Static keys (chunk
constants, builtin installation literals) outlive the object
trivially, but a write like `obj["k" + i] = v` allocates a
*fresh* `JSString` on the GC heap, then stores its `.bytes`
slice as the key. Without an anchor the JSString gets swept; the
slice dangles; the next hash lookup either returns nothing or
SEGVs comparing against freed memory.

`JSObject.key_anchors: ArrayListUnmanaged(*JSString)` holds those
heap-allocated key strings; `markValue` walks the list and marks
each. The write path uses `setComputedOwned(allocator, key_str, v)`
to stash the JSString alongside the entry. Static-key writes still
go through `set` / `setIfWritable` — they don't need anchoring and
the parallel list stays empty.

## Promise reaction roots

`JSObject.promise_reactions[i].result_promise` is the chained
sub-Promise that a later `.then` is registered on; it lives on
the *source* Promise's reaction list until settlement fires. The
walker now follows that list when marking a JSObject
(`heap.markValue`); without it, mid-drain GC collects the chain
before step *n* can settle into step *n+1*'s sub-Promise.

`runPromiseReaction` opens a `HandleScope` to pin
`result_promise`, `value`, and `handler` across the handler call
— the microtask was `orderedRemove`d from the queue before
dispatch, so its values no longer have a queue-based root.

## Iterative marker for chain-shaped graphs

`markValue` and `markEnvironment` recurse through their target's
fields by default. That's fine for objects with a fixed number
of typed slots — the recursion depth is bounded by the
field-count graph. But three edges in the object model can form
N-deep linear chains where the recursion depth tracks the
user-program's chain length, and 5-10k user-side chain entries
overflow the Debug call stack:

- **Promise reaction chain.** `p0.reactions[0].result_promise =
  p1`, `p1.reactions[0].result_promise = p2`, … A 5k-deep
  `.then` chain forms a 5k-deep `markValue → markValue` recursion
  through that edge.
- **Closure-env chain.** Each closure's `captured_env.slots[0]`
  is the previous closure. Marking traverses
  `markValue(f) → markEnvironment(f.captured_env) →
  markValue(env.slots[0]=f_prev) → markEnvironment(…) → …`.
- **Prototype chain.** A 10k-deep `Object.create(prev)` tower
  recurses through `markValue → markObjectInternalSlots →
  markValue(taggedObject(o.prototype)) → …`.

`Heap` carries two worklists for these edges:

- `mark_worklist: ArrayListUnmanaged(Value)` — for Value
  pushes (`promise_reactions[i].result_promise`,
  `o.prototype`).
- `mark_env_worklist: ArrayListUnmanaged(*Environment)` — for
  Environment pushes (`env.parent`, `f.captured_env`).

At those four edges, code pushes to the relevant worklist
instead of calling `markValue` / `markEnvironment` recursively:

    self.mark_worklist.append(self.allocator, taggedObject(p)) catch {
        self.markValue(taggedObject(p)); // OOM fallback
    };

`drainMarkWorklist` runs at cycle boundaries (before sweep in
`collectFull`, before fixpoint and again post-fixpoint in
`collectYoung`), alternating between the two worklists until
both are empty. Either drain can refill the other — marking a
function pushes its captured_env onto `mark_env_worklist`;
marking an env pushes its slot values onto `mark_worklist`. The
outer while re-checks both after each inner drain.

The four edges above are the only ones that form unbounded
chains today. Other recursive `markValue` calls inside the body
— property bag values, Map / Set entries, FinalizationRegistry
held_values, accessor pairs, key anchors — stay recursive
because they don't form linear chains by construction.

**When adding a new typed slot** (`runtime/object.zig` field,
new `iter_helper` payload, etc.) that COULD form a chain — i.e.,
the slot can hold an object that itself has a slot of the same
kind — push to `mark_worklist` instead of recursing. If the
slot is single-hop (e.g., one-shot capability state), recursion
is fine. V8 (`MarkingState`) / JSC (Riptide concurrent marker)
/ SpiderMonkey (`MarkingTracer`) all ship fully iterative
markers globally; Cynic's worklist is a scoped subset covering
the chains that actually overflow today.

## Typed-setter helpers

Property-bag writes / indexed-element writes / environment-slot
writes route through `Heap.storeProperty` / `storeElement` /
`storeEnvSlot`, each of which calls `writeBarrier` before doing
the raw assignment. **Typed internal slots** (`prototype`,
`home_object`, `captured_env`, `bound_target`, `proxy_handler`,
`promise_value`, accessor `getter`/`setter` halves, …) get the
same treatment via a family of single-purpose setter helpers
on `Heap`:

| Container | Helpers |
|---|---|
| `*JSObject` | `setObjectPrototype`, `setProxyTarget` / `setProxyHandler` / `setProxyTargetFn`, `setBoxedPrimitive` / `setBoxedString`, `setFinallyCallback` / `setFinallyValue` / `setFinallyConstructor`, `setRegexpSource` / `setRegexpFlags`, `setGeneratorRef`, `setAccessorGetter` / `setAccessorSetter`, `settlePromise` |
| `*JSFunction` | `setFunctionPrototype`, `setHomeObject`, `setHomeFunction`, `setCapturedEnv`, `setCapturedThis`, `setCapturedNewTarget`, `setBoundTarget` / `setBoundThis` / `setBoundArgs`, `setFunctionNameString`, `setAccessorGetter` / `setAccessorSetter` |
| `*JSGenerator` | `setGeneratorHomeObject`, `setGeneratorHomeFunction`, `setGeneratorEnv` |
| `*Environment` | `setEnvironmentParent` |

Each helper checks for a null target and skips the barrier in
that case (no edge to remember when the slot is cleared). For
the typed-pointer fields where the target type isn't NaN-box-
tagged (`*Environment`, `*JSGenerator`), the barrier is
open-coded against the target's `.generation` instead of
routing through `writeBarrier`'s Value path.

**When adding a new typed slot**, add a matching `setXxx`
helper next to its siblings in `heap.zig` and route every write
site through it. The bare `obj.<slot> = …` form bypasses the
barrier and silently leans on the per-cycle mature scan (see
below) to keep mature→young edges alive — which closes the loop
for now, but blocks the scan-drop work.

### Per-cycle scan and the closure work

`collectYoung` currently runs a per-minor-cycle root walk over
every mature container's typed internal slots
(`markObjectInternalSlots`, `markFunctionInternalSlots`,
`markGeneratorInternalSlots`, plus a slot-by-slot pass over
declarative environments). This catches any old→young edge that
bypassed the write barrier — it's the safety net that lets a
new internal slot ship before its writes are fully routed.

The closure work in progress migrates every raw typed-slot
write to use the typed setters above (so the barrier always
fires), with the goal of dropping the corresponding portions
of the scan. Three buckets remain:

1. **`iter_helper.*` mutable state** (`source`, `next_fn`,
   `payload`, `active`, `concat_inputs[]`, `zip_inputs[]`) — set
   at iterator creation and mutated as iteration advances. Needs
   barrier coverage on the containing JSObject when the
   `*IteratorHelperState` field is updated.
2. **Collection mutations** — `map_data.entries`,
   `set_data.entries`, `promise_store.reactions[]`,
   `promise_store.waiters[]`, `finalization_cells.cells[]`,
   `key_anchors[]`, `private_properties` / `private_accessors`.
   Two design choices: per-mutation barriers at each `Map.set` /
   `.then` / etc., or an "always-remembered subset" list of
   mature containers carrying collections that the minor cycle
   re-scans wholesale.
3. **Generator hot-path mutations** (`gen.registers[]`,
   `gen.queue[]`) — written on every opcode / async-gen request.
   The scan stays for these; per-write barriers would dominate
   interpreter dispatch cost.

Once buckets 1 and 2 close, `collectYoung`'s mature scan can be
split: drop the `objects_mature` / `functions_mature` /
`environments_mature` passes entirely, keep a scan over
`generators_mature` (Tier 3) and any "always-remembered" subset
(if that design wins). The remembered set then becomes the only
mature→young root source for the non-generator object world,
which is what V8's Scavenger / JSC's Eden / SpiderMonkey's
Nursery converged on independently.

## What's not yet done

### Array-spread integer-key gap (resolved)

Historic: spread into an array (`[...iter]`) used to allocate a
JSString per index ("0", "1", "2", …) inside the loop and store
its `bytes` slice as the property key. Nothing rooted those
JSStrings, and the test262 poisoned-iterator fixtures
(`spread-err-{sngl,mult}-err-itr-value.js`, up to 16M iters)
either turned the GC walk quadratic (with anchoring) or relied
on the JSString reallocator happening to land at compatible
addresses (without).

Resolved by the §10.4.2 Array exotic refactor: `JSObject` grew an
`elements: ArrayListUnmanaged(Value)` vector and an
`is_array_exotic` flag, and every site that allocates an Array
instance now calls `JSObject.markAsArrayExotic`. Integer-indexed
reads/writes route through the packed vector (the `array_spread`
opcode goes straight to `setIndexed`, no JSString allocation per
index), and the GC's mark walk is `O(N)` over the elements
vector regardless of how many iterations the source produced.

### Future work

- **Generational aging via card marking.** Short-lived churn is
  promoted-then-stranded as mature garbage today (`promoteYoungList`
  tenures on first survival), which is the engine's clearest
  alloc-perf gap vs the big-engine interpreters (see the cross-engine
  compass — `ctor_array_build` ~5×, `object_alloc` ~2×). The fix is a
  nursery with aging, but it requires a **card-marking** remembered
  set first: two aging attempts were reverted at the `gc-threshold=1`
  gate because the current per-edge-class barrier/scan patchwork can't
  be made complete by inspection (whack-a-mole — verifier gap, then a
  promise-`finally` reaction use-after-free). Full root-cause +
  design: [docs/gc-generational-aging.md](../gc-generational-aging.md).
- **Write-barrier closure + scan drop.** In progress — see
  "Typed-setter helpers" above. Once the iter_helper and
  collection-mutation buckets close, `collectYoung`'s per-cycle
  walk over `objects_mature` / `functions_mature` /
  `environments_mature` can be dropped in favour of the
  remembered set as the sole mature→young root source. The
  generator-register / async-queue scan stays.
- **Parallel / concurrent collection.** Today's mark phase is a single
  uninterruptible walk; long lists or deep object graphs introduce
  GC-pause latency, and on a large live set a single-threaded mark is
  itself wall-time. V8's incremental/parallel marker, JSC's Riptide
  concurrent marker, SpiderMonkey's parallel marking bound this. The
  staged plan — atomic mark-claim → work-stealing parallel
  stop-the-world marking (threshold-gated) → parallel sweep → (deferred)
  concurrent marking — plus the honest "large-heap-only, gate on heap
  size, measure first" case is written up in
  [../gc-parallel.md](../gc-parallel.md). Metla's non-moving design is
  the key leverage (no evacuation race). Not a current bottleneck —
  test262's typical resident set is well under 50 MB.
- **Compaction.** Mark-compact would reduce fragmentation in
  long-running embedder scenarios (Workers, Deno). Not a
  bottleneck against test262's allocation profile.
- **A `--top-rss` CLI flag for `cynic run`.** The test262
  harness exposes the per-fixture RSS-delta report; the runtime
  CLI doesn't yet thread it through. (`--gc-threshold=<n>` is
  now wired — `cynic --gc-threshold=1 run foo.js` collects on
  every allocation for stress testing.)
- **Latent rooting bugs (gc-stress only).** The historically
  documented clusters here — `built-ins/Array/fromAsync/*` and the
  `language/expressions/generators/dstr/{,dflt-}obj-ptrn-rest-getter.js`
  rest-pattern getters — are now clean at `--gc-threshold=1`
  ReleaseSafe. Most recently fixed: the §27.6.1.6
  AsyncFromSyncIteratorContinuation path
  (`built-ins/AsyncFromSyncIteratorPrototype/*`), which held the
  inner rejection reason / iterator-result value in bare Zig frames
  across the `iterator.return()` and `value.constructor` JS
  re-entries it performs. A minor cycle during a re-entry freed the
  value and left the resulting Promise's `promise_value` dangling —
  a use-after-free that crashed on the next mark, visible only under
  `--gc-threshold=1` (it passes at the default threshold). Closed by
  wrapping each re-entry in `builtins/async_iterator.zig` in a
  `HandleScope` (`closeAndReject`, `processIterResult`, the
  pending-Promise branch of `wrapAsyncGenResultWithClose`,
  `closeIteratorOnReject`).
- **Constant-folded cons-rope pinning (fixed).** A broad
  `--gc-threshold=1` ReleaseSafe sweep surfaced `built-ins/RegExp`
  (×2) and `built-ins/JSON` (×1) aborting with an out-of-bounds read
  of a `0xaa…`-poisoned length inside `string.zig` `copyConsBytes` /
  `flatBytes`. Root cause was NOT a builtin holding a string across a
  re-entry (the first hypothesis) — it was the **compiler constant-
  folding `'…' + '…' + …` (§12.9 / §13.15)**: the fold reuses
  `arith.addValues`, which builds a real lazy cons rope once the total
  clears `min_cons_byte_len`, and stores it as a chunk constant.
  `pinChunk` → `pinValue` pinned only the rope's ROOT; its
  intermediate cons nodes (born transiently by the fold, never
  themselves chunk constants) were left unpinned AND unmarked, so the
  first `collectYoung` freed them — and a later `flatBytes()` on the
  pinned root descended `copyConsBytes` into freed memory. Fixed by
  `Heap.pinString`: pinning a cons rope now recursively pins the whole
  child subtree (bounded by `max_rope_depth`, idempotent, pin-time
  only — zero GC-cycle cost). `built-ins/JSON` + `built-ins/RegExp`
  are crash-free at `--gc-threshold=1`; score unchanged. The gate is
  the in-corpus fixture (`built-ins/JSON/parse/15.12.1.1-0-9` at
  `--gc-threshold=1`) — a minimal unit test can't faithfully hit the
  pinned-but-not-`const_roots` window. (`built-ins/TypedArray` at
  `--gc-threshold=1` is merely slow — it times out a 400 s budget,
  no crash.) A full-corpus `--gc-threshold=1` sweep remains the way
  to surface any *new* native missing a `HandleScope`.

## Prior art

- V8 Orinoco (Scavenger + concurrent marker + concurrent sweep).
  Allocation-pressure triggers on both young and old gen.
- JSC Riptide (concurrent generational, mostly-copying Eden).
- SpiderMonkey GGC (Nursery + incremental major).
- Hermes Hades (concurrent generational; the bias is mobile, where
  pause budgets are tight).
- QuickJS (refcounting + cycle collector — explicitly rejected for
  Cynic; cycles are too common in real-world JS).
