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
#   - default-ref resolution never falls back to an unverified branch name (merge-gate final-review MED):
#     an unresolvable --default-branch reads as UNKNOWN (inspection needed), not silently merged/unmerged
#   - a worktree with an INITIALIZED submodule is excluded from tier1 even when merged+clean+old, since
#     `git worktree remove` unconditionally refuses it (merge-gate final-review MED)
# -e (merge-gate code-review Finding 5): fixture setup must fail FAST and LOUD, not silently — a swallowed
# `git init`/`commit`/`clone` failure would let a later negative assertion ("X is not tier1") pass
# vacuously because X was never actually created. Safe here because every INTENTIONALLY-nonzero
# invocation below is already wrapped in `if`/`&&`/`||` (exempt from errexit) except one (the real
# --reap-tier1 run with a locked worktree), which explicitly captures its exit code via `&&/||` too.
set -euo pipefail

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

# Fixture-setup helper — FAILS FAST (merge-gate code-review Finding 5): every `g` call below is fixture
# construction that must succeed, never a deliberately-expected-failure path (those are tested via direct
# python3/git invocations with their exit code checked explicitly). A silently swallowed setup failure
# would let a negative assertion ("X is not tier1") pass vacuously because X was never actually created.
g(){ git -C "$1" "${@:2}" >/dev/null 2>&1 || { echo "FIXTURE SETUP FAILED: git -C $1 ${*:2}" >&2; exit 1; }; }

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
git init -q --bare -b main "$ORIGIN"
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

# tier-3 candidate: unmerged, old, no owner. Carries a REAL committed file main doesn't have (not just an
# --allow-empty commit) so the content-identity alternative bar (automated-researcher#533) can't wave it
# through vacuously -- this is what keeps it a genuine "stale, no one continuing it" case even once a
# clean-but-unmerged worktree can otherwise qualify for tier 1 via content-identity.
g "$REPO" worktree add -q -b stale-unmerged "$TMP/wt-stale" main
echo stale_unique_content > "$TMP/wt-stale/stale-unique.txt"
git -C "$TMP/wt-stale" add stale-unique.txt
GIT_COMMITTER_DATE="$OLD_DATE" git -C "$TMP/wt-stale" commit -q -m stale --date="$OLD_DATE"

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

# 3b. round-3 code-review Finding 1: ignored content must never be silently reaped, and a repo config
#     that tries to hide untracked files must not fool the safety-critical status check. Isolated fixture
#     repo so a repo-wide `status.showUntrackedFiles=no` doesn't disturb the main fixture's assertions.
IGN_REPO="$TMP/ign-repo"; IGN_ORIGIN="$TMP/ign-origin.git"
git init -q --bare -b main "$IGN_ORIGIN"
git init -q -b main "$IGN_REPO"
g "$IGN_REPO" config user.email t@example.com; g "$IGN_REPO" config user.name smoke
echo hello > "$IGN_REPO/f.txt"; g "$IGN_REPO" add f.txt; g "$IGN_REPO" commit -q -m init
g "$IGN_REPO" remote add origin "$IGN_ORIGIN"; g "$IGN_REPO" push -q origin main

# merged+clean(tracked)+zero-untracked+old, but carries a real .gitignore'd file — verified empirically
# that `git worktree remove` deletes ignored content right along with everything else, so this must NOT
# reach tier1 (must be silent, since it's not otherwise dirty/untracked/stale-unmerged).
g "$IGN_REPO" worktree add -q -b feat-ignored "$TMP/wt-ignored" main
{ echo "*.local"; } > "$TMP/wt-ignored/.gitignore"
git -C "$TMP/wt-ignored" add .gitignore
GIT_COMMITTER_DATE="$OLD_DATE" git -C "$TMP/wt-ignored" commit -q -m addignore --date="$OLD_DATE"
echo "precious local data" > "$TMP/wt-ignored/keep.local"
g "$IGN_REPO" merge -q --no-edit feat-ignored
g "$IGN_REPO" push -q origin main

