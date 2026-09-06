#!/bin/bash
# stage_artifacts.sh — build the close's upload-staging tree (`artifacts/`) as LINKS PLUS A MANIFEST, never
# as a second copy of the run's own files.
#
# INCIDENT (automated-researcher#843, 2026-09-06): closing ONE experiment held the run's artifacts on the box
# three times as real copies (distinct inodes) — 13 unique adapter tars of 0.35 GB appearing 39 times. One of
# those three was this staging step: the executor `cp`-ed the run's own `target_probes/` into an `artifacts/`
# dir so a single `rclone copy` had one root to upload from. The copy is pure duplication with a lifetime of
# the whole close (the peak stood for the entire audit, 82% -> 92% disk in three hours), and it buys nothing
# a hardlink does not: rclone reads bytes through a hardlink exactly as it reads them through the original,
# because a hardlink IS the original — one inode, two names, zero extra bytes.
#
# WHAT IT DOES
#   For every <source>, mirror its directory structure under <staging-dir> and LINK each regular file:
#     - `ln` (HARDLINK) when the source and the staging dir are on the same filesystem — zero bytes, and the
#       staged name is byte-identical to the original by construction, not by a comparison someone has to run.
#     - `ln -s` (absolute SYMLINK) as the cross-filesystem fallback, since a hardlink cannot span devices.
#       This case is REPORTED LOUDLY (an `ARTIFACT-STAGE-SYMLINKS:` line on stdout) because it changes what
#       the close must do downstream — see THE SYMLINK CAVEAT below.
#     - NEVER a `cp`. A copy is the thing this script exists to remove; if neither link form works the file
#       is a hard failure, not a silent duplication.
#   ...and write `MANIFEST.tsv` at the staging root: one row per staged file (`link-type`, staged relative
#   path, absolute source path, bytes), so the tree says WHAT IT POINTS AT rather than only what it contains.
#
# THE STAGING DIR IS THE UPLOAD ROOT, SO IT IS ALSO THE VERIFY ROOT (#846 round 1). `close_record.sh`'s
# byte-verification compares two sets of RELATIVE KEYS, so it holds only when both halves line up:
#   ROOT       — the keys in the store are paths relative to whatever root `rclone copy` was pointed at.
#                That root is THIS STAGING DIR, so `--uploaded-from` must be this staging dir too. Passing
#                the SOURCE dirs instead strips each source's basename off every key (`target_probes/x.tar`
#                becomes `x.tar`) and drops `MANIFEST.tsv` entirely — every object then reads as missing
#                AND surplus at once, which is exactly what an earlier revision of this header told callers
#                to do. The staged layout IS the store layout: verify against the thing that was uploaded.
#   VISIBILITY — which entries rclone counted as files. A HARDLINKED staging tree is regular files, so
#                `close_record.sh`'s default `find -type f` (rclone's own default: skip symlinks) sees
#                exactly what was uploaded, and it verifies just as a copied tree did. A SYMLINKED one does
#                not: the upload must follow links (`-L`, which gpu-job's `r2_copy` always injects, #295),
#                so the close must enumerate the same way — pass `--uploaded-from-follows-symlinks`
#                alongside the same `--uploaded-from <staging-dir>`. That flag makes `close_record.sh` walk
#                with `find -L` (dereferenced sizes, and an unresolvable link is fatal rather than silently
#                dropped) instead of swapping the root out from under the comparison.
# The exact flags for THIS staging run are printed on the `ARTIFACT-STAGE-VERIFY-WITH:` line below, so the
# close copies them rather than re-deriving which case it is in. Put the staging dir on the same filesystem
# as the run's artifacts and the symlink half never arises.
#
# USAGE
#   stage_artifacts.sh <staging-dir> <source>...
#       <staging-dir> must not exist, or must be empty — this script never merges into an existing tree,
#       because a stale leg from an earlier attempt would be uploaded as though this close had staged it.
#       A <source> may be a directory (mirrored under <staging-dir>/<basename>/) or a regular file (linked
#       at <staging-dir>/<basename>). Two sources whose basenames collide are refused: the staged layout IS
#       the layout the artifact store gets, so a silently merged pair would publish an ambiguous store.
#
# STDOUT MARKERS (single lines a close report is written from):
#   ARTIFACT-STAGE: ...              what was staged — file count, bytes NOT duplicated, the link split.
#   ARTIFACT-STAGE-VERIFY-WITH: ...  the exact close_record.sh flags this staging tree must be verified
#                                    with — always emitted, so the close never has to work out which case
#                                    it is in (see THE STAGING DIR IS THE UPLOAD ROOT above).
#   ARTIFACT-STAGE-SYMLINKS: ...     at least one file could only be symlinked, so the upload must run `-L`.
#
# EXIT CODES: 0 = staged · 1 = BLOCK (bad arguments, a collision, or a file that could not be linked). A
# BLOCK LEAVES NO STAGING TREE: whatever this run had already linked is taken back out on the way to exit,
# because a half-staged tree is residue the next `rclone copy` would upload as this close's artifact set —
# the same disease #843 is about, one directory over. It removes only what this run created, inside a
# directory it either minted or verified EMPTY, and it removes LINKS, never the originals' bytes.
set -uo pipefail

