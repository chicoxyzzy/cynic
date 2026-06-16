#!/usr/bin/env bash
# tools/fuzz/fuzz-ci-gate.sh — the nightly-fuzz regression gate.
#
# Pipeline (see docs/fuzzing.md → "Continuous fuzzing"):
#   1. dedup crashes by Zig panic anchor          (tools/fuzz/triage-crashes.sh)
#   2. drop non-reproducing "(no-panic)" buckets  (advisory carve-out
#                                                  classification for the log)
#   3. compare the surviving panic buckets to the committed allowlist
#                                                  (tools/fuzz/crash-baseline.txt)
#   4. FAIL only on a NEW (unlisted, non-carved-out) panic bucket;
#      copy its reproducer into the artifact dir and name the anchor in
#      the failure message so the run is actionable.
#
# A run that finds nothing, or finds only known-open / carved-out
# buckets, is a PASS. WHICH samples a nondeterministic fuzz run executes
# never matters: a known-open bucket is allowlisted whether or not it
# shows up tonight, so run-to-run sample churn cannot flip the verdict.
# Only a genuinely new crash — a real regression — fails the gate.
#
# Why a panic is never a divergence carve-out: docs/fuzz-carveouts.md's
# strict-only / SES / Annex-B / eval-gate entries describe *output*
# divergences, not host aborts. A Zig panic on untrusted JS is a
# host-safety violation per AGENTS.md ("never abort the host on untrusted
# input") — carve-out `cynic.crash-route` says so explicitly. So the
# carve-out registry is applied here only to *explain* dropped no-panic
# samples (advisory), never to dismiss a reproducing crash.
#
# Usage:
#   tools/fuzz/fuzz-ci-gate.sh [crashes-dir]
#
# Env:
#   CYNIC         cynic binary used to replay (default ./zig-out/bin/cynic).
#                 MUST be ReleaseSafe/ReleaseFast — a Debug binary's
#                 ~1000× DebugAllocator slowdown makes repros time out and
#                 mis-report as (no-panic). See AGENTS.md.
#   BASELINE      allowlist file (default <repo>/tools/fuzz/crash-baseline.txt)
#   CARVEOUTS     carve-out registry (default <repo>/docs/fuzz-carveouts.md)
#   ARTIFACT_DIR  where new-crash reproducers are copied (default ./fuzz-artifacts)
#   TIMEOUT_S     per-repro replay seconds, passed to triage (default 5)
#   JOBS          parallel replays, passed to triage (default 4)
#
# Exit: 0 = PASS (no new crash bucket); 1 = FAIL (new bucket(s)); 2 = misconfig.

set -uo pipefail

# Resolve repo root from this script's location so default paths work
# from any CWD (and inside the CI container).
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)

CRASHES_DIR=${1:-/tmp/fuzzilli-cynic/crashes}
CYNIC=${CYNIC:-$REPO_ROOT/zig-out/bin/cynic}
BASELINE=${BASELINE:-$REPO_ROOT/tools/fuzz/crash-baseline.txt}
CARVEOUTS=${CARVEOUTS:-$REPO_ROOT/docs/fuzz-carveouts.md}
ARTIFACT_DIR=${ARTIFACT_DIR:-$REPO_ROOT/fuzz-artifacts}
TIMEOUT_S=${TIMEOUT_S:-5}
JOBS=${JOBS:-4}

log()  { printf '%s\n' "$*" >&2; }
fail() { printf 'fuzz-ci-gate: %s\n' "$*" >&2; exit 2; }

[ -x "$CYNIC" ]      || fail "CYNIC=$CYNIC not executable (build a ReleaseSafe cynic first)"
[ -f "$BASELINE" ]   || fail "baseline $BASELINE not found"

# A summary line for GitHub's job summary panel, accumulated as we go.
summary() { [ -n "${GITHUB_STEP_SUMMARY:-}" ] && printf '%s\n' "$*" >> "$GITHUB_STEP_SUMMARY"; return 0; }

# --- 0. No crashes at all → PASS -------------------------------------
if [ ! -d "$CRASHES_DIR" ]; then
    log "fuzz-ci-gate: no crashes dir ($CRASHES_DIR) — PASS (fuzzer found nothing)"
    summary "### Nightly fuzz: ✅ no crashes"
    exit 0
fi
n_repro=$(find "$CRASHES_DIR" -maxdepth 1 -name '*.js' -type f | wc -l | tr -d ' ')
if [ "$n_repro" -eq 0 ]; then
    log "fuzz-ci-gate: 0 reproducers in $CRASHES_DIR — PASS (fuzzer found nothing)"
    summary "### Nightly fuzz: ✅ no crashes"
    exit 0
fi
log "fuzz-ci-gate: $n_repro crash reproducer(s) to triage"

# --- 1. Dedup by panic anchor (canonical triage tool) ----------------
tsv=$(mktemp -t fuzz-triage-tsv.XXXXXX)
trap 'rm -f "$tsv"' EXIT
# triage-crashes.sh writes the human report to stderr (kept in the CI
# log) and the machine-readable bucket rows to $TRIAGE_TSV.
TRIAGE_TSV="$tsv" CYNIC="$CYNIC" TIMEOUT_S="$TIMEOUT_S" JOBS="$JOBS" \
    bash "$SCRIPT_DIR/triage-crashes.sh" "$CRASHES_DIR"