# a SECOND worktree with a real untracked file, but the repo is configured to hide untracked files from
# plain `git status` — the safety check must force --untracked-files=all and see it anyway.
g "$IGN_REPO" worktree add -q -b feat-hidden-untracked "$TMP/wt-hidden-untracked" main
GIT_COMMITTER_DATE="$OLD_DATE" git -C "$TMP/wt-hidden-untracked" commit -q --allow-empty -m hiddenuntracked --date="$OLD_DATE"
g "$IGN_REPO" merge -q --no-edit feat-hidden-untracked
g "$IGN_REPO" push -q origin main
echo "a real untracked file" > "$TMP/wt-hidden-untracked/stray.txt"
g "$IGN_REPO" config status.showUntrackedFiles no

J_IGN=$(python3 "$SWEEP" --json --repo "$IGN_REPO" 2>/dev/null)
if echo "$J_IGN" | has_path_in "d['tier1']" "$TMP/wt-ignored"; then no "ignored-content worktree reached tier1 (would have destroyed the ignored file on reap)"; else ok "ignored-content worktree excluded from tier1"; fi
ALL_IGN=$(echo "$J_IGN" | all_paths)
if grep -qxF "$TMP/wt-ignored" <<<"$ALL_IGN"; then no "ignored-content worktree should be SILENT (not noisy tier2/3 nagging over build-cache-like content)"; else ok "ignored-content worktree is silent (not tier1, not noisy)"; fi
if echo "$J_IGN" | has_path_in "d['tier1']" "$TMP/wt-hidden-untracked"; then no "status.showUntrackedFiles=no let a real untracked file hide from the safety check"; else ok "status.showUntrackedFiles=no cannot hide untracked content (forced --untracked-files=all)"; fi

# 3c. round-3 code-review Finding 2: a linked worktree checked out ON the default branch name itself must
#     never have that branch ref deleted, even though it trivially reads as "merged".
DB_REPO="$TMP/db-repo"; DB_ORIGIN="$TMP/db-origin.git"
git init -q --bare -b main "$DB_ORIGIN"
git init -q -b main "$DB_REPO"
g "$DB_REPO" config user.email t@example.com; g "$DB_REPO" config user.name smoke
echo hello > "$DB_REPO/f.txt"; g "$DB_REPO" add f.txt
GIT_COMMITTER_DATE="$OLD_DATE" git -C "$DB_REPO" commit -q -m init --date="$OLD_DATE"   # main's tip must be OLD
g "$DB_REPO" remote add origin "$DB_ORIGIN"; g "$DB_REPO" push -q origin main
g "$DB_REPO" checkout -q -b trunk-work            # primary checkout now sits on a DIFFERENT branch
g "$DB_REPO" worktree add -q "$TMP/wt-on-main" main   # a LINKED worktree checked out on "main" itself

python3 "$SWEEP" --repo "$DB_REPO" --reap-tier1 >/dev/null 2>&1
if [ -d "$TMP/wt-on-main" ]; then no "linked worktree on the default branch was not reaped (expected removal of the WORKTREE, just not the branch)"; else ok "linked worktree on the default branch was removed"; fi
if git -C "$DB_REPO" rev-parse --verify -q refs/heads/main >/dev/null; then ok "default branch ref 'main' preserved after reap"; else no "default branch ref 'main' was WRONGLY deleted"; fi

# 3d. merge-gate final-review MED finding: default-ref resolution must not silently fall back to an
#     unverified branch name when neither the remote-tracking ref nor the local branch exists for the
#     configured --default-branch. A genuinely-merged worktree compared against a bogus name must read
#     UNKNOWN (inspection needed), never silently "merged" or silently "not merged".
J_BADDEFAULT=$(python3 "$SWEEP" --json --repo "$REPO" --default-branch "does-not-exist" 2>/dev/null)
if echo "$J_BADDEFAULT" | has_path_in "d['tier1']" "$TMP/wt-merged"; then no "unresolvable --default-branch: wt-merged falsely reached tier1"; else ok "unresolvable --default-branch: wt-merged excluded from tier1"; fi
if echo "$J_BADDEFAULT" | reason_has "d['tier3']" "$TMP/wt-merged" "inspection needed"; then ok "unresolvable --default-branch: wt-merged reads as UNKNOWN (inspection needed)"; else no "unresolvable --default-branch: wt-merged missing its UNKNOWN/inspection-needed reason"; fi

