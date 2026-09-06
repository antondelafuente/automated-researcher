#!/usr/bin/env bash
# Smoke for stage_artifacts.sh — the close's upload-staging tree as LINKS PLUS A MANIFEST, never a second
# copy (automated-researcher#843). Behavior the deterministic JSON/syntax checks can't catch, and the
# properties the incident turns on:
#   - a staged file is the SAME INODE as the source (a hardlink IS the original: one inode, two names, zero
#     extra bytes) — the whole point, and the one thing a `cp -r` gets wrong
#   - the structure is mirrored under each source's basename, and `MANIFEST.tsv` names link-type, staged
#     path, source path and bytes for every entry — the tree says what it POINTS AT, not only what it holds
#   - NEVER A COPY: when a hardlink is impossible (the cross-filesystem case, stubbed here) it falls back to
#     a symlink and says so LOUDLY on stdout, because that changes what the upload and close_record.sh's
#     byte-verification must do; when neither link form works it FAILS rather than duplicating bytes
#   - a non-empty staging dir is refused (an earlier attempt's leg would be uploaded as this close's set)
#   - a basename collision between two sources is refused (the staged layout IS the artifact store's layout)
#   - a symlink inside a source is RECORDED in the manifest and counted on the marker rather than silently
#     dropped — the scaffold manufactures these (executors symlink `work/<exp>/scripts`, #811)
#   - a staging dir inside a source (and vice versa) is refused before the traversal stages its own output
#   - the ARTIFACT-STAGE-VERIFY-WITH line names the STAGING dir in BOTH cases, adding the follow flag only
#     for the symlink one — the close copies those flags rather than re-deriving them (#846 round 1, P0;
#     the end-to-end proof that they actually verify lives in close_record_smoke.sh section 9c)
#   - a failure PART WAY THROUGH the traversal leaves no staging tree: the partial one would be uploaded by
#     the next `rclone copy` as this close's artifact set (#846 round 1, P1)
# Fully offline: nothing but the local filesystem is touched.
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
S="$HERE/stage_artifacts.sh"
[ -f "$S" ] || { echo "FAIL: missing $S"; exit 1; }

TMP=$(mktemp -d) || { echo "FAIL: mktemp"; exit 1; }
trap 'rm -rf "$TMP"' EXIT
cd "$TMP" || { echo "FAIL: cd $TMP"; exit 1; }

fails=0
ok(){ echo "ok   $1"; }
no(){ echo "FAIL $1"; fails=1; }
inode(){ stat -c %i -- "$1" 2>/dev/null; }
links(){ stat -c %h -- "$1" 2>/dev/null; }

# --- the happy path: hardlinks, mirrored structure, a manifest ---------------------------------------
mkdir -p src/target_probes/sub
head -c 4096 /dev/zero > src/target_probes/adapter.tar
echo secondary > src/target_probes/sub/eval.jsonl
out=$(bash "$S" "$TMP/artifacts" "$TMP/src/target_probes" 2>/dev/null); rc=$?
[ "$rc" = 0 ] && ok stage-exit0 || no "stage-exit0 (rc=$rc)"
[ -f artifacts/target_probes/adapter.tar ] && ok stage-mirrored-under-basename || no stage-mirrored-under-basename
[ -f artifacts/target_probes/sub/eval.jsonl ] && ok stage-mirrored-subdirs || no stage-mirrored-subdirs
# THE property: same inode, link count 2 — the staged tree added zero bytes
[ "$(inode artifacts/target_probes/adapter.tar)" = "$(inode src/target_probes/adapter.tar)" ] \
  && ok stage-same-inode-as-source || no stage-same-inode-as-source
[ "$(links src/target_probes/adapter.tar)" = 2 ] && ok stage-is-a-hardlink || no "stage-is-a-hardlink (link count $(links src/target_probes/adapter.tar))"
case "$out" in
  *"ARTIFACT-STAGE: dir=$TMP/artifacts files=2 bytes=4106 hardlinked=2 symlinked=0 skipped_symlinks=0 copied=0 "*) ok stage-marker-on-stdout ;;
  *) no "stage-marker-on-stdout (stdout was: $out)" ;;
esac
grep -qP '^hardlink\ttarget_probes/adapter\.tar\t'"$TMP"'/src/target_probes/adapter\.tar\t4096$' artifacts/MANIFEST.tsv \
  && ok stage-manifest-row || no "stage-manifest-row ($(cat artifacts/MANIFEST.tsv))"
head -1 artifacts/MANIFEST.tsv | grep -qF 'link	staged_path	source_path	bytes' \
  && ok stage-manifest-header || no stage-manifest-header
