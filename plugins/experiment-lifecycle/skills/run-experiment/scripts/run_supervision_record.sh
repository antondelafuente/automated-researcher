#!/bin/bash
# run_supervision_record.sh — the run-supervision record: machine-consumed desired-state for a
# model-free relaunch supervisor (the #54 crash-resilience design; child 1 + child 3). PRODUCT helper —
# no instance specifics (session names, relaunch commands, systemd wiring are all instance, consumed
# via this API; the session_handle field below records the instance value OPAQUELY — the product never
# interprets it).
#
# WHAT IT IS: a tiny per-run JSON record carrying RELAUNCH-scoped state only —
#   desired_active / stopped / closed / handoff_path / lease_pod_ids / session_handle / worktree_path /
#   relaunch_requested / relaunch_reason / timestamps. It LINKS to the gpu-job pod lease(s) (the #54
#   child-2 record) by pod id; it never holds pod-DELETION policy (that is the lease's domain). The
#   model-free supervisor reads `is-desired-active` to decide whether a gone session should be
#   relaunched (desired-active, not stopped, not closed) or left alone (a deliberate /quit or a
#   finished run), reads `is-relaunch-requested` for the positive agent-declared "relaunch me" signal,
#   reads `session-handle` for the opaque instance binding telling it WHICH session a run maps to, and
#   reads `worktree-path` (bound at `start`) for the run-id<->worktree binding `reap_worktree.sh` checks
#   before it will remove a worktree (automated-researcher#535 review round 2).
#
# WHY A HELPER, NOT PROSE: the record is genuinely stateful, so one product implementation owns the
#   atomic-write + monotonic-state semantics rather than every consumer (claude-pane-loop.sh, the
#   instance stop helpers, the supervisor, a StopFailure-style hook) re-deriving them and drifting.
#   The needs-relaunch signal is part of THIS record for the same reason (#54 child 3, design-review
#   HIGH): it is machine-consumed relaunch state naming the same handoff_path, so it must not be a
#   parallel on-disk marker re-implementing atomic writes.
#
# STATE MACHINE (monotonic; stop/close are TERMINAL):
#   create  -> desired_active=true, stopped=false, closed=false
#   update  -> refresh handoff_path / add lease_pod_ids / set session_handle; FAILS CLOSED if already
#              stopped or closed (never resurrects a deliberately-stopped or finished run)
#   stop    -> stopped=true (a /quit or manual kill: do NOT resurrect). Terminal.
#   close   -> closed=true (run finished). Terminal.
#   request-relaunch -> relaunch_requested=true (the agent / a StopFailure-style hook asks the
#              supervisor to recover this run — the can't-resume-in-place case). FAILS CLOSED on a
#              stopped/closed/missing/corrupt record (a deliberately-ended run is never requested back).
#              REQUIRES a bound handoff_path: pass --handoff PATH to bind it atomically with the request,
#              or it must already be on the record. FAILS CLOSED if no handoff is bound after the request —
#              this is the can't-resume-in-place signal, and its fallback (launch_successor) needs the
#              handoff to point the fresh successor at, so a "recover me" with nothing to recover from is
#              refused rather than silently accepted.
#   clear-relaunch   -> relaunch_requested=false (the supervisor's act-then-clear path, so one request
#              is acted on once and not re-triggered). Idempotent; allowed on a still-active record.
#   is-desired-active   -> exit 0 iff desired_active && !stopped && !closed; else exit 1 (a MISSING
#              record is exit 1 — fail-closed, an unknown run is never resurrected).
#   is-relaunch-requested -> exit 0 iff a relaunch is requested AND the run is still desired-active;
#              else exit 1 (a stopped/closed/missing/corrupt record is exit 1 — fail-closed).
#   is-closed -> exit 0 iff the record is terminal `closed` (run finished cleanly); else exit 1
#              (absent/invalid/stopped/active all fail closed). The reap guard: only a finished run is
#              reapable, so a parked/blocked (desired-active) run's session is never torn down.
#   session-handle -> print the opaque instance handle ("" + exit 1 if unset/missing).
#   worktree-path -> print the run's own worktree path, bound at `start`/`checkpoint` via `--worktree PATH`
#              ("" + exit 1 if unset/missing). This is the run-id<->worktree BINDING `reap_worktree.sh`
#              checks (automated-researcher#535 review, round 2): the record is written from INSIDE the
#              run's own worktree at start, so a clean-closed run-id can only ever name its OWN worktree
#              path here, never a peer's.
#   list -> print one `<run-id> <state>` line per record on disk (state: active|stopped|closed|invalid).
#              Read-only, no lock (write_record's atomic replace means a list never observes a partial
#              write). This is the box-level session-janitor's enumeration input (session_janitor.sh),
#              the run-supervision analog of pod_lease.sh's own `list`.
#
# CONCURRENCY: every mutation takes a per-record flock for the whole read-modify-write window, and
#   the terminal-state guard runs INSIDE that lock — so a concurrent `update` cannot read-modify-write
#   over a `stop`/`close` and re-activate a stopped run. Writes go through a temp file + mv under the
#   lock, so a crash mid-write never leaves a half-written record.
#
# USAGE:
#   run_supervision_record.sh start|create <run-id> [--handoff PATH] [--session-handle H] [--worktree PATH]
#   run_supervision_record.sh checkpoint|update <run-id> [--handoff PATH] [--lease-pod ID]... [--session-handle H] [--worktree PATH]
#   run_supervision_record.sh stop   <run-id>
#   run_supervision_record.sh close  <run-id>
#   run_supervision_record.sh request-relaunch <run-id> [--handoff PATH] [--reason TEXT]
#   run_supervision_record.sh clear-relaunch   <run-id>
#   run_supervision_record.sh is-desired-active     <run-id>  # exit 0/1, no output
#   run_supervision_record.sh is-relaunch-requested <run-id>  # exit 0/1, no output
#   run_supervision_record.sh is-closed             <run-id>  # exit 0/1, no output (0 iff finished/closed)
#   run_supervision_record.sh session-handle        <run-id>  # print opaque handle (exit 1 if unset)
#   run_supervision_record.sh worktree-path         <run-id>  # print bound worktree path (exit 1 if unset)
#   run_supervision_record.sh status <run-id>               # compact checklist evidence
#   run_supervision_record.sh show   <run-id>                # print the JSON (debug)
#   run_supervision_record.sh list                           # `<run-id> <state>` per record (enumeration)
#
# Record root is instance-overridable: ${AAR_RUN_SUPERVISION_DIR:-$HOME/.config/run-supervision}.
set -euo pipefail

