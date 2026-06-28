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
# Auth: the ambient agent GitHub credential MUST be read-only (writes go through the engineer token path).
#      Authenticate gh (gh auth login) OR export GH_TOKEN for ordinary ambient READ access only.
#      Protected workflow mutations that name an author are strict by default: they use the engineer
#      identity seams below, or fail before falling back to ambient auth.
#      wf.sh sources NO env file itself.
#      WF_READONLY_TOKEN_CMD prints the ambient READ-ONLY token; WF_READONLY_TOKEN_INFO_CMD reads its
#      token (on stdin) and prints that token's canonical GitHub permissions JSON so `wf.sh doctor
#      --readonly` can authoritatively confirm read-only-ness (it FAILS CLOSED on an unattested token).
#      WF_DOCTOR_SKIP_LIVE_PROBES=1 skips the read-only detector's LIVE network probes (advisory API +
#      git-push) for a hermetic/offline doctor run (provenance still runs); WF_GIT_PROBE_TIMEOUT (default
#      20s) bounds the git-push --dry-run probe so it can never hang doctor.
#      WF_ENGINEER_TOKEN_CMD_CLAUDE / _CODEX print GitHub tokens for engineer identities.
#      WF_ENGINEER_GIT_AUTHOR_CLAUDE / _CODEX are "Name <email>" strings for strict open commits.
#      WF_REVIEWER_TOKEN_CMD remains a legacy alias for WF_ENGINEER_TOKEN_CMD_CODEX.
#      WF_ALLOW_AMBIENT_IDENTITY=1 explicitly restores ambient-auth fallback for workflow mutations.
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
  wf.sh open   <worktree> <author>        commit the doc, push, open the DRAFT PR
  wf.sh design-review <worktree> <author> --scaffold on the doc, post to PR (fail-closed)
  wf.sh code-review   <worktree> <author> --code on the diff, post to PR (fail-closed)
  wf.sh comment <worktree> <author> [file] post an AUTHOR triage comment as the engineer identity (body: file|stdin)
  wf.sh issue   <author> <gh issue args…>  file/comment a GitHub Issue AS the engineer identity (no worktree)
  wf.sh classify      <worktree> <author> classifier on changed paths, post evidence (advisory record)
  wf.sh finish <worktree> <author>        checks + fail-closed --code gate + ready + merge + cleanup
  wf.sh finish <worktree> <author> --design   two-phase DESIGN merge: gate on --scaffold (doc-only PR), spawn ready issues after
  wf.sh doctor <author> [repo-or-worktree] report ambient + engineer identity readiness without printing tokens
  wf.sh doctor <author> [repo-or-worktree] --readonly  STRICT read-only-ambient detector: exits non-zero if the ambient credential is not authoritatively read-only (API + git-push, per-source, non-mutating)
  wf.sh locate-audit [repo]               print the verify-claims reviewer that would run (introspection/test)
  wf.sh dispositions                       print close-gate disposition labels (one per line)
  wf.sh install-gh-guard [bindir] [--force]  install the gh write-guard wrapper ahead of gh on PATH (default ~/.local/bin; --force replaces a non-guard gh)
  wf.sh uninstall-gh-guard [bindir]       remove the gh write-guard wrapper
  wf.sh help                              this message

<author> = claude | codex (the OPPOSITE family reviews). If an engineer identity is configured for that author,
open/push/PR actions use it. Missing engineer identity now fails closed by default; set
WF_ALLOW_AMBIENT_IDENTITY=1 only for a deliberate permissive workflow run. Ambient gh remains fine for
ordinary inspection outside protected wf.sh mutations. wf.sh sources no env file.
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
need_ambient_gh(){ [ -n "${GH_TOKEN:-}" ] || real_gh auth status >/dev/null 2>&1 \
  || die "no GitHub auth — run 'gh auth login' or export GH_TOKEN before invoking; wf.sh sources no env file"; }
ambient_identity_allowed(){ [ "${WF_ALLOW_AMBIENT_IDENTITY:-0}" = 1 ]; }
ambient_identity_hint="Source the engineer-token env before running, or set WF_ALLOW_AMBIENT_IDENTITY=1 for a deliberate ambient-auth workflow run."
ambient_identity_note(){ note "WARN: WF_ALLOW_AMBIENT_IDENTITY=1 — using ambient GitHub auth for protected workflow action: $*"; }
missing_identity_die(){ die "$1. Named ship-change workflow actions are strict by default; wf.sh sources no env file. $ambient_identity_hint"; }
ambient_override_notice(){
  local action=$1
  printf '⚠️ Ambient workflow identity override: `%s` used ambient GitHub auth because `WF_ALLOW_AMBIENT_IDENTITY=1` was set. This should be deliberate; normal ship-change workflow writes use the family engineer bot identity.' "$action"
}
post_ambient_pr_trail(){  # post_ambient_pr_trail <worktree> <pr> <action>
  local wt=$1 pr=$2 action=$3 repo body
  repo=$(gh_repo "$wt")
  body=$(ambient_override_notice "$action")
  echo "$body" | real_gh -R "$repo" pr comment "$pr" --body-file - >/dev/null 2>&1 \
    || note "WARN: could not post ambient-identity override note to PR #$pr (non-fatal; terminal warning already emitted)"
}

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
  [ "$1" = codex ] || return 0
  [ -n "${AUDIT_VERIFIER_CMD:-}" ] \
    || die "author=codex needs a Claude model-family reviewer for --scaffold/--code (set AUDIT_VERIFIER_CMD, e.g. claude -p ... > \"\\$OUT_TMP\")"
  is_claude_verifier_cmd "$AUDIT_VERIFIER_CMD" \
    || die "author=codex needs AUDIT_VERIFIER_CMD to be Claude-family; got a non-Claude verifier (would fail cross-family review)"
}

is_claude_verifier_cmd(){
  # Keep this narrow mirror synced with verify-claims' verifier-family matcher in
  # plugins/verify-claims/skills/verify-claims/scripts/audit_experiment.sh.
  case "${1:-}" in *claude*) return 0 ;; *) return 1 ;; esac
}

review_audit_env(){  # review_audit_env <author> <constitution>
  local author=$1 constitution=$2
  # AUDIT_DRY_RUN= : a review must NEVER run in dry-run (it would exit 0 without writing findings, and a stale
  # clean review file could then be reused as the merge verdict — a gate bypass). Clear it unconditionally.
  if [ "$author" = claude ] && is_claude_verifier_cmd "${AUDIT_VERIFIER_CMD:-}"; then
    note "ignoring same-family AUDIT_VERIFIER_CMD for author=claude; using default Codex verifier"
    printf '%s\0' BASH_ENV= AUDIT_VERIFIER_CMD= AUDIT_DRY_RUN= DISPOSITION_FILE= FRESH_SWEEP_FILE= "AAR_SUBSTRATE=$author" "AUDIT_CONSTITUTION=$constitution"
  else
    printf '%s\0' BASH_ENV= AUDIT_DRY_RUN= DISPOSITION_FILE= FRESH_SWEEP_FILE= "AAR_SUBSTRATE=$author" "AUDIT_CONSTITUTION=$constitution"
  fi
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

engineer_token_seam(){
  case "$1" in
    codex) echo "WF_ENGINEER_TOKEN_CMD_CODEX (or legacy WF_REVIEWER_TOKEN_CMD)" ;;
    claude) echo "WF_ENGINEER_TOKEN_CMD_CLAUDE" ;;
    *) echo "WF_ENGINEER_TOKEN_CMD_<FAMILY>" ;;
  esac
}

engineer_token(){  # engineer_token <family> <required:0|1>
  local fam=$1 required=${2:-0} cmd t suffix
  suffix=$(family_suffix "$fam"); cmd=$(engineer_token_cmd "$fam")
  if [ -z "$cmd" ]; then
    if [ "$required" = 1 ]; then
      missing_identity_die "missing $(engineer_token_seam "$fam") for the $fam engineer identity"
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
    [ "$required" = 1 ] && missing_identity_die "missing WF_ENGINEER_GIT_AUTHOR_$suffix for author=$fam (expected: Name <email>)"
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
    if ambient_identity_allowed; then
      ambient_identity_note "author=$author (missing $(engineer_token_seam "$author"))"
    else
      missing_identity_die "missing $(engineer_token_seam "$author") for author=$author"
    fi
  fi
  echo "$tok"
}

# real_gh — the ONE marked internal gh helper (#165). EVERY internal gh call in wf.sh must go through this
# (directly or via gh_author): it sets WF_GH_INTERNAL=1 so the gh write-guard wrapper (scripts/gh-guard.sh),
# if installed ahead of gh on PATH, passes the call straight through to the real gh instead of redirecting it.
# A GH_TOKEN swap is invisible to a PATH wrapper, so this explicit marker — not "no engineer token present" —
# is the bypass signal. The .aar-ci static check (gh_guard_static_check.sh) fails the build on any unmarked
# `gh`/`GH_TOKEN=… gh` call in this file so a future call site cannot silently regress the bypass.
real_gh(){ WF_GH_INTERNAL=1 gh "$@"; }

# guard_symlink_matches <link> <guard-target> — true ONLY if <link> canonicalizes to the SAME real path as
# <guard-target>. FAILS CLOSED (returns false) if either canonicalization yields empty (e.g. `readlink -f`
# missing/failing), so install/uninstall never treat an unknown gh symlink as "ours" and clobber it (#165
# review). Tries `readlink -f`, then `realpath`, then a plain `readlink` one-hop as a last resort.
canon_path(){ local p; p=$(readlink -f "$1" 2>/dev/null) || p=""; [ -n "$p" ] || p=$(realpath "$1" 2>/dev/null) || p=""; [ -n "$p" ] || p=$(readlink "$1" 2>/dev/null) || p=""; printf '%s' "$p"; }
guard_symlink_matches(){ local a b; a=$(canon_path "$1"); b=$(canon_path "$2"); [ -n "$a" ] && [ -n "$b" ] && [ "$a" = "$b" ]; }

gh_author(){  # gh_author <author-token-or-empty> <gh args...>
  local tok=$1; shift
  if [ -n "$tok" ]; then GH_TOKEN="$tok" real_gh "$@"; else real_gh "$@"; fi
}

