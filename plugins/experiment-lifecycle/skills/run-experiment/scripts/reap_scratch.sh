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
#      AND IT MUST NOT BE, OR CONTAIN, A MOUNT POINT (round-3 code-review Finding 1). Gate 2's bound is a
#      PATH bound, and a mount underneath the derived path escapes it: `rm -rf` deletes a bind mount's
#      contents THROUGH the mount and only THEN fails with EBUSY on the mount point itself, so the loud
#      non-zero exit this script's callers rely on arrives after the mounted data is already destroyed.
#      Mount-freedom is established from /proc/self/mountinfo and nothing else: for a bind mount whose
#      source is on the same filesystem, `ismount`/`st_dev`/`rm --one-file-system` all read it as ordinary
#      scratch. An unreadable table is UNKNOWN, and UNKNOWN never reaches a delete (gate 6's shape). An
#      ANCESTOR mount blocks nothing — a scratch root on its own volume is the normal layout.
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
#      DANGLING symlinks are pre-scanned out of BOTH sides of that symmetry (see 4b).
#   4b. A DANGLING SYMLINK IS EXCLUDED AND LOGGED, NOT ARCHIVED AND NOT FATAL.
#      INCIDENT (automated-researcher#811, 2026-08-31): with -L, rclone fails the LISTING on a symlink
#      whose target is gone (`Listing error: symlink: stat …: no such file or directory`, exit 6, "Can't
#      retry any of the errors"), so gate 4 refused and the dir stayed on disk forever. The scaffold
#      MANUFACTURES that condition: executors symlink `work/<exp>/scripts` at the run worktree, and
#      reap_worktree.sh removes that worktree earlier in the SAME close — so by the time this runs the
#      link dangles. 2 of 27 clean-closed scratch dirs failed exactly this way (1.3G + 259M); removing the
#      dead link and re-running reaped both. So a pre-scan lists every dangling link, LOGS it (path +
#      target) on the reap output, and passes an `--exclude` for it. Excluded rather than deleted, so the
#      record shows what was skipped — and a link to nothing carries no BYTES, which puts it in the same
#      class as the empty tree of gate 5's precondition, not in the class of data. A link whose target
#      EXISTS is untouched: its bytes are archived by -L, and the `Can't follow symlink` NOTICE above
#      still refuses for it (a live link whose bytes were silently skipped is data loss; a dangling link
#      is not). The excludes go on `rclone check` identically — asymmetry there would leave the verify to
#      list, and abort on, the exact entry the copy skipped (gate 4's own invariant, one argument over).
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
#      A tree whose ONLY content is dangling symlinks reaches that same branch (#811): after 4b's
#      exclusions the copy would write zero bytes, so no destination prefix appears and the probe could
#      only ever report a false failure. The dangling paths are still logged before it is deleted.
#   6. UNSET SEAM -> A NO-OP THAT IS LOUD ON THE RECORD, NEVER A DELETE. With no scratch root declared
#      there is no bounded delete target to derive; with no archive destination configured (or no rclone on
#      PATH) there is nowhere to make the scratch durable. Either way nothing is deleted.
#      INCIDENT (automated-researcher#804, 2026-08-31): as a plain exit-0 log line, that no-op was invisible
#      — neither seam was ever wired on the instance, the message went to the executor's stdout only, and
#      SEVEN experiments closed reaping ZERO scratch dirs before a human noticed the disk back at 92%. So a
#      gap now surfaces the way a FAILED ARCHIVE CHECK does: a one-line `SCRATCH-REAP-GAP:` marker on
#      STDOUT for the close report / ledger line, and a distinct non-zero EXIT 3 the caller cannot miss.
#      Exit 3 is deliberately NOT 1: nothing was lost and nothing needs recovering (the scratch is exactly
#      where it was), so the caller must be able to tell this apart from `die`'s "an archive/verify step
#      FAILED" without parsing prose. The same shape covers the platform gap (no readable mount table) —
#      same consequence, same invisibility, same record.
#
# WHAT THE INSTANCE SUPPLIES (both are instance values, so the product ships neither path):
#   EXPERIMENT_SCRATCH_ROOT — the absolute LOCAL directory this instance creates per-run scratch dirs
#   under (e.g. "<home>/work"). It bounds what may ever be deleted: the only reapable path for run <id>
#   is "<root>/<id>", nothing else, at any depth. Unset -> recorded gap, exit 3 (6).
#   EXPERIMENT_SCRATCH_ARCHIVE_DEST — an rclone destination ROOT for archived executor scratch (e.g.
#   "<remote>:<bucket>/archive/work"). Per-run archives land at "<root>/<run-id>". Unset -> recorded gap,
#   exit 3 (6).
#
# USAGE: reap_scratch.sh <run-id> <scratch-dir>
# Call it at close, AFTER artifact-store upload is verified and `log-experiment` has merged the record —
# same sequencing responsibility as reap_worktree.sh gate 4: this script cannot re-check those itself.
#
# EXIT CODES (all three are outcomes a close report states; none of them is "ignore me"):
#   0  reaped (archived + verified + deleted), or an empty tree deleted with nothing to archive
#   1  a REAL failure — a gate refused, or an archive/verify step failed. The scratch is still on disk and
#      the run's ledger line says so.
#   3  WIRING/PLATFORM GAP (#804) — nothing was archived and nothing was deleted because a seam is unset
#      (or no rclone / no readable mount table). Nothing is lost; the wiring is missing. Stdout carries a
#      single `SCRATCH-REAP-GAP: ...` line for the close report and the ledger line.
set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REC="$SCRIPT_DIR/run_supervision_record.sh"

