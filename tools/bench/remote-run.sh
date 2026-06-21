#!/usr/bin/env bash
#
# remote-run.sh — run a command on the configured remote against a git ref,
# off your laptop, as a DETACHED job that survives the local ssh dying (e.g.
# a Claude Code restart). Submit launches the job under setsid+flock on the
# box and returns a JOB_ID; the job writes its output + an exit-sentinel to
# /tmp/jobs/<id>. Polling is short, stateless, and re-runnable with the same
# id after a restart — so a multi-minute sweep is no longer at the mercy of
# local-process lifetime.
#
#   remote-run.sh <ref> <cmd...>          submit, then wait (prints JOB_ID first)
#   remote-run.sh --submit <ref> <cmd...> submit only, print JOB_ID, return
#   remote-run.sh --wait <id>             wait for an existing job; print log
#   remote-run.sh --status <id>           empty = running, a number = exit code
#   remote-run.sh --tail <id> [N]         last N lines of the job log
#
# Serialised by an flock on the remote (held by the detached job). The remote
# does `git checkout`, never `git clean`, so its warm zig-cache + test262
# pass-cache survive; the test262 submodule is synced per ref.
#
# Generic — see tools/bench/README.md to configure the remote. With none
# configured this errors; just run the command locally instead.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tools/bench/lib-remote.sh
. "$DIR/lib-remote.sh"
load_remote || exit 1

case "${1:-}" in
  --status)
    [ -n "${2:-}" ] || { echo "usage: remote-run.sh --status <id>" >&2; exit 1; }
    st="$(job_status "$2")"; echo "${st:-running}"; exit 0 ;;
  --tail)
    [ -n "${2:-}" ] || { echo "usage: remote-run.sh --tail <id> [N]" >&2; exit 1; }
    job_tail "$2" "${3:-40}"; exit 0 ;;
  --wait)
    [ -n "${2:-}" ] || { echo "usage: remote-run.sh --wait <id>" >&2; exit 1; }
    echo ">> waiting on $2 (re-runnable after a restart: remote-run.sh --wait $2)" >&2
    rc=0; job_wait "$2" || rc=$?
    job_tail "$2" 500
    echo ">> $2 finished, exit $rc" >&2
    exit "$rc" ;;
  --submit)
    shift
    ref="${1:?usage: remote-run.sh --submit <ref> <cmd...>}"; shift
    [ "$#" -gt 0 ] || { echo "remote-run: no command given" >&2; exit 1; }
    job="$(job_submit "$ref" "$*")"
    echo ">> submitted $job on $CYNIC_REMOTE [$ref]" >&2
    echo ">> poll:  tools/bench/remote-run.sh --wait $job" >&2
    echo "$job" ;;
  ""|-*)
    echo "usage: remote-run.sh <ref> <cmd...> | --submit|--wait|--status|--tail <id>" >&2
    exit 1 ;;
  *)
    # Default: submit + wait. The JOB_ID is printed FIRST so a restart can
    # resume — the job keeps running on the box regardless.
    ref="$1"; shift
    [ "$#" -gt 0 ] || { echo "remote-run: no command given" >&2; exit 1; }
    job="$(job_submit "$ref" "$*")"
    echo ">> submitted $job on $CYNIC_REMOTE [$ref]: $*" >&2
    echo ">> if this disconnects, resume with:  tools/bench/remote-run.sh --wait $job" >&2
    rc=0; job_wait "$job" || rc=$?
    job_tail "$job" 500
    echo ">> $job finished, exit $rc" >&2
    exit "$rc" ;;
esac
