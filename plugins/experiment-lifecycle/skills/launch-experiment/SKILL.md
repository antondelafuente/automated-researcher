---
name: launch-experiment
description: >-
  Launch a MERGED design-stage record: the design→execute seam as a first-class step. Fail closed unless the
  record is merged on the base branch with its Presentation section locked (a lock is NEVER settable from
  here); create the run worktree/branch; write designer-of-record = THIS launching session into the record;
  resolve the executor launcher + model pin from INSTANCE WIRING (never a bare interactive session launcher,
  never a script name hardcoded in skill prose); send the kickoff and mechanically verify it SUBMITTED;
  verify-bootstrap the run-supervision record; arm both supervision layers (pane monitor + long-cadence
  heartbeat) with their ids recorded; then hold the designer-of-record duties until close. Use when a
  design-stage PR has merged and someone says "launch it" / "/launch-experiment registry/<exp>", whether the
  design was written in this session or handed off from another (including a cross-family handoff). The
  middle skill: `design-experiment` produces the locked brief, this one starts the executor, `run-experiment`
  is what the executor then runs.
---

# Launching an experiment (the design→execute seam)

`design-experiment` produces a locked brief and lands it as a merged design-stage record. `run-experiment` is
what the fresh-context executor runs. **This skill is the step between them** — and it is a separate skill
because **the designing session is not always the launching session**.

That assumption used to be baked into `design-experiment`'s dispatch step, and it broke in production
(2026-08-31, RGBH1): one family designed the experiment, a session in the *other* family launched and
babysat it (it held the supervision machinery). Everything at the seam was undocumented or a footnote, and
all four failure modes fired in one launch — the executor came up on the interactive default model instead
of the pinned executor model (burning most of a subscription cap), the designer-of-record re-bind was a
hand-edit of the other family's record, the **Presentation lock got flipped from the launch side** on the
strength of "launch it", and the design-side instructions told a substrate with no supervision machinery to
dispatch itself.

So the split is: **design owns the science and the lock; launch owns the executor, the address, and the
supervision.** Which session launches is a *routing* question `design-experiment`'s last step asks out loud.

> **Companion skills this one composes** (declare these as dependencies of your install):
> - **`design-experiment`** — produces the merged design-stage record this skill's whole input is.
> - **`run-experiment`** — the execute half the launched executor loads; it also owns the scripts this skill
>   calls (`run_supervision_record.sh`, the worktree helpers) and `references/CODEX_SUPERVISION.md`.
>   **Invoke the companion skill; let it resolve its own scripts** — never hardcode a path into another
>   plugin's (or another skill's) `scripts/` dir.

## Rules this skill pins

- **Launch never edits the design's science or its Presentation section.** A missing Presentation lock at
  launch is a **design defect**, not something to fix from here: point back at `design-experiment` and stop.
  The lock records the researcher's explicit in-chat word on what gets plotted; a launcher inferring it from
  "launch it" fabricates that word.
- **Designer-of-record moves exactly once, at launch, and is written to the record by the launcher** — the
  launching session's own harness session name, resolved by lookup, written mechanically (below), never
  hand-edited into someone else's record.
- **The executor launcher and the executor model pin are instance wiring, resolved here.** A skill never
  hardcodes a launcher script name, and a session never starts an executor with the bare interactive
  launcher — that is how an executor ends up on whatever interactive default the box happens to carry.
- **Experiment mechanics never depend on a `TEMP.md` handoff or on a session's memory** (researcher rule,
  2026-08-31: *"handoff is never needed for experiments"*). The merged record is the whole input to this
  skill: if something you need is only in the designing session's head or scratch file, that is a brief gap
  to fix in the record, not context to carry across the seam.

## Step 0 — Preconditions (FAIL CLOSED, before anything else)

Your input is a **merged design-stage record on the base branch** — nothing else, no matter what the person
launching says. Run the deterministic check:

```
scripts/launch_record.sh preflight <path to registry/<exp>> --base-ref origin/<base_branch>
```

`<base_branch>` is the instance's `[github].base_branch` (`design-experiment`'s `references/SCHEMA.md`
describes the profile; the merged record's `START.md` snapshot names the resolved value). The check refuses,
with a `BLOCKED:` line and no side effects, when:

