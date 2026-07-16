# JIT tiers — Bistromath (T1), Ohaimark (T2), Spasm (wasm T1), and the shared substrate

Status: **Bistromath shipped and on by default** (2026-06; `--no-jit`
opts out, the CI differential gates merges). Ohaimark's feedback/SSA,
specialization, representation-selection, and logical deopt-metadata front end
plus stable physical deopt homes, graph/Lantern differential evaluation, and
abstract register/spill allocation plus AArch64 frame/edge lowering have
landed. Transactional prologue/epilogue emission now has native AArch64 proof,
and typed moves, folded-value returns, checked int32 arithmetic/control, and
frame-reconstructing guard exits execute natively in tests. Guarded
own/prototype/synthetic named loads now execute through live typed IC cells.
Safepoints, code ownership, and runtime tier-up remain future work; Spasm's
delivery state is tracked below. The document doubles as the design record that
pinned the architecture before the first emitter was written and as the delivery ledger
(the "Delivery order" section tracks what each increment shipped). It is the
durable output of a prior-art survey (per
[handbook/prior-art.md](handbook/prior-art.md)) across V8, JSC,
SpiderMonkey, Hermes, LuaJIT, YJIT/ZJIT, CPython's copy-and-patch
JIT, LibJS, ChakraCore, wasmtime (Winch), Wizard, and the papers in
§15. [ARCHITECTURE.md](ARCHITECTURE.md) names the tiers (Lantern T0 →
Bistromath T1 at M5 → Ohaimark T2 at M6) and
[ROADMAP.md](ROADMAP.md) "Future work" sketches them in two bullets;
this is the actual design.

Pinned here:

- the tier model and what each tier is *not* allowed to be (§4, §5);
- Bistromath's frame-identity rule — T1 frames ARE Lantern frames (§4.2);
- data-driven inline caches — T1 reuses the existing `ICCell`s, no
  code patching (§4.4);
- a single shared codegen substrate under both the JS tiers and
  Spasm, the wasm baseline — and the exact reuse boundary (§7);
- the JS↔wasm call-boundary fast path — per-signature thunks in the
  shared code region, IC-integrated dispatch on both sides (§7.1);
- executable-memory mechanics for macOS/arm64 + Linux (§8);
- the verification gate: differential test262 at force-compile, plus
  gc-stress (§10).

Deferred, each with an owner section: Ohaimark runtime deoptimization/codegen
([ohaimark.md](ohaimark.md) — §5), per-realm code-cache scoping (the ADR
[multi-realm.md](multi-realm.md) already reserves — §14), x86_64
port timing (§8), background compilation (§14).

## 1. Why a JIT, and why now

The interpreter arc is closing. The IC family
([inline-caches.md](inline-caches.md)) is shipped through Tier 1,
`loop_inc_lt` fusion landed, the frame register pool and
`value_stack` landed, and ROADMAP "Performance" item 4 already
names the stopping point: the remaining `arith_loop` distance to
JSC's hand-written-assembly LLInt "without a JIT is deep,
diminishing-returns micro-tuning of the dispatch core … the point
where a baseline JIT becomes the better investment."

Two more forcing facts from the survey:

- The gap is an order of magnitude, and it is not interpreter-shaped.
  Interpreters sit ~10× under optimizing-JIT code; baseline JITs
  ~2–3× under (Titzer, arXiv:2305.13241 — the same numbers
  [wasm-engine.md](wasm-engine.md) §3 already cites for Sarcasm).
  No amount of dispatch tuning crosses that.