MANIFEST_NAME="MANIFEST.tsv"

say(){ echo "stage_artifacts: $*" >&2; }
die(){ echo "stage_artifacts: $*" >&2; exit 1; }

# ---- no-residue-on-failure (#846 round 1, P1) ------------------------------------------------------------
# Every refusal reachable BEFORE the tree exists is checked in pass 1 and needs none of this. The ones that
# can only be reached after — a link that fails mid-traversal, a manifest append that fails, an enumeration
# error, the zero-file case — are facts about the traversal, not about the arguments, so they take their own
# residue back out. One EXIT trap rather than a cleanup call per `die`: a failure site that forgets to clean
# up is precisely how the partial tree survives, and there are eight of them.
#
# WHAT IT REMOVES IS BOUNDED BY CONSTRUCTION, not by a path check at delete time: only `MANIFEST.tsv` and the
# per-source top-level entries THIS RUN created, under a `$STAGING_REAL` that pass 1 either minted or proved
# EMPTY. Nothing pre-existing is in scope, so there is nothing to mistakenly reach. And the tree holds links
# (hardlinks or symlinks), never bytes — unlinking a name never touches the run's own artifacts.
created_staging=0      # 1 only if THIS run minted the staging dir (so only then may it rmdir it)
STAGE_TREE_STARTED=0   # set once the staging dir/manifest exist; before that there is nothing to undo
STAGE_OK=0             # set only after the last check passes — an exit with this clear is a failed staging
CUR_LIST=""            # the mktemp enumeration file in flight, if any
declare -a STAGED_TOPS=()

stage_cleanup(){
  [ -z "$CUR_LIST" ] || rm -f "$CUR_LIST"
  CUR_LIST=""
  { [ "$STAGE_TREE_STARTED" = 1 ] && [ "$STAGE_OK" != 1 ]; } || return 0
  local top
  rm -f "$STAGING_REAL/$MANIFEST_NAME"
  for top in ${STAGED_TOPS[@]+"${STAGED_TOPS[@]}"}; do
    rm -rf "$STAGING_REAL/$top"
  done
  # The dir itself goes only if this run minted it: a caller who pre-created an empty staging dir gets it
  # back the way they left it.
  [ "$created_staging" = 1 ] && rmdir "$STAGING_REAL" 2>/dev/null
  say "removed the partial staging tree under '$STAGING_REAL' (links only — no artifact bytes were touched); nothing was left for a later 'rclone copy' to upload as this close's artifact set"
  return 0
}

[ $# -ge 2 ] || die "usage: stage_artifacts.sh <staging-dir> <source>... (a staging dir and at least one source)"
STAGING=$1; shift

case "$STAGING" in
  "") die "the staging dir must not be empty" ;;
esac
# The staging dir is RESOLVED BEFORE IT IS CREATED, and nothing is created until every source has passed
# the checks below: a refusal that had already minted the directory (and its manifest header) would leave
# residue behind — and residue nobody expects is the whole #840/#843 disease, one directory over.
if [ -e "$STAGING" ]; then
  [ -L "$STAGING" ] && die "refusing to stage into '$STAGING': it is a symlink — pass the real directory"
  [ -d "$STAGING" ] || die "'$STAGING' exists and is not a directory"
  # `find -mindepth 1 -print -quit` rather than `ls`: an entry whose name starts with a dot is content too.
  [ -z "$(find "$STAGING" -mindepth 1 -print -quit 2>/dev/null)" ] \
    || die "refusing to stage into '$STAGING': it is not empty. A staging tree is what gets uploaded, so merging into an earlier attempt's leg would publish files this close never staged. Remove it (it holds links, not data — the originals are untouched) and re-run"
  STAGING_REAL=$(cd "$STAGING" && pwd -P) || die "could not resolve the staging dir '$STAGING'"
else
  staging_parent=$(cd "$(dirname -- "$STAGING")" 2>/dev/null && pwd -P) \
    || die "the staging dir's parent directory does not exist: $(dirname -- "$STAGING")"
  STAGING_REAL="$staging_parent/$(basename -- "$STAGING")"
fi

files=0; bytes=0; hard=0; soft=0; skipped=0
declare -A SEEN_TOP=()
declare -a SRC_ABS=() SRC_TOP=() SRC_KIND=()

