# Proposal: log-experiment secret scan — boundary-guard the `sk-` pattern + scope to the diff (#306)

> The canonical design doc (ADR + PR description). Reviewed by `--scaffold` before build. Lands on main.

## Problem

The `log-experiment.sh` note/design-stage secret scan blocks a legitimate journal log on a file already merged
on `main` and untouched by the log — `journal/knowledge/blog_posts/.../evaluation__agent-scaffolds.html`. Two
compounding bugs (issue #306):

1. **`sk-` pattern has no left word boundary.** `sk-[A-Za-z0-9_-]{20,}` matches inside any long hyphenated
   identifier that merely contains `sk-` — here the HTML anchor `...my-agent-task-always-succeeds-in-suspicious-ways`.
   Any committed page with a phrase like `task-always-…` trips it.
2. **The scan greps the entire passed dir, not the changed files.** Pre-existing merged content permanently
   blocks all future note-logs of that dir — and the journal dir is the standard synthesis-pass target, so this
   recurs every pass (worked around 2026-07-02 by `mv`-ing the wiki mirror out and back).

## Approach

Two changes, both in `log-experiment.sh`; the gate structure is otherwise preserved.

1. **Boundary guard.** Change the `sk-` alternative to `(^|[^A-Za-z0-9_-])sk-[A-Za-z0-9_-]{20,}` so a match must
   begin at start-of-line or after a non-word/non-hyphen char. The other patterns (`ghp_`/`github_pat_`/`AKIA`/
   PEM) are distinctive enough to leave as-is. Verified: the guard clears the `task-always-…` false-positive
   while still matching real OpenAI/Anthropic-style keys (which appear after `=`, space, quote, or `:`).

2. **Scan the exact staged set, in the worktree that gets committed.** Rather than reconstruct "what changed"
   from the *current* working tree against a *stale* `origin/$BASE_BRANCH` (two things that can both diverge
   from what git actually commits), the scan now runs on the set git has **staged** in the dedicated commit
   worktree: `git diff --cached -z --name-only` in the same worktree the push uses, created off the freshly
   fetched base. The log already stages by `cp`-ing `$DIR` over a base checkout and `git add`-ing `$REL`; a file
   unchanged vs base stages nothing, so a pre-existing merged file (the #306 wiki page) is simply not in the set
   — no special-casing needed. Because we scan *the staged index of the worktree we commit*, the scanned set is
   the committed set **by construction**: no stale-base skew (we hold the fetched base) and no ignore-rule skew
   (the worktree's index, under the base tree's `.gitignore`, decides what is staged — not the possibly-dirty
   checkout). The staging helper is shared by `--dry-run` (which stages off the local base, no tokens/network,
   and runs the identical scan, then stops) and the real push path, so `--dry-run` validates the actual gate.

   Paths are read NUL-delimited (`-z` / `read -d ''`) so a newline / quote / non-ASCII filename is scanned RAW
   rather than git-quoted-and-skipped (a scan bypass). A missing base ref, or an empty staged delta, now fails
   **closed** ("no `origin/$BASE_BRANCH` ref" / "nothing to commit") rather than falling back to a whole-dir
   scan — the log cannot proceed without a base to commit against anyway, so refusing is strictly safer than
   scanning something other than the commit.

The scan stays fail-closed on grep errors (`rc>1` → die) and still reports only matching filenames, never the
matched secret text.

## Alternatives considered

- **Boundary guard alone** (issue's option a): unblocks *this* case but leaves the whole-dir scan, so any
  future merged file carrying a real-looking `sk-`/`ghp_`/`AKIA` string still permanently blocks the dir.
  Rejected as half a fix.
- **Working-tree-vs-base diff scoping** (issue's option b; the first-cut implementation here): scan the files
  that differ from `origin/$BASE_BRANCH` via `git diff`/`ls-files` against the *current* tree. Rejected on
  review: the scanned set is reconstructed from the current working tree + a stale local base, which can
  diverge from what git actually commits — a file unchanged vs the stale ref but reintroduced vs the fetched
  ref, or a file un-ignored in the commit worktree but ignored by the dirty checkout, would be committed without
  being scanned. Scanning the actual staged index of the commit worktree removes that whole class by
  construction.
- **Fetching a base in the gate just to compute a diff**: unnecessary once we scan the staged worktree — the
  real path already fetches + stages there, and `--dry-run` stages off the local base offline.

## Blast radius

- `plugins/experiment-lifecycle/skills/log-experiment/scripts/log-experiment.sh` — the `sk-` guard + the
  `secret_scan`→staged-set rework + a `stage_worktree` helper shared by the `--dry-run` and push paths.
  Affects the note and design-stage gates only; the experiment gate does not scan. No config, interface, or
  identity changes. The push/PR/merge machinery below the staging point is unchanged (it already used this
  worktree); the only reorder is that staging now also runs under `--dry-run` (and, on the real path, after
  token minting — still "fail before mutating the remote", since the worktree is local and trap-cleaned).
- `plugins/experiment-lifecycle/skills/log-experiment/scripts/log_experiment_secret_scan_smoke.sh` (new) — an
  offline behavior smoke that drives the real script via `--dry-run` over throwaway git fixtures (no network /
  identity), covering the boundary guard, the staged-set scoping (unchanged file passes, new/modified secret
  blocks), non-ASCII path handling, missing-base fail-closed, and empty-delta.
- `.aar-ci/checks.sh` — wires the smoke to run when the script or the smoke changes (mirrors the existing
  per-helper smoke blocks).
- `plugins/experiment-lifecycle/.claude-plugin/plugin.json` (0.3.16 → 0.3.17) + `CHANGELOG.md` — required
  version bump + one changelog line for a behavior-changing script edit.

Product scaffold, SWE-pipeline-shipped.

## Rollout + rollback

Revert the commit to restore the prior scan. No migration, no state. Failure modes are fail-closed: a missing
base ref or an empty delta refuses to log (never an unscanned push), and the scanned set is the committed set by
construction, so the scan cannot silently under-cover what the PR introduces.
