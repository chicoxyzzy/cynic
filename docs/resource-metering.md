# Per-realm resource metering

Status: **shipped** (2026-07) — embedder-facing API on `Realm`, not a
CLI verb. Three mechanisms: an instruction budget ("fuel"), a memory
ceiling, and an embedder interrupt hook. Fuel exhaustion and an
interrupt-hook verdict end execution with an **uncatchable host
termination**; the memory ceiling stays on the existing catchable-OOM
contract. The same policy spans ECMAScript, long-running native builtins,
and WebAssembly execution/storage. This document is the durable output of
the prior-art survey
(per [handbook/prior-art.md](handbook/prior-art.md)) and records the
three design decisions an embedder needs to trust: why the
termination is uncatchable and how, why the memory surface is not a
termination, and how metering interacts with the JIT tiers.

## 1. The embedder API

Everything lives on `Realm` (`src/runtime/realm.zig`), additive
fields + narrow methods:

```zig
// Fuel — uncatchable termination when spent.
realm.setFuel(10_000_000);           // units = safe-point crossings
_ = realm.remainingFuel();

// Memory — catchable-OOM ceiling on live bytes, heap-wide.
realm.setMemoryLimit(64 * 1024 * 1024);

// Interrupt hook — polled at safe points on the running thread.
fn myHook(ctx: ?*anyopaque) Realm.InterruptAction {
    const state: *MyState = @ptrCast(@alignCast(ctx.?));
    return if (state.cancel.load(.acquire)) .interrupt else .proceed;
}
realm.setInterruptHook(myHook, &my_state);
realm.clearInterruptHook();

// After a run surfaces `.thrown`:
if (realm.terminationReason()) |why| {
    // .fuel_exhausted or .host_interrupted — a host termination,
    // not an ordinary uncaught exception.
    _ = why;
    realm.clearTermination();  // realm is reusable afterwards
    realm.setFuel(n);          // refuel for the next run
}
```

A terminated run surfaces to the host as a normal `RunResult.thrown`
whose value is an ordinary `RangeError("execution terminated: …")`;
the host tells a termination apart from an uncaught user exception by
`terminationReason() != null`. This is the V8 shape (empty result +
`Isolate::IsExecutionTerminating`) — the *value* is host-facing
convenience, the *latch* is the semantics. Per the never-abort-the-
host contract ([handbook/host-safety.md](handbook/host-safety.md)),
nothing in this path panics: the host always gets a normal completion
shape back.

**Fuel units are safe-point crossings, not opcodes**: loop
back-edges, §15.10 proper-tail-call re-entries, fresh dispatch
entries, and the ~1024-iteration poll inside long-running native
builtins (`checkInterruptInNative`). That is the same granularity
every engine meters at (see §2) and the reason the disabled-path cost
is near zero (§6). Straight-line code between crossings is bounded by
construction, so the budget bounds wall-clock work without a
per-opcode tax.

**Reuse after termination** is supported and tested: `clearTermination()`
(plus a `setFuel` refill — a cleared latch with zero fuel re-latches
on the next crossing) returns the realm to a runnable state. The
unwind released every frame through the same pool paths an uncaught
throw uses, so no engine state is stranded. Microtasks that were
queued when the termination hit stay queued (the drain stops while
the latch is set); the host decides whether to drain or tear down.

## 2. Prior art

| Engine | Time/instruction bound | Cancellation | Memory bound |
|---|---|---|---|
| **V8** | — (host timers) | `Isolate::TerminateExecution()`: sets a flag checked at interrupt points (stack-guard polls at loop back-edges / calls); unwinds **without running catch or finally**; the termination stays pending until the stack fully unwinds and re-arms if JS is re-entered; `CancelTerminateExecution()` clears. `TryCatch::HasTerminated()` tells the host. | heap limit → near-heap-limit callback, else hard OOM abort |
| **JSC** | `Watchdog` (`JSContextGroupSetExecutionTimeLimit`): fires via VMTraps at loop/call safe points | throws `TerminatedExecutionException`, a special exception the handler-dispatch machinery refuses to hand to JS `catch` — uncatchable by construction | per-VM soft limits; host callbacks |
| **QuickJS** | `JS_SetInterruptHandler(rt, cb, opaque)`: polled every N interpreter operations | non-zero return raises an **uncatchable** exception (`JS_ThrowUncatchableError`-marked); the handler keeps firing if code somehow continues | `JS_SetMemoryLimit`: allocation failure surfaces as an OOM exception at the allocation site |
| **SpiderMonkey** | `JS_AddInterruptCallback` | callback returning `false` → uncatchable stop (the slow-script dialog path) | GC heap params |
| **wasmtime** | *fuel* (deterministic instruction counting, `Store::set_fuel`) and *epochs* (host thread bumps a global counter; checked at loop headers / function entries — the cheap, recommended one) | out-of-fuel / epoch deadline → a trap; traps are uncatchable in wasm and surface to the host as an error | `StoreLimits` memory caps at grow sites |

