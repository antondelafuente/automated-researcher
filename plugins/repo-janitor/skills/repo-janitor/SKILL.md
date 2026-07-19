---
name: repo-janitor
description: Deterministic weekly sweep of git worktrees + the shared checkout, triaged into three tiers (safe-to-reap, owner-investigates, researcher-residual). Use when worktrees/repo state have accumulated silently (abandoned worktrees from interrupted runs, agent scratch left in a persistent tree, a shared checkout drifting behind origin) and need a backstop sweep — running the janitor on demand, or wiring it as a scheduled instance sweep. Report-only by default; no state, no auto-reap, no lease model.
---

# repo-janitor — the worktree/repo backstop sweep

The worktree analog of `gpu-job`'s `pod_reaper.sh` and the `automated-researcher#285` session-janitor
idea: every *happy* path already cleans up its own worktree (`ship-change` reaps at `finish`; the
design-in-worktree rule keeps agents off the shared checkout), but nothing catches the irreducible
remainder — a process that died before its cleanup step, a session interrupted mid-run, residue that
predates a rule. This sweep is that backstop, plus a sensor: recurring reports are empirical evidence for
where to plug leaks at the source, not just a cleanup mechanism.

**No state, ever.** Every sweep recomputes every fact from `git` alone — there is no database of past
reports, no lease/expiry model (a worktree doesn't bill by the hour the way a GPU pod does). If something
goes unresolved this week, next week's sweep sees the same git state and flags it again — the re-sweep IS
the retry.

## Running it

```
python3 scripts/worktree_sweep.py --repo <path> [--repo <path> ...] [options]
```

By default this only **reports** — nothing is ever deleted. See "The three tiers" and "The reap action,
and the one rule that matters" below before wiring anything that calls this on a schedule.

Key flags: `--worktree-root <path>` (derive owner ids for tier-2 routing; omit and nothing routes to an
owner — see below), `--owner-depth N` (default 1), `--min-age-days N` (default 7, the tier-1 age bar),
`--default-branch <name>` (default `main`), `--fetch` (do a read-only `git fetch origin` per repo before
comparing — see "Freshness" below), `--json` (machine-readable; see "The report" below), `--reap-tier1`
+ `--dry-run` (see "The reap action").

## The three tiers

Per worktree (`git worktree list --porcelain`, including the repo's own primary checkout), every fact —
dirty, untracked count, merged-into-default, commit age, and for the primary checkout, behind/ahead of
origin — is **fail-closed tri-state**: a `git status`/`log`/`merge-base` call that errors or times out
leaves that fact `UNKNOWN`, which disqualifies the worktree from tier 1 and routes it to tier 2/3 tagged
"inspection needed" — never silently treated as the safe value. The submodule check specifically
**degrades instead of poisoning the whole worktree**: `git submodule status` fails repo-wide the moment
*any* gitlink lacks a `.gitmodules` mapping, so on that failure the sweep falls back to a per-path scan of
the index's gitlink entries instead of marking the fact `UNKNOWN` outright — a single historical broken
mapping no longer disqualifies every worktree that happens to contain it from tier 1.

1. **Deterministic ("safe to reap")** — merged into the default branch, clean of both tracked changes AND
   untracked files, carries no ignored content either, and older than `--min-age-days`; or the worktree's
   own administrative record is plain **prunable** (its working directory is already gone — someone
   `rm -rf`'d it instead of `git worktree remove`). No one is asked. **No ignored content, verified
   empirically:** `git worktree remove` deletes the entire directory tree once it judges the tree clean —
   it does not spare `.gitignore`'d files (a local `.env`, unstaged secrets, anything a broad ignore
   pattern happens to match), so any ignored file blocks tier 1 outright; a worktree that's otherwise
   merged+clean+old but carries only ignored build-cache-like content (`node_modules`, `__pycache__`, a
   venv) is simply **silent** rather than either reaped or nagged about weekly. The untracked/ignored scan
   forces `--untracked-files=all --ignored`, so a repo's own `status.showUntrackedFiles=no` config can't
   hide real content from this check. **Exception, load-bearing:** if `--worktree-root` derives an owner
   for this path and that owner reads as *live* (see the seam below), it is **never** tier 1 even when
   every other condition holds — a persistent per-agent worktree that simply hasn't diverged from a quiet
   default branch recently is not proof of disuse. It demotes to tier 2 instead, with its own reason
   ("merged+clean+old, but you're live — confirm this is really unused before it's reaped"). **The
   configured default branch's own ref is never deleted**, even for a linked worktree checked out directly
   on it (trivially "merged") — only its worktree directory is removed, never the branch, since other
   worktrees/operations depend on that ref existing. An **initialized submodule** also blocks tier 1
   outright, merged+clean+old or not (`git worktree remove` unconditionally refuses a working tree that
   contains one) — flagged into tier 2/3 instead of silently skipped, since only a human can remove it
   manually or with `--force`.
   **Content-identity, the squash-merge-aware alternative to "merged"** (automated-researcher#533): under a
   squash-merge PR flow, a branch's own commit is never itself an ancestor of the default branch — its
   content lands as a new, unrelated squashed commit — so the plain ancestry check above never passes for
   it, permanently, however clean and old. A worktree also qualifies for tier 1 when every file it carries
   beyond `default_ref` — its committed tree (a direct two-tree diff against `default_ref`, not an ancestry
   check) plus any dirty/untracked residue on top — is byte-identical to the same path there: the tree
   contains zero content the default branch doesn't already have, so reaping the *worktree* (never the
   branch ref — the best-effort `git branch -d` is simply a no-op for a non-ancestor branch, and that
   failure is already non-fatal, so the ref survives on its own) loses nothing. A worktree that's still
   genuinely unmerged and carries content of its own not reflected anywhere on the default branch is
   unaffected by this — it's excluded exactly as before, or reads `UNKNOWN` (never a guess) if a comparison
   itself can't complete. **A path with a staged add/modify is checked against both the index blob and the
   working-tree file, independently** — a status like `MM` (staged, then further modified unstaged) means
   the working-tree file can coincidentally match the default branch while the staged blob still holds
   unique content that exists nowhere else; checking the working tree alone would miss that and reap it
   anyway. A staged deletion needs no such check (there's no index blob left to compare). **The reap itself
   passes `--force`** whenever this bar (rather than plain
   mergedness) is what qualified the worktree: the dirty/untracked residue that makes the tree byte-identical
   to `default_ref` is exactly the "modified or untracked files" state a bare `git worktree remove`
   unconditionally refuses, regardless of whether that content is a byte-for-byte match — `--force` is
   harmless to pass on a worktree that's also genuinely git-clean, so the reap doesn't need to re-derive
   which case it's in.
2. **Owner-session investigates** — stray content (dirty/untracked), or a stale unmerged branch nobody is
   continuing, whose derived owner reads as *live*. The report asks that owner to investigate and
   disposition it (or escalate) — ownership assigns *investigation responsibility*, not a memory test: a
   context-cleared session can still `git log`/read the files/cross-reference the registry. **A session's
   answer alone never deletes anything** — the only two things that ever authorize a delete are
   re-verified tier-1 evidence and explicit researcher approval (below).
3. **Researcher residual** — everything flagged that has no live owner to route to (includes every
   candidate owner that doesn't match a live session, and every worktree outside `--worktree-root`, or no
   root given at all), plus the shared/primary checkout's own drift (dirty, untracked, or behind/ahead of
   origin — it has no per-worktree "owner" concept).

An in-progress branch (unmerged, recently touched) or a worktree that just merged and is still inside its
grace window is **silent** — it appears in no tier. It isn't a problem, and if it's still sitting there
next week the same recompute will flag it then.

## The report

Default output is human-readable text, grouped by tier (tier 2 sub-grouped by owner). Every entry carries
the fact(s) that triggered its tier and a **suggested action** — but the action differs by what's actually
safe to hand out: a tier-1/prunable entry gets a ready-to-run removal (`git worktree remove` [+ `git branch
-d` if merged], or `git worktree prune`); a tier-2/3 entry with unresolved dirty/untracked content gets an
**inspection** command instead (a bare `git worktree remove` refuses a dirty worktree, so printing it there
would just fail — inspect first, get an explicit disposition, then remove). When a single reason string
accounts for a large share of one tier's entries (one shared root cause hitting many worktrees identically
— a 2026-07-19 real sweep produced 40 such duplicate lines from one unmapped gitlink), the human report
collapses that group into one summary line plus a flat path list instead of repeating the full reason and
action per entry, so the shared root cause isn't buried in noise. `--json` is unaffected — every entry is
always listed individually there for a machine consumer to group however it needs.

`--json` emits `{"tier1": [...], "tier2": {"<owner>": [...]}, "tier3": [...]}` — each entry has `repo`,
`path`, `branch`, `owner`, `tier`, `reason`, and `action` (`{"kind": "remove"|"prune"|"inspect",
"commands": [...]}`). An instance's messaging wrapper iterates this (one message per tier-2 owner key, one
combined message for tier 3) — **the sweep never sends anything itself**; delivery is instance work (see
"What the instance supplies" below). The report is silent when there's nothing to flag.

