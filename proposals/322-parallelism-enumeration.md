# Proposal: Replace serial-edge JUSTIFICATION with parallelism ENUMERATION (#322)

> The canonical design doc (ADR + PR description). Reviewed by `--scaffold` before build. Lands on main.

## Problem

The #311/#312 framing asks the designer to *justify each serial edge* in the schedule, and asks
`design-audit`'s schedule-efficiency dimension to *check the justification*. In practice
(restriction-sweep-1, hours after #312 merged, same day) this produced a circular justification —
"serial edge justified: single shared GPU is the resource limit" — where the single GPU was itself a
discretionary one-pod choice made a line earlier. The design-audit's schedule-efficiency dimension
PASSED it, because both sides were in justification-mode: defending/checking the plan as drawn instead
of generating alternatives. The researcher had to catch it in conversation, again — the same failure
mode #311/#312 were meant to close.

Justification-mode is asymmetric in a way that invites this: it is always easier to justify a choice
already on the page than to independently generate the max-fan-out alternative and compare. The author
writes the schedule, then writes a one-line reason for each serial edge already in it; the auditor reads
the schedule with the same anchor. Neither side is ever forced to produce the parallel alternative and
show why it was rejected.

## Approach

Replace justification with **enumeration** at both ends of the same seam (design + design-audit), with
the researcher's concrete numbers landing verbatim in spirit:

1. **`design-experiment` SKILL.md** (`plugins/experiment-lifecycle/skills/design-experiment/SKILL.md`):
   remove the "justify every serialization" cost-section bullet and the "every serial edge you *do* keep
   must justify itself" line in the schedule-brainstorm bullet. Replace with an enumeration instruction:
   while sketching the schedule, list each step's max sensible fan-out and price it, not just note that
   parallel is allowed. State the researcher's defaults directly (not as escalation thresholds, as norms):
   - 5-10 pods is the NORMAL fan-out for parallelizable GPU work — not a special case needing permission.
   - API concurrency starts at ~50.
   (These are stated as this researcher's/instance's current defaults, adjustable to a design's actual
   execution profile / provider quota — not a universal product constant — same pattern the skill already
   uses for `AAR_STYLE_GUIDE`.)
   - Per-wallclock cost is linear in pod count, so pod-count conservatism buys nothing under that billing
     model — the only real caps are (a) setup/warmup fraction (fan out until setup is roughly 20-30% of
     the unit of work — e.g. ~15-20 min pod warmup against a 1h generation unit is fine at one pod per
     unit), (b) GPU stock/quota, and (c) a true data dependency or validation gate.
   Keep the per-compute vs per-wallclock billing distinction (Tinker-style parallel-is-free vs a rented
   pod) — that framing correctly caught the 2026-07-03 hereditary-ccp-platform incident and isn't part of
   what broke.

2. **`verify-claims` `audit_experiment.sh --design`, dimension 7 (schedule efficiency)**
   (`plugins/verify-claims/skills/verify-claims/scripts/audit_experiment.sh`): reframe the dimension from
   "does every serial edge justify itself" to "enumerate the parallelizable steps and their max sensible
   fan-out; is the design at max fan-out for each, or did the researcher explicitly decline it?" State
   explicitly that a resource limit which is itself a discretionary design choice (e.g. "only one pod") is
   NOT a valid reason to serialize — that's the exact circular pattern that slipped through. Keep the
   per-compute vs per-wallclock billing check (still correct, still the thing that caught the earlier
   incident).

3. Update the matching one-paragraph summary of dimension 7 in `verify-claims` `SKILL.md`
   (`plugins/verify-claims/skills/verify-claims/SKILL.md`) so the two descriptions of the same dimension
   don't diverge — one says "justify," the other says "enumerate."

Companion runtime ticket #323 (API concurrency 50 + watchdog GPU-utilization tracking) touches
`run-experiment`'s runtime concurrency/watchdog text and `design-experiment` SKILL.md for the same reason
(shared serialization language); it is a separate PR, dispatched right after this one merges, to avoid two
concurrent edits to the same file.

## Alternatives considered

- **Keep justification, add a stronger auditor prompt ("be suspicious of resource-limit justifications").**
  Rejected: still asks the auditor to evaluate a justification for a plan already drawn, which is exactly
  the anchor that let the circular case through. Doesn't change the generative/adversarial asymmetry.
- **Require the researcher to co-sign every serial edge.** Rejected: reintroduces per-decision human gating
  that the design stage already avoids elsewhere (the whole point of the audit gates is to let the AAR self-
  correct before consuming the researcher's attention); the enumeration reframe gives the auditor a concrete,
  falsifiable check (is the enumeration complete, is fan-out at the max or explicitly declined) without adding
  a human step.
- **Numeric fan-out floor enforced by tooling (e.g. a checklist gate that fails under N pods).** Rejected as
  out of scope for this issue: the fix here is a documentation/prompt-framing change to two already-existing
  gates, not new tooling; a mechanical floor can't tell a genuine stock/quota cap from under-parallelization
  and would need its own design work.

## Blast radius

Product-scaffold only, in `automated-researcher`: `plugins/experiment-lifecycle/skills/design-experiment/
SKILL.md` (prose), and `plugins/verify-claims/skills/verify-claims/SKILL.md` (prose) + its
`scripts/audit_experiment.sh` — a behavior-affecting change to the prompt text the cross-family design-audit
reads, not just documentation, since it changes what the auditor is asked to check. Both changed plugins
(`experiment-lifecycle`, `verify-claims`) get a `plugin.json` version bump + a `CHANGELOG.md` entry per repo
convention, checked by `.aar-ci/checks.sh`'s version-bump gate. No other skills, no schemas. Affects every
future experiment design and design-audit pass; does not touch `run-experiment`'s runtime text (companion
issue #323, landing right after this PR merges) or any in-flight experiment.

## Rollout + rollback

Doc-only change, takes effect on the next `design-experiment` invocation after merge — no migration, no
staged rollout needed. Rollback is a plain revert of the merge commit if the enumeration framing turns out
worse in practice; low risk given the change narrows rather than removes a check (the billing-distinction
check that caught a real incident is left intact).