GAP_EXIT=3

say(){ echo "reap_scratch: $*" >&2; }
die(){ echo "reap_scratch: $*" >&2; exit 1; }
# gap <cause-slug> <one-line detail> — the loud, on-the-record no-op (#804). The marker goes to STDOUT
# because that is the stream a close report is written from; the human sentence goes to stderr with the
# rest of the log; and the exit status is non-zero so an unattended close cannot silently skip a reap the
# way seven of them did. Every call site sits below where `id` and `scratch_real` are bound; the `:-`
# fallbacks keep a future one from turning into an unbound-variable abort INSTEAD of the gap report, which
# would be the same invisibility this exists to remove.
gap(){
  local cause=$1; shift
  local where=${scratch_real:-${scratch:-unresolved}}
  printf 'SCRATCH-REAP-GAP: run=%s cause=%s reaped=no scratch=%s — %s\n' \
    "${id:-unknown}" "$cause" "$where" "$*"
  say "WIRING GAP [$cause]: $* Scratch '$where' was NOT archived and NOT deleted (nothing is lost — the wiring is missing). Put the SCRATCH-REAP-GAP line on the close report AND the run's ledger line; exit $GAP_EXIT."
  exit "$GAP_EXIT"
}

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
  gap EXPERIMENT_SCRATCH_ROOT-unset "EXPERIMENT_SCRATCH_ROOT is unset, so there is no bounded delete target to derive (a basename alone would make every dir named '$id' on this box deletable) — wire the instance's scratch root."
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

