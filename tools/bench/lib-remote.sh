#!/usr/bin/env bash
#
# lib-remote.sh — shared helper for the OPTIONAL remote bench/test runner.
#
# Heavy builds, test sweeps, and benches can run on a remote machine you
# configure, so your laptop stays free. Nothing here is provider-specific:
# the remote is whatever `CYNIC_REMOTE` points at — an `ssh` target like
# `user@host` or an ssh-config Host alias.
#
# Configure it either way:
#   - export CYNIC_REMOTE=user@host
#   - or put it in a local env file (default ~/.config/cynic/remote.env,
#     override with CYNIC_REMOTE_ENV). That file is yours and is never
#     committed.
#
# With no remote configured the runners tell you to set one or run locally.

SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -o LogLevel=ERROR)

# Directory of the checkout on the remote (provisioned by provision-remote.sh).
CYNIC_REMOTE_DIR="${CYNIC_REMOTE_DIR:-/opt/cynic}"

load_remote() {
  if [ -z "${CYNIC_REMOTE:-}" ]; then
    local envf="${CYNIC_REMOTE_ENV:-$HOME/.config/cynic/remote.env}"
    # shellcheck disable=SC1090
    [ -f "$envf" ] && . "$envf"
  fi
  [ -n "${CYNIC_REMOTE:-}" ] || {
    echo "no remote configured. Set CYNIC_REMOTE=user@host (or put it in" >&2
    echo "${CYNIC_REMOTE_ENV:-$HOME/.config/cynic/remote.env}), or run the suite locally — see tools/bench/README.md." >&2
    return 1
  }
}
