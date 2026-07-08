#!/usr/bin/env bash
# Bootstrap the exact Zig toolchain pinned in build.zig.zon
# (.minimum_zig_version) into $HOME/.cache/cynic-zig/<version>/ and
# print the absolute path of the `zig` binary on stdout (everything
# else goes to stderr). Idempotent: a verified, already-extracted
# toolchain short-circuits the network entirely.
#
# Why this exists: anyzig / setup-zig resolve the same pin, but both
# need ziglang.org or the community mirrors. Restricted-egress
# environments (e.g. Claude Code cloud containers, where outbound
# HTTPS passes a policy proxy that only allows a github.com-shaped
# hole) can reach neither — so the repo mirrors the pinned tarball
# onto its own `zig-toolchain` GitHub Release (see
# .github/workflows/mirror-zig-toolchain.yml, which minisign-verifies
# every byte against upstream's key before upload).
#
# Source order (first verified download wins):
#   1. the repo's zig-toolchain GitHub Release   (works everywhere github.com does)
#   2. the Zig community mirrors                  (live list, hardcoded fallback)
#   3. ziglang.org itself                         (/builds for dev pins, /download for tagged)
#
# Verification: SHA-256 against the embedded known-good table below
# (refreshed from the release's SHA256SUMS whenever the pin bumps);
# for a version not in the table, against the release's SHA256SUMS;
# failing that, minisign against upstream's key if `minisign` is on
# PATH. An unverifiable tarball is refused unless
# CYNIC_ZIG_FETCH_ALLOW_UNVERIFIED=1.
#
# Usage:
#   tools/fetch-zig.sh                                   # prints .../zig
#   export PATH="$(dirname "$(tools/fetch-zig.sh)"):$PATH"
#
# Respects HTTPS_PROXY et al. via curl's environment handling; never
# disables TLS verification.

set -euo pipefail

log() { printf '%s\n' "$*" >&2; }
die() { log "fetch-zig: ERROR: $*"; exit 1; }

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

VERSION="$(grep -m1 '\.minimum_zig_version' "$ROOT/build.zig.zon" | sed 's/.*"\(.*\)".*/\1/')"
[ -n "$VERSION" ] || die "could not read .minimum_zig_version from $ROOT/build.zig.zon"

case "$(uname -m)" in
  x86_64|amd64)  ARCH=x86_64  ;;
  aarch64|arm64) ARCH=aarch64 ;;
  *) die "unsupported architecture: $(uname -m)" ;;
esac
case "$(uname -s)" in
  Linux)  OS=linux  ;;
  Darwin) OS=macos  ;;
  *) die "unsupported OS: $(uname -s)" ;;
esac

# Naming convention for >= 0.14.1 / 0.15.0-dev: zig-<arch>-<os>-<version>.
# (Older tarballs reversed the fields; the pin never goes back there.)
TARBALL_DIR="zig-$ARCH-$OS-$VERSION"
TARBALL="$TARBALL_DIR.tar.xz"

PREFIX="${CYNIC_ZIG_PREFIX:-$HOME/.cache/cynic-zig}"
DEST="$PREFIX/$VERSION"
BIN="$DEST/$TARBALL_DIR/zig"

# Known-good SHA-256 per tarball, produced by the mirror-zig-toolchain
# workflow (which minisign-verifies against upstream's key before
# hashing). Refresh alongside every .minimum_zig_version bump.
embedded_sha256() {
  case "$1" in
    zig-x86_64-linux-0.17.0-dev.813+2153f8143.tar.xz)  echo "b0d46ffc4587b9e8dd0b524ee5bc4da1e67f28bba55e7c534cec64af2f2d7a74" ;;
    zig-aarch64-linux-0.17.0-dev.813+2153f8143.tar.xz) echo "aa67b418d50bdde3043cfe765016d5387a2333b514ada2c57f24baae4005c331" ;;
    zig-aarch64-macos-0.17.0-dev.813+2153f8143.tar.xz) echo "36673d2513afa4a96c86780648ba504beedd7f0451389091cf9d53e38d5b4840" ;;
    zig-x86_64-macos-0.17.0-dev.813+2153f8143.tar.xz)  echo "3938c46ae4bca3c13f423b09503e3ef00bb4b7ef12b8bc1e5122ede366057a5b" ;;
    *) echo "" ;;
  esac
}

# ---- idempotence: reuse a working extraction --------------------------------
if [ -x "$BIN" ] && [ "$("$BIN" version 2>/dev/null || true)" = "$VERSION" ]; then
  log "fetch-zig: using cached toolchain at $BIN"
  printf '%s\n' "$BIN"
  exit 0
fi

command -v curl >/dev/null || die "curl is required"
command -v tar  >/dev/null || die "tar is required"
command -v xz   >/dev/null || die "xz is required"
if command -v sha256sum >/dev/null; then
  sha256_of() { sha256sum "$1" | awk '{print $1}'; }
elif command -v shasum >/dev/null; then
  sha256_of() { shasum -a 256 "$1" | awk '{print $1}'; }
else
  die "need sha256sum or shasum"
fi

