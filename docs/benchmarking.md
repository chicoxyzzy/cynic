# Cynic Performance Benchmarking

How we measure Cynic's performance and compare against other JS engines.

## Goals

1. **Catch regressions** — when an interpreter or runtime change tanks
   throughput on a workload that used to be fast.
2. **Compare against the field** — Cynic vs V8, JavaScriptCore,
   SpiderMonkey, QuickJS on the same hardware, same input, same
   measurement protocol.
3. **Surface CPU and memory together** — wall time alone hides
   allocator pressure and GC pause cliffs.

Out of scope: DOM benchmarks (Speedometer etc.) — Cynic targets
non-browser edge / server runtimes.

## Tooling foundation

Two community projects do the boring parts; we don't reinvent them.

- **[jsvu](https://github.com/GoogleChromeLabs/jsvu)** — installs and
  updates pinned engine binaries (`v8`, `jsc`, `sm`, `qjs`,
  `engine262`, `boa`, …) into `~/.jsvu/`. One command:
  `jsvu --engines=v8,sm,jsc,qjs`.

- **[eshost-cli](https://github.com/bterlson/eshost-cli)** — uniform
  shim layer over those binaries. Normalizes `print()`, exit codes,
  file loading, error reporting across the engines so one script
  runs everywhere. Same toolchain test262 maintainers use for
  cross-engine reproduction.

Register Cynic with eshost once per dev machine:

    eshost-cli --add cynic ch zig-out/bin/cynic

(`ch` is the generic chakra-style shell type — it expects `print()`,
which we already expose.)

Neither tool measures performance. They run the scripts; our Zig
harness does the timing and resource accounting.

## Architecture

```
tools/bench.zig                  Zig driver — spawn, time, aggregate
  ├─ wraps `eshost-cli --host=<E> --raw <script>` per (suite, subtest, engine)
  ├─ captures rusage (user/sys CPU, peak RSS, page faults) on return
  ├─ parses stdout for in-script timings + engine-reported heap stats
  └─ writes bench-results.md (date-keyed, like test262-results.md)

bench/prologue.js                Shared per-engine probe shim
  ├─ exposes __perfNow()           — performance.now() with fallback
  ├─ exposes __heapUsed()          — per-engine heap-bytes lookup
  └─ exposes __gcCollect()         — per-engine forced-GC hook (where available)

bench/jetstream2/                JetStream 2.0 (submodule of WebKit/PerformanceTests)
bench/octane/                    Octane archive (V8 retired suite, still tracked)
bench/micros/                    Cynic-specific microbenchmarks
bench/ohaimark/                  Natural-threshold T1/T2 rollout fixtures
```

### Suite selection

| Suite | What it measures | Why we run it |
|---|---|---|
| **JetStream 2** | Mixed throughput + latency + startup across 64 subtests | Industry-standard; every major engine team publishes JS2 numbers |
| **Octane** | 15 throughput microbenches (Crypto, Splay, Mandreel, …) | Older but stable; trivially comparable across engines. The pure-compute **six** (Richards, DeltaBlue, Crypto, RayTrace, NavierStokes, Splay) are vendored in `bench/macros/` — see below. |
| **Custom micros** | Cynic-specific hot paths | Catches regressions in opcodes we own |
| **Ohaimark rollout** | Repeated hot leaf calls under natural T1/T2 thresholds | Guards default-on T2 publication, steady-state entry cost, refusal economics, and guard exits |

Octane is *retired* by its own authors (engines over-tuned to it), so
the macro suite is for **relative tracking** and **cross-engine
interpreter-tier comparison**, never a headline score. The eval-heavy
and generated-blob Octane members (RegExp, EarleyBoyer, pdf.js,
TypeScript, zlib, Box2D, …) are skipped — high effort, low marginal
signal for a strict-only engine. JetStream 2's pure-JS core overlaps
the compute-six; its full harness (WASM + browser bits) is deferred.

Web Tooling Benchmark is **deferred** — it needs Node-style module
resolution, which we don't ship until the module loader lands.

### Custom micro-fixtures

The hand-picked suite in `bench/micros/*.js`. Each fixture targets
one identifiable cost — dispatch density, allocation churn, GC,
the property cache, etc. Iteration counts are sized so Cynic's
wall-time is ~50-100 ms (small-time fixtures get hit by process-
spawn overhead and timer granularity in the cross-engine harness,
flagging cells as noisy at `*` >10% spread). Bump the count if
the fixture drops below ~50 ms on the lead engine.

Run one fixture with `zig build bench -- --filter=<name>`; combine it with
`--runs=<N>`, `--no-jit`, or `--ab-baseline=<binary>` for a focused gate.

| Fixture | Iters | Stresses |
|---|---:|---|
| `arith_loop` | 5,000,000 | Bytecode dispatch density on `Op.add` / `Op.lt` / `Op.jmp` — int32 fast-path + the threaded-dispatch loop with no property access. Smi-overflow paths are NOT exercised (every step stays int32-clean via `\| 0`). |
| `mul_loop` | 3,000,000 | Numeric `Op.mul` dispatch with an Int32/Double raw-operand pair and a Double result. Pins Lantern's one-byte per-site operand profile plus the fused Number multiplication path; the changing multiplicand prevents constant folding. |
| `div_loop` | 3,000,000 | Numeric `Op.div` dispatch with Int32 raw operands and a Double result. Pins Lantern's one-byte per-site operand profile plus the fused Number division path; the changing numerator prevents constant folding. |
| `prop_access` | 500,000 | Hot named-property reads on a same-shape object — `lda_property` IC hit-rate. Pre-IC: ~3× behind QuickJS-NG. Post-IC (e03f5cd): −66 % on Cynic. The headline cache-effectiveness bench. |
| `prop_write` | 500,000 | Hot named-property writes on a same-shape object — `sta_property` IC + shape-shadow update + property-bag put. The mirror of `prop_access`. Post-IC (7bad504): −63 % on Cynic. |
| `array_iter` | 10,000×100 passes | `for-of` over a packed Array — iterator protocol + indexed reads on §10.4.2 Array exotic. The env-hoist (`f719ae3`) was measured here at −69.6 %. |
| `string_concat` | 300,000 | `s = s + chunk` loop — JSString allocation churn, GC byte-trigger, and the ConsString rope path (`min_cons_byte_len` + depth cap). Iteration count picked to balance Cynic ~70 ms against keeping QuickJS-NG under ~50 ms. |
| `promise_chain` | 10,000 | `.then` chain — `promise_reaction` microtask queue + per-iter arrow env + per-iter reaction record. **Bounded by an open bug**: longer chains (≥15k at default GC, ≥100 at `--gc-threshold=1`) hit a SIGSEGV / SIGABRT in the reaction drain (see `docs/test262-upstream-gaps.md`). The bump is held below the failure threshold; lift when the bug lands. |
| `object_alloc` | 400,000 | Fresh-object allocation churn — every iteration produces a new `JSObject` + two string-keyed properties. Heap alloc + GC frequency + property-bag write path. The leanness target for the packed-`JSArray` work (perf roadmap item 2). |
| `method_call` | 500,000 | Hot method dispatch on `obj.method()`. Exercises both the `call_method` IC (callee cache) and the proto-load IC (the method lives on the prototype, not the instance). Warm-IC fast path is shape pointer compare + slot load + direct `callJSFunction`; cold or invalidated falls back to the chain walk + exotic-callee checks. |
| `class_instantiate` | 400,000 | `new Class(args)` allocation churn — `OrdinaryCreateFromConstructor` (proto lookup + fresh `JSObject` + prototype wire), constructor body (`this.x = …` writes through the `sta_property` IC), frame setup, and the literal-shape template cache. Companion to `object_alloc` for class-based allocation. Real-world equivalents: React `createElement`, `new Date()` in formatting loops, `new URL()` parsers. |
| `json_stringify` | 25,000 | `JSON.stringify` hot loop — exercises own-property enumeration (the §25.5.2 EnumerableOwnProperties walk), recursive value serialization, and string concatenation. Different shape from the synthetic micros: tests the property *walk* path rather than read/write specifically. Useful proxy for any workload that touches `Object.keys(o).map(…)` or a serialization path. |
| `tail_recursion` | 1,000,000 deep | §15.10 PTC frame-reuse on the `tail_call` opcode. Workload sized so the recursion would trivially blow the 1024-frame stack ceiling without PTC; with PTC the same call site runs in one frame and the iteration count dominates the timing. Mandatory `"use strict"` because spec PTC only fires in strict mode (JSC, the only other PTC-shipping engine, follows the letter); Cynic is always strict so the directive is a no-op here but keeps the fixture cross-engine portable. |

Adding a fixture: drop a `.js` file in `bench/micros/`, append the
fixture name to the `BENCHES` array in `tools/bench.zig`, then
document it in the table above. Cross-engine picks it up
automatically (`tools/bench-cross.sh` globs `bench/micros/*.js`).

### Ohaimark natural-threshold gate

`zig build bench -- --ohaimark-rollout` selects the dedicated
`bench/ohaimark/*.js` suite. It compares the same ReleaseFast binary under
Bistromath alone (`--jit --no-ohaimark`) and Bistromath plus Ohaimark
(`--jit --ohaimark`), using production thresholds in both cases. Each fixture
gets one discarded warmup per posture, then alternating T1/T2 and T2/T1 process
pairs so slow host drift does not consistently favor one tier. T2 compilation
remains inside the timed child lifetime.

The report uses the median paired `T2 / T1` ratio (`<1` is faster), with `iqr%`
showing the middle 50% of those ratios. It also prints the geometric mean and
worst fixture. One separate T2 probe emits a versioned machine record with
compile attempts, publications/refusals, compile time, installed bytes,
entries, completions, and exits; separating that probe keeps counter formatting
out of the timed samples. Increase confidence with:

    zig build bench -- --ohaimark-rollout --runs=30

The ordinary `bench/micros/mul_loop.js` and `div_loop.js` intentionally invoke
their hot function once. Backedges heat those chunks, but an entry-only T2 has
no later entry at which to compile them; they remain valid T1 benchmarks and
are the shape the **OSR rollout** suite targets.

### Ohaimark OSR natural-threshold gate

`zig build bench -- --ohaimark-osr-rollout` selects `bench/ohaimark_osr/*.js`:
single-call hot loops that only OSR can promote to T2. It compares explicit T1
(`--jit --no-ohaimark`) against the default T2+OSR posture (`--jit --ohaimark`)
in the same ReleaseFast binary with interleaved process pairs. The rollout
driver still passes `--ohaimark-osr` explicitly as a compatibility assertion;
`--no-ohaimark-osr` is the entry-only diagnostic posture. Report columns match
the function-entry rollout:
compile attempts/publications, compile time, code size, entries, exits,
geometric mean, and worst fixture.

    zig build bench -- --ohaimark-osr-rollout --runs=30

The 2026-07-19 graduation repeat measured `0.122x` geometric mean and `0.140x`
worst fixture, with exact differential, GC-pressure, and fuzz gates clean.
The suite remains the regression guard for the default posture.

The ordinary function-entry rollout fixtures repeatedly call small leaf
functions instead, covering tagged Number multiplication/division, monomorphic
named loads, strict-equality control flow, and a call wrapper that should
refuse once while its numeric callee publishes. No default-on decision passes
if any stable fixture regresses by more than 5% or if the geometric mean
exceeds `1.000x`, matching the JIT gate in [`jit.md`](jit.md) §10.

The graduation 30-pair arm64 sample measured `0.997x` geometric mean, with
`branch_eq` worst at `1.041x`, and installed 0.8 KiB. Both rollout limits pass,
so the production CLI now enables Ohaimark at its natural threshold. The
benchmark command defaults to that production T2 posture; its `--jit` posture
explicitly passes `--no-ohaimark` to isolate T1. Full results, including the
earlier failed samples and same-tree A/B decisions, are recorded in
[`ohaimark.md`](ohaimark.md) §§3.21-3.26.

### Macro fixtures (Octane compute-six)

The vendored Octane workloads live in `bench/macros/*.js` —
whole-program throughput, complementary to the single-mechanism
micros. Each is **self-contained**: a small prelude stands in for
Octane's `base.js` registry, the body is byte-for-byte upstream
(BSD headers retained), and a tail runs a fixed `CYNIC_ITERS` count.
Sized to ~200 ms of work on Cynic's interpreter, except `splay`
(setup-dominated; a GC/allocation macro at the canonical 8000-node
tree). Full provenance, licence, and the per-fixture rationale are in
[`bench/macros/README.md`](../bench/macros/README.md).

They are a **separate set**, not folded into the default micro loop
(Splay alone is seconds, not milliseconds, on the interpreter), and
they run under `--unhardened` (the ES5-era bodies monkey-patch
primordials). Select them with a flag on either harness — both
postures, same as the micros (interpreter-only Lantern + JIT-enabled
Bistromath):

    zig build bench -- --macros              # single-engine, JIT (default)
    zig build bench -- --macros --no-jit     # single-engine, interpreter-only
    tools/bench-cross.sh --macros            # cross-engine, BOTH tiers
                                             # (interp jitless + full-speed)

Adding one: vendor the body into `bench/macros/`, wrap it the same
way (see the README), and append to the `MACROS` array in
`tools/bench.zig`. Cross-engine globs `bench/macros/*.js`
automatically under `--macros`.

## Measurement protocol

For every (suite, subtest, engine) cell:

1. **Warmup pass** — one full run, results discarded.
2. **10 runs** — record each. Single-engine (`tools/bench.zig`)
   and cross-engine (`tools/bench-cross.sh`) use the same sample
   budget so deltas in one artifact are directly relatable to
   deltas in the other.
3. **Report p50** — the average of the two middle samples for the
   even sample count. (The shell median in `bench-cross.sh` picks
   the upper of the two middles — a ≤1-sample bias accepted to
   keep the script pure-shell; well within the 10% noise floor.)
4. **Subprocess isolation** — each run is a fresh shell invocation,
   so cold-start cost is included but doesn't leak across runs.

The 10-sample budget replaced an earlier 5-sample policy after
parallel-agent runs on the dev hardware showed too much
sensitivity to one-off OS-scheduling jitter at N=5 — see the
comment in `tools/bench.zig` at `DEFAULT_RUNS` for the rationale.

### `tools/bench.zig` columns + percentile gating

The single-engine driver reports, per fixture:

- **`p50_ms`** — true median (interpolated on even N).
- **`min_ms` / `max_ms`** — sample extremes.
- **`spread%`** — `(max − min) / p50 × 100`. Dispersion at a
  glance; works at any sample count. A high spread% means the
  fixture's median is noisy this run — investigate before trusting
  a delta.
- **`outliers`** — count of samples above the Tukey fence
  `Q3 + 1.5·IQR`. **Reported, never deleted** — every sample still
  feeds `p50` / `min` / `max`. A non-zero count is a "this run was
  jittery" flag, not a correction.

**Tail percentiles are gated on sample size.** With the default 10
samples, the 95th/99th percentile collapses onto `max` (nearest-
rank index N−1), so printing them would be noise dressed as rigor.
The driver hides them until the budget supports a distinct value:

- **`p95_ms`** appears at **N ≥ 20** (`zig build bench -- --runs=20`).
- **`p99_ms`** appears at **N ≥ 100** (`zig build bench -- --runs=100`).

Raising `--runs` lights up the columns automatically. The default
stays 10 so single-engine and cross-engine numbers share a sample
budget (see above); use a wider budget only when you specifically
want tail-latency resolution.

## Cadence — when to update each results file

The two on-disk artifacts answer different questions and update
at different rhythms:

| File | Question answered | Update trigger |
|---|---|---|
| [`bench-results.md`](../bench-results.md) | "How does Cynic's perf and RSS look right now?" | After every perf-shaped commit (or batch). `/perf` re-runs the suite; append a new row when something moved ≥5%. |
| [`bench-cross-results.md`](../bench-cross-results.md) | "Where does Cynic sit vs production engines?" | After meaningful relative-position changes — when Cynic moves past (or behind) a peer on a fixture, or after a multi-commit perf batch. Not per-commit. |

Skip cross-engine on a routine `/perf` run unless you've changed
something likely to shift the position-vs-peers ranking.
`/checkpoint` runs the cross-engine sweep gated on bench
movement (skipped when nothing moved ≥5%).

### Metrics captured per run

Cross-engine (works for everything jsvu installs):

| Metric | Source |
|---|---|
| Wall clock (ms) | `__perfNow()` deltas inside the script + rusage realtime outside |
| User CPU (ms) | `getrusage(RUSAGE_CHILDREN).ru_utime` after the spawn |
| System CPU (ms) | `ru_stime` after the spawn |
| Peak RSS (KB) | `ru_maxrss` (bytes on macOS, KB on Linux — normalized to KB) |
| Page faults | `ru_minflt + ru_majflt` — early signal for alloc-pressure regressions |

Engine-specific (probed by `bench/prologue.js`):

| Engine | Heap probe | GC trigger |
|---|---|---|
| Cynic | `$bench.heapUsed()` | `$bench.collectGarbage()` |
| Node / V8 | `process.memoryUsage().heapUsed` | `globalThis.gc()` (requires `--expose-gc`) |
| JSC | `gcHeapSize()` | `fullGC()` |
| SpiderMonkey | `gcparam("gcBytes")` | `gc()` |
| QuickJS | n/a | `__qjs_gc()` (build-dependent) |

Cynic-only deep stats (for our regression dashboard, not cross-engine
comparison):

- GC cycles run during the test
- Sum of GC pause times, max GC pause
- Allocations since test start
- Per-pool live-object counts (objects / strings / generators / …)

These come from `realm.heap` counters, exposed via the `$bench` host
builtin installed only when `cynic` is launched via the bench harness.

## Interpreter-tier cross-engine runs

`zig build bench` is single-engine — it tracks Cynic against its own
history. To put Cynic next to other engines on the same fixtures,
`tools/bench-cross.sh` runs the `bench/micros/*.js` suite under every
engine present and prints a comparison table.

**This is an internal regression compass, not a public scoreboard.**
The output never goes to the website or `bench-results.md`. Its only
job is to answer "did a runtime change move Cynic relative to the
field" for the developer running it.

### Interpreter tier only — the hard rule

Comparing a JIT-warm engine against an interpreter measures
nothing useful: the JIT engine wins by an order of magnitude and
the number says only "JIT beats interpreter," which we already
know. So **every engine is run interpreter-tier** — each JIT peer
with its JIT disabled, and Cynic with `--no-jit` (Bistromath has
been on by default since docs/jit.md §12's step-3 exit). A
baseline-tier table (default Cynic vs Sparkplug-class peer
configs) is now unlockable per docs/jit.md §10.6 and gets added
when the wasm/Spasm work settles, not piecemeal:

| Engine | No-JIT invocation | Notes |
|---|---|---|
| V8 (`d8`) | `--jitless` | disables every JIT tier |
| SpiderMonkey (`sm`) | `--no-baseline --no-ion` | disables Baseline + Ion; older builds also take `--no-warp`, jsvu 151.x rejects it |
| JavaScriptCore (`jsc`) | env `JSC_useJIT=0` | a flag-less env toggle |
| QuickJS-NG (`qjs`) | none needed | non-JIT C interpreter |
| Hermes (`hermes`) | none needed | natively interpreter-only |
| XS (`xst`) | none needed | natively interpreter-only |
| Cynic | `--no-jit` | pins Lantern; Bistromath is the default tier since the step-3 exit |

The headline peer is **QuickJS-NG** — a non-JIT C interpreter, the
fairest comparison point for the Lantern tier.

A third comparison — the **baseline-tier table** — is the
recorded idea most relevant to Bistromath itself: pin each big
engine to its *baseline* JIT tier and compare Sparkplug-class to
Sparkplug-class. The peer configs:

| Engine | Baseline-tier invocation | Leaves enabled |
|---|---|---|
| V8 (`d8`) | `--no-opt --no-maglev` | Ignition + Sparkplug |
| SpiderMonkey (`sm`) | `--no-ion` | interpreter + Baseline |
| JavaScriptCore (`jsc`) | env `JSC_useDFGJIT=0 JSC_useFTLJIT=0` | LLInt + Baseline |
| Cynic | default | Lantern + Bistromath |

This answers "is Bistromath in the right ballpark against peer
baselines" rather than against full optimizing stacks. Not wired
into `tools/bench-cross.sh` yet — when it lands it becomes a
`--tier baseline` third section, same never-merge rule.

The full-speed table — Cynic's default posture (Bistromath)
against the peers with their JITs enabled — lives in the same
artifact as a second, separately-headed section
(`tools/bench-cross.sh` runs both tiers by default; `--tier
interp` / `--tier jit` select one). The two are different fairness
baselines answering different questions and are never merged into
one table. One cold-start caveat applies to every per-process
harness here: each sample is a fresh process, so JIT numbers are
"cold start, what a user gets," not steady-state throughput — the
tier warms inside each run.

### Install the engines

```sh
npm i -g jsvu eshost-cli
jsvu --engines=quickjs,v8,spidermonkey,hermes
```

`jsvu` drops pinned binaries into `~/.jsvu/bin/`. QuickJS-NG is the
must-have; the others are nice-to-have. `eshost-cli` is the uniform
shim layer — Cynic + every engine register as eshost hosts via
`bench/eshost-hosts.json` (or `tools/bench-setup-hosts.sh`, which
copies the entries into `~/.eshost-config.json` for plain
`eshost --list` / `eshost <file>` use).

A caveat on eshost: its bundled per-engine *agents* are version-
coupled and drift from the jsvu binaries (the `qjs` agent injects a
`-N` flag QuickJS-NG 0.14 rejects; the `hermes` agent passes
`-fenable-tdz`, dropped in newer Hermes). So `tools/bench-cross.sh`
invokes the engine binaries **directly** with the no-JIT flags above
for reliable wall-clock timing. The eshost config still serves manual
one-off runs and is the one committed place the canonical flag set
lives.

### Running it

```sh
tools/bench-cross.sh            # comparison table to stdout
tools/bench-cross.sh -o x.md    # also write the table to a file
tools/bench-cross.sh --runs 7   # override the timed-run count
```

The runner builds Cynic `ReleaseFast` itself before timing — a Debug
`cynic` is 5-18x slower and would make the comparison meaningless
against the optimized peer binaries.

The runner follows the [measurement protocol](#measurement-protocol)
above: 1 discarded warmup, 5 timed subprocess runs, report the
median, flag (`*`) any fixture whose max-min spread tops 10%. It
**degrades gracefully** — any engine whose binary is absent is
skipped with a note rather than failing the run, so it works against
Cynic alone if no peers are installed.

The table prints to stdout (or the `-o` file). It is deliberately
**not** appended to `bench-results.md` — that file is the
single-engine `zig build bench` artifact and stays that way.

## Output format

`bench-results.md`, dated rows mirroring `test262-results.md`:

```
### 2026-MM-DD — cynic <commit>, jetstream2 <rev>

| suite / subtest      | engine  | wall_ms | user_ms | rss_kb | heap_kb | gc_max_ms |
|---|---:|---:|---:|---:|---:|---:|
| JetStream2/3d-cube   | cynic   |   412.3 |   408.7 |  18432 |   11264 |       3.2 |
| JetStream2/3d-cube   | v8      |    28.1 |    25.9 |  52736 |    8192 |       0.6 |
| JetStream2/3d-cube   | qjs     |   186.4 |   184.2 |   4608 |       — |         — |
```

Δ vs prior row inline. Regression alert when Cynic loses > 5% on
any subtest vs the prior baseline.

## Stability hardening

To make numbers reproducible across runs:

1. Fixed CPU affinity on Linux (`taskset -c 0`).
2. Disable thermal throttling on macOS bench hosts
   (`sudo pmset -a sleep 0 disablesleep 1`).
3. `--gc-threshold` pinned for Cynic across runs.
4. Document the allocator caveat — peak RSS comparisons across
   engines are skewed by allocator choice (libc vs jemalloc).

## Implementation phases

1. **Phase 1** — `tools/bench.zig` + `bench/prologue.js` + the
   `$bench` host builtin. One subtest from JetStream 2 end-to-end
   against Cynic, V8, QuickJS. Validates the protocol.
2. **Phase 2** — Vendor full JetStream 2 + Octane. Full matrix
   captured in `bench-results.md`.
3. **Phase 3** — Cynic-specific micros under `bench/micros/`,
   focused on opcodes / GC / regex / generators.
4. **Phase 4** — CI integration. Gate PRs on >5% regression
   against a recorded baseline.

Phases 1-3 are local-developer-driven; phase 4 needs a stable bench
host (separate from the GitHub-Actions runners, which vary in CPU).

## What's NOT in scope

- DOM benchmarks (Cynic doesn't target browsers).
- JIT-warm comparison. The cross-engine runner
  (`tools/bench-cross.sh`) pins every JIT peer to its no-JIT flags
  AND pins Cynic with `--no-jit` (the tier defaults on since the
  step-3 exit), so the comparison stays interpreter-tier vs
  interpreter-tier. A JIT-warm peer number against Lantern is
  meaningless and is never recorded or published; the
  baseline-tier table (docs/jit.md §10.6) is tracked separately —
  see "Interpreter-tier cross-engine runs" above.
- Microbenchmarking individual opcodes from outside the engine —
  see `src/bytecode/op.zig`'s in-tree perf tests instead.
- Multi-isolate or multi-thread workloads — single-agent-per-isolate
  is the Cynic target (see ROADMAP.md).
