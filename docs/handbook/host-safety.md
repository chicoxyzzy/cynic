# Host-abort safety

Cynic runs untrusted JavaScript inside a host process — edge
runtimes, server JS, the WASM playground. The single invariant that
makes that safe:

> **Untrusted JS must never abort the host. Any input — however
> hostile or pathological — produces a normal completion or a
> *catchable* JS exception, never a `panic`, `unreachable`, a
> segfault, an `@intFromFloat`/`@intCast` trap, or unbounded
> resource growth that the OS kills.**

A `RangeError` the script can `try`/`catch` is correct. A SIGABRT,
SIGSEGV, or `EXC_BAD_ACCESS` at a Zig `unreachable` is a security
bug — it's a denial-of-service on any embedder that accepts
user-controlled input, and a memory-safety violation is worse.

This is a *robustness* contract, distinct from spec conformance: a
spec-conformant result is still a host-abort bug if a crafted input
reaches it through a trap. Several of these bugs are invisible to a
normal test262 run — they only surface under allocation-pressure GC
or deep recursion — so the rule has to be applied at authoring time,
not discovered later.

## The mechanisms

Each recurring host-abort class has a standard mitigation. Use the
existing one; don't reinvent it.

### 1. Numeric casts on user-controlled doubles

`@intFromFloat` / `@intCast` **trap** (and abort in ReleaseFast,
panic in safe builds) for any finite value outside the destination
range — e.g. `@as(i64, @intFromFloat(1e30))`. Every JS number is a
user-controlled `f64`, so a bare cast on an argument is a host-abort
waiting to happen.

- Route §7.1.5 ToIntegerOrInfinity / §7.1.20 ToLength sites through the
  saturating-cast family in `intrinsics.zig` —
  `doubleToI64Saturating` and its width companions
  `doubleToUsizeSaturating` / `doubleToU32Saturating` /
  `doubleToI32Saturating` (each saturates NaN / ±∞ / out-of-range
  finites to the destination bounds, which is where the spec's
  clamping lands anyway). Pick the variant matching the cast's target
  type rather than writing a raw `@intFromFloat`.
- For a radix / digit count / index, range-check *before* the cast
  and emit the spec value (or `RangeError`) explicitly.
- Guard length × element-size multiplies (`byte_len * count`) against
  overflow and throw `RangeError` (§22.1.3.16-style).

Precedent: `cd1d038` (eight Number/String/Array/TypedArray sites),
the array-like iterator and ShadowRealm-arity follow-ups. When you
add a builtin that coerces a number, grep your diff for
`@intFromFloat` / `@intCast(` and confirm each is range-checked or
saturating. Two backstops keep the class closed:

- **`tools/lint-builtin-safety.sh [base]`** — advisory, diff-scoped:
  flags a *newly-added* raw `@intFromFloat` under `builtins/` that
  doesn't route through a `*Saturating` helper (annotate a provably-
  bounded cast with `// safety: <reason>` to silence it). The ~70
  historical guarded sites are grandfathered.
- The **`no host-abort on huge numeric args` unit test** (in
  `lantern/tests.zig`) drives 1e21-magnitude arguments at the whole
  surface; a regressing unguarded cast panics there under ReleaseSafe
  and fails `test-fast`.

### 2. Recursion depth

User input controls nesting depth: `[[[[…]]]]`, `{"a":{"a":…}}`,
`(((((…)))))`. Unbounded native recursion overflows the host stack.

- The parser bounds expression / statement nesting.
- `JSON.parse` bounds its recursion and throws `RangeError`
  (`aa5010c`).
- Any new recursive descent over user-sized input needs a depth
  backstop that throws, not a stack that grows until the OS faults.

### 3. Native re-entry into JS (the stack guard)

`max_call_frames` bounds the *JS* frame stack within one `runFrames`
dispatch, but a native builtin that calls back into JS — an accessor
getter, a `.map` / `.forEach` callback, `Reflect.apply`, a Proxy
trap, a promise-reaction drain — starts a *fresh* `runFrames` on a
fresh native stack frame. That nesting was once unbounded and
crashed the process.

`nearNativeStackLimit()` in `src/runtime/lantern/interpreter.zig`
measures actual remaining native stack at each `runFrames` entry and
throws `RangeError("Maximum call stack size exceeded")` before the
red zone — precise per-thread bounds on macOS
(`pthread_get_stackaddr_np`) and Linux (`pthread_getattr_np` +
`pthread_attr_getstack`), a growth-from-base heuristic elsewhere
(`63c5811`, `e5d637c`). You don't normally touch this, but if you
add a *new* native→JS re-entry path, it's already covered by the
entry check — don't bypass `runFrames`.

### 4. Heap pointers across a re-entry or allocation (GC rooting)

A native that holds a raw `*JSObject` / `*JSString` / `*JSFunction`
or a `Value` across a call that can GC — any allocation, any JS
re-entry — and doesn't root it has a use-after-free: the sweep frees
the object, the post-call dereference reads poison (segfault in
ReleaseSafe, silent corruption in ReleaseFast). The fresh value
returned by an accessor getter, a set-like's `has`/`keys`, or a
once-read `constructor.resolve` is the classic offender — reachable
through nothing until you root it.

Root with a `HandleScope` (or move engine state into a typed
`JSObject` slot). The contract is in
[gc.md](gc.md) ("the `HandleScope` contract for natives"); the
"No engine state on user-visible objects" rule in
[../../AGENTS.md](../../AGENTS.md) is the typed-slot half. Precedent:
the Object / Set / Promise re-entry fixes (`d87eed3`).

### 5. Out-of-memory

An allocation failure must surface as a JS-visible `RangeError`
(`error.OutOfMemory` propagated to a throw), never an unchecked
`catch unreachable` that aborts.

## The contributor checklist

When you add or touch a builtin, ask:

1. Does it cast a user-controlled number? → saturate / range-check
   (§1).
2. Does it recurse over user-sized input? → depth backstop (§2).
3. Does it call back into JS — getter, callback, trap, `then`,
   species constructor, coercion hook? → every heap pointer / `Value`
   held across that call is rooted (§4); the re-entry itself is
   covered by the stack guard (§3).
4. Does every allocation propagate `error.OutOfMemory` to a throw
   rather than `catch unreachable`? (§5).
5. Add a regression test. UAF / rooting tests go in the `GC:` cluster
   in `src/runtime/lantern/tests.zig` under `gc_threshold = 1`
   (`expectScriptIntUnderGcPressure`); host-abort-on-numeric tests go
   alongside the relevant builtin's tests. A bug that only reproduces
   under GC pressure or deep recursion needs a test that recreates
   that pressure.

## How it's enforced

- **`test262-gc-stress` CI** — ReleaseSafe (verifiers + 0xaa
  free-poison armed) at `--gc-threshold=1` across the
  GC-mutation-heavy buckets, on every PR. A missed root is a
  deterministic crash there even though it's invisible to the
  ReleaseFast scoring sweep. See the job in
  `.github/workflows/ci.yml` and the `/gc-stress` workflow.
- **Unit regression tests** — the `GC:` cluster runs each fixed
  re-entry path under `gc_threshold = 1`.
- **The full ReleaseSafe sweep completes** — a host-abort mid-corpus
  used to wedge the run; a clean full sweep is itself a signal.

When a host-abort fix lands that no existing test262 fixture catches,
log it in
[../test262-upstream-gaps.md](../test262-upstream-gaps.md).
