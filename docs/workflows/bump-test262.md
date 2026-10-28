# Update the test262 corpus

Update the corpus and measure the resulting score without committing.

1. Inspect the submodule's working tree and current SHA:

   ```sh
   git -C vendor/test262 status --short
   git -C vendor/test262 rev-parse HEAD
   ```

   Preserve local edits; do not switch the submodule revision if they would
   be lost or conflict with the update.
2. Fetch and select upstream:

   ```sh
   git -C vendor/test262 fetch origin main
   git -C vendor/test262 checkout --detach origin/main
   ```

   Report the old/new SHA and `git -C vendor/test262 rev-list <old>..<new> --count`.
3. Follow [Score](score.md), including its memory precheck and full
   `--write-results` run. If remote execution is needed, the selected ref must
   contain the new gitlink; report that prerequisite rather than committing or
   pushing the bump without approval.
4. Follow the [corpus-bump regression protocol](../handbook/agent-checks.md#corpus-bumps):
   account for denominator changes, compare exact pass sets, distinguish new
   fixtures from regressions, and inspect isolated proposal scores.
5. Review the diff and report the corpus change and score delta. The expected
   updates are `vendor/test262` and `test262-results.md`; leave unrelated edits
   alone. Do not commit.

If a step fails, report where and why. A corpus bump should land as a deliberate
PR with its measured results, not an unverified submodule update.
