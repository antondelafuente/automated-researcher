---
name: repo-janitor
description: Deterministic weekly sweep of git worktrees + the shared checkout + non-git scratch globs, plus a content-keyed eviction pass against the artifact store, triaged into three tiers (safe-to-reap, owner-investigates, researcher-residual). Use when worktrees/repo/disk state have accumulated silently (abandoned worktrees from interrupted runs, agent scratch left in a persistent tree, unreaped repro/temp dirs, big files already uploaded to the store, a shared checkout drifting behind origin) and need a backstop sweep — running the janitor on demand, or wiring it as a scheduled instance sweep. Report-only by default; no state, no lease model.
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

Key flags: `--worktree-root <path>` (**repeatable** — derive owner ids for tier-2 routing; omit and nothing
routes to an owner — see below), `--owner-depth N` (default 1), `--min-age-days N` (default 7, the tier-1 age
bar for UNMERGED worktrees and scratch), `--merged-min-age-days N` (default 2, the tier-1 age bar for
worktrees already merged into the default branch — see "The age bar is per tier" below),
`--default-branch <name>` (default `main`), `--fetch` (do a read-only `git fetch origin` per repo before
comparing — see "Freshness" below), `--json` (machine-readable; see "The report" below), `--reap-tier1`
+ `--dry-run` (see "The reap action"), `--scratch-glob <glob>` (repeatable; see "Non-git scratch" below),
`--evict-verified <root>` (repeatable) + `--store <rclone path>` + `--min-size <size>` (default 50M; see
"Content-verified eviction" below).

