#!/bin/bash
# locate_audit_smoke.sh — composition smoke for wf.sh's trusted-but-current verify-claims resolution (#69).
# Builds throwaway git repos and asserts `wf.sh locate-audit <repo>`:
#   (1) resolves to the BASE-ref (clean) reviewer, NOT the branch's poisoned copy — the security property: a PR
#       that edits the reviewer cannot run its own modified reviewer as its merge gate; AND the whole skill dir
#       (SKILL.md + references/, not just scripts/) is materialized;
#   (2) returns CURRENT base content (picks up a new main commit), not a stale extraction;
#   (3) fails closed when neither a base-ref nor an installed reviewer exists;
#   (4) FAILS CLOSED when verify-claims IS present at base but extraction is broken, even with an installed copy
#       available — never silently downgrades the merge-gate reviewer to a stale install;
#   (5) falls back to wf.sh's OWN source-repo base ref (not the stale install) when the context repo has no
#       verify-claims in-tree.
# Self-contained: no network, fake HOME, fresh repos. Exits non-zero on any failed assertion.
set -uo pipefail
WF=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/wf.sh
[ -f "$WF" ] || { echo "FAIL: wf.sh not found next to smoke" >&2; exit 1; }

fail=0
check(){ if eval "$2"; then echo "  PASS: $1"; else echo "  FAIL: $1" >&2; fail=1; fi; }

