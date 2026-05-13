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
```

### Suite selection

| Suite | What it measures | Why we run it |
|---|---|---|
| **JetStream 2** | Mixed throughput + latency + startup across 64 subtests | Industry-standard; every major engine team publishes JS2 numbers |
| **Octane** | 15 throughput microbenches (Crypto, Splay, Mandreel, …) | Older but stable; trivially comparable across engines |
| **Custom micros** | Cynic-specific hot paths | Catches regressions in opcodes we own |

Web Tooling Benchmark is **deferred** — it needs Node-style module
resolution, which we don't ship until the module loader lands.

## Measurement protocol

For every (suite, subtest, engine) cell:

1. **Warmup pass** — one full run, results discarded.
2. **5 runs** — record each.
3. **Report median** of the 5; flag if max-min spread > 10%.
4. **Subprocess isolation** — each run is a fresh shell invocation,
   so cold-start cost is included but doesn't leak across runs.

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
- JIT-warm vs cold separation beyond "discard first run" — Cynic has
  no JIT, comparison engines do, and that mismatch is OK to publish.
- Microbenchmarking individual opcodes from outside the engine —
  see `src/bytecode/op.zig`'s in-tree perf tests instead.
- Multi-isolate or multi-thread workloads — single-agent-per-isolate
  is the Cynic target (see ROADMAP.md).
