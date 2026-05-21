# test262 conformance score history

## Current scores

|         | spec% | attempted% | pass / total | pass / attempted |
|---|---|---|---|---|
| **parser** | 73.32 % | 100.00 % | 30311 / 41339 | 30311 / 30311 |
| **runtime** | 92.81 % | 99.97 % | 37208 / 40091 | 37208 / 37221 |


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
| **_1–9 fails_** | | | | | |
| `built-ins/RegExp` | 1593 | 9 | 161 | 90 % | 99 % |
| `built-ins/TypedArrayConstructors` | 655 | 1 | 16 | 97 % | 100 % |
| `language/module-code` | 574 | 1 | 14 | 97 % | 100 % |
| `language/statements` | 8407 | 2 | 672 | 93 % | 100 % |
| **_0 fails (passing or wholly OOS)_** | | | | | |
| ~~`built-ins/AbstractModuleSource`~~ | ~~0~~ | ~~0~~ | ~~8~~ | ~~0 %~~ | ~~0 %~~ |
| `built-ins/AggregateError` | 23 | 0 | 0 | 100 % | 100 % |
| `built-ins/Array` | 3035 | 0 | 36 | 99 % | 100 % |
| `built-ins/ArrayBuffer` | 182 | 0 | 4 | 98 % | 100 % |
| `built-ins/ArrayIteratorPrototype` | 19 | 0 | 8 | 70 % | 100 % |
| ~~`built-ins/AsyncDisposableStack`~~ | ~~0~~ | ~~0~~ | ~~103~~ | ~~0 %~~ | ~~0 %~~ |
| `built-ins/AsyncFromSyncIteratorPrototype` | 38 | 0 | 0 | 100 % | 100 % |
| `built-ins/AsyncFunction` | 14 | 0 | 0 | 100 % | 100 % |
| `built-ins/AsyncGeneratorFunction` | 9 | 0 | 0 | 100 % | 100 % |
| `built-ins/AsyncGeneratorPrototype` | 48 | 0 | 0 | 100 % | 100 % |
| `built-ins/AsyncIteratorPrototype` | 4 | 0 | 9 | 31 % | 100 % |
| `built-ins/BigInt` | 76 | 0 | 0 | 100 % | 100 % |
| `built-ins/Boolean` | 49 | 0 | 0 | 100 % | 100 % |
| `built-ins/DataView` | 466 | 0 | 55 | 89 % | 100 % |
| `built-ins/Date` | 583 | 0 | 0 | 100 % | 100 % |
| ~~`built-ins/DisposableStack`~~ | ~~0~~ | ~~0~~ | ~~92~~ | ~~0 %~~ | ~~0 %~~ |
| `built-ins/Error` | 55 | 0 | 0 | 100 % | 100 % |
| `built-ins/FinalizationRegistry` | 46 | 0 | 0 | 100 % | 100 % |
| `built-ins/Function` | 250 | 0 | 10 | 96 % | 100 % |
| `built-ins/GeneratorFunction` | 9 | 0 | 0 | 100 % | 100 % |
| `built-ins/GeneratorPrototype` | 61 | 0 | 0 | 100 % | 100 % |
| `built-ins/Infinity` | 4 | 0 | 2 | 67 % | 100 % |
| `built-ins/Iterator` | 425 | 0 | 6 | 99 % | 100 % |
| `built-ins/JSON` | 143 | 0 | 21 | 87 % | 100 % |
| `built-ins/Map` | 169 | 0 | 1 | 99 % | 100 % |
| `built-ins/MapIteratorPrototype` | 11 | 0 | 0 | 100 % | 100 % |
| `built-ins/Math` | 322 | 0 | 5 | 98 % | 100 % |
| `built-ins/NaN` | 4 | 0 | 2 | 67 % | 100 % |
| `built-ins/NativeErrors` | 88 | 0 | 0 | 100 % | 100 % |
| `built-ins/Number` | 339 | 0 | 0 | 100 % | 100 % |
| `built-ins/Object` | 3319 | 0 | 80 | 98 % | 100 % |
| `built-ins/Promise` | 627 | 0 | 38 | 94 % | 100 % |
| `built-ins/Proxy` | 293 | 0 | 13 | 96 % | 100 % |
| `built-ins/Reflect` | 152 | 0 | 0 | 100 % | 100 % |
| `built-ins/RegExpStringIteratorPrototype` | 17 | 0 | 0 | 100 % | 100 % |
| `built-ins/Set` | 381 | 0 | 1 | 100 % | 100 % |
| `built-ins/SetIteratorPrototype` | 11 | 0 | 0 | 100 % | 100 % |
| `built-ins/String` | 1203 | 0 | 5 | 100 % | 100 % |
| `built-ins/StringIteratorPrototype` | 7 | 0 | 0 | 100 % | 100 % |
| ~~`built-ins/SuppressedError`~~ | ~~0~~ | ~~0~~ | ~~21~~ | ~~0 %~~ | ~~0 %~~ |
| `built-ins/Symbol` | 75 | 0 | 6 | 93 % | 100 % |
| `built-ins/ThrowTypeError` | 13 | 0 | 0 | 100 % | 100 % |
| `built-ins/TypedArray` | 1423 | 0 | 8 | 99 % | 100 % |
| `built-ins/WeakMap` | 101 | 0 | 0 | 100 % | 100 % |
| `built-ins/WeakRef` | 28 | 0 | 0 | 100 % | 100 % |
| `built-ins/WeakSet` | 84 | 0 | 0 | 100 % | 100 % |
| `built-ins/decodeURI` | 55 | 0 | 0 | 100 % | 100 % |
| `built-ins/decodeURIComponent` | 56 | 0 | 0 | 100 % | 100 % |
| `built-ins/encodeURI` | 31 | 0 | 0 | 100 % | 100 % |
| `built-ins/encodeURIComponent` | 31 | 0 | 0 | 100 % | 100 % |
| `built-ins/global` | 9 | 0 | 0 | 100 % | 100 % |
| `built-ins/isFinite` | 15 | 0 | 0 | 100 % | 100 % |
| `built-ins/isNaN` | 15 | 0 | 0 | 100 % | 100 % |
| `built-ins/parseFloat` | 54 | 0 | 0 | 100 % | 100 % |
| `built-ins/parseInt` | 55 | 0 | 0 | 100 % | 100 % |
| `built-ins/undefined` | 4 | 0 | 3 | 57 % | 100 % |
| `language/arguments-object` | 204 | 0 | 57 | 78 % | 100 % |
| `language/asi` | 102 | 0 | 0 | 100 % | 100 % |
| `language/block-scope` | 145 | 0 | 0 | 100 % | 100 % |
| `language/comments` | 22 | 0 | 23 | 49 % | 100 % |
| `language/computed-property-names` | 48 | 0 | 0 | 100 % | 100 % |
| `language/destructuring` | 18 | 0 | 1 | 95 % | 100 % |
| ~~`language/directive-prologue`~~ | ~~0~~ | ~~0~~ | ~~62~~ | ~~0 %~~ | ~~0 %~~ |
| `language/export` | 3 | 0 | 0 | 100 % | 100 % |
| `language/expressions` | 9768 | 0 | 972 | 91 % | 100 % |
| `language/function-code` | 94 | 0 | 109 | 46 % | 100 % |
| `language/future-reserved-words` | 48 | 0 | 7 | 87 % | 100 % |
| `language/global-code` | 36 | 0 | 5 | 88 % | 100 % |
| `language/identifier-resolution` | 9 | 0 | 5 | 64 % | 100 % |
| `language/identifiers` | 268 | 0 | 0 | 100 % | 100 % |
| `language/import` | 4 | 0 | 123 | 3 % | 100 % |
| `language/keywords` | 25 | 0 | 0 | 100 % | 100 % |
| `language/line-terminators` | 32 | 0 | 0 | 100 % | 100 % |
| `language/literals` | 384 | 0 | 97 | 80 % | 100 % |
| `language/punctuators` | 11 | 0 | 0 | 100 % | 100 % |
| `language/reserved-words` | 27 | 0 | 0 | 100 % | 100 % |
| `language/rest-parameters` | 11 | 0 | 0 | 100 % | 100 % |
| `language/source-text` | 1 | 0 | 0 | 100 % | 100 % |
| `language/statementList` | 40 | 0 | 0 | 100 % | 100 % |
| `language/types` | 97 | 0 | 9 | 92 % | 100 % |
| `language/white-space` | 51 | 0 | 0 | 100 % | 100 % |


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
| `joint-iteration` | 54 | 24 | 0 | 69 % | 69 % |
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

