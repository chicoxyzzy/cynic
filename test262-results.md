# test262 conformance — Cynic

**Cynic passes 90.25 % of the 49808 test262 fixtures it runs**, scored binary pass/fail under a single posture (`--unhardened --allow=eval`):

- **44950 passing** — Cynic produced the spec-expected result.
- **4858 failing** — every other scored fixture. No "expected fail" category: an Annex-B / no-Intl / strict-only miss counts as a plain fail, same as an engine bug. Honest, not flattering. (This posture has SES off and eval on, so neither is a failure source here.)
- **Excluded from the denominator**: the upstream `harness/` and `staging/` paths, the whole `annexB/` tree, every Stage ≤ 3 proposal (decorators, import-defer, …), and structurally-unrunnable fixtures (no / malformed frontmatter). Shipped pre-Stage-4 proposals (joint-iteration, ShadowRealm) get their own scoreboard below.

## Current scores

| posture | passing | failing | total | pass% |
|---|---:|---:|---:|---:|
| **`--unhardened --allow=eval`** | 44950 | 4858 | 49808 | 90.25 % |

> **pass%** = `passing / (passing + failing)`. Every scored
> fixture is a plain pass or fail — there is no "expected
> fail" reclassification and no in-corpus "skip" column.

## Legend

### Posture

One scored posture: **`--unhardened --allow=eval`**. The SES
freeze pass is off (so fixtures that monkey-patch primordials
run unhindered) and the eval surface (`eval()`,
`new Function(string)`, …) is opened so eval-dependent
fixtures run for real. The default `cynic run` posture
(hardened, eval off) is stricter; this row measures the
engine's spec coverage with the policy knobs out of the way.

### Columns

- **`passing`** — Cynic produced the spec-expected result.
- **`failing`** — every other scored fixture. An Annex B,
  no-Intl, or strict-only miss counts as a plain fail, same
  as an engine bug. (Under this posture SES is off and eval
  is on, so neither produces a failure.)
- **`total`** — `passing + failing`. Excludes the upstream
  `harness/` / `staging/` / `annexB/` paths, Stage ≤ 3
  proposals, and structurally-unrunnable fixtures.
- **`pass%`** — `passing / total`. The headline.
- **`Δ pass`** (history) — change in `passing` versus the
  previous row.
- **`elapsed`** (history) — wall-clock time of the run.
  Recorded only for full sweeps; partial runs leave it blank.

### Why we don't claim "spec%"

These percentages are **not** ECMA-262 spec conformance.
test262 is one community attempt at covering the spec via
concrete fixtures, and we run a filtered subset of it. So
`pass%` is right for "did anything regress?" tracking, but
it's a lower bound on spec coverage.


## Where the engine fails, by area

Areas are grouped into fail-magnitude tiers (most fails
first); within a tier they're sorted by pass% ascending.
Bucketed on the first two path components (`built-ins/Set`,
`language/expressions`, …). `pass%` = `passing / (passing +
failing)` per area. The `1+ fails` tiers are the engine-work
list.


**1000+ fails**

| area | passing | failing | pass% |
|---|---:|---:|---:|
| `intl402/Temporal` | 49 | 1957 | 2 % |

**100–999 fails**

| area | passing | failing | pass% |
|---|---:|---:|---:|
| `intl402/DateTimeFormat` | 0 | 248 | 0 % |
| `intl402/DurationFormat` | 0 | 111 | 0 % |
| `intl402/Locale` | 0 | 152 | 0 % |
| `intl402/NumberFormat` | 0 | 253 | 0 % |
| `language/eval-code` | 158 | 189 | 46 % |
| `built-ins/Atomics` | 268 | 114 | 70 % |
| `language/statements` | 8902 | 421 | 95 % |
| `language/expressions` | 10227 | 455 | 96 % |

**10–99 fails**

