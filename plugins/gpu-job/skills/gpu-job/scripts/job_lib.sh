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

# --- R2 copy --------------------------------------------------------------------------
# Incidents: `rclone copy` of a tree WITHOUT -L silently SKIPS symlinks, logs a `NOTICE: … Can't
# follow symlink without -L/--copy-links`, and still exits 0 — and some links (HF-cache snapshot
# links; cross-run dataset/adapter dedup links) point OUTSIDE the tree, so the data is genuinely LOST
# when the source is deleted (HF-cache pre-stage 2026-06-06; Neel-volume migration 2026-06-09). Use
# r2_copy for ANY tree/HF-cache copy instead of raw `rclone copy`.

r2_copy(){ # r2_copy <src> <dst> [extra rclone args…] — hardened tree/HF-cache copy. ALWAYS follows
           # symlinks (-L, appended LAST so a caller flag can't override it) so link targets land as
           # real bytes, and treats ANY `Can't follow symlink` NOTICE as an INCOMPLETE copy → returns
           # non-zero WITH a directed message even when rclone itself exited 0 (the swallow that made a
           # bare copy read as success). Propagates rclone's own non-zero exit too. Output streams live
           # (tee) so a long copy still shows progress. REJECTS symlink-defeating flags (--skip-links,
           # -l/--links, --copy-links=false) — they'd silence the NOTICE the guarantee rests on.
  local src=$1 dst=$2; shift 2
  local a
  for a in "$@"; do
    case "$a" in
      -l|--links|--skip-links|--no-copy-links|--copy-links=false|--copy-links=FALSE|--copy-links=0)
        echo "r2_copy: refusing symlink-defeating flag '$a' — r2_copy MUST follow symlinks (-L) and surface skip NOTICEs. Drop it, or call raw rclone if you truly intend it." >&2
        return 1 ;;
    esac
  done
  local log rc notice=0
  # Fail closed if the temp log can't be made: an empty $log would make the NOTICE grep always miss
  # and return rclone's status — 0 in the very NOTICE-but-exit-0 case this helper exists to catch.
  log=$(mktemp) || { echo "r2_copy: mktemp failed — refusing to copy without a log to scan for skipped symlinks" >&2; return 1; }
  # Capture rclone's status via PIPESTATUS so the result is correct with OR without `pipefail`; guard
  # errexit around the pipe so a non-zero rclone doesn't exit the caller before we surface the message
  # (restore the caller's errexit exactly — never force it on/off). -L is LAST so it wins over any
  # earlier caller-supplied copy-links flag (belt-and-suspenders beyond the reject-list above).
  local restore_e=; case $- in *e*) restore_e='set -e';; esac
  set +e
  rclone copy "$src" "$dst" "$@" -L 2>&1 | tee "$log"
  rc=${PIPESTATUS[0]}
  $restore_e
  grep -qi "can't follow symlink" "$log" && notice=1
  rm -f "$log"
  if [ "$notice" = 1 ]; then
    echo "r2_copy: INCOMPLETE — rclone logged \"Can't follow symlink\": a symlink was SKIPPED (its target may lie outside the tree → silent data loss). Re-copy so the link's bytes land, or verify the source has no cross-tree links. src=$src dst=$dst" >&2
    return 1
  fi
  return "$rc"
}

# --- R2 gates -------------------------------------------------------------------------
# Incidents: `rclone lsf <missing-file>` exits 0 (fullft-pair 2026-06-09); single-file lsf
# can PHANTOM a just-deleted object — list the DIRECTORY; done-gates must check the real
# deliverable's bytes, never a 0-byte sentinel; size-threshold ready-gates race the producer.

r2_exists(){ # r2_exists <r2-dir> <name> — true iff <name> is listed in <dir>. Lists the DIRECTORY and
             # `grep -qx`s the name — NEVER single-file `rclone lsf <file>` (exits 0 on a missing file,
             # and can phantom a just-deleted leaf → false skip / false pass).
  rclone lsf "$1/" 2>/dev/null | grep -qx "$2"
}

