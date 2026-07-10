---
name: visualize-results
description: >-
  Enter a LOCAL-FIRST visualization/presentation loop for a finished experiment or note — resolve the
  record + verified artifacts (preferring presentation_manifest.json when present), enter the instance's
  configured visualization-preview recipe, create or iterate on the page + gallery entry, run its
  prescribed build/browser checks, and return the stable preview URL. Keep iterating locally — no review,
  no production deploy — until the researcher gives an EXPLICIT "publish" or "ship" instruction, which
  alone transitions to the gated landing path and releases the preview claim. Use when asked to "visualize
  this," "make plots for these results," "add this to the visualizations," "iterate on this page," or
  "publish/ship the visualization." Distinct from `run-experiment`'s own close-time viewer publish leg
  (#347), which is automatic/one-shot from a locked brief; this is the later, repeatable, researcher-driven
  pass, live-resolving the instance recipe rather than reading a frozen snapshot.
---

# Visualizing results (the researcher-driven editorial loop)

This is the **later** visualization step: a researcher looked at a finished experiment (or a note, a
meeting readout, an ad hoc plot) and wants a page for it, or wants to keep shaping a page's story. It is
**not** `run-experiment`'s close-time publish leg — that leg builds and lands a page unattended, once, from
the exact arms `DESIGN.md`'s Presentation spec named, as part of closing out a locked brief. This skill runs
whenever the researcher asks, as many times as they ask, and defaults to **local iteration** — nothing ships
anywhere until they explicitly say so.

> **The one seam this skill reads:** the instance's **visualization-preview recipe** (`[recipes.visualization_preview]`
> in the instance's aar-profile) plus, only on explicit publish, its existing **viewer** recipe
> (`[recipes.viewer]` — the same pointer `run-experiment`'s publish leg already reads). See
> `references/SCHEMA.md`. This skill never hardcodes a viewer repo, worktree, or any instance networking/tunnel
> detail — those live only in the instance's own profile + the recipe docs it points at.

## Disposition — live-resolving, not a locked-brief executor

Unlike `run-experiment`, this skill has no `START.md` snapshot to read: it's invoked live, ad hoc, on
records that may be days old or may never have gone through `design-experiment` at all. So it resolves the
instance's **live** profile itself — the same live-resolving role `design-experiment` already plays (see the
aar-profile `SCHEMA.md`'s "who resolves live vs who reads the snapshot"). That rule's "the executor reads
only the frozen snapshot" clause binds `run-experiment` specifically, because that skill's whole contract is
reproducing a *locked* run from a *frozen* record; this skill has no such record to freeze from.

## Step 1 — Resolve the record

Given a pointer to a registry/experiment dir, or the researcher's description of what to visualize:
- **Prefer `presentation_manifest.json`** when present next to `RESULTS.md` — every experiment close already
  writes one (unconditionally, config-free); it already names the title, the arm/label lookup, the headline
  figures, and the datasets worth surfacing. Use it as the starting point rather than re-deriving structure
  from raw artifacts.
- No manifest (a note, a pre-manifest record, or something that was never an experiment) → read `RESULTS.md`
  / the artifacts directly and use judgment; still follow the plain-language, no-verdict, mark-postdictions
  discipline the manifest itself follows.
- Verify artifacts you cite actually exist at the path you're about to reference — don't build a page around
  a figure that was never rendered.

## Step 2 — Resolve the visualization-preview recipe — fail closed, never improvise

Run `scripts/resolve_visualization_recipe.sh` (no flags, the default = preview mode). It resolves ONLY
`[recipes.visualization_preview]` from the instance's aar-profile and prints its fields, or **BLOCKs** with a
clear message (no profile found; the recipe isn't configured; a required field is missing for its kind) —
never a guessed port, hostname, or worktree path. **A BLOCK here is a real stop**: report it to the
researcher rather than improvising a preview server or a scratch directory. This absence is expected on an
instance that hasn't wired visualization yet (out of scope for this skill — that wiring is the consuming
instance's own config + recipe-doc work).

The resolved fields point at a recipe **document** (repo + path + pinned commit, or a pinned URI) that is
entirely instance/viewer-owned narrative. Read it; it names, at minimum:
- the preview **claim lifecycle** — status / use / release commands, and how to tell if another agent
  already owns the preview;
- the **stable local worktree** convention for this preview and the **stable local URL** it serves at;
- the **page-style pattern** — the shared page-building library and at least one committed prior page to
  follow as pattern (bespoke per page, not a generic manifest-to-template generator — the same posture
  `run-experiment`'s publish leg takes: a template flattens the "tell this experiment's story" quality).

## Step 3 — Claim, build, iterate locally (the default — no flag, no instruction needed)

Follow the recipe doc's own claim/build/check mechanics (this skill does not reimplement them):
- **Check ownership first.** If another agent's claim is active per the recipe's `status`, **report the
  owner/branch to the researcher and stop** — do not clobber a dirty claim.
- Otherwise **claim** the preview, then create or edit the page + its gallery entry per the recipe's
  page-style pattern, using the record resolved in Step 1.
- Run the recipe's **prescribed build and browser checks** — don't skip this because the diff "looks right";
  a page that doesn't render is not done.
- **Return the stable preview URL** to the researcher.
- **Keep iterating here.** No code review, no production deploy, at this stage — the researcher looks at the
  live preview and asks for changes; repeat Step 3 as many times as asked. The page prose at this stage is a
  first-pass draft the researcher polishes on the live page, same discipline as the close-time leg.

## Step 4 — Publish only on an EXPLICIT instruction

Only when the researcher explicitly says **"publish"** or **"ship"** this page (never inferred from "looks
good" or silence):
1. Re-run the resolver with `--publish`: `scripts/resolve_visualization_recipe.sh --publish`. This
   *additionally* resolves `[recipes.viewer]` — the **same** publish-destination pointer `run-experiment`'s
   close-time leg already reads (the viewer repo, its gated landing path, the assemble/render/bundle/gallery
   commands). If that recipe isn't configured, this BLOCKs even though preview-mode already worked — report
   it; do not fall back to guessing a landing path.
2. Follow the viewer recipe's gated landing path to land the change (reusing the instance's existing
   engineer-identity seams — no new credential surface this skill invents).
3. **Release the preview claim** once landed, so the next agent isn't blocked on a stale claim.

If another agent's claim is still active when publish is requested, resolve that the same way Step 3 does —
report it, don't clobber it — before proceeding.

## Reference

- **`references/SCHEMA.md`** — the two recipe pointers this skill reads (`visualization_preview`, reused
  `viewer`), their required fields, and how the explicit-publish boundary is enforced mechanically at the
  resolver, not just in prose.
- **`scripts/resolve_visualization_recipe.sh`** — the recipe resolver (preview mode default; `--publish` for
  the explicit publish leg).
- **`run-experiment`**'s publish leg — the sibling, automatic, close-time leg this skill is deliberately
  distinct from; read it if you need the shape of a from-scratch page build (assemble → render → bundle →
  gallery-rebuild), which this skill's Step 3/4 reuse via the same recipe-doc pattern rather than duplicating.