# Gate 3c — NEVER DELETE THROUGH A MOUNT POINT. Placed here so BOTH `rm -rf` sites below (the empty-tree
# branch and the post-verify delete) sit behind it. `rm -rf` unlinks a bind mount's contents through the
# mount and only afterwards fails with EBUSY on the mount point, so "it exits non-zero, the caller records
# it" is no protection at all — the mounted dataset is gone by then. The mount table is the only source
# that sees it: a same-filesystem bind mount has an IDENTICAL st_dev on both sides, so `--one-file-system`
# and every `ismount` check read it as ordinary scratch. `printf -v` (not `$(printf)`) so a mount point
# ending in an escaped newline keeps it, and so this doesn't fork once per mounted filesystem.
mountinfo=${REAP_SCRATCH_MOUNTINFO:-/proc/self/mountinfo}
if [ -r "$mountinfo" ]; then
  while read -r _ _ _ _ mp _; do
    printf -v mp '%b' "$mp"   # mountinfo octal-escapes spaces/tabs/newlines/backslashes in mount points
    case "$mp" in
      /*) : ;;
      # A table that does not parse establishes nothing — treating the line as "lists no mount" would
      # silently shrink the set being checked, which is the one thing this gate must never do.
      *) die "refusing to reap '$scratch_real': '$mountinfo' has a line whose mount-point field is not an absolute path — mount-freedom cannot be established from a table that does not parse, and nothing is deleted without it" ;;
    esac
    case "$mp" in
      "$scratch_real"|"$scratch_real"/*)
        die "refusing to reap '$scratch_real': it is, or contains, a mount point ('$mp') — deleting through a mount destroys the mounted data, not scratch. Record this on the run's ledger line." ;;
    esac
  done < "$mountinfo"
else
  gap mountinfo-unreadable "cannot enumerate mount points on this platform ('$mountinfo' unreadable), so mount-freedom cannot be established and nothing may be deleted without it."
fi

# Gate 6 — unset seam / no rclone: a no-op that is LOUD ON THE RECORD (#804). Nothing is archived, so
# nothing may be deleted.
dest_root=${EXPERIMENT_SCRATCH_ARCHIVE_DEST:-}
if [ -z "${dest_root// /}" ]; then
  gap EXPERIMENT_SCRATCH_ARCHIVE_DEST-unset "EXPERIMENT_SCRATCH_ARCHIVE_DEST is unset, so there is nowhere to make this scratch durable and nothing may be deleted without a verified archive — wire the instance's archive destination."
fi
if ! command -v rclone >/dev/null 2>&1; then
  gap rclone-missing "rclone is not on PATH, so the archive cannot be made or verified and nothing may be deleted without it."
fi

# Gate 5 — the destination is DERIVED FROM <run-id>, once, and both the copy and the verification use
# that derivation rather than a caller-supplied path. Strip trailing slashes so "<root>/" and "<root>"
# resolve identically (rclone treats "<root>//<id>" as a distinct, empty prefix).
while [ "${dest_root%/}" != "$dest_root" ]; do dest_root=${dest_root%/}; done
[ -n "$dest_root" ] || die "EXPERIMENT_SCRATCH_ARCHIVE_DEST resolved to an empty destination root"
dest="$dest_root/$id"

# Gate 4b PRE-SCAN — dangling symlinks (#811). Every symlink in the tree is classified BEFORE anything is
# copied or deleted: a link whose target resolves is ordinary content the -L copy will carry, a link whose
# target is gone carries no bytes and would fail the -L listing for the whole tree. `[ -e ]` follows the
# link, so it answers exactly the question rclone's `os.Stat` asks (a circular link is unresolvable too,
# and lands on the same side). It cannot tell "target is gone" from "target cannot be stat'd", so a live
# link with an unreadable target is classified here as dangling — which costs the archive a DUPLICATE of
# bytes that live outside this tree and are not what the rm -rf below deletes (a target INSIDE the tree is
# enumerated and copied on its own, link or no link), so the no-bytes-deleted-unverified invariant holds
# either way. A scan that fails (an unreadable subdirectory is a SHORT READ, never "no
# links down there") can only UNDER-report: the copy then hits the link this missed and refuses loudly with
# the scratch still on disk — the pre-#811 behavior, never a delete.
link_scan_rc=0
link_list=$(mktemp) || die "mktemp failed — refusing to copy without a dangling-symlink pre-scan"
find "$scratch_real" -mindepth 1 -type l -print0 > "$link_list" 2>/dev/null || link_scan_rc=$?
dangling=()
live_symlink=0
while IFS= read -r -d '' link; do
  if [ -e "$link" ]; then live_symlink=1; else dangling+=("$link"); fi
done < "$link_list"
rm -f "$link_list"

# rclone filter patterns are GLOBS, so a literal path has to be escaped before it can be an --exclude: an
# unescaped `*` or `[…]` in a filename would exclude MORE than the one dead link, silently dropping real
# files from an archive that is about to authorize an rm -rf. Escaping in-shell (no fork, no sed dialect
# question about `\` inside a bracket expression).
glob_escape(){
  local s=$1 out='' i=0 c
  while [ "$i" -lt "${#s}" ]; do
    c=${s:$i:1}
    case "$c" in
      '\'|'['|']'|'*'|'?'|'{'|'}') out="$out\\$c" ;;
      *) out="$out$c" ;;
    esac
    i=$((i+1))
  done
  printf '%s' "$out"
}

# The excludes are built ONCE and used by the copy and the check identically (gate 4's symmetry). Anchored
# with a leading '/' so the pattern is the path relative to the transfer root, not a name match anywhere.
excludes=()
for link in ${dangling[@]+"${dangling[@]}"}; do
  say "DANGLING SYMLINK (excluded from the archive — it points at nothing, so it carries no bytes): '$link' -> '$(readlink -- "$link" 2>/dev/null)'"
  excludes+=( --exclude "/$(glob_escape "${link#"$scratch_real"/}")" )
done

# Gate 4/5 PRECONDITION — does this tree hold anything the archive must carry? `rclone copy` creates no
# empty directories at the destination, so for a scratch tree with no files there is nothing for the
# parent-listing probe to find and the probe CANNOT pass (round-2 code-review Finding 2). Left as-is, the
# gate that exists to catch "the copy went nowhere" would instead strand every empty scratch dir on the
# box forever — the exact residue #792 is about, failing the issue's acceptance bar ("a closed experiment
# leaves no scratch dir unless the check failed"). The invariant is that no BYTES are deleted without a
# verified archive; a tree with no bytes has nothing to verify and nothing to lose, so it is deleted with
# that stated explicitly rather than archived through a probe that can only ever report a false failure.
# Anything that is not a directory counts as content, LIVE symlinks included: the -L copy turns them into
# files at the destination. DANGLING links do not (#811) — they are excluded above, so a tree holding
# nothing else copies zero bytes and belongs on this branch rather than in front of a probe that cannot
# pass. A find that fails (an unreadable subdirectory is a SHORT READ, never "no files down there") is
# treated as NON-empty, so the full archive-and-verify path runs and can only refuse to delete; the same
# goes for a short link scan, whose live/dangling split is then not trustworthy either.
find_rc=0
tree_content=$(find "$scratch_real" -mindepth 1 ! -type d ! -type l -print -quit 2>/dev/null) || find_rc=$?
if [ "$find_rc" != 0 ]; then
  tree_content="unreadable-tree-assume-content"
elif [ -z "$tree_content" ] && [ "$live_symlink" = 1 ]; then
  tree_content="live-symlink-is-content"
elif [ -z "$tree_content" ] && [ "$link_scan_rc" != 0 ]; then
  tree_content="unreadable-link-scan-assume-content"
fi
if [ -z "$tree_content" ]; then
  if [ "${#dangling[@]}" -gt 0 ]; then
    say "scratch '$scratch_real' holds nothing but ${#dangling[@]} dangling symlink(s) (logged above) — they point at nothing, so there are no bytes to archive (and rclone copy would create no destination prefix to verify). Deleting the tree."
  else
    say "scratch '$scratch_real' holds no files — nothing to archive (and rclone copy would create no destination prefix to verify). Deleting the empty tree."
  fi
  rm -rf -- "$scratch_real" || die "empty scratch delete failed ('rm -rf $scratch_real') — delete it by hand"
  say "done — empty scratch removed; nothing was archived because there was nothing to archive"
  exit 0
fi

say "archiving scratch '$scratch_real' -> '$dest' before deleting it"

# Gate 4 — hardened copy. -L is appended LAST so nothing can override it; a `Can't follow symlink` NOTICE
# is an INCOMPLETE copy even when rclone exits 0 (gpu-job#295's silent data-loss swallow). The 4b excludes
# sit before -L for the same reason.
copy_log=$(mktemp) || die "mktemp failed — refusing to copy without a log to scan for skipped symlinks"
rclone copy "$scratch_real" "$dest" ${excludes[@]+"${excludes[@]}"} -L 2>&1 | tee "$copy_log"
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
# having never been verified at all (round-1 code-review Finding 1). The 4b excludes must match the copy's
# for the same reason in the other direction: an exclude the copy carried and the check did not leaves the
# check to list — and abort on — the very dangling link the copy was told to skip (#811).
if ! rclone check "$scratch_real" "$dest" --one-way ${excludes[@]+"${excludes[@]}"} -L; then
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
