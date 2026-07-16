# Ohaimark optimizing JIT

Status: **ADR accepted; bytecode/feedback/SSA, pure specialization, and
logical deopt metadata landed** (2026-07-16). Physical recovery metadata,
machine-code lowering, runtime deoptimization, and tier-up are not shipped yet.

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
returns.

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
synthetic accessor value; future code must validate through the live cell.
Cold and invalidated cells remain generic. A stale or malformed feedback index
rejects the graph instead of indexing unchecked memory.

### 3.4 Exceptions stay explicit

Liveness exposes protected-range edges as `exception_edges`, separately from
normal successors. An exception edge is not an ordinary branch: the unwinder
defines the handler accumulator, catch register, completion state, and frame
depth. The first graph builder returns `error.UnsupportedExceptionFlow` for a
chunk with handlers. A later phase will add an exceptional environment and
deopt state before enabling those chunks; silently treating handler edges as
normal phis is forbidden.

### 3.5 Fallback is part of correctness

`UnsupportedOp`, `UnsupportedExceptionFlow`, malformed internal bytecode, an
oversized graph, or allocation failure all abandon Ohaimark compilation. Once
tier-up is wired, the chunk remains executable in Bistromath/Lantern. These are
normal compiler outcomes, never `panic`, `unreachable` on input-dependent
state, or partial optimized execution.

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

This is deliberately compiler-level metadata, not an executable deoptimizer.
Representation selection and register allocation must translate each
`ValueId` recovery to a tagged/unboxed machine register or spill location.
Only then can a no-allocation runtime path reconstruct the existing Lantern
frame. A graph evaluator must first prove graph execution and recovery agree
with Lantern for the supported subset.

## 5. Delivery order

1. **Front-end substrate, shipped:** exceptional CFG edges, immutable typed-IC
   snapshots, linear block-argument SSA, loop/diamond tests, graceful reject.
2. **Typed specialization, initial pass shipped:** small value lattice,
   fixed-point block-argument facts, IC-to-assumption transpilation,
   semantics-safe int32 folding, and explicit lowering choices.
   Representation selection beyond those choices and local DCE remain.
3. **Deopt first, logical metadata shipped:** pre-operation frame-state
   capture, liveness-compacted translation stream, and metadata verifier.
   Physical recovery locations, runtime reconstruction, and graph-vs-Lantern
   differential tests remain.
4. **AArch64 lowering:** register allocation, safepoints, guard exits, code
   ownership, and a disabled-by-default tier-up path.
5. **Gates and tuning:** full test262 pass-set differential, SES suite,
   GC-pressure runs, fuzzing, and compile-time/code-size/performance budgets.
6. **Only if measured:** background compilation, polymorphic feedback,
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
