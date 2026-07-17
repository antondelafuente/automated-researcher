# update-dashboard — the recipe contract it reads

> This is a small, **skill-owned** reference scoped to the one recipe pointer `update-dashboard` reads. It
> is not a copy of the full aar-profile schema (that document — `[github]`, identity seams, branch
> protection, the general `[recipes.<name>]` pointer shape — lives at
> `design-experiment/references/SCHEMA.md`, byte-identical to `run-experiment`'s and `log-experiment`'s
> copies; read it for the full instance-profile contract). This doc only names the one recipe key this
> skill uses and why it reads it LIVE rather than from a frozen snapshot.

## One recipe key: `[recipes.viewer]` — the SAME key `run-experiment`'s close leg uses

`update-dashboard` reads exactly one recipe: `[recipes.viewer]` (#347), using the aar-profile schema's
existing generic `[recipes.<name>]` shape (`kind = "repo" | "uri"` + the kind-appropriate fields — see the
aar-profile `SCHEMA.md` normative field table). This is **not a new pointer** — it is the same key
`run-experiment`'s close-time publish leg already resolves (from its frozen `START.md` snapshot) to build
the dashboard's first page. `update-dashboard` never reads `[recipes.visualization_preview]` or
`[recipes.visualization_publish]` — those are `update-site`'s own pointers, for the unrelated `site/`
destination (see `update-site/references/SCHEMA.md`).

Absent, or present but missing a required field for its declared `kind`, is a hard **BLOCK** — this skill
never improvises a dashboard location, repo, or build command. An unconfigured `[recipes.viewer]` means the
instance is manifest-only (no dashboard exists to edit at all) — this skill has nothing to do there, same as
`run-experiment`'s close leg falling back to manifest-only.

## Why LIVE, not the frozen snapshot — the role split, extended (#153, #484)

`design-experiment/references/SCHEMA.md`'s "Who resolves live vs who reads the snapshot" section binds
`run-experiment` to reading **only** the frozen `START.md` snapshot for `[recipes.viewer]`, because that
skill's whole contract is reproducing a *locked* run from a *frozen* record at close time. `update-dashboard`
has no such contract: it is invoked **after** close, live, ad hoc, arbitrarily long after the original brief
was written — there is no snapshot left to freeze from (the brief's job already finished). So it resolves
`[recipes.viewer]` **live**, the same live-resolving role `design-experiment` and `update-site` already play
for their own recipes — a second, narrowly-scoped live reader of this specific key, alongside
`run-experiment`'s snapshot-bound read of it.

**The resolved recipe revision (`VIEWER_GIT_REF` for `kind=repo`, `VIEWER_SHA256` for `kind=uri`) is not
just an implementation detail — the skill's own contract requires recording it** (see SKILL.md), so a
dashboard rebuilt under a viewer recipe that has moved on since the experiment's original close is a visible
fact in the commit/PR note, never a silent divergence.

## What this doc does NOT define

- The aar-profile schema itself (`schema_version`, `[github]`, identity seams, the generic
  `[recipes.<name>]` pointer shape) — owned by `design-experiment`/`run-experiment`/`log-experiment`'s
  shared `SCHEMA.md`.
- `[recipes.viewer]`'s content contract (the four things its recipe doc must name — viewer repo + gated
  landing path, page-building library + prior-page pattern, assemble/render/bundle/gallery commands, where
  per-experiment page source lives) — owned by `run-experiment`'s publish leg (#347); this skill reuses the
  same contract rather than restating it.
- `update-site`'s own recipe pointers (`visualization_preview`/`visualization_publish`) — owned by
  `update-site/references/SCHEMA.md`; this skill never reads them.
- The content of the recipe document itself (claim/build/interpreter commands, page-style pattern, gated
  landing-path mechanics) — entirely instance-owned, out of scope for this product.