ROOT="${AAR_RUN_SUPERVISION_DIR:-$HOME/.config/run-supervision}"

die(){ echo "run_supervision_record: $*" >&2; exit 2; }

# run-id is used as a filename — keep it path-safe (no traversal / separators).
validate_id(){
  [ -n "${1:-}" ] || die "missing <run-id>"
  case "$1" in
    *[!A-Za-z0-9._-]*) die "invalid run-id '$1' (allowed: A-Za-z0-9._-)";;
    .|..) die "invalid run-id '$1'";;
  esac
}

record_path(){ printf '%s/%s.json' "$ROOT" "$1"; }
lock_path(){ printf '%s/%s.lock' "$ROOT" "$1"; }

# Read a top-level field from the record JSON ("" if record or field absent). python3 is already a
# hard dependency of the .aar-ci checks + the rest of the plugin scaffold.
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
elif isinstance(v, list):
    print("\n".join(str(x) for x in v))
else:
    print(v)
PY
}

# Classify a record path's on-disk state in ONE word so the shell can fail closed correctly (a corrupt
# record must NEVER be treated as an empty active one). Prints: absent | invalid | active | stopped | closed.
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
if d.get("closed") is True:
    print("closed")
elif d.get("stopped") is True:
    print("stopped")
else:
    print("active")
PY
}

