# Sarcasm micro-bench history

Wall-time on the WebAssembly interpreter's dispatch-bound
micro-benchmarks. Produced by `zig build wasm-bench` — a dedicated
ReleaseFast harness over two fixed workloads (a tight arithmetic loop
and recursive `fib`, fixed rep counts, checksums asserted) so hot-loop
changes stay measured against a baseline, per
[`docs/wasm-engine.md`](docs/wasm-engine.md) §10.

**Numbers are only stable on a quiet machine, and only comparable
within the same `host` line.** The recorded value is the best `ms/rep`
across at least three manual runs; the spread is noted when it is wide.

Newest run first. Append a fresh section per recorded run; diff a new
run against the previous section with the *same host*.

## History

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
