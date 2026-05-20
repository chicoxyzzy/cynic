#!/usr/bin/env bash
# Build the Cynic playground bundle.
#
# Thin wrapper over `zig build wasm`: compiles the engine to a
# wasm32-freestanding ReleaseSmall module and assembles a
# directly-servable directory at zig-out/playground/ containing
# playground.html, playground.js, and cynic.wasm.
#
# See docs/playground.md for the WASM build details and the
# gh-pages deploy steps.
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
echo "==> playground bundle ready: ${out_dir}/"
ls -la "${out_dir}"
echo
echo "    cynic.wasm: ${size_human} (${size_bytes} bytes, ReleaseSmall)"
echo
echo "Serve it over HTTP (file:// will not satisfy fetch/instantiateStreaming):"
echo "    cd ${out_dir} && python3 -m http.server 8080"
echo "    open http://localhost:8080/playground.html"
