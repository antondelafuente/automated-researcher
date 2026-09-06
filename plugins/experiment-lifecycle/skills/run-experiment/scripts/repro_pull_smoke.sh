#!/usr/bin/env bash
# Smoke for repro_pull.sh — the fresh-pull reproduction directory's lifecycle (automated-researcher#843).
# Behavior the deterministic JSON/syntax checks can't catch, and the properties the incident turns on:
#   - `create` mints exactly "<EXPERIMENT_SCRATCH_ROOT>/<run-id>/fresh_reproduction", prints THAT PATH AND
#     NOTHING ELSE on stdout (callers capture it with `$( )`), and records the pre-pull footprint
#   - `create` REFUSES an existing tree rather than reusing or emptying it (a live pull or a crashed close's
#     residue is a human's call, and reuse would silently make the pre-pull measurement a lie)
#   - THE DELETE TARGET IS DERIVED, NOT SUPPLIED: a sibling directory, a same-named `fresh_reproduction`
#     under a DIFFERENT root, and the run's own scratch dir are all refused with nothing deleted — the
#     bound reap_scratch.sh gate 2 states, one directory down
#   - a symlink at the target path is refused (deleting it would leave the tree it points at while claiming
#     the space came back), and so is a reap run from inside the tree
#   - NEVER DELETE THROUGH A MOUNT POINT: a target that IS or CONTAINS a mount is refused, an ANCESTOR mount
#     blocks nothing, and an unreadable mount table is the loud gap (exit 3), never a delete
#   - the unset seam is a LOUD no-op (a `REPRO-PULL-GAP:` line on stdout + exit 3), never a guessed path
#   - the FOOTPRINT RECORD reap_scratch.sh reads: before_bytes at create, peak_bytes + pull_bytes at reap,
#     and the peak is the whole scratch WITH the pull still in it (the close's high-water mark)
#   - reaping a directory that is already gone is a no-op success (idempotent, like audit_checkout.sh reap)
# No network, no rclone: this helper touches nothing but the local filesystem.
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
P="$HERE/repro_pull.sh"
[ -f "$P" ] || { echo "FAIL: missing $P"; exit 1; }

TMP=$(mktemp -d) || { echo "FAIL: mktemp"; exit 1; }
trap 'rm -rf "$TMP"' EXIT
ROOT="$TMP/work"; mkdir -p "$ROOT"
export EXPERIMENT_SCRATCH_ROOT="$ROOT"
cd "$TMP" || { echo "FAIL: cd $TMP"; exit 1; }

fails=0
ok(){ echo "ok   $1"; }
no(){ echo "FAIL $1"; fails=1; }

mkscratch(){ local d="$ROOT/$1"; mkdir -p "$d"; echo "payload-$1" > "$d/out.txt"; echo "$d"; }
mkmountinfo(){
  local f=$1; shift
  echo "27 2 8:1 / / rw - ext4 /dev/root rw" > "$f"
  local n=28
  for mp in "$@"; do echo "$n 27 0:$n / $mp rw - tmpfs tmpfs rw" >> "$f"; n=$((n+1)); done
}

# --- create: the one derived path, stdout is the path and nothing else -------------------------------
s=$(mkscratch c1)
out=$(bash "$P" create c1 2>/dev/null); rc=$?
[ "$rc" = 0 ] && ok create-exit0 || no "create-exit0 (rc=$rc)"
[ "$out" = "$s/fresh_reproduction" ] && ok create-stdout-is-the-path-only || no "create-stdout-is-the-path-only (stdout was: $out)"
[ -d "$s/fresh_reproduction" ] && ok create-made-the-dir || no create-made-the-dir
grep -qE '^before_bytes=[0-9]+$' "$s/.close_footprint" 2>/dev/null \
  && ok create-records-pre-pull-footprint || no "create-records-pre-pull-footprint ($(cat "$s/.close_footprint" 2>/dev/null))"

# an existing tree is refused, never reused or emptied
echo pulled > "$s/fresh_reproduction/adapter.tar"
out=$(bash "$P" create c1 2>&1); rc=$?
[ "$rc" = 1 ] && ok create-refuses-existing || no "create-refuses-existing (rc=$rc)"
[ -f "$s/fresh_reproduction/adapter.tar" ] && ok create-refusal-kept-content || no create-refusal-kept-content

