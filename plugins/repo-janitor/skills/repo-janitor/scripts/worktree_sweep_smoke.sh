#!/usr/bin/env bash
# Smoke for worktree_sweep.py (automated-researcher#364). Runs OFFLINE against real, local git fixture
# repos (no GitHub, no network) — worktree/status/merge-base behavior is exactly git's own, so faking it
# would just re-implement git badly. Covers:
#   - tier 1: merged+clean+old -> reaped by --reap-tier1; a prunable (working dir gone) entry -> pruned
#   - tier 2: stray content under a LIVE owner (the REPO_JANITOR_LIVE_SESSIONS_CMD seam)
#   - tier 3: the same stray content with NO live owner (seam unset -> fail-safe default), a stale
#     unmerged branch with no owner, and shared-checkout drift (dirty; behind origin only surfaces with
#     --fetch, never silently from a cached ref)
#   - the live-owner tier-1 VETO (design-review Finding 2): merged+clean+old is tier 2, not tier 1, when
#     its owner reads as live
#   - fail-closed UNKNOWN (Finding 4): a corrupted worktree (unreadable status) never reaches tier 1
#   - silent cases: unmerged-but-fresh, merged-clean-but-fresh — appear in neither tier
#   - --reap-tier1 --dry-run deletes nothing; --reap-tier1 deletes ONLY tier-1 entries
#   - --json shape, and CLI argument validation (missing --repo, --dry-run without --reap-tier1, bad depth)
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
SWEEP="$HERE/worktree_sweep.py"
[ -f "$SWEEP" ] || { echo "FAIL: missing $SWEEP"; exit 1; }

TMP=$(mktemp -d) || { echo "FAIL: mktemp"; exit 1; }
trap 'rm -rf "$TMP"' EXIT

fails=0
ok(){ echo "ok   $1"; }
no(){ echo "FAIL $1"; fails=1; }

OLD_DATE=$(date -u -d '-40 days' +%Y-%m-%dT%H:%M:%S 2>/dev/null || echo "2026-01-01T00:00:00")
FRESH_DATE=$(date -u -d '-1 days' +%Y-%m-%dT%H:%M:%S 2>/dev/null || echo "2026-07-09T00:00:00")

g(){ git -C "$1" "${@:2}" >/dev/null 2>&1; }

# has_path_in <tier-python-expr-over-d> <path>: reads the JSON report on STDIN (never embedded as a
# shell/python string literal — a path or reason containing a quote would otherwise corrupt the check).
has_path_in(){
  local expr=$1 path=$2
  python3 -c "
import json, sys
d = json.load(sys.stdin)
tier = $expr
paths = [e['path'] for e in (tier if isinstance(tier, list) else [x for v in tier.values() for x in v])]
sys.exit(0 if '$path' in paths else 1)
"
}

# reason_contains_for <tier-python-expr-over-d> <path> <substring>: same stdin-piped discipline.
reason_has(){
  local expr=$1 path=$2 needle=$3
  python3 -c "
import json, sys
d = json.load(sys.stdin)
tier = $expr
entries = tier if isinstance(tier, list) else [x for v in tier.values() for x in v]
matches = [e for e in entries if e['path'] == '$path']
sys.exit(0 if matches and '$needle' in matches[0]['reason'] else 1)
"
}

all_paths(){ # all entry paths across all three tiers, one per line
  python3 -c "
import json, sys
d = json.load(sys.stdin)
paths = [e['path'] for e in d['tier1']] + [e['path'] for v in d['tier2'].values() for e in v] + [e['path'] for e in d['tier3']]
print('\n'.join(paths))
"
}

# --- build the fixture: one repo + origin remote + several worktrees in every state we classify ---
REPO="$TMP/repo"; ORIGIN="$TMP/origin.git"
git init -q --bare "$ORIGIN"
git init -q -b main "$REPO"
g "$REPO" config user.email t@example.com
g "$REPO" config user.name "smoke"
echo hello > "$REPO/f.txt"; g "$REPO" add f.txt; g "$REPO" commit -q -m init
g "$REPO" remote add origin "$ORIGIN"
g "$REPO" push -q origin main
g "$REPO" branch --set-upstream-to=origin/main main

WS="$TMP/ws"; mkdir -p "$WS"

# tier-1 candidate: merged, clean, old
g "$REPO" worktree add -q -b feat-merged "$TMP/wt-merged" main
GIT_COMMITTER_DATE="$OLD_DATE" git -C "$TMP/wt-merged" commit -q --allow-empty -m old --date="$OLD_DATE"
g "$REPO" merge -q --no-edit feat-merged
g "$REPO" push -q origin main

