#!/bin/bash
# wf.sh — the GitHub-backed scaffold-change workflow driver (SWE pipeline, Phase 1 / SHADOW MODE).
#
# Drives one scaffold change through its whole lifecycle, GitHub as the durable coordination layer:
#   Issue -> worktree branch -> namespaced proposals/<issue>-<slug>.md -> draft PR -> --scaffold design
#   review (posted) -> implement -> --code review (posted) -> classifier (records mechanical|architectural
#   with evidence, posted) -> checks + fail-closed gate -> merge-when-clean.
# The agent (following SKILL.md) does the JUDGMENT steps (write the design doc, implement, respond to
# findings) BETWEEN these mechanical subcommands; wf.sh is the glue that is too error-prone to hand-run.
#
# WHY worktree-from-the-start (PR #3's review, folded): the standalone predecessor used a
# `checkout -b -> commit -> checkout main` dance on the SHARED main checkout, which bred three real races —
# reviewing STALE files, a commit-failure STRANDING the shared checkout off main, and a remote-vs-local SHA
# gap. A dedicated worktree dissolves all three: the branch work never touches the shared `main` checkout.
#
# WHY fail-closed everywhere (ship-change's hardening, folded): a crashed/garbage review must NEVER read as
# "clean" and merge. Every review verdict is parsed from the AUTHORITATIVE `SUMMARY: high=.. med=.. low=..`
# line; a missing/malformed summary BLOCKS. A reviewer process error BLOCKS. We also re-run --code as the
# merge gate so the merged diff is the reviewed diff (a HIGH fix earlier this program slipped a re-review).
#
# SHADOW MODE (Phase 1): wf.sh RUNS + POSTS + RECORDS, but nothing is enforced by GitHub branch protection
# yet (Phase 2 adds the per-family GitHub Apps + required checks). The merge here is the agent's own
# `gh pr merge` after the script's fail-closed gate — the gate logic lives in this script for now, not in
# branch protection. The classifier output is RECORDED on the PR (the human reads it), never blocks.
#
# Usage: run `wf.sh help` (or `-h` / no args) for the lifecycle short-list; SKILL.md is the full runbook.
# (The command list lives in ONE place — the usage() function below — not duplicated here.)
#
# Env: GH_TOKEN must be set (this instance: source ~/.env — wf.sh sources NO env file itself).
#      AUDIT_EXPERIMENT=<path to verify-claims audit_experiment.sh> overrides auto-location.
#      WF_WORKTREE_ROOT=<dir> (default /tmp) where worktrees are created.
#      ORIGIN_REPO=<path> the main checkout that owns the worktrees (default: this script's repo root).
set -euo pipefail

die(){ echo "BLOCKED: $*" >&2; exit 1; }
note(){ echo "[wf] $*" >&2; }
REVIEW_HIGH=0; REVIEW_ALL=0   # set by run_review (globals, nounset-safe defaults)

# the CANONICAL lifecycle short-list (single source — the header points here, help routes here). Prints to the
# given stream (default stdout). Doc paths are computed from the script's own dir so they're concrete from any cwd.
usage(){
  local d; d=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)
  cat <<EOF
wf.sh — the GitHub-backed scaffold-change workflow driver (SWE pipeline, shadow mode).

Lifecycle (the agent does the judgment steps BETWEEN these):
  wf.sh start  <issue#> <slug>            worktree + branch + design-doc skeleton   [then: write the doc]
  wf.sh open   <worktree>                 commit the doc, push, open the DRAFT PR
  wf.sh design-review <worktree> <author> --scaffold on the doc, post to PR (fail-closed)
  wf.sh code-review   <worktree> <author> --code on the diff, post to PR (fail-closed)
  wf.sh classify      <worktree>          classifier on changed paths, post evidence (shadow record)
  wf.sh finish <worktree> <author>        checks + fail-closed --code gate + ready + merge + cleanup
  wf.sh help                              this message

<author> = claude | codex (the OPPOSITE family reviews). Auth: GH_TOKEN (this instance: source ~/.env).
Full runbook: ${d:-<plugin>}/SKILL.md    Phase-2 + rollback: ${d:-<plugin>}/RUNBOOK.md
EOF
}

