#!/bin/bash
# run_remote.sh <ssh-port> <user@host> <local-script> <remote-log> [ENV=VAL ...]
# scp a job script to the pod, launch it DETACHED (survives SSH close), verify it started.
# Footguns this encodes: `exec > >(tee ...)` drivers die on channel close without
# nohup+setsid+</dev/null; never author scripts inside quoted ssh strings (scp them);
# scp uses -P where ssh uses -p; "launched" != "running" — verify the log grows.
set -euo pipefail
PORT=${1:?port} HOST=${2:?user@host} SCRIPT_F=${3:?local script} RLOG=${4:?remote log}; shift 4
KEY=$(grep -E "^SSH_KEY_FILE=" ~/.config/gpu-job/env 2>/dev/null | cut -d= -f2- || echo ~/.ssh/id_ed25519)
RNAME=$(basename "$SCRIPT_F")
scp -i "$KEY" -P "$PORT" -o StrictHostKeyChecking=no "$SCRIPT_F" "$HOST:/root/$RNAME"
ssh -i "$KEY" -p "$PORT" -o StrictHostKeyChecking=no "$HOST" \
  "nohup setsid env $* bash /root/$RNAME </dev/null >> '$RLOG' 2>&1 & disown; echo launched"
sleep 15
ssh -i "$KEY" -p "$PORT" -o StrictHostKeyChecking=no "$HOST" "[ -s '$RLOG' ]" \
  || { echo "run_remote: launched but $RLOG empty after 15s — launch likely died" >&2; exit 1; }
echo "run_remote: $RNAME running on $HOST, log $RLOG"
