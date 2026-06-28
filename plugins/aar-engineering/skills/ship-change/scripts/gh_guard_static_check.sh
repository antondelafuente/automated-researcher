#!/bin/bash
# gh_guard_static_check.sh — fail the build on any UNMARKED internal `gh` call in wf.sh (#165).
#
# The gh write-guard bypass contract: every internal `gh` invocation in wf.sh must carry the WF_GH_INTERNAL
# marker so the guard wrapper passes it straight through. In practice that means the call goes through one of
# the marked helpers: `real_gh` (sets WF_GH_INTERNAL=1), `gh_author` (-> real_gh), or `git_push_author` (sets
# WF_GH_INTERNAL=1 on the push, which itself never calls `gh`). A future call site that does a bare `gh …` or
# `GH_TOKEN=… gh …` would silently regress the bypass and break the pipeline under the wrapper — this check
# catches it deterministically.
#
# Usage: gh_guard_static_check.sh [repo-root]   (defaults to the script's repo root)
set -euo pipefail

ROOT=${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && git rev-parse --show-toplevel 2>/dev/null || echo .)}
WF="$ROOT/plugins/aar-engineering/skills/ship-change/scripts/wf.sh"
[ -f "$WF" ] || { echo "gh_guard_static_check: wf.sh not found at $WF" >&2; exit 2; }

# Scan EXECUTABLE lines for an invocation of the `gh` command. We strip comments and skip strings/heredocs as
# best we can, but the robust rule is: any token-position `gh ` (start of a simple command, or after a pipe /
# `$(` / `&&` / `;` / `GH_TOKEN=…`) that is NOT `real_gh` and NOT one of the marker-setting forms is a fail.
#
# Allowed marked forms:
#   real_gh …                         (the marker helper)
#   GH_TOKEN="…" real_gh …            (token swap + marker helper)
#   WF_GH_INTERNAL=1 gh …             (explicit marker inline — e.g. the git_push_author fallback uses git, not gh)
# A bare `gh …` or `GH_TOKEN="…" gh …` (without real_gh / WF_GH_INTERNAL) is a violation.

violations=0
lineno=0
heredoc_term=""   # when inside a <<EOF heredoc, the terminator we wait for (heredoc bodies are doc text,
                  # NOT shell — a `gh …` in usage()/PR-body text there is never an invocation, so skip them).
while IFS= read -r line; do
  lineno=$((lineno+1))
  # heredoc handling: if we're inside one, skip lines until the terminator; otherwise detect a heredoc start.
  if [ -n "$heredoc_term" ]; then
    # terminator is the line (optionally indented for <<-) equal to the captured word.
    if printf '%s\n' "$line" | grep -Eq "^[[:space:]]*${heredoc_term}[[:space:]]*$"; then heredoc_term=""; fi
    continue
  fi
  # detect `<<EOF` / `<<'EOF'` / `<<-"EOF"` start; capture the (quote-stripped) terminator word.
  if printf '%s\n' "$line" | grep -Eq '<<-?[[:space:]]*["'"'"']?[A-Za-z_][A-Za-z0-9_]*'; then
    heredoc_term=$(printf '%s\n' "$line" | sed -E "s/.*<<-?[[:space:]]*[\"']?([A-Za-z_][A-Za-z0-9_]*).*/\1/")
    # the START line itself can still carry a real `gh` before the `<<`, so fall through and scan it too.
  fi
  # drop full-line comments and trailing comments (cheap; good enough — a `#gh` inside a string is rare and
  # would only cause a FALSE POSITIVE that the author resolves by marking, never a false negative).
  code=${line%%#*}
  # blank out the CONTENTS of quoted strings so a `gh …` mentioned inside an echo/note/error message (not an
  # actual invocation) is not flagged. Replace "..." and '...' bodies with empty quotes. (A gh invocation is
  # never wrapped whole inside one quoted string, so this never hides a real call.)
  code=$(printf '%s\n' "$code" | sed -E "s/\"[^\"]*\"//g; s/'[^']*'//g")
  # normalize: collapse to detect a `gh` invocation token. Match `gh ` preceded by a command boundary.
  # Boundaries: start-of-line (optional leading ws), `|`, `(`, `&`, `;`, `=` (env-prefix), `{`, backtick.
  # Use grep -P for the lookbehind-ish boundary via a character class group.
  if printf '%s\n' "$code" | grep -Eq '(^|[|&;({`]|[[:space:]])gh[[:space:]]'; then
    # It contains a `gh ` token. Now decide if EVERY such token is marked. Replace the allowed forms out and
    # re-test: if a bare `gh ` remains, it's a violation.
    stripped=$(printf '%s\n' "$code" \
      | sed -E 's/real_gh/REAL/g' \
      | sed -E 's/WF_GH_INTERNAL=1[[:space:]]+gh/MARKEDGH/g')
    # remove the KNOWN non-invocation form `command -v gh` (a PATH probe, not a call) so it doesn't false-flag.
    probe_stripped=$(printf '%s\n' "$stripped" | sed -E 's/command -v gh//g')
    # SOUND gate (review F1): ANY remaining token-position `gh ` is a violation — we do NOT gate on a
    # hardcoded subcommand allowlist (a future `gh project|secret|… ` write would slip past one). After
    # stripping the marked forms (real_gh / WF_GH_INTERNAL=1 gh) and the command-probe, nothing legitimate
    # should remain; a survivor is an unmarked internal gh call.
    if printf '%s\n' "$probe_stripped" | grep -Eq '(^|[|&;({`]|[[:space:]])gh[[:space:]]'; then
      echo "VIOLATION wf.sh:$lineno: unmarked internal gh call — route through real_gh/gh_author or set WF_GH_INTERNAL=1" >&2
      echo "    $line" >&2
      violations=$((violations+1))
    fi
  fi
done < "$WF"

if [ "$violations" -gt 0 ]; then
  echo "gh_guard_static_check: $violations unmarked internal gh call(s) in wf.sh — the guard would intercept them. FAIL." >&2
  exit 1
fi
echo "gh_guard_static_check: OK — all internal gh calls in wf.sh are marked (real_gh/gh_author/WF_GH_INTERNAL)." >&2