# The verify flags are emitted for the ordinary case too, not only the exotic one: the close copies one line
# instead of working out which case it is in — the derivation an earlier revision got wrong (#846).
case "$out" in
  *"ARTIFACT-STAGE-VERIFY-WITH: --uploaded-from $TMP/artifacts"*) ok stage-verify-with-hardlink ;;
  *) no "stage-verify-with-hardlink (stdout was: $out)" ;;
esac
case "$out" in
  *"--uploaded-from-follows-symlinks"*) no "stage-verify-with-hardlink-no-follow-flag (stdout was: $out)" ;;
  *) ok stage-verify-with-hardlink-no-follow-flag ;;
esac

# re-staging into the same dir is refused: a stale leg would be uploaded as though this close staged it
bash "$S" "$TMP/artifacts" "$TMP/src/target_probes" >/dev/null 2>&1 \
  && no stage-refuses-non-empty || ok stage-refuses-non-empty

# --- a symlink inside a source is RECORDED, never silently dropped -----------------------------------
mkdir -p src2/probes
echo real > src2/probes/real.bin
ln -s "$TMP/src/target_probes" src2/probes/scripts
out=$(bash "$S" "$TMP/art2" "$TMP/src2/probes" 2>/dev/null)
case "$out" in
  *"skipped_symlinks=1 "*) ok stage-counts-skipped-symlink ;;
  *) no "stage-counts-skipped-symlink (stdout was: $out)" ;;
esac
grep -q '^skipped-symlink	probes/scripts	' art2/MANIFEST.tsv && ok stage-records-skipped-symlink || no "stage-records-skipped-symlink ($(cat art2/MANIFEST.tsv))"
[ -e art2/probes/scripts ] && no stage-did-not-stage-the-symlink || ok stage-did-not-stage-the-symlink

# --- a single regular file as a source ---------------------------------------------------------------
echo onefile > lone.jsonl
bash "$S" "$TMP/art3" "$TMP/lone.jsonl" >/dev/null 2>&1 && ok stage-file-source || no stage-file-source
[ "$(inode art3/lone.jsonl)" = "$(inode lone.jsonl)" ] && ok stage-file-source-hardlinked || no stage-file-source-hardlinked

# --- refusals ----------------------------------------------------------------------------------------
mkdir -p a/probes b/probes; echo x > a/probes/x; echo y > b/probes/y
bash "$S" "$TMP/art4" "$TMP/a/probes" "$TMP/b/probes" >/dev/null 2>&1 \
  && no stage-refuses-basename-collision || ok stage-refuses-basename-collision
bash "$S" "$TMP/src/target_probes/inside" "$TMP/src/target_probes" >/dev/null 2>&1 \
  && no stage-refuses-staging-inside-source || ok stage-refuses-staging-inside-source
mkdir -p art5; echo z > art5/z
bash "$S" "$TMP/art6" "$TMP/no/such/source" >/dev/null 2>&1 \
  && no stage-refuses-missing-source || ok stage-refuses-missing-source
mkdir -p emptysrc
bash "$S" "$TMP/art7" "$TMP/emptysrc" >/dev/null 2>&1 \
  && no stage-refuses-empty-source || ok stage-refuses-empty-source
# A REFUSAL LEAVES NOTHING BEHIND. A staging dir (or a manifest-only one) minted by a run that then refused
# is residue the next `rclone copy` would upload as this close's artifact set — the same disease one
# directory over. Every refusal above is checked before anything is created; the empty-source one is the
# single case reachable after, and it takes its own tree back out.
{ [ ! -e art6 ] && [ ! -e art7 ] && [ ! -e art8 ] && [ ! -e "$TMP/src/target_probes/inside" ]; } \
  && ok stage-refusals-leave-no-residue || no "stage-refusals-leave-no-residue ($(ls -d art6 art7 art8 "$TMP/src/target_probes/inside" 2>/dev/null))"
bash "$S" "$TMP/art8" >/dev/null 2>&1 && no stage-refuses-no-source || ok stage-refuses-no-source

# --- NEVER A COPY: the cross-filesystem fallback is a SYMLINK, and it is loud -------------------------
# A real second filesystem needs root, so `ln` is stubbed to fail exactly the way EXDEV makes it fail
# (hardlink refused, symlink fine). What must NOT happen on this path is a silent `cp`.
mkdir -p "$TMP/stub"
cat > "$TMP/stub/ln" <<'STUB'
#!/bin/bash
[ "${1:-}" = "-s" ] && exec /bin/ln "$@"
exit 1
STUB
chmod +x "$TMP/stub/ln"
out=$(PATH="$TMP/stub:$PATH" bash "$S" "$TMP/art9" "$TMP/src/target_probes" 2>/dev/null); rc=$?
[ "$rc" = 0 ] && ok stage-symlink-fallback-exit0 || no "stage-symlink-fallback-exit0 (rc=$rc)"
[ -L art9/target_probes/adapter.tar ] && ok stage-symlink-fallback-is-a-symlink || no stage-symlink-fallback-is-a-symlink
[ "$(links src/target_probes/adapter.tar)" = 2 ] && ok stage-symlink-fallback-added-no-hardlink || no stage-symlink-fallback-added-no-hardlink
case "$out" in
  *"ARTIFACT-STAGE-SYMLINKS: dir=$TMP/art9 symlinked=2"*) ok stage-symlink-fallback-marker ;;
  *) no "stage-symlink-fallback-marker (stdout was: $out)" ;;
