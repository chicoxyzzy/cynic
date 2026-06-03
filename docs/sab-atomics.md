# SharedArrayBuffer + Atomics — design & plan

Goal: ship `SharedArrayBuffer` (§25.2) and `Atomics` (§25.4) far
enough to clear the **single-agent** slice of the test262 corpus
(~500 fixtures), and lay the substrate for the cross-agent phase
without committing to real OS threads up front.

This doc is the durable plan — a fresh session should be able to pick
up the next phase from here. Sister docs:
[multi-realm.md](multi-realm.md) (per-realm intrinsics — the same
install plumbing SAB/Atomics use) and
[ses-alignment.md](ses-alignment.md).

## Why now — the scoping insight

`SharedArrayBuffer` / `Atomics` is the single largest engine-true gap
in the binary-scored corpus: ~382 `built-ins/Atomics` + 104
`built-ins/SharedArrayBuffer` fixtures fail outright (`ReferenceError:
SharedArrayBuffer`), plus ~148 fixtures under
`DataView` / `ArrayBuffer` / `TypedArray*` that reference SAB. Everything
else surfaced in triage (`docs` triage 2026-06) is a deliberate
divergence (Annex B, strict-only, eval-strict-`this`) that counts as an
honest fail by design — this is the one big *fixable* block.

The decisive fact: **most of it needs no real concurrency.** Counts
against the pinned corpus:

| tree | total | use `$262.agent` (multi-agent) | single-agent |
|---|--:|--:|--:|
| `built-ins/Atomics` | 382 | 112 | **~270** |
| `built-ins/SharedArrayBuffer` | 104 | 0 | **104** |
| SAB-referencing in `DataView`/`ArrayBuffer`/`TypedArray*` | ~148 | ~0 | **~148** |

Cynic is single-agent-per-isolate (no Workers, no threads). On a single
agent, `Atomics.*` read-modify-write / load / store / compareExchange /
isLockFree are ordinary sequential operations on the backing store;
`Atomics.notify` always returns 0 (no other agent waits); the only
genuinely-concurrent surface (`$262.agent.*` spawning agents, the
memory-model litmus tests, cross-agent `wait`/`notify`) is the ~112
fixtures we defer.

## Prior art

- **QuickJS-ng** — the closest reference: ships SAB + Atomics with a
  single-process backing store; `Atomics.wait` uses a real futex only
  when threads exist, else degrades. Smallest faithful implementation
  to mirror.
- **V8 / JavaScriptCore / SpiderMonkey** — SAB backed by a refcounted
  shared store; `wait`/`notify` over a per-buffer futex/condvar table;
  `isLockFree(n)` true for the platform's lock-free widths (1,2,4, and
  8 where `Atomics` on 64-bit ints is lock-free). We copy the *observable*
  rules (isLockFree results, the §25.4 validation order, the
  `[[CanBlock]]` gate on `wait`) without the threading machinery in
  phase 1.
- **XS (Moddable)** — embedded, single-agent by default; SAB is a
  non-detachable ArrayBuffer. Confirms the "SAB ≈ ArrayBuffer minus
  detach, plus grow" shape is enough for the sequential surface.

Spec: §25.2 SharedArrayBuffer, §25.4 Atomics, §9.7 Agents +
§9.8 AgentClusters, §25.4.3 (ValidateIntegerTypedArray /
ValidateAtomicAccess), §25.4.{11,12} wait/notify, §25.1.3
(shared vs non-shared ArrayBuffer abstract ops).

## Engine starting point

- `ArrayBuffer` is fully implemented in
  `src/runtime/builtins/typed_array.zig` (constructor, `byteLength`,
  resizable + `resize`, `transfer` / `transferToFixedLength`, `slice`,
  species, `isView`). Backing store is `JSObject.array_buffer: ?[]u8`
  with `array_buffer_max_byte_length: ?usize` (resizable) and the
  `has_array_buffer_data` brand (detached = brand set + slice null) —
  see `src/runtime/object.zig`.
- `TypedArray` (`typed_view`) and `DataView` (`data_view`) views borrow
  the backing slice and already work over `ArrayBuffer`.
- **No `SharedArrayBuffer`, no `Atomics`, no `shared`/`agent` concept
  anywhere** (`git grep` clean). Greenfield, with a strong reuse base.

## Phase 1 — SharedArrayBuffer (single-agent)

SAB is an ArrayBuffer that is **never detachable** and **grow-only**
(`grow`, not `resize`). Reuse the `array_buffer` slice + brand; add a
discriminator.

- `JSObject`: add `array_buffer_shared: bool = false` (or fold into a
  small enum on the existing brand). `IsSharedArrayBuffer(O)` = brand
  set ∧ shared.
- Global `SharedArrayBuffer` constructor + `%SharedArrayBuffer.prototype%`,
  installed per-realm alongside `ArrayBuffer` (mirror the existing
  `install`).
  - `new SharedArrayBuffer(len [, { maxByteLength }])` → allocate a
    zeroed store; growable iff `maxByteLength` given.
  - prototype: `byteLength`, `maxByteLength`, `growable`, `grow(n)`
    (grow-only; never shrinks), `slice` (returns a SAB), `@@toStringTag`,
    species (`get [Symbol.species]`).
  - **never** `detached` / `transfer` / `resize` (those stay
    ArrayBuffer-only).
