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
> 98.82 → 98.81. A real `--allow=eval` sweep will replace it
> (and split the eval-dependent relabel into the passing
> column).

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

Per-bucket breakdown sourced from the **hardened (default)**
sweep so the numbers match `cynic run`. Bucketed on the
first two path components (`built-ins/Set`,
`language/expressions`, …).

**Reading guide:**

- The **`1+ fails` tiers** are the engine-work list — real
  failures with no policy bucket. Today the bulk is the
  SAB/Atomics surface (`built-ins/Atomics`,
  `built-ins/SharedArrayBuffer`, plus the `-sab.js`
  generated siblings under TypedArrayConstructors / DataView
  / TypedArray). Cynic doesn't ship shared memory, but
  could — so these are plain fails, not a policy bucket.
  The remainder (~13 fixtures) is the
  cross-realm cluster awaiting `--allow=eval` and multi-realm
  error attribution.
- The **0-fails tier** is sorted by `expected fails ↓` so
  the heaviest policy buckets cluster first. `intl402/`
  trees dominate (no Intl), then the SES-hot built-ins
  (`Array`, `Object`, `TypedArray`, `String`, `Date`,
  `Math`), then the Annex B / eval / noStrict tails.

| area | passing | failing | expected fails | total | pass% |
|---|---:|---:|---:|---:|---:|
| **_100–999 fails — engine-work tier_** | | | | | |
| `built-ins/Atomics` | 0 | 382 | 0 | 382 | 0 % |
| `built-ins/SharedArrayBuffer` | 0 | 104 | 0 | 104 | 0 % |
| **_10–99 fails — engine-work tier_** | | | | | |
| `built-ins/DataView` | 455 | 39 | 56 | 550 | 93 % |
| `built-ins/TypedArrayConstructors` | 572 | 48 | 116 | 736 | 93 % |
| **_1–9 fails — engine-work tier_** | | | | | |
| `built-ins/Error` | 43 | 1 | 14 | 58 | 98 % |
| `built-ins/Function` | 315 | 5 | 189 | 509 | 99 % |
| `built-ins/Proxy` | 290 | 3 | 18 | 311 | 99 % |
| `built-ins/String` | 1029 | 2 | 192 | 1223 | 100 % |
| `built-ins/ThrowTypeError` | 13 | 1 | 0 | 14 | 93 % |
| `built-ins/TypedArray` | 1104 | 7 | 327 | 1438 | 100 % |
| `language/expressions` | 10017 | 1 | 661 | 10682 | 100 % |
| **_0 fails — passing / all-policy (sorted by expected fails ↓)_** | | | | | |
| `intl402/Temporal` | 48 | 0 | 1958 | 2006 | 100 % |
| `annexB/language` | 82 | 0 | 763 | 845 | 100 % |
| `built-ins/Temporal` | 3885 | 0 | 703 | 4588 | 100 % |
| `built-ins/Object` | 2785 | 0 | 626 | 3411 | 100 % |
| `built-ins/Array` | 2490 | 0 | 591 | 3081 | 100 % |
| `language/statements` | 8753 | 0 | 570 | 9323 | 100 % |
| `language/eval-code` | 73 | 0 | 274 | 347 | 100 % |
| `intl402/NumberFormat` | 0 | 0 | 253 | 253 | 100 % |
| `intl402/DateTimeFormat` | 0 | 0 | 248 | 248 | 100 % |
| `annexB/built-ins` | 3 | 0 | 238 | 241 | 100 % |
| `built-ins/Date` | 439 | 0 | 155 | 594 | 100 % |
| `intl402/Locale` | 0 | 0 | 152 | 152 | 100 % |
| `built-ins/Math` | 214 | 0 | 113 | 327 | 100 % |
| `intl402/DurationFormat` | 0 | 0 | 111 | 111 | 100 % |
| `built-ins/RegExp` | 1770 | 0 | 109 | 1879 | 100 % |
| `built-ins/Promise` | 533 | 0 | 107 | 640 | 100 % |
| `intl402/ListFormat` | 0 | 0 | 81 | 81 | 100 % |
| `language/function-code` | 136 | 0 | 81 | 217 | 100 % |
| `intl402/RelativeTimeFormat` | 0 | 0 | 80 | 80 | 100 % |
| `intl402/Segmenter` | 0 | 0 | 79 | 79 | 100 % |
| `built-ins/Set` | 311 | 0 | 72 | 383 | 100 % |
| `intl402/Intl` | 0 | 0 | 66 | 66 | 100 % |
| `intl402/Collator` | 0 | 0 | 65 | 65 | 100 % |
| `built-ins/Iterator` | 368 | 0 | 64 | 432 | 100 % |
| `built-ins/ArrayBuffer` | 133 | 0 | 59 | 192 | 100 % |
| `intl402/DisplayNames` | 0 | 0 | 57 | 57 | 100 % |
| `built-ins/Map` | 151 | 0 | 53 | 204 | 100 % |
| `intl402/PluralRules` | 0 | 0 | 52 | 52 | 100 % |
| `built-ins/Reflect` | 111 | 0 | 42 | 153 | 100 % |
| `language/arguments-object` | 223 | 0 | 40 | 263 | 100 % |
| `language/statementList` | 40 | 0 | 40 | 80 | 100 % |
| `built-ins/Number` | 302 | 0 | 38 | 340 | 100 % |
| `built-ins/NativeErrors` | 58 | 0 | 36 | 94 | 100 % |
| `built-ins/JSON` | 136 | 0 | 29 | 165 | 100 % |
| `built-ins/WeakMap` | 114 | 0 | 27 | 141 | 100 % |
| `built-ins/Symbol` | 73 | 0 | 25 | 98 | 100 % |
| `language/directive-prologue` | 37 | 0 | 25 | 62 | 100 % |
| `built-ins/AsyncDisposableStack` | 80 | 0 | 24 | 104 | 100 % |
| `built-ins/DisposableStack` | 69 | 0 | 24 | 93 | 100 % |
| `language/types` | 90 | 0 | 23 | 113 | 100 % |
| `intl402` | 0 | 0 | 22 | 22 | 100 % |
| `built-ins/AsyncGeneratorFunction` | 2 | 0 | 21 | 23 | 100 % |
| `built-ins/GeneratorFunction` | 2 | 0 | 21 | 23 | 100 % |
| `built-ins/WeakSet` | 65 | 0 | 20 | 85 | 100 % |
| `language/module-code` | 576 | 0 | 19 | 595 | 100 % |
| `built-ins/BigInt` | 59 | 0 | 18 | 77 | 100 % |
| `built-ins/Uint8Array` | 50 | 0 | 18 | 68 | 100 % |
| `language/white-space` | 52 | 0 | 15 | 67 | 100 % |
| `intl402/String` | 5 | 0 | 14 | 19 | 100 % |
| `language/global-code` | 28 | 0 | 14 | 42 | 100 % |
| `language/literals` | 521 | 0 | 13 | 534 | 100 % |
| `built-ins/RegExpStringIteratorPrototype` | 5 | 0 | 12 | 17 | 100 % |
| `built-ins/AsyncGeneratorPrototype` | 37 | 0 | 11 | 48 | 100 % |
| `built-ins/FinalizationRegistry` | 36 | 0 | 11 | 47 | 100 % |
| `built-ins/GeneratorPrototype` | 50 | 0 | 11 | 61 | 100 % |
| `built-ins/global` | 18 | 0 | 11 | 29 | 100 % |
| `intl402/BigInt` | 1 | 0 | 10 | 11 | 100 % |
| `intl402/Date` | 2 | 0 | 10 | 12 | 100 % |
| `built-ins/AsyncFunction` | 9 | 0 | 9 | 18 | 100 % |
| `language/line-terminators` | 32 | 0 | 9 | 41 | 100 % |
| `built-ins/Boolean` | 43 | 0 | 8 | 51 | 100 % |
| `built-ins/WeakRef` | 21 | 0 | 8 | 29 | 100 % |
| `language/comments` | 45 | 0 | 7 | 52 | 100 % |
| `language/future-reserved-words` | 48 | 0 | 7 | 55 | 100 % |
| `language/identifier-resolution` | 7 | 0 | 7 | 14 | 100 % |
| `built-ins/AggregateError` | 19 | 0 | 6 | 25 | 100 % |
| `built-ins/AsyncIteratorPrototype` | 7 | 0 | 6 | 13 | 100 % |
| `built-ins/SuppressedError` | 16 | 0 | 6 | 22 | 100 % |
| `intl402/Number` | 1 | 0 | 6 | 7 | 100 % |
| `built-ins/ArrayIteratorPrototype` | 23 | 0 | 4 | 27 | 100 % |
| `built-ins/undefined` | 4 | 0 | 4 | 8 | 100 % |
| `built-ins/MapIteratorPrototype` | 8 | 0 | 3 | 11 | 100 % |
| `built-ins/SetIteratorPrototype` | 8 | 0 | 3 | 11 | 100 % |
| `built-ins/StringIteratorPrototype` | 4 | 0 | 3 | 7 | 100 % |
| `built-ins/decodeURI` | 52 | 0 | 3 | 55 | 100 % |
| `built-ins/decodeURIComponent` | 53 | 0 | 3 | 56 | 100 % |
| `built-ins/encodeURI` | 28 | 0 | 3 | 31 | 100 % |
| `built-ins/encodeURIComponent` | 28 | 0 | 3 | 31 | 100 % |
| `built-ins/eval` | 7 | 0 | 3 | 10 | 100 % |
| `built-ins/Infinity` | 4 | 0 | 2 | 6 | 100 % |
| `built-ins/NaN` | 4 | 0 | 2 | 6 | 100 % |
| `built-ins/isFinite` | 14 | 0 | 1 | 15 | 100 % |
| `built-ins/isNaN` | 14 | 0 | 1 | 15 | 100 % |
| `built-ins/parseFloat` | 53 | 0 | 1 | 54 | 100 % |
| `built-ins/parseInt` | 54 | 0 | 1 | 55 | 100 % |
| `intl402/Array` | 1 | 0 | 1 | 2 | 100 % |
| `language/destructuring` | 18 | 0 | 1 | 19 | 100 % |
| `language/import` | 20 | 0 | 1 | 21 | 100 % |
| `language/punctuators` | 10 | 0 | 1 | 11 | 100 % |
| `built-ins/AsyncFromSyncIteratorPrototype` | 38 | 0 | 0 | 38 | 100 % |
| `intl402/TypedArray` | 1 | 0 | 0 | 1 | 100 % |
| `language/asi` | 102 | 0 | 0 | 102 | 100 % |
| `language/block-scope` | 145 | 0 | 0 | 145 | 100 % |
| `language/computed-property-names` | 48 | 0 | 0 | 48 | 100 % |
| `language/export` | 3 | 0 | 0 | 3 | 100 % |
| `language/identifiers` | 268 | 0 | 0 | 268 | 100 % |
| `language/keywords` | 25 | 0 | 0 | 25 | 100 % |
| `language/reserved-words` | 27 | 0 | 0 | 27 | 100 % |
| `language/rest-parameters` | 11 | 0 | 0 | 11 | 100 % |
| `language/source-text` | 1 | 0 | 0 | 1 | 100 % |

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

### 2026-06-01 — cynic `fed859f`, test262 `d0c1b4555b`

|         | passing | failing | expected fails | total | pass% | Δ pass | elapsed |
|---|---:|---:|---:|---:|---:|---:|---:|
| **unhardened** | 44074 | 600 | 6217 | 50894 | 98.82 % | n/a | 1m 30s |
| **hardened** | 40178 | 593 | 10120 | 50894 | 98.83 % | n/a | 1m 25s |

