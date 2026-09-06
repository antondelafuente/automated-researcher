#!/usr/bin/env bash
# Smoke for sparse_worktree.sh's `--existing` mode — the IN-PLACE sparsifier (automated-researcher#807), the
# product-side intercept for the two worktree creation paths #805 could not reach (harness-spawned
# `.claude/worktrees/*` and an instance's own launchers: measured 2026-09-06 as 16 of 36 live worktrees and
# 37G of 48G). Sibling of sparse_worktree_smoke.sh, which covers the CREATION mode; this one covers only what
# `--existing` adds, and specifically the behavior the ~77%-of-worktree-disk claim and its safety contract
# rest on:
#   - a non-sparse linked worktree really loses the unnamed `registry/` records and keeps everything else
#     (the disk win), and the reclaimed byte count it PRINTS is real and non-zero;
#   - it is IDEMPOTENT: a second run reclaims 0 bytes, keeps the same set, and exits 0;
#   - it PRESERVES the tree's own existing `registry/` cone entries — the footgun that matters most, since
#     the SKILL guidance tells a session to run this as its first act in a tree someone else created: an
#     already-sparse instance-created tree made for `registry/<exp>` must not lose that record to a caller
#     who did not know to re-name it (and a re-run must not undo the first run);
#   - it REFUSES the main working tree (the box's one full copy of the registry, which #805's own verified
#     property keeps non-sparse);
#   - it REFUSES when modified, untracked, or IGNORED state sits inside a record the cone would drop, and
#     proceeds when that same state sits inside a record the caller NAMED. Ignored state is included on
#     purpose and the smoke proves why: git deletes an ignored-only record dir outright, and the registry's
#     ignored artifacts are the one class a `git checkout` cannot bring back;
#   - it is a NO-OP on a tree that is not a checkout of the research repo (a blind first act pointed at the
#     wrong tree must not sparse-checkout an unrelated repo);
#   - the narrow-default safety property survives in-place sparsification: `git add` outside the cone still
#     FAILS rather than silently staging a short commit;
#   - fail-closed refusals (flag combinations that cannot mean anything, a missing path, a non-worktree).
# Uses real throwaway git repos under TMP — no network, no real experiment state touched.
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
S="$HERE/sparse_worktree.sh"
[ -f "$S" ] || { echo "FAIL: missing $S"; exit 1; }

TMP=$(mktemp -d) || { echo "FAIL: mktemp"; exit 1; }
trap 'rm -rf "$TMP"' EXIT

fails=0
ok(){ echo "ok   $1"; }
no(){ echo "FAIL $1"; fails=1; }
has(){ [ -e "$2" ] && ok "$1" || no "$1 (missing: $2)"; }
hasnt(){ [ -e "$2" ] && no "$1 (present: $2)" || ok "$1"; }

# A research-repo-shaped fixture whose UNNAMED records carry real bulk, so the reclaimed byte count the
# script prints can be asserted as non-zero rather than filesystem-block noise. ~1M per heavy record — the
# shape of the real registry (a few big jsonl per experiment), small enough to stay a fast fixture.
REPO="$TMP/repo"
git init -q -b main "$REPO"
mkdir -p "$REPO/registry/exp-a/figures" "$REPO/registry/exp-b" "$REPO/registry/exp-c" "$REPO/plugins" "$REPO/tooling"
printf 'top\n'   > "$REPO/README.md"
printf '*.big\n' > "$REPO/.gitignore"
printf '*.huge\n' > "$REPO/registry/.gitignore"
printf 'a\n'     > "$REPO/registry/exp-a/DESIGN.md"
printf 'fig\n'   > "$REPO/registry/exp-a/figures/f.svg"
printf 'b\n'     > "$REPO/registry/exp-b/DESIGN.md"
printf 'c\n'     > "$REPO/registry/exp-c/DESIGN.md"
printf 'p\n'     > "$REPO/plugins/x.md"
printf 't\n'     > "$REPO/tooling/y.md"
for h in exp-b exp-c; do
  for i in 1 2 3 4; do head -c 262144 /dev/zero | tr '\0' 'x' > "$REPO/registry/$h/rollouts-$i.jsonl"; done
