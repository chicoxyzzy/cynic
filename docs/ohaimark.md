# Ohaimark optimizing JIT

Status: **default-on for ordinary-function entry and loop-header OSR on AArch64
and x86_64.** `--no-ohaimark` isolates Bistromath,
`--no-ohaimark-osr` isolates function-entry T2, and `--no-jit` selects
Lantern.

- **Qualified:** baseline and forced-T2+OSR test262 sweeps have the same
  48,653-pass set and SHA-256; ReleaseSafe GC-pressure and bounded crash/value
  differential campaigns found no mismatch or host failure.
- **Current native scope:** the feedback/SSA, specialization, representation,
  deoptimization, allocation, property-guard, safepoint, compact handoff, and
  transactional-code paths documented below on both native backends.
- **Remaining:** generalized JS-reentrant helpers, native post-call
  continuations, more opcode families, and additional targets.

Ohaimark is Cynic's T2 method JIT. It consumes finalized Lantern bytecode
and runtime feedback, builds a compact control-flow SSA graph, specializes
that graph under explicit assumptions, and eventually lowers through the
shared `runtime/jit/` assembler substrate. A failed compile or failed runtime
guard returns execution to Lantern; it must never change JavaScript behavior
or abort the host.

This document is both the accepted design and delivery ledger: §3 describes
the optimizer and backends, §4 the deoptimization contract, §5 the rollout
order, and §6 loop-header OSR.

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
AAPCS64 convention without emitting code. Ordinary generated code is
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
every tagged slot to a non-pointer value before the first safepoint. The narrow
environment-helper boundary reconstructs the physical pre-operation state into
the Lantern frame, then saves `x0`-`x8`, `x16`, and LR in a 96-byte aligned
area before calling a non-reentrant C helper. The helper either succeeds and
the generated state is restored, or resumes Lantern at the original opcode
with that already-staged frame. This mirrors the rooted-call discipline behind
V8 Maglev's [SaveRegisterStateForCall](https://chromium.googlesource.com/v8/v8/%2B/d8fd81812d5a4c5c3449673b6a803279c4bdb2f2/src/maglev/maglev-assembler.h),
without claiming a general native stack-map protocol: JS-reentrant calls and
exception-producing helpers still reject transactionally.

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

### 3.10a Monomorphic computed own-data loads

`lda_computed8` and `lda_computed` enter the graph with separate receiver and
key inputs. The native subset accepts only a mature `ComputedICCell` for an
ordinary plain object, an own data slot, and a nonempty flat string key of at
most the cell's 23-byte inline capacity. Its immutable snapshot retains only
the realm-arena-stable receiver shape, slot, and copied key bytes; it embeds no
GC-managed `JSObject` or `JSString` pointer.

Generated code first proves that the live cell still has the snapshot shape,
slot, key length, and key bytes, then proves that the receiver is a plain object
of that live shape. It requires the dynamic key to be a tagged flat `JSString`
with the same byte length and bytes before reusing the shared own-slot read.
The live-cell checks mean a same-shape refill from `obj["x"]` to `obj["y"]`
cannot accidentally execute stale specialized code.

