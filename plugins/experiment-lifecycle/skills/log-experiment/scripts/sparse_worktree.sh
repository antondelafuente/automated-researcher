#!/bin/bash
# sparse_worktree.sh — create a git worktree of the research repo SPARSE by default: every top-level dir
# EXCEPT the heavy `registry/` tree, plus only the `registry/<exp>` record(s) the task actually names. The
# creation-side counterpart of reap_worktree.sh (same dir), and the single place this recipe lives so no
# caller has to re-derive it. `--existing` applies the SAME recipe IN PLACE to a worktree that already
# exists (see the second WHY below) — the two modes derive one cone from one function.
#
# WHY (automated-researcher#805, measured on the instance 2026-08-31): of 184G used on a 225G disk, 57G was
# worktrees — 25 checkouts of the research repo, each carrying its own copy of the 5.3G `registry/` (~2.2G on
# disk per worktree) while durable research data was only 6.5G. Almost every worktree task (design / explore /
# synthesis / bridge sessions / log-experiment staging) touches ONE `registry/<exp>` dir or none, yet
# materialized all 301. At ~10 new worktrees/day × 2.2G ≈ 20G/day, no scratch reaper (#792/#793, #804) and no
# disk purchase can outrun that — reaping changes the intercept, sparse checkout changes the SLOPE. A sparse
# worktree carrying one experiment measures ~100-300M instead of ~2.2G.
#
# WHY `--existing` (automated-researcher#807, measured on the same instance 2026-09-06): #805 could only
# intercept the ONE creation path a scaffold *script* owns, and disk hit 95% again 7 days later. Of 36 live
# worktrees of the research repo, 16 were NOT sparse — 5 harness-spawned (`claude rc … --spawn worktree` →
# `.claude/worktrees/*`, 12.8G) and 11 made by an instance's own worktree convention (a plain
# `git worktree add` in its session launchers, 24.1G) — and those 16 carried 37G of the 48G total, i.e.
# ~77% of worktree disk sat behind creation paths this script is never called on.
# A full checkout is now 2.3–2.6G (0.3G on 2026-07-01 → 1.8G on 08-01 → 2.6G on 09-06) against ~330M sparse.
# Neither of those two creation paths is this repo's code, so the product-side intercept is the FIRST ACT of
# the session that lands in such a tree: `--existing` reclaims the already-materialized registry copy rather
# than preventing it, which is the only lever a product script has on a tree someone else created.
#
# The same #805 measurement is also why log-experiment.sh's staging worktree routes through here: it is a
# fresh full checkout in /tmp on EVERY log run, transiently materializing the whole registry (the #666 ENOSPC
# class of failure, from the other direction — there the input dir was too big to copy, here the base tree is
# too big to check out).
#
# USAGE
#   sparse_worktree.sh [--repo <dir>] [-b <new-branch>] [--full] [--] <worktree-path> <committish> [<include-path> ...]
#   sparse_worktree.sh --existing <worktree-path> [<include-path> ...]
#
#   --repo <dir>        repo (or worktree of it) to create from; default: the cwd's repo.
#   -b <new-branch>     create <new-branch> at <committish> (passed straight to `git worktree add -b`).
#                       Without it, <committish> is checked out as-is, exactly like a plain `git worktree add`.
#   --full              THE EXPLICIT ESCAPE HATCH: plain full checkout, no sparse rules at all. For the rare
#                       task that genuinely needs the whole registry (synthesis sweeps, cross-experiment viz).
#                       Deliberately a flag and not a heuristic: "does this task need all 301 records" is not
#                       something a script can infer, and guessing WRONG toward full is how the 57G accrued.
#   --existing <path>   SPARSIFY IN PLACE, creating nothing: apply the same cone to a worktree that already
#                       exists — a harness-spawned `.claude/worktrees/*` tree, or one an instance's own
#                       launcher created (see the second WHY). Idempotent, and prints the bytes it reclaimed.
#                       Takes no `--repo` / `-b` / `--full`: the path IS the repo, it is already on a branch,
#                       and "leave it full" is spelled by not running this. Its own safety rules:
#                         - refuses the MAIN working tree (that is the box's one full copy of the registry);
#                         - refuses when ANY local state — modified, untracked, or IGNORED — sits inside a
#                           `registry/` path the cone would drop; name that record as an <include-path>
#                           instead. Ignored state counts because git DELETES a dropped directory that holds
#                           only ignored files (verified, see FAIL-CLOSED below), and the registry's big
#                           artifacts are exactly what is ignored there;
#                         - PRESERVES whatever `registry/` paths the tree's own cone already includes, so
#                           running it in an already-sparse tree can never un-materialize the record that
#                           tree was created for.
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
#   - `--existing` never creates or removes a worktree, and never touches a ref. What it changes is which
#     files git materializes — and that is NOT limited to tracked ones: verified on git 2.55, a directory
#     leaving the cone with only IGNORED files inside it is deleted outright (silently, exit 0), while one
#     holding UNTRACKED files is kept with a warning and its tracked siblings removed anyway, and a MODIFIED
#     tracked file is left in place with a warning. So the pre-check above refuses all three rather than
#     letting git pick, and the reclaimed figure is MEASURED with `du` afterwards rather than computed from
#     the cone — the number reported is the number the filesystem actually gave back.
#   - EVERY read the applied cone is derived from is TOTAL-OR-FATAL (#821's construction rule): the top-level
#     dir enumeration, the tree's own existing `sparse-checkout list`, the `git status` refusal gate, and the
#     `ls-tree` research-repo gate each go through a temp file with a checked exit status, never a pipeline or
#     a process substitution whose failure is invisible. The reason is asymmetric: a failed read of any of them
#     looks exactly like "nothing there", and "nothing there" is the answer that NARROWS the cone — i.e. the
#     answer that drops records. The one deliberate exception is `du` (below), which only feeds the printed
#     figure and never the cone.
#   - git older than 2.27 has no `sparse-checkout set --cone`. That degrades LOUDLY to a full checkout rather
#     than dying: this helper sits on log-experiment's record-landing path, and refusing to land a research
#     record over a disk optimization would be the wrong trade. The warning names the version so the box gets
#     fixed. `--existing` degrades the same way (a loud warning, tree left as it was, exit 0): it runs as a
#     session's first act, and a disk optimization must never be the thing that stops a run from starting.
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
REPO_SET=0
NEW_BRANCH=""
FULL=0
EXISTING=""
while [ $# -gt 0 ]; do
  case "$1" in
    --repo)     [ $# -ge 2 ] || die "--repo requires a value"; REPO="$2"; REPO_SET=1; shift 2 ;;
    -b)         [ $# -ge 2 ] || die "-b requires a value"; NEW_BRANCH="$2"; shift 2 ;;
    --full)     FULL=1; shift ;;
    --existing) [ $# -ge 2 ] || die "--existing requires a value"; EXISTING="$2"; shift 2 ;;
    --)         shift; break ;;
    -*)         die "unknown flag: $1" ;;
    *)          break ;;
  esac
