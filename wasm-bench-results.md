# Sarcasm micro-bench history

Wall-time on the WebAssembly interpreter's dispatch-bound
micro-benchmarks. Produced by `zig build wasm-bench` — a dedicated
ReleaseFast harness over three fixed workloads (a tight arithmetic loop,
self-recursive `fib`, and cross-recursive `fib`, fixed rep counts, checksums
asserted) so hot-loop and native-link changes stay measured against a baseline, per
[`docs/wasm-engine.md`](docs/wasm-engine.md) §10.

**Numbers are only stable on a quiet machine, and only comparable
within the same `host` line.** Each section states whether it records the best
`ms/rep` or a range across at least three manual runs.

Newest run first. Append a fresh section per recorded run; diff a new
run against the previous section with the *same host*.

## History

### 2026-08-08, asynchronous Realm wake-byte paired A/B, current worktree, host `Darwin 25.6.0 arm64`

Three ReleaseFast ABBA samples from the final implementation. Each sample runs
`spasm-bare`, `spasm-wake`, `spasm-wake`, `spasm-bare` and keeps the faster
observation per mode, reducing order and thermal bias. `spasm-wake` models the
production Realm posture: an initially clear atomic wake byte is acquire-loaded
at every native entry and taken structured-loop backedge. Checksums matched,
both modes stayed native, and diagnostics reported `helper 0/0` in every row.

The tight loop is flat within noise (`0.963-1.033x`). Entry-heavy recursive
code exposes the expected extra function-entry probe: `1.047-1.079x` for
self-recursion and a noisier `1.036-1.153x` for cross-recursion. This is the
measured correctness/performance tradeoff for interrupts raised after native
entry; the clear path performs no spills and no host call. The configured
remote benchmark host is `Linux x86_64`, while Spasm is AArch64-only, so this
paired A/B cannot be reproduced on that box.

| bench | interpreter ms/rep | Spasm bare ms/rep | Spasm wake ms/rep | wake / bare |
|---|---:|---:|---:|---:|
| loop `sum(i*i)`, n=2,000,000 | 86.25-108.67 | 6.486-6.861 | 6.438-6.803 | 0.963-1.033x |
| `fib(32)` self-recursive | 301.43-342.35 | 30.423-34.480 | 32.822-36.240 | 1.047-1.079x |
| `fib(32)` cross-recursive | 276.46-357.59 | 33.278-39.274 | 35.499-45.268 | 1.036-1.153x |

### 2026-08-08, native Spasm execution safe points, current worktree, host `Darwin 25.6.0 arm64`

Three ReleaseFast samples after adding the optional execution-controller
pointer, function-entry polls, and taken structured-loop backedge polls to
Spasm. Every checksum matched, every Spasm row stayed native, and diagnostics
reported `helper 0`, proving the unmetered path did not tier down.

The host was not suitable for an absolute before/after claim: concurrent Rust
LTO, JavaScriptCore stress runs, and two long-lived Node jobs were consuming
CPU, and the interpreter was 2-3x slower than the quieter 2026-08-07 sample.
Treat this as a native-engagement/correctness gate. The 2026-08-07 section
remains the useful same-host reference for the original null-controller poll;
the newer section above isolates the Realm-backed wake-byte path directly.

**This sample predates the asynchronous Realm wake-byte probe.** It covers the
bare/null-controller path only; no recorded performance evidence yet covers
the acquire-load now used by Realm-backed unmetered calls. The paired section
above supplies that evidence; this older row remains the pre-probe checkpoint.

| bench | interpreter ms/rep | Spasm ms/rep | paired speedup |
|---|---:|---:|---:|
| loop `sum(i*i)`, n=2,000,000 | 147.69-207.95 | 6.93-17.75 | 11.71-26.37x |
| `fib(32)` self-recursive | 367.96-1,367.36 | 43.23-100.57 | 8.51-13.60x |
| `fib(32)` cross-recursive | 429.23-490.33 | 43.11-47.26 | 9.08-11.34x |

### 2026-08-07, Realm metering integration, cynic `6e125807` plus current worktree, host `Darwin 25.6.0 arm64`

Three ReleaseFast samples after wiring Wasm calls into the Realm fuel,
interrupt, and memory controls. Unmetered calls remained eligible for Spasm:
every checksum matched, every Spasm row executed natively, and the timed
diagnostics reported `helper 0`. Metered calls deliberately use Sarcasm so
back-edge polling remains precise. Host load was still noisy, particularly for
cross-recursive interpreter timings, so this is a default-tier engagement gate
rather than evidence of an interpreter speed change.

| bench | interpreter ms/rep | Spasm ms/rep | paired speedup |
|---|---:|---:|---:|
| loop `sum(i*i)`, n=2,000,000 | 56.87-83.37 | 5.34-5.69 | 10.66-14.66x |
| `fib(32)` self-recursive | 179.37-264.22 | 21.91-25.67 | 8.19-10.29x |
| `fib(32)` cross-recursive | 177.10-348.17 | 23.28-37.10 | 7.23-9.38x |

### 2026-08-06, full benchmark refresh, cynic `6e125807`, host `Darwin 25.6.0 arm64`

Four ReleaseFast samples on the unchanged stable-call-gate implementation.
Every interpreter/Spasm checksum matched, every Spasm row executed natively,
and the timed diagnostics reported `helper 0`. The host was unusually noisy:
the interpreter loop had a 2.9x max/min spread and both tiers were slower than
the 2026-07-30 same-host checkpoint despite no intervening changes under
`src/runtime/wasm/` or `tools/wasm_bench.zig`. Treat this as a current
engagement/correctness sample, not evidence of a Wasm performance regression;
retain the quieter 2026-07-30 section as the performance checkpoint.

