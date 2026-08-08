#!/usr/bin/env bash
#
# remote-bench.sh — interleaved A/B (a ref vs a baseline) on the configured
# remote, off your laptop, as a DETACHED job that survives the local ssh
# dying (e.g. a Claude Code restart). The whole A/B (+ optional --cross) runs
# as one flock-held job on the box; the report renders locally with
# ab-report.ts. Submit returns a JOB_ID; resume with --wait/--fetch.
#
#   remote-bench.sh --ref origin/<b> --baseline origin/main [--cpu 1] [--cross]
#   remote-bench.sh --wait <id>     # resume waiting on a submitted A/B
#   remote-bench.sh --fetch <id>    # pull results of a finished A/B + render
#
# Interleaved: HEAD and baseline are measured back-to-back per iteration
# (bench.zig --ab-baseline), so host drift cancels and the ratio is solid
# even on a shared box. checkout, never `git clean` — warm zig-cache stays.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$DIR/../.." && pwd)"
# shellcheck source=tools/bench/lib-remote.sh
. "$DIR/lib-remote.sh"

REF="origin/main"
BASELINE="origin/main"
SUITE="both"
RUNS="12"
CPU="${CYNIC_BENCH_CPU:-1}"
CROSS="0"
WAIT_ID=""
FETCH_ID=""

while [ $# -gt 0 ]; do
  case "$1" in
    --ref)      REF="$2"; shift 2 ;;
    --baseline) BASELINE="$2"; shift 2 ;;
    --suite)    SUITE="$2"; shift 2 ;;
    --runs)     RUNS="$2"; shift 2 ;;
    --cpu)      CPU="$2"; shift 2 ;;
    --cross)    CROSS="1"; shift ;;
    --wait)     WAIT_ID="$2"; shift 2 ;;
    --fetch)    FETCH_ID="$2"; shift 2 ;;
    *) echo "remote-bench: unknown argument '$1'" >&2; exit 1 ;;
  esac
done

case "$CPU" in
  ''|*[!0-9]*) echo "remote-bench: --cpu must be a non-negative integer" >&2; exit 1 ;;
esac

load_remote || exit 1
command -v node >/dev/null || { echo "remote-bench: node not found (need >= 23 to render ab-report.ts)" >&2; exit 1; }

OUT="$REPO_ROOT/bench-results-remote"

# Fetch a finished job's results into bench-results-remote/ and render.
fetch_and_render() {
  local job="$1"
  mkdir -p "$OUT"
  job_fetch_dir "$job" ab "$OUT/ab"
  # A non-cross job must not inherit reports fetched for an earlier job.
  rm -f "$OUT/cross-micros.md" "$OUT/cross-macros.md"
  scp "${SSH_OPTS[@]}" "$CYNIC_REMOTE":"/tmp/jobs/$job/cross-micros.md" "$OUT/cross-micros.md" >/dev/null 2>&1 || true
  scp "${SSH_OPTS[@]}" "$CYNIC_REMOTE":"/tmp/jobs/$job/cross-macros.md" "$OUT/cross-macros.md" >/dev/null 2>&1 || true
  if [ -d "$OUT/ab" ]; then
    node "$REPO_ROOT/tools/bench/ab-report.ts" "$OUT/ab" > "$OUT/report.md"
    echo "" >&2; echo "================ interleaved A/B ================" >&2
    cat "$OUT/report.md"
    if [ -f "$OUT/cross-micros.md" ]; then
      echo "" >&2; echo "================ cross-engine ================" >&2
      cat "$OUT/cross-micros.md" "$OUT/cross-macros.md" 2>/dev/null || true
    fi
    echo ">> raw outputs in bench-results-remote/" >&2
  else
    echo "remote-bench: no results fetched for $job (did it fail? remote-run.sh --tail $job)" >&2
    return 1
  fi
}

# Resume paths.
if [ -n "$FETCH_ID" ]; then fetch_and_render "$FETCH_ID"; exit $?; fi
if [ -n "$WAIT_ID" ]; then
  echo ">> waiting on $WAIT_ID (re-runnable: remote-bench.sh --wait $WAIT_ID)" >&2
  rc=0; job_wait "$WAIT_ID" || rc=$?
  fetch_and_render "$WAIT_ID"
  exit "$rc"
fi

# Build the A/B job body. It checks out BASELINE, builds that binary once,
# then bench.zig --ab-baseline interleaves HEAD vs it. Results go under
# $JOB_DIR so --fetch can pull them by id. ($BASELINE/$REF/$RUNS/$SUITE are
# interpolated locally; $JOB_DIR/$l/$@ stay literal for the box.)
AB_CMD=$(cat <<AB
set -e
mkdir -p "\$JOB_DIR/ab"
command -v taskset >/dev/null || { echo "remote-bench: taskset is required on the benchmark host" >&2; exit 2; }
taskset -c "$CPU" true >/dev/null 2>&1 || { echo "remote-bench: CPU $CPU is unavailable to taskset" >&2; exit 2; }
check_zig_pin() {
  expected="\$(grep -oE '0\.[0-9]+\.[0-9]+-dev\.[0-9]+\+[0-9a-f]+' build.zig.zon | head -1)"
  actual="\$(zig version)"
  [ "\$actual" = "\$expected" ] || {
    echo "remote-bench: resolved Zig \$actual does not match ref pin \$expected; check tools/fetch-zig.sh" >&2
    exit 2
  }
}
git checkout -f -q --detach "$BASELINE"
cynic_use_pinned_zig
check_zig_pin
zig build -Doptimize=ReleaseFast >/dev/null 2>&1
cp zig-out/bin/cynic /tmp/cynic-base
git checkout -f -q --detach "$REF"
cynic_use_pinned_zig
check_zig_pin
run_ab() { local l="\$1"; shift; taskset -c "$CPU" zig build bench -- --ab-baseline=/tmp/cynic-base --runs=$RUNS "\$@" > "\$JOB_DIR/ab/\$l.txt" 2>/dev/null || rm -f "\$JOB_DIR/ab/\$l.txt"; }
case "$SUITE" in micros|both) run_ab micros-jit; run_ab micros-nojit --no-jit ;; esac
case "$SUITE" in macros|both) run_ab macros-jit --macros; run_ab macros-nojit --macros --no-jit ;; esac
AB
)
if [ "$CROSS" = "1" ]; then
  AB_CMD=$(cat <<AB
$AB_CMD
git checkout -f -q --detach "$REF"
cynic_use_pinned_zig
check_zig_pin
echo ">> cross-engine micros (all peers x both tiers — the slow part)" >&2
CYNIC_BENCH_CPU="$CPU" tools/bench-cross.sh --runs $RUNS > "\$JOB_DIR/cross-micros.md" 2>&1 || true
CYNIC_BENCH_CPU="$CPU" tools/bench-cross.sh --macros --runs $RUNS > "\$JOB_DIR/cross-macros.md" 2>&1 || true
AB
)
fi

job="$(job_submit "$REF" "$AB_CMD")"
echo ">> submitted A/B $job on $CYNIC_REMOTE — $REF vs $BASELINE (suite=$SUITE, runs=$RUNS, cpu=$CPU, cross=$CROSS)" >&2
echo ">> if this disconnects, resume with:  tools/bench/remote-bench.sh --wait $job" >&2
rc=0; job_wait "$job" || rc=$?
fetch_and_render "$job"
exit "$rc"