# Atomically write the record from a python dict built on EXPLICIT positional args (never ambient env —
# so a subcommand only ever mutates the fields IT requested). Always under the lock. Args after <file>:
#   <handoff>        non-empty -> set handoff_path; "" -> leave
#   <add_pods>       newline-separated pod ids to additively de-dup into lease_pod_ids; "" -> none
#   <set_stopped>    "true" -> mark stopped (terminal); else leave
#   <set_closed>     "true" -> mark closed (terminal); else leave
#   <create>         "true" -> write a fresh record (caller has already classified+guarded the on-disk state)
#   <session_handle> non-empty -> set the opaque instance-owned session handle; "" -> leave
#   <set_relaunch>   "true" -> set the needs-relaunch request; "false" -> clear it; "" -> leave
#   <relaunch_reason> free-text reason recorded with a set request (cleared with the request)
#   <require_handoff> "true" -> after merging, FAIL CLOSED (exit 4, no write) if handoff_path is null/empty
#                     (used by request-relaunch: the recover-me signal needs a handoff for the successor path)
#   <worktree_path>  non-empty -> bind the run's own worktree path (the run-id<->worktree binding
#                     `reap_worktree.sh` checks); "" -> leave
# Preserves existing fields it doesn't touch. For any non-create mutation, malformed existing JSON fails
# CLOSED (exit 3) rather than being treated as empty.
write_record(){ # <file> <handoff> <add_pods> <set_stopped> <set_closed> <create> [<session_handle> <set_relaunch> <relaunch_reason> <require_handoff> <worktree_path>]
  local file=$1 handoff=$2 add_pods=$3 set_stopped=$4 set_closed=$5 create=$6
  local session_handle=${7:-} set_relaunch=${8:-} relaunch_reason=${9:-} require_handoff=${10:-} worktree_path=${11:-}
  HANDOFF="$handoff" ADD_PODS="$add_pods" SET_STOPPED="$set_stopped" SET_CLOSED="$set_closed" CREATE="$create" \
  SESSION_HANDLE="$session_handle" SET_RELAUNCH="$set_relaunch" RELAUNCH_REASON="$relaunch_reason" \
  REQUIRE_HANDOFF="$require_handoff" WORKTREE_PATH="$worktree_path" \
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
        # malformed existing record on a non-create mutation: fail CLOSED, never silently resurrect.
        sys.stderr.write("malformed run-supervision record JSON: %s\n" % path)
        sys.exit(3)
    rec = {}

now = int(time.time())
if creating:
    rec = {
        "run_id": os.path.basename(path)[:-5] if path.endswith(".json") else os.path.basename(path),
        "desired_active": True,
        "stopped": False,
        "closed": False,
        "handoff_path": None,
        "lease_pod_ids": [],
        "session_handle": None,
        "relaunch_requested": False,
        "relaunch_reason": None,
        "worktree_path": None,
        "created_at": now,
    }
rec.setdefault("desired_active", True)
rec.setdefault("stopped", False)
rec.setdefault("closed", False)
rec.setdefault("lease_pod_ids", [])
rec.setdefault("session_handle", None)
rec.setdefault("relaunch_requested", False)
rec.setdefault("relaunch_reason", None)
rec.setdefault("worktree_path", None)

handoff = os.environ.get("HANDOFF", "")
if handoff:
    rec["handoff_path"] = handoff
session_handle = os.environ.get("SESSION_HANDLE", "")
if session_handle:
    rec["session_handle"] = session_handle
worktree_path = os.environ.get("WORKTREE_PATH", "")
if worktree_path:
    rec["worktree_path"] = worktree_path
add_pods = [p for p in os.environ.get("ADD_PODS", "").splitlines() if p]
if add_pods:
    seen = list(rec.get("lease_pod_ids") or [])
    for p in add_pods:
        if p not in seen:
            seen.append(p)
    rec["lease_pod_ids"] = seen
set_relaunch = os.environ.get("SET_RELAUNCH", "")
if set_relaunch == "true":
    rec["relaunch_requested"] = True
    reason = os.environ.get("RELAUNCH_REASON", "")
    rec["relaunch_reason"] = reason or None
elif set_relaunch == "false":
    rec["relaunch_requested"] = False
    rec["relaunch_reason"] = None
if os.environ.get("SET_STOPPED") == "true":
    rec["stopped"] = True
    rec["desired_active"] = False
    # a deliberately-stopped run is never owed a relaunch — clear any pending request so a stale
    # request can't outlive the stop and be observed by a supervisor that races the stop.
    rec["relaunch_requested"] = False
    rec["relaunch_reason"] = None
if os.environ.get("SET_CLOSED") == "true":
    rec["closed"] = True
    rec["desired_active"] = False
    rec["relaunch_requested"] = False
    rec["relaunch_reason"] = None
rec["updated_at"] = now

# request-relaunch's bound-handoff guard: this is the can't-resume-in-place signal, and the supervisor's
# fallback for it (launch_successor) needs a handoff_path to point the fresh successor at. So fail CLOSED —
# before writing anything — if the merged record still has no handoff bound. Checked here (inside the lock,
# with the merged record in hand) so it is atomic with the request and reflects any --handoff passed in.
if os.environ.get("REQUIRE_HANDOFF") == "true":
    hp = rec.get("handoff_path")
    if not (isinstance(hp, str) and hp.strip()):
        sys.stderr.write(
            "request-relaunch requires a bound handoff_path (pass --handoff PATH, or bind it first via "
            "create/update): the successor fallback needs it. Refusing to set a recover-me request with "
            "nothing to recover from.\n"
        )
        sys.exit(4)

d = os.path.dirname(path) or "."
fd, tmp = tempfile.mkstemp(dir=d, prefix=".rsr.", suffix=".tmp")
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

# Run <fn> ... while holding the per-record lock (whole read-modify-write window).
with_lock(){ # <run-id> <fn> [args...]
  local id=$1; shift
  mkdir -p "$ROOT"
  local lock; lock=$(lock_path "$id")
  exec 9>"$lock"
  flock 9
  "$@"
}

# Require an option's value to be present AND non-empty (an empty $VAR expanded into --handoff/--lease-pod
# is a caller bug — fail loudly rather than silently registering nothing).
require_val(){ # <flag> <value>
  [ -n "${2:-}" ] || die "$1 requires a non-empty value (got empty/missing)"
}

cmd_create(){
  local id=$1; shift
  local handoff="" got_handoff=0 session_handle="" worktree=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --handoff)        require_val --handoff "${2:-}";        handoff=$2; got_handoff=1; shift 2;;
      --session-handle) require_val --session-handle "${2:-}"; session_handle=$2;         shift 2;;
      --worktree)       require_val --worktree "${2:-}";       worktree=$2;                shift 2;;
      *) die "create: unknown arg '$1'";;
    esac
  done
  local file; file=$(record_path "$id")
  # Guard the existing on-disk state INSIDE the lock: never reset a terminal record back to desired-active,
  # and never silently overwrite a corrupt record. `create` is only valid when there is no record yet.
  local state; state=$(classify_record "$file")
  case "$state" in
    absent)  : ;;  # the only clean create
    stopped) die "create: run '$id' already exists and is stopped (terminal) — refusing to reset to desired-active";;
    closed)  die "create: run '$id' already exists and is closed (terminal) — refusing to reset to desired-active";;
    active)  die "create: run '$id' already exists and is active — use 'update' to refresh it";;
    invalid) die "create: run '$id' has a malformed record on disk — inspect/remove $file before re-creating";;
    *)       die "create: unexpected record state '$state' for '$id'";;
  esac
  write_record "$file" "$handoff" "" "" "" "true" "$session_handle" "" "" "" "$worktree"
  echo "created run-supervision record: $file (desired-active)"
}

