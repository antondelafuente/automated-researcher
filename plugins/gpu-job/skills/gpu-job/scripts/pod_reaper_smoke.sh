#!/usr/bin/env bash
# Smoke for pod_reaper.sh — the #54 child-2 box-level reaper. Runs OFFLINE: the provider seams
# (list/delete/verify/keepalive/resolve-key) are stubbed via env so no RunPod call is made. Covers the
# four design-review fixtures + the locked-reap race:
#   - reap an expired registered lease; keep a fresh one
#   - report-only an UNKNOWN pod (never deleted) — gpu-job's "never blanket-delete" rule
#   - report-only a lease whose key_ref does NOT resolve (Finding 2)
#   - pending-intent nonce match is report-only (not deleted)
#   - legacy contract-1: keepalive future -> keep; inconclusive -> retry (NOT delete, Finding 3); past -> reap
#   - the locked reap: a refresh that extends expiry between classify and delete SAVES the pod (Finding 1)
#   - --dry-run deletes nothing
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
LEASE="$HERE/pod_lease.sh"
REAPER="$HERE/pod_reaper.sh"
[ -f "$LEASE" ] && [ -f "$REAPER" ] || { echo "FAIL: missing scripts"; exit 1; }

TMP=$(mktemp -d) || { echo "FAIL: mktemp"; exit 1; }
trap 'rm -rf "$TMP"' EXIT
export GPU_JOB_LEASE_DIR="$TMP/leases"
DEL_LOG="$TMP/deletes.log"; : > "$DEL_LOG"
GONE="$TMP/gone"; mkdir -p "$GONE"        # a pod-id file here means "verify says gone"
mkdir -p "$GPU_JOB_LEASE_DIR"

fails=0
ok(){ echo "ok   $1"; }
no(){ echo "FAIL $1"; fails=1; }
lease(){ bash "$LEASE" "$@"; }
deleted(){ grep -qx "$1" "$DEL_LOG"; }    # was pod $1 deleted?

