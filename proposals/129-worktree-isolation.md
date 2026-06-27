# Proposal: Per-agent / per-experiment worktrees for the research-lab tree (#129)

> The canonical design doc (ADR + PR description). Reviewed by `--scaffold` before build. Lands on main.
> Step 1 of 2. Step 2 (experiments-as-reviewed-PRs, #130) builds on the `run/<exp>` branch this defines.
> Design-only: this PR lands the design; implementation follows as spawned `ready` issues.
>
> **Scope after the #129 design review:** this is **instance work** — it modifies the existing fleet-controller
> launchers *in place*, it does NOT move them into the product. Whether the fleet-controller layer graduates
> from instance to product is a separate decision (**#136**). This proposal provides only the **mechanism**
> (per-agent/per-experiment worktrees + the `run/<exp>` branch); the experiment **close/review/reap contract**
> that rides on that branch is owned by the experiment skills and **#130**, not here.

## Problem

Every AAR agent on this box works in **one shared `~/research-lab` checkout**. Two failure modes follow, and they bite constantly once several agents run experiments in parallel:

1. **Cross-agent dirt.** Each agent sees every other agent's uncommitted files. The recurring symptom is an agent (or Anton) staring at "19 modified files I don't recognise" with no way to tell which experiment they belong to, whether they're safe to commit, or whose they are. A stray `git add -A` sweeps a peer's in-flight work.
2. **Shared-branch collisions.** The checkout can only be on one branch at a time, so when one agent switches it to a feature branch, it switches for *everyone* — work merged to `main` stops appearing on disk for all the other agents (the branch-parking incident: a transcript merged to `main` was invisible because the shared tree sat on a Codex paper branch). "I pushed it to main" stops matching "agents can see it."

Both reduce to one root cause: **shared mutable working-tree state** — one working directory, one staging index, one current-branch, for all agents.

## Approach

Give every agent its **own git worktree** of research-lab, so no agent shares a working tree or index with another. The shared `~/research-lab` checkout is demoted to a **read-only canonical surface pinned on `main`** (where merges land; never parked on a branch again — that discipline is what kills the branch-parking class of bug).

- **Persistent fleet workers:** a stable worktree `~/ws/<name>` that is the worker's isolated cwd. Its branch `agent/<name>` is **resettable local scratch** — fast-forwarded to `main` for reading, **never a durable commit/review unit.**
- **Experiment executors:** a disposable worktree `~/ws/run/<exp>` on a short-lived branch `run/<exp>`, created at dispatch and removed at close. `run/<exp>` is the **seam to #130** — it becomes the experiment's PR.

**The worktree doubles as the agent's cwd.** Claude Code keys conversation history off the working directory — the only reason each agent currently needs a separate `~/claude-N` folder. A per-agent worktree is already a unique directory, so it serves both jobs (isolation + history separation) and absorbs the `~/claude-N` trick.

**Net invariant:** `main` only ever receives merged, reviewed work, so the shared read surface stays clean; all in-progress churn lives on a branch inside one agent's worktree, invisible to every other agent. "19 unknown dirty files" becomes structurally impossible.

### Load-bearing decisions (revised for the design review)

1. **Worktrees, not full clones.** Worktrees share one object store (disk-cheap, instant) where N clones would each carry a full copy + their own remote sync. The one constraint: two worktrees can't both check out `main` → each worker sits on its own `agent/<name>` scratch branch, fast-forwarded to `main` for reading. (Validated: a throwaway worktree was created, dirtied, and removed with zero leakage into the shared tree.)
2. **Durable changes go on short-lived task/experiment branches — NOT the agent identity branch.** *(review F3)* The worktree gives **isolation**; it does not change the review unit. A worker that makes a durable change branches a short-lived `task/<n>` (or, for a run, `run/<exp>`) off `main` → PR → cross-family review → merge, exactly as `research-lab/AGENTS.md` already prescribes. `agent/<name>` carries no reviewable commits; it is scratch the worker can reset to `main` at any time. This keeps the durable unit = the change, not the agent.
3. **`~/research-lab` stays the canonical `main` surface**, never switched to a branch again.
4. **Modify the existing instance launchers in place.** *(review F1)* The fleet-controller launchers (`new-claude.sh`, `dispatch-claude.sh`, `manage-aar`) are instance/deployment tooling today (#111). This proposal edits them in place to add worktree isolation. It does **not** move them into the product or assert they are product — that graduation is **#136**, with its own generic design. Instance specifics (lab path, worktree root) become config (`AAR_LAB`, `AAR_WS`) so the change is product-shaped if/when #136 lifts it.
5. **`run/<exp>` is the mechanism; the contract is #130's.** *(review F2)* This proposal defines only the branch/worktree the executor works in. *What* gets committed, *how* it's reviewed at close, and *when* it merges is the experiment lifecycle's contract — it belongs in `run-experiment`/`design-experiment` and is designed in **#130**, not buried in launcher text here.

### What gets built (spawned `ready` issues — not this PR)

- **Launcher: per-worker worktree.** `new-claude.sh` ensures `~/ws/<name>` exists (reuse if present), launches the agent there. **cwd migration is fresh/handoff-only, never a silent break** *(review F5)*: a `restart --continue` keeps resuming the **old** `~/claude-N` cwd (its history slug is unchanged); a worker moves to a worktree only via an explicit fresh start or a one-time history shim — because changing the cwd silently changes the conversation-history slug and would orphan a continue-restart.
- **Launcher: per-executor worktree + conservative reap.** `dispatch-claude.sh` creates `~/ws/run/<exp>` on `run/<exp>`, launches the executor, and at reap **guards before removing: worktree clean AND branch pushed at HEAD**, with an explicit `--force` override for genuine cleanup. (Replaces the current draft's unguarded `worktree remove --force || rm -rf`.) The **richer evidence-gated reap** (verifying close artifacts) waits for **#130** to define the close contract — #129 must not reap against an evidence contract that does not exist yet *(review F4)*.
- **Slug contract.** A shared `aar_slug()` validates `<name>`/`<exp>` before they're used as paths, git refs, or tmux names — reject path separators, `..`, whitespace, and characters hostile to git-ref/tmux/filesystem *(review F6)*. Names that fail are rejected at create, never at `rm -rf`.
- **Config seam.** `AAR_LAB`, `AAR_WS` with this-instance defaults.
- **manage-aar** updates so a restarted worker re-attaches its existing worktree consistently with the F5 migration rule.

## Alternatives considered

- **Full clone per agent.** Simpler (each can sit on `main`), but more disk + a separate remote sync per clone. Rejected: worktrees give the same isolation while sharing the object store.
- **Durable commits on a stable `agent/<name>` branch.** Tempting (one branch per worker), but it makes *agent identity* the review unit and lets unrelated changes pile on one branch, against the per-change convention. Rejected per review F3 — `agent/<name>` is scratch only.
- **Move the launchers into the product now.** Rejected per review F1 — that needs the generic controller-fleet design (#136), which this issue should not trigger as a side effect.
- **Status quo (one shared tree, path-scoped discipline).** The problem itself; error-prone and does nothing for shared-branch collisions.

## Blast radius

- **Instance / fleet-controller machinery**, not the shipped research product or experiment science. The change rewrites a core working-tree convention, so the spawned work MUST update **every surface that encodes the old one** — missing any leaves agents following stale guidance:
  - **launchers:** `new-claude.sh`, `dispatch-claude.sh`.
  - **restart machinery** *(review F3)*: `restart-fleet.sh`, `restart-self.sh`, `start-orchestrator.sh` — these hardcode `~/claude-N` cwd and would migrate workers *back* off their worktrees; `claude-0` (the always-on controller in `$HOME`) is explicitly exempted with a safe rule.
  - **boot/constitution guidance** *(review F2 — load-bearing)*: `~/CLAUDE.md` ("all AARs share ONE working tree") and `~/AGENTS.md` ("all AARs share one `~` working tree and one staging index") must be rewritten to the per-worktree convention, or zero-context agents keep following the shared-tree contract after the launchers change.
  - **skill + map docs** *(review F5)*: the `manage-aar` dispatch section (still describes `~/.aar-dispatch/<exp>-exec-<runid>/`) and the `README.md` box-machinery row.
- Changes where an agent's **cwd** can live (`~/claude-N` → `~/ws/<name>`), which moves the conversation-history slug — handled fresh/handoff-only per F5 so a continue-restart never silently orphans a conversation. Existing `~/claude-N` histories are untouched.
- **No change** to research-lab content, the registry schema, or any experiment.
- **Seams:** `run/<exp>` is the interface to **#130** (which owns the close/review/reap *contract*); the product-vs-instance home of the launchers is **#136**. This proposal touches neither contract — only the mechanism.

## Rollout + rollback

- **Cutover preflight (blocks the pin)** *(review F1)*: `~/research-lab` can only be pinned to a clean `main` once the **existing** dirty/ahead state is resolved — today it is `ahead 4` with modified `journal/writeup/*` and `registry/*`. The preflight must, for every dirty/ahead path, **attribute it, move it to an owner's worktree/branch, or merge it through the lab PR path** — and refuse to pin until the tree is clean and at `origin/main`. (This is the loose paper state we already flagged, now a hard gate.)
- **Staged.** Apply to NEW launches first so running sessions aren't disrupted. Persistent-worker migration is fresh/handoff-only (F5), so no running conversation is broken.
- **Smoke first.** Validate end-to-end with one trivial throwaway experiment (dispatch → worktree → records on `run/<exp>` → fail-closed reap) before the real wave.
- **Rollback is cheap.** Revert the launchers to cwd-only behavior; worktrees are removable with no data loss *because the reap is fail-closed* (branch pushed before removal). No history migration to undo.

## Coordination, scope-home, and rollback (added for the merge-gate review)

- **Duplicate-launch detection survives isolation — via pushed claims, not the shared-tree peek** *(review F1, HIGH)*. The shared tree's one coordination *benefit* was that a peer's in-flight `CLAIMED_BY` and uncommitted work were visible, catching duplicate launches. Isolation removes that visibility, so the claim contract moves to the **remote**, which is strictly more reliable: a launch **preflight requires a visible claim** before dispatch — an existing `run/<exp>` branch/PR (and the experiment's issue) is the claim, and `CLAIMED_BY` is **committed + pushed** (discoverable by every agent via `origin`), never an uncommitted file only visible inside one tree. Dispatch refuses if a `run/<exp>` branch/PR/issue already exists. This is a hard part of the spawned launcher work, not an afterthought.
- **Design-home vs implementation-home** *(review F2)*. This design *doc* lands in `automated-researcher/proposals` only because that is the available cross-family review surface (the instance has no repo). The *implementation* edits the instance launchers in the home folder directly; its merge authority is the instance, governed by the instance-vs-product boundary in **#136**. The spawned units are **instance-scoped**, not product ship-change runs.
- **`close-experiment.sh` is a prototype to retire, not a live contract** *(review F3)*. A `close-experiment.sh` draft was written during this design exploration and sits in the home folder implementing a `run/<exp>` close/review/merge flow. It is **not** an authoritative contract: the spawned work either **removes it** or folds it into **#130** (which owns the close/review/reap contract), so there is no competing duplicate when `run/<exp>` lands.
- **Rollback preflight for worker worktrees** *(review F4)*. Rollback is data-loss-free only after a per-`~/ws/<name>` preflight: each worktree must be **clean, or its state transferred to a task branch, or the owner explicitly approves** before the worktree is removed or its cwd rolled back. `agent/<name>` is scratch, but it may hold unpushed live work; rollback never blind-removes it.
