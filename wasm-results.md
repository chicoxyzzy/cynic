# Sarcasm — WebAssembly spec testsuite results

Scored by `zig build wasm-testsuite` against the official
WebAssembly spec testsuite (the `.wast` corpus, preprocessed with
`wast2json`). Each `assert_*` / `action` command is a plain pass or
fail. Commands are counted as skips when they cannot be scored:
`assert_unlinkable` fixtures, text/quoted-module commands `wast2json`
does not lower to a binary, a handful of value comparisons the harness
does not model, and — importantly — **every command whose module uses a
feature Sarcasm does not implement**: that module fails to decode /
validate, so its assertions are *skipped, not failed*.

**What `pass%` does and does not mean.** `pass%` is `100 ×
passing / (passing + failing)` — the fraction of *scored* commands that
pass. It is **not** "fraction of all of WebAssembly implemented": an
unimplemented standardized (Phase-5) proposal — currently `gc` (WasmGC)
— sits in the *skip* column, not the *fail* column, so the headline
stays 100% regardless of how many features are missing. Implementing a
proposal moves its assertions from **skip → pass** (the `passing` count
grows, `skipped` shrinks) — that, not the percentage, is the real
measure of coverage. The corpus vendored under `vendor/wasm-testsuite`
includes the proposal tests; the `files` column is how many were
successfully lowered + run, not the full set. (The scoreboard below has
not been regenerated since `exceptions` landed, so its skip count still
reflects the pre-exceptions corpus.)

## Current scores

| passing | failing | pass% | skipped | files |
|---|---|---|---|---|
| 56510 | 0 | 100.00 | 1056 | 157 |
