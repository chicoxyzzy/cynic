# WebAssembly engine — architecture

Cynic runs WebAssembly with a from-scratch native engine in
`src/runtime/wasm/`. This document is the durable design record: the
load-bearing decisions, the prior art behind them, and the data
structures the implementation builds on. Read it before touching the
decoder, validator, or interpreter.

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

Non-goals: a browser host, `WebAssembly` debugging surfaces, or any
sloppy-mode affordance. Cynic is strict, non-browser, edge-runtime
shaped — the WASM engine matches.

## 2. The pipeline

WASM separates cleanly into a **compile front-end** that runs once and
a **runtime** that executes. The two never blur.

```
  bytes ─▶ DECODE ──▶ VALIDATE-AND-LOWER ──▶ [compiled module]   immutable, shared
           §5         §3 + Appendix          register IR          (WebAssembly.Module)
                                                  │
                                            INSTANTIATE ──▶ [instance + store]   per Instance
                                                                  │              mem/table/global/func
                                                                  ▼
                                                            INTERPRET   the execution tier
                                                            threaded dispatch over the IR
```

The front-end is engine-neutral — identical regardless of how the code
is later executed. The runtime is realm-owned state the interpreter
(and any future JIT tier) operates on. This is the same split V8, JSC,
and SpiderMonkey draw, and it mirrors Cynic's own front-end-vs-Lantern
split.

## 3. Prior art and the decisions it forces

Per [handbook/prior-art.md](handbook/prior-art.md), the design space
for a WASM execution tier:

| Engine / system | Substrate | Dispatch | Operand model |
|---|---|---|---|
| Spec reference interpreter | AST walk | recursive | typed stack |
| wasmi | raw bytes + side-table | switch | untyped cells |
| **wasm3** | **pre-lowered IR** | **tail-threaded** | **stack→register slots** |
| V8 **DrumBrake** | pre-lowered register IR | threaded handlers | registers |
| JSC **IPInt** | in-place + metadata side-table | threaded | stack, metadata-guided |
| **Lantern** (Cynic's JS tier) | register bytecode | threaded (`continue :dispatch`) | registers + accumulator |

Academic grounding: threaded dispatch over a switch is the
Ertl & Gregg result (*The Structure and Performance of Efficient
Interpreters*, 2003); register VMs beat stack VMs for the same program
by cutting dispatch count (Shi et al., *Virtual Machine Showdown:
Stack Versus Registers*, 2008); wasm3 demonstrated the stack→register
lowering specifically for WebAssembly.

**Cynic's Lantern is the bar.** It is an Ignition-style register
machine with a hot accumulator, threaded dispatch via Zig's
labeled-switch (`continue :dispatch <next>` — the computed-goto
equivalent), frame state kept in loop-persistent locals and flushed
only at frame swaps, and an explicit frame stack registered with the
realm so Metla walks it as a GC root. A naive "switch over raw wasm
bytes" interpreter would be a second-class citizen beside it.

### Decisions (locked)

1. **The validator is a compiler front-end, not a checker.** WASM
   validation (§3, Appendix) already computes the operand-stack height
   and type at every program point. We emit a lowered **register IR**
   from that same pass — resolved immediates, resolved branch targets
   with arity, and a register assignment for every value. The "is this
   module valid?" answer and the executable artifact fall out of one
   walk. (`§3` validation ⇒ the `CompiledFunc` of §4 below.)

2. **Register-based internal IR, not stack interpretation.** Because
   validation hands us the stack layout for free, the costly part of
   stack→register conversion is already paid. Each operand-stack slot
   becomes a register index; opcodes read inputs from and write
   outputs to fixed slots. This is wasm3 / DrumBrake, and it matches
   Lantern so the two read as siblings.

3. **Threaded dispatch.** The interpreter loop is a Zig labeled switch
   whose every arm ends in `continue :dispatch <next-op>`, identical
   to Lantern's idiom. No shared dispatch funnel; one indirect branch
   per opcode site for the branch predictor.

4. **Segregated scalar / reference register files** (see §5) — the
   choice that makes untyped-fast scalars and precise GC roots
   coexist.

5. **Explicit frame stack, no host recursion** (see §6) — deep wasm
   recursion traps as `call stack exhausted` instead of crashing the
   Zig host.

6. **Pre-decoded immediates.** LEB128 operands are decoded once during
   lowering, never re-decoded in the dispatch loop.

These are the expensive-to-reverse decisions — IR shape touches the
compiler, every opcode handler, and the GC scan. They are made now, up
front, deliberately.

## 4. The compiled artifact

Validation-and-lowering emits one of these per function; an instance
shares the immutable compiled module and only allocates its own store
entries.

```zig
const CompiledFunc = struct {
    type_index: u32,
    // Frame layout, computed from validation:
    scalar_reg_count: u32,   // i32/i64/f32/f64/v128 slots
    ref_reg_count: u32,      // funcref/externref slots (GC-scanned)
    local_types: []ValType,  // params ++ declared locals
    // The lowered instruction stream — resolved immediates,
    // register-indexed operands, resolved branch targets:
    ir: []Instr,
};

const Instr = struct {
    op: IrOp,                // internal opcode (post-lowering)
    a: u32, b: u32, dst: u32,// register slot indices
    imm: Immediate,          // pre-decoded constant / memarg / target
};
```

The internal `IrOp` set is *not* the wasm byte opcodes: lowering folds
the 1.0 + extension opcode space into a regular internal form (e.g. a
single `i32.binop` family parameterised by operation, memargs with
resolved offset/align, branch targets as IR indices). This is the
substrate a future JIT tier consumes — a raw-bytes interpreter would
be a dead end.

## 5. Operand model — segregated register files

The tension: untyped raw cells are fast (no per-op tag dispatch), but
Metla cannot tell which raw cell currently holds a live `externref`
(a GC root) from an `i64` that merely looks like a pointer.

The register IR resolves it for free. Validation knows every value's
type statically, so lowering assigns each to one of two per-frame
files:

- **Scalar file** — `i32/i64/f32/f64/v128`. Raw untyped storage,
  **never scanned** by the GC. Fast path.
- **Reference file** — `funcref/externref`. Each slot is a JS `Value`,
  **always scanned** by Metla as a root.

So scalars stay tag-free and fast *and* references are precisely
rooted, with no per-PC stack map. The two-file split is a direct
benefit of the register IR; a flat untyped stack could not do this
without a tagging or stack-map scheme.

(v128 SIMD lanes live in the scalar file as 16-byte slots; references
never alias them.)

## 6. Calls, frames, traps

**Frames are explicit**, drawn from a pool like Lantern's
`frame_pool`. A wasm→wasm call pushes a frame and continues the same
dispatch loop; it does not recurse in Zig. A configurable depth limit
converts overflow into a clean `call stack exhausted` trap rather than
a host-stack crash. (wasm→JS→wasm re-entrancy *does* cross the Zig
stack at the boundary — each segment runs its own loop instance, which
is correct and bounded by the JS side's own limits.)

**Traps** (§4.2) are an unwind: a Zig `error.WasmTrap` plus a reason
recorded on the store, propagated out of the loop and converted to a
thrown `WebAssembly.RuntimeError` at the JS boundary. Sources:
`unreachable`, OOB memory/table, integer divide-by-zero,
`i32.div_s INT_MIN / -1`, trapping float→int, `call_indirect`
null/signature mismatch, uninitialized element, stack exhaustion.

The **call-stack and operand registers are GC roots.** The frame stack
registers with the realm exactly like `realm.frame_stacks` does for
Lantern, so a GC fired mid-execution (e.g. inside an imported JS call)
walks live wasm references. This is the use-after-free hazard; it
lands with `/gc-stress` coverage at `--gc-threshold=1` when references
arrive.

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
access in the interpreter tier (a future JIT could use guard pages).

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

This is the **T0** tier — correctness-first, but architected so the
ceiling is high and the road to a JIT is open:

- Register IR + threaded dispatch + pre-decoded immediates put it in
  the wasm3 / DrumBrake class rather than the reference-interpreter
  class.
- The register IR is the **JIT substrate**. When Cynic's optimizing
  tiers (Bistromath / Ohaimark) exist, a wasm JIT tier consumes this
  IR — exactly where V8/JSC/SM share TurboFan/B3/Ion between JS and
  wasm. No rework of the front-end required.
- Documented future T0 refinements (not done up front): top-of-stack
  in an accumulator local; tail-call dispatch handlers; untyped cell
  packing tuned per type. The IR shape does not change to adopt them.

## 11. Implementation map

| Step | Deliverable |
|---|---|
| Decoder | §5 binary → parsed module *(done)* |
| Validate-and-lower | §3 validation pass **emitting the register IR** (§4) |
| Interpreter | threaded dispatch over the IR, integer + control subset → `fib` |
| Memory | `WasmMemory`, loads/stores, bulk-memory, grow + detach |
| JS API | `WebAssembly.*` typed-slot objects, marshalling, `--allow=wasm` |
| References | tables, funcref/externref, `call_indirect`, Metla roots + gc-stress |
| Floats / SIMD | float ops, sign-ext, non-trapping float→int, multi-value, v128 |
| Conformance | the WebAssembly spec testsuite harness → `wasm-results.md` |

Conformance is scored against the official WebAssembly spec testsuite
(the `.wast` corpus), the same way `test262-results.md` scores ECMA-262.