# tier-3 candidate: unmerged, old, no owner
g "$REPO" worktree add -q -b stale-unmerged "$TMP/wt-stale" main
GIT_COMMITTER_DATE="$OLD_DATE" git -C "$TMP/wt-stale" commit -q --allow-empty -m stale --date="$OLD_DATE"

# silent: unmerged, fresh (in-progress work)
g "$REPO" worktree add -q -b wip-fresh "$TMP/wt-wip" main
GIT_COMMITTER_DATE="$FRESH_DATE" git -C "$TMP/wt-wip" commit -q --allow-empty -m wip --date="$FRESH_DATE"

# silent: merged, clean, fresh (just landed, inside the grace window)
g "$REPO" worktree add -q -b feat-fresh-merged "$TMP/wt-fresh-merged" main
GIT_COMMITTER_DATE="$FRESH_DATE" git -C "$TMP/wt-fresh-merged" commit -q --allow-empty -m freshmerge --date="$FRESH_DATE"
g "$REPO" merge -q --no-edit feat-fresh-merged
g "$REPO" push -q origin main

# tier-2/3 candidate: stray content under an owner path
g "$REPO" worktree add -q -b owner-stray "$WS/agent-a" main
echo scratch > "$WS/agent-a/TEMP.md"

# tier-2 veto candidate: merged+clean+old, but lives under an owner path
g "$REPO" worktree add -q -b owner-idle-home "$WS/agent-b" main
GIT_COMMITTER_DATE="$OLD_DATE" git -C "$WS/agent-b" commit -q --allow-empty -m home --date="$OLD_DATE"
g "$REPO" merge -q --no-edit owner-idle-home
g "$REPO" push -q origin main

# fail-closed candidate: corrupt the .git pointer so status/log fail
g "$REPO" worktree add -q -b broken "$TMP/wt-broken" main
echo "not a gitdir" > "$TMP/wt-broken/.git"

# prunable candidate: remove the working dir by hand (never `git worktree remove`)
g "$REPO" worktree add -q -b prunable-branch "$TMP/wt-prunable" main
rm -rf "$TMP/wt-prunable"

# tier-1 candidate that will be LOCKED (code-review Finding 5: a genuine remove failure must be counted
# and must exit non-zero, distinct from a defensive skip)
g "$REPO" worktree add -q -b feat-merged-locked "$TMP/wt-merged-locked" main
GIT_COMMITTER_DATE="$OLD_DATE" git -C "$TMP/wt-merged-locked" commit -q --allow-empty -m lockedold --date="$OLD_DATE"
g "$REPO" merge -q --no-edit feat-merged-locked
g "$REPO" push -q origin main
g "$REPO" worktree lock "$TMP/wt-merged-locked"

# shared-checkout drift: dirty the main checkout
echo dirty >> "$REPO/f.txt"

LIVE_FILE="$TMP/live.txt"
printf 'agent-b\n' > "$LIVE_FILE"   # only agent-b is "live"; agent-a is NOT

# =================================================================================================
# 1. Base classification (no live-sessions seam wired -> everything reads as not-live)
J1=$(python3 "$SWEEP" --json --repo "$REPO" --worktree-root "$WS" 2>/dev/null)

if echo "$J1" | has_path_in "d['tier1']" "$TMP/wt-merged"; then ok "tier1: merged+clean+old"; else no "tier1: merged+clean+old NOT classified"; fi
if echo "$J1" | has_path_in "d['tier3']" "$TMP/wt-stale"; then ok "tier3: unmerged+old+no-owner"; else no "tier3: stale-unmerged missing"; fi
if echo "$J1" | has_path_in "d['tier3']" "$WS/agent-a"; then ok "tier3: stray content, owner NOT live (no seam wired -> fail-safe)"; else no "tier3: agent-a (no seam) missing"; fi
if echo "$J1" | has_path_in "d['tier1']" "$TMP/wt-prunable"; then ok "tier1: prunable"; else no "tier1: prunable missing"; fi
if echo "$J1" | has_path_in "d['tier3']" "$TMP/wt-broken"; then ok "tier3: UNKNOWN fact (broken worktree) fails closed, not silently safe"; else no "tier3: broken worktree missing"; fi
if echo "$J1" | has_path_in "d['tier1']" "$TMP/wt-broken"; then no "UNKNOWN fact must NEVER reach tier 1"; else ok "UNKNOWN fact correctly excluded from tier 1"; fi
if echo "$J1" | has_path_in "d['tier3']" "$REPO"; then ok "tier3: shared checkout dirty"; else no "tier3: dirty shared checkout missing"; fi
# no-seam: agent-b's merged+clean+old home has no liveness info at all -> reaps as tier1
if echo "$J1" | has_path_in "d['tier1']" "$WS/agent-b"; then ok "no-seam: agent-b (merged+clean+old, no liveness info) is tier1"; else no "no-seam: agent-b should be tier1 absent a live-sessions seam"; fi

