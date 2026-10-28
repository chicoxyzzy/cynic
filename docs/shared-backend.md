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
- [V8 Maglev](https://v8.dev/blog/maglev) and Poletto/Sarkar's
  [linear-scan paper](https://bernsteinbear.com/assets/img/linearscan-ra.pdf)
  motivate a liveness prepass, forward register assignment, and a farthest-end
  spill heuristic. This prototype reuses production Ohaimark's policy, not its
  JS-specific allocation structures. Air's early-use/late-definition distinction
  permits reusing a dying input's home after both operands have been read.
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
- B3's [dead-code pass](https://github.com/WebKit/WebKit/blob/main/Source/JavaScriptCore/b3/B3EliminateDeadCode.cpp)
  and [Turboshaft's liveness analysis](https://github.com/v8/v8/blob/main/src/compiler/turboshaft/dead-code-elimination-reducer.h)
  retain required operations and propagate their operand uses. Cynic uses
  this distinction for guards, without their CFG transformations. Local
  integer folding follows the low-level boundary of
  [Turboshaft's machine reducer](https://github.com/v8/v8/blob/main/src/compiler/turboshaft/machine-optimization-reducer.h).
  Wegman/Zadeck's [conditional constant propagation](https://cs.brown.edu/research/pubs/techreports/reports/CS-89-36.html)
  is the reference for a possible later cross-block analysis, not an algorithm
  implemented by this block-local pass.
- B3's [PureCSE](https://github.com/WebKit/WebKit/blob/main/Source/JavaScriptCore/b3/B3PureCSE.cpp)
  and [Turboshaft value numbering](https://github.com/v8/v8/blob/main/src/compiler/turboshaft/value-numbering-reducer.h)
  reuse matching expressions only where an earlier definition dominates the
  use. Cynic takes the smaller block-local case: a hash table of typed pure
  expressions, cleared at each block, with no memory or throwing operations.
  Briggs/Cooper/Simpson's [Value Numbering](https://bernsteinbear.com/assets/img/briggs-gvn.pdf)
  supplies the local hash-based algorithm; global value numbering and code
  motion remain outside this pass.

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
arithmetic oracles. Each frontend also runs CSE-off, allocation-only, and
unoptimized all-scratch variants, separating CSE, other passes, and allocator
gains.
A JS case overflows Int32 after successful iterations and
must recover in Lantern, not restart the function. It reports native entry
and recovery counts, IR size, code size, per-call scratch size, static emitted
loads/stores and register moves, compilation time, and bounded-call time
(including scratch allocation). Instruction counts include cold guard exits
and both branch paths; they are not dynamic memory-traffic measurements.
It also reports input/output node counts, folds, commoned expressions, and
dead nodes.
These diagnostics are not cross-engine benchmarks.

Focused tests: `zig build test-fast -Dtest-filter='backend'` covers the
allocator, native prototype, and shared Ohaimark adapter.
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

AArch64 and x86_64 SysV backends use the existing encoders and W^X allocator.
Code is published only after graph/allocation verification and complete
emission; an allocation or emission failure releases temporary state.

## Liveness-aware allocation

The prototype defaults to block-local linear scan. Cross-block liveness is
already explicit in edge arguments, so no global dataflow solver is needed.
Lifetimes include guard captures and arguments on both successors. Reads
precede writes: the emitter loads operands into reserved scratch registers
before assigning a result, allowing an input's last use to share its home
with that result.

The allocator uses four caller-saved registers: AArch64 `x4`-`x7`, or SysV
x86_64 `rcx`, `rdx`, `r8`, `r9`. The scratch pointer, block budget, arithmetic
temporaries, and platform/callee-saved registers are excluded. Under pressure,
the value with the farthest end is spilled when that frees a register for a
shorter-lived value. Spill decisions apply to the whole lifetime: the emitter
stores at the definition, with no late spill or interval splitting. Spill
slots are reused after last use and across blocks. All homes hold 64-bit words.

A separate allocation verifier recomputes lifetimes and checks every home,
register bound, spill bound, and overlapping assignment. Its pairwise check is
bounded by the 2,048-value IR limit. Edge transfers still snapshot all sources
before assigning any destination, including register/spill cycles. Unused
definitions need no home, but their computation is still emitted; this is not
a dead-code-elimination pass.

`native.compileWithOptions(..., .{ .allocation = .scratch })` retains one
scratch slot per SSA value as the correctness oracle. The Ohaimark adapter
exposes the same option through `Program.buildWithOptions`. Tests also force
zero or one available register to exercise spill reuse. Seeded pressure graphs
compare every guard's ID and captured bits; JS tests compare exact recovery
frames before resuming Lantern. Loop transfers, budget exhaustion, malformed
plans, and allocation-failure cleanup are covered on both native architectures.

This remains a leaf-code allocator. Native calls would require explicit
clobbers and ABI constraints; GC-capable calls additionally require root maps.
Neither is supported implicitly. Operand shuffles and the fixed 64-word edge
transfer area remain; reducing them is a separate measured improvement.

## Shared pure optimizations

The prototype runs constant folding and block-local common-subexpression
elimination (CSE), followed by dead-code elimination before register allocation.
All three default on in this developer path and have independent switches
under `native.Options.optimization`:

```zig
.{ .optimization = .{
    .constant_folding = false,
    .common_subexpression_elimination = false,
    .dead_code_elimination = false,
} }
```

With all three off, native compilation bypasses graph transformation. Combine
those switches with `.allocation = .scratch` for the unoptimized scratch
reference. `Program.buildWithOptions` forwards the same options for JS.
`Compiled.optimization` reports input/output nodes, folded nodes, CSE's
`commoned_nodes`, and DCE's `removed_nodes`. Folds count replacements even if
CSE or DCE subsequently removes that node; input nodes equal output plus
commoned plus removed nodes.

Folding evaluates only operations whose operands are known integer constants
within the same block. It covers wrapping i32/i64 add/subtract/multiply,
bitwise AND/OR, signed/unsigned comparisons, and explicit width conversions.
It does not apply algebraic identities to unknown values or infer constants
for block parameters. Integer truncation, two's-complement interpretation,
and sign extension are explicit; this is not floating-point or JS Number
folding. Ohaimark still owns tag checks, overflow, and negative-zero guards.

CSE visits definitions in block order, after each possible fold. Its key
contains the opcode, result type, canonical operand identities, and constant
bits where applicable. Only integer add/multiply, AND/OR, and equality use
unordered operand keys; subtraction, ordered comparisons, and sign/zero
extension remain distinct. It does not reassociate arithmetic or commute JS
operand evaluation: ECMA-262 §13.15.3-4
[binary evaluation and coercion](https://tc39.es/ecma262/multipage/ecmascript-language-expressions.html#sec-applystringornumericbinaryoperator)
remain the frontend's responsibility.

Each duplicate is replaced by an earlier local definition. The pass rewrites
later operands, guard predicates/captures, returns, branch conditions, and
edge arguments before DCE. Guards are never commoned, removed, or moved;
nontrapping pure calculations can reuse values across a guard without changing
its ordered recovery record. No definitions are shared across blocks. The
temporary table holds at most 2,048 entries, reuses capacity between blocks,
and propagates allocation failures. Canonical representatives avoid recursive
alias chasing and do not depend on numeric value-ID order. CSE remains useful
with folding and DCE disabled.

DCE walks each block backwards from returns, branch conditions, edge
arguments, and every guard predicate/capture. A guard is retained even if its
predicate is constant. Parameter lists, capture ordering (including duplicate
values), exit IDs, edges, and block order stay unchanged. Consequently loop
behavior and block-budget exhaustion remain directly comparable with the
unoptimized graph. Unused pure chains disappear transitively; unused block
parameters and unreachable blocks do not. An exhaustive purity switch forces
every future opcode to choose an effect contract before it can be removed.

The optimizer validates its input before any removal, owns a separate output
graph, densely renumbers surviving values, and verifies the result before
emission. Malformed dead nodes are still errors. All passes are bounded by
the existing graph limits and use no recursive graph traversal. Tests cover
all eight switch combinations, integer boundaries, commutative/ordered keys,
block isolation, mixed register pressure, seeded native differential cases,
input ownership, table growth, graph limits, and allocation failures. The JS
frontend compares exact recovery frames and the Wasm frontend compares with
Sarcasm. Neither frontend gains a new production execution path.

For the fixed sum-of-squares demo (ReleaseSafe, macOS; x86_64 via Rosetta),
each cell below is **optimized / CSE-off / allocation-only / unoptimized scratch**.
These are static sizes/counts, not cross-engine performance scores:

| Frontend / target | Code bytes | Per-call scratch bytes | Emitted loads + stores |
|---|---:|---:|---:|
| Wasm / AArch64 | 364 / 372 / 372 / 388 | 528 / 528 / 528 / 664 | 24 / 24 / 24 / 68 |
| Wasm / x86_64 | 431 / 444 / 444 / 632 | 528 / 528 / 528 / 664 | 24 / 24 / 24 / 68 |
| JS / AArch64 | 1,868 / 2,124 / 2,204 / 2,252 | 584 / 560 / 560 / 1,312 | 174 / 163 / 171 / 374 |
| JS / x86_64 | 2,506 / 2,764 / 2,879 / 3,727 | 584 / 560 / 560 / 1,312 | 174 / 163 / 171 / 374 |

The JS loop folds four computations, commons 28 expressions, and removes two
dead nodes (98 to 68); CSE-off leaves 91 nodes. CSE cuts code size by 12.1% on
AArch64 and 9.3% on x86_64 relative to folding/DCE alone, and register moves
fall from 188 to 140 on both. Sharing also extends live ranges: with the current
allocator, scratch rises from 560 to 584 bytes and static loads/stores from
163 to 174. This is a code-size win, not a demonstrated throughput win.
Cheap-constant rematerialization and operand placement deserve measurement next.
The Wasm loop shares one initial zero constant (seven to six nodes); its
loop-dependent arithmetic remains unchanged.
Compile/run timings remain diagnostic; a rollout needs paired measurements
that account for warmup, ordering, and the extra compiler work.

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
3. **Liveness-aware allocation, developer-only:** verified register/spill homes,
   reused spill slots, exact guard captures, and an all-scratch oracle now serve
   both frontends. Static code/memory diagnostics accompany correctness gates;
   this does not establish a production throughput win.
4. **Shared pure optimizations, developer-only:** independently switchable
   block-local constant folding, CSE, and dead-code elimination now run before
   allocation, with exact unoptimized comparisons. Better instruction
   selection remains next. Add load elimination or loop motion only after
   effects are modeled and tested.
5. **Wider Wasm coverage:** floating point, memory and traps, then calls and
   runtime integration. Preserve bounds checks, memory-growth invalidation,
   resource metering, and executable ownership before broadening the surface.
6. **Rollout decision:** paired warm/cold execution measurements, compilation
   latency, peak compiler allocation, installed code size, refusal/entry
   telemetry, differential fuzzing, and spec-suite gates. No automatic
   default-on graduation or new JS tier follows from finishing the prototype.

The next step is reducing operand moves, measuring cheap-constant
rematerialization, and improving immediate/compare-branch selection. Keep each
change independently measurable against the CSE-off and unoptimized references.
Adopt the backend in production only if measurements justify its complexity.
