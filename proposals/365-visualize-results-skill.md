# Proposal: Add a local-first `visualize-results` skill (#365)

> The canonical design doc (ADR + PR description). Reviewed by `--scaffold` before build. Lands on main.

## Problem

After an experiment or meeting, a researcher should be able to say "visualize this" and have a fresh agent
enter a local-first presentation workflow without knowing viewer repos, worktrees, ports, or deployment
mechanics. Today `run-experiment`'s close-time publish leg (#347) can build and land an experiment's overview
page automatically when the frozen `START.md` snapshot carries a `[recipes.viewer]` pointer — but that leg is
narrow by design: it runs once, unattended, at close, against exactly the arms `DESIGN.md`'s Presentation spec
named. There is no standalone skill for the *later*, researcher-driven, editorial loop — iterating on a page's
story after a human has looked at the data, adding a result to an existing gallery page, or building a page for
something that was never a locked experiment brief at all (a meeting readout, an ad hoc plot). Agents asked to
do this today improvise: they invent preview servers, guess at "the" viewer repo, or conflate a local draft
with a production deploy.

## Approach

Add a concise `visualize-results` skill to the `experiment-lifecycle` plugin, installed as a fourth
independently-installable skill (same distribution as `design-experiment` / `run-experiment` / `log-experiment` —
one bundled Claude plugin, individually symlinked skill dirs for Codex per the README).

**Disposition: local-first by default, live-resolving (not a locked-brief executor).** Unlike `run-experiment`,
this skill is not consuming a frozen brief — it's invoked ad hoc, live, with the researcher steering ("visualize
this", "add this to the visualizations", "iterate on this page"), on records that may be days old or may never
have had a `START.md` at all. So it resolves the **live** instance profile itself, the same role
`design-experiment` already plays per the aar-profile SCHEMA's role split ("who resolves live vs who reads the
snapshot") — it is a second live-resolving role, not a violation of the executor-reads-only-snapshot rule (that
rule binds `run-experiment` specifically, because *that* skill's whole contract is reproducibility from a frozen
record).

