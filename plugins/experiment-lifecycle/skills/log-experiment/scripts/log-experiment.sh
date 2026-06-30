#!/usr/bin/env bash
# log-experiment.sh <registry-dir> [--dry-run]
#
# Log a research-repo registry directory to GitHub as a GATED pull request and merge it.
# The gate is chosen by the directory's own content (auditability via the registry convention):
#   - experiment (has DESIGN.md + RESULTS.md): verify the close-audit is present and clean.
#   - note (anything else):                    deterministic secret scan only.
# A cross-family engineer-bot approval satisfies the research repo's branch protection
# (the author cannot approve their own PR). Self-contained: this does NOT source wf.sh.
#
# Config (instance, env-overridable; NO instance defaults — fail closed):
#   RESEARCH_REPO                    the research repo (owner/repo). REQUIRED; the input dir's origin must match it.
#   LOG_EXPERIMENT_AUTHOR_FAMILY     claude|codex. Defaults to $AAR_SUBSTRATE; fail-closed if neither is set
#                                    (a wrong default must not make the review same-family). Reviewer = OPPOSITE family.
#   LOG_EXPERIMENT_TOKEN_CMD_CLAUDE  command taking <owner/repo> that mints a claude-engineer token.
#   LOG_EXPERIMENT_TOKEN_CMD_CODEX   command taking <owner/repo> that mints a codex-engineer token.
#                                    The REVIEWER family's command is used; fail-closed if unset.
#                                    (A single LOG_EXPERIMENT_REVIEWER_TOKEN_CMD override is also honored.)
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
  if [ -f "$DIR/DESIGN.md" ] && [ -f "$DIR/RESULTS.md" ]; then KIND="experiment"; else KIND="note"; fi
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
    if grep -qiE 'unresolved|OPEN HIGH|HIGH[^a-z]*(not addressed|outstanding|unresolved)' "$DIR/AUDIT_RESPONSE.md"; then
      die "experiment AUDIT_RESPONSE.md flags an unresolved HIGH — surface for human"
    fi
    APPROVAL_BODY="Experiment record — close-audit ran and was triaged (AUDIT.md + AUDIT_RESPONSE.md present, no unresolved-HIGH marker). Verified per registry convention."
    note "experiment gate ok: close-audit present and triaged"
  else
    if grep -qiE 'ANCHOR_FAILED|NO-?GO|gate pass=false|gate=false|stopped at [a-z0-9 _-]*gate|null result|diagnostic only' "$DIR/RESULTS.md"; then
      APPROVAL_BODY="Experiment record — eval-only/no-go run; no close-audit needed; RESULTS records a closed decision."
      note "experiment gate ok: no close-audit, RESULTS records a closed decision"
    else
      die "experiment has no AUDIT.md and RESULTS.md records no closed decision — surface for human"
    fi
  fi
}
gate_note() {
  local hits
  # -l: report only the FILES that match, never the matched secret text (no value leak into logs)
  hits="$(grep -rlaIE '(ghp_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|sk-[A-Za-z0-9_-]{20,}|AKIA[0-9A-Z]{16}|-----BEGIN [A-Z ]*PRIVATE KEY)' "$DIR" 2>/dev/null || true)"
  [ -z "$hits" ] || { echo "secret-value pattern found in (values redacted):" >&2; echo "$hits" >&2; die "note contains secret-value patterns"; }
  APPROVAL_BODY="Record — deterministic secret scan clean; no experiment, so no audit."
  note "note gate ok: secret scan clean"
}
case "$KIND" in
  experiment) gate_experiment ;;
  note)       gate_note ;;
  *)          die "unknown KIND override: '$KIND' (expected experiment|note)" ;;
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
# normalize git@github.com:owner/repo(.git) or https://github.com/owner/repo(.git) -> exact owner/repo
origin_slug="$(printf '%s' "$origin_url" | sed -E 's#^.*[/:]([^/]+/[^/]+)$#\1#; s#\.git$##')"
[ "$origin_slug" = "$RESEARCH_REPO" ] || die "input dir's origin ($origin_slug, from '$origin_url') is not RESEARCH_REPO ($RESEARCH_REPO)"
# Reviewer = OPPOSITE family (independence). Token command is EXPLICIT instance config (family-keyed):
# a command taking <owner/repo> that mints a ${REVIEWER_FAMILY,,}-engineer token. No derivation from other
# seams; fail closed if unset. (Author push/PR/merge use ambient gh — the researcher logging to their own
# lab is the legitimate author; the cross-family bot is the independent reviewer.)
mint_var="LOG_EXPERIMENT_TOKEN_CMD_${REVIEWER_FAMILY}"
REVIEWER_MINT="${LOG_EXPERIMENT_REVIEWER_TOKEN_CMD:-${!mint_var:-}}"
[ -n "$REVIEWER_MINT" ] || die "no reviewer token command — set $mint_var (or LOG_EXPERIMENT_REVIEWER_TOKEN_CMD), a command taking <owner/repo> minting a ${REVIEWER_FAMILY,,}-engineer token"
TOK="$($REVIEWER_MINT "$RESEARCH_REPO" 2>/dev/null || true)"
[ -n "$TOK" ] || die "could not mint ${REVIEWER_FAMILY,,}-engineer reviewer token for $RESEARCH_REPO"
# Validate repo access BEFORE any mutation (a token that can't reach the repo would strand a half-open PR).
GH_TOKEN="$TOK" gh api "repos/$RESEARCH_REPO" -q .full_name >/dev/null 2>&1 \
  || die "reviewer token cannot access $RESEARCH_REPO (is the ${REVIEWER_FAMILY,,}-engineer App installed there?)"

