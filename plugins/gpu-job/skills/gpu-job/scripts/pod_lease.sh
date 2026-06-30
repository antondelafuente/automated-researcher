#!/bin/bash
# pod_lease.sh — the gpu-job POD LEASE: a tiny, DELETION-SCOPED record written at acquire so a
# standing model-free reaper can safely delete an abandoned pod (the #54 crash-resilience design,
# child 2 / #169). PRODUCT helper — no instance specifics (the systemd/bash sweep schedule and the
# secret key values are instance; they are consumed through this API + the API_KEY_ENV seam).
#
# WHAT IT IS: a per-pod JSON lease carrying ONLY what DELETION needs —
#   nonce / pod_id / key_ref (the durable API_KEY_ENV reference the reaper resolves on its own) /
#   expiry_at / cost_per_hr / ssh (once enriched) / state / refresh_contract. Anything run-shaped
#   (owner, artifact path, handoff_path, desired-active) lives in the run-supervision record
#   (experiment-lifecycle, #168), which links to this lease BY POD ID. This record never holds
#   relaunch policy and the run-supervision record never holds deletion policy.
#
# WHY A HELPER, NOT PROSE: the lease is genuinely stateful and is read/written by three independent
#   actors (acquire, teardown, the reaper). One product implementation owns the atomic-write +
#   per-lease-lock semantics so the reaper's locked reap and a long run's refresh are strictly
#   serialized (the classify-then-delete race the design review caught, Finding 1).
#
# THREE-PHASE CREATE (no un-leased billing window, #169 B.0):
#   intent      <key-ref> [--expiry-min N]   -> mint a nonce, write it + key_ref + a SHORT default
#                                               expiry BEFORE deploy(); pass the nonce as the pod name.
#                                               Prints the nonce. The reaper can match an otherwise-
#                                               unknown pod to this pending intent BY NONCE.
#   provisional <nonce> <pod-id>             -> bind the real pod id once deploy() returns it.
#   enrich      <nonce> --ssh H:P --expiry-min N [--cost C]
#                                            -> add the SSH endpoint + the run's real expiry.
#
# LIFECYCLE:
#   refresh <id> --expiry-min N              -> extend expiry for a long run (controller-side
#                                               generalization of the pod-side keepalive). Takes the
#                                               SAME lock the reaper's delete takes.
#   close   <id>                             -> ONLY after the pod's deletion is verified on the
#                                               control plane (caller's job). Terminal.
#   claim-reaping <id>                       -> ATOMIC locked-reap claim: in ONE lock, re-check the
#                                               lease is still expired AND mark it `reaping`. Exit 0 =
#                                               claimed (caller may DELETE); exit 1 = a refresh moved
#                                               expiry forward, no mutation (keep). pod_reaper.sh uses
#                                               this (NOT is-reapable + reaping, which has a race window).
#   unclaim-reaping <id>                     -> revert a `reaping` lease to a reapable active state so
#                                               the NEXT sweep retries it (used on an UNVERIFIED delete).
#   reaping <id>                             -> mark a lease `reaping` unconditionally (low-level).
#   is-reapable <id>                         -> exit 0 iff state is registerable AND expiry_at is in
#                                               the PAST; else exit 1. (Read-only probe.)
#   show / list / path / lock-path / find-nonce  -> inspection + the reaper's primitives.
#
# <id> is the NONCE for an intent/provisional lease and stays the nonce after provisional/enrich, so
#   a lease is always addressable by its stable nonce. find-nonce maps a pod NAME back to a pending
#   intent (exact whole-string match only; ambiguous -> empty, the reaper treats that as report-only).
#
# STATES (monotonic where terminal): intent -> provisional -> enriched ; any -> reaping|closed.
#   reaping and closed are terminal. expiry_at drives reapability; refresh moves it forward.
#
# Registry root is instance-overridable: ${GPU_JOB_LEASE_DIR:-$HOME/.config/gpu-job/leases}.
set -euo pipefail

# write_record reads these generic overlay vars from the environment; an INHERITED value from the
# caller's shell must never leak into a lease write (round-3 Finding 3). Clear them up front — every
# real mutation sets the ones it means via an inline `VAR=val write_record` call, which re-exports just
# those for that single subprocess.
unset POD_ID SSH STATE COST EXPIRY_MIN NONCE KEY_REF CREATE CLAIMED_AT DELETE_ACCEPTED 2>/dev/null || true

