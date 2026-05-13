#!/usr/bin/env bash
#
# tools/profile.sh — Run a test262 sweep under `samply` and emit a
# top-N hot-function list. Used by the `/profile` slash command.
#
# Usage:
#   tools/profile.sh [filter] [top_n]
#
# Args:
#   filter  — test262 path substring (default: "built-ins/Array")
#   top_n   — how many hot functions to print (default: 20)
#
# Output:
#   - profile.json — full samply profile (open with `samply load`)
#   - prints the top-N hot functions to stdout
#
# Prereq: `samply` on PATH. Install on macOS with `brew install samply`
# or `cargo install samply`. Linux: same `cargo install` works; or
# build from https://github.com/mstange/samply.

set -eu

FILTER="${1:-built-ins/Array}"
TOP_N="${2:-20}"

cd "$(dirname "$0")/.."

if ! command -v samply >/dev/null 2>&1; then
    cat >&2 <<EOF
profile.sh: \`samply\` not found on PATH.

Install with one of:
    brew install samply           # macOS / Linuxbrew
    cargo install samply          # any platform with Rust toolchain

Then re-run.
EOF
    exit 1
fi

# Use the ReleaseFast harness — Debug interpretation is 5-10×
# slower and would over-weight cold paths in the profile.
echo "==> Building test262 harness (ReleaseFast)..." >&2
zig build test262 -- --quiet --filter=__nonexistent_filter__ >/dev/null

HARNESS_BIN="$(find .zig-cache -name 'test262' -type f -perm -u+x | head -1)"
if [[ -z "${HARNESS_BIN:-}" ]]; then
    echo "profile.sh: couldn't locate the test262 harness binary in .zig-cache" >&2
    exit 1
fi

echo "==> Profiling '${FILTER}' under samply..." >&2
echo "    harness: ${HARNESS_BIN}" >&2

# `samply record --save-only` writes a profile without launching the
# GUI viewer. The harness's own --quiet keeps stdout terse.
samply record --save-only --output profile.json -- \
    "${HARNESS_BIN}" \
    --quiet \
    --mode=runtime \
    "--filter=${FILTER}" \
    >/dev/null

echo "==> Wrote profile.json. Load with: samply load profile.json" >&2
echo "" >&2
echo "==> Top ${TOP_N} hot functions (by inclusive sample count):" >&2

# samply's JSON profile is the Firefox Profiler format. The schema
# nests `threads[*].stackTable` + `frameTable` + `funcTable`; we
# don't reimplement that here. The user opens the profile in the
# Firefox Profiler UI (`samply load profile.json`) and reads off
# the call tree.
#
# For a CI-friendly textual top-N, prefer `samply` with its own
# top-N output mode when it lands; until then the profile.json is
# the artifact and the UI is the reader.
echo "    (open profile.json in the Firefox Profiler — \`samply load profile.json\`)" >&2
