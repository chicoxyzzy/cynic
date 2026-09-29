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
`v128.const/load/store`, all eight lane loads/stores, scalar splats,
extract/replace-lane, vector bitwise operations, `v128.any_true`, all integer
`all_true`/`bitmask` reductions, all 12 integer min/max operations, integer
`abs`/`neg` at every lane width, unsigned rounded averages, and `i32x4.add`;
other SIMD instructions still fall back.

| target | native entries | compiled functions | refusals |
|---|---:|---:|---:|
| x86_64-macos (Rosetta) | 122,324 | 4,867 | 1,116 |
| AArch64-macos | 127,891 | 4,841 | 1,142 |

The SIMD foundation added 249 compiled functions on x86_64 and 26 on AArch64
over the reference-parity checkpoint. The bounded AArch64 code-reservation
follow-up adds another 107 compiled functions and 5,226 native entries, with
x86 counts unchanged. Lane memory operations and `any_true` add another 245
compiled functions and 303 native entries on each target, removing 245 SIMD
refusals apiece. The scalar-lane and bitwise follow-up adds 138 compiled
functions and 551 native entries per target, removing another 138 SIMD
refusals apiece. All eight integer reductions add another 46 compiled
functions and 143 native entries per target, removing 46 SIMD refusals
apiece. The 12 integer min/max operations add 108 compiled functions and
276 native entries per target, removing another 108 SIMD refusals apiece.
Integer `abs`/`neg` and unsigned rounded averages add 73 compiled functions
and 229 native entries per target, removing 73 more SIMD refusals apiece.
These are coverage counts, not speedups.

- x86: 8 limits, 0 signatures, 397 bytecode shapes, 711 unsupported opcodes,
  0 emission failures, and 0 installation refusals.
- AArch64: 8 limits, 0 signatures, 335 bytecode shapes, 799 unsupported
  opcodes, 0 emission failures, and 0 installation refusals. Reusing x86's
  module-sized reservation removes all 99 installation refusals from the
  previous fixed 64 KiB arena. Both targets retain the 64 KiB minimum and
  4 MiB cap, charge the entire mapping to a Realm's memory budget, and fall
  back to Sarcasm if reservation or installation is refused.

The x86 vector-signature bucket falls from 1,349 to zero, but many functions
then encounter unsupported instructions: both targets record 640 refusals
at `0xfd`. The largest subopcode groups are `f64x2.min` (244: 18),
`f64x2.max` (245: 18), `i8x16.popcnt` (98: 15), `f32x4.min` (232: 12),
and `v128.load8x8_s` (1: 11).
Counts classify the first refusal per attempted function, not every operation
it contains. Both sweeps also report 7 overflows of the compact per-instance
top-level opcode table; the fixed subopcode counters are tracked separately.

Both backends still refuse native table64 operations while their helpers use
u32 indices, preventing truncation above 2^32. The largest remaining `0xfc` groups are
`table.copy` (22), `table.grow` (5), `table.size` (5), `memory.init` (4),
and `memory.copy` (2).
