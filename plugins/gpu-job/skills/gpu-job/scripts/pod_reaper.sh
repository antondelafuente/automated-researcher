#!/bin/bash
# pod_reaper.sh — the BOX-LEVEL, MODEL-FREE pod reaper (the #54 crash-resilience design, child 2 /
# #169 B.1). PRODUCT helper: it owns the whole reap DECISION + the DELETE-and-verify, resolving keys
# through the same API_KEY_ENV seam deploy_pod.py/teardown.sh use. The INSTANCE supplies only the
# secret values (~/.config/gpu-job/env, as today) and the SCHEDULE (the systemd timer / loop that
# invokes this). No decision logic, key resolution, listing, or DELETE lives in instance wiring — so
# no instance wiring can blanket-delete.
#
# THE CONTRACT (over the pod_lease.sh registry + the provider's live pod list):
#   reap        — a lease that is REGISTERED and PAST EXPIRY. Deleted, under the lease's lock.
#   keep        — a lease registered and NOT expired. Left alone.
#   report-only — an UNKNOWN pod (no lease, no matching pending-intent nonce), an AMBIGUOUS nonce
#                 match, or a lease whose key_ref can't be resolved. REPORTED, NEVER deleted —
#                 preserving gpu-job's "never blanket-delete idle pods" rule.
#
# THE LOCKED REAP (design review Finding 1): a reap is NOT a stale classification followed by a
#   detached DELETE. For each candidate lease, this re-checks `is-reapable` and marks `reaping`
#   INSIDE that lease's per-record lock (via pod_lease.sh, which takes the same lock `refresh` takes),
#   so a concurrent long-run `refresh` that extended expiry can never be raced into a wrongful delete.
#   Only after the in-lock claim succeeds does it DELETE + verify.
#
# KEY RESOLUTION + LISTING IN THE PRODUCT (Finding 2): each lease records a key_ref (the API_KEY_ENV
#   reference). This resolves it to a secret value through the gpu-job config seam, lists pods PER
#   RESOLVED KEY, and does the matched-key DELETE+verify. A lease whose key_ref does not resolve is
#   report-only (never deleted with the wrong account's key).
#
# MIGRATION / BACK-COMPAT (Finding 3): a lease carries refresh_contract. Contract 2 (controller-side,
#   the only contract this helper's pod_lease.sh writes) reaps on LEASE EXPIRY ALONE. A legacy
#   contract-1 lease additionally requires a pod-side keepalive check over its SSH endpoint, and an
#   INCONCLUSIVE read (transient SSH failure) REPORTS-AND-RETRIES — it is never a license to delete a
#   healthy old-style long job.
#
# --dry-run: log every DELETE it WOULD issue (and every report-only pod), reconcilable against the
#   ledger + lease registry, WITHOUT deleting or marking anything. Roll the sweep out dry-run first.
#
# Provider seams (overridable so the smoke can run offline without RunPod):
#   GPU_JOB_LIST_PODS_CMD   "<cmd> <key>"  -> prints one `<pod-id> <name>` line per live pod for <key>
#   GPU_JOB_DELETE_POD_CMD  "<cmd> <key> <pod-id>" -> deletes; exit 0 on accepted delete
#   GPU_JOB_VERIFY_GONE_CMD "<cmd> <key> <pod-id>" -> exit 0 iff the pod is confirmed GONE
#   GPU_JOB_KEEPALIVE_CMD   "<cmd> <ssh> <pod-id>" -> prints future|past|"" (""=inconclusive read)
#   GPU_JOB_RESOLVE_KEY_CMD "<cmd> <key-ref>"      -> prints the resolved secret (empty = unresolved)
# Defaults use curl/ssh against RunPod + ~/.config/gpu-job/env.
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
LEASE="$HERE/pod_lease.sh"
CFG="$HOME/.config/gpu-job/env"

DRY=0
[ "${1:-}" = "--dry-run" ] && { DRY=1; shift; }

log(){ echo "[reaper $(date -u +%H:%M:%S)] $*"; }

# --- provider seams (real defaults; smoke overrides via env) -------------------------------------

cfg_get(){ grep -E "^$1=" "$CFG" 2>/dev/null | tail -1 | cut -d= -f2- | tr -d '"'"'"; }

