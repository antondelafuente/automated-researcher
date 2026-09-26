#!/usr/bin/env bash
# Shared Claude Code CLI installer for every CLI-running leg of the GitHub-native SWE pipeline
# (implement-on-ready, address-review, senior-engineer, triage-assess's two Fable legs, checks).
#
# Incidents this encodes:
#  - automated-researcher#384/#385: claude-code-action auto-installed an UNPINNED CLI that crashed at SDK
#    launch before any API call ever went out (opaque "SDK execution error", exit 1 — runs 29134553863 /
#    29134534809). The response was a hard `@2.1.207` pin, copy-pasted into six separate workflow steps.
#  - automated-researcher#872: that same hard pin is what kept every pipeline agent a model generation
#    behind. `--model` aliases (`opus`, `fable`) resolve through the CLI's OWN model table, so they only
#    track the newest model if the CLI itself is current. So: install `@latest`, but keep #384's protection
#    by smoke-testing the exact launch path that crashed and falling back to a known-good version when that
#    smoke fails. A `claude --version` check would not have caught #384 at all — the binary installed fine
#    and died at SDK launch, which only an actual one-turn launch reproduces.
#
# Contract the call sites depend on:
#   env  AAR_CLAUDE_SMOKE_MODEL          model alias this caller will really run with (default: opus).
#                                        Smoking with the caller's own alias also proves the alias
#                                        resolves on whatever CLI we just installed — the second half of
#                                        #872's failure mode.
#   env  AAR_CLAUDE_CODE_VERSION         npm dist-tag/version to try FIRST (default: latest). Point it at
#                                        a bogus version to exercise the fallback path on demand.
#   env  ANTHROPIC_API_KEY               required for the smoke. Without it the launch path is unprovable,
#                                        so the known-good version is installed directly (fail-closed) —
#                                        this is the fork-PR `checks.yml` case, where GitHub withholds the
#                                        secret and the run cannot go green anyway.
#   out  path                            absolute path to the resolved `claude` (the pre-#872 contract:
#                                        callers pass it through as CLAUDE_BIN)
#   out  version                         `claude --version` of whatever was resolved
#   out  source                          requested | fallback | fallback-unverified
#
# Degrading to the known-good version is the POINT, so a bad `@latest` never fails this script. The only
# hard failures are "no usable `claude` on PATH afterwards" and a missing prerequisite (jq/npm).
set -euo pipefail

# The single constant the whole pipeline shares. 2.1.282 is what the box runs today (#872); it supersedes
# the 2.1.207 that was hand-copied into six workflow steps. Bumping it is a normal one-line PR here.
FALLBACK_VERSION="2.1.282"

REQUESTED_SPEC="${AAR_CLAUDE_CODE_VERSION:-latest}"
SMOKE_MODEL="${AAR_CLAUDE_SMOKE_MODEL:-opus}"
SMOKE_TIMEOUT_SECONDS="${AAR_CLAUDE_SMOKE_TIMEOUT_SECONDS:-180}"

log() { printf '[install-claude-code] %s\n' "$*" >&2; }

# GitHub annotations, so a fallback is visible in the run's Summary page and not just buried in the log.
annotate_warning() { printf '::warning::%s\n' "$*"; }

emit_output() {
  [ -n "${GITHUB_OUTPUT:-}" ] || return 0
  printf '%s=%s\n' "$1" "$2" >> "$GITHUB_OUTPUT"
}

install_spec() {
  local spec="$1"
  log "npm install -g @anthropic-ai/claude-code@${spec}"
  npm install -g "@anthropic-ai/claude-code@${spec}"
}

claude_path() { command -v claude || true; }

claude_version() {
  local bin="$1"
  "$bin" --version 2>/dev/null | head -n1 || true
}

