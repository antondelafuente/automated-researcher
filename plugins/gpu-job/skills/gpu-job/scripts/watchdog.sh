#!/bin/bash
# watchdog.sh <pod-id> <ip> <ssh-port> [grace-seconds=1200]
# Detached idle-teardown: if you step away, a finished/orphaned pod gets deleted after the
# grace period instead of billing forever. Honors a pod-side keepalive: a job that wants to
# live writes a UTC timestamp to /workspace/.keepalive_until_utc (expiry-stamped on purpose —
# bare flag files become stale-flag footguns). Runs box-side, detached, SCOPED TO THIS POD ID.
set -u
PID=${1:?} IP=${2:?} PORT=${3:?} GRACE=${4:-1200}
KEY_FILE=$(grep -E "^SSH_KEY_FILE=" ~/.config/gpu-job/env 2>/dev/null | cut -d= -f2- || echo ~/.ssh/id_ed25519)
API_KEY=$(grep -E "^RUNPOD_API_KEY=" ~/.config/gpu-job/env 2>/dev/null | cut -d= -f2-)
cat > /tmp/gpu_job_watchdog_$PID.sh <<EOS
sleep $GRACE
u=\$(ssh -i $KEY_FILE -p $PORT -o StrictHostKeyChecking=no -o ConnectTimeout=15 root@$IP 'cat /workspace/.keepalive_until_utc 2>/dev/null')
now=\$(date -u +%s)
[ -n "\$u" ] && [ "\$(date -u -d "\$u" +%s 2>/dev/null || echo 0)" -gt "\$now" ] && exit 0
curl -s -X DELETE -H "Authorization: Bearer $API_KEY" -H "User-Agent: gpu-job" https://rest.runpod.io/v1/pods/$PID >/dev/null
EOS
setsid nohup bash /tmp/gpu_job_watchdog_$PID.sh >/tmp/gpu_job_watchdog_$PID.log 2>&1 &
echo "watchdog armed: pod $PID deletes after ${GRACE}s unless /workspace/.keepalive_until_utc is in the future"