- `DESIGN.md` / `START.md` / `CHECKLIST.md` are not all present **at that ref** — the design-stage PR has not
  merged, so there is nothing pre-registered to launch. Go finish `design-experiment`'s design-stage logging.
- the working copy of any of them differs from the merged ref — you would be launching something the
  cross-family design gate never saw. (The one exception is `START.md`'s designer-address lines, which are
  Step 2's own output, so this check stays re-runnable after a bind — on a relaunch, or just to re-read the
  state.)
- `DESIGN.md`'s Presentation header carries no researcher lock
  (`## Presentation (locked with the researcher <ISO date>)`). **Never add it here** — see the rule above.

A refusal is a routing outcome, not a blocker to work around: say which one fired, point at the design side,
and stop.

## Step 1 — Create the run worktree/branch

Per the instance's convention (`[github].branch_prefix` → `run/<exp>`, forked from the base branch). Use
`run-experiment`'s **`sparse_worktree.sh`** so the checkout carries this experiment's record rather than the
whole registry (#805) — `--full` only for the rare task that genuinely needs every record.

The executor works in that worktree and binds it to its own run-supervision record (`--worktree`, set by the
executor from inside the worktree, at `start`) — you do not bind it for it; you only make it exist and point
the launcher at it.

## Step 2 — Write designer-of-record = THIS launching session

**Resolve YOUR OWN harness session name; never assume one (automated-researcher#796).** The executor needs a
*stable address* for you, not a description of you. Look your own up through the harness's own self-identity
listing (Claude Code: the name `ListAgents` shows for this session — the same name `SendMessage <name>`
delivers into), exactly as the peer-coordination rule requires everywhere else: **never** a fleet-shaped guess
(`claude-1..4`) and never the tmux session name. A tmux name is not a session under a Remote Control host
(`claude rc … --spawn worktree`): it is a HOST fronting many spawned zero-context sessions. Real incident
(2026-08-30, `depv1-negemo-qwen-chat-carrier-emotion-1`): the brief named a tmux session as
designer-of-record, the executor's DESIGN-budget notify was keyed into that name, an RC-spawned sibling with
no run context received it, ruled as designer-of-record and consumed the question — the session actually
supervising the run found the inbox already cleared. Two designers-of-record by construction; same ruling
both times only by luck.

Then write it into the record's seed line — **a scripted edit, not a hand-edit and not a `sed` one-liner**
(the RGBH1 launcher hand-edited the designing family's `DESIGN.md`/`START.md` to move the role):

```
scripts/launch_record.sh bind-designer <path to registry/<exp>/START.md> <your harness session name>
```

It rewrites the single `**Designer-of-record:**` line (and any remaining `<designer_session>` placeholder),
fails closed if that line is missing or ambiguous, and is idempotent. Commit it path-scoped on the run
branch. **No addressable session on this substrate?** Bind the reserved literal `record-only` and own the
polling: with no push, `has-question` on your heartbeat cadence is the only thing that surfaces a question.
Never substitute a `send-keys`-to-a-tmux-name push for the address you don't have.

That line is the **seed only**. Once the executor binds it at `start`, **the record is the address of
record**: a later move of the role is published by `run_supervision_record.sh checkpoint <run-id>
--designer-session <new name>` alone. That one write is the WHOLE handoff — the executor is told to resolve
the address off the record (`designer-session <run-id>`) immediately before every notify, precisely so a
rebind takes effect without reissuing the brief, which is also why the stale `START.md` line is harmless, and
why **re-binding is not optional**: a successor that leaves the old name bound is addressable only at the
session that just left the run.

Then **verify it landed on the record rather than trusting the brief** — `--designer-session` is a required
argument of Step 6's `verify-bootstrap`, matched EXACTLY against what the executor bound.

## Step 3 — Resolve the launcher + the executor model pin from INSTANCE WIRING

Two seams, both instance-owned, both resolved here and **never** guessed:

| seam | holds | absent ⇒ |
|---|---|---|
| `AAR_EXECUTOR_LAUNCH_CMD` | the command that starts a **fresh zero-context executor session** in a given working dir, applying the pin below | `BLOCKED: no executor launcher configured` |
| `AAR_EXECUTOR_MODEL` | the **executor-policy model id** that command must pin | `BLOCKED: no executor model pin configured` |

Both unset is a fail-closed stop, not a licence to improvise: **a bare interactive session launcher is not a
substitute.** Real incident (RGBH1, 2026-08-31): a fresh context launched the executor with the box's plain
interactive launcher, so no pin file applied, and the executor ran the whole experiment on the interactive
default model — a subscription-capped model at 97% of cap — instead of the executor-policy model. The
launcher script and the pin value are exactly the kind of fact that lives in instance wiring and rots in
skill prose, so this skill names only the seams.

**Where the executor is started by a harness-native primitive rather than a shell command** (the Codex
child-thread path of Step 4), `AAR_EXECUTOR_LAUNCH_CMD` may legitimately be unset — say so explicitly rather
than silently. The rule survives in the form the primitive exposes: the model/policy that primitive is handed
still comes from instance wiring (`AAR_EXECUTOR_MODEL` when the instance sets one), never from whatever
default the harness happens to carry, and you record which you used. What is never acceptable is an executor
running on an unpinned interactive default because nobody looked.

**The pin is a CHECKED state, not a claim** — the same bar `run-experiment` and the supervision layers hold
everywhere else. After launch, read the model the executor actually came up on wherever the substrate exposes
it (Claude Code: the session's own model line in the pane) and record it with your dispatch notes next to the
launcher you used. A mismatch is a relaunch, not a note-to-self.

**Do not plan on switching the model from inside the executor session.** On some substrates an in-session
model switch rewrites the harness's *global* default for every later session on the box (observed in the same
incident) — a launch-time pin has no such blast radius. If you ever do have to switch mid-run as a
remediation, restore the global default afterward and record both.

## Step 4 — The dispatch contract (substrate-neutral)

> **`dispatch(DESIGN.md, START.md, CHECKLIST.md) → a fresh-context executor that reads ONLY the brief +
> scaffold, runs the `run-experiment` skill, and reports artifacts/results.`**

The executor MUST start with **fresh context** (no memory of the design conversation) — that property is the
whole point: it tests the brief's self-sufficiency on every real run, and it separates designer-bias from
execution. *How* you spawn it is the instance's implementation of the contract:

- **Autonomous detached run requirement:** the executor substrate must be able to arm its **own independent
  recurring self-wake** and record the waker/backstop id in `CHECKLIST.md`. A controller-held wake, or a
  monitor used after the executor parks, does not satisfy the autonomous detached-run contract. A blocking
  watcher that keeps the executor turn alive is controller-supervised, not autonomous detached; pair it with
  the idle-cost teardown backstop if compute bills.
- **Claude Code:** a fresh zero-context session in its own dedicated working dir, started through the
  instance launcher seam of Step 3 (never the interactive launcher). A tool-spawned Agent subagent is fine
  for short controller-supervised probes, but not as the autonomous detached executor: it cannot arm the
  independent recurring wake this contract requires.
- **Codex:** a fresh, zero-context Codex thread by default — same-family as the *executor policy*, never a
  silent fallback to a different family (an explicit operator override is fine; a quiet substitution is not).
  Record `--executor-family codex` and the capability-detected `--supervision-mode` (`autonomous-detached` if
  the host actually exposes an independent scheduled wake, else the honest `controller-supervised`) on the
  run-supervision record at dispatch. A blocking watcher is the controller-supervised implementation today
  (Codex has no periodic-reinvocation primitive yet): it keeps the executor turn alive and, with an
  idle-teardown backstop for billable compute, satisfies this dispatch contract without claiming
  autonomous-detached status — but it must re-verify its own held handle on every wake, not just trust a long
  wait blindly (the stale-`exec_command`-handle incident this closes). **Capability-detect the coordination
  surface — do not assume the visible top-level thread wrappers exist** (automated-researcher#637): a session
  may expose `create_thread`/`wait_threads`, or only the native multi-agent primitives (a `spawn_agent`-shaped
  child task with a nickname). Either satisfies this contract as long as the child starts zero-context on the
  brief; a missing wrapper is **not** a blocked launch and never a reason to fall back to a different family
  or to run the design here. **Announce the executor the moment the dispatch call returns a handle** — before
  verifying anything, before any wait: the handle/nickname it returned and where to inspect it ("Executor
  **Erdos** is running; open **Subagents** to inspect or chat with it"), bound as the record's
  `--session-handle` so it outlives the turn. An app-visible child is a first-class executor surface the
  researcher may read or chat with directly, while supervision and integration stay yours; keep it around
  through human review rather than closing it at DONE. See **`run-experiment`'s
  `references/CODEX_SUPERVISION.md`** for the full contract: same-family default, the supervision-bootstrap
  receipt (§2), the durable question/answer inbox, the hardened wait pattern, and the
  coordination-surface/visibility contract (§7).
- **Other substrates:** a CI job, a remote worker, or a hosted queue that reads the brief.

**A substrate that cannot supervise should not be the launcher.** If you are running on a substrate with no
supervision machinery (no scheduling primitive, no pane/monitor equivalent), the honest move is to hand the
launch to one that has it — `design-experiment`'s last step already defaults that way — not to dispatch
yourself and hope. Launching anyway is a deliberate choice you record as `controller-supervised` with its
manual cadence, never a silent one.

**The kickoff:** point the executor at `START.md` with the run-to-completion + arm-self-wake-first directive.
Do NOT ask it to "report your first status lines and stop" — that invites a park after planning (a real
failure mode). The executor's first action is to arm its own heartbeat/self-wake; then run to completion.

## Step 5 — A send is not a submit: mechanically verify the kickoff SUBMITTED (automated-researcher#659)

Launch is complete when the executor is *consuming tokens*, not when the send call returned. Real incident
(2026-08-02, `depv1-negemo-dose-response-1`): a tmux `send-keys <prompt> Enter` kickoff raced the fresh
executor session's own startup prompts, the Enter was consumed by one of them, the kickoff sat **unsent in
the input box**, and the executor idled at 0 tokens for ~15 minutes — caught by the researcher, not by
machinery. So after sending, capture the pane (e.g. `tmux capture-pane -t run-<exp> -p`) and **classify what
is on screen before you touch the keyboard again** — the remedy depends on the state, and firing the wrong
keystroke at the wrong state is how this incident happened in the first place:

1. **A startup / permission / choice prompt is up** (trust-this-folder, a model or theme picker, a tool
   permission ask — anything with a highlighted default). **Answer it deliberately**: read what it asks and
   send the answer this launch actually requires. Do NOT fire a blind Enter at it — Enter here *selects
   whatever default is highlighted* rather than submitting anything, which is precisely the keystroke-eating
   modal that swallowed the original kickoff (and, on a model picker, precisely how an executor ends up off
   its pin). Then re-capture and classify again.
2. **No modal, but the kickoff is still pending in the composer** — the multi-line kickoff still sitting
   above the input separator. **Send a bare Enter.** It is the right remedy *in this state specifically*: the
   composer has focus with nothing modal in front of it, so Enter submits what is already typed and nothing
   else, and a text nudge would instead append to the pending prompt and submit a corrupted kickoff. Then
   re-capture and classify again.
3. **No modal and the composer is clear** — the kickoff went in. Now confirm the executor is actually
   *working*: the **token counter is climbing**, greater than 0 AND increasing across two reads a few seconds
   apart. A static non-zero count is not a pass. This cold-start test is valid *here* because a just-launched
   executor sits at 0 until the kickoff turn begins (see the heartbeat's first tick in Step 7, where it is
   NOT valid and a different signature is used instead).

Reading the composer takes care: the `❯` line normally carries ghost/auto-suggest text, so "there's text on
the prompt line" cannot distinguish a genuinely pending unsent prompt from ghost text. The discriminators are
the multi-line prompt sitting above the separator and the token counter, not the `❯` line's contents.

Only once you have reached state 3 *and* the counter is climbing do you report "executor running". Two pane
captures is the whole cost in the common case.

This is written concretely for the tmux/Claude-launcher path, where the race lives. The contract behind it is
substrate-neutral — some mechanical proof the brief was actually accepted and the executor is doing work —
and the Codex path carries its own form of it in the `verify-bootstrap` receipt below.

## Step 6 — `verify-bootstrap` the run record (automated-researcher#628)

A successful dispatch call alone does NOT make launch complete: it proves a session exists, and nothing
about whether the executor wrote its own supervision record, bound the right worktree/routes/mode, or armed
its own watcher. Before falling into the healthy zero-turn wait loop, run

```
run_supervision_record.sh verify-bootstrap <run-id> --executor-family <claude|codex>
  --supervision-mode <expected mode> --worktree <expected path> --question-route <expected route>
  --terminal-route <expected route> --designer-session <your harness session name, or record-only>
```

and treat a non-zero exit (missing record, a mismatched field, or a timeout) as `needs-attention`, not a
normal wait — reported against the executor you already named. `--designer-session` is matched EXACTLY
against what the executor bound from Step 2's seed line, which is what makes the handoff *verified* rather
than asserted. That poll is bounded but can run to its full default 300s or fail, so it must never be what
the executor announcement waits on.

## Step 7 — Arm BOTH supervision layers (#292, #342, #658)

Supervision divides by failure mode, and the launcher's share is deliberately small. (The prior contract —
one `/loop 20m` watchdog per executor, in the designing session — ran every tick with the full design
history: guaranteed cache-cold past the 5-min prompt-cache TTL, ~$150–250/run-day of avoidable spend measured
2026-07-05.)

- **The executor's own independent self-wake owns IDLE detection** — benign waiting, dead in-session
  monitors, no-progress-while-billing escalation, and GPU-utilization judgment (`run-experiment`: "Arm your
  self-wake" + the #323 utilization-series discipline). This is why `CHECKLIST.md`'s self-wake gate makes
  autonomous detached runs name an *independent* waker — parking on an in-process monitor is FAIL; a
  substrate that can't arm one runs controller-supervised instead. None of it is your job — no pod SSH, no
  GPU sampling, no checklist-step progress accounting from this session.
- **Your side owns only SESSION-WEDGE**: the executor's session API-stuck mid-turn (usually a rate limit) —
  process alive, no crash, so a crash supervisor never fires; the one failure the executor's own wake cannot
  cure, because its wake queues behind the stuck turn (#292).

For the session-wedge duty, arm at launch, in this order:

1. **An event-driven shell monitor per executor pane — zero model turns while healthy.** A detached shell
   watcher polling the pane text (e.g. `tmux capture-pane -t run-<exp> -p | tail -5`) for the terminal
   transitions — the executor's DONE/BLOCKED line, or the pane gone — delivering one notification turn to
   whoever holds the heartbeat duty when it fires; **record its id**; stop it when the run is reaped. (Claude
   Code: the harness `Monitor` primitive — visible, cancellable harness machinery, not an ad-hoc background
   sleep-loop the harness can kill without anyone noticing. Any substrate with a background shell can run the
   equivalent loop.)
2. **ONE long-cadence heartbeat (45–60 min) for silent-wedge detection.** Read each executor's pane and judge
   advancing-vs-frozen against your previous read — the discrimination a model-free probe (#172) cannot make.
   **The FIRST tick asks one extra question of every supervised pane before any advancing-vs-frozen
   judgment: did the kickoff ever land at all?** (#659 — a race that slipped past Step 5 then costs one
   heartbeat interval instead of the researcher's attention.) Key it on the **never-started signature**,
   which is durable at this distance from kickoff: the token counter still at **0** — nothing has ever been
   consumed — together with the kickoff still pending in the composer or an unanswered startup/permission
   prompt still on screen. Remedy it the way Step 5 does: **answer a modal deliberately, bare Enter for a
   pending composer**, never the text nudge below (which would append to the still-pending prompt). Do
   **NOT** reuse Step 5's *climbing*-counter test here: 45–60 min in, a correctly running executor
   legitimately shows a static counter — mid-tool-call, waiting on a long job, sitting at a question, or
   simply finished — so demanding "increasing" would misread all of those as an unsent kickoff, poke healthy
   sessions, and short-circuit the wedge assessment this tick exists to make. No never-started signature →
   fall straight through to the advancing-vs-frozen judgment, which is what a static counter is actually
   diagnosed by. Put this instruction in the heartbeat prompt itself — including the dispatched-watchdog
   variant in 3 below, which has no memory of the kickoff.
   Frozen → send a cheap, idempotent nudge via `send-keys` (even `hello` resumes an API-errored session; low
   harm if it was actually working — a liveness poke, not driving it, see below). A load-bearing
   fork/question sitting unanswered in the pane, or any real problem → it lands on **you** as
   designer-of-record (a delegated watchdog escalates to you, not past you): answer it under the
   decide-record-report rule in Step 8, and surface it to the researcher with specifics only when one of that
   rule's two checks fails. **Supervising several executors → ONE merged heartbeat over all their panes,
   never one loop per run.** (A **Codex** launcher still has no periodic-reinvocation primitive today, so run
   this heartbeat as an ad hoc / manual check at the same 45-60 min cadence — read the executor's pane/log
   tail and the run-supervision record's `status` only, never a full design conversation, and do NOT block
   launch on this being automated away. A real load-bearing question from the executor arrives through the
   durable question/answer inbox on the run-supervision record — `has-question`/`answer-question` — not only
   through pane text, so this cadence check should also poll that. See `references/CODEX_SUPERVISION.md` in
   `run-experiment` for the full contract, #223.)

   > **Claude Code implementation — invoke the loop skill; never a `ScheduleWakeup` chain
   > (automated-researcher#658).** Arm this layer by explicitly invoking the loop skill (`/loop 45m
   > <heartbeat prompt>`), which registers a **standing cron** (`CronCreate`): it fires until deleted or
   > expired, with no per-tick re-arm step to lose. **Record the returned cron job id** with your launch
   > notes, and delete the job when the run is reaped. Do **NOT** implement this duty as a `ScheduleWakeup`
   > dynamic wakeup: those are self-re-arming chains where each firing must schedule the next, so one broken
   > link — an interrupted turn, a user message consuming the turn before the re-arm — ends supervision
   > **silently**. That is a measured incident, not a hypothetical (2026-08-02, the
   > `depv1-negemo-dose-response-1` dispatch): the pending wakeup vanished during interactive churn, no
   > heartbeat was live for ~40 minutes, and only the researcher noticing surfaced it. Nobody watches the
   > watcher (exactly one supervision level — see 3 below), so this failure mode has no backstop. Other
   > substrates with a scheduling primitive: same rule — a standing schedule, never a self-re-arming chain.

3. **Your context known-large → dispatch the heartbeat to a separate small session (optional).** The
   heartbeat needs ~2k tokens (pane text + the rubric above) but a loop in a long-lived session executes with
   that whole history, re-cached cold on every tick. The dispatched watchdog is spawned at kickoff with the
   list of panes to watch, owns only this layer's duty (monitor triggers route to it; it runs the merged
   heartbeat and escalates real problems), and terminates when every supervised run reports DONE or is
   reaped. It is your *delegated* watch, not a new level: nobody watches the watchdog — exactly **one**
   supervision level, as always (the launcher watches the executor; nobody watches the launcher; two nested
   failures is out of scope).

**"Supervision armed" is a checkable state, not a claim (automated-researcher#658).** On a substrate with a
scheduling primitive, launch is not complete until BOTH layers demonstrably exist and both ids are recorded
with the launch notes: the per-pane monitor (1) and the heartbeat cron (2). Verify against the substrate's
own listing rather than your memory of having armed them — Claude Code: `CronList` for the heartbeat job id,
`TaskList` for the monitor — so a retro can check supervision mechanically instead of trusting prose. Either
one missing = go arm it before calling launch done. If you delegated the heartbeat to a separate watchdog
session (3), that session owns the cron and reports its id back to you (a cron wakes only its creating
session, so it is that session's `CronList` the id lives in) — what you record is unchanged. A substrate with
no scheduling primitive (Codex today) has no cron id to record: say so explicitly at launch and fall back to
its documented manual cadence above, rather than reporting supervision armed on the strength of the monitor
alone.

## Step 8 — You are now designer-of-record (until the run closes)

**You stay available for design-intent questions** (the executor routes them back to you — through the
durable question/answer inbox on the run-supervision record where the instance uses one,
`has-question`/`answer-question`, with its push notify addressed to whatever `designer_session` the record
holds when it asks — so if the role moves again mid-run, re-bind that field or the notify chases your
predecessor; a `record-only` binding means **no** push exists, so your own `has-question` poll is the only
thing that surfaces a question), but you **do not drive it** mid-run (that defeats the self-sufficiency
test) — you review at the synthesis pass. The heartbeat nudge above is bounded health supervision, not
driving: it pokes an idle session back to life, it does not answer design questions or steer the method — a
real question still routes back to you as a load-bearing flag, same as always.

**You are where the executor's questions TERMINATE, not a relay to the researcher — on an unattended run the
default is DECIDE-RECORD-REPORT (automated-researcher#664).** When a question reaches you, apply two checks:

1. **Does it stay inside the already-cleared budget / cost envelope?**
2. **Does it leave unchanged what is being measured** — the question, the arms, the metric; what the numbers
   will mean? (A meaning-changing answer FAILS this check.)

**Both pass → you decide**, record the decision durably where the run's own record carries it (an amendment
note on the experiment's registry record — the run-supervision record's question/answer inbox is cleared by
`consume-question` by design, so an answer that lived only there is not a record, and neither is a decision
that exists only in a chat turn), and report it to the researcher **after the fact**. **Either check fails →
forward to the researcher.** Researcher-owned and untouched by this: design clearance, the Presentation lock,
raising any cost ceiling, and anything that alters the experiment's meaning — those are legitimate asks, and
this default is not a reason to suppress them. What it eliminates is the *decidable* question: a bounded,
invariant-preserving call you already have the judgment to make, sent up for approval anyway (2026-08-02/03,
observed in both families — the same session, once told "make decisions as long as nothing changes
drastically," immediately made the correct bounded call; it had the judgment, it lacked the license). Note
what is deliberately **not** a condition here: "is it reversible or
gate-protected?" Nearly everything in this pipeline is redoable at small dollar cost, so a reversibility
clause just gets over-applied in the cautious direction — which is the failure mode this default exists to
fix. The executor's own disposition is unchanged by all of this: mechanical/reversible gap → sensible
default, record, keep going; bigger gap → route up and work around it. The executor flags; it does not rule.

**A verifiable fact is never forwarded — and that binds you too.** A question whose answer is checkable from
the records or the live state ("is X the baseline?", "does Y exist?") gets verified directly by whoever is
holding it, not relayed to anyone.

**A design-intent question you cannot answer** — one that needs what only the *designing* session knew — is
a brief gap: resolve it from the merged record if it is there, and otherwise route it to the researcher and
record the gap in `CHECKLIST.md`'s GAPS section, which is what grades the design stage. Do not reach back
into a design session's memory; by contract the record is the whole handoff.

**Context hygiene while supervising:** route bulk reads (RESULTS.md, screenshots, long logs) through
subagents/forks during supervision phases — context accumulated while babysitting is rent paid on every
future turn of this session, including every heartbeat tick.

## Step 9 — Own the reap at close

What you armed, you tear down. When the run reaches its terminal state (the executor's DONE/BLOCKED, or a
deliberate stop):

- **Stop the pane monitor** you recorded in Step 7 (1) and **delete the heartbeat cron** you recorded in
  Step 7 (2) — a cron nobody deleted keeps waking a session about a finished run, and a monitor nobody
  stopped is the "supervision armed" state lying in the other direction. Verify against the substrate's own
  listing, same bar as arming them.
- **The executor's own close finalizers stay the executor's** — the run-supervision record `close`/`stop`,
  `reap_worktree.sh` on the run worktree, the pod-lease teardown: all are `CHECKLIST.md` gates it resolves
  with evidence. Your reap is the supervision machinery, plus any launch-side scratch of your own.
- If the executor died without closing its record, that is the relaunch supervisor's path
  (`run-experiment`'s `references/RELAUNCH_SUPERVISOR.md`), not a licence to close another session's record
  from here.

## Reference

- **Scripts** ship with this skill under `scripts/`: `launch_record.sh` (`preflight` + `bind-designer`), with
  `launch_record_smoke.sh` as its behavior test.
- **The brief this skill launches:** `design-experiment` (`DESIGN.md` + `START.md` + `CHECKLIST.md`, merged
  as a design-stage record).
- **What the executor then runs:** `run-experiment` — also the home of `run_supervision_record.sh`,
  `sparse_worktree.sh` / `reap_worktree.sh`, `references/CODEX_SUPERVISION.md`, and
  `references/RELAUNCH_SUPERVISOR.md`.
