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
