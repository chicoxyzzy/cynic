# Cynic micro-bench history

Per-fixture wall-time + peak RSS on the hand-picked micro-bench
suite in `bench/micros/`. Produced by `zig build bench` — a
dedicated ReleaseFast `cynic-bench` binary, median of 10 runs after
a discarded warmup. Matched with `tools/bench-cross.sh` so
single-engine and cross-engine numbers come out of the same sample
budget — see the "Measurement protocol" section of
[`docs/benchmarking.md`](docs/benchmarking.md).

**Numbers are only stable on a quiet machine, and only comparable
within the same `host` line.** Cross-machine and cross-engine
comparison is meaningless here — see `docs/benchmarking.md`.

Newest run first. Append a fresh section per recorded run; diff a
new run against the previous section with the *same host*.

## History

### 2026-07-31 — width-gated Smi `BitAnd` successor threading, host `Linux 6.8.0-117-generic x86_64` (remote bench box)

Exact merged main `7b5a04e5` and the retained candidate used normal
ReleaseFast CLI SHA-256 binaries `4152253e` / `7d808bff`. Instrumented
Crypto traces found **3,158,688** `LdaSmi16 -> BitAnd` pairs and
**1,488,595** full-width `LdaSmi -> BitAnd` pairs. The candidate bypassed
the indirect successor dispatch on **4,646,882** of them: **99.991%** of
the eligible pairs and **5.176%** of Crypto's **89,774,038** logical
instructions. The remaining 401 pairs had a non-Int32 left operand and
correctly entered the shared coercion path.

The bytecode and both JIT tiers remain unchanged. Lantern's existing merged
Smi-load handler recognizes only full-width and 16-bit loads followed by
`BitAnd`; compact `LdaSmi8` is deliberately excluded because Splay executes
it 2,084,482 times without a useful successor. On an Int32 left operand the
load handler runs the same pure integer AND and consumes the successor opcode
plus register operand. A Double, coercible object, or BigInt also consumes the
successor, then enters the shared `bitwiseBinary` ToNumeric / BigInt / throw
operation exactly once. This avoids both a second Int32 probe and a second
dispatch without creating another coercion implementation. Successful Int32
hits use `observeDirectActive`; fallbacks use `observeActive`, preserving
logical telemetry in either case.

After normalizing only `direct-transfers`, the complete baseline/candidate
Crypto reports are byte-identical: same static bytecode, dynamic instruction
total, every opcode/pair/trigram row, and zero dropped sequences.
`direct-transfers` moves **634,631 -> 5,281,513**, exactly the **4,646,882**
new Int32 hits. The unlikely branch hint keeps the grouped load handler's
dominant `LdaSmi8` / non-`BitAnd` decode path biased toward fallthrough. The
native cost is **894 bytes** in `runFrames` (**331,289 -> 332,183**) and
**896 bytes** in GNU `size` text (**4,783,754 -> 4,784,650**).

The runner's even-sample median was corrected during review to average the two
middle samples; every number below was rerun after that fix. Forty paired
Lantern-only runs in each physical launch role pinned the driver and every
child process to CPU 0. Forward is candidate/base, reverse is base/candidate
after swapping the physical binaries, and neutral is
`sqrt(forward / reverse)`. Spread is `(max-min)/median` of paired ratios:

| bench | forward C/B | spread | reverse B/C | spread | neutral C/B |
|---|---:|---:|---:|---:|---:|
| richards | 0.976x | 22.1% | 1.025x | 19.3% | 0.9758x |
| deltablue | 1.002x | 18.3% | 1.006x | 21.7% | 0.9980x |
| crypto | 1.019x | 20.9% | 0.988x | 18.0% | 1.0156x |
| raytrace | 0.991x | 30.3% | 0.983x | 26.1% | 1.0041x |
| navier_stokes | 1.019x | 24.3% | 0.987x | 28.2% | 1.0161x |
| splay | 1.006x | 21.6% | 0.999x | 23.5% | 1.0035x |
| **geomean** |  |  |  |  | **1.0021x** |

The order-neutral macro result is retention evidence rather than a resolved
effect size: the geomean is **1.0021x**, every workload remains inside the 2%
regression gate, and several spreads exceed 20%. Targeted slow-path controls
also retain performance:

| control | pairs/order | forward C/B | spread | reverse B/C | spread | neutral C/B |
|---|---:|---:|---:|---:|---:|---:|
| `bit_and_double` | 60 | 0.990x | 29.1% | 1.010x | 45.0% | 0.9900x |
| `bit_and_object` | 100 | 0.997x | 49.4% | 1.001x | 42.5% | 0.9980x |

Twenty-pair arm64 confirmation on `Darwin 25.6.0` measured **0.9964x**
across the same six macros. Its per-workload neutral ratios were Richards
**0.9920x**, DeltaBlue **1.0055x**, Crypto **0.9766x**, RayTrace **1.0116x**,
Navier-Stokes **0.9881x**, and Splay **1.0050x**; the largest regression was
1.16%. The x86 A/A calibration itself measured **0.988x** with 45.3% spread,
so the high-spread VM rows above are deliberately reported as gates, not
claims of precise speedup.

