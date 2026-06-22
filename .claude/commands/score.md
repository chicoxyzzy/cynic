---
description: Run test262 runtime sweep, append rows to test262-results.md, show delta vs prior row
---

Score current test262 conformance and update the score history.
The harness runs parse + compile + execute in one mode — parse-
negative fixtures (`negative.phase: parse` in frontmatter) resolve
inline at their parse phase, so there's no separate parser-only
sweep to run.

1. Leak-check first. Confirm the heaviest per-fixture RSS deltas
   are in the healthy band on a filtered sweep before kicking off
   a full one:

       zig build test262 -- --quiet \
         --filter=language/expressions --top-rss=10

   Healthy: top deltas ≤ ~20 MiB on `language/expressions`, ≤ ~50 MiB
   on `built-ins/TypedArray`. If deltas climb noticeably above that,
   STOP — bisect recent commits with the same `--top-rss` filter; do
   not start the full sweep. Do NOT use `/usr/bin/time -l` —
   it measures `zig build`'s RSS (~1 GB during link), not the
   harness.

2. Runtime sweep (includes main + every pre-Stage-4 feature phase
   in one invocation, populating the per-feature scoreboard
   alongside the main row, plus the `runtime` + `runtime_hardened`
   rows):

       tools/guarded-run.sh --timeout=1800 -- \
         zig build test262 -- --quiet --write-results

   **Local hook blocked?** If the command returns
   `Full test262 sweep / bench — do not run locally (it melts the
   laptop)`, submit it to the configured remote box instead — the
   job is detached and survives a local restart:

       JOB=$(tools/bench/remote-run.sh --submit origin/main \
           'zig build test262 -- --quiet --write-results')
       # status echoes "running" while live, exit code when done
       until s=$(tools/bench/remote-run.sh --status "$JOB"); \
           [ "$s" != running ]; do sleep 30; done
       # pull the refreshed files back
       . tools/bench/lib-remote.sh; load_remote
       scp -q "$CYNIC_REMOTE:$CYNIC_REMOTE_DIR/test262-results.md" .
       scp -q "$CYNIC_REMOTE:$CYNIC_REMOTE_DIR/.test262-pass-cache.txt" .

   See [tools/bench/README.md](../../tools/bench/README.md) "Remote
   (optional)" for setup; with no remote configured the local block
   is the floor — re-run on an idle machine.

3. Read the last two rows in `test262-results.md` (the freshly
   appended one and the row above it).

4. Report:
   - Current score: `pass / total (spec%, attempted%)` for both
     the `runtime` and `runtime_hardened` rows.
   - Delta vs prior row: `Δ pass`, `Δ spec%`, `Δ attempted%`.
   - False-reject + false-accept counts (parse-positive /
     parse-negative columns in the harness output).
   - Top movers (the "Biggest movers" sub-list from the row, if
     present).

Do **not** commit. Just print the summary.
