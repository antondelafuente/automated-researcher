---
name: design-experiment
description: >-
  Design a GPU experiment as a DATA-COLLECTION spec WITH the researcher, then dispatch it
  to a fresh-context executor. The "together" stage: propose with taste + a
  recommendation, surface the load-bearing choices, write the DESIGN.md
  data-collection spec (purpose — what the data is designed to inform; arms; the canonical
  metric + exact eval definitions; comparability; cost — but NOT a pre-registered verdict), run the
  pre-launch gates (verify-claim on the FACTS + cross-family design-audit on the
  DATA-TRUSTABILITY), iterate till the researcher clears it, write the thin START.md executor
  brief + CHECKLIST.md gates, and dispatch a fresh-context executor to run it. Use
  when starting to design / scope / propose an experiment ("let's design X",
  "propose an experiment for Y"), BEFORE it runs. The layer ABOVE run-experiment —
  that skill EXECUTES the locked brief this one produces.
---

# Designing an experiment (the "together" stage)

This is the **design half** of the experiment lifecycle; **`run-experiment`** is the execute half. The two are
deliberately split because they're done by **different agents** with **opposite dispositions**: design is
collaborative-and-careful (you + the researcher, iterate till they stop); execution is autonomous-and-barreling (a
fresh-context executor that runs to completion). The **seam is `DESIGN.md` + `START.md` + `CHECKLIST.md`** — this skill
produces them; the executor consumes them.

You are the **design-side agent**, working with the researcher (the human who holds design clearance). Design produces a
*locked brief*; you do not run the experiment in this thread (the default) — you dispatch it (Step 4).

> **Companion skills this one composes** (declare these as dependencies of your install):
> - **`verify-claims`** — supplies the pre-launch gates (`verify_claim` on facts, `audit_experiment --design` on data-trustability,
>   `--data` on data). **Invoke the verify-claims skill; let it resolve its own scripts** — never hardcode a path to
>   another plugin's scripts (installs are version-pinned; the companion skill is the stable interface).
> - **`run-experiment`** — the execute half that the dispatched executor loads.
> - **`log-experiment`** — logs the design-stage pre-registration (Step 4, below) as a gated PR before
>   dispatch, and later logs the finished result at close; invoke it rather than hand-rolling the PR.

## The posture — together, with taste (the researcher steers hardest here)

- **Propose with a recommendation, not a neutral menu.** Surface the load-bearing choices + tradeoffs, give your taste
  on each, and **clear the design with the researcher before launch.** This is where their input is heaviest.