ROOT="${GPU_JOB_LEASE_DIR:-$HOME/.config/gpu-job/leases}"

die(){ echo "pod_lease: $*" >&2; exit 2; }

# A lease id (the nonce) is used as a filename — keep it path-safe.
validate_id(){
  [ -n "${1:-}" ] || die "missing <id>"
  case "$1" in
    *[!A-Za-z0-9._-]*) die "invalid id '$1' (allowed: A-Za-z0-9._-)";;
    .|..) die "invalid id '$1'";;
  esac
}

record_path(){ printf '%s/%s.json' "$ROOT" "$1"; }
lock_path(){ printf '%s/%s.lock' "$ROOT" "$1"; }

# Mint a collision-proof nonce: a `gpujob-` prefix + 16 random bytes hex. The prefix means a
# user-chosen POD_NAME can never collide, and the full entropy means two intents never collide.
mint_nonce(){ printf 'gpujob-%s' "$(python3 -c 'import secrets;print(secrets.token_hex(16))')"; }

# Read a top-level field from the lease JSON ("" if record or field absent).
get_field(){ # <file> <field>
  python3 - "$1" "$2" <<'PY' 2>/dev/null || true
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
v = d.get(sys.argv[2])
if v is None:
    sys.exit(0)
if isinstance(v, bool):
    print("true" if v else "false")
else:
    print(v)
PY
}

# Classify a lease path's on-disk state in ONE word so the shell fails closed (a corrupt lease must
# NEVER read as an empty active one). Prints: absent | invalid | intent | provisional | enriched | reaping | closed.
classify_record(){ # <file>
  python3 - "$1" <<'PY'
import json, os, sys
path = sys.argv[1]
if not os.path.exists(path):
    print("absent"); sys.exit(0)
try:
    d = json.load(open(path))
    if not isinstance(d, dict):
        raise ValueError
except Exception:
    print("invalid"); sys.exit(0)
st = d.get("state")
print(st if st in ("intent", "provisional", "enriched", "reaping", "closed") else "invalid")
PY
}

# Atomically write/patch the lease from kwargs. Always called under the lock. `create=true` writes a
# fresh intent record (caller has already classified+guarded the on-disk state). Every other mutation
# fails CLOSED on malformed existing JSON (exit 3) rather than treating it as empty.
write_record(){ # <file> CREATE= POD_ID= SSH= EXPIRY_MIN= COST= STATE= KEY_REF= NONCE=
  local file=$1
  python3 - "$file" <<'PY'
import json, os, sys, tempfile, time

path = sys.argv[1]
creating = os.environ.get("CREATE") == "true"
try:
    rec = json.load(open(path))
    if not isinstance(rec, dict):
        raise ValueError
except FileNotFoundError:
    rec = {}
except Exception:
    if not creating:
        sys.stderr.write("malformed pod lease JSON: %s\n" % path)
        sys.exit(3)
    rec = {}

now = int(time.time())
if creating:
    rec = {
        "nonce": os.environ.get("NONCE", ""),
        "pod_id": None,
        "key_ref": os.environ.get("KEY_REF", ""),
        "ssh": None,
        "cost_per_hr": None,
        "expiry_at": None,
        "state": "intent",
        # refresh_contract v2 = controller-side expiry is the SOLE deletion authority (no pod-side
        # keepalive read). A lease created by this helper is always new-contract.
        "refresh_contract": 2,
        "created_at": now,
    }

def setif(key, env):
    v = os.environ.get(env, "")
    if v != "":
        rec[key] = v

# On CREATE the record is fully defined by NONCE/KEY_REF/EXPIRY_MIN above; the generic overlay vars
# (POD_ID/SSH/STATE/COST) must NOT be applied, or an intent could inherit an exported POD_ID/SSH/STATE/
# COST from the caller's environment and corrupt a brand-new lease before deploy bound the pod
# (code-review round-3 Finding 3). Those overlays only ever apply to a non-create mutation, which sets
# them deliberately via the inline `VAR=… write_record` call.
if not creating:
    setif("pod_id", "POD_ID")
    setif("ssh", "SSH")
    setif("state", "STATE")
    cost = os.environ.get("COST", "")
    if cost != "":
        rec["cost_per_hr"] = cost
    ca = os.environ.get("CLAIMED_AT", "")
    if ca != "":
        rec["claimed_at"] = int(ca)
    if os.environ.get("DELETE_ACCEPTED") == "true":
        rec["delete_accepted"] = True
em = os.environ.get("EXPIRY_MIN", "")
if em != "":
    rec["expiry_at"] = now + int(float(em) * 60)
rec["updated_at"] = now

d = os.path.dirname(path) or "."
fd, tmp = tempfile.mkstemp(dir=d, prefix=".lease.", suffix=".tmp")
try:
    with os.fdopen(fd, "w") as f:
        json.dump(rec, f, indent=2, sort_keys=True)
        f.write("\n")
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, path)
except Exception:
    try:
        os.unlink(tmp)
    except OSError:
        pass
    raise
