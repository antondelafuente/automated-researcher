#!/usr/bin/env bash
# blocked_state_smoke.sh — offline behavior smoke for the issue-side blocked-state machine
# (automated-researcher#629, the #620 dead-letter incident).
#
# This is the deterministic check issue #629's acceptance asks for. It covers both halves of the fix:
#   - blocked-state.sh's decision logic, driven with the real fetched-JSON shapes the workflow passes it
#     (REST comments array + a label-name array + the GraphQL lastEditedAt/editor pair), including the
#     three ways the loop protection could fail OPEN — a bare `ready` re-add re-dispatching anyway, a
#     non-authority (in particular the implementor bot itself) unblocking with its own `DECISION: PROCEED`,
#     or that same bot unblocking itself by EDITING the issue body, which is an ordinary content act here
#     and so must be author-attributed exactly like the comment route;
#   - static assertions on implement-on-ready.yml that the routing actuator is actually wired: blocked ⇒
#     `ready` removed + blocked-state label + `needs-human` + machine-readable record + a non-success run
#     conclusion, a bare-ready re-add refused before any implementor run is spent, the pre-PR and post-PR
#     blocks routed to their distinct escalation surfaces, every restore path clearing BOTH blocked labels,
#     and the `opened` path left exactly as it was (enable-automerge still gated only on `pr_number`).
# Fully offline: no network, no gh, no tokens.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SELF_DIR/blocked-state.sh"
REPO_ROOT="$(cd "$SELF_DIR/../.." && pwd)"
WORKFLOW="$REPO_ROOT/.github/workflows/implement-on-ready.yml"
[ -f "$SCRIPT" ] || { echo "FAIL: blocked-state.sh not found next to smoke" >&2; exit 1; }

AUTHORITY="antondelafuente senior-engineer-agent[bot]"
RECORD_AUTHOR="claude-code-engineer[bot]"
BLOCKED_LABEL="$("$SCRIPT" label)"
MARKER="$("$SCRIPT" record-marker)"

FAILS=0
pass() { echo "  ok: $1"; }
fail() { echo "  FAIL: $1" >&2; FAILS=$((FAILS+1)); }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

echo '["ready","bug"]' > "$TMP/labels_plain.json"
printf '%s\n' "[\"bug\",\"ready\",\"$BLOCKED_LABEL\",\"needs-human\"]" > "$TMP/labels_blocked.json"

# Build a comments array from "login|created_at|body" triples (body \n-escapes are expanded by json.dumps).
comments() {
  local out="$1"; shift
  COMMENTS_SPEC="$*" python3 - "$out" <<'PY'
import json
import os
import sys

items = []
for spec in os.environ["COMMENTS_SPEC"].split("\x1f"):
    if not spec:
        continue
    login, created, body = spec.split("|", 2)
    items.append({"user": {"login": login}, "created_at": created, "body": body.replace("\\n", "\n")})
with open(sys.argv[1], "w") as fh:
    json.dump(items, fh)
PY
}
spec() { local IFS=$'\x1f'; printf '%s' "$*"; }

# The GraphQL `repository.issue` packet the workflow hands the guard: when the body was edited, and by
# whom. `edit_state <file> <lastEditedAt> [<__typename> <login>]` — omit the editor pair for the
# unattributable case (a deleted account, or a caller that failed to request the field).
edit_state() {
  local out="$1" ts="$2" typename="${3-}" login="${4-}"
  jq -n --arg ts "$ts" --arg t "$typename" --arg l "$login" '
    { lastEditedAt: (if $ts == "" then null else $ts end),
      editor: (if $l == "" then null else { __typename: $t, login: $l } end) }' > "$out"
}

RECORD_BODY="$MARKER\\nimplementation-status: blocked\\nblock-reason: external-verification-unavailable\\n<!-- IMPLEMENTATION-STATE:END -->"
REC="$RECORD_AUTHOR|2026-07-25T10:00:05Z|$RECORD_BODY"
EXPLANATION="$RECORD_AUTHOR|2026-07-25T10:00:00Z|I cannot verify the acceptance step from inside this runner."

