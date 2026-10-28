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

Cleanup follows production migration, not prototype coverage. Keep Lantern and
Sarcasm as interpreters and differential references, and keep both baseline
compilers. Retire duplicated Ohaimark optimization/allocation/emission code
only when its production replacement passes the same correctness, recovery,
resource, and performance gates. JS specialization/GC/deoptimization and Wasm
validation/instance semantics remain frontend-owned. Share a helper when both
consumers use the same contract, not merely similar-looking instructions.

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
- B3's memory effects and Cranelift's
  [memory flags](https://docs.rs/cranelift-codegen/latest/cranelift_codegen/ir/struct.MemFlagsData.html)
  distinguish aliasing, alignment, and trapping assumptions. Cynic's bounded
  accesses assume neither disjoint regions nor aligned/non-trapping addresses.
  The existing Spasm bounds checks provide the local instruction-level reference.
- B3's [CCall and patchpoint contracts](https://webkit.org/docs/b3/intermediate-representation.html)
  make call effects and ABI constraints explicit. V8 Maglev's
  [allocation design](https://v8.dev/blog/maglev) and LLVM's
  [statepoint model](https://llvm.org/docs/Statepoints.html) motivate preserving
  live values and identifying roots at call boundaries. Cynic uses frontend-owned
  snapshots for its non-moving collector, not LLVM relocation semantics or
  conservative scanning of arbitrary integer words.

## First executable slice

The shared code lives in `src/runtime/jit/backend/`; the adapters live in
`src/runtime/wasm/backend_prototype.zig` and
`src/runtime/ohaimark/shared_backend.zig`. The shared layer imports neither
JS values/realms nor Wasm types, bytecode, instances, or Cells.

The subset has i32/i64 and f32/f64 constants, wrapping integer arithmetic,
strict scalar FP arithmetic, comparisons, bitwise operations, explicit width
conversions, ordered guards/traps, block parameters, jumps, conditional branches,
bounded scalar loads/stores, typed runtime calls, and a single scalar result.
The Wasm adapter accepts locals, scalar-typed block/loop/if constructs (including
multiple block parameters/results), `br`/`br_if`/`br_table`, and scalar `select`.
Unsupported instructions or types are an explicit
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

At runtime calls the emitter saves live allocated registers into bounded
invocation scratch, stages arguments and frontend root snapshots, and restores
the live registers before assigning the result. Spill homes remain stable.
Root interpretation is a frontend contract, not inferred from i64 bits.
Operand shuffles and the fixed 64-word edge
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

The current Ohaimark adapter's generated entries neither allocate nor call JS,
and cannot trigger GC. Heap
constants are refused because the experiment has no compiled-code root table.
Incoming tagged references may be copied but are never dereferenced. The
returned value/recovery record is **not a GC root**: resume immediately, or
root it before intervening GC-capable work. Once resumed, Lantern's ordinary
frame-rooting contract applies. A test forces collection inside an object's
`valueOf` after recovery and checks that coercion runs only there.

## Scalar floating point

The shared IR and Wasm adapter accept f32/f64 constants, add/subtract/multiply/
divide, min/max, copy-sign, absolute value, negation, square root, all six
comparisons, ceil/floor/trunc/nearest, promotion/demotion, numeric integer/float
conversions, and same-width integer/float reinterpretation.
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
Production resource policy remains part of the rollout work. Native leaf entry
now establishes the FP environment described below; it does not rely on the
embedding application's rounding mode or exception masks.

### Floating-point entry and exit

ECMA-262 [Number operations (section 6.1.6.1)](https://tc39.es/ecma262/multipage/ecmascript-data-types-and-values.html#sec-ecmascript-language-types-number-type)
and [Wasm floating-point operations](https://webassembly.github.io/spec/core/exec/numerics.html#floating-point-operations)
must not inherit an embedder's directed rounding or flush-to-zero mode.
The generated leaf prologue saves the caller's state and establishes
nearest-even rounding, gradual underflow, masked hardware exceptions, and
cleared status flags. Every native return restores the exact saved controls
and flags, including guard exits, arithmetic/conversion traps, terminal traps,
and budget exhaustion before or after a loop. Direct native entry receives the
same protection as `Compiled.runOutcome`; this is not a wrapper-only fix.

On x86_64, STMXCSR/LDMXCSR save and restore MXCSR, with `0x1f80` used inside
generated code. The independent x87 state stays untouched because this backend
emits no x87 arithmetic. On AArch64, MRS/MSR save FPCR and FPSR; entry clears the
f32/f64 rounding, flush, alternate/NaN-handling, exception-enable, and status
bits while preserving unrelated controls. Exit restores FPSR before FPCR.
State lives in two extra scratch words per invocation, not global storage.
The graph is checked after optimization: integer-only graphs, raw float-bit
transfers, and graphs whose only FP arithmetic was removed by DCE receive no
extra entry/exit instructions or scratch slots.

The instruction/register model follows [Arm AAPCS64](https://github.com/ARM-software/abi-aa/blob/main/aapcs64/aapcs64.rst#simd-and-floating-point-registers)
and [LLVM libc's MXCSR handling](https://github.com/llvm/llvm-project/blob/main/libc/src/__support/FPUtil/x86_64/fenv_mxcsr_utils.h).
[V8's AssertFPCRState](https://github.com/v8/v8/blob/main/src/codegen/arm64/macro-assembler-arm64.cc)
illustrates the same dependence on rounding and denormal controls. Cynic
normalizes and restores instead of requiring that an arbitrary host already
has those settings. Exact sticky-flag restoration is a stronger contract than
the ordinary AArch64 calling convention requires.

Static memory-traffic counters include this machinery: both targets emit two
stores on entry; x86 additionally loads the canonical MXCSR and reloads saved
MXCSR at each exit, while AArch64 loads two saved words at each exit. This
adds code and 16 bytes of scratch to FP functions; no speedup is claimed.
Tests exercise all rounding modes, input/output subnormals, unmasked exceptions
where supported by the hardware, preexisting flags, each exit kind, direct
Wasm-lowered entry, optimizer/allocation variants, and allocation failures.
The hardware-exception test checks actual control-register readback. It reports
a skip on Arm hardware without exception-enable support, or when Rosetta forces
MXCSR masks on; native x86 must really enable the exceptions. An emulated pass
is not counted as native hardware-exception coverage.

Runtime calls explicitly choose the caller's FP environment for raw host
callbacks or strict controls for language-execution helpers. On return they
re-establish strict controls without overwriting the entry snapshot; every exit
restores the original state, including callback errors and nested entry. This
does not add FP-environment isolation to unrelated production tiers; entry
normalization alone does not qualify those boundaries or non-local unwinding.
Production Ohaimark and Spasm are not rerouted by this change.

### Rounding and numeric conversions

The language-neutral `convert_s` / `convert_u` operations convert i32/i64 to
f32/f64 with signedness on the operation, not the storage type. `trunc_s` /
`trunc_u` convert in the other direction with ordered, location-bearing traps:
NaN produces `invalid_conversion`, while infinity and out-of-range finite
inputs produce `integer_overflow`. `trunc_sat_s` / `trunc_sat_u` are separate
pure operations, clamping overflow and mapping NaN to zero. The verifier checks
both domains and requires trap metadata only on checked conversions.

These follow [Wasm numeric conversions](https://webassembly.github.io/spec/core/exec/numerics.html#conversions),
not ECMAScript [ToInt32 (currently section 7.1.8)](https://tc39.es/ecma262/multipage/abstract-operations.html#sec-toint32).
The latter wraps to 32 bits and cannot be replaced by a trapping or saturating
conversion. B3's [typed conversion boundary](https://webkit.org/docs/b3/intermediate-representation.html)
is the shared-IR precedent; Cynic's existing Spasm implementations supply the
architecture-specific reference. No new JS coercion or SES surface is exposed.

Checks precede conversion instructions. Signed f64-to-i32 accepts fractions
strictly above -2147483649; the other signed combinations use an inclusive
minimum because their input format cannot represent that extra interval.
Unsigned truncation accepts inputs strictly above -1. AArch64 FCVTZ directly
implements saturation. x86 uses explicit clamps and a split at 2^63 for u64
truncation; u64-to-float preserves the low sticky bit before converting and
doubling the high half. All temporaries avoid allocated GP homes.

AArch64 rounds with FRINT instructions. The x86 path uses SSE2 only: finite
fractional magnitudes fit an exact integer conversion, ties are resolved by
integer parity, and the original sign is restored, including for zero. Already
integral large values and infinities pass through; signaling NaNs are quieted.
There are no helper calls or optional SSE4.1 requirements. Numeric conversions
and rounding are not host-folded, reassociated, or given fast-math identities.

Differentials cover every scalar rounding/conversion opcode, both precisions,
adjacent values at range/exponent boundaries, ties, subnormals, infinities,
NaNs, and seeded arbitrary bit patterns. Direct IR tests exercise all sixteen
optimization/rematerialization combinations with zero/one/four allocated
registers, exact guard captures, discarded trapping results, invalid type
combinations, and allocation failures. Wasm tests retain opcode locations and
decode saturating-conversion sub-opcodes as LEBs.

## Integer operations and traps

The Wasm adapter now lowers the complete scalar integer numeric family for
i32/i64: arithmetic, signed/unsigned division and remainder, bitwise operations,
masked shifts/rotates, zero/leading/trailing/population counts, comparisons,
integer width conversions, and sign-extension operations. Numeric integer/float
conversions are described above and memory accesses below. It also accepts
`unreachable`, including in dead validated code. Unsupported operations such
as reference instructions still refuse even in dead bytecode.

Division and remainder declare `may_trap` effects and require a frontend-owned
`trap_site`; pure operations and guards reject that metadata. A terminal `trap`
needs no result value. `Compiled.runOutcome` returns `trapped: { reason, site }`
separately from normal return and recoverable guard exit. The Wasm frontend uses
the opcode byte offset within the validated function's instruction stream;
the backend does not interpret it. `Compiled.run` translates the reason to
`IntegerDivideByZero`, `IntegerOverflow`, `Unreachable`,
`InvalidConversionToInteger`, or `OutOfBoundsMemoryAccess`. Malformed native
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

## Bounded memory and effects

The backend has scalar little-endian loads/stores of one, two, four, or eight
bytes. Integer loads sign- or zero-extend; narrow stores truncate; f32/f64
accesses preserve raw bits without FP arithmetic. Addresses are i32/i64 byte
indices into frontend-owned `MemoryView` descriptors, not raw JS heap pointers.
The host must keep the descriptors and their backing stores alive and stable
through each span of generated execution. A runtime callback may replace a
descriptor before native execution resumes. Concurrent mutation/resizing is not supported.

Every access checks address-plus-offset overflow and compares against
`length - width`, trapping on subtraction underflow before using that bound.
No access can touch bytes before its check succeeds, including an unaligned access or
a store that straddles the end. Failure returns a structured
`memory_out_of_bounds` trap at the original frontend site; it does not rely on
a host page fault. Memory trap exits restore saved FP state just like other exits.

`Effects` combines reads, writes, trapping, and exits. Loads are reads that
may trap, and stores are writes that may trap. The optimizer retains unused
loads and all stores, and neither folds nor commons them. Region numbers only
select descriptors: different regions may alias. No memory motion, load
elimination, no-alias promise, or atomic/fence semantics is inferred.

The Wasm adapter lowers all 23 scalar load/store opcodes for memory32/memory64,
including explicit multi-memory indices and memory imports. `lowerInstance`
uses an already validated instance; `runInInstance` rebuilds descriptors from
its current stores on every invocation. Host growth or replacement between
invocations therefore updates both base and length without recompilation.
Neither the base nor the length is embedded in generated code. Imported stores
alias when the instance uses the existing `Imports.share_memory` contract; snapshot imports
remain separate copies. Shared memories explicitly refuse compilation and
invocation until their concurrency contract is implemented.

These accesses follow [Wasm memory instruction semantics](https://webassembly.github.io/spec/core/exec/instructions.html#memory-instructions).
They do not implement JS buffer coercion, detachment, witness records, or
shared-memory ordering from ECMA-262
[GetValueFromBuffer / SetValueInBuffer](https://tc39.es/ecma262/multipage/structured-data.html#sec-getvaluefrombuffer)
(sections 25.1.3.16 and 25.1.3.18); those stay frontend responsibilities.
No JS-visible API or SES policy changes.

Direct tests cover width/type validation, overflowing offsets, empty/short
views, sign extension, raw float bits, aliasing across optimizer switches and
register/scratch allocation, guard/budget/trap ordering, and allocation failure.
Wasm tests compare results and backing bytes with Sarcasm and Spasm, require
Spasm entry, and cover real instance growth, imported aliasing, replacement
stores, multi-memory, memory64, loop-carried addresses, partial writes before
later traps, and source trap locations. This is still a developer-only path:
direct `memory.grow` lowering, production resource metering,
and production dispatch are not implemented by this adapter. Growth in a callee
now refreshes descriptors through the runtime-call bridge described below.

The memory increment passes the focused backend tests on native AArch64 and
x86_64 under Rosetta (146 passed, one skipped on each), the full ReleaseSafe
unit/CLI suite, and both architecture demos. The memory-free demo code sizes,
scratch sizes, and emitted load/store counts are unchanged. The production
test262 pass set is also unchanged at 48,653 passing and 1,324 failing fixtures;
that is a non-regression check, not qualification of this experimental path.
Native x86_64 hardware coverage remains a CI gate.

## Runtime calls and root snapshots

`call` is an ordered read/write/trapping safepoint with an explicit scalar
signature, symbolic frontend target, source site, and root-snapshot ID/values.
It supports zero or one scalar result and up to 64 arguments/captures. The
verifier checks all argument/result types and capture availability; optimization
retains even unused or void calls and remaps their inputs and captures.

`runOutcomeWithRuntime` supplies the frontend callback and invocation context.
Generated code stages arguments and captures in bounded scratch, saves live
caller-saved registers, and invokes a C-ABI trampoline with an aligned stack.
The context pointer, native return address, and block budget survive the call.
The trampoline catches Zig errors and returns status; generated code restores
FP state and returns normally, propagating the original error. It never unwinds
an exception through generated frames. Re-entry uses independent invocation
storage and the common native-stack exhaustion guard.

Raw host calls default to the original caller FP controls. A frontend marks
language-execution helpers `.fp_mode = .strict`; the Wasm bridge does so, keeping
nearest-even/gradual-underflow/masked-exception semantics in its callees.
Both modes restore the initial host state at every final exit, even when a
callback changes controls or returns an error. FP state and memory descriptors
occupy separate scratch areas from arguments, captures, and saved registers.

Snapshots are borrowed, read-only values for Cynic's non-moving collector.
The frontend must register all live references, including arguments, in a
`HandleScope` before allocation or JS re-entry; the backend cannot infer roots
from raw integer bits. A regression adapter calls the existing
ECMA-262 [Call](https://tc39.es/ecma262/multipage/abstract-operations.html#sec-call)
machinery, forces GC inside the callee, and checks a capture-only object after
native resumption. This establishes the boundary, not complete Ohaimark call
lowering. Moving-GC relocation is not supported; JS frame maps, exception
handlers, and OSR remain production-integration requirements.

The Wasm frontend lowers scalar direct `call`, including function imports and
cross-instance targets, following the [Core call rules](https://webassembly.github.io/spec/core/exec/instructions.html#exec-call).
Its callback uses existing Sarcasm/Spasm dispatch, then refreshes all caller
memory views before resumption. Callees share a bounded poll allowance across
the invocation, in addition to the caller's native block budget. The bridge
forwards the existing caller or defining-instance execution controller without
mutating either instance. These prototype bounds are not a production fuel
cost model; host callbacks remain trusted and cooperative. Indirect/reference
calls, multi-result signatures, native shared-backend callee linking, and
complete JS/Wasm exception integration remain open.

Local checks cover caller-saved values, duplicate captures, every scalar result
type, void effects, nested entry, stack exhaustion, repeated-call budgets,
callback errors, FP modes, allocation failures, GC during JS callbacks, Wasm
callee growth, and cross-instance controller forwarding. The full AArch64
unit/CLI suite passes (4,129 passed, 303 skipped), as does the focused x86_64
suite under Rosetta (162 passed, one hardware-specific skip). The production
test262 pass set remains byte-identical; this is not production qualification.

## Safety and non-goals

- No JS heap-object dereferences, shared-memory accesses,
  atomics, SIMD, exception handlers, table/global/tag imports, inlining, OSR, or production
  tier-up in this slice.
- Compile-time limits cap input at 64 KiB, decoder/validator workspace at
  8 MiB, function bodies at 16 KiB, blocks at 256, SSA values at 2,048,
  IR nodes (including guards) at 4,096, block arguments/captures at 64, and
  memory views at 64.
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

Scalar traps and bounded memory accesses now have explicit ordering. Before
memory code motion, introduce and verify any stronger alias guarantees; before
concurrent accesses, add atomic/fence semantics. A guard,
budget poll, call, or trap must not disappear or move past an observable
operation merely because its result is unused.

Opaque frontend-owned recovery IDs and captured-value maps now exist. Before
production JS integration, the JS frontend must generate complete roots, frame
recovery, allocation/re-entry, and exception metadata without importing JS
object layouts into the backend. The runtime-call snapshots alone do not prove
that production lowering supplies all of it.

Do not enable fast-math identities or silently reuse Wasm trapping conversions
for JavaScript coercions. Preserve the generated FP entry/exit and callback
contracts when adding production execution paths.

## Structured Wasm control

The Wasm adapter lowers scalar-typed `block`, `loop`, and `if`/`else`, including
type-index signatures with multiple parameters/results; `br`, `br_if`, and
`br_table`; explicit return and branches to the implicit function label; and
typed/untyped scalar `select`. Function entry/results and runtime-call results
retain their existing limits: this is not multi-result function support,
reference/SIMD control support, tail calls, or exception handling.

The [Wasm control instruction rules](https://webassembly.github.io/spec/core/exec/instructions.html#control-instructions)
distinguish loop parameters from block results. Wasmtime's
[Cranelift translator](https://github.com/bytecodealliance/wasmtime/blob/main/crates/cranelift/src/translate/code_translator.rs)
expresses both through block arguments. Cynic uses the same SSA boundary but
reuses its validator's branch side table for destinations, carried arity, and
discard counts. That metadata originated with the
[in-place interpreter design](https://arxiv.org/abs/2205.01183); no second Wasm
validator or machine-code control stack is introduced. ECMA-262/test262 and
SES semantics are unchanged; the direct gates here are Wasm differentials.

Taken branches preserve the stack prefix and carried values, discarding only
the operands between them. Untaken conditional branches preserve all operands.
`else` consumes its validator metadata even after a terminated then arm and
restores the reachability of the enclosing `if`. Dead unsupported signatures
still refuse. The function's implicit label targets a synthetic return, so a
branch to it uses the same carried-value rule as other labels.

`select` evaluates both operands before a branch passes the chosen bits into
a common successor. This preserves eager traps, NaN payloads, and signed zero;
it does not turn `select` into short-circuit evaluation. Branch tables expand
into comparison/branch blocks, with an unsigned i32 index and a default edge.
There is no jump-table performance claim. Expansion is bounded by the existing
256-block/2048-value graph limits and refuses excessive tables normally. Each
dispatch block consumes the developer execution budget, as do loop backedges.

Control tests compare explicit result oracles with Sarcasm, forced native
Spasm entry, and shared native execution under all 16 optimization/rematerialization
combinations at zero/one/four allocated registers. They cover typed merges,
loop parameters, stack discard, branch-table defaults, function-label exits,
dead arms, exact eager-trap locations, raw scalar selection bits, allocation
failures, resource limits, and finite interruption of infinite typed loops.
These are frontend coverage gates, not production rollout qualification.

Local validation for this increment: the full AArch64 ReleaseSafe unit/CLI
suite passed 4,144 tests with 303 skips (all 52 build steps successful); the
x86_64 backend suite under Rosetta passed 177 tests with one skip. The latter
is not native x86_64 hardware qualification. The RSS precheck stayed within
its 512 MiB cap; the full test262 sweep retained 48,653 passing and 1,324
existing failing fixtures, with a byte-identical pass cache. That sweep is a
production non-regression check, not shared-backend conformance coverage.
Both architecture demos retained their existing IR/code-size, scratch,
load/store, and recovery counts. Timings are diagnostic, not a speedup claim.

## Delivery and gates

### Production completion checklist

The active objective is a fully functional shared backend for Cynic's JS and
Wasm execution, not completion of the integer prototype. These gates are still
open; a passing demo or unchanged production test262 run does not close them.

- [ ] Complete scalar numeric types and operations, including strict floating
  point, bit-preserving conversions, and explicit integer/truncation traps.
  Operation coverage, protected native entry, and explicit callback FP modes are
  implemented; production integration and qualification remain below.
- [ ] Model memory, calls, traps, safepoints, and ordered effects in the IR and
  verifier before optimizing them; preserve aliasing, atomics, and trap order.
  Bounded scalar memory, runtime calls, root snapshots, and conservative effects
  are implemented; atomic/fence semantics and complete frontend integration remain.
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
5. **Wider Wasm coverage:** scalar floating point (including rounding and
   conversions), the complete scalar integer family, and bounded scalar memory
   now run natively, with explicit ordered arithmetic/conversion/memory traps.
   Direct scalar calls now bridge through existing runtime dispatch, including
   function imports and callee memory growth. Scalar structured control now
   includes multi-value block parameters/results, branch tables, and selection.
   Continue with function signatures, references/exceptions, indirect/native
   calls, and production integration. Preserve bounds checks,
   memory-growth invalidation, resource metering, and executable ownership.
6. **Rollout decision:** paired warm/cold execution measurements, compilation
   latency, peak compiler allocation, installed code size, refusal/entry
   telemetry, differential fuzzing, and spec-suite gates. No automatic
   default-on graduation or new JS tier follows from finishing the prototype.

The next capability work is the remaining Wasm signature/control/call surface,
production Ohaimark root/frame lowering, and resource-policy integration.
Operand-move
reduction and immediate/compare-branch selection remain measured optimization
work, not substitutes for coverage.
Keep each change independently measurable against disabled variants and
unoptimized references.
Adopt the backend in production only if measurements justify its complexity.
