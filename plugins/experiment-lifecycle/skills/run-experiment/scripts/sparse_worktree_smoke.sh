#!/usr/bin/env bash
# Smoke for sparse_worktree.sh — the creation-side worktree helper (automated-researcher#805). Behavior the
# deterministic JSON/syntax checks can't catch, and that the ~90%-of-daily-disk-growth claim rests on:
#   - the DEFAULT set really excludes `registry/` while keeping every other top-level dir (the disk win), and
#     really includes the named `registry/<exp>` record(s) (the task's own data);
#   - cone mode still materializes the ANCESTOR dirs' own files — specifically the repo root's `.gitignore`
#     and `registry/.gitignore`, which log-experiment's #340 ignored-file guard and #666 staging copy both
#     decide against; a sparse tree missing a rule file would silently change a landing verdict;
#   - a named record dir that does NOT exist at the base commit is accepted (the new-experiment case that
#     log-experiment hits on every first landing);
#   - `git add` on a path outside the cone FAILS rather than silently staging a short commit — the property
#     that makes a narrow default safe;
#   - `--full` still produces a whole-registry checkout (the explicit rare escape hatch);
#   - `-b` creates and checks out the new branch; without `-b` a named branch is checked out (not detached);
#   - fail-closed refusals (existing path, non-commit, non-repo, unknown flag) and no half-created worktree
#     left behind on a post-`worktree add` failure.
# Uses real throwaway git repos under TMP — no network, no real experiment state touched.
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
S="$HERE/sparse_worktree.sh"
[ -f "$S" ] || { echo "FAIL: missing $S"; exit 1; }
# The log-experiment copy (log-experiment.sh calls its own co-located one, same per-skill-copy precedent as
# aar_profile_snapshot.sh) must not drift from this canonical one. Skipped when that skill dir isn't present
# (a single-skill symlink install of run-experiment alone).
LE_COPY="$HERE/../../log-experiment/scripts/sparse_worktree.sh"

TMP=$(mktemp -d) || { echo "FAIL: mktemp"; exit 1; }
trap 'rm -rf "$TMP"' EXIT

fails=0
ok(){ echo "ok   $1"; }
no(){ echo "FAIL $1"; fails=1; }
has(){ [ -e "$2" ] && ok "$1" || no "$1 (missing: $2)"; }
hasnt(){ [ -e "$2" ] && no "$1 (present: $2)" || ok "$1"; }

# A research-repo-shaped fixture: a heavy `registry/` of several records next to the ordinary top-level dirs,
# with .gitignore rule files at the root AND inside registry/ (the two log-experiment reads back).
REPO="$TMP/repo"
git init -q -b main "$REPO"
mkdir -p "$REPO/registry/exp-a/figures" "$REPO/registry/exp-b" "$REPO/registry/exp-c" "$REPO/plugins" "$REPO/tooling"
printf 'top\n'        > "$REPO/README.md"
printf '*.big\n'      > "$REPO/.gitignore"
printf '*.huge\n'     > "$REPO/registry/.gitignore"
printf 'a\n'          > "$REPO/registry/exp-a/DESIGN.md"
printf 'fig\n'        > "$REPO/registry/exp-a/figures/f.svg"
printf 'b\n'          > "$REPO/registry/exp-b/DESIGN.md"
printf 'c\n'          > "$REPO/registry/exp-c/DESIGN.md"
printf 'p\n'          > "$REPO/plugins/x.md"
printf 't\n'          > "$REPO/tooling/y.md"
git -C "$REPO" add -A
git -C "$REPO" -c user.email=t@t -c user.name=t commit -qm init

sw(){ bash "$S" --repo "$REPO" "$@"; }

# --- default: one named record in, the rest of registry/ out, every other top-level dir in ---
WT1="$TMP/wt-default"
if sw -b w1 "$WT1" main registry/exp-a >/dev/null 2>&1; then ok default-exit0; else no default-exit0; fi
has    default-keeps-other-top-level-dirs "$WT1/plugins/x.md"
has    default-keeps-second-top-level-dir "$WT1/tooling/y.md"
has    default-keeps-root-gitignore       "$WT1/.gitignore"
has    default-keeps-registry-gitignore   "$WT1/registry/.gitignore"
has    default-keeps-named-record         "$WT1/registry/exp-a/DESIGN.md"
has    default-keeps-named-record-subdir  "$WT1/registry/exp-a/figures/f.svg"
hasnt  default-excludes-unnamed-record-b  "$WT1/registry/exp-b"
hasnt  default-excludes-unnamed-record-c  "$WT1/registry/exp-c"
[ "$(git -C "$WT1" rev-parse --abbrev-ref HEAD)" = "w1" ] && ok default-new-branch-checked-out || no default-new-branch-checked-out

