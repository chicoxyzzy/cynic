#!/usr/bin/env bash
# tools/fuzz/triage-crashes.sh — replay each Fuzzilli crash reproducer
# through `cynic` under the fuzz posture (--unhardened --allow=eval),
# extract the first Zig panic anchor (src/.../X.zig:NN) from the trace,
# group reproducers by anchor, print one bucket per unique anchor with
# count + representative path.
#
# Cynic-side fallback to pragmatist's mcp__pragmatist__fuzz_triage_crashes
# (the MCP tool currently stack-overflows past ~10 reproducers and
# misapplies divergence carve-outs to crash inputs). This script doesn't
# need any of pragmatist's machinery — it walks the crashes/ dir Fuzzilli
# wrote, replays each through the regular `cynic` CLI, and dedups.
#
# Usage:
#   tools/fuzz/triage-crashes.sh [crashes-dir]
#
# Env:
#   CYNIC       path to the cynic binary (default ./zig-out/bin/cynic)
#   TIMEOUT_S   per-repro seconds (default 3)
#   JOBS        parallel cynic invocations (default 8)
#   LIMIT       cap reproducers processed (for smoke tests)
#   TRIAGE_TSV  if set, also write machine-readable bucket rows
#               ("<count>\t<anchor>\t<example-path>", one per line, sorted
#               by count descending) to this path. The human stderr
#               report is unchanged. Used by tools/fuzz/fuzz-ci-gate.sh.
#
# Defaults assume the post-8h run at /tmp/fuzzilli-cynic/crashes.

set -uo pipefail

CYNIC=${CYNIC:-./zig-out/bin/cynic}
CRASHES_DIR=${1:-/tmp/fuzzilli-cynic/crashes}
TIMEOUT_S=${TIMEOUT_S:-3}
JOBS=${JOBS:-8}
LIMIT=${LIMIT:-0}

[ -x "$CYNIC" ] || { echo "error: CYNIC=$CYNIC not executable" >&2; exit 2; }
[ -d "$CRASHES_DIR" ] || { echo "error: $CRASHES_DIR not a directory" >&2; exit 2; }

total=$(find "$CRASHES_DIR" -maxdepth 1 -name '*.js' -type f | wc -l | tr -d ' ')
if [ "$LIMIT" -gt 0 ] && [ "$LIMIT" -lt "$total" ]; then
    cap=$LIMIT
else
    cap=$total
fi
echo "fuzz-triage-crashes: $cap reproducers from $CRASHES_DIR" >&2
echo "  cynic=$CYNIC  timeout=${TIMEOUT_S}s  jobs=$JOBS" >&2

raw=$(mktemp -t triage-raw)
trap 'rm -f "$raw"' EXIT

# The per-reproducer worker. Exported as an env so xargs -P can call it
# via `bash -c`. Inputs: $1 = .js path. Output (stdout): one tab-
# separated line, "<anchor>\t<path>".
process_one() {
    local f=$1
    local tmp out anchor
    tmp=$(mktemp -t reproXXXXXX).js
    # Cynic is strict-only; Fuzzilli's polyfill `fuzzilli = function(){}`
    # is a bare assignment to an undeclared name — a strict-mode
    # ReferenceError. Prepending `var fuzzilli;` declares the binding
    # (still undefined), so the `typeof === 'undefined'` check passes
    # and the polyfill's assignment becomes legal.
    { echo 'var fuzzilli;'; cat "$f"; } > "$tmp"
    out=$(timeout "${TIMEOUT_S:-3}" "${CYNIC:-./zig-out/bin/cynic}" --unhardened --allow=eval run "$tmp" 2>&1)
    rm -f "$tmp"
    # First src/.../X.zig:NN anchor in the trace. Zig panics print the
    # full path; we strip down to the path-from-src and the line.
    anchor=$(printf '%s\n' "$out" | grep -oE 'src/[^:]+\.zig:[0-9]+' | head -1)
    [ -z "$anchor" ] && anchor="(no-panic)"
    printf '%s\t%s\n' "$anchor" "$f"
}
export -f process_one
export CYNIC TIMEOUT_S

# Collect raw "anchor\tpath" lines, in parallel.
if [ "$LIMIT" -gt 0 ]; then
    find "$CRASHES_DIR" -maxdepth 1 -name '*.js' -type f | sort | head -n "$LIMIT"
else
    find "$CRASHES_DIR" -maxdepth 1 -name '*.js' -type f | sort
fi | xargs -P "$JOBS" -I {} bash -c 'process_one "$1"' _ {} > "$raw"

echo >&2
echo "=== Unique panic anchors (sorted by count) ===" >&2
echo >&2

# Dedup + sort by count, descending. Awk groups consecutive identical
# anchors after a regular sort.
sort < "$raw" | awk -F'\t' '
    NR == 1 || $1 != prev {
        if (prev != "") printf "%d\t%s\t%s\n", count, prev, example
        count = 0
        example = ""
    }
    {
        count++
        if (!example) example = $2
        prev = $1
    }
    END {
        if (prev != "") printf "%d\t%s\t%s\n", count, prev, example
    }
' | sort -t$'\t' -k1,1rn \
  | tee "${TRIAGE_TSV:-/dev/null}" \
  | awk -F'\t' '{
    printf "  %4d  %s\n        example: %s\n\n", $1, $2, $3
}'

# Trailing one-liner summary so a CI grep can see the unique count.
buckets=$(sort < "$raw" | awk -F'\t' '!seen[$1]++ {n++} END {print n+0}')
echo "$cap reproducers → $buckets unique panic anchors" >&2
