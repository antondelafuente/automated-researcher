#!/bin/bash
# reap_worktree.sh — close-time WORKSPACE teardown: remove the executor's own git worktree, the missing
# member of the teardown symmetry (compute = gpu-job's lease reaper; sessions = reap_session.sh, #282).
# Neither run-experiment nor design-experiment ever removed its own worktree before this (automated-
# researcher#532): worktrees don't bill, so they never got a contract and just ate disk silently — a
# 2026-07-19 sweep found ~86G of dead worktrees, including ~46G of closed-experiment executor trees, every
# one already durable on `main` + the artifact store with zero unique content.
#
# POLICY A (researcher-approved, 2026-07-19): close-time self-teardown, NO grace window. The close
# contract already guarantees durability (RESULTS.md + figures/CSVs on main, artifacts verified on the
# artifact store, `log-experiment` merged — all BEFORE this runs) and post-close iteration is fed from
# main + the artifact store, never from executor scratch — so a deferred-reap grace window would be a
# second mechanism where one suffices.
#
# CONTRACT (mirrors reap_session.sh's fail-closed gates):
#   1. CLEAN-CLOSE GUARD: only reap if the run-supervision record is a clean close
#      (`run_supervision_record.sh is-closed` = closed AND NOT stopped) — same guard, same reason: a
#      parked/blocked/crashed run leaves its worktree in place for forensics (automated-researcher#285's
#      janitor sweep is the backstop for that residue, not this script).
#   2. SELF-ONLY BINDING (mirrors reap_session.sh's self-only session check, automated-researcher#535
#      review): a clean-closed run-id alone does not prove <worktree-path> is THAT run's own tree — nothing
#      else ties the two arguments together. So this script additionally requires <worktree-path> to equal
#      `$OLDPWD`, i.e. the directory the CALLING shell just `cd`'d out of — exactly the sequence the calling
#      skill already documents ("cd OUT of the worktree yourself FIRST ... then run reap_worktree.sh <run-id>
#      <this worktree's path>"). This is cheap (no new state to persist) and closes the "any clean-closed
#      run-id can be paired with an unrelated/mistaken worktree path" gap without inventing a naming
#      convention the product doesn't otherwise have.
#   3. SEQUENCING IS THE SAFETY STORY, and it is the CALLER's responsibility, not this script's: invoke
#      this only AFTER artifact-store upload is verified AND log-experiment has merged the record —
#      teardown-before-upload-verified loses data. This script has no way to re-check upload/merge state
#      itself; the clean-close guard above is the only mechanical gate it can enforce.
#   4. --force IS REQUIRED, and safe ONLY behind gates 1+3 above: executor scratch (e.g. `work/`) is
#      untracked by design, so a plain `git worktree remove` would refuse on untracked content every time.
#   5. KEEP THE BRANCH REF: content already landed via squash-merge, so the ref is cheap and preserves
#      recoverability. This script removes the WORKTREE only — it never runs `git branch -d`.
#
# USAGE: reap_worktree.sh <run-id> <worktree-path>
# <worktree-path> MUST equal $OLDPWD (see gate 2 above) — call this immediately after cd'ing out of it, in
# the same shell. Resolves the worktree's shared/main checkout itself via its git-dir (`--git-common-dir`,
# read from the worktree BEFORE cd'ing away) — no separate repo-root argument to get wrong, and no
# assumption that the git-dir's parent is itself a working checkout (bare / `--separate-git-dir` safe).
# Never touches the shared checkout beyond the one `worktree remove` call.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REC="$SCRIPT_DIR/run_supervision_record.sh"

die(){ echo "reap_worktree: $*" >&2; exit 1; }

[ $# -eq 2 ] || die "usage: reap_worktree.sh <run-id> <worktree-path>"
id=$1
wt=$2
[ -x "$REC" ] || [ -f "$REC" ] || die "run_supervision_record.sh not found next to reap_worktree.sh"
[ -d "$wt" ] || die "worktree path '$wt' does not exist"

# Gate 1 — clean-close guard (fail closed on anything but a clean close; same predicate reap_session.sh uses).
if ! bash "$REC" is-closed "$id"; then
  die "refusing to reap worktree for '$id': not a clean close (parked/blocked/stopped/active/unknown are never reaped)"
fi

# Gate 2 — self-only binding: a clean-closed run-id says nothing about which worktree is "its own" unless
# something ties the two together. Require <worktree-path> to be exactly $OLDPWD, i.e. the directory the
# CALLING shell just cd'd out of (the documented calling convention) — this is the only mechanical way to
# bind the two arguments without a naming scheme the product doesn't otherwise have.
[ -n "${OLDPWD:-}" ] || die "refusing to reap '$wt': \$OLDPWD is unset — this script must be invoked immediately after cd'ing OUT of the worktree being reaped, in the same shell"
wt_real=$(cd "$wt" && pwd -P) || die "could not resolve '$wt'"
oldpwd_real=$(cd "$OLDPWD" 2>/dev/null && pwd -P) || die "\$OLDPWD '$OLDPWD' is not a directory — cannot verify self-only binding"
[ "$wt_real" = "$oldpwd_real" ] || die "refusing to reap '$wt': it does not match \$OLDPWD '$OLDPWD' — this script only reaps the worktree the calling shell just cd'd out of, never an arbitrary peer path"

# Resolve the shared checkout's git-dir (not a repo-root directory) FROM the worktree, before we cd away
# from it — a linked worktree's --git-common-dir always points at the main tree's .git, and `--git-dir`
# operates on it directly without assuming its parent is itself a working checkout (true for bare repos /
# `--separate-git-dir` setups, where dirname(common_git_dir) would NOT be a valid working tree).
common_git_dir=$(git -C "$wt" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || \
  die "could not resolve '$wt' as a git worktree (already removed, or not a worktree at all)"

# cd OUT before removing — never run `git worktree remove` from inside the tree it is removing.
cd "$HOME" || die "could not cd out to \$HOME"

echo "reap_worktree: removing worktree '$wt' (git-dir '$common_git_dir') for clean-closed run '$id'"
git --git-dir="$common_git_dir" worktree remove --force "$wt"
echo "reap_worktree: done — branch ref kept (content already landed via squash-merge)"
