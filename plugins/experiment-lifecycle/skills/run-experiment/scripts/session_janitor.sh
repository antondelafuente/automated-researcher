#!/bin/bash
# session_janitor.sh — the BOX-LEVEL, MODEL-FREE session reaper: the pod_reaper.sh analog for sessions
# (fast-follow to #282's self-reap; automated-researcher#285). Self-reap (reap_session.sh) frees a
# finished executor's own session at clean close, but it only fires FROM INSIDE the closing session — a
# crashed close (the executor dies before reap_session.sh runs, or the close never finalizes) leaves the
# session resident indefinitely. This is the standing backstop for that crash class, same split as
# pod_reaper.sh: the PRODUCT owns the whole reap DECISION over the run-supervision record registry
# (run_supervision_record.sh); the INSTANCE supplies the session mechanics as command seams + the
# schedule (systemd timer / loop).
#
# THE CONTRACT (fail-closed, never blanket-kill):
#   reap        — a run-supervision record that is a CLEAN CLOSE (`is-closed`: closed && !stopped),
#                 whose recorded `session-handle` matches a LIVE session, AND that session reads IDLE.
#                 Killed, then re-verified gone.
#   keep        — anything not reapable for an ORDINARY reason: not yet closed, no handle recorded, a
#                 closed record whose handle is already gone (the common case — self-reap already ran),
#                 or a closed+live session that isn't idle yet (retry next sweep).
#   report-only — an ANOMALY worth a human/senior-triage look, NEVER killed:
#                   - a LIVE session with NO matching run-supervision record at all (unknown/orphan
#                     session — mirrors pod_reaper's "never delete an unknown pod" rule)
#                   - a still-DESIRED-ACTIVE record whose recorded handle is NOT live (the deeper crash
#                     class: the executor died before ever reaching Step-5 close, so self-reap never had
#                     a chance to run either — the product can observe this directly, without any
#                     external/main-branch knowledge, as "should be running, isn't")
#                   - an INCONCLUSIVE idleness read on an otherwise-reapable candidate (never a license
#                     to kill; report-and-retry next sweep, same as pod_reaper's legacy-keepalive read)
#                   - a MALFORMED run-supervision record file
#                   - more than one CLOSED record bound to the SAME session-handle, OR a closed record
#                     sharing a handle with an active/stopped one (registry ambiguity — which one
#                     actually owns it? never guess)
#
# SEAM DESIGN — this CANNOT reuse reap_session.sh's EXPERIMENT_SESSION_REAP_CMD: that seam is SELF-ONLY
#   BY CONTRACT (it must verify the current session's own identity == the handle and fail closed on a
#   mismatch). A janitor is by construction not-self, so it needs its own pod_reaper-style seams, all
#   instance-owned:
#     SESSION_JANITOR_LIST_CMD  ""               -> prints one LIVE session handle per line
#     SESSION_JANITOR_IDLE_CMD  "<cmd> <handle>" -> prints idle|active|"" (""=inconclusive)
#     SESSION_JANITOR_KILL_CMD  "<cmd> <handle>" -> kills the session; exit 0 on accepted kill
#   The instance-level guard "only dispatched run-<slug> sessions, never a persistent worker" lives in
#   the instance's OWN list/kill commands — the product has no session-naming convention of its own.
#   Unset SESSION_JANITOR_LIST_CMD -> documented NO-OP (exit 0), same convention as reap_session.sh's
#   unset EXPERIMENT_SESSION_REAP_CMD: an instance with no janitor wiring keeps working unchanged. A
#   PARTIAL config (list set, idle or kill missing) is NOT "no janitor configured" — it fails loudly
#   instead of silently doing incomplete work.
#
# --dry-run: log every would-kill (and every report-only line), kill nothing. Roll the sweep out
#   dry-run first, same as pod_reaper.
#
# USAGE: session_janitor.sh [--dry-run]
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
REC="$HERE/run_supervision_record.sh"
[ -f "$REC" ] || { echo "session_janitor: run_supervision_record.sh not found next to session_janitor.sh" >&2; exit 1; }