# Resolve a key_ref (an API_KEY_ENV var NAME) to its secret: process env wins, else the gpu-job config
# (the same indirection deploy_pod.py uses). Empty output = unresolved -> the caller reports the lease.
resolve_key(){ # <key-ref>
  if [ -n "${GPU_JOB_RESOLVE_KEY_CMD:-}" ]; then $GPU_JOB_RESOLVE_KEY_CMD "$1"; return; fi
  local ref=$1 v
  v=${!ref:-}
  [ -n "$v" ] || v=$(cfg_get "$ref")
  printf '%s' "$v"
}

list_pods(){ # <key> -> "<pod-id> <name>" lines
  if [ -n "${GPU_JOB_LIST_PODS_CMD:-}" ]; then $GPU_JOB_LIST_PODS_CMD "$1"; return; fi
  curl -s -H "Authorization: Bearer $1" -H "User-Agent: gpu-job" https://rest.runpod.io/v1/pods \
    | python3 -c "import json,sys
d=json.load(sys.stdin); d=d if isinstance(d,list) else d.get('data',d)
for p in d:
    if p.get('desiredStatus')=='RUNNING': print(p['id'], p.get('name',''))" 2>/dev/null
}

delete_pod(){ # <key> <pod-id>
  if [ -n "${GPU_JOB_DELETE_POD_CMD:-}" ]; then $GPU_JOB_DELETE_POD_CMD "$1" "$2"; return; fi
  curl -s -X DELETE -H "Authorization: Bearer $1" -H "User-Agent: gpu-job" \
    "https://rest.runpod.io/v1/pods/$2" >/dev/null
}

verify_gone(){ # <key> <pod-id> -> exit 0 iff gone
  if [ -n "${GPU_JOB_VERIFY_GONE_CMD:-}" ]; then $GPU_JOB_VERIFY_GONE_CMD "$1" "$2"; return; fi
  local out
  out=$(curl -s -H "Authorization: Bearer $1" -H "User-Agent: gpu-job" \
        "https://rest.runpod.io/v1/pods/$2" 2>/dev/null)
  # gone iff the pod is absent / no longer RUNNING
  printf '%s' "$out" | grep -q '"desiredStatus":[[:space:]]*"RUNNING"' && return 1 || return 0
}

