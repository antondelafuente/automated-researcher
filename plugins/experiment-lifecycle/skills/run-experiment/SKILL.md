---
name: run-experiment
description: >-
  EXECUTE a pre-designed GPU experiment from its locked brief, on disposable
  compute, as a zero-context autonomous executor. Read the locked DESIGN.md +
  START.md + CHECKLIST.md, arm your self-wake, then run the loop to completion:
  acquire compute (via the gpu-job backend), PROVISION it (per your execution
  profile), drive it (a self-contained detached driver), collect results to your
  artifact store, and CLOSE (RESULTS.md describes the data per the DESIGN spec, cross-family
  audit via verify-claims, teardown, ledger). Use when handed a brief to run
  ("execute the wave per START.md", "run this arm", "kick off the eval"). The
  DESIGN half is the `design-experiment` skill; this is the EXECUTE half — it does
  not design, it runs a locked brief.
---

# Executing an experiment on disposable compute

> **The three seams this skill reads** (so the protocol stays substrate-neutral and the instance stays swappable):
> - **`gpu-job`** (companion plugin) — acquire / deploy / drive-helpers / teardown mechanics. Invoke it; do
>   not reimplement deploys.
> - **`verify-claims`** (companion plugin) — the close audit (`audit_experiment`) and the standing data audit
>   (`audit_data.py` + `--data`). Invoke the skill; don't hardcode its script paths.
> - **the execution profile** — your instance's provisioning, frozen recipes, artifact store, ledger, teardown-key
>   policy, and cost/API policy. The brief (`START.md`) snapshots or links the relevant profile section with a commit/
>   hash, so the method is reproducible from the record. Where this skill says "per your execution profile," that's the
>   instance seam — nothing instance-specific is hardcoded here.

## You are an autonomous executor (read this first — it sets your whole disposition)

You are running a **locked, pre-designed** experiment from its brief. Your disposition is NOT the default helpful
assistant (which stops to check in at natural boundaries) — it is an **autonomous executor**:

- **Run to completion.** Do **not** end your turn until you hit a real blocker or you're done. **Stopping after planning
  is the failure mode** (real incident: a fresh executor planned, said "proceeding," then parked silently for hours).
  Plan briefly, then *execute* — don't narrate the next step and stop.
