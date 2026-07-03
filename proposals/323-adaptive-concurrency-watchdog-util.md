# Proposal: Runtime throughput defaults — API concurrency starts high, watchdog tracks GPU utilization over time (#323)

> The canonical design doc (ADR + PR description). Reviewed by `--scaffold` before build. Lands on main.

## Problem

Two runtime execution defaults are miscalibrated, both caught during recent experiment runs rather than
at design time — companion to #322 (which reframed the *schedule* side of the same "don't leave cheap
parallelism on the table" failure mode).

**1. API loops start too conservative.** A neutral-corpus generation crawled at ~50 rows/min for hours
against OpenRouter because the client defaulted to a low worker count. Separately, E1 judging ran at 2-3
concurrent workers and became the eval bottleneck (~15 min/student) when the judge API could plainly
absorb far more — ~50 concurrent workers cost nothing on the provider side. Both incidents share a root
cause: the executor picked a small, "safe-sounding" concurrency number up front instead of starting high
and letting backoff discover the real ceiling. `run-experiment`'s existing "Saturate the hardware" bullet
only prompts raising concurrency *reactively*, when GPU utilization is already observed low — it says
nothing about how an API-only loop (no GPU signal to react to) should start.

**2. The watchdog's `nvidia-smi` fold-in (#292) is underspecified.** The dispatcher-side watchdog
(`design-experiment` SKILL.md, "Arm the dispatcher-side watchdog") currently says only that it "may fold
`nvidia-smi` utilization into its periodic check" for a long-running GPU step — no sampling cadence, no
persistence, and critically no judgment rule. A single point-read of `nvidia-smi` mid-cycle is exactly the
kind of one-sample noise the rest of this skill is careful to avoid elsewhere (cf. the DATA AUDIT gate's
distrust of a 2-sample self-smoke). Worse, without an explicit "0% can be fine" carve-out, a naive
point-read risks two failure directions at once: false-alarming during a step where 0% GPU is *expected*
(e.g. waiting on judge API calls) and, symmetrically, sitting on a genuinely flatlined GPU-bound job
because one nudge and a "seems fine" read from a stale process satisfied the check. There's also no stated
bias toward action: with the resume contract already required elsewhere in this skill (checkpointed
state, `TEMP.md` handoff), a flatlined job is cheap to restart and expensive to wait out, but nothing says
so.

The existing cross-reference between the two skills is also stale: `design-experiment`'s watchdog
paragraph points to "`run-experiment`'s concurrency directive" for the nvidia-smi fold-in, but no such
directive exists yet in `run-experiment` — it names something #323 is what creates.

## Approach

Two text-only runtime-directive edits, no new tooling (matches the issue's "Homes" section):

**1. `run-experiment` SKILL.md — new "API loops start high" bullet in Execution discipline.** Added
immediately after the existing "Saturate the hardware" bullet (same section, same altitude, distinct
concern — that bullet is the *reactive* GPU-utilization-driven case, this one is the *proactive* starting
point for any pure API loop):

- Any API loop (LLM judge, corpus generation, batch scoring) starts at ~**50 concurrent requests**, not
  2-3.
- Exponential backoff on 429/timeout; re-ramp back up after recovery (not a permanent step-down).
- States the principle directly: discovering the provider's real limit is the backoff's job, not the
  initial guess's — an initial guess erring conservative just burns wall-clock for free.
- Cites both motivating incidents (corpus generation, E1 judging) so the number isn't arbitrary-looking.

No literal "modest concurrency" string exists in the current skill text (checked directly), so this is a
pure addition, not a replacement — but the new bullet is written to pre-empt any future conservative
default being added here.

**2. `design-experiment` SKILL.md — extend the #292 watchdog paragraph.** Replace the one-line "may fold
`nvidia-smi` utilization into its periodic check too" with the full pattern:

- Sample `nvidia-smi --query-gpu=utilization.gpu,memory.used --format=csv` **several times across the
  ~20-min window**, not once.
- **Append the series** to the run-supervision record — a trend over time, not a point read (matches the
  skill's existing distrust of single-sample judgments elsewhere).
- **Judge in context of the executor's current step**, not against a flat threshold: 0% during "waiting on
  judge API" is fine; 0% for 40+ min during "training/generating" is a flatline. This requires the
  watchdog to already know which checklist step the executor is on — it does (bullet (b) in the same
  paragraph), so the utilization judgment reuses that context rather than adding a new read.
- **Restart-over-wait bias, stated explicitly**: with checkpointed resumable state (the resume contract
  this skill already requires), restarting a flatlined job costs minutes while waiting costs hours — don't
  kill on one bad sample, do recommend a restart on a sustained flatline against a GPU-bound step.

The stale cross-reference is fixed in the same edit: `design-experiment`'s pointer now correctly names
`run-experiment`'s new API-concurrency bullet as the sibling directive (same saturate-don't-idle instinct,
API side vs GPU side), and `run-experiment`'s existing pointer to "`design-experiment`'s watchdog" is left
as the forward pointer for the fuller pattern (no change needed there beyond a small wording touch — it
already exists per the issue's "pointer in run-experiment" requirement).

## Alternatives considered

- **New tooling (a wrapper script for adaptive-concurrency API calls, or a watchdog helper script that
  parses `nvidia-smi` output).** Rejected per the issue's explicit "no new tooling required" — this is a
  text/judgment directive for the executor and watchdog (both model-driven), not a deterministic check
  that benefits from code. Codifying a concurrency ramp-rate or a flatline threshold in a script would
  also fight the "judge in context" requirement, which needs the model's read of *what step this is*.
- **A fixed numeric flatline threshold (e.g. "restart after exactly 3 zero-samples").** Rejected — the
  issue is explicit that this is a judgment call ("don't kill on one bad sample, do recommend restart on a
  sustained flatline"), and a hardcoded count would misfire on legitimately bursty GPU-bound steps
  (data-loading pauses, checkpoint writes) the same way a naive point-read does today.
- **Putting the watchdog utilization text in `run-experiment` instead of `design-experiment`.** Rejected —
  the watchdog itself is dispatcher-side machinery owned by the designer (per #292), not the executor;
  `run-experiment` only needs the pointer, matching the issue's stated "Homes."

## Blast radius

Text-only edits to two files, both in `plugins/experiment-lifecycle/skills/`:
`run-experiment/SKILL.md` and `design-experiment/SKILL.md`. No code, no scripts, no schema changes, no
config. Affects future experiment executions (both the executor's own API-loop defaults and the
dispatcher's watchdog judgment) going forward; does not touch any in-flight run's state or any committed
experiment records. Pure product-scaffold change — no instance-specific config, no secrets.

## Rollout + rollback

Low-risk prose change; lands as a normal scaffold PR through `ship-change`, picked up by AAR sessions the
next time they read the skill (no live-session propagation step required beyond the existing
`update-fleet` broadcast, which is a *reload*, not a required migration). Rollback is a plain `git revert`
of the merge commit if the new defaults prove wrong in practice — nothing downstream depends on the exact
wording, so a revert is fully safe.
