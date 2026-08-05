#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
actual="$("$ROOT/tools/bench-cross.sh" --self-test-rss-medals)"
expected='| tied | 🥇 **100** | 🥈 200 | 🥈 200 | 🥉 300 | 400 | — |'

if [ "$actual" != "$expected" ]; then
  echo "unexpected RSS medal row" >&2
  printf 'expected: %s\n' "$expected" >&2
  printf 'actual:   %s\n' "$actual" >&2
  exit 1
fi

affinity_actual="$("$ROOT/tools/bench-cross.sh" --self-test-python-affinity)"
affinity_expected='taskset -c 7 engine fixture.js
env FLAG=1 taskset -c 7 engine fixture.js'

if [ "$affinity_actual" != "$affinity_expected" ]; then
  echo "unexpected Python fallback argv" >&2
  printf 'expected: %s\n' "$affinity_expected" >&2
  printf 'actual:   %s\n' "$affinity_actual" >&2
  exit 1
fi