cmd_update(){
  local id=$1; shift
  local handoff="" pods="" session_handle="" worktree=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --handoff)        require_val --handoff "${2:-}";        handoff=$2;             shift 2;;
      --lease-pod)      require_val --lease-pod "${2:-}";      pods="${pods}${2}"$'\n'; shift 2;;
      --session-handle) require_val --session-handle "${2:-}"; session_handle=$2;      shift 2;;
      --worktree)       require_val --worktree "${2:-}";       worktree=$2;             shift 2;;
      *) die "update: unknown arg '$1'";;
    esac
  done
  local file; file=$(record_path "$id")
  # Classify INSIDE the lock — distinguishes absent / invalid / terminal and fails closed on each.
  local state; state=$(classify_record "$file")
  case "$state" in
    absent)  die "update: no record for '$id' (create it first)";;
    invalid) die "update: run '$id' has a malformed record on disk — refusing to modify (inspect $file)";;
    stopped) die "update: run '$id' is stopped (terminal) — refusing to modify";;
    closed)  die "update: run '$id' is closed (terminal) — refusing to modify";;
    active)  : ;;
    *)       die "update: unexpected record state '$state' for '$id'";;
  esac
  write_record "$file" "$handoff" "$pods" "" "" "false" "$session_handle" "" "" "" "$worktree"
  echo "updated run-supervision record: $file"
}

