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
Rosetta (2026-10-01). Gating runs add `--require-spasm-entry`; focused target
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
signed/unsigned narrowing, low/high extension, pairwise extended sums,
all 12 extended multiplications, signed halfword dot products, Q15 products,
floating rounding plus pseudo-min/max at both lane widths,
byte shuffle, strict swizzle, relaxed swizzle, all ten standard numeric
conversions, all four relaxed truncations, and the remaining 15 relaxed
operations (multiply-add, lane selection, min/max, Q15, and dot products).
All SIMD memory forms also support explicit memory indices, with the
selected memory's address width and bounds.
Scalar loads/stores and size/grow/fill/copy/init now support indexed memories
on both targets too, including mixed-width copies and aliased imports.
Table64 get/set, grow/size, fill/copy/init, and indirect calls also enter native
code, preserving full-width indices and complete reference values.
Type-indexed blocks, loop/if parameters, and multi-value branch merges now
compile on both targets, as do terminating if arms and catchable unreachable.
Function-label branches now reuse the return path for all three branch
instructions, with zero or multiple results. AArch64 branch tables also
compile beyond the 12-bit comparison-immediate range.
Typed `call_ref` also compiles on both targets, preserving complete
references, foreign instances, live values, and memory views across the
checked invocation boundary. Native tests cover traps, exception payloads,
host GC, cancellation, recursion limits, and incompatible host call layouts.
All three tail-call forms now compile on both targets through a bounded
runtime transfer protocol. Native callers return before their targets enter;
the driver reuses a Cell frame instead of growing the host stack. Native-entry
tests cover deep recursion, foreign instances, host callbacks, exceptions,
GC, allocation failure, and cancellation. This still uses helper-mediated
dispatch, not a native-register tail-jump ABI.

The interpreter and forced-Spasm sweeps also reproduce this score in
`ReleaseSafe` on both targets, under the same 600-second / 3-GB guards.
That validation caught a pre-existing branch-metadata underflow: unreachable
stacks now skip metadata arithmetic, and missing carried operands are rejected
before subtraction. The harness releases action scratch after each assertion
instead of retaining interpreter stacks for a whole manifest, and releases
its copied command-line options at shutdown. Focused regressions cover both
the validator guard and bounded scratch retention.

| target | native entries | compiled functions | refusals |
|---|---:|---:|---:|
| x86_64-macos (Rosetta) | 10,883,548 | 6,007 | 27 |
| AArch64-macos | 10,888,667 | 6,007 | 27 |

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
Extended multiplication, dot products, and Q15 multiplication add 14 compiled
functions and 366 native entries per target, removing 14 more SIMD refusals.
The interpreter's dot-product sum now wraps instead of panicking with safety
checks enabled when both signed-minimum products sum to 2^31.
Floating rounding and pseudo-min/max add 12 compiled functions and 8,096
native entries per target, removing 12 more SIMD refusals. Shared rounding
also quiets signaling NaNs explicitly, fixing an x86 interpreter/helper gap.
Byte shuffle and strict/relaxed swizzle add 20 compiled functions and 41
native entries per target, removing another 20 SIMD refusals. Both targets
zero invalid swizzle indices; x86 retains the SSE2 baseline without helpers.
Standard numeric conversions and relaxed truncations add 17 compiled
functions and 320 native entries per target, removing 17 more SIMD refusals.
Relaxed truncation uses deterministic saturation, matching the interpreter.
The remaining relaxed operations add 31 compiled functions and 64 native
entries per target, removing the last 31 SIMD refusals in this corpus.
Multiply-add is unfused; dot products saturate signed i16 pair sums before
wrapping i32 accumulation. The latter also fixes an interpreter overflow
panic when safety checks are enabled.
Scalar multi-memory adds 218 compiled functions and 703 native entries per
target, removing 216 first refusals apiece. Loads/stores share SIMD's indexed
decoder and view helpers; fill/copy keep their bounded execution polls.
Growth refreshes memory zero even when a nonzero imported index aliases it,
and both tiers copy aliased imports in the overlap-safe direction.
Table64 adds 46 compiled functions and 141 native entries per target,
removing 45 first refusals apiece. The helper ABI retains u64 indices through
bounds checks, and mixed-width table.copy validation uses the narrower count.
Type-indexed multi-value control flow and terminating-arm parity add 97
compiled functions / 605 native entries on x86, and 122 compiled functions /
149 native entries on AArch64. First refusals fall by 95 and 120 respectively.
Function-label branches add 30 compiled functions / 52 native entries on
x86; together with large branch-table support, they add 31 compiled
functions / 60 native entries on AArch64. First refusals fall by 30 and 31.
Typed reference calls add 9 compiled functions and 22,452 native entries
per target, removing all 7 first refusals at `call_ref` in this corpus.
Native tail calls add 100 compiled functions and 10,714,763 native entries
per target, removing all 56 first refusals at the three tail-call opcodes.
Call-heavy modules use 50% code-estimate headroom for the new completion
checks, retaining the 64 KiB minimum, 4 MiB cap, and full Realm memory charge.
These are coverage counts, not speedups.

- x86: 8 limits, 0 signatures, 10 bytecode shapes, 9 unsupported opcodes,
  0 emission failures, and 0 installation refusals.
- AArch64: 8 limits, 0 signatures, 10 bytecode shapes, 9 unsupported
  opcodes, 0 emission failures, and 0 installation refusals. Reusing x86's
  module-sized reservation removes all 99 installation refusals from the
  previous fixed 64 KiB arena. Both targets retain the 64 KiB minimum and
  4 MiB cap, charge the entire mapping to a Realm's memory budget, and fall
  back to Sarcasm if reservation or installation is refused.

The x86 vector-signature bucket falls from 1,349 to zero. Neither target
now records a refusal at `0xfd` in this corpus.
Counts classify the first refusal per attempted function, not every operation
it contains. Neither sweep now overflows the compact per-instance top-level
opcode table; the fixed subopcode counters are tracked separately.

The source inventory accounts for all 256 SIMD opcodes accepted by the
validator: all 256 have lowering paths on both targets.
This is an opcode count, not the first-refusal-per-function count above.
An independent catalogue requires native entry for each accepted opcode,
unreachable immediates, and 128-/1,024-operation bodies, including unpadded
unary chains. It exposed five x86 installation refusals (byte popcount and
the four f32 rounding operations); compact immediates address their excess
code size without raising the reservation. Separate tests cover all 22
memory forms with explicit indices, mixed memory32/memory64 widths,
imported memories, growth, and exact-width bounds. Unrelated unsupported
instructions, control shapes, and resource ceilings still permit fallback.

Neither backend now records a `0xfc` refusal in this corpus. Focused table64
tests require native entry for all eight helper paths, imported/defined
tables, mixed-width copies, aliased overlap, high indices/counts, growth
failure, full references, cross-instance calls, and host-callback GC.
The leading remaining opcode refusals are `return_call_indirect` (21),
`return_call` (18), `return_call_ref` (17), and `br_on_non_null` (4), with
the same counts on both targets. Unsupported bytecode shapes and the eight
intentional resource limits also remain.
