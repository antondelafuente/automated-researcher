#!/bin/bash
# local_job_queue.sh — concurrency-capped LOCAL job queue for the controller box (#402).
#
# Incident: "concurrency is free" (run-experiment SKILL.md's Execution discipline / design-experiment's
# per-compute-billing note) describes REMOTE/provider-side billing only. A 40-way Tinker LoRA train fan-out
# followed that guidance and launched all 40 `train_ccp.py` drivers at once — each driver holds ~1.5-2GB RAM
# on the CONTROLLER box while it builds/holds its rendered datums, even though the actual training compute
# runs on Tinker's servers. The naive "launch all N at once" hit the controller's local RAM ceiling well
# before any remote/provider concurrency cap, OOM-killing 21/40 processes with ZERO output in their logs —
# indistinguishable from "hasn't started yet." This queue throttles LOCAL launch concurrency independently
# of any remote/provider limit, so the throttled-relaunch pattern hand-rolled to recover doesn't get
# re-derived from scratch next time.
#
# USAGE: local_job_queue.sh <cap> <commands-file> [poll-seconds=5]
#   <cap>            max jobs THIS QUEUE launched allowed running at once (positive integer)
#   <commands-file>  one full shell command per line; blank lines and lines starting with '#' are skipped.
#                    Each command owns its own stdout/stderr redirection if it needs a log file.
#   [poll-seconds]   how often to recheck the running count while the cap is full (default 5)
#
# Deliberately NOT `pgrep -f <pattern>`-based: matching launched jobs by a command-line pattern self-matches
# on more than just this script's own PID — every ANCESTOR shell that assembled this invocation (a wrapping
# driver script, an autonomous agent session whose own command text names the driver being launched) AND
# every transient helper process this script itself forks to do the counting (a `pgrep`/`grep` child
# momentarily still carries this script's OWN argv until it execs) can carry the same pattern text and get
# miscounted as a live job — at cap=1 that phantom match never clears, hanging forever. Counting via the
# shell's OWN job table instead (`jobs -rp`, scoped to jobs THIS script backgrounded) sidesteps the whole
# self-match class: it can only ever report jobs this invocation actually launched.
#
# Each command is launched detached (`setsid nohup bash -c "<cmd>"`, output discarded unless the command
# redirects its own). Blocks until every command has been LAUNCHED — this is dispatch throttling only, NOT
# a wait-for-completion: use your own done-marker / job control to know when the launched jobs finish.
# Prints one line per launch to stdout: "launched <n>/<total> pid=<pid> cmd=<cmd>".
set -euo pipefail

die(){ echo "local_job_queue: $*" >&2; exit 1; }

[ $# -ge 2 ] && [ $# -le 3 ] || die "usage: local_job_queue.sh <cap> <commands-file> [poll-seconds=5]"
cap=$1 cmdfile=$2 poll=${3:-5}

case "$cap" in ''|*[!0-9]*) die "cap must be a positive integer (got '$cap')" ;; esac
[ "$cap" -ge 1 ] || die "cap must be >= 1 (got '$cap')"
case "$poll" in ''|*[!0-9]*) die "poll-seconds must be a non-negative integer (got '$poll')" ;; esac
[ -f "$cmdfile" ] || die "commands-file not found: $cmdfile"

running_count(){ jobs -rp | wc -l | tr -d ' '; }

mapfile -t cmds < <(grep -vE '^[[:space:]]*(#|$)' "$cmdfile")
total=${#cmds[@]}
[ "$total" -ge 1 ] || die "commands-file has no runnable commands (all blank/comment lines?): $cmdfile"

launched=0
for cmd in "${cmds[@]}"; do
  while [ "$(running_count)" -ge "$cap" ]; do
    sleep "$poll"
  done
  setsid nohup bash -c "$cmd" >/dev/null 2>&1 &
  pid=$!
  launched=$((launched + 1))
  echo "launched $launched/$total pid=$pid cmd=$cmd"
done
