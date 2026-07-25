#!/usr/bin/env bash
# blocked-state.sh — the issue-side blocked-state machine for the implement leg (automated-researcher#629).
#
# Incident (#620, 2026-07-24/25): the implementor correctly blocked fail-closed on an acceptance step it
# could not verify from inside its runner, posted an explanation comment, applied `needs-senior-engineer`
# to the ISSUE, and reported `status: blocked`. Nothing consumed any of it — `needs-senior-engineer` is
# watched only on PRs (senior-engineer.yml / reconcile-prs.yml are PR-scoped), the workflow run concluded
# SUCCESS, and `ready` stayed applied while never re-firing on its own. The ticket sat silently ~14h; after
# the researcher intervened, `ready` was re-cycled three more times and each fresh stateless run re-derived
# the identical block from the identical priors — four blocked runs, resolved only by a manual owner PR
# (#631).
#
# This script is the STATE half of the fix (implement-on-ready.yml is the actuator half): it renders the
# machine-readable blocked-state record the implement workflow posts on the issue, and decides whether a
# (re-)dispatch may proceed while that state stands. It makes NO network calls and holds no policy about
# who may dispatch (that stays in implement-on-ready.yml's own authorize step) — the caller fetches the
# inputs and passes them in, which is what makes this logic exercisable offline by blocked_state_smoke.sh.
#
# THE INVARIANT this file exists to hold: releasing a blocked issue is an AUTHORIZATION ACT by an
# IDENTIFIED restore-authority principal. Every transition from inert to dispatchable must be attributable
# to a principal, and that principal must be in the restore authority; a signal whose author this script
# cannot name is not a weak signal, it is NO signal (it neither releases the block nor supersedes an
# earlier authority decision). The restore authority deliberately excludes the engineer bots themselves: an
# agent that blocked must not be able to release itself, by ANY route (the authority inversion #620 and
# #632 are about).
#
# Restore authority — the material state transitions that release a blocked issue for re-dispatch (issue
# #629: "Only that consumer or a human restores the dispatchable state"):
#   1. Removing the blocked-state label: a write-access maintainer's explicit act, nothing for this script
#      to decide (with the label gone, `decide` reports `not-blocked`). See the note below on why this one
#      is not editor-attributed the way 2 and 3 are.
#   2. A `DECISION: PROCEED` / `DECISION: REVISE` comment (issue #632's binding-decision form; this ticket
#      consumes the verb line as an unblock trigger and NOTHING more) authored by one of the restore
#      authority logins the caller passes in, posted AFTER the most recent blocked-state record.
#      `DECISION: STOP` is honored as a decision NOT to re-dispatch.
#   3. An issue-BODY edit after the most recent blocked-state record, made BY a restore-authority login —
#      the block-reason being addressed in the contract a zero-context implementor actually reads. The
#      EDITOR is identified (GraphQL `issue.editor`), never assumed from the fact that an edit happened:
#      on this repo a body edit is an ordinary CONTENT act, not an authorization one — the triager holds
#      explicit shaping rights over ticket bodies (AGENTS.md, "Shaping rights"), and an agent-filed issue's
#      author IS an engineer bot, which can always edit its own body. Treating any edit as a release would
#      therefore hand both engineer bots a self-unblock route straight around rule 2's author filter.
# Anything else — a bare `ready` re-add, a `DECISION:` line from a non-authority login, a stale pre-record
# decision, a body edit by anyone but the restore authority — is INERT: it must not spend another
# implementor run re-deriving the same block.
#
# Why rule 1 is not editor-attributed: removing `implementation-blocked` is not an act any agent performs
# in the course of its normal job — no prompt or workflow touches that label except this pipeline's own
# post-release clear — so, unlike a body edit, it carries unambiguous "I am authorizing re-dispatch"
# semantics on its own, and repo write access is the boundary GitHub already enforces on it. Attributing it
# would mean walking the issue timeline and telling a maintainer's restore apart from the pipeline's own
# clear, whose failure mode (an issue that was once blocked becoming permanently undispatchable) is worse
# than what it would prevent. `implement.md` tells the implementor not to touch that label, and the record
# names label removal as a MAINTAINER action.
#
# Fail-closed direction: while the blocked-state label is present, a MISSING or untrusted-authored state
# record is inert, never dispatchable. The label is the visible state; removing it is the documented
# restore.
#
# Usage:
#   blocked-state.sh label                     # print the blocked-state label name (single source of truth)
#   blocked-state.sh record-marker             # print the state record's machine-readable BEGIN marker
#   blocked-state.sh normalize-reason <raw>    # print a machine-readable block-reason slug
#   blocked-state.sh render-record <reason> <run-url>
#   blocked-state.sh present-labels <labels-json-file> <label>...   # echo only the ones actually present
#   blocked-state.sh decide <authority-logins> <record-author> <labels-json-file> <comments-json-file> [edit-json-file]
#
# `decide` prints exactly one line, "<dispatchable|inert> <why>", to stdout and its reasoning to stderr:
#   dispatchable not-blocked | dispatchable decision-proceed | dispatchable decision-revise
#   dispatchable body-edited | inert blocked | inert no-record | inert decision-stop
# <labels-json-file> is a JSON array of label NAMES (`gh issue view --json labels --jq '[.labels[].name]'`).
# <comments-json-file> is the REST issues/<n>/comments array — REST, not GraphQL: `.user.login` there
# already carries the `<slug>[bot]` suffix for a bot comment, the identity-shape trap automated-researcher
# #625 was about.
# <edit-json-file> is the GraphQL `repository.issue` object holding the body-edit attribution —
# `{ lastEditedAt, editor { __typename, login } }`. Both halves are needed and both come from GraphQL:
# REST exposes no `lastEditedAt` at all, and a GraphQL `Bot` actor's `login` is the BARE app slug (no
# `[bot]` suffix), so `__typename` is what makes the canonical identity derivable instead of guessed —
# the same #625 identity-shape trap from the other direction. Omit the argument (or pass a file with a
# null `lastEditedAt`) when the body was never edited.
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./canonical-login.sh
source "$SELF_DIR/canonical-login.sh"

