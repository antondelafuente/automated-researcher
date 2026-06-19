# Proposal: Codex skill-wrapper coverage and currency (#70)

> The canonical design doc (ADR + PR description). Reviewed by `--scaffold` before build. Lands on main.

## Problem

Codex can be an AAR engineer, but the repo's Codex install instructions do not expose every skill Codex may need. In
particular, the README tells Codex users to symlink four research skills and omits `ship-change`, even though Codex
authors scaffold changes through that workflow.

Issue #70 also asked whether the existing local Codex wrappers in `~/.codex/skills/` should become tracked product
source. The audit answer is no. The source skills already carry the important Codex-specific notes, and the local
wrappers on this box also point at instance-only files such as `/home/anton/AGENTS.md`, the memory index, and the
orchestrator execution profile. Those wrappers are useful local convenience, but they are not the product seam.

## Approach

Keep one canonical product skill source under `plugins/*/skills/*`. Update the README Codex install instructions so a
Codex engineer can install all owned aar-skills source skills, including `aar-engineering`'s `ship-change`, by symlinking
the plugin skill directories into `~/.codex/skills/`.

Coverage decision:

- `gpu-job`: no product wrapper needed. Codex can use the source skill directly; the source is already substrate-neutral.
- `verify-claims`: no product wrapper needed. The source skill already says a Codex main agent must use a different
  family verifier when independence matters.
- `design-experiment`: no product wrapper needed. The source skill already contains the Codex dispatch note; this box's
  local wrapper can remain an instance convenience.
- `run-experiment`: no product wrapper needed. The source skill already describes the substrate-neutral wake requirement
  and the Codex blocking-watcher implementation path; this box's local wrapper can remain an instance convenience.
- `ship-change`: no product wrapper needed, but the README must include its symlink line. The source skill already says
  Codex-authored reviews need `AUDIT_VERIFIER_CMD` pointed at a Claude-family CLI.

Also add a short README note that local harness wrappers are optional convenience files. If a user keeps such wrappers,
they should stay thin and point at these source skills rather than copying the procedure.

## Alternatives considered

- Track `codex/skills/<skill>/SKILL.md` wrappers in this repo. Rejected after design review: it creates a second product
  source tree, duplicates notes that already live in the source skills, and invites instance-path leaks.
- Symlink only the four current README skills. Rejected because it leaves Codex unable to discover `ship-change` through
  the documented setup path.
- Move all Codex-specific notes out of source skills and into wrappers. Rejected because the product design is one
  substrate-neutral source skill with labeled substrate notes.

## Blast radius

This is a README and proposal-doc change. It does not touch plugin source skills, scripts, review gates, merge rules,
GPU backend behavior, verifier behavior, or the local `~/.codex/skills/` instance files.

## Rollout + rollback

Roll out by merging the README update, then optionally aligning this box's local `~/.codex/skills/ship-change` entry with
the documented source-symlink path.

Rollback is reverting the README line and note. The source skills remain unchanged.
