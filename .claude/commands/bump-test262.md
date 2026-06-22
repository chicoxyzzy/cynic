---
description: Update vendor/test262 submodule to upstream HEAD, rerun, score, report (do not commit)
---

Bump the test262 corpus to upstream HEAD and produce fresh score rows.

1. Capture the current submodule SHA:
   `git -C vendor/test262 rev-parse HEAD`.

2. Fetch and update:
   `git -C vendor/test262 fetch origin main`
   `git -C vendor/test262 checkout origin/main`.

3. Show the new SHA and the number of intervening commits
   (`git -C vendor/test262 rev-list <old>..<new> --count`).

4. Leak-check first — a filtered runtime sweep with `--top-rss`
   (see `.claude/commands/score.md` step 1). If per-fixture RSS
   deltas are unhealthy, STOP and report; do not proceed.

5. Run the sweep with `--write-results` — one invocation covers
   `runtime` + `runtime_hardened` rows + every pre-Stage-4 feature
   phase, and parse-negative fixtures resolve inline:

       tools/guarded-run.sh --timeout=1800 -- \
         zig build test262 -- --quiet --write-results

   If the local laptop-melt hook trips (`Full test262 sweep /
   bench — do not run locally`), submit to the remote box —
   see [.claude/commands/score.md](score.md) step 2 "Local hook
   blocked?" for the submit/poll/scp recipe. Important: with a
   fresh corpus the remote will pick up the new `vendor/test262`
   SHA on its `git checkout`, so push the bump commit first
   (`git push origin HEAD:<branch>`) and submit against that ref
   rather than `origin/main`.

6. Show the score delta vs the prior row (now on the new corpus).
   Call out any per-bucket movers that look like new-test arrivals
   vs real regressions — new fixtures from upstream often show up
   as fresh failures even though nothing in Cynic changed.

7. Run `git status` to confirm only `vendor/test262` and
   `test262-results.md` are modified. Do **not** commit.

If any step fails, stop and report which step and why. The bump
should be a deliberate PR with the resulting score rows, per
[docs/ROADMAP.md](../../docs/ROADMAP.md) M3.
