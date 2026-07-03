# Proposal: Absorb researcher-interaction defaults + feedback-roles text from the instance constitution (#327)

> The canonical design doc (ADR + PR description). Reviewed by `--scaffold` before build. Lands on main.

## Problem

The instance's `~/AGENTS.md` carried a line of cross-agent researcher-interaction dispositions that belong to
this product, not to one box: "labor is free" (currencies + parallel-wave launches), conclusions-vs-postdictions
hygiene, validity/comparability as the standing failure mode, and the user/maintainer hat-separation + feedback
loop. Any deployment's agents need these — they aren't specific to Anton's box — and a Codex-substrate agent
never sees one Claude instance's memories, so leaving them only in instance prose means every other deployment
(and every Codex agent on this one) never gets them. The instance file is supposed to hold only what's true of
this box or this customer (`~/AGENTS.md` "The router"); these four are true of the product.

## Approach

Absorb each into its canonical product home, verifying what already exists before adding anything (per-item
disposition, from the issue):

1. **Labor is free.** Genuinely new to the product — grepped `design-experiment`/`run-experiment`/`AGENTS.md`
   for "attention", "wall-clock", "labor is free": none present. Added:
   - `AGENTS.md` gets a new **"Researcher-interaction defaults"** section (placed after "Rules", before the
     `DISPOSITIONS` block — same pattern as the disposition vocabulary: AGENTS.md carries the short canonical
     *definition*, the skill carries the worked mechanics) stating estimates quote three currencies only
     (dollars, external wall-clock, researcher-attention-minutes), implementation effort is never a reason to
     defer/phase/withhold, and independent work launches as one parallel wave.
   - `design-experiment` SKILL.md's posture section gets a matching bullet, explicitly generalizing #322's
     already-shipped enumerate-don't-justify schedule logic **one level up**: when several independent
     experiments are on the table, default to designing + dispatching them as one wave rather than
     one-at-a-time, with the same three caps (setup/warmup fraction, real compute/quota limit, true data
     dependency) that already govern per-step fan-out.
   - The existing "Cost estimate" bullet (Step 1) gets one clause tying it to the three-currency framing above,
     so the $-only framing already there doesn't read as contradicting the new wall-clock/attention currencies.

2. **Conclusions vs postdictions.** Verified, not duplicated: `design-experiment` SKILL.md already pins
   "RESULTS describes the data, not a verdict" + the postdiction-hygiene parenthetical (Step 1), `run-experiment`
   SKILL.md already requires separating conclusions from postdictions at close (two places), and
   `verify-claims` SKILL.md already carries `conclusions-vs-postdictions` as a close-audit dimension. This is
   full lifecycle coverage (state the rule at design → enforce at close → audit independently) — collapsing it
   into one copy would be a regression, not a consolidation. AGENTS.md's new section gets the one-line canonical
   *definition* only, pointing at the three existing homes, so a reader has one place to learn the disposition
   exists without the mechanics being copied a fourth time.

