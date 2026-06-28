# Proposal: Revert #122 — the bounded-wait overlay (it broke detached-run economics) (#224)

> The canonical design doc (ADR + PR description). Reviewed by `--scaffold` before build. Lands on main.

## Problem

PR #122/#160 (`cef1342`, June 27) added a "bounded background waits — silence is not progress" rule to
AGENTS.md and restated it at every waiting surface (run-experiment, ship-change SKILL+RUNBOOK,
verify-claims), plus a 20-min `WF_REVIEW_TIMEOUT` hard-cap on the reviewer subprocess in `wf.sh`.

The rule's "each tick, **continuously verify** liveness + positive-progress; silence is not progress;
watch with a background until-loop" pressure **flipped the detached-run model**: from "arm a ~12-min
self-wake, **end the turn, sleep**, get re-invoked to check" → to "keep the turn alive and **poll**." On
Codex (no `CronCreate` wake) that's a continuous in-turn poller; on Claude the until-loop keeps the turn
alive too. Each poll re-reads the cached experiment context (which Codex bills), so a detached run
drained the 5-hour quota. **It worked fine before #122** — the ~12-min heartbeat.

## Approach

**Revert `cef1342` in full** (a `git revert`, conflicts resolved against intervening PRs):

- Remove the bounded-wait rule prose from AGENTS.md + run-experiment + ship-change SKILL/RUNBOOK +
  verify-claims. This restores the **pre-#122 behavior** (the ~12-min heartbeat that worked) by removing
  the continuous-verify pressure. The older until-loop / controller-supervised / look-again-deadline prose
  *predates* #122 and is left as-is — so this revert does not by itself fully clean the
  autonomous-vs-controller-supervised wait contract; that cleaner split and the Codex cheap-wait are
  **#223**, not this revert.
- Remove the `WF_REVIEW_TIMEOUT` / `run_verifier_bounded` cap from `wf.sh`. **It's dead code:** `wf.sh`
  only ever runs under an agent, whose own Bash-tool timeout (≤10 min) is *shorter* than the 20-min cap —
  so the agent always catches a hung reviewer first; nothing reaches the cap. (A human runs it
  interactively and Ctrl-C's a hang.)
- Preserve everything later PRs added near these lines (notably #215's read-only-credential contract in
  AGENTS.md and ship-change SKILL).

Net: **−90 / +11** (the +11 are 3 plugin patch-bumps + merge-seam fixups). `aar-engineering` 0.3.34→0.3.35,
`experiment-lifecycle` 0.3.4→0.3.5, `verify-claims` 0.7.5→0.7.6.

## Alternatives considered

- **Surgical hand-edit of run-experiment only** (the first attempt, PR #225 — closed): it deleted the
  *older* liveness/progress content and left AGENTS.md/templates contradicting it → drew HIGHs. A faithful
  full revert is cleaner and consistent.
- **Keep the rule, fix only the Codex wait layer** (the reviewer's suggestion): rejected — the until-loop
  degrades **Claude** too, so it's not a Codex-only problem.
- **Codex's cheap-wait mechanism:** genuinely needed (Codex has no `CronCreate`), but it's a separate
  design — tracked in **#223** (needs-design), not bundled into this removal.

## Blast radius

The bounded-wait rule prose (4 skills + the constitution) and the dead `wf.sh` subprocess cap. The
detached-run economics revert to the working pre-#122 behavior; the review pipeline is unchanged except
the cap removal (which never fired). #215's read-only content is preserved.

## Rollout + rollback

It *is* a revert; to roll back, re-apply `cef1342`. The Codex-side cheap wait lands later via #223.