# --- reap: measures the peak, then deletes -----------------------------------------------------------
before_only=$(grep -c . "$s/.close_footprint")
out=$(bash "$P" reap c1 "$s/fresh_reproduction" 2>/dev/null); rc=$?
[ "$rc" = 0 ] && ok reap-exit0 || no "reap-exit0 (rc=$rc)"
[ -e "$s/fresh_reproduction" ] && no reap-deleted-the-dir || ok reap-deleted-the-dir
[ -f "$s/out.txt" ] && ok reap-left-the-rest-of-scratch || no reap-left-the-rest-of-scratch
case "$out" in
  "REPRO-PULL-REAPED: run=c1 pull_bytes="[0-9]*" peak_bytes="[0-9]*" path=$s/fresh_reproduction") ok reap-marker-on-stdout ;;
  *) no "reap-marker-on-stdout (stdout was: $out)" ;;
esac
peak=$(sed -n 's/^peak_bytes=\([0-9]*\)$/\1/p' "$s/.close_footprint")
pull=$(sed -n 's/^pull_bytes=\([0-9]*\)$/\1/p' "$s/.close_footprint")
bef=$(sed -n 's/^before_bytes=\([0-9]*\)$/\1/p' "$s/.close_footprint")
{ [ -n "$peak" ] && [ -n "$pull" ] && [ -n "$bef" ]; } && ok reap-records-all-three || no "reap-records-all-three (peak='$peak' pull='$pull' before='$bef')"
# the peak is the whole scratch WITH the pull still in it, so it strictly exceeds both halves' own measure
{ [ "$peak" -gt "$bef" ] && [ "$peak" -gt 0 ] && [ "$pull" -gt 0 ]; } \
  && ok reap-peak-is-the-high-water-mark || no "reap-peak-is-the-high-water-mark (peak=$peak before=$bef pull=$pull)"
[ "$before_only" -ge 1 ] && ok create-record-preceded-reap || no create-record-preceded-reap

# reaping what is already gone is a no-op success (a close that reaped by hand must not fail here)
bash "$P" reap c1 "$s/fresh_reproduction" >/dev/null 2>&1 \
  && ok reap-idempotent || no reap-idempotent

# --- THE DELETE TARGET IS DERIVED, NOT SUPPLIED ------------------------------------------------------
s2=$(mkscratch d1); mkdir -p "$s2/fresh_reproduction" "$s2/other" "$s2/fresh_reproduction_v2"
echo keep > "$s2/other/keep.txt"; echo keep > "$s2/fresh_reproduction_v2/keep.txt"
for bad in "$s2/other" "$s2/fresh_reproduction_v2" "$s2" "$ROOT"; do
  bash "$P" reap d1 "$bad" >/dev/null 2>&1 && no "reap-refuses-$bad" || ok "reap-refuses-off-target ($(basename "$bad"))"
done
{ [ -f "$s2/other/keep.txt" ] && [ -f "$s2/fresh_reproduction_v2/keep.txt" ] && [ -d "$s2" ]; } \
  && ok reap-refusals-deleted-nothing || no reap-refusals-deleted-nothing
# ...including a same-named dir under a DIFFERENT root, which a basename-only binding would have accepted
OTHERROOT="$TMP/other-work"; mkdir -p "$OTHERROOT/d1/fresh_reproduction"; echo peer > "$OTHERROOT/d1/fresh_reproduction/peer.txt"
bash "$P" reap d1 "$OTHERROOT/d1/fresh_reproduction" >/dev/null 2>&1 \
  && no reap-refuses-other-root || ok reap-refuses-other-root
[ -f "$OTHERROOT/d1/fresh_reproduction/peer.txt" ] && ok reap-other-root-untouched || no reap-other-root-untouched
# a run-id that is not a single path segment never becomes one
bash "$P" create ../escape >/dev/null 2>&1 && no create-refuses-traversal-runid || ok create-refuses-traversal-runid

# --- a SYMLINK at the target path is refused ---------------------------------------------------------
s3=$(mkscratch l1); mkdir -p "$TMP/elsewhere"; echo data > "$TMP/elsewhere/keep.txt"
ln -s "$TMP/elsewhere" "$s3/fresh_reproduction"
bash "$P" reap l1 "$s3/fresh_reproduction" >/dev/null 2>&1 && no reap-refuses-symlink || ok reap-refuses-symlink
{ [ -f "$TMP/elsewhere/keep.txt" ] && [ -L "$s3/fresh_reproduction" ]; } \
  && ok reap-symlink-target-untouched || no reap-symlink-target-untouched
rm -f "$s3/fresh_reproduction"

# the calling shell standing inside the tree
s4=$(mkscratch w1); mkdir -p "$s4/fresh_reproduction/deep"
( cd "$s4/fresh_reproduction/deep" && bash "$P" reap w1 "$s4/fresh_reproduction" >/dev/null 2>&1 ) \
  && no reap-refuses-cwd-inside || ok reap-refuses-cwd-inside
[ -d "$s4/fresh_reproduction" ] && ok reap-cwd-inside-kept || no reap-cwd-inside-kept