# --- the fail-loud property: `git add` inside the cone works, outside it does not ---
mkdir -p "$WT1/registry/exp-a/new" && printf 'n\n' > "$WT1/registry/exp-a/new/n.md"
git -C "$WT1" add -- registry/exp-a >/dev/null 2>&1 && ok add-inside-cone-ok || no add-inside-cone-ok
mkdir -p "$WT1/registry/exp-b" && printf 'x\n' > "$WT1/registry/exp-b/D.md"
git -C "$WT1" add -- registry/exp-b >/dev/null 2>&1 && no add-outside-cone-refused || ok add-outside-cone-refused
# ...and the refusal really left it unstaged, rather than warning and staging anyway.
git -C "$WT1" diff --cached --name-only | grep -q '^registry/exp-b/' \
  && no add-outside-cone-not-staged || ok add-outside-cone-not-staged

# --- ignore rules still decide the same way they would in a full checkout ---
printf 'zz\n' > "$WT1/registry/exp-a/artifact.huge"
git -C "$WT1" check-ignore -q registry/exp-a/artifact.huge \
  && ok registry-gitignore-still-applies || no registry-gitignore-still-applies
printf 'zz\n' > "$WT1/registry/exp-a/artifact.big"
git -C "$WT1" check-ignore -q registry/exp-a/artifact.big \
  && ok root-gitignore-still-applies || no root-gitignore-still-applies

# --- several records named at once ---
WT2="$TMP/wt-multi"
sw -b w2 "$WT2" main registry/exp-a registry/exp-c >/dev/null 2>&1
has   multi-record-a "$WT2/registry/exp-a/DESIGN.md"
has   multi-record-c "$WT2/registry/exp-c/DESIGN.md"
hasnt multi-excludes-b "$WT2/registry/exp-b"

# --- no record named at all: registry/ entirely absent, everything else present ---
WT3="$TMP/wt-none"
sw -b w3 "$WT3" main >/dev/null 2>&1
has   none-keeps-other-dirs "$WT3/plugins/x.md"
hasnt none-drops-registry   "$WT3/registry"

# --- a record dir that does not exist at the base commit (log-experiment's new-experiment case) ---
WT4="$TMP/wt-new-record"
if sw -b w4 "$WT4" main registry/brand-new >/dev/null 2>&1; then ok new-record-exit0; else no new-record-exit0; fi
mkdir -p "$WT4/registry/brand-new" && printf 'd\n' > "$WT4/registry/brand-new/DESIGN.md"
git -C "$WT4" add -- registry/brand-new >/dev/null 2>&1 && ok new-record-addable || no new-record-addable

# --- --full: the explicit escape hatch still materializes the whole registry ---
WT5="$TMP/wt-full"
if sw --full -b w5 "$WT5" main >/dev/null 2>&1; then ok full-exit0; else no full-exit0; fi
has full-keeps-record-a "$WT5/registry/exp-a/DESIGN.md"
has full-keeps-record-b "$WT5/registry/exp-b/DESIGN.md"
has full-keeps-record-c "$WT5/registry/exp-c/DESIGN.md"

# --- sparse really is SMALLER on disk than full (the whole point of the ticket). Compared on a second
#     fixture whose unnamed records carry real bulk, and on FRESH trees: WT1 above has had test files added
#     to it, so it is not a clean size sample. ---
BULK="$TMP/bulk-repo"
git init -q -b main "$BULK"
mkdir -p "$BULK/registry/wanted" "$BULK/registry/heavy-1" "$BULK/registry/heavy-2" "$BULK/plugins"
printf 'p\n' > "$BULK/plugins/x.md"
printf 'd\n' > "$BULK/registry/wanted/DESIGN.md"
# ~1M per unnamed record — the shape of the real registry (a few big jsonl/json per experiment), small
# enough to stay a fast fixture, big enough that the difference cannot be filesystem-block noise.
for h in heavy-1 heavy-2; do
  for i in 1 2 3 4; do head -c 262144 /dev/zero | tr '\0' 'x' > "$BULK/registry/$h/rollouts-$i.jsonl"; done
done
git -C "$BULK" add -A
git -C "$BULK" -c user.email=t@t -c user.name=t commit -qm init
bash "$S" --repo "$BULK" -b s "$TMP/bulk-sparse" main registry/wanted >/dev/null 2>&1
bash "$S" --repo "$BULK" --full -b f "$TMP/bulk-full" main >/dev/null 2>&1
sparse_du=$(du -s --exclude=.git "$TMP/bulk-sparse" 2>/dev/null | cut -f1)
full_du=$(du -s --exclude=.git "$TMP/bulk-full" 2>/dev/null | cut -f1)
if [ -n "$sparse_du" ] && [ -n "$full_du" ] && [ "$((sparse_du * 2))" -lt "$full_du" ]; then
  ok "sparse-much-smaller-than-full ($sparse_du vs $full_du blocks)"
