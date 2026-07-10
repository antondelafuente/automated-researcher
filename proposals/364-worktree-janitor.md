# Proposal: worktree/repo janitor — deterministic sweep + three-tier triage (#364)

> The canonical design doc (ADR + PR description). Reviewed by `--scaffold` before build. Lands on main.

## Problem

Worktrees and repo state on an instance accumulate silently: abandoned worktrees from interrupted runs,
agent scratch written into a persistent tree, a shared checkout drifting behind origin. Nothing in the
flow notices — the researcher discovers the sprawl by tripping over it. State found on the deploying box
2026-07-10 (`git worktree list` off `~/research-lab`): ~40 worktrees; stale unmerged branch families
(`codex-*trigger*`, `toy-reason-*`, SFT-paper era); per-agent trees holding scratch (a stray `TEMP.md` +
untracked registry dirs in one, a stray handoff file in another, a modified script + deleted tracked files
in a third); the shared checkout itself behind origin and not fast-forwardable, with local modifications
and untracked strays.

Every *happy* path already cleans up — `ship-change` reaps its worktree at `finish`, the
design-in-worktree rule keeps agents off the shared checkout. What leaks is the irreducible remainder: a
process that dies before its cleanup step, a session interrupted mid-run, residue that predates a rule.
No workflow patch prevents "the process died before cleanup" — a backstop has to notice orphans on a
schedule, the worktree analog of `pod_reaper.sh` (`gpu-job`) and #285's (not yet built) session janitor.

Issue #364 was shaped to `ready` in a live conversation with the researcher (2026-07-10); the shaping
comment and body pin the decisions below as binding, not up for reinterpretation by this build or its
reviews: weekly cadence, three-tier triage, fire-and-forget message delivery, reset-safe ownership
semantics, and an explicit out-of-scope list (no auto-reap, no state DB, no lease model).

## Approach

