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
made because the same-family path was inconvenient. *Which* Codex primitive creates that fresh executor is
capability-detected, not assumed — see §7. Record which family actually ran the experiment on the
run-supervision record at `start`/`checkpoint`:

```
run_supervision_record.sh start <run-id> --handoff <TEMP.md> --session-handle <opaque> \
  --worktree <path> --executor-family codex --supervision-mode <mode, see §4>
```

`executor_family` is opaque (the product never branches on its value — it is provenance, read by a human
or a future audit asking "who actually ran this"), and it is set once at dispatch, not inferred after the
fact. A brief dispatched to a *different* family than its designer's must say so explicitly in `START.md`'s
executor-disposition section — the override, not the default, is the thing that needs a paper trail.

## 2. The supervision-bootstrap receipt — dispatch is not complete until this passes (automated-researcher#628)

A successful dispatch call — `create_thread`, a native child-task spawn (§7), or the Claude-path
fresh-session spawn — proves only that the thread/session/child exists, nothing more. If the executor wedges
before writing its own supervision record, binds the wrong worktree/routes/mode, or begins paid work without
its own watcher armed, the designer can fall straight into
§4's healthy zero-turn wait loop with **no durable recovery/control channel behind it** — the exact gap the
prior Claude dispatch closed only by a human habit (babysitting until the executor had actually created its
record, armed its wake, and begun the first real phase, before treating kickoff as complete). This section
makes that check explicit and deterministic instead of a habit a designer might skip under load.

**The executor's side — before any experiment work and before any GPU/API spend:**

1. Immediately after its own thread/session creation succeeds, start the record — the same
   `run_supervision_record.sh start <run-id> --handoff <TEMP.md> --session-handle <opaque> --worktree
   <path> --executor-family codex --supervision-mode <mode> --question-route <route> --terminal-route
   <route>` call §1 already requires, just moved to the FIRST thing the executor does, not something
   deferred until after provisioning.
2. Arm its own watcher/liveness mechanism (§4's controller-supervised blocking wait, or a real
   autonomous-detached wake if the host actually has one) and bind the bootstrap receipt in the same or a
   following call: `run_supervision_record.sh checkpoint <run-id> --look-again <opaque deadline/receipt>`
   — a positive "I am alive and I will check again by this" signal, not a bare "I started." This is the one
   bounded `SUPERVISION_READY` signal the contract asks for: a single deterministic write delivered through
   the record, exactly the way `question_route`/`terminal_state_route` already deliver the Q&A channel
   (default `record`; an instance may route the same signal elsewhere without the product interpreting it).

