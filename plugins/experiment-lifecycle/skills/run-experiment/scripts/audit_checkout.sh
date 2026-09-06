#!/bin/bash
# audit_checkout.sh — the ONE lifecycle for a close-audit CLEAN CHECKOUT: create it sparse under a fixed,
# reapable prefix, and remove it again through a statically-bounded delete. The creation-side sibling of
# sparse_worktree.sh (same dir) and reap_worktree.sh, for the one checkout neither of them owns — the
# throwaway clean-room tree an auditor makes to answer "does this code actually regenerate the headline
# numbers from a fresh checkout".
#
# INCIDENT (automated-researcher#840, 2026-09-06): a week after #804 the disk hit 95% again, and closing
# ONE experiment had left three full clones in /tmp — `<exp>-clean-checkout`, `<exp>-repro.HB0fxQ`,
# `<exp>-repro-corrected.QnOz0f` — 10.7G between them, all created inside a two-hour window by the
# auditing session BY HAND, not by any product script. Older unmatched siblings from already-closed
# experiments (`<exp>-build`, `full_dry`, `<exp>_prelim`) added another 3.6G. Two failures compounded:
#   1. NOTHING CREATED THEM, so nothing removed them. An audit checkout has an obvious end of life — the
#      moment the verdict is written — but a tree made by hand at an ad-hoc path has no owner to notice.
#   2. THE NAMES WERE UNPREDICTABLE, so repo-janitor's backstop globs could not match them either. A
#      backstop can only catch what it can NAME; ad-hoc naming defeats the sweep as surely as the missing
#      cleanup defeats the close.
# So the path is not the caller's choice: it is `<temp root>/<exp>-audit.<random>`, one fixed shape that
# the close reaps directly and repo-janitor can glob as a backstop when a close died before reaping.
#
# ...AND IT IS CREATED SPARSE (automated-researcher#805). A full clone of the research repo materializes
# the whole `registry/` tree (~2.2G on disk per checkout, measured); an audit reads ONE experiment's
# record. sparse_worktree.sh already owns that recipe, so this helper routes through it rather than
# re-deriving the cone — and a worktree (not a clone) is also what makes the tree visible to
# `git worktree list`, which is what lets repo-janitor sweep a leaked one with git's own refusals standing
# behind the removal instead of a bare `rm -rf`.
#
# USAGE
#   audit_checkout.sh create <exp-slug> [--repo <dir>] [--full] [--] <committish> [<include-path> ...]
#       Prints the created checkout's absolute path on STDOUT — and nothing else, so `$( )` capture is
#       exact. Every log line goes to stderr.
#   audit_checkout.sh reap <path>
#       Removes a checkout this helper created. Refuses anything else (see the bound below).
#
# THE DELETE SCOPE IS STATICALLY BOUNDED, and that is the whole safety story for `reap`: the path must be a
# DIRECT CHILD of the same temp root `create` uses, its name must match the `*-audit.*` shape `create`
# mints, it must not be a symlink or resolve through one, it must not be the calling shell's cwd or an
# ancestor of it, and it must be a LINKED GIT WORKTREE — which is what makes the removal `git worktree
# remove` (with git's own history/attachedness checks) instead of an `rm -rf` with nothing underneath it.
# Anything failing any of those is REPORTED and left alone, never deleted: the cost of refusing is one
# reported directory that repo-janitor's next sweep sees anyway; the cost of guessing is unrecoverable.
#
# WHAT THE INSTANCE SUPPLIES: nothing. `TMPDIR` (or AUDIT_CHECKOUT_TMPDIR, below) is the only path input and
# both have a POSIX default — the prefix shape is a PRODUCT convention, deliberately, because a backstop
# glob in another plugin has to be able to name it.
#   AUDIT_CHECKOUT_TMPDIR — override the temp root (default: $TMPDIR, else /tmp). Must be absolute.
set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SPARSE="$SCRIPT_DIR/sparse_worktree.sh"

# The fixed name shape, stated ONCE. `repo-janitor`'s documented backstop glob is the same string with the
# exp slug replaced by a wildcard, so a change here is a change to a cross-plugin convention (see
# verify-claims/SKILL.md and repo-janitor/SKILL.md).
SUFFIX="-audit."

