#!/usr/bin/env bash
# Smoke for run_supervision_record.sh — the #54 child-1 run-supervision record + child-3 relaunch
# additions. Behavior the deterministic JSON/syntax checks can't catch: the monotonic state machine,
# fail-closed is-desired-active, atomic writes, the update-vs-stop/close race (Finding 1 from the
# child-1 design review), and the child-3 needs-relaunch request + opaque session-handle (request/clear,
# fail-closed is-relaunch-requested, request cleared by stop/close); plus the #188 finding-2 rule that
# request-relaunch requires a bound handoff_path (fail-closed without one; --handoff binds it atomically),
# and the agent-facing lifecycle aliases (`start`/`checkpoint`/`status`) preserving the same fail-closed
# behavior. Also covers the #223 Codex-native supervision additions: the validated supervision-mode
# enum, the opaque executor-family/question-route/terminal-route fields, and the single-in-flight
# question/answer inbox (ask-question/answer-question/consume-question/has-question/has-answer) —
# refusing a second ask while one is unanswered, refusing to answer nothing, the --question-id mismatch
# guard, refusing to consume before an answer exists, idempotent consume, and the same terminal/missing/
# corrupt fail-closed guards as the rest of the record. Also covers the #628 supervision-bootstrap
# receipt: the look-again-by getter, and verify-bootstrap's successful-bootstrap / missing-record /
# wrong-field / bootstrap-timeout paths (small --timeout-sec/--poll-interval-sec values keep this smoke fast).
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

# --- is-closed: the session-reap guard — exit 0 ONLY on a CLEAN close (closed AND NOT stopped) ---
closed(){ run is-closed "$1"; }                                    # exit 0 = clean close (reapable), 1 = not
run create ic_active --handoff /art/ic/TEMP.md >/dev/null
if closed ic_active; then no isclosed-active-no; else ok isclosed-active-no; fi         # active -> NOT reapable
run create ic_clean >/dev/null; run close ic_clean >/dev/null
if closed ic_clean; then ok isclosed-clean-yes; else no isclosed-clean-yes; fi          # clean close -> reapable
run create ic_stop >/dev/null; run stop ic_stop >/dev/null
if closed ic_stop; then no isclosed-stopped-no; else ok isclosed-stopped-no; fi         # stopped-only -> NOT reapable
# design-review finding 2: a stop -> close record classifies as "closed" (closed-before-stopped) but is a
# deliberate-quit finalize, NOT a clean close -> is-closed MUST fail closed so its session is never reaped.
run create ic_sc >/dev/null; run stop ic_sc >/dev/null; run close ic_sc >/dev/null
if closed ic_sc; then no isclosed-stopclose-no; else ok isclosed-stopclose-no; fi
# missing + corrupt fail closed; surplus arg rejected
if closed nonesuch; then no isclosed-missing-no; else ok isclosed-missing-no; fi
printf 'not json{' > "$TMP/ic_broken.json"
if closed ic_broken; then no isclosed-corrupt-no; else ok isclosed-corrupt-no; fi
if run is-closed ic_clean extra >/dev/null 2>&1; then no isclosed-surplus-rejected; else ok isclosed-surplus-rejected; fi

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

# ===== #54 child 3: needs-relaunch request + opaque session-handle =====
requested(){ run is-relaunch-requested "$1"; }   # exit 0 = relaunch asked, 1 = no
jget(){ run show "$1" | python3 -c "import json,sys;v=json.load(sys.stdin)[\"$2\"];print('' if v is None else v)"; }

# --- session-handle: opaque, set on create, readable, overridable on update ---
run create s1 --handoff /art/s1/TEMP.md --session-handle "tmux:claude-3" >/dev/null
[ "$(run session-handle s1)" = "tmux:claude-3" ] && ok session-handle-create || no session-handle-create
run update s1 --session-handle "systemd:run-s1.service" >/dev/null
[ "$(run session-handle s1)" = "systemd:run-s1.service" ] && ok session-handle-update || no session-handle-update
# absent handle -> exit 1, no output
run create s2 >/dev/null
if run session-handle s2 >/dev/null 2>&1; then no session-handle-absent-failclosed; else ok session-handle-absent-failclosed; fi
# missing record -> exit 1
if run session-handle nonesuch >/dev/null 2>&1; then no session-handle-missing-failclosed; else ok session-handle-missing-failclosed; fi
# empty --session-handle value rejected (caller bug)
if run update s1 --session-handle "" >/dev/null 2>&1; then no empty-session-handle-rejected; else ok empty-session-handle-rejected; fi

