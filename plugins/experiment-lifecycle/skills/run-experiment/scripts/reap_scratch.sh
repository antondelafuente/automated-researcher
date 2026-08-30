#!/bin/bash
# reap_scratch.sh — close-time EXECUTOR-SCRATCH teardown: archive the run's own scratch dir to the
# artifact store, VERIFY the archive, then delete the local copy. The third member of the close-time
# teardown symmetry (compute = gpu-job's lease reaper; sessions = reap_session.sh, #282; workspace =
# reap_worktree.sh, #532) — and the last one with nothing on the delete side.
#
# INCIDENT (automated-researcher#792, 2026-08-30): the box disk hit 92% of 225G with only ~7G durable
# behind it. Per-experiment executor scratch was the largest single bucket — 52G across 74 dirs (0.5-3G
# each, 12G for one union dose-response run), every one of them already durable on `main` + the artifact
# store, and nothing ever deleted them. At ~1 experiment/day the box structurally fills in about two
# months and the whole pipeline halts; a manual pass (archive-to-store + delete) took it 92% -> 77%.
# Buying a bigger volume just resets that clock, so the fix lands at the place the scratch is created.
#
# CONTRACT (mirrors reap_worktree.sh's fail-closed gates; the DIFFERENCE is that this one archives first,
# because unlike a worktree the scratch dir is NOT already durable anywhere):
#   1. CLEAN-CLOSE GUARD: only reap if the run-supervision record is a clean close
#      (`run_supervision_record.sh is-closed` = closed AND NOT stopped) — a parked/blocked/crashed run
#      keeps its scratch in place for forensics (repo-janitor's sweep is the backstop for that residue).
#   2. THE DELETE TARGET IS DERIVED, NOT SUPPLIED — and the deletable set is statically bounded to ONE
#      path per run: "<EXPERIMENT_SCRATCH_ROOT>/<run-id>". A basename check alone is NOT a binding (round-1
#      code-review Finding 2): it makes every directory anywhere on the box named <run-id> deletable, so a
#      caller that passed the wrong path — a second checkout's `work/<id>`, an archive copy, a same-named
#      dir under someone else's root — got an `rm -rf` and a "verified" archive of the wrong tree. So the
#      instance declares the ONE scratch root it creates these dirs under; the target is derived from that
#      root plus the run-id, and the <scratch-dir> argument is checked AGAINST that derivation rather than
#      trusted. This is the same invariant repo-janitor's `--scratch-glob` states for its own `rm -rf`
#      (delete scope statically bounded to direct children of one root the researcher wrote out in full),
#      and the same shape as gate 5's re-derived destination: nothing an `rm -rf` or an archive addresses
#      is ever a value this script accepted from its caller. It is also what keeps a clean-closed run-id
#      from ever naming a live peer's scratch — a peer's dir is named for the PEER's run-id.
#   3. PATH SANITY: <scratch-dir> must be a real directory (never a symlink — deleting through one
#      destroys the target while leaving the link), must not be the calling shell's own cwd or an
#      ancestor of it, must not be $HOME, and must sit at least one level below the filesystem root.
#   4. ARCHIVE-BEFORE-DELETE, and NO DELETE WITHOUT A VERIFIED ARCHIVE. Copy follows symlinks (-L) and
#      treats rclone's `Can't follow symlink` NOTICE as an INCOMPLETE copy even when rclone exits 0 —
#      the silent data-loss swallow gpu-job's r2_copy exists to catch (#295). A copy failure, a check
#      failure, or an absent destination listing all leave the directory in place and exit non-zero, so
#      the caller records it on the run's ledger line instead of silently losing the scratch.
#      THE VERIFICATION MUST SEE EXACTLY WHAT THE COPY SAW, so `rclone check` carries -L too (round-1
#      code-review Finding 1): without it rclone skips source symlinks while listing, and `--one-way`
#      ignores their copies at the destination as extras — so every byte that reached the store only
#      BECAUSE the copy followed a link would be deleted locally without ever having been verified. An
#      asymmetric verify is the exact failure mode gate 5 exists to prevent, one argument over.
#   5. THE VERIFY DESTINATION IS RE-DERIVED, NOT REUSED (#729): `rclone copy "$src" "$D"` followed by
#      `rclone check "$src" "$D"` verifies the wrong destination against itself and passes green — it
#      proves the copy happened, never that it happened to the INTENDED target. Here the destination is
#      re-derived from <run-id> (the same identifier gate 1 just cleared, and gate 2 pinned to this
#      directory), and the store is additionally probed by LISTING THE PARENT PREFIX and matching the
#      run-id in it — never a single-file/single-dir `rclone lsf` of the destination itself, which exits
#      0 on a missing path (gpu-job's r2_exists incident). That probe has a PRECONDITION: it can only
#      pass if the copy had bytes to write, since rclone creates no empty destination directories. A
#      scratch tree holding no files therefore takes an explicit branch — deleted with "nothing to
#      archive" logged, never run through a probe that could only report a false failure and strand it
#      locally forever (round-2 code-review Finding 2). The invariant is that no BYTES are deleted
#      without a verified archive; a tree with no bytes has nothing to verify and nothing to lose.
#   6. UNSET SEAM -> A LOGGED NO-OP, NEVER A DELETE. With no scratch root declared there is no bounded
#      delete target to derive; with no archive destination configured (or no rclone on PATH) there is
#      nowhere to make the scratch durable. Either way nothing is deleted and the run reports the wiring
#      gap in its retro — the same shape as reap_session.sh's unset-seam no-op.
#
# WHAT THE INSTANCE SUPPLIES (both are instance values, so the product ships neither path):
#   EXPERIMENT_SCRATCH_ROOT — the absolute LOCAL directory this instance creates per-run scratch dirs
#   under (e.g. "<home>/work"). It bounds what may ever be deleted: the only reapable path for run <id>
#   is "<root>/<id>", nothing else, at any depth. Unset -> no-op (6).
#   EXPERIMENT_SCRATCH_ARCHIVE_DEST — an rclone destination ROOT for archived executor scratch (e.g.
#   "<remote>:<bucket>/archive/work"). Per-run archives land at "<root>/<run-id>". Unset -> no-op (6).
#
# USAGE: reap_scratch.sh <run-id> <scratch-dir>
# Call it at close, AFTER artifact-store upload is verified and `log-experiment` has merged the record —
# same sequencing responsibility as reap_worktree.sh gate 4: this script cannot re-check those itself.
set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REC="$SCRIPT_DIR/run_supervision_record.sh"

