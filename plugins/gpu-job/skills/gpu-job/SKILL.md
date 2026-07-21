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

1. **Acquire:** `python3 scripts/deploy_pod.py` (env knobs: `GPU_TYPES` (comma list of acceptable SKUs,
   e.g. `"NVIDIA L40S,NVIDIA A100 80GB PCIe"` — state the job's actual hardware need here rather than
   taking the default) or `GPU_TYPE` (single id, back-compat), `GPU_COUNT`,
   `DISK_GB`, `POD_NAME`, `POD_NAME_PREFIX` (prepended to the pod name for shared-account dashboard visibility, e.g. `anton-`; empty default), `DATA_CENTERS`, `VOLUME_ID`). Prints `POD_ID` / `LEASE_NONCE` / `SSH` /
   cost. Big-model jobs need big disks — the 220GB default is deliberate. Acquire also writes a
   **pod lease** (see *The pod lease + the standing reaper* below) so an abandoned pod can be reaped
   without you; note the `LEASE_NONCE` and pass it to teardown.
2. **Bootstrap:** scp + run `scripts/bootstrap_pod.sh` on the pod (configures rclone from
   your injected config; restores the optional bundle).
3. **Run detached:** `scripts/run_remote.sh <port> root@<ip> <job.sh> /root/job.log [ENV=V…]`
   — survives SSH close, verifies the job actually started (a "launched" echo proves the
   wrapper ran, not the job). Write the job script to be idempotent and to print progress.
   Cost safety needs no per-pod timer armed by hand — every pod is lease-covered automatically at
   acquire (step 1), and the standing reaper is the backstop (see "The pod lease + the standing
   reaper" below).
4. **Persist + VERIFY:** the job's last act is `source job_lib.sh; r2_copy <outputs> <remote>/<job>/`
   — the hardened copy that always follows symlinks (`-L`) and fails closed if rclone skips one
   (`Can't follow symlink` ⇒ INCOMPLETE), so an incomplete upload never reads as success. Before
   teardown, verify EVERY unique artifact is in the store (`r2_exists`/`r2_done` — list the directory
   and check the final artifact's bytes; never trust a zero-byte done-marker).
   - **Gotcha — N parallel subjects uploading to one shared R2 prefix:** `rclone copy <file> <dir>/`
     keeps the *local* basename at the destination, so N fan-out drivers (one per subject, one pod
     each) that all run `rclone copy out/${SUBJECT}/rollouts.jsonl <remote>/rollouts/` land every
     subject's file on the identical object name — whichever pod's upload finishes last silently
     overwrites every subject before it, no error from rclone. It only bites once two pods finish
     close together, so a driver written from a single-subject template and tested one subject at a
     time looks correct. Give each subject an explicit destination filename with `copyto` instead:
     ```bash
     rclone copyto "out/${SUBJECT}/rollouts.jsonl" "<remote>/rollouts/${SUBJECT}.jsonl"
     ```
     (#446 — caught by luck in a 7-pod fan-out before any subject's rollouts were actually lost.)
5. **Tear down:** `scripts/teardown.sh <pod-id> [lease-nonce]`. Default the moment artifacts verify.
   Pass the `LEASE_NONCE` so the lease is **closed only after the delete is verified gone** (an
   unverified delete leaves the lease for the standing reaper to retry). Never use provider "stop"
   expecting keep-warm — container disk wipes on restart.

## One canonical copy — reference it, never fork

`scripts/deploy_pod.py` **in this plugin is the single canonical `deploy_pod.py`.** The provisioning
gotchas it guards (disk-size default, `ports==None`, hardcoded `containerDiskInGb`, the mid-create abort
trap) only stay fixed everywhere if there is **one** copy. A driver **references** the canonical; it never
copies or forks it into an experiment dir.

**Box-side vs pod-side — how a driver gets the canonical without forking it:**

- **Box-side (invoked on the orchestrator, never copied to the pod):** `deploy_pod.py` (acquisition — it
  calls the RunPod API to *create* the pod and prints the SSH endpoint) and `run_remote.sh` (it `scp`s a job
  script over and launches it detached). A driver runs these **in place** against the canonical path —
  either `python3 <this-scripts-dir>/deploy_pod.py`, or through a **box-side symlink/shim into this scripts
  dir** that the consuming instance provides. The env knobs (`GPU_TYPES`, `DISK_GB`, `POD_NAME`, …) are the
  customization seam — not a reason to fork the code.
- **Pod-side (they run on the pod, so they are copied *to* it from THIS scripts dir at provision time):**
  `bootstrap_pod.sh` (run on first ssh) and `job_lib.sh` (sourced by the job). `scp` them from the canonical
  `scripts/` dir so the pod runs the canonical helpers too — never a hand-carried older copy.

So every path (box-side invoke, pod-side `scp`) resolves back to this one directory; a fix here reaches every
run. If you find a divergent `deploy_pod.py` under an experiment/pipeline dir, treat it as stale and repoint
it at this canonical — do not patch the fork.

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
- **Gotcha:** a silent, zero-progress stall pulling from HF on a fresh pod is not a flaky
  network — check `hf-xet` first (#442). `bootstrap_pod.sh` and `stage_model.sh` already
  default `HF_HUB_DISABLE_XET=1`; for any other direct `huggingface_hub`/`hf`/`huggingface-cli`
  call, set it yourself.

## Scoring several LoRA adapters on one pod (use the helper — do NOT hand-roll)

Serving adapter → eval → next adapter is the single most-repeated pod loop, and hand-rolling it keeps
producing the **same silent failure**: N conditions collapse to N *identical* numbers because a
surviving server (or a stale per-adapter cache) is reused — a clean pipeline emitting a
confidently-wrong table. **`source job_lib.sh; serve_adapters_eval`** bakes in the fix; call it
instead of writing the loop:

```
serve_adapters_eval <out_root> <port> <serve_fn> <eval_fn> -- <adapter1> [adapter2 …]
  serve_fn <adapter> <port> <serve-log>  # launch vLLM serving THIS adapter, detached; ECHO its PID
  eval_fn  <adapter> <out_dir> <port>    # run the eval, writing results UNDER the isolated <out_dir>
```

Per adapter it does, in order: **full teardown** (kill the served PID + every `MA_KILL_PATTERNS`
process form) → **wait until the GPU/port is ACTUALLY free** (`nvidia-smi` below the floor AND the
port refuses — never a fixed timeout) → a **fresh isolated `<out_root>/NN-<adapter>` dir** (no
stale-cache reuse possible) → serve → readiness → `eval_fn` → teardown again. After the loop it
**asserts the per-adapter outputs are distinct** and dies loud otherwise (the exact reuse tell).

```bash
source /root/job_lib.sh
BASE=/workspace/models/Qwen3-32B
serve_fn(){ vllm_serve_lora "$BASE" "$1" "$2" "$3" --max-model-len 8192; }   # baked-in default serve
eval_fn(){ python /root/run_eval.py --url "http://localhost:$3/v1" --out "$2"; }  # your harness
serve_adapters_eval /workspace/out 8000 serve_fn eval_fn -- adapters/dose25 adapters/dose50 adapters/dose100
```

Knobs: `MA_VRAM_FLOOR_MIB` (free-VRAM floor, default 12000); `MA_KILL_PATTERNS` (default the two
generic vLLM forms — **add your in-process pooled-server's process name here** if you run one, e.g.
`MA_KILL_PATTERNS="vllm.entrypoints.openai.api_server VLLM::EngineCore run_pooled_gpqa"`);
`MA_DISTINCT_GLOB` (scope the distinctness compare to your canonical rollout/metric file);
`MA_DISTINCT_MODE`=`error`|`warn`|`off` (`warn` opts out for an eval whose outputs are legitimately
identical across adapters). Reference call-site + self-test: `scripts/multi_adapter_smoke.sh`.

## The pod lease + the standing reaper

Cost safety is **automatic** — there is no per-pod timer to arm by hand. `deploy_pod.py` writes a
tiny, **deletion-scoped** lease (via `scripts/pod_lease.sh`) across acquire — an **intent** record
*before* the pod is created (so even a created-but-never-returned pod is covered), bound to the real
pod id (**provisional**) the moment it deploys, then **enriched** with the SSH endpoint + the run's
real expiry. A kill during the readiness poll DELETEs the un-confirmed pod on a catchable signal (a
`timeout`'s SIGTERM, Ctrl-C); an untrappable kill (SIGKILL / host limit) is bounded by the short
intent expiry. A standing, **model-free** box-level reaper (`scripts/pod_reaper.sh`, scheduled by the
instance) then deletes **only leases that are registered AND past expiry**, and **reports — never
deletes — any unknown pod** (no lease). The lease is what gives the reaper the authority to delete
safely, and it is the **sole** backstop — the old per-pod `watchdog.sh` is retired (#266).

- **A long job must keep its lease fresh.** The lease `expiry` is the only deletion trigger. A run
  that outlives its expiry must `bash scripts/pod_lease.sh refresh <nonce> --expiry-min <N>`
  periodically (the controller-side generalization of the pod-side `keepalive_until_utc`) — or set a
  long expiry up front via `GPU_JOB_LEASE_EXPIRY_MIN` (default 720 = 12h). A `refresh` takes the same
  per-lease lock the reaper's delete takes, so it can never be raced into a wrongful reap. **A
  standalone `gpu-job` caller (no run-experiment wrapper) is responsible for this refresh itself**, or
  the reaper will reap the pod at expiry. (`run-experiment`'s self-wake tick owns this refresh
  automatically for the pods it drives — see that skill's "Arm your self-wake" section, #293.)
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