PY
}

# Run <fn> ... holding the per-lease lock (the whole read-modify-write window).
with_lock(){ # <id> <fn> [args...]
  local id=$1; shift
  mkdir -p "$ROOT"
  local lock; lock=$(lock_path "$id")
  exec 9>"$lock"
  flock 9
  "$@"
}

require_val(){ [ -n "${2:-}" ] || die "$1 requires a non-empty value (got empty/missing)"; }

cmd_intent(){
  local key_ref=$1; shift
  require_val "<key-ref>" "$key_ref"
  local expiry_min=15
  while [ $# -gt 0 ]; do
    case "$1" in
      --expiry-min) require_val --expiry-min "${2:-}"; expiry_min=$2; shift 2;;
      *) die "intent: unknown arg '$1'";;
    esac
  done
  mkdir -p "$ROOT"
  local nonce; nonce=$(mint_nonce)
  local file; file=$(record_path "$nonce")
  # nonce is fresh 128-bit entropy: an existing file would be a catastrophic RNG failure — fail closed.
  [ -e "$file" ] && die "intent: nonce collision on $nonce (refusing to overwrite)"
  NONCE="$nonce" KEY_REF="$key_ref" EXPIRY_MIN="$expiry_min" CREATE=true write_record "$file"
  echo "$nonce"
}

cmd_provisional(){
  local id=$1 pod_id=$2
  require_val "<pod-id>" "$pod_id"
  local file; file=$(record_path "$id")
  local state; state=$(classify_record "$file")
  case "$state" in
    intent) : ;;
    absent)  die "provisional: no intent for '$id'";;
    invalid) die "provisional: lease '$id' is malformed — inspect $file";;
    closed|reaping) die "provisional: lease '$id' is terminal ($state) — refusing";;
    provisional|enriched) die "provisional: lease '$id' already past intent ($state)";;
    *) die "provisional: unexpected state '$state'";;
  esac
  POD_ID="$pod_id" STATE=provisional write_record "$file"
  echo "bound pod $pod_id to lease $id (provisional)"
}

cmd_enrich(){
  local id=$1; shift
  local ssh="" expiry_min="" cost=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --ssh) require_val --ssh "${2:-}"; ssh=$2; shift 2;;
      --expiry-min) require_val --expiry-min "${2:-}"; expiry_min=$2; shift 2;;
      --cost) require_val --cost "${2:-}"; cost=$2; shift 2;;
      *) die "enrich: unknown arg '$1'";;
    esac
  done
  [ -n "$expiry_min" ] || die "enrich: --expiry-min is required (the run's real expiry)"
  local file; file=$(record_path "$id")
  local state; state=$(classify_record "$file")
  case "$state" in
    provisional|enriched) : ;;   # enrich is idempotent/refreshable from provisional or enriched
    absent)  die "enrich: no lease for '$id'";;
    invalid) die "enrich: lease '$id' is malformed — inspect $file";;
    intent)  die "enrich: lease '$id' has no pod id yet (call provisional first)";;
    closed|reaping) die "enrich: lease '$id' is terminal ($state) — refusing";;
    *) die "enrich: unexpected state '$state'";;
  esac
  SSH="$ssh" EXPIRY_MIN="$expiry_min" COST="$cost" STATE=enriched write_record "$file"
  echo "enriched lease $id (ssh=${ssh:-?} expiry+${expiry_min}min)"
}