done
git -C "$REPO" add -A
git -C "$REPO" -c user.email=t@t -c user.name=t commit -qm init

# A FULL linked worktree, created the way the harness / an instance convention does it: a plain
# `git worktree add` that never passes through this helper.
full_wt(){ git -C "$REPO" worktree add -q -b "$2" "$1" main; }

# --- the disk win: a full tree sparsified in place, with a real reclaimed byte count -----------------------
WT1="$TMP/wt-inplace"
full_wt "$WT1" w1
has    inplace-precondition-full-b "$WT1/registry/exp-b/DESIGN.md"
OUT1="$TMP/out1"
if bash "$S" --existing "$WT1" registry/exp-a 2>"$OUT1" >/dev/null; then ok inplace-exit0; else no "inplace-exit0 ($(cat "$OUT1"))"; fi
has    inplace-keeps-other-top-level-dirs "$WT1/plugins/x.md"
has    inplace-keeps-second-top-level-dir "$WT1/tooling/y.md"
has    inplace-keeps-root-gitignore       "$WT1/.gitignore"
has    inplace-keeps-registry-gitignore   "$WT1/registry/.gitignore"
has    inplace-keeps-named-record         "$WT1/registry/exp-a/DESIGN.md"
has    inplace-keeps-named-record-subdir  "$WT1/registry/exp-a/figures/f.svg"
hasnt  inplace-drops-unnamed-record-b     "$WT1/registry/exp-b"
hasnt  inplace-drops-unnamed-record-c     "$WT1/registry/exp-c"
# the reclaimed figure is PRINTED and is a real, non-zero byte count (the fixture dropped ~2M of jsonl)
BYTES1=$(sed -n 's/.*reclaimed \([0-9][0-9]*\) bytes.*/\1/p' "$OUT1" | head -1)
if [ -n "$BYTES1" ] && [ "$BYTES1" -gt 1000000 ]; then
  ok "inplace-prints-reclaimed-bytes ($BYTES1)"
else
  no "inplace-prints-reclaimed-bytes (got '${BYTES1:-<none>}' from: $(cat "$OUT1"))"
fi
# the narrow default is still safe in place: `git add` outside the cone FAILS, never a short commit
mkdir -p "$WT1/registry/exp-b" && printf 'x\n' > "$WT1/registry/exp-b/D.md"
git -C "$WT1" add -- registry/exp-b >/dev/null 2>&1 && no inplace-add-outside-cone-refused || ok inplace-add-outside-cone-refused
rm -rf "$WT1/registry/exp-b"

# --- idempotent: a second run reclaims 0 and changes nothing ----------------------------------------------
OUT2="$TMP/out2"
if bash "$S" --existing "$WT1" registry/exp-a 2>"$OUT2" >/dev/null; then ok rerun-exit0; else no "rerun-exit0 ($(cat "$OUT2"))"; fi
BYTES2=$(sed -n 's/.*reclaimed \([0-9][0-9]*\) bytes.*/\1/p' "$OUT2" | head -1)
[ "${BYTES2:-x}" = 0 ] && ok rerun-reclaims-nothing || no "rerun-reclaims-nothing (got '${BYTES2:-<none>}')"
has   rerun-keeps-named-record "$WT1/registry/exp-a/DESIGN.md"
hasnt rerun-still-drops-b      "$WT1/registry/exp-b"

# --- PRESERVES the tree's own cone: an already-sparse tree does not lose the record it was created for -----
#     (the first-act guidance means this runs on trees the caller did not create and may not know about)
WT2="$TMP/wt-already-sparse"
bash "$S" --repo "$REPO" -b w2 "$WT2" main registry/exp-c >/dev/null 2>&1
has  presarse-precondition-c "$WT2/registry/exp-c/DESIGN.md"
if bash "$S" --existing "$WT2" >/dev/null 2>&1; then ok preserve-exit0; else no preserve-exit0; fi
has  preserve-keeps-existing-cone-record "$WT2/registry/exp-c/DESIGN.md"
hasnt preserve-still-drops-unnamed-b     "$WT2/registry/exp-b"
# ...and a caller naming a DIFFERENT record gets the union, not a swap
if bash "$S" --existing "$WT2" registry/exp-a >/dev/null 2>&1; then ok union-exit0; else no union-exit0; fi
has  union-keeps-pre-existing-c "$WT2/registry/exp-c/DESIGN.md"
has  union-adds-named-a         "$WT2/registry/exp-a/DESIGN.md"

