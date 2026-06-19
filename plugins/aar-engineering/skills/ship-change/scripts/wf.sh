#!/bin/bash
# wf.sh — the GitHub-backed scaffold-change workflow driver (SWE pipeline, ENFORCED).
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
# ENFORCED: the cross-family --code review can be posted as a NATIVE opposite-family engineer review, and branch
# protection on `main` can REQUIRE that opposite-family approval (+ no force-push/deletion, include-admins so the
# admin author token can't bypass) before any merge. wf.sh's own fail-closed gate (checks + final-SHA review,
# no HIGH) runs first; `gh pr merge` then succeeds only when the required approval is present.
# STILL ADVISORY: the classifier's architectural/mechanical classification is RECORDED on the PR (the human
# reads it), not yet wired to a required `design-gate` check — so the design/architectural approval is the
# human's judgment, recorded, not mechanically blocking. See RUNBOOK.md for the as-built config + escape hatches.
#
# Usage: run `wf.sh help` (or `-h` / no args) for the lifecycle short-list; SKILL.md is the full runbook.
# (The command list lives in ONE place — the usage() function below — not duplicated here.)
#
# Auth: authenticate gh (gh auth login) OR export GH_TOKEN — wf.sh sources NO env file itself.
#      WF_ENGINEER_TOKEN_CMD_CLAUDE / _CODEX print GitHub tokens for engineer identities.
#      WF_ENGINEER_GIT_AUTHOR_CLAUDE / _CODEX are "Name <email>" strings for strict open commits.
#      WF_REVIEWER_TOKEN_CMD remains a legacy alias for WF_ENGINEER_TOKEN_CMD_CODEX.
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
wf.sh — the GitHub-backed scaffold-change workflow driver (SWE pipeline, enforced).

Lifecycle (the agent does the judgment steps BETWEEN these):
  wf.sh start  <issue#> <slug>            worktree + branch + design-doc skeleton   [then: write the doc]
  wf.sh open   <worktree> [author]        commit the doc, push, open the DRAFT PR
  wf.sh design-review <worktree> <author> --scaffold on the doc, post to PR (fail-closed)
  wf.sh code-review   <worktree> <author> --code on the diff, post to PR (fail-closed)
  wf.sh comment <worktree> <author> [file] post an AUTHOR triage comment as the engineer identity (body: file|stdin)
  wf.sh issue   <author> <gh issue args…>  file/comment a GitHub Issue AS the engineer identity (no worktree)
  wf.sh classify      <worktree> [author] classifier on changed paths, post evidence (advisory record)
  wf.sh finish <worktree> <author>        checks + fail-closed --code gate + ready + merge + cleanup
  wf.sh finish <worktree> <author> --design   two-phase DESIGN merge: gate on --scaffold (doc-only PR), spawn ready issues after
  wf.sh locate-audit [repo]               print the verify-claims reviewer that would run (introspection/test)
  wf.sh help                              this message

<author> = claude | codex (the OPPOSITE family reviews). If an engineer identity is configured for that author,
open/push/PR actions use it; otherwise they warn and use ambient auth unless WF_REQUIRE_ENGINEER_IDENTITY=1.
Auth: gh auth login OR export GH_TOKEN for ambient fallback (wf.sh sources no env file).
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

need_gh(){ command -v gh >/dev/null || die "gh not on PATH"; }
need_ambient_gh(){ [ -n "${GH_TOKEN:-}" ] || gh auth status >/dev/null 2>&1 \
  || die "no GitHub auth — run 'gh auth login' or export GH_TOKEN before invoking; wf.sh sources no env file"; }

