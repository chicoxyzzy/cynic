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

**Shipped beyond that floor** (all standardized in WebAssembly 3.0):
`memory64` / `table64` (i64 addressing), the `extended-const`
constant-expression operators, the **`function-references`** proposal
(typed references `(ref [null] $t)`, `call_ref` / `return_call_ref`,
`br_on_null` / `br_on_non_null`, `ref.as_non_null`, value-type
subtyping, non-defaultable-local initialization tracking, typed
tables/globals with explicit table initializers), the **`tail-call`** proposal
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
GC-rooted. The reverse direction works too: a JS exception thrown by a
host import is caught by a wasm `try_table` (`catch_all`, or `catch
$tag` when it is a `WebAssembly.Exception` of a matching tag), and an
uncaught one re-raises the *original* JS value with its identity intact.
`v128` is spec-mandated not to cross the JS boundary; a bare `exnref`
likewise raises a TypeError if it would.

Multiple memories (Wasm 3.0) is shipped: a module declares or imports
any number of linear memories; every load/store carries an optional
memory index in its memarg (bit 6 of the align field), `memory.size` /
`grow` / `fill` / `init` take a memory index, `memory.copy` copies
across two memories, active data segments target any memory (flag 2),
and the JS API exports each memory as its own `WebAssembly.Memory`. An
imported memory aliases the provider's — a store or grow through one
instance is visible through the other (which also means a JS
`Memory.grow` can no longer leave an importing instance reading a
stale buffer).

Globals are aliased across instances the way memories and tables are:
an imported global IS the provider's global (§4.5.4), so a mutable
global's writes are visible through every importer — including a JS
`WebAssembly.Global`, whose `.value` accessor reads and writes the
same cell the instances use.

Not yet implemented. **Standardized (WebAssembly 3.0) but
unimplemented** — `gc` (WasmGC: struct/array/i31 heap types, rec
groups, casts). Exception handling — every wasm instruction and the
full JS interop, both directions — is shipped (above). **Still
pre-standard upstream** — `threads` (would sit on the existing
`SharedArrayBuffer` / `Atomics` substrate), and the early-stage
shared-everything-threads and component-model proposals.

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
      `wasm_extern_roots` of the outermost calling realm (deduped by bits).
      The heap records that owner so shared-heap child realms and imported
      callbacks use the same dynamic lifetime. Start functions enter this
      boundary too. The set is cleared when the outermost wasm call exits,
      normally or exceptionally: by then the stack is empty and any escapee
      is rooted by its JS caller. Nested calls in another realm cannot clear the outer pins.
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
At the JS boundary these become a thrown
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

**Standalone and Realm-backed `Instance`.** Instantiation lays out runtime state
into a caller-provided `Instance` (`interpreter.zig`) — validated
function bodies, a global array (imports then defined), linear memories,
and the table index space. The function / table / global
index spaces place **imports first** so cross-module linking resolves by
index; tables are held by pointer (`[]*Table`) so an imported table is
genuinely shared — a write through one instance is visible to the other.
Memories are likewise held by pointer, so a JS import aliases the provider's
`Memory` record and observes writes and growth. Bounds are checked on every
access.

**Realm ownership is split by lifetime.** The JS API lazily creates
`wasm_arena` for immutable decoded metadata, instance records, and store
headers. Mutable Memory/Table backing buffers use `wasmStoreAllocator`, an
immediate-free quota allocator: `grow` reallocates the live backing instead of
leaving obsolete buffers in the arena, and `grow(0)` does not consume quota.
Each owned record carries its backing allocator; shared imports retain the
provider's allocator and identity. One quota-backed Realm registry tracks
instances and reaches their owned records; two smaller registries cover direct
JS `Memory` / `Table` constructors. Teardown releases those backings before the
arena invalidates their headers. A failed population transaction before start execution removes its exact
instance and decrements its reference-counted roots before releasing code and
store resources. Once a start function begins, the instance and its roots stay
owned by the realm even if start throws: an imported callback may already have
published a Wasm function or reference that still needs that store. The bare embedding defaults the backing
allocator to the allocator passed to `instantiate` and releases it from
`Instance.deinit`.

**Linear memory and JS views.** `Memory.prototype.buffer` returns a real,
non-owning `ArrayBuffer` view over the live bytes. `memory.grow` reallocates
the backing and **detaches** a prior fixed-length buffer; a resizable buffer
retains its identity and receives the live backing slice. The next `.buffer`
access materializes a fresh fixed view when needed. Ordinary imported
instances share the same `Memory` header, so a grow updates every importer.
The threads proposal remains out of scope; shared memories retain their
provisional arena backing until they move to `SharedDataBlock` for non-moving,
in-place growth.

## 8. The JS boundary

The scoped [WPT Wasm JavaScript API lane](wpt.md) supplements the core
instruction tests; its [results](../wpt-results.md) track remaining API gaps.
Its corrections follow WebIDL property descriptors and the Wasm JS API's
conversion algorithms: nonenumerable interface constructors, enumerable
operations and attributes, branded `Global.valueOf` / `Instance.exports`,
shallow-frozen exports, and NativeError constructor inheritance. Numeric values
use the throwing ECMA-262 ToNumber / ToBigInt operations. Host import callbacks
stay rooted for the realm-owned Wasm store's lifetime. Failed import resolution
and pre-start instantiation failures release their registrations; failures
after start begins preserve potentially escaped references. Promise capabilities
and intermediate wrappers are rooted across collecting start callbacks.

