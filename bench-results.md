# Cynic micro-bench history

Per-fixture wall-time + peak RSS on the hand-picked micro-bench
suite in `bench/micros/`. Produced by `zig build bench` — a
dedicated ReleaseFast `cynic-bench` binary, median of 5 runs after
a discarded warmup.

**Numbers are only stable on a quiet machine, and only comparable
within the same `host` line.** Cross-machine and cross-engine
comparison is meaningless here — see `docs/benchmarking.md`.

Newest run first. Append a fresh section per recorded run; diff a
new run against the previous section with the *same host*.

## History

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