# --- a cone that already names the whole registry/ is left alone (nothing to reclaim; narrowing a
#     deliberately-full cone is not this mode's job) ----------------------------------------------------
WT3="$TMP/wt-cone-all"
full_wt "$WT3" w3
git -C "$WT3" sparse-checkout set --cone -- plugins tooling registry >/dev/null 2>&1
OUT3="$TMP/out3"
if bash "$S" --existing "$WT3" 2>"$OUT3" >/dev/null; then ok cone-all-exit0; else no cone-all-exit0; fi
grep -q "already names the whole registry" "$OUT3" && ok cone-all-says-so || no "cone-all-says-so ($(cat "$OUT3"))"
has cone-all-untouched-b "$WT3/registry/exp-b/DESIGN.md"

# --- REFUSES the main working tree -----------------------------------------------------------------------
bash "$S" --existing "$REPO" >/dev/null 2>&1 && no refuse-main-worktree || ok refuse-main-worktree
has  main-still-full-b "$REPO/registry/exp-b/DESIGN.md"
has  main-still-full-c "$REPO/registry/exp-c/DESIGN.md"
git -C "$REPO" sparse-checkout list >/dev/null 2>&1 && no main-not-sparse || ok main-not-sparse

# --- REFUSES uncommitted / untracked work inside a record the cone would DROP ------------------------------
WT4="$TMP/wt-dirty-modified"
full_wt "$WT4" w4
printf 'edited\n' > "$WT4/registry/exp-b/DESIGN.md"
bash "$S" --existing "$WT4" registry/exp-a >/dev/null 2>&1 && no refuse-modified-in-dropped || ok refuse-modified-in-dropped
has refuse-modified-left-tree-alone "$WT4/registry/exp-b/DESIGN.md"
[ "$(cat "$WT4/registry/exp-b/DESIGN.md")" = "edited" ] && ok refuse-modified-kept-edit || no refuse-modified-kept-edit

WT5="$TMP/wt-dirty-untracked"
full_wt "$WT5" w5
printf 'scratch\n' > "$WT5/registry/exp-c/NOTES.md"
bash "$S" --existing "$WT5" registry/exp-a >/dev/null 2>&1 && no refuse-untracked-in-dropped || ok refuse-untracked-in-dropped
has refuse-untracked-left-file "$WT5/registry/exp-c/NOTES.md"
has refuse-untracked-left-tree "$WT5/registry/exp-b/DESIGN.md"
# ...and naming that record makes it proceed (the refusal message's own remedy actually works)
if bash "$S" --existing "$WT5" registry/exp-c >/dev/null 2>&1; then ok named-dirty-record-proceeds; else no named-dirty-record-proceeds; fi
has   named-dirty-record-kept  "$WT5/registry/exp-c/NOTES.md"
hasnt named-dirty-other-dropped "$WT5/registry/exp-b"

# --- IGNORED artifacts inside a dropped record are a REFUSAL, because git DELETES an ignored-only record
#     dir outright (verified below). Those artifacts are the registry's own big files — they live on disk and
#     in the artifact store, not in git, so unlike a dropped TRACKED file they are not recoverable. -------
WT6="$TMP/wt-ignored"
full_wt "$WT6" w6
printf 'zz\n' > "$WT6/registry/exp-b/artifact.big"    # matched by the root .gitignore
printf 'zz\n' > "$WT6/registry/exp-c/artifact.huge"   # matched by registry/.gitignore
bash "$S" --existing "$WT6" registry/exp-a >/dev/null 2>&1 && no refuse-ignored-in-dropped || ok refuse-ignored-in-dropped
has ignored-artifact-preserved     "$WT6/registry/exp-b/artifact.big"
has ignored-artifact-preserved-2   "$WT6/registry/exp-c/artifact.huge"
has ignored-record-left-untouched  "$WT6/registry/exp-b/DESIGN.md"
# The loss that refusal prevents is real, not theoretical: applying the very same cone by hand deletes it.
# If a future git stops doing this, THIS assertion is what fails — and the refusal can then be relaxed.
git -C "$WT6" sparse-checkout set --cone -- plugins tooling registry/exp-a >/dev/null 2>&1
hasnt ignored-artifact-really-would-be-deleted "$WT6/registry/exp-b/artifact.big"