assert_decide() {
  local desc="$1" expected="$2" labels="$3" comments_file="$4" edit_file="${5-}"
  local got
  got=$("$SCRIPT" decide "$AUTHORITY" "$RECORD_AUTHOR" "$labels" "$comments_file" "$edit_file" 2>/dev/null)
  if [ "$got" = "$expected" ]; then pass "$desc -> $got"
  else fail "$desc -> '$got', expected '$expected'"; fi
}

echo "[smoke] group A: the dispatchable/inert decision"

comments "$TMP/c_record.json" "$(spec "$EXPLANATION" "$REC")"
assert_decide "no blocked-state label (the unchanged happy path) -> dispatch proceeds" \
  "dispatchable not-blocked" "$TMP/labels_plain.json" "$TMP/c_record.json"
assert_decide "blocked + record, bare 'ready' re-add (the #620 re-cycles) -> inert" \
  "inert blocked" "$TMP/labels_blocked.json" "$TMP/c_record.json"

comments "$TMP/c_proceed.json" "$(spec "$REC" \
  "antondelafuente|2026-07-25T11:00:00Z|Checked it live myself.\\nDECISION: PROCEED\\nSCOPE: issue-620\\nOVERRIDES: the external-verification step\\nRATIONALE: I verified it")"
assert_decide "blocked + researcher DECISION: PROCEED after the record -> dispatchable" \
  "dispatchable decision-proceed" "$TMP/labels_blocked.json" "$TMP/c_proceed.json"

comments "$TMP/c_revise.json" "$(spec "$REC" \
  "app/senior-engineer-agent|2026-07-25T11:00:00Z|Verified empirically.\\n  DECISION: REVISE\\nSCOPE: issue-620")"
assert_decide "blocked + senior-engineer DECISION: REVISE (app/<slug> identity form) -> dispatchable" \
  "dispatchable decision-revise" "$TMP/labels_blocked.json" "$TMP/c_revise.json"

# The self-unblock hole: the agent that blocked must not be able to clear its own block. This is the
# authority inversion #620 ran into and #632 defines away — RESTORE_AUTHORITY deliberately excludes both
# engineer bots.
comments "$TMP/c_self.json" "$(spec "$REC" "$RECORD_AUTHOR|2026-07-25T11:00:00Z|DECISION: PROCEED")"
assert_decide "blocked + the implementor bot's OWN DECISION: PROCEED -> inert (no self-unblock)" \
  "inert blocked" "$TMP/labels_blocked.json" "$TMP/c_self.json"

comments "$TMP/c_outsider.json" "$(spec "$REC" "some-outsider|2026-07-25T11:00:00Z|DECISION: PROCEED")"
assert_decide "blocked + an outside commenter's DECISION: PROCEED -> inert (public-repo forgery)" \
  "inert blocked" "$TMP/labels_blocked.json" "$TMP/c_outsider.json"

comments "$TMP/c_codex.json" "$(spec "$REC" "codex-engineer[bot]|2026-07-25T11:00:00Z|DECISION: PROCEED")"
assert_decide "blocked + the codex engineer bot's DECISION: PROCEED -> inert (dispatch allowlist != restore authority)" \
  "inert blocked" "$TMP/labels_blocked.json" "$TMP/c_codex.json"

comments "$TMP/c_stop.json" "$(spec "$REC" \
  "antondelafuente|2026-07-25T11:00:00Z|DECISION: STOP\\nRATIONALE: park this until the prerequisite lands")"
assert_decide "blocked + DECISION: STOP -> inert (a decision NOT to re-dispatch)" \
  "inert decision-stop" "$TMP/labels_blocked.json" "$TMP/c_stop.json"

comments "$TMP/c_stop_then_go.json" "$(spec "$REC" \
  "antondelafuente|2026-07-25T11:00:00Z|DECISION: STOP" \
  "antondelafuente|2026-07-25T12:00:00Z|DECISION: PROCEED")"
assert_decide "blocked + STOP then a later PROCEED -> latest decision wins" \
  "dispatchable decision-proceed" "$TMP/labels_blocked.json" "$TMP/c_stop_then_go.json"

comments "$TMP/c_stale.json" "$(spec \
  "antondelafuente|2026-07-25T09:00:00Z|DECISION: PROCEED" "$REC")"
