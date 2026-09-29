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

The corpus harness checks scalar and vector NaN expectations by their bits:
`nan:canonical` allows only the quiet bit in the payload; `nan:arithmetic`
requires that bit and allows any remaining payload. Either sign is valid.
Numeric expectations remain bit-exact, including signaling NaNs and signed
zeros. The score below is unchanged under these stricter checks.

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
`v128.const/load/store`, all six signed/unsigned widening loads, all four
memory splats, both zero loads, all eight lane loads/stores, scalar splats,
extract/replace-lane, vector bitwise operations, `v128.any_true`, all integer
`all_true`/`bitmask` reductions, all 12 integer min/max operations, integer
`abs`/`neg` at every lane width, unsigned rounded averages, floating-point
min/max at both lane widths, all 48 integer/floating comparisons, wrapping
integer add/sub/mul, 8/16-bit saturating add/sub, all integer shifts, byte popcount,
floating `abs/neg/sqrt/add/sub/mul/div` at both lane widths, and all
signed/unsigned narrowing, low/high extension, and pairwise extended sums;
other SIMD instructions still fall back.

| target | native entries | compiled functions | refusals |
|---|---:|---:|---:|
| x86_64-macos (Rosetta) | 135,945 | 5,413 | 570 |
| AArch64-macos | 141,512 | 5,387 | 596 |

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
Floating-point min/max adds 58 compiled functions and 1,518 native entries
per target, removing another 58 SIMD refusals apiece.
The six widening loads add 66 compiled functions and 84 native entries per
target, removing another 66 SIMD refusals apiece.
Memory splats/zero loads and all comparisons add 181 compiled functions and
6,767 native entries per target, removing another 181 SIMD refusals apiece.
Integer arithmetic, saturation, shifts, and byte popcount add 138 compiled
functions and 1,209 native entries per target, removing 138 more SIMD refusals.
Floating arithmetic, square roots, and abs/neg add 67 compiled functions and
3,663 native entries per target, removing another 67 SIMD refusals apiece.
Narrowing, extension, and pairwise extended sums add 36 compiled functions
and 380 native entries per target, removing another 36 SIMD refusals apiece.
These are coverage counts, not speedups.

- x86: 8 limits, 0 signatures, 397 bytecode shapes, 165 unsupported opcodes,
  0 emission failures, and 0 installation refusals.
- AArch64: 8 limits, 0 signatures, 335 bytecode shapes, 253 unsupported
  opcodes, 0 emission failures, and 0 installation refusals. Reusing x86's
  module-sized reservation removes all 99 installation refusals from the
  previous fixed 64 KiB arena. Both targets retain the 64 KiB minimum and
  4 MiB cap, charge the entire mapping to a Realm's memory budget, and fall
  back to Sarcasm if reservation or installation is refused.

The x86 vector-signature bucket falls from 1,349 to zero, but many functions
then encounter unsupported instructions: both targets record 94 refusals
at `0xfd`. The largest reported subopcode groups are `i8x16.shuffle` (13: 11),
`i8x16.swizzle` (14: 7), `f32x4.convert_i32x4_s` (250: 4),
`i32x4.trunc_sat_f32x4_s` (248: 3), and `f32x4.convert_i32x4_u` (251: 3).
Counts classify the first refusal per attempted function, not every operation
it contains. Both sweeps also report 7 overflows of the compact per-instance
top-level opcode table; the fixed subopcode counters are tracked separately.

The source inventory accounts for all 256 SIMD opcodes accepted by the
validator: 198 have lowering paths on both targets; 58 still need them.
This is an opcode count, not the first-refusal-per-function count above.
Existing nonzero-memory and control-shape fallback restrictions still apply.

| Remaining family | Opcodes |
|---|---:|
| Shuffle / swizzle | 2 |
| Extended multiply / dot / Q15 | 14 |
| Floating rounding / pseudo-min/max | 12 |
| Conversions | 10 |
| Relaxed SIMD | 20 |

Both backends still refuse native table64 operations while their helpers use
u32 indices, preventing truncation above 2^32. The largest remaining `0xfc` groups are
`table.copy` (22), `table.grow` (5), `table.size` (5), `memory.init` (4),
and `memory.copy` (2).