## Freshness (`--fetch`)

Without `--fetch`, the primary checkout's behind/ahead-of-origin comparison uses whatever the repo last
fetched — and the report says so ("origin state as of last fetch"), rather than presenting a cached number
as current. With `--fetch`, the sweep runs a plain read-only `git fetch origin` first; if that fetch
fails, behind/ahead is `UNKNOWN` for that repo (never a stale number silently presented as live).

## The reap action, and the one rule that matters

`--reap-tier1` performs the deletions this same invocation just classified as tier 1: prunable entries via
`git worktree prune`, merged+clean+old entries via `git worktree remove` (re-verified immediately before
deleting, as a defense against the state changing mid-sweep — including whether the worktree has since
gained an initialized submodule, re-checked the same as at classification, not just status/identity/HEAD) +
a best-effort `git branch -d` — `--force` is added to the `remove` whenever the content-identity bar above
(not plain mergedness) is what qualified the entry, since that path's byte-identical dirty/untracked residue
is exactly what a bare `remove` refuses.
`--dry-run` (only meaningful with `--reap-tier1`) logs every removal it would perform without touching
anything.

**A scheduled/standing invocation of this sweep must never pass `--reap-tier1`.** Deletion happens only on
researcher approval, or on deterministic tier-1 evidence the researcher has explicitly, separately
blanket-approved for that instance — `--reap-tier1` exists for the latter case, wired as a deliberate,
documented instance-level opt-in, never this product's default behavior. Without that opt-in every sweep,
scheduled or on-demand, is report-only. The very first sweep on a new instance is expected to be an
on-demand run against whatever debt has already accumulated, reviewed and executed in-chat from the
printed/JSON'd commands — spending judgment once on the backlog rather than automating it.