# ---- pass 1: validate and resolve every source. Nothing is created in this pass. ----------------------
for src in "$@"; do
  [ -n "$src" ] || die "an empty source path is not a source"
  [ -e "$src" ] || die "source does not exist: $src"
  top=$(basename -- "$src")
  case "$top" in
    .|..|/) die "source '$src' has no usable basename to stage under — pass the directory itself, not '.' or '/'" ;;
  esac
  [ -n "${SEEN_TOP[$top]:-}" ] && die "two sources share the basename '$top' ('${SEEN_TOP[$top]}' and '$src') — they would merge into one staged directory and publish an ambiguous artifact store; rename one, or stage them under separate roots"
  SEEN_TOP[$top]=$src
  if [ -f "$src" ] && [ ! -L "$src" ]; then
    src_abs=$(cd "$(dirname -- "$src")" && pwd -P)/$top || die "could not resolve '$src'"
    kind=file
  else
    [ -d "$src" ] && [ ! -L "$src" ] || die "source '$src' is neither a regular file nor a directory (a symlinked source is refused: stage what it points at, so the manifest names the real path)"
    src_abs=$(cd "$src" && pwd -P) || die "could not resolve '$src'"
    kind=dir
    case "$STAGING_REAL/" in
      "$src_abs"/*) die "refusing to stage '$src_abs' into '$STAGING_REAL': the staging dir is INSIDE the source, so the traversal would stage its own output" ;;
    esac
  fi
  case "$src_abs/" in
    "$STAGING_REAL"/*) die "refusing to stage '$src_abs': it is INSIDE the staging dir '$STAGING_REAL'" ;;
  esac
  SRC_ABS+=("$src_abs"); SRC_TOP+=("$top"); SRC_KIND+=("$kind")
done

# ---- every source checked out: NOW the tree may exist --------------------------------------------------
# The trap arms BEFORE the first thing it may have to remove, not after — an mkdir that succeeded and a
# manifest write that then failed is already residue.
trap stage_cleanup EXIT
STAGE_TREE_STARTED=1
STAGED_TOPS=("${SRC_TOP[@]}")
if [ ! -d "$STAGING_REAL" ]; then
  mkdir -p "$STAGING_REAL" || die "could not create the staging dir '$STAGING_REAL'"
  created_staging=1
fi
MANIFEST="$STAGING_REAL/$MANIFEST_NAME"
printf 'link\tstaged_path\tsource_path\tbytes\n' > "$MANIFEST" \
  || die "could not write the staging manifest '$MANIFEST'"

# link_one <abs-source-file> <staged-rel-path> <bytes>: hardlink, else symlink, else fail. Never a copy.
link_one(){
  local src=$1 rel=$2 size=$3 dest="$STAGING_REAL/$2" kind
  mkdir -p "$(dirname "$dest")" || die "could not create '$(dirname "$dest")' under the staging dir"
  [ -e "$dest" ] && die "refusing to overwrite '$dest' while staging '$src' — two sources map onto the same staged path, and the staged layout is what the artifact store gets"
  if ln -- "$src" "$dest" 2>/dev/null; then
    kind=hardlink; hard=$((hard + 1))
  elif ln -s -- "$src" "$dest" 2>/dev/null; then
    kind=symlink; soft=$((soft + 1))
  else
    die "could not LINK '$src' to '$dest' (neither a hardlink nor a symlink) — refusing to fall back to a copy, which is the duplication this script exists to remove (#843). Stage onto a filesystem that supports links, or upload '$src' directly"
  fi
  printf '%s\t%s\t%s\t%s\n' "$kind" "$rel" "$src" "$size" >> "$MANIFEST" \
    || die "could not append '$rel' to the staging manifest '$MANIFEST'"
  files=$((files + 1)); bytes=$((bytes + size))
}

# ---- pass 2: stage the validated set -------------------------------------------------------------------
i=0
while [ "$i" -lt "${#SRC_ABS[@]}" ]; do
  src_abs=${SRC_ABS[$i]}; top=${SRC_TOP[$i]}; kind=${SRC_KIND[$i]}; i=$((i + 1))
  if [ "$kind" = file ]; then
    size=$(find "$src_abs" -maxdepth 0 -type f -printf '%s' 2>/dev/null) \
      || die "could not size '$src_abs' (a GNU find with -printf is required, same as close_record.sh's own local enumeration)"
    link_one "$src_abs" "$top" "$size"
    continue
  fi
  # Rule (a) of close_record.sh's enumeration discipline, same reasoning one script over: the traversal goes
  # to a FILE whose exit status is checked, never through a pipe that drops it. A short enumeration here
  # would stage a tree missing files the close then uploads and verifies as complete.
  list=$(mktemp) || die "mktemp failed — refusing to stage without an enumeration file whose status can be checked"
  CUR_LIST="$list"   # so the EXIT trap reclaims it however this run ends
  if ! find "$src_abs" -type f -printf '%s\t%P\0' > "$list"; then
    die "enumerating source '$src_abs' FAILED (find exit $?) — nothing further was staged: a partially enumerated source stages a tree that is missing files the close would then upload and call complete"
  fi
  while IFS=$'\t' read -r -d '' size rel; do
    [ -n "$rel" ] || die "enumerating '$src_abs' produced a record with an EMPTY relative path — refusing to stage a set this script cannot name"
    link_one "$src_abs/$rel" "$top/$rel" "$size"
  done < "$list"
  rm -f "$list"; CUR_LIST=""
  # A SYMLINK inside a source is not a regular file, so the enumeration above skipped it — and a skip nobody
  # states is how a close uploads less than it thinks it did (the scaffold manufactures these: executors
  # symlink `work/<exp>/scripts` at the run worktree, #811). They are RECORDED in the manifest and counted on
  # the stdout marker rather than staged: linking a link resolves to a target outside the staged set, and
  # dropping it silently is the one thing that must not happen.
  llist=$(mktemp) || die "mktemp failed — refusing to stage without a symlink scan of '$src_abs'"
  CUR_LIST="$llist"
  if ! find "$src_abs" -type l -printf '%P\0' > "$llist"; then
    die "scanning '$src_abs' for symlinks FAILED (find exit $?) — a skipped symlink this script could not name is content the close would silently not upload"
  fi
  while IFS= read -r -d '' rel; do
    [ -n "$rel" ] || continue
    printf 'skipped-symlink\t%s\t%s\t0\n' "$top/$rel" "$src_abs/$rel" >> "$MANIFEST" \
      || die "could not append the skipped symlink '$rel' to '$MANIFEST'"
    skipped=$((skipped + 1))
    say "SKIPPED SYMLINK (recorded in the manifest, NOT staged and NOT uploaded): '$src_abs/$rel' -> '$(readlink -- "$src_abs/$rel" 2>/dev/null)'"
  done < "$llist"
  rm -f "$llist"; CUR_LIST=""
done

if [ "$files" -eq 0 ]; then
  # Reachable only AFTER the tree exists — it is a fact about the traversal, not about the arguments — so
  # the EXIT trap above takes the manifest-only staging dir back out. Left standing, it would be uploaded by
  # the next `rclone copy` as if it were this close's artifact set.
  die "nothing was staged: the source(s) hold no regular files. An empty staging tree uploads nothing, and close_record.sh would then have no local set to verify a listing against"
fi

# Every check has passed: from here the tree is this close's artifact set, not residue.
STAGE_OK=1

printf 'ARTIFACT-STAGE: dir=%s files=%s bytes=%s hardlinked=%s symlinked=%s skipped_symlinks=%s copied=0 manifest=%s\n' \
  "$STAGING_REAL" "$files" "$bytes" "$hard" "$soft" "$skipped" "$MANIFEST"
# The verify flags are emitted for BOTH cases, always — the close copies them instead of re-deriving which
# case it is in, which is the derivation an earlier revision of this script got wrong (#846 round 1, P0).
# `--uploaded-from` is the STAGING DIR either way: it is the root rclone is pointed at, so it is the root
# whose relative paths become the store's keys. Only the visibility half changes.
if [ "$soft" -gt 0 ]; then
  printf 'ARTIFACT-STAGE-VERIFY-WITH: --uploaded-from %s --uploaded-from-follows-symlinks\n' "$STAGING_REAL"
  printf 'ARTIFACT-STAGE-SYMLINKS: dir=%s symlinked=%s — the upload MUST follow symlinks (-L, which r2_copy always injects, #295) and close_record.sh MUST be passed --uploaded-from-follows-symlinks alongside --uploaded-from %s, so its local set is enumerated the same way the upload read this tree\n' \
    "$STAGING_REAL" "$soft" "$STAGING_REAL"
  say "WARNING: $soft file(s) could only be SYMLINKED (the staging dir is on a different filesystem from the source). The upload must run with -L, and close_record.sh must get --uploaded-from-follows-symlinks — see the ARTIFACT-STAGE-VERIFY-WITH line above, and this script's header."
else
  printf 'ARTIFACT-STAGE-VERIFY-WITH: --uploaded-from %s\n' "$STAGING_REAL"
fi
say "staged $files file(s) ($bytes bytes) into '$STAGING_REAL' as $hard hardlink(s) + $soft symlink(s) — ZERO bytes duplicated ($skipped source symlink(s) recorded but not staged). Manifest: '$MANIFEST'."
