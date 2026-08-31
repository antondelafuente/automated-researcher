#!/bin/bash
# sparse_worktree.sh — create a git worktree of the research repo SPARSE by default: every top-level dir
# EXCEPT the heavy `registry/` tree, plus only the `registry/<exp>` record(s) the task actually names. The
# creation-side counterpart of reap_worktree.sh (same dir), and the single place this recipe lives so no
# caller has to re-derive it.
#
# WHY (automated-researcher#805, measured on the instance 2026-08-31): of 184G used on a 225G disk, 57G was
# worktrees — 25 checkouts of the research repo, each carrying its own copy of the 5.3G `registry/` (~2.2G on
# disk per worktree) while durable research data was only 6.5G. Almost every worktree task (design / explore /
# synthesis / bridge sessions / log-experiment staging) touches ONE `registry/<exp>` dir or none, yet
# materialized all 301. At ~10 new worktrees/day × 2.2G ≈ 20G/day, no scratch reaper (#792/#793, #804) and no
# disk purchase can outrun that — reaping changes the intercept, sparse checkout changes the SLOPE. A sparse
# worktree carrying one experiment measures ~100-300M instead of ~2.2G.
#
# The same #805 measurement is also why log-experiment.sh's staging worktree routes through here: it is a
# fresh full checkout in /tmp on EVERY log run, transiently materializing the whole registry (the #666 ENOSPC
# class of failure, from the other direction — there the input dir was too big to copy, here the base tree is
# too big to check out).
#
# USAGE
#   sparse_worktree.sh [--repo <dir>] [-b <new-branch>] [--full] [--] <worktree-path> <committish> [<include-path> ...]
#
#   --repo <dir>        repo (or worktree of it) to create from; default: the cwd's repo.
#   -b <new-branch>     create <new-branch> at <committish> (passed straight to `git worktree add -b`).
#                       Without it, <committish> is checked out as-is, exactly like a plain `git worktree add`.
#   --full              THE EXPLICIT ESCAPE HATCH: plain full checkout, no sparse rules at all. For the rare
#                       task that genuinely needs the whole registry (synthesis sweeps, cross-experiment viz).
#                       Deliberately a flag and not a heuristic: "does this task need all 301 records" is not
#                       something a script can infer, and guessing WRONG toward full is how the 57G accrued.
#   <include-path> ...  extra cone-mode dirs to materialize on top of the default set — normally
#                       `registry/<exp>` for the experiment(s) this worktree is for. Repeatable. A path that
#                       does not exist at <committish> is accepted (cone mode simply matches nothing): a NEW
#                       experiment's record dir does not exist on the base branch yet, and `git add`ing it
#                       inside the worktree is exactly the log-experiment case.
#
# WHAT "SPARSE" MEANS HERE, precisely: cone-mode sparse checkout whose set is (every top-level DIR at
# <committish>, minus `registry`) + (<include-path> ...). Cone mode also materializes each included path's
# ANCESTOR dirs' own files, so the repo root's files and `registry/.gitignore` are present — load-bearing for
# log-experiment, whose ignored-file guard (#340) and staging copy (#666) both decide against the worktree's
# `.gitignore` state and would silently change verdicts if a rule file went missing.
#
# `registry` is named as a PRODUCT convention (the research repo's registry-of-records layout that
# log-experiment classifies against), not as an instance value — there is no path, host, or bucket here.
#
# FAIL-CLOSED / SAFETY
#   - `git add` on a path OUTSIDE the sparse set fails loudly (git's own `advice.updateSparsePath` error), it
#     does not silently skip. So a caller that forgot to name its record dir gets an error, never a quietly
#     incomplete commit. That property is why the default set can be narrow.
#   - On any failure AFTER `git worktree add` succeeds, the partially-created worktree is removed before
#     dying: a half-materialized tree is never handed back. The BRANCH ref is never deleted (same reasoning as
#     reap_worktree.sh gate 6 — refs are cheap and preserve recoverability), so branch cleanup stays the
#     caller's own concern.
#   - git older than 2.27 has no `sparse-checkout set --cone`. That degrades LOUDLY to a full checkout rather
#     than dying: this helper sits on log-experiment's record-landing path, and refusing to land a research
#     record over a disk optimization would be the wrong trade. The warning names the version so the box gets
#     fixed.
#   - `git sparse-checkout` enables the `extensions.worktreeConfig` repo extension on first use. That is git's
#     own documented mechanism for per-worktree config and it does NOT make any other worktree sparse
#     (verified: the main checkout stays non-sparse, `sparse-checkout list` there reports "not sparse").
set -euo pipefail

die(){ echo "sparse_worktree: $*" >&2; exit 1; }
note(){ echo "sparse_worktree: $*" >&2; }

# The one top-level tree this helper exists to keep OUT of the default set (see header).
HEAVY_DIR="registry"
# `sparse-checkout set --cone <path>...` landed in git 2.27.
MIN_GIT="2.27"