# --- 2. Load the baseline allowlist ----------------------------------
# Two forms: exact "file.zig:NN" and whole-file wildcard "file.zig:*".
exact_anchors=()
wildcard_files=()
while IFS= read -r line; do
    line="${line%%#*}"                       # strip trailing comment
    line="$(printf '%s' "$line" | tr -d '[:space:]')"
    [ -z "$line" ] && continue
    case "$line" in
        *:\*) wildcard_files+=("${line%:\*}") ;;
        *)    exact_anchors+=("$line") ;;
    esac
done < "$BASELINE"
log "fuzz-ci-gate: baseline → ${#exact_anchors[@]} exact + ${#wildcard_files[@]} wildcard entr(ies)"

in_baseline() {
    local anchor=$1 e f
    for e in "${exact_anchors[@]:-}"; do [ "$anchor" = "$e" ] && return 0; done
    for f in "${wildcard_files[@]:-}"; do
        case "$anchor" in "$f":*) return 0 ;; esac
    done
    return 1
}

# --- carve-out classification (advisory, for the log only) -----------
# Best-effort syntactic match of the dropped (no-panic) samples against
# docs/fuzz-carveouts.md so the log says *why* a sample didn't reproduce.
# Never affects the verdict — a reproducing panic is always a crash.
classify_carveout() {
    local f=$1 src
    src=$(cat "$f" 2>/dev/null)
    case "$src" in
        *__proto__*)                            echo "cynic.proto-accessor"; return ;;
        *"<!--"*|*"-->"*)                       echo "cynic.html-comment"; return ;;
    esac
    if printf '%s' "$src" | grep -qE 'RegExp\.(\$[1-9]|input|lastMatch|lastParen|leftContext|rightContext)'; then
        echo "cynic.legacy-regexp-globals"; return
    fi
    if printf '%s' "$src" | grep -qE '\b(un)?escape\s*\(|\.substr\s*\(|\.trim(Left|Right)\s*\(|getYear|setYear|toGMTString|__(define|lookup)(Getter|Setter)__'; then
        echo "cynic.removed-intrinsics"; return
    fi
    echo ""   # uncategorised
}

# --- 3. Walk the buckets ---------------------------------------------
mkdir -p "$ARTIFACT_DIR"
manifest="$ARTIFACT_DIR/new-crashes.txt"
: > "$manifest"

new_count=0 known_count=0 nopanic_count=0
while IFS=$'\t' read -r count anchor example; do
    [ -z "${anchor:-}" ] && continue
    if [ "$anchor" = "(no-panic)" ]; then
        nopanic_count=$((nopanic_count + count))
        cls=$(classify_carveout "$example")
        log "  drop  ${count}x  (no-panic)${cls:+  [carve-out: $cls]}  — does not reproduce a host panic"
        continue
    fi
    if in_baseline "$anchor"; then
        known_count=$((known_count + 1))
        log "  ok    ${count}x  $anchor  — known-open (baseline)"
        continue
    fi
    # A reproducing panic not in the baseline → NEW regression.
    new_count=$((new_count + 1))
    safe=$(printf '%s' "$anchor" | tr '/:.' '___')
    dest="$ARTIFACT_DIR/new-crash-${safe}.js"
    cp "$example" "$dest" 2>/dev/null || cp "$example" "$ARTIFACT_DIR/" 2>/dev/null || true
    printf '%s\t%s\t%s\n' "$count" "$anchor" "$dest" >> "$manifest"
    log "  NEW   ${count}x  $anchor  — reproducer → $dest"
done < "$tsv"

# --- 4. Verdict ------------------------------------------------------
log ""
log "fuzz-ci-gate: $known_count known-open, $nopanic_count no-panic dropped, $new_count NEW bucket(s)"

if [ "$new_count" -eq 0 ]; then
    log "fuzz-ci-gate: PASS — no new crash buckets"
    summary "### Nightly fuzz: ✅ PASS"
    summary ""
    summary "- known-open buckets seen: \`$known_count\`"
    summary "- non-reproducing samples dropped: \`$nopanic_count\`"
    summary "- new crash buckets: \`0\`"
    exit 0
fi

# Actionable failure: name every new anchor.
log ""
log "================================================================"
log "fuzz-ci-gate: FAIL — $new_count NEW crash bucket(s) (host-safety regression)"
log "================================================================"
summary "### Nightly fuzz: ❌ FAIL — $new_count new crash bucket(s)"
summary ""
summary "A fuzzer-generated input aborted the host (Zig panic) at an anchor not"
summary "in \`tools/fuzz/crash-baseline.txt\`. Each is a host-safety regression"
summary "(AGENTS.md: never abort the host on untrusted input). Reproducers are"
summary "attached as the \`fuzz-new-crashes\` artifact."
summary ""
summary "| count | panic anchor | reproducer |"
summary "|------:|--------------|------------|"
while IFS=$'\t' read -r count anchor dest; do
    log "  $anchor   (${count}x)   →   $dest"
    summary "| $count | \`$anchor\` | \`$(basename "$dest")\` |"
done < "$manifest"
log ""
log "To triage: replay the reproducer locally —"
log "  $CYNIC --unhardened --allow=eval run <reproducer.js>"
log "Then fix it (preferred), or — if it is a tracked known-open bug —"
log "add the anchor to tools/fuzz/crash-baseline.txt with a note."
exit 1
