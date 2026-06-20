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
#   tools/bench-cross.sh                 # BOTH tiers (two separate tables)
#   tools/bench-cross.sh --tier interp   # interpreter tier only
#   tools/bench-cross.sh --tier jit      # full-speed tier only: Cynic
#                                        # default (Bistromath) vs peers
#                                        # with their JITs ENABLED. The two
#                                        # tiers are different fairness
#                                        # baselines — always separate
#                                        # tables, never one merged table.
#   tools/bench-cross.sh -o results.md   # also write table(s) to a file
#   tools/bench-cross.sh --runs 5        # override timed-run count
#   tools/bench-cross.sh --macros        # Octane macro set (bench/macros/)
#                                        # instead of the micros; Cynic
#                                        # pinned --unhardened
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
TIER="both"
MACROS=0          # --macros: run bench/macros/ (Octane) instead of micros

while [ $# -gt 0 ]; do
  case "$1" in
    -o|--out)   OUT_FILE="$2"; shift 2 ;;
    --runs)     RUNS="$2"; shift 2 ;;
    --tier)     TIER="$2"; shift 2 ;;
    --macros)   MACROS=1; shift ;;
    -h|--help)
      sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) echo "bench-cross: unknown argument '$1'" >&2; exit 1 ;;
  esac
done

# Macro mode runs the Octane workloads in bench/macros/ instead of the
# micros, and pins Cynic with `--unhardened` — those ES5-era bodies
# monkey-patch primordials, which the default frozen-primordials (SES)
# posture rejects. Peers are unhardened by nature, so the comparison
# stays apples-to-apples; only Cynic needs the flag.
if [ "$MACROS" = "1" ]; then
  BENCH_DIR="$REPO_ROOT/bench/macros"
  CYNIC_EXTRA="--unhardened"
  MACRO_FWD="--macros"
else
  BENCH_DIR="$MICROS_DIR"
  CYNIC_EXTRA=""
  MACRO_FWD=""
fi

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

# `both` composes the two single-tier runs — interpreter table
# first (the headline), full-speed second — into one artifact with
# two separately-headed sections.
if [ "$TIER" = "both" ]; then
  tmp_i="$(mktemp)" tmp_j="$(mktemp)"
  trap 'rm -f "$tmp_i" "$tmp_j"' EXIT
  "$0" --tier interp --runs "$RUNS" $MACRO_FWD > "$tmp_i"
  "$0" --tier jit --runs "$RUNS" $MACRO_FWD > "$tmp_j"
  if [ -n "$OUT_FILE" ]; then
    { cat "$tmp_i"; echo; cat "$tmp_j"; } > "$OUT_FILE"
    echo "wrote $OUT_FILE" >&2
  fi
  cat "$tmp_i"; echo; cat "$tmp_j"
  exit 0
fi

echo "Discovering $TIER-tier engines ..." >&2

if [ "$TIER" = "jit" ]; then
  # Full-speed table: Cynic's default posture (Bistromath, on by
  # default since the step-3 exit of docs/jit.md's delivery order)
  # against the peers with their JITs ENABLED. Kept strictly
  # separate from the interpreter table below — the two answer
  # different questions and must never share a table. The
  # natively interpreter-only engines (qjs, hermes, xst) carry no
  # JIT to enable and already appear in the interpreter table, so
  # they are omitted here.
  register cynic - "$CYNIC_BIN" $CYNIC_EXTRA run
  register v8 - "$JSVU_BIN/v8"
  register sm - "$JSVU_BIN/sm"
else
  # Interpreter tier — the headline. Cynic pinned with `--no-jit`
  # (Bistromath is the engine default), every JIT peer pinned with
  # its no-JIT flags, so the comparison stays interpreter-tier vs
  # interpreter-tier.
  register cynic - "$CYNIC_BIN" --no-jit $CYNIC_EXTRA run

  # QuickJS-NG — headline non-JIT peer, no flag needed.
  register qjs - "$JSVU_BIN/qjs"

  # V8 / d8 — JIT off.
  register v8 - "$JSVU_BIN/v8" --jitless

  # SpiderMonkey — Baseline + Ion JITs off.
  register sm - "$JSVU_BIN/sm" --no-baseline --no-ion
fi

# JavaScriptCore — JIT off via env var. Prefer a jsvu-installed
# `jsc`; otherwise fall back to the macOS system JavaScriptCore
# framework helper, which ships on every macOS and honours
# `JSC_useJIT=0` just the same.
jsc_bin="$JSVU_BIN/jsc"
if [ ! -x "$jsc_bin" ]; then
  sys_jsc="/System/Library/Frameworks/JavaScriptCore.framework/Versions/A/Helpers/jsc"
  [ -x "$sys_jsc" ] && jsc_bin="$sys_jsc"
fi
if [ "$TIER" = "jit" ]; then
  register jsc - "$jsc_bin"
else
  register jsc "JSC_useJIT=0" "$jsc_bin"
fi

# Natively interpreter-only engines — interpreter table only (no
# JIT to enable; identical numbers would just pad the full-speed
# table).
if [ "$TIER" != "jit" ]; then
  # Hermes — natively interpreter-only.
  register hermes - "$JSVU_BIN/hermes"

  # XS (Moddable xst) — natively interpreter-only.
  register xs - "$JSVU_BIN/xst"
fi

