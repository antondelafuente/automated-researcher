---
name: design-experiment
description: >-
  Design a GPU experiment as a DATA-COLLECTION spec WITH the researcher, then land it as a merged
  design-stage record and hand it to `launch-experiment`. The "together" stage: propose with taste + a
  recommendation, surface the load-bearing choices, write the DESIGN.md
  data-collection spec (purpose — what the data is designed to inform; arms; the canonical
  metric + exact eval definitions; comparability; cost — but NOT a pre-registered verdict), fire the
  pre-launch gates (verify-claim on the FACTS + cross-family design-audit on the DATA-TRUSTABILITY)
  the moment it lands and draft the thin START.md executor brief + CHECKLIST.md gates while they
  run, triage the findings, and land the design-stage PR — the triage goes to the researcher as a
  report at the end, not as a second gate. Its LAST step is a question, not an
  action: launch from this session (invoke `launch-experiment`) or hand the launch off to a session
  that holds the supervision machinery — the launching session, whichever it is, becomes
  designer-of-record. Use when starting to design / scope / propose an experiment ("let's design X",
  "propose an experiment for Y"), BEFORE it runs. The layer ABOVE `launch-experiment` +
  run-experiment — those skills START and EXECUTE the locked brief this one produces.
---

# Designing an experiment (the "together" stage)

This is the **design half** of the experiment lifecycle; **`run-experiment`** is the execute half. The two are
deliberately split because they're done by **different agents** with **opposite dispositions**: design is
collaborative-and-careful (you + the researcher, iterate till they stop); execution is autonomous-and-barreling (a
fresh-context executor that runs to completion). The **seam is `DESIGN.md` + `START.md` + `CHECKLIST.md`** — this skill
produces them; the executor consumes them.

You are the **design-side agent**, working with the researcher (the human who holds design clearance). Design produces a
*locked brief*; you do not run the experiment in this thread (the default) — it is launched, from this session or another,
by **`launch-experiment`** (Step 4).