# git_push_author — push as the engineer identity, FORCING a one-shot engineer credential (#165). Askpass
# alone is bypassable: a stored owner HTTPS credential helper (~/.git-credentials / keychain) or an SSH
# remote authenticates OUTSIDE GH_TOKEN. So when an engineer token is present we rewrite the push to an
# explicit tokenized HTTPS URL computed from the remote AND disable credential helpers for that one push
# (`-c credential.helper=`), so neither a stored helper nor an SSH key can win. WF_GH_INTERNAL=1 marks the
# push so a `gh auth git-credential` helper invocation by git passes the guard. With no token we fall back
# to a plain push (ambient identity) for unenforced/permissive installs.
git_push_author(){  # git_push_author <author-token-or-empty> <worktree> <args...>
  local tok=$1 wt=$2; shift 2
  # No-token fallback (unenforced/permissive installs): plain push with ambient auth. We do NOT set
  # WF_GH_INTERNAL here — a pre-push hook must not inherit the guard-bypass marker (#165 review); the guard's
  # `auth git-credential get` allowlist already lets git's credential helper through without it.
  if [ -z "$tok" ]; then git -C "$wt" push "$@"; return; fi
  # Derive the effective PUSH url for origin (honors an explicit `remote set-url --push`, else the fetch url).
  local remote_url owner_repo push_url
  remote_url=$(git -C "$wt" remote get-url --push origin 2>/dev/null) || die "git_push_author: no origin remote in $wt"
  case "$remote_url" in
    https://github.com/*|https://*@github.com/*|https://github.com:*|https://*@github.com:*|\
    git@github.com:*|git@ssh.github.com:*|\
    ssh://git@github.com/*|ssh://github.com/*|ssh://git@github.com:*|ssh://git@ssh.github.com*|ssh://ssh.github.com*)
      # A real GitHub remote (HTTPS, scp-style SSH, or ssh:// SSH): FORCE the engineer credential. Askpass
      # alone is bypassable by a stored owner HTTPS helper or an SSH remote/key, so we NORMALIZE any of these
      # forms to an explicit tokenized HTTPS URL AND clear credential helpers for THIS push
      # (-c credential.helper=) so no ambient owner credential (stored helper or SSH key) can win. Callers
      # pass the remote name `origin`; swap the first literal `origin` for the URL.
      # Strip every supported scheme/host/port/userinfo prefix down to <owner>/<repo>. scp-style uses ':'
      # before the path; URL forms use '/'. Cover github.com and ssh.github.com, optional :port, optional
      # user@/x-access-token@ userinfo.
      owner_repo=$(printf '%s' "$remote_url" | sed -E '
        s#^git@(ssh\.)?github\.com:##;
        s#^ssh://([^@/]+@)?(ssh\.)?github\.com(:[0-9]+)?/##;
        s#^https://([^@/]+@)?github\.com(:[0-9]+)?/##;
        s#\.git$##')
      case "$owner_repo" in
        */*) push_url="https://x-access-token:${tok}@github.com/${owner_repo}.git" ;;
        *)   die "git_push_author: could not derive owner/repo from origin url '$remote_url'" ;;
      esac
      # Swap the literal `origin` for the tokenized URL, AND strip any -u/--set-upstream: `git push -u <url> …`
      # would PERSIST the tokenized URL (token!) into .git/config as the branch upstream (#165 review HIGH).
      # We push WITHOUT -u, then set the upstream to the NAMED `origin` remote separately (no URL on disk).
      local a args=() swapped=0 want_upstream=0 upstream_branch=""
      for a in "$@"; do
        case "$a" in
          -u|--set-upstream) want_upstream=1; continue ;;   # drop — restored as named remote below
        esac
        if [ "$swapped" = 0 ] && [ "$a" = origin ]; then args+=("$push_url"); swapped=1; continue; fi
        args+=("$a")
      done
      [ "$swapped" = 1 ] || die "git_push_author: expected an 'origin' remote arg to replace with the tokenized URL"
      # The tokenized URL ALREADY carries the credential (x-access-token:$tok) and `-c credential.helper=`
      # disables any helper, so the push needs NEITHER GH_TOKEN NOR the WF_GH_INTERNAL marker in its env. We
      # deliberately DON'T export them here so a pre-push hook can't inherit the engineer token + guard-bypass
      # marker (#165 review). Return the push's status IMMEDIATELY on failure, BEFORE the upstream bookkeeping
      # below — else the function's exit status would be the trailing `git config`'s (0) and a caller's
      # `… || die` would never fire (set -e does not stop inside a function in a `|| die` context).
      git -C "$wt" -c credential.helper= push "${args[@]}" || return $?
      if [ "$want_upstream" = 1 ]; then
        # set upstream to the NAMED origin remote (never the tokenized URL). The branch arg is the worktree's
        # current branch; configure branch.<b>.remote=origin + .merge=refs/heads/<b> directly so nothing
        # token-bearing is written to .git/config.
        upstream_branch=$(git -C "$wt" rev-parse --abbrev-ref HEAD 2>/dev/null)
        if [ -n "$upstream_branch" ] && [ "$upstream_branch" != HEAD ]; then
          git -C "$wt" config "branch.${upstream_branch}.remote" origin
          git -C "$wt" config "branch.${upstream_branch}.merge" "refs/heads/${upstream_branch}"
        fi
      fi
      ;;
    *)
      # Non-GitHub push remote (e.g. a local file:// remote in tests, or a mirror). No tokenized-URL rewrite
      # applies; push as given with the token in the env. We do NOT set WF_GH_INTERNAL — a pre-push hook must
      # not inherit the guard-bypass marker (#165 review); the guard allowlists `auth git-credential get` so
      # git's credential helper still works without it.
      GH_TOKEN="$tok" git -C "$wt" push "$@"
      ;;
  esac
}

wt_branch(){ git -C "$1" rev-parse --abbrev-ref HEAD; }                       # branch of a worktree
# the INTEGRATION BASE: prefer origin/main (the true base the PR merges onto) over local main, which can go
# stale after a rebase-onto-newer-origin/main. Used consistently for PATHS, review diffs, and the version base
# so they never disagree. Falls back to local main if there's no origin/main remote-tracking ref.
base_ref(){ git -C "$1" rev-parse --verify -q origin/main >/dev/null 2>&1 && echo origin/main || echo main; }

# ---- finding-disposition state (#137/#139): PR-local, GitHub-canonical --------------------------------------
# DISTINCT from disposition_gate() above (the ISSUE close-gate, ready/needs-design). This is the FINDING
# disposition state (fixed/refuted/deferred per review finding) for the disposition-aware merge gate. Canonical
# copy = a marked PR comment (durable, recoverable by any zero-context agent); local cache = a git-path file,
# NEVER the committed tree (so it cannot merge to main or leak to a sibling PR). Names are `fd_*`.
FD_MARKER='<!-- WF-FINDING-DISPOSITIONS -->'
fd_cache(){ git -C "$1" rev-parse --git-path wf-finding-dispositions.json; }   # absolute path under the gitdir
# Stable content-derived id from a finding's issue text (same text -> same id across rounds).
fd_fid(){ printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' ' ' | sed 's/^ *//;s/ *$//' | md5sum | cut -c1-12; }
# Seed/merge a review output file's findings into the cache JSON: new findings -> status "unresolved" (the
# author then dispositions them); existing ids keep their disposition. Closes the omission hole (F2).
fd_seed(){  # fd_seed <cache> <rev>
  local cache=$1 rev=$2 sev="" issue id
  [ -s "$cache" ] || printf '{"altitude":"implementation","findings":[]}\n' > "$cache"
  while IFS= read -r line; do
    case "$line" in
      FINDING\ *) sev=$(printf '%s' "$line" | sed -nE 's/^FINDING [0-9]+: (HIGH|MED|LOW).*/\1/p') ;;
      *issue:*)
        [ -n "$sev" ] || continue
        issue=$(printf '%s' "$line" | sed -E 's/^[[:space:]]*issue:[[:space:]]*//')
        [ -n "$issue" ] || { sev=""; continue; }
        id=$(fd_fid "$issue")
        if [ "$(jq --arg id "$id" '[.findings[]|select(.id==$id)]|length' "$cache" 2>/dev/null)" = 0 ]; then
          jq --arg id "$id" --arg d "$issue" --arg s "$sev" \
            '.findings += [{"id":$id,"severity":$s,"description":$d,"status":"unresolved"}]' \
            "$cache" > "$cache.tmp" && mv "$cache.tmp" "$cache"
        fi
        sev="" ;;
    esac
  done < "$rev"
}
fd_high_list(){ jq -r '.findings[]|select(.severity=="HIGH")|"\(.id) HIGH"' "$1" 2>/dev/null; }
# Non-convergence backstop (#137): bound the MERGE-GATE review loop. The gate's final-SHA review re-runs every
# `finish` and the merge is hard-blocked (enforce_admins ON), so a PR that keeps producing fresh, validly-
# dispositioned HIGHs round after round (PR #192: 7 CHANGES_REQUESTED rounds) has no human-judgment exit and
# burns scarce cross-family review credits. After N such BLOCKING ROUNDS the gate stops saying "fix and re-run"
# and says "this PR is under-scoped — re-split it" (still BLOCKS; never auto-merges). A round = one completed
# merge-gate reviewer pass that STILL PRODUCED A BLOCKING HIGH (a clean review merges, so it is not a
# non-convergence round and never increments — this keeps `round` an honest count of "rounds with a residual
# HIGH", per the field's contract). fd_bump_round increments `round` IDEMPOTENTLY, keyed on a fingerprint of
# <reviewed-HEAD-sha>:<sorted residual-HIGH ids>: a new commit (new SHA) or a changed HIGH set => new
# fingerprint => +1; a bare identical `finish` retry (same SHA, same HIGHs) reproduces the recorded fingerprint
# => no increment. Keyed on SHA (not HIGH-ids alone) so a recurring SAME blocker across genuinely new commits
# still counts — that is exactly the #192 under-scoped signature. It also records `last_reviewed_sha` so the
# pre-review short-circuit can tell "nothing committed since the last counted round" (a bare retry) from "a new
# fix to give one more look". Args: <cache> <reviewed-sha> <high-ids-file> <had-high:0|1>. Echoes the resulting
# round number. Back-compat: absent `round` reads as 0.
fd_bump_round(){  # fd_bump_round <cache> <reviewed-sha> <high-ids-file> <had-high:0|1>
  local cache=$1 sha=$2 hifile=$3 had_high=${4:-0} fp prev cur
  [ -s "$cache" ] || printf '{"altitude":"implementation","findings":[]}\n' > "$cache"
  cur=$(jq -r '.round // 0' "$cache" 2>/dev/null); case "$cur" in ''|*[!0-9]*) cur=0 ;; esac
  # A clean review (no residual HIGH) is NOT a non-convergence round — never increments; leave state untouched.
  if [ "$had_high" != 1 ]; then printf '%s\n' "$cur"; return 0; fi
  # fingerprint = reviewed SHA + the sorted residual-HIGH id set (one id per line in <high-ids-file>)
  fp=$(printf '%s:%s' "$sha" "$(awk 'NF' "$hifile" 2>/dev/null | sort -u | tr '\n' ',')" | md5sum | cut -c1-16)
  prev=$(jq -r '.last_review_fingerprint // ""' "$cache" 2>/dev/null)
  if [ "$fp" != "$prev" ]; then
    cur=$((cur + 1))
    # The cache write must SUCCEED before we report the advance — otherwise fd_bump_round would echo an
    # incremented round while the cache still holds the old value, fd_save would repost stale JSON, and the
    # next finish would undercount. On a write failure, leave the cache untouched and signal failure (rc 1,
    # no echo) so the caller fails closed rather than trusting a phantom increment.
    if jq --argjson r "$cur" --arg fp "$fp" --arg sha "$sha" \
        '.round=$r | .last_review_fingerprint=$fp | .last_reviewed_sha=$sha' "$cache" > "$cache.tmp" \
        && mv "$cache.tmp" "$cache"; then :; else
      rm -f "$cache.tmp" 2>/dev/null || true
      return 1
    fi
  fi
  printf '%s\n' "$cur"
}
fd_round(){ jq -r '(.round // 0)' "$1" 2>/dev/null | grep -E '^[0-9]+$' || echo 0; }   # current round; absent => 0
fd_last_reviewed_sha(){ jq -r '(.last_reviewed_sha // "")' "$1" 2>/dev/null || echo ""; }  # SHA of the last counted round
# Validate the `round` field BEFORE trusting it as the load-bearing backstop counter. Absent / null => fine
# (back-compat 0). A PRESENT value that is not a non-negative INTEGER JSON NUMBER (a corrupt or hand-edited
# disposition save — including a numeric STRING like "3", a float, or a negative) is corruption: rc 2 so finish
# fails closed instead of silently resetting the counter (which fd_round would otherwise do). Validates the JSON
# TYPE in jq, not the rendered string, so `"3"` does not sneak through. rc 2 also on unreadable/invalid JSON.
fd_round_valid(){  # fd_round_valid <cache>  -> rc 0 ok (absent/null/non-neg-integer), rc 2 otherwise
  local v
  v=$(jq -r 'if (has("round")|not) or .round==null then "OK"
             elif (.round|type)=="number" and (.round|floor)==.round and .round>=0 then "OK"
             else "BAD" end' "$1" 2>/dev/null) || return 2
  [ "$v" = OK ] && return 0 || return 2
}
# Post the non-convergence backstop PR comment ONCE (#137): a hidden marker makes it idempotent across repeated
# tripped `finish` runs — if a backstop comment already exists on the PR, skip re-posting. Best-effort (the
# terminal BLOCK at the call site is the gate, not this comment). Args: <atok> <repo> <pr> <rounds> <detail>.
NCV_COMMENT_MARKER='<!-- wf:nonconvergence-backstop -->'
ncv_backstop_comment(){  # ncv_backstop_comment <atok> <repo> <pr> <rounds> <detail>
  local atok=$1 repo=$2 pr=$3 rounds=$4 detail=$5 existing
  existing=$(gh_author "$atok" -R "$repo" pr view "$pr" --json comments \
    --jq '.comments[].body' 2>/dev/null | grep -F "$NCV_COMMENT_MARKER" || true)
  [ -z "$existing" ] || return 0   # already posted once — don't duplicate
  printf '%s\nNon-convergence backstop tripped: %s merge-gate review rounds with a blocking HIGH %s.\n\nEvery round has been a legitimate, validly-dispositioned finding, yet a fresh HIGH keeps appearing — the signature of an **under-scoped** PR (the lesson from PR #132/#192), not a single fixable defect. The recommendation now changes from "fix and re-run" to **re-split this change into smaller `ready`/`needs-design` children** and ship them separately, rather than continuing to spend cross-family review credits on a loop that the merge gate itself cannot exit.\n\nThis is advisory guidance attached to the block; the merge stays blocked (no auto-merge). If you judge this a genuine multi-round false-positive on a cohesive change, raise `WF_NONCONVERGENCE_ROUNDS` for the next `finish` run.\n' \
    "$NCV_COMMENT_MARKER" "$rounds" "$detail" \
    | gh_author "$atok" -R "$repo" pr comment "$pr" --body-file - >/dev/null 2>&1 \
    || note "WARN: could not post the non-convergence backstop PR comment (non-fatal; terminal BLOCK stands)"
}
# TRUSTED findings list (reviewer-derived, not author-editable) from a review output file: "<fid> HIGH" per
# HIGH finding, ids computed the same way fd_seed does. Used as the gate's findings list so deleting/downgrading
# a prior disposition entry can't bypass the deterministic backstop (the deleted id has no entry -> BLOCK).
fd_review_high_list(){  # fd_review_high_list <rev>
  local sev="" issue
  while IFS= read -r line; do
    case "$line" in
      FINDING\ *) sev=$(printf '%s' "$line" | sed -nE 's/^FINDING [0-9]+: (HIGH|MED|LOW).*/\1/p') ;;
      *issue:*) [ "$sev" = HIGH ] || { sev=""; continue; }
        issue=$(printf '%s' "$line" | sed -E 's/^[[:space:]]*issue:[[:space:]]*//')
        [ -n "$issue" ] && printf '%s HIGH\n' "$(fd_fid "$issue")"; sev="" ;;
    esac
  done < "$1"
}
# DURABLE trusted findings list (#143): recover the reviewer-derived HIGH ids from the GitHub review record the
# reviewer bot posts — NOT a transient/author-writable /tmp file. The review body carries a `<!-- WF-REVIEW
# pk=.. -->` marker (run_review) and embeds the raw FINDING block; the fresh-eyes sweep carries a DISTINCT
# marker (fresh_sweep) so it is never trusted. Tamper-resistance is anchored on the reviewer-bot LOGIN (the
# author cannot author another identity's review/comment). echoes "<id> HIGH" lines; returns 1 = no marked
# reviewer review found, 2 = no reviewer login / GitHub API error (caller fails closed on both).
FD_REVIEW_MARKER='<!-- WF-REVIEW'
fd_review_high_github(){  # fd_review_high_github <repo> <pr> <pk> <read-token> <reviewer-login>
  local repo=$1 pr=$2 pk=$3 tok=$4 login=$5
  [ -n "$login" ] || return 2   # no reviewer identity to anchor trust on
  local prefix="$FD_REVIEW_MARKER pk=$pk "   # the marker run_review prepends as the body's FIRST bytes
  local reviews comments body
  # per_page=100 (no --paginate): a PR with >100 reviewer reviews/comments is implausible, and --paginate over
  # array endpoints needs --slurp gymnastics. Both surfaces run_review posts to: native reviews + issue comments.
  reviews=$(GH_TOKEN="$tok" real_gh api "repos/$repo/pulls/$pr/reviews?per_page=100" 2>/dev/null) || return 2
  comments=$(GH_TOKEN="$tok" real_gh api "repos/$repo/issues/$pr/comments?per_page=100" 2>/dev/null) || return 2
  # Trust only reviewer-LOGIN-authored bodies whose marker is at the START of the body — startswith, NOT
  # contains, so a marker QUOTED inside a fenced review body (a review OF this very change, or a sweep's
  # candidate text) can never masquerade as a real marked review. startswith alone also excludes the fresh-eyes
  # sweep (its body starts with the DISTINCT WF-FRESH-SWEEP marker, never WF-REVIEW) — so no extra sweep-marker
  # filter is needed, and adding one would wrongly reject a genuine review that merely *mentions* the sweep
  # marker (e.g. a review of this code). Pick the most-recent survivor.
  body=$(jq -rn --argjson R "$reviews" --argjson C "$comments" --arg login "$login" --arg prefix "$prefix" '
    ([ $R[] | {t: (.submitted_at // .created_at // ""), login: .user.login, body} ]
     + [ $C[] | {t: (.created_at // ""), login: .user.login, body} ])
    | map(select(.login == $login and .body != null and (.body | startswith($prefix))))
    | sort_by(.t) | last | .body // empty') 2>/dev/null || return 2
  [ -n "$body" ] || return 1   # no marked reviewer review recoverable
  # Capture the parser output AND status BEFORE cleanup so a temp write/read failure fails closed instead of
  # being masked by rm's success (the function's exit status must reflect recovery, not cleanup).
  local tmp out rc
  tmp=$(mktemp 2>/dev/null) || tmp="${TMPDIR:-/tmp}/wf_ghrev_${pk}_$$.md"
  if ! printf '%s\n' "$body" > "$tmp" 2>/dev/null; then rm -f "$tmp" 2>/dev/null; return 2; fi
  out=$(fd_review_high_list "$tmp"); rc=$?
  rm -f "$tmp" 2>/dev/null || true
  printf '%s\n' "$out"
  return "$rc"
}
# Tri-state so a GitHub error never reads as "no state" (fail-open): 0 = active, 1 = no state, 2 = lookup error.
fd_active(){  # fd_active <repo> <pr> <tok>
  local out rc
  out=$(gh_author "$3" -R "$1" pr view "$2" --json comments --jq "[.comments[]|select(.body|contains(\"$FD_MARKER\"))]|length" 2>/dev/null); rc=$?
  [ "$rc" = 0 ] || return 2
  [ "${out:-0}" -gt 0 ] 2>/dev/null && return 0 || return 1
}
fd_load(){  # fd_load <wt> <repo> <pr> <tok> -> echoes cache path (canonical PR comment -> cache; init if none)
  local wt=$1 repo=$2 pr=$3 tok=$4 cache body
  cache=$(fd_cache "$wt")
  # `last` selects the most-recent matching comment IN jq — do NOT pipe the multiline body through tail.
  # Distinguish a GitHub READ FAILURE (must fail closed) from a legitimate "no marker yet" (empty state).
  local grc=0
  body=$(gh_author "$tok" -R "$repo" pr view "$pr" --json comments --jq "[.comments[]|select(.body|contains(\"$FD_MARKER\"))|.body]|last // empty" 2>/dev/null) || grc=$?
  [ "$grc" = 0 ] || { echo "BLOCKED: could not read PR #$pr comments to load disposition state (GitHub error)" >&2; return 2; }
  if [ -n "$body" ]; then
    printf '%s' "$body" | sed -n '/```json/,/```/p' | sed '1d;$d' > "$cache"
    # A marked comment that exists but yields no valid JSON is CORRUPT state -> fail closed (not empty init).
    jq -e . "$cache" >/dev/null 2>&1 || { echo "BLOCKED: canonical disposition comment on PR #$pr exists but has no valid JSON" >&2; return 1; }
  else
    printf '{"altitude":"implementation","findings":[]}\n' > "$cache"   # no marker -> legitimately empty state
  fi
  printf '%s\n' "$cache"
}
# fd_merge_canonical_round (#137): the MONOTONIC-counter guard, factored out of fd_save so it is unit-testable
# without GitHub. The non-convergence `round` is reviewer-owned and monotonic — an author-facing `fdispo save`
# of a hand-edited cache (which carries only finding dispositions) must NEVER lower or delete it, or the author
# could reset the backstop and keep spending reviews past the threshold. Given the CANONICAL comment body (as
# read from GitHub) and the local <cache>, if canonical's round is at least the cache's, adopt canonical's round
# + its matching fingerprint + last_reviewed_sha into the cache (so the about-to-post save can't regress it OR
# drop its metadata). The comparison is `>=`, not `>`: on EQUAL rounds an author `fdispo save` whose cache lacks
# (or staled) last_reviewed_sha would otherwise publish a same-round comment WITHOUT the SHA, and a later bare
# retry would miss the pre-review short-circuit. The only writer of round/sha is fd_bump_round (finish), which
# always STRICTLY increments — so on equal rounds canonical is always at least as authoritative, and finish's
# own advancing save still wins (its local round is strictly greater => this branch is skipped => local wins).
# Args: <cache> <canonical-comment-body>. RETURNS nonzero when fd_save must abort: rc 2 if a PRESENT canonical
# body is unparseable OR its round is malformed (would otherwise be coerced to 0 and reset the counter), or rc 1
# if a required adoption (canonical >= local) cannot be written. A no-op returns 0: a genuinely-empty body (no
# canonical comment yet), a lower canonical round, or an absent canonical round (back-compat).
fd_merge_canonical_round(){  # fd_merge_canonical_round <cache> <canonical-body>
  local cache=$1 cbody=$2 cjson cround lround fp sha
  [ -n "$cbody" ] || return 0   # genuinely NO canonical comment yet (empty body) -> legit no-op
  # A canonical comment EXISTS — it MUST parse. A present-but-unparseable body is corruption: rc 2 so fd_save
  # aborts (matches fd_clamp_to_canonical). This is the single fail-closed point both the author save AND the
  # finish/allow_advance save flow through, so finish is protected too.
  cjson=$(printf '%s' "$cbody" | sed -n '/```json/,/```/p' | sed '1d;$d' \
    | jq -c '{r:(.round // 0), fp:(.last_review_fingerprint // ""), sha:(.last_reviewed_sha // "")}' 2>/dev/null) || return 2
  [ -n "$cjson" ] || return 2
  # The canonical comment's `round` is also the load-bearing counter — a PRESENT-but-malformed canonical value
  # must NOT be silently coerced to 0 (that would let a corrupt canonical comment be overwritten/reset). Tell a
  # legitimate ABSENT round (back-compat 0) from a present-but-bad one via the jq->0 input, and fail closed (rc 2)
  # on the latter so fd_save aborts. (`.r` came from `.round // 0`, so 0 here = absent OR a literal 0 — both fine.)
  local cround_raw; cround_raw=$(printf '%s' "$cbody" | sed -n '/```json/,/```/p' | sed '1d;$d' \
    | jq -r 'if (has("round")|not) or .round==null then "OK0"
             elif (.round|type)=="number" and (.round|floor)==.round and .round>=0 then (.round|tostring)
             else "BAD" end' 2>/dev/null)
  [ "$cround_raw" = BAD ] && return 2
  cround=$(printf '%s' "$cjson" | jq -r '.r' 2>/dev/null); case "$cround" in ''|*[!0-9]*) cround=0 ;; esac
  lround=$(jq -r '(.round // 0)' "$cache" 2>/dev/null); case "$lround" in ''|*[!0-9]*) lround=0 ;; esac
  if [ "$cround" -ge "$lround" ] 2>/dev/null && [ "$cround" -gt 0 ] 2>/dev/null; then
    fp=$(printf '%s' "$cjson" | jq -r '.fp'); sha=$(printf '%s' "$cjson" | jq -r '.sha')
    # The adoption is REQUIRED (canonical is at least as advanced) — if we can't write it, signal failure so
    # fd_save aborts rather than publish the stale lower local round (which would regress the monotonic counter).
    if jq --argjson r "$cround" --arg fp "$fp" --arg sha "$sha" \
        '.round=$r | .last_review_fingerprint=$fp | .last_reviewed_sha=$sha' "$cache" > "$cache.tmp" \
        && mv "$cache.tmp" "$cache"; then :; else
      rm -f "$cache.tmp" 2>/dev/null || true
      return 1
    fi
  fi
  return 0
}
# fd_clamp_to_canonical (#137): the OTHER half of monotonicity. The round counter is REVIEWER-OWNED — only the
# finish path (fd_bump_round, after a completed merge-gate review) may ADVANCE it. An author-facing `fdispo save`
# of a hand-edited cache must not be able to publish a `round` ABOVE the canonical value (which would advance, or
# attach bogus fingerprint/sha to, the counter without a merge review). So on a non-finish save, if the local
# round exceeds canonical, clamp the local round + fingerprint + sha DOWN to canonical's before posting. (Combined
# with fd_merge_canonical_round's adopt-when-canonical-is-higher, a non-finish save can only ever publish exactly
# the canonical round — it can change findings, never the counter.) Args: <cache> <canonical-body>. rc 2 if a
# present canonical body is unparseable/malformed (fail closed); rc 1 if a required clamp write failed; rc 0 on a
# successful clamp or a no-op (local <= canonical, incl. a legitimately-empty no-canonical-yet body).
fd_clamp_to_canonical(){  # fd_clamp_to_canonical <cache> <canonical-body>
  local cache=$1 cbody=$2 cjson cround lround fp sha
  cround=0
  if [ -n "$cbody" ]; then
    # A canonical comment EXISTS — it MUST parse. An unparseable/malformed canonical body is corruption: rc 2 so
    # fd_save aborts rather than clamp to a phantom 0 and publish a reset counter. (Empty body = genuinely no
    # canonical comment yet -> cround stays 0, a legitimate first-save clamp.)
    cjson=$(printf '%s' "$cbody" | sed -n '/```json/,/```/p' | sed '1d;$d' \
      | jq -c '{r:(.round // 0), fp:(.last_review_fingerprint // ""), sha:(.last_reviewed_sha // "")}' 2>/dev/null) || return 2
    [ -n "$cjson" ] || return 2
    cround=$(printf '%s' "$cjson" | jq -r '.r' 2>/dev/null); case "$cround" in ''|*[!0-9]*) return 2 ;; esac
  fi
  lround=$(jq -r '(.round // 0)' "$cache" 2>/dev/null); case "$lround" in ''|*[!0-9]*) lround=0 ;; esac
  if [ "$lround" -gt "$cround" ] 2>/dev/null; then
    fp=""; sha=""
    if [ -n "${cjson:-}" ]; then fp=$(printf '%s' "$cjson" | jq -r '.fp'); sha=$(printf '%s' "$cjson" | jq -r '.sha'); fi
    if jq --argjson r "$cround" --arg fp "$fp" --arg sha "$sha" \
        '.round=$r | .last_review_fingerprint=$fp | .last_reviewed_sha=$sha' "$cache" > "$cache.tmp" \
        && mv "$cache.tmp" "$cache"; then :; else rm -f "$cache.tmp" 2>/dev/null || true; return 1; fi
  fi
  return 0
}
# fd_save posts the local cache as the new canonical comment, after guarding the monotonic counter. The canonical
# read is REQUIRED, not best-effort: if it FAILS (GitHub error) we fail closed (rc 3, no post) rather than risk
# regressing `round`. A clean read that finds NO canonical comment yet (empty body) is a legitimate first save. The
# local round is validated at save time (rc 4 on malformed). The round is REVIEWER-OWNED: by default (allow_advance
# unset/0 — the author `fdispo save` path) a local round ABOVE canonical is CLAMPED down, so only the finish path
# (allow_advance=1, right after fd_bump_round) may advance it. RETURNS: gh post rc on a real post; 3 read failed;
# 4 malformed local round; 5 a required canonical adoption couldn't be written; 6 a required author-clamp couldn't
# be written.
fd_save(){  # fd_save <wt> <repo> <pr> <tok> [allow_advance:0|1]
  local wt=$1 repo=$2 pr=$3 tok=$4 allow_advance=${5:-0} cache cbody rrc=0; cache=$(fd_cache "$wt")
  fd_round_valid "$cache" || return 4   # never publish a malformed round (back-compat absent/null still ok)
  cbody=$(gh_author "$tok" -R "$repo" pr view "$pr" --json comments \
    --jq "[.comments[]|select(.body|contains(\"$FD_MARKER\"))|.body]|last // empty" 2>/dev/null) || rrc=$?
  [ "$rrc" = 0 ] || return 3   # canonical read failed -> cannot guarantee monotonicity -> fail closed, do NOT post
  fd_merge_canonical_round "$cache" "$cbody" || return 5   # canonical >= local: required adoption couldn't be written
  [ "$allow_advance" = 1 ] || fd_clamp_to_canonical "$cache" "$cbody" || return 6  # author save: local can't out-advance canonical
  printf '%s\n\n## Finding dispositions — disposition-aware merge gate (canonical, latest)\n\n```json\n%s\n```\n' \
    "$FD_MARKER" "$(cat "$cache")" | gh_author "$tok" -R "$repo" pr comment "$pr" --body-file - >/dev/null 2>&1
}
# fd-helpers-end (extraction sentinel for fd_state_smoke.sh)

# fresh_sweep (#140): an UN-ANCHORED stateless dimensional review (no disposition injection — review_audit_env
# clears DISPOSITION_FILE; the --code/--scaffold prompts carry no prior-round anchoring) to catch a pre-existing
# hole the disposition-anchored review would trust past. Writes a DISTINCT wf_fresh_<branch>.md artifact (never
# the wf_code_*/wf_scaffold_* file #139 consumes), posts it COMMENT-ONLY and NON-gating, and echoes the artifact
# path. CANDIDATE-only: it never seeds state or feeds the deterministic gate; the disposition-aware merge review
# semantically adjudicates it. A sweep failure is non-fatal (the disposition-aware gate still runs).
fresh_sweep(){  # fresh_sweep <wt> <author> <mode> <target> <pr>  -> echoes the artifact path (best-effort)
  local wt=$1 author=$2 mode=$3 target=$4 pr=$5
  local audit rev; audit=$(locate_audit "$wt")
  rev="${TMPDIR:-/tmp}/wf_fresh_$(wt_branch "$wt" | tr '/' '_').md"
  rm -f "$rev"   # never reuse a stale sweep
  local audit_env=()
  while IFS= read -r -d '' item; do audit_env+=("$item"); done < <(review_audit_env "$author" "${AUDIT_CONSTITUTION:-$wt/AGENTS.md}")
  note "fresh-eyes sweep (un-anchored stateless ${mode#--}; candidate findings, NON-gating)…"
  # The sweep itself is the MANDATORY backstop — return non-zero on failure so finish fails closed. Only the
  # PR-comment posting below is best-effort. (NOT require_valid_review here — it dies; the caller decides.)
  if ! env "${audit_env[@]}" bash "$audit" "$mode" "$target" "$wt" "$rev" >/dev/null 2>"$rev.run.log"; then
    note "fresh-eyes sweep run FAILED — tail: $(tail -2 "$rev.run.log" 2>/dev/null)"; return 1
  fi
  grep -qE '^SUMMARY: high=[0-9]+ med=[0-9]+ low=[0-9]+' "$rev" 2>/dev/null \
    || { note "fresh-eyes sweep produced no parseable output"; rm -f "$rev"; return 1; }
  local h m l; h=$(count_high "$rev"); m=$(count_med "$rev"); l=$(count_low "$rev")
  # If the SUMMARY claims findings but none are parseable as FINDING lines, the candidates would silently vanish
  # from the adjudicator — treat that as a malformed (failed) sweep so the mandatory backstop holds.
  if [ "$((h + m + l))" -gt 0 ] && ! grep -qE '^FINDING ' "$rev" 2>/dev/null; then
    note "fresh-eyes sweep SUMMARY claims findings but no parseable FINDING lines — treating as malformed"; rm -f "$rev"; return 1
  fi
  note "fresh-eyes sweep: $h HIGH / $m MED / $l LOW candidate(s) -> $rev"
  if [ -n "$pr" ]; then
    local repo rtok; repo=$(gh_repo "$wt"); rtok=$(reviewer_token "$author" 0)
    if [ -z "$rtok" ] && ! ambient_identity_allowed; then
      note "fresh-eyes sweep: no reviewer engineer identity — skipping the (non-gating) PR comment"
    else
      local body
      # #143: a DISTINCT marker (NOT WF-REVIEW) so the disposition gate's GitHub recovery never trusts the
      # candidate-only sweep — even though it is posted by the same reviewer bot and embeds FINDING lines.
      body=$( { printf '<!-- WF-FRESH-SWEEP -->\n## Fresh-eyes sweep — un-anchored stateless read (CANDIDATE findings; NON-gating; do NOT `fdispo seed` these)\n\nThese are an amnesiac full re-read to catch a pre-existing hole. They are NOT a verdict and NOT auto-seeded; the disposition-aware merge review semantically adjudicates them, and only its residual findings are dispositioned.\n\n'; markdown_code_details "Sweep candidates ($h HIGH/$m MED/$l LOW)" "$(cat "$rev")"; } )
      printf '%s' "$body" | gh_author "$rtok" -R "$repo" pr comment "$pr" --body-file - >/dev/null 2>&1 \
        || note "WARN: could not post the fresh-eyes sweep comment (non-fatal)"
    fi
  fi
  printf '%s\n' "$rev"
}

# the reviewed + merged content must be the COMMITTED content: refuse to act on a dirty tree (uncommitted or
# untracked changes would make checks/review see content that isn't what merges, and --force removal would
# then destroy it).
require_clean(){ [ -z "$(git -C "$1" status --porcelain)" ] || die "worktree $1 has uncommitted/untracked changes — commit or discard them first (reviewed+merged content must be the committed content)"; }
# every post-open review/finish subcommand REQUIRES a PR (the durable record); a failed lookup is fatal, never silent.
wt_pr_required(){ local pr; pr=$(wt_pr "$1" "${2:-}"); [ -n "$pr" ] || die "no PR found for branch $(wt_branch "$1") — run 'wf.sh open $1' first (or PR lookup/auth failed)"; echo "$pr"; }
# repo slug + main checkout, derived FROM a worktree dir (any worktree shares origin + the main checkout):
gh_repo(){      git -C "${1:-$ORIGIN_REPO}" remote get-url origin | sed -E 's#(git@github.com:|https://github.com/)##; s#\.git$##'; }
repo_arg_from_gh_args(){  # repo_arg_from_gh_args <fallback-repo> <gh-subcommand-args...>
  local repo=$1 want_repo=0 want_val=0 a
  shift || true
  for a in "$@"; do
    if [ "$want_val" = 1 ]; then want_val=0; continue; fi
    if [ "$want_repo" = 1 ]; then repo=$a; want_repo=0; continue; fi
    case "$a" in
      -R|--repo) want_repo=1 ;;
      -R=*) repo=${a#-R=} ;;
      --repo=*) repo=${a#--repo=} ;;
      -t|--title|-b|--body|-F|--body-file|-l|--label|-a|--assignee|-m|--milestone|-p|--project)
        want_val=1 ;;
      -t=*|--title=*|-b=*|--body=*|-F=*|--body-file=*|-l=*|--label=*|-a=*|--assignee=*|-m=*|--milestone=*|-p=*|--project=*)
        ;;
    esac
  done
  echo "$repo"
}
issue_number_from_gh_issue_args(){  # issue_number_from_gh_issue_args <gh issue args...>
  local sub=${1:-} want_val=0 a
  shift || true
  [ "$sub" = comment ] || return 0
  for a in "$@"; do
    if [ "$want_val" = 1 ]; then want_val=0; continue; fi
    case "$a" in
      -R|--repo|-t|--title|-b|--body|-F|--body-file|-l|--label|-a|--assignee|-m|--milestone|-p|--project)
        want_val=1 ;;
      -R=*|--repo=*|-t=*|--title=*|-b=*|--body=*|-F=*|--body-file=*|-l=*|--label=*|-a=*|--assignee=*|-m=*|--milestone=*|-p=*|--project=*)
        ;;
      -*) ;;
      *) echo "$a"; return 0 ;;
    esac
  done
}
# Narrow engineer MAINTAINER verbs (#164): close|label|dispose under the engineer identity, each with a FIXED
# validated arg set and NO arbitrary-arg passthrough (the #91 hardening model). Called from the `issue)` arm.
#   close   <N> -R <repo> [-c|--comment <text>] [-r|--reason completed|"not planned"|duplicate] [--duplicate-of <N|url>]
#   label   <N> -R <repo> [--add-label <L>]… [--remove-label <L>]…   (≥1 add/remove)
#   dispose <N> -R <repo> --label <L> --body-line "<key>: <val>"     (atomic disposition: one label + one
#           idempotent body line — re-running with the same "<key>:" replaces that line, never duplicates,
#           and never overwrites the rest of the body. This is the `blocked-by: #N` body-set path.)
issue_maintainer_verb(){
  local author=$1 verb=$2; shift 2
  local repo="" num="" comment="" reason="" dupof="" dlabel="" bodyline="" want=""
  local -a add_labels=() rm_labels=()
  # STATEFUL allowlist scan (mirrors the create/comment path): only the named flags, each consuming its value;
  # any other `-`-prefixed token fails CLOSED. No bare `gh` flag survives that isn't explicitly permitted here.
  local a
  for a in "$@"; do
    if [ -n "$want" ]; then
      # An explicitly-supplied flag value must be non-empty: automation passing an unset variable
      # (e.g. `--reason "$VAR"` with VAR empty) must FAIL CLOSED, not silently fall back to default semantics.
      [ -n "$a" ] || die "wf.sh issue $verb: flag value for --$want must not be empty (an empty value was supplied)"
      case "$want" in
        repo) repo=$a ;; comment) comment=$a ;; reason) reason=$a ;; dupof) dupof=$a ;;
        dlabel) dlabel=$a ;; bodyline) bodyline=$a ;;
        add) add_labels+=("$a") ;; rm) rm_labels+=("$a") ;;
      esac
      want=""; continue
    fi
    case "$a" in
      # An explicit `--flag=` / `-x=` with an EMPTY value fails closed too (same reason as the bare-form check
      # above) — an empty supplied value must never read as "flag omitted".
      -[A-Za-z]=|--*=) die "wf.sh issue $verb: flag '$a' was given an empty value (an empty value is not allowed)" ;;
      -R|--repo)            want=repo ;;
      -R=*) repo=${a#-R=} ;; --repo=*) repo=${a#--repo=} ;;
      -c|--comment)         [ "$verb" = close ] || die "wf.sh issue $verb: -c/--comment is only valid for 'close'"; want=comment ;;
      -c=*) [ "$verb" = close ] || die "wf.sh issue $verb: -c/--comment is only valid for 'close'"; comment=${a#-c=} ;;
      --comment=*) [ "$verb" = close ] || die "wf.sh issue $verb: --comment is only valid for 'close'"; comment=${a#--comment=} ;;
      -r|--reason)          [ "$verb" = close ] || die "wf.sh issue $verb: -r/--reason is only valid for 'close'"; want=reason ;;
      -r=*) [ "$verb" = close ] || die "wf.sh issue $verb: -r/--reason is only valid for 'close'"; reason=${a#-r=} ;;
      --reason=*) [ "$verb" = close ] || die "wf.sh issue $verb: --reason is only valid for 'close'"; reason=${a#--reason=} ;;
      --duplicate-of)       [ "$verb" = close ] || die "wf.sh issue $verb: --duplicate-of is only valid for 'close'"; want=dupof ;;
      --duplicate-of=*) [ "$verb" = close ] || die "wf.sh issue $verb: --duplicate-of is only valid for 'close'"; dupof=${a#--duplicate-of=} ;;
      --add-label)          [ "$verb" = label ] || die "wf.sh issue $verb: --add-label is only valid for 'label'"; want=add ;;
      --add-label=*) [ "$verb" = label ] || die "wf.sh issue $verb: --add-label is only valid for 'label'"; add_labels+=("${a#--add-label=}") ;;
      --remove-label)       [ "$verb" = label ] || die "wf.sh issue $verb: --remove-label is only valid for 'label'"; want=rm ;;
      --remove-label=*) [ "$verb" = label ] || die "wf.sh issue $verb: --remove-label is only valid for 'label'"; rm_labels+=("${a#--remove-label=}") ;;
      --label)              [ "$verb" = dispose ] || die "wf.sh issue $verb: --label is only valid for 'dispose'"; want=dlabel ;;
      --label=*) [ "$verb" = dispose ] || die "wf.sh issue $verb: --label is only valid for 'dispose'"; dlabel=${a#--label=} ;;
      --body-line)          [ "$verb" = dispose ] || die "wf.sh issue $verb: --body-line is only valid for 'dispose'"; want=bodyline ;;
      --body-line=*) [ "$verb" = dispose ] || die "wf.sh issue $verb: --body-line is only valid for 'dispose'"; bodyline=${a#--body-line=} ;;
      -*) die "wf.sh issue $verb: flag '$a' is not allowed (no arbitrary passthrough — #91 model). Permitted: close[-R -c -r --duplicate-of] label[-R --add-label --remove-label] dispose[-R --label --body-line]" ;;
      *) [ -z "$num" ] || die "wf.sh issue $verb: unexpected extra positional '$a' (only one issue number)"; num=$a ;;
    esac
  done
  [ -z "$want" ] || die "wf.sh issue $verb: flag expecting a value got none"
  [ -n "$num" ] || die "wf.sh issue $verb: missing issue number (e.g. wf.sh issue <fam> $verb 123 -R owner/repo …)"
  case "$num" in *[!0-9]*) die "wf.sh issue $verb: issue must be a number (got '$num')" ;; esac
  [ -n "$repo" ] || die "wf.sh issue $verb: -R <owner/repo> is required"
  local ATOK; ATOK=$(author_token_optional "$author")
  [ -n "$ATOK" ] || need_ambient_gh
  case "$verb" in
    close)
      local -a args=(issue close "$num" -R "$repo")
      [ -n "$comment" ] && args+=(-c "$comment")
      if [ -n "$reason" ]; then
        # gh's fixed close-reason enum (gh ≥2.45: completed|not planned|duplicate). Validate against it so a
        # typo'd reason fails closed here rather than at gh.
        case "$reason" in completed|"not planned"|duplicate) ;; *) die "wf.sh issue close: --reason must be 'completed', 'not planned', or 'duplicate' (gh's fixed close-reason set)" ;; esac
        args+=(-r "$reason")
      fi
      if [ -n "$dupof" ]; then
        # --duplicate-of takes an issue NUMBER or a GitHub issue URL — nothing else (no arbitrary string that
        # gh might reinterpret). gh derives reason=duplicate from it, so it composes with -r duplicate.
        case "$dupof" in
          ''|*[!0-9]*)
            # not a bare number → must be a well-formed issue URL with EXACTLY owner/repo/issues/<digits> and
            # nothing trailing (a glob like .../issues/[0-9]* would accept '10abc' or extra path segments).
            [[ "$dupof" =~ ^https://github\.com/[^/]+/[^/]+/issues/[0-9]+$ ]] \
              || die "wf.sh issue close: --duplicate-of must be an issue number or a https://github.com/<owner>/<repo>/issues/<n> URL (got '$dupof')" ;;
        esac
        args+=(--duplicate-of "$dupof")
      fi
      gh_author "$ATOK" "${args[@]}" || die "wf.sh issue close: 'gh issue close' failed — failing closed"
      ;;
    label)
      [ ${#add_labels[@]} -gt 0 ] || [ ${#rm_labels[@]} -gt 0 ] || die "wf.sh issue label: give at least one --add-label or --remove-label"
      local -a args=(issue edit "$num" -R "$repo")
      local l
      for l in "${add_labels[@]}"; do args+=(--add-label "$l"); done
      for l in "${rm_labels[@]}"; do args+=(--remove-label "$l"); done
      gh_author "$ATOK" "${args[@]}" || die "wf.sh issue label: 'gh issue edit' (labels) failed — failing closed"
      ;;
    dispose)
      [ -n "$dlabel" ] || die "wf.sh issue dispose: --label <disposition> is required"
      [ -n "$bodyline" ] || die "wf.sh issue dispose: --body-line \"<key>: <val>\" is required"
      # The disposition vocab is fixed (DISPO_RE, the same set the close-gate enforces): dispose sets a
      # DISPOSITION, so reject anything that isn't one — this is not a general label setter.
      printf '%s' "$dlabel" | grep -qE "$DISPO_RE" || die "wf.sh issue dispose: --label must be a disposition ($(bash "${BASH_SOURCE[0]}" dispositions | paste -sd'|' -)); got '$dlabel' (use 'wf.sh issue <fam> label' for non-disposition labels)"
      case "$bodyline" in *:*) ;; *) die "wf.sh issue dispose: --body-line must contain a 'key:' (e.g. \"blocked-by: #42\") so it can be set idempotently" ;; esac
      # --body-line is a SINGLE line by contract: reject embedded LF/CR so it can't append multiple body lines.
      case "$bodyline" in *$'\n'*|*$'\r'*) die "wf.sh issue dispose: --body-line must be a single line (no embedded newline/CR)" ;; esac
      local key; key=${bodyline%%:*}            # idempotency key = text before the first colon
      # Treat the key as a LITERAL prefix, never a regex: validate a conservative charset (word chars + '-')
      # so it can't smuggle ERE metacharacters that would delete unrelated body lines.
      case "$key" in *[!A-Za-z0-9_-]*|"") die "wf.sh issue dispose: --body-line key '$key' must be [A-Za-z0-9_-]+ (e.g. 'blocked-by'); the part before the first ':'" ;; esac
      local cur newbody
      cur=$(gh_author "$ATOK" issue view "$num" -R "$repo" --json body -q .body 2>/dev/null) \
        || die "wf.sh issue dispose: could not read issue #$num body — failing closed"
      # Drop any existing line whose key matches (LITERAL prefix compare in awk, not a regex), so re-disposing
      # replaces rather than duplicates; fail closed on a filter error rather than risk an empty-body overwrite.
      newbody=$(printf '%s' "$cur" | awk -v k="$key" '{ l=$0; sub(/^[ \t]+/,"",l); if (index(l, k ":")==1) next; print }') \
        || die "wf.sh issue dispose: body-line filter failed — failing closed (refusing to overwrite the issue body)"
      newbody=$(printf '%s\n%s\n' "$newbody" "$bodyline")
      # Set the disposition label AND remove every OTHER disposition label in the same edit, so the
      # "exactly one disposition" invariant holds (a single --add-label could otherwise leave two). Read the
      # current labels; remove any disposition label that isn't the one we're setting.
      local -a editargs=(issue edit "$num" -R "$repo" --add-label "$dlabel" --body-file -)
      local curlabels lbl
      curlabels=$(gh_author "$ATOK" issue view "$num" -R "$repo" --json labels -q '.labels[].name' 2>/dev/null) \
        || die "wf.sh issue dispose: could not read issue #$num labels — failing closed"
      while IFS= read -r lbl; do
        [ -n "$lbl" ] || continue
        [ "$lbl" = "$dlabel" ] && continue
        printf '%s' "$lbl" | grep -qE "$DISPO_RE" && editargs+=(--remove-label "$lbl")
      done <<< "$curlabels"
      printf '%s' "$newbody" | gh_author "$ATOK" "${editargs[@]}" \
        || die "wf.sh issue dispose: 'gh issue edit' (label + body-line) failed — failing closed"
      ;;
  esac
  if [ -n "$ATOK" ]; then
    note "ran 'gh issue $verb' on #$num as the $author engineer identity"
  else
    # Ambient fallback (WF_ALLOW_AMBIENT_IDENTITY=1): leave a durable override trail on the issue, mirroring
    # the create/comment path, so an owner-token maintenance write is auditable on the issue itself.
    ambient_override_notice "wf.sh issue $verb" | gh_author "$ATOK" issue comment "$num" -R "$repo" --body-file - >/dev/null 2>&1 \
      || note "WARN: could not post ambient-identity override note to issue #$num (non-fatal; terminal warning already emitted)"
    note "ran 'gh issue $verb' on #$num (ambient token — no engineer identity configured for $author)"
  fi
}