# --- worktree-path: opaque, set on create, readable, overridable on update (automated-researcher#535
# review round 2 — the run-id<->worktree binding reap_worktree.sh checks) ---
run create w1 --handoff /art/w1/TEMP.md --worktree "/ws/run/w1" >/dev/null
[ "$(run worktree-path w1)" = "/ws/run/w1" ] && ok worktree-path-create || no worktree-path-create
run update w1 --worktree "/ws/run/w1-moved" >/dev/null
[ "$(run worktree-path w1)" = "/ws/run/w1-moved" ] && ok worktree-path-update || no worktree-path-update
# absent path -> exit 1, no output
run create w2 >/dev/null
if run worktree-path w2 >/dev/null 2>&1; then no worktree-path-absent-failclosed; else ok worktree-path-absent-failclosed; fi
# missing record -> exit 1
if run worktree-path nonesuch >/dev/null 2>&1; then no worktree-path-missing-failclosed; else ok worktree-path-missing-failclosed; fi
# empty --worktree value rejected (caller bug)
if run update w1 --worktree "" >/dev/null 2>&1; then no empty-worktree-rejected; else ok empty-worktree-rejected; fi
# surplus arg rejected
if run worktree-path w1 oops >/dev/null 2>&1; then no surplus-worktreepath-rejected; else ok surplus-worktreepath-rejected; fi

# --- request-relaunch: sets the flag + reason; is-relaunch-requested reads it; supervisor clears it ---
run create q1 --handoff /art/q1/TEMP.md >/dev/null
if requested q1; then no fresh-no-request; else ok fresh-no-request; fi          # default: no request
run request-relaunch q1 --reason "policy-block" >/dev/null
if requested q1; then ok request-sets-flag; else no request-sets-flag; fi
[ "$(jget q1 relaunch_reason)" = "policy-block" ] && ok request-records-reason || no request-records-reason
# a requested run is still desired-active (request != stop)
if active q1; then ok request-stays-active; else no request-stays-active; fi
# supervisor act-then-clear
run clear-relaunch q1 >/dev/null
if requested q1; then no clear-resets-flag; else ok clear-resets-flag; fi
[ -z "$(jget q1 relaunch_reason)" ] && ok clear-drops-reason || no clear-drops-reason
# clear is idempotent
run clear-relaunch q1 >/dev/null && ok clear-idempotent || no clear-idempotent

# --- is-relaunch-requested is fail-closed on missing/corrupt/terminal ---
if requested nonesuch; then no request-missing-failclosed; else ok request-missing-failclosed; fi
if requested broken; then no request-corrupt-failclosed; else ok request-corrupt-failclosed; fi   # broken.json from earlier

# --- request-relaunch is refused on a terminal record (never resurrect a deliberately-ended run) ---
run create q2 >/dev/null; run stop q2 >/dev/null
if run request-relaunch q2 >/dev/null 2>&1; then no request-on-stopped-refused; else ok request-on-stopped-refused; fi
run create q3 >/dev/null; run close q3 >/dev/null
if run request-relaunch q3 >/dev/null 2>&1; then no request-on-closed-refused; else ok request-on-closed-refused; fi
# request-relaunch on a missing record is refused
if run request-relaunch nonesuch >/dev/null 2>&1; then no request-missing-record-refused; else ok request-missing-record-refused; fi

# --- a pending request is CLEARED by stop/close, and is-relaunch-requested then says NO ---
run create q4 --handoff /art/q4/TEMP.md >/dev/null
run request-relaunch q4 --reason "blip" >/dev/null
if requested q4; then ok q4-requested-before-stop; else no q4-requested-before-stop; fi
run stop q4 >/dev/null
if requested q4; then no stop-clears-request; else ok stop-clears-request; fi
[ "$(jget q4 relaunch_requested)" = False ] && ok stop-clears-request-field || no stop-clears-request-field

run create q5 --handoff /art/q5/TEMP.md >/dev/null
run request-relaunch q5 >/dev/null
run close q5 >/dev/null
if requested q5; then no close-clears-request; else ok close-clears-request; fi

# --- #188 finding 2: request-relaunch REQUIRES a bound handoff_path (the successor fallback needs it) ---
# (a) a record with NO handoff bound -> request-relaunch fails closed, and the request is NOT recorded
run create h1 >/dev/null
if run request-relaunch h1 >/dev/null 2>&1; then no request-no-handoff-failclosed; else ok request-no-handoff-failclosed; fi
[ "$(jget h1 relaunch_requested)" = False ] && ok request-no-handoff-no-write || no request-no-handoff-no-write
# (b) request-relaunch --handoff binds the handoff atomically AND sets the request in one call
run request-relaunch h1 --handoff /art/h1/TEMP.md --reason "policy-block" >/dev/null
if requested h1; then ok request-handoff-binds-and-sets; else no request-handoff-binds-and-sets; fi
[ "$(jget h1 handoff_path)" = "/art/h1/TEMP.md" ] && ok request-handoff-recorded || no request-handoff-recorded
run clear-relaunch h1 >/dev/null
# (c) a record that ALREADY has a handoff -> plain request-relaunch (no --handoff) succeeds
run create h2 --handoff /art/h2/TEMP.md >/dev/null
if run request-relaunch h2 >/dev/null 2>&1; then ok request-existing-handoff-ok; else no request-existing-handoff-ok; fi
if requested h2; then ok request-existing-handoff-sets; else no request-existing-handoff-sets; fi
# (d) empty --handoff value rejected (caller bug)
run create h3 --handoff /art/h3/TEMP.md >/dev/null
if run request-relaunch h3 --handoff "" >/dev/null 2>&1; then no request-empty-handoff-rejected; else ok request-empty-handoff-rejected; fi

