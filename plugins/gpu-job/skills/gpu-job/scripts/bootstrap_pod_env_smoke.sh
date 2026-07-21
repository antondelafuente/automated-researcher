#!/usr/bin/env bash
# Smoke test for bootstrap_pod.sh's PASS_ENV persistence (#341): a fresh ssh session doesn't
# inherit the container's injected env, so job launch scripts on the pod couldn't see
# TINKER_API_KEY/HF_TOKEN/etc — only RCLONE_CONF_B64 had a special-cased fix. _persist_passed_env
# generalizes it: read PID 1's environ (deploy_pod.py's PASSED_ENV_NAMES tells it which keys to
# look for) and persist each to /workspace/.env (always) and /etc/environment (root pods only).
# Fully OFFLINE: fakes a NUL-separated "/proc/1/environ" file and scratch workspace/etc paths —
# never touches the real filesystem locations.
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
# Sourcing (not executing) reaches the guard in bootstrap_pod.sh and returns before the real
# bootstrap (rclone install, real /etc/environment writes) runs — see that file's header.
source "$HERE/bootstrap_pod.sh" || { echo "FAIL: cannot source bootstrap_pod.sh"; exit 1; }

TMP=$(mktemp -d) || { echo "FAIL: mktemp"; exit 1; }
trap 'rm -rf "$TMP"' EXIT

fails=0
ok(){ echo "ok   $1"; }
no(){ echo "FAIL $1"; fails=1; }

fake_environ(){ # fake_environ <file> <KEY=VALUE>... — write a NUL-separated environ blob
  local f=$1; shift
  printf '%s\0' "$@" > "$f"
}

# --- 1. persists exactly the PASSED_ENV_NAMES-listed vars, to BOTH files when root ------------------
ENV1="$TMP/environ1"
fake_environ "$ENV1" "PASSED_ENV_NAMES=TINKER_API_KEY,HF_TOKEN" "TINKER_API_KEY=tk-abc" "HF_TOKEN=hf-xyz" "UNRELATED_VAR=nope"
WS1="$TMP/ws1/.env"; ETC1="$TMP/etc1/environment"
_persist_passed_env "$ENV1" "$WS1" "$ETC1" 1
if grep -qx 'TINKER_API_KEY=tk-abc' "$WS1" && grep -qx 'HF_TOKEN=hf-xyz' "$WS1"; then ok persists-listed-vars-to-workspace-env; else no "persists-listed-vars-to-workspace-env ($(cat "$WS1" 2>/dev/null))"; fi
if grep -qx 'TINKER_API_KEY=tk-abc' "$ETC1" && grep -qx 'HF_TOKEN=hf-xyz' "$ETC1"; then ok root-also-persists-to-etc-environment; else no "root-also-persists-to-etc-environment ($(cat "$ETC1" 2>/dev/null))"; fi
if grep -q 'UNRELATED_VAR' "$WS1" 2>/dev/null; then no "unrelated-var-not-in-passed-names-must-not-leak"; else ok unrelated-var-not-in-passed-names-must-not-leak; fi

# --- 2. non-root pod: workspace/.env written, /etc/environment left untouched -----------------------
ENV2="$TMP/environ2"
fake_environ "$ENV2" "PASSED_ENV_NAMES=HF_TOKEN" "HF_TOKEN=hf-xyz"
WS2="$TMP/ws2/.env"; ETC2="$TMP/etc2/environment"
_persist_passed_env "$ENV2" "$WS2" "$ETC2" 0
if grep -qx 'HF_TOKEN=hf-xyz' "$WS2"; then ok non-root-still-writes-workspace-env; else no non-root-still-writes-workspace-env; fi
if [ -e "$ETC2" ]; then no "non-root-must-not-write-etc-environment ($(cat "$ETC2"))"; else ok non-root-must-not-write-etc-environment; fi

# --- 3. no PASSED_ENV_NAMES at all (no PASS_ENV used) -> no-op, no files created ---------------------
ENV3="$TMP/environ3"
fake_environ "$ENV3" "SOME_OTHER_VAR=x"
WS3="$TMP/ws3/.env"; ETC3="$TMP/etc3/environment"
_persist_passed_env "$ENV3" "$WS3" "$ETC3" 1
if [ -e "$WS3" ]; then no "no-passed-env-names-must-be-a-no-op ($(cat "$WS3"))"; else ok no-passed-env-names-must-be-a-no-op; fi

# --- 4. a listed name with no/empty value in the environ is skipped, not written as VAR= -------------
ENV4="$TMP/environ4"
fake_environ "$ENV4" "PASSED_ENV_NAMES=MISSING_VAR,HF_TOKEN" "HF_TOKEN=hf-xyz"
WS4="$TMP/ws4/.env"; ETC4="$TMP/etc4/environment"
_persist_passed_env "$ENV4" "$WS4" "$ETC4" 1
if grep -q '^MISSING_VAR=' "$WS4" 2>/dev/null; then no "missing-value-name-not-written"; else ok missing-value-name-not-written; fi
if grep -qx 'HF_TOKEN=hf-xyz' "$WS4"; then ok present-name-still-written-alongside-missing-one; else no present-name-still-written-alongside-missing-one; fi

# --- 5. idempotent: a second bootstrap run doesn't duplicate an already-persisted line ---------------
ENV5="$TMP/environ5"
fake_environ "$ENV5" "PASSED_ENV_NAMES=HF_TOKEN" "HF_TOKEN=hf-xyz"
WS5="$TMP/ws5/.env"; ETC5="$TMP/etc5/environment"
_persist_passed_env "$ENV5" "$WS5" "$ETC5" 1
_persist_passed_env "$ENV5" "$WS5" "$ETC5" 1
if [ "$(grep -c '^HF_TOKEN=' "$WS5")" = 1 ] && [ "$(grep -c '^HF_TOKEN=' "$ETC5")" = 1 ]; then ok idempotent-rerun; else no "idempotent-rerun (ws=$(cat "$WS5") etc=$(cat "$ETC5"))"; fi

[ "$fails" = 0 ] && { echo "PASS bootstrap_pod_env_smoke"; exit 0; } || { echo "FAIL bootstrap_pod_env_smoke"; exit 1; }
