#!/usr/bin/env bash
# reconcile_prs_smoke.sh — offline behavior smoke for reconcile-prs.yml's stranded-rejected-review leg
# (automated-researcher#824; the leg itself is #515, its retry counter #516, its round budget #502/#438).
#
# The case this exists for: `handle_stranded_rejected` used to escalate to `needs-senior-engineer` on
# `round >= REVIEW_ADDRESS_LIMIT` BEFORE it looked at whether an addressing dispatch was still in flight, so
# every ~10-minute tick past the limit re-labelled a PR whose implementor was actively working. Observed
# twice on 2026-09-02 — PR #820 at 04:48 UTC (the run pushed 5f778e1c at 04:48:44) and PR #823 at 06:58 UTC
# (pushed 282dd9fd at 06:59) — each time summoning a second senior-engineer run whose 2-round guard then
# bounced the PR to `needs-human`, a label a human had to clear by hand for work that was never stranded.
#
# Ordering is branch behavior a static grep cannot prove, so this smoke extracts the reconcile step's REAL
# run body out of the workflow (same idiom as blocked_state_smoke.sh's group E), truncates it just before
# the PR-enumeration loop so sourcing it only defines the constants and handlers, and drives
# handle_stranded_rejected against a stubbed `gh`. The mutation test at the end drops the in-flight early
# return and asserts the headline case flips, so the case is proven load-bearing rather than incidentally
# green. Fully offline: no network, no real gh, no tokens.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SELF_DIR/../.." && pwd)"
WORKFLOW="$REPO_ROOT/.github/workflows/reconcile-prs.yml"
[ -f "$WORKFLOW" ] || { echo "FAIL: reconcile-prs.yml not found at $WORKFLOW" >&2; exit 1; }

FAILS=0
pass() { echo "  ok: $1"; }
fail() { echo "  FAIL: $1" >&2; FAILS=$((FAILS+1)); }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# ---------------------------------------------------------------------------------------------------
# Extract the reconcile step's run body, truncated before the PR-enumeration loop: everything above that
# line is constants + handler definitions, which is exactly what this smoke wants to source.
extract_prefix() {
  python3 - "$WORKFLOW" <<'PY'
import sys

lines = open(sys.argv[1]).read().splitlines()
start = next(i for i, l in enumerate(lines) if l.strip() == "- name: Reconcile open bot PRs")
run = next(i for i in range(start, len(lines)) if lines[i].strip() == "run: |")
indent = len(lines[run + 1]) - len(lines[run + 1].lstrip())
body = []
for l in lines[run + 1:]:
    if l.strip() and len(l) - len(l.lstrip()) < indent:
        break
    body.append(l[indent:] if l.strip() else "")
cut = next(i for i, l in enumerate(body) if l.startswith("if ! numbers_output="))
sys.stdout.write("\n".join(body[:cut]) + "\n")
PY
}

PREFIX="$TMP/reconcile_prefix.sh"
if ! extract_prefix > "$PREFIX" 2>"$TMP/extract.err"; then
  fail "could not extract the reconcile step's run body ($(tr '\n' ' ' < "$TMP/extract.err"))"
  echo "[smoke] reconcile-prs: $FAILS FAILURE(S)" >&2
  exit 1
fi
if ! grep -q '^handle_stranded_rejected()' "$PREFIX"; then
  fail "the extracted prefix does not define handle_stranded_rejected — extraction is out of date"
  echo "[smoke] reconcile-prs: $FAILS FAILURE(S)" >&2
  exit 1
fi
pass "extracted the reconcile step's constants + handlers ($(wc -l < "$PREFIX") lines)"

# ---------------------------------------------------------------------------------------------------
# `gh` stub: logs every invocation, and answers the one read this handler makes (the issue-comment fetch)
# from a fixture. Mutations (`gh pr comment` / `gh pr edit`) are recorded, never performed.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'SH'
#!/usr/bin/env bash
echo "$*" >> "$GH_CALL_LOG"
case "${1:-}" in
  api) cat "$STUB_COMMENTS" ;;
