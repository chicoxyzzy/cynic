---
description: Update vendor/test262 submodule to upstream HEAD, rerun parser + runtime, score, report (do not commit)
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

5. Run both modes with `--write-results`:
   - `timeout 1800 zig build test262 -- --quiet --write-results`
   - `timeout 1800 zig build test262 -- --quiet --write-results
     --mode=runtime`

6. Show the score delta vs the prior row for each mode (which is
   now on the new corpus). Call out any per-bucket movers that
   look like new-test arrivals vs real regressions — new fixtures
   from upstream often show up as fresh failures even though
   nothing in Cynic changed.

7. Run `git status` to confirm only `vendor/test262` and
   `test262-results.md` are modified. Do **not** commit.

If any step fails, stop and report which step and why. The bump
should be a deliberate PR with the resulting score rows, per
[docs/ROADMAP.md](../../docs/ROADMAP.md) M3.
