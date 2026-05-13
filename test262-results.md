# test262 conformance score history

## Current scores

|         | spec% | attempted% | pass / total |
|---|---|---|---|
| **parser** | 65.75 % | 100.00 % | 30363 / 46176 |
| **runtime** | 70.79 % | 85.00 % | 32775 / 46296 |

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
| **_1000+ fails_** | | | | | |
| `language/expressions` | 8928 | 1197 | 913 | 81 % | 88 % |
| **_100–999 fails_** | | | | | |
| `built-ins/Array` | 2494 | 458 | 129 | 81 % | 84 % |
| `built-ins/Function` | 211 | 210 | 88 | 41 % | 50 % |
| `built-ins/Object` | 2899 | 431 | 81 | 85 % | 87 % |
| `built-ins/Promise` | 506 | 131 | 40 | 75 % | 79 % |
| `built-ins/RegExp` | 1334 | 384 | 161 | 71 % | 78 % |
| `built-ins/String` | 1014 | 204 | 5 | 83 % | 83 % |
| `built-ins/TypedArray` | 981 | 442 | 15 | 68 % | 69 % |
| `built-ins/TypedArrayConstructors` | 408 | 258 | 70 | 55 % | 61 % |
| `language/module-code` | 392 | 202 | 2 | 66 % | 66 % |
| `language/statements` | 7846 | 810 | 657 | 84 % | 91 % |
| **_10–99 fails_** | | | | | |
| `built-ins/ArrayBuffer` | 94 | 93 | 9 | 48 % | 50 % |
| `built-ins/AsyncFromSyncIteratorPrototype` | 8 | 30 | 0 | 21 % | 21 % |
| `built-ins/AsyncGeneratorFunction` | 7 | 16 | 0 | 30 % | 30 % |
| `built-ins/AsyncGeneratorPrototype` | 22 | 26 | 0 | 46 % | 46 % |
| `built-ins/BigInt` | 51 | 26 | 0 | 66 % | 66 % |
| `built-ins/DataView` | 440 | 82 | 39 | 78 % | 84 % |
| `built-ins/Date` | 526 | 60 | 8 | 89 % | 90 % |
| `built-ins/GeneratorFunction` | 7 | 16 | 0 | 30 % | 30 % |
| `built-ins/GeneratorPrototype` | 32 | 29 | 0 | 52 % | 52 % |
| `built-ins/Iterator` | 442 | 62 | 6 | 87 % | 88 % |
| `built-ins/JSON` | 113 | 31 | 21 | 68 % | 78 % |
| `built-ins/Map` | 177 | 26 | 1 | 87 % | 87 % |
| `built-ins/NativeErrors` | 82 | 12 | 0 | 87 % | 87 % |
| `built-ins/Number` | 318 | 22 | 0 | 94 % | 94 % |
| `built-ins/Proxy` | 201 | 98 | 12 | 65 % | 67 % |
| `built-ins/Reflect` | 118 | 35 | 0 | 77 % | 77 % |
| `built-ins/Set` | 346 | 36 | 1 | 90 % | 91 % |
| `built-ins/WeakMap` | 123 | 18 | 0 | 87 % | 87 % |
| `built-ins/WeakSet` | 73 | 12 | 0 | 86 % | 86 % |
| `built-ins/global` | 16 | 13 | 0 | 55 % | 55 % |
| `language/function-code` | 85 | 23 | 109 | 39 % | 79 % |
| `language/global-code` | 18 | 19 | 5 | 43 % | 49 % |
| `language/identifiers` | 252 | 16 | 0 | 94 % | 94 % |
| `language/import` | 4 | 10 | 113 | 3 % | 29 % |
| `language/line-terminators` | 29 | 12 | 0 | 71 % | 71 % |
| `language/literals` | 405 | 32 | 97 | 76 % | 93 % |
| `language/statementList` | 27 | 53 | 0 | 34 % | 34 % |
| `language/types` | 94 | 10 | 9 | 83 % | 90 % |
| `language/white-space` | 51 | 16 | 0 | 76 % | 76 % |
| **_1–9 fails_** | | | | | |
| `built-ins/AggregateError` | 19 | 6 | 0 | 76 % | 76 % |
| `built-ins/ArrayIteratorPrototype` | 10 | 9 | 8 | 37 % | 53 % |
| `built-ins/AsyncFunction` | 11 | 7 | 0 | 61 % | 61 % |
| `built-ins/Boolean` | 47 | 4 | 0 | 92 % | 92 % |
| `built-ins/Error` | 50 | 8 | 0 | 86 % | 86 % |
| `built-ins/FinalizationRegistry` | 44 | 3 | 0 | 94 % | 94 % |
| `built-ins/Math` | 311 | 6 | 10 | 95 % | 98 % |
| `built-ins/RegExpStringIteratorPrototype` | 8 | 9 | 0 | 47 % | 47 % |
| `built-ins/StringIteratorPrototype` | 2 | 5 | 0 | 29 % | 29 % |
| `built-ins/Symbol` | 82 | 8 | 8 | 84 % | 91 % |
| `built-ins/ThrowTypeError` | 12 | 2 | 0 | 86 % | 86 % |
| `built-ins/WeakRef` | 26 | 3 | 0 | 90 % | 90 % |
| `built-ins/decodeURI` | 53 | 2 | 0 | 96 % | 96 % |
| `built-ins/decodeURIComponent` | 55 | 1 | 0 | 98 % | 98 % |
| `built-ins/encodeURI` | 27 | 4 | 0 | 87 % | 87 % |
| `built-ins/encodeURIComponent` | 26 | 5 | 0 | 84 % | 84 % |
| `built-ins/isFinite` | 14 | 1 | 0 | 93 % | 93 % |
| `built-ins/isNaN` | 14 | 1 | 0 | 93 % | 93 % |
| `built-ins/parseInt` | 54 | 1 | 0 | 98 % | 98 % |
| `built-ins/undefined` | 4 | 1 | 3 | 50 % | 80 % |
| `language/arguments-object` | 200 | 6 | 57 | 76 % | 97 % |
| `language/asi` | 97 | 5 | 0 | 95 % | 95 % |
| `language/block-scope` | 140 | 5 | 0 | 97 % | 97 % |
| `language/comments` | 22 | 7 | 23 | 42 % | 76 % |
| `language/computed-property-names` | 39 | 9 | 0 | 81 % | 81 % |
| `language/destructuring` | 15 | 3 | 1 | 79 % | 83 % |
| `language/identifier-resolution` | 8 | 1 | 5 | 57 % | 89 % |
| `language/reserved-words` | 26 | 1 | 0 | 96 % | 96 % |
| `language/rest-parameters` | 10 | 1 | 0 | 91 % | 91 % |
| `language/source-text` | 0 | 1 | 0 | 0 % | 0 % |
| **_0 fails (passing or wholly OOS)_** | | | | | |
| ~~`built-ins/AbstractModuleSource`~~ | ~~0~~ | ~~0~~ | ~~8~~ | ~~0 %~~ | ~~0 %~~ |
| ~~`built-ins/AsyncDisposableStack`~~ | ~~0~~ | ~~0~~ | ~~104~~ | ~~0 %~~ | ~~0 %~~ |
| `built-ins/AsyncIteratorPrototype` | 4 | 0 | 9 | 31 % | 100 % |
| ~~`built-ins/DisposableStack`~~ | ~~0~~ | ~~0~~ | ~~93~~ | ~~0 %~~ | ~~0 %~~ |
| `built-ins/Infinity` | 4 | 0 | 2 | 67 % | 100 % |
| `built-ins/MapIteratorPrototype` | 11 | 0 | 0 | 100 % | 100 % |
| `built-ins/NaN` | 4 | 0 | 2 | 67 % | 100 % |
| `built-ins/SetIteratorPrototype` | 11 | 0 | 0 | 100 % | 100 % |
| ~~`built-ins/ShadowRealm`~~ | ~~0~~ | ~~0~~ | ~~64~~ | ~~0 %~~ | ~~0 %~~ |
| ~~`built-ins/SuppressedError`~~ | ~~0~~ | ~~0~~ | ~~22~~ | ~~0 %~~ | ~~0 %~~ |
| ~~`built-ins/Temporal`~~ | ~~0~~ | ~~0~~ | ~~4588~~ | ~~0 %~~ | ~~0 %~~ |
| ~~`built-ins/Uint8Array`~~ | ~~0~~ | ~~0~~ | ~~68~~ | ~~0 %~~ | ~~0 %~~ |
| `built-ins/parseFloat` | 54 | 0 | 0 | 100 % | 100 % |
| ~~`language/directive-prologue`~~ | ~~0~~ | ~~0~~ | ~~62~~ | ~~0 %~~ | ~~0 %~~ |
| `language/export` | 3 | 0 | 0 | 100 % | 100 % |
| `language/future-reserved-words` | 48 | 0 | 7 | 87 % | 100 % |
| `language/keywords` | 25 | 0 | 0 | 100 % | 100 % |
| `language/punctuators` | 11 | 0 | 0 | 100 % | 100 % |