### 2026-05-21 — cynic `0ad1d25`, test262 `d0c1b455`

|         | spec% | attempted% | pass / total | pass / attempted | Δ pass | elapsed |
|---|---|---|---|---|---:|---:|
| **runtime** | 92.81 % | 99.97 % | 37208 / 40091 | 37208 / 37221 | +33 | 45.6 s |

### 2026-05-20 — cynic `1708084`, test262 `d0c1b455`

|         | spec% | attempted% | pass / total | pass / attempted | Δ pass | elapsed |
|---|---|---|---|---|---:|---:|
| **runtime** | 92.72 % | 99.87 % | 37175 / 40094 | 37175 / 37223 | +82 |  |

### 2026-05-19 — cynic `b2efa16`, test262 `d0c1b455`

|         | spec% | attempted% | pass / total | pass / attempted | Δ pass | elapsed |
|---|---|---|---|---|---:|---:|
| **runtime** | 92.51 % | 99.64 % | 37093 / 40098 | 37093 / 37227 | +117 |  |

### 2026-05-18 — cynic `debcfcf`, test262 `b1f9a0aea3`

|         | spec% | attempted% | pass / total | pass / attempted | Δ pass | elapsed |
|---|---|---|---|---|---:|---:|
| **runtime** | 92.17 % | 99.28 % | 36976 / 40115 | 36976 / 37244 | +314 |  |

### 2026-05-17 — cynic `400fbae`, test262 `d0c1b455`

|         | spec% | attempted% | pass / total | pass / attempted | Δ pass | elapsed |
|---|---|---|---|---|---:|---:|
| **runtime** | 91.28 % | 98.25 % | 36662 / 40164 | 36662 / 37315 | +786 |  |

### 2026-05-16 — cynic `452bafa`, test262 `d0c1b455`

|         | spec% | attempted% | pass / total | pass / attempted | Δ pass | elapsed |
|---|---|---|---|---|---:|---:|
| **runtime** | 88.78 % | 95.58 % | 35876 / 40411 | 35876 / 37535 | +1004 |  |

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