# --- surplus-arg / unknown-arg fail-closed on the new commands ---
run create q6 >/dev/null
if run clear-relaunch q6 oops >/dev/null 2>&1; then no surplus-clear-rejected; else ok surplus-clear-rejected; fi
if run is-relaunch-requested q6 oops >/dev/null 2>&1; then no surplus-isrequested-rejected; else ok surplus-isrequested-rejected; fi
if run session-handle q6 oops >/dev/null 2>&1; then no surplus-sessionhandle-rejected; else ok surplus-sessionhandle-rejected; fi
if run worktree-path q6 oops >/dev/null 2>&1; then no surplus-worktreepath-rejected2; else ok surplus-worktreepath-rejected2; fi
if run request-relaunch q6 --reason "" >/dev/null 2>&1; then no empty-reason-rejected; else ok empty-reason-rejected; fi
if run request-relaunch q6 --bogus x >/dev/null 2>&1; then no request-unknown-arg-rejected; else ok request-unknown-arg-rejected; fi

# --- ambient env must NOT leak into write_record (code-review MED): a subcommand only mutates fields it
#     was asked to. A stray SET_RELAUNCH/SESSION_HANDLE in the caller's env must be ignored by a plain
#     update/stop that didn't request them. (write_record reads explicit positional args, not env.) ---
run create e1 --handoff /art/e1/TEMP.md >/dev/null
SET_RELAUNCH=true SESSION_HANDLE="evil" WORKTREE_PATH="/evil/wt" RELAUNCH_REASON="injected" run update e1 --handoff /art/e1/TEMP2.md >/dev/null
if requested e1; then no ambient-no-relaunch-leak; else ok ambient-no-relaunch-leak; fi
if run session-handle e1 >/dev/null 2>&1; then no ambient-no-handle-leak; else ok ambient-no-handle-leak; fi
if run worktree-path e1 >/dev/null 2>&1; then no ambient-no-worktree-leak; else ok ambient-no-worktree-leak; fi
# the update DID apply its own requested change (handoff)
[ "$(jget e1 handoff_path)" = "/art/e1/TEMP2.md" ] && ok ambient-update-still-works || no ambient-update-still-works
# a plain stop with stray ambient SET_RELAUNCH must still leave no request set
run create e2 >/dev/null
SET_RELAUNCH=true run stop e2 >/dev/null
[ "$(jget e2 relaunch_requested)" = False ] && ok ambient-no-leak-on-stop || no ambient-no-leak-on-stop

# --- backward-compat: a child-1-era record (no new fields) reads as no-request, no-handle, still active ---
printf '{"run_id":"legacy","desired_active":true,"stopped":false,"closed":false,"handoff_path":"/art/legacy/TEMP.md","lease_pod_ids":[],"created_at":1}\n' > "$TMP/legacy.json"
if active legacy; then ok legacy-active || true; else no legacy-active; fi
if requested legacy; then no legacy-no-request; else ok legacy-no-request; fi
if run session-handle legacy >/dev/null 2>&1; then no legacy-no-handle; else ok legacy-no-handle; fi
if run worktree-path legacy >/dev/null 2>&1; then no legacy-no-worktree-path; else ok legacy-no-worktree-path; fi
# an update of the legacy record backfills the new fields without disturbing existing ones, stays valid JSON
run update legacy --session-handle "tmux:legacy" >/dev/null
[ "$(run session-handle legacy)" = "tmux:legacy" ] && ok legacy-update-backfills || no legacy-update-backfills
[ "$(jget legacy handoff_path)" = "/art/legacy/TEMP.md" ] && ok legacy-update-preserves || no legacy-update-preserves
printf '{"desired_active":true,"stopped":false,"closed":false,"handoff_path":"/art/noid/TEMP.md","lease_pod_ids":[],"created_at":1}\n' > "$TMP/noid.json"
printf '%s\n' "$(run status noid)" | grep -qx 'run_id=' && ok status-missing-run-id-empty || no status-missing-run-id-empty