cmd_refresh(){
  local id=$1; shift
  local expiry_min=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --expiry-min) require_val --expiry-min "${2:-}"; expiry_min=$2; shift 2;;
      *) die "refresh: unknown arg '$1'";;
    esac
  done
  [ -n "$expiry_min" ] || die "refresh: --expiry-min is required"
  local file; file=$(record_path "$id")
  local state; state=$(classify_record "$file")
  case "$state" in
    provisional|enriched) : ;;
    absent)  die "refresh: no lease for '$id'";;
    invalid) die "refresh: lease '$id' is malformed — inspect $file";;
    intent)  die "refresh: lease '$id' has no pod yet";;
    closed)  die "refresh: lease '$id' is closed (terminal) — refusing";;
    reaping) die "refresh: lease '$id' is being reaped (terminal) — refusing";;
    *) die "refresh: unexpected state '$state'";;
  esac
  EXPIRY_MIN="$expiry_min" write_record "$file"
  echo "refreshed lease $id (expiry +${expiry_min}min)"
}

# emergency: the provisional-write-failure path (deploy_pod.py). The pod is REST-created and billing but
# its lease is still `intent`; this binds the discovered pod id AND forces expiry to NOW in one atomic
# write, tolerant of the intent state (round-6 Finding 3 — enrich refuses an intent-only lease, so it
# couldn't force expiry here). The result is a provisional, already-expired lease the reaper reaps on
# the next sweep — the explicit emergency record, never a silent un-leased orphan.
cmd_emergency(){
  local id=$1 pod=$2
  require_val "<pod-id>" "$pod"
  local file; file=$(record_path "$id")
  local state; state=$(classify_record "$file")
  case "$state" in
    intent|provisional|enriched) : ;;
    absent)  die "emergency: no lease for '$id'";;
    invalid) die "emergency: lease '$id' is malformed — inspect $file";;
    closed)  die "emergency: lease '$id' is closed (terminal) — refusing";;
    reaping) echo "emergency: lease '$id' already reaping (no-op)"; return 0;;
    *) die "emergency: unexpected state '$state'";;
  esac
  POD_ID="$pod" STATE=provisional EXPIRY_MIN="0" write_record "$file"
  echo "emergency lease $id bound pod $pod, expired NOW (reaper will reap)"
}

# expire: set expiry_at to NOW so the lease is IMMEDIATELY reapable on the next sweep. Used by teardown
# when a delete could not be verified gone (round-4 Finding 3): the lease must not keep its future run
# expiry, or the reaper wouldn't retry the abandoned-but-billing pod for hours. Refuses terminal leases.
cmd_expire(){
  local id=$1; local file; file=$(record_path "$id")
  local state; state=$(classify_record "$file")
  case "$state" in
    provisional|enriched) : ;;
    absent)  die "expire: no lease for '$id'";;
    invalid) die "expire: lease '$id' is malformed — inspect $file";;
    intent)  die "expire: lease '$id' has no pod yet";;
    closed)  die "expire: lease '$id' is closed (terminal) — refusing";;
    reaping) echo "expire: lease '$id' already reaping (no-op)"; return 0;;
    *) die "expire: unexpected state '$state'";;
  esac
  EXPIRY_MIN="0" write_record "$file"
  echo "expired lease $id (immediately reapable)"
}

cmd_close(){
  local id=$1; local file; file=$(record_path "$id")
  local state; state=$(classify_record "$file")
  case "$state" in
    closed)  echo "close: lease '$id' already closed (no-op)"; return 0;;
    absent)  die "close: no lease for '$id'";;
    invalid) die "close: lease '$id' is malformed — inspect $file";;
    *) : ;;   # intent/provisional/enriched/reaping -> close is the finalizer after verified deletion
  esac
  STATE=closed write_record "$file"
  echo "closed lease $id"
}

# reaping: mark a lease `reaping` unconditionally (low-level). pod_reaper.sh uses claim-reaping (the
# atomic re-check + mark) instead; this is kept for direct/diagnostic use. Refuses to mark a closed lease.
cmd_reaping(){
  local id=$1; local file; file=$(record_path "$id")
  local state; state=$(classify_record "$file")
  case "$state" in
    closed)  die "reaping: lease '$id' already closed";;
    reaping) echo "reaping: lease '$id' already marked (no-op)"; return 0;;
    absent)  die "reaping: no lease for '$id'";;
    invalid) die "reaping: lease '$id' is malformed — inspect $file";;
    *) : ;;
  esac
  STATE=reaping write_record "$file"
  echo "marked lease $id reaping"
}

