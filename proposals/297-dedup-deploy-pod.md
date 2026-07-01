# Proposal: De-duplicate deploy_pod.py — one canonical copy so fixes propagate (#297)

> The canonical design doc (ADR + PR description). Reviewed by `--scaffold` before build. Lands on main.

## Problem

`deploy_pod.py` — the pod-acquisition script (it hits the RunPod API to CREATE a pod, box-side) — has
existed as multiple on-disk copies, and a fix in one has not reached the others. The provisioning gotchas
this script guards against (disk-size default, `ports==None`, hardcoded `containerDiskInGb`, the #278
mid-create abort trap) are exactly the class that gets silently re-hit when a stale fork is the one a driver
actually runs. The copies observed on this instance:

- **Canonical:** `plugins/gpu-job/skills/gpu-job/scripts/deploy_pod.py` (this repo) — 27 KB, current:
  region-tiering, `--selftest`, the pod lease, the mid-create abort trap.
- **`research-lab/registry/pipelines/lib/deploy_pod.py`** — **a symlink** (git mode `120000`), not a
  divergent file. It points at `../../../aar-skills/plugins/gpu-job/skills/gpu-job/scripts/deploy_pod.py`,
  i.e. a `research-lab/aar-skills/…` path that no longer exists (the plugin tree moved to
  `automated-researcher` + the marketplace cache). So it is **broken today**, but it carries **zero
  divergent code** — it was already designed to inherit the canonical, it is just pointing at a stale target.
- **Per-experiment forks** — `toy_action_faithfulness/deploy_pod.py` across many old worktrees. These are
  **real, older** copies (~4.7 KB: a hardcoded pubkey + an older `GPU_CANDIDATES`/tiers block), frozen in
  per-experiment dirs that pre-date the symlink convention. Strictly *behind* the canonical — they contain
  no fix the canonical lacks.

The reconcile result is therefore clean: **there is nothing to pull into the canonical.** The one live
non-fork consumer (`research-lab/registry/pipelines/lib`) is already a symlink into the plugin tree; its only
defect is a stale target path, which is a `research-lab`-side fix, not an `automated-researcher` code merge.

This PR's job is thus small and bounded: **make the plugin copy the stated single canonical, and write down
the no-fork convention** — including how a driver gets the canonical without copying it — so the drift can't
silently re-open. It does **not** rewire historical drivers or delete the other copies.

## Approach

**1. Establish the canonical + document the no-fork convention in the gpu-job SKILL.md.** Add a short
"One canonical copy — reference it, never fork" subsection stating:

- `plugins/gpu-job/skills/gpu-job/scripts/deploy_pod.py` is the **single canonical** `deploy_pod.py`.
- **`deploy_pod.py` runs box-side (on the orchestrator), not on the pod.** It calls the RunPod API to
  *create* the pod; it never needs to reach the pod, so a driver must **never** `scp` it to a pod or copy it
  into an experiment dir. A driver **invokes the canonical path in place** — either directly
  (`python3 <plugin>/scripts/deploy_pod.py`) or through a **box-side symlink into the plugin scripts dir**
  (the `research-lab/registry/pipelines/lib/deploy_pod.py` pattern, once its target is fixed). The env-knob
  interface (`GPU_TYPE`, `DISK_GB`, `POD_NAME`, …) is the seam drivers customize — not a code fork.
- **The pod-side mechanism, stated explicitly** (this is where the copies came from): the scripts that *do*
  run on the pod — `bootstrap_pod.sh`, `run_remote.sh`, `job_lib.sh` — are **`scp`'d to the pod from the
  canonical plugin `scripts/` dir at provision time**, so the pod runs the canonical too, never a
  hand-carried fork. `deploy_pod.py` is the acquisition script and is exempt from this — it is invoked
  box-side and produces the SSH endpoint the other scripts are then copied over.

**2. Bump the gpu-job plugin version** 0.2.7 → 0.2.8 (required by `.aar-ci/checks.sh` for any non-manifest
change under a plugin dir).

**3. File a follow-up `ready` ticket in `research-lab`** (via `wf.sh issue claude create -R
antondelafuente/research-lab …`) to (a) repoint / repair the broken
`registry/pipelines/lib/deploy_pod.py` symlink at the canonical's real current location and (b) retire the
historical per-experiment `toy_action_faithfulness/deploy_pod.py` forks. This is deliberately a **separate
repo's** work: the ship-change close-gate rejects a cross-repo `Closes`, and the forks are low-priority
history. The follow-up number is recorded here once filed.

The reconcile step (#297 scope item 2) is **complete in the finding itself**: the diff between the canonical
and `research-lab/registry/pipelines/lib/deploy_pod.py` is empty because the latter is a symlink, and the
per-experiment forks are strictly older — no code moves into the canonical.

## Alternatives considered

- **Vendor `deploy_pod.py` into `research-lab` and import it there.** Rejected — it recreates the exact fork
  this ticket closes. A box-side symlink into the plugin scripts dir gives single-source with no copy.
- **Delete the `research-lab` copy / the per-experiment forks in this PR.** Rejected / out of scope — a
  cross-repo deletion can't be a `Closes` from an `automated-researcher` PR (close-gate rejects cross-repo
  closes), and the forks are low-priority. Handed to the follow-up ticket instead.
- **Rewire every historical driver to the canonical path now.** Rejected — the ticket scopes this
  conservatively to canonicalize + document; the stale `/home/anton/orchestrator/…` driver paths are dead
  worktrees, not live runs.

## Blast radius

- **Docs + version only in this repo.** The single functional change is the SKILL.md convention text plus the
  `plugin.json` version bump. No `deploy_pod.py` behavior changes. `--selftest` and the gpu-job smokes are
  unaffected (no script edits).
- **Product layer** (the gpu-job skill), not the SWE pipeline or instance wiring.
- **Cross-repo:** a follow-up Issue is filed in `research-lab`; no `research-lab` files are touched here.

## Rollout + rollback

- Rollout: merge via the normal ship-change gate; the doc convention takes effect immediately on plugin
  update. No pod or run is affected mid-flight (no runtime code change).
- Rollback: one-command revert of the squash commit (RUNBOOK "One-command revert"); re-run `claude plugin
  update gpu-job` on consumers. The follow-up `research-lab` ticket is independent and can proceed or be
  closed on its own.
