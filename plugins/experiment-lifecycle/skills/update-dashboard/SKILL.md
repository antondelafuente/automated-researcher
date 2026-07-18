---
name: update-dashboard
description: >-
  Post-close edit loop for ONE experiment's operational DASHBOARD page (the `dashboard/` overview
  `run-experiment` builds automatically at close). Live-resolves `[recipes.viewer]` (no locked brief
  exists post-close), records the resolved recipe revision so a rebuild under a newer viewer recipe than
  close-time is visible, edits the bespoke per-experiment `build_<exp>_page.py` builder, rebuilds the page
  + gallery, verifies the served page actually renders (heading text present, no NaN in generated SVG),
  and lands the SOURCE change (builder + the dashboard's own manifest, never the registry record or
  generated `build/` output) via the `log-experiment` skill (`--skip-ignored`). The experiment registry
  record (`RESULTS.md`/`presentation_manifest.json`/`figures/*.csv`) is strictly READ-ONLY input here — this
  skill writes only inside the dashboard directory it lands. Refuses (BLOCK, points at `run-experiment`) unless the experiment is already CLOSED and
  a dashboard manifest/builder already exists — this is an EDIT loop, not the first-build path. **Routing
  (destination/artifact, not data scope — a cross-experiment comparison still belongs here if it's landing
  on the dashboard):** a per-experiment OPERATIONAL page in `dashboard/` → this skill; a cross-experiment
  EDITORIAL story page in `site/` → `update-site` instead. Use when asked to "update the dashboard," "add
  `<figure>` to `<exp>`'s dashboard page," "fix the experiment's page," or "compare experiments on the
  dashboard." Distinct from `run-experiment`'s own close-time build (automatic, one-shot, from the locked
  `DESIGN.md` Presentation spec) and from `update-site`'s researcher-driven editorial loop (a different
  surface, `site/`, with its own preview/publish recipes).
---

# Updating an experiment's dashboard page (the post-close edit loop)

`run-experiment`'s close-time publish leg builds a `dashboard/` overview page for an experiment
**automatically, once**, from the exact arms its cleared `DESIGN.md` Presentation spec named. This skill is
the **later** step: a researcher wants that page changed after close — a new figure, a fixed caption, a
comparison against a sibling experiment added to the same page — and there is no locked brief left to
re-run. It is **not** `run-experiment`'s close leg (that only ever runs once, unattended, at close), and it
is **not** `update-site` (that skill owns the separate cross-experiment editorial `site/` surface, with its
own preview-claim lifecycle and explicit publish gate — a genuinely different destination).

## Terminology + routing (read this first — the two surfaces are easy to confuse)

- **`dashboard/`** = the per-experiment **operational** browser this skill edits: one overview page per
  experiment, first built automatically at close, edited afterward here.
- **`site/`** = the cross-experiment **editorial** story pages `update-site` owns: researcher-driven
  narrative, explicit publish gate, its own preview/publish recipes.
- **Routing is by DESTINATION/ARTIFACT, not by how many experiments the page covers.** A "compare
  experiments" request still lands here if the destination is the dashboard (destination wins over
  cross-experiment scope). Trigger-phrase examples:
  - "update the dashboard" / "add `<figure>` to `<exp>`'s dashboard page" / "fix the experiment's page" /
    "compare experiments on the dashboard" → **this skill**.
  - "make a story page about X" / "update the site" / "publish the visualization" / "make a story about one
    experiment" → **`update-site`** instead.

## The one seam this skill reads: `[recipes.viewer]`, resolved LIVE

