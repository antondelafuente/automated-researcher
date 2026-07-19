#!/usr/bin/env bash
# Smoke for session_janitor.sh — the #285 fast-follow backstop reaper for crashed-close sessions. Runs
# OFFLINE: the instance seams (list/idle/kill) are stubs so no real session is touched. Covers the reap
# predicate + every report-only class named in the issue:
#   - reap: closed record + live handle + idle -> killed, verified gone
#   - keep: closed record whose handle is already gone (the common path, self-reap already ran)
#   - keep: not-yet-closed (active) record with a live handle, regardless of idleness
#   - keep: a deliberately-STOPPED record whose handle is no longer live (never reported as a crash)
#   - keep: closed + live but NOT idle yet (retry next sweep, no report)
#   - report-retry: an INCONCLUSIVE idleness read, never a license to kill
#   - report-only: a live session with NO matching record at all (unknown/orphan session)
#   - report-only: a still-desired-active record whose handle is NOT live (the deeper crash class)
#   - report-only: a MALFORMED run-supervision record file
#   - report-only: two CLOSED records bound to the SAME handle (registry ambiguity)
#   - report-only: a CLOSED record sharing a handle with an ACTIVE record (registry ambiguity)
#   - keep: a STOP-then-CLOSE (deliberate-quit finalize) record, live + idle -> never reaped
#   - a kill that's accepted but the session is STILL listed live afterward -> retried, not reaped
#   - a kill that's NOT accepted -> retried, not reaped
#   - --dry-run kills nothing
#   - unset SESSION_JANITOR_LIST_CMD -> whole sweep no-op; a PARTIAL config (idle/kill missing) fails loud
#   - arg validation (unknown/surplus arguments rejected)
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
J="$HERE/session_janitor.sh"
REC="$HERE/run_supervision_record.sh"
[ -f "$J" ]   || { echo "FAIL: missing $J"; exit 1; }
[ -f "$REC" ] || { echo "FAIL: missing $REC"; exit 1; }

TMP=$(mktemp -d) || { echo "FAIL: mktemp"; exit 1; }
trap 'rm -rf "$TMP"' EXIT
export AAR_RUN_SUPERVISION_DIR="$TMP/records"
mkdir -p "$AAR_RUN_SUPERVISION_DIR"

fails=0
ok(){ echo "ok   $1"; }
no(){ echo "FAIL $1"; fails=1; }
rec(){ bash "$REC" "$@"; }
janitor(){ bash "$J" "$@"; }

# --- stub seams -------------------------------------------------------------------------------------
LIVE_FILE="$TMP/live.txt"; : > "$LIVE_FILE"
KILL_LOG="$TMP/kill.log"; : > "$KILL_LOG"
: > "$TMP/killfail"       # handles in here: kill is NOT accepted (exit 1)
: > "$TMP/killnoeffect"   # handles in here: kill accepted (exit 0) but session stays live