else
  no "sparse-much-smaller-than-full ($sparse_du vs $full_du blocks — expected sparse < half of full)"
fi

# --- without -b, an existing branch is CHECKED OUT, not left detached ---
git -C "$REPO" branch -q other main
WT6="$TMP/wt-existing-branch"
sw "$WT6" other registry/exp-b >/dev/null 2>&1
[ "$(git -C "$WT6" rev-parse --abbrev-ref HEAD)" = "other" ] && ok existing-branch-not-detached || no existing-branch-not-detached
has existing-branch-record "$WT6/registry/exp-b/DESIGN.md"

# --- the main checkout is never made sparse by any of the above (extensions.worktreeConfig is per-worktree) ---
has main-checkout-still-full-a "$REPO/registry/exp-a/DESIGN.md"
has main-checkout-still-full-b "$REPO/registry/exp-b/DESIGN.md"
git -C "$REPO" sparse-checkout list >/dev/null 2>&1 && no main-checkout-not-sparse || ok main-checkout-not-sparse

# --- a RELATIVE <worktree-path> is created where the CALLER stands, not inside --repo (`git -C <repo>
#     worktree add <rel>` would resolve it against the repo, and the sparse steps address it cwd-relative) ---
CALLER_CWD="$TMP/caller"
mkdir -p "$CALLER_CWD"
( cd "$CALLER_CWD" && bash "$S" --repo "$REPO" -b w8 rel-wt main registry/exp-a >/dev/null 2>&1 )
has   relative-path-created-at-caller "$CALLER_CWD/rel-wt/registry/exp-a/DESIGN.md"
hasnt relative-path-not-inside-repo   "$REPO/rel-wt"

# --- fail-closed refusals ---
sw -b dup "$WT1" main >/dev/null 2>&1 && no refuse-existing-path || ok refuse-existing-path
sw -b bad "$TMP/wt-bad-commit" nosuchref >/dev/null 2>&1 && no refuse-non-commit || ok refuse-non-commit
hasnt refuse-non-commit-no-tree "$TMP/wt-bad-commit"
bash "$S" --repo "$TMP/not-a-repo" "$TMP/wt-no-repo" main >/dev/null 2>&1 && no refuse-non-repo || ok refuse-non-repo
sw --bogus "$TMP/wt-bogus" main >/dev/null 2>&1 && no refuse-unknown-flag || ok refuse-unknown-flag
sw -b "$TMP/wt-missing-value" >/dev/null 2>&1 && no refuse-missing-args || ok refuse-missing-args

# --- a failure AFTER `worktree add` leaves NO half-created worktree behind (and no stale registration in
#     `git worktree list`). Forced deterministically with a `git` shim on PATH that fails only the
#     `sparse-checkout` step and forwards everything else to the real git — permission-bit tricks are not
#     portable here (git recreates its own admin dirs, and root ignores the bits anyway). ---
REAL_GIT="$(command -v git)"
mkdir -p "$TMP/shim"
{
  printf '#!/bin/sh\n'
  printf 'for a in "$@"; do [ "$a" = "sparse-checkout" ] && exit 1; done\n'
  printf 'exec %s "$@"\n' "$REAL_GIT"
} > "$TMP/shim/git"
chmod +x "$TMP/shim/git"
WT7="$TMP/wt-abort"
PATH="$TMP/shim:$PATH" bash "$S" --repo "$REPO" -b w7 "$WT7" main registry/exp-a >/dev/null 2>&1 \
  && no abort-nonzero-exit || ok abort-nonzero-exit
hasnt abort-no-half-worktree "$WT7"
git -C "$REPO" worktree list | grep -q "wt-abort" && no abort-no-stale-registration || ok abort-no-stale-registration

# --- the two shipped copies must stay byte-identical ---
if [ -f "$LE_COPY" ]; then
  cmp -s "$S" "$LE_COPY" && ok log-experiment-copy-in-sync \
    || no "log-experiment-copy-in-sync (copies drift; keep run-experiment and log-experiment byte-identical)"
else
  echo "skip log-experiment-copy-in-sync (no sibling log-experiment skill dir in this install)"
fi

if [ "$fails" = 0 ]; then echo "[smoke] sparse_worktree: ALL PASS"; else echo "[smoke] sparse_worktree: FAILURES"; fi
exit "$fails"