# ===== agent-facing lifecycle aliases: same state machine, smaller executor vocabulary =====
run start a1 --handoff /art/a1/TEMP.md --session-handle "tmux:a1" --worktree "/ws/run/a1" >/dev/null
if active a1; then ok alias-start-active; else no alias-start-active; fi
[ "$(run session-handle a1)" = "tmux:a1" ] && ok alias-start-session-handle || no alias-start-session-handle
[ "$(run worktree-path a1)" = "/ws/run/a1" ] && ok alias-start-worktree-path || no alias-start-worktree-path
run checkpoint a1 --handoff /art/a1/TEMP2.md --lease-pod podZ >/dev/null
[ "$(jget a1 handoff_path)" = "/art/a1/TEMP2.md" ] && ok alias-checkpoint-handoff || no alias-checkpoint-handoff
[ "$(run show a1 | python3 -c 'import json,sys;print(",".join(json.load(sys.stdin)["lease_pod_ids"]))')" = "podZ" ] \
  && ok alias-checkpoint-pod || no alias-checkpoint-pod
status=$(run status a1)
printf '%s\n' "$status" | grep -qx 'state=active' && ok status-state || no status-state
printf '%s\n' "$status" | grep -qx 'desired_active=true' && ok status-desired-active-bool || no status-desired-active-bool
printf '%s\n' "$status" | grep -qx 'handoff_path=/art/a1/TEMP2.md' && ok status-handoff || no status-handoff
printf '%s\n' "$status" | grep -qx 'session_handle=tmux:a1' && ok status-session-handle || no status-session-handle
printf '%s\n' "$status" | grep -qx 'worktree_path=/ws/run/a1' && ok status-worktree-path || no status-worktree-path
printf '%s\n' "$status" | grep -qx 'lease_pod_ids=podZ' && ok status-pods || no status-pods
printf '%s\n' "$status" | grep -qx 'relaunch_requested=false' && ok status-relaunch-bool || no status-relaunch-bool

# Alias commands must preserve fail-closed and argument validation.
if run start a1 >/dev/null 2>&1; then no alias-start-over-active-refused; else ok alias-start-over-active-refused; fi
run stop a1 >/dev/null
if run checkpoint a1 --handoff /evil >/dev/null 2>&1; then no alias-checkpoint-terminal-refused; else ok alias-checkpoint-terminal-refused; fi
if run status nonesuch >/dev/null 2>&1; then no status-missing-failclosed; else ok status-missing-failclosed; fi
if run status broken >/dev/null 2>&1; then no status-corrupt-failclosed; else ok status-corrupt-failclosed; fi
if run status a1 extra >/dev/null 2>&1; then no status-surplus-rejected; else ok status-surplus-rejected; fi

# ===== list: the session-janitor's enumeration input =====
# Fresh registry root so `list`'s output is exactly the fixtures created here (a-la-carte, not the
# whole smoke's accumulated state).
LISTROOT=$(mktemp -d)
AAR_RUN_SUPERVISION_DIR="$LISTROOT" run create lst_active >/dev/null
AAR_RUN_SUPERVISION_DIR="$LISTROOT" run create lst_closed >/dev/null
AAR_RUN_SUPERVISION_DIR="$LISTROOT" run close lst_closed >/dev/null
printf 'not json{' > "$LISTROOT/lst_broken.json"
LOUT=$(AAR_RUN_SUPERVISION_DIR="$LISTROOT" run list)
echo "$LOUT" | grep -qx 'lst_active active' && ok list-active || no list-active
echo "$LOUT" | grep -qx 'lst_closed closed' && ok list-closed || no list-closed
echo "$LOUT" | grep -qx 'lst_broken invalid' && ok list-invalid || no list-invalid
if AAR_RUN_SUPERVISION_DIR="$LISTROOT" run list extra >/dev/null 2>&1; then no list-surplus-rejected; else ok list-surplus-rejected; fi
[ -z "$(AAR_RUN_SUPERVISION_DIR="$TMP/no-such-dir" run list)" ] && ok list-missing-dir-empty || no list-missing-dir-empty
rm -rf "$LISTROOT"

# ===== #223: Codex-native supervision — executor_family / supervision_mode / question+terminal routes =====
smode(){ run supervision-mode "$1"; }
efam(){ run executor-family "$1"; }
qroute(){ run question-route "$1"; }
troute(){ run terminal-route "$1"; }

# --- create with the new fields; all readable, and validated ---
run create cx1 --handoff /art/cx1/TEMP.md --executor-family codex --supervision-mode controller-supervised \
  --question-route record --terminal-route record >/dev/null
[ "$(efam cx1)" = codex ] && ok codex-executor-family-create || no codex-executor-family-create
[ "$(smode cx1)" = controller-supervised ] && ok codex-supervision-mode-create || no codex-supervision-mode-create
[ "$(qroute cx1)" = record ] && ok codex-question-route-create || no codex-question-route-create
[ "$(troute cx1)" = record ] && ok codex-terminal-route-create || no codex-terminal-route-create

# --- update can change them; absent fields on a plain record are fail-closed (exit 1, no output) ---
run create cx2 >/dev/null