main_checkout(){ git -C "$1" worktree list --porcelain | awk '/^worktree /{print $2; exit}'; }   # 1st worktree = main
wt_pr(){
  local tok=${2:-}
  if [ -n "$tok" ]; then
    GH_TOKEN="$tok" real_gh -R "$(gh_repo "$1")" pr view "$(wt_branch "$1")" --json number -q .number 2>/dev/null
  else
    real_gh -R "$(gh_repo "$1")" pr view "$(wt_branch "$1")" --json number -q .number 2>/dev/null
  fi
}  # PR# for a worktree's branch

doctor_ambient_gh(){  # prints status; returns 0 ok, 1 missing/bad
  local login
  if login=$(real_gh api user --jq .login 2>/dev/null); then
    echo "  ambient gh: ok (login=$login)"; return 0
  fi
  echo "  ambient gh: unavailable (gh auth login or GH_TOKEN needed for ambient fallback)"; return 1
}

doctor_token(){  # doctor_token <family> <repo> <label>; returns 0 ok, 1 missing, 2 configured-but-failing
  local fam=$1 repo=$2 label=$3 tok full
  if [ -z "$(engineer_token_cmd "$fam")" ]; then
    echo "  $label token: missing ($(engineer_token_seam "$fam"))"; return 1
  fi
  if ! tok=$(engineer_token "$fam" 0 2>/dev/null); then
    echo "  $label token: configured but failed to mint ($(engineer_token_seam "$fam"))"; return 2
  fi
  if [ -z "$tok" ]; then
    echo "  $label token: missing ($(engineer_token_seam "$fam"))"; return 1
  fi
  # NEVER send a URL-shaped / credential-bearing value into `gh api repos/<repo>` — it would leak userinfo into
  # the API request + child argv (#166 code-review F1 r18f). Use a CLEAN owner/repo slug only: the value as-is
  # if it's already clean, else a slug derived from a GitHub URL; otherwise skip the API access check.
  local apirepo=""
  if is_clean_repo_slug "$repo"; then apirepo=$repo
  elif is_github_remote_url "$repo"; then apirepo=$(github_repo_slug "$repo"); fi
  if [ -z "$apirepo" ]; then
    # can't verify repo access against a non-clean/non-GitHub target -> do NOT count the token as verified
    # (return 2 = configured-but-unverified, so plain doctor doesn't read READY without a real access check —
    # #166 code-review F2 r18g).
    echo "  $label token: minted but repo-access NOT verified (target is not a bare owner/repo: $(redact_userinfo "$repo"))"; return 2
  fi
  if full=$(GH_TOKEN="$tok" real_gh api "repos/$apirepo" --jq .full_name 2>/dev/null); then
    echo "  $label token: ok (repo access=$full)"; return 0
  fi
  echo "  $label token: minted but cannot access $apirepo"; return 2
}

