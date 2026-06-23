#!/usr/bin/env bash
# Fetch Unicode CLDR-JSON *source* packages into vendor/cldr/json/, mirroring
# how IANA tzdata sources are dropped into vendor/tzdata/iana/ before a pack.
#
#   tools/fetch-cldr.sh              # pinned version (vendor/cldr/VERSION), fetch + pack
#   tools/fetch-cldr.sh 48.2.0       # pin a CLDR-JSON release
#   tools/fetch-cldr.sh --no-pack    # fetch only; skip the CYCL pack
#
# The raw JSON is large (tens of MB across the data packages) and is NOT
# committed (vendor/cldr/.gitignore ignores json/). The committed artifact is
# the packed blob vendor/cldr/cynic_cldr.bin, embedded only at -Dintl=full.
# After this, `zig build pack-cldr` (or this script without --no-pack) reads
# vendor/cldr/json/ and regenerates the blob.
#
# Upstream: https://github.com/unicode-org/cldr-json (npm registry tarballs)
# License:  Unicode License v3 — vendor/cldr/LICENSE
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CLDR_DIR="$REPO_ROOT/vendor/cldr"
JSON_DIR="$CLDR_DIR/json"
STAMP="$CLDR_DIR/VERSION"
REGISTRY="https://registry.npmjs.org"

# CLDR-JSON packages we consume. cldr-core carries the locale-independent
# supplemental data (plural + ordinal rules, likelySubtags); the *-full
# packages carry per-locale data which the packer filters to the modern
# coverage tier. (The *-modern npm split was discontinued after v45, so we
# fetch -full and filter at pack time.)
PACKAGES=(
    cldr-core
    cldr-numbers-full
    cldr-dates-full
    cldr-localenames-full
    cldr-misc-full
)

DO_PACK=1
VERSION=""

usage() {
    cat <<'EOF'
usage: fetch-cldr.sh [options] [version]

Download CLDR-JSON source packages into vendor/cldr/json/, then (optionally)
run the CYCL packer to regenerate vendor/cldr/cynic_cldr.bin.

  version          CLDR-JSON release, e.g. 48.2.0 (default: vendor/cldr/VERSION)
  --no-pack        Only refresh vendor/cldr/json/; skip the pack
  -h, --help       Show this help
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-pack) DO_PACK=0; shift ;;
        -h|--help) usage; exit 0 ;;
        -*) echo "fetch-cldr: unknown option: $1" >&2; usage >&2; exit 2 ;;
        *)
            if [[ -n "$VERSION" ]]; then
                echo "fetch-cldr: unexpected extra arg: $1" >&2; exit 2
            fi
            VERSION="$1"; shift ;;
    esac
done

# Default version: the committed VERSION stamp's first line, else cldr-core latest.
if [[ -z "$VERSION" ]]; then
    if [[ -f "$STAMP" ]]; then
        VERSION="$(head -1 "$STAMP" | tr -d '[:space:]')"
    fi
fi
if [[ -z "$VERSION" ]]; then
    echo ">> no version pinned; resolving cldr-core latest" >&2
    VERSION="$(curl -sL --max-time 30 "$REGISTRY/cldr-core/latest" \
        | python3 -c 'import json,sys; print(json.load(sys.stdin)["version"])')"
fi

echo ">> CLDR-JSON $VERSION → $JSON_DIR" >&2
rm -rf "$JSON_DIR"
mkdir -p "$JSON_DIR"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

for pkg in "${PACKAGES[@]}"; do
    url="$REGISTRY/$pkg/-/$pkg-$VERSION.tgz"
    echo ">> $pkg" >&2
    if ! curl -fsSL --max-time 180 "$url" -o "$tmp/$pkg.tgz"; then
        echo "fetch-cldr: download failed: $url" >&2
        echo "   (does $pkg publish version $VERSION? check https://www.npmjs.com/package/$pkg)" >&2
        exit 1
    fi
    mkdir -p "$JSON_DIR/$pkg"
    # npm tarballs wrap everything under package/; strip that prefix.
    tar xzf "$tmp/$pkg.tgz" -C "$JSON_DIR/$pkg" --strip-components=1
done

# Refresh the VERSION stamp.
{
    echo "$VERSION"
    echo "# Unicode CLDR-JSON source: vendor/cldr/json/ (release $VERSION)"
    echo "# Packages: ${PACKAGES[*]}"
    echo "# Upstream: https://github.com/unicode-org/cldr-json"
    echo "# Fetch:    tools/fetch-cldr.sh $VERSION"
    echo "# Pack:     zig build pack-cldr  (tools/pack_cldr.zig → cynic_cldr.bin)"
} > "$STAMP"

echo ">> sources ready ($(du -sh "$JSON_DIR" | cut -f1))" >&2

if [[ "$DO_PACK" == "1" ]]; then
    echo ">> packing cynic_cldr.bin" >&2
    ( cd "$REPO_ROOT" && zig build pack-cldr )
fi
