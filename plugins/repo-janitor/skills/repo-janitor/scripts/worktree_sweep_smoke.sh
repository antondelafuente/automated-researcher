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
#   - the MERGED+identical-residue tier-1 bar (automated-researcher#804): a merged-but-BEHIND worktree
#     whose only residue is a byte-identical duplicate of the default branch reaches tier 1 and is really
#     removed, while one whose residue differs from main, or sits at a path main lacks entirely, stays
#     reported and survives a real --reap-tier1
#   - the MERGED+allowlisted-residue tier-1 bar (automated-researcher#840): a merged worktree whose
#     non-identical residue is entirely regenerable (`*.run.log`, `__pycache__/`, `*.pyc`) or superseded by
#     main's own copy of the same path reaches tier 1, names its allowlist in the reason, and is really
#     removed — while ONE off-allowlist file, or a superseded-class basename at a path main does NOT carry,
#     keeps the worktree reported and alive through a real --reap-tier1. The fixture repo carries a REAL
#     .gitignore, so the regenerable classes arrive IGNORED (the category they land in on any real repo,
#     this one included) rather than untracked: a merged worktree whose entire residue is ignored and
#     allowlisted reaches tier 1, says so in its reason, and is really removed, while one off-allowlist
#     ignored file (a local `.env`) keeps the whole worktree silent and intact through a real --reap-tier1
#   - the PER-TIER age bar (#840): a merged worktree 3d old reaches tier 1 under the default 2-day merged
#     bar while an unmerged 3d-old one stays silent under the unchanged 7-day bar, and each bar is movable
#     independently (--merged-min-age-days / --min-age-days), with a negative value rejected
#   - repeatable --worktree-root (#840): naming the harness's own (nested) worktree root gives its trees the
#     live-owner tier-2 veto they never had, without changing the workspace root's own classification; the
#     owner id comes from the most specific matching root, and a whitespace-only root is rejected
#   - a worktree with an INITIALIZED submodule is excluded from tier1 even when merged+clean+old, since
#     `git worktree remove` unconditionally refuses it (merge-gate final-review MED)
#   - --scratch-glob, the non-git scratch prune (automated-researcher#792): a stale entry reaches tier1 and
#     is actually deleted; a fresh one is silent; a dir whose OWN mtime is old but that carries a freshly
#     written file is silent (the TREE's newest mtime is the fact); a symlink, a swept repo's own worktree,
#     and an aged-out BARE repository (no `.git` entry — HEAD + objects/ + refs/ at its root) all route to
#     tier3 and survive a real --reap-tier1; --dry-run deletes nothing; and every unsafe
#     repository-like entries NEVER reach tier 1 whether or not their repo marker resolves: a bare repo, a
#     bare repo missing refs/, and a checkout whose `.git` is a DANGLING SYMLINK all route to tier 3; an
#     entry that IS or CONTAINS a mount point routes to tier 3 and survives a real --reap-tier1 (with the
#     mount point's `\040` space escape decoded before comparison), an ANCESTOR mount blocks nothing, and
#     an unreadable mount table is UNKNOWN -> tier 3; and every unsafe
#     --scratch-glob shape (relative, wildcard in the directory part, root-level, trailing slash) is
#     rejected up front so the delete scope stays statically bounded
#   - the "Reaped" report section (#792's acceptance bar): --json's `reaped` records and the human
#     report's section both name what was actually removed, and a tier-3 entry never appears there
#   - --evict-verified, the CONTENT-keyed eviction leg (automated-researcher#856): bytes proven at the
#     artifact store by a RECOMPUTED CHECKSUM reach tier1 and are really unlinked (under a store layout
#     that does NOT mirror the local path), while name+size agreement with no comparable checksum, an
#     incomparable-only algorithm, a disagreeing checksum, one record contradicting itself across two
#     spellings of one algorithm, a size disagreement, an absent object, a failed listing, a file directly
#     under the root and a live owner's file are ALL kept and survive a real --reap-tier1; rclone's
#     `MD5`/`SHA-1` spellings verify exactly as `md5`/`sha1` do (a case-sensitive lookup silently dropped
#     production hashes — Codex review #859 round 1); a sub---min-size file, a symlink and everything under
#     `registry/` of a git tree are never even classified while a plain `registry/` dir outside a checkout
#     still evicts; a hardlinked pair is ONE entry that unlinks every link and counts its bytes once while
#     an out-of-scope link keeps the group; --dry-run evicts nothing; the `reaped`/`## Reclaimed`
#     accounting splits verified-on-store from tier-1 bytes; and every incomplete/unsafe invocation is
#     rejected up front. The store is stood in for through the REPO_JANITOR_STORE_LIST_CMD seam (rclone is
#     not reachable on a CI runner, and the contract under test is what the sweep does with the LISTING)
#   - evict_unlink's identity-AND-byte binding (#859 rounds 1 and 2), driven directly as a unit: the
#     verified inode is the one removed and its BYTES are re-digested immediately before the unlink, so a
#     file rewritten in place with its size and mtime_ns preserved — the case a stat tuple cannot see — is
#     refused; a stat-key, link-count or digest disagreement (and a missing digest at all) aborts and
#     RESTORES every staged link under its original name, leaving no `.repo-janitor-evicting.*` entry behind
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
echo hello > "$CI_REPO/f.txt"; g "$CI_REPO" add f.txt
# symlink-victim.txt is committed here, in the SHARED base every Case A-F branch forks from (not added to
# main later): default_ref is re-resolved fresh for every content-identity check, so adding a file to main
# AFTER a branch already forked would make that branch's own committed-tree diff (step 1) non-empty against
# every OTHER already-existing case's fork point too — it must land in the common ancestor all cases share.
echo hello > "$CI_REPO/symlink-victim.txt"; g "$CI_REPO" add symlink-victim.txt
g "$CI_REPO" commit -q -m init
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

# Case B: the same idea but as UNCOMMITTED residue — a file whose content matches main byte-for-byte but
# reads as untracked ("??") in `git status` rather than clean (the literal case the manual 2026-07-19
# verification script checked). Built by untracking an already-identical, already-committed file from the
# INDEX ONLY (`git rm --cached`, disk content untouched) rather than deleting+recreating it: the committed
# tree (HEAD) stays byte-identical to default_ref either way (content_identical_fact's step 1, the
# committed-tree diff, stays empty — `git rm --cached` doesn't create a new commit), while status now
# reports it "??" for step 2 to match against main. (Round-1 Codex review, automated-researcher#537 P0: the
# ORIGINAL version of this fixture instead branched feat-stray-matching from `main` AFTER Case A's
# newfile.txt had already landed there, so the checkout inherited it as an already-tracked, UNMODIFIED file
# — `git status` reported nothing for it, so the fixture never actually exercised a genuinely untracked path
# at all, and its "removed by --reap-tier1" assertion passed on git's own plain clean bar alone, never on
# the content-identity/`--force` path it claimed to be testing.)
g "$CI_REPO" worktree add -q -b feat-stray-matching "$TMP/wt-stray-matching" main
GIT_COMMITTER_DATE="$OLD_DATE" git -C "$TMP/wt-stray-matching" commit -q --allow-empty -m oldbase --date="$OLD_DATE"
git -C "$TMP/wt-stray-matching" rm -q --cached newfile.txt

# Case C: genuinely novel untracked content with no counterpart on main at all — must NOT be silently
# waved through (a per-file compare failure, including "path absent from main", is UNKNOWN, never a guess).
g "$CI_REPO" worktree add -q -b feat-stray-novel "$TMP/wt-stray-novel" main
GIT_COMMITTER_DATE="$OLD_DATE" git -C "$TMP/wt-stray-novel" commit -q --allow-empty -m oldbase2 --date="$OLD_DATE"
echo genuinely_novel_scratch > "$TMP/wt-stray-novel/scratch.txt"

# Case D (round-2 Codex review, automated-researcher#537 P0): a tracked file staged with unique content,
# then the WORKING TREE reverted back to byte-match main on top of that staged change ("MM" status) — the
# committed tree (HEAD) still matches main exactly, so step 1 stays empty, and a working-tree-only residue
# check would see f.txt's on-disk bytes match main and wrongly call this content-identical, losing the
# staged-only content. The index blob must be checked too.
g "$CI_REPO" worktree add -q -b feat-staged-unique "$TMP/wt-staged-unique" main
GIT_COMMITTER_DATE="$OLD_DATE" git -C "$TMP/wt-staged-unique" commit -q --allow-empty -m oldbase3 --date="$OLD_DATE"
echo staged_unique_content > "$TMP/wt-staged-unique/f.txt"
git -C "$TMP/wt-staged-unique" add f.txt
echo hello > "$TMP/wt-staged-unique/f.txt"  # working tree reverted to match main's f.txt byte-for-byte

# Case E (senior-engineer round, automated-researcher#537): an uncommitted chmod-only change on a tracked
# file -- `chmod +x` alone, no byte change. Porcelain status reports this as a modification with IDENTICAL
# content to main, so a byte-only compare would call this content-identical and a forced reap would then
# destroy the mode change; must be excluded from tier1 (lands tier3 as dirty, same as any other tracked
# modification).
g "$CI_REPO" worktree add -q -b feat-chmod-only "$TMP/wt-chmod-only" main
GIT_COMMITTER_DATE="$OLD_DATE" git -C "$TMP/wt-chmod-only" commit -q --allow-empty -m oldbase4 --date="$OLD_DATE"
chmod +x "$TMP/wt-chmod-only/f.txt"

# Case F (senior-engineer round, automated-researcher#537): an untracked SYMLINK at a path whose main copy
# is a tracked regular file (symlink-victim.txt, committed in CI_REPO's shared base above), where the
# symlink's FOLLOWED target has bytes identical to main's copy -- the exact case a bare `open()` read (which
# follows symlinks) would match byte-for-byte, silently treating a mode-120000 path as content-identical to
# main's mode-100644 copy and losing the symlink itself on reap.
g "$CI_REPO" worktree add -q -b feat-symlink-residue "$TMP/wt-symlink-residue" main
GIT_COMMITTER_DATE="$OLD_DATE" git -C "$TMP/wt-symlink-residue" commit -q --allow-empty -m oldbase5 --date="$OLD_DATE"
git -C "$TMP/wt-symlink-residue" rm -q --cached symlink-victim.txt
rm "$TMP/wt-symlink-residue/symlink-victim.txt"
ln -s f.txt "$TMP/wt-symlink-residue/symlink-victim.txt"

J_CI=$(python3 "$SWEEP" --json --repo "$CI_REPO" 2>/dev/null)
if echo "$J_CI" | has_path_in "d['tier1']" "$TMP/wt-squashed"; then ok "content-identity: squash-merge-equivalent clean+old worktree reaches tier1 despite merged=False"; else no "content-identity: squash-merge-equivalent worktree NOT classified tier1 (defect not fixed)"; fi
if echo "$J_CI" | reason_has "d['tier1']" "$TMP/wt-squashed" "squash-merge equivalent"; then ok "content-identity: tier1 reason distinguishes the squash-merge-equivalent path from a literal merge"; else no "content-identity: tier1 reason doesn't explain the squash-merge-equivalent basis"; fi
if echo "$J_CI" | has_path_in "d['tier1']" "$TMP/wt-stray-matching"; then ok "content-identity: untracked residue matching main exactly reaches tier1"; else no "content-identity: matching untracked residue NOT classified tier1"; fi
if echo "$J_CI" | has_path_in "d['tier1']" "$TMP/wt-stray-novel"; then no "content-identity: worktree with genuinely novel untracked content wrongly reached tier1"; else ok "content-identity: novel untracked content (no counterpart on main) correctly excluded from tier1"; fi
if echo "$J_CI" | has_path_in "d['tier1']" "$TMP/wt-staged-unique"; then no "content-identity: staged-unique ('MM') worktree WRONGLY reached tier1 (index-only content would be lost on reap)"; else ok "content-identity: staged-unique ('MM') worktree correctly excluded from tier1 (index blob checked, not just the working-tree read)"; fi
if echo "$J_CI" | has_path_in "d['tier1']" "$TMP/wt-chmod-only"; then no "content-identity: chmod-only worktree WRONGLY reached tier1 (mode change would be lost on reap)"; else ok "content-identity: chmod-only worktree correctly excluded from tier1 (mode compared, not just bytes)"; fi
if echo "$J_CI" | has_path_in "d['tier1']" "$TMP/wt-symlink-residue"; then no "content-identity: untracked-symlink worktree WRONGLY reached tier1 (followed-target bytes matched main, but mode 120000 != 100644)"; else ok "content-identity: untracked-symlink worktree correctly excluded from tier1 (symlink compared by mode+link-target, never by followed content)"; fi

