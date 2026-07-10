# Proposal: give `visualize-results` its own publish-destination recipe (#369)

> The canonical design doc (ADR + PR description). Reviewed by `--scaffold` before build. Lands on main.

## Problem

`visualize-results` (#365/#366) reuses `[recipes.viewer]` for its explicit `--publish` leg, on the
assumption that the automatic close-time experiment viewer (`run-experiment`'s publish leg, #347) and the
researcher-driven editorial visualization land in the same destination. Instance #1 disproves that
assumption: `run-experiment` publishes operational experiment pages under the configured dashboard viewer,
while `visualize-results` publishes curated editorial pages under a separate site surface. Pointing both at
`[recipes.viewer]` would route the editorial publish to the wrong recipe document — the wrong repo, the
wrong gated landing path, the wrong page-style pattern — silently, since both recipes share the same
`kind = "repo"` shape and would resolve without error.

This is a real instance mismatch found before rollout (instance #1's wiring is paused on this landing), not
a hypothetical: the fix must land before that instance can safely wire `visualize-results --publish`.

## Approach

Give `visualize-results` a **second, independently-typed** recipe pointer — `[recipes.visualization_publish]`
— alongside the existing `[recipes.visualization_preview]`. Same generic `[recipes.<name>]` shape the schema
already defines (`kind = "repo" | "uri"` + kind-appropriate fields); only the *name* is new.

Resolution boundary (mechanical, in `resolve_visualization_recipe.sh`, not just prose):
- **Preview mode (no flag)** resolves ONLY `[recipes.visualization_preview]` — unchanged from #365. It never
  reads `[recipes.viewer]` and, after this change, never reads `[recipes.visualization_publish]` either.
- **`--publish`** resolves `[recipes.visualization_preview]` **plus** `[recipes.visualization_publish]`. It
  never reads or requires `[recipes.viewer]` — that pointer is now exclusively `run-experiment`'s close-time
  publish leg's concern.
- Missing/incomplete `[recipes.visualization_publish]` on `--publish` BLOCKs with zero stdout leakage, same
  fail-closed discipline the existing preview/viewer paths already have (resolve-and-validate-everything
  before printing anything).

`run-experiment` and `[recipes.viewer]` themselves are **completely unchanged** — no code, schema field, or
doc sentence describing that leg is touched. This is purely additive: a new optional recipe key that
`visualize-results` alone reads.

Files touched:
- `resolve_visualization_recipe.sh` — `--publish` resolves `visualization_publish` instead of `viewer`;
  output prefix changes from `VIEWER_*` to `VISUALIZATION_PUBLISH_*` for the publish-only fields.
- `visualize-results/SKILL.md` — Step 4 and the frontmatter/intro's "one seam this skill reads" note now
  name `visualization_publish` as the publish destination, not `viewer`.
- `visualize-results/references/SCHEMA.md` — the "two recipe keys" section becomes three: `preview` (read
  always) and `publish` (read only on `--publish`); drops the "reuses `[recipes.viewer]`" framing.
- `design-experiment/references/SCHEMA.md` and `run-experiment/references/SCHEMA.md` (byte-identical
  canonical copies) — the normative field table's recipe-name examples and the `[recipes.visualization_preview]`
  prose paragraph gain a sibling `[recipes.visualization_publish]` paragraph; the existing `[recipes.viewer]`
  paragraph is untouched except removing the now-stale "the *publish* half of `visualize-results` reuses
  `[recipes.viewer]`" cross-reference.
- `visualize_results_smoke.sh` — existing publish-boundary assertions retarget from `[recipes.viewer]` to
  `[recipes.visualization_publish]`; add a new case proving the two recipes don't cross-resolve (an instance
  profile where `viewer` and `visualization_publish` point at different repos/paths; assert publish mode
  emits only `VISUALIZATION_PUBLISH_*` fields matching the *publish* recipe's values, never the viewer
  recipe's, and preview mode emits neither).
- `plugins/experiment-lifecycle/.claude-plugin/plugin.json` — version 0.3.28 → 0.3.29.
- `CHANGELOG.md` — new entry.

## Alternatives considered

- **Keep reusing `[recipes.viewer]`, document the assumption instead of fixing it.** Rejected — the issue
  exists precisely because that assumption is false for a real instance; documenting a wrong assumption
  doesn't fix the mismatch.
- **Make `visualize-results --publish` resolve `[recipes.viewer]` with an instance-level override key inside
  the viewer recipe table (e.g. `viewer.editorial_path`).** Rejected — conflates two independently-owned
  destinations (operational dashboard vs. editorial site) into one recipe document/table, re-introducing the
  coupling the issue is about; a typed sibling pointer matches how every other recipe key already works
  (`provisioning`, `artifact_store`, `ledger`, `teardown`, `cost_policy` are all independent keys, not nested
  variants of one another).
- **Require `[recipes.visualization_publish]`.** Rejected — matches `visualization_preview`'s existing
  optionality: an instance that hasn't wired editorial publish yet should get a clear BLOCK on `--publish`,
  not a forced config addition before preview-mode iteration can even start.

## Blast radius

Product scaffold only (`plugins/experiment-lifecycle`), specifically the `visualize-results` skill added in
#365/#366 and the two canonical aar-profile `SCHEMA.md` copies it's documented in. `run-experiment`,
`design-experiment`, `log-experiment`, `[recipes.viewer]`, and every other recipe key are untouched — this is
additive-only (one new optional recipe key + a resolver flag re-target). No `research-lab` or `home` changes.
No existing instance profile needs to change: `[recipes.visualization_publish]` is optional, so an instance
that hasn't configured it simply gets a BLOCK on `--publish` (same as today, just for the correct key name).

## Rollout + rollback

Additive schema change (new optional recipe key), no MAJOR bump. No migration needed for instances that
haven't wired `visualize-results --publish` yet (none have — the issue states instance #1's rollout is
paused on this landing). An instance that wants editorial publish now configures
`[recipes.visualization_publish]` pointing at its own site's recipe doc, distinct from `[recipes.viewer]`.
Rollback is a plain revert — no state migration, since nothing consumes the new key until this change lands.
