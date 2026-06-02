# test262 scoring policy (superseded)

> **Status: retired.** The multi-posture, policy-classified test262
> scoring this document used to describe has been replaced by a
> **single-posture, binary pass/fail** model. This page is kept because
> other files still link to it; the sections below describe what
> changed and where the logic lives now.

## What the harness does today

The test262 harness (`tools/test262.zig`) scores every fixture as a
plain **pass** or **fail** under one posture: **`--unhardened
--allow=eval`** (`realm.hardened = false`, `realm.allow_eval = true`).

- **`pass%` = `passing / (passing + failing)`.**
- There is **no "expected fail" / "correctly handled"
  reclassification.** An Annex B, no-Intl, strict-only, SES, or eval
  miss counts as a plain `failing`, exactly like an engine bug. The
  number is honest, not flattering.
- There is **no in-corpus "skip" bucket** and **no SES witness side
  channel.** The `tools/test262/ses_witnesses.zig` and
  `tools/test262/ses_divergent.zig` classifiers have been removed.

Excluded from the denominator (not "skipped" — simply not part of the
scored corpus):

- the upstream `harness/`, `staging/`, and `annexB/` path prefixes
  (`tools/test262/skip.zig` → `corpus_excluded_prefixes`);
- pre-Stage-4 proposals — unshipped (decorators, import-defer, …) via
  `skip.zig` → `featureIsUnimplementedProposal`, and shipped
  (joint-iteration, ShadowRealm) via the harness's per-phase
  feature-tag gate, scored separately in `## Pre-Stage-4 proposals
  shipped`;
- structurally-unrunnable fixtures (no / malformed frontmatter).

## Why the change

The policy/witness model answered "how well does Cynic implement the
spec *it has chosen to ship*" — it counted a deliberate refusal (no
Annex B, no Intl, eval off, an SES throw) as spec-correct. That made
the headline ~98–99 % but was hard to reason about: five priority-
ordered policy buckets, a hardened vs unhardened vs `--allow=eval`
three-row table, a curated witness-inversion floor, and a runtime
error-pattern matcher.

The binary model trades that headline for legibility: one posture, one
number, every fixture pass or fail. The engine itself is **unchanged**
— it is still SES-hardened by default (`cynic run`); only how the
test262 *score* is computed changed. The hand-written SES
positive-coverage suite (`zig build test-ses`, fixtures under
`tests/ses/`) still proves the hardened posture enables what it should.

## Floors / CI

A single floor gates the run: `--min-pass-pct=<f>` (exit 2 below it,
skipped under `--filter=`). CI wires it at the published baseline. The
former `--min-spec-pct` / `--min-hardened-spec-pct` /
`--min-ses-witness-pct` flags are gone.

See [AGENTS.md](../../AGENTS.md) "Build & test" and
[../ses-alignment.md](../ses-alignment.md) for the current picture.
