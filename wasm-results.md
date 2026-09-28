# Sarcasm — WebAssembly spec testsuite results

Scored by `zig build wasm-testsuite -Dwasm-corpus=vendor/wasm-testsuite`
against the official WebAssembly spec testsuite (the `.wast` corpus,
preprocessed with `wast2json --enable-tail-call --enable-relaxed-simd
--enable-memory64 --enable-extended-const --enable-multi-memory
--enable-function-references`). Each `assert_*` / `action`
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
| 58779 | 0 | 100.00 | 1232 | 222 |

The forced-Spasm differential posture (`--spasm`) produces this exact score on
both qualified code-generation targets: native AArch64 and x86_64-macos under
Rosetta (2026-09-28). Gating runs add `--require-spasm-entry`; focused target
tests additionally require generated x86 instance/cache, trap, safe-point,
self-link, and stable-gate execution. Unsupported x86 opcode families fall
back per function and therefore remain covered by the same semantic sweep.
The fail-closed witness observed 120,469 native entries / 4,001 compiled
functions on x86_64 and 53,747 / 3,646 on AArch64. The x86 sweep recorded
1,978 transactional refusals (8 limits, 1,349 signatures, 473 bytecode shapes,
148 opcodes) and zero emission or install failures. The x86 backend now covers
memory32 and memory64 scalar access/grow/bulk-memory, `data.drop`, nested
`return`, catchable `unreachable`, and full-width reference parameters,
results, locals, typed select, calls, and single-result control-flow merges.
The reference increment adds 31 compiled functions and 138 native entries,
reducing refusals by 22. It also refuses table64 operations whose native
helpers still use u32 indices, preventing truncation above 2^32; this safety
check intentionally moves previously compiled bodies back to Sarcasm.
Before it, the 1,401 signature refusals split into 52 reference and 1,349
vector cases; afterward all 1,349 are vector cases.
These counts classify the first rejected type in each function, not every
type it contains. The largest remaining `0xfc` groups are
`table.copy` (22), `table.grow` (5), `table.size` (5), `memory.init` (4),
and `memory.copy` (2).
