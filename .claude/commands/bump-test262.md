---
description: Update vendor/test262 submodule to upstream HEAD, rerun, score, report (do not commit)
---

Bump the test262 corpus to upstream HEAD and produce a fresh score row.

1. Capture the current submodule SHA:
   `git -C vendor/test262 rev-parse HEAD`.
2. Fetch and update:
   `git -C vendor/test262 fetch origin main`
   `git -C vendor/test262 checkout origin/main`.
3. Show the new SHA and the number of intervening commits
   (`git -C vendor/test262 rev-list <old>..<new> --count`).
4. Run `zig build test262 -- --quiet --write-results`.
5. Show the score delta vs the prior row (which is now on the new
   corpus).
6. Run `git status` to confirm only `vendor/test262` and
   `test262-results.md` are modified. Do **not** commit.

If any step fails, stop and report which step and why. The bump
should be a deliberate PR with the resulting score row, per
[docs/ROADMAP.md](../../docs/ROADMAP.md) M3.