r2_done(){ # r2_done <r2-path-to-final-artifact> <min-bytes> — true iff the FINAL artifact (e.g. the
           # last shard) exists with >= min bytes, via `rclone lsl` (needs real object metadata → empty
           # if absent). This is the deliverable-BYTES gate — deliberately NOT the racy anti-pattern the
           # gotcha warns against (a whole-TREE size threshold used as a readiness proxy, which starts a
           # consumer mid-upload). For an EXACT count/bytes gate, use pull_model's `_STAGED.json`.
  local sz
  sz=$(rclone lsl "$1" 2>/dev/null | awk '{print $1; exit}')
  [ -n "$sz" ] && [ "$sz" -ge "$2" ]
}

# --- model staging --------------------------------------------------------------------
# Pulls a model staged ONCE by box-side stage_model.sh, so a pod never re-pulls from HF
# (retires the 25+min / fully-stalled 32B HF base pulls, ~$5 H200 burned on a stuck shard).
# stage_model.sh writes the _STAGED.json manifest LAST, so waiting for it + verifying its
# object_count/total_bytes closes the exact incident where a de-risk pod size-thresholded
# "ready", pulled mid-upload, and missed model-00017-of-00017.safetensors: a pod that starts
# before staging finished, or gets a partial pull, dies on a loud gate, not a short read.

