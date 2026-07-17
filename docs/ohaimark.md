# Ohaimark optimizing JIT

Status: **default-on for production CLI ordinary-function entry** (2026-07-17).
The accepted bytecode/feedback/SSA pipeline, pure specialization and
representation plans, verified logical/physical deopt metadata, allocator,
AArch64 lowering, live-cell property guards, backedge safepoints, and
transactional executable ownership now ship. Single-predecessor edge
coalescing, physical next-block fallthrough, a one-word completion ABI, and
exact Int32/Double operand-shape specialization closed the remaining rollout
cost. The graduation 30-pair T2/T1 run measured `0.997x` geometric mean, a
worst fixture of `1.041x`, and 0.8 KiB installed code. Baseline and forced-T2
test262 sweeps produced the same 48,517-pass set and SHA-256; focused
ReleaseSafe GC-pressure runs and bounded crash/value-differential fuzz
campaigns found no verifier failure, host crash, or differential. The
production CLI enables Ohaimark at its natural threshold; `--no-ohaimark`
isolates Bistromath, while `--no-jit` disables both tiers. Loop-header OSR is
implemented behind a realm-local **default-off** gate
(`Realm.ohaimark_osr_enabled`); it does not graduate to default-on until its
own differential, GC/fuzz, and natural-threshold performance gates pass.
Rooted helper calls, broader opcode coverage, and additional architectures
remain future work.

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

`runtime/ohaimark/feedback.zig` copies every typed IC and arithmetic-profile
table into same-indexed, immutable arrays. An opcode's side-table operand still
identifies the corresponding snapshot entry.

The snapshot may contain:

- arena-stable `Shape*` values;
- slots, inline computed-key bytes, revisions, and guard epochs;
- a classified site mode such as `cold`, `own_data`, `transition`,
  `construct`, or `megamorphic`;
- one-byte, pointer-free arithmetic observations: Int32/Int32,
  Double/Int32, Int32/Double, Double/Double, and non-Number. The derived
  optimizer shape is cold, one exact pair, polymorphic Number, or non-Number.

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
constants, register moves, `add`/`sub`/`mul`/`div`, strict equality, logical not,
less-than, immediate addition, generic named-property loads, branches, jumps,
and returns. All three displacement widths of the fused strict-equality and
strict-inequality branches canonicalize to one guarded strict-equality value
plus an ordinary truthy/falsy branch. Standalone strict inequality canonicalizes
to that same guarded equality node followed by a reusable logical-not node.

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
represent `-0`. Division additionally requires a nonzero divisor, an exact
quotient, no `INT_MIN / -1` overflow, and no negative-zero result before it may
remain int32. Unknown tagged division selects the guarded Number lowering only
when its same-index raw-operand profile has observed Number pairs exclusively;
cold, coercive, and mixed sites remain generic. Named loads consult their
same-index feedback snapshot and select generic, own-data, prototype-data, or
synthetic-accessor lowering.

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

Tagged Number division deliberately does not add a persistent Double
representation to this lattice. It consumes tagged operands, bridges Int32 and
Double values through caller-saved FP scratch registers, and immediately
reboxes the result. A Double SSA kind remains deferred until more than one
lowering can keep values unboxed across nodes.

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
AAPCS64 convention without emitting code. The current executable subset is
helper-free, so it preserves its three incoming arguments in volatile
`x0`-`x2` (realm, Lantern frame, register-file base), maps six optimizer values
to `x3`-`x8`, reserves `x9`-`x15` for move/boxing/graph scratch, and uses `x16`
as the spill base. It avoids platform register `x18` and leaves FP/LR plus every
callee-saved `x19`-`x28` untouched. Number arithmetic uses vector `v16`/`v17`,
which do not alias general-purpose `x16`/`x17`.

The native spill area starts with contiguous 8-byte tagged slots, followed by
contiguous 4-byte int32 slots, then rounds up to the AAPCS64 16-byte alignment.
Physical locations carry byte offsets from `x16`. The first emitter uses direct
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
stream ranges, and resolved move sequence. Code generation must initialize
every tagged slot to a non-pointer value before the first safepoint. A future
rooted helper-call lowering must introduce explicit live-register preservation
and stack maps before changing the helper-free ABI; GC polls currently transfer
exact state to Lantern instead of calling.

### 3.7 Native frame entry and exit

`runtime/ohaimark/emitter_aarch64.zig` is the first machine-code checkpoint.
The helper-free prologue leaves incoming argument registers in place, reserves
only the spill area in 4,080-byte-or-smaller aligned chunks, anchors it in
`x16`, and initializes every tagged slot to Cynic's non-pointer `undefined`
bits. A zero-spill graph emits no prologue instruction. The epilogue releases
the exact spill size and returns without touching FP/LR or a callee-saved
register. Both operations verify the layout before writing and roll the
assembler buffer back on allocation failure.

Golden-word tests pin the convention and immediate chunking. On AArch64, an
executable-memory test enters the generated frame, reads the last initialized
tagged slot through `x16`, restores the native stack, and returns the exact
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
ECMAScript negative-zero case. Exact int32 division guards zero and signed zero,
uses non-trapping `sdiv`, and compares the widened quotient/divisor product with
the dividend to reject overflow or a fractional result.

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

### 3.15 Function-entry tiering and independent opt-out

`runtime/ohaimark/driver.zig` consults T2 before Bistromath whenever both the
master `Realm.jit_enabled` switch and the separate
`Realm.ohaimark_enabled` policy are true. Cold T2 waits for
`8192 + 32 * bytecode_length` warmth unless the host supplies an override.
The production CLI now enables both fields by default; `--no-ohaimark` keeps
Bistromath active, and `--no-jit` remains the master opt-out. Direct embedders
constructing `Realm` retain explicit opt-in policy for both native tiers. The
test262 `--ohaimark` posture forces both thresholds to 1, while `--jit`
continues to isolate T1. Child realms inherit all four tier policy fields, so
`$262.createRealm()` and ShadowRealm do not silently leave a selected posture.

Fresh-entry heat is recorded before either tier is selected, including callees
pushed by Bistromath's in-place call driver. T1 therefore keeps accumulating
evidence for T2 instead of freezing the shared counter when baseline code first
publishes. Backedges continue to add warmth in Lantern/T1 independently; when
`Realm.ohaimark_osr_enabled` is set they may also enter published T2 stubs
(§3.17).

Only fresh ordinary-function frames use function-entry T2. Constructors,
generators, and async Promise-wrapping frames stay in the lower tiers. Loop-
header OSR is a separate default-off gate. A cold/refused T2 attempt leaves the
frame untouched and permits T1;
an optimized guard exit reports `resumed` separately because it already wrote
the exact bytecode offset, accumulator, and live registers into the Lantern
frame. The shared dispatcher resumes Lantern directly in that case and never
restarts the activation at T1 entry.

