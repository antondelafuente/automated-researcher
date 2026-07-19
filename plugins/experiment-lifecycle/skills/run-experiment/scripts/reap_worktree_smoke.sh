#!/usr/bin/env bash
# Smoke for reap_worktree.sh — the workspace self-reap close action (automated-researcher#532). Behavior the
# deterministic JSON/syntax checks can't catch: the clean-close guard (only closed-AND-not-stopped reaps —
# a parked/blocked or deliberately-stopped run is never reaped), the $OLDPWD self-only binding (a
# clean-closed run-id must still match the worktree the caller just cd'd out of — automated-researcher#535
# review), the actual `git worktree remove --force` (branch ref kept, untracked scratch removed), and
# refusal on a path that isn't a real worktree. Uses a real throwaway git repo under TMP — no network, no
# real experiment state touched.
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
R="$HERE/reap_worktree.sh"
REC="$HERE/run_supervision_record.sh"
[ -f "$R" ]   || { echo "FAIL: missing $R"; exit 1; }
[ -f "$REC" ] || { echo "FAIL: missing $REC"; exit 1; }

TMP=$(mktemp -d) || { echo "FAIL: mktemp"; exit 1; }
trap 'rm -rf "$TMP"' EXIT
export AAR_RUN_SUPERVISION_DIR="$TMP/records"

fails=0
ok(){ echo "ok   $1"; }
no(){ echo "FAIL $1"; fails=1; }
rec(){ bash "$REC" "$@"; }
# Invoke reap_worktree.sh the way the skill actually calls it: cd INTO the worktree, then OUT of it, so
# $OLDPWD is exactly the worktree path when the script runs (the self-only binding it now enforces) —
# propagates the script's exit code. Forwards ALL args (not just id/wt) so arg-count validation tests
# below still reach the script unchanged; only cd's when $2 is an existing directory to cd into.
reap(){
  local wt=${2:-}
  if [ -n "$wt" ] && [ -d "$wt" ]; then
    ( cd "$wt" && cd "$TMP" && bash "$R" "$@" )
  else
    bash "$R" "$@"
  fi
}

REPO="$TMP/repo"
git init -q "$REPO"
git -C "$REPO" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init

new_worktree(){ # <name> -> prints the worktree path
  local name=$1
  local wt="$TMP/wt-$name"
  git -C "$REPO" worktree add -q -b "run/$name" "$wt" >/dev/null
  # untracked scratch (like real executor scratch, e.g. work/) — a plain `worktree remove` would refuse.
  echo scratch > "$wt/untracked_scratch.txt"
  printf '%s' "$wt"
}

# --- clean close -> removes the worktree (untracked scratch and all), keeps the branch ref, exit 0 ---
WT1=$(new_worktree c1)
rec create c1 >/dev/null; rec close c1 >/dev/null
if reap c1 "$WT1" >/dev/null 2>&1; then ok reap-clean-exit0; else no reap-clean-exit0; fi
[ -d "$WT1" ] && no "reap-clean-removed-dir (still present)" || ok reap-clean-removed-dir
git -C "$REPO" show-ref --verify --quiet "refs/heads/run/c1" && ok reap-clean-branch-kept || no reap-clean-branch-kept
git -C "$REPO" worktree list | grep -q "wt-c1" && no reap-clean-worktree-list-cleared || ok reap-clean-worktree-list-cleared

# --- GUARD: never reap a run that isn't a CLEAN close — worktree must survive ---
WT2=$(new_worktree g_active)
rec create g_active >/dev/null                                                                # active
if reap g_active "$WT2" >/dev/null 2>&1; then no reap-active-refused; else ok reap-active-refused; fi
[ -d "$WT2" ] && ok reap-active-worktree-survives || no reap-active-worktree-survives

WT3=$(new_worktree g_stop)
rec create g_stop >/dev/null; rec stop g_stop >/dev/null                                       # stopped-only
if reap g_stop "$WT3" >/dev/null 2>&1; then no reap-stopped-refused; else ok reap-stopped-refused; fi
[ -d "$WT3" ] && ok reap-stopped-worktree-survives || no reap-stopped-worktree-survives

WT4=$(new_worktree g_sc)
rec create g_sc >/dev/null; rec stop g_sc >/dev/null; rec close g_sc >/dev/null                # stop->close
if reap g_sc "$WT4" >/dev/null 2>&1; then no reap-stopclose-refused; else ok reap-stopclose-refused; fi
[ -d "$WT4" ] && ok reap-stopclose-worktree-survives || no reap-stopclose-worktree-survives

WT5=$(new_worktree g_missing)
if reap nonesuch "$WT5" >/dev/null 2>&1; then no reap-missing-refused; else ok reap-missing-refused; fi   # missing record
[ -d "$WT5" ] && ok reap-missing-worktree-survives || no reap-missing-worktree-survives

WT6=$(new_worktree g_broken)
printf 'not json{' > "$AAR_RUN_SUPERVISION_DIR/g_broken.json"                                   # corrupt record
if reap g_broken "$WT6" >/dev/null 2>&1; then no reap-corrupt-refused; else ok reap-corrupt-refused; fi
[ -d "$WT6" ] && ok reap-corrupt-worktree-survives || no reap-corrupt-worktree-survives

# --- SELF-ONLY BINDING: $OLDPWD unset -> refuses, worktree survives (raw invocation, bypassing the
# reap() wrapper's cd dance, since this test is exactly about that dance being absent) ---
WT7=$(new_worktree g_oldpwd_unset)
rec create g_oldpwd_unset >/dev/null; rec close g_oldpwd_unset >/dev/null
if (unset OLDPWD; bash "$R" g_oldpwd_unset "$WT7") >/dev/null 2>&1; then no reap-oldpwd-unset-refused; else ok reap-oldpwd-unset-refused; fi
[ -d "$WT7" ] && ok reap-oldpwd-unset-worktree-survives || no reap-oldpwd-unset-worktree-survives

# --- SELF-ONLY BINDING: $OLDPWD set but pointing at a DIFFERENT dir (e.g. a peer's worktree, or a plain
# copy/paste mistake) -> refuses, worktree survives ---
WT8=$(new_worktree g_oldpwd_mismatch)
rec create g_oldpwd_mismatch >/dev/null; rec close g_oldpwd_mismatch >/dev/null
if OLDPWD="$TMP" bash "$R" g_oldpwd_mismatch "$WT8" >/dev/null 2>&1; then no reap-oldpwd-mismatch-refused; else ok reap-oldpwd-mismatch-refused; fi
[ -d "$WT8" ] && ok reap-oldpwd-mismatch-worktree-survives || no reap-oldpwd-mismatch-worktree-survives

# --- a clean close but a path that ISN'T actually a worktree -> refuses, no crash ---
rec create c_notwt >/dev/null; rec close c_notwt >/dev/null
NOTWT="$TMP/just-a-dir"; mkdir -p "$NOTWT"
if reap c_notwt "$NOTWT" >/dev/null 2>&1; then no reap-notworktree-refused; else ok reap-notworktree-refused; fi

# --- arg validation ---
if reap >/dev/null 2>&1; then no reap-noarg-rejected; else ok reap-noarg-rejected; fi
if reap c1 >/dev/null 2>&1; then no reap-onearg-rejected; else ok reap-onearg-rejected; fi
if reap c1 "$TMP" extra >/dev/null 2>&1; then no reap-surplus-rejected; else ok reap-surplus-rejected; fi

[ "$fails" = 0 ] && { echo "reap_worktree smoke PASS"; exit 0; } || { echo "reap_worktree smoke FAIL"; exit 1; }
