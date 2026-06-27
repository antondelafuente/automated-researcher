<!-- DISPOSITIONS:START -->
## Issue tracker — dispositions

Every open Issue carries a **disposition** — how it should be handled — orthogonal to its type
(`bug`/`enhancement`/…) and to open/closed. This is the definition (the product-owned, versioned part). The
assign-at-filing and maintain *procedures* live in the appropriate operating surface: reusable product feedback
machinery belongs in product skills, while deployment-only file bookkeeping belongs in consuming-instance
guidance. AGENTS.md holds the issue contract, not local workflow paths.

- **`ready`** — actionable now, with **no unresolved design** (this refines #74's initial "low-blast"
  wording: a design-derived child can touch architectural surfaces and still be `ready` because its design is
  settled). Implement + merge on the cross-family review + checks. `ready` is the only disposition **eligible**
  for auto-handling — but eligibility is not blind auto-merge: the auto-handler still runs the full
  cross-family review + checks, and the precise boundary of which `ready` Issues it acts on autonomously
  (especially by blast radius) is #49's to define.
- **`needs-design`** — real, but needs a design pass first (the two-phase design flow: a design PR spawns
  `ready` children). Not implemented directly.
- **`needs-shaping`** — a direction, too vague to start; needs scoping into `ready`/`needs-design` first.
- **`blocked`** — decided but gated on a prerequisite; carries a `blocked-by: #N` body line. (When the
  blocker closes, triage clears the label so it's re-dispositioned, usually to `ready`.)
- **`parked`** — real but deliberately not-now; revisit later. (Distinct from `wontfix` = never.)
- **`other`** — doesn't fit the five; a recurring `other` is the signal to evolve the vocabulary.

**Invariant:** every open Issue is EITHER unlabeled (= untriaged, awaiting triage — distinct from
`needs-shaping`) OR carries **exactly one** disposition. Enforcement flags only an Issue with two-or-more.

**Design → implementation link:** a `needs-design` Issue is closed when its design lands (the design PR);
that design spawns `ready` children, each carrying a **`design: #<design-issue>`** body pointer. Code PRs
close `ready` Issues, never a `needs-design` Issue directly.
<!-- DISPOSITIONS:END -->
