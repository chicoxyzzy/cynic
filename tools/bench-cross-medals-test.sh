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
