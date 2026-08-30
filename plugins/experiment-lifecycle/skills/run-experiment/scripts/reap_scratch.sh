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
#   2. RUN-ID<->SCRATCH BINDING: <scratch-dir>'s basename must equal <run-id>. This is the `work/<exp>`
#      convention the incident describes (one scratch dir per experiment, named for it), and it is what
#      ties the two arguments together: without it a clean-closed run-id could be paired with ANY path,
#      including a live peer's scratch — the same hole reap_worktree.sh's round-2 review closed with the
#      record's `worktree_path` field. It is also what makes gate 5's destination independent (below).
#   3. PATH SANITY: <scratch-dir> must be a real directory (never a symlink — deleting through one
#      destroys the target while leaving the link), must not be the calling shell's own cwd or an
#      ancestor of it, must not be $HOME, and must sit at least one level below the filesystem root.
#   4. ARCHIVE-BEFORE-DELETE, and NO DELETE WITHOUT A VERIFIED ARCHIVE. Copy follows symlinks (-L) and
#      treats rclone's `Can't follow symlink` NOTICE as an INCOMPLETE copy even when rclone exits 0 —
#      the silent data-loss swallow gpu-job's r2_copy exists to catch (#295). A copy failure, a check
#      failure, or an absent destination listing all leave the directory in place and exit non-zero, so
#      the caller records it on the run's ledger line instead of silently losing the scratch.
#   5. THE VERIFY DESTINATION IS RE-DERIVED, NOT REUSED (#729): `rclone copy "$src" "$D"` followed by
#      `rclone check "$src" "$D"` verifies the wrong destination against itself and passes green — it
#      proves the copy happened, never that it happened to the INTENDED target. Here the destination is
#      re-derived from <run-id> (the same identifier gate 1 just cleared, and gate 2 pinned to this
#      directory), and the store is additionally probed by LISTING THE PARENT PREFIX and matching the
#      run-id in it — never a single-file/single-dir `rclone lsf` of the destination itself, which exits
#      0 on a missing path (gpu-job's r2_exists incident).
#   6. UNSET SEAM -> A LOGGED NO-OP, NEVER A DELETE. With no archive destination configured (or no
#      rclone on PATH) there is nowhere to make the scratch durable, so nothing is deleted and the run
#      reports the wiring gap in its retro — the same shape as reap_session.sh's unset-seam no-op.
#
# WHAT THE INSTANCE SUPPLIES:
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

# Gate 2 — run-id<->scratch binding. The `work/<exp>` convention IS the binding: a clean-closed run-id can
# only ever name the scratch dir that carries its own name, never a peer's.
scratch_name=${scratch_real##*/}
[ "$scratch_name" = "$id" ] || die "refusing to reap '$scratch_real': its basename '$scratch_name' does not equal run-id '$id' — this script only reaps the scratch dir named for the run (the work/<exp> convention), never an unrelated path"

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
if ! rclone check "$scratch_real" "$dest" --one-way; then
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
