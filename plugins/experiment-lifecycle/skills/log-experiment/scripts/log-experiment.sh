#!/usr/bin/env bash
# log-experiment.sh <registry-dir> [--dry-run]
#
# Log a research-repo registry directory to GitHub as a GATED pull request and merge it.
# The gate is chosen by the directory's own content (auditability via the registry convention):
#   - experiment   (DESIGN.md + RESULTS.md):   verify the close-audit is present and clean.
#   - design-stage (DESIGN.md, no RESULTS.md): verify the design-audit (DESIGN_AUDIT*.md) is present + secret scan.
#   - note         (anything else):            deterministic secret scan only.
# A cross-family engineer-bot approval satisfies the research repo's branch protection
# (the author cannot approve their own PR). Self-contained: this does NOT source wf.sh.
#
# Config (instance, env-overridable; NO instance defaults — fail closed):
#   RESEARCH_REPO                    the research repo (owner/repo). REQUIRED; the input dir's origin must match it.
#   LOG_EXPERIMENT_AUTHOR_FAMILY     claude|codex. Defaults to $AAR_SUBSTRATE; fail-closed if neither is set
#                                    (a wrong default must not make the review same-family). Reviewer = OPPOSITE family.
#   LOG_EXPERIMENT_TOKEN_CMD_CLAUDE  command taking <owner/repo> that mints a claude-engineer token.
#   LOG_EXPERIMENT_TOKEN_CMD_CODEX   command taking <owner/repo> that mints a codex-engineer token.
#                                    AUTHOR family -> writes; OPPOSITE family -> approval. Fail-closed if unset.
#   LOG_EXPERIMENT_GIT_AUTHOR_CLAUDE the 'Name <email>' the claude bot commits as.
#   LOG_EXPERIMENT_GIT_AUTHOR_CODEX  the 'Name <email>' the codex bot commits as.
set -euo pipefail

# Config (instance, env-overridable). RESEARCH_REPO has NO default — fail closed if unset.
RESEARCH_REPO="${RESEARCH_REPO:-}"
AUTHOR_FAMILY="${LOG_EXPERIMENT_AUTHOR_FAMILY:-${AAR_SUBSTRATE:-}}"   # the running family (NO default — fail closed if unknown); reviewer is the OPPOSITE family

die()  { echo "BLOCK: $*" >&2; exit 1; }
note() { echo "[log-experiment] $*" >&2; }

# ---- args ----
DRY_RUN=0; DIR=""
for a in "$@"; do
  case "$a" in
    --dry-run) DRY_RUN=1 ;;
    -*) die "unknown flag: $a" ;;
    *) DIR="$a" ;;
  esac
done
[ -n "$DIR" ] || die "usage: log-experiment.sh <registry-dir> [--dry-run]"
[ -d "$DIR" ] || die "not a directory: $DIR"
DIR="$(cd "$DIR" && pwd)"   # absolute — stable across the later cd into the repo root

REPO_ROOT="$(cd "$DIR" && git rev-parse --show-toplevel 2>/dev/null)" || die "not inside a git repo: $DIR"
REL="$(cd "$REPO_ROOT" && realpath --relative-to="$REPO_ROOT" "$DIR")"
[ "${REL#..}" = "$REL" ] || die "dir is outside the repo root"
SLUG="$(basename "$REL" | tr -c 'A-Za-z0-9._-' '-' | sed 's/-*$//')"

# ---- classify (registry convention; KIND file is an explicit override) ----
KIND=""
[ -f "$DIR/KIND" ] && KIND="$(tr -d '[:space:]' < "$DIR/KIND")"
if [ -z "$KIND" ]; then
  if   [ -f "$DIR/DESIGN.md" ] && [ -f "$DIR/RESULTS.md" ]; then KIND="experiment"     # results leg: close-audit gate
  elif [ -f "$DIR/DESIGN.md" ];                                then KIND="design-stage"  # design leg: design-audit gate
  else                                                              KIND="note"; fi       # everything else: secret scan
fi
note "classified: $KIND  ($REL)"

