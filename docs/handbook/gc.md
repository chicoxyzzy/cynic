# Garbage collection

Stop-the-world mark-sweep, triggered on allocation pressure. Lives in
[`src/runtime/heap.zig`](../../src/runtime/heap.zig); the trigger and
root walker live in [`src/runtime/realm.zig`](../../src/runtime/realm.zig)
and [`src/runtime/interpreter.zig`](../../src/runtime/interpreter.zig).

## What it does

Each `Heap.allocateX` (object, function, environment, generator,
string, symbol, BigInt) increments a per-heap counter
(`allocs_since_gc`). At the top of the interpreter's dispatch loop —
the only safe point Cynic has — the loop checks that counter against
`gc_threshold` (default 16,384). When it crosses, `Realm.collectGarbage`
walks every root, marks reachable objects, and sweeps the rest.
`heap.collect` resets the counter at the end.

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
- **Active call frames** — for each `CallFrame` in the dispatch loop's
  stack: `accumulator`, `this_value`, every register, the env chain,
  `home_object`, the owning `JSGenerator` (when running a generator
  body), and the executing chunk's constants.
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

The contract: any native that holds a pointer across a JS sub-call
must register it on a `HandleScope`. Open one with `heap.openScope()`,
push values via `scope.push(v)`, close it with `scope.close()` (or
`defer scope.close()` for the common case). Open scopes are walked as
roots inside `heap.collect`. Natives that allocate-and-immediately-use
without re-entering JS in between are safe without a scope.

The 734-test unit suite plus the test262 runtime sweep both pass
under the new trigger, which means the existing built-ins are
mostly already in compliance — but the audit isn't finished. When a
specific test starts failing only under high allocation pressure
(reproducible with `realm.heap.gc_threshold = 1`), the suspect is a
native missing a `HandleScope`.

## Tunables

```zig
realm.heap.gc_threshold = 16384;  // allocations between collections
```

`std.math.maxInt(u32)` effectively disables the trigger; a few unit
tests in `heap.zig` set it that way when they want to call `collect`
explicitly with a tailored root set. Real hosts (the CLI, the test262
harness) leave it at the default.

The 16,384 default is the smallest power of two where the per-iteration
bookkeeping is invisible in the test262 wall-time (vs `gc_threshold = 1`
which doubles the runtime). It collects often enough that an empty
allocating loop's RSS stays under 20 MB and rare enough that scripts
which churn through a few thousand short-lived objects don't pay for
GC at all.

## What's not yet done

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
- **A `--gc-threshold` CLI flag.** Tunable from the host today only by
  poking `realm.heap.gc_threshold` directly.

## Prior art

- V8 Orinoco (Scavenger + concurrent marker + concurrent sweep).
  Allocation-pressure triggers on both young and old gen.
- JSC Riptide (concurrent generational, mostly-copying Eden).
- SpiderMonkey GGC (Nursery + incremental major).
- Hermes Hades (concurrent generational; the bias is mobile, where
  pause budgets are tight).
- QuickJS (refcounting + cycle collector — explicitly rejected for
  Cynic; cycles are too common in real-world JS).
