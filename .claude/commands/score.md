---
description: Run test262 (parser + runtime), append rows to test262-results.md, show delta vs prior row
---

Score current test262 conformance and update the score history.
Today the meaningful signal is the **runtime** row (parser has been
at 100 % attempted for a while); we still capture both.

1. Leak-check first. Confirm peak RSS is in the healthy band on a
   filtered sweep before kicking off a full one:

       /usr/bin/time -l timeout 300 zig build test262 -- --quiet \
         --mode=runtime --filter=language/expressions

   Healthy: ≤ 100 MB peak, ≤ 10 s. If RSS climbs noticeably above
   that, STOP — bisect recent commits with the same harness; do
   not start the full sweep.

2. Parser sweep — `zig build test262 -- --quiet --write-results`
   (parser is the default mode).

3. Runtime sweep — `zig build test262 -- --quiet --write-results
   --mode=runtime`. Wrap in `timeout 1800` if the laptop is slow.

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
