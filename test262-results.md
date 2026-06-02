# test262 conformance — Cynic

**Cynic passes 98.83 % of its 50894-fixture test262 corpus** under the default (hardened SES) posture (`cynic run`). The breakdown:

- **40178 passing** — Cynic produced the spec-expected result.
- **10120 expected fails** — failures that hit a Cynic design policy (Annex B not shipped, strict-only, no Intl, eval-off, SES throw) rather than an engine bug. Counted as spec-correct in `pass%` because Cynic's deliberate "no" is the right answer for the policy it ships.
- **593 failing** — real engine failures with no policy bucket. Work to do.
- **Out of total**, dropped before `corpus`: the upstream `harness/` and `staging/` paths, and every Stage ≤ 3 proposal (decorators, import-defer, source-phase-imports, import-bytes, immutable-arraybuffer, await-dictionary, plus shipped joint-iteration / ShadowRealm — those get their own dedicated scoreboard).

## Current scores

| posture | passing | failing | expected fails | total | pass% |
|---|---:|---:|---:|---:|---:|
| **unhardened, `--allow=eval`** † | 44074 | 604 | 6213 | 50894 | 98.81 % |
| **unhardened** (`cynic --unhardened`) | 44074 | 600 | 6217 | 50894 | 98.82 % |
| **hardened** (default — `cynic run`) | 40178 | 593 | 10120 | 50894 | 98.83 % |

> **pass%** = `(passing + expected fails) / total`.
> A fixture that fails because of a Cynic design policy
> (Annex B not shipped, strict-only, no Intl, eval-off, SES
> throw) is an **expected fail** rather than a real
> engine bug. Plain **failing** is what's left over — real
> engine work to do.
>
> **† the `--allow=eval` row is a projection**, not a measured
> sweep — the opt-in isn't shipped (see `docs/ses-alignment.md`).
> Turning eval on makes the eval-dependent fixtures (today
> counted as expected fails) attempt to run; most would pass,
> but that relabel stays inside the pass-counted numerator, so
> it never moves pass%. The *only* score-affecting change is the
> **4 indirect-eval Sputnik fixtures** — they fail even with
> eval on (strict-mode PerformEval throws the wrong error
> class), so they move from expected fail to real failing. The
> projected row is the unhardened row with those 4 shifted:
> `failing` 600 → 604, `expected fails` 6217 → 6213, pass%
> 98.82 → 98.81. (Re-applied by hand after each `--write-results`
> sweep, which regenerates this table to `n/a`.)

*SES witness fidelity*: **10 / 10** witnesses are SES expected fails (100.00 %). Curated set in `tools/test262/ses_witnesses.zig`; CI gates at 100 %. See `docs/handbook/ses-test262-policy.md`.

## Legend

### Rows (postures)

Same engine path, different policy mask. All three rows
refer to the same parse → compile → run sweep.

- **unhardened, `--allow=eval`** — unhardened plus the
  eval surface (`eval()`, `new Function(string)`, …) opted
  in. **Projected, not measured** (†): `--allow=eval` isn't
  shipped yet (see `docs/ses-alignment.md`), so this row is
  derived from the unhardened sweep — see the † note under
  the table. A real opt-in sweep replaces it when eval lands.
- **unhardened** — `cynic --unhardened` opt-out. Eval off
  (so eval-dependent fixtures fail and count as correctly
  handled fails), Annex B / Intl / noStrict failures too.
  SES posture off — no SES throws.
- **hardened** — the default posture (`cynic run`). All
  the unhardened policies plus SES — primordials frozen,
  override-mistake fix on, locked descriptors. Fixtures
  whose expectation conflicts with SES enforcement throw
  by design and count as expected fails.

### Columns

- **`passing`** — engine-true successes. Cynic produced
  the spec-expected result.
- **`failing`** — engine-true failures that *don't* match
  any design policy. Real work to do.
- **`expected fails`** — failures that hit a Cynic
  design policy: Annex B not shipped, strict-only,
  no Intl, eval-off, or SES throw. Counted with passes
  under `pass%` because Cynic's deliberate "no" is the
  spec-correct answer for the policy Cynic ships.
  First-match priority: annex_b > no_strict > intl402 >
  eval > SES.
- **`total`** — every fixture except pre-Stage-4
  proposals (Stage ≤ 3, shipped or not) and the upstream
  `staging/` / `harness/` paths.
- **`pass%`** — `(passing + expected fails) / total`.
  The headline.
- **SES witness fidelity** (the italic note above) —
  positive-coverage signal. The curated witness set in
  `tools/test262/ses_witnesses.zig` is a small list of
  paths that MUST classify under the SES policy under
  hardened runs. Drift either way is a hard signal. CI
  gates the floor at 100 %.
- **`Δ pass`** (history) — change in `pass` versus the
  previous row of the same posture.
- **`elapsed`** (history) — wall-clock time of the run
  that produced the row. Recorded only for full sweeps
  (no `--filter`, no `--only-failing`); partial runs
  leave it blank. Sub-minute as `12.3 s`, minute+ as
  `2m 40s`.

