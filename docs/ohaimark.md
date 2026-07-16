# Ohaimark optimizing JIT

Status: **ADR accepted; bytecode/feedback/SSA, pure specialization,
representation selection, and logical plus stable-spill physical deopt
metadata, graph/Lantern differential evaluation, and abstract register/spill
allocation plus AArch64 physical frame/edge lowering landed** (2026-07-16).
Verified native frame entry/exit, typed physical moves, folded-value returns,
checked int32 arithmetic/control and strict equality, every fused strict
equality/inequality branch width, and direct Lantern-frame guard exits have also
landed. Guarded own/prototype/synthetic named-property loads now execute through
live typed IC cells. Frame-reconstructing backedge safepoints now poll fuel,
interrupts, hooks, and pending GC work. Chunk-owned executable lifetime and
transactional full-pipeline compilation/installation now ship. Runtime tier-up
now enters ordinary functions behind a realm-local default-off gate; the full
test262 differential remains exact, while broader GC-pressure, fuzz, and
performance gates remain.

Ohaimark is Cynic's T2 method JIT. It consumes finalized Lantern bytecode
and runtime feedback, builds a compact control-flow SSA graph, specializes
that graph under explicit assumptions, and eventually lowers through the
shared `runtime/jit/` assembler substrate. A failed compile or failed runtime
guard returns execution to Lantern; it must never change JavaScript behavior
or abort the host.

## 1. Inputs fixed by Bistromath

The first optimizing-tier checkpoint starts from measured, shipping state:

- `Op.spec()` is the authoritative instruction/operand/control-flow schema.
- `bytecode/liveness.zig` already supplies leaders, normal successors,
  reachability, register live-in/live-out sets, and now explicit exceptional
  edges.
- Property, computed-key, call, and for-in feedback lives in separate typed
  IC tables. Shape pointers are realm-arena-stable; object/function pointers
  are GC-managed and weak-cleared.
- Bistromath proved Lantern-frame identity, compiled continuation re-entry,
  and data-driven IC loads. Its hardened `hasOwnProperty` call benchmark
  improved 49.8%, while the complete main test262 interpreted/JIT pass sets
  stayed identical at 48,653 / 49,977.

This is enough evidence to design T2 around the existing bytecode and cells.
There is no need for an AST optimizer, another profiling format, or an
Ohaimark-specific execution frame.

## 2. Prior art