# the main checkout that owns worktrees. When wf.sh runs from the INSTALLED PLUGIN CACHE, the script's own
# dir is NOT the target repo — so default to the CWD's git root (the agent runs `start` from inside the repo
# it's changing), and only fall back to the script's repo. Env override always wins. Subcommands that already
# hold a worktree derive the repo/main-checkout FROM the worktree (see gh_repo / main_checkout) and don't
# rely on this at all.
SELF_REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")" && git rev-parse --show-toplevel 2>/dev/null || true)
ORIGIN_REPO=${ORIGIN_REPO:-$(git rev-parse --show-toplevel 2>/dev/null || echo "$SELF_REPO")}

need_gh(){ command -v gh >/dev/null || die "gh not on PATH"; [ -n "${GH_TOKEN:-}" ] || gh auth status >/dev/null 2>&1 \
  || die "no GitHub auth — set GH_TOKEN (this instance: source ~/.env) before invoking; wf.sh sources no env file"; }

locate_audit(){  # locate_audit [context-repo-dir]
  if [ -n "${AUDIT_EXPERIMENT:-}" ] && [ -f "$AUDIT_EXPERIMENT" ]; then echo "$AUDIT_EXPERIMENT"; return; fi
  local repo=${1:-} hit=""
  # 1. installed reviewer, highest version — Claude plugin cache AND Claude/Codex skill installs (symlink or copy).
  #    `|| true` is load-bearing under `set -euo pipefail`: a MISSING search dir makes find exit non-zero and
  #    (with pipefail) would abort the assignment BEFORE the in-tree fallback below — swallow it so we continue.
  hit=$(find "$HOME/.claude/plugins/cache" "$HOME/.claude/skills" "$HOME/.codex/skills" \
        -path '*verify-claims*scripts/audit_experiment.sh' 2>/dev/null | sort -V | tail -1 || true)
  # 2. fallback: the context repo's OWN in-tree copy (a repo-only checkout with no install still works)
  [ -n "$hit" ] || { [ -n "$repo" ] && hit=$(find "$repo/plugins" -path '*verify-claims*scripts/audit_experiment.sh' 2>/dev/null | sort -V | tail -1 || true); }
  [ -n "$hit" ] || die "cannot locate verify-claims audit_experiment.sh (searched the plugin cache, Claude/Codex skills, and ${repo:-the repo}/plugins; install verify-claims or set AUDIT_EXPERIMENT)"
  echo "$hit"
}

check_author(){  # cross-family: claude|codex; the Codex->Claude reverse reviewer isn't wired yet
  case "$1" in
    claude) ;;
    codex)  [ -n "${AUDIT_VERIFIER_CMD:-}" ] || die "author=codex needs a Claude reviewer (AUDIT_VERIFIER_CMD); the Codex->Claude reverse path is a tracked follow-up, not yet wired. Ship Claude-authored changes for now." ;;
    *) die "author must be 'claude' or 'codex' (got '$1')" ;;
  esac
}

wt_branch(){ git -C "$1" rev-parse --abbrev-ref HEAD; }                       # branch of a worktree
# the INTEGRATION BASE: prefer origin/main (the true base the PR merges onto) over local main, which can go
# stale after a rebase-onto-newer-origin/main. Used consistently for PATHS, review diffs, and the version base
# so they never disagree. Falls back to local main if there's no origin/main remote-tracking ref.
base_ref(){ git -C "$1" rev-parse --verify -q origin/main >/dev/null 2>&1 && echo origin/main || echo main; }
# the reviewed + merged content must be the COMMITTED content: refuse to act on a dirty tree (uncommitted or
# untracked changes would make checks/review see content that isn't what merges, and --force removal would
# then destroy it).
require_clean(){ [ -z "$(git -C "$1" status --porcelain)" ] || die "worktree $1 has uncommitted/untracked changes — commit or discard them first (reviewed+merged content must be the committed content)"; }
# every post-open review/finish subcommand REQUIRES a PR (the durable record); a failed lookup is fatal, never silent.
wt_pr_required(){ local pr; pr=$(wt_pr "$1"); [ -n "$pr" ] || die "no PR found for branch $(wt_branch "$1") — run 'wf.sh open $1' first (or PR lookup/auth failed)"; echo "$pr"; }
# repo slug + main checkout, derived FROM a worktree dir (any worktree shares origin + the main checkout):
gh_repo(){      git -C "${1:-$ORIGIN_REPO}" remote get-url origin | sed -E 's#(git@github.com:|https://github.com/)##; s#\.git$##'; }
main_checkout(){ git -C "$1" worktree list --porcelain | awk '/^worktree /{print $2; exit}'; }   # 1st worktree = main
wt_pr(){        gh -R "$(gh_repo "$1")" pr view "$(wt_branch "$1")" --json number -q .number 2>/dev/null; }  # PR# for a worktree's branch

