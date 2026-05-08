# test262 conformance score history

## Current scores

|         | spec% | attempted% | pass / total |
|---|---|---|---|
| **parser** | 54.76 % | 95.61 % | 28542 / 52125 |
| **runtime** | 30.15 % | 42.34 % | 15718 / 52125 |

## Legend

**Rows**

- **parser** — parses the source only. A pass means Cynic's parser accepts or rejects the test as the spec requires. The runtime is never invoked.
- **runtime** — parses, compiles, and executes. A pass means the result matches the test's expectation (no error for positive tests, the right error class for negatives).

**Columns**

- **spec%** — `pass / total`. Coverage of the corpus. Skipped tests are in `total` but never in `pass`, so this rises only when we ship features that unblock previously-skipped tests.
- **attempted%** — `pass / (pass + fail)`. Of the tests we actually ran, the fraction that passed. Skips drop out. Measures the quality of what's shipped, independent of coverage.
- **pass / total** — raw counts. `total` is the Cynic-targeted corpus (see below); `fail` is `attempted - pass`; `skip` is `total - attempted`.

**Scope.** `total` excludes paths universally out of scope (`harness/`, `staging/`, `intl402/`), Annex B language extensions, and browser-era built-ins Cynic doesn't ship (`escape` / `unescape`, `String.prototype` HTML wrappers, `Date.{getYear, setYear}`).

## History

### 2026-05-08 — cynic `unknown`, test262 `d0c1b455`

|         | spec% | attempted% | pass / total |
|---|---|---|---|
| **parser** | 54.76 % | 95.61 % | 28542 / 52125 |
| **runtime** | 30.15 % | 42.34 % | 15718 / 52125 |