Unlike `run-experiment` — which reads only the frozen `[recipes.viewer]` snapshot in its `START.md` brief,
per the aar-profile schema's executor-reads-only-the-snapshot rule — this skill has no locked brief to read:
it is invoked live, ad hoc, arbitrarily long after close. So it resolves the instance's **live** profile
itself, the same live-resolving role `design-experiment` and `update-site` already play (see the aar-profile
`SCHEMA.md`'s "who resolves live vs who reads the snapshot"). It reads `[recipes.viewer]` only — the
existing recipe key `run-experiment`'s close leg already uses, no new recipe pointer, and it never reads
`[recipes.visualization_preview]`/`[recipes.visualization_publish]` (those are `update-site`'s own, for the
unrelated `site/` destination).

Run `scripts/resolve_viewer_recipe.sh` (no flags). It resolves `[recipes.viewer]` from the instance's
aar-profile and prints its fields (`VIEWER_KIND`, and for `kind=repo`: `VIEWER_REPO`/`VIEWER_PATH`/
`VIEWER_GIT_REF`; for `kind=uri`: `VIEWER_URI`/`VIEWER_SHA256`), or **BLOCKs** with a clear message (no
profile found; `[recipes.viewer]` isn't configured; a required field is missing for its kind) — never a
guessed repo, host, or worktree path. **A BLOCK here is a real stop**: report it to the researcher; do not
improvise a dashboard location. An unconfigured `[recipes.viewer]` means the instance is manifest-only (see
`run-experiment`'s publish leg) — there is no dashboard to edit, so this skill has nothing to do.

**Record the resolved revision in the diff itself — don't let a newer recipe rebuild silently.** The
printed `VIEWER_GIT_REF`/`VIEWER_SHA256` is the recipe **revision** live right now. `log-experiment`
hard-codes its commit/PR messages by design (see Step 4) — this skill never touches that — so the revision
is recorded a different way: maintain a header comment line at the top of the edited `build_<exp>_page.py`,

```
# viewer-recipe-rev: <git_ref or sha> (<ISO date>)
```

updated to the live-resolved revision and today's date on every edit pass (Step 3). That satisfies the
visibility contract without new landing machinery: the revision travels with the landed source and its
blame history, so a rebuild under a viewer recipe that has moved on since the experiment's original close is
a visible fact, never a silent divergence. Compare the resolved revision against the experiment's own
`START.md` `[recipes.viewer]` snapshot (from its original close, if the experiment went through
`design-experiment`/`run-experiment`) for your own situational awareness while editing; no `START.md` to
compare against (a pre-`design-experiment` record, or one predating the snapshot helper) is not a BLOCK —
just write the live revision into the header line regardless.

## Preconditions — refuse if this looks like a first build, not an edit (guards against overlap with `run-experiment`'s close leg)

Before doing anything, confirm BOTH:
1. **The experiment is CLOSED** (`RESULTS.md` exists in its registry dir).
2. **A dashboard manifest/builder already exists** for it — at minimum, `presentation_manifest.json` next to
   `RESULTS.md`, and a bespoke `build_<exp>_page.py` already committed in the viewer repo (per the recipe's
   "where per-experiment page source lives" field).

Either missing → **BLOCK and point at `run-experiment`**: an experiment that hasn't closed, or one whose
close never got a viewer page (a manifest-only instance, or a brief with no `[recipes.viewer]` at close
time), needs the close-time leg to run first (or the instance to configure `[recipes.viewer]`) — this skill
never improvises a first build, only edits one that already exists.

## Step 1 — Resolve the record

Same discipline as any visualization pass: **prefer `presentation_manifest.json`** (title, arm/label lookup,
headline figures, datasets) as the starting point over re-deriving structure from raw artifacts; verify any
artifact you're about to reference in the edit actually exists at the path you cite.

**Scope: the registry record is READ-ONLY input.** `RESULTS.md`, `presentation_manifest.json`, and
`figures/*.csv` — and every other artifact in the experiment's registry dir — are read-only input to this
skill: resolve titles, labels, headline figures, and datasets from them, but never edit them. This skill's
only writable surface is inside the dashboard directory it lands: the per-experiment builder
(`build_<exp>_page.py`) and the dashboard's own manifest (e.g. `manifests/<exp>.json`, if the recipe's
viewer layout keeps one alongside the builder). **A desired change to the registry record itself is out of
scope here — that is a separate `log-experiment` invocation on the registry experiment dir.**

## Step 2 — Read the viewer recipe doc

The resolved fields (`VIEWER_REPO`/`VIEWER_PATH` for `kind=repo`, `VIEWER_URI` for `kind=uri`) locate the
recipe **document itself** — never the dashboard. **Never use those pointer fields as a landing target.**
Read the resolved document's own body — entirely instance-owned narrative — to obtain the actual dashboard:
it names, at minimum (same four things `run-experiment`'s close leg requires of it):
1. **the dashboard's own viewer repo and its gated landing path (subdirectory)** — distinct from
   `VIEWER_REPO`/`VIEWER_PATH` above, which only locate this document and may live in an entirely different
   repo/path from the dashboard;
2. the shared page-building library and at least one committed prior page as the pattern;
3. the assemble → render → bundle → gallery-rebuild commands (or worked examples) — **and the interpreter**
   they run under;
4. where per-experiment page source (`build_<exp>_page.py`) lives in the viewer repo.

A resolved recipe missing any of these — including a doc that never states a landing repo/directory — is a
**named BLOCK** ("recipe doc does not name <which field>"); report it. Do not improvise a build/
interpreter/gallery command it didn't specify, and never fall back to `VIEWER_REPO`/`VIEWER_PATH` as a
landing repo/directory when the doc's body omits one.

## Step 3 — Edit the bespoke builder, rebuild, verify

- **Edit `build_<exp>_page.py`** — builders are per-page **by design** (no generic manifest-to-template
  generator; a template flattens the "tell this experiment's story" quality, same posture as `run-experiment`'s
  close leg and `update-site`). Missing the builder at the path the recipe names is a **named BLOCK**
  ("builder script not found at <path>") — this skill edits an existing builder, it does not scaffold one
  from scratch (that gap belongs to `run-experiment`'s close leg or a first-build follow-up, not here). Add
  or update the `# viewer-recipe-rev: <git_ref or sha> (<ISO date>)` header comment line to the live-resolved
  revision from Step 2 as part of this edit — see "Record the resolved revision" above; this is the
  revision-tracking mechanism, not a commit/PR message.
- **Rebuild the page + gallery** with the recipe's own commands, under the recipe's named interpreter.
  Missing/unresolvable interpreter is a **named BLOCK** ("interpreter <name> not found") — never fall back
  to whatever `python`/`node`/etc. happens to be on `PATH`.
- **Verify the served page actually renders** — this is a real gate, not a formality:
  - Fetch the page URL the recipe names and assert the **new section's heading text** you just added is
    present in the response body.
  - Assert **no `NaN`** appears in the generated SVG output (a `NaN` in an SVG path/attribute renders as a
    silently broken or missing mark — this is the same class of "looks done but isn't" bug the close leg's
    gallery-rebuild-is-a-verified-gate rule guards against).
  - A missing served page (fetch fails, 404, connection refused) is a **named BLOCK** ("served page did not
    respond at <url>") — never report success on an unverified page.

## Step 4 — Land the source change

Land **only the dashboard-directory source** — the edited `build_<exp>_page.py` and the dashboard's own
manifest (if the recipe's viewer layout keeps one, e.g. `manifests/<exp>.json`) — never the generated
`build/` output (stays uncommitted per the dashboard repo's own `.gitignore`), and never the registry's
`presentation_manifest.json`: that file lives in the experiment's registry dir, is read-only input (Step
1), and never travels in this landing. A desired change to it is a separate `log-experiment` invocation on
the registry experiment dir, not part of this skill's scope.

**Invoke the `log-experiment` skill; let it resolve its own script** — never hardcode a path to another
plugin's scripts (installs are version-pinned; the companion skill is the stable interface, the same
convention `design-experiment`'s SKILL.md states for its own `verify-claims` dependency). Concretely: **invoke
the `log-experiment` skill on the dashboard subdirectory (with `--skip-ignored`), from the research-repo
checkout** — cwd/checkout is a checkout of the dashboard's own repo, the repo the recipe **doc's body** names
(Step 2, item 1), never `VIEWER_REPO` (that field only locates the recipe document itself, and may point at
an entirely different repo); the argument you pass it is that repo's own gated landing **subdirectory**,
never a repo root. Resolve both the repo and the subdirectory from the recipe doc's body, then pass the
subdirectory relative to the checkout root as the skill's registry-dir argument, plus `--skip-ignored`.

`log-experiment` computes the branch name from the input directory's path *relative to the checkout root*;
passed the checkout root itself, that relative path is `.`, which is not a valid branch component.
**Require the resolved path to be a real subdirectory (relative path != `.`)** before invoking the skill. If
the recipe resolves the dashboard to the repo root itself — an instance whose dashboard IS its own repository
root — that is a **recipe/instance-config gap, not something this skill improvises around**: emit a named
BLOCK ("viewer recipe's landing path is the repo root, not a subdirectory — land this manually, or fix the
recipe to name a subdirectory") and stop; never invent a branch name or restructure the checkout to force a
subdirectory.

This is the **note** path — the dashboard subdirectory carries no `DESIGN.md`/`RESULTS.md`, so `log-experiment`
classifies it as a note (deterministic secret scan only, no audit gate). `--skip-ignored` acknowledges the
dashboard's own intentional gitignored caches (`data_cache`/`build/`-style exclusions) — it does **not**
bypass `log-experiment`'s committed-claim check, so a doc that still claims an excluded file "is committed"
still BLOCKs regardless. The committed diff must be builder source + the dashboard's own manifest only
(never the registry's `presentation_manifest.json` — out of scope per Step 1); generated `build/` output
stays out per the dashboard repo's own ignore rules. If the dashboard's repo (as the recipe doc's body names
it) differs from the instance's default research repo (a genuinely separate viewer repo, the common case for
a dashboard), set `RESEARCH_REPO` to that doc-named repo — never to `VIEWER_REPO`, which only locates the
recipe document and may live in a wholly different repo from the dashboard itself — before invoking the
skill; its own `origin`-must-match-`RESEARCH_REPO` gate otherwise fails closed against the wrong repo.

## Failure behavior — named BLOCKs only, never improvisation

Every gap above is a **named** BLOCK (which precondition/field/file/interpreter/page was missing), reported
to the researcher — this skill never guesses a manifest, scaffolds a builder from scratch, invents a build
command, or reports an unverified page as done.

## Reference

- **`scripts/resolve_viewer_recipe.sh`** — the live `[recipes.viewer]` resolver (fail-closed; prints the
  recipe revision).
- **`references/SCHEMA.md`** — why this skill reads `[recipes.viewer]` (the existing key, not a new one),
  and how it differs from `run-experiment`'s frozen-snapshot read of the same key.
- **`run-experiment`**'s publish leg — the close-time FIRST build this skill's precondition defers to; read
  it for the shape of the from-scratch build (assemble → render → bundle → gallery-rebuild) this skill's
  Step 3 reuses via the same recipe-doc pattern.
- **`update-site`** — the sibling skill for the OTHER surface: the cross-experiment editorial `site/`
  pages. Route there instead when the destination is the site, not the dashboard.
- **`log-experiment`** — lands this skill's source change as a gated PR (the note path).