# content-identity items must actually survive a REAL --reap-tier1 pass too, not just classification — the
# do_reap re-verification recomputes merged/content-identity fresh before deleting, and must not gate solely
# on `merged_now is True` (which a squash-merge branch can never satisfy, at classification OR reap time).
# `|| true`: do_reap's exit code reflects genuine removal failures (main() propagates `fails`), and under
# `set -euo pipefail` an unguarded non-zero exit here would abort the whole smoke script before the
# assertions below ever ran, instead of surfacing as a clean FAIL line (as line 400's `&&/||` capture
# already does for the equivalent case elsewhere in this file).
python3 "$SWEEP" --repo "$CI_REPO" --reap-tier1 >/dev/null 2>&1 || true
if [ -d "$TMP/wt-squashed" ]; then no "content-identity: squash-merge-equivalent worktree NOT removed by --reap-tier1 (re-verification regressed to requiring literal merged=True)"; else ok "content-identity: squash-merge-equivalent worktree removed by --reap-tier1"; fi
if [ -d "$TMP/wt-stray-matching" ]; then no "content-identity: matching-residue worktree NOT removed by --reap-tier1"; else ok "content-identity: matching-residue worktree removed by --reap-tier1"; fi
if git -C "$CI_REPO" branch --format='%(refname:short)' 2>/dev/null | grep -qx feat-squashed; then ok "content-identity: branch ref survives reap (git branch -d is a no-op for a non-ancestor branch, non-fatal)"; else no "content-identity: branch ref feat-squashed was WRONGLY deleted despite never being an ancestor"; fi
if [ -d "$TMP/wt-stray-novel" ]; then ok "content-identity: novel-content worktree preserved by --reap-tier1"; else no "content-identity: novel-content worktree was WRONGLY removed by --reap-tier1"; fi
if [ -d "$TMP/wt-staged-unique" ]; then ok "content-identity: staged-unique ('MM') worktree preserved by --reap-tier1"; else no "content-identity: staged-unique ('MM') worktree was WRONGLY removed by --reap-tier1 (staged-only content lost)"; fi
if [ -d "$TMP/wt-chmod-only" ]; then ok "content-identity: chmod-only worktree preserved by --reap-tier1"; else no "content-identity: chmod-only worktree was WRONGLY removed by --reap-tier1 (mode change lost)"; fi
if [ -d "$TMP/wt-symlink-residue" ]; then ok "content-identity: untracked-symlink worktree preserved by --reap-tier1"; else no "content-identity: untracked-symlink worktree was WRONGLY removed by --reap-tier1 (symlink lost)"; fi

# 3f2. automated-researcher#804: a MERGED worktree whose only residue is byte-identical to the default
#      branch. The 2026-08-31 instance sweep classified 22/22 worktrees as tier 3 with ZERO in tier 1 while
#      4 of 7 hand-checked ones carried nothing but duplicates of `origin/main`: `log-experiment` lands
#      `registry/<exp>/` from its own branch, so the executor worktree's identical copy reads UNTRACKED
#      forever. The #533 whole-tree bar could not rescue them either — its two-tree diff lists everything
#      main changed SINCE the worktree's HEAD, which for a worktree whose PR landed weeks ago is never
#      empty. So the fixture below is deliberately MERGED-AND-BEHIND: main moves on after the merge, which
#      is exactly what makes the whole-tree check answer False and the residue-only check the load-bearing
#      one.
M_ORIGIN="$TMP/m-origin.git"; M_REPO="$TMP/m-repo"
git init -q --bare -b main "$M_ORIGIN"
git init -q -b main "$M_REPO"
g "$M_REPO" config user.email t@example.com; g "$M_REPO" config user.name smoke
echo hello > "$M_REPO/f.txt"; g "$M_REPO" add f.txt; g "$M_REPO" commit -q -m init
g "$M_REPO" remote add origin "$M_ORIGIN"; g "$M_REPO" push -q origin main

# Three old worktrees, each branched off main and merged BACK into it (so ancestry — plain `merged` — holds
# for all three); they differ only in what residue sits on top.
for w in merged-dup merged-differs merged-novel; do
  g "$M_REPO" worktree add -q -b "feat-$w" "$TMP/wt-$w" main
  GIT_COMMITTER_DATE="$OLD_DATE" git -C "$TMP/wt-$w" commit -q --allow-empty -m "old-$w" --date="$OLD_DATE"
  g "$M_REPO" merge -q --no-edit "feat-$w"
done
g "$M_REPO" push -q origin main

# ...and then main moves on with a registry record landed from its OWN branch, which none of the three
# worktrees has in its index. This is what puts every one of them BEHIND main.
mkdir -p "$M_REPO/registry/exp-1"
printf 'record-line\n' > "$M_REPO/registry/exp-1/RESULTS.md"
g "$M_REPO" add registry/exp-1/RESULTS.md
g "$M_REPO" commit -q -m "log-experiment landed registry/exp-1 from its own branch"
g "$M_REPO" push -q origin main

# Case A: the incident's own shape — an untracked copy of a path on main, byte-for-byte identical.
mkdir -p "$TMP/wt-merged-dup/registry/exp-1"
printf 'record-line\n' > "$TMP/wt-merged-dup/registry/exp-1/RESULTS.md"
# Case B: the same path, DIFFERENT bytes — a confirmed "not identical", must stay reported, never reaped.
mkdir -p "$TMP/wt-merged-differs/registry/exp-1"
printf 'locally-edited-line\n' > "$TMP/wt-merged-differs/registry/exp-1/RESULTS.md"
# Case C: residue at a path main does not carry AT ALL — UNKNOWN per-file compare, never a guessed "same".
printf 'only-here\n' > "$TMP/wt-merged-novel/scratch-notes.txt"

J_M=$(python3 "$SWEEP" --json --repo "$M_REPO" 2>/dev/null)
if echo "$J_M" | has_path_in "d['tier1']" "$TMP/wt-merged-dup"; then ok "merged-residue-identity: merged+behind worktree whose untracked residue duplicates main reaches tier1"; else no "merged-residue-identity: duplicate-residue worktree NOT classified tier1 (#804 defect not fixed)"; fi
if echo "$J_M" | reason_has "d['tier1']" "$TMP/wt-merged-dup" "residue identical to main"; then ok "merged-residue-identity: tier1 reason names the residue-identity basis"; else no "merged-residue-identity: tier1 reason doesn't state the residue-identity basis"; fi
if echo "$J_M" | has_path_in "d['tier1']" "$TMP/wt-merged-differs"; then no "merged-residue-identity: worktree whose residue DIFFERS from main wrongly reached tier1 (real edits would be lost)"; else ok "merged-residue-identity: differing residue correctly excluded from tier1"; fi
if echo "$J_M" | has_path_in "d['tier3']" "$TMP/wt-merged-differs"; then ok "merged-residue-identity: differing residue reported in tier3"; else no "merged-residue-identity: differing-residue worktree reported in neither tier1 nor tier3"; fi
if echo "$J_M" | has_path_in "d['tier1']" "$TMP/wt-merged-novel"; then no "merged-residue-identity: residue absent from main wrongly reached tier1 (UNKNOWN treated as identical)"; else ok "merged-residue-identity: residue absent from main correctly excluded from tier1"; fi
# The reason for a merged worktree whose identity check came back UNKNOWN/False stays the PRECISE
# dirty/untracked one it was before #804 — a failed residue comparison must not downgrade a reported
# entry's reason to a generic "inspection needed".
if echo "$J_M" | reason_has "d['tier3']" "$TMP/wt-merged-novel" "untracked"; then ok "merged-residue-identity: an UNKNOWN residue comparison keeps the precise untracked reason"; else no "merged-residue-identity: UNKNOWN residue comparison replaced the precise reason with a generic one"; fi

# ...and the classification must survive do_reap's own re-verification, which recomputes the same facts.
python3 "$SWEEP" --repo "$M_REPO" --reap-tier1 >/dev/null 2>&1 || true
if [ -d "$TMP/wt-merged-dup" ]; then no "merged-residue-identity: duplicate-residue worktree NOT removed by --reap-tier1 (reap-time re-verification regressed)"; else ok "merged-residue-identity: duplicate-residue worktree removed by --reap-tier1 (--force lifts the untracked refusal)"; fi
if [ -d "$TMP/wt-merged-differs" ]; then ok "merged-residue-identity: differing-residue worktree preserved by --reap-tier1"; else no "merged-residue-identity: differing-residue worktree was WRONGLY removed (local edits lost)"; fi
if [ -d "$TMP/wt-merged-novel" ]; then ok "merged-residue-identity: novel-residue worktree preserved by --reap-tier1"; else no "merged-residue-identity: novel-residue worktree was WRONGLY removed"; fi
if [ -f "$M_REPO/registry/exp-1/RESULTS.md" ]; then ok "merged-residue-identity: the default branch's own copy of the duplicated path is untouched"; else no "merged-residue-identity: the swept checkout's own registry file disappeared"; fi

# 3f3. automated-researcher#840: a MERGED worktree whose NON-identical residue is entirely on the bounded
#      regenerable/superseded allowlist. Measured cause: four merged experiment worktrees (2.2-2.4G each,
#      9.3G total) had to be removed by hand on 2026-09-06 because #804's byte-identity bar never admitted
#      them — their only non-identical paths were `*.run.log` audit logs, `__pycache__`, and design-stage
#      record files main already holds in post-run form. The two negative cases below are the whole safety
#      story for this bar: ONE off-allowlist file keeps the worktree out, and a SUPERSEDED-class basename
#      whose exact path main does NOT carry is not superseded at all (it exists nowhere else).
#
#      THE FIXTURE CARRIES A REAL `.gitignore` (Codex review of PR #842), and that is load-bearing, not
#      set dressing: a normal Python repo's ignore rules — including this repo's own — already cover
#      `__pycache__/`, `*.pyc` and `*.run.log`, so on a real box those paths arrive from `git status` as
#      IGNORED, not untracked. The first cut of this block used a fixture with no `.gitignore` at all, so
#      every regenerable class read as untracked and the bar was only ever exercised against a category it
#      does not meet in production; with the ignore rules in place these cases fail on the pre-fix code
#      (the worktrees go SILENT under the old `ignored == 0` tier-1 gate) exactly as they did on the box.
A_ORIGIN="$TMP/a-origin.git"; A_REPO="$TMP/a-repo"
git init -q --bare -b main "$A_ORIGIN"
git init -q -b main "$A_REPO"
g "$A_REPO" config user.email t@example.com; g "$A_REPO" config user.name smoke
echo hello > "$A_REPO/f.txt"; g "$A_REPO" add f.txt
# `.env` is the off-allowlist ignored pattern Case E uses below: the local-secrets case the ignored veto
# was built for, which must keep vetoing after the allowlist widens.
printf '__pycache__/\n*.pyc\n*.run.log\n.env\n' > "$A_REPO/.gitignore"; g "$A_REPO" add .gitignore
g "$A_REPO" commit -q -m init
g "$A_REPO" remote add origin "$A_ORIGIN"; g "$A_REPO" push -q origin main

for w in allow-ok allow-nonmember allow-unsuperseded allow-ignored-only allow-ignored-veto; do
  g "$A_REPO" worktree add -q -b "feat-$w" "$TMP/wt-$w" main
  GIT_COMMITTER_DATE="$OLD_DATE" git -C "$TMP/wt-$w" commit -q --allow-empty -m "old-$w" --date="$OLD_DATE"
  g "$A_REPO" merge -q --no-edit "feat-$w"
done
g "$A_REPO" push -q origin main

# main then lands the POST-RUN form of the design-stage record files, from its own branch — so every
# worktree above is merged-and-BEHIND and its own copies read untracked, exactly as on the box.
mkdir -p "$A_REPO/registry/exp-1"
printf 'post-run checklist\n' > "$A_REPO/registry/exp-1/CHECKLIST.md"
printf 'post-run start\n'     > "$A_REPO/registry/exp-1/START.md"
printf 'post-run audit\n'     > "$A_REPO/registry/exp-1/DESIGN_AUDIT2.md"
g "$A_REPO" add registry/exp-1
g "$A_REPO" commit -q -m "close landed registry/exp-1 in post-run form"
g "$A_REPO" push -q origin main

