# Proposal: docs for enforced mode — Phase 2 is live (#21)

> Design PM-cleared (the wording is stale post-enforcement). Docs-only; shipped with a `--code` review.

## Problem

The pipeline is now **enforced**: the repo is public, branch protection on `main` requires a counting
`codex-engineer[bot]` approval (the `.aar-ci` checks are enforced by `wf.sh finish`, not yet as GitHub
required status checks), and `include administrators` means even the admin author token can't bypass. But
`wf.sh`, `SKILL.md`, and `RUNBOOK.md` still describe "Phase 1 / shadow mode /
nothing enforced / branch protection not required yet." That's now false and misleading to any reader.

A subtlety to preserve: the **code-review gate** is enforced, but the **classifier / design-gate** is still
*advisory* — the architectural classification is recorded on the PR, not wired to a required `design-gate`
status check. So those "recorded, not blocking" notes are still accurate; they just shouldn't be framed as
"Phase 1 / shadow."

## Approach

Docs-only sweep of `plugins/aar-engineering/skills/ship-change/`:

- **`wf.sh` header + `usage()` + the `SHIPPED:` line + the draft-PR body:** drop "Phase 1 / shadow mode";
  state that the cross-family code review is a native `codex-engineer[bot]` review that branch protection
  *requires* before merge. The `SHIPPED:` line no longer says "(shadow mode)".
- **Keep the genuinely-advisory notes**, reworded off "shadow/Phase 1": the classifier records and never
  blocks; the design/architectural approval is the human's and is recorded, not yet a required check.
- **`SKILL.md`:** replace the "Phase 1 = SHADOW MODE" section with an "Enforced" description (what branch
  protection requires); keep the human-design-gate-is-advisory note.
- **`RUNBOOK.md`:** convert from "how to enable Phase 2" to an **as-built record** of the live config (the
  rules in force, the `codex-engineer` App identity, the reviewer-token seam) — and crucially **keep the
  escape hatches** (admin can edit/disable the rule; revert path) since those are the load-bearing part.
  Add the gotcha learned: an App's approval only counts toward required reviews if it has `contents: write`
  (with `pull_requests: write` alone it posts but reads as `author_association: NONE`).

No behavior change — comments/strings/markdown only.

## Alternatives considered

- **Leave it** — rejected: the docs now actively misdescribe the system as unenforced.
- **Delete the Phase framing entirely** — partly: drop it where it implies "not enforced yet," but keep the
  real remaining boundary (classifier/design-gate advisory) so the docs stay honest about what *is* enforced.

## Blast radius

Docs/strings only: `scripts/wf.sh` (comments + a couple of user-facing strings), `SKILL.md`, `RUNBOOK.md`,
`plugin.json` version. No code path, gate, or branch-protection change.

## Rollout + rollback

Land it; the docs match reality. Rollback: revert the one commit. One squash commit.
