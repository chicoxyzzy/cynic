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

# ServerAlive* turns a genuinely dead connection into a clean error after
# ~60s of silence instead of an indefinite hang — so "alive but quiet" (a
# long bench) and "stuck/dead" become distinguishable. Keepalives are
# protocol-level, so a slow-but-healthy run is never falsely dropped.
SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=4 -o LogLevel=ERROR)

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

# --- Detached remote jobs --------------------------------------------------
# Long remote work must outlive the local ssh channel: if the laptop's
# Claude Code restarts, a SYNCHRONOUS remote job gets SIGHUP when the ssh
# dies and its streamed-only output is lost. So we SUBMIT the job detached
# (setsid → SIGHUP-immune), holding the flock for its whole life, writing
# out.log + a `status` exit-sentinel into /tmp/jobs/<id>. Polling/fetching
# are short stateless ssh ops, re-runnable with the same id after a restart.

# job_submit <ref> <cmd> -> echoes JOB_ID, returns immediately. The job
# cd's to the checkout, fetches, force-checks-out <ref> (never `git clean`,
# so the warm zig-cache survives), syncs the test262 submodule, then runs
# <cmd>. $JOB_DIR is exported into the job so it can stash result files
# there for --fetch.
job_submit() {
  local ref="$1" cmd="$2" job cmd_b64
  job="cynic-$(date +%s)-$$"
  cmd_b64="$(printf '%s' "$cmd" | base64 | tr -d '\n')"
  ssh "${SSH_OPTS[@]}" "$CYNIC_REMOTE" \
    "JOB='$job' DIR='$CYNIC_REMOTE_DIR' REF='$ref' CMD_B64='$cmd_b64' LOCK_WAIT='${CYNIC_LOCK_WAIT:-2400}' bash -s" <<'REMOTE' >/dev/null
set -euo pipefail
d="/tmp/jobs/$JOB"
mkdir -p "$d"
# TTL: drop job dirs older than a day so /tmp/jobs doesn't accumulate.
find /tmp/jobs -maxdepth 1 -type d -name 'cynic-*' -mmin +1440 -exec rm -rf {} + 2>/dev/null || true
# Write the job body to a file (no nested-quote hell; the user command is a
# literal). %q quotes the interpolated values shell-safely.
{
  echo '#!/usr/bin/env bash'
  echo 'set -uo pipefail'
  printf 'export JOB_DIR=%q\n' "$d"
  echo 'export PATH="/usr/local/bin:$PATH" JSVU_BIN="$HOME/.jsvu/bin"'
  printf 'cd %q\n' "$DIR"
  echo 'git fetch -q --all --prune'
  printf 'git checkout -f -q --detach %q\n' "$REF"
  echo 'git submodule update --init --quiet vendor/test262 2>/dev/null || true'
  printf '%s\n' "$CMD_B64" | base64 --decode
} > "$d/job.sh"
# Detached: setsid + </dev/null + & make it ignore the ssh channel closing
# (SIGHUP). The flock is held by the JOB, not the transient ssh. The status
# sentinel is the completion signal; out.log is the durable result.
setsid bash -c "flock -w $LOCK_WAIT /var/lock/cynic-box.lock bash '$d/job.sh' > '$d/out.log' 2>&1; echo \$? > '$d/status'" </dev/null >/dev/null 2>&1 &
REMOTE
  echo "$job"
}

# job_status <job> -> echoes the exit code once finished, empty while running.
job_status() {
  ssh "${SSH_OPTS[@]}" "$CYNIC_REMOTE" "cat /tmp/jobs/$1/status 2>/dev/null" || true
}

# job_wait <job> -> polls the sentinel until the job finishes; returns its
# exit code. Re-runnable after a restart with the same id.
job_wait() {
  local job="$1" st
  while :; do
    st="$(job_status "$job")"
    [ -n "$st" ] && return "$st"
    sleep "${CYNIC_POLL:-15}"
  done
}

# job_tail <job> [N] -> last N lines of the job log.
job_tail() {
  ssh "${SSH_OPTS[@]}" "$CYNIC_REMOTE" "tail -n ${2:-40} /tmp/jobs/$1/out.log 2>/dev/null" || true
}

# job_fetch_dir <job> <subdir-under-jobdir> <local-dest> -> scp a result dir.
job_fetch_dir() {
  rm -rf "$3"
  scp "${SSH_OPTS[@]}" -r "$CYNIC_REMOTE":"/tmp/jobs/$1/$2" "$3" >/dev/null 2>&1 || true
}
