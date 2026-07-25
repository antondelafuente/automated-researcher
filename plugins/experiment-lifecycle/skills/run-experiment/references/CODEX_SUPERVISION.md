# Codex-native dispatch and supervision (automated-researcher#223)

Claude Code can dispatch a locked brief to a fresh Claude executor, exchange load-bearing questions with
it, and get cheap regular supervision (`CronCreate` + `LOOK_AGAIN.md` — see `SKILL.md`'s "Arm your
self-wake" section). Codex could not yet do the same thing on equal footing: a Codex designer had no
periodic-reinvocation primitive, so a detached Codex run fell back to an in-turn blocking watcher that
either burned quota polling every 1-3 min, or — worse — could believe it was still waiting on a local
`exec_command`/`write_stdin` session after that handle had gone stale, with no independent wake to catch
it (the 2026-06-29 Japanese-fitness-trigger incident: `write_stdin(session_id=72473,
yield_time_ms=180000)` never returned a tool result, the pod-side run failed ~15 min later, and nothing
noticed until a human resumed the thread by hand). This document is the product-level, substrate-neutral
contract that closes that gap — same shape as `RELAUNCH_SUPERVISOR.md`'s product/instance split, so any
instance that wires a Codex-family dispatch reads from here instead of re-deriving the dangerous parts.

The record this contract writes through is **`run_supervision_record.sh`** — the same helper the Claude
path already uses (`session_handle`, `is-desired-active`, `request-relaunch`, …), extended with the fields
and commands below. One record format, one supervisor, both families — never a parallel Codex-only state
file.

## 1. Same-family fresh executor by default, never a silent fallback

A Codex designer dispatches the locked `DESIGN.md` / `START.md` / `CHECKLIST.md` to a **fresh, zero-context
Codex executor** by default — the same same-family default `design-experiment` Step 4 already states for
Claude. If the substrate genuinely cannot spin up a fresh same-family executor, an operator may explicitly
choose a different one — but that choice must be a **visible, deliberate act**, never a quiet substitution
made because the same-family path was inconvenient. Record which family actually ran the experiment on the
run-supervision record at `start`/`checkpoint`:

```
run_supervision_record.sh start <run-id> --handoff <TEMP.md> --session-handle <opaque> \
  --worktree <path> --executor-family codex --supervision-mode <mode, see §3>
```

`executor_family` is opaque (the product never branches on its value — it is provenance, read by a human
or a future audit asking "who actually ran this"), and it is set once at dispatch, not inferred after the
fact. A brief dispatched to a *different* family than its designer's must say so explicitly in `START.md`'s
executor-disposition section — the override, not the default, is the thing that needs a paper trail.

## 2. The durable two-way control channel — questions without idling, answers without taking over

`run-experiment`'s own disposition already says a load-bearing gap gets flagged to the designer-of-record,
not guessed at, and the executor keeps working on everything the gap doesn't block. What Codex lacked was
a *durable* channel to do that asking through — one that survives the executor's own session churn and
that the designer can answer without stepping into the run. The record now carries a single-in-flight
question/answer inbox:

- **`ask-question <run-id> --text "..."`** (the executor) — records a load-bearing question and a fresh,
  monotonic `question_id`. Refuses if a question is already pending and unanswered (one in flight at a
  time — a second ask before the first is resolved would silently clobber it, and the executor should be
  working on everything else in the meantime, not queuing more questions no one has seen yet).
- **`answer-question <run-id> --text "..." [--question-id N]`** (the designer) — answers the current
  pending question. Passing `--question-id` guards against answering a question that has since moved on
  (mismatched id is refused, not silently accepted).
- **`has-question <run-id>` / `has-answer <run-id>`** — fail-closed predicates (missing/corrupt/terminal
  record reads as "no") for either side to poll cheaply without a full `show`.
- **`consume-question <run-id>`** (the executor) — reads the answer, then clears the pair. Refuses to
  consume a still-unanswered question (that would drop it on the floor); idempotent once already clear.

**`question_route`** and **`terminal_state_route`** (set at `start`/`checkpoint` via `--question-route` /
`--terminal-route`, read back via the `question-route`/`terminal-route` getters) are opaque pointers naming
**how** these signals actually reach a human or a delegated watcher — the default is `record` (poll this
same file, per §5's cadence), but an instance may route through a chat channel, a paging system, or
whatever it already has; the product does not interpret the value, only carries it so the binding is
durable and inspectable rather than living only in someone's memory of "how this run's questions get
answered."

This channel is deliberately not a general-purpose message queue (see Non-goals) — it is exactly the
single load-bearing question/answer/terminal-state seam `design-experiment`'s dispatch contract already
promises, made durable enough to survive a lost local process handle.

## 3. Cheap healthy waiting — capability-detected, honestly classified

Healthy supervision must consume **zero model turns between meaningful events** wherever the substrate
allows it. The rule is a capability check, not a substrate-specific mandate:

- **If an independent, recurring scheduled wake is actually available** (Claude Code's `CronCreate` is the
  worked example — session-scoped, ~12 min cadence, honors `LOOK_AGAIN.md`), use it, and record
  `--supervision-mode autonomous-detached` on the run-supervision record.
- **If no such capability exists** — this is Codex's honest state today: it has no periodic-reinvocation
  primitive, only a blocking wait inside the executor's own turn (`exec_command` + a long `yield_time_ms`,
  or an equivalent detached-shell-plus-poll pattern) — classify the run **`--supervision-mode
  controller-supervised`** and keep that blocking/event-driven watcher alive instead. **Never write
  `autonomous-detached` for a controller-held watcher** — `supervision_mode` is a validated enum on the
  record precisely so this can't drift into an honest-sounding lie about what actually happened if the
  Codex host later gains a real scheduling primitive and an instance forgets to re-classify.

A controller-supervised run is not a worse product than autonomous-detached by construction — it is a
*differently supervised* one, and the record says so plainly rather than overclaiming. What it must not do
is repeat the 2026-06-29 incident: a blocking wait that trusts its own held-open local handle without ever
re-verifying it is still real. So the controller-supervised tick — whatever length `yield_time_ms`/sleep it
uses — must, on EVERY wake (not only after a suspected failure):

1. **Re-verify the underlying process/shell is still alive by its recorded handle** (a pidfile, a session
   id it can independently probe) — never assume a returned wait implies the remote/local process is still
   the one it thinks it is (the same PID-over-`pgrep`, timeout-is-not-death discipline `SKILL.md`'s
   "Long-running process discipline" already requires of every long-running poll in this product).
2. **Check the done-marker, a liveness signal, and a positive-progress signal** — exactly the same
   three-part tick `SKILL.md`'s "Arm your self-wake" section already specifies for the autonomous-detached
   case. Controller-supervised does not relax this; it only changes who is holding the wait open.
3. **Honor a look-again deadline.** A deadline quietly gone past with compute still billing is the same
   signal in either mode: stop re-waiting, diagnose, escalate.

If step 1 ever finds the recorded handle gone or unrecognized, that is a **wedge**, not a reason to
silently re-issue a fresh wait and hope — surface it (see §4) rather than re-creating the exact silent gap
this document exists to close.

## 4. Recovery does not depend on one in-memory exec handle

This is not a new mechanism — `run_supervision_record.sh` and `RELAUNCH_SUPERVISOR.md` are already
substrate-neutral (the whole point of `session_handle` being an opaque, instance-owned value the product
never interprets). The Codex-specific gap was operational, not structural: nothing told a Codex designer to
actually *use* this contract instead of trusting an in-conversation `write_stdin` wait as if it were durable
state. It is not: bind a `session_handle` naming whatever Codex actually gives you (a task/thread id, a
detached-shell pidfile path — whatever is stable enough to re-probe later) at `start`, keep the standing
handoff (`TEMP.md`) and the checkpoint discipline current exactly as `SKILL.md`'s "resume contract"
already requires, and let the model-free relaunch supervisor's existing decision tree
(`resume_same_session` else `launch_successor(handoff_path)`) do the recovery — it does not care which
family the dead session belonged to. `LOOK_AGAIN.md` remains a note a human/watcher reads, never a wake
mechanism in itself, on Codex exactly as on Claude. The model-free idle-cost teardown/reaper (the pod
lease's own expiry) remains the money backstop regardless of supervision mode; it is not a substitute for
the continuity contract above.

## 5. Bounded designer supervision — wedge detection without recaching the world

The two-layer split `design-experiment` Step 4 already defines is substrate-neutral: the executor's own
tick (§3) owns ordinary idle/progress detection; the designer owns only **session-wedge** detection — the
executor's session stuck mid-turn, alive but making no progress, the one failure the executor's own tick
cannot self-diagnose because its own wake queues behind the stuck turn. For a Codex designer specifically,
absent a periodic-reinvocation primitive, run this at a **45-60 min cadence** as an ad hoc/manual check (or
a delegated small watcher session, per Step 4 item 3) reading only the executor's pane/log tail and the
run-supervision record's `status` — never the full design conversation on every tick, which is exactly the
$150-250/run-day regression a prior full-history `/loop` watchdog caused. Do not block dispatch on this gap
being fully automated away — note it, fall back to the manual cadence, and keep supervising; a Codex host
gaining a real scheduled-wake primitive later is a §3 capability upgrade, not a blocker to shipping this
contract today.

## What is INSTANCE, not product (do not put it here)

Per the same boundary `RELAUNCH_SUPERVISOR.md` draws:

- The concrete Codex host API (if any) for arming a scheduled wake, and the exact capability-detection
  probe that decides `autonomous-detached` vs `controller-supervised` for a given Codex host/version.
- The concrete blocking-wait mechanics (`exec_command`/`write_stdin` parameters, a detached-shell-plus-poll
  script, tmux/pane layout) used for the controller-supervised tick.
- Where `question_route`/`terminal_state_route` actually deliver to when they are not `record` (a chat
  channel id, a paging integration).
- The 45-60 min designer-heartbeat cadence's concrete scheduling (a cron entry, a manual habit, a
  delegated watcher session's own wake) for a Codex designer.

## Non-goals (unchanged from the issue)

This contract is not a general-purpose job queue, does not touch or replace Claude's existing same-family
executor path, does not let a controller-held watcher satisfy the autonomous-detached contract merely
because it is well-behaved, and does not hard-code any instance's tmux layout, filesystem paths, model
choice, or Codex host API into the product. A Codex-authored/run experiment still uses **Claude** for the
independent cross-family scientific audit (`verify-claims`) — that boundary is untouched by any of the
above.
