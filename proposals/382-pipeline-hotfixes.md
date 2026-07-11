# Proposal: fix the two live crashes blocking the GitHub-Actions SWE pipeline (#382, #381)

> The canonical design doc (ADR + PR description). Reviewed by `--scaffold` before build. Lands on main.

This PR closes both #382 and #381: the pipeline cannot implement either issue while the schema crash
in #382 exists (its own acceptance criterion says so), so they ship together in one scoped diff.

## Problem

Two independent bugs in the just-merged GitHub-Actions SWE pipeline block every implementor run:

**#382 — schema crash.** `implement-on-ready.yml`'s `claude_args` passes claude-code-action a
`--json-schema` whose top level contains `allOf` (encoding "status=opened requires integer pr_number").
The Anthropic API rejects any input_schema with `oneOf`/`allOf`/`anyOf` at the top level (400), so the
inner Claude process exits 1 within a second on every run (observed: runs 29133957216, 29133737246;
reproduced locally with the exact schema string). The action hides the underlying API error ("full
output hidden for security"), so the run log only shows an opaque exit-1 — no signal of the real cause.

**#381 — author-gate login-format mismatch.** The "Resolve + authorize issue" step in
`implement-on-ready.yml` compares the issue author from
`gh issue view --json author --jq .author.login` (returns the GitHub App form `app/claude-code-engineer`)
against the allowlist, which uses the REST/event form `claude-code-engineer[bot]`. Every bot-authored
`ready` issue is refused as a result (observed: issue #371, "author 'app/claude-code-engineer' is not
allowlisted"). Event-payload logins (`github.event.sender.login`, `github.actor`,
`github.event.pull_request.user.login`) already use the `<slug>[bot]` form, so those gates currently
pass — only CLI-fetched author fields (`gh issue view --json author`) mismatch.

## Approach

**Fix 1 (#382) — flatten the schema, move the conditional invariant to the shell parser.**
Replace the `claude_args --json-schema` in `implement-on-ready.yml` with the flat schema from the issue:

```json
{"type":"object","required":["status"],"properties":{"status":{"type":"string","enum":["opened","blocked"]},"pr_number":{"type":["integer","null"]}}}
```

The dropped invariant (`status=opened` requires an integer `pr_number`) moves into the existing
"Resolve job outputs" shell step, which already parses `structured_output` — it now fails loudly
(`::error::` + `exit 1`) if `status=opened` but `pr_number` isn't a valid integer, instead of silently
emitting an empty `pr_number` output.

Grepped both workflow files for other top-level `oneOf`/`allOf`/`anyOf` in schema inputs
(`implement-on-ready.yml`'s `--json-schema` and `review-on-pr.yml`'s `output-schema`) — the review
workflow's schema has no such construct, nothing else to fix there.

`show_full_output`: `anthropics/claude-code-action`'s own `docs/security.md` documents enabling it as
acceptable "Working in a private repository with controlled access" (our exact situation — repo is
private, researcher accepts run-log visibility for diagnosability of exactly this class of opaque
exit-1). Setting `show_full_output: true` on the implementor step so a future SDK-launch failure shows
the real API error instead of another silent exit-1.

**Fix 2 (#381) — canonicalize every identity comparison in both workflows.**
Added `.github/scripts/canonical-login.sh`, a small shared shell function:

```sh
canonical_login() {
  local s="$1"
  s="${s#app/}"    # strip leading "app/"
  s="${s%\[bot\]}" # strip trailing "[bot]"
  printf '%s' "$s"
}
```

Applied at the one shell-based identity comparison in either workflow — `implement-on-ready.yml`'s
"Resolve + authorize issue" step — canonicalizing both the fetched `AUTHOR` and each `$ALLOWLIST` entry
before comparing, so `app/claude-code-engineer`, `claude-code-engineer[bot]`, and
`claude-code-engineer` all compare equal. Unknown/garbled logins still fail closed (canonicalizing
doesn't add any new match, it only normalizes the two known suffix/prefix variants).

Audited every other identity comparison in both files per the issue's explicit instruction (don't fix
only the reported site):

- `implement-on-ready.yml` job-level `if:` — `github.event.sender.login` (labeled-event path) and
  `github.actor` (workflow_dispatch path), each checked against the allowlist.
- `review-on-pr.yml` job-level `if:` — the agent-PR predicate,
  `github.event.pull_request.user.login == 'claude-code-engineer[bot]'`.

These three all read event-payload fields, which the issue confirms are already emitted in `<slug>[bot]`
form (they pass today — #371's failure was specifically the CLI-fetched author field). They're also
GitHub Actions `if:` job-gate expressions, evaluated before any step (hence any shell) runs, so the
shared shell function can't reach them directly. Rather than leave them as bare single-form string
comparisons (silently correct today only because of the current event-payload convention, with no
defense if that convention ever drifts), each is widened to accept both the `<slug>[bot]` and
`app/<slug>` forms explicitly in the expression itself — the YAML-expression-level equivalent of
canonicalizing both sides, since the expression language has no string-strip primitive to share a
literal function with the shell side. This is the "audit each one" pass the issue asks for: every
identity comparison in both files now tolerates both known login formats, and anything else still fails
closed.

No other behavior changes: the researcher-authored path (plain `antondelafuente` username, no
suffix/prefix) is untouched by canonicalization (stripping a prefix/suffix it doesn't have is a no-op),
and both fixes are additive/normalizing, not gate-loosening.

## Alternatives considered

- **#382:** keeping `allOf` and hoping the action pre-processes schemas before sending to the API — ruled
  out, the issue reproduced the 400 locally against the exact schema string, so the API itself rejects it
  regardless of the action's plumbing.
- **#381:** allowlisting both literal forms (`claude-code-engineer[bot]` AND `app/claude-code-engineer`)
  in the shell script instead of canonicalizing — rejected per the issue's explicit fix instruction
  (canonicalize, don't dual-list) since dual-listing doesn't generalize to a third representation and
  silently duplicates the allowlist surface.
- **#381 job-level `if:` gates:** restructuring the coarse job-level pre-filters into an early shell step
  (so the shared `canonical_login()` function could gate them too) — rejected as disproportionate to a
  two-bug hotfix; the acceptance criterion is explicit that "no other behavior of either workflow
  changes," and these gates are documented as coarse pre-filters, not the authoritative gate (the
  authoritative gate for implement-on-ready is the shell-based author/label re-check right after).
  Widening the existing expressions to accept both known forms achieves the same robustness without a
  structural change.

## Blast radius

Both files are `.github/workflows/*.yml` in `automated-researcher`'s SWE pipeline (product scaffold, not
the shipped research product). New file: `.github/scripts/canonical-login.sh`. No effect on any other
repo, no effect on the research product runtime.

## Rollout + rollback

Ships as one PR closing both issues. Revert is a plain `git revert` of the merge commit if the pipeline
regresses; no data migration, no state to roll back. Acceptance is validated pre-merge by (a) running the
fixed schema locally against the Anthropic API via `claude --json-schema ... -p ... --model
claude-haiku-4-5-20251001` and confirming no 400, and (b) re-flipping `ready` on #371 after merge so the
concrete case from #381 is the live confirmation.
