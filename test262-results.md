# test262 conformance — Cynic

**Cynic passes 97.32 % of the 49895 test262 fixtures it runs**, scored binary pass/fail under a single posture (`--unhardened --allow=eval`):

- **48556 passing** — Cynic produced the spec-expected result.
- **1339 failing** — every other scored fixture. No "expected fail" category: an Annex-B / strict-only / SES / eval / not-yet-implemented-Intl miss counts as a plain fail, same as an engine bug. Honest, not flattering.
- **Excluded from the denominator**: the upstream `harness/` and `staging/` paths, the whole `annexB/` tree, every Stage ≤ 3 proposal (decorators, import-defer, …), and structurally-unrunnable fixtures (no / malformed frontmatter). Shipped pre-Stage-4 proposals (joint-iteration, ShadowRealm) get their own scoreboard below.

## Current scores

| posture | passing | failing | total | pass% |
|---|---:|---:|---:|---:|
| **`--unhardened --allow=eval`** | 48556 | 1339 | 49895 | 97.32 % |

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
  strict-only, SES, eval, or not-yet-implemented-Intl miss
  counts as a plain fail, same as an engine bug.
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
| sloppy-mode-only fixtures | 1142 | `flags: [noStrict]` — Cynic is strict-only by design (`with`, sloppy direct-eval `arguments` bindings, legacy S11-era semantics, ...) |
| Annex B builtins | 69 | `__proto__` accessor + `__define`/`__lookup{Getter,Setter}__` are not shipped by design |
| Intl normative-optional legacy | 8 | `features: [intl-normative-optional]` — the ECMA-402 §11.1.1/§11.1.2 legacy constructor `[[FallbackSymbol]]` shim (`Intl.NumberFormat.call(obj)` stashing a formatter on a user object). Optional in the spec; a legacy web-compat surface Cynic declines by design, like Annex B. Cynic ships the non-optional path (a fresh formatter, no fallback symbol) |
| **engine gaps** | 120 | failures the policy classes do not explain — the work list. Includes in-scope `intl402/` surfaces not yet implemented at `-Dintl=full` plus implemented-surface Intl bugs; and an upper-bound residue of fixtures whose sloppy semantics hide inside dynamic `Function(...)` bodies, undetectable from frontmatter |

**Failing areas.** Only areas with at least one failure are
listed (everything else passes). `gaps` is the slice of the
area's failures the policy classes above do not explain —
that column is the engine work list. Sorted by area
(alphabetical), bucketed on the first two path components.

| area | passing | failing | gaps | pass% |
|---|---:|---:|---:|---:|
| `built-ins/Array` | 3054 | 27 | 0 | 99 % |
| `built-ins/Function` | 428 | 81 | 50 | 84 % |
| `built-ins/Infinity` | 4 | 2 | 0 | 67 % |
| `built-ins/Map` | 203 | 1 | 0 | 100 % |
| `built-ins/NaN` | 4 | 2 | 0 | 67 % |
| `built-ins/Object` | 3329 | 82 | 2 | 98 % |
| `built-ins/Promise` | 637 | 3 | 0 | 100 % |
| `built-ins/Proxy` | 300 | 11 | 0 | 96 % |
| `built-ins/RegExp` | 1878 | 1 | 0 | 100 % |
| `built-ins/Set` | 382 | 1 | 0 | 100 % |
| `built-ins/String` | 1219 | 4 | 2 | 100 % |
| `built-ins/Symbol` | 96 | 2 | 0 | 98 % |
| `built-ins/Temporal` | 4589 | 14 | 14 | 100 % |
| `built-ins/TypedArray` | 1430 | 8 | 0 | 99 % |
| `built-ins/TypedArrayConstructors` | 719 | 17 | 1 | 98 % |
| `built-ins/undefined` | 5 | 3 | 0 | 63 % |
| `intl402/DateTimeFormat` | 240 | 4 | 1 | 98 % |
| `intl402/FallbackSymbol` | 0 | 2 | 0 | 0 % |
| `intl402/NumberFormat` | 246 | 3 | 0 | 99 % |
| `intl402/Temporal` | 2028 | 1 | 1 | 100 % |
| `language/arguments-object` | 225 | 38 | 0 | 86 % |
| `language/comments` | 51 | 1 | 1 | 98 % |
| `language/destructuring` | 18 | 1 | 0 | 95 % |
| `language/directive-prologue` | 37 | 25 | 0 | 60 % |
| `language/eval-code` | 164 | 183 | 2 | 47 % |
| `language/expressions` | 10308 | 395 | 23 | 96 % |
| `language/function-code` | 155 | 62 | 4 | 71 % |
| `language/future-reserved-words` | 48 | 7 | 0 | 87 % |
| `language/global-code` | 37 | 5 | 0 | 88 % |
| `language/identifier-resolution` | 9 | 5 | 0 | 64 % |
| `language/literals` | 527 | 7 | 2 | 99 % |
| `language/module-code` | 590 | 5 | 5 | 99 % |
| `language/statements` | 8996 | 327 | 12 | 96 % |
| `language/types` | 104 | 9 | 0 | 92 % |


