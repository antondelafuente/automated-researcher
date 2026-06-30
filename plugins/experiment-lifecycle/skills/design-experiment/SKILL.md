---
name: design-experiment
description: >-
  Design and pre-register a GPU experiment WITH the researcher, then dispatch it
  to a fresh-context executor. The "together" stage: propose with taste + a
  recommendation, surface the load-bearing choices, write the DESIGN.md
  pre-registration (hypothesis, arms, metric, decision rules, cost), run the
  pre-launch gates (verify-claim on the FACTS + cross-family design-audit on the
  LOGIC), iterate till the researcher clears it, write the thin START.md executor
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
> - **`verify-claims`** — supplies the pre-launch gates (`verify_claim` on facts, `audit_experiment --design` on logic,
>   `--data` on data). **Invoke the verify-claims skill; let it resolve its own scripts** — never hardcode a path to
>   another plugin's scripts (installs are version-pinned; the companion skill is the stable interface).
> - **`run-experiment`** — the execute half that the dispatched executor loads.

## The posture — together, with taste (the researcher steers hardest here)

- **Propose with a recommendation, not a neutral menu.** Surface the load-bearing choices + tradeoffs, give your taste
  on each, and **clear the design with the researcher before launch.** This is where their input is heaviest.
- **One change vs a matched reference recipe** — design so only the variable under test differs from a known baseline;
  that's what makes a delta interpretable. A validity/comparability slip here ("are these two numbers even on the same
  scale?") is the silent-failure mode that needs a human — adversarially check your own comparisons.
- **Iterate till the researcher stops** (they are the convergence stop — see the gates). Don't over-engineer past the
  real flaws.

## Step 1 — Write `DESIGN.md` (the pre-registration)

`DESIGN.md` (in the experiment's working dir) is the experiment's brain and the executor's scientific world. Pin:
- **WHY + hypothesis + predictions, BEFORE running.** Pre-registration is what makes a result interpretable instead of
  a post-hoc story. State the arms, the canonical metric (exact eval definitions — these are load-bearing), and
  **numeric decision rules** (what counts as the effect / no-effect / inconclusive; falsifiers; per-component reporting).
- **Separate conclusions from postdictions:** a *conclusion* is strictly about the pre-registered hypothesis; any *new*
  explanation fitted from the results is a *postdiction* (unverified; if load-bearing, test on FRESH data). Bake this
  distinction into the doc so the executor reports it correctly.
- **Provenance gets verified or flagged, never asserted.** Before stating any lineage/provenance, sweep the archive for
  EVERY artifact matching the target's name AND public sources under the researcher's handles (HF, GitHub). (Real case:
  a brief asserted "no checkpoint survives" when the policy was in fact live on the customer's own HF — a wrong anchor
  silently redefines PASS/FAIL for a zero-context reader.) State unverified readings as "documented reading, unverified."
- **Cost estimate** (GPU $/hr × runtime; API cascade) + the parallel-wave shape (independent arms launch together).

## Step 2 — The pre-launch gates (both MANDATORY for a new design, before any GPU/$ spend)

Both gates are supplied by the **`verify-claims`** companion skill — invoke it; do not reimplement or path-hardcode it.

- **verify-claim — the brief's FACTS:** an independent model family adversarially fact-checks the load-bearing claims —
  anchors, provenance, comparison references — read-only. **DISPUTE blocks until resolved. UNKNOWN = the records can't
  support the claim** (a records-sufficiency finding, not a pass). Don't check your own claim; route it to independent
  context.
- **design-audit — the design's LOGIC** (`audit_experiment --design` → `DESIGN_AUDIT.md`): a cross-family review of the
  *proposal* — confounds/missing controls, comparability traps, pre-registration completeness, claim-scope, power,
  execution under-specification, cheaper-decisive alternatives. (Origin: a real case where two design flaws survived
  until close because nothing audited the *logic* pre-launch.)
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
- **Don't-redesign:** the design is locked; execute per `DESIGN.md`; judge results against its pre-registered rules.
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

**The kickoff:** point the executor at `START.md` with the run-to-completion + arm-self-wake-first directive. Do NOT ask
it to "report your first status lines and stop" — that invites a park after planning (a real failure mode). The
executor's first action is to arm its own heartbeat/self-wake; then run to completion.

**Landing the pre-registration (optional):** to land the cleared design as its own gated PR *before* the run — the
design leg of the two-PR flow — run the **`log-experiment`** skill on the experiment dir: with a `DESIGN.md` +
`DESIGN_AUDIT*.md` and no `RESULTS.md` it classifies as **design-stage** and gates on the design-audit. (Whether/when
this is required — vs landing only the results PR at close — is the instance's push policy, not mandated here.)

**Designer-of-record:** you stay available for design-intent questions (the executor routes them back to you), but you
**do not drive it** mid-run (that defeats the self-sufficiency test) — you review at the synthesis pass.

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
- **Gates:** the `verify-claims` skill — `verify_claim` (facts), `audit_experiment --design` (logic), `--data`
  + `audit_data.py` (data). Invoke that skill; it owns the scripts.
- **Execute half:** the **`run-experiment`** skill (what the dispatched executor loads). Compose this skill → that skill
  via the `START.md` handoff.
