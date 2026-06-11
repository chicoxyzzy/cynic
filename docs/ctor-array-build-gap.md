# The ctor_array_build interpreter-tier gap — diagnosis and plan

Status: **research note — no production code changes.** This is the
measured explanation of why `bench/micros/ctor_array_build.js` runs
~2.4-3× slower on Cynic's interpreter tier than on the JIT-disabled
big-engine interpreters, plus a ranked plan of attack. One lever was
validated with a scratch (uncommitted) patch; everything else is an
estimate against the measured ledger, labelled as such. Companion to
[gc-generational-aging.md](gc-generational-aging.md) (aging: refuted,
do not re-chase) and [gc-parallel.md](gc-parallel.md) (parallel GC:
large-heap-only, irrelevant here).

The fixture (1.5M iterations):

```js
const p = new Point(i & 255, i & 127);   // 2-prop class instance
const a = [p.x, p.y, (i >> 2) & 255];    // 3-element array literal
acc += a[0] + a[1] + a[2];
```

Standing (bench-cross-results.md, interpreter tier, all JITs off):
cynic 318 ms (~210 ns/iter) vs sm 104 (gold, ~69 ns/iter), jsc 111,
v8 139, qjs 464. Cynic was ~499 before the virtual-array-length work
(`0ca290c`), the mark-prefilter / barrier split (`96817a1`), and the
JSObject slim-down to 400 bytes (`c6563a9` … `e1031f9`).

## Methodology

- All timing: ReleaseFast binary, `--no-jit` (Bistromath is the CLI
  default now), interleaved min-of-31 with `arith_loop`-shaped
  variant as noise control, machine checked for load/orphans first.
  Medians below matched the recorded cross-bench table within 2%
  (cynic 316 vs recorded 318; sm 102/101; jsc 106/106; v8 135/135),
  so the session's numbers are trustworthy.
- Opcode counts: `cynic run --dump-bytecode` (exact, static); peer
  engines via `d8 --print-bytecode` and `JSC_dumpGeneratedBytecodes=1`
  (exact), SpiderMonkey via source (its release shell ships no
  disassembler).
