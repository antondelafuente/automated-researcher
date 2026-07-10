# Proposal: Define ledger terminal status as operational run health, not a scientific verdict (#376)

> The canonical design doc (ADR + PR description). Reviewed by `--scaffold` before build. Lands on main.

## Problem

`run-experiment` tells executors to log a **terminal ledger status** at close (Step 4 "Log the run in your
ledger", Step 5 tear-down-on-block, and the close self-audit gate) and, separately, to resolve every
`CHECKLIST.md` `[BLOCK]` gate to `PASS`/`N.A.`/`FAIL`. Neither the skill nor the `CHECKLIST_TEMPLATE.md`
legend ever states how these two vocabularies relate. An executor closed two correctly-executed Helena
evaluations with ledger status `failed` because an instrument-calibration gate and a parse-coverage gate did
not pass — a **planned, correctly-executed no-go**, not a broken execution. The dashboard then truthfully
rendered two good runs as broken ones.

The root cause is a missing definition, not a missing feature: `failed` reads naturally as "the result was
bad" (a verdict) as easily as "the execution broke" (operational health), and the skill never picks one.

## Approach

Define ledger terminal status as **operational run health** in terms of three **product-owned, abstract
operational outcomes** — not by hardcoding one instance's concrete status strings — at the exact points
`run-experiment` already tells executors to write or self-audit it, and cross-reference that definition from
the `CHECKLIST.md` legend where `[BLOCK] FAIL` is defined, so the two terms are distinguished at both places
an executor reads them.

**The three abstract outcomes (the load-bearing part):**
- **completed-as-designed** — the intended procedure executed and reached its planned close, whatever that
  close turned out to show. This includes a hypothesis that wasn't supported, a small/absent effect, an
  unfavorable interpretation, **and a correctly executed planned no-go or stop at an instrument/data/validity
  gate** — the gate result is a *scientific/measurement* outcome, not an *operational* one. The limitation is
  preserved where it belongs: the `CHECKLIST.md` gate stays `FAIL` (the validity trail), and `RESULTS.md` +
  the ledger note say plainly that the gate didn't pass and what that means for the data — never smoothed
  over.
- **technical-failure** — a technical execution failure or experiment bug prevented the intended procedure
  from reaching a valid planned close (a crash, an OOM, a save/load corruption, a driver bug, an unhandled
  provider error). It never encodes whether a hypothesis was supported, an effect was large, an
  interpretation was favorable, or a measurement/validity gate passed.
- **deliberate-abandon** — a deliberate stop not driven by a technical break (a `/quit`, an explicit human
  abandon of the run) — unchanged from today's `killed`.

**The instance's ledger recipe maps these to its concrete terminal strings — fail closed if it doesn't.**
Recipes stay narrative prose reached by typed pointer (unchanged product architecture, `SCHEMA.md` "Recipes
stay narrative"); this proposal adds **no new config/schema field**. Instead, `run-experiment` now requires
that the ledger recipe's prose state which concrete terminal value corresponds to which of the three
outcomes above (today's common default is `done` / `failed` / `killed`, but the recipe's own words govern for
that instance). An executor writes the concrete value that matches which outcome *actually occurred* — never
one that merely sounds right. **If the recipe's terminal set or its mapping onto these three outcomes isn't
discoverable, or is internally contradictory, the executor fails closed** (flags it, does not guess) — this
extends the existing "don't guess if the terminal set isn't discoverable" line (`SKILL.md`'s close
self-audit) to also cover the *meaning* of each terminal value, not just its existence.

- `[BLOCK] FAIL` in `CHECKLIST.md` is explicitly a **validity-trail term**, distinct from ledger
  `technical-failure`: it can legitimately co-occur with ledger `completed-as-designed` (the gate correctly
  stopped a valid, complete execution) or with ledger `technical-failure` (the gate caught a symptom of a
  genuine technical break). The checklist FAIL still blocks continuation exactly as today (load-bearing
  flag, fix-or-clear before proceeding) — this proposal does not touch that behavior, only what gets written
  to the *ledger* once the run reaches its close.
- No numerical threshold is introduced anywhere (no "effect size > X ⇒ failed"). The data-vs-verdict
  philosophy is unchanged: `RESULTS.md` still describes the data per the DESIGN spec and never pre-registers
  a verdict; this proposal only disambiguates the *operational* ledger axis from that scientific axis, which
  was always meant to be orthogonal to it.

**Where this lands (both are read at the point executors act, per the Issue's acceptance criteria):**
1. `plugins/experiment-lifecycle/skills/run-experiment/SKILL.md` — Step 4 ("Log the run in your ledger") gets
   the three-outcome definition + the recipe-mapping/fail-closed requirement inline, since that's the actual
   write action; the Step 5 tear-down-on-block bullet is tightened so "instrument-failure" (currently
   ambiguous — could mean a genuine fault or a gate that correctly said no-go) doesn't imply
   `technical-failure` by default; the close self-audit bullet (which re-checks the ledger's folded status is
   terminal) gets the mapping/fail-closed extension plus a one-line cross-reference so a self-auditing
   executor doesn't need to re-derive the distinction.
2. `plugins/experiment-lifecycle/skills/design-experiment/templates/CHECKLIST_TEMPLATE.md` — the executor
   legend (where `[BLOCK] FAIL` is already defined) gets a one-line cross-reference to the ledger definition,
   and the `[BLOCK] Ledger's folded/latest status is TERMINAL` gate gets a clause naming which outcome a
   planned gate-stop maps to.
3. `plugins/experiment-lifecycle/.claude-plugin/plugin.json` — version bump; `CHANGELOG.md` gains the
   versioned entry (this repo does carry one — corrected from an earlier draft of this doc that claimed
   otherwise).

No code changes — this is executor-facing guidance; the ledger schema/recipe stays the frozen narrative prose
it already is (`SCHEMA.md` "Recipes stay narrative, reached by typed pointer").

**The consuming-instance side (named, not implemented here).** This box's research-lab already has the
concrete incident this Issue describes: `research-lab#211` corrects the two mislabeled Helena entries
(`helena-lie-direction-1/2`, ledger `failed` → `done`) as **append-only** corrections, preserving the
calibration/parse-coverage caveats in reader-facing prose, and states this instance's `done`/`failed`/`killed`
→ (completed-as-designed / technical-failure / deliberate-abandon) mapping explicitly. That is the
consuming-instance compatibility/backfill work this proposal's product-level definition depends on being
*possible* — it is tracked and actioned in `research-lab`, a separate repo/registry with its own lifecycle,
not part of this PR's blast radius.

## Alternatives considered

- **Hardcode `done`/`failed`/`killed` as THE product vocabulary** (the earlier draft of this proposal).
  Rejected on design review (#377 finding 1): the product contract already delegates concrete ledger
  vocabulary to the instance recipe (`SCHEMA.md` "Recipes stay narrative"); baking one instance's literal
  strings into product guidance would leak instance detail into the product and silently mismatch an instance
  whose recipe uses different strings. The abstract-outcome + recipe-mapping approach above is the fix.
- **Add a fourth *product-level* status** (e.g. `stopped_at_gate`) instead of folding gate-stops into
  completed-as-designed. Rejected: a gate-stop is not a new *operational* category — the procedure still
  reached its planned close — so a fourth bucket would blur run-health back toward a verdict axis; the
  CHECKLIST/RESULTS note already carries the "why" a completed run had a gate stop.
- **Leave it to instance-level ledger-recipe documentation alone, with no product-side definition.**
  Rejected: the ambiguity is in the *product's* executor guidance (`run-experiment` is what tells an executor
  to write the status in the first place), so the abstract definition belongs where the write instruction
  lives; the recipe still owns the concrete mapping, per the approach above.
- **Only touch `CHECKLIST_TEMPLATE.md`.** Rejected: the Issue's incident happened at ledger-write time
  (`run-experiment` Step 4/5), and the template legend alone wouldn't reach an executor who reads `SKILL.md`
  once and works from CHECKLIST after.

## Blast radius

Product-level definition confined to `automated-researcher`'s `experiment-lifecycle` plugin executor-facing
docs: `run-experiment/SKILL.md` and `design-experiment/templates/CHECKLIST_TEMPLATE.md` (consumed by both
skills at design-time and run-time), plus `CHANGELOG.md` + `plugin.json`. No script/schema change — the ledger
recipe stays narrative prose; this proposal only requires that prose state a mapping it may already imply.
**Named downstream dependent:** `research-lab#211` is the coordinated consuming-instance compatibility pass —
it corrects the two already-mislabeled entries (append-only) and states this instance's concrete mapping. That
work is scoped and merged independently in `research-lab`, not part of this PR.

## Rollout + rollback

Low-risk doc change; ships directly via the standard cross-family review + checks. **Rollback is NOT a claim
that persisted ledger events revert** — a doc revert only changes *future* guidance; any ledger row already
corrected under the new definition (e.g. `research-lab#211`'s two rows) stays corrected, because ledger
writes are themselves append-only (never edit-in-place, per the existing `#338` invariant already in
`SKILL.md`). If this definition ever needs walking back, the correction is the same shape as the fix itself:
a **fresh append-only event** stating the corrected status, never a silent rewrite of history. No migration
is needed to *adopt* this doc change — the next executor to close a run simply reads the clarified guidance —
but any *backfill* of past mislabeled rows (this instance's two, or any other instance's) is that instance's
own append-only correction pass, cited above, not a mechanical consequence of merging this PR.