done

# ${arr[@]+"${arr[@]}"} throughout: `set -u` treats an empty array as unset on bash < 4.4.
is_num(){ case "${1:-}" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }

# `sparse-checkout set --cone <path>...` landed in git 2.27 (see the FAIL-CLOSED note).
have_cone_sparse(){
  local v major minor
  v="$(git --version 2>/dev/null | sed -n 's/^git version \([0-9][0-9]*\.[0-9][0-9]*\).*/\1/p')"
  [ -n "$v" ] || return 1
  major="${v%%.*}"; minor="${v#*.}"
  [ "$major" -gt "${MIN_GIT%%.*}" ] && return 0
  [ "$major" -eq "${MIN_GIT%%.*}" ] && [ "$minor" -ge "${MIN_GIT#*.}" ]
}

# THE cone recipe, in one place so the creation path and --existing can never drift apart: every top-level dir
# at $2 except $HEAVY_DIR, plus the include paths. Fills the global CONE.
# Args: <repo-or-worktree dir> <sha> [<include-path> ...]
compute_cone(){
  local dir="$1" sha="$2" d tf
  shift 2
  CONE=()
  # Enumerated through a temp file, not a process substitution: a `ls-tree` that failed partway would
  # otherwise leave CONE holding only the include paths, and the resulting cone would drop every ordinary
  # top-level dir. An enumeration this cone is derived from is total-or-fatal (the #821 construction rule).
  tf="$(mktemp)" || die "could not create a temp file"
  git -C "$dir" ls-tree -z -d --name-only "$sha" > "$tf" \
    || { rm -f "$tf"; die "could not enumerate the top-level dirs at $sha"; }
  while IFS= read -r -d '' d; do
    [ "$d" = "$HEAVY_DIR" ] && continue
    CONE+=("$d")
  done < "$tf"
  rm -f "$tf"
  CONE+=("$@")
}

