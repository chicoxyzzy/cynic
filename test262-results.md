# test262 conformance score history

## Current scores

|         | spec% | attempted% | pass / total | pass / attempted |
|---|---|---|---|---|
| **parser** | 73.32 % | 100.00 % | 30311 / 41339 | 30311 / 30311 |
| **runtime** | 86.37 % | 92.93 % | 35202 / 40757 | 35202 / 37880 |


## Where the runtime stands, by area

Bucketed on the first two path components (`built-ins/Set`,
`language/expressions`, …). Grouped into fail-magnitude
tiers (1000+, 100–999, 10–99, 1–9, 0), alphabetical
within each tier — heavy-hitter areas surface at the top,
related siblings stay neighbours so the table is scannable.
Skipped tests are excluded from `pass` and `fail`. Rows
in ~~strikethrough~~ are buckets we skip wholesale (out
of scope per the Cynic-targeted skiplist — Annex B
language extensions, intl402, staging, Temporal,
browser-era built-ins …).

| area | pass | fail | skip | spec% | attempted% |
|---|---:|---:|---:|---:|---:|
| **_100–999 fails_** | | | | | |
| `built-ins/Array` | 2894 | 146 | 36 | 94 % | 95 % |
| `built-ins/Object` | 3150 | 180 | 80 | 92 % | 95 % |
| `built-ins/RegExp` | 1358 | 252 | 161 | 77 % | 84 % |
| `built-ins/TypedArray` | 1276 | 147 | 8 | 89 % | 90 % |
| `built-ins/TypedArrayConstructors` | 554 | 106 | 16 | 82 % | 84 % |
| `language/expressions` | 9388 | 577 | 975 | 86 % | 94 % |
| `language/module-code` | 464 | 118 | 14 | 78 % | 80 % |
| `language/statements` | 8164 | 316 | 672 | 89 % | 96 % |
| **_10–99 fails_** | | | | | |
| `built-ins/ArrayBuffer` | 166 | 25 | 4 | 85 % | 87 % |
| `built-ins/AsyncFromSyncIteratorPrototype` | 12 | 26 | 0 | 32 % | 32 % |
| `built-ins/AsyncGeneratorPrototype` | 37 | 11 | 0 | 77 % | 77 % |
| `built-ins/Date` | 527 | 64 | 0 | 89 % | 89 % |
| `built-ins/Function` | 265 | 57 | 84 | 65 % | 82 % |
| `built-ins/GeneratorPrototype` | 36 | 25 | 0 | 59 % | 59 % |
| `built-ins/Iterator` | 391 | 34 | 6 | 91 % | 92 % |
| `built-ins/JSON` | 115 | 50 | 0 | 70 % | 70 % |
| `built-ins/Map` | 155 | 14 | 1 | 91 % | 92 % |
| `built-ins/Math` | 311 | 16 | 0 | 95 % | 95 % |
| `built-ins/Number` | 327 | 12 | 0 | 96 % | 96 % |
| `built-ins/Promise` | 603 | 25 | 38 | 91 % | 96 % |
| `built-ins/Proxy` | 243 | 55 | 13 | 78 % | 82 % |
| `built-ins/Reflect` | 129 | 24 | 0 | 84 % | 84 % |
| `built-ins/Set` | 347 | 34 | 1 | 91 % | 91 % |
| `built-ins/String` | 1148 | 69 | 5 | 94 % | 94 % |
| `built-ins/Symbol` | 65 | 10 | 6 | 80 % | 87 % |
| `built-ins/WeakMap` | 87 | 14 | 0 | 86 % | 86 % |
| `built-ins/WeakSet` | 74 | 10 | 0 | 88 % | 88 % |
| `built-ins/global` | 17 | 12 | 0 | 59 % | 59 % |
| `language/function-code` | 86 | 22 | 109 | 40 % | 80 % |
| `language/global-code` | 19 | 18 | 5 | 45 % | 51 % |
| `language/identifiers` | 252 | 16 | 0 | 94 % | 94 % |
| `language/literals` | 409 | 28 | 97 | 77 % | 94 % |
| `language/statementList` | 40 | 40 | 0 | 50 % | 50 % |
| `language/white-space` | 51 | 16 | 0 | 76 % | 76 % |
| **_1–9 fails_** | | | | | |
| `built-ins/AggregateError` | 19 | 5 | 0 | 79 % | 79 % |
| `built-ins/ArrayIteratorPrototype` | 12 | 7 | 8 | 44 % | 63 % |
| `built-ins/AsyncFunction` | 11 | 3 | 0 | 79 % | 79 % |
| `built-ins/AsyncGeneratorFunction` | 7 | 2 | 0 | 78 % | 78 % |
| `built-ins/BigInt` | 69 | 7 | 0 | 91 % | 91 % |
| `built-ins/Boolean` | 48 | 2 | 0 | 96 % | 96 % |
| `built-ins/DataView` | 509 | 1 | 11 | 98 % | 100 % |
| `built-ins/Error` | 50 | 7 | 0 | 88 % | 88 % |
| `built-ins/GeneratorFunction` | 7 | 2 | 0 | 78 % | 78 % |
| `built-ins/NativeErrors` | 82 | 6 | 0 | 93 % | 93 % |
| `built-ins/RegExpStringIteratorPrototype` | 9 | 8 | 0 | 53 % | 53 % |
| `built-ins/StringIteratorPrototype` | 2 | 5 | 0 | 29 % | 29 % |
| `built-ins/ThrowTypeError` | 12 | 2 | 0 | 86 % | 86 % |
| `built-ins/decodeURI` | 53 | 2 | 0 | 96 % | 96 % |
| `built-ins/decodeURIComponent` | 55 | 1 | 0 | 98 % | 98 % |
| `built-ins/encodeURI` | 27 | 4 | 0 | 87 % | 87 % |
| `built-ins/encodeURIComponent` | 26 | 5 | 0 | 84 % | 84 % |
| `built-ins/parseInt` | 54 | 1 | 0 | 98 % | 98 % |
| `built-ins/undefined` | 4 | 1 | 3 | 50 % | 80 % |
| `language/arguments-object` | 202 | 4 | 57 | 77 % | 98 % |
| `language/asi` | 100 | 2 | 0 | 98 % | 98 % |
| `language/block-scope` | 140 | 5 | 0 | 97 % | 97 % |
| `language/comments` | 22 | 7 | 23 | 42 % | 76 % |
| `language/computed-property-names` | 45 | 3 | 0 | 94 % | 94 % |
| `language/destructuring` | 16 | 2 | 1 | 84 % | 89 % |
| `language/line-terminators` | 32 | 9 | 0 | 78 % | 78 % |
| `language/types` | 98 | 6 | 9 | 87 % | 94 % |
| **_0 fails (passing or wholly OOS)_** | | | | | |
| ~~`built-ins/AbstractModuleSource`~~ | ~~0~~ | ~~0~~ | ~~8~~ | ~~0 %~~ | ~~0 %~~ |
| ~~`built-ins/AsyncDisposableStack`~~ | ~~0~~ | ~~0~~ | ~~103~~ | ~~0 %~~ | ~~0 %~~ |
| `built-ins/AsyncIteratorPrototype` | 4 | 0 | 9 | 31 % | 100 % |
| ~~`built-ins/DisposableStack`~~ | ~~0~~ | ~~0~~ | ~~92~~ | ~~0 %~~ | ~~0 %~~ |
| `built-ins/FinalizationRegistry` | 46 | 0 | 0 | 100 % | 100 % |
| `built-ins/Infinity` | 4 | 0 | 2 | 67 % | 100 % |
| `built-ins/MapIteratorPrototype` | 11 | 0 | 0 | 100 % | 100 % |
| `built-ins/NaN` | 4 | 0 | 2 | 67 % | 100 % |
| `built-ins/SetIteratorPrototype` | 11 | 0 | 0 | 100 % | 100 % |
| ~~`built-ins/SuppressedError`~~ | ~~0~~ | ~~0~~ | ~~21~~ | ~~0 %~~ | ~~0 %~~ |
| `built-ins/WeakRef` | 28 | 0 | 0 | 100 % | 100 % |
| `built-ins/isFinite` | 15 | 0 | 0 | 100 % | 100 % |
| `built-ins/isNaN` | 15 | 0 | 0 | 100 % | 100 % |
| `built-ins/parseFloat` | 54 | 0 | 0 | 100 % | 100 % |
| ~~`language/directive-prologue`~~ | ~~0~~ | ~~0~~ | ~~62~~ | ~~0 %~~ | ~~0 %~~ |
| `language/export` | 3 | 0 | 0 | 100 % | 100 % |
| `language/future-reserved-words` | 48 | 0 | 7 | 87 % | 100 % |
| `language/identifier-resolution` | 9 | 0 | 5 | 64 % | 100 % |
| `language/import` | 4 | 0 | 123 | 3 % | 100 % |
| `language/keywords` | 25 | 0 | 0 | 100 % | 100 % |
| `language/punctuators` | 11 | 0 | 0 | 100 % | 100 % |
| `language/reserved-words` | 27 | 0 | 0 | 100 % | 100 % |
| `language/rest-parameters` | 11 | 0 | 0 | 100 % | 100 % |
| `language/source-text` | 1 | 0 | 0 | 100 % | 100 % |


