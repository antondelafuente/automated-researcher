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
#   2. SEQUENCING IS THE SAFETY STORY, and it is the CALLER's responsibility, not this script's: invoke
#      this only AFTER artifact-store upload is verified AND log-experiment has merged the record —
#      teardown-before-upload-verified loses data. This script has no way to re-check upload/merge state
#      itself; the clean-close guard above is the only mechanical gate it can enforce.
#   3. --force IS REQUIRED, and safe ONLY behind gates 1+2 above: executor scratch (e.g. `work/`) is
#      untracked by design, so a plain `git worktree remove` would refuse on untracked content every time.
#   4. KEEP THE BRANCH REF: content already landed via squash-merge, so the ref is cheap and preserves
#      recoverability. This script removes the WORKTREE only — it never runs `git branch -d`.
#
# USAGE: reap_worktree.sh <run-id> <worktree-path>
# Resolves the worktree's shared/main checkout itself (`--git-common-dir`, read from the worktree BEFORE
# cd'ing away) — no separate repo-root argument to get wrong. Never touches the shared checkout beyond the
# one `worktree remove` call.
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

# Resolve the shared checkout (the main working tree this linked worktree belongs to) FROM the worktree,
# before we cd away from it — a linked worktree's --git-common-dir always points at the main tree's .git.
common_git_dir=$(git -C "$wt" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || \
  die "could not resolve '$wt' as a git worktree (already removed, or not a worktree at all)"
repo_root=$(dirname "$common_git_dir")
[ -d "$repo_root" ] || die "resolved repo root '$repo_root' does not exist"

# cd OUT before removing — never run `git worktree remove` from inside the tree it is removing.
cd "$HOME" || die "could not cd out to \$HOME"

echo "reap_worktree: removing worktree '$wt' (repo root '$repo_root') for clean-closed run '$id'"
git -C "$repo_root" worktree remove --force "$wt"
echo "reap_worktree: done — branch ref kept (content already landed via squash-merge)"