# ---- gate (fail-closed) ----
gate_experiment() {
  [ -f "$DIR/RESULTS.md" ] || die "experiment missing RESULTS.md"
  if [ -f "$DIR/AUDIT.md" ]; then
    # Require the triage artifact to exist (the close-audit must have been triaged), then backstop-scan it.
    # This VERIFIES the audit ran and was triaged; it does not re-derive triage (a machine-readable
    # close-triage contract is a future hardening — see proposal #240 "Gate detail").
    [ -f "$DIR/AUDIT_RESPONSE.md" ] || die "experiment has AUDIT.md but no AUDIT_RESPONSE.md (close-audit not triaged) — surface for human"
    # The gate VERIFIES the close-audit ran and was triaged (both artifacts present). It deliberately does
    # NOT prose-grep AUDIT_RESPONSE.md for unresolved HIGHs — that heuristic is unreliable (negation/scope
    # games) and not a real proof. Per-finding HIGH-resolution verification needs a machine-readable triage
    # status (a documented future hardening); the actual triage is done with discipline in run-experiment's close.
    APPROVAL_BODY="Experiment record — close-audit ran and was triaged (AUDIT.md + AUDIT_RESPONSE.md present). Verified per registry convention."
    note "experiment gate ok: close-audit present and triaged"
  else
    if grep -qiE '^[^A-Za-z0-9]*((decision|status|outcome|result)[^A-Za-z0-9]+)?(ANCHOR_FAILED|NO[ _-]?GO|GATE[ _]PASS=FALSE|GATE[ _]FAILED?|NULL RESULT|DIAGNOSTIC ONLY|STOPPED AT [A-Za-z0-9 _-]*GATE)' "$DIR/RESULTS.md"; then
      APPROVAL_BODY="Experiment record — eval-only/no-go run; no close-audit needed; RESULTS records a closed decision."
      note "experiment gate ok: no close-audit, RESULTS records a closed decision"
    else
      die "experiment has no AUDIT.md and RESULTS.md records no closed decision — surface for human"
    fi
  fi
}
secret_scan() {
  # Deterministic scan for secret-VALUE patterns in $DIR; dies (fail-closed) on a hit or an incomplete scan.
  # Shared by the note gate and the design-stage gate (a DESIGN-only dir was scanned as a 'note' before the
  # design-stage kind existed — moving it to design-stage must not drop that scan).
  local hits rc
  # -l: report only matching FILES, never the matched secret text. Capture grep's status: 0=match, 1=clean,
  # >1=error (unreadable file/traversal) -> fail closed (an incomplete scan must not read as clean).
  # The `if` keeps `set -e` from exiting on grep's normal exit 1.
  if hits="$(grep -rlaIE '(ghp_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|sk-[A-Za-z0-9_-]{20,}|AKIA[0-9A-Z]{16}|-----BEGIN [A-Z ]*PRIVATE KEY)' "$DIR" 2>/dev/null)"; then rc=0; else rc=$?; fi
  [ "$rc" -le 1 ] || die "secret scan failed (grep exit $rc) — scan incomplete, refusing to log"
  [ -z "$hits" ] || { echo "secret-value pattern found in (values redacted):" >&2; echo "$hits" >&2; die "$KIND contains secret-value patterns"; }
}
gate_note() {
  secret_scan
  APPROVAL_BODY="Record — deterministic secret scan clean; no experiment, so no audit."
  note "note gate ok: secret scan clean"
}
gate_design_stage() {
  # The design PR — the pre-launch leg of the two-PR flow. Verify the design-audit RAN (its numbered
  # DESIGN_AUDIT*.md chain is the validity record design-experiment emits), then run the same secret scan a
  # note gets. Like the experiment gate it verifies the audit is PRESENT, not that every finding was resolved
  # (a machine-readable triage status is a documented future hardening; the researcher invoking this at design
  # time is the clearance act — same human-in-the-loop trust model as the close gate).
  # Defend the invariant on the KIND-override path too (auto-classify only reaches here when DESIGN.md exists,
  # but a KIND=design-stage file bypasses that): a design-stage record IS a pre-registration.
  [ -f "$DIR/DESIGN.md" ]  || die "design-stage dir missing DESIGN.md — a design-stage record is a pre-registration"
  [ -f "$DIR/RESULTS.md" ] && die "design-stage dir unexpectedly has RESULTS.md — should classify as experiment"
  compgen -G "$DIR/DESIGN_AUDIT*.md" >/dev/null 2>&1 \
    || die "design-stage dir has DESIGN.md but no DESIGN_AUDIT*.md (design-audit not run) — surface for human"
  secret_scan
  APPROVAL_BODY="Design-stage record — design-audit present (DESIGN_AUDIT*.md) and secret scan clean; pre-launch leg of the two-PR flow."
  note "design-stage gate ok: design-audit present and secret scan clean"
}
case "$KIND" in
  experiment)   gate_experiment ;;
  design-stage) gate_design_stage ;;
  note)         gate_note ;;
  *)            die "unknown KIND override: '$KIND' (expected experiment|design-stage|note)" ;;
