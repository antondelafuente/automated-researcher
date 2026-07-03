# Proposal: file-feedback etiquette — check issue state before commenting (#318)

> The canonical design doc (ADR + PR description). Reviewed by `--scaffold` before build. Lands on main.

## Problem

`file-feedback`'s Etiquette section tells an agent to prefer commenting on an existing Issue over filing a
duplicate — sound advice when a tracker is a slow-moving backlog. But on a deployment with fast
auto-implementation, a `ready` issue can be picked up, implemented, reviewed, and merged within the hour: the
tracker behaves like a work queue, not a notebook an author can keep annotating.

Two concrete incidents from 2026-07-03: addendum/scope-change comments were posted on #311 and #313 minutes
*after* their implementing PRs (#312, #316) had already merged. The implementor sessions were one-shot and
terminal by the time the comments landed — nobody was watching the issue anymore. #313's lost addendum had to
be manually noticed and re-filed as a new ticket (#317) to get seen at all.

The root cause: nothing in `file-feedback`'s guidance tells the filing agent to check whether the target is
still a live mailbox before writing to it. "Search/read first" (the existing bullet) covers de-duplication on
file, not staleness on comment.

## Approach

Add one bullet to the `## Etiquette` section of `plugins/feedback-loop/skills/file-feedback/SKILL.md`:

> Before posting an addendum or scope-change comment on an existing issue, check its state and whether an
> implementing PR/branch is already in flight (`gh issue view <N> -R "$FEEDBACK_PRODUCT_REPO" --json
> state,closed` / `gh pr list -R "$FEEDBACK_PRODUCT_REPO" --search "<N>" --state open`) — on a deployment with
> fast auto-implementation the tracker is a queue, not a notebook, and a `ready` issue can close within the
> hour. If it is closed or in flight, file a new small ticket linking the old one instead: a comment there is
> a dead letter the implementor never sees. Shaping comments on an open `needs-shaping` issue remain the
> intended flow — this only changes the calculus once an issue is `ready`/in-progress or already closed.

Both liveness checks are scoped with `-R "$FEEDBACK_PRODUCT_REPO"`, matching the existing rule ("Always pass
`-R \"$FEEDBACK_PRODUCT_REPO\"`") so a zero-context agent can't accidentally query the current checkout's
tracker instead of the configured product one.

The existing Route It sentence — "If an Issue exists, add a recurrence comment instead of duplicating it" —
governs a different decision point (dedup search while filing *new* feedback) but can land on the same
closed/in-flight issue this bullet is about. Rather than duplicating the liveness logic there, add a short
parenthetical pointing to the Etiquette check, so the two sections don't give conflicting instructions at the
moment an agent is about to comment on a hit from the dedup search.

Scope is otherwise minimal: no new tooling, no change to Fix-Now. The check is two read-only `gh` calls the
agent already has ambient read access to (no engineer-identity write needed for the check itself — only for
the eventual new-ticket file, which already goes through the existing `wf.sh issue <fam> create` path).

`plugins/feedback-loop/.claude-plugin/plugin.json` version bumps 0.1.2 -> 0.1.3 (non-manifest file changed;
repo's version-bump check requires it).

This is the author-side half of the pattern #315 addresses on the implementor side (pre-flight disposition
check before starting work). Together: an implementor won't start on a non-`ready` issue, and an author won't
write into an issue that's already moved past being writable.

## Alternatives considered

- **Automate the check** (a script/hook that blocks `gh issue comment` on closed/in-flight issues). Rejected
  as over-engineering for one guidance bullet in a skill that already routes all writes through `wf.sh
  issue`/`wf.sh comment`; the fix belongs in agent judgment at file time, not a new mechanical gate. Revisit if
  the pattern recurs after this lands (drain the raw footgun entry into code per `~/AGENTS.md`'s directive
  tier if so).
- **Fold into the existing "Search/read first" bullet** instead of adding a new one. Rejected: that bullet is
  about de-duplication before *filing*; this is about liveness before *commenting on something that already
  exists*. Conflating them would blur two distinct failure modes into one sentence.
- **Wait and let #315's implementor-side fix cover it.** Rejected: #315 only stops an implementor from
  *starting* on a non-ready issue; it does nothing about an author writing an addendum comment onto an issue
  whose PR already merged. Author-side and implementor-side are genuinely different halves.

## Blast radius

Product scaffold only: one new bullet + one short cross-reference parenthetical in
`plugins/feedback-loop/skills/file-feedback/SKILL.md`, plus the paired `feedback-loop` `plugin.json` version
bump. No code, no CI config, no instance-only files touched. Read-only for every consuming deployment until an
agent actually follows the new guidance when filing feedback.

## Rollout + rollback

No staged rollout needed — a doc-only addition to a skill file takes effect the next time an agent reads the
skill. Rollback is a one-line revert of the added bullet if it turns out to misfire in practice.
