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
#   2. RUN-ID<->WORKTREE BINDING (automated-researcher#535 review, round 2): a clean-closed run-id alone
#      does not prove <worktree-path> is THAT run's own tree unless something ties the two arguments
#      together — an earlier revision required only <worktree-path> == $OLDPWD, but that binds the argument
#      to "whatever directory the caller just cd'd out of", not to the run-id at all: a caller that cd's out
#      of a PEER's worktree and passes that same path alongside any OTHER clean-closed run-id would still
#      pass. The actual binding is the run-supervision record's own `worktree_path` field (set via
#      `--worktree` at `start`/`checkpoint`, from INSIDE the run's own worktree): this script reads
#      `run_supervision_record.sh worktree-path <run-id>` and requires it to resolve to the SAME real path
#      as <worktree-path> — a run-id can only ever name the worktree IT bound at its own start, never an
#      unrelated one. Fails closed if the record has no worktree bound at all.
#   3. SELF-ONLY SEQUENCING (defense in depth, kept alongside gate 2): <worktree-path> must additionally
#      equal `$OLDPWD`, i.e. the directory the CALLING shell just `cd`'d out of — the calling skill's
#      documented sequence ("cd OUT of the worktree yourself FIRST ... then run reap_worktree.sh <run-id>
#      <this worktree's path>"). Cheap, and catches a caller invoking this from the wrong place even when
#      gate 2's path happens to match.
#   4. SEQUENCING IS THE SAFETY STORY, and it is the CALLER's responsibility, not this script's: invoke
#      this only AFTER artifact-store upload is verified AND log-experiment has merged the record —
#      teardown-before-upload-verified loses data. This script has no way to re-check upload/merge state
#      itself; the clean-close guard above is the only mechanical gate it can enforce.
#   5. --force IS REQUIRED, and safe ONLY behind gates 1+4 above: executor scratch (e.g. `work/`) is
#      untracked by design, so a plain `git worktree remove` would refuse on untracked content every time.
#   6. KEEP THE BRANCH REF: content already landed via squash-merge, so the ref is cheap and preserves
#      recoverability. This script removes the WORKTREE only — it never runs `git branch -d`.
#
# USAGE: reap_worktree.sh <run-id> <worktree-path>
# <worktree-path> MUST equal both the run-supervision record's bound `worktree-path` for <run-id> (gate 2)
# AND $OLDPWD (gate 3) — call this immediately after cd'ing out of it, in the same shell. Resolves the
# worktree's shared/main checkout itself via its git-dir (`--git-common-dir`, read from the worktree BEFORE
# cd'ing away) — no separate repo-root argument to get wrong, and no assumption that the git-dir's parent is
# itself a working checkout (bare / `--separate-git-dir` safe). Never touches the shared checkout beyond the
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

wt_real=$(cd "$wt" && pwd -P) || die "could not resolve '$wt'"

# Gate 2 — run-id<->worktree binding: the run-supervision record's OWN worktree_path (bound at start, from
# inside the run's own worktree) is the only thing that ties <run-id> to a SPECIFIC worktree. Fail closed if
# nothing is bound (a record with no recorded worktree can never be paired with one supplied at reap time),
# and fail closed if the recorded path doesn't resolve to the same real directory as <worktree-path>.
recorded_wt=$(bash "$REC" worktree-path "$id" 2>/dev/null || true)
[ -n "$recorded_wt" ] || die "refusing to reap '$wt': run '$id' has no worktree_path bound in its run-supervision record — cannot verify this is its own tree"
recorded_real=$(cd "$recorded_wt" 2>/dev/null && pwd -P) || die "run '$id''s recorded worktree_path '$recorded_wt' does not resolve to a directory — refusing to reap an unverifiable binding"
[ "$wt_real" = "$recorded_real" ] || die "refusing to reap '$wt': it does not match run '$id''s recorded worktree_path '$recorded_wt' — this script only reaps the worktree THAT run-id bound at its own start, never an unrelated/peer path"

# Gate 3 — self-only sequencing (defense in depth): <worktree-path> must ALSO equal $OLDPWD, i.e. the
# directory the CALLING shell just cd'd out of (the documented calling convention).
[ -n "${OLDPWD:-}" ] || die "refusing to reap '$wt': \$OLDPWD is unset — this script must be invoked immediately after cd'ing OUT of the worktree being reaped, in the same shell"
oldpwd_real=$(cd "$OLDPWD" 2>/dev/null && pwd -P) || die "\$OLDPWD '$OLDPWD' is not a directory — cannot verify self-only sequencing"
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
