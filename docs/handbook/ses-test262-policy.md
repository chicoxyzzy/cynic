# SES + test262 scoring policy

Cynic ships SES posture by default (frozen primordials, override-mistake
fix, `harden()` global) and runs both modes through every score sweep —
the `runtime` row tracks the legacy ECMAScript baseline (`--unhardened`),
the `runtime_hardened` row tracks the SES posture. The two rows share
the same test262 corpus, but **the corpus was written against pre-SES
ECMAScript**: many fixtures assert invariants that SES intentionally
invalidates (`Math.abs.length` is `configurable: true`,
`Array.prototype.X = …` succeeds, `Object.isExtensible(Math)` is
`true`). Under the SES posture the engine throwing on those is the
*correct* behaviour, not a bug.

This doc is the durable plan for separating "SES is doing its job" from
"Cynic has a real bug" in the `runtime_hardened` score. A fresh session
should be able to pick up the next sub-step from here without re-deriving
the design. Sister docs:

- [docs/ses-alignment.md](../ses-alignment.md) — what SES posture
  actually changes at runtime (Phase 1+3 shipped).
- [tools/test262/skip.zig](../../tools/test262/skip.zig) — existing
  skip-by-path rules (Annex B, intl402, staging — different mechanism
  from what this doc describes).
- [test262-results.md](../../test262-results.md) — the score artifact
  this policy reshapes.

## Problem in one paragraph

The current `runtime_hardened` row at ~84.77% spec% looks ~8 pp worse
than the unhardened baseline (92.90%). The ~3258-fixture delta isn't
mostly Cynic bugs — it's intentional SES divergence. Real engine bugs
under SES are ~9 fixtures (the same libregexp Annex B leak the
unhardened row carries). The current row mixes both signals, which
makes the floor in `--min-hardened-spec-pct` blunt: a *real* hardened
regression of 50 fixtures still leaves the score well above any
reasonable floor, so CI can't catch it cleanly.

## Goals

1. The `runtime_hardened` headline number reflects **real Cynic
   bugs**, not intentional SES divergence — directly comparable
   to `runtime`. **Hardened mode is the primary signal**: Cynic's
   brand bet is hardened-by-default and that's where engineering
   effort should go. `runtime` (unhardened) is the continuity /
   reference baseline, not the optimisation target. A bug fix
   that only moves unhardened doesn't earn the same priority as
   one that moves hardened too.
2. SES-required behaviours get **positively tested** — the engine
   asserts a throw where SES says it must, instead of silently
   skipping the fixture.
3. Both modes stay **comparable** and the score history doesn't get
   retroactively invalidated — old rows still read meaningfully.
4. **New corpus updates** can't silently introduce un-classified
   divergent fixtures (a test262 bump that adds 200 descriptor-shape
   fixtures shouldn't quietly tank the hardened row).
5. **Strict-only enforcement is positively tested** — for every
   Annex B / sloppy-only feature Cynic doesn't ship, the test262
   fixtures that assert the feature is *absent* (or rejected in
   strict mode) get attempted, not skipped. Coverage of "the
   engine correctly refuses Annex B" matters as much as coverage
   of "the engine correctly implements ECMAScript". See "Annex B
   negative coverage" below.

## The three building blocks

### A. Divergence list — fixtures reclassified, not failed

Most fixtures that fail under hardened mode hit one of a handful of
**structural** reasons. Each gets a predicate in
`tools/test262/ses_divergent.zig` — path glob, frontmatter check,
or both. A hardened-mode fixture whose post-run failure matches a
divergence predicate gets reclassified into a fourth outcome
state alongside `pass` / `fail` / `skip`: **`divergent`**.

Candidate categories (concrete list comes from the audit step
below — these are the hypothesis):

- Built-in `.name` / `.length` `configurable: true` assertions.
- Built-in property-descriptor round-trips (`writable: true`,
  `configurable: true` on intrinsic methods).
- `Foo.prototype.X = …` monkey-patch assertions where the fixture
  expects the assignment to succeed.
- `Object.isExtensible(<intrinsic-namespace>)` returning `true`.
- `Object.preventExtensions(<intrinsic>)` no-ops because the
  target is already non-extensible.
- `Object.getOwnPropertyDescriptor(<intrinsic>, "X")` returning
  spec-pre-SES flags.

Each entry in `ses_divergent.zig` carries a `category` enum (so the
score row can break the divergent count down by source) and a
short comment naming the spec section being subverted.

### B. Witness inversion — a curated SES-positive subset

For ~50–100 fixtures whose sole assertion is the SES-divergent one and
whose code body is short and clear, **invert** the expected outcome
under the hardened phase: instead of "expect success", "expect
TypeError on the offending operation". These become **SES-witness**
fixtures.

They sit in `tools/test262/ses_witnesses.zig` as a path → expected-
exception-class map. The hardened-phase runner consults this map
before classifying a failure: if the fixture's actual outcome was
the expected-exception-class, it passes; otherwise it fails (and
fails noisily — a missing witness throw means SES isn't enforcing
what we claim it does).

Selection criterion for inclusion in the witness set:

- Fixture is ≤ 30 lines, no `includes:` beyond `propertyHelper.js`.
- Sole assertion is the SES-divergent invariant (no unrelated
  spec checks bundled in).
- Failure mode is unambiguous (engine should throw TypeError
  at a specific operation).

The remaining ~3200 divergent fixtures stay in category A
(reclassified to `divergent`, no expected-outcome inversion).

### C. Cynic-authored SES-positive tests

Test262 doesn't cover SES surfaces Cynic ships natively — override-
mistake fix correctness (assignment-becomes-shadow, accessor pair
demotion semantics), `harden()` cycle behaviour, `--unhardened`
round-trip parity, frozen-globalThis edge cases. Add a small suite
under `tests/ses/` (NOT in `vendor/test262/`) and route it through
the harness as a separate phase: `--phase=ses-positive`.

These tests:

- Live in `tests/ses/*.js`, hand-written, Cynic-specific.
- Each carries a `// expected: pass` or `// expected: TypeError`
  header comment (Cynic-specific format — not test262 frontmatter).
- Run only under hardened mode (no point under `--unhardened`).
- Score as a separate row: `ses-cynic-witness`. Distinct from
  `ses-witness` (which is test262 fixtures inverted) so the two
  can drift independently.

Out of scope for this doc: contributing the Cynic-authored set back
to test262. That's a TC39/SES-working-group conversation, separate
PR cycle, separate review surface. Track in `docs/test262-upstream-
gaps.md` when concrete.

## Scoring math

Under the new scheme, the hardened phase produces four buckets per
fixture: `pass`, `fail`, `divergent`, `skip`. Skip semantics
unchanged. Divergent is the new bucket — fixtures the harness saw
fail in a way that matches the divergence list.

For the score row, two numerators matter:

- `pass + divergent` — "engine behaved correctly given the spec
  it implements" (SES is part of the spec Cynic ships in hardened
  mode). Comparable directly to unhardened.