# --- fail-closed review verdict ------------------------------------------------------------------
require_valid_review(){ grep -qE '^SUMMARY: high=[0-9]+ med=[0-9]+ low=[0-9]+' "$1" \
  || die "review output malformed/incomplete (no valid 'SUMMARY: high=.. med=.. low=..') — failing CLOSED. See $1"; }
sum_line(){ grep -E '^SUMMARY:' "$1" | tail -1; }
count_high(){ sum_line "$1" | sed -E 's/.*high=([0-9]+).*/\1/'; }
count_all(){ local s; s=$(sum_line "$1"); echo $(( $(sed -E 's/.*high=([0-9]+).*/\1/'<<<"$s") + $(sed -E 's/.*med=([0-9]+).*/\1/'<<<"$s") + $(sed -E 's/.*low=([0-9]+).*/\1/'<<<"$s") )); }

# resolve a fresh token for the REVIEWER identity (a different identity than the author's GH_TOKEN), used to
# post a NATIVE cross-family review. WF_REVIEWER_TOKEN_CMD prints the token (a GitHub App installation token —
# minted fresh because they expire ~1h — or `echo <PAT>`). Empty when unset -> comment fallback (shadow). A
# configured-but-FAILING command is fail-closed (never silently drop to an unsigned comment when enforcement
# is expected). The reviewer is the opposite family from the author; today only author=claude -> codex is
# wired (author=codex is blocked upstream), so the single cmd is the codex reviewer identity.
reviewer_token(){
  [ -n "${WF_REVIEWER_TOKEN_CMD:-}" ] || { echo ""; return 0; }
  local t; t=$(eval "$WF_REVIEWER_TOKEN_CMD") || die "WF_REVIEWER_TOKEN_CMD failed — can't get the reviewer-identity token (failing closed)"
  [ -n "$t" ] || die "WF_REVIEWER_TOKEN_CMD produced an empty token (failing closed)"
  echo "$t"
}

