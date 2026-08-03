#!/usr/bin/env bash
# Smoke for reap_session.sh — the session self-reap terminal close action (#282). Behavior the deterministic
# JSON/syntax checks can't catch: the clean-close guard (only closed-AND-not-stopped reaps — a parked/blocked
# or deliberately-stopped run is never reaped), the no-handle and unset-seam NO-OPs, and the SELF-ONLY seam
# invocation passing the opaque handle as its SOLE argument. No real session is killed — the seam is a stub
# that records the argument it was handed.
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
R="$HERE/reap_session.sh"
REC="$HERE/run_supervision_record.sh"
[ -f "$R" ]   || { echo "FAIL: missing $R"; exit 1; }
[ -f "$REC" ] || { echo "FAIL: missing $REC"; exit 1; }

TMP=$(mktemp -d) || { echo "FAIL: mktemp"; exit 1; }
trap 'rm -rf "$TMP"' EXIT
export AAR_RUN_SUPERVISION_DIR="$TMP"
# The no-handle no-op case below asserts that NOTHING is bound, so this smoke must not inherit an
# instance's #673 derive-at-start seam from the ambient env (run_supervision_record.sh's own smoke covers it).
unset EXPERIMENT_SESSION_HANDLE_CMD

fails=0
ok(){ echo "ok   $1"; }
no(){ echo "FAIL $1"; fails=1; }
rec(){ bash "$REC" "$@"; }
reap(){ bash "$R" "$@"; }                 # propagate exit code
seam_calls(){ wc -l < "$REAP_LOG" | tr -d ' '; }

# stub seam: records the handle it was handed, exits 0 (a real instance verifies self==handle then kills).
STUB="$TMP/stub_reap.sh"
cat > "$STUB" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$1" >> "$REAP_LOG"
EOF
chmod +x "$STUB"
export REAP_LOG="$TMP/reaped"
: > "$REAP_LOG"

# --- clean close + handle + seam set -> invokes seam with the EXACT opaque handle, exit 0 ---
rec create c1 --session-handle "tmux:run-c1" >/dev/null; rec close c1 >/dev/null
: > "$REAP_LOG"
if EXPERIMENT_SESSION_REAP_CMD="$STUB" reap c1 >/dev/null; then ok reap-clean-invokes-exit0; else no reap-clean-invokes-exit0; fi
[ "$(cat "$REAP_LOG")" = "tmux:run-c1" ] && ok reap-passes-exact-handle || no "reap-passes-exact-handle ($(cat "$REAP_LOG"))"

# --- seam as a COMMAND STRING (interpreter + path, the *_CMD convention) still invokes with the exact handle ---
rec create c1b --session-handle "tmux:run-c1b" >/dev/null; rec close c1b >/dev/null
: > "$REAP_LOG"
if EXPERIMENT_SESSION_REAP_CMD="bash $STUB" reap c1b >/dev/null; then ok reap-cmdstring-invokes; else no reap-cmdstring-invokes; fi
[ "$(cat "$REAP_LOG")" = "tmux:run-c1b" ] && ok reap-cmdstring-exact-handle || no "reap-cmdstring-exact-handle ($(cat "$REAP_LOG"))"

# --- unset seam -> documented no-op (exit 0), seam not called ---
rec create c2 --session-handle "tmux:run-c2" >/dev/null; rec close c2 >/dev/null
: > "$REAP_LOG"
if env -u EXPERIMENT_SESSION_REAP_CMD bash "$R" c2 >/dev/null; then ok reap-unset-seam-noop; else no reap-unset-seam-noop; fi
[ "$(seam_calls)" = 0 ] && ok reap-unset-no-call || no reap-unset-no-call

# --- clean close but NO handle recorded -> no-op exit 0, seam not called ---
rec create c3 >/dev/null; rec close c3 >/dev/null
: > "$REAP_LOG"
if EXPERIMENT_SESSION_REAP_CMD="$STUB" reap c3 >/dev/null; then ok reap-nohandle-noop; else no reap-nohandle-noop; fi
[ "$(seam_calls)" = 0 ] && ok reap-nohandle-no-call || no reap-nohandle-no-call

# --- GUARD: never reap a run that isn't a CLEAN close, and never call the seam ---
rec create g_active --session-handle "tmux:a" >/dev/null                                     # active
: > "$REAP_LOG"
if EXPERIMENT_SESSION_REAP_CMD="$STUB" reap g_active >/dev/null 2>&1; then no reap-active-refused; else ok reap-active-refused; fi
[ "$(seam_calls)" = 0 ] && ok reap-active-no-call || no reap-active-no-call
rec create g_stop --session-handle "tmux:s" >/dev/null; rec stop g_stop >/dev/null           # stopped-only
: > "$REAP_LOG"
if EXPERIMENT_SESSION_REAP_CMD="$STUB" reap g_stop >/dev/null 2>&1; then no reap-stopped-refused; else ok reap-stopped-refused; fi
rec create g_sc --session-handle "tmux:sc" >/dev/null; rec stop g_sc >/dev/null; rec close g_sc >/dev/null  # stop->close (finding 2)
: > "$REAP_LOG"
if EXPERIMENT_SESSION_REAP_CMD="$STUB" reap g_sc >/dev/null 2>&1; then no reap-stopclose-refused; else ok reap-stopclose-refused; fi
[ "$(seam_calls)" = 0 ] && ok reap-stopclose-no-call || no reap-stopclose-no-call
: > "$REAP_LOG"                                                                               # missing record
if EXPERIMENT_SESSION_REAP_CMD="$STUB" reap nonesuch >/dev/null 2>&1; then no reap-missing-refused; else ok reap-missing-refused; fi
printf 'not json{' > "$TMP/g_broken.json"                                                    # corrupt record
if EXPERIMENT_SESSION_REAP_CMD="$STUB" reap g_broken >/dev/null 2>&1; then no reap-corrupt-refused; else ok reap-corrupt-refused; fi
[ "$(seam_calls)" = 0 ] && ok reap-guard-never-called || no reap-guard-never-called

# --- arg validation: exactly one run-id ---
if reap >/dev/null 2>&1; then no reap-noarg-rejected; else ok reap-noarg-rejected; fi
if reap c1 extra >/dev/null 2>&1; then no reap-surplus-rejected; else ok reap-surplus-rejected; fi

[ "$fails" = 0 ] && { echo "reap_session smoke PASS"; exit 0; } || { echo "reap_session smoke FAIL"; exit 1; }
