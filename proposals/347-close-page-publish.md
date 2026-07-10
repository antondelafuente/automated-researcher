# Proposal: Executor builds + publishes the viewer page at close, with committed iterable source (#347)

> The canonical design doc (ADR + PR description). Reviewed by `--scaffold` before build. Lands on main.

## Problem

An experiment that closes today is not on the researcher's dashboard until someone is separately asked to put
it there. #313 landed the design-time Presentation spec and the close-side `presentation_manifest.json`, but
deliberately stopped the product at the manifest: the publish leg — assemble transcript logs, render the
pinned plots, build the overview page, update the gallery, land the viewer PR — was left as consuming-instance
work, authored by the **designer-of-record at publish time**.

Field experience since says that leg rots exactly where it was left:

- **"Experiment done" ≠ "page live."** Every close still needs a manual designer pass before the page exists;
  the newest experiment of each program tends to be the one missing from the browser. The researcher's
  standing pain (2026-07-10, verbatim): *"once the experiment is done, it's not being put on the dashboard
  without a further ask."*
- **The page source never lands.** Hand-built pages accumulate as untracked files in a shared checkout: seven
  experiments' manifests + build/assemble scripts sat uncommitted until a backfill pass
  (research-lab PRs #184/#185, 2026-07-10) — one careless `git clean` from gone. Two of those experiments
  (`chat-student-pilot-1`, `chat-student-qwen-1`) have manifests but **no page source anywhere**: their pages
  cannot be iterated by any later agent.
- **The designer-authors-at-publish model contradicts the lifecycle's own economics.** Rendering agreed plots
  from agreed data is scripted work, not judgment; parking it on the designer serializes every close behind a
  human-attention-shaped queue for no validity gain.

## Approach

Three parts, matching issue #347. The through-line: move the judgment to design time (where the researcher
already clears the figures), make the close render mechanically from that cleared spec, and make the rendered
page's **source** part of the durable record.

**1. `design-experiment` Step 1 — the Presentation spec gets pinned render-ready.** The existing Presentation
bullet already asks, per headline figure/table, "what it plots and what that requires." Tighten it to
*concrete enough to render unattended*: each declared figure names its plot type, the arms/series on it, the
canonical metric and axes, and the per-cell data source — which artifact/field supplies each cell, at what
granularity (e.g. one transcript log per {arm × condition}, and which field is the score). Still **never what
it should show** — the no-verdict posture is unchanged; this is the same data-organization spec, one notch
more concrete, cleared in the SAME researcher conversation as today.

**2. `design-audit` — the existing PRESENTATION-DATA PERSISTENCE dimension also gates render-readiness.**
`audit_experiment.sh --design` dimension 8 today checks the collection plan *persists* every field the
Presentation section names. Extend the same dimension (no new gate): could a stranger render each declared
figure from the planned artifacts alone — type, arms, metric, axes, per-cell source all named? A Presentation
section too vague to render unattended is an execution-under-specification finding, same family the dimension
already catches. No Presentation subsection remains "no material finding," unchanged.

**3. `run-experiment` close — the executor builds + publishes, behind an instance seam, and commits the
source.** Replace the "publish leg is consuming-instance work, not this skill's" paragraph:

- **The seam:** `AAR_VIEWER_GUIDE` — an optional env var naming a path or URI to the instance's viewer
  publish guidance (where the viewer repo lives, the shared page-building library, assemble/bundle steps,
  gallery rebuild, and the gated landing path). Exact mirror of the `AAR_STYLE_GUIDE` seam (#317): unset →
  the close is manifest-only, today's behavior, a config-free no-op.
- **Set → publishing is part of the close, executor-owned:** assemble the per-cell transcripts, author the
  bespoke per-experiment builder against the cleared DESIGN.md Presentation spec (shared page lib + prior
  pages as the pattern — bespoke-not-template survives; only house style is shared), render the pinned plots,
  bundle, update the gallery, and land the viewer change through the instance's gated path.
- **Iterable source is a first-class requirement:** the close commits the per-experiment build/assemble
  scripts and manifest — not just rendered HTML — so any later agent iterates by editing a script and
  re-running. This is the difference between "the page got built once" and "the page stays maintainable"
  (the chat-student gap above is the counterexample).
- **`CHECKLIST_TEMPLATE.md` gains one UNIVERSAL gate** right after the manifest gate (the checklist is the
  forcing function, not prose): resolve the viewer publish leg per instance config — `AAR_VIEWER_GUIDE` set →
  page built + published from committed source (evidence: the landed viewer PR/commit, the committed script
  paths, the page URL); unset → resolved with that fact as evidence. Either way the gate resolves with
  evidence; it is never silently skipped.

**Kept OUT (deliberate, from the issue):**
- **The page prose stays a first-pass draft** the researcher polishes on the live page. The plain-language /
  no-verdict / mark-postdictions discipline is exactly what is easy to get wrong; automation produces a live
  first-pass page, never a finished story.
- **Post-close framing overrides stay cheap and expected.** The plot is pinned at design, but framing
  genuinely shifts on contact with the data (real case: a headline plot changed from difference-from-neutral
  to absolute-with-neutral after the researcher saw it). Committed source is what keeps that tweak a
  one-script edit.

## Alternatives considered

- **Status quo (designer authors at publish time).** Proven to rot: pages lag every close, source lands late
  or never (the #184/#185 backfill and the chat-student missing-source gap are the direct evidence).
- **A generic manifest→template page generator.** Rejected already in the existing SKILL.md text and the
  consuming instance's viewer docs: a template flattens the "tell this experiment's story" quality a
  hand-built page has. The executor authors a bespoke builder per experiment; sharing stays at the
  page-lib/house-style level.
- **Unconditional publish (no seam).** Breaks the product's instance-neutrality — an instance with no viewer
  has nothing to publish to. The manifest remains the unconditional part; publishing is conditional on the
  instance declaring a viewer.
- **Publish recipe spelled out in the product.** The viewer's layout, page lib, and landing path are instance
  property; hardcoding them violates the execution-profile seam discipline the skill already follows. Hence a
  pointer env var, same shape as `AAR_STYLE_GUIDE`.

## Blast radius

- **Product docs/templates only; no code paths.** `design-experiment/SKILL.md` (Presentation bullet),
  `run-experiment/SKILL.md` (close Step 5: the manifest bullet's neighborhood + the publish-leg paragraph),
  `design-experiment/templates/CHECKLIST_TEMPLATE.md` (one gate), and one dimension-text edit in
  `verify-claims/.../audit_experiment.sh`'s `--design` prompt (dimension 8).
- **Config surface:** one new optional env var (`AAR_VIEWER_GUIDE`); unset preserves today's behavior
  exactly, so existing instances and in-flight briefs are unaffected.
- **Instance work is out of scope for this PR:** writing the research-lab viewer guidance doc and exporting
  `AAR_VIEWER_GUIDE` into executor environments happens instance-side, after this lands.

## Rollout + rollback

- Inert until an instance sets `AAR_VIEWER_GUIDE`; first live test is the next dispatched close on an
  instance that sets it. Rollback: unset the env var (instant, per-instance) or revert the docs commit —
  no data or schema migration in either direction.
