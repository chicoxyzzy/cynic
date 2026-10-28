# Score test262 conformance

Refresh the current score and history using the harness, then report the delta.
The scored posture is `--unhardened --allow=eval`; proposal sweeps remain
separate. Parse-negative fixtures resolve inline, not in a parser-only run.

1. Read the current row in `test262-results.md` and note the corpus revision
   with `git -C vendor/test262 rev-parse HEAD`.
2. Run the required memory precheck:

   ```sh
   zig build test262 -- --quiet --filter=language/expressions --top-rss=10
   ```

   Healthy per-fixture RSS deltas are at most about 20 MiB for this bucket
   (about 50 MiB for `built-ins/TypedArray`). If they are unexpectedly high,
   stop and investigate before a full sweep. Do not use the build process's
   peak RSS as a substitute for the per-fixture measurements.
3. Run the full main sweep and tracked proposal sweeps:

   ```sh
   tools/guarded-run.sh --timeout=1800 -- \
     zig build test262 -- --quiet --write-results
   ```

   Do not use `--only-failing` to establish a score or absence of regressions.
   The harness owns the score format and history update. See
   [regression checks](../handbook/agent-checks.md).
4. Compare the updated main row with the prior row: passing, failing, total,
   pass percentage, and changes in passing and pass percentage. Report proposal
   results separately. Explain corpus or posture changes before comparing rows.
5. Review `git diff -- test262-results.md` and report the actual results and
   any new failures. Do not commit.

## Optional remote execution

When local resource policy prevents the run, or a configured remote is more
suitable, follow [the remote-runner instructions](../../tools/bench/README.md).
Submit the intended published revision, not an unrelated `origin/main`:

```sh
JOB=$(tools/bench/remote-run.sh --submit <published-ref> \
  zig build test262 -- --quiet --write-results)
tools/bench/remote-run.sh --wait "$JOB"
```

The remote does not include local uncommitted edits. Do not commit or push them
without approval just to run this workflow. After a successful run, inspect
its revision and log, then retrieve the results using the configured
`CYNIC_REMOTE` and `CYNIC_REMOTE_DIR`. Preserve any local result edits before
applying the remote output. With no remote configured, use an appropriate local
machine or report the resource limitation; no client-specific hook is assumed.