- **Gaps — two kinds, and only one ever involves a human:**
  - **Mechanical / reversible gap** (a path to pick, a parameter the design didn't pin, a disk size): **pick a sensible
    default, record what you chose, and keep going.** No flag, no wait.
  - **Load-bearing gap** (changes the *method, the cost, or what the result means*): **do not guess — and do not idle-
    wait.** Notify the designer-of-record and **keep working on everything the gap doesn't block.** Only if the gap
    blocks the *whole* run do you stop — and then **TEAR DOWN THE COMPUTE FIRST** (a blocked run bills the same as a
    completed one — see tear-down-on-block in the close), record the blocker, ping the human, and clear the now-pointless
    self-wake. **Never leave blocked compute billing while you wait for a decision.**
- **The design is locked — don't redesign.** Collect + report the data `DESIGN.md` specifies (the numbers / the plot);
  don't pre-register a verdict — interpretation is the researcher's separate step. If you think the design is wrong, that's
  a load-bearing flag to the designer-of-record, not a unilateral change.
- **Record your gaps.** The defaults you had to invent and the things you had to flag are **feedback that grades the
  design**: surface them in the close retro (too many = the design wasn't pinned enough → the design skill needs work).
- **Never dispatch `Agent(subagent_type: "fork")` from this executor-framed session for a narrow research question.**
  A fork inherits your FULL conversation context, including this very disposition — "run to completion, don't stop
  after planning, don't ask questions" — so it can silently take on the executor role itself instead of just
  answering what you asked, duplicating billable pipeline work and racing you on shared work-dir/registry paths
  (real incident: a fork dispatched to resolve a handful of file paths instead re-derived S1/S4 independently, wrote
  and launched its own S2-S8 driver, and ran a duplicate judge pass against the same output file the main thread was
  writing to — ~38 minutes of wasted spend before it was caught and stopped). Do narrow research **inline** (read the
  files yourself) or via a **read-only, non-fork subagent** (e.g. `Explore`) instead. If a fork is genuinely needed,
  its prompt MUST explicitly revoke the executor framing and forbid billable/pipeline work: *"you are NOT the
  executor; do not write pipeline files or launch any generation/training/judging — answer only: ..."*.

## Your brief is your world — read it

Your brief is **`DESIGN.md`** (the science + the data-collection spec) + **`START.md`** (the operational bridge: input
paths, scripts to adapt, cost ceiling, designer-of-record, and the execution-profile snapshot/link) + **`CHECKLIST.md`**
(the verification gates). Read all three first. If you need a fact that isn't in the brief, that's a brief gap — flag it
(load-bearing) or default-and-record (mechanical), don't confabulate.

**Work the `CHECKLIST` as you go — it's the forcing function, not optional.** Resolve every `[BLOCK]` gate to exactly
one end-state with EVIDENCE (an artifact path + numbers, never a bare ✓): **☑ PASS** / **☑ N.A. ev: <why>** / **☒ FAIL
ev: <what failed>**. A `[BLOCK]` gate is **un-passable without evidence** — a 2-sample smoke is NOT evidence for a
full-pool data gate. A **FAIL blocks continuation** and is a load-bearing flag (notify the human; proceed only if they
clear a changed method); **keep the FAIL recorded** — the FAIL→fix→PASS history is the validity trail. Fill the `GAPS`
section as you go. Commit `CHECKLIST.md` at close — the cross-family close audit verifies it against the artifacts.

**The single most common faceplant:** freshly-acquired compute has your *identity* only — it does **NOT** have the
training environment (venvs, the model repo). **Provisioning** (next, per your execution profile) is what installs them;
skip it and every command fails.

## Arm your self-wake / idle-cost backstop FIRST — before any detached run or billable background work (do not skip)

A detached run means **you end your turn and wait to be re-invoked.** The silent-failure class that bites an autonomous
executor is **never-re-invoked** — you sit parked, nothing errored, the compute bills, the research stalls. So **for
autonomous detached execution, the moment you start execution — before launching any compute or detached driver — arm an
independent, recurring self-wake** as your standing waker (any single in-process waker can die and leave you parked; the
independent waker is the mandatory backstop). If any background work leaves billable compute running, arm the idle-cost
teardown backstop before you detach. The autonomous self-wake must, each tick: check each job's **done-marker**, a
**liveness** signal (compute busy = alive; idle AND not-done = hung), AND a **positive-progress** signal (a stage
advancing / bytes growing — liveness alone can't tell working from a wedged hot-loop), plus the driver log for
BLOCKED/errors; and it must honor a **look-again deadline** — a deadline quietly gone past with compute still billing is
the signal you parked, so STOP re-waiting, diagnose, and notify the human.

**The same tick also owns the pod-lease heartbeat — refresh is not something to remember by hand.** The `gpu-job`
lease's `expiry` is the SOLE deletion trigger the standing reaper enforces (the per-pod watchdog is retired, #266/
#284), so a run that silently outlives its lease gets reaped out from under it — a real incident lost a ~15h run's
eval pod mid-stage this way, plus a recovered orphan pod whose lease never got past its short, un-enriched
acquire-window expiry. Fold the refresh into the SAME tick that already computed the liveness + progress signal
above, gated on **that same progress principle, not raw compute activity** — a wedged hot-loop is busy without
producing, and gating on "busy" alone would refresh it forever, defeating the expiry backstop (#428 review). For
every pod id in the run-supervision record's `lease_pod_ids` (`run_supervision_record.sh status <run-id>`),
first resolve the pod id to its lease nonce — leases are addressed by nonce, never by pod id directly —
the `gpu-job` plugin's `scripts/pod_lease.sh find-by-pod <pod-id>` — empty output is not safely-skippable, it
means no single matching non-terminal lease (none, or several — `find-by-pod` only prints a nonce for exactly
one match); enumerate via `scripts/pod_lease.sh list` to disambiguate before deciding, never guess a nonce —
then:
- **positive-progress evidence this tick** (the stage-advancing / bytes-growing / log-heartbeat signal above,
  actually observed — not merely busy) → the `gpu-job` plugin's `scripts/pod_lease.sh refresh <nonce>
  --expiry-min <N>`; if the lease is
  still `provisional` (never enriched — e.g. a recovered/adopted orphan) and you've confirmed SSH reachability,
  `enrich` it instead (`--ssh <host:port> --expiry-min <N>`) so it stops carrying its short intent-window
  deadline.
- **no progress this tick, but an active operator-declared long-quiet-phase marker** — a `QUIET_PHASE.md`
  (`reason` + a bounded `quiet_until` horizon, same shape as `LOOK_AGAIN.md` below) written only because the
  brief or a human explicitly told you to expect an extended silent stretch (e.g. a known long non-logging
  compile/index stage); never self-declare one just because a tick came up empty, that's the over-strict-gating
  failure re-created through the back door. While `quiet_until` is still in the future, refresh/enrich the
  lease the same way as the positive-progress case above, citing the marker in place of a progress
  observation. A marker whose `quiet_until` has passed counts as absent → falls through to the **neither**
  case below: do NOT refresh, surface loudly on the next wake.
- **neither** (busy-but-not-progressing, hung, BLOCKED, or simply quiet with no active marker) → do **NOT**
  refresh. Don't let this pass silently: treat it like a look-again-deadline miss — surface it loudly on the
  next wake (diagnose, notify the human) instead of quietly trusting the lease's existing expiry to eventually
  reap it unattended.

For an **autonomous detached run**, this is a capability requirement, not a best-effort preference. If your substrate
cannot arm an independent recurring wake, do **not** silently substitute an in-process monitor and then park. Mark the
`CHECKLIST.md` self-wake gate **FAIL**, notify/escalate before GPU/API spend, and either relaunch in a substrate that
can own its wake or keep the work explicitly controller-supervised. A blocking watcher that keeps the executor turn
alive is controller-supervised, not autonomous detached; if it leaves billable compute running in the background, still
arm the idle-cost teardown backstop.

> **Claude Code implementation:** a non-durable recurring `CronCreate` (~every 12 min) whose prompt re-checks the pods
> and honors a `LOOK_AGAIN.md` marker (`last_looked` / `look_again_by`, generous). Session-scoped (wakes only its
> creating session; auto-expires ~7 days — re-arm for longer runs). A tool-spawned Agent subagent cannot use this
> independent wake path, so it is not a valid autonomous detached executor. A `run_in_background` Bash/Monitor
> waiter is not a substitute for this either — see "Long-running process discipline" below. Other substrates: the
> equivalent recurring wake.

## The resume contract — be resumable by a model-free supervisor (do this as you go)

The self-wake above catches you going *idle*. A separate failure is the agent process **dying or wedging**
mid-run (a crash, an API blip long enough to kill the session, a usage-policy block that ends the thread). On an
instance that runs a model-free relaunch supervisor (the #54 crash-resilience design), that supervisor will try to
**relaunch you and resume the run** — but a blind relaunch only recovers *useful* work if you held up your end.
Three obligations, maintained continuously (not at close):

- **Checkpoint state to disk, not only to conversation.** Everything a successor needs to continue —
  what's launched, **pod ids**, what's been collected, the DESIGN data-collection spec — lives in the run's
  artifact dir / `START.md` / ledger. `--continue` replays the conversation, but a *fresh* successor only has the
  disk. Anything load-bearing that's only in your chat history is lost when the session is.
- **Keep an always-current successor handoff.** Maintain `TEMP.md` (your instance's handoff path) as a
  **standing**, refreshed-at-every-checkpoint pointer file — pod ids, artifact paths, the active look-again
  deadline, the next action. **Pointers only, never trigger-prone prose** (a block-prone run — misalignment-organism
  material — can leave your thread unable to write its own handoff later, so it must already be current). This is the
  input the supervisor feeds a fresh successor when same-session `--continue` is impossible (corrupted session,
  policy block).
- **Write a run-supervision record at run start, and keep it current.** This is the machine-readable
  desired-state the supervisor reads to decide whether a gone session should be relaunched at all — so it
  relaunches a genuine crash but **never resurrects a deliberate `/quit` or a finished run.** It is real state,
  written through one product helper (atomic, fail-closed), not prose:

  > **Claude Code / this instance:** the helper is `run_supervision_record.sh` in this skill's `scripts/`
  > (record root `${AAR_RUN_SUPERVISION_DIR:-~/.config/run-supervision}`). At run start, from **inside your own
  > worktree**: `start <run-id> --handoff <TEMP.md path> --session-handle <opaque> --worktree <this worktree's
  > path>` (marks the run **desired-active**, records the opaque, instance-owned handle that binds this run-id
  > to your session — a tmux name / systemd unit / pid-file path; the product never interprets it — and binds
  > this run-id to your own worktree path, the binding `reap_worktree.sh` checks at close so a clean-closed
  > run-id can only ever reap the worktree IT bound, never a peer's, `automated-researcher#535` review round 2).
  > At each checkpoint: `checkpoint <run-id> --handoff <path> --lease-pod <id>…`
  > (refresh the handoff + link the pod ids the run holds — these link to `gpu-job`'s pod leases by id). Use
  > `status <run-id>` as compact checklist evidence. If you hit a case you can't resume in place (a usage-policy
  > block, a corrupted session): `request-relaunch <run-id> [--handoff <path>] [--reason …]` — a positive
  > "recover me" signal the supervisor acts on (it is auto-cleared if you later `stop`/`close`). This needs a
  > **bound `handoff_path`** (the successor fallback points the fresh successor at it): if you bound one at
  > `start`/`checkpoint` it's already there, else pass `--handoff <path>` to bind it atomically —
  > `request-relaunch` fails closed if no handoff is bound. The supervisor branches on `is-desired-active` /
  > `is-relaunch-requested` / `session-handle`. The concrete relaunch commands + the supervisor wiring are
  > instance, not this helper. (`start`/`checkpoint` are the executor-facing aliases for the lower-level
  > `create`/`update` API used in supervisor references.)

  See **`references/RELAUNCH_SUPERVISOR.md`** for the supervisor's side of this contract — the substrate-neutral
  decision tree (`resume_same_session` else `launch_successor(handoff_path)`), the desired-state gating, and what
  is deliberately out of scope (silent-wedge detection, deferred to the #54 `needs-shaping` follow-up).

- **Never leave a pod behind an in-conversation-only note.** A pod's existence and its cost-cap deadline must be
  on disk — the keepalive contract + the standing handoff + the linked pod ids in the record — so a reaper can
  find it without you. (At close, clearing the record is a **post-audit finalizer**, not an early step — see
  Step 5.)

**A `StopFailure`-style notifier is a signal, NOT recovery.** An instance may also wire a hook that *fires* when
the agent process exits on an API error — to push-notify and/or wake the supervisor (and, where the relaunch
supervisor's *needs-relaunch* marker exists, drop it). Such a hook **cannot itself resume** the session: it runs
only *after* the process is already gone. Recovery stays the model-free supervisor's job
(`resume_same_session` else `launch_successor`); the hook is a **signal into** that path, never a substitute for
it — don't wire one expecting it to recover the run. (Raising the in-process API timeout so a *short* blip is
ridden out without ever killing the session, and the concrete hook command, are instance settings, not this
contract.)

## Topology: detached driver (default) vs on-compute agent (rare)

- **Detached shell driver — THE DEFAULT.** scp a self-contained `*.sh`, run it detached (`setsid nohup`), poll a
  done-marker. Deterministic, robust, no auth risk. Use your profile's worked-example drivers as the shape.
  Detach from the FIRST invocation, never only after a suspected failure — see "Long-running process discipline"
  below for why.
- **Delegate to an on-compute agent — RARE.** Brief a named agent on the compute and drive it, for a *messy sub-task*
  that genuinely needs on-box judgment. A second brain (it can lose auth; the controller can't) — use sparingly.
- You (the executor) are the **controller-resident brain driving ephemeral, dumb compute** — there is no agent on the
  GPU box for the default path.

## Long-running process discipline

Five failure modes recur wherever this skill has you launch, watch, or poll a process that outlives a single turn
— remote drivers, local pollers, and judge/API worker pools alike. Each is **silent** (no crash, no error, no
signal at the moment it happens) and each has a proven, cheap fix; treat all five as standing discipline, not a
situational judgment call.

- **A local-tool timeout is never evidence the remote process died — detach from the first invocation, and
  verify by PID before ever relaunching (#355).** A foreground (non-detached) SSH call that hits the local Bash
  tool's timeout returns "failed/killed" locally, but the remote process is independent of that local timeout
  and keeps running unless something on the remote side actually tore it down. A real incident: a foreground
  judge call timed out locally, was believed dead, got relaunched detached — and the two processes wrote to the
  same output file concurrently for several seconds before ~60 duplicate rows gave it away. The fix is upstream
  of the relaunch decision, not a smarter relaunch check: launch every remote/long-running script detached from
  the FIRST invocation (`setsid`/`nohup … & disown`, log + pidfile — see Topology, above), so "did this survive
  a timeout" is never ambiguous. If you ever do suspect a job might still be running, confirm via its PID
  (`pgrep -af <script>` read-only, as a check, never as a kill target) before relaunching — never relaunch on
  the assumption that a timed-out local call means a dead remote one.
- **Bracket a semaphore around the single attempt, never around a retry/backoff loop (#343).** A judge/API
  worker pool sharing one rate-limited account can silently stall — not crash, not error, just stop advancing —
  when a permit is held for a call's entire retry loop (`async with sem: for attempt in …: … await
  asyncio.sleep(backoff)`, with the sleep INSIDE the `with`): under a real rate-limit spike, most permits get
  stuck in backoff at once, and unjittered backoff synchronizes retries into a thundering herd that never
  drains. One real run went through three successive "looks-fixed" concurrency attempts before finding this —
  each looked correct, each still silently stalled. The fix: acquire the semaphore for the single HTTP attempt
  only, release it before the backoff sleep so a stuck retry doesn't block the workers behind it, and jitter the
  backoff (`base * (0.5 + random())`) so retries don't re-synchronize. If a work unit spans several dependent
  API calls (e.g. a multi-step judge sequence), hold the permit for that whole unit's forward progress, not for
  any single call's failure-recovery path.
- **A `run_in_background` Bash/Monitor waiter is a convenience layer, never the thing you rely on for
  re-invocation (#461).** These waiters are not guaranteed to survive across turns or context events — a real
  run saw ALL currently-running background waiters, including unrelated ones from long-finished earlier phases,
  killed in a single sweep with no explicit `TaskStop` and no visible trigger, twice in one session. The remote
  job itself was unaffected both times — only the local poller died — so treat a killed waiter as a signal to
  re-verify the remote job's liveness directly (SSH/PID), never as evidence the job itself failed. The
  independent recurring self-wake you armed above is the one channel proven to survive this; a
  `run_in_background` poller layered on top of it for faster-than-cron cadence is fine, but the self-wake tick's
  own direct poll is what you fall back to the moment a waiter goes quiet — never widen the self-wake interval
  or skip arming it because a background waiter is also running.
- **Poll liveness by PID (`kill -0` against a recorded pidfile), never `pgrep -f <name>`, in ANY polling
  context — an ssh one-liner, a Monitor `command:` loop, or a deploy poller alike (#462).** `pgrep -f`/
  `pkill -f` matches the full command line of every process, including the poller's OWN wrapper — an ssh
  one-liner or a Monitor `bash -c '...'` invocation whose text names the target script (as a poll condition's
  text almost always does) matches itself, so a negative liveness check never goes true even after the real
  target process has genuinely exited. A real incident: a Monitor completion loop reported "still running"
  indefinitely after its target had already finished, because the loop's own `pgrep -f judge_pass.py` matched
  its own `bash -c` wrapper. Capture the PID at launch (`… & echo $! > pidfile`) and poll `kill -0
  "$(cat pidfile)"` instead — this is `gpu-job`'s liveness-helper pattern; use it rather than re-deriving a
  pgrep-based check per driver.
- **Past ~120s, the harness auto-backgrounds a Bash call regardless of any `timeout N` you pass it — don't fight
  this, poll for the completion marker instead (#480).** "Run it in the foreground with a long Bash timeout" is
  not a real mechanism once a call legitimately runs past ~120s — and the close audit / `log-experiment` calls
  routinely do, at 400-500s+: the harness's own auto-background kicks in first, so the call is never actually
  "foreground" beyond that point no matter what timeout you gave it. Worse, wrapping the call in your OWN
  `timeout N` on top of this can kill it just short of finishing — a real incident lost a full audit attempt
  this way, its `timeout 500` wrapper firing at the 500s mark seconds before the audit would have completed.
  Let the harness auto-background the call, don't add your own timeout wrapper around it, and poll for the
  call's own output-file marker (e.g. `AUDIT.md`/`DATA_AUDIT.md`) the same way you'd poll any other detached
  driver's done-marker.

## Step 1 — Acquire the compute

**Claim the experiment BEFORE the first billable action (do not skip — it's the `[BLOCK]` claim gate).** If
your instance uses a shared experiment tree, its convention requires *claiming* the experiment before any GPU/
API spend: check no peer already owns the dir, then write the instance's claim marker (e.g. a `CLAIMED_BY`
file naming who/date/scope) and commit it path-scoped. A zero-context executor naturally works the listed gates
and misses this separate coordination convention, so a run's dir has been caught unclaimed *at close* — claim
first, then acquire.

Delegate to the **`gpu-job`** backend — don't reimplement deploys. Account/key selection, default GPU + disk, and the
tiered-region retry are the backend's job; the *recipe* choice (which GPU, how big) comes from your execution profile.
**After deploy, note WHICH account/key created the compute — all later management (list/teardown/verify) MUST use the
SAME key.** A tiny GPU is plenty for a smoke.

## Step 2 — Provision the environment (the missing link)

Acquired compute is NOT experiment-ready until it has the repos + environment. **Provision it per your execution
profile** (the profile names the bootstrap, the environments/venvs, the model repo, the base model, and where API keys
land). **Wait for the profile's readiness signal before any train/eval.** (If an artifact you need lives only in a
legacy store the profile flags for migration, capture it to your artifact store yourself — don't retrain it, don't ask
the human — and mention what you moved.)

## Step 3 — Drive it

**Default = the detached driver.** scp a self-contained, **idempotent** `*.sh` (skip cells whose output exists): resolve
base → serve/train → eval → parse → copy artifacts to your store → `touch …/.done`. **The "skip cells whose output
exists" check must be SUCCESS-aware, not presence-only (#357):** a done-check that treats ANY row written to the
output as permanently complete — regardless of whether the read actually succeeded — silently never retries a row
that hit a parse failure / null label (a real incident: 73/8884 direction-read rows sat silently wrong across an
entire experiment, caught only by comparing aggregate row counts at close). Before computing what's left `todo`,
strip any row lacking a valid success marker (a real label/score, not `null` / an `excluded_*`/error status) from the
"done" set, so a failed read gets requeued on the next pass instead of sitting silently wrong until someone notices
a downstream discrepancy. Run it detached (`setsid nohup`),
then watch it with the self-wake tick you already armed above; a `run_in_background` until-loop layered on top
for faster-than-cron cadence is fine but not load-bearing — see "Long-running process discipline" above.

**A judge driver's strict-tag parser needs a bare-text fallback, or it feeds the done-check above a false
API-failure signal (#542).** A parser that only matches the literal `<mode>X</mode><flavor>Y</flavor>` wrapper
and treats anything else as unparsed will retry a row forever (or drop it, under a lower retry cap) when the
judge model reliably reproduces a bare-text shorthand for the same kind of row instead of the tagged format — a
real incident: a 119,925-row Task-2 mini judge pass (`gpt-5.4-mini`, `reasoning_effort=low`) plateaued at 99.91%
parsed across 3 retry-to-convergence passes, with 58 rows stuck no matter how many times the same prompt was
re-sent; every one had already been classified correctly (`"answer"`, `"answer, na"`, `"deflect other"`, etc.),
just without the XML tags, so more retries never helped. To the SUCCESS-aware done-check above (#357), a
bare-text row is indistinguishable from a genuine API failure — both lack a valid tagged success marker — so the
two failure modes need to be handled together: when the strict tag match fails, fall back to a constrained
regex matched against the ENTIRE trimmed response — not a word search anywhere within it — requiring the whole
trimmed response to consist of a standalone `\b(answer|deflect|refuse)\b` mode word, optionally followed only
by a standalone flavor word (only if flavor tags are also absent), defaulting flavor to `na` when mode=answer.
A longer free-text response that merely contains one of these words (e.g. "I cannot answer; this should be
refused") must NOT match — an unanchored word search would misread that example as mode=answer, flavor=na,
exactly the invented/coerced value the fallback must never produce. This only ever extracts the classification
the judge already stated in a genuine bare-shorthand row — it never invents or coerces a value — and took one
run's 234 cells from as low as 93.9% up to 100%.

**A fanout wrapper's done-marker must key on the trainer's own success CONTENT, never on the trainer
process's exit code alone (#569).** A `bash -c "<trainer invocation> && touch done_marker"` wrapper — the
standard fanout-wrapper shape around a trainer script — relies on `&&` to decide whether an arm succeeded,
but a shutdown-time SDK/HTTP-client crash AFTER a fully successful save can still exit the trainer non-zero,
short-circuiting `&&` and leaving `done_marker` untouched — a false "not done" signal on a genuinely-completed,
genuinely-valid arm (a real incident: 2 of 24 arms printed a clean `=== DONE ===` banner with valid checkpoint
+ sampler-weight paths, then the wrapping `bash -c` reported `Aborted (core dumped)` from the trainer's own
SDK teardown, after both saves had already returned successfully). To the SUCCESS-aware done-check above
(#357), an exit-code-gated marker is doubly wrong here: trusting a missing marker as "not done" risks a
silent double-spend (re-running an arm that already completed) just as readily as trusting a stale-but-present
marker risks the opposite failure #357 already covers. Treat the wrapper's own exit code as untrustworthy:
grep the trainer's log for its success banner plus a parseable artifact path (e.g. `=== DONE ===` followed by
the checkpoint/sampler-weight paths it printed) as the done signal instead of `&&`-chaining a `touch`,
optionally confirming with a live sampler-attach check against the printed path as stronger validity
confirmation before trusting an arm complete. Where a trainer script controls its own exit path, also prefer
having it flush and `exit(0)` explicitly right after printing its success banner, before any SDK/client
teardown that could crash — closing off the false-non-zero-exit case at the source rather than only working
around it downstream.

**Multi-wave eval fan-out over many checkpoints needs an explicit canonical checklist, not reactive batching
(#337).** Batching eval waves reactively — queuing whichever checkpoints/arms/seeds are ready right now — has
no built-in signal that something was skipped: it only ever adds to what's present, never checks against what's
supposed to exist. When N known checkpoints/arms/seeds land in an unpredictable order across multiple compute
units/pods over multiple waves, maintain an explicit canonical list of every expected (arm, seed) — or (unit,
replicate) — combination up front, and before believing the eval is done, diff what's actually been judged
against that FULL expected set — not just confirm the last wave's queue is empty (a real incident: an
18-checkpoint (9 arms x 2 seeds) fan-out across 2 eval pods over several waves silently never queued 5
specific (arm, seed) pairs into ANY wave, caught only when a pooled per-arm number came up with one seed's
data missing). This generalizes the SUCCESS-aware done-check above from per-row/per-arm completeness to
across-the-whole-fan-out completeness.

**Same completeness discipline applies to a launch-time glob, not just the eval done-check above: count-check
the expansion against the expected arm count before launching.** A shell driver that launches one job per
matched file (`for f in "$SETS"/train_*.jsonl; do ...; done`) has the identical no-signal-on-skip failure mode
as reactive eval batching — a glob that silently matches fewer files than expected launches fewer jobs than
expected, with no error and no log line (a real incident: 9 of 10 expected arm files launched, the 10th simply
absent from the list, root cause undiagnosed but plausibly a basename/glob interaction with a suffixed sibling
file — e.g. `train_arm3.jsonl.pre_dedup_fix` — sitting in the same directory). Before trusting a glob-driven
launch loop, compare the matched-file count against the expected arm count, and watch for suffixed sibling
files sharing the same directory and base pattern as the files you mean to glob.

**Use the `gpu-job` helpers** — its driver library owns the foot-guns (GPU-stage handoffs that wait for the prior runner
and poll until VRAM frees; port/serve waits; artifact-exists checks; liveness; safe process-tree kills; LoRA merges
through a mandatory diff gate). Hand-rolling these is how validity bugs breed. (Never poll liveness with raw
`pkill -f`/`pgrep -f` in an ssh one-liner — see "Long-running process discipline" above for why and the PID-based
fix.) **One more kill rule, three incidents:** never end a driver in a bare `wait` when `exec > >(tee …)` is in
play (the tee child is a job; `wait` never returns and the done-marker never fires — wait on explicit PIDs, or
touch the marker first).

**Sibling footgun, same failure class — `disown` and ANY `wait` on the SAME jobs are mutually exclusive, bare
or by PID.** A sample-fanout driver that launches each job with `nohup ... & disown` and then closes with a bare
`wait` (no PID args) does NOT block until those jobs finish: `disown` removes the job from the shell's OWN job
table, so the bare `wait` returns as soon as the launch loop itself finishes, and any done-marker written right
after fires early while the jobs are still running (caught once via `ps` / growing row counts: a "DONE" marker
landed with 11 of 19 subjects still mid-sample). Collecting PIDs does not rescue this: bash cannot `wait` on a
disowned PID at all — `wait "${pids[@]}"` on disowned jobs returns immediately too, same false-early marker.
Two actually-correct patterns, pick by whether the driver itself is the thing that needs to block: **the driver
waits → don't disown** (a detached driver that stays up polling until its own `wait`/`wait "${pids[@]}"` returns
needs the jobs to stay in its job table — that's the common case, and `nohup` alone already protects them from a
dropped SSH session); **the jobs must outlive the driver for some other reason → disown, and replace `wait` with
a `kill -0` liveness poll loop on the collected PIDs** (`while kill -0 "$pid" 2>/dev/null; do sleep …; done`,
per PID or over the array) instead of `wait` — never `wait`, bare or by PID, on a disowned job.

**Train/eval overlap (free wall-clock for adapter arms):** when the train artifact is a small adapter (hops via the
store in seconds), run eval cells on a SECOND unit *during* training — eval does the base-anchor cells first, then waits
for the adapter and poll-resumes into arm cells.

**Small-model LoRA generation: default to direct Tinker-side sampling over download-to-vLLM, not only as a
congestion fallback (#353).** Tinker's checkpoint-archive-export step (pulling a trained LoRA adapter local for
vLLM serving) shares one account-level export queue across every session on the same `TINKER_API_KEY` — two
concurrent sessions exporting around the same time can each stall 20-40+ min on a step that normally finishes in
minutes, with neither script at fault (confirmed independently by two sessions hitting the identical symptom on
their own unrelated adapters). `tinker.ServiceClient().create_sampling_client(model_path=<tinker:// sampler
path>)` samples straight from Tinker's hosted model state and never touches the export queue at all — for a
3600-rollout subject on Llama-3.2-3B, direct sampling took ~5-10 min total versus the export step alone costing
20-40+ min before generation could even start. For single-digit-B-parameter LoRA fine-tunes trained via Tinker,
default to direct sampling rather than reaching for it only once congestion is already observed. Before trusting
either serving stack (a mid-run switch or a from-the-start default), run an anchor-reproduction guard: re-generate
a known-reference subject with byte-identical decoding config on the stack you're about to use, and confirm its
rollouts CI-overlap historical values before trusting it for the real run. A local adapter file is still genuinely
needed for two remaining cases — vLLM serving of models too large for direct Tinker-side sampling, and offline
artifact archival — see the archive-download guidance immediately below (#330) for those.

**Tinker checkpoint-archive downloads, for the remaining cases above where a local adapter file is genuinely
required (#330): timeout AND concurrency guidance differ by code path.** Archive creation server-side can take up
to ~1hr even for a modest rank-32 LoRA adapter (observed 29-55min for a 3B-base adapter) — a plain
`tinker.ServiceClient()` in a custom `download_adapter.py`-style script uses the SDK's shorter default HTTP
timeout and raises `tinker.APITimeoutError` well before archive creation finishes, despite the SDK's own poll-loop
heartbeat implying long waits are expected. Fix: pass a generous explicit timeout —
`tinker.ServiceClient(timeout=3600)`. Once that fix is in place, multiple adapter downloads *within the same run*
don't add self-inflicted blocking beyond what the export queue already imposes (confirmed 4/4 succeeding
concurrently after the fix, and separately 20/20 small-corpus adapters in ~5-10min total run concurrently — real
variance, not evidence the long wait is gone in general) — but this is orthogonal to the cross-session
account-level queue congestion described above: if another session is exporting concurrently on the same
`TINKER_API_KEY`, you can still hit the 20-40+ min stall regardless of how many downloads your own run launches at
once, which is itself a reason to keep archive-download usage to the remaining cases above rather than the
default generation path. The `tinker` CLI's own `checkpoint download` command is a DIFFERENT code path with no
equivalent override available (no flag/env var): its internal retry loop has a hardcoded 300s cumulative wait
budget, and launching several `checkpoint download` invocations concurrently reproducibly blew that budget (4/4
timed out, twice in a row) while the identical downloads run ONE AT A TIME each succeeded well within it. For the
CLI path specifically: prefer serial, not concurrent, when fetching more than one adapter.

**On-compute agent delegate (RARE):** drive a named agent in the compute's tmux via the send-keys protocol (clear input
first, send text, separate Enter; long msgs via a literal heredoc). If it loses auth, finish auth-free with a shell
driver instead.

## Step 4 — Collect, log, verify

- Confirm the upload to your artifact store (**every unique artifact** — adapter, eval summaries, **rollout/sample
  logs**, **raw per-pod driver console logs** — e.g. `train_seed*.log`/`gen_seed*.log`; a structured summary alone
  drops warnings/stderr/timing detail a future reader can't get back once the pod is torn down (#419) — generated
  data, reproduce scripts, `SUMMARY.md` — per the profile; full data to files, never truncated).
- **Stamp the decoding config into the rollout artifacts (self-contained artifacts, #233).** Whenever you write
  eval rollouts, persist the exact generation settings — **temperature, top_p, max_new_tokens, seed, and the
  sampling mode (greedy/sample)** — into each rollout row *or* a companion summary, so cross-arm decoding
  comparability is verifiable from the artifacts alone, not only re-derivable from driver source. The data-audit
  gate checks the config is present and consistent across co-measured arms.
- **Log the run in your ledger** (per the profile). Every GPU run goes in. **Close writes exactly ONE explicit
  experiment-level terminal event — a ledger line whose `run` field equals the registry dir name exactly, no
  suffix (#473).** Sub-runs may log whatever granularity they like (`…-smoke`, `…-seed1`, `…-seed2-gen`, …
  events); readers treat the experiment-level event as the authoritative status for the experiment badge — a
  folded/aggregated status inferred only from sub-run events is not a substitute (the exact incident this
  closes: a stale sub-run event rendered a completed experiment `failed` on a downstream dashboard). **Ledger
  terminal status is OPERATIONAL run health, never a scientific verdict (#376):** three product-owned abstract outcomes —
  **completed-as-designed** (the procedure reached its planned close, *whatever that shows* — including a
  correctly executed no-go / stop at an instrument/data/validity gate; preserve that limitation in
  `RESULTS.md` + the ledger note, and keep the `CHECKLIST.md` gate itself `FAIL`), **technical-failure** (a
  technical execution failure or experiment bug prevented a valid planned close — never a hypothesis/effect/
  interpretation/gate outcome), **deliberate-abandon** (a deliberate stop, e.g. `/quit` — today's `killed`).
  Your instance's ledger recipe (narrative prose, no schema change) maps these onto its concrete terminal
  strings (commonly `done`/`failed`/`killed`) — write the value matching which outcome *actually occurred*;
  fail closed (flag, don't guess) if the recipe's terminal set or mapping isn't discoverable or is
  contradictory. **A checklist `[BLOCK] FAIL` is a distinct validity-trail term, never ledger
  `technical-failure` by itself** — it can legitimately co-occur with either ledger outcome and still blocks
  continuation as always. No numerical threshold is introduced; the data-vs-verdict philosophy is unchanged.
- Pull the headline numbers back and report them.
- **Start `RESULTS.md` now** (from your instance's record template) — fill what you have; it must be complete before close.
- **Keep the standing successor handoff current** (the resume contract, below): refresh `TEMP.md` and the
  run-supervision record at each checkpoint.

## Step 5 — Close (kill-on-completion is the DEFAULT)

Idle compute burns money. **Teardown is the default the moment a run completes.**

- **Tear-down-on-block:** a BLOCKED / errored run, OR a run stopped by an instrument/data/validity gate,
  tears down the SAME as a completed one — preserve logs/partials to the store if possible → ledger it per
  the ledger-status definition above (a gate stop is not automatically `technical-failure`; teardown urgency
  never depends on which) → **tear down (stop billing)** → notify the human → *then* discuss redesign. Do NOT
  leave blocked compute billing while you wait (a real incident billed ~8.7h / $76 because the agent asked what
  to do first). The warm env is reproducible. **Only exception:** an explicit, expiry-stamped keepalive set
  for a concrete, named debugging reason.
- **The completion boundary (the safety gate):** tear down only once the upload is **verified** — *every artifact unique
  to this run* (adapter, eval summaries, rollout/sample logs, **raw per-pod driver console logs**, not just their
  structured summary — see Step 4, #419), not just the summary. Before that, teardown loses data — this gate is the
  whole ballgame. **The verify trigger fires per artifact-completion, not only at an imminent teardown (#460):**
  a GPU pod gets this for free (teardown IS the trigger), but a Tinker-hosted or API-only leg never has a
  pod-teardown event to hang it on — trigger the verify EITHER on (a) an imminent teardown OR (b) a leg/artifact
  reaching "done, will not be touched again," whichever comes first, independent of whether a pod exists at all;
  run a consolidated R2-vs-local check (`rclone check` or equivalent) once at THAT leg's own completion, not only a
  single sweep at the very end of the whole run. **Teardown follows your profile's policy** (deploying-account
  key; delete-don't-stop for ephemeral/region-free units; the mechanics are `gpu-job`'s). **Verify on the control
  plane of the deploying account** that the unit is actually gone (never SSH liveness; a 404 from the wrong key
  masquerades as deleted while it bills).
- **Stepping away?** Your unit is lease-covered — `gpu-job`'s lease reaper tears down **THIS unit's id** at lease
  expiry (set a short lease for faster idle teardown; the per-pod watchdog was retired, #266). Peers own theirs.
  This is for a deliberate idle stop — a run you're actively driving keeps its lease fresh via the self-wake
  heartbeat above, so it is never reaped mid-work.
- **Write `RESULTS.md` FIRST — the experiment-close gate (do NOT skip).** Bar: *a fresh agent could reproduce this run
  and understand the data **from this dir alone**.* **Describe each arm's data (the numbers / the plot) per the DESIGN
  spec**; any lightweight qualitative read stays separable from the numbers — no pre-registered verdict (if RESULTS *does*
  assert a claim, state it at the level the design varied — upgrading a bundle-level contrast into a component
  attribution is overclaim — and separate conclusions from postdictions). One `RESULTS.md` at close for a multi-arm
  wave, not per-arm. **Before checking this gate, run ONE real fresh-pull reproduction of the aggregation/rendering
  script(s) that produced the headline numbers/figures (#447):** commit every driver script whose output is
  reported, not just its CSV/PNG output; then from a clean state — remove local scratch, re-run exactly the pull
  commands the record documents (`ARTIFACT_MANIFEST.md` / `scripts/README.md`), re-run the committed scripts —
  diff the regenerated output against the previously-committed one. "The script ran during the live run" is a
  different, weaker claim than "the committed script reproduces the committed artifact from the documented
  recipe against a fresh pull"; only the second is what a future reader/auditor needs, and only the second
  passes this gate.
- **Write `presentation_manifest.json` next to `RESULTS.md` — unconditional, config-free.** Every close writes this file,
  whether or not an instance viewer is configured (a no-op consumer is fine — the manifest still stands alone as
  plain-language arm documentation). Required: `{title, labels: [{match, label}]}` (`title` — one plain sentence
  naming the experiment; `labels` — a lookup table mapping each raw arm/artifact identifier your data uses to a
  human-readable label). All-optional beyond that, per the DESIGN.md Presentation subsection:
  - `figures`: `[{path, caption}]` — the headline figures you rendered at close, `path` relative to this registry dir.
  - `datasets`: `[{name, role: "training"|"eval", columns, source}]` — the datasets worth surfacing, the columns worth
    showing, and an artifact-store pointer for each.
  Render figures and populate dataset entries per what the cleared DESIGN.md Presentation spec asked for — this is
  implementation of an agreed spec, not improvisation. An arm/dataset the spec never mentioned needs no entry.
  The manifest's `title` and `labels` follow the instance's prose style guide when `AAR_STYLE_GUIDE` (an
  optional env var naming a path or URI) is set — unset, the plain-language requirement above stands on its own.
- **The publish leg — YOURS when the brief carries a viewer recipe (#347); manifest-only otherwise.** Check the
  `START.md` instance-profile snapshot for a **`[recipes.viewer]`** pointer (a typed, pinned recipe pointer like
  any other — you read ONLY the snapshot, never a live profile or env var). **No viewer recipe in the snapshot →
  the close is manifest-only** — the manifest still stands on its own as plain-language arm documentation, and
  any later page build is consuming-instance work. **Recipe present → building and publishing the page is part
  of YOUR close**, after upload verification + `RESULTS.md` + `presentation_manifest.json` (it consumes the same verified
  artifacts) and **before the independent close audit and `log-experiment`**, so the audit and the landed
  record see the committed source + the gate's evidence:
  - **The recipe doc must name** (1) the viewer repo and its gated landing path (reusing the instance's existing
    engineer-identity seams — no new credential surface), (2) the shared page-building library and at least one
    committed prior page as the pattern, (3) the assemble → render → bundle → gallery-rebuild commands or worked
    examples, and (4) where per-experiment page source lives in the viewer repo. A resolved recipe missing any of
    these is a **load-bearing brief gap**: flag it and fall back to manifest-only — don't improvise a publish path.
  - **The work:** assemble the per-cell transcripts, author the bespoke per-experiment builder against the
    cleared `DESIGN.md` Presentation spec, render the pinned figures, bundle, update the gallery, and land the
    viewer change through the recipe's gated path. The page is deliberately **bespoke, not a generic
    manifest-to-template generator** — a template flattens the "tell this experiment's story" quality; share only
    house style (the page lib + prior pages as pattern).
  - **The gallery rebuild is a verified gate, not a named step.** The recipe's gallery-rebuild command must
    actually **run** (rendering the page is not the same as rebuilding the index that lists it), and the leg is
    not complete until the new page is **verified present in the built output** — grep the built index/manifest
    for the experiment's slug, or fetch the gallery page and confirm the entry — with the verification evidence
    (the command + the matching output line) cited in the close notes/CHECKLIST. A publish leg without this
    evidence is an incomplete close, not a judgment call: this is the same fail-closed pattern as the skill's
    other gates, added because a real close (run-csp1-gemma4-refusal-ablation-1) built the page but skipped the
    rebuild, so the page existed but the dashboard never listed it.
  - **Commit the iterable SOURCE, not just rendered HTML:** the per-experiment build/assemble scripts + manifest
    land in the viewer repo, so any later agent iterates by editing a script and re-running. Framing genuinely
    shifts on contact with the data (a real headline plot changed form after the researcher saw it) — committed
    source is what keeps that post-close tweak a one-script edit.
  - **The page prose is a FIRST-PASS draft** the researcher polishes on the live page — the plain-language /
    no-verdict / mark-postdictions discipline is exactly what's easy to get wrong; produce a live first-pass
    page, never a finished story. The mechanical bar (figures per spec, source committed, page landed) is the
    checklist gate; prose quality is explicitly not.
- **Delete the transient successor handoff (`TEMP.md`) before staging (#332).** It is working scratch (progress
  timestamps, next-action notes) — never part of the record convention (DESIGN/RESULTS/AUDIT/manifests) — and it
  silently contradicts the final `RESULTS.md` at whatever checkpoint it was last refreshed if it lands in the
  merged registry PR. Delete it here, before staging below (`log-experiment.sh` also rejects a staged `TEMP.md`
  as a belt-and-braces backstop, but don't rely on that — make deleting it your own close step).
- **Stage the record locally** (path-scoped if your tree is shared). It is *landed to GitHub* by `log-experiment` **after** the close audit (below), not by a raw push — the experiment gate needs `AUDIT.md` to exist first.
- **R2-backed record: what goes in git vs the artifact store (#232).** Heavy artifacts (full rollout JSONL,
  adapters, raw logs) belong in **R2**, not git — the profile + `.gitignore` deliberately exclude them. The
  **canonical self-sufficient record** is: commit the **lightweight** files (`RESULTS.md`, the audit + its
  responses, `CHECKLIST.md`, small representative samples the brief asked to pin) **plus an
  `ARTIFACT_MANIFEST.md`** that pins the R2 path, object count, and key sizes of the heavy artifacts (i.e. the
  committed record fully *describes and locates* what's in R2 and proves the upload was verified). Keep full
  JSONL/logs/adapters in R2 unless the brief explicitly requests git-pinned samples — do **not** force hundreds
  of MB into git to satisfy a reproducibility read. If the close audit raises a remote-only reproducibility
  finding, the canonical triage response is to point at the verified `ARTIFACT_MANIFEST.md` + upload (accept-
  with-manifest), recorded in the audit-response section like any other finding.
  **A per-branch `git add -f` does NOT survive landing (automated-researcher#553).** Force-adding a small
  pinned record (screen verdicts, slot sets, data-audit samples) past the blanket `registry/**/*.jsonl`
  ignore rule commits it on your own branch, but `log-experiment` stages from a FRESH worktree off
  `origin/$BASE_BRANCH` with a plain `git add` (no `-f`) — that worktree has never seen your branch's
  commit, so the ignore rule still applies in full there and the staging check BLOCKs. The mechanism that
  actually survives landing: rename the file to a non-ignored extension (e.g. `.jsonl` → `.json`, converting
  NDJSON content to a genuine JSON array under that name) so a plain `git add` stages it cleanly in ANY
  worktree, author's or fresh — don't reach for `git add -f` on a file meant to land.
- **The AGGREGATION step is always LOCAL, whatever the reuse convention (#458).** "Pull, don't rewrite" a
  sibling's script, and treat a sibling's frozen rollouts/judgments as an external input needing no new
  generation — both are the right call for the underlying DATA reuse decision, and neither licenses leaving
  the script that actually PRODUCES the headline CSV/figures pointed at a live external path. That aggregator
  must always be a LOCAL, this-experiment-committed script reading only this-experiment-local/committed
  inputs, same bar as the canonical self-sufficient record above: if it depends on external data (a pulled
  script's original directory, a sibling's live judge-verdict file), pull the RELEVANT SLICE into a local
  durable artifact first — don't duplicate a sibling's multi-GB rollouts wholesale, just the small slice this
  aggregation actually reads — then write the aggregator against that local copy.
- **Every committed script's local-module resolution stays inside this experiment's own tree (#499).** A
  CHECKLIST/RESULTS claim that a script is a "byte-identical vendored copy" is prose, not evidence — it can
  pass self-audit purely because a sibling experiment's directory happened to be reachable in the same shared
  worktree at execution time, which a fresh clone of just this experiment's registry dir cannot rely on. Run
  `scripts/vendoring_check.sh <exp-dir>` (this skill's `scripts/`) — a static scan that flags any
  `sys.path.insert`/`sys.path.append` in a committed `*.py` under `scripts/` whose target resolves OUTSIDE the
  experiment's own directory. Fix any hit (vendor the file byte-identical, or point the reference at a local
  copy) before closing — don't accept the finding in prose.
- **Independent close audit — the OUTPUT-side gate (before clearing the self-wake).** Your self-audit can't catch your
  own reproducibility gaps/overclaims/confounds. Run a **cross-family** audit via **`verify-claims`**
  (`audit_experiment <exp>` → `AUDIT.md`; always the *other* family from whoever ran the work). **Respond to every
  finding** — fix (commit) or a one-line accept/defer with reason; HIGH findings fixed or explicitly justified. Record
  the responses either in a separate **`AUDIT_RESPONSE.md`** or **inline in `AUDIT.md`** (a `## Executor responses`
  section) — `log-experiment` accepts either form (#263). **Triage
  as a PEER, autonomously — close is execution, you don't need the human here.** Audit once (a second pass if your fixes
  were substantive); do NOT auto-iterate to zero findings (it never converges) — stop when only polish remains.
- **Land the record on GitHub via `log-experiment`** (the research counterpart to `ship-change`):
  `log-experiment.sh <exp-dir>` opens a gated PR, verifies the close-audit is present + clean (or, for a
  no-go/eval-only run, a closed `RESULTS.md` decision), takes the cross-family bot approval, and merges — one
  command, not the by-hand branch/approve/merge dance. This is how a finished experiment becomes a GitHub record.
- **Clear the self-wake.** Once the record exists, is landed via `log-experiment`, and compute is torn down: delete this
  experiment's recurring waker and its look-again marker. A finished run with a still-firing waker is a stale-waker
  footgun.
- **Close the run-supervision record — the post-audit FINALIZER (ordering is load-bearing).** Clearing
  desired-active is **not** an early Close step and **not** the audited gate — the checklist gate verifies *close
  readiness* (the record exists, the close path is armed), and the actual clear happens **after** the audit, as the
  *finalizer*. The reason: if you cleared desired-active at the top of Close and then crashed before teardown
  finished, the supervisor would (correctly) refuse to relaunch a not-desired-active run while a pod still bills
  with no brain to tear it down — an orphaned, un-closed session. So keep the run **desired-active until the close
  path is durably in charge**, then run the finalizer: `run_supervision_record.sh stop <run-id>` for a deliberate
  stop (a `/quit`/kill — never to be relaunched), or `close <run-id>` for a finished run (marks it inactive). After
  this, the supervisor will not resurrect the run.
- **Retro — file feedback** (you are the product's user): file product/scaffold friction via feedback-loop's
  `file-feedback` when installed/configured; record deployment-only incidents or ideas through the consuming instance's
  feedback guidance. Include the design-feedback: list the gaps you hit (mechanical defaults invented +
  load-bearing flags). Too many = the brief was under-pinned → feeds back to `design-experiment`. A clean run files
  little.
- **Self-audit the close (the last verification — verify state, not your memory of doing it).** Re-CHECK by inspection:
  artifacts listed in the store, **an explicit experiment-level terminal ledger event exists** (its `run` field
  equals the registry dir name exactly, no suffix — #473) **and** the ledger's folded/latest status is terminal
  (`done`/`failed`/`killed`, or whatever terminal set the instance's ledger recipe defines) — not merely that a
  launch event exists somewhere in its history, and not merely a folded status inferred only from sub-run
  events — compute gone per the control plane of the deploying account, `RESULTS.md` committed + pushed,
  waker + marker cleared. "I ran the step" ≠ "the state is right." **Never backfill a `running`/`launched`/
  `deploying` event after a terminal one has already landed**: a last-non-null-field-wins ledger fold means that
  write silently reopens a finished run for every consumer, even though artifacts/teardown/`RESULTS.md`/close are
  all already done (`automated-researcher#338`). If launch metadata turns out to be missing at this point, attach
  it as a non-status note, or re-emit it on a fresh event that itself carries a terminal status — never as a
  non-terminal status event. If the ledger recipe's terminal set isn't discoverable at all, don't guess: fail
  closed and flag it rather than write a non-terminal status to find out. **Re-check it's the RIGHT terminal
  value, not just A terminal one** — per the ledger-status definition above (#376): a `CHECKLIST.md` `FAIL`
  alone never justifies `technical-failure`.
- **Tear down your own worktree — right after the record lands, right before session reap
  (automated-researcher#532).** Compute already tears down (the lease reaper, above) and the session
  self-reaps (next bullet) — the **workspace** was the missing member of that symmetry: this skill never
  removed its own worktree, so dead ones accumulated silently (worktrees don't bill, so nothing forced the
  issue — a 2026-07-19 sweep found ~46G of them under closed-experiment executor trees alone, every one
  already durable on `main` + the artifact store with zero unique content). **Policy A (researcher-approved,
  2026-07-19): close-time self-teardown, no grace window** — by this point in Close, upload is already
  **verified** and `log-experiment` has already **merged** the record (both above), so the same durability
  gates that already guard those steps are what make this one safe; a marker+deferred-reap alternative was
  considered and rejected as a second mechanism where one suffices. Fires **only on a clean close** — the
  SAME `is-closed` guard session reap uses below: a parked/blocked/crashed run leaves its worktree in place
  for forensics (`repo-janitor`'s sweep is the backstop for that residue, not this step). `cd` OUT of the
  worktree yourself FIRST (e.g. `$HOME` — never remove the tree your own shell is standing in), then
  **immediately, in the same shell**, run `scripts/reap_worktree.sh <run-id> <this worktree's path>`: it
  re-checks the clean-close guard, **requires the given path to match the run-supervision record's own
  `worktree_path`** (bound at `start`, above — the actual run-id<->worktree binding, so a clean-closed run-id
  can only ever reap the worktree IT bound, never a peer's) **and to equal `$OLDPWD`** (defense in depth —
  refuses if you cd'd elsewhere first, or pass any path other than the one you just left), resolves the
  shared checkout on its own via its git-dir, then `git worktree remove --force`s the tree (**`--force` is
  required and
  safe ONLY behind the upload-verified + log-experiment-merged gates above** — executor scratch is untracked
  by design, so a plain `remove` would refuse every time). **Keep the branch ref** — the content already
  landed via squash-merge, so the ref is cheap and preserves recoverability; this never touches the shared
  checkout beyond that one call.
- **Reap your session — the TERMINAL action (free the process, symmetric with pod-teardown).** A finished executor
  session is a ~300–530 MB zombie until reaped; on a small box a batch day of them OOMs the cross-family audits. As the
  VERY LAST thing — once the close is durably done and self-audited — reap your own session:
  `run_supervision_record.sh` scripts' `reap_session.sh <run-id>`. It fires **only on a clean close** (the record is
  `closed` and not `stopped`, via `is-closed`): a **parked / blocked** run is desired-active, never `closed`, so its
  session is KEPT for resume (only its pod was torn down) — this step never reaps it. It reads the record's opaque
  `session_handle` and hands it to your instance's **session-teardown seam** (`EXPERIMENT_SESSION_REAP_CMD` — resolved
  LIVE at close like the deploy-account teardown key, NOT a frozen `START.md` field). The seam is **self-only**: it must
  verify the current session matches the handle and fail closed on a mismatch, so a stale/misbound handle reaps nothing,
  never a peer. **No seam configured → a logged no-op** (the standing session-janitor sweep is the backstop for a
  crashed close, below). The **transcript persists on disk** (resumable) — this frees the process, not the record.
  Nothing runs after this by design.
- **The session janitor is the backstop for a crashed close.** Self-reap above only fires from inside the closing
  session — if the executor dies before it runs (or the close never finalizes), the session sits resident
  indefinitely (~300–530 MB each; a batch of these OOMs a small box). `scripts/session_janitor.sh`, scheduled by the
  instance like `gpu-job`'s `pod_reaper.sh`, sweeps the run-supervision record registry standing outside any one
  session: it reaps ONLY a record that is a clean close (`is-closed`) whose recorded `session_handle` matches a LIVE
  session that reads IDLE — never a parked/blocked/stopped run, never on an inconclusive idleness read. Everything
  else is reported, never killed: a live session with no matching record, a still-desired-active record whose
  session is no longer live (the deeper crash class self-reap can't catch — the executor died before ever reaching
  close), and an inconclusive idle read. It needs its own instance seams (`SESSION_JANITOR_LIST_CMD` /
  `SESSION_JANITOR_IDLE_CMD` / `SESSION_JANITOR_KILL_CMD`) — `reap_session.sh`'s `EXPERIMENT_SESSION_REAP_CMD` is
  self-only by contract and cannot be reused here. Roll it out `--dry-run` first, same as the pod reaper.

---

## Execution discipline (how to run the science well)

- **Verify a `git add` on a newly-built file actually staged it — a clean exit is not evidence (#564).** Git
  silently omits any path matching `.gitignore` from BOTH `git add` and `git status --short`, with zero visual
  difference from "already committed, nothing new" — so a dropped file gives no error and no signal at the
  moment it's dropped. On `csp1-natural-dose-bridge-1`, 4 DESIGN.md-mandated pinned control-draw slot files
  under a `registry/**/*.jsonl` ignore rule sat silently untracked through an ENTIRE run — build, train, serve,
  judge, aggregate, upload, `RESULTS.md`, close-audit — surfaced only by `log-experiment.sh`'s `--dry-run`
  staging gate at the very end, after all the real GPU/API spend was already sunk. **The check, right after any
  `git add <path>` on a file your brief requires to land:** `git status --short -- <path>` must actually list
  the file, unless it's already in a prior commit (`git log -1 --name-only -- <path>` shows it) — a file that's
  neither staged nor already committed silently didn't land. Run this check within minutes of building the
  file, not only at close, where the same gap would otherwise ride the whole run unrecorded. The mechanism that
  actually survives landing is automated-researcher#553's fix — rename to a non-ignored extension (e.g.
  `.jsonl` → `.json`, an NDJSON→JSON-array conversion) so a plain `git add` stages it in ANY worktree — never
  reach for `git add -f`, which does not survive `log-experiment`'s fresh-worktree restaging (see the close
  section above).
- **Parallelize, then iterate.** Run a batch at once (parallel units); use the *whole set* to decide the next batch.
  **Independent units (training runs, evals, API calls) run concurrently by default** — serialize only when it buys
  something real (a validation gate, a true data dependency, a shared-resource limit), matching the design's own
  serialization-justification requirement (`design-experiment` Step 1). **Saturate the hardware:** when GPU utilization
  is low during a long-running step, raise the bottleneck knob (batch size, concurrent requests, whatever's actually
  limiting) and note what you changed in the run log — don't let a rented GPU idle at 15%. (Runtime backstop for #311.)
- **"Concurrency is free" is a REMOTE/provider-side billing statement only (#402).** It (and `design-experiment`'s
  per-compute-billing note) means N parallel Tinker/API-hosted runs cost the same as N serial ones — it says nothing
  about the LOCAL controller box. A driver process that renders/holds data in-process before handing the actual
  compute off to a remote provider (e.g. a Tinker train driver building its rendered datums) still holds real RAM on
  the controller while it runs. A naive "launch all N at once" fan-out can hit the controller's own RAM ceiling well
  before any remote/provider concurrency cap — and a controller-box OOM silently kills the LOCAL driver process with
  ZERO output in its log (indistinguishable from "hasn't started yet"; same signature as a peer-session OOM, but here
  self-inflicted by your own fan-out). **Concrete trigger — default to `local_job_queue.sh` BEFORE launching, not
  after eating the OOM:** any LOCAL fan-out of more than ~8-10 drivers that render/hold data pre-submission, or
  whenever `N > (available_RAM_GB / 2) / per_process_GB` for the box you're on (check with `free -g` and a rough
  per-driver RSS estimate). Cap LOCAL launch concurrency independently of the remote/provider limit —
  `local_job_queue.sh` in this skill's `scripts/` is a reusable throttled-launch queue (poll a running-process count
  against a cap, launch the next queued command as a slot frees) so this doesn't get re-derived from scratch per run.
- **Kill-or-verify the original pod before treating a mid-run reassignment as clean (#334).** Rebalancing a
  queue item onto a newly-free pod is a decision that lives in *your* head, not the original pod's: its
  already-running driver still holds the stale arm/queue list it was launched with and, once it finishes its
  current item, will auto-continue to the next item in that baked-in list — even if you've since reassigned
  that item elsewhere. "The pod looks idle now" is not evidence its driver won't pick the item back up; check
  its actual running process argv (the `--arms`/queue it's really executing) before reassigning, and kill (or
  positively confirm already-exited) that process — then also kill any orphaned worker process it spawned
  (e.g. a `VLLM::EngineCore` left behind by a killed driver, same pattern as `gpu-job` SKILL.md's multi-adapter
  kill guidance) or the GPU isn't actually free either. One pod duplicating another's corpus generation
  concurrently was caught only by a downstream row-count sanity check (a corpus file unexpectedly climbing on
  a pod that should have been idle) — a mechanical kill-or-verify check catches the silent 2x-spend before it
  happens, not after.
- **Utilization is judged as a series, in context — and YOU own that judgment, not the designer (#323, relocated by
  #342).** A single `nvidia-smi` read is one-sample noise (cf. the DATA AUDIT gate's distrust of a 2-sample
  self-smoke): during a long-running GPU-bound step, sample `nvidia-smi
  --query-gpu=utilization.gpu,memory.used --format=csv` over the run's SSH endpoint on your self-wake ticks and keep
  the running series. **Judge the series IN CONTEXT of the current step**, not against a flat threshold: 0% during
  "waiting on judge API" is fine; 0% for 40+ min during "training/generating" is a flatline. **Restart-over-wait
  bias:** with checkpointed resumable state (the resume contract above), restarting a flatlined job costs minutes
  while waiting costs hours — don't kill on one bad sample, but do restart on a sustained flatline against a
  GPU-bound step.
- **API loops start HIGH, not low (#323).** Any API loop (an LLM judge, corpus generation, batch scoring) starts at
  ~**50 concurrent requests** — not 2-3 — with exponential backoff on 429/timeout and re-ramp back up after recovery
  (not a permanent step-down). Discovering the provider's real limit is the backoff's job, not the initial guess's: a
  conservative initial guess just burns wall-clock for nothing (a neutral-corpus generation crawled at ~50 rows/min for
  hours against an over-conservative client; separately, judging at 2-3 workers made judging the bottleneck at ~15
  min/student when ~50 workers cost nothing). ~50 is this default's *starting point*, not a hard cap — where your
  **execution profile** documents a real, tighter provider quota or cost policy (`Cost / API discipline is your
  execution profile's policy`, below), that policy governs; absent one, start at ~50 and let backoff find the ceiling.
- **Drain inflight request pools in completion order, never submission order (#548).** This interacts directly
  with the "start HIGH" guidance above: a driver that drains FIFO (`fut = inflight.pop(0); r = fut.result()`)
  always blocks on the OLDEST-submitted request, even when many newer ones already finished — so *raising*
  concurrency to saturate a per-compute-billed provider makes a FIFO stall WORSE, not better, because more
  inflight slots raise the odds the head-of-line request is a slow one, and every faster request behind it sits
  unwritten until it resolves. This bites hardest on high response-length-variance prompt populations (one run:
  median 38 chars, tail up to 15,002 chars against a 16,384-token cap) and is easy to misdiagnose as a hung
  process rather than a scheduling bug: it produces a sustained ZERO-GROWTH flatline that gets worse, not
  better, as you raise concurrency in response. It's also invisible at smoke scale — a 10-prompt smoke never
  triggered it; it only appeared at n=1207 with concurrency>=48 — so a clean smoke run is not proof the drain
  loop is fine at full scale. Drain with `asyncio.wait(pending, return_when=asyncio.FIRST_COMPLETED)` instead,
  so whichever request finishes first gets processed first — wrap each future with `asyncio.wrap_future(fut)`
  only if `fut` is a `concurrent.futures.Future` (e.g. from a thread/process-pool executor); a native asyncio
  Task/Future from `asyncio.ensure_future`/`create_task` goes into `pending` directly, not through
  `wrap_future`. Completion order is not submission order: carry each request's own input identifier (its
  index or key) alongside its future so the result can be re-associated with its source input when written —
  writing results out purely by arrival position will silently scramble row alignment against the input
  population. Measured effect from the incident that surfaced this: 1.5-1.9/s -> 6.0-6.7/s (3-4x) at
  concurrency 96-128, same model/prompts/decoding config, with no data-validity change — this is a pure
  scheduling fix (when result-to-input identity is carried through, as above).
- **`tinker.ServiceClient().create_sampling_client(...).sample(...)` returns a plain
  `concurrent.futures.Future`, not `tinker.APIFuture` — wrap it, don't call `.result_async()` on it (#552).**
  `tinker.APIFuture` exists in the SDK namespace and does have `.result_async()` as a real coroutine method,
  which makes it easy to assume that's what `.sample()` returns — it isn't: `.sample()` returns a plain
  `concurrent.futures.Future` (`type(fut)` -> `<class 'concurrent.futures._base.Future'>`), which has no
  `.result_async()` and crashes an asyncio-native driver instantly on `AttributeError: 'Future' object has no
  attribute 'result_async'`, before any rows are written. Wrap it with `asyncio.wrap_future(fut)` instead — the
  same `wrap_future` call the completion-order drain loop above already needs for a `concurrent.futures.Future`
  — then use the result directly in `asyncio.wait(pending, return_when=asyncio.FIRST_COMPLETED)`.
- **Smoke-test ladder, always.** Small model first (and any multi-unit path tested small) → smoke → full model → smoke →
  real run. Never jump straight to the full model. On a NEW dataset, smoke the first batches (memory is data-dependent).
- **Read full samples at every stage** — *actual text*, not just aggregates. This is enforced as a **STANDING two-layer
  DATA AUDIT gate on all three data surfaces — training data, eval inputs, and the model-generated eval ROLLOUTS** (the
  rollouts are where parse/truncation/empty-`<think>`/grader-failure bugs live): the **`verify-claims`** deterministic
  `audit_data.py` (full pool + a stratified high-risk sample) on each surface ALWAYS, **then** its cross-family `--data`
  on each surface vs the design intent — **always, no N.A.; the rollouts every run** (generated fresh). A 2-sample
  self-smoke is exactly what misses a truncation bug. When training and eval domains overlap, this includes the
  train/eval leakage screen — DEFAULT to `design-experiment` SKILL.md's semantic-embedding near-dup recipe
  (cross-battery + within-pool), not a token-overlap screen alone. **Always pass `--label-field`** when auditing a surface where
  an added/edited subset sits inside a much larger unchanged base (ablations, add-back waves, targeted edits) — the
  default sample can otherwise oversample the unchanged majority and miss the subset the gate actually cares about.
- **An all-null/all-zero join or aggregation result is (almost) never a real finding — treat it as a loud bug
  signal, not a possible legitimate result.** A per-item join (e.g. correlating verdicts against a blind-key
  parsed from filenames) that returns `null`/`n_items=0` for EVERY row usually means the join key itself is
  broken, not that the correlation happened to vanish — e.g. `mid.rsplit("__", 1)` silently mis-splitting a
  filename that has more than the two `__`-delimited segments the code assumed, producing zero matching keys
  with no error anywhere (#349). Before reporting a zero-match or all-null/all-zero aggregation result:
  re-derive the join keys from a hand-inspected sample and assert the join rate is sane (e.g. >90% of expected
  rows matched) — don't accept "the correlation happened to be null" at face value. This is the
  aggregation-stage analog of the eval-script gotcha where N conditions collapsing to N *identical* numbers
  signals a reused server/stale cache, not a real result (`gpu-job` SKILL.md's `serve_adapters_eval` section).
- **Cheap proxy in, full-scale out.** Search on small model / small-n / cheap grader; validate finalists at full scale.
  **Re-run finalists once** before believing them (best-of-N from noise fakes ≈ SE·√(2 ln N) — often bigger than the
  gaps you chase).
- **Report the data `DESIGN.md` specifies** — don't move the goalposts post-hoc. Interpretation is the researcher's
  separate step; if RESULTS *does* assert a claim, state it at the level the design varied — upgrading a bundle-level
  contrast into a component attribution is overclaim — and separate conclusions from postdictions (fitted after — unverified).
- **Cost / API discipline is your execution profile's policy** + the brief's ceiling. (Typically: GPU is cheap, run it
  autonomously and tear down promptly; the LLM API is the real sink — gate big data-generation/judging runs with the
  human before launching.)
- **Pre-flight the judge key's balance before it runs dry, not after (#354).** A metered-API driver (an LLM judge,
  batch scoring) discovers depletion only via a runtime error burst if nobody checks first — a key that starts a
  judging pass at ~$0 balance, or one that gets topped up but at the run's real burn rate only buys 1-2 hours, both
  fail the same way: a wall of `Insufficient credits` errors mid-run, a killed process, pruning the handful of
  null-valued rows written during the failure window, and a designer round-trip to resume. Before **every**
  (re)launch of such a driver — the initial launch AND every resume after a kill/top-up/key-swap, since the incident
  hit both — fetch the provider's current balance (however your cost_policy recipe says to) and compare it against
  the estimated remaining spend (rows-left * this run's own observed $/row) once that estimate is worth checking
  (e.g. >$5). `judge_balance_check.sh` in this skill's `scripts/` does the threshold/comparison arithmetic so it
  doesn't get re-derived per run — it takes the balance and rate numbers you already have and tells you OK or
  BLOCKED; it has no opinion on the provider or how you fetched the balance.

## Gotchas

> Keep a living log of operational footguns for your instance — **read the configured instance feedback guidance at
> experiment start** (a parallel session may have logged the wall you're about to hit). File product/scaffold friction
> via feedback-loop's `file-feedback` when installed/configured; route deployment-only notes through the consuming
> instance's guidance. Footguns that became code live in the backend helpers — use them, don't re-derive fixes. One
> canonical home per fact (code > protocol step > gotcha log).

## Invariants

- The controller has no GPU — work runs on the compute; you drive it.
- Never reimplement deploys — call the `gpu-job` backend.
- Acquired compute needs profile provisioning, not just the identity bootstrap.
- **Arm the self-wake / idle-cost backstop before any detached run or billable background work; run to completion; never park silently.**
- **Be resumable by a model-free supervisor:** checkpoint state to disk (pod ids, what's collected, decision
  rules), keep the standing handoff (`TEMP.md`) current, write a run-supervision record at run start, and clear it
  as a POST-AUDIT finalizer (`stop`/`close`) — never resurrect a deliberate quit, never clear desired-active early.
- **Kill-on-completion is the default.** Tear down once the upload is *verified* (every unique artifact). Keep one unit
  running only for a concrete queued follow-up (expiry-stamped). Log run + teardown.
- Teardown is **unit-id-scoped** and uses the **deploying account's key** — never blanket-delete idle compute.
- **Tear down your own worktree at a clean close** — the workspace member of the same teardown symmetry as
  pod-teardown and session-reap: removed (`git worktree remove --force`, branch ref kept) only AFTER upload is
  verified AND `log-experiment` has merged the record, gated on the same clean-close `is-closed` check as
  session reap, right before it (`reap_worktree.sh`). A parked/blocked/crashed run keeps its worktree for forensics.
- **Reap your session at a clean close** — symmetric with pod-teardown: the finished executor frees its own process as
  the terminal action (`reap_session.sh`), only on a clean `close`, via the self-only instance seam. A parked/blocked
  run keeps its session for resume; no seam configured is a no-op.
- **Don't redesign** — the brief is locked; design questions go to the designer-of-record.

## Reference

- Your brief: `DESIGN.md` + `START.md` + `CHECKLIST.md` (produced by the `design-experiment` skill).
- Backend: the **`gpu-job`** plugin (deploy / helpers / teardown). Gates: the **`verify-claims`** plugin
  (close audit + data audit). Instance specifics: your **execution profile**.
- Work that's deliberately below this skill's threshold — a quick interactive experiment that still wants a
  durable record, no locked brief, no close-audit — see **`log-exploratory`** instead.