Every other case takes the existing pre-operation guard exit: cold, cleared, or
megamorphic feedback; a non-string, rope, empty, or oversized key; a shape or
slot mismatch; and all prototype, accessor, proxy, typed-array, or coercive-key
semantics. The exit restores the original key as Lantern's accumulator at the
faulting opcode, so Lantern performs
[ToPropertyKey](https://tc39.es/ecma262/#sec-topropertykey) and the full
property access exactly once. The compiled lane allocates nothing and cannot
re-enter JavaScript; generic computed access remains a transactional refusal
until a rooted helper protocol exists.

Graph, evaluator, native, and source-level `gc_threshold=1` coverage exercise
direct hits, dynamic-key exits, post-compile IC refills, and key recovery. The
full forced-T2 and fresh T1 test262 sweeps remain identical at `48,653` pass /
`1,324` fail. `lda_computed8` leaves the leading refusal report, although the
aggregate publication count stays at 10,265 because most newly traversed
functions encounter another unsupported opcode later in the bytecode. This is
coverage evidence, not a performance claim.

### 3.10b Monomorphic computed own-data stores

`sta_computed8` and `sta_computed` use the same live-cell guard sequence, but
their effect node carries receiver, key, and assignment value inputs. Lantern
only fills a `ComputedICCell` for a writable own data slot, so native code may
skip the full [assignment evaluation](https://tc39.es/ecma262/#sec-assignment-operators)
only after it proves the live cell, plain-object receiver, and flat string key
against the immutable shape/slot/key-byte snapshot. This admits the identity
case of [ToPropertyKey](https://tc39.es/ecma262/#sec-topropertykey), never an
object or rope key, setter, prototype, proxy, typed-array, non-writable, or
shape-transition write.

After every guard succeeds, generated code performs the shared inline/overflow
slot write and immediately calls `Heap.storeInternalSlot` through a small
non-reentrant C ABI shim. The ordering deliberately mirrors Lantern: no guard
or fallible operation follows the write, and the normal generational and
incremental-marking barrier observes the new tagged value. The shim cannot enter
JavaScript or initiate collection; volatile optimized locations survive its
AAPCS64 boundary. It adds no user-visible metadata to the receiver, preserving
the SES boundary.

Every miss restores the exact pre-operation state, including the assignment
value as Lantern's accumulator and the receiver/key registers, then replays the
original opcode once. This follows Maglev's register-state discipline and
SpiderMonkey's atomic-bytecode rule: the speculative store either has no visible
effect or completes before any bailout
([V8 Maglev](https://v8.dev/blog/maglev),
[SpiderMonkey bytecode checklist](https://firefox-source-docs.mozilla.org/js/bytecode_checklist.html)).
Graph, native, and `gc_threshold=1` source coverage exercise direct writes,
overflow-safe slot addressing, young-value barriers, stale-cell exits, and
value recovery.

The fresh lower-tier and forced-T2 test262 sweeps remain `48,653` pass /
`1,324` fail. Forced T2 still publishes 10,265 functions, but moves 1,344
first-refusal sites from IR into later codegen refusals, raises generated entries
from 264,756 to 268,799, and drops `sta_computed8` out of the top-twelve
unsupported-opcode report. This is coverage evidence, not a performance or
conformance claim.

### 3.10c Same-shape named stores and feedback-scoped retry

`sta_property8` and `sta_property` now lower the narrow writable own-data
case of [OrdinarySetWithOwnDescriptor](https://tc39.es/ecma262/#sec-ordinarysetwithowndescriptor).
The immutable plan records a same-shape `StoreICCell` fact; native code proves
the live cell shape and slot, proves the receiver retains that shape, writes the
verified inline or overflow slot, and immediately invokes the normal heap write
barrier through the existing non-reentrant ABI shim. A transition cell
(`post_shape != null`), setter, prototype, proxy, exotic receiver, or any guard
miss takes the pre-operation exit before a visible write, leaving Lantern to
perform the full `[[Set]]` exactly once.

Cold generic property operations are no longer treated as permanently
unsupported codegen. The emitter returns a typed descriptor for the first
generic named-load, named-store, computed-load, or computed-store node. The T2
state retains only its opaque site key and a one-bit readiness fingerprint; on
each eligible entry or OSR probe, the driver reads only that same live cell.
Named loads become ready with a shape; named stores require a same-shape cell;
computed sites additionally require a nonempty, in-cap cached key. Transition
and megamorphic cells remain unready. Thus an unrelated IC update cannot reopen
a refusal, while a cold-to-monomorphic transition reattempts compilation once
and either publishes or defers at the next unresolved property site.

This follows the feedback-first discipline used by
[V8 Maglev](https://v8.dev/blog/maglev) and
[SpiderMonkey's optimizing pipeline](https://firefox-source-docs.mozilla.org/js/how-we-optimize.html):
baseline feedback selects a narrow guarded path, rather than causing a generic
recompilation loop. Focused tests prove the retry token ignores an unrelated
property IC and rejects transition or megamorphic feedback. The final forced-T2
four-worker sweep retained the exact `48,653` pass / `1,324` fail set while
making `223,098` attempts and publishing `12,699` functions (5.69%). This is
coverage and retry-policy evidence, not a speed or conformance claim.

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
depth. Ohaimark now compiles the normal-flow portion of a chunk with handlers:
`normalReachability()` follows only ordinary successors, so catch landings and
synthetic rethrow blocks that are reachable only through an exception edge are
not translated or emitted. Protected-range starts and ends are basic-block
leaders, so exceptional liveness attaches to exactly the covered instructions;
their state does not become an SSA phi.

An explicit `throw_` is a terminal node with a physical pre-operation frame
state. AArch64 takes the ordinary guard-exit path, restores the accumulator and
all liveness-derived registers into the existing Lantern frame, stamps the
original bytecode offset, and returns the resume sentinel. Lantern then executes
the original [ThrowStatement](https://tc39.es/ecma262/#sec-throw-statement) and
its existing unwinder owns the [TryStatement](https://tc39.es/ecma262/#sec-try-statement)
handler search, catch binding, `finally` completion, termination, and async
boundary behavior under the normal [Completion Record](https://tc39.es/ecma262/#sec-completion-record-specification)
rules. There is no native JS exception unwind and no compiled-handler entry
stub in this T2 path.

This follows Maglev's use of interpreter frame states at deopt-capable nodes
([V8 Maglev](https://v8.dev/blog/maglev)) and SpiderMonkey's requirement that a
bytecode operation remain atomic across bailout and exception behavior
([bytecode checklist](https://firefox-source-docs.mozilla.org/js/bytecode_checklist.html)).
The targeted `vendor/test262/test/language/statements/try` differential matches
T1 at `195 pass / 6 fail`; a `gc_threshold=1` source regression covers catch
identity, `finally`, and a heap object live only through the replay. The
approach adds no user-visible state or handler metadata to JavaScript objects,
preserving the SES boundary. Treating exceptional edges as ordinary native CFG
edges remains forbidden.

### 3.13 Fallback is part of correctness

`UnsupportedOp`, malformed internal bytecode, an oversized graph, or allocation
failure all abandon Ohaimark compilation. Once tier-up is attempted, the chunk
remains executable in Bistromath/Lantern. These are normal compiler outcomes,
never `panic`, `unreachable` on input-dependent state, or partial optimized
execution.

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
(§6).

Only fresh ordinary-function frames use function-entry T2. Constructors,
generators, and async Promise-wrapping frames stay in the lower tiers. Loop-
header OSR is a separately disableable default policy. A cold/refused T2
attempt leaves the frame untouched and permits T1;
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

### 3.17 Frame, environment, global loads, and compact call/construct/property handoff

The optimizer distinguishes environment allocation from environment access with
a shared post-bytecode analysis in `bytecode/environment_elision.zig`. Both JIT
tiers erase `make_environment` only when every allocation in the chunk has zero
slots and the same chunk performs no environment read or write. Ohaimark also
lowers exactly one `make_environment` at bytecode offset zero, including a
zero-slot allocation whose pushed depth is observed by `lda_env`. Before it
materializes any SSA parameter, the generated entry saves `x0`-`x2`, `x16`, and
LR in a 48-byte AAPCS64-aligned temporary area, calls the environment allocator,
then restores that ABI state. Thus every pre-call JS reference remains in the
registered Lantern frame; the helper writes the fresh child into `frame.env`
before native code walks it. Allocation failure restores the untouched entry
state, sets `frame.ip = 0`, and returns the normal resume sentinel so Lantern
retries the original opcode and reports `OutOfMemory` normally.

An `lda_env` without a local allocation is still valid: it reads an inherited
environment from the existing `CallFrame`, so Ohaimark walks and null-checks the
live parent chain rather than manufacturing optimizer state. This preserves the
environment-record and `GetThisBinding` boundaries in
[§9.1.1](https://tc39.es/ecma262/#sec-environment-records) and
[§9.1.1.3.4](https://tc39.es/ecma262/#sec-getthisbinding).

Later or multiple allocations now become void `allocate_environment` nodes;
`sta_env` becomes a void `store_environment` node with the accumulator as its
one tagged input. Both carry a physical pre-operation deopt point. Codegen
first reconstructs that exact accumulator/live-register state in the existing
Lantern frame, then saves `x0`-`x8`, `x16`, and LR before calling the allocator
or a `Heap.storeEnvSlot` shim. The latter preserves the normal generational and
incremental-marking write barrier. A helper failure restores the native ABI,
stamps the original bytecode offset, and resumes Lantern; a successful helper
restores the live optimizer state and continues. This is a deliberately narrow
frame-staged safepoint, not a general stack-map/continuation protocol: neither
helper can re-enter JS, and calls, exception-producing operations, and
continuation-bearing opcodes still reject transactionally.

`lda_arguments` extends that boundary only for
[`CreateUnmappedArgumentsObject`](https://tc39.es/ecma262/#sec-createunmappedargumentsobject).
It is a tagged, result-producing allocation node with no SSA inputs: the
incoming argument window is deliberately pinned in the rooted Lantern frame,
not treated as a normal remappable register use. Codegen commits the exact
pre-operation frame, saves the volatile ABI state, and calls a typed
non-reentrant helper. The helper bounds-checks `argc`, builds the fresh exotic
object, and publishes its tagged result in `frame.accumulator`; after restoring
the ABI, native code reloads that value and installs its ordinary tagged SSA
home. An invalid frame replays the original bytecode, while an allocation
failure returns the ordinary host OOM completion without replaying a partially
completed allocation. This follows Maglev's
[`SaveRegisterStateForCall`](https://chromium.googlesource.com/v8/v8/%2B/d8fd81812d5a4c5c3449673b6a803279c4bdb2f2/src/maglev/maglev-assembler.h)
discipline and SpiderMonkey's
[atomic-bytecode contract](https://searchfox.org/mozilla-central/source/js/src/doc/bytecode_checklist.md),
but deliberately does not create a generic JS-reentrant helper ABI.

Graph, AArch64, and source-level `gc_threshold=1` coverage prove that the
incoming objects remain roots throughout allocation, each invocation receives a
fresh Arguments exotic, and generated execution needs no guard exit. The
`language/arguments-object` T1/T2 differential matches at 225 pass / 38 fail
with nine generated functions and zero guard exits. The full forced-T2 run
retained the 48,653-path / 1,324-failure pass set, published 8,634 functions,
and removed `lda_arguments` from the refusal report.

`make_object` and `make_object_shape` now reuse the same result-producing
boundary for the static-data
[`ObjectLiteral`](https://tc39.es/ecma262/#sec-object-initializer) subset. The
shaped variant validates and resolves its chunk-local key template, builds or
reuses its shape, stamps the fresh object, and initializes every slot to
`undefined` before a collection can scan it. Its adjacent
[`def_template_property`](https://tc39.es/ecma262/#sec-runtime-semantics-propertydefinitionevaluation)
is a two-input staged helper that writes the private literal register's known
slot plus the normal heap write barrier; malformed or demoted state replays
Lantern's generic definition path. Computed keys, spreads, accessors, and
generic property definitions remain Lantern-only.

Graph, native AArch64, and source-level `gc_threshold=1` coverage prove
prototype, shape-slot initialization, freshness, and root survival. The
`language/expressions/object` T1/T2 differential matches at 1,136 pass / 34
fail. The full forced-T2 pass set remains 48,653 pass / 1,324 fail;
publications rise from 8,634 to 9,467, while `make_object_shape` and
`make_object` leave the leading refusal report.

`make_function` now takes the same result-producing boundary for the ordinary,
synchronous [`OrdinaryFunctionCreate`](https://tc39.es/ecma262/#sec-ordinaryfunctioncreate)
subset. The graph carries a validated function-template index and stages the
complete pre-operation Lantern frame before the helper allocates the closure.
The helper captures `frame.env`, stamps the current module and running realm,
applies the template's source, name, and spec length, and wires the fresh
function's `Function.prototype` and ordinary `.prototype` object before
publishing the tagged result in `frame.accumulator`. Native code restores its
volatile ABI state and reloads the normal tagged SSA value. Invalid frame or
template metadata replays Lantern; allocation failure returns the ordinary host
OOM completion without exposing a partial closure.

This follows Maglev's allocating, lazily-deoptimizable
[`FastCreateClosure`](https://chromium.googlesource.com/v8/v8.git/%2B/a530b2c29486d05e98fde344898cd007846cb50a/src/maglev/maglev-ir.h)
discipline and SpiderMonkey's
[atomic-bytecode contract](https://searchfox.org/mozilla-central/source/js/src/doc/bytecode_checklist.md),
without introducing a generic JS-reentrant helper ABI. Arrow, generator, async,
and named-function-expression templates remain Lantern-only.

The adjacent static object-method sequence now extends that same bounded
family: direct `make_object -> make_function -> set_home -> def_property`
becomes a pair of effect nodes after closure allocation. The first applies
[`MakeMethod`](https://tc39.es/ecma262/#sec-makemethod) (§10.2.5) to the
rooted function accumulator; the second performs
[`PropertyDefinitionEvaluation`](https://tc39.es/ecma262/#sec-runtime-semantics-propertydefinitionevaluation)
through a shared helper only after proving the same fresh plain object, closure,
home-object register, and static string key flow directly through the sequence.
The helper repeats ordinary-object, extensibility, configurable-own-property,
and non-constructor guards before its own-data write, so an exotic receiver,
unexpected descriptor, malformed frame, or future graph rewrite resumes the
original Lantern bytecode without mutation. Its state is fully captured in the
ordinary `CallFrame`; it introduces no user-visible engine property, global,
or primordial mutation, so the SES hardening posture is unchanged.

This follows Maglev's allocating
[`FastCreateClosure`](https://chromium.googlesource.com/v8/v8.git/%2B/a530b2c29486d05e98fde344898cd007846cb50a/src/maglev/maglev-ir.h)
discipline and SpiderMonkey's
[atomic-bytecode contract](https://searchfox.org/mozilla-central/source/js/src/doc/bytecode_checklist.md):
the whole narrow method operation is either completed by a non-reentrant helper
or replayed once by Lantern. Graph and `gc_threshold=1` source coverage verify
`super` via `[[HomeObject]]`, removal of [[Construct]] / `.prototype`, property
installation, and root survival. The relevant conformance surface is
`test/language/expressions/object/method-definition/`; computed method names,
getters/setters, generator or async methods, class methods, spreads,
`__proto__` mutations, and every generic `def_property` remain Lantern-only.
The subsequent four-worker forced-T2 sweep retained the exact `48,653` pass /
`1,324` fail set, raised publications from `12,429` to `12,699`, and removed
`set_home` from the leading unsupported-opcode report. This is T2 coverage
evidence, not a conformance-score claim.

Graph, AArch64, and source-level `gc_threshold=1` coverage prove captured
environment retention, formal-length adjustment, prototype wiring, closure
freshness, and post-GC invocation. The `language/expressions/function` T1/T2
differential matches at 243 pass / 21 fail. The full forced-T2 pass set remains
48,653 pass / 1,324 fail; publications rise from 9,467 to 10,265, with
`make_function` absent from the leading refusal report.

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

The mid-body follow-up again kept the forced-T2 pass list equal to the lower-tier
baseline: 48,653 paths, SHA-256
`10f024349d3467c72112da03dd57e0d7e543cdb819a00b3082dfecedaec614ca`.
Its four-worker sweep attempted 222,334 compilations, published 7,036, refused
215,298, installed 181 KiB, and completed 143,447 of 143,565 generated entries
with 118 guard exits. `make_environment` no longer appears as an unsupported
opcode; `call_method8` (23,611), `throw_if_hole` (21,131), and `typeof_`
(9,117) are the leading remaining frontiers. Native tests pin the 96-byte
save/restore sequence, retain a frame root and its environment chain through a
full collection, test the barrier-backed store, and compile a real `var` write
at `gc_threshold=1`. The ReleaseSafe `language/statements/let` T2 bucket also
passed with `gc_threshold=1`.

`throw_if_hole` now lowers as a tagged identity guard. Per
[§9.1.1.1.6 GetBindingValue](https://tc39.es/ecma262/#sec-declarative-environment-records-getbindingvalue),
the Hole path must produce the normal TDZ `ReferenceError`; it therefore exits
through the existing pre-operation deopt path and lets Lantern create and unwind
that completion. The non-Hole path preserves the tagged accumulator in place,
without a helper call, allocation, or synthetic exception state. Graph-evaluator
and native AArch64 tests cover both paths.

The four-worker ReleaseSafe `--timeout=0` differential retained byte-identical
48,653-path T1 and forced-T2 pass lists (SHA-256
`10f024349d3467c72112da03dd57e0d7e543cdb819a00b3082dfecedaec614ca`). T2
attempted 222,336 compilations, published 7,297, installed 241 KiB, and entered
generated code 260,248 times (260,112 completions and 136 guard exits).
The same safe sweep exposed a separate `Iterator.zipKeyed` card-marking gap:
copied keys and longest-mode padding values now remember a mature wrapper after
each heap-value write, with an alternating-minor/major regression test.

`typeof_` now lowers directly under
[§13.5.3](https://tc39.es/ecma262/#sec-typeof-operator). AArch64 classifies the
NaN-boxed tag without coercion or property access: Double and Int32 join the
Number result; String, Boolean, Null, and Undefined take their fixed paths;
the heap-pointer kind distinguishes Function, Symbol, BigInt, and plain
objects; and the packed callable-exotic bit preserves Proxy and
`%Function.prototype%`'s `"function"` result. This follows the same basic
tagged-value discipline exposed by
[JavaScriptCore's `JSValue`](https://github.com/WebKit/WebKit/blob/main/Source/JavaScriptCore/runtime/JSCJSValue.h),
while retaining Ohaimark's existing pre-operation deopt contract rather than
adding a helper call. Each Realm owns eight lazy immutable result strings in
`Intrinsics`; a cold cache takes that deopt, Lantern allocates the string once,
and later native entries load it directly. The cache is GC-rooted and snapshot
encoded as an intrinsic `Value`, so it is neither JS-visible state nor an SES
surface change. Graph-evaluator, layout, snapshot, and native tests cover the
cache miss plus every ECMAScript value category, including callable plain
objects. The forced-T2 ReleaseSafe sweep published 7,354 functions (up from
7,297), installed 270 KiB, and completed 260,118 of 260,306 generated entries;
`typeof_` dropped out of the leading refusal report. Its 48,653 pass paths were
byte-identical to forced T1 (SHA-256
`10f024349d3467c72112da03dd57e0d7e543cdb819a00b3082dfecedaec614ca`).

#### Direct monomorphic compact call/construct/property handoff

Ohaimark now accepts a narrow JS-reentrant boundary for
[`EvaluateCall`](https://tc39.es/ecma262/#sec-evaluatecall) and
[`EvaluateNew`](https://tc39.es/ecma262/#sec-evaluate-new)'s compact bytecode
forms: `call_method8`, fixed-arity free calls `call0_8` through `call3_8`, the
generic-arity `call8`, `call_property8`, and `new_call8`. A shared handoff
record distinguishes ordinary calls, property calls, and construction. Method
and property calls preserve their receiver, while free calls explicitly pass
`undefined` as strict `this`. A call needs an exact ordinary bytecode
`JSFunction`, excluding native, bound, wrapped, class, generator, async,
revocable, and synthetic-accessor behavior. Construction additionally verifies
the mature CallIC's cached prototype against the live constructor; it excludes
native, bound, wrapped, arrow, generator, async, revocable, and
synthetic-accessor behavior, while ordinary class constructors remain eligible.
Before any allocation, codegen decodes the pre-operation physical deopt point
and materializes the caller's accumulator, receiver when present, callee, and
argument window in its Lantern `CallFrame`. A compile-time root check rejects a
malformed liveness/deopt snapshot rather than publishing code that could lose a
call operand during collection. This is the same materialize-before-call
discipline as V8 Maglev's
[`SaveRegisterStateForCall`](https://chromium.googlesource.com/v8/v8/%2B/d8fd81812d5a4c5c3449673b6a803279c4bdb2f2/src/maglev/maglev-assembler.h),
but Cynic returns to Lantern instead of maintaining a native post-call state.

For `call_property8`, the receiver is `this` and its arguments occupy the
following contiguous register window. The T2 helper first requires a plain
object receiver and a mature data-only `LoadICCell` with the exact receiver
shape. An own-slot load checks that slot directly; an immediate-prototype load
also checks prototype identity, prototype shape, and the Realm prototype
revision before reading the slot. It then requires the `CallICCell` to name the
same ordinary bytecode function found in that slot. A cold cell, non-data cell,
receiver or prototype mismatch, accessor, Proxy/exotic, or target mismatch is
not partially executed: it reconstructs the pre-operation state and lets
Lantern perform the whole operation. This is the fused-property-call shape used
by V8 Ignition's
[`CallProperty0/1/2`](https://chromium.googlesource.com/v8/v8/%2B/447bf33d786e39067e76cfa7604bacdcf2287c25/src/interpreter/bytecodes.h),
while its all-or-nothing fallback follows SpiderMonkey's
[atomic bytecode/IC contract](https://searchfox.org/mozilla-central/source/js/src/doc/bytecode_checklist.md).
In particular, rejecting synthetic accessor cells keeps hardened-realm
override-mistake accessors in Lantern and adds no JIT-only user-visible state.

The generated stub then advances `frame.ip` past the operation and invokes a
shared `lantern/call.zig` frame push. The call helper applies ordinary-call
setup, including arrow lexical `this` and `new.target`. The construct helper
allocates an instance from the IC's cached prototype, applies its initial-shape
capacity hint, sets `is_construct` plus `new_target`, and lets Lantern apply
§10.2.2 ConstructResult when the child returns. Both append the bytecode child
to the same `CallFrame` list and immediately return a reserved control word, so
generated code does not touch a possibly relocated caller frame. The helper
boundary preserves `x1` through `x8`, `x16`, and LR while leaving its status in
`x0`, so a cold or mismatching IC can safely reconstruct the pre-operation
Lantern state. The Ohaimark driver then yields to Lantern, which drives the
child and uses its normal return path to restore the parked caller at the
following bytecode. `JitFrameScope` conditionally registers a top-level
`callJSFunction` frame list before either JIT can allocate, closing the root gap
that existed before a direct frame push.

A cold or mismatching call, construct, or property IC, a changed constructor
prototype, or any excluded callable form reconstructs the same pre-operation
state and replays the original opcode in Lantern. This is a frame handoff, not
a native post-call continuation: after a successful child call, the remainder
of the parent runs in Lantern until a later tier entry. Generic JS-reentrant
helpers and native post-call continuations remain unsupported. Explicit
`throw_` is the narrow exception path: it is terminal pre-operation replay to
Lantern, not a native exception continuation or handler compilation. Focused
source-level coverage forces collection at `gc_threshold=1`, exercises every
compact free-call layout, validates strict `this` plus argument placement, and
checks constructor `new.target`, object-return ConstructResult, cold, and
polymorphic fallback. Property coverage adds a mature own-data hit plus cold
LoadIC/CallIC replay and a same-own-shape, different-immediate-prototype miss.
The forced-T2 `language/expressions/call` sweep remains 82 pass / 10 fail,
publishes nine functions, completes 100,008 generated entries, and exits zero
times; the `language/expressions/new` sweep remains 73 pass / 0 fail. The full
forced sweep remains `48,653` pass / `1,324` fail, publishes 8,370 functions,
generates 263,938 entries, completes 260,124, and records 2,364 guard exits.
`call_property8` no longer appears in its leading unsupported-opcode report.
The CI-shaped excluded interpreter/T2 pass-set differential remains the
independent release gate.

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

### 3.22 Volatile-register ABI and rooted entry allocation

The follow-up applies the platform convention rather than inventing a private
one. AAPCS64 classifies `x0`-`x17` as caller-saved (`x16`/`x17` are IP0/IP1),
`x18` as platform-specific, and `x19`-`x29` as callee-saved
([Arm AAPCS64](https://github.com/ARM-software/abi-aa/blob/main/aapcs64/aapcs64.rst)).
Most Ohaimark entries make no helper call, so preserving ten callee-saved
registers and FP/LR on every entry paid for a capability they could not use.
V8 Maglev likewise saves a snapshot's live registers around an actual
call/safepoint rather than unconditionally for helper-free code
([Maglev assembler](https://chromium.googlesource.com/v8/v8/+/d8fd81812d5a4c5c3449673b6a803279c4bdb2f2/src/maglev/maglev-assembler.h)).

The lowering contract keeps the realm, Lantern frame, and Lantern register-file
pointers in incoming `x0`-`x2`, maps the allocator to `x3`-`x8`, keeps existing
scratch in `x9`-`x15`, and anchors spills in `x16`. The prologue contains only
optional aligned spill reservation, spill-base setup, and tagged-home
initialization; a zero-spill graph starts at its first body instruction. The
epilogue releases optional spills and returns. The one rooted entry allocator
temporarily saves/restores the volatile state it needs. All generic and
mid-body helper calls remain unsupported until they can flush/reload optimized
state and publish precise root metadata; they cannot quietly invalidate this
layout.

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

#### Post-graduation refresh (2026-07-30)

On `Darwin 25.6.0 arm64`, from `f8c30570` plus the current worktree, two
independent 30-pair function-entry runs measured the following host-local
results:

| Run | `number_mul` | `number_div` | `named_load` | `branch_eq` | `call_refusal` | Geometric mean | Worst fixture |
|---|---:|---:|---:|---:|---:|---:|---|
| first | `0.964x` | `1.031x` | `1.021x` | `1.020x` | `0.989x` | `1.005x` | `number_div`, `1.031x` |
| repeat | `0.959x` | `1.035x` | `1.024x` | `1.017x` | `0.985x` | `1.004x` | `number_div`, `1.035x` |

Each probe attempted 11 chunks, published six, refused five, installed 0.9
KiB, and recorded 24,997,387 entries, 24,997,383 completions, and four guard
exits; compilation took 0.267 ms and 0.256 ms, respectively. Every fixture
remains within the `1.050x` per-fixture limit, but both runs miss the strict
`<=1.000x` aggregate rollout threshold by 0.4-0.5%. This is reproducible
host-local regression evidence, not a reason to silently rewrite the already
graduated default-on decision; future Ohaimark performance changes should
resolve or explain it before treating the aggregate gate as re-qualified.

The matching OSR 30-pair run measured `0.119x` geometric mean and `0.133x`
worst: `count_loop` `0.133x`, `sum_loop` `0.094x`, and `mul_acc_loop`
`0.133x`. All three OSR chunks published, with 0.233 ms compile time, 2.1 KiB
of code, three entries/completions, and zero exits. The OSR result remains
comfortably inside the production threshold.

#### x86_64 function-entry qualification (2026-07-30)

The canonical remote peer box is `x86_64`. Its native Ohaimark backend now
supports direct formal/folded returns, strict tagged-Number `mul` / `div`
leaves with exact Int32/Double feedback, fused Int32 strict-equality return
diamonds, and monomorphic own-data named loads. It uses the SysV `Value`
register ABI and the shared logical/physical deopt metadata, so every failed
tag, shape, slot, kind, or live-IC guard reconstructs the exact Lantern
accumulator, registers, and bytecode offset before returning the common resume
sentinel.

The named-load fast path validates the tagged plain-object kind, the live
chunk-owned `LoadICCell`, and the receiver shape before reading an
inline/overflow slot. The x86 encoder grew the corresponding integer
mask/test and direct memory-compare forms; compacting those guards moved the
five-pair `named_load` screen from `1.094x` to `0.998x`. A permanent T2 refusal
also takes a one-byte status fast path. Finally,
the published `JitState.ohaimark_requires_frame_scope` capability makes the
helper boundary explicit. At this initial checkpoint every x86 graph was
helper-free, so each published entry skipped `JitFrameScope`'s root-list scan.
The loop path described below may use typed native spills and OSR, but it never
collects or re-enters JS while values live only in those locations; a slow poll
first reconstructs the exact Lantern frame and returns.

The qualifying 30-pair run from `7b5bda49` measured:

| Fixture | Median T2/baseline | Ratio IQR | Publication result |
|---|---:|---:|---|
| `number_mul` | `0.969x` | 6.0% | 1 published, 0 exits |
| `number_div` | `0.981x` | 8.0% | 1 published, 0 exits |
| `named_load` | `0.997x` | 7.7% | 1 published, 0 exits |
| `branch_eq` | `0.943x` | 5.1% | 1 published, 0 exits |
| `call_refusal` | `0.986x` | 6.2% | numeric leaf published; wrapper refused |

The `0.975x` geometric mean and `0.997x` worst fixture pass the
`<=1.000x` aggregate and `<=1.050x` per-fixture gates. Across the five probes,
11 attempts published five functions, refused six, spent 0.351 ms compiling,
installed 0.8 KiB, and completed all 24,997,383 generated entries with zero
guard exits. At this checkpoint Bistromath had no x86 backend, so this
rollout's `--no-ohaimark` control resolved to Lantern even though the report retains the historical
`T1` column label.

The CI-shaped x86 interpreter and forced-Ohaimark sweeps (the three watchdog
exclusions retained) both finished at 48,517 pass and 1,324 fail. Their sorted
pass lists compare byte-for-byte at SHA-256
`52146dd368643d2eedd21f60c731589f7fd6a0245dadeb26f8cdd70a95ec2ae3`.
The forced run attempted 221,394 compilations, published 6,545 leaves,
installed 65 KiB, and recorded 40,809 entries/completions with zero guard
exits. The full ReleaseSafe suite also passed 3,432/3,700 tests with 268
intentional skips.

This qualified the initial x86 function-entry subset for the default production
posture. At that checkpoint x86 still refused OSR, helpers, allocation, spills,
calls, general CFG lowering, prototype properties, and most opcodes. The
separate loop gate below expands only the helper-free CFG/OSR part of that
surface; the other refusals remain deliberate.

#### x86_64 loop-header OSR qualification (2026-07-30)

The x86 backend now reuses the target-independent control-fusion, allocation,
logical/physical deopt, and OSR plans for helper-free loops. It lowers checked
Int32 add/sub/mul (including overflow and multiply negative-zero exits),
strict-equality and truthiness control, typed tagged/Int32 native spills,
cycle-safe block-argument edge moves, backedges, and same-allocation OSR entry
stubs. Every guard reconstructs the exact pre-operation Lantern frame.

Taken backedges poll marking/sweeping state, allocation and byte GC thresholds,
the host interrupt hook, fuel, and the cooperative interrupt flag. A slow poll
first transfers the exact loop-header accumulator and live registers to
Lantern, then returns; native x86 code never invokes a helper or collector with
roots held only in its spill frame. Focused native tests cover count, sum, and
product loops, arithmetic overflow, zero fuel, cooperative interruption, and a
GC-pressure transfer containing a tagged root.

The native remote 30-pair rollout measured:

| Fixture | Median T2/baseline | Ratio IQR | Publication result |
|---|---:|---:|---|
| `count_loop` | `0.243x` | 34.1% | 1 published, 0 exits |
| `sum_loop` | `0.181x` | 19.5% | 1 published, 0 exits |
| `mul_acc_loop` | `0.189x` | 21.9% | 1 published, 0 exits |

The geometric mean was `0.203x` and the worst fixture `0.243x`. All three
attempts published, compilation took 0.427 ms, installed code totaled 2.8 KiB,
and all three entries completed with zero guard exits.

The matching CI-shaped x86 interpreter and forced-Ohaimark+OSR test262 sweeps
both finished at 48,517 pass and 1,324 fail. Their sorted pass lists are
byte-identical at SHA-256
`52146dd368643d2eedd21f60c731589f7fd6a0245dadeb26f8cdd70a95ec2ae3`.
The forced run attempted 221,394 compilations, published 6,545, installed 65
KiB, and recorded 40,809 entries/completions with zero guard exits. Focused
native Debug and ReleaseSafe x86 suites pass, including the safepoint cases.
The final repository-wide ReleaseSafe gate also passed 3,459/3,732 tests with
273 intentional skips.

This qualified helper-free x86 loop-header OSR for the default natural-
threshold posture. At that checkpoint general CFG helpers, allocations, calls,
division, prototype-property paths, and broader opcodes still refused normally
and returned execution to Lantern.

#### x86_64 rooted compact-call handoff and backend decomposition (2026-07-31)

The next x86 slice ports the already-qualified AArch64 handoff contract rather
than inventing a native post-call continuation. It covers direct strict calls
(`call_method8`, `call0_8` through `call3_8`, and `call8`), fused own-data
`call_property8`, and `new_call8`. The generated entry executes only the
monomorphic IC-hit prefix: it parks the caller after the bytecode operation,
pushes one vetted bytecode child frame, and returns control to Lantern. Cold or
stale ICs, proxies, bound/native/async/generator functions, class misuse, and
every other exotic case replay the original §13.3.6 call or §13.3.5
construction path before user code runs.

Three pieces are target-independent:

- `entry_result.zig` owns the resume, OSR-bail, child-pushed, and host-OOM
  sentinels;
- `frame_recovery.zig` plans exact parallel Lantern-frame reconstruction,
  including cycles and deferred spill/immediate writes;
- `call_handoff.zig` validates rooted operand windows and weak call/property
  IC facts, applies the ordinary-bytecode-function eligibility rules, and
  invokes the shared Lantern frame-push operations.

The SysV emitter first reconstructs the exact pre-call frame and writes the
post-bytecode `ip`. It reserves one native stack word, which both changes entry
`rsp % 16 == 8` into the required call-site alignment and saves `CallFrame*`.
The six C arguments occupy `rdi`, `rsi`, `rdx`, `rcx`, `r8`, and `r9`; `r11`
holds the indirect helper target. A pushed child or host-OOM result never
dereferences the possibly relocated caller frame. A transactional tier-down
restores the original bytecode `ip` and returns the common resume sentinel.
Because the helper may allocate or relocate the frame list, publication carries
an `ohaimark_requires_frame_scope` bit alongside the executable. AArch64
currently sets it conservatively for every entry; x86 sets it only for graphs
containing a direct call. The driver compiles first, reads the published
capability, and registers roots only around entries that can cross the helper
boundary. This preserves the helper-free x86 leaf/loop cost model while making
the call-capable path safe.

The same pass decomposed the x86 implementation by ownership:
`codegen_x86_64.zig` is the general spill/CFG/OSR facade,
`codegen_x86_64_leaf.zig` owns the compact leaf/diamond matcher,
`codegen_x86_64_shared.zig` owns frame and immediate primitives, and
`property_codegen_x86_64.zig` owns the reusable own-data LoadIC guard. The main
backend fell from 2,447 to 1,524 lines without adding a generic instruction
emitter or duplicating recovery policy.

The implementation was driven by a native x86 red test: a warmed
`load_named -> call_method8 -> continuation` graph previously remained
`.dont_compile`. Focused native tests now cover direct/free/property calls,
construction, GC-threshold-1 frame pushes, cold ICs, and target/prototype
mismatches. The identical native `-Dtest-filter=Ohaimark` bucket moved from
125 pass / 28 fail to 132 pass / 21 fail with the same 69 architecture skips:
the seven call/construct hit-and-miss tests are the exact additions and no
prior pass regressed. The complete ReleaseSafe, pass-set differential, and
natural-threshold rollout evidence is recorded with the milestone in
[ROADMAP.md](ROADMAP.md).

The final native qualification used revision `477e8e4d0845` and the repository
pin, Zig `0.17.0-dev.1275+59a628c6d`. The 30-pair function-entry rollout
measured `0.966x` geometric mean / `0.997x` worst: all 24,997,383 generated
entries completed with zero guard exits. The OSR rollout measured `0.201x` /
`0.224x`, with all three entries completing. CI-shaped baseline and forced-T2
test262 runs each passed 48,517 fixtures; their pass lists were byte-identical
at SHA-256
`52146dd368643d2eedd21f60c731589f7fd6a0245dadeb26f8cdd70a95ec2ae3`.
The forced run published 6,675 functions and completed 40,809 of 40,939
generated entries, with the remaining 130 taking ordinary guard exits. The
full pinned x86 ReleaseSafe run at that checkpoint had no unrelated failures:
its 21 failures were the unchanged architecture-coverage assertions listed
above.

#### x86_64 architecture-parity closure (2026-07-31)

The follow-up closed those 21 native architecture assertions without adding a
generic JS-reentrant helper ABI. The compact x86 matcher now distinguishes a
valid but unsupported terminal from a malformed graph, allowing transactional
fallback to the general CFG backend. The CFG path gained the remaining
qualified AArch64 operations:

- checked relational and numeric conversion lowering, static
  truthy/falsy/nullish branches, and exact edge-state recovery;
- named and monomorphic flat-string computed own-data load/store ICs, shared
  feedback-scoped cold-IC retry, and rooted computed delete;
- rooted non-reentrant helpers for lexical environments, unmapped arguments,
  ordinary closures and methods, object literals, dense and unfused array
  literals, dense append, and template properties;
- `tail_dispatch`, `throw_`, and `throw_if_hole` terminal replay through
  Lantern.

The helper contract is target-neutral in `frame_safepoint.zig`: generated code
first serializes the complete pre-operation frame, and a helper may then
allocate or mutate typed engine state but may not invoke JavaScript. Success
continues in generated code where the operation permits it; a validation miss
replays the original bytecode; allocation failure returns the host-OOM control
word. Property retry policy similarly moved to `feedback_retry.zig`, so both
backends classify cold, invalidated, and permanently unsupported IC states the
same way.

One GC-pressure regression exposed an x86 register-allocation contract rather
than a helper bug. The value register set includes `r8`, `r9`, and `r10`, while
frame recovery still used `r10` as its move scratch. A safepoint could
therefore overwrite the third live SSA input before materializing a shaped
object or unfused array. Recovery now reserves `rax` for ordinary moves and
`r11` for cycles, and a compile-time assertion keeps both plus `rcx` out of the
value register set. The `gc_threshold=1` object/array tests exercise this exact
case.

At this 2026-07-31 checkpoint Bistromath remained AArch64-only. The tier-policy
tests asserted the active lower tier per architecture: AArch64 refusal and
warmth continued through Bistromath, while x86_64 kept the T1 record cold and
continued through Lantern. This was policy parity, not a hidden x86
Bistromath implementation.

The final x86-target `-Dtest-filter=Ohaimark` bucket exits cleanly with 152
passes, zero failures, and 69 intentional architecture skips. Both the complete
AArch64 and Rosetta x86_64 ReleaseSafe suites pass. Linux glibc and musl x86_64
cross-builds also pass. The canonical native Linux peer was unreachable for
this final rerun, so the execution and timing evidence below is explicitly the
local x86_64-macos binary under Rosetta rather than a claimed native-Linux
measurement.

The CI-shaped baseline and forced-Ohaimark test262 sweeps both finished at
48,517 pass / 1,324 fail. Their 48,517-line pass lists are byte-identical at
SHA-256
`52146dd368643d2eedd21f60c731589f7fd6a0245dadeb26f8cdd70a95ec2ae3`.
The forced run attempted 222,050 compilations, published 10,462 (4.71%),
installed 3,073 KiB, and recorded 317,428 generated entries, 313,258 normal
completions, and 2,720 guard exits. Compilation consumed 43,215 ms in aggregate
at 194 us average; 30,400 refusals occurred in IR construction and 181,188 in
codegen. The pass-set equality, rather than the equal aggregate count alone,
is the semantic gate.

The local 30-pair function-entry rollout produced:

| Fixture | Median T2/lower-tier | Ratio IQR | Publication result |
|---|---:|---:|---|
| `number_mul` | `0.996x` | 15.2% | 1 published / 1 refused, 0 exits |
| `number_div` | `0.987x` | 11.0% | 1 published / 1 refused, 0 exits |
| `named_load` | `0.961x` | 11.2% | 1 published / 1 refused, 0 exits |
| `branch_eq` | `0.936x` | 17.3% | 1 published / 1 refused, 0 exits |
| `call_refusal` | `0.936x` | 9.1% | 2 published / 1 refused, 4 exits |

The geometric mean was `0.963x` and the worst fixture `0.996x`. The probes
attempted 11 compilations, published six, refused five, compiled in 1.960 ms,
installed 0.9 KiB, and completed 24,997,383 of 24,997,387 entries; the four
remaining entries were the expected `call_refusal` guard exits.

The matching loop-header rollout produced:

| Fixture | Median T2+OSR/lower-tier | Ratio IQR | Publication result |
|---|---:|---:|---|
| `count_loop` | `0.368x` | 14.2% | 1 published, 0 exits |
| `sum_loop` | `0.311x` | 12.6% | 1 published, 0 exits |
| `mul_acc_loop` | `0.338x` | 11.4% | 1 published, 0 exits |

Its geometric mean was `0.338x` and the worst fixture `0.368x`; all three
attempts published, compilation took 3.758 ms, installed code totaled 2.8 KiB,
and every entry completed. These translated measurements are a positive local
regression gate; the earlier native-Linux post-handoff measurements remain the
portable performance checkpoint until the peer is reachable again.

#### Native rollout refresh (2026-08-06)

Revision `6e125807ba93` was rerun at the canonical 30-pair budget on the Linux
x86_64 benchmark box and on the Darwin arm64 development host. Ratios remain
host-local; both hosts used Zig `0.17.0-dev.1275+59a628c6d` and included
compilation in the optimized sample.

| host | function-entry geometric mean | entry worst | OSR geometric mean | OSR worst |
|---|---:|---:|---:|---:|
| Linux `6.8.0-136-generic x86_64` | `0.975x` | `1.007x` (`named_load`) | `0.203x` | `0.236x` (`count_loop`) |
| Darwin `25.6.0 arm64` confirmation | `0.985x` | `1.034x` (`number_div`) | `0.204x` | `0.223x` (`mul_acc_loop`) |

The x86 entry probe attempted 11 compilations, published six, refused five,
compiled in 0.442 ms, installed 0.9 KiB, and completed 24,997,383 of
24,997,387 entries; the four remaining entries were the expected
`call_refusal` exits. Its OSR probe published all three attempts in 0.443 ms,
installed 2.8 KiB, and completed every entry without an exit.

The first arm64 entry pass landed at `0.978x` geometric mean but missed the
per-fixture gate: `named_load` measured `1.067x` with 15.4% ratio IQR while
the host showed broad timing variance. After an idle interval, the full
30-pair confirmation above moved that fixture to `0.995x`; every fixture then
met the `1.050x` worst-case limit. The arm64 entry probe compiled in 0.454 ms
with the same six publications, five refusals, and four expected exits. Its
OSR probe published all three attempts in 0.328 ms, installed 2.1 KiB, and
completed every entry. The low-noise native x86 result is the primary gate;
the two disclosed arm64 passes bound the current host variance.

The companion interleaved x86 A/B against merge base `7949d5f8` exposed a
different production-posture cost that the function-shaped rollout fixtures
do not cover. Four top-level arithmetic scripts regressed despite broad host
noise: `arith_loop` `1.195x`, `div_loop` `1.400x`, `mod_loop` `1.233x`, and
`mul_loop` `1.295x`. Lantern-only rows were largely flat; `mod_loop` was the
one threshold-clearing exception at `1.100x`. A focused current-revision
`arith_loop` probe recorded one Ohaimark compile attempt, one refusal, zero
publications, and zero generated entries. The generated x86 code therefore
passes its rollout gate, but the default-on backedge/refusal policy still adds
measurable cost to a hot top-level loop that cannot enter T2. Keep this as an
open performance gate before treating x86 default-on parity as complete.

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
8b. **Loop-header OSR, shipping default-on:** verified OSR-entry metadata for
   every eligible loop header, AArch64 and x86_64 entry stubs in the same
   transactional code allocation as function entry, Lantern and Bistromath
   backedge drivers, reuse of guard-exit / safepoint recovery, and anti-thrash
   strikes. The AArch64 and helper-free x86_64 subsets passed independent exact
   differential, ReleaseSafe, and natural-threshold rollout gates (see §6).
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
   inlining, remaining opcode families and ISA targets, native post-call
   continuations, and native handler-region compilation.

## 6. Loop-header on-stack replacement (OSR)

Status: **implemented, default-on.** Function-entry T2 alone cannot win
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
   unsupported opcodes stay out. A handler-bearing chunk may compile its normal
   CFG and eligible loop headers, but exception-only handler blocks remain
   Lantern-owned; an explicit throw reconstructs the faulting frame and replays
   there. OSR materialization errors still refuse the whole T2 compile for that
   chunk without mutating the live frame.

6. **Default-on policy.** `Realm.ohaimark_osr_enabled` defaults true and is
   inherited by `initChild`, subordinate to the master JIT/T2 gates. The
   production CLI's natural Ohaimark posture therefore includes loop-header
   OSR; `--no-ohaimark-osr` isolates function-entry compilation for diagnosis.
   `--ohaimark-osr` remains an explicit compatibility no-op. The test262
   `--ohaimark` and forced fuzz postures follow the same default; their
   `--no-ohaimark-osr` switches retain an entry-only comparison when needed.

#### Rejected alternatives

- **Separate OSR-only compile unit** (compile only the loop body): doubles the
  pipeline and breaks frame-state consistency with function-entry code; Maglev
  and JSC compile the whole method with an extra entry.
- **OSR into a new native frame format:** violates the frame-identity rule
  that makes GC, deopt, and the watchdog tier-agnostic.
- **Enter at arbitrary bytecode offsets:** forbids standard loop opts; every
  production engine restricts optimizing OSR to headers (or rarer special
  points).
- **Premature default-on before gates passed:** the validation-only
  `--ohaimark-osr` posture was retained until the recorded graduation evidence
  below completed.

#### Graduation record (2026-07-19)

The forced baseline-vs-T2+OSR test262 pass sets are byte-identical at 48,517
paths (SHA-256 `52146dd368643d2eedd21f60c731589f7fd6a0245dadeb26f8cdd70a95ec2ae3`).
ReleaseSafe `--gc-threshold=1` Object, Array, and object-expression buckets
completed with no GC verifier failure or host crash. The initial Fuzzilli
value-differential candidate reduced to `new Date(); v++` and exposed a
determinism-shim gap, not a JIT divergence; the shared `--diff` prelude now
pins zero-argument Date construction as well as `Date.now`. The minimized
artifact replayed cleanly, and a fresh 6m30s forced Ohaimark+OSR campaign ran
250 samples / 11,388 executions with zero crash and differential artifacts.
The natural-threshold 30-pair rollout measured `0.122x` geometric mean and
`0.140x` worst fixture, both inside the `≤1.000x` / `≤1.050x` limits. OSR
therefore graduated to the default production T2 posture.

## 7. Declined for v1

- AST-to-IR compilation: bytecode is already the semantic and profiling unit.
- Sea-of-nodes IR, tracing, or global type inference: unnecessary complexity
  for the low-latency tier Cynic needs first.
- Copying raw GC pointers into optimizer snapshots or machine-code literals.
- Treating exception handlers as ordinary CFG successors.
- Background compilation before synchronous compile cost is measured.
- Deoptless continuation specialization: interesting later, but conventional
  deopt is the smaller correctness surface for the first tier.
- Default-on OSR without retaining the §6 validation record and opt-out.