esac
grep -q '^symlink	target_probes/adapter\.tar	' art9/MANIFEST.tsv && ok stage-symlink-fallback-manifest || no stage-symlink-fallback-manifest
# THE P0 (#846 round 1): --uploaded-from is the STAGING dir here too, plus the follow flag. Naming the SOURCE
# dirs instead — what this script's header used to say — strips each source's basename off every key and
# drops MANIFEST.tsv, so every object reads as missing AND surplus and the close can never verify.
case "$out" in
  *"ARTIFACT-STAGE-VERIFY-WITH: --uploaded-from $TMP/art9 --uploaded-from-follows-symlinks"*) ok stage-verify-with-symlink ;;
  *) no "stage-verify-with-symlink (stdout was: $out)" ;;
esac
case "$out" in
  *"VERIFY-WITH: --uploaded-from $TMP/src/target_probes"*) no "stage-verify-with-never-names-source-dirs (stdout was: $out)" ;;
  *) ok stage-verify-with-never-names-source-dirs ;;
esac

# ...and when NEITHER link form works, it fails rather than falling back to a copy
cat > "$TMP/stub/ln" <<'STUB'
#!/bin/bash
exit 1
STUB
chmod +x "$TMP/stub/ln"
PATH="$TMP/stub:$PATH" bash "$S" "$TMP/art10" "$TMP/src/target_probes" >/dev/null 2>&1 \
  && no stage-unlinkable-refused || ok stage-unlinkable-refused
[ -e art10/target_probes/adapter.tar ] && no stage-unlinkable-made-no-copy || ok stage-unlinkable-made-no-copy
# ...and it leaves NO TREE AT ALL, not merely no copied file (#846 round 1, P1). The failure is mid-traversal
# — the arguments were all fine — so it is reachable only after the dir and its manifest exist. A staging dir
# holding a manifest and a few links is not inert: the next `rclone copy` uploads it as this close's set.
[ -e art10 ] && no "stage-midstage-failure-leaves-no-tree ($(find art10 2>/dev/null | tr '\n' ' '))" || ok stage-midstage-failure-leaves-no-tree

# The same failure with SOME files already linked — the genuinely partial tree, not the fail-on-first case.
# `ln` refuses only the second file, so the first is really staged before the run dies.
cat > "$TMP/stub/ln" <<'STUB'
#!/bin/bash
for a in "$@"; do case "$a" in *eval.jsonl) exit 1 ;; esac; done
exec /bin/ln "$@"
STUB
chmod +x "$TMP/stub/ln"
mkdir -p partial/probes; echo one > partial/probes/adapter.tar; echo two > partial/probes/eval.jsonl
PATH="$TMP/stub:$PATH" bash "$S" "$TMP/art11" "$TMP/partial/probes" >/dev/null 2>&1 \
  && no stage-partial-refused || ok stage-partial-refused
[ -e art11 ] && no "stage-partial-leaves-no-residue ($(find art11 2>/dev/null | tr '\n' ' '))" || ok stage-partial-leaves-no-residue
# ...and the cleanup removed LINKS, never the originals' bytes: both sources are intact and unshared.
{ [ -f partial/probes/adapter.tar ] && [ "$(links partial/probes/adapter.tar)" = 1 ]; } \
  && ok stage-cleanup-left-sources-intact || no "stage-cleanup-left-sources-intact (link count $(links partial/probes/adapter.tar))"

# A staging dir the CALLER pre-created (empty) is handed back the way they left it, not removed with the
# residue — the cleanup is bounded to what this run made.
mkdir -p art12
PATH="$TMP/stub:$PATH" bash "$S" "$TMP/art12" "$TMP/partial/probes" >/dev/null 2>&1
{ [ -d art12 ] && [ -z "$(find art12 -mindepth 1 -print -quit 2>/dev/null)" ]; } \
  && ok stage-cleanup-keeps-callers-own-dir || no "stage-cleanup-keeps-callers-own-dir (dir=$([ -d art12 ] && echo yes || echo removed), contents=$(find art12 2>/dev/null | tr '\n' ' '))"

[ "$fails" = 0 ] && { echo "stage_artifacts smoke PASS"; exit 0; } || { echo "stage_artifacts smoke FAIL"; exit 1; }
