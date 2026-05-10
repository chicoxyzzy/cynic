# test262 conformance score history

## Current scores

|         | spec% | attempted% | pass / total |
|---|---|---|---|
| **parser** | 63.16 % | 96.48 % | 29258 / 46320 |
| **runtime** | 52.42 % | 63.66 % | 24282 / 46320 |

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
| `language/expressions` | 5919 | 4148 | 971 | 54 % | 59 % |
| `language/statements` | 4463 | 4207 | 667 | 48 % | 51 % |
| **_100–999 fails_** | | | | | |
| `built-ins/Array` | 2053 | 817 | 211 | 67 % | 72 % |
| `built-ins/Function` | 173 | 247 | 89 | 34 % | 41 % |
| `built-ins/Object` | 2732 | 594 | 85 | 80 % | 82 % |
| `built-ins/Promise` | 459 | 215 | 3 | 68 % | 68 % |
| `built-ins/Proxy` | 121 | 178 | 12 | 39 % | 40 % |
| `built-ins/RegExp` | 1130 | 588 | 161 | 60 % | 66 % |
| `built-ins/String` | 849 | 369 | 5 | 69 % | 70 % |
| `built-ins/TypedArray` | 766 | 456 | 216 | 53 % | 63 % |
| `built-ins/TypedArrayConstructors` | 372 | 340 | 24 | 51 % | 52 % |
| `language/module-code` | 369 | 213 | 14 | 62 % | 63 % |
| **_10–99 fails_** | | | | | |
| `built-ins/AggregateError` | 12 | 13 | 0 | 48 % | 48 % |
| `built-ins/ArrayBuffer` | 33 | 51 | 112 | 17 % | 39 % |
| `built-ins/AsyncFromSyncIteratorPrototype` | 0 | 38 | 0 | 0 % | 0 % |
| `built-ins/AsyncGeneratorFunction` | 4 | 19 | 0 | 17 % | 17 % |
| `built-ins/AsyncGeneratorPrototype` | 10 | 38 | 0 | 21 % | 21 % |
| `built-ins/BigInt` | 39 | 38 | 0 | 51 % | 51 % |
| `built-ins/DataView` | 421 | 68 | 72 | 75 % | 86 % |
| `built-ins/Date` | 502 | 84 | 8 | 85 % | 86 % |
| `built-ins/Error` | 33 | 25 | 0 | 57 % | 57 % |
| `built-ins/GeneratorFunction` | 4 | 19 | 0 | 17 % | 17 % |
| `built-ins/GeneratorPrototype` | 26 | 35 | 0 | 43 % | 43 % |
| `built-ins/Iterator` | 423 | 81 | 6 | 83 % | 84 % |
| `built-ins/JSON` | 70 | 73 | 22 | 42 % | 49 % |
| `built-ins/Map` | 142 | 61 | 1 | 70 % | 70 % |
| `built-ins/MapIteratorPrototype` | 1 | 10 | 0 | 9 % | 9 % |
| `built-ins/NativeErrors` | 62 | 32 | 0 | 66 % | 66 % |
| `built-ins/Number` | 269 | 71 | 0 | 79 % | 79 % |
| `built-ins/Reflect` | 93 | 60 | 0 | 61 % | 61 % |
| `built-ins/RegExpStringIteratorPrototype` | 0 | 17 | 0 | 0 % | 0 % |
| `built-ins/Set` | 312 | 70 | 1 | 81 % | 82 % |
| `built-ins/SetIteratorPrototype` | 1 | 10 | 0 | 9 % | 9 % |
| `built-ins/Symbol` | 41 | 49 | 8 | 42 % | 46 % |
| `built-ins/ThrowTypeError` | 0 | 14 | 0 | 0 % | 0 % |
| `built-ins/WeakMap` | 120 | 21 | 0 | 85 % | 85 % |
| `built-ins/WeakSet` | 71 | 14 | 0 | 84 % | 84 % |
| `built-ins/encodeURI` | 17 | 14 | 0 | 55 % | 55 % |
| `built-ins/encodeURIComponent` | 16 | 15 | 0 | 52 % | 52 % |
| `built-ins/global` | 11 | 18 | 0 | 38 % | 38 % |
| `built-ins/isFinite` | 3 | 12 | 0 | 20 % | 20 % |
| `built-ins/isNaN` | 3 | 12 | 0 | 20 % | 20 % |
| `language/arguments-object` | 137 | 69 | 57 | 52 % | 67 % |
| `language/computed-property-names` | 15 | 33 | 0 | 31 % | 31 % |
| `language/function-code` | 85 | 23 | 109 | 39 % | 79 % |
| `language/global-code` | 17 | 20 | 5 | 40 % | 46 % |
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
| `built-ins/Boolean` | 43 | 8 | 0 | 84 % | 84 % |
| `built-ins/FinalizationRegistry` | 40 | 7 | 0 | 85 % | 85 % |
| `built-ins/Infinity` | 1 | 3 | 2 | 17 % | 25 % |
| `built-ins/Math` | 304 | 8 | 15 | 93 % | 97 % |
| `built-ins/NaN` | 1 | 3 | 2 | 17 % | 25 % |
| `built-ins/StringIteratorPrototype` | 2 | 5 | 0 | 29 % | 29 % |
| `built-ins/WeakRef` | 22 | 7 | 0 | 76 % | 76 % |
| `built-ins/decodeURI` | 48 | 7 | 0 | 87 % | 87 % |
| `built-ins/decodeURIComponent` | 50 | 6 | 0 | 89 % | 89 % |
| `built-ins/parseFloat` | 50 | 4 | 0 | 93 % | 93 % |
| `built-ins/parseInt` | 46 | 9 | 0 | 84 % | 84 % |
| `built-ins/undefined` | 0 | 5 | 3 | 0 % | 0 % |
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

### 2026-05-10 — cynic `bd53b8a`, test262 `d0c1b455`

|         | spec% | attempted% | pass / total | Δ pass |
|---|---|---|---|---:|
| **parser** | 63.16 % | 96.48 % | 29258 / 46320 | +464 |
| **runtime** | 52.42 % | 63.66 % | 24282 / 46320 | +369 |

Biggest movers (runtime):

- `built-ins/Iterator` +143
- `built-ins/FinalizationRegistry` +40
- `built-ins/WeakRef` +22
- `built-ins/Object` +2
- `language/expressions` +1

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