- `pass` alone — "engine matched the test262-as-written
  expectation". The historical raw number.

Two denominators matter:

- `total` — corpus size, unchanged from unhardened.
- `pass + fail` (the "attempted" denominator) — excludes both
  `skip` and `divergent`. The quality-of-engine-conformance gauge.

For the hardened row in the score table:

- `spec%` = `(pass + divergent) / total` — headline.
- `attempted%` = `pass / (pass + fail)` — drops on any real
  regression regardless of divergence.
- `pass / total` column shows `(pass + divergent) / total`.
- `pass / attempted` column shows `pass / (pass + fail)`.
- New `divergent` column carries the absolute divergent count.

For the new `ses-witness` row (test262 fixtures inverted under
hardened mode):

- `spec%` = `pass / total`, where `total` is the curated witness
  set size (~50–100, not the whole corpus).
- `attempted%` = `pass / (pass + fail)` — typically 100% under
  correct SES enforcement.
- A drop below 100% on this row means **SES isn't enforcing what
  we say it does** — a different class of bug from the main rows.

The `ses-cynic-witness` row (Cynic-authored tests) scores the same
way.

## Score row rendering (Layout A — chosen 2026-05-25)

`## Current scores` table:

```
|                    | spec%   | attempted% | pass / total     | pass / attempted | divergent |
|--------------------|---------|------------|------------------|------------------|----------:|
| parser             | 73.32 % | 100.00 %   | 30311 / 41339    | 30311 / 30311    |         — |
| runtime            | 92.90 % | 99.98 %    | 37241 / 40089    | 37241 / 37250    |         — |
| runtime_hardened   | 92.90 % | 99.97 %    | 37241 / 40089    | 33983 / 33992    |      3258 |
| ses-witness        | 100.00 %| 100.00 %   |    87 / 87       |    87 / 87       |         — |
| annex-b-rejection  | 100.00 %| 100.00 %   |   142 / 142      |   142 / 142      |         — |
```

The `annex-b-rejection` row scores test262 fixtures that assert
Annex B features are *absent* under strict mode — see "Annex B
negative coverage" above. Target pass rate 100%; anything less
means Cynic accidentally implemented an Annex B feature.

Per-day `## History` rows pick up the same five columns plus
`Δ pass` and `elapsed`:

```
### 2026-05-25 — cynic `<sha>`, test262 `<sha>`

|                    | spec%   | attempted% | pass / total     | pass / attempted | divergent | Δ pass | elapsed |
|--------------------|---------|------------|------------------|------------------|----------:|-------:|--------:|
| runtime            | 92.90 % | 99.98 %    | 37241 / 40089    | 37241 / 37250    |         — |    ±0  |   35.6s |
| runtime_hardened   | 92.90 % | 99.97 %    | 37241 / 40089    | 33983 / 33992    |      3258 |    ±0  |   38.4s |
| ses-witness        | 100.00 %| 100.00 %   |    87 / 87       |    87 / 87       |         — |    ±0  |    0.2s |
| annex-b-rejection  | 100.00 %| 100.00 %   |   142 / 142      |   142 / 142      |         — |    ±0  |    0.5s |
```

`Δ pass` tracks the headline numerator (`pass + divergent` for
hardened), so:

- A real bug that flips one test from pass to fail: `Δ pass = -1`,
  `attempted%` drops too. Both signals move.
- An intentional SES policy change that shifts a fixture from
  real-fail to divergent (or vice versa): `Δ pass = 0`, `divergent`
  count shifts. The signal lives in the divergent-count delta.

Catch-all summary: a regression that's a *real* engine bug shows up
in `Δ pass` and `attempted%`; a regression that's a *policy* shift
shows up in the `divergent` column only.

## Legend additions

`## Legend` in `test262-results.md` picks up these entries:

- **divergent** (`runtime_hardened` only) — fixtures whose test262-
  written assertion conflicts with SES enforcement (frozen
  primordials, locked descriptors, non-extensible namespaces).
  The engine throws on the offending operation, which is correct
  under SES; the fixture's "expected pass" is invalidated. Counted
  separately from `fail`. See [docs/handbook/ses-test262-policy.md].
- **spec%** (`runtime_hardened`) — `(pass + divergent) / total`.
  Divergent counts as engine-correct because SES is part of the
  spec Cynic ships. Directly comparable to the `runtime` row.
- **attempted%** (`runtime_hardened`) — `pass / (pass + fail)`.
  Excludes divergent from both numerator and denominator. This is
  the real-engine-conformance gauge — drops on any genuine
  failure regardless of SES policy.
- **ses-witness** — curated subset of test262 fixtures whose
  "expected pass" was inverted to "expected TypeError under SES".
  Pass rate of 100% required; anything less means SES isn't
  enforcing what we claim. See
  [tools/test262/ses_witnesses.zig].
- **annex-b-rejection** — test262 fixtures that assert Annex B
  features are *absent* under strict mode (`String.prototype.
  substr === undefined`, `escape` not on globalThis, etc.).
  Pass rate of 100% required; anything less means Cynic
  accidentally implemented an Annex B feature. See
  "Annex B negative coverage" in
  [docs/handbook/ses-test262-policy.md] and the include-list
  in [tools/test262/skip.zig].

## CI floor implications

**Hardened is the primary gate** — Cynic ships hardened by default,
so a hardened regression is what matters most. The unhardened
floor stays as a continuity / catastrophic-regression safety net,
not as an optimisation target.

Replace `--min-hardened-spec-pct` (currently 84.0 — gating the raw
number) with three floors:

- `--min-hardened-spec-pct=<f>` — floor on the new adjusted
  `spec%` (`(pass + divergent) / total`). **Primary gate.** Set
  to match the unhardened floor (today 92.5) — they should
  track each other closely once divergence is properly
  classified. Tightened over time as the engine improves.
- `--min-ses-witness-pct=<f>` — floor on the witness pass rate.
  **Hard gate, 100.0.** A SES-witness regression means hardened
  mode isn't enforcing what we say it does — a correctness bug
  in SES itself, not a test262 score blip.
- `--min-annex-b-rejection-pct=<f>` — floor on the Annex B
  negative-coverage row (per "Annex B negative coverage"
  above). **Hard gate, 100.0.** A drop means Cynic accidentally
  shipped an Annex B feature.
- `--min-spec-pct=<f>` — floor on `runtime` (unhardened) row.
  Continuity gate. Set conservatively so a real catastrophic
  regression still trips it, but don't tighten ahead of
  hardened — engineering effort goes to hardened first.

CI workflow updates in lockstep — `.github/workflows/ci.yml`.
A PR that improves only `runtime` and leaves `runtime_hardened`
flat is still mergeable, but reviewers should ask whether the
fix is portable to hardened mode.

## Annex B negative coverage

Cynic targets strict-only, non-browser-host edge runtimes — Annex B
in its entirety is out (with the one acknowledged `B.1.4` regex
grammar exception). Today the harness path-skips the entire
`vendor/test262/test/annexB/` subtree, which loses an important
signal:

**Test262 has fixtures that assert Annex B features are *absent***.
A fixture under `annexB/built-ins/String/prototype/substr/…` that
asserts `String.prototype.substr` exists is correctly skipped.
But a fixture elsewhere asserting `String.prototype.substr ===
undefined` (or `typeof Date.prototype.getYear === 'undefined'`,
or that a sloppy-mode-only construct throws SyntaxError in strict
mode) **is exactly the test Cynic should pass**. Skipping it
means we can't tell from the score whether we accidentally
implemented an Annex B feature.

Audit deliverable in Phase 0:

- Walk `vendor/test262/test/annexB/` and classify each fixture by
  what it asserts:
  - **Presence** (the feature exists and behaves a certain way) —
    keep skipped under the current rule.
  - **Absence under strict mode** (Annex B feature throws / is
    undefined when running strict) — **unskip**. Cynic should
    attempt and pass these.
  - **Both** (frontmatter `flags: [onlyStrict]` or `flags:
    [noStrict]`) — split by flag. `onlyStrict` is strict-mode
    behaviour we should attempt; `noStrict` stays skipped.
- For fixtures *outside* `annexB/` that test Annex B absence
  (typed via the absence-asserting body), survey them too —
  some `built-ins/String/prototype/substr/…` fixtures may test
  the spec-strict behaviour that `substr` doesn't exist (need
  to check the frontmatter case-by-case).
- Produce the unskip list as a sidecar in `tools/test262/
  skip.zig` (a positive include-list overriding the blanket
  path skip for Annex B negative-asserting fixtures).

The unskipped set probably runs ~50-200 fixtures and confirms
the strict-only invariant against the test262 corpus directly.
Score reflected in a new row: **`annex-b-rejection`**, same
layout as `ses-witness`, target pass rate 100%.

Risk in unskipping: the audit needs to be careful to not
re-introduce *positive* Annex B fixtures (those that expect the
feature to work) into the active set. The Phase 0 audit's
deliverable is the include-list with a per-entry rationale.

## Skip-list audit (Phase 0 of the rollout)