# The blocked-state label. Deliberately NOT the existing `blocked` disposition label: AGENTS.md's
# disposition contract defines `blocked` as "decided but gated on a prerequisite (blocked-by: #N)" and makes
# it researcher/triage-applied only, so reusing it would both overload the vocabulary and have an agent
# self-apply a disposition. This is a pipeline STATE label, same class as `needs-senior-engineer` /
# `needs-human`, and it leaves the disposition invariant intact (a blocked issue ends up carrying no
# disposition at all, i.e. back to the resting state, until someone re-dispositions it).
BLOCKED_LABEL="implementation-blocked"

# HTML-comment markers, so the record is machine-readable without depending on prose (same pattern as
# triage-assess.yml's assessment markers and AGENTS.md's own fenced blocks).
RECORD_BEGIN="<!-- IMPLEMENTATION-STATE:BEGIN -->"
RECORD_END="<!-- IMPLEMENTATION-STATE:END -->"

# The `app/<slug>` -> `<slug>[bot]` mapping as a jq function, for logins read out of a fetched JSON array.
# Same idiom as senior-engineer.yml / reconcile-prs.yml, and identical semantics to canonical-login.sh:
# a BARE `<slug>` is a different, untrusted identity and is left alone, so it still fails comparison.
JQ_CANON='def canon_login: if startswith("app/") then (.[4:] + "[bot]") else . end;'

die() { echo "blocked-state: $*" >&2; exit 1; }

