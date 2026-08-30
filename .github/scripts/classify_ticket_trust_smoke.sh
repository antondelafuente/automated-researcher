#!/usr/bin/env bash
# classify_ticket_trust_smoke.sh — offline behavior smoke for classify-ticket-trust.sh
# (automated-researcher#625).
#
# Exercises the actual gh/GraphQL-vs-REST identity shapes this bug was about, as inputs a caller could
# plausibly hand the script: `app/<slug>` (GraphQL issue-author form), `<slug>[bot]` (REST comment-author
# form, and the event-payload form), and a bare `<slug>` (the GraphQL comment-author form that caused
# #625 — a same-named untrusted user must classify identically to this).
#
# Cases 8+ additionally cover automated-researcher#797, whose bug was in the CALLER rather than in this
# script: triage-assess.yml's gather step derived a comment login the ticket did not have. Those cases
# extract that step's real jq program from the workflow and drive it here, since no amount of unit-testing
# this script could have caught a caller handing it a fabricated argument.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SELF_DIR/classify-ticket-trust.sh"
[ -f "$SCRIPT" ] || { echo "FAIL: classify-ticket-trust.sh not found next to smoke" >&2; exit 1; }

ALLOWLIST="antondelafuente claude-code-engineer[bot] codex-engineer[bot]"

FAILS=0
pass() { echo "  ok: $1"; }
fail() { echo "  FAIL: $1" >&2; FAILS=$((FAILS+1)); }

assert_trust() {
  local desc="$1" expected="$2" author="$3"; shift 3
  local got
  got=$("$SCRIPT" "$ALLOWLIST" "$author" "$@" 2>/dev/null)
  if [ "$got" = "$expected" ]; then pass "$desc -> $got"
  else fail "$desc -> $got, expected $expected"; fi
}

echo "[smoke] case 1: GraphQL issue author (app/<slug>) + REST comment authors (<slug>[bot]) -> trusted"
assert_trust "app/claude-code-engineer author, codex-engineer[bot]+claude-code-engineer[bot] comments" \
  true "app/claude-code-engineer" "codex-engineer[bot]" "claude-code-engineer[bot]"

echo "[smoke] case 2: the #625 regression itself — a bare-slug comment author (the GraphQL comments bug) must NOT be trusted"
assert_trust "app/claude-code-engineer author, bare 'codex-engineer' comment (GraphQL bug shape)" \
  false "app/claude-code-engineer" "codex-engineer"

echo "[smoke] case 3: same-named plain user impersonating the bot via a bare login -> stays untrusted"
assert_trust "app/claude-code-engineer author, bare 'claude-code-engineer' comment" \
  false "app/claude-code-engineer" "claude-code-engineer"

echo "[smoke] case 4: researcher author (plain username) + no comments -> trusted"
assert_trust "antondelafuente author, no comments" \
  true "antondelafuente"

echo "[smoke] case 5: any other commenter forces the untrusted path"
assert_trust "app/codex-engineer author, outside commenter" \
  false "app/codex-engineer" "some-random-user"

echo "[smoke] case 6: a null/deleted comment author (jq -r's 'null' rendering) forces the untrusted path"
assert_trust "app/claude-code-engineer author, literal 'null' comment login" \
  false "app/claude-code-engineer" "null"

echo "[smoke] case 7: event-payload form (<slug>[bot]) as the ISSUE author, mixed with REST comment form -> trusted"
assert_trust "claude-code-engineer[bot] author, codex-engineer[bot] comment" \
  true "claude-code-engineer[bot]" "codex-engineer[bot]"

