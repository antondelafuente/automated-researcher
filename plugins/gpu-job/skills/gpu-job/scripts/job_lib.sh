# gpu-job job_lib.sh — POD-side job helpers. Source from any job/driver script:
#   source /root/job_lib.sh   (scp it to the pod alongside your job script)
# Each helper header cites the real incident it encodes. Caller scripts should use
# `set -euo pipefail`; helpers return nonzero rather than exiting, except die().

say(){ echo "=== [$(date -u +%H:%M:%S)] $* ==="; }
die(){ echo "BLOCKED: $*" >&2; exit 1; }

# --- logging --------------------------------------------------------------------------
# Incidents: stale-grep across relaunches (exp2 2026-06-06); tqdm CR "giant line" tails;
# append-only logs ballooning (8xH200 2026-06-08).

log_attempt(){ # log_attempt <logfile> — open a new attempt section; call once at script start
  echo "=== ATTEMPT $(date -u +%FT%TZ) pid=$$ host=$(hostname) ===" >> "$1"
}

log_tail(){ # log_tail <logfile> [bytes] — latest attempt only, CR-split, byte-capped
  local f=$1 cap=${2:-20000}
  awk '/^=== ATTEMPT /{s=NR} {l[NR]=$0} END{if(!s)s=1; for(i=s;i<=NR;i++)print l[i]}' "$f" \
    | tr '\r' '\n' | tail -c "$cap"
}

# --- GPU stage gate -------------------------------------------------------------------
# Incidents: grape GPU-contention; hung-OOM vLLM holding VRAM (OPD 2026-06-06); identical-cv
# from a surviving server (OPD-A); in-process GPQA vLLM missed by api_server pkill +
# "never a fixed-timeout gate between two single-GPU jobs" (reconcile 2026-06-06).

gpu_gate(){ # gpu_gate [runner-pattern ...] — wait for prior runners to EXIT (no clock-kill),
            # then kill every vLLM form, then wait until VRAM is actually free.
  local pat i used
  for pat in "$@"; do
    while pgrep -f "$pat" >/dev/null 2>&1; do
      say "gpu_gate: waiting on '$pat' (no timeout — wait on the process, not a clock)"
      sleep 20
    done
  done
  pkill -9 -f "vllm.entrypoints.openai.api_server" 2>/dev/null || true
  pkill -9 -f "VLLM::EngineCore" 2>/dev/null || true
  for i in $(seq 1 120); do
    used=$(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits 2>/dev/null \
           | sort -n | tail -1)
    [ -n "${used:-}" ] && [ "$used" -lt 12000 ] && { say "gpu_gate: free (${used}MiB)"; return 0; }
    sleep 5
  done
  echo "gpu_gate: VRAM never freed (last ${used:-?}MiB)" >&2; return 1
}

port_free_wait(){ # port_free_wait <port> — block until nothing answers on the port (OPD-A fix)
  local port=$1
  while curl -sf "http://localhost:$port/v1/models" >/dev/null 2>&1; do
    say "port_free_wait: $port still serving"; sleep 5
  done
}

serve_wait(){ # serve_wait <port> [max-iter=480] — wait (5s steps) until a vLLM server answers
  local port=$1 n=${2:-480} i
  for i in $(seq 1 "$n"); do
    curl -sf "http://localhost:$port/v1/models" >/dev/null 2>&1 && return 0
    sleep 5
  done
  return 1
}

# --- R2 gates -------------------------------------------------------------------------
# Incidents: `rclone lsf <missing-file>` exits 0 (fullft-pair 2026-06-09); single-file lsf
# can PHANTOM a just-deleted object — list the DIRECTORY; done-gates must check the real
# deliverable's bytes, never a 0-byte sentinel; size-threshold ready-gates race the producer.

r2_exists(){ # r2_exists <r2-dir> <name> — true iff <name> is listed in <dir> (no trailing /)
  rclone lsf "$1/" 2>/dev/null | grep -qx "$2"
}