Convergent findings the design adopts:

- **Poll at loop back-edges and call/entry boundaries, never per
  opcode.** Everyone does this (V8 stack guard, JSC VMTraps,
  QuickJS's N-op counter, wasmtime epochs) because the dispatch loop
  is the hottest code in the engine.
- **Cancellation must be uncatchable and sticky.** All four JS
  engines make the watchdog stop something user JS cannot `catch`,
  and V8/QuickJS explicitly re-arm so a path that swallows one
  surface re-terminates immediately.
- **Two budget flavours exist** (wasmtime): deterministic fuel vs
  cheap epochs. Cynic's fuel counts safe-point crossings — closer to
  epochs in cost, closer to fuel in shape (no extra thread needed);
  an embedder wanting wall-clock deadlines runs a watchdog thread
  that flips state the interrupt hook reads (exactly what the
  test262 harness does, §5).

## 3. Uncatchable termination — the mechanism

The latch is `realm.termination: ?TerminationReason`, set by
`Realm.terminate(reason)` and cleared only by the host. Three pieces
make it airtight:

1. **The safe point checks the latch first.**
   `runSafePoint` (`lantern/interpreter.zig`) surfaces a synthetic
   thrown result whenever the latch is set — before the budget, the
   cooperative `interrupt` flag, and the hook — so the termination
   re-signals at every crossing no matter what happened to the
   previous surface. Safe-point throws return directly out of
   `runFrames` (no handler walk), so within one dispatch the
   termination is uncatchable by construction.
2. **`unwindThrow` skips every handler while the latch is set.**
   Termination surfaces that cross a native boundary come back as
   ordinary throws (a native converts the inner `.thrown` into
   `pending_exception` + `error.NativeThrew`, and the outer dispatch
   re-throws it at the call opcode). That path *does* run the
   handler walk — so `unwindThrow` opens with a latch check that
   pops the whole frame stack (through the same register-release
   path the no-handler walk uses) and reports "unhandled". No
   `catch`, no `finally`, no async promise-wrap.
3. **The latch is sticky.** A native that swallows a thrown result
   for spec reasons (iterator close, `Promise.allSettled`'s
   rejection→result conversion) re-enters JS to do it — and the
   fresh dispatch's entry safe point re-terminates on the spot. The
   engine never clears the latch; `clearTermination()` is the host's
   `CancelTerminateExecution`.

The thrown *value* is an ordinary `RangeError` so hosts get a
readable message; uncatchability lives entirely in the latch. (JSC
puts it in the exception object's identity instead; the latch was
chosen because Cynic's native boundary re-materializes exceptions
through `pending_exception`, where value identity is easy to lose
and a realm flag is not.)

**`finally` blocks do not run.** Decision, and the justification:
a `finally` body is arbitrary user JS, and running it after the host
demanded cancellation hands hostile code a second timeslice —
`try { … } finally { while (true) {} }` would defeat the watchdog,
forcing a second (nested) termination mechanism. V8 skips `finally`
under TerminateExecution for exactly this reason, and Cynic follows.
(The alternative — run finallys but re-terminate at their first safe
point — buys nothing observable: the finally could never complete
side effects reliably anyway, and it costs a re-entry per frame.)
The unit test `metering: finally blocks do not run during a
termination` pins the behavior.

**Termination is not an error-class event for JS.** Nothing about it
is observable from inside the realm — no handler runs, no `.catch`
fires (the microtask drain stops while the latch is set), no value
escapes. That is the property that makes fuel metering safe against
hostile code, and it is tested from both directions (same-dispatch
`try/catch` and a `forEach`-driven native re-entry).

## 4. Memory ceiling — catchable by decision

`realm.setMemoryLimit(bytes)` sets `Heap.max_bytes`; `Heap.charge`
fails any allocation that would push **live bytes** past it with
`error.OutOfMemory`. That error surfaces through the pre-existing
OOM contract (host-safety §5): builtins that size an allocation from
user input convert it to a catchable `RangeError`; ambient
allocation-site failures propagate `error.OutOfMemory` to the host
as a normal Zig error. It is deliberately **not** a termination:

- **The ceiling cannot be defeated by catch-and-retry.** The bound
  is on *live* bytes at the allocator, so a hostile
  `while (true) { try { grow() } catch {} }` re-fails every retry
  until the script itself frees memory — host memory stays
  protected regardless of what JS does with the exception. (This is
  the property that makes termination unnecessary here; fuel needed
  termination because a caught RangeError would let the loop keep
  *running*, whereas a caught OOM cannot let the loop keep
  *allocating*.)
- **Precedent.** QuickJS's `JS_SetMemoryLimit` surfaces as an
  exception at the allocation site; Cynic's own OOM-to-throw rule
  (host-safety §5) is the established engine-wide contract, and a
  second OOM mode would fork it.
- **Simplicity.** One mode, no policy enum. An embedder that wants
  a hard stop on memory pressure pairs the ceiling with fuel or an
  interrupt hook (e.g. the hook checks `heap.bytes_live` against a
  soft threshold and returns `.interrupt`).

Scope note: the ceiling lives on the `Heap`, and child realms
(`Realm.initChild` — `$262.createRealm`, ShadowRealm) share the
parent's heap, so the budget bounds the whole agent — the right
containment boundary, since a child can pass values to its parent.
The realm's Wasm arena, immediate-free store/invocation allocator, and native
code ledger all use `Heap.charge` / `discharge`. Decoded modules, instance
metadata, live table/linear-memory backings, Sarcasm operand/frame stacks, and
Spasm executable mappings therefore count against the same ceiling. The
instance/direct-resource ownership registries and reference-counted externref
root registries use that allocator too, so publishing a resource can fail
transactionally before unmetered native capacity escapes the limit. Memory and
table growth reallocates through the owning store allocator, so obsolete
buffers discharge immediately (`grow(0)` is quota-neutral); Spasm charges its
page-aligned reservation before `mmap`, rolls back a failed map, and discharges
after `munmap`. `charge` remains coarse by design (dominant payloads and native
registry storage are exact; small headers are approximate), and the check does
not force a GC before failing — a limit sized with a comfortable margin over
the real working set is the intended use, same as V8's
`--max-old-space-size`.

## 5. Interrupt hook — and the test262 watchdog as first user

`setInterruptHook(hook, ctx)` installs a
`fn (?*anyopaque) InterruptAction` polled at every safe point the
fuel counter is checked at, including `checkInterruptInNative`'s
~1024-iteration poll inside long-running builtins. Returning
`.interrupt` latches the same uncatchable termination as fuel
exhaustion (`.host_interrupted`). The hook runs on the executing
thread — the canonical shape is a single acquire load of state some
other thread (a watchdog, a UI thread, a deadline timer) writes.

The first in-tree user is the **test262 per-fixture watchdog**
(`tools/test262.zig`): `monitorLoop` flips a per-worker abort flag
when a worker sits on one fixture past `--timeout`, and every worker
realm now wires `watchdogAbortHook` (an acquire load of that flag)
through `setInterruptHook`. Previously the flag was aimed at
`realm.host_interrupt`, which the engine never polled — the abort
was dead wiring, and a fixture wedged inside `try { for(;;){} }
catch {}` could only be stopped by the 50M-step budget's catchable
RangeError, which a hostile `catch` could swallow. Now it terminates
uncatchably and the sweep keeps moving. (`realm.host_interrupt`
stays as a field for embedders that used it as storage, documented
as superseded.)

Distinct from the pre-existing `requestInterrupt()` /
`realm.interrupt` flag, which remains the *cooperative* surface: it
throws a catchable `RangeError("execution interrupted")`. Use it
when you want the script to be able to observe and clean up; use the
hook when you don't.

## 6. Performance

The disabled-default path adds, per safe-point crossing (loop
back-edge / PTC re-entry / dispatch entry — **not** per opcode):

- one load + never-taken branch for the termination latch,
- one load + never-taken branch for the hook null check,

adjacent to the loads the safe point already performs (GC phase
checks, `step_budget`, the `interrupt` atomic). Fuel reuses the
existing `step_budget` counter and its existing compare + saturating
decrement, so an *armed* fuel budget costs nothing beyond the
default path. The new fields sit next to `step_budget` /
`interrupt` on `Realm` for locality.

Local ReleaseFast validation on 2026-08-07 completed the full
`zig build bench` suite; `arith_loop` measured 26.56 ms p50
(22.84-28.94 ms). After native Spasm polls landed on 2026-08-08, the
benchmark gained paired bare/wake modes in ABBA order. Three final samples kept
every workload native with matching checksums and `helper 0/0`. The tight loop
was flat within noise (`0.963-1.033x` wake/bare); self-recursive code measured
`1.047-1.079x`, and cross-recursive code `1.036-1.153x`, exposing the expected
extra probe at function-heavy entry boundaries. The configured remote host is
x86_64 and cannot run AArch64-only Spasm, so the paired raw samples and host
caveat are recorded in
[`wasm-bench-results.md`](../wasm-bench-results.md).

## 7. JIT interaction

Compiled code polls **`step_budget` and the `interrupt` byte at
every compiled back-edge** (docs/jit.md §4.6, `backEdgeSafePoint`)
and tiers down to a Lantern safe point when either trips. Hence:

- **Fuel needs no JIT carve-out.** It *is* the step budget; a
  compiled hot loop burns and honours it, tiers down at zero, and
  Lantern's safe point latches the termination.
- **Termination reaches compiled frames.** `terminate()` also
  raises the `interrupt` byte, so a compiled frame mid-loop bails
  to Lantern, whose safe point checks the latch *before* the
  cooperative interrupt (the byte is cleared by
  `clearTermination`, so it never leaks as a catchable
  RangeError while a termination is pending).
- **The JS JITs do not call the hook directly** (their optimized-only
  roots require a frame handoff, and a host call on every backedge is
  exactly the cost those tiers exist to remove).
  **v1 rule: arming a hook disables `jit_enabled` for the realm.**
  `clearInterruptHook` does not silently re-enable it; the embedder
  opts back in. An embedder that re-enables `jit_enabled` with a
  hook armed accepts hook polling only at interpreter safe points —
  the test262 harness does exactly that under `--jit` (the
  differential gate must keep compiling), backstopped by its
  50M-step budget. The measured alternative — emitting a hook call
  on compiled back-edges, or a wasmtime-style epoch byte the hook
  owner flips — is recorded as the v2 candidate if an embedder
  needs hooks and tier-up simultaneously.

Spasm is the deliberate exception to that JS-frame rule: its typed operand
bank and raw boundary registers have explicit spill homes, so the armed slow
path can call the shared hook safely. A bare embedding retains the null-branch
path; a Realm-backed unarmed call performs only the atomic wake probe described
below.

Ohaimark's backedge poll extends that contract: a non-null hook
pointer is itself a slow condition. The optimized frame transfers its exact
loop-header state to Lantern, which invokes the hook from the ordinary safe
point; generated code never calls host code with optimized-only roots. Realm
policy still disables `jit_enabled` when a hook is armed, but an explicit
embedder re-enable remains correct for the default-on runtime tier.

The JIT differential gate (docs/jit.md §10) is unaffected: metering
is off in the scored posture, and the harness's hook wiring happens
before the `--jit` override re-enables tier-up, so the `--jit` and
no-jit sweeps see identical realm behavior.

Sarcasm uses the same `Realm.pollExecution` state machine as Lantern and
long-running native builtins. It polls at invocation entry, every taken
backward branch (`br`, `br_if`, `br_table`, and the reference branch
forms), and proper-tail-call frame replacement. The bare Wasm embedding
leaves `Instance.execution_control` null and keeps its standalone API
unchanged.

Spasm uses the same controller while retaining its compiled path. Its native
entry ABI carries an optional controller pointer through direct self-links,
warm and cold same-instance call gates, generic imported calls, and indirect
dispatch. Generated code tests that pointer at function entry and every taken
structured-loop backedge. A bare Wasm embedding leaves the pointer null and
pays one predictable branch. A Realm-backed unmetered call parks a controller
whose first field points at `realm.interrupt`; generated code acquire-loads
that byte and skips all spills and host calls while it remains clear. An armed
fuel budget or hook uses an always-set wake byte, spills only the live
boundary/operand registers, calls the shared poll, and propagates fuel or
interrupt termination through Spasm's existing trap-status epilogue. Bodies
outside Spasm's supported class still fall back to metered Sarcasm.

Because `requestInterrupt()` release-stores the same byte from any thread, a
request raised after native entry is observed at the next function entry or
taken structured-loop backedge. The outlined poll performs the authoritative
state transition and clears a cooperative request exactly as Sarcasm and
Lantern do.

## 8. What is deliberately NOT here

- **No CLI verb.** Metering is embedder API; the `cynic` CLI grows
  flags if and when a use case appears.
- **No per-opcode accounting / deterministic gas.** Fuel counts
  safe-point crossings, which is deterministic for a given engine
  build but not across builds (fusion, tiering change crossing
  counts). wasmtime-style deterministic fuel would need per-opcode
  decrements — the cost profile this design exists to avoid.
- **No termination-on-OOM mode.** §4.
- **No async/deadline built-ins.** Wall-clock deadlines are an
  embedder watchdog thread + the hook, by design (that's the
  epoch model).