cmd_stop(){
  local id=$1; local file; file=$(record_path "$id")
  # classify under the lock: fail closed on missing/corrupt; idempotent on already-stopped; refuse to
  # re-stop a closed run (the opposite terminal state — a closed run is finished, not stoppable).
  local state; state=$(classify_record "$file")
  case "$state" in
    absent)  die "stop: no record for '$id'";;
    invalid) die "stop: run '$id' has a malformed record on disk — refusing to modify (inspect $file)";;
    closed)  die "stop: run '$id' is already closed (terminal) — refusing to re-mark";;
    stopped) echo "stop: run '$id' is already stopped (no-op)"; return 0;;
    active)  : ;;
    *)       die "stop: unexpected record state '$state' for '$id'";;
  esac
  write_record "$file" "" "" "true" "" "false"
  echo "stopped run-supervision record: $file (will NOT be relaunched)"
}

cmd_close(){
  local id=$1; local file; file=$(record_path "$id")
  # classify under the lock: fail closed on missing/corrupt; idempotent on already-closed. `close` is the
  # finalizer superset — closing a stopped run is allowed (a deliberately-stopped run that is then torn down).
  local state; state=$(classify_record "$file")
  case "$state" in
    absent)  die "close: no record for '$id'";;
    invalid) die "close: run '$id' has a malformed record on disk — refusing to modify (inspect $file)";;
    closed)  echo "close: run '$id' is already closed (no-op)"; return 0;;
    stopped) : ;;  # stop -> close is a legitimate finalize of a deliberately-stopped run
    active)  : ;;
    *)       die "close: unexpected record state '$state' for '$id'";;
  esac
  write_record "$file" "" "" "" "true" "false"
  echo "closed run-supervision record: $file (inactive)"
}

cmd_request_relaunch(){
  local id=$1; shift
  local reason="" handoff=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --handoff) require_val --handoff "${2:-}"; handoff=$2; shift 2;;
      --reason)  require_val --reason  "${2:-}"; reason=$2;  shift 2;;
      *) die "request-relaunch: unknown arg '$1'";;
    esac
  done
  local file; file=$(record_path "$id")
  # The needs-relaunch signal as record state (NOT a parallel file): a positive "recover this run" ask
  # from the agent or a StopFailure-style hook. Fail CLOSED on a terminal/missing/corrupt record — a
  # deliberately-stopped or finished run must never be requested back.
  local state; state=$(classify_record "$file")
  case "$state" in
    absent)  die "request-relaunch: no record for '$id' (create it first)";;
    invalid) die "request-relaunch: run '$id' has a malformed record on disk — refusing to modify (inspect $file)";;
    stopped) die "request-relaunch: run '$id' is stopped (terminal) — refusing to request a relaunch of a deliberately-stopped run";;
    closed)  die "request-relaunch: run '$id' is closed (terminal) — refusing to request a relaunch of a finished run";;
    active)  : ;;
    *)       die "request-relaunch: unexpected record state '$state' for '$id'";;
  esac
  # Bind any passed --handoff atomically with the request, and require a bound handoff_path after the merge
  # (the last positional "true"): this is the can't-resume-in-place signal, and its successor fallback needs
  # the handoff. write_record exits 4 (no write) if none is bound — surface that as a clear failure.
  write_record "$file" "$handoff" "" "" "" "false" "" "true" "$reason" "true"
  echo "requested relaunch: $file"
}

cmd_clear_relaunch(){
  local id=$1; local file; file=$(record_path "$id")
  # The supervisor's act-then-clear path: clear the request once it has acted so it isn't re-triggered.
  # Idempotent (clearing an already-clear request is a no-op write). Fail closed on missing/corrupt; a
  # terminal record already has the flag cleared, so allow the clear there too (idempotent finalize).
  local state; state=$(classify_record "$file")
  case "$state" in
    absent)  die "clear-relaunch: no record for '$id'";;
    invalid) die "clear-relaunch: run '$id' has a malformed record on disk — refusing to modify (inspect $file)";;
    stopped|closed|active) : ;;
    *)       die "clear-relaunch: unexpected record state '$state' for '$id'";;
  esac
  write_record "$file" "" "" "" "" "false" "" "false" ""
  echo "cleared relaunch request: $file"
}

