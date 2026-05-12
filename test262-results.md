# test262 conformance score history

## Current scores

|         | spec% | attempted% | pass / total |
|---|---|---|---|
| **parser** | 63.16 % | 96.48 % | 29258 / 46320 |
| **runtime** | 65.19 % | 79.17 % | 30196 / 46320 |

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
| `language/expressions` | 7964 | 2103 | 971 | 72 % | 79 % |
| `language/statements` | 7135 | 1535 | 667 | 76 % | 82 % |
| **_100–999 fails_** | | | | | |
| `built-ins/Array` | 2322 | 548 | 211 | 75 % | 81 % |
| `built-ins/Function` | 216 | 204 | 89 | 42 % | 51 % |
| `built-ins/Object` | 2853 | 473 | 85 | 84 % | 86 % |
| `built-ins/Promise` | 507 | 167 | 3 | 75 % | 75 % |
| `built-ins/Proxy` | 176 | 123 | 12 | 57 % | 59 % |
| `built-ins/RegExp` | 1295 | 423 | 161 | 69 % | 75 % |
| `built-ins/String` | 861 | 357 | 5 | 70 % | 71 % |
| `built-ins/TypedArray` | 880 | 342 | 216 | 61 % | 72 % |
| `built-ins/TypedArrayConstructors` | 385 | 327 | 24 | 52 % | 54 % |
| `language/module-code` | 381 | 201 | 14 | 64 % | 65 % |
| **_10–99 fails_** | | | | | |
| `built-ins/ArrayBuffer` | 55 | 29 | 112 | 28 % | 65 % |
| `built-ins/AsyncFromSyncIteratorPrototype` | 8 | 30 | 0 | 21 % | 21 % |
| `built-ins/AsyncGeneratorFunction` | 6 | 17 | 0 | 26 % | 26 % |
| `built-ins/AsyncGeneratorPrototype` | 22 | 26 | 0 | 46 % | 46 % |
| `built-ins/BigInt` | 40 | 37 | 0 | 52 % | 52 % |
| `built-ins/DataView` | 428 | 61 | 72 | 76 % | 88 % |
| `built-ins/Date` | 505 | 81 | 8 | 85 % | 86 % |
| `built-ins/Error` | 44 | 14 | 0 | 76 % | 76 % |
| `built-ins/GeneratorFunction` | 6 | 17 | 0 | 26 % | 26 % |
| `built-ins/GeneratorPrototype` | 32 | 29 | 0 | 52 % | 52 % |
| `built-ins/Iterator` | 439 | 65 | 6 | 86 % | 87 % |
| `built-ins/JSON` | 73 | 70 | 22 | 44 % | 51 % |
| `built-ins/Map` | 146 | 57 | 1 | 72 % | 72 % |
| `built-ins/NativeErrors` | 74 | 20 | 0 | 79 % | 79 % |
| `built-ins/Number` | 295 | 45 | 0 | 87 % | 87 % |
| `built-ins/Reflect` | 98 | 55 | 0 | 64 % | 64 % |
| `built-ins/RegExpStringIteratorPrototype` | 7 | 10 | 0 | 41 % | 41 % |
| `built-ins/Set` | 331 | 51 | 1 | 86 % | 87 % |
| `built-ins/Symbol` | 56 | 34 | 8 | 57 % | 62 % |
| `built-ins/WeakMap` | 121 | 20 | 0 | 86 % | 86 % |
| `built-ins/WeakSet` | 72 | 13 | 0 | 85 % | 85 % |
| `built-ins/encodeURI` | 20 | 11 | 0 | 65 % | 65 % |
| `built-ins/encodeURIComponent` | 19 | 12 | 0 | 61 % | 61 % |
| `built-ins/global` | 16 | 13 | 0 | 55 % | 55 % |
| `language/arguments-object` | 178 | 28 | 57 | 68 % | 86 % |
| `language/computed-property-names` | 38 | 10 | 0 | 79 % | 79 % |
| `language/function-code` | 85 | 23 | 109 | 39 % | 79 % |
| `language/global-code` | 18 | 19 | 5 | 43 % | 49 % |
| `language/identifiers` | 252 | 16 | 0 | 94 % | 94 % |
| `language/line-terminators` | 29 | 12 | 0 | 71 % | 71 % |
| `language/literals` | 404 | 33 | 97 | 76 % | 92 % |
| `language/statementList` | 27 | 53 | 0 | 34 % | 34 % |
| `language/types` | 92 | 12 | 9 | 81 % | 88 % |
| `language/white-space` | 51 | 16 | 0 | 76 % | 76 % |
| **_1–9 fails_** | | | | | |
| `built-ins/AggregateError` | 17 | 8 | 0 | 68 % | 68 % |
| `built-ins/ArrayIteratorPrototype` | 10 | 9 | 8 | 37 % | 53 % |
| `built-ins/AsyncFunction` | 10 | 8 | 0 | 56 % | 56 % |
| `built-ins/AsyncIteratorPrototype` | 0 | 4 | 9 | 0 % | 0 % |
| `built-ins/Boolean` | 47 | 4 | 0 | 92 % | 92 % |
| `built-ins/FinalizationRegistry` | 43 | 4 | 0 | 91 % | 91 % |
| `built-ins/MapIteratorPrototype` | 10 | 1 | 0 | 91 % | 91 % |
| `built-ins/Math` | 305 | 7 | 15 | 93 % | 98 % |
| `built-ins/SetIteratorPrototype` | 10 | 1 | 0 | 91 % | 91 % |
| `built-ins/StringIteratorPrototype` | 2 | 5 | 0 | 29 % | 29 % |
| `built-ins/ThrowTypeError` | 12 | 2 | 0 | 86 % | 86 % |
| `built-ins/WeakRef` | 25 | 4 | 0 | 86 % | 86 % |
| `built-ins/decodeURI` | 51 | 4 | 0 | 93 % | 93 % |
| `built-ins/decodeURIComponent` | 53 | 3 | 0 | 95 % | 95 % |
| `built-ins/isFinite` | 10 | 5 | 0 | 67 % | 67 % |
| `built-ins/isNaN` | 10 | 5 | 0 | 67 % | 67 % |
| `built-ins/parseFloat` | 52 | 2 | 0 | 96 % | 96 % |
| `built-ins/parseInt` | 48 | 7 | 0 | 87 % | 87 % |
| `built-ins/undefined` | 4 | 1 | 3 | 50 % | 80 % |
| `language/asi` | 97 | 5 | 0 | 95 % | 95 % |
| `language/block-scope` | 140 | 5 | 0 | 97 % | 97 % |
| `language/comments` | 20 | 3 | 29 | 38 % | 87 % |
| `language/identifier-resolution` | 7 | 2 | 5 | 50 % | 78 % |
| `language/reserved-words` | 26 | 1 | 0 | 96 % | 96 % |
| `language/rest-parameters` | 9 | 2 | 0 | 82 % | 82 % |
| `language/source-text` | 0 | 1 | 0 | 0 % | 0 % |
| **_0 fails (passing or wholly OOS)_** | | | | | |
| ~~`built-ins/AbstractModuleSource`~~ | ~~0~~ | ~~0~~ | ~~8~~ | ~~0 %~~ | ~~0 %~~ |
| ~~`built-ins/AsyncDisposableStack`~~ | ~~0~~ | ~~0~~ | ~~104~~ | ~~0 %~~ | ~~0 %~~ |
| ~~`built-ins/DisposableStack`~~ | ~~0~~ | ~~0~~ | ~~93~~ | ~~0 %~~ | ~~0 %~~ |
| `built-ins/Infinity` | 4 | 0 | 2 | 67 % | 100 % |
| `built-ins/NaN` | 4 | 0 | 2 | 67 % | 100 % |
| ~~`built-ins/ShadowRealm`~~ | ~~0~~ | ~~0~~ | ~~64~~ | ~~0 %~~ | ~~0 %~~ |
| ~~`built-ins/SuppressedError`~~ | ~~0~~ | ~~0~~ | ~~22~~ | ~~0 %~~ | ~~0 %~~ |
| ~~`built-ins/Temporal`~~ | ~~0~~ | ~~0~~ | ~~4588~~ | ~~0 %~~ | ~~0 %~~ |
| ~~`built-ins/Uint8Array`~~ | ~~0~~ | ~~0~~ | ~~68~~ | ~~0 %~~ | ~~0 %~~ |
| `language/destructuring` | 17 | 0 | 2 | 89 % | 100 % |
| ~~`language/directive-prologue`~~ | ~~0~~ | ~~0~~ | ~~62~~ | ~~0 %~~ | ~~0 %~~ |
| `language/export` | 3 | 0 | 0 | 100 % | 100 % |
| `language/future-reserved-words` | 48 | 0 | 7 | 87 % | 100 % |
| `language/import` | 4 | 0 | 123 | 3 % | 100 % |
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