pull_model(){ # pull_model <remote-model-path> <local-dir> [deadline-min=30] — pull a staged
              # model + VERIFY it against its _STAGED.json manifest. Blocks until the manifest
              # lists (safe to call before staging finishes), but only up to deadline-min so a
              # typo'd/missing remote path dies loud instead of billing a pod that waits forever.
  local remote=${1%/} dest=$2 deadline=${3:-30} man exp_n exp_b got_n got_b i=0 max
  max=$(( deadline * 2 ))    # 30s steps
  mkdir -p "$dest"
  while ! rclone lsf "$remote/" 2>/dev/null | grep -qx '_STAGED.json'; do
    i=$((i+1))
    [ "$i" -gt "$max" ] && { echo "pull_model: no _STAGED.json at $remote/ after ${deadline}min — wrong path, or staging never finished?" >&2; return 1; }
    say "pull_model: waiting for staging to finish ($remote/_STAGED.json) [${i}/${max}]"; sleep 30
  done
  man=$(rclone cat "$remote/_STAGED.json" 2>/dev/null || true)
  # `|| true` so a malformed manifest (grep miss) doesn't trip the caller's `set -e` here — let
  # the explicit empty-field check below return the clear error instead.
  exp_n=$(printf '%s' "$man" | grep -o '"object_count":[0-9]*' | grep -o '[0-9]*$' || true)
  exp_b=$(printf '%s' "$man" | grep -o '"total_bytes":[0-9]*' | grep -o '[0-9]*$' || true)
  [ -n "$exp_n" ] && [ -n "$exp_b" ] || { echo "pull_model: bad/missing manifest at $remote/_STAGED.json" >&2; return 1; }
  say "pull_model: pulling $remote -> $dest (expect $exp_n files, $exp_b bytes)"
  # Via r2_copy (hardened): the staged tree is materialized flat so -L is a no-op and the NOTICE never
  # fires, but this routes the pull through the one copy path + fails closed on any residual symlink.
  r2_copy "$remote/" "$dest/" --transfers=8 --checkers=8 || return 1   # explicit: fail closed even without caller errexit
  got_n=$(find "$dest" -type f ! -name '_STAGED.json' | wc -l | tr -d ' ')
  got_b=$(find "$dest" -type f ! -name '_STAGED.json' -printf '%s\n' | awk '{s+=$1} END{print s+0}')
  [ "$got_n" = "$exp_n" ] && [ "$got_b" = "$exp_b" ] || {
    echo "pull_model: INCOMPLETE — got $got_n files/$got_b bytes, manifest says $exp_n/$exp_b" >&2; return 1; }
  say "pull_model: verified $got_n files, $got_b bytes"
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

wait_r2(){ # wait_r2 <r2-dir> <name> [interval=60] — block until the object lists in the dir (a .done
           # sentinel or the real final artifact — never a size threshold, which races the producer).
           # Lists the DIRECTORY + `grep -qx` (never single-file `lsf`, which phantoms a deleted leaf).
           # The adapter-hop idiom: an eval pod polls for the adapter/sentinel the train pod uploads.
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

# --- multi-adapter serve loop ----------------------------------------------------------
# THE recurring silent-failure (gotchas 2026-06-06 OPD-A / reconcile, lines 13/46/74/87): an eval
# driver that scores several LoRA adapters on ONE pod serves adapter A, evals, serves B, evals… and
# N conditions collapse to N IDENTICAL numbers — a clean pipeline emitting a confidently-wrong table
# (cost toy-reason-beyond-rerun ~2.5h). Two compounding bugs: (a) a SURVIVING server from the
# previous adapter keeps answering (serve only `if ! curl /v1/models`; killing only VLLM::EngineCore
# leaves the api_server PARENT alive; an in-process pooled server isn't matched by the api_server
# pattern at all; an OOM'd server HANGS holding VRAM), so every later adapter is scored on the FIRST
# adapter's weights; (b) rollouts cached in a SHARED dir with `skip-if *.eval exists` → adapters 2..N
# find adapter 1's files and skip generation. serve_adapters_eval bakes in the fix so drivers call it
# instead of re-hand-rolling (and re-breaking) the loop: FULL teardown + wait-until-actually-free
# between adapters, an ISOLATED fresh out-dir per adapter (no skip-if-exists reuse possible), and a
# final distinctness assertion (identical outputs across adapters = the exact tell → die loud).

MA_VRAM_FLOOR_MIB=${MA_VRAM_FLOOR_MIB:-12000}
# Default kill patterns are the two GENERIC vLLM process forms ONLY — no instance eval-driver name.
# A driver that runs an IN-PROCESS pooled server (its process name is the driver's own, e.g. a
# `run_pooled_…` script that spawns vLLM in-process) sets MA_KILL_PATTERNS to add that name so the
# between-adapter teardown kills it too — the hook is here, the instance-specific value stays
# caller-side. Self-safe by construction (#299): ma_teardown resolves each pattern to PIDs and drops
# the driver itself/its ancestors before killing, so a pattern that happens to match the driver's own
# command line can never take down the driver, even once a caller wires a real pooled-server name in.
MA_KILL_PATTERNS=${MA_KILL_PATTERNS:-"vllm.entrypoints.openai.api_server VLLM::EngineCore"}
# Distinctness check unit + mode (F4). GLOB scopes the compare to the CANONICAL eval artifact so
# incidental sidecar metadata can't mask a real reuse (and serve.log is always excluded); MODE lets
# an eval whose outputs are legitimately identical across adapters opt out.
MA_DISTINCT_GLOB=${MA_DISTINCT_GLOB:-'*'}
MA_DISTINCT_MODE=${MA_DISTINCT_MODE:-error}   # error (die) | warn (loud, continue) | off

ma_self_and_ancestors(){ # ma_self_and_ancestors — space-delimited self ($$, $BASHPID) + BOTH their
                         # ancestor chains up to PID 1 (the two diverge once called from inside a `( )`
                         # subshell, e.g. serve_adapters_eval's die-isolating callers). Used to keep a
                         # caller-supplied MA_KILL_PATTERNS match from ever self-killing the driver.
  local pids=" $$ ${BASHPID:-$$} " seed p n
  for seed in "$$" "${BASHPID:-$$}"; do
    p=$seed; n=0
    while [ "$p" != 1 ] && [ "$n" -lt 50 ]; do
      p=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')
      [ -n "$p" ] || break
      pids="$pids$p "
      n=$((n+1))
    done
  done
  printf '%s' "$pids"
}

ma_teardown(){ # ma_teardown [serve-pid] [port=8000] — kill the served process + every vLLM/pooled
               # form, then BLOCK until VRAM is below the floor AND the port refuses. KILLS (never
               # waits-for-exit): an OOM'd server hangs and never exits on its own. Dies loud if the
               # GPU/port never frees — never a fixed-timeout "proceed regardless" gate. SELF-SAFE
               # (#299): resolves each MA_KILL_PATTERNS pattern to PIDs first (pgrep -f), drops any
               # that are the driver itself or an ancestor, and kill_tree's only the survivors — never
               # a blind `pkill -9 -f` on a caller-supplied pattern, which can self-match the driver
               # shell (or an unrelated same-pod process) exactly like the `pkill -f self-matches`
               # hazard alive_check's header already warns about (≥6 prior incidents: killed own ssh,
               # masked-dead jobs).
  local pid=${1:-} port=${2:-8000} pat kp i used self_pids
  [ -n "$pid" ] && kill_tree "$pid" KILL
  self_pids=$(ma_self_and_ancestors)
  for pat in $MA_KILL_PATTERNS; do
    for kp in $(pgrep -f "$pat" 2>/dev/null); do
      case "$self_pids" in
        *" $kp "*) say "ma_teardown: pattern '$pat' matched pid $kp (self/ancestor) — refusing to kill it" ;;
        *) kill_tree "$kp" KILL ;;
      esac
    done
  done
  for i in $(seq 1 180); do   # up to ~15 min
    used=$(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits 2>/dev/null \
           | sort -n | tail -1)
    if [ -n "${used:-}" ] && [ "$used" -lt "$MA_VRAM_FLOOR_MIB" ] \
       && ! curl -sf "http://localhost:$port/v1/models" >/dev/null 2>&1; then
      say "ma_teardown: GPU/port free (${used}MiB, port $port refuses)"; return 0
    fi
    sleep 5
  done
  echo "ma_teardown: GPU/port never freed (last ${used:-?}MiB, port $port)" >&2; return 1
}