# keepalive check for a LEGACY (contract-1) lease: future | past | "" (inconclusive)
keepalive_state(){ # <ssh-endpoint> <pod-id>
  if [ -n "${GPU_JOB_KEEPALIVE_CMD:-}" ]; then $GPU_JOB_KEEPALIVE_CMD "$1" "$2"; return; fi
  local ssh=$1 ip port keyfile u now
  ip=${ssh%%:*}; port=${ssh##*:}
  keyfile=$(cfg_get SSH_KEY_FILE); keyfile=${keyfile:-$HOME/.ssh/id_ed25519}
  u=$(ssh -i "$keyfile" -p "$port" -o StrictHostKeyChecking=no -o ConnectTimeout=15 \
        "root@$ip" 'cat /workspace/.keepalive_until_utc 2>/dev/null' 2>/dev/null) || { echo ""; return; }
  [ -n "$u" ] || { echo "past"; return; }   # no keepalive file -> not protected
  now=$(date -u +%s)
  [ "$(date -u -d "$u" +%s 2>/dev/null || echo 0)" -gt "$now" ] && echo future || echo past
}

# --- the sweep -----------------------------------------------------------------------------------

# Build: nonce -> "<pod_id> <state> <expiry_at>" and pod_id -> nonce, from the lease registry.
declare -A LEASE_POD LEASE_STATE
declare -A POD_TO_NONCE
while read -r nonce state pod exp; do
  [ -n "${nonce:-}" ] || continue
  LEASE_POD["$nonce"]="$pod"
  LEASE_STATE["$nonce"]="$state"
  [ "$pod" != "-" ] && [ -n "$pod" ] && POD_TO_NONCE["$pod"]="$nonce"
done < <(bash "$LEASE" list)

reaped=0; reported=0; kept=0; retried=0

# Reap one lease (by nonce) holding a verified-in-lock claim, then DELETE+verify.
reap_lease(){ # <nonce> <key> <pod-id>
  local nonce=$1 key=$2 pod=$3
  # The LOCKED reap: re-check expiry and claim `reaping` inside the lease lock (pod_lease.sh takes the
  # same lock refresh takes). If a refresh extended expiry, is-reapable now fails -> we abort, keep.
  if ! bash "$LEASE" is-reapable "$nonce"; then
    log "keep (refreshed under lock): $nonce pod=$pod"; kept=$((kept+1)); return
  fi
  if [ "$DRY" = 1 ]; then
    log "DRY-RUN would reap: nonce=$nonce pod=$pod"; reaped=$((reaped+1)); return
  fi
  bash "$LEASE" reaping "$nonce" >/dev/null || { log "report (claim failed): $nonce"; reported=$((reported+1)); return; }
  delete_pod "$key" "$pod" || true
  if verify_gone "$key" "$pod"; then
    bash "$LEASE" close "$nonce" >/dev/null || true
    log "REAPED: nonce=$nonce pod=$pod (deleted + verified gone)"; reaped=$((reaped+1))
  else
    # delete not verified: leave the lease expired (re-mark enriched-ish is not needed — reaping is
    # terminal-ish, but an unverified delete should retry; we re-open by NOT closing and logging).
    log "RETRY: nonce=$nonce pod=$pod delete not verified — lease left for next sweep"; retried=$((retried+1))
  fi
}

# Decide for one expired-candidate lease, including the legacy keepalive check.
consider_lease(){ # <nonce>
  local nonce=$1 pod=${LEASE_POD[$nonce]} state=${LEASE_STATE[$nonce]}
  case "$state" in intent|provisional|enriched) : ;; *) return ;; esac   # closed/reaping/invalid: skip
  bash "$LEASE" is-reapable "$nonce" || { kept=$((kept+1)); return; }     # not expired -> keep
  local key_ref key
  key_ref=$(bash "$LEASE" show "$nonce" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("key_ref",""))' 2>/dev/null)
  key=$(resolve_key "$key_ref")
  if [ -z "$key" ]; then
    log "report (unresolved key_ref '$key_ref'): nonce=$nonce pod=$pod"; reported=$((reported+1)); return
  fi
  # MIGRATION: contract-1 (legacy) leases need the pod-side keepalive check; contract-2 reaps on
  # lease expiry alone.
  local contract ssh
  contract=$(bash "$LEASE" show "$nonce" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("refresh_contract",2))' 2>/dev/null)
  if [ "$contract" = 1 ]; then
    ssh=$(bash "$LEASE" show "$nonce" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("ssh") or "")' 2>/dev/null)
    if [ -n "$ssh" ]; then
      local ka; ka=$(keepalive_state "$ssh" "$pod")
      case "$ka" in
        future) log "keep (legacy keepalive future): nonce=$nonce pod=$pod"; kept=$((kept+1)); return;;
        "")     log "report-retry (legacy keepalive inconclusive): nonce=$nonce pod=$pod"; retried=$((retried+1)); return;;
        past)   : ;;   # both controller-expired AND no future keepalive -> reap
      esac
    fi
  fi
  reap_lease "$nonce" "$key" "$pod"
}

log "sweep start${DRY:+ (dry-run=$DRY)} root=${GPU_JOB_LEASE_DIR:-$HOME/.config/gpu-job/leases}"

# 1. Reap/keep over the lease registry (the only set we ever DELETE from).
for nonce in "${!LEASE_POD[@]}"; do
  consider_lease "$nonce"
done

# 2. report-only over live pods that no lease accounts for (unknown / ambiguous-nonce). We list pods
#    per resolved key seen in the registry; a pod with no lease and no matching pending-intent nonce
#    is REPORTED, never deleted.
declare -A SEEN_KEY
for nonce in "${!LEASE_POD[@]}"; do
  kr=$(bash "$LEASE" show "$nonce" 2>/dev/null | python3 -c 'import json,sys;print(json.load(sys.stdin).get("key_ref",""))' 2>/dev/null)
  [ -n "$kr" ] || continue
  [ -n "${SEEN_KEY[$kr]:-}" ] && continue
  SEEN_KEY["$kr"]=1
  key=$(resolve_key "$kr")
  [ -n "$key" ] || continue
  while read -r pod name; do
    [ -n "${pod:-}" ] || continue
    [ -n "${POD_TO_NONCE[$pod]:-}" ] && continue          # accounted for by a lease
    # try to match an unknown pod to a PENDING INTENT by nonce (exact, ambiguous->empty=report)
    m=$(bash "$LEASE" find-nonce "$name")
    if [ -n "$m" ]; then
      log "report (pending-intent match, not yet provisional): pod=$pod nonce=$m"; reported=$((reported+1))
    else
      log "report-only (UNKNOWN pod, no lease — NEVER deleted): pod=$pod name=$name"; reported=$((reported+1))
    fi
  done < <(list_pods "$key")
done

log "sweep done: reaped=$reaped kept=$kept reported=$reported retried=$retried${DRY:+ (DRY-RUN — nothing deleted)}"