# --- question_route / terminal_state_route default to "record" on a flagless create, per
#     CODEX_SUPERVISION.md's documented default; an explicit flag still overrides it ---
[ "$(qroute cx2)" = record ] && ok codex-question-route-default || no codex-question-route-default
[ "$(troute cx2)" = record ] && ok codex-terminal-route-default || no codex-terminal-route-default
run update cx2 --question-route "chan:#runs" >/dev/null
[ "$(qroute cx2)" = "chan:#runs" ] && ok codex-question-route-override || no codex-question-route-override

if run supervision-mode cx2 >/dev/null 2>&1; then no supervision-mode-absent-failclosed; else ok supervision-mode-absent-failclosed; fi
if run executor-family cx2 >/dev/null 2>&1; then no executor-family-absent-failclosed; else ok executor-family-absent-failclosed; fi
run update cx2 --executor-family claude --supervision-mode autonomous-detached >/dev/null
[ "$(efam cx2)" = claude ] && ok executor-family-update || no executor-family-update
[ "$(smode cx2)" = autonomous-detached ] && ok supervision-mode-update || no supervision-mode-update

# --- supervision-mode is a validated enum: an unrecognized value is rejected, on create AND update ---
if run create cx3 --supervision-mode bogus >/dev/null 2>&1; then no supervision-mode-create-rejects-bogus; else ok supervision-mode-create-rejects-bogus; fi
run create cx3 >/dev/null
if run update cx3 --supervision-mode bogus >/dev/null 2>&1; then no supervision-mode-update-rejects-bogus; else ok supervision-mode-update-rejects-bogus; fi
if run update cx3 --supervision-mode "" >/dev/null 2>&1; then no supervision-mode-empty-rejected; else ok supervision-mode-empty-rejected; fi

# --- question/answer inbox: ask -> has-question -> answer -> has-answer -> consume -> clean ---
hasq(){ run has-question "$1"; }   # exit 0 = an unanswered question is pending
hasa(){ run has-answer "$1"; }     # exit 0 = pending question has been answered, awaiting consume
run create q10 --handoff /art/q10/TEMP.md >/dev/null
if hasq q10; then no fresh-no-question; else ok fresh-no-question; fi
run ask-question q10 --text "smaller GPU ok?" >/dev/null
if hasq q10; then ok ask-sets-has-question; else no ask-sets-has-question; fi
if hasa q10; then no ask-not-yet-answered; else ok ask-not-yet-answered; fi
[ "$(jget q10 question)" = "smaller GPU ok?" ] && ok ask-records-text || no ask-records-text
[ "$(jget q10 question_id)" = 1 ] && ok ask-assigns-id-1 || no "ask-assigns-id-1 ($(jget q10 question_id))"

# a second ask while the first is unanswered is refused, and does NOT overwrite the pending question
if run ask-question q10 --text "second?" >/dev/null 2>&1; then no second-ask-refused; else ok second-ask-refused; fi
[ "$(jget q10 question)" = "smaller GPU ok?" ] && ok second-ask-noop || no second-ask-noop

# answering with the wrong --question-id is refused; the right id (or no id at all) succeeds
if run answer-question q10 --text "no" --question-id 99 >/dev/null 2>&1; then no answer-wrong-id-refused; else ok answer-wrong-id-refused; fi
run answer-question q10 --text "yes, use the small one" --question-id 1 >/dev/null
if hasa q10; then ok answer-sets-has-answer; else no answer-sets-has-answer; fi
[ "$(jget q10 answer)" = "yes, use the small one" ] && ok answer-records-text || no answer-records-text

# a second ask after the first is answered but NOT YET consumed is also refused — it must not
# clobber an answer the executor hasn't read yet (regression: this used to only guard the
# unanswered case, so an answered-but-unconsumed question could be silently overwritten)
if run ask-question q10 --text "third?" >/dev/null 2>&1; then no answered-unconsumed-ask-refused; else ok answered-unconsumed-ask-refused; fi
[ "$(jget q10 question)" = "smaller GPU ok?" ] && ok answered-unconsumed-ask-noop-question || no answered-unconsumed-ask-noop-question
[ "$(jget q10 answer)" = "yes, use the small one" ] && ok answered-unconsumed-ask-noop-answer || no answered-unconsumed-ask-noop-answer

# a second answer-question while the first answer is unconsumed is also refused — it must not
# clobber an answer the executor hasn't read yet (the symmetric gap to the ask-side one above:
# answer-question used to only check a question was pending, not that it was still unanswered)
if run answer-question q10 --text "actually, use the big one" >/dev/null 2>&1; then no answered-unconsumed-reanswer-refused; else ok answered-unconsumed-reanswer-refused; fi
[ "$(jget q10 answer)" = "yes, use the small one" ] && ok answered-unconsumed-reanswer-noop || no answered-unconsumed-reanswer-noop

# consuming clears both; consuming again is idempotent (no error, no residual state)
run consume-question q10 >/dev/null
if hasq q10; then no consume-clears-question; else ok consume-clears-question; fi
[ -z "$(jget q10 question)" ] && ok consume-clears-question-field || no consume-clears-question-field
[ -z "$(jget q10 answer)" ] && ok consume-clears-answer-field || no consume-clears-answer-field
run consume-question q10 >/dev/null && ok consume-idempotent || no consume-idempotent