if [ "${#ENGINE_NAMES[@]}" -eq 0 ]; then
  echo "bench-cross: no engines available — install peers with" >&2
  echo "  \`jsvu --engines=quickjs,v8,spidermonkey\` (Cynic builds above)." >&2
  exit 1
fi

# Column order: Cynic first (the engine under test), then peers
# alphabetically — stable regardless of discovery order.
sort_engines() {
  local n=${#ENGINE_NAMES[@]} i name
  local names=() envs=() cmds=()
  i=0
  while [ "$i" -lt "$n" ]; do
    if [ "${ENGINE_NAMES[$i]}" = "cynic" ]; then
      names+=("${ENGINE_NAMES[$i]}"); envs+=("${ENGINE_ENVS[$i]}"); cmds+=("${ENGINE_CMDS[$i]}")
    fi
    i=$((i + 1))
  done
  for name in $(printf '%s
' "${ENGINE_NAMES[@]}" | grep -v '^cynic$' | sort); do
    i=0
    while [ "$i" -lt "$n" ]; do
      if [ "${ENGINE_NAMES[$i]}" = "$name" ]; then
        names+=("${ENGINE_NAMES[$i]}"); envs+=("${ENGINE_ENVS[$i]}"); cmds+=("${ENGINE_CMDS[$i]}")
      fi
      i=$((i + 1))
    done
  done
  ENGINE_NAMES=("${names[@]}"); ENGINE_ENVS=("${envs[@]}"); ENGINE_CMDS=("${cmds[@]}")
}
sort_engines
echo >&2

# ---------------------------------------------------------------------
# Fixture discovery.
# ---------------------------------------------------------------------
FIXTURES=()
for f in "$BENCH_DIR"/*.js; do
  [ -e "$f" ] || continue
  FIXTURES+=("$f")
done
if [ "${#FIXTURES[@]}" -eq 0 ]; then
  echo "bench-cross: no fixtures in $BENCH_DIR" >&2
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
# Engine version strings for the table header. jsvu writes the
# versions it installed into ~/.jsvu/status.json; engines outside
# jsvu answer their own flags; Cynic is identified by commit.
jsvu_ver() {
  sed -n "s/.*\"$1\": \"\([^\"]*\)\".*/\1/p" "$HOME/.jsvu/status.json" 2>/dev/null | head -1
}

engine_version() {
  local name="$1" bin="$2" v=""
  case "$name" in
    cynic)  v="$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null)" ;;
    sm)     v="$("$bin" --version 2>/dev/null | head -1)" ;;
    v8)     v="$(jsvu_ver v8)"
            [ -z "$v" ] && v="$("$bin" -e 'print(version())' 2>/dev/null | head -1)" ;;
    qjs)    v="$(jsvu_ver quickjs)" ;;
    hermes) v="$(jsvu_ver hermes)" ;;
    xs)     v="$(jsvu_ver xs)" ;;
    jsc)    case "$bin" in
              /System/*) v="macOS $(sw_vers -productVersion 2>/dev/null) system" ;;
              *)         v="$(jsvu_ver javascriptcore)" ;;
            esac ;;
  esac
  [ -n "$v" ] && printf '%s' "$v" || printf '?'
}

emit() {
  local host_os
  host_os="$(uname -srm 2>/dev/null || echo unknown)"
  local kind="micro"
  [ "$MACROS" = "1" ] && kind="macro"
  if [ "$TIER" = "jit" ]; then
    echo "## Full-speed-tier cross-engine ${kind}-bench"
  else
    echo "## Interpreter-tier cross-engine ${kind}-bench"
  fi
  echo
  echo "Subprocess wall-clock; times in **ms**, **median of N=$RUNS timed"
  echo "runs** after $WARMUP discarded warmup run. \`*\` flags a fixture"
  echo "whose max-min spread exceeded ${SPREAD_LIMIT}% — treat that cell as noisy."
  echo "🥇 🥈 🥉 mark the three fastest engines on each fixture row"
  echo "(gold also bold); tied cells share a medal."
  echo
  if [ "$TIER" = "jit" ]; then
    echo "Every engine runs at FULL SPEED — Cynic in its default posture"
    echo "(Bistromath on; per-process cold start, so the tier warms inside"
    echo "each run), v8/sm/jsc with all JIT tiers enabled. A different"
    echo "fairness baseline from the interpreter-tier table; never merge"
    echo "the two."
  else
    echo "All JIT engines run JIT-disabled (interpreter tier only): v8"
    echo "\`--jitless\`, sm \`--no-baseline --no-ion\`, jsc \`JSC_useJIT=0\`;"
    echo "Cynic pinned with \`--no-jit\` (Bistromath is the engine default)."
  fi
  echo "Internal regression compass — not published."
  echo
  echo "Host: \`$host_os\`. Generated by \`tools/bench-cross.sh\`."
  echo
  local vers="" i=0
  while [ "$i" -lt "${#ENGINE_NAMES[@]}" ]; do
    local n="${ENGINE_NAMES[$i]}"
    local b="${ENGINE_CMDS[$i]%% *}"
    [ -n "$vers" ] && vers="$vers, "
    vers="$vers$n $(engine_version "$n" "$b")"
    i=$((i + 1))
  done
  echo "Engines: $vers."
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
  if [ "$TIER" = "jit" ]; then
    echo "_Full-speed-tier, internal compass. Do not publish; do_"
  else
    echo "_Interpreter-tier-only, internal compass. Do not publish; do_"
  fi
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