# Case A: every non-identical path is on the allowlist. `AUDIT.md.run.log` and the __pycache__ entry exist
# nowhere on main (the REGENERABLE class needs no main copy); the three record files are the SUPERSEDED
# class and carry DIFFERENT bytes from main's post-run copies, which is precisely what #804's bar refuses.
# `registry/exp-1/RESULTS.md` is a byte-identical duplicate, proving the two bars compose in one worktree.
mkdir -p "$TMP/wt-allow-ok/registry/exp-1" "$TMP/wt-allow-ok/pipelines/__pycache__"
printf 'auditor transcript\n'  > "$TMP/wt-allow-ok/registry/exp-1/AUDIT.md.run.log"
printf 'design-stage form\n'   > "$TMP/wt-allow-ok/registry/exp-1/CHECKLIST.md"
printf 'design-stage start\n'  > "$TMP/wt-allow-ok/registry/exp-1/START.md"
printf 'design-stage audit\n'  > "$TMP/wt-allow-ok/registry/exp-1/DESIGN_AUDIT2.md"
printf 'claude-1\n'            > "$TMP/wt-allow-ok/registry/exp-1/CLAIMED_BY"
printf 'not-really-bytecode\n' > "$TMP/wt-allow-ok/pipelines/__pycache__/driver.cpython-311.pyc"
# ...and a NON-.pyc file inside __pycache__, so the directory-COMPONENT rule is exercised on its own rather
# than being masked by the `*.pyc` basename rule that would admit the file above anyway.
printf '{}\n' > "$TMP/wt-allow-ok/pipelines/__pycache__/index.json"
# Case B: the same allowlisted residue PLUS one ordinary file — one off-allowlist path is enough.
mkdir -p "$TMP/wt-allow-nonmember/registry/exp-1"
printf 'auditor transcript\n' > "$TMP/wt-allow-nonmember/registry/exp-1/AUDIT.md.run.log"
printf 'hand-written notes that exist nowhere else\n' > "$TMP/wt-allow-nonmember/NOTES.md"
# Case C: a SUPERSEDED-class basename at a path main does NOT carry — no main copy means nothing supersedes
# it, so it is unique content however familiar the filename looks.
mkdir -p "$TMP/wt-allow-unsuperseded/registry/exp-9"
printf 'the only copy of this record\n' > "$TMP/wt-allow-unsuperseded/registry/exp-9/CHECKLIST.md"
# Case D: the measured production shape — a merged worktree that is tracked-clean with ZERO untracked
# paths, whose entire residue is IGNORED and entirely allowlisted. Pre-fix this is the case that made the
# feature inert: `git status` reports these as `!!`, the dirty/untracked allowlist scan never saw them, and
# the `ignored == 0` tier-1 gate sent the worktree to SILENT — reported nowhere, reaped never.
mkdir -p "$TMP/wt-allow-ignored-only/pipelines/__pycache__" "$TMP/wt-allow-ignored-only/registry/exp-1"
printf 'auditor transcript\n'  > "$TMP/wt-allow-ignored-only/registry/exp-1/AUDIT.md.run.log"
printf 'not-really-bytecode\n' > "$TMP/wt-allow-ignored-only/pipelines/__pycache__/driver.cpython-311.pyc"
printf '{}\n'                  > "$TMP/wt-allow-ignored-only/pipelines/__pycache__/index.json"
printf 'loose bytecode\n'      > "$TMP/wt-allow-ignored-only/loose.pyc"
# Case E: allowlisted ignored residue PLUS one OFF-allowlist ignored file. The "one off-allowlist path
# keeps the whole worktree out" rule has to hold in the ignored category too, or the widening would have
# quietly turned the local-secrets veto into a blanket "ignored content is fine".
mkdir -p "$TMP/wt-allow-ignored-veto/pipelines/__pycache__"
printf 'not-really-bytecode\n' > "$TMP/wt-allow-ignored-veto/pipelines/__pycache__/driver.cpython-311.pyc"
printf 'SECRET=hunter2\n'      > "$TMP/wt-allow-ignored-veto/.env"

# CLAIMED_BY is the design-stage claim file; main carries none, so it must NOT be admitted on Case A above
# unless main holds that exact path. Land it so Case A's own CLAIMED_BY has its warrant.
printf 'closed\n' > "$A_REPO/registry/exp-1/CLAIMED_BY"
g "$A_REPO" add registry/exp-1/CLAIMED_BY
g "$A_REPO" commit -q -m "claim record landed"
g "$A_REPO" push -q origin main
# ...and the byte-identical duplicate, added after main carries it so the bytes really match.
printf 'post-run results\n' > "$A_REPO/registry/exp-1/RESULTS.md"
g "$A_REPO" add registry/exp-1/RESULTS.md
g "$A_REPO" commit -q -m "results landed"
g "$A_REPO" push -q origin main
printf 'post-run results\n' > "$TMP/wt-allow-ok/registry/exp-1/RESULTS.md"

J_A=$(python3 "$SWEEP" --json --repo "$A_REPO" 2>/dev/null)
if echo "$J_A" | has_path_in "d['tier1']" "$TMP/wt-allow-ok"; then ok "residue-allowlist: merged worktree whose non-identical residue is all allowlisted reaches tier1"; else no "residue-allowlist: allowlisted-residue worktree NOT classified tier1 (#840 defect not fixed)"; fi
if echo "$J_A" | reason_has "d['tier1']" "$TMP/wt-allow-ok" "reap allowlist"; then ok "residue-allowlist: tier1 reason names the allowlist basis"; else no "residue-allowlist: tier1 reason doesn't name the allowlist"; fi
if echo "$J_A" | reason_has "d['tier1']" "$TMP/wt-allow-ok" "*.run.log"; then ok "residue-allowlist: tier1 reason spells the allowlist members out"; else no "residue-allowlist: tier1 reason doesn't spell out the allowlist members"; fi
if echo "$J_A" | has_path_in "d['tier1']" "$TMP/wt-allow-nonmember"; then no "residue-allowlist: one off-allowlist file did NOT keep the worktree out of tier1 (unique content would be lost)"; else ok "residue-allowlist: a single off-allowlist file keeps the worktree out of tier1"; fi
if echo "$J_A" | has_path_in "d['tier3']" "$TMP/wt-allow-nonmember"; then ok "residue-allowlist: off-allowlist residue reported in tier3"; else no "residue-allowlist: off-allowlist worktree reported in neither tier1 nor tier3"; fi
if echo "$J_A" | has_path_in "d['tier1']" "$TMP/wt-allow-unsuperseded"; then no "residue-allowlist: a SUPERSEDED-class basename with no copy on main wrongly reached tier1 (its only copy would be lost)"; else ok "residue-allowlist: a superseded-class basename main does not carry is correctly excluded"; fi

# The ignored category (Codex review of PR #842). Case A above already proves the mixed shape — its
# `*.run.log` and `__pycache__` paths are IGNORED under the fixture's .gitignore while its record files are
# untracked — so these add the two pure cases either side of the line.
if echo "$J_A" | has_path_in "d['tier1']" "$TMP/wt-allow-ignored-only"; then ok "ignored-allowlist: merged worktree whose only residue is ignored+allowlisted reaches tier1"; else no "ignored-allowlist: ignored-only allowlisted worktree NOT classified tier1 (the allowlist is inert against the category it actually meets on a box)"; fi
if echo "$J_A" | reason_has "d['tier1']" "$TMP/wt-allow-ignored-only" "ignored path(s)"; then ok "ignored-allowlist: tier1 reason states that ignored paths are being reaped, not just 'clean'"; else no "ignored-allowlist: tier1 reason hides the ignored content the reap will delete"; fi
if echo "$J_A" | reason_has "d['tier1']" "$TMP/wt-allow-ignored-only" "reap allowlist"; then ok "ignored-allowlist: tier1 reason names the allowlist that admitted the ignored paths"; else no "ignored-allowlist: tier1 reason doesn't name the allowlist basis for the ignored paths"; fi
if echo "$J_A" | has_path_in "d['tier1']" "$TMP/wt-allow-ignored-veto"; then no "ignored-allowlist: one OFF-allowlist ignored file did NOT keep the worktree out of tier1 (a local .env would be destroyed)"; else ok "ignored-allowlist: a single off-allowlist ignored file keeps the whole worktree out of tier1"; fi
ALL_A=$(echo "$J_A" | all_paths)
if grep -qxF "$TMP/wt-allow-ignored-veto" <<<"$ALL_A"; then no "ignored-allowlist: off-allowlist ignored content should stay SILENT (build-cache-like clutter must not nag weekly), not be reported"; else ok "ignored-allowlist: off-allowlist ignored content is silent, exactly as before the allowlist widened"; fi

python3 "$SWEEP" --repo "$A_REPO" --reap-tier1 >/dev/null 2>&1 || true
if [ -d "$TMP/wt-allow-ok" ]; then no "residue-allowlist: allowlisted-residue worktree NOT removed by --reap-tier1 (reap-time re-verification regressed)"; else ok "residue-allowlist: allowlisted-residue worktree removed by --reap-tier1"; fi
if [ -d "$TMP/wt-allow-nonmember" ]; then ok "residue-allowlist: off-allowlist worktree preserved by --reap-tier1"; else no "residue-allowlist: off-allowlist worktree was WRONGLY removed (hand-written notes lost)"; fi
if [ -d "$TMP/wt-allow-unsuperseded" ]; then ok "residue-allowlist: unsuperseded record worktree preserved by --reap-tier1"; else no "residue-allowlist: unsuperseded record worktree was WRONGLY removed (only copy lost)"; fi
# The reap-time re-verification runs the ignored allowlist in the same shape classification does — if it
# still gated on `ignored == 0`, every one of these items would classify tier1 and then SKIP forever.
if [ -d "$TMP/wt-allow-ignored-only" ]; then no "ignored-allowlist: ignored-only worktree NOT removed by --reap-tier1 (reap-time gate disagrees with classification)"; else ok "ignored-allowlist: ignored-only allowlisted worktree really removed by --reap-tier1"; fi
if [ -f "$TMP/wt-allow-ignored-veto/.env" ]; then ok "ignored-allowlist: the off-allowlist ignored file survived a real --reap-tier1"; else no "ignored-allowlist: a local .env was DESTROYED by the reap"; fi
if [ -f "$A_REPO/registry/exp-1/CHECKLIST.md" ]; then ok "residue-allowlist: main's own post-run record copies are untouched"; else no "residue-allowlist: the swept checkout's own record file disappeared"; fi

# 3f4. automated-researcher#840: the age bar is PER TIER — merged clears at --merged-min-age-days (default
#      2), unmerged stays at --min-age-days (default 7). Measured cause: at ~10G of residue per closed
#      experiment and roughly a close a day, the 7-day bar WAS the steady-state fill — the disk refilled
#      before the bar expired. Both directions are asserted, since a bar that only ever loosens is not a
#      bar: the flags must be able to move each class independently.
MID_DATE=$(date -u -d '-3 days' +%Y-%m-%dT%H:%M:%S 2>/dev/null || echo "2026-07-07T00:00:00")
B_ORIGIN="$TMP/b-origin.git"; B_REPO="$TMP/b-repo"
git init -q --bare -b main "$B_ORIGIN"
git init -q -b main "$B_REPO"
g "$B_REPO" config user.email t@example.com; g "$B_REPO" config user.name smoke
echo hello > "$B_REPO/f.txt"; g "$B_REPO" add f.txt; g "$B_REPO" commit -q -m init
g "$B_REPO" remote add origin "$B_ORIGIN"; g "$B_REPO" push -q origin main
# merged + clean, 3 days old: inside the old 7-day bar, past the new 2-day merged one.
g "$B_REPO" worktree add -q -b feat-mid-merged "$TMP/wt-mid-merged" main
GIT_COMMITTER_DATE="$MID_DATE" git -C "$TMP/wt-mid-merged" commit -q --allow-empty -m mid --date="$MID_DATE"
g "$B_REPO" merge -q --no-edit feat-mid-merged
g "$B_REPO" push -q origin main
# unmerged with unique committed content, same 3 days old: must stay SILENT — the shorter bar is the
# merged one only, and for an unmerged tree the age IS the evidence nobody is continuing it.
g "$B_REPO" worktree add -q -b mid-unmerged "$TMP/wt-mid-unmerged" main
printf 'unique-unmerged\n' > "$TMP/wt-mid-unmerged/only-here.txt"
git -C "$TMP/wt-mid-unmerged" add only-here.txt >/dev/null 2>&1
GIT_COMMITTER_DATE="$MID_DATE" git -C "$TMP/wt-mid-unmerged" commit -q -m midunmerged --date="$MID_DATE"

