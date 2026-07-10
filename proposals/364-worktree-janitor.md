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
                   [--json]                      # machine-readable report (default: human-readable text)
                   [--reap-tier1] [--dry-run]    # perform (or log-only) tier-1 deletions; see "The reap action"
```

For each `--repo`, enumerate every entry of `git worktree list --porcelain` (this includes the repo's own
primary checkout as one entry, marked `is_main`). Per entry, compute deterministically — no state, no
memory of past sweeps; **the git state IS the state**, recomputed from scratch every run:

- `dirty` — `git status --porcelain` is non-empty (tracked modifications/staged changes).
- `untracked` — count of `??` entries in that same status.
- `merged` — (linked worktrees only) is the worktree's HEAD an ancestor of the repo's default ref?
  Default ref resolves to `origin/<default-branch>` if that remote-tracking ref exists in the repo, else
  local `<default-branch>` — so a sweep works offline against whatever the repo last fetched.
- `age_days` — days since the worktree's HEAD commit (`git log -1 --format=%ct`).
- `behind` / `ahead` — (main worktree only) commits between local HEAD and the default ref, in each
  direction — the shared-checkout drift the issue's example hit.
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
whenever `dirty OR untracked>0 OR behind>0 OR ahead>0`; otherwise silent.

**Linked worktree, prunable** (working dir gone) — **tier 1** unconditionally.

**Linked worktree, else:**
- `merged AND !dirty AND untracked==0 AND age_days >= min_age_days` → **tier 1** ("safe to reap" — no one
  is asked; see *The reap action* for what "safe" authorizes).
- else if `dirty OR untracked>0 OR (!merged AND age_days >= min_age_days)` — a real signal (stray content,
  or a stale branch nobody is continuing):
  - owner candidate is **live** → **tier 2**, routed to that owner: "these files are in your tree —
    investigate and deal, or escalate." Ownership assigns *investigation responsibility*, not a memory
    test (#364 shaping) — a context-cleared session can still `git log`/read the files/cross-reference the
    registry and propose a disposition; a bare "not mine, dunno" is not itself a disposition. **Guard,
    pinned out-of-scope**: a session's tier-2 answer alone never deletes anything — only deterministic
    tier-1 evidence or explicit researcher approval does (enforced structurally: this script has no code
    path that deletes anything but a re-verified tier-1/prunable entry; a tier-2 investigation result
    becomes a *new* sweep input only insofar as the owner's actions change the underlying git state before
    the next weekly sweep recomputes it).
  - owner not live, or no owner candidate at all (includes every executor-style path whose top segment
    never matches a live session, and every path outside `--worktree-root`) → **tier 3**, the residual the
    issue reserves for the researcher: ownerless items, orphaned worktrees with no live session, and (per
    above) shared-checkout decisions.
- else (merged-but-too-fresh, or unmerged-but-clean-and-recent) → silent. An in-progress branch or a
  just-merged worktree still inside its grace window is not a problem; it will re-surface next week if it
  is still around then, which is the whole "re-sweep is the retry" design (no state DB needed to know this
  — the same recompute lands the same verdict until the underlying git state changes).

### Report format (product-owned)

Default output is a human-readable text report split into the three tier sections above (tier 2
sub-grouped by owner id), each entry showing path, branch, the facts that triggered its tier, and — for
every non-tier-1 entry — the exact `git -C <repo> worktree remove <path>` (+ `git branch -d <branch>` where
merged) command a session would run once its disposition is approved, so the chat-approval flow in tier 3
(and an owner's own resolution in tier 2) is copy-paste, not free-hand. `--json` emits the identical data
as `{"tier1": [...], "tier2": {"<owner>": [...]}, "tier3": [...]}` so an instance's messaging wrapper can
iterate it programmatically (one fleet-message per tier-2 owner key, one combined message for tier 3) —
that iteration and the actual send are instance work, out of scope here. The report is silent (empty
sections, one summary line) when there is nothing to flag — no news is not sent as news.

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
one-time cleanup the issue calls for, spending judgment once rather than automating it. Rollback is the
standard one-commit revert; the plugin is inert until an instance schedules it (no other code path calls
it), so removing/disabling the plugin has no effect on any other part of the product.
