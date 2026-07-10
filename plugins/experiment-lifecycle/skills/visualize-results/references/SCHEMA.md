# visualize-results — the recipe contract it reads

> This is a small, **skill-owned** reference scoped to the two recipe pointers `visualize-results` reads. It
> is not a copy of the full aar-profile schema (that document — `[github]`, identity seams, branch
> protection, the general `[recipes.<name>]` pointer shape — lives at
> `design-experiment/references/SCHEMA.md`, byte-identical to `run-experiment`'s copy; read it for the full
> instance-profile contract). This doc only names which two recipe keys this skill uses and why.

## Two recipe keys, two different concerns

`visualize-results` reads **two independently-configured** typed pointers from the instance's aar-profile,
both using the aar-profile schema's existing generic `[recipes.<name>]` shape (`kind = "repo" | "uri"` + the
kind-appropriate fields — see the aar-profile `SCHEMA.md` normative field table). Neither is a new pointer
*grammar*; only the *names* below are new to this skill.

### `[recipes.visualization_preview]` — OPTIONAL, new (#365)

The **local iteration** recipe — read in the DEFAULT (preview) mode, always required for this skill to do
anything. Its pointed-to document is entirely instance-owned narrative; it must name, at minimum:
- the preview claim lifecycle (status / use / release commands, and how ownership conflicts show up);
- the stable per-page local worktree convention and the stable local URL it serves at;
- the shared page-style pattern (a page-building library + at least one prior committed page).

Absent, or present but missing a required field for its declared `kind`, is a hard **BLOCK** — this skill
never improvises a preview mechanism.

### `[recipes.viewer]` — OPTIONAL, already exists (see `run-experiment`'s publish leg, #347)

The **publish destination** recipe — reused as-is, same shape, same semantics `run-experiment`'s close-time
publish leg already reads: the viewer repo, its gated landing path, and the assemble/render/bundle/gallery
commands. `visualize-results` does **not** define a second publish-destination pointer; both the automatic
close-time leg and this skill's explicit publish leg land in the same place, so they read the same config
fact. This skill only resolves `[recipes.viewer]` when the researcher gives an **explicit** publish/ship
instruction — never as part of ordinary preview iteration.

## The explicit-publish boundary is mechanical, not just prose

`scripts/resolve_visualization_recipe.sh` (default call, no flags) resolves and validates ONLY
`[recipes.visualization_preview]` — it does not parse, require, or ever look at `[recipes.viewer]`. Only an
explicit `--publish` flag makes it additionally resolve `[recipes.viewer]`. Because the two are genuinely
separate profile entries (not a filtered view over one document), the gated-landing-path fields are
**structurally unreachable** without asking for them by name — the fake-HOME smoke
(`scripts/visualize_results_smoke.sh`) exercises exactly this boundary, plus the fail-closed paths (no
profile, no recipe table, an incomplete table) and a static check that this skill's own shipped files carry
no hardcoded instance value.

## Who resolves this live (the role-split note)

`design-experiment/references/SCHEMA.md` (and its byte-identical `run-experiment` copy) name
`visualize-results` alongside `design-experiment` as a live-resolving reader of the instance profile — see
that document's "Who resolves live vs who reads the snapshot" section. `run-experiment` alone is bound to the
executor-reads-only-the-frozen-snapshot rule, because only its contract requires reproducing a locked run
from a frozen record.

## What this doc does NOT define

- The aar-profile schema itself (`schema_version`, `[github]`, identity seams, the generic
  `[recipes.<name>]` pointer shape) — owned by `design-experiment`/`run-experiment`'s shared `SCHEMA.md`.
- The content of either recipe document (claim commands, page-style pattern, gated landing-path mechanics) —
  entirely instance/viewer-owned, out of scope for this product.