ma_hash_dir(){ # ma_hash_dir <dir> — content hash of MA_DISTINCT_GLOB files (serve.log excluded),
               # path-independent (per-file content only) so the per-adapter dir prefix never matters.
  find "$1" -type f -name "$MA_DISTINCT_GLOB" ! -name 'serve.log' -exec sha256sum {} + 2>/dev/null \
    | awk '{print $1}' | sort | sha256sum | awk '{print $1}'
}

ma_assert_distinct(){ # ma_assert_distinct <dir…> — honor MA_DISTINCT_MODE. In error mode returns 1
                      # (caller dies) if any two dirs hash identically; warn prints loud + returns 0.
  [ "$MA_DISTINCT_MODE" = off ] && return 0
  local d h prev; declare -A seen=()
  for d in "$@"; do
    h=$(ma_hash_dir "$d")
    prev=${seen[$h]:-}
    if [ -n "$prev" ]; then
      local msg="ma_assert_distinct: '$d' output is BYTE-IDENTICAL to '$prev' — the multi-adapter reuse/caching bug (a surviving server or a stale per-adapter cache). Two conditions collapsed to one number; do NOT trust these results."
      if [ "$MA_DISTINCT_MODE" = warn ]; then echo "WARNING: $msg" >&2; else echo "$msg" >&2; return 1; fi
    fi
    seen[$h]=$d
  done
  return 0
}

vllm_serve_lora(){ # vllm_serve_lora <base> <adapter> <port> <serve-log> [extra vllm args…] — the
                   # baked-in DEFAULT serve: launch the OpenAI api_server serving ONE LoRA adapter
                   # (module name 'adapter') against <base>, detached, logging to <serve-log>. ECHOES
                   # the server PID per the serve_fn contract. Wrap it in a one-line serve_fn that
                   # closes over the base model.
  local base=$1 adapter=$2 port=$3 log=$4; shift 4
  mkdir -p "$(dirname "$log")"
  nohup python -m vllm.entrypoints.openai.api_server \
    --model "$base" --enable-lora --lora-modules "adapter=$adapter" \
    --port "$port" "$@" </dev/null >"$log" 2>&1 &
  echo $!
}

