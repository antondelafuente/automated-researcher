# update-site — the recipe contract it reads

> This is a small, **skill-owned** reference scoped to the two recipe pointers `update-site` reads. It
> is not a copy of the full aar-profile schema (that document — `[github]`, identity seams, branch
> protection, the general `[recipes.<name>]` pointer shape — lives at
> `design-experiment/references/SCHEMA.md`, byte-identical to `run-experiment`'s copy; read it for the full
> instance-profile contract). This doc only names which two recipe keys this skill uses and why.

## Two recipe keys, two different concerns

`update-site` reads **two independently-configured** typed pointers from the instance's aar-profile,
both using the aar-profile schema's existing generic `[recipes.<name>]` shape (`kind = "repo" | "uri"` + the
kind-appropriate fields — see the aar-profile `SCHEMA.md` normative field table). Neither is a new pointer
*grammar*; only the *names* below are new to this skill. **Neither key is `[recipes.viewer]`** — this skill
never reads or requires that pointer at all, in either mode (#369; see "Why not `[recipes.viewer]`" below).

### `[recipes.visualization_preview]` — OPTIONAL, new (#365)

The **local iteration** recipe — read in the DEFAULT (preview) mode, always required for this skill to do
anything. Its pointed-to document is entirely instance-owned narrative; it must name, at minimum:
- the preview claim lifecycle (status / use / release commands, and how ownership conflicts show up);
- the stable per-page local worktree convention and the stable local URL it serves at;
- the shared page-style pattern (a page-building library + at least one prior committed page).

Absent, or present but missing a required field for its declared `kind`, is a hard **BLOCK** — this skill
never improvises a preview mechanism.

### `[recipes.visualization_publish]` — OPTIONAL, new (#369)

The **editorial publish destination** recipe — read only on explicit `--publish`: the editorial site's repo,
its gated landing path, and the assemble/render/bundle/gallery commands for the researcher-driven page this
skill builds. This is `update-site`'s **own** publish-destination pointer, independent of
`[recipes.viewer]` — the instance's operational-dashboard publish recipe that `run-experiment`'s close-time
leg (and `update-dashboard`'s post-close edit loop) read (#347, #484). The two destinations coincide on some
instances and diverge on others (the mismatch #369 was filed to fix); this skill resolves only its own key,
never the other one, so the two lifecycles can never cross-resolve regardless of how a given instance
happens to be wired.

Absent, or present but missing a required field for its declared `kind`, is a hard **BLOCK** on `--publish` —
this skill never falls back to guessing a landing path, and never falls back to `[recipes.viewer]`.

## Why not `[recipes.viewer]`

An earlier version of this skill (#365/#366, then named `visualize-results`) reused `[recipes.viewer]` for
its explicit-publish leg, on the assumption that the automatic close-time experiment viewer and this skill's
researcher-driven editorial visualization always land in the same place. A real instance disproved that: the
two are genuinely distinct destinations there. `[recipes.visualization_publish]` exists specifically so this
skill never depends on that assumption — it is a separate, independently-typed profile entry, not a filtered
view over `[recipes.viewer]`'s document.

## The explicit-publish boundary is mechanical, not just prose

`scripts/resolve_visualization_recipe.sh` (default call, no flags) resolves and validates ONLY
`[recipes.visualization_preview]` — it does not parse, require, or ever look at `[recipes.visualization_publish]`
or `[recipes.viewer]`. Only an explicit `--publish` flag makes it additionally resolve
`[recipes.visualization_publish]`; it still never reads `[recipes.viewer]`, in either mode. Because the
preview and publish keys are genuinely separate profile entries (not a filtered view over one document), the
gated-landing-path fields are **structurally unreachable** without asking for them by name — the fake-HOME
smoke (`scripts/update_site_smoke.sh`) exercises exactly this boundary, plus the fail-closed paths (no
profile, no recipe table, an incomplete table), a distinct-destinations regression case proving
`visualization_publish` and `viewer` never cross-resolve even when both are configured and point at
different repos/paths, and a static check that this skill's own shipped files carry no hardcoded instance
value.

## Who resolves this live (the role-split note)

`design-experiment/references/SCHEMA.md` (and its byte-identical `run-experiment`/`log-experiment` copies)
name `update-site` alongside `design-experiment` (and, for `[recipes.viewer]` specifically, `update-dashboard`
— #484) as a live-resolving reader of the instance profile — see that document's "Who resolves live vs who
reads the snapshot" section. `run-experiment` alone is bound to the executor-reads-only-the-frozen-snapshot
rule, because only its contract requires reproducing a locked run from a frozen record.

## What this doc does NOT define

- The aar-profile schema itself (`schema_version`, `[github]`, identity seams, the generic
  `[recipes.<name>]` pointer shape) — owned by `design-experiment`/`run-experiment`'s shared `SCHEMA.md`.
- `[recipes.viewer]` itself — owned by `run-experiment`'s publish leg (#347) and, for post-close edits, by
  `update-dashboard` (#484); this skill only names it here to explain why it is deliberately NOT the pointer
  this skill reads.
- The content of either recipe document (claim commands, page-style pattern, gated landing-path mechanics) —
  entirely instance-owned, out of scope for this product.