- Attribution: `samply` at ~1 kHz over a 15M-iteration scaled copy
  (3218 samples), symbolicated against `nm -n`, then **each sample
  assigned to exactly one bucket** by stack-marker priority — no
  double counting between inclusive trees. Caveat: LLVM ICF merges
  identical generic instantiations (`ArrayList(*T).append` shows up
  under one arbitrary instantiation's name), and the write-side
  `canonicalIntegerIndex` shares markers with the read bucket — both
  noted where they matter.
- Binary layout swings dispatch-tight micros ±5-12%; sub-10% claims
  below are flagged tentative. The A/B experiment used the same
  source tree ± one patch, interleaved.

## Where the ~210 ns/iter goes

### Opcode ledger

`--dump-bytecode` on the fixture: the loop body is **63 dispatches**
in the main chunk + **10 in the ctor** (`LdaThis, Star, Ldar,
StaProperty` ×2 + `LdaUndefined, Return`; verified on the identical
function-form body — class ctor chunks aren't dumped) = **73
dispatches/iteration**. The same loop on peers:

| engine | loop body | ctor | total | notes |
|---|---:|---:|---:|---|
| cynic | 63 | 10 | **73** | accumulator machine; `p`/`a` live in env slots (`LdaEnv`+`ThrowIfHole`+`Star` per access ×5); 3× `DefProperty` with string keys "0"/"1"/"2"; 3× `LdaSmi`+`LdaComputed` reads |
| v8 (Ignition) | 55 | 6 | **61** | `p`/`a` in registers; one `CreateArrayLiteral` (boilerplate, PACKED_SMI) + 3× `StaInArrayLiteral` (int key in register, keyed-store IC); 3× `GetKeyedProperty` (Smi key, never stringified). V8 also pays a context-slot load + `ThrowReferenceErrorIfHole` for `Point` per iteration |
| jsc (LLInt) | 27 | 5 | **32** | 3-operand register machine, no shuffle; **one `new_array dst, argv, argc`** consuming 3 consecutive registers; `get_by_val` with Int32 *constant* operands; ctor is `enter, create_this(inlineCapacity:2), put_by_id ×2, ret` |
| sm | n/a | n/a | n/a | release shell has no `dis()`; from `js/src/vm/Opcodes.h`: `NewArray(uint32 length)` preallocates, then `InitElemArray(uint32 index)` per element — index is an **immediate**, never a string; `GetElem` takes the int32 key from the stack |

Two structural observations, separated:

1. **Dispatch technique is NOT the gap.** Cynic wins `arith_loop`
   outright (28 ms vs jsc 34, sm 47, v8 49 in this session's matrix),
   and the ReleaseFast binary shows the labeled-`switch` loop
   compiled to ~540 per-arm indirect branches (threaded dispatch,
   the computed-goto shape) across a ~314 KB `runFrames`. Per-op
   dispatch cost is competitive; don't spend effort there.
2. **Dispatch *count* and per-op *work* are the gap.** 73 vs JSC's 32
   comes from the accumulator shuffle (`Star`/`Ldar`), the env-slot
   lowering of `p`/`a` (block-scoped consts are not register-
   allocated — verified unchanged when the loop is wrapped in a
   function), and one-op-per-element literal init. The per-op work
   gap is the next two ledgers.

### Variant ledger (interleaved min-of-31, medians, ns/iter)

Isolated variants, all preserving the loop + masking arithmetic:

| variant | cynic | sm | v8 | jsc | qjs |
|---|---:|---:|---:|---:|---:|
| arith only (control) | **19.0** | 31.5 | 32.9 | 22.5 | 33.7 |
| + ctor phase (Δ of `new Point` + `p.x`/`p.y`) | 63.7 | 22.8 | 22.8 | 29.5 | 142.6 |
| + array phase (Δ of literal + 3 reads) | 122.2 | 12.4 | 28.9 | 18.6 | 122.8 |
| full fixture | 210.7 | 68.1 | 89.7 | 70.7 | 304.9 |

Phases are additive within 3% on every engine (e.g. cynic
19.0+63.7+122.2 = 204.9 vs 210.7 measured), so the decomposition is
real. Cynic-only sub-splits: literal-no-reads 57.7 ns over control;
hoisted-array-reads-only 60.5 ns over control; object-literal
`{x,y}` instead of `new` 55.4; bare 2-arg function call 27.5.
Function-wrapping the whole loop changes nothing (208.5 vs 210.7) —
top-level global-slot `acc` access is not a factor.

Read of the table: **the array-literal-plus-reads phase is the
outlier — 122 ns vs SpiderMonkey's 12 ns, a 10× phase gap.** The
ctor phase is ~2.8× off. The baseline is fastest-in-class.

### Profile ledger (one bucket per sample, v3 @ 210.7 ns/iter)

| bucket | share | ns/iter | what's in it |
|---|---:|---:|---|
| dispatch + inline arm work | 37.4% | 78.7 | the 73 dispatches, operand decode, IC-hit fast paths, arith |
| indexed-read slow path | 22.9% | 48.3 | per `a[k]`: int32→`bufPrint` string (`computedKeyToString`), `coerceToPropertyKey`, `chainHasProxy` full-chain walk, `lookupAccessor` (own-shadow check via `hasOwn`), `JSObject.get` re-parsing the string back to an index (`canonicalIntegerIndex`), `tryGetIndexedOwn` |
| GC, amortized | 16.8% | 35.3 | minor cycle per 8192 allocs (= 4096 iters; ~366/run, every 8th full): root + mature-internal-slot mark (~5%), sweep+promote (~10%, of which `deinitFields` ~9.6% incl. the `elements` buffer free), worklist (~2%) |
| element append | 8.3% | 17.6 | 3× `def_property`: key decode, `canonicalIntegerIndex("0".."2")` parse, `appendDenseSequential` (`ArrayList` growth ⇒ one libc malloc per array), per-element write barrier |
| allocateObject ×2 | 4.9% | 10.3 | pool pop + ~400-byte header field-init + `objects_young.append`, ×2 |
| prop-write (ctor ICs) | 2.7% | 5.7 | two transition-IC `sta_property` hits (resizeSlots within inline cap, setSlot, barrier) |
| ctor frame | 1.9% | 4.1 | `frames.append`, register window, arg copy |
| env-slot stores | 1.0% | 2.2 | `StaEnv` for `p`/`a` |
| misc | ~4.1% | ~8.5 | `setObjectPrototype`, `strictEq`, `toBoolean`, platform memset |

Cross-checks against the variant ledger hold: the reads-only variant
attributes 53.5% to the indexed-read bucket (= ~14 ns of helpers per
read + its dispatch share, matching v3's 48.3/3); the literal-only
variant shows the same ~17 ns element-append and ~22 ns/dead-object
GC cost (its GC bucket is 28.9% of a smaller total). Per dead object
the sweep side costs ~18-22 ns (deinitFields' ~15 out-of-line-field
branches + the elements free for arrays + pool push) — paid for both
the Point and the array, every iteration, because **Metla's sweep is
per-object**: allocation appends to `objects_young`, death costs a
`deinitFields` walk + free-list push. Dead objects are not free.

## What the fast engines do differently

Verified locally (bytecode dumps above) or cited:

- **Array literal = one allocation-shaped op.** JSC `new_array dst,
  argv, argc, recommendedIndexingType` evaluates elements into
  consecutive registers and builds the JSArray + butterfly in one
  arm. V8 `CreateArrayLiteral` clones a PACKED_SMI boilerplate (the
  backing FixedArray comes pre-sized), then `StaInArrayLiteral`
  hits a keyed-store IC with an int key. SM `NewArray(3)`
  preallocates, `InitElemArray(idx)` carries the index as a u32
  immediate. **Nobody stringifies element indices, in either
  direction.** Cynic's `make_array` + 3× string-keyed
  `def_property` + 3× string-parsed reads is the 10× phase.
- **Indexed reads never leave integer-land.** V8 `GetKeyedProperty`
  / JSC `get_by_val` / SM `GetElem` take the int32 key and
  bounds-check into the elements store. Cynic's `lda_computed`
  formats the int into a stack buffer, then walks `chainHasProxy`
  over the full prototype chain, runs `lookupAccessor` (whose own
  `hasOwn` is what finally consults the element), and re-parses the
  string in `JSObject.get`. ~14-16 ns of helpers per read vs ~1-2 ns
  of bounds-checked load.
- **Instance allocation is profile-sized and bump-allocated.** JSC
  `create_this` carries `inlineCapacity:2` from the constructor's
  allocation profile — the Point's two slots are part of the one
  cell allocation. V8's jitless mode still runs feedback-vector ICs
  and bump-allocates in new space ([v8.dev/blog/jitless]: builtins
  stay embedded native code). Cynic's path is already decent here
  (pool pop + transition ICs; the 2.8× ctor-phase gap is mostly the
  10-op ctor body + frame machinery + header init).
- **Dead young objects cost ~zero.** V8/SM moving scavengers touch
  only survivors; dead nursery objects are reclaimed wholesale.
  JSC is the instructive non-moving case (same constraint as
  Metla): 16 KB MarkedBlocks per size class, **bump'n'pop**
  allocation — a completely-empty block is re-armed as a bump
  arena in O(1) instead of building a free list — with lazy
  block-granularity sweeping and sticky mark bits for eden
  collections ([webkit.org/blog/7122] Riptide). Crucially JSC's
  out-of-line storage (the butterfly) is itself GC-managed in
  size-class blocks, so a dead array needs **no per-object
  destructor**. Metla's per-object `deinitFields` + libc-malloc'd
  `elements` buffer is what forces per-corpse work.
- Hermes errs on the fixture (ERR in the recorded table) and QuickJS
  is slower than Cynic on every variant; neither is the target.

Prior-session results that stand (do not re-derive): GC-off
(huge `--gc-threshold`) makes this fixture ~55% *slower* at
13 MB→366 MB RSS — sweep-and-reuse keeps the working set
cache-resident, so "less GC" is not a lever. Generational aging:
~0% (refuted, [gc-generational-aging.md](gc-generational-aging.md)).
Conservative stack scanning: +12-31% alloc-heavy tax (parked on
`gc-conservative-membership`). Inline (in-header) array elements:
tried, reverted — +40 B on every JSObject regressed `object_alloc`
more than it saved.

## Ranked levers

Estimates are against the profile ledger above; they overlap (L2
shrinks the same element-append bucket L3b touches), so the sum is
an upper bound, not a forecast.

### L1 — int32-keyed dense-element fast path in `lda_computed` (validated)

When the key value is a non-negative int32 and the receiver is a
non-proxy Array exotic, serve `elements[idx]` directly: skip
ToPropertyKey (side-effect-free on an int32, §7.1.19), the
stringify, `chainHasProxy`, `lookupAccessor`, and the re-parse. A
present own element shadows any inherited accessor (§10.1.8.1
OrdinaryGet step 1) and ToPropertyKey of an int32 in array-index
range is exactly its canonical index string (§7.1.21), so a dense
in-bounds non-hole hit is observably identical; any miss (hole,
out-of-bounds, sparse, proxy receiver) falls through unchanged to
the §10.4.2 path.

**Validated with a ~20-line scratch patch** (reverted, not
committed), interleaved min-of-31 A/B, arith control −1.0% (noise):

| fixture | base med | patched med | Δ |
|---|---:|---:|---:|
| ctor_array_build | 300.9 ms | 229.7 ms | **−23.7%** |
| hoisted-array reads-only variant | 115.1 ms | 45.3 ms | −60.6% |

≈ **−47 ns/iter**. Risk: low; one opcode arm (mirror on
`sta_computed` for the write-side later). The production version
needs the standard gates (test262 `built-ins/Array` +
`language/expressions`, gc-stress on the bucket) and unit tests
first (red-first; differential-find shape). `array_iter` and any
index-loop fixture should also move. Interpreter-tier work; the
same helper shape is reusable by Bistromath's data-driven ICs —
coordinate, don't fork.

### L2 — fused array-literal opcode (`make_array_n`)

JSC's `new_array argv/argc` is the precedent: compiler evaluates the
N (non-spread, ≤ small cap) elements into consecutive temp registers
(the call-argv machinery already does exactly this), one opcode arm
does: `allocateObject` + exotic stamp + **one** exact-capacity
elements reserve + memcpy of N values + **one** write barrier scan.
Removes per-element: dispatch + key-constant decode +
`canonicalIntegerIndex` parse + `appendDenseSequential` checks +
ArrayList growth (today: one malloc per array via the growth path) +
N−1 redundant barrier calls. Eliminates most of element-append
(17.6 → ~6 ns) plus ~3 dispatches and the write-side canonical-parse
share. Estimate: **−15 to −20 ns/iter (−7-9%)**, plus it makes L3b
trivial (exact-size buffers are pool-class-friendly). §13.2.4.1
ArrayAccumulation semantics are preserved (elements are
CreateDataPropertyOrThrow on a fresh extensible array — the existing
`def_property` fast path's reasoning, hoisted to compile time).
Blast radius: compiler + one opcode + disasm; **a new opcode must
also be known to Bistromath** (tier-up on chunks containing it) —
that's a mechanical addition but requires the JIT track's sign-off.

### L3 — dead-object economics (three independent steps + one research track)

- **L3a: "plain object" deinit fast bit.** A header flag set false
  the first time any out-of-line field is created (bag entry,
  accessors, elements, extension, …). `deinitFields` on a
  still-plain object becomes a no-op; Point instances qualify
  (inline slots only), literal arrays don't (elements). Estimate
  −5 to −8 ns/iter. Low risk, small surface.
- **L3b: pool small element buffers.** Replace libc malloc/free for
  ≤8-slot element vectors with a per-heap size-class slab (same
  free-list shape as `object_pool`). Kills the malloc (element-
  append bucket) and the free (inside `deinitFields`, GC bucket).
  Estimate −8 to −15 ns/iter. Medium risk: ownership/teardown
  paths, realloc-on-growth past the class. This is the correct
  retry of the reverted inline-elements idea — same cache goal,
  zero bytes added to JSObject.
- **L3c: retire the per-minor-cycle O(mature) internal-slot scan.**
  `collectYoung` walks every mature container's typed slots each
  cycle because a residue of raw `container.field = young` writes
  bypasses the dirty-container barrier. Completing the funnel
  migration makes the dirty list authoritative and drops the scan.
  Estimate −3 to −5 ns/iter here (grows with realm size). Higher
  risk: GC completeness invariant — needs the gc-stress gate at
  `--gc-threshold=1`, multi-threaded too.
- **L3d (research, parked): block-structured bump'n'pop young
  space.** JSC-shape 16 KB per-type blocks, bump-while-empty,
  block-granularity sweep, wholesale empty-block reset — all
  compatible with non-moving Metla (addresses stay put; promotion
  stays a relink if generations are per-object bits). The honest
  caveat: block sweeping only pays once **no dead object needs a
  destructor**, i.e. after L3b moves the last per-corpse free into
  GC-owned pools; and it replaces the `objects_young` list that
  the whole collector currently iterates. That's a Metla redesign,
  not a patch — do it only if L1-L3c leave the GC bucket as the
  blocker. Prior art: Riptide [webkit.org/blog/7122]; Immix
  (Blackburn & McKinley 2008) for the mark-region shape.

### L4 — register-allocate uncaptured block-scoped consts (compiler)

`p` and `a` compile to environment slots (`MakeEnvironment 2` +
`StaEnv`/`LdaEnv ^0` + `ThrowIfHole`) even though nothing captures
them — verified in both script and function form. With
escape/capture analysis (the `function_scope_scan` substrate is
adjacent), an uncaptured, provably-initialized-before-use `const`
lowers to a plain register: each `p.x` read drops
`LdaEnv+ThrowIfHole` (3→2 ops), each `a[k]` read drops
`LdaEnv+ThrowIfHole+Star` (5→2 ops with the operand-form
`lda_computed`). ~11 fewer dispatches + the env-store traffic ≈
**−8 to −12 ns/iter** (tentative; dispatch-bucket math). TDZ
semantics (§14.7.4 / §6.2.8) are unobservable for a binding proven
initialized before every read in the same block. Compiler-only;
medium effort; benefits every block-scoped hot loop, not just this
fixture.

### L5 — smaller residuals

- Leaner `allocateObject` init: the `o.* = .{…}` field-init writes
  ~370 bytes of header per allocation (alloc bucket 10.3 ns for
  two) — a prezeroed-template memcpy or a further header shrink
  buys a few ns at most. Defer until after the JSObject diet's
  next step.
- `sta_this_property` fusion (ctor body is 10 ops where JSC does 5;
  the `LdaThis,Star` pairs around each store are pure shuffle):
  ~2-4 dispatches ≈ −2-3 ns. Tentative.
- A segregated `JSArray` heap kind (V8/JSC-style separate type):
  **not recommended** — the unified-JSObject costs this fixture
  still pays (header init breadth, per-corpse deinit walk) are
  addressed far more cheaply by L3a/L3b/L5a, and the type split's
  blast radius is the whole runtime.

### What this means for the JIT track (flag only — not designed here)

The full-speed-tier table shows ctor_array_build at **333 ms with
Bistromath on** vs 318 interpreted — the JIT doesn't move this
fixture, because the cost lives in the shared runtime helpers
(alloc, GC, the indexed-read slow path), not in dispatch. So L1-L4
are tier-independent wins that lift both rows, and the JIT row
cannot catch JSC's 15 ms without them. JIT-side levers beyond that
(allocation sinking / escape analysis for the dead `a`, inlined
bump-allocation sequences) belong to the Bistromath/Ohaimark track
and are intentionally not specced here.

## Recommended sequence

1. **L1** int32-keyed dense read fast path (validated −24%; do
   `sta_computed`'s mirror while in there). Gates: unit tests
   red-first, `built-ins/Array` + `language/expressions` test262
   buckets, `/gc-stress` on the bucket, full-sweep safety net.
2. **L3a** plain-bit deinit skip (small, independent, also helps
   `object_alloc` / `class_instantiate` / `promise_chain`).
3. **L2** fused `make_array_n` (coordinate the new opcode with the
   JIT track before landing).
4. **L3b** pooled small element buffers (after L2, sizes are exact).
5. **L4** register-allocated block consts (compiler track, parallel-
   izable with 3/4).
6. **L3c** dirty-only minor marking; then reassess whether **L3d**
   is still worth a Metla redesign.

Back-of-envelope end state if 1-5 land near their estimates:
~210 → ~120-135 ns/iter (~180-200 ms), i.e. from 3.1× off
SpiderMonkey to ~1.8-2×, overtaking V8's row. The remaining gap is
the per-corpse GC economics + the op-count delta, which is L3d/JIT
territory. Treat that number as a direction, not a promise — the
estimates overlap, and two of them are sub-10% (binary-layout
noise floor).

## Non-goals

- No GC pause-latency work (parallel/concurrent marking) — wrong
  bottleneck and wrong heap size class (see gc-parallel.md).
- No aging revival (refuted), no conservative-scan merge (taxed),
  no GC-off modes (measured slower).
- No dispatch-loop rewrite (tail-call experiments, handler
  reordering) — Cynic already wins the dispatch-bound fixture.
- No published numbers: bench-cross is the internal compass;
  nothing here goes to gh-pages.

## Code pointers

- Bytecode: `compileArrayLiteral`
  (src/bytecode/compiler.zig:2446) — `make_array` + per-element
  string-keyed `def_property`; the no-spread arm is L2's target.
- Interpreter: `lda_computed` (src/runtime/lantern/interpreter.zig,
  `.lda_computed` arm) — L1's insertion point ahead of
  `coerceToPropertyKey`; the `def_property` arm +
  `JSObject.appendDenseSequential` (src/runtime/object.zig) — the
  element-append path L2 subsumes; `computedKeyToString` /
  `lookupAccessor` (src/runtime/lantern/helpers.zig) — the slow
  machinery L1 bypasses.
- Heap: `allocateObject` / `collectYoung` / `promoteYoungList`
  (src/runtime/heap.zig) — header init, the per-corpse sweep, the
  O(mature) typed-slot scan (L3a/L3c/L3d); `JSObject.deinitFields`
  (src/runtime/object.zig:1950) — the 15-branch corpse walk (L3a).
- Compiler scope machinery for L4: src/bytecode/scope.zig,
  src/bytecode/function_scope_scan.zig.
- Session measurement scripts (variants, interleaved A/B harness,
  profile bucketizer) lived in `/tmp/ctorgap/`; they are
  reproducible from this note's method section and are deliberately
  not committed.
