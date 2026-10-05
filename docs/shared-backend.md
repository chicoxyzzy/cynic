# Shared optimizing backend experiment

Status: an **opt-in developer prototype**, not a production execution tier.
Ohaimark, Bistromath, Spasm, and their selection policies remain unchanged.
The first experiment establishes a typed SSA boundary and native execution;
it does not claim B3-level optimization or a throughput improvement.

## Why this boundary

Ohaimark already owns JS feedback, guards, SSA, representation selection,
allocation, and deoptimization. Spasm directly emits from validated Wasm.
Both reuse instruction encoders and executable-memory management, but neither
can currently consume a language-independent optimizing IR.

The intended eventual pipeline is:

```text
JS bytecode -> Ohaimark specialization/guards ---+
                                                +-> low-level SSA -> native code
Wasm validation -> optimizing Wasm frontend ----+
```

Bistromath and Spasm remain direct-emitting baseline tiers. Adding an IR to
their normal paths would spend startup time without proving a benefit.

## Prior art

- [WebKit B3](https://webkit.org/docs/b3/) separates C-like typed SSA from
  JS specialization. Its [Air layer](https://webkit.org/docs/b3/assembly-intermediate-representation.html)
  handles machine constraints and allocation. Adopt the semantic boundary;
  do not pre-build a second IR or graph-coloring allocator for this experiment.
- [V8 Turboshaft](https://github.com/v8/v8/tree/main/src/compiler/turboshaft)
  is a useful shared-backend reference. Keep lowering distinct from language
  feedback rather than moving JS-shaped nodes into a nominally shared folder.
- [Wasmtime/Cranelift](https://docs.wasmtime.dev/contributing-architecture.html)
  separates Wasm translation from native compilation. Block parameters are a
  compact way to make loop-carried values explicit without mutable locals in
  the low-level IR.
- SpiderMonkey's MIR/LIR sharing and the interpreter-first Hermes, QuickJS,
  XS, and Boa alternatives are surveyed in [jit.md](jit.md#2-what-the-survey-found).
  They do not justify replacing Cynic's existing baseline paths.
- Titzer's [Whose baseline compiler is it anyway?](https://arxiv.org/abs/2305.13241)
  motivates measuring compilation, memory, and execution separately, not
  treating one throughput number as sufficient evidence for a tier.

## First executable slice

The shared code lives in `src/runtime/jit/backend/`; the Wasm adapter lives in
`src/runtime/wasm/backend_prototype.zig`. The shared layer imports neither JS
values/realms nor Wasm types, bytecode, instances, or Cells.

The initial subset has i32/i64 constants, wrapping add/subtract/multiply,
integer comparisons, block parameters, jumps, conditional branches, and a
single integer result. The Wasm adapter accepts locals and void block/loop
constructs with `br`/`br_if`. Unsupported instructions or types are an explicit
refusal, even in dead bytecode; there is no silent fallback that could make an
execution test pass without running generated code.

Run the isolated correctness demo with `zig build backend-prototype`. It
compares a bounded integer loop against Sarcasm, native Spasm, and an
independent arithmetic oracle. It reports native entry counts, IR size,
installed code size, compilation time, and bounded-call time (including
scratch allocation). These diagnostics are not cross-engine benchmarks.

Focused tests: `zig build test-fast -Dtest-filter='backend prototype'`.
Run the same tests and demo with `-Dtarget=x86_64-macos` on an Apple Silicon
host with Rosetta, or natively on the other supported architecture.

Integer arithmetic follows [Wasm Core numeric operations](https://webassembly.github.io/spec/core/exec/numerics.html).
Signedness belongs to comparisons, not storage types. i32 values have zeroed
upper 32 bits at the native boundary. This is **not** JS checked-Int32
arithmetic: a future Ohaimark adapter must lower overflow and negative-zero
guards explicitly before it can use wrapping machine operations.

Every block owns its SSA definitions. Values cross blocks only through typed
edge arguments; edge transfers are simultaneous. The verifier checks complete
single definitions, local use-before-definition, edge arity/types, i32
branch conditions, result types, bounds, and entry-block restrictions.
It runs before any executable code is installed.

The first native lowering deliberately assigns values to bounded scratch
slots rather than implementing another allocator. AArch64 and x86_64 SysV
backends use the existing encoders and W^X allocator. Code is published only
after verification and complete emission; an allocation or emission failure
releases temporary state. This is a correctness baseline, not an efficient
register-allocation strategy.

## Safety and non-goals

- No host calls, heap references, Wasm memory operations, SIMD, floating point,
  exceptions, imports, inlining, OSR, or production tier-up in this slice.
- Compile-time limits cap input at 64 KiB, decoder/validator workspace at
  8 MiB, function bodies at 16 KiB, blocks at 256, SSA values at 2,048, and
  block arguments at 64. Runtime scratch storage is heap-allocated and
  bounded by those limits; the execution budget is at most 1,000,000 visits.
- Generated code checks a mandatory finite budget at every block entry,
  including loop backedges. Exhaustion returns normally. These block visits
  are a **prototype work limit**, not Realm fuel or Wasm instruction counts.
  This does not implement asynchronous interruption and cannot be wired into
  a production Realm until that contract is preserved.
- The developer driver reports refusal on an unsupported target; no native
  entry means no claimed native result.
- No JS-visible state or globals are added. The experiment has no SES impact.
  A future JS adapter must preserve ECMA-262 [completion records](https://tc39.es/ecma262/#sec-completion-record-specification-type)
  and exact interpreter recovery, verified by test262 pass-set equality.

## Contracts before expansion

Before memory operations or code motion, add conservative explicit read/write
effects, alias domains, trap ordering, and atomic/fence semantics. A guard,
budget poll, call, or trap must not disappear or move past an observable
operation merely because its result is unused.

Before JS integration, define opaque frontend-owned recovery identifiers and
live-value maps. GC roots, allocation, re-entry, and exception edges must be
visible to the backend without importing JS object layouts into it. The
current prototype has no such nodes; their absence is a restriction, not an
implicit promise that all future operations are pure.

Floating point needs explicit NaN, signed-zero, rounding, and conversion
semantics. Do not enable fast-math identities or silently reuse Wasm trapping
conversions for JavaScript coercions.

## Delivery and gates

1. **Current experiment:** verified integer SSA, bounded Wasm frontend,
   native execution on both architectures, and a separate developer driver.
   Unit tests compare results, edge transfers, overflow, refusal, and budget
   exhaustion. The driver compares against Sarcasm and requires native entry.
2. **Second consumer:** lower a narrow Ohaimark numeric subset with explicit
   guards and recovery metadata. Keep it opt-in and verify GC-pressure,
   deoptimization, and exact test262 pass-set equality on both architectures.
3. **Measured optimizations:** add pure constant folding, dead-value removal,
   and common-subexpression elimination individually, followed by allocation
   improvements. Add load elimination or loop motion only after effects are
   modeled and tested. Each pass needs an on/off correctness oracle.
4. **Wider Wasm coverage:** floating point, memory and traps, then calls and
   runtime integration. Preserve bounds checks, memory-growth invalidation,
   resource metering, and executable ownership before broadening the surface.
5. **Rollout decision:** paired warm/cold execution measurements, compilation
   latency, peak compiler allocation, installed code size, refusal/entry
   telemetry, differential fuzzing, and spec-suite gates. No automatic
   default-on graduation or new JS tier follows from finishing the prototype.

The next decision is whether this boundary earns its complexity with two
real consumers. If it does not, retain the useful tests and measurements and
avoid forcing the production compilers through it.
