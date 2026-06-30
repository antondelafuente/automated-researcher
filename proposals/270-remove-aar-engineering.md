# Proposal: Remove the aar-engineering plugin from automated-researcher (#270)

> The canonical design doc (ADR + PR description). Reviewed by `--scaffold` before build. Lands on main.

## Problem

The engineering tooling — the `ship-change` lifecycle in the `aar-engineering` plugin — now lives in and
is self-hosted by the separate `agentic-engineering` repo (Phase 2). `automated-researcher` still ships a
full duplicate copy of that plugin. That duplication is the product carrying the engineering team's tooling:
it violates the product boundary (`automated-researcher` is the research product; `agentic-engineering` is the
team that builds it), and it means two copies of `wf.sh` drift (they already diverge at the marketplace-name
line). This is Phase 3a of the cutover (parent #255): make `agentic-engineering` the sole home of ship-change.

The fleet loader (`~/claude-pane-loop.sh`) already loads `aar-engineering` from `~/agentic-engineering` and no
longer from the product, so the product's copy is now dead weight — removing it is safe.

## Approach

One atomic PR with four surgical touches:

1. **Delete `plugins/aar-engineering/`** — the entire plugin (ship-change skill, `wf.sh`, the smoke/guard
   scripts, RUNBOOK, references).
2. **Drop the `aar-engineering` entry** (name + source) from `.claude-plugin/marketplace.json`.
3. **Trim `.aar-ci/checks.sh`** — remove every block that references `plugins/aar-engineering/...`: the
   required-file assertions (DISPOSITIONS.md, `wf.sh`) and all the ship-change smoke invocations
   (`locate_audit_smoke`, `identity_smoke`, `fd_state_smoke`, `issue_verbs_smoke`, `gh_guard_static_check`,
   `readonly_ambient_smoke`, `gh_guard_smoke`, `disposition_gate_smoke`). Keep the generic profile intact —
   JSON validity, version-bump checks, and the plugin-discovery / fake-HOME behavior smoke for the **remaining**
   plugins. The branch's trimmed `checks.sh` is what `finish` runs, so it must be self-consistent with the
   plugin dir being gone.
4. **Update `AGENTS.md` prose** — point references to ship-change/`aar-engineering` at the new home: the
   plugin lives in `agentic-engineering`, and scaffold/engineering changes to `automated-researcher` now ship
   via `agentic-engineering`'s ship-change.

**Load-bearing decision — keep `verify-claims` FULL.** `verify-claims` is NOT trimmed here. ship-change
reviewing an `automated-researcher` change sources its `--scaffold`/`--code` reviewer from **this repo's own**
`verify-claims` via `locate_audit` (trusted-but-current, from the base ref). If we removed `--scaffold`/`--code`
from it now, ship-change could no longer review `automated-researcher`. Trimming `verify-claims` is therefore
coupled to a reviewer-resolution change and is deferred to **Phase 3b**. Confirmed working:
`agentic-engineering`'s `wf.sh locate-audit /home/anton/automated-researcher` resolves this repo's
`verify-claims` with `--scaffold` (8) and `--code` (10) mode support.

## Alternatives considered

- **Keep the duplicate plugin in the product** — rejected: that's the boundary violation we're fixing, and the
  two `wf.sh` copies drift.
- **Symlink the product's `aar-engineering` to `agentic-engineering`** — rejected: a symlink across repos is a
  hidden cross-repo runtime dependency (the product would fail to build standalone), the opposite of the
  self-contained-product goal.
- **Also trim `verify-claims` in the same PR** — rejected for now: it breaks cross-repo review until the
  reviewer-resolution change lands; split to Phase 3b so this PR stays safe and atomic.

## Blast radius

- **SWE pipeline (not product runtime):** `ship-change` for `automated-researcher` now comes from
  `agentic-engineering` (the loader already points there). No experiment/research path touches
  `aar-engineering` — `experiment-lifecycle` depends only on `verify-claims`' experiment modes
  (`--design`/`--data`/close + `verify_claim`), which are untouched.
- **CI profile:** `.aar-ci/checks.sh` loses the ship-change-specific assertions/smokes; the generic profile
  (JSON, version bump, plugin discovery, fake-HOME) stays and still covers the remaining four plugins.
- **`verify-claims` kept full** so cross-repo review keeps working (see the load-bearing decision).
- **Untouched:** CHANGELOG.md and `proposals/*.md` (historical ADRs — they reference the plugin as history, not
  as a live dependency).

## Rollout + rollback

- **Already cut over:** the fleet loader loads ship-change from `agentic-engineering`. Sessions adopt the new
  source on their next fresh wrapper (the in-loop plugin-dir recompute); already-running sessions keep working
  (the plugin is loaded in-memory) and lose nothing until they restart, at which point they pick up the new
  source.
- **Rollback:** revert this PR — the plugin dir, marketplace entry, and CI blocks return; nothing external
  depends on the deletion. The `agentic-engineering` copy is unaffected either way.