# silent cases must appear in NO tier
ALL1=$(echo "$J1" | all_paths)
for silentpath in "$TMP/wt-wip" "$TMP/wt-fresh-merged"; do
  if grep -qxF "$silentpath" <<<"$ALL1"; then no "silent: $silentpath unexpectedly flagged"; else ok "silent: $silentpath not flagged"; fi
done

# 2. With the live-sessions seam wired: agent-b is LIVE -> vetoed out of tier1, demoted to tier2 with its
#    own reason; agent-a is NOT in the seam -> still tier3.
J2=$(REPO_JANITOR_LIVE_SESSIONS_CMD="cat $LIVE_FILE" python3 "$SWEEP" --json --repo "$REPO" --worktree-root "$WS" 2>/dev/null)
if echo "$J2" | has_path_in "d['tier1']" "$WS/agent-b"; then no "live-owner VETO failed: agent-b reaped as tier1 despite being live"; else ok "live-owner veto: agent-b excluded from tier1"; fi
if echo "$J2" | has_path_in "d['tier2']" "$WS/agent-b"; then ok "live-owner veto: agent-b routed to tier2 instead"; else no "agent-b missing from tier2 after veto"; fi
if echo "$J2" | reason_has "d['tier2']" "$WS/agent-b" "live"; then ok "tier2 reason names agent-b as live"; else no "tier2 reason for agent-b doesn't explain why"; fi
if echo "$J2" | has_path_in "d['tier2']" "$WS/agent-a"; then no "agent-a should NOT read live (only agent-b is in the seam)"; else ok "agent-a correctly not-live (seam scoped to agent-b only)"; fi
if echo "$J2" | has_path_in "d['tier3']" "$WS/agent-a"; then ok "agent-a (owner not live) -> tier3"; else no "agent-a should be tier3 when not live"; fi

# 2b. code-review Finding 1: a CONFIGURED live-sessions seam that FAILS must be UNKNOWN liveness, never
#     silently folded into "not live" — agent-b (merged+clean+old) must NOT reach tier1, and its tier3
#     reason must say liveness couldn't be verified (not silently reaped as if no owner existed).
J_SEAMFAIL=$(REPO_JANITOR_LIVE_SESSIONS_CMD="false" python3 "$SWEEP" --json --repo "$REPO" --worktree-root "$WS" 2>/dev/null)
if echo "$J_SEAMFAIL" | has_path_in "d['tier1']" "$WS/agent-b"; then no "seam-failure: agent-b reached tier1 despite an unverifiable (failed) liveness seam"; else ok "seam-failure: agent-b excluded from tier1"; fi
if echo "$J_SEAMFAIL" | has_path_in "d['tier2']" "$WS/agent-b"; then no "seam-failure: agent-b should NOT be routed to tier2 (we can't confirm they're reachable)"; else ok "seam-failure: agent-b not routed to tier2 either"; fi
if echo "$J_SEAMFAIL" | reason_has "d['tier3']" "$WS/agent-b" "could not be verified"; then ok "seam-failure: tier3 reason explains liveness is unverifiable"; else no "seam-failure: tier3 reason missing the unverifiable-liveness note"; fi

# 2c. code-review Finding 2: a RELATIVE --worktree-root must still derive ownership (git worktree paths
#     are always absolute; a naive normpath-only prefix check would never match and silently disable
#     ownership — and with it, the live-owner tier-1 veto).
RELROOT=$(python3 -c "import os; print(os.path.relpath('$WS', '$TMP'))")
J_RELROOT=$(cd "$TMP" && REPO_JANITOR_LIVE_SESSIONS_CMD="cat $LIVE_FILE" python3 "$SWEEP" --json --repo "$REPO" --worktree-root "$RELROOT" 2>/dev/null)
if echo "$J_RELROOT" | has_path_in "d['tier1']" "$WS/agent-b"; then no "relative --worktree-root: live-owner veto bypassed (agent-b reached tier1)"; else ok "relative --worktree-root: ownership still derived (agent-b excluded from tier1)"; fi
if echo "$J_RELROOT" | has_path_in "d['tier2']" "$WS/agent-b"; then ok "relative --worktree-root: agent-b correctly routed to tier2"; else no "relative --worktree-root: agent-b not routed to tier2 (ownership not derived)"; fi