# 3e. merge-gate final-review MED finding: a worktree with an INITIALIZED submodule reads merged+clean+old
#     but `git worktree remove` unconditionally refuses submodule-bearing worktrees regardless of the
#     submodule's own cleanliness — must be excluded from tier1 (never silently reaped, which would always
#     fail) and flagged with a reason naming the submodule, not silently skipped like ignored content.
SM_SUBORIGIN="$TMP/sm-sub-origin.git"; SM_SUBREPO="$TMP/sm-sub"
git init -q --bare -b main "$SM_SUBORIGIN"
git init -q -b main "$SM_SUBREPO"
g "$SM_SUBREPO" config user.email t@example.com; g "$SM_SUBREPO" config user.name smoke
echo subfile > "$SM_SUBREPO/s.txt"; g "$SM_SUBREPO" add s.txt; g "$SM_SUBREPO" commit -q -m subinit
g "$SM_SUBREPO" remote add origin "$SM_SUBORIGIN"; g "$SM_SUBREPO" push -q origin main

SM_ORIGIN="$TMP/sm-origin.git"; SM_REPO="$TMP/sm-repo"
git init -q --bare -b main "$SM_ORIGIN"
git init -q -b main "$SM_REPO"
g "$SM_REPO" config user.email t@example.com; g "$SM_REPO" config user.name smoke
echo hello > "$SM_REPO/f.txt"; g "$SM_REPO" add f.txt; g "$SM_REPO" commit -q -m init
g "$SM_REPO" remote add origin "$SM_ORIGIN"; g "$SM_REPO" push -q origin main
g "$SM_REPO" -c protocol.file.allow=always submodule add -q "$SM_SUBORIGIN" subm
g "$SM_REPO" commit -q -m addsubmodule
g "$SM_REPO" push -q origin main

g "$SM_REPO" worktree add -q -b feat-with-submodule "$TMP/wt-submodule" main
GIT_COMMITTER_DATE="$OLD_DATE" git -C "$TMP/wt-submodule" commit -q --allow-empty -m oldsubm --date="$OLD_DATE"
g "$TMP/wt-submodule" -c protocol.file.allow=always submodule update --init -q
g "$SM_REPO" merge -q --no-edit feat-with-submodule
g "$SM_REPO" push -q origin main

J_SUBM=$(python3 "$SWEEP" --json --repo "$SM_REPO" 2>/dev/null)
if echo "$J_SUBM" | has_path_in "d['tier1']" "$TMP/wt-submodule"; then no "submodule-bearing worktree reached tier1 (git worktree remove would refuse it)"; else ok "submodule-bearing worktree excluded from tier1"; fi
if echo "$J_SUBM" | reason_has "d['tier3']" "$TMP/wt-submodule" "submodule"; then ok "tier3 reason names the initialized submodule"; else no "tier3 reason for submodule-bearing worktree missing the submodule note"; fi

python3 "$SWEEP" --repo "$SM_REPO" --reap-tier1 >/dev/null 2>&1
if [ -d "$TMP/wt-submodule" ]; then ok "submodule-bearing worktree not removed by --reap-tier1"; else no "submodule-bearing worktree was WRONGLY removed (or removal was wrongly attempted/succeeded)"; fi

# 3f. automated-researcher#533: the content-identity alternative bar. Under a squash-merge PR flow a
#     branch's own commit is never an ancestor of the default branch (its content lands as a separate
#     squashed commit), so `merged_fact` is a confirmed False forever and the classic tier-1 bar can never
#     pass — this must not mean the worktree nags forever once its content has genuinely landed elsewhere.
CI_ORIGIN="$TMP/ci-origin.git"; CI_REPO="$TMP/ci-repo"
git init -q --bare -b main "$CI_ORIGIN"
git init -q -b main "$CI_REPO"
g "$CI_REPO" config user.email t@example.com; g "$CI_REPO" config user.name smoke
echo hello > "$CI_REPO/f.txt"; g "$CI_REPO" add f.txt; g "$CI_REPO" commit -q -m init
g "$CI_REPO" remote add origin "$CI_ORIGIN"; g "$CI_REPO" push -q origin main