# --- never delete through a mount point --------------------------------------------------------------
# `rm -rf` unlinks a bind mount's contents THROUGH the mount and only then fails with EBUSY, so the
# non-zero exit arrives after the mounted data is gone. Same injectable table as reap_scratch.sh's gate 3c.
s5=$(mkscratch m1); mkdir -p "$s5/fresh_reproduction/dataset"
mkmountinfo "$TMP/mi-at" "$s5/fresh_reproduction"
REPRO_PULL_MOUNTINFO="$TMP/mi-at" bash "$P" reap m1 "$s5/fresh_reproduction" >/dev/null 2>&1 \
  && no reap-refuses-mount-at-target || ok reap-refuses-mount-at-target
mkmountinfo "$TMP/mi-under" "$s5/fresh_reproduction/dataset"
REPRO_PULL_MOUNTINFO="$TMP/mi-under" bash "$P" reap m1 "$s5/fresh_reproduction" >/dev/null 2>&1 \
  && no reap-refuses-mount-under-target || ok reap-refuses-mount-under-target
[ -d "$s5/fresh_reproduction/dataset" ] && ok reap-mount-refusals-deleted-nothing || no reap-mount-refusals-deleted-nothing
mkmountinfo "$TMP/mi-anc" "$ROOT"
REPRO_PULL_MOUNTINFO="$TMP/mi-anc" bash "$P" reap m1 "$s5/fresh_reproduction" >/dev/null 2>&1 \
  && ok reap-ancestor-mount-allowed || no reap-ancestor-mount-allowed
[ -e "$s5/fresh_reproduction" ] && no reap-ancestor-mount-deleted || ok reap-ancestor-mount-deleted
# an unreadable table is UNKNOWN, and UNKNOWN never reaches a delete — the loud gap, not a silent exit 0
s6=$(mkscratch m2); mkdir -p "$s6/fresh_reproduction"
out=$(REPRO_PULL_MOUNTINFO="$TMP/no-such-table" bash "$P" reap m2 "$s6/fresh_reproduction" 2>/dev/null); rc=$?
[ "$rc" = 3 ] && ok reap-unreadable-table-exit3 || no "reap-unreadable-table-exit3 (rc=$rc)"
case "$out" in
  *"REPRO-PULL-GAP: run=m2 cause=mountinfo-unreadable"*) ok reap-unreadable-table-marker ;;
  *) no "reap-unreadable-table-marker (stdout was: $out)" ;;
esac
[ -d "$s6/fresh_reproduction" ] && ok reap-unreadable-table-kept || no reap-unreadable-table-kept

# --- the unset seam is a LOUD no-op, never a guessed path --------------------------------------------
s7=$(mkscratch g1)
out=$(env -u EXPERIMENT_SCRATCH_ROOT bash "$P" create g1 2>/dev/null); rc=$?
[ "$rc" = 3 ] && ok create-unset-seam-exit3 || no "create-unset-seam-exit3 (rc=$rc)"
case "$out" in
  *"REPRO-PULL-GAP: run=g1 cause=EXPERIMENT_SCRATCH_ROOT-unset"*) ok create-unset-seam-marker ;;
  *) no "create-unset-seam-marker (stdout was: $out)" ;;
esac
[ -e "$s7/fresh_reproduction" ] && no create-unset-seam-created-nothing || ok create-unset-seam-created-nothing
out=$(env -u EXPERIMENT_SCRATCH_ROOT bash "$P" reap g1 "$s7/fresh_reproduction" 2>/dev/null); rc=$?
[ "$rc" = 3 ] && ok reap-unset-seam-exit3 || no "reap-unset-seam-exit3 (rc=$rc)"

# a run whose scratch dir does not exist has nowhere to put the pull — refused, not created elsewhere
bash "$P" create no-such-run >/dev/null 2>&1 && no create-refuses-missing-scratch || ok create-refuses-missing-scratch
[ -e "$ROOT/no-such-run" ] && no create-missing-scratch-made-nothing || ok create-missing-scratch-made-nothing

# --- argument validation -----------------------------------------------------------------------------
bash "$P" >/dev/null 2>&1                       && no args-no-verb-refused      || ok args-no-verb-refused
bash "$P" bogus x >/dev/null 2>&1               && no args-unknown-verb-refused || ok args-unknown-verb-refused
bash "$P" reap c1 >/dev/null 2>&1               && no args-reap-needs-path      || ok args-reap-needs-path
bash "$P" create >/dev/null 2>&1                && no args-create-needs-runid   || ok args-create-needs-runid

[ "$fails" = 0 ] && { echo "repro_pull smoke PASS"; exit 0; } || { echo "repro_pull smoke FAIL"; exit 1; }