RELEASE_BASE="https://github.com/chicoxyzzy/cynic/releases/download/zig-toolchain"
MINISIGN_KEY="RWSGOq2NVecA2UPNdBUZykf1CCb147pkmdtYxgb3Ti+JO/wCYvhbAb/U"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/cynic-fetch-zig.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

fetch() { # url -> file; quiet failure
  curl -fsSL --max-time 600 --retry 2 -o "$2" "$1" 2>/dev/null
}

verify() { # path-to-tarball source-base -> 0 if trusted
  want="$(embedded_sha256 "$TARBALL")"
  if [ -n "$want" ]; then
    have="$(sha256_of "$1")"
    if [ "$have" = "$want" ]; then
      log "fetch-zig: SHA-256 OK (embedded pin)"
      return 0
    fi
    log "fetch-zig: SHA-256 mismatch: want $want, have $have"
    return 1
  fi
  # No embedded hash (pin bumped without refreshing the table):
  # try the release's SHA256SUMS, then minisign.
  if fetch "$RELEASE_BASE/SHA256SUMS" "$WORK/SHA256SUMS"; then
    want="$(awk -v f="$TARBALL" '$2==f || $2=="*"f {print $1; exit}' "$WORK/SHA256SUMS")"
    if [ -n "$want" ]; then
      have="$(sha256_of "$1")"
      if [ "$have" = "$want" ]; then
        log "fetch-zig: SHA-256 OK (release SHA256SUMS)"
        return 0
      fi
      log "fetch-zig: SHA-256 mismatch against release SHA256SUMS"
      return 1
    fi
  fi
  if command -v minisign >/dev/null; then
    if fetch "$(asset_url "$2" "$TARBALL.minisig")" "$1.minisig" \
       && minisign -Vm "$1" -x "$1.minisig" -P "$MINISIGN_KEY" >/dev/null 2>&1; then
      log "fetch-zig: minisign OK"
      return 0
    fi
    log "fetch-zig: minisign verification failed"
    return 1
  fi
  if [ "${CYNIC_ZIG_FETCH_ALLOW_UNVERIFIED:-0}" = "1" ]; then
    log "fetch-zig: WARNING: no verification path available; proceeding because CYNIC_ZIG_FETCH_ALLOW_UNVERIFIED=1"
    return 0
  fi
  log "fetch-zig: refusing unverifiable tarball (no embedded hash, no SHA256SUMS entry, no minisign). Set CYNIC_ZIG_FETCH_ALLOW_UNVERIFIED=1 to override."
  return 1
}

# ---- source list ------------------------------------------------------------
SOURCES="$RELEASE_BASE"
MIRRORS="$(curl -fsSL --max-time 10 https://ziglang.org/download/community-mirrors.txt 2>/dev/null || true)"
if [ -z "$MIRRORS" ]; then
  # Hardcoded fallback (mlugg/setup-zig's list).
  MIRRORS="https://pkg.machengine.org/zig
https://zigmirror.hryx.net/zig
https://zig.linus.dev/zig
https://zig.squirl.dev
https://zig.florent.dev
https://zig.mirror.mschae23.de/zig
https://zigmirror.meox.dev
https://ziglang.freetls.fastly.net
https://zig.tilok.dev
https://zig-mirror.tsimnet.eu/zig
https://zig.karearl.com/zig
https://pkg.earth/zig
https://fs.liujiacai.net/zigbuilds"
fi
case "$VERSION" in
  *-dev*) CANONICAL="https://ziglang.org/builds" ;;
  *)      CANONICAL="https://ziglang.org/download/$VERSION" ;;
esac
SOURCES="$(printf '%s\n%s\n%s\n' "$SOURCES" "$MIRRORS" "$CANONICAL" | grep -v '^$')"

# ---- download + verify ------------------------------------------------------
# GitHub release-asset URLs need the '+' in the version percent-encoded;
# the community mirrors and ziglang.org take it literally.
asset_url() {
  if [ "$1" = "$RELEASE_BASE" ]; then
    printf '%s/%s\n' "$1" "${2//+/%2B}"
  else
    printf '%s/%s\n' "$1" "$2"
  fi
}

GOT=""
while IFS= read -r src; do
  log "fetch-zig: trying $src/$TARBALL"
  if fetch "$(asset_url "$src" "$TARBALL")" "$WORK/$TARBALL"; then
    if verify "$WORK/$TARBALL" "$src"; then
      GOT=1
      break
    fi
    rm -f "$WORK/$TARBALL" "$WORK/$TARBALL.minisig"
  fi
done <<< "$SOURCES"

[ -n "$GOT" ] || die "could not obtain zig-$ARCH-$OS-$VERSION from any source (repo release, community mirrors, ziglang.org). Check network/proxy policy; see .github/workflows/mirror-zig-toolchain.yml for repopulating the repo release."

# ---- extract ----------------------------------------------------------------
mkdir -p "$DEST"
tar -C "$DEST" -xJf "$WORK/$TARBALL"

[ -x "$BIN" ] || die "extraction finished but $BIN is missing"
ACTUAL="$("$BIN" version)"
[ "$ACTUAL" = "$VERSION" ] || die "extracted zig reports '$ACTUAL', expected '$VERSION'"

log "fetch-zig: installed $VERSION at $BIN"
printf '%s\n' "$BIN"