doctor_git_author(){  # doctor_git_author <author>; returns 0 ok, 1 missing, 2 invalid
  local author=$1 val
  if ! val=$(engineer_git_author "$author" 0 2>/dev/null); then
    echo "  author git identity: configured but invalid (WF_ENGINEER_GIT_AUTHOR_$(family_suffix "$author"))"; return 2
  fi
  if [ -z "$val" ]; then
    echo "  author git identity: missing (WF_ENGINEER_GIT_AUTHOR_$(family_suffix "$author"))"; return 1
  fi
  echo "  author git identity: ok ($(git_author_name "$val") <$(git_author_email "$val")>)"; return 0
}

# ============================================================================================================
# READ-ONLY-AMBIENT DETECTOR (#166, child #2 of #149) — is the AMBIENT GitHub credential read-only?
#
# Certifies a PASS only by PROVENANCE (authoritative granted-permissions with no write/admin category), never
# by enumerating probes (a finite probe set can't prove "no reachable write scope" for an opaque token). Any
# uninspectable/unattested token FAILS CLOSED. An empirical 403/422 denial probe is ADVISORY ONLY — it can
# turn a PASS into a FAIL (422 = definitely write-capable) but a 403 floor never UPGRADES an unattested token
# to PASS. Covers the gh/API surface AND the ambient `git push` surface, per credential SOURCE, and NEVER
# performs a real mutation (the contents probe carries no sha+content; the git probe is --dry-run only).
# ============================================================================================================

# redact_userinfo <string> — strip a `user:secret@` userinfo segment from any URL-shaped value so a
# credential-bearing remote never leaks its token into doctor/CI logs (#166 F1 r13). Covers BOTH the `://…@`
# URL form AND the scp-style `[user[:secret]@]host:path` form (no scheme — #166 code-review F1 r18g).
redact_userinfo(){
  printf '%s' "$1" \
    | sed -E 's#(://)[^/@[:space:]]+@#\1<redacted>@#g' \
    | sed -E 's#(^|[[:space:]])[^/@:[:space:]]+:[^/@[:space:]]+@([^/[:space:]]+:)#\1<redacted>@\2#g'
}

# url_host <url> — extract the TRUE authority host from a remote URL, correctly (not a glob). The authority is
# the segment after `://` up to the first `/`, `?`, or `#`; userinfo is everything up to the LAST `@` WITHIN
# that authority (userinfo cannot contain `/`); the host is the authority minus userinfo minus any `:port`.
# For scp-style `user@host:path`, the host is between the (optional) `user@` and the first `:`. Prints the host
# (lowercased) or empty. This is the load-bearing anti-spoof: `https://evil.example/path@github.com/o/r` has
# authority `evil.example` (the `@github.com/…` is PATH, not host), so this returns evil.example, NOT github.com
# (#166 code-review F1 r16b).
url_host(){
  local u=$1 auth host
  case "$u" in
    *://*)
      auth=${u#*://}            # strip scheme
      auth=${auth%%/*}          # authority = up to first '/'
      auth=${auth%%\?*}; auth=${auth%%#*}
      auth=${auth##*@}          # drop userinfo (everything up to the LAST '@' in the authority)
      host=${auth%%:*}          # drop :port
      ;;
    *@*:*)                       # scp-style user@host:path
      host=${u#*@}; host=${host%%:*} ;;
    *:*)                         # scp-style host:path (no user)
      host=${u%%:*} ;;
    *) host="" ;;
  esac
  printf '%s' "$host" | tr '[:upper:]' '[:lower:]'
}

# is_github_remote_url <url> — true ONLY if the URL's TRUE authority host is EXACTLY github.com or
# ssh.github.com (parsed, not glob-matched), closing the `…@github.com/…`-in-path spoof (#166 F1 r16b).
is_github_remote_url(){
  local h; h=$(url_host "$1")
  [ "$h" = github.com ] || [ "$h" = ssh.github.com ]
}

# github_repo_slug <github-url> — extract the bare `owner/repo` from a (already GitHub-validated) remote URL of
# any form (https://github.com/o/r[.git], git@github.com:o/r[.git], ssh://git@github.com/o/r[.git]). Prints the
# slug or empty. Used to synthesize the canonical probe URLs when the caller's repo value is URL-shaped (#166 r18e).
github_repo_slug(){
  local u=$1 path
  case "$u" in
    *://*) path=${u#*://}; path=${path%%\?*}; path=${path%%#*}; path=${path#*/} ;;  # after authority
    *:*)   path=${u#*:} ;;                                                          # scp-style host:path
    *)     path=$u ;;
  esac
  path=${path%.git}; path=${path#/}
  # REJECT (don't truncate) anything that isn't exactly owner/repo — silently truncating an extra-segment URL
  # could make the detector probe a DIFFERENT repo than the supplied remote (#166 code-review F3 r18h). ALWAYS
  # return 0 (empty output on rejection) so a bare `slug=$(github_repo_slug …)` assignment can't trip `set -e`
  # (#166 code-review r18i) — callers handle the empty value explicitly.
  if is_clean_repo_slug "$path"; then printf '%s' "$path"; fi
  return 0
}

# is_clean_repo_slug <s> — true ONLY for a well-formed bare `owner/repo`: exactly one slash, BOTH components
# non-empty, the GitHub-name charset ([A-Za-z0-9._-]) only, and NEITHER component is `.`/`..` (path traversal).
# So `/repo`, `owner/`, `../user`, `a/b/c`, and URL-shaped values are all rejected — a value used in a
# `gh api repos/<slug>` path or a synthesized push URL is always a real owner/repo (#166 code-review F1 r18h).
is_clean_repo_slug(){
  local s=$1 owner repo
  case "$s" in
    */*/*) return 1 ;;                    # more than one slash
    */*) owner=${s%%/*}; repo=${s#*/} ;;  # exactly one slash
    *) return 1 ;;                        # no slash
  esac
  [ -n "$owner" ] && [ -n "$repo" ] || return 1
  case "$owner" in ""|.|..|*[!A-Za-z0-9._-]*) return 1 ;; esac
  case "$repo"  in ""|.|..|*[!A-Za-z0-9._-]*) return 1 ;; esac
  return 0
}

readonly_token_cmd(){ echo "${WF_READONLY_TOKEN_CMD:-}"; }            # the instance read-only minter seam
readonly_token_info_cmd(){ echo "${WF_READONLY_TOKEN_INFO_CMD:-}"; }  # its paired machine-verifiable perms

# perms_has_write <json> — true (returns 0) if a GitHub-permissions JSON object is NOT provably read-only.
# READ-ONLY ALLOWLIST (fail-closed, #166 code-review F1): a token is read-only IFF EVERY permission value is
# EXACTLY "read" or "none". ANY other value — "write", "admin", "maintain", "triage", a future write-ish
# level, OR a non-string value — counts as write (we never enumerate write levels; we allowlist the two safe
# ones and fail toward write on everything else). Unparseable / missing python3 also fails toward write.
perms_has_write(){
  local json=$1
  command -v python3 >/dev/null 2>&1 || { return 0; }   # can't parse -> can't certify read-only -> treat as write
  python3 - "$json" <<'PY'
import json,sys
raw=sys.argv[1]
try:
    obj=json.loads(raw)
except Exception:
    sys.exit(0)  # unparseable -> cannot certify read-only -> "has write" (fail toward write)
perms = obj.get("permissions", obj) if isinstance(obj, dict) else obj
if not isinstance(perms, dict) or not perms:
    sys.exit(0)  # no readable permission map -> cannot certify read-only -> fail toward write
for v in perms.values():
    # ALLOWLIST: only an exact-string "read"/"none" is safe; anything else (incl. non-string) is write.
    if not (isinstance(v, str) and v.lower() in ("read", "none")):
        sys.exit(0)   # a non-allowlisted permission value -> treat as write
sys.exit(1)           # every value is read/none -> read-only
PY
}

# readonly_provenance_verdict <token> — classify a token's read-only-ness AUTHORITATIVELY. Prints a one-word
# verdict on stdout: "readonly" | "write" | "unprovable". Uses, in order:
#   (1) GitHub App installation-token permissions — `gh api installation/repositories`? No: the granted set is
#       on the token itself. We read it via `gh api -H 'Authorization: token <t>' rate_limit`? No — the
#       authoritative source is the installation token's own metadata, exposed at the `/installation` resource
#       for the App-auth context. We fetch the App installation permissions the token carries.
#   (2) the read-only minter's paired token-info command (machine-verifiable perms tied to THIS token).
# Anything else -> "unprovable" (FAIL CLOSED). Never mutates (all GETs).
readonly_provenance_verdict(){
  local tok=$1 info_cmd perms_json
  # (1) GitHub App installation token: its granted permissions are returned by GET /installation? The
  #     canonical authoritative read is the App installation's permissions object. For an installation token,
  #     `gh api /installation/permissions`-style endpoints are not public, but the installation's permissions
  #     are echoed on the token-mint response. We can't re-mint here; instead we read the permissions the
  #     INSTANCE attests via the paired info command (the only machine-verifiable provenance available to a
  #     detector that did not itself mint the token). So provenance flows through the info-command seam.
  info_cmd=$(readonly_token_info_cmd)
  if [ -n "$info_cmd" ]; then
    # the info command emits canonical permissions JSON for the token on its stdin (so it can verify the perms
    # are tied to THIS token, not a generic claim). BOUND it with `timeout` so a hanging instance seam can't
    # hang doctor (#166 code-review F2 r17b); fail closed (unprovable) if it errors, times out, or emits nothing.
    local to=${WF_GIT_PROBE_TIMEOUT:-20}
    if perms_json=$(printf '%s' "$tok" | timeout "$to" bash -c "$info_cmd" 2>/dev/null) && [ -n "$perms_json" ]; then
      if perms_has_write "$perms_json"; then echo write; else echo readonly; fi
      return 0
    fi
    echo unprovable; return 0
  fi
  # No paired info command: try the GitHub App installation-token self-describing path. A `gh api` GET that
  # echoes the token's own granted permissions is `GET /` with the token? GitHub does NOT return granted scope
  # for an opaque PAT, and a fine-grained PAT's scope is not machine-readable via the API. So with no info
  # seam we cannot authoritatively confirm read-only-ness -> FAIL CLOSED.
  echo unprovable
}

