#!/usr/bin/env bash
# Smoke for run_supervision_record.sh — the #54 child-1 run-supervision record. Behavior the
# deterministic JSON/syntax checks can't catch: the monotonic state machine, fail-closed
# is-desired-active, atomic writes, and the update-vs-stop/close race (Finding 1 from the design review).
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
S="$HERE/run_supervision_record.sh"
[ -f "$S" ] || { echo "FAIL: missing $S"; exit 1; }

TMP=$(mktemp -d) || { echo "FAIL: mktemp"; exit 1; }
trap 'rm -rf "$TMP"' EXIT
export AAR_RUN_SUPERVISION_DIR="$TMP"

fails=0
ok(){ echo "ok   $1"; }
no(){ echo "FAIL $1"; fails=1; }

run(){ bash "$S" "$@"; }                       # propagate exit code
active(){ run is-desired-active "$1"; }         # exit 0 = relaunch, 1 = no

# --- create -> desired-active ---
run create r1 --handoff /art/r1/TEMP.md >/dev/null
if active r1; then ok create-desired-active; else no create-desired-active; fi
[ "$(run show r1 | python3 -c 'import json,sys;print(json.load(sys.stdin)["handoff_path"])')" = /art/r1/TEMP.md ] \
  && ok create-handoff || no create-handoff

# --- missing record is fail-closed (exit 1) ---
if active nonesuch; then no missing-failclosed; else ok missing-failclosed; fi

# --- update: handoff refresh + additive, de-duped pod ids ---
run update r1 --lease-pod podA --lease-pod podB --handoff /art/r1/TEMP2.md >/dev/null
run update r1 --lease-pod podA >/dev/null   # dup
pods=$(run show r1 | python3 -c 'import json,sys;print(",".join(json.load(sys.stdin)["lease_pod_ids"]))')
[ "$pods" = "podA,podB" ] && ok update-pods-dedup || no "update-pods-dedup ($pods)"
[ "$(run show r1 | python3 -c 'import json,sys;print(json.load(sys.stdin)["handoff_path"])')" = /art/r1/TEMP2.md ] \
  && ok update-handoff || no update-handoff
if active r1; then ok update-stays-active; else no update-stays-active; fi

# --- stop is terminal: not desired-active, and update is refused ---
run stop r1 >/dev/null
if active r1; then no stop-deactivates; else ok stop-deactivates; fi
if run update r1 --handoff /evil >/dev/null 2>&1; then no stop-blocks-update; else ok stop-blocks-update; fi
# the refused update did NOT mutate the record (handoff unchanged)
[ "$(run show r1 | python3 -c 'import json,sys;print(json.load(sys.stdin)["handoff_path"])')" = /art/r1/TEMP2.md ] \
  && ok stop-update-noop || no stop-update-noop

# --- close is terminal too ---
run create r2 >/dev/null
run close r2 >/dev/null
if active r2; then no close-deactivates; else ok close-deactivates; fi
if run update r2 --handoff /evil >/dev/null 2>&1; then no close-blocks-update; else ok close-blocks-update; fi

# --- invalid run-id rejected (path-traversal safe) ---
if run create '../evil' >/dev/null 2>&1; then no reject-traversal; else ok reject-traversal; fi

# --- create over an existing record is refused (no resetting terminal/active state) ---
if run create r1 >/dev/null 2>&1; then no create-over-stopped-refused; else ok create-over-stopped-refused; fi
[ "$(run show r1 | python3 -c 'import json,sys;print(json.load(sys.stdin)["stopped"])')" = True ] \
  && ok create-over-stopped-keeps-terminal || no create-over-stopped-keeps-terminal
run create r3 >/dev/null
if run create r3 >/dev/null 2>&1; then no create-over-active-refused; else ok create-over-active-refused; fi

# --- malformed existing JSON fails CLOSED on update/stop/close, and is-desired-active says NO ---
printf 'not json{' > "$TMP/broken.json"
if run update broken --handoff /x >/dev/null 2>&1; then no corrupt-update-failclosed; else ok corrupt-update-failclosed; fi
if run stop broken >/dev/null 2>&1; then no corrupt-stop-failclosed; else ok corrupt-stop-failclosed; fi
if active broken; then no corrupt-not-active; else ok corrupt-not-active; fi
# the corrupt file was NOT overwritten by the refused update
grep -q 'not json' "$TMP/broken.json" && ok corrupt-untouched || no corrupt-untouched

# --- empty option values are rejected (caller bug, not a silent no-op) ---
run create r4 >/dev/null
if run update r4 --handoff "" >/dev/null 2>&1; then no empty-handoff-rejected; else ok empty-handoff-rejected; fi
if run update r4 --lease-pod "" >/dev/null 2>&1; then no empty-pod-rejected; else ok empty-pod-rejected; fi

# --- surplus args on no-arg commands fail closed (must NOT silently mutate a terminal state) ---
run create r5 >/dev/null
if run stop r5 oops >/dev/null 2>&1; then no surplus-stop-rejected; else ok surplus-stop-rejected; fi
# the spurious-arg stop did NOT mark r5 stopped
if active r5; then ok surplus-stop-noop; else no surplus-stop-noop; fi
if run is-desired-active r5 extra >/dev/null 2>&1; then no surplus-isactive-rejected; else ok surplus-isactive-rejected; fi

# --- stop/close terminal transitions: stop idempotent; close-after-stop ok; re-stop-after-close refused ---
run stop r5 >/dev/null
run stop r5 >/dev/null && ok stop-idempotent || no stop-idempotent          # already stopped -> no-op success
run close r5 >/dev/null && ok close-after-stop || no close-after-stop        # stop -> close finalize allowed
if run stop r5 >/dev/null 2>&1; then no restop-after-close-refused; else ok restop-after-close-refused; fi
run create r6 >/dev/null; run close r6 >/dev/null
run close r6 >/dev/null && ok close-idempotent || no close-idempotent        # already closed -> no-op success

# --- RACE: many concurrent updates against a stop must never re-activate the run (Finding 1) ---
run create rc --handoff /art/rc/TEMP.md >/dev/null
for i in $(seq 1 40); do run update rc --lease-pod "p$i" >/dev/null 2>&1 & done
run stop rc >/dev/null 2>&1
wait
# after the dust settles the run MUST be stopped (terminal) — an update that landed after stop must
# not have cleared it. With the flock + in-lock terminal guard, stopped stays true.
if active rc; then no race-stop-wins; else ok race-stop-wins; fi
[ "$(run show rc | python3 -c 'import json,sys;print(json.load(sys.stdin)["stopped"])')" = True ] \
  && ok race-stopped-true || no race-stopped-true
# the record is still valid JSON (atomic writes never left it half-written)
run show rc | python3 -c 'import json,sys;json.load(sys.stdin)' && ok race-valid-json || no race-valid-json

[ "$fails" = 0 ] && { echo "run_supervision_record smoke PASS"; exit 0; } || { echo "run_supervision_record smoke FAIL"; exit 1; }
