<!-- DISPOSITIONS:START -->
## Issue tracker — dispositions

Every open Issue carries a **disposition** — how it should be handled — orthogonal to its type
(`bug`/`enhancement`/…) and to open/closed. This is the definition (the product-owned, versioned part). The
assign-at-filing and maintain *procedures* live in the appropriate operating surface: reusable product feedback
machinery belongs in product skills, while deployment-only file bookkeeping belongs in consuming-instance
guidance. AGENTS.md holds the issue contract, not local workflow paths.

- **`ready`** — actionable now; any design is settled and lives in the implementing PR itself (design-in-PR).
  Implement + merge on the cross-family review + checks. `ready` is the only disposition **eligible**
  for auto-handling — but eligibility is not blind auto-merge: the auto-handler still runs the full
  cross-family review + checks. No Issue is auto-implemented without an explicit dispatch (a human or a
  dispatcher session naming it); the precise boundary of which `ready` Issues get acted on with less
  oversight (especially by blast radius) is undecided, and will be revisited if/when a standing
  auto-handler is actually proposed.
- **`needs-design`** — default resting state for every newly filed Issue: awaiting a researcher triage/shaping
  pass before it can be flipped to `ready`. This covers both a plain untriaged item and a direction too vague
  to start, scoped into `ready` (possibly a few `ready` tickets) through a conversation with the researcher —
  one resting label, not two. (The former `needs-shaping` label is retired, folded in here: same disposition,
  one name. Backlog swept 2026-07-11 — no open Issue should carry the old label.)
- **`blocked`** — decided but gated on a prerequisite; carries a `blocked-by: #N` body line. (When the
  blocker closes, triage clears the label so it's re-dispositioned, usually to `ready`.)
- **`parked`** — real but deliberately not-now; revisit later. (Distinct from `wontfix` = never.)
- **`other`** — doesn't fit the others; a recurring `other` is the signal to evolve the vocabulary.

**`needs-design → ready` is the researcher's transition, in every lane.** An agent records the flip only on
the back of an actual researcher conversation, and the flip must **cite it** — a comment on the issue
summarizing/linking the shaping discussion. An agent asked to *implement* an issue never flips its disposition
label as a step of implementing it — that would let it triage its own way in. This is a norm every lane
follows; a lane's mechanical *enforcement* of it (e.g. a pre-flight before work starts, vs. a gate only at
close) is that lane's own concern to build out. Agents filing Issues (including via `file-feedback`, see
#405) never self-apply `ready` — an Issue an agent files always lands at `needs-design`, the same resting
state as a human-filed one; only the researcher's explicit flip moves it to `ready`.

**Invariant:** every open Issue is EITHER unlabeled (= untriaged, awaiting triage — distinct from
`needs-design`) OR carries **exactly one** disposition. Enforcement flags only an Issue with two-or-more.
<!-- DISPOSITIONS:END -->