An installed T2 entry gets a four-exit budget. Each function-entry guard exit
saturating-increments `Chunk.JitState.ohaimark_guard_exits`; once the budget is
spent, dispatch bypasses that entry and lets T1/Lantern run directly. The
chunk still owns and frees the generated bytes, and Ohaimark has no
recompilation ladder yet, so this is bounded anti-thrash rather than
jettison/reoptimization. The natural `8192 + 32 * bytecode_length` heat policy
is unchanged after graduation: the measured gate justified enabling the tier,
not changing when a production function becomes eligible.

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
fact. CI pairs that report with the full gating `--ohaimark` pass-set
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

Standalone strict inequality now follows the spec's composition directly:
[Equality Operators evaluation](https://tc39.es/ecma262/#sec-equality-operators-runtime-semantics-evaluation)
computes `IsStrictlyEqual` and negates its Boolean result. The equality node
owns the original `strict_neq` pre-operation frame state, while the synthetic
logical-not node is statically Boolean and needs no second guard. Direct
[`logical_not`](https://tc39.es/ecma262/#sec-logical-not-operator) uses two
lowerings, matching the known-Boolean versus generic distinction in
[V8 Maglev](https://chromium.googlesource.com/v8/v8.git/+/refs/heads/12.0.78/src/maglev/maglev-graph-builder.cc#7249): a proven Boolean flips payload bit
zero directly; an arbitrary tagged input first guards for exactly `false` or
`true` and otherwise resumes Lantern at the original opcode for full §7.1.2
`ToBoolean`. Constants with primitive truthiness known to the planner fold to a
Boolean.

The resulting full run again attempted 218,345 compilations and published
6,644, with 211,701 refusals (208,974 IR; 2,727 codegen). It installed 620 KiB,
ran 43,309 generated entries (41,500 completions and 1,809 guard exits), and
spent 1.833 s compiling in aggregate. Standalone `strict_neq` (previously
32,025 refusals) and `logical_not` (2,541) disappeared from the leading
frontier; `lda_global8` at 44,462, `make_environment` at 38,799, and `div` at
36,894 are now the top three. The forced-T2 and fresh lower-tier pass lists
remain byte-identical at 48,653 paths with the same SHA-256 above.

### 3.17 Frame, environment, and global loads

The optimizer now distinguishes environment allocation from environment access
with a shared post-bytecode analysis in `bytecode/environment_elision.zig`.
Both JIT tiers may erase `make_environment` only when every allocation in the
chunk has zero slots and the same chunk performs no environment read or write.
An `lda_env` without a local allocation is still valid: it reads an inherited
environment from the existing `CallFrame`, so Ohaimark walks and null-checks the
live parent chain rather than manufacturing optimizer state. This preserves the
environment-record and `GetThisBinding` boundaries in
[§9.1.1](https://tc39.es/ecma262/#sec-environment-records) and
[§9.1.1.3.4](https://tc39.es/ecma262/#sec-getthisbinding). Malformed bytecode,
nonzero allocations, and mixed allocation/access chunks reject normally.

`lda_this` reads the executing Lantern frame after validating constructor state.
Named global loads follow the same live-cell discipline as property loads: the
feedback snapshot retains only arena-stable shape and scalar facts, while native
code selects `frame.running_realm`, validates the live target, shape, slot, mode,
prototype state, and declaration revision, then reads the current slot. Global
lexical loads check the live declaration-slot length before indexing its live
pointer. This keeps realm switching and global declaration invalidation faithful
to the Global Environment Record in
[§9.1.1.4](https://tc39.es/ecma262/#sec-global-environment-records) without
embedding a GC-managed object in optimizer metadata.

Every miss uses the original operation's pre-operation deopt point. Native tests
cover `this`, inherited environment depth, named globals, `or_undefined`, global
lexical slots, declaration-revision invalidation, null environments, and a frame
whose running realm changes after code installation. The miss path reconstructs
the frame and lets Lantern execute the operation exactly once; cold global ICs
still reject transactionally because Ohaimark has no rooted generic-helper call
path yet.

The full forced-T2 sweep still attempted 218,345 compilations, published 6,896
(+252), refused 211,449, and installed 670 KiB. It entered generated code 144,498
times, completed 141,919 times, and took 2,579 guard exits; aggregate compilation
cost was 2.043 s. `lda_global8` disappeared from the leading unsupported list and
`make_environment` fell from 38,799 to 21,163 refusals. IR refusals fell from
208,974 to 205,322, while codegen refusals rose from 2,727 to 6,125 because cold
global sites now reach the transactional generic-load boundary. Forced T2 and a
fresh lower-tier run retained byte-identical 48,653-path pass lists (SHA-256
`10f024349d3467c72112da03dd57e0d7e543cdb819a00b3082dfecedaec614ca`).

### 3.18 Exact-int32 and tagged-Number division

Division follows
[§6.1.6.1.5 Number::divide](https://tc39.es/ecma262/#sec-numeric-types-number-divide),
including fractional results, infinities, signed zero, and NaN. The split
matches the established optimizing-engine shape: V8 Maglev separates
`Int32DivideWithOverflow` from `Float64Divide`
([Maglev IR](https://chromium.googlesource.com/v8/v8/+/refs/heads/main/src/maglev/maglev-ir.h));
JavaScriptCore DFG uses a fallible integer `sdiv` path beside `DoubleRep`
([DFG speculative JIT](https://github.com/WebKit/WebKit/blob/main/Source/JavaScriptCore/dfg/DFGSpeculativeJIT.cpp));
and SpiderMonkey's `MDiv` carries fallible int32 and Double specializations
([MIR](https://searchfox.org/mozilla-central/source/js/src/jit/MIR.h)).

Ohaimark folds an int32 division only when the quotient is exact and remains a
representable non-negative-zero int32. A dynamic statically-int32 node uses the
same checked conditions in the evaluator and AArch64 emitter. A tagged node
guards both operands as Int32 or Double, converts them into caller-saved
`v16`/`v17`, executes `fdiv`, and re-applies Cynic's NaN-box Double offset before
the result becomes visible. This path calls no helper, allocates nothing, and
does not introduce a Double spill class. Non-Number coercion and BigInt cases
resume Lantern from the pre-operation frame state. A NaN result also resumes
Lantern so `Value.fromDouble` remains the sole canonical-NaN authority.

The exact-int32 implementation alone moved approximately 36,875 `div` sites
from IR refusal to codegen refusal but published no additional function: the
corpus sites arrived as tagged entry values. The guarded tagged path retained
218,345 compile attempts and converted 32,053 of those codegen refusals into
publications: 38,949 published, 179,396 refused (168,447 IR, 2 allocation,
10,947 codegen), with 48,710 KiB installed. It entered generated code 1,839,963
times, completed 553,362 times, and took 1,286,601 guard exits (69.93%) under
the deliberately hostile threshold-1 test262 posture. Aggregate compilation
cost was 10.379 s (47 us average, 82.682 ms maximum).

The forced-T2 and fresh lower-tier pass lists remained byte-identical at 48,653
paths with SHA-256
`10f024349d3467c72112da03dd57e0d7e543cdb819a00b3082dfecedaec614ca`.
The publication gain is therefore executable-coverage evidence, not a speed
claim. The high guard rate and code footprint make operand-type feedback plus
threshold tuning prerequisites for default-on T2; broadening more tagged
arithmetic before that measurement would repeat the same avoidable exits.

### 3.19 Binary operand profiles and bounded T2 exits

Optimizing engines make arithmetic decisions from site feedback rather than
from an unconstrained entry value. V8 Maglev consumes a per-site
`BinaryOperationHint` and treats missing feedback as insufficient
([Maglev graph builder](https://chromium.googlesource.com/v8/v8/+/refs/heads/main/src/maglev/maglev-graph-builder.cc));
JavaScriptCore carries bytecode `ValueProfile`s into its optimizing tiers
([ValueProfile.h](https://github.com/WebKit/WebKit/blob/main/Source/JavaScriptCore/bytecode/ValueProfile.h));
and SpiderMonkey lets Baseline IC state progress from specialized toward
megamorphic/generic instead of retrying one shape forever
([ICState.h](https://searchfox.org/mozilla-central/source/js/src/jit/ICState.h)).
Cynic now applies the same bounded principle without exposing engine state on
a JS object.

Each profiled `mul` or `div` bytecode is `[op][lhs:u8][profile:u16]`. Its indexed
`BinaryTypeProfile` is one byte in the chunk: monotonic bits record an
Int32/Int32 pair, another Number pair, and a pair containing a non-Number. The
derived modes distinguish cold, numeric-only, coercive-only, and mixed sites.
Lantern records the raw operands before §6.1.6.1.4/.5 coercion, so `"6" * 2`
or `"6" / 2`
cannot train a Number guard merely because its result is numeric. A fused
Number fast path performs that classification and the operation in one tag
walk; only coercion and BigInt fall through to `numericBinary`.

The deliberately hostile threshold-1 test262 posture compiles at function
entry before the body has supplied one observation. Cold tagged division now
stays generic and refuses transactionally; exact constants and statically
int32 graphs remain eligible, while natural-threshold functions accumulate
thousands of Lantern observations before T2 asks. Together with the four-exit
budget, this changed the full forced-T2 report from 38,949 publications,
48,710 KiB installed, and 1,286,601/1,839,963 guard exits (69.93%) to 6,896
publications, 670 KiB installed, and 106/141,632 exits (0.07%). The clean run
attempted 218,345 compilations, refused 211,449 (168,447 IR, 2 allocation,
43,000 codegen), and spent 4.055 s compiling (18 us average, 65.697 ms max).

The fresh lower-tier and forced-T2 sweeps retained the same 48,653 sorted pass
paths, SHA-256
`10f024349d3467c72112da03dd57e0d7e543cdb819a00b3082dfecedaec614ca`.
ReleaseSafe `--gc-threshold=1` over `language/expressions/division` retained
44 pass / 1 known strict-only failure with zero T2 exits. An interleaved
40-pair Darwin arm64 `--no-jit` A/B against the pre-profile commit measured
the new `div_loop` at 46.13 ms versus 63.09 ms (`0.727x`, 12.3% ratio spread);
the fused Number path more than repays profile recording, while `arith_loop`
stayed flat at `1.003x`.

### 3.20 Profile-gated tagged-Number multiplication

Multiplication follows
[§6.1.6.1.4 Number::multiply](https://tc39.es/ecma262/#sec-numeric-types-number-multiply),
including overflow promotion, infinities, signed zero, and NaN. Its lowering
reuses the engine shape surveyed for division: V8 Maglev separates checked
int32 multiplication from Float64 multiplication in its
[Maglev IR](https://chromium.googlesource.com/v8/v8/+/refs/heads/main/src/maglev/maglev-ir.h),
JSC DFG selects integer or `DoubleRep` multiplication in the
[speculative JIT](https://github.com/WebKit/WebKit/blob/main/Source/JavaScriptCore/dfg/DFGSpeculativeJIT.cpp),
and SpiderMonkey's
[MIR](https://searchfox.org/mozilla-central/source/js/src/jit/MIR.h) gives
`MMul` fallible int32 and Double specializations.

`mul` now uses the same one-byte raw-operand profile and three-byte operand
layout as `div`. Lantern classifies and executes the Number case in one tag
walk while preserving its established representation contract: an exact,
non-negative-zero int32 product remains Int32; overflow, `-0`, and mixed
Int32/Double products become Double. Coercion and BigInt still run through
`numericBinary` after their raw pair is recorded.

Ohaimark's distinct `number_mul` lowering is selected only for Number-only
feedback. It consumes tagged Int32/Double inputs, converts through the same
caller-saved FP scratch registers as division, emits AArch64 `fmul`, and
immediately reboxes the result. NaN and non-Number operands deopt from the
pre-operation frame state so Lantern remains the canonical-NaN and coercion
authority. Representation, logical/physical deopt, evaluator, and native tests
cover finite products, widened int32 products, infinities, negative zero, NaN,
and string coercion.

The hostile threshold-1 full corpus cannot consume body feedback before its
first compile attempt, so its telemetry intentionally stayed at 6,896
publications, 670 KiB installed, and 106/141,632 guard exits (0.07%). A
natural-threshold integration test instead trains three Number pairs before
publication, then completes two calls in generated code with no T1 compile or
guard exit. Lower-tier and forced-T2 sweeps retained the same 48,653 sorted
paths and SHA-256
`10f024349d3467c72112da03dd57e0d7e543cdb819a00b3082dfecedaec614ca`.
ReleaseSafe `--gc-threshold=1` over `language/expressions/multiplication`
retained 39 passes plus the one known strict-only failure; forced T2 completed
six native entries with no exits. A focused 200-pair Darwin arm64 no-JIT A/B
measured `mul_loop` at 44.92 ms versus 44.38 ms (`1.012x` median), but the
81.8% max/min ratio spread permits only the conclusion that no large Lantern
regression was observed.

### 3.21 Natural-threshold rollout benchmark

The initial rollout exposed the realm-local gate as top-level `--ohaimark`;
after graduation that spelling remains an explicit no-op, `--no-ohaimark`
isolates T1, and `--no-jit` remains the master opt-out. `cynic run
--ohaimark-stats file.js` writes one versioned, fail-closed machine record to
stderr. Its parser rejects unknown, duplicate, missing, or internally
inconsistent fields, so benchmark automation cannot silently consume a changed
telemetry schema.

`zig build bench -- --ohaimark-rollout` compares T1 against T1+T2 in the same
ReleaseFast binary at natural thresholds. It alternates process order within
each pair, includes synchronous compile time in T2 samples, and obtains
telemetry from a separate probe. Existing single-entry loop micros correctly
produce no T2 attempt because this checkpoint has no OSR. A dedicated suite
therefore drives roughly five million entries through small numeric, property,
and branch leaves plus one intentionally unsupported call wrapper.

The first 30-pair Darwin arm64 run measured:

| Fixture | Median T2/T1 | Ratio IQR | Publication result |
|---|---:|---:|---|
| `number_mul` | `0.940x` | 41.1% | 1 published, 0 exits |
| `number_div` | `1.037x` | 23.4% | 1 published, 0 exits |
| `named_load` | `1.123x` | 18.9% | 1 published, 0 exits |
| `branch_eq` | `1.121x` | 18.2% | 1 published, 0 exits |
| `call_refusal` | `0.956x` | 21.7% | numeric leaf published; call wrapper refused |

The geometric mean was `1.032x`. Across the five telemetry probes Ohaimark
attempted six compilations, published five, refused one, installed 1.7 KiB,
spent 0.254 ms compiling, and completed all 24,997,383 generated entries with
zero guard exit. A preceding independent 10-pair run also put `named_load` and
`branch_eq` more than 10% behind T1, so those regressions are not inferred from
one outlier even though this shared-host sample remains noisy.

Correctness, speculation stability, code size, and compile latency all pass
this checkpoint; throughput does not. The >5% per-fixture rule in `jit.md` §10
keeps Ohaimark default-off. This made the unconditional x19-x28 save/restore
sequence the first measured tuning target before broader opcode coverage or
threshold changes.

### 3.22 Helper-free volatile-register ABI

The follow-up applies the platform convention rather than inventing a private
one. AAPCS64 classifies `x0`-`x17` as caller-saved (`x16`/`x17` are IP0/IP1),
`x18` as platform-specific, and `x19`-`x29` as callee-saved
([Arm AAPCS64](https://github.com/ARM-software/abi-aa/blob/main/aapcs64/aapcs64.rst)).
Ohaimark makes no helper call, so preserving ten callee-saved registers and
FP/LR on every entry paid for a capability it could not use. V8 Maglev likewise
saves a snapshot's live registers around an actual call/safepoint rather than
unconditionally for helper-free code
([Maglev assembler](https://chromium.googlesource.com/v8/v8/+/d8fd81812d5a4c5c3449673b6a803279c4bdb2f2/src/maglev/maglev-assembler.h)).

The lowering contract now marks helper calls unsupported, keeps the realm,
Lantern frame, and Lantern register-file pointers in incoming `x0`-`x2`, maps
the allocator to `x3`-`x8`, keeps existing scratch in `x9`-`x15`, and anchors
spills in `x16`. The prologue contains only optional aligned spill reservation,
spill-base setup, and tagged-home initialization; a zero-spill graph starts at
its first body instruction. The epilogue releases optional spills and returns.
Adding a generated helper call now explicitly requires a call-aware ABI plus
rooted live-register preservation; it cannot quietly invalidate this layout.

Golden tests cover the zero-spill and chunked-spill instruction streams.
Native tests execute typed moves and every graph path under the new mapping,
including Number arithmetic (`v16`/`v17` are a separate register file), exact
guard exits, own/prototype/synthetic property loads, globals/environments, fuel
and interrupt polls, and a GC safepoint with a live tagged root. The full
Ohaimark Debug bucket retained 92/92 passes; the complete ReleaseSafe suite
retained 3,244 passes with 260 intentional skips.

The repeated 30-pair Darwin arm64 rollout measured:

| Fixture | Median T2/T1 | Ratio IQR | Publication result |
|---|---:|---:|---|
| `number_mul` | `0.980x` | 8.1% | 1 published, 0 exits |
| `number_div` | `1.067x` | 8.9% | 1 published, 0 exits |
| `named_load` | `1.049x` | 12.2% | 1 published, 0 exits |
| `branch_eq` | `1.085x` | 8.2% | 1 published, 0 exits |
| `call_refusal` | `0.915x` | 19.7% | numeric leaf published; call wrapper refused |

The geometric mean improved from `1.032x` to `1.017x`; installed code across
the five probes fell from 1.7 KiB to 1.3 KiB. The follow-up attempted six
compilations, published five, refused the call wrapper once, spent 0.375 ms
compiling, and completed all 24,997,383 generated entries with zero exit.
Division (`+6.7%`) and strict-equality branching (`+8.5%`) still fail the 5%
ceiling, so the default does not flip. With unconditional callee-save traffic
removed, the next evidence-driven targets are deopt-home preparation on tiny
leaves and the emitted Number/strict-equality paths; adding unrelated opcodes,
changing heat, OSR, or inlining would not explain these residual regressions.
The direct-recovery follow-up below completes the deopt-home target.

### 3.23 Direct entry-frame deopt recovery

Physical recovery metadata should describe an authoritative source rather than
force every logical value through one storage class. V8's frame translations
likewise distinguish machine registers, typed stack slots, and literals
([translation opcodes](https://chromium.googlesource.com/v8/v8/+/ebe97b7e03a1990f88d5b76d83136c73e3432a27/src/deoptimizer/translation-opcode.h)).
Cynic has a narrower source that is especially cheap: helper-free Ohaimark
never mutates the executing Lantern `CallFrame` or register file before a
terminal return, safepoint exit, or guard exit. Block-0 parameters therefore
remain recoverable from their original accumulator/register locations for the
whole optimized invocation.

The home planner now validates block 0's complete parameter table and omits a
home only for those exact SSA values. The physical stream encodes
`frame_accumulator` and `frame_register` recipes alongside tagged-stack,
int32-stack, and immediate recipes. Derived values, non-entry block parameters
and loop phis, and state created by overwrites still receive stable
definition-time homes. Verification recomputes entry eligibility from the
graph; it does not trust a serialized bit. The differential evaluator keeps the
immutable entry accumulator/register slice next to its spill arrays and uses
the same physical recipes on guard failure.

A native guard exit cannot write direct recipes sequentially because one
destination may still contain another recipe's source. Codegen first resolves
all direct frame assignments as a bounded parallel-move set, omits identity
moves, and uses volatile `x15` to break cycles. Only after those source-dependent
moves finish does it write spill and immediate recoveries. This keeps the hot
path free of entry-home stores and gives cold exits exact alias behavior without
allocating or calling a helper.

Tests cover direct accumulator/register materialization, mixed direct/stable/
immediate streams, malformed direct-register metadata, retained derived homes,
zero-spill lowering, and a native cyclic reconstruction (`r0 <- entry r1`,
`r1 <- entry r0`). All 93 Ohaimark Debug tests and the full ReleaseSafe suite
pass.

The repeated 30-pair Darwin arm64 rollout measured:

| Fixture | Median T2/T1 | Ratio IQR | Publication result |
|---|---:|---:|---|
| `number_mul` | `0.985x` | 4.5% | 1 published, 0 exits |
| `number_div` | `0.991x` | 15.1% | 1 published, 0 exits |
| `named_load` | `1.024x` | 12.4% | 1 published, 0 exits |
| `branch_eq` | `1.054x` | 4.3% | 1 published, 0 exits |
| `call_refusal` | `0.960x` | 9.2% | numeric leaf published; call wrapper refused |

The geometric mean improved from `1.017x` to `1.002x`; installed code fell
from 1.3 KiB to 1.0 KiB. Six attempts published five leaves, refused the call
wrapper once, spent 0.167 ms compiling, and completed all 24,997,383 native
entries with zero exits. Direct recovery removes division's prior regression,
but equality remains 5.4% behind and the aggregate is 0.2% behind. The strict
`<=1.050x` per-fixture and `<=1.000x` aggregate gates therefore both miss.
Ohaimark remains default-off; the next measured change is a fused
strict-equality branch that avoids materializing a tagged Boolean.

### 3.24 Strict-equality control fusion

ECMA-262 [§7.2.14 IsStrictlyEqual](https://tc39.es/ecma262/#sec-isstrictlyequal)
defines the comparison result, but an implementation need not allocate a
Boolean when control is its only observer. V8 Maglev makes that distinction
explicit: its graph builder replaces single-use comparisons with
`BranchIfInt32Compare` / `BranchIfReferenceEqual`, and codegen compares the
original inputs at the control node
([builder](https://chromium.googlesource.com/v8/v8.git/+/refs/heads/12.0.78/src/maglev/maglev-graph-builder.cc),
[emission](https://chromium.googlesource.com/v8/v8/+/852a76c0b3c84c007c11813cd20df241dfd7a421/src/maglev/maglev-ir.cc)).
Cynic follows the consumption model but keeps the `strict_eq` SSA node: that
node owns the original fused bytecode's pre-operation deopt point, so deleting
it would couple a local codegen optimization to recovery semantics.

`runtime/ohaimark/control_fusion.zig` is a separately verified side plan. It
selects only an adjacent `strict_eq -> branch` pair where the comparison has
one total SSA use, lowers through checked int32 equality, carries an exact frame
state, and feeds truthy/falsy rather than nullish control. Shared comparisons,
ordinary `===` results carried as the accumulator on successor edges, folded
comparisons, and non-adjacent consumers stay materialized. Verification
recomputes both the branch-to-comparison map and elided-value bitmap; the
compiler reports plan failure in its own appended telemetry bucket.

Allocation omits the fused branch input from effective liveness, requires the
comparison to have no deopt home, and assigns its tagged Boolean no register or
spill. Codegen emits no definition at the retained SSA node. At the terminating
branch it uses that node's guard label, checks both original operands as int32,
XORs their 32-bit payloads, and takes equality with `cbz` or inequality with
`cbnz`. A failed operand check still reconstructs the original accumulator and
live registers and resumes Lantern at the fused equality opcode. Standalone
equality continues to use `cset` and a tagged Boolean, so this changes no
user-visible value or hardened-realm surface.

The machine-level choice was measured rather than inferred from instruction
count. The first direct lowering used `cmp` + `b.cond`; although it removed seven
instructions and passed every native test, a 300-pair same-tree T2 A/B measured
`1.044x` versus materialization, so it was rejected. Replacing it with `eor` +
`cbz/cbnz` measured `0.986x` in the same 300-pair protocol. Generated
`branch_eq` code is 140 bytes instead of 168. Tests pin both equality and
inequality instruction shapes, all i8/i16/i32 branch widths and directions,
exact Double-operand guard recovery, standalone materialization, location
elision, carried-result refusal, and independently corrupted plan fields.
The full Ohaimark Debug bucket and complete ReleaseSafe suite pass with the
retained lowering.

The retained lowering's repeated 30-pair Darwin arm64 rollout measured:

| Fixture | Median T2/T1 | Ratio IQR | Publication result |
|---|---:|---:|---|
| `number_mul` | `1.050x` | 12.6% | 1 published, 0 exits |
| `number_div` | `1.031x` | 15.6% | 1 published, 0 exits |
| `named_load` | `1.038x` | 6.1% | 1 published, 0 exits |
| `branch_eq` | `1.059x` | 5.1% | 1 published, 0 exits |
| `call_refusal` | `0.956x` | 3.9% | numeric leaf published; call wrapper refused |

Six attempts published five leaves, refused the call wrapper once, spent 0.188
ms compiling, installed 1.0 KiB, and completed all 24,997,383 generated entries
with zero exits. The geometric mean was `1.026x`; `branch_eq` still exceeds the
`1.050x` fixture ceiling. The T2-only A/B establishes that fusion improves the
Ohaimark leaf, but it does not substitute for the public T2/T1 gate. At this
checkpoint Ohaimark therefore remained default-off; the next two measured
changes addressed entry/CFG transfer and Number operand shape directly.

### 3.25 CFG transfer and one-word completion ABI

An edge into a block with one predecessor is a constrained parallel copy, not
an arbitrary join. The allocator now gives a block parameter its incoming
register when the source representation is identical and no conversion is
required. The verifier recomputes that eligibility from the CFG and rejects a
hint that crosses a representation conversion or multi-predecessor join. When
the next bytecode-order block consequently needs neither edge moves nor deopt
home stores, AArch64 codegen also omits the explicit branch and uses physical
fallthrough. This follows Maglev's distinction between a next-block edge and a
general control transfer
([V8 edge emission](https://chromium.googlesource.com/v8/v8.git/%2B/0a96df301fdaadc26a059ee5cd06fc47f9a662b6/src/maglev/maglev-ir.cc),
[Maglev assembler](https://chromium.googlesource.com/v8/v8/%2B/0a07adec84357fafdd9e6e69aa95f2d1e9f33734/src/maglev/maglev-assembler-inl.h)).

Generated entries now return one 64-bit word in AAPCS64 `x0`: an ordinary
completion is the tagged `Value` bits, while a guard/safepoint exit first
reconstructs the Lantern frame and returns the encoded non-canonical-NaN
sentinel `0x7FFA000000000001`. Cynic canonicalizes every JS NaN and uses a
disjoint NaN-box tag range, so no user-visible value can equal that control
word; compile-time assertions pin both facts. This keeps the generated/native
boundary inside the ordinary single-register result convention
([AAPCS64](https://github.com/ARM-software/abi-aa/blob/main/aapcs64/aapcs64.rst))
and follows JavaScriptCore's precedent that spare encoded `JSValue` patterns
may carry internal control state
([JSCJSValue](https://github.com/WebKit/WebKit/blob/main/Source/JavaScriptCore/runtime/JSCJSValue.h)).

A two-word `x0`/`x1` completion aggregate was implemented and rejected: the
same-tree comparison measured `1.018x`, and its public rollout repeat was about
`1.022x`, with no semantic benefit. The retained one-word ABI plus CFG changes
passed the complete Ohaimark and ReleaseSafe suites. Their intermediate
30-pair rollout installed 0.9 KiB and measured `1.014x` geometric mean, but
`number_div` at `1.076x` still failed the per-fixture ceiling. Inspection then
showed that Number-only feedback still generated both Int32 and Double paths
for each operand even when every observed pair had one stable shape.

### 3.26 Operand-shape specialization and default-on graduation

The one-byte `BinaryTypeProfile` now records five independent observations:
Int32/Int32, Double/Int32, Int32/Double, Double/Double, and any non-Number pair.
The immutable feedback snapshot derives one exact shape only after the site's
existing maturity rule; multiple numeric bits become polymorphic and any
non-Number observation keeps generic coercion in Lantern. This is the compact
equivalent of Maglev selecting operand-specific Number checks and conversions
from feedback rather than emitting every representation path
([Maglev graph builder](https://chromium.googlesource.com/v8/v8/%2B/main/src/maglev/maglev-graph-builder.cc),
[Number specialization](https://chromium.googlesource.com/v8/v8/%2B/78dd4b31847ab1f5b06ef3d8742a9f3835fb6919/src/maglev/maglev-graph-builder.cc)).

For an exact shape, each input emits one matching tag guard; an Int32 input
uses `scvtf`, while a Double input decodes and moves directly into the FP
register. Polymorphic Number sites retain the old checked Int32-or-Double
conversion, so the optimization narrows code only when the profile proves it.
`specialize.Plan.verify` independently rebuilds the pure specialization plan
immediately before codegen and compares every node decision and assumption;
corrupted or stale shape metadata fails compilation transactionally.

The graduation 30-pair Darwin arm64 rollout measured:

| Fixture | Median T2/T1 | Ratio IQR | Publication result |
|---|---:|---:|---|
| `number_mul` | `0.970x` | 2.3% | 1 published, 0 exits |
| `number_div` | `1.037x` | 2.9% | 1 published, 0 exits |
| `named_load` | `1.013x` | 5.2% | 1 published, 0 exits |
| `branch_eq` | `1.041x` | 4.3% | 1 published, 0 exits |
| `call_refusal` | `0.929x` | 2.9% | numeric leaf published; call wrapper refused |

Six attempts published five leaves, refused the call wrapper once, spent
0.217 ms compiling, installed 0.8 KiB, and completed all 24,997,383 generated
entries with zero exit. The `0.997x` geometric mean and `1.041x` worst fixture
pass the `<=1.000x` aggregate and `<=1.050x` per-fixture gates.

The forced-T2 full test262 sweep then matched the baseline at 48,517 pass and
1,324 fail; both sorted pass lists have SHA-256
`52146dd368643d2eedd21f60c731589f7fd6a0245dadeb26f8cdd70a95ec2ae3`.
It attempted 217,427 compilations, published 6,872 (3.16%), refused 210,555,
installed 135 KiB, and recorded 141,354 entries, 141,248 completions, and 106
guard exits (0.07%). Compilation consumed 4.825 s in aggregate (22 us average,
32.323 ms maximum).

ReleaseSafe threshold-1 sweeps over `built-ins/Object`, `built-ins/Array`, and
`language/expressions/object` found no GC-verifier failure or host crash; the
Array bucket retained one known 60-second watchdog. A five-minute forced-T2
crash campaign retained 216 programs with no crash artifact, and a separate
five-minute Lantern-vs-T2 completion-value differential retained 49 programs
with no differential. The fuzz host exposes `--ohaimark` so both campaigns
force T2 at threshold 1 rather than depending on natural heat.

These results graduate Ohaimark for the production CLI. It is enabled at the
natural threshold before Bistromath; `--no-ohaimark` selects T1-only and
`--no-jit` selects Lantern-only. Direct `Realm` embedders still choose their
tier policy explicitly. The full CI Ohaimark pass-set comparison is now gating,
while its GC-stress matrix remains advisory until the independent watchdog
flake is resolved.

## 4. Deoptimization contract

Every speculative node will carry an explicit assumption and deopt point.
Deopt reconstructs a Lantern `CallFrame`, not a Bistromath-specific frame:

- bytecode continuation offset;
- accumulator location;
- every live register location or recoverable value;
- environment/home-object/`this` state already owned by the frame;
- inlined-frame records once inlining exists.

The first logical metadata checkpoint now ships. During graph construction,
each arithmetic or guarded-load candidate records its **pre-operation**
accumulator and live registers as SSA values. Resuming at the node's original
bytecode offset therefore lets Lantern execute the failed operation exactly
once. A single reverse-liveness scan per block selects those registers; dead
defined registers do not inflate every guard state.

After specialization, `runtime/ohaimark/deopt.zig` emits points only for
checked-int32 arithmetic, tagged-Number multiplication/division,
feedback-specialized
property/global loads, and guarded frame/environment loads. Its byte stream
embeds constants directly and uses `ValueId` recoveries for non-constant SSA
values. The verifier checks point order and bounds, lowering/assumption
compatibility, same-block/parameter value availability, strictly ordered
in-range register slots, and exact stream decoding. Corrupt metadata returns
`InvalidMetadata` or `MalformedGraph`; it cannot become an unchecked slice or
cast trap.

`runtime/ohaimark/deopt_physical.zig` turns those logical values into verified
physical recipes. Entry-block parameters recover directly from the untouched
Lantern accumulator/register file. Every other non-constant SSA value
referenced by a deopt point receives one stable definition-time spill home;
values absent from every frame state receive none. Tagged and int32 homes
occupy separate regions, following Maglev's single split-point design
([V8 Maglev](https://v8.dev/blog/maglev#register-allocation)), so a future stack
walker scans only the tagged region. Repeated recoveries share a home.

The physical translation stream contains frame-accumulator, frame-register,
tagged-stack, int32-stack, or immediate recipes. Materializing a direct or
tagged slot is a `Value` load; materializing an int32 slot boxes with
`Value.fromInt32`; singleton and constant-pool recipes remain embedded. Every
lookup and stream read is bounds-checked, and the logical and physical formats
share one parser substrate. Tampered homes, region counts, tags, direct
registers, offsets, and spill indices return `InvalidMetadata` or
`InvalidRecovery` without unchecked access or panicking.

`runtime/ohaimark/evaluator.zig` now provides that pre-codegen proof for the
pure supported subset. It executes constants, block arguments, branches,
loops, folded nodes, checked int32 arithmetic, strict equality/inequality,
guarded tagged-Number multiplication/division, Boolean logical not, numeric
less-than, and
returns while applying the selected per-use conversions. Every derived
definition writes its required physical home; entry recipes read the immutable
entry state. A failed type/overflow/NaN guard decodes the physical stream,
materializes the accumulator and live registers, and can resume
`lantern.runFrames` at the original operation.

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
counterpart now emits checked int32 definitions/control, strict equality, and
verified branch-exclusive equality control fusion,
required home stores, direct guard exits that reconstruct the existing Lantern
frame, and live-cell named-property guards. Taken backedges also transfer
loop-header state to Lantern whenever host or GC work is pending. Owned code
survives destruction of every temporary compiler plan. The default-on
function-entry driver executes it through normal call dispatch, returning a
tagged completion in one word or reconstructing Lantern state before returning
the reserved resume sentinel. Unsupported or repeatedly deoptimizing chunks
continue through Bistromath/Lantern without changing JavaScript behavior.

## 5. Delivery order

1. **Front-end substrate, shipped:** exceptional CFG edges, immutable typed-IC
   snapshots, linear block-argument SSA, loop/diamond tests, graceful reject.
2. **Typed specialization, initial pass shipped:** small value lattice,
   fixed-point block-argument facts, IC-to-assumption transpilation,
   semantics-safe int32 folding, explicit lowering choices, verified
   tagged/int32 representation selection, and a verified adjacent/sole-use
   control-fusion side plan. Local DCE and a measured need for a Double
   representation remain.
3. **Deopt first, logical + physical metadata shipped:** pre-operation
   frame-state capture, liveness-compacted logical stream, direct entry-frame
   recipes, stable tagged/int32 homes for derived state, physical boxing,
   bounds-checked verifiers, and a bounded graph evaluator proving checked
   success plus overflow recovery against Lantern. Native guard exits now ship
   for the checked-int32 execution subset; own/prototype/synthetic property
   guards use those same exits.
4. **Abstract allocation, shipped:** CFG-scheduled live intervals, bounded
   general-purpose register ids, immediate rematerialization, deterministic
   eviction, representation-partitioned spill reuse, and stable-home reuse.
5. **AArch64 physical planning, shipped:** helper-free volatile-register
   mapping, aligned tagged/int32 frame regions, bounded direct offsets, and
   deterministic cycle-safe parallel edge moves with conversion preservation.
6. **AArch64 frame emission, shipped:** transactional prologue/epilogue,
   optional chunked aligned spill reservation, safe tagged-slot initialization,
   zero-spill leaf entry, golden words, and native-hardware execution proof.
7. **Typed moves + folded returns, shipped:** representation-bearing physical
   moves, raw int32 spill stores, boxing, checked offsets, non-heap constant
   rematerialization, and an end-to-end folded graph native return.
8. **AArch64 optimized execution, initial slice shipped:** checked int32
   add/sub/mul/div plus guarded tagged-Number multiplication/division, strict
   equality and all fused strict equality/inequality branch widths, direct
   `eor` + `cbz/cbnz` control for branch-exclusive results, standalone strict
   inequality, guarded Boolean logical not, int32
   control flow, required derived-home writes, returns, and cycle-safe direct
   Lantern-frame guard exits, plus live-cell own/prototype/synthetic named loads
   with inline/overflow slot reads. Frame `this`, inherited environments, named
   globals, and global lexical slots now use the same exact-exit contract;
   shared analysis safely
   erases only unobservable zero-slot environments. Taken backedges now poll
   fuel, interrupts, hooks, and GC work, transferring exact loop-header state
   before Lantern handles a slow condition. Transactional compilation now
   publishes an owned executable handle only after the full pipeline succeeds;
   per-tier refusal and chunk teardown preserve Bistromath independently.
   Default-on ordinary-function tier-up now ships with exact
   bailout-vs-fallback routing, one-word completion, and child-realm policy
   inheritance.
8b. **Loop-header OSR, shipping default-off:** verified OSR-entry metadata for
   every eligible loop header, AArch64 entry stubs in the same transactional
   code allocation as function entry, Lantern and Bistromath backedge drivers,
   reuse of guard-exit / safepoint recovery, and anti-thrash strikes. Kept
   independently off until its own differential and rollout benchmarks pass
   (see §3.17).
9. **Gates and tuning, shipped:** full test262 pass-set differential, SES suite,
   GC-pressure runs, fuzzing, and compile-time/code-size/performance budgets.
   CFG edge coalescing/fallthrough and exact Number operand shapes brought the
   final 30-pair rollout to `0.997x` geometric mean, `1.041x` worst fixture,
   and 0.8 KiB. Baseline and forced-T2 test262 pass lists are identical at
   48,517 paths; focused ReleaseSafe threshold-1 GC runs and two bounded fuzz
   campaigns found no verifier failure, host crash, or value differential. CI
   treats the T2 pass-set comparison as gating. The production CLI therefore
   enables T2 at natural thresholds, with `--no-ohaimark` retaining a T1-only
   posture and `--no-jit` retaining Lantern-only execution.
10. **Only if measured:** background compilation, polymorphic feedback,
   inlining, x86_64 lowering, and exception-region compilation.

### 3.17 Loop-header on-stack replacement (OSR)

Status: **implemented, default-off.** Function-entry T2 alone cannot win
single-entry hot loops (`function f() { for (…) … } ; f()`): the body never
re-enters at ip 0 after the first call, so the natural heat threshold is only
reachable through backedges. OSR closes that gap without inventing a second
frame format.

#### Prior art

- **V8 Maglev / TurboFan.** Maglev builds loop phis in a single forward pass
  (pre-created from a bytecode prepass) and supports OSR compilation for hot
  loops (`JumpLoop` can trigger optimization while the loop is still running).
  Maglev peels loops on OSR compiles so the OSR entry lands on a clean header;
  TurboFan retains the classic OSR-entry / deopt dual. Frame state is explicit;
  deopt reconstructs Ignition. Cynic reuses the Maglev-shaped fact that loop
  phis already exist as block parameters at every header
  ([Maglev](https://v8.dev/blog/maglev)).
- **JavaScriptCore DFG / FTL.** `prepareOSREntry` materializes a buffer of
  locals at a loop-header bytecode index, then a thunk loads that buffer into
  the optimized frame. Entry is rare and gated: OSR entry at arbitrary points
  would forbid many loop opts, so JSC only enters when the profiler says the
  loop has not yet terminated
  ([speculation](https://webkit.org/blog/10308/speculation-in-javascriptcore/),
  [`DFGOSREntry.cpp`](https://github.com/WebKit/WebKit/blob/main/Source/JavaScriptCore/dfg/DFGOSREntry.cpp)).
  Cynic follows the same restriction surface: only loop headers, and only when
  the compiled graph already has parameters for that header.
- **SpiderMonkey Baseline / Warp.** Baseline counts loop iterations; Ion/Warp
  OSR enters at loop headers from Baseline after a warm threshold. Bailout
  reconstructs a Baseline Interpreter frame. Warp snapshots bytecode + IC data
  on the main thread — the ownership split Ohaimark already mirrors
  ([how we optimize](https://firefox-source-docs.mozilla.org/js/how-we-optimize.html)).
- **Hermes.** Primarily AOT + a compact interpreter; the 2024 arm64 translator
  is closer to Bistromath than to a speculative T2. Useful as a control for
  "frame-compatible baseline OSR is enough for many mobile workloads," not as
  the optimizing-entry model.
- **Cynic Bistromath.** Already ships loop-header OSR (§12 3f in jit.md): a
  `bc → code_off` table in the executable region, Lantern backedge precheck,
  `osr_strikes` anti-thrash, and frame identity so entry is a jump. Ohaimark
  OSR reuses that dispatcher shape; the new work is mapping Lantern values
  onto SSA block parameters with representation conversions and deopt.

#### Accepted design

1. **Metadata first.** `runtime/ohaimark/osr.zig` walks the finished IR graph,
   collects every unique backedge target (loop header), and records its
   bytecode offset, block index, and ordered `ParamRole` list (accumulator +
   liveness-derived live-in registers). The verifier recomputes the set and
   rejects corrupted tables (missing accumulator, duplicate registers, bad
   block ownership, non-header targets). Diamond-to-loop and multi-backedge
   headers collapse to one entry per bytecode offset.

2. **Same frame.** OSR never allocates a parallel optimized frame or stores
   engine state on JS-visible objects. The entry stub loads the current
   `CallFrame` accumulator and live registers sequentially into the physical
   locations already assigned to the header's block parameters (tagged load +
   optional int32 tag-check then `movRegW` unbox + `emitMove`; it does **not**
   run `parallel_moves.resolve` — that remains for in-graph edge transfers),
   then jumps to the header block label. A failed entry materialization returns
   a distinct OSR-bail sentinel; mid-body guards and cooperative safepoints use
   the ordinary resume sentinel and restore exact Lantern state.

3. **One transactional code allocation.** OSR stubs are emitted after the
   ordinary function body into the same `Masm` buffer. Publication still
   installs one owned executable handle; a separate chunk-owned
   `bc → code_off` table (same `OsrEntry` layout as Bistromath) rides beside
   it. Failed compile refuses T2 only (`dont_compile`); Bistromath/Lantern
   stay executable. Today materialization failure is all-or-nothing for the
   compile (the whole T2 publish is refused); per-header skip-and-still-
   publish is a future refinement.

4. **Triggers.** Lantern backedges try Ohaimark OSR when
   `Realm.ohaimark_osr_enabled` is true (and the master `jit_enabled` +
   `ohaimark_enabled` gates allow). Bistromath backedges flush frame state and
   yield to the loop header so Lantern can enter a published stub. Both reuse
   heat/`dont_compile`; true enter-and-bail (OSR-bail sentinel) charges
   `osr_strikes`. Cooperative safepoint resumes do **not** charge strikes or
   the function-entry `guard_exit` budget.

5. **Refusals.** Constructors, generators, async Promise-wrapping frames, and
   exception-region chunks stay out (same as function-entry T2). Unsupported
   opcodes or OSR materialization errors refuse the whole T2 compile for that
   chunk without mutating the live frame.

6. **Default-off gate.** `Realm.ohaimark_osr_enabled` defaults false and is
   inherited by `initChild`. The CLI flag `--ohaimark-osr` (requires
   `--jit`/`--ohaimark`) exists only so validation and
   `zig build bench -- --ohaimark-osr-rollout` can flip the Realm policy
   without a separate binary — not a production default. The test262
   harness mirrors that opt-in as `--ohaimark --ohaimark-osr` (OSR requires
   `--ohaimark`; same exclude set as the T2 differential) so the
   baseline-vs-OSR pass-set gate can run before graduation. Enabling OSR by
   default waits on the graduation criteria below.

#### Rejected alternatives

- **Separate OSR-only compile unit** (compile only the loop body): doubles the
  pipeline and breaks frame-state consistency with function-entry code; Maglev
  and JSC compile the whole method with an extra entry.
- **OSR into a new native frame format:** violates the frame-identity rule
  that makes GC, deopt, and the watchdog tier-agnostic.
- **Enter at arbitrary bytecode offsets:** forbids standard loop opts; every
  production engine restricts optimizing OSR to headers (or rarer special
  points).
- **Default-on CLI for end users before gates pass:** the validation-only
  `--ohaimark-osr` flag is the compromise — opt-in for benches/tests, never
  the production default until graduation.

#### Graduation criteria (unchanged from the function-entry bar)

Do **not** default `ohaimark_osr_enabled` on unless: forced baseline-vs-T2
test262 pass sets are byte-identical, ReleaseSafe `--gc-threshold=1` over
loop/Array/Object buckets is clean, bounded Fuzzilli crash + Lantern-vs-T2
value differentials are clean, natural-threshold OSR geometric mean T2/T1 is
`≤ 1.000×`, and no stable fixture exceeds `1.050×`.

## 6. Declined for v1

- AST-to-IR compilation: bytecode is already the semantic and profiling unit.
- Sea-of-nodes IR, tracing, or global type inference: unnecessary complexity
  for the low-latency tier Cynic needs first.
- Copying raw GC pointers into optimizer snapshots or machine-code literals.
- Treating exception handlers as ordinary CFG successors.
- Background compilation before synchronous compile cost is measured.
- Deoptless continuation specialization: interesting later, but conventional
  deopt is the smaller correctness surface for the first tier.
- Default-on OSR before the §3.17 graduation criteria pass.