# is-desired-active: exit 0 iff supervisor should relaunch this run; exit 1 otherwise. No mutation, but
# read under the lock so it never observes a half-applied state. A MISSING record is exit 1 (fail-closed).
cmd_is_desired_active(){
  local id=$1; local file; file=$(record_path "$id")
  [ -f "$file" ] || exit 1
  local active stopped closed
  active=$(get_field "$file" desired_active)
  stopped=$(get_field "$file" stopped)
  closed=$(get_field "$file" closed)
  if [ "$active" = "true" ] && [ "$stopped" != "true" ] && [ "$closed" != "true" ]; then
    exit 0
  fi
  exit 1
}

# is-relaunch-requested: exit 0 iff a relaunch is requested AND the run is still relaunch-eligible
# (desired-active). A stopped/closed/missing/corrupt record is exit 1 — fail-closed, so a stale request
# can never trigger a relaunch of a run that was deliberately ended after the request was set.
cmd_is_relaunch_requested(){
  local id=$1; local file; file=$(record_path "$id")
  [ -f "$file" ] || exit 1
  local requested active stopped closed
  requested=$(get_field "$file" relaunch_requested)
  active=$(get_field "$file" desired_active)
  stopped=$(get_field "$file" stopped)
  closed=$(get_field "$file" closed)
  if [ "$requested" = "true" ] && [ "$active" = "true" ] && [ "$stopped" != "true" ] && [ "$closed" != "true" ]; then
    exit 0
  fi
  exit 1
}

# is-closed: exit 0 iff the record is a CLEAN close — closed==true AND NOT also stopped. exit 1 otherwise.
# absent/invalid/active fail closed via classify_record; a `stopped`-then-`closed` record (the deliberate-quit
# finalize — cmd_close allows stop->close, and classify_record collapses it to "closed") ALSO fails closed,
# because the reap guard must reap only the auto-close path, never a deliberately-stopped run and never a
# parked/blocked (desired-active) one. This is the machine guard behind session self-reap: reap_session.sh
# requires it.
cmd_is_closed(){
  local id=$1; local file; file=$(record_path "$id")
  local state; state=$(classify_record "$file")
  [ "$state" = "closed" ] || exit 1
  # classify_record returns "closed" for a record that is BOTH stopped and closed (closed is checked first);
  # a clean close is closed WITHOUT stopped, so re-read stopped and fail closed if it is also set.
  local stopped; stopped=$(get_field "$file" stopped)
  [ "$stopped" = "true" ] && exit 1
  exit 0
}

# session-handle: print the opaque instance-owned session handle for this run; exit 1 (no output) if the
# record or the handle is absent. The product never interprets the value — it is the instance's binding
# from this run-id to whatever process/session it owns (tmux name, systemd unit, pid-file path, …).
cmd_session_handle(){
  local id=$1; local file; file=$(record_path "$id")
  [ -f "$file" ] || exit 1
  local h; h=$(get_field "$file" session_handle)
  [ -n "$h" ] || exit 1
  printf '%s\n' "$h"
}

# worktree-path: print the run's own worktree path bound at start/checkpoint via --worktree; exit 1 (no
# output) if the record or the path is absent. This is the run-id<->worktree BINDING `reap_worktree.sh`
# checks (automated-researcher#535 review round 2): bound from INSIDE the run's own worktree at start, so
# a clean-closed run-id can only ever resolve to its OWN worktree path here, never a peer's.
cmd_worktree_path(){
  local id=$1; local file; file=$(record_path "$id")
  [ -f "$file" ] || exit 1
  local w; w=$(get_field "$file" worktree_path)
  [ -n "$w" ] || exit 1
  printf '%s\n' "$w"
}

cmd_show(){
  local id=$1; local file; file=$(record_path "$id")
  [ -f "$file" ] || die "show: no record for '$id'"
  cat "$file"
}

