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

Define ledger terminal status as **operational run health** — did the intended procedure execute and reach a
valid planned close — at the exact points `run-experiment` already tells executors to write or self-audit it,
and cross-reference that definition from the `CHECKLIST.md` legend where `[BLOCK] FAIL` is defined, so the two
terms are distinguished at both places an executor reads them.

**Definition (the load-bearing part):**
- `failed` (ledger) = a **technical execution failure or experiment bug** prevented the intended procedure
  from reaching a valid planned close (a crash, an OOM, a save/load corruption, a driver bug, an unhandled
  provider error). It never encodes whether a hypothesis was supported, an effect was large, an
  interpretation was favorable, or a measurement/validity gate passed.
- A **correctly executed planned no-go or stop at an instrument/data/validity gate is operationally `done`**
  — the procedure ran as designed and reached its planned close; the gate result is a *scientific/measurement*
  outcome, not an *operational* one. The limitation is preserved where it belongs: the `CHECKLIST.md` gate
  stays `FAIL` (the validity trail), and `RESULTS.md` + the ledger note say plainly that the gate didn't pass
  and what that means for the data — never smoothed over.
- `killed` stays for a deliberate stop (a `/quit`, an explicit abandon) — unchanged.
- `[BLOCK] FAIL` in `CHECKLIST.md` is explicitly a **validity-trail term**, distinct from ledger `failed`: it
  can legitimately co-occur with ledger `done` (the gate correctly stopped a valid, complete execution) or
  with ledger `failed` (the gate caught a symptom of a genuine technical break). The checklist FAIL still
  blocks continuation exactly as today (load-bearing flag, fix-or-clear before proceeding) — this proposal
  does not touch that behavior, only what gets written to the *ledger* once the run reaches its close.
- No numerical threshold is introduced anywhere (no "effect size > X ⇒ failed"). The data-vs-verdict
  philosophy is unchanged: `RESULTS.md` still describes the data per the DESIGN spec and never pre-registers
  a verdict; this proposal only disambiguates the *operational* ledger axis from that scientific axis, which
  was always meant to be orthogonal to it.

**Where this lands (both are read at the point executors act, per the Issue's acceptance criteria):**
1. `plugins/experiment-lifecycle/skills/run-experiment/SKILL.md` — Step 4 ("Log the run in your ledger") gets
   the operational-health definition inline, since that's the actual write action; the Step 5
   tear-down-on-block bullet is tightened so "instrument-failure" (currently ambiguous — could mean a genuine
   fault or a gate that correctly said no-go) doesn't imply `failed` by default; the close self-audit bullet
   (which re-checks the ledger's folded status is terminal) gets a one-line cross-reference so a self-auditing
   executor doesn't need to re-derive the distinction.
2. `plugins/experiment-lifecycle/skills/design-experiment/templates/CHECKLIST_TEMPLATE.md` — the executor
   legend (where `[BLOCK] FAIL` is already defined) gets a one-line cross-reference to the ledger definition,
   and the `[BLOCK] Ledger's folded/latest status is TERMINAL` gate gets a clause naming which terminal value
   a planned gate-stop should record.
3. `plugins/experiment-lifecycle/.claude-plugin/plugin.json` — version bump (behavior change to executor
   guidance); CHANGELOG-style line in the commit message per repo convention (no separate CHANGELOG file in
   this repo).

No code changes — this is purely documentation/guidance (the ledger schema and its terminal-set enum are
already instance-owned and already include `done`/`failed`/`killed`; this proposal defines *which* to pick,
not the schema).

## Alternatives considered

- **Add a fourth ledger status** (e.g. `stopped_at_gate`) distinct from `done`/`failed`/`killed`. Rejected:
  it would require every consuming instance's ledger recipe + dashboard to learn a new terminal value, is a
  schema change (out of scope — the Issue asks for a semantic definition, not a new enum member), and the
  CHECKLIST/RESULTS note already carries the "why" a `done` run had a gate stop; the dashboard's job is run
  health, and a correctly-executed no-go IS healthy.
- **Leave it to instance-level ledger-recipe documentation.** Rejected: the ambiguity is in the *product's*
  executor guidance (`run-experiment` is what tells an executor to write the status in the first place), so
  the definition belongs where the write instruction lives — an instance's ledger recipe only defines the
  terminal *set*, not what each member means.
- **Only touch `CHECKLIST_TEMPLATE.md`.** Rejected: the Issue's incident happened at ledger-write time
  (`run-experiment` Step 4/5), and the template legend alone wouldn't reach an executor who reads `SKILL.md`
  once and works from CHECKLIST after.

## Blast radius

Product-only (`automated-researcher`), confined to the `experiment-lifecycle` plugin's executor-facing docs:
`run-experiment/SKILL.md` and `design-experiment/templates/CHECKLIST_TEMPLATE.md` (consumed by both skills at
design-time and run-time). No script/schema/code changes; no instance-repo or ship-change (`agentic-engineering`)
changes. Read by every future executor at close; does not affect any in-flight experiment's already-written
ledger entries (out of scope — no backfill).

## Rollout + rollback

Low-risk doc change; ships directly via the standard cross-family review + checks. Rollback is a plain revert
if the wording turns out to need another pass. No migration needed — the next executor to close a run simply
reads the clarified guidance.