serve_adapters_eval(){ # serve_adapters_eval <out_root> <port> <serve_fn> <eval_fn> -- <adapter…>
  #   serve_fn <adapter> <port> <serve-log>  : launch vLLM serving THIS adapter, detached; ECHO its PID
  #   eval_fn  <adapter> <out_dir> <port>    : run the eval, writing results UNDER the isolated <out_dir>
  # Guarantees, per adapter: full teardown+wait-until-free BEFORE serve (no surviving-server reuse), a
  # FRESH isolated out-dir (no stale-cache skip), serve+readiness, eval, teardown AFTER; then a final
  # distinctness assertion over the per-adapter outputs. See MA_* knobs above.
  local out_root=$1 port=$2 serve_fn=$3 eval_fn=$4; shift 4
  [ "${1:-}" = "--" ] && shift
  local adapters=("$@")
  [ "${#adapters[@]}" -ge 1 ] || die "serve_adapters_eval: no adapters given"
  command -v "$serve_fn" >/dev/null 2>&1 || die "serve_adapters_eval: serve_fn '$serve_fn' not found"
  command -v "$eval_fn"  >/dev/null 2>&1 || die "serve_adapters_eval: eval_fn '$eval_fn' not found"
  mkdir -p "$out_root"
  local i=0 a name out_dir serve_log pid; local out_dirs=()
  for a in "${adapters[@]}"; do
    i=$((i+1))
    name=$(printf '%02d-%s' "$i" "$(printf '%s' "$(basename "$a")" | tr -c 'A-Za-z0-9._-' '_')")
    out_dir="$out_root/$name"; serve_log="$out_dir/serve.log"
    say "serve_adapters_eval: [$i/${#adapters[@]}] adapter=$a -> $out_dir"
    ma_teardown "" "$port" || die "serve_adapters_eval: could not free GPU/port before adapter $a"
    rm -rf "$out_dir"; mkdir -p "$out_dir"              # fresh isolated dir — no stale .eval to reuse
    pid=$("$serve_fn" "$a" "$port" "$serve_log") || die "serve_adapters_eval: serve_fn failed for $a"
    # PID contract, fail-closed: must be a REAL live child server PID. Reject empty/non-numeric, and
    # 0/1/self — kill_tree KILL on 0 signals the whole process group, and 1/self would target init or
    # this driver. `kill -0` then confirms the process actually exists (a serve that never launched
    # dies loud here, not silently un-killed later).
    case "$pid" in ''|*[!0-9]*) die "serve_adapters_eval: serve_fn must ECHO a numeric server PID (got '$pid') for $a";; esac
    if [ "$pid" -le 1 ] || [ "$pid" = "$$" ] || [ "$pid" = "${BASHPID:-$$}" ]; then
      die "serve_adapters_eval: serve_fn returned an unsafe PID ('$pid') for $a — must be a real child server PID, not 0/1/self"
    fi
    kill -0 "$pid" 2>/dev/null || die "serve_adapters_eval: serve_fn PID '$pid' is not a live process for $a (serve failed to launch?)"
    serve_wait "$port" || { ma_teardown "$pid" "$port"; die "serve_adapters_eval: server never became ready for $a"; }
    "$eval_fn" "$a" "$out_dir" "$port" || { ma_teardown "$pid" "$port"; die "serve_adapters_eval: eval_fn failed for $a"; }
    ma_teardown "$pid" "$port" || die "serve_adapters_eval: could not free GPU/port after adapter $a"
    out_dirs+=("$out_dir")
  done
  ma_assert_distinct "${out_dirs[@]}" || die "serve_adapters_eval: DISTINCTNESS FAILED — investigate the reuse before trusting these numbers (or set MA_DISTINCT_MODE=warn for a legitimately identical-output eval)."
  say "serve_adapters_eval: ${#adapters[@]} adapters served in isolation; outputs verified distinct (mode=$MA_DISTINCT_MODE)"
}