## Pre-Stage-4 proposals shipped

Per-feature scores for the TC39 proposals Cynic ships at
Stage 1–3, ahead of their inclusion in the published edition.
Each proposal is swept in isolation (only its own
`--enable=<flag>` on) under the same single posture, scored
binary pass/fail. These fixtures are excluded from the
top-line score.

| feature | passing | failing | total | pass% |
|---|---:|---:|---:|---:|
| `joint-iteration` | 82 | 0 | 82 | 100 % |
| `ShadowRealm` | 63 | 1 | 64 | 98 % |


## History

### 2026-07-03 — cynic `0c1f0965`, test262 `de8e621c`

| passing | failing | total | pass% | Δ pass | elapsed |
|---:|---:|---:|---:|---:|---:|
| 48556 | 1339 | 49895 | 97.32 % | +2108 | 1m 25s |

Biggest movers:

- `intl402/Temporal` +1579
- `built-ins/Date` +594
- `built-ins/DataView` +550
- `built-ins/Iterator` +432
- `built-ins/Atomics` +381

### 2026-06-25 — cynic `882c0dc`, test262 `de8e621cdb`

| passing | failing | total | pass% | Δ pass | elapsed |
|---:|---:|---:|---:|---:|---:|
| 46448 | 3447 | 49895 | 93.09 % | +1113 | 2m 05s |

### 2026-06-24 — cynic `86ec52d`, test262 `de8e621cdb`

| passing | failing | total | pass% | Δ pass | elapsed |
|---:|---:|---:|---:|---:|---:|
| 45335 | 4560 | 49895 | 90.86 % | ±0 | 2m 05s |

### 2026-06-22 — cynic `f435659`, test262 `de8e621cdb`

| passing | failing | total | pass% | Δ pass | elapsed |
|---:|---:|---:|---:|---:|---:|
| 45335 | 4560 | 49895 | 90.86 % | ±0 | 2m 10s |

### 2026-06-21 — cynic `b45d2c62`, test262 `de8e621cdb`

| passing | failing | total | pass% | Δ pass | elapsed |
|---:|---:|---:|---:|---:|---:|
| 45335 | 4560 | 49895 | 90.86 % | ±0 | 2m 05s |

### 2026-06-19 — cynic `8642fb21`, test262 `8642fb21`

| passing | failing | total | pass% | Δ pass | elapsed |
|---:|---:|---:|---:|---:|---:|
| 45335 | 4560 | 49895 | 90.86 % | +2 | 55.1 s |

### 2026-06-14 — cynic `c48da45`, test262 `de8e621cdb`

| passing | failing | total | pass% | Δ pass | elapsed |
|---:|---:|---:|---:|---:|---:|
| 45333 | 4562 | 49895 | 90.86 % | +34 | 1m 25s |

### 2026-06-12 — cynic `9026203`, test262 `de8e621c`

| passing | failing | total | pass% | Δ pass | elapsed |
|---:|---:|---:|---:|---:|---:|
| 45299 | 4596 | 49895 | 90.79 % | +58 | 55.1 s |

### 2026-06-11 — cynic `b2adad7`, test262 `d0c1b4555b`

| passing | failing | total | pass% | Δ pass | elapsed |
|---:|---:|---:|---:|---:|---:|
| 45241 | 4567 | 49808 | 90.83 % | +18 | 40.1 s |

### 2026-06-10 — cynic `288c1a0`, test262 `d0c1b4555b`

| passing | failing | total | pass% | Δ pass | elapsed |
|---:|---:|---:|---:|---:|---:|
| 45223 | 4585 | 49808 | 90.79 % | +57 | 45.4 s |

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