# run a cross-family review (mode = --scaffold|--code) on TARGET, write REV, post it to the PR.
# Sets the globals REVIEW_HIGH / REVIEW_ALL (NOT via $(...) — so a fail-closed `die` here hard-stops the
# whole script, instead of being swallowed by a command-substitution subshell).
# `approving=1` (passed ONLY by finish's merge-gate review) lets a clean --code review post a native APPROVE;
# every other call posts request-changes (HIGH>0) / a comment (clean interim) — never an approval, so an early
# review can't satisfy branch protection before finish's checks + final-SHA review have run.
run_review(){  # run_review <mode> <worktree> <author> <target> <pr> <heading> [approving]
  local mode=$1 wt=$2 author=$3 target=$4 pr=$5 heading=$6 approving=${7:-0}
  local audit rev; audit=$(locate_audit "$wt")
  rev="${TMPDIR:-/tmp}/wf_${mode#--}_$(wt_branch "$wt" | tr '/' '_').md"
  note "$mode review (author=$author, reviewer=opposite family)…"
  AAR_SUBSTRATE="$author" AUDIT_CONSTITUTION="${AUDIT_CONSTITUTION:-$wt/AGENTS.md}" \
    bash "$audit" "$mode" "$target" "$wt" "$rev" >/dev/null 2>"$rev.run.log" \
    || { echo "BLOCKED: reviewer process failed — tail of log:" >&2; tail -8 "$rev.run.log" >&2; exit 1; }
  require_valid_review "$rev"
  REVIEW_HIGH=$(count_high "$rev"); REVIEW_ALL=$(count_all "$rev")
  note "$mode verdict: $REVIEW_ALL finding(s), $REVIEW_HIGH HIGH -> $rev"
  [ -n "$pr" ] || { note "no PR yet — $mode review NOT posted (verdict above; $rev)"; return 0; }
  local repo body; repo=$(gh_repo "$wt")
  body=$(printf '## %s\n\n_Cross-family `%s` review — author `%s`, reviewer = opposite family._\n\n```\n%s\n```\n' "$heading" "$mode" "$author" "$(cat "$rev")")
  # NATIVE review via the reviewer identity — ONLY for --code AND author=claude (the single reviewer token is
  # the CODEX identity, which may only review CLAUDE-authored work; codex-authored would be same-family, so it
  # falls through to a comment). --scaffold/other modes = comment.
  local rtok=""; { [ "$mode" = --code ] && [ "$author" = claude ]; } && rtok=$(reviewer_token)
  if [ -n "$rtok" ]; then
    local event sha; sha=$(git -C "$wt" rev-parse HEAD)
    if [ "$approving" = 1 ] && [ "$REVIEW_HIGH" = 0 ]; then event=APPROVE              # finish gate, clean -> APPROVE
    elif [ "$REVIEW_HIGH" != 0 ]; then event=REQUEST_CHANGES                           # any blocking finding
    else event=COMMENT; fi                                                             # clean interim -> comment, not approve
    # Bind the review to the EXACT reviewed SHA via commit_id (F1): if the head advanced since we checked it,
    # the approval is for the OLD sha -> won't satisfy branch protection on the new head -> merge blocked (safe).
    # GitHub also rejects self-approval; reviewer identity == author errors here -> we fail closed (loud).
    GH_TOKEN="$rtok" gh api -X POST "repos/$repo/pulls/$pr/reviews" \
        -f commit_id="$sha" -f event="$event" -f body="$body" >/dev/null \
      || die "could not post the native $event review (commit $sha) to PR #$pr as the reviewer identity — failing closed (verdict: $REVIEW_ALL findings, $REVIEW_HIGH HIGH; see $rev)"
    note "posted NATIVE review ($event @ ${sha:0:8}) to PR #$pr as the reviewer identity"
  else
    echo "$body" | gh -R "$repo" pr comment "$pr" --body-file - >/dev/null \
      || die "could not post the $mode review comment to PR #$pr — failing closed (verdict: $REVIEW_ALL findings, $REVIEW_HIGH HIGH; see $rev)"
    note "posted $mode review COMMENT to PR #$pr"
  fi
}

# =================================================================================================
CMD=${1:-}; shift || true
case "$CMD" in

help|-h|--help|"")  usage; exit 0 ;;