**Recovering from a reap.** Tier-1's own definition makes this non-destructive of content by construction:
`merged` means every commit on the worktree's branch already lives in the default branch's history, and
`git branch -d` (never `-D`) refuses to delete a branch that isn't fully merged. Recovery is a `git
worktree add <path> <default-branch>`, or — using the SHA the sweep logs on every reap (path, branch, HEAD
SHA) — `git branch <name> <sha>`.

## Relationship to `wf.sh gc` (agentic-engineering)

`ship-change`'s `wf.sh gc` already reaps its own worktrees with PR-aware protections (the PR is
closed/merged AND the local HEAD matches what was actually reviewed). This sweep doesn't duplicate that
lookup — it has no GitHub dependency, working from git state alone — but its `merged` bar (the *entire*
worktree HEAD is already an ancestor of the default branch) is a strict subset of `gc`'s safety condition,
so there's no unreviewed content `gc`'s PR-head check could catch that this sweep would miss. Run `wf.sh
gc` for ship-change worktrees specifically; run this sweep as the broader backstop for everything else
(and for whatever `gc` missed) — two independent nets, not competing cleanup paths.

## What the instance supplies

This plugin owns the classification + report format only. An instance wires:

- **Which repo(s) and worktree root** to point `--repo`/`--worktree-root` at.
- **`REPO_JANITOR_LIVE_SESSIONS_CMD`** — a command that prints one live session id per line (mirroring
  `gpu-job`'s `GPU_JOB_*_CMD` provider-seam pattern). **Unset ⇒ every owner reads as not-live** — the
  fail-safe default: nothing is silently routed to tier 2 without this wired, everything instead surfaces
  to the researcher.
- **Message delivery** — turning `--json`'s tier-2/tier-3 entries into an actual fleet message per owner /
  to the researcher. Delivery is fire-and-forget: no waiting on responses, no tracking, no timeouts, no
  aggregation. Whatever isn't resolved just reappears next sweep.
- **The schedule** — the weekly timer (or on-demand invocation) that runs the sweep. **Never pass
  `--reap-tier1` from the standing timer** unless the researcher has explicitly, separately decided to
  blanket-approve the deterministic bucket for that instance.

## Smoke

`scripts/worktree_sweep_smoke.sh` — builds real local git fixtures (no network) covering every tier, the
live-owner tier-1 veto, fail-closed UNKNOWN handling, the silent cases, `--fetch` freshness, `--reap-tier1`
with/without `--dry-run`, the `--json` shape, CLI argument validation, ignored content never reaching tier
1 (with a `status.showUntrackedFiles=no` config bypass attempt), the default branch's ref surviving a reap
of a linked worktree checked out on it, a locked (un-removable) tier-1 worktree failing without blocking
other removals, the squash-merge content-identity alternative bar (including a real `--reap-tier1` pass and
a fail-closed novel-content case), the per-path submodule-fact degradation on an unmapped gitlink, and the
human report's same-reason collapsing.