# readonly_advisory_probe <token> <repo> — ADVISORY ONLY. Sends a PATCH /repos/{owner}/{repo} with an EMPTY
# JSON object body ({}). PROVEN non-mutating against a live disposable repo (see proposals/166 PR evidence):
# with an empty object GitHub validates permission and returns 200 echoing the repo object WITHOUT changing any
# field (updated_at unchanged), so a write-capable token -> 200 ("writable" signal) and a read-only / no-access
# token -> 403 or 404 ("denied"); NEITHER mutates the repo. Prints "denied" | "writable" | "inconclusive".
# NEVER the certifier — provenance is the gate; this only sharpens the message (a "writable" can turn a PASS
# into a FAIL, a "denied" never UPGRADES an unattested token to PASS).
readonly_advisory_probe(){
  local tok=$1 repo=$2 code out to=${WF_GIT_PROBE_TIMEOUT:-20}
  # An empty JSON object body is the load-bearing detail (a NO-body PATCH returns 400 = inconclusive; a body
  # with a -f field could MUTATE). We pipe '{}' via --input - so no settable field is ever supplied. real_gh
  # marker so the guard (if installed) passes this internal call through. CAPTURE the -i output FIRST with its
  # own `|| true` so a non-2xx gh exit (403/404 -> nonzero) does NOT blank the status under `set -o pipefail`
  # (#166 code-review F4) — then parse the HTTP status line. BOUND with `timeout` so a stalled `gh api` can't
  # hang doctor (#166 code-review F1 r12); a timeout -> inconclusive.
  out=$(printf '{}' | timeout "$to" env GH_TOKEN="$tok" WF_GH_INTERNAL=1 gh api -X PATCH "repos/$repo" --input - -i 2>/dev/null || true)
  code=$(printf '%s\n' "$out" | awk 'toupper($1) ~ /^HTTP/ {print $2; exit}')
  case "$code" in
    2*)      echo writable ;;     # GitHub ACCEPTED the (empty, non-mutating) write attempt -> write-capable
    422)     echo writable ;;     # validation-reject AFTER the permission check passed -> write-capable too
    403|404) echo denied ;;       # forbidden / not-visible -> no reachable write on this floor
    *)       echo inconclusive ;; # 400/5xx/garbled -> advisory says nothing (provenance still gates)
  esac
}

# readonly_probe_source <label> <token-or-empty> <repo> — probe ONE credential source in ISOLATION. Prints a
# report line and returns: 0 = authoritatively read-only (PASS), 1 = source absent (skipped), 2 = NOT read-only
# (write-capable or unprovable -> FAIL). The advisory probe only sharpens the message; provenance is the gate.
readonly_probe_source(){
  local label=$1 tok=$2 repo=$3 verdict advisory
  if [ -z "$tok" ]; then echo "    $label: absent (not set)"; return 1; fi
  verdict=$(readonly_provenance_verdict "$tok")
  advisory=""
  # The advisory probe is a LIVE network call; skip it under the no-network mode (WF_DOCTOR_SKIP_LIVE_PROBES=1)
  # so plain `doctor` stays hermetic in smokes. Provenance (the gate) still runs. ALSO require `$repo` to be a
  # CLEAN owner/repo slug — never embed a URL-shaped target (which can carry a userinfo token) into the
  # `gh api repos/<repo>` path, or the token would leak into the API request/logs (#166 code-review F1 r17b).
  if [ "${WF_DOCTOR_SKIP_LIVE_PROBES:-0}" != 1 ] && is_clean_repo_slug "$repo"; then
    advisory=$(readonly_advisory_probe "$tok" "$repo" 2>/dev/null) || advisory=inconclusive
  fi
  case "$verdict" in
    readonly)
      # provenance says read-only; if the advisory probe loudly says writable, that's a contradiction -> FAIL.
      if [ "$advisory" = writable ]; then
        echo "    $label: FAIL (provenance=readonly but advisory probe accepted a write — investigate the attesting seam)"; return 2
      fi
      echo "    $label: read-only (authoritative provenance; advisory=${advisory:-skipped})"; return 0 ;;
    write)
      echo "    $label: FAIL (authoritative provenance shows a write/admin permission; advisory=${advisory:-skipped})"; return 2 ;;
    *)  # unprovable -> FAIL CLOSED. Note the advisory hint but never let a 403 floor upgrade it to PASS.
      echo "    $label: FAIL-CLOSED (read-only-ness not authoritatively confirmable — no WF_READONLY_TOKEN_INFO_CMD provenance; advisory=${advisory:-skipped}, advisory NEVER certifies a PASS)"; return 2 ;;
  esac
}

# readonly_probe_one_push_url <url> [worktree] — `git push --dry-run` ONE url, non-mutating, under an isolated
# config with a read-only credential replay. ASYMMETRIC: sets RO_PUSH_RC=0 only when the dry-run is ACCEPTED
# (the FAIL signal); RO_PUSH_RC=1 for EVERY other outcome (rejected / transport failure / timeout / error) —
# "not demonstrably writable", which is advisory and never a read-only PASS.
RO_PUSH_RC=1
readonly_probe_one_push_url(){
  local url=$1 wt=${2:-} tmp rc to=${WF_GIT_PROBE_TIMEOUT:-20} shim
  RO_PUSH_RC=1
  # the context git uses for resolving the AMBIENT credential: the TARGET WORKTREE when supplied (so its
  # worktree-LOCAL credential config is honored), else the default ctx.
  local credctx=(); [ -n "$wt" ] && [ -d "$wt" ] && credctx=(-C "$wt")
  tmp=$(mktemp -d) || { RO_PUSH_RC=1; return; }
  (
    git -C "$tmp" init -q 2>/dev/null
    # LOCAL commit identity so the probe commit never depends on a global git user.name/email (#166 F2), AND
    # disable HOOKS + SIGNING so a globally-configured core.hooksPath / commit.gpgsign can never run during
    # this supposedly side-effect-free probe (#166 code-review F1 r7).
    git -C "$tmp" -c core.hooksPath=/dev/null -c commit.gpgsign=false \
        -c user.name="wf-doctor" -c user.email="wf-doctor@local" \
        commit -q --no-verify --allow-empty -m probe 2>/dev/null
  ) || { rm -rf "$tmp"; RO_PUSH_RC=1; return; }
  # MUTATION-SAFE credential layer (#166 code-review F1 r8/r9/r10). A successful auth on a `--dry-run` push
  # makes git call the credential helper's `store` (verified empirically), which MUTATES the user's credential
  # store; and git honors URL-SCOPED helpers + helpers WITH ARGUMENTS that hand-rolled shim parsing gets wrong.
  # So instead of re-implementing git's helper resolution, we let GIT ITSELF resolve the ambient credential
  # read-only via `git credential fill` (run in the REAL config — fill performs ONLY the `get` step, never
  # store/erase), then run the dry-run push under an ISOLATED config (no inherited helper can run) with a
  # trivial STATIC helper that just replays that pre-resolved credential for `get` and no-ops store/erase.
  # This both preserves detection (a real ambient credential is found by git's own correct parsing) and makes
  # store/erase impossible.
  shim="$tmp/cred-ro-shim.sh"
  local cred_in cred_out parsed_host parsed_proto parsed_path parsed_user rest push_url
  parsed_proto=${url%%://*}; case "$url" in *://*) : ;; *) parsed_proto=ssh ;; esac
  parsed_user=""
  # Use the PARSED authority host (url_host), never an inline glob-prone parse — so the host handed to
  # credential fill is the URL's TRUE host, and a spoofed `…@github.com/…` path can never coax a github.com
  # credential out for an attacker host (#166 code-review F1 r16b). All `urls` here are already validated as
  # exactly github.com/ssh.github.com, so parsed_host is github.com/ssh.github.com by construction.
  parsed_host=$(url_host "$url"); [ -n "$parsed_host" ] || parsed_host=github.com
  case "$url" in
    https://*)
      rest=${url#https://}
      # userinfo (a username) is BEFORE the first '/' in the authority; extract it from the authority only.
      local authority=${rest%%/*}
      case "$authority" in
        *@*) parsed_user=${authority%@*}; parsed_user=${parsed_user%%:*} ;;  # username, drop any :password
      esac
      parsed_path=${rest#*/}
      [ "$parsed_path" = "$rest" ] && parsed_path=""
      ;;
    *) parsed_path="" ;;
  esac
  # Build a USERINFO-STRIPPED push URL for EVERY accepted GitHub form, so a credential-bearing origin never
  # exposes a secret in the `git push` child argv (#166 code-review F1/F2 r18c). The credential under test is
  # the AMBIENT one (resolved by `git credential fill` + replayed via the shim); a credential EMBEDDED in the
  # remote URL is an explicit, non-ambient credential and is deliberately NOT replayed — the ambient surface is
  # still fully covered because we ALSO probe the synthesized clean github.com URLs. So dropping URL userinfo
  # neither leaks a secret nor weakens the ambient-credential alarm.
  # SSH auth is KEY-based and GitHub REQUIRES the username `git` (it is the literal SSH user, NOT a secret) — so
  # for SSH/scp forms we KEEP the username (defaulting to `git`) and strip only a `:password` if any; dropping
  # the username entirely would make ssh try the local Unix user and false-negative a writable github key (#166
  # code-review F1 r18d). For HTTPS the userinfo IS the credential, so it's fully dropped (cred via the shim).
  local ssh_user
  case "$url" in
    https://*)
      if [ -n "$parsed_path" ]; then push_url="https://${parsed_host}/${parsed_path}"; else push_url="https://${parsed_host}/"; fi ;;
    ssh://*)
      # ssh://[user[:secret]@]host[:port]/path -> ssh://<user>@host[:port]/path (keep user, drop :secret).
      local sshrest=${url#ssh://} sshauth sshport=""
      sshauth=${sshrest%%/*}; local sshpath=${sshrest#*/}; [ "$sshpath" = "$sshrest" ] && sshpath=""
      case "$sshauth" in *@*) ssh_user=${sshauth%@*}; ssh_user=${ssh_user%%:*}; sshauth=${sshauth##*@} ;; *) ssh_user=git ;; esac
      [ -n "$ssh_user" ] || ssh_user=git
      case "$sshauth" in *:*) sshport=":${sshauth#*:}"; sshauth=${sshauth%%:*} ;; esac
      if [ -n "$sshpath" ]; then push_url="ssh://${ssh_user}@${sshauth}${sshport}/${sshpath}"; else push_url="ssh://${ssh_user}@${sshauth}${sshport}/"; fi ;;
    *@*:*)
      # scp-style [user[:secret]@]host:path -> <user>@host:path (keep user, drop ALL userinfo incl. any secret).
      # Rebuild from the host AFTER the userinfo `@`, never from `${url#*:}` (which keeps `secret@host:` when the
      # userinfo carries a password — #166 code-review F2 r18f).
      ssh_user=${url%%@*}; ssh_user=${ssh_user%%:*}; [ -n "$ssh_user" ] || ssh_user=git
      local scp_hostpath=${url##*@}                       # host:path (userinfo dropped)
      push_url="${ssh_user}@${scp_hostpath}" ;;
    *:*)
      # bare scp-style host:path with NO user -> add the required `git@`.
      push_url="git@${url}" ;;
    *) push_url=$url ;;
  esac
  # `git credential fill` resolves the ambient credential using git's OWN rules (handles helpers with args,
  # url-scoped helpers, !-commands) and performs only `get` — no mutation. Run in the TARGET WORKTREE context
  # (credctx) so worktree-local helpers are honored. We DO pass the URL path, but we DON'T force
  # `credential.useHttpPath` — git's DEFAULT path behavior is what a real push uses, so a host-wide
  # credential-store entry is still resolved (the asymmetric design means we only care about the ACCEPTED case;
  # we no longer try to faithfully classify the rejected case, so the host-vs-path tension is moot — #166 r15).
  # Prompts disabled so it can't block; a TIMEOUT just yields an empty cred -> the push will auth-reject ->
  # advisory (no false read-only PASS is possible from this surface).
  cred_in=$(printf 'protocol=%s\nhost=%s\n' "$parsed_proto" "$parsed_host")
  [ -n "$parsed_path" ] && cred_in=$(printf '%s\npath=%s' "$cred_in" "$parsed_path")
  [ -n "$parsed_user" ] && cred_in=$(printf '%s\nusername=%s' "$cred_in" "$parsed_user")
  cred_in=$(printf '%s\n\n' "$cred_in")
  cred_out=$(printf '%s' "$cred_in" | GIT_TERMINAL_PROMPT=0 GIT_ASKPASS=/bin/true \
               timeout "$to" git "${credctx[@]}" credential fill 2>/dev/null || true)
  # build the static get-only replay helper (no-ops store/erase). Only meaningful for the HTTPS surface; SSH
  # auth uses the key, not this helper, and the isolated config + BatchMode handle the SSH side.
  {
    printf '#!/bin/bash\n'
    printf 'op=$1\n'
    printf 'if [ "$op" != get ]; then cat >/dev/null 2>&1 || true; exit 0; fi  # no-op store/erase (never mutate)\n'
    printf 'cat >/dev/null 2>&1 || true\n'
    # replay the pre-resolved credential verbatim (may be empty -> no ambient HTTPS credential -> auth-reject).
    printf 'cat <<'\''WF_CRED_EOF'\''\n%s\nWF_CRED_EOF\n' "$cred_out"
  } > "$shim"
  chmod +x "$shim"
  # Disable every interactive/ambient-helper PROMPT but keep the AMBIENT credential surface reachable for `get`
  # via the read-only shim — that is exactly what we must catch, WITHOUT the store/erase mutation. Bound with
  # `timeout` so a DNS/network/helper stall can never hang doctor (#166 F2).
  # ISOLATE git config (GIT_CONFIG_GLOBAL/SYSTEM -> /dev/null + NOSYSTEM=1) so NO inherited helper — unscoped OR
  # URL-scoped (credential.https://github.com.helper) — runs and writes the store (#166 F1 r9); then install
  # ONLY the read-only shim, which forwards `get` to the snapshotted helpers but no-ops store/erase. The repo's
  # OWN tmp config carries the shim + ssh/hooks settings via -c, which survive the global/system isolation.
  rc=0
  # FULL config isolation: global+system+NOSYSTEM AND GIT_CONFIG_COUNT=0 so inherited env-injected config
  # (GIT_CONFIG_KEY_n/VALUE_n) can't add a credential helper alongside the shim and run store/erase (#166 r18).
  # Reset the helper chain (-c credential.helper=) BEFORE installing ONLY the read-only shim, so nothing else
  # handles store/erase for this push.
  GIT_TERMINAL_PROMPT=0 GIT_ASKPASS=/bin/true SSH_ASKPASS=/bin/true \
        GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_COUNT=0 \
        timeout "$to" git -C "$tmp" -c core.askPass= -c core.hooksPath=/dev/null \
        -c credential.helper= -c "credential.helper=$shim" \
        -c core.sshCommand="ssh -o BatchMode=yes -o ConnectTimeout=$to" \
        push --dry-run --no-verify "$push_url" "HEAD:refs/heads/wf-doctor-readonly-probe-$$" >/dev/null 2>&1 || rc=$?
  rm -rf "$tmp"
  # ASYMMETRIC: ONLY an ACCEPTED dry-run (rc 0) is meaningful -> RC=0 (the caller raises a FAIL). EVERY other
  # outcome — auth rejection, authz denial, pre-auth transport failure, timeout, any error — is simply "not
  # demonstrably writable" -> RC=1 (advisory; never a read-only PASS). We no longer parse rejection messages to
  # tell auth-reject from transport failure, because the caller treats them identically and the surface can
  # never certify read-only anyway. This removes the entire fragile message-pattern classification (#166 r15).
  if [ "$rc" = 0 ]; then RO_PUSH_RC=0; else RO_PUSH_RC=1; fi
}