### Why we don't claim "spec%"

The percentages here are **not** ECMA-262 spec
conformance. Spec conformance would require running every
normative requirement in the spec — there's no such
enumerable set. test262 is one community attempt at
covering the spec via concrete fixtures, and we run a
**filtered subset** of that (the `corpus`). So `pass%`
is right for "did anything regress?" tracking, but it's
a lower bound on spec coverage — a fixture not in
`corpus` doesn't get a verdict either way.

### Scope (what's in `total`)

Every test262 fixture runs except:

- the upstream `harness/` and `staging/` paths (helpers
  and WIP grounds, not portable spec fixtures); and
- every Stage ≤ 3 proposal — both unshipped (decorators,
  import-defer, source-phase-imports, import-bytes,
  immutable-arraybuffer, await-dictionary) and shipped
  (joint-iteration, ShadowRealm). Shipped pre-Stage-4
  proposals get their own scoreboard in `## Pre-Stage-4
  proposals shipped` below.

Annex B / `noStrict` / `intl402/` / the eval surface
are NOT skipped — they run and any failure classifies
as an **expected fail** under the matching policy.

## Where the engine fails, by area

Each area gets three rows — one per runtime posture
(hardened / unhardened / +eval) — mirroring the three rows in
`## Current scores`. Row ordering + the tier grouping are
driven by the **hardened (default)** sweep's `failing` count.
Bucketed on the first two path components (`built-ins/Set`,
`language/expressions`, …).

**Reading guide:**

- **`failing`** is the real engine-work signal — failures with
  no policy bucket. Nearly posture-invariant: the policies
  relabel expected fails, they don't create engine bugs.
- **hardened** matches `cynic run`; SES-divergent fixtures are
  expected fails. **unhardened** turns SES off, so those flip
  from `expected fails` to `passing`. `pass%` barely moves (it
  counts expected fails as pass), but the **passing ↔ expected
  fails split** shifts — that's the real per-posture signal,
  heaviest in the SES-hot built-ins (`Array`, `Object`,
  `TypedArray`, `String`, …).
- **+eval** is the `--allow=eval` projection; per area it
  equals the unhardened row (the 4 indirect-eval fixtures that
  distinguish them globally don't localize — see the
  `--allow=eval` row in `## Current scores`).
- The **`1+ fails` tiers** are the engine-work list — today
  mostly the SAB/Atomics surface plus the ~13-fixture
  cross-realm cluster. The **0-fails tier** is sorted by
  hardened `expected fails ↓`.


**100–999 fails — engine-work tier**

| area · posture | passing | failing | expected fails | total | pass% |
|---|---:|---:|---:|---:|---:|
| **`built-ins/Atomics`** | | | | | |
| · hardened | 0 | 382 | 0 | 382 | 0 % |
| · unhardened | 0 | 382 | 0 | 382 | 0 % |
| · +eval | 0 | 382 | 0 | 382 | 0 % |
| **`built-ins/SharedArrayBuffer`** | | | | | |
| · hardened | 0 | 104 | 0 | 104 | 0 % |
| · unhardened | 0 | 104 | 0 | 104 | 0 % |
| · +eval | 0 | 104 | 0 | 104 | 0 % |

**10–99 fails — engine-work tier**

| area · posture | passing | failing | expected fails | total | pass% |
|---|---:|---:|---:|---:|---:|
| **`built-ins/DataView`** | | | | | |
| · hardened | 455 | 39 | 56 | 550 | 93 % |
| · unhardened | 511 | 39 | 0 | 550 | 93 % |
| · +eval | 511 | 39 | 0 | 550 | 93 % |
| **`built-ins/TypedArrayConstructors`** | | | | | |
| · hardened | 572 | 48 | 116 | 736 | 93 % |
| · unhardened | 665 | 50 | 21 | 736 | 93 % |
| · +eval | 665 | 50 | 21 | 736 | 93 % |

**1–9 fails — engine-work tier**