# question ids stay monotonic across a second round on the same run (never reused after a consume)
run ask-question q10 --text "round 2?" >/dev/null
[ "$(jget q10 question_id)" = 2 ] && ok question-id-monotonic || no "question-id-monotonic ($(jget q10 question_id))"
run answer-question q10 --text "ok" >/dev/null; run consume-question q10 >/dev/null

# --- consume refuses to clear a still-unanswered question (would silently drop it) ---
run create q11 --handoff /art/q11/TEMP.md >/dev/null
run ask-question q11 --text "pending" >/dev/null
if run consume-question q11 >/dev/null 2>&1; then no consume-before-answer-refused; else ok consume-before-answer-refused; fi
if hasq q11; then ok consume-refusal-preserves-question; else no consume-refusal-preserves-question; fi

# --- answering with nothing pending is refused ---
run create q12 >/dev/null
if run answer-question q12 --text "x" >/dev/null 2>&1; then no answer-nothing-pending-refused; else ok answer-nothing-pending-refused; fi

# --- ask-question / answer-question are refused on terminal (stopped/closed) and missing records ---
run create q13 >/dev/null; run stop q13 >/dev/null
if run ask-question q13 --text "x" >/dev/null 2>&1; then no ask-on-stopped-refused; else ok ask-on-stopped-refused; fi
run create q14 >/dev/null; run close q14 >/dev/null
if run ask-question q14 --text "x" >/dev/null 2>&1; then no ask-on-closed-refused; else ok ask-on-closed-refused; fi
if run ask-question nonesuch --text "x" >/dev/null 2>&1; then no ask-missing-refused; else ok ask-missing-refused; fi
if run answer-question nonesuch --text "x" >/dev/null 2>&1; then no answer-missing-refused; else ok answer-missing-refused; fi

# has-question / has-answer are fail-closed on missing/corrupt/terminal records
if hasq nonesuch; then no hasquestion-missing-failclosed; else ok hasquestion-missing-failclosed; fi
if hasq broken; then no hasquestion-corrupt-failclosed; else ok hasquestion-corrupt-failclosed; fi  # broken.json from earlier
run create q15 --handoff /art/q15/TEMP.md >/dev/null; run ask-question q15 --text "x" >/dev/null; run stop q15 >/dev/null
if hasq q15; then no hasquestion-stopped-failclosed; else ok hasquestion-stopped-failclosed; fi

# --- consume-question IS allowed on a terminal record (residual cleanup at close) ---
run create q16 --handoff /art/q16/TEMP.md >/dev/null
run ask-question q16 --text "x" >/dev/null; run answer-question q16 --text "y" >/dev/null
run close q16 >/dev/null
if run consume-question q16 >/dev/null 2>&1; then ok consume-on-closed-ok; else no consume-on-closed-ok; fi

# --- missing --text is rejected ---
run create q17 --handoff /art/q17/TEMP.md >/dev/null
if run ask-question q17 >/dev/null 2>&1; then no ask-missing-text-rejected; else ok ask-missing-text-rejected; fi
run ask-question q17 --text "x" >/dev/null
if run answer-question q17 >/dev/null 2>&1; then no answer-missing-text-rejected; else ok answer-missing-text-rejected; fi

# --- surplus-arg rejected on the no-further-arg new commands ---
run create q18 >/dev/null
if run consume-question q18 oops >/dev/null 2>&1; then no surplus-consume-rejected; else ok surplus-consume-rejected; fi
if run has-question q18 oops >/dev/null 2>&1; then no surplus-hasquestion-rejected; else ok surplus-hasquestion-rejected; fi
if run has-answer q18 oops >/dev/null 2>&1; then no surplus-hasanswer-rejected; else ok surplus-hasanswer-rejected; fi
if run supervision-mode q18 oops >/dev/null 2>&1; then no surplus-supmode-rejected; else ok surplus-supmode-rejected; fi
if run executor-family q18 oops >/dev/null 2>&1; then no surplus-execfam-rejected; else ok surplus-execfam-rejected; fi
if run question-route q18 oops >/dev/null 2>&1; then no surplus-qroute-rejected; else ok surplus-qroute-rejected; fi
if run terminal-route q18 oops >/dev/null 2>&1; then no surplus-troute-rejected; else ok surplus-troute-rejected; fi