assert_decide "blocked + a PROCEED from BEFORE the record (a prior round's decision) -> inert" \
  "inert blocked" "$TMP/labels_blocked.json" "$TMP/c_stale.json"

comments "$TMP/c_prose.json" "$(spec "$REC" \
  "antondelafuente|2026-07-25T11:00:00Z|you could post a DECISION: PROCEED line if you want to unblock it")"
assert_decide "blocked + a mid-sentence mention of the protocol -> inert (only a line-anchored verb counts)" \
  "inert blocked" "$TMP/labels_blocked.json" "$TMP/c_prose.json"

# The body-edit route is an AUTHORIZATION act, so it is author-attributed exactly like the DECISION route
# (round-2 review P0). Without attribution, editing the body is a self-unblock hole wide open to both
# engineer bots: the triager edits ticket bodies as its normal job (AGENTS.md "Shaping rights"), and an
# agent-filed issue's author is an engineer bot, which can always edit its own body.
edit_state "$TMP/e_researcher.json" "2026-07-25T12:00:00Z" User antondelafuente
edit_state "$TMP/e_senior.json" "2026-07-25T12:00:00Z" Bot senior-engineer-agent
edit_state "$TMP/e_implementor.json" "2026-07-25T12:00:00Z" Bot claude-code-engineer
edit_state "$TMP/e_triager.json" "2026-07-25T12:00:00Z" Bot codex-engineer
edit_state "$TMP/e_outsider.json" "2026-07-25T12:00:00Z" User some-outsider
edit_state "$TMP/e_lookalike.json" "2026-07-25T12:00:00Z" User senior-engineer-agent
edit_state "$TMP/e_unattributed.json" "2026-07-25T12:00:00Z"
edit_state "$TMP/e_stale.json" "2026-07-25T09:00:00Z" User antondelafuente
edit_state "$TMP/e_late.json" "2026-07-25T13:00:00Z" User antondelafuente
edit_state "$TMP/e_never.json" ""

assert_decide "blocked + a researcher body edit after the record -> dispatchable" \
  "dispatchable body-edited" "$TMP/labels_blocked.json" "$TMP/c_record.json" "$TMP/e_researcher.json"
assert_decide "blocked + a senior-engineer body edit (GraphQL Bot login is the BARE slug) -> dispatchable" \
  "dispatchable body-edited" "$TMP/labels_blocked.json" "$TMP/c_record.json" "$TMP/e_senior.json"
assert_decide "blocked + the implementor bot editing the issue IT filed -> inert (no self-unblock by body edit)" \
  "inert blocked" "$TMP/labels_blocked.json" "$TMP/c_record.json" "$TMP/e_implementor.json"
assert_decide "blocked + the codex engineer bot's body edit -> inert (dispatch allowlist != restore authority)" \
  "inert blocked" "$TMP/labels_blocked.json" "$TMP/c_record.json" "$TMP/e_triager.json"
assert_decide "blocked + an outside collaborator's body edit -> inert" \
  "inert blocked" "$TMP/labels_blocked.json" "$TMP/c_record.json" "$TMP/e_outsider.json"
assert_decide "blocked + a USER account whose name matches the authority BOT's slug -> inert (identity shape is load-bearing)" \
  "inert blocked" "$TMP/labels_blocked.json" "$TMP/c_record.json" "$TMP/e_lookalike.json"
assert_decide "blocked + an edit GitHub cannot attribute (deleted account / absent editor) -> inert (fail closed)" \
  "inert blocked" "$TMP/labels_blocked.json" "$TMP/c_record.json" "$TMP/e_unattributed.json"
assert_decide "blocked + a researcher body edit from BEFORE the record -> inert" \
  "inert blocked" "$TMP/labels_blocked.json" "$TMP/c_record.json" "$TMP/e_stale.json"
assert_decide "blocked + a researcher body edit after a STOP -> dispatchable (latest material signal wins)" \
  "dispatchable body-edited" "$TMP/labels_blocked.json" "$TMP/c_stop.json" "$TMP/e_late.json"
