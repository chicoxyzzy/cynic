#!/usr/bin/env bash
#
# remote-run.sh — run an arbitrary command on the configured remote against
# a git ref, so heavy builds / test sweeps / benches run off your laptop.
#
#   tools/bench/remote-run.sh origin/my-branch zig build test-fast
#   tools/bench/remote-run.sh origin/my-branch zig build test262 -- --quiet
#
# Serialised by an flock on the remote: jobs never overlap (overlap would
# contend for CPU). A second caller queues. Crucially the remote does
# `git checkout` and NEVER `git clean`, so its warm zig-cache and
# test262 pass-cache survive between runs — each ref's build is incremental,
# so even the serialised queue stays fast.
#
# Generic — see tools/bench/README.md to configure the remote. With none
# configured this errors; just run the command locally instead.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tools/bench/lib-remote.sh
. "$DIR/lib-remote.sh"
load_remote || exit 1

REF="${1:?usage: remote-run.sh <ref> <command...>}"
shift
[ "$#" -gt 0 ] || { echo "remote-run: no command given" >&2; exit 1; }
LOCK_WAIT="${CYNIC_LOCK_WAIT:-2400}"

echo ">> $CYNIC_REMOTE [$REF]: $* (queues behind any running job)" >&2
ssh "${SSH_OPTS[@]}" "$CYNIC_REMOTE" \
  "flock -w $LOCK_WAIT /var/lock/cynic-box.lock bash -s" "$CYNIC_REMOTE_DIR" "$REF" "$*" <<'REMOTE'
set -euo pipefail
DIR="$1"; REF="$2"; CMD="$3"
export PATH="/usr/local/bin:$PATH"
export JSVU_BIN="$HOME/.jsvu/bin"
cd "$DIR"
git fetch --all --quiet --prune
# checkout, never clean — keeps the warm .zig-cache + .test262-pass-cache so
# builds are incremental across refs and across agents.
git checkout --detach --quiet "$REF"
eval "$CMD"
REMOTE
