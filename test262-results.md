# test262 conformance score history

## Current scores

|         | spec% | attempted% | pass / total |
|---|---|---|---|
| **parser** | 62.11 % | 94.89 % | 28794 / 46357 |
| **runtime** | 49.27 % | 59.84 % | 22841 / 46357 |

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
| `language/expressions` | 5900 | 4167 | 971 | 53 % | 59 % |
| `language/statements` | 4457 | 4213 | 667 | 48 % | 51 % |
| **_100–999 fails_** | | | | | |
| `built-ins/Array` | 2005 | 865 | 211 | 65 % | 70 % |
| `built-ins/Date` | 423 | 163 | 8 | 71 % | 72 % |
| `built-ins/Function` | 170 | 250 | 89 | 33 % | 40 % |
| `built-ins/Iterator` | 263 | 241 | 6 | 52 % | 52 % |
| `built-ins/Object` | 2726 | 600 | 85 | 80 % | 82 % |
| `built-ins/Promise` | 304 | 370 | 3 | 45 % | 45 % |
| `built-ins/Proxy` | 116 | 183 | 12 | 37 % | 39 % |
| `built-ins/RegExp` | 742 | 976 | 161 | 39 % | 43 % |
| `built-ins/String` | 829 | 389 | 5 | 68 % | 68 % |
| `built-ins/TypedArray` | 444 | 778 | 216 | 31 % | 36 % |
| `built-ins/TypedArrayConstructors` | 336 | 376 | 24 | 46 % | 47 % |
| `language/module-code` | 369 | 213 | 14 | 62 % | 63 % |
| **_10–99 fails_** | | | | | |
| `built-ins/AggregateError` | 11 | 14 | 0 | 44 % | 44 % |
| `built-ins/ArrayBuffer` | 32 | 52 | 112 | 16 % | 38 % |
| `built-ins/AsyncFromSyncIteratorPrototype` | 0 | 38 | 0 | 0 % | 0 % |
| `built-ins/AsyncGeneratorFunction` | 4 | 19 | 0 | 17 % | 17 % |
| `built-ins/AsyncGeneratorPrototype` | 12 | 36 | 0 | 25 % | 25 % |
| `built-ins/BigInt` | 39 | 38 | 0 | 51 % | 51 % |
| `built-ins/DataView` | 416 | 73 | 72 | 74 % | 85 % |
| `built-ins/Error` | 18 | 40 | 0 | 31 % | 31 % |
| `built-ins/FinalizationRegistry` | 0 | 47 | 0 | 0 % | 0 % |
| `built-ins/GeneratorFunction` | 4 | 19 | 0 | 17 % | 17 % |
| `built-ins/GeneratorPrototype` | 26 | 35 | 0 | 43 % | 43 % |
| `built-ins/JSON` | 70 | 73 | 22 | 42 % | 49 % |
| `built-ins/Map` | 141 | 62 | 1 | 69 % | 69 % |
| `built-ins/MapIteratorPrototype` | 1 | 10 | 0 | 9 % | 9 % |
| `built-ins/Math` | 290 | 22 | 15 | 89 % | 93 % |
| `built-ins/NativeErrors` | 45 | 49 | 0 | 48 % | 48 % |
| `built-ins/Number` | 268 | 72 | 0 | 79 % | 79 % |
| `built-ins/Reflect` | 93 | 60 | 0 | 61 % | 61 % |
| `built-ins/RegExpStringIteratorPrototype` | 0 | 17 | 0 | 0 % | 0 % |
| `built-ins/Set` | 303 | 79 | 1 | 79 % | 79 % |
| `built-ins/SetIteratorPrototype` | 1 | 10 | 0 | 9 % | 9 % |
| `built-ins/Symbol` | 40 | 50 | 8 | 41 % | 44 % |
| `built-ins/ThrowTypeError` | 0 | 14 | 0 | 0 % | 0 % |
| `built-ins/WeakMap` | 120 | 21 | 0 | 85 % | 85 % |
| `built-ins/WeakRef` | 0 | 29 | 0 | 0 % | 0 % |
| `built-ins/WeakSet` | 68 | 17 | 0 | 80 % | 80 % |
| `built-ins/decodeURI` | 37 | 18 | 0 | 67 % | 67 % |
| `built-ins/decodeURIComponent` | 38 | 18 | 0 | 68 % | 68 % |
| `built-ins/encodeURI` | 15 | 16 | 0 | 48 % | 48 % |
| `built-ins/encodeURIComponent` | 14 | 17 | 0 | 45 % | 45 % |
| `built-ins/global` | 9 | 20 | 0 | 31 % | 31 % |
| `built-ins/isFinite` | 3 | 12 | 0 | 20 % | 20 % |
| `built-ins/isNaN` | 3 | 12 | 0 | 20 % | 20 % |
| `built-ins/parseFloat` | 20 | 34 | 0 | 37 % | 37 % |
| `built-ins/parseInt` | 33 | 22 | 0 | 60 % | 60 % |
| `language/arguments-object` | 134 | 72 | 57 | 51 % | 65 % |
| `language/computed-property-names` | 15 | 33 | 0 | 31 % | 31 % |
| `language/function-code` | 86 | 22 | 109 | 40 % | 80 % |
| `language/global-code` | 17 | 20 | 5 | 40 % | 46 % |
| `language/identifiers` | 252 | 16 | 0 | 94 % | 94 % |
| `language/line-terminators` | 29 | 12 | 0 | 71 % | 71 % |
| `language/literals` | 386 | 51 | 97 | 72 % | 88 % |
| `language/statementList` | 27 | 53 | 0 | 34 % | 34 % |
| `language/types` | 91 | 13 | 9 | 81 % | 88 % |
| `language/white-space` | 51 | 16 | 0 | 76 % | 76 % |
| **_1–9 fails_** | | | | | |
| `annexB/built-ins` | 21 | 7 | 9 | 57 % | 75 % |
| `built-ins/ArrayIteratorPrototype` | 10 | 9 | 8 | 37 % | 53 % |
| `built-ins/AsyncFunction` | 10 | 8 | 0 | 56 % | 56 % |
| `built-ins/AsyncIteratorPrototype` | 0 | 4 | 9 | 0 % | 0 % |
| `built-ins/Boolean` | 43 | 8 | 0 | 84 % | 84 % |
| `built-ins/Infinity` | 1 | 3 | 2 | 17 % | 25 % |
| `built-ins/NaN` | 1 | 3 | 2 | 17 % | 25 % |
| `built-ins/StringIteratorPrototype` | 2 | 5 | 0 | 29 % | 29 % |
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

### 2026-05-09 — cynic `ca35c88`, test262 `d0c1b455`

|         | spec% | attempted% | pass / total | Δ pass |
|---|---|---|---|---:|
| **parser** | 62.11 % | 94.89 % | 28794 / 46357 | +252 |
| **runtime** | 49.27 % | 59.84 % | 22841 / 46357 | +4976 |

### 2026-05-08 — cynic `unknown`, test262 `d0c1b455`

|         | spec% | attempted% | pass / total | Δ pass |
|---|---|---|---|---:|
| **parser** | 54.76 % | 95.61 % | 28542 / 52125 | n/a |
| **runtime** | 34.60 % | 46.64 % | 17865 / 51639 | n/a |

