# Garbage collection

Stop-the-world mark-sweep, triggered on allocation pressure. Lives in
[`src/runtime/heap.zig`](../../src/runtime/heap.zig); the trigger and
root walker live in [`src/runtime/realm.zig`](../../src/runtime/realm.zig)
and [`src/runtime/interpreter.zig`](../../src/runtime/interpreter.zig).

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

The sweep walks each per-kind list (`heap.strings`, `heap.functions`,
`heap.objects`, `heap.environments`, `heap.generators`, `heap.symbols`,
`heap.bigints`), `swapRemove`s any unmarked entry, and `deinit`s it.
Marked entries get their bit cleared, ready for the next cycle.

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
a missing **generational write barrier** on a raw `setIndexed` /
`properties.put` (route through `heap.storeProperty` /
`storeIndexed`, or call `heap.writeBarrier` before the raw store);
and a **missing mark edge** — a typed slot `markValue` /
`markObjectInternalSlots` forgot to trace (e.g. a function's
`home_object`, a symbol's description).

### Finding these bugs

Run any suspect area under maximum allocation pressure:

    zig build test262 -Dtest262-debug=true -- \
      --gc-threshold=1 --filter=<area>

`--gc-threshold=1` collects on every allocation, so a pointer held
unrooted across a re-entry is freed immediately — the failure is
deterministic instead of a rare flake. Building the harness Debug
(or `-Doptimize=ReleaseSafe`) also arms `Heap.verifyRememberedSet`,
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

The README has these as future work and they remain so:

- **Generational GC.** A nursery + tenuring lets the cheap case (most
  allocations die young) be much cheaper still. V8's Scavenger,
  SpiderMonkey's Nursery, Hermes's YoungGen all live here.
- **Incremental marking.** Today's mark phase is a single
  uninterruptible walk; long lists or deep object graphs introduce
  GC-pause latency. V8's incremental marker, JSC's Riptide concurrent
  marker bound this; Cynic doesn't yet need to.
- **Concurrent / parallel sweep.** Useful once the heap is big enough
  that a single-threaded sweep eats real wall-time. Not a current
  bottleneck — test262's typical resident set is well under 50 MB.
- **A `--top-rss` CLI flag for `cynic run`.** The test262
  harness exposes the per-fixture RSS-delta report; the runtime
  CLI doesn't yet thread it through. (`--gc-threshold=<n>` is
  now wired — `cynic --gc-threshold=1 run foo.js` collects on
  every allocation for stress testing.)

## Prior art

- V8 Orinoco (Scavenger + concurrent marker + concurrent sweep).
  Allocation-pressure triggers on both young and old gen.
- JSC Riptide (concurrent generational, mostly-copying Eden).
- SpiderMonkey GGC (Nursery + incremental major).
- Hermes Hades (concurrent generational; the bias is mobile, where
  pause budgets are tight).
- QuickJS (refcounting + cycle collector — explicitly rejected for
  Cynic; cycles are too common in real-world JS).