- **Labor is free.** Estimates you give the researcher quote three currencies only — dollars,
  external wall-clock, and researcher-attention-minutes; your own implementation effort is never a reason to
  defer, phase, or withhold a proposal. When several independent experiments are on the table (multiple arms
  of one question, or multiple independent questions), default to designing + dispatching them as **one
  parallel wave**, not one-at-a-time — the same enumerate-don't-justify logic as the schedule fan-out below
  (#322), one level up: the only valid caps are setup/warmup fraction, a real compute/quota limit, or a true
  data dependency between them.
- **One change vs a matched reference recipe** — design so only the variable under test differs from a known baseline;
  that's what makes a delta interpretable. A validity/comparability slip here ("are these two numbers even on the same
  scale?") is the silent-failure mode that needs a human — adversarially check your own comparisons.
- **Iterate till the researcher stops** (they are the convergence stop — see the gates). Don't over-engineer past the
  real flaws.

## Step 1 — Write `DESIGN.md` (the data-collection spec)

An experiment's job is to produce **trustworthy DATA**. *Interpretation* — "what does it mean" — is a **separate step the
researcher does afterward, by looking at the data.** So `DESIGN.md` (in the experiment's working dir) pins how to collect
**reliable, comparable** data and states **what that data is designed to inform** — it does NOT pre-register a verdict on
it. The line: **purpose and lightweight qualitative reads are welcome; pre-registered verdicts and refutation thresholds
are not.** Pin:
- **WHY + what question the data is designed to inform** (the *purpose* — load-bearing: "trustworthy for what?" is
  undefined without it, and the data-audit's "what would invalidate this" is relative to it). This is a purpose, **not a
  claim**: do NOT pre-register numeric decision rules, falsifiers, "what counts as effect / no-effect / inconclusive," or
  pass/fail verdicts. (If a design genuinely *does* assert a rigorous claim, that's fine — it just then gets audited as
  one; the default is measurement.)
- **What's measured + comparability (the load-bearing core).** The arms; the canonical metric with **EXACT eval
  definitions** (load-bearing); **comparability** — the anchor-gate and co-measurement on ONE scale; the confound controls
  that corrupt *the number*; **pinning the independent variable** — name the intervention at the level actually
  varied; a bundled intervention is pinned — and later reported — as the bundle; the data-audit + manifest. This
  is the rigor that earns its keep: the silent failure mode is *a clean pipeline producing a confidently-wrong NUMBER*.
- **RESULTS describes the data, not a verdict.** `RESULTS.md` reports the numbers / the plot and **may include a
  lightweight, clearly-marked qualitative read** ("the data looks like X") that stays **separable from the numbers**. It
  must NOT make a rigorous pre-registered claim ("H confirmed / refuted at threshold") — the rigorous interpretation is the
  researcher's separate analysis step. (Hygiene survives: a read *fitted* from the data is a postdiction — unverified; if
  load-bearing, test on FRESH data.)
- **Presentation — per figure/table, what it plots and what that requires, concrete enough to render
  unattended — PROPOSED in-chat and explicitly LOCKED by the researcher (researcher-requested, 2026-07-14:
  "I would like the designer to propose what to plot, what rollouts to show etc so I can just say looks good
  or change things. Also it should be plain simple language").** For each headline figure or table the
  experiment will produce: what it plots — the plot type, the arms/series on it, the canonical metric and axes
  — and which columns/fields it needs at what granularity (per-arm? per-row? aggregated?), down to the per-cell
  data source (e.g. one transcript log per {arm × condition}, and which field is the score). The bar: a
  stranger could render each declared figure from the collected artifacts alone, without asking you — because
  at close, the executor will (the `run-experiment` publish leg; when the instance profile carries a
  `[recipes.viewer]` pointer, the standard profile snapshot into `START.md` carries it like any other recipe
  pointer, and the executor's publish leg reads only that snapshot). Still **never what it should show** (no
  pre-registered verdict here either; this is a data-organization spec, same posture as the rest of
  `DESIGN.md`). Cover both halves: the headline-figure spec, and the dataset/column organization (training +
  eval datasets, which columns are worth surfacing) — so both get cleared by the researcher in this SAME
  design-clearance pass, with no separate gate. This is what `design-audit` (Step 2) checks the
  data-collection plan actually persists and can render (the design-audit's scope is unchanged by the lock
  below — it still only checks renderability, never the lock itself, since design-audit runs BEFORE the
  clearance pass that produces the lock).
  - **Propose it explicitly, in-chat, in plain language, before lock.** State three things in the conversation,
    each in plain simple sentences (no jargon; visual structure only, never a predicted finding — same
    no-verdict posture as the rest of `DESIGN.md`), and give a recommendation on each so the researcher can
    just say "looks good" or ask for changes:
    - **What to plot** — the headline figure(s): plot form, axes, series/arms, with your recommendation (a
      cheap sketch/mock where it helps).
    - **What rollouts/transcripts to show** — as **selection RULES, not hand-picked examples** (the data
      doesn't exist yet at design time): which cells (arm × condition), how many per cell, and the sampling
      criterion (e.g. "first 3 by row id", "one refusal + one comply per arm"). An experiment with no rollouts
      states that and proposes the table/dataset view instead.
    - **The page story** — one plain sentence per figure on what the reader will be looking at (visual
      structure, not outcome; no jargon; `STYLE.md` / `AAR_STYLE_GUIDE` register).
  - **The lock is machine-checkable.** Once the researcher gives an explicit word on the proposal (approval or
    requested changes, iterated till they say it's good), the Presentation section header records it:
    `## Presentation (locked with the researcher <ISO date>)` — following the existing good example in
    `registry/csp1-author-sweep-1/DESIGN.md`. Design clearance is **incomplete without this lock** — it is a
    named load-bearing choice, same standing as arms/metric/comparability. If the presentation changes after
    lock (e.g. a design-audit finding forces a data change that breaks a figure), re-propose and re-lock with a
    new date. A rerun/replication may **inherit a prior experiment's locked presentation by citation**
    ("presentation as csp1-X, re-locked `<date>`") instead of re-proposing from scratch — the researcher still
    gets the one-line ask and the header still carries a fresh lock date.
  - **Enforcement lives at design-stage logging (`log-experiment`), NOT design-audit** — design-audit runs
    BEFORE final clearance, so it cannot check a lock that clearance itself produces; the `log-experiment`
    design-stage gate greps the Presentation header for the lock line and BLOCKS the design-stage PR without
    it (see that skill for the exact check).

  The figure captions, story wording, and the experiment's human-facing title follow the instance's prose
  style guide when `AAR_STYLE_GUIDE` (an optional env var naming a path or URI) is set — unset, the
  plain-language requirement above stands on its own.
- **Provenance gets verified or flagged, never asserted.** Before stating any lineage/provenance, sweep the archive for
  EVERY artifact matching the target's name AND public sources under the researcher's handles (HF, GitHub). (Real case:
  a brief asserted "no checkpoint survives" when the policy was in fact live on the customer's own HF — a wrong anchor
  silently corrupts every comparison built on it.) State unverified readings as "documented reading, unverified."
- **While sketching the schedule, ENUMERATE — don't justify (#322).** For each step, name its max sensible
  fan-out and price it, rather than defending whatever serialization is already on the page: justification
  recruits motivated reasoning in both author and auditor (real case, restriction-sweep-1: "single shared GPU
  is the resource limit" justified a serial edge, where the single GPU was itself a discretionary one-pod
  choice made a line earlier — the design-audit's schedule-efficiency dimension passed it because both sides
  were defending the plan as drawn instead of generating the parallel alternative). Concrete defaults for this
  researcher's instance (adjust to your own execution profile / provider quota if it differs): **5-10 pods is
  the NORMAL fan-out for parallelizable GPU work — not an escalation needing permission; API concurrency
  starts at ~50.** Per-wallclock cost is linear in pod count, so pod-count conservatism buys nothing. The only
  real caps, name them explicitly per step: (a) **setup/warmup fraction** — fan out until setup is roughly
  20-30% of the unit of work (e.g. ~15-20 min pod warmup against a 1h generation unit is fine at one pod per
  unit), (b) **GPU stock/quota, or a real API/provider rate limit** (a documented requests-per-minute or
  concurrent-request cap, not a guess), (c) a **true data dependency or validation gate**. A resource limit that is
  itself a discretionary design choice (e.g. "only one pod") is not a valid cap — it's the thing enumeration
  is supposed to catch. (This is the generative half; Step 2's design-audit runs the adversarial half — it
  checks the enumeration is complete and the design sits at max fan-out per step, or the researcher explicitly
  declined it.)
- **Cost estimate** (GPU $/hr × runtime; API cascade) — one of the three currencies from the posture note above
  (the other two are wall-clock and researcher-attention; implementation effort is never a fourth): price each
  step's max-fan-out alternative alongside its serialized form. "Cheaper" only counts if the billing model
  actually charges for concurrency: **per-compute
  billing** (e.g. Tinker — N parallel runs cost the same as N serial ones) makes serializing to "save money" a
  false economy, unlike **per-wallclock billing** (a rented pod, where concurrency needs more units to get
  more wall-clock for the same $).

## Step 2 — The pre-launch gates (both MANDATORY for a new design, before any GPU/$ spend)

Both gates are supplied by the **`verify-claims`** companion skill — invoke it; do not reimplement or path-hardcode it.

- **verify-claim — the brief's FACTS:** an independent model family adversarially fact-checks the load-bearing claims —
  anchors, provenance, comparison references — read-only. **DISPUTE blocks until resolved. UNKNOWN = the records can't
  support the claim** (a records-sufficiency finding, not a pass). Don't check your own claim; route it to independent
  context.
- **design-audit — the design's DATA-TRUSTABILITY** (`audit_experiment --design` → `DESIGN_AUDIT.md`): a cross-family
  review of the *proposal* — does it produce reliable, comparable data for its stated purpose? Comparability / co-measurement
  traps, confounds that corrupt the number, variable-pinning, anchor reproduction, honest component / parse% reporting,
  execution under-specification, and is-this-the-right/cheapest-data. It leads with a qualitative evidence-quality read
  ("this will produce a clean comparable number" / "this confound will muddy it"). Claim-rigor dimensions (decision-rule
  soundness, claim-scope, power) fire **only if the design actually asserts a verdict** — a measurement design that states a
  purpose but no decision rule is not "incomplete." **Schedule efficiency (#311, reframed #322):** enumerate the
  parallelizable steps and their max sensible fan-out; is the design at max fan-out for each, or did the researcher
  explicitly decline it? A resource limit that is itself a discretionary design choice (e.g. "only one pod") is NOT
  a valid reason to serialize. Cost reasoning must distinguish per-compute billing (Tinker-style — parallel is free)
  from per-wallclock billing (a rented pod) — the check that would have failed the 2026-07-03 hereditary-ccp-platform
  incident (serial Tinker training called "cheap" on a false per-wallclock premise).
  (Origin: a real case where two design flaws survived until close because
  nothing audited the *logic* pre-launch — and two later cases where every claim-rigor HIGH dissolved the moment the
  researcher said "just plot the data," while every measurement-validity finding survived and mattered.)
- **The loop: audit ONCE → triage as a PEER → surface survivors to the researcher → they arbitrate.**
  1. **Audit ONCE.** Do NOT auto-iterate to "no new findings" — an adversarial auditor is *told* to find the next
     thing, so it never converges (real case: a design ran to 9 passes; confounds settled by ~pass 4, the rest was
     polish + over-engineering, which is most of what a long audit costs in added arms/bug-surface). Cross-checking a
     *different* family (e.g. a second-family audit after the first) can catch what the first missed — that's worth one
     extra pass, not endless iteration.
  2. **TRIAGE every finding as a PEER** — **ACCEPT** (real flaw → fix), **DISPUTE** (say why it's wrong/moot),
     **DEFER** (real but out of scope → reason). One line of domain judgment collapses an adversarial finding ("those
     biases are fictional, the base model can't know them" killed a HIGH the auditor couldn't see was moot).
  3. **SURFACE the survivors to the researcher with your recommendation on each** — your judgments
     (ACCEPT/DISPUTE/DEFER + why), not raw auditor output. **The researcher is the convergence stop:** they arbitrate
     with domain knowledge and either call another pass or clear it to run. This is the last step of the "together"
     stage — the human's judgment at the design-validity moment is the highest-value, cheapest touch. What's wrong is
     *finishing the audit yourself and rubber-stamping.* Number the outputs (`DESIGN_AUDIT.md`, `DESIGN_AUDIT2.md`, …) —
     the chain is the validity record.
  - **EXCEPTION (flexible):** for simple parameter-reruns of an already-audited design, the researcher may tell you to
    triage-and-run yourself. Default to surfacing for genuinely new designs; they'll say when to just go.

## Step 3 — Write `START.md` (the thin executor bridge) + the self-sufficiency pass

`DESIGN.md` is the science; `START.md` (in the same dir) is the **operational bridge** that lets a fresh-context
executor run it. Start from the `START` template in this skill's `templates/`. It contains:
- The **executor disposition** (verbatim — this is what makes the handoff work): *"You are an autonomous executor. Run
  this experiment to completion — do not end your turn until you hit a real blocker or you're done; stopping after
  planning is the failure mode. Mechanical/reversible gap → pick a sensible default, record it, keep going.
  Load-bearing gap (changes method/cost/meaning) → notify the researcher and work AROUND it; only a gap that blocks the
  whole run stops you, and then you notify + arm your self-wake — NEVER park silently."*
- **Don't-redesign:** the design is locked; execute per `DESIGN.md`; collect + report the data it specifies (no verdict).
- **Exact input paths + scripts to adapt**, with filename caveats (a filename can lie about its contents — verify by
  content, not name). Point at battle-tested worked-example drivers; don't make the executor write from scratch.
- **Use the `run-experiment` skill** for the loop + gates. **Cost ceiling** + who the **designer-of-record** is (so the
  executor can route design-intent questions back to you).
- **The resume contract (so a model-free supervisor can relaunch a dead run):** the `START` template's
  resilience wording tells the executor to checkpoint run state to disk (pod ids, what's collected, decision
  rules — not only the conversation), keep a standing `TEMP.md` successor handoff current, and write a
  run-supervision record at run start (cleared as a post-audit finalizer at close). The matching `CHECKLIST`
  open + close gates are below. Keep that wording; the executor reads it on every run. (The contract + the
  `run_supervision_record.sh` helper live in `run-experiment`.)
- **The self-sufficiency pass (do this before handoff):** read `DESIGN.md` + `START.md` **as a stranger** — anything
  load-bearing that's only in your head goes INTO the docs first. Operational facts (paths, scripts) belong in
  `START.md`; the executor having them is not "context we're testing" — guessing a path is not the test, executing the
  *science* from the doc is.
- **Snapshot the instance profile (mechanical, before the brief commit — #469):** run
  `scripts/aar_profile_snapshot.sh snapshot <path to this experiment's START.md>`. It resolves the live
  `aar-profile` once (the SCHEMA.md discovery order), fails closed with a one-line `BLOCKED: …` if no
  profile is discoverable or its `schema_version` is unknown, and writes/replaces the fenced-TOML
  `## Instance profile (snapshot)` block the `START` template already carries a placeholder for — `[github]` +
  `[recipes.viewer]` only (never `[recipes.visualization_*]`, which `update-site` resolves live by
  design; `update-dashboard` also resolves `[recipes.viewer]` itself, live, for its own post-close purposes
  — see that skill). This is what the `log-experiment` design-stage gate (below, and see that skill) verifies is present
  and not stale before the design PR can merge — the deterministic fix for the #347 silent miss (three closed
  experiments never got a viewer page because nothing ever wrote or checked this block; only a parenthetical
  mention of it existed here). In a **multi-arm wave**, run this once per START.md — each independently
  resolves the same live profile, so every arm's snapshot shares one `profile_sha256`.

## Step 3b — Write `CHECKLIST.md` (the verification gates — the forcing function)

Prose discipline gets skipped (real incident: an executor trained on truncated data because "read your samples" was
buried prose, not a gate). So the design also emits **`CHECKLIST.md`** — the concrete verification gates the executor
must resolve **with evidence**, ticked in place (it becomes both protocol and record).
- **Seed it from the `CHECKLIST` template in this skill's `templates/`** — a UNIVERSAL core (lifecycle gates) + a
  STANDING data-audit gate + a CONDITIONAL menu (sample reads, smoke, anchor-gate, co-measure — each phrased as a
  *declared invariant*).
- **The checklist is YOURS to shape — this is the anti-overfitting rule.** Keep the universal gates; for each
  conditional gate, either instantiate its invariant for THIS experiment or mark it N.A.; then **ADD the
  experiment-specific gates** — you know this experiment's failure modes, the executor can't invent them (a gen step →
  the exact data invariant; a loaded released ckpt → anchor-vs-published; a thinking model → think-length collapse; an
  interp run → hook-removed / patch-recipient-matches-reference). Different experiment types prune and extend very
  differently; don't force a training-shaped checklist onto an interp or eval-only run.
- **The institutional-memory pipeline:** a recurring operational footgun gets promoted into the `CHECKLIST` template as
  a permanent gate (not just prose in a skill) — the durable fix for "discipline gets skipped."
- **Write a `data_audit_manifest.md`** (from the `DATA_AUDIT_MANIFEST` template) — STANDING, not conditional: every
  experiment audits its data, and there are **three surfaces** — (a) training data, (b) eval input data, (c) the
  **model-generated eval rollouts** (where most confidently-wrong-number bugs hide; "read the rollouts, not the
  scalar"). The manifest states purpose, sources/counts, transformations, **known invariants**, and what would
  *invalidate* the experiment — what the data auditor reads so it can say "this violates the experiment," not just
  "looks okay" (the **data** rung of the facts→logic→data→evidence ladder). The executor runs the two-layer audit
  (`verify-claims`' `audit_data.py` full-pool determinism + `--data` cross-family semantics) per the checklist gate —
  **always, all three surfaces, both layers, no N.A.** (the eval rollouts are audited every run; generated fresh, never
  frozen).

## Step 4 — Dispatch the locked brief to a fresh-context executor (the default)

Do NOT run the locked design in this designing thread. **Dispatch the brief to a fresh-context execution substrate.**
The contract is substrate-neutral:

> **`dispatch(DESIGN.md, START.md, CHECKLIST.md) → a fresh-context executor that reads ONLY the brief + scaffold, runs
> the `run-experiment` skill, and reports artifacts/results.`**

The executor MUST start with **fresh context** (no memory of this design conversation) — that property is the whole
point. *How* you spawn it is the instance's implementation of the contract:
- **Autonomous detached run requirement:** the executor substrate must be able to arm its **own independent recurring
  self-wake** and record the waker/backstop id in `CHECKLIST.md`. A controller-held wake, or a monitor used after the
  executor parks, does not satisfy the autonomous detached-run contract. A blocking watcher that keeps the executor turn
  alive is controller-supervised, not autonomous detached; pair it with the idle-cost teardown backstop if compute bills.
- **Claude Code:** a fresh zero-context session in its own dedicated working dir (a launcher script + the session-manager skill).
  A tool-spawned Agent subagent is fine for short controller-supervised probes, but not as the autonomous detached
  executor: it cannot arm the independent recurring wake this contract requires.
- **Codex:** a fresh thread / watcher-driven local execution. A blocking watcher is the controller-supervised
  implementation: it keeps the executor turn alive and, with an idle-teardown backstop for billable compute, satisfies
  this dispatch contract without claiming autonomous-detached status.
- **Other substrates:** a CI job, a remote worker, or a hosted queue that reads the brief.

Why fresh-context dispatch is the default:
- **It tests the brief's self-sufficiency on every real run** — the product's core promise ("hand an agent a brief, it
  runs the experiment"). A designer-executes flow never tests that.
- **It separates designer-bias from execution** (same logic as the cross-family audit): the designing agent fills gaps
  from conversation memory; a stranger surfaces the under-specifications. If the executor must guess or ask on anything
  load-bearing, the design wasn't done.
- **It kills implicit-context fragility** (recycles, model-fallbacks, long threads lose warm context) and decouples
  heavy design from delegatable, fan-out execution.

**Land the design-stage PR FIRST — MANDATORY for pre-registered experiments (the dispatch gate).** The design-audit
(Step 2) is the *scientific* gate: a cross-family review of the design's DATA-TRUSTABILITY. Landing it is a *separate,
GitHub* step — the **design leg of the two-PR flow** (design merge before execution; closeout merge after results). Once
the researcher has cleared the design, run the **`log-experiment`** skill on the experiment dir
(`log-experiment.sh <registry-dir>`): with a `DESIGN.md` + `DESIGN_AUDIT*.md` and no `RESULTS.md` it classifies as
**design-stage**, gates on the design-audit + the Presentation lock (the `## Presentation (locked with the researcher
<ISO date>)` header from Step 1 above) + a deterministic secret scan, posts that audit as the PR review record, gets
opposite-family bot approval, and merges. It **reuses the already-run design-audit as its review record — it does NOT
re-run the science.** **Do NOT dispatch the executor until this design-stage PR is merged.** This gate is
substrate-neutral: it holds whether the executor is Claude, Codex, or any other substrate — there is no separate
per-family wrapper, so a Codex-family design agent reads this same instruction. A design-side agent that has cleared the
design-audit but not landed + merged the design-stage PR is **not done**. (Genuinely exploratory, designer-driven work
that is never dispatched — see the last paragraph — has no pre-registration to land; this gate is the pre-registered /
dispatch path, matching `run-experiment`'s existing close-stage `log-experiment` requirement.)

**The kickoff (only after the design-stage PR is merged):** point the executor at `START.md` with the
run-to-completion + arm-self-wake-first directive. Do NOT ask it to "report your first status lines and stop" — that
invites a park after planning (a real failure mode). The executor's first action is to arm its own heartbeat/self-wake;
then run to completion.

**Arm designer-side supervision (standard, the same moment you kick off) — the two-layer split (#292, #342).**
Supervision divides by failure mode, and the designer's share is deliberately small. (The prior contract — one
`/loop 20m` watchdog per executor, in the designer session — ran every tick with the full designer history:
guaranteed cache-cold past the 5-min prompt-cache TTL, ~$150–250/run-day of avoidable spend measured 2026-07-05.)

- **The executor's own independent self-wake owns IDLE detection** — benign waiting, dead in-session monitors,
  no-progress-while-billing escalation, and GPU-utilization judgment (`run-experiment`: "Arm your self-wake" + the
  #323 utilization-series discipline under Execution discipline). This is why `CHECKLIST.md`'s self-wake gate makes
  autonomous detached runs name an *independent* waker — parking on an in-process monitor is FAIL; a substrate that
  can't arm one runs controller-supervised instead. None of it is the designer's job — no pod SSH, no
  GPU sampling, no checklist-step progress accounting from the designer session.
- **The designer side owns only SESSION-WEDGE**: the executor's session API-stuck mid-turn (usually a rate limit) —
  process alive, no crash, so a crash supervisor never fires; the one failure the executor's own wake cannot cure,
  because its wake queues behind the stuck turn (#292).

For the session-wedge duty, arm at dispatch, in this order:

1. **An event-driven shell monitor per executor pane — zero model turns while healthy.** A detached shell watcher
   polling the pane text (e.g. `tmux capture-pane -t run-<exp> -p | tail -5`) for the terminal transitions — the
   executor's DONE/BLOCKED line, or the pane gone — delivering one notification turn to whoever holds the heartbeat
   duty when it fires; stop it when the run is reaped. (Claude Code: the harness `Monitor` primitive — visible,
   cancellable harness machinery, not an ad-hoc background sleep-loop the harness can kill without anyone noticing.
   Any substrate with a background shell can run the equivalent loop.)
2. **ONE long-cadence heartbeat (45–60 min) for silent-wedge detection.** Read each executor's pane and judge
   advancing-vs-frozen against your previous read — the discrimination a model-free probe (#172) cannot make.
   Frozen → send a cheap, idempotent nudge via `send-keys` (even `hello` resumes an API-errored session; low harm if
   it was actually working — a liveness poke, not driving it, see below). A load-bearing fork/question sitting
   unanswered in the pane, or any real problem → surface to the researcher with specifics. **Supervising several
   executors → ONE merged heartbeat over all their panes, never one loop per run.** (Claude Code: `/loop 45m`; a
   **Codex** designer has no periodic-reinvocation primitive today — the open gap tracked at #223, not something to
   invent here: note the gap, fall back to ad hoc / manual checks at the same cadence, and do NOT block dispatch.)
3. **Designer context known-large → dispatch the heartbeat to a separate small session (optional).** The heartbeat
   needs ~2k tokens (pane text + the rubric above) but a loop in the designer session executes with the whole
   designer history, re-cached cold on every tick. The dispatched watchdog is spawned at kickoff with the list of
   panes to watch, owns only this layer's duty (monitor triggers route to it; it runs the merged heartbeat and
   escalates real problems), and terminates when every supervised run reports DONE or is reaped. It is the
   designer's *delegated* watch, not a new level: nobody watches the watchdog — exactly **one** supervision level,
   as always (the launcher watches the executor; nobody watches the launcher; two nested failures is out of scope).

**Context hygiene while supervising:** route bulk reads (RESULTS.md, screenshots, long logs) through subagents/forks
during supervision phases — context accumulated while babysitting is rent paid on every future turn of the designer
session, including every heartbeat tick.

**Designer-of-record:** you stay available for design-intent questions (the executor routes them back to you), but you
**do not drive it** mid-run (that defeats the self-sufficiency test) — you review at the synthesis pass. The heartbeat
nudge above is bounded health supervision, not driving: it pokes an idle session back to life, it does not answer
design questions or steer the method — a real question still routes back to you as a load-bearing flag, same as always.

**When to keep the designer driving instead (per-experiment, reversible):** genuinely exploratory / iterative work where
the design *is* the discovery and can't be fully pre-specified. For pre-registered, well-specified designs, dispatch it.

## The feedback loop — the executor's gaps GRADE this skill

When the executor runs, **count its gaps**: how many mechanical defaults it had to invent (not pinned by the design) and
how many load-bearing things it had to flag. **Too many = the design wasn't pinned enough → iterate this skill / the
`DESIGN.md` / `START.md` templates.** A clean run from the brief alone is the target; a run full of "I had to guess X" is
signal that the design stage (or the gate meant to catch under-specification) needs sharpening. The retro folds these
counts back as feedback.

## Reference

- **Templates** ship with this skill under `templates/` (`START`, `CHECKLIST`, `DATA_AUDIT_MANIFEST`).
- **Gates:** the `verify-claims` skill — `verify_claim` (facts), `audit_experiment --design` (data-trustability), `--data`
  + `audit_data.py` (data). Invoke that skill; it owns the scripts.
- **Execute half:** the **`run-experiment`** skill (what the dispatched executor loads). Compose this skill → that skill
  via the `START.md` handoff.
