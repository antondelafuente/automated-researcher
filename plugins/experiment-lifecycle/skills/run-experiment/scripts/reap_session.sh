#!/bin/bash
# reap_session.sh — the terminal close action: free the finished executor's own SESSION process, symmetric
# with pod-teardown. PRODUCT helper — substrate-neutral, no session-kill mechanics here (no tmux, no session
# naming). It decides WHEN a session may be reaped and hands the opaque handle to the INSTANCE seam, which
# owns HOW. Called as the very last step of Step-5 Close, from inside the session being closed.
#
# CONTRACT (the three fail-closed gates):
#   1. CLEAN-CLOSE GUARD: reap only if the run-supervision record is a clean close
#      (`run_supervision_record.sh is-closed` = closed AND NOT stopped). A parked/blocked run is
#      desired-active (never closed) and a deliberately-stopped run is excluded — neither is ever reaped,
#      so a run that must survive for resume keeps its session. absent/invalid/active also refuse.
#   2. HANDLE: read the `session-handle` from the record. No handle recorded -> nothing to reap
#      (exit 0). The product NEVER interprets the handle; it is the instance's own binding (tmux name,
#      systemd unit, pid-file, ...). It is NOT a free-choice string, though: the seam below compares it
#      against the CURRENT session's own identity, so the recorded value must be exactly what the seam
#      derives for itself. `run_supervision_record.sh start` binds that by construction from the
#      instance's `EXPERIMENT_SESSION_HANDLE_CMD` self-identity seam when the executor omits
#      `--session-handle` — a hand-written near-miss (`tmux:<name>` vs `<name>`) made this refuse twice,
#      and a closed record is terminal by the time reap runs, so it was uncorrectable (#673).
#   3. SELF-ONLY SEAM: the instance seam `EXPERIMENT_SESSION_REAP_CMD` (a word-split command string, the
#      *_CMD convention) is invoked with the handle as its FINAL argument. This is SELF-reap: the seam MUST
#      verify the CURRENT session's own identity matches
#      the handle before killing anything, and FAIL CLOSED on a mismatch — so a stale or misbound handle
#      reaps NOTHING, never a peer's reused session. The product cannot check instance identity, so this
#      guarantee lives in the seam; this helper only invokes it from within the closing session.
#   Unset `EXPERIMENT_SESSION_REAP_CMD` -> documented NO-OP (exit 0): an instance with no session-teardown
#   mechanism keeps working unchanged; the process simply isn't freed at close (the deferred janitor is the
#   backstop). The transcript persists on disk regardless — this frees the process, not the record.
#
# The seam is an INSTANCE MODULE seam resolved LIVE at close (like the deploy-account teardown key), NOT a
# field frozen into the START.md brief — the reap command is instance-wide, not experiment-specific.
#
# USAGE: reap_session.sh <run-id>
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REC="$SCRIPT_DIR/run_supervision_record.sh"

die(){ echo "reap_session: $*" >&2; exit 1; }

[ $# -eq 1 ] || die "usage: reap_session.sh <run-id>"
id=$1
[ -x "$REC" ] || [ -f "$REC" ] || die "run_supervision_record.sh not found next to reap_session.sh"

# Gate 1 — clean-close guard (fail closed on anything but a clean close).
if ! bash "$REC" is-closed "$id"; then
  die "refusing to reap '$id': not a clean close (parked/blocked/stopped/active/unknown are never reaped)"
fi

# Gate 2 — the opaque handle; absent handle => nothing to reap.
handle=$(bash "$REC" session-handle "$id" 2>/dev/null || true)
if [ -z "$handle" ]; then
  echo "reap_session: no session handle recorded for '$id' — nothing to reap (no-op)"
  exit 0
fi

# Gate 3 — the self-only instance seam. Unset => documented no-op.
if [ -z "${EXPERIMENT_SESSION_REAP_CMD:-}" ]; then
  echo "reap_session: EXPERIMENT_SESSION_REAP_CMD not configured — session self-reap is a no-op on this instance"
  exit 0
fi

# Terminal action: hand the opaque handle to the instance seam, which reaps THIS session (verifying
# self==handle, fail-closed on mismatch). The seam is a COMMAND STRING word-split like gpu-job's
# GPU_JOB_*_CMD provider seams (so "reaper --self" or "bash /path/reap.sh" both work); the handle is passed
# as a quoted final argument, never re-parsed (injection-safe). Nothing runs after this by design.
echo "reap_session: reaping own session for '$id' via EXPERIMENT_SESSION_REAP_CMD"
# shellcheck disable=SC2086  # intentional word-split of the command string (the *_CMD seam convention)
exec $EXPERIMENT_SESSION_REAP_CMD "$handle"
