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
  Its separate Float/Double types and the
  [Wasm numeric semantics](https://webassembly.github.io/spec/core/exec/numerics.html)
  guide scalar FP lowering: preserve sign bits, distinguish numeric conversion
  from reinterpretation, and do not assume algebraic identities for NaNs/zeros.
  Cynic's existing Spasm emitters provide the local per-ISA reference, including
  x86's unordered comparisons and signed-zero min/max handling.
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
- [Briggs, Cooper, and Torczon's rematerialization work](https://doi.org/10.1145/143095.143143)
  motivates recreating cheap values instead of spilling them. V8 Maglev's
  [constant gap moves](https://github.com/v8/v8/blob/main/src/maglev/maglev-regalloc.cc)
  and B3's constant-materialization placement illustrate the same distinction
  between a constant and its physical home. Cynic starts with a bounded
  literal-only policy, not expression recomputation or global placement.
- B3's [effects and trapping operations](https://webkit.org/docs/b3/intermediate-representation.html)
  distinguish observable exits from removable calculations. Cranelift's
  [defined-semantics design](https://cranelift.dev/) is the relevant safety
  constraint: hostile arithmetic must not become compiler undefined behavior
  or a host signal. Cynic explicitly checks native division and returns a
  structured trap. The [CLIR study](https://arxiv.org/abs/2606.26977) motivates
  liveness-dense SSA tests across architectures; tests here keep allocated
  values live across fixed-register operations, rather than only checking
  standalone arithmetic results.

## First executable slice

The shared code lives in `src/runtime/jit/backend/`; the adapters live in
`src/runtime/wasm/backend_prototype.zig` and
`src/runtime/ohaimark/shared_backend.zig`. The shared layer imports neither
JS values/realms nor Wasm types, bytecode, instances, or Cells.

The subset has i32/i64 and f32/f64 constants, wrapping integer arithmetic,
strict scalar FP arithmetic, comparisons, bitwise operations, explicit width
conversions, ordered guards/traps, block parameters, jumps, conditional branches,
and a single scalar result. The Wasm adapter accepts locals and void block/loop
constructs with `br`/`br_if`. Unsupported instructions or types are an explicit
refusal, even in dead bytecode; there is no silent fallback that could make an
execution test pass without running generated code.

Run the isolated correctness demo with `zig build backend-prototype`. It
compares the same sum-of-squares loop through both frontends: Wasm against
Sarcasm and native Spasm, JS against Lantern, and both against independent
arithmetic oracles. Each frontend also runs rematerialization-off, CSE-off,
allocation-only, and unoptimized all-scratch variants. Allocation-only disables
all graph transformations and constant rematerialization; CSE-off retains
folding, DCE, and rematerialization.
A JS case overflows Int32 after successful iterations and
must recover in Lantern, not restart the function. It reports native entry
and recovery counts, IR size, code size, per-call scratch size, static emitted
loads/stores and allocator home/scratch register moves, compilation time, and
bounded-call time (including scratch allocation). Instruction counts include cold guard exits
and both branch paths; they are not dynamic memory-traffic measurements.
The move counter excludes copies internal to an arithmetic operation, including
GP/FP transfers in scalar floating-point emission.
It also reports input/output node counts, folds, commoned expressions, dead
nodes, and static rematerializations.
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

### Cheap constant rematerialization

Linear-scan allocation gives live cheap literals an `immediate` location
instead of reserving a register or spill slot. Cheap means zero or at most
one nonzero 16-bit lane: the existing AArch64 emitter uses one MOVZ, and
x86_64 uses one immediate move. This shared conservative policy leaves larger
literals in ordinary homes even though x86_64 can load them in one instruction.
Instruction count is only a cost proxy; it does not establish a speedup.

The emitter skips the original materialization and recreates the exact bits
in the requested scratch operand at each use. This includes returns, guard
predicates, ordered/duplicate guard captures, and edge sources. Parameters
retain normal homes, and all edge sources are captured before any destination
is overwritten. Arithmetic, guards, budget polls, and control-flow edges stay
in place.
The allocation verifier independently checks an immediate against its defining
constant node; parameters, arithmetic results, and forged bits are rejected.

Set `.rematerialize_constants = false` in `native.Options` or
`Program.buildWithOptions` to isolate the change. It defaults on only in this
developer backend; scratch allocation ignores it and retains a slot for every
SSA value. `Compiled.stats.rematerializations` counts emitted immediate reads,
including cold exits and both branch paths, not dynamic executions. Tests cover
all 16 combinations with folding/CSE/DCE, zero/one/four registers, typed integer
boundaries, exact captures, loop transfers, and budget exhaustion. Existing
allocation-failure tests also exercise the immediate path.

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

Arithmetic folding evaluates only operations whose operands are known integer
constants within the same block. It covers wrapping i32/i64 add/subtract/
multiply, bitwise AND/OR/XOR, signed/unsigned comparisons, and explicit width
conversions; same-width reinterpretation also folds by copying literal bits.
It does not apply algebraic identities to unknown values or infer constants
for block parameters. Integer truncation, two's-complement interpretation,
and sign extension are explicit; this is not floating-point or JS Number
folding. Ohaimark still owns tag checks, overflow, and negative-zero guards.

CSE visits definitions in block order, after each possible fold. Its key
contains the opcode, result type, canonical operand identities, and constant
bits where applicable. Only integer add/multiply, AND/OR/XOR, and equality/inequality use
unordered operand keys; subtraction, ordered comparisons, and sign/zero
extension remain distinct. It does not reassociate arithmetic or commute JS
operand evaluation: ECMA-262 §13.15.3-4
[binary evaluation and coercion](https://tc39.es/ecma262/multipage/ecmascript-language-expressions.html#sec-applystringornumericbinaryoperator)
remain the frontend's responsibility.

Each duplicate is replaced by an earlier local definition. The pass rewrites
later operands, guard predicates/captures, returns, branch conditions, and
edge arguments before DCE. Guards and potentially trapping operations are
never folded, commoned, removed, or moved;
nontrapping pure calculations can reuse values across a guard without changing
its ordered recovery record. No definitions are shared across blocks. The
temporary table holds at most 2,048 entries, reuses capacity between blocks,
and propagates allocation failures. Canonical representatives avoid recursive
alias chasing and do not depend on numeric value-ID order. CSE remains useful
with folding and DCE disabled.

DCE walks each block backwards from returns, branch conditions, edge
arguments, trapping instructions, and every guard predicate/capture. A guard is retained even if its
predicate is constant. Parameter lists, capture ordering (including duplicate
values), exit IDs, edges, and block order stay unchanged. Consequently loop
behavior and block-budget exhaustion remain directly comparable with the
unoptimized graph. Unused pure chains disappear transitively; unused block
parameters and unreachable blocks do not. An exhaustive purity switch forces
every future opcode to choose an effect contract before it can be removed.
The effect classification lives in the IR, not just in an optimizer-local
allowlist. A trapping definition remains in SSA even if its result is unused;
the allocator may discard the result home but never the operation.

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
each cell below is **optimized / rematerialization-off / CSE-off /
allocation-only / unoptimized scratch**.
These are static sizes/counts, not cross-engine performance scores:

| Frontend / target | Code bytes | Per-call scratch bytes | Emitted loads + stores |
|---|---:|---:|---:|
| Wasm / AArch64 | 348 / 364 / 348 / 372 / 388 | 528 / 528 / 528 / 528 / 664 | 24 / 24 / 24 / 24 / 68 |
| Wasm / x86_64 | 426 / 431 / 426 / 444 / 632 | 528 / 528 / 528 / 528 / 664 | 24 / 24 / 24 / 24 / 68 |
| JS / AArch64 | 1,788 / 1,868 / 1,932 / 2,204 / 2,252 | 568 / 584 / 560 / 560 / 1,312 | 156 / 174 / 156 / 171 / 374 |
| JS / x86_64 | 2,465 / 2,506 / 2,620 / 2,879 / 3,727 | 568 / 584 / 560 / 560 / 1,312 | 156 / 174 / 156 / 171 / 374 |

The JS loop folds four computations, commons 28 expressions, and removes two
dead nodes (98 to 68); CSE-off leaves 91 nodes. Rematerialization leaves the
graph unchanged and reduces code size by 4.3% on AArch64 and 1.6% on x86_64
relative to the same graph with rematerialization disabled. Register moves
fall from 140 to 125, scratch from 584 to 568 bytes, and static loads/stores
from 174 to 156. There are 23 emitted immediate reads in the JS graph and three
in the Wasm graph. The fixed transfer area still dominates scratch, and CSE's
extended live ranges still cost eight bytes versus CSE-off. These are code-size
and storage wins, not a demonstrated throughput win; operand placement remains
an optimization opportunity.
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

## Scalar floating point

The shared IR and Wasm adapter accept f32/f64 constants, add/subtract/multiply/
divide, min/max, copy-sign, absolute value, negation, square root, all six
comparisons, promotion/demotion, and same-width integer/float reinterpretation.
The Ohaimark adapter still lowers checked Int32 operations; adding shared FP
does not silently change JS specialization or coercion behavior.

Homes and block arguments carry raw IEEE-754 bits. f32 values have zero upper
32 bits, like i32. The verifier rejects mixed-width arithmetic, integer ops on
float values, raw floats used as branch conditions, and mismatched
conversions. A shared operand-count definition keeps liveness, remapping, and
emission consistent for unary operations.

FP arithmetic uses AArch64 v16/v17 or x86 xmm0/xmm1 as short-lived temporaries;
the allocator still assigns GP homes. There is no FP-register allocation yet.
Sign operations and reinterpretation preserve signaling-NaN payloads exactly.
Arithmetic follows Wasm's permitted NaN classes; comparisons return false for
unordered inputs except `ne`. x86 min/max explicitly handle unordered inputs
and both signed-zero orders instead of using SSE MIN/MAX directly. These paths
use the existing baseline instruction set and introduce no native helper calls.

There is no FP arithmetic constant folding, reassociation, fast math, or
commutative operand normalization. CSE may reuse identical ordered expressions;
constant keys include the type and every bit, so +0/-0 and distinct NaN payloads
stay distinct. Reinterpretation of a known literal can fold without evaluating
it as a host float. Guards capture exact raw bits across all optimization and
rematerialization combinations.

Tests force native entry and compare with Sarcasm with Spasm disabled. They
cover both widths, infinities, subnormals, signed zero, quiet/signaling NaNs,
register pressure, constant and runtime conversions, mixed integer/float loop
edges, budget exhaustion, invalid graphs, and allocation-failure cleanup.
Numeric integer/float conversions, trapping truncation, and the four rounding
operations are still explicit refusals, not interpreter fallback or complete
scalar coverage. Production resource policy and FP-environment integration
remain part of the rollout work.

## Integer operations and traps

The Wasm adapter now lowers the complete scalar integer numeric family for
i32/i64: arithmetic, signed/unsigned division and remainder, bitwise operations,
masked shifts/rotates, zero/leading/trailing/population counts, comparisons,
integer width conversions, and sign-extension operations. This does not include
integer/float numeric conversions, memory operations, or the `select` control
instruction. It also accepts `unreachable`, including in dead validated code.
Unsupported operations such as calls still refuse even in dead bytecode.

Division and remainder declare `may_trap` effects and require a frontend-owned
`trap_site`; pure operations and guards reject that metadata. A terminal `trap`
needs no result value. `Compiled.runOutcome` returns `trapped: { reason, site }`
separately from normal return and recoverable guard exit. The Wasm frontend uses
the opcode byte offset within the validated function's instruction stream;
the backend does not interpret it. `Compiled.run` translates the reason to
`IntegerDivideByZero`, `IntegerOverflow`, or `Unreachable`. Malformed native
status/metadata is rejected before it reaches a consumer.

Following [Wasm numeric semantics](https://webassembly.github.io/spec/core/exec/numerics.html),
zero divisors trap, signed MIN/-1 division traps, but signed MIN%-1 returns zero.
x86 checks both dangerous cases before IDIV so neither can raise a host signal;
unsigned DIV uses a zero high dividend. AArch64 checks the same conditions
explicitly because its integer division does not trap. Branches to trap returns
stay at the original operation, after the block budget poll. Unused results,
known constants, duplicate divisions, guards, and untaken branches cannot erase
or reorder the first observable trap.

These are low-level machine-integer semantics, not ECMAScript
[Number::divide / Number::remainder](https://tc39.es/ecma262/multipage/ecmascript-data-types-and-values.html#sec-numeric-types-number-divide)
(ECMA-262 section 6.1.6.1.5-6). JS specialization/coercion stays in Ohaimark; its
current adapter emits no trapping integer operations and rejects an unexpected
native trap rather than treating it as a deoptimization or a JS value. No
JS-visible surface or SES policy changes.

The x86 allocator still owns RCX/RDX. Shifts and sign extension save/restore RCX
through R11; division saves/restores RDX after safety checks. R10/R11 are scratch
only. CLZ/CTZ handle zero explicitly with baseline bit scans; population count
uses a bounded SWAR sequence, not an assumed POPCNT instruction. AArch64 uses
its baseline scalar and Advanced SIMD encoders. Tests cover both widths and
architectures, boundary shift counts, negative dividends, exact trap reasons
and sites, all optimizer switches, live homes across fixed-register operations,
allocation failure, guard ordering, and untaken traps.

## Safety and non-goals

- No native host calls, heap dereferences, Wasm memory operations, SIMD,
  exceptions, imports, inlining, OSR, or production
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

Scalar traps now have explicit ordering. Before memory operations or code motion,
add conservative explicit read/write effects, alias domains, and atomic/fence semantics. A guard,
budget poll, call, or trap must not disappear or move past an observable
operation merely because its result is unused.

Opaque frontend-owned recovery IDs and captured-value maps now exist. Before
production JS integration, GC roots, allocation, re-entry, and exception edges
must become explicit without importing JS object layouts into the backend.
Those operations remain absent, not implicitly pure.

Further floating-point operations need explicit rounding and conversion-trap
semantics. Do not enable fast-math identities or silently reuse Wasm trapping
conversions for JavaScript coercions.

## Delivery and gates

### Production completion checklist

The active objective is a fully functional shared backend for Cynic's JS and
Wasm execution, not completion of the integer prototype. These gates are still
open; a passing demo or unchanged production test262 run does not close them.

- [ ] Complete scalar numeric types and operations, including strict floating
  point, bit-preserving conversions, and explicit integer/truncation traps.
- [ ] Model memory, calls, traps, safepoints, and ordered effects in the IR and
  verifier before optimizing them; preserve aliasing, atomics, and trap order.
- [ ] Support the accepted Wasm control/signature surface, memory and growth,
  tables/references, calls/imports, globals, SIMD, and exception behavior through
  a real instance-aware optimizing path, not just the standalone demo.
- [ ] Integrate Ohaimark's numeric and heap operations, calls, guards, exact
  frame recovery, OSR, GC roots/write barriers, re-entry, and exception edges.
- [ ] Preserve Realm fuel, asynchronous interruption, memory ceilings,
  executable ownership, and teardown in both production consumers.
- [ ] Qualify both AArch64 and x86_64 with forced-native-entry differential
  tests, test262 and Wasm/WPT suites, GC/allocation stress, and differential
  fuzzing. Track refusals so fallback cannot hide missing coverage.
- [ ] Measure warm/cold execution, compilation time and peak memory, code size,
  and scratch use on representative JS/Wasm workloads; make the rollout
  decision from those results, with working diagnostics and opt-outs.

Each capability must have direct backend tests and frontend integration tests.
Baseline fallback remains necessary for unsupported targets and resource
failures, but is not evidence that an unimplemented backend capability works.

1. **Current experiment:** verified scalar SSA, bounded Wasm frontend,
   native execution on both architectures, and a separate developer driver.
   Unit tests compare results, edge transfers, overflow, refusal, and budget
   exhaustion. The driver compares against Sarcasm and requires native entry.
2. **Second consumer, developer-only:** narrow Ohaimark integer lowering,
   explicit guards, and exact recovery now run through the same native backend.
   Unit gates cover intermediate-state and loop recovery, signed zero, integer
   boundaries, unexpected operands, GC during resumed coercion, and allocation
   failures. Full test262 pass-set equality remains a production-integration gate.
3. **Liveness-aware allocation, developer-only:** verified register/spill homes,
   reused spill slots, cheap-constant rematerialization, exact guard captures,
   and an all-scratch oracle now serve both frontends. Static code/memory
   diagnostics accompany correctness gates; this does not establish a
   production throughput win.
4. **Shared pure optimizations, developer-only:** independently switchable
   block-local constant folding, CSE, and dead-code elimination now run before
   allocation, with exact unoptimized comparisons. Better instruction
   selection remains next. Add load elimination or loop motion only after
   effects are modeled and tested.
5. **Wider Wasm coverage:** core scalar floating point and the complete scalar
   integer family now run natively, with explicit ordered integer traps.
   Finish rounding/numeric conversions, then memory, calls, and runtime
   integration. Preserve bounds checks,
   memory-growth invalidation, resource metering, and executable ownership.
6. **Rollout decision:** paired warm/cold execution measurements, compilation
   latency, peak compiler allocation, installed code size, refusal/entry
   telemetry, differential fuzzing, and spec-suite gates. No automatic
   default-on graduation or new JS tier follows from finishing the prototype.

The next capability work is floating-point rounding and numeric conversions,
then memory/call effects and runtime integration. Operand-move reduction and immediate/compare-branch
selection remain measured optimization work, not substitutes for coverage.
Keep each change independently measurable against disabled variants and
unoptimized references.
Adopt the backend in production only if measurements justify its complexity.
