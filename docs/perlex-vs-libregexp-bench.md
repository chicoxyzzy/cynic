# Perlex vs libregexp — benchmark history

The replacement-gate numbers for retiring the vendored QuickJS-NG
**libregexp** in favour of Cynic's native regex engine, **Perlex**.
Both engines are linked into one binary and timed on identical
`(pattern, UTF-16 input)` pairs, so this is an apples-to-apples
in-process comparison — not a cross-process shell race.

Reproduce:

    zig build bench-regex                 # speed: Perlex vs libregexp, compile + exec
    ./zig-out/bin/cynic-test262 --quiet --filter=RegExp \
      --mem-summary --top-rss=10 --top-alloc=8   # RSS / allocation footprint

`bench-regex` reports the median ns/iter over 32 batches (~200µs
each), monotonic timer, ReleaseFast. Ratios are
`libregexp / Perlex` for both compile and exec — **>1.0 means Perlex
is faster**. `agree` cross-checks that both engines return the same
match (a correctness gate alongside the timing).

Memory is read from the test262 harness's engine-side counters
(`--mem-summary`), not RSS-only — RSS includes binary + libc +
allocator slack. Since the corpus reaches libregexp on neither the
runtime nor the parse path (the fall-through census is 0; see the
`-Dperlex-only` guard in AGENTS.md), these are also the *post-removal*
runtime numbers: libregexp contributes nothing at runtime today.

Newest run first.

## 2026-06-01 — cynic `5090791`, Zig 0.17.0-dev.305

Speed verdict: **Perlex is faster on every case, compile and exec**,
and agrees with libregexp on all 23. Memory: bounded, healthy GC.

### Speed — compile + exec (median ns/iter)

| Category | Case | Cynic compile | libregexp compile | compile × | Cynic exec | libregexp exec | exec × | agree |
|---|---|--:|--:|--:|--:|--:|--:|:--:|
| common | literal-hit | 794.2 ns | 1.21 µs | 1.52× | 277.1 ns | 674.5 ns | 2.43× | yes |
| common | literal-miss | 291.1 ns | 479.1 ns | 1.65× | 471.7 ns | 1.58 µs | 3.35× | yes |
| common | email | 954.5 ns | 3.47 µs | 3.63× | 526.0 ns | 2.77 µs | 5.27× | yes |
| common | url | 615.1 ns | 1.56 µs | 2.54× | 311.9 ns | 792.6 ns | 2.54× | yes |
| common | iso-date | 837.4 ns | 1.30 µs | 1.55× | 244.2 ns | 1.04 µs | 4.25× | yes |
| common | first-word | 283.9 ns | 659.5 ns | 2.32× | 162.3 ns | 388.9 ns | 2.40× | yes |
| common | integers | 253.1 ns | 493.0 ns | 1.95× | 196.6 ns | 576.3 ns | 2.93× | yes |
| common | lower-run | 275.3 ns | 514.4 ns | 1.87× | 86.5 ns | 196.9 ns | 2.28× | yes |
| common | anchored-num | 289.0 ns | 525.3 ns | 1.82× | 217.0 ns | 346.3 ns | 1.60× | yes |
| common | alternation | 575.5 ns | 773.8 ns | 1.34× | 357.0 ns | 1.64 µs | 4.59× | yes |
| common | ci-word | 220.2 ns | 418.1 ns | 1.90× | 96.5 ns | 222.7 ns | 2.31× | yes |
| common | multiline-anchor | 200.1 ns | 394.7 ns | 1.97× | 134.9 ns | 422.0 ns | 3.13× | yes |
| common | backref-dup | 614.1 ns | 1.28 µs | 2.08× | 95.0 ns | 246.3 ns | 2.59× | yes |
| common | lookahead-px | 391.4 ns | 556.2 ns | 1.42× | 147.5 ns | 516.0 ns | 3.50× | yes |
| common | prop-letter | 6.59 µs | 20.66 µs | 3.14× | 92.6 ns | 304.1 ns | 3.28× | yes |
| common | emoji-class | 284.1 ns | 545.9 ns | 1.92× | 152.9 ns | 517.7 ns | 3.39× | yes |
| worst | nested-quant | 366.4 ns | 634.3 ns | 1.73× | 1.32 ms | 4.34 ms | 3.30× | yes |
| worst | alt-overlap | 325.3 ns | 553.1 ns | 1.70× | 2.66 ms | 8.76 ms | 3.29× | yes |
| worst | scan-miss-64k | 237.3 ns | 437.1 ns | 1.84× | 434.90 µs | 1.67 ms | 3.84× | yes |
| worst | class-scan-64k | 367.2 ns | 543.0 ns | 1.48× | 526.90 µs | 2.92 ms | 5.54× | yes |
| worst | restart-heavy | 301.2 ns | 471.3 ns | 1.56× | 533.98 µs | 1.88 ms | 3.53× | yes |
| worst | big-bound-exact | 232.5 ns | 551.4 ns | 2.37× | 9.02 µs | 31.73 µs | 3.52× | yes |
| worst | big-bound-range | 325.4 ns | 557.3 ns | 1.71× | 36.13 µs | 78.82 µs | 2.18× | yes |

Geomean (Perlex-owned cases):

| Metric | Perlex speedup |
|---|--:|
| compile (all) | **1.90×** |
| exec (common) | **2.98×** |
| exec (worst-case) | **3.49×** |

### Memory — RegExp bucket, `--mem-summary` (single-threaded)

Engine-side counters across 1693 fixtures with engine activity (of
1896 total in the bucket); 0 fail, 0 false-reject, 0 false-accept.

| Metric | Value |
|---|--:|
| max per-fixture charged peak | 42 MiB |
| avg bytes / fixture | 5.6 MiB |
| cumulative bytes allocated | 9407 MiB |
| GC cycles | 27 |
| total GC pause | 25 ms (avg 956 µs) |

Heaviest fixtures by process-RSS delta (≥ 8 MB) — these are inherent
whole-Unicode set-construction tests (negated shorthand / property
escape over the entire code-point space), engine-agnostic, not a
Perlex pathology:

| RSS delta | Fixture |
|--:|---|
| 199 MB | `built-ins/RegExp/character-class-escape-non-whitespace.js` |
| 103 MB | `CharacterClassEscapes/character-class-non-word-class-escape-positive-cases.js` |
| 100 MB | `CharacterClassEscapes/character-class-non-whitespace-class-escape-positive-cases.js` |
| 48 MB | `property-escapes/generated/General_Category_-_Nonspacing_Mark.js` |
| 40 MB | `property-escapes/generated/General_Category_-_Other.js` |
| 38 MB | `property-escapes/generated/Script_Extensions_-_Zanabazar_Square.js` |
| 37 MB | `CharacterClassEscapes/character-class-digit-class-escape-negative-cases.js` |
| 30 MB | `property-escapes/generated/Emoji_Modifier.js` |
| 26 MB | `property-escapes/generated/XID_Start.js` |
| 23 MB | `property-escapes/generated/General_Category_-_Private_Use.js` |

### Source / binary footprint (removal impact)

| Item | Now | After libregexp removal (#42) |
|---|--:|---|
| `cynic` binary | 12 MB | smaller (libregexp object dropped) |
| `vendor/quickjs/libregexp.c` | 2610 lines | removed |
| `vendor/quickjs/libunicode.c` | 1746 lines | **kept** (Perlex case folding) |

Runtime speed / RSS are unaffected by removal — Perlex already does
all the work; libregexp is dead weight at runtime (census 0).
