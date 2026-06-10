# test262 conformance — Cynic

**Cynic passes 90.79 % of the 49808 test262 fixtures it runs**, scored binary pass/fail under a single posture (`--unhardened --allow=eval`):

- **45220 passing** — Cynic produced the spec-expected result.
- **4588 failing** — every other scored fixture. No "expected fail" category: an Annex-B / no-Intl / strict-only / SES / eval miss counts as a plain fail, same as an engine bug. Honest, not flattering.
- **Excluded from the denominator**: the upstream `harness/` and `staging/` paths, the whole `annexB/` tree, every Stage ≤ 3 proposal (decorators, import-defer, …), and structurally-unrunnable fixtures (no / malformed frontmatter). Shipped pre-Stage-4 proposals (joint-iteration, ShadowRealm) get their own scoreboard below.

## Current scores

| posture | passing | failing | total | pass% |
|---|---:|---:|---:|---:|
| **`--unhardened --allow=eval`** | 45220 | 4588 | 49808 | 90.79 % |

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
  no-Intl, strict-only, SES, or eval miss counts as a plain
  fail, same as an engine bug.
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


## What is not passing, and why

Every failure, classified. The policy classes are by-design
fails under the binary posture — fixtures that need sloppy
mode, Annex B surfaces, or ECMA-402, none of which Cynic
ships, on purpose. The **engine gaps** row is the real bug
count; the per-area table below it is the work list.

| why | failing | detail |
|---|---:|---|
| ECMA-402 not implemented | 3250 | the whole `intl402/` tree — `Intl` (and the `intl402/Temporal` twins of the excluded Temporal proposal) is an unbuilt subsystem |
| sloppy-mode-only fixtures | 1148 | `flags: [noStrict]` — Cynic is strict-only by design (`with`, sloppy direct-eval `arguments` bindings, legacy S11-era semantics, ...) |
| Annex B builtins | 69 | `__proto__` accessor + `__define`/`__lookup{Getter,Setter}__` are not shipped by design |
| cannot-block agent semantics | 2 | `flags: [CanBlockIsFalse]` — fixtures requiring `Atomics.wait` to throw on a non-blocking agent |
| **engine gaps** | 119 | failures the policy classes do not explain — the work list (an upper bound: it includes a residue of fixtures whose sloppy semantics hide inside dynamic `Function(...)` bodies, undetectable from frontmatter) |

**Failing areas.** Only areas with at least one failure are
listed (everything else passes). `gaps` is the slice of the
area's failures the policy classes above do not explain —
sorted to the top, because that column is the engine work
list. Bucketed on the first two path components.