say(){ echo "reap_scratch: $*" >&2; }
die(){ echo "reap_scratch: $*" >&2; exit 1; }

[ $# -eq 2 ] || die "usage: reap_scratch.sh <run-id> <scratch-dir>"
id=$1
scratch=$2
[ -n "$id" ] || die "run-id must not be empty"
[ -f "$REC" ] || die "run_supervision_record.sh not found next to reap_scratch.sh"

# Gate 1 — clean-close guard (identical predicate to reap_session.sh / reap_worktree.sh).
if ! bash "$REC" is-closed "$id"; then
  die "refusing to reap scratch for '$id': not a clean close (parked/blocked/stopped/active/unknown are never reaped)"
fi

# Gate 3a — the path must be a real directory, not a symlink to one. `rm -rf` through a symlink removes
# the LINK and leaves the target, but `rclone copy` reads THROUGH it — so a symlinked scratch dir would
# archive one tree and delete a different thing. Refuse rather than guess which was meant.
[ -e "$scratch" ] || die "scratch dir '$scratch' does not exist"
[ -L "$scratch" ] && die "refusing to reap '$scratch': it is a symlink — pass the real directory"
[ -d "$scratch" ] || die "scratch path '$scratch' is not a directory"
scratch_real=$(cd "$scratch" && pwd -P) || die "could not resolve '$scratch'"

# Gate 2 — the delete target is DERIVED from (declared root, run-id), and the argument is checked against
# it. Unset root -> no-op, because without a declared root there is no bounded delete scope to derive and
# the only remaining "binding" would be a basename, which is not one (see the CONTRACT block).
scratch_root=${EXPERIMENT_SCRATCH_ROOT:-}
if [ -z "${scratch_root// /}" ]; then
  say "NO-OP: EXPERIMENT_SCRATCH_ROOT is unset — scratch '$scratch_real' left in place (without a declared scratch root there is no bounded delete target to derive, and a basename alone would make every dir named '$id' on this box deletable). Report this wiring gap in the retro."
  exit 0
fi
case "$scratch_root" in
  /*) : ;;
  *) die "EXPERIMENT_SCRATCH_ROOT must be an ABSOLUTE path (got '$scratch_root') — a relative root would make the delete target depend on the caller's cwd" ;;
esac
root_real=$(cd "$scratch_root" 2>/dev/null && pwd -P) || die "EXPERIMENT_SCRATCH_ROOT '$scratch_root' is not a readable directory — refusing to derive a delete target from a root that does not resolve"
[ "$root_real" != "/" ] || die "refusing to use '/' as EXPERIMENT_SCRATCH_ROOT: a scratch root is never the filesystem root"
expected="$root_real/$id"
[ "$scratch_real" = "$expected" ] || die "refusing to reap '$scratch_real': run '$id''s scratch dir is '$expected' (derived from EXPERIMENT_SCRATCH_ROOT + the run-id) and this path is not it — this script only ever deletes the one derived path, never a caller-supplied one"

# Gate 3b — never delete $HOME, a root-level directory, or a directory the calling shell is standing in
# (or under). A shell whose cwd vanishes mid-close produces confusing downstream failures, and the two
# path shapes below are never a per-experiment scratch dir under any convention.
case "$scratch_real" in
  /*/*) : ;;
  *) die "refusing to reap '$scratch_real': a per-experiment scratch dir is never a root-level path" ;;
