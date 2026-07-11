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

For an **autonomous detached run**, this is a capability requirement, not a best-effort preference. If your substrate
cannot arm an independent recurring wake, do **not** silently substitute an in-process monitor and then park. Mark the
`CHECKLIST.md` self-wake gate **FAIL**, notify/escalate before GPU/API spend, and either relaunch in a substrate that
can own its wake or keep the work explicitly controller-supervised. A blocking watcher that keeps the executor turn
alive is controller-supervised, not autonomous detached; if it leaves billable compute running in the background, still
arm the idle-cost teardown backstop.

> **Claude Code implementation:** a non-durable recurring `CronCreate` (~every 12 min) whose prompt re-checks the pods
> and honors a `LOOK_AGAIN.md` marker (`last_looked` / `look_again_by`, generous). Session-scoped (wakes only its
> creating session; auto-expires ~7 days — re-arm for longer runs). A tool-spawned Agent subagent cannot use this
> independent wake path, so it is not a valid autonomous detached executor. Other substrates: the equivalent recurring
> wake.

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
  > (record root `${AAR_RUN_SUPERVISION_DIR:-~/.config/run-supervision}`). At run start: `start <run-id>
  > --handoff <TEMP.md path> --session-handle <opaque>` (marks the run **desired-active** and records the opaque,
  > instance-owned handle that binds this run-id to your session — a tmux name / systemd unit / pid-file path; the
  > product never interprets it). At each checkpoint: `checkpoint <run-id> --handoff <path> --lease-pod <id>…`
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
- **Delegate to an on-compute agent — RARE.** Brief a named agent on the compute and drive it, for a *messy sub-task*
  that genuinely needs on-box judgment. A second brain (it can lose auth; the controller can't) — use sparingly.
- You (the executor) are the **controller-resident brain driving ephemeral, dumb compute** — there is no agent on the
  GPU box for the default path.

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
then watch with a background until-loop SSH-checking the done-marker (plus the self-wake you already armed).

**Use the `gpu-job` helpers** — its driver library owns the foot-guns (GPU-stage handoffs that wait for the prior runner
and poll until VRAM frees; port/serve waits; artifact-exists checks; liveness; safe process-tree kills; LoRA merges
through a mandatory diff gate). Hand-rolling these is how validity bugs breed. **Two kill rules, three incidents each:**
never raw `pkill -f` / `pgrep -f` in an ssh one-liner (it self-matches your own wrapper — kill by PID, use the liveness
helper); never end a driver in a bare `wait` when `exec > >(tee …)` is in play (the tee child is a job; `wait` never
returns and the done-marker never fires — wait on explicit PIDs, or touch the marker first).

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
  logs**, generated data, reproduce scripts, `SUMMARY.md` — per the profile; full data to files, never truncated).