# A discarded edit is NO signal, not a late one: it must not release the block, and it must not revoke an
# authority PROCEED it happens to postdate either.
assert_decide "blocked + PROCEED, then a non-authority body edit after it -> still dispatchable (an unauthorized act neither grants nor revokes)" \
  "dispatchable decision-proceed" "$TMP/labels_blocked.json" "$TMP/c_proceed.json" "$TMP/e_implementor.json"
assert_decide "blocked + lastEditedAt null (never-edited body) -> inert, not an error" \
  "inert blocked" "$TMP/labels_blocked.json" "$TMP/c_record.json" "$TMP/e_never.json"
assert_decide "blocked + no edit packet passed at all -> inert, not an error" \
  "inert blocked" "$TMP/labels_blocked.json" "$TMP/c_record.json" ""

# Fail-closed direction: the label is the visible state, so a missing/forged record never opens the gate.
comments "$TMP/c_none.json" "$(spec "$EXPLANATION")"
assert_decide "blocked label with NO state record -> inert (fail closed; remove the label to restore)" \
  "inert no-record" "$TMP/labels_blocked.json" "$TMP/c_none.json"

comments "$TMP/c_forged.json" "$(spec "some-outsider|2026-07-25T10:00:05Z|$RECORD_BODY")"
assert_decide "a state record forged by an outside commenter is not a record -> inert no-record" \
  "inert no-record" "$TMP/labels_blocked.json" "$TMP/c_forged.json"

comments "$TMP/c_forged_late.json" "$(spec "$REC" \
  "antondelafuente|2026-07-25T11:00:00Z|DECISION: PROCEED" \
  "some-outsider|2026-07-25T11:30:00Z|$RECORD_BODY")"
assert_decide "an outsider's LATER forged record cannot invalidate a real decision -> still dispatchable" \
  "dispatchable decision-proceed" "$TMP/labels_blocked.json" "$TMP/c_forged_late.json"

# Identity-form equivalence (automated-researcher#381): the record author may be named in either form.
got=$("$SCRIPT" decide "$AUTHORITY" "app/claude-code-engineer" "$TMP/labels_blocked.json" "$TMP/c_proceed.json" 2>/dev/null)
if [ "$got" = "dispatchable decision-proceed" ]; then
  pass "record author given as app/<slug> matches a <slug>[bot]-authored record -> $got"
else
  fail "record author given as app/<slug> -> '$got', expected 'dispatchable decision-proceed'"
fi

echo "[smoke] group B: block-reason normalization (model-authored text, never trusted raw)"
assert_reason() {
  local raw="$1" expected="$2" got
  got=$("$SCRIPT" normalize-reason "$raw")
  if [ "$got" = "$expected" ]; then pass "normalize-reason '$raw' -> $got"
  else fail "normalize-reason '$raw' -> '$got', expected '$expected'"; fi
}
assert_reason "External Verification Unavailable!" "external-verification-unavailable"
assert_reason "already-a-slug" "already-a-slug"
assert_reason "" "unspecified"
assert_reason "   " "unspecified"
assert_reason "---" "unspecified"
assert_reason "spec_contradiction (issue #620)" "spec-contradiction-issue-620"
long_reason=$(printf 'verification %.0s' $(seq 1 20))
got=$("$SCRIPT" normalize-reason "$long_reason")
if [ "${#got}" -le 64 ] && [ -n "$got" ] && [ "${got%-}" = "$got" ]; then
  pass "normalize-reason truncates an overlong reason to ${#got} chars with no trailing dash"
else
  fail "normalize-reason overlong -> '$got' (len ${#got}); expected <=64 chars, no trailing dash"
fi

echo "[smoke] group B2: present-labels only ever names labels actually on the issue"
got=$("$SCRIPT" present-labels "$TMP/labels_blocked.json" ready needs-senior-engineer | tr '\n' ' ')
if [ "$got" = "ready " ]; then
  pass "present-labels drops needs-senior-engineer (not on the issue) and keeps ready -> '$got'"
else
  fail "present-labels -> '$got', expected 'ready '"
fi
got=$("$SCRIPT" present-labels "$TMP/labels_plain.json" "$BLOCKED_LABEL" needs-human | tr '\n' ' ')
if [ -z "$got" ]; then
  pass "present-labels prints nothing when none of the requested labels are present"
