#!/bin/bash
# engineer_gh_issue.sh - minimal self-contained engineer-identity Issue filer, for boxes that lack an
# `aar-engineering` checkout (so `wf.sh issue` isn't on PATH) but DO have the #149 seam configured
# (automated-researcher#454: box sessions with no wf.sh fell back to a raw `gh` write, which impersonates
# the human ambient credential - #447). Mints a short-lived engineer-identity token via the instance-owned
# WF_ENGINEER_TOKEN_CMD_<FAMILY> command (never the ambient credential) and execs `gh issue <verb>` under
# it. Fixed verb surface only (create/comment) - no arbitrary `gh` passthrough, matching wf.sh issue's own
# contract (see triage-feedback SKILL.md).
set -euo pipefail

usage() {
  cat >&2 <<'USAGE'
Usage:
  engineer_gh_issue.sh <claude|codex> create  -R OWNER/REPO -t TITLE -b BODY [-l LABEL]...
  engineer_gh_issue.sh <claude|codex> comment ISSUE_NUMBER -R OWNER/REPO -b BODY

Requires WF_ENGINEER_TOKEN_CMD_CLAUDE or WF_ENGINEER_TOKEN_CMD_CODEX (matching <claude|codex>) to be set to
a command that prints a short-lived, write-scoped GitHub token for that engineer identity on stdout.
USAGE
  exit 1
}

[ $# -ge 2 ] || usage
family=$1; shift
verb=$1; shift

case "$family" in
  claude) token_cmd_var=WF_ENGINEER_TOKEN_CMD_CLAUDE ;;
  codex)  token_cmd_var=WF_ENGINEER_TOKEN_CMD_CODEX ;;
  *) echo "ERROR: family must be 'claude' or 'codex', got '$family'" >&2; exit 1 ;;
esac

token_cmd=${!token_cmd_var-}
[ -n "$token_cmd" ] || {
  echo "ERROR: $token_cmd_var is not set; cannot mint an engineer-identity token." >&2
  echo "Do not fall back to a bare 'gh issue $verb' - it would write under the ambient credential instead." >&2
  exit 1
}

# $token_cmd is an instance-owned config value (the #149 seam), not attacker input - documented contract is
# a shell command line, same eval convention as verify-claims' AUDIT_VERIFIER_CMD override.
token=$(eval "$token_cmd") || { echo "ERROR: $token_cmd_var failed to mint a token" >&2; exit 1; }
[ -n "$token" ] || { echo "ERROR: $token_cmd_var produced an empty token" >&2; exit 1; }

case "$verb" in
  create)
    GH_TOKEN="$token" gh issue create "$@"
    ;;
  comment)
    [ $# -ge 1 ] || usage
    number=$1; shift
    GH_TOKEN="$token" gh issue comment "$number" "$@"
    ;;
  *)
    echo "ERROR: unsupported verb '$verb' (only create/comment)" >&2
    exit 1
    ;;
esac
