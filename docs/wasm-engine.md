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

Deferred: `threads` (sits on the existing `SharedArrayBuffer` /
`Atomics` substrate), `exceptions`, `gc`, `tail-call` beyond the
trivial case, `memory64`, `relaxed-simd`, the component model.

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

3. **Threaded dispatch.** A Zig labeled switch whose every arm ends in
   `continue :dispatch <next-op>` — the computed-goto equivalent,
   identical to Lantern's idiom. This is non-negotiable for
   performance (disabling WAMR's jump table cost 2×). It is the *one*
   thing we borrow from Lantern; we do **not** borrow its
   rewrite-to-register-bytecode, because wasm (unlike JS source) is
   already compact validated bytecode.

4. **Unboxed value stack** with lazy reference tags (see §5) — fast
   primitives, precise GC roots, no stackmaps.

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

## 5. Operand model — unboxed value stack, lazy ref tags

Wasm is a stack machine; nearly every instruction touches the operand
stack, so its representation dominates interpreter speed.

- **One contiguous value stack** holds a frame's locals followed by
  its operands (JVM-style numbering: local 0..N, then the operand
  stack). Outgoing call arguments are already laid out as the callee's
  first locals — **zero-copy calls**.
- **Values are unboxed** — raw `i32/i64/f32/f64/v128/ref` bytes, never
  a heap allocation. (Boxing would be prohibitive, the very thing wasm
  exists to avoid.)
- **References and GC.** A precise GC must find `externref`/`funcref`
  cells on the value stack. Natively-compiled engines use stackmaps;
  an interpreter can't afford to precompute them. Instead, value-stack
  slots carry a **1-byte type tag written lazily** — only when a
  reference is stored (e.g. initializing a ref local in the prologue),
  never for primitive arithmetic. Metla scans only ref-tagged slots.
  Fast primitives, precise roots, no stackmaps. (Validation guarantees
  types, so the tag is never used for a dynamic check — only for GC.)

## 6. Calls, frames, traps

**Frames are explicit**, drawn from a pool like Lantern's
`frame_pool`; a wasm→wasm call pushes a frame and continues the same
dispatch loop rather than recursing in Zig.

**Stack overflow** is bounded without per-push checks. Titzer's engine
uses a guard page at the end of the value stack plus an OS signal;
Cynic's portable first cut uses a **frame-depth limit checked once per
call** (cheap, no signal handler), converting overflow into a clean
`call stack exhausted` trap. A guard-page scheme is a documented later
refinement.

**Traps** (§4.2) are an unwind: a Zig `error.WasmTrap` plus a reason
recorded on the store, propagated out of the loop and converted to a
thrown `WebAssembly.RuntimeError` at the JS boundary. Sources:
`unreachable`, OOB memory/table, integer divide-by-zero,
`i32.div_s INT_MIN / -1`, trapping float→int, `call_indirect`
null/signature mismatch, uninitialized element, stack exhaustion.

The **value stack and frames are GC roots**, registered with the realm
exactly like `realm.frame_stacks` does for Lantern, so a GC fired
mid-execution (e.g. inside an imported JS call) walks live wasm
references (the ref-tagged slots of §5). This is the use-after-free
hazard; it lands with `/gc-stress` coverage at `--gc-threshold=1` when
references arrive.

## 7. Runtime data structures — realm-owned

The §4.2.1 store is realm-scoped and created lazily, so non-wasm
programs pay nothing:

```zig
// realm.zig
wasm_store: ?*WasmStore = null,   // allocated on first wasm use

const WasmStore = struct {
    memories: ArrayListUnmanaged(*WasmMemory),
    tables:   ArrayListUnmanaged(*WasmTable),   // ref elements → GC roots
    globals:  ArrayListUnmanaged(*WasmGlobal),  // ref-typed → GC roots
    funcs:    ArrayListUnmanaged(WasmFuncInst), // wasm body OR host JS callable
};
```

**Linear memory is an `ArrayBuffer`.** `WebAssembly.Memory.prototype.buffer`
must return a real `ArrayBuffer` aliasing the linear bytes, so
`WasmMemory` is backed by the *same* backing-store abstraction
`shared_data_block.zig` and the ArrayBuffer machinery already use — not
a private buffer. `memory.grow` reallocates and **detaches** the prior
buffer (observable, spec-required); we reuse Cynic's existing detach
path. Shared memory (threads, later) backs onto a SharedArrayBuffer
data block so `Atomics` work unchanged. Bounds are checked on every
access in the interpreter tier.

## 8. The JS boundary

`WebAssembly.instantiate` returns a Promise (uses the existing
microtask queue). Argument and result marshalling is
§ToWebAssemblyValue / §ToJSValue: `i32 ↔ Number`, `i64 ↔ BigInt`,
`f32/f64 ↔ Number`, references pass through. **Every wasm→JS call site
opens a `HandleScope`** — calling an imported JS function re-enters
Lantern, which allocates, so the gc.md re-entry contract applies.

All engine state lives in **typed internal slots** on `JSObject`,
never `__cynic_*` property keys (AGENTS.md "no engine state on
user-visible objects"), the same pattern as `iter_helper` /
`capability_record`:

```
WebAssembly.Module   → slot → *CompiledModule   (immutable, shareable)
WebAssembly.Instance → slot → *ModuleInstance
WebAssembly.Memory   → slot → *WasmMemory        (+ cached .buffer ArrayBuffer)
WebAssembly.Table    → slot → *WasmTable
WebAssembly.Global   → slot → *WasmGlobal
```

## 9. SES / hardening

The `WebAssembly` namespace, its constructors, and prototypes freeze
under the hardened default like every other intrinsic; instances are
ordinary hardenable objects with typed slots (no observable engine
keys). `Memory.buffer` detaching on `memory.grow` stays observable —
spec-conformant and SES-fine.

`WebAssembly.compile` / `validate` / `new Module` are **gated behind
`--allow=wasm`**, the WASM analogue of `--allow=eval`
(HostEnsureCanCompileWasmBytes). The two gates are orthogonal: a build
can allow eval but not wasm, or vice versa. Default-off matches the
SES posture of refusing runtime code construction unless opted in. See
[ses-alignment.md](ses-alignment.md).

## 10. Performance posture

This is the **T0** tier — correctness-first, but at the right point in
the measured design space:

- In-place + O(1) side-table + threaded dispatch + unboxed value stack
  puts it in the `wamr-fast` / Wizard class on throughput, with the
  **best-in-class startup and memory** — the metrics Cynic's edge
  target actually rewards.
- Honest trade: `wasm3` is ~2–3× faster as an interpreter via a
  register rewrite + stack caching, paying 2–4× memory and a compile
  pass. We decline that trade on purpose.
- Documented future refinements (not done up front, none change the
  in-place design): **stack caching** — keep top-of-stack in a
  register/accumulator like Lantern; **superinstructions** for common
  opcode pairs; a guard-page value stack. The real throughput jump
  comes from a **baseline JIT tier** later (the ~10×→~2–3× step),
  which would consume the validated module + side-table — exactly
  where V8/JSC/SM add Liftoff/BBQ over their interpreters.

## 11. Implementation map

| Step | Deliverable |
|---|---|
| Decoder | §5 binary → parsed module *(done)* |
| Validate + side-table | single-pass validation **emitting the O(1) branch side-table** (§4) |
| Interpreter | in-place threaded dispatch over bytecode + side-table, integer + control subset → `fib` |
| Memory | `WasmMemory`, loads/stores, bulk-memory, grow + detach |
| JS API | `WebAssembly.*` typed-slot objects, marshalling, `--allow=wasm` |
| References | tables, funcref/externref, `call_indirect`, ref tags + Metla roots + gc-stress |
| Floats / SIMD | float ops, sign-ext, non-trapping float→int, multi-value, v128 |
| Conformance | the WebAssembly spec testsuite harness → `wasm-results.md` |

Conformance is scored against the official WebAssembly spec testsuite
(the `.wast` corpus), the same way `test262-results.md` scores ECMA-262.