## Pre-Stage-4 proposals shipped

Per-feature scores for the TC39 proposals Cynic ships at
Stage 1–3, ahead of their inclusion in the published
edition. **Each row is sourced from a dedicated phase
sweep** that runs only the fixtures whose frontmatter
`features:` list names the proposal, in a realm where only
that proposal's flag is enabled — a `joint-iteration`
fixture is scored here against a realm where
`Map.prototype.getOrInsert` is undefined, and vice versa,
so each row reflects the proposal in honest isolation.
**These fixtures are excluded entirely from the top-line
`## Current scores` and the per-area scoreboard** — they
are not in `total` and not in any bucket, so the headline
number tracks stable ECMA-262 conformance only. When a
proposal advances to Stage 4 the row stays here until its
features ship in mainline ECMA-262.

| feature | pass | fail | skip | spec% | attempted% |
|---|---:|---:|---:|---:|---:|
| `joint-iteration` | 52 | 26 | 0 | 67 % | 67 % |
| `upsert` | 72 | 0 | 0 | 100 % | 100 % |


## Legend

**Rows**

- **parser** — parses the source only. A pass means Cynic's parser accepts or rejects the test as the spec requires. The runtime is never invoked.
- **runtime** — parses, compiles, and executes. A pass means the result matches the test's expectation (no error for positive tests, the right error class for negatives).

