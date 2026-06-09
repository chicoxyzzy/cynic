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

> Not to be confused with `playground/wasm.zig`, which compiles
> Cynic *to* a `wasm32-freestanding` module for the browser
> playground. That is an output target; this is an execution surface.
>
>     playground/wasm.zig   Cynic ➜ WASM   (a build target)
>     src/runtime/wasm/         WASM ➜ Cynic   (an execution surface)

## 1. Scope

Target the standardized baseline every modern toolchain emits: the
1.0 core plus the universally-shipped post-MVP features —
`mutable-globals`, `sign-extension-ops`, `non-trapping-float-to-int`,
`multi-value`, `bulk-memory`, `reference-types`, and `simd`. Skipping
any of these makes most real `.wasm` fail to validate, so they are the
floor, not extensions.

**Shipped beyond that floor** (all now Phase 5 / WebAssembly 3.0):
`memory64` / `table64` (i64 addressing), the `extended-const`
constant-expression operators, the function-references
table-with-initializer encoding, the **`tail-call`** proposal
(`return_call` / `return_call_indirect` — the callee replaces the current
frame, so deep tail recursion runs in constant stack), **`relaxed-simd`**
(the relaxed-SIMD opcodes, each computed to one deterministic valid
result), the **`exception-handling`** proposal's *wasm instructions*
(the tag section, `throw` / `throw_ref`, `try_table` with every catch
form — `catch` / `catch_ref` / `catch_all` / `catch_all_ref` — and
`exnref`, with cross-frame stack unwinding and precise handler scoping;
the standardized `try_table` form, not the deprecated
try/catch/delegate/rethrow), and full cross-module linking (imported
functions / globals / tables / memories, shared tables, host functions).
On the official spec testsuite the engine passes **100.00% of the
commands it scores** — see `wasm-results.md` for what that does and does
not mean (it excludes proposal tests for features not yet implemented).

The **JS API** surface — `WebAssembly.*` objects (`Module`, `Instance`,
`Memory`, `Table`, `Global`, `Tag`, `Exception`), `compile` /
`instantiate` Promises, imports incl. host functions, the error types,
and i32/i64/f32/f64 marshalling — is shipped (§8), and `externref` holds
live JS objects (externref tables / globals, reference round-trips
through host calls), reclaimed precisely (§5 — a transient stack pin
cleared at the outermost return, plus per-container marking of externref
tables / globals). For exceptions: `WebAssembly.Tag` (a canonical
identity), `WebAssembly.Exception` (`.is` / `.getArg`), tag
imports/exports, and an uncaught wasm exception surfacing to JS as a
thrown `WebAssembly.Exception` all work — a tag shared by import is
caught across the boundary, and reference-typed exception payloads are
GC-rooted. `v128` is spec-mandated not to cross the JS boundary; a bare
`exnref` likewise raises a TypeError if it would.

Not yet implemented. **Standardized (Phase 5, Wasm 3.0) but
unimplemented** — `gc` (WasmGC); and one corner of exception interop:
a JS exception caught by a wasm `try_table` (the JS→wasm direction —
the interpreter is realm-free, so converting a thrown JS value into an
`exnref` needs a realm bridge it does not yet have). The wasm→JS
direction and all wasm instructions are shipped (above). **Still in
flight** — `threads` (Phase 4; sits on the existing `SharedArrayBuffer`
/ `Atomics` substrate), shared-everything threads and the component
model (Phase 1).

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
   see §5). `externref` liveness is precise (§5 — a transient stack pin
   plus per-container marking), reclaimed once wasm drops a value; the
   originally-planned lazy 1-byte value-stack ref tags are a future
   micro-optimization, not built. See §5.

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
- **GC integration — externref, precisely reclaimed.** An `externref`
  cell carries the JS value's NaN-boxed bits; a `funcref` carries its
  arena-owned defining-instance pointer (not GC-managed); the null ref is
  all-ones. Because the collector is **non-moving**, those bits are a
  stable identity, so the engine moves reference cells around opaquely —
  no per-slot tags in the hot loop. Liveness splits two ways, both rooted
  in `realm.markRoots`:
    - **Transient** — a value on the wasm stack / in a local *during* a
      call (where a host import can trigger GC) is pinned in
      `realm.wasm_extern_roots` (deduped by bits). The set is cleared when
      the outermost wasm call returns to JS (`wasm_call_depth` → 0): by
      then the stack is empty and any escapee is rooted by its JS caller.
    - **Persistent** — every `externref` table / global is registered and
      its live cells are walked each GC. Overwriting or dropping a slot
      reclaims the old value precisely.
  So an `externref` survives wherever wasm holds it (identity preserved)
  and is collected once wasm drops it — no retain-until-teardown leak,
  and no hot-loop instrumentation. The originally-planned lazy 1-byte
  *value-stack* ref tags would let Metla scan only live ref slots; they
  remain a future micro-optimization, not a correctness requirement.
  See §6 and §11.

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

