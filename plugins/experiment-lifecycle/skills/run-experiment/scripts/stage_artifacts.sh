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
# THE SYMLINK CAVEAT (state it, don't discover it): `close_record.sh --uploaded-from` enumerates REGULAR
# FILES ONLY (`find -type f`), deliberately matching rclone's own default of skipping symlinks so both sides
# of its byte-verification are the same set of things. A HARDLINKED staging dir is regular files, so it
# verifies exactly like a copied one did. A SYMLINKED one does not: the upload must follow links (`-L`, which
# gpu-job's `r2_copy` always injects, #295) and the local enumeration would then see none of what was
# uploaded. So on the symlink path, pass the SOURCE dirs to `--uploaded-from` (their relative paths under the
# staging root are the same by construction, one level down from each source's basename) rather than the
# staging dir. Put the staging dir on the same filesystem as the run's artifacts and none of this applies.
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
#   ARTIFACT-STAGE: ...           what was staged — file count, bytes NOT duplicated, and the link split.
#   ARTIFACT-STAGE-SYMLINKS: ...  at least one file could only be symlinked (see THE SYMLINK CAVEAT).
#
# EXIT CODES: 0 = staged · 1 = BLOCK (bad arguments, a collision, or a file that could not be linked —
# nothing is left half-staged in the sense that matters: the failure is loud and the tree is named).
set -uo pipefail

MANIFEST_NAME="MANIFEST.tsv"

say(){ echo "stage_artifacts: $*" >&2; }
die(){ echo "stage_artifacts: $*" >&2; exit 1; }

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
created_staging=0
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
  if ! find "$src_abs" -type f -printf '%s\t%P\0' > "$list"; then
    rm -f "$list"
    die "enumerating source '$src_abs' FAILED (find exit $?) — nothing further was staged: a partially enumerated source stages a tree that is missing files the close would then upload and call complete"
  fi
  while IFS=$'\t' read -r -d '' size rel; do
    [ -n "$rel" ] || { rm -f "$list"; die "enumerating '$src_abs' produced a record with an EMPTY relative path — refusing to stage a set this script cannot name"; }
    link_one "$src_abs/$rel" "$top/$rel" "$size"
  done < "$list"
  rm -f "$list"
  # A SYMLINK inside a source is not a regular file, so the enumeration above skipped it — and a skip nobody
  # states is how a close uploads less than it thinks it did (the scaffold manufactures these: executors
  # symlink `work/<exp>/scripts` at the run worktree, #811). They are RECORDED in the manifest and counted on
  # the stdout marker rather than staged: linking a link resolves to a target outside the staged set, and
  # dropping it silently is the one thing that must not happen.
  llist=$(mktemp) || die "mktemp failed — refusing to stage without a symlink scan of '$src_abs'"
  if ! find "$src_abs" -type l -printf '%P\0' > "$llist"; then
    rm -f "$llist"
    die "scanning '$src_abs' for symlinks FAILED (find exit $?) — a skipped symlink this script could not name is content the close would silently not upload"
  fi
  while IFS= read -r -d '' rel; do
    [ -n "$rel" ] || continue
    printf 'skipped-symlink\t%s\t%s\t0\n' "$top/$rel" "$src_abs/$rel" >> "$MANIFEST" \
      || { rm -f "$llist"; die "could not append the skipped symlink '$rel' to '$MANIFEST'"; }
    skipped=$((skipped + 1))
    say "SKIPPED SYMLINK (recorded in the manifest, NOT staged and NOT uploaded): '$src_abs/$rel' -> '$(readlink -- "$src_abs/$rel" 2>/dev/null)'"
  done < "$llist"
  rm -f "$llist"
done

if [ "$files" -eq 0 ]; then
  # The one refusal that can only be reached AFTER the tree exists (it is a fact about the traversal, not
  # about the arguments), so it takes its own residue back out: a manifest-only staging dir left behind here
  # would be uploaded by the next `rclone copy` as if it were this close's artifact set.
  rm -f "$MANIFEST"
  [ "$created_staging" = 1 ] && rmdir "$STAGING_REAL" 2>/dev/null
  die "nothing was staged: the source(s) hold no regular files. An empty staging tree uploads nothing, and close_record.sh would then have no local set to verify a listing against"
fi

printf 'ARTIFACT-STAGE: dir=%s files=%s bytes=%s hardlinked=%s symlinked=%s skipped_symlinks=%s copied=0 manifest=%s\n' \
  "$STAGING_REAL" "$files" "$bytes" "$hard" "$soft" "$skipped" "$MANIFEST"
if [ "$soft" -gt 0 ]; then
  printf 'ARTIFACT-STAGE-SYMLINKS: dir=%s symlinked=%s — the upload MUST follow symlinks (-L) and close_record.sh --uploaded-from must name the SOURCE dirs, not this staging dir (it enumerates regular files only)\n' \
    "$STAGING_REAL" "$soft"
  say "WARNING: $soft file(s) could only be SYMLINKED (the staging dir is on a different filesystem from the source). See THE SYMLINK CAVEAT in this script's header before running the upload or close_record.sh."
fi
say "staged $files file(s) ($bytes bytes) into '$STAGING_REAL' as $hard hardlink(s) + $soft symlink(s) — ZERO bytes duplicated ($skipped source symlink(s) recorded but not staged). Manifest: '$MANIFEST'."