| bench | interpreter ms/rep | Spasm ms/rep | paired speedup |
|---|---:|---:|---:|
| loop `sum(i*i)`, n=2,000,000 | 68.37–195.93 | 5.35–6.62 | 12.55–29.58x |
| `fib(32)` self-recursive | 216.26–352.30 | 23.97–33.80 | 7.90–10.42x |
| `fib(32)` cross-recursive | 240.16–296.77 | 24.64–29.95 | 9.44–10.12x |

### 2026-07-30, stable same-instance Spasm call gates, host `Darwin 25.6.0 arm64`

Three ReleaseFast samples after adding one stable data gate per defined function.
Generated callers use a shared W^X-installed stub: the cold edge tail-branches
to the existing guarded helper for lazy compilation, while a published target
entry tail-branches directly without a helper lookup or executable-code patch.
The new mutually recursive `fib` fixture keeps every recursive edge
cross-function. Checksums matched on every run.

| bench | interpreter ms/rep | Spasm ms/rep | Spasm / interpreter |
|---|---:|---:|---:|
| loop `sum(i*i)`, n=2,000,000 | 36.86-39.78 | 3.95-4.18 | 9.30-9.52x |
| `fib(32)` self-recursive | 116.53-135.60 | 15.23-16.74 | 7.28-8.90x |
| `fib(32)` cross-recursive | 120.86-149.15 | 16.34-23.36 | 6.38-7.39x |

The timed diagnostic output reported `helper 0` for all three rows. The wider
cross-recursive spread reflects host load; its best sample remains within 8%
of the self-recursive link while exercising the gate on every recursive edge.
The forced-Spasm official testsuite remained `58,779/58,779`, with the existing
`1,232` conversion skips across 222 files.

### 2026-07-30, helper-free self-recursive Spasm calls, host `Darwin 25.6.0 arm64`

Three ReleaseFast samples after linking eligible scalar self-calls with a local
`BL` instead of crossing `spasmCall`, the cache lookup, and `runSpasmEntry` on
every recursive edge. The native entry receives a stack cutoff and preserves it
in x20, so runaway recursion still returns `CallStackExhausted` rather than
overflowing the host stack. Imports, indirect calls, cross-function calls, and
self-calls with declared locals remain on the existing checked helper boundary.
Checksums matched on every run.

| bench | interpreter ms/rep | Spasm ms/rep | Spasm / interpreter |
|---|---:|---:|---:|
| loop `sum(i*i)`, n=2,000,000 | 38.94-45.16 | 4.02-6.78 | 6.66-9.86x |
| `fib(32)` recursive | 121.03-129.06 | 15.54-15.93 | 7.79-8.14x |

The benchmark's opt-in diagnostic output reported `helper 0` for both rows;
the focused recursive regression proves the fib edges use the local link, and
the forced-Spasm official testsuite remained `58,779/58,779`, with the existing
`1,232` harness skips.

### 2026-07-30, native direct Spasm calls with stack-aware boundary, host `Darwin 25.6.0 arm64`

Three ReleaseFast samples after moving same-module direct `call` from
`invoke` re-entry to a native Cell frame. The final path checks the running
thread's native stack before each recursive entry and keeps imports on the
generic invocation boundary. Checksums matched on every run.

| bench | interpreter ms/rep | Spasm ms/rep | Spasm / interpreter |
|---|---:|---:|---:|
| loop `sum(i*i)`, n=2,000,000 | 37.10-43.18 | 3.96-4.39 | 9.37-9.84x |
| `fib(32)` recursive | 118.36-133.78 | 67.93-72.37 | 1.74-1.85x |

Each timed `fib(32)` sample made `56,393,232` nested direct `EntryFn` calls;
the leaf loop made zero. The forced-Spasm official testsuite pass set remained
`58,779/58,779`, with the existing `1,232` harness skips.

### 2026-07-30, pre-direct native calls, cynic `f8c30570` plus current worktree, host `Darwin 25.6.0 arm64`

Three ReleaseFast samples refresh the Sarcasm baseline. Both interpreter and
Spasm checksums matched on every run. The dispatch-bound loop remains a clear
native win; recursive `fib` executes natively but is currently slower under
Spasm, so this is a recorded gap rather than a claimed optimization result.

| bench | interpreter ms/rep | Spasm ms/rep | Spasm / interpreter |
|---|---:|---:|---:|
| loop `sum(i*i)`, n=2,000,000 | 37.99–39.88 | 4.07–4.09 | 9.33–9.76x |
| `fib(32)` recursive | 120.73–123.37 | 221.40–232.62 | 0.53–0.55x |

### 2026-06-10 — cynic `86c048e` (post function-references + multi-memory + ref-local default fix), host `Darwin 25.6.0 arm64`

First recorded baseline for the wasm interpreter.

| bench | best ms/rep | runs | spread |
|---|---:|---:|---|
| loop `sum(i*i)`, n=2,000,000 | 38.82 | 4 | 38.8–41.1 (tight) |
| fib(32) recursive | 116.85 | 4 | 116.9–146.7 (wide — machine load; trust the min) |

Context: measured the same day as the §10 operand-cell-narrowing
experiment (split 64-bit lanes), which this baseline gated — the loop
improved ~5 % but `fib` regressed ~5 %, so the change was declined and
the finding recorded in [`docs/wasm-engine.md`](docs/wasm-engine.md)
§10 (commit `a49385b`). These numbers are the unchanged 128-bit-cell
interpreter.
