---
name: run-experiment
description: >-
  EXECUTE a pre-designed GPU experiment from its locked brief, on disposable
  compute, as a zero-context autonomous executor. Read the locked DESIGN.md +
  START.md + CHECKLIST.md, arm your self-wake, then run the loop to completion:
  acquire compute (via the gpu-job backend), PROVISION it (per your execution
  profile), drive it (a self-contained detached driver), collect results to your
  artifact store, and CLOSE (RESULTS.md vs the pre-registered rules, cross-family
  audit via verify-claims, teardown, ledger). Use when handed a brief to run
  ("execute the wave per START.md", "run this arm", "kick off the eval"). The
  DESIGN half is the `design-experiment` skill; this is the EXECUTE half — it does
  not design, it runs a locked brief.
---

# Executing an experiment on disposable compute

> **The three seams this skill reads** (so the protocol stays substrate-neutral and the instance stays swappable):
> - **`gpu-job`** (companion plugin) — acquire / deploy / drive-helpers / watchdog / teardown mechanics. Invoke it; do
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
- **The design is locked — don't redesign.** Judge results against the **pre-registered decision rules in `DESIGN.md`**.
  If you think the design is wrong, that's a load-bearing flag to the designer-of-record, not a unilateral change.
- **Record your gaps.** The defaults you had to invent and the things you had to flag are **feedback that grades the
  design**: surface them in the close retro (too many = the design wasn't pinned enough → the design skill needs work).

## Your brief is your world — read it

Your brief is **`DESIGN.md`** (the science + pre-registered rules) + **`START.md`** (the operational bridge: input
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

## Arm your self-wake FIRST — before any detached work (do not skip)

A detached run means **you end your turn and wait to be re-invoked.** The silent-failure class that bites an autonomous
executor is **never-re-invoked** — you sit parked, nothing errored, the compute bills, the research stalls. So **the
moment you start execution — before launching any compute or detached driver — arm an independent, recurring self-wake**
as your standing waker (any single in-process waker can die and leave you parked; the independent waker is the mandatory
backstop). It must, each tick: check each job's **done-marker**, a **liveness** signal (compute busy = alive; idle AND
not-done = hung), AND a **positive-progress** signal (a stage advancing / bytes growing — liveness alone can't tell
working from a wedged hot-loop), plus the driver log for BLOCKED/errors; and it must honor a **look-again deadline** —
a deadline quietly gone past with compute still billing is the signal you parked, so STOP re-waiting, diagnose, and
notify the human.

For an **autonomous detached run**, this is a capability requirement, not a best-effort preference. If your substrate
cannot arm an independent recurring wake, do **not** silently substitute an in-process monitor and proceed. Mark the
`CHECKLIST.md` self-wake gate **FAIL**, notify/escalate before GPU/API spend, and either relaunch in a substrate that
can own its wake or keep the work explicitly controller-supervised. Short controller-supervised probes may use weaker
watching, but then they are not autonomous detached runs; if they leave billable compute detached, still arm the
idle-cost teardown backstop.

> **Claude Code implementation:** a non-durable recurring `CronCreate` (~every 12 min) whose prompt re-checks the pods
> and honors a `LOOK_AGAIN.md` marker (`last_looked` / `look_again_by`, generous). Session-scoped (wakes only its
> creating session; auto-expires ~7 days — re-arm for longer runs). A tool-spawned Agent subagent cannot use this
> independent wake path, so it is not a valid autonomous detached executor. Other substrates: the equivalent recurring
> wake.

## Topology: detached driver (default) vs on-compute agent (rare)

- **Detached shell driver — THE DEFAULT.** scp a self-contained `*.sh`, run it detached (`setsid nohup`), poll a
  done-marker. Deterministic, robust, no auth risk. Use your profile's worked-example drivers as the shape.
- **Delegate to an on-compute agent — RARE.** Brief a named agent on the compute and drive it, for a *messy sub-task*
  that genuinely needs on-box judgment. A second brain (it can lose auth; the controller can't) — use sparingly.
- You (the executor) are the **controller-resident brain driving ephemeral, dumb compute** — there is no agent on the
  GPU box for the default path.

## Step 1 — Acquire the compute

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
base → serve/train → eval → parse → copy artifacts to your store → `touch …/.done`. Run it detached (`setsid nohup`),
then watch with a background until-loop SSH-checking the done-marker (plus the self-wake you already armed).

**Use the `gpu-job` helpers** — its driver library owns the foot-guns (GPU-stage handoffs that wait for the prior runner
and poll until VRAM frees; port/serve waits; artifact-exists checks; liveness; safe process-tree kills; LoRA merges
through a mandatory diff gate). Hand-rolling these is how validity bugs breed. **Two kill rules, three incidents each:**
never raw `pkill -f` / `pgrep -f` in an ssh one-liner (it self-matches your own wrapper — kill by PID, use the liveness
helper); never end a driver in a bare `wait` when `exec > >(tee …)` is in play (the tee child is a job; `wait` never
returns and the done-marker never fires — wait on explicit PIDs, or touch the marker first).

**Train/eval overlap (free wall-clock for adapter arms):** when the train artifact is a small adapter (hops via the
store in seconds), run eval cells on a SECOND unit *during* training — eval does the base-anchor cells first, then waits
for the adapter and poll-resumes into arm cells.

**On-compute agent delegate (RARE):** drive a named agent in the compute's tmux via the send-keys protocol (clear input
first, send text, separate Enter; long msgs via a literal heredoc). If it loses auth, finish auth-free with a shell
driver instead.

## Step 4 — Collect, log, verify

- Confirm the upload to your artifact store (**every unique artifact** — adapter, eval summaries, **rollout/sample
  logs**, generated data, reproduce scripts, `SUMMARY.md` — per the profile; full data to files, never truncated).
- **Log the run in your ledger** (per the profile). Every GPU run goes in.
- Pull the headline numbers back and report them.
- **Start `RESULTS.md` now** (from your instance's record template) — fill what you have; it must be complete before close.
- **Block-prone content** (e.g. misalignment-organism material)? Keep a `TEMP.md` successor-handoff updated at
  checkpoints (pointers only, never trigger text) — one usage-policy block can leave your thread unable to write its own
  handoff later.

## Step 5 — Close (kill-on-completion is the DEFAULT)

Idle compute burns money. **Teardown is the default the moment a run completes.**

- **Tear-down-on-block:** a BLOCKED / errored / instrument-failure run tears down the SAME as a completed one — preserve
  logs/partials to the store if possible → ledger the block → **tear down (stop billing)** → notify the human → *then*
  discuss redesign. Do NOT leave blocked compute billing while you wait (a real incident billed ~8.7h / $76 because the
  AAR asked what to do first). The warm env is reproducible. **Only exception:** an explicit, expiry-stamped keepalive
  set for a concrete, named debugging reason.
- **The completion boundary (the safety gate):** tear down only once the upload is **verified** — *every artifact unique
  to this run*, not just the summary. Before that, teardown loses data — this gate is the whole ballgame. **Teardown
  follows your profile's policy** (deploying-account key; delete-don't-stop for ephemeral/region-free units; the
  mechanics are `gpu-job`'s). **Verify on the control plane of the deploying account** that the unit is actually gone
  (never SSH liveness; a 404 from the wrong key masquerades as deleted while it bills).
- **Stepping away?** Arm the controller-side idle-teardown watchdog (`gpu-job`) — always-on, detached, **scoped to THIS
  unit's id only** (never blanket-delete idle compute; peers own theirs).
- **Write `RESULTS.md` FIRST — the experiment-close gate (do NOT skip).** Bar: *a fresh agent could reproduce this run
  and know what you concluded **from this dir alone**.* **Judge each arm against the pre-registered decision rules in
  `DESIGN.md`**; separate conclusions from postdictions. One `RESULTS.md` at close for a multi-arm wave, not per-arm.
- **Commit + push the record** (path-scoped if your tree is shared; `--rebase --autostash` if rejected).
- **Independent close audit — the OUTPUT-side gate (before clearing the self-wake).** Your self-audit can't catch your
  own reproducibility gaps/overclaims/confounds. Run a **cross-family** audit via **`verify-claims`**
  (`audit_experiment <exp>` → `AUDIT.md`; always the *other* family from whoever ran the work). **Respond to every
  finding** — fix (commit) or a one-line accept/defer with reason; HIGH findings fixed or explicitly justified. **Triage
  as a PEER, autonomously — close is execution, you don't need the human here.** Audit once (a second pass if your fixes
  were substantive); do NOT auto-iterate to zero findings (it never converges) — stop when only polish remains.
- **Clear the self-wake.** Once the record exists, is committed + pushed, and compute is torn down: delete this
  experiment's recurring waker and its look-again marker. A finished run with a still-firing waker is a stale-waker
  footgun.
- **Retro — file feedback** (you are the product's user): what cost you time → gotchas; what would have been smoother →
  backlog; **and the design-feedback: list the gaps you hit** (mechanical defaults invented + load-bearing flags). Too
  many = the brief was under-pinned → feeds back to `design-experiment`. A clean run files little.
- **Self-audit the close (last step — verify state, not your memory of doing it).** Re-CHECK by inspection: artifacts
  listed in the store, ledger has BOTH launch + done events, compute gone per the control plane of the deploying
  account, `RESULTS.md` committed + pushed, waker + marker cleared. "I ran the step" ≠ "the state is right."

---

## Execution discipline (how to run the science well)

- **Parallelize, then iterate.** Run a batch at once (parallel units); use the *whole set* to decide the next batch.
- **Smoke-test ladder, always.** Small model first (and any multi-unit path tested small) → smoke → full model → smoke →
  real run. Never jump straight to the full model. On a NEW dataset, smoke the first batches (memory is data-dependent).
- **Read full samples at every stage** — *actual text*, not just aggregates. This is enforced as a **STANDING two-layer
  DATA AUDIT gate on all three data surfaces — training data, eval inputs, and the model-generated eval ROLLOUTS** (the
  rollouts are where parse/truncation/empty-`<think>`/grader-failure bugs live): the **`verify-claims`** deterministic
  `audit_data.py` (full pool + a stratified high-risk sample) on each surface ALWAYS, **then** its cross-family `--data`
  on each surface vs the design intent — **always, no N.A.; the rollouts every run** (generated fresh). A 2-sample
  self-smoke is exactly what misses a truncation bug.
- **Cheap proxy in, full-scale out.** Search on small model / small-n / cheap grader; validate finalists at full scale.
  **Re-run finalists once** before believing them (best-of-N from noise fakes ≈ SE·√(2 ln N) — often bigger than the
  gaps you chase).
- **Honor the pre-registered rules** in `DESIGN.md` — don't move the goalposts post-hoc; separate conclusions
  (pre-registered) from postdictions (fitted after — unverified).
- **Cost / API discipline is your execution profile's policy** + the brief's ceiling. (Typically: GPU is cheap, run it
  autonomously and tear down promptly; the LLM API is the real sink — gate big data-generation/judging runs with the
  human before launching.)

## Gotchas

> Keep a living log of operational footguns for your instance — **read it at experiment start** (a parallel session may
> have logged the wall you're about to hit); file new ones via `file-feedback`. Footguns that became code live in the
> backend helpers — use them, don't re-derive fixes. One canonical home per fact (code > protocol step > gotcha log).

## Invariants

- The controller has no GPU — work runs on the compute; you drive it.
- Never reimplement deploys — call the `gpu-job` backend.
- Acquired compute needs profile provisioning, not just the identity bootstrap.
- **Arm the self-wake before any detached run; run to completion; never park silently.**
- **Kill-on-completion is the default.** Tear down once the upload is *verified* (every unique artifact). Keep one unit
  running only for a concrete queued follow-up (expiry-stamped). Log run + teardown.
- Teardown is **unit-id-scoped** and uses the **deploying account's key** — never blanket-delete idle compute.
- **Don't redesign** — the brief is locked; design questions go to the designer-of-record.

## Reference

- Your brief: `DESIGN.md` + `START.md` + `CHECKLIST.md` (produced by the `design-experiment` skill).
- Backend: the **`gpu-job`** plugin (deploy / helpers / watchdog / teardown). Gates: the **`verify-claims`** plugin
  (close audit + data audit). Instance specifics: your **execution profile**.
