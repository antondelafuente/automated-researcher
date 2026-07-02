# Proposal: log-experiment secret scan — boundary-guard the `sk-` pattern + scope to the diff (#306)

> The canonical design doc (ADR + PR description). Reviewed by `--scaffold` before build. Lands on main.

## Problem

The `log-experiment.sh` note/design-stage secret scan blocks a legitimate journal log on a file already merged
on `main` and untouched by the log — `journal/knowledge/blog_posts/.../evaluation__agent-scaffolds.html`. Two
compounding bugs (issue #306):

1. **`sk-` pattern has no left word boundary.** `sk-[A-Za-z0-9_-]{20,}` matches inside any long hyphenated
   identifier that merely contains `sk-` — here the HTML anchor `...my-agent-task-always-succeeds-in-suspicious-ways`.
   Any committed page with a phrase like `task-always-…` trips it.
2. **The scan greps the entire passed dir, not the changed files.** Pre-existing merged content permanently
   blocks all future note-logs of that dir — and the journal dir is the standard synthesis-pass target, so this
   recurs every pass (worked around 2026-07-02 by `mv`-ing the wiki mirror out and back).

## Approach

Both fixes land in the shared `secret_scan()` helper in `log-experiment.sh` (used by the note and design-stage
gates); nothing else changes.

1. **Boundary guard.** Change the `sk-` alternative to `(^|[^A-Za-z0-9_-])sk-[A-Za-z0-9_-]{20,}` so a match must
   begin at start-of-line or after a non-word/non-hyphen char. The other patterns (`ghp_`/`github_pat_`/`AKIA`/
   PEM) are distinctive enough to leave as-is. Verified: the guard clears the `task-always-…` false-positive
   while still matching real OpenAI/Anthropic-style keys (which appear after `=`, space, quote, or `:`).

2. **Scope to the changed files.** Compute the files under `$REL` that actually differ from
   `origin/$BASE_BRANCH` — tracked diffs (`git diff --name-only origin/$BASE_BRANCH -- "$REL"`, i.e. working
   tree vs base) plus untracked new files (`git ls-files --others --exclude-standard -- "$REL"`, matching the
   `git add`'s gitignore semantics) — and scan only those. This is exactly the delta the PR will introduce
   (the log commits `$DIR`'s current content onto a branch forked from `origin/$BASE_BRANCH`), so a
   pre-existing merged file is never re-scanned.

   **Fail-safe direction.** When `origin/$BASE_BRANCH` is unavailable as a ref, fall back to the current
   full-dir scan — an incomplete diff must never silently narrow the scan. Staleness of the local
   `origin/$BASE_BRANCH` only ever *over*-scans (an older base = a larger delta), so the gate never skips a
   file that a fresh fetch would have flagged; no network fetch is added to the gate. Deleted paths named by
   the diff are filtered out (`[ -f ]`) before grep. An empty delta scans nothing (trivially clean); the
   existing "nothing to commit" guard still catches a truly empty log downstream.

The scan stays fail-closed on grep errors (`rc>1` → die) and still reports only matching filenames, never the
matched secret text.

## Alternatives considered

- **Boundary guard alone** (issue's option a): unblocks *this* case but leaves the whole-dir scan, so any
  future merged file carrying a real-looking `sk-`/`ghp_`/`AKIA` string still permanently blocks the dir.
  Rejected as half a fix.
- **Diff-scope alone** (issue's option b): unblocks the recurring journal case but leaves the brittle `sk-`
  regex to false-positive on any *newly added* hyphenated phrase. Rejected as half a fix.
- **Fetching `origin/$BASE_BRANCH` in the gate** for an exact delta: rejected — adds a network dependency to
  the gate (and to `--dry-run`) for no safety gain, since staleness only over-scans.

Both together (the issue's recommended shape) is the right fix.

## Blast radius

One helper in one script: `plugins/experiment-lifecycle/skills/log-experiment/scripts/log-experiment.sh`
(`secret_scan()`). Product scaffold, SWE-pipeline-shipped. Affects the note and design-stage gates only; the
experiment gate does not call `secret_scan`. No config, interface, or identity changes.

## Rollout + rollback

Single-commit change; revert the commit to restore the prior scan. No migration, no state. The fail-closed
fallback means a worst-case bug (e.g. a bad diff computation) degrades to the current full-dir behavior rather
than to an unscanned log.
