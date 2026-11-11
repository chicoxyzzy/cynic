# Shared optimizing backend experiment

Status: **opt-in Wasm and narrow JS runtime integration**.
Default Ohaimark still uses its existing backend. Bistromath and Spasm remain
baseline tiers; default tier selection is unchanged. The shared layer establishes
a typed SSA boundary with JS and Wasm consumers, not B3-level optimization or a
demonstrated throughput improvement. Full production qualification remains open.

## Why this boundary

Ohaimark already owns JS feedback, guards, SSA, representation selection,
allocation, and deoptimization. Spasm directly emits from validated Wasm.
Both reuse instruction encoders and executable-memory management. Ohaimark's
default path does not yet use the language-independent IR introduced here;
both frontends can opt in at the Realm boundary described below.

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
  B3's explicit [V128 type](https://github.com/WebKit/WebKit/blob/main/Source/JavaScriptCore/b3/B3Type.h)
  and separate [SIMD operation metadata](https://github.com/WebKit/WebKit/blob/main/Source/JavaScriptCore/b3/B3SIMDValue.h)
  motivate keeping a vector's 128-bit storage independent of its lane
  interpretation. Cynic uses the existing NEON/SSE2 encoders; no Wasm opcode
  or Cell representation enters the shared IR. Arithmetic follows the
  [Wasm vector rules](https://webassembly.github.io/spec/core/exec/instructions.html#vector-instructions).
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
- Cranelift's [instruction result lists](https://docs.rs/cranelift-codegen/latest/cranelift_codegen/ir/dfg/struct.DataFlowGraph.html#method.inst_results)
  and the [Wasm call rules](https://webassembly.github.io/spec/core/exec/instructions.html#exec-call)
  motivate explicit typed result vectors. Calls define all their SSA results
  together; void calls are the empty case, not a fabricated scalar value.
- [Wasmtime's reference-type roots](https://bytecodealliance.org/articles/reference-types-in-wasmtime)
  motivate typed safepoint captures, not scanning arbitrary integers for pointers.
  [JSC's Wasm lowering](https://raw.githubusercontent.com/WebKit/WebKit/main/Source/JavaScriptCore/wasm/WasmOMGIRGenerator.cpp)
  and [V8's table lowering](https://raw.githubusercontent.com/v8/v8/main/src/wasm/turboshaft-graph-interface.cc)
  keep reference representation and instance-relative table access in the Wasm
  frontend. Cynic preserves its existing two-word reference Cells at this boundary.

## First executable slice

The shared code lives in `src/runtime/jit/backend/`; the adapters live in
`src/runtime/wasm/backend_prototype.zig` and
`src/runtime/ohaimark/shared_backend.zig`. The shared layer imports neither
JS values/realms nor Wasm types, bytecode, instances, or Cells.

The subset has i32/i64 and f32/f64 constants, wrapping integer arithmetic,
strict scalar FP arithmetic, comparisons, bitwise operations, explicit width
conversions, ordered guards/traps, block parameters, jumps, conditional branches,
bounded scalar loads/stores, and typed runtime calls. Wasm bulk-memory and table
instructions lower through those calls. Functions and calls support zero to 64
physical 64-bit words through one result-list model; references and vectors use two.
The backend also has native v128 values, full-width memory accesses, bitwise
operations, lane-wise addition, splats, lane access, shuffles, and swizzles.
Integer extension, saturating narrowing, and pairwise widening sums are also
native, as are integer/FP comparisons and Boolean/bitmask reductions.
The Wasm adapter lowers these and scalar-width/widening vector loads;
full instruction coverage remains open as detailed below.
Scalar/reference/vector globals use ordered loads/stores over bounded views.
The Wasm adapter accepts scalar/reference/vector locals and block/loop/if constructs
(including multiple block parameters/results), branches, and selection.
Unsupported instructions or types are an explicit refusal, even in dead
bytecode. Standalone frontend tests do not fall back. The opt-in runtime tier
records pre-entry refusals and falls back, so its tests also assert native entry.

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

## Opt-in Wasm execution

Set `Instance.shared_backend_enabled = true`, or set
`Realm.wasm_shared_backend_enabled = true` before creating JS-facing instances.
The Realm option is inherited by child realms and remains subordinate to
`jit_enabled`. There is no CLI default-on change. At external/runtime function
dispatch the defining instance tries shared code first, then Spasm if enabled,
then Sarcasm. Sarcasm's internal frame-push path is not rerouted, and there is
no OSR or hotness-based tier-up yet.

`wasm/backend_tier.zig` owns a pointer-stable, per-instance cache, including
negative entries for unsupported functions. Compilation refusal can fall back
only before execution. Errors after native entry propagate without replaying
stores or callbacks. Calls use the runtime dispatcher, so an
eligible callee may also use shared code; this is not direct native linking.
Memory descriptors refresh after callees, and foreign exception tags/payloads
retain their defining-instance identity. Exception-handler bodies still refuse.

Controlled compilation uses `native.Options.execution_policy = .controlled`
and `Compiled.runControlledInto`. It polls an optional host controller at entry
and taken backward SSA edges. Every CFG cycle has such an edge; polls run before
entry parameter loads or after edge values are staged, so no allocated register
is live across them. A null controller skips the helper; an unarmed controller's
atomic wake byte is acquire-probed. Errors return normally through the native
status ABI. Poll callbacks must not allocate, collect, re-enter language code,
or retain arguments. They see the caller's FP state; generated code restores
strict controls afterwards and the original host state on every exit.

Realm fuel, sticky termination, and asynchronous wakeups use the existing Wasm
controller. Fuel counts safe-point crossings, not Wasm instructions: synthetic
branch-table blocks can introduce additional backward SSA edges. Controlled
execution has no developer block-budget cap. The bounded standalone API remains
available and rejects controlled code, and vice versa.

This follows the entry/loop polling boundary in
[Wasmtime's epoch interruption](https://docs.wasmtime.dev/api/wasmtime/struct.Config.html#method.epoch_interruption),
while preserving Cynic's existing controller policy. The
[Wasm invocation rules](https://webassembly.github.io/spec/core/exec/modules.html#invocation)
govern calls/start behavior; [V8's baseline/optimizing split](https://v8.dev/blog/liftoff)
supports retaining a fast baseline rather than replacing it with this tier.
ECMA-262/test262 semantics and the SES surface are unchanged.

Persistent cache metadata uses `Instance.shared_backend_allocator` (or the
instance GPA); it never borrows the short-lived `invocation_allocator`.
Realm-backed metadata and transient scratch both use the immediate-free Wasm
quota allocator; executable mappings use the existing memory ledger. The cache owns
its mapping allocator and releases compiled handles before it. Teardown is
idempotent; cache-initialization refusal stays sticky until explicit release.
Result/scratch allocation and stack checks precede native entry; the entry
counter increments only immediately before generated code actually executes.
The stack guard also runs before cache allocation or compilation. Cold compilation
has a non-inlined boundary so optimizer workspace cannot inflate every cached
recursive call frame. Mutable memory descriptors live after the code-visible
slots in the existing invocation scratch allocation, rather than reserving the
maximum descriptor count on every native frame. The Wasm adapter keeps four
initial views locally and uses its invocation allocator for larger sets; both
that allocation and native scratch allocation fail before entry. Tests cover
descriptor isolation at the 64-view limit, allocation-failure cleanup,
exhausted-stack rejection before compilation, and 256 successful recursive calls
on a 2 MiB ReleaseSafe worker stack.

The Wasm suite accepts `--shared-backend --require-shared-backend-entry` and
reports entries, compiled functions, and refusals. It tracks instances before
start execution, including trapping starts, and releases their native caches.
Refusal details distinguish cache creation, frontend lowering, and native
compilation, retaining the error and opcode/subopcode when available. Like
Spasm's existing diagnostics, collection is bounded and allocation-free: 32
distinct keys plus an explicit overflow count, with saturating counters.
Cached refusals count once, not on every fallback invocation. The harness
aggregates across instances and manifests; `--quiet` retains the final
breakdown, while ordinary output also identifies the affected manifests.
Experimental runs cannot overwrite the default results ledger. Per-manifest
score equality plus a positive entry count proves integration/non-regression,
not complete shared-backend opcode coverage: refusals remain visible and the
completion checklist below remains open.

Local verification on 2026-11-10: the 232-manifest Wasm corpus passes
61,051/61,051 assertions with 1,370 skips in interpreter, shared-only, and
shared-plus-Spasm modes on AArch64 and x86_64 under Rosetta. Every manifest's
pass/fail/skip counts match; both native tiers are required to execute in the
combined run. Shared-only mode compiles 3,254 functions and records 2,381
refusals. The AArch64 unit/CLI suite passes 4,179 tests (303 skips); the focused
x86_64 backend suite passes 212 (one hardware-dependent skip). The production
test262 pass set remains byte-identical at 48,653 passes and 1,324 existing
failures. These are integration gates, not default-on or performance approval.

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
the live registers before assigning the results. Spill homes remain stable.
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
Sarcasm. These optimization passes do not by themselves activate a runtime tier.

For the pre-Number-lowering sum-of-squares baseline (ReleaseSafe, macOS;
x86_64 via Rosetta),
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

### Opt-in ordinary function entry

Set `Realm.ohaimark_shared_backend_enabled = true` together with `jit_enabled`
and `ohaimark_enabled`. The shared frontend gets first refusal at the existing
Ohaimark hotness threshold; `ohaimark_threshold_override = 1` forces it for
verification. The option follows child realms. There is no CLI default change.
Refused compilation leaves the existing Ohaimark/Bistromath/Lantern paths
available. A guard exit or runtime error after entry never restarts the call.
Shared compilation, entries, completions, guard exits, safepoint handoffs, and
refusals have separate heap-scoped counters, including child realms.

Run `zig build test262 -- --shared-js-backend --require-shared-js-entry
--pass-list-out=/tmp/shared-js-pass.txt` for forced runtime qualification.
It disables production OSR, prints the shared counters separately from legacy
Ohaimark, and fails if no shared native entry executes or a worker fails. Compare
the explicit pass list with an interpreter run of the same corpus. Experimental
runs cannot write the normal score report or pass cache. Positive entry counts
plus pass-set equality prove integration, not complete opcode coverage.
Both native CI lanes compare the same explicit pass lists with their existing
Atomics `wait`/`notify` and TypedArray `copyWithin/coerced` exclusions. Those
blocking-fixture exclusions do not constitute full-corpus qualification;
`waitAsync` remains in the differential.

Local qualification on 2026-11-11 (`1a5b953e`, merged in #184): full AArch64
interpreter and forced-shared test262 runs have byte-identical pass lists,
48,653 passes and 1,324 existing failures, with no exclusions or watchdog
aborts. Shared code executes 42,259 entries, compiles 6,887 functions, completes
42,143 entries, and recovers 116 guards. It also records 211,456 pre-entry
refusals, so this proves runtime integration, not complete operation coverage.
The single-threaded `language/expressions` memory preflight executes 2,302 shared
entries with no fixture reaching the 8 MiB RSS-delta reporting threshold.
All 38 CI checks pass on that revision, including the native AArch64 and x86_64
shared differential jobs. The 13 focused runtime safety tests pass on AArch64
and x86_64/macOS via Rosetta (19 tests including module roots); those tests,
not the full sweep's zero safepoint handoffs, cover collecting recovery and
fuel/interrupt/hook handoff. Performance and broader production gates stay open.

Each chunk owns a pointer-stable cache containing its native code, typed graph,
and recovery metadata. Compiler temporaries, retained metadata, invocation
scratch, and executable mappings are charged to the heap ceiling. The quota
allocator is shared with Wasm. Mappings reserve a bounded, bytecode-scaled
region per compiled chunk; this is an initial ownership policy, not a tuned
memory/performance result. Chunk teardown frees the native handle before the
mapping and releases all charges. Compile refusal is cached independently of
the existing tiers. Guard exits have their own bounded retry budget.

The runtime adapter writes recovery directly into the active Lantern frame and
its existing register storage. It does not create a detached synthetic frame or
replace `this`, lexical environments, caller continuations, or argument snapshots.
The call ABI can reserve more slots than the bytecode register count for surplus
actual arguments. Entry accepts those frames; recovery clears only bytecode
temporaries and preserves the trailing argument slots.
Taken backward edges carry exact loop-header captures through a non-collecting
runtime poll. Only the no-work path decrements fuel. Pending GC, exhausted fuel,
cooperative interrupts, sticky termination, and host hooks restore that frame
and return the existing `.safe_point` handoff; Lantern then performs its canonical
poll before executing even an immediate header return. Forward header entries
do not consume a loop poll. A separate native entry block permits bytecode loops
whose header is also the first instruction without weakening the shared verifier.

This follows the client-owned exit boundary in
[B3](https://webkit.org/docs/b3/intermediate-representation.html) and the exact
interpreter-state recovery used by [Maglev](https://v8.dev/blog/maglev), preserving
[ECMA-262 execution contexts](https://tc39.es/ecma262/multipage/executable-code-and-execution-contexts.html#sec-execution-contexts).
No test262 or SES policy is relaxed. Native JS heap operations, JS calls, heap
constant roots, exception regions, and shared-backend OSR are not implemented
by this entry path; they remain required production work below. The existing
production tiers continue to handle their supported cases.

### Detached developer API

The Ohaimark adapter reuses its existing bytecode-to-SSA graph, specialization
plan, and pre-operation frame-state records. It handles primitive constants
(including existing pure folds), Number add/subtract/multiply/divide, the
existing relational/strict-equality nodes, Number `ToNumeric`, boolean/Number
truthiness, branches, and loops. Other non-folded nodes, environments, and
exception handlers refuse. The shared frontend deliberately tries guarded
Number operations even with cold inputs; default Ohaimark's feedback policy
is unchanged.

JS tagged values cross the shared boundary as opaque i64 words. Operand-tag
checks precede arithmetic. Int32 pairs retain the checked add/subtract/multiply
path: signed widening to i64 followed by a round-trip through i32 detects
overflow; multiplication also checks for negative zero. Those guards still
recover before the operation. Mixed/double operands instead use strict f64
operations, and division uses f64 even for Int32 operands. This preserves
ECMA-262 §6.1.6.1.4
[Number::multiply](https://tc39.es/ecma262/#sec-numeric-types-number-multiply)
and §6.1.6.1.5 [Number::divide](https://tc39.es/ecma262/#sec-numeric-types-number-divide),
plus §6.1.6.1.7-8 [Number::add/subtract](https://tc39.es/ecma262/#sec-numeric-types-number-add).
Non-Number arithmetic operands exit before any coercion. Lantern performs the
original operation, including user callbacks and abrupt completions.

Number decoding and boxing remain frontend-owned, following B3's typed
[Double/bitcast boundary](https://webkit.org/docs/b3/intermediate-representation.html)
and [Maglev's guarded representations](https://v8.dev/blog/maglev). No JS tag or
coercion rule enters the shared IR. Integer bit selection chooses between an
exact Int32-to-f64 conversion and decoded double bits before reinterpretation.
Every computed NaN is canonicalized exactly like `Value.fromDouble`, preventing
negative/payload NaNs from colliding with heap tags. Signed zero, subnormals,
infinities, and floating overflow retain their Number behavior.

The existing source IR expresses some `>=` and fused `!<=`/`!>=` relations by
inverting integer `<`. The shared frontend instead inverts ordered f64 `>=`
for those nodes, preserving the original relation's false result for NaN.
Truthiness explicitly rejects both zeros and NaN. It does not trust source
Int32 facts after widening `ToNumeric` and arithmetic; Boolean result facts
remain valid. Guards still restore exact pre-operation state and do not call JS.
Remainder, exponentiation, bitwise/unary operations, and other source-IR
coverage gaps remain separate frontend work. The wider path computes both
integer and floating alternatives before selecting a result; its additional
code and scratch costs require measurement, not an assumed speedup.

On the same AArch64 sum-of-squares diagnostic, Number lowering grows optimized
code from 1,788 to 3,920 bytes and per-call scratch from 568 to 640 bytes;
the graph grows from 98 to 307 nodes before optimization (190 afterwards).
All five optimization/allocation variants retain exact Lantern results and the
Int32 loop-overflow recovery. These static costs make conditional fast paths
and better representation selection important follow-up work before rollout.

A `guard` has no SSA result. A zero predicate captures an ordered list of
available values and returns an opaque frontend-owned exit ID. The shared
backend knows nothing about bytecode offsets or JS registers. Ohaimark owns
the ID-to-frame mapping and reconstructs the exact pre-operation accumulator,
live registers, `this`, and bytecode offset. Dead registers become undefined.
The standalone `Program.run` API uses the evaluator's detached `DeoptState` and
synthetic Lantern frame; the opt-in runtime path instead restores the driver's
active frame in place.
The verifier checks capture availability and bounds, including use-before-def;
guards remain ordered effects even when none of their captures are used later.

The current Ohaimark adapter's generated entries neither allocate JS objects nor call JS,
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
The opt-in Ohaimark adapter uses this FP substrate for the guarded Number
operations above. Default Ohaimark specialization and JS coercion behavior
are unchanged.

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
For bounded execution, the graph is checked after optimization: integer-only
graphs, raw float-bit transfers, and graphs whose only FP arithmetic was removed
by DCE receive no extra entry/exit instructions or scratch slots. Controlled
execution always saves FP state so host polls cannot change the native environment
or leak changed controls back to the embedder, including in integer-only code.

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
`unreachable`, including in dead validated code. Unsupported operations still
refuse even in dead bytecode; the supported SIMD subset is described below.

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
later traps, and source trap locations. Resource metering and runtime dispatch
are provided by the opt-in tier. Both direct growth and growth in a callee
refresh descriptors through the runtime-call bridge described below.

The memory increment passes the focused backend tests on native AArch64 and
x86_64 under Rosetta (146 passed, one skipped on each), the full ReleaseSafe
unit/CLI suite, and both architecture demos. The memory-free demo code sizes,
scratch sizes, and emitted load/store counts are unchanged. The production
test262 pass set is also unchanged at 48,653 passing and 1,324 failing fixtures;
that is a non-regression check, not qualification of this experimental path.
Native x86_64 hardware coverage remains a CI gate.

### Ordered atomic memory

The shared IR has sequentially consistent integer loads, stores, add/subtract,
and/or/xor, exchange, strong compare-exchange, and a memory-independent fence.
Accesses use the same bounded, potentially aliased views as ordinary memory.
Widths are 1, 2, 4, or 8 bytes, with i32/i64 operands and zero-extended narrow
results. Stores truncate; compare-exchange compares the low access-width bits
of its expected operand and returns the old value on both success and failure.
There is no implicit success flag or weak/spurious-failure mode.

The verifier checks operand availability/types, region/width, and exact trap
metadata. Compare-exchange's expected value participates in liveness, DCE, and
CSE remapping. Atomic accesses and fences have an explicit ordered effect;
unused loads/results remain observable and no atomic is folded or commoned.
Bounds/overflow checks precede alignment checks. Both the effective byte offset
and host address must be naturally aligned, otherwise execution returns an
`unaligned_atomic` trap with the frontend's site, never an alignment signal.

AArch64 uses acquire/release loads/stores and exclusive retry loops, with full
inner-shareable barriers. Failed comparisons clear the exclusive reservation.
x86_64 uses aligned loads, implicitly locked exchanges for stores, and locked
compare-exchange for RMW/retry loops; a standalone fence emits MFENCE. No host
callback or optional CPU extension implements these operations. Retry scratch
registers cannot clobber allocated values, and all per-invocation storage stays
private when multiple host threads execute the same compiled code.

Prior art: [B3's memory/fence effects](https://webkit.org/docs/b3/intermediate-representation.html#memory-model)
make ordering separate from ordinary aliasing;
[V8's AArch64 atomic lowering](https://github.com/v8/v8/blob/main/src/compiler/backend/arm64/code-generator-arm64.cc)
provides the exclusive-loop precedent. The semantic anchors are
[ECMA-262 section 29](https://tc39.es/ecma262/multipage/memory-model.html) and
[Wasm's atomic instruction rules](https://github.com/WebAssembly/threads/blob/main/proposals/threads/Overview.md#atomic-memory-accesses).
This is backend machinery, not a change to JS Atomics/SES policy or a claim
that Wasm shared-memory validation, wait/notify, concurrent growth, or production
Ohaimark atomic lowering is complete. Views and their descriptors still require
stable lifetimes; racing ordinary accesses is not made safe by this API.

Tests cover every width/operation, narrow comparison and result bits, register
pressure, scratch/allocated and optimized/unoptimized variants, malformed IR,
unaligned host views, address overflow, exact trap/guard order, allocation
failure, assembler-checked encodings, concurrent native/host increments, and
the sequential-consistency store-buffering litmus. Concurrency tests are
regression evidence, not an exhaustive memory-model proof.

### Memory size and growth

The Wasm frontend now lowers `memory.size` and `memory.grow` for non-shared
memory32/memory64, including nonzero and aliased imported memory indices.
`memory.size` reads the current descriptor through the language-neutral
`memory_length` operation, then converts bytes to pages. This is an ordered
read, not a constant or pure expression: CSE must not reuse a pre-growth size.
The verifier requires an existing view and an i64 byte-length result; native
emission loads the descriptor directly without a host call.

`memory.grow` uses the existing typed runtime-call boundary. Its helper reuses
`interpreter.growMemory`, also used by Sarcasm and Spasm: overflow, maximum,
host-cap, or allocation refusal returns the address-width `-1` value without
changing the store. Successful growth zeroes the new range and runs the existing
host-view commit before returning, including zero-page growth. Every descriptor
is then refreshed, since multiple imports can alias the grown memory. A later
trap preserves the growth and never retries the body through another tier.
Realm-backed stores retain their quota allocator and host-view callbacks.

Runtime call targets are opaque 64-bit identifiers. The Wasm frontend partitions
them into a kind and a full u32 index, so helper IDs cannot collide with the
function-index space. This interpretation stays outside the shared backend.

The split follows [V8's size-load / growth-builtin lowering](https://raw.githubusercontent.com/v8/v8/main/src/wasm/turboshaft-graph-interface.cc)
and [JSC's runtime growth helper](https://raw.githubusercontent.com/WebKit/WebKit/main/Source/JavaScriptCore/wasm/WasmOperations.cpp).
The [Core memory instructions](https://webassembly.github.io/spec/core/exec/instructions.html#memory-instructions)
define the old-page-count / failure result; the native helper does not introduce
a JS exception for an ordinary Wasm growth failure. Shared-memory ordering
and broader production qualification remain open.

Tests require native entry for direct growth, force backing-store relocation
through aliased imports, and check memory32/memory64 result widths, ordered
size observations, zero initialization, allocation refusal, Realm quotas, and
no replay after a later trap. The JS integration test checks fixed-buffer
detachment and resizable-buffer identity/extent after a GC checkpoint.

Local verification on 2026-11-10: all 232 Wasm manifests retain identical
pass/fail/skip counts in interpreter, shared-only, and shared-plus-Spasm modes
on AArch64 and x86_64 under Rosetta (61,051 passes, 1,370 skips each).
Shared-only mode compiles 3,328 functions with 2,307 refusals on each
architecture: 74 additional compiled functions and 74 fewer refusals than
the initial tier. The final Debug memory tests pass on both architectures
(55 each). The full production test262 pass set remains byte-identical
(48,653 passes, 1,324 existing failures). ReleaseSafe WPT with GC threshold 1
matches its named baseline (592 passing subtests, 11 known failures, two
existing parse-error files). WPT runs the interpreter reference path; it is
not shared-native qualification. Native x86_64 hardware and rollout/performance
gates remain separate.

### Bulk memory

The frontend lowers non-shared `memory.copy`, `memory.fill`, `memory.init`,
and `data.drop` to ordered void runtime calls. The shared backend receives no
Wasm-specific opcode or instance pointer in its IR. A second memory/segment
index is a typed i32 constant argument; the target namespace retains its full
u32 primary index. Call effects keep writes and drops live even with no result.

Both copy ranges are checked before any write, including zero-length requests.
Aliased imports use the same runtime memory identity, so overlapping copies
choose the correct direction. Mixed memory32/memory64 copies preserve each
address width and use the narrower width for the count. Fill truncates its
value to a byte; init retains i32 source/count operands even for memory64.
Dropped segments become empty and repeated drops remain harmless. Later traps
do not roll back or replay completed writes, growth, or drops.

The common `copyMemory`, `fillMemory`, `initMemory`, and `dropData` helpers
serve Sarcasm and the shared tier; Spasm also reuses init/drop, while retaining
its existing native copy/fill emission. Growth still refreshes descriptors
before a subsequent bulk call. These helpers do not allocate, re-enter JS, or
change the JS API/SES policy. Shared memories remain an explicit refusal.

The [Wasm Core memory instructions](https://webassembly.github.io/spec/core/exec/instructions.html#memory-instructions)
define bounds-before-writes and dropped-segment behavior.
[JSC uses runtime helpers](https://raw.githubusercontent.com/WebKit/WebKit/main/Source/JavaScriptCore/wasm/WasmOperations.cpp)
for bulk operations; [V8 combines upfront checks with helper or inline paths](https://raw.githubusercontent.com/v8/v8/main/src/wasm/turboshaft-graph-interface.cc).
Cynic starts with the existing call boundary; small-copy inlining is separate
measured optimization work, not required to establish instruction coverage.

Tests compare the interpreter, forced Spasm entry, and forced shared entry for
mixed-width and aliased copies, nonzero memory/segment indices, zero-length and
maximum-width operands, bounds failures without partial writes, and segment
lifetime. Void fill/drop effects survive all optimization/rematerialization
combinations with scratch and linear-scan allocation at zero/one/four registers.
The suite also checks data-only modules and growth/write/drop effects before a
later trap without replay.

Local verification on 2026-11-10: the full AArch64 ReleaseSafe unit/CLI suite
passes 4,191 tests with 303 skips (55/55 build steps); x86_64 Debug backend tests
under Rosetta pass 224 with one hardware-dependent skip. Both harness-contract
runs pass 18 tests. All 232 Wasm manifests have identical pass/fail/skip counts
in interpreter, shared-only, and combined shared/Spasm modes on both
architectures: 61,051 passes and 1,370 skips each. Shared-only mode compiles
3,493 functions with 2,142 refusals, 165 additional functions compared with
memory size/growth alone. Native hardware, remaining opcode coverage,
production JS integration, and performance/default-on qualification remain open.
The bounded RSS precheck passes, and the full production test262 pass set stays
byte-identical (48,653 passes, 1,324 existing failures). GC-threshold-1 ReleaseSafe
WPT matches its named baseline (592 passing subtests, 11 known failures, two
existing parse-error files). That WPT run checks the interpreter helpers, not
shared-native JavaScript API qualification.

### Scalar globals

`global.get` and `global.set` lower directly to typed loads/stores for i32,
i64, f32, and f64. Reads retain exact bits, including signed zero and NaN
payloads. Stores preserve the scalar Cell's canonical low 64-bit word, including
zero-extension for i32/f32. These are ordered memory effects: a write, an aliased
import, or a callee update cannot be hidden by CSE or removed as a dead result.
No per-access host call or Wasm-specific shared IR opcode is needed.

The Wasm frontend owns a compact list of referenced global indices alongside
the compiled code. It copies that list out of the temporary lowering arena;
the instance cache owns and releases it with the same quota allocator as other
compiler metadata. At entry, each index binds a view of the instance's actual
global cell, after the linear-memory views. Imported aliases therefore share
storage, while one compiled function can bind different compatible instances
without embedded instance pointers. Callee/growth refreshes preserve both kinds
of view. Only referenced globals consume the existing 64-view budget; exceeding
it is a pre-entry resource refusal, not an unbounded compiler allocation.

The [Wasm variable instructions](https://webassembly.github.io/spec/core/exec/instructions.html#variable-instructions)
define the reads/writes; mutability remains a validator obligation. The
instance-storage model follows [V8's global lowering](https://raw.githubusercontent.com/v8/v8/main/src/compiler/turboshaft/wasm-lowering-reducer.h)
and Cynic's Spasm implementation. Reference globals now use the paired-word
representation below. Vector globals use full-width 16-byte accesses, and
unused imports of any supported type consume no view slots.
No ECMA-262 or SES surface changes.

Tests cover imported aliases, immutable/defined globals, exact scalar bits,
callee updates, graph-to-code binding lifetime, all optimization/allocation
modes, allocation failures, view-budget boundaries, and writes before traps
without fallback replay. A forced-native JS API test changes an imported global
inside a collecting callback. Broader production and rollout gates remain open.

Local verification on 2026-11-10: the full AArch64 ReleaseSafe unit/CLI suite
passes 4,201 tests with 303 skips (55/55 build steps); x86_64 Debug backend tests
under Rosetta pass 234 with one hardware-dependent skip. Both harness-contract
runs pass 18 tests. All 232 Wasm manifests match the interpreter in shared-only
and shared/Spasm modes on both architectures: 61,051 passes, 1,370 skips each.
Shared-only mode compiles 3,570 functions with 2,067 refusals (77 more compiled
and 75 fewer refusals than bulk memory alone). The production test262 pass set
is byte-identical after the RSS precheck: 48,653 passes, 1,324 existing failures.
GC-threshold-1 ReleaseSafe WPT retains its named baseline: 592 passing subtests,
11 known failures, two existing parse-error files. WPT remains an interpreter
reference check; the collecting-callback unit test requires shared-native entry.
Native x86_64 hardware and wasm32 builds remain CI gates, with no performance
or default-on claim.

### References and tables

The Wasm frontend retains logical 128-bit Cells while `backend_abi.zig` maps
each reference to two i64 SSA values: low word followed by high word. Function
references retain their defining-instance pointer; external references retain
JS value bits; null retains all 128 one bits. `exnref` moves opaquely, but
exception instructions still refuse. Scalar values remain single words.
The shared IR, allocator, and emitter do not import Wasm types or GC policy.
The existing 64-word ABI limit therefore admits at most 32 reference arguments
or results. Oversized signatures/edges refuse before entry.

Reference locals, typed selection, block/loop/if edges, parameters/results,
global reads/writes, `ref.null`, `ref.func`, `ref.is_null`, `ref.as_non_null`,
`br_on_null`, and `br_on_non_null` now lower. Branch metadata continues to count
logical values; flattening happens only at SSA edges and call/return boundaries.
Reference globals use two ordered eight-byte accesses to the same Cell view.

`table.get/set/size/grow/fill/copy/init` and `elem.drop` use runtime helpers.
They preserve table32/table64 address widths, imported aliases, overlapping
copies, dropped segments, and bounds-before-mutation. Sarcasm, Spasm, and the
shared tier reuse the same table growth/bulk helpers. Each operation reads the
current backing store, so growth cannot leave a cached table address stale.
`call_indirect` and `call_ref` resolve the full reference, check the existing
runtime signature contract, and dispatch into the defining instance's selected
tier. Null, bounds, and type-mismatch errors return normally. This is runtime
dispatch, not direct shared-native linking. Tail-call dispatch is described below.

These operations follow the [Core instruction rules](https://webassembly.github.io/spec/core/exec/instructions.html).
Table/ref helpers do not collect or re-enter JS. Before language calls, the
frontend captures external-reference pairs from locals and the operand stack;
the callback pins them using `Instance.externref_rooter`. Return values are
pinned before JS result marshalling can allocate. Pinning may fail with OOM,
but must not collect or re-enter; errors after native entry never replay effects
through fallback. Bare embeddings leave this hook unset or supply their own
root lifetime. The Realm hook uses the existing heap-wide outermost-call owner
and releases transient pins on normal and exceptional return.

The same tests exposed a fallback-tier gap: values loaded from a table/global
could lose their persistent root before a collecting callback. Sarcasm and
Spasm now pin external-reference loads, including constructed non-nullable
reference types. Durable registration also recognizes these types, not just
the `externref` shorthand. No ordinary object properties or public globals
are added; ECMA-262/SES policy is unchanged.

Tests require shared entry for paired parameters/results, reference globals,
nullable control, table operations, cross-instance indirect/typed calls, and
all optimization/allocation modes. They cover 64-word limits, allocation
failures, null/bounds/type traps, and no replay after pin failure in all three
tiers. Collecting JS callbacks verify that removed table/global values survive
while on the Wasm stack and become collectible after the outermost return.
This establishes correctness coverage, not a throughput or default-on claim.

Local verification on 2026-11-10: Debug backend tests pass on AArch64 and
x86_64 under Rosetta (250 passed, one hardware-dependent skip each). Both
separate harness-contract runs pass 18 checks. All 55 full AArch64 ReleaseSafe unit/CLI
build steps pass; the final reference-focused ReleaseSafe run passes 22 tests.
The OOM matrix disables in-place arena growth, as the existing Ohaimark test
does, so failure indices remain deterministic across retry layouts.
All 232 Wasm manifests retain identical per-file pass/fail/skip counts across
interpreter, shared-only, and combined shared/Spasm modes on both architectures:
61,051 passes, 1,370 skips. Shared-only mode compiles 4,499 functions with 1,577
refusals, compared with 3,570/2,067 before references; native entries are
182,940 on AArch64 and 177,540 under Rosetta. Native hardware and production
qualification remain CI/rollout gates, not conclusions from translated runs.
After the bounded RSS precheck, the full production test262 pass set remains
byte-identical: 48,653 passes, 1,324 existing failures. ReleaseSafe WPT at GC
threshold 1 retains its named baseline: 592 passing subtests, 11 known failures,
two existing parse-error files. WPT checks the interpreter reference path;
the new collecting-callback tests separately verify interpreter, Spasm, and
shared-native execution, with entry counters for both native tiers.

### Proper tail calls

`return_call`, `return_call_indirect`, and `return_call_ref` lower to a terminal
IR `exit` carrying outgoing physical arguments and an opaque continuation ID.
The shared verifier checks capture availability and the 64-word bound;
optimization and allocation preserve ordered captures, including duplicate
values. Native emission uses the existing side-exit completion and restores FP
state before returning. It does not encode Wasm targets or GC policy in the IR.

The Wasm compiled artifact owns the target descriptors independently of the
temporary graph. After the generated frame returns, the adapter resolves the
target, checks null/table bounds/signature compatibility, and pins outgoing
external references. Indirect host targets must match parameter/result types,
not just arity. Direct calls retain the existing imported-function contract.
Dead caller locals are not added to the tail-call root snapshot; Realm transient
pins still have their existing conservative outermost-call lifetime.

The adapter stages an instance-owned `NativeTailCall`; an iterative dispatcher
shared with Spasm consumes it before invoking the next target. Alternating
shared/Spasm chains therefore do not accumulate native frames. Sarcasm fallback
uses its existing frame-replacement path. Host calls receive separate outgoing
arguments and results. This is a constant-stack tier handoff, not native `jmp`
linking. The large staged payload stays behind non-inlined helpers rather than
inflating ordinary recursive dispatch frames.

The [Core tail-call rules](https://webassembly.github.io/spec/core/exec/instructions.html#exec-return-call)
require discarding the caller before invoking its target.
[V8's implementation notes](https://v8.dev/blog/wasm-tail-call) describe the same
constant-stack requirement and argument-move hazards; B3's
[frontend-owned exits](https://webkit.org/docs/b3/intermediate-representation.html)
motivate keeping the continuation opaque to the shared backend. Cynic reuses
its existing cross-tier trampoline rather than introducing a second unwinder.
ECMA-262/test262 semantics and the SES surface are unchanged.

Native-entry polls retain caller/defining-instance controller precedence,
including through the bounded developer wrapper. Host tail targets poll before
observable effects. Errors never retry the executed caller through fallback;
staged requests and owned captures are released on allocation failure, traps,
cancellation, and normal return. Foreign fallback exceptions retain their tag
and payload. Exception instructions/handlers themselves remain unsupported by
the shared frontend.

Tests cover 10,000-hop direct, indirect, typed, and mixed-tier chains with a
measured native-stack span below 32 KiB; foreign state and table32/table64 traps;
mixed scalar/reference results; 64-word reordered argument/result transfers;
all optimization/allocation modes; metadata and invocation allocation failures;
bounded and production termination; and collecting JS re-entry at GC threshold
1. They require native entry so interpreter fallback cannot hide a refusal.
An initially dormant controller is also woken between tail hops, including a
shared-to-Spasm transition, with a finite backstop if the wake probe is broken.
Locals and operand-stack depth are bounded independently at 64 logical values;
combined physical edge width is checked where a block edge is emitted.

Qualification preserves the per-manifest interpreter baseline on all 232 Wasm
manifests in interpreter, shared-only, and shared/Spasm modes on ARM64 and
x86-64/Rosetta: 61,051 passes and 1,370 skips in each run. Shared-only execution
compiles 4,602 functions (up from 4,499), with 1,518 refusals (down from 1,577)
and 10,901,536 native entries. These are coverage counters, not throughput
measurements. The full production test262 pass set remains byte-identical
(48,653 passes, 1,324 existing failures), and GC-threshold-1 ReleaseSafe WPT
has no named-baseline regressions (592 passes, 11 existing failures, two existing
parse-error files). Native x86-64 hardware and wasm32 remain CI gates; this
does not close the production completion checklist or change the opt-in policy.

## Runtime calls and root snapshots

`call` is an ordered read/write/trapping safepoint with an explicit scalar/vector
signature, symbolic frontend target, source site, and root-snapshot ID/values.
Arguments, results, and captures each fit 64 physical words (two for `v128`). The
verifier checks all argument/result types and capture availability; optimization
retains even unused or void calls and remaps their inputs, outputs, and captures.

`runInto` supplies the frontend callback, invocation context, and caller-owned
result buffer. `runOutcomeWithRuntime` is its checked single-result convenience.
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
`HandleScope` or an embedding-owned pin set before GC-capable allocation or JS
re-entry; the backend cannot infer roots
from raw integer bits. A regression adapter calls the existing
ECMA-262 [Call](https://tc39.es/ecma262/multipage/abstract-operations.html#sec-call)
machinery, forces GC inside the callee, and checks a capture-only object after
native resumption. This establishes the boundary, not complete Ohaimark call
lowering. Moving-GC relocation is not supported; JS frame maps, exception
handlers, and OSR remain production-integration requirements.

The Wasm frontend lowers direct `call`, `call_indirect`, and `call_ref`, including
function imports and cross-instance targets, following the [Core call rules](https://webassembly.github.io/spec/core/exec/instructions.html#exec-call).
Its callback uses existing Sarcasm/Spasm dispatch, then refreshes all caller
memory views before resumption. Callees share a bounded poll allowance across
the invocation, in addition to the caller's native block budget. The bridge
forwards the existing caller or defining-instance execution controller without
mutating either instance. These prototype bounds are not a production fuel
cost model; host callbacks remain trusted and cooperative. Native
shared-backend callee linking and
complete JS/Wasm exception integration remain open.

### Exceptional call edges

`Terminator.invoke` makes both normal and exceptional successors explicit.
It uses the same typed call signature, source site, and safepoint snapshot as
`call`. The verifier checks the exceptional edge before defining call results,
so a handler cannot observe partial or failed results. Both successors may
forward pre-call values; allocation keeps those homes live across the call,
including scalar/vector register banks and spills. CSE/DCE remap and retain
the call, captures, results, and both edge argument lists.

An optional frontend `Runtime.catch_exception(context, request, error)` hook
classifies a failed invoke. Returning true means the frontend has prepared
its exception state and generated code may enter the handler; false propagates
the original error. A classifier error propagates instead. Ordinary calls do
not invoke this hook. The hook receives the same borrowed request and root
snapshot as the call, with no valid result values. It must root captures and
any pending exception before allocation or language re-entry, just as the
call callback must. JS values, Wasm tags/payloads, catch ordering, and
catchability policy remain frontend-owned; the backend does not equate Zig
errors, resource termination, or Wasm traps with language exceptions.

Native code uses status returns, not stack unwinding through generated frames.
Both resumable paths restore strict FP controls and live register homes, but
only the normal path publishes results. Final failures restore the original
host FP state. Handler backedges use the existing execution-controller polls
and block-budget rules. Memory descriptors refreshed by either callback remain
invocation-owned and visible to the successor.

Prior art: Cranelift's
[`try_call`](https://docs.rs/cranelift-codegen/latest/cranelift_codegen/ir/trait.InstBuilder.html#method.try_call)
separates return/exception edges and leaves tag meaning to the embedder;
[B3 terminal patchpoints](https://webkit.org/docs/b3/intermediate-representation.html)
also make custom successor control flow explicit. Cynic uses its existing
status-return runtime boundary instead of adding an unwind ABI. This is the
shared substrate for [Core exception handling](https://webassembly.github.io/spec/core/exec/instructions.html#exception-handling)
and ECMA-262
[14.15.3 TryStatement evaluation](https://tc39.es/ecma262/multipage/ecmascript-language-statements-and-declarations.html#sec-try-statement-runtime-semantics-evaluation),
not their complete frontend implementation. Wasm lowering is described below;
Ohaimark exception/frame integration and production qualification remain open.
No test262 scoring or SES policy changes follow from this IR operation.

The initial runtime-call checks covered caller-saved values, duplicate captures,
every scalar result type, void effects, nested entry, stack exhaustion,
repeated-call budgets,
callback errors, FP modes, allocation failures, GC during JS callbacks, Wasm
callee growth, and cross-instance controller forwarding. At that increment,
the full AArch64 unit/CLI suite passed (4,129 passed, 303 skipped), as did the
focused x86_64 suite under Rosetta (162 passed, one hardware-specific skip).
The production test262 pass set remained byte-identical; this was not
production qualification.

### Wasm exception lowering

The instance-aware frontend now lowers `try_table`, `throw`, and `throw_ref`
through explicit invoke edges. Protected direct, indirect, and typed-reference
calls split at their normal continuation; exceptional continuations carry the
current locals and pre-call stack values into a lexical catch chain. Catch
branches use the validator's branch metadata after restoring the try-entry
stack prefix, excluding block parameters. All four catch forms are supported.
Canonical instance tag identities, not equal signatures or tag indices, select
the first matching clause. A nonmatch continues outward. Proper tail calls
still leave the current frame and its handlers before the callee executes.

The runtime adapter reuses `ExnRecord`, imported tag identities, and the host
exception bridge. Wasm traps, null `throw_ref`, allocation failure, and resource
termination do not enter catch blocks. Caught host calls refresh memory views
before resuming generated code. Scalar, vector, and reference payloads retain
their bits; `_ref` catches and rethrows retain record identity. A direct local
throw uses a temporary record that is freed after a plain catch; an exnref or
an escaping exception materializes it into the instance pool. Both paths clean
up on allocation failure. Materialized records retain the existing
instance-lifetime ownership model; general exception-record reclamation is
still lifecycle work, not claimed complete here.

The Realm root walker now traces pooled records' typed externref payloads and
original JS throw values. This covers records retained in Wasm globals/tables
after an invocation ends, not just transient native snapshots. Tests check
normal/exceptional paths, nested handlers, block parameters and live locals,
cross-instance tags, mixed payloads, host-call growth, proper tail calls,
allocation failures, repeated local catches, full/minor GC, and actual
collecting JS re-entry with an exnref retained between calls. Native entry and
zero refusal assertions prevent interpreter fallback from satisfying them.

Prior art: V8's
[Turboshaft catch chain](https://raw.githubusercontent.com/v8/v8/main/src/wasm/turboshaft-graph-interface.cc)
also makes catch dispatch and tag comparison explicit in the graph. Cynic keeps
that structure but uses status-return helpers and its existing exception
records instead of adding a platform unwind mechanism. The semantic anchor is
[Core control instructions](https://webassembly.github.io/spec/core/exec/instructions.html#control-instructions);
the JS bridge preserves the existing ECMA-262 throw completion and SES policy.

The AArch64 forced-native corpus comparison passes the same 61,051 assertions
with 1,370 skips across 232 manifests. Compiled functions increase from 6,113
to 6,123; all nine exception-related refusals disappear, leaving two
pre-instruction resource limits and one `br_table` resource limit. These remain
executed-corpus counts, not proof of complete accepted-input coverage or a
production rollout decision.

## Safety and non-goals

- No production JS heap-object lowering, frontend shared-memory integration,
  inlining, OSR, or automatic shared-backend tier-up in this slice. The shared
  IR's atomic accesses do not themselves enable a language's shared-memory API.
- Developer module decoding caps input at 64 KiB and decoder/validator workspace
  at 8 MiB. Runtime lowering starts from an already validated instance.
  Shared compilation caps function bodies at 16 KiB, blocks at 256, SSA values at 2,048,
  IR nodes (including guards) at 4,096, argument/result/capture payloads at 64
  physical 64-bit words, and
  linear-memory/global views at 64.
  The JS adapter caps bytecode at 16 KiB and registers at 63. Runtime scratch
  storage is heap-allocated and bounded by those limits; the developer execution
  budget is at most 1,000,000 visits.
- Bounded developer code checks a finite budget at every block entry,
  including loop backedges. Exhaustion returns normally. These block visits
  are a **prototype work limit**, not Realm fuel or Wasm instruction counts.
  Realm execution instead uses the separate controlled policy above, including
  asynchronous interruption; the two entry APIs reject policy mismatches.
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

The Wasm adapter lowers scalar/reference/vector-typed `block`, `loop`, and `if`/`else`,
including type-index signatures with multiple parameters/results; `br`, `br_if`, and
`br_table`; explicit return and branches to the implicit function label; and
typed selection (plus untyped numeric/vector `select`). Function and runtime-call
signatures support void/multiple logical results through width-aware payloads.
Exception handling remains outside this adapter; tail calls use terminal exits.

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

## Void and multiple scalar results

Function signatures and return terminators carry result lists. Calls own typed
lists of SSA definitions rather than using the scalar node-output field. The
verifier rejects mismatched arity/types, duplicate definitions, and captures of
results that do not exist until after the call. Allocation and liveness treat
all call outputs as simultaneous definitions after input use; optimization owns
and remaps every list, including outputs that are unused but belong to an
effectful call. Scalar arithmetic keeps its existing single-output encoding.

`Compiled.runInto` accepts an exact-sized caller-owned `[]u64` result buffer and
returns a completion: normal return, trap, or a side exit with owned captures.
It publishes no result values on errors, traps, budget exhaustion, or side exits.
This does not roll back native stores or callback side effects, including writes
through aliases of the result buffer.
The scalar `run`/`runOutcome` APIs check for exactly one result before native
entry. The Wasm adapter offers `runResultsInInstance` with the same contract;
its scalar `runInInstance` remains a checked convenience.

Normal native returns stage results in the existing 64-word transfer area, also
used for edges and call arguments. Trap/exit metadata remains separate. Runtime
callbacks return `!void` and fill `Request.results`; a bounded temporary C-frame
array keeps those writes separate from borrowed arguments and root snapshots.
Only successful callbacks publish results to transfer storage. Restoring live
registers precedes assignment of every result, with i32/f32 upper bits cleared.
This does not enlarge generated invocation scratch. Caller result buffers may
alias caller argument buffers because argument staging precedes native entry
and result publication follows it.

The Wasm frontend handles void and multi-result entry signatures, explicit
returns and implicit-function-label branches, defined direct calls, and imported
host/cross-instance calls. It validates the complete result signature and
converts the existing runtime's returned Cells to scalar words. Callees use
the runtime dispatcher and its selected tier; this is not direct native
shared-backend callee linking.

Tests cover mixed scalar types, order and duplicates, NaN payloads, 64-result
calls, simultaneous live caller values, discarded outputs, aliasing, allocation
failures, and result-list ownership. Wasm tests include binary decoding and
compare against Sarcasm and forced Spasm entry. Direct call tests exercise both
allocation modes, zero/one/four registers, and all 16 optimization/rematerialization
combinations. These tests establish the result ABI, not production readiness.

Local validation: the full AArch64 ReleaseSafe unit/CLI suite passed 4,159 tests
with 303 skips (52/52 build steps), and the x86_64 backend suite under Rosetta
passed 192 with one skip. The expression-suite RSS precheck stayed within
512 MiB with no reported fixture delta at or above the 8 MiB reporting
threshold. The full test262 sweep retained 48,653 passing and 1,324 existing
failing fixtures with a byte-identical pass cache. Native x86_64 hardware and
production integration remain separate qualification gates. Both architecture
demos retained their IR/code size, scratch use, emitted load/store counts, and
recovery counts; their timings are diagnostic, not a performance claim.

## Delivery and gates

### Vector values and native storage

The language-neutral IR now has a real `v128` type. It occupies two consecutive
64-bit words in invocation storage but remains one SSA value and one entry in a
signature. Constants carry separate low/high words; their CSE keys retain both.
`vector_add` has explicit lane metadata for i8x16, i16x8, i32x4, i64x2, f32x4,
and f64x2. Bitwise AND/OR/XOR operate on all 128 bits without lane metadata.
Integer addition wraps independently in each lane; floating addition uses the
same protected FP environment as scalar arithmetic. No vector constant folding,
fast math, or reassociation is performed.

Allocation uses independent four-register GP and vector banks. Vector homes use
v4-v7 on AArch64 and xmm4-xmm7 on x86-64, with full-width preservation across
runtime calls. Whole-lifetime vector spills reserve two contiguous words;
the verifier checks partial overlap with scalar spills as well as register
class and lifetime overlap. The all-scratch reference layout is width-aware.

Function entry/results, block-edge permutations, guards, terminal exits, runtime
arguments/results, and safepoint snapshots all transport complete vectors.
Type arrays count logical values; payload arrays count words, low word first.
The existing limit remains **64 physical words per transfer**, allowing up to
32 vectors or a mixed signature. It is not silently expanded to 64 vectors.
Runtime callback results remain unpublished on failure, and the scalar-only
`run` convenience API refuses a v128 result rather than truncating it.

Full-width vector loads/stores use the existing ordered bounds checks, with
exactly 16 bytes checked before any access and no alignment promise. Packed
scratch also requires only eight-byte alignment. A shared scratch-addressing
helper handles AArch64 offsets beyond its scalar load/store immediate range;
maximum-sized vector graphs can place invocation metadata past 32 KiB.

Direct tests cover all allocation/optimization switches, every addition lane
shape and bitwise operation, constant/CSE identity, mixed-width cyclic edges,
maximum-width callbacks, nested native re-entry clobbering all allocated vector
registers, guards/exits, unaligned and failing memory accesses, hostile FP
rounding/flush modes, allocation failures, and maximum-sized scratch with
control/memory/callback metadata. These establish the backend storage contract;
frontend integration has its own tests below. Neither closes the production
qualification checklist.

### Wasm vector integration

The opt-in Wasm tier now carries `v128` through parameters, results, zeroed
locals, selections, block transfers, globals, direct/indirect/typed calls,
imports, and proper tail calls. The Cell adapter distinguishes three counts:
logical Wasm values, lowered SSA values, and physical 64-bit words. A vector
is one Wasm value and one SSA value, but two payload words. A reference remains
one Wasm value lowered to two i64 SSA values. Type arrays are allocated to
their exact lowered length; payload limits remain 64 words, including dynamic
call selectors. Vector bits are never included in external-reference snapshots.

`v128.const`, `v128.load/store`, `v128.and/or/xor`, and the six integer/float
lane-wise additions lower directly to the native vector operations above.
Scalar and vector memory decoding share the same memory32/memory64 and
multi-memory immediate handling. Full-width globals use one 16-byte access;
loads/stores keep the existing aliasing and ordered bounds/trap contracts.
SIMD lane access and permutation extend this set as described below.
Unimplemented SIMD operations still refuse before native entry, even in dead code.
Fallback tests use an unsupported operation rather than a now-supported
constant, so their tier-transition assertions remain meaningful.

This follows the Wasm Core [vector type](https://webassembly.github.io/spec/core/syntax/types.html#vector-types)
and [vector instruction](https://webassembly.github.io/spec/core/exec/instructions.html#vector-instructions)
rules: all 128 bits are observable, while lane interpretation belongs to each
operation. [B3's V128 type](https://github.com/WebKit/WebKit/blob/main/Source/JavaScriptCore/b3/B3Type.h)
and [V8's typed Wasm values](https://github.com/v8/v8/blob/main/src/wasm/wasm-value.h)
likewise keep vector data distinct from references. Cynic retains its existing
Cell ABI at tier boundaries rather than importing either engine's frame layout.
No ECMA-262/SES surface or default tier policy changes.

Integration tests require actual shared-backend entry and cover mixed
scalar/reference/vector signatures, 32-vector Wasm calls, selector-inclusive
limits, all allocation/optimization modes, cyclic local transfers, high-word
constants, aliased globals, foreign and host calls (including all three tail
forms), Sarcasm/Spasm/shared callees, reference-root failures without replay,
OOM cleanup, and unaligned/out-of-bounds multi-memory accesses. Arithmetic
differentials preserve exact non-NaN bits and compare arithmetic NaNs by class.

At the initial vector integration, the 232-manifest Wasm corpus retained
61,051 passes and 1,370 skips on AArch64 and x86-64 under Rosetta, with identical
per-manifest results in shared-only and shared-plus-Spasm modes. Shared-only
compiled-function coverage increased from 4,602 to 4,867; refusals fell from
1,518 to 1,257. The mixed-tier run compiled 4,868 functions through the shared
backend. These are coverage counts, not performance claims. Complete SIMD
lowering and both-architecture production qualification remain open.

### SIMD lane access and permutation

`vector_splat`, `vector_extract`, and `vector_replace` carry a lane shape;
extraction/replacement also carry a checked immediate lane index. Floating
lanes transfer raw bits, including signaling NaNs and signed zero. Narrow
integer extraction is unsigned in the IR; the Wasm frontend adds the existing
`sext8`/`sext16` operation for signed extraction. `vector_shuffle` contains
sixteen constant byte selectors in its two immediate words; `vector_swizzle`
uses dynamic byte indices and returns zero for every index above 15. The Wasm
relaxed swizzle selects this same permitted deterministic behavior.

This follows [B3's explicit lane/immediate metadata](https://github.com/WebKit/WebKit/blob/main/Source/JavaScriptCore/b3/B3SIMDValue.h)
and [Cranelift's separate lane, shuffle, and swizzle operations](https://github.com/bytecodealliance/wasmtime/blob/main/cranelift/codegen/meta/src/shared/instructions.rs).
In particular, strict swizzle is not x86 PSHUFB semantics for indices 16-127.
The verifier checks scalar/vector types, lane bounds, selector bounds, and
metadata applicability. CSE keys include the semantic immediates independently
of arity, so two extractions or shuffles differing only in an immediate remain
distinct while unused fields on scalar operations remain irrelevant.

AArch64 emits native DUP, INS, UMOV, and TBL instructions. x86-64 retains the
SSE2 baseline: splats use unpack/shuffle instructions, lane transfers preserve
the untouched bits, constant shuffles use fixed native extracts, and dynamic
swizzles combine packed equality masks. These paths make no interpreter or
runtime helper calls. The SSE2 permutation sequences are larger than native
SSSE3/AVX alternatives; a feature-gated fast path and its measurements remain
optimization work, not a claimed throughput gain.

The Wasm adapter also lowers `v128.load{8,16,32,64}_splat`,
`v128.load{32,64}_zero`, and all lane loads/stores. They compose existing
bounded scalar accesses with the lane operations. Each checks exactly 1, 2,
4, or 8 bytes, retaining the original trap site, offset overflow checks,
memory32/memory64 selection, and multi-memory identity. Zero loads explicitly
zero the remaining bits. Lane stores leave every other memory byte untouched.
Widening loads are covered by the next section. The remaining
arithmetic/conversion SIMD families are still pending; this is not completion
of SIMD or the production checklist.

Direct tests cover every allocation/optimization switch, live GP/vector homes,
both shuffle-mask words in CSE, and malformed IR. Wasm integration tests require
native entry and cover every lane, all 256 swizzle indices, both input vectors
in constant shuffles, exact float bits, and unaligned memory-end accesses with
overflow/OOB traps and no partial stores. No ECMA-262/SES surface or default
tier policy changes.

With lane/permutation lowering, all 232 manifests retain the same per-manifest
results on AArch64 and x86-64/Rosetta, in both shared-only and shared-plus-Spasm
modes: 61,051 passes and 1,370 skips. Shared-only compilation rises from 4,867
to 5,269 functions; refusals fall from 1,257 to 855. Mixed-tier runs compile
5,270 functions through the shared backend. These measure expanded native
coverage, not a performance win or complete SIMD coverage.

### SIMD integer width changes

The IR now has signed/unsigned `vector_extend`, `vector_narrow`, and
`vector_pairwise_add` operations. Extension's lane metadata describes the source
width (8, 16, or 32 bits), and immediate 0/1 selects the low/high input half.
Narrowing's lane metadata describes the destination width (8 or 16 bits);
the two inputs are narrowed and concatenated in operand order. Pairwise sums
extend adjacent 8/16-bit lanes before adding into 16/32-bit results. The verifier
rejects unsupported widths, floating lane metadata, and invalid half selectors;
CSE retains the selected half and signedness.

The signed-source rule for both narrowing variants follows the Wasm
[numeric narrowing definitions](https://webassembly.github.io/spec/core/exec/numerics.html#op-narrow):
unsigned narrowing clamps negative input lanes to zero, rather than treating
their bit patterns as large unsigned inputs. This fits the existing
[B3 SIMD metadata boundary](https://github.com/WebKit/WebKit/blob/main/Source/JavaScriptCore/b3/B3SIMDValue.h)
without importing Wasm opcodes into the shared IR.

AArch64 uses native widening, saturating narrowing, and pairwise-add
instructions. Integer-only narrowing now enables the native FP-state save and
restore path: NEON saturation changes FPSR.QC even without floating-point
operands. Direct native-entry tests caught and now guard preservation of both
clear and already-set caller flags on returns and side exits. SSE2 narrowing
does not change MXCSR and does not pay for that extra state handling.

The x86-64 sequences live in `src/runtime/jit/simd_x86_64.zig`, shared with
Spasm rather than duplicated in two tiers. They retain the SSE2 baseline and
use only documented temporary registers outside the backend's allocated
homes. Unsigned 32-to-16 narrowing clamps negatives, applies a bias, uses
signed packing, then removes the bias; no SSE4.1-only PACKUSDW is assumed.

All six Wasm widening loads compose an exactly eight-byte scalar load with
native extension. They do not read sixteen bytes just because the result is a
vector. Integration tests compare Sarcasm, forced Spasm, and forced shared
native execution across signedness and half-selection boundaries, saturation
limits, pairwise overflow cases, memory32/memory64 and multi-memory selection,
memory-end accesses, offset overflow, original trap sites, and suppressed
post-trap effects. Direct IR tests run every allocation/optimization mode with
live scalar/vector homes. No default policy or JS/SES surface changes.

The 232-manifest corpus remains identical per manifest to the lane-operation
baseline on AArch64 and x86-64: 61,051 passing commands, 1,370 skips, no failures.
Shared-only and mixed-tier runs compile 102 more functions (5,371 and 5,372
respectively), reducing shared-backend refusals from 855 to 753. Spasm-only
runs also match their pre-extraction baselines, including all 6,080 compiled
functions, so shared-tier coverage cannot hide a regression in the extracted
SSE2 sequences. These are native-coverage counts, not throughput measurements.

### SIMD comparisons and reductions

All 48 accepted Wasm vector comparisons and all nine Boolean/bitmask reductions
now lower through the shared backend. Comparisons produce full-width lane masks;
`vector_any_true`, `vector_all_true`, and `vector_bitmask` produce zero-extended
`i32` values. `any_true` has no lane interpretation, while `all_true` tests each
complete integer lane and `bitmask` gathers lane sign bits in lane order.
In particular, `i64x2.all_true` does not require all four 32-bit words to be
nonzero. Scalar reduction results also feed ordinary structured branches.

The IR uses equality/inequality, signed/unsigned integer less-than/less-or-equal,
and ordered FP less-than/less-or-equal operations with existing lane metadata.
The Wasm adapter swaps operands for greater-than/greater-or-equal forms.
It never implements an FP ordered comparison by negating another ordered
comparison, which would turn unordered NaN lanes into true. Equality treats
positive and negative zero as equal, and inequality is true for unordered lanes.
These contracts follow the Wasm
[vector instruction semantics](https://webassembly.github.io/spec/core/exec/instructions.html#vector-instructions)
and [SIMD comparison/reduction definitions](https://github.com/WebAssembly/spec/blob/main/proposals/simd/SIMD.md).
[B3's SIMD values](https://github.com/WebKit/WebKit/blob/main/Source/JavaScriptCore/b3/B3SIMDValue.h)
likewise keep comparisons and reductions as language-neutral operations with
lane metadata. No ECMAScript or SES surface changes are involved.

AArch64 emits native lane comparisons, whole-lane tests, and weighted sign-bit
reductions. The SSE2 comparison/reduction sequences are shared with Spasm in
`jit/simd_x86_64.zig`. Integer 64-bit comparisons use native scalar comparisons
and reconstruct full qword masks without SSE4.1/SSE4.2 instructions; temporary
GP/vector registers stay outside allocated homes. FP comparisons use the
existing native-entry FP-state protection, including subnormal handling and
restoration of exception flags after signaling-NaN comparisons.

Direct tests exercise every allocation/optimization combination, retained
scalar/vector inputs, mixed-lane CSE identities, result types, and invalid lane
metadata. Integration tests compare independent scalar oracles with Sarcasm,
forced Spasm, and forced shared-native entry for every accepted comparison and
reduction, including every sign-bit position, all 128 any-true input bits,
signedness boundaries, whole-qword cases, NaNs, infinities, signed zeros, and
subnormals. Raw installed-entry tests additionally use unusual host FP controls;
the public invocation wrapper cannot conceal a native-entry failure.

The same 232 manifests retain 61,051 passes, 1,370 skips, and no failures on
AArch64 and x86-64, with exact per-manifest agreement in shared-only,
shared-plus-Spasm, and Spasm-only modes. Shared compilation increases by 197
functions to 5,568 (5,569 in mixed-tier runs); refusals fall from 753 to 556.
Spasm-only compilation and entry/refusal counts remain unchanged after the
SSE2 extraction. This measures native coverage, not a throughput improvement
or completion of SIMD.

### SIMD integer arithmetic and masks

The shared frontend now accepts wrapping subtraction/multiplication, signed and
unsigned saturating add/subtract, abs/neg, byte popcount, all integer shifts,
integer min/max, rounded unsigned averages, and the remaining bitwise operations.
Shifts take a scalar `i32` count modulo lane width; abs/neg preserve the signed
minimum through wrapping. Saturation and averages are restricted to 8/16-bit
lanes, min/max to 8/16/32-bit lanes, and multiplication to 16/32/64-bit lanes.
The verifier rejects incompatible lane, count, result, and immediate metadata.

These contracts follow the
[Wasm SIMD integer definitions](https://github.com/WebAssembly/spec/blob/main/proposals/simd/SIMD.md)
and [numeric rules](https://webassembly.github.io/spec/core/exec/numerics.html).
The operation/lane boundary follows
[B3 SIMD values](https://github.com/WebKit/WebKit/blob/main/Source/JavaScriptCore/b3/B3SIMDValue.h).
Bit-select is `b ^ ((a ^ b) & mask)` in existing bitwise IR;
[relaxed lane-select](https://webassembly.github.io/spec/core/exec/numerics.html#op-irelaxed-laneselect)
uses its allowed per-bit profile. No ECMAScript or SES surface changes.

`jit/simd_integer_x86_64.zig` shares SSE2 sequences with Spasm. Qword products use
32-bit partial products, arithmetic qword shifts use sign masks, and byte shifts
mask cross-lane bits without borrowing allocated GP homes. ARM uses NEON, with
scalar lane products for `i64x2.mul`. Saturating NEON operations participate in
native-entry FPSR preservation, including sticky QC and side exits.

Direct tests cover every optimization/allocation mode, live GP/vector homes,
composed selects, and invalid metadata. Independent scalar oracles compare all
new Wasm operations against Sarcasm, forced Spasm, and forced shared-native
entry. Integer products and floating arithmetic/conversions are described below.

All 232 Wasm manifests retain their exact per-manifest results on both native
architectures in shared-only, mixed-tier, and Spasm-only modes: 61,051 passes,
1,370 skips, no failures. The 57 newly supported opcodes add 345 compiled
functions, reaching 5,913 (5,914 in mixed-tier runs), with refusals down from
556 to 211. Spasm-only compilation, entry, and refusal counts are unchanged.
These are coverage measurements, not throughput claims.

### SIMD extended and fixed-point products

All 17 accepted product opcodes now lower natively: signed/unsigned low/high
extended multiplication at 8/16/32-bit source widths, signed i16 pair-dot,
strict/relaxed Q15 multiplication, and relaxed byte-dot with/without an i32
accumulator. Extended products double the source width; their half selector is
part of the CSE key. The i16 dot wraps its i32 sum. Q15 adds the rounding bias,
shifts arithmetically, and saturates, including `INT16_MIN * INT16_MIN`.

The contracts follow the [Wasm SIMD product definitions](https://github.com/WebAssembly/spec/blob/main/proposals/simd/SIMD.md)
and [relaxed dot rules](https://webassembly.github.io/spec/core/exec/numerics.html#op-ivrelaxed-dot).
Cynic keeps its existing relaxed profile: signed byte operands, saturating i16
pair sums, then signed pairwise widening and wrapping i32 accumulation. The
shared IR expresses those exact operations, not an unconstrained relaxed result.

`jit/simd_products_x86_64.zig` is shared with Spasm and needs only SSE2. The byte
dot uses XMM8/XMM9 as extra scratch, preserving the allocated XMM4-XMM7 bank.
ARM emits widening multiplies, pairwise sums, and Q15 instructions. Its Q15 and
saturating dot operations preserve FPSR.QC on native return and side exit.

Direct tests check half-selector CSE, signedness, live GP/vector homes, every
allocation/optimization setting, and invalid metadata. Independent scalar
oracles require entry in both native tiers, including saturation-before-widening
and accumulator overflow. No default-tier or JS/SES surface changes follow.

All 232 corpus manifests retain identical per-file results on AArch64 and
x86_64 in shared-only, mixed-tier, and Spasm-only runs: 61,051 passes,
1,370 skips, no failures. Product lowering adds 20 compiled functions, reaching
5,933 (5,934 in mixed-tier runs), with refusals down from 211 to 191.
Spasm-only compilation, entry, and refusal counts remain unchanged. These
counts measure native coverage, not execution speed or production readiness.

### SIMD floating-point operations

The remaining 50 floating-point SIMD opcodes lower natively: f32/f64 arithmetic,
sign operations, square roots, strict/pseudo/relaxed min/max, four rounding modes,
precision changes, signed/unsigned integer conversions, strict/relaxed saturating
truncation, and relaxed multiply-add. The verifier records the float lane shape
and rejects invalid widths or metadata. CSE keeps the lane interpretation;
scalar constant folding never processes vector payloads.

The contracts follow [Core numeric operations](https://webassembly.github.io/spec/core/exec/numerics.html)
and [Relaxed SIMD](https://github.com/WebAssembly/relaxed-simd/blob/main/proposals/relaxed-simd/Overview.md).
Sign and pseudo-min/max operations preserve selected bits, including signaling
NaNs and signed zero. Arithmetic observes Core's canonical/arithmetic NaN rules.
Relaxed operations retain Cynic's existing deterministic choices: strict min/max
and saturating truncation, plus separate multiply/add rounding (negate the first
operand for nmadd). No optimization fuses those two operations.

As in [B3's SIMD values](https://github.com/WebKit/WebKit/blob/main/Source/JavaScriptCore/b3/B3SIMDValue.h),
operation semantics and lane interpretation are explicit rather than encoded as
frontend-specific helpers. AArch64 uses NEON operations. SSE2 arithmetic and
min/max sequences are shared with Spasm. The shared backend's rounding/conversions
reuse its native scalar emitters, with XMM8/XMM9 preserving the vector input and partial
result. They require no host callbacks, temporary stack storage, SSE4, or AVX.

Direct tests keep all GP/vector homes live across every optimization/allocation
setting. Independent Wasm oracles require actual Spasm/shared entry, preserve
exact bits for sign/pseudo operations, and enforce quiet/canonical NaN rules for
arithmetic. Raw-entry probes cover all host rounding modes, flushing controls,
sticky status, subnormals, conversion boundaries, normal returns, and side exits.
Numerical cancellation cases distinguish the two-rounding multiply-add profile
from fused results. Fallback tests now use exception regions for opcode refusal
and an SSA-size limit for mixed shared/Spasm execution, not a SIMD coverage hole.

All 232 corpus manifests retain identical per-file results on both native
architectures in shared-only, mixed-tier, and Spasm-only runs: 61,051 passes,
1,370 skips, no failures. Floating SIMD adds 168 compiled functions, reaching
6,101 (6,102 in mixed-tier runs), with refusals down from 191 to 23. Spasm-only
compilation, entry, and refusal counts remain unchanged. Those remaining
refusals, production integration, and rollout qualification stay open; these
are coverage results, not performance measurements.

### Refusal audit and imported tags

The post-SIMD audit exposed a blanket `UnsupportedImports` check: importing a
tag rejected every function in that module, even ordinary arithmetic or memory
accesses. Memory collection now ignores tag imports, as it already ignores
function/global/table imports. The [Core module index spaces](https://webassembly.github.io/spec/core/syntax/modules.html#indices)
are separate; tags remain owned by the existing instance machinery. Regression
tests interleave tag and memory imports, compare all three tiers, and verify
that a fallback throw retains the imported tag's identity and payload.

On the 232-manifest corpus, shared compilation increases from 6,101 to 6,113
functions and refusals fall from 23 to 12. All 61,051 assertions still pass,
with 1,370 unchanged skips. The remaining lowering refusals are:

| Cause | Count | Manifests |
|---|---:|---|
| `try_table` (`0x1f`) | 8 | `throw_ref`, `instance`, `throw` |
| `throw` (`0x08`) | 1 | `throw` |
| Pre-instruction resource limits | 2 | `skip-stack-guard-page`, `call` |
| `br_table` resource limit | 1 | `br_table` |

These are executed-corpus counts, not a claim that every accepted function or
instruction has been exercised. No refusal keys overflowed the diagnostic
table. This historical audit preceded the exception lowering described above;
that implementation removes the nine exception refusals and leaves the three
resource-limit refusals. This does not change
ECMA-262/SES policy, the default tier, or the production gates below.

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
  Bounded scalar memory, runtime calls with explicit exceptional edges, root snapshots, and conservative effects
  and native sequentially consistent atomic/fence semantics are implemented;
  complete frontend integration and shared-memory lifecycle qualification remain.
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
2. **Second consumer:** narrow Ohaimark integer lowering,
   explicit guards, and exact recovery now run through the same native backend,
   including opt-in ordinary function entry on the real Lantern frame.
   Unit gates cover intermediate-state and loop recovery, signed zero, integer
   boundaries, unexpected operands, GC during resumed coercion, and allocation
   failures. Shared-codegen heap operations, JS calls, and OSR remain open;
   full forced-entry test262 equality is a qualification gate, not their substitute.
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
   Direct, indirect, and typed-reference calls now bridge through existing runtime
   dispatch, including function imports, direct memory size/growth, bulk memory,
   scalar/reference/vector globals, table operations, and callee growth.
   Scalar/reference/vector structured control includes multi-value block parameters/results,
   branch tables, nullable branches, and selection.
   Function and call signatures support void and multiple logical results.
   Proper tail calls use the tier-neutral terminal-exit handoff described above.
   SIMD constants, full-width and scalar-width vector memory, bitwise operations,
   lane-wise additions, splats, lane access, shuffles, swizzles, integer width
   changes, pairwise widening sums, and widening loads now lower natively.
   Integer/FP comparisons and Boolean/bitmask reductions also lower natively.
   Wrapping/saturating integer arithmetic, shifts, min/max, averages, abs/neg,
   byte popcount, bitwise complements, and strict/relaxed bit selection are supported.
   Extended products, dot products, and strict/relaxed Q15 multiplication also
   lower natively, including relaxed dot accumulation.
   Floating arithmetic, rounding, min/max, conversions, and relaxed multiply-add
   also lower natively. Exception handlers, payloads, and propagation now lower
   through explicit exceptional edges. Continue with shared memory, native linking,
   and production integration. Preserve bounds checks,
   memory-growth invalidation, resource metering, and executable ownership.
6. **Rollout decision:** paired warm/cold execution measurements, compilation
   latency, peak compiler allocation, installed code size, refusal/entry
   telemetry, differential fuzzing, and spec-suite gates. No automatic
   default-on graduation or new JS tier follows from finishing the prototype.

The next capability work is frontend shared-memory integration, production
Ohaimark root/frame lowering, and resource-policy integration.
Operand-move
reduction and immediate/compare-branch selection remain measured optimization
work, not substitutes for coverage.
Keep each change independently measurable against disabled variants and
unoptimized references.
Adopt the backend in production only if measurements justify its complexity.
