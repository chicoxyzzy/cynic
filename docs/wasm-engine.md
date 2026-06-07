# Sarcasm — the WebAssembly engine

Cynic runs WebAssembly with **Sarcasm**, a from-scratch native engine
in `src/runtime/wasm/`. The name buries *asm* (sarc·**asm** — WebA**sm**)
and is, fittingly for this project, the native register of a cynic.
It scopes to the whole subsystem — decoder, validator, interpreter —
the way SpiderMonkey's *Baldr* names all of its wasm support.

This document is the durable design record: the load-bearing
decisions, the prior art behind them, and the data structures the
implementation builds on. Read it before touching the decoder,
validator, or interpreter.

> Not to be confused with `src/playground_wasm.zig`, which compiles
> Cynic *to* a `wasm32-freestanding` module for the browser
> playground. That is an output target; this is an execution surface.
>
>     src/playground_wasm.zig   Cynic ➜ WASM   (a build target)
>     src/runtime/wasm/         WASM ➜ Cynic   (an execution surface)

## 1. Scope

Target the standardized baseline every modern toolchain emits: the
1.0 core plus the universally-shipped post-MVP features —
`mutable-globals`, `sign-extension-ops`, `non-trapping-float-to-int`,
`multi-value`, `bulk-memory`, `reference-types`, and `simd`. Skipping
any of these makes most real `.wasm` fail to validate, so they are the
floor, not extensions.

**Shipped beyond that floor:** `memory64` / `table64` (i64 addressing),
the `extended-const` constant-expression operators, the
function-references table-with-initializer encoding, and full
cross-module linking (imported functions / globals / tables / memories,
shared tables, host functions). The engine scores **100.00%** on the
official WebAssembly spec testsuite — see `wasm-results.md`.

The **JS API** surface — `WebAssembly.*` objects (`Module`, `Instance`,
`Memory`, `Table`, `Global`), `compile` / `instantiate` Promises,
imports incl. host functions, the error types, and i32/i64/f32/f64
marshalling — is shipped (§8). The **GC integration** (§5, §6) is the
main remaining structural piece; until it lands, `externref` can't hold
a live JS object, so externref tables and reference marshalling across
the JS boundary stay deferred.

Deferred: `threads` (sits on the existing `SharedArrayBuffer` /
`Atomics` substrate), `exceptions`, `gc`, `tail-call` beyond the
trivial case, `relaxed-simd`, the component model.

Non-goals: a browser host, debugging surfaces, or any sloppy-mode
affordance. Cynic is strict, non-browser, edge-runtime shaped — the
WASM engine matches.

## 2. The pipeline

WASM separates cleanly into a **compile front-end** that runs once and
a **runtime** that executes. The interpreter executes the **original
bytecode in place** — it is not rewritten to an internal format.

```
  bytes ─▶ DECODE ──▶ VALIDATE ──▶ [module + side-table]   immutable, shared
           §5         §3            original bytes +         (WebAssembly.Module)
                                    O(1) branch metadata
                                         │
                                   INSTANTIATE ──▶ [instance + store]   per Instance
                                                        │              mem/table/global/func
                                                        ▼
                                                  INTERPRET in place
                                                  threaded dispatch over the
                                                  original bytecode + side-table
```

The front-end is engine-neutral. The runtime is realm-owned state the
interpreter operates on. This is the same split V8/JSC/SpiderMonkey
draw, and it mirrors Cynic's own front-end-vs-Lantern split — with one
deliberate difference noted in §3.

## 3. Prior art and the decisions it forces

Per [handbook/prior-art.md](handbook/prior-art.md). The decision here
was **changed by reading the literature**, not assumed — an earlier
draft of this doc specified a register-IR rewrite; the survey below
showed that to be the wrong tier choice for an interpreter.

### The design space, measured