# readonly_probe_git_push <repo> [worktree-dir] — probe the AMBIENT git-push surface, non-mutating, as a
# ONE-DIRECTIONAL ALARM. Probes the worktree's actual GitHub origin push URL (when given) AND the synthesized
# canonical GitHub HTTPS+SSH URLs. An ACCEPTED `git push --dry-run` -> FAIL (an ambient credential can push);
# anything else is ADVISORY ONLY (this surface NEVER certifies read-only — see the asymmetry rationale below).
# Returns 2 FAIL (accepted), 1 advisory (not demonstrably writable). Never returns a PASS.
readonly_probe_git_push(){
  local repo=$1 wt=${2:-} u urls=() accepted=0 rejected=0 origin_url
  # the actual origin push URL (covers SSH + a non-default push url) when a worktree dir is supplied — but ONLY
  # if it's a real GitHub remote. A non-GitHub / custom-scheme remote could invoke an arbitrary remote-helper,
  # which a GitHub-credential detector must not execute (#166 code-review F2 r12); such an origin is skipped
  # (we still probe the synthesized GitHub URLs below). Mirror git_push_author's GitHub-host allowlist.
  if [ -n "$wt" ] && [ -d "$wt" ]; then
    # ALL push URLs, not just the first — git supports multiple `pushurl`s and a later one could be GitHub
    # (#166 code-review F2 r16). Validate each against a STRICT GitHub-host allowlist that requires a `/` or `:`
    # DELIMITER right after the host, so a homograph/suffix host like `ssh.github.com.evil` or
    # `github.com.evil` is NOT treated as GitHub (#166 code-review F1 r16). A non-GitHub url is skipped (never
    # executed — it could invoke an arbitrary remote helper) and its raw text is never echoed (userinfo leak).
    local nongithub_seen=0
    while IFS= read -r origin_url; do
      [ -n "$origin_url" ] || continue
      # PARSED host check (not a glob) — closes the `https://evil/path@github.com/…` authority spoof (#166 r16b).
      if is_github_remote_url "$origin_url"; then urls+=("$origin_url"); else nongithub_seen=1; fi
    done < <(git -C "$wt" remote get-url --push --all origin 2>/dev/null || true)
    [ "$nongithub_seen" = 1 ] && echo "    ambient git push: note — a worktree origin push URL is not a GitHub remote; skipped (its URL is not echoed; a non-GitHub remote helper is not executed). Probing synthesized GitHub URLs only."
  fi
  # always include BOTH synthesized canonical surfaces for a real owner/repo — HTTPS AND SSH — so an ambient
  # SSH key that can push is probed even when no worktree origin was supplied (#166 code-review F1 r4: an
  # owner/repo-only target must never PASS the git surface on HTTPS alone while an ambient SSH key can push).
  # ONLY synthesize from a CLEAN owner/repo (one slash, no scheme/userinfo/host/colon) — a `repo` that is
  # actually a full URL (e.g. when a worktree has a non-GitHub origin) must NOT be embedded in a synthesized URL
  # (it could carry a userinfo token, #166 code-review F1 r13).
  # Determine the owner/repo SLUG to synthesize the canonical HTTPS+SSH probes from. Prefer the passed-in
  # `$repo` when it's already a clean owner/repo; otherwise — when it's URL-shaped (e.g. gh_repo returned a URL
  # for a worktree origin) — DERIVE a clean slug from the FIRST allowlisted GitHub origin URL's path, so the
  # OTHER canonical surface (e.g. SSH when the origin is HTTPS) is still probed (#166 code-review F1 r18e).
  local slug=""
  if is_clean_repo_slug "$repo"; then
    slug=$repo
  elif [ "${#urls[@]}" -gt 0 ]; then
    slug=$(github_repo_slug "${urls[0]}")
  fi
  if [ -n "$slug" ] && is_clean_repo_slug "$slug"; then
    urls+=("https://github.com/$slug.git"); urls+=("git@github.com:$slug.git")
  fi
  # de-dup so the same canonical URL isn't probed twice (origin may equal a synthesized form).
  if [ "${#urls[@]}" -gt 0 ]; then
    local -a uniq=(); local seen
    for u in "${urls[@]}"; do
      seen=0; for s in "${uniq[@]:-}"; do [ "$s" = "$u" ] && { seen=1; break; }; done
      [ "$seen" = 0 ] && uniq+=("$u")
    done
    urls=("${uniq[@]}")
  fi
  if [ "${#urls[@]}" = 0 ]; then echo "    ambient git push: no GitHub remote to probe (advisory; provenance is the gate)"; return 1; fi
  for u in "${urls[@]}"; do
    readonly_probe_one_push_url "$u" "$wt"
    case "$RO_PUSH_RC" in
      0) accepted=$((accepted+1)) ;;
      *) rejected=$((rejected+1)) ;;   # auth-rejected OR inconclusive — both are merely "not demonstrably writable"
    esac
  done
  # ASYMMETRIC by design (#166 code-review r15, confirmed cross-family): faithfully proving "a real push would
  # be REJECTED" from a synthetic, non-mutating env is structurally leaky (credential helpers, useHttpPath
  # host-vs-path scoping, url.insteadOf, http.extraHeader, ssh config, …) — every attempt to make the negative
  # faithful either inherits a side effect or diverges from a real push. So the git-push surface is a
  # ONE-DIRECTIONAL ALARM: an ACCEPTED dry-run is a hard FAIL (ambient push auth was demonstrably accepted);
  # ANYTHING ELSE is ADVISORY ONLY and never contributes a read-only PASS. The categorical read-only PASS rests
  # solely on API PROVENANCE. This makes the synthetic-env false-PASS class structurally impossible (the probe
  # can only ADD a failure signal, never remove one).
  if [ "$accepted" -gt 0 ]; then
    echo "    ambient git push: FAIL (--dry-run was ACCEPTED on a probed GitHub remote — an ambient credential can push; --dry-run did NOT update the remote)"; return 2
  fi
  echo "    ambient git push: no ambient push credential was accepted (advisory — this surface only ever raises a FAIL; the read-only PASS is decided by API provenance, never by this probe)"; return 1
}

# doctor_readonly_section <repo> — print the read-only-ambient report for ALL sources + the git surface.
# Returns 0 iff EVERY present API source is authoritatively read-only AND the git surface is read-only (or
# inconclusive is treated as NOT-PASS under strict). Sets DOCTOR_RO_FAIL=1 on any FAIL/FAIL-CLOSED.
DOCTOR_RO_FAIL=0
doctor_readonly_section(){
  local repo=$1 wt=${2:-} strict=${3:-0} any_present=0 rc gitrc minted minted_verdict
  DOCTOR_RO_FAIL=0
  echo "  read-only ambient credential (#166):"
  # --- API surface, per SOURCE in isolation -------------------------------------------------------------
  # GH_TOKEN
  if [ -n "${GH_TOKEN:-}" ]; then
    any_present=1
    rc=0; readonly_probe_source "GH_TOKEN" "${GH_TOKEN:-}" "$repo" || rc=$?
    [ "$rc" = 2 ] && DOCTOR_RO_FAIL=1
  else
    echo "    GH_TOKEN: absent (not set)"
  fi
  # GITHUB_TOKEN
  if [ -n "${GITHUB_TOKEN:-}" ]; then
    any_present=1
    rc=0; readonly_probe_source "GITHUB_TOKEN" "${GITHUB_TOKEN:-}" "$repo" || rc=$?
    [ "$rc" = 2 ] && DOCTOR_RO_FAIL=1
  else
    echo "    GITHUB_TOKEN: absent (not set)"
  fi
  # stored `gh auth` credential: read its token via the real gh (marker bypasses the guard), in ISOLATION
  # from the env tokens (clear GH_TOKEN/GITHUB_TOKEN for this read so we get the STORED credential, not env).
  local stored_tok
  stored_tok=$(env -u GH_TOKEN -u GITHUB_TOKEN WF_GH_INTERNAL=1 gh auth token 2>/dev/null || true)
  if [ -n "$stored_tok" ]; then
    any_present=1
    rc=0; readonly_probe_source "stored gh auth" "$stored_tok" "$repo" || rc=$?
    [ "$rc" = 2 ] && DOCTOR_RO_FAIL=1
  else
    echo "    stored gh auth: absent (no gh auth login credential)"
  fi
  # --- the read-only minter seam itself (if wired): confirm it yields an authoritative read-only token -----
  if [ -n "$(readonly_token_cmd)" ]; then
    # BOUND the minter with `timeout` so a hanging instance seam can't hang doctor (#166 F2 r17b).
    if minted=$(timeout "${WF_GIT_PROBE_TIMEOUT:-20}" bash -c "$(readonly_token_cmd)" 2>/dev/null) && [ -n "$minted" ]; then
      minted_verdict=$(readonly_provenance_verdict "$minted")
      case "$minted_verdict" in
        readonly) echo "    WF_READONLY_TOKEN_CMD: ok (mints an authoritatively read-only token)" ;;
        write)    echo "    WF_READONLY_TOKEN_CMD: FAIL (mints a WRITE-capable token)"; DOCTOR_RO_FAIL=1 ;;
        *)        echo "    WF_READONLY_TOKEN_CMD: FAIL-CLOSED (minted token's read-only-ness not authoritatively confirmable — wire WF_READONLY_TOKEN_INFO_CMD)"; DOCTOR_RO_FAIL=1 ;;
      esac
    else
      echo "    WF_READONLY_TOKEN_CMD: FAIL (configured but produced no token)"; DOCTOR_RO_FAIL=1
    fi
  else
    echo "    WF_READONLY_TOKEN_CMD: not configured (instance has not wired the read-only minter seam)"
  fi
  # --- ambient git-push surface (ASYMMETRIC ALARM) -----------------------------------------------------------
  # This surface only ever ADDS a FAIL (a demonstrably-accepted push); it NEVER grants the read-only PASS (that
  # is API provenance). So a SKIPPED git probe — no-network mode, or no target — is NOT a fail-closed condition:
  # it just means "this advisory alarm didn't run", and the provenance gate stands on its own. (#166 r15)
  if [ "${WF_DOCTOR_SKIP_LIVE_PROBES:-0}" = 1 ]; then
    echo "    ambient git push: skipped (WF_DOCTOR_SKIP_LIVE_PROBES=1 — no-network mode; advisory alarm only)"
  elif [ -n "$repo" ] || [ -n "$wt" ]; then
    gitrc=0; readonly_probe_git_push "$repo" "$wt" || gitrc=$?
    [ "$gitrc" = 2 ] && DOCTOR_RO_FAIL=1   # ONLY a demonstrably-accepted push fails closed
  else
    echo "    ambient git push: skipped (no repo target; advisory alarm only)"
  fi
  if [ "$any_present" = 0 ]; then
    echo "    (no ambient API credential present in this shell — nothing to certify; that is itself read-only-by-absence on the API surface)"
  fi
  [ "$DOCTOR_RO_FAIL" = 0 ]
}

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

# resolve a fresh token for the REVIEWER identity (opposite family from the author), used to post cross-family
# reviews/comments. Callers pass required=1 on protected workflow writes unless WF_ALLOW_AMBIENT_IDENTITY=1
# explicitly opts into ambient fallback; configured-but-failing commands always fail closed.
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
  # Any posted workflow review/comment should use the opposite-family engineer identity by default, not the
  # ambient owner account. WF_ALLOW_AMBIENT_IDENTITY=1 is the explicit permissive escape hatch.
  ambient_identity_allowed || require_reviewer=1
  if [ -n "$pr" ]; then
    rtok=$(reviewer_token "$author" "$require_reviewer")
    if [ -z "$rtok" ]; then
      ambient_identity_note "$mode review for PR #$pr (missing reviewer $(engineer_token_seam "$(opposite_family "$author")"))"
      need_ambient_gh
    fi
  fi
  note "$mode review (author=$author, reviewer=opposite family; quiet for several minutes can be normal; findings appear atomically at completion)…"
  local audit_env=()
  while IFS= read -r -d '' item; do audit_env+=("$item"); done < <(review_audit_env "$author" "${AUDIT_CONSTITUTION:-$wt/AGENTS.md}")
  # disposition-aware review (#139): if this PR has finding-disposition state, hand the reviewer the state so
  # it suppresses validly-dispositioned prior findings. No state -> stateless review (today's behavior).
  if { [ "$mode" = --scaffold ] || [ "$mode" = --code ]; } && [ -n "$pr" ]; then
    local fd_repo; fd_repo=$(gh_repo "$wt")
    local fdrc; if fd_active "$fd_repo" "$pr" "$rtok"; then fdrc=0; else fdrc=$?; fi   # if-form: set -e safe on rc 1/2
    # A lookup error on the APPROVING merge-gate review must fail closed (don't silently drop to stateless).
    [ "$fdrc" = 2 ] && [ "$approving" = 1 ] && die "disposition-state lookup failed (GitHub error) during the merge-gate review — failing closed; re-run finish"
    if [ "$fdrc" = 0 ]; then
      local fd_file
      if fd_file=$(fd_load "$wt" "$fd_repo" "$pr" "$rtok"); then
        audit_env+=("DISPOSITION_FILE=$fd_file")
        # #140: if a fresh-eyes sweep artifact exists for this branch, hand it to the reviewer for SEMANTIC
        # adjudication (surface any HIGH not covered by a disposition). FRESH_SWEEP_FILE was cleared from the
        # inherited env by review_audit_env, so it is only ever the trusted finish-produced artifact.
        # Only the APPROVING merge-gate review (approving=1) adjudicates the fresh sweep — and finish produces a
        # current artifact immediately before it. A non-final review must never pick up a stale wf_fresh.
        local fresh_art; fresh_art="${TMPDIR:-/tmp}/wf_fresh_$(wt_branch "$wt" | tr '/' '_').md"
        [ "$approving" = 1 ] && [ -f "$fresh_art" ] && audit_env+=("FRESH_SWEEP_FILE=$fresh_art")
        note "disposition-aware: $(jq '[.findings[]|select(.status!="unresolved")]|length' "$fd_file" 2>/dev/null)/$(jq '.findings|length' "$fd_file" 2>/dev/null) findings dispositioned$([ -f "$fresh_art" ] && echo "; +fresh-sweep adjudication")"
      else
        note "WARN: disposition state present but corrupt JSON — this review runs stateless (finish will fail closed)"
      fi
    fi
  fi
  env "${audit_env[@]}" bash "$audit" "$mode" "$target" "$wt" "$rev" >/dev/null 2>"$rev.run.log" \
    || { echo "BLOCKED: reviewer process failed — tail of log:" >&2; tail -8 "$rev.run.log" >&2; exit 1; }
  require_valid_review "$rev"
  local review_med review_low
  REVIEW_HIGH=$(count_high "$rev"); review_med=$(count_med "$rev"); review_low=$(count_low "$rev"); REVIEW_ALL=$(count_all "$rev")
  note "$mode verdict: $REVIEW_ALL finding(s), $REVIEW_HIGH HIGH -> $rev"
  [ -n "$pr" ] || { note "no PR yet — $mode review NOT posted (verdict above; $rev)"; return 0; }
  local repo body review_text; repo=$(gh_repo "$wt"); review_text=$(cat "$rev")
  body=$( { printf '## %s\n\n%s\n\n' "$heading" "$(review_summary_text "$REVIEW_HIGH" "$review_med" "$review_low" "$approving")"; markdown_code_details "Full review details" "$review_text"; } )
  # #143: stamp gate-relevant reviewer reviews with a hidden, machine-readable marker so the disposition gate
  # can recover this trusted findings list from GitHub (durable) instead of /tmp. pk = the disposition gate's
  # PRIORREV key (code|scaffold); the fresh-eyes sweep carries a DISTINCT marker so it is never trusted.
  local pk=""; case "$mode" in --code) pk=code;; --scaffold) pk=scaffold;; esac
  [ -n "$pk" ] && body=$(printf '%s pk=%s sha=%s -->\n%s' "$FD_REVIEW_MARKER" "$pk" "$(git -C "$wt" rev-parse HEAD)" "$body")
  if [ -z "$rtok" ] && ambient_identity_allowed; then
    body=$( { ambient_override_notice "$mode review for PR #$pr"; printf '\n\n%s' "$body"; } )
  fi
  # The reviewer identity attributes its output to the opposite-family engineer — a NATIVE review for --code,
  # AND for --scaffold WHEN it is the merge gate (approving=1, i.e. `finish --design`) so the design approval
  # is a real native APPROVE branch protection accepts. An interim --scaffold (design-review, approving=0)
  # stays a COMMENT via the elif below. Missing reviewer identity reaches the ambient fallback only when
  # WF_ALLOW_AMBIENT_IDENTITY=1 was explicitly set; otherwise reviewer_token failed closed above.
  if { [ "$mode" = --code ] || { [ "$mode" = --scaffold ] && [ "$approving" = 1 ]; }; } && [ -n "$rtok" ]; then
    local event sha; sha=$(git -C "$wt" rev-parse HEAD)
    if [ "$approving" = 1 ] && [ "$REVIEW_HIGH" = 0 ]; then event=APPROVE              # finish gate, clean -> APPROVE
    elif [ "$REVIEW_HIGH" != 0 ]; then event=REQUEST_CHANGES                           # any blocking finding
    else event=COMMENT; fi                                                             # clean interim -> comment, not approve
    # Bind the review to the EXACT reviewed SHA via commit_id (F1): if the head advanced since we checked it,
    # the approval is for the OLD sha -> won't satisfy branch protection on the new head -> merge blocked (safe).
    # GitHub also rejects self-approval; reviewer identity == author errors here -> we fail closed (loud).
    GH_TOKEN="$rtok" real_gh api -X POST "repos/$repo/pulls/$pr/reviews" \
        -f commit_id="$sha" -f event="$event" -f body="$body" >/dev/null \
      || die "could not post the native $event review (commit $sha) to PR #$pr as the reviewer identity — failing closed (verdict: $REVIEW_ALL findings, $REVIEW_HIGH HIGH; see $rev)"
    note "posted NATIVE review ($event @ ${sha:0:8}) to PR #$pr as the reviewer identity"
  elif [ -n "$rtok" ]; then
    # --scaffold (or any non-code): a COMMENT attributed to the reviewer identity (so the design review reads
    # as the bot, not the author's token).
    echo "$body" | GH_TOKEN="$rtok" real_gh -R "$repo" pr comment "$pr" --body-file - >/dev/null \
      || die "could not post the $mode review comment to PR #$pr as the reviewer identity — failing closed (see $rev)"
    note "posted $mode review COMMENT to PR #$pr as the reviewer identity"
  else
    # no reviewer identity configured (unenforced fallback / unsupported direction): comment under the default token
    echo "$body" | real_gh -R "$repo" pr comment "$pr" --body-file - >/dev/null \
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

dispositions)  # wf.sh dispositions — print close-gate disposition labels (introspection/test)
  sed -E 's/^\^\((.*)\)\$/\1/' <<<"$DISPO_RE" | tr '|' '\n'
  ;;

