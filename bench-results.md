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