J_B=$(python3 "$SWEEP" --json --repo "$B_REPO" 2>/dev/null)
if echo "$J_B" | has_path_in "d['tier1']" "$TMP/wt-mid-merged"; then ok "age-bar: a merged worktree 3d old reaches tier1 under the default 2-day merged bar"; else no "age-bar: merged 3d-old worktree did not reach tier1 (the per-tier bar isn't applied)"; fi
if echo "$J_B" | all_paths | grep -qxF "$TMP/wt-mid-unmerged"; then no "age-bar: an UNMERGED 3d-old worktree was flagged (the 7-day bar must still hold for unmerged trees)"; else ok "age-bar: an unmerged 3d-old worktree stays silent under the unchanged 7-day bar"; fi

J_B7=$(python3 "$SWEEP" --json --repo "$B_REPO" --merged-min-age-days 7 2>/dev/null)
if echo "$J_B7" | all_paths | grep -qxF "$TMP/wt-mid-merged"; then no "age-bar: --merged-min-age-days 7 did not put the 3d-old merged worktree back inside its grace window"; else ok "age-bar: --merged-min-age-days 7 keeps the 3d-old merged worktree silent"; fi
J_B2=$(python3 "$SWEEP" --json --repo "$B_REPO" --min-age-days 2 2>/dev/null)
if echo "$J_B2" | has_path_in "d['tier3']" "$TMP/wt-mid-unmerged"; then ok "age-bar: --min-age-days 2 flags the 3d-old unmerged worktree (the unmerged bar is independently movable)"; else no "age-bar: --min-age-days 2 did not flag the 3d-old unmerged worktree"; fi
python3 "$SWEEP" --repo "$B_REPO" --merged-min-age-days -1 >/dev/null 2>&1 && no "age-bar: negative --merged-min-age-days accepted" || ok "age-bar: negative --merged-min-age-days rejected"