- An IC-rich baseline captures a startling fraction of the total.
  Deegen's LuaJIT-Remake baseline JIT (interpreter + copy-and-patch
  baseline with full ICs, no optimizing tier) lands only 33% behind
  LuaJIT's *optimizing* tracing JIT (arXiv:2411.11469). SpiderMonkey's
  ablation is the same story from the other side: their baseline tiers
  *without* ICs run 0.57–0.79× the plain C++ interpreter — slower —
  and 1.6–3.4× with them (MPLR '23). The ICs are the tier; Cynic
  already owns the ICs.

Counter-evidence was weighed, not skipped: LibJS built a JIT in 2023
and deleted it in 2024 (interpreter optimization matched it; ~45% of
V8's CVEs are JIT-adjacent per Microsoft's SDSM data); CPython's
copy-and-patch JIT has yet to beat its own tail-call interpreter by
more than ~1.5% geomean. The lessons are absorbed as constraints
(§4's "boring T1", §10's differential gate, a permanent
`--no-jit` mode) rather than as a reason to stop — Cynic's position
differs from both: unlike LibJS it is not racing a browser's feature
treadmill, and unlike CPython its semantics don't hide every win
behind refcounting and finalizers. The closest cousin is Hermes,
which held the no-JIT line for five years and then shipped exactly
the tier this doc specifies: an arm64-only, no-IR,
bytecode-to-machine-code translator with fast/slow path splits.

## 2. What the survey found

One-line tier maps, current as of 2026:

| Engine | Interpreter | Baseline | Mid | Top | Wasm |
|---|---|---|---|---|---|
| V8 | Ignition | Sparkplug (no IR, frame-mirrors Ignition) | Maglev (SSA CFG) | TurboFan/Turboshaft | Liftoff → Turboshaft |
| JSC | LLInt (offlineasm) | Baseline (template MASM) | DFG | FTL (B3→Air) | IPInt → BBQ (direct-emit) → OMG (B3) |
| SpiderMonkey | C++ interp → Baseline Interpreter (generated) | Baseline JIT | — | Warp/Ion (MIR/LIR) | Rabaldr → Ion |
| Hermes | register-VM interpreter | arm64 translator JIT (2024) | — | — | — |
| Ruby | YARV | YJIT (LBBV) | — | ZJIT (SSA, 2025) | — |

Five conclusions carry the design:

1. **Baseline frames must be bit-identical to interpreter frames.**
   Sparkplug frames mirror Ignition's exactly — "the bytecode
   compiler has done the hard work of register allocation" — buying
   OSR in both directions, unchanged GC stack walking, unchanged
   unwinding, and deopt-target simplicity, for free. JSC says the
   same ("LLInt runs on the same stack … makes LLInt→Baseline OSR
   trivial"); SpiderMonkey's interpreter frame is its baseline frame
   plus a pc field. Every production engine converged here.
2. **The baseline tier is "builtin calls and control flow" — no IR,
   one pass.** Sparkplug is "a switch statement inside a for loop."
   JSC rewrote its wasm baseline *twice away from* IR (B3 → Air →
   direct MacroAssembler emission) because baseline latency is
   dominated by IR construction. The win is eliminating
   decode/dispatch and inlining the IC/Smi fast paths — not codegen
   cleverness. Expected execution win: Sparkplug is +45% over
   Ignition on JetStream; JSC Baseline ~2.3× LLInt; SM Baseline
   2.5–3.4× their C++ interpreter.
3. **Speculation lives in the optimizing tier, priced honestly.** A
   JSC OSR exit costs ~2500 ns against ~1.5 ns saved per elided
   check — speculation pays only above ~99.9% confidence, which is
   why feedback (ICs) must mature before the optimizer consumes it,
   why thresholds back off exponentially after a jettison (2^R), and
   why >N bailouts must invalidate (SM: 10). The baseline tier
   therefore speculates on *nothing*: IC misses take a helper call,
   never a deopt.
4. **One structured IC substrate feeds every tier.** SpiderMonkey's
   CacheIR is the strongest architectural idea in the field: ICs as
   data consumed by the interpreter and baseline, then *transpiled*
   into the optimizing IR — no parallel type system (Warp deleted
   TI for −8% memory, +10-12% Speedometer, and an invalidation-storm
   class removed). Cynic's `ICCell`s are not an IR, but the same
   layering applies: T1 executes against the cells; T2 reads them as
   feedback. Polymorphic ICs (deferred in
   [inline-caches.md](inline-caches.md) Tier 3 precisely because
   "their main consumer is JIT speculation") become T2-era work.
5. **Method JITs won; both shortcut families have known ceilings.**
   Tracing died for JS (TraceMonkey: trace explosion on branchy
   code, 17k LOC deleted). LBBV (YJIT) buys superb warm-up but
   Shopify's ZJIT pivot (2025) concedes its ceiling: block-granular
   codegen blocks textbook optimization. Copy-and-patch compiles
   absurdly fast (Deegen proves it can host real ICs) but CPython's
   experience shows the backend was never the bottleneck — and a
   stencil toolchain is a worse fit for a Zig tree than a few
   thousand lines of hand-written encoder. Boring single-pass
   template T1 + boring SSA-CFG method T2 (never sea-of-nodes —
   V8 is currently paying to leave it) is the convergent answer.

## 3. What Cynic already gives the tiers

Substrate facts the design builds on (verified 2026-06):

- **Value representation is JIT-ready.** 64-bit NaN-boxed
  `extern struct` ([value.zig](../src/runtime/value.zig)) whose doc
  comment has promised since day one that "the JIT (M5+) … can read
  these fields by offset." Int32 fast path is a tag test
  (`0xFFFB` high bits); doubles are unboxed with the
  `double_encode_offset` trick — both inline to 2–3 instructions.
- **The bytecode is the IR.** Register file + accumulator, one-byte
  opcodes, relative `i16` jumps, IC-cell indices (`u16`) baked into
  property/call operands ([op.zig](../src/bytecode/op.zig)).
  ARCHITECTURE.md: "Bytecode is the source of truth for IR —
  Bistromath and Ohaimark will consume bytecode + profile data, not
  the AST." The register allocation T1 needs was done by the
  bytecode compiler.
- **Frames are explicit and GC-walked.** `CallFrame` structs on a
  frames list; per-frame `registers: []Value` from the
  `value_stack` / `frame_pool`; `realm.frame_stacks` makes every
  live frame's registers + accumulator GC roots
  ([handbook/gc.md](handbook/gc.md)). No native-stack scanning
  exists or is needed.
- **Metla is non-moving.** Mark-sweep over per-kind young/mature
  lists; pointers are stable for an object's lifetime. JIT code may
  embed heap pointers (shapes, protos, chunk constants) as guard
  immediates without revalidation or relocation. Write barriers are
  already funneled through `Heap` helpers; the dirty-list remembered
  set doesn't care who performed the store.
- **Shapes are arena-allocated, realm-lifetime.** A `*Shape` baked
  into code never dangles. IC cells weak-clear their heap pointers
  between mark and sweep — a protocol T1 inherits untouched by
  reading cells from memory (§4.4).
- **Slow paths are already factored for a second consumer.**
  [lantern/helpers.zig](../src/runtime/lantern/helpers.zig) opens
  with: "each function is callable from the interpreter, the JITs
  (when they land), or any built-in." `arith.zig`, the IC slow
  paths (`slowLdaGlobal` et al.), and `call.zig` are the T1 runtime
  library, already extracted.
- **Safepoints exist and are documented.** The dispatch-loop top is
  "the only safe point Cynic has" (gc.md): GC triggers
  (`allocs_since_gc` / `bytes_since_gc`), the test262
  `realm.step_budget`, and the watchdog's `realm.host_interrupt`
  all key off it. §4.6 moves this contract to compiled back-edges.
- **Sarcasm's compiled artifact anticipates the tier.**
  [wasm-engine.md](wasm-engine.md) §10: "The real throughput jump
  comes from a baseline JIT tier later … which would consume the
  validated module + side-table." The §10 operand-cell-narrowing
  decline explicitly parks the value-representation question "as
  part of a baseline JIT's value representation" (§6).

The one gap this survey found — no profiling state — is now
closed: `Chunk.JitState` carries the warmth counters (entries +16,
including §15.10 PTC re-entries; back-edges +1) and the tier state
(§4.7), measured sub-noise on the bench suite.

## 4. Bistromath — the T1 baseline JIT

One sentence: a single forward pass over Lantern bytecode emitting
machine code per opcode — inline fast paths for Smi arithmetic and
IC hits, helper calls for everything else — into a function whose
execution state *is* a Lantern `CallFrame`, so the interpreter, the
GC, OSR, and the watchdog cannot tell (and don't care) which tier is
driving.

What Bistromath is **not**: no IR, no register allocation (beyond a
handful of pinned machine registers), no type speculation, no deopt
metadata, no inlining, no code patching. Every one of those is
either free via frame identity or deferred to Ohaimark. The compiler
is a loop over opcodes calling per-op `emit*` functions — the
Sparkplug shape.

### 4.1 Compilation unit and tier state

The unit is the `Chunk` (function template), not the closure —
compiled code must be closure-independent (env pointer, `this`,
realm all arrive via the frame), so all closures over one template
share one code object, exactly as all closures share the chunk's IC
cells today. Tier state rides the same mutable-side-state pattern as
`Chunk.inline_caches`:

```zig
// On Chunk, mutable side-state (chunk stays semantically immutable):
warmth: u32 = 0,            // entry +16, back-edge +1 (§4.7)
tier: enum(u8) { cold, compiled, dont_compile } = .cold,
entry: ?*const anyopaque = null, // type-erased EntryFn; the code
                                 // bytes live in the allocator (§8)
```

`dont_compile` is the permanent opt-out for chunks the v1 compiler
doesn't support (§4.5) and the backstop after a compile failure
(OOM in the code allocator → stay interpreted; never abort).

### 4.2 The frame-identity rule

A Bistromath activation uses the same `CallFrame`, acquired the same
way (`value_stack` bump or `frame_pool`), pushed on the same frames
list, with `registers: []Value` in the same pooled slice. Machine
code holds the frame pointer and the register-file base pointer in
pinned registers; the accumulator lives in a pinned machine register
and is flushed to `frame.accumulator` at every safepoint, call, and
exit — the same write-back discipline the interpreter's local
already follows.

What this buys, all at once:

- **GC correctness with zero new machinery.** Every live `Value` a
  compiled function holds sits in the register file or the flushed
  accumulator — both already walked by `Realm.collectGarbage` via
  `realm.frame_stacks`. No stack maps, no conservative scanning, no
  new root source. (This is the Sparkplug/Wizard play adapted to
  Cynic's heap-slice register files.)
- **OSR both directions is a jump** (§4.6): same frame, two drivers.
- **Tier-down on exception is trivial** (§4.5).
- **The watchdog and step budget keep working** (§4.6).
- **`max_call_frames` (1024) and PTC semantics are preserved**
  because frame push/pop stays in the same helpers (§4.5).

The cost is equally explicit: values live in memory, not in machine
registers across opcodes. T1's win is dispatch elimination + inlined
fast paths, not register residency — that is the measured Sparkplug
trade (+45% over Ignition), and register residency is exactly what
Ohaimark is for.

### 4.3 What gets inlined

Per opcode, the emitter writes either an inline fast path with a
helper-call slow path, or a bare helper call:

- **Smi arithmetic/compare** (`add`, `sub`, `lt`, `loop_inc_lt`, …):
  inline both-int32 tag check + op + overflow check; overflow or
  non-int32 falls into the existing `arith.zig` helper. The
  NaN-boxed tag tests are 2–3 instructions on arm64.
- **Register moves, constants** (`ldar`, `star`, `lda_smi`,
  `lda_constant`, `lda_undefined`, …): inline loads/stores against
  the register file — these opcodes exist only to feed the
  dispatch loop, and they vanish into addressing modes.
- **Property ICs** (`lda_property`, `sta_property`, `lda_global`,
  …): inline the cell-hit fast path (§4.4); miss → the existing
  slow-path helper (which also fills the cell, exactly as today).
- **Calls** (`call`, `call_method`, `call_property`, `new_call`):
  inline the `CallICCell` callee check, then hand off to the
  call helpers (§4.5).
- **Jumps**: relative branches over the emitted code; back-edges
  carry the safepoint check (§4.6).
- **Everything else** (`typeof`, `instanceof`, iterator protocol,
  destructuring ops, env ops, …): helper call, one per opcode,
  reusing the interpreter's factored functions. Correct first;
  promote individual ops to inline fast paths only when the bench
  suite names them.

### 4.4 Data-driven ICs — no code patching

T1 fast paths **load IC state from the existing `ICCell` /
`CallICCell` memory** (guard fields compared against runtime values)
rather than burning shapes into instruction immediates and
repatching on transition. Three reasons, each independently
sufficient:

- The GC weak-clear protocol (cells' heap pointers nulled between
  mark and sweep) keeps working verbatim. Patched-in pointers would
  need a code-patching GC hook, W^X toggles inside the GC, and
  icache flushes — a whole subsystem.
- SpiderMonkey ships exactly this ("baseline ICs call through a data
  pointer, so attaching a stub never re-protects code") for W^X
  hygiene; on Apple Silicon every patch costs a
  `pthread_jit_write_protect_np` round-trip plus
  `sys_icache_invalidate` (§8), so patch-free fast paths are the
  cheap design, not the slow one.
- Measured: Poirier/Rohou/Serrano (arXiv:2502.20547) removed IC
  memory loads via binary patching in an AOT JS compiler and found
  **no execution-time win** on modern x86-64 — well-predicted IC
  loads hide in out-of-order execution. The load is not the cost.

A cell hit in T1 is therefore: load `cell.shape`, compare against
`receiver.shape`, load `cell.slot`, indexed load from
`receiver.slots` — identical structure to the interpreter's hit,
minus the dispatch around it, plus no call boundary.

### 4.5 Calls, tail calls, exceptions, generators — the v1 scope

**Calls** stay helper-mediated: compiled code materializes the
arg window (it's already in the register file — the bytecode
compiler laid it out), flushes the accumulator, and calls the
existing `call.zig` entry points, which push the callee frame and
dispatch it — into its own compiled code if `chunk.code != null`,
else into Lantern. JIT→JIT calls thus recurse on the native stack;
the existing address-based `stack_guard.nearLimit` check (already
the contract for native→JS re-entry) is emitted in every compiled
prologue, throwing the same catchable `RangeError`. Direct
JIT→JIT call fast paths (skipping the helper) are a later, measured
optimization.

**Proper tail calls** (§15.10 — shipped in Lantern as frame-reuse
on `tail_call`) must not regress: a compiled `tail_call` either
(a) jumps to its own entry after rebuilding the frame in place
(self-recursion — the hot case, e.g. the `tail_recursion` bench), or
(b) returns to the driver with a "tail-dispatch" request so the
callee runs without growing the native stack (cross-function PTC).
The driver is the same small loop that enters compiled code from
`callJSFunction`; PTC is the one place v1 keeps a trampoline.

**Exceptions share Lantern's unwinder and re-enter compiled handlers.**
The compiler records every `chunk.handlers[*].handler_pc` and emits the
same frame-compatible prologue-and-jump stub used for OSR and post-call
continuations. When compiled code reports a throw, the driver finds the
first §14.15 catch/finally handler in the frame subtree it owns, invokes
`unwindThrow` exactly once to install catch bindings, finally completion
state, barriers, and `frame.ip`, then jumps to that handler's compiled
stub. Termination, an async Promise-wrap boundary, a cold handler, or a
handler below the driver's frame subtree takes the existing Lantern path.
This keeps exception semantics in one implementation while removing the
hot-throw tier-down/re-enter loop.

**Excluded from v1 compilation** (per-chunk `dont_compile`, decided
in one pre-pass over the opcodes): generator and async-function
chunks (suspend/resume rebuilds frames around `JSGenerator`-owned
register files — compile these later, the way every engine did
generators last), and any chunk containing an opcode the emitter
doesn't support yet. One carve-out lives *inside* the supported
set: the emitter elides a zero-slot `make_environment` as a no-op
(no own bindings to store), but `lda_env`/`sta_env` carry depth
operands computed relative to that pushed env — so a chunk holding
both would resolve every env read one scope too shallow. The
pre-pass therefore `dont_compile`s any chunk that mixes
`make_environment` with an env read/write; the §10 differential
caught the gap when a 0-slot block-scope env shared a chunk with
`lda_env ^1` reads of an outer closure var and miscompiled an
`await using` async path (a spurious `throw undefined`).
Function-granularity fallback means the
compiler never needs a mid-function bailout mechanism — the absence
of which is most of why T1 stays small.

### 4.6 Safepoints, the watchdog, and OSR

The robustness contract (AGENTS.md "never abort the host") and the
harness watchdog both assume execution periodically passes a
checkpoint. In Lantern that's the dispatch-loop top; in Bistromath
it is **every loop back-edge and every call boundary**:

- back-edge: decrement `realm.step_budget`, test
  `realm.host_interrupt`, test the GC counters
  (`allocs_since_gc` / `bytes_since_gc` against thresholds) —
  a handful of instructions on the loop path, exactly the
  per-iteration cost the interpreter already pays;
- calls and allocation helpers check natively (they're the same Zig
  functions the interpreter uses).

A compiled infinite loop therefore still hits the step budget and
the watchdog; `--gc-threshold=1` stress (the
[/gc-stress](../.claude/commands/gc-stress.md) workflow) exercises
compiled frames the same as interpreted ones. **Any future emitter
change that adds a loop without a back-edge check is a host-safety
bug**, same class as an unrooted handle.

**OSR entry** (interpreter → T1 mid-loop): when a back-edge in
Lantern finds the chunk compiled, jump into the code at that
bytecode offset — frame identity makes this a lookup in a small
`bytecode offset → code offset` table (recorded for loop headers
only) plus a tail-jump. V8 gates wasm OSR out entirely and JS OSR
behind urgency heuristics; Cynic gets it nearly free, but it still
ships in step 3, not step 1 (§12).

**Tier-down OSR** (T1 → interpreter) exists from day one via the
exception path (§4.5) and is otherwise unneeded: T1 speculates on
nothing, so nothing can fail mid-function.

### 4.7 Tier-up policy

Counters follow the JSC/SM structure with Cynic-sized constants
(all named in one place, tunable by flag):

- `warmth += 16` at function entry, `+= 1` per back-edge
  (JSC weights 15/1; round to a shift);
- compile when `warmth >= 512 + 8 × chunk.code.len` — size-scaled
  so a 4-line helper compiles after ~30 calls but a 3000-byte
  function waits for real heat (V8 scales budgets by bytecode
  length; constants here are starting points for the bench suite,
  not gospel);
- compilation is **synchronous** on first crossing — Sparkplug
  compiles synchronously because baseline compilation is nearly
  free; if compile time ever shows up in `/perf`, batching (V8) or
  a thread (JSC) are known answers, deferred (§14);
- a failed compile (allocator exhaustion) sets `dont_compile`;
  there is no recompilation ladder until Ohaimark exists.

## 5. Ohaimark — T2 front end and checked execution subset landed

The accepted design and delivery gates are in
[ohaimark.md](ohaimark.md). The first checkpoints now ship the immutable
typed-IC feedback snapshot, a linear CFG SSA graph with block arguments, a
pure specialization plan carrying value facts and pointer-free IC assumptions,
a verified tagged/int32 representation plan with explicit per-use conversions,
and logical deopt metadata mapping Lantern frame slots to SSA values. Physical
metadata gives every referenced non-constant value a stable tagged or int32
spill home and records the required boxing recipe. A bounded graph evaluator
now proves checked-int32 success and physical-deopt Lantern resumption against
full Lantern runs. A deterministic linear-scan plan assigns bounded abstract
registers or representation-partitioned spills, rematerializes immediates, and
reuses stable homes when a recoverable value spills. A physical plan now maps
six values to `x23`-`x28`, lays out aligned tagged/int32 frame regions, and
resolves parallel edge moves through a dedicated cycle scratch while preserving
boxing conversions. The native prologue/epilogue now saves that convention,
chunks aligned spill reservation, and initializes tagged slots safely. Typed
register/stack moves and folded returns now emit, including int32 boxing, while
heap constant-pool literals refuse raw code embedding. A verified AArch64 graph
compiler now emits checked int32 add/sub/mul, constant and int32 control flow,
parallel edge transfers, stable deopt-home writes, normal returns, and cold
guard exits. An exit decodes the physical recipe at compile time and writes the
pre-operation accumulator, live registers, and bytecode offset directly into
the existing Lantern frame before returning `resume_interp`; the bailout path
allocates nothing and calls no helper. The graph compiler also emits specialized
own-data, prototype-data, and frozen synthetic-accessor named loads. It validates
the snapshot's realm-stable shape/slot/revision facts against the live
chunk-owned `LoadICCell`, then reads the GC-managed prototype or synthetic value
only through that cell. Shape, holder, prototype-identity, revision, mode, or
cell invalidation misses use the same pre-operation guard exit; native arm64
tests resume Lantern and compare exact results. Safepoints, executable-code
ownership, and runtime tier-up remain disabled. The decisions Bistromath must
preserve are:

- **Method JIT over a CFG SSA IR with linear storage.** Not sea of
  nodes (V8 is migrating off it: 3–7× worse cache locality, "error
  prone, hard to maintain", Turboshaft's CFG halved compile time);
  not LBBV (ZJIT's pivot conceded the ceiling); not tracing
  (TraceMonkey's grave is well marked). Wimmer-Franz SSA linear
  scan is the regalloc starting point.
- **Feedback = the IC cells + shapes, transpiled** — the CacheIR
  lesson. T2 reads each site's cell (and, by then, a small
  polymorphic chain per [inline-caches.md](inline-caches.md)
  Tier 3) and emits guarded fast paths from it. No global type
  inference, ever (Warp's TI removal is the cautionary tale).
- **Deopt reconstructs Lantern frames, not Bistromath frames** (SM
  bails to its interpreter; T1 code stays discardable). Deopt
  metadata is a compact translation stream per deopt point — frame
  stack + per-slot locations — the V8 format, the proven shape.
  ARCHITECTURE.md's "deopt can fall all the way back to Lantern
  (T0)" was already normative; frame identity (§4.2) makes the
  reconstruction target well-defined today.
- **Invalidation via the epoch/revision counters that already
  exist** (`proto_struct_epoch`, `proto_revision_counter`,
  `GlobalBindings.decl_revision`) promoted into per-assumption
  watchpoint lists when measurement demands precision — the
  global-epoch-vs-per-proto-cells analysis in
  [inline-caches.md](inline-caches.md) already did this dance for
  the interpreter and lands the same way.

## 6. Spasm — the wasm baseline compiler (T1)

[wasm-engine.md](wasm-engine.md) §3/§10 already commits to the
tier and its inputs: a single-pass compiler consuming the
**validated module + the O(1) branch side-table**, exactly where
V8/JSC/SM put Liftoff/BBQ/Rabaldr. The survey settles its shape:

- **Liftoff/Wizard-SPC hybrid.** One forward pass over validated
  bytecode; abstract state = the operand stack as
  `{const, register, stack-slot}` locations with a small
  register-cache state machine; constants fold into consumers;
  **spill-everything at control-flow merges and loop headers** (the
  Liftoff simplification — adapt-to-snapshot merges are a measured
  follow-up, not v1). Titzer's CGO'24 ablations rank the choices:
  constant tracking > multi-value-per-register allocation > folding
  > instruction selection; v1 takes the first, sketches the second,
  defers the rest.
- **The side-table is reused as the compiler's control-flow oracle**
  — Wizard-SPC precedent: branch targets, arities, and pop counts
  are already computed; the compiler walks the same
  `⟨Δip, Δstp, valcnt, popcnt⟩` stream the interpreter does.
- **Value representation: native.** Scalars in registers / 8-byte
  spill slots, `v128` in 16-byte slots — this is the "as part of a
  baseline JIT's value representation" future the §10
  cell-narrowing decline reserved. Compiled frames live on the
  native stack (wasm has no `CallFrame` to mirror and no GC walking
  them).
- **Refs keep the pin-set discipline.** Compiled ref ops call the
  same pin/unpin helpers at the same points the interpreter does
  (`externref` liveness stays precise via
  `realm.wasm_externref_pins` + per-container marking — see
  wasm-engine.md §5); refs are cold in wasm hot paths, so
  helper-mediated ref traffic costs nothing measurable. **No GC
  stack maps in v1**; if precise stack scanning ever becomes
  necessary, Titzer's on-demand value tags (0.9–4.9% overhead vs
  2.4–3.3× for eager tagging) are the recorded escape hatch.
- **Tier-up at function entry only; no loop OSR in v1.** V8 and
  SpiderMonkey both ship wasm without tier-up OSR ("execution can be
  stuck in a loop in Liftoff code" — and they live with it); Cynic's
  in-place interpreter keeps frames simple, and the option to add
  Wizard-style frame-compatible OSR later is noted, not built.
  `return_call` (already shipped in Sarcasm per §11) compiles as a
  real jump — wasm PTC is mandatory and must not grow the native
  stack.
- **No ICs, no speculation, no deopt.** Wasm is statically typed;
  the baseline tier's only job is erasing dispatch. Expected
  multiplier per the SPC paper: 5–28× over an in-place interpreter
  (suite averages 10–15×), at 20–100 MB/s compile throughput.
  Against the 2026-06-10 `wasm-bench` baselines (38.82 ms/rep loop,
  116.85 ms/rep fib), §11's targets follow.

The name follows the family pattern twice over: **Spasm** buries
*asm* the way Sarc**asm** does, and the word is the design — a
quick reflexive contraction, over before deliberation starts. A
compiler whose whole point is to emit code before it has time to
think (one pass, no IR) could hardly be called anything else.

## 7. What JS and wasm share — and what they must not

The reuse question has a precise, triple-validated answer: **share
the emission and memory layers; never share the abstract state
above them.** V8 (one MacroAssembler under Sparkplug *and* Liftoff,
one Turboshaft backend under JS *and* wasm), JSC (one MacroAssembler
under Baseline/DFG/FTL *and* BBQ, B3/Air under FTL *and* OMG), and
SpiderMonkey (one MacroAssembler under everything on seven
architectures, MIR/LIR shared by JS-Warp and wasm-Ion) all drew the
same line.

| Layer | Shared? | Notes |
|---|---|---|
| Per-ISA assembler/encoder (`asm_aarch64`, `asm_x86_64`) | **yes** | one encoder, grown opcode-by-opcode on demand |
| MacroAssembler facade (labels, branches, veneers, ABI moves) | **yes** | the SM model; style: target-independent call sites, per-ISA bodies |
| Executable-memory allocator (W^X, MAP_JIT, icache flush, free) | **yes** | one reservation per Engine (§8) |
| Entry/exit thunks + driver loop infrastructure | **yes** (machinery) | instances differ per tier — JS thunks sync `CallFrame`, wasm thunks marshal cells; the per-signature JS↔wasm boundary thunks are first-class citizens here (§7.1) |
| Safepoint/interrupt convention (`host_interrupt`, budgets) | **yes** | same atomic, same back-edge discipline |
| Tiering counter/threshold machinery | **yes** (shape) | constants differ per tier |
| Disassembler + golden-test harness for emitters | **yes** | substrate ships with its own tests before any tier uses it |
| T2 SSA backend | **maybe, decide at M6** | TurboFan/B3/Ion all compile both; Maglev/Winch show staying single-language is also viable. Don't pre-pay. |
| Baseline abstract state / "register allocation" | **no** | JS T1 has none (frame-mirrored); wasm T1's operand-stack state machine is its whole compiler. V8 keeps Sparkplug and Liftoff separate above the assembler for exactly this reason. |
| Frame layout & calling convention | **no** | JS frames are `CallFrame`s with heap register files; wasm frames are native. |
| Value representation handling | **no** | NaN-boxed `Value` vs raw wasm scalars/cells. |
| ICs, shapes, feedback, deopt | **no** | JS-only by construction; bolting ICs onto the wasm tier would cost the compile throughput that justifies it. |

Concretely, the tree gains one shared directory and two consumers:

```
src/runtime/jit/            shared substrate (new)
  code_alloc.zig            reserve/commit, W^X toggling, icache flush,
                            per-code free; one region per Engine
  asm_aarch64.zig           encoder
  asm_x86_64.zig            encoder (second target, §8)
  masm.zig                  facade + ABI helpers + veneer/branch fixups
src/runtime/bistromath/     T1 JS baseline (per AGENTS.md repo map)
src/runtime/ohaimark/       T2 (M6; ADR first)
src/runtime/wasm/spasm.zig  Spasm — the wasm T1 baseline (§6)
```

### 7.1 The JS↔wasm call boundary

The boundary is a first-class performance surface, not an interop
afterthought — Cynic's edge target is JS glue around wasm kernels,
which means crossings inside hot loops. Engine history is blunt
here: before Firefox's 2018 overhaul a JS↔wasm call cost far more
than a JS↔JS call, and the fix brought most crossings to parity
with — sometimes under — a non-inlined JS→JS call
(hacks.mozilla.org, 2018); JSC later replaced its per-function
JS→wasm entry thunks with one shared metadata-driven entry because
thunk sprawl itself became the cost. Two fast tiers meeting at a
slow door would waste both.

Today (T0↔T0) a crossing is generic by design: an export is a
native-callback `JSFunction` that marshals `Value`s ↔ operand
cells through `builtins/webassembly.zig`; an import re-enters JS
through the host-function bridge ([wasm-engine.md](wasm-engine.md)
§8). At interpreter tier that's the right shape — marshalling is
noise against dispatch overhead. The moment either side compiles,
the boundary gets the same treatment as everything else:

- **Same code region, near calls both directions.** Compiled JS,
  compiled wasm, and every boundary thunk live in the one §8
  reservation, inside arm64 `BL` range — a warm crossing never
  takes an indirect hop through engine plumbing.
- **Per-signature thunks, compiled once, cached by canonical
  function type** (the same type identity `call_indirect` checks).
  The JS→wasm *entry thunk* unboxes arguments straight from the
  caller's register window into the wasm register convention and
  boxes the result back; the wasm→JS *exit thunk* does the reverse
  and enters the callee through the standard call helper — landing
  in Bistromath code when the callee is compiled. Signature counts
  are small in practice; the cache stays tiny.
- **IC-integrated dispatch on both sides.** To Bistromath, an
  exported wasm function is a `CallICCell` hit like any other
  callee — the cell-hit path branches straight to the cached entry
  thunk, so a hot `add(x, y)` export costs a pointer compare plus
  a near call. On the wasm side, import targets resolve **once at
  instantiation** to a direct callee (wasm function, JS function
  via exit thunk, or host native) — no per-call kind dispatch.
- **Conversion costs, honestly priced.** i32 ↔ Int32 is a tag
  test + retag (~2 instructions); f64 ↔ `Value` is the
  `double_encode_offset` add (~1); `externref` crosses as raw
  `Value` bits plus the pin-set discipline (one shared heap —
  nothing wrapped, nothing copied); **i64 ↔ BigInt is the
  expensive one** — a heap allocation each way, mandated by the
  JS-API's ToJSValue / ToWebAssemblyValue. Every engine eats
  that; toolchains already avoid i64 boundary signatures; v1
  doesn't fight it (a small-BigInt cache is a recorded micro-opt,
  nothing more).
- **No generic-wrapper tiering.** V8 ships generic wrappers that
  tier to compiled ones; Cynic's thunks are small enough to
  compile eagerly at instantiation whenever the JIT is on, and
  the T0 generic path remains as the jitless fallback.
- **Measured, gated.** A `wasm_boundary` set of micros (a JS loop
  hammering an exported i32 function; a wasm loop hammering a JS
  import; a ref-typed variant) lands with Spasm (§12 step 4) and
  gates the §11 boundary target.
- **The M6 reserve.** The endgame in V8 and SpiderMonkey is
  *inlining* small cross-boundary calls into the optimizing IR —
  possible exactly when one T2 IR can hold both languages. That
  is the concrete payoff behind this section's "maybe" row in the
  §7 table, and it goes into the Ohaimark ADR as a named input.

## 8. Executable memory and platforms

The ritual, validated against JSC/V8 practice and Apple's
porting-JIT guide; all of it lives in `code_alloc.zig` so no tier
ever touches a syscall:

- **macOS arm64 (primary target):** `mmap(PROT_READ|WRITE|EXEC,
  MAP_PRIVATE|ANONYMOUS|MAP_JIT)` — Zig's `std.c.MAP` for darwin
  already carries the `JIT` bit. Writes happen inside a
  `pthread_jit_write_protect_np(0)` … `(1)` window (per-thread,
  APRR-backed, nanoseconds — but **not in Zig's std**: extern-declare
  it), followed by `sys_icache_invalidate(addr, len)` (also extern —
  Zig's compiler_rt `__clear_cache` explicitly excludes Apple
  platforms). `mprotect` on a MAP_JIT region fails since macOS 11.2 —
  the toggle is the only door. Ad-hoc-signed local binaries need no
  entitlement; the `com.apple.security.cs.allow-jit` entitlement
  becomes relevant only if Cynic ever ships hardened-runtime signed
  builds (recorded, not actioned).
- **Linux:** start with the simple, measured thing — `mprotect`
  flipping RW↔RX around writes (SpiderMonkey measured <1% Octane
  cost for full W^X). x86_64 needs no icache maintenance; aarch64
  Linux gets compiler_rt's real `__clear_cache`.
- **W^X always, RWX never** — including on Intel macs where the
  toggle is a no-op; the allocator API makes writable-and-executable
  states mutually exclusive by construction, because retrofitting
  W^X into a JIT that assumed RWX is the documented painful path.
- **Branch reach:** arm64 `B/BL` spans ±128 MiB. v1 reserves a
  single region well under that (64 MiB default, flag-tunable) so
  every intra-cache call is a near branch; veneer support in `masm`
  is the day-two answer if a workload outgrows it.
- **Code lifetime:** `CompiledCode` is owned via the chunk
  (`chunk.code`), so realm teardown — ShadowRealm, `initChild`
  realms — frees code exactly when it frees chunks; the allocator
  keeps a free list (compiled functions are small; fragmentation is
  a non-problem at this scale). The *scoping* question (per-realm
  pools vs engine-wide) stays with the ADR
  [multi-realm.md](multi-realm.md) reserved for it; nothing in v1
  forecloses either answer.
- **Targets without codegen:** the playground builds Cynic to
  `wasm32-freestanding` — the entire `src/runtime/jit/` directory is
  comptime-gated on native targets, and every tier-up check
  constant-folds to "interpret" there. The same gate provides
  `--no-jit` (a permanent jitless mode, not a build): tier-up
  disabled, T0 remains the complete engine. Cheap to keep forever,
  and the Edge-SDSM/LibJS security calculus says some embedders
  will want exactly that switch.

## 9. GC integration summary

Collected from the sections above, since "Barriers cost in JIT'd
code: every GC change touches the JIT"
([handbook/compiler-engineering.md](handbook/compiler-engineering.md)):

- Roots: unchanged — compiled JS frames are `CallFrame`s (§4.2);
  compiled wasm frames hold no GC refs outside the pin set (§6).
- Write barriers: T1 property/element/env writes go through the
  same `Heap` store helpers (inline fast paths write only into
  `slots` of shape-checked receivers — the one store class the IC
  fast path performs today without a barrier, because a same-shape
  overwrite can still create a mature→young edge: **the interpreter
  IC's barrier behavior is the spec; T1 emits exactly what
  `sta_property`'s hit path does, helper-call included if that's
  what it does**). Any divergence here is what
  `verifyRememberedSet` + `/gc-stress` exist to catch.
- Embedded pointers: legal (non-moving heap; arena-stable shapes;
  chunk constants rooted via `markChunk` for exactly the code's
  lifetime) but v1 barely uses them — IC state stays data-driven
  (§4.4), so the only baked pointers are chunk/cell addresses and
  helper entry points.
- Triggers: GC can only run at safepoints (§4.6) and inside
  helpers — the same places it runs today.
- A future moving collector (ROADMAP keeps generational-moving "the
  path forward later") invalidates embedded *object* pointers but
  not this design: data-driven ICs already read through cells, and
  frame identity means precise roots were never derived from JIT
  frames. The doc records this as the reason to keep baked heap
  pointers out of T1 code paths wherever a cell-indirection costs
  nothing.

## 10. Verification and rollout

The tier ships dark, proves equivalence, then flips on:

1. **Substrate first, golden-tested.** The encoders get
   instruction-level golden tests (bytes compared against
   known-good encodings); the allocator gets W^X round-trip +
   execute-a-stub tests. No JS involvement yet.
2. **Differential gate — the heart of it.** A harness/CLI flag
   forces tier-up at `warmth ≥ 1`. The full test262 sweep
   (`zig build test262 -- --quiet`, binary scoring) must produce
   **byte-for-byte identical pass/fail results** with the flag on
   vs off — the same bar every IC commit already meets
   ([inline-caches.md](inline-caches.md) "Verification"). Lantern is
   the executable spec; Bistromath is correct exactly when the
   sweep can't tell them apart.
3. **gc-stress with force-compile.** `test262-safe` +
   `--gc-threshold=1` + force-tier-up across the GC-heavy buckets —
   compiled frames must survive the same rooting torture as
   interpreted ones (§4.2 says they're the same frames; this is
   where that claim gets audited).
4. **Bench gates.** `/perf` suite p50s with the JIT on must beat
   Lantern on the dispatch-bound fixtures (§11) and regress nothing
   >5% elsewhere (compile-time inclusion makes warm-up visible —
   the fixtures are sized 50–100 ms, so a millisecond-class compile
   shows up honestly).
5. **Flag posture.** `--jit` (off) while landing; defaults flip to
   on only after gates 2–4 hold on full sweeps, leaving `--no-jit`
   behind permanently (§8). The headline test262 score row never
   changes meaning — same posture, same binary scoring; a
   JIT-on differential sweep is an *additional* CI job, mirroring
   how gc-stress runs today.
6. **Cross-engine bench policy** ([benchmarking.md](benchmarking.md))
   gains a second table when the default flips: the existing
   interpreter-tier table (everyone `--jitless`) stays — it tracks
   Lantern — and a baseline-tier table (V8
   `--no-opt --sparkplug`-class configs, JSC
   `JSC_useDFGJIT=0`-class) gets added then, not before. The
   fuzzilli profile note ("No JIT") updates at the same moment.

## 11. Performance expectations

Targets are gates, not hopes; all measured by the existing
harnesses, recorded in `bench-results.md` / `wasm-bench-results.md`:

- **Bistromath:** ≥1.5× p50 on the dispatch-bound micros
  (`arith_loop`, `method_call`, `prop_access`, `tail_recursion`)
  against same-commit Lantern, with a stretch expectation of
  2–2.5× as fast-path coverage grows. Calibration: Sparkplug is
  +45% over Ignition (JetStream); SM's Baseline Compiler is
  2.5–3.4× over their C++ interpreter — but Lantern is already
  IC'd, fused, and pooled, so its dispatch overhead (the only thing
  T1 removes) is a smaller slice than a naive interpreter's.
  Compile throughput target: ≤1 ms per typical chunk (the ZJIT
  bar), expected to be comfortably met (Sparkplug-class compilers
  run two orders of magnitude faster than that).
- **Spasm:** ≥5× on both `wasm-bench` fixtures vs the
  2026-06-10 interpreter baselines (loop 38.82 → ≤7.8 ms/rep;
  fib 116.85 → ≤23.4 ms/rep), with the SPC paper's 10–15× suite
  average as the expected landing zone — wasm baselines remove the
  *entire* dispatch+cell-traffic layer, hence the bigger multiplier
  than JS T1.
- **Boundary:** a warm JS→wasm export call within ~2× of a warm
  monomorphic JS→JS call, and the import direction symmetric —
  the post-2018 norm (§7.1) — measured by the `wasm_boundary`
  micros. Anything worse means the thunk path picked up an
  indirect hop or an allocation it shouldn't have.
- **Ohaimark:** unspecified here; its ADR sets targets off
  Bistromath's measured numbers (the field says a further 2–3×
  on JS, with deopt machinery as the price).

## 12. Delivery order (M5)

Each step lands green (full unit suite + the §10 gates that exist
by then) before the next starts; every step is independently
useful:

1. **Substrate** — `src/runtime/jit/`: arm64 encoder + masm +
   code allocator, golden-tested, with executable smoke proofs in
   the unit suite — install-and-run stubs up through a
   fixup-patched loop, a helper call, and a hand-emitted NaN-boxed
   "add two Smis" at the `Value` level. The `--jit` flag arrives
   with step 2, where it first gates real behavior.
2. **Bistromath MVP** — the §4.3 inline set (moves, constants,
   int32 arithmetic/bitwise/compares, branches, `loop_inc_lt`,
   `return_`); everything else — calls, property ICs, heap-env
   locals — honestly `dont_compile`, and anything the fast path
   can't prove tiers down mid-function. The `--jit` CLI/harness
   flags land here, and the differential sweep (§10.2) is wired
   into CI as the macos-arm64 job (advisory at first; gating
   since the step-3 exit). Shipped 2026-06:
   full-corpus pass-sets byte-identical under force-compile
   (45166 passing / 4642 failing, both postures).
3. **Coverage + OSR** — where the bench wins arrive. Expanded
   into landable increments, each gated by the §10.2 differential
   before it commits, ordered by which bench fixture it unlocks.
   The register promotion of non-captured body `let`/`const`
   (shipped 2026-06: env elision + TDZ-window `throw_if_hole`,
   conformance-neutral at 45193) was this step's preamble — it
   made whole register-only functions compilable before a single
   new emitter existed.

   3a. **Layout contract** — `src/runtime/jit/layout.zig`, the
       one module holding every offset machine code may read:
       `CallFrame.{ip, accumulator, running_realm}`,
       `JSObject.{shape, prototype, inline/overflow slots}`,
       `Realm.{step_budget, interrupt, proto_revision_counter,
       globals}`, the `ICCell` / `CallICCell` fields, and the
       NaN-box kind bits. Comptime asserts plus an executable
       proof test that `ldr`-walks live objects and compares
       against Zig-side reads — the slice-layout assumption gets
       a runtime witness, not a comment. Shipped 2026-06.
   3b. **Bench `--jit` mode** — `cynic-bench` grows the flag so
       increments land with measured numbers. Shipped 2026-06
       (natural tier-up thresholds — the user posture);
       bench-results.md records both tables per entry from the
       first IC coverage onward.
   3c. **Property/global IC reads** — `lda_property` own-data
       and proto-load hits, `lda_global[_or_undef]`: inline
       cell-hit fast paths reading the cells as data (§4.4),
       including the split inline/overflow slot accessor and the
       executing frame's realm for globals (§8.3); any miss
       tiers down — Lantern re-runs the op and fills the cell,
       so the next activation hits. Reads need no helper ABI at
       all. Shipped 2026-06: full-corpus pass-sets identical
       under force-compile (45193).
   3d. **Property IC writes** — `sta_property` same-shape hit,
       emitting exactly what the interpreter's hit path does
       barrier-wise (§9 — the slot store inline plus the same
       `storeInternalSlot` call through a C shim); the
       transition mode tiers down (it resizes slots). Shipped
       2026-06; `verifyRememberedSet` audits the mirror under
       the `--jit` gc-stress CI lane and a young-string-into-
       mature-object unit test.
   3e. **Calls from compiled code** — the §4.5 helper-mediated
       design: materialize the args window, enter through
       `callValue` (every callee kind day one — natives, bound,
       proxies, compiled callees recursively; the nested
       `runFrames` carries the native-re-entry stack guard); a
       third `EntryResult.threw` keeps the frame pushed at the
       faulting call op so `unwindThrow` checks its own handlers
       first — catching tiers down at the handler. `call`,
       `call_method`, and the fused `call_property` (IC load into
       a spare scratch, then the marshal) all compile; tail calls
       tier down unconditionally — §15.10 demands constant stack
       and the helper path recurses natively. Shipped 2026-06
       (pass-sets identical at 45223). Self-recursive `tail_call`
       as frame-rebuild + jump-to-entry shipped 2026-06: a plain
       non-arrow callee over the same chunk swaps its capture set
       into the frame, shifts the args window, and branches to the
       body — constant native stack by construction, with the
       budget poll before any mutation (tail_recursion ~-18%);
       every other callee still tiers down to Lantern's general
       reframe. The `CallICCell` inline compare shipped 2026-06:
       a cell hit (vetted plain function, pointer match) skips
       callValue's whole dispatch chain into callJSFunction
       directly — and the bench verdict is that it bought ~nothing
       (method_call held at -24%): the remaining per-call cost is
       callJSFunction's frames-list + register-file ceremony, not
       the dispatch checks. A leaner compiled→compiled frame path
       is the measured next target if call-bound workloads demand
       it; until then this is recorded as done-and-evaluated.
   3f. **OSR entry** — per-loop-header prologue stubs with a
       `bytecode offset → stub offset` table riding in the code
       region; Lantern back-edges consult it through an inline
       precheck (a function call per back-edge costs ~+20% on a
       5M-iteration interpreted loop — the precheck is loads and
       branches, with a `dont_compile` early-out and an
       `osr_strikes` limit against the enter-and-bail ping-pong),
       and the PTC re-entry hooks `tryEnterTop` at ip 0. Tier-up
       counts back-edge warmth, so a function called once with a
       hot loop compiles from inside its own run. Shipped
       2026-06: the wrapped-arith_loop shape (5M iterations, one
       call) runs ~1.5× faster ReleaseFast, ~2× Debug. The bench
       fixture `arith_loop` itself stays interpreted — its loop
       is top-level, and script chunks carry global-slot ops
       (3g). `tail_recursion` enters per-reframe but the
       tail-call tier-down round-trip eats the win until
       jump-to-entry lands.
   3g. **Long tail** — script-chunk global-slot ops
       (`lda/sta_global_slot[_init]` against per-realm
       `decl_slots` slice caches on `GlobalBindings`, refreshed
       at `createLexBinding`, the only growth site) shipped
       2026-06: top-level loops OSR-enter, and the arith_loop
       bench fixture runs ~2.2× faster under `--jit`. Unary
       int32/bool ops (negate with the -0 / INT32_MIN
       tier-downs, bit_not, logical_not) and the `lda_env` /
       `sta_env` fixed-depth walks (closures as callees; the
       env store runs `storeEnvSlot` — barrier + store —
       through a C shim per §9; unroll capped at depth 8)
       shipped 2026-06, as did body-local promotion for methods
       and constructors (the same predicate and cap as plain
       functions; constructors still run in Lantern — the tier
       refuses construct frames — but skip the env allocation
       and chain walks) and `var` promotion (§14.3.2 — registers
       seed with undefined, no TDZ; re-declaration aliases;
       destructuring vars keep the env path). Compiled handler
       dispatch shipped 2026-07: each catch/finally bytecode entry
       gets a frame-compatible reentry stub in the existing
       continuation table. `driveTop` delegates the state change to
       Lantern's real `unwindThrow` once, then resumes Bistromath at
       that stub; termination, async Promise wrapping, and cold or
       caller-owned handlers still fall back without changing
       semantics. Generators/async stay last. Two defects the
       lean-call-path work unearthed shipped 2026-06: frames whose
       dispatch starts at a fresh `runFrames` (every callee of a
       compiled caller) now receive the §4.7 entry weight — without
       it such callees could never tier up; and `callJSFunction`
       registers its local frames list in `realm.frame_stacks`
       across the compiled-entry window — the GC marker walks only
       that list, and an unregistered compiled frame's registers
       held invisible (sweepable) references; the regression test
       reproduces the use-after-free via a forced full collection
       with the only reference in a compiled frame's register.
       The hardened-globals gap is CLOSED (2026-06): the global
       object was dictionary-mode from birth (and the SES freeze
       demoted everything else), so `lda_global` cells could never
       fill on ANY posture. Three pieces shipped: the global
       object promotes to shape residency at the end of intrinsic
       install (`promoteToShape`); the SES freeze locks
       descriptors via shape REDEFINITION TRANSITIONS (same slot,
       frozen attrs, cached in the transition tree) instead of
       demoting, so frozen objects stay IC-able; and the
       flip-audit debts this exposed were paid — `demoteFromShape`
       back-fills first-seen-wins so redefine nodes can't resurrect
       pre-freeze attrs, the `sta_global[_strict]` writability
       gates and the cross-realm default-proto remap read
       shape-first, and `installTestGlobals` re-locks in-shape.
       The frozen-PROTOTYPE gap is also CLOSED (2026-07).
       `LoadICCell` now distinguishes ordinary data loads from a
       `synthetic_accessor` mode that caches the override-mistake
       getter's immutable captured value. Fill is deliberately
       narrower than a general accessor IC: the receiver must be
       shape-mode with no own shadow, the holder must be the
       immediate non-extensible prototype, the descriptor must be
       non-configurable, and the getter must carry Cynic's internal
       non-setter `SyntheticAccessor` slot. Hits re-check receiver
       shape, prototype identity/shape, and the realm prototype
       revision; GC weak-clears a dead prototype, while a live
       prototype's getter strongly traces the captured value.
       Lantern and Bistromath consume the same cell mode. Tests
       cover forced-GC survival, `Object.setPrototypeOf`
       invalidation, and refusal to cache an ordinary immutable
       user getter. On the original 5M-call
       `o.hasOwnProperty("x")` workload, an interleaved ReleaseFast
       same-tree A/B (11 timed pairs after one discarded cold pair)
       measured **304.6 → 152.8 ms p50 (-49.8%)** when enabling the
       new fill. Re-measured postures are approximately 153 ms
       hardened/default, 152 ms `--no-jit`, and 149 ms
       `--unhardened`: the former 2.3× product-default cliff is gone.

   Step exit — taken 2026-06-11: `--jit` flipped to default-on
   (`--no-jit` is the permanent escape hatch; `--jit` stays
   accepted as an explicit no-op) and the CI differential flipped
   from advisory to gating, on the evidence below. The §10 gates
   green with the tier doing real work —
   full-corpus differential compared as pass-*sets* (a sorted
   `comm`, never counts: counts let compensating flips hide), a
   `--jit` lane in the gc-stress matrix, bench at the §11
   targets — then the default-on conversation.
4. **Spasm** — `wasm/spasm.zig` on the same substrate (§6) plus
   the §7.1 per-signature boundary thunks, gated by the wasm
   spec-testsuite at 100% with tiering forced, scored against the
   §11 targets; the `wasm_boundary` micros land here and gate the
   boundary number. *Started 2026-06:* the compiler skeleton +
   the trivial function class (constant-return) compile on the
   shared substrate, with the v1 boundary ABI (params/results as
   the interpreter's `Cell` arrays, the §7.1 native-register
   thunks deferred) and the degrade-to-interpreter contract
   (`compile → ?EntryFn`, null = stay interpreted). **Now wired into
   `interpreter.invoke`** behind the off-by-default per-instance
   `spasm_enabled` gate (the wasm-testsuite differential forces it on):
   a compilable entry function compiles and runs as native code through
   the v1 `Cell`-array boundary (params + locals in, results out),
   degrading to the interpreter for anything outside the emittable
   class. A counter-proven unit test (`spasm_runs`) confirms the
   compiled path is actually taken — the result alone is identical to
   the interpreter by design. v1 compiles fresh per call; a per-function
   code cache is a recorded perf follow-up. The compilable
   class (now: the complete straight-line i32 tier — const,
   `local.get`/`set`/`tee`, the i32 ALU including the four trapping
   `div`/`rem` ops, the ten comparisons +
   `eqz`, branchless `select`, `nop`/`drop`, and the bounds-checked i32
   memory accesses — full-width `load`/`store` plus the sign/zero-extending
   sub-width `load8_s`/`load8_u`/`load16_s`/`load16_u` and the narrowing
   `store8`/`store16` (the boundary passes the live memory base in x2 and
   length in x3, and the bounds check is overflow-safe — it traps on
   `ea > len` via a subtract's borrow rather than an `ea + n` that a near-
   2^64 memory64 address could wrap past), and the start of the i64 tier
   (`i64.const`, i64 `local.get`/`set`/`tee`, the i64 ALU
   add/sub/mul/and/or/xor/shl/shr_s/shr_u, `eqz` + the ten i64
   comparisons — a full 64-bit X-form `cmp` producing the i32 0/1 result —
   the four `div`/`rem` ops reusing the trap channel, and the i64 memory
   family (`load` + the sign/zero-extending `load8`/`load16`/`load32` and
   the narrowing `store`/`store8`/`store16`/`store32`, sharing the
   overflow-safe bounds check; the zero-extending narrow loads reuse the
   W-form loads, whose cleared high word is the i64 zero-extension) — the
   X-form mirror of the i32 ops — and the integer-width conversions
   `i64.extend_i32_s` (sxtw), `i64.extend_i32_u`, and `i32.wrap_i64` (both
   a W-form mov), completing the i64 integer tier; the bit-count unary
   ops `i32`/`i64.clz`, `ctz` (the native `CLZ`, with a `RBIT`+`CLZ`
   pair for trailing zeros, both yielding the bit width for a zero input),
   and `popcnt` (no scalar GP form, so a NEON `CNT`+`ADDV` over the
   vector unit) and the sign-extension ops `i32.extend8`/`16_s` and
   `i64.extend8`/`16`/`32_s` (`SXTB`/`SXTH`/`SXTW`); and the start of the
   float tier (`f64.const`, f64 `local.get`/`set`/`tee`, f64
   add/sub/mul/div, the six f64 comparisons — `fcmp` then `cset` with
   the FP condition codes, so a NaN operand makes the ordered relops false
   and `ne` true per spec; the `f32`/`f64` loads/stores, which are
   bit-identical to the same-width integer load/store and so reuse those
   encoders directly; the f32 arithmetic and comparisons — the S-form
   mirror of the f64 ops, bridging through the low word with the W↔S
   `fmov`s; and the f64 unary ops — `abs`/`neg` as the non-arithmetic
   sign-bit `FABS`/`FNEG` (NaN payloads preserved), `ceil`/`floor`/`trunc`/
   `nearest` as the `FRINTP`/`FRINTM`/`FRINTZ`/`FRINTN` directed-rounding
   modes (nearest = ties-to-even), and `sqrt` as `FSQRT`; the f32
   unary ops, the S-form mirror of the same seven; and the f32/f64
   `min`/`max`/`copysign` that close the scalar float ALU — `min`/`max`
   as the plain NaN-propagating `FMIN`/`FMAX` (so `min(-0, +0) = -0`),
   `copysign` as a pure GP bit op (magnitude of `a` via `bic` against the
   sign mask, sign of `b` via `and`, combined with `orr`); and the start
   of the representation conversions — the four reinterprets (free: a
   reinterpret only relabels the type, and the bits already sit in the GP
   slot) plus `f32.demote_f64` / `f64.promote_f32` (the cross-precision
   `FCVT`s), the int→float conversions (`SCVTF` / `UCVTF`, which read
   the integer straight from the GP slot — signed and unsigned, i32 and
   i64 sources, both result precisions), the saturating truncations
   (the `0xFC`-prefixed `i32`/`i64.trunc_sat_f32`/`f64_s`/`u` — `FCVTZS` /
   `FCVTZU`, whose round-toward-zero with NaN→0 and saturate-on-overflow
   is exactly the spec's, so no trap path is needed), and the trapping
   truncations (the single-byte `i32`/`i64.trunc_f32`/`f64_s`/`u`, which
   must trap rather than saturate: an explicit `fcmp f, f`/`b.vs` traps
   NaN to a new invalid-conversion channel and a `[lo, hi)` range test —
   the interpreter's exact per-pair bounds — traps to the overflow
   channel, then the in-range `FCVTZS`/`FCVTZU` converts)). A float keeps living in its slot's GP register as raw
   bits — an FP op bridges those bits into a v-register (`fmov` to v16/v17,
   a distinct register file from the GP x16/x17 scratch), computes in the
   FP unit, and bridges back — so the operand-stack model is unchanged and
   float loads/stores/const reuse the integer machinery. (`select` moved to
   the X-form `csel` so an i64/f64 select keeps all 64 bits.) — on the
   depth→register operand-stack machine, plus structured control
   flow: `block`/`end` + forward conditional `br_if`, `loop` +
   backward `br_if` (do-while), and unconditional `br` with a
   dead-code skipper (the rest of the frame after a `br` is
   unreachable — scanned to its `end`, degrading on any opcode whose
   immediate width the baseline doesn't know) — so `br`-continue plus
   `br_if`-break compiles a full `while` loop; `if`/`else` (a
   two-label frame: `cbz` to the else arm, then both arms canonicalize
   into the same result registers); and `br_table` as an indexed
   multi-way dispatch (a linear compare chain to each target plus a
   default jump, targets carrying no values for now — the common
   switch shape). Structured control flow is complete. Merges are
   register-resident at the canonical depth registers via a
   native-label control stack; the compilable block types carry no
   loop params, so a back-edge carries nothing and loop-carried state
   lives in locals, keeping the header merge spill-free. `div`/`rem`
   introduce the **trap channel**: `EntryFn` now returns a `u32` status
   (0 = ok, non-zero = a `TrapCode`), so a body that traps returns the
   code instead of writing results and `spasmRun` maps it to the matching
   `TrapError` — a Spasm trap is then indistinguishable from an
   interpreter trap at the JS boundary. AArch64 division never faults
   (÷0 yields 0, INT_MIN/-1 yields INT_MIN), so the spec's two `div`
   traps (divide-by-zero, signed overflow) are explicit pre-checks that
   branch to shared out-of-line exits; `rem_s(INT_MIN,-1) = 0` falls out
   of sdiv+msub on its own. `i32.load`/`i32.store` reuse this channel:
   each computes `ea = addr + offset`, bounds-checks `ea + n > mem_len`
   (x3) — AArch64's unsigned `hi`, with the zero-extended address making
   `ea` non-wrapping — and routes a failure to a shared
   `OutOfBoundsMemoryAccess` exit, so a stray access traps catchably
   instead of faulting the host; the access itself is a register-offset
   `ldr`/`str` off the base (x2). The
   **wasm-testsuite differential gate** now holds: a force-`spasm_enabled`
   run over the full spec testsuite (58779/58779 commands across 222
   `.wast` files, 1232 skip) produces the interpreter's exact pass-set —
   the §10-analog authoritative correctness gate, reproduced with
   `zig build wasm-testsuite -Dwasm-corpus=vendor/wasm-testsuite --
   --quiet [--spasm]` (the harness `--spasm` flag forces the per-instance
   gate on for every loaded module). The **per-function code cache**
   now ships (`spasmEntryFor`): each emittable function compiles once on
   its first Spasm-enabled invoke and the cached `EntryFn` runs every
   later call (the instance owns the executable pages for its lifetime;
   a body Spasm can't emit is recorded `failed` so it isn't re-attempted).
   A counter-proven unit test (1 compile across N runs) and the
   `zig build wasm-bench` interp-vs-Spasm A/B back it — the fully
   compilable `sum(i*i)` loop runs ~10× faster as cached native code on
   that workload, results byte-identical, while `call`-using `fib`
   degrades to the interpreter at parity. **Spasm is now the default
   production wasm tier**: the JS `WebAssembly` API turns it on for every
   instance when the JIT is on (`spasm_enabled = realm.jit_enabled`, set
   in `populateInstance`), so a JS-instantiated module's emittable
   functions baseline-compile through Spasm and `--no-jit` keeps the pure
   interpreter — the posture every shipping engine takes (V8 Liftoff,
   SpiderMonkey baseline, JSC BBQ all baseline-compile wasm rather than
   interpret it). A red-first `wasm_js_test` (a JS export runs
   Spasm-compiled native code, `spasm_runs >= 1`) plus the full JS-wasm
   suite run under the jit-on posture gate it; non-emittable bodies
   (tables, most of bulk memory, SIMD)
   degrade, so the suite still covers the interpreter through that fallback. The scalar ALU now spans
   the i32/i64 and f32/f64 arithmetic and comparisons, the full float unary
   set (incl. min/max/copysign), the integer bit-counts (clz/ctz/popcnt)
   and sign-extends, and every float↔int
   conversion (trapping and saturating) — the whole scalar wasm ALU — plus
   `global.get`/`global.set` (a fifth boundary register, x4, carries the
   instance globals base; the ops double-indirect through it to the
   global's value cell), the first bulk-memory ops `memory.fill` and
   `memory.copy` (inline byte loops after up-front overflow-safe bounds
   checks — leaf, no helper; copy picks the overlap-safe direction from
   `dst <= src`), `memory.size` (`mem_len >> 16`), `memory.grow` (a helper
   does the realloc and writes the fresh base/len into a frame out-region the
   body reloads x2/x3 from — growth invalidates the cached pointers; the i32
   result is the previous page count or -1), and both `call` and
   `call_indirect` (a non-leaf prologue parks the `*Instance` in callee-saved
   x19; the args marshal through a per-frame cell buffer to a native helper
   that re-enters `invoke`; operands live below the args are spilled across
   the helper call and reloaded after — a constant one stays a constant,
   re-materialized on each control-flow arm; `call_indirect` resolves and
   type-checks the table element in its helper, trapping on a bad index,
   null element, or signature mismatch; a thread-local depth guard turns
   runaway native recursion into a catchable `CallStackExhausted`); and
   `memory.init` / `data.drop` (the passive-segment ops, via the same
   helper-call shape) — so the whole bulk-memory family now compiles. The
   reference types open with `ref.null` / `ref.func` / `ref.is_null`: both ref
   sources are compile-time-known (a `ref.null` is always `REF_NULL`; a
   `ref.func`'s funcref is `makeFuncRef(x19, f)`, fixed by the immediate since
   the instance is the body-constant x19), so two compile-time-constant `Loc`
   variants carry them — like `.const_i32`, never spilled or mutated — and
   `ref.is_null` folds those to a constant `i32`. The scalar-operand table ops
   (`table.size`, `table.copy`, `table.init`, `elem.drop` — no reference
   crosses the operand stack, only i32 indices) compile through the same
   helper-call shape as the bulk-memory ops. A *runtime* reference (a
   `table.get` result) needs a 128-bit home: rather than register pairs or a
   native-stack frame, Spasm puts it in a depth-keyed cell appended to the heap
   locals buffer (`spasmRun` over-allocates by the bank depth; a ref is exactly
   one `Cell`), addressed off x0 — so a runtime ref survives calls and SP moves
   for free (the data is in the heap buffer, x0 is a spilled boundary register)
   and never touches the register bank. On that representation the whole
   `table.*` family compiles: `table.get` reads a ref into a cell, `table.set`
   / `table.grow` / `table.fill` write one back (a shared helper normalizes a
   `.ref_func` / `.ref_null` operand into the cell first so the runtime helper
   always reads one uniform slot pointer), and `ref.is_null` tests the full
   128-bit slot against `REF_NULL`. Reference locals (`local.get` / `set` /
   `tee` of a ref type — `spasmRun` re-seeds a declared ref local to `REF_NULL`
   per §4.4.10, since `@memset(0)` is wrong for a reference) and `select t` of
   a ref close out the reference family. The whole
   scalar/control/calls/memory/table/ref surface baseline-compiles. **SIMD
   (`v128`) is now under way**: a `v128` is one `Cell`, so it reuses the same
   depth-keyed heap-cell storage as references (a `.v128` Loc; default all-zero,
   not `REF_NULL`), giving the data path — `v128.const`, `v128.load` / `store`,
   v128 locals / params / results — for free as 128-bit cell moves; the first
   lane-compute op `i32x4.add` establishes the NEON substrate (the `ldr`/`str`
   Q-reg + `add Vd.4S` encoders in `asm_aarch64.zig`: load both operand cells
   into v0/v1, `add.4s`, store the result cell). The rest of the v128 lane-op
   surface (the other arithmetic/compare/convert/shuffle/lane families) is the
   remaining frontier, along with the side-table-as-control-oracle wiring (§6)
   that would make multi-target `br_table` cheap.
5. **Ohaimark** — the ADR plus bytecode/feedback/SSA, initial specialization,
   tagged/int32 representation selection, and verified logical deopt metadata
   plus stable physical spill homes have landed against measured Bistromath
   data. A bounded graph evaluator also proves checked success and overflow
   recovery against Lantern. Register allocation, AArch64 frame/edge lowering,
   checked int32 arithmetic/control emission, and direct guard-exit frame
   reconstruction now also ship in the test-only tier, along with guarded
   own/prototype/synthetic named loads through live IC cells. Next: safepoints,
   executable-code ownership, and disabled-by-default tier-up; see
   [ohaimark.md](ohaimark.md).

## 13. Considered and declined

- **Copy-and-patch stencils for T1** (Xu & Kjolstad,
  arXiv:2011.13127). Real (Deegen runs a full IC-bearing baseline
  on it; compiles 4.9–6.5× faster than Liftoff with better code),
  but it imports a build-time meta-toolchain (clang object emission
  + relocation parsing per target) to solve a problem Cynic doesn't
  have — baseline compile *speed* was never the bottleneck at
  Cynic's scale, and CPython's three years of modest results show
  the backend isn't where wins live. Two hand-written encoders are
  smaller than the stencil pipeline, and TPDE (arXiv:2505.22610)
  exists as the fallback evidence that hand-rolled backends hit
  LLVM -O0 quality at 10–20× the speed anyway. Revisit only if a
  third+fourth ISA ever matters.
- **LBBV as the T1 strategy** (YJIT). Best-in-class warm-up and a
  production success — but its specialization wins overlap heavily
  with ICs Cynic already has, and ZJIT's 2025 pivot to a method SSA
  JIT is the field conceding LBBV doesn't grow into a T2. A
  Sparkplug-shaped T1 keeps the T1→T2 boundary clean instead.
- **Tracing JIT at any tier.** TraceMonkey's removal rationale
  (trace explosion on branchy JS, bimodal cliffs, 17k LOC) has aged
  into consensus; even CPython's new tracing layer is a region
  *selector* over a baseline backend, not a compiler architecture.
- **A generated/asm interpreter as an intermediate step** (SM
  Baseline Interpreter, JSC LLInt, Ladybird AsmInt). Real wins for
  those engines, but Lantern's labeled-switch threaded dispatch
  already took the cheap half of that win, and Cynic's IC cells
  already give the interpreter the expensive half (SM's BLI is
  worthless without ICs — 0.57–0.72× — and Lantern *has* the ICs).
  The remaining gap is dispatch itself, which is T1's job.
- **Sharing the baseline abstract state between JS and wasm.** No
  engine does it (§7); the two T1s solve different problems above
  the assembler (frame mirroring vs operand-stack tracking) and the
  forced union would be worse at both.
- **Sea of nodes for Ohaimark.** Declined per V8's own retreat
  (§5); recorded here so the M6 ADR starts from CFG SSA.
- **Inline (patched) IC fast paths in T1.** Declined on GC-protocol,
  W^X-cost, and measured-no-win grounds (§4.4); revisit only with
  profile evidence *after* the data-driven version ships.

## 14. Open questions

- **Per-realm code-cache scoping** — reserved ADR in
  [multi-realm.md](multi-realm.md); v1's chunk-owned code with one
  engine-wide allocator doesn't foreclose either answer.
- **Background compilation** — irrelevant at Sparkplug-class
  compile costs (§4.7); becomes an Ohaimark ADR question (every
  engine compiles its optimizing tier off-thread; Cynic realms are
  single-threaded today, which is the complication to design
  around).
- **x86_64 timing** — the masm facade keeps the second encoder a
  mechanical port; land it when CI hardware or an embedder demands
  it, not before the differential gate exists to validate it
  cheaply.
- **Polymorphic ICs** — stay deferred per
  [inline-caches.md](inline-caches.md) until Ohaimark consumes
  feedback; T1 neither needs nor wants them.
- **Generators/async in T1** — after step 3, measured; the
  suspend/resume frame dance is bounded work but pure bookkeeping.
- **`Error.stack`** — Cynic doesn't build stack strings today;
  frame identity means whenever it does, compiled frames walk the
  same way. No action.

## 15. References

Engine sources: V8 — Sparkplug ([v8.dev/blog/sparkplug](https://v8.dev/blog/sparkplug)),
Maglev ([v8.dev/blog/maglev](https://v8.dev/blog/maglev)),
Liftoff ([v8.dev/blog/liftoff](https://v8.dev/blog/liftoff)),
leaving sea of nodes ([v8.dev/blog/leaving-the-sea-of-nodes](https://v8.dev/blog/leaving-the-sea-of-nodes)).
JSC — Speculation in JavaScriptCore
([webkit.org/blog/10308](https://webkit.org/blog/10308/speculation-in-javascriptcore/)),
B3 ([webkit.org/blog/5852](https://webkit.org/blog/5852/introducing-the-b3-jit-compiler/)),
Assembling WebAssembly ([webkit.org/blog/7691](https://webkit.org/blog/7691/webassembly/)).
SpiderMonkey — Baseline Interpreter
([hacks.mozilla.org, 2019](https://hacks.mozilla.org/2019/08/the-baseline-interpreter-a-faster-js-interpreter-in-firefox-70/)),
Warp ([hacks.mozilla.org, 2020](https://hacks.mozilla.org/2020/11/warp-improved-js-performance-in-firefox-83/)),
CacheIR ([jandemooij.nl](https://jandemooij.nl/blog/cacheir/)),
W^X ICs ([jandemooij.nl](https://jandemooij.nl/blog/wx-jit-code-enabled-in-firefox/)),
Rabaldr ([wingolog.org, 2020](https://wingolog.org/archives/2020/03/25/firefoxs-low-latency-webassembly-compiler)),
JS↔wasm boundary overhaul
([hacks.mozilla.org, 2018](https://hacks.mozilla.org/2018/10/calls-between-javascript-and-webassembly-are-finally-fast-%F0%9F%8E%89/)).
Hermes JIT (React Universe 2024 talk, Mikov). YJIT→ZJIT
([railsatscale.com](https://railsatscale.com/2025-05-14-merge-zjit/)).
LibJS JIT removal (Ladybird, 2024) + Microsoft SDSM CVE data
([microsoftedge.github.io](https://microsoftedge.github.io/edgevr/posts/Super-Duper-Secure-Mode/)).
Winch RFC ([bytecodealliance/rfcs](https://github.com/bytecodealliance/rfcs/blob/main/accepted/wasmtime-baseline-compilation.md)).
Apple, Porting JIT compilers to Apple silicon
([developer.apple.com](https://developer.apple.com/documentation/apple-silicon/porting-just-in-time-compilers-to-apple-silicon)).

Papers: Hölzle/Chambers/Ungar, PICs (ECOOP '91) and dynamic
deoptimization (PLDI '92). Poletto/Sarkar linear scan (TOPLAS '99);
Wimmer/Franz, linear scan on SSA (CGO '10). Chevalier-Boisvert/
Feeley, LBBV (ECOOP '15, arXiv:1411.0352). Xu/Kjolstad,
copy-and-patch (OOPSLA '21, arXiv:2011.13127). Titzer, in-place
interpretation (OOPSLA '22, arXiv:2205.01183) — Sarcasm's own
lineage. de Mooij et al., CacheIR (MPLR '23, DOI
10.1145/3617651.3622979). Titzer et al., Whose Baseline Compiler Is
It Anyway? (CGO '24, arXiv:2305.13241) — the wasm-T1 design manual.
Xu et al., Deegen (OOPSLA1 '26, arXiv:2411.11469). Poirier/Rohou/
Serrano, the false lead of optimizing inline caches (⟨Programming⟩
'25, arXiv:2502.20547). Schwarz/Kamm/Engelke, TPDE (CGO '26,
arXiv:2505.22610).