**Columns**

- **spec%** — `pass / total`. Coverage of the corpus. Skipped tests are in `total` but never in `pass`, so this rises only when we ship features that unblock previously-skipped tests. Same definition in the rolled-up rows and in the by-area scoreboard.
- **attempted%** — `pass / (pass + fail)`. Of the tests we actually ran, the fraction that passed. Skips drop out. Measures the quality of what's shipped, independent of coverage. Same definition in the rolled-up rows and in the by-area scoreboard; skip-only buckets render as `0 %`.
- **pass / total** — raw counts for `spec%`. `total` is the Cynic-targeted corpus (see below); `skip` is `total - attempted`.
- **pass / attempted** — raw counts for `attempted%`. `attempted = pass + fail`; `fail` is `attempted - pass`. Side-by-side with `pass / total` so a row's two percentages have visible numerators and denominators.
- **Δ pass** (history) — change in `pass` versus the row immediately above (chronologically previous run of the same `mode`).
- **elapsed** (history) — wall-clock time of the run that produced the row. Recorded only for full sweeps (no `--filter`, no `--only-failing`); partial runs leave it blank to keep the regression signal clean. Sub-minute as `12.3 s`, minute+ as `2m 40s`.

**Scope.** `total` excludes paths universally out of scope (`harness/`, `staging/`, `intl402/`), Annex B language extensions, and browser-era built-ins Cynic doesn't ship (`escape` / `unescape`, `String.prototype` HTML wrappers, `Date.{getYear, setYear}`). Fixtures referencing a pre-Stage-4 proposal (see the per-feature table) are *also* excluded from `total` — they don't appear in the rolled-up rows or the per-area scoreboard at all. Each proposal's row in `## Pre-Stage-4 proposals shipped` is sourced from a dedicated phase sweep that runs only the matching fixtures, in a realm where only that one proposal's flag is enabled.

## History

