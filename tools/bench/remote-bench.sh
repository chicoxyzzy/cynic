#!/usr/bin/env bash
#
# remote-bench.sh — bench a ref against a baseline on the configured remote,
# off your laptop. Runs a same-runner A/B (both refs built and timed on the
# one machine, so the HEAD/baseline ratio cancels host variance), then
# renders the report locally with ab-report.ts.
#
#   tools/bench/remote-bench.sh --ref origin/my-branch --baseline origin/main
#   tools/bench/remote-bench.sh --ref origin/my-branch --cross   # + cross-engine
#
# The whole A/B holds ONE flock on the remote, so another job can't slip
# between the two halves and skew the ratio. The remote keeps its warm
# build cache (never cleaned), so each half is an incremental build.
#
# Generic — configure the remote per tools/bench/README.md. The report
# renders on your laptop (Node >= 23), so the remote needs no report tooling.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$DIR/../.." && pwd)"
# shellcheck source=tools/bench/lib-remote.sh
. "$DIR/lib-remote.sh"

REF="origin/main"
BASELINE="origin/main"
SUITE="both"
RUNS="12"
CROSS="0"
LOCK_WAIT="${CYNIC_LOCK_WAIT:-2400}"

while [ $# -gt 0 ]; do
  case "$1" in
    --ref)      REF="$2"; shift 2 ;;
    --baseline) BASELINE="$2"; shift 2 ;;
    --suite)    SUITE="$2"; shift 2 ;;
    --runs)     RUNS="$2"; shift 2 ;;
    --cross)    CROSS="1"; shift ;;
    *) echo "remote-bench: unknown argument '$1'" >&2; exit 1 ;;
  esac
done

load_remote || exit 1
command -v node >/dev/null || { echo "remote-bench: node not found (need >= 23 to render ab-report.ts)" >&2; exit 1; }

echo ">> $CYNIC_REMOTE — A/B: $REF vs $BASELINE (suite=$SUITE, runs=$RUNS, cross=$CROSS)" >&2
echo ">> acquiring remote lock (waits if another run is in progress)" >&2

# run-suite.sh is copied to /tmp first so the baseline checkout (which may
# predate it) can't remove the script driving the run. The A/B report
# renders on the laptop afterwards.
ssh "${SSH_OPTS[@]}" "$CYNIC_REMOTE" \
  "flock -w $LOCK_WAIT /var/lock/cynic-box.lock bash -s" "$CYNIC_REMOTE_DIR" "$REF" "$BASELINE" "$SUITE" "$RUNS" "$CROSS" <<'REMOTE'
set -euo pipefail
DIR="$1"; REF="$2"; BASELINE="$3"; SUITE="$4"; RUNS="$5"; CROSS="$6"
export PATH="/usr/local/bin:$PATH"
export JSVU_BIN="$HOME/.jsvu/bin"
cd "$DIR"
git fetch --all --quiet --prune
cp tools/bench/run-suite.sh /tmp/run-suite.sh
rm -rf /tmp/head /tmp/base /tmp/cross-micros.md /tmp/cross-macros.md

# checkout, never clean — warm cache survives, builds stay incremental.
git checkout --detach --quiet "$REF"
bash /tmp/run-suite.sh /tmp/head "$RUNS" "$SUITE"
git checkout --detach --quiet "$BASELINE"
bash /tmp/run-suite.sh /tmp/base "$RUNS" "$SUITE"

if [ "$CROSS" = "1" ]; then
  git checkout --detach --quiet "$REF"
  tools/bench-cross.sh --runs "$RUNS" > /tmp/cross-micros.md 2>/dev/null || echo "_(cross micros failed)_" > /tmp/cross-micros.md
  tools/bench-cross.sh --macros --runs "$RUNS" > /tmp/cross-macros.md 2>/dev/null || echo "_(cross macros failed)_" > /tmp/cross-macros.md
fi
echo "remote run complete" >&2
REMOTE

OUT="$REPO_ROOT/bench-results-remote"
mkdir -p "$OUT"
rm -rf "$OUT/head" "$OUT/base"
scp "${SSH_OPTS[@]}" -r "$CYNIC_REMOTE":/tmp/head "$OUT/head" >/dev/null
scp "${SSH_OPTS[@]}" -r "$CYNIC_REMOTE":/tmp/base "$OUT/base" >/dev/null
# Render the A/B report locally — Node >= 23 runs the .ts directly.
node "$REPO_ROOT/tools/bench/ab-report.ts" "$OUT/base" "$OUT/head" > "$OUT/report.md"
if [ "$CROSS" = "1" ]; then
  scp "${SSH_OPTS[@]}" "$CYNIC_REMOTE":/tmp/cross-micros.md "$OUT/cross-micros.md" >/dev/null 2>&1 || true
  scp "${SSH_OPTS[@]}" "$CYNIC_REMOTE":/tmp/cross-macros.md "$OUT/cross-macros.md" >/dev/null 2>&1 || true
fi

echo "" >&2
echo "================ A/B ($REF vs $BASELINE) ================" >&2
cat "$OUT/report.md"
if [ "$CROSS" = "1" ]; then
  echo "" >&2; echo "================ cross-engine (HEAD=$REF) ================" >&2
  cat "$OUT/cross-micros.md" 2>/dev/null || true
  cat "$OUT/cross-macros.md" 2>/dev/null || true
fi
echo ">> raw outputs in bench-results-remote/" >&2
