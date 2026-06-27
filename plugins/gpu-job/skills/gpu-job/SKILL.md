---
name: gpu-job
description: Run GPU work on disposable cloud pods (RunPod backend) with artifact persistence and verified teardown. Use when the user wants to rent/launch a GPU, run a training/eval/compute job remotely ("get me an H100", "run this on a GPU", "launch a pod"), or when local hardware can't run the job. The contract - acquire, run detached, persist artifacts, VERIFY, tear down - exists so a forgotten pod never bills silently.
---

# gpu-job — disposable GPU compute for coding agents

The machine you're on probably has no GPU; the cloud has plenty by the hour. This skill's
whole contract: **acquire → run detached → persist artifacts → verify → tear down.** A pod
is cattle, not a pet — everything worth keeping leaves the pod before the pod dies.

## One-time setup (per user)

`scripts/gpu_job_init.sh` — writes `~/.config/gpu-job/env` (RunPod key, SSH pubkey, defaults,
optional rclone artifact remote). Nothing is uploaded; config stays local, chmod 600.
Optional: stage an identity bundle at `<remote>/gpu-job/bundle.tar` (e.g. agent auth,
.gitconfig) and pods restore it at bootstrap.

## The loop

1. **Acquire:** `python3 scripts/deploy_pod.py` (env knobs: `GPU_TYPE`, `GPU_COUNT`,
   `DISK_GB`, `POD_NAME`, `DATA_CENTERS`, `VOLUME_ID`). Prints `POD_ID` / `LEASE_NONCE` / `SSH` /
   cost. Big-model jobs need big disks — the 220GB default is deliberate. Acquire also writes a
   **pod lease** (see *The pod lease + the standing reaper* below) so an abandoned pod can be reaped
   without you; note the `LEASE_NONCE` and pass it to teardown.
2. **Bootstrap:** scp + run `scripts/bootstrap_pod.sh` on the pod (configures rclone from
   your injected config; restores the optional bundle).
3. **Run detached:** `scripts/run_remote.sh <port> root@<ip> <job.sh> /root/job.log [ENV=V…]`
   — survives SSH close, verifies the job actually started (a "launched" echo proves the
   wrapper ran, not the job). Write the job script to be idempotent and to print progress.
4. **Arm the watchdog the moment the job is launched:** `scripts/watchdog.sh <pod-id> <ip>
   <port> [grace]` — if you stop paying attention, the pod still gets deleted. NOTE its
   semantics: it is a **TTL / dead-man timer, not idle detection** — it fires after the grace
   period unless `/workspace/.keepalive_until_utc` holds a future UTC timestamp. A long job
   must REFRESH that file periodically (e.g. each epoch), or set grace ≥ expected runtime +
   margin; otherwise a healthy job gets killed on schedule.
5. **Persist + VERIFY:** the job's last act is `rclone copy <outputs> <remote>/<job>/`;
   before teardown, verify EVERY unique artifact is in the store (`rclone lsf` the
   directory and check the final artifact's bytes — never trust a zero-byte done-marker).
6. **Tear down:** `scripts/teardown.sh <pod-id> [lease-nonce]`. Default the moment artifacts verify.
   Pass the `LEASE_NONCE` so the lease is **closed only after the delete is verified gone** (an
   unverified delete leaves the lease for the standing reaper to retry). Never use provider "stop"
   expecting keep-warm — container disk wipes on restart.

## Staging a base model (optional)

Pods re-pulling the same base model from HF every run is the root of a paid gotcha cluster
(~25-min first-touch network-FS stalls; missing-shard races; rclone symlink loss). Stage it
in the store **once** and pull from there:

- **Box-side, once:** `scripts/stage_model.sh <hf-repo>[@rev] <remote-path>` downloads from
  HF, `rclone copy -L`s it to the store, and writes a `_STAGED.json` completeness manifest
  **last** (object count + bytes). (`HF_TOKEN` for gated repos.)
- **Pod-side, in the job:** `source job_lib.sh; pull_model <remote-path> <local-dir>` waits
  for the manifest, pulls, and **verifies count + bytes against it** — a pod that starts
  before staging finished, or gets a partial pull, dies on a loud gate, never a short read.

## The pod lease + the standing reaper

The per-pod `watchdog.sh` only reaps a pod if you armed it, by hand, after the run was underway — so
a pod whose agent died before arming it bills until a human notices. The **pod lease** closes that
hole: `deploy_pod.py` writes a tiny, **deletion-scoped** lease (via `scripts/pod_lease.sh`) across
acquire — an **intent** record *before* the pod is created (so even a created-but-never-returned pod
is covered), bound to the real pod id (**provisional**) the moment it deploys, then **enriched** with
the SSH endpoint + the run's real expiry. A standing, **model-free** box-level reaper
(`scripts/pod_reaper.sh`, scheduled by the instance) then deletes **only leases that are registered
AND past expiry**, and **reports — never deletes — any unknown pod** (no lease). The lease is what
gives the reaper the authority to delete safely; the reaper is the always-on counterpart to the
per-pod watchdog.

- **A long job must keep its lease fresh.** The lease `expiry` is the only deletion trigger. A run
  that outlives its expiry must `bash scripts/pod_lease.sh refresh <nonce> --expiry-min <N>`
  periodically (the controller-side generalization of the pod-side `keepalive_until_utc`) — or set a
  long expiry up front via `GPU_JOB_LEASE_EXPIRY_MIN` (default 720 = 12h). A `refresh` takes the same
  per-lease lock the reaper's delete takes, so it can never be raced into a wrongful reap. **A
  standalone `gpu-job` caller (no run-experiment wrapper) is responsible for this refresh itself**, or
  the reaper will reap the pod at expiry.
- **The reaper is a product operation, not instance wiring.** `pod_reaper.sh` resolves each lease's
  key reference through the same `API_KEY_ENV` seam, lists pods per key, and does the matched-key
  delete-and-verify. The instance supplies only the secret values (`~/.config/gpu-job/env`) and the
  schedule. Roll it out **`--dry-run` first** (logs every would-be DELETE without acting).
- **Disable the lease wiring** with `GPU_JOB_LEASE_DISABLE=1` (a standalone caller who doesn't want a
  registry) — the reaper then simply has nothing to read for that pod. Registry root is
  `${GPU_JOB_LEASE_DIR:-~/.config/gpu-job/leases}`.

## Rules that are not optional

- **The completion boundary is the whole ballgame:** before verified persistence, DELETE
  loses data; after it, DELETE is free. Order everything around that line.
- **Teardown is pod-id-scoped.** Never blanket-delete "idle" pods — parallel runs own theirs.
- **Watch liveness with a positive-progress signal** (artifact growing, stage marker
  advancing) — "no done-marker yet" can't distinguish working from wedged.
- Costs are per-hour from deploy to delete. Check the printed `COST_PER_HR`; a forgotten
  H200 is ~$100/day.
