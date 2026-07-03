# Proposal: reader-facing presentation text follows the instance's prose style guide (#317)

> The canonical design doc (ADR + PR description). Reviewed by `--scaffold` before build. Lands on main.

## Problem

Follow-up to #313 / PR #316. That PR added a Presentation subsection to `DESIGN.md` (figure/caption/story
wording, the experiment's human-facing title) and a close-time `presentation_manifest.json` (`title`,
`labels`) in `run-experiment`. Neither says anything about *whose prose conventions* that reader-facing text
should follow. A consuming instance may configure a prose style guide (research-lab's `STYLE.md`: outcome
first, short sentences, jargon explained on first use); today the product gives an agent writing that text no
seam to consult it — the text is just "plain language," full stop.

The original addendum proposing this landed after #316 merged, so the implementor never saw it. Scope was
shaped with the researcher 2026-07-03 (a first implementation attempt, PR #320, was withdrawn mid-shaping and
restarted from a clean issue).

## Approach

Two one-line instance-seam touches, matching the posture #316 already established for the manifest's
publish leg (viewer guidance is consuming-instance work, referenced abstractly, no instance paths/names in the
product doc):

1. **`design-experiment/SKILL.md`, Presentation subsection.** Append one sentence: the figure captions, story
   wording, and the experiment's human-facing title follow the instance's prose style guide when one is
   configured. Unconfigured: the existing plain-language requirement stands on its own — no-op.
2. **`run-experiment/SKILL.md`, close/manifest step.** Append the same sentence, scoped to the manifest's
   `title`/`labels` fields (the two fields that become human-readable text on an instance dashboard).

Both touches are pure instance-seam prose — an abstract pointer ("the instance's prose style guide, when
configured"), never a config key, a file path, or content belonging to any one instance. This mirrors the
existing viewer-guidance seam in `run-experiment/SKILL.md`'s publish-leg paragraph: the product states that an
instance-owned convention exists and where it applies; the instance supplies (or doesn't supply) the guide
itself.

Explicitly out of scope (per the issue): `RESULTS.md` prose, issue text, review text — those are
agent-to-agent surfaces, not reader-facing, and stay untouched.

No version bump needed beyond the standard plugin.json bump for `experiment-lifecycle` (behavior-change
convention already used by #316) since both files it edits (`design-experiment/SKILL.md`,
`run-experiment/SKILL.md`) live in that plugin.

## Alternatives considered

- **Name the instance's actual style guide path/file in the product doc.** Rejected — the issue is explicit
  that "the product carries only the seam, never the instance's guide content"; hardcoding a path couples the
  product to one instance's layout, exactly what the seam pattern (viewer guidance, feedback guidance) exists
  to avoid.
- **A new config key in the execution profile (e.g. `[presentation] style_guide_path`).** Rejected — over-scoped
  for a one-line prose seam. The existing seams in this doc (viewer guidance, feedback guidance) don't invent
  config schema either; they state the convention abstractly and let the instance wire it however it likes.
  Nothing in the issue asks for a resolvable path or a script to consult it.
- **Cover `RESULTS.md` / issue / review text too.** Rejected per the issue's explicit scope — those are
  agent-to-agent surfaces, not reader-facing, and the researcher's shaping conversation drew the line there.

## Blast radius

- **Product** (`experiment-lifecycle` plugin): one sentence in `design-experiment/SKILL.md`'s Presentation
  subsection, one sentence in `run-experiment/SKILL.md`'s close/manifest step. `plugin.json` version bump.
- **Not touched:** `verify-claims` (no new audit dimension — this isn't a trustability check, it's a prose
  convention), `log-experiment`, any manifest schema field (no new field — `title`/`labels` already exist),
  any instance config/profile file.
- **Downstream (consuming instance, informational only):** an instance with `~/AGENTS.md` pointing at a style
  guide (e.g. research-lab's `STYLE.md`) now has an explicit product-side hook telling agents writing
  Presentation/manifest text to consult it. An instance with no such guide configured sees no behavior change.

## Rollout + rollback

Documentation-only (two one-line prose additions); no runtime/schema change. Effective on the next
experiment designed/executed by an agent reading the updated skills. Rollback is a plain revert of the PR.