# Case A: squash-merge-equivalent — a clean, old, fully-committed worktree whose branch was never merged,
# but whose exact file content was independently squash-landed on main under a DIFFERENT commit.
g "$CI_REPO" worktree add -q -b feat-squashed "$TMP/wt-squashed" main
echo squashcontent > "$TMP/wt-squashed/newfile.txt"
git -C "$TMP/wt-squashed" add newfile.txt
GIT_COMMITTER_DATE="$OLD_DATE" git -C "$TMP/wt-squashed" commit -q -m addnewfile --date="$OLD_DATE"
echo squashcontent > "$CI_REPO/newfile.txt"
git -C "$CI_REPO" add newfile.txt
g "$CI_REPO" commit -q -m "squash landed newfile"
g "$CI_REPO" push -q origin main

# Case B: the same idea but as UNCOMMITTED residue — an untracked file that happens to already match main
# byte-for-byte (the literal case the manual 2026-07-19 verification script checked).
g "$CI_REPO" worktree add -q -b feat-stray-matching "$TMP/wt-stray-matching" main
GIT_COMMITTER_DATE="$OLD_DATE" git -C "$TMP/wt-stray-matching" commit -q --allow-empty -m oldbase --date="$OLD_DATE"
echo squashcontent > "$TMP/wt-stray-matching/newfile.txt"   # untracked, matches main's newfile.txt exactly

# Case C: genuinely novel untracked content with no counterpart on main at all — must NOT be silently
# waved through (a per-file compare failure, including "path absent from main", is UNKNOWN, never a guess).
g "$CI_REPO" worktree add -q -b feat-stray-novel "$TMP/wt-stray-novel" main
GIT_COMMITTER_DATE="$OLD_DATE" git -C "$TMP/wt-stray-novel" commit -q --allow-empty -m oldbase2 --date="$OLD_DATE"
echo genuinely_novel_scratch > "$TMP/wt-stray-novel/scratch.txt"

J_CI=$(python3 "$SWEEP" --json --repo "$CI_REPO" 2>/dev/null)
if echo "$J_CI" | has_path_in "d['tier1']" "$TMP/wt-squashed"; then ok "content-identity: squash-merge-equivalent clean+old worktree reaches tier1 despite merged=False"; else no "content-identity: squash-merge-equivalent worktree NOT classified tier1 (defect not fixed)"; fi
if echo "$J_CI" | reason_has "d['tier1']" "$TMP/wt-squashed" "squash-merge equivalent"; then ok "content-identity: tier1 reason distinguishes the squash-merge-equivalent path from a literal merge"; else no "content-identity: tier1 reason doesn't explain the squash-merge-equivalent basis"; fi
if echo "$J_CI" | has_path_in "d['tier1']" "$TMP/wt-stray-matching"; then ok "content-identity: untracked residue matching main exactly reaches tier1"; else no "content-identity: matching untracked residue NOT classified tier1"; fi
if echo "$J_CI" | has_path_in "d['tier1']" "$TMP/wt-stray-novel"; then no "content-identity: worktree with genuinely novel untracked content wrongly reached tier1"; else ok "content-identity: novel untracked content (no counterpart on main) correctly excluded from tier1"; fi