install-gh-guard)  # wf.sh install-gh-guard [bindir] [--force] — put the gh write-guard wrapper ahead of gh on PATH (#165)
  BIND=""; FORCE=0
  for a in "$@"; do case "$a" in --force) FORCE=1;; *) [ -z "$BIND" ] && BIND=$a;; esac; done
  BIND=${BIND:-$HOME/.local/bin}
  GUARD="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/gh-guard.sh"
  [ -f "$GUARD" ] || die "guard wrapper not found at $GUARD"
  command -v gh >/dev/null || die "no real gh on PATH to guard — install gh first"
  REALGH=$(command -v gh)
  # If `gh` already resolves to $BIND/gh, distinguish two cases: (a) it's ALREADY this guard -> a re-install is
  # idempotent (fall through to the symlink check below); (b) it's some OTHER gh in $BIND -> reject, since we
  # can't see the real gh behind it (#165 review F2).
  if [ "$REALGH" = "$BIND/gh" ]; then
    if [ -L "$BIND/gh" ] && guard_symlink_matches "$BIND/gh" "$GUARD"; then
      note "gh write-guard already installed + active at $BIND/gh (idempotent re-install)"
    else
      die "real gh resolves to $REALGH (inside the install dir) and is NOT this guard — point install-gh-guard at a DIFFERENT bindir that sits EARLIER on PATH than the real gh"
    fi
  fi
  mkdir -p "$BIND" || die "could not create bindir $BIND"
  # Refuse to clobber an EXISTING $BIND/gh that isn't already this guard's symlink (it could be a real gh
  # binary or a different tool the operator put there) — mirror uninstall's safety. --force overrides (#165 review F2).
  if [ -e "$BIND/gh" ] || [ -L "$BIND/gh" ]; then
    if [ -L "$BIND/gh" ] && guard_symlink_matches "$BIND/gh" "$GUARD"; then
      : # already our guard symlink — idempotent re-install is fine
    elif [ "$FORCE" = 1 ]; then
      note "WARN: --force overwriting existing $BIND/gh (was: $(readlink -f "$BIND/gh" 2>/dev/null || echo "$BIND/gh"))"
    else
      die "$BIND/gh already exists and is NOT this guard (it may be a real gh or another tool) — refusing to overwrite. Re-run with --force to replace it, or choose a different bindir."
    fi
  fi
  ln -sf "$GUARD" "$BIND/gh" || die "could not symlink the guard into $BIND/gh"
  note "installed gh write-guard: $BIND/gh -> $GUARD"
  case ":$PATH:" in
    *":$BIND:"*)
      if [ "$(command -v gh)" = "$BIND/gh" ]; then
        note "active: \`gh\` now resolves to the guard. Reads pass through; bare writes are redirected to wf.sh."
      else
        note "WARN: $BIND is on PATH but $REALGH still resolves FIRST — move $BIND earlier on PATH for the guard to take effect."
      fi
      ;;
    *) note "NEXT: add $BIND to the FRONT of PATH (e.g. export PATH=\"$BIND:\$PATH\") so the guard resolves before the real gh." ;;
  esac
  note "undo: wf.sh uninstall-gh-guard $BIND   (the guard is an ergonomic redirect — the read-only ambient credential is the real boundary)"
  ;;

uninstall-gh-guard)  # wf.sh uninstall-gh-guard [bindir] — remove the gh write-guard wrapper (#165)
  BIND=${1:-$HOME/.local/bin}
  GUARD="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/gh-guard.sh"
  if [ -L "$BIND/gh" ] && guard_symlink_matches "$BIND/gh" "$GUARD"; then
    rm -f "$BIND/gh" && note "removed gh write-guard symlink $BIND/gh"
  elif [ -e "$BIND/gh" ]; then
    die "$BIND/gh exists but is not this guard's symlink — refusing to remove it (remove it by hand if intended)"
  else
    note "no gh write-guard symlink at $BIND/gh — nothing to remove"
  fi
  ;;

locate-audit)  # wf.sh locate-audit [context-repo] — print the verify-claims reviewer wf.sh would run (introspection/test)
  locate_audit "${1:-}" ;;

doctor)  # wf.sh doctor <author> [repo-or-worktree] [--readonly] — report lifecycle identity readiness without printing tokens.
  # --readonly: run ONLY the read-only-ambient detector (#166) and EXIT NON-ZERO on any FAIL/FAIL-CLOSED —
  # the machine-consumable form rollout + CI invoke. Plain `doctor` prints the read-only section as a labeled
  # reporter but does not fold it into the identity-readiness exit code (one explicit gate, not two semantics).
  need_gh
  RO_ONLY=0; DARGS=()
  for a in "$@"; do case "$a" in --readonly) RO_ONLY=1 ;; *) DARGS+=("$a") ;; esac; done
  set -- "${DARGS[@]}"
  AUTHOR=${1:?usage: wf.sh doctor <claude|codex> [repo-or-worktree] [--readonly]}; TARGET=${2:-$ORIGIN_REPO}
  check_author "$AUTHOR"
  DWT=""   # the worktree DIR (if TARGET is a dir) so the git-push probe can read the ACTUAL origin push url
  if [ -d "$TARGET" ]; then
    DREPO=$(gh_repo "$TARGET" 2>/dev/null) || die "doctor target is a directory but not a git repo/worktree with an origin remote: $TARGET (pass owner/repo instead)"
    DWT=$TARGET
  else
    DREPO=$TARGET
  fi
  # --readonly: the strict, machine-consumable detector. Run ONLY the read-only-ambient section and exit
  # non-zero on any FAIL/FAIL-CLOSED — the form rollout + CI invoke (#166 design-review F1).
  if [ "$RO_ONLY" = 1 ]; then
    echo "wf.sh doctor --readonly"
    echo "  repo: $(redact_userinfo "$DREPO")"
    if doctor_readonly_section "$DREPO" "$DWT" 1; then
      echo "READONLY-PASS: every ambient API credential source is authoritatively read-only by provenance, and no ambient push credential was demonstrably accepted"
    else
      echo "READONLY-FAIL: the ambient credential is NOT authoritatively read-only (see FAIL/FAIL-CLOSED lines above) — demote the ambient credential / wire WF_READONLY_TOKEN_CMD+WF_READONLY_TOKEN_INFO_CMD"
      exit 1
    fi
    exit 0
  fi
  REVIEWER=$(opposite_family "$AUTHOR")
  echo "wf.sh doctor"
  echo "  author: $AUTHOR"
  echo "  reviewer: $REVIEWER"
  echo "  repo: $(redact_userinfo "$DREPO")"
  if ambient_identity_allowed; then
    echo "  ambient workflow fallback: ENABLED (WF_ALLOW_AMBIENT_IDENTITY=1)"
  else
    echo "  ambient workflow fallback: disabled (strict engineer identity default)"
  fi
  ambient_rc=0; doctor_ambient_gh || ambient_rc=$?
  author_tok_rc=0; doctor_token "$AUTHOR" "$DREPO" "author engineer" || author_tok_rc=$?
  reviewer_tok_rc=0; doctor_token "$REVIEWER" "$DREPO" "reviewer engineer" || reviewer_tok_rc=$?
  git_author_rc=0; doctor_git_author "$AUTHOR" || git_author_rc=$?
  model_rc=0
  if [ "$AUTHOR" = codex ]; then
    if [ -z "${AUDIT_VERIFIER_CMD:-}" ]; then
      echo "  model reviewer: missing (AUDIT_VERIFIER_CMD required for Codex-authored --scaffold/--code reviews)"
      model_rc=1
    elif is_claude_verifier_cmd "$AUDIT_VERIFIER_CMD"; then
      echo "  model reviewer: ok (AUDIT_VERIFIER_CMD is Claude-family for Codex-authored reviews)"
    else
      echo "  model reviewer: invalid (AUDIT_VERIFIER_CMD must be Claude-family for Codex-authored reviews)"
      model_rc=1
    fi
  else
    if command -v codex >/dev/null 2>&1; then
      echo "  model reviewer: ok (default Codex reviewer is on PATH for Claude-authored reviews)"
    else
      echo "  model reviewer: missing (default Codex reviewer not on PATH for Claude-authored reviews)"
      model_rc=1
    fi
  fi
  ready=1
  if ambient_identity_allowed; then
    [ "$ambient_rc" = 0 ] || ready=0
    [ "$author_tok_rc" != 2 ] || ready=0
    [ "$reviewer_tok_rc" != 2 ] || ready=0
    [ "$git_author_rc" != 2 ] || ready=0
  else
    [ "$author_tok_rc" = 0 ] || ready=0
    [ "$reviewer_tok_rc" = 0 ] || ready=0
    [ "$git_author_rc" = 0 ] || ready=0
  fi
  [ "$model_rc" = 0 ] || ready=0
  # Read-only-ambient detector (#166) — printed as a LABELED REPORTER. Deliberately NOT folded into the
  # identity-readiness exit code (the strict gate is `wf.sh doctor <author> [repo] --readonly`); this keeps a
  # single exit-code semantics for plain doctor (identity readiness) and one explicit gate for the read-only
  # contract (#166 design-review F1).
  doctor_readonly_section "$DREPO" "$DWT" || true
  RDREPO=$(redact_userinfo "$DREPO")   # redact userinfo in the displayed command hints too (#166 F1 r14)
  if [ "$DOCTOR_RO_FAIL" = 0 ]; then
    echo "  read-only ambient verdict: PASS (run \`wf.sh doctor $AUTHOR $RDREPO --readonly\` for the strict gate)"
  else
    echo "  read-only ambient verdict: FAIL — ambient credential is not authoritatively read-only (advisory here; \`wf.sh doctor $AUTHOR $RDREPO --readonly\` is the gating form, exits non-zero)"
  fi
  if [ "$ready" = 1 ]; then
    echo "READY: the full ship-change workflow identity path would proceed under current configuration"
  else
    echo "BLOCKED: the full ship-change workflow identity path would fail under current configuration"
    echo "  $ambient_identity_hint"
    exit 1
  fi
  ;;

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
  note "next: write the design doc at $WT/$DOC, then: wf.sh open $WT <claude|codex>"
  ;;

open)   # wf.sh open <worktree> <author>   — commit the design doc, push, open the DRAFT PR
  need_gh; WT=${1:?usage: wf.sh open <worktree> <author>}; AUTHOR=${2:-}
  [ -d "$WT" ] || die "no such worktree: $WT"
  if [ -n "$AUTHOR" ]; then
    check_author "$AUTHOR"
  elif ambient_identity_allowed; then
    ambient_identity_note "open without author (no engineer identity requested)"
  else
    missing_identity_die "open requires an author family (claude|codex) for engineer attribution"
  fi
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
      if ambient_identity_allowed; then
        ambient_identity_note "git commit author for author=$AUTHOR (missing WF_ENGINEER_GIT_AUTHOR_$(family_suffix "$AUTHOR"))"
      else
        missing_identity_die "missing WF_ENGINEER_GIT_AUTHOR_$(family_suffix "$AUTHOR") for author=$AUTHOR"
      fi
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
  if [ -z "$AUTHOR_TOKEN" ] && ambient_identity_allowed; then
    post_ambient_pr_trail "$WT" "$PR" "wf.sh open"
  fi
  echo "PR=$PR"; note "draft PR #$PR opened: $PRURL"; note "next: wf.sh design-review $WT <author>"
  ;;

design-review)  # wf.sh design-review <worktree> <author>
  need_gh; WT=${1:?usage: wf.sh design-review <worktree> <author>}; AUTHOR=${2:?author: claude|codex}
  check_author "$AUTHOR"; require_model_reviewer "$AUTHOR"; [ -d "$WT" ] || die "no such worktree: $WT"
  ATOK=$(author_token_optional "$AUTHOR")
  [ -n "$ATOK" ] || need_ambient_gh
  require_clean "$WT"; PR=$(wt_pr_required "$WT" "$ATOK")
  DOC=$(cd "$WT" && git diff --name-only "$(base_ref "$WT")"...HEAD -- proposals/ | head -1)
  [ -n "$DOC" ] || die "no committed design doc under proposals/ (run: wf.sh open $WT <claude|codex>)"
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
  if [ -z "$ATOK" ] && ambient_identity_allowed; then
    BODY=$( { ambient_override_notice "wf.sh comment on PR #$PR"; printf '\n\n%s' "$BODY"; } )
  fi
  echo "$BODY" | gh_author "$ATOK" -R "$(gh_repo "$WT")" pr comment "$PR" --body-file - >/dev/null \
    || die "could not post the author comment to PR #$PR — failing closed"
  if [ -n "$ATOK" ]; then note "posted author COMMENT to PR #$PR as the $AUTHOR engineer identity"
  else note "posted author COMMENT to PR #$PR (ambient token — no engineer identity configured for $AUTHOR)"; fi
  ;;