# ...and naming the record that holds the artifact is the remedy the refusal points at
WT6B="$TMP/wt-ignored-named"
full_wt "$WT6B" w6b
printf 'zz\n' > "$WT6B/registry/exp-b/artifact.big"
if bash "$S" --existing "$WT6B" registry/exp-b >/dev/null 2>&1; then ok named-ignored-record-proceeds; else no named-ignored-record-proceeds; fi
has   named-ignored-artifact-kept "$WT6B/registry/exp-b/artifact.big"
has   named-ignored-record-kept   "$WT6B/registry/exp-b/DESIGN.md"
hasnt named-ignored-other-dropped "$WT6B/registry/exp-c"

# --- a subdirectory argument addresses the whole worktree (sparse-checkout is per-worktree) ---------------
WT7="$TMP/wt-subdir-arg"
full_wt "$WT7" w7
if bash "$S" --existing "$WT7/plugins" registry/exp-a >/dev/null 2>&1; then ok subdir-arg-exit0; else no subdir-arg-exit0; fi
has   subdir-arg-keeps-named "$WT7/registry/exp-a/DESIGN.md"
hasnt subdir-arg-drops-b     "$WT7/registry/exp-b"

# --- `--existing .` from inside the tree: the literal invocation both SKILL checklists tell a session to run
WT8="$TMP/wt-dot"
full_wt "$WT8" w8
if ( cd "$WT8" && bash "$S" --existing . registry/exp-a >/dev/null 2>&1 ); then ok dot-arg-exit0; else no dot-arg-exit0; fi
has   dot-arg-keeps-named "$WT8/registry/exp-a/DESIGN.md"
hasnt dot-arg-drops-b     "$WT8/registry/exp-b"

# --- NO-OP on a tree that is not a checkout of the research repo -------------------------------------------
OTHER="$TMP/other-repo"
git init -q -b main "$OTHER"
mkdir -p "$OTHER/src"
printf 's\n' > "$OTHER/src/a.md"
git -C "$OTHER" add -A
git -C "$OTHER" -c user.email=t@t -c user.name=t commit -qm init
OWT="$TMP/other-wt"
git -C "$OTHER" worktree add -q -b ow "$OWT" main
OUT8="$TMP/out8"
if bash "$S" --existing "$OWT" 2>"$OUT8" >/dev/null; then ok other-repo-exit0; else no other-repo-exit0; fi
grep -q "not a checkout of the research repo" "$OUT8" && ok other-repo-says-so || no "other-repo-says-so ($(cat "$OUT8"))"
has other-repo-untouched "$OWT/src/a.md"

# --- fail-closed refusals ---------------------------------------------------------------------------------
bash "$S" --existing "$TMP/nope" >/dev/null 2>&1            && no refuse-missing-path      || ok refuse-missing-path
bash "$S" --existing "$TMP" >/dev/null 2>&1                 && no refuse-non-worktree      || ok refuse-non-worktree
bash "$S" --existing >/dev/null 2>&1                        && no refuse-existing-no-value || ok refuse-existing-no-value
bash "$S" --existing "$WT1" --full >/dev/null 2>&1          && no refuse-existing-with-full || ok refuse-existing-with-full
bash "$S" --existing "$WT1" -b nb >/dev/null 2>&1           && no refuse-existing-with-b    || ok refuse-existing-with-b
bash "$S" --existing "$WT1" --repo "$REPO" >/dev/null 2>&1  && no refuse-existing-with-repo || ok refuse-existing-with-repo

if [ "$fails" = 0 ]; then echo "[smoke] sparse_worktree --existing: ALL PASS"; else echo "[smoke] sparse_worktree --existing: FAILURES"; fi
exit "$fails"
