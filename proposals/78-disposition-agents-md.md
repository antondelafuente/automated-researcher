# Proposal: add the disposition-system definition to AGENTS.md (#78)

> The canonical design doc (ADR + PR description). Reviewed by `--scaffold` before build. Lands on main.

## Problem

The disposition design (#74, merged) defined a six-label scheme for the issue tracker and chose `AGENTS.md`
as the **lightweight canonical home** for the *definition* (names + meanings + the invariant + the
`design: #<n>` pointer convention), with the operational procedure living in the instance
`file-feedback`/`triage-feedback` skills. The labels now exist on the tracker, but the definition isn't yet
written anywhere versioned — it lives only in the (closed) design doc. This is the `ready` issue that lands
that definition. It's what #79/#80 (the skills) and #49 (the auto-handler) reference.

## Approach

Add one short section to `AGENTS.md` (after Rules) — constitutional and lightweight, **not** the operational
procedure (per #74 §4 / review F4):

- **The six dispositions, one line each:** `ready` (actionable now, no unresolved design — per #74 review
  LOW3, *not* strictly low-blast: a design-derived child can touch architectural surfaces yet still be
  `ready` because its design is settled), `needs-design`, `needs-shaping`, `blocked` (carries `blocked-by:
  #N`), `parked`, `other` (taxonomy-gap signal).
- **The invariant:** every open issue is EITHER unlabeled (untriaged) OR carries exactly one disposition;
  enforcement flags only two-or-more.
- **The `design: #<n>` pointer convention:** a design-spawned `ready` issue references its origin design issue;
  that pointer (on the child) is the canonical design→implementation link.
- **A pointer** to the operational home: the `file-feedback` (assign) / `triage-feedback` (maintain) skills.

## Alternatives considered

- **Put the full assign/maintain procedure in `AGENTS.md`.** Rejected (#74 review F4): would overload the
  constitution; the procedure lives in the skills, AGENTS.md holds only the definition.
- **Leave the definition only in the label descriptions / the design doc.** Rejected: not a durable,
  discoverable home; the constitution is read every session and is where conventions belong.

## Blast radius

`AGENTS.md` only — one added section, no code, no plugin version bump. Product (SWE-pipeline constitution)
layer. Implements the merged #74 design.

## Rollout + rollback

Lands on main via this PR. Rollback = revert the one-section addition; no dependents break (the skills will
reference it once #79/#80 land).
