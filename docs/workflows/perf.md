# Measure performance

Use same-host measurements before and after a performance change. Follow
[the measurement protocol](../benchmarking.md#measurement-protocol); use a
quiet machine or a configured [remote runner](../../tools/bench/README.md).

1. Run `zig build bench`. It builds the dedicated optimized benchmark binary;
   do not substitute a Debug CLI build. Run `zig build bench -- --no-jit`
   separately when comparing the production JIT posture with Lantern.
2. Capture the complete table, including `p50_ms`, `min_ms`, `max_ms`,
   `spread%`, outliers, and RSS. Keep the sample count, host, revision,
   toolchain, and execution posture with the results. Do not silently remove
   noisy samples or compare measurements from different hosts.
3. Compare against a matching baseline, calling out changes of at least 5%
   and any noisy fixtures. For published refs, the optional interleaved runner
   is `tools/bench/remote-bench.sh --ref <head-ref> --baseline <base-ref>`.
   It cannot measure uncommitted local changes; do not publish them implicitly.
4. For a peer-facing refresh, run `tools/bench-cross.sh` or the remote runner
   with `--cross`. Keep interpreter-only and full-speed tables separate.
   Use a temporary output, review completeness and noise, then replace
   `bench-cross-results.md` only when recording a requested snapshot.

Print the measured table and relevant deltas. `bench-results.md` is an archive,
not a destination for new routine snapshots. Record decision-relevant A/B
summaries in the owning design document; see
[results ownership](../benchmarking.md#results-artifacts).

Do not commit. Report a failed or contaminated run without replacing a good
snapshot or discarding pre-existing edits.