**Product/instance split (same seam as #285/pod_reaper):** this PR ships the **product** half only — a
new `repo-janitor` plugin whose sweep script owns the classification logic, the tier semantics, and the
report format. The **instance** supplies: which repo(s) + worktree root to point it at, how to enumerate
live sessions and message them, and the timer that invokes it. None of that instance wiring lands here;
`repo-janitor`'s `SKILL.md` documents the seam contract so a consuming instance can wire it same-day.

### The sweep: `worktree_sweep.sh`

```
worktree_sweep.sh --repo <path> [--repo <path> ...]
                   [--worktree-root <path>]      # default: unset -> ownership never derived
                   [--owner-depth N]             # default 1 (path segments under root -> candidate owner id)
                   [--min-age-days N]            # default 7
                   [--default-branch <name>]     # default: main
                   [--fetch]                     # default off: `git fetch origin` each repo before comparing
                   [--json]                      # machine-readable report (default: human-readable text)
                   [--reap-tier1] [--dry-run]    # perform (or log-only) tier-1 deletions; see "The reap action"
```

For each `--repo`, enumerate every entry of `git worktree list --porcelain` (this includes the repo's own
primary checkout as one entry, marked `is_main`). Per entry, compute deterministically — no state, no
memory of past sweeps; **the git state IS the state**, recomputed from scratch every run. **Every fact
below is fail-closed tri-state (true / false / UNKNOWN), never binary**: a `git status`/`log`/`merge-base`
invocation that errors, times out, or returns unparseable output leaves that fact `UNKNOWN` for that
worktree — the classifier (next section) treats any `UNKNOWN` fact as disqualifying from tier 1 and routes
the entry to tier 3 tagged "inspection needed: `<command>` failed," mirroring `pod_reaper.sh`'s own rule
that an unlistable/unreadable result is reported, never silently treated as the safe value:

- `dirty` — `git status --porcelain` is non-empty (tracked modifications/staged changes); a nonzero exit
  or unparseable output is `UNKNOWN`, not `false`.
- `untracked` — count of `??` entries in that same status; tied to the same `UNKNOWN` fate as `dirty`.
- `merged` — (linked worktrees only) is the worktree's HEAD an ancestor of the repo's default ref? Default
  ref resolves to `origin/<default-branch>` if that remote-tracking ref exists in the repo, else local
  `<default-branch>`. A `merge-base --is-ancestor` call that errors for any reason other than a clean "not
  an ancestor" (exit 1) — e.g. the ref not resolving at all — is `UNKNOWN`, not `false`.
- `age_days` — days since the worktree's HEAD commit (`git log -1 --format=%ct`); an empty/unparseable
  timestamp is `UNKNOWN`.
- `behind` / `ahead` — (main worktree only) commits between local HEAD and the default ref, in each
  direction — the shared-checkout drift the issue's example hit. **Freshness (Finding 5):** by default this
  compares against whatever the repo last fetched, and says so in the report ("origin state as of last
  fetch — pass `--fetch` for a live check"), so a stale cache is never silently presented as current. With
  `--fetch`, the sweep runs a plain read-only `git fetch origin` first; a fetch failure does not fall back
  to the stale ref silently — it marks `behind`/`ahead` `UNKNOWN` for that repo's main worktree ("could not
  verify freshness against origin — fetch failed"), which routes it to tier 3 rather than reporting a
  number that might already be wrong.
- `prunable` — the worktree's administrative record exists but its working directory is gone (a worktree
  someone `rm -rf`'d by hand instead of `git worktree remove`). Always safe to fold into tier 1 (nothing to
  lose — `git worktree prune` reclaims only bookkeeping) regardless of merge state.
- **owner candidate** — only when `--worktree-root` is given and the path sits under it: the first
  `--owner-depth` path segment(s) under the root (default depth 1, e.g. `~/ws/<name>/…` → `<name>`; a
  depth-1 default naturally sends anything under a shared executor namespace like `~/ws/run/<exp>` to
  candidate id `run`, which will not match a live session name and correctly falls through to tier 3 —
  no special-casing of any particular namespace convention is baked into the product). A path outside the
  root, or no root given at all, has no owner candidate.
- **owner liveness** — a candidate owner is "live" iff its id appears in the list printed by
  `REPO_JANITOR_LIVE_SESSIONS_CMD` (an instance-supplied seam command, mirroring `gpu-job`'s
  `GPU_JOB_*_CMD` provider-seam pattern). **Unset seam ⇒ empty list ⇒ every owner reads as not-live** —
  the fail-safe default when an instance hasn't wired session enumeration: nothing is silently routed to
  tier 2, everything instead surfaces to the researcher (tier 3) where a human is in the loop.

### Triage-tier semantics (deterministic, product-owned)

**Main/shared worktree** — never tier 1 (you cannot "safe-reap" the shared checkout). Flagged to **tier 3**
whenever `dirty OR untracked>0 OR behind>0 OR ahead>0 OR any fact UNKNOWN`; otherwise silent.

**Linked worktree, prunable** (working dir gone) — **tier 1** unconditionally (a bookkeeping-only prune
carries no live-owner question — there is no working directory left for anyone to be using).

**Linked worktree, any required fact `UNKNOWN`** (a `status`/`log`/`merge-base` call failed) — never tier 1
regardless of what the other facts show; routed to tier 2 (if a live owner is derivable) or tier 3,
tagged "inspection needed: `<command>` failed for this worktree" (Finding 4: fail-closed on tool failure,
not just on the facts the tool successfully read).

**Linked worktree, all required facts resolved.** First decide whether there is anything to flag at all —
`flaggable = dirty OR untracked>0 OR (!merged AND age_days >= min_age_days) OR (merged AND !dirty AND
untracked==0 AND age_days >= min_age_days)` (i.e. stray content, a stale unmerged branch, or a
deterministically-idle merged one). If not `flaggable`, **silent** — an in-progress branch or a
just-merged worktree still inside its grace window is not a problem; it will re-surface next week if it is
still around then, which is the whole "re-sweep is the retry" design (no state DB needed to know this — the
same recompute lands the same verdict until the underlying git state changes). If `flaggable`:

- `merged AND !dirty AND untracked==0 AND age_days >= min_age_days` **AND (no owner candidate, or the
  candidate owner is not live)** → **tier 1** ("safe to reap" — no one is asked; see *The reap action* for
  what "safe" authorizes).
- `merged AND !dirty AND untracked==0 AND age_days >= min_age_days` **AND the candidate owner IS live** →
  **tier 2**, not tier 1. **A live owner is an unconditional tier-1 veto** (Finding 2): a worktree that
  reads as merged+clean+old can still be a persistent per-agent home that simply hasn't diverged from a
  quiet default branch recently (e.g. an `agent/<name>` branch kept fast-forwarded) — commit-recency is not
  proof of disuse when a live session is attached. The deterministic bucket is for content nobody is
  actively holding, not merely content that "looks" idle by commit timestamp; routed to the owner with its
  own distinct reason ("merged+clean+old, but you're live — confirm this is really unused before it's
  reaped") so they get the same investigate-or-escalate lane as any other tier-2 entry, rather than having
  it silently deleted out from under them.
- `dirty OR untracked>0 OR (!merged AND age_days >= min_age_days)` (stray content, or a stale branch nobody
  is continuing) **AND the candidate owner is live** → **tier 2**, routed to that owner: "these files are
  in your tree — investigate and deal, or escalate." Ownership assigns *investigation responsibility*, not
  a memory test (#364 shaping) — a context-cleared session can still `git log`/read the files/cross-
  reference the registry and propose a disposition; a bare "not mine, dunno" is not itself a disposition.
  **Guard, pinned out-of-scope**: a session's tier-2 answer alone never deletes anything — only
  deterministic tier-1 evidence or explicit researcher approval does (enforced structurally: this script
  has no code path that deletes anything but a re-verified tier-1/prunable entry; a tier-2 investigation
  result becomes a *new* sweep input only insofar as the owner's actions change the underlying git state
  before the next weekly sweep recomputes it).
- everything else `flaggable` (owner not live, or no owner candidate at all — includes every
  executor-style path whose top segment never matches a live session, and every path outside
  `--worktree-root`) → **tier 3**, the residual the issue reserves for the researcher: ownerless items,
  orphaned worktrees with no live session, and (per above) shared-checkout decisions.

### Report format (product-owned)

Default output is a human-readable text report split into the three tier sections above (tier 2
sub-grouped by owner id), each entry showing path, branch, and the facts that triggered its tier. The
**suggested command differs by what's actually safe to run** (Finding 7 — a bare `git worktree remove`
refuses a dirty/untracked worktree, so printing it unconditionally would hand out a command that fails):
a tier-1 or prunable entry (nothing left to lose) gets the exact ready-to-run removal — `git -C <repo>
worktree remove <path>` (+ `git branch -d <branch>` when merged) for tier 1, `git -C <repo> worktree prune`
for prunable. A tier-2/tier-3 entry carrying dirty or untracked content instead gets an **inspection**
command (`git -C <path> status`, `git -C <path> log -1`) and a note that a removal command is offered only
once that content has an explicit disposition (discarded, committed, or moved out) — never a
premature delete command for content nobody has looked at yet. `--json` emits the identical data as
`{"tier1": [...], "tier2": {"<owner>": [...]}, "tier3": [...]}`, each entry's `action` field holding
whichever of the two command kinds applies, so an instance's messaging wrapper can iterate it
programmatically (one fleet-message per tier-2 owner key, one combined message for tier 3) — that
iteration and the actual send are instance work, out of scope here. The report is silent (empty sections,
one summary line) when there is nothing to flag — no news is not sent as news.

**Relationship to `wf.sh gc` (Finding 3).** `agentic-engineering`'s `wf.sh gc` already reaps
ship-change's own worktrees with PR-aware protections (checks the PR is closed/merged and the local HEAD
matches what was actually reviewed before removing). This sweep does not duplicate that lookup — it has no
GitHub dependency and works from git state alone — but its tier-1 bar is a strict subset of `gc`'s safety
condition: `merged` here means the *entire* worktree HEAD is already an ancestor of the default branch, so
there is no unreviewed content `gc`'s PR-head check could have caught that this misses. The two coexist as
two independent backstops, not a replacement: an instance should run `wf.sh gc` for ship-change worktrees
specifically (it has stronger, PR-state-aware evidence available for that specific case) and this sweep as
the broader backstop that also safely catches whatever `gc` missed — exactly the "irreducible remainder"
framing in the Problem section. `SKILL.md` states this relationship explicitly so an instance doesn't wire
the two as competing/conflicting cleanup paths.

### The reap action — respecting "no auto-reap"

`--reap-tier1` performs the deletions for entries this same invocation just classified as tier 1
(prunable → `git worktree prune`; merged+clean+old → re-verify the three conditions immediately before
`git worktree remove <path>` as a defense against the state changing mid-sweep, then `git branch -d
<branch>` best-effort). `--dry-run` (only meaningful with `--reap-tier1`) logs every removal it would
perform without touching anything — the pod-reaper rollout discipline ("roll out dry-run first"), reused
here even though there is no lease/lock to race against.

**This flag is never passed by the instance's standing weekly timer by default.** The issue's out-of-scope
list is explicit: deletion happens only on researcher approval, *or* on deterministic tier-1 evidence *the
researcher has blanket-approved* — i.e. `--reap-tier1` exists for a researcher who has explicitly decided
"always reap the deterministic bucket," wired as a deliberate, documented instance-level opt-in (an env
toggle on the systemd unit), never the product's shipped default. Without that opt-in, every sweep —
scheduled or on-demand — is report-only, full stop. The **first run is the one-time cleanup** of the
current debt: run once on demand (no `--reap-tier1`), the researcher reviews the report in-chat, and the
session executes the approved subset with the printed commands — exactly the tier-3 chat-approval flow,
spent once on the whole backlog rather than automated.

### Plugin layout

New plugin `plugins/repo-janitor/`:
- `.claude-plugin/plugin.json` (v0.1.0)
- `skills/repo-janitor/SKILL.md` — the sweep contract, the tier semantics, the seam contract
  (`REPO_JANITOR_LIVE_SESSIONS_CMD`) an instance wires, and the explicit "timer never passes
  `--reap-tier1`" rule.
- `skills/repo-janitor/scripts/worktree_sweep.sh` — the sweep + reap implementation above.
- `skills/repo-janitor/scripts/worktree_sweep_smoke.sh` — offline fixture repo(s) covering: tier-1
  (merged+clean+old, and prunable), tier-2 (stray content under a live owner), tier-3 (stray content under
  a not-live/no owner, a stale-unmerged-and-old branch with no owner, and shared-checkout drift), the
  silent cases (merged-but-fresh, unmerged-but-fresh), `--json` shape, and `--reap-tier1`
  (with/without `--dry-run`) actually removing only what tier 1 says and nothing else.
- `.aar-ci/checks.sh` gains a stanza running the new smoke (same pattern as the `pod_reaper`/
  `run_supervision_record`/`reap_session` smokes already wired there).
- `README.md` and `.claude-plugin/marketplace.json` gain the `repo-janitor` entry alongside the other
  installable plugins (Finding 6) — the existing checks.sh stanza (README install-namespace-vs-marketplace
  check, and the marketplace-declared-plugin-must-exist smoke) already enforces this stays in sync, so a
  missed entry fails the tracked checks rather than shipping silently undiscoverable.

## Alternatives considered

- **A state DB of past sweep reports (to diff "what's new since last week").** Rejected — pinned
  out-of-scope. The git state IS the state; every sweep recomputes fresh, and "the re-sweep is the retry"
  is exactly what makes a database unnecessary: an unresolved item just reappears.
- **A lease/expiry model like `pod_reaper`.** Rejected — pinned out-of-scope. Pods need a lease because
  they bill hourly; a worktree just sits on disk. No billing pressure means no need for the lock/refresh
  machinery that model exists to serialize against.
- **Auto-reap tier 1 by default from the standing timer.** Rejected — pinned out-of-scope ("no auto-reap").
  `--reap-tier1` exists as an explicit, opt-in escape hatch for a researcher who has already blanket-
  approved the deterministic bucket, not as shipped default behavior.
- **Let a tier-2 owner's investigation answer authorize a delete directly (session says "not mine" →
  reaped).** Rejected — pinned out-of-scope guard. An investigated recommendation beats "not mine, dunno,"
  but both only escalate; the only two things that ever authorize a delete are re-verified tier-1 evidence
  and explicit researcher approval.