3. **Validity/comparability as the main failure mode.** Same verification result: this is already the
   throughout-the-file standing disposition in `design-experiment` SKILL.md ("the silent-failure mode that
   needs a human", "the silent failure mode is a clean pipeline producing a confidently-wrong NUMBER") and the
   explicit subject of every `verify-claims` audit dimension (comparability, confounds, anchor). AGENTS.md's new
   section gets the definition line; no mechanics change anywhere.

4. **User/maintainer separation + feedback loop.** Checked the `feedback-loop` plugin's docs first, per the
   issue. `file-feedback` SKILL.md already said "During experiments you are a user of the scaffold" and
   `triage-feedback` SKILL.md already said "You are switching hats from product user to maintainer" — the
   *framing* existed. Missing, and now added: the explicit "separated in time, never both hats at once"
   statement (both skills), "don't refactor the product mid-run" (file-feedback — genuinely absent; grepped for
   "refactor" across the experiment-lifecycle and feedback-loop skills, no hits), and "single-writer — no other
   maintainer pass runs concurrently" (triage-feedback — the skill's frontmatter already says "Never run
   automatically" but the single-writer property specifically was unstated). **The new "don't refactor mid-run"
   line is scoped explicitly against the skill's existing Fix-Now Path** ("if the fix is mechanical and safe,
   fix the canonical home immediately") so the two don't read as contradictory: "mid-run" bars the maintainer's
   *broad* work (redesigning, restructuring, non-trivial fixes) while a user is running an experiment; it does
   not narrow the already-established Fix-Now Path exception, which stays scoped to mechanical/safe fixes only.
   AGENTS.md's new section gets the
   definition line pointing at both skills.

**Discoverability for plugin-only installs (addressed after the first `--scaffold` review round):** root
`AGENTS.md` isn't shipped to a plugin-only install, so every actionable line in its new section is written to be
fully self-contained in the skill that owns it too — a plugin-only install of `design-experiment` or
`file-feedback` gets the complete rule inline, not a pointer that only resolves against a root file it doesn't
have. AGENTS.md's section is a repo-checkout index for cross-referencing, not the sole copy; dropped the one
place that read otherwise (design-experiment's bullet cited "(AGENTS.md)" as if the reader needed that file to
make sense of the line, when the bullet's own text was already complete).

All four get a one-line entry in the new AGENTS.md section (so the section is a complete index of the
migrated dispositions), but three of the four (#2-#4) add no new mechanics beyond that definition line plus the
small missing-framing patches in the owning skills — the point of "verify before absorbing" is to not turn a
migration into duplication.

## Alternatives considered

- **Put all four entirely inside `design-experiment`/`run-experiment`/`feedback-loop`, nothing in AGENTS.md.**
  Rejected: "labor is free" governs the whole researcher-interaction posture, not one skill's internal
  procedure (e.g. it should also shape how an agent scopes an Issue during shaping, not just GPU experiment
  design) — the disposition-vocabulary section already establishes the pattern of "definition in AGENTS.md,
  procedure in skills" for exactly this kind of cross-cutting rule, so this reuses rather than invents structure.
- **Duplicate the conclusions-vs-postdictions and validity/comparability write-ups into AGENTS.md in full.**
  Rejected: both are already correctly placed and phrased in the owning skills (design-experiment /
  run-experiment / verify-claims); a full copy in AGENTS.md would immediately drift from the skill text on the
  next edit to either. A pointer-plus-one-line-definition mirrors how the codebase already treats "the disposition
  vocabulary lives in AGENTS.md, the assign/maintain procedure lives in skills."
- **Fold the new AGENTS.md section into the existing `<!-- DISPOSITIONS:START/END -->` block.** Rejected: that
  block is a special drift-checked sync target (`.aar-ci/checks.sh` keeps it byte-identical with
  `feedback-loop`'s packaged `DISPOSITIONS.md` copies) for the Issue-disposition vocabulary specifically: adding
  unrelated content would either break that sync's intent or require extending the sync mechanism for content
  that isn't packaged/copied anywhere. A separate section keeps the sync's scope exactly what it already is.

## Blast radius

Product-scaffold only, in `automated-researcher`: `AGENTS.md` (new section, outside the drift-checked
`DISPOSITIONS` block — verified `.aar-ci/checks.sh`'s disposition-sync check only fires on that block, not this
one), `plugins/experiment-lifecycle/skills/design-experiment/SKILL.md` (two bullets), `plugins/feedback-loop/
skills/file-feedback/SKILL.md` + `skills/triage-feedback/SKILL.md` (intro framing). `experiment-lifecycle` and
`feedback-loop` both get a `plugin.json` version bump + `CHANGELOG.md` entry per the version-bump gate in
`.aar-ci/checks.sh`. No schema changes, no `run-experiment`/`verify-claims` script changes (their existing
postdiction/comparability text was verified sufficient, not touched). Affects future design/triage conversations
and doc reads; no in-flight experiment or tracker state.

## Rollout + rollback

Doc-only change (prose in AGENTS.md + two SKILL.md files), takes effect on the next read of each file — no
migration, no staged rollout. **Same-day pointer rule (AGENTS.md "Same-day pointer rule"), applied on merge, not
deferred:** immediately after this PR merges, the instance's `~/AGENTS.md` "Labor is free" bullet (the one
residual copy actually live today — items 2-4 were already absorbed out of the instance file in an earlier
rewrite, and the fourth's user/maintainer text does not currently exist there to duplicate) gets replaced with a
one-line pointer at this same box, same day, to this product's new "Researcher-interaction defaults" section —
not left for a later, unscheduled drain pass. Rollback is a plain revert of the merge commit if any of the added
framing turns out wrong in practice; the instance pointer edit reverts independently (it's a separate repo/commit).
