#!/bin/bash
# gpu-job init — one-time setup. Writes ~/.config/gpu-job/env from your answers/env and
# (optionally) prepares the rclone artifact-store config the pods will receive.
# Non-interactive: pre-set the vars and run; interactive: it prompts for what's missing.
# NOTHING is uploaded anywhere by this script; it only writes a local config file.
set -euo pipefail
CFG_DIR=~/.config/gpu-job; CFG=$CFG_DIR/env; mkdir -p "$CFG_DIR"; touch "$CFG"; chmod 600 "$CFG"

ask(){ # ask VAR "prompt" [default]
  local var=$1 prompt=$2 def=${3:-} cur val
  cur=$(grep -E "^${var}=" "$CFG" 2>/dev/null | tail -1 | cut -d= -f2- || true)
  val=${!var:-${cur:-}}
  if [ -z "$val" ]; then
    if [ -t 0 ]; then read -rp "$prompt${def:+ [$def]}: " val; val=${val:-$def}
    else val=$def; fi
  fi
  [ -n "$val" ] || { echo "ERROR: $var required" >&2; exit 1; }
  grep -vE "^${var}=" "$CFG" > "$CFG.tmp" || true; mv "$CFG.tmp" "$CFG"
  printf '%s=%s\n' "$var" "$val" >> "$CFG"
}

echo "== gpu-job init (config -> $CFG, chmod 600) =="
ask RUNPOD_API_KEY "RunPod API key (runpod.io -> Settings -> API Keys)"
SSH_PUBLIC_KEY=${SSH_PUBLIC_KEY:-$(cat ~/.ssh/id_ed25519.pub 2>/dev/null || true)}
ask SSH_PUBLIC_KEY "SSH public key to inject into pods"
ask SSH_KEY_FILE "Matching private key path" "$HOME/.ssh/id_ed25519"
ask GPU_TYPE "Default GPU type" "NVIDIA H200"
ask DISK_GB "Default container disk GB (big models need big disks)" "220"

# Optional: artifact store = any rclone remote ("r2:mybucket", "s3:bucket", "gdrive:dir").
# We base64 your rclone.conf section for that remote and inject it into pods so jobs can
# `rclone copy` artifacts out before teardown.
if [ -n "${RCLONE_REMOTE:-}" ] || [ -t 0 ]; then
  ask RCLONE_REMOTE "rclone remote for artifacts (e.g. r2:mybucket; empty to skip)" "${RCLONE_REMOTE:-skip}"
fi
REMOTE=$(grep -E "^RCLONE_REMOTE=" "$CFG" | cut -d= -f2- || true)
if [ -n "$REMOTE" ] && [ "$REMOTE" != "skip" ]; then
  RNAME=${REMOTE%%:*}
  if rclone config show "$RNAME" >/dev/null 2>&1; then
    B64=$( { echo "[$RNAME]"; rclone config show "$RNAME" | tail -n +2; } | base64 -w0 )
    grep -vE "^RCLONE_CONF_B64=" "$CFG" > "$CFG.tmp" || true; mv "$CFG.tmp" "$CFG"
    printf 'RCLONE_CONF_B64=%s\n' "$B64" >> "$CFG"
    echo "  rclone remote '$RNAME' captured for pod injection"
  else
    echo "  WARNING: rclone remote '$RNAME' not found locally (rclone config) — artifact persistence won't work until it exists" >&2
  fi
fi
echo "== done. Deploy with: python3 deploy_pod.py =="
