#!/bin/bash
# teardown.sh <pod-id> — DELETE a pod (the default the moment a run completes) and list
# anything still RUNNING so nothing bills silently. RULES this encodes: tear down only
# AFTER artifacts are verified in your store (before that, DELETE loses data — that gate
# is the whole ballgame); never use the provider's "stop" expecting keep-warm (container
# disk is wiped on restart — same loss as delete, still billing storage); pod-id-scoped,
# never blanket-delete (parallel runs own their own pods).
set -euo pipefail
PID=${1:?pod id}
KEY=$(grep -E "^RUNPOD_API_KEY=" ~/.config/gpu-job/env 2>/dev/null | cut -d= -f2- || echo "${RUNPOD_API_KEY:?}")
curl -s -X DELETE -H "Authorization: Bearer $KEY" -H "User-Agent: gpu-job" \
  "https://rest.runpod.io/v1/pods/$PID" >/dev/null && echo "deleted $PID"
echo "still RUNNING (verify these are yours and intended):"
curl -s -H "Authorization: Bearer $KEY" -H "User-Agent: gpu-job" https://rest.runpod.io/v1/pods \
  | python3 -c "import json,sys
d=json.load(sys.stdin); d=d if isinstance(d,list) else d.get('data',d)
print([f\"{p['id']} {p.get('name')} \${p.get('costPerHr')}/hr\" for p in d if p.get('desiredStatus')=='RUNNING'] or 'none')"
