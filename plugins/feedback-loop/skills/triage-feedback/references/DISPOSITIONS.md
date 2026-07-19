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
- **`blocked`** — decided but gated on a prerequisite; carries a `blocked-by: #N` body line. (When the
  blocker closes, triage clears the label so it's re-dispositioned, usually to `ready`.)
- **`parked`** — real but deliberately not-now; revisit later. (Distinct from `wontfix` = never.)
- **`other`** — doesn't fit the others; a recurring `other` is the signal to evolve the vocabulary.

**Unlabeled is the resting state.** Every newly filed Issue stays unlabeled — awaiting a triager assessment
(posted as an on-ticket comment, automated-researcher#497) and, on the back of it, a researcher decision —
until it is flipped to one of the labels above. `needs-design` is retired (#497): that resting state is now
simply the absence of a disposition label, not a separate label of its own. (The former `needs-shaping` label
was already folded into it the same way, 2026-07-11.)

**`unlabeled → ready` is the researcher's transition, in every lane.** An agent records the flip only on
the back of an actual researcher conversation, and the flip must **cite it** — a comment on the issue
summarizing/linking the shaping discussion (the triager's assessment comment, when one already exists, is
exactly this citation). An agent asked to *implement* an issue never flips its disposition
label as a step of implementing it — that would let it triage its own way in. This is a norm every lane
follows; a lane's mechanical *enforcement* of it (e.g. a pre-flight before work starts, vs. a gate only at
close) is that lane's own concern to build out. An Issue an agent files (including via `file-feedback`, see
#405) carries exactly a type label plus, when an agent is the filer, exactly one
provenance label (`agent-filed` or `researcher-requested` — see `file-feedback`'s filing instructions for
the class contract) — nothing else besides those: never self-apply `ready`, and never
self-apply `blocked`, `parked`, or `other` either. Those three remain valid dispositions but are
researcher/triage-applied only, same reasoning as never self-applying `ready` — self-parking is a triage
decision. An agent that believes a filing is blocked or parkable says so in the issue body, for the triage
pass to act on.

**Invariant:** every open Issue is EITHER unlabeled (= awaiting a disposition decision) OR carries
**exactly one** disposition. Enforcement flags only an Issue with two-or-more.
<!-- DISPOSITIONS:END -->
