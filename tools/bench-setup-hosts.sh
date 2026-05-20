#!/usr/bin/env bash
#
# bench-setup-hosts.sh — register Cynic + jsvu-installed engines with
# eshost-cli, each pinned to its no-JIT (interpreter-tier) flags.
#
# This is a convenience wrapper. The canonical host registry lives in
# bench/eshost-hosts.json — that file already works as-is via
#   eshost -c bench/eshost-hosts.json ...
# This script copies the same entries into eshost-cli's global config
# (~/.eshost-config.json) so plain `eshost --list` / `eshost <file>`
# see them too.
#
# Cynic is an interpreter-only engine with no JIT. The whole point of
# this harness is interpreter-tier-vs-interpreter-tier comparison, so
# every JIT engine is registered with its JIT disabled. See
# docs/benchmarking.md and bench/eshost-hosts.json for the rationale.
#
# Usage:
#   tools/bench-setup-hosts.sh          # register all engines present
#   tools/bench-setup-hosts.sh --list   # show eshost's current hosts
#
# Engines whose jsvu binary is absent are skipped silently — install
# them with `jsvu --engines=quickjs,v8,spidermonkey,hermes` first.

set -u

JSVU_BIN="${JSVU_BIN:-$HOME/.jsvu/bin}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CYNIC_BIN="$REPO_ROOT/zig-out/bin/cynic"

if ! command -v eshost >/dev/null 2>&1; then
  echo "bench-setup-hosts: eshost not on PATH." >&2
  echo "  install with: npm i -g eshost-cli" >&2
  exit 1
fi

if [ "${1:-}" = "--list" ]; then
  eshost --list
  exit 0
fi

# add <name> <host-type> <path> [extra eshost args...]
add_host() {
  local name="$1" type="$2" path="$3"; shift 3
  if [ ! -x "$path" ]; then
    echo "  skip  $name  (binary not found: $path)"
    return
  fi
  eshost --delete "$name" >/dev/null 2>&1
  eshost --add "$name" "$type" "$path" "$@" >/dev/null 2>&1 \
    && echo "  added $name  ->  $path $*" \
    || echo "  FAIL  $name  (eshost --add errored)"
}

echo "Registering interpreter-tier hosts with eshost-cli ..."

# Cynic — `ch` host type (bare file arg, expects print()); `run`
# subcommand makes the spawn `cynic run <file>`.
add_host cynic ch "$CYNIC_BIN" --args run

# QuickJS-NG — non-JIT C interpreter, the headline peer. `ch` type:
# jsvu's qjs rejects the `-N` flag the eshost `qjs` agent injects.
add_host qjs ch "$JSVU_BIN/qjs"

# V8 (d8) — JIT disabled with --jitless.
add_host v8 d8 "$JSVU_BIN/v8" --args --jitless

# SpiderMonkey — JIT disabled with --no-baseline --no-ion.
# (Older builds also accept --no-warp; jsvu 151.x rejects it.)
add_host sm jsshell "$JSVU_BIN/sm" --args "--no-baseline --no-ion"

# JavaScriptCore — JIT disabled via the JSC_useJIT=0 env var, not a
# flag. eshost can't set env per host; the cross-engine runner
# (bench-cross.sh) sets it. Registered here for completeness.
add_host jsc jsc "$JSVU_BIN/jsc"

# Hermes — natively interpreter-only, no flag needed.
add_host hermes hermes "$JSVU_BIN/hermes"

# XS (Moddable) — natively interpreter-only.
add_host xs xs "$JSVU_BIN/xst"

echo
echo "Done. Current eshost hosts:"
eshost --list
echo
echo "Note: the cross-engine timing runner is tools/bench-cross.sh —"
echo "it invokes engines directly (with these same no-JIT flags) for"
echo "reliable wall-clock timing. eshost is used here only for the"
echo "registry / manual one-off runs."
