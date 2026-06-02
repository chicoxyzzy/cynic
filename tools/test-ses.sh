#!/usr/bin/env bash
# Run the hand-written SES coverage tests under tests/ses/ through
# the cynic CLI and report pass / fail. Each test is a self-
# contained script that throws on failure; `cynic run` exits 1 on
# uncaught throw, 0 on clean completion.
#
# Two suites:
#   tests/ses/*.js           — run against the default hardened
#                              posture. Asserts SES enforcement is
#                              active (override-mistake shadowing
#                              works, primordials frozen, etc.).
#   tests/ses/unhardened/*.js — run against `cynic --unhardened`.
#                              Asserts the SES posture turns off
#                              atomically (primordials mutable,
#                              `harden` not installed, globalThis
#                              extensible). The "round-trip" check
#                              that --unhardened means what it says.
#
# Used by `zig build test-ses` and CI. Positive-coverage proof
# that the hardened-by-default posture enables what it should
# (the dual of the test262 sweep, which now scores binary
# pass/fail under `--unhardened --allow=eval`).

set -u

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
ses_dir="$repo_root/tests/ses"
unhardened_dir="$repo_root/tests/ses/unhardened"
cynic="$repo_root/zig-out/bin/cynic"

if [ ! -x "$cynic" ]; then
  echo "tools/test-ses.sh: $cynic missing; run \`zig build\` first" >&2
  exit 2
fi

if [ ! -d "$ses_dir" ]; then
  echo "tools/test-ses.sh: $ses_dir missing" >&2
  exit 2
fi

pass=0
fail=0
failed_names=()

run_one() {
  local t="$1"
  local label="$2"   # display path, relative to tests/ses/
  shift 2
  local out
  out="$("$cynic" "$@" run "$t" 2>&1)"
  local rc=$?
  if [ "$rc" -eq 0 ]; then
    pass=$((pass + 1))
    printf "  ok    %s\n" "$label"
  else
    fail=$((fail + 1))
    failed_names+=("$label")
    printf "  FAIL  %s\n" "$label"
    if [ -n "$out" ]; then
      printf '        %s\n' "$out" | head -n 5
    fi
  fi
}

# Hardened suite — files directly under tests/ses/. Glob is non-
# recursive so the unhardened/ subdir doesn't sneak in.
shopt -s nullglob
hardened_tests=("$ses_dir"/*.js)
shopt -u nullglob

for t in "${hardened_tests[@]}"; do
  run_one "$t" "$(basename "$t")"
done

# Unhardened suite — files under tests/ses/unhardened/. Run with
# `--unhardened` so the realm-init freeze pass is skipped and
# `harden` is not installed.
if [ -d "$unhardened_dir" ]; then
  shopt -s nullglob
  unhardened_tests=("$unhardened_dir"/*.js)
  shopt -u nullglob
  for t in "${unhardened_tests[@]}"; do
    run_one "$t" "unhardened/$(basename "$t")" --unhardened
  done
fi

total=$((pass + fail))
printf "\nses: %d / %d pass\n" "$pass" "$total"

if [ "$fail" -gt 0 ]; then
  printf "\nFailing:\n"
  for n in "${failed_names[@]}"; do
    printf "  - %s\n" "$n"
  done
  exit 1
fi
