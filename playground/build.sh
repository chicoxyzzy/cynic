#!/usr/bin/env bash
# Build the Cynic playground *engine half*.
#
# Thin wrapper over `zig build wasm`: compiles the engine to a
# wasm32-freestanding ReleaseSmall module and assembles
# zig-out/playground/{cynic.wasm, cynic-engine.js} — the two artifacts
# the engine owns and CI publishes to `gh-pages:/playground/`.
#
# The *website half* (index.html, app.js, codemirror.bundle.js) lives
# on the `gh-pages` branch and imports `cynic-engine.js`. To preview the
# whole playground locally, build here, then copy the two artifacts next
# to a checkout of the gh-pages UI and serve that directory.
#
# See docs/playground.md for the split + the gh-pages deploy steps.
set -euo pipefail

# Resolve the repo root regardless of where the script is invoked.
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"
cd "${repo_root}"

echo "==> zig build wasm"
zig build wasm

wasm="zig-out/bin/cynic.wasm"
out_dir="zig-out/playground"

if [[ ! -f "${wasm}" ]]; then
  echo "error: ${wasm} was not produced" >&2
  exit 1
fi

size_bytes=$(wc -c < "${wasm}" | tr -d ' ')
size_human=$(du -h "${wasm}" | cut -f1)

echo
echo "==> engine artifacts ready: ${out_dir}/"
ls -la "${out_dir}"
echo
echo "    cynic.wasm: ${size_human} (${size_bytes} bytes, ReleaseSmall)"
echo "    cynic-engine.js: the stable ABI binding the gh-pages UI imports"
echo
echo "To preview the full playground, drop these two next to the"
echo "gh-pages /playground/ UI (index.html + app.js + codemirror) and"
echo "serve over HTTP (file:// will not satisfy fetch/instantiateStreaming):"
echo "    python3 -m http.server 8080   # from that directory"
echo "    open http://localhost:8080/"
