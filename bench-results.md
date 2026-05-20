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