# content-identity items must actually survive a REAL --reap-tier1 pass too, not just classification — the
# do_reap re-verification recomputes merged/content-identity fresh before deleting, and must not gate solely
# on `merged_now is True` (which a squash-merge branch can never satisfy, at classification OR reap time).
python3 "$SWEEP" --repo "$CI_REPO" --reap-tier1 >/dev/null 2>&1
if [ -d "$TMP/wt-squashed" ]; then no "content-identity: squash-merge-equivalent worktree NOT removed by --reap-tier1 (re-verification regressed to requiring literal merged=True)"; else ok "content-identity: squash-merge-equivalent worktree removed by --reap-tier1"; fi
if [ -d "$TMP/wt-stray-matching" ]; then no "content-identity: matching-residue worktree NOT removed by --reap-tier1"; else ok "content-identity: matching-residue worktree removed by --reap-tier1"; fi
if git -C "$CI_REPO" branch --format='%(refname:short)' 2>/dev/null | grep -qx feat-squashed; then ok "content-identity: branch ref survives reap (git branch -d is a no-op for a non-ancestor branch, non-fatal)"; else no "content-identity: branch ref feat-squashed was WRONGLY deleted despite never being an ancestor"; fi
if [ -d "$TMP/wt-stray-novel" ]; then ok "content-identity: novel-content worktree preserved by --reap-tier1"; else no "content-identity: novel-content worktree was WRONGLY removed by --reap-tier1"; fi

# 3g. automated-researcher#533: submodule-fact per-path degradation. A single gitlink with no `.gitmodules`
#     mapping makes `git submodule status` fail identically for EVERY worktree whose checkout contains that
#     path — this previously read as UNKNOWN (submodule fact unresolvable) and disqualified every one of
#     them from tier 1 for a reason that had nothing to do with their own submodule state. Falling back to
#     a per-path gitlink scan restores a real answer instead.
UM_ORIGIN="$TMP/um-origin.git"; UM_REPO="$TMP/um-repo"
git init -q --bare -b main "$UM_ORIGIN"
git init -q -b main "$UM_REPO"
g "$UM_REPO" config user.email t@example.com; g "$UM_REPO" config user.name smoke
echo hello > "$UM_REPO/f.txt"; g "$UM_REPO" add f.txt; g "$UM_REPO" commit -q -m init
FAKESHA="1234567890123456789012345678901234567890"
g "$UM_REPO" update-index --add --cacheinfo 160000,$FAKESHA,badlink
g "$UM_REPO" commit -q -m addbadgitlink
g "$UM_REPO" remote add origin "$UM_ORIGIN"; g "$UM_REPO" push -q origin main

g "$UM_REPO" worktree add -q -b feat-um-merged "$TMP/wt-um-merged" main
GIT_COMMITTER_DATE="$OLD_DATE" git -C "$TMP/wt-um-merged" commit -q --allow-empty -m umold --date="$OLD_DATE"
g "$UM_REPO" merge -q --no-edit feat-um-merged
g "$UM_REPO" push -q origin main

if git -C "$UM_REPO" submodule status >/dev/null 2>&1; then no "fixture setup: expected 'git submodule status' to fail on the unmapped gitlink (fixture doesn't reproduce the real trigger)"; else ok "fixture: 'git submodule status' fails on the unmapped gitlink, as in the real 2026-07-19 trigger"; fi