### 2026-05-16 — cynic `c72910f`, test262 `d0c1b455`

|         | spec% | attempted% | pass / total | pass / attempted | Δ pass | elapsed |
|---|---|---|---|---|---:|---:|
| **runtime** | 86.37 % | 92.93 % | 35202 / 40757 | 35202 / 37880 | +330 | 1m 57s |

Biggest movers (runtime):

- `language/expressions` +86
- `built-ins/Object` +62
- `built-ins/Array` +43
- `language/statements` +14
- `built-ins/TypedArrayConstructors` +8

### 2026-05-15 — cynic `2b05c51`, test262 `d0c1b455`

|         | spec% | attempted% | pass / total | pass / attempted | Δ pass | elapsed |
|---|---|---|---|---|---:|---:|
| **parser** | 73.32 % | 100.00 % | 30311 / 41339 | 30311 / 30311 | -167 |  |
| **runtime** | 85.12 % | 91.56 % | 34872 / 40969 | 34872 / 38087 | +1623 |  |

### 2026-05-14 — cynic `aca1903`, test262 `d0c1b455`

|         | spec% | attempted% | pass / total | pass / attempted | Δ pass | elapsed |
|---|---|---|---|---|---:|---:|
| **parser** | 73.44 % | 100.00 % | 30478 / 41501 | 30478 / 30478 | +108 |  |
| **runtime** | 80.12 % | 85.56 % | 33249 / 41501 | 33249 / 38860 | +474 |  |

### 2026-05-13 — cynic `550a57e`, test262 `d0c1b455`

|         | spec% | attempted% | pass / total | pass / attempted | Δ pass | elapsed |
|---|---|---|---|---|---:|---:|
| **parser** | 65.76 % | 100.00 % | 30370 / 46183 | 30370 / 30370 | +964 |  |
| **runtime** | 70.79 % | 85.00 % | 32775 / 46296 | 32775 / 38559 | +1007 |  |

### 2026-05-12 — cynic `6800720`, test262 `d0c1b455`

|         | spec% | attempted% | pass / total | pass / attempted | Δ pass | elapsed |
|---|---|---|---|---|---:|---:|
| **parser** | 63.52 % | 96.48 % | 29406 / 46296 | 29406 / 30479 | +148 |  |
| **runtime** | 68.62 % | 82.38 % | 31768 / 46296 | 31768 / 38563 | +1877 |  |

### 2026-05-11 — cynic `feb8709`, test262 `d0c1b455`

|         | spec% | attempted% | pass / total | pass / attempted | Δ pass | elapsed |
|---|---|---|---|---|---:|---:|
| **parser** | 63.16 % | 96.48 % | 29258 / 46320 | 29258 / 30325 | ±0 |  |
| **runtime** | 64.53 % | 78.37 % | 29891 / 46320 | 29891 / 38141 | +4713 |  |

### 2026-05-10 — cynic `c5c12a0`, test262 `d0c1b455`

|         | spec% | attempted% | pass / total | pass / attempted | Δ pass | elapsed |
|---|---|---|---|---|---:|---:|
| **parser** | 63.16 % | 96.48 % | 29258 / 46320 | 29258 / 30325 | +464 |  |
| **runtime** | 54.36 % | 66.01 % | 25178 / 46320 | 25178 / 38143 | +1265 |  |

### 2026-05-09 — cynic `fcc5543`, test262 `d0c1b455`

|         | spec% | attempted% | pass / total | pass / attempted | Δ pass | elapsed |
|---|---|---|---|---|---:|---:|
| **parser** | 62.11 % | 94.89 % | 28794 / 46357 | 28794 / 30345 | +252 |  |
| **runtime** | 51.58 % | 62.65 % | 23913 / 46357 | 23913 / 38169 | +6048 |  |

### 2026-05-08 — cynic `unknown`, test262 `d0c1b455`

|         | spec% | attempted% | pass / total | pass / attempted | Δ pass | elapsed |
|---|---|---|---|---|---:|---:|
| **parser** | 54.76 % | 95.61 % | 28542 / 52125 | 28542 / 29853 | n/a |  |
| **runtime** | 34.60 % | 46.64 % | 17865 / 51639 | 17865 / 38304 | n/a |  |