Ben Titzer (a WebAssembly co-designer), *A fast in-place interpreter
for WebAssembly*, OOPSLA 2022 ([arXiv:2205.01183](https://arxiv.org/abs/2205.01183)),
is the controlling reference. Its findings:

- **Every other interpreter rewrites the bytecode** to an internal
  format — wasm3 and WAMR to a register/threaded form, JSC/Chakra to
  their own. "Rewriting Wasm bytecode has similar disadvantages to
  baseline-compiling: it still takes time and memory" — typically
  **2×–4× the bytecode in space**, plus a translation pass before
  first execution.
- Direct in-place interpretation was *thought* infeasible because a
  wasm branch targets a structured construct by **nesting depth**, not
  a byte offset, and also pops operands — so a naive interpreter can't
  find the target or the pop count in O(1).
- **The validator already computes both** while typechecking. Distil
  it into a compact **side-table**: one 4-tuple `⟨Δip, Δstp, valcnt,
  popcnt⟩` *per branch*, emitted as a side-effect of the single
  validation pass, in forward order (no separate sort). Only branches
  need entries — **most functions have no control flow and so an empty
  side-table; overall ≈ 30% of bytecode, an order of magnitude smaller
  than the rewriting tiers.**
- **Throughput is competitive:** the in-place Wizard interpreter runs
  within ~1.5–1.7× of `wamr-fast` (the rewriting interpreter) and on
  par on short benchmarks. `wasm3` (register-rewrite + threaded +
  stack-caching) is the fastest interpreter, ~2–3× over in-place — at
  the 2–4× memory and translation-time cost. Interpreters sit ~10×
  under an optimizing JIT; baseline JITs ~2–3× under (so a future
  baseline tier, not the interpreter, is where that gap closes).

Two corroborating sources: Titzer, *Whose baseline compiler is it
anyway?* ([arXiv:2305.13241](https://arxiv.org/abs/2305.13241)) on the
tier landscape; *Research on WebAssembly Runtimes: A Survey*
([arXiv:2404.12621](https://arxiv.org/abs/2404.12621)) on the runtime
taxonomy. Classic interpreter-technique grounding (not on arXiv):
Ertl & Gregg, *The Structure and Performance of Efficient
Interpreters* (2003) on threaded dispatch.

### Decisions (locked, evidence-based)

1. **In-place interpretation — no rewrite.** Execute the original
   wasm bytes directly; the IP steps through them. This gives the
   **fastest startup and lowest memory**, which is decisive for
   Cynic's edge target (Workers/Deno/serverless cold starts). A
   register-IR rewrite would optimize peak interpreter throughput —
   the wrong axis for this engine, and the wrong tier for the job
   (rewriting is what a *baseline JIT* does, later).

2. **The validator emits an O(1) side-table** (`⟨Δip, Δstp, valcnt,
   popcnt⟩` per branch) as a side-effect of the validation pass. It is
   indexed by a side-table pointer advanced alongside the IP — O(1),
   never searched.
   **Explicitly not** a runtime branch-target cache: WAMR's original
   in-place design used a 128-entry cache whose misses rescan the
   whole function, going pathological (up to 8×) on branch-heavy code.
   The validator-emitted side-table is the fix and the entire point.

3. **Threaded dispatch** *(shipped)*. A Zig labeled switch whose every
   arm ends in `continue :dispatch nextOp(...)` — the computed-goto
   equivalent, identical to Lantern's idiom. Each opcode site emits its
   own indirect branch, so the predictor learns per-opcode-pair patterns
   instead of funnelling through one shared dispatch. Measured on a
   dispatch-bound arithmetic loop this was ~1.47× over the prior
   `while` + `switch` form (see `zig build wasm-bench`). It is the *one*
   thing we borrow from Lantern; we do **not** borrow its
   rewrite-to-register-bytecode, because wasm (unlike JS source) is
   already compact validated bytecode.

4. **Unboxed value stack.** Raw `i32/i64/f32/f64/v128/ref` bytes, never
   a heap allocation. Today every slot is a uniform 128-bit `Cell`
   (`interpreter.zig`), wide enough for `v128`; references are encoded
   inline (a `funcref` carries its defining instance in the high bits —
   see §5). The originally-planned lazy 1-byte ref tags for precise GC
   roots are **not built** — they belong with the GC integration, which
   waits on the JS API (no `externref` holding a JS value can reach the
   stack until then). See §5.

5. **Guard-bounded stacks, not per-push checks** (see §6).

These hold the front-end engine-neutral and the interpreter small.
The decoder (already built) is unchanged; the validator's job is now
"validate **and emit the side-table**," not "validate and lower to IR."

## 4. The compiled artifact

Validation emits, per function, the original body plus its side-table.
An instance shares the immutable compiled module and allocates only
its own store entries.

```zig
const CompiledFunc = struct {
    type_index: u32,
    local_decls: []LocalGroup,   // (count, type) runs from the body header
    body: []const u8,            // ORIGINAL bytecode, executed in place
    side_table: []BranchEntry,   // O(1) branch metadata; often empty
    value_stack_height: u32,     // max operand depth, from validation
};

// One per branch instruction (br / br_if / br_table case / if / else),
// in forward order. Consulted via a side-table pointer that advances
// with the IP.
const BranchEntry = struct {
    delta_ip: i32,    // adjust IP if the branch is taken
    delta_stp: i32,   // adjust the side-table pointer if taken
    val_count: u32,   // values to copy (branch arity)
    pop_count: u32,   // values to pop
};
```

The internal opcode space *is* the wasm byte opcodes — there is no
second instruction set. (A future baseline JIT tier would introduce
its own lowered form; the interpreter does not.)

## 5. Operand model — unboxed value stack

Wasm is a stack machine; nearly every instruction touches the operand
stack, so its representation dominates interpreter speed.

- **One contiguous value stack** holds a frame's locals followed by
  its operands (JVM-style numbering: local 0..N, then the operand
  stack). Outgoing call arguments are already laid out as the callee's
  first locals — **zero-copy calls**.
- **Values are unboxed** — raw `i32/i64/f32/f64/v128/ref` bytes, never
  a heap allocation. (Boxing would be prohibitive, the very thing wasm
  exists to avoid.) Today the slot is a uniform 128-bit `Cell`: simple
  and wide enough for `v128`, at the cost of 2× the bandwidth a scalar
  needs. Narrowing to an 8-byte scalar slot with a side `v128` lane is
  a documented future refinement (§10).
- **References are self-describing values.** A `funcref` is encoded as
  `instance_ptr << 64 | func_index`: the defining instance rides in the
  high bits, the function index in the low 32 (where the spec testsuite
  compares it). This is what makes a funcref callable across module
  boundaries — a table shared between instances may hold functions
  defined in either, and `call_indirect` runs each in the instance it
  was defined in. The null reference is all-ones; a bare index (high
  bits zero) resolves against the current instance.
- **GC integration is future.** The originally-planned scheme —
  lazy 1-byte ref tags so Metla scans only reference slots, no
  stackmaps — is **not built**, and neither is registering the value
  stack as a GC root. With the JS API shipped (§8), a GC *can* now fire
  mid-execution — a host import re-enters Lantern, which allocates — but
  it stays safe because only numeric values reach the wasm stack: a
  `funcref`'s instance pointer is arena-owned (not GC-managed) and no
  `externref` carries a live JS object yet, so there is nothing for the
  collector to lose (locked in by a host-import-under-GC-churn test).
  The ref tags + root registration become load-bearing the moment
  `externref` holds JS values (externref tables, reference marshalling
  across the boundary); the instance-pointer-in-a-funcref encoding will
  also need a GC-visible, lifetime-safe form then. This is the engine's
  largest open design item — see §6 and §11.

## 6. Calls, frames, traps

**Frames are explicit.** `invoke` allocates a value stack and a frame
array up front; a wasm→wasm call pushes a frame and continues the same
dispatch loop rather than recursing in Zig. Each frame records the
instance it runs in, so an imported (cross-module) call's body sees its
own module's memory / tables / globals — the interpreter rebinds the
active instance at every frame swap.

**Stack overflow** is bounded without per-push checks. Titzer's engine
uses a guard page at the end of the value stack plus an OS signal;
Cynic's portable first cut uses a **frame-depth limit checked once per
call** (cheap, no signal handler), converting overflow into a clean
`CallStackExhausted` trap. A guard-page scheme is a documented later
refinement.

**Traps** (§4.2) are a Zig error unwind: each maps to a member of the
`TrapError` set (`Unreachable`, `OutOfBoundsMemoryAccess`,
`IntegerDivideByZero`, `IntegerOverflow` for `i32.div_s INT_MIN / -1`,
`InvalidConversionToInteger`, `UndefinedElement` /
`UninitializedElement` / `IndirectCallTypeMismatch` for
`call_indirect`, `CallStackExhausted`, …), propagated out of the loop.
At the future JS boundary these become a thrown
`WebAssembly.RuntimeError`.

**GC roots — future.** The plan is to register the value stack and
frames as realm GC roots (exactly as `realm.frame_stacks` does for
Lantern) so a GC fired mid-execution — e.g. inside an imported JS call
— walks live wasm references. **Not built.** A host import now *does*
fire a GC mid-execution, but it is safe without rooting today because
the wasm stack holds only numerics (no live `externref`); registration
becomes load-bearing once `externref` carries JS values. It lands then,
with `/gc-stress` coverage at `--gc-threshold=1`. See §5.

## 7. Runtime data structures

**Today: a standalone `Instance`.** Instantiation lays out runtime state
into a caller-provided `Instance` (`interpreter.zig`) — validated
function bodies, a global array (imports then defined), the single
linear memory, and the table index space. The function / table / global
index spaces place **imports first** so cross-module linking resolves by
index; tables are held by pointer (`[]*Table`) so an imported table is
genuinely shared — a write through one instance is visible to the other.
Memory is a plain owned `[]u8`; bounds are checked on every access.

**Planned: a realm-owned store.** When the JS API (§8) lands, the
§4.2.1 store becomes realm-scoped and lazily created, so non-wasm
programs pay nothing:

```zig
// realm.zig (planned — not yet built)
wasm_store: ?*WasmStore = null,   // allocated on first wasm use

const WasmStore = struct {
    memories: ArrayListUnmanaged(*WasmMemory),
    tables:   ArrayListUnmanaged(*WasmTable),   // ref elements → GC roots
    globals:  ArrayListUnmanaged(*WasmGlobal),  // ref-typed → GC roots
    funcs:    ArrayListUnmanaged(WasmFuncInst), // wasm body OR host JS callable
};
```

**Planned: linear memory as an `ArrayBuffer`.**
`WebAssembly.Memory.prototype.buffer` must return a real `ArrayBuffer`
aliasing the linear bytes, so `WasmMemory` will back onto the *same*
backing-store abstraction `shared_data_block.zig` and the ArrayBuffer
machinery already use — not a private buffer. `memory.grow` reallocates
and **detaches** the prior buffer (observable, spec-required); reuse
Cynic's existing detach path. Shared memory (threads, later) backs onto
a SharedArrayBuffer data block so `Atomics` work unchanged. The
interpreter's current plain-buffer memory is the placeholder this
replaces.

## 8. The JS boundary

**Status: shipped** (`builtins/webassembly.zig`, tested in
`runtime/wasm_js_test.zig`). The full surface is wired:
`validate` (ungated); the `Module` / `Instance` constructors and the
`compile` / `instantiate` Promises; the `Memory` / `Table` / `Global`
objects (standalone and as instance exports); imports — host functions,
cross-module functions, and shared globals / memories / tables; and the
`CompileError` / `LinkError` / `RuntimeError` types. The engine is also
still exercised through its Zig API (`decode` / `instantiate` / `invoke`)
and the conformance harness.

`compile` / `instantiate` return Promises (built on the existing
microtask queue via §27.2.1.5 NewPromiseCapability); compilation is
synchronous, so they resolve — or, on an abrupt completion, reject with
the proper error class. Argument and result marshalling is
§ToWebAssemblyValue / §ToJSValue: `i32 ↔ Number`, `i64 ↔ BigInt`,
`f32/f64 ↔ Number` (`v128` / references across the JS boundary are still
TODO). **Every wasm→JS host call opens a `HandleScope`** — calling an
imported JS function re-enters Lantern, which allocates, so the gc.md
re-entry contract applies; a JS throw propagates as the engine trap
`HostThrew` and is re-raised at the boundary. To carry a JS callable
into the engine, `FuncRef.host` gained a `ctx` pointer.

All engine state lives in **typed internal slots** on `JSObject` /
`JSFunction`, never `__cynic_*` property keys (AGENTS.md "no engine
state on user-visible objects"), the same pattern as `iter_helper` /
`capability_record`. The records are opaque pointers into the realm's
`wasm_arena` (realm-lifetime, so no GC marking or cleanup):

```
WebAssembly.Module   → wasm_module slot → *ModuleState   (decoded module)
WebAssembly.Instance → exports own property; the *Instance lives in the
                       arena, reached via each export fn's wasm_export slot
WebAssembly.Memory   → wasm_memory slot → *MemoryState   (+ cached .buffer)
WebAssembly.Table    → wasm_table slot  → *TableState     (funcref only)
WebAssembly.Global   → wasm_global slot → *GlobalState
exported function    → wasm_export slot → *ExportRecord (instance, index)
```

`Memory.buffer` is a non-owning `ArrayBuffer` view over the arena bytes
(an `array_buffer_external` flag keeps `deinit` from freeing them);
`grow` detaches the old buffer and re-materializes a fresh one. An
imported memory shares the provider's bytes (`Imports.share_memory`), so
writes propagate both ways; the spectest harness keeps the snapshot
(dupe) default. Known gaps: `externref` tables (await the §5 GC
integration), and a JS-side `grow` of an imported memory isn't yet
observed by the importer (the aliased slice header goes stale).

## 9. SES / hardening

The `WebAssembly` namespace, its constructors, and prototypes freeze
under the hardened default like every other intrinsic; instances are
ordinary hardenable objects with typed slots (no observable engine
keys). `Memory.buffer` detaching on `memory.grow` stays observable —
spec-conformant and SES-fine.

The code-constructing surface — `WebAssembly.compile` / `instantiate` /
`new Module` / `new Instance` — is **gated behind `--allow=wasm`**, the
WASM analogue of `--allow=eval` (HostEnsureCanCompileWasmBytes); a closed
gate throws `EvalError`. The two gates are orthogonal: a build can allow
eval but not wasm, or vice versa. Default-off matches the SES posture of
refusing runtime code construction unless opted in. `WebAssembly.validate`,
which only inspects bytes and constructs nothing runnable, is installed
ungated. See [ses-alignment.md](ses-alignment.md).

## 10. Performance posture

This is the **T0** tier — correctness-first, but at the right point in
the measured design space:

- In-place + O(1) side-table + threaded dispatch + unboxed value stack
  puts it in the `wamr-fast` / Wizard class on throughput, with the
  **best-in-class startup and memory** — the metrics Cynic's edge
  target actually rewards. Threaded dispatch is now in (§3 Decision 3);
  `zig build wasm-bench` is a standalone ReleaseFast harness for the
  dispatch-bound loop and recursive `fib` so future hot-loop changes
  stay measured.
- Honest trade: `wasm3` is ~2–3× faster as an interpreter via a
  register rewrite + stack caching, paying 2–4× memory and a compile
  pass. We decline that trade on purpose.
- Documented future refinements (none change the in-place design),
  roughly in leverage order: **narrow the operand cell** — the uniform
  128-bit `Cell` doubles scalar bandwidth; an 8-byte scalar slot with a
  side `v128` lane is the next win (§5); **hoist the memarg align/offset
  and the memory `is_64` flag** out of the per-access path into the
  side-table; **stack caching** (top-of-stack in a register, like
  Lantern); **superinstructions** for common opcode pairs; a guard-page
  value stack. The real throughput jump comes from a **baseline JIT
  tier** later (the ~10×→~2–3× step), which would consume the validated
  module + side-table — exactly where V8/JSC/SM add Liftoff/BBQ over
  their interpreters.

## 11. Implementation map

| Step | Status |
|---|---|
| Decoder | §5 binary → parsed module — **done** |
| Validate + side-table | single-pass validation emitting the O(1) branch side-table (§4) — **done** |
| Interpreter | in-place **threaded** dispatch over bytecode + side-table — **done** (integer, control, floats, SIMD, references) |
| Memory | loads/stores, bulk-memory, grow; memory64 i64 addressing — **done** (engine plain buffer; the JS `Memory.buffer` aliasing view + detach-on-grow ships in §8) |
| References / tables | tables, funcref/externref, `call_indirect`, element segments — **done** (ref tags + Metla GC roots are future, §5) |
| Floats / SIMD | float ops, sign-ext, non-trapping float→int, multi-value, v128 — **done** |
| Cross-module linking | imported funcs/globals/tables/memories, shared tables, cross-instance funcrefs, host functions, start functions — **done** |
| Conformance | the WebAssembly spec testsuite harness → `wasm-results.md` — **done, 100.00%** |
| JS API | `WebAssembly.*` typed-slot objects (`Module`/`Instance`/`Memory`/`Table`/`Global`), `compile`/`instantiate` Promises, imports incl. host functions, error types, i32/i64/f32/f64 marshalling, `--allow=wasm` — **done** (§8); externref-across-JS + the §5 GC roots are future |

Conformance is scored against the official WebAssembly spec testsuite
(the `.wast` corpus), the same way `test262-results.md` scores ECMA-262.
