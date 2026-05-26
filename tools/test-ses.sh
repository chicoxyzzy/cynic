#!/usr/bin/env bash
# Run every tests/ses/*.js through the cynic CLI (hardened by
# default) and report pass / fail. Each test is a self-contained
# script that throws on failure; `cynic run` exits 1 on uncaught
# throw, 0 on clean completion.
#
# Used by `zig build test-ses` and CI. Phase 4 of
# `docs/handbook/ses-test262-policy.md` — the positive coverage
# dual of `tools/test262/ses_witnesses.zig`.

set -u

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
ses_dir="$repo_root/tests/ses"
cynic="$repo_root/zig-out/bin/cynic"

if [ ! -x "$cynic" ]; then
  echo "tools/test-ses.sh: $cynic missing; run \`zig build\` first" >&2
  exit 2
fi

if [ ! -d "$ses_dir" ]; then
  echo "tools/test-ses.sh: $ses_dir missing" >&2
  exit 2
fi

shopt -s nullglob
tests=("$ses_dir"/*.js)
shopt -u nullglob

if [ "${#tests[@]}" -eq 0 ]; then
  echo "tools/test-ses.sh: no tests in $ses_dir" >&2
  exit 2
fi

pass=0
fail=0
failed_names=()

for t in "${tests[@]}"; do
  name="$(basename "$t")"
  out="$("$cynic" run "$t" 2>&1)"
  rc=$?
  if [ "$rc" -eq 0 ]; then
    pass=$((pass + 1))
    printf "  ok    %s\n" "$name"
  else
    fail=$((fail + 1))
    failed_names+=("$name")
    printf "  FAIL  %s\n" "$name"
    if [ -n "$out" ]; then
      printf '        %s\n' "$out" | head -n 5
    fi
  fi
done

total=$((pass + fail))
printf "\nses: %d / %d pass\n" "$pass" "$total"

if [ "$fail" -gt 0 ]; then
  printf "\nFailing:\n"
  for n in "${failed_names[@]}"; do
    printf "  - %s\n" "$n"
  done
  exit 1
fi