- **V8 Maglev** builds a CFG SSA graph directly from bytecode with a forward
  abstract-interpreter state, pre-created loop phis, feedback-specialized
  nodes, deopt frame-state metadata, and a deliberately simple allocator.
  That is the closest fit for Cynic's first T2
  ([V8 Maglev](https://v8.dev/blog/maglev)).
- **JavaScriptCore DFG/FTL** specializes from bytecode profiles and inline
  caches, then OSR-exits when speculation fails. It demonstrates the required
  semantic boundary: optimization assumptions are disposable; interpreter
  semantics are not
  ([JSC speculation](https://webkit.org/blog/10308/speculation-in-javascriptcore/),
  [FTL](https://webkit.org/blog/3362/introducing-the-webkit-ftl-jit/)).
- **SpiderMonkey Warp** snapshots bytecode plus relevant IC data on the main
  thread, builds MIR from that immutable snapshot, and reconstructs a Baseline
  Interpreter frame on bailout. Ohaimark follows that ownership split even
  while compilation remains synchronous
  ([optimization pipeline](https://firefox-source-docs.mozilla.org/js/how-we-optimize.html)).
- **Hermes**, QuickJS, XS, and Boa's interpreter-first configurations are
  useful footprint/cold-start controls, but do not supply a runtime T2 model
  that fits Cynic better than Maglev/Warp. Hermes deliberately emphasizes AOT
  optimization and compact bytecode
  ([Hermes](https://github.com/facebook/hermes)).
- **Literature.** Wimmer/Franz linear scan on SSA is the register-allocation
  starting point. Flückiger et al. model speculative assumptions explicitly in
  IR, which is the rule Ohaimark adopts for every removable guard
  ([Correctness of Speculative Optimizations with Dynamic Deoptimization](https://arxiv.org/abs/1711.03050)).

ECMA-262 does not expose execution tiers. Lantern remains the executable
oracle for execution-context and abrupt-completion behavior
([§9.4 execution contexts](https://tc39.es/ecma262/#sec-execution-contexts),
[§6.2.4 completion records](https://tc39.es/ecma262/#sec-completion-record-specification-type)).
The test262 contract is therefore differential: enabling Ohaimark must produce
the exact same pass set as Lantern, just as Bistromath does. No Ohaimark state
is installed on JS-visible objects, so the design does not weaken Cynic's SES
posture or frozen-primordial behavior.

## 3. Accepted design

### 3.1 Immutable feedback snapshot

`runtime/ohaimark/feedback.zig` copies every typed IC table into same-indexed,
immutable arrays. An opcode's IC operand still identifies the corresponding
snapshot entry.

The snapshot may contain:

- arena-stable `Shape*` values;
- slots, inline computed-key bytes, revisions, and guard epochs;
- a classified site mode such as `cold`, `own_data`, `transition`,
  `construct`, or `megamorphic`.

It must not contain GC-managed `JSObject*` or `JSFunction*` values. In
particular it never copies prototype, callee, or for-in snapshot pointers.
Future optimized code that needs one guards through the live typed IC cell,
whose existing weak-clear protocol remains authoritative. This avoids a
second root set and makes a future off-thread compiler possible without
letting GC pointers dangle. The snapshot is still bounded by its realm's
`ShapeTree` lifetime; synchronous compilation holds that lifetime today, and
a future worker must acquire an explicit realm/shape-arena pin.

### 3.2 Linear CFG SSA with block arguments

`runtime/ohaimark/ir.zig` stores blocks, nodes, node inputs, parameters, and
edges in flat arrays. A `ValueId` is a node index. Phi semantics use block
arguments:

1. Run finalized-bytecode liveness.
2. Pre-create one accumulator parameter plus each live-in register parameter
   for every reachable block.
3. Walk blocks once in bytecode order with an abstract accumulator/register
   state.
4. Attach the target block's argument vector to every edge. Each edge records
   whether it is a jump, ordinary fallthrough, taken branch, or branch
   fallthrough; codegen never relies on insertion order.

Because target parameters exist before translation, backward edges require no
repair pass. Unreachable blocks are not translated, so unsupported dead code
does not reject an otherwise eligible function. The initial node set covers
constants, register moves, `add`/`sub`/`mul`, strict equality, less-than,
immediate addition, generic named-property loads, branches, jumps, and
returns. All three displacement widths of the fused strict-equality and
strict-inequality branches canonicalize to one guarded strict-equality value
plus an ordinary truthy/falsy branch.

### 3.3 Pure specialization plan

`runtime/ohaimark/specialize.zig` computes monotone facts over the finished
graph without mutating the graph or runtime. Its compact lattice distinguishes
the primitive categories, int32 from Double, object from function, and the
internal hole value. A linear edge pass merges incoming block-argument facts;
loop phis iterate to a fixed point under a saturating convergence bound.

Each node receives a result type, lowering choice, optional folded immediate,
and optional removable assumption. Int32 arithmetic folds only when the exact
result is representable: overflow stays on a checked Number lowering, and a
sign-negative zero product stays unfolded because the int32 encoding cannot
represent `-0`. Named loads consult their same-index feedback snapshot and
select generic, own-data, prototype-data, or synthetic-accessor lowering.

An assumption contains the live typed-IC index, arena-stable shape pointers,
slot, and revision only. It never captures the GC-managed prototype or
synthetic accessor value; native code validates the copied scalar/shape facts
against the live cell and reads those GC-managed values through it.
Cold and invalidated cells remain generic. A stale or malformed feedback index
rejects the graph instead of indexing unchecked memory.

### 3.4 Representation selection

`runtime/ohaimark/representation.zig` assigns one output representation to
every SSA value and one required representation to every entry in the shared
node-input/edge-argument array. The initial lattice is intentionally only
`tagged` and `int32`; adding Double before a lowering and recovery path needs
it would increase conversion and deopt states without improving executable
coverage.

Int32 constants and successful checked-int32 arithmetic stay unboxed. Generic
arithmetic, comparisons, property loads, branches, and returns consume tagged
values, so an int32 producer records an explicit `box_int32` conversion at
that use. A checked arithmetic input may record `check_int32`, but only on a
node carrying a pre-operation frame state. Folded nodes mark their eliminated
inputs as unused.

Block parameters remain int32 only when specialization proves the exact type
and every incoming edge already produces int32. Selection starts optimistic
and monotonically drops parameters to tagged until loop phis converge. This
rule deliberately forbids a tagged-to-int32 guard on a CFG edge: an edge has
no operation-owned deopt point from which Lantern could safely resume. Tagged
phis instead box int32 incoming values.

The verifier recomputes selection independently and checks node arity and
payload/lowering compatibility, parameter ownership, edge ownership and
argument counts, disjoint complete coverage of the flat input array, producer
bounds, and conversion legality. Corrupt plans or graphs return
`InvalidRepresentation` or `MalformedGraph`; they cannot reach unchecked
slicing or casts.

### 3.5 Register and spill allocation

`runtime/ohaimark/allocation.zig` assigns every materialized SSA value one
ordinary-use location: an abstract general-purpose register, tagged spill,
int32 spill, or rematerializable immediate.
`runtime/ohaimark/allocation_schedule.zig` constructs its live intervals:
scheduling positions follow CFG block order rather than `ValueId` order because
all block parameters are created before any block body. Parameters define in
parallel at block entry; node operands use their values before the node result
is defined; outgoing edge arguments use at block exit.

The deterministic linear scan expires an interval only when its last use is
strictly before the next definition, so an instruction cannot overwrite an
operand register while producing its result. With no free register it spills
the active interval ending farthest in the future only when that is better
than spilling the current value. Constants and folded results never consume a
register or stack slot; code generation rematerializes their `Immediate`.

Tagged and int32 spills occupy separate regions. A spilled value already
carrying a stable deopt home reuses that exact slot. Other spills start after
the stable-home prefix and reuse the lowest slot whose prior interval ended
before the new one starts. A value kept in a register still has its separate
definition-time deopt-home write; ordinary location choice never weakens
recovery metadata.

The allocator verifier recomputes schedule ranges, locations, eviction
choices, and region sizes from the graph. It also checks block/node/edge
ownership, use-after-definition ordering, home representation and uniqueness,
register bounds, and spill bounds. Mutated plans return `InvalidAllocation`;
malformed graphs or homes remain normal compilation errors.

### 3.6 AArch64 physical lowering

`runtime/ohaimark/lowering_aarch64.zig` maps the abstract plan onto one fixed
AAPCS64 convention without emitting code. `x19`-`x22` pin the realm, Lantern
frame, Lantern register-file base, and optimized spill base. Six optimizer
values map to callee-saved `x23`-`x28`. `x9` is reserved exclusively for
parallel-move cycles; `x10` remains available for a future emitter's
stack-to-stack transfer. FP/LR and `x19`-`x28` occupy a 96-byte save area.

The native spill area starts with contiguous 8-byte tagged slots, followed by
contiguous 4-byte int32 slots, then rounds up to the AAPCS64 16-byte alignment.
Physical locations carry byte offsets from `x22`. The first emitter uses direct
scaled loads/stores, so a tagged offset beyond 32,760 or an int32 offset beyond
16,380 returns `FrameTooLarge` and leaves the chunk in lower tiers; widening
address materialization is deferred until a real fixture needs it.

Every CFG edge lowers its block arguments as one parallel assignment.
`runtime/ohaimark/parallel_moves.zig` first emits destinations that no pending
source still needs. A cycle saves its first raw source in `x9`, redirects every
fan-out consumer to that scratch, and preserves any `box_int32` conversion on
the final move. Same-location copies disappear only when no conversion is
attached. Duplicate destinations, scratch aliasing, and edge-level
`check_int32` return normal compiler errors.

The lowering verifier rebuilds the frame, physical value locations, per-edge
stream ranges, and resolved move sequence. This is still non-executable: code
generation must initialize every tagged slot to a non-pointer value before the
first safepoint and must spill or stack-map live tagged registers before any
helper call or GC poll.

### 3.7 Native frame entry and exit

`runtime/ohaimark/emitter_aarch64.zig` is the first machine-code checkpoint.
The prologue saves FP/LR and all ten pinned/value callee-saved registers, sets
FP, reserves the spill area in 4,080-byte-or-smaller aligned chunks, pins the
three-argument entry ABI, and initializes every tagged slot to Cynic's
non-pointer `undefined` bits. The epilogue releases the exact spill size,
restores each pair in reverse order, and returns. Both operations verify the
layout before writing and roll the assembler buffer back on allocation failure.

Golden-word tests pin the convention and immediate chunking. On AArch64, an
executable-memory test enters the generated frame, reads the last initialized
tagged slot through `x22`, restores the native stack, and returns the exact
NaN-boxed bits. Higher-level graph scheduling and guard exits live separately
in `runtime/ohaimark/codegen_aarch64.zig`.

### 3.8 Typed moves and folded returns

The emitter now consumes the resolved physical move stream. Every move carries
explicit source and destination representations, so one shared validator checks
register/stack kind compatibility and permits only identity or int32-to-tagged
boxing. `x10` transfers stack values and `x11` materializes the int32 NaN-box
tag; `x9` remains untouched while it preserves a parallel-move cycle. The
shared encoder gained a golden-tested 32-bit scaled store for raw int32 spills.

Immediate, register, tagged-stack, and int32-stack sources can target registers
or their matching stack region. Move emission is transactional and all offsets
are checked before reaching assertion-bearing encoder APIs. A constant-pool
value is embedded only when it is non-heap; object/string/symbol/BigInt values
return `UnsupportedConstant` until codegen has a rooted pool-load path. Raw GC
pointers never enter code literals.

`emitConstantReturn` connects the first complete graph path: a specialization-
folded `1 + 2` result remains an int32 immediate, the return use boxes it into
`x0`, and native AArch64 returns bits identical to `Value.fromInt32(3)`. The API
rejects every non-immediate producer, so unchecked arithmetic or property nodes
cannot execute before guards and deopt exits exist.

### 3.9 Checked arithmetic, control flow, and guard exits

`runtime/ohaimark/codegen_aarch64.zig` verifies every upstream plan before
emitting the first non-folded graph subset. It materializes used entry
parameters from the production three-argument ABI, binds CFG blocks, applies
the resolved parallel edge streams, and writes every separate stable recovery
home at definition time. Constant branches and dynamic int32 truthiness feed
their own edge streams; checked add/sub use AArch64's signed overflow flag,
while multiply compares the full signed product and separately guards the
ECMAScript negative-zero case.

Each speculative node branches to one cold out-of-line exit. Physical recovery
metadata is decoded while compiling, then emitted as direct tagged/int32 spill
loads, boxing, and stores into the existing Lantern `CallFrame` accumulator and
register file. The exit stamps the pre-operation bytecode offset and returns
the same numeric `resume_interp` result as Bistromath. Runtime bailout performs
no allocation and calls no helper; Lantern executes the failed operation once.
Heap-valued constant-pool recoveries remain a compile-time fallback rather than
embedding an unrooted pointer.

Conditional guards first branch over a near-site trampoline, whose
unconditional branch reaches the cold exit. This keeps the AArch64 `b.cond` /
`cbz` / `tbz` displacement local; verified graph, move-stream, and metadata
caps keep the wider branch in range instead of allowing a fixup cast to trap on
user-sized input.

Native arm64 tests cover successful add/sub/mul, dynamic zero/nonzero control,
add/sub/mul overflow, `-1 * 0` recovery to `-0`, and exact resumed/full-Lantern
result equality. Unsupported generic arithmetic rejects transactionally and
leaves the machine buffer unchanged. At this checkpoint the graph compiler
remained test-only; the backedge safepoint checkpoint follows below.

### 3.10 Live named-property guards

`runtime/ohaimark/property_codegen_aarch64.zig` owns the property-specific
machine sequence, leaving graph scheduling and deopt integration in
`codegen_aarch64.zig`. A specialized site embeds only its chunk-owned live-cell
address and realm-arena-stable shape assumptions. It never embeds the
GC-managed prototype or synthetic-accessor value.

Every hit first proves a plain `JSObject`, then compares the immutable
receiver-shape/slot assumption with the current `LoadICCell` and the receiver's
current shape. Own-data mode additionally requires a data cell with no cached
prototype. Prototype-data and synthetic-accessor modes compare the receiver's
immediate prototype with the live cell pointer, the holder's current shape with
both the cell and the optimizer assumption, and the cell revision with both the
assumption and `Realm.proto_revision_counter`. The mode byte selects either a
live holder-slot read or the live synthetic value. Slot reads cover the inline
array and overflow buffer using the shared JIT layout contract.

Any cold cell, invalidation, receiver/holder shape change, prototype swap,
revision change, or mode change branches to the existing pre-operation guard
exit. Bailout therefore restores the receiver and live registers, stamps the
property bytecode offset, and lets Lantern execute that operation exactly once;
the fast path and exit allocate nothing and call no helper. Native tests install
the code before mutating cells and prototypes, cover inline and overflow slots,
and compare resumed Lantern results. A cold generic load rejects compilation
transactionally until a rooted generic-helper call path exists.

### 3.11 Backedge safepoints and precise root transfer

`runtime/ohaimark/safepoint_codegen_aarch64.zig` polls every taken backedge
after its parallel edge moves have installed the target block parameters. The
no-work path checks incremental mark/sweep phases, allocation-count and byte
pressure, an armed interrupt hook, the shared step budget, and the cooperative
interrupt byte. It decrements the budget exactly once and jumps directly to
the loop header.

Any pending GC/host work branches to a nearby cold exit. The target block's
accumulator parameter and liveness-derived register parameters are the exact
Lantern state at that loop header, so the exit boxes them as needed, writes
them into the existing `CallFrame`, stamps the target bytecode offset, and
returns `resume_interp`. Lantern then performs the collection, hook call,
termination, or cooperative throw with every live tagged value in its normal
precise root set. Optimized code never invokes GC while a pointer exists only
in a machine register or native spill.

Native tests cover the no-work path, zero fuel, a cooperative interrupt, an
armed-but-proceeding hook, and allocation-pressure young collection. The GC
case carries an object only through a loop parameter, proves the cold exit
transfers it to the Lantern register file, and proves a real collection keeps
that object while reclaiming an unrooted peer. Corrupt parameter roles reject
transactionally. The current optimized subset still allocates nothing and
calls no helper; helper-backed nodes remain `UnsupportedNode` until a rooted
call-safepoint policy lands.

### 3.12 Exceptions stay explicit

Liveness exposes protected-range edges as `exception_edges`, separately from
normal successors. An exception edge is not an ordinary branch: the unwinder
defines the handler accumulator, catch register, completion state, and frame
depth. The first graph builder returns `error.UnsupportedExceptionFlow` for a
chunk with handlers. A later phase will add an exceptional environment and
deopt state before enabling those chunks; silently treating handler edges as
normal phis is forbidden.

### 3.13 Fallback is part of correctness

`UnsupportedOp`, `UnsupportedExceptionFlow`, malformed internal bytecode, an
oversized graph, or allocation failure all abandon Ohaimark compilation. Once
tier-up is attempted, the chunk remains executable in Bistromath/Lantern.
These are normal compiler outcomes, never `panic`, `unreachable` on
input-dependent state, or partial optimized execution.

### 3.14 Publication is transactional and chunk-owned

`runtime/ohaimark/compiler.zig` now runs graph construction, specialization,
representation selection, logical/physical deopt planning, allocation,
physical lowering, and machine emission synchronously in temporary allocator
state. Only a completely emitted buffer reaches the shared W^X
`CodeAllocator`; only a successful install reaches `Chunk.JitState.ohaimark`.
Every failure marks T2 alone `dont_compile`, leaving Bistromath and Lantern
untouched. Its realm-facing `compile` entry owns executable-allocator lookup;
the dispatcher does not manipulate code memory directly.

`CodeAllocator.InstalledCode` couples the exact executable slice to its owner.
Publication uses an explicit `take()` transfer, and idempotent `deinit` returns
the slot to the allocator's free list. `Chunk.JitState` keeps independent
Bistromath and Ohaimark records; Bistromath now owns both its main code and its
installed continuation table through the same mechanism. Recursive
`Chunk.deinit` releases all tier code while the realm's heap allocator is still
alive; parent and child realm teardown both complete before the owning heap
unmaps the shared region. No temporary graph/plan pointer survives publication.

### 3.15 Default-off function-entry tiering

`runtime/ohaimark/driver.zig` consults T2 before Bistromath whenever both the
master `Realm.jit_enabled` switch and the separate
`Realm.ohaimark_enabled` rollout gate are true. Cold T2 waits for
`8192 + 32 * bytecode_length` warmth unless the host supplies an override;
the test262 `--ohaimark` posture forces both T1 and T2 thresholds to 1. Child
realms inherit all four tier policy fields, so `$262.createRealm()` and
ShadowRealm do not silently leave a differential run.

Fresh-entry heat is recorded before either tier is selected, including callees
pushed by Bistromath's in-place call driver. T1 therefore keeps accumulating
evidence for T2 instead of freezing the shared counter when baseline code first
publishes. Backedges continue to add warmth in Lantern/T1 independently; this
checkpoint does not perform Ohaimark OSR.

Only fresh ordinary-function frames enter this checkpoint. Constructors,
generators, async Promise-wrapping frames, and Ohaimark OSR stay in the lower
tiers. A cold/refused T2 attempt leaves the frame untouched and permits T1;
an optimized guard exit reports `resumed` separately because it already wrote
the exact bytecode offset, accumulator, and live registers into the Lantern
frame. The shared dispatcher resumes Lantern directly in that case and never
restarts the activation at T1 entry.

### 3.16 Opt-in rollout telemetry

V8 exposes optimizing-tier publication/deoptimization through `--trace-opt` /
`--trace-deopt`; JavaScriptCore keeps VM/tier counters for the same rollout
questions. Cynic uses a smaller aggregate suited to an embedded engine: one
opt-in `OhaimarkStats` lives on the shared heap and records compile attempts,
publications/refusals, compile wall time (total/max), installed code bytes,
generated entries, normal completions, guard exits, the pipeline stage of every
refusal, and the first unsupported bytecode when IR construction is the
boundary. Stage names are append-only diagnostic identifiers; opcode names come
directly from the bytecode `Op` enum. Child realms naturally contribute because
they share the parent heap; independent agent heaps remain independent rather
than introducing cross-thread atomics into the runtime.

Disabled telemetry performs no clock read and no entry-counter mutation. It is
host-only state, never a JS-visible global or object property. The test262
`--ohaimark-stats` flag enables it per fixture, merges snapshots across harness
workers with saturating counters, and prints one main-phase summary plus the top
unsupported opcodes in deterministic count/opcode order. Every compiler pass
stamps its stage before it can fail; the IR builder carries the exact opcode at
its two explicit `UnsupportedOp` exits instead of reparsing bytecode after the
fact. CI pairs that report with the full advisory `--ohaimark` pass-set
differential and runs both T1 and T2 postures in the ReleaseSafe
`--gc-threshold=1` matrix.

The first full forced-tier sample attempted 217,427 compilations, published
6,541 (3.01%), installed 581 KiB (91 bytes per published function), and ran
40,805 generated entries to normal completion with no guard exit. Compilation
consumed 1.642 s in aggregate (7 us per attempt, 8.187 ms max). The exact
48,517-path pass set still matched the non-T2 baseline. This is a rollout
baseline, not a speed claim; the high refusal rate makes supported-surface
coverage the next measurement target before threshold tuning.

The first classified follow-up attempted 218,345 compilations and refused
211,780. IR construction accounted for 209,006 refusals (98.69%); codegen
accounted for the remaining 2,774 (1.31%). `jmp_if_strict_neq8` led the opcode
histogram at 44,069 (20.81% of all refusals), followed by `make_environment` at
38,799 (18.32%) and `lda_global8` at 32,265 (15.24%); together those three
explain 54.36% of every refusal. The forced-T2 and same-tree lower-tier runs
produced the exact same 48,653 sorted pass paths (SHA-256
`10f024349d3467c72112da03dd57e0d7e543cdb819a00b3082dfecedaec614ca`).

The first measured coverage expansion now ships the complete fused
strict-equality/inequality branch family. The strict-equality node implements
the int32 subset of
[§7.2.14 Strict Equality Comparison](https://tc39.es/ecma262/#sec-isstrictlyequal):
both inputs use checked-int32 conversions, and any other representation takes
the node's pre-operation deopt point so Lantern re-executes the original fused
opcode with full ECMAScript semantics. AArch64 emits the tagged boolean result
and the existing branch machinery consumes it; outgoing SSA edges retain the
original accumulator because the fused bytecode does not overwrite it. Native
tests execute equality and inequality across all 8/16/32-bit displacement
encodings and prove a Double pair restores the exact opcode, accumulator, and
registers before Lantern resumes.

The follow-up full run attempted the same 218,345 compilations, published 6,639
and refused 211,706: 74 additional functions reached native T2 code, while the
former 44,069-entry fused-branch refusal disappeared. IR now accounts for
208,980 refusals and codegen for 2,726. The newly exposed leaders are
`lda_global8` at 44,142, `make_environment` at 38,799, and standalone
`strict_neq` at 32,025. The forced-T2 and same-tree lower-tier runs again
produced byte-identical 48,653-path pass sets (SHA-256
`10f024349d3467c72112da03dd57e0d7e543cdb819a00b3082dfecedaec614ca`).

## 4. Deoptimization contract

Every speculative node will carry an explicit assumption and deopt point.
Deopt reconstructs a Lantern `CallFrame`, not a Bistromath-specific frame:

- bytecode continuation offset;
- accumulator location;
- every live register location or recoverable value;
- environment/home-object/`this` state already owned by the frame;
- inlined-frame records once inlining exists.

The first logical metadata checkpoint now ships. During graph construction,
each arithmetic or named-load candidate records its **pre-operation**
accumulator and live registers as SSA values. Resuming at the node's original
bytecode offset therefore lets Lantern execute the failed operation exactly
once. A single reverse-liveness scan per block selects those registers; dead
defined registers do not inflate every guard state.

After specialization, `runtime/ohaimark/deopt.zig` emits points only for
checked-int32 and feedback-specialized named-load lowerings. Its byte stream
embeds constants directly and uses `ValueId` recoveries for non-constant SSA
values. The verifier checks point order and bounds, lowering/assumption
compatibility, same-block/parameter value availability, strictly ordered
in-range register slots, and exact stream decoding. Corrupt metadata returns
`InvalidMetadata` or `MalformedGraph`; it cannot become an unchecked slice or
cast trap.

`runtime/ohaimark/deopt_physical.zig` now turns those logical values into a
conservative first physical policy. Every non-constant SSA value referenced by
any deopt point receives one stable definition-time spill home; values absent
from every frame state receive none. Tagged and int32 homes occupy separate
regions, following Maglev's single split-point design
([V8 Maglev](https://v8.dev/blog/maglev#register-allocation)), so a future stack
walker scans only the tagged region. Repeated recoveries share a home.

The physical translation stream contains tagged-stack, int32-stack, or
immediate recipes. Materializing a tagged slot is a direct `Value` load;
materializing an int32 slot boxes with `Value.fromInt32`; singleton and
constant-pool recipes remain embedded. Every lookup and stream read is
bounds-checked, and the logical and physical formats share one parser
substrate. Tampered homes, region counts, tags, offsets, and spill indices
return `InvalidMetadata` or `InvalidRecovery` without unchecked access or
panicking.

`runtime/ohaimark/evaluator.zig` now provides that pre-codegen proof for the
pure supported subset. It executes constants, block arguments, branches,
loops, folded nodes, checked int32 arithmetic, strict equality, numeric
less-than, and returns while applying the selected per-use conversions. Every
definition writes its required physical home. A failed type/overflow guard
decodes the physical stream, materializes the accumulator and live registers,
and can resume `lantern.runFrames` at the original operation.

The differential tests cover both sides of a checked add after a diamond phi:
the in-range optimized result is bit-identical to a full Lantern run; overflow
reconstructs the pre-add int32 operands, resumes Lantern, and produces the same
double result as a full run. A self-loop test proves the mandatory step limit
returns `StepLimitExceeded` instead of hanging the host. Generic effectful
arithmetic and cold generic named-load execution remain explicit
`UnsupportedNode` boundaries. The evaluator continues to model a specialized
named load as a guard failure; executable tests now cover the native hit and
resumed-Lantern miss paths directly.

The evaluator remains the target-independent oracle. Its first executable
counterpart now emits checked int32 definitions/control and strict equality,
required home stores, direct guard exits that reconstruct the existing Lantern
frame, and live-cell named-property guards. Taken backedges also transfer
loop-header state to Lantern whenever host or GC work is pending. Owned code
survives destruction of every temporary compiler plan, and the default-off
function-entry driver now executes it through normal call dispatch. Production
traffic remains on T1/T0 until the rollout gates pass.

## 5. Delivery order

1. **Front-end substrate, shipped:** exceptional CFG edges, immutable typed-IC
   snapshots, linear block-argument SSA, loop/diamond tests, graceful reject.
2. **Typed specialization, initial pass shipped:** small value lattice,
   fixed-point block-argument facts, IC-to-assumption transpilation,
   semantics-safe int32 folding, explicit lowering choices, and verified
   tagged/int32 representation selection. Local DCE and a measured need for a
   Double representation remain.
3. **Deopt first, logical + physical-home metadata shipped:** pre-operation
   frame-state capture, liveness-compacted logical stream, stable tagged/int32
   spill homes, physical boxing recipes, bounds-checked verifiers, and a bounded
   graph evaluator proving checked success plus overflow recovery against
   Lantern. Native guard exits now ship for the checked-int32 execution subset;
   own/prototype/synthetic property guards use those same exits.
4. **Abstract allocation, shipped:** CFG-scheduled live intervals, bounded
   general-purpose register ids, immediate rematerialization, deterministic
   eviction, representation-partitioned spill reuse, and stable-home reuse.
5. **AArch64 physical planning, shipped:** fixed callee-saved register mapping,
   aligned tagged/int32 frame regions, bounded direct offsets, and deterministic
   cycle-safe parallel edge moves with conversion preservation.
6. **AArch64 frame emission, shipped:** transactional prologue/epilogue,
   chunked aligned stack reservation, pinned ABI setup, safe tagged-slot
   initialization, golden words, and native-hardware execution proof.
7. **Typed moves + folded returns, shipped:** representation-bearing physical
   moves, raw int32 spill stores, boxing, checked offsets, non-heap constant
   rematerialization, and an end-to-end folded graph native return.
8. **AArch64 optimized execution, initial slice shipped:** checked int32
   add/sub/mul, strict equality and all fused strict equality/inequality branch
   widths, int32 control flow, stable-home writes, returns, and direct
   Lantern-frame guard exits, plus live-cell own/prototype/synthetic named loads
   with inline/overflow slot reads. Taken backedges now poll fuel, interrupts,
   hooks, and GC work, transferring exact loop-header state before Lantern
   handles a slow condition. Transactional compilation now publishes an owned
   executable handle only after the full pipeline succeeds; per-tier refusal
   and chunk teardown preserve Bistromath independently. Default-off
   ordinary-function tier-up now ships with exact bailout-vs-fallback routing
   and child-realm policy inheritance; Ohaimark OSR remains deferred.
9. **Gates and tuning:** full test262 pass-set differential, SES suite,
   GC-pressure runs, fuzzing, and compile-time/code-size/performance budgets.
   The current full differential (48,653 passing paths in each posture), SES
   suite, and focused ReleaseSafe `--gc-threshold=1` runs without verifier
   failures are complete. CI now repeats the T2 differential advisory, expands
   the GC matrix across T1/T2, and reports opt-in heap-scoped rollout telemetry;
   broaden fuzz and performance evidence before default-on rollout.
10. **Only if measured:** background compilation, polymorphic feedback,
   inlining, x86_64 lowering, and exception-region compilation.

## 6. Declined for v1

- AST-to-IR compilation: bytecode is already the semantic and profiling unit.
- Sea-of-nodes IR, tracing, or global type inference: unnecessary complexity
  for the low-latency tier Cynic needs first.
- Copying raw GC pointers into optimizer snapshots or machine-code literals.
- Treating exception handlers as ordinary CFG successors.
- Background compilation before synchronous compile cost is measured.
- Deoptless continuation specialization: interesting later, but conventional
  deopt is the smaller correctness surface for the first tier.
