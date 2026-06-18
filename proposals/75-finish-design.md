# Proposal: finish --design — merge a design-only PR on the cross-family --scaffold approval (#75)

> The canonical design doc (ADR + PR description). Reviewed by `--scaffold` before build. Lands on main.

## Problem

We want **two-phase design** (the design half of #50): a design-only PR lands a design doc on `main`,
**approved by the opposite-family engineer exactly like a normal coding PR**, and implementation happens
separately as a set of spawned `ready` issues.

ship-change is already structurally two-phase — it scaffolds a design doc, `--scaffold`-reviews it, and only
then implements. But two things block a clean design-only merge:

1. **Only `--code` can approve.** The thing branch protection accepts is a *native APPROVE*. Today only
   `finish`'s `--code` merge gate posts one; `design-review` (`--scaffold`) posts a comment. So "the
   opposite-family agent approves the design" — the model the user wants, identical to coding PRs — is not
   expressible.
2. **`finish` on a design-only PR does the wrong thing.** It re-runs `--code` (code-reviewing a prose doc)
   and gates on that, instead of the design review.

The user is explicit that the design approver should be the **opposite-family agent**, not the human —
same as every other PR. The human steers at design-authoring time, not at merge.

## Approach

A surgical two-part change to `wf.sh`, reusing everything else `finish` already does:

**1. `run_review` learns to approve on `--scaffold` when it is the merge gate.** Today the native-review
(APPROVE-capable) path is gated on `mode == --code`. Widen it to also fire for `--scaffold` **when
`approving=1`** (the merge-gate flag). A regular `design-review` call passes `approving=0`, so it still posts
a comment — unchanged. So `--scaffold` posts a native APPROVE/REQUEST_CHANGES/COMMENT only as the merge gate,
mirroring `--code` exactly.

**2. `finish <wt> <author> [--design]`.** In design mode the merge-gate review is `--scaffold` on the design
doc instead of `--code` on the diff:
- `run_review --scaffold "$WT" "$AUTHOR" "$WT/$DOC" "$PR" "Final design review (merge gate)" 1`
- **Fail-closed guard:** design mode requires the diff to be **design-doc-only** (`proposals/*.md`). If it
  touches anything else, error and point at plain `finish` — so `--design` can NEVER skip `--code` on real
  code. This is the one safety-critical line.
- Everything else is reused unchanged: base-freshness check, push/sync, PR-body refresh, the deterministic
  `checks.sh` (which no-ops on a doc-only diff), the `--match-head-commit` squash-merge, worktree cleanup.

Load-bearing decisions:
- **Symmetric to code, gated on the opposite family.** A `claude-code-engineer`-authored design PR is
  approved by `codex-engineer` (and vice-versa) — not self-approval, satisfies the existing 1-required-review
  branch protection, needs no new infra. Same trust model as every coding PR.
- **`approving=1` is the seam, not a new mode flag in `run_review`.** Reusing the existing approving-gate flag
  keeps `design-review`'s interim behavior byte-for-byte unchanged and confines the new behavior to the merge
  gate.
- **Fail-closed on non-doc diffs.** Because `--design` skips `--code`, it must refuse any PR that contains
  code. The guard is what makes the mode safe to expose.
- **Folder stays `proposals/`.** The `proposals/ → design/` rename is a separate tracked ticket; doing it here
  would widen the diff for no functional gain. `finish --design` reads the doc from `proposals/` like the rest
  of the lifecycle.

## Alternatives considered

- **A separate `design-finish` subcommand.** Rejected: it would duplicate `finish`'s base-freshness / sync /
  checks / merge / cleanup. A `--design` flag on `finish` reuses all of it and keeps one merge path.
- **Human (Anton) approves the design PR.** Rejected by the user: the opposite-family agent is the approver,
  same as coding PRs — the human steers at authoring time, not merge.
- **Let `--scaffold` always post a native review (even interim).** Rejected: would change `design-review`'s
  current comment behavior; gating on `approving=1` confines the change to the merge gate.

## Blast radius

`aar-engineering` plugin only: `wf.sh` (`run_review` one-line condition widen + a `finish` design-mode branch),
the usage text, the `ship-change` SKILL.md two-phase-flow docs, and a `plugin.json` version bump. Additive —
plain `finish` and `design-review` are unchanged for existing (code) PRs; the new behavior only fires on
`finish --design`. SWE-pipeline layer.

## Rollout + rollback

Built single-phase through the normal ship-change flow (this is code, not a design). Its first real use will
be the first **two-phase design** — designing the issue-tracker disposition system (#74). Rollback = revert
the additive commit; existing code PRs are unaffected since their path doesn't change.