start)  # wf.sh start <issue#> <slug>
  ISSUE=${1:?usage: wf.sh start <issue#> <slug>}; SLUG=${2:?slug (kebab-case)}
  [ "$(git -C "$ORIGIN_REPO" rev-parse --abbrev-ref HEAD)" = main ] || die "$ORIGIN_REPO is not on 'main' (base must be main)"
  # fail CLOSED on a stale base: every later gate assumes main...HEAD is THE integration diff, so main must be
  # current with the remote before we branch from it. (Pass WF_OFFLINE=1 to skip — e.g. a deliberate offline run.)
  if [ "${WF_OFFLINE:-}" != 1 ]; then
    git -C "$ORIGIN_REPO" fetch -q origin || die "git fetch origin failed — can't confirm main is current (set WF_OFFLINE=1 to override)"
    git -C "$ORIGIN_REPO" pull --ff-only -q origin main 2>/dev/null || true   # catch up if simply behind
    # require EXACT equality with origin/main: if local main is AHEAD (unpublished commits) those would ride
    # into the PR while `main...HEAD` reviews/checks omit them; if behind/diverged the base is stale.
    [ "$(git -C "$ORIGIN_REPO" rev-parse main)" = "$(git -C "$ORIGIN_REPO" rev-parse origin/main)" ] \
      || die "local main != origin/main (unpublished/diverged commits) — reconcile main with origin before starting; otherwise unreviewed main commits would merge through this PR"
  fi
  BR="change/${ISSUE}-${SLUG}"; WT="${WF_WORKTREE_ROOT:-/tmp}/wf-${ISSUE}-${SLUG}"
  [ -e "$WT" ] && die "worktree path already exists: $WT (finish or remove the prior run first)"
  git -C "$ORIGIN_REPO" worktree add -q "$WT" -b "$BR" main || die "could not create worktree/branch $BR"
  DOC="proposals/${ISSUE}-${SLUG}.md"
  if [ ! -f "$WT/$DOC" ]; then
    mkdir -p "$WT/proposals"
    cat > "$WT/$DOC" <<EOF
# Proposal: <title> (#${ISSUE})

> The canonical design doc (ADR + PR description). Reviewed by \`--scaffold\` before build. Lands on main.

## Problem

<what's broken / missing, concretely>

## Approach

<the design — the lifecycle/change, the load-bearing decisions>

## Alternatives considered

<what else, why rejected>

## Blast radius

<what this touches; product vs SWE pipeline vs instance>

## Rollout + rollback

<for risky changes: staged rollout, escape hatch, how to revert>
EOF
    note "scaffolded design-doc skeleton: $DOC"
  fi
  echo "WORKTREE=$WT"; echo "BRANCH=$BR"; echo "DOC=$DOC"
  note "next: write the design doc at $WT/$DOC, then: wf.sh open $WT"
  ;;

open)   # wf.sh open <worktree>   — commit the design doc, push, open the DRAFT PR
  need_gh; WT=${1:?usage: wf.sh open <worktree>}
  [ -d "$WT" ] || die "no such worktree: $WT"
  BR=$(wt_branch "$WT")
  DOC=$(cd "$WT" && git status --porcelain proposals/ | sed 's/^...//' | head -1)
  [ -n "$DOC" ] || DOC=$(cd "$WT" && git diff --name-only "$(base_ref "$WT")"...HEAD -- proposals/ | head -1)
  [ -n "$DOC" ] || die "no design doc under proposals/ found (write proposals/<issue>-<slug>.md first)"
  ISSUE=$(basename "$DOC" | sed -E 's/^([0-9]+)-.*/\1/')
  # attribution comes from the committer's git identity + the PR — don't hardcode an author family here
  # (this is product code; a Codex- or other-authored change must not get a Claude trailer).
  # Commit ONLY the doc: the `-- "$DOC"` pathspec on commit means a pre-staged unrelated file can't ride in.
  ( cd "$WT" && git add -- "$DOC" && git commit -q -m "design: $(basename "$DOC" .md) (#${ISSUE})

Namespaced design doc for the scaffold change. Reviewed by --scaffold next." -- "$DOC" )
  ( cd "$WT" && git push -q -u origin "$BR" ) || die "push failed"
  PRURL=$(gh -R "$(gh_repo "$WT")" pr create --draft --base main --head "$BR" \
    --title "$(grep -m1 '^# ' "$WT/$DOC" | sed 's/^# Proposal: //; s/^# //')" \
    --body "Closes #${ISSUE}. Design doc: \`$DOC\` (on this branch; lands on main at merge).

Lifecycle (shadow mode): draft PR -> --scaffold design review -> implement -> --code review -> classifier (recorded) -> checks -> merge-when-clean. Reviews are posted as comments by the workflow driver.") \
    || die "gh pr create failed"
  PR=$(basename "$PRURL")
  echo "PR=$PR"; note "draft PR #$PR opened: $PRURL"; note "next: wf.sh design-review $WT <author>"
  ;;

design-review)  # wf.sh design-review <worktree> <author>
  need_gh; WT=${1:?usage: wf.sh design-review <worktree> <author>}; AUTHOR=${2:?author: claude|codex}
  check_author "$AUTHOR"; [ -d "$WT" ] || die "no such worktree: $WT"
  require_clean "$WT"; PR=$(wt_pr_required "$WT")
  DOC=$(cd "$WT" && git diff --name-only "$(base_ref "$WT")"...HEAD -- proposals/ | head -1)
  [ -n "$DOC" ] || die "no committed design doc under proposals/ (run: wf.sh open $WT)"
  # push so the reviewed doc == what the PR shows (consistency with code-review)
  ( cd "$WT" && git push -q origin HEAD ) || die "push failed — can't review a doc the PR doesn't reflect"
  run_review --scaffold "$WT" "$AUTHOR" "$WT/$DOC" "$PR" "Design review (\`--scaffold\`)"
  note "design-review done (HIGH=$REVIEW_HIGH). Revise the doc for findings; the PM's design approval is the human gate (shadow: recorded). Then implement + commit, and: wf.sh code-review $WT $AUTHOR"
  ;;

code-review)    # wf.sh code-review <worktree> <author>
  need_gh; WT=${1:?usage: wf.sh code-review <worktree> <author>}; AUTHOR=${2:?author: claude|codex}
  check_author "$AUTHOR"; [ -d "$WT" ] || die "no such worktree: $WT"
  require_clean "$WT"; PR=$(wt_pr_required "$WT")
  # push first so the PR (what the human + reviewer see) reflects the reviewed commits — no local/remote gap
  ( cd "$WT" && git push -q origin HEAD ) || die "push failed — can't review a diff the PR doesn't reflect"
  DIFF="${TMPDIR:-/tmp}/wf_code_$(wt_branch "$WT" | tr '/' '_').diff"
  ( cd "$WT" && git diff "$(base_ref "$WT")"...HEAD ) > "$DIFF"
  [ -s "$DIFF" ] || die "empty diff main...$(wt_branch "$WT") — implement + commit the change first"
  run_review --code "$WT" "$AUTHOR" "$DIFF" "$PR" "Code review (\`--code\`)"
  note "code-review done (HIGH=$REVIEW_HIGH). Triage findings (fix in $WT + commit, or respond on the PR). Then: wf.sh classify $WT ; wf.sh finish $WT $AUTHOR"
  ;;

classify)       # wf.sh classify <worktree>   — shadow-mode record (never blocks)
  need_gh; WT=${1:?usage: wf.sh classify <worktree>}
  [ -d "$WT" ] || die "no such worktree: $WT"
  [ -x "$WT/.aar-ci/classify.sh" ] || die "no classifier at $WT/.aar-ci/classify.sh (is this the aar-skills repo?)"
  require_clean "$WT"
  mapfile -t PATHS < <(cd "$WT" && git diff --name-only "$(base_ref "$WT")"...HEAD)
  [ ${#PATHS[@]} -gt 0 ] || die "no changed paths main...HEAD"
  OUT=$( cd "$WT" && .aar-ci/classify.sh "${PATHS[@]}" )
  CLASS=$(echo "$OUT" | sed -nE 's/^CLASSIFICATION: //p' | head -1)
  PR=$(wt_pr_required "$WT")
  if [ -n "$PR" ]; then
    { echo "## Change classification (shadow mode — recorded, not enforced)"; echo;
      echo "**$CLASS** — architectural changes need the PM's design approval; mechanical merge on the cross-family review + checks alone. (Phase 1: recorded only; Phase 2 wires this to a required \`design-gate\` check.)"; echo;
      echo '```'; echo "$OUT"; echo '```'; } | gh -R "$(gh_repo "$WT")" pr comment "$PR" --body-file - >/dev/null \
      || die "could not post the classification to PR #$PR — the shadow-mode record is the point; failing closed (classification was: $CLASS)"
    note "posted classification to PR #$PR"
  fi
  echo "$OUT"
  ;;

finish) # wf.sh finish <worktree> <author>   — checks + fail-closed --code gate + ready + merge + cleanup
  need_gh; WT=${1:?usage: wf.sh finish <worktree> <author>}; AUTHOR=${2:?author: claude|codex}
  check_author "$AUTHOR"; [ -d "$WT" ] || die "no such worktree: $WT"
  require_clean "$WT"   # everything must be committed: reviewed == checked == merged, and nothing lost on --force removal
  REPO=$(gh_repo "$WT"); MAIN_CO=$(main_checkout "$WT")
  BR=$(wt_branch "$WT"); PR=$(wt_pr_required "$WT")
  mapfile -t PATHS < <(cd "$WT" && git diff --name-only "$(base_ref "$WT")"...HEAD)
  [ ${#PATHS[@]} -gt 0 ] || die "no changed paths main...HEAD — nothing to merge"
  # 0a. BASE FRESHNESS: origin/main may have ADVANCED since `start` (a peer PR merged). The merge would land
  #     on that newer main, but checks/review run against this branch's base — so the integrated tree that
  #     actually lands was never checked. Block unless the branch is rebased onto current origin/main (the
  #     agent: `cd $WT && git rebase origin/main`, then re-run code-review, then finish). WF_OFFLINE=1 skips.
  if [ "${WF_OFFLINE:-}" != 1 ]; then
    git -C "$WT" fetch -q origin main || die "git fetch origin failed — can't confirm the merge base is current (WF_OFFLINE=1 to override)"
    BASE=$(git -C "$WT" merge-base HEAD origin/main); OMAIN=$(git -C "$WT" rev-parse origin/main)
    [ "$BASE" = "$OMAIN" ] || die "origin/main advanced since this branch started — the merge would land on newer main than was checked. Integrate + re-review: (cd $WT && git rebase origin/main) then re-run code-review, then finish."
  fi
  # 0b. SYNC: push the worktree so the PR head == the LOCAL HEAD we're about to review (F1). Otherwise we'd
  #    review the local diff but merge a different remote head, then delete the reviewed worktree.
  ( cd "$WT" && git push -q origin HEAD ) || die "push failed — refusing to merge a PR that may not match the reviewed diff"
  LOCAL_SHA=$(git -C "$WT" rev-parse HEAD)
  REMOTE_SHA=$(gh -R "$REPO" pr view "$PR" --json headRefOid -q .headRefOid)
  [ "$LOCAL_SHA" = "$REMOTE_SHA" ] || die "PR #$PR head ($REMOTE_SHA) != local HEAD ($LOCAL_SHA) — the reviewed diff is not what would merge. Resolve (re-push / reconcile) before finishing."
  # 1. deterministic checks + behavior smoke, on the BRANCH's actual content (the worktree)
  [ -f "$WT/.aar-ci/checks.sh" ] || die "repo has no tracked check profile ($WT/.aar-ci/checks.sh)"
  note "running .aar-ci checks + smoke on branch content…"
  ( cd "$WT" && bash .aar-ci/checks.sh "${PATHS[@]}" ) || die "deterministic checks/behavior-smoke FAILED — fix before merging"
  # 2. the authoritative merge gate: re-run --code on the FINAL diff, fail-closed, NO HIGH
  DIFF="${TMPDIR:-/tmp}/wf_finish_${BR//\//_}.diff"
  ( cd "$WT" && git diff "$(base_ref "$WT")"...HEAD ) > "$DIFF"
  run_review --code "$WT" "$AUTHOR" "$DIFF" "$PR" "Final code review (merge gate)" 1   # approving=1: clean -> native APPROVE
  [ "$REVIEW_HIGH" = 0 ] || die "merge gate: $REVIEW_HIGH HIGH finding(s) remain — NOT merging. Fix in $WT + commit, then re-run finish."
  # 3. merge the EXACT reviewed SHA (--match-head-commit aborts if the head moved since we synced) — shadow
  #    mode: agent merge after the gate; branch protection not required yet.
  note "gate clean (no HIGH) + checks passed -> marking ready + merging PR #$PR @ $LOCAL_SHA"
  gh -R "$REPO" pr ready "$PR" >/dev/null 2>&1 || true
  gh -R "$REPO" pr merge "$PR" --squash --delete-branch --match-head-commit "$LOCAL_SHA" || die "merge failed (head may have moved since review — re-run finish)"
  # 4. cleanup: remove the worktree (derive the main checkout FROM the worktree), sync main
  git -C "$MAIN_CO" worktree remove --force "$WT" 2>/dev/null || true
  git -C "$MAIN_CO" pull --ff-only -q origin main 2>/dev/null || note "WARN: could not ff-only pull main ($MAIN_CO) — reconcile manually"
  local_manifest=0; for p in "${PATHS[@]}"; do case "$p" in */plugin.json|*marketplace.json) local_manifest=1;; esac; done
  [ "$local_manifest" = 1 ] && note "a plugin manifest changed — refresh installs: claude plugin marketplace update aar-skills && claude plugin update <name>@aar-skills"
  echo "SHIPPED: PR #$PR merged (shadow mode — clean cross-family review + checks). Worktree cleaned."
  ;;

*) echo "BLOCKED: unknown subcommand '${CMD:-}'." >&2; echo >&2; usage >&2; exit 1 ;;
esac
