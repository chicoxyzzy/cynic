#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"

if ! command -v rsvg-convert >/dev/null 2>&1; then
  echo "rsvg-convert is required (install librsvg)." >&2
  exit 1
fi

for spec in \
  "16:icons/favicon-16.png" \
  "32:icons/favicon-32.png" \
  "48:icons/favicon-48.png" \
  "180:icons/apple-touch-icon.png" \
  "192:icons/favicon-192.png" \
  "512:icons/favicon-512.png"
do
  size=${spec%%:*}
  output=${spec#*:}
  rsvg-convert -w "$size" -h "$size" assets/cynic-mascot.svg -o "$output"
done
