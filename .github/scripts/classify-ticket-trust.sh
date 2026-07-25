#!/usr/bin/env bash
# classify-ticket-trust.sh — decide whether a ticket's author + every comment author canonicalizes into
# the SWE-pipeline engineer allowlist (automated-researcher#625).
#
# automated-researcher#625: `gh issue view --json comments` (GraphQL) supplies a bot-authored comment's
# author login as the BARE App slug (e.g. `codex-engineer`), while the same call's `--json author` for a
# bot-authored issue returns `app/<slug>`. `canonical-login.sh` correctly refuses to reinterpret a bare
# login as an App identity (a same-named plain user account is a different, untrusted identity), so
# feeding it GraphQL-sourced comment logins made every engineer-bot comment fail classification and force
# the whole ticket down the untrusted path (observed on automated-researcher#223). The REST comments
# endpoint's `.user.login` does not have this ambiguity — it already carries the `<slug>[bot]` suffix for
# a bot comment — so the caller MUST source comment logins from there (see triage-assess.yml's gather
# job), never from the GraphQL packet. This script only classifies whatever logins it's given; it is the
# caller's job to fetch them from the right surface.
#
# Usage: classify-ticket-trust.sh <allowlist-space-separated> <author-login> [comment-login ...]
# Prints exactly "true" or "false" to stdout; logs the raw identities + decision to stderr.
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./canonical-login.sh
source "$SELF_DIR/canonical-login.sh"

if [ "$#" -lt 2 ]; then
  echo "usage: classify-ticket-trust.sh <allowlist> <author-login> [comment-login ...]" >&2
  exit 1
fi

allowlist="$1"; shift
author_login="$1"; shift
comment_logins=("$@")

trusted_author=true
for login in "$author_login" "${comment_logins[@]}"; do
  login_canon=$(canonical_login "$login" 2>/dev/null || echo "")
  matched=false
  # Explicit if/then (not a `&&`-chained one-liner): under `set -e`, a bare failing `[ ... ]` in a `&&`
  # list that never reaches `matched=true` would abort this whole script, not just skip the loop body.
  if [ -n "$login_canon" ]; then
    for a in $allowlist; do
      if [ "$(canonical_login "$a")" = "$login_canon" ]; then
        matched=true
      fi
    done
  fi
  if [ "$matched" != true ]; then
    trusted_author=false
  fi
done

echo "author=$author_login comment_authors=${comment_logins[*]:-none} trusted_author=$trusted_author" >&2
echo "$trusted_author"
