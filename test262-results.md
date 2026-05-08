# test262 conformance score history

## Current scores

|         | spec% | attempted% | pass / total |
|---|---|---|---|
| **parser** | 54.76 % | 95.61 % | 28542 / 52125 |
| **runtime** | 30.42 % | 42.47 % | 15854 / 52125 |

## Where the runtime stands, by area

Bucketed on the first two path components (`built-ins/Set`,
`language/expressions`, …). Sorted by raw fail count
descending — the top is where the most tests would move
with the least work. Skipped tests are excluded from
`pass` and `fail`.

| area | pass | fail | skip | spec% |
|---|---:|---:|---:|---:|
| `language/expressions` | 3717 | 6350 | 971 | 34 % |
| `language/statements` | 2676 | 5994 | 667 | 29 % |
| `built-ins/TypedArray` | 1 | 1221 | 216 | 0 % |
| `built-ins/Array` | 1818 | 1052 | 211 | 59 % |
| `built-ins/Object` | 2336 | 986 | 89 | 68 % |
| `built-ins/String` | 539 | 674 | 10 | 44 % |
| `built-ins/TypedArrayConstructors` | 48 | 664 | 24 | 7 % |
| `built-ins/Promise` | 199 | 475 | 3 | 29 % |
| `built-ins/RegExp` | 403 | 469 | 1007 | 21 % |
| `built-ins/Function` | 140 | 280 | 89 | 28 % |
| `built-ins/DataView` | 218 | 271 | 72 | 39 % |
| `built-ins/Atomics` | 0 | 271 | 111 | 0 % |
| `built-ins/Proxy` | 68 | 231 | 12 | 22 % |
| `built-ins/Date` | 371 | 215 | 8 | 62 % |
| `language/module-code` | 380 | 202 | 14 | 64 % |
| `language/arguments-object` | 65 | 141 | 57 | 25 % |
| `language/eval-code` | 10 | 117 | 220 | 3 % |
| `built-ins/Iterator` | 7 | 108 | 395 | 1 % |
| `built-ins/Set` | 276 | 106 | 1 | 72 % |
| `built-ins/JSON` | 38 | 105 | 22 | 23 % |
| `built-ins/Number` | 254 | 86 | 0 | 75 % |
| `language/literals` | 303 | 78 | 153 | 57 % |
| `built-ins/Reflect` | 76 | 77 | 0 | 50 % |
| `built-ins/Map` | 130 | 73 | 1 | 64 % |
| `built-ins/SharedArrayBuffer` | 0 | 60 | 44 | 0 % |
| `built-ins/Math` | 255 | 57 | 15 | 78 % |
| `built-ins/Symbol` | 33 | 57 | 8 | 34 % |
| `built-ins/ArrayBuffer` | 31 | 53 | 112 | 16 % |
| `language/statementList` | 27 | 53 | 0 | 34 % |
| `built-ins/NativeErrors` | 45 | 48 | 1 | 48 % |
| `language/computed-property-names` | 0 | 48 | 0 | 0 % |
| `built-ins/FinalizationRegistry` | 0 | 47 | 0 | 0 % |
| `built-ins/BigInt` | 33 | 44 | 0 | 43 % |
| `built-ins/parseFloat` | 12 | 42 | 0 | 22 % |
| `built-ins/AsyncGeneratorPrototype` | 7 | 41 | 0 | 15 % |
| `built-ins/Error` | 16 | 39 | 3 | 28 % |
| `built-ins/AsyncFromSyncIteratorPrototype` | 0 | 38 | 0 | 0 % |
| `built-ins/GeneratorPrototype` | 26 | 35 | 0 | 43 % |
| `built-ins/parseInt` | 26 | 29 | 0 | 47 % |
| `built-ins/WeakRef` | 0 | 29 | 0 | 0 % |
| `built-ins/WeakMap` | 114 | 27 | 0 | 81 % |
| `built-ins/Boolean` | 26 | 25 | 0 | 51 % |
| `built-ins/AggregateError` | 0 | 24 | 1 | 0 % |
| `language/function-code` | 85 | 23 | 109 | 39 % |
| `language/types` | 82 | 22 | 9 | 73 % |
| `language/white-space` | 46 | 21 | 0 | 69 % |
| `built-ins/AsyncGeneratorFunction` | 2 | 21 | 0 | 9 % |
| `built-ins/GeneratorFunction` | 2 | 21 | 0 | 9 % |
| `built-ins/WeakSet` | 65 | 20 | 0 | 76 % |
| `language/global-code` | 17 | 20 | 5 | 40 % |
| `built-ins/decodeURIComponent` | 37 | 19 | 0 | 66 % |
| `built-ins/decodeURI` | 36 | 19 | 0 | 65 % |
| `built-ins/encodeURIComponent` | 13 | 18 | 0 | 42 % |
| `built-ins/encodeURI` | 14 | 17 | 0 | 45 % |
| `built-ins/RegExpStringIteratorPrototype` | 0 | 17 | 0 | 0 % |
| `language/identifiers` | 252 | 16 | 0 | 94 % |
| `built-ins/global` | 13 | 16 | 0 | 45 % |
| `built-ins/ThrowTypeError` | 0 | 14 | 0 | 0 % |
| `language/line-terminators` | 29 | 12 | 0 | 71 % |
| `built-ins/AsyncFunction` | 6 | 12 | 0 | 33 % |
| `built-ins/isFinite` | 3 | 12 | 0 | 20 % |
| `built-ins/isNaN` | 3 | 12 | 0 | 20 % |
| `annexB/built-ins` | 18 | 10 | 9 | 49 % |
| `built-ins/MapIteratorPrototype` | 1 | 10 | 0 | 9 % |
| `built-ins/SetIteratorPrototype` | 1 | 10 | 0 | 9 % |
| `language/rest-parameters` | 1 | 10 | 0 | 9 % |
| `built-ins/eval` | 0 | 10 | 0 | 0 % |
| `built-ins/ArrayIteratorPrototype` | 10 | 9 | 8 | 37 % |
| `language/block-scope` | 140 | 5 | 0 | 97 % |
| `language/asi` | 97 | 5 | 0 | 95 % |
| `language/comments` | 18 | 5 | 29 | 35 % |
| `language/identifier-resolution` | 4 | 5 | 5 | 29 % |
| `built-ins/StringIteratorPrototype` | 2 | 5 | 0 | 29 % |
| `language/reserved-words` | 23 | 4 | 0 | 85 % |
| `built-ins/undefined` | 1 | 4 | 3 | 13 % |
| `built-ins/AsyncIteratorPrototype` | 0 | 4 | 9 | 0 % |
| `language/destructuring` | 15 | 2 | 2 | 79 % |
| `built-ins/Infinity` | 2 | 2 | 2 | 33 % |
| `built-ins/NaN` | 2 | 2 | 2 | 33 % |
| `language/punctuators` | 10 | 1 | 0 | 91 % |
| `language/source-text` | 0 | 1 | 0 | 0 % |
| `language/future-reserved-words` | 48 | 0 | 7 | 87 % |
| `language/keywords` | 25 | 0 | 0 | 100 % |
| `language/import` | 4 | 0 | 123 | 3 % |
| `language/export` | 3 | 0 | 0 | 100 % |
| `built-ins/AbstractModuleSource` | 0 | 0 | 8 | 0 % |
| `built-ins/AsyncDisposableStack` | 0 | 0 | 104 | 0 % |
| `built-ins/DisposableStack` | 0 | 0 | 93 | 0 % |
| `built-ins/ShadowRealm` | 0 | 0 | 64 | 0 % |
| `built-ins/SuppressedError` | 0 | 0 | 22 | 0 % |
| `built-ins/Temporal` | 0 | 0 | 4588 | 0 % |
| `built-ins/Uint8Array` | 0 | 0 | 68 | 0 % |
| `harness` | 0 | 0 | 116 | 0 % |
| `intl402` | 0 | 0 | 22 | 0 % |
| `intl402/Array` | 0 | 0 | 2 | 0 % |
| `intl402/BigInt` | 0 | 0 | 11 | 0 % |
| `intl402/Collator` | 0 | 0 | 65 | 0 % |
| `intl402/Date` | 0 | 0 | 12 | 0 % |
| `intl402/DateTimeFormat` | 0 | 0 | 248 | 0 % |
| `intl402/DisplayNames` | 0 | 0 | 57 | 0 % |
| `intl402/DurationFormat` | 0 | 0 | 111 | 0 % |
| `intl402/Intl` | 0 | 0 | 66 | 0 % |
| `intl402/ListFormat` | 0 | 0 | 81 | 0 % |
| `intl402/Locale` | 0 | 0 | 152 | 0 % |
| `intl402/Number` | 0 | 0 | 7 | 0 % |
| `intl402/NumberFormat` | 0 | 0 | 253 | 0 % |
| `intl402/PluralRules` | 0 | 0 | 52 | 0 % |
| `intl402/RelativeTimeFormat` | 0 | 0 | 80 | 0 % |
| `intl402/Segmenter` | 0 | 0 | 79 | 0 % |
| `intl402/String` | 0 | 0 | 19 | 0 % |
| `intl402/Temporal` | 0 | 0 | 2006 | 0 % |
| `intl402/TypedArray` | 0 | 0 | 1 | 0 % |
| `language/directive-prologue` | 0 | 0 | 62 | 0 % |
| `staging` | 0 | 0 | 4 | 0 % |
| `staging/Temporal` | 0 | 0 | 2 | 0 % |
| `staging/Uint8Array` | 0 | 0 | 1 | 0 % |
| `staging/built-ins` | 0 | 0 | 8 | 0 % |
| `staging/decorators` | 0 | 0 | 3 | 0 % |
| `staging/explicit-resource-management` | 0 | 0 | 53 | 0 % |
| `staging/set-methods` | 0 | 0 | 3 | 0 % |
| `staging/sm` | 0 | 0 | 1409 | 0 % |
| `staging/source-phase-imports` | 0 | 0 | 1 | 0 % |
| `staging/top-level-await` | 0 | 0 | 1 | 0 % |