**The designer's side — before treating dispatch as complete:** run `run_supervision_record.sh
verify-bootstrap <run-id> --executor-family codex --supervision-mode <expected mode> --worktree <expected
path> --question-route <expected route> --terminal-route <expected route> [--timeout-sec N]
[--poll-interval-sec N]`. This polls the record (bounded by `--timeout-sec`, default 300s) until it is
active/desired-active AND every named field matches EXACTLY AND a look-again receipt is bound — the full
bootstrap contract, not merely "a thread exists." A record whose bound fields actively mismatch what the
designer expected (wrong worktree, wrong family, wrong mode, wrong route) fails **immediately**, not after
the timeout — a mismatch never self-corrects by waiting longer. A record that never appears, or never
completes, within `--timeout-sec` fails **at the deadline** instead, with a message distinguishing "never
appeared" from "appeared but never finished."

**Missing, malformed, or timed-out bootstrap is `needs-attention` — not a normal healthy wait.** Treat a
non-zero exit from `verify-bootstrap` as a dispatch failure requiring diagnosis (a wedged executor, a wrong
worktree bound, a stale/reused run-id) with the same seriousness as any other `CHECKLIST.md` `[BLOCK]` gate
FAIL — never silently re-issue the dispatch call again, and never fall into §4's wait loop on a bootstrap that
hasn't actually passed. Once `verify-bootstrap` exits 0, dispatch IS complete (announce the executor per §7 in
that same turn), and healthy supervision returns to the existing §4 zero-turn wait loop — this receipt is a
one-time gate at kickoff, not a recurring poll layered on top of it.

## 3. The durable two-way control channel — questions without idling, answers without taking over

`run-experiment`'s own disposition already says a load-bearing gap gets flagged to the designer-of-record,
not guessed at, and the executor keeps working on everything the gap doesn't block. What Codex lacked was
a *durable* channel to do that asking through — one that survives the executor's own session churn and
that the designer can answer without stepping into the run. The record now carries a single-in-flight
question/answer inbox:

- **`ask-question <run-id> --text "..."`** (the executor) — records a load-bearing question and a fresh,
  monotonic `question_id`. Refuses if a question is already pending — answered or not — until it is
  consumed (one in flight at a time — a second ask before the first is consumed would silently clobber
  it, including overwriting an answer the executor hasn't read yet; the executor should be working on
  everything else in the meantime, not queuing more questions no one has seen yet).
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
same file, per §6's cadence), but an instance may route through a chat channel, a paging system, or
whatever it already has; the product does not interpret the value, only carries it so the binding is
durable and inspectable rather than living only in someone's memory of "how this run's questions get
answered."

This channel is deliberately not a general-purpose message queue (see Non-goals) — it is exactly the
single load-bearing question/answer/terminal-state seam `design-experiment`'s dispatch contract already
promises, made durable enough to survive a lost local process handle.

## 4. Cheap healthy waiting — capability-detected, honestly classified

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
silently re-issue a fresh wait and hope — surface it (see §5) rather than re-creating the exact silent gap
this document exists to close.

## 5. Recovery does not depend on one in-memory exec handle

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

## 6. Bounded designer supervision — wedge detection without recaching the world

The two-layer split `design-experiment` Step 4 already defines is substrate-neutral: the executor's own
tick (§4) owns ordinary idle/progress detection; the designer owns only **session-wedge** detection — the
executor's session stuck mid-turn, alive but making no progress, the one failure the executor's own tick
cannot self-diagnose because its own wake queues behind the stuck turn. For a Codex designer specifically,
absent a periodic-reinvocation primitive, run this at a **45-60 min cadence** as an ad hoc/manual check (or
a delegated small watcher session, per Step 4 item 3) reading only the executor's pane/log tail and the
run-supervision record's `status` — never the full design conversation on every tick, which is exactly the
$150-250/run-day regression a prior full-history `/loop` watchdog caused. Do not block dispatch on this gap
being fully automated away — note it, fall back to the manual cadence, and keep supervising; a Codex host
gaining a real scheduled-wake primitive later is a §4 capability upgrade, not a blocker to shipping this
contract today.

## 7. The coordination surface is capability-detected, and the executor is announced (automated-researcher#637)

§4 capability-detects the *wake*; this section capability-detects the *dispatch and coordination surface*, and
requires the designer to hand the researcher a way to actually see the executor it just created. The gap this
closes was observed 2026-07-25: a Codex-native dispatch created a real child task with the correct parent
relationship — inspectable in Codex Desktop under **Subagents**, chattable, the executor's full context
preserved — but the parent never said so, so the researcher believed the executor was hidden and spent
attention asking why visible top-level thread tools were unavailable. The experiment itself completed
correctly; the defect was the missing visibility handoff between dispatch machinery and researcher-facing
conversation.

**Detect the surface; never assume the top-level thread wrappers exist.** Some Codex sessions expose visible
top-level thread tools (`create_thread` / `wait_threads` and relatives); others expose only the native
multi-agent primitives — a `spawn_agent`-shaped call that returns a child task with a nickname — with no
top-level wrappers at all. Probe what the session in front of you actually has *before* dispatch, and use
whichever surface is present. **A missing `create_thread` wrapper is not a blocked dispatch:** the native
child-subagent path satisfies §1's fresh-executor contract as long as the child starts **zero-context**
(pointed at `DESIGN.md` / `START.md` / `CHECKLIST.md`, never handed this design conversation's history —
inheriting the designer's context is the one thing that would defeat the point of dispatching at all).
Falling back to a non-Codex or non-fresh executor is warranted only when *neither* surface exists, not when
one of two working surfaces happens to be absent.

**An app-visible child subagent is a first-class executor surface, not a degraded one.** Supervision and
integration stay with the parent: §2's bootstrap receipt, §4's tick, §6's wedge check, and the closeout are
unchanged and still the designer's job. What the child adds is a second, *human* window onto the same run —
the researcher may open it and read or chat with it directly. That window is for inspection, not for control
flow: anything load-bearing the executor needs answered still travels through §3's durable question/answer
inbox, so it survives session churn and lands somewhere the record can prove.

**Announce the executor in the same turn you dispatch it** — before falling into any wait, in the
researcher-facing conversation and not only on the record: the handle/nickname the dispatch returned, plus
where to inspect it. Worked example: "Executor **Erdos** is running; open **Subagents** to inspect or chat
with it." Bind that same handle as the record's opaque `--session-handle` at `start` (§1, §5) so it stays
durable and re-probable instead of living only in one conversation turn. A dispatch whose handle exists but was
never announced is exactly the defect this section names, even when the run underneath it is perfectly healthy.

**Keep a completed executor available through human review.** When the executor reports DONE, do not close or
discard the child as a tidy-up step: its preserved context is part of the review surface until the closeout
(and any cross-family audit) has actually been accepted. Reap it with the rest of the run, not the moment it
finishes.

**UI caveat, not product behavior:** in Codex Desktop as observed 2026-07-25, a newly completed child did not
appear under **Subagents** until the researcher clicked away and back to force the list to refresh. Say so when
it applies — but treat it as a host-UI quirk to be fixed there, never as the expected product shape and never
as something the contract above is allowed to depend on.

## What is INSTANCE, not product (do not put it here)

Per the same boundary `RELAUNCH_SUPERVISOR.md` draws:

- The concrete Codex host API (if any) for arming a scheduled wake, and the exact capability-detection
  probe that decides `autonomous-detached` vs `controller-supervised` for a given Codex host/version.
- The concrete §7 coordination-surface probe: which tool names a given Codex host/version actually exposes
  (top-level `create_thread`/`wait_threads` wrappers vs. only a native `spawn_agent`-style child task), and
  the app surface a child is inspectable under (Codex Desktop's **Subagents** list is one host's answer, and
  its refresh quirk one host's bug — neither is the product's contract; the product requires only that
  whatever the surface turns out to be, it gets detected and then announced).
- The concrete blocking-wait mechanics (`exec_command`/`write_stdin` parameters, a detached-shell-plus-poll
  script, tmux/pane layout) used for the controller-supervised tick.
- Where `question_route`/`terminal_state_route` actually deliver to when they are not `record` (a chat
  channel id, a paging integration).
- The 45-60 min designer-heartbeat cadence's concrete scheduling (a cron entry, a manual habit, a
  delegated watcher session's own wake) for a Codex designer.
- The concrete `--timeout-sec`/`--poll-interval-sec` values a designer uses for `verify-bootstrap`, and the
  concrete meaning of the opaque `--look-again` receipt value (an epoch timestamp, a monotonic counter —
  whatever the executor's host can actually produce and re-check).

## Non-goals (unchanged from the issue)

This contract is not a general-purpose job queue, does not touch or replace Claude's existing same-family
executor path, does not let a controller-held watcher satisfy the autonomous-detached contract merely
because it is well-behaved, and does not hard-code any instance's tmux layout, filesystem paths, model
choice, or Codex host API into the product. A Codex-authored/run experiment still uses **Claude** for the
independent cross-family scientific audit (`verify-claims`) — that boundary is untouched by any of the
above.
