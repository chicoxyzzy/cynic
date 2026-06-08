#!/usr/bin/env bash
#
# bench-cross.sh — interpreter-tier cross-engine micro-bench runner.
#
# Runs every bench/micros/*.js fixture under each available engine,
# times the subprocess wall-clock (spawn-to-exit), and prints a
# markdown table (engine x fixture, median ms) in the bench-results.md
# row style.
#
# This is an INTERNAL regression compass, not a public scoreboard.
# Numbers never go to the website. Cynic is a pure bytecode
# interpreter with no JIT, so this harness compares interpreter tiers
# only: every JIT engine runs with its JIT disabled.
#
#   v8 (d8)       --jitless
#   spidermonkey  --no-baseline --no-ion
#   javascriptcore  JSC_useJIT=0 (env)
#   quickjs-ng / hermes / xs   natively interpreter-only, no flag
#
# QuickJS-NG is the headline peer — a non-JIT C interpreter, the
# fairest comparison (Cynic already vendors its libregexp).
#
# Measurement protocol (docs/benchmarking.md §Measurement protocol):
#   1 discarded warmup run, then 10 timed runs, report the median,
#   flag any fixture whose (max-min)/median spread exceeds 10%.
#   Matched with the single-engine `tools/bench.zig` harness so
#   the two artefacts come out of the same sample budget.
#
# Graceful degradation: any engine whose binary is absent is skipped
# with a note rather than failing the whole run. With zero external
# engines present the runner still works against Cynic alone, which
# proves the plumbing.
#
# Usage:
#   tools/bench-cross.sh                 # all engines, table to stdout
#   tools/bench-cross.sh -o results.md   # also write table to a file
#   tools/bench-cross.sh --runs 5        # override timed-run count
#
# Does NOT touch bench-results.md (that file is the single-engine
# `zig build bench` artifact). Output goes to stdout / the -o file.

set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
JSVU_BIN="${JSVU_BIN:-$HOME/.jsvu/bin}"
MICROS_DIR="$REPO_ROOT/bench/micros"
CYNIC_BIN="$REPO_ROOT/zig-out/bin/cynic"

# Timed-run count + warmup. Matched with tools/bench.zig's
# RUNS_PER_FIXTURE so single-engine and cross-engine numbers come
# out of the same sample budget. The shell median pick below
# (sed-indexed at `mid+1`) returns the upper-middle sample for
# even N — a ≤1-sample bias above the true average-of-middles
# median. At ms-resolution timing on a noisy machine the bias
# sits well inside the existing spread-flagging threshold (10%);
# accepting it keeps the script pure-shell.
RUNS=10
WARMUP=1
SPREAD_LIMIT=10   # percent
OUT_FILE=""

while [ $# -gt 0 ]; do
  case "$1" in
    -o|--out)   OUT_FILE="$2"; shift 2 ;;
    --runs)     RUNS="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) echo "bench-cross: unknown argument '$1'" >&2; exit 1 ;;
  esac
done

# ---------------------------------------------------------------------
# Build Cynic ReleaseFast. A Debug `cynic` runs 5-18x slower — it would
# make the cross-engine comparison meaningless, since every peer below
# is an optimized build. `zig` caches aggressively, so this is near-
# instant when the tree is unchanged.
# ---------------------------------------------------------------------
echo "Building Cynic (ReleaseFast) ..." >&2
if ! ( cd "$REPO_ROOT" && zig build -Doptimize=ReleaseFast ) >&2; then
  echo "bench-cross: \`zig build -Doptimize=ReleaseFast\` failed" >&2
  exit 1
fi

# ---------------------------------------------------------------------
# Engine registry. Each entry: "name|env|command-prefix".
#   env  — KEY=VAL pairs (space-separated) prepended to the command,
#          or "-" for none.
#   command-prefix — the binary plus any no-JIT flags.
# An engine is included only if its binary is executable.
# ---------------------------------------------------------------------
ENGINE_NAMES=()
ENGINE_ENVS=()
ENGINE_CMDS=()