esac

if [ "$DRY_RUN" = 1 ]; then note "--dry-run: classified=$KIND, gate PASSED; stopping before any push."; exit 0; fi

# ---- resolve identities + mint the cross-family reviewer token up front (fail before mutating) ----
[ -n "$RESEARCH_REPO" ] || die "RESEARCH_REPO is required (instance config; no default target)"
case "$AUTHOR_FAMILY" in
  claude) REVIEWER_FAMILY=CODEX  ;;
  codex)  REVIEWER_FAMILY=CLAUDE ;;
  *) die "LOG_EXPERIMENT_AUTHOR_FAMILY (or AAR_SUBSTRATE) must be claude|codex (got '$AUTHOR_FAMILY') — fail closed to keep the review cross-family" ;;
esac
# F2: the input dir's repo must BE the research repo — never push/leak the record to the wrong origin.
origin_url="$(git -C "$REPO_ROOT" remote get-url origin 2>/dev/null || true)"
# Require a github.com remote, then EXACT owner/repo. Never print the raw URL (it may carry a token).
case "$origin_url" in
  https://github.com/*|git@github.com:*|ssh://git@github.com/*) : ;;
  *) die "input dir's origin is not a github.com remote — refusing to push" ;;
esac
origin_slug="$(printf '%s' "$origin_url" | sed -E 's#^.*github\.com[/:]##; s#\.git$##; s#/$##')"
[ "$origin_slug" = "$RESEARCH_REPO" ] || die "input dir's origin ($origin_slug) is not RESEARCH_REPO ($RESEARCH_REPO)"
# Two engineer-bot tokens, both EXPLICIT family-keyed instance config (commands taking <owner/repo>):
#   AUTHOR family -> the bot that pushes / creates / merges; REVIEWER = OPPOSITE family -> the bot that
#   approves (cross-family independence; the author bot cannot approve its own PR). Fail closed if unset.
mint_var="LOG_EXPERIMENT_TOKEN_CMD_${REVIEWER_FAMILY}"
REVIEWER_MINT="${LOG_EXPERIMENT_REVIEWER_TOKEN_CMD:-${!mint_var:-}}"
[ -n "$REVIEWER_MINT" ] || die "no reviewer token command — set $mint_var (or LOG_EXPERIMENT_REVIEWER_TOKEN_CMD), a command taking <owner/repo> minting a ${REVIEWER_FAMILY,,}-engineer token"
TOK="$($REVIEWER_MINT "$RESEARCH_REPO" 2>/dev/null || true)"
[ -n "$TOK" ] || die "could not mint ${REVIEWER_FAMILY,,}-engineer reviewer token for $RESEARCH_REPO"
# Validate repo access BEFORE any mutation (a token that can't reach the repo would strand a half-open PR).
GH_TOKEN="$TOK" gh api "repos/$RESEARCH_REPO" -q .full_name >/dev/null 2>&1 \
  || die "reviewer token cannot access $RESEARCH_REPO (is the ${REVIEWER_FAMILY,,}-engineer App installed there?)"
# Author-family token (the bot that pushes / creates / merges) + its commit identity. Fail closed.
amint_var="LOG_EXPERIMENT_TOKEN_CMD_${AUTHOR_FAMILY^^}"
AUTHOR_MINT="${!amint_var:-}"
[ -n "$AUTHOR_MINT" ] || die "no author token command — set $amint_var, a command taking <owner/repo> minting a ${AUTHOR_FAMILY}-engineer token"
ATOK="$($AUTHOR_MINT "$RESEARCH_REPO" 2>/dev/null || true)"
[ -n "$ATOK" ] || die "could not mint ${AUTHOR_FAMILY}-engineer author token for $RESEARCH_REPO"
GH_TOKEN="$ATOK" gh api "repos/$RESEARCH_REPO" -q .full_name >/dev/null 2>&1 \
  || die "author token cannot access $RESEARCH_REPO (is the ${AUTHOR_FAMILY}-engineer App installed there?)"