| area · posture | passing | failing | expected fails | total | pass% |
|---|---:|---:|---:|---:|---:|
| **`built-ins/Error`** | | | | | |
| · hardened | 43 | 1 | 14 | 58 | 98 % |
| · unhardened | 57 | 1 | 0 | 58 | 98 % |
| · +eval | 57 | 1 | 0 | 58 | 98 % |
| **`built-ins/Function`** | | | | | |
| · hardened | 315 | 5 | 189 | 509 | 99 % |
| · unhardened | 344 | 5 | 160 | 509 | 99 % |
| · +eval | 344 | 5 | 160 | 509 | 99 % |
| **`built-ins/Proxy`** | | | | | |
| · hardened | 290 | 3 | 18 | 311 | 99 % |
| · unhardened | 296 | 4 | 11 | 311 | 99 % |
| · +eval | 296 | 4 | 11 | 311 | 99 % |
| **`built-ins/String`** | | | | | |
| · hardened | 1029 | 2 | 192 | 1223 | 100 % |
| · unhardened | 1206 | 2 | 15 | 1223 | 100 % |
| · +eval | 1206 | 2 | 15 | 1223 | 100 % |
| **`built-ins/ThrowTypeError`** | | | | | |
| · hardened | 13 | 1 | 0 | 14 | 93 % |
| · unhardened | 13 | 1 | 0 | 14 | 93 % |
| · +eval | 13 | 1 | 0 | 14 | 93 % |
| **`built-ins/TypedArray`** | | | | | |
| · hardened | 1104 | 7 | 327 | 1438 | 100 % |
| · unhardened | 1423 | 7 | 8 | 1438 | 100 % |
| · +eval | 1423 | 7 | 8 | 1438 | 100 % |
| **`language/expressions`** | | | | | |
| · hardened | 10017 | 1 | 661 | 10682 | 100 % |
| · unhardened | 10132 | 1 | 546 | 10682 | 100 % |
| · +eval | 10132 | 1 | 546 | 10682 | 100 % |

**0 fails — passing / all-policy (sorted by expected fails ↓)**

