# test262 conformance score history

## Current scores

|         | spec% | attempted% | pass / total |
|---|---|---|---|
| **parser** | 63.16 % | 96.48 % | 29258 / 46320 |
| **runtime** | 58.20 % | 70.68 % | 26957 / 46320 |

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
| **runtime** | 58.20 % | 70.68 % | 26957 / 46320 | +1779 |

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