| area | passing | failing | pass% |
|---|---:|---:|---:|
| `intl402` | 0 | 22 | 0 % |
| `intl402/Collator` | 0 | 65 | 0 % |
| `intl402/DisplayNames` | 0 | 57 | 0 % |
| `intl402/Intl` | 0 | 66 | 0 % |
| `intl402/ListFormat` | 0 | 81 | 0 % |
| `intl402/PluralRules` | 0 | 52 | 0 % |
| `intl402/RelativeTimeFormat` | 0 | 80 | 0 % |
| `intl402/Segmenter` | 0 | 79 | 0 % |
| `intl402/String` | 7 | 12 | 37 % |
| `language/directive-prologue` | 37 | 25 | 60 % |
| `language/function-code` | 155 | 62 | 71 % |
| `built-ins/Function` | 421 | 88 | 83 % |
| `language/arguments-object` | 225 | 38 | 86 % |
| `language/types` | 102 | 11 | 90 % |
| `built-ins/Proxy` | 298 | 13 | 96 % |
| `built-ins/Object` | 3329 | 82 | 98 % |
| `built-ins/TypedArrayConstructors` | 719 | 17 | 98 % |
| `built-ins/Array` | 3054 | 27 | 99 % |

**1–9 fails**

| area | passing | failing | pass% |
|---|---:|---:|---:|
| `intl402/Number` | 3 | 4 | 43 % |
| `intl402/BigInt` | 5 | 6 | 45 % |
| `intl402/Array` | 1 | 1 | 50 % |
| `built-ins/undefined` | 5 | 3 | 63 % |
| `language/identifier-resolution` | 9 | 5 | 64 % |
| `built-ins/Infinity` | 4 | 2 | 67 % |
| `built-ins/NaN` | 4 | 2 | 67 % |
| `intl402/Date` | 8 | 4 | 67 % |
| `language/future-reserved-words` | 48 | 7 | 87 % |
| `language/global-code` | 37 | 5 | 88 % |
| `built-ins/ThrowTypeError` | 13 | 1 | 93 % |
| `language/destructuring` | 18 | 1 | 95 % |
| `built-ins/AsyncGeneratorFunction` | 22 | 1 | 96 % |
| `built-ins/GeneratorFunction` | 22 | 1 | 96 % |
| `built-ins/Symbol` | 96 | 2 | 98 % |
| `language/comments` | 51 | 1 | 98 % |
| `language/literals` | 527 | 7 | 99 % |
| `language/module-code` | 589 | 6 | 99 % |
| `built-ins/Reflect` | 152 | 1 | 99 % |
| `built-ins/JSON` | 164 | 1 | 99 % |
| `built-ins/TypedArray` | 1430 | 8 | 99 % |
| `built-ins/String` | 1217 | 6 | 100 % |
| `built-ins/Map` | 203 | 1 | 100 % |
| `built-ins/Promise` | 637 | 3 | 100 % |
| `built-ins/Set` | 382 | 1 | 100 % |
| `built-ins/RegExp` | 1878 | 1 | 100 % |

**0 fails — fully passing**

