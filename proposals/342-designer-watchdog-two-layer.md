# Proposal: designer watchdog goes two-layer — event-driven Monitor + long merged heartbeat (#342)

> The canonical design doc (ADR + PR description). Reviewed by `--scaffold` before build. Lands on main.

## Problem

The `design-experiment` skill's dispatcher-watchdog contract tells the designer to run `/loop 20m <check the
executor pane, assess checklist step, sample GPU util>` inside the designer's own session, one loop per
executor. That is expensive in exactly the session where context is largest: a designer session accumulates
designs, gate outputs, and page builds (~500k tokens by close), the prompt cache TTL is 5 minutes, and a
20-minute tick is therefore guaranteed cache-cold — every tick re-caches the full history. Measured
2026-07-05 on the carrier-divergence designer session: ~$300 of a ~$337 session was cache reads + cold
re-caches against ~$36 of actual output; two concurrent executors doubled the ticks (two independent 20-min
loops). The watchdog's job needs ~2k tokens (pane text + a small rubric) but executes with the whole
designer history — roughly $150–250/run-day of avoidable spend at current fleet shape, scaling with fleet
size.

The 20-minute cadence exists for wedge detection, but the *terminal* transitions it polls for (executor
prints DONE/BLOCKED, pane disappears) are mechanically greppable and need zero model turns; only the rarer
advancing-vs-frozen judgment needs a model read. The current contract also loads the designer with duties
that belong to the executor's own supervision loop (checklist-step progress accounting, GPU-utilization
series over pod SSH — the #323 fold-in), so the expensive session does the cheap session's work.

## Approach

Replace the watchdog section of `design-experiment/SKILL.md` with a **two-layer supervision split**, per the
shaping on #342. The division of labor is by failure mode:

**Layer 1 — the executor's own independent self-wake owns IDLE detection.** Benign waiting, dead in-session
monitors ("waiting on a monitor whose process silently died"), and no-progress-while-billing escalation are
the executor's job — its self-wake is already required by `CHECKLIST.md` to be an *independent recurring
wake* (cron), precisely so it survives in-session watcher death, and `run-experiment` already carries the
tick contract (done-marker + liveness + positive-progress) and the GPU-saturation runtime backstop (#311).
No new text is needed on the executor side; the designer contract simply stops duplicating it.

**Layer 2 — the designer side owns only SESSION-WEDGE**: the executor's Claude session API-stuck mid-turn,
the one failure the executor's own wake cannot cure (its wake queues behind the stuck turn). Prescribed
implementation, in order:

1. **A shell-side monitor on the executor pane — event-driven, zero model turns while healthy.** On Claude
   Code, the built-in `Monitor` tool (an until-loop watching `tmux capture-pane` output) armed for the
   terminal transitions: the DONE/BLOCKED line and pane-gone. It fires a designer turn only when something
   actually happened; a healthy multi-hour run costs nothing.
2. **ONE long-cadence heartbeat (45–60 min) for silent-wedge detection** — a pane *read* that judges
   advancing-vs-frozen against the previous read and nudges with `send-keys` if frozen (the same cheap,
   idempotent liveness poke as today). When the designer supervises multiple executors, this is **one merged
   heartbeat covering all panes, not one loop per run**.
3. **Optionally, run the heartbeat in a separate small session (a dispatched watchdog)** when the designer
   context is known-large — the heartbeat needs ~2k tokens of context, so a fresh session makes each tick
   near-free instead of a full-history re-cache.

**Explicitly removed from the designer contract:** pod SSH, GPU-utilization sampling (the #323 series
paragraph), and checklist-step progress accounting — those belong to the executor's loop, where they already
live. The stale cross-reference in `run-experiment/SKILL.md` ("the dispatcher watchdog may fold `nvidia-smi`
utilization into its periodic check — see `design-experiment`'s watchdog") is updated to match.

**Kept:** the designer-of-record posture (a nudge is a liveness poke, not driving), exactly one supervision
level, and the Codex-designer gap note — the shell monitor is substrate-neutral, but the heartbeat needs a
periodic-reinvocation primitive Codex lacks today (#223); the fallback stays ad hoc checks at the heartbeat
cadence, and still does not block dispatch.

**One added line on context hygiene:** during supervision phases the designer routes bulk reads (RESULTS.md,
screenshots, long logs) through subagents/forks — context accumulated while babysitting is rent paid on
every future turn of the session, including every heartbeat tick.

## Alternatives considered

- **Shorten the loop below the 5-min cache TTL** (stay cache-warm): wrong direction — 4× the ticks, each
  still carrying full designer context on output, and warmth isn't guaranteed under concurrent session
  activity. The watchdog needs *less context*, not warmer cache.
- **Always dispatch a separate watchdog session per run**: solves the cache burn but adds a session per
  executor and loses the merged-heartbeat economy; the shell monitor already gets the common case
  (DONE/BLOCKED/pane-gone) for free. Kept as the *optional* escalation for known-large designer contexts.
- **Model-free probe only (#172)**: rejected before and still — a grep can't judge advancing-vs-frozen from
  a busy-but-stuck pane. That judgment is exactly what the long heartbeat retains a model turn for; the
  split just stops paying model rates for the greppable part.
- **Drop designer-side supervision entirely** (trust the executor's self-wake): misses the one failure mode
  the executor cannot self-cure — its own session wedged mid-turn — which is the documented, recurring
  reason #292 introduced the watchdog.

## Blast radius

Product skill text only: the watchdog section of
`plugins/experiment-lifecycle/skills/design-experiment/SKILL.md` (the #292 + #323 paragraphs), one stale
cross-reference sentence in `plugins/experiment-lifecycle/skills/run-experiment/SKILL.md`, and the
`experiment-lifecycle` plugin version bump. No scripts, no templates (CHECKLIST already requires the
executor self-wake as an independent cron), no instance config. The `ship-change` dispatcher contract in
agentic-engineering (a deliberate ~5-min cadence for short-lived code implementors, watched from small
dispatcher sessions) is a different trade-off and is not touched. Live designer sessions pick the new
contract up on `/reload-plugins`; runs already in flight keep whatever loop they armed.

## Rollout + rollback

Doc-only prescription change; no migration. Rollback = revert the commit. If the event-driven monitor
proves unreliable on some substrate, the long heartbeat is still armed independently, so the failure mode
of a bad rollout is "wedge detected in ≤60 min instead of ≤20" — bounded, and cheaper than the status quo
by construction.
