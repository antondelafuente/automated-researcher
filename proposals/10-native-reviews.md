# Proposal: native GitHub reviews instead of comments (#10)

> The canonical design doc (ADR + PR description). Reviewed by `--scaffold` before build. Lands on main.

## Problem

The cross-family code review posts its verdict as a **PR comment**. That gives a durable record but it is
NOT a native GitHub review, so it can't carry an `Approve` / `Request changes` state and can't satisfy a
branch-protection "require 1 approval" rule. Without a real approval, "no change merges until the reviewer
approves" stays convention, not enforcement. This is the code half of Phase 2 (the identity + branch
protection are the operator half, in RUNBOOK.md).

The blocker for a native approval is identity: GitHub forbids approving your own PR, and today the author and
the reviewer run under the same token. So native review needs a SECOND, distinct reviewer identity.

## Approach

Add a **reviewer-identity seam**, `WF_REVIEWER_TOKEN_CMD` — a shell command that prints a fresh token for the
reviewer identity (a *different* identity than the author's `GH_TOKEN`). A command, not a static token,
because the reviewer is a GitHub App and its installation tokens expire (~1h) — the instance points this at a
mint-on-demand helper (App JWT → installation token); a static PAT is just `echo $PAT`. Make the `--code`
review post a native review through it:

- **Approve ONLY at `finish`, never at interim `code-review`** (design-review F1 HIGH). An approval emitted at
  interim review would satisfy branch protection *before* `finish` has run the checks + the final-SHA review —
  letting a stale/early state merge. So: interim `code-review` posts **request-changes** (HIGH>0) or a plain
  **comment** (HIGH=0, "clean, will approve at finish") as the reviewer identity — never an approval. Only
  `finish`, AFTER checks pass and the final-SHA `--code` review is clean (HIGH=0), posts the native
  **`--approve`** on the exact merged SHA. Pair with branch-protection "dismiss stale approvals on new
  commits" so the approval is bound to its reviewed SHA.
- **Reviewer selected by AUTHOR FAMILY** (design-review F2). `author=claude` → the codex reviewer identity;
  `author=codex` has no wired Claude reviewer yet, so it stays comment-only / blocked (fail closed for an
  unsupported direction, never a silent pass). The resolved reviewer login is recorded in the review body.
- **`--scaffold` design review and `classify`** stay as posted comments — they're the design dialogue and the
  shadow-mode record, not the branch-protection gate (the architectural/design gate is the human's, separate).
- **Self-approval guard:** GitHub forbids approving your own PR; if the reviewer identity equals the PR author,
  the approve call fails and we FAIL CLOSED (loud block, not a silent fallback that looks enforced but isn't).

No behavior change when `WF_REVIEWER_TOKEN_CMD` is unset — every current invocation keeps posting comments.

## Alternatives considered

- **Keep comments only** — rejected: can't satisfy branch protection, so enforcement is impossible; the whole
  point of Phase 2 is a real, required approval.
- **One identity, "approve via the API anyway"** — impossible: GitHub blocks self-approval by design. A
  distinct reviewer identity is mandatory, not a nicety.
- **GitHub App now vs machine-user PAT** — orthogonal to this code: both reduce to "a token for a different
  identity" that this seam consumes. The identity mechanism is an operator choice (RUNBOOK), not a code one.

## Blast radius

The SWE pipeline only. Touches `scripts/wf.sh` (the posting path + the seam), `.claude-plugin/plugin.json`
(version bump), and docs (SKILL.md notes the seam; RUNBOOK.md gets the activation steps). No change to the
research product or the instance. With the seam unset, zero behavior change — so it's safe to land before the
reviewer identity exists.

## Rollout + rollback

Staged, matching RUNBOOK: (1) land this code (comments still, seam unset); (2) operator creates the reviewer
identity + sets `WF_REVIEWER_TOKEN_CMD` (a command that prints a fresh reviewer token — e.g. a GitHub App
installation-token minter); (3) test a throwaway change → confirm a native `Approve` posts; (4) only then turn
on branch protection (require 1 approval + dismiss-stale-approvals + include administrators, so the admin
authoring token can't bypass the gate). Rollback is trivial: unset `WF_REVIEWER_TOKEN_CMD` (reverts to
comments) and/or remove branch protection (back to shadow mode). One squash commit; revertible.
