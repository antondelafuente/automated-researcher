#!/usr/bin/env bash
# Smoke for pod_lease.sh — the #54 child-2 pod lease. Behavior the deterministic JSON/syntax checks
# can't catch: the 3-phase create, expiry-driven is-reapable, the refresh-extends-expiry path, atomic
# writes under concurrency, fail-closed on corrupt/terminal records, and the exact-match find-nonce
# (pending-intent match + ambiguous/unknown -> report-only).
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
S="$HERE/pod_lease.sh"
[ -f "$S" ] || { echo "FAIL: missing $S"; exit 1; }

TMP=$(mktemp -d) || { echo "FAIL: mktemp"; exit 1; }
trap 'rm -rf "$TMP"' EXIT
export GPU_JOB_LEASE_DIR="$TMP"

fails=0
ok(){ echo "ok   $1"; }
no(){ echo "FAIL $1"; fails=1; }
run(){ bash "$S" "$@"; }
field(){ run show "$1" | python3 -c "import json,sys;print(json.load(sys.stdin).get('$2'))"; }

# --- 3-phase create: intent -> provisional -> enriched ---
N=$(run intent RUNPOD_API_KEY --expiry-min 15)
case "$N" in gpujob-????????????????????????????????) ok intent-nonce-format;; *) no "intent-nonce-format ($N)";; esac
[ "$(field "$N" state)" = intent ] && ok intent-state || no intent-state
[ "$(field "$N" key_ref)" = RUNPOD_API_KEY ] && ok intent-keyref || no intent-keyref
[ "$(field "$N" refresh_contract)" = 2 ] && ok intent-contract2 || no intent-contract2
# a fresh intent with a 15-min expiry is NOT reapable
if run is-reapable "$N"; then no intent-not-reapable; else ok intent-not-reapable; fi

run provisional "$N" pod-123 >/dev/null
[ "$(field "$N" state)" = provisional ] && ok provisional-state || no provisional-state
[ "$(field "$N" pod_id)" = pod-123 ] && ok provisional-podid || no provisional-podid

run enrich "$N" --ssh 1.2.3.4:22 --expiry-min 720 --cost 3.5 >/dev/null
[ "$(field "$N" state)" = enriched ] && ok enrich-state || no enrich-state
[ "$(field "$N" ssh)" = 1.2.3.4:22 ] && ok enrich-ssh || no enrich-ssh

# --- expiry drives is-reapable: a past expiry IS reapable; refresh moves it back to future ---
EXP=$(run intent RUNPOD_API_KEY --expiry-min -1)        # already-past expiry
run provisional "$EXP" pod-exp >/dev/null
if run is-reapable "$EXP"; then ok past-expiry-reapable; else no past-expiry-reapable; fi
run refresh "$EXP" --expiry-min 60 >/dev/null
if run is-reapable "$EXP"; then no refresh-extends-expiry; else ok refresh-extends-expiry; fi

# --- intent is NOT reapable while in intent state with future expiry; provisional/enriched are the
#     only reapable states (closed/reaping are not) ---
run close "$N" >/dev/null
[ "$(field "$N" state)" = closed ] && ok close-state || no close-state
if run is-reapable "$N"; then no closed-not-reapable; else ok closed-not-reapable; fi

# --- terminal guards: provisional/enrich/refresh refused after close; close idempotent ---
if run provisional "$N" pod-x >/dev/null 2>&1; then no closed-blocks-provisional; else ok closed-blocks-provisional; fi
if run refresh "$N" --expiry-min 5 >/dev/null 2>&1; then no closed-blocks-refresh; else ok closed-blocks-refresh; fi
run close "$N" >/dev/null && ok close-idempotent || no close-idempotent

# --- reaping is terminal-ish: refresh refused after reaping (the locked-reap claim) ---
R=$(run intent RUNPOD_API_KEY --expiry-min -1); run provisional "$R" pod-r >/dev/null
run reaping "$R" >/dev/null
[ "$(field "$R" state)" = reaping ] && ok reaping-state || no reaping-state
if run refresh "$R" --expiry-min 60 >/dev/null 2>&1; then no reaping-blocks-refresh; else ok reaping-blocks-refresh; fi

# --- missing / corrupt records fail closed ---
if run is-reapable nonesuch; then no missing-not-reapable; else ok missing-not-reapable; fi
printf 'not json{' > "$TMP/gpujob-broken.json"
if run refresh gpujob-broken --expiry-min 5 >/dev/null 2>&1; then no corrupt-refresh-failclosed; else ok corrupt-refresh-failclosed; fi
if run is-reapable gpujob-broken; then no corrupt-not-reapable; else ok corrupt-not-reapable; fi
grep -q 'not json' "$TMP/gpujob-broken.json" && ok corrupt-untouched || no corrupt-untouched

# --- find-nonce: exact whole-string match only; unknown / ambiguous -> empty (report-only) ---
P=$(run intent RUNPOD_API_KEY)            # pending intent (no pod bound)
[ "$(run find-nonce "$P")" = "$P" ] && ok findnonce-exact || no findnonce-exact
[ -z "$(run find-nonce "my-pod-name")" ] && ok findnonce-unknown-empty || no findnonce-unknown-empty
[ -z "$(run find-nonce "${P}x")" ] && ok findnonce-no-substring || no findnonce-no-substring
# ambiguous: two leases with the same nonce field -> empty
cp "$TMP/$P.json" "$TMP/gpujob-dupe.json"   # second file carries the SAME nonce value
[ -z "$(run find-nonce "$P")" ] && ok findnonce-ambiguous-empty || no findnonce-ambiguous-empty
rm -f "$TMP/gpujob-dupe.json"

# --- validation: bad id rejected, empty option rejected, surplus args rejected ---
if run provisional '../evil' pod >/dev/null 2>&1; then no reject-traversal; else ok reject-traversal; fi
G=$(run intent RUNPOD_API_KEY)
if run refresh "$G" --expiry-min "" >/dev/null 2>&1; then no empty-expiry-rejected; else ok empty-expiry-rejected; fi
if run close "$G" oops >/dev/null 2>&1; then no surplus-close-rejected; else ok surplus-close-rejected; fi
# the surplus-arg close did NOT close G
[ "$(field "$G" state)" = intent ] && ok surplus-close-noop || no surplus-close-noop

# --- RACE: many concurrent refreshes against a reaping mark — the lease must end terminal (reaping),
#     never re-activated, and stay valid JSON (atomic writes) ---
RC=$(run intent RUNPOD_API_KEY --expiry-min -1); run provisional "$RC" pod-rc >/dev/null
for i in $(seq 1 30); do run refresh "$RC" --expiry-min 60 >/dev/null 2>&1 & done
run reaping "$RC" >/dev/null 2>&1
wait
# after the dust settles: either reaping won (terminal) or a refresh won (not reapable) — but the
# record is ALWAYS valid JSON and is NEVER both reaping AND reapable.
run show "$RC" | python3 -c 'import json,sys;json.load(sys.stdin)' >/dev/null 2>&1 && ok race-valid-json || no race-valid-json
st=$(field "$RC" state)
if [ "$st" = reaping ]; then
  if run is-reapable "$RC"; then no race-reaping-not-reapable; else ok race-reaping-not-reapable; fi
else
  ok "race-refresh-won ($st)"
fi

[ "$fails" = 0 ] && { echo "pod_lease smoke PASS"; exit 0; } || { echo "pod_lease smoke FAIL"; exit 1; }