- **Stamp the decoding config into the rollout artifacts (self-contained artifacts, #233).** Whenever you write
  eval rollouts, persist the exact generation settings — **temperature, top_p, max_new_tokens, seed, and the
  sampling mode (greedy/sample)** — into each rollout row *or* a companion summary, so cross-arm decoding
  comparability is verifiable from the artifacts alone, not only re-derivable from driver source. The data-audit
  gate checks the config is present and consistent across co-measured arms.
- **Log the run in your ledger** (per the profile). Every GPU run goes in. **Ledger terminal status is
  OPERATIONAL run health, never a scientific verdict (#376):** three product-owned abstract outcomes —
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
  leave blocked compute billing while you wait (a real incident billed ~8.7h / $76 because the AAR asked what
  to do first). The warm env is reproducible. **Only exception:** an explicit, expiry-stamped keepalive set
  for a concrete, named debugging reason.
- **The completion boundary (the safety gate):** tear down only once the upload is **verified** — *every artifact unique
  to this run*, not just the summary. Before that, teardown loses data — this gate is the whole ballgame. **Teardown
  follows your profile's policy** (deploying-account key; delete-don't-stop for ephemeral/region-free units; the
  mechanics are `gpu-job`'s). **Verify on the control plane of the deploying account** that the unit is actually gone
  (never SSH liveness; a 404 from the wrong key masquerades as deleted while it bills).
- **Stepping away?** Your unit is lease-covered — `gpu-job`'s lease reaper tears down **THIS unit's id** at lease
  expiry (set a short lease for faster idle teardown; the per-pod watchdog was retired, #266). Peers own theirs.
- **Write `RESULTS.md` FIRST — the experiment-close gate (do NOT skip).** Bar: *a fresh agent could reproduce this run
  and understand the data **from this dir alone**.* **Describe each arm's data (the numbers / the plot) per the DESIGN
  spec**; any lightweight qualitative read stays separable from the numbers — no pre-registered verdict (if RESULTS *does*
  assert a claim, separate conclusions from postdictions). One `RESULTS.md` at close for a multi-arm wave, not per-arm.
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
  - **Commit the iterable SOURCE, not just rendered HTML:** the per-experiment build/assemble scripts + manifest
    land in the viewer repo, so any later agent iterates by editing a script and re-running. Framing genuinely
    shifts on contact with the data (a real headline plot changed form after the researcher saw it) — committed
    source is what keeps that post-close tweak a one-script edit.
  - **The page prose is a FIRST-PASS draft** the researcher polishes on the live page — the plain-language /
    no-verdict / mark-postdictions discipline is exactly what's easy to get wrong; produce a live first-pass
    page, never a finished story. The mechanical bar (figures per spec, source committed, page landed) is the
    checklist gate; prose quality is explicitly not.
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
  artifacts listed in the store, **the ledger's folded/latest status is terminal** (`done`/`failed`/`killed`, or
  whatever terminal set the instance's ledger recipe defines) — not merely that a launch event exists somewhere
  in its history — compute gone per the control plane of the deploying account, `RESULTS.md` committed + pushed,
  waker + marker cleared. "I ran the step" ≠ "the state is right." **Never backfill a `running`/`launched`/
  `deploying` event after a terminal one has already landed**: a last-non-null-field-wins ledger fold means that
  write silently reopens a finished run for every consumer, even though artifacts/teardown/`RESULTS.md`/close are
  all already done (`automated-researcher#338`). If launch metadata turns out to be missing at this point, attach
  it as a non-status note, or re-emit it on a fresh event that itself carries a terminal status — never as a
  non-terminal status event. If the ledger recipe's terminal set isn't discoverable at all, don't guess: fail
  closed and flag it rather than write a non-terminal status to find out. **Re-check it's the RIGHT terminal
  value, not just A terminal one** — per the ledger-status definition above (#376): a `CHECKLIST.md` `FAIL`
  alone never justifies `technical-failure`.
- **Reap your session — the TERMINAL action (free the process, symmetric with pod-teardown).** A finished executor
  session is a ~300–530 MB zombie until reaped; on a small box a batch day of them OOMs the cross-family audits. As the
  VERY LAST thing — once the close is durably done and self-audited — reap your own session:
  `run_supervision_record.sh` scripts' `reap_session.sh <run-id>`. It fires **only on a clean close** (the record is
  `closed` and not `stopped`, via `is-closed`): a **parked / blocked** run is desired-active, never `closed`, so its
  session is KEPT for resume (only its pod was torn down) — this step never reaps it. It reads the record's opaque
  `session_handle` and hands it to your instance's **session-teardown seam** (`EXPERIMENT_SESSION_REAP_CMD` — resolved
  LIVE at close like the deploy-account teardown key, NOT a frozen `START.md` field). The seam is **self-only**: it must
  verify the current session matches the handle and fail closed on a mismatch, so a stale/misbound handle reaps nothing,
  never a peer. **No seam configured → a logged no-op** (the deferred session-janitor is the backstop). The **transcript
  persists on disk** (resumable) — this frees the process, not the record. Nothing runs after this by design.

---

## Execution discipline (how to run the science well)

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
  self-inflicted by your own fan-out). Cap LOCAL launch concurrency independently of the remote/provider limit —
  `local_job_queue.sh` in this skill's `scripts/` is a reusable throttled-launch queue (poll a running-process count
  against a cap, launch the next queued command as a slot frees) so this doesn't get re-derived from scratch per run.
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
- **Smoke-test ladder, always.** Small model first (and any multi-unit path tested small) → smoke → full model → smoke →
  real run. Never jump straight to the full model. On a NEW dataset, smoke the first batches (memory is data-dependent).
- **Read full samples at every stage** — *actual text*, not just aggregates. This is enforced as a **STANDING two-layer
  DATA AUDIT gate on all three data surfaces — training data, eval inputs, and the model-generated eval ROLLOUTS** (the
  rollouts are where parse/truncation/empty-`<think>`/grader-failure bugs live): the **`verify-claims`** deterministic
  `audit_data.py` (full pool + a stratified high-risk sample) on each surface ALWAYS, **then** its cross-family `--data`
  on each surface vs the design intent — **always, no N.A.; the rollouts every run** (generated fresh). A 2-sample
  self-smoke is exactly what misses a truncation bug. **Always pass `--label-field`** when auditing a surface where
  an added/edited subset sits inside a much larger unchanged base (ablations, add-back waves, targeted edits) — the
  default sample can otherwise oversample the unchanged majority and miss the subset the gate actually cares about.
- **Cheap proxy in, full-scale out.** Search on small model / small-n / cheap grader; validate finalists at full scale.
  **Re-run finalists once** before believing them (best-of-N from noise fakes ≈ SE·√(2 ln N) — often bigger than the
  gaps you chase).
- **Report the data `DESIGN.md` specifies** — don't move the goalposts post-hoc. Interpretation is the researcher's
  separate step; if RESULTS *does* assert a claim, separate conclusions from postdictions (fitted after — unverified).
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
- **Reap your session at a clean close** — symmetric with pod-teardown: the finished executor frees its own process as
  the terminal action (`reap_session.sh`), only on a clean `close`, via the self-only instance seam. A parked/blocked
  run keeps its session for resume; no seam configured is a no-op.
- **Don't redesign** — the brief is locked; design questions go to the designer-of-record.

## Reference

- Your brief: `DESIGN.md` + `START.md` + `CHECKLIST.md` (produced by the `design-experiment` skill).
- Backend: the **`gpu-job`** plugin (deploy / helpers / teardown). Gates: the **`verify-claims`** plugin
  (close audit + data audit). Instance specifics: your **execution profile**.