| area | passing | failing | gaps | pass% |
|---|---:|---:|---:|---:|
| `built-ins/Function` | 424 | 85 | 54 | 83 % |
| `language/expressions` | 10276 | 406 | 28 | 96 % |
| `language/statements` | 8995 | 328 | 13 | 96 % |
| `language/module-code` | 588 | 7 | 7 | 99 % |
| `language/eval-code` | 162 | 185 | 4 | 47 % |
| `language/function-code` | 155 | 62 | 4 | 71 % |
| `built-ins/Object` | 3329 | 82 | 2 | 98 % |
| `language/literals` | 527 | 7 | 2 | 99 % |
| `built-ins/String` | 1219 | 4 | 2 | 100 % |
| `built-ins/TypedArrayConstructors` | 719 | 17 | 1 | 98 % |
| `built-ins/JSON` | 164 | 1 | 1 | 99 % |
| `language/comments` | 51 | 1 | 1 | 98 % |
| `intl402/Temporal` | 49 | 1957 | 0 | 2 % |
| `intl402/NumberFormat` | 0 | 253 | 0 | 0 % |
| `intl402/DateTimeFormat` | 0 | 248 | 0 | 0 % |
| `intl402/Locale` | 0 | 152 | 0 | 0 % |
| `intl402/DurationFormat` | 0 | 111 | 0 | 0 % |
| `intl402/ListFormat` | 0 | 81 | 0 | 0 % |
| `intl402/RelativeTimeFormat` | 0 | 80 | 0 | 0 % |
| `intl402/Segmenter` | 0 | 79 | 0 | 0 % |
| `intl402/Intl` | 0 | 66 | 0 | 0 % |
| `intl402/Collator` | 0 | 65 | 0 | 0 % |
| `intl402/DisplayNames` | 0 | 57 | 0 | 0 % |
| `intl402/PluralRules` | 0 | 52 | 0 | 0 % |
| `language/arguments-object` | 225 | 38 | 0 | 86 % |
| `built-ins/Array` | 3054 | 27 | 0 | 99 % |
| `language/directive-prologue` | 37 | 25 | 0 | 60 % |
| `intl402` | 0 | 22 | 0 | 0 % |
| `intl402/String` | 7 | 12 | 0 | 37 % |
| `built-ins/Proxy` | 300 | 11 | 0 | 96 % |
| `language/types` | 104 | 9 | 0 | 92 % |
| `built-ins/TypedArray` | 1430 | 8 | 0 | 99 % |
| `language/future-reserved-words` | 48 | 7 | 0 | 87 % |
| `intl402/BigInt` | 5 | 6 | 0 | 45 % |
| `language/global-code` | 37 | 5 | 0 | 88 % |
| `language/identifier-resolution` | 9 | 5 | 0 | 64 % |
| `intl402/Date` | 8 | 4 | 0 | 67 % |
| `intl402/Number` | 3 | 4 | 0 | 43 % |
| `built-ins/Promise` | 637 | 3 | 0 | 100 % |
| `built-ins/undefined` | 5 | 3 | 0 | 63 % |
| `built-ins/Atomics` | 380 | 2 | 0 | 99 % |
| `built-ins/Infinity` | 4 | 2 | 0 | 67 % |
| `built-ins/NaN` | 4 | 2 | 0 | 67 % |
| `built-ins/Symbol` | 96 | 2 | 0 | 98 % |
| `built-ins/Map` | 203 | 1 | 0 | 100 % |
| `built-ins/RegExp` | 1878 | 1 | 0 | 100 % |
| `built-ins/Set` | 382 | 1 | 0 | 100 % |
| `intl402/Array` | 1 | 1 | 0 | 50 % |
| `language/destructuring` | 18 | 1 | 0 | 95 % |


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

### 2026-06-10 — cynic `47e09c9`, test262 `d0c1b4555b`

| passing | failing | total | pass% | Δ pass | elapsed |
|---:|---:|---:|---:|---:|---:|
| 45220 | 4588 | 49808 | 90.79 % | +54 | 40.1 s |

Biggest movers:

- `built-ins/Temporal` +4588
- `built-ins/Date` +594
- `built-ins/DataView` +550
- `built-ins/Iterator` +432
- `built-ins/Number` +340

### 2026-06-07 — cynic `690388f`, test262 `d0c1b455`

| passing | failing | total | pass% | Δ pass | elapsed |
|---:|---:|---:|---:|---:|---:|
| 45166 | 4642 | 49808 | 90.68 % | ±0 | 45.1 s |

### 2026-06-05 — cynic `057df50`, test262 `d0c1b455`

| passing | failing | total | pass% | Δ pass | elapsed |
|---:|---:|---:|---:|---:|---:|
| 45166 | 4642 | 49808 | 90.68 % | ±0 | 40.2 s |

### 2026-06-04 — cynic `cf85935`, test262 `d0c1b455`

| passing | failing | total | pass% | Δ pass | elapsed |
|---:|---:|---:|---:|---:|---:|
| 45166 | 4642 | 49808 | 90.68 % | +216 | 45.1 s |

### 2026-06-03 — cynic `51dc5d2`, test262 `d0c1b455`

| passing | failing | total | pass% | Δ pass | elapsed |
|---:|---:|---:|---:|---:|---:|
| 44950 | 4858 | 49808 | 90.25 % | +528 | 25.1 s |

### 2026-06-02 — cynic `bd0337e`, test262 `d0c1b455`

| passing | failing | total | pass% | Δ pass | elapsed |
|---:|---:|---:|---:|---:|---:|
| 44422 | 5386 | 49808 | 89.19 % | n/a | 25.2 s |