## Legend

**Rows**

- **parser** — parses the source only. A pass means Cynic's parser accepts or rejects the test as the spec requires. The runtime is never invoked.
- **runtime** — parses, compiles, and executes. A pass means the result matches the test's expectation (no error for positive tests, the right error class for negatives).

**Columns**

- **spec%** — `pass / total`. Coverage of the corpus. Skipped tests are in `total` but never in `pass`, so this rises only when we ship features that unblock previously-skipped tests. Same definition in the rolled-up rows and in the by-area scoreboard.
- **attempted%** — `pass / (pass + fail)`. Of the tests we actually ran, the fraction that passed. Skips drop out. Measures the quality of what's shipped, independent of coverage. Same definition in the rolled-up rows and in the by-area scoreboard; skip-only buckets render as `0 %`.
- **pass / total** — raw counts. `total` is the Cynic-targeted corpus (see below); `fail` is `attempted - pass`; `skip` is `total - attempted`.
- **Δ pass** (history) — change in `pass` versus the row immediately above (chronologically previous run of the same `mode`).
- **elapsed** (history) — wall-clock time of the run that produced the row. Recorded only for full sweeps (no `--filter`, no `--only-failing`); partial runs leave it blank to keep the regression signal clean. Sub-minute as `12.3 s`, minute+ as `2m 40s`.