esac
exit 0
SH
chmod +x "$TMP/bin/gh"

HEAD_SHA=1234abcd5678ef901234abcd5678ef901234abcd
NOW_EPOCH=$(date -u +%s)
iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }
# The rejected review sits a day back, so every mention fixture below (specified as "seconds ago") is
# unambiguously AFTER it and only the author allowlist + the grace window decide the outcome. A fixed
# wall-clock timestamp here would silently drop the older mentions depending on the time of day the smoke
# runs, which is exactly the kind of clock coupling that makes a smoke flaky.
REVIEW_AT=$(iso $(( NOW_EPOCH - 24 * 60 * 60 )))

# review_info <file> <consecutive CHANGES_REQUESTED rounds>: the `{at_head, all}` packet handle_mergeable
# passes in. An APPROVED review sits in front of the run so the trailing-run reduce is exercised, not just
# a raw length.
review_info() {
  jq -n --arg at "$REVIEW_AT" --argjson n "$2" '
    { at_head: { submitted_at: $at, state: "CHANGES_REQUESTED" },
      all: ([{ submitted_at: "2026-09-01T00:00:00Z", state: "APPROVED" }]
            + [range($n) | { submitted_at: ("2026-09-02T0" + (. | tostring) + ":00:00Z"), state: "CHANGES_REQUESTED" }]) }' > "$1"
}

# comments <file> [<login>:<seconds-ago>]... : an allowlisted dispatch mention posted N seconds ago. Every
# entry lands after the review above, so `created_at >= $since` is satisfied and only the author allowlist
# and the grace window decide.
comments() {
  local out="$1"; shift
  local items=()
  for spec in "$@"; do
    local login="${spec%%:*}" ago="${spec##*:}" ts
    ts=$(iso $(( NOW_EPOCH - ago )))
    items+=("$(jq -nc --arg l "$login" --arg t "$ts" \
      '{user: {login: $l}, created_at: $t, body: "Review loop: auto-dispatch. @claude-code-engineer please address the findings and push."}')")
  done
  if [ "${#items[@]}" -eq 0 ]; then echo '[]' > "$out"
  else printf '%s\n' "${items[@]}" | jq -s '.' > "$out"; fi
}

# run_case <handler-source> <review_info file> <comments file> -> writes the gh call log, echoes stdout.
run_case() {
  local prefix="$1" info="$2" cmts="$3"
  : > "$TMP/gh_calls.log"
  {
    cat "$prefix"
    echo 'if ! handle_stranded_rejected "$PR_N" "$HEAD_SHA" "$(cat "$REVIEW_INFO")"; then echo "HANDLER-NONZERO"; fi'
  } > "$TMP/harness.sh"
  ( cd "$REPO_ROOT" && PATH="$TMP/bin:$PATH" \
      GITHUB_WORKSPACE="$REPO_ROOT" GH_TOKEN=stub REPO=antondelafuente/automated-researcher \
      RECONCILER_ACTIONS_TOKEN=stub GH_CALL_LOG="$TMP/gh_calls.log" STUB_COMMENTS="$cmts" \
      PR_N=823 HEAD_SHA="$HEAD_SHA" REVIEW_INFO="$info" \
      bash "$TMP/harness.sh" ) 2>&1
}

# assert_case <desc> <expect: escalate|dispatch|quiet> <rounds> [<comment spec>...]
assert_case() {
  local desc="$1" expect="$2" rounds="$3"; shift 3
  local info="$TMP/info.json" cmts="$TMP/comments.json" out
  review_info "$info" "$rounds"
  comments "$cmts" "$@"
  out=$(run_case "$PREFIX" "$info" "$cmts")
  assert_effect "$desc" "$expect" "$out"
}