# list: print one `<run-id> <state>` line per record (the session-janitor's enumeration input, mirroring
# pod_lease.sh's own `list`). <run-id> is the FILENAME's stem, not a field read out of the (possibly
# corrupt) JSON, so an invalid record is still enumerable and reportable rather than silently skipped.
cmd_list(){
  [ -d "$ROOT" ] || return 0
  local f id state
  for f in "$ROOT"/*.json; do
    [ -e "$f" ] || continue
    id=$(basename "$f"); id=${id%.json}
    state=$(classify_record "$f")
    printf '%s %s\n' "$id" "$state"
  done
}

cmd_status(){
  local id=$1; local file; file=$(record_path "$id")
  local state; state=$(classify_record "$file")
  case "$state" in
    active|stopped|closed) : ;;
    absent)  die "status: no record for '$id'";;
    invalid) die "status: run '$id' has a malformed record on disk — refusing to summarize (inspect $file)";;
    *)       die "status: unexpected record state '$state' for '$id'";;
  esac
  python3 - "$file" "$state" <<'PY'
import json
import sys

path, state = sys.argv[1], sys.argv[2]
with open(path) as f:
    rec = json.load(f)
pods = rec.get("lease_pod_ids") or []

def fmt_bool(value):
    if isinstance(value, bool):
        return "true" if value else "false"
    return "" if value is None else str(value)

print(f"record={path}")
print(f"run_id={rec.get('run_id') or ''}")
print(f"state={state}")
print(f"desired_active={fmt_bool(rec.get('desired_active'))}")
print(f"handoff_path={rec.get('handoff_path') or ''}")
print(f"session_handle={rec.get('session_handle') or ''}")
print(f"worktree_path={rec.get('worktree_path') or ''}")
print(f"lease_pod_ids={','.join(str(p) for p in pods)}")
print(f"relaunch_requested={fmt_bool(rec.get('relaunch_requested'))}")
reason = rec.get("relaunch_reason")
if reason:
    print(f"relaunch_reason={reason}")
PY
}

main(){
  local sub=${1:-}; shift || true
  local id=${1:-}
  case "$sub" in
    create|start|update|checkpoint|stop|close|request-relaunch|clear-relaunch|is-desired-active|is-relaunch-requested|is-closed|session-handle|worktree-path|status|show)
      validate_id "$id"; shift;;
    list) [ $# -eq 0 ] || die "list: unexpected extra argument(s): $*";;
    "") die "usage: run_supervision_record.sh <start|create|checkpoint|update|stop|close|request-relaunch|clear-relaunch|is-desired-active|is-relaunch-requested|is-closed|session-handle|worktree-path|status|show|list> <run-id> [...]";;
    *) die "unknown subcommand '$sub'";;
  esac
  # commands that take NO further args must reject surplus tokens — a malformed wrapper call must fail
  # closed, especially before a terminal mutation, not silently stop/close a run.
  case "$sub" in
    stop|close|clear-relaunch|status|show|is-desired-active|is-relaunch-requested|is-closed|session-handle|worktree-path)
      [ $# -eq 0 ] || die "$sub: unexpected extra argument(s): $*";;
  esac
  case "$sub" in
    create)                with_lock "$id" cmd_create           "$id" "$@";;
    start)                 with_lock "$id" cmd_create           "$id" "$@";;
    update)                with_lock "$id" cmd_update           "$id" "$@";;
    checkpoint)            with_lock "$id" cmd_update           "$id" "$@";;
    stop)                  with_lock "$id" cmd_stop             "$id";;
    close)                 with_lock "$id" cmd_close            "$id";;
    request-relaunch)      with_lock "$id" cmd_request_relaunch "$id" "$@";;
    clear-relaunch)        with_lock "$id" cmd_clear_relaunch   "$id";;
    # the is-* predicates + session-handle/worktree-path exit 0/1 (or print+exit) from inside with_lock;
    # preserve that exit code
    is-desired-active)     with_lock "$id" cmd_is_desired_active     "$id";;
    is-relaunch-requested) with_lock "$id" cmd_is_relaunch_requested "$id";;
    is-closed)             with_lock "$id" cmd_is_closed             "$id";;
    session-handle)        with_lock "$id" cmd_session_handle        "$id";;
    worktree-path)         with_lock "$id" cmd_worktree_path         "$id";;
    status)                with_lock "$id" cmd_status           "$id";;
    show)                  with_lock "$id" cmd_show             "$id";;
    list)                  cmd_list;;
  esac
}

main "$@"