# mark-deleted: persist that the provider ACCEPTED a DELETE for this lease's pod (round-7 Finding 3), so
# a later retry can close on verified-gone even if a fresh DELETE then 404s (pod already gone). Survives
# unclaim-reaping. Refuses a closed lease.
cmd_mark_deleted(){
  local id=$1; local file; file=$(record_path "$id")
  local state; state=$(classify_record "$file")
  case "$state" in
    closed)  die "mark-deleted: lease '$id' already closed";;
    absent)  die "mark-deleted: no lease for '$id'";;
    invalid) die "mark-deleted: lease '$id' is malformed — inspect $file";;
    *) : ;;
  esac
  DELETE_ACCEPTED=true write_record "$file"
  echo "marked lease $id delete-accepted"
}

# claim-reaping: the ATOMIC locked-reap claim (code-review Finding 1). In ONE lock acquisition it
# RE-CHECKS that the lease is still reapable (expiry still in the past) AND marks it `reaping`. Exit 0
# iff the claim succeeded (caller may now DELETE); exit 1 if a concurrent refresh moved expiry into the
# future (no mutation — the pod is kept). This collapses the former is-reapable + reaping two-call
# window where a refresh could land between the unlock and the mark.
# A reaping claim older than this is STALE (the reaper crashed after claiming, before delete+verify) and
# is reclaimable, so a stuck `reaping` lease never bills forever (round-6 Finding 1). Instance-tunable.
STALE_REAPING_SEC="${GPU_JOB_STALE_REAPING_SEC:-900}"

cmd_claim_reaping(){
  local id=$1; local file; file=$(record_path "$id")
  # Reclaimable INSIDE the lock iff: a reapable (expired, non-terminal) lease, OR a STALE `reaping`
  # claim (a prior reaper crashed mid-reap). A `reaping` claim younger than the staleness window is
  # owned by a live reaper -> not reclaimable (exit 1, no double-reap).
  local verdict
  verdict=$(STALE="$STALE_REAPING_SEC" python3 - "$file" <<'PY'
import json, os, sys, time
try:
    d = json.load(open(sys.argv[1]))
    if not isinstance(d, dict):
        raise ValueError
except Exception:
    print("no"); sys.exit(0)
now = int(time.time()); state = d.get("state"); exp = d.get("expiry_at")
stale = int(os.environ.get("STALE", "900"))
if state in ("intent", "provisional", "enriched") and isinstance(exp, int) and exp <= now:
    print("claim")
elif state == "reaping":
    ca = d.get("claimed_at")
    print("claim" if (not isinstance(ca, int) or (now - ca) >= stale) else "no")
else:
    print("no")
PY
)
  [ "$verdict" = claim ] || { echo "claim-reaping: lease '$id' not reclaimable (refreshed/closed/fresh-claim) — keep" >&2; exit 1; }
  CLAIMED_AT="$(date -u +%s)" STATE=reaping write_record "$file"
  echo "claimed lease $id for reaping"
}

# would-claim: READ-ONLY predicate mirroring claim-reaping's decision (expired non-terminal OR stale
# reaping) WITHOUT mutating — for honest dry-run logging (round-8 Finding 2). Exit 0 = a real sweep
# would claim+reap this lease; exit 1 otherwise.
cmd_would_claim(){
  local id=$1; local file; file=$(record_path "$id")
  [ -f "$file" ] || exit 1
  STALE="$STALE_REAPING_SEC" python3 - "$file" <<'PY'
import json, os, sys, time
try:
    d = json.load(open(sys.argv[1]))
    if not isinstance(d, dict):
        raise ValueError
except Exception:
    sys.exit(1)
now = int(time.time()); state = d.get("state"); exp = d.get("expiry_at")
stale = int(os.environ.get("STALE", "900"))
if state in ("intent", "provisional", "enriched") and isinstance(exp, int) and exp <= now:
    sys.exit(0)
if state == "reaping":
    ca = d.get("claimed_at")
    sys.exit(0 if (not isinstance(ca, int) or (now - ca) >= stale) else 1)
sys.exit(1)
PY
}

