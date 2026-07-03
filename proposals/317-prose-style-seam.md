# Proposal: reader-facing presentation text follows the instance's prose style guide (#317)

> The canonical design doc (ADR + PR description). Reviewed by `--scaffold` before build. Lands on main.

## Problem

#316 added a `Presentation` subsection to `DESIGN.md` (what each headline figure/table plots and what data it
needs) and a close-time `presentation_manifest.json` seam in `run-experiment` (plain-language `title`/`labels`
for a later viewer). Neither says anything about *how the reader-facing wording itself* — figure captions, the
overview-page story/takeaway, the manifest's `title`/`labels`, any reader-facing `RESULTS.md` prose — should be
written. An instance that has already invested in a house prose style guide (short sentences, jargon explained
on first use, outcome first, captions readable cold) has no seam telling the design and execution stages to use
it; that guide only gets applied if a human happens to remember to ask for it. This addendum was raised in a
comment on #313 after PR #316 had already merged, so the original implementor never saw it — filing it
properly as its own issue.

## Approach

Two one-line, config-free instance-seam additions, same posture as the manifest's viewer seam #316 already
added (`run-experiment/SKILL.md`'s "an instance with no viewer configured is simply a no-op here"): the product
states the seam only, never the guide's content, and an instance with nothing configured sees no behavior
change.

1. **`design-experiment/SKILL.md`, Presentation subsection** (Step 1): one added sentence — the figure/caption/
   story wording this subsection specs is written per the instance's prose style guide, when the instance
   configures one.
2. **`run-experiment/SKILL.md`, close-step `presentation_manifest.json` bullet**: the matching sentence — the
   manifest's `title`/`labels` and any reader-facing `RESULTS.md` prose follow the same guide, when configured.

Both are additive prose in an existing bullet — no new gate, no new script, no schema change. The seam is
"when the instance configures a prose style guide, wording follows it"; the product carries no path, no
filename, no format for that guide, matching the repo's existing convention for instance-owned concerns
(execution profile, viewer, session-teardown seam, etc. — all stated abstractly, resolved by the instance).

## Alternatives considered

- **Fold this into #316 instead of a new PR.** Moot — #316 already merged before the addendum comment landed;
  this is the correctly-filed follow-up.
- **Name the guide's path/format in the product** (e.g. point at a specific file convention). Rejected — the
  product only ever states seams, never instance content (same reasoning #316 used for the viewer: "the
  product doc defines the fields on its own terms rather than pointing at that instance's path"). An instance
  wires its own guide however it wants; the product doesn't need to know its shape to say "follow it when one
  exists."
- **A new design-audit or close-checklist gate enforcing style-guide compliance.** Rejected — this is a prose
  seam, not a data-trustability concern; `design-audit`/`CHECKLIST.md` gate collection/persistence facts, not
  writing style. Over-scoped for a one-line addendum.

## Blast radius

- **Product** (this repo): `plugins/experiment-lifecycle/skills/design-experiment/SKILL.md` (one sentence in
  the Presentation bullet) and `plugins/experiment-lifecycle/skills/run-experiment/SKILL.md` (one sentence in
  the `presentation_manifest.json` bullet). Version bump on `experiment-lifecycle/.claude-plugin/plugin.json`
  per the repo's behavior-change convention. No scripts, no schema, no other plugin touched.
- **Not touched:** `verify-claims` (`audit_experiment.sh --design`) — this addendum doesn't add a new
  trustability dimension, so its checklist is unaffected. `CHECKLIST_TEMPLATE.md` is unaffected for the same
  reason.
- **Downstream (consuming instance, informational only):** an instance with a prose style guide configured
  (e.g. this deployment's `journal/writeup/COMMUNICATION.md`) now has an explicit product-level pointer telling
  the design and execution stages to use it; an instance with none configured sees no behavior change.

## Rollout + rollback

No staged rollout — documentation/prompt-text only (two added sentences in existing bullets). Effective on the
next experiment designed/executed by an agent reading the updated skills. Rollback is a plain revert of the PR
if the addition adds friction without value.