> **Companion skills this one composes** (declare these as dependencies of your install):
> - **`verify-claims`** — supplies the pre-launch gates (`verify_claim` on facts, `audit_experiment --design` on data-trustability,
>   `--data` on data). **Invoke the verify-claims skill; let it resolve its own scripts** — never hardcode a path to
>   another plugin's scripts (installs are version-pinned; the companion skill is the stable interface).
> - **`launch-experiment`** — the launch half: it takes the MERGED design-stage record and starts the executor
>   (fail-closed preconditions, the run worktree, the designer-of-record bind, the instance-resolved launcher +
>   executor model pin, kickoff verification, supervision arming). Invoke it in this session to launch here, or
>   name it in the one-line handoff (Step 4).
> - **`run-experiment`** — the execute half that the launched executor loads.
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
- **Iterate till the researcher stops — at the PROPOSAL** (they are the convergence stop *there*, on arms /
  metric / comparability / presentation). Once they clear the proposal, the draft → gates → triage → land
  sequence runs unbroken and the triage reaches them as a report (Step 2's loop, automated-researcher#817);
  only a load-bearing arbitration re-opens the conversation. Don't over-engineer past the real flaws.

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
  definitions** (load-bearing); **comparability** — the HARD instrument pins (judge model + rubric, battery bytes,
  eval definitions), the anchor-gate, and a measured wobble band on every prior-wave value **the purpose actually
  reads a delta against** (name that comparison set in `DESIGN.md`; those are the deltas the CHECKLIST's
  delta-provenance gate classifies as same-scale or cross-scale, and what the citation-default policy below
  scopes — **the scale unit is the SERVING SESSION, not the wave**: two arms served in the same session need
  no band, and every delta read across two sessions carries one, whether the far side is a prior wave's
  record or another of this wave's own sessions); the confound controls
  that corrupt *the number*; **pinning the independent variable** — name the intervention at the level actually
  varied; a bundled intervention is pinned — and later reported — as the bundle; the data-audit + manifest. This
  is the rigor that earns its keep: the silent failure mode is *a clean pipeline producing a confidently-wrong NUMBER*.
  - **CITATION is the default for every prior-wave value; RE-SERVING TOGETHER is opt-in and justified per delta —
    the lean anchor policy, now *the* rule (researcher standing decision 2026-07-20, re-confirmed 2026-08-08 on
    #694, made unconditional 2026-08-25 on #776).** Instrument pins stay hard — every incident behind this
    section (judge-era incomparability, battery drift) is an *instrument* failure, and those protections are
    untouched. What is retired is the expectation that arms get re-served together *for comparability*: that is not
    free — re-serving + re-generating + re-judging a full prior anchor slate ran ~$16/subject eval+judge,
    ~$200/wave on the depv1 thread, paid wave after wave for deltas nothing in the purpose read, and ~$200 again
    in csp1-refusal-footprint-map-1. So the question is never "should these land together?" but **"which specific
    read delta can the citation path not carry?"** — name that delta and why (its expected size falls inside the
    thread's measured wobble band), or cite. No arm is re-served "for comparability" without that named
    justification, and an arm whose delta against the new arms is not load-bearing does not get re-served just
    because it was measured before.
  - **The rule for a repeat wave on a PINNED instrument stack is the lean anchor slate:** the new arms + a floor
    subject (e.g. stock) + **ONE anchor pair serving as the anchor-GATE** — a breakage tripwire for the wrong
    adapter, instrument drift, or battery drift, not a re-measurement of the prior slate. Every other prior-wave
    value is **cited from the merged records** (the EXACT committed identifier, per the reuse pin below — #487) **alongside
    the instance's measured cross-wave wobble**, not re-served. Re-serving any additional arm is **opt-in and
    justified by a named load-bearing delta** — and it stays cheap to change your mind when one becomes
    load-bearing at interpretation time, provided you name which recovery you actually bought. **The scale
    unit is the serving session, not the wave**, and that cuts both ways. It is why re-serving the prior arm
    ALONE does not put its delta on one scale: the fresh value lands on a NEW session's scale while the arm it
    is read against stays on the session that produced it, so that delta is cross-session — legitimate only on
    a still-pinned stack and reported with the ledger's wobble attached, exactly like a cited value (cost: one
    subject; it buys a fresh value, not a shared scale). And it is equally why two of THIS wave's own arms
    served in SEPARATE sessions are a cross-session read too, carrying the band exactly like a cited value —
    being new buys nothing on its own; being served together is what buys a shared scale. (The ledger's
    cross-wave figure is the conservative bound for a within-wave cross-session read: same stack, less
    elapsed time, so it over-covers rather than under-covers.) The opt-in route that DOES buy a shared scale costs the
    PAIR: re-serve the prior arm alongside the arm it is compared against, both in the new session (cost: two
    subjects) — still an order of magnitude below re-serving the slate. Buy the pair for the one delta whose
    expected size sits inside the wobble band; otherwise the citation path is both cheaper and the honest one.
    *Pinned instrument stack* is the precondition, not a formality: same judge model + judge prompt, same
    batteries, same eval definitions. If any of those moved, prior-wave values are not on this wave's scale
    and the citation path is void — re-serve the pair instead. The judge TRANSPORT is deliberately NOT one of those
    void-triggers (#735): a same-model transport swap is a recorded choice, not a citation-voiding event — cite
    prior-wave values with the standing wobble band you already attach to every cited value, plus a one-line note
    of the swap (and this wave's in-wave anchor pair doubles as a free read of the transport offset).
    *Measured grounding:* two depv1 waves days apart on an identical pinned stack moved stock 0.255→0.199 and a
    top64 re-serve 0.901→0.846 — cross-wave wobble ≈ ±0.05–0.08 against decision-relevant effects of ±0.6. The
    full-slate re-measurement buys precision an order of magnitude below anything that changes a conclusion.
  - **Wobble ledger (the convention that keeps the citation path grounded).** So a citation carries a *measured*
    wobble rather than an assumed one, each wave records its anchor values — the floor subject and the anchor pair,
    one line per wave — in the thread's records (`RESULTS.md`, or the thread's standing record if it keeps one).
    The next wave's design cites that ledger for the wobble figure it attaches to every prior-wave value it reuses.
    The lean slate feeds the ledger it draws on: the floor subject and anchor pair are re-served every wave, so
    their deltas against the prior entry ARE that wave's wobble measurement — a thread's first repeat wave
    establishes the first entry from its own anchor-gate, and the figure gets better grounded each wave. Cite the
    wobble you actually have; never assume one.
- **Every model choice gets named and cleared with the researcher, never inherited by default (#335).** Generation,
  training, judge/classifier, and embedding (leakage-screen) models each get stated explicitly in this pass, with your
  recommendation, same posture as any other load-bearing choice — a model silently inherited from whatever a prior
  design used is the failure mode this closes off (real incident: a judge model rode unexamined across four
  experiments before anyone re-checked whether it was still the right one). Sign-off happens in this SAME
  design-clearance conversation, no separate gate.
- **Train/eval leakage screen — DEFAULT to a semantic-embedding near-dup check, not token overlap alone.**
  Whenever training data and eval data are drawn from overlapping domains (a training pool that intentionally
  shares an eval battery's topic area is the common case), token-overlap screens (e.g. Jaccard on word sets) miss
  real near-duplicates that share little surface vocabulary — a real incident: a 0.6-threshold token-Jaccard
  screen missed training/eval near-duplicates scoring 0.52 and 0.37 Jaccard, and the screen never checked
  within-pool (training-against-itself) duplicates at all, only cross-battery ones. Pin the DEFAULT recipe as:
  embedding cosine similarity (e.g. OpenAI `text-embedding-3-small`), run in BOTH directions — cross-battery
  (training pool vs. every eval battery it must stay disjoint from) AND within-pool (training pool against
  itself) — flagging pairs above a moderate threshold (~0.55-0.6) for a read. A flagged pair is not automatically
  a leak: a "convergent_topical" pair (same narrow domain, distinct question) is an expected structural residual
  when the pool intentionally shares an eval battery's domain, so flagged pairs need a read, not an auto-drop.
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
- **Spot-check split/anchor claims against the literal source artifact before locking (#481).** A quantitative
  split/anchor claim written from the designer's mental model of prior waves' structure — not the literal artifact — is
  a distinct failure class from provenance above: two real incidents had a claimed subject/battery intersection count
  and a cross-battery sanity anchor both wrong on the FIRST real computation at execute time. Before locking, directly
  resolve 2-3 of the design's quantitative split/anchor claims against their cited source: actually compute one or two
  subjects' prompt-ID intersection counts against the real manifest, and confirm any sanity anchor's cited number comes
  from the SAME battery/topic being measured, not a different one. This is mechanical resolution against the source,
  not adversarial reasoning — a bounded spot-check (N=2-3, explicitly non-exhaustive), distinct from `verify-claim`'s
  adversarial fact-check and `design-audit`'s comparability dimension, neither of which resolves an ID intersection or
  anchor number against the actual artifact.
- **Pin exact committed identifiers when reusing prior-wave data, never a category word (#487).** A category word
  ("filler") can silently anchor on the WRONG condition when a prior wave's own NOTE/RESULTS documents an
  accidentally-named or bug-artifact condition sharing a similar name (real incident: `filler64` was an accidental
  hot32-id-order variant, not the benign `fillertrue64` control — picking the wrong one cost ~400 wasted judge calls
  before the naming trap was found). Name the EXACT committed identifier explicitly. When a reuse claim is
  "byte-identical where DESIGN's rule matches," don't trust the filename — rebuild the file from PRIMARY sources and
  assert byte-equality in the build script; this also catches the naming trap by failing loudly instead of silently
  anchoring on the wrong condition.
- **Pin a runnable reference, not prose, for any non-trivial selection/matching algorithm whose hash gets pinned
  (#336).** When a design-stage receipt pins an exact hash/checksum produced by anything beyond a plain sort or
  filter (a greedy match, a tie-break rule, an ordering-sensitive selection), commit the exact code that produced it
  — inline in the receipt, or a small linked script — alongside the pinned hash. A natural-language description
  under-specifies exact behavior (real incident: "greedily take nearest-unused composite, ties resolved by
  bisect-left adjacency" reproduced the aggregate stats but not the pinned hash bit-for-bit across two reasonable
  implementations) — and the design stage has, by definition, already run the algorithm once to compute the hash, so
  committing it costs nothing extra. Trivial derivations (a plain sort/filter) stay out of scope; prose remains
  sufficient there.
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
- **A candidate-generation oversample ratio must be sized against the FULL gate pipeline, not just the
  admission screens.** When a new component's authoring spec pins a length band (or any other draw-gate
  beyond mode), the schedule table's oversample-ratio reasoning has to account for that draw-gate's
  attrition too — the admission screens (political/leakage) passing cleanly gives false confidence that
  enough candidates were drawn (real case, csp1-recipe-reconstruction-1: a component needed both a Task-2
  mode gate and a 300-1500 character length gate; the screens passed 12/12 candidates on the first batch,
  but the length gate, interacting with the generation template's short-translation/single-step-math
  flavors, only let 3/12 through even after a pinned redraw-once — recovered with 2 mechanical backfill
  batches, ~$1-2 extra spend). Before fixing the ratio, gut-check: does the generation template's own
  instruction plausibly produce output that clears every gate in the pipeline, not just the screens?
- **Check the artifact store for an already-complete matching run before specifying fresh GPU spend (#105).** Key
  the check on {adapters × recipe × metric}: if a run already in the store matches all three, validate it (the base
  model it depends on is itself store-staged or revision-pinned per the convention below, and its recorded config
  matches what this design would otherwise dispatch fresh) and reuse it by default — spend on redundant compute only
  when validation fails or the researcher wants a fresh measurement anyway.
- **Cost estimate** (GPU $/hr × runtime; API cascade) — one of the three currencies from the posture note above
  (the other two are wall-clock and researcher-attention; implementation effort is never a fourth): price each
  step's max-fan-out alternative alongside its serialized form. "Cheaper" only counts if the billing model
  actually charges for concurrency: **per-compute
  billing** (e.g. Tinker — N parallel runs cost the same as N serial ones) makes serializing to "save money" a
  false economy, unlike **per-wallclock billing** (a rented pod, where concurrency needs more units to get
  more wall-clock for the same $).
  - **Never carry forward a cross-population LLM-judge/classification per-row rate as-is (#479).** Task-2-style
    classification cost scales with the input/output token lengths of the SPECIFIC rollouts being judged, which vary
    meaningfully across experiments/checkpoints/training regimes — a rate measured on a different rollout population
    can undershoot badly (a real incident: ~75% low, pushing judge spend past the design's notify ceiling). Either
    re-measure on a small sample (~50-100 rows) of the ACTUAL target population before pricing the full pass, or, if
    reusing a cross-experiment rate anyway, apply an explicit safety margin (~1.5-2x, more for reasoning-heavy
    prompts) and size the notify/hard-stop ceilings against the margined estimate, not the raw carried-forward one.
  - **Judge/classifier throughput is a design-time capacity gate, not an execution-time surprise (#352).** Estimate
    the wave's judge-call volume and the rows/min it needs against a deadline, then check that against the pinned
    instrument's PROVISIONED capacity (call latency × concurrency, not the model's theoretical rate) — block dispatch
    if capacity falls short rather than discovering it mid-run (a real incident needed a 2.6x multi-account workaround
    discovered mid-run, after ~14h+ of a wave being judge-bound while ample budget sat unusable). When the capacity
    check falls short, EITHER pre-provision capacity at the current transport (e.g. multiple validated
    keys/accounts, before dispatch) OR swap to an equivalent transport serving the same pinned model+rubric —
    whichever is cheaper — recording the swap on the wave.
    *Measured grounding (depv1 thread):* a same-model transport swap moved cell means by +0.03 to ±0.05 — inside
    the standing ±0.05–0.08 cross-wave wobble — while per-row agreement was 87% within 1 point (the once-cited
    "13%" is that per-row tail, not a scale shift). The model+rubric pin stays hard; the transport is a recorded
    property.

## Step 2 — The pre-launch gates (both MANDATORY for a new design, before any GPU/$ spend)

Both gates are supplied by the **`verify-claims`** companion skill — invoke it; do not reimplement or path-hardcode it.

**Fire BOTH gates the moment `DESIGN.md` is written — concurrently, in the background — then draft Steps 3/3b
while they run (automated-researcher#817).** Neither gate reads `START.md`, `CHECKLIST.md`, or the manifest:
`verify_claim` reads the claims plus its evidence packet, and `design-audit` audits `DESIGN.md` (even its
schedule-efficiency dimension reads fan-out that `DESIGN.md` already carries). So the ordering is:

1. `DESIGN.md` written →
2. **start both gates at once, in the background** — `verify_claim` and `audit_experiment --design` are
   independent processes with no ordering between them; launch them in the same breath, do not serialize
   them and do not wait on the first before starting the second →
3. write `START.md` / `CHECKLIST.md` / `data_audit_manifest.md` / the profile snapshot (Steps 3, 3b) while
   they run →
4. read both verdicts and run the triage loop below.

The drafting IS the wait — don't idle-poll. Measured (#817): the gate window runs ~5-7 min against ~3-6 min
of executor-doc drafting, so overlapping takes the gate off the critical path entirely instead of adding it
to the wall clock. In one metered design the audit launched 3.7 min after `DESIGN.md` existed purely because
the sibling docs were drafted first — that 3.7 min bought nothing.

- **verify-claim — the brief's FACTS:** an independent model family adversarially fact-checks the load-bearing claims —
  anchors, provenance, comparison references — read-only. **DISPUTE blocks until resolved. UNKNOWN = the records can't
  support the claim** (a records-sufficiency finding, not a pass). Don't check your own claim; route it to independent
  context. **Run it in the experiment-dir mode that builds the evidence packet BY CODE** (the skill's `--exp`
  form) rather than hand-copying files into an evidence dir: a path you forget to copy comes back UNKNOWN by
  construction, and the reassemble-and-rerun that follows was found in 3 of 3 recent designs, cost ~2-3 min
  and ~$1-2 each, and never once turned up a new contradiction (automated-researcher#817). Where a claim is
  settled by a hash, a count, a file's existence, or whether a commit landed, declare it with that mode's
  `check:` directives so it resolves deterministically and never spends a verifier pass.
- **design-audit — the design's DATA-TRUSTABILITY** (`audit_experiment --design` → `DESIGN_AUDIT.md`): a cross-family
  review of the *proposal* — does it produce reliable, comparable data for its stated purpose? Instrument pins (unpinned
  judge/rubric/battery/eval definitions), cross-scale band hygiene (the scale unit is the serving SESSION, not the
  wave: any delta read across two sessions missing its wobble band — a cited prior-wave value or the design's own
  second session alike — or a delta smaller than the band it carries with nothing re-served together to resolve it),
  confounds that corrupt the number, variable-pinning, anchor reproduction, honest component / parse% reporting,
  execution under-specification, and is-this-the-right/cheapest-data. A lean design that cites every prior-wave value
  with its band and re-serves nothing beyond the lean slate's floor subject + one anchor-gate pair draws **no finding
  on that basis** — the citation path is the rule, not a gap.
  It leads with a qualitative evidence-quality read
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
- **The loop: audit ONCE → triage as a PEER → run on to landed → REPORT the survivors** (a load-bearing
  arbitration is the one thing that stops the run and goes back to the researcher).
  1. **Audit ONCE.** Do NOT auto-iterate to "no new findings" — an adversarial auditor is *told* to find the next
     thing, so it never converges (real case: a design ran to 9 passes; confounds settled by ~pass 4, the rest was
     polish + over-engineering, which is most of what a long audit costs in added arms/bug-surface). Cross-checking a
     *different* family (e.g. a second-family audit after the first) can catch what the first missed — that's worth one
     extra pass, not endless iteration.
  2. **TRIAGE every finding as a PEER** — **ACCEPT** (real flaw → fix), **DISPUTE** (say why it's wrong/moot),
     **DEFER** (real but out of scope → reason). One line of domain judgment collapses an adversarial finding ("those
     biases are fictional, the base model can't know them" killed a HIGH the auditor couldn't see was moot).
     An **ACCEPT that rests on an artifact being "committed"/present** must mechanically resolve it before the finding
     is marked resolved — `git show <ref>:<path>` for a git-committed artifact, or the equivalent existence check under
     the experiment's R2 prefix — a pinned `SHA256SUMS` hash is a claim, not proof of presence (real incident: a
     `DESIGN_AUDIT_RESPONSE.md` certified an artifact "committed" from its SHA256SUMS line alone; it existed nowhere,
     #356). **An ACCEPT amends ONE file.** The old rule — grep every already-drafted sibling doc for the amended
     clause and update it there too (#375) — is **retired** (automated-researcher#817). It existed only because the
     sibling docs RESTATED `DESIGN.md`'s clauses, so an amendment had to be chased into every copy; the
     cite-don't-restate rule (Steps 3/3b) removes the copies, so there is nothing to chase — fix the clause where it
     lives and every citation follows it. If you ever find yourself wanting that grep, the sibling doc is restating
     something it should be citing: fix THAT instead.
  3. **RUN ON to landed, then REPORT the survivors — do not gate on a second "ok"
     (automated-researcher#817).** The researcher's touch is the PROPOSAL (Step 1: arms / metric /
     comparability / presentation, in plain language, before drafting) — that is where 26 of 37 measured
     designs got their real researcher input, and it is unchanged. Once they have said "looks good" there,
     the rest of this skill is ONE unbroken run: draft → gates → triage → apply every ACCEPT you and the
     auditor agree on → the `log-experiment` design-stage PR (Step 4) → **then** report the triage outcome —
     your judgments (ACCEPT/DISPUTE/DEFER + why), not raw auditor output — as a REPORT, not a gate.
     Researcher instruction (2026-09-02): *waiting on them is fine only at the very end, as a report, not a
     gate.* The measured second touch cost 3-12 min of pure wait per design and changed nothing. Number the
     outputs (`DESIGN_AUDIT.md`, `DESIGN_AUDIT2.md`, …) — the chain is the validity record.
     - **STOP and ask only on a load-bearing arbitration:** a `verify_claim` DISPUTE (always blocking), or a
       design-audit finding whose resolution would change what is being measured, the cleared budget, or the
       locked Presentation. Those need the researcher's domain call, and there the wait is the point — the
       Presentation case included: if a triage outcome forces a data change that breaks a locked figure,
       re-propose and re-lock per Step 1 rather than landing. Everything else — an ACCEPT you can apply, a
       finding one line of domain judgment shows is moot — you resolve, record, and report.
     - **The Presentation lock is already taken** at the proposal touch (Step 1 says it happens "in this SAME
       design-clearance pass, with no separate gate"); this step is what makes the rest of the skill honor
       that instead of re-gating on it.
     - What is still wrong is *rubber-stamping*: a finding you neither fixed nor can defend in one line is not
       triaged. Landing before reporting does not lower that bar — the report is what makes it checkable
       after the fact, and it lands in the record as `DESIGN_AUDIT*.md` either way.
  - **Scope note:** a simple parameter-rerun of an already-audited design runs this same loop against the
    DELTA under the **light design path** below — gates scoped to what changed plus the parent-drift check.
    That is a smaller payload, not a lighter loop.

**The light design path — a declared mode for parameter-reruns, not just prose (#464).** Restating ~80% of a
parent design's `DESIGN.md` for a same-shape rerun (new arms/manifests, nothing else) costs researcher-attention on
every confirm wave and risks restatement-drift — a restated pin silently diverging from the parent's own committed
one (real case: csp1-orig250-attribution-2, a 6-arm rerun of csp1-orig250-attribution-1 with only slot manifests
changed, where ~80% of DESIGN/START/CHECKLIST was pure restatement and the facts gate re-verified facts the
parent's own gate had already cleared). Declare it explicitly:
**This is the DEFAULT for a same-shape rerun, not an opt-in (flipped 2026-09-02, automated-researcher#817).**
When a parent design exists and ONLY arms / manifests / parameters change, **propose the light path in the
proposal message (Step 1) and take it unless the researcher says "full"** — you do not wait for a separate
per-experiment authorization. The old opt-in default was measurably backwards: 13 unattended reruns since
2026-08-01 each fell back to the full path and spent ~30k output tokens restating a parent they should have
cited. A genuinely NEW design — anything moving purpose, metric, comparability, or the instrument stack — is
not a parameter-rerun and still takes the full path. That judgment is yours to make honestly; the header's
parent pin is what makes it checkable afterward.
- **Header + authorization.** `DESIGN.md` opens with `## Rerun of <parent-exp-dir>@<parent-DESIGN.md
  commit-sha> (researcher-authorized <ISO date>)` — pin the parent's `DESIGN.md` at the exact commit it was in
  when authorization was given, not just the directory name, so there is a fixed baseline to check citations
  against later even if the parent doc is amended afterward. The authorization line stays and records the
  researcher's go on the PROPOSAL (the Step 1 touch where you named this mode and they did not ask for
  "full") — same standing as the Presentation lock's authorization line (Step 1 above). It is a record of the
  clearance you already have, never a second gate to wait on.
- **Inherit unchanged sections by citation, not restatement** — "purpose/comparability/metric as `<parent-exp>`,
  re-locked `<date>`," generalizing the existing Presentation inherit-by-citation precedent (Step 1) to every
  section that didn't change.
- **Gates scope to the DELTA, plus one parent-drift check.** verify-claim and design-audit run against only what
  changed (the new arms/manifests/parameters) — not a full re-verification of facts/comparability the parent's own
  gates already cleared — plus one mechanical check that every inherited-by-citation section still matches the
  parent's `DESIGN.md` AT THE PINNED COMMIT from the header, not whatever the parent file says now (`git show
  <pinned-sha>:<parent-exp-dir>/DESIGN.md`, e.g. `git show <pinned-sha>:registry/csp1-author-sweep-1/DESIGN.md`)
  — a citation checked against the parent's current HEAD instead of the pinned commit
  would silently pass even if the parent doc was amended after this rerun was authorized, which is exactly the
  drift this check exists to catch.
- **No new record kind needed downstream.** The rerun's `DESIGN.md` still classifies as design-stage under
  `log-experiment`'s existing rule (a `DESIGN.md` + audit present, no `RESULTS.md`) — the delta-scoped audit above
  is simply what gets posted as its review record, same mechanism, smaller payload.

Genuinely new designs still take the full design + full triage loop; this mode is the default only for the
same-shape rerun class above.

## Step 3 — Write `START.md` (the thin executor bridge) + the self-sufficiency pass

`DESIGN.md` is the science; `START.md` (in the same dir) is the **operational bridge** that lets a fresh-context
executor run it.

**Cite `DESIGN.md`, don't restate it — inside one experiment, not just across a parent/child pair
(automated-researcher#817).** `START.md`, `CHECKLIST.md` and `data_audit_manifest.md` REFERENCE `DESIGN.md`
by section heading for anything the design already states — arms, instrument pins, the canonical metric,
fan-out, comparability, Presentation — and carry only what is operationally theirs: paths, exact commands,
gate wording, the artifact list, the executor disposition. Write "arms + pins per `DESIGN.md` § *What's
measured*" and stop. A restated pin is a second copy that can silently diverge from the one the design-audit
actually cleared, and a median design spent ~24k output tokens pushing audit ACCEPTs back through four docs
that all said the same thing. This generalizes the light path's inherit-by-citation precedent (Step 2) from
parent→child to sibling docs inside ONE experiment, and it is what retires the #375 grep-every-sibling rule:
with no copies, an amendment has exactly one place to land. The self-sufficiency bar is unchanged — a
stranger must still be able to execute from the record — and it is met, because the executor has `DESIGN.md`
open in the same directory. The self-sufficiency pass below is what tests it: a citation that doesn't resolve
to a real heading is a record gap, exactly like a missing path.

Start from the `START` template in this skill's `templates/`. It contains:
- The **executor disposition** (verbatim — this is what makes the handoff work): *"You are an autonomous executor. Run
  this experiment to completion — do not end your turn until you hit a real blocker or you're done; stopping after
  planning is the failure mode. Mechanical/reversible gap → pick a sensible default, record it, keep going.
  Load-bearing gap (changes method/cost/meaning) → notify the designer-of-record and work AROUND it; only a gap that
  blocks the whole run stops you, and then you notify + arm your self-wake — NEVER park silently. Your questions go to
  the designer-of-record, not the researcher — they answer them, and escalate only what changes the cleared budget or
  what is being measured; a question whose answer is checkable from the records or the live state is not a question,
  so verify it yourself instead of routing it anywhere. That routing governs every escalation in this brief however
  the individual line is worded — anything telling you to notify, gate on, or get clearance from "the human" or "the
  researcher" means the designer-of-record unless it is a budget or meaning change. (An instance line requiring a
  *human's* authorization for credentials, access, or destructive operations beyond this run's own compute is a trust
  gate, not question routing — honor it as written.) Never dispatch
  `Agent(subagent_type: "fork")` for a narrow research question — the fork inherits this whole disposition and can
  silently take on the executor role itself; do narrow research inline or via a read-only, non-fork subagent
  instead (see `run-experiment`'s executor-disposition section for the incident and the full guardrail)."*
- **Don't-redesign:** the design is locked; execute per `DESIGN.md`; collect + report the data it specifies (no verdict).
- **Exact input paths + scripts to adapt**, with filename caveats (a filename can lie about its contents — verify by
  content, not name). Point at battle-tested worked-example drivers; don't make the executor write from scratch.
- **Use the `run-experiment` skill** for the loop + gates. **Cost ceiling** + the **designer-of-record** section (how the
  executor routes design-intent questions back to whoever holds the run). **Leave that section's
  `<designer_session>` placeholder alone at design time** — the address is the *launching* session's harness
  session name, which may not be this session, and `launch-experiment` writes it mechanically at launch
  (`launch_record.sh bind-designer`). A hand-written name here is the failure this split closes off: never a
  fleet/tmux name, and never a name you assumed.
- **The resume contract (so a model-free supervisor can relaunch a dead run):** the `START` template's
  resilience wording tells the executor to checkpoint run state to disk (pod ids, what's collected, decision
  rules — not only the conversation), keep a standing `TEMP.md` successor handoff current, and write a
  run-supervision record at run start (cleared as a post-audit finalizer at close). The matching `CHECKLIST`
  open + close gates are below. Keep that wording; the executor reads it on every run. (The contract + the
  `run_supervision_record.sh` helper live in `run-experiment`.)
- **The self-sufficiency pass (do this before handoff):** read `DESIGN.md` + `START.md` **as a stranger** — anything
  load-bearing that's only in your head goes INTO the docs first. Operational facts (paths, scripts) belong in
  `START.md`; the executor having them is not "context we're testing" — guessing a path is not the test, executing the
  *science* from the doc is. **Resolve every `DESIGN.md §` citation** you wrote per the cite-don't-restate rule
  above: a citation pointing at a heading that doesn't exist is a record gap, and it is the one failure mode
  citation introduces that restatement didn't.
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
  STANDING data-audit gate + a CONDITIONAL menu (sample reads, smoke, anchor-gate, delta-provenance — each phrased
  as a *declared invariant*).
- **Instantiate a gate by CITING the design, not by copying it** (the cite-don't-restate rule, Step 3). A gate's
  own wording — what must be true, what evidence resolves it — is operationally the CHECKLIST's; the arms, pins,
  metric and load-bearing deltas it ranges over are `DESIGN.md`'s. "Every delta named load-bearing in `DESIGN.md`
  § *What's measured* has its provenance class recorded" is a complete gate; re-listing those deltas here is a
  copy that goes stale on the first ACCEPT.
- **Seed from THIS skill's templates only — never from a sibling experiment's registry copy** (#512): a closed
  sibling's `CHECKLIST.md` / `data_audit_manifest.md` is that experiment's completed RECORD (ticks, evidence, and
  resolved counts included), not a template — copying it and string-replacing fields ships fabricated evidence
  (a stale field left behind reads as verified when it isn't, and a pre-ticked gate can get treated as already
  satisfied). This applies to any registry file a design stage seeds from a sibling's completed record, not
  `CHECKLIST.md` alone. (Parameter-descendant designs may inherit gate WORDING by citation if desired, never
  tick-state or resolved counts.) `log-experiment`'s design-stage gate deterministically BLOCKs a staged
  `CHECKLIST.md` that still carries any ticked gate marker, as a backstop.
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
  *invalidate* the experiment — citing `DESIGN.md` by heading for the purpose and the invariants the design
  already pins (cite-don't-restate, Step 3), and carrying in its own right only what is dataset-operational:
  paths, hashes, counts, the transformations applied — what the data auditor reads so it can say "this violates the experiment," not just
  "looks okay" (the **data** rung of the facts→logic→data→evidence ladder). The executor runs the two-layer audit
  (`verify-claims`' `audit_data.py` full-pool determinism + `--data` cross-family semantics) per the checklist gate —
  **always, all three surfaces, both layers, no N.A.** (the eval rollouts are audited every run; generated fresh, never
  frozen).

## Step 4 — Land the design-stage PR, then: launch here, or hand off?

Do NOT run the locked design in this designing thread. It goes to a **fresh-context executor** — but
*starting* one is its own step, owned by its own skill (**`launch-experiment`**), because **the designing
session is not always the launching session**. Design owns the science and the Presentation lock; launch owns
the executor, the designer-of-record address, and the supervision.

Why a fresh-context executor is the default:
- **It tests the brief's self-sufficiency on every real run** — the product's core promise ("hand an agent a brief, it
  runs the experiment"). A designer-executes flow never tests that.
- **It separates designer-bias from execution** (same logic as the cross-family audit): the designing agent fills gaps
  from conversation memory; a stranger surfaces the under-specifications. If the executor must guess or ask on anything
  load-bearing, the design wasn't done.
- **It kills implicit-context fragility** (recycles, model-fallbacks, long threads lose warm context) and decouples
  heavy design from delegatable, fan-out execution.

**Land the design-stage PR FIRST — MANDATORY for pre-registered experiments (the launch gate).** The design-audit
(Step 2) is the *scientific* gate: a cross-family review of the design's DATA-TRUSTABILITY. Landing it is a *separate,
GitHub* step — the **design leg of the two-PR flow** (design merge before execution; closeout merge after results).
This step is inside the unbroken run of Step 2's loop, not after a second clearance: once the proposal was
cleared (Step 1) and the triage is done (Step 2), run the **`log-experiment`** skill on the experiment dir
(`log-experiment.sh <registry-dir>`): with a `DESIGN.md` + `DESIGN_AUDIT*.md` and no `RESULTS.md` it classifies as
**design-stage**, gates on the design-audit + the Presentation lock (the `## Presentation (locked with the researcher
<ISO date>)` header from Step 1 above) + a deterministic secret scan, posts that audit as the PR review record, gets
opposite-family bot approval, and merges. It **reuses the already-run design-audit as its review record — it does NOT
re-run the science.** **Nothing is launched until this design-stage PR is merged** — `launch-experiment`'s own
preflight refuses an unmerged record, so an unlanded design cannot be launched by either route below. This gate is
substrate-neutral: it holds whether the executor is Claude, Codex, or any other substrate — there is no separate
per-family wrapper, so a Codex-family design agent reads this same instruction. A design-side agent that has cleared the
design-audit but not landed + merged the design-stage PR is **not done**. (Genuinely exploratory, designer-driven work
that is never launched — see the last paragraph — has no pre-registration to land; this gate is the pre-registered /
launch path, matching `run-experiment`'s existing close-stage `log-experiment` requirement.)

**Then your last step is a QUESTION, not an action** (automated-researcher#813 — the RGBH1 2026-08-31 seam
failure: this step used to say "dispatch it", so a session that was never going to launch still read
launch-side instructions, and the session that actually launched had none). This is also where Step 2's
triage **report** lands — the survivors and your judgment on each, delivered alongside the question, in the
one researcher touch at the end (automated-researcher#817):

> **Design-stage PR merged. Triage: `<n>` findings — `<one line each: ACCEPT applied / DISPUTE why / DEFER
> why>`. Launch from this session, or hand off?**

- **Launch here** → invoke **`launch-experiment`** on the merged record in this same session (the
  same-session design-and-launch flow). You then hold designer-of-record and its duties — they are that
  skill's Step 8, because they belong to whoever launched, not to whoever designed.
- **Hand off** → print ONE paste-able line for the researcher and stop:
  > `/launch-experiment registry/<exp>` — design-stage record is merged on main; the launching session
  > becomes designer-of-record.

  Nothing else is needed, because **the merged record is the whole input**. Do not write a `TEMP.md`, do not
  summarize the design conversation, and do not hand-write your own session name into the brief as the
  designer-of-record: the launcher binds its own address mechanically (researcher rule, 2026-08-31: *"handoff
  is never needed for experiments"*). If something load-bearing is only in this conversation, that is a brief
  gap — put it in the record (Step 3's self-sufficiency pass) rather than in a handoff note.
- **A substrate without supervision machinery defaults to HAND OFF.** Codex today has no
  periodic-reinvocation primitive, so a Codex-family designer hands the launch to a substrate that can arm
  the two supervision layers rather than dispatching itself — the old step told exactly the family that lacks
  the machinery to dispatch itself. (A Codex session may still launch when it is the deliberate choice: it
  runs controller-supervised on the documented manual cadence, per `launch-experiment` and
  `run-experiment`'s `references/CODEX_SUPERVISION.md`.)

Either way the **designer-of-record moves exactly once, at launch, to the launching session**, written to the
record by the launcher. Once it has moved, design-intent questions terminate there, not here.

**Reap your own design worktree — right after you launch or hand off (automated-researcher#532).** If this design session is
running in a dedicated worktree (your instance's convention for giving a design-experiment session its own
working dir, distinct from the shared checkout — mirroring the executor's own dedicated dir), it
is dead by construction once the launch is placed: the design docs it carried already landed on the
default branch via the design-stage PR merge (the gate above), so nothing in it is still load-bearing —
worktrees don't bill, so nothing else forces this teardown (automated-researcher#532: ~37G of exactly this
class of dead worktree accumulated silently before this contract existed). `cd` OUT of it first (e.g. `$HOME`
or the shared checkout — never remove the tree your own shell is standing in), then `git worktree remove
--force` it (**`--force` is required and safe ONLY because the design-stage PR already merged** — design-stage
scratch may be untracked). **Keep the branch ref** — the content already landed via squash-merge, so the ref
is cheap and preserves recoverability. Skip this if you were never given a dedicated worktree for this design
(e.g. exploratory work directly in a shared tree) — there is nothing of this class to reap. If you launched
from this session, reap after `launch-experiment` reports the executor running (you keep supervising from
this session, just not from that tree); if you handed off, reap once the handoff line is out.

**When to keep the designer driving instead (per-experiment, reversible):** genuinely exploratory / iterative work where
the design *is* the discovery and can't be fully pre-specified. For pre-registered, well-specified designs, launch it.
For work that's deliberately below even that threshold — a quick interactive analysis that still deserves a durable
record, not a locked design — see **`log-exploratory`** instead of running this skill's full pipeline.

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
- **Launch half:** the **`launch-experiment`** skill — the design→execute seam (merged-record preconditions, the
  designer-of-record bind, the instance-resolved launcher + executor model pin, kickoff verification, supervision
  arming, and the designer-of-record duties that follow). Compose this skill → that one via the **merged
  design-stage record**, not via a conversation handoff.
- **Execute half:** the **`run-experiment`** skill (what the launched executor loads). Compose via the `START.md`
  handoff.