# unclaim-reaping: revert a `reaping` lease back to a reapable active state (code-review Finding 2) —
# used when the DELETE could not be verified gone, so the NEXT sweep retries it (a `reaping` lease is
# skipped by the sweep otherwise). Restores `enriched` if an SSH endpoint is recorded, else `provisional`.
# expiry_at is left in the past, so the reverted lease is immediately reapable again.
cmd_unclaim_reaping(){
  local id=$1; local file; file=$(record_path "$id")
  local state; state=$(classify_record "$file")
  case "$state" in
    reaping) : ;;
    closed)  die "unclaim-reaping: lease '$id' is closed — refusing";;
    absent)  die "unclaim-reaping: no lease for '$id'";;
    invalid) die "unclaim-reaping: lease '$id' is malformed — inspect $file";;
    *) echo "unclaim-reaping: lease '$id' not in reaping ($state) — no-op"; return 0;;
  esac
  local back; back=provisional
  [ -n "$(get_field "$file" ssh)" ] && back=enriched
  STATE="$back" write_record "$file"
  echo "unclaimed lease $id (back to $back for retry)"
}

# is-reapable: exit 0 iff the lease is in a deletable state AND its expiry_at is in the PAST. A
# missing/closed/malformed lease is exit 1 (fail-closed). Read under the lock so it never observes a
# half-applied refresh.
cmd_is_reapable(){
  local id=$1; local file; file=$(record_path "$id")
  [ -f "$file" ] || exit 1
  python3 - "$file" <<'PY'
import json, sys, time
try:
    d = json.load(open(sys.argv[1]))
    if not isinstance(d, dict):
        raise ValueError
except Exception:
    sys.exit(1)
state = d.get("state")
if state not in ("intent", "provisional", "enriched"):  # closed/reaping/invalid -> not reapable
    sys.exit(1)
exp = d.get("expiry_at")
if not isinstance(exp, int):
    sys.exit(1)
sys.exit(0 if exp <= int(time.time()) else 1)
PY
}

cmd_show(){
  local id=$1; local file; file=$(record_path "$id")
  [ -f "$file" ] || die "show: no lease for '$id'"
  cat "$file"
}