Before the divergence work itself, audit the current skip list
(`tools/test262/skip.zig`). The list today mixes three rationales
under one mechanism, and only one of the three is permanent:

1. **Permanent OOS** — Annex B, intl402, harness/, staging/,
   browser-era built-ins (`escape`, `String.prototype` HTML
   wrappers, `Date.{getYear, setYear}`, etc.). These will *never*
   apply to Cynic's target. Strikethrough rows in the scoreboard
   make sense. Keep as-is.
2. **Stage maturity** — pre-Stage-4 proposals
   (`decorators`, `explicit-resource-management`, `ShadowRealm`,
   `import-defer`, …). These *might* ship later; today they'd
   drown the scoreboard in 0% rows. Skipping is right but the
   classification needs a rebuild — proposals advance, and
   `explicit-resource-management` / `import-attributes` /
   `Float16Array` / `Uint8Array.{fromBase64,…}` / Temporal have
   all moved to Stage 4 since the list was written. The audit
   re-checks each entry against [TC39 finished proposals](https://github.com/tc39/proposals/blob/main/finished-proposals.md)
   and downgrades anything Stage 4 from "stage maturity" to
   "planned".
3. **Planned (vendor/infra gap)** — Stage 4 features Cynic
   *should* ship but hasn't yet (Temporal, Float16Array,
   libregexp Annex B grammar, json-parse-with-source). Skipping
   them hides real work-to-do. Surface them as a separate
   **`## Planned features`** section in `test262-results.md`
   (parallel to the existing `## Pre-Stage-4 proposals shipped`
   block) showing each entry's fixture count and a one-line note
   on what's missing. Visible without polluting the headline.

Audit deliverable: a table in this doc under `## Audit results`
naming every current skip entry, the rationale category, and
(for Planned items) the implementation lead — what would need
to ship to unskip it. Most rows in the current "0 fails (passing
or wholly OOS)" tier should move into the new `## Planned
features` block.

## Per-bucket scoreboard under dual-mode

The existing `## Where the runtime stands, by area` table shows
one mode's numbers. With dual-mode + divergent reclassification,
extend it:

```
| area                 | runtime (pass / fail) | hardened (pass / fail / divergent) | spec% (runtime) | spec% (hardened) |
|----------------------|----------------------:|-----------------------------------:|----------------:|-----------------:|
| **_1–9 fails_** |
| `built-ins/RegExp`   |          1593 / 9     |                  1593 / 9 / 0      |             90% |              90% |
| **_real-fail in hardened only_** |
| `built-ins/Math`     |           327 / 0     |                   212 / 0 / 115    |            100% |              65% (adj) |
| ...                  |                       |                                    |                 |                  |
```

Three tiers in the dual-mode view, refining the existing
"1000+ / 100–999 / 10–99 / 1–9 / 0":

- **Real-fail buckets** (`pass / fail`, ignoring divergent — the
  "engine bugs" tier). Sorted by hardened-mode fail count, then
  unhardened. This is where work actually goes.
- **Divergence-only buckets** — buckets that pass 100% under
  unhardened but show divergent count under hardened. Visible
  but not a fix target.
- **Passing or wholly OOS** — strikethrough rows for permanent
  OOS, plain rows for fully-passing buckets.

The Planned-features block lives in its own section below the
main scoreboard, not interleaved (it'd visually conflict with
the strikethrough OOS rows).

## Phase plan

Each phase is independently mergeable, builds green, and is gated
on `zig build test` + the relevant filtered test262 smoke. Don't
land Phase 3 (the policy-shift) without Phase 0 + 1 + 2 (the
audits + infrastructure) landing first — the policy is hollow
without the fixture classification.

### Phase 0 — skip-list + Annex B audit (analysis only, no code)

Three audits packaged into one phase because they all walk the
same artifact (`tools/test262/skip.zig` + the corpus tree) and
inform the same downstream phases:

**0a. Stage-maturity vs Planned reclassification.** Walk every
entry in `tools/test262/skip.zig` against the current
[TC39 finished-proposals list](https://github.com/tc39/proposals/blob/main/finished-proposals.md).
For each:

- Confirm the rationale category (Permanent OOS / Stage
  maturity / Planned).
- For stage-maturity entries whose proposal has reached
  Stage 4, downgrade to Planned (e.g. `import-attributes`,
  `explicit-resource-management`, `Float16Array`,
  `Uint8Array.{fromBase64,…}`).
- For Planned entries, note the implementation lead — what'd
  need to ship to unskip.

**0b. Annex B negative-coverage scan.** Walk
`vendor/test262/test/annexB/` and (for thoroughness) any
`built-ins/<X>/prototype/<annexB-method>/…` paths outside it.
For each fixture, read the frontmatter + body and classify:

- *Positive* (asserts the Annex B feature works) — stays
  skipped.
- *Negative under strict mode* (asserts the feature is
  absent / throws under strict) — **unskip**, add to a
  positive include-list in `skip.zig`.
- *Mixed* (both flags) — split by `flags:` field.

Output: the unskip include-list with per-entry one-line
rationale.

**0c. Planned-features block sketch.** Produce the
`## Planned features` section for `test262-results.md` —
columns, sort order, narrative paragraph. Lands in Phase 5
but the shape gets agreed here.

Combined deliverable: the `## Audit results` table at the
bottom of this doc, naming every skip entry, its category,
the implementation lead (for Planned), and the Annex B
include-list count.

Risk: low — read-only. Test262 risk: zero.

### Phase 1 — divergence audit (analysis only, no code)

Walk the current ~3258 hardened-only failures from the latest
sweep. Group by stderr error message pattern. Propose categories.
Output: a markdown table in this doc under `## Audit results` —
column shape `(category, sample fixture, fixture count, proposed
treatment {divergent | witness | engine bug})`.

Pairs with Phase 0 (skip-list audit) — both land before any
code, both inform the column shape we commit to in Phase 5.

Risk: low — read-only. Test262 risk: zero.

### Phase 2 — divergence-list infrastructure

Implement `tools/test262/ses_divergent.zig` with the top 3
categories from Phase 1 (probably ≥80% of the delta). Wire
into the harness:

- `outcome` enum gains `divergent` variant.
- Hardened-phase classifier checks the divergence list before
  recording a `fail`.
- `Stats` gains a `divergent` counter.
- `printTally` + `writeResults` pick up the new column.

Audit step: run the hardened phase; confirm 80%+ of previous
fails reclassify as divergent. Score the remainder.

Risk: low (additive — failures only move into divergent, never
the reverse). Test262 risk: zero — unhardened path untouched.

### Phase 3 — witness inversion

Pick ~20 fixtures from the largest divergent category that match
the witness selection criteria above. Put them in
`tools/test262/ses_witnesses.zig` with their expected
exception class. Add witness-row scoring to the harness.

Verify: every witness passes (the engine threw the expected
exception). Anything else means SES is broken in a way we
didn't know about — fix it before landing.

Risk: medium — surfaces previously-invisible SES gaps. Test262
risk: zero.

### Phase 4 — Cynic-authored SES tests

Add `tests/ses/*.js` with ~30 hand-written tests covering:

- Override-mistake fix corner cases (accessor demotion, shadowing
  rules, redefinition over a synthetic accessor pair).
- `harden()` invariants on cyclic graphs, mixed proto chains.
- `--unhardened` round-trip — confirm the flag fully disables.
- Frozen-globalThis edge cases.

Route through the harness as `--phase=ses-positive`. Score row:
`ses-cynic-witness`.

Risk: low. Test262 risk: zero (not from test262).

### Phase 5 — re-baseline + CI + scoreboard reshape

- Refresh `test262-results.md` rows with the new column shape
  (Layout A: dual-mode rows with `divergent` column).
- Reshape the per-area scoreboard to the dual-mode tiering
  described under "Per-bucket scoreboard under dual-mode" above.
- Add the new `## Planned features` section per Phase 0's
  sketch — fixture counts for each Stage-4-but-unshipped feature
  (Temporal, Float16Array, etc.).
- Update legend.
- Update `--min-hardened-spec-pct` floor to track the adjusted
  number (~92.5).
- Add `--min-ses-witness-pct=100.0` to CI.
- Update AGENTS.md flag table.

Risk: low — bookkeeping. Test262 risk: zero.

### Phase 6 — corpus-update protocol

Document the bump protocol in [`docs/handbook/agent-checks.md`]:
when running `/bump-test262`, the divergent-count delta is now a
review signal alongside `Δ pass`. A jump in divergent count on a
corpus bump means a new bucket of fixtures hit SES rules that
nobody categorised — add them to `ses_divergent.zig` (with a
comment) before landing the bump.

## Open questions to settle during implementation

1. **Divergence-list authoring style**: by-path glob or
   by-error-message pattern? Per-path is easier to audit but
   brittle on test262 file moves; per-message is robust but
   harder to grep.
   - **Lean**: by-path glob, with a comment naming the category +
     spec section. Periodic bump regenerates the list from a
     scripted re-classification pass.

2. **Should divergent fixtures stay in `total`** or drop out
   entirely (Annex B pattern)?
   - **Lean**: stay in `total`. Removing them from total makes
     corpus-update detection harder (a new divergent fixture would
     vanish silently). Layout A's column math expects them in
     `total`.

3. **Witness inversion mechanism**: sidecar JSON file, Cynic-
   specific frontmatter, or a Zig table?
   - **Lean**: Zig table (`ses_witnesses.zig`). Type-checked,
     in-repo, no extra parser. Path → enum exception class.

4. **CI floors for `attempted%`**: do we also floor
   `attempted%` (the real-engine-conformance gauge)?
   - **Lean**: yes — `--min-hardened-attempted-pct=99.9`. A floor
     on attempted% catches engine bugs that aren't masked by SES
     enforcement. Cheap, low false-positive rate.

5. **Per-category sub-counts in the divergent column**: show just
   the total (e.g. `3258`) or break down (e.g.
   `3258 [name=1700 length=900 …]`)?
   - **Lean**: just the total in the row; per-category breakdown
     in a separate "Divergence breakdown" section below
     `## Current scores`. Same shape as the existing "Where the
     runtime stands, by area" block.

6. **Versioning the divergence list when test262 corpus bumps**:
   regenerate vs. preserve-and-diff.
   - **Lean**: preserve-and-diff — every divergent entry is a
     deliberate categorisation. A corpus bump that surfaces new
     divergent fixtures lands a separate PR adding them, reviewed
     line-by-line.

## What this is NOT

- Not a contribution-back to upstream test262. That's a separate
  TC39/SES-working-group effort, on a separate timeline.
- Not a replacement for the existing `runtime` row. The legacy
  baseline stays exactly as it is — unchanged column shape,
  unchanged scoring math, unchanged floor.
- Not blocking on lazy-bag Phase 3 — orthogonal work.
- Not a new test262 mode (we still use `--mode=runtime` for both).
  This is policy on top of an existing mode.

## Audit results

### Phase 0a — skip-list reclassification (2026-05-26)

Cross-referenced [TC39 finished-proposals.md](https://github.com/tc39/proposals/blob/main/finished-proposals.md)
against `tools/test262/skip.zig`. One mis-classification surfaced;
the rest were already correct.

**Mis-classified — needs downgrade from Stage maturity to Planned:**

| Feature | Current bucket | TC39 status | Lead |
|---|---|---|---|
| `explicit-resource-management` | `skip_stage_maturity_features` | **Stage 4** (per finished-proposals.md, expected publication 2027) | Needs `using` / `await using` grammar in the parser, plus the four built-ins: `DisposableStack`, `AsyncDisposableStack`, `SuppressedError`, and Symbol.dispose / Symbol.asyncDispose. ~478 fixtures. |

**Already correctly classified as Planned (Stage 4, Cynic doesn't ship yet):**

| Feature / Path | Fixture count |
|---|---:|
| `Temporal` (path `built-ins/Temporal/`) | 4588 |
| `explicit-resource-management` (after downgrade above) | 478 |
| `import-attributes` (feature tag) | 100 |
| `Uint8Array.{fromBase64, toBase64, fromHex, toHex}` (`built-ins/Uint8Array/`) | 68 |
| `Float16Array` (feature tag) | 62 |
| `json-parse-with-source` (feature tag) | 22 |
| `json-modules` (feature tag) | 13 |
| `regexp-duplicate-named-groups`, `regexp-modifiers`, unicodeSets `\q{}` / property-of-strings / set-difference / etc. (libregexp gaps) | varies |

Total currently-Planned fixture exposure: **≈ 5350 fixtures** dominated
by Temporal. These all get a row in the new `## Planned features`
block per Phase 0c below.

**Correctly classified as Stage maturity (still pre-Stage-4):**

| Feature | TC39 stage |
|---|---|
| `decorators` | Stage 3 |
| `import-defer` | Stage 3 |
| `source-phase-imports` | Stage 3 |
| `import-bytes` | Stage 3 |
| `immutable-arraybuffer` | Stage 2.7 |
| `await-dictionary` | Stage 2 |
| `ShadowRealm` (path) | Stage 2.7 (67 fixtures) |

**Already shipped natively** (no skip needed, scoring as expected):

`Array.fromAsync`, `Error.isError`, `Promise.try`, `RegExp.escape`,
`Math.sumPrecise`, `Iterator.concat` (iterator-sequencing). One
follow-up note: `upsert` reached Stage 4 in January 2026 — the
in-code comment `Stage 3 as of 2026-05` in
`src/runtime/builtins/iterator.zig:67` and `src/runtime/builtins/
collections.zig` is stale. Currently the feature ships behind
`--enable=upsert`; decide separately whether to flip it on by
default and graduate the row out of `## Pre-Stage-4 proposals
shipped`. Same call for `joint-iteration` (still Stage 3 per
2026-05).

### Phase 0b — Annex B negative-coverage scan (2026-05-26)

Walked `vendor/test262/test/annexB/` and classified fixtures
with `negative:` frontmatter against their `flags:` field.

| Fixture | flags | type | Treatment |
|---|---|---|---|
| `annexB/language/statements/for-in/strict-initializer.js` | `[onlyStrict]` | parse SyntaxError | **Unskip** — strict-mode rejection test |
| `annexB/language/expressions/template-literal/legacy-octal-escape-sequence-strict.js` | `[onlyStrict]` | parse SyntaxError | **Unskip** — strict-mode rejection test |

**Net Annex B unskip: 2 fixtures.** Both are pure strict-mode-
rejection tests — exactly the positive coverage we want. The
remaining ~1084 fixtures under `annexB/` test the *positive*
Annex B surface (which Cynic doesn't ship); keeping them skipped
is correct.

Cross-check outside `annexB/`: **268 strict-only fixtures** under
`vendor/test262/test/language/` already get attempted and pass.
None are over-skipped by the `skip_annex_b_features` rule
(verified: zero overlap between strict-only fixtures and
fixtures tagged `__getter__` / `__setter__` / `__proto__` /
`legacy-regexp` / `IsHTMLDDA`).

**Cynic-authored negative coverage gap:** test262 doesn't include
fixtures of the form `typeof String.prototype.substr ===
'undefined'` (the spec doesn't mandate absence of Annex B in
non-browser hosts — Annex B is normative *for* browsers,
optional elsewhere). For positive proof that Cynic doesn't ship
these features by accident, Phase 4 of this plan adds
hand-written tests under `tests/ses/annex-b-rejection/` with
the same scoring shape as the SES witnesses. Estimated ~40
hand-written assertions (one per Annex B method we deliberately
don't ship: `substr`, HTML wrappers, `escape`/`unescape`,
`getYear` / `setYear` / `toGMTString`, `__proto__` accessor,
`__define{Getter,Setter}__` / `__lookup{Getter,Setter}__`,
`RegExp.$1` legacy globals, for-in initializer in sloppy, etc.).

### Phase 0c — Planned features block sketch (2026-05-26)

Proposed `## Planned features` section for `test262-results.md`,
sorted by fixture count descending (biggest gap surface first):

```markdown
## Planned features

Stage 4 ECMAScript features Cynic doesn't yet ship. Each entry's
fixtures are excluded from the headline `total` (same mechanism
as the `## Pre-Stage-4 proposals shipped` block — feature-tagged
or path-skipped). Once a feature lands, its row migrates from
here into the per-area scoreboard above. Counts come from the
current `vendor/test262/` corpus.

| feature | fixtures | implementation lead |
|---|---:|---|
| **Temporal** | 4588 | The Temporal global — Calendar / TimeZone / Instant / PlainDate / PlainTime / ZonedDateTime + the full §22 API. Large; an entire bucket of engineering. |
| **explicit-resource-management** | 478 | `using` / `await using` grammar + `DisposableStack`, `AsyncDisposableStack`, `SuppressedError`, `Symbol.dispose` / `Symbol.asyncDispose`. |
| **import-attributes** | 100 | `import x from "./y.json" with { type: "json" }` syntax + the JSON-module resolver back-end. Pair with json-modules below. |
| **Uint8Array.{from,to}{Base64,Hex}** | 68 | `Uint8Array.fromBase64` / `.fromHex` / `.prototype.{set,to}{Base64,Hex}`. Pure data-conversion methods on the TypedArray surface. |
| **Float16Array** | 62 | IEEE 754 binary16 conversion + the TypedArray ctor + `Math.f16round` + `DataView` half-float accessors. |
| **json-parse-with-source** | 22 | `JSON.parse` reviver's second arg carries `{ source }` for the original JSON span. Needs per-value source spans through the parse tree. |
| **json-modules** | 13 | `import data from "./x.json"` returning the parsed JSON value. Pair with import-attributes above. |
| **libregexp Annex B / `/v` gaps** | varies | Vendored libregexp doesn't implement ES2024 `/v` set-difference / `\q{…}` / property-of-strings, `regexp-modifiers`, or `regexp-duplicate-named-groups`. Either patch the matcher or switch regex engines. |
```

Open question for implementation: do we add an `attempt-on-bump`
flag to a Planned entry, so that when we ship the underlying
feature we can flip the skip off in one step? Lean: yes — a
boolean `ready_to_attempt` per entry, defaulting false, lets
the audit row read "shipped — pending unskip" before flipping
the feature flag.

### Phase 1 — divergence audit (2026-05-26)

Walked the **3093 hardened-only failures** from a full sweep at
`f48b7b0` (`./zig-out/bin/cynic-test262 --quiet --phase=main
--list-failures=5000`). Canonicalised each failure message
(stripped fixture paths, `Testing with X` typed-array sub-test
suffixes, `'<KEY>'` property-name interpolations) and grouped
by unique pattern.

The 3093 failures break down across **five buckets**:

#### Bucket A — propertyHelper descriptor assertions (1453 fixtures, divergent)

The test262 `propertyHelper.js` assertion library compares an
own descriptor against an expectation table. Under SES the
descriptors are locked (`writable: false`, `configurable: false`
on all intrinsic methods) so these assertions fail wholesale.

| Pattern | Count | Treatment |
|---|---:|---|
| `obj['<KEY>'] descriptor should be configurable` | 857 | divergent |
| `obj['<KEY>'] descriptor should be writable; obj['<KEY>'] descriptor should be configurable` | 396 | divergent |
| `desc.writable Expected SameValue(«false», «true») to be true` | 109 | divergent |
| `desc.value Expected SameValue(«undefined», «[object Function]») to be true` | 54 | divergent (synthetic accessor demoted what the fixture expected as a data slot) |
| `obj['<KEY>'] descriptor should not be writable; obj['<KEY>'] descriptor should be configurable` | 13 | divergent |
| `Expected true but got false` | 10 | divergent (small set; pattern matches a `propertyHelper.isWritable(…)` true-expected check) |
| `Expected obj[constructor] to have writable:true.` | 9 | divergent (the back-edge constructor on each prototype is frozen-data) |
| `desc.configurable Expected SameValue(«false», «true») to be true` | 5 | divergent |

Treatment: **all 1453 → divergent.** Detect via path-glob — every
`built-ins/<X>/{name,length,prop-desc,*-desc}.js` fixture and the
generic `built-ins/<X>/prototype/<method>/length.js` /
`name.js` / `prop-desc.js` family.

#### Bucket B — engine TypeErrors from SES enforcement (~1300 fixtures, divergent)

The engine correctly threw on a frozen-primordial mutation
attempt; the fixture expected the mutation to succeed.

| Pattern | Count | Treatment |
|---|---:|---|
| `Cannot add property, object is not extensible` (with trailing-space variants) | 336 | divergent |
| `Cannot assign to read-only property` (with trailing-space variants) | 306 | divergent |
| `Object.defineProperty: object is not extensible` (with trailing-space variants) | 228 | divergent |
| `Cannot extend non-writable array length` | 107 | divergent |
| `Cannot delete non-configurable property` | 107 | divergent |
| `Cannot redefine non-configurable property on frozen prototype` | 105 | divergent |
| `Cannot define index past the length of a non-writable-length array` | 91 | divergent |
| `Object.defineProperty: cannot redefine non-configurable property` (with trailing-space variants) | 28 | divergent |
| `Built-in objects must be extensible. Expected SameValue(«false», «true») to be true` | 7 | divergent (the assertion *literally* says built-ins must be extensible, which SES contradicts on purpose) |

Treatment: **all → divergent.** Detect via engine-error-class
match (Cynic stamps a known TypeError message string from one
of a small set of `throwTypeError(…)` call sites in the SES
freeze enforcement path; bucket-by-substring is robust).

A subset of these (~50–100, candidates: the freeze-rejection
`Cannot add property` + `Cannot assign to read-only property`
ones whose body is short and whose sole assertion is the
SES-divergent invariant) make natural **SES witnesses** —
invert the expectation, expect-the-TypeError, count them as
positive proof SES is enforcing. Phase 3 selects the curated
subset.

#### Bucket C — Synthetic-accessor side effects (133 fixtures, divergent)

Phase 3 of SES demotes prototype data slots to synthetic
accessor pairs. Tests that introspect via `Function.prototype.
toString` or ToPrimitive on the prototype method object see the
accessor instead of the data slot.

| Pattern | Count | Treatment |
|---|---:|---|
| `Cannot convert function to primitive value` | 123 | divergent (ToPrimitive on a synthetic-accessor-wrapped function via the prototype chain) |
| `Conforms to NativeFunction Syntax: "undefined"` | 10 | divergent (`Function.prototype.toString` on the synthetic accessor returns `"undefined"` instead of native-code syntax) |

Treatment: **all → divergent.** Detect via the two distinctive
error-message patterns above.

#### Bucket D — Engine-bug candidates (~80 fixtures, needs investigation)

Failures that do NOT match the SES divergence pattern. Each
is a candidate engine bug or a subtle SES-Phase-3 interaction
that should NOT happen.

| Pattern | Count | Likely cause | Treatment |
|---|---:|---|---|
| `iterator.next is not callable` | 65 | All cluster on `Set.prototype.{intersection,union,difference,…}` (set-method proposal) + `Iterator.{concat,zip}` (iterator-sequencing). Under hardened mode the `[Symbol.iterator]` getter dispatch + custom `.next` install via the receiver appears to drop the function. **Likely synthetic-accessor regression** — needs root-cause investigation. | **engine bug** |
| `Expected a Test262Error but got a TypeError` | 9 | The fixture's `Test262Error.thrower` setup doesn't fire because some earlier SES TypeError already kicked in (often `throw new Test262Error(…)` where the Test262Error constructor was mutated by the test prelude — SES-frozen `Test262Error.prototype` likely the cause). | divergent (assertion library side effect) |
| `Expected a TypeError to be thrown but no exception was thrown at all` | 3 | Two `language/global-code/script-decl-{var,func}-err.js` test that `var X` / `function X` declaration throws when `X` is already a non-configurable own property of globalThis. Under SES, Cynic's `canDeclareGlobalVar` / `canDeclareGlobalFunction` deliberately skip the extensibility check (per `commit 3a4be3c` — "Top-level `var x = 1` keeps working under the SES posture"). | divergent (intentional SES design — top-level declarations carve-out) |

Treatment: **65 engine bugs go on a triage list** (Phase 2
investigates the synthetic-accessor + iterator interaction);
the rest are divergent with specific carve-out rationales.

#### Bucket E — Generic assertion failures (~80 fixtures, mixed)

Catch-all patterns that need per-fixture inspection. Most are
likely divergent (assertion-library side effects of SES
TypeError leakage), but each needs a single-fixture look to
confirm.

| Pattern | Count | Lean |
|---|---:|---|
| `b Expected SameValue(«true», «false») to be true` | 44 | likely divergent |
| `e Expected SameValue(«false», «true») to be true` | 18 | likely divergent |
| `arr[0] Expected SameValue(«undefined», «12») to be true` | 4 | needs inspection |
| `value is not callable` | 7 | needs inspection |

Treatment: **case-by-case in Phase 2.** Expected outcome:
~75 divergent, ~5 engine bugs (small).

#### Headline numbers

- **Total hardened-only failures**: 3093.
- **Divergent (clearly intentional SES enforcement)**: ~2960 (96%).
- **Engine-bug candidates** (`iterator.next is not callable`
  cluster): **65** (2%).
- **Needs case-by-case inspection**: ~68 (2%).

The 65 `iterator.next` failures are the **headline finding**.
They cluster on Set-method-proposal and Iterator-helpers
fixtures — both of which Cynic ships natively and which pass
under unhardened mode. The hardened-mode regression points
at a Phase-3 synthetic-accessor interaction with iterator
dispatch. Phase 2's first concrete action: reproduce one of
these fixtures under `cynic run --debug-globals` and trace.

#### Implications for Phase 2 / Phase 3

- The divergence list (Phase 2) needs **at minimum 4 categories**:
  - `descriptor_assertion` — propertyHelper descriptor mismatches.
  - `frozen_intrinsic_typeerror` — engine TypeError from SES.
  - `synthetic_accessor_introspection` — ToPrimitive / toString
    on accessor-demoted methods.
  - `intentional_design_carveout` — Cynic's deliberate SES
    relaxations (top-level `var`, etc.).
- The witness inversion candidates (Phase 3) come predominantly
  from `frozen_intrinsic_typeerror` — shortest fixtures whose
  sole assertion is "mutation succeeded".
- The 65 iterator-bug investigation is a **Phase 2 prerequisite** —
  shipping the divergence-list infrastructure with a known engine
  bug masked inside it is the failure mode the whole policy is
  designed to prevent.