- **Hardcode this box's `~/ws/<name>` / `~/ws/run/<exp>` convention into the owner-derivation logic.**
  Rejected — that convention lives in this box's instance `AGENTS.md`, not in the product. The
  path-segment-under-root + configurable depth scheme reproduces the same routing (executor paths fall
  through to tier 3 because "run" won't match a live session) without the product assuming any particular
  deployment's directory naming.
- **Have the product also perform message delivery** (call a fleet-message command directly from the
  sweep script). Rejected — the issue's product/instance split puts session enumeration *and* messaging on
  the instance side; the product's contract ends at emitting `--json` an instance wrapper can iterate.
- **Move the classifier to `agentic-engineering`** (the "would a video-game team building this way have it"
  test, applied to worktree hygiene in general). Considered and rejected for *this* issue specifically:
  #364 was filed and shaped to `ready` in `automated-researcher` itself, explicitly as "the same seam as
  #285" — #285 (the session-janitor backstop) is also an `automated-researcher` issue, and its own stated
  precedent, `pod_reaper.sh`, already ships in `automated-researcher/plugins/gpu-job` despite disposable-GPU
  hygiene being just as "generic-sounding" as worktree hygiene. The researcher's shaping conversation placed
  this alongside that existing product precedent, not alongside `agentic-engineering`'s own worktree
  handling (`wf.sh gc`, which stays put and is addressed on its own terms above). Reopening the product/team
  boundary for this class of tooling is a real question (see AGENTS.md's "would a video-game team" test) but
  is a decision for the researcher to make prospectively across GPU-job and worktree hygiene together, not
  one this single implementation should make unilaterally against where its own issue was already filed and
  shaped.

## Blast radius

- **Product (`automated-researcher`):** new, self-contained plugin `repo-janitor` (script + smoke +
  SKILL.md + `.claude-plugin/plugin.json`); one `.aar-ci/checks.sh` stanza wiring its smoke into the
  tracked check profile; root `.claude-plugin/marketplace.json` gains the new plugin entry. No existing
  plugin, skill, or script changes.
- **Instance (NOT this repo, follow-up work):** the systemd timer, the concrete `--repo`/`--worktree-root`
  values for this box, the `REPO_JANITOR_LIVE_SESSIONS_CMD` seam (this box's fleet session-enumeration),
  and the fleet-message delivery for tier 2/3 report contents. Documented here as the seam this plugin
  expects; wired separately, path-scoped, in the instance's own repo/config.

## Rollout + rollback

Ships report-only by construction — `--reap-tier1` is opt-in and the timer wiring (instance, follow-up)
defaults to omitting it. The very first invocation on this box is expected to be an on-demand, no-flag run
against the current ~40-worktree debt, reviewed and executed in-chat per the printed commands — the
one-time cleanup the issue calls for, spending judgment once rather than automating it. Rollback of the
*plugin code* is the standard one-commit revert; the plugin is inert until an instance schedules it (no
other code path calls it), so removing/disabling the plugin has no effect on any other part of the
product.

**Recovering from a `--reap-tier1` deletion (Finding 8).** Tier-1's own definition makes this
non-destructive of content by construction: `merged` means every commit on the worktree's branch already
lives in the default branch's history, so nothing unique is lost when the worktree directory goes away, and
`git branch -d` (used, never `-D`) refuses to delete a branch that is not fully merged — it cannot discard
history the worktree removal didn't already prove redundant. Recovery is therefore always available from
the default branch itself (`git worktree add <path> <default-branch>` recreates a working copy of the same
content) or, for the branch ref specifically, `git reflog`/`git branch <name> <sha>` using the SHA the
sweep logged before deleting (the log line for every reap records path, branch, and HEAD SHA) — no
dedicated undo machinery is needed beyond "the sweep's own log line has the SHA."