# --- automated-researcher#797: the CALLER's comment-login extraction, driven exactly as the workflow runs it ---
# Case 4 above already proves the script trusts an allowlisted author with zero comment logins, and it
# passed throughout — the #797 bug was never in this script. It was in triage-assess.yml's gather step,
# which handed the script a comment login the ticket did not have: `jq -r '.[].user.login // "null"'`
# applies `//` to the whole OUTPUT STREAM, and jq's `//` yields its right side when the left produces no
# outputs, so a zero-comment ticket (`[]`) emitted one literal `null` login. Since tickets are triaged on
# `opened`, before anyone has commented, that forced EVERY fresh ticket down the capability-reduced path
# (12/12 of the runs surveyed on #797) — fail-closed, so nothing unsafe happened, but the adjudicator's
# file-footprint / wave-batching check silently never ran. A unit test of this script alone cannot catch
# that, so extract the workflow line's ACTUAL jq program from triage-assess.yml and drive fixtures through
# it: a revert to the stream form fails here rather than silently degrading every triage again.
REPO_ROOT="$(cd "$SELF_DIR/../.." && pwd)"
WORKFLOW="$REPO_ROOT/.github/workflows/triage-assess.yml"
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq not available — cannot verify the #797 extraction" >&2; exit 1; }
[ -f "$WORKFLOW" ] || { echo "FAIL: triage-assess.yml not found at $WORKFLOW" >&2; exit 1; }

extract_line=$(grep -F "mapfile -t comment_logins < <(jq -r " "$WORKFLOW" | head -1)
JQ_PROG=${extract_line#*jq -r \'}
JQ_PROG=${JQ_PROG%\'*}
if [ -z "$JQ_PROG" ]; then
  echo "FAIL: could not extract the comment-login jq program from $WORKFLOW" >&2; exit 1
fi
echo "[smoke] extracted comment-login jq program from triage-assess.yml: $JQ_PROG"

# Space-joined so an EMPTY result (the zero-comment case) is assertable as the empty string.
assert_logins() {
  local desc="$1" expected="$2" fixture="$3"
  local got
  got=$(printf '%s' "$fixture" | jq -r "$JQ_PROG" | tr '\n' ' ')
  got="${got% }"
  if [ "$got" = "$expected" ]; then pass "$desc -> [$got]"
  else fail "$desc -> [$got], expected [$expected]"; fi
}

# End-to-end through the same `mapfile` the workflow uses, so the empty-array argv shape is exercised too.
assert_trust_from_comments_json() {
  local desc="$1" expected="$2" author="$3" fixture="$4"
  local got
  local logins=()
  mapfile -t logins < <(printf '%s' "$fixture" | jq -r "$JQ_PROG")
  got=$("$SCRIPT" "$ALLOWLIST" "$author" "${logins[@]}" 2>/dev/null)
  if [ "$got" = "$expected" ]; then pass "$desc -> $got"
  else fail "$desc -> $got, expected $expected"; fi
}

echo "[smoke] case 8: the #797 regression — a zero-comment ticket must yield NO comment logins, not a literal 'null'"
assert_logins "empty comments array" "" '[]'

echo "[smoke] case 9: real comment authors still come through, in order"
assert_logins "two REST comment authors" "codex-engineer[bot] antondelafuente" \
  '[{"user":{"login":"codex-engineer[bot]"}},{"user":{"login":"antondelafuente"}}]'

echo "[smoke] case 10: the 'null' sentinel is still emitted PER COMMENT for a missing/deleted comment author"
assert_logins "one null-user comment among two" "null antondelafuente" \
  '[{"user":null},{"user":{"login":"antondelafuente"}}]'

echo "[smoke] case 11: end-to-end — allowlisted author + zero comments ⇒ trusted (the capability-reduction bug)"
assert_trust_from_comments_json "antondelafuente author, zero comments" true "antondelafuente" '[]'
assert_trust_from_comments_json "app/claude-code-engineer author, zero comments" true "app/claude-code-engineer" '[]'

echo "[smoke] case 12: end-to-end — a deleted comment author still forces the untrusted path (fail-closed intact)"
assert_trust_from_comments_json "antondelafuente author, null-user comment" false "antondelafuente" '[{"user":null}]'

echo "[smoke] case 13: end-to-end — a non-allowlisted commenter still forces the untrusted path"
assert_trust_from_comments_json "antondelafuente author, outside commenter" false "antondelafuente" \
  '[{"user":{"login":"some-random-user"}}]'

if [ "$FAILS" -eq 0 ]; then echo "[smoke] classify-ticket-trust: ALL PASS"; exit 0; else
  echo "[smoke] classify-ticket-trust: $FAILS FAILURE(S)" >&2; exit 1; fi