**`--worktree-root` is repeatable** (automated-researcher#840) because a box has more than one place
per-session worktrees get created: the agent-workspace root, and the coding harness's own
`<repo>/.claude/worktrees` trees. The harness trees were already *seen* by the sweep (they are worktrees of
a repo passed with `--repo`, so `git worktree list` reports them) but derived **no owner**, so the
live-owner tier-1 veto never applied to them in either direction — 5 such trees held 12.8G on the box that
filed #840. Name every root an instance actually creates worktrees under and they all follow the same tier
rules. Where roots nest, the **most specific (longest) match** supplies the owner id, so the answer never
depends on the order the flags were passed. Which roots exist is an instance value; the product ships the
mechanism and none of the paths.

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
   `rm -rf`'d it instead of `git worktree remove`). No one is asked. **No ignored content beyond the
   residue allowlist below, verified empirically:** `git worktree remove` deletes the entire directory tree
   once it judges the tree clean — it does not spare `.gitignore`'d files (a local `.env`, unstaged
   secrets, anything a broad ignore pattern happens to match), so any ignored file that is *not* an
   allowlist member blocks tier 1 outright; a worktree that's otherwise merged+clean+old but carries such
   ignored build-cache-like content (`node_modules`, a venv) is simply **silent** rather than either reaped
   or nagged about weekly. The untracked/ignored scan forces `--untracked-files=all --ignored`, so a repo's
   own `status.showUntrackedFiles=no` config can't hide real content from this check — and, with
   `--untracked-files=all`, git lists ignored **files** individually at full depth rather than collapsing
   them to a directory, so the per-path allowlist rules apply to them exactly as written.
   **Exception, load-bearing:** if `--worktree-root` derives an owner
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
   never deleted.
   **...OR entirely on the bounded RESIDUE ALLOWLIST** (automated-researcher#840). Byte-identity is a bar no
   experiment worktree that went through a design audit can ever clear: a week after #804 landed, four
   merged worktrees (2.2–2.4G each, 9.3G total) still had to be removed by hand, and their only
   non-identical paths were `*.run.log` auditor transcripts, `__pycache__`/`*.pyc`, and the design-stage
   `CHECKLIST.md` / `START.md` / `CLAIMED_BY` / `DESIGN_AUDIT*.md` copies that main already holds in
   post-run form. So a **merged** worktree also reaches tier 1 when every path that is *not* byte-identical
   is an allowlist member, in one of two classes with deliberately different admission rules:
   **regenerable** (`*.run.log`, `*.pyc`, anything under a `__pycache__/` component — matched on the file's
   own basename at any depth, with **no** requirement that the default branch carry the path at all, because
   these are reproducible from code that is on it or are a tool's transcript of a run whose findings file is
   the durable record) and **superseded** (`CHECKLIST.md`, `START.md`, `CLAIMED_BY`, `DESIGN_AUDIT*.md` —
   admitted **only when the default branch carries that exact path already**; main's copy *is* the warrant,
   so the worktree's is a stale earlier revision of something durable rather than unique content). The
   reason string names the allowlist in full, because this is the one tier-1 bar that deletes bytes the
   default branch does not itself carry. **One off-allowlist path is enough to keep the whole worktree out**
   — every other path still has to clear the full byte-and-mode identity bar — and a superseded-class
   *basename* at a path main lacks is not superseded at all: it is the only copy, and it keeps the worktree
   reported instead. This bar applies to ancestry-**merged** worktrees only; the squash-merge alternative
   above still requires whole-tree identity, since there nothing has established that the commits themselves
   are durable.
   **The allowlist spans all three residue categories — dirty, untracked AND *ignored*.** A tier-1 reap
   deletes all three identically, so the set of paths the safety bar adjudicates has to be the set the reap
   destroys. This is not a refinement but the case that carries the feature: a normal `.gitignore` —
   including this repo's own — already ignores `__pycache__/`, `*.pyc` and `*.run.log`, so on a real box
   those paths arrive as ignored, not untracked, and an allowlist consulted only against dirty/untracked
   residue is inert against precisely the worktrees it was written for (the merged worktree carrying
   nothing but audit transcripts and bytecode stays silent and unreapable, which is the pre-#840 state).
   What does **not** carry over between the categories is the byte-identity fallback: for the ignored
   category, allowlist membership is the *only* way through, and any other ignored path is a confirmed
   veto exactly as before. That is what keeps this widening bounded to the named allowlist and preserves
   the concern the ignored veto was built for — a stray `.env`, unstaged secrets and a 6G venv are none of
   `*.run.log` / `*.pyc` / `__pycache__/`, and the superseded class cannot admit a path the default branch
   doesn't already carry. When ignored paths are what cleared the bar, the tier-1 reason says so
   explicitly (`+N ignored path(s), all on the reap allowlist [...]`) rather than folding them into
   "clean" — the reap's least visible effect is the one the report must not leave out. **The reap itself
   passes `--force`** whenever any of these residue bars (rather than plain
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

## The age bar is per tier

`--min-age-days` (default 7) is the bar for **unmerged** worktrees and for `--scratch-glob` entries;
`--merged-min-age-days` (default 2) is the bar for a worktree ancestry has already proven **merged**
(automated-researcher#840). What the grace window buys differs between the two, which is why one number
can't serve both: for an unmerged worktree the **age is the evidence** that nobody is continuing it, while
for a merged one every committed byte already lives on the default branch and the only open question — "is
someone still working in this checkout" — is answered directly by the live-owner veto, not by waiting.
Measured: at ~10G of residue per closed experiment and roughly a close a day, a uniform 7-day bar *was* the
steady-state fill — the disk refilled before the bar expired, so the sweep's deletions never caught up with
its own backlog. Both flags move independently, so an instance that wants the old uniform behavior passes
`--merged-min-age-days 7`. Neither bar overrides anything else: a live (or unverifiable) owner,
off-allowlist ignored content, an initialized submodule, and every UNKNOWN fact all still keep a worktree
out of tier 1 at any age.

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

**Close-audit checkouts: the backstop, and where it does and doesn't apply** (automated-researcher#840).
Closing one experiment on 2026-09-06 left three clean-room checkouts in `/tmp` (10.7G) plus 3.6G of older
siblings from experiments already closed. Two things had to change and only one of them is here:
`experiment-lifecycle` now mints those trees at a **fixed, nameable shape** (`<temp root>/<exp>-audit.<random>`,
via `audit_checkout.sh`) and reaps them when the audit verdict is written — a backstop can only catch what it
can NAME, and ad-hoc names defeated this sweep as surely as the missing cleanup defeated the close. For the
residue a *died-mid-close* run still leaves:

- **A checkout made by `audit_checkout.sh` is a git WORKTREE, so `--repo` already sweeps it** — no glob
  needed, and better: it is classified with git's own facts and removed with `git worktree remove` rather
  than an `rm -rf`. This is the path to rely on.
- **A `--scratch-glob '<temp root>/*-audit.*'` (and any `*-checkout*` shape an instance still produces) is
  the second net**, for anything that is *not* a worktree of a swept repo. Be aware what it will and won't
  do: the repository-like path guard above means a leftover **full clone** is **reported in tier 3, never
  deleted** — deliberately, since an unrecoverable object database is not a fair trade for a disk win. So
  the glob converts "invisible" into "reported", not into "reaped"; the reaping fix is upstream, at the
  helper that stops the clone being made in the first place.

## Content-verified eviction (`--evict-verified`) — the box is a cache of the artifact store

Every rule above is **lifecycle-keyed**: it deletes what a known close path registered, at a known step,
under a known path shape. That cannot converge, and automated-researcher#856 is the measurement — a *third*
disk-full incident in four days (2026-09-06 95%, 09-06 evening 92%, 09-09 94%), each from a class no
existing reaper rule reached, because each new workflow variant (harness worktrees, ad hoc audit clones,
the close leg's fresh pull, and then the exploratory path) falls outside the rule set and leaks until
someone does forensics by hand. Measured 2026-09-09: **41.5 GB** of Tinker adapter tars in six *closed*
exploratory runs (`explore-depv1-*`, NOTE.md landed 10–34 h earlier). Every byte was already on R2 under
`experiments/<exp>/target_probes/` — verified by name+size, then deleted **by hand**. Nothing on the box
could evict them, because the exploratory path registers no close, so no reaper considered them "finished".

`--evict-verified <root> --store <rclone path> [--min-size 50M]` asks a **content** question instead, which
no workflow variant can fall outside of: *are these exact bytes already at the artifact store?* For every
regular file at or above `--min-size` under each root, it looks for an object under
`<store>/<the file's top-level directory under the root>/**` carrying the **same basename and the same exact
size** — and then requires a **checksum recomputed from the local bytes** to agree with every comparable
checksum that object exposes (for S3 that is the ETag's md5, or the `X-Amz-Meta-Md5chksum` metadata rclone
writes for a multipart upload whose ETag is not a plain md5). On a match the local file is evicted; the
report prints `EVICTED <path> -> <store object>` and the reclaimed bytes. **No match, no comparable
checksum, a checksum that disagrees, an unreadable local file, or a store listing that fails → keep and
report** (tier 3), never a guess.

- **Basename, not path.** The store's layout under `<store>/<exp>/` is the archive step's business, not
  this sweep's: #856's own case has `~/work/<exp>/adapters/probe.tar` living at
  `experiments/<exp>/target_probes/probe.tar`, so a path-shaped lookup would have found nothing while the
  bytes were demonstrably there. The **top-level directory name** is the only path fact used, and only to
  pick the store prefix — which is also what bounds the listing to one experiment's objects.
- **A recomputed checksum is REQUIRED — name + size is a prefilter, never the proof.** Name and exact byte
  length are what was checked by hand before those 41.5 GB were deleted, but they are not exact-byte
  equivalence, and the two files this leg most needs to tell apart are two adapter tars for one experiment:
  a generic basename (`probe.tar`) and a size fixed by the adapter's *shape* rather than its weights is
  exactly the collision name+size cannot see. So an object exposing no checksum this sweep can recompute
  proves nothing, and the file is **kept and reported with that object named** — run the by-hand check
  yourself if you believe the bytes really are durable. Every comparable checksum the object exposes must
  agree: one disagreement is a confirmed *different file*, and a record contradicting itself across two
  spellings of one algorithm picks no winner. An algorithm this sweep can't recompute (crc32, quickxor) is
  treated exactly like an absent one. This costs the measured case nothing — `--store` names an rclone
  remote, rclone reports md5 for the S3/R2 objects it uploaded, and a recomputed checksum is what
  `rclone check` (the test the archive step already gates on) compares. **Hash names are matched
  case- and punctuation-insensitively** (`MD5`, `md5` and `SHA-1` all normalize), because rclone has spelled
  them both ways and a listing's formatting must not decide whether a real checksum gets checked.
- **The age bar is 0, deliberately.** Age is evidence about a *writer*, and the store answers the only
  question that matters for a cache entry: a file whose bytes are proven durable is not
  work-in-progress at any age. **The live-owner veto is the only hold** — nothing inside a live (or
  liveness-unverifiable) owner's tree is ever evicted, reusing the same `--worktree-root`-derived owner and
  the same `REPO_JANITOR_LIVE_SESSIONS_CMD` seam as the worktree tiers. Name the eviction roots as
  `--worktree-root` too, or no owner is derived for them and that veto has nothing to fire on.
- **`registry/` of a git tree is never touched**, and neither is a `.git` directory: the walk prunes both,
  so nothing beneath them is even stat'd. The veto is keyed on the git marker's *name* being present
  (never on whether it resolves — same discipline as the scratch guards), and it is **git-tree-keyed, not
  name-keyed**: a directory that merely happens to be called `registry/` outside any checkout is ordinary
  scratch. That is the whole git-side veto, deliberately: a *tracked* file elsewhere in a checkout could in
  principle be evicted (leaving the worktree dirty until `git restore`), but a file whose bytes are proven
  at the store and also committed to a branch is durable twice over, so widening the veto to whole
  checkouts would cost the leg most of what it was written to reach — executor scratch lives inside
  worktrees.
- **Symlinks are never candidates** and the walk never follows one, so a link into a live tree can neither
  be evicted nor drag its target's bytes into the scan. Only regular files are considered.
- **Hardlinks are resolved per inode, not per path.** Unlinking one of N links frees *nothing*, so an inode
  is evicted only when every link to it was found in this scan (`st_nlink` is what makes that checkable)
  **and every one of them verified**; the reclaimed figure counts its bytes once. A link the sweep cannot
  see, or a sibling that didn't verify, keeps the whole group — destroying a path for zero reclaimed bytes
  is pure loss.
- **Deletion is still `--reap-tier1`-gated, like everything else here.** A verified file classifies as
  **tier 1** with a `kind` of `evict`; a bare sweep reports it (and the total it would reclaim) and deletes
  nothing. Every fact is re-verified immediately before the unlink — the owner's liveness fresh per item,
  the file's `(device, inode, size, mtime)` identity, and **its bytes**, re-read and re-digested against
  the checksum that matched the store.
- **The inode that was verified is the inode that is removed — and it still holds the verified bytes.**
  Two distinct substitutions have to be refused here, and the delete refuses both:
  - *A name is not an inode.* Checking a *path* and then unlinking that path is two lookups of a name: a
    concurrent rename in between would have the janitor delete a file it never verified, and a link added
    after the count was read would make the accounting claim bytes it no longer frees. So before anything
    is checked, every link in the group is `rename`d — inside its own directory, through a directory fd
    opened `O_NOFOLLOW` — to a private `.repo-janitor-evicting.*` name this process just generated.
    Nothing else can reach the inode by path after that, so the identity and link-count checks *hold*
    rather than merely having held.
  - *A stat tuple is not the bytes.* `(device, inode, size, mtime)` is a **proxy** for the content, and
    letting it stand for the content at the delete is the same substitution the verdict already rejects
    when it refuses name+size: `mtime` is not a content hash (an mmap writer's timestamp update is only
    guaranteed by writeback/`msync`, a coarse-granularity filesystem hides a write inside its own granule,
    and a writer holding a descriptor never goes through the name the staging step bound). So the *last*
    thing before the unlink is a re-read of the staged inode through an `O_RDONLY|O_NOFOLLOW` descriptor,
    every digest compared against the one that matched the store, with an `fstat` on that same descriptor
    confirming the bytes came from the verified inode and the identity/link-count checks re-run afterwards
    (so a write or a new link that landed *during* the read is caught too). The stat checks survive as the
    cheap gate that skips a stale group without paying for the read; nothing deletes on their strength
    alone. This is a **second full read of each file a reap is about to delete** — deliberately paid, since
    it is the only thing that establishes what the leg claims, and it is never paid on the tier-3 majority.
  - **The boundary this leaves**, stated rather than papered over: POSIX has no atomic
    "unlink-if-contents-still-equal", so a writer holding an open descriptor could in principle write into
    the inode in the microsecond window between that last read and the `unlink`. What covers the realistic
    writer is the live-owner veto, not the window; the digest closes everything a stat tuple silently
    waved through.

  Any disagreement aborts and renames every staged link back (refusing to overwrite a name something
  re-created meanwhile); a restore that can't complete is logged loudly with the staged path, and a
  crash-orphaned staging entry is both recognizable by hand and unevictable by a later sweep, since no
  store object shares that name.
- **The mount guard from `--scratch-glob` deliberately does not carry over.** It exists because
  `rmtree` deletes a bind mount's *contents* through the mount before failing on the mount point; this leg
  unlinks one named regular file whose bytes are proven at the store, so there is no tree-walk to escape
  and no unverified byte to lose.
- **Why this is a backstop, not a replacement.** It does not know or care what a close path did, so it
  covers variants nobody has written a rule for yet — which makes the lifecycle reapers' coverage gaps a
  *delay* instead of a leak. It would also have caught the 2026-09-06 row4-factorial triplication (2 of 3
  copies already on R2) and every `reap_scratch.sh` leftover after a verified archive. Regenerable-but-not-
  stored content (venvs, `__pycache__`) is not its business — that is the residue allowlist above.

**The store listing goes through a seam**, `REPO_JANITOR_STORE_LIST_CMD`: `<cmd> <store prefix>` must print
`rclone lsjson --recursive --files-only --hash`-shaped JSON (an array of `{"Path","Name","Size","Hashes"}`).
Unset, it *is* `rclone lsjson --recursive --files-only --hash` — `--store r2:mats/experiments` is an rclone
remote, and `lsjson` is the one verb that reports name, size and hash together in a single recursive call
without re-reading object bytes. Each prefix is listed at most once per sweep, failures included: a prefix
that failed to list must not be retried once per file under it. An object whose reported size is negative
(rclone's "size unknown") proves nothing and is dropped from the index.

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

`--json` emits `{"tier1": [...], "tier2": {"<owner>": [...]}, "tier3": [...], "reaped": [...],
"reclaimed": {...}}` — each
tier entry has `repo`, `path`, `branch`, `owner`, `tier`, `kind` (`"worktree"`, `"scratch"` or `"evict"`),
`reason`,
and `action` (`{"kind": "remove"|"prune"|"delete"|"evict"|"inspect", "commands": [...]}`). An instance's messaging
wrapper iterates this (one message per tier-2 owner key, one combined message for tier 3) — **the sweep
never sends anything itself**; delivery is instance work (see "What the instance supplies" below). The
report is silent when there's nothing to flag.

**`reaped` — what the sweep actually removed** (automated-researcher#792). A reaping sweep that prints
only what it *classified* leaves the reader inferring the deletions from a stderr log, where a skip (the
safety net firing correctly) reads identically to a removal. Each record is `{"path", "kind", "outcome",
"detail", "bytes"}` with `outcome` in `removed` / `pruned` / `deleted` / `evicted` / `dry-run` / `skipped`
/ `failed`; the human
report renders the same information under a `## Reaped` section, grouped so the removals lead. It is empty
without `--reap-tier1`. Because the report now states removals, it is emitted **after** the reap runs — the
live per-action stderr log inside the reap is unchanged, so a human watching a long sweep still sees each
action as it happens.

**`reclaimed` — the byte accounting, split by leg** (automated-researcher#856):
`{"verified_on_store_bytes", "tier1_bytes", "unmeasured", "evictable_bytes"}`, rendered as a
`## Reclaimed` line reading *"reclaimed X GB verified-on-store, Y GB tier-1"*. The two legs are reported
apart on purpose — they answer different questions about the box: the tier-1 figure is how much the
lifecycle-keyed reapers are still finding, and the verified-on-store figure is how much they **missed** and
a content check caught anyway. Collapsing them into one number would hide exactly the trend #856 exists to
make visible. `bytes` is measured immediately *before* each delete (apparent size, one count per inode, so
hardlinks aren't double-counted); an action whose size can't be measured is counted in `unmeasured` rather
than as zero, so a small total is never mistaken for a complete one. `evictable_bytes` is what a
`--reap-tier1` run *would* free from the eviction leg, which is what a report-only sweep states instead —
the sensor half of the feature.

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
and re-aged immediately before the delete (see "Non-git scratch" above), and `--evict-verified` files via a
single `unlink` each, re-verified against both the identity *and* the re-read bytes the store proved (see
"Content-verified eviction" above).
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

**A content-verified eviction, by contrast, IS recoverable — that is its entire premise.** The store object
that authorized the delete is named in the reason string, the `## Reaped` detail and the stderr `EVICTED`
line, so recovery is `rclone copy <that object> <the local dir>`. This is why its age bar can be 0 while
scratch's is a week: for scratch, the age is the only evidence there is; here the store *is* the evidence.

**Recovering from a reap.** Tier-1's own definition makes this non-destructive of content by construction:
`merged` means every commit on the worktree's branch already lives in the default branch's history, and
`git branch -d` (never `-D`) refuses to delete a branch that isn't fully merged. Recovery is a `git
worktree add <path> <default-branch>`, or — using the SHA the sweep logs on every reap (path, branch, HEAD
SHA) — `git branch <name> <sha>`.

**Re-create it SPARSE, not full (automated-researcher#805).** Reaping and sparse checkout attack different
halves of the same disk problem and this sweep only owns one of them: reaping moves the *intercept*, sparse
checkout moves the *slope*. A 2026-08-31 measurement on one 225G box found 57G of worktrees — 25 checkouts
each carrying its own copy of a 5.3G `registry/` (~2.2G on disk) against 6.5G of genuinely durable research
data; at ~10 new worktrees/day no sweep cadence can outrun that. So when this sweep's recovery command (or any
convention that creates a worktree of the research repo) runs, create it sparse: `experiment-lifecycle` ships
`sparse_worktree.sh` for exactly this — every top-level dir except `registry/`, plus only the
`registry/<exp>` record(s) the task names, with an explicit `--full` for the rare task that needs all of them.

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
- **Which scratch roots to evict from, and the store to verify against**: `--evict-verified <root>` (the
  roots the instance already names, e.g. its executor-scratch root) plus `--store`. Both are instance
  values; on the box that filed #856 those are `--store r2:mats/experiments` for the experiment roots and
  `r2:mats/archive/work` for archived executor scratch — one `--store` per sweep invocation, so a box
  verifying against two stores runs the leg twice (a store is what bounds where a prefix lookup may find
  proof, so it is deliberately not a list).
- **`REPO_JANITOR_LIVE_SESSIONS_CMD`** — a command that prints one live session id per line (mirroring
  `gpu-job`'s `GPU_JOB_*_CMD` provider-seam pattern). **Unset ⇒ every owner reads as not-live** — the
  fail-safe default: nothing is silently routed to tier 2 without this wired, everything instead surfaces
  to the researcher. It is also the eviction leg's only hold, so name the eviction roots as
  `--worktree-root` too (see "Content-verified eviction" above).
- **`REPO_JANITOR_STORE_LIST_CMD`** — optional; only if the box's store isn't reachable through plain
  `rclone lsjson` (see "Content-verified eviction" above for the shape it must print). A listing that
  fails, times out, or won't parse means nothing under that prefix is ever evicted.
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
  # is an INSTANCE value (checkout path, research repo, worktree roots, temp-dir layout, uid in a path, log
  # path): fill in your own, and see "Non-git scratch" above for what a --scratch-glob may safely look like.
  17 4 * * * python3 <checkout>/plugins/repo-janitor/skills/repo-janitor/scripts/worktree_sweep.py --repo <research repo> --worktree-root '<agent workspace root>' --worktree-root '<research repo>/.claude/worktrees' --fetch --reap-tier1 --scratch-glob '<absolute glob of repro dirs>' --scratch-glob '<absolute glob of per-session scratch>' --evict-verified '<agent workspace root>' --store '<rclone path of the experiment artifact store>' >> <log path> 2>&1
  ```

  The age bars apply as described in "The age bar is per tier" above — 2 days for merged worktrees, 7 for
  unmerged ones and scratch (a daily sweep does not shorten either; it only means an entry is reaped the day
  after it crosses its bar instead of up to a week later). Naming **every** worktree root the box creates
  trees under, harness roots included, is what puts them all under the same tier rules. `--fetch` is what
  keeps the mergedness/identity comparisons against a live `origin/<default-branch>` rather than whatever
  the box last fetched. Roll the timer out with `--dry-run` for a cycle first, per the reap section above.

## Smoke

`scripts/worktree_sweep_smoke.sh` — builds real local git fixtures (no network) covering every tier, the
live-owner tier-1 veto, fail-closed UNKNOWN handling, the silent cases, `--fetch` freshness, `--reap-tier1`
with/without `--dry-run`, the `--json` shape, CLI argument validation, off-allowlist ignored content never
reaching tier 1 (with a `status.showUntrackedFiles=no` config bypass attempt), the merged+identical-residue
tier-1 bar
(automated-researcher#804 — a merged-but-behind worktree whose untracked residue duplicates the default
branch reaches tier 1 and is really removed, while residue that differs from it or sits at a path it lacks
stays reported and survives a real `--reap-tier1`), the merged+allowlisted-residue tier-1 bar
(automated-researcher#840 — allowlisted regenerable/superseded residue reaches tier 1 with the allowlist
named in its reason and is really removed, while one off-allowlist file or a superseded-class basename the
default branch doesn't carry keeps the worktree reported and alive; the fixture repo carries the same
`.gitignore` a real one does, so the regenerable classes arrive IGNORED and the bar is exercised on the
category it actually meets on a box — plus a merged worktree whose only residue is ignored+allowlisted
reaching tier 1 and really being removed, an off-allowlist ignored file still vetoing outright, and the
reap-time re-verification agreeing with classification on both), the per-tier age bar (a merged 3d-old
worktree reaches tier 1 while an unmerged 3d-old one stays silent, each bar movable independently), the
repeatable `--worktree-root` giving a nested harness worktree root the live-owner veto with the owner id
taken from the most specific match, the default branch's ref surviving a reap
of a linked worktree checked out on it, a locked (un-removable) tier-1 worktree failing without blocking
other removals, the squash-merge content-identity alternative bar (including a real `--reap-tier1` pass, a
fail-closed novel-content case, a chmod-only mode-mismatch case, and an untracked-symlink mode-mismatch
case), the per-path submodule-fact degradation on an unmapped gitlink (including a tab-quoted path carrying
a genuinely initialized submodule, which the NUL-safe fallback parse must still find), the human
report's same-reason collapsing, and `--scratch-glob` end to end (stale reaches tier 1 and is really
deleted; fresh is silent; an old directory mtime with a freshly-written file inside is silent; a symlink,
its target, and a swept repo's own worktree all survive a real `--reap-tier1`; `--dry-run` deletes nothing;
every unsafe glob shape is rejected up front; and the `## Reaped` / `reaped` records name what was removed),
and content-verified eviction end to end (automated-researcher#856 — the store is stood in for through the
`REPO_JANITOR_STORE_LIST_CMD` seam, which is exactly why that seam exists: `rclone` is not reachable on a
CI runner and this leg's contract is what the sweep does with the *listing*. Bytes proven by a recomputed
checksum reach tier 1 under a store layout that does not mirror the local path and are really evicted, with
the reason naming the checksum that proved them; rclone's `MD5` and `SHA-1` key spellings verify exactly as
the lowercase ones do; while name+exact-size with *no* comparable checksum, an incomparable-only algorithm
(crc32/quickxor), a *disagreeing* checksum, a record contradicting itself across two spellings of one
algorithm, a size disagreement, an absent object, a failed listing, a file directly under
the root, and a live owner's file are all kept and survive a real `--reap-tier1`; `evict_unlink` is driven
directly as a unit — it removes only the verified inode, and a stat-key or link-count disagreement aborts
and restores every staged link, leaving no `.repo-janitor-evicting.*` entry behind; a file below `--min-size`,
a symlink, and everything under `registry/` of a git tree are never even classified, while a plain
`registry/` directory outside any checkout still evicts (the veto is git-tree-keyed, not name-keyed); a
hardlinked pair is ONE tier-1 entry that unlinks every link and counts the bytes once, while an inode with
a link outside the scanned roots is kept; `--dry-run` evicts nothing; the `reaped` records and the
`## Reclaimed` line split verified-on-store from tier-1 bytes; and every incomplete/unsafe invocation
— `--evict-verified` without `--store`, `--store` without a root, a relative or `/` or unnormalized root, an
unparseable `--min-size` — is rejected up front).