## Legend

**Rows**

- **parser** — parses the source only. A pass means Cynic's parser accepts or rejects the test as the spec requires. The runtime is never invoked.
- **runtime** — parses, compiles, and executes. A pass means the result matches the test's expectation (no error for positive tests, the right error class for negatives).

**Columns**

- **spec%** — `pass / total`. Coverage of the corpus. Skipped tests are in `total` but never in `pass`, so this rises only when we ship features that unblock previously-skipped tests.
- **attempted%** — `pass / (pass + fail)`. Of the tests we actually ran, the fraction that passed. Skips drop out. Measures the quality of what's shipped, independent of coverage.
- **pass / total** — raw counts. `total` is the Cynic-targeted corpus (see below); `fail` is `attempted - pass`; `skip` is `total - attempted`.
- **Δ pass** (history) — change in `pass` versus the row immediately above (chronologically previous run of the same `mode`).

**Scope.** `total` excludes paths universally out of scope (`harness/`, `staging/`, `intl402/`), Annex B language extensions, and browser-era built-ins Cynic doesn't ship (`escape` / `unescape`, `String.prototype` HTML wrappers, `Date.{getYear, setYear}`).

## History

### 2026-05-08 — cynic `unknown`, test262 `d0c1b455`

|         | spec% | attempted% | pass / total | Δ pass |
|---|---|---|---|---:|
| **parser** | 54.76 % | 95.61 % | 28542 / 52125 | n/a |
| **runtime** | 30.42 % | 42.47 % | 15854 / 52125 | n/a |