say(){ echo "audit_checkout: $*" >&2; }
die(){ echo "audit_checkout: $*" >&2; exit 1; }

temp_root(){
  local root=${AUDIT_CHECKOUT_TMPDIR:-${TMPDIR:-/tmp}}
  while [ "${root%/}" != "$root" ] && [ "$root" != "/" ]; do root=${root%/}; done
  case "$root" in
    /*) : ;;
    *) die "temp root must be an ABSOLUTE path (got '$root') — a relative root would put the checkout somewhere the reap bound cannot name" ;;
  esac
  [ "$root" != "/" ] && [ -d "$root" ] || die "temp root '$root' is not a usable directory"
  (cd "$root" && pwd -P) || die "could not resolve temp root '$root'"
}

VERB=${1:-}
[ -n "$VERB" ] || die "usage: audit_checkout.sh create <exp-slug> [--repo <dir>] [--full] <committish> [<include-path> ...] | reap <path>"
shift

case "$VERB" in
create)
  [ $# -ge 1 ] || die "create requires an <exp-slug> (it becomes the checkout's name prefix)"
  EXP=$1; shift
  [ -n "$EXP" ] || die "create requires a non-empty <exp-slug> (it becomes the checkout's name prefix)"
  # The slug lands in a filesystem path AND in the glob repo-janitor matches, so it is restricted rather
  # than sanitized: a '/' would break the direct-child bound, and a glob metacharacter would make the
  # backstop glob match more (or less) than the one tree. Refuse instead of rewriting the caller's slug
  # into something that no longer identifies the experiment.
  case "$EXP" in
    *[!A-Za-z0-9._-]*|.|..|.*) die "exp-slug '$EXP' must be non-empty, must not start with '.', and may contain only [A-Za-z0-9._-] — it becomes a path segment and a glob target" ;;
  esac

  REPO="."
  declare -a PASSTHRU=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --repo) [ $# -ge 2 ] || die "--repo requires a value"; REPO="$2"; shift 2 ;;
      --full) PASSTHRU+=(--full); shift ;;
      --)     shift; break ;;
      -*)     die "unknown flag: $1" ;;
      *)      break ;;
    esac
  done
  [ $# -ge 1 ] || die "create requires a <committish>"
  COMMITTISH="$1"; shift
  [ -f "$SPARSE" ] || die "sparse_worktree.sh not found next to audit_checkout.sh — refusing to create a FULL checkout instead (that is the ~2.2G-per-tree cost automated-researcher#805 exists to remove)"

  # Resolve to a SHA and hand THAT to sparse_worktree.sh, so the audit checkout lands DETACHED. Two
  # reasons, both load-bearing: (1) `git worktree add <path> <branch>` refuses outright when that branch is
  # already checked out somewhere (the default branch usually is, in the shared checkout), which would make
  # the ordinary `audit_checkout.sh create <exp> main` invocation fail for a reason that has nothing to do
  # with the audit; (2) a clean-room tree must be a fixed, quotable point in history — a branch ref can
  # move under a long audit, and a verdict about "the code at <branch>" is not reproducible.
  SHA=$(git -C "$REPO" rev-parse --verify --quiet "$COMMITTISH^{commit}") \
    || die "not a commit: '$COMMITTISH' (in repo '$REPO')"

  ROOT=$(temp_root) || exit 1
  # mktemp mints the unique name (never a predictable one — two audits of the same experiment must not
  # collide), then the directory is removed because `git worktree add` refuses an existing path. The window
  # between the two is a single rmdir wide and closes LOUDLY if anything else takes the name meanwhile:
  # sparse_worktree.sh's own `[ -e "$WT" ]` check dies rather than reusing a tree it did not create.
  WT=$(mktemp -d "$ROOT/$EXP${SUFFIX}XXXXXX") || die "could not mint a checkout path under '$ROOT'"
  rmdir "$WT" || die "could not clear the minted path '$WT' before creating the worktree"

  if ! bash "$SPARSE" --repo "$REPO" ${PASSTHRU[@]+"${PASSTHRU[@]}"} -- "$WT" "$SHA" "$@"; then
    # sparse_worktree.sh removes its own partial tree on failure, so there is nothing to clean up here —
    # and nothing was printed on stdout, so a caller capturing the path gets an empty string plus a
    # non-zero exit rather than a path to a half-materialized tree.
    die "sparse_worktree.sh could not create the audit checkout at '$WT'"
  fi
  say "audit checkout created: '$WT' (detached at $SHA, from '$COMMITTISH'). REAP IT when the audit verdict is written: audit_checkout.sh reap '$WT'"
  printf '%s\n' "$WT"
  ;;

reap)
  [ $# -eq 1 ] || die "usage: audit_checkout.sh reap <path>"
  WT=$1
  [ -n "$WT" ] || die "reap requires a path"
  ROOT=$(temp_root) || exit 1

  [ -e "$WT" ] || { say "nothing to reap: '$WT' does not exist (already removed)"; exit 0; }
  [ -L "$WT" ] && die "refusing to reap '$WT': it is a symlink — removing it would leave the tree it points at"
  [ -d "$WT" ] || die "refusing to reap '$WT': not a directory"
  REAL=$(cd "$WT" && pwd -P) || die "could not resolve '$WT'"
  [ "$REAL" = "$WT" ] || die "refusing to reap '$WT': it resolves through a symlinked ancestor to '$REAL' — the bound below is a path bound, so it must be checked against the path actually named"
  [ "$(dirname "$REAL")" = "$ROOT" ] || die "refusing to reap '$REAL': not a DIRECT CHILD of the audit temp root '$ROOT' — this helper only ever removes checkouts it created"
  case "$(basename "$REAL")" in
    *"$SUFFIX"*) : ;;
    *) die "refusing to reap '$REAL': its name does not carry the '$SUFFIX' shape this helper mints — an unrelated directory under the temp root is not an audit checkout" ;;
  esac
  PWD_REAL=$(pwd -P 2>/dev/null) || PWD_REAL=""
  case "${PWD_REAL:-/dev/null}" in
    "$REAL"|"$REAL"/*) die "refusing to reap '$REAL': the calling shell is standing inside it — cd out first, then re-run" ;;
  esac

  # A LINKED WORKTREE is the last condition, and it is what makes this removal safe rather than merely
  # bounded: `git worktree remove` refuses a tree with unmerged history/attachedness problems, and it
  # prunes the administrative record an `rm -rf` would strand. A directory under this prefix that is NOT a
  # worktree is not something `create` made, so it is reported for a human rather than destroyed.
  COMMON=$(git -C "$REAL" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || COMMON=""
  OWN=$(git -C "$REAL" rev-parse --path-format=absolute --git-dir 2>/dev/null) || OWN=""
  TOP=$(git -C "$REAL" rev-parse --show-toplevel 2>/dev/null) || TOP=""
  if [ -z "$COMMON" ] || [ -z "$OWN" ] || [ "$COMMON" = "$OWN" ] || [ "$TOP" != "$REAL" ]; then
    die "refusing to reap '$REAL': it is not a LINKED git worktree (this helper creates worktrees, so anything else here was created by something else). Inspect it and remove it by hand, or let repo-janitor's sweep report it."
  fi
  # `git worktree list`'s FIRST entry is always the repo's own primary checkout — the stable cwd for the
  # removal, since git will not remove the worktree the command is running inside.
  MAIN=$(git -C "$REAL" worktree list --porcelain 2>/dev/null | sed -n '1s/^worktree //p')
  [ -n "$MAIN" ] || die "refusing to reap '$REAL': could not resolve its repo's primary checkout to run the removal from"
  git -C "$MAIN" worktree remove --force "$REAL" \
    || die "'git worktree remove --force $REAL' FAILED — the checkout is still on disk; remove it by hand and say so on the close report"
  say "audit checkout reaped: '$REAL'"
  ;;

*) die "unknown verb '$VERB' — expected 'create' or 'reap'" ;;
esac
