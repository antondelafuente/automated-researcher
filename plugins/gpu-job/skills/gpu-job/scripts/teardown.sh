#!/bin/bash
# teardown.sh <pod-id> [lease-nonce] — DELETE a pod (the default the moment a run completes) and list
# anything still RUNNING so nothing bills silently. RULES this encodes: tear down only
# AFTER artifacts are verified in your store (before that, DELETE loses data — that gate
# is the whole ballgame); never use the provider's "stop" expecting keep-warm (container
# disk is wiped on restart — same loss as delete, still billing storage); pod-id-scoped,
# never blanket-delete (parallel runs own their own pods).
#
# If a [lease-nonce] (the #54 child-2 pod lease) is passed, the lease is CLOSED only AFTER the pod's
# deletion is VERIFIED on the control plane — closing it on an unverified delete would turn a failed
# teardown into an UNKNOWN pod the reaper only reports (a billing orphan). An unverified delete leaves
# the lease expired for the standing reaper to retry. Without a nonce, behavior is unchanged.
set -euo pipefail
PID=${1:?pod id}
NONCE=${2:-}
HERE=$(cd "$(dirname "$0")" && pwd)
KEY_NAME=$(grep -E "^API_KEY_ENV=" ~/.config/gpu-job/env 2>/dev/null | cut -d= -f2-); KEY_NAME="${API_KEY_ENV:-${KEY_NAME:-RUNPOD_API_KEY}}"
KEY=$(grep -E "^$KEY_NAME=" ~/.config/gpu-job/env 2>/dev/null | cut -d= -f2- || eval echo "\${$KEY_NAME:?}")
curl -s -X DELETE -H "Authorization: Bearer $KEY" -H "User-Agent: gpu-job" \
  "https://rest.runpod.io/v1/pods/$PID" >/dev/null && echo "deleted $PID"

# Close the lease ONLY after verifying the pod is actually gone on the control plane.
if [ -n "$NONCE" ] && [ -f "$HERE/pod_lease.sh" ]; then
  still=$(curl -s -H "Authorization: Bearer $KEY" -H "User-Agent: gpu-job" \
            "https://rest.runpod.io/v1/pods/$PID" 2>/dev/null | grep -c '"desiredStatus":[[:space:]]*"RUNNING"' || true)
  if [ "${still:-0}" = 0 ]; then
    bash "$HERE/pod_lease.sh" close "$NONCE" >/dev/null && echo "lease $NONCE closed (delete verified)"
  else
    echo "WARNING: pod $PID still RUNNING after DELETE — lease $NONCE left for the reaper to retry (NOT closed)" >&2
  fi
fi

echo "still RUNNING (verify these are yours and intended):"
curl -s -H "Authorization: Bearer $KEY" -H "User-Agent: gpu-job" https://rest.runpod.io/v1/pods \
  | python3 -c "import json,sys
d=json.load(sys.stdin); d=d if isinstance(d,list) else d.get('data',d)
print([f\"{p['id']} {p.get('name')} \${p.get('costPerHr')}/hr\" for p in d if p.get('desiredStatus')=='RUNNING'] or 'none')"