register() {
  local name="$1" env="$2" bin="$3"; shift 3
  if [ ! -x "$bin" ]; then
    echo "  skip  $name  (not found: $bin)" >&2
    return
  fi
  ENGINE_NAMES+=("$name")
  ENGINE_ENVS+=("$env")
  ENGINE_CMDS+=("$bin $*")
  echo "  found $name  ->  $bin $*" >&2
}

echo "Discovering interpreter-tier engines ..." >&2

# Cynic first — the engine under test. `run` subcommand.
register cynic - "$CYNIC_BIN" run

# QuickJS-NG — headline non-JIT peer, no flag needed.
register qjs - "$JSVU_BIN/qjs"

# V8 / d8 — JIT off.
register v8 - "$JSVU_BIN/v8" --jitless

# SpiderMonkey — Baseline + Ion JITs off.
register sm - "$JSVU_BIN/sm" --no-baseline --no-ion

# JavaScriptCore — JIT off via env var. Prefer a jsvu-installed
# `jsc`; otherwise fall back to the macOS system JavaScriptCore
# framework helper, which ships on every macOS and honours
# `JSC_useJIT=0` just the same.
jsc_bin="$JSVU_BIN/jsc"
if [ ! -x "$jsc_bin" ]; then
  sys_jsc="/System/Library/Frameworks/JavaScriptCore.framework/Versions/A/Helpers/jsc"
  [ -x "$sys_jsc" ] && jsc_bin="$sys_jsc"
fi
register jsc "JSC_useJIT=0" "$jsc_bin"

# Hermes — natively interpreter-only.
register hermes - "$JSVU_BIN/hermes"

# XS (Moddable xst) — natively interpreter-only.
register xs - "$JSVU_BIN/xst"

if [ "${#ENGINE_NAMES[@]}" -eq 0 ]; then
  echo "bench-cross: no engines available — install peers with" >&2
  echo "  \`jsvu --engines=quickjs,v8,spidermonkey\` (Cynic builds above)." >&2
  exit 1
fi
echo >&2