# ---------------------------------------------------------------------------------------------------------
# --existing: sparsify a worktree that already exists (automated-researcher#807)
# ---------------------------------------------------------------------------------------------------------
# On-disk size in 1024-byte blocks, or empty when it can't be read. `|| true` because `du` exits non-zero on
# a partially-unreadable tree while still printing a total: the reclaimed figure is a REPORT, so it must never
# be the thing that fails a sparsify that otherwise worked (is_num below decides whether to trust it).
du_kb(){ du -sk -x "$1" 2>/dev/null | awk 'NR==1{print $1}' || true; }

sparsify_existing(){
  local wt="$1"; shift
  declare -a inc=("$@")

  [ "$FULL" = 0 ]        || die "--existing and --full are mutually exclusive: --full means 'leave the whole registry materialized', which is what NOT running --existing already does"
  [ -z "$NEW_BRANCH" ]   || die "--existing takes no -b: the worktree already exists and is already on a branch"
  [ "$REPO_SET" = 0 ]    || die "--existing takes no --repo: <worktree-path> IS the tree to sparsify, and its repo is derived from it"
  [ -d "$wt" ]           || die "--existing: not a directory: $wt"
  git -C "$wt" rev-parse --git-common-dir >/dev/null 2>&1 \
    || die "--existing: not a git worktree (or a worktree of one): $wt"

  # sparse-checkout is a per-WORKTREE setting, so resolve to the worktree root: a subdir argument must address
  # the tree the caller meant, not silently a different scope than the path they typed.
  local root
  root="$(git -C "$wt" rev-parse --show-toplevel)" \
    || die "--existing: could not resolve the worktree root of $wt"

  # Refuse the MAIN working tree. On the instance that is the box's one FULL copy of the registry — the thing
  # every sparse worktree is sparse *against* — and #805's own verified property is that it stays non-sparse.
  # Each rev-parse is read into its own variable and checked before it is used: inlined as `cd "$(git …)"` a
  # failed read expands to the empty string, and `cd ""` is a silent no-op success in bash, so the comparison
  # below would be made between two values that were never actually read.
  local gitdir commondir gd cd_
  gd="$(git -C "$root" rev-parse --git-dir)" \
    || die "--existing: could not resolve the git dir of $root"
  cd_="$(git -C "$root" rev-parse --git-common-dir)" \
    || die "--existing: could not resolve the common git dir of $root"
  gitdir="$(cd "$root" && cd "$gd" && pwd -P)" \
    || die "--existing: could not resolve the git dir of $root"
  commondir="$(cd "$root" && cd "$cd_" && pwd -P)" \
    || die "--existing: could not resolve the common git dir of $root"
  [ "$gitdir" != "$commondir" ] \
    || die "--existing: refusing to sparsify $root — it is the MAIN working tree, the one full checkout the sparse ones exist to avoid duplicating; run this on a linked worktree instead"

  local sha
  sha="$(git -C "$root" rev-parse --verify --quiet HEAD^{commit})" \
    || die "--existing: $root has no HEAD commit (unborn branch?) — there is no tree to derive a cone from"

  if ! have_cone_sparse; then
    note "WARNING: this git has no 'sparse-checkout set --cone' (need >= $MIN_GIT; found '$(git --version 2>/dev/null)') — leaving $root exactly as it is; upgrade git to reclaim automated-researcher#807's disk."
    return 0
  fi

  # Not a checkout of the research repo → nothing this helper knows how to sparsify. Exit 0 without touching
  # it: `--existing` is a session's blind first act, so pointing it at the wrong tree must be a no-op, never
  # a surprise sparse-checkout of an unrelated repo.
  # Read total-or-fatal (temp file, checked exit) rather than through a pipeline: `ls-tree | grep -qx` cannot
  # tell "$HEAVY_DIR/ is genuinely absent" from "the read failed", and conflating them would report the wrong
  # reason for doing nothing on a tree that IS the research repo. Empty output with exit 0 is the real
  # negative — a pathspec matching nothing is not an error to git.
  local htf
  htf="$(mktemp)" || die "could not create a temp file"
  git -C "$root" ls-tree -d --name-only "$sha" -- "$HEAVY_DIR" > "$htf" \
    || { rm -f "$htf"; die "--existing: could not read the top-level tree of $root at $sha — refusing to decide whether this is a checkout of the research repo from a read that failed"; }
  if ! grep -qx "$HEAVY_DIR" "$htf"; then
    rm -f "$htf"
    note "--existing: $root has no top-level $HEAVY_DIR/ at HEAD — not a checkout of the research repo; nothing to sparsify, leaving it alone."
    return 0
  fi
  rm -f "$htf"

  # PRESERVE the tree's own registry inclusions. This mode runs as the first act of a session standing in a
  # tree someone ELSE created, so it must never drop the record that tree was made for: an instance-convention
  # instance-created tree made sparse with `registry/<exp>` would otherwise be silently un-materialized by a
  # caller who did not know to re-name it (and a second run would undo the first). This is also what makes
  # re-running a no-op rather than a slow reshuffle.
  # ONE `sparse-checkout list`, read total-or-fatal through a temp file (the #821 construction rule, same as
  # compute_cone and the status gate below). This cone is an INPUT the set applied at the end is derived from,
  # so losing it is not a benign empty read: it silently narrows the cone and un-materializes exactly the
  # record this block exists to preserve. A probe-then-read-again pair could not be total either — the read
  # whose output is consumed was the unchecked one, and the two invocations need not agree.
  local p ctf lrc=0
  ctf="$(mktemp)" || die "could not create a temp file"
  git -C "$root" sparse-checkout list > "$ctf" 2>/dev/null || lrc=$?
  if [ "$lrc" -ne 0 ]; then
    rm -f "$ctf"
    # `list` fails on a tree that is not sparse AT ALL — the ordinary case for the harness/instance-created
    # trees this mode exists for, where there is by definition no cone to preserve. It also fails on a real
    # error, and the two must not be conflated, so which one happened is decided from the authoritative
    # per-worktree setting rather than inferred from the failure: a tree that IS sparse but whose cone cannot
    # be read is the case that must refuse, not the case that must proceed on an empty list. `config --get`
    # exits 1 for "key not set" (the not-sparse answer) and >1 for a real read error — which is itself a read
    # this decision depends on, so it is fatal rather than swallowed into "not sparse".
    local sc="" src=0
    sc="$(git -C "$root" config --bool --get core.sparseCheckout 2>/dev/null)" || src=$?
    [ "$src" -le 1 ] \
      || die "--existing: could not read core.sparseCheckout in $root (git config exited $src) — refusing to sparsify a tree whose existing sparse state cannot be determined"
    [ "$sc" != "true" ] \
      || die "--existing: $root is sparse (core.sparseCheckout=true) but 'git sparse-checkout list' failed there — refusing to apply a cone derived from a set that could not be read, since that would drop whatever $HEAVY_DIR/ record this tree was already made for"
  else
    while IFS= read -r p; do
      [ -n "$p" ] || continue
      # In cone mode `list` prints plain directories (`registry/exp-a`). Some gits print the raw PATTERN form
      # instead (`/registry/` + `!/registry/*/` + `/registry/exp-a/`), where an ANCESTOR line is
      # indistinguishable from "the whole registry is included" without also parsing the negations. An
      # unrecognized shape is therefore refused rather than guessed at: guessing wrong either drops the
      # record this tree was created for or silently no-ops a tree that needed sparsifying.
      case "$p" in
        '!'*|/*)
          rm -f "$ctf"
          note "--existing: cannot read $root's existing sparse-checkout cone — this git prints it in pattern form ('$p'), so which $HEAVY_DIR/ record(s) it keeps is not readable here. Leaving the tree alone rather than guessing."
          return 0 ;;
      esac
      case "$p" in "$HEAVY_DIR"|"$HEAVY_DIR"/*) inc+=("$p") ;; esac
    done < "$ctf"
    rm -f "$ctf"
  fi
  # Dedupe (the caller's includes and the tree's own cone routinely overlap) so the reported count is real.
  declare -a uniq=()
  local i j seen
  for i in ${inc[@]+"${inc[@]}"}; do
    seen=0
    for j in ${uniq[@]+"${uniq[@]}"}; do [ "$i" = "$j" ] && { seen=1; break; }; done
    [ "$seen" = 1 ] || uniq+=("$i")
  done
  inc=(${uniq[@]+"${uniq[@]}"})
  for i in ${inc[@]+"${inc[@]}"}; do
    [ "$i" = "$HEAVY_DIR" ] && {
      note "--existing: $root's own cone already names the whole $HEAVY_DIR/ tree — there is nothing for this mode to reclaim, and narrowing a deliberately-full cone is not its job. Leaving it alone."
      return 0
    }
  done

  # Refuse when ANY local state — modified, untracked, or IGNORED — sits inside a $HEAVY_DIR/ path the cone
  # would DROP (#807's stated contract). Each of git's three behaviors here was verified directly (git 2.55),
  # and none of them is a safe silent outcome:
  #   - a MODIFIED tracked file is left in place with a warning and exit 0 — a half-sparsified record and a
  #     reclaimed figure that isn't the whole story;
  #   - an UNTRACKED file keeps its directory (warning, exit 0) while its tracked siblings are still removed —
  #     a record left half-present on disk;
  #   - a directory holding ONLY IGNORED files is DELETED OUTRIGHT, ignored files and all, silently and with
  #     exit 0. That is the destructive one and the reason ignored state is a refusal rather than a footnote:
  #     the registry's own big artifacts are exactly what `registry/.gitignore` covers, they live on disk and
  #     in the artifact store rather than in git, so git deleting them is not recoverable with a `git
  #     checkout` the way a dropped tracked file is.
  # The remedy is always the caller's to choose (land the work, or name that record as an <include-path>) —
  # never this script's to guess, because none of the three is distinguishable from "stale junk" from here.
  declare -a blockers=()
  local rec keep stf
  # Via a temp file rather than a process substitution so a `git status` that FAILED cannot read as "clean"
  # (fail-open on a refusal check is the one thing this gate must not do).
  stf="$(mktemp)" || die "could not create a temp file"
  git -C "$root" status --porcelain -z --untracked-files=normal --ignored > "$stf" \
    || { rm -f "$stf"; die "--existing: could not read git status in $root — refusing to sparsify a tree whose uncommitted state cannot be determined"; }
  while IFS= read -r -d '' rec; do
    p="$rec"
    # `--porcelain -z` records are `XY <path>` (a rename adds the original path as its own record, which is
    # also a path under the same tree, so treating every record as a path candidate is conservative).
    [ "${p:2:1}" = " " ] && p="${p:3}"
    case "$p" in "$HEAVY_DIR"/*) ;; *) continue ;; esac
    keep=0
    for i in ${inc[@]+"${inc[@]}"}; do
      case "$p" in "$i"|"$i"/*) keep=1; break ;; esac
    done
    [ "$keep" = 1 ] || blockers+=("$p")
  done < "$stf"
  rm -f "$stf"
  if [ "${#blockers[@]}" -gt 0 ]; then
    for p in ${blockers[@]+"${blockers[@]}"}; do note "  local state that would be dropped or orphaned: $p"; done
    die "--existing: refusing to sparsify $root — ${#blockers[@]} modified/untracked/ignored path(s) sit inside the $HEAVY_DIR/ records this cone would drop (listed above; an ignored-only record dir would be DELETED outright). Land or archive that work, or name the record(s) to keep: --existing $root $HEAVY_DIR/<exp> ..."
  fi

  compute_cone "$root" "$sha" ${inc[@]+"${inc[@]}"}

  local before after kb
  before="$(du_kb "$root")"
  git -C "$root" sparse-checkout set --cone -- ${CONE[@]+"${CONE[@]}"} \
    || die "--existing: could not apply the sparse-checkout cone to $root"
  after="$(du_kb "$root")"

  if is_num "$before" && is_num "$after"; then
    kb=$(( before - after )); [ "$kb" -lt 0 ] && kb=0
    note "--existing: $root sparsified — reclaimed $(( kb * 1024 )) bytes ($(( kb / 1024 )) MiB); ${#CONE[@]} cone path(s), $HEAVY_DIR/ excluded except ${#inc[@]} kept record(s)${inc[0]+: ${inc[*]}}"
  else
    note "--existing: $root sparsified — ${#CONE[@]} cone path(s), $HEAVY_DIR/ excluded except ${#inc[@]} kept record(s)${inc[0]+: ${inc[*]}}; reclaimed bytes UNKNOWN (du unavailable here)"
  fi
}

if [ -n "$EXISTING" ]; then
  sparsify_existing "$EXISTING" "$@"
  exit 0
fi

# ---------------------------------------------------------------------------------------------------------
# creation mode (the default): make a NEW worktree, sparse
# ---------------------------------------------------------------------------------------------------------
[ $# -ge 2 ] || die "usage: sparse_worktree.sh [--repo <dir>] [-b <new-branch>] [--full] <worktree-path> <committish> [<include-path> ...]  |  sparse_worktree.sh --existing <worktree-path> [<include-path> ...]"
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
add_worktree(){ git -C "$REPO" worktree add "$@" -q ${ADD_ARGS[@]+"${ADD_ARGS[@]}"} "$WT" "$COMMITTISH"; }

if [ "$FULL" = 1 ]; then
  add_worktree || die "could not create worktree $WT at $COMMITTISH"
  note "--full: $WT is a FULL checkout (whole $HEAVY_DIR/ materialized) — as asked."
  exit 0
fi

# ---- git capability gate: degrade loudly, never block a landing over a disk optimization (see header) ----
if ! have_cone_sparse; then
  note "WARNING: this git has no 'sparse-checkout set --cone' (need >= $MIN_GIT; found '$(git --version 2>/dev/null)') — falling back to a FULL checkout of $WT; upgrade git to get automated-researcher#805's disk win."
  add_worktree || die "could not create worktree $WT at $COMMITTISH"
  exit 0
fi

# ---- the sparse set: every top-level dir at $SHA except $HEAVY_DIR, plus the caller's include paths ----
compute_cone "$REPO" "$SHA" ${INCLUDE[@]+"${INCLUDE[@]}"}

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