esac
home_real=$(cd "$HOME" 2>/dev/null && pwd -P) || home_real=""
[ -n "$home_real" ] && [ "$scratch_real" = "$home_real" ] && die "refusing to reap '$scratch_real': it is \$HOME"
pwd_real=$(pwd -P 2>/dev/null) || pwd_real=""
case "${pwd_real:-/dev/null}" in
  "$scratch_real"|"$scratch_real"/*) die "refusing to reap '$scratch_real': the calling shell is standing inside it — cd out first (e.g. \$HOME), then re-run" ;;
esac
# Never reap the run's own WORKTREE through this path — that is reap_worktree.sh's job, behind its own
# binding + `git worktree remove`. A worktree deleted with `rm -rf` leaves a stale administrative record.
recorded_wt=$(bash "$REC" worktree-path "$id" 2>/dev/null || true)
if [ -n "$recorded_wt" ]; then
  recorded_real=$(cd "$recorded_wt" 2>/dev/null && pwd -P) || recorded_real=""
  [ -n "$recorded_real" ] && [ "$scratch_real" = "$recorded_real" ] && \
    die "refusing to reap '$scratch_real': it is run '$id''s bound worktree — use reap_worktree.sh for that, never an rm -rf"
fi

# Gate 6 — unset seam / no rclone: a logged NO-OP. Nothing is archived, so nothing may be deleted.
dest_root=${EXPERIMENT_SCRATCH_ARCHIVE_DEST:-}
if [ -z "${dest_root// /}" ]; then
  say "NO-OP: EXPERIMENT_SCRATCH_ARCHIVE_DEST is unset — scratch '$scratch_real' left in place (nothing may be deleted without a verified archive). Report this wiring gap in the retro."
  exit 0
fi
if ! command -v rclone >/dev/null 2>&1; then
  say "NO-OP: rclone is not on PATH — scratch '$scratch_real' left in place (nothing may be deleted without a verified archive). Report this wiring gap in the retro."
  exit 0
fi

# Gate 5 — the destination is DERIVED FROM <run-id>, once, and both the copy and the verification use
# that derivation rather than a caller-supplied path. Strip trailing slashes so "<root>/" and "<root>"
# resolve identically (rclone treats "<root>//<id>" as a distinct, empty prefix).
while [ "${dest_root%/}" != "$dest_root" ]; do dest_root=${dest_root%/}; done
[ -n "$dest_root" ] || die "EXPERIMENT_SCRATCH_ARCHIVE_DEST resolved to an empty destination root"
dest="$dest_root/$id"

# Gate 4/5 PRECONDITION — does this tree hold anything the archive must carry? `rclone copy` creates no
# empty directories at the destination, so for a scratch tree with no files there is nothing for the
# parent-listing probe to find and the probe CANNOT pass (round-2 code-review Finding 2). Left as-is, the
# gate that exists to catch "the copy went nowhere" would instead strand every empty scratch dir on the
# box forever — the exact residue #792 is about, failing the issue's acceptance bar ("a closed experiment
# leaves no scratch dir unless the check failed"). The invariant is that no BYTES are deleted without a
# verified archive; a tree with no bytes has nothing to verify and nothing to lose, so it is deleted with
# that stated explicitly rather than archived through a probe that can only ever report a false failure.
# Anything that is not a directory counts as content, symlinks included: the -L copy turns them into
# files at the destination. A find that fails (an unreadable subdirectory is a SHORT READ, never "no
# files down there") is treated as NON-empty, so the full archive-and-verify path runs and can only
# refuse to delete.
find_rc=0
tree_content=$(find "$scratch_real" -mindepth 1 ! -type d -print -quit 2>/dev/null) || find_rc=$?
[ "$find_rc" = 0 ] || tree_content="unreadable-tree-assume-content"
if [ -z "$tree_content" ]; then
  say "scratch '$scratch_real' holds no files — nothing to archive (and rclone copy would create no destination prefix to verify). Deleting the empty tree."
  rm -rf -- "$scratch_real" || die "empty scratch delete failed ('rm -rf $scratch_real') — delete it by hand"
  say "done — empty scratch removed; nothing was archived because there was nothing to archive"
  exit 0
fi

say "archiving scratch '$scratch_real' -> '$dest' before deleting it"

# Gate 4 — hardened copy. -L is appended LAST so nothing can override it; a `Can't follow symlink` NOTICE
# is an INCOMPLETE copy even when rclone exits 0 (gpu-job#295's silent data-loss swallow).
copy_log=$(mktemp) || die "mktemp failed — refusing to copy without a log to scan for skipped symlinks"
rclone copy "$scratch_real" "$dest" -L 2>&1 | tee "$copy_log"
copy_rc=${PIPESTATUS[0]}
notice=0
grep -qi "can't follow symlink" "$copy_log" && notice=1
rm -f "$copy_log"
if [ "$copy_rc" != 0 ]; then
  die "ARCHIVE FAILED (rclone copy exited $copy_rc): scratch '$scratch_real' left in place. Record this on the run's ledger line."
fi
if [ "$notice" = 1 ]; then
  die "ARCHIVE INCOMPLETE (rclone logged \"Can't follow symlink\" — a link's bytes were SKIPPED): scratch '$scratch_real' left in place. Record this on the run's ledger line."
fi

# Verification, part 1: every source file exists at the destination with matching size/hash. --one-way so
# a previous partial attempt's leftovers at the destination are not themselves reported as differences.
# -L MUST match the copy's -L: without it rclone skips source symlinks while listing, and --one-way then
# ignores their copies at the destination as extras — so link-followed bytes would be deleted locally
# having never been verified at all (round-1 code-review Finding 1).
if ! rclone check "$scratch_real" "$dest" --one-way -L; then
  die "ARCHIVE CHECK FAILED (rclone check '$scratch_real' vs '$dest'): scratch left in place. Record this on the run's ledger line."
fi

# Verification, part 2 (#729 + gpu-job's r2_exists incident): prove something actually landed at the
# INTENDED prefix by listing the PARENT and matching the run-id in it — a single-path `rclone lsf` exits
# 0 on a missing path, so it would pass against a destination that was never written.
# -F as well as -x: a run-id is a free-form identifier, so treating it as a regex would let '.' match any
# character and pass this gate against a DIFFERENT, similarly-named archive prefix.
if ! rclone lsf "$dest_root/" 2>/dev/null | grep -qxF "$id/"; then
  die "ARCHIVE NOT FOUND at the intended destination: '$id/' is not listed under '$dest_root/'. Scratch left in place. Record this on the run's ledger line."
fi

say "archive VERIFIED at '$dest' — deleting local scratch '$scratch_real'"
rm -rf -- "$scratch_real" || die "archive verified but 'rm -rf $scratch_real' failed — delete it by hand"
say "done — scratch archived and removed (recover with: rclone copy '$dest' '$scratch_real')"
