#!/usr/bin/env bash
#
# guarded-run.sh — run a build/test command under hard resource guards.
#
# Why this exists: a hung `zig build test` or a runaway test fixture can
# leak multiple GB and orphan child processes that survive a plain
# Ctrl-C or `timeout` — the build runner is named `build`, the unit-test
# runner `test`, neither matches `pkill zig`, so they linger and pile
# up. This wrapper bounds wall-clock time AND total memory, and on ANY
# exit (completion, timeout, RSS cap, Ctrl-C) kills the entire process
# tree it spawned. No orphans, no unbounded leaks.
#
# Usage:
#   tools/guarded-run.sh [--timeout=S] [--rss=MB] [--quiet] -- <command...>
#   tools/guarded-run.sh --reap        # kill stray zig/build/test orphans
#
# Defaults: --timeout=2400 (40 min — a cold `zig build test` is slow),
#           --rss=8000 (8 GB tree total).
# Exit codes: the command's own, or 124 (timeout), 137 (RSS cap).

set -u

TIMEOUT=2400
RSS_CAP_MB=8000
QUIET=0
POLL=2

note() { [ "$QUIET" -eq 1 ] || echo "guarded-run: $*" >&2; }

# collect_tree <pid> — echo <pid> and every descendant pid (snapshot).
collect_tree() {
  echo "$1"
  local k
  for k in $(pgrep -P "$1" 2>/dev/null); do collect_tree "$k"; done
}

# kill_tree <pid> — snapshot the tree, then SIGKILL every pid in it.
# Snapshot first so a process spawning children mid-kill can't escape.
kill_tree() {
  local pids p
  pids=$(collect_tree "$1")
  for p in $pids; do kill -9 "$p" 2>/dev/null; done
}

# tree_rss_kb <pid> — total resident memory (KB) of the whole tree.
tree_rss_kb() {
  local total=0 p r
  for p in $(collect_tree "$1"); do
    r=$(ps -o rss= -p "$p" 2>/dev/null | tr -d ' ')
    [ -n "$r" ] && total=$((total + r))
  done
  echo "$total"
}

# --reap: kill any leftover Cynic build/test orphans and exit.
reap() {
  local n=0 p
  for p in $(pgrep -x zig 2>/dev/null) \
           $(pgrep -f '\.zig-cache/o/.*/build' 2>/dev/null) \
           $(pgrep -f '\.zig-cache/o/.*/test' 2>/dev/null) \
           $(pgrep -f 'zig-out/bin/cynic' 2>/dev/null); do
    kill -9 "$p" 2>/dev/null && n=$((n + 1))
  done
  echo "guarded-run: reaped $n stray process(es)" >&2
}

# ---- argument parsing -------------------------------------------------
while [ $# -gt 0 ]; do
  case "$1" in
    --reap)        reap; exit 0 ;;
    --timeout=*)   TIMEOUT="${1#*=}"; shift ;;
    --rss=*)       RSS_CAP_MB="${1#*=}"; shift ;;
    --quiet)       QUIET=1; shift ;;
    --)            shift; break ;;
    -h|--help)     sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "guarded-run: unknown argument '$1'" >&2; exit 2 ;;
  esac
done
if [ $# -eq 0 ]; then
  echo "guarded-run: no command given (expected: ... -- <command...>)" >&2
  exit 2
fi

# ---- run under guard --------------------------------------------------
note "running: $* (timeout ${TIMEOUT}s, rss cap ${RSS_CAP_MB}MB)"

"$@" &
CMD_PID=$!

# Kill the whole tree on any script exit — completion, signal, error.
trap 'kill_tree "$CMD_PID"' EXIT INT TERM

START=$(date +%s)
rss_cap_kb=$((RSS_CAP_MB * 1024))

while kill -0 "$CMD_PID" 2>/dev/null; do
  elapsed=$(( $(date +%s) - START ))
  if [ "$elapsed" -ge "$TIMEOUT" ]; then
    note "TIMEOUT after ${elapsed}s — killing process tree"
    kill_tree "$CMD_PID"
    trap - EXIT
    exit 124
  fi
  rss_kb=$(tree_rss_kb "$CMD_PID")
  if [ "$rss_kb" -gt "$rss_cap_kb" ]; then
    note "RSS cap exceeded ($((rss_kb / 1024))MB > ${RSS_CAP_MB}MB) — killing process tree"
    kill_tree "$CMD_PID"
    trap - EXIT
    exit 137
  fi
  sleep "$POLL"
done

# Command finished on its own — collect its real exit status.
wait "$CMD_PID"
status=$?
trap - EXIT
note "done (exit ${status}, $(( $(date +%s) - START ))s)"
exit "$status"