**Scope.** `total` excludes paths universally out of scope (`harness/`, `staging/`, `intl402/`), Annex B language extensions, and browser-era built-ins Cynic doesn't ship (`escape` / `unescape`, `String.prototype` HTML wrappers, `Date.{getYear, setYear}`).

## History

### 2026-05-13 — cynic `4abfcec`, test262 `d0c1b455`

|         | spec% | attempted% | pass / total | Δ pass | elapsed |
|---|---|---|---|---:|---:|
| **parser** | 65.75 % | 100.00 % | 30363 / 46176 | +957 | 1.2 s |
| **runtime** | 70.79 % | 85.00 % | 32775 / 46296 | +1007 | 1m 47s |

### 2026-05-12 — cynic `6800720`, test262 `d0c1b455`

|         | spec% | attempted% | pass / total | Δ pass | elapsed |
|---|---|---|---|---:|---:|
| **parser** | 63.52 % | 96.48 % | 29406 / 46296 | +148 | 1.2 s |
| **runtime** | 68.62 % | 82.38 % | 31768 / 46296 | +1877 | 2m 12s |

### 2026-05-11 — cynic `feb8709`, test262 `d0c1b455`

|         | spec% | attempted% | pass / total | Δ pass | elapsed |
|---|---|---|---|---:|---:|
| **parser** | 63.16 % | 96.48 % | 29258 / 46320 | ±0 |  |
| **runtime** | 64.53 % | 78.37 % | 29891 / 46320 | +4713 |  |

### 2026-05-10 — cynic `c5c12a0`, test262 `d0c1b455`

|         | spec% | attempted% | pass / total | Δ pass | elapsed |
|---|---|---|---|---:|---:|
| **parser** | 63.16 % | 96.48 % | 29258 / 46320 | +464 |  |
| **runtime** | 54.36 % | 66.01 % | 25178 / 46320 | +1265 |  |

### 2026-05-09 — cynic `fcc5543`, test262 `d0c1b455`

|         | spec% | attempted% | pass / total | Δ pass | elapsed |
|---|---|---|---|---:|---:|
| **parser** | 62.11 % | 94.89 % | 28794 / 46357 | +252 |  |
| **runtime** | 51.58 % | 62.65 % | 23913 / 46357 | +6048 |  |

### 2026-05-08 — cynic `unknown`, test262 `d0c1b455`

|         | spec% | attempted% | pass / total | Δ pass | elapsed |
|---|---|---|---|---:|---:|
| **parser** | 54.76 % | 95.61 % | 28542 / 52125 | n/a |  |
| **runtime** | 34.60 % | 46.64 % | 17865 / 51639 | n/a |  |