# --- status surfaces the new fields, and question/answer only when a question exists ---
run create q19 --handoff /art/q19/TEMP.md --executor-family codex --supervision-mode controller-supervised >/dev/null
status=$(run status q19)
printf '%s\n' "$status" | grep -qx 'executor_family=codex' && ok status-executor-family || no status-executor-family
printf '%s\n' "$status" | grep -qx 'supervision_mode=controller-supervised' && ok status-supervision-mode || no status-supervision-mode
printf '%s\n' "$status" | grep -q '^question=' && no status-no-question-line-when-absent || ok status-no-question-line-when-absent
run ask-question q19 --text "smoke q" >/dev/null
status=$(run status q19)
printf '%s\n' "$status" | grep -qx 'question=smoke q' && ok status-question-line || no status-question-line
printf '%s\n' "$status" | grep -qx 'question_id=1' && ok status-question-id-line || no status-question-id-line
printf '%s\n' "$status" | grep -qx 'answer=' && ok status-answer-empty-line || no status-answer-empty-line

# --- backward-compat: a legacy record with none of the new fields reads as absent-everything, not corrupt ---
if hasq legacy; then no legacy-no-question; else ok legacy-no-question; fi
if run supervision-mode legacy >/dev/null 2>&1; then no legacy-no-supervision-mode; else ok legacy-no-supervision-mode; fi
if run executor-family legacy >/dev/null 2>&1; then no legacy-no-executor-family; else ok legacy-no-executor-family; fi

# ===== #628: supervision-bootstrap receipt (look-again-by field + verify-bootstrap gate) =====
lookagain(){ run look-again "$1"; }

# --- look-again: opaque, set on create, readable, overridable on update; absent -> fail-closed ---
run create la1 --handoff /art/la1/TEMP.md --look-again "1234567890" >/dev/null
[ "$(lookagain la1)" = "1234567890" ] && ok lookagain-create || no lookagain-create
run update la1 --look-again "1234567999" >/dev/null
[ "$(lookagain la1)" = "1234567999" ] && ok lookagain-update || no lookagain-update
run create la2 >/dev/null
if run look-again la2 >/dev/null 2>&1; then no lookagain-absent-failclosed; else ok lookagain-absent-failclosed; fi
if run look-again nonesuch >/dev/null 2>&1; then no lookagain-missing-failclosed; else ok lookagain-missing-failclosed; fi
if run update la1 --look-again "" >/dev/null 2>&1; then no empty-lookagain-rejected; else ok empty-lookagain-rejected; fi
if run look-again la1 oops >/dev/null 2>&1; then no surplus-lookagain-rejected; else ok surplus-lookagain-rejected; fi

# --- verify-bootstrap: successful bootstrap (all fields match + look-again bound) ---
run create vb1 --handoff /art/vb1/TEMP.md --executor-family codex --supervision-mode controller-supervised \
  --worktree /ws/run/vb1 --question-route record --terminal-route record --look-again "111" >/dev/null
if run verify-bootstrap vb1 --executor-family codex --supervision-mode controller-supervised \
     --worktree /ws/run/vb1 --question-route record --terminal-route record \
     --timeout-sec 2 --poll-interval-sec 1 >"$TMP/vb1.out" 2>&1; then ok verify-bootstrap-success; else no verify-bootstrap-success; fi
grep -q "supervision-bootstrap receipt PASSED" "$TMP/vb1.out" && ok verify-bootstrap-receipt-line || no verify-bootstrap-receipt-line

# --- verify-bootstrap: missing record — never appears, fails at the timeout deadline (not fail-fast) ---
if run verify-bootstrap vb_nonesuch --executor-family codex --supervision-mode controller-supervised \
     --worktree /ws/run/vb_nonesuch --question-route record --terminal-route record \
     --timeout-sec 1 --poll-interval-sec 1 >"$TMP/vb_missing.out" 2>&1; then no verify-bootstrap-missing-record; else ok verify-bootstrap-missing-record; fi
grep -q "no supervision record ever appeared" "$TMP/vb_missing.out" && ok verify-bootstrap-missing-message || no verify-bootstrap-missing-message

# --- verify-bootstrap: wrong worktree/mode/route — fails IMMEDIATELY, not at the (long) timeout deadline ---
run create vb2 --handoff /art/vb2/TEMP.md --executor-family codex --supervision-mode controller-supervised \
  --worktree /ws/run/vb2 --question-route record --terminal-route record --look-again "222" >/dev/null
VB2_START=$(date +%s)
if run verify-bootstrap vb2 --executor-family codex --supervision-mode controller-supervised \
     --worktree /ws/run/WRONG --question-route record --terminal-route record \
     --timeout-sec 30 --poll-interval-sec 1 >"$TMP/vb2.out" 2>&1; then no verify-bootstrap-wrong-worktree; else ok verify-bootstrap-wrong-worktree; fi
VB2_ELAPSED=$(( $(date +%s) - VB2_START ))
[ "$VB2_ELAPSED" -lt 10 ] && ok verify-bootstrap-wrong-worktree-failfast || no "verify-bootstrap-wrong-worktree-failfast (took ${VB2_ELAPSED}s)"
grep -q "worktree_path mismatch" "$TMP/vb2.out" && ok verify-bootstrap-wrong-worktree-message || no verify-bootstrap-wrong-worktree-message

