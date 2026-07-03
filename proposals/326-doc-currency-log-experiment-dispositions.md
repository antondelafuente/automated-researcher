# Proposal: doc currency — README's missing `log-experiment` + AGENTS.md's stale DISPOSITIONS block (#326)

> The canonical design doc (ADR + PR description). Reviewed by `--scaffold` before build. Lands on main.

## Problem

Two independent doc-currency gaps, both docs-only:

1. **README.md** describes `experiment-lifecycle` as shipping two skills (`design-experiment`,
   `run-experiment`) in both the "if you are a coding agent" Codex/Agent-Skills symlink block and the
   modules table. It actually ships three — `log-experiment` is load-bearing: `design-experiment`
   requires a `log-experiment` design-stage merge before it will dispatch an executor (since commit
   a689835). A non-Claude install (Codex CLI or another Agent-Skills harness) that follows the README's
   symlink instructions literally ends up missing a skill the other two depend on, with no signal that
   anything is missing until `design-experiment` tries to dispatch.

2. **AGENTS.md**'s `DISPOSITIONS:START`/`END` block is a synced copy of the canonical vocabulary in
   `agentic-engineering`'s `plugins/aar-engineering/skills/ship-change/references/DISPOSITIONS.md`. That
   canonical copy has since picked up two changes this repo's copy lacks (merged via
   antondelafuente/agentic-engineering#37, which also folds in #36's fix):
   - the **no-self-flip contract**: `needs-shaping → ready` is the researcher's transition in every
     lane; an agent asked to *implement* an issue never flips its own disposition label as a step of
     doing so.
   - a **fixed dangling reference**: the `ready` bullet's clause about the auto-handler's autonomy
     boundary used to end "...is #49's to define" (a reference that had gone stale); canonical now
     phrases this as an open/undecided boundary without pointing at a specific issue number.

   Until synced, this repo's copy is a silently-drifted fork of the constitution text — an agent reading
   only this repo's AGENTS.md won't learn the no-self-flip norm.

## Approach

Both fixes are mechanical text syncs, no code/behavior change. Revised in response to `--scaffold`
review (see Alternatives considered): the `log-experiment` fix needed to cover every install/discovery
surface, not just README, and the DISPOSITIONS sync needed to also touch its packaged mirrors and keep
`AGENTS.md` as this product's canonical copy rather than inverting ownership to `agentic-engineering`.

**`log-experiment` doc-currency (README + the other surfaces the review found still stale):**
- README's "If you are a coding agent" Codex/Agent-Skills symlink block: "`experiment-lifecycle` has
  two" → "has three", plus the `log-experiment` `ln -s` line alongside `design-experiment` /
  `run-experiment`.
- README's modules table `experiment-lifecycle` row: extended to name all three skills and their order
  — `design-experiment` → `log-experiment` (land the design-stage pre-registration, later the finished
  result, as a gated PR) → `run-experiment`.
- Root `.claude-plugin/marketplace.json`'s `experiment-lifecycle` description: same three-skill update
  (per-plugin `plugins/experiment-lifecycle/.claude-plugin/plugin.json`'s own description already names
  all three — only the root marketplace copy was stale).
- `design-experiment/SKILL.md`'s "Companion skills this one composes" list: added `log-experiment` (the
  skill's own body already instructs "run the `log-experiment` skill" at Step 4, but the declared
  dependency list omitted it — the two were out of sync within the same file).
- `experiment-lifecycle`'s `plugin.json` version bumped (0.3.22 → 0.3.23): a non-manifest file in that
  plugin dir changed (`design-experiment/SKILL.md`), and `.aar-ci/checks.sh` requires the version to
  move so version-pinned installs pick up the fix.

**AGENTS.md DISPOSITIONS sync (kept AGENTS.md canonical, not inverted):**
- Replaced this repo's `<!-- DISPOSITIONS:START -->` … `<!-- DISPOSITIONS:END -->` block with the
  current canonical text (the #315 no-self-flip contract + the fixed dangling `#49` reference), sourced
  from `agentic-engineering`'s `references/DISPOSITIONS.md` as of the merged #37 state — but as *source
  material for the text*, not as a change of which repo owns the definition. `AGENTS.md` already states
  "This is the definition (the product-owned, versioned part)"; that ownership is unchanged here. No
  "agentic-engineering is canonical" line was added (see Alternatives considered).
- Applied the identical sync to `automated-researcher`'s own two packaged mirrors that
  `.aar-ci/checks.sh` requires to byte-match the `AGENTS.md` block:
  `plugins/feedback-loop/skills/file-feedback/references/DISPOSITIONS.md` and
  `plugins/feedback-loop/skills/triage-feedback/references/DISPOSITIONS.md`.
- `feedback-loop`'s `plugin.json` version bumped (0.1.3 → 0.1.4) for the same reason as
  `experiment-lifecycle` above — its packaged references changed.

## Alternatives considered

- **Link to the canonical file instead of embedding the text.** Rejected: the block is embedded in
  AGENTS.md by design so it reads inline as part of this repo's constitution (and so
  `.aar-ci/checks.sh` can diff it locally without a cross-repo fetch at check time); a pointer-only
  version would work for `ship-change`'s own use of `references/DISPOSITIONS.md` but would degrade the
  reading experience for anyone opening this repo's AGENTS.md cold.
- **Leave the `#49` reference as a link instead of removing the issue number.** Rejected: matching the
  canonical text verbatim is the point of a "sync" fix — a locally-reworded version would just be a new
  drift instance in miniature.
- **Note that `agentic-engineering`'s copy is canonical.** Rejected on `--scaffold` review (HIGH-adjacent
  MED finding): this repo's `AGENTS.md` explicitly declares itself "the definition (the product-owned,
  versioned part)," and `.aar-ci/checks.sh` extracts *from* `AGENTS.md` as the source of truth for its
  own packaged-mirror drift check. Declaring `agentic-engineering` canonical here would invert that
  ownership and contradict both the existing constitution text and the check that already treats
  `AGENTS.md` as canonical — the text happened to land in `agentic-engineering`'s copy first, but that's
  an editing-order accident, not a change of which repo owns the definition.
- **Update README/marketplace.json only, leaving `design-experiment/SKILL.md`'s companion list and the
  per-plugin manifest version stale.** Rejected on `--scaffold` review: a zero-context install that reads
  only the companion-skill dependency list (not the prose that mentions `log-experiment` later in the
  same file) would still under-install, and a changed packaged file without a version bump defeats
  version-pinned installs' ability to detect the fix.

## Blast radius

Docs + manifests only, across two plugins: `README.md`, `AGENTS.md`, `.claude-plugin/marketplace.json`,
`plugins/experiment-lifecycle/.claude-plugin/plugin.json`, `plugins/experiment-lifecycle/skills/design-experiment/SKILL.md`,
`plugins/feedback-loop/.claude-plugin/plugin.json`, and both `feedback-loop` packaged
`references/DISPOSITIONS.md` copies. No scripts, skill logic, or CI behavior change. Does not touch
anything else in `AGENTS.md` — issue #327 is scoped to a separate follow-up touching the same file after
this merges.

## Rollout + rollback

Single PR, no staging needed. Revert is a plain `git revert` of the merge commit if the wording needs
another pass.
