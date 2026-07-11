#!/usr/bin/env bash
# canonical-login.sh — canonicalize a GitHub identity login to its allowlist-comparable form
# (automated-researcher#381).
#
# GitHub emits App-authored logins in two different forms depending on API surface:
#   - REST/event-payload fields (github.event.sender.login, .user.login) -> "<slug>[bot]"
#   - `gh ... --json author --jq .author.login` (CLI/GraphQL)            -> "app/<slug>"
# Both denote the SAME identity; only the "app/" form is remapped here, to the "<slug>[bot]" canonical
# form used by every allowlist in this repo. A bare "<slug>" (no prefix, no suffix) is a DIFFERENT,
# untrusted identity (a plain user account, not the App) and must NOT be treated as equivalent — it
# passes through unchanged, so it correctly still fails an allowlist comparison against "<slug>[bot]".
#
# A null/empty login (e.g. a deleted GitHub user) must fail closed with a clear error rather than
# canonicalizing to an empty string, which could accidentally match some other empty value downstream.
# `jq -r` renders a JSON null as the literal string "null" (not empty), so that literal is rejected too.
canonical_login() {
  local s="$1"
  if [ -z "$s" ] || [ "$s" = "null" ]; then
    echo "canonical_login: empty/null login input" >&2
    return 1
  fi
  case "$s" in
    app/*) printf '%s[bot]' "${s#app/}" ;;
    *) printf '%s' "$s" ;;
  esac
}