gitauthor_var="LOG_EXPERIMENT_GIT_AUTHOR_${AUTHOR_FAMILY^^}"
GIT_AUTHOR="${!gitauthor_var:-}"
[ -n "$GIT_AUTHOR" ] || die "no author git identity — set $gitauthor_var to the ${AUTHOR_FAMILY}-engineer 'Name <email>'"
[[ "$GIT_AUTHOR" =~ ^.+\ \<[^@[:space:]]+@[^@[:space:]]+\>$ ]] || die "$gitauthor_var is malformed (expected 'Name <email>'): $GIT_AUTHOR"
GA_NAME="${GIT_AUTHOR% <*}"; GA_EMAIL="${GIT_AUTHOR#*<}"; GA_EMAIL="${GA_EMAIL%>}"

# ---- branch in a DEDICATED worktree (never disturbs the shared tree) ----
cd "$REPO_ROOT"
git fetch origin --quiet
BRANCH="log/${SLUG}"
WT="$(mktemp -d)/wt"
CREATED_BRANCH=0   # only delete the branch in cleanup if THIS run created it (never a pre-existing one)
cleanup() { git worktree remove --force "$WT" >/dev/null 2>&1 || true; [ "$CREATED_BRANCH" = 1 ] && git branch -D "$BRANCH" >/dev/null 2>&1 || true; }
trap cleanup EXIT
git show-ref --verify --quiet "refs/heads/$BRANCH" && die "local branch $BRANCH already exists (a prior run may have failed) — remove it and retry"
git worktree add -q -b "$BRANCH" "$WT" origin/main || die "could not create worktree/branch $BRANCH"
CREATED_BRANCH=1

mkdir -p "$WT/$(dirname "$REL")"
cp -r "$DIR" "$WT/$(dirname "$REL")/"
git -C "$WT" add -- "$REL"                          # respects the dir's .gitignore (large artifacts stay on R2)
git -C "$WT" diff --cached --quiet && die "nothing to commit for $REL (all gitignored?)"
# Force the bot identity via env (overrides any ambient GIT_AUTHOR_*/GIT_COMMITTER_* + config) for author AND committer.
GIT_AUTHOR_NAME="$GA_NAME" GIT_AUTHOR_EMAIL="$GA_EMAIL" \
GIT_COMMITTER_NAME="$GA_NAME" GIT_COMMITTER_EMAIL="$GA_EMAIL" \
  git -C "$WT" commit -q -m "Log $KIND: $REL"
# Push as the AUTHOR bot via a token-scoped remote, with credential helpers DISABLED so no ambient
# credential machinery can participate (matches the hardened push convention). URL not persisted as a remote.
git -C "$WT" -c credential.helper= push -q "https://x-access-token:${ATOK}@github.com/${RESEARCH_REPO}.git" "HEAD:refs/heads/$BRANCH"
HEAD_SHA="$(git -C "$WT" rev-parse HEAD)"   # bind the merge to exactly the reviewed commit

# ---- PR -> bot approve -> merge ----
BODY="$(printf '%s\n\nLogged by log-experiment.sh (gate: %s).' "$APPROVAL_BODY" "$KIND")"
URL="$(GH_TOKEN="$ATOK" gh pr create -R "$RESEARCH_REPO" --head "$BRANCH" --base main \
        -t "Log $KIND: $REL" -b "$BODY")"
PR="$(echo "$URL" | grep -oE '[0-9]+$')"
note "opened PR #$PR ($URL)"
GH_TOKEN="$TOK" gh pr review "$PR" -R "$RESEARCH_REPO" --approve --body "$APPROVAL_BODY" >/dev/null
GH_TOKEN="$ATOK" gh pr merge "$PR" -R "$RESEARCH_REPO" --squash --delete-branch --match-head-commit "$HEAD_SHA" >/dev/null
note "merged PR #$PR (head $HEAD_SHA)"

# ---- sync local main (ff-only, ONLY if this checkout is on main; never touches other uncommitted work) ----
git fetch origin --quiet
if [ "$(git rev-parse --abbrev-ref HEAD)" = "main" ]; then
  git merge --ff-only origin/main >/dev/null 2>&1 || note "local main not fast-forwardable; left as-is"
else
  note "checkout is on $(git rev-parse --abbrev-ref HEAD), not main; skipping local sync"
fi
echo "OK: logged $KIND '$REL' as PR #$PR (merged)."   # the EXIT trap removes the temp worktree + its local branch