| area | passing | failing | pass% |
|---|---:|---:|---:|
| `built-ins/AggregateError` | 25 | 0 | 100 % |
| `built-ins/ArrayBuffer` | 192 | 0 | 100 % |
| `built-ins/ArrayIteratorPrototype` | 27 | 0 | 100 % |
| `built-ins/AsyncDisposableStack` | 104 | 0 | 100 % |
| `built-ins/AsyncFromSyncIteratorPrototype` | 38 | 0 | 100 % |
| `built-ins/AsyncFunction` | 18 | 0 | 100 % |
| `built-ins/AsyncGeneratorPrototype` | 48 | 0 | 100 % |
| `built-ins/AsyncIteratorPrototype` | 13 | 0 | 100 % |
| `built-ins/BigInt` | 77 | 0 | 100 % |
| `built-ins/Boolean` | 51 | 0 | 100 % |
| `built-ins/DataView` | 550 | 0 | 100 % |
| `built-ins/Date` | 594 | 0 | 100 % |
| `built-ins/DisposableStack` | 93 | 0 | 100 % |
| `built-ins/Error` | 58 | 0 | 100 % |
| `built-ins/FinalizationRegistry` | 47 | 0 | 100 % |
| `built-ins/GeneratorPrototype` | 61 | 0 | 100 % |
| `built-ins/Iterator` | 432 | 0 | 100 % |
| `built-ins/MapIteratorPrototype` | 11 | 0 | 100 % |
| `built-ins/Math` | 327 | 0 | 100 % |
| `built-ins/NativeErrors` | 94 | 0 | 100 % |
| `built-ins/Number` | 340 | 0 | 100 % |
| `built-ins/RegExpStringIteratorPrototype` | 17 | 0 | 100 % |
| `built-ins/SetIteratorPrototype` | 11 | 0 | 100 % |
| `built-ins/SharedArrayBuffer` | 104 | 0 | 100 % |
| `built-ins/StringIteratorPrototype` | 7 | 0 | 100 % |
| `built-ins/SuppressedError` | 22 | 0 | 100 % |
| `built-ins/Temporal` | 4588 | 0 | 100 % |
| `built-ins/Uint8Array` | 68 | 0 | 100 % |
| `built-ins/WeakMap` | 141 | 0 | 100 % |
| `built-ins/WeakRef` | 29 | 0 | 100 % |
| `built-ins/WeakSet` | 85 | 0 | 100 % |
| `built-ins/decodeURI` | 55 | 0 | 100 % |
| `built-ins/decodeURIComponent` | 56 | 0 | 100 % |
| `built-ins/encodeURI` | 31 | 0 | 100 % |
| `built-ins/encodeURIComponent` | 31 | 0 | 100 % |
| `built-ins/eval` | 10 | 0 | 100 % |
| `built-ins/global` | 29 | 0 | 100 % |
| `built-ins/isFinite` | 15 | 0 | 100 % |
| `built-ins/isNaN` | 15 | 0 | 100 % |
| `built-ins/parseFloat` | 54 | 0 | 100 % |
| `built-ins/parseInt` | 55 | 0 | 100 % |
| `intl402/TypedArray` | 1 | 0 | 100 % |
| `language/asi` | 102 | 0 | 100 % |
| `language/block-scope` | 145 | 0 | 100 % |
| `language/computed-property-names` | 48 | 0 | 100 % |
| `language/export` | 3 | 0 | 100 % |
| `language/identifiers` | 268 | 0 | 100 % |
| `language/import` | 21 | 0 | 100 % |
| `language/keywords` | 25 | 0 | 100 % |
| `language/line-terminators` | 41 | 0 | 100 % |
| `language/punctuators` | 11 | 0 | 100 % |
| `language/reserved-words` | 27 | 0 | 100 % |
| `language/rest-parameters` | 11 | 0 | 100 % |
| `language/source-text` | 1 | 0 | 100 % |
| `language/statementList` | 80 | 0 | 100 % |
| `language/white-space` | 67 | 0 | 100 % |


## Pre-Stage-4 proposals shipped

Per-feature scores for the TC39 proposals Cynic ships at
Stage 1–3, ahead of their inclusion in the published edition.
Each proposal is swept in isolation (only its own
`--enable=<flag>` on) under the same single posture, scored
binary pass/fail. These fixtures are excluded from the
top-line score.

| feature | passing | failing | total | pass% |
|---|---:|---:|---:|---:|
| `joint-iteration` | 78 | 0 | 78 | 100 % |
| `ShadowRealm` | 63 | 1 | 64 | 98 % |


## History

### 2026-06-03 — cynic `51dc5d2`, test262 `d0c1b455`

| passing | failing | total | pass% | Δ pass | elapsed |
|---:|---:|---:|---:|---:|---:|
| 44950 | 4858 | 49808 | 90.25 % | +528 | 25.1 s |

Biggest movers:

- `built-ins/Atomics` +55

### 2026-06-02 — cynic `bd0337e`, test262 `d0c1b455`

| passing | failing | total | pass% | Δ pass | elapsed |
|---:|---:|---:|---:|---:|---:|
| 44422 | 5386 | 49808 | 89.19 % | n/a | 25.2 s |