# find-by-pod: print the nonce of the NON-TERMINAL (active/reaping) lease bound to a pod id, for the
# back-compat teardown path that gets only a pod id (round-9 Finding 2). >1 match or none -> empty.
cmd_find_by_pod(){
  local pod=$1
  require_val "<pod-id>" "$pod"
  [ -d "$ROOT" ] || return 0
  local f match="" count=0
  for f in "$ROOT"/*.json; do
    [ -e "$f" ] || continue
    local p st
    p=$(get_field "$f" pod_id)
    [ "$p" = "$pod" ] || continue
    st=$(get_field "$f" state)
    case "$st" in
      intent|provisional|enriched|reaping)
        match=$(get_field "$f" nonce); count=$((count+1)) ;;
    esac
  done
  [ "$count" = 1 ] && printf '%s\n' "$match"
  return 0
}

# list: print one `<id> <state> <pod_id> <expiry_at>` line per lease (the reaper's enumeration input).
cmd_list(){
  [ -d "$ROOT" ] || return 0
  local f
  for f in "$ROOT"/*.json; do
    [ -e "$f" ] || continue
    python3 - "$f" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    print("%s invalid - -" % sys.argv[1]); sys.exit(0)
print("%s %s %s %s" % (d.get("nonce") or "?", d.get("state") or "?",
                        d.get("pod_id") or "-", d.get("expiry_at") if d.get("expiry_at") is not None else "-"))
PY
  done
}

# find-nonce: map a pod NAME back to a PENDING-INTENT lease. EXACT whole-string match only, and ONLY a
# lease that is still a PENDING INTENT — state=intent with NO bound pod_id (code-review Finding 4). A
# lease that already has a pod_id is accounted for by the step-1 pod-id path, not by name-matching, so
# matching it here could double-reap or reap an unknown pod sharing a registered nonce. >1 matching
# pending intent -> empty (ambiguous; report-only). A name that is not a `gpujob-` nonce -> empty.
cmd_find_nonce(){
  local name=$1
  require_val "<name>" "$name"
  # Recover the gpujob-<hex> nonce structurally from a possibly-prefixed pod name (e.g. anton-gpujob-..),
  # independent of any POD_NAME_PREFIX reaching this (detached reaper) process — a missing prefix env must
  # never orphan a billing pod. A name with no gpujob- token is unknown.
  case "$name" in *gpujob-*) name="gpujob-${name##*gpujob-}" ;; *) return 0;; esac
  [ -d "$ROOT" ] || return 0
  local f match="" count=0
  for f in "$ROOT"/*.json; do
    [ -e "$f" ] || continue
    local n st pod
    n=$(get_field "$f" nonce)
    [ "$n" = "$name" ] || continue
    st=$(get_field "$f" state)
    pod=$(get_field "$f" pod_id)
    # pending intent ONLY: state=intent AND no pod bound
    if [ "$st" = intent ] && { [ -z "$pod" ] || [ "$pod" = None ]; }; then
      match=$n; count=$((count+1))
    fi
  done
  [ "$count" = 1 ] && printf '%s\n' "$match"   # 0 or >1 -> nothing (report-only)
  return 0
}

main(){
  local sub=${1:-}; shift || true
  case "$sub" in
    intent)
      [ $# -ge 1 ] || die "usage: pod_lease.sh intent <key-ref> [--expiry-min N]"
      cmd_intent "$@";;
    provisional)
      validate_id "${1:-}"; local id=$1; shift
      [ $# -ge 1 ] || die "usage: pod_lease.sh provisional <nonce> <pod-id>"
      with_lock "$id" cmd_provisional "$id" "$@";;
    enrich)
      validate_id "${1:-}"; local id=$1; shift
      with_lock "$id" cmd_enrich "$id" "$@";;
    refresh)
      validate_id "${1:-}"; local id=$1; shift
      with_lock "$id" cmd_refresh "$id" "$@";;
    close)
      validate_id "${1:-}"; local id=$1; shift
      [ $# -eq 0 ] || die "close: unexpected extra argument(s): $*"
      with_lock "$id" cmd_close "$id";;
    expire)
      validate_id "${1:-}"; local id=$1; shift
      [ $# -eq 0 ] || die "expire: unexpected extra argument(s): $*"
      with_lock "$id" cmd_expire "$id";;
    emergency)
      validate_id "${1:-}"; local id=$1; shift
      [ $# -ge 1 ] || die "usage: pod_lease.sh emergency <nonce> <pod-id>"
      with_lock "$id" cmd_emergency "$id" "$@";;
    reaping)
      validate_id "${1:-}"; local id=$1; shift
      [ $# -eq 0 ] || die "reaping: unexpected extra argument(s): $*"
      with_lock "$id" cmd_reaping "$id";;
    mark-deleted)
      validate_id "${1:-}"; local id=$1; shift
      [ $# -eq 0 ] || die "mark-deleted: unexpected extra argument(s): $*"
      with_lock "$id" cmd_mark_deleted "$id";;
    claim-reaping)
      validate_id "${1:-}"; local id=$1; shift
      [ $# -eq 0 ] || die "claim-reaping: unexpected extra argument(s): $*"
      with_lock "$id" cmd_claim_reaping "$id";;
    would-claim)
      validate_id "${1:-}"; local id=$1; shift
      [ $# -eq 0 ] || die "would-claim: unexpected extra argument(s): $*"
      with_lock "$id" cmd_would_claim "$id";;
    unclaim-reaping)
      validate_id "${1:-}"; local id=$1; shift
      [ $# -eq 0 ] || die "unclaim-reaping: unexpected extra argument(s): $*"
      with_lock "$id" cmd_unclaim_reaping "$id";;
    is-reapable)
      validate_id "${1:-}"; local id=$1; shift
      [ $# -eq 0 ] || die "is-reapable: unexpected extra argument(s): $*"
      with_lock "$id" cmd_is_reapable "$id";;
    show)
      validate_id "${1:-}"; local id=$1; shift
      [ $# -eq 0 ] || die "show: unexpected extra argument(s): $*"
      with_lock "$id" cmd_show "$id";;
    list)
      [ $# -eq 0 ] || die "list: takes no arguments"
      cmd_list;;
    path)        validate_id "${1:-}"; record_path "$1";;
    lock-path)   validate_id "${1:-}"; lock_path "$1";;
    find-nonce)
      [ $# -eq 1 ] || die "usage: pod_lease.sh find-nonce <pod-name>"
      cmd_find_nonce "$1";;
    find-by-pod)
      [ $# -eq 1 ] || die "usage: pod_lease.sh find-by-pod <pod-id>"
      cmd_find_by_pod "$1";;
    "") die "usage: pod_lease.sh <intent|provisional|enrich|refresh|close|expire|emergency|reaping|mark-deleted|claim-reaping|would-claim|unclaim-reaping|is-reapable|show|list|path|lock-path|find-nonce|find-by-pod> ...";;
    *) die "unknown subcommand '$sub'";;
  esac
}

main "$@"
