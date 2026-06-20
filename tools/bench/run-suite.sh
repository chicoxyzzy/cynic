#!/usr/bin/env bash
#
# run-suite.sh — run the single-engine bench suites in both postures
# (interpreter + JIT), writing one labelled output file per config.
#
# Used by .github/workflows/bench.yml for same-runner A/B: the workflow
# invokes this once for HEAD and once for a baseline ref, into separate
# output dirs, then diffs the two with ab-report.ts. Because both halves
# run in the same job (same physical CPU), the HEAD/baseline ratio is
# stable even though absolute ms drift between GitHub-hosted runners.
#
# Usage: run-suite.sh <outdir> <runs> <suite:micros|macros|both>
#
# Each config that fails (e.g. a baseline ref predating bench/macros/)
# is skipped, not fatal — ab-report.ts simply omits that comparison.
set -euo pipefail

OUT="$1"
RUNS="${2:-8}"
SUITE="${3:-both}"
mkdir -p "$OUT"

run_one() { # <label> [extra bench flags...]
  local label="$1"; shift
  if zig build bench -- --runs="$RUNS" "$@" > "$OUT/$label.txt" 2>/dev/null; then
    echo "  wrote $label.txt"
  else
    echo "  skipped $label (bench failed at this ref — suite may not exist)"
    rm -f "$OUT/$label.txt"
  fi
}

case "$SUITE" in
  micros|both)
    run_one micros-jit
    run_one micros-nojit --no-jit
    ;;
esac
case "$SUITE" in
  macros|both)
    run_one macros-jit --macros
    run_one macros-nojit --macros --no-jit
    ;;
esac