run create vb3 --handoff /art/vb3/TEMP.md --executor-family codex --supervision-mode controller-supervised \
  --worktree /ws/run/vb3 --question-route record --terminal-route record --look-again "333" >/dev/null
if run verify-bootstrap vb3 --executor-family codex --supervision-mode autonomous-detached \
     --worktree /ws/run/vb3 --question-route record --terminal-route record \
     --timeout-sec 30 --poll-interval-sec 1 >"$TMP/vb3.out" 2>&1; then no verify-bootstrap-wrong-mode; else ok verify-bootstrap-wrong-mode; fi
grep -q "supervision_mode mismatch" "$TMP/vb3.out" && ok verify-bootstrap-wrong-mode-message || no verify-bootstrap-wrong-mode-message

run create vb4 --handoff /art/vb4/TEMP.md --executor-family claude --supervision-mode controller-supervised \
  --worktree /ws/run/vb4 --question-route record --terminal-route record --look-again "444" >/dev/null
if run verify-bootstrap vb4 --executor-family codex --supervision-mode controller-supervised \
     --worktree /ws/run/vb4 --question-route record --terminal-route record \
     --timeout-sec 30 --poll-interval-sec 1 >"$TMP/vb4.out" 2>&1; then no verify-bootstrap-wrong-family; else ok verify-bootstrap-wrong-family; fi
grep -q "executor_family mismatch" "$TMP/vb4.out" && ok verify-bootstrap-wrong-family-message || no verify-bootstrap-wrong-family-message

run create vb5 --handoff /art/vb5/TEMP.md --executor-family codex --supervision-mode controller-supervised \
  --worktree /ws/run/vb5 --question-route "chan:#other" --terminal-route record --look-again "555" >/dev/null
if run verify-bootstrap vb5 --executor-family codex --supervision-mode controller-supervised \
     --worktree /ws/run/vb5 --question-route record --terminal-route record \
     --timeout-sec 30 --poll-interval-sec 1 >"$TMP/vb5.out" 2>&1; then no verify-bootstrap-wrong-qroute; else ok verify-bootstrap-wrong-qroute; fi
grep -q "question_route mismatch" "$TMP/vb5.out" && ok verify-bootstrap-wrong-qroute-message || no verify-bootstrap-wrong-qroute-message

# --- verify-bootstrap: bootstrap timeout — record active + all fields match, but no look-again receipt yet ---
run create vb6 --handoff /art/vb6/TEMP.md --executor-family codex --supervision-mode controller-supervised \
  --worktree /ws/run/vb6 --question-route record --terminal-route record >/dev/null
if run verify-bootstrap vb6 --executor-family codex --supervision-mode controller-supervised \
     --worktree /ws/run/vb6 --question-route record --terminal-route record \
     --timeout-sec 2 --poll-interval-sec 1 >"$TMP/vb6.out" 2>&1; then no verify-bootstrap-timeout; else ok verify-bootstrap-timeout; fi
grep -q "never reached the full expected state" "$TMP/vb6.out" && ok verify-bootstrap-timeout-message || no verify-bootstrap-timeout-message

# --- verify-bootstrap: terminal (stopped/closed/invalid) records refused immediately, never treated as a healthy wait ---
run create vb7 --handoff /art/vb7/TEMP.md --executor-family codex --supervision-mode controller-supervised \
  --worktree /ws/run/vb7 --question-route record --terminal-route record --look-again "777" >/dev/null
run stop vb7 >/dev/null
if run verify-bootstrap vb7 --executor-family codex --supervision-mode controller-supervised \
     --worktree /ws/run/vb7 --question-route record --terminal-route record \
     --timeout-sec 30 --poll-interval-sec 1 >/dev/null 2>&1; then no verify-bootstrap-stopped-refused; else ok verify-bootstrap-stopped-refused; fi
if run verify-bootstrap broken --executor-family codex --supervision-mode controller-supervised \
     --worktree /ws/run/broken --question-route record --terminal-route record \
     --timeout-sec 30 --poll-interval-sec 1 >/dev/null 2>&1; then no verify-bootstrap-corrupt-refused; else ok verify-bootstrap-corrupt-refused; fi

# --- verify-bootstrap: required-arg / malformed-timeout validation ---
if run verify-bootstrap vb1 --supervision-mode controller-supervised --worktree /x --question-route record --terminal-route record >/dev/null 2>&1; then no verify-bootstrap-missing-family-arg-rejected; else ok verify-bootstrap-missing-family-arg-rejected; fi
if run verify-bootstrap vb1 --executor-family codex --supervision-mode controller-supervised --worktree /x --question-route record --terminal-route record --timeout-sec abc >/dev/null 2>&1; then no verify-bootstrap-bad-timeout-rejected; else ok verify-bootstrap-bad-timeout-rejected; fi

[ "$fails" = 0 ] && { echo "run_supervision_record smoke PASS"; exit 0; } || { echo "run_supervision_record smoke FAIL"; exit 1; }
