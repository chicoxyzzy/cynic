# Shared optimizing backend experiment

Status: an **opt-in developer prototype**, not a production execution tier.
Ohaimark, Bistromath, Spasm, and their selection policies remain unchanged.
The experiment establishes a typed SSA boundary with JS and Wasm consumers;
it does not claim B3-level optimization or a throughput improvement.

## Why this boundary

Ohaimark already owns JS feedback, guards, SSA, representation selection,
allocation, and deoptimization. Spasm directly emits from validated Wasm.
Both reuse instruction encoders and executable-memory management. Their
production paths do not use the language-independent IR introduced here.

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
  Its [IR side exits and integer conversions](https://webkit.org/docs/b3/intermediate-representation.html)
  also motivate opaque client-owned recovery and explicit sign/zero extension.
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

The shared code lives in `src/runtime/jit/backend/`; the adapters live in
`src/runtime/wasm/backend_prototype.zig` and
`src/runtime/ohaimark/shared_backend.zig`. The shared layer imports neither
JS values/realms nor Wasm types, bytecode, instances, or Cells.

The initial subset has i32/i64 constants, wrapping add/subtract/multiply,
integer comparisons, bitwise AND/OR, explicit width conversions, ordered
guards, block parameters, jumps, conditional branches, and a single integer
result. The Wasm adapter accepts locals and void block/loop
constructs with `br`/`br_if`. Unsupported instructions or types are an explicit
refusal, even in dead bytecode; there is no silent fallback that could make an
execution test pass without running generated code.

Run the isolated correctness demo with `zig build backend-prototype`. It
compares the same sum-of-squares loop through both frontends: Wasm against
Sarcasm and native Spasm, JS against Lantern, and both against independent
arithmetic oracles. A JS case overflows Int32 after successful iterations and
must recover in Lantern, not restart the function. It reports native entry
and recovery counts, IR size, installed code size, compilation time, and
bounded-call time (including
scratch allocation). These diagnostics are not cross-engine benchmarks.

Focused tests: `zig build test-fast -Dtest-filter='backend prototype'` and
`zig build test-fast -Dtest-filter='shared Ohaimark backend'`.
Run the same tests and demo with `-Dtarget=x86_64-macos` on an Apple Silicon
host with Rosetta, or natively on the other supported architecture.

Integer arithmetic follows [Wasm Core numeric operations](https://webassembly.github.io/spec/core/exec/numerics.html).
Signedness belongs to comparisons, not storage types. i32 values have zeroed
upper 32 bits at the native boundary. This is **not** JS checked-Int32
arithmetic: the Ohaimark adapter lowers overflow and negative-zero guards
explicitly before returning a tagged JS result.

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

## JS guards and recovery

The Ohaimark adapter reuses its existing bytecode-to-SSA graph, specialization
plan, and pre-operation frame-state records. It handles primitive constants
(including existing pure folds), checked Int32 add/subtract/multiply, numeric
less-than/strict-equality, Int32 `ToNumeric`, boolean/Int32 truthiness, branches,
and loops. Other non-folded nodes, environments, and exception handlers refuse.
This developer path deliberately tries guarded Int32 operations even with
cold inputs; production Ohaimark's feedback policy is unchanged.

JS tagged values cross the shared boundary as opaque i64 words. Operand-tag
checks precede arithmetic. Signed widening to i64 followed by a round-trip
through i32 detects overflow; multiplication also checks for negative zero.
This preserves ECMA-262 §6.1.6.1.3
[Number::multiply](https://tc39.es/ecma262/#sec-numeric-types-number-multiply)
and §6.1.6.1.7-8 [Number::add/subtract](https://tc39.es/ecma262/#sec-numeric-types-number-add).
Other operand types exit before any coercion. Lantern then performs the
original operation, including user callbacks and abrupt completions.

A `guard` has no SSA result. A zero predicate captures an ordered list of
available values and returns an opaque frontend-owned exit ID. The shared
backend knows nothing about bytecode offsets or JS registers. Ohaimark owns
the ID-to-frame mapping and reconstructs the exact pre-operation accumulator,
live registers, `this`, and bytecode offset. Dead registers become undefined.
This uses the evaluator's detached `DeoptState` and synthetic Lantern frame;
production adoption must instead preserve the driver's active-frame identity.
The verifier checks capture availability and bounds, including use-before-def;
guards remain ordered effects even when none of their captures are used later.

Generated entries neither allocate nor call JS, and cannot trigger GC. Heap
constants are refused because the experiment has no compiled-code root table.
Incoming tagged references may be copied but are never dereferenced. The
returned value/recovery record is **not a GC root**: resume immediately, or
root it before intervening GC-capable work. Once resumed, Lantern's ordinary
frame-rooting contract applies. A test forces collection inside an object's
`valueOf` after recovery and checks that coercion runs only there.

## Safety and non-goals

- No native host calls, heap dereferences, Wasm memory operations, SIMD,
  floating-point arithmetic, exceptions, imports, inlining, OSR, or production
  tier-up in this slice.
- Compile-time limits cap input at 64 KiB, decoder/validator workspace at
  8 MiB, function bodies at 16 KiB, blocks at 256, SSA values at 2,048,
  IR nodes (including guards) at 4,096, and block arguments/captures at 64.
  The JS adapter caps bytecode at 16 KiB and registers at 63. Runtime scratch
  storage is heap-allocated and bounded by those limits; the execution budget
  is at most 1,000,000 visits.
- Generated code checks a mandatory finite budget at every block entry,
  including loop backedges. Exhaustion returns normally. These block visits
  are a **prototype work limit**, not Realm fuel or Wasm instruction counts.
  This does not implement asynchronous interruption and cannot be wired into
  a production Realm until that contract is preserved.
- The developer driver reports refusal on an unsupported target; no native
  entry means no claimed native result.
- No JS-visible state or globals are added. The experiment has no SES impact.
  Runtime integration must preserve ECMA-262 [completion records](https://tc39.es/ecma262/#sec-completion-record-specification-type)
  and pass test262 equality gates. The developer-only tests do not qualify a
  production tier or claim full-suite coverage of this backend.

## Contracts before expansion

Before memory operations or code motion, add conservative explicit read/write
effects, alias domains, trap ordering, and atomic/fence semantics. A guard,
budget poll, call, or trap must not disappear or move past an observable
operation merely because its result is unused.

Opaque frontend-owned recovery IDs and captured-value maps now exist. Before
production JS integration, GC roots, allocation, re-entry, and exception edges
must become explicit without importing JS object layouts into the backend.
Those operations remain absent, not implicitly pure.

Floating point needs explicit NaN, signed-zero, rounding, and conversion
semantics. Do not enable fast-math identities or silently reuse Wasm trapping
conversions for JavaScript coercions.

## Delivery and gates

1. **Current experiment:** verified integer SSA, bounded Wasm frontend,
   native execution on both architectures, and a separate developer driver.
   Unit tests compare results, edge transfers, overflow, refusal, and budget
   exhaustion. The driver compares against Sarcasm and requires native entry.
2. **Second consumer, developer-only:** narrow Ohaimark integer lowering,
   explicit guards, and exact recovery now run through the same native backend.
   Unit gates cover intermediate-state and loop recovery, signed zero, integer
   boundaries, unexpected operands, GC during resumed coercion, and allocation
   failures. Full test262 pass-set equality remains a production-integration gate.
3. **Measured optimizations:** add liveness-aware allocation, then pure constant
   folding, dead-value removal, and common-subexpression elimination
   individually. Add load elimination or loop motion only after effects are
   modeled and tested. Each pass needs an on/off correctness oracle.
4. **Wider Wasm coverage:** floating point, memory and traps, then calls and
   runtime integration. Preserve bounds checks, memory-growth invalidation,
   resource metering, and executable ownership before broadening the surface.
5. **Rollout decision:** paired warm/cold execution measurements, compilation
   latency, peak compiler allocation, installed code size, refusal/entry
   telemetry, differential fuzzing, and spec-suite gates. No automatic
   default-on graduation or new JS tier follows from finishing the prototype.

The next step is liveness-aware allocation and individually measurable pure
optimizations shared by both consumers. Keep the current scratch-slot lowering
as an oracle. Adopt the backend in production only if those measurements
justify its complexity.
