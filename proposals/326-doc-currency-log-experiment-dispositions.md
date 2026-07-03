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

Both fixes are mechanical text syncs, no code/behavior change.

**README.md:**
- In the "If you are a coding agent" Codex/Agent-Skills symlink block: change "`experiment-lifecycle`
  has two" → "`experiment-lifecycle` has three", and add the `log-experiment` `ln -s` line alongside the
  existing `design-experiment` / `run-experiment` lines (same plugin, same directory-naming pattern).
- In the modules table's `experiment-lifecycle` row: extend the description from
  `design-experiment (…) → run-experiment (…)` to also name `log-experiment`'s role — landing the
  design-stage pre-registration (and, later, the finished result) to the research repo as a gated PR —
  so the row reflects all three skills and their order in the lifecycle.

**AGENTS.md:**
- Replace this repo's `<!-- DISPOSITIONS:START -->` … `<!-- DISPOSITIONS:END -->` block with the current
  canonical text from `agentic-engineering`'s `references/DISPOSITIONS.md` (read fresh from that repo's
  checkout at implementation time — the merged #37 state), preserving the block markers so
  `.aar-ci/checks.sh`'s drift check continues to find and diff it.
- Add one line inside the block noting that `agentic-engineering`'s copy is canonical and this one is a
  synced mirror — so a future drift is caught as "this copy is stale," not silently re-diverged, and a
  future editor knows which file to change first.

## Alternatives considered

- **Link to the canonical file instead of embedding the text.** Rejected: the block is embedded in
  AGENTS.md by design so it reads inline as part of this repo's constitution (and so
  `.aar-ci/checks.sh` can diff it locally without a cross-repo fetch at check time); a pointer-only
  version would work for `ship-change`'s own use of `references/DISPOSITIONS.md` but would degrade the
  reading experience for anyone opening this repo's AGENTS.md cold.
- **Leave the `#49` reference as a link instead of removing the issue number.** Rejected: matching the
  canonical text verbatim is the point of a "sync" fix — a locally-reworded version would just be a new
  drift instance in miniature.

## Blast radius

Docs only: `README.md` and `AGENTS.md` in `automated-researcher`. No scripts, skills, or CI behavior
change. `.aar-ci/checks.sh`'s DISPOSITIONS drift check (if present) should pass post-sync rather than
flag drift. Does not touch anything else in AGENTS.md — issue #327 is scoped to a separate follow-up
touching the same file after this merges.

## Rollout + rollback

Single PR, no staging needed. Revert is a plain `git revert` of the merge commit if the wording needs
another pass.
