---
description: Run the Phase 1 micro-bench suite; report wall-time medians per fixture
---

Measure Cynic's per-fixture wall-time + peak RSS on the
hand-picked micro-bench suite in `bench/micros/` and report the
table. Use this before/after a perf-shaped change to confirm a
regression or speed-up.

1. Run `zig build bench`. This builds a dedicated ReleaseFast
   `zig-out/bin/cynic-bench` binary (the default Debug build is
   5-10× slower and gives misleading numbers) and runs the
   driver against the suite in `bench/micros/`.
2. Capture the table the driver prints — one row per fixture with
   `median_ms`, `min_ms`, `max_ms`, `rss_kb` (median of 10 runs
   after a discarded warmup; matched with `tools/bench-cross.sh`
   per [`docs/benchmarking.md`](../../docs/benchmarking.md)
   §Measurement protocol).
3. If `bench-results.md` exists, look up the previous row for the
   same hostname / OS line, diff each fixture, and call out
   anything that moved ≥5% in either direction.
4. Print the table verbatim. If the user asks to record a new
   baseline, append a fresh `### <date> — cynic <sha>, host
   <uname>` section to `bench-results.md` (mirror the
   test262-results.md row pattern).

Do **not** commit. Just print the summary.

Caveats: numbers are only stable on a quiet machine. Cross-machine
comparison is meaningless. Cross-engine comparison is Phase 2
(jsvu + eshost-cli — see `docs/benchmarking.md`).
