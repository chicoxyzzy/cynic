#!/usr/bin/env bash
#
# provision-remote.sh — install the toolchain on the configured remote so it
# can build + bench + test Cynic. Idempotent: re-runnable any time. Targets a
# fresh Ubuntu host reachable as $CYNIC_REMOTE (see tools/bench/README.md).
#
# Installs build deps, the EXACT pinned Zig from build.zig.zon (reproducible
# toolchain, same as CI), the cross-engine peers via jsvu, and a Cynic
# checkout at /opt/cynic. Assumes an x86-64 host; for arm64, set
# CYNIC_REMOTE_ARCH=aarch64.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tools/bench/lib-remote.sh
. "$DIR/lib-remote.sh"
load_remote || exit 1

ARCH="${CYNIC_REMOTE_ARCH:-x86_64}"
echo ">> provisioning $CYNIC_REMOTE (Zig + peers + checkout) — first run takes a few minutes" >&2

ssh "${SSH_OPTS[@]}" "$CYNIC_REMOTE" 'bash -s' "$ARCH" "$CYNIC_REMOTE_DIR" <<'REMOTE'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
ZIG_ARCH="$1"; DEST="$2"
REPO_URL="https://github.com/chicoxyzzy/cynic.git"

if ! command -v git >/dev/null 2>&1; then
  echo ">> installing build deps"
  apt-get update -qq
  apt-get install -y -qq git curl xz-utils build-essential
fi

if [ ! -d "$DEST/.git" ]; then
  echo ">> cloning Cynic"
  git clone --quiet "$REPO_URL" "$DEST"
fi
cd "$DEST"
git fetch --all --quiet --prune

# Pinned Zig from build.zig.zon — same field CI's setup-zig reads, fetched by
# exact version so the remote matches CI and the laptop bit-for-bit.
VER=$(grep -oE '0\.[0-9]+\.[0-9]+-dev\.[0-9]+\+[0-9a-f]+' build.zig.zon | head -1)
ZIG_DIR="/opt/zig-$VER"
if [ ! -x "$ZIG_DIR/zig" ]; then
  url="https://ziglang.org/builds/zig-${ZIG_ARCH}-linux-${VER}.tar.xz"
  echo ">> fetching Zig $VER"
  curl -fsSL "$url" -o /tmp/zig.tar.xz
  mkdir -p "$ZIG_DIR"
  tar -xJf /tmp/zig.tar.xz -C "$ZIG_DIR" --strip-components=1
fi
ln -sf "$ZIG_DIR/zig" /usr/local/bin/zig

# Cross-engine peers for tools/bench-cross.sh, via jsvu. Installed once so
# the versions freeze until a deliberate refresh — the cross-engine "same
# prerequisites" pin. jsvu degrades per engine; bench-cross.sh skips any
# peer that isn't present (jsc has no reliable Linux jsvu build).
if ! command -v node >/dev/null 2>&1; then
  echo ">> installing Node (for jsvu)"
  curl -fsSL https://deb.nodesource.com/setup_20.x | bash - >/dev/null 2>&1
  apt-get install -y -qq nodejs
fi
if [ ! -d "$HOME/.jsvu/bin" ] || [ -z "$(ls -A "$HOME/.jsvu/bin" 2>/dev/null)" ]; then
  echo ">> installing JS engines via jsvu (v8, sm, qjs, hermes, xs)"
  npm install -g jsvu --silent >/dev/null 2>&1 || npm install -g jsvu
  jsvu --os=linux64 --engines=v8,spidermonkey,quickjs,hermes,xs || true
fi
# JavaScriptCore — jsvu has no Linux JSC build, so use WebKitGTK's jsc CLI
# (apt `libjavascriptcoregtk-bin` → /usr/bin/jsc). apt is idempotent.
if [ ! -x /usr/bin/jsc ]; then
  echo ">> installing JavaScriptCore (WebKitGTK jsc)"
  apt-get install -y -qq libjavascriptcoregtk-bin || true
fi
echo ">> peers present: $(ls "$HOME/.jsvu/bin" 2>/dev/null | tr '\n' ' ')$([ -x /usr/bin/jsc ] && echo 'jsc')"
echo ">> remote ready — zig $(zig version)"
REMOTE