`Instance` keeps `[[Exports]]` in a typed slot, traced by full and minor GC and
covered by the typed-slot write barrier. This follows the
[Wasm JS API §5.2](https://webassembly.github.io/spec/js-api/#instances)
getter model used by
[V8](https://github.com/v8/v8/blob/main/src/wasm/wasm-js.cc) and
[JavaScriptCore](https://github.com/WebKit/WebKit/blob/main/Source/JavaScriptCore/wasm/js/WebAssemblyInstancePrototype.cpp).
Production hardening still freezes the installed intrinsics after setup.
WPT uses mutable primordials; focused tests also cover hardened exports and
collection during callbacks.

Exported-function identity follows the Wasm JS API's
[object caches (§4.2)](https://webassembly.github.io/spec/js-api/#object-caches)
and [Exported Functions (§5.6)](https://webassembly.github.io/spec/js-api/#exported-function).
Every function exposure uses `makeExportedFunction`, including exports,
table/global reads, and function-reference results. A lazy cache in the store
owner's Realm maps the canonical `CompiledFunc` or `HostImportCtx` pointer to
one JS function and its backing instance. Aliases and imported Wasm reexports
therefore retain identity; independent ordinary JS imports receive fresh
`HostImportCtx` records and remain distinct. This follows
[JSC's `ensureFunctionWrapper`](https://github.com/WebKit/WebKit/blob/main/Source/JavaScriptCore/wasm/js/JSWebAssemblyInstance.cpp),
[SpiderMonkey's `getExportedFunction`](https://github.com/mozilla-firefox/firefox/blob/main/js/src/wasm/WasmInstance.cpp),
and [V8's `GetOrCreateExternal`](https://github.com/v8/v8/blob/main/src/wasm/wasm-objects.cc):
reuse the canonical function wrapper instead of allocating one per exposure.

The cache is strong for the existing Realm-owned store lifetime: entries are
quota-accounted, their JS values are rooted on every GC cycle, and teardown
releases the map with the store. This deliberately retains materialized
wrappers until store teardown, matching the current arena lifetime of core
instances rather than adding weak-cache collection. Pre-start instantiation
rollback removes any partial entries; once start executes, potentially escaped
references remain valid. First exposure creates the JS function in the current
Realm, while its native backing record lives in the store owner's arena;
cross-realm lookups reuse that owner's cache. This separates the function's
creation Realm from the lifetime of the store it calls.

`Global`, `Memory`, and `Table` identity uses one Realm-local map keyed by a
union of their typed native pointers, implementing the same
[object caches (§4.2)](https://webassembly.github.io/spec/js-api/#object-caches)
and the initialize/create-object algorithms for
[Memory (§5.3)](https://webassembly.github.io/spec/js-api/#memories),
[Table (§5.4)](https://webassembly.github.io/spec/js-api/#tables), and
[Global (§5.5)](https://webassembly.github.io/spec/js-api/#globals).
Constructors register their actual `this` object, preserving subclasses and
custom prototypes on reexport. Export helpers search the maps in `heap.realms`
before allocating, so cross-realm imports reuse the original wrapper. A miss
is local: foreign Memory/Table/Global imports already arrive through wrappers;
primitive immutable Global imports allocate fresh local cells. First exposure
therefore chooses the wrapper's Realm and prototype, while equal primitive
imports remain distinct. Memory keys use the stable native `Memory` record,
not its reallocatable byte backing, so growth preserves wrapper identity and
all aliases share its cached `buffer`. As with function wrappers, entries are
quota-accounted strong roots for the existing store lifetime, traced on every
GC and released at teardown; pre-start instance rollback removes only that
instance's partial entries, preserving imported providers. After growth removes
old buffers from the rooted host-view registry, the buffer getter checks
registry membership before dereferencing its cached pointer: GC may already
have reclaimed that detached buffer before the next getter call.

The closest prior art is
[SpiderMonkey's `EnsureExportedGlobalObject` / `GetGlobalExport`](https://github.com/mozilla-firefox/firefox/blob/main/js/src/wasm/WasmModule.cpp):
it materializes a Global wrapper once per index and reuses retained Memory
and Table objects. [V8's `ProcessExports`](https://github.com/v8/v8/blob/main/src/wasm/module-instantiate.cc)
and [JSC's `initializeExports`](https://github.com/WebKit/WebKit/blob/main/Source/JavaScriptCore/wasm/js/WebAssemblyModuleRecord.cpp)
preserve imported wrappers, but their current local-Global paths differ from
the explicit spec cache: V8 allocates a wrapper per local Global export, and
JSC does so for embedded immutable globals. Cynic follows the spec for these
aliases too. Shared-memory cloning needs a separate identity policy: the
spec exempts shared objects from the uniqueness guarantee, and
[V8's `ReadWasmMemory`](https://github.com/v8/v8/blob/main/src/objects/value-serializer.cc)
creates a new wrapper linked to an existing shared backing store.

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

Boundary *performance* under the JIT tiers — per-signature
entry/exit thunks in the shared code region, IC-integrated dispatch
on both sides, and the conversion-cost ledger (i64 ↔ BigInt is the
allocating one) — is pinned in [jit.md](jit.md) §7.1; the
`wasm_boundary` micros land with Spasm (jit.md §12).

The `Module` constructor carries the JS-API's static introspection
methods (ungated — no code is generated): `Module.exports(module)` and
`Module.imports(module)` return descriptor arrays in declaration order
(`{ name, kind }` and `{ module, name, kind }`, `kind` the external-kind
string `"function"` / `"table"` / `"memory"` / `"global"` / `"tag"`),
and `Module.customSections(module, name)` returns fresh `ArrayBuffer`
copies of every custom section whose name matches. Custom sections are
retained for this by the decoder (a `CustomSection { name, bytes }`
slice borrowing the kept-alive input buffer; validation still ignores
them). The section name is coerced through the full §7.1.17 ToString, so
a user-defined `toString` / `@@toPrimitive` on an object argument fires.
Each constructor prototype (`Module`, `Instance`, `Memory`, `Table`,
`Global`, `Tag`, `Exception`) carries its `@@toStringTag`
(`"WebAssembly.Module"`, …), installed before the hardened-realm freeze
so the brand survives on the frozen prototype.

`compile` / `instantiate` return Promises through the existing promise
capability machinery. `instantiate` follows the Wasm JS API's
[asynchronous compilation](https://webassembly.github.io/spec/js-api/#asynchronously-compile-a-webassembly-module)
and [asynchronous instantiation](https://webassembly.github.io/spec/js-api/#asynchronously-instantiate-a-webassembly-module)
boundaries. The bytes overload snapshots the selected BufferSource bytes at
call time; decoding currently also happens there, but compilation completion
and import getters wait for a host task. The Module overload captures imports
synchronously. Both then queue core instantiation, including active data/element
segments and the start function. Captured functions and primitive globals are
not reread; imported Memory/Table/Global objects retain their normal aliasing.
Import and start exceptions reject with the original thrown value.

`Realm.wasm_instantiation_jobs` is a separate FIFO, driven by the existing
`lantern.drainMicrotasks` entry point. It drains runnable ordinary promise jobs,
including newly queued reactions, before each Wasm task and checkpoints again
afterward, following ECMA-262 [Jobs](https://tc39.es/ecma262/#sec-jobs).
Thus reactions queued by import getters run before core instantiation. A nested
drain cannot enter another Wasm task while one is running or while the Module
overload is capturing imports. The JS debug helper `__drainMicrotasks` drains
ordinary microtasks only; native host/TLA checkpoints drive both queues. This
adds no event loop or timers.

Pending tasks trace their promise capability, module, import object, and
captured import values. A popped task opens a `HandleScope` before any JS
reentry. Queue storage and retained-value arrays use the shared heap quota;
completion, failure, and realm teardown release their owned registrations and
arrays, with successful instantiation transferring import ownership to the
instance. Fuel/interrupt termination stops the drain without turning host
termination into a catchable rejection. The popped task is not retried;
remaining tasks stay queued for the host to resume or discard at teardown.

[JavaScriptCore](https://github.com/WebKit/WebKit/blob/main/Source/JavaScriptCore/wasm/js/JSWebAssembly.cpp)
likewise retains dependencies through `DeferredWorkTimer` and schedules
instantiation completion. [SpiderMonkey](https://github.com/mozilla-firefox/firefox/blob/main/js/src/wasm/WasmJS.cpp)
retains source bytes/imports in `CompileBufferTask`, then captures imports
before dispatching `AsyncInstantiateTask`. Cynic uses its existing host drain
instead of background workers. Public `WebAssembly.compile()` still settles
inline, and the promise constructor is still looked up through the global
binding; those separate conformance gaps are unchanged by this scheduling work.

Argument and result marshalling is
§ToWebAssemblyValue / §ToJSValue: `i32 ↔ Number`, `i64 ↔ BigInt`,
`f32/f64 ↔ Number`, and `externref` as a live JS value; `v128` and a bare
`exnref` are spec-rejected at the boundary with a TypeError (an
`exnref`'s JS form is the `Exception` object). **Every wasm→JS host call opens a `HandleScope`** — calling an
imported JS function re-enters Lantern, which allocates, so the gc.md
re-entry contract applies; a JS throw propagates as the engine trap
`HostThrew` and is re-raised at the boundary. To carry a JS callable
into the engine, `FuncRef.host` gained a `ctx` pointer.

JS host imports support up to 16 parameters and 16 results, matching the
interpreter and native host-call buffers. Zero-result imports discard the
returned JS value; single-result imports convert it directly. Multiple results
follow [Wasm JS API §5.6 run a host function](https://webassembly.github.io/spec/js-api/#run-a-host-function):
get the iterator, consume it to completion, require the exact result count,
then convert each value in signature order. `v128` and `exnref` signatures are
rejected before calling JavaScript. Iterator failures propagate without an
extra `return()` call, as required by ECMA-262
[§7.4.19 IteratorToList](https://tc39.es/ecma262/#sec-iteratortolist).

The bridge keeps only the signature's bounded number of values while still
reading every excess iterator result before reporting an arity mismatch. This
follows [JavaScriptCore's operationIterateResults](https://github.com/WebKit/WebKit/blob/main/Source/JavaScriptCore/wasm/WasmOperations.cpp).
[V8](https://github.com/v8/v8/blob/main/src/builtins/builtins-iterator-gen.cc) and
[SpiderMonkey](https://github.com/mozilla-firefox/firefox/blob/main/js/src/wasm/WasmInstance.cpp)
materialize rooted collections before the same count check. Cynic also polls
host interruption/fuel during iteration in both the callback realm and the
outer calling realm, and applies its existing 16M-element iteration ceiling
with a RangeError. Collected values stay rooted through
later getters and conversions; externrefs remain pinned for the enclosing
Wasm call. Allocation failures retain `OutOfMemory` through both interpreter
and native host-call paths instead of becoming an unrelated JS throw.

The WPT multi-value fixture checks iteration before numeric conversion.
Focused tests add hardened realms, arbitrary iterator objects and callable
Proxy methods, thrown-value identity, mixed numeric/reference results,
allocation failure, GC pressure, start functions, and cross-realm nested calls.
These Wasm host-integration cases are outside test262's ECMAScript-only scope.

Typed function references now retain their defining type context throughout
the JS boundary: exported arguments, single/multiple host results, global
imports and setters, table set/grow, and exception payloads all validate before
use. Nullable references accept `null`, not `undefined`; optional constructor
and table arguments retain their specified defaults. Store wrappers and tag
identities preserve that context across imports and re-exports. Incompatible
store imports raise `LinkError` after the import getters finish; invalid
primitive imports fail during conversion. Ordinary conversion raises
`TypeError` before invocation or mutation.

This follows [ToWebAssemblyValue](https://webassembly.github.io/spec/js-api/#towebassemblyvalue),
[V8's module-aware JSToWasmObject](https://github.com/v8/v8/blob/main/src/wasm/wasm-objects.cc),
and [SpiderMonkey's CheckRefType at table writes](https://github.com/mozilla-firefox/firefox/blob/main/js/src/wasm/WasmJS.cpp).
Cynic compares the supported singleton final function definitions across
module-local indices, including nested references and nullability, rather
than introducing a global canonical-type registry. The worklist is iterative,
memoized, and capped at 4,096 type pairs / 65,536 value comparisons; exhaustion
raises a catchable exception, and temporary allocations are metered and freed. Rolled
self references remain distinct from references to an outer type, following
[Core type equivalence](https://webassembly.github.io/spec/core/valid/conventions.html).
Explicit GC recursive groups and declared subtypes remain unsupported.
Tests cover both execution tiers, GC pressure, aliasing, getter ordering,
resource limits, and allocation failures. No SES policy or test262 surface
changes are involved; Spasm's native call-layout guard remains a backstop.

All engine state lives in **typed internal slots** on `JSObject` /
`JSFunction`, never `__cynic_*` property keys (AGENTS.md "no engine
state on user-visible objects"), the same pattern as `iter_helper` /
`capability_record`. The records are opaque pointers into the realm's
`wasm_arena`; mutable Memory/Table buffers and executable mappings have
explicit teardown because their lifetime and accounting differ from arena
metadata:

```
WebAssembly.Module   → wasm_module slot → *ModuleState   (decoded module)
WebAssembly.Instance → wasm_instance_exports slot → frozen exports object
                       (prototype getter; GC-traced, including minor cycles)
WebAssembly.Memory   → wasm_memory slot → *MemoryState   (+ cached .buffer)
WebAssembly.Table    → wasm_table slot  → *TableState     (funcref / externref)
WebAssembly.Global   → wasm_global slot → *GlobalState
exported function    → wasm_export slot → *ExportRecord (instance, index)
```

`Memory.buffer` is a non-owning `ArrayBuffer` view over the live store backing
(an `array_buffer_external` flag keeps `deinit` from freeing them);
each `Memory` registers its materialized host views outside the JS property
graph and roots the current buffer of each wrapper cache. Superseded shared
views remain registered while reachable from JavaScript; object teardown
unregisters them before reclaiming their headers. Root traversal reaches instance-owned memories through the
instance registry and direct-constructor memories through their dedicated
registry. `Memory.commitGrowth` publishes the live backing, then refreshes
registered views without allocation or JS re-entry. Fixed non-shared buffers
detach and leave the registry; resizable buffers retain identity and update
their slices. The JS, interpreter, and Spasm growth paths all use this operation.
An
imported memory shares the provider's bytes (`Imports.share_memory`), so
writes propagate both ways; the spectest harness keeps the snapshot
(dupe) default. `externref` tables / globals and reference round-trips
through host calls work, GC-reclaimed precisely per §5. A JS-side `grow`
updates the shared `Memory` record and is visible to importing instances.
`v128` remains spec-rejected at the JS boundary (a TypeError,
§ToJSValue / §ToWebAssemblyValue).

### Memory buffer conversion and host resizing

`Memory.toFixedLengthBuffer()` and `toResizableBuffer()` follow
[Wasm JS API §5.3](https://webassembly.github.io/spec/js-api/#memories).
Repeated same-kind requests return the cached buffer. A kind change creates
and registers the replacement before detaching the old non-shared buffer, so
allocation failure leaves the old view usable. Resizable conversion requires
an explicit maximum; `ArrayBuffer.resize` grows the owning Memory in whole
64 KiB pages and cannot shrink. Existing typed-array and DataView length
tracking reads the refreshed buffer slice.

A typed `wasm_memory_buffer` slot connects borrowed buffers to their native
Memory, avoiding a pointer into the calling Realm. The detach callback clears
both the slice and this link before the owning store is released. Transfer
operations enforce the Wasm detach restriction after length coercion and never
free externally owned bytes. Ordinary transfer also reloads its source after
coercion and completes fallible allocations before detaching it.

Shared wrappers remain non-detachable and frozen. Old fixed SAB views keep
their original extent; growable views continue tracking the Memory even after
it switches to a fixed wrapper. Within the existing single-agent shared-memory
implementation, refresh callbacks repoint both kinds after backing relocation.
This does not add Wasm threads or cross-agent shared backing: the provisional
arena storage still needs replacement with `SharedDataBlock` for that work.
Superseded shared wrappers are weak registrations, so repeated conversions do
not retain unreachable wrappers forever. Shared-buffer slice rejects species
results that alias its backing; typed-array copies detect shared store identity
across distinct wrappers and preserve overlapping input bytes.

Prior art: [V8's ArrayBuffer transfer / ResizeHelper](https://github.com/v8/v8/blob/main/src/builtins/builtins-arraybuffer.cc)
checks detach restrictions before allocation and routes Wasm resize through
its owning Memory; [V8's WasmMemoryObject](https://github.com/v8/v8/blob/main/src/wasm/wasm-objects.cc)
and [JSC's JSWebAssemblyMemory](https://github.com/WebKit/WebKit/blob/main/Source/JavaScriptCore/wasm/js/JSWebAssemblyMemory.cpp)
preserve growable wrapper identity and leave old shared wrappers attached.
Cynic uses its existing provider-owned view registry for the same lifetime
contract. Tests cover both hardened postures, GC pressure, JIT growth, child
Realm teardown, and allocation failure. The adjacent test262 buckets are
ArrayBuffer, SharedArrayBuffer, TypedArray, and DataView.

## 9. SES / hardening

The `WebAssembly` namespace, its constructors, and prototypes freeze
under the hardened default like every other intrinsic; instances are
ordinary hardenable objects with typed slots (no observable engine
keys). `Memory.buffer` detaching on `memory.grow` stays observable —
spec-conformant and SES-fine.

The Cynic CLI enables WebAssembly byte compilation by default. Direct
embedders retain the narrower HostEnsureCanCompileWasmBytes policy through
`Realm.allow_wasm_compile`, which defaults to `false`: it guards
`new WebAssembly.Module(bytes)`, `WebAssembly.compile(bytes)`, and the
BufferSource overload of `WebAssembly.instantiate`. A refusal is a
`WebAssembly.CompileError`, matching the
[WebAssembly JS API hook](https://webassembly.github.io/spec/js-api/#hostensurecancompilewasmbytes)
and [CSP's Wasm integration](https://www.w3.org/TR/CSP3/#can-compile-wasm-bytes).

The policy does not disable the Wasm object model. `validate`, `Memory`,
`Table`, `Global`, `Tag`, `Exception`, `new Instance(module)`, and
`instantiate(module)` remain available when byte compilation is denied. This
is the same useful split exposed by hosts such as
[Cloudflare Workers](https://developers.cloudflare.com/workers/runtime-apis/webassembly/):
dynamic bytes may be refused while trusted/precompiled modules still run.
It is orthogonal to `allow_eval` and to hardened primordials. The historical
CLI spelling `--allow=wasm` remains accepted as a compatibility no-op.

Realm resource policy crosses the JS/Wasm boundary. Sarcasm polls the shared
execution controller at function entry, taken loop backedges, and proper tail
calls. Spasm carries the same optional controller through its native entry ABI,
direct links, cold call gates, imported calls, and indirect dispatch, polling
at function entry and taken structured-loop backedges. A bare embedding takes
one predictable null branch; a Realm-backed unmetered entry acquire-probes the
cooperative-interrupt byte and never calls the host while it remains clear.
Fuel exhaustion and interrupt-hook verdicts flow through the native trap
channel and latch the same uncatchable termination as Lantern. Wasm arena
metadata, transient invocation stacks, live Memory/Table backings, and Spasm's
OS-backed executable reservations are charged through `Heap.charge`, so
`setMemoryLimit` bounds both store and native-code memory as part of the
realm/agent budget. Obsolete growth buffers discharge immediately and native
code discharges after `munmap`. See
[resource-metering.md](resource-metering.md).

## 10. Performance posture

This is the **T0** tier — correctness-first, but at the right point in
the measured design space:

- In-place + O(1) side-table + threaded dispatch + unboxed value stack
  puts it in the `wamr-fast` / Wizard class on throughput, with the
  **best-in-class startup and memory** — the metrics Cynic's edge
  target actually rewards. Threaded dispatch is now in (§3 Decision 3);
  `zig build wasm-bench` is a standalone ReleaseFast harness for the
  dispatch-bound loop and recursive `fib`; it pairs bare Spasm with the
  Realm-like clear-wake-byte path in ABBA order so future hot-loop and
  metering changes stay measured. Recorded baselines live in
  [`wasm-bench-results.md`](../wasm-bench-results.md).
- Honest trade: `wasm3` is ~2–3× faster as an interpreter via a
  register rewrite + stack caching, paying 2–4× memory and a compile
  pass. We decline that trade on purpose.
- Documented future refinements (none change the in-place design),
  roughly in leverage order: **hoist the memarg align/offset
  and the memory `is_64` flag** out of the per-access path into the
  side-table; **stack caching** (top-of-stack in a register, like
  Lantern); **superinstructions** for common opcode pairs; a guard-page
  value stack. The real throughput jump comes from the **baseline JIT
  tier**, **Spasm** (the ~10×→~2–3× step), which consumes the validated
  module + side-table — exactly where V8/JSC/SM add Liftoff/BBQ over
  their interpreters. It now ships and is default-on for wasm — a
  single-pass, side-table-driven compiler that buries *asm* the way its
  parent does, on the codegen substrate shared with the JS tiers — and
  covers the complete scalar numeric ISA — i32/i64 and f32/f64 ALU,
  comparisons, div/rem with catchable traps, the memory family (incl.
  bulk-memory fill/copy/size), and every int↔float conversion (trapping
  and saturating) — plus globals, structured control flow, and same-module
  calls. Every defined function has a stable per-instance call gate: after
  lazy compilation a scalar cross-function call tail-enters the target native
  entry without a helper or code patch; cold or refused targets retain the
  checked helper boundary. Scalar self-recursion with no declared locals keeps
  its smaller local link. Imported, indirect, and cross-instance targets retain
  the checked generic dispatch and its interpreter fallback. Pinned in
  [jit.md](jit.md) §6, with the JS↔wasm
  call-boundary fast path (per-signature thunks, IC-integrated dispatch)
  in jit.md §7.1 (still deferred).

  The complete opcode surface above is the mature AArch64 backend. The
  qualified x86_64 SysV backend emits the complete scalar numeric family --
  including integer bit counts and sign-extension -- scalar globals, every
  scalar memory load/store width for memory32 and memory64,
  memory size/grow/fill/copy/init plus `data.drop`, catchable
  numeric/memory/native-stack traps, Realm
  entry/backedge polls, guarded local
  self-links, scalar `select`, value-carrying structured branches, `br_table`,
  nested explicit `return`, catchable `unreachable`, stable W^X-safe
  cross-function call gates,
  `call_indirect` / `call_ref`, `ref.null` / `ref.func` / `ref.is_null`, and the
  table get/set/size/copy/init/grow/fill family plus `elem.drop`. Runtime
  references use their full 128-bit scratch Cell across the helper boundary.
  Reference parameters/results/locals, typed select (including constructed
  types), single-result branches, and direct/indirect calls now preserve both
  halves throughout. Native call gates initialize reference locals to null;
  host calls and refused callees keep the checked helper boundary.
  Typed reference calls share indirect-call staging and memory-view refresh.
  They reject null, retain the full defining-instance reference, and preserve
  the caller's execution controller across foreign calls. Both dynamic call
  paths also forward uncaught Wasm exception records, not only trap codes.
  A native layout guard rejects incompatible host-supplied references before
  using the call buffer. The JS boundary additionally validates the supported
  final function-reference types with their defining module context (§8).
  `return_call`, `return_call_indirect`, and `return_call_ref` now compile on
  both targets. A bounded transfer record copies the arguments, then the
  native caller returns before a runtime loop enters the target. The loop
  reuses one Cell buffer, growing only for a larger target frame; tail-chain
  length does not grow the host stack. It preserves foreign instance state,
  execution controls, full Cells, and exception payloads. Host callbacks and
  unsupported targets retain their checked invocation paths. This is a
  helper-mediated implementation, not the deferred native-register tail-jump
  ABI; each transfer still pays runtime dispatch and local initialization.
  References and vectors preserve full Cells on both targets, including
  parameters/results, locals/globals, select, calls, and single-result merges.
  The shared SIMD foundation includes `v128.const/load/store` and `i32x4.add`
  (NEON on AArch64, baseline SSE2 on x86_64); memory accesses check the whole
  16-byte range before reading or writing, including memory64 overflow.
  All eight lane loads/stores also compile, checking only the lane's 1/2/4/8
  bytes and preserving the other vector lanes. `v128.any_true` checks both
  64-bit halves. These paths reuse scalar moves and existing Cell storage;
  x86 stays at SSE2 without lane-insertion/extraction ISA extensions.
  Scalar splats, every extract/replace-lane variant, and vector
  not/and/andnot/or/xor/bitselect also compile, preserving raw floating bits
  and signed/unsigned integer extraction through shared lane metadata.
  All four integer `all_true` and `bitmask` reductions compile with canonical
  i32 results, using baseline NEON/scalar operations on ARM and SSE2/scalar
  operations on x86. No optional SIMD extensions are required.
  Signed/unsigned integer min/max for 8/16/32-bit lanes also compile on
  both targets. ARM uses direct NEON instructions; x86 combines the SSE2
  min/max forms, saturated subtraction, and compare/select sequences.
  Integer `abs`/`neg` for 8/16/32/64-bit lanes and unsigned rounded averages
  for 8/16-bit lanes compile too. ARM uses direct NEON instructions; x86
  retains SSE2 with lane-width subtraction, sign masks, and `PAVGB/PAVGW`.
  Wrapping add/sub/mul, saturating 8/16-bit add/sub, all integer shifts,
  and byte popcount compile on both targets. Counts are masked to the lane
  width; x86 retains SSE2 through packed/scalar sequences where necessary.
  All signed/unsigned narrowing, low/high extension, and pairwise extended
  sums compile too. ARM uses direct NEON instructions; x86 uses SSE2 pack,
  unpack, shift, and multiply-add sequences. Unsigned i32-to-i16 narrowing
  explicitly clamps negative source lanes before biasing and signed packing.
  All low/high extended multiplications, signed halfword dot products, and
  saturating Q15 products compile on both targets as well. x86 reconstructs
  wider products using SSE2, with explicit signed corrections for i32 inputs.
  Dot sums wrap at 32 bits in native code and the interpreter fallback.
  Both floating lane widths also compile `abs/neg/sqrt` and `add/sub/mul/div`:
  direct NEON or packed SSE/SSE2 arithmetic, with bit-preserving sign masks
  for abs/neg on x86.
  Floating-point min/max for `f32x4` and `f64x2` use NaN-propagating NEON
  operations or SSE2 sequences that handle both signed-zero orders and
  canonicalize NaNs. Focused tests enforce quiet/canonical NaN rules and
  preserve subnormal lane bits; no runtime helper calls are needed.
  Floating `ceil/floor/trunc/nearest` use NEON directed rounding or the existing
  SSE2-compatible scalar raw-bit helpers per lane. The shared rounding helper
  explicitly quiets signaling NaNs in the interpreter and x86 native paths.
  Pseudo-min/max retain the first input bits on equal or unordered comparisons,
  using NEON comparison masks plus bit selection or reversed SSE min/max
  operands. This intentionally differs from ordinary floating min/max.
  Byte shuffle and strict/relaxed swizzle use NEON `TBL` or bounded scalar
  byte selections on x86, with no SSSE3 requirement or runtime helper call.
  Swizzle indices are checked against 16; relaxed swizzle retains Sarcasm's
  deterministic zero-on-invalid-index behavior on both targets.
  All standard SIMD numeric conversions and relaxed truncations compile via
  NEON conversions or fixed SSE2 scalar-lane loops. Truncations map NaNs to
  zero and clamp out-of-range values; `_zero` forms clear unused upper lanes.
  Unsigned i32-to-float conversion rounds once; widening preserves unread
  inputs. Relaxed truncation uses the same deterministic saturating behavior
  as Sarcasm, without runtime helper calls or a higher x86 ISA requirement.
  Relaxed multiply-add is unfused; relaxed lane selection, min/max, and Q15
  reuse the strict operations. Relaxed dot products saturate signed byte-pair
  sums to i16, then dot-add widens pairs and wraps the i32 accumulation.
  NEON and SSE2 implement the same choices as Sarcasm; ordinary permitted
  NaN payload variation remains. The interpreter's dot-add also wraps under
  safety checks instead of trapping on signed overflow.
  The six signed/unsigned widening loads (8x8, 16x4, 32x2) check and read
  exactly eight bytes before widening to a full vector, using NEON
  SXTL/UXTL or SSE2 unpacking with zero/sign masks. Memory64 overflow traps
  before access. All SIMD memory forms support explicit memory indices;
  the selected memory controls both address width and bounds. Nonzero
  memories use a fresh non-allocating base/length view without replacing
  the memory-zero cache, including after growth of an imported memory.
  Memory splats and zero loads use exact-width reads and preserve raw bits.
  All 48 integer/floating comparisons compile, including unsigned sign-boundary
  handling and NaN-aware floating ordering. The x86 i64 forms use scalar
  comparisons to retain the SSE2 baseline.
  Scalar loads/stores and size/grow/fill/copy/init also support explicit
  memory indices on both targets. Mixed-width copies use each memory's
  address type and the narrower count type. Imported aliases retain
  overlap-safe copying and a fresh memory-zero cache after growth.
  Table64 get/set, grow/size, fill/copy/init, and indirect calls use u64
  helper arguments and width-correct results on both targets. Mixed-width
  table copies use the narrower count type; table.init keeps i32 segment
  offsets/counts. Type-indexed block/loop/if signatures now carry parameters
  and multiple results on both targets. Branch merges preserve every scalar,
  reference, and vector value; loop polls preserve the transferred parameter
  state. Both backends compile catchable `unreachable` and terminating if
  arms. Branches to the implicit function label now use the return path,
  including conditional/table branches with multiple results. AArch64 branch
  tables also compile beyond the 12-bit comparison-immediate range; both
  targets retain linear dispatch. Oversized stacks and unsupported opcodes
  still refuse before code publication and run in Sarcasm.
  This is a coverage difference, not a semantic one: forced-Spasm sweeps on
  both architectures pass all 58,779 scored spec commands. Current native
  coverage and per-opcode refusals are in [wasm-results.md](../wasm-results.md).
  Both backends use the same bounded module-sized code reservation (64 KiB
  minimum, 4 MiB maximum), charged in full to a Realm's memory budget. The
  arena never relocates published code; allocation refusal or exhaustion
  still falls back to Sarcasm.
  The x86 scalar rounding fallback is
  deliberately helper-based on SSE2-only targets rather than assuming SSE4.1;
  remaining refusals are unsupported bytecode shapes/opcodes and resource
  limits, not vector signatures. Table indices stay full-width until after
  bounds checks; imported and defined tables use the same module-index
  lookup. The memory64 closure retains u64
  memarg offsets, traps effective-address carry, and covers grow plus the bulk
  memory family without changing the exact pass set. CI pairs
  `--spasm` with `--require-spasm-entry`, and the focused x86 instance/cache,
  trap, safe-point, self-link, and stable-gate tests require actual native
  entry, so the differential gate cannot be satisfied by fallback alone.
- **Narrowing the operand cell was measured and declined** (2026-06).
  Splitting the 128-bit `Cell` into parallel 64-bit lanes (scalars in
  the low lane only) was prototyped and benchmarked on Apple Silicon:
  the dispatch-bound arithmetic loop got ~5% faster, but recursive
  `fib` got ~5% *slower* — a u128 slot copy is a single 16-byte vector
  move on ARM64, and the split turns every type-blind move
  (`local.get`, frame argument/result shuffles — which dominate
  call-heavy code) into two loads + two stores on two distant cache
  lines. Net wash at best, plus a stale-high-lane discipline every
  full-width read must follow. Revisit only for a target where 128-bit
  moves are genuinely two ops, or as part of a baseline JIT's value
  representation.

## 11. Implementation map

| Step | Status |
|---|---|
| Decoder | §5 binary → parsed module — **done** |
| Validate + side-table | single-pass validation emitting the O(1) branch side-table (§4) — **done** |
| Interpreter | in-place **threaded** dispatch over bytecode + side-table — **done** (integer, control, floats, SIMD, references, tail calls, exceptions) |
| Memory | loads/stores, bulk-memory, grow; memory64 i64 addressing; **multiple memories** (memarg memory index, per-memory size/grow/fill/init, cross-memory copy, flag-2 data segments, aliased imports) — **done** (engine plain buffer; the JS `Memory.buffer` aliasing view + detach-on-grow ships in §8) |
| References / tables | tables, funcref/externref, `call_indirect`, element segments — **done**; typed function references (`(ref [null] $t)`, `call_ref` / `return_call_ref`, `br_on_null` / `br_on_non_null`, `ref.as_non_null`, subtyping, local-init tracking, table initializers) — **done**; externref GC rooting precise (§5), value-stack ref tags a future micro-opt |
| Floats / SIMD | float ops, sign-ext, non-trapping float→int, multi-value, v128, relaxed-SIMD — **done** |
| Cross-module linking | imported funcs/globals/tables/memories, shared tables, cross-instance funcrefs, host functions, start functions — **done** |
| Conformance | the WebAssembly spec testsuite harness → `wasm-results.md` — **done — 100% of the commands it scores** (the scored set excludes tests for unimplemented proposals) |
| JS API | `WebAssembly.*` typed-slot objects (`Module`/`Instance`/`Memory`/`Table`/`Global`/`Tag`/`Exception`), `compile`/`instantiate` Promises, imports incl. host functions, error types, i32/i64/f32/f64 marshalling, host byte-compilation policy — **done** (§8-9), incl. externref-across-JS (tables / globals / host round-trips), precisely GC-reclaimed (§5); v128 is spec-rejected at the boundary |
| Exception handling | tag section, `throw` / `throw_ref` / `try_table` (every catch form), `exnref`, cross-frame unwind + precise handler scoping — **done**; JS API `Tag` / `Exception` (`.is` / `.getArg`), tag imports/exports, uncaught wasm → JS `Exception`, GC-rooted reference payloads — **done** (§1, §8); a JS host exception caught by a wasm `try_table` (the JS→wasm direction), with identity-preserving re-raise — **done** (via an instance-set bridge over `call` / `call_indirect` / `return_call` / `return_call_indirect`; PTC semantics honoured — the caller's `try_table` is gone with its frame before the host runs, so a host throw is caught by the grandparent's `try_table`, not bogusly by the popped frame's) |

Conformance is scored against the official WebAssembly spec testsuite
(the `.wast` corpus), the same way `test262-results.md` scores ECMA-262.
Scalar and SIMD float expectations share a bit-based matcher for
[Core canonical/arithmetic NaNs](https://webassembly.github.io/spec/core/syntax/values.html#syntax-float),
following [WABT's expectation types](https://github.com/WebAssembly/wabt/blob/main/src/tools/spectest-interp.cc).
Canonical expectations allow only the quiet payload bit; arithmetic
expectations require that bit and allow additional payload bits. Both
accept either sign. Explicit numeric bit patterns stay exact, including
signaling NaNs and signed zeros; unknown NaN expectation tokens fail.
Matcher regressions run in both `zig build test` and `zig build test-fast`
(filter: `-Dtest-filter='wasm harness:'`). This is harness-only: no
ECMA-262/test262 or SES behavior changes.
