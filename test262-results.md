# test262 conformance score history

## Current scores

|         | spec% | attempted% | pass / total |
|---|---|---|---|
| **parser** | 54.76 % | 95.61 % | 28542 / 52125 |
| **runtime** | 37.00 % | 49.88 % | 19108 / 51639 |

## Where the runtime stands, by area

Bucketed on the first two path components (`built-ins/Set`,
`language/expressions`, …). Sorted by raw fail count
descending — the top is where the most tests would move
with the least work. Skipped tests are excluded from
`pass` and `fail`. Rows in ~~strikethrough~~ are buckets
we skip wholesale (out of scope per the Cynic-targeted
skiplist — Annex B language extensions, intl402, staging,
Temporal, browser-era built-ins …).

| area | pass | fail | skip | spec% | attempted% |
|---|---:|---:|---:|---:|---:|
| `language/statements` | 3107 | 5563 | 667 | 33 % | 36 % |
| `language/expressions` | 4555 | 5512 | 971 | 41 % | 45 % |
| `built-ins/RegExp` | 658 | 1060 | 161 | 35 % | 38 % |
| `built-ins/Array` | 1984 | 886 | 211 | 64 % | 69 % |
| `built-ins/TypedArray` | 390 | 832 | 216 | 27 % | 32 % |
| `built-ins/Object` | 2602 | 724 | 85 | 76 % | 78 % |
| `built-ins/String` | 703 | 515 | 5 | 57 % | 58 % |
| `built-ins/TypedArrayConstructors` | 271 | 441 | 24 | 37 % | 38 % |
| `built-ins/Promise` | 253 | 421 | 3 | 37 % | 38 % |
| `built-ins/Iterator` | 113 | 391 | 6 | 22 % | 22 % |
| `built-ins/Function` | 156 | 264 | 89 | 31 % | 37 % |
| `built-ins/DataView` | 238 | 251 | 72 | 42 % | 49 % |
| `built-ins/Proxy` | 68 | 231 | 12 | 22 % | 23 % |
| `language/module-code` | 368 | 214 | 14 | 62 % | 63 % |
| `built-ins/Date` | 421 | 165 | 8 | 71 % | 72 % |
| `language/eval-code` | 10 | 117 | 220 | 3 % | 8 % |
| `built-ins/JSON` | 40 | 103 | 22 | 24 % | 28 % |
| `built-ins/Set` | 299 | 83 | 1 | 78 % | 78 % |
| `language/literals` | 358 | 79 | 97 | 67 % | 82 % |
| `built-ins/Number` | 265 | 75 | 0 | 78 % | 78 % |
| `language/arguments-object` | 132 | 74 | 57 | 50 % | 64 % |
| `built-ins/Map` | 140 | 63 | 1 | 69 % | 69 % |
| `built-ins/Reflect` | 93 | 60 | 0 | 61 % | 61 % |
| `language/statementList` | 27 | 53 | 0 | 34 % | 34 % |
| `built-ins/ArrayBuffer` | 32 | 52 | 112 | 16 % | 38 % |
| `built-ins/Symbol` | 40 | 50 | 8 | 41 % | 44 % |
| `built-ins/NativeErrors` | 45 | 49 | 0 | 48 % | 48 % |
| `built-ins/FinalizationRegistry` | 0 | 47 | 0 | 0 % | 0 % |
| `built-ins/Error` | 18 | 40 | 0 | 31 % | 31 % |
| `built-ins/parseFloat` | 14 | 40 | 0 | 26 % | 26 % |
| `built-ins/BigInt` | 39 | 38 | 0 | 51 % | 51 % |
| `built-ins/AsyncFromSyncIteratorPrototype` | 0 | 38 | 0 | 0 % | 0 % |
| `built-ins/AsyncGeneratorPrototype` | 12 | 36 | 0 | 25 % | 25 % |
| `built-ins/GeneratorPrototype` | 26 | 35 | 0 | 43 % | 43 % |
| `language/computed-property-names` | 15 | 33 | 0 | 31 % | 31 % |
| `built-ins/WeakRef` | 0 | 29 | 0 | 0 % | 0 % |
| `built-ins/parseInt` | 28 | 27 | 0 | 51 % | 51 % |
| `built-ins/AggregateError` | 0 | 25 | 0 | 0 % | 0 % |
| `built-ins/Boolean` | 28 | 23 | 0 | 55 % | 55 % |
| `built-ins/Math` | 290 | 22 | 15 | 89 % | 93 % |
| `language/function-code` | 86 | 22 | 109 | 40 % | 80 % |
| `built-ins/WeakMap` | 120 | 21 | 0 | 85 % | 85 % |
| `language/types` | 83 | 21 | 9 | 73 % | 80 % |
| `language/white-space` | 46 | 21 | 0 | 69 % | 69 % |
| `language/global-code` | 17 | 20 | 5 | 40 % | 46 % |
| `built-ins/decodeURIComponent` | 37 | 19 | 0 | 66 % | 66 % |
| `built-ins/decodeURI` | 36 | 19 | 0 | 65 % | 65 % |
| `built-ins/AsyncGeneratorFunction` | 4 | 19 | 0 | 17 % | 17 % |
| `built-ins/GeneratorFunction` | 4 | 19 | 0 | 17 % | 17 % |
| `built-ins/encodeURIComponent` | 13 | 18 | 0 | 42 % | 42 % |
| `built-ins/WeakSet` | 68 | 17 | 0 | 80 % | 80 % |
| `built-ins/encodeURI` | 14 | 17 | 0 | 45 % | 45 % |
| `built-ins/RegExpStringIteratorPrototype` | 0 | 17 | 0 | 0 % | 0 % |
| `language/identifiers` | 252 | 16 | 0 | 94 % | 94 % |
| `built-ins/global` | 13 | 16 | 0 | 45 % | 45 % |
| `built-ins/ThrowTypeError` | 0 | 14 | 0 | 0 % | 0 % |
| `language/line-terminators` | 29 | 12 | 0 | 71 % | 71 % |
| `built-ins/isFinite` | 3 | 12 | 0 | 20 % | 20 % |
| `built-ins/isNaN` | 3 | 12 | 0 | 20 % | 20 % |
| `built-ins/MapIteratorPrototype` | 1 | 10 | 0 | 9 % | 9 % |
| `built-ins/SetIteratorPrototype` | 1 | 10 | 0 | 9 % | 9 % |
| `language/rest-parameters` | 1 | 10 | 0 | 9 % | 9 % |
| `built-ins/eval` | 0 | 10 | 0 | 0 % | 0 % |
| `built-ins/ArrayIteratorPrototype` | 10 | 9 | 8 | 37 % | 53 % |
| `annexB/built-ins` | 20 | 8 | 9 | 54 % | 71 % |
| `built-ins/AsyncFunction` | 10 | 8 | 0 | 56 % | 56 % |
| `language/block-scope` | 140 | 5 | 0 | 97 % | 97 % |
| `language/asi` | 97 | 5 | 0 | 95 % | 95 % |
| `language/comments` | 18 | 5 | 29 | 35 % | 78 % |
| `built-ins/StringIteratorPrototype` | 2 | 5 | 0 | 29 % | 29 % |
| `built-ins/undefined` | 1 | 4 | 3 | 13 % | 20 % |
| `built-ins/AsyncIteratorPrototype` | 0 | 4 | 9 | 0 % | 0 % |
| `language/identifier-resolution` | 6 | 3 | 5 | 43 % | 67 % |
| `language/destructuring` | 15 | 2 | 2 | 79 % | 88 % |
| `built-ins/Infinity` | 2 | 2 | 2 | 33 % | 50 % |
| `built-ins/NaN` | 2 | 2 | 2 | 33 % | 50 % |
| `language/reserved-words` | 26 | 1 | 0 | 96 % | 96 % |
| `language/punctuators` | 10 | 1 | 0 | 91 % | 91 % |
| `language/source-text` | 0 | 1 | 0 | 0 % | 0 % |
| `language/future-reserved-words` | 48 | 0 | 7 | 87 % | 100 % |
| `language/keywords` | 25 | 0 | 0 | 100 % | 100 % |
| `language/import` | 4 | 0 | 123 | 3 % | 100 % |
| `language/export` | 3 | 0 | 0 | 100 % | 100 % |
| ~~`built-ins/AbstractModuleSource`~~ | ~~0~~ | ~~0~~ | ~~8~~ | ~~0 %~~ | ~~0 %~~ |
| ~~`built-ins/AsyncDisposableStack`~~ | ~~0~~ | ~~0~~ | ~~104~~ | ~~0 %~~ | ~~0 %~~ |
| ~~`built-ins/DisposableStack`~~ | ~~0~~ | ~~0~~ | ~~93~~ | ~~0 %~~ | ~~0 %~~ |
| ~~`built-ins/ShadowRealm`~~ | ~~0~~ | ~~0~~ | ~~64~~ | ~~0 %~~ | ~~0 %~~ |
| ~~`built-ins/SuppressedError`~~ | ~~0~~ | ~~0~~ | ~~22~~ | ~~0 %~~ | ~~0 %~~ |
| ~~`built-ins/Temporal`~~ | ~~0~~ | ~~0~~ | ~~4588~~ | ~~0 %~~ | ~~0 %~~ |
| ~~`built-ins/Uint8Array`~~ | ~~0~~ | ~~0~~ | ~~68~~ | ~~0 %~~ | ~~0 %~~ |
| ~~`harness`~~ | ~~0~~ | ~~0~~ | ~~116~~ | ~~0 %~~ | ~~0 %~~ |
| ~~`intl402`~~ | ~~0~~ | ~~0~~ | ~~22~~ | ~~0 %~~ | ~~0 %~~ |
| ~~`intl402/Array`~~ | ~~0~~ | ~~0~~ | ~~2~~ | ~~0 %~~ | ~~0 %~~ |
| ~~`intl402/BigInt`~~ | ~~0~~ | ~~0~~ | ~~11~~ | ~~0 %~~ | ~~0 %~~ |
| ~~`intl402/Collator`~~ | ~~0~~ | ~~0~~ | ~~65~~ | ~~0 %~~ | ~~0 %~~ |
| ~~`intl402/Date`~~ | ~~0~~ | ~~0~~ | ~~12~~ | ~~0 %~~ | ~~0 %~~ |
| ~~`intl402/DateTimeFormat`~~ | ~~0~~ | ~~0~~ | ~~248~~ | ~~0 %~~ | ~~0 %~~ |
| ~~`intl402/DisplayNames`~~ | ~~0~~ | ~~0~~ | ~~57~~ | ~~0 %~~ | ~~0 %~~ |
| ~~`intl402/DurationFormat`~~ | ~~0~~ | ~~0~~ | ~~111~~ | ~~0 %~~ | ~~0 %~~ |
| ~~`intl402/Intl`~~ | ~~0~~ | ~~0~~ | ~~66~~ | ~~0 %~~ | ~~0 %~~ |
| ~~`intl402/ListFormat`~~ | ~~0~~ | ~~0~~ | ~~81~~ | ~~0 %~~ | ~~0 %~~ |
| ~~`intl402/Locale`~~ | ~~0~~ | ~~0~~ | ~~152~~ | ~~0 %~~ | ~~0 %~~ |
| ~~`intl402/Number`~~ | ~~0~~ | ~~0~~ | ~~7~~ | ~~0 %~~ | ~~0 %~~ |
| ~~`intl402/NumberFormat`~~ | ~~0~~ | ~~0~~ | ~~253~~ | ~~0 %~~ | ~~0 %~~ |
| ~~`intl402/PluralRules`~~ | ~~0~~ | ~~0~~ | ~~52~~ | ~~0 %~~ | ~~0 %~~ |
| ~~`intl402/RelativeTimeFormat`~~ | ~~0~~ | ~~0~~ | ~~80~~ | ~~0 %~~ | ~~0 %~~ |
| ~~`intl402/Segmenter`~~ | ~~0~~ | ~~0~~ | ~~79~~ | ~~0 %~~ | ~~0 %~~ |
| ~~`intl402/String`~~ | ~~0~~ | ~~0~~ | ~~19~~ | ~~0 %~~ | ~~0 %~~ |
| ~~`intl402/Temporal`~~ | ~~0~~ | ~~0~~ | ~~2006~~ | ~~0 %~~ | ~~0 %~~ |
| ~~`intl402/TypedArray`~~ | ~~0~~ | ~~0~~ | ~~1~~ | ~~0 %~~ | ~~0 %~~ |
| ~~`language/directive-prologue`~~ | ~~0~~ | ~~0~~ | ~~62~~ | ~~0 %~~ | ~~0 %~~ |
| ~~`staging`~~ | ~~0~~ | ~~0~~ | ~~4~~ | ~~0 %~~ | ~~0 %~~ |
| ~~`staging/Temporal`~~ | ~~0~~ | ~~0~~ | ~~2~~ | ~~0 %~~ | ~~0 %~~ |
| ~~`staging/Uint8Array`~~ | ~~0~~ | ~~0~~ | ~~1~~ | ~~0 %~~ | ~~0 %~~ |
| ~~`staging/built-ins`~~ | ~~0~~ | ~~0~~ | ~~8~~ | ~~0 %~~ | ~~0 %~~ |
| ~~`staging/decorators`~~ | ~~0~~ | ~~0~~ | ~~3~~ | ~~0 %~~ | ~~0 %~~ |
| ~~`staging/explicit-resource-management`~~ | ~~0~~ | ~~0~~ | ~~53~~ | ~~0 %~~ | ~~0 %~~ |
| ~~`staging/set-methods`~~ | ~~0~~ | ~~0~~ | ~~3~~ | ~~0 %~~ | ~~0 %~~ |
| ~~`staging/sm`~~ | ~~0~~ | ~~0~~ | ~~1409~~ | ~~0 %~~ | ~~0 %~~ |
| ~~`staging/source-phase-imports`~~ | ~~0~~ | ~~0~~ | ~~1~~ | ~~0 %~~ | ~~0 %~~ |
| ~~`staging/top-level-await`~~ | ~~0~~ | ~~0~~ | ~~1~~ | ~~0 %~~ | ~~0 %~~ |


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

### 2026-05-09 — cynic `e69594d`, test262 `d0c1b455`

|         | spec% | attempted% | pass / total | Δ pass |
|---|---|---|---|---:|
| **runtime** | 37.00 % | 49.88 % | 19108 / 51639 | +1243 |

Biggest movers (runtime):

- `language/statements` +315
- `language/expressions` +302
- `language/arguments-object` +52
- `built-ins/Set` +6

### 2026-05-08 — cynic `unknown`, test262 `d0c1b455`

|         | spec% | attempted% | pass / total | Δ pass |
|---|---|---|---|---:|
| **parser** | 54.76 % | 95.61 % | 28542 / 52125 | n/a |
| **runtime** | 34.60 % | 46.64 % | 17865 / 51639 | n/a |