unset AUDIT_EXPERIMENT                                # ambient override would short-circuit the resolver under test
TMP=$(mktemp -d "${TMPDIR:-/tmp}/locate-audit-smoke.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"; mkdir -p "$HOME"            # virgin HOME: no installed plugin cache unless we add one
export GIT_CONFIG_GLOBAL="$TMP/gitconfig"; : > "$GIT_CONFIG_GLOBAL"
git config --global user.email smoke@example.com; git config --global user.name smoke
git config --global init.defaultBranch main
VC=plugins/verify-claims/skills/verify-claims          # the SKILL dir; reviewer at $VC/scripts/audit_experiment.sh

# seed a verify-claims SKILL dir (reviewer + sibling script + non-script resource) under $1
seed_vc(){ local root=$1 tag=$2
  mkdir -p "$root/$VC/scripts" "$root/$VC/references"
  printf '#!/bin/bash\necho %s\n' "$tag" > "$root/$VC/scripts/audit_experiment.sh"
  printf 'sibling\n'   > "$root/$VC/scripts/verify_claim.sh"
  printf 'calibration\n' > "$root/$VC/references/CALIBRATION.md"   # non-script resource (F2)
  printf '# verify-claims\n' > "$root/$VC/SKILL.md"
}
git_repo_with_origin(){ local repo=$1   # init repo + a bare origin so origin/main exists
  ( cd "$repo" && git init -q && git add -A && git commit -qm init )
  git init -q --bare "$repo.git"
  ( cd "$repo" && git remote add origin "$repo.git" && git push -q origin main )
}

# ---------- repo with verify-claims on main + a branch worktree that POISONS the reviewer ----------
REPO="$TMP/repo"; mkdir -p "$REPO"; seed_vc "$REPO" CLEAN-BASE-REVIEWER; git_repo_with_origin "$REPO"
WT="$TMP/wt"; ( cd "$REPO" && git worktree add -q "$WT" -b change/1-x main )
printf '#!/bin/bash\necho POISONED-BRANCH-REVIEWER\n' > "$WT/$VC/scripts/audit_experiment.sh"
( cd "$WT" && git add -A && git commit -qm "poison reviewer" )

echo "=== (1) base reviewer (not poisoned branch) + whole skill dir materialized ==="
got=$(bash "$WF" locate-audit "$WT" 2>/dev/null); out=$(bash "$got" 2>/dev/null)
echo "  -> $got"
check "runs the CLEAN base reviewer"               "[ \"$out\" = CLEAN-BASE-REVIEWER ]"
check "does NOT run the poisoned branch reviewer"  "[ \"$out\" != POISONED-BRANCH-REVIEWER ]"
check "resolved path is NOT inside the worktree"   "case \"$got\" in $WT/*) false;; *) true;; esac"
check "sibling script materialized"                "[ -f \"$(dirname "$got")/verify_claim.sh\" ]"
check "non-script skill resource materialized (F2)" "[ -f \"$(dirname "$got")/../references/CALIBRATION.md\" ]"
check "SKILL.md materialized (F2)"                  "[ -f \"$(dirname "$got")/../SKILL.md\" ]"

echo "=== (2) tracks current base content (new main commit), not a stale extraction ==="
( cd "$REPO" && printf '#!/bin/bash\necho CLEAN-BASE-REVIEWER-V2\n' > "$VC/scripts/audit_experiment.sh" \
    && git commit -qam v2 && git push -q origin main )
( cd "$WT" && git fetch -q origin )
got2=$(bash "$WF" locate-audit "$WT" 2>/dev/null); out2=$(bash "$got2" 2>/dev/null)
check "picks up the updated base reviewer"          "[ \"$out2\" = CLEAN-BASE-REVIEWER-V2 ]"

echo "=== (3) no source anywhere -> fail closed ==="
# invoke a wf.sh copy from a NON-git dir so its SELF_REPO is empty (no source-repo fallback), against a context
# repo with no verify-claims, with no install yet -> nothing to resolve.
PLAIN="$TMP/plain"; mkdir -p "$PLAIN"; cp "$WF" "$PLAIN/wf.sh"
BARE="$TMP/bare"; mkdir -p "$BARE"; ( cd "$BARE" && git init -q && git commit -q --allow-empty -m init )
if bash "$PLAIN/wf.sh" locate-audit "$BARE" >/dev/null 2>&1; then
  echo "  FAIL: expected failure (no in-tree, no source repo, no install) but one resolved" >&2; fail=1
else echo "  PASS: fails closed when neither base-ref nor installed reviewer exists"; fi

echo "=== (4) base has verify-claims but extraction broken + installed present -> FAIL CLOSED, not the install (F1) ==="
# install a reviewer in the fake HOME so a fail-OPEN would resolve to it
mkdir -p "$HOME/.claude/skills/$VC/scripts"
printf '#!/bin/bash\necho INSTALLED-STALE\n' > "$HOME/.claude/skills/$VC/scripts/audit_experiment.sh"
# sabotage extraction: make the cache parent a FILE so materialization can't write
COMMON=$(git -C "$WT" rev-parse --git-common-dir); case "$COMMON" in /*) ;; *) COMMON="$WT/$COMMON";; esac
rm -rf "$COMMON/aar-ship-verify"; : > "$COMMON/aar-ship-verify"
got4=$(bash "$WF" locate-audit "$WT" 2>/dev/null); rc4=$?
out4=""; [ -n "$got4" ] && out4=$(bash "$got4" 2>/dev/null)
check "exits non-zero (fail closed)"               "[ $rc4 -ne 0 ]"
check "does NOT resolve the stale installed copy"  "[ \"$out4\" != INSTALLED-STALE ]"
rm -f "$COMMON/aar-ship-verify"                     # un-sabotage

echo "=== (5) context repo has no verify-claims -> resolves from wf.sh's OWN source-repo base ref (F3) ==="
# Build a fake 'self repo': a git repo carrying verify-claims AND a copy of wf.sh at its real in-repo path, so
# the copy's BASH_SOURCE makes SELF_REPO point at this repo. Invoke THAT copy against a context repo with no vc.
SELF="$TMP/selfrepo"; mkdir -p "$SELF"; seed_vc "$SELF" SELF-REPO-BASE-REVIEWER
WFREL="plugins/aar-engineering/skills/ship-change/scripts/wf.sh"
mkdir -p "$SELF/$(dirname "$WFREL")"; cp "$WF" "$SELF/$WFREL"
git_repo_with_origin "$SELF"
CTX="$TMP/ctx"; mkdir -p "$CTX/src"; printf 'x\n' > "$CTX/src/a.txt"   # a repo with NO verify-claims in-tree
( cd "$CTX" && git init -q && git add -A && git commit -qm init )
got5=$(bash "$SELF/$WFREL" locate-audit "$CTX" 2>/dev/null); out5=$(bash "$got5" 2>/dev/null)
echo "  -> $got5"
check "resolves from the self-repo base ref"       "[ \"$out5\" = SELF-REPO-BASE-REVIEWER ]"
check "self-repo reviewer path is under the self repo, not the install" "case \"$got5\" in $SELF/*) true;; *) false;; esac"

echo "=== (7) base ref present but un-inspectable (corrupt object DB) + installed present -> FAIL CLOSED (F1/F2) ==="
# build a dedicated repo with verify-claims on main + an installed fallback in HOME, then corrupt the object DB
# so the base ref resolves at the ref layer but cannot be enumerated/inspected.
mkdir -p "$HOME/.claude/skills/$VC/scripts"
printf '#!/bin/bash\necho INSTALLED-STALE-7\n' > "$HOME/.claude/skills/$VC/scripts/audit_experiment.sh"
CORRUPT="$TMP/corrupt"; mkdir -p "$CORRUPT"; seed_vc "$CORRUPT" CORRUPT-BASE; git_repo_with_origin "$CORRUPT"
assert_failclosed(){ local repo=$1 desc=$2 got rc out
  got=$(bash "$WF" locate-audit "$repo" 2>/dev/null); rc=$?
  out=""; [ -n "$got" ] && out=$(bash "$got" 2>/dev/null)
  check "$desc: exits non-zero (fail closed)"        "[ $rc -ne 0 ]"
  check "$desc: does NOT use the stale install"      "[ \"$out\" != INSTALLED-STALE-7 ]"
}
TREE=$(git -C "$CORRUPT" rev-parse 'main^{tree}'); COMMIT=$(git -C "$CORRUPT" rev-parse refs/heads/main)
# 7a: ls-tree fails (tree object removed) while rev-parse still resolves the commit
rm -f "$CORRUPT/.git/objects/${TREE:0:2}/${TREE:2}"
assert_failclosed "$CORRUPT" "7a ls-tree failure"
# 7b: ref present in the ref store but the commit object is gone too (rev-parse --verify fails)
rm -f "$CORRUPT/.git/objects/${COMMIT:0:2}/${COMMIT:2}"
assert_failclosed "$CORRUPT" "7b ref present but unresolvable"
# 7c: origin/main present-but-corrupt while a DIVERGED local main still resolves -> must fail closed on the
# canonical base, not silently fall back to the (possibly stale) local main.
CRP2="$TMP/corrupt2"; mkdir -p "$CRP2"; seed_vc "$CRP2" CORRUPT2-BASE; git_repo_with_origin "$CRP2"
OCOMMIT=$(git -C "$CRP2" rev-parse refs/remotes/origin/main)
( cd "$CRP2" && echo y > extra && git add -A && git commit -qm "diverge local main" )   # local main moves ahead; origin/main stays at OCOMMIT
rm -f "$CRP2/.git/objects/${OCOMMIT:0:2}/${OCOMMIT:2}"                                   # corrupt origin/main's commit
assert_failclosed "$CRP2" "7c corrupt origin/main, intact local main"

echo "=== (6) AUDIT_EXPERIMENT override honored when set; suite unsets it so cases test the resolver ==="
OV="$TMP/override.sh"; printf '#!/bin/bash\necho OVERRIDE-REVIEWER\n' > "$OV"
got6=$(AUDIT_EXPERIMENT="$OV" bash "$WF" locate-audit "$WT" 2>/dev/null); out6=$(bash "$got6" 2>/dev/null)
check "override is returned when AUDIT_EXPERIMENT is set"  "[ \"$out6\" = OVERRIDE-REVIEWER ]"
got6b=$(bash "$WF" locate-audit "$WT" 2>/dev/null); out6b=$(bash "$got6b" 2>/dev/null)
check "with override cleared, resolver (not the override) is used" "[ \"$out6b\" != OVERRIDE-REVIEWER ] && [ -n \"$out6b\" ]"

echo
[ "$fail" = 0 ] && { echo "locate_audit smoke: ALL PASS"; exit 0; } || { echo "locate_audit smoke: FAILURES" >&2; exit 1; }
