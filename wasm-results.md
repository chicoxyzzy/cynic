# Sarcasm — WebAssembly spec testsuite results

Scored by `zig build wasm-testsuite -Dwasm-corpus=vendor/wasm-testsuite`
against the official WebAssembly spec testsuite (the `.wast` corpus,
preprocessed with `wast2json --enable-tail-call --enable-relaxed-simd
--enable-memory64 --enable-extended-const`). Each `assert_*` / `action`
command is a plain pass or fail. Commands are counted as skips when they
cannot be scored: `assert_unlinkable` fixtures, text/quoted-module
commands `wast2json` does not lower, a few value comparisons the harness
does not model, and — importantly — **every command whose module uses a
feature Sarcasm does not implement**: that module fails to decode /
validate, so its assertions are *skipped, not failed*.

**What `pass%` does and does not mean.** `pass%` is `100 ×
passing / (passing + failing)` — the fraction of *scored* commands that
pass, **not** "fraction of all of WebAssembly implemented". An
unimplemented standardized proposal (`gc`) sits in the *skip* column,
not *fail*, so the headline stays 100% regardless. Implementing a
proposal moves its assertions **skip → pass** — that, not the
percentage, is the real coverage signal. Exception handling is
implemented but unscored here: this `wast2json` cannot parse the
proposal's `(ref exn)` text syntax, so its `.wast` files don't lower
(its coverage is the engine unit tests instead).

## Current scores

| passing | failing | pass% | skipped | files |
|---|---|---|---|---|
| 56868 | 0 | 100.00 | 1159 | 169 |
