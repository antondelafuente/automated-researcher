---
name: repo-janitor
description: Deterministic weekly sweep of git worktrees + the shared checkout + non-git scratch globs, triaged into three tiers (safe-to-reap, owner-investigates, researcher-residual). Use when worktrees/repo/disk state have accumulated silently (abandoned worktrees from interrupted runs, agent scratch left in a persistent tree, unreaped repro/temp dirs, a shared checkout drifting behind origin) and need a backstop sweep — running the janitor on demand, or wiring it as a scheduled instance sweep. Report-only by default; no state, no lease model.
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
+ `--dry-run` (see "The reap action"), `--scratch-glob <glob>` (repeatable; see "Non-git scratch" below).

## The three tiers

Per worktree (`git worktree list --porcelain`, including the repo's own primary checkout), every fact —
dirty, untracked count, merged-into-default, commit age, and for the primary checkout, behind/ahead of
origin — is **fail-closed tri-state**: a `git status`/`log`/`merge-base` call that errors or times out
leaves that fact `UNKNOWN`, which disqualifies the worktree from tier 1 and routes it to tier 2/3 tagged
"inspection needed" — never silently treated as the safe value. The submodule check specifically
**degrades instead of poisoning the whole worktree**: `git submodule status` fails repo-wide the moment
*any* gitlink lacks a `.gitmodules` mapping, so on that failure the sweep falls back to a per-path scan of
the index's gitlink entries instead of marking the fact `UNKNOWN` outright — a single historical broken
mapping no longer disqualifies every worktree that happens to contain it from tier 1. That fallback parses
`git ls-files -s -z` (NUL-separated), not the plain-line default: git C-quotes a tab/newline-containing path
in normal output, so a plain-line parse checking for that literal quoted spelling on disk would miss a
genuinely initialized submodule at such a path and silently let it through a forced reap.

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
   check) plus any dirty/untracked residue on top — is byte-identical AND mode-identical to the same path
   there: the tree contains zero content the default branch doesn't already have, so reaping the *worktree*
   (never the branch ref — the best-effort `git branch -d` is simply a no-op for a non-ancestor branch, and
   that failure is already non-fatal, so the ref survives on its own) loses nothing. Mode identity
   (100644/100755/120000) is checked alongside bytes, not instead of them: an uncommitted `chmod +x` on a
   tracked file is byte-identical to the default branch but a distinct mode, and a symlink is compared by
   its link target, never by reading through it to whatever it points at — either mismatch fails this bar,
   even when the raw bytes would otherwise "match." A worktree that's still genuinely unmerged and carries
   content of its own not reflected anywhere on the default branch is unaffected by this — it's excluded
   exactly as before, or reads `UNKNOWN` (never a guess) if a comparison itself can't complete. **A path with
   a staged add/modify is checked against both the index blob and the working-tree file, independently** — a
   status like `MM` (staged, then further modified unstaged) means the working-tree file can coincidentally
   match the default branch while the staged blob still holds unique content (and its own mode) that exists
   nowhere else; checking the working tree alone would miss that and reap it anyway. A staged deletion needs
   no such check (there's no index blob left to compare).
   **A MERGED worktree qualifies on its RESIDUE ALONE** (automated-researcher#804): ancestry has already
   proven every committed byte lives on the default branch, so the dirty/untracked residue on top is the
   only thing a reap could lose — if every one of those paths is byte-and-mode-identical to `default_ref`'s
   own copy (compared exactly as above, staged blobs, modes, and symlink targets included), the worktree is
   tier 1 with the reason "residue identical to `<default-branch>`". The content-identity bar above cannot
   serve this case: its committed-tree diff lists every file the default branch changed *since* this
   worktree's HEAD, so a merged-but-**behind** worktree — the normal state of one whose PR landed weeks ago
   — can never pass it. That gap is what made a 2026-08-31 instance sweep classify 22/22 worktrees as tier 3
   with zero in tier 1 while 4 of 7 hand-checked ones carried nothing but duplicates of `origin/main`:
   `log-experiment` lands `registry/<exp>/` from its own branch, which leaves the executor worktree's
   identical copy *untracked* forever, and the disk refilled 77%→92% in a day behind that. Residue that
   DIFFERS from the default branch, or that sits at a path the default branch doesn't carry at all (an
   UNKNOWN comparison, never a guessed "same"), keeps the worktree out of tier 1 exactly as before —
   reported with its own precise dirty/untracked reason rather than a generic "inspection needed", and
   never deleted. **The reap itself
   passes `--force`** whenever either identity bar (rather than plain
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

## Non-git scratch (`--scratch-glob`)

Worktrees were never the whole leak. The 2026-08-30 disk-fill (automated-researcher#792) had four growing
buckets on one 225G box at 198G used, and only two of them were git: per-experiment executor scratch, dead
worktrees, generated dashboard bundles, and ~15G of `*-repro.*` / per-session temp dirs that nothing had
ever deleted. Durable data was ~7G. Each closed experiment left ~3–6G behind with nothing on the delete
side, so at ~1 experiment/day the disk structurally fills in about two months and the pipeline halts.

`--scratch-glob '<absolute glob>'` (repeatable) ages out that last bucket in the same sweep, on the same
terms as everything else here: an entry whose tree hasn't been written to for `--min-age-days` is **tier
1**; a fresher one is **silent**; anything whose age can't be read, or that trips a path guard, is **tier
3** — reported, never deleted. There is no tier 2: scratch has no per-worktree owner concept to route to.
Deletion still only happens under `--reap-tier1`, which is still the deliberate instance opt-in described
below — a bare sweep reports and nothing else.

- **Age is the TREE's newest mtime, never the directory's own.** A directory's mtime only moves when an
  entry is added or removed at that level, so an actively-written tree can carry a weeks-old directory
  mtime; stat'ing the directory would read a live repro dir as stale and delete it. Symlinks are `lstat`'d
  and never followed, so a link into a live tree can neither rescue nor condemn an entry. A tree larger
  than the scan cap, or one with an unreadable subdirectory, reads UNKNOWN → tier 3, never reaped.
- **The delete scope is statically bounded, and that is the safety story.** Unlike `git worktree remove`,
  nothing underneath an `rm -rf` will refuse a bad target — so a `--scratch-glob`'s *directory* part must
  be absolute, wildcard-free, normalized, and not `/`: only the last path segment may glob. Every
  deletable entry is therefore a direct child of one parent directory the researcher wrote out in full.
  An unsafe pattern is rejected **up front**, before a single fact is computed, not discovered mid-sweep.
- **Path guards, all fail-closed to tier 3:** a symlink (deleting it would leave its target, or the link
  is standing in for real content), a path resolving through a symlinked ancestor, anything that is /
  contains / lives inside a swept repo or worktree, `$HOME`, or the cwd, and anything **repository-like**
  — either a `.git` entry (an ordinary checkout/worktree) or a bare repository, which carries no `.git` at
  all because its gitdir IS its top level (`HEAD` beside `objects/` / `refs/` / `packed-refs` / `config`).
  Both route to `--repo`, where git's own refusals apply; neither is ever scratch.
- **"Not a repository" must be positively established, from the entry's own top-level listing.** The guard
  reads which NAMES are present; it never asks whether those names resolve, and an entry whose listing
  can't be read is UNKNOWN → tier 3, never "not a repository". A checkout whose `.git` is a *dangling
  symlink* is still a checkout — and is the one least likely to have its contents pushed anywhere. For the
  same reason the bare-repo signature is deliberately wider than git's own `is_git_directory()` check:
  that predicate is calibrated for "can git operate here", this one for "may this be destroyed", so a
  half-cloned or atypical bare repo lands on the reporting side. The cost is that a scratch dir holding a
  top-level `HEAD` beside one of those names gets reported instead of reaped.
- **An entry that IS, or CONTAINS, a mount point is never reapable** — the bound is a *path* bound, so it
  has to hold across mounts too. `shutil.rmtree` (like `rm -rf`) deletes a bind mount's contents *through*
  the mount and only then raises `EBUSY` on the mount point itself, so the delete-failed path arrives after
  the mounted data is already gone. Established from `/proc/self/mountinfo` and nothing else: for a bind
  mount whose source is on the *same* filesystem, `os.path.ismount()` is False and `st_dev` is identical on
  both sides, so `ismount` / `st_dev` / `-xdev` / `--one-file-system` all wave it through. An unreadable or
  unparseable mount table is UNKNOWN → tier 3, never "there are no mounts". An **ancestor** mount blocks
  nothing — a scratch root sitting on its own volume is the normal layout; only the entry itself, or
  something strictly below it, blocks.
- **Every fact is recomputed immediately before the delete**, exactly like the worktree reap: a repro dir
  written to in the gap between classification and reaping is skipped, not deleted on a stale reading.

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

`--json` emits `{"tier1": [...], "tier2": {"<owner>": [...]}, "tier3": [...], "reaped": [...]}` — each
tier entry has `repo`, `path`, `branch`, `owner`, `tier`, `kind` (`"worktree"` or `"scratch"`), `reason`,
and `action` (`{"kind": "remove"|"prune"|"delete"|"inspect", "commands": [...]}`). An instance's messaging
wrapper iterates this (one message per tier-2 owner key, one combined message for tier 3) — **the sweep
never sends anything itself**; delivery is instance work (see "What the instance supplies" below). The
report is silent when there's nothing to flag.

**`reaped` — what the sweep actually removed** (automated-researcher#792). A reaping sweep that prints
only what it *classified* leaves the reader inferring the deletions from a stderr log, where a skip (the
safety net firing correctly) reads identically to a removal. Each record is `{"path", "kind", "outcome",
"detail"}` with `outcome` in `removed` / `pruned` / `deleted` / `dry-run` / `skipped` / `failed`; the human
report renders the same information under a `## Reaped` section, grouped so the removals lead. It is empty
without `--reap-tier1`. Because the report now states removals, it is emitted **after** the reap runs — the
live per-action stderr log inside the reap is unchanged, so a human watching a long sweep still sees each
action as it happens.

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
is exactly what a bare `remove` refuses — and stale `--scratch-glob` entries via `rm -rf`, each re-guarded
and re-aged immediately before the delete (see "Non-git scratch" above).
`--dry-run` (only meaningful with `--reap-tier1`) logs every removal it would perform without touching
anything.

**Report-only is the default, and it is the ONLY mode for tiers 2 and 3 — there is no flag that deletes
them.** `--reap-tier1` acts on tier 1 alone: deterministic evidence, no one asked. **A standing/scheduled
invocation passes it only when the researcher has explicitly, separately blanket-approved the deterministic
bucket for that instance** — automated-researcher#792 is exactly that decision for the instance whose disk
filled, and the flag exists for it. Absent that opt-in every sweep, scheduled or on-demand, reports and
deletes nothing; the opt-in is instance wiring (a documented flag on the timer), never this product's
default behavior. The very first sweep on a new instance is expected to be an on-demand run against
whatever debt has already accumulated, reviewed and executed in-chat from the printed/JSON'd commands —
spending judgment once on the backlog rather than automating it. Roll a newly-opted-in timer out with
`--dry-run` for a cycle first, same as `gpu-job`'s pod reaper: the `## Reaped` section then reads as
exactly the list of things the next real sweep will delete.

**Scratch deletions are NOT recoverable** the way a worktree reap is (below) — `~/work`-style executor
scratch has no `main` behind it. That is why the scratch bar is "nothing has written here in a week" and
why the archive-then-delete step belongs at the point the scratch is *created*
(`run-experiment`'s close-time `reap_scratch.sh`, which uploads to the artifact store and verifies before
deleting). This sweep is the backstop for what that step missed, not a substitute for it.

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

- **Which repo(s) and worktree root** to point `--repo`/`--worktree-root` at, and **which scratch globs**
  (if any) to pass as `--scratch-glob`. Those globs are pure instance values — the temp-dir layout, the
  per-session scratch root, the uid in a path — so the product ships the mechanism and none of the paths.
- **`REPO_JANITOR_LIVE_SESSIONS_CMD`** — a command that prints one live session id per line (mirroring
  `gpu-job`'s `GPU_JOB_*_CMD` provider-seam pattern). **Unset ⇒ every owner reads as not-live** — the
  fail-safe default: nothing is silently routed to tier 2 without this wired, everything instead surfaces
  to the researcher.
- **Message delivery** — turning `--json`'s tier-2/tier-3 entries into an actual fleet message per owner /
  to the researcher. Delivery is fire-and-forget: no waiting on responses, no tracking, no timeouts, no
  aggregation. Whatever isn't resolved just reappears next sweep.
- **The schedule** — the timer (or on-demand invocation) that runs the sweep. **Never pass
  `--reap-tier1` from the standing timer** unless the researcher has explicitly, separately decided to
  blanket-approve the deterministic bucket for that instance (automated-researcher#792 is that decision on
  the instance it was filed from; it is not inherited by any other deployment). **An unscheduled sweep is
  no sweep at all** (automated-researcher#804): on the instance that opted in, nothing ran the sweep for
  the first day after the reaper landed and merged worktrees only went away when someone remembered — while
  ~10 new worktrees/day at ~2.2G of `registry/` each put on 18–22G/day. Wire it as a **daily** cron (the
  worktree bucket refills daily; the weekly cadence in this skill's own description is the report-only
  default, not the opted-in reaping one), with the sweep's own output going to a log a human can read
  afterwards — the `## Reaped` section is the record of what it deleted:

  ```cron
  # daily worktree/scratch sweep. ONE line — crontab has no line continuation. Every angle-bracketed value
  # is an INSTANCE value (checkout path, research repo, temp-dir layout, uid in a path, log path): fill in
  # your own, and see "Non-git scratch" above for what a --scratch-glob may safely look like.
  17 4 * * * python3 <checkout>/plugins/repo-janitor/skills/repo-janitor/scripts/worktree_sweep.py --repo <research repo> --fetch --reap-tier1 --scratch-glob '<absolute glob of repro dirs>' --scratch-glob '<absolute glob of per-session scratch>' >> <log path> 2>&1
  ```

  The default 7-day `--min-age-days` bar still applies (a daily sweep does not shorten it — it only means
  an entry is reaped the day after it crosses the bar instead of up to a week later), and `--fetch` is what
  keeps the mergedness/identity comparisons against a live `origin/<default-branch>` rather than whatever
  the box last fetched. Roll the timer out with `--dry-run` for a cycle first, per the reap section above.

## Smoke

`scripts/worktree_sweep_smoke.sh` — builds real local git fixtures (no network) covering every tier, the
live-owner tier-1 veto, fail-closed UNKNOWN handling, the silent cases, `--fetch` freshness, `--reap-tier1`
with/without `--dry-run`, the `--json` shape, CLI argument validation, ignored content never reaching tier
1 (with a `status.showUntrackedFiles=no` config bypass attempt), the merged+identical-residue tier-1 bar
(automated-researcher#804 — a merged-but-behind worktree whose untracked residue duplicates the default
branch reaches tier 1 and is really removed, while residue that differs from it or sits at a path it lacks
stays reported and survives a real `--reap-tier1`), the default branch's ref surviving a reap
of a linked worktree checked out on it, a locked (un-removable) tier-1 worktree failing without blocking
other removals, the squash-merge content-identity alternative bar (including a real `--reap-tier1` pass, a
fail-closed novel-content case, a chmod-only mode-mismatch case, and an untracked-symlink mode-mismatch
case), the per-path submodule-fact degradation on an unmapped gitlink (including a tab-quoted path carrying
a genuinely initialized submodule, which the NUL-safe fallback parse must still find), the human
report's same-reason collapsing, and `--scratch-glob` end to end (stale reaches tier 1 and is really
deleted; fresh is silent; an old directory mtime with a freshly-written file inside is silent; a symlink,
its target, and a swept repo's own worktree all survive a real `--reap-tier1`; `--dry-run` deletes nothing;
every unsafe glob shape is rejected up front; and the `## Reaped` / `reaped` records name what was removed).
