#!/usr/bin/env bash
# classify_ticket_trust_smoke.sh — offline behavior smoke for classify-ticket-trust.sh
# (automated-researcher#625).
#
# Exercises the actual gh/GraphQL-vs-REST identity shapes this bug was about, as inputs a caller could
# plausibly hand the script: `app/<slug>` (GraphQL issue-author form), `<slug>[bot]` (REST comment-author
# form, and the event-payload form), and a bare `<slug>` (the GraphQL comment-author form that caused
# #625 — a same-named untrusted user must classify identically to this).
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

if [ "$FAILS" -eq 0 ]; then echo "[smoke] classify-ticket-trust: ALL PASS"; exit 0; else
  echo "[smoke] classify-ticket-trust: $FAILS FAILURE(S)" >&2; exit 1; fi
