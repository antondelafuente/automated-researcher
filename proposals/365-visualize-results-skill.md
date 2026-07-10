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
2. **Resolve the recipe — fail closed, don't improvise.** Read the instance profile's new, OPTIONAL
   `[recipes.visualization_preview]` typed pointer (same `kind="repo"|"uri"` shape every other recipe already
   uses — no new pointer grammar). Absent, or present but missing a required field for its kind, is a **BLOCKED**
   with a clear message — never a guessed port/hostname/worktree. A tiny resolver script
   (`resolve_visualization_recipe.sh`) does the parse + validation offline (mirrors `log-experiment.sh`'s
   existing `read_profile_field` bridge, generalized to a recipe table); it is the thing the fake-HOME smoke can
   exercise deterministically.
3. **Enter local iteration (the default, no flag needed).** The recipe doc it resolves to is 100% instance/
   viewer-owned narrative — this skill does not reimplement or know about claim files, worktree paths, ports, or
   URL shapes. It names, at minimum: the preview claim commands (status/use/release), the stable per-page local
   worktree + URL convention, and the shared page-style pattern (a page lib + a prior page, same "bespoke, not a
   generic template" posture as the run-experiment publish leg). The skill's job is to follow that doc: claim (or
   report the current owner/branch and stop rather than clobber a dirty claim), create or edit the page + gallery
   entry, run the recipe's prescribed build + browser checks, and return the stable preview URL. Continue
   iterating here — no review, no production deploy — until told otherwise.
4. **Publish only on explicit instruction.** Only an explicit "publish" or "ship" instruction transitions to the
   configured **gated landing path** (the same recipe doc's publish/PR section — reusing the instance's existing
   engineer-identity seams, no new credential surface) and releases the preview claim afterward. The mechanical
   boundary is enforced at the resolver, not just in prose: `resolve_visualization_recipe.sh` only emits the
   gated-landing-path fields when called with an explicit `--publish` flag; a default (preview-mode) call
   resolves only the preview-mechanics fields. This gives the "explicit publish boundary" acceptance criterion a
   deterministic, fake-HOME-testable mechanism instead of relying solely on the agent reading prose correctly.

**Schema addition — additive, no version bump.** `[recipes.visualization_preview]` is a new, OPTIONAL entry
using the aar-profile schema's existing generic `[recipes.<name>]` pointer mechanism (documented already as an
open set: "provisioning, artifact_store, ledger, teardown, cost_policy, viewer, ..."). Adding a new *name* to
that open set is backward-compatible per the schema's own versioning rule (adding an optional field needs no
MAJOR bump); the two byte-identical `aar-profile` `SCHEMA.md` copies (`design-experiment/references/`,
`run-experiment/references/`) get one short paragraph each, mirroring the existing `[recipes.viewer]` paragraph,
naming this as a **distinct** key from `viewer` — different trigger (explicit researcher request vs. automatic
at experiment close), different lifecycle (repeatable local iteration vs. one-shot), same typed/pinned shape.
`run-experiment`'s close-time publish leg is untouched: no field it reads is renamed or reinterpreted.

**Product boundary — no instance values in product code.** The recipe pointer carries a `repo`/`path`/`git_ref`
(or `uri`/`sha256`); the product never hardcodes a viewer repo, hostname, port, or Cloudflare value — those live
only in the instance's own profile + the recipe doc it points at (out of scope for this issue, per the issue's
own scope boundary — the consuming `research-lab` preview helper/wiring lands separately).

**Fake-HOME behavioral coverage** (`visualize_results_smoke.sh`, hooked into `.aar-ci/checks.sh` alongside the
other per-skill smokes):
- Skill discovery — already covered by the generic `fake_home_smoke.sh` install/discover pass (frontmatter
  `name:`/`description:` present) once `visualize-results/SKILL.md` exists; no new code needed for this leg.
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
- **Reuse `[recipes.viewer]` itself for the new skill** instead of adding `[recipes.visualization_preview]`.
  Rejected as the default: an instance may well point both keys at doc sections in the *same* viewer repo, but
  giving `visualize-results` its own key keeps it independently installable/discoverable (Codex symlinks this
  skill alone) without requiring a reader to already understand `run-experiment`'s recipe to use this skill, and
  keeps the "distinct, not duplicated" requirement structurally true rather than just true-by-convention. Happy
  to have the exact key name / shape challenged in review.
- **A generic manifest-to-template page generator** instead of following the recipe's page-style pattern.
  Rejected for the same reason `run-experiment`'s publish leg rejected it (#347): a template flattens the
  "tell this experiment's story" quality; the recipe's job is to name the shared library + a prior page as
  pattern, not hand the skill a generator.

## Blast radius

- New: `plugins/experiment-lifecycle/skills/visualize-results/{SKILL.md,references/SCHEMA.md,scripts/resolve_visualization_recipe.sh,scripts/visualize_results_smoke.sh}`.
- Edited: `plugins/experiment-lifecycle/skills/{design-experiment,run-experiment}/references/SCHEMA.md` (one
  additive paragraph each, byte-identical to each other as the existing check requires) + the normative field
  table's recipe-name list.
- Edited: `plugins/experiment-lifecycle/.claude-plugin/plugin.json` (version bump).
- Edited: `.aar-ci/checks.sh` (hook the new smoke, same pattern as the other per-skill smokes).
- Edited: `README.md` (add the Codex symlink line for the new skill, matching the existing per-skill list).
- Does **not** touch `research-lab` or any `/home/anton` instance wiring — out of scope per the issue, lands
  separately through the instance's own repository/config path.

## Rollout + rollback

Additive only: a new optional skill, a new optional recipe key, no renamed/removed fields, no behavior change to
existing skills' code paths (only prose/table additions to the shared `SCHEMA.md`). An instance that never
configures `[recipes.visualization_preview]` sees no behavior change at all — the skill installs and discovers,
and simply reports BLOCKED with a clear message if invoked before that recipe is configured. Revert is a plain
`git revert` of the merge commit; nothing downstream depends on this skill existing yet.