# ---------------------------------------------------------------------
# Fixture discovery.
# ---------------------------------------------------------------------
FIXTURES=()
for f in "$MICROS_DIR"/*.js; do
  [ -e "$f" ] || continue
  FIXTURES+=("$f")
done
if [ "${#FIXTURES[@]}" -eq 0 ]; then
  echo "bench-cross: no fixtures in $MICROS_DIR" >&2
  exit 1
fi

# ---------------------------------------------------------------------
# Timing. Each timed run is a fresh subprocess (cold-start cost is
# included but does not leak across runs — see docs/benchmarking.md
# §Measurement protocol, "subprocess isolation").
#
# We time the run with a single helper that brackets the spawn with
# one monotonic-clock read on each side — no per-timestamp subprocess
# jitter. `date +%s%3N` is GNU-only and absent on macOS; there we use
# one python3 process that itself spawns + times the engine, which is
# both accurate and a single fork.
# ---------------------------------------------------------------------
USE_GNU_DATE=0
if date +%s%3N 2>/dev/null | grep -qE '^[0-9]{10,}$'; then
  USE_GNU_DATE=1
fi

# run_once <env> <cmd> <fixture> -> echoes elapsed ms, or "FAIL"
run_once() {
  local env="$1" cmd="$2" fixture="$3"

  if [ "$USE_GNU_DATE" -eq 1 ]; then
    local t0 t1 rc
    t0="$(date +%s%3N)"
    if [ "$env" = "-" ]; then
      # shellcheck disable=SC2086
      $cmd "$fixture" >/dev/null 2>&1
    else
      # shellcheck disable=SC2086
      env $env $cmd "$fixture" >/dev/null 2>&1
    fi
    rc=$?
    t1="$(date +%s%3N)"
    if [ "$rc" -ne 0 ]; then echo "FAIL"; else echo $(( t1 - t0 )); fi
    return
  fi

  # macOS path: one python3 process spawns + times the engine with
  # time.monotonic(), so the measured interval is exactly the
  # engine's wall time — no double shell-spawn jitter.
  local argv
  if [ "$env" = "-" ]; then
    argv="$cmd $fixture"
  else
    argv="env $env $cmd $fixture"
  fi
  python3 - "$argv" <<'PYEOF'
import sys, time, subprocess, shlex
argv = shlex.split(sys.argv[1])
t0 = time.monotonic()
rc = subprocess.run(argv, stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL).returncode
t1 = time.monotonic()
print("FAIL" if rc != 0 else int(round((t1 - t0) * 1000)))
PYEOF
}

# median + spread of a space-separated integer list.
# echoes "<median> <spread_pct> <min> <max>"
stats() {
  local sorted n mid med mn mx spread
  sorted="$(printf '%s\n' $1 | sort -n)"
  n="$(printf '%s\n' "$sorted" | wc -l | tr -d ' ')"
  mid=$(( n / 2 ))
  med="$(printf '%s\n' "$sorted" | sed -n "$((mid + 1))p")"
  mn="$(printf '%s\n' "$sorted" | head -1)"
  mx="$(printf '%s\n' "$sorted" | tail -1)"
  if [ "$med" -gt 0 ]; then
    spread=$(( (mx - mn) * 100 / med ))
  else
    spread=0
  fi
  echo "$med $spread $mn $mx"
}

# ---------------------------------------------------------------------
# Run the matrix. Results keyed "engine|fixture" -> "median[*]".
# A trailing * marks spread > SPREAD_LIMIT%.
# ---------------------------------------------------------------------
declare -A CELL
FLAGGED=()

for ei in "${!ENGINE_NAMES[@]}"; do
  name="${ENGINE_NAMES[$ei]}"
  env="${ENGINE_ENVS[$ei]}"
  cmd="${ENGINE_CMDS[$ei]}"
  for fixture in "${FIXTURES[@]}"; do
    base="$(basename "$fixture" .js)"
    echo "  running  $name / $base ..." >&2

    # Warmup — discarded.
    w=0
    while [ "$w" -lt "$WARMUP" ]; do
      run_once "$env" "$cmd" "$fixture" >/dev/null
      w=$(( w + 1 ))
    done

    samples=""
    failed=0
    r=0
    while [ "$r" -lt "$RUNS" ]; do
      v="$(run_once "$env" "$cmd" "$fixture")"
      if [ "$v" = "FAIL" ]; then
        failed=1
        break
      fi
      samples="$samples $v"
      r=$(( r + 1 ))
    done

    if [ "$failed" -eq 1 ]; then
      CELL["$name|$base"]="ERR"
      continue
    fi

    read -r med spread _mn _mx <<EOF
$(stats "$samples")
EOF
    if [ "$spread" -gt "$SPREAD_LIMIT" ]; then
      CELL["$name|$base"]="${med}*"
      FLAGGED+=("$name/$base: ${spread}% spread")
    else
      CELL["$name|$base"]="$med"
    fi
  done
done

# ---------------------------------------------------------------------
# Emit the markdown table. Rows = fixtures, columns = engines —
# mirrors the bench-results.md per-fixture row style.
# ---------------------------------------------------------------------
emit() {
  local host_os
  host_os="$(uname -srm 2>/dev/null || echo unknown)"
  echo "## Interpreter-tier cross-engine micro-bench"
  echo
  echo "Subprocess wall-clock; times in **ms**, **median of N=$RUNS timed"
  echo "runs** after $WARMUP discarded warmup run. \`*\` flags a fixture"
  echo "whose max-min spread exceeded ${SPREAD_LIMIT}% — treat that cell as noisy."
  echo "🥇 🥈 🥉 mark the three fastest engines on each fixture row"
  echo "(gold also bold); tied cells share a medal."
  echo
  echo "All JIT engines run JIT-disabled (interpreter tier only): v8"
  echo "\`--jitless\`, sm \`--no-baseline --no-ion\`, jsc \`JSC_useJIT=0\`."
  echo "Internal regression compass — not published."
  echo
  echo "Host: \`$host_os\`. Generated by \`tools/bench-cross.sh\`."
  echo

  # Header row — each engine column carries the run count (`n=N`) so
  # the figure is visible at every glance, not just in the prose
  # preamble. `fixture` stays unannotated since the row label is
  # the fixture name itself.
  printf '| fixture |'
  for name in "${ENGINE_NAMES[@]}"; do printf ' %s (n=%d) |' "$name" "$RUNS"; done
  # Separator row — `%s` form so the leading dashes are not parsed
  # as printf option flags.
  printf '\n|%s' '---|'
  for _ in "${ENGINE_NAMES[@]}"; do printf '%s' '---:|'; done
  printf '\n'

  # Body. The three fastest (lowest-ms) engines on each fixture row get
  # 🥇 / 🥈 / 🥉 medals (gold also bold — bold alone is too subtle in a
  # dark theme). Ranking is by DISTINCT value: cells that tie share a
  # medal and the next distinct value takes the following place. `ERR` /
  # `—` never place. A noisy medalist keeps its `*` outside the medal.
  for fixture in "${FIXTURES[@]}"; do
    base="$(basename "$fixture" .js)"
    # First pass — gather the row's numeric cells, then take the three
    # smallest distinct values as gold / silver / bronze (any of the
    # three may be empty when the row has fewer than three engines).
    row_nums=""
    for name in "${ENGINE_NAMES[@]}"; do
      cell="${CELL["$name|$base"]:-—}"
      num="${cell%\*}"
      case "$num" in
        ''|*[!0-9]*) continue ;;   # ERR / — / non-numeric: never places
      esac
      row_nums="$row_nums $num"
    done
    gold=""; silver=""; bronze=""
    read -r gold silver bronze <<EOF
$(printf '%s\n' $row_nums | sort -nu | head -3 | tr '\n' ' ')
EOF
    # Second pass — emit, medaling each cell by which podium value it
    # matches (gold also bold for extra emphasis).
    printf '| %s |' "$base"
    for name in "${ENGINE_NAMES[@]}"; do
      cell="${CELL["$name|$base"]:-—}"
      num="${cell%\*}"
      star=""; [ "$cell" != "$num" ] && star="*"
      case "$num" in
        ''|*[!0-9]*) printf ' %s |' "$cell" ;;
        *)
          if   [ -n "$gold" ]   && [ "$num" -eq "$gold" ];   then printf ' 🥇 **%s**%s |' "$num" "$star"
          elif [ -n "$silver" ] && [ "$num" -eq "$silver" ]; then printf ' 🥈 %s%s |' "$num" "$star"
          elif [ -n "$bronze" ] && [ "$num" -eq "$bronze" ]; then printf ' 🥉 %s%s |' "$num" "$star"
          else printf ' %s |' "$cell"
          fi ;;
      esac
    done
    printf '\n'
  done

  if [ "${#FLAGGED[@]}" -gt 0 ]; then
    echo
    echo "Noisy cells (>${SPREAD_LIMIT}% spread):"
    for f in "${FLAGGED[@]}"; do echo "- $f"; done
  fi
  echo
  echo "_Interpreter-tier-only, internal compass. Do not publish; do_"
  echo "_not append to bench-results.md (that file is the single-engine_"
  echo "_\`zig build bench\` artifact)._"
}

OUTPUT="$(emit)"
echo "$OUTPUT"
if [ -n "$OUT_FILE" ]; then
  printf '%s\n' "$OUTPUT" > "$OUT_FILE"
  echo >&2
  echo "Wrote table to $OUT_FILE" >&2
fi