| area · posture | passing | failing | expected fails | total | pass% |
|---|---:|---:|---:|---:|---:|
| **`intl402/Temporal`** | | | | | |
| · hardened | 48 | 0 | 1958 | 2006 | 100 % |
| · unhardened | 49 | 0 | 1957 | 2006 | 100 % |
| · +eval | 49 | 0 | 1957 | 2006 | 100 % |
| **`annexB/language`** | | | | | |
| · hardened | 82 | 0 | 763 | 845 | 100 % |
| · unhardened | 85 | 0 | 760 | 845 | 100 % |
| · +eval | 85 | 0 | 760 | 845 | 100 % |
| **`built-ins/Temporal`** | | | | | |
| · hardened | 3885 | 0 | 703 | 4588 | 100 % |
| · unhardened | 4588 | 0 | 0 | 4588 | 100 % |
| · +eval | 4588 | 0 | 0 | 4588 | 100 % |
| **`built-ins/Object`** | | | | | |
| · hardened | 2785 | 0 | 626 | 3411 | 100 % |
| · unhardened | 3322 | 0 | 89 | 3411 | 100 % |
| · +eval | 3322 | 0 | 89 | 3411 | 100 % |
| **`built-ins/Array`** | | | | | |
| · hardened | 2490 | 0 | 591 | 3081 | 100 % |
| · unhardened | 3054 | 0 | 27 | 3081 | 100 % |
| · +eval | 3054 | 0 | 27 | 3081 | 100 % |
| **`language/statements`** | | | | | |
| · hardened | 8753 | 0 | 570 | 9323 | 100 % |
| · unhardened | 8842 | 0 | 481 | 9323 | 100 % |
| · +eval | 8842 | 0 | 481 | 9323 | 100 % |
| **`language/eval-code`** | | | | | |
| · hardened | 73 | 0 | 274 | 347 | 100 % |
| · unhardened | 73 | 0 | 274 | 347 | 100 % |
| · +eval | 73 | 0 | 274 | 347 | 100 % |
| **`intl402/NumberFormat`** | | | | | |
| · hardened | 0 | 0 | 253 | 253 | 100 % |
| · unhardened | 0 | 0 | 253 | 253 | 100 % |
| · +eval | 0 | 0 | 253 | 253 | 100 % |
| **`intl402/DateTimeFormat`** | | | | | |
| · hardened | 0 | 0 | 248 | 248 | 100 % |
| · unhardened | 0 | 0 | 248 | 248 | 100 % |
| · +eval | 0 | 0 | 248 | 248 | 100 % |
| **`annexB/built-ins`** | | | | | |
| · hardened | 3 | 0 | 238 | 241 | 100 % |
| · unhardened | 3 | 0 | 238 | 241 | 100 % |
| · +eval | 3 | 0 | 238 | 241 | 100 % |
| **`built-ins/Date`** | | | | | |
| · hardened | 439 | 0 | 155 | 594 | 100 % |
| · unhardened | 594 | 0 | 0 | 594 | 100 % |
| · +eval | 594 | 0 | 0 | 594 | 100 % |
| **`intl402/Locale`** | | | | | |
| · hardened | 0 | 0 | 152 | 152 | 100 % |
| · unhardened | 0 | 0 | 152 | 152 | 100 % |
| · +eval | 0 | 0 | 152 | 152 | 100 % |
| **`built-ins/Math`** | | | | | |
| · hardened | 214 | 0 | 113 | 327 | 100 % |
| · unhardened | 327 | 0 | 0 | 327 | 100 % |
| · +eval | 327 | 0 | 0 | 327 | 100 % |
| **`intl402/DurationFormat`** | | | | | |
| · hardened | 0 | 0 | 111 | 111 | 100 % |
| · unhardened | 0 | 0 | 111 | 111 | 100 % |
| · +eval | 0 | 0 | 111 | 111 | 100 % |
| **`built-ins/RegExp`** | | | | | |
| · hardened | 1770 | 0 | 109 | 1879 | 100 % |
| · unhardened | 1871 | 1 | 7 | 1879 | 100 % |
| · +eval | 1871 | 1 | 7 | 1879 | 100 % |
| **`built-ins/Promise`** | | | | | |
| · hardened | 533 | 0 | 107 | 640 | 100 % |
| · unhardened | 637 | 0 | 3 | 640 | 100 % |
| · +eval | 637 | 0 | 3 | 640 | 100 % |
| **`intl402/ListFormat`** | | | | | |
| · hardened | 0 | 0 | 81 | 81 | 100 % |
| · unhardened | 0 | 0 | 81 | 81 | 100 % |
| · +eval | 0 | 0 | 81 | 81 | 100 % |
| **`language/function-code`** | | | | | |
| · hardened | 136 | 0 | 81 | 217 | 100 % |
| · unhardened | 139 | 0 | 78 | 217 | 100 % |
| · +eval | 139 | 0 | 78 | 217 | 100 % |
| **`intl402/RelativeTimeFormat`** | | | | | |
| · hardened | 0 | 0 | 80 | 80 | 100 % |
| · unhardened | 0 | 0 | 80 | 80 | 100 % |
| · +eval | 0 | 0 | 80 | 80 | 100 % |
| **`intl402/Segmenter`** | | | | | |
| · hardened | 0 | 0 | 79 | 79 | 100 % |
| · unhardened | 0 | 0 | 79 | 79 | 100 % |
| · +eval | 0 | 0 | 79 | 79 | 100 % |
| **`built-ins/Set`** | | | | | |
| · hardened | 311 | 0 | 72 | 383 | 100 % |
| · unhardened | 382 | 0 | 1 | 383 | 100 % |
| · +eval | 382 | 0 | 1 | 383 | 100 % |
| **`intl402/Intl`** | | | | | |
| · hardened | 0 | 0 | 66 | 66 | 100 % |
| · unhardened | 0 | 0 | 66 | 66 | 100 % |
| · +eval | 0 | 0 | 66 | 66 | 100 % |
| **`intl402/Collator`** | | | | | |
| · hardened | 0 | 0 | 65 | 65 | 100 % |
| · unhardened | 0 | 0 | 65 | 65 | 100 % |
| · +eval | 0 | 0 | 65 | 65 | 100 % |
| **`built-ins/Iterator`** | | | | | |
| · hardened | 368 | 0 | 64 | 432 | 100 % |
| · unhardened | 432 | 0 | 0 | 432 | 100 % |
| · +eval | 432 | 0 | 0 | 432 | 100 % |
| **`built-ins/ArrayBuffer`** | | | | | |
| · hardened | 133 | 0 | 59 | 192 | 100 % |
| · unhardened | 183 | 0 | 9 | 192 | 100 % |
| · +eval | 183 | 0 | 9 | 192 | 100 % |
| **`intl402/DisplayNames`** | | | | | |
| · hardened | 0 | 0 | 57 | 57 | 100 % |
| · unhardened | 0 | 0 | 57 | 57 | 100 % |
| · +eval | 0 | 0 | 57 | 57 | 100 % |
| **`built-ins/Map`** | | | | | |
| · hardened | 151 | 0 | 53 | 204 | 100 % |
| · unhardened | 203 | 0 | 1 | 204 | 100 % |
| · +eval | 203 | 0 | 1 | 204 | 100 % |
| **`intl402/PluralRules`** | | | | | |
| · hardened | 0 | 0 | 52 | 52 | 100 % |
| · unhardened | 0 | 0 | 52 | 52 | 100 % |
| · +eval | 0 | 0 | 52 | 52 | 100 % |
| **`built-ins/Reflect`** | | | | | |
| · hardened | 111 | 0 | 42 | 153 | 100 % |
| · unhardened | 152 | 0 | 1 | 153 | 100 % |
| · +eval | 152 | 0 | 1 | 153 | 100 % |
| **`language/arguments-object`** | | | | | |
| · hardened | 223 | 0 | 40 | 263 | 100 % |
| · unhardened | 225 | 0 | 38 | 263 | 100 % |
| · +eval | 225 | 0 | 38 | 263 | 100 % |
| **`language/statementList`** | | | | | |
| · hardened | 40 | 0 | 40 | 80 | 100 % |
| · unhardened | 40 | 0 | 40 | 80 | 100 % |
| · +eval | 40 | 0 | 40 | 80 | 100 % |
| **`built-ins/Number`** | | | | | |
| · hardened | 302 | 0 | 38 | 340 | 100 % |
| · unhardened | 340 | 0 | 0 | 340 | 100 % |
| · +eval | 340 | 0 | 0 | 340 | 100 % |
| **`built-ins/NativeErrors`** | | | | | |
| · hardened | 58 | 0 | 36 | 94 | 100 % |
| · unhardened | 94 | 0 | 0 | 94 | 100 % |
| · +eval | 94 | 0 | 0 | 94 | 100 % |
| **`built-ins/JSON`** | | | | | |
| · hardened | 136 | 0 | 29 | 165 | 100 % |
| · unhardened | 164 | 1 | 0 | 165 | 99 % |
| · +eval | 164 | 1 | 0 | 165 | 99 % |
| **`built-ins/WeakMap`** | | | | | |
| · hardened | 114 | 0 | 27 | 141 | 100 % |
| · unhardened | 141 | 0 | 0 | 141 | 100 % |
| · +eval | 141 | 0 | 0 | 141 | 100 % |
| **`built-ins/Symbol`** | | | | | |
| · hardened | 73 | 0 | 25 | 98 | 100 % |
| · unhardened | 96 | 0 | 2 | 98 | 100 % |
| · +eval | 96 | 0 | 2 | 98 | 100 % |
| **`language/directive-prologue`** | | | | | |
| · hardened | 37 | 0 | 25 | 62 | 100 % |
| · unhardened | 37 | 0 | 25 | 62 | 100 % |
| · +eval | 37 | 0 | 25 | 62 | 100 % |
| **`built-ins/AsyncDisposableStack`** | | | | | |
| · hardened | 80 | 0 | 24 | 104 | 100 % |
| · unhardened | 104 | 0 | 0 | 104 | 100 % |
| · +eval | 104 | 0 | 0 | 104 | 100 % |
| **`built-ins/DisposableStack`** | | | | | |
| · hardened | 69 | 0 | 24 | 93 | 100 % |
| · unhardened | 93 | 0 | 0 | 93 | 100 % |
| · +eval | 93 | 0 | 0 | 93 | 100 % |
| **`language/types`** | | | | | |
| · hardened | 90 | 0 | 23 | 113 | 100 % |
| · unhardened | 97 | 2 | 14 | 113 | 98 % |
| · +eval | 97 | 2 | 14 | 113 | 98 % |
| **`intl402`** | | | | | |
| · hardened | 0 | 0 | 22 | 22 | 100 % |
| · unhardened | 0 | 0 | 22 | 22 | 100 % |
| · +eval | 0 | 0 | 22 | 22 | 100 % |
| **`built-ins/AsyncGeneratorFunction`** | | | | | |
| · hardened | 2 | 0 | 21 | 23 | 100 % |
| · unhardened | 9 | 0 | 14 | 23 | 100 % |
| · +eval | 9 | 0 | 14 | 23 | 100 % |
| **`built-ins/GeneratorFunction`** | | | | | |
| · hardened | 2 | 0 | 21 | 23 | 100 % |
| · unhardened | 9 | 0 | 14 | 23 | 100 % |
| · +eval | 9 | 0 | 14 | 23 | 100 % |
| **`built-ins/WeakSet`** | | | | | |
| · hardened | 65 | 0 | 20 | 85 | 100 % |
| · unhardened | 85 | 0 | 0 | 85 | 100 % |
| · +eval | 85 | 0 | 0 | 85 | 100 % |
| **`language/module-code`** | | | | | |
| · hardened | 576 | 0 | 19 | 595 | 100 % |
| · unhardened | 589 | 0 | 6 | 595 | 100 % |
| · +eval | 589 | 0 | 6 | 595 | 100 % |
| **`built-ins/BigInt`** | | | | | |
| · hardened | 59 | 0 | 18 | 77 | 100 % |
| · unhardened | 77 | 0 | 0 | 77 | 100 % |
| · +eval | 77 | 0 | 0 | 77 | 100 % |
| **`built-ins/Uint8Array`** | | | | | |
| · hardened | 50 | 0 | 18 | 68 | 100 % |
| · unhardened | 68 | 0 | 0 | 68 | 100 % |
| · +eval | 68 | 0 | 0 | 68 | 100 % |
| **`language/white-space`** | | | | | |
| · hardened | 52 | 0 | 15 | 67 | 100 % |
| · unhardened | 52 | 0 | 15 | 67 | 100 % |
| · +eval | 52 | 0 | 15 | 67 | 100 % |
| **`intl402/String`** | | | | | |
| · hardened | 5 | 0 | 14 | 19 | 100 % |
| · unhardened | 7 | 0 | 12 | 19 | 100 % |
| · +eval | 7 | 0 | 12 | 19 | 100 % |
| **`language/global-code`** | | | | | |
| · hardened | 28 | 0 | 14 | 42 | 100 % |
| · unhardened | 36 | 0 | 6 | 42 | 100 % |
| · +eval | 36 | 0 | 6 | 42 | 100 % |
| **`language/literals`** | | | | | |
| · hardened | 521 | 0 | 13 | 534 | 100 % |
| · unhardened | 521 | 0 | 13 | 534 | 100 % |
| · +eval | 521 | 0 | 13 | 534 | 100 % |
| **`built-ins/RegExpStringIteratorPrototype`** | | | | | |
| · hardened | 5 | 0 | 12 | 17 | 100 % |
| · unhardened | 17 | 0 | 0 | 17 | 100 % |
| · +eval | 17 | 0 | 0 | 17 | 100 % |
| **`built-ins/AsyncGeneratorPrototype`** | | | | | |
| · hardened | 37 | 0 | 11 | 48 | 100 % |
| · unhardened | 48 | 0 | 0 | 48 | 100 % |
| · +eval | 48 | 0 | 0 | 48 | 100 % |
| **`built-ins/FinalizationRegistry`** | | | | | |
| · hardened | 36 | 0 | 11 | 47 | 100 % |
| · unhardened | 47 | 0 | 0 | 47 | 100 % |
| · +eval | 47 | 0 | 0 | 47 | 100 % |
| **`built-ins/GeneratorPrototype`** | | | | | |
| · hardened | 50 | 0 | 11 | 61 | 100 % |
| · unhardened | 61 | 0 | 0 | 61 | 100 % |
| · +eval | 61 | 0 | 0 | 61 | 100 % |
| **`built-ins/global`** | | | | | |
| · hardened | 18 | 0 | 11 | 29 | 100 % |
| · unhardened | 21 | 0 | 8 | 29 | 100 % |
| · +eval | 21 | 0 | 8 | 29 | 100 % |
| **`intl402/BigInt`** | | | | | |
| · hardened | 1 | 0 | 10 | 11 | 100 % |
| · unhardened | 5 | 0 | 6 | 11 | 100 % |
| · +eval | 5 | 0 | 6 | 11 | 100 % |
| **`intl402/Date`** | | | | | |
| · hardened | 2 | 0 | 10 | 12 | 100 % |
| · unhardened | 8 | 0 | 4 | 12 | 100 % |
| · +eval | 8 | 0 | 4 | 12 | 100 % |
| **`built-ins/AsyncFunction`** | | | | | |
| · hardened | 9 | 0 | 9 | 18 | 100 % |
| · unhardened | 14 | 0 | 4 | 18 | 100 % |
| · +eval | 14 | 0 | 4 | 18 | 100 % |
| **`language/line-terminators`** | | | | | |
| · hardened | 32 | 0 | 9 | 41 | 100 % |
| · unhardened | 32 | 0 | 9 | 41 | 100 % |
| · +eval | 32 | 0 | 9 | 41 | 100 % |
| **`built-ins/Boolean`** | | | | | |
| · hardened | 43 | 0 | 8 | 51 | 100 % |
| · unhardened | 50 | 0 | 1 | 51 | 100 % |
| · +eval | 50 | 0 | 1 | 51 | 100 % |
| **`built-ins/WeakRef`** | | | | | |
| · hardened | 21 | 0 | 8 | 29 | 100 % |
| · unhardened | 29 | 0 | 0 | 29 | 100 % |
| · +eval | 29 | 0 | 0 | 29 | 100 % |
| **`language/comments`** | | | | | |
| · hardened | 45 | 0 | 7 | 52 | 100 % |
| · unhardened | 45 | 0 | 7 | 52 | 100 % |
| · +eval | 45 | 0 | 7 | 52 | 100 % |
| **`language/future-reserved-words`** | | | | | |
| · hardened | 48 | 0 | 7 | 55 | 100 % |
| · unhardened | 48 | 0 | 7 | 55 | 100 % |
| · +eval | 48 | 0 | 7 | 55 | 100 % |
| **`language/identifier-resolution`** | | | | | |
| · hardened | 7 | 0 | 7 | 14 | 100 % |
| · unhardened | 9 | 0 | 5 | 14 | 100 % |
| · +eval | 9 | 0 | 5 | 14 | 100 % |
| **`built-ins/AggregateError`** | | | | | |
| · hardened | 19 | 0 | 6 | 25 | 100 % |
| · unhardened | 25 | 0 | 0 | 25 | 100 % |
| · +eval | 25 | 0 | 0 | 25 | 100 % |
| **`built-ins/AsyncIteratorPrototype`** | | | | | |
| · hardened | 7 | 0 | 6 | 13 | 100 % |
| · unhardened | 13 | 0 | 0 | 13 | 100 % |
| · +eval | 13 | 0 | 0 | 13 | 100 % |
| **`built-ins/SuppressedError`** | | | | | |
| · hardened | 16 | 0 | 6 | 22 | 100 % |
| · unhardened | 22 | 0 | 0 | 22 | 100 % |
| · +eval | 22 | 0 | 0 | 22 | 100 % |
| **`intl402/Number`** | | | | | |
| · hardened | 1 | 0 | 6 | 7 | 100 % |
| · unhardened | 3 | 0 | 4 | 7 | 100 % |
| · +eval | 3 | 0 | 4 | 7 | 100 % |
| **`built-ins/ArrayIteratorPrototype`** | | | | | |
| · hardened | 23 | 0 | 4 | 27 | 100 % |
| · unhardened | 27 | 0 | 0 | 27 | 100 % |
| · +eval | 27 | 0 | 0 | 27 | 100 % |
| **`built-ins/undefined`** | | | | | |
| · hardened | 4 | 0 | 4 | 8 | 100 % |
| · unhardened | 4 | 0 | 4 | 8 | 100 % |
| · +eval | 4 | 0 | 4 | 8 | 100 % |
| **`built-ins/MapIteratorPrototype`** | | | | | |
| · hardened | 8 | 0 | 3 | 11 | 100 % |
| · unhardened | 11 | 0 | 0 | 11 | 100 % |
| · +eval | 11 | 0 | 0 | 11 | 100 % |
| **`built-ins/SetIteratorPrototype`** | | | | | |
| · hardened | 8 | 0 | 3 | 11 | 100 % |
| · unhardened | 11 | 0 | 0 | 11 | 100 % |
| · +eval | 11 | 0 | 0 | 11 | 100 % |
| **`built-ins/StringIteratorPrototype`** | | | | | |
| · hardened | 4 | 0 | 3 | 7 | 100 % |
| · unhardened | 7 | 0 | 0 | 7 | 100 % |
| · +eval | 7 | 0 | 0 | 7 | 100 % |
| **`built-ins/decodeURI`** | | | | | |
| · hardened | 52 | 0 | 3 | 55 | 100 % |
| · unhardened | 55 | 0 | 0 | 55 | 100 % |
| · +eval | 55 | 0 | 0 | 55 | 100 % |
| **`built-ins/decodeURIComponent`** | | | | | |
| · hardened | 53 | 0 | 3 | 56 | 100 % |
| · unhardened | 56 | 0 | 0 | 56 | 100 % |
| · +eval | 56 | 0 | 0 | 56 | 100 % |
| **`built-ins/encodeURI`** | | | | | |
| · hardened | 28 | 0 | 3 | 31 | 100 % |
| · unhardened | 31 | 0 | 0 | 31 | 100 % |
| · +eval | 31 | 0 | 0 | 31 | 100 % |
| **`built-ins/encodeURIComponent`** | | | | | |
| · hardened | 28 | 0 | 3 | 31 | 100 % |
| · unhardened | 31 | 0 | 0 | 31 | 100 % |
| · +eval | 31 | 0 | 0 | 31 | 100 % |
| **`built-ins/eval`** | | | | | |
| · hardened | 7 | 0 | 3 | 10 | 100 % |
| · unhardened | 10 | 0 | 0 | 10 | 100 % |
| · +eval | 10 | 0 | 0 | 10 | 100 % |
| **`built-ins/Infinity`** | | | | | |
| · hardened | 4 | 0 | 2 | 6 | 100 % |
| · unhardened | 4 | 0 | 2 | 6 | 100 % |
| · +eval | 4 | 0 | 2 | 6 | 100 % |
| **`built-ins/NaN`** | | | | | |
| · hardened | 4 | 0 | 2 | 6 | 100 % |
| · unhardened | 4 | 0 | 2 | 6 | 100 % |
| · +eval | 4 | 0 | 2 | 6 | 100 % |
| **`built-ins/isFinite`** | | | | | |
| · hardened | 14 | 0 | 1 | 15 | 100 % |
| · unhardened | 15 | 0 | 0 | 15 | 100 % |
| · +eval | 15 | 0 | 0 | 15 | 100 % |
| **`built-ins/isNaN`** | | | | | |
| · hardened | 14 | 0 | 1 | 15 | 100 % |
| · unhardened | 15 | 0 | 0 | 15 | 100 % |
| · +eval | 15 | 0 | 0 | 15 | 100 % |
| **`built-ins/parseFloat`** | | | | | |
| · hardened | 53 | 0 | 1 | 54 | 100 % |
| · unhardened | 54 | 0 | 0 | 54 | 100 % |
| · +eval | 54 | 0 | 0 | 54 | 100 % |
| **`built-ins/parseInt`** | | | | | |
| · hardened | 54 | 0 | 1 | 55 | 100 % |
| · unhardened | 55 | 0 | 0 | 55 | 100 % |
| · +eval | 55 | 0 | 0 | 55 | 100 % |
| **`intl402/Array`** | | | | | |
| · hardened | 1 | 0 | 1 | 2 | 100 % |
| · unhardened | 1 | 0 | 1 | 2 | 100 % |
| · +eval | 1 | 0 | 1 | 2 | 100 % |
| **`language/destructuring`** | | | | | |
| · hardened | 18 | 0 | 1 | 19 | 100 % |
| · unhardened | 18 | 0 | 1 | 19 | 100 % |
| · +eval | 18 | 0 | 1 | 19 | 100 % |
| **`language/import`** | | | | | |
| · hardened | 20 | 0 | 1 | 21 | 100 % |
| · unhardened | 21 | 0 | 0 | 21 | 100 % |
| · +eval | 21 | 0 | 0 | 21 | 100 % |
| **`language/punctuators`** | | | | | |
| · hardened | 10 | 0 | 1 | 11 | 100 % |
| · unhardened | 11 | 0 | 0 | 11 | 100 % |
| · +eval | 11 | 0 | 0 | 11 | 100 % |
| **`built-ins/AsyncFromSyncIteratorPrototype`** | | | | | |
| · hardened | 38 | 0 | 0 | 38 | 100 % |
| · unhardened | 38 | 0 | 0 | 38 | 100 % |
| · +eval | 38 | 0 | 0 | 38 | 100 % |
| **`intl402/TypedArray`** | | | | | |
| · hardened | 1 | 0 | 0 | 1 | 100 % |
| · unhardened | 1 | 0 | 0 | 1 | 100 % |
| · +eval | 1 | 0 | 0 | 1 | 100 % |
| **`language/asi`** | | | | | |
| · hardened | 102 | 0 | 0 | 102 | 100 % |
| · unhardened | 102 | 0 | 0 | 102 | 100 % |
| · +eval | 102 | 0 | 0 | 102 | 100 % |
| **`language/block-scope`** | | | | | |
| · hardened | 145 | 0 | 0 | 145 | 100 % |
| · unhardened | 145 | 0 | 0 | 145 | 100 % |
| · +eval | 145 | 0 | 0 | 145 | 100 % |
| **`language/computed-property-names`** | | | | | |
| · hardened | 48 | 0 | 0 | 48 | 100 % |
| · unhardened | 48 | 0 | 0 | 48 | 100 % |
| · +eval | 48 | 0 | 0 | 48 | 100 % |
| **`language/export`** | | | | | |
| · hardened | 3 | 0 | 0 | 3 | 100 % |
| · unhardened | 3 | 0 | 0 | 3 | 100 % |
| · +eval | 3 | 0 | 0 | 3 | 100 % |
| **`language/identifiers`** | | | | | |
| · hardened | 268 | 0 | 0 | 268 | 100 % |
| · unhardened | 268 | 0 | 0 | 268 | 100 % |
| · +eval | 268 | 0 | 0 | 268 | 100 % |
| **`language/keywords`** | | | | | |
| · hardened | 25 | 0 | 0 | 25 | 100 % |
| · unhardened | 25 | 0 | 0 | 25 | 100 % |
| · +eval | 25 | 0 | 0 | 25 | 100 % |
| **`language/reserved-words`** | | | | | |
| · hardened | 27 | 0 | 0 | 27 | 100 % |
| · unhardened | 27 | 0 | 0 | 27 | 100 % |
| · +eval | 27 | 0 | 0 | 27 | 100 % |
| **`language/rest-parameters`** | | | | | |
| · hardened | 11 | 0 | 0 | 11 | 100 % |
| · unhardened | 11 | 0 | 0 | 11 | 100 % |
| · +eval | 11 | 0 | 0 | 11 | 100 % |
| **`language/source-text`** | | | | | |
| · hardened | 1 | 0 | 0 | 1 | 100 % |
| · unhardened | 1 | 0 | 0 | 1 | 100 % |
| · +eval | 1 | 0 | 0 | 1 | 100 % |

