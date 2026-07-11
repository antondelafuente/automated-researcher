# Proposal: implement-on-ready — launch Claude via the pinned CLI directly, replacing the claude-code-action wrapper step (#387)

> The canonical design doc (ADR + PR description). Reviewed by `--scaffold` before build. Lands on main.

## Problem

`implement-on-ready` dies about 0.4s after SDK launch on every run. The diagnosis chain (2026-07-11) has
ruled out every alternative explanation by fix or repro: the author gate (#381), the schema `allOf` (#382),
the CLI version pin (#384), the API key/model (a 200 probe), a virgin `HOME`, the repo cwd, and
stream-json+json-schema mode itself (all pass locally). The decisive test was debug PR #386, which ran the
raw pinned CLI directly on a real `ubuntu-latest` runner in three modes — plain `-p`, the SDK-style
stream-json + `--json-schema` invocation implement-on-ready actually uses, and a `--debug` run — and **all
three exited 0 with clean structured output** (run 29135070985). That isolates the crash to inside
`anthropics/claude-code-action`'s own wrapper (its bun/agent-SDK harness plus injected settings/MCP
config), which matches its open startup-crash issue family (upstream #947, #892, #804).

The researcher's decision, taken after reading the probe verdict: stop routing through the wrapper action
and launch the CLI directly from a plain `run:` step. The wrapper can be re-adopted later, in one step, once
upstream fixes the crash.

## Approach

Replace the single `Run claude-code-action (implementor)` step in `.github/workflows/implement-on-ready.yml`
with plain `run:` steps that do explicitly what the wrapper did implicitly, reusing PR #386 probe 2's proven
invocation verbatim. Everything else in the workflow — triggers, the authorization gate, the App-token mint,
the pinned CLI install (#384), concurrency, and the `enable-automerge` post-step — is unchanged.

1. **Git/gh identity setup.** `git config user.name 'claude-code-engineer[bot]'` + the matching
   `294932622+claude-code-engineer[bot]@users.noreply.github.com` noreply email (the same numeric bot id the
   wrapper step already passed as `bot_id`). Export `GH_TOKEN` as the minted App token so `gh` calls made by
   the agent's own Bash tool are authorized. Configure git push auth via the `x-access-token` remote URL form
   (the same pattern `log-experiment.sh` already uses in this repo) rather than `git remote set-url -u`,
   since the token is ephemeral and scoped to this runner only — no persistent tracking branch to set up.
2. **Render the prompt.** Unchanged: substitute `{{ISSUE_NUMBER}}`/`{{REPO}}` into
   `.github/prompts/implement.md` (already done by the existing `Render implementor prompt` step) and write
   it to a temp file for the CLI's stdin. The template itself carries no claude-code-action-specific
   phrasing that's now factually wrong, so it is not edited.
3. **Run the CLI directly**, piping the rendered prompt as a stream-json user message — the exact invocation
   proven in PR #386 probe 2:
   ```
   claude -p --input-format stream-json --output-format stream-json --verbose \
     --model claude-sonnet-5 --allowedTools Bash,Edit,Write,Read,Grep,Glob \
     --json-schema '<the flat schema already in the workflow>'
   ```
   with `ANTHROPIC_API_KEY` and `GH_TOKEN` in env, `timeout-minutes: 45` on the step, and the stream teed to
   the step log for progress visibility (probe 2's output showed this is line-delimited JSON — `system`/
   `assistant`/`user`/`result` events — safe to tee directly).
4. **Extract structured output — fail loudly, don't fall through.** The probe's final `"type":"result"`
   event carries a top-level `.structured_output` object matching the schema directly (e.g.
   `{"status":"blocked","pr_number":null}`), not the JSON-encoded `.result` string. `set -euo pipefail` on
   the run step means a non-zero CLI exit (a crash, a timeout) already fails the step/job loudly via
   `pipefail` on the `| tee` pipeline — no separate check needed there. But the *existing*
   `Resolve job outputs` step's `jq -r '.status // "blocked"'` silently resolves an **empty** `$STRUCTURED`
   to `status=blocked` with exit 0 (verified: `echo "" | jq -r '.status // "blocked"'` exits 0) — under the
   wrapper, this was safe because the action step itself would already have failed the job before
   `resolve_outputs` ever ran on a launch crash; now that this job owns extraction directly, that silent
   fallback would make a CLI run that exited 0 but produced no result event (or no `structured_output` on
   it) look identical to a real `blocked` decision instead of erroring (design-review finding 1). So the new
   extraction step itself validates before handing off: pull the last `type == "result"` event's
   `.structured_output` from the tee'd log, and if that's empty or `null`, `echo "::error::..."` and
   `exit 1` right there — `resolve_outputs` only ever sees a populated `$STRUCTURED`, and its existing
   `opened` ⇒ requires-valid-`pr_number` invariant enforcement (#382) is otherwise unchanged.
5. Note `--permission-mode bypassPermissions` as the documented fallback knob for tool-permission denials, in
   a comment, without enabling it preemptively — no evidence yet that it's needed.

Out of scope: `review-on-pr.yml` and `checks.yml` (untouched); the `@claude` mention-mode re-entry path (was
wrapper functionality — the `needs-dispatcher` label re-flip stays the retry path); filing the upstream
claude-code-action issue.

## Alternatives considered

- **Wait for upstream to fix claude-code-action.** Rejected: three open crash-family issues (#947/#892/#804)
  with no fix timeline, and the pipeline is fully blocked until this is resolved. The direct-CLI path is a
  one-file, mechanically swappable change; the wrapper can come back later.
- **Pin an older claude-code-action release known not to crash.** Not attempted: the probe already isolated
  the crash to the wrapper's harness itself (not the CLI version, which is independently pinned via #384),
  so a different wrapper version is not a proven fix and would cost another debug cycle to verify.

## Blast radius

Touches exactly one file, `.github/workflows/implement-on-ready.yml` (the `implement` job's launch step),
plus this design doc. No change to `review-on-pr.yml`, `checks.yml`, `.aar-ci/*`, or `.github/prompts/implement.md`.
This is the SWE pipeline's implement leg — a regression here blocks all future `ready`-labeled issues from
being auto-implemented, but does not touch already-merged product code or the research product.

## Rollout + rollback

No staged rollout: this is a single workflow-file swap, exercised for real the next time an issue is
labeled `ready` (acceptance criterion: a re-flip on a bot-authored issue gets past launch with visible
streaming progress). Rollback is trivial — revert the one commit to restore the claude-code-action step,
or re-adopt it directly once upstream fixes the wrapper's startup crash.