# 3. --fetch surfaces behind-origin drift that the default (cached) path does not
CLONE="$TMP/other-clone"
git clone -q "$ORIGIN" "$CLONE" >/dev/null 2>&1
g "$CLONE" config user.email t@example.com; g "$CLONE" config user.name smoke
git -C "$CLONE" commit -q --allow-empty -m "someone else's push" >/dev/null 2>&1
g "$CLONE" push -q origin main
J_NOFETCH=$(python3 "$SWEEP" --json --repo "$REPO" 2>/dev/null)
J_FETCH=$(python3 "$SWEEP" --json --repo "$REPO" --fetch 2>/dev/null)
if echo "$J_NOFETCH" | reason_has "d['tier3']" "$REPO" "behind"; then no "no --fetch unexpectedly reported behind-origin (stale cache treated as current)"; else ok "no --fetch: stale cached ref never reports drift it can't see"; fi
if echo "$J_FETCH" | reason_has "d['tier3']" "$REPO" "behind"; then ok "--fetch: behind-origin drift correctly surfaced"; else no "--fetch: behind-origin drift NOT surfaced"; fi

# 4. --reap-tier1 --dry-run touches nothing
COUNT_BEFORE=$(git -C "$REPO" worktree list | wc -l)
python3 "$SWEEP" --repo "$REPO" --worktree-root "$WS" --reap-tier1 --dry-run >/dev/null 2>&1
COUNT_AFTER=$(git -C "$REPO" worktree list | wc -l)
[ "$COUNT_BEFORE" = "$COUNT_AFTER" ] && ok "--dry-run deletes nothing" || no "--dry-run changed the worktree count"

# 5. --reap-tier1 (real, no live-sessions seam -> agent-b has no liveness info, so it IS tier1 here and
#    WILL be reaped; re-run the earlier veto scenario separately in step 2, already verified above).
#    wt-merged-locked is ALSO tier1 (merged+clean+old) but LOCKED — its removal must FAIL, must be
#    counted, and must NOT block the other legitimate removals in the same invocation (code-review
#    Finding 5).
python3 "$SWEEP" --repo "$REPO" --worktree-root "$WS" --reap-tier1 >/dev/null 2>&1
REAP_RC=$?
# Assert on the list BEFORE any independent prune (code-review round-2 Finding 4): pruning here first
# would clean up a prunable record the SCRIPT's own do_reap failed (or forgot) to prune, silently masking
# a broken prune action behind this smoke's own cleanup.
REMAINING=$(git -C "$REPO" worktree list)
if ! grep -q "$TMP/wt-merged$" <<<"$REMAINING"; then ok "reap: tier-1 merged worktree removed"; else no "reap: tier-1 merged worktree still present"; fi
if ! grep -q "wt-prunable" <<<"$REMAINING"; then ok "reap: prunable record pruned"; else no "reap: prunable record still listed"; fi
for keep in "wt-stale" "wt-wip" "wt-broken" "agent-a"; do
  if grep -q "$keep" <<<"$REMAINING"; then ok "reap: non-tier1 '$keep' preserved"; else no "reap: non-tier1 '$keep' was WRONGLY removed"; fi
done
if git -C "$REPO" branch --format='%(refname:short)' 2>/dev/null | grep -qx feat-merged; then no "reap: merged branch ref not deleted"; else ok "reap: merged branch ref cleaned up"; fi
if grep -q "wt-merged-locked" <<<"$REMAINING"; then ok "reap: LOCKED tier-1 worktree's remove failure preserved it"; else no "reap: locked worktree was wrongly removed"; fi
[ "$REAP_RC" -ne 0 ] && ok "reap: exit code is non-zero when a requested removal genuinely failed" || no "reap: exit code should be non-zero (a locked-worktree removal failed)"

# 6. CLI argument validation
python3 "$SWEEP" >/dev/null 2>&1 && no "missing --repo should fail" || ok "missing --repo fails closed"
python3 "$SWEEP" --repo "$REPO" --dry-run >/dev/null 2>&1 && no "--dry-run without --reap-tier1 should fail" || ok "--dry-run without --reap-tier1 fails closed"
python3 "$SWEEP" --repo "$REPO" --owner-depth 0 >/dev/null 2>&1 && no "--owner-depth 0 should fail" || ok "--owner-depth 0 fails closed"

# 7. --json is valid JSON with the documented shape
echo "$J1" | python3 -c "
import json, sys
d = json.load(sys.stdin)
assert set(d.keys()) >= {'tier1','tier2','tier3'}
assert isinstance(d['tier1'], list) and isinstance(d['tier2'], dict) and isinstance(d['tier3'], list)
" 2>/dev/null && ok "--json shape matches the documented contract" || no "--json shape check failed"

if [ "$fails" = 0 ]; then echo "smoke: all groups passed"; else echo "smoke: FAILURES present (see FAIL lines above)"; fi
exit "$fails"
