# Proposal: Codify the read-only-ambient contract across canonical homes (#167)

> The canonical design doc (ADR + PR description). Reviewed by `--scaffold` before build. Lands on main.
> Doc-only child of the #149 design (`proposals/149-gh-write-identity-guard.md`, merged in #162).

## Problem

The #149 design makes the ambient agent GitHub credential read-only so a bare `gh` write fails closed,
with the engineer-token path as the only way to write. Its three code children have shipped: the guard
wrapper + bypass contract (#165 → #187), the narrow engineer maintainer verbs (#164 → #182), and the
provenance-gated `wf.sh doctor --readonly` detector + the `WF_READONLY_TOKEN_CMD` /
`WF_READONLY_TOKEN_INFO_CMD` seams (#166 → #209). But the *rule itself* — "the ambient agent credential
MUST be read-only by construction; all writes go through the engineer path; `doctor` fails closed on a
token it can't authoritatively confirm" — does not yet live as a stated contract in the constitution.

`AGENTS.md` has the sibling rule (agent writes carry the `*-engineer[bot]` identity) but nothing that
says the ambient credential is read-only by construction. And the plugin's own metadata still frames
ambient writes as merely *convention-gated* ("protected workflow writes use bot identities unless
`WF_ALLOW_AMBIENT_IDENTITY=1`"), which reads as "ambient can write, we just ask it not to" — the stale
pre-#149 mental model. A reader who trusts that metadata over the now-shipped capability layer has the
wrong picture of what the credential can do. The risk is a second, drifting contract: the code enforces
read-only, but the prose says ambient-is-write-capable-by-convention.

## Approach

State the contract **once** as canonical text in `AGENTS.md`, next to the existing engineer-identity
rule, and make every other surface *reference* that one statement rather than restate a competing one.
There is exactly one live contract; the point-of-use surfaces point at it.

1. **`AGENTS.md` (the canonical home).** Add a bullet next to the engineer-identity rule: the ambient
   agent GitHub credential MUST be minted read-only by a controlled minter (so its read-only scope is
   authoritative by construction); all writes go through the engineer token path
   (`WF_ENGINEER_TOKEN_CMD_*`); and `wf.sh doctor … --readonly` fails closed on any ambient token whose
   read-only-ness it cannot authoritatively confirm. Name the product seam an instance implements —
   `WF_READONLY_TOKEN_CMD` (+ `WF_READONLY_TOKEN_INFO_CMD` for the machine-verifiable permissions) —
   mirroring how the engineer-identity bullet already names `WF_ENGINEER_TOKEN_CMD_*`.

2. **Kill the stale write-capable-ambient framing in plugin metadata.** Update the `aar-engineering`
   `plugin.json` description sentence that currently says "Ambient gh is fine for inspection, but
   protected workflow writes use bot identities unless `WF_ALLOW_AMBIENT_IDENTITY=1` is explicitly set"
   so it states the read-only-by-construction reality: ambient gh is read-only (inspection only), writes
   go through the engineer-token path. This is a behavior-description fix, so it bumps the plugin version
   per the constitution.

3. **Point the point-of-use prose at the canonical statement, and fix the residual stale framing in it.**
   `SKILL.md` and `RUNBOOK.md` already carry the read-only rule (pulled forward with the #166 detector).
   Add a "(canonical: `AGENTS.md`)" pointer at those restatements so it's unambiguous which one is the
   source of truth and the others are point-of-need reminders — the same editorial pattern `AGENTS.md`
   already uses for the bounded-background-waits rule ("Each waiting surface restates the minimal rule at
   point of need; this is the editorial home"). Two restatements still describe ambient `gh` as usable
   for "owner/admin maintenance" (`SKILL.md` "Engineer identities are strict…" bullet; `RUNBOOK.md`
   "Ambient gh vs workflow identity" section), which contradicts the #149 contract — owner writes are NOT
   ambient; they require the explicit two-step elevated-owner-token + `WF_GH_ALLOW_OWNER_WRITE=1` path.
   Revise those two so ambient is described as read-only inspection only and owner/admin writes are named
   as the elevated path. No new prose is duplicated.

This is the #149 design's child #3, doc-only by construction: the seams and detector already exist in
code, so codifying the contract is pure documentation + one metadata-string fix.

## Alternatives considered

- **Restate the full contract verbatim in `SKILL.md`/`RUNBOOK.md`/metadata.** Rejected: that creates
  the exact duplicate-live-contract drift the issue warns against — four copies that must be kept in
  sync. One canonical statement + pointers is the maintainable shape.
- **Leave the stale `plugin.json` sentence.** Rejected: it's a user-facing surface (plugin discovery)
  that actively advertises the pre-#149 model, so it is precisely a "stale write-capable-ambient prose"
  the acceptance criteria names.
- **Put the canonical statement in `SKILL.md` instead of `AGENTS.md`.** Rejected: `AGENTS.md` is the
  cross-agent constitution and already holds the sibling engineer-identity rule; the read-only-ambient
  rule is its other half and belongs beside it.

## Blast radius

- **Docs + one metadata string only.** No code path changes; no `wf.sh` behavior change. The shipped
  seams (`WF_READONLY_TOKEN_CMD`, `WF_READONLY_TOKEN_INFO_CMD`, `wf.sh doctor --readonly`) are referenced,
  not modified.
- **`plugin.json` version bump** (behavior-description change to a tracked plugin manifest) — the
  `.aar-ci` version-bump check requires it.
- No API/GPU/data cost. No instance rollout in this child (the instance credential demotion is the
  separate #149 instance task, not product code).

## Rollout + rollback

- Lands as a normal single-phase ship-change PR closing #167. Rollback is a plain revert of the doc
  commit; nothing depends on these strings at runtime.
