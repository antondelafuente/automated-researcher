# Proposal: Presentation spec in DESIGN.md + close-side manifest seam (#313)

> The canonical design doc (ADR + PR description). Reviewed by `--scaffold` before build. Lands on main.

## Problem

Today `DESIGN.md` pins the data-collection spec (arms, metric, comparability) but says nothing about how the
collected data will be *presented* — which figure/table shows what, and which columns/fields a later viewer
would need at what granularity. That gap shows up downstream, past the point where it's cheap to fix:

- The executor writes `RESULTS.md` at close, but there is no standing seam for a machine-readable summary of
  the experiment's arms/labels/artifacts that a later viewer (a dashboard, a gallery page) could consume
  without re-parsing prose.
- When a researcher-facing overview page gets built for an experiment (the instance dashboard pattern, seen in
  `~/research-lab/dashboard/manifests/*.json`), the columns/fields worth surfacing get re-decided *after* the
  run, sometimes discovering the run didn't persist a field the presentation needs (wrong granularity, missing
  per-arm breakdown) — a redo, or a page built from whatever happens to be lying around.
- There's no design-time forcing function asking "what will this data look like when someone views it, and did
  I persist what that requires" — so it's caught late, if at all.

## Approach

Three small, config-free product touches that close this gap without adding a separate researcher-facing gate
— the new spec rides the *existing* design-clearance and design-audit conversations.

**1. `DESIGN.md` gains a Presentation subsection (`design-experiment` Step 1).** Per figure/table: what it
plots, and which columns/fields it needs at what granularity — never what it should *show* (no pre-registered
verdict; this is a data-organization spec, same posture as the rest of `DESIGN.md`). It covers both the
headline-figure spec and the dataset/column organization (training + eval datasets, which columns are worth
surfacing) — so both get cleared by the researcher during the SAME design-clearance conversation that already
happens in Step 1/Step 2, no new step.

**2. `design-audit` (`audit_experiment.sh --design`) gains one checklist line**, alongside the existing
dimensions: does the data-collection spec persist every field the Presentation section requires, at the
granularity it requires? This is a mechanical trustability check — a Presentation section that names a column
the collection plan never records is exactly the kind of execution-under-specification gap `design-audit`
already exists to catch, so it's an added line inside the existing dimension list, not a new gate.

**3. `run-experiment`'s close checklist gains one unconditional, config-free `[BLOCK]` gate** (both in
`SKILL.md` prose and in `CHECKLIST_TEMPLATE.md`, matching the existing `RESULTS.md`-write gate right next to
it — the checklist is the actual forcing function, not the prose): the executor writes
`presentation_manifest.json` into the experiment registry dir, next to `RESULTS.md`. The schema is defined
**self-contained in the product** (`run-experiment/SKILL.md`'s manifest-format note) — required
`{title, labels: [{match, label}]}`, plus two all-optional fields:
- `figures`: `[{path, caption}]` — the experiment's rendered headline figures, paths relative to the registry
  dir, matching the DESIGN.md Presentation spec. Rendered by the EXECUTOR at close time (not a later viz
  pass) — the researcher's only remaining touch is clearing the design, then viewing the page.
- `datasets`: `[{name, role: "training"|"eval", columns, source}]` — what a later overview page would render
  as dataset cards linking into the Inspect bundles.

This is not a new invention: the required `{title, labels}` core matches the schema already proven in
production by an existing consuming instance's dashboard (a backfilled set of per-experiment manifest files
using exactly this shape) — but the product doc defines the fields on its own terms rather than pointing at
that instance's path, so the contract stands on its own regardless of which instance (if any) consumes it.
Nothing beyond `{title, labels}` is required; an executor with no figures/datasets to report writes the
existing two-field shape, unchanged. This step is unconditional (every close writes the file) and config-free
(no flag, no viewer check) — the manifest is useful as plain-language arm documentation even for an instance
with no viewer wired up at all.

**4. An instance-guidance paragraph for the publish leg**, placed alongside `run-experiment`'s existing
consuming-instance pointers (the feedback-guidance / session-reap seam pattern already there). It states, in
the same abstract register the repo already uses for instance concerns (no instance paths or product names):
converting a manifest into a rendered viewer page, and rebuilding any gallery/index, is consuming-instance
work; the per-experiment overview page is deliberately bespoke, not a generic manifest-to-template generator —
the designer-of-record authors it against the cleared Presentation spec at publish time, sharing only house
style (a shared page-building library + prior bespoke pages as pattern), single-writer at results review, same
convention as the rest of the repo's landing steps. An instance with no viewer configured is a no-op by
construction — nothing here requires one to exist.

**Why no separate gate.** The researcher already clears `DESIGN.md` in Step 1/2 and already reviews
`design-audit` findings in the same pass; folding Presentation into that same document and that same audit
means the new spec is cleared for free, at the point where it's cheapest to fix (before any GPU/$ spend) —
consistent with the rest of the design-clearance model.

## Alternatives considered

- **A separate "presentation review" gate after design clearance.** Rejected — the researcher already reviews
  `DESIGN.md` + `design-audit` findings together; a second pass for the same document adds friction without a
  distinct failure mode this doesn't already catch (a missing/wrong Presentation field is exactly a
  data-trustability finding).
- **Invent a new manifest schema.** Rejected — the dashboard already has a proven schema in production
  (`{title, labels}`), backfilled across a dozen experiments; extending it verbatim means the executor's output
  is immediately consumable by the existing pattern with zero translation.
- **Have `run-experiment` build the bespoke overview page itself.** Rejected per the researcher's explicit
  correction (issue #313, 4th comment): a generic manifest-to-template generator flattens the "tell this
  experiment's story" quality that makes a bespoke page worth having. Page-building is scoped to the consuming
  instance, at publish time, against the cleared spec — not to the product's close-time script.
- **Make the manifest write conditional on a Presentation section existing.** Rejected — unconditional keeps
  the close checklist simple (one script path, no branch) and the two-field fallback shape costs nothing to
  write even when there's no figure/dataset to report; the researcher-confirmed spec calls it unconditional.

## Blast radius

- **Product** (this repo): `design-experiment/SKILL.md` (Step 1 — new subsection) and its
  `CHECKLIST_TEMPLATE.md` (one new `[BLOCK]` line, mirroring the existing `RESULTS.md` gate), `verify-claims`'
  `audit_experiment.sh --design` prompt (one new checklist dimension), `run-experiment/SKILL.md` (one new
  close-step bullet + a self-contained manifest-format note). No new scripts, no schema-generator code, no
  template-generator tooling. Version bump (`plugin.json`) on both `experiment-lifecycle` and `verify-claims`
  per the repo's behavior-change convention.
- **Not touched:** any manifest-consuming code (dashboard rendering, gallery rebuild, `build_<exp>_page.py`) —
  that's instance-side by design and explicitly out of scope for this issue.
- **Downstream (consuming instance, informational only):** existing dashboard manifests
  (`~/research-lab/dashboard/manifests/*.json`) are unaffected — the new fields are additive and optional, and
  older manifests without them remain valid under the same schema.

## Rollout + rollback

No staged rollout needed — this is documentation/prompt-text only (a new DESIGN.md subsection template line, a
new design-audit checklist line, a new close-checklist bullet + note, a new guidance paragraph). Effective on
the next experiment designed/executed by an agent reading the updated skills; no runtime behavior change to
existing in-flight experiments. Rollback is a plain revert of the PR if the Presentation subsection or the
manifest step turns out to add more friction than value.