REPO="."
NEW_BRANCH=""
FULL=0
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) [ $# -ge 2 ] || die "--repo requires a value"; REPO="$2"; shift 2 ;;
    -b)     [ $# -ge 2 ] || die "-b requires a value"; NEW_BRANCH="$2"; shift 2 ;;
    --full) FULL=1; shift ;;
    --)     shift; break ;;
    -*)     die "unknown flag: $1" ;;
    *)      break ;;
  esac
done

[ $# -ge 2 ] || die "usage: sparse_worktree.sh [--repo <dir>] [-b <new-branch>] [--full] <worktree-path> <committish> [<include-path> ...]"
WT="$1"; shift
COMMITTISH="$1"; shift
declare -a INCLUDE=("$@")

# Make <worktree-path> absolute against the CALLER's cwd before anything touches it. `git -C "$REPO" worktree
# add <relative-path>` resolves that path relative to $REPO, not to the caller's cwd — so a relative path would
# be created somewhere the caller did not name, and the `git -C "$WT"` calls below (cwd-relative) would then
# address a different directory entirely. Not realpath'd: the path must NOT exist yet.
case "$WT" in /*) ;; *) WT="$PWD/$WT" ;; esac

[ -e "$WT" ] && die "worktree path already exists: $WT"
git -C "$REPO" rev-parse --git-common-dir >/dev/null 2>&1 || die "not a git repo (or worktree of one): $REPO"
# $COMMITTISH itself is what `worktree add` gets (so naming a BRANCH still checks that branch out rather than
# landing detached); the resolved SHA is used only to enumerate the cone, so the set can never be read off a
# different commit than the one that existed when this call started.
SHA="$(git -C "$REPO" rev-parse --verify --quiet "$COMMITTISH^{commit}")" \
  || die "not a commit: $COMMITTISH"

declare -a ADD_ARGS=()
[ -n "$NEW_BRANCH" ] && ADD_ARGS+=(-b "$NEW_BRANCH")
# ${arr[@]+"${arr[@]}"} throughout: `set -u` treats an empty array as unset on bash < 4.4.
add_worktree(){ git -C "$REPO" worktree add "$@" -q ${ADD_ARGS[@]+"${ADD_ARGS[@]}"} "$WT" "$COMMITTISH"; }

if [ "$FULL" = 1 ]; then
  add_worktree || die "could not create worktree $WT at $COMMITTISH"
  note "--full: $WT is a FULL checkout (whole $HEAVY_DIR/ materialized) — as asked."
  exit 0
fi

# ---- git capability gate: degrade loudly, never block a landing over a disk optimization (see header) ----
have_cone_sparse(){
  local v major minor
  v="$(git --version 2>/dev/null | sed -n 's/^git version \([0-9][0-9]*\.[0-9][0-9]*\).*/\1/p')"
  [ -n "$v" ] || return 1
  major="${v%%.*}"; minor="${v#*.}"
  [ "$major" -gt "${MIN_GIT%%.*}" ] && return 0
  [ "$major" -eq "${MIN_GIT%%.*}" ] && [ "$minor" -ge "${MIN_GIT#*.}" ]
}
if ! have_cone_sparse; then
  note "WARNING: this git has no 'sparse-checkout set --cone' (need >= $MIN_GIT; found '$(git --version 2>/dev/null)') — falling back to a FULL checkout of $WT; upgrade git to get automated-researcher#805's disk win."
  add_worktree || die "could not create worktree $WT at $COMMITTISH"
  exit 0
fi

# ---- the sparse set: every top-level dir at $SHA except $HEAVY_DIR, plus the caller's include paths ----
declare -a CONE=()
while IFS= read -r -d '' d; do
  [ "$d" = "$HEAVY_DIR" ] && continue
  CONE+=("$d")
done < <(git -C "$REPO" ls-tree -z -d --name-only "$SHA")
CONE+=(${INCLUDE[@]+"${INCLUDE[@]}"})

# --no-checkout is git's own documented recipe for this ("useful if you'd like to do a sparse checkout"):
# nothing is materialized until the `checkout` below, so the heavy tree is never written even transiently.
add_worktree --no-checkout || die "could not create worktree $WT at $COMMITTISH"

# From here on the worktree exists, so every failure path removes it before dying (see header).
abort(){ git -C "$REPO" worktree remove --force "$WT" >/dev/null 2>&1 || true; die "$*"; }

# Zero cone paths is legal and means "root files only" — reachable only when $SHA has no top-level dir but
# $HEAVY_DIR and no include path was named; `sparse-checkout set --cone` accepts it.
git -C "$WT" sparse-checkout set --cone -- ${CONE[@]+"${CONE[@]}"} \
  || abort "could not set the sparse-checkout cone on $WT"
# Bare `git checkout` is what materializes the sparse set in a --no-checkout worktree.
git -C "$WT" checkout \
  || abort "could not populate the sparse worktree $WT"

note "sparse worktree $WT at $COMMITTISH: ${#CONE[@]} cone path(s), $HEAVY_DIR/ excluded except ${#INCLUDE[@]} named record(s)${INCLUDE[0]+: ${INCLUDE[*]}}"
