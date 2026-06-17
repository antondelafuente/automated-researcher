# Proposal: pre-commit guard against direct commits to aar-skills main (#40, Tier 2)

> The canonical design doc (ADR + PR description). Reviewed by `--scaffold` before build. Lands on main.

## Problem

An agent (or human) can forget the ship-change workflow and edit `aar-skills` directly. The protection
today is **asymmetric**:

- **`origin/main` is well-defended** — branch protection requires a PR + a `codex-engineer[bot]` approval +
  include-administrators, so a direct `git push origin main` is rejected. A forgotten edit can't become
  canonical.
- **Local commits are NOT guarded.** The repo's `.githooks/pre-commit` is a *secrets* scanner only. Nothing
  stops a `git commit` directly on the local `main` branch — which leaves local `main` dirty/ahead of origin,
  and (because some artifacts are consumed live from the working tree) can change behavior before any review.

This is the commit-time layer of the broader #40 defense. (Tiers 1 and 3 — a Claude Code PreToolUse
edit-guard and a SessionStart drift tripwire — are **instance** hooks and already landed on the box; this PR
is the one **product** layer, so it ships through ship-change and protects every clone/substrate, not just
this box.)

## Approach

Add a check to `aar-skills/.githooks/pre-commit`: **refuse a commit whose current branch is `main`.** In the
ship-change model, every legitimate change is committed on a `change/*` branch inside a `/tmp/wf-*` worktree;
`main` only ever receives commits via GitHub's squash-merge of an approved PR (server-side, which does **not**
run this local hook). So a *local* commit on `main` is always the bypass — block it with a message that
points at `wf.sh start`.

```sh
# (early in pre-commit, before/independent of the secret scan)
branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)
if [ "$branch" = "main" ]; then
  echo "BLOCKED: direct commit to aar-skills 'main' — scaffold changes go through ship-change" >&2
  echo "  wf.sh start <issue> <slug> -> edit in the worktree (change/* branch) -> PR + review -> merge." >&2
  echo "  Deliberate exception only: git commit --no-verify." >&2
  exit 1
fi
```

- **`git commit --no-verify`** remains the escape hatch (the threat is *forgetting*, not *evading*).
- The secret scan still runs for `change/*` branches (the guard is an early, independent gate; it only
  short-circuits on `main`).
- Belt-and-suspenders with branch protection: this fails *locally and early* with a helpful message, instead
  of letting the agent build a commit only to be rejected at push.

## Alternatives considered

- **A separate `pre-push` hook blocking pushes to `main`.** Useful but redundant with branch protection
  (push to `origin/main` is already rejected server-side) and it doesn't catch the *local* divergence the
  commit-time guard does. Could add later; the commit guard is the higher-value half. (Noted, deferred.)
- **Detect "am I in the main checkout vs a worktree?"** instead of branch name. Rejected — branch name is the
  robust invariant (worktrees are on `change/*`, main checkout on `main`); checkout-path detection is
  fiddlier and no more correct.
- **Rely on prose only** (CLAUDE.md / AGENTS.md / SKILL). That's exactly what gets forgotten — the point of
  #40 is a mechanical gate, not another paragraph.

## Blast radius

- **One file:** `aar-skills/.githooks/pre-commit` (a new early branch check; the existing secret-scan logic is
  untouched). Active only where `core.hooksPath=.githooks` is set (the documented per-clone install, already
  in force on this box).
- Affects **every committer on a `main` branch** — which, in the ship-change model, should be nobody (all work
  is on `change/*`). The `--no-verify` hatch covers the rare genuine exception (e.g. the bootstrap path).
- Does **not** affect the merge: `gh pr merge --squash` runs server-side and never triggers the local hook;
  `finish`'s `git pull --ff-only` doesn't commit. So the workflow itself is unaffected.
- No plugin manifest / skill behavior change → no version bump needed for a `.githooks` script. (The check
  profile will confirm.)

## Rollout + rollback

- **Rollout:** ships through ship-change; the `.aar-ci` checks (bash syntax) + smoke run in `finish`. First
  effect: any local `git commit` on `main` is refused with the pointer message.
- **Rollback:** single squash commit — `git revert <sha>` and re-ship, or `git commit --no-verify` in the
  interim. The guard is a few lines in one hook; worst case it's bypassed with `--no-verify`. Because it only
  *adds* a refusal on `main` (a branch nothing should commit to), the downside risk is near zero.