else
  fail "present-labels on an unblocked issue -> '$got', expected empty"
fi

echo "[smoke] group C: the rendered state record is machine-readable"
record=$("$SCRIPT" render-record external-verification-unavailable "https://example.test/run/42")
for needle in "$MARKER" "implementation-status: blocked" "block-reason: external-verification-unavailable" \
              "blocked-run: https://example.test/run/42" "<!-- IMPLEMENTATION-STATE:END -->"; do
  if printf '%s' "$record" | grep -qF -- "$needle"; then pass "record contains '$needle'"
  else fail "record is missing '$needle'"; fi
done
# The record must never look like a binding decision itself: it names the protocol in prose, and a
# line-anchored DECISION verb inside a record would be a self-unblock vector if the record author were ever
# added to the restore authority.
if printf '%s' "$record" | grep -qE '^[[:space:]]*DECISION:[[:space:]]*(PROCEED|REVISE|STOP)([[:space:]]|$)'; then
  fail "the rendered record contains a line-anchored DECISION verb"
else
  pass "the rendered record carries no line-anchored DECISION verb"
fi
# It must tell a reader how to get out of the state — the record is the researcher-facing half of the fix,
# including WHO the body-edit route is open to, so nobody reads it as "any edit releases this".
for needle in "$BLOCKED_LABEL" "Re-dispatch is INERT" "Edit this issue's body" \
              "The edit must" "restore authority"; do
  if printf '%s' "$record" | grep -qF -- "$needle"; then pass "record explains '$needle'"
  else fail "record does not mention '$needle'"; fi
done

echo "[smoke] group D: implement-on-ready.yml wiring (the actuator half)"
if [ ! -f "$WORKFLOW" ]; then
  fail "implement-on-ready.yml not found at $WORKFLOW"