**Scope.** `total` excludes paths universally out of scope (`harness/`, `staging/`, `intl402/`), Annex B language extensions, and browser-era built-ins Cynic doesn't ship (`escape` / `unescape`, `String.prototype` HTML wrappers, `Date.{getYear, setYear}`).

## History

### 2026-05-12 — cynic `ce042af`, test262 `d0c1b455`

|         | spec% | attempted% | pass / total | Δ pass |
|---|---|---|---|---:|
| **runtime** | 65.19 % | 79.17 % | 30196 / 46320 | +305 |

Biggest movers (runtime):

- `built-ins/Object` +4
- `language/arguments-object` +1

### 2026-05-11 — cynic `feb8709`, test262 `d0c1b455`

|         | spec% | attempted% | pass / total | Δ pass |
|---|---|---|---|---:|
| **parser** | 63.16 % | 96.48 % | 29258 / 46320 | ±0 |
| **runtime** | 64.53 % | 78.37 % | 29891 / 46320 | +4713 |

### 2026-05-10 — cynic `c5c12a0`, test262 `d0c1b455`

|         | spec% | attempted% | pass / total | Δ pass |
|---|---|---|---|---:|
| **parser** | 63.16 % | 96.48 % | 29258 / 46320 | +464 |
| **runtime** | 54.36 % | 66.01 % | 25178 / 46320 | +1265 |

### 2026-05-09 — cynic `fcc5543`, test262 `d0c1b455`

|         | spec% | attempted% | pass / total | Δ pass |
|---|---|---|---|---:|
| **parser** | 62.11 % | 94.89 % | 28794 / 46357 | +252 |
| **runtime** | 51.58 % | 62.65 % | 23913 / 46357 | +6048 |

### 2026-05-08 — cynic `unknown`, test262 `d0c1b455`

|         | spec% | attempted% | pass / total | Δ pass |
|---|---|---|---|---:|
| **parser** | 54.76 % | 95.61 % | 28542 / 52125 | n/a |
| **runtime** | 34.60 % | 46.64 % | 17865 / 51639 | n/a |

