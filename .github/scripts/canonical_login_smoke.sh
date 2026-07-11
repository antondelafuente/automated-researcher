#!/usr/bin/env bash
# canonical_login_smoke.sh — offline behavior smoke for canonical-login.sh (automated-researcher#381).
#
# Two things a JSON/syntax check can't cover:
#   1. canonical_login() maps exactly the two GitHub-observed App-identity representations to the same
#      canonical form, and does NOT collapse a bare (untrusted) slug into matching the App.
#   2. the workflow actually sources the helper AFTER checkout (helper reachability from the real
#      workflow step, not just unit correctness of the function in isolation — #382 design-review F1/F3).
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER="$SELF_DIR/canonical-login.sh"
[ -f "$HELPER" ] || { echo "FAIL: canonical-login.sh not found next to smoke" >&2; exit 1; }
# shellcheck source=/dev/null
source "$HELPER"

FAILS=0
pass() { echo "  ok: $1"; }
fail() { echo "  FAIL: $1" >&2; FAILS=$((FAILS+1)); }

assert_eq() {
  local input="$1" expected="$2" got
  got=$(canonical_login "$input")
  if [ "$got" = "$expected" ]; then pass "canonical_login('$input') = '$got'"
  else fail "canonical_login('$input') = '$got', expected '$expected'"; fi
}

echo "[smoke] case 1: app/<slug> -> <slug>[bot] (CLI/GraphQL form canonicalizes)"
assert_eq "app/claude-code-engineer" "claude-code-engineer[bot]"
assert_eq "app/codex-engineer" "codex-engineer[bot]"

echo "[smoke] case 2: <slug>[bot] -> unchanged (already canonical, event-payload form)"
assert_eq "claude-code-engineer[bot]" "claude-code-engineer[bot]"
assert_eq "codex-engineer[bot]" "codex-engineer[bot]"

echo "[smoke] case 3: plain researcher username -> unchanged"
assert_eq "antondelafuente" "antondelafuente"

echo "[smoke] case 4: bare slug (no prefix/suffix) -> unchanged, so it does NOT match the App's canonical form"
got=$(canonical_login "claude-code-engineer")
if [ "$got" != "claude-code-engineer[bot]" ]; then
  pass "bare slug 'claude-code-engineer' stays '$got' (does not collapse into the App identity)"
else
  fail "bare slug was canonicalized to match the App identity — trust-boundary regression"
fi

echo "[smoke] case 5: unrelated garbage -> unchanged, still fails any allowlist comparison"
assert_eq "some-random-value" "some-random-value"

# --- static reachability check: the helper must be sourced AFTER checkout, from the workflow that needs it ---
REPO_ROOT="$(cd "$SELF_DIR/../.." && pwd)"
WORKFLOW="$REPO_ROOT/.github/workflows/implement-on-ready.yml"
if [ -f "$WORKFLOW" ]; then
  echo "[smoke] case 6: implement-on-ready.yml sources canonical-login.sh AFTER checkout"
  checkout_line=$(grep -n "name: Checkout base branch" "$WORKFLOW" | head -1 | cut -d: -f1)
  source_line=$(grep -n "canonical-login\.sh" "$WORKFLOW" | head -1 | cut -d: -f1)
  if [ -z "$checkout_line" ] || [ -z "$source_line" ]; then
    fail "could not locate both the checkout step and the canonical-login.sh source line in $WORKFLOW"
  elif [ "$source_line" -gt "$checkout_line" ]; then
    pass "canonical-login.sh is sourced (line $source_line) after checkout (line $checkout_line)"
  else
    fail "canonical-login.sh is sourced (line $source_line) BEFORE checkout (line $checkout_line) — file would not exist yet"
  fi
else
  fail "implement-on-ready.yml not found at $WORKFLOW"
fi

if [ "$FAILS" -eq 0 ]; then echo "[smoke] canonical-login: ALL PASS"; exit 0; else
  echo "[smoke] canonical-login: $FAILS FAILURE(S)" >&2; exit 1; fi
