# test262 conformance score history

## Current scores

|         | spec% | attempted% | pass / total |
|---|---|---|---|
| **parser** | 63.16 % | 96.48 % | 29258 / 46320 |
| **runtime** | 60.86 % | 73.91 % | 28189 / 46320 |

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
| `language/expressions` | 7202 | 2865 | 971 | 65 % | 72 % |
| `language/statements` | 6732 | 1938 | 667 | 72 % | 78 % |
| **_100–999 fails_** | | | | | |
| `built-ins/Array` | 2153 | 717 | 211 | 70 % | 75 % |
| `built-ins/Function` | 205 | 215 | 89 | 40 % | 49 % |
| `built-ins/Object` | 2748 | 578 | 85 | 81 % | 83 % |
| `built-ins/Promise` | 466 | 208 | 3 | 69 % | 69 % |
| `built-ins/Proxy` | 125 | 174 | 12 | 40 % | 42 % |
| `built-ins/RegExp` | 1136 | 582 | 161 | 60 % | 66 % |
| `built-ins/String` | 850 | 368 | 5 | 70 % | 70 % |
| `built-ins/TypedArray` | 766 | 456 | 216 | 53 % | 63 % |
| `built-ins/TypedArrayConstructors` | 383 | 329 | 24 | 52 % | 54 % |
| `language/module-code` | 381 | 201 | 14 | 64 % | 65 % |
| **_10–99 fails_** | | | | | |
| `built-ins/AggregateError` | 13 | 12 | 0 | 52 % | 52 % |
| `built-ins/ArrayBuffer` | 36 | 48 | 112 | 18 % | 43 % |
| `built-ins/AsyncFromSyncIteratorPrototype` | 8 | 30 | 0 | 21 % | 21 % |
| `built-ins/AsyncGeneratorFunction` | 4 | 19 | 0 | 17 % | 17 % |
| `built-ins/AsyncGeneratorPrototype` | 10 | 38 | 0 | 21 % | 21 % |
| `built-ins/BigInt` | 40 | 37 | 0 | 52 % | 52 % |
| `built-ins/DataView` | 422 | 67 | 72 | 75 % | 86 % |
| `built-ins/Date` | 503 | 83 | 8 | 85 % | 86 % |
| `built-ins/Error` | 34 | 24 | 0 | 59 % | 59 % |
| `built-ins/GeneratorFunction` | 4 | 19 | 0 | 17 % | 17 % |
| `built-ins/GeneratorPrototype` | 26 | 35 | 0 | 43 % | 43 % |
| `built-ins/Iterator` | 435 | 69 | 6 | 85 % | 86 % |
| `built-ins/JSON` | 71 | 72 | 22 | 43 % | 50 % |
| `built-ins/Map` | 143 | 60 | 1 | 70 % | 70 % |
| `built-ins/NativeErrors` | 68 | 26 | 0 | 72 % | 72 % |
| `built-ins/Number` | 270 | 70 | 0 | 79 % | 79 % |
| `built-ins/Reflect` | 94 | 59 | 0 | 61 % | 61 % |
| `built-ins/RegExpStringIteratorPrototype` | 7 | 10 | 0 | 41 % | 41 % |
| `built-ins/Set` | 318 | 64 | 1 | 83 % | 83 % |
| `built-ins/Symbol` | 42 | 48 | 8 | 43 % | 47 % |
| `built-ins/WeakMap` | 121 | 20 | 0 | 86 % | 86 % |
| `built-ins/WeakSet` | 72 | 13 | 0 | 85 % | 85 % |
| `built-ins/encodeURI` | 20 | 11 | 0 | 65 % | 65 % |
| `built-ins/encodeURIComponent` | 19 | 12 | 0 | 61 % | 61 % |
| `built-ins/global` | 16 | 13 | 0 | 55 % | 55 % |
| `built-ins/isFinite` | 4 | 11 | 0 | 27 % | 27 % |
| `built-ins/isNaN` | 4 | 11 | 0 | 27 % | 27 % |
| `language/arguments-object` | 168 | 38 | 57 | 64 % | 82 % |
| `language/computed-property-names` | 30 | 18 | 0 | 63 % | 63 % |
| `language/function-code` | 85 | 23 | 109 | 39 % | 79 % |
| `language/global-code` | 18 | 19 | 5 | 43 % | 49 % |
| `language/identifiers` | 252 | 16 | 0 | 94 % | 94 % |
| `language/line-terminators` | 29 | 12 | 0 | 71 % | 71 % |
| `language/literals` | 398 | 39 | 97 | 75 % | 91 % |
| `language/statementList` | 27 | 53 | 0 | 34 % | 34 % |
| `language/types` | 92 | 12 | 9 | 81 % | 88 % |
| `language/white-space` | 51 | 16 | 0 | 76 % | 76 % |
| **_1–9 fails_** | | | | | |
| `built-ins/ArrayIteratorPrototype` | 10 | 9 | 8 | 37 % | 53 % |
| `built-ins/AsyncFunction` | 10 | 8 | 0 | 56 % | 56 % |
| `built-ins/AsyncIteratorPrototype` | 0 | 4 | 9 | 0 % | 0 % |
| `built-ins/Boolean` | 44 | 7 | 0 | 86 % | 86 % |
| `built-ins/FinalizationRegistry` | 43 | 4 | 0 | 91 % | 91 % |
| `built-ins/Infinity` | 2 | 2 | 2 | 33 % | 50 % |
| `built-ins/MapIteratorPrototype` | 10 | 1 | 0 | 91 % | 91 % |
| `built-ins/Math` | 305 | 7 | 15 | 93 % | 98 % |
| `built-ins/NaN` | 2 | 2 | 2 | 33 % | 50 % |
| `built-ins/SetIteratorPrototype` | 10 | 1 | 0 | 91 % | 91 % |
| `built-ins/StringIteratorPrototype` | 2 | 5 | 0 | 29 % | 29 % |
| `built-ins/ThrowTypeError` | 13 | 1 | 0 | 93 % | 93 % |
| `built-ins/WeakRef` | 25 | 4 | 0 | 86 % | 86 % |
| `built-ins/decodeURI` | 51 | 4 | 0 | 93 % | 93 % |
| `built-ins/decodeURIComponent` | 53 | 3 | 0 | 95 % | 95 % |
| `built-ins/parseFloat` | 52 | 2 | 0 | 96 % | 96 % |
| `built-ins/parseInt` | 48 | 7 | 0 | 87 % | 87 % |
| `built-ins/undefined` | 1 | 4 | 3 | 13 % | 20 % |
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

### 2026-05-11 — cynic `feb8709`, test262 `d0c1b455`

|         | spec% | attempted% | pass / total | Δ pass |
|---|---|---|---|---:|
| **parser** | 63.16 % | 96.48 % | 29258 / 46320 | ±0 |
| **runtime** | 60.86 % | 73.91 % | 28189 / 46320 | +3011 |

Biggest movers (runtime):

- `built-ins/Array` +103

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