# 3f5. automated-researcher#840: --worktree-root is REPEATABLE, so the harness's own worktree root gets the
#      same owner-liveness tier rules as the agent-workspace root. Measured cause: 5 harness worktrees
#      (12.8G) were "seen but never reaped" — they derived NO owner, so the live-owner veto never applied
#      to them in either direction. The nested-root case pins the most-specific-match rule, so the answer
#      cannot depend on flag order.
C_ORIGIN="$TMP/c-origin.git"; C_REPO="$TMP/c-repo"
git init -q --bare -b main "$C_ORIGIN"
git init -q -b main "$C_REPO"
g "$C_REPO" config user.email t@example.com; g "$C_REPO" config user.name smoke
echo hello > "$C_REPO/f.txt"; g "$C_REPO" add f.txt; g "$C_REPO" commit -q -m init
g "$C_REPO" remote add origin "$C_ORIGIN"; g "$C_REPO" push -q origin main
WS2="$TMP/ws2"; HARNESS="$TMP/ws2/harness-worktrees"; mkdir -p "$WS2" "$HARNESS"
for spec in "$WS2/agent-x:ws-x" "$HARNESS/agent-y:hn-y"; do
  d=${spec%%:*}; b=${spec##*:}
  g "$C_REPO" worktree add -q -b "$b" "$d" main
  GIT_COMMITTER_DATE="$OLD_DATE" git -C "$d" commit -q --allow-empty -m "old-$b" --date="$OLD_DATE"
  g "$C_REPO" merge -q --no-edit "$b"
done
g "$C_REPO" push -q origin main

# With only the workspace root named, the harness tree's owner id would be the nested-root-relative
# "harness-worktrees" — the live seam names "agent-y", so the veto can only fire once the harness root is
# named too. That contrast IS the fix.
LIVEY="$TMP/live-y.sh"; printf '#!/bin/sh\necho agent-y\n' > "$LIVEY"; chmod +x "$LIVEY"
J_C1=$(REPO_JANITOR_LIVE_SESSIONS_CMD="$LIVEY" python3 "$SWEEP" --json --repo "$C_REPO" --worktree-root "$WS2" 2>/dev/null)
if echo "$J_C1" | has_path_in "d['tier1']" "$HARNESS/agent-y"; then ok "worktree-root: with only the workspace root named, the harness tree derives no live owner (the pre-#840 gap)"; else no "worktree-root: fixture did not reproduce the pre-#840 no-owner state for the harness tree"; fi
J_C2=$(REPO_JANITOR_LIVE_SESSIONS_CMD="$LIVEY" python3 "$SWEEP" --json --repo "$C_REPO" --worktree-root "$WS2" --worktree-root "$HARNESS" 2>/dev/null)
if echo "$J_C2" | has_path_in "d['tier2']" "$HARNESS/agent-y"; then ok "worktree-root: a second --worktree-root gives the harness tree the live-owner tier-2 veto"; else no "worktree-root: repeatable --worktree-root did not route the harness tree to tier2 for its live owner"; fi
if echo "$J_C2" | has_path_in "d['tier1']" "$WS2/agent-x"; then ok "worktree-root: the workspace root's own not-live tree still reaches tier1"; else no "worktree-root: naming a second root broke the first root's classification"; fi
OWNER_Y=$(echo "$J_C2" | python3 -c "
import json,sys
d=json.load(sys.stdin)
print(next((e['owner'] for v in d['tier2'].values() for e in v if e['path']=='$HARNESS/agent-y'), ''))
")
[ "$OWNER_Y" = "agent-y" ] && ok "worktree-root: the owner id comes from the MOST SPECIFIC (longest) matching root, not flag order" || no "worktree-root: owner id was '$OWNER_Y', expected 'agent-y' from the nested harness root"
python3 "$SWEEP" --repo "$C_REPO" --worktree-root "   " >/dev/null 2>&1 && no "worktree-root: whitespace-only --worktree-root accepted (would realpath to the cwd)" || ok "worktree-root: whitespace-only --worktree-root rejected"

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

# Second worktree (senior-engineer round, automated-researcher#537): extends the same unmapped-gitlink
# fixture with a genuinely INITIALIZED submodule at a TAB-containing path. `git ls-files -s` (without -z)
# C-quotes a tab-containing path (e.g. a literal `dir<TAB>tab/inner` renders as `"dir\ttab/inner"`, literal
# backslash-t and all) in its default output, so a plain-line parse of the fallback scan would probe that
# literal quoted spelling on disk and miss the real path -- `-z` emits the raw, unquoted path instead,
# letting the fallback correctly find this submodule and keep the worktree OUT of tier 1, even though `git
# submodule status` itself already fails here too (same unrelated `badlink` gitlink as wt-um-merged above).
g "$UM_REPO" worktree add -q -b feat-um-quoted-submodule "$TMP/wt-um-quoted" main
QUOTED_REL=$'dir\ttab/inner'
mkdir -p "$TMP/wt-um-quoted/$QUOTED_REL"
git init -q -b main "$TMP/wt-um-quoted/$QUOTED_REL"
g "$TMP/wt-um-quoted/$QUOTED_REL" config user.email t@example.com
g "$TMP/wt-um-quoted/$QUOTED_REL" config user.name smoke
git -C "$TMP/wt-um-quoted" update-index --add --cacheinfo 160000,$FAKESHA,"$QUOTED_REL"
GIT_COMMITTER_DATE="$OLD_DATE" git -C "$TMP/wt-um-quoted" commit -q -m addquotedgitlink --date="$OLD_DATE"
g "$UM_REPO" merge -q --no-edit feat-um-quoted-submodule
g "$UM_REPO" push -q origin main

if git -C "$UM_REPO" submodule status >/dev/null 2>&1; then no "fixture setup: expected 'git submodule status' to fail on the unmapped gitlink (fixture doesn't reproduce the real trigger)"; else ok "fixture: 'git submodule status' fails on the unmapped gitlink, as in the real 2026-07-19 trigger"; fi

J_UM=$(python3 "$SWEEP" --json --repo "$UM_REPO" 2>/dev/null)
if echo "$J_UM" | has_path_in "d['tier1']" "$TMP/wt-um-merged"; then ok "unmapped-gitlink degradation: merged+clean+old worktree still reaches tier1 (submodule fact degrades per-path instead of poisoning UNKNOWN)"; else no "unmapped-gitlink poisoned tier1 classification (submodule check failure not degraded)"; fi
if echo "$J_UM" | has_path_in "d['tier1']" "$TMP/wt-um-quoted"; then no "quoted-path fallback: worktree with an initialized submodule at a tab-quoted path WRONGLY reached tier1 (fallback failed to find it)"; else ok "quoted-path fallback: worktree with an initialized submodule at a tab-quoted path correctly excluded from tier1"; fi
if echo "$J_UM" | reason_has "d['tier3']" "$TMP/wt-um-quoted" "submodule"; then ok "quoted-path fallback: tier3 reason names the initialized submodule"; else no "quoted-path fallback: tier3 reason for wt-um-quoted missing the submodule note"; fi

# 3h. round-2 Codex review, automated-researcher#537 P0: do_reap's re-verification must re-check
#     submodule_fact() too, not just status/identity/HEAD -- a worktree can gain an INITIALIZED submodule in
#     the gap between classification and the reap loop's --force removal, and `git worktree remove --force`
#     doesn't spare submodule content just because the surrounding tree read as clean/submodule-free at
#     classification time. Classification and reap are exercised directly (not via the CLI in one shot) so a
#     real submodule-init can land in that exact gap.
RACE_SUBORIGIN="$TMP/race-sub-origin.git"; RACE_SUBREPO="$TMP/race-sub"
git init -q --bare -b main "$RACE_SUBORIGIN"
git init -q -b main "$RACE_SUBREPO"
g "$RACE_SUBREPO" config user.email t@example.com; g "$RACE_SUBREPO" config user.name smoke
echo subfile > "$RACE_SUBREPO/s.txt"; g "$RACE_SUBREPO" add s.txt; g "$RACE_SUBREPO" commit -q -m subinit
g "$RACE_SUBREPO" remote add origin "$RACE_SUBORIGIN"; g "$RACE_SUBREPO" push -q origin main

RACE_ORIGIN="$TMP/race-origin.git"; RACE_REPO="$TMP/race-repo"
git init -q --bare -b main "$RACE_ORIGIN"
git init -q -b main "$RACE_REPO"
g "$RACE_REPO" config user.email t@example.com; g "$RACE_REPO" config user.name smoke
echo hello > "$RACE_REPO/f.txt"; g "$RACE_REPO" add f.txt; g "$RACE_REPO" commit -q -m init
g "$RACE_REPO" remote add origin "$RACE_ORIGIN"; g "$RACE_REPO" push -q origin main
g "$RACE_REPO" -c protocol.file.allow=always submodule add -q "$RACE_SUBORIGIN" subm
g "$RACE_REPO" commit -q -m addsubmodule
g "$RACE_REPO" push -q origin main

g "$RACE_REPO" worktree add -q -b feat-race-submodule "$TMP/wt-race-submodule" main
GIT_COMMITTER_DATE="$OLD_DATE" git -C "$TMP/wt-race-submodule" commit -q --allow-empty -m oldrace --date="$OLD_DATE"
g "$RACE_REPO" merge -q --no-edit feat-race-submodule
g "$RACE_REPO" push -q origin main
# submodule intentionally left UNINITIALIZED here -> has_submodule reads False right now, so this worktree
# genuinely, correctly classifies as tier1 at this moment.

python3 -c "
import sys, subprocess, time
sys.path.insert(0, '$HERE')
import worktree_sweep as ws

args = ws.build_parser().parse_args(['--repo', '$RACE_REPO'])
results = {'tier1': [], 'tier2': {}, 'tier3': []}
reap_plan = []
ws.process_repo('$RACE_REPO', args, set(), False, int(time.time()), results, reap_plan)
assert any(i['path'] == '$TMP/wt-race-submodule' for i in results['tier1']), \
    'fixture did not classify as tier1 as expected: ' + str(results)

# Simulate the race: the submodule is initialized AFTER classification, BEFORE the reap loop runs.
subprocess.run(['git', '-C', '$TMP/wt-race-submodule', '-c', 'protocol.file.allow=always',
                'submodule', 'update', '--init', '-q'], check=True)

ws.do_reap(reap_plan, False, 'main', args.min_age_days, (set(), set()), int(time.time()))
"
if [ -d "$TMP/wt-race-submodule" ]; then ok "reap re-verification: worktree that gained an initialized submodule mid-run is SKIPPED, not force-removed"; else no "reap re-verification: worktree with a newly-initialized submodule was WRONGLY removed (submodule safety gate not re-checked before --force)"; fi

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

assert '[8 entries, same root cause] inspection needed: shared root cause' in out, 'shared reason not collapsed:\n' + out
assert out.count('git -C /wt/') == 2, 'collapsed entries must not repeat action commands: ' + out
assert 'distinct reason 0' in out and 'distinct reason 1' in out, 'distinct (non-repeated) reasons must still render individually: ' + out

# round-2 Codex review, automated-researcher#537 P1: a group whose size lands EXACTLY on collapse_at (5
# identical entries alone in the group -> collapse_at == max(5, 5*0.2) == 5) must still collapse — the
# documented threshold is 'at least', an inclusive bound, not a strict '>'.
boundary = [entry(200 + i, 'inspection needed: boundary root cause') for i in range(5)]
results2 = {'tier1': [], 'tier2': {}, 'tier3': boundary}
buf2 = io.StringIO()
with contextlib.redirect_stdout(buf2):
    ws.render_text(results2)
out2 = buf2.getvalue()
assert '[5 entries, same root cause] inspection needed: boundary root cause' in out2, \
    'group exactly at collapse_at was not collapsed (off-by-one on the inclusive threshold):\n' + out2
" && ok "report ergonomics: a reason shared by most of a tier collapses; distinct reasons still render individually; a group exactly at the collapse threshold still collapses" || no "report ergonomics: collapse behavior check failed"

# 8. --scratch-glob: the non-git scratch prune (automated-researcher#792). The disk-fill incident's third
#    bucket was `*-repro.*` / per-session dirs under /tmp that nothing ever deleted. Covered here:
#    stale -> tier1 and actually deleted; fresh -> silent; a dir whose OWN mtime is old but which carries a
#    freshly-written file -> silent (the tree's newest mtime is the fact, not the directory's); a symlink,
#    and anything protecting a swept checkout, -> tier3 and never deleted; --dry-run deletes nothing; and
#    the pattern validation that keeps the delete scope statically bounded.
SCRATCH="$TMP/scratchroot"; mkdir -p "$SCRATCH"

# The mount guard reads the box's REAL mount table for every case except the mount block at the end, and
# on a Linux runner nothing is mounted at or under $TMP. On a platform with no /proc/self/mountinfo it
# would (correctly) read UNKNOWN and route every scratch entry to tier 3, so point the seam at a synthetic
# single-root table there instead — the rest of this section then exercises the same path it does on Linux.
if [ ! -r /proc/self/mountinfo ]; then
  echo "27 2 8:1 / / rw - ext4 /dev/root rw" > "$TMP/mountinfo-baseline"
  export REPO_JANITOR_MOUNTINFO="$TMP/mountinfo-baseline"
fi

# mkmountinfo <file> <mount-point>... — a mountinfo fixture (a real `mount --bind` needs root). Field 5 is
# the mount point; the caller passes it already octal-escaped where it needs to be.
mkmountinfo(){
  local f=$1; shift
  echo "27 2 8:1 / / rw - ext4 /dev/root rw" > "$f"
  local n=28
  for mp in "$@"; do echo "$n 27 0:$n / $mp rw - tmpfs tmpfs rw" >> "$f"; n=$((n+1)); done
}

mk_old(){ # mk_old <dir> — a scratch dir whose whole tree is 40 days old
  mkdir -p "$1"; echo payload > "$1/data.bin"
  touch -d "$OLD_DATE" "$1/data.bin"; touch -d "$OLD_DATE" "$1"
}
mk_old "$SCRATCH/stale-repro.aaa"
mk_old "$SCRATCH/stale2-repro.bbb"
mk_old "$SCRATCH/dryrun-repro.ccc"

mkdir -p "$SCRATCH/fresh-repro.ddd"; echo payload > "$SCRATCH/fresh-repro.ddd/data.bin"

# old directory mtime, FRESH file inside — the case a naive `stat` of the directory would delete
mk_old "$SCRATCH/live-repro.eee"; echo busy > "$SCRATCH/live-repro.eee/active.log"
touch -d "$OLD_DATE" "$SCRATCH/live-repro.eee"

# symlink whose target is old: must be reported, never followed and never deleted
mk_old "$TMP/link-target-dir"
ln -s "$TMP/link-target-dir" "$SCRATCH/linked-repro.fff"

# A real linked worktree of a SWEPT repo, sitting inside the scratch root: protected, never rm -rf'd.
# Given novel untracked content deliberately, so it is NOT tier-1-eligible as a WORKTREE either -- otherwise
# `git worktree remove` would legitimately reap it and this assertion could never tell the scratch-side
# protection working from the worktree path removing it for unrelated, correct reasons.
g "$REPO" worktree add -q -b scratch-guard "$SCRATCH/checkout-repro.ggg" main
echo novel-guard-content-not-on-main > "$SCRATCH/checkout-repro.ggg/guard-note.txt"

# A BARE repository, fully aged out so every age fact says "reap me": it carries no `.git` entry at all
# (HEAD + objects/ + refs/ sit at its top level), so a `.git`-only repo guard would hand a whole object
# database to `rm -rf`. Round-1 code-review Finding 3 — the loss here is unrecoverable, unlike scratch.
git init --bare -q "$SCRATCH/bare-repro.iii"
find "$SCRATCH/bare-repro.iii" -exec touch -d "$OLD_DATE" {} +

# A checkout whose `.git` is a DANGLING SYMLINK — its gitdir moved, or the linked worktree's admin dir was
# pruned. `os.path.exists()` answers False for it, so a resolution-based repo guard would classify a whole
# working tree as ordinary scratch and `rm -rf` it (round-2 code-review Finding 1); this is also precisely
# the checkout least likely to have its contents pushed anywhere. Name presence is the fact, not
# resolvability. Also aged out fully, so nothing but the repo guard can keep it out of tier 1.
mk_old "$SCRATCH/dangling-repro.jjj"
ln -s "$TMP/gitdir-that-was-moved-away" "$SCRATCH/dangling-repro.jjj/.git"
touch -h -d "$OLD_DATE" "$SCRATCH/dangling-repro.jjj/.git"
touch -d "$OLD_DATE" "$SCRATCH/dangling-repro.jjj"

# A bare repo missing `refs/` — half-cloned, or an atypical layout. git's own is_git_directory() trio
# would say "not a repository" and hand its object database to `rm -rf`; the guard is deliberately broader
# than that trio because it is choosing between reporting an entry and destroying it.
mkdir -p "$SCRATCH/partial-repro.kkk/objects"
echo "ref: refs/heads/main" > "$SCRATCH/partial-repro.kkk/HEAD"
find "$SCRATCH/partial-repro.kkk" -exec touch -d "$OLD_DATE" {} +

GLOB="$SCRATCH/*-repro.*"

python3 "$SWEEP" --repo "$REPO" --scratch-glob "$GLOB" --json 2>/dev/null > "$TMP/scratch.json"
has_path_in "d['tier1']" "$SCRATCH/stale-repro.aaa"     < "$TMP/scratch.json" && ok "scratch: stale entry is tier1" || no "scratch: stale entry is tier1"
has_path_in "d['tier1']" "$SCRATCH/fresh-repro.ddd"     < "$TMP/scratch.json" && no "scratch: fresh entry must be SILENT, not tier1" || ok "scratch: fresh entry is silent"
has_path_in "d['tier1']" "$SCRATCH/live-repro.eee"      < "$TMP/scratch.json" && no "scratch: old dir mtime with a fresh file inside must NOT be tier1 (tree newest-mtime, not dir mtime)" || ok "scratch: actively-written tree with an old dir mtime is silent"
has_path_in "d['tier3']" "$SCRATCH/linked-repro.fff"    < "$TMP/scratch.json" && ok "scratch: symlink entry routes to tier3" || no "scratch: symlink entry routes to tier3"
has_path_in "d['tier1']" "$SCRATCH/linked-repro.fff"    < "$TMP/scratch.json" && no "scratch: symlink entry must never be tier1" || ok "scratch: symlink entry never tier1"
has_path_in "d['tier3']" "$SCRATCH/checkout-repro.ggg"  < "$TMP/scratch.json" && ok "scratch: a swept repo's worktree inside the glob routes to tier3 (protected)" || no "scratch: protected checkout must route to tier3"
has_path_in "d['tier3']" "$SCRATCH/bare-repro.iii"      < "$TMP/scratch.json" && ok "scratch: an aged-out BARE repo routes to tier3" || no "scratch: aged-out bare repo must route to tier3"
has_path_in "d['tier1']" "$SCRATCH/bare-repro.iii"      < "$TMP/scratch.json" && no "scratch: a bare repo must never be tier1 (no .git entry, but still a repository)" || ok "scratch: bare repo never tier1"
has_path_in "d['tier3']" "$SCRATCH/dangling-repro.jjj" < "$TMP/scratch.json" && ok "scratch: a checkout with a DANGLING .git symlink routes to tier3" || no "scratch: dangling .git symlink must route to tier3"
has_path_in "d['tier1']" "$SCRATCH/dangling-repro.jjj" < "$TMP/scratch.json" && no "scratch: a dangling .git symlink must never be tier1 (name presence is the fact, not resolvability)" || ok "scratch: dangling .git symlink never tier1"
has_path_in "d['tier3']" "$SCRATCH/partial-repro.kkk" < "$TMP/scratch.json" && ok "scratch: a bare repo missing refs/ still routes to tier3" || no "scratch: partial bare repo must route to tier3"
has_path_in "d['tier1']" "$SCRATCH/partial-repro.kkk" < "$TMP/scratch.json" && no "scratch: a bare repo missing refs/ must never be tier1 (the guard is broader than git's is_git_directory trio)" || ok "scratch: partial bare repo never tier1"
# Kind-scoped on purpose: this path is legitimately reported TWICE (once as a git worktree with untracked
# content, once as a scratch match), so a first-match-wins reason check would read the worktree entry.
python3 -c "
import json, sys
d = json.load(sys.stdin)
e = [x for x in d['tier3'] if x['path'] == '$SCRATCH/checkout-repro.ggg' and x['kind'] == 'scratch']
assert e and 'protected path' in e[0]['reason'], d['tier3']
" < "$TMP/scratch.json" && ok "scratch: protected reason names the protection" || no "scratch: protected reason names the protection"
python3 -c "
import json, sys
d = json.load(sys.stdin)
e = [x for x in d['tier1'] if x['path'] == '$SCRATCH/stale-repro.aaa'][0]
assert e['kind'] == 'scratch', e
assert e['action']['kind'] == 'delete', e
assert e['action']['commands'] == ['rm -rf -- $SCRATCH/stale-repro.aaa'], e
" < "$TMP/scratch.json" && ok "scratch: tier1 entry carries kind=scratch + a delete action" || no "scratch: tier1 entry shape"

# The cwd (and $HOME) protect themselves and their ANCESTORS, never their contents: a scratch root is
# routinely under one or both, so a containment-based guard there would silently disqualify every match
# the glob was configured for. Running the sweep from inside the scratch root must change nothing.
(cd "$SCRATCH" && python3 "$SWEEP" --repo "$REPO" --scratch-glob "$GLOB" --json 2>/dev/null) > "$TMP/scratch-cwd.json"
has_path_in "d['tier1']" "$SCRATCH/stale2-repro.bbb" < "$TMP/scratch-cwd.json" \
  && ok "scratch: a sweep run from inside the scratch root still classifies its entries (cwd protects itself, not its contents)" \
  || no "scratch: cwd inside the scratch root wrongly disqualified every entry"

# --dry-run touches nothing, and records dry-run outcomes in the report
python3 "$SWEEP" --repo "$REPO" --scratch-glob "$GLOB" --reap-tier1 --dry-run --json 2>/dev/null > "$TMP/scratch-dry.json"
[ -d "$SCRATCH/dryrun-repro.ccc" ] && ok "scratch: --dry-run deleted nothing" || no "scratch: --dry-run DELETED a scratch dir"
python3 -c "
import json, sys
d = json.load(sys.stdin)
outs = {r['path']: r['outcome'] for r in d['reaped']}
assert outs.get('$SCRATCH/stale-repro.aaa') == 'dry-run', d['reaped']
" < "$TMP/scratch-dry.json" && ok "scratch: --dry-run reports a dry-run outcome per planned deletion" || no "scratch: --dry-run outcome record"

# The real reap. `|| true`: this repo still carries the LOCKED tier-1 worktree from step 5, whose removal
# genuinely fails every run, so the sweep legitimately exits non-zero here — that exit code is already
# asserted in step 5 and must not abort this script under `set -e`.
python3 "$SWEEP" --repo "$REPO" --scratch-glob "$GLOB" --reap-tier1 --json 2>/dev/null > "$TMP/scratch-reap.json" || true
[ -d "$SCRATCH/stale-repro.aaa" ]    && no "scratch: stale entry NOT deleted by --reap-tier1" || ok "scratch: stale entry deleted by --reap-tier1"
[ -d "$SCRATCH/fresh-repro.ddd" ]    && ok "scratch: fresh entry survives --reap-tier1" || no "scratch: fresh entry was deleted"
[ -d "$SCRATCH/live-repro.eee" ]     && ok "scratch: actively-written entry survives --reap-tier1" || no "scratch: actively-written entry was deleted"
[ -L "$SCRATCH/linked-repro.fff" ]   && ok "scratch: symlink survives --reap-tier1" || no "scratch: symlink was deleted"
[ -d "$TMP/link-target-dir" ]        && ok "scratch: symlink TARGET survives --reap-tier1" || no "scratch: symlink target was deleted"
[ -d "$SCRATCH/checkout-repro.ggg" ] && ok "scratch: protected checkout survives --reap-tier1" || no "scratch: protected checkout was rm -rf'd"
[ -d "$SCRATCH/bare-repro.iii/objects" ] && ok "scratch: aged-out bare repo survives --reap-tier1" || no "scratch: aged-out bare repo was rm -rf'd"
[ -L "$SCRATCH/dangling-repro.jjj/.git" ] && ok "scratch: checkout with a dangling .git symlink survives --reap-tier1" || no "scratch: checkout with a dangling .git symlink was rm -rf'd"
[ -d "$SCRATCH/partial-repro.kkk/objects" ] && ok "scratch: bare repo missing refs/ survives --reap-tier1" || no "scratch: bare repo missing refs/ was rm -rf'd"

# the report says what it removed (the #792 acceptance bar), in both output modes
python3 -c "
import json, sys
d = json.load(sys.stdin)
outs = {r['path']: r for r in d['reaped']}
r = outs.get('$SCRATCH/stale-repro.aaa')
assert r and r['outcome'] == 'deleted' and r['kind'] == 'scratch', d['reaped']
assert '$SCRATCH/checkout-repro.ggg' not in outs, 'a tier-3 entry must never appear in reaped: ' + str(d['reaped'])
" < "$TMP/scratch-reap.json" && ok "scratch: --json report lists what was removed" || no "scratch: --json reaped record"

mk_old "$SCRATCH/text-repro.hhh"
python3 "$SWEEP" --repo "$REPO" --scratch-glob "$GLOB" --reap-tier1 2>/dev/null > "$TMP/scratch-reap.txt" || true
grep -q '^## Reaped' "$TMP/scratch-reap.txt" && ok "scratch: human report carries a Reaped section" || no "scratch: human report Reaped section"
grep -q "^- \[scratch\] $SCRATCH/text-repro.hhh" "$TMP/scratch-reap.txt" && ok "scratch: human report names the deleted path" || no "scratch: human report names the deleted path"

# 8b. NEVER DELETE THROUGH A MOUNT POINT (round-3 code-review Finding 1). `shutil.rmtree` unlinks a bind
#     mount's contents THROUGH the mount and only THEN raises EBUSY on the mount point, so the reap loop's
#     failure handling arrives after the mounted data is already destroyed. Verified on a stock Linux
#     runner. The mount table is the only source that sees it — for a bind mount whose source is on the
#     same filesystem `os.path.ismount()` is False and `st_dev` is IDENTICAL either side, so ismount /
#     st_dev / `-xdev` guards all wave it through. A real `mount --bind` needs root, hence the injected
#     table. Runs after step 8's destructive reap so these fixtures meet exactly one `--reap-tier1`.
mk_old "$SCRATCH/mountat-repro.lll"
mk_old "$SCRATCH/mountsub-repro.mmm"; mkdir -p "$SCRATCH/mountsub-repro.mmm/dataset"
touch -d "$OLD_DATE" "$SCRATCH/mountsub-repro.mmm/dataset" "$SCRATCH/mountsub-repro.mmm"
# The entry's own name carries a SPACE, so the table's `\040` has to decode for this to match the entry at
# all: leave the escape raw and this exact case is classified tier 1 and rm -rf'd through its mount.
mk_old "$SCRATCH/mount esc-repro.nnn"
mk_old "$SCRATCH/control-repro.ooo"
mkmountinfo "$TMP/mi-scratch" \
  "$SCRATCH" \
  "$SCRATCH/mountat-repro.lll" \
  "$SCRATCH/mountsub-repro.mmm/dataset" \
  "$SCRATCH/mount\\040esc-repro.nnn"

REPO_JANITOR_MOUNTINFO="$TMP/mi-scratch" python3 "$SWEEP" --repo "$REPO" --scratch-glob "$GLOB" --json 2>/dev/null > "$TMP/scratch-mount.json"
has_path_in "d['tier3']" "$SCRATCH/mountat-repro.lll" < "$TMP/scratch-mount.json" && ok "scratch: an entry that IS a mount point routes to tier3" || no "scratch: entry that is a mount point must route to tier3"
has_path_in "d['tier1']" "$SCRATCH/mountat-repro.lll" < "$TMP/scratch-mount.json" && no "scratch: an entry that IS a mount point must never be tier1" || ok "scratch: entry that is a mount point never tier1"
has_path_in "d['tier1']" "$SCRATCH/mountsub-repro.mmm" < "$TMP/scratch-mount.json" && no "scratch: an entry CONTAINING a mount point must never be tier1 (rmtree deletes the mounted data before failing)" || ok "scratch: entry containing a mount point never tier1"
has_path_in "d['tier3']" "$SCRATCH/mountsub-repro.mmm" < "$TMP/scratch-mount.json" && ok "scratch: an entry CONTAINING a mount point routes to tier3" || no "scratch: entry containing a mount point must route to tier3"
has_path_in "d['tier1']" "$SCRATCH/mount esc-repro.nnn" < "$TMP/scratch-mount.json" && no "scratch: a mount point written with mountinfo's \\040 space escape must be decoded before comparison" || ok "scratch: mount point with an octal-escaped space is decoded and blocks"
# An ANCESTOR mount blocks nothing — the fixture table lists the scratch root itself (and `/` is an
# ancestor of every path there is), so an ancestor-sensitive guard would reap nothing, ever.
has_path_in "d['tier1']" "$SCRATCH/control-repro.ooo" < "$TMP/scratch-mount.json" && ok "scratch: an ancestor mount point blocks nothing (scratch root on its own volume is the normal layout)" || no "scratch: ancestor mount wrongly disqualified an entry"
python3 -c "
import json, sys
d = json.load(sys.stdin)
e = [x for x in d['tier3'] if x['path'] == '$SCRATCH/mountat-repro.lll' and x['kind'] == 'scratch']
assert e and 'mount point' in e[0]['reason'], d['tier3']
" < "$TMP/scratch-mount.json" && ok "scratch: mount reason names the mount point" || no "scratch: mount reason names the mount point"

REPO_JANITOR_MOUNTINFO="$TMP/mi-scratch" python3 "$SWEEP" --repo "$REPO" --scratch-glob "$GLOB" --reap-tier1 --json 2>/dev/null > /dev/null || true
[ -d "$SCRATCH/mountat-repro.lll" ]       && ok "scratch: an entry that IS a mount point survives --reap-tier1" || no "scratch: an entry that IS a mount point was rm -rf'd"
[ -d "$SCRATCH/mountsub-repro.mmm/dataset" ] && ok "scratch: the data under a nested mount point survives --reap-tier1" || no "scratch: mounted data beneath a scratch entry was DESTROYED"
[ -d "$SCRATCH/mount esc-repro.nnn" ]     && ok "scratch: an octal-escaped mount point survives --reap-tier1" || no "scratch: an octal-escaped mount point was rm -rf'd"
[ -d "$SCRATCH/control-repro.ooo" ]       && no "scratch: the control entry under an ancestor mount was NOT reaped" || ok "scratch: the control entry under an ancestor mount is still reaped"

# An unreadable mount table is UNKNOWN, never "there are no mounts" — the same fail-closed direction every
# other unreadable fact in this guard takes.
mk_old "$SCRATCH/control2-repro.ppp"
REPO_JANITOR_MOUNTINFO="$TMP/no-such-mountinfo" python3 "$SWEEP" --repo "$REPO" --scratch-glob "$GLOB" --json 2>/dev/null > "$TMP/scratch-nomi.json"
has_path_in "d['tier3']" "$SCRATCH/control2-repro.ppp" < "$TMP/scratch-nomi.json" && ok "scratch: an unreadable mount table routes entries to tier3 (UNKNOWN, never 'no mounts')" || no "scratch: unreadable mount table must route to tier3"
has_path_in "d['tier1']" "$SCRATCH/control2-repro.ppp" < "$TMP/scratch-nomi.json" && no "scratch: an unreadable mount table must never leave an entry tier1" || ok "scratch: unreadable mount table never tier1"
REPO_JANITOR_MOUNTINFO="$TMP/no-such-mountinfo" python3 "$SWEEP" --repo "$REPO" --scratch-glob "$GLOB" --reap-tier1 --json 2>/dev/null > /dev/null || true
[ -d "$SCRATCH/control2-repro.ppp" ] && ok "scratch: nothing is deleted while the mount table is unreadable" || no "scratch: an entry was deleted with mount-freedom unestablished"

# pattern validation — the delete scope must stay statically bounded
for bad in "relative/*-repro.*" "/tmp/*/inner-*" "/*" "$SCRATCH/repro/"; do
  if python3 "$SWEEP" --repo "$REPO" --scratch-glob "$bad" >/dev/null 2>&1; then
    no "scratch: unsafe --scratch-glob '$bad' was accepted"
  else
    ok "scratch: unsafe --scratch-glob '$bad' rejected"
  fi
done

# --- content-verified eviction (--evict-verified, automated-researcher#856) ---------------------------
# The artifact store is stood in for through the REPO_JANITOR_STORE_LIST_CMD seam, which is exactly why
# that seam exists: `rclone` is neither installed nor reachable on a CI runner, and this leg's whole
# contract is what the sweep does with the LISTING — a checksum match, a checksum disagreement, a listing
# that offers no comparable checksum at all, a size disagreement, an absent object, a failed listing. The
# fake prints `rclone lsjson --recursive --files-only --hash`-shaped JSON for the prefix it is handed, so
# every assertion below exercises the real parser and the real bar.
#
# EVERY fixture that is expected to EVICT carries a real checksum (Codex review #859 round 1): a recomputed
# checksum is now required, so a hashless fixture would assert the old, unsafe name+size bar. The spellings
# are deliberately mixed — `md5`, `MD5`, `SHA-1` — because rclone has emitted all of them and the
# case-sensitive lookup that shipped in round 1 silently discarded the ones a production listing carries.
#
# A DEDICATED repo: every eviction run below passes --reap-tier1 for real, and $REPO's worktree/scratch
# fixtures are consumed by the assertions above — reaping them here would make those tests order-dependent.
EVREPO="$TMP/evrepo"
git init -q -b main "$EVREPO"
g "$EVREPO" config user.email t@example.com
g "$EVREPO" config user.name "smoke"
echo hi > "$EVREPO/f.txt"; g "$EVREPO" add f.txt; g "$EVREPO" commit -q -m init

EV="$TMP/evict"; STORE_DB="$TMP/storedb"; mkdir -p "$EV" "$STORE_DB"
export STORE_DB
STORE_CMD="$TMP/fake-store.sh"
cat > "$STORE_CMD" <<'EOS'
#!/usr/bin/env bash
# stands in for `rclone lsjson --recursive --files-only --hash <prefix>`: prints the fixture listing for
# the prefix it is handed, or fails loudly for a prefix marked as a listing failure. An unknown prefix is
# an empty array — the store genuinely holding nothing there, which must NOT read the same as a failure.
prefix=$1
f="$STORE_DB/$(printf '%s' "$prefix" | tr '/:' '__')"
if [ -f "$f.fail" ]; then echo "fake store: listing refused" >&2; exit 7; fi
if [ -f "$f.json" ]; then cat "$f.json"; else echo '[]'; fi
EOS
chmod +x "$STORE_CMD"
STORE="r2:mats/experiments"
# store_put <top-level dir> <object path under the prefix> <size> [hash-json]
store_put(){
  local key hashes=${4:-}
  key=$(printf '%s' "$STORE/$1" | tr '/:' '__')
  [ -n "$hashes" ] || hashes='{}'
  printf '[{"Path":"%s","Name":"%s","Size":%s,"IsDir":false,"Hashes":%s}]' \
    "$2" "${2##*/}" "$3" "$hashes" > "$STORE_DB/$key.json"
}
mkbig(){ mkdir -p "$(dirname "$1")"; head -c "${2:-2000000}" /dev/urandom > "$1"; }
digestof(){ python3 -c "
import hashlib, sys
h = hashlib.new(sys.argv[2])
with open(sys.argv[1], 'rb') as fh:
    for chunk in iter(lambda: fh.read(1 << 20), b''):
        h.update(chunk)
print(h.hexdigest())
" "$1" "${2:-md5}"; }
md5of(){ digestof "$1" md5; }
# store_put_md5 <top-level dir> <object path under the prefix> <local file> [hash key spelling]
# The ordinary "these bytes really are at the store" fixture: same size, same md5, spelled however rclone
# would spell the key on the day the listing was taken.
store_put_md5(){
  store_put "$1" "$2" "$(stat -c%s "$3")" "{\"${4:-md5}\":\"$(md5of "$3")\"}"
}
sweep_evict(){ # extra args -> stdout is the JSON report
  REPO_JANITOR_STORE_LIST_CMD="$STORE_CMD" python3 "$SWEEP" --repo "$EVREPO" \
    --evict-verified "$EV" --store "$STORE" --min-size 1M "$@" 2>/dev/null
}

# 1. the #856 case itself: bytes already at the store, under a store layout that does NOT mirror the local
#    path (`adapters/probe.tar` locally, `target_probes/probe.tar` at the store) — a path-shaped lookup
#    would have found nothing while the bytes were demonstrably there.
mkbig "$EV/exp-match/adapters/probe.tar"
store_put_md5 exp-match "target_probes/probe.tar" "$EV/exp-match/adapters/probe.tar"
# 2. same basename at the store, DIFFERENT size -> not these bytes
mkbig "$EV/exp-size/big.tar"
store_put exp-size "x/big.tar" "$(( $(stat -c%s "$EV/exp-size/big.tar") + 1 ))"
# 3. nothing at the store under that prefix at all
mkbig "$EV/exp-none/orphan.tar"
# 4. the store spells its hash key the way rclone does on an S3/R2 backend — `MD5`, not `md5`. The bar is a
#    fact about the STORE, not about rclone's formatting: this must verify exactly as lowercase does.
mkbig "$EV/exp-hash/hashed.tar"
store_put_md5 exp-hash "y/hashed.tar" "$EV/exp-hash/hashed.tar" "MD5"
# 5. the store exposes a hash and it DISAGREES while name+size match — the collision case name+size alone
#    would wave through.
mkbig "$EV/exp-badhash/collide.tar"
store_put exp-badhash "z/collide.tar" "$(stat -c%s "$EV/exp-badhash/collide.tar")" \
  '{"md5":"00000000000000000000000000000000"}'
# 5b. THE ROUND-1 P0 (#859): name and exact size agree and the store offers NO comparable checksum. Two
#     adapter tars for one experiment share a generic basename and a size fixed by the adapter's shape, so
#     this is the shape name+size cannot tell apart — it must be KEPT, not waved through.
mkbig "$EV/exp-nohash/probe.tar"
store_put exp-nohash "p/probe.tar" "$(stat -c%s "$EV/exp-nohash/probe.tar")"
# 5c. an algorithm this sweep cannot recompute is exactly as much evidence as no hash at all
mkbig "$EV/exp-crc/probe.tar"
store_put exp-crc "p/probe.tar" "$(stat -c%s "$EV/exp-crc/probe.tar")" \
  '{"crc32":"deadbeef","quickxor":"zzz"}'
# 5d. `SHA-1` normalizes onto sha1 and verifies — the other spelling rclone actually emits
mkbig "$EV/exp-sha/probe.tar"
store_put exp-sha "p/probe.tar" "$(stat -c%s "$EV/exp-sha/probe.tar")" \
  "{\"SHA-1\":\"$(digestof "$EV/exp-sha/probe.tar" sha1)\"}"
# 5e. one record carrying two spellings of ONE algorithm that DISAGREE is a store record contradicting
#     itself: every comparable checksum must agree, so no winner is picked and the file is kept.
mkbig "$EV/exp-selfcontra/probe.tar"
store_put exp-selfcontra "p/probe.tar" "$(stat -c%s "$EV/exp-selfcontra/probe.tar")" \
  "{\"md5\":\"$(md5of "$EV/exp-selfcontra/probe.tar")\",\"MD5\":\"00000000000000000000000000000000\"}"
# 6. the listing itself fails -> UNKNOWN, never "the store does not have this"
mkbig "$EV/exp-fail/unlisted.tar"
touch "$STORE_DB/$(printf '%s' "$STORE/exp-fail" | tr '/:' '__').fail"
# 7. below --min-size, even with a perfectly matching object: not the leak, never considered
mkbig "$EV/exp-match/small.bin" 1024
# 8. `registry/` of a GIT TREE is the durable record and is never touched; the same directory NAME outside
#    a git tree is not the record and is fair game — the veto is git-tree-keyed, not name-keyed.
mkbig "$EV/exp-reg/tree/registry/e1/rec.tar"
git init -q "$EV/exp-reg/tree"
mkdir -p "$EV/exp-reg/plain/registry"
cp "$EV/exp-reg/tree/registry/e1/rec.tar" "$EV/exp-reg/plain/registry/rec.tar"
store_put_md5 exp-reg "recs/rec.tar" "$EV/exp-reg/tree/registry/e1/rec.tar"
# 9. a live owner vetoes eviction outright, whatever the store says
mkbig "$EV/exp-live/adapters/probe.tar"
store_put_md5 exp-live "target_probes/probe.tar" "$EV/exp-live/adapters/probe.tar"
# 10. a hardlinked pair, both links in scope and both verifiable -> ONE tier-1 entry, both links unlinked,
#     the bytes counted ONCE (unlinking one of two links frees nothing at all).
mkbig "$EV/exp-hl/a/big.tar"
mkdir -p "$EV/exp-hl/b"; ln "$EV/exp-hl/a/big.tar" "$EV/exp-hl/b/big.tar"
store_put_md5 exp-hl "hl/big.tar" "$EV/exp-hl/a/big.tar"
# 11. a link this sweep CANNOT see (outside every scanned root) -> kept: the unlink would free nothing
#     while destroying a path whose sibling is unaccounted for.
mkbig "$EV/exp-hlout/big.tar"
ln "$EV/exp-hlout/big.tar" "$TMP/outside-link.tar"
store_put_md5 exp-hlout "hl/big.tar" "$EV/exp-hlout/big.tar"
# 12. a symlink is never a candidate, however verifiable its target looks
ln -s "adapters/probe.tar" "$EV/exp-match/probe-link.tar"
# 13. a file directly under the root has no top-level dir to key the store prefix on -> kept
mkbig "$EV/loose.tar"

REPO_JANITOR_STORE_LIST_CMD="$STORE_CMD" REPO_JANITOR_LIVE_SESSIONS_CMD="echo exp-live" python3 "$SWEEP" \
  --repo "$EVREPO" --worktree-root "$EV" --evict-verified "$EV" --store "$STORE" --min-size 1M --json \
  2>/dev/null > "$TMP/evict-live.json"
has_path_in "d['tier3']" "$EV/exp-live/adapters/probe.tar" < "$TMP/evict-live.json" && ok "evict: a live owner's tree is never evicted from (tier3)" || no "evict: live-owner veto must route to tier3"
has_path_in "d['tier1']" "$EV/exp-live/adapters/probe.tar" < "$TMP/evict-live.json" && no "evict: a live owner's file must never reach tier1" || ok "evict: a live owner's file never reaches tier1"
reason_has "d['tier3']" "$EV/exp-live/adapters/probe.tar" "nothing inside a live" < "$TMP/evict-live.json" && ok "evict: the live-owner reason names the liveness" || no "evict: live-owner reason must name the liveness"

sweep_evict --json > "$TMP/evict.json"
has_path_in "d['tier1']" "$EV/exp-match/adapters/probe.tar" < "$TMP/evict.json" && ok "evict: bytes proven at the store reach tier1 (store layout need not mirror the local path)" || no "evict: a store-verified file must reach tier1"
reason_has "d['tier1']" "$EV/exp-match/adapters/probe.tar" "$STORE/exp-match/target_probes/probe.tar" < "$TMP/evict.json" && ok "evict: the tier-1 reason names the store object that proves the bytes" || no "evict: tier-1 reason must name the store object"
has_path_in "d['tier1']" "$EV/exp-hash/hashed.tar" < "$TMP/evict.json" && ok "evict: rclone's 'MD5' key spelling verifies exactly as 'md5' does (#859: a case-sensitive lookup dropped it)" || no "evict: an uppercase MD5 key must verify"
reason_has "d['tier1']" "$EV/exp-hash/hashed.tar" "md5-verified" < "$TMP/evict.json" && ok "evict: the reason names the checksum the verification rested on" || no "evict: reason must state md5-verified"
has_path_in "d['tier1']" "$EV/exp-sha/probe.tar" < "$TMP/evict.json" && ok "evict: rclone's 'SHA-1' key spelling normalizes onto sha1 and verifies" || no "evict: a 'SHA-1' key must verify"
reason_has "d['tier1']" "$EV/exp-sha/probe.tar" "sha1-verified" < "$TMP/evict.json" && ok "evict: the reason names sha1 when that is what proved the bytes" || no "evict: reason must state sha1-verified"
for keep in "$EV/exp-size/big.tar" "$EV/exp-none/orphan.tar" "$EV/exp-badhash/collide.tar" "$EV/exp-nohash/probe.tar" "$EV/exp-crc/probe.tar" "$EV/exp-selfcontra/probe.tar" "$EV/exp-fail/unlisted.tar" "$EV/exp-hlout/big.tar" "$EV/loose.tar"; do
  has_path_in "d['tier3']" "$keep" < "$TMP/evict.json" && ok "evict: unverified '$(basename "$(dirname "$keep")")/$(basename "$keep")' is kept and reported (tier3)" || no "evict: unverified $keep must be reported in tier3"
  has_path_in "d['tier1']" "$keep" < "$TMP/evict.json" && no "evict: unverified $keep must never reach tier1" || ok "evict: unverified '$(basename "$(dirname "$keep")")/$(basename "$keep")' never reaches tier1"
done
reason_has "d['tier3']" "$EV/exp-badhash/collide.tar" "the checksums the store exposes for it disagree" < "$TMP/evict.json" && ok "evict: a name+size collision whose checksum disagrees is kept, and the reason says why" || no "evict: hash-disagreement reason missing"
# THE ROUND-1 P0 (#859): name+size agreement is not exact-byte equivalence and never evicts on its own.
reason_has "d['tier3']" "$EV/exp-nohash/probe.tar" "name+size is not" < "$TMP/evict.json" && ok "evict: name+exact-size with no comparable checksum is KEPT, and the reason says name+size is not equivalence" || no "evict: name+size alone must never evict"
reason_has "d['tier3']" "$EV/exp-nohash/probe.tar" "$STORE/exp-nohash/p/probe.tar" < "$TMP/evict.json" && ok "evict: the kept-for-no-checksum reason still names the object, so the by-hand check is one step away" || no "evict: no-checksum reason must name the candidate object"
reason_has "d['tier3']" "$EV/exp-crc/probe.tar" "no checksum this sweep can recompute" < "$TMP/evict.json" && ok "evict: an incomparable-only algorithm (crc32/quickxor) is exactly as much evidence as no hash at all" || no "evict: incomparable-algorithm reason missing"
reason_has "d['tier3']" "$EV/exp-selfcontra/probe.tar" "the checksums the store exposes for it disagree" < "$TMP/evict.json" && ok "evict: a record contradicting itself across two spellings of one algorithm picks no winner" || no "evict: self-contradicting record must be kept"
reason_has "d['tier3']" "$EV/exp-fail/unlisted.tar" "store prefix could not be listed" < "$TMP/evict.json" && ok "evict: a failed store listing is UNKNOWN, not an empty store" || no "evict: failed-listing reason missing"
# the sub-threshold file and everything under `registry/` of a git tree are not just un-reaped, they are
# never CONSIDERED — silent, in no tier at all
all_paths < "$TMP/evict.json" | grep -qxF "$EV/exp-match/small.bin" && no "evict: a file below --min-size must not be classified at all" || ok "evict: a file below --min-size is silent"
all_paths < "$TMP/evict.json" | grep -qxF "$EV/exp-reg/tree/registry/e1/rec.tar" && no "evict: registry/ of a git tree must never be classified" || ok "evict: registry/ of a git tree is never even considered"
all_paths < "$TMP/evict.json" | grep -qxF "$EV/exp-match/probe-link.tar" && no "evict: a symlink must never be a candidate" || ok "evict: a symlink is never a candidate"
has_path_in "d['tier1']" "$EV/exp-reg/plain/registry/rec.tar" < "$TMP/evict.json" && ok "evict: the registry veto is git-tree-keyed, not name-keyed (a plain registry/ dir is still evictable)" || no "evict: a non-git registry/ dir must still be evictable"
python3 -c "
import json, sys
d = json.load(sys.stdin)
hl = [e for e in d['tier1'] if e['path'].startswith('$EV/exp-hl/')]
assert len(hl) == 1, hl                                    # ONE entry per inode, not one per link
assert len(hl[0]['action']['commands']) == 2, hl           # ...planning BOTH links for the unlink
assert 'hardlink sibling' in hl[0]['reason'], hl
assert d['reclaimed']['evictable_bytes'] > 0, d['reclaimed']
" < "$TMP/evict.json" && ok "evict: a hardlinked pair is one tier-1 entry that unlinks every link to the inode" || no "evict: hardlink grouping is wrong"
reason_has "d['tier3']" "$EV/exp-hlout/big.tar" "were found under the scanned root(s)" < "$TMP/evict.json" && ok "evict: an inode with a link outside the scanned roots is kept (the unlink would free nothing)" || no "evict: out-of-scope hardlink must be kept with that reason"
# report-only says what a reap WOULD reclaim — the sensor half of #856
python3 -c "
import json, sys
d = json.load(sys.stdin)
assert d['reaped'] == [], d['reaped']
assert d['reclaimed']['verified_on_store_bytes'] == 0, d['reclaimed']
assert d['reclaimed']['evictable_bytes'] >= 6_000_000, d['reclaimed']
" < "$TMP/evict.json" && ok "evict: report-only deletes nothing and states the evictable total" || no "evict: report-only accounting is wrong"
sweep_evict | grep -q "verified-on-store is evictable now" && ok "evict: the human report states the evictable total in report-only mode" || no "evict: human report must state the evictable total"

# --dry-run touches nothing
sweep_evict --reap-tier1 --dry-run > /dev/null
[ -f "$EV/exp-match/adapters/probe.tar" ] && ok "evict: --dry-run evicts nothing" || no "evict: --dry-run deleted a file"

# the real thing
sweep_evict --reap-tier1 --json > "$TMP/evict-reaped.json"
[ -f "$EV/exp-match/adapters/probe.tar" ] && no "evict: a store-verified file was NOT evicted by --reap-tier1" || ok "evict: --reap-tier1 really evicts a store-verified file"
[ -f "$EV/exp-hash/hashed.tar" ]           && no "evict: a hash-verified file was NOT evicted" || ok "evict: --reap-tier1 really evicts a hash-verified file"
[ -f "$EV/exp-hl/a/big.tar" ] || [ -f "$EV/exp-hl/b/big.tar" ] && no "evict: a hardlink sibling survived its inode's eviction (frees nothing)" || ok "evict: every link to an evicted inode is unlinked"
find "$EV" -name '.repo-janitor-evicting.*' -print -quit | grep -q . && no "evict: a staging entry was left behind by a successful reap" || ok "evict: a successful reap leaves no staging entry behind"
for survivor in "$EV/exp-size/big.tar" "$EV/exp-none/orphan.tar" "$EV/exp-badhash/collide.tar" "$EV/exp-nohash/probe.tar" "$EV/exp-crc/probe.tar" "$EV/exp-selfcontra/probe.tar" "$EV/exp-fail/unlisted.tar" "$EV/exp-hlout/big.tar" "$EV/loose.tar" "$EV/exp-match/small.bin" "$EV/exp-reg/tree/registry/e1/rec.tar"; do
  [ -f "$survivor" ] && ok "evict: '$(basename "$(dirname "$survivor")")/$(basename "$survivor")' survives a real --reap-tier1" || no "evict: $survivor was DELETED without being verified at the store"
done
python3 -c "
import json, sys
d = json.load(sys.stdin)
ev = [r for r in d['reaped'] if r['outcome'] == 'evicted']
assert ev, d['reaped']
assert all(r['kind'] == 'evict' and r['bytes'] > 0 and 'r2:mats/experiments/' in r['detail'] for r in ev), ev
# the inode's bytes are credited ONCE, not once per link
hl = [r for r in ev if r['path'].startswith('$EV/exp-hl/')]
assert len(hl) == 1 and hl[0]['bytes'] == 2000000, hl
assert d['reclaimed']['verified_on_store_bytes'] == sum(r['bytes'] for r in ev), d['reclaimed']
assert d['reclaimed']['tier1_bytes'] == 0, d['reclaimed']
" < "$TMP/evict-reaped.json" && ok "evict: the 'reaped' records name each eviction, its store object and its reclaimed bytes" || no "evict: eviction reap records are wrong"
sweep_evict --reap-tier1 2>/dev/null | grep -q "verified-on-store, .* tier-1" && no "evict: nothing is left to evict on a second pass, so no reclaimed line is expected" || ok "evict: a second pass finds nothing left to evict"

# evict_unlink's identity-AND-BYTE binding, driven directly (Codex review #859 rounds 1 and 2). Neither
# race can be scheduled from a shell — but the mechanism is "the inode I verified is the inode I remove,
# and the bytes I verified are the bytes I remove", and that IS assertable: hand it a stat key, a link
# count, or a digest that no longer describes the file and it must abort and put every staged link back
# exactly where it was. Driven as a unit because a sweep can only reach this through a real classification,
# which by construction never disagrees with itself.
UNLINK_DIR="$TMP/unlink-unit"; mkdir -p "$UNLINK_DIR"
python3 - "$SWEEP" "$UNLINK_DIR" <<'PY' && ok "evict: evict_unlink removes only the verified inode holding the verified bytes, and restores every staged link when it cannot" || no "evict: evict_unlink identity/byte binding or restore is wrong"
import hashlib, importlib.util, os, sys

spec = importlib.util.spec_from_file_location("ws", sys.argv[1])
ws = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ws)
root = sys.argv[2]
logged = []

def mkgroup(name, links=1):
    """A file plus `links - 1` hardlinks to it; returns (paths, stat_key, verified_hashes)."""
    paths = []
    for i in range(links):
        p = os.path.join(root, f"{name}.{i}")
        if i == 0:
            with open(p, "wb") as fh:
                fh.write(os.urandom(4096))
        else:
            os.link(paths[0], p)
        paths.append(p)
    st = os.lstat(paths[0])
    with open(paths[0], "rb") as fh:
        digest = hashlib.md5(fh.read()).hexdigest()
    return paths, (st.st_dev, st.st_ino, st.st_size, st.st_mtime_ns), {"md5": digest}

def staging_entries():
    return [n for n in os.listdir(root) if n.startswith(ws.EVICT_STAGE_PREFIX)]

# 1. the happy path: every link to the verified inode goes
paths, key, hashes = mkgroup("happy", links=2)
assert ws.evict_unlink(paths, key, hashes, logged.append) == ("evicted", None)
assert not any(os.path.lexists(p) for p in paths), paths
assert staging_entries() == [], staging_entries()

# 2. a stat key that does not describe the file: nothing is deleted, and every link is back under its
#    ORIGINAL name — a staged rename this sweep does not finish must never be visible afterwards.
paths, key, hashes = mkgroup("wrongkey", links=2)
outcome, detail = ws.evict_unlink(paths, (key[0], key[1], key[2], key[3] + 1), hashes, logged.append)
assert outcome == "skipped" and "not the inode whose bytes were verified" in detail, (outcome, detail)
assert all(os.path.lexists(p) for p in paths), paths
assert staging_entries() == [], staging_entries()

# 3. a link added to the inode after the plan was made: the unlink would no longer free the bytes, so the
#    group is skipped whole and restored.
paths, key, hashes = mkgroup("extralink", links=2)
os.link(paths[0], os.path.join(root, "extralink.sneaked"))
outcome, detail = ws.evict_unlink(paths, key, hashes, logged.append)
assert outcome == "skipped" and "link(s), not the 2" in detail, (outcome, detail)
assert all(os.path.lexists(p) for p in paths), paths
assert staging_entries() == [], staging_entries()

# 4. a path that is not a regular file any more is never unlinked
p = os.path.join(root, "gone-dir")
_, key, hashes = mkgroup("gone", links=1)
os.mkdir(p)
outcome, detail = ws.evict_unlink([p], key, hashes, logged.append)
assert outcome == "skipped", (outcome, detail)
assert os.path.isdir(p), p
assert staging_entries() == [], staging_entries()

# 5. THE ROUND-2 P0 (#859): the stat tuple STILL AGREES and the bytes do not. Rewritten in place, same
#    length, same inode, mtime restored to the nanosecond — exactly what a writer holding an open fd
#    leaves behind, and exactly what `(dev, ino, size, mtime_ns)` cannot see. The bytes about to be
#    deleted are no longer the bytes the store matched, so nothing may be deleted.
paths, key, hashes = mkgroup("rewritten", links=2)
with open(paths[0], "r+b") as fh:
    fh.write(b"\xff" * 4096)
os.utime(paths[0], ns=(key[3], key[3]))
assert os.lstat(paths[0]).st_mtime_ns == key[3]                 # the metadata proxy still says "unchanged"
outcome, detail = ws.evict_unlink(paths, key, hashes, logged.append)
assert outcome == "skipped" and "no longer holds the bytes" in detail, (outcome, detail)
assert all(os.path.lexists(p) for p in paths), paths           # every link back under its original name
assert staging_entries() == [], staging_entries()

# 6. fail-closed with nothing to re-check against: no digest was carried into the delete, so the function
#    cannot establish the one thing it exists to establish and must refuse rather than fall back to stat.
paths, key, _hashes = mkgroup("nohash", links=1)
for empty in (None, {}):
    outcome, detail = ws.evict_unlink(paths, key, empty, logged.append)
    assert outcome == "skipped" and "no recomputed checksum" in detail, (empty, outcome, detail)
    assert os.path.lexists(paths[0]), paths
assert staging_entries() == [], staging_entries()

# 7. the digest itself disagreeing (the store-side value, not a local rewrite) is the same refusal
paths, key, _hashes = mkgroup("baddigest", links=1)
outcome, detail = ws.evict_unlink(paths, key, {"md5": "0" * 32}, logged.append)
assert outcome == "skipped" and "md5 disagrees now" in detail, (outcome, detail)
assert os.path.lexists(paths[0]), paths
assert staging_entries() == [], staging_entries()
PY

# tier-1 worktree/scratch reaps carry their own byte figure, so the summary can split the two legs
SC2="$TMP/scratch2"; mkdir -p "$SC2"
mkbig "$SC2/leftover-repro.zzz/blob.bin"
touch -d "$OLD_DATE" "$SC2/leftover-repro.zzz/blob.bin"; touch -d "$OLD_DATE" "$SC2/leftover-repro.zzz"
python3 "$SWEEP" --repo "$EVREPO" --scratch-glob "$SC2/*-repro.*" --reap-tier1 --json 2>/dev/null > "$TMP/evict-tier1bytes.json"
python3 -c "
import json, sys
d = json.load(sys.stdin)
assert d['reclaimed']['tier1_bytes'] >= 2_000_000, d['reclaimed']
assert d['reclaimed']['verified_on_store_bytes'] == 0, d['reclaimed']
" < "$TMP/evict-tier1bytes.json" && ok "evict: the summary splits reclaimed bytes into verified-on-store and tier-1 legs" || no "evict: tier-1 reclaimed bytes are not accounted"

# argument validation — --store is the whole safety argument, so the mode may never run without one
for bad in "--evict-verified $EV" "--store $STORE" "--evict-verified relative/dir --store $STORE" "--evict-verified / --store $STORE" "--evict-verified $EV/../evict --store $STORE" "--evict-verified $EV --store $STORE --min-size bogus" "--evict-verified '' --store $STORE"; do
  # shellcheck disable=SC2086
  if python3 "$SWEEP" --repo "$EVREPO" $bad >/dev/null 2>&1; then
    no "evict: unsafe/incomplete invocation '$bad' was accepted"
  else
    ok "evict: unsafe/incomplete invocation '$bad' rejected"
  fi
done

if [ "$fails" = 0 ]; then echo "smoke: all groups passed"; else echo "smoke: FAILURES present (see FAIL lines above)"; fi
exit "$fails"