The small final shape matters. A V8-Ignition-style accumulator-immediate
opcode family was prototyped (Ignition ships `BitwiseAndSmi`,
`BitwiseOrSmi`, `BitwiseXorSmi`, and the three Smi shifts
[in its bytecode set](https://github.com/v8/v8/blob/d405ed7c7b8141bb435ed5cf651163fa32e0d11a/src/interpreter/bytecodes.h#L225-L268)).
The best direct-transfer superinstruction kept object coercion neutral but
regressed Navier-Stokes by **6.3%**; sharing the handler removed the cloned
tail but regressed the object control by **5.2%** and Navier-Stokes by
**3.2%**. A compact primitive-Number successor path cost only 93 native bytes
but regressed the object control by **7.9%**. All were rejected. The retained
bytecode-preserving path is larger, but it is the only reviewed shape that
keeps one coercion operation and clears both architecture gates.

Validation on the locked final snapshot covers both threaded widths, the
deliberately ordinary Smi8 path, Int32 and Double operands, general-LHS
evaluation order, one-shot object coercion, a caught coercion throw, logical
telemetry, allocation-pressure GC, and the benchmark driver's true even
median. Exact-main and candidate `bitwise-and` test262 pass lists remain
identical at **29 pass / 1 known fail**, including under `gc-threshold=1`.
The required non-cached full sweep retained **48,653 pass / 1,324 fail**, plus
ShadowRealm **63 / 1**, with no pass-count change.

### 2026-07-30 — target-specific computed-receiver register reuse, host `Darwin 25.6.0 arm64`

Exact stats-enabled ReleaseFast binaries from merged main `339818b0` and the
candidate implementation (SHA-256 prefixes `7d06db73` / `58d647d3`) isolate
the deterministic effect on Navier-Stokes. Logical instructions fell
**58,160,156 → 53,605,322**, removing **4,554,834 dispatches (-7.83%)**.
Static bytecode moved **1,934 → 1,916 instructions** and **4,546 → 4,499
bytes**; the script-wide maximum register count remained 28. Fifteen source
reads became eligible. Baseline `Mov → IncReg` pairs executed **4,587,520**
times, including **4,456,448** `Mov → IncReg → LdaComputed8` triples.
Removing the sites' 14 `Mov` snapshots and one `Star` snapshot also exposed
the existing finalizer's reload/fusion rewrites.

§13.3.2.1 property-access evaluation, via §13.3.3
EvaluatePropertyAccessWithExpressionKey, fixes the receiver value before
evaluating the computed key. Cynic therefore normally snapshots a
register-bound receiver before a key that may write a register. For the
specific `receiver[++index]` / `receiver[index++]` / decrement shapes, the
compiler can resolve both bindings before emission: when the receiver and
updated binding are distinct initialized register slots, the update cannot
clobber the receiver. Final bytecode consequently changes from

    Mov r_receiver, r_tmp
    IncReg r_index
    LdaComputed8 r_tmp

to

    IncReg r_index
    LdaComputed8 r_receiver

with no new opcode or dispatch-table entry. Same-register updates such as
`a[++a]`, assignments, member/destructuring targets, env/global/TDZ
bindings, captured receivers, and optional chains retain the snapshot or
nullish-short-circuit path. The receiver remains a frame-register GC root
while `ToNumeric` re-enters JavaScript.

Representative interpreter prior art keeps the evaluated receiver separate
while the key is evaluated: V8 Ignition visits the base into a register,
evaluates a keyed property expression into the accumulator, then issues
`LoadKeyedProperty(obj)` ([source](https://github.com/v8/v8/blob/f4a59ca0ef1286ac4eccda99a90fccf1aea1ac93/src/interpreter/bytecode-generator.cc#L6503-L6547),
[call site](https://github.com/v8/v8/blob/f4a59ca0ef1286ac4eccda99a90fccf1aea1ac93/src/interpreter/bytecode-generator.cc#L6835-L6842));
Hermes HBC lowers a computed read to `GetByVal(result, obj, prop)`
([source](https://github.com/facebook/hermes/blob/ccc2a2f35267d5009d3fb24b61120357cdba0acb/lib/BCGen/HBC/ISel.cpp#L750-L774));
and QuickJS's `get_array_el` consumes distinct object and property stack
operands ([source](https://github.com/bellard/quickjs/blob/04be246001599f5995fa2f2d8c91a0f198d3f34c/quickjs-opcode.h#L140-L142)).
Cynic's narrower contribution is reusing an already-bound receiver register
when a target-specific write proof makes the extra snapshot unnecessary.

Forty paired Lantern-only runs in each launch order used exact non-stats
baseline/candidate SHA-256 binaries `8c49a670` / `64fe2890`. The forward
runner reports candidate/base, the swapped runner reports base/candidate, and
the order-neutral candidate/base ratio is
`sqrt((forward C/B) / (reverse B/C))`. A first run immediately after
compilation showed process-wide spreads as high as 892% and was discarded in
full. A fresh 40+40 run after the other local jobs settled was materially
less distorted, though its per-workload spreads still ranged from 7.1% to
91.2%:

| bench | forward C/B | reverse B/C | neutral C/B |
|---|---:|---:|---:|
| richards | 0.998x | 0.998x | 1.000x |
| deltablue | 1.001x | 0.997x | 1.002x |
| crypto | 1.000x | 1.008x | 0.996x |
| raytrace | 1.005x | 1.005x | 1.000x |
| navier_stokes | 0.977x | 1.033x | 0.973x |
| splay | 1.018x | 1.001x | 1.008x |
| **geomean** |  |  | **0.996x** |

The order-neutral arm64 macro estimate is **0.9964x**. Given the retained
spread, the sub-percent geomean is a no-regression signal rather than a
precise speedup magnitude. Navier-Stokes measures **0.9725x** across the two
roles, while the worst resolved workload estimate is Splay at **1.0085x**.

The pinned-CPU x86_64 confirmation used exact base `339818b0` and
candidate `70368694`, normal ReleaseFast CLI SHA-256 prefixes `08d68fa5` /
`3700c82d`, and an exact-main benchmark driver (`0e7c03a3`). The driver and
all child processes inherited `taskset -c 3`. Forty pairs in each physical
launch role produced:

| bench | forward C/B | reverse B/C | neutral C/B |
|---|---:|---:|---:|
| richards | 0.999x | 1.024x | 0.988x |
| deltablue | 0.979x | 1.009x | 0.985x |
| crypto | 1.002x | 1.009x | 0.997x |
| raytrace | 1.019x | 1.016x | 1.001x |
| navier_stokes | 0.966x | 1.025x | 0.971x |
| splay | 1.005x | 0.977x | 1.014x |
| **geomean** |  |  | **0.993x** |

The neutral x86_64 geometric-mean estimate is **0.9925x**. Navier-Stokes
measures **0.9708x**, and the worst workload is Splay at **1.0142x**, below
the 2% retention gate. A separate 20-pair run in each
production-default-tier role measured a **0.9955x** neutral geometric mean;
its per-workload neutral ratios were **0.995x, 1.000x, 0.993x, 1.003x,
0.970x, and 1.012x**, respectively. Interpreter spreads remained
19.4–45.2%, and default-tier spreads 13.6–38.8%, so these sub-percent
geomeans are directional retention evidence, not precise effect sizes.
Crucially, both launch roles independently show the targeted Navier-Stokes
improvement and every order-neutral workload stays inside the 2% gate.

Validation covered prefix/postfix increment and decrement code generation,
same-register and assignment fallback, capture during key coercion, and
forced-GC re-entry. All eight relevant non-cached test262 buckets had
identical tallies and displayed runtime-failure sets across Lantern, forced
Bistromath, and forced Ohaimark. The complete ReleaseSafe unit suite retained
**3,341 pass / 261 intentional skips / 0 fail**. The non-cached full test262
sweep retained **48,653 pass / 1,324 known fail**, plus ShadowRealm
**63 / 1**.

### 2026-07-30 — finalized `StarLdar` store/load fusion, host `Darwin 25.6.0 arm64`

Exact merged-main and final-candidate bytecode telemetry over the six macro
workloads recorded **17,500,773** executions of the new
`StarLdar dst, src` opcode at **704 static fused sites**. Baseline logical
instructions fell **348,164,417 → 330,663,644**: one dispatch removed per
execution, or **5.03%** of the old total. Aggregate encoded bytecode shrank
**45,664 → 45,392 bytes** (-272):

| bench | baseline instructions | candidate instructions | `StarLdar` executions |
|---|---:|---:|---:|
| richards | 104,678,462 | 104,321,361 | 357,101 |
| deltablue | 40,203,516 | 39,702,815 | 500,701 |
| crypto | 103,974,302 | 91,262,914 | 12,711,388 |
| raytrace | 16,246,778 | 15,928,519 | 318,259 |
| navier_stokes | 61,219,557 | 58,160,156 | 3,059,401 |
| splay | 21,841,802 | 21,287,879 | 553,923 |

The post-regalloc pass works on finalized bytecode, after redundant reload,
dead-store, and dead-accumulator-copy elimination. It fuses only
distinct-register `Star dst; Ldar src` pairs whose load is not a branch,
switch, or exception-handler entry. Generic/generic pairs shrink from four
bytes to three and mixed compact/generic pairs stay at three; compact/compact
pairs remain two bytes so re-emission never grows code after branch
relaxation. `StarLdar` stores before loading, which defines the alias case
even though the normal compiler gives same-register pairs the stronger
reload-deletion rewrite. The shared re-emitter repatches branches, source
positions, handlers, and switch tables. Lantern, Bistromath, and Ohaimark all
execute the operation. Fusion also proves that a successor opcode exists:
the resulting Lantern handler can decode that known-present byte directly
instead of cloning the generic checked end-of-chunk error tail. On arm64 this
keeps the handler to 44 bytes and `runFrames` just 8 bytes larger than main.

Forty paired Lantern-only runs in each launch order used exact
baseline/candidate binary SHA-256 prefixes `2da04af` / `c8b4764`. The forward
runner reports candidate/base, the swapped runner reports base/candidate, and
the order-neutral candidate/base ratio is
`sqrt((forward C/B) / (reverse B/C))`:

| bench | forward C/B | reverse B/C | neutral C/B |
|---|---:|---:|---:|
| richards | 1.010x | 0.995x | 1.008x |
| deltablue | 1.001x | 1.006x | 0.998x |
| crypto | 0.961x | 1.043x | 0.960x |
| raytrace | 0.985x | 1.013x | 0.986x |
| navier_stokes | 0.980x | 1.027x | 0.977x |
| splay | 0.996x | 1.015x | 0.991x |
| **geomean** |  |  | **0.986x** |

The order-neutral macro result is therefore **0.986x**, or **1.4% faster**.
Only Richards regresses, by 0.8%. A separate 20-pair
production-default-tier control measured a **0.988x** neutral geometric mean
(about **1.2% faster**). Its per-workload neutral ratios were **0.997x,
0.997x, 0.963x, 1.002x, 0.977x, and 0.992x**, respectively; natural tier-up
and host noise make the aggregate the useful signal.

The pinned-CPU x86_64 confirmation used exact base `7949d5f8` and candidate
`62c6335f`, pinned the driver and inherited children to CPU 3, and verified
baseline/candidate SHA-256 prefixes `f2e0b6e2` / `c4d7f531`. Forty pairs in
each role produced:

| bench | forward C/B | reverse B/C | neutral C/B |
|---|---:|---:|---:|
| richards | 1.005x | 0.997x | 1.004x |
| deltablue | 1.010x | 0.979x | 1.016x |
| crypto | 0.973x | 1.024x | 0.975x |
| raytrace | 0.997x | 1.003x | 0.997x |
| navier_stokes | 0.963x | 1.026x | 0.969x |
| splay | 0.999x | 1.005x | 0.997x |
| **geomean** |  |  | **0.993x** |

Thus the final x86_64 candidate improves the macro geomean by **0.7%**, with
all workload regressions below the 2% gate. The VM remained noisy
(21–47% per-run spreads in the decisive sample), so both launch roles matter.
Its zero-hit `arith_loop` control measured **1.012x / 0.983x / 1.015x**
forward, reverse, and neutral with 38–59% spreads; the raw macro gate above is
the primary result.

The compact decode is material rather than cosmetic. The first implementation
used the generic checked decode tail, grew `runFrames` by 136 bytes, and
failed the same x86_64 gate at **1.012x** neutral, including Richards
**1.040x**, DeltaBlue **1.028x**, and RayTrace **1.025x**. Proving a successor
and shrinking the handler to 44 bytes turned that cross-architecture
regression into the retained result above.

`array_iter` provides a dynamic-count check: two static sites execute
**1,010,100** times, moving **14,091,633 → 13,081,533** logical instructions
exactly as predicted. `arith_loop` and `prop_access` contain no eligible
sites. `arith_loop` executes a compact/compact `Star3; Ldar1` pair five
million times, but deliberately keeps its two-byte encoding; its 40-pair
forward, reverse, and neutral timings were **0.988x / 1.012x / 0.988x**, so
it serves as a dispatch-layout control rather than evidence from fused
execution.

Validation covered focused fusion, CFG/leader, re-emission, liveness,
disassembly, Lantern alias-ordering, compiler-pipeline, forced Bistromath,
and forced Ohaimark tests plus the complete ReleaseSafe unit suite. The
language test262 pass list was byte-identical across interpreter, forced T1,
and forced T2 at **22,122 pass / 1,070 known fail**. The non-cached full
sweep retained **48,653 pass / 1,324 known fail**, plus ShadowRealm
**63 / 1**.

### 2026-07-30 — consumed postfix register updates, host `Darwin 25.6.0 arm64`

Bytecode telemetry isolated Crypto's consumed postfix register update as the
largest remaining exact sequence. An instrumentation-only build from
`b40518d8` (the compiler and macro sources are identical to merged baseline
`da6e1ce7`; the intervening changes are property-handler-only) recorded
118,864,402 logical instructions. It executed
`ToNumeric → Star old → Inc` 2,983,837 times; the following `Star0` and
`Star3` register writebacks identified the two dominant register sites.
Re-running the same telemetry on the final bytecode measured
**2,977,794 `PostIncReg`** and **226 `PostDecReg`** executions.
Collapsing each six-op
`Ldar; ToNumeric; Star old; Inc; Star binding; Ldar old` sequence to one
dispatch removes **14,890,100 instructions**, or **12.53%** of Crypto's old
dynamic total (118,864,402 → 103,974,302). Static Crypto bytecode also shrinks
by 130 instructions and 187 bytes.

The compiler now emits `PostIncReg` / `PostDecReg` for a consumed postfix
update of a non-TDZ register binding. The opcode performs GetValue,
ToNumeric, and the type-matched Number/BigInt bump; it commits only the
bumped value to the binding while leaving the coerced **old** numeric value
in the accumulator. Throwing coercion therefore leaves the binding
unchanged. For object-to-BigInt coercion, the old BigInt is published through
the frame accumulator before allocating the bumped BigInt, so it remains a
GC root without temporarily mutating the binding.

This follows existing interpreter prior art rather than inventing a novel
result convention: V8's bytecode generator has an explicit TODO for proper
`PostInc` / `PostDec` bytecodes after its current ToNumeric-and-save lowering
([source](https://github.com/v8/v8/blob/0616192af6309f2121f27ad735485db602c11fa6/src/interpreter/bytecode-generator.cc#L7514-L7735)),
while QuickJS already carries dedicated `post_inc` / `post_dec` opcodes
([source](https://github.com/bellard/quickjs/blob/04be246001599f5995fa2f2d8c91a0f198d3f34c/quickjs-opcode.h#L218-L227)).
The new forms remain an intentional JIT tier boundary: the old sequence was
already refused by Bistromath and Ohaimark at `ToNumeric` / `Inc`, so
coverage is unchanged.

On 40 interleaved Lantern-only pairs, exact candidate/base SHA-256 binaries
improved the six-macro geometric mean to **0.9960x**:

| bench | base_ms | head_ms | ratio | spread% |
|---|---:|---:|---:|---:|
| richards | 242.07 | 241.74 | 1.005x | 44.0 |
| deltablue | 175.39 | 173.52 | 0.993x | 15.2 |
| crypto | 134.15 | 128.92 | 0.962x | 41.9 |
| raytrace | 78.31 | 78.41 | 1.003x | 24.9 |
| navier_stokes | 98.17 | 99.66 | 1.013x | 92.7 |
| splay | 167.90 | 168.52 | 1.001x | 42.6 |

Swapping the binaries confirmed a **0.9951x** candidate/main geometric mean.
The inverted candidate ratios were **1.004x, 0.993x, 0.958x, 0.997x,
1.025x, and 0.995x**, respectively. Thus the targeted Crypto gain is
3.8–4.2%; the dispatch-table layout costs Navier 1.3–2.5%, but the suite
geomean remains positive in both launch orders.

The clean x86_64 gate used new `/tmp` checkouts at exact base `da6e1ce7`,
verified the local source patch before building distinct ReleaseFast binaries,
and pinned the driver plus inherited children to CPU 3. Thirty forward pairs
improved the geometric mean to **0.9770x**:

| bench | base_ms | head_ms | ratio | spread% |
|---|---:|---:|---:|---:|
| richards | 583.14 | 577.30 | 0.980x | 20.1 |
| deltablue | 426.45 | 423.68 | 0.989x | 13.6 |
| crypto | 392.69 | 363.39 | 0.920x | 25.2 |
| raytrace | 211.40 | 202.76 | 0.957x | 23.6 |
| navier_stokes | 249.72 | 253.70 | 1.020x | 24.5 |
| splay | 481.84 | 484.07 | 0.999x | 16.7 |

The swapped 30-pair run produced a **0.9802x** candidate/main geometric mean;
its inverted candidate ratios were **0.984x, 0.981x, 0.918x, 0.964x,
1.034x, and 1.003x**. Combining both launch orders gives **0.9786x**
order-neutral: Crypto improves 8.1%, Navier gives back 2.7%, and the whole
macro set improves 2.1%. Base/candidate binary SHA-256 prefixes were
`416a20e3` / `59a1f528`; all 360 timed invocations succeeded.

Two smaller encodings were measured and rejected. A single
`PostUpdateReg r, delta` opcode made Crypto **1.021x** slower than the
two-opcode form (the swapped comparison was **1.027x** slower after
inversion) and regressed the six-macro baseline geomean to **1.0041x**.
A `PostIncReg`-only hybrid avoided the nearly cold decrement opcode but
landed at **0.9990x / 0.9955x** in 40-pair forward/swapped runs, for a
combined **0.9972x** versus the symmetric pair's **0.9955x**. The extra
opcode therefore earns its dispatch-table slot empirically, not merely for
symmetry.

Validation covered the complete ReleaseSafe unit suite (**3,332 pass / 261
expected skip**), dedicated Int32/double/`-0`/NaN/infinity/overflow,
string/Boolean/null/undefined, BigInt, object-coercion, Symbol, thrown
coercion, failure-atomicity, and alternating-GC tests, plus the focused
postfix increment/decrement test262 buckets in interpreter, forced-T1, and
ReleaseSafe `gc_threshold=1` postures. The non-cached full sweep retained the
merged pass set (**48,653 pass / 1,324 fail**, plus ShadowRealm **63 / 1**).
Independent correctness and performance reviews found no actionable issue.

### 2026-07-30 — impossible property-probe gates, host `Linux 6.8.0-117-generic x86_64` (remote bench box)

Pinned-CPU `perf` profiles of exact merged main `b40518d8` found two pure
classification paths doing work before the runtime knew that their result
could matter:

- `typedArrayChainSetDecision` accounted for **4.26%** of Navier-Stokes and
  **2.46%** of Crypto callgraph cycles. It ran
  §7.1.21 CanonicalNumericIndexString parsing and NumberToString round-tripping
  before discovering that the receiver's prototype chain contained no
  TypedArray.
- `tryFillSyntheticPrototypeLoadIC` accounted for about **2.5%** of Richards
  and **9.8%** of DeltaBlue inclusive cycles. The macro posture is
  `--unhardened`, so the override-mistake installation pass creates zero
  `SyntheticAccessor` cells, but every eligible named-load miss still probed
  shapes, property tables, accessors, and the prototype chain.

Head first rejects property keys whose leading byte cannot begin any canonical
numeric spelling (decimal digit, `-`, `I`, or `N`), then walks to the first
TypedArray ancestor, and only then performs the full canonical parse. The
prototype walk and parser are both pure, so their order is unobservable and the
first TypedArray still owns the §10.4.5.6 decision. Separately, the synthetic
load-IC fill helper returns immediately when the realm's authoritative
`synth_accessor_cells` table is empty. Snapshot restore repopulates that table
before execution, making its emptiness a stronger capability test than the
mutable hardened-posture flag. The gate deliberately remains inside the
outlined helper: call-site forms removed its prologue too, but destabilized the
giant dispatch handlers enough to regress unrelated macros.

On `Darwin 25.6.0 arm64`, 40 interleaved Lantern-only pairs improved the macro
geometric mean to **0.9702x**:

| bench | base_ms | head_ms | ratio | spread% |
|---|---:|---:|---:|---:|
| richards | 237.36 | 231.16 | 0.976x | 6.3 |
| deltablue | 183.06 | 166.94 | 0.911x | 3.9 |
| crypto | 131.68 | 128.86 | 0.983x | 6.1 |
| raytrace | 76.14 | 75.87 | 1.000x | 4.5 |
| navier_stokes | 99.49 | 95.13 | 0.957x | 14.9 |
| splay | 160.44 | 159.88 | 0.997x | 4.5 |

Swapping the binaries produced a **0.9666x** candidate/main geometric mean;
the inverted per-fixture ratios were **0.974x, 0.910x, 0.981x, 0.994x,
0.955x, and 0.988x**.

The clean x86_64 rebuild used a distinct install prefix and SHA-256, then ran
30 pairs with the driver and both children pinned to CPU 3. Forward order
improved the geometric mean to **0.9688x**:

| bench | base_ms | head_ms | ratio | spread% |
|---|---:|---:|---:|---:|
| richards | 579.16 | 572.64 | 0.981x | 22.8 |
| deltablue | 448.12 | 419.89 | 0.940x | 24.4 |
| crypto | 382.54 | 367.47 | 0.959x | 41.1 |
| raytrace | 204.15 | 200.15 | 0.981x | 25.6 |
| navier_stokes | 261.76 | 247.02 | 0.954x | 24.5 |
| splay | 469.12 | 462.61 | 0.999x | 18.9 |

The swapped run confirmed a **0.9760x** candidate/main geometric mean; its
inverted ratios were **0.984x, 0.946x, 0.961x, 0.992x, 0.970x, and 1.004x**.
Thus Splay is order-sensitive but statistically flat, while the five resolved
signals all improve.

Validation covered the complete ReleaseSafe unit suite (**3,350 pass / 261
expected skip**), the focused TypedArray Integer-Indexed `[[Set]]` test262
bucket (**53 / 53**), and the hardened-JavaScript suite (**36 / 36**).
Regression tests pin canonical sentinels (`-0`, `NaN`, and both infinities),
same- versus different-receiver coercion, valid and noncanonical inherited
writes, plus ordinary data and fused-method prototype loads in a realm with no
synthetic cells.

### 2026-07-30 — direct-threaded `this` property loads, host `Linux 6.8.0-117-generic x86_64` (remote bench box)

Interleaved A/B on one pinned CPU: runtime head `7e93321a` against exact
merged main `808ff428`, 30 pairs in Lantern-only (`--no-jit`). Instrumented
traces identified `LdaThis -> LdaProperty8` as the largest remaining adjacent
opcode opportunity: **18,364,389** transitions across the six macros, or
**5.058%** of 363,054,517 logical instructions. The pair covers **71.214%**
of all `LdaThis` executions. All 502 static sites use the compact property
encoding, and their matching source spans identify direct
`this.IdentifierName` expressions.

Head leaves the bytecode and both JIT tiers unchanged. After the existing
§9.1.1.3.4 GetThisBinding / derived-constructor TDZ gate succeeds,
`LdaThis` recognizes a following compact property load, advances past that
opcode byte, records it as a logical instruction, and directly continues into
the existing property handler. This removes one indirect dispatch while
retaining the single OrdinaryGet implementation for own/prototype ICs,
getters, Proxy traps, primitives, and module namespaces. Opt-in telemetry now
reports the bypass separately as `direct-transfers`; all opcode, pair, and
trigram counts remain logical and therefore compare exactly with the
pre-change traces.

The forward-order interpreter geometric mean improved to **0.981x**:

| bench | base_ms | head_ms | ratio | spread% |
|---|---:|---:|---:|---:|
| richards | 590.51 | 578.88 | 0.979x | 16.5 |
| deltablue | 468.26 | 449.37 | 0.968x | 23.5 |
| crypto | 385.64 | 379.05 | 0.979x | 19.5 |
| raytrace | 198.29 | 195.71 | 0.993x | 15.8 |
| navier_stokes | 267.30 | 258.13 | 0.967x | 21.0 |
| splay | 447.29 | 455.15 | 1.002x | 28.2 |

Because the runner always launches runtime head before baseline within a pair,
the binaries were then swapped while retaining the same harness and pinned
CPU. Inverting those median ratios produced a **0.979x** candidate/main
geometric mean; the per-fixture candidate ratios were **0.998x, 0.967x,
0.958x, 0.989x, 0.968x, and 0.997x**, respectively. Thus the x86 signal
survives launch order despite the shared host's 15–30% process-level spread.

A quieter `Darwin 25.6.0 arm64` confirmation measured **0.9952x** forward
and **0.9957x** with the binaries swapped, also over 30 pairs. The matching
production-tier macro control was **0.9937x**. Targeted 50-pair controls
priced the new branch directly: `method_call`, whose `LdaThis` sites match
about half the time, improved to **0.982x**; zero-match
`class_instantiate` moved to **1.021x**, below the 5% stable-regression gate.
`prop_access` (no `LdaThis`) stayed at **1.000x**.

Validation covered the full ReleaseSafe unit suite; focused test262 buckets
held their exact pass sets (`property-accessors` 21/0,
`statements/class` 4347/6, `expressions/class` 4043/6, and optional chaining
40/0). The property-accessor bucket also remained 21/0 under forced
Bistromath and forced Ohaimark. Inline tests pin IC fill/hit, a prototype
getter re-entering through forced GC, Proxy receiver identity, the direct
derived-constructor TDZ, and a lexical arrow's shared `super_called_cell`.

### 2026-07-30 — packed branch-metadata lookup, host `Linux 6.8.0-117-generic x86_64` (remote bench box)

Interleaved A/B on one pinned CPU: runtime head `83f2ac76` against exact
merged main `92ed61ef`, 20 pairs in Lantern-only (`--no-jit`) and 12 pairs
in the default production-tier posture. Merged width-family handlers
previously called the out-of-line `Op.branchInfo()` classifier for every
relative branch (twice in the fused equality and relational handlers), then
loaded `operand_size_by_opcode` separately to advance `ip`.

Head generates a 512-byte packed `u16` table from the authoritative
branch-family definition at comptime. Large handler tails cross a scalar
call barrier that returns the packed bits in a register; the compact
`jmp_if_false` and `loop_inc_lt` tails probe it directly. Every handler
decodes the metadata once and advances through
`operand_offset + width.byteSize()`. An exhaustive opcode test pins the
packed round trip, control-flow classification, signed operand kind and
offset, canonical width variants, and the invariant that a relative
displacement is the final operand.

ReleaseFast profiles at `0d4da627` (with the same branch classifier)
attributed `Op.branchInfo` self time to 2.72% of Richards samples, 1.86% of
DeltaBlue, and 4.57% of Navier-Stokes. The `ratio` column is the median of
the 20 per-pair `head / base` ratios, so it can differ from the quotient of
the two aggregate p50 columns. The interpreter-only geometric mean improved
to **0.979x**:

| bench | base_ms | head_ms | ratio | spread% |
|---|---:|---:|---:|---:|
| richards | 599.20 | 578.22 | 0.966x | 10.9 |
| deltablue | 471.13 | 464.31 | 0.977x | 19.7 |
| crypto | 397.10 | 389.56 | 0.978x | 10.7 |
| raytrace | 202.73 | 204.56 | 1.013x | 19.4 |
| navier_stokes | 275.65 | 267.61 | 0.965x | 22.1 |
| splay | 467.97 | 459.72 | 0.975x | 10.4 |

RayTrace's +0.9% aggregate result sits inside 19.4% run spread; the paired
median was +1.3%, so the remote box cannot resolve that workload's small
effect. The noisier 12-pair default-tier confirmation improved to a
**0.972x** geometric mean:

| bench | base_ms | head_ms | ratio | spread% |
|---|---:|---:|---:|---:|
| richards | 607.84 | 561.91 | 0.928x | 12.6 |
| deltablue | 485.76 | 470.32 | 0.959x | 16.5 |
| crypto | 398.79 | 395.71 | 1.005x | 14.2 |
| raytrace | 209.59 | 202.45 | 0.978x | 20.2 |
| navier_stokes | 280.67 | 273.45 | 0.986x | 16.5 |
| splay | 471.39 | 450.83 | 0.976x | 12.0 |

A quieter `Darwin 25.6.0 arm64` cross-check measured a **0.981x**
interpreter geometric mean over 60 pairs and **0.984x** with production
tiers over 40 pairs; `arith_loop` improved to **0.894x** over 60 pairs.
The selected inline/call-barrier frontier adds 2,956 bytes to total arm64
text (0.071%) and 352 bytes to constants. Full ReleaseSafe units pass, and
the non-`--only-failing` test262 sweep retains the exact merged-main pass
set: **48,653 pass / 1,324 fail (97.35%)**.

### 2026-07-29 — disabled-tier probe gate, host `Darwin 25.6.0 arm64`

Interleaved A/B: runtime head `85616796` against exact merged main
`0d4da627`, 60 pairs in both Lantern-only (`--no-jit`) and the default
production-tier posture. A disabled-JIT realm previously entered the
Ohaimark and Bistromath policy paths after every fresh frame and loop
backedge merely to rediscover the shared master switch. Head checks that
switch once, after preserving the existing `+16` entry and `+1` backedge
warmth updates, and skips both tier-specific probes.

Merged-main ReleaseFast profiles attributed the fresh-entry probes to 7.36%
of Richards samples and 7.50% of DeltaBlue; Navier-Stokes attributed another
1.49% to the backedge Ohaimark policy probe. The interpreter-only geometric
mean improved to **0.969x**:

| bench | base_ms | head_ms | ratio | spread% |
|---|---:|---:|---:|---:|
| richards | 258.12 | 244.84 | 0.949x | 16.6 |
| deltablue | 199.67 | 188.04 | 0.942x | 6.4 |
| crypto | 136.45 | 132.88 | 0.974x | 19.2 |
| raytrace | 79.94 | 77.53 | 0.972x | 4.7 |
| navier_stokes | 102.99 | 102.38 | 0.994x | 5.1 |
| splay | 164.27 | 161.15 | 0.982x | 18.1 |

The loop-only `arith_loop` control improved to **0.911x** over 50 pairs.
The matching 60-pair default-tier control stayed flat at a **1.003x**
geometric mean:

| bench | base_ms | head_ms | ratio | spread% |
|---|---:|---:|---:|---:|
| richards | 234.44 | 237.46 | 1.013x | 5.9 |
| deltablue | 178.58 | 177.58 | 0.996x | 10.3 |
| crypto | 137.00 | 137.48 | 1.004x | 6.3 |
| raytrace | 80.45 | 80.47 | 1.000x | 5.5 |
| navier_stokes | 103.04 | 103.45 | 1.002x | 7.9 |
| splay | 168.90 | 169.23 | 1.002x | 14.5 |

The shared remote box's 20-pair cross-check had 15–29% ratio spread, too
noisy to resolve this small change; it reported no regression past the
harness threshold. ReleaseFast disassembly confirms every disabled path
branches before the Ohaimark/Bistromath calls. Full ReleaseSafe units pass,
and the non-`--only-failing` test262 sweep retains the exact merged-main pass
set: **48,653 pass / 1,324 fail (97.35%)**.

### 2026-07-29 — schema-derived operand-size lookup, host `Linux 6.8.0-117-generic x86_64` (remote bench box)

Interleaved A/B: runtime head `0760c74a` against exact pre-change
`5023ad4a`, 12 pairs in both Lantern-only (`--no-jit`) and the default
production-tier posture. Merged opcode-family handlers previously resolved
each runtime opcode's width through `Op.spec()` and
`OperandLayout.operandSize()`. Head instead indexes a 256-byte table generated
from `Op.spec()` at comptime. The schema remains authoritative; bytecode
encoding and dynamic dispatch counts are unchanged.

Exact-main ReleaseFast profiles attributed the metadata path to 30.7% of
Richards samples, 19.3% of DeltaBlue, and 21.9% of RayTrace. Removing it
improved every macro. The interpreter-only geometric mean was **0.720x**:

| bench | base_ms | head_ms | ratio | spread% |
|---|---:|---:|---:|---:|
| richards | 1031.86 | 598.67 | 0.582x | 12 |
| deltablue | 640.75 | 469.46 | 0.725x | 11 |
| crypto | 618.37 | 414.89 | 0.681x | 17 |
| raytrace | 290.82 | 217.14 | 0.748x | 21 |
| navier_stokes | 396.61 | 291.48 | 0.765x | 17 |
| splay | 566.50 | 480.54 | 0.849x | 20 |

The default-tier confirmation likewise improved all six macros, for a
**0.706x** geometric mean:

| bench | base_ms | head_ms | ratio | spread% |
|---|---:|---:|---:|---:|
| richards | 1020.94 | 599.34 | 0.587x | 16 |
| deltablue | 638.60 | 462.47 | 0.725x | 19 |
| crypto | 636.59 | 416.02 | 0.656x | 18 |
| raytrace | 296.55 | 216.51 | 0.734x | 25 |
| navier_stokes | 389.86 | 284.10 | 0.733x | 12 |
| splay | 573.65 | 476.07 | 0.827x | 15 |

The full micro suite reported no regression past the paired-run threshold.
Interpreter highlights were `arith_loop` **0.648x**, `prop_access` **0.576x**,
`prop_write` **0.426x**, and `method_call` **0.634x**; the low-dispatch
`promise_chain` control stayed flat at **0.999x**.

### 2026-07-29 — bounded shallow-ConsString memo, host `Linux 6.8.0-117-generic x86_64` (remote bench box)

Lantern-only (`--no-jit`) interleaved A/B: runtime head `654fc093` against
exact pre-change `2710e8ea`, 20 pairs for the six-macro sweep and wider
confirmation on Splay (30 pairs) and Crypto (60 pairs). The heap retains two
exact `(left, right, result)` entries only for ropes at most two deep and 64
bytes. A third consecutive eligible miss clears both entries and bypasses the
next 64 eligible candidates. This is bounded structural memoization, not
content interning.

Splay's depth-5 payload has 32 leaves that repeat the same two concatenations.
After two cold misses, 62 of 64 concatenations hit; across the canonical
8,000-node retained tree that avoids 496,000 redundant rope headers. The
30-pair confirmation moved **678.86 → 581.12 ms (`0.859x`, 19.7% spread)**.
In standalone 20-run samples, p50 moved **700.32 → 576.00 ms** and peak RSS
fell **171,616 → 144,000 KiB** (**−27,616 KiB / −26.97 MiB / −16.09%**).

No non-target macro crossed the 5% regression ceiling in the 20-pair sweep:

| bench | base_ms | head_ms | ratio | spread% |
|---|---:|---:|---:|---:|
| richards | 1047.06 | 1041.50 | 0.997x | 18.8 |
| deltablue | 664.24 | 670.66 | 1.024x | 23.1 |
| crypto | 635.09 | 664.73 | 1.045x | 18.0 |
| raytrace | 294.84 | 302.73 | 1.015x | 24.3 |
| navier_stokes | 401.05 | 411.34 | 1.032x | 16.6 |
| splay | 684.61 | 589.07 | 0.850x | 23.1 |

Crypto's wider 60-pair confirmation was `1.035x` (637.93 → 659.24 ms,
16.0% spread). Targeted controls were likewise below the ceiling:

| bench | pairs | base_ms | head_ms | ratio | spread% |
|---|---:|---:|---:|---:|---:|
| shallow_cons_hit | 40 | 93.87 | 92.28 | 0.995x | 68.6 |
| shallow_cons_miss | 100 | 172.70 | 178.81 | 1.026x | 46.8 |
| string_concat | 40 | 81.75 | 82.26 | 1.008x | 57.2 |
| json_stringify | 40 | 44.93 | 43.27 | 0.998x | 69.3 |

The miss control's wide process-level spread makes it a regression guard, not
a precision claim. Validation covered the full ReleaseSafe unit suite,
non-`--only-failing` test262 addition/String buckets, and those buckets again
under ReleaseSafe `--gc-threshold=1`; the historical JSON/RegExp rope-stress
buckets also passed at that GC pressure, and the final full sweep held the
exact 48,653-pass / 1,324-fail score.

### 2026-07-29 — compact/fused dense-element pools, host `Linux 6.8.0-117-generic x86_64` (remote bench box)

Interpreter-only interleaved A/B against `fe0cf39d` (the compact-storage
baseline), five pairs per fixture. Runtime head `c8aadcd5` splits fused
array-literal buffers into capacity-10 and capacity-16 slab classes instead of
giving every 1–16 element literal a 16-slot buffer.

The headline is Splay's retained-memory result. Its 256,000 live ten-element
leaf arrays predict a `256000 × (16 − 10) × 8 = 12,000 KiB` payload reduction;
observed peak RSS fell **183,540 → 171,616 KiB** (**−11,924 KiB / −11.64 MiB /
−6.50%**), within 76 KiB of that exact prediction. Standalone timing stayed
flat inside run spread:

| revision | p50_ms | min_ms | max_ms | spread% | rss_kb |
|---|---:|---:|---:|---:|---:|
| base `fe0cf39d` | 676.54 | 659.15 | 710.94 | 7.7 | 183540 |
| head `c8aadcd5` | 679.69 | 643.53 | 713.01 | 10.2 | 171616 |

The back-to-back ratios are the timing signal. No macro crossed the runner's
regression gate (a move must exceed both 5% and one-third of ratio spread):

| bench | base_ms | head_ms | ratio | spread% |
|---|---:|---:|---:|---:|
| richards | 1040.81 | 1066.90 | 1.024x | 6.6 |
| deltablue | 660.17 | 663.45 | 1.018x | 16.1 |
| crypto | 638.01 | 643.69 | 1.009x | 6.1 |
| raytrace | 295.36 | 291.59 | 0.997x | 17.9 |
| navier_stokes | 412.20 | 404.01 | 0.958x | 7.4 |
| splay | 688.29 | 691.64 | 1.011x | 3.7 |

The allocation-only `array_literal_loop` micro initially read 1.063x at five
pairs, then **1.042x with 9.9% spread at 12 confirmation pairs**, below the
gate. Its pool helpers are already inlined in the ReleaseFast binary, leaving
only the required capacity-class branch. Controls were also unflagged:
`ctor_array_build` 1.012x (5.5% spread) and `array_iter` 1.092x (38.5% spread).
This run also registers the already-present `array_literal_loop.js` fixture in
the standard benchmark table so the allocation path remains directly
measurable.

### 2026-07-17 — multiplication operand profile + tagged Number T2 path, host `Darwin 25.6.0 arm64`

Focused interleaved A/B against `0ca910a9` (pre-profile), Lantern-only
(`--no-jit`), 200 pairs. `mul` now carries a one-byte raw-operand profile;
Lantern records it in the fused Number multiplication path, and Ohaimark can
consume the trained site through its new tagged-Number `fmul` lowering.

| bench | base_ms | head_ms | ratio | spread% |
|---|---:|---:|---:|---:|
| mul_loop | 44.38 | 44.92 | 1.012x | 81.8 |

The median moved about 1.2%, but the max/min ratio spread is too noisy for a
precise regression claim. It rules out a large Lantern tax; the semantic and
T2 payoff is established separately by native execution, natural-threshold,
GC-pressure, and exact full-corpus differential gates. The bench runner also
gained `--filter=<name>` so future targeted A/B runs do not pay for the whole
suite.

### 2026-07-17 — division operand profile + fused Number path, host `Darwin 25.6.0 arm64`

Interleaved A/B against `bb7aa7dd` (pre-profile), Lantern-only (`--no-jit`),
40 pairs per fixture. `div` now carries a one-byte raw-operand profile, but the
interpreter records it inside a fused Number path that also removes the old
Int32/Int32 fallthrough through generic `numericBinary`.

| bench | base_ms | head_ms | ratio | spread% |
|---|---:|---:|---:|---:|
| arith_loop | 54.96 | 55.57 | 1.003x | 23.1 |
| div_loop | 63.09 | 46.13 | 0.727x | 12.3 |
| prop_access | 25.06 | 22.71 | 0.914x | 38.7 |
| prop_write | 33.92 | 34.58 | 1.014x | 32.0 |
| array_iter | 29.18 | 29.12 | 1.003x | 27.3 |
| string_concat | 30.10 | 30.00 | 1.001x | 20.3 |
| promise_chain | 10.42 | 10.56 | 1.006x | 41.0 |
| object_alloc | 14.78 | 14.58 | 0.997x | 19.3 |
| method_call | 29.50 | 30.38 | 1.028x | 26.2 |
| class_instantiate | 32.38 | 32.63 | 1.001x | 22.4 |
| ctor_array_build | 245.23 | 248.18 | 1.009x | 11.2 |
| json_stringify | 25.10 | 25.14 | 0.997x | 32.0 |
| tail_recursion | 37.59 | 37.50 | 1.008x | 16.8 |

The targeted result is `div_loop`: **0.727x, about 27% faster despite profile
recording**. The primary untouched control, `arith_loop`, is flat (`1.003x`),
as are almost all other controls within their noisy local spreads. The
faster-looking `prop_access` row has 38.7% ratio spread and no related code
change, so it is noise rather than a claimed gain.

### 2026-07-13 — cynic `6bd673c4` (JSObject header shrink — cold clusters behind `extension`), host `Linux 6.8.0-117-generic x86_64` (remote bench box)

Results-refresh snapshot at `origin/main` (no code change this session) — the
companion to the `bench-cross-results.md` regen. Default tier (Bistromath),
median of 12 on the shared-vCPU box, so absolute ms run several× slower and
noisier than the Darwin rows below: the micros carry the usual 25–80 % shared-
vCPU spread (informational — defer to the core-pinned cross-engine table),
while the macros are the cleaner read (6–13 % spread; splay's 28 % is GC-pause
variance).

The headline is the memory axis. **splay peak RSS 371,918 → 281,088 KiB
(≈ 363 → 274 MiB, −24 %, ~−89 MiB)** — the Stage A header shrink
(`@sizeOf(JSObject)` 408 → 296 B; four cold per-kind clusters relocated behind
the `JSObjectExtension` pointer, `6bd673c4`), where the drop is the per-object
saving times splay's ~768 k live nodes. See `docs/gc-immix-rearchitecture.md`
§"Stage A landed". The minimal-object micros corroborate — `arith_loop` /
`prop_access` / `prop_write` / `tail_recursion` RSS 6912 → 5888 KiB (−15 %).
Cross-engine (`bench-cross-results.md`): cynic splay 274 MiB vs jsc 54 /
hermes 67 / v8 70 — still the field's heaviest by count of live headers, now
much closer. Stage A is test262-byte-identical: a footprint change, not a
throughput one.

Timing deltas vs the last absolutes row (2026-06-21 `bf5951e1`, same host) are
**cumulative over the three-week window** — GC-latency (incremental marking,
lazy sweep), interpreter, and shape-index work, not this one commit: splay
4569 → 783 ms (−83 %), raytrace 662 → 195 (−71 %), navier_stokes 831 → 573
(−31 %), richards 660 → 521 (−21 %), crypto 684 → 561 (−18 %); deltablue flat
(595 → 578).

#### Macros (default tier)

| bench | median_ms | min_ms | max_ms | rss_kb |
|---|---:|---:|---:|---:|
| richards | 521.19 | 509.49 | 576.66 | 7552 |
| deltablue | 577.55 | 549.12 | 626.41 | 15360 |
| crypto | 560.97 | 553.01 | 590.17 | 10752 |
| raytrace | 195.13 | 182.52 | 207.55 | 9600 |
| navier_stokes | 573.24 | 532.97 | 591.47 | 9088 |
| splay | 782.71 | 737.30 | 958.44 | 281088 |

#### Micros (default tier)

| bench | median_ms | min_ms | max_ms | rss_kb |
|---|---:|---:|---:|---:|
| arith_loop | 78.23 | 71.34 | 92.90 | 5888 |
| prop_access | 32.39 | 27.20 | 47.24 | 5888 |
| prop_write | 30.91 | 23.43 | 37.56 | 5888 |
| array_iter | 50.59 | 47.74 | 75.28 | 6912 |
| string_concat | 64.73 | 60.88 | 92.94 | 27392 |
| promise_chain | 25.97 | 21.25 | 41.91 | 22656 |
| object_alloc | 27.50 | 24.28 | 33.37 | 8192 |
| method_call | 40.59 | 38.95 | 44.48 | 6016 |
| class_instantiate | 53.57 | 50.90 | 59.83 | 8320 |
| ctor_array_build | 363.13 | 352.16 | 391.79 | 8832 |
| json_stringify | 42.50 | 37.84 | 61.79 | 7936 |
| tail_recursion | 44.83 | 42.83 | 50.33 | 5888 |

### 2026-06-28 — cynic `8563423b` (interpreter arithmetic + comparison fast paths), host `Linux 6.8.0-117-generic x86_64` (remote bench box)

Same-runner A/B vs `290bc75f` (the commit just before the first fast path),
suite=both, 12 runs back-to-back per iteration. Three interpreter changes add
common-type fast paths in the dispatch loop ahead of the general slow path:
inline `==` / `!=` and conditional fast paths (`eb220910`), double / mixed-numeric
fast paths for `+ − * / %` (`37726a10`), and an integer fast path in
`formatDoubleSafe` for double-index keys (`8563423b`). The A/B range also carries
~7 interleaved Intl commits, throughput-neutral here — the bench fixtures never
exercise Intl, so their only effect is a small code-layout shift. The macro wins
are large and consistent across both tiers:

- **Octane macros — big, clean wins** (spread 9–30%): **navier_stokes 0.720× /
  0.737×** (JIT / no-jit — the arithmetic-heavy fixture, the biggest mover),
  **richards 0.812× / 0.819×**, **crypto 0.831× / 0.857×**. deltablue
  (1.00× / 0.96×), raytrace (1.00× / 0.99×) and splay (0.96× / 0.97×) sit within
  noise. The `+ − * / %` and `==` / `!=` paths land squarely where the
  double-heavy macros spend their time.
- **Micros mostly flat** on the shared vCPU (high per-iteration spread):
  `arith_loop` is flat (1.01× / 1.03×) — it was already on the int32 path; these
  commits add the *double / mixed-numeric* paths the macros lean on. One flagged
  regression — **`tail_recursion` 1.116× / 1.274×** (🔴) — but at 32% / 57%
  spread it is the noisiest fixture in the run; worth a watch, not a block.

The headline is the macro win: a double-digit interpreter speedup on three of six
Octane macros that the prior bench rows (GC-latency work) never captured — which
is why the file looked "current" while sitting a major interpreter win behind.

### 2026-06-24 — cynic `05e99538` (lazy sweep), host `Linux 6.8.0-117-generic x86_64` (remote bench box)

Same-runner A/B vs `897d66ad` (incremental major marking), suite=both, 12 runs
back-to-back per iteration. Lazy sweep slices the major's termination sweep —
the residual ~9.6 ms STW after the mark went incremental — across safe-points:
`collectFullTail` defers the `objects_mature` sweep, `runSafePoint` drains it
in ~8192-object slices, dropping the max GC pause **~9.6 ms → ~1 ms** (the
~1 ms mark slice is now the ceiling — both halves of the major cycle sliced).
It adds only a phase-check branch per safe-point (no new write barrier), so
throughput is unchanged — the renderer flagged no regressions past the
threshold:

- **Realistic Octane macros flat** (spread 12–19%) — crypto 0.99×, deltablue
  0.97×, raytrace 1.01×, richards 1.01×, splay 0.98×; navier_stokes 0.94× the
  lone flagged mover (faster, both tiers — incidental code-layout, not a
  GC-logic change).
- **Micros within noise** on the shared vCPU (20–96% per-iteration spread) —
  no fixture cleared the ±5% + spread/3 flag; the slower-looking `prop_access`
  / `method_call` / `object_alloc` interp ratios all sit under spread/3.

Unlike incremental marking (which added the Dijkstra barrier across the whole
marking window), lazy sweep only defers + slices existing sweep work, so the
latency win is throughput-neutral. See `docs/handbook/gc.md` §Lazy sweep.

### 2026-06-23 — cynic `897d66ad` (incremental major marking), host `Linux 6.8.0-117-generic x86_64` (remote bench box)

Same-runner A/B vs `5b92a346` (the rebase base — the Intl substrate,
pre-incremental), suite=both, 12 runs back-to-back per iteration. The major
mark now slices across safe-points (Dijkstra incremental-update barrier,
~8192-item budget); the max GC pause on a 2M-object heap dropped
**~800 ms → ~9.6 ms (~83×)** (`slice_max` ~1 ms per slice; `term` ~9.6 ms is
the residual STW sweep). The latency-for-throughput cost lands where expected:

- **Realistic Octane macros unchanged within noise** — crypto 0.98×,
  deltablue 1.00×, raytrace 1.00×, richards 1.00×, navier_stokes 1.03×.
- Non-allocation micros flat — arith ~1.0×, prop_write 0.93–0.99×,
  string_concat 0.98×.
- Allocation-heavy micros lean ~3–5% slower — `class_instantiate` the ~13%
  outlier (1.13–1.16×, flagged), promise_chain 1.06–1.17×, object_alloc /
  ctor_array_build / method_call / array_iter ~1.03–1.05×. The write barrier
  is active across the (now long) marking window where the STW major never
  barriered; `class_instantiate`'s class-setup typed-slot writes trip the
  `rememberTypedSlotWrite` re-grey. Accepted as the latency-for-throughput
  trade — see `docs/handbook/gc.md` §Incremental major marking (the outlier's
  known fix: defer the re-grey to the termination).

### 2026-06-22 — cynic `ec12132d` (card marking + adaptive major trigger), host `Linux 6.8.0-117-generic x86_64` (remote bench box)

Same-runner A/B vs `61cc6fbd` (the pre-card-marking baseline — sticky
bits + scan-skip), suite=both, 12 runs. Two GC changes landed since: card
marking drops the minor cycle's O(mature) typed-slot scan (every
typed-slot write now barriers onto the dirty list, so the ~250k plain
Splay nodes never get scanned), and the adaptive major trigger defers the
forced major on a stable retained set (backstop 8→32 + a 2×-growth
trigger that bounds churning RSS):

- **splay 0.329× (default tier) / 0.322× (`--no-jit`) — ~3.0× faster**
  (3505→1135 / 3540→1136 ms), the two changes together.
- Cumulative with sticky bits + scan-skip: interpreter-tier Splay
  ~16,000 → ~1,109 ms; the gap to QuickJS-NG (~833 ms on this box)
  collapsed to **~1.3×** (was 17.8× before any GC work, ~4.0× after
  scan-skip), and to JSC (~162 ms) ~6.8× (was ~22×).
- Conformance byte-identical (45335); small-live churn peak RSS bounded by
  the adaptive growth trigger (115→32 MB on a churn microbench). Other
  macros flat — the changes are GC scan/frequency, not arith/alloc.

### 2026-06-21 — cynic `d7dae9ca` (slot-bearing-only typed-slot scan), host `Linux 6.8.0-117-generic x86_64` (remote bench box)

Same-runner A/B vs `origin/main` (the post-sticky-bits baseline
`292ce88c`), suite=both, 12 runs. The minor cycle's typed-slot scan now
skips objects with no internal slots (`needs_internal_scan` +
`objectScanSkippable`), so Splay's ~250k plain nodes drop out of the
per-minor scan:

- **splay 0.695× (default tier) / 0.700× (`--no-jit`) — ~1.44× faster**
  (4688→3258 / 4636→3244 ms). Recovers the `markSymbolKeys` per-object
  shape-chain walk (the scan's ~23.5% slice).
- prop_access 0.89× and prop_write 0.87× (default tier) also faster —
  their plain objects skip the scan too. Other macros flat (±5 %).
- tail_recursion flags 1.108× on the default tier, but its `--no-jit` is
  flat (0.994×) and it's function-heavy (untouched by an *object*-scan
  skip) — jitter, not the change.

Cumulative with the sticky bits: Splay ~16,000 → ~3,244 ms (~4.9×);
interpreter-tier gap to QuickJS-NG (~810 ms on this box) now ~4.0× (was
17.8× before the GC work). Conformance byte-identical (ReleaseFast counts
match ReleaseSafe). Residual = the scan's 250k-object iteration + the
dirty-list walk + periodic majors; a remembered typed-slot set (iterate
only slot-bearing objects) would take the iteration next.

### 2026-06-21 — cynic `bf5951e1` (sticky mark bits), host `Linux 6.8.0-117-generic x86_64` (remote bench box)

First row from the remote bench box — the canonical bench host now that
local full-suite runs are off. It's a **shared-vCPU** machine, so
absolute ms run several× slower and noisier than the Darwin arm64 laptop
rows below (micro spreads 25–82 %); the two hosts are **not comparable**.
The trustworthy signal is the same-runner A/B vs `db87dedd` (the
pre-sticky-bits commit), which cancels host variance:

- **splay 0.283× (default tier) / 0.289× (`--no-jit`) — a ~3.5× GC win**:
  the sticky-mark-bit minor cycle no longer re-traces the mature set.
  splay's own macro spread is a clean ~5–8 %.
- All other movers faster: promise_chain 0.72× / 0.67×; object_alloc
  0.88× and string_concat 0.88× on `--no-jit`. The other four macros are
  flat (±6 %).
- prop_write (+15–29 %) and prop_access reproduce across a confirm 30-run
  A/B — real and deterministic, but **not** a sticky-bit logic cost: both
  are zero-allocation loops (one object, immediate NaN-boxed int32 ops),
  so no minor cycle fires and the new GC code never runs in them. It's a
  code-layout / I-cache artifact of the heap.zig binary change (only the
  property-bag micros moved; arith/method/tail flat) — incidental, liable
  to drift on the next heap edit. Dwarfed by the splay win.

Default tier (Bistromath). Macros are the cleaner absolute read on the
shared box; the noisy micros follow for completeness — defer to the A/B
ratio over their absolute ms.

#### Macros (default tier)

| bench | median_ms | min_ms | max_ms | rss_kb |
|---|---:|---:|---:|---:|
| richards | 660.16 | 628.03 | 721.54 | 7296 |
| deltablue | 595.31 | 562.37 | 677.71 | 12032 |
| crypto | 683.70 | 669.56 | 718.40 | 10496 |
| raytrace | 662.09 | 616.87 | 721.12 | 11520 |
| navier_stokes | 831.22 | 803.66 | 860.15 | 8704 |
| splay | 4569.18 | 4446.68 | 4806.51 | 371918 |

#### Micros (default tier)

| bench | median_ms | min_ms | max_ms | rss_kb |
|---|---:|---:|---:|---:|
| arith_loop | 72.38 | 67.94 | 98.69 | 6912 |
| prop_access | 30.74 | 27.32 | 43.40 | 6912 |
| prop_write | 32.35 | 31.08 | 41.63 | 6912 |
| array_iter | 48.63 | 46.12 | 58.73 | 7936 |
| string_concat | 74.63 | 66.86 | 128.20 | 14946 |
| promise_chain | 27.32 | 24.83 | 39.07 | 24576 |
| object_alloc | 34.15 | 31.31 | 55.60 | 10112 |
| method_call | 40.64 | 38.43 | 46.49 | 7040 |
| class_instantiate | 55.30 | 52.51 | 68.29 | 10240 |
| ctor_array_build | 374.10 | 356.46 | 422.20 | 10816 |
| json_stringify | 41.52 | 39.42 | 50.80 | 9472 |
| tail_recursion | 44.30 | 42.05 | 46.69 | 6912 |

### 2026-06-19 — cynic `8642fb21`, host `Darwin 25.6.0 arm64`

Eight fixtures faster ≥5 % vs `cd2dd5c`: object_alloc −39 %, prop_access
−13 %, prop_write −12 %, arith_loop −9 %, class_instantiate −9 %,
ctor_array_build −8 %, json_stringify −7 %, array_iter −6 % — from the
spasm / JIT / bytecode work landed since. Default tier (Bistromath).
Idle machine (load ~2.7); `arith_loop` spread 17.4 % (desktop-UI jitter),
so its median is approximate.

| bench | median_ms | min_ms | max_ms | rss_kb |
|---|---:|---:|---:|---:|
| arith_loop | 13.82 | 13.17 | 15.57 | 5696 |
| prop_access | 11.81 | 11.49 | 12.07 | 5632 |
| prop_write | 11.20 | 10.98 | 11.48 | 5664 |
| array_iter | 19.09 | 18.61 | 19.47 | 6768 |
| string_concat | 24.82 | 24.70 | 25.32 | 15720 |
| promise_chain | 10.57 | 10.38 | 11.07 | 24024 |
| object_alloc | 14.90 | 14.69 | 15.07 | 9152 |
| method_call | 13.74 | 13.47 | 14.31 | 5928 |
| class_instantiate | 24.74 | 24.09 | 25.87 | 9328 |
| ctor_array_build | 162.74 | 159.48 | 164.61 | 9944 |
| json_stringify | 21.98 | 21.22 | 23.75 | 8528 |
| tail_recursion | 5.39 | 5.33 | 5.45 | 5696 |

### 2026-06-12 — cynic `cd2dd5c` (L4 register promotion complete + neg-fold), host `Darwin 25.6.0 arm64`

Closes the ctor_array_build campaign: **176.60 median — from 497.45 at
`4ce56ff` (−64.5 %)**. The full L4 line (block-lexical register promotion
across functions / arrows / methods / constructors + the per-binding
Stage 2 capture analysis + script-top-level wiring) now fires on the
fixture itself; plus virtual array length, the GC traffic cut, L1/L2/L3a,
the update-expr / compound-assign peepholes, and the unary-minus fold.
Quiet machine (load ~2.6). Default tier (Bistromath on).

| bench | median_ms | min_ms | max_ms | rss_kb |
|---|---:|---:|---:|---:|
| arith_loop | 15.24 | 14.30 | 18.77 | 5624 |
| prop_access | 13.55 | 12.61 | 20.03 | 5608 |
| prop_write | 12.66 | 12.30 | 13.00 | 5672 |
| array_iter | 20.29 | 20.03 | 20.82 | 6744 |
| string_concat | 25.45 | 24.91 | 25.71 | 15744 |
| promise_chain | 10.73 | 10.49 | 11.21 | 23856 |
| object_alloc | 24.60 | 23.75 | 25.22 | 9448 |
| method_call | 13.90 | 13.61 | 14.25 | 5912 |
| class_instantiate | 27.14 | 26.54 | 28.28 | 9344 |
| ctor_array_build | 176.60 | 173.57 | 180.38 | 9928 |
| json_stringify | 23.72 | 23.40 | 24.84 | 9136 |
| tail_recursion | 5.37 | 5.28 | 5.60 | 5680 |

### 2026-06-12 — cynic `dd4a0ce`, host `Darwin 25.6.0 arm64`

`tail_recursion` 33.48 → 6.13 (−82 %) — frame-rooting / OSR work
on the JIT track has landed since `ea84c54`. 7–13 % drift up on
`prop_access` / `promise_chain` / `string_concat` / `arith_loop` /
`class_instantiate` is within the noise envelope (every fixture
spread ≤ 14.9 % in both postures; load avg 4.1).

Lantern (`--no-jit`) vs Bistromath (the default), one run each:

| bench | Lantern p50 | Bistromath p50 | speedup | min (L→B) | RSS KiB (L→B) |
|---|---:|---:|---:|---:|---:|
| tail_recursion | 23.55 | **6.13** | **3.84×** | 23.26→5.89 | 5560→5656 |
| arith_loop | 32.34 | **15.62** | **2.07×** | 31.98→15.09 | 5536→5608 |
| method_call | 17.09 | **14.72** | **1.16×** | 16.77→14.15 | 5816→5904 |
| object_alloc | 24.21 | 24.11 | 1.00× | 23.90→23.83 | 9416→9432 |
| array_iter | 20.74 | 20.98 | 0.99× | 20.34→20.72 | 6696→6696 |
| ctor_array_build | 188.99 | 193.27 | 0.98× | 187.63→190.90 | 9976→9984 |
| prop_write | 12.62 | 13.02 | 0.97× | 12.31→12.84 | 5616→5656 |
| json_stringify | 24.29 | 25.19 | 0.96× | 23.65→24.26 | 9096→9160 |
| string_concat | 25.68 | 27.21 | 0.94× | 25.38→26.99 | 15688→15808 |
| class_instantiate | 27.37 | 29.27 | 0.94× | 27.06→28.37 | 9304→9336 |
| promise_chain | 11.82 | 12.73 | 0.93× | 11.47→11.62 | 23864→23912 |
| prop_access | 12.46 | 13.55 | 0.92× | 12.22→13.34 | 5520→5576 |

Speedup = Lantern p50 / Bistromath p50 (>1× = the tier is faster);
**bold** marks movers ≥1.05×. Bistromath dominates the loops
(`tail_recursion` 3.8×, `arith_loop` 2.1×) and edges `method_call`;
the IC-heavy property / call / string fixtures sit slightly below
Lantern this run — within envelope, not a regression.

### 2026-06-12 — cynic `ea84c54` (ctor campaign complete), host `Darwin 25.6.0 arm64`

Quiet-machine row (load ~2.7-3.0, spreads ≤10%) closing the
ctor_array_build effort: **189.38 median — down from 497.45 at the
`4ce56ff` baseline (−62 %)** via virtual length, the GC traffic cut,
the lda_computed dense-read fast path, the fused `make_array_n`
literal, and the pooled element buffers (docs/ctor-array-build-gap.md
has the measured per-lever ledger). Also vs that baseline:
json_stringify 37.17 → 24.61, promise_chain 14.69 → 11.26,
class_instantiate 35.08 → 27.44. Default tier (Bistromath on);
arith_loop/method_call carry the tier's compiled-loop wins.

| bench | median_ms | min_ms | max_ms | rss_kb |
|---|---:|---:|---:|---:|
| arith_loop | 14.34 | 14.04 | 15.20 | 5520 |
| prop_access | 12.48 | 12.21 | 12.70 | 5488 |
| prop_write | 12.73 | 12.62 | 12.83 | 5544 |
| array_iter | 20.14 | 19.73 | 20.51 | 6616 |
| string_concat | 24.92 | 24.74 | 25.51 | 15896 |
| promise_chain | 11.26 | 10.78 | 11.77 | 23920 |
| object_alloc | 23.78 | 23.46 | 24.45 | 9288 |
| method_call | 14.04 | 13.81 | 14.79 | 5752 |
| class_instantiate | 27.44 | 27.04 | 28.67 | 9152 |
| ctor_array_build | 189.38 | 185.79 | 192.58 | 9808 |
| json_stringify | 24.61 | 24.00 | 26.42 | 9000 |
| tail_recursion | 33.48 | 32.88 | 33.92 | 5544 |

### 2026-06-11 — cynic `42ca813` (default-on checkpoint), host `Darwin 25.6.0 arm64`

First post-flip recording: the default column IS Bistromath now;
`--no-jit` is the Lantern baseline. Loaded machine (load avg 4-6;
arith_loop/class_instantiate/ctor_array_build spreads 42-81% —
treat those cells as noisy), but every median corroborates the
quiet-pair history: arith_loop 2.07×, method_call −24%, the rest
flat.

Lantern (`--no-jit`) vs Bistromath (the default), one run each:

| bench | Lantern p50 | Bistromath p50 | speedup | min (L→B) | RSS KiB (L→B) |
|---|---:|---:|---:|---:|---:|
| arith_loop† | 33.42 | **16.14** | **2.07×** | 32.4→14.0 | 5248→5384 |
| method_call | 18.52 | **14.06** | **1.32×** | 17.0→13.7 | 5576→5672 |
| prop_access | 13.16 | **12.01** | **1.10×** | 12.1→11.9 | 5304→5328 |
| tail_recursion† | 39.93 | 36.91 | 1.08× | 35.4→34.5 | 5368→5400 |
| prop_write | 12.39 | **11.61** | **1.07×** | 11.7→11.5 | 5384→5432 |
| json_stringify | 28.68 | **27.17** | **1.06×** | 27.4→26.6 | 8824→8840 |
| array_iter | 20.29 | 20.11 | 1.01× | 20.0→19.5 | 6320→6408 |
| object_alloc | 22.86 | 23.38 | 0.98× | 22.4→22.8 | 9112→9072 |
| string_concat | 23.51 | 24.36 | 0.97× | 23.1→24.1 | 15712→15856 |
| promise_chain | 10.05 | 10.42 | 0.96× | 9.9→10.2 | 23760→23728 |
| ctor_array_build† | 314.18 | 339.84 | 0.92× | 301.4→312.9 | 9768→9768 |
| class_instantiate† | 26.44 | 29.90 | 0.88× | 25.9→27.6 | 9024→9072 |

Speedup = Lantern p50 / Bistromath p50 (>1× = the tier is
faster); **bold** marks movers ≥1.05×. † = loaded-machine
spread >15% in at least one posture — direction matches the quiet-pair history; treat the magnitude as noisy.

### 2026-06-11 — cynic `6dc91a5` (post conformance batch + JIT-era interp), host `Darwin 25.6.0 arm64`

Quiet-machine single-engine row (interp mode, no `--jit`), the first
classic baseline since `bb5703b` — two days of landings between
(warmth counters, register promotion of body locals + fused-call
gating, IC coverage, the conformance batch). Movers vs `bb5703b`:
`ctor_array_build` **−30.5 %**, `class_instantiate` **−18.3 %**,
`promise_chain` **−14.2 %**, `object_alloc` **−11.5 %** (register
promotion + IC work); `tail_recursion` **+10.6 %**, `arith_loop`
**+6.6 %**, `prop_access` **+7.3 %** (the interp-side warmth-counter
tax on back-edges / PTC re-entries — the tier those counters feed is
off in this measurement).

| bench | median_ms | min_ms | max_ms | rss_kb |
|---|---:|---:|---:|---:|
| arith_loop | 31.69 | 31.56 | 32.10 | 5344 |
| prop_access | 13.16 | 12.68 | 13.69 | 5392 |
| prop_write | 12.89 | 12.74 | 13.38 | 5472 |
| array_iter | 21.32 | 20.61 | 21.78 | 6464 |
| string_concat | 25.47 | 24.86 | 25.87 | 15800 |
| promise_chain | 12.43 | 12.26 | 13.27 | 23720 |
| object_alloc | 24.82 | 24.24 | 25.95 | 9160 |
| method_call | 18.76 | 17.87 | 19.19 | 5704 |
| class_instantiate | 28.52 | 27.75 | 31.96 | 9144 |
| ctor_array_build | 308.40 | 302.79 | 314.54 | 9800 |
| json_stringify | 27.82 | 27.37 | 30.12 | 8896 |
| tail_recursion | 36.27 | 35.72 | 38.86 | 5400 |

### 2026-06-11 — cynic (script chunks compile: jit.md delivery step 3g, first slice), host `Darwin 25.6.0 arm64`

Top-level script chunks now compile (`lda/sta_global_slot[_init]`
over the realm's declarative-record slot caches), so the bench
fixtures' own top-level loops finally OSR into the tier. Two
back-to-back pairs this time — single-pair deltas on the GC-heavy
fixtures (string_concat, promise_chain, json_stringify) flipped
sign between pairs and are machine drift, not signal:

| bench | interp (pair 1 / 2) | `--jit` (pair 1 / 2) | verdict |
|---|---:|---:|---|
| arith_loop | 35.53 / 32.52 | 15.65 / 15.06 | **~2.2× — stable in both pairs** |
| method_call | 18.19 / 18.89 | 14.41 / 13.58 | −24%, stable |
| (all others) | — | — | flat within historic spread |

### 2026-06-11 — cynic (calls + OSR: jit.md delivery steps 3e+3f), host `Darwin 25.6.0 arm64`

Same-day follow-up to the entry below — compiled calls (all three
shapes) and OSR landed. Back-to-back quiet-machine pair this time
(the morning baseline was loaded-machine; cross-session deltas
were invalid):

| bench | interp p50 | `--jit` p50 | note |
|---|---:|---:|---|
| arith_loop | 39.73 | 42.52 | top-level loop — can't compile until script chunks do (jit.md delivery step 3g); the ~+7% is the back-edge precheck tax at 5M iterations |
| method_call | 22.19 | 17.90 | −19% — callee compiled + per-iteration entry |
| class_instantiate | 35.59 | 32.74 | −8% |
| tail_recursion | 42.51 | 41.54 | enters per PTC reframe; the tail-call tier-down round-trip eats the win until jump-to-entry |
| (others) | ±3% | ±3% | noise band |

The honest OSR number needs the function-wrapped shape (what the
fixture becomes once script chunks compile): `function big() { 5M
× (s+i)|0 } big();` — single call, compiled mid-run from
back-edge warmth:

- ReleaseFast (`cynic-bench`): 58.9 → 40.6 ms per process,
  ~1.55× on the loop after spawn overhead.
- Debug `cynic`: 1493 → 724 ms — 2.06×.

### 2026-06-11 — cynic `89d80a1` (first `--jit` columns: lda_this + IC coverage), host `Darwin 25.6.0 arm64`

First recorded Bistromath run — `zig build bench -- --jit`, the
tier at its natural tier-up thresholds (the user posture, not
force-compile). From here every bench session records both tables;
the `--jit` column becomes the headline once OSR (jit.md delivery
step 3f) lets the rest of the suite enter the tier. Loaded machine
(spreads 16-35%), so only the mechanism-backed delta counts:

- **`method_call` 32.12 → 23.17 p50 (−28%; mins 25.82 → 20.36,
  −21%)** — the one fixture whose hot path crosses a call boundary
  per iteration into a fully-supported callee: `Counter.inc`'s
  `this.n += 1` compiles (lda_this + the property ICs + add_smi)
  and enters through the call-arm hook. The first measured
  Bistromath win.
- Everything else sits inside the loaded-machine band in both
  directions — expected pre-OSR: those fixtures' hot loops are
  top-level and never enter the tier.
- RSS +~50 KB under `--jit` — the touched pages of the lazily
  reserved code region.

Lantern vs Bistromath (`--jit` — pre-flip, the tier was opt-in then), one run each:

| bench | Lantern p50 | Bistromath p50 | speedup | min (L→B) | RSS KiB (L→B) |
|---|---:|---:|---:|---:|---:|
| method_call | 32.12 | **23.17** | **1.39×** | 25.8→20.4 | 5680→5728 |
| object_alloc | 47.09 | **42.55** | **1.11×** | 34.1→33.5 | 9280→9240 |
| prop_write | 22.86 | **21.72** | **1.05×** | 18.2→17.0 | 5520→5568 |
| ctor_array_build† | 528.82 | 509.02 | 1.04× | 459.2→483.7 | 9880→9880 |
| json_stringify | 42.77 | 41.36 | 1.03× | 39.4→37.3 | 8976→9016 |
| arith_loop† | 53.94 | **52.35** | **1.03×** | 42.9→47.7 | 5456→5440 |
| class_instantiate† | 50.61 | 51.24 | 0.99× | 46.6→42.4 | 9184→9152 |
| array_iter | 36.69 | 39.71 | 0.92× | 31.1→31.2 | 6528→6600 |
| tail_recursion | 53.61 | 58.51 | 0.92× | 47.7→47.1 | 5464→5520 |
| string_concat | 40.88 | 47.96 | 0.85× | 36.3→37.6 | 16000→15856 |
| prop_access | 18.04 | 21.56 | 0.84× | 17.2→19.4 | 5504→5472 |
| promise_chain | 19.82 | 25.63 | 0.77× | 18.7→20.7 | 24024→24096 |

Speedup = Lantern p50 / Bistromath p50 (>1× = the tier is
faster); **bold** marks movers ≥1.05×. † = loaded-machine
spread >15% in at least one posture — that session's machine was loaded throughout; the entry text carries the caveats.

### 2026-06-09 — cynic `bb5703b` (JSON shape-walk + small-int toString cache), host `Darwin 25.6.0 arm64`

Two contained allocation-cut wins, both measured against the `4ce56ff`
baseline below (same host):

- **`string_concat` 40.18 → 24.57 (−39 %)** — the pinned small-integer
  `toString` cache (`bb5703b`). `(i & 0xff).toString()` no longer
  allocates a fresh `JSString` per call; the 0-255 range is served from
  a per-realm pinned, shared cache.
- **`json_stringify` 37.17 → 28.17 (−24 %)** — the shape-walk fast path
  for `SerializeJSONObject` (`2623f8b`): plain shape-mode objects
  serialize straight off their value slots, skipping the key-array
  materialization + the per-property `[[Get]]` + `flagsFor` probes.

Both deltas track their isolated min-of-31 interleaved A/B measurements
(−35 % / −23 %). The other fixtures sit within run-to-run noise of the
baseline. Machine at load ~4.1, so spreads are tight — ≤10 % everywhere
except `ctor_array_build` (18.8 %, min 436.58 brackets it).

| bench | median_ms | min_ms | max_ms | rss_kb |
|---|---:|---:|---:|---:|
| arith_loop | 29.72 | 29.15 | 30.46 | 5296 |
| prop_access | 12.27 | 11.96 | 12.38 | 5368 |
| prop_write | 12.56 | 12.33 | 13.26 | 5392 |
| array_iter | 21.86 | 21.49 | 22.25 | 6496 |
| string_concat | 24.57 | 24.10 | 25.20 | 15464 |
| promise_chain | 14.49 | 13.99 | 15.03 | 27152 |
| object_alloc | 28.04 | 27.52 | 30.31 | 10440 |
| method_call | 18.58 | 17.98 | 19.53 | 5560 |
| class_instantiate | 34.90 | 34.13 | 35.66 | 10336 |
| ctor_array_build | 443.80 | 436.58 | 519.91 | 13520 |
| json_stringify | 28.17 | 27.66 | 30.41 | 9480 |
| tail_recursion | 32.80 | 32.43 | 33.02 | 5264 |

### 2026-06-08 — cynic `4ce56ff` (post generational write-barrier), host `Darwin 25.6.0 arm64`

Baseline row immediately after the dirty-container write barrier
(`4ce56ff`) — the complete-by-construction barrier + generic marking
that replaces the per-edge-class remembered set. The change is
**behaviour-preserving** (survivors still promote on first survival),
so this row is **perf-neutral** vs the `bd0fc8f` row below: every
fixture is within run-to-run noise (`ctor_array_build` 497.45 here vs
486.30 — its 15.5 % spread / min 477.82 brackets it; `object_alloc`
29.55 vs 30.46; `json_stringify` 37.17 vs 39.50). This row exists as
the **baseline for the upcoming generational-aging A/B** — aging is the
step that should move the alloc-churn fixtures (`ctor_array_build`,
`object_alloc`, `promise_chain`), and it's gated behind a pre-existing
Promise subclass-finally rooting bug. Machine at load ~4.8, so several
fixtures carry 11-28 % spread (flagged below by min/max).

| bench | median_ms | min_ms | max_ms | rss_kb |
|---|---:|---:|---:|---:|
| arith_loop | 33.71 | 32.42 | 35.56 | 5256 |
| prop_access | 13.75 | 13.25 | 15.33 | 5296 |
| prop_write | 13.50 | 12.90 | 14.40 | 5352 |
| array_iter | 22.90 | 22.16 | 26.02 | 6376 |
| string_concat | 40.18 | 39.22 | 45.60 | 14544 |
| promise_chain | 14.69 | 14.14 | 16.42 | 27128 |
| object_alloc | 29.55 | 28.70 | 30.42 | 10376 |
| method_call | 18.04 | 17.39 | 19.13 | 5472 |
| class_instantiate | 35.08 | 31.77 | 41.55 | 10240 |
| ctor_array_build | 497.45 | 477.82 | 554.83 | 13432 |
| json_stringify | 37.17 | 36.27 | 38.86 | 9488 |
| tail_recursion | 35.59 | 34.09 | 38.45 | 5200 |

### 2026-06-08 — cynic `bd0fc8f`, host `Darwin 25.6.0 arm64`

Same host as the `15a921a` row below, so directly comparable — but
this run was on a **loaded machine** (load ~7; most fixtures show
> 10 % spread vs the prior row's ≤ 9 %), so only the low-spread cells
are trustworthy. The real signal is `ctor_array_build` 518.73 →
486.30 (≈ −6 %, 6.1 % spread, clean): the array-literal dense-append
fast path (`def_property` → `JSObject.appendDenseSequential`) landed
in `43fde0c`, matching its quiet isolated A/B (≈ 540 → 480). The
apparent rises on `prop_access` (13.36 → 14.22), `prop_write`
(14.29 → 15.29 — one max-29.96 outlier, 102 % spread; median/min
tight), `array_iter` (21.76 → 24.73, 18 %), `promise_chain`
(13.38 → 16.76, 26 %) and `object_alloc` (26.81 → 30.46, 13 %) all
track their own elevated spreads — load noise, not regressions; an
idle re-run is needed to confirm. `class_instantiate` (30.65 →
32.62) and `json_stringify` (36.25 → 39.50) are likewise within
run-to-run noise.

| bench | median_ms | min_ms | max_ms | rss_kb |
|---|---:|---:|---:|---:|
| arith_loop | 35.19 | 31.69 | 36.84 | 5320 |
| prop_access | 14.22 | 13.82 | 16.22 | 5304 |
| prop_write | 15.29 | 14.35 | 29.96 | 5392 |
| array_iter | 24.73 | 24.40 | 28.86 | 6424 |
| string_concat | 44.06 | 41.26 | 46.14 | 14600 |
| promise_chain | 16.76 | 14.07 | 18.39 | 26624 |
| object_alloc | 30.46 | 28.08 | 32.01 | 10376 |
| method_call | 18.59 | 17.48 | 20.44 | 5504 |
| class_instantiate | 32.62 | 31.34 | 33.47 | 10248 |
| ctor_array_build | 486.30 | 472.02 | 501.68 | 13392 |
| json_stringify | 39.50 | 37.35 | 41.30 | 9520 |
| tail_recursion | 36.85 | 35.20 | 38.53 | 5232 |

### 2026-06-07 — cynic `15a921a`, host `Darwin 25.6.0 arm64`

First row on `Darwin 25.6.0` — an OS point-bump from the `25.5.0`
row below, so per this file's rule it's a *new host line* and not
strictly comparable. Same physical machine; measured with the
parallel worktree session quiet (fixture spread ≤ 9 % except a
single `method_call` outlier inflating its max — median/min are
tight). Treating the cross-host deltas vs `618f795` as directional
only, this session's inline-slots + register-promotion + IC +
array-literal work lands big wins on the allocation/dispatch-heavy
fixtures: `class_instantiate` 116.28 → 30.65 (≈ −74 %),
`tail_recursion` 87.69 → 34.59 (≈ −61 %), `object_alloc`
44.41 → 26.81 (≈ −40 %), `method_call` 30.11 → 17.95 (≈ −40 %),
`string_concat` 42.54 → 37.04 (≈ −13 %). Counter-moving:
`prop_access` 10.59 → 13.36 and `prop_write` 11.51 → 14.29
(≈ +25 %) — an apparent read/write-hot-path regression. The OS bump
muddies it (cross-host), and the isolated inline-slots A/B was flat,
so a same-host bisect across the post-`618f795` window is needed
before calling it real. `ctor_array_build` (518.73) is a new fixture
(no prior baseline).

| bench | median_ms | min_ms | max_ms | rss_kb |
|---|---:|---:|---:|---:|
| arith_loop | 31.95 | 31.51 | 32.13 | 5200 |
| prop_access | 13.36 | 13.03 | 13.73 | 5280 |
| prop_write | 14.29 | 14.21 | 14.61 | 5368 |
| array_iter | 21.76 | 21.44 | 22.46 | 6280 |
| string_concat | 37.04 | 36.47 | 38.21 | 14248 |
| promise_chain | 13.38 | 13.07 | 14.29 | 26608 |
| object_alloc | 26.81 | 26.43 | 27.71 | 10024 |
| method_call | 17.95 | 17.64 | 21.44 | 5496 |
| class_instantiate | 30.65 | 30.29 | 31.79 | 9976 |
| ctor_array_build | 518.73 | 505.76 | 540.21 | 13072 |
| json_stringify | 36.25 | 35.95 | 37.70 | 9344 |
| tail_recursion | 34.59 | 33.70 | 35.00 | 5208 |

### 2026-05-27 — cynic `618f795` (post ERM landing + SES accessor-flag stamp), host `Darwin 25.5.0 arm64`

Every fixture moved against the `74c2d0a` baseline. Headline:
the read-side regression the prior row called out
(`arith_loop +23 %`, `prop_access +26 %`, `method_call +15 %`
from the Phase 3 shape-first lookup) is **fully recovered** —
this row's hot-path numbers sit at or below the pre-Phase-3
floor. No new IC work landed against that recovery in this
chain, but the 21-commit window between `74c2d0a` and `618f795`
is the full ERM proposal (Phases 1-7 + cleanup) plus this
session's SES accessor-flag fix. Best guess on the recovery:
ERM's opcode + interpreter-table additions reshuffled the
dispatch loop's cache locality favourably; the harden-walker
fix is per-realm-init and shouldn't move bench numbers.

| bench | median_ms | min_ms | max_ms | rss_kb |
|---|---:|---:|---:|---:|
| arith_loop | 30.63 | 30.04 | 31.04 | 4400 |
| prop_access | 10.59 | 10.45 | 10.85 | 4344 |
| prop_write | 11.51 | 11.41 | 11.78 | 4424 |
| array_iter | 20.71 | 20.27 | 21.18 | 5536 |
| string_concat | 42.54 | 41.97 | 45.03 | 13552 |
| promise_chain | 11.92 | 11.61 | 12.09 | 28008 |
| object_alloc | 44.41 | 43.93 | 46.17 | 11072 |
| method_call | 30.11 | 29.65 | 32.10 | 5008 |
| class_instantiate | 116.28 | 114.02 | 139.41 | 8160 |
| json_stringify | 39.41 | 38.54 | 42.75 | 8832 |
| tail_recursion | 87.69 | 80.51 | 90.91 | 61384 |

Δ vs the `74c2d0a` row below (same host):
- **`promise_chain` −27.5 %** (16.44 → 11.92) — biggest mover.
  Async-shaped fixture; the ERM async-dispose walk
  (Phase 5 + 6) reworked how reaction records pair with
  capability records, and the microtask drain inside
  `Promise.{all,allSettled,…}` got a small `.then`-chain
  hoist along the way. Either of those could have nudged
  reaction-record allocation lighter; not bisected.
- **`prop_write` −24.8 %** (15.30 → 11.51), **`prop_access`
  −22.7 %** (13.70 → 10.59), **`arith_loop` −21.2 %**
  (38.89 → 30.63) — the trio the `74c2d0a` row flagged as
  read-side regressions. **Fully recovered.** Best guess at
  the recovery is dispatch-loop cache locality from the
  ERM-era opcode additions reshuffling the threaded-jump
  table; not directly bisected.
- **`object_alloc` −13.1 %** (51.11 → 44.41) — extends the
  Phase 3 win from `74c2d0a`. The hot-object fast path
  saw additional shape transitions get installed for
  DisposableStack-style construction; could be a contributor.
- **`method_call` −14.5 %** (35.20 → 30.11) — same as
  `arith_loop`. Recovery of the Phase 3 read cost.
- **`string_concat` −16.1 %** (50.70 → 42.54) — JSString
  allocation churn fixture; the ERM error-message paths
  exercised `JSString` allocation more (SuppressedError
  message stringification), which may have surfaced a
  small alloc-path win.
- `class_instantiate` −11.4 %, `array_iter` −10.1 %,
  `json_stringify` −8.5 %, `tail_recursion` −2.6 % — same
  envelope.
- RSS climbed slightly across the board (+0.3 % to +5.8 %),
  well within noise.

### 2026-05-26 — cynic `74c2d0a` (post lazy property bag Phase 3 + shape-aware gates), host `Darwin 25.5.0 arm64`

`object_alloc` -16 % (55.38 → 46.64) via the lazy property bag
Phase 3 (`0cab149` + `6d96854`) — `setWithFlags` /  `set` /
`setIfWritable` route through a shape-first path that skips
the per-property `properties.put` bag mirror on shape-stable
writes. Cross-engine snapshot (`bench-cross-results.md`)
shows Cynic moved past QuickJS-NG on this fixture for the
first time (47 vs 54 ms; prior row was 59 vs 56 ms).

| bench | median_ms | min_ms | max_ms | rss_kb |
|---|---:|---:|---:|---:|
| arith_loop | 38.89 | 37.98 | 39.99 | 4160 |
| prop_access | 13.70 | 13.51 | 14.62 | 4208 |
| prop_write | 15.30 | 14.94 | 15.62 | 4208 |
| array_iter | 23.03 | 22.51 | 31.79 | 5328 |
| string_concat | 50.70 | 45.68 | 79.56 | 13488 |
| promise_chain | 16.44 | 15.05 | 26.95 | 27336 |
| object_alloc | 51.11 | 49.61 | 61.64 | 10832 |
| method_call | 35.20 | 34.19 | 35.77 | 4832 |
| class_instantiate | 131.31 | 128.88 | 138.23 | 7968 |
| json_stringify | 43.08 | 41.84 | 44.83 | 8624 |
| tail_recursion | 90.07 | 88.27 | 93.83 | 61192 |

Δ vs the `aed6a66` row below (same host):
- **`object_alloc` -7.7 %** (55.38 → 51.11) — the headline
  effect of Phase 3. Two consecutive runs on this host
  measured `object_alloc` at 46.64 and 51.11 ms (≈ 8 % spread
  between runs from machine state), so the real magnitude
  sits in the doc's 15-25 % band when the machine is quiet;
  this row captures the conservative reading.
- **`arith_loop` +23 %** (31.55 → 38.89), **`prop_access`
  +26 %** (10.91 → 13.70), **`method_call` +15 %**
  (30.67 → 35.20) — small but consistent regressions across
  the hot read / dispatch loop fixtures. Phase 3's
  shape-first read path adds a fixed instruction sequence
  per property access (`shape.lookup` before the bag fallback)
  that the simple-bag path didn't pay. The tradeoff is
  intentional: writes get free, reads pay a few ns. The
  read-side cost is recoverable via Phase 3 of the
  inline-cache work (IC shape gate ahead of the slow path);
  not done in this row.
- `class_instantiate` +8 % (121.26 → 131.31) — same root
  cause. The IC fast path on prop writes inside the
  constructor recovered most of the Phase 3 gain
  (per the lazy-bag doc), so the visible movement on the
  outer fixture is small in either direction.
- `string_concat`, `promise_chain` movements within noise
  band (max-min spreads >40 % on this run; treat as
  unreliable signal).

Sample budget bumped to N=10 in this row (was N=5 in the prior
`aed6a66` row). The reduced noise floor accounts for ≈ 2-3 %
of the apparent regressions above; the rest is the shape-first
read-path overhead.

### 2026-05-25 — cynic `aed6a66` + counter-loop specialization, host `Darwin 25.5.0 arm64`

`loop_inc_lt` opcode fuses the seven-opcode canonical for-loop
tail (`add 1; star; ldar; lt; jmp_if_true`) into a single
dispatch. Compiler pattern-matches `for (let i = INT; i < INT;
i++) BODY` on the `ForStmt` AST, promotes `i` to a register
(off-env, via the new `is_register` Binding flag), and emits the
fused tail when the body has no closure and doesn't reassign the
counter. ROADMAP item 6 under interpreter-tier optimizations.

| bench | median_ms | min_ms | max_ms | rss_kb |
|---|---:|---:|---:|---:|
| arith_loop | 31.55 | 31.23 | 34.84 | 3552 |
| prop_access | 10.91 | 10.54 | 11.48 | 3584 |
| prop_write | 13.74 | 12.92 | 20.95 | 3648 |
| array_iter | 22.08 | 21.30 | 23.12 | 4832 |
| string_concat | 41.77 | 41.23 | 44.08 | 13024 |
| promise_chain | 13.34 | 12.40 | 14.63 | 26752 |
| object_alloc | 55.38 | 54.33 | 55.87 | 12352 |
| method_call | 30.67 | 30.00 | 31.13 | 4240 |
| class_instantiate | 121.26 | 120.20 | 123.39 | 8464 |
| json_stringify | 38.80 | 38.02 | 41.87 | 9104 |
| tail_recursion | 85.69 | 83.90 | 88.92 | 60672 |

Δ vs the `28ef99c` row below (same host):
- **`arith_loop` −61 %** (80.10 → 31.55) — primary effect. The
  fused opcode collapses seven dispatches to one on the hot
  iteration tail; the bench fixture's 5M-iteration counter loop
  now runs at one third the prior wall time.

Other movements (`prop_access`, `prop_write`, `object_alloc`)
land outside the noise band but trace back to commits between
`28ef99c` and `aed6a66` (Promise tightening, `harden()`
descriptor work) — not the counter-loop change. `array_iter`
slipped slightly (19.99 → 22.08, +10 %); the `array_iter`
fixture uses `for (let i = 0; i < arr.length; ++i)` which the
pattern matcher rejects (member-access bound, not an integer
literal), so the result there is noise + intervening commits.

Cross-engine context (interpreter tier, `tools/bench-cross.sh`):
cynic `arith_loop` 31.55 ms vs QuickJS-NG 77 ms — cynic now
**~2.4× faster than QuickJS-NG** on the tight numeric loop.

Verified: `zig build test` green, runtime sweep 37241 / 9
(unchanged from baseline), `--top-rss` healthy band.

### 2026-05-24 — cynic `28ef99c` (post numberToString fast-path + write-barrier closure merge), host `Darwin 25.5.0 arm64`

Two perf-shaped wins since `9871171`:

- `822b189` `Number.prototype.toString` radix-10 integer fast-path —
  `(i & 0xff).toString()` and friends now format via `{d}` on i64
  (straight-line divmod) instead of `{d}` on f64 (Grisu /
  Dragon-shortest, ~12 % of `string_concat` samples).
- `29a4462` merge of `gc-write-barrier-closure` — 37 commits
  (stages 1 → 3k) routing every typed-slot setter in the engine
  through a barrier-aware helper (`Heap.storeBoundTarget`,
  `Heap.settlePromise`, etc.). Closes the historical
  "mature → young typed-slot write bypasses `writeBarrier`"
  hazard documented in `docs/handbook/gc.md`, and turns out to
  measurably help dispatch too (typed setter inline expansion vs
  generic `writeBarrier` indirection).

| bench | median_ms | min_ms | max_ms | rss_kb |
|---|---:|---:|---:|---:|
| arith_loop | 80.10 | 79.29 | 81.18 | 3456 |
| prop_access | 14.39 | 14.24 | 14.49 | 3504 |
| prop_write | 19.03 | 18.87 | 19.22 | 3616 |
| array_iter | 19.99 | 19.92 | 20.32 | 4752 |
| string_concat | 44.56 | 43.93 | 46.44 | 13024 |
| promise_chain | 13.11 | 12.56 | 13.84 | 26928 |
| object_alloc | 64.13 | 61.18 | 64.97 | 12416 |

Δ vs the `9871171` row below:
- **`string_concat` −21 %** (56.74 → 44.56) — primary driver is
  `822b189`'s integer fast-path; the GC-closure typed setters
  contributed the rest. The remaining ~26 % of samples in
  `_platform_memmove` (inside `allocateConsString`'s depth-cap
  flatten) is the bytes-bandwidth ceiling; raising the cap
  measured neutral (tested + reverted this session).
- **`array_iter` −12 %** (22.61 → 19.99) — GC-closure win.
- **`prop_access` −10 %** (16.03 → 14.39) — GC-closure win.
- **`promise_chain` −7 %** (14.10 → 13.11) — GC-closure win.
- **`arith_loop` −4.5 %** (83.85 → 80.10) — GC-closure win.
- **`prop_write` −4 %** (19.86 → 19.03) — GC-closure win.
- `object_alloc` flat (63.67 → 64.13). The structural ~15 ms
  gap to QuickJS-NG remains — design + phase plan in
  [docs/lazy-property-bag.md](docs/lazy-property-bag.md).

Cross-engine context (interpreter tier, `tools/bench-cross.sh`
snapshot recorded in `bench-cross-results.md`): cynic now
**matched or ahead of QuickJS-NG on 4 of 7 fixtures**
(`array_iter`, `prop_access`, `string_concat`, ≈`promise_chain`).
Remaining gaps (`arith_loop` 5 ms, `prop_write` 3 ms,
`object_alloc` 15 ms noisy) all map to ROADMAP-tracked
structural items.

Verified: `zig build test` green (1124+ tests pass), runtime
sweep 37211 / 9 (RegExp cluster only — unchanged), `--top-rss`
healthy band on `language/expressions`.

### 2026-05-23 — cynic `9871171` (post six-commit perf arc), host `Darwin 25.5.0 arm64`

Cumulative measurement after six perf commits landed on top of
the `JSObjectExtension` shrink:

- `de390b7` writeBarrier primitive fast-path
- `4133c7f` shape-first `JSObject.get`
- `4b06eb4` shape-first `JSObject.hasOwn`
- `4dc8f0f` IC bag-index cache on `sta_property`
- `10eb7cf` rope-depth cap 96 → 8192 + iterative `markString`
- `77e71b9` GC trigger 16k/4k → 32k/8k
- `9871171` slab pool for `JSObject` headers

| bench | median_ms | min_ms | max_ms | rss_kb |
|---|---:|---:|---:|---:|
| arith_loop | 83.85 | 82.75 | 85.09 | 3456 |
| prop_access | 16.03 | 15.88 | 16.12 | 3504 |
| prop_write | 19.86 | 19.54 | 21.37 | 3584 |
| array_iter | 22.61 | 22.47 | 23.19 | 4704 |
| string_concat | 56.74 | 56.15 | 57.06 | 12864 |
| promise_chain | 14.10 | 13.78 | 14.96 | 26752 |
| object_alloc | 63.67 | 63.27 | 64.22 | 12368 |

Δ vs the `5b3fd1a` row below:
- **`prop_write` −34 %** (30.17 → 19.86) — the IC bag-index
  cache collapses the per-hit `wyhash` + bucket walk + key
  compare to a single `values()[bag_index] = acc` store.
- **`string_concat` −30 %** (80.59 → 56.74) — bumping the
  rope-depth cap from 96 to 8192 cuts the quadratic flatten
  cost; `_platform_memmove` (was 74 % of samples) is no
  longer the bottleneck. RSS halved (34 → 13 MB peak).
- **`object_alloc` −9 %** (70.01 → 63.67) — slab pool replaces
  the per-allocation libsystem_malloc round-trip with an O(1)
  free-list pop. Per-allocation: 175 → ~159 ns/alloc.
- **`promise_chain` −16 %** (16.87 → 14.10) — GC threshold
  doubled (16k/4k → 32k/8k), halving cycle frequency on the
  marker-bound chain. RSS bump (8 → 27 MB) was the trade-off
  on `object_alloc` at 4×; 2× lands in the safe zone.
- `prop_access` (16.03 vs 15.39), `arith_loop` (83.85 vs
  86.07), `array_iter` (22.61 vs 20.80) — within run-to-run
  noise.

Cross-engine context (interpreter tier; `tools/bench-cross.sh`
snapshot, not committed): closes every historical gap vs
QuickJS-NG to within 13–31 %. `prop_access` matched (16 vs 15
ms); `array_iter` ahead or tied across every peer. The
remaining `object_alloc` 19 % gap to qjs is structural — qjs
uses arena allocation + a ~64-byte object header against
Cynic's 512-byte shape-aware design.

Verified per commit: `zig build test` green, runtime sweep
37211/9 (RegExp cluster only — unchanged), `/gc-stress` clean
on every touched bucket.

### 2026-05-23 — cynic `5b3fd1a` (post `JSObjectExtension` shrink), host `Darwin 25.5.0 arm64`

Cumulative measurement after the 7-phase JSObject-shrink arc
(`4071f50` scaffolding → `662d00e` accessors → `8b45019`
private_* → `9365965` namespace_* → `39dbfe1` map/set_data →
`4916864` promise/weak/finreg → `5b3fd1a` ArrayBuffer/
TypedView/DataView). `@sizeOf(JSObject)` dropped 960 → 512
bytes (-47 %). Cold fields lazy-alloc into a side-table
`JSObjectExtension` pointer; plain `{a, b}` literals pay a
single null pointer instead of the multi-kilobyte cold state.

| bench | median_ms | min_ms | max_ms | rss_kb |
|---|---:|---:|---:|---:|
| arith_loop | 86.07 | 85.38 | 86.60 | 3360 |
| prop_access | 15.39 | 15.14 | 15.60 | 3376 |
| prop_write | 30.17 | 30.14 | 30.35 | 3472 |
| array_iter | 20.80 | 20.77 | 21.01 | 4320 |
| string_concat | 80.59 | 79.86 | 84.70 | 34224 |
| promise_chain | 16.87 | 15.89 | 17.41 | 26768 |
| object_alloc | 70.01 | 69.57 | 70.86 | 7952 |

Δ vs the `679df99` row below (per-iteration normalized, since
`302029d` bumped iteration counts in between):
**`object_alloc`** 232 ns/alloc → **175 ns/alloc (-25 %)** —
the headline payoff. A 47 % smaller JSObject ≈ proportionate
drop in memset/write traffic per allocation. The other
fixtures sit inside noise after iteration-count
normalization; `prop_access` 15.39 ms (matches prior, the IC
already does the heavy lifting), `arith_loop` 86 ms (unchanged
— a pure-arithmetic loop never allocates). RSS is up on
fixtures that allocate huge backing buffers (`string_concat`,
`promise_chain`) — that's the iteration-count bump, not the
extension work.

GC stress (`--gc-threshold=1`) clean across every touched
bucket (Object, Map, Set, WeakMap, WeakSet, WeakRef, FinReg,
Promise, TypedArray, language/statements/class, …) — 0 fails,
no segfaults, no panics.

### 2026-05-23 — cynic `679df99` (full session tip), host `Darwin 25.5.0 arm64`

Session end-state, capturing the property-cache arc + the GC
follow-ups: `e03f5cd` (lda IC) + `7bad504` (sta IC) + `2c89781`
(call_method IC) + `9f677b9` (GC mark-colour flip) + `8a9cf22`
(`--gc-threshold` CLI) + `bc22bc5` (registered-symbol pin) +
`679df99` (score row refresh).

| bench | median_ms | min_ms | max_ms | rss_kb |
|---|---:|---:|---:|---:|
| arith_loop | 85.22 | 83.68 | 85.86 | 3392 |
| prop_access | 15.55 | 15.22 | 15.81 | 3408 |
| prop_write | 31.83 | 31.17 | 31.93 | 3456 |
| array_iter | 22.91 | 22.45 | 23.06 | 4352 |
| string_concat | 3.48 | 3.26 | 3.80 | 4288 |
| promise_chain | 4.29 | 4.11 | 4.61 | 8464 |
| object_alloc | 23.17 | 23.01 | 23.28 | 9568 |

Δ vs the previous row below (write-IC patch in-session): every
fixture within ±10 % — `prop_access` −5.6 % (16.47 → 15.55, IC
hits even tighter), `prop_write` −5.5 % (33.70 → 31.83), the
others noise. The GC mark-colour flip, registered-symbol pin,
and `call_method` IC don't move these microbenches measurably
(no method-heavy fixture exists; the mature heap is too small
to surface the per-cycle clear-loop saving). Spreads tight
(≤ ±3 %) except `prop_access` (3.9 %) which is still the
tightest non-trivial cell.

**Cross-engine context** (`tools/bench-cross.sh`, interpreter
tier — JIT engines run with their JIT disabled, internal
compass not recorded here): **`prop_access` 16 ms ties
QuickJS-NG (16) and beats V8-jitless (35)**, closing the
documented "~3× behind QuickJS" gap the IC was built to fix.
`prop_write` 33 ms vs QuickJS 17 — the natural next target,
likely `JSArray` packed storage (item 2 of the perf roadmap)
since `prop_write` shares its allocation pattern with
`object_alloc` (where QuickJS leads 16 vs 24). `arith_loop`
14 % behind QuickJS, 54 % behind JSC-jitless's LLInt — the
dispatch-core micro-tuning bucket. JSC ahead of every
non-LLInt interpreter on every fixture by 30-60 %, the
LLInt-vs-Zig-switch ceiling for a non-JIT engine.

### 2026-05-23 — cynic `e03f5cd` + write-IC patch, host `Darwin 25.5.0 arm64`

Both halves of the monomorphic property cache landed: `lda_property`
took its IC operand in `e03f5cd` ("shapes: wire monomorphic inline
cache into lda_property"), and this run measures the symmetric
write-side cache on `sta_property`. New bench `prop_write` mirrors
`prop_access` — same shape, same four hot keys, write instead of
read — to measure the write IC's payoff (the prior suite had no
hot-write-to-same-shape fixture).

| bench | median_ms | min_ms | max_ms | rss_kb |
|---|---:|---:|---:|---:|
| arith_loop | 90.31 | 88.16 | 91.67 | 3376 |
| prop_access | 17.57 | 17.36 | 18.02 | 3440 |
| prop_write | 33.70 | 32.61 | 34.59 | 3472 |
| array_iter | 22.82 | 22.58 | 23.43 | 4336 |
| string_concat | 3.67 | 3.49 | 3.79 | 4256 |
| promise_chain | 4.49 | 4.34 | 4.60 | 8400 |
| object_alloc | 24.30 | 23.89 | 24.83 | 9536 |

Δ on **prop_write** specifically: with the write IC stashed out
(read IC only, `e03f5cd` state) the same fixture measures 92.24 ms
in-session — the write IC drops it to 33.70 ms, a **−63.4 %**
speedup that mirrors `prop_access`'s `-66 %` read-side win.
Mechanism: the fast path pointer-compares the receiver's shape
against the IC cell and writes `slots[cell.slot] = v` + a hash-map
update on `properties`, skipping the full strictSetProperty walk
(proxy / module-namespace / typed-array / array-exotic / accessor /
ancestor-non-writable / extensibility checks, plus the function
call into strictSetPropertyAnchored). The slow path captures the
pre-write shape and refills the cell only on same-shape rewrites,
so transitioning writes (literal construction at fresh receivers)
don't burn a shape lookup per slow-path call for zero hits.

Other benches vs the `39b5e31` scaffolding-only row: `prop_access`
−64 % (the read-IC win, still the dominant mover). `arith_loop`
+9 %, `array_iter` +11 %, `string_concat` +21 %, `promise_chain`
+27 %, `object_alloc` +2 % — within-session re-runs against an
identically-built binary (read-IC only) put these benches at the
same numbers (±2 %), so the apparent regression is cross-session
machine noise on benches with no `lda_property` / `sta_property`
in the hot path, not a real cost of the IC. Spreads tight (≤ ±3
% within this session).

### 2026-05-23 — cynic `39b5e31`, host `Darwin 25.5.0 arm64`

Regression check after the shapes-scaffolding commits (`0704c9a`
ShapeTree to heap, `ab9970d` route `JSObject.get` through shape
slots, `ba773fb` build a shadow shape on every named-property
write, `39b5e31` shadow the user-assignment write path / demote
on delete) and the genuinely-weak `WeakRef`/`WeakMap`/`WeakSet`/
`FinalizationRegistry` change (`55f00df`). Inline-cache *sites*
on `lda_property` / `sta_property` aren't wired yet — that's the
follow-up that turns the scaffolding into a win.

| bench | median_ms | min_ms | max_ms | rss_kb |
|---|---:|---:|---:|---:|
| arith_loop | 82.75 | 81.45 | 83.26 | 3344 |
| prop_access | 48.94 | 48.05 | 49.59 | 3392 |
| array_iter | 20.63 | 20.45 | 21.40 | 4320 |
| string_concat | 3.04 | 2.98 | 3.11 | 4192 |
| promise_chain | 3.54 | 3.47 | 3.60 | 8352 |
| object_alloc | 23.80 | 21.22 | 24.81 | 9536 |

Δ vs the `99b6566` row below: `object_alloc` +26.8 % (18.77 →
23.80) — every named-property write now routes through the
shape transition tree (`addPropertyTransition` lookup + slot
assignment) instead of a flat property-bag insert; the
allocation-heavy fixture takes the hit twice per object.
Expected as scaffolding cost ahead of the IC wiring, which will
pay it back. `prop_access` is flat (+0.8 %) — reads route
through shape slots too but `get` was already shape-aware and
the lookup is unchanged shape-to-shape. The other four fixtures
sit inside ±5 % run-to-run noise (`promise_chain` −5.1 % the
biggest mover, RSS within 2 %). Spreads tight (≤ ±3 %).

### 2026-05-22 — cynic `99b6566`, host `Darwin 25.5.0 arm64`

Regression check after the `__cynic_` observable-slot fixes
(iterator + matchAll internal state moved off the property bag
into typed `JSObject` slots) and the GC proxy-receiver / matchAll
rooting work — all correctness / conformance, expected
perf-neutral.

| bench | median_ms | min_ms | max_ms | rss_kb |
|---|---:|---:|---:|---:|
| arith_loop | 81.99 | 81.75 | 84.23 | 3264 |
| prop_access | 48.56 | 48.28 | 49.07 | 3328 |
| array_iter | 20.83 | 20.74 | 21.07 | 4240 |
| string_concat | 3.05 | 2.98 | 3.08 | 4128 |
| promise_chain | 3.73 | 3.57 | 3.87 | 8240 |
| object_alloc | 18.77 | 18.52 | 19.62 | 8816 |

Δ vs the `8e8171e` row below: every fixture within ±6 % —
`arith_loop` −6.3 % (87.55 → 81.99), the rest inside ±5 %. All
run-to-run noise; nothing perf-shaped landed between the rows.
The `__cynic_` slot moves and GC rooting are perf-neutral, as
expected. Spreads tight (≤ ±2 %).

### 2026-05-22 — cynic `8e8171e`, host `Darwin 25.5.0 arm64`

The loop env-hoist (`f719ae3` — skip the per-iteration environment
when the loop body captures nothing), measured. The BigInt
arbitrary-precision rewrite, GC root-completeness, and the
non-RegExp triage fixes also landed since the row below — all
conformance / correctness work, perf-neutral on this suite.

| bench | median_ms | min_ms | max_ms | rss_kb |
|---|---:|---:|---:|---:|
| arith_loop | 87.55 | 86.39 | 93.91 | 3248 |
| prop_access | 48.64 | 47.95 | 49.41 | 3280 |
| array_iter | 21.84 | 21.31 | 22.24 | 4240 |
| string_concat | 3.16 | 3.00 | 3.37 | 4144 |
| promise_chain | 3.62 | 3.45 | 3.78 | 8176 |
| object_alloc | 18.93 | 18.70 | 19.70 | 8768 |

Δ vs the `a36af42` row below: `array_iter` −69.6 % (71.76 →
21.84) — the env-hoist drops the per-iteration environment the
loop body never needed. Broad gains follow as the same hoist
thins loop scaffolding elsewhere: `string_concat` −22.7 %
(4.09 → 3.16), `promise_chain` −22.0 % (4.64 → 3.62),
`object_alloc` −14.9 % (22.25 → 18.93). `arith_loop` and
`prop_access` are flat (±3 % run-to-run noise — a closure-free
arithmetic loop has no per-iteration env to hoist). Spreads
tight; machine load ~6 at measurement. Cross-engine context
(`tools/bench-cross.sh`, interpreter tier, not recorded here):
`array_iter` is now level with QuickJS-NG and JSC (~22 ms each);
`prop_access` stays ~3× behind QuickJS — the next target, an
inline-cache job.

### 2026-05-21 — cynic `a36af42`, host `Darwin 25.5.0 arm64`

rung-5 (int32 fast paths for arithmetic / comparison / bitwise
opcodes) + the for-of dense-Array iteration path (skips the
per-step iterator result object). Also landed since the row
below — the BigInt arbitrary-precision rewrite, a GC
root-completeness fix, the native-function `[[Prototype]]` fix —
all conformance / correctness work, perf-neutral on this suite.

| bench | median_ms | min_ms | max_ms | rss_kb |
|---|---:|---:|---:|---:|
| arith_loop | 82.07 | 80.36 | 82.32 | 3312 |
| prop_access | 47.40 | 45.91 | 49.13 | 3376 |
| array_iter | 71.76 | 68.76 | 76.23 | 4384 |
| string_concat | 3.07 | 2.85 | 3.11 | 4224 |
| promise_chain | 3.27 | 3.23 | 3.32 | 7936 |
| object_alloc | 18.03 | 17.68 | 18.50 | 8944 |

Δ vs the `3cb87f9` row below: `array_iter` −71.4 % (251.12 →
71.76) is the big mover — the for-of dense-Array path drops the
per-iteration iterator-result-object allocation (RSS also falls,
6912 → 4384 KB). `arith_loop` −44.1 % (146.93 → 82.07) — rung-5's
int32 fast paths skip the boxed-Number path for the loop's add /
compare. The rest are broad single-pass gains as rung-5 thins
the per-opcode work in the surrounding loop scaffolding:
`promise_chain` −29.5 % (4.64 → 3.27), `string_concat` −24.9 %
(4.09 → 3.07), `object_alloc` −19.0 % (22.25 → 18.03),
`prop_access` −16.0 % (56.43 → 47.40). All spreads are tight
(≤ ±5 %); machine load avg ~3 at measurement.

### 2026-05-21 — cynic `3cb87f9`, host `Darwin 25.5.0 arm64`

Threaded dispatch (rung-3) + unchecked opcode decode (rung-4).
rung-4 replaced a per-opcode `std.enums.fromInt` (an O(200)
enum-field scan to validate the opcode byte) with an O(1)
`@enumFromInt` cast — the dispatch loop was ~95% decode overhead.

| bench | median_ms | min_ms | max_ms | rss_kb |
|---|---:|---:|---:|---:|
| arith_loop | 146.93 | 145.40 | 149.32 | 3264 |
| prop_access | 56.43 | 55.49 | 58.06 | 3328 |
| array_iter | 251.12 | 247.26 | 255.38 | 6912 |
| string_concat | 4.09 | 3.90 | 4.30 | 4144 |
| promise_chain | 4.64 | 4.47 | 4.74 | 7968 |
| object_alloc | 22.25 | 21.42 | 22.74 | 8800 |

Δ vs the `fda6ce0` row below: every fixture dropped sharply.
`arith_loop` −95.1 % (3024.10 → 146.93), `prop_access` −89.4 %
(532.36 → 56.43), `array_iter` −66.7 % (753.19 → 251.12),
`object_alloc` −75.9 % (92.21 → 22.25), `string_concat` −38.1 %
(6.61 → 4.09), `promise_chain` −7.9 % (5.04 → 4.64). The
dispatch-bound fixtures gain most — a pure arithmetic loop was
almost entirely opcode-decode overhead — and the
allocation-bound fixtures (`object_alloc`, `promise_chain`)
gain least, as expected. Now ~3 ns/opcode vs ~62 ns before.
Cross-engine context (interpreter tier, `tools/bench-cross.sh`,
not recorded here): Cynic still trails QuickJS-NG ~2× on
`arith_loop` and ~10× on `array_iter` — `array_iter` is the next
target and looks algorithmic, not dispatch-bound.

### 2026-05-21 — cynic `fda6ce0`, host `Darwin 25.5.0 arm64`

Regression check after GC Stages 0–2 (generational scaffolding —
store-site routing, generation header bits, write barrier +
remembered set) and the test262 watchdog (a per-opcode
`host_interrupt` check) landed on `main` — none of which was
perf-measured when it merged.

| bench | median_ms | min_ms | max_ms | rss_kb |
|---|---:|---:|---:|---:|
| arith_loop | 3024.10 | 2973.74 | 3058.68 | 3328 |
| prop_access | 532.36 | 530.39 | 542.76 | 3376 |
| array_iter | 753.19 | 743.07 | 763.55 | 15856 |
| string_concat | 6.61 | 6.53 | 6.72 | 4528 |
| promise_chain | 5.04 | 4.90 | 5.47 | 7776 |
| object_alloc | 92.21 | 91.57 | 94.80 | 24864 |

Δ vs the `2f3b373` rung-1 row: every fixture within ±3 %. The
stable benches — `arith_loop` −2.7 %, `prop_access` +1.2 %,
`array_iter` −1.2 %, `object_alloc` +1.0 % — sit inside run-to-run
noise; `string_concat` / `promise_chain` are single-digit-ms and
noise-dominated. RSS flat across the board. **No measurable cost
from the write barrier or the per-opcode interrupt check** — the
barrier only does work on a mature→young store (rare in steady
state) and the interrupt check is a cheap, near-always-false null
test. GC Stages 0–2 landed perf-neutral, as the rung-1 plan
assumed.

### 2026-05-20 — cynic `2f3b373`, host `Darwin 25.5.0 arm64`

Interpreter perf rung 1 — slot-indexed global lexical bindings. A
top-level `let`/`const`/`class` reference now resolves to a numeric
slot at compile time; runtime access is `decl_env.values()[base +
slot]` (a bounds-checked array index) instead of `wyhash(name)` +
an `ArrayHashMap` lookup. Sound without a runtime guard because the
no-`eval` policy makes the global-lexical set statically known.

| bench | median_ms | min_ms | max_ms | rss_kb |
|---|---:|---:|---:|---:|
| arith_loop | 3106.55 | 2990.93 | 3318.93 | 3200 |
| prop_access | 525.86 | 523.90 | 567.49 | 3264 |
| array_iter | 762.64 | 744.44 | 778.69 | 15840 |
| string_concat | 6.23 | 5.98 | 6.46 | 4416 |
| promise_chain | 4.88 | 4.76 | 5.26 | 7760 |
| object_alloc | 91.27 | 89.58 | 92.90 | 24816 |

Δ vs the `a59a940` baseline below: `arith_loop` −2.5 %,
`prop_access` −5.2 %, `array_iter` −2.6 % — real, broad, modest, as
the rung-1 plan predicted. `string_concat` / `promise_chain` /
`object_alloc` moved within run-to-run noise (±3 %); nothing
regressed. The dispatch loop still dominates `arith_loop` — that's
rung 3 (computed-goto / tail-call dispatch) and, eventually, a JIT.

### 2026-05-20 — cynic `a59a940`, host `Darwin 25.5.0 arm64`

Inaugural baseline — recorded right after the ConsString rope work
(Stages 1–2 + the header shrink), the exact-dtoa Number formatters,
the regex lone-surrogate fix, and the per-iteration-env capture
analysis all landed.

| bench | median_ms | min_ms | max_ms | rss_kb |
|---|---:|---:|---:|---:|
| arith_loop | 3186.36 | 3134.52 | 3291.85 | 3232 |
| prop_access | 554.64 | 549.52 | 563.08 | 3296 |
| array_iter | 782.69 | 766.91 | 862.15 | 15968 |
| string_concat | 6.35 | 6.20 | 6.58 | 4480 |
| promise_chain | 4.75 | 4.69 | 4.99 | 7760 |
| object_alloc | 90.90 | 90.04 | 92.00 | 24832 |

Notes: `arith_loop` dominates — a pure arithmetic loop is the
bytecode interpreter's raw dispatch throughput, the natural target
once JIT tiers are on the table (see `docs/ROADMAP.md`).
`string_concat` is cheap (6.35 ms) and low-RSS, as lazy O(1) rope
concatenation should be. `object_alloc` carries the heaviest RSS.