## Pre-Stage-4 proposals shipped

Per-feature scores for the TC39 proposals Cynic ships at
Stage 1–3, ahead of their inclusion in the published
edition. Each proposal gets a **(hardened)** row — the
as-shipped SES posture under `--enable=<flag>`, with SES
throws counted as expected fails — and an
**(unhardened)** row against bare ECMA-262. Same column
shape as the main `## Current scores` table:
`passing | failing | expected fails | total | pass%`.
These fixtures are excluded from the top-line score.

| feature | passing | failing | expected fails | total | pass% |
|---|---:|---:|---:|---:|---:|
| `joint-iteration` (hardened) | 78 | 0 | 3 | 81 | 100 % |
| `joint-iteration` (unhardened) | 76 | 0 | 3 | 81 | 94 % |
| `ShadowRealm` (hardened) | 64 | 0 | 3 | 67 | 100 % |
| `ShadowRealm` (unhardened) | 63 | 0 | 3 | 67 | 94 % |


## History

### 2026-06-02 — cynic `de9e11a`, test262 `d0c1b4555b`

|         | passing | failing | expected fails | total | pass% | Δ pass | elapsed |
|---|---:|---:|---:|---:|---:|---:|---:|
| **unhardened** | 44074 | 600 | 6217 | 50894 | 98.82 % | ±0 | 30.1 s |
| **hardened** | 40178 | 593 | 10120 | 50894 | 98.83 % | ±0 | 40.1 s |

### 2026-06-01 — cynic `fed859f`, test262 `d0c1b4555b`

|         | passing | failing | expected fails | total | pass% | Δ pass | elapsed |
|---|---:|---:|---:|---:|---:|---:|---:|
| **unhardened** | 44074 | 600 | 6217 | 50894 | 98.82 % | n/a | 1m 30s |
| **hardened** | 40178 | 593 | 10120 | 50894 | 98.83 % | n/a | 1m 25s |

