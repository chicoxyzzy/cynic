# Sarcasm — WebAssembly spec testsuite results

Scored by `zig build wasm-testsuite` against the official
WebAssembly spec testsuite (the `.wast` corpus, preprocessed with
`wast2json`). Each `assert_*` / `action` command is a plain pass or
fail; commands that need cross-module linking or v128/ref values
Sarcasm does not yet support are counted as skips.

## Current scores

| passing | failing | pass% | skipped | files |
|---|---|---|---|---|
| 54248 | 2232 | 96.05 | 1104 | 157 |
