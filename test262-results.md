# test262 conformance score history

## Current scores

|         | spec% | attempted% | pass / total | pass / attempted |
|---|---|---|---|---|
| **parser** | 73.32 % | 100.00 % | 30311 / 41339 | 30311 / 30311 |
| **runtime** | 85.12 % | 91.56 % | 34872 / 40969 | 34872 / 38088 |


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
| `built-ins/Array` | 2850 | 190 | 36 | 93 % | 94 % |
| `built-ins/Function` | 265 | 103 | 84 | 59 % | 72 % |
| `built-ins/Object` | 3088 | 242 | 80 | 91 % | 93 % |
| `built-ins/RegExp` | 1349 | 261 | 161 | 76 % | 84 % |
| `built-ins/String` | 1045 | 172 | 5 | 86 % | 86 % |
| `built-ins/TypedArray` | 1273 | 150 | 8 | 89 % | 89 % |
| `built-ins/TypedArrayConstructors` | 534 | 126 | 16 | 79 % | 81 % |
| `language/expressions` | 9298 | 671 | 979 | 85 % | 93 % |
| `language/module-code` | 462 | 120 | 14 | 78 % | 79 % |
| `language/statements` | 8149 | 339 | 672 | 89 % | 96 % |
| **_10–99 fails_** | | | | | |
| `built-ins/ArrayBuffer` | 165 | 26 | 4 | 85 % | 86 % |
| `built-ins/AsyncFromSyncIteratorPrototype` | 11 | 27 | 0 | 29 % | 29 % |
| `built-ins/AsyncGeneratorPrototype` | 22 | 26 | 0 | 46 % | 46 % |
| `built-ins/BigInt` | 50 | 26 | 0 | 66 % | 66 % |
| `built-ins/Date` | 526 | 65 | 0 | 89 % | 89 % |
| `built-ins/GeneratorPrototype` | 36 | 25 | 0 | 59 % | 59 % |
| `built-ins/Iterator` | 443 | 60 | 6 | 87 % | 88 % |
| `built-ins/JSON` | 115 | 50 | 0 | 70 % | 70 % |
| `built-ins/Map` | 179 | 23 | 1 | 88 % | 89 % |
| `built-ins/Math` | 311 | 16 | 0 | 95 % | 95 % |
| `built-ins/Number` | 318 | 21 | 0 | 94 % | 94 % |
| `built-ins/Promise` | 603 | 25 | 38 | 91 % | 96 % |
| `built-ins/Proxy` | 214 | 84 | 13 | 69 % | 72 % |
| `built-ins/Reflect` | 120 | 33 | 0 | 78 % | 78 % |
| `built-ins/Set` | 347 | 34 | 1 | 91 % | 91 % |
| `built-ins/Symbol` | 65 | 10 | 6 | 80 % | 87 % |
| `built-ins/WeakMap` | 124 | 16 | 0 | 89 % | 89 % |
| `built-ins/WeakSet` | 74 | 10 | 0 | 88 % | 88 % |
| `built-ins/global` | 17 | 12 | 0 | 59 % | 59 % |
| `language/function-code` | 86 | 22 | 109 | 40 % | 80 % |
| `language/global-code` | 19 | 18 | 5 | 45 % | 51 % |
| `language/identifiers` | 252 | 16 | 0 | 94 % | 94 % |
| `language/line-terminators` | 29 | 12 | 0 | 71 % | 71 % |
| `language/literals` | 409 | 28 | 97 | 77 % | 94 % |
| `language/statementList` | 40 | 40 | 0 | 50 % | 50 % |
| `language/white-space` | 51 | 16 | 0 | 76 % | 76 % |
| **_1–9 fails_** | | | | | |
| `built-ins/AggregateError` | 19 | 5 | 0 | 79 % | 79 % |
| `built-ins/ArrayIteratorPrototype` | 12 | 7 | 8 | 44 % | 63 % |
| `built-ins/AsyncFunction` | 11 | 3 | 0 | 79 % | 79 % |
| `built-ins/AsyncGeneratorFunction` | 7 | 2 | 0 | 78 % | 78 % |
| `built-ins/Boolean` | 47 | 3 | 0 | 94 % | 94 % |
| `built-ins/DataView` | 506 | 4 | 11 | 97 % | 99 % |
| `built-ins/Error` | 50 | 7 | 0 | 88 % | 88 % |
| `built-ins/FinalizationRegistry` | 45 | 1 | 0 | 98 % | 98 % |
| `built-ins/GeneratorFunction` | 7 | 2 | 0 | 78 % | 78 % |
| `built-ins/NativeErrors` | 82 | 6 | 0 | 93 % | 93 % |
| `built-ins/RegExpStringIteratorPrototype` | 9 | 8 | 0 | 53 % | 53 % |
| `built-ins/StringIteratorPrototype` | 2 | 5 | 0 | 29 % | 29 % |
| `built-ins/ThrowTypeError` | 12 | 2 | 0 | 86 % | 86 % |
| `built-ins/WeakRef` | 27 | 1 | 0 | 96 % | 96 % |
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
| `language/rest-parameters` | 10 | 1 | 0 | 91 % | 91 % |
| `language/source-text` | 0 | 1 | 0 | 0 % | 0 % |
| `language/types` | 98 | 6 | 9 | 87 % | 94 % |
| **_0 fails (passing or wholly OOS)_** | | | | | |
| ~~`built-ins/AbstractModuleSource`~~ | ~~0~~ | ~~0~~ | ~~8~~ | ~~0 %~~ | ~~0 %~~ |
| ~~`built-ins/AsyncDisposableStack`~~ | ~~0~~ | ~~0~~ | ~~103~~ | ~~0 %~~ | ~~0 %~~ |
| `built-ins/AsyncIteratorPrototype` | 4 | 0 | 9 | 31 % | 100 % |
| ~~`built-ins/DisposableStack`~~ | ~~0~~ | ~~0~~ | ~~92~~ | ~~0 %~~ | ~~0 %~~ |
| `built-ins/Infinity` | 4 | 0 | 2 | 67 % | 100 % |
| `built-ins/MapIteratorPrototype` | 11 | 0 | 0 | 100 % | 100 % |
| `built-ins/NaN` | 4 | 0 | 2 | 67 % | 100 % |
| `built-ins/SetIteratorPrototype` | 11 | 0 | 0 | 100 % | 100 % |
| ~~`built-ins/SuppressedError`~~ | ~~0~~ | ~~0~~ | ~~21~~ | ~~0 %~~ | ~~0 %~~ |
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

**Scope.** `total` excludes paths universally out of scope (`harness/`, `staging/`, `intl402/`), Annex B language extensions, and browser-era built-ins Cynic doesn't ship (`escape` / `unescape`, `String.prototype` HTML wrappers, `Date.{getYear, setYear}`).

## History

### 2026-05-15 — cynic `2b05c51`, test262 `d0c1b455`

|         | spec% | attempted% | pass / total | pass / attempted | Δ pass | elapsed |
|---|---|---|---|---|---:|---:|
| **parser** | 73.32 % | 100.00 % | 30311 / 41339 | 30311 / 30311 | -167 |  |
| **runtime** | 85.12 % | 91.56 % | 34872 / 40969 | 34872 / 38088 | +1623 | 1m 48s |

Biggest movers (runtime):

- `language/statements` +57
- `language/expressions` +32
- `built-ins/GeneratorPrototype` +4

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

