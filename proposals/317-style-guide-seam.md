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
   wording, and the experiment's human-facing title follow the instance's prose style guide when the optional
   `AAR_STYLE_GUIDE` env var (a path or URI, read at the point of writing) is set. Unset: the existing
   plain-language requirement stands on its own — no-op.
2. **`run-experiment/SKILL.md`, close/manifest step.** Append the same sentence, scoped to the manifest's
   `title`/`labels` fields (the two fields that become human-readable text on an instance dashboard).

**Design-review finding (accepted, MED):** the first draft of this doc said "when the instance configures
one" with no discoverable seam — an autonomous, zero-context `run-experiment` executor has no way to check
whether a guide exists or where to read it (unlike, say, `EXPERIMENT_SESSION_REAP_CMD` or
`FEEDBACK_INSTANCE_GUIDANCE`, which name a concrete env var). Fixed by naming `AAR_STYLE_GUIDE` directly in
both touches: an optional env var holding a path or URI, mirroring the existing narrow-seam pattern (a named
pointer, not a schema field) rather than the vaguer, unnamed "viewer guidance" phrasing #316 used for a
different (human-driven, at-publish-time) step. The product still carries only the seam **name** — never the
guide's content or a hardcoded instance path.

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
- **A fully abstract, unnamed pointer ("when the instance configures one," no env var).** The first draft's
  approach — rejected by the design review (see finding above): `run-experiment`'s executor is explicitly
  zero-context and autonomous, so "when configured" with nothing to check against is not actionable. A named
  env var (`AAR_STYLE_GUIDE`) is the minimal fix that keeps the executor's read mechanical.
- **A new field in the `aar-profile` execution-profile schema (`SCHEMA.md`).** Rejected as over-scoped — that
  schema is versioned, dual-copy-synced, and validated by `.aar-ci/checks.sh`; a MAJOR-version-free optional
  field would still mean touching both `SCHEMA.md` copies and the profile init/validate scripts for a single
  prose convention. A bare env var (matching the `EXPERIMENT_SESSION_REAP_CMD` / `FEEDBACK_INSTANCE_GUIDANCE`
  precedent already in this plugin family) reaches the same discoverability without the schema machinery.
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