# Materialize a repo's verify-claims reviewer from its BASE ref into a content cache; echo the cached
# audit_experiment.sh path on success. "Trusted-but-current": read from the repo's own main (origin/main, then
# local main) — CURRENT (matches what merges, not a stale version-keyed install cache) yet TRUSTED (the base,
# never the branch under review, so a PR that edits verify-claims' own reviewer can't run that modified reviewer
# as its merge gate). For any PR that does NOT touch verify-claims, base content == the worktree's, so this only
# ever differs by being safe. The WHOLE skill dir is materialized (SKILL.md + scripts/ + references/…), the
# canonical Agent Skill unit, so a reviewer that reads a relative resource still finds it. Cached under the
# repo's git-common-dir (shared across worktrees, never in the worktree's tracked state) keyed by the base
# commit, so repeated calls + review phases reuse one extraction.
#   rc 0 + path  = resolved;  rc 0 + no output = no verify-claims at this base (legitimate fall-through);
#   rc 2         = the base ref could not be safely inspected (present but unresolvable, or ls-tree failed), OR
#                  verify-claims IS present but extraction failed -> caller FAILS CLOSED (never silently
#                  downgrade a merge-gate reviewer to a stale installed copy).
audit_from_base_ref(){  # audit_from_base_ref <repo>
  local repo=$1 base tree relp skilldir cdir tgt tmp
  [ -n "$repo" ] || return 0
  command -v git >/dev/null 2>&1 || return 0                 # no git -> can't determine a base ref at all -> fall through
  # Resolve the base: origin/main (the canonical integration base) then local main. `rev-parse --verify -q`
  # returns a ref's SHA even when its object is MISSING/corrupt, and only "fails" (empty) when the ref is
  # genuinely ABSENT. So this falls back to local main ONLY when origin/main is absent (the legitimate
  # no-remote-tracking-ref case) — a present-but-corrupt origin/main yields its own (dangling) SHA and is NOT
  # masked by a stale local main. An empty result means neither ref exists -> no base here -> fall through.
  base=$(git -C "$repo" rev-parse --verify -q refs/remotes/origin/main \
      || git -C "$repo" rev-parse --verify -q refs/heads/main || true)
  [ -n "$base" ] || return 0
  # Capture ls-tree separately from grep, keyed on its exit status: the base ref already exists (rev-parse
  # --verify above), so a FAILED enumeration (corrupt/partial clone) is an error, not "nothing here" — fail
  # closed (rc 2) rather than letting an empty result masquerade as "no verify-claims" and fall through to a
  # stale install. A clean enumeration with no match keeps the legitimate rc-0 fall-through.
  tree=$(git -C "$repo" ls-tree -r --name-only "$base" 2>/dev/null) || return 2
  relp=$(printf '%s\n' "$tree" | grep -m1 -E 'verify-claims.*/scripts/audit_experiment\.sh$' || true)
  [ -n "$relp" ] || return 0                                 # no verify-claims at this base -> legitimate fall-through
  # verify-claims IS present at base from here on -> any inability to extract is fail-closed (rc 2), never a
  # silent fall-through to a stale installed reviewer. tar is checked here (not up top) so a missing tar with
  # verify-claims present fails closed rather than masquerading as "not found".
  command -v tar >/dev/null 2>&1 || return 2
  skilldir=${relp%/scripts/audit_experiment.sh}             # the verify-claims SKILL dir, in-tree path
  cdir=$(git -C "$repo" rev-parse --git-common-dir 2>/dev/null) || return 2
  case "$cdir" in /*) ;; *) cdir="$repo/$cdir" ;; esac       # --git-common-dir may be relative to repo
  tgt="$cdir/aar-ship-verify/$base"
  if [ ! -f "$tgt/$skilldir/scripts/audit_experiment.sh" ]; then
    tmp=$(mktemp -d "$cdir/aar-ship-verify.XXXXXX" 2>/dev/null) || return 2
    if git -C "$repo" archive "$base" -- "$skilldir" 2>/dev/null | tar -x -C "$tmp" 2>/dev/null; then
      mkdir -p "$(dirname "$tgt")" 2>/dev/null || true
      mv -T "$tmp" "$tgt" 2>/dev/null || rm -rf "$tmp"       # lost a concurrent race / already built: drop ours
    else
      rm -rf "$tmp"; return 2                                # present at base but archive/tar failed -> fail closed
    fi
  fi
  [ -f "$tgt/$skilldir/scripts/audit_experiment.sh" ] || return 2
  echo "$tgt/$skilldir/scripts/audit_experiment.sh"
}

locate_audit(){  # locate_audit [context-repo-dir]
  if [ -n "${AUDIT_EXPERIMENT:-}" ] && [ -f "$AUDIT_EXPERIMENT" ]; then echo "$AUDIT_EXPERIMENT"; return; fi
  local repo=${1:-} hit="" src out rc tried=""
  # 1. TRUSTED-BUT-CURRENT (#69, see audit_from_base_ref): verify-claims at the BASE ref of the context repo,
  #    then of wf.sh's OWN source repo when the context repo carries none in-tree (so a cross-repo ship-change
  #    still reviews against current product source, not a stale install). Current source, never the reviewed
  #    branch. FAILS CLOSED (rc 2) if a base ref HAS verify-claims but it can't be extracted — never a silent
  #    downgrade to the stale installed copy.
  for src in "$repo" "$SELF_REPO"; do
    [ -n "$hit" ] && break
    [ -n "$src" ] || continue
    case " $tried " in *" $src "*) continue ;; esac; tried="$tried $src"
    if out=$(audit_from_base_ref "$src"); then rc=0; else rc=$?; fi
    case "$rc" in
      0) [ -n "$out" ] && hit="$out" ;;
      *) die "could not safely resolve verify-claims from $src's base ref (rc=$rc: the base ref couldn't be inspected, or verify-claims is present but extraction failed) — failing closed rather than silently using a stale installed reviewer; set AUDIT_EXPERIMENT to override" ;;
    esac
  done
  # 2. fallback: installed reviewer, highest version — Claude plugin cache AND Claude/Codex skill installs
  #    (symlink or copy). Only reached when NO trusted base-ref source carries verify-claims (a repo-less
  #    invocation with no source repo, or repos with none in-tree). `|| true` is load-bearing under
  #    `set -euo pipefail`: a missing search dir makes find exit non-zero and would abort the assignment.
  [ -n "$hit" ] || hit=$(find "$HOME/.claude/plugins/cache" "$HOME/.claude/skills" "$HOME/.codex/skills" \
        -path '*verify-claims*scripts/audit_experiment.sh' 2>/dev/null | sort -V | tail -1 || true)
  [ -n "$hit" ] || die "cannot locate verify-claims audit_experiment.sh (searched the base refs of ${repo:+the context repo and }wf.sh's source repo, the plugin cache, and Claude/Codex skills; install verify-claims or set AUDIT_EXPERIMENT)"
  echo "$hit"
}

check_author(){
  case "$1" in
    claude|codex) ;;
    *) die "author must be 'claude' or 'codex' (got '$1')" ;;
  esac
}

require_model_reviewer(){
  [ "$1" != codex ] || [ -n "${AUDIT_VERIFIER_CMD:-}" ] \
    || die "author=codex needs a Claude model-family reviewer for --scaffold/--code (set AUDIT_VERIFIER_CMD, e.g. claude -p ... > \"\\$OUT_TMP\")"
}

family_suffix(){
  case "$1" in
    claude) echo CLAUDE ;;
    codex) echo CODEX ;;
    *) die "unknown engineer family '$1'" ;;
  esac
}

opposite_family(){
  case "$1" in
    claude) echo codex ;;
    codex) echo claude ;;
    *) die "unknown author family '$1'" ;;
  esac
}

engineer_token_cmd(){
  local fam=$1 suffix var cmd
  suffix=$(family_suffix "$fam"); var="WF_ENGINEER_TOKEN_CMD_$suffix"
  cmd="${!var:-}"
  # Back-compat: the original single reviewer seam minted the Codex engineer token.
  if [ -z "$cmd" ] && [ "$fam" = codex ]; then cmd="${WF_REVIEWER_TOKEN_CMD:-}"; fi
  echo "$cmd"
}

engineer_token(){  # engineer_token <family> <required:0|1>
  local fam=$1 required=${2:-0} cmd t suffix
  suffix=$(family_suffix "$fam"); cmd=$(engineer_token_cmd "$fam")
  if [ -z "$cmd" ]; then
    if [ "$required" = 1 ]; then
      if [ "$fam" = codex ]; then
        die "missing WF_ENGINEER_TOKEN_CMD_CODEX (or legacy WF_REVIEWER_TOKEN_CMD)"
      else
        die "missing WF_ENGINEER_TOKEN_CMD_$suffix"
      fi
    fi
    echo ""; return 0
  fi
  t=$(eval "$cmd") || die "WF_ENGINEER_TOKEN_CMD_$suffix failed — can't get the $fam engineer token (failing closed)"
  [ -n "$t" ] || die "WF_ENGINEER_TOKEN_CMD_$suffix produced an empty token (failing closed)"
  echo "$t"
}

engineer_git_author(){
  local fam=$1 required=${2:-0} suffix var val
  suffix=$(family_suffix "$fam"); var="WF_ENGINEER_GIT_AUTHOR_$suffix"; val="${!var:-}"
  if [ -z "$val" ]; then
    [ "$required" = 1 ] && die "missing WF_ENGINEER_GIT_AUTHOR_$suffix (expected: Name <email>)"
    echo ""; return 0
  fi
  [ -n "$(git_author_name "$val")" ] && [ -n "$(git_author_email "$val")" ] \
    || die "WF_ENGINEER_GIT_AUTHOR_$suffix must look like: Name <email>"
  echo "$val"
}

git_author_name(){ sed -E 's/[[:space:]]*<[^>]+>[[:space:]]*$//' <<<"$1"; }
git_author_email(){ sed -nE 's/.*<([^>]+)>.*/\1/p' <<<"$1"; }

section_text(){  # section_text <markdown-file> <section-name-without-##>
  local file=$1 name=$2
  awk -v name="$name" '
    {
      line=$0
      sub(/[[:space:]]+$/, "", line)
    }
    line == "## " name { found=1; next }
    found && /^## / { exit }
    found { print }
  ' "$file" || true
}

first_paragraph(){  # first_paragraph <text>
  awk '
    /^[[:space:]]*$/ { if (seen) exit; next }
    { seen=1; print }
  ' <<<"${1:-}" || true
}

markdown_details(){  # markdown_details <summary> <body>
  local summary=$1 body=${2:-}
  printf '<details>\n<summary>%s</summary>\n\n%s\n\n</details>\n' "$summary" "$body"
}

markdown_code_details(){  # markdown_code_details <summary> <body>
  local summary=$1 body=${2:-} fence_len fence
  fence_len=$(awk '
    {
      line=$0
      while (match(line, /`+/)) {
        if (RLENGTH > max) max=RLENGTH
        line=substr(line, RSTART + RLENGTH)
      }
    }
    END {
      if (max < 3) max=3
      print max + 1
    }
  ' <<<"$body" || true)
  : "${fence_len:=4}"
  printf -v fence '%*s' "$fence_len" ''
  fence=${fence// /\`}
  printf '<details>\n<summary>%s</summary>\n\n%stext\n%s\n%s\n\n</details>\n' "$summary" "$fence" "$body" "$fence"
}

review_summary_text(){  # review_summary_text <high> <med> <low> <approving:0|1>
  local high=$1 med=$2 low=$3 approving=${4:-0}
  if [ "$high" -gt 0 ]; then
    printf 'This review found %s serious issue(s). Fix them or clearly explain why they are not real before this PR moves forward.' "$high"
  elif [ "$approving" = 1 ] && [ "$med" -gt 0 ]; then
    printf 'Final review approved this PR. It found %s non-blocking issue(s), recorded below for the author and human reader.' "$med"
  elif [ "$approving" = 1 ] && [ "$low" -gt 0 ]; then
    printf 'Final review approved this PR. It found only minor notes, recorded below for the author and human reader.'
  elif [ "$med" -gt 0 ]; then
    printf 'This review found %s issue(s) that should be fixed or answered before merging.' "$med"
  elif [ "$low" -gt 0 ]; then
    printf 'This review found only minor notes. The PR can continue after the author records what they did with them.'
  elif [ "$approving" = 1 ]; then
    printf 'Final review approved this PR. It found no problems.'
  else
    printf 'This review found no problems.'
  fi
}

classification_summary_text(){  # classification_summary_text <classification>
  local class=$1
  case "$class" in
    architectural)
      printf 'This PR touches a high-impact part of the scaffold. A human design approval is expected before treating it as routine. The detailed rule that matched is below.'
      ;;
    mechanical)
      printf 'This PR looks mechanical. It can merge on the normal review and checks if no serious issues remain.'
      ;;
    *)
      printf 'This PR was classified as %s. The detailed classifier output is below.' "$class"
      ;;
  esac
}

author_token_optional(){
  local author=$1 tok
  tok=$(engineer_token "$author" 0)
  if [ -z "$tok" ]; then
    [ "${WF_REQUIRE_ENGINEER_IDENTITY:-}" = 1 ] && die "missing engineer token for author=$author and WF_REQUIRE_ENGINEER_IDENTITY=1"
    note "WARN: no engineer token configured for author=$author; using ambient GitHub auth"
  fi
  echo "$tok"
}

gh_author(){  # gh_author <author-token-or-empty> <gh args...>
  local tok=$1; shift
  if [ -n "$tok" ]; then GH_TOKEN="$tok" gh "$@"; else gh "$@"; fi
}

git_push_author(){  # git_push_author <author-token-or-empty> <worktree> <args...>
  local tok=$1 wt=$2; shift 2
  if [ -n "$tok" ]; then GH_TOKEN="$tok" git -C "$wt" push "$@"; else git -C "$wt" push "$@"; fi
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
wt_pr_required(){ local pr; pr=$(wt_pr "$1" "${2:-}"); [ -n "$pr" ] || die "no PR found for branch $(wt_branch "$1") — run 'wf.sh open $1' first (or PR lookup/auth failed)"; echo "$pr"; }
# repo slug + main checkout, derived FROM a worktree dir (any worktree shares origin + the main checkout):
gh_repo(){      git -C "${1:-$ORIGIN_REPO}" remote get-url origin | sed -E 's#(git@github.com:|https://github.com/)##; s#\.git$##'; }
main_checkout(){ git -C "$1" worktree list --porcelain | awk '/^worktree /{print $2; exit}'; }   # 1st worktree = main
wt_pr(){
  local tok=${2:-}
  if [ -n "$tok" ]; then
    GH_TOKEN="$tok" gh -R "$(gh_repo "$1")" pr view "$(wt_branch "$1")" --json number -q .number 2>/dev/null
  else
    gh -R "$(gh_repo "$1")" pr view "$(wt_branch "$1")" --json number -q .number 2>/dev/null
  fi
}  # PR# for a worktree's branch

# render_pr_body <worktree> <doc-relpath> <issue> — the PR body as a generated VIEW of the committed
# design doc (#24): a self-describing, plain-language PR with zero duplicate authoring. The visible body
# uses the first paragraphs of Problem + Approach; the full design record stays under details. Re-rendered
# at finish so the merged record matches the landed doc.
render_pr_body(){
  local wt="$1" doc="$2" issue="$3" body problem approach visible fallback_body title
  body=$(awk 'f||/^## /{f=1}f' "$wt/$doc")
  [ -n "$body" ] || body=$(sed '1{/^# /d;}' "$wt/$doc")
  problem=$(first_paragraph "$(section_text "$wt/$doc" "Problem")")
  approach=$(first_paragraph "$(section_text "$wt/$doc" "Approach")")
  visible="$problem"
  if [ -n "$problem" ] && [ -n "$approach" ]; then visible=$(printf '%s\n\n%s' "$problem" "$approach")
  elif [ -n "$approach" ]; then visible="$approach"; fi
  fallback_body=$(sed '1{/^## /d;}' <<<"$body")
  [ -n "$visible" ] || visible=$(first_paragraph "$fallback_body")
  if [ -z "$visible" ]; then
    title=$(sed -nE 's/^# +//p' "$wt/$doc" | head -1 || true)
    visible="$title"
  fi
  printf 'Closes #%s.\n\n%s\n\n' "$issue" "$visible"
  markdown_details "Design record" "$body"
  printf '\n\nDesign record: `%s`. It lands in the repo when this PR merges.\n' "$doc"
}

# --- fail-closed review verdict ------------------------------------------------------------------
require_valid_review(){ grep -qE '^SUMMARY: high=[0-9]+ med=[0-9]+ low=[0-9]+' "$1" \
  || die "review output malformed/incomplete (no valid 'SUMMARY: high=.. med=.. low=..') — failing CLOSED. See $1"; }
sum_line(){ grep -E '^SUMMARY:' "$1" | tail -1; }
count_high(){ sum_line "$1" | sed -E 's/.*high=([0-9]+).*/\1/'; }
count_med(){ sum_line "$1" | sed -E 's/.*med=([0-9]+).*/\1/'; }
count_low(){ sum_line "$1" | sed -E 's/.*low=([0-9]+).*/\1/'; }
count_all(){ local s; s=$(sum_line "$1"); echo $(( $(sed -E 's/.*high=([0-9]+).*/\1/'<<<"$s") + $(sed -E 's/.*med=([0-9]+).*/\1/'<<<"$s") + $(sed -E 's/.*low=([0-9]+).*/\1/'<<<"$s") )); }

# resolve a fresh token for the REVIEWER identity (opposite family from the author), used to post a NATIVE
# cross-family review. Missing token config falls back to ambient comments unless a caller explicitly requires
# a native reviewer token (finish's merge gate does this when WF_REQUIRE_NATIVE_REVIEW=1); configured-but-failing
# commands always fail closed.
reviewer_token(){  # reviewer_token <author> [required:0|1]
  local author=$1 reviewer required=${2:-0}
  reviewer=$(opposite_family "$author")
  engineer_token "$reviewer" "$required"
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
  local rtok="" require_reviewer=0
  # The merge gate (approving=1, set by finish for --code AND design-mode --scaffold) must have a real
  # opposite-family reviewer when WF_REQUIRE_NATIVE_REVIEW=1 — fail early on a missing identity rather than
  # silently falling back to an ambient comment that can't satisfy branch protection. Keyed on approving=1
  # (only the merge gate passes it), so it covers both gate modes, not just --code.
  [ "$approving" = 1 ] && [ "${WF_REQUIRE_NATIVE_REVIEW:-}" = 1 ] && require_reviewer=1
  if [ -n "$pr" ]; then
    rtok=$(reviewer_token "$author" "$require_reviewer")
    [ -n "$rtok" ] || need_ambient_gh
  fi
  note "$mode review (author=$author, reviewer=opposite family)…"
  AAR_SUBSTRATE="$author" AUDIT_CONSTITUTION="${AUDIT_CONSTITUTION:-$wt/AGENTS.md}" \
    bash "$audit" "$mode" "$target" "$wt" "$rev" >/dev/null 2>"$rev.run.log" \
    || { echo "BLOCKED: reviewer process failed — tail of log:" >&2; tail -8 "$rev.run.log" >&2; exit 1; }
  require_valid_review "$rev"
  local review_med review_low
  REVIEW_HIGH=$(count_high "$rev"); review_med=$(count_med "$rev"); review_low=$(count_low "$rev"); REVIEW_ALL=$(count_all "$rev")
  note "$mode verdict: $REVIEW_ALL finding(s), $REVIEW_HIGH HIGH -> $rev"
  [ -n "$pr" ] || { note "no PR yet — $mode review NOT posted (verdict above; $rev)"; return 0; }
  local repo body review_text; repo=$(gh_repo "$wt"); review_text=$(cat "$rev")
  body=$( { printf '## %s\n\n%s\n\n' "$heading" "$(review_summary_text "$REVIEW_HIGH" "$review_med" "$review_low" "$approving")"; markdown_code_details "Full review details" "$review_text"; } )
  # The reviewer identity attributes its output to the opposite-family engineer — a NATIVE review for --code,
  # AND for --scaffold WHEN it is the merge gate (approving=1, i.e. `finish --design`) so the design approval
  # is a real native APPROVE branch protection accepts. An interim --scaffold (design-review, approving=0)
  # stays a COMMENT via the elif below. Unconfigured installs fall back to ambient comments unless
  # WF_REQUIRE_NATIVE_REVIEW=1. Advisory scaffold/classification comments still fall back when no reviewer
  # identity is configured.
  if { [ "$mode" = --code ] || { [ "$mode" = --scaffold ] && [ "$approving" = 1 ]; }; } && [ -n "$rtok" ]; then
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
  elif [ -n "$rtok" ]; then
    # --scaffold (or any non-code): a COMMENT attributed to the reviewer identity (so the design review reads
    # as the bot, not the author's token).
    echo "$body" | GH_TOKEN="$rtok" gh -R "$repo" pr comment "$pr" --body-file - >/dev/null \
      || die "could not post the $mode review comment to PR #$pr as the reviewer identity — failing closed (see $rev)"
    note "posted $mode review COMMENT to PR #$pr as the reviewer identity"
  else
    # no reviewer identity configured (unenforced fallback / unsupported direction): comment under the default token
    echo "$body" | gh -R "$repo" pr comment "$pr" --body-file - >/dev/null \
      || die "could not post the $mode review comment to PR #$pr — failing closed (see $rev)"
    note "posted $mode review COMMENT to PR #$pr (default token)"
  fi
}

# disposition_gate <wt> <author-token> <pr> <design_mode> — the two-phase CLOSE-GATE (#50/#85). Enforces the
# disposition contract on the issues a PR closes, BEFORE any native APPROVE is posted (a check after the
# approval would leave a non-conforming PR approved + manually mergeable):
#   code  (finish):          closes >=1 issue, EVERY closing issue's disposition set == {ready}
#   design (finish --design): closes EXACTLY ONE issue, its disposition set == {needs-design}
# Equality over the six-label disposition set (not "contains") fails closed on untriaged (zero) and malformed
# (multiple) — so an issue mislabelled both ready+needs-design can't sneak through. Closing issues resolved via
# GitHub's own closingIssuesReferences (Closes/Fixes + manual links). Fail closed on any lookup error. Label
# reads work under the engineer Apps' existing contents+pull_requests perms on a PUBLIC repo; a private install
# must add issues:read (RUNBOOK). WF_ALLOW_NONREADY_CLOSE=1 overrides but posts a durable PR comment.
DISPO_RE='^(ready|needs-design|needs-shaping|blocked|parked|other)$'
disposition_gate(){
  local wt=$1 tok=$2 pr=$3 design=$4 repo owner name expect closing n labels count=0 bad="" problem=""
  repo=$(gh_repo "$wt"); owner=${repo%%/*}; name=${repo#*/}
  # Override FIRST (before any lookup): the hatch must rescue a lookup/permission failure too — otherwise a
  # private install missing issues:read would fail closed on every merge with no in-band bypass. So if set, skip
  # the gate entirely. Trail = a BEST-EFFORT PR comment (the hatch must work even if GitHub is flaky) PLUS a
  # guaranteed terminal log.
  if [ "${WF_ALLOW_NONREADY_CLOSE:-0}" = 1 ]; then
    printf '⚠️ **Close-gate OVERRIDDEN** (`WF_ALLOW_NONREADY_CLOSE=1`): close-disposition checks skipped for this merge.\n' \
      | gh_author "$tok" -R "$repo" pr comment "$pr" --body-file - >/dev/null 2>&1 || true
    note "design-gate OVERRIDDEN (WF_ALLOW_NONREADY_CLOSE=1) — checks skipped (best-effort PR comment posted)"
    return 0
  fi
  [ "$design" = 1 ] && expect=needs-design || expect=ready
  # Query the first page (100, GitHub's max) + hasNextPage + each ref's repo. The --jq emits "MORE:<bool>"
  # then "<number> <owner/repo>" per closing ref, so we (a) never silently skip refs beyond the page (fail
  # closed if more exist) and (b) detect cross-repo refs. The MORE: marker is skipped in-loop (no fragile grep
  # that fails on zero).
  local repo_lc; repo_lc=$(printf '%s' "$repo" | tr '[:upper:]' '[:lower:]')   # case-insensitive slug compare
  closing=$(gh_author "$tok" api graphql \
      -f query='query($o:String!,$n:String!,$p:Int!){repository(owner:$o,name:$n){pullRequest(number:$p){closingIssuesReferences(first:100){pageInfo{hasNextPage} nodes{number repository{nameWithOwner}}}}}}' \
      -F o="$owner" -F n="$name" -F p="$pr" \
      --jq '.data.repository.pullRequest.closingIssuesReferences | "MORE:\(.pageInfo.hasNextPage)", (.nodes[] | "\(.number) \(.repository.nameWithOwner)")' 2>/dev/null) \
    || die "design-gate: could not resolve PR #$pr closing issues (lookup failed) — failing closed"
  printf '%s\n' "$closing" | head -1 | grep -qx 'MORE:false' \
    || die "design-gate: PR #$pr closes more than 100 issues — refusing to merge without checking all of them (split the PR, or WF_ALLOW_NONREADY_CLOSE=1)."
  local nrepo_lc
  while read -r n nrepo; do
    case "$n" in ''|MORE:*) continue;; esac          # skip blank + the MORE: marker line
    # A CROSS-REPO closing ref must fail closed (not be silently ignored): a PR here must not close an issue in
    # another repo as an unchecked side effect. Use a non-closing mention (drop Closes/Fixes) for cross-repo refs.
    nrepo_lc=$(printf '%s' "$nrepo" | tr '[:upper:]' '[:lower:]')
    [ "$nrepo_lc" = "$repo_lc" ] || die "design-gate: PR #$pr has a CROSS-REPO closing reference ($nrepo#$n) — a PR here must not close an issue in another repo. Drop the Closes/Fixes keyword for cross-repo refs (a plain mention is fine), or WF_ALLOW_NONREADY_CLOSE=1."
    count=$((count+1))
    labels=$(gh_author "$tok" api "repos/$repo/issues/$n" \
        --jq "[.labels[].name]|map(select(test(\"$DISPO_RE\")))|sort|join(\",\")" 2>/dev/null) \
      || die "design-gate: could not read labels for issue #$n (lookup failed) — failing closed"
    [ "$labels" = "$expect" ] || bad="$bad #$n[disposition=${labels:-none}]"
  done <<EOF
$closing
EOF
  if [ "$design" = 1 ]; then
    [ "$count" = 1 ] || problem="a design PR must close EXACTLY ONE needs-design issue (this closes $count)"
  else
    [ "$count" -ge 1 ] || problem="a code PR must close at least one ready issue (this closes 0)"
  fi
  [ -n "$bad" ] && problem="${problem:+$problem; }closing issue(s) not disposition=={$expect}:$bad"
  [ -z "$problem" ] && { note "design-gate ok: closes $count issue(s), all disposition=={$expect}"; return 0; }
  die "design-gate: $problem.
  Two-phase close contract: code PRs close only 'ready' issues; a 'needs-design' issue is closed by its DESIGN
  landing (finish --design), which spawns 'ready' children (linked 'design: #<n>') — close a child, not the
  parent; triage any other non-'ready' close to 'ready' first. Override (best-effort PR comment + logged):
  WF_ALLOW_NONREADY_CLOSE=1."
}

# =================================================================================================
CMD=${1:-}; shift || true
case "$CMD" in

help|-h|--help|"")  usage; exit 0 ;;

locate-audit)  # wf.sh locate-audit [context-repo] — print the verify-claims reviewer wf.sh would run (introspection/test)
  locate_audit "${1:-}" ;;

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

open)   # wf.sh open <worktree> [author]   — commit the design doc, push, open the DRAFT PR
  need_gh; WT=${1:?usage: wf.sh open <worktree> [author]}; AUTHOR=${2:-}
  [ -d "$WT" ] || die "no such worktree: $WT"
  if [ -n "$AUTHOR" ]; then check_author "$AUTHOR"; else note "WARN: no author passed to open; using ambient git/GitHub identity. For agent attribution, pass author: wf.sh open $WT <claude|codex>"; fi
  BR=$(wt_branch "$WT")
  DOC=$(cd "$WT" && git status --porcelain proposals/ | sed 's/^...//' | head -1)
  [ -n "$DOC" ] || DOC=$(cd "$WT" && git diff --name-only "$(base_ref "$WT")"...HEAD -- proposals/ | head -1)
  [ -n "$DOC" ] || die "no design doc under proposals/ found (write proposals/<issue>-<slug>.md first)"
  ISSUE=$(basename "$DOC" | sed -E 's/^([0-9]+)-.*/\1/')
  AUTHOR_TOKEN=""; GIT_AUTHOR=""
  if [ -n "$AUTHOR" ]; then
    AUTHOR_TOKEN=$(author_token_optional "$AUTHOR")
    [ -n "$AUTHOR_TOKEN" ] || need_ambient_gh
    GIT_AUTHOR=$(engineer_git_author "$AUTHOR" 0)
    if [ -z "$GIT_AUTHOR" ]; then
      [ "${WF_REQUIRE_ENGINEER_IDENTITY:-}" = 1 ] && die "missing git author for author=$AUTHOR and WF_REQUIRE_ENGINEER_IDENTITY=1"
      note "WARN: no engineer git author configured for author=$AUTHOR; using ambient git identity"
    fi
  else
    need_ambient_gh
  fi
  # Commit ONLY the doc: the `-- "$DOC"` pathspec on commit means a pre-staged unrelated file can't ride in.
  if [ -n "$GIT_AUTHOR" ]; then
    GIT_NAME=$(git_author_name "$GIT_AUTHOR"); GIT_EMAIL=$(git_author_email "$GIT_AUTHOR")
    ( cd "$WT" && git add -- "$DOC" && \
      GIT_AUTHOR_NAME="$GIT_NAME" GIT_AUTHOR_EMAIL="$GIT_EMAIL" \
      GIT_COMMITTER_NAME="$GIT_NAME" GIT_COMMITTER_EMAIL="$GIT_EMAIL" \
      git -c user.name="$GIT_NAME" -c user.email="$GIT_EMAIL" commit -q -m "design: $(basename "$DOC" .md) (#${ISSUE})

Namespaced design doc for the scaffold change. Reviewed by --scaffold next." -- "$DOC" )
  else
    ( cd "$WT" && git add -- "$DOC" && git commit -q -m "design: $(basename "$DOC" .md) (#${ISSUE})

Namespaced design doc for the scaffold change. Reviewed by --scaffold next." -- "$DOC" )
  fi
  git_push_author "$AUTHOR_TOKEN" "$WT" -q -u origin "$BR" || die "push failed"
  # PR body = the design doc RENDERED (#24) — self-describing, plain-language, zero duplicate authoring.
  # render_pr_body re-runs at finish so the merged record matches the landed doc. --body-file - (stdin)
  # so the doc's backticks/code fences/$/# survive untouched.
  PRURL=$(render_pr_body "$WT" "$DOC" "$ISSUE" | gh_author "$AUTHOR_TOKEN" -R "$(gh_repo "$WT")" pr create --draft --base main --head "$BR" \
    --title "$(grep -m1 '^# ' "$WT/$DOC" | sed 's/^# Proposal: //; s/^# //')" \
    --body-file -) \
    || die "gh pr create failed"
  PR=$(basename "$PRURL")
  echo "PR=$PR"; note "draft PR #$PR opened: $PRURL"; note "next: wf.sh design-review $WT <author>"
  ;;

design-review)  # wf.sh design-review <worktree> <author>
  need_gh; WT=${1:?usage: wf.sh design-review <worktree> <author>}; AUTHOR=${2:?author: claude|codex}
  check_author "$AUTHOR"; require_model_reviewer "$AUTHOR"; [ -d "$WT" ] || die "no such worktree: $WT"
  ATOK=$(author_token_optional "$AUTHOR")
  [ -n "$ATOK" ] || need_ambient_gh
  require_clean "$WT"; PR=$(wt_pr_required "$WT" "$ATOK")
  DOC=$(cd "$WT" && git diff --name-only "$(base_ref "$WT")"...HEAD -- proposals/ | head -1)
  [ -n "$DOC" ] || die "no committed design doc under proposals/ (run: wf.sh open $WT)"
  # push so the reviewed doc == what the PR shows (consistency with code-review)
  git_push_author "$ATOK" "$WT" -q origin HEAD || die "push failed — can't review a doc the PR doesn't reflect"
  run_review --scaffold "$WT" "$AUTHOR" "$WT/$DOC" "$PR" "Design review (\`--scaffold\`)"
  note "design-review done (HIGH=$REVIEW_HIGH). Revise the doc for findings; the PM's design approval is the human gate (recorded, advisory — not a required check). Then implement + commit, and: wf.sh code-review $WT $AUTHOR"
  ;;

code-review)    # wf.sh code-review <worktree> <author>
  need_gh; WT=${1:?usage: wf.sh code-review <worktree> <author>}; AUTHOR=${2:?author: claude|codex}
  check_author "$AUTHOR"; require_model_reviewer "$AUTHOR"; [ -d "$WT" ] || die "no such worktree: $WT"
  ATOK=$(author_token_optional "$AUTHOR")
  [ -n "$ATOK" ] || need_ambient_gh
  require_clean "$WT"; PR=$(wt_pr_required "$WT" "$ATOK")
  # push first so the PR (what the human + reviewer see) reflects the reviewed commits — no local/remote gap
  git_push_author "$ATOK" "$WT" -q origin HEAD || die "push failed — can't review a diff the PR doesn't reflect"
  DIFF="${TMPDIR:-/tmp}/wf_code_$(wt_branch "$WT" | tr '/' '_').diff"
  ( cd "$WT" && git diff "$(base_ref "$WT")"...HEAD ) > "$DIFF"
  [ -s "$DIFF" ] || die "empty diff main...$(wt_branch "$WT") — implement + commit the change first"
  run_review --code "$WT" "$AUTHOR" "$DIFF" "$PR" "Code review (\`--code\`)"
  note "code-review done (HIGH=$REVIEW_HIGH). Triage findings (fix in $WT + commit, or respond via: wf.sh comment $WT $AUTHOR — posts as the engineer identity, NOT your owner token). Then: wf.sh classify $WT ; wf.sh finish $WT $AUTHOR"
  ;;

comment)        # wf.sh comment <worktree> <author> [body-file]   — post an AUTHOR triage comment
  # Attributes the comment to the AUTHOR family's engineer identity (claude-code-engineer / codex-engineer),
  # not the human owner's ambient token — the author-side counterpart to run_review's reviewer-identity posts.
  # Use it for triage responses to findings (accept/dispute/defer) instead of a bare `gh pr comment`.
  need_gh; WT=${1:?usage: wf.sh comment <worktree> <author> [body-file] (body on stdin if omitted)}
  AUTHOR=${2:?author: claude|codex}; BODYFILE=${3:--}
  check_author "$AUTHOR"; [ -d "$WT" ] || die "no such worktree: $WT"
  ATOK=$(author_token_optional "$AUTHOR")          # author engineer token, or "" with the configured fallback
  [ -n "$ATOK" ] || need_ambient_gh
  PR=$(wt_pr_required "$WT" "$ATOK")
  if [ "$BODYFILE" = - ]; then BODY=$(cat); else [ -f "$BODYFILE" ] || die "no such body file: $BODYFILE"; BODY=$(cat "$BODYFILE"); fi
  [ -n "$BODY" ] || die "empty comment body (nothing on stdin / empty file)"
  echo "$BODY" | gh_author "$ATOK" -R "$(gh_repo "$WT")" pr comment "$PR" --body-file - >/dev/null \
    || die "could not post the author comment to PR #$PR — failing closed"
  if [ -n "$ATOK" ]; then note "posted author COMMENT to PR #$PR as the $AUTHOR engineer identity"
  else note "posted author COMMENT to PR #$PR (ambient token — no engineer identity configured for $AUTHOR)"; fi
  ;;

issue)          # wf.sh issue <claude|codex> <gh issue args…>   — file/comment on a GitHub Issue AS the engineer identity
  # The Issue-side counterpart to `wf.sh comment` (which does PR triage comments): authors Issues and
  # issue-comments as the family engineer identity (claude-code-engineer / codex-engineer), never the human
  # owner's ambient token, so agent-filed Issues read as the bot. ONE engineer-token path for every agent
  # GitHub authorship (#89). No worktree needed — pass full `gh issue` args. Examples:
  #   wf.sh issue claude create -R owner/repo -t "<title>" -b "<body>" -l <label>
  #   wf.sh issue codex  comment <N> -R owner/repo -b "<body>"
  need_gh; AUTHOR=${1:?usage: wf.sh issue <claude|codex> <gh issue args…> (e.g. issue claude create -R owner/repo -t … -b …)}; shift
  check_author "$AUTHOR"
  [ $# -gt 0 ] || die "no gh issue args given (e.g. create -R owner/repo -t '…' -b '…' -l <label>)"
  GHSUB=$1
  # Allowlist: this is the engineer-AUTHORING path (#89), not general issue admin. Refuse anything but
  # create/comment so a typo or a broad call can't run close/edit/delete/lock under the engineer token.
  case "$GHSUB" in create|comment) ;; *) die "wf.sh issue: only 'create' and 'comment' are allowed (got '$GHSUB'); this is the engineer-authoring path, not general issue ops" ;; esac
  # Flag ALLOWLIST (#91): the subcommand allowlist isn't enough, and a denylist is whack-a-mole (misses
  # short forms, `--web=true`, `-we` bundles, future interactive flags). Permit ONLY the non-interactive
  # authoring flags; reject every other `-`-prefixed arg — fails CLOSED on all interactive/destructive/
  # unknown forms at once. STATEFUL scan: every allowed flag TAKES A VALUE, so the token right after a
  # bare (non-`=`) allowed flag is its value and must be skipped — else a legit value beginning with `-`
  # (e.g. `--body-file -` for stdin, or a body like `-x`) would be misread as a flag and rejected.
  want_val=0
  for a in "$@"; do
    if [ "$want_val" = 1 ]; then want_val=0; continue; fi   # this token is the previous flag's value
    case "$a" in
      -*) case "${a%%=*}" in
            -R|--repo|-t|--title|-b|--body|-F|--body-file|-l|--label|-a|--assignee|-m|--milestone|-p|--project)
              case "$a" in *=*) ;; *) want_val=1 ;; esac ;;   # bare form → next token is the value
            *) die "wf.sh issue: flag '$a' is not allowed on the authoring path; permitted (non-interactive create/comment): -R -t -b -F -l -a -m -p" ;;
          esac ;;
      *) ;;   # positional (subcommand, issue number)
    esac
  done
  ATOK=$(author_token_optional "$AUTHOR")          # engineer token, or "" with the configured fallback
  [ -n "$ATOK" ] || need_ambient_gh
  gh_author "$ATOK" issue "$@" || die "wf.sh issue: 'gh issue $GHSUB' failed — failing closed"
  if [ -n "$ATOK" ]; then note "ran 'gh issue $GHSUB' as the $AUTHOR engineer identity"
  else note "ran 'gh issue $GHSUB' (ambient token — no engineer identity configured for $AUTHOR)"; fi
  ;;

classify)       # wf.sh classify <worktree> [author]   — advisory record (never blocks)
  need_gh; WT=${1:?usage: wf.sh classify <worktree> [author]}; AUTHOR=${2:-}
  [ -z "$AUTHOR" ] || check_author "$AUTHOR"
  [ -d "$WT" ] || die "no such worktree: $WT"
  [ -x "$WT/.aar-ci/classify.sh" ] || die "no classifier at $WT/.aar-ci/classify.sh (is this the aar-skills repo?)"
  require_clean "$WT"
  mapfile -t PATHS < <(cd "$WT" && git diff --name-only "$(base_ref "$WT")"...HEAD)
  [ ${#PATHS[@]} -gt 0 ] || die "no changed paths main...HEAD"
  OUT=$( cd "$WT" && .aar-ci/classify.sh "${PATHS[@]}" )
  CLASS=$(echo "$OUT" | sed -nE 's/^CLASSIFICATION: //p' | head -1)
  # Attribute the classification to the opposite-family reviewer identity when configured. Without an author
  # or reviewer identity, keep the existing ambient-comment fallback.
  RTOK=""
  if [ -n "$AUTHOR" ]; then
    RTOK=$(reviewer_token "$AUTHOR" 0)
  else
    note "WARN: no author passed to classify; posting classification with ambient GitHub auth. Pass author to use an opposite-family reviewer identity when configured."
  fi
  [ -n "$RTOK" ] || need_ambient_gh
  PR=$(wt_pr_required "$WT" "$RTOK")
  BODY=$( { echo "## Type of change"; echo;
      classification_summary_text "$CLASS"; echo; echo;
      markdown_code_details "Classifier details" "$OUT"; } )
  if [ -n "$RTOK" ]; then
    echo "$BODY" | GH_TOKEN="$RTOK" gh -R "$(gh_repo "$WT")" pr comment "$PR" --body-file - >/dev/null \
      || die "could not post the classification to PR #$PR as the reviewer identity — failing closed (classification was: $CLASS)"
    note "posted classification to PR #$PR as the reviewer identity"
  else
    echo "$BODY" | gh -R "$(gh_repo "$WT")" pr comment "$PR" --body-file - >/dev/null \
      || die "could not post the classification to PR #$PR — failing closed (classification was: $CLASS)"
    note "posted classification to PR #$PR (default token)"
  fi
  echo "$OUT"
  ;;

finish) # wf.sh finish <worktree> <author> [--design]   — checks + fail-closed merge gate + ready + merge + cleanup
  # Plain finish gates on --code (the diff). `--design` makes it the DESIGN half of two-phase: the merge gate
  # is --scaffold on the design doc (opposite-family native APPROVE), the same approval model as a code PR —
  # for a design-doc-only PR whose implementation lands later as spawned `ready` issues.
  need_gh; WT=${1:?usage: wf.sh finish <worktree> <author> [--design]}; AUTHOR=${2:?author: claude|codex}
  # Validate the optional 3rd arg explicitly — a typo (e.g. --desgin) must FAIL, not silently run plain finish
  # (the wrong merge gate). Only "" or exactly --design are valid.
  DESIGN_MODE=0
  case "${3:-}" in
    "") ;;
    --design) DESIGN_MODE=1 ;;
    *) die "finish: unknown 3rd argument '${3:-}' — only '--design' is valid (or omit it for a code PR)" ;;
  esac
  check_author "$AUTHOR"; require_model_reviewer "$AUTHOR"; [ -d "$WT" ] || die "no such worktree: $WT"
  require_clean "$WT"   # everything must be committed: reviewed == checked == merged, and nothing lost on --force removal
  REPO=$(gh_repo "$WT"); MAIN_CO=$(main_checkout "$WT")
  ATOK=$(author_token_optional "$AUTHOR")
  [ -n "$ATOK" ] || need_ambient_gh
  BR=$(wt_branch "$WT"); PR=$(wt_pr_required "$WT" "$ATOK")
  mapfile -t PATHS < <(cd "$WT" && git diff --name-only "$(base_ref "$WT")"...HEAD)
  [ ${#PATHS[@]} -gt 0 ] || die "no changed paths main...HEAD — nothing to merge"
  # FAIL-CLOSED: --design skips --code, so it must NEVER run on a PR that contains code, and the --scaffold
  # approval must cover the EXACT doc that lands. Require the diff to be (1) design-doc-only (proposals/*.md)
  # and (2) EXACTLY ONE design doc — else the gate would review only one of several docs (head -1) while the
  # rest merged un-design-reviewed. Capture that one doc as the gate target.
  DESIGN_DOC=""
  if [ "$DESIGN_MODE" = 1 ]; then
    # Use a RENAME-STABLE path list (--no-renames): with rename detection, a code->proposals/*.md rename shows
    # only the NEW doc path, so the old code path could masquerade as doc-only and skip --code. --no-renames
    # decomposes a rename into delete(old)+add(new), so the old code path surfaces in NONDOC and is rejected.
    mapfile -t RPATHS < <(cd "$WT" && git diff --no-renames --name-only "$(base_ref "$WT")"...HEAD)
    NONDOC=$(printf '%s\n' "${RPATHS[@]}" | grep -vE '^proposals/.*\.md$' || true)
    [ -z "$NONDOC" ] || die "finish --design is for design-doc-only PRs; this diff also touches non-doc paths:
$NONDOC
Use plain 'wf.sh finish $WT $AUTHOR' (gates on --code) for any PR with code."
    mapfile -t DESIGN_DOCS < <(printf '%s\n' "${RPATHS[@]}" | grep -E '^proposals/.*\.md$')
    [ "${#DESIGN_DOCS[@]}" = 1 ] || die "finish --design expects EXACTLY ONE design doc (the --scaffold approval covers one doc); this diff changes ${#DESIGN_DOCS[@]}:
$(printf '%s\n' "${DESIGN_DOCS[@]}")
Split into one design PR per doc."
    DESIGN_DOC="${DESIGN_DOCS[0]}"
  fi
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
  git_push_author "$ATOK" "$WT" -q origin HEAD || die "push failed — refusing to merge a PR that may not match the reviewed diff"
  LOCAL_SHA=$(git -C "$WT" rev-parse HEAD)
  # Verify the pushed state via the remote BRANCH ref (git ls-remote), NOT `gh pr view headRefOid`: the branch
  # ref updates atomically on push, while GitHub's PR-head association LAGS a beat — querying headRefOid right
  # after a push intermittently returned the old SHA and wedged finish on a phantom mismatch. The merge below
  # still uses --match-head-commit "$LOCAL_SHA" as the authoritative guard against a head that moved.
  # exact head ref only (--heads + refs/heads/$BR) so a tag or other ref with the same tail can't match
  REMOTE_SHA=$(git -C "$WT" ls-remote --heads origin "refs/heads/$BR" | awk '{print $1}')
  [ -n "$REMOTE_SHA" ] || die "branch $BR has no head on origin — push it first"
  [ "$LOCAL_SHA" = "$REMOTE_SHA" ] || die "branch $BR remote head ($REMOTE_SHA) != local HEAD ($LOCAL_SHA) — the reviewed diff is not what would merge. Re-push / reconcile before finishing."
  # 0c. Refresh the PR body from the now-final committed design doc (#24 F1): the doc may have been revised
  #     during review since `open`, so re-render before merge to keep the durable record == the landed doc.
  #     Best-effort — a cosmetic body refresh must never block an otherwise-clean merge. Uses the REST API
  #     (gh api PATCH), NOT `gh pr edit`: the latter issues a GraphQL query needing read:org, which a minimal
  #     repo-scoped token lacks, so it silently no-op'd the refresh (#43). REST pulls PATCH needs only `repo`.
  FDOC=$(cd "$WT" && git diff --name-only "$(base_ref "$WT")"...HEAD -- proposals/ | head -1)
  if [ -n "$FDOC" ]; then
    FISSUE=$(basename "$FDOC" | sed -E 's/^([0-9]+)-.*/\1/')
    # mktemp -> a guaranteed-unique path (no stale-path/dir collision); fall back to a fixed path if mktemp
    # is unavailable. The trailing `||` keeps the assignment from tripping set -e.
    BODYTMP=$(mktemp 2>/dev/null) || BODYTMP="${TMPDIR:-/tmp}/wf_prbody_${BR//\//_}.md"
    # Render AND patch inside one if-condition so set -e can't abort finish on a render/write/API failure
    # — the refresh is best-effort and must never block an otherwise-clean merge (#43/F1).
    if render_pr_body "$WT" "$FDOC" "$FISSUE" > "$BODYTMP" 2>/dev/null \
       && gh_author "$ATOK" api --method PATCH "repos/$REPO/pulls/$PR" -F body=@"$BODYTMP" >/dev/null 2>&1; then
      note "refreshed PR #$PR body from the final design doc"
    else
      note "WARN: could not refresh PR #$PR body (cosmetic — proceeding to merge)"
    fi
    rm -f "$BODYTMP" 2>/dev/null || true   # non-fatal cleanup: never abort finish on a cosmetic temp removal
  fi
  # 1. deterministic checks + behavior smoke, on the BRANCH's actual content (the worktree)
  [ -f "$WT/.aar-ci/checks.sh" ] || die "repo has no tracked check profile ($WT/.aar-ci/checks.sh)"
  note "running .aar-ci checks + smoke on branch content…"
  ( cd "$WT" && bash .aar-ci/checks.sh "${PATHS[@]}" ) || die "deterministic checks/behavior-smoke FAILED — fix before merging"
  # 1.5 the CLOSE-GATE (#50/#85): enforce the two-phase disposition contract on the PR's closing issues, BEFORE
  #     the native APPROVE below (so a non-conforming PR is never approved/mergeable). Fail-closed.
  disposition_gate "$WT" "$ATOK" "$PR" "$DESIGN_MODE"
  # 2. the authoritative merge gate, fail-closed, NO HIGH. approving=1 -> clean review posts a native APPROVE.
  #    --design: gate on --scaffold over the design DOC (the doc IS the deliverable). else: --code over the diff.
  if [ "$DESIGN_MODE" = 1 ]; then
    # $DESIGN_DOC was validated above as the single design doc in the diff — review that exact artifact.
    run_review --scaffold "$WT" "$AUTHOR" "$WT/$DESIGN_DOC" "$PR" "Final design review (merge gate)" 1
  else
    DIFF="${TMPDIR:-/tmp}/wf_finish_${BR//\//_}.diff"
    ( cd "$WT" && git diff "$(base_ref "$WT")"...HEAD ) > "$DIFF"
    run_review --code "$WT" "$AUTHOR" "$DIFF" "$PR" "Final code review (merge gate)" 1
  fi
  [ "$REVIEW_HIGH" = 0 ] || die "merge gate: $REVIEW_HIGH HIGH finding(s) remain — NOT merging. Fix in $WT + commit, then re-run finish."
  # 3. merge the EXACT reviewed SHA (--match-head-commit aborts if the head moved since we synced). On enforced
  #    repos this succeeds only when the required opposite-family approval is present on this SHA.
  note "gate clean (no HIGH) + checks passed -> marking ready + merging PR #$PR @ $LOCAL_SHA"
  gh_author "$ATOK" -R "$REPO" pr ready "$PR" >/dev/null 2>&1 || true
  gh_author "$ATOK" -R "$REPO" pr merge "$PR" --squash --delete-branch --match-head-commit "$LOCAL_SHA" || die "merge failed (head may have moved since review — re-run finish)"
  # 4. cleanup: remove the worktree (derive the main checkout FROM the worktree), delete the local workflow
  #    branch if it is no longer checked out anywhere, then sync main. `gh pr merge --delete-branch` deletes
  #    the remote PR branch, but the local branch is still checked out in $WT at merge time, so local cleanup
  #    has to happen after the worktree is removed. Best-effort only: a cleanup failure must not turn an
  #    already-merged PR into a failed run.
  git -C "$MAIN_CO" worktree remove --force "$WT" 2>/dev/null || true
  if [[ "$BR" == change/* ]]; then
    if git -C "$MAIN_CO" show-ref --verify --quiet "refs/heads/$BR"; then
      if git -C "$MAIN_CO" worktree list --porcelain | grep -Fxq "branch refs/heads/$BR"; then
        note "WARN: local workflow branch $BR is still checked out in a worktree; leaving it in place"
      elif git -C "$MAIN_CO" branch -D "$BR" >/dev/null 2>&1; then
        note "deleted local workflow branch $BR"
      else
        note "WARN: could not delete local workflow branch $BR; remove it manually if stale"
      fi
    fi
  else
    note "WARN: not deleting local non-workflow branch $BR"
  fi
  git -C "$MAIN_CO" pull --ff-only -q origin main 2>/dev/null || note "WARN: could not ff-only pull main ($MAIN_CO) — reconcile manually"
  local_manifest=0; for p in "${PATHS[@]}"; do case "$p" in */plugin.json|*marketplace.json) local_manifest=1;; esac; done
  [ "$local_manifest" = 1 ] && note "a plugin manifest changed — refresh installs: claude plugin marketplace update aar-skills && claude plugin update <name>@aar-skills"
  if [ "$DESIGN_MODE" = 1 ]; then
    echo "SHIPPED: design PR #$PR merged (opposite-family --scaffold approval + checks). Worktree cleaned. Next: file the spawned 'ready' issues."
  else
    echo "SHIPPED: PR #$PR merged (opposite-family review gate + checks). Worktree cleaned."
  fi
  ;;

*) echo "BLOCKED: unknown subcommand '${CMD:-}'." >&2; echo >&2; usage >&2; exit 1 ;;
esac