**GC roots.** Live `externref` JS values are marked in `realm.markRoots`
alongside `realm.frame_stacks` — the transient set for values in-flight on
the wasm stack, plus a walk of every registered externref table / global.
So a GC fired mid-execution (e.g. inside an imported JS call) never loses
an `externref`, and a value is reclaimed once wasm drops it. Verified by
a WeakRef reclaim test, a host-import-under-GC-churn test, and an
8-million-allocation externref-churn stress under ReleaseSafe. The lazy
1-byte value-stack ref tags (so Metla scans only live ref slots, instead
of clearing the whole transient set per call) remain a future
micro-optimization. See §5.

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
cross-module functions, and shared globals / memories / tables; the
`CompileError` / `LinkError` / `RuntimeError` types; and the exception
surface — `Tag` (a canonical identity, imported/exported and shared
across the boundary) and `Exception` (`.is` / `.getArg`), with an
uncaught wasm exception surfacing to JS as a thrown `Exception` and its
reference-typed payloads GC-rooted. The engine is also still exercised
through its Zig API (`decode` / `instantiate` / `invoke`) and the
conformance harness.

`compile` / `instantiate` return Promises (built on the existing
microtask queue via §27.2.1.5 NewPromiseCapability); compilation is
synchronous, so they resolve — or, on an abrupt completion, reject with
the proper error class. Argument and result marshalling is
§ToWebAssemblyValue / §ToJSValue: `i32 ↔ Number`, `i64 ↔ BigInt`,
`f32/f64 ↔ Number`, and `externref` as a live JS value; `v128` and a bare
`exnref` are spec-rejected at the boundary with a TypeError (an
`exnref`'s JS form is the `Exception` object). **Every wasm→JS host call opens a `HandleScope`** — calling an
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
(dupe) default. `externref` tables / globals and reference round-trips
through host calls work, GC-reclaimed precisely per §5. Two deliberate
limitations: a JS-side `grow` of an imported memory isn't observed by the
importer (the aliased slice header goes stale; propagating it would cost
a load/store indirection for a rare case), and `v128` is spec-rejected at
the boundary (a TypeError, §ToJSValue / §ToWebAssemblyValue).

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
| Interpreter | in-place **threaded** dispatch over bytecode + side-table — **done** (integer, control, floats, SIMD, references, tail calls, exceptions) |
| Memory | loads/stores, bulk-memory, grow; memory64 i64 addressing — **done** (engine plain buffer; the JS `Memory.buffer` aliasing view + detach-on-grow ships in §8) |
| References / tables | tables, funcref/externref, `call_indirect`, element segments — **done**; externref GC rooting precise (§5), value-stack ref tags a future micro-opt |
| Floats / SIMD | float ops, sign-ext, non-trapping float→int, multi-value, v128, relaxed-SIMD — **done** |
| Cross-module linking | imported funcs/globals/tables/memories, shared tables, cross-instance funcrefs, host functions, start functions — **done** |
| Conformance | the WebAssembly spec testsuite harness → `wasm-results.md` — **done — 100% of the commands it scores** (the scored set excludes tests for unimplemented proposals) |
| JS API | `WebAssembly.*` typed-slot objects (`Module`/`Instance`/`Memory`/`Table`/`Global`/`Tag`/`Exception`), `compile`/`instantiate` Promises, imports incl. host functions, error types, i32/i64/f32/f64 marshalling, `--allow=wasm` — **done** (§8), incl. externref-across-JS (tables / globals / host round-trips), precisely GC-reclaimed (§5); v128 is spec-rejected at the boundary |
| Exception handling | tag section, `throw` / `throw_ref` / `try_table` (every catch form), `exnref`, cross-frame unwind + precise handler scoping — **done**; JS API `Tag` / `Exception` (`.is` / `.getArg`), tag imports/exports, uncaught wasm → JS `Exception`, GC-rooted reference payloads — **done** (§1, §8); a JS exception caught by a wasm `try_table` (the JS→wasm direction) — **pending** (the realm-free interpreter needs a bridge to turn a thrown JS value into an `exnref`) |

Conformance is scored against the official WebAssembly spec testsuite
(the `.wast` corpus), the same way `test262-results.md` scores ECMA-262.