**The loop:**
1. **Resolve the record.** Given a pointer to an experiment/registry dir or a researcher's description, locate
   the relevant `RESULTS.md` + verified artifacts. Prefer `presentation_manifest.json` when present (the
   unconditional, config-free manifest every experiment close already writes, #313/#316) — it already names the
   title, labels, figures, and datasets worth surfacing, so a manifest-carrying record needs no re-derivation.
2. **Resolve the recipe(s) — fail closed, don't improvise.** Two DISTINCT, independently-typed profile pointers,
   both the existing generic `[recipes.<name>]` shape (`kind="repo"|"uri"` + the kind-appropriate fields) — no new
   pointer grammar:
   - **`[recipes.visualization_preview]`** (new, OPTIONAL) — the *local iteration* recipe: preview claim commands
     (status/use/release), the stable per-page local worktree + URL convention, and the shared page-style pattern.
     Always required for this skill to do anything; absent or incomplete (missing a required field for its kind)
     is **BLOCKED** with a clear message before any preview work starts.
   - **`[recipes.viewer]`** (existing, already read by `run-experiment`'s close-time publish leg, #347) — the
     *publish destination*: the viewer repo, its gated landing path, the assemble/render/bundle/gallery commands.
     Reused as-is, unchanged shape and unchanged field semantics — `visualize-results` does not add a second
     publish destination, it reads the SAME pointer `run-experiment` already reads, because both legs land pages
     in the identical destination; only *when* and *how often* each leg runs differs.
   A tiny resolver script (`resolve_visualization_recipe.sh`) does the parse + validation offline (mirrors
   `log-experiment.sh`'s existing `read_profile_field` bridge, generalized to a recipe table); it is the thing the
   fake-HOME smoke exercises deterministically.
3. **Enter local iteration (the default, no flag needed).** Resolving `[recipes.visualization_preview]` is enough
   to start — `[recipes.viewer]` is never even looked up on this path. The preview recipe doc is 100%
   instance-owned narrative; this skill does not reimplement or know about claim files, worktree paths, ports, or
   URL shapes. It names, at minimum: the preview claim commands (status/use/release), the stable per-page local
   worktree + URL convention, and the shared page-style pattern (a page lib + a prior page, same "bespoke, not a
   generic template" posture as the run-experiment publish leg). The skill's job is to follow that doc: claim (or
   report the current owner/branch and stop rather than clobber a dirty claim), create or edit the page + gallery
   entry, run the recipe's prescribed build + browser checks, and return the stable preview URL. Continue
   iterating here — no review, no production deploy — until told otherwise.
4. **Publish only on explicit instruction.** Only an explicit "publish" or "ship" instruction makes the skill
   *also* resolve `[recipes.viewer]` and follow its gated landing path (reusing the instance's existing
   engineer-identity seams — no new credential surface), then release the preview claim afterward. The boundary
   is mechanically real, not just prose discipline: `resolve_visualization_recipe.sh`'s default (preview-mode)
   invocation resolves ONLY `[recipes.visualization_preview]` — it does not parse, require, or emit anything from
   `[recipes.viewer]` at all; only an explicit `--publish` flag makes it additionally resolve `[recipes.viewer]`
   and emit its fields. Because the two recipes are genuinely separate, independently-typed profile entries (not
   one doc with a filtered view), a caller literally cannot obtain the publish/landing-path fields without asking
   for them by name — the fake-HOME smoke exercises exactly this.

**Schema addition — additive, no version bump, nothing about `[recipes.viewer]` changes.**
`[recipes.visualization_preview]` is a new, OPTIONAL entry using the aar-profile schema's existing generic
`[recipes.<name>]` pointer mechanism (documented already as an open set: "provisioning, artifact_store, ledger,
teardown, cost_policy, viewer, ..."). Adding a new *name* to that open set is backward-compatible per the
schema's own versioning rule (an optional addition needs no MAJOR bump). The two byte-identical aar-profile
`SCHEMA.md` copies (`design-experiment/references/`, `run-experiment/references/`) get: (a) one short paragraph
naming `visualization_preview` as a distinct key from `viewer` — different trigger (explicit researcher request
vs. automatic at experiment close), different lifecycle (repeatable local iteration vs. one-shot), same
typed/pinned shape, publish destination shared via the *existing* `viewer` key rather than duplicated; and (b) an
explicit amendment to the "who resolves live vs who reads the snapshot" role-split section naming
`visualize-results` as a second, narrowly-scoped live reader — live-resolving `[recipes.visualization_preview]`
and, on explicit publish, `[recipes.viewer]` — alongside `design-experiment` and `aar-profile-init`/`-validate`,
with the same rationale already given for `design-experiment` (this is live, repeatable, researcher-steered work
with no locked brief to snapshot into, not the reproducibility-from-a-frozen-record contract `run-experiment`
alone must uphold). `run-experiment`'s close-time publish leg is completely untouched: no field it reads is
renamed, retyped, or reinterpreted, and this skill never writes to the profile.

**Product boundary — no instance values in product code.** Both recipe pointers carry only a `repo`/`path`/
`git_ref` (or `uri`/`sha256`); the product never hardcodes a viewer repo, hostname, port, or Cloudflare value —
those live only in the instance's own profile + the recipe docs they point at (out of scope for this issue, per
the issue's own scope boundary — the consuming `research-lab` preview helper/wiring lands separately).

**Fake-HOME behavioral coverage** (`visualize_results_smoke.sh`, hooked into `.aar-ci/checks.sh` alongside the
other per-skill smokes):
- Skill discovery — already covered by the generic `fake_home_smoke.sh` install/discover pass (frontmatter
  `name:`/`description:` present) once `visualize-results/SKILL.md` exists; no new code needed for this leg. (The
  skill's own `references/SCHEMA.md` is a small, self-contained doc scoped to the two recipe pointers this skill
  reads — it is NOT a third copy of the full aar-profile schema, so it adds no third leg to the existing
  design-experiment/run-experiment byte-identical-copy check; that check's scope is unchanged.)
- Complete-recipe resolution — a fake profile with a fully-specified `[recipes.visualization_preview]`
  (`kind="repo"` + `repo`/`path`/`git_ref` all set) resolves cleanly.
- Missing/incomplete-recipe failure — no profile, a profile with no `[recipes.visualization_preview]` table, and
  a table missing a kind-required field (e.g. `kind="repo"` without `git_ref`) each BLOCK with a clear message.
- Explicit publish boundary — a default (no `--publish`) resolve on a complete recipe returns only preview
  fields (no gated-landing-path fields); `--publish` returns the publish fields too.
- Hardcoded-instance-path absence — a static grep over the skill's own shipped files (`SKILL.md`, `references/`,
  `scripts/`) asserts none of `research-lab`, `/home/anton`, a literal hostname/port pattern, or `cloudflare`
  appear (the same class of check `checks.sh` already runs elsewhere, scoped to this skill's own source so a
  future edit can't quietly reintroduce an instance leak here).

**Version bump.** `plugins/experiment-lifecycle/.claude-plugin/plugin.json` 0.3.27 → 0.3.28 (new skill added to
the bundle).

## Alternatives considered

- **Fold this into `run-experiment`'s existing publish leg** (a "re-open and iterate" mode on the same
  `[recipes.viewer]` pointer). Rejected: that leg's whole contract is a locked, one-shot, close-time build from a
  frozen `START.md` snapshot; overloading it with a live, repeatable, researcher-steered loop (and a second,
  live-resolving profile read) would blur a currently-clean distinction the issue explicitly asks to preserve
  ("avoid duplicating or silently changing that close-time contract").
- **Use `[recipes.viewer]` alone for everything** (no new key). Rejected: `[recipes.viewer]`'s documented shape is
  specifically the *publish* contract (viewer repo, gated landing path, assemble/render/bundle/gallery commands)
  — it says nothing about a *local preview* lifecycle (claim/use/release, a stable local worktree, a local URL).
  Overloading it would either bloat one recipe doc with two unrelated concerns or require `run-experiment` (which
  has no notion of "claim a preview") to grow fields it never uses. A second, narrowly-scoped key for the
  genuinely new concern (local iteration) is more concise than stretching the existing one — while the *publish*
  half deliberately reuses `[recipes.viewer]` unchanged rather than inventing a third pointer for it (see Approach).
- **Duplicate `[recipes.viewer]`'s publish fields into a `visualization_preview`-owned publish section** instead
  of reusing the existing key. Rejected: this is exactly the duplication the issue asks to avoid — two
  independently-configured pointers to the same destination would drift the moment an instance updates one and
  not the other. Reusing the identical, already-battle-tested `[recipes.viewer]` pointer for the publish half
  keeps there being exactly one gated-landing-path config fact per instance.
- **A generic manifest-to-template page generator** instead of following the recipe's page-style pattern.
  Rejected for the same reason `run-experiment`'s publish leg rejected it (#347): a template flattens the
  "tell this experiment's story" quality; the recipe's job is to name the shared library + a prior page as
  pattern, not hand the skill a generator.

## Blast radius

- New: `plugins/experiment-lifecycle/skills/visualize-results/{SKILL.md,references/SCHEMA.md,scripts/resolve_visualization_recipe.sh,scripts/visualize_results_smoke.sh}`.
- Edited: `plugins/experiment-lifecycle/skills/{design-experiment,run-experiment}/references/SCHEMA.md` (additive
  paragraphs, kept byte-identical to each other as the existing check requires) + the normative field table's
  recipe-name list + the live-reader role-split amendment (Approach, above).
- Edited: `plugins/experiment-lifecycle/.claude-plugin/plugin.json` (version bump + description updated from
  "three skills" to name all four, so installed-product discovery metadata stays current).
- Edited: `.claude-plugin/marketplace.json` (same description update, same reason — Finding 5).
- Edited: `.aar-ci/checks.sh` (hook the new smoke, same pattern as the other per-skill smokes).
- Edited: `README.md` (add the Codex symlink line for the new skill, matching the existing per-skill list).
- Does **not** touch `research-lab` or any `/home/anton` instance wiring — out of scope per the issue, lands
  separately through the instance's own repository/config path.

## Rollout + rollback

Additive only: a new optional skill, a new optional recipe key, no renamed/removed fields on the existing
`[recipes.viewer]` key this skill reuses, no behavior change to existing skills' code paths (only prose/table
additions to the shared `SCHEMA.md`). An instance that never configures `[recipes.visualization_preview]` sees no
behavior change at all — the skill installs and discovers, and simply reports BLOCKED with a clear message if
invoked before that recipe is configured. Because the publish half reuses the *existing* `[recipes.viewer]` key
rather than introducing a second destination pointer, there is no new instance-side config to orphan on revert
beyond the one new, purely-additive `visualization_preview` key itself — an instance that had configured it would
simply have an inert, ignored key after a revert (no dangling reference, no broken downstream consumer). Revert
is a plain `git revert` of the merge commit; nothing downstream depends on this skill existing yet.