J_UM=$(python3 "$SWEEP" --json --repo "$UM_REPO" 2>/dev/null)
if echo "$J_UM" | has_path_in "d['tier1']" "$TMP/wt-um-merged"; then ok "unmapped-gitlink degradation: merged+clean+old worktree still reaches tier1 (submodule fact degrades per-path instead of poisoning UNKNOWN)"; else no "unmapped-gitlink poisoned tier1 classification (submodule check failure not degraded)"; fi

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
# This ONE invocation is EXPECTED to exit non-zero (the locked worktree's removal genuinely fails) — under
# `set -e`, capturing that via a bare `cmd; rc=$?` would abort the script before the assignment ever runs;
# `&&/||` is the pattern that both survives errexit and captures the deliberately-expected failure.
python3 "$SWEEP" --repo "$REPO" --worktree-root "$WS" --reap-tier1 >/dev/null 2>&1 && REAP_RC=0 || REAP_RC=$?
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
# merge-gate Finding 3: an empty/blank --repo must never silently normalize to cwd
python3 "$SWEEP" --repo "" >/dev/null 2>&1 && no "empty --repo should fail" || ok "empty --repo fails closed"
python3 "$SWEEP" --repo "   " >/dev/null 2>&1 && no "whitespace-only --repo should fail" || ok "whitespace-only --repo fails closed"
python3 "$SWEEP" --repo "$REPO" --default-branch "" >/dev/null 2>&1 && no "empty --default-branch should fail" || ok "empty --default-branch fails closed"
# merge-gate round-2 Finding 1: a remote shorthand / qualified ref resolves fine as a git revision but
# differs from the local short branch name the protection guard compares against — must be rejected.
python3 "$SWEEP" --repo "$REPO" --default-branch "origin/main" >/dev/null 2>&1 && no "--default-branch 'origin/main' should fail" || ok "--default-branch 'origin/main' (remote shorthand) fails closed"
python3 "$SWEEP" --repo "$REPO" --default-branch "refs/remotes/origin/main" >/dev/null 2>&1 && no "--default-branch qualified remote ref should fail" || ok "--default-branch qualified remote ref fails closed"
# merge-gate Finding 1: a fully-qualified refs/heads/<name> --default-branch must normalize to the short
# name, so the never-delete-the-default-branch guard still matches (not silently bypassed by a comparison
# of "main" != "refs/heads/main"). $DB_REPO's "main" was freed up again when wt-on-main was reaped above.
g "$DB_REPO" worktree add -q "$TMP/wt-on-main-2" main
python3 "$SWEEP" --repo "$DB_REPO" --default-branch "refs/heads/main" --reap-tier1 >/dev/null 2>&1
if [ -d "$TMP/wt-on-main-2" ]; then no "fully-qualified --default-branch: worktree not reaped as expected"; else ok "fully-qualified --default-branch: worktree still reaped correctly"; fi
if git -C "$DB_REPO" rev-parse --verify -q refs/heads/main >/dev/null; then ok "fully-qualified --default-branch: default branch ref still preserved (normalization closed the bypass)"; else no "fully-qualified --default-branch: default branch ref was WRONGLY deleted"; fi

# 7. --json is valid JSON with the documented shape
echo "$J1" | python3 -c "
import json, sys
d = json.load(sys.stdin)
assert set(d.keys()) >= {'tier1','tier2','tier3'}
assert isinstance(d['tier1'], list) and isinstance(d['tier2'], dict) and isinstance(d['tier3'], list)
" 2>/dev/null && ok "--json shape matches the documented contract" || no "--json shape check failed"

# 8. Report ergonomics (automated-researcher#533): a reason string shared by a large fraction of one tier's
#    entries collapses into a single summary line + a flat path list, instead of repeating the full reason
#    and action commands once per entry — the real 2026-07-19 sweep produced 40 duplicate "inspection
#    needed" lines from one shared root cause, burying the one actionable fact in noise. Exercised directly
#    against render_text() (a synthetic report) rather than via real fixtures — the collapsing is a pure
#    function of reason-string repetition, not of any particular git state.
python3 -c "
import sys, io, contextlib
sys.path.insert(0, '$HERE')
import worktree_sweep as ws

def entry(i, reason):
    return {'repo': '/r', 'path': f'/wt/{i}', 'branch': 'b', 'owner': None, 'tier': 3, 'reason': reason,
            'action': {'kind': 'inspect', 'commands': [f'git -C /wt/{i} status']}}

many_same = [entry(i, 'inspection needed: shared root cause') for i in range(8)]
few_distinct = [entry(100 + i, f'distinct reason {i}') for i in range(2)]
results = {'tier1': [], 'tier2': {}, 'tier3': many_same + few_distinct}

buf = io.StringIO()
with contextlib.redirect_stdout(buf):
    ws.render_text(results)
out = buf.getvalue()

assert '[8 worktrees, same root cause] inspection needed: shared root cause' in out, 'shared reason not collapsed:\n' + out
assert out.count('git -C /wt/') == 2, 'collapsed entries must not repeat action commands: ' + out
assert 'distinct reason 0' in out and 'distinct reason 1' in out, 'distinct (non-repeated) reasons must still render individually: ' + out
" && ok "report ergonomics: a reason shared by most of a tier collapses; distinct reasons still render individually" || no "report ergonomics: collapse behavior check failed"

if [ "$fails" = 0 ]; then echo "smoke: all groups passed"; else echo "smoke: FAILURES present (see FAIL lines above)"; fi
exit "$fails"