# A one-turn launch through the SAME stream-json path every caller uses. `--tools ""` is the triage-assess
# idiom for a model that must not be able to touch anything; here it also keeps the smoke to a single turn.
# Returns 0 only on a clean `result` event, which is exactly what #384's crash never produced.
smoke_test() {
  local bin="$1"
  local out_file err_file rc=0 model
  out_file=$(mktemp)
  err_file=$(mktemp)

  jq -nc '{"type":"user","message":{"role":"user","content":"Reply with exactly: OK"}}' \
    | timeout "$SMOKE_TIMEOUT_SECONDS" "$bin" -p --input-format stream-json --output-format stream-json \
        --verbose --model "$SMOKE_MODEL" --tools "" > "$out_file" 2> "$err_file" || rc=$?

  if [ "$rc" -ne 0 ]; then
    log "smoke launch exited $rc"
    tail -n 20 "$err_file" >&2 || true
    rm -f "$out_file" "$err_file"
    return 1
  fi

  # Exit 0 with no result event is the other half of the #384 class (the same shape every run step's own
  # `structured_output` guard checks for), so a clean exit alone is not enough evidence.
  if ! jq -e 'select(.type=="result") | (.is_error // false) | not' "$out_file" >/dev/null 2>&1; then
    log "smoke produced no successful result event"
    tail -n 20 "$out_file" >&2 || true
    rm -f "$out_file" "$err_file"
    return 1
  fi

  model=$(jq -r 'select(.type=="assistant") | .message.model // empty' "$out_file" 2>/dev/null | head -n1 || true)
  log "smoke ok (model alias '${SMOKE_MODEL}' resolved to '${model:-unknown}')"
  rm -f "$out_file" "$err_file"
}

for tool in npm jq timeout; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    printf '::error::install-claude-code.sh requires `%s` on PATH\n' "$tool"
    exit 1
  fi
done

resolved_source=""

if [ -z "${ANTHROPIC_API_KEY:-}" ]; then
  # No key => the launch path cannot be proven, so do not gamble on an unverified @latest.
  annotate_warning "ANTHROPIC_API_KEY is unset: cannot smoke-test the Claude Code launch path, installing known-good ${FALLBACK_VERSION} instead of '${REQUESTED_SPEC}'"
elif install_spec "$REQUESTED_SPEC"; then
  candidate_bin=$(claude_path)
  candidate_version=$(claude_version "$candidate_bin")
  if [ -n "$candidate_bin" ] && smoke_test "$candidate_bin"; then
    resolved_source="requested"
  else
    annotate_warning "Claude Code '${REQUESTED_SPEC}' (${candidate_version:-version unknown}) failed its launch smoke test — falling back to known-good ${FALLBACK_VERSION} (automated-researcher#384/#872)"
  fi
else
  annotate_warning "npm install of Claude Code '${REQUESTED_SPEC}' failed — falling back to known-good ${FALLBACK_VERSION}"
fi

if [ -z "$resolved_source" ]; then
  if ! install_spec "$FALLBACK_VERSION"; then
    printf '::error::npm install of the known-good Claude Code %s failed; no usable CLI on this runner\n' "$FALLBACK_VERSION"
    exit 1
  fi
  resolved_source="fallback"
  # The known-good version failing its own smoke points at the API/runner, not at a bad release, and the
  # real run right after this will surface that loudly on its own. Record it and continue rather than
  # turning a transient blip into a hard pipeline failure.
  if [ -n "${ANTHROPIC_API_KEY:-}" ] && ! smoke_test "$(claude_path)"; then
    resolved_source="fallback-unverified"
    annotate_warning "known-good Claude Code ${FALLBACK_VERSION} also failed its launch smoke test — continuing, but this run is likely to fail"
  fi
fi

resolved_bin=$(claude_path)
if [ -z "$resolved_bin" ]; then
  printf '::error::no `claude` executable on PATH after install\n'
  exit 1
fi
resolved_version=$(claude_version "$resolved_bin")

emit_output path "$resolved_bin"
emit_output version "$resolved_version"
emit_output source "$resolved_source"

# #872 step 3: with `--model` now an alias, "which CLI ran this job" stops being readable off the workflow
# file — so record it where the run itself is read.
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    printf '### Claude Code CLI\n'
    printf -- '- version: `%s`\n' "${resolved_version:-unknown}"
    printf -- '- requested `%s`, resolved via **%s**\n' "$REQUESTED_SPEC" "$resolved_source"
  } >> "$GITHUB_STEP_SUMMARY"
fi

log "resolved ${resolved_version:-unknown} at ${resolved_bin} (${resolved_source})"
