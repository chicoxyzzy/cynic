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
Rosetta (2026-09-29). Gating runs add `--require-spasm-entry`; focused target
tests additionally require generated x86 instance/cache, trap, safe-point,
self-link, and stable-gate execution. Unsupported x86 opcode families fall
back per function and therefore remain covered by the same semantic sweep.
The SIMD foundation preserves full `v128` values across calls, locals/globals,
select, and single-result merges on both targets. Both compile
`v128.const/load/store` and `i32x4.add`; other SIMD instructions still fall back.

| target | native entries | compiled functions | refusals |
|---|---:|---:|---:|
| x86_64-macos (Rosetta) | 120,822 | 4,257 | 1,726 |
| AArch64-macos | 121,163 | 4,124 | 1,851 |

Compared with the reference-parity checkpoint, this adds 249 compiled
functions on x86_64 and 26 on AArch64. These are coverage counts, not speedups.

- x86: 8 limits, 0 signatures, 397 bytecode shapes, 1,321 unsupported opcodes,
  0 emission failures, and 0 installation refusals.
- AArch64: 8 limits, 0 signatures, 335 bytecode shapes, 1,409 unsupported
  opcodes, 0 emission failures, and 99 installation refusals. Diagnostics now
  cover this backend too. The installation refusals exhaust its existing
  fixed 64 KiB native-code arena; they safely fall back to Sarcasm. Its
  reservation policy is unchanged by this milestone.

The x86 vector-signature bucket falls from 1,349 to zero, but many functions
then encounter unsupported instructions: both targets record 1,250 refusals
at `0xfd`. The largest subopcode groups are `v128.load8_lane` (84: 48),
`v128.store8_lane` (88: 48), `v128.load16_lane` (85: 32),
`v128.store16_lane` (89: 32), and `v128.any_true` (83: 21).
Counts classify the first refusal per attempted function, not every operation
it contains. Both sweeps also report 7 overflows of the compact per-instance
top-level opcode table; the fixed subopcode counters are tracked separately.

Both backends still refuse native table64 operations while their helpers use
u32 indices, preventing truncation above 2^32. The largest remaining `0xfc` groups are
`table.copy` (22), `table.grow` (5), `table.size` (5), `memory.init` (4),
and `memory.copy` (2).