else
  assert_yaml() {
    local desc="$1" pattern="$2"
    if grep -qE -- "$pattern" "$WORKFLOW"; then pass "$desc"
    else fail "$desc (no line matching /$pattern/ in implement-on-ready.yml)"; fi
  }

  # The loop guard runs, from the trusted checkout, before anything is spent.
  assert_yaml "a blocked-state loop guard step exists" "id: loop_guard"
  assert_yaml "the guard calls blocked-state.sh decide" "blocked-state\.sh decide"
  assert_yaml "the guard is handed the restore authority + record author" \
    "\"\\\$RESTORE_AUTHORITY\" \"\\\$STATE_RECORD_AUTHOR\""
  # The body-edit route only holds if the guard is told WHO edited: fetching lastEditedAt without `editor`
  # would silently reopen the self-unblock hole (round-2 review P0), since the script then sees an
  # unattributable edit and — correctly, but uselessly — discards every body edit.
  assert_yaml "the guard's GraphQL query fetches the body EDITOR, not just lastEditedAt" \
    "lastEditedAt editor\{__typename login\}"
  assert_yaml "the guard passes the edit-attribution packet to the state machine" \
    "issue_comments\.json\" \"\\\$RUNNER_TEMP/issue_edit\.json\""
  guard_line=$(grep -n "id: loop_guard" "$WORKFLOW" | head -1 | cut -d: -f1)
  checkout_line=$(grep -n "name: Checkout base branch" "$WORKFLOW" | head -1 | cut -d: -f1)
  if [ -n "$guard_line" ] && [ -n "$checkout_line" ] && [ "$guard_line" -gt "$checkout_line" ]; then
    pass "the guard (line $guard_line) runs after the base checkout (line $checkout_line) that provides its helper"
  else
    fail "could not confirm the guard runs after the base checkout (guard=$guard_line checkout=$checkout_line)"
  fi

  # RESTORE_AUTHORITY must stay narrower than the dispatch allowlist: neither engineer bot may unblock
  # itself. This is the regression guard for group A's self-unblock cases.
  authority_line=$(grep -E '^\s*RESTORE_AUTHORITY:' "$WORKFLOW" | head -1)
  if [ -z "$authority_line" ]; then
    fail "RESTORE_AUTHORITY is not defined in implement-on-ready.yml"
  elif printf '%s' "$authority_line" | grep -qE 'claude-code-engineer|codex-engineer'; then
    fail "RESTORE_AUTHORITY includes an engineer bot ($authority_line) — an agent could unblock itself"
  else
    pass "RESTORE_AUTHORITY excludes the engineer bots ($authority_line)"
  fi

  # Every step that spends money or mutates state on the dispatch path is gated on the guard, so an inert
  # re-add cannot reach the CLI (the #620 cost) — checked per step, since one missed gate is the whole bug.
  assert_step_guarded() {
    local step="$1" line body
    line=$(grep -n -m1 -F -- "- name: $step" "$WORKFLOW" | cut -d: -f1)
    if [ -z "$line" ]; then fail "step '$step' not found in implement-on-ready.yml"; return; fi
    body=$(sed -n "$((line + 1)),$((line + 4))p" "$WORKFLOW")
    if printf '%s' "$body" | grep -qF "steps.loop_guard.outputs.verdict != 'inert'"; then
      pass "step '$step' is gated on the loop guard"
    else
      fail "step '$step' (line $line) is NOT gated on the loop guard — an inert re-add would still run it"
    fi
  }
  assert_step_guarded "Render implementor prompt"
  assert_step_guarded "Mint claude engineer App token"
  assert_step_guarded "Install pinned Claude Code"
  assert_step_guarded "Configure implementor git identity"
  assert_step_guarded "Run pinned Claude Code CLI (implementor)"
  assert_step_guarded "Resolve job outputs"

  # The `if:` line of a named step (steps declare it within the first few lines of their block).
  step_if() {
    local step="$1" line
    line=$(grep -n -m1 -F -- "- name: $step" "$WORKFLOW" | cut -d: -f1)
    [ -n "$line" ] || return 1
    sed -n "$((line + 1)),$((line + 3))p" "$WORKFLOW" | grep -m1 -E '^[[:space:]]+if:' || true
  }

  # Releasing the block must clear BOTH labels on EVERY restore path (round-1 review P0). Removing
  # `implementation-blocked` by hand — one of the three documented restores — makes the guard report
  # `not-blocked`, so gating the clear on the guard's `why` would leave `needs-human` stranded on an issue
  # the implementor is actively working, contradicting the documented restore.
  clear_if=$(step_if "Clear released blocked state")
  if [ -z "$clear_if" ]; then
    fail "the 'Clear released blocked state' step has no if: condition (or the step is gone)"
  elif printf '%s' "$clear_if" | grep -qF "not-blocked"; then
    fail "the release-clear step is gated on the guard's why ($clear_if) — the label-removal restore reports 'not-blocked', so needs-human would be stranded"
  elif printf '%s' "$clear_if" | grep -qF "verdict != 'inert'"; then
    pass "the release-clear step runs on every proceeding dispatch, so a label-removal restore clears needs-human too"
  else
    fail "unexpected gate on the release-clear step: $clear_if"
  fi
  assert_yaml "the release-clear step clears the blocked-state label AND needs-human" \
    "present-labels .*needs-human"

  # blocked ⇒ routed: ready removed, blocked-state label + needs-human applied, record recorded, run red.
  assert_yaml "a route-blocked job exists" "^  route-blocked:"
  assert_yaml "route-blocked fires only on a blocked outcome" \
    "needs\.implement\.outputs\.status == 'blocked'"
  assert_yaml "routing removes the stale 'ready' + the unconsumable issue-level needs-senior-engineer" \
    "present-labels .* ready needs-senior-engineer"
  assert_yaml "routing ensures its labels exist before applying them (fresh deployments)" \
    "gh label create \"\\\$BLOCKED_LABEL\""
  assert_yaml "routing applies the blocked-state label" '--add-label "\$BLOCKED_LABEL"'
  assert_yaml "routing escalates to the watched needs-human surface" "--add-label needs-human"
  assert_yaml "routing records the machine-readable state record" "blocked-state\.sh render-record"
  assert_yaml "the routed state is verified against GitHub, not self-reported" \
    "name: Verify routed blocked state"
  assert_yaml "a blocked run concludes non-success for run-level observers" \
    "name: Signal blocked outcome"

  # The record must be posted BEFORE the labels: the guard fails closed on label-without-record, so the
  # reverse order could leave an issue only a label removal can rescue.
  comment_line=$(grep -n "gh issue comment" "$WORKFLOW" | head -1 | cut -d: -f1)
  label_line=$(grep -n -- "--add-label \"\$BLOCKED_LABEL\"" "$WORKFLOW" | head -1 | cut -d: -f1)
  if [ -n "$comment_line" ] && [ -n "$label_line" ] && [ "$comment_line" -lt "$label_line" ]; then
    pass "the state record is posted (line $comment_line) before the blocked label is applied (line $label_line)"
  else
    fail "could not confirm record-before-label ordering (comment=$comment_line label=$label_line)"
  fi

  # Pre-PR and post-PR blocks are DIFFERENT escalation paths (round-1 review P0): the issue-side terminal
  # state is for a block with no PR; a block found after a PR was opened belongs on that PR's
  # `needs-senior-engineer`, the summons senior-engineer.yml actually watches. Applying the issue-side state
  # to a post-PR block marks an issue blocked while its PR is in flight.
  assert_yaml "the implement job publishes the blocked run's PR separately from pr_number" \
    "^      blocked_pr:"
  if grep -qE '^\s+pr_number=""$' "$WORKFLOW"; then
    pass "a non-opened status still clears pr_number, so a blocked result can never reach enable-automerge"
  else
    fail "the non-opened pr_number clearing is gone — a blocked result could reach enable-automerge's gate"
  fi
  assert_yaml "route-blocked resolves which surface carries the escalation" "id: surface"
  assert_yaml "the reported blocked PR is verified against GitHub, not trusted" \
    'gh pr view "\$BLOCKED_PR" --repo "\$REPO" --json state'
  assert_yaml "only an OPEN pull request takes the PR route (anything else falls back to the issue)" \
    '\[ "\$state" = "OPEN" \]'
  assert_surface_gated() {
    local step="$1" want="$2" cond
    cond=$(step_if "$step")
    if [ -z "$cond" ]; then fail "step '$step' is not gated on the escalation surface (no if:)"; return; fi
    if printf '%s' "$cond" | grep -qF "steps.surface.outputs.target == '$want'"; then
      pass "step '$step' runs only for the '$want' surface"
    else
      fail "step '$step' is not gated on the '$want' surface (if: $cond)"
    fi
  }
  assert_surface_gated "Route the blocked outcome onto the issue" issue
  assert_surface_gated "Verify routed blocked state" issue
  assert_surface_gated "Route the blocked outcome onto the PR" pr
  assert_yaml "a post-PR block is routed to the PR's senior-engineer summons" \
    "--add-label needs-senior-engineer"
  assert_yaml "the PR-side summons is verified present, not self-reported" \
    "should carry needs-senior-engineer after routing"

  # A refused re-dispatch is loud and self-correcting, never a silent green no-op.
  assert_yaml "a reject-redispatch job exists" "^  reject-redispatch:"
  assert_yaml "reject-redispatch fires exactly on an inert verdict" \
    "needs\.implement\.outputs\.guard_verdict == 'inert'"
  assert_yaml "a refused re-dispatch takes the inert 'ready' label back off" \
    "gh issue edit \"\\\$ISSUE_NUMBER\" --repo \"\\\$REPO\" --remove-label ready"

  # opened ⇒ unchanged: auto-merge still keys off pr_number alone, with no blocked-state coupling.
  assert_yaml "enable-automerge is still gated only on pr_number" \
    "needs\.implement\.outputs\.pr_number != ''"
  if grep -A2 "^  enable-automerge:" "$WORKFLOW" | grep -q "blocked"; then
    fail "enable-automerge's gate now references the blocked state — the opened path must be unchanged"
  else
    pass "enable-automerge's gate is untouched by the blocked-state machinery"
  fi
fi

if [ "$FAILS" -eq 0 ]; then echo "[smoke] blocked-state: ALL PASS"; exit 0; else
  echo "[smoke] blocked-state: $FAILS FAILURE(S)" >&2; exit 1; fi