- Wire the existing ArrayBuffer.prototype `this-is-sharedarraybuffer.js`
  guards: methods that step "If IsSharedArrayBuffer(O) throw TypeError"
  (`byteLength`/`detached`/`maxByteLength`/`resizable`/`resize`/`slice`/
  `transfer`/`transferToFixedLength`) now reach a real SAB instead of a
  `ReferenceError` → those ~9 ArrayBuffer fixtures flip to pass.
- `TypedArray` / `DataView` constructors accept a SAB-backed buffer
  (the buffer-arg validation currently keys off the AB brand; broaden to
  "AB or SAB"). A SAB-backed view is otherwise identical (no detach
  path).

Yield estimate: 104 (`SharedArrayBuffer`) + ~148 (SAB-backed views /
ArrayBuffer guards) ≈ **~250 fixtures**.

## Phase 2 — Atomics (single-agent)

A global `Atomics` ordinary object (per-realm) with:

- `add`, `and`, `or`, `sub`, `xor`, `exchange` — §25.4.8
  AtomicReadModifyWrite: `ValidateIntegerTypedArray` → `ValidateAtomicAccess`
  → ToIntegerOrInfinity/ToBigInt the value → read, op, write back. On a
  single agent this is a plain sequential read-op-write.
- `compareExchange` — §25.4.6, same shape with the expected/replacement
  compare.
- `load`, `store` — §25.4.{10,13}.
- `isLockFree(n)` — §25.4.9: true for 1, 2, 4 (and 8, matching
  V8 on 64-bit); false otherwise. Pure function of size.
- `notify(ta, index, count)` — §25.4.12: validate, then return **0**
  (no waiters exist on a single agent).
- `wait(ta, index, value, timeout)` — §25.4.11: requires an Int32Array/
  BigInt64Array over a **shared** buffer; honor `[[CanBlock]]` (§9.7 — a
  TypeError when the surrounding agent can't block). The not-equal fast
  path (`"not-equal"`) and the validation/throw paths are fully testable
  single-agent; with no other agent to notify, a matching wait either
  returns `"timed-out"` (finite timeout) or is a no-op we bound. Most
  single-agent `wait` fixtures exercise validation + `not-equal` +
  zero-timeout `timed-out`.
- `waitAsync` (§25.4.x, ES2024) — returns `{ async: true, value: <promise> }`
  / `{ async:false, value:"not-equal"|"timed-out" }`; single-agent the
  promise resolves `"timed-out"`.
- `@@toStringTag` = "Atomics".

Engine touch-points: a new `src/runtime/builtins/atomics.zig`; the
typed-array element read/write helpers in `typed_array.zig` are reused
for the per-kind load/store. No GC-visible new heap types (Atomics is a
plain object; SAB reuses the ArrayBuffer slot).

Yield estimate: ~270 single-agent Atomics fixtures (213 landed).

**Single-agent follow-ups (small, not yet done):**

- `Atomics.waitAsync` (§25.4, ES2024) — ~48 fixtures. Needs a Promise
  result; single-agent it resolves `"timed-out"`. Deferred only because
  the would-block case wants a (resolved-immediately) Promise and most
  of its corpus is `$262.agent`-based.
- `Atomics.pause` (TC39 proposal) — ~6 fixtures. A no-op hint returning
  `undefined`, not a constructor; trivial to add.
- `Atomics.store` return value should be `ToIntegerOrInfinity` (so `-0`
  → `+0`), not `ToNumber` — 1 fixture (`store/expected-return-value-
  negative-zero.js`).
- `wait` with `[[CanBlock]] = false` (browser-main-thread semantics) —
  2 fixtures; needs an agent CanBlock model, tied to the multi-agent
  phase.

**Phase 1 + 2 combined ≈ ~500 fixtures** → headline ~89.3 % → ~90.3 %+.

## Phase 3 — multi-agent (deferred)

The ~112 `$262.agent`-using Atomics fixtures + the memory-model litmus
tests need a real agent cluster: `$262.agent.start/broadcast/sleep/
report/getReport/leaving/monotonicNow`, a shared store handed across
agents, and cross-agent `wait`/`notify` with a futex table. This is the
genuine concurrency surface and a separate project (likely real OS
threads or a cooperative agent scheduler). Out of scope for the first
landing; revisit once phases 1–2 ship and the multi-realm substrate
(see [multi-realm.md](multi-realm.md)) is exercised.

## SES / hardening notes

- `SharedArrayBuffer` + `Atomics` are frozen with the other primordials
  at realm init (the existing freeze pass walks them automatically once
  installed — no extra work, but confirm `Object.isFrozen(Atomics)` in a
  `test-ses` fixture).
- SAB has no detach/transfer, so it sidesteps the ArrayBuffer
  capability-revocation surface entirely.
- A SAB backing store is process-local in phase 1 (single agent), so
  there's no cross-realm sharing concern yet; phase 3 must revisit how a
  shared store interacts with per-realm teardown
  (`Heap.pending_realm_teardown`).

## Verification plan

- TDD per phase: unit tests in `atomics_test.zig` /
  `shared_array_buffer_test.zig` before the builtins.
- `zig build test262 -- --filter=built-ins/SharedArrayBuffer` and
  `--filter=built-ins/Atomics` after each phase; compare pass counts to
  the table above (watch for the `$262.agent` fixtures staying failed —
  that's expected until phase 3).
- `--filter=built-ins/DataView` / `ArrayBuffer` to confirm the
  SAB-backed + `this-is-sharedarraybuffer` flips land.
- `test262-safe --gc-threshold=1` on the SAB tree (new heap-slot usage).
- Session-end full sweep + `--write-results`; expect ~+500 on phases 1–2.
