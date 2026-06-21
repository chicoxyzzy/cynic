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
# Base64-encode the command so it survives ssh's arg-flattening: ssh joins
# all its args into ONE string the remote shell re-splits on spaces, which
# would otherwise leave the remote `bash -s` seeing only the first word of a
# multi-word command (CMD=$3="zig"). base64 output has no spaces or shell
# metacharacters, so it arrives intact as a single positional arg; the
# remote decodes it before eval. Encode runs locally (BSD/GNU base64 both
# default to encode); decode runs on the Linux remote (`--decode`).
cmd_b64="$(printf '%s' "$*" | base64 | tr -d '\n')"
ssh "${SSH_OPTS[@]}" "$CYNIC_REMOTE" \
  "flock -w $LOCK_WAIT /var/lock/cynic-box.lock bash -s" "$CYNIC_REMOTE_DIR" "$REF" "$cmd_b64" <<'REMOTE'
set -euo pipefail
DIR="$1"; REF="$2"; CMD="$(printf '%s' "$3" | base64 --decode)"
export PATH="/usr/local/bin:$PATH"
export JSVU_BIN="$HOME/.jsvu/bin"
cd "$DIR"
git fetch --all --quiet --prune
# checkout, never clean — keeps the warm .zig-cache + .test262-pass-cache so
# builds are incremental across refs and across agents.
git checkout -f --detach --quiet "$REF"
# Sync the test262 submodule to this ref so `zig build test262` sweeps find
# the corpus (the box clones without submodules). A no-op once present; the
# first sweep pays the one-time fetch. Non-test262 commands just see a fast
# up-to-date check.
git submodule update --init --quiet vendor/test262 2>/dev/null || true
eval "$CMD"
REMOTE
