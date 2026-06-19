# Proposal: implement the two-phase close-gate in `finish` (#85)

> The canonical design doc (ADR + PR description). Reviewed by `--scaffold` before build. Lands on main.

## Problem

The disposition design (#74) + the design-gate design (#50) defined the contract — **code PRs close only
`ready` issues; a `needs-design` issue is closed by its design landing, which spawns `ready` children** — but
nothing enforces it. This issue implements the gate (the `design: #50` child).

## Approach

Add a `disposition_gate` helper to `wf.sh` and call it inside `finish`, **after** the PR/body sync but
**before** the `run_review … approving=1` native APPROVE (a check after the approval would leave a
non-conforming PR approved and manually mergeable — the #50 design HIGH).

The gate, for the PR being finished:
1. Resolve the PR's **closing issues** via the GraphQL `closingIssuesReferences` (GitHub's own `Closes/Fixes`
   + manual-link resolution). Fail closed on lookup error.
2. For each closing issue, read its **disposition labels** (intersection with the six-label set) and require
   the set to **equal** the mode's expected single label:
   - **code mode (`finish`):** every closing issue `== {ready}`, and **≥1** closing issue.
   - **design mode (`finish --design`):** **exactly one** closing issue, `== {needs-design}`.
   Equality (not "contains") fails closed on untriaged (zero dispositions) and on malformed multi-disposition
   issues.
3. On violation: `die` with guidance pointing at the two-phase path — unless **`WF_ALLOW_NONREADY_CLOSE=1`**,
   which proceeds but **posts a PR comment** (engineer identity) recording the override + offending issues, so
   the durable trail shows it.

Token: the existing author token (`ATOK`) — label reads work under the engineer Apps' existing
`contents`+`pull_requests` perms on this **public** repo (verified during the #50 design). `RUNBOOK.md` gets a
note that a **private** install must add `issues: read`.

Load-bearing decisions (all settled in the #50 design):
- **Before the APPROVE, not at merge** — else a vetoed PR is left approved.
- **Equality over the six-label set, fail-closed on zero/multiple** — blocks untriaged + malformed.
- **Symmetric** — design mode enforces its own half (`== {needs-design}`), not just the code half.
- **Override leaves a durable PR-comment trail**, not terminal-only logging.

## Alternatives considered

- **Parse `Closes #N` from the body.** Rejected: `closingIssuesReferences` is GitHub's authoritative resolution.
- **Gate in the classifier (advisory).** Rejected: the classifier records, never blocks; this is a gate.
- (Full alternative set is in the #50 design doc; this issue is its implementation.)

## Blast radius

`aar-engineering` only: the `disposition_gate` helper + one call in `finish` + SKILL.md/usage + RUNBOOK note +
`plugin.json` bump. **Behavior change for all future merges:** a code PR must now close ≥1 `ready` issue; a
design PR must close exactly one `needs-design` issue; violations block (override available). `finish --design`
on the normal path (closes its `needs-design` issue) and code PRs closing their `ready` issue are unaffected.
This is the intended Phase-2 enforcement.

## Rollout + rollback

Lands via a single-phase ship-change run (this PR closes #85, a `ready` issue — and merges via the *current*
`finish`, before the gate is live, so no bootstrap problem). After merge the gate is live for subsequent
finishes. Rollback = revert the additive commit; `WF_ALLOW_NONREADY_CLOSE=1` is the in-place escape hatch
meanwhile. The `disposition_gate` is validated standalone against real PRs/issues before merge.