DRY=0
[ "${1:-}" = "--dry-run" ] && { DRY=1; shift; }
# Reject any other/leftover argument — a typo like `--dryrun` must NOT silently run a LIVE kill sweep.
[ $# -eq 0 ] || { echo "session_janitor: unexpected argument(s): $* (only optional --dry-run is accepted)" >&2; exit 2; }

log(){ echo "[janitor $(date -u +%H:%M:%S)] $*"; }

# unset LIST_CMD -> the whole sweep is a documented no-op (no instance janitor wiring yet).
if [ -z "${SESSION_JANITOR_LIST_CMD:-}" ]; then
  echo "session_janitor: SESSION_JANITOR_LIST_CMD not configured — session janitor sweep is a no-op on this instance"
  exit 0
fi
# a PARTIAL config (list set, idle/kill missing) is a misconfiguration, not "no janitor" — fail loud
# rather than silently sweeping with half the decision unavailable.
[ -n "${SESSION_JANITOR_IDLE_CMD:-}" ] || { echo "session_janitor: SESSION_JANITOR_LIST_CMD is set but SESSION_JANITOR_IDLE_CMD is not — refusing a partial sweep" >&2; exit 2; }
[ -n "${SESSION_JANITOR_KILL_CMD:-}" ] || { echo "session_janitor: SESSION_JANITOR_LIST_CMD is set but SESSION_JANITOR_KILL_CMD is not — refusing a partial sweep" >&2; exit 2; }

list_sessions(){ $SESSION_JANITOR_LIST_CMD; }             # one live handle per line
idle_state(){ $SESSION_JANITOR_IDLE_CMD "$1"; }           # idle|active|"" (inconclusive)
kill_session(){ $SESSION_JANITOR_KILL_CMD "$1"; }         # exit 0 on accepted kill

# `list`'s state column collapses a stopped-then-closed record to "closed" too (classify_record checks
# closed before stopped); is-closed is the only reliable "genuine clean close" predicate (closed &&
# !stopped). A record must never be treated as reapable off the list state alone.
is_clean_close(){ bash "$REC" is-closed "$1" >/dev/null 2>&1; } # <run-id>

reaped=0; kept=0; reported=0; retried=0

# --- live session inventory (read once; re-read after an actual kill to verify) --------------------
# A failed listing must never be silently read as "no live sessions" — that would misreport a live
# desired-active session as the deeper-crash anomaly, and misreport a live unknown session as absent.
# Abort loudly instead of sweeping on an inventory we can't trust.
declare -A LIVE
LIVE_OUT=$(list_sessions) || { echo "session_janitor: SESSION_JANITOR_LIST_CMD failed — aborting sweep (refusing to make reap decisions without a reliable live-session inventory)" >&2; exit 1; }
while IFS= read -r h; do
  [ -n "${h:-}" ] || continue
  LIVE["$h"]=1
done <<< "$LIVE_OUT"

# --- run-supervision record registry ---------------------------------------------------------------
# A failed listing must never be silently read as "no records" — that would leave every live session
# looking unknown/orphan instead of surfacing the real anomaly. Abort loudly, same as the live-session
# inventory above.
RECORDS_OUT=$(bash "$REC" list) || { echo "session_janitor: run_supervision_record.sh list failed — aborting sweep (refusing to make reap decisions without a reliable record inventory)" >&2; exit 1; }
mapfile -t RECORDS <<< "$RECORDS_OUT"

# Only KNOWN_HANDLE is snapshotted here — it feeds step 2's report-only "unknown live session" check,
# which never kills anything, so a snapshot that goes stale mid-sweep is harmless. The handle-ambiguity
# check that GATES a kill is deliberately NOT precomputed here: see handle_ambiguous() below, re-checked
# fresh immediately before each kill so a record created/updated for a handle after this snapshot (e.g.
# while an idle probe is in flight) still blocks it.
declare -A KNOWN_HANDLE
for line in "${RECORDS[@]}"; do
  [ -n "$line" ] || continue
  id=${line%% *}; state=${line#* }
  [ -n "$id" ] || continue
  h=$(bash "$REC" session-handle "$id" 2>/dev/null || true)
  [ -n "$h" ] || continue
  KNOWN_HANDLE["$h"]=1
done

# Fresh re-check for handle ambiguity, called as LATE as possible (immediately before a kill) instead of
# off a sweep-start snapshot: a record created/updated for this handle after the snapshot — e.g. while
# the idle probe in consider_record is in flight — must still block the kill. run_supervision_record.sh
# only locks a SINGLE record's own read-modify-write, so there is no cross-record lock this janitor can
# take; this narrows the race window to "between this re-check and the kill call" rather than eliminating
# it (the same residual gap any reader of a multi-record registry like this has).
handle_ambiguous(){ # <handle> -> exit 0 iff ambiguous (never kill), 1 iff this handle's ownership is clear
  local h=$1 closed_n=0 line id state hh fresh
  fresh=$(bash "$REC" list) || return 0   # can't verify the registry right now -> never guess, block the kill
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    id=${line%% *}; state=${line#* }
    [ -n "$id" ] || continue
    hh=$(bash "$REC" session-handle "$id" 2>/dev/null || true)
    [ "$hh" = "$h" ] || continue
    if [ "$state" = closed ] && is_clean_close "$id"; then
      closed_n=$((closed_n+1))
    else
      return 0   # a non-clean-close (active/stopped/stopped-then-closed) record also claims this handle
    fi
  done <<< "$fresh"
  [ "$closed_n" -gt 1 ]
}

# Decide for one record.
consider_record(){ # <run-id> <state>
  local id=$1 state=$2
  if [ "$state" = invalid ]; then
    log "report-only (MALFORMED run-supervision record — inspect): run-id=$id"; reported=$((reported+1)); return
  fi
  local h; h=$(bash "$REC" session-handle "$id" 2>/dev/null || true)
  if [ "$state" != closed ] || ! is_clean_close "$id"; then
    # Not a GENUINE clean close: never yet closed, OR a stopped-then-closed terminal record (the
    # deliberate-quit finalize — `list`'s state column collapses that to "closed" too, but is-closed
    # correctly excludes it). reap_session.sh's own guard already keeps these forever (parked/blocked/
    # stopped/stopped-then-closed never reap). The one anomaly the janitor CAN observe here, with no
    # external/main-branch knowledge, is a still-desired-active record whose bound handle is no longer
    # live at all — the executor died before ever reaching close (self-reap never had a chance to run
    # either). Report it, never guess. (is-desired-active itself already excludes stopped/closed records,
    # so a stopped-then-closed record falls through to the plain "kept" branch, never reported.)
    if [ -n "$h" ] && [ -z "${LIVE[$h]:-}" ] && bash "$REC" is-desired-active "$id" >/dev/null 2>&1; then
      log "report-only (desired-active record, session NOT live — never reached close, the deeper crash class): run-id=$id handle=$h"
      reported=$((reported+1))
    else
      kept=$((kept+1))
    fi
    return
  fi
  # From here on: a genuine clean close (closed && !stopped).
  if [ -z "$h" ]; then
    kept=$((kept+1)); return    # nothing recorded to reap — mirrors reap_session.sh's own no-handle no-op
  fi
  if [ -z "${LIVE[$h]:-}" ]; then
    kept=$((kept+1)); return    # already gone — the common path (self-reap already ran)
  fi
  local idle; idle=$(idle_state "$h")
  case "$idle" in
    active) kept=$((kept+1)); return;;
    "")     log "report-retry (inconclusive idleness read): run-id=$id handle=$h"; retried=$((retried+1)); return;;
    idle)   : ;;   # both a clean close AND idle -> reap
    *)      log "report-retry (unrecognized idleness verdict '$idle'): run-id=$id handle=$h"; retried=$((retried+1)); return;;
  esac
  # Authoritative ambiguity gate, re-checked fresh right here (see handle_ambiguous above) — the latest
  # point before the kill, after whatever time the idle probe above took.
  if handle_ambiguous "$h"; then
    log "report-only (AMBIGUOUS records bound to session $h — registry ambiguity, NOT killing): run-id=$id"
    reported=$((reported+1)); return
  fi
  if [ "$DRY" = 1 ]; then
    log "DRY-RUN would reap: run-id=$id handle=$h"; reaped=$((reaped+1)); return
  fi
  if kill_session "$h"; then
    local relist
    if relist=$(list_sessions); then
      local -A LIVE2
      while IFS= read -r hh; do [ -n "${hh:-}" ] && LIVE2["$hh"]=1; done <<< "$relist"
      if [ -z "${LIVE2[$h]:-}" ]; then
        log "REAPED: run-id=$id handle=$h (kill accepted + verified gone)"; reaped=$((reaped+1))
      else
        log "RETRY: run-id=$id handle=$h kill accepted but session still listed live — next sweep will retry"; retried=$((retried+1))
      fi
    else
      log "RETRY: run-id=$id handle=$h kill accepted but post-kill listing failed — cannot verify gone, next sweep will retry"; retried=$((retried+1))
    fi
  else
    log "RETRY: run-id=$id handle=$h kill not accepted — next sweep will retry"; retried=$((retried+1))
  fi
}

DRY_TAG=""; [ "$DRY" = 1 ] && DRY_TAG=" (DRY-RUN)"
log "sweep start${DRY_TAG} root=${AAR_RUN_SUPERVISION_DIR:-$HOME/.config/run-supervision}"

# 1. Reap/keep/report over the run-supervision record registry.
for line in "${RECORDS[@]}"; do
  [ -n "$line" ] || continue
  id=${line%% *}; state=${line#* }
  consider_record "$id" "$state"
done

# 2. report-only: a LIVE session with NO matching record at all (unknown/orphan session — never killed).
for h in "${!LIVE[@]}"; do
  [ -n "${KNOWN_HANDLE[$h]:-}" ] && continue
  log "report-only (UNKNOWN live session, no matching record — NEVER killed): handle=$h"
  reported=$((reported+1))
done

DONE_TAG=""; [ "$DRY" = 1 ] && DONE_TAG=" (DRY-RUN — nothing killed)"
log "sweep done: reaped=$reaped kept=$kept reported=$reported retried=$retried${DONE_TAG}"