cat > "$TMP/list.sh" <<EOF
#!/bin/bash
cat "$LIVE_FILE" 2>/dev/null || true
EOF
cat > "$TMP/idle.sh" <<EOF
#!/bin/bash
cat "$TMP/idle_\$1" 2>/dev/null || true
EOF
cat > "$TMP/kill.sh" <<EOF
#!/bin/bash
echo "\$1" >> "$KILL_LOG"
grep -qxF "\$1" "$TMP/killfail" && exit 1
grep -qxF "\$1" "$TMP/killnoeffect" && exit 0
grep -vxF "\$1" "$LIVE_FILE" > "$LIVE_FILE.tmp" 2>/dev/null || : > "$LIVE_FILE.tmp"
mv "$LIVE_FILE.tmp" "$LIVE_FILE"
exit 0
EOF
chmod +x "$TMP"/*.sh
export SESSION_JANITOR_LIST_CMD="bash $TMP/list.sh"
export SESSION_JANITOR_IDLE_CMD="bash $TMP/idle.sh"
export SESSION_JANITOR_KILL_CMD="bash $TMP/kill.sh"

live_add(){ echo "$1" >> "$LIVE_FILE"; }        # live_add <handle>
idle_set(){ printf '%s' "$2" > "$TMP/idle_$1"; } # idle_set <handle> <idle|active|"">
killed(){ grep -qxF "$1" "$KILL_LOG"; }          # was a kill attempted on <handle>?

# === fixture: reap — closed + live + idle -> killed, verified gone ===
rec create s1 --session-handle "tmux:s1" >/dev/null; rec close s1 >/dev/null
live_add "tmux:s1"; idle_set "tmux:s1" idle
OUT=$(janitor 2>&1)
killed "tmux:s1" && ok reap-kill-attempted || no reap-kill-attempted
echo "$OUT" | grep -q "REAPED: run-id=s1" && ok reap-logged || no reap-logged
grep -qxF "tmux:s1" "$LIVE_FILE" && no reap-session-still-live || ok reap-session-gone

# === fixture: keep — closed but handle already gone (the common path) ===
rec create s2 --session-handle "tmux:s2" >/dev/null; rec close s2 >/dev/null
# tmux:s2 never added to LIVE_FILE
OUT=$(janitor 2>&1)
killed "tmux:s2" && no keep-gone-handle-not-killed || ok keep-gone-handle-untouched

# === fixture: keep — not-yet-closed (active) record with a LIVE handle, regardless of idleness ===
rec create s3 --session-handle "tmux:s3" >/dev/null
live_add "tmux:s3"; idle_set "tmux:s3" idle
OUT=$(janitor 2>&1)
killed "tmux:s3" && no active-record-killed || ok active-record-kept
echo "$OUT" | grep -q "run-id=s3" && no active-record-unexpectedly-logged || ok active-record-not-reported

# === fixture: keep — a deliberately STOPPED record whose handle is no longer live (never a "crash") ===
rec create s4 --session-handle "tmux:s4" >/dev/null; rec stop s4 >/dev/null
# tmux:s4 never live
OUT=$(janitor 2>&1)
echo "$OUT" | grep -q "run-id=s4" && no stopped-gone-reported || ok stopped-gone-not-reported

# === fixture: keep — closed + live but NOT idle yet (retry silently, no report) ===
rec create s5 --session-handle "tmux:s5" >/dev/null; rec close s5 >/dev/null
live_add "tmux:s5"; idle_set "tmux:s5" active
OUT=$(janitor 2>&1)
killed "tmux:s5" && no not-idle-killed || ok not-idle-kept
echo "$OUT" | grep -q "run-id=s5" && no not-idle-reported || ok not-idle-not-reported

# === fixture: report-retry — an INCONCLUSIVE idleness read is never a license to kill ===
rec create s6 --session-handle "tmux:s6" >/dev/null; rec close s6 >/dev/null
live_add "tmux:s6"; idle_set "tmux:s6" ""
OUT=$(janitor 2>&1)
killed "tmux:s6" && no inconclusive-killed || ok inconclusive-not-killed
echo "$OUT" | grep -q "report-retry (inconclusive idleness read): run-id=s6" && ok inconclusive-logged || no inconclusive-logged

# === fixture: report-only — a live session with NO matching record at all (unknown/orphan) ===
live_add "tmux:orphan"
OUT=$(janitor 2>&1)
killed "tmux:orphan" && no orphan-killed || ok orphan-not-killed
echo "$OUT" | grep -q "UNKNOWN live session, no matching record" && ok orphan-reported || no orphan-reported

# === fixture: report-only — a still-desired-active record whose handle is NOT live (deeper crash class) ===
rec create s7 --session-handle "tmux:s7" >/dev/null
# tmux:s7 never live -> the executor died before ever reaching close
OUT=$(janitor 2>&1)
echo "$OUT" | grep -q "the deeper crash class): run-id=s7" && ok deep-crash-reported || no deep-crash-reported
killed "tmux:s7" && no deep-crash-killed || ok deep-crash-not-killed

# === fixture: report-only — a MALFORMED run-supervision record file ===
printf 'not json{' > "$AAR_RUN_SUPERVISION_DIR/broken.json"
OUT=$(janitor 2>&1)
echo "$OUT" | grep -q "MALFORMED run-supervision record" && ok malformed-reported || no malformed-reported
rm -f "$AAR_RUN_SUPERVISION_DIR/broken.json"

# === fixture: report-only — two CLOSED records bound to the SAME handle (registry ambiguity) ===
rec create d1 --session-handle "tmux:dup" >/dev/null; rec close d1 >/dev/null
rec create d2 --session-handle "tmux:dup" >/dev/null; rec close d2 >/dev/null
live_add "tmux:dup"; idle_set "tmux:dup" idle
: > "$KILL_LOG"
OUT=$(janitor 2>&1)
killed "tmux:dup" && no dup-handle-killed || ok dup-handle-not-killed
echo "$OUT" | grep -q "AMBIGUOUS records bound to session tmux:dup" && ok dup-handle-reported || no dup-handle-reported

# === fixture: report-only — a CLOSED record sharing a handle with an ACTIVE record (registry ambiguity) ===
rec create e1 --session-handle "tmux:reuse" >/dev/null; rec close e1 >/dev/null
rec create e2 --session-handle "tmux:reuse" >/dev/null
live_add "tmux:reuse"; idle_set "tmux:reuse" idle
: > "$KILL_LOG"
OUT=$(janitor 2>&1)
killed "tmux:reuse" && no reused-handle-killed || ok reused-handle-not-killed
echo "$OUT" | grep -q "AMBIGUOUS records bound to session tmux:reuse" && ok reused-handle-reported || no reused-handle-reported

# === fixture: keep — a STOP-then-CLOSE (deliberate-quit finalize) record, live + idle -> NEVER reaped ===
# `list`'s state column collapses this to "closed" too; only is-closed correctly excludes it.
rec create sc --session-handle "tmux:sc" >/dev/null; rec stop sc >/dev/null; rec close sc >/dev/null
live_add "tmux:sc"; idle_set "tmux:sc" idle
: > "$KILL_LOG"
OUT=$(janitor 2>&1)
killed "tmux:sc" && no stop-then-close-killed || ok stop-then-close-not-killed
echo "$OUT" | grep -q "run-id=sc" && no stop-then-close-unexpectedly-reported || ok stop-then-close-not-reported

# === fixture: kill accepted but the session is STILL listed live afterward -> retried, not reaped ===
rec create s8 --session-handle "tmux:s8" >/dev/null; rec close s8 >/dev/null
live_add "tmux:s8"; idle_set "tmux:s8" idle
echo "tmux:s8" >> "$TMP/killnoeffect"
OUT=$(janitor 2>&1)
echo "$OUT" | grep -q "RETRY: run-id=s8 handle=tmux:s8 kill accepted but session still listed live" && ok kill-noeffect-retried || no kill-noeffect-retried

# === fixture: kill NOT accepted -> retried, not reaped ===
rec create s9 --session-handle "tmux:s9" >/dev/null; rec close s9 >/dev/null
live_add "tmux:s9"; idle_set "tmux:s9" idle
echo "tmux:s9" >> "$TMP/killfail"
OUT=$(janitor 2>&1)
echo "$OUT" | grep -q "RETRY: run-id=s9 handle=tmux:s9 kill not accepted" && ok kill-rejected-retried || no kill-rejected-retried
grep -qxF "tmux:s9" "$LIVE_FILE" && ok kill-rejected-still-live || no kill-rejected-still-live

# === --dry-run kills nothing, logs would-reap ===
rec create sd --session-handle "tmux:sd" >/dev/null; rec close sd >/dev/null
live_add "tmux:sd"; idle_set "tmux:sd" idle
: > "$KILL_LOG"
DOUT=$(janitor --dry-run 2>&1)
killed "tmux:sd" && no dryrun-killed || ok dryrun-kills-nothing
echo "$DOUT" | grep -q "DRY-RUN would reap: run-id=sd handle=tmux:sd" && ok dryrun-logged || no dryrun-logged
grep -qxF "tmux:sd" "$LIVE_FILE" && ok dryrun-session-untouched || no dryrun-session-untouched

# === a FAILING SESSION_JANITOR_LIST_CMD aborts the sweep loudly, never read as "no live sessions" ===
cat > "$TMP/list_fail.sh" <<'EOF'
#!/bin/bash
exit 1
EOF
chmod +x "$TMP/list_fail.sh"
if SESSION_JANITOR_LIST_CMD="bash $TMP/list_fail.sh" bash "$J" >/dev/null 2>&1; then no list-cmd-failure-accepted; else ok list-cmd-failure-rejected; fi
FOUT=$(SESSION_JANITOR_LIST_CMD="bash $TMP/list_fail.sh" bash "$J" 2>&1)
echo "$FOUT" | grep -q "SESSION_JANITOR_LIST_CMD failed" && ok list-cmd-failure-logged || no list-cmd-failure-logged

# === unset SESSION_JANITOR_LIST_CMD -> the whole sweep is a documented no-op ===
if env -u SESSION_JANITOR_LIST_CMD bash "$J" >/dev/null 2>&1; then ok unset-list-noop; else no unset-list-noop; fi
UOUT=$(env -u SESSION_JANITOR_LIST_CMD bash "$J" 2>&1)
echo "$UOUT" | grep -q "no-op on this instance" && ok unset-list-noop-logged || no unset-list-noop-logged

# === a PARTIAL config (list set, idle/kill missing) is NOT "no janitor" -- fail loudly ===
if env -u SESSION_JANITOR_IDLE_CMD bash "$J" >/dev/null 2>&1; then no partial-noidle-accepted; else ok partial-noidle-rejected; fi
if env -u SESSION_JANITOR_KILL_CMD bash "$J" >/dev/null 2>&1; then no partial-nokill-accepted; else ok partial-nokill-rejected; fi

# === arg validation: unknown/surplus arguments rejected, never silently sweeping live ===
if janitor --dryrun >/dev/null 2>&1; then no unknown-arg-accepted; else ok unknown-arg-rejected; fi
if janitor --dry-run extra >/dev/null 2>&1; then no surplus-arg-accepted; else ok surplus-arg-rejected; fi
if janitor extra >/dev/null 2>&1; then no bare-extra-arg-accepted; else ok bare-extra-arg-rejected; fi

[ "$fails" = 0 ] && { echo "session_janitor smoke PASS"; exit 0; } || { echo "session_janitor smoke FAIL"; exit 1; }
