# Sarcasm — WebAssembly spec testsuite results

Scored by `zig build wasm-testsuite` against the official
WebAssembly spec testsuite (the `.wast` corpus, preprocessed with
`wast2json`). Each `assert_*` / `action` command is a plain pass or
fail. A small residue is counted as skips: `assert_unlinkable`
fixtures, text/quoted-module commands `wast2json` does not lower to a
binary, and a handful of value comparisons the harness does not model.

## Current scores

| passing | failing | pass% | skipped | files |
|---|---|---|---|---|
| 56510 | 0 | 100.00 | 1056 | 157 |