normalize_reason() {
  # Machine-readable block-reason: lowercase kebab slug, <=64 chars, never empty. The implementor reports
  # this in its structured output, so it is model-authored text — normalize rather than trust it, and fall
  # back to `unspecified` instead of failing: routing the block matters more than the reason's precision.
  local slug
  slug=$(printf '%s' "${1-}" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9' '-' | sed -E 's/-+/-/g; s/^-//; s/-$//')
  slug=${slug:0:64}
  slug=${slug%-}
  printf '%s' "${slug:-unspecified}"
}

render_record() {
  local reason="$1" run_url="$2"
  # Fully workflow-authored (never the agent's own prose): this record is the machine-readable state other
  # automation and humans read, so its shape must be deterministic. The agent's explanation comment sits
  # immediately above it and carries the human detail.
  cat <<EOF
$RECORD_BEGIN
implementation-status: blocked
block-reason: $reason
blocked-run: $run_url
$RECORD_END

**This issue is in the blocked state** (automated-researcher#629). The implement leg ended
\`status: blocked\`, so \`ready\` was removed and \`$BLOCKED_LABEL\` applied — a stale \`ready\` label must not
imply work is still coming. The blocking run's own explanation comment (posted just before this record)
says what it could not resolve.

Re-dispatch is INERT while this state stands: re-adding \`ready\` alone will not start another implementor
run, because a fresh stateless run would re-derive the same block from the same priors — exactly what burned
four runs in the #620 incident. One of these must happen first:

- **Remove the \`$BLOCKED_LABEL\` label** (a maintainer's explicit restore), then re-add \`ready\`.
- **Record a binding decision** — a comment from the researcher or the senior-engineer adjudicator whose
  body carries a \`DECISION:\` line with verb \`PROCEED\` or \`REVISE\` (automated-researcher#632's protocol;
  \`STOP\` is honored as a decision not to re-dispatch) — then re-add \`ready\`.
- **Edit this issue's body** so the \`block-reason\` above is addressed, then re-add \`ready\`. The edit must
  be made by the researcher or the senior-engineer adjudicator — the same restore authority a
  \`DECISION:\` requires. A body edit by anyone else (the triager's shaping pass, or an engineer bot editing
  an issue it filed) is a content change, not a release, and leaves this state standing.
EOF
}

present_labels() {
  # `gh issue edit --remove-label X` is not reliably a no-op when X isn't on the issue (or isn't defined on
  # the repo at all) — it can fail the whole mutation. The routing of a block must never fail on that, or
  # the fix for a dead letter becomes a dead letter itself, so callers pass the labels they'd LIKE to
  # remove through here first and only reference the ones actually present.
  local file="$1"; shift
  [ -f "$file" ] || die "labels file not found: $file"
  local l
  for l in "$@"; do
    if jq -e --arg l "$l" 'any(.[]; . == $l)' "$file" >/dev/null; then printf '%s\n' "$l"; fi
  done
}

decide() {
  [ "$#" -ge 4 ] || die "decide needs <authority-logins> <record-author> <labels-json-file> <comments-json-file> [edit-json-file]"
  local authority="$1" record_author="$2" labels_file="$3" comments_file="$4" edit_file="${5-}"
  [ -f "$labels_file" ] || die "labels file not found: $labels_file"
  [ -f "$comments_file" ] || die "comments file not found: $comments_file"

  if ! jq -e --arg label "$BLOCKED_LABEL" 'any(.[]; . == $label)' "$labels_file" >/dev/null; then
    echo "issue does not carry '$BLOCKED_LABEL'; dispatch proceeds unchanged" >&2
    echo "dispatchable not-blocked"
    return 0
  fi

  local record_author_canon
  record_author_canon=$(canonical_login "$record_author") || die "invalid record-author login"

  # The most recent state record authored by the implement workflow's own identity. Author-filtering is
  # load-bearing on a PUBLIC repo: anyone can comment, so an unfiltered marker match would let an outsider
  # forge a later "block" record — freezing re-dispatch, or shifting the transition cutoff so a real
  # decision no longer counts.
  local record_ts
  record_ts=$(jq -r --arg author "$record_author_canon" --arg begin "$RECORD_BEGIN" "$JQ_CANON"'
    [ .[] | select((((.user.login // "") | canon_login) == $author) and ((.body // "") | contains($begin))) ]
    | sort_by(.created_at) | last | if . == null then "" else .created_at end
  ' "$comments_file")

  if [ -z "$record_ts" ]; then
    echo "'$BLOCKED_LABEL' is present but no $record_author_canon-authored state record was found; failing closed (remove the label to restore dispatchability)" >&2
    echo "inert no-record"
    return 0
  fi

  local canon_authority=()
  local a
  for a in $authority; do canon_authority+=("$(canonical_login "$a")"); done
  local authority_json
  authority_json=$(printf '%s\n' "${canon_authority[@]+"${canon_authority[@]}"}" \
    | jq -Rsc 'split("\n") | map(select(length > 0))')

  # Latest restore-authority DECISION verb strictly after the record. Anchored at line start (leading
  # whitespace allowed) so a prose mention of the protocol mid-sentence is not a decision; within one body
  # the LAST such line wins, and across bodies the latest comment wins.
  local decision_line decision_ts decision_verb
  # `$login` is bound BEFORE the `index()` call: inside `index(...)` the input `.` is the authority array,
  # not the comment, so evaluating `.user.login` in there would index the wrong value.
  decision_line=$(jq -r --argjson auth "$authority_json" --arg cutoff "$record_ts" "$JQ_CANON"'
    [ .[]
      | . as $c
      | (($c.user.login // "") | canon_login) as $login
      | select(($auth | index($login)) != null)
      | select($c.created_at > $cutoff)
      | { ts: $c.created_at,
          verb: ( (($c.body // "") | split("\n")
                   | map(select(test("^[[:space:]]*DECISION:[[:space:]]*(PROCEED|REVISE|STOP)([[:space:]]|$)")))
                   | last // "")
                  | [ scan("DECISION:[[:space:]]*(PROCEED|REVISE|STOP)") ] | last
                  | if . == null then "" else .[0] end ) }
      | select(.verb != "")
    ] | sort_by(.ts) | last | if . == null then "" else .ts + " " + .verb end
  ' "$comments_file")
  decision_ts=""
  decision_verb=""
  if [ -n "$decision_line" ]; then
    decision_ts="${decision_line%% *}"
    decision_verb="${decision_line##* }"
  fi

  # A body edit counts only if it happened after the record AND the restore authority is the one who made
  # it. GitHub timestamps are same-format ISO-8601 UTC, so a lexicographic comparison is a valid time
  # comparison (same idiom as senior-engineer.yml). An edit that fails EITHER test is discarded outright
  # rather than downgraded: an unattributable or unauthorized edit must not release the block, and it must
  # not supersede an earlier authority decision in the latest-wins comparison below either — it is not the
  # authority's act, so it can neither grant nor revoke.
  local edit_ts="" edit_note="none"
  if [ -n "$edit_file" ]; then
    [ -f "$edit_file" ] || die "edit-state file not found: $edit_file"
    local raw_edit_ts raw_editor
    raw_edit_ts=$(jq -r '.lastEditedAt // "" | tostring' "$edit_file")
    # `Bot` -> `<slug>[bot]`; every other actor type keeps its login verbatim. A null/absent editor (a
    # deleted account, or a field the caller failed to request) yields "", which is unattributable.
    raw_editor=$(jq -r '
      if (.editor // null) == null or ((.editor.login // "") | tostring) == "" then ""
      elif .editor.__typename == "Bot" then (.editor.login + "[bot]")
      else (.editor.login | tostring) end
    ' "$edit_file")
    if [ -n "$raw_edit_ts" ] && [ "$raw_edit_ts" != "null" ] && [[ "$raw_edit_ts" > "$record_ts" ]]; then
      if [ -z "$raw_editor" ]; then
        edit_note="$raw_edit_ts by an unidentifiable editor (DISCARDED — attribution is required)"
      else
        local editor_canon
        editor_canon=$(canonical_login "$raw_editor") || die "invalid body editor login"
        if jq -e -n --argjson auth "$authority_json" --arg l "$editor_canon" '($auth | index($l)) != null' >/dev/null; then
          edit_ts="$raw_edit_ts"
          edit_note="$raw_edit_ts by $editor_canon"
        else
          edit_note="$raw_edit_ts by non-authority '$editor_canon' (DISCARDED — a body edit is a content act, not an authorization one)"
        fi
      fi
    fi
  fi

  echo "state record at $record_ts; latest authority decision: ${decision_line:-none}; body edit after record: $edit_note" >&2

  # Whichever material signal is LATEST decides — so a `STOP` vetoes an earlier `PROCEED`, and a later body
  # edit (or a later decision) supersedes a `STOP`.
  if [ -n "$decision_ts" ] && { [ -z "$edit_ts" ] || [[ "$decision_ts" > "$edit_ts" ]]; }; then
    case "$decision_verb" in
      PROCEED) echo "dispatchable decision-proceed" ;;
      REVISE) echo "dispatchable decision-revise" ;;
      STOP) echo "inert decision-stop" ;;
      *) die "unrecognized decision verb '$decision_verb'" ;;
    esac
    return 0
  fi
  if [ -n "$edit_ts" ]; then
    echo "dispatchable body-edited"
    return 0
  fi
  echo "inert blocked"
}

case "${1-}" in
  label) printf '%s' "$BLOCKED_LABEL" ;;
  record-marker) printf '%s' "$RECORD_BEGIN" ;;
  normalize-reason) shift; normalize_reason "${1-}" ;;
  render-record)
    shift
    [ "$#" -eq 2 ] || die "render-record needs <reason> <run-url>"
    render_record "$1" "$2"
    ;;
  present-labels)
    shift
    [ "$#" -ge 2 ] || die "present-labels needs <labels-json-file> <label>..."
    present_labels "$@"
    ;;
  decide) shift; decide "$@" ;;
  *) die "usage: blocked-state.sh label|record-marker|normalize-reason|render-record|decide ..." ;;
esac
