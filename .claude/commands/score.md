---
description: Run test262 (parser + runtime), append rows to test262-results.md, show delta vs prior row
---

Score current test262 conformance and update the score history.
Today the meaningful signal is the **runtime** row (parser has been
at 100 % attempted for a while); we still capture both.

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

2. Runtime sweep (default mode — includes main + every pre-Stage-4
   feature phase in one invocation, populating the per-feature
   scoreboard alongside the main row):

       tools/guarded-run.sh --timeout=1800 -- \
         zig build test262 -- --quiet --write-results

3. Parser sweep — `zig build test262 -- --quiet --mode=parser
   --write-results`.

4. Read the last two rows for each mode in `test262-results.md`
   (the freshly appended ones and the rows above them).

5. Report per mode:
   - Current score: `pass / total (spec%, attempted%)`.
   - Delta vs prior row: `Δ pass`, `Δ spec%`, `Δ attempted%`.
   - False-reject count + delta (parser mode).
   - False-accept count + delta (parser mode).
   - Top movers (the "Biggest movers" sub-list from the runtime
     row, if present).

Do **not** commit. Just print the summary.
