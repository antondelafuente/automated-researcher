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
#   reaping <id>                             -> mark a lease as being reaped (set by pod_reaper.sh
#                                               INSIDE the lock, only when still expired). Terminal-ish.
#   is-reapable <id>                         -> exit 0 iff state is registerable AND expiry_at is in
#                                               the PAST; else exit 1. (Used by pod_reaper.sh under lock.)
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

setif("pod_id", "POD_ID")
setif("ssh", "SSH")
setif("state", "STATE")
cost = os.environ.get("COST", "")
if cost != "":
    rec["cost_per_hr"] = cost
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

# reaping: pod_reaper.sh sets this INSIDE the lock once it confirms the lease is still expired, just
# before issuing the DELETE. Refuses to mark a closed lease.
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

# find-nonce: map a pod NAME back to a PENDING-INTENT lease. EXACT whole-string match only (the pod
# name IS the nonce for a pending intent). >1 match -> empty output (ambiguous; the reaper treats
# that as report-only, never reaps). A name that is not a `gpujob-` nonce -> empty (unknown pod).
cmd_find_nonce(){
  local name=$1
  require_val "<name>" "$name"
  case "$name" in gpujob-*) : ;; *) return 0;; esac   # not a nonce -> unknown
  [ -d "$ROOT" ] || return 0
  local f match="" count=0
  for f in "$ROOT"/*.json; do
    [ -e "$f" ] || continue
    local n; n=$(get_field "$f" nonce)
    if [ "$n" = "$name" ]; then match=$n; count=$((count+1)); fi
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
    reaping)
      validate_id "${1:-}"; local id=$1; shift
      [ $# -eq 0 ] || die "reaping: unexpected extra argument(s): $*"
      with_lock "$id" cmd_reaping "$id";;
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
    "") die "usage: pod_lease.sh <intent|provisional|enrich|refresh|close|reaping|is-reapable|show|list|path|lock-path|find-nonce> ...";;
    *) die "unknown subcommand '$sub'";;
  esac
}

main "$@"