fdispo)         # wf.sh fdispo <worktree> <author> <seed|show|edit|save> — manage FINDING-disposition state (#139)
  # The author-facing interface to the disposition-aware merge gate. `seed` pulls the latest review's findings
  # into the PR-canonical state as `unresolved`; edit the printed cache to set fixed/refuted/deferred_*, then
  # `save` to update the canonical PR comment. `show`/`edit` print the cache path/contents.
  WT=${1:?usage: wf.sh fdispo <worktree> <author> <seed|show|edit|save>}
  AUTHOR=${2:?author: claude|codex}; ACTION=${3:-show}
  check_author "$AUTHOR"; [ -d "$WT" ] || die "no such worktree: $WT"
  ATOK=$(author_token_optional "$AUTHOR"); [ -n "$ATOK" ] || need_ambient_gh
  REPO=$(gh_repo "$WT"); PR=$(wt_pr_required "$WT" "$ATOK")
  CACHE=$(fd_cache "$WT")   # the LOCAL cache path — do NOT reload from GitHub for save/show/edit (would clobber edits)
  case "$ACTION" in
    seed)
      # refresh canonical state from GitHub, THEN merge in the latest review's findings (then the author edits).
      CACHE=$(fd_load "$WT" "$REPO" "$PR" "$ATOK") || die "canonical disposition state on PR #$PR is corrupt (invalid JSON) — fix the disposition comment first"
      BRT=$(wt_branch "$WT" | tr '/' '_')
      REVF=$(ls -t "${TMPDIR:-/tmp}/wf_code_${BRT}.md" "${TMPDIR:-/tmp}/wf_scaffold_${BRT}.md" 2>/dev/null | head -1 || true)
      [ -n "$REVF" ] && [ -f "$REVF" ] || die "no review output to seed from — run 'wf.sh code-review $WT $AUTHOR' (or design-review) first"
      fd_seed "$CACHE" "$REVF"
      fd_save "$WT" "$REPO" "$PR" "$ATOK" || die "failed to post the canonical disposition comment to PR #$PR (GitHub error) — state NOT updated"
      note "seeded $(jq '.findings|length' "$CACHE") finding(s) ($(jq '[.findings[]|select(.status=="unresolved")]|length' "$CACHE") unresolved). Edit $CACHE (set status fixed|refuted|deferred_to_child_design|deferred_out_of_scope + evidence/commit/child_issue/followup_issue), then: wf.sh fdispo $WT $AUTHOR save" ;;
    save)
      [ -s "$CACHE" ] || die "no local disposition cache to save ($CACHE) — run 'wf.sh fdispo $WT $AUTHOR seed' first"
      jq -e . "$CACHE" >/dev/null 2>&1 || die "local disposition cache is not valid JSON ($CACHE) — fix it, then save"
      fd_save "$WT" "$REPO" "$PR" "$ATOK" || die "failed to post the canonical disposition comment to PR #$PR (GitHub error) — state NOT updated"
      note "saved disposition state to PR #$PR canonical comment ($(jq '.findings|length' "$CACHE") findings)" ;;
    show) [ -s "$CACHE" ] && cat "$CACHE" || echo "(no local disposition cache — run 'wf.sh fdispo $WT $AUTHOR seed')" ;;
    edit) echo "$CACHE" ;;
    *) die "usage: wf.sh fdispo <worktree> <author> <seed|show|edit|save>" ;;
  esac
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
  # Narrow MAINTAINER verbs (#164 — blocking predecessor of the #149 gh write-guard). close|label|dispose let
  # triage-feedback and wf.sh do tracker maintenance under the ENGINEER identity once the guard makes the
  # ambient owner token read-only. Each has a FIXED, validated arg set and NO arbitrary-arg passthrough —
  # preserving the #91 hardening model (allowlisted flags only; no destructive/interactive surface). They have
  # their own arg shapes (and dispose is multi-step), so they run in a dedicated helper, NOT the create|comment
  # authoring path below.
  if [ "$GHSUB" = close ] || [ "$GHSUB" = label ] || [ "$GHSUB" = dispose ]; then
    issue_maintainer_verb "$AUTHOR" "$@"
  else
  # Allowlist: this is the engineer-AUTHORING path (#89), not general issue admin. Refuse anything but
  # create/comment (and the maintainer verbs handled above) so a typo or a broad call can't run
  # edit/delete/lock under the engineer token.
  case "$GHSUB" in create|comment) ;; *) die "wf.sh issue: only 'create', 'comment', 'close', 'label', 'dispose' are allowed (got '$GHSUB'); this is the engineer-authoring/maintenance path, not general issue ops" ;; esac
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
  if [ -z "$ATOK" ] && ambient_identity_allowed; then
    ambient_identity_note "wf.sh issue $GHSUB"
    IREPO=$(repo_arg_from_gh_args "$(gh_repo "${ORIGIN_REPO:-.}")" "$@")
    if [ "$GHSUB" = create ]; then
      OUT=$(gh_author "$ATOK" issue "$@") || die "wf.sh issue: 'gh issue $GHSUB' failed — failing closed"
      printf '%s\n' "$OUT"
      INUM=$(sed -nE 's#.*/issues/([0-9]+).*#\1#p' <<<"$OUT" | head -1 || true)
      if [ -n "$INUM" ]; then
        ambient_override_notice "wf.sh issue create" | gh_author "$ATOK" issue comment "$INUM" -R "$IREPO" --body-file - >/dev/null 2>&1 \
          || note "WARN: could not post ambient-identity override note to issue #$INUM (non-fatal; terminal warning already emitted)"
      fi
    else
      INUM=$(issue_number_from_gh_issue_args "$@" || true)
      gh_author "$ATOK" issue "$@" || die "wf.sh issue: 'gh issue $GHSUB' failed — failing closed"
      # A second comment is the least invasive durable trail for arbitrary `gh issue comment` args.
      if [ -n "$INUM" ]; then
        if [[ "$INUM" == http://* || "$INUM" == https://* ]]; then
          ambient_override_notice "wf.sh issue comment" | gh_author "$ATOK" issue comment "$INUM" --body-file - >/dev/null 2>&1 \
            || note "WARN: could not post ambient-identity override note for issue URL $INUM (non-fatal; terminal warning already emitted)"
        else
          ambient_override_notice "wf.sh issue comment" | gh_author "$ATOK" issue comment "$INUM" -R "$IREPO" --body-file - >/dev/null 2>&1 \
          || note "WARN: could not post ambient-identity override note for issue #$INUM (non-fatal; terminal warning already emitted)"
        fi
      else
        note "WARN: could not identify issue number for ambient-identity override note (non-fatal; terminal warning already emitted)"
      fi
    fi
  else
    gh_author "$ATOK" issue "$@" || die "wf.sh issue: 'gh issue $GHSUB' failed — failing closed"
  fi
  if [ -n "$ATOK" ]; then note "ran 'gh issue $GHSUB' as the $AUTHOR engineer identity"
  else note "ran 'gh issue $GHSUB' (ambient token — no engineer identity configured for $AUTHOR)"; fi
  fi
  ;;

classify)       # wf.sh classify <worktree> <author>   — advisory record (never blocks)
  need_gh; WT=${1:?usage: wf.sh classify <worktree> <author>}; AUTHOR=${2:-}
  if [ -n "$AUTHOR" ]; then
    check_author "$AUTHOR"
  elif ambient_identity_allowed; then
    ambient_identity_note "classify without author (classification will use ambient auth)"
  else
    missing_identity_die "classify requires an author family (claude|codex) so the opposite-family reviewer identity can post the classification"
  fi
  [ -d "$WT" ] || die "no such worktree: $WT"
  [ -x "$WT/.aar-ci/classify.sh" ] || die "no classifier at $WT/.aar-ci/classify.sh (is this the automated-researcher repo?)"
  require_clean "$WT"
  mapfile -t PATHS < <(cd "$WT" && git diff --name-only "$(base_ref "$WT")"...HEAD)
  [ ${#PATHS[@]} -gt 0 ] || die "no changed paths main...HEAD"
  OUT=$( cd "$WT" && .aar-ci/classify.sh "${PATHS[@]}" )
  CLASS=$(echo "$OUT" | sed -nE 's/^CLASSIFICATION: //p' | head -1)
  # Attribute the classification to the opposite-family reviewer identity when configured. Without an author
  # or reviewer identity, keep the existing ambient-comment fallback.
  RTOK=""
  if [ -n "$AUTHOR" ]; then
    if ambient_identity_allowed; then
      RTOK=$(reviewer_token "$AUTHOR" 0)
    else
      RTOK=$(reviewer_token "$AUTHOR" 1)
    fi
  else
    note "WARN: no author passed to classify; posting classification with ambient GitHub auth because WF_ALLOW_AMBIENT_IDENTITY=1"
  fi
  if [ -z "$RTOK" ]; then
    ambient_identity_note "classification for PR lookup/post"
    need_ambient_gh
  fi
  PR=$(wt_pr_required "$WT" "$RTOK")
  BODY=$( { echo "## Type of change"; echo;
      classification_summary_text "$CLASS"; echo; echo;
      markdown_code_details "Classifier details" "$OUT"; } )
  if [ -z "$RTOK" ] && ambient_identity_allowed; then
    BODY=$( { ambient_override_notice "wf.sh classify on PR #$PR"; printf '\n\n%s' "$BODY"; } )
  fi
  if [ -n "$RTOK" ]; then
    echo "$BODY" | GH_TOKEN="$RTOK" real_gh -R "$(gh_repo "$WT")" pr comment "$PR" --body-file - >/dev/null \
      || die "could not post the classification to PR #$PR as the reviewer identity — failing closed (classification was: $CLASS)"
    note "posted classification to PR #$PR as the reviewer identity"
  else
    echo "$BODY" | real_gh -R "$(gh_repo "$WT")" pr comment "$PR" --body-file - >/dev/null \
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
  # Prefer THIS branch's OWN design doc (proposals/<issue>-*.md) over a lexically-first sibling: a PR that
  # MOVES many design docs (e.g. the proposals/->designs/ rename) would otherwise refresh the PR body from an
  # unrelated doc — `head -1` picks proposals/10-* and rewrites the body to "Closes #10", tripping the
  # close-gate (#180). The branch name carries the PR's issue (change/<issue>-<slug>); select the changed doc
  # named for it, and fall back to the first changed doc only when none matches. The `|| true` keeps a no-match
  # `grep` (set -euo pipefail -> rc 1) from aborting this best-effort refresh.
  BRISSUE=$(printf '%s\n' "$BR" | sed -nE 's#^change/([0-9]+)-.*#\1#p')
  FDOC=""
  if [ -n "$BRISSUE" ]; then
    FDOC=$( (cd "$WT" && git diff --name-only "$(base_ref "$WT")"...HEAD -- proposals/ \
              | grep -E "/${BRISSUE}-[^/]*\.md$" | head -1) || true)
  fi
  [ -n "$FDOC" ] || FDOC=$(cd "$WT" && git diff --name-only "$(base_ref "$WT")"...HEAD -- proposals/ | head -1)
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
  # 2a. disposition-aware deterministic backstop (#139), BEFORE any approving review — so a blocked/malformed
  #     disposition state can never receive a native APPROVE. If this PR has finding-disposition state, the
  #     structural gate over its HIGH entries must pass first (a HIGH left `unresolved` or a malformed
  #     disposition BLOCKS). Fail-CLOSED on a GitHub lookup error; no state -> skipped (stateless behavior).
  FD=""; if fd_active "$REPO" "$PR" "$ATOK"; then FDRC=0; else FDRC=$?; fi   # if-form: set -e safe on rc 1/2
  case "$FDRC" in
    2) die "disposition-state lookup failed (GitHub error) — failing closed; re-run finish" ;;
    0) FD=$(fd_load "$WT" "$REPO" "$PR" "$ATOK") || die "canonical disposition state on PR #$PR is corrupt (invalid JSON) — fix the disposition comment and re-run finish"
       # A present-but-malformed `round` is corruption of the load-bearing backstop counter — fail closed rather
       # than let fd_round silently reset it to 0 (which would defeat the backstop). Absent/null is fine (=> 0).
       fd_round_valid "$FD" || die "canonical disposition state on PR #$PR has a malformed \`round\` (must be a non-negative integer) — the non-convergence backstop counter is corrupt; fix the disposition comment and re-run finish."
       # 1d. Non-convergence backstop — PRE-REVIEW short-circuit (#137). This MUST run before any verifier-backed
       #      work below (the mandatory #140 fresh-eyes sweep AND the merge review), so a bare retry past threshold
       #      spends NO review credit at all — the whole point of the backstop. If the PR is already at the round
       #      threshold AND nothing has been committed since the last counted blocking round (HEAD ==
       #      last_reviewed_sha = a bare retry of the same loop), refuse to spend another review and emit the
       #      under-scoped block now. A NEW commit since then (HEAD moved = a genuine fix attempt) falls through
       #      and is allowed one more review. Env-overridable: raise WF_NONCONVERGENCE_ROUNDS to review the same SHA.
       NCV_N=${WF_NONCONVERGENCE_ROUNDS:-4}; case "$NCV_N" in ''|*[!0-9]*) NCV_N=4 ;; esac
       NCV_PRIOR=$(fd_round "$FD"); NCV_PRIOR_SHA=$(fd_last_reviewed_sha "$FD")
       if [ "${NCV_PRIOR:-0}" -ge "$NCV_N" ] 2>/dev/null && [ -n "$NCV_PRIOR_SHA" ] && [ "$NCV_PRIOR_SHA" = "$LOCAL_SHA" ]; then
         ncv_backstop_comment "$ATOK" "$REPO" "$PR" "$NCV_PRIOR" "(unchanged since last round)"
         die "non-convergence backstop: already $NCV_PRIOR merge-gate rounds with a blocking HIGH (>= WF_NONCONVERGENCE_ROUNDS=$NCV_N) and nothing committed since the last review — NOT spending another review. This PR appears UNDER-SCOPED; re-split it into smaller ready/needs-design children. Commit a genuine fix to get one more review, or raise WF_NONCONVERGENCE_ROUNDS to override."
       fi
       # #140 fresh-eyes companion: BEFORE the gate/merge-review, run ONE un-anchored stateless sweep over the
       #      same target and post it. Its wf_fresh_<branch> artifact is auto-handed to the disposition-aware
       #      merge review (run_review) for SEMANTIC adjudication. Candidate-only — it never feeds the
       #      deterministic structural gate below, so a rephrased dispositioned finding can't false-block.
       if [ "$DESIGN_MODE" = 1 ]; then
         fresh_sweep "$WT" "$AUTHOR" --scaffold "$WT/$DESIGN_DOC" "$PR" >/dev/null || die "fresh-eyes sweep (mandatory #140 backstop) failed — re-run finish (only its PR comment is best-effort)"
       else
         FRESHDIFF="${TMPDIR:-/tmp}/wf_finish_${BR//\//_}.diff"
         ( cd "$WT" && git diff "$(base_ref "$WT")"...HEAD ) > "$FRESHDIFF"
         fresh_sweep "$WT" "$AUTHOR" --code "$FRESHDIFF" "$PR" >/dev/null || die "fresh-eyes sweep (mandatory #140 backstop) failed — re-run finish (only its PR comment is best-effort)"
       fi
       FDLIST="${TMPDIR:-/tmp}/wf_fd_high_${BR//\//_}.txt"
       # TRUSTED findings list (#143): recover the reviewer-derived HIGH ids from the DURABLE GitHub review
       # record (posted under the reviewer-bot identity), NOT a transient/author-writable /tmp file. A
       # deleted/downgraded disposition still can't bypass the gate (the deleted id has no entry -> BLOCK), and
       # the list now survives reboot / fresh worktree / a different agent. FAIL CLOSED if no reviewer identity
       # or no marked reviewer review is recoverable — never fall back to /tmp or to author-only state.
       PK=code; [ "$DESIGN_MODE" = 1 ] && PK=scaffold
       # Reviewer-bot login = the opposite family's canonical git-author NAME (== the App's PR comment login).
       RLOGIN=$(git_author_name "$(engineer_git_author "$(opposite_family "$AUTHOR")" 0)")
       [ -n "$RLOGIN" ] || die "disposition-aware finish needs the reviewer identity to anchor the trusted findings list, but WF_ENGINEER_GIT_AUTHOR_$(family_suffix "$(opposite_family "$AUTHOR")") is unset — configure the reviewer engineer identity (wf.sh doctor $AUTHOR) and re-run finish."
       # ATOK (author token) has read access to the PR's reviews/comments; the trust is in the reviewer LOGIN
       # filter, not in which token reads. Tri-state: 0 ok, 1 no marked reviewer review, 2 no login / API error.
       if REVHIGH=$(fd_review_high_github "$REPO" "$PR" "$PK" "$ATOK" "$RLOGIN"); then :; else
         case "$?" in
           1) die "disposition-aware finish found no marked reviewer $PK review on PR #$PR to anchor the trusted findings list — run 'wf.sh code-review $WT $AUTHOR' (or design-review) to post one, then finish. (A disposition PR last reviewed before #143 landed has an unmarked review — one fresh review fixes it.)" ;;
           *) die "disposition-aware finish could not recover the trusted reviewer findings list from the GitHub review record (API error or no reviewer identity) — failing closed; re-run finish." ;;
         esac
       fi
       # Detect a TRUE duplicate WITHIN the reviewer-derived list (a hashed-id collision = real ambiguity)
       # BEFORE any dedup, so `sort -u` below only collapses the legitimate reviewer∩state overlap.
       # awk 'NF' (not grep -v '^$') so an EMPTY list — the expected convergence case — returns 0, not 1-under-pipefail.
       DUPR=$(printf '%s\n' "$REVHIGH" | awk 'NF' | sort | uniq -d)
       [ -z "$DUPR" ] || die "ambiguous reviewer findings — colliding id(s): $(printf '%s ' $DUPR) — cannot disposition unambiguously"
       # UNION of reviewer-derived HIGH ids (trusted; catches a deleted/downgraded disposition) AND the state's
       # own HIGH ids (catches a stale `unresolved` HIGH the current reviewer no longer raises). Either blocks.
       { printf '%s\n' "$REVHIGH"; fd_high_list "$FD"; } | awk 'NF' | sort -u > "$FDLIST"
       ( cd "$WT" && bash "$(dirname "$0")/disposition_gate.sh" "$FD" "$FDLIST" ) \
         || die "disposition structural gate BLOCKED — a reviewer HIGH is unresolved, undispositioned, or malformed in the state. Disposition it (wf.sh fdispo $WT $AUTHOR) and re-run finish." ;;
  esac
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
  # 2c. record the final review's findings into the disposition state for the NEXT round (non-gating — the
  #     structural gate above and the model verdict below are the gates; this only keeps the canonical record current).
  #     ALSO advance the non-convergence round counter (#137 backstop) IDEMPOTENTLY here — this is the one place a
  #     completed merge-gate reviewer pass is incorporated, so it is the credit-accurate unit to count.
  NCV_ROUND=0
  if [ -n "$FD" ]; then
    FK=code; [ "$DESIGN_MODE" = 1 ] && FK=scaffold
    REVF="${TMPDIR:-/tmp}/wf_${FK}_$(wt_branch "$WT" | tr '/' '_').md"
    if [ -f "$REVF" ]; then
      fd_seed "$FD" "$REVF"
      # Fingerprint = reviewed SHA + this review's residual-HIGH id set. A new commit (new SHA) or a changed
      # HIGH set => new fingerprint => round +1; a bare identical re-run reproduces it => no increment.
      NCV_HI="${TMPDIR:-/tmp}/wf_ncv_high_${BR//\//_}.txt"
      fd_review_high_list "$REVF" | awk '{print $1}' > "$NCV_HI"
      # had_high=1 only when THIS merge review left a blocking HIGH — a clean review is not a non-convergence
      # round and must not increment the counter (keeps `round` an honest "rounds with a residual HIGH").
      NCV_HADHI=0; [ "$REVIEW_HIGH" != 0 ] && NCV_HADHI=1
      NCV_BEFORE=$(fd_round "$FD")
      NCV_ROUND=$(fd_bump_round "$FD" "$LOCAL_SHA" "$NCV_HI" "$NCV_HADHI") \
        || die "could not persist the non-convergence round counter to the local disposition cache (write failed) — failing closed so the backstop never undercounts. Re-run finish."
      # fd_save persists the disposition state (incl. round / last_reviewed_sha) to the canonical PR comment.
      # If the round counter actually ADVANCED this pass, that state is load-bearing for the next finish (the
      # pre-review short-circuit + the trip both read round/last_reviewed_sha from the comment) — a lost save
      # would UNDERCOUNT and silently defeat the backstop. So fail CLOSED on a save failure that drops a real
      # increment; a non-advancing save (clean review / idempotent retry) stays a cosmetic WARN.
      # allow_advance=1: THIS is the one legitimate round-advancing save (right after fd_bump_round). Every other
      # fd_save (the author-facing fdispo paths) defaults to 0 and is clamped to canonical, so the counter is
      # reviewer-owned — only finish can advance it.
      if fd_save "$WT" "$REPO" "$PR" "$ATOK" 1; then :; else
        if [ "${NCV_ROUND:-0}" != "${NCV_BEFORE:-0}" ]; then
          die "could not persist the advanced non-convergence round ($NCV_BEFORE -> $NCV_ROUND) to the canonical PR comment (GitHub write failed) — failing closed so the next finish does not undercount. Re-run finish."
        fi
        note "WARN: could not update canonical disposition comment (cosmetic — round unchanged; gates already evaluated)"
      fi
    fi
  fi
  if [ "$REVIEW_HIGH" != 0 ]; then
    # Non-convergence backstop (#137): after N merge-gate rounds STILL producing a blocking HIGH, the loop is
    # the under-scoped signature, not a fixable finding — change the guidance to "re-split", still BLOCK.
    NCV_N=${WF_NONCONVERGENCE_ROUNDS:-4}
    case "$NCV_N" in ''|*[!0-9]*) NCV_N=4 ;; esac
    if [ -n "$FD" ] && [ "${NCV_ROUND:-0}" -ge "$NCV_N" ] 2>/dev/null; then
      ncv_backstop_comment "$ATOK" "$REPO" "$PR" "$NCV_ROUND" "(still $REVIEW_HIGH blocking HIGH)"
      die "non-convergence backstop: $REVIEW_HIGH HIGH after $NCV_ROUND merge-gate rounds (>= WF_NONCONVERGENCE_ROUNDS=$NCV_N) — this PR appears UNDER-SCOPED. Re-split it into smaller ready/needs-design children rather than iterating further. (Raise WF_NONCONVERGENCE_ROUNDS to override for a genuine false-positive loop.)"
    fi
    die "merge gate: $REVIEW_HIGH HIGH finding(s) remain — NOT merging. Fix in $WT + commit, then re-run finish."
  fi
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
  [ "$local_manifest" = 1 ] && note "a plugin manifest changed — refresh installs: claude plugin marketplace update automated-researcher && claude plugin update <name>@automated-researcher"
  if [ "$DESIGN_MODE" = 1 ]; then
    echo "SHIPPED: design PR #$PR merged (opposite-family --scaffold approval + checks). Worktree cleaned. Next: file the spawned 'ready' issues."
  else
    echo "SHIPPED: PR #$PR merged (opposite-family review gate + checks). Worktree cleaned."
  fi
  ;;

*) echo "BLOCKED: unknown subcommand '${CMD:-}'." >&2; echo >&2; usage >&2; exit 1 ;;
esac