# ---- branch in a DEDICATED worktree (never disturbs the shared tree) ----
cd "$REPO_ROOT"
git fetch origin --quiet
BRANCH="log/${SLUG}"
WT="$(mktemp -d)/wt"
cleanup() { git worktree remove --force "$WT" >/dev/null 2>&1 || true; git branch -D "$BRANCH" >/dev/null 2>&1 || true; }
trap cleanup EXIT
git worktree add -q -b "$BRANCH" "$WT" origin/main || die "could not create worktree/branch (does $BRANCH already exist?)"

mkdir -p "$WT/$(dirname "$REL")"
cp -r "$DIR" "$WT/$(dirname "$REL")/"
git -C "$WT" add -- "$REL"                          # respects the dir's .gitignore (large artifacts stay on R2)
git -C "$WT" diff --cached --quiet && die "nothing to commit for $REL (all gitignored?)"
git -C "$WT" commit -q -m "Log $KIND: $REL"
git -C "$WT" push -q -u origin "$BRANCH"
HEAD_SHA="$(git -C "$WT" rev-parse HEAD)"   # bind the merge to exactly the reviewed commit

# ---- PR -> bot approve -> merge ----
BODY="$(printf '%s\n\nLogged by log-experiment.sh (gate: %s).' "$APPROVAL_BODY" "$KIND")"
URL="$(gh pr create -R "$RESEARCH_REPO" --head "$BRANCH" --base main \
        -t "Log $KIND: $REL" -b "$BODY")"
PR="$(echo "$URL" | grep -oE '[0-9]+$')"
note "opened PR #$PR ($URL)"
GH_TOKEN="$TOK" gh pr review "$PR" -R "$RESEARCH_REPO" --approve --body "$APPROVAL_BODY" >/dev/null
gh pr merge "$PR" -R "$RESEARCH_REPO" --squash --delete-branch --match-head-commit "$HEAD_SHA" >/dev/null
note "merged PR #$PR (head $HEAD_SHA)"

# ---- sync local main (ff-only, ONLY if this checkout is on main; never touches other uncommitted work) ----
git fetch origin --quiet
if [ "$(git rev-parse --abbrev-ref HEAD)" = "main" ]; then
  git merge --ff-only origin/main >/dev/null 2>&1 || note "local main not fast-forwardable; left as-is"
else
  note "checkout is on $(git rev-parse --abbrev-ref HEAD), not main; skipping local sync"
fi
echo "OK: logged $KIND '$REL' as PR #$PR (merged)."   # the EXIT trap removes the temp worktree + its local branch
