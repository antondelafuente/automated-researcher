# Proposal: move instance patterns out of the committed pre-commit hook (#14)

> Design PM-cleared (audit finding + agreed fix); shipped with a `--code` review. Lands on main.

## Problem

A pre-public audit found the repo is clean of credentials — but the one place instance specifics appear is
the secrets hook itself. `.githooks/pre-commit` hardcodes four instance identifiers as block-patterns — the
R2 bucket name, an account handle prefix, the box's tailnet IP prefix, and the RunPod network-volume ID.
None are credentials and none grant access, but they are instance values living in the public product —
which is exactly what the hook exists to prevent. The hook undercuts its own rule. (This doc deliberately
describes them rather than quoting them, so it doesn't reproduce the values it's removing.)

## Approach

Genericize the committed hook; keep instance-specific patterns local and gitignored:

- The committed `.githooks/pre-commit` keeps only **generic** secret regexes — GitHub personal-access-token
  prefixes, Anthropic and OpenAI API-key prefixes, AWS access-key IDs, PEM private-key headers, RunPod
  API-key assignments, and Google/Slack token prefixes — with no instance values. (Described in prose, not
  quoted: the hook would block a doc that contains its own trigger strings.)
- It **sources an optional `.githooks/patterns.local`** (gitignored): each non-comment line is an extra
  pattern, appended to the set. A clone with no local file still gets the generic protection; this instance
  puts its four identifiers there so they keep being blocked without being committed.
- `.gitignore` gains `.githooks/patterns.local`.

No history rewrite: the four strings are inert identifiers (not secrets), so per GitHub's own guidance a
history purge is overkill — the fix is that the *current public surface* obeys the rule. The hook continues
to skip itself (so editing it never self-blocks).

## Alternatives considered

- **Rewrite history to scrub the strings** — rejected for inert identifiers: force-push churn + GitHub PR
  refs/caches mean it isn't perfectly clean anyway, and there's no secret to purge. Reserved for real secrets.
- **Drop the instance patterns entirely** — rejected: then this instance loses the protection against
  re-committing its own bucket/IP/volume. The local file keeps the protection without the leak.
- **Leave as-is** — rejected: it's the only thing contradicting the repo's no-instance-values rule, right as
  it goes public.

## Blast radius

The SWE pipeline / repo hygiene only: `.githooks/pre-commit` + `.gitignore`. The instance's
`.githooks/patterns.local` is created locally (not committed). No product-plugin behavior changes. This is
the last change before the repo is flipped public.

## Rollout + rollback

Land this, create the local pattern file on the instance, confirm a test commit containing one of the
instance patterns is still blocked, then flip the repo public. Rollback: revert the one commit (restores the
old hook). One squash commit.