# --- provider stubs (exported so pod_reaper.sh's seams pick them up) ---
cat > "$TMP/list.sh"   <<EOF
#!/bin/bash
# emit "<pod-id> <name>" for the "live" pods declared in $TMP/pods.txt (any key)
cat "$TMP/pods.txt" 2>/dev/null || true
EOF
cat > "$TMP/del.sh"    <<EOF
#!/bin/bash
echo "\$2" >> "$DEL_LOG"      # record the deleted pod id; mark it gone so verify passes
touch "$GONE/\$2"
EOF
cat > "$TMP/verify.sh" <<EOF
#!/bin/bash
[ -f "$GONE/\$2" ]            # exit 0 iff gone
EOF
cat > "$TMP/resolve.sh" <<EOF
#!/bin/bash
# resolve every key_ref EXCEPT the literal UNRESOLVABLE
[ "\$1" = UNRESOLVABLE ] && exit 0
echo "secret-for-\$1"
EOF
cat > "$TMP/keepalive.sh" <<EOF
#!/bin/bash
# echo the keepalive verdict declared per-pod in $TMP/keepalive_<podid>
cat "$TMP/keepalive_\$2" 2>/dev/null || echo ""
EOF
chmod +x "$TMP"/*.sh
export GPU_JOB_LIST_PODS_CMD="bash $TMP/list.sh"
export GPU_JOB_DELETE_POD_CMD="bash $TMP/del.sh"
export GPU_JOB_VERIFY_GONE_CMD="bash $TMP/verify.sh"
export GPU_JOB_RESOLVE_KEY_CMD="bash $TMP/resolve.sh"
export GPU_JOB_KEEPALIVE_CMD="bash $TMP/keepalive.sh"

mk_lease(){ # mk_lease <pod-id> <expiry-min> <key-ref> [contract] [ssh]  -> prints nonce
  local pod=$1 exp=$2 kr=$3 contract=${4:-2} ssh=${5:-}
  local n; n=$(lease intent "$kr" --expiry-min "$exp")
  lease provisional "$n" "$pod" >/dev/null
  if [ "$contract" = 1 ]; then
    # contract-1 legacy lease: enrich with ssh + downgrade refresh_contract to 1 via direct edit
    [ -n "$ssh" ] && lease enrich "$n" --ssh "$ssh" --expiry-min "$exp" >/dev/null
    python3 - "$GPU_JOB_LEASE_DIR/$n.json" <<PY
import json,sys
p=sys.argv[1]; d=json.load(open(p)); d["refresh_contract"]=1
json.dump(d, open(p,"w"), indent=2, sort_keys=True)
PY
  fi
  printf '%s\n' "$n"
}

# === fixture 1: expired registered lease is REAPED; fresh one is KEPT ===
EXP=$(mk_lease pod-exp -1 RUNPOD_API_KEY)
FRESH=$(mk_lease pod-fresh 120 RUNPOD_API_KEY)
# === fixture 2: an UNKNOWN live pod (no lease) ===
# === fixture 3: an unresolved-key lease ===
UNRES=$(mk_lease pod-unres -1 UNRESOLVABLE)
# === fixture 4: a pending intent (no pod bound) whose nonce names a live pod ===
PEND=$(lease intent RUNPOD_API_KEY --expiry-min 15)
# === fixture 5: legacy contract-1 leases, keepalive future / inconclusive / past ===
LF=$(mk_lease pod-lf -1 RUNPOD_API_KEY 1 9.9.9.9:22); echo future       > "$TMP/keepalive_pod-lf"
LI=$(mk_lease pod-li -1 RUNPOD_API_KEY 1 9.9.9.9:22); echo ""           > "$TMP/keepalive_pod-li"
LP=$(mk_lease pod-lp -1 RUNPOD_API_KEY 1 9.9.9.9:22); echo past         > "$TMP/keepalive_pod-lp"

# the "live" pod list the stub returns (pod-id name)
cat > "$TMP/pods.txt" <<EOF
pod-exp $EXP
pod-fresh $FRESH
pod-unres $UNRES
pod-unknown some-user-name
$PEND $PEND
pod-lf $LF
pod-li $LI
pod-lp $LP
EOF

OUT=$(bash "$REAPER" 2>&1)

deleted pod-exp           && ok reap-expired || no reap-expired
deleted pod-fresh         && no keep-fresh-deleted || ok keep-fresh-kept
deleted pod-unknown       && no unknown-deleted || ok unknown-report-only
deleted pod-unres         && no unresolved-deleted || ok unresolved-report-only
deleted pod-lf            && no legacy-future-deleted || ok legacy-future-kept
deleted pod-li            && no legacy-inconclusive-deleted || ok legacy-inconclusive-retry
deleted pod-lp            && ok legacy-past-reaped || no legacy-past-reaped
echo "$OUT" | grep -q "pending-intent match" && ok pending-intent-reported || no pending-intent-reported
echo "$OUT" | grep -q "UNKNOWN pod" && ok unknown-logged || no unknown-logged
# a reaped lease is CLOSED after verified delete
[ "$(lease show "$EXP" | python3 -c 'import json,sys;print(json.load(sys.stdin)["state"])')" = closed ] \
  && ok reaped-lease-closed || no reaped-lease-closed

# === locked-reap race (Finding 1): a refresh that lands before the reaper's in-lock recheck SAVES
#     the pod. Simulate by refreshing the expired lease to a future expiry, THEN sweeping. ===
RACE=$(mk_lease pod-race -1 RUNPOD_API_KEY)
echo "pod-race $RACE" >> "$TMP/pods.txt"
lease refresh "$RACE" --expiry-min 120 >/dev/null     # the long run refreshed just in time
bash "$REAPER" >/dev/null 2>&1
deleted pod-race && no race-refresh-lost || ok race-refresh-saves-pod

# === --dry-run deletes NOTHING even for an expired lease ===
: > "$DEL_LOG"
DRYEXP=$(mk_lease pod-dry -1 RUNPOD_API_KEY)
echo "pod-dry $DRYEXP" >> "$TMP/pods.txt"
DOUT=$(bash "$REAPER" --dry-run 2>&1)
deleted pod-dry && no dryrun-deleted || ok dryrun-deletes-nothing
echo "$DOUT" | grep -q "DRY-RUN would reap" && ok dryrun-logs-would-reap || no dryrun-logs-would-reap
# the dry-run lease is NOT closed/reaping
[ "$(lease show "$DRYEXP" | python3 -c 'import json,sys;print(json.load(sys.stdin)["state"])')" = provisional ] \
  && ok dryrun-no-mutation || no dryrun-no-mutation

[ "$fails" = 0 ] && { echo "pod_reaper smoke PASS"; exit 0; } || { echo "pod_reaper smoke FAIL"; exit 1; }