# The observable effect of one handler call, read off the recorded gh calls.
assert_effect() {
  local desc="$1" expect="$2" out="$3"
  local labelled=0 commented=0
  grep -q -- "--add-label needs-senior-engineer" "$TMP/gh_calls.log" && labelled=1
  grep -q "^pr comment" "$TMP/gh_calls.log" && commented=1
  local got
  if [ "$labelled" = 1 ]; then got=escalate
  elif [ "$commented" = 1 ]; then got=dispatch
  else got=quiet; fi
  if [ "$got" = "$expect" ]; then
    pass "$desc -> $got"
  else
    fail "$desc -> $got, expected $expect (gh calls: $(tr '\n' ';' < "$TMP/gh_calls.log") | output: $(printf '%s' "$out" | tr '\n' ' '))"
  fi
}

echo "[smoke] group A: an in-flight addressing dispatch is never escalated over (#824)"

# The headline case from the issue: rejected review at head, round past the limit, dispatch mention 60s old.
assert_case "round 4/3 with an allowlisted dispatch mention 60s old -> no label, no comment" \
  quiet 4 "antondelafuente:60"
assert_case "round 4/3, senior-engineer's own dispatch mention 60s old -> no label, no comment" \
  quiet 4 "app/senior-engineer-agent:60"
assert_case "round 3/3 (exactly at the limit) with a mention 60s old -> no label, no comment" \
  quiet 3 "codex-engineer[bot]:60"

echo "[smoke] group B: the round-limit escalation still fires when nothing is in flight"

assert_case "round 4/3 with no dispatch mention at all -> escalate" escalate 4
assert_case "round 4/3 with a mention older than the grace window (a dead run) -> escalate" \
  escalate 4 "antondelafuente:$((3 * 60 * 60))"
# The allowlist is what makes a mention evidence of a DISPATCH: address-review.yml ignores a mention from
# the claude engineer bot itself, so one must not buy in-flight credit here either.
assert_case "round 4/3 with a 60s-old mention from a NON-allowlisted author -> escalate" \
  escalate 4 "claude-code-engineer[bot]:60"

echo "[smoke] group C: below the limit, the leg's pre-existing behavior is unchanged"

assert_case "round 2/3 with no dispatch mention -> auto-dispatch, no label" dispatch 2
assert_case "round 2/3 with a mention 60s old -> still in flight, no label, no comment" \
  quiet 2 "antondelafuente:60"
assert_case "round 2/3 with one stale mention (the addressing run died) -> re-dispatch the same round" \
  dispatch 2 "antondelafuente:$((3 * 60 * 60))"
assert_case "round 2/3 with 3 stale mentions (retry budget exhausted, #516) -> escalate" \
  escalate 2 "antondelafuente:$((5 * 60 * 60))" "antondelafuente:$((4 * 60 * 60))" "antondelafuente:$((3 * 60 * 60))"

echo "[smoke] group D: mutation — the in-flight early return is what produces group A"

MUTANT="$TMP/reconcile_prefix_mutant.sh"
# Drop only the `return` that follows the stranded-rejected in-flight log line, leaving the check itself in
# place: execution then falls through to the round-limit branch exactly as it did before #824.
sed '/against the rejected review at head/{n;s/^\([[:space:]]*\)return$/\1: # mutated: in-flight no longer short-circuits/;}' \
  "$PREFIX" > "$MUTANT"
if ! grep -qF 'mutated: in-flight no longer short-circuits' "$MUTANT"; then
  fail "mutation could not drop the in-flight early return — this smoke is not testing what it claims"
else
  review_info "$TMP/info.json" 4
  comments "$TMP/comments.json" "antondelafuente:60"
  mut_out=$(run_case "$MUTANT" "$TMP/info.json" "$TMP/comments.json")
  assert_effect "mutation: round 4/3 with a 60s-old mention falls through to the round-limit branch" \
    escalate "$mut_out"
fi

if [ "$FAILS" -eq 0 ]; then echo "[smoke] reconcile-prs: ALL PASS"; exit 0; else
  echo "[smoke] reconcile-prs: $FAILS FAILURE(S)" >&2; exit 1; fi