r2_done(){ # r2_done <r2-path-to-final-artifact> <min-bytes> — true iff it exists with >= min bytes
  local sz
  sz=$(rclone lsl "$1" 2>/dev/null | awk '{print $1; exit}')
  [ -n "$sz" ] && [ "$sz" -ge "$2" ]
}

# --- input gates ----------------------------------------------------------------------
# Gotcha: process-substitution Python failure sailed past `set -uo pipefail` into torchrun
# with a missing input file (8xH200 2026-06-08) — gate every generated input explicitly.

require_files(){ # require_files <f1> [f2 ...] — die unless every file exists and is non-empty
  local f
  for f in "$@"; do
    [ -s "$f" ] || die "required file missing/empty: $f"
  done
}

# --- process / env helpers --------------------------------------------------------------
# Incidents: PGID kill self-kills a driver whose child shares its process group (regen-dpo
# 2026-06-11); `export `-prefixed .env lines defeat `^VAR=` greps → empty token → "Bearer ''"
# (bail-repro 2026-06-10).

kill_tree(){ # kill_tree <pid> [signal=TERM] — kill a child + descendants WITHOUT touching your
             # own group (never `kill -- -PGID`: a setsid'd driver and its `&` child share PGID)
  local pid=$1 sig=${2:-TERM} k
  for k in $(pgrep -P "$pid" 2>/dev/null); do kill_tree "$k" "$sig"; done
  kill -"$sig" "$pid" 2>/dev/null || true
}

alive_check(){ # alive_check <output-file> <staleness-min> — true iff <file> exists AND its mtime
               # advanced within the last <staleness-min> minutes (positive-progress liveness).
               # USE THIS, not `pgrep -f <token>`, to answer "is the job still working?": a -f
               # process probe self-matches the probing shell (≥6 incidents — masked-dead jobs,
               # killed own ssh, never-exiting relaunch loops) AND a hung-but-not-exited process
               # reads as "alive" though it stopped progressing. A growing output file is the real
               # signal. Pair with kill_tree (kill by PID, never `pkill -f`).
  local f=$1 stale=$2
  [ -e "$f" ] || return 1
  [ -z "$(find "$f" -mmin +"$stale" 2>/dev/null)" ]  # empty ⇒ newer than stale-min ⇒ alive
}

env_get(){ # env_get <VAR> [file=/workspace/.env] — read VAR tolerating `export VAR=…`; dies if empty
  local var=$1 file=${2:-/workspace/.env} val
  val=$(grep -E "^(export )?${var}=" "$file" 2>/dev/null | tail -1 | sed 's/^export //' \
        | cut -d= -f2- | sed -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'$//")
  [ -n "$val" ] || die "env_get: $var empty/missing in $file"
  printf '%s' "$val"
}

wait_r2(){ # wait_r2 <r2-dir> <name> [interval=60] — block until the object lists in the dir
           # (the adapter-hop idiom: eval pod polls for a 2GB adapter the train pod uploads)
  local dir=$1 name=$2 iv=${3:-60}
  while ! rclone lsf "$dir/" 2>/dev/null | grep -qx "$name"; do sleep "$iv"; done
}

# --- disk janitor -----------------------------------------------------------------------
# Incident (2026-06-11): verl at save_steps=1 dumps ~16GB full-FSDP .pt per checkpoint beside
# a 253MB adapter — disk hit 100% and torch.save died mid-write. Generic pattern: training
# frameworks that emit huge intermediates need a bounded-disk sweeper DURING the run.

ckpt_janitor(){ # ckpt_janitor <dir> <glob> [age-min=2] [interval=30] — detached loop deleting
                # matching files older than age-min (the age guard avoids mid-write deletion).
                # Returns the janitor PID; kill_tree it when training ends.
  local dir=$1 glob=$2 age=${3:-2} iv=${4:-30}
  ( while true; do find "$dir" -name "$glob" -mmin +"$age" -delete 2>/dev/null; sleep "$iv"; done ) &
  echo $!
}
