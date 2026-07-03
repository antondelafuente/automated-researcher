# Proposal: dispatcher-side executor watchdog + efficiency-mindedness in the lifecycle (#292, #311)

> The canonical design doc (ADR + PR description). Reviewed by `--scaffold` before build. Lands on main.

## Problem

Two related gaps surfaced by the same 2026-07-03 hereditary-ccp-platform run, bundled here because both are
tight, non-overlapping text edits to the same lifecycle skills and land more coherently as one change than as
two competing PRs touching the same files.

**#292 — no standard dispatcher-side watchdog.** A dispatched executor can hit a Claude-Code-side API error
(usually a rate limit) and go **silent-idle mid-turn**: the process is alive, nothing crashed, so the existing
crash supervisor (#54/#170) never fires, and the executor's own self-wake cron is for *benign* idle (a
monitor that silently failed), not for a wedged turn in the *same* rate-limited session — it can't reliably
un-wedge itself. Observed: a rate-limited agent sat stuck for hours despite a cron. The hereditary-ccp-platform
run worked around this ad hoc with a designer-side `/loop 20m` watchdog that captured the executor's tmux pane
and nudged it — but `design-experiment` doesn't ask for this, so it only happens when the designer happens to
remember.

**#311 — no lifecycle prompt for compute efficiency.** Neither the design-audit nor the run-experiment runbook
asks "is this serialization buying anything?" or "is the hardware saturated?" The same run's `DESIGN.md`
declared serial-overnight Tinker training "the cheap default" for 15 LoRA runs — wrong reasoning nothing
caught, because Tinker bills per training compute consumed: 14 parallel submissions cost exactly the same as
14 serial ones (and don't even occupy a pod). The researcher caught it in conversation ("serial is not cheaper
right?"); wall-clock ETA dropped from ~2–4 days to ~1 day at zero cost delta. The design had already passed
verify-claim + design-audit — neither audits the *schedule*.

## Approach

All changes are skill-text edits to `experiment-lifecycle` (`design-experiment`, `run-experiment`) and
`verify-claims` (`audit_experiment.sh --design`'s prompt) — no new scripts, no new plugins.

**1. (#292) Standard dispatcher-side watchdog — `design-experiment` SKILL.md, Step 4 (dispatch).** Arming a
watchdog becomes a required part of the dispatch step, alongside the existing self-wake-arming instruction
given to the executor: the moment the designer dispatches an executor, the designer arms its own `/loop`
(~20 min cadence), one loop per executor. `/loop` is named explicitly as a **Claude Code** facility (the
scheduled-wakeup-that-re-injects-the-prompt mechanism); a Codex designer has no equivalent today — that gap is
cross-referenced to #223 rather than invented here. Each iteration the watchdog reads the executor's live
state (deployment example: `tmux capture-pane -t run-<exp> -p | tail -40`) and assesses three things:
(a) progress vs wedged, (b) which checklist step it's on, (c) whether a load-bearing fork/question is sitting
unanswered. Wedged → a cheap idempotent nudge (`hello`; low-harm if the executor was actually fine). Real
problems → surfaced to the researcher with specifics. The loop stops when the executor reports DONE or is
reaped. Exactly **one** supervision level: the launcher watches the executor; nobody watches the launcher
(two nested failures is out of scope, matching the issue). One-line rationale carried in the text: a model
watcher can judge idle-vs-working from the transcript — the discrimination a model-free probe (#172) cannot
make. Cites the proven pattern (2026-07-03 hereditary-ccp-platform, designer-of-record `/loop 20m`).

**2. (#311) Efficiency-mindedness, generative vs adversarial (per the issue's shaping resolution).**

- **(a) Generative — design stage, `design-experiment` SKILL.md Step 1 (schedule sketching).** While
  sketching the schedule, actively brainstorm what can run concurrently — including restructuring (shard a
  monolithic step, start a step before its wave completes). Multi-pod fan-out is an acceptable **default**
  answer, not a special case needing justification — wall-clock matters.
- **(b) Adversarial-ready — design-experiment SKILL.md Step 1, cost/schedule line.** Upgrade the existing
  "state the parallel-wave shape" cost-estimate line to require **justifying every serialization**: each
  serial edge in the schedule must name what it buys (a validation gate, a true data dependency, or a
  shared-resource limit). "Cheaper" only counts if the billing model actually charges for concurrency —
  distinguish per-compute billing (e.g. Tinker: N parallel runs cost the same as N serial) from per-wallclock
  billing (a rented pod).
- **(c) Adversarial gate — `verify-claims` `audit_experiment.sh --design` prompt.** Add one more audit
  dimension (7, after the existing 6): does the schedule justify every serial edge per (b), and does its cost
  reasoning distinguish per-compute from per-wallclock billing? This is the check that would have failed the
  motivating incident — a design that stated the parallel-wave shape (satisfying the old, weaker line) but
  still snuck an unchallenged serial default past every existing dimension.
- **(d) Runtime backstop — `run-experiment` SKILL.md, Execution discipline.** Independent units (training
  runs, evals, API calls) run concurrently by default; when GPU utilization is low during a long step, raise
  the bottleneck knob (batch size / concurrent requests) and note it in the run log. One line ties back to
  (1): the dispatcher watchdog may include `nvidia-smi` utilization in its periodic check when the pane shows
  a long-running GPU step.

**Versioning:** bump `experiment-lifecycle` (touches `design-experiment` + `run-experiment`) and
`verify-claims` (touches `audit_experiment.sh`), with one `CHANGELOG.md` entry each.

## Alternatives considered

- **Split into two PRs (one per issue).** Rejected per the dispatch instructions: both are small, non-competing
  text edits to the same two `experiment-lifecycle` skills, so one PR avoids a merge race on the same files and
  keeps the two GENERATIVE-vs-ADVERSARIAL edits to the same Step 1 section visibly consistent with each other.
- **A model-free heuristic wedge detector for #292 (the #172 framing).** Already rejected in the issue itself —
  a heuristic can't tell a long healthy turn from a genuine wedge without risking restarting healthy work; the
  model-in-the-loop watchdog is strictly more capable at that judgment call.
- **Fold #311's justification requirement only into the design-audit gate, not the generative design step.**
  Rejected per the issue's own resolution: a gate-only adversarial check is satisfiable vacuously by never
  brainstorming a parallel structure in the first place (the motivating design *did* brainstorm "arms within a
  wave parallel" and still kept an unjustified serial default) — the generative prompt and the adversarial gate
  serve different, complementary purposes and both need to land.
- **One supervision level watching the watcher too (recursive robustness for #292).** Explicitly out of scope
  per the issue: two nested failures at once is rare enough not to design for here.

## Blast radius

Docs-only: `plugins/experiment-lifecycle/skills/design-experiment/SKILL.md`,
`plugins/experiment-lifecycle/skills/run-experiment/SKILL.md`,
`plugins/verify-claims/skills/verify-claims/scripts/audit_experiment.sh` (the `--design` mode prompt text),
plus the two plugins' `plugin.json` version bumps and `CHANGELOG.md` entries. No script behavior changes other
than the added prompt text in the design-audit dimension; no schema, CLI flag, or instance-profile changes. No
migration needed — the next `design-experiment` / `run-experiment` / `--design` audit invocation picks up the
new text.

## Rollout + rollback

Low risk, additive prose + one new audit dimension. Rollback is a plain revert of the diff (no state, no
migration to unwind). No staged rollout needed.
