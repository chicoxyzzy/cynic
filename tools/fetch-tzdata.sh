#!/usr/bin/env bash
# Fetch an IANA tzdata *source* release into vendor/tzdata/iana/, mirroring
# how UCD files are dropped into vendor/unicode/ before `zig build gen-unicode`.
#
#   tools/fetch-tzdata.sh              # latest release (reads data.iana.org/time-zones/tzdb/version)
#   tools/fetch-tzdata.sh 2026b        # pin a release id
#   tools/fetch-tzdata.sh --no-pack    # fetch only; skip zic + CYTZ pack
#
# After this, `zig build pack-tzdata` (or this script without --no-pack) compiles
# the sources with system `zic` and regenerates vendor/tzdata/cynic_tzdb.bin.
#
# Upstream: https://data.iana.org/time-zones/
# License:  vendor/tzdata/iana/LICENSE (public domain / CC0 — see file)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IANA_DIR="$REPO_ROOT/vendor/tzdata/iana"
TZCODE_DIR="$REPO_ROOT/vendor/tzdata/tzcode"
STAMP="$REPO_ROOT/vendor/tzdata/VERSION"
BIN_OUT="$REPO_ROOT/vendor/tzdata/cynic_tzdb.bin"
BASE_URL="https://data.iana.org/time-zones"
RELEASES_URL="$BASE_URL/releases"
VERSION_URL="$BASE_URL/tzdb/version"

DO_PACK=1
VERSION=""

usage() {
    cat <<'EOF'
usage: fetch-tzdata.sh [options] [version]

Download an IANA tzdata source tarball into vendor/tzdata/iana/, then
(optionally) compile with zic and run the CYTZ packer.

  version          IANA id, e.g. 2026b (default: latest from tzdb/version)
  --no-pack        Only refresh vendor/tzdata/iana/; skip zic + pack
  -h, --help       Show this help

Examples (Unicode-analogue workflow):
  tools/fetch-tzdata.sh              # bump to latest + repack cynic_tzdb.bin
  tools/fetch-tzdata.sh 2025c        # pin + repack
  tools/fetch-tzdata.sh --no-pack    # sources only; then zig build pack-tzdata
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-pack) DO_PACK=0; shift ;;
        -h|--help) usage; exit 0 ;;
        -*)
            echo "fetch-tzdata: unknown option: $1" >&2
            usage >&2
            exit 2
            ;;
        *)
            if [[ -n "$VERSION" ]]; then
                echo "fetch-tzdata: unexpected extra arg: $1" >&2
                exit 2
            fi
            VERSION="$1"
            shift
            ;;
    esac
done

need_cmd() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "fetch-tzdata: required command not found: $1" >&2
        exit 1
    fi
}

need_cmd curl
need_cmd tar

if [[ -z "$VERSION" ]]; then
    VERSION="$(curl -fsSL "$VERSION_URL" | tr -d '[:space:]')"
    if [[ -z "$VERSION" ]]; then
        echo "fetch-tzdata: could not read latest version from $VERSION_URL" >&2
        exit 1
    fi
fi

# Normalise: accept "tzdata2026b" or "2026b"
VERSION="${VERSION#tzdata}"
TARBALL="tzdata${VERSION}.tar.gz"
CODE_TARBALL="tzcode${VERSION}.tar.gz"
URL="$RELEASES_URL/$TARBALL"
CODE_URL="$RELEASES_URL/$CODE_TARBALL"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/cynic-tzdata.XXXXXX")"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

echo "fetch-tzdata: downloading $URL"
if ! curl -fsSL -o "$TMP/$TARBALL" "$URL"; then
    echo "fetch-tzdata: download failed (check version id; available at $RELEASES_URL/)" >&2
    exit 1
fi

echo "fetch-tzdata: downloading $CODE_URL"
if ! curl -fsSL -o "$TMP/$CODE_TARBALL" "$CODE_URL"; then
    echo "fetch-tzdata: tzcode download failed (need matching zic; $CODE_URL)" >&2
    exit 1
fi

STAGE="$TMP/extract"
mkdir -p "$STAGE"
tar -xzf "$TMP/$TARBALL" -C "$STAGE"

# Tarball extracts files at the top level (africa, europe, version, …).
if [[ ! -f "$STAGE/version" ]]; then
    echo "fetch-tzdata: tarball missing version file; unexpected layout" >&2
    exit 1
fi
GOT="$(tr -d '[:space:]' <"$STAGE/version")"
if [[ "$GOT" != "$VERSION" ]]; then
    echo "fetch-tzdata: warning: tarball version=$GOT requested=$VERSION" >&2
fi

mkdir -p "$(dirname "$IANA_DIR")"
rm -rf "$IANA_DIR"
mkdir -p "$IANA_DIR"
cp -a "$STAGE"/. "$IANA_DIR"/

# tzcode — vendored so `zig build pack-tzdata` can build a matching `zic`
# (host zic is often years old and truncates future transitions).
CODE_STAGE="$TMP/tzcode"
mkdir -p "$CODE_STAGE"
tar -xzf "$TMP/$CODE_TARBALL" -C "$CODE_STAGE"
rm -rf "$TZCODE_DIR"
mkdir -p "$TZCODE_DIR"
cp -a "$CODE_STAGE"/. "$TZCODE_DIR"/

# Provenance note (committed alongside sources; human-readable).
cat >"$IANA_DIR/README.cynic" <<EOF
IANA tzdata source release ${VERSION}
Fetched from ${URL}
via tools/fetch-tzdata.sh

Matching tzcode (for zic): vendor/tzdata/tzcode/ from ${CODE_URL}

Refresh: tools/fetch-tzdata.sh ${VERSION}
Pack:    zig build pack-tzdata
         (builds zic from tzcode, compiles these sources, then tools/pack_tzdata.zig)
EOF

echo "fetch-tzdata: wrote $IANA_DIR + $TZCODE_DIR (IANA ${VERSION})"

if [[ "$DO_PACK" -eq 0 ]]; then
    echo "fetch-tzdata: --no-pack; run: zig build pack-tzdata"
    exit 0
fi

need_cmd zic

# Prefer the in-tree Zig packer via `zig build` so we don't depend on a
# prebuilt zig-out; fall back to invoking zig run directly.
cd "$REPO_ROOT"
if command -v zig >/dev/null 2>&1; then
    echo "fetch-tzdata: compiling IANA sources with zic + packing CYTZ"
    zig build pack-tzdata
else
    echo "fetch-tzdata: zig not on PATH; sources updated but not packed" >&2
    echo "fetch-tzdata: run: zig build pack-tzdata" >&2
    exit 1
fi

if [[ -f "$BIN_OUT" ]]; then
    echo "fetch-tzdata: done (vendor/tzdata/cynic_tzdb.bin ready for -Dintl=full)"
fi
