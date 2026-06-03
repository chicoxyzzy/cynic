# Multi-agent SAB/Atomics — real-threads substrate (design)

The single-agent SharedArrayBuffer + Atomics surface shipped (see
[sab-atomics.md](sab-atomics.md)). This doc designs the **multi-agent**
phase — the ~112 `$262.agent` test262 fixtures that need genuinely
concurrent agents sharing memory, plus cross-thread `Atomics.wait` /
`notify`.

It is a deliberate departure from Cynic's "single-agent-per-isolate"
default (AGENTS.md), greenlit as a separate initiative. The design's
guiding constraint: **introduce real OS threads without making the
whole engine thread-safe.**

## The key insight — isolation, not shared state

Agents share **only raw bytes** (a SharedArrayBuffer's backing store)
and a **futex table**. They do NOT share JS objects, heaps, or GC. So:

- Each agent runs on its own OS thread with its **own Realm + heap +
  allocators** — all of which stay single-threaded, unchanged.
- The only cross-thread mutable state is (a) a refcounted shared byte
  block and (b) a process-global futex table. Both are small, explicit,
  lock-guarded surfaces.

This mirrors V8 (one Isolate per agent, a shared `BackingStore`) and is
what makes the project tractable rather than a full engine
thread-safety rewrite.

## Engine pieces

### 1. `SharedDataBlock` — refcounted, non-GC backing store

Today a SAB's bytes are `JSObject.array_buffer: ?[]u8`, allocated from
the realm allocator and freed in the object's extension `deinit` (the
per-realm, GC-swept path). That can't be shared across threads.

Introduce a process-global, refcounted block:

```
const SharedDataBlock = struct {
    bytes: []u8,              // page-allocated, outside any realm heap
    byte_length: usize,       // current length (≤ cap; grows in place)
    max_byte_length: usize,   // cap (growable SAB pre-allocates this)
    refcount: std.atomic.Value(usize),
    // futex state for this block (see §2)
    mutex: std.Thread.Mutex,
    cond: std.Thread.Condition,
};
```

- Allocated from a process-global allocator (page allocator / a
  dedicated shared arena), never from a realm's GC heap.
- A `SharedArrayBuffer` `JSObject` holds a `*SharedDataBlock` (a new
  slot beside `array_buffer`) and bumps the refcount on construction.
- When a SAB object is swept / `deinit`'d, it decrements the refcount;
  the block frees at zero. Growable SABs pre-allocate `max_byte_length`
  so `grow` only bumps `byte_length` (the data block never moves — so
  other agents' views stay valid; this also fixes the single-agent
  realloc-moves-the-store shortcut).
- **Broadcast** (`$262.agent.broadcast(sab)`) hands the *block pointer*
  to another agent, which constructs its own SAB `JSObject` in its own
  realm pointing at the same block (refcount++). Same bytes, two
  isolated views.

Non-shared `ArrayBuffer` is unchanged (keeps the per-realm slice).

### 2. Futex table — cross-thread `wait` / `notify`

Per-block `mutex` + `cond` (above) back a wait queue:

- `Atomics.wait(ta, i, v, t)`: lock the block mutex; re-read the element
  under the lock; if it ≠ `v` → `"not-equal"`; else `cond.timedWait(t)`
  in a loop until woken or the deadline → `"ok"` / `"timed-out"`. The
  current single-agent stub (always `"timed-out"`) becomes a real
  blocking wait.
- `Atomics.notify(ta, i, count)`: lock; wake up to `count` waiters
  parked on `(block, i)`; return the number woken. Today's `0` becomes
  the real count.
- Waiters carry their byte-index so a `notify` on index `j` doesn't wake
  a waiter on index `i` (the `no-spurious-wakeup` fixtures).

A single mutex+cond per block (broadcast-wake then re-filter by index)
is simplest and correct; a per-index queue is the optimization.

`waitAsync` resolves its pending Promise from `notify` — which means the
notifying thread must enqueue a microtask on the *waiter's* realm. That
cross-thread microtask hand-off is the fiddliest part; defer `waitAsync`
cross-agent resolution to last.

## Harness pieces (`$262.agent`, in `tools/test262.zig`)

`$262.agent` is a **test262 host hook**, not a JS builtin — it lives in
the harness's `install262`, keeping the engine free of test262
specifics. Surface (by fixture usage): `start`, `receiveBroadcast`,
`safeBroadcast` / `broadcast`, `report` / `getReport` / `getReportAsync`,
`waitUntil`, `monotonicNow`, `timeouts`, `tryYield`, `leaving`, `sleep`.

- `start(src)`: spawn a `std.Thread` that builds a fresh Realm (own
  heap), installs builtins + a **child `$262.agent`** (`receiveBroadcast`,
  `report`, `leaving`, `sleep`, `monotonicNow`), and evaluates `src`.
- **Broadcast channel** parent→agent: a thread-safe slot holding the
  `*SharedDataBlock` (+ optional int); the agent's `receiveBroadcast`
  callback fires when set.
- **Report channel** agent→parent: a mutex-guarded queue of strings;
  `report(s)` pushes, `getReport()` pops (blocking until available).
- `monotonicNow` / `timeouts`: a shared monotonic clock; `timeouts`
  comes from `atomicsHelper.js` (an `includes:` the fixtures pull in).
- `waitUntil` / `tryYield` / `safeBroadcast` are **harness JS helpers**
  (`atomicsHelper.js`) built on the primitives — no new host hooks.

Lifetime: agents must be joined (or detached + drained) at fixture end;
a wait-forever agent is bounded by the harness's existing per-fixture
timeout watchdog (`--timeout`), which must signal agent threads to
unpark and exit.

## Phasing

- **A — SharedDataBlock substrate (no threads).** Refcounted non-GC
  block; SAB points at it; growable grows in place; a SAB can be handed
  to a second Realm *on the same thread* and both views see one block.
  Verifiable with a unit test; single-agent corpus must stay flat.
- **B — real futex `wait`/`notify` (two threads, unit-tested).** Block
  mutex/cond; blocking `wait` with timeout; `notify` wakes by index.
  Cynic unit test spawning two threads sharing a block.
- **C — `$262.agent` harness hooks.** Thread spawn + broadcast/report
  channels + child-agent `$262`; wire `atomicsHelper.js`. Land the
  ~112 fixtures. `waitAsync` cross-agent resolution last (cross-thread
  microtask enqueue).

## Risks

- **Thread lifetime / hangs.** A stuck agent must be unparked + joined;
  rely on the per-fixture watchdog and a shutdown flag the futex wait
  checks.
- **CI flakiness.** Real-thread timing tests can be flaky; the
  `monotonicNow`-based duration asserts have slack, but watch the
  `--threads` interaction (the harness's own worker pool vs. agent
  threads — agents are per-fixture and must not be confused with
  harness workers).
- **GC vs shared block.** The block is refcounted and outside GC; the
  SAB object's sweep must decrement, never free directly. Audit under
  `test262-safe --gc-threshold=1`.
- **Scope creep.** This is the only part of Cynic that uses real
  threads; keep the shared surface to exactly `SharedDataBlock` +
  futex table, nothing else.

Start with **Phase A** — it's the foundational, thread-free engine
change (decouple SAB backing from the GC heap), low-risk and verifiable
on its own before any threading lands.
