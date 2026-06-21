# Bench tooling

Single-engine + cross-engine bench harnesses, and an **optional** remote
runner so heavy builds / test sweeps / benches can run on a machine you
configure instead of your laptop. Everything works locally with no remote.

## Local

    zig build bench                  # micros, JIT (default tier)
    zig build bench -- --no-jit      # micros, interpreter
    zig build bench -- --macros      # Octane macros (see ../bench/macros)
    tools/bench-cross.sh             # cross-engine table (needs jsvu peers)

`run-suite.sh <outdir> <runs> <micros|macros|both>` runs both postures
into labelled files; `ab-report.ts <base-dir> <head-dir>` diffs two such
dirs into a markdown ratio table. The report tool is TypeScript, run with
`node ab-report.ts …` (Node ≥ 23 strips the types — no build step) and
type-checked with tsgo (`npm run typecheck` here; deps pinned in
`package.json`).

## Remote (optional) — offload the heavy work

If you set up a remote, the laptop only orchestrates over SSH:

    tools/bench/provision-remote.sh                    # install toolchain (once)
    tools/bench/remote-bench.sh --ref origin/<branch> --baseline origin/main
    tools/bench/remote-run.sh origin/<branch> zig build test-fast   # any command

`remote-bench.sh` runs an **interleaved A/B** (a ref and a baseline measured
back-to-back per iteration, so the ratio cancels host drift) and renders the
report on your laptop. `remote-run.sh` runs an arbitrary command (a build, a
test sweep) against a ref. `--cross` adds the cross-engine table.

**Detached jobs (survive a local restart).** Both submit the work as a
detached job on the box (under `setsid`+`flock`) and return a `JOB_ID`
immediately; the job writes its output + an exit-sentinel to
`/tmp/jobs/<id>`, so it keeps running even if your laptop's Claude Code
restarts and the ssh dies. The default invocation submits then waits, but
the wait is just stateless polling — **re-runnable after a restart**:

    JOB=$(tools/bench/remote-run.sh --submit origin/<branch> zig build test262 -- --quiet)
    tools/bench/remote-run.sh --status $JOB     # running | <exit code>
    tools/bench/remote-run.sh --tail   $JOB     # last lines of the log
    tools/bench/remote-run.sh --wait   $JOB     # block until done, print log
    tools/bench/remote-bench.sh --wait  $JOB    # (A/B) resume + render
    tools/bench/remote-bench.sh --fetch $JOB    # (A/B) pull results of a finished job

Nothing here is provider-specific — point it at any Ubuntu host:

    export CYNIC_REMOTE=user@host        # or an ssh-config Host alias

or put `CYNIC_REMOTE=…` in a local env file (default
`~/.config/cynic/remote.env`, override with `CYNIC_REMOTE_ENV`) — that
file is yours and is git-ignored. **With no remote configured, run the
commands locally instead.**

### Serialisation + caching

Every remote run is **`flock`-serialised**: jobs never overlap (overlap
would contend for CPU and ruin bench numbers); a second caller queues. The
remote does `git checkout` and **never `git clean`**, so its warm
`zig-cache` (and the test262 `--only-failing` pass-cache) survive between
runs — each ref's build is *incremental*, so the serialised queue stays
fast even when several agents use it.

So: **benches** want the serialised remote (clean numbers); **correctness
tests** can run there too (incremental + cached), or in parallel via CI.

### Precision

A shared-vCPU remote has a same-code A/B noise floor of ~7% (up to ~18% on
`promise_chain`) that does *not* shrink with more runs — it's neighbour
jitter between the two A/B halves, not sample noise. So it reliably catches
**large** regressions (>10%); re-run a flagged fixture to confirm. To
tighten: interleave the base/head measurements (cancels the drift, no extra
cost), or use a dedicated (non-shared) host.

### Notes

- The ref/baseline you compare must be pushed to `origin` (the remote
  fetches from GitHub).
- `provision-remote.sh` fetches the exact pinned Zig from `build.zig.zon`
  and installs peers via jsvu (v8, sm, qjs, hermes, xs; `jsc` has no
  reliable Linux jsvu build and drops out of the table). x86 by default;
  set `CYNIC_REMOTE_ARCH=aarch64` for arm64.
- The report renders on your laptop (Node ≥ 23), so the remote needs no
  Python or TS toolchain.
