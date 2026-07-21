#!/bin/bash
# bootstrap_pod.sh — run ON the pod (first ssh). Minimal, provider-image-agnostic:
# 1) installs rclone if absent and materializes your injected rclone config, so jobs can
#    persist artifacts to YOUR store; 2) pulls an optional identity/env bundle
#    (<remote>/gpu-job/bundle.tar) if you've staged one (e.g. agent auth, .gitconfig); 3)
#    persists every deploy_pod.py PASS_ENV var so LATER ssh sessions can see it too (see
#    _persist_passed_env below — automated-researcher #341).
set -euo pipefail

_proc1_get(){ # _proc1_get <environ-file> <name> — <name>'s value from a NUL-separated KEY=VALUE
              # environ file (e.g. /proc/1/environ — PID 1's env is the one place guaranteed to
              # hold every var RunPod/deploy_pod.py injected into THIS container, regardless of
              # whether the ssh session running bootstrap itself inherited it). Empty if
              # absent/unreadable; never errors (safe under `set -e` at every call site).
  awk -v k="$2" 'BEGIN{RS="\0"} index($0, k"=")==1{print substr($0, length(k)+2); exit}' "$1" 2>/dev/null || true
}

_persist_passed_env(){ # _persist_passed_env <environ-file> [workspace-env=/workspace/.env]
  # [etc-environment=/etc/environment] [is-root=auto] — generalizes the R2-only env persistence
  # below to ANY var deploy_pod.py injected via PASS_ENV (#341: TINKER_API_KEY/HF_TOKEN/etc were
  # silently absent from every job-launch ssh session, costing a diagnose-and-relaunch cycle
  # each). deploy_pod.py's pod_env() writes PASSED_ENV_NAMES alongside the real vars — bootstrap
  # has no other record of what was in PASS_ENV. Writes each to <workspace-env> (the
  # `source /workspace/.env`-per-launch-script fallback convention; job_lib.sh's env_get already
  # reads this file) and, on a root pod, to <etc-environment> too — the PRIMARY mechanism, since
  # PAM applies /etc/environment to every later non-interactive `ssh pod 'cmd'` with no per-script
  # source to forget (same pattern the RCLONE_MULTI_THREAD_* write below already uses).
  local environ_file=$1 workspace_env=${2:-/workspace/.env} etc_env=${3:-/etc/environment} is_root=${4:-}
  [ -n "$is_root" ] || { [ "$(id -u)" = 0 ] && is_root=1 || is_root=0; }
  local names name val old_ifs
  names=$(_proc1_get "$environ_file" PASSED_ENV_NAMES)
  [ -n "$names" ] || return 0
  mkdir -p "$(dirname "$workspace_env")"
  [ "$is_root" = 1 ] && mkdir -p "$(dirname "$etc_env")"
  old_ifs=$IFS; IFS=','
  for name in $names; do
    IFS=$old_ifs
    [ -n "$name" ] || continue
    val=$(_proc1_get "$environ_file" "$name")
    [ -n "$val" ] || continue
    grep -q "^${name}=" "$workspace_env" 2>/dev/null || printf '%s=%s\n' "$name" "$val" >> "$workspace_env"
    if [ "$is_root" = 1 ]; then
      grep -q "^${name}=" "$etc_env" 2>/dev/null || printf '%s=%s\n' "$name" "$val" >> "$etc_env"
    fi
  done
  IFS=$old_ifs
  echo "[bootstrap] persisted PASS_ENV var(s) for later ssh sessions: $names"
}

# Allow this file to be `source`d (by bootstrap_pod_env_smoke.sh) to reuse the two functions above
# offline, without running the real bootstrap below (rclone install, real /etc/environment writes).
if [ "${BASH_SOURCE[0]}" != "${0}" ]; then
  return 0
fi

# Multi-threaded rclone by default (automated-researcher #284): exported here so THIS bootstrap's own
# rclone pulls use it, and (below) written to /etc/environment so later pod shells / ssh eval-drivers
# inherit it. Overridable — respects a value already set in the environment.
export RCLONE_MULTI_THREAD_STREAMS="${RCLONE_MULTI_THREAD_STREAMS:-16}" RCLONE_MULTI_THREAD_CUTOFF="${RCLONE_MULTI_THREAD_CUTOFF:-100M}"
# Disable huggingface_hub's Xet-accelerated downloader by default (automated-researcher #442): on a
# fresh pod it silently stalls at zero bytes/sec on some host/network paths — no error, no timeout,
# no retry, it just sits (root-caused via a raw curl range-GET on the same host hitting full
# bandwidth, proving the network was fine and the stall was Xet-specific). Same resolved-value
# persistence pattern as RCLONE_MULTI_THREAD_* above — overridable, and inherited by later shells.
export HF_HUB_DISABLE_XET="${HF_HUB_DISABLE_XET:-1}"
if [ -n "${RCLONE_CONF_B64:-}" ]; then
  command -v rclone >/dev/null || (curl -fsSL https://rclone.org/install.sh | bash >/dev/null 2>&1)
  mkdir -p ~/.config/rclone
  echo "$RCLONE_CONF_B64" | base64 -d > ~/.config/rclone/rclone.conf
  echo "[bootstrap] rclone configured"
  if [ -n "${RCLONE_REMOTE:-}" ] && rclone lsf "$RCLONE_REMOTE/gpu-job/" 2>/dev/null | grep -qx bundle.tar; then
    rclone copy "$RCLONE_REMOTE/gpu-job/bundle.tar" /tmp/ && tar xf /tmp/bundle.tar -C ~ && rm /tmp/bundle.tar
    echo "[bootstrap] identity bundle restored"
  fi
fi
# Default multi-threaded rclone so large single-file R2 pulls (venvs, big adapters) parallelize instead
# of throttling to ~1 MB/s single-stream (~148 MB/s measured; automated-researcher #284). Written to
# /etc/environment so EVERY pod shell — incl. `ssh pod 'rclone …'` used by eval-drivers — inherits it;
# overridable per-call. Needs a root pod (RunPod default); skipped gracefully otherwise.
if [ "$(id -u)" = 0 ]; then
  # Persist the RESOLVED values (honors an override passed into bootstrap), per-key idempotent.
  for kv in "RCLONE_MULTI_THREAD_STREAMS=$RCLONE_MULTI_THREAD_STREAMS" "RCLONE_MULTI_THREAD_CUTOFF=$RCLONE_MULTI_THREAD_CUTOFF" "HF_HUB_DISABLE_XET=$HF_HUB_DISABLE_XET"; do
    grep -q "^${kv%%=*}=" /etc/environment 2>/dev/null || echo "$kv" >> /etc/environment
  done
  echo "[bootstrap] rclone multi-thread + HF Xet defaults set"
fi
# Generalized PASS_ENV persistence (#341) — see _persist_passed_env's header above.
_persist_passed_env /proc/1/environ
touch /workspace/.gpu-job-ready 2>/dev/null || touch ~/.gpu-job-ready
echo "[bootstrap] ready"
