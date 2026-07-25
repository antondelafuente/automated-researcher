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
# CODEX-NATIVE DISPATCH/SUPERVISION FIELDS (automated-researcher#223): the same record also carries the
#   substrate-neutral supervision metadata a Codex-family dispatch needs, so it need not invent a parallel
#   channel — see `references/CODEX_SUPERVISION.md` for the full contract this backs:
#   executor_family / supervision_mode / question_route / terminal_state_route / question / question_id /
#   answer / look_again_by / timestamps. `executor_family` names WHO the fresh executor is (e.g. "codex"/"claude", opaque —
#   the product never branches on it); `supervision_mode` is a validated enum, `autonomous-detached` or
#   `controller-supervised` — the honest self-classification a dispatcher writes once it capability-detects
#   whether an independent scheduled wake is available (never claim autonomous-detached for a
#   controller-held blocking watcher). `question_route` / `terminal_state_route` are opaque pointers
#   naming HOW the executor's load-bearing questions and DONE/BLOCKED/failed terminal state reach the
#   designer-of-record — default `record`, poll this same file — but instance-overridable to a chat
#   channel, pager, etc. The question/answer fields are a single-in-flight file-based inbox: `ask-question` (the
#   executor) and `answer-question` (the designer) let the executor ask without idling and the designer
#   answer without taking over the run — the durable two-way control channel #223 asks for, reusing this
#   record's existing atomic-write + fail-closed machinery instead of a new parallel file format.
#
# SUPERVISION-BOOTSTRAP RECEIPT (automated-researcher#628): `create_thread` (or the Claude-path session spawn)
#   only proves the executor's thread/session exists — it says nothing about whether the executor ever wrote
#   its own supervision record, bound the right worktree/routes/mode, or armed its own watcher. `look_again_by`
#   is the executor's positive liveness receipt (an opaque "I am alive and will check again by" value, set via
#   `--look-again` on `start`/`checkpoint`) — the one bounded signal the executor sends before any paid work.
#   `verify-bootstrap` is the designer-side gate: it polls the record (bounded by `--timeout-sec`) until it is
#   active/desired-active, every named field (`executor_family` / `supervision_mode` / `worktree_path` /
#   `question_route` / `terminal_state_route`) matches EXACTLY what the designer expected, AND `look_again_by`
#   is bound — failing fast on an actual mismatch (never self-corrects by waiting longer) and failing at the
#   deadline on a record that never appears or never completes. Dispatch is not "done" until this passes; see
#   `references/CODEX_SUPERVISION.md` §2 for the full contract this backs.
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
#   ask-question -> the executor asks the designer-of-record a load-bearing question (a fresh
#              question_id, monotonic across the run's lifetime). FAILS CLOSED on a stopped/closed/
#              missing/corrupt record (same guard as request-relaunch) and REFUSES if a question is
#              already pending — answered or not — one in-flight question at a time, so a second ask
#              never silently clobbers the first (an answered-but-unconsumed one included); consume it
#              first.
#   answer-question -> the designer answers the current pending question (optionally naming the
#              --question-id it's answering, refused on a mismatch — protects a racy designer from
#              answering a question that's since moved on). FAILS if there is no pending question, and
#              FAILS if the pending question already has an unconsumed answer — one answer at a time,
#              same reasoning as ask-question's own one-in-flight guard: a second answer-question before
#              consume-question would silently destroy an answer the executor hasn't read yet.
#   has-question -> exit 0 iff an unanswered question is pending on a still-active record; else exit 1
#              (fail-closed on missing/corrupt/terminal, same shape as is-relaunch-requested).
#   has-answer -> exit 0 iff the pending question has been answered (awaiting the executor's
#              consume-question) on a still-active record; else exit 1.
#   consume-question -> the executor's read-then-clear: clears the question/answer pair after the
#              executor has read the answer. REFUSES to clear a still-unanswered question (the designer
#              hasn't answered yet — clearing it would silently drop it); idempotent when nothing is
#              pending. Allowed on a terminal record too (residual Q&A cleanup at close).
#   supervision-mode / executor-family / question-route / terminal-route / look-again -> print the respective
#              opaque/enum value ("" + exit 1 if unset/missing), same shape as session-handle/worktree-path.
#   verify-bootstrap -> the designer-side supervision-bootstrap-receipt gate (#628): polls the record (bounded
#              by --timeout-sec, default 300s; --poll-interval-sec, default 5s) until it is active/
#              desired-active AND executor_family/supervision_mode/worktree_path/question_route/
#              terminal_state_route all match the given --executor-family/--supervision-mode/--worktree/
#              --question-route/--terminal-route EXACTLY AND look_again_by is bound. FAILS IMMEDIATELY (not
#              at the timeout) the moment any of those fields is SET but does not match — a mismatch never
#              self-corrects by waiting longer. FAILS AT THE DEADLINE if the record never appears, or never
#              reaches the full matching state, within --timeout-sec. Also fails immediately on an
#              invalid/stopped/closed record. Does NOT take the per-record lock across its poll (it must
#              never block the executor's own concurrent start/checkpoint writes) — each tick is a plain,
#              lock-free read, safe because write_record's atomic replace means a tick never observes a
#              partial write. Exit 0 + a receipt line on success; non-zero + a diagnosing message otherwise.
#
# CONCURRENCY: every mutation takes a per-record flock for the whole read-modify-write window, and
#   the terminal-state guard runs INSIDE that lock — so a concurrent `update` cannot read-modify-write
#   over a `stop`/`close` and re-activate a stopped run. Writes go through a temp file + mv under the
#   lock, so a crash mid-write never leaves a half-written record.
#
# USAGE:
#   run_supervision_record.sh start|create <run-id> [--handoff PATH] [--session-handle H] [--worktree PATH]
#       [--executor-family NAME] [--supervision-mode autonomous-detached|controller-supervised]
#       [--question-route ROUTE] [--terminal-route ROUTE] [--look-again RECEIPT]
#   run_supervision_record.sh checkpoint|update <run-id> [--handoff PATH] [--lease-pod ID]... [--session-handle H] [--worktree PATH]
#       [--executor-family NAME] [--supervision-mode autonomous-detached|controller-supervised]
#       [--question-route ROUTE] [--terminal-route ROUTE] [--look-again RECEIPT]
#   run_supervision_record.sh stop   <run-id>
#   run_supervision_record.sh close  <run-id>
#   run_supervision_record.sh request-relaunch <run-id> [--handoff PATH] [--reason TEXT]
#   run_supervision_record.sh clear-relaunch   <run-id>
#   run_supervision_record.sh ask-question     <run-id> --text TEXT
#   run_supervision_record.sh answer-question  <run-id> --text TEXT [--question-id ID]
#   run_supervision_record.sh consume-question <run-id>
#   run_supervision_record.sh verify-bootstrap <run-id> --executor-family NAME --supervision-mode MODE \
#       --worktree PATH --question-route ROUTE --terminal-route ROUTE [--timeout-sec N] [--poll-interval-sec N]
#   run_supervision_record.sh is-desired-active     <run-id>  # exit 0/1, no output
#   run_supervision_record.sh is-relaunch-requested <run-id>  # exit 0/1, no output
#   run_supervision_record.sh is-closed             <run-id>  # exit 0/1, no output (0 iff finished/closed)
#   run_supervision_record.sh has-question          <run-id>  # exit 0/1, no output
#   run_supervision_record.sh has-answer            <run-id>  # exit 0/1, no output
#   run_supervision_record.sh session-handle        <run-id>  # print opaque handle (exit 1 if unset)
#   run_supervision_record.sh worktree-path         <run-id>  # print bound worktree path (exit 1 if unset)
#   run_supervision_record.sh supervision-mode      <run-id>  # print mode (exit 1 if unset)
#   run_supervision_record.sh executor-family       <run-id>  # print opaque family (exit 1 if unset)
#   run_supervision_record.sh question-route        <run-id>  # print opaque route (exit 1 if unset)
#   run_supervision_record.sh terminal-route         <run-id>  # print opaque route (exit 1 if unset)
#   run_supervision_record.sh look-again             <run-id>  # print the look-again receipt (exit 1 if unset)
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

# supervision_mode is a validated enum, not a free-text field — an unrecognized value would silently
# defeat the honest-classification contract (#223): a dispatcher must say EXACTLY autonomous-detached or
# controller-supervised, never invent a third state that downstream consumers can't interpret.
validate_supervision_mode(){
  case "$1" in
    autonomous-detached|controller-supervised) ;;
    *) die "invalid --supervision-mode '$1' (allowed: autonomous-detached, controller-supervised)";;
  esac
}

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
#   <executor_family> non-empty -> set the opaque executor-family name (#223); "" -> leave
#   <supervision_mode> non-empty -> set the validated supervision-mode enum (bash already validated it
#                     via validate_supervision_mode before calling); "" -> leave
#   <question_route> non-empty -> set the opaque question-route pointer; "" -> leave
#   <terminal_route> non-empty -> set the opaque terminal-state-route pointer; "" -> leave
#   <set_question>   non-empty -> set a FRESH pending question (text), bump question_id monotonically,
#                     stamp question_asked_at, and clear any prior answer (a fresh question has no answer
#                     yet); "" -> leave. Caller (cmd_ask_question) has already refused this call if a
#                     question is already pending and unanswered.
#   <set_answer>     non-empty -> set the answer text + answered_at for the CURRENT pending question;
#                     "" -> leave. Caller has already confirmed a question is pending AND not already
#                     answered (cmd_answer_question refuses a second answer before consume-question).
#   <clear_qa>       "true" -> clear question/question_id/question_asked_at/answer/answered_at (the
#                     executor's consume-question); question_seq is NOT reset, so ids stay monotonic
#                     across the run's lifetime and a stale --question-id can never alias a later question.
#   <look_again>     non-empty -> set the executor's opaque look-again-by receipt (#628's supervision-
#                     bootstrap positive liveness signal — "I am alive and will check again by this");
#                     "" -> leave.
# Preserves existing fields it doesn't touch. For any non-create mutation, malformed existing JSON fails
# CLOSED (exit 3) rather than being treated as empty.
write_record(){ # <file> <handoff> <add_pods> <set_stopped> <set_closed> <create> [<session_handle> <set_relaunch> <relaunch_reason> <require_handoff> <worktree_path> <executor_family> <supervision_mode> <question_route> <terminal_route> <set_question> <set_answer> <clear_qa> <look_again>]
  local file=$1 handoff=$2 add_pods=$3 set_stopped=$4 set_closed=$5 create=$6
  local session_handle=${7:-} set_relaunch=${8:-} relaunch_reason=${9:-} require_handoff=${10:-} worktree_path=${11:-}
  local executor_family=${12:-} supervision_mode=${13:-} question_route=${14:-} terminal_route=${15:-}
  local set_question=${16:-} set_answer=${17:-} clear_qa=${18:-} look_again=${19:-}
  HANDOFF="$handoff" ADD_PODS="$add_pods" SET_STOPPED="$set_stopped" SET_CLOSED="$set_closed" CREATE="$create" \
  SESSION_HANDLE="$session_handle" SET_RELAUNCH="$set_relaunch" RELAUNCH_REASON="$relaunch_reason" \
  REQUIRE_HANDOFF="$require_handoff" WORKTREE_PATH="$worktree_path" \
  EXECUTOR_FAMILY="$executor_family" SUPERVISION_MODE="$supervision_mode" QUESTION_ROUTE="$question_route" \
  TERMINAL_ROUTE="$terminal_route" SET_QUESTION="$set_question" SET_ANSWER="$set_answer" CLEAR_QA="$clear_qa" \
  LOOK_AGAIN="$look_again" \
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
        "executor_family": None,
        "supervision_mode": None,
        "question_route": "record",
        "terminal_state_route": "record",
        "question": None,
        "question_id": None,
        "question_seq": 0,
        "question_asked_at": None,
        "answer": None,
        "answered_at": None,
        "look_again_by": None,
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
rec.setdefault("executor_family", None)
rec.setdefault("supervision_mode", None)
rec.setdefault("question_route", "record")
rec.setdefault("terminal_state_route", "record")
rec.setdefault("question", None)
rec.setdefault("question_id", None)
rec.setdefault("question_seq", 0)
rec.setdefault("question_asked_at", None)
rec.setdefault("answer", None)
rec.setdefault("answered_at", None)
rec.setdefault("look_again_by", None)

handoff = os.environ.get("HANDOFF", "")
if handoff:
    rec["handoff_path"] = handoff
session_handle = os.environ.get("SESSION_HANDLE", "")
if session_handle:
    rec["session_handle"] = session_handle
worktree_path = os.environ.get("WORKTREE_PATH", "")
if worktree_path:
    rec["worktree_path"] = worktree_path
executor_family = os.environ.get("EXECUTOR_FAMILY", "")
if executor_family:
    rec["executor_family"] = executor_family
supervision_mode = os.environ.get("SUPERVISION_MODE", "")
if supervision_mode:
    rec["supervision_mode"] = supervision_mode
question_route = os.environ.get("QUESTION_ROUTE", "")
if question_route:
    rec["question_route"] = question_route
terminal_route = os.environ.get("TERMINAL_ROUTE", "")
if terminal_route:
    rec["terminal_state_route"] = terminal_route
set_question = os.environ.get("SET_QUESTION", "")
if set_question:
    rec["question"] = set_question
    rec["question_seq"] = int(rec.get("question_seq") or 0) + 1
    rec["question_id"] = rec["question_seq"]
    rec["question_asked_at"] = now
    # a fresh question has no answer yet — clear any stale one from a prior consumed round.
    rec["answer"] = None
    rec["answered_at"] = None
set_answer = os.environ.get("SET_ANSWER", "")
if set_answer:
    rec["answer"] = set_answer
    rec["answered_at"] = now
if os.environ.get("CLEAR_QA") == "true":
    rec["question"] = None
    rec["question_id"] = None
    rec["question_asked_at"] = None
    rec["answer"] = None
    rec["answered_at"] = None
look_again = os.environ.get("LOOK_AGAIN", "")
if look_again:
    rec["look_again_by"] = look_again
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
  local executor_family="" supervision_mode="" question_route="" terminal_route="" look_again=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --handoff)          require_val --handoff "${2:-}";          handoff=$2; got_handoff=1; shift 2;;
      --session-handle)   require_val --session-handle "${2:-}";   session_handle=$2;         shift 2;;
      --worktree)         require_val --worktree "${2:-}";         worktree=$2;                shift 2;;
      --executor-family)  require_val --executor-family "${2:-}";  executor_family=$2;         shift 2;;
      --supervision-mode) require_val --supervision-mode "${2:-}"; validate_supervision_mode "$2"; supervision_mode=$2; shift 2;;
      --question-route)   require_val --question-route "${2:-}";   question_route=$2;          shift 2;;
      --terminal-route)   require_val --terminal-route "${2:-}";   terminal_route=$2;           shift 2;;
      --look-again)       require_val --look-again "${2:-}";       look_again=$2;               shift 2;;
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
  write_record "$file" "$handoff" "" "" "" "true" "$session_handle" "" "" "" "$worktree" \
    "$executor_family" "$supervision_mode" "$question_route" "$terminal_route" "" "" "" "$look_again"
  echo "created run-supervision record: $file (desired-active)"
}

cmd_update(){
  local id=$1; shift
  local handoff="" pods="" session_handle="" worktree=""
  local executor_family="" supervision_mode="" question_route="" terminal_route="" look_again=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --handoff)          require_val --handoff "${2:-}";          handoff=$2;             shift 2;;
      --lease-pod)        require_val --lease-pod "${2:-}";        pods="${pods}${2}"$'\n'; shift 2;;
      --session-handle)   require_val --session-handle "${2:-}";   session_handle=$2;      shift 2;;
      --worktree)         require_val --worktree "${2:-}";         worktree=$2;             shift 2;;
      --executor-family)  require_val --executor-family "${2:-}";  executor_family=$2;      shift 2;;
      --supervision-mode) require_val --supervision-mode "${2:-}"; validate_supervision_mode "$2"; supervision_mode=$2; shift 2;;
      --question-route)   require_val --question-route "${2:-}";   question_route=$2;       shift 2;;
      --terminal-route)   require_val --terminal-route "${2:-}";   terminal_route=$2;        shift 2;;
      --look-again)       require_val --look-again "${2:-}";       look_again=$2;            shift 2;;
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
  write_record "$file" "$handoff" "$pods" "" "" "false" "$session_handle" "" "" "" "$worktree" \
    "$executor_family" "$supervision_mode" "$question_route" "$terminal_route" "" "" "" "$look_again"
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

cmd_ask_question(){
  local id=$1; shift
  local text=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --text) require_val --text "${2:-}"; text=$2; shift 2;;
      *) die "ask-question: unknown arg '$1'";;
    esac
  done
  [ -n "$text" ] || die "ask-question: --text is required"
  local file; file=$(record_path "$id")
  # Same terminal guard as request-relaunch: a load-bearing question from a deliberately-ended or
  # finished run must never be recorded as if the run were still live.
  local state; state=$(classify_record "$file")
  case "$state" in
    absent)  die "ask-question: no record for '$id' (create it first)";;
    invalid) die "ask-question: run '$id' has a malformed record on disk — refusing to modify (inspect $file)";;
    stopped) die "ask-question: run '$id' is stopped (terminal) — refusing to ask on a deliberately-stopped run";;
    closed)  die "ask-question: run '$id' is closed (terminal) — refusing to ask on a finished run";;
    active)  : ;;
    *)       die "ask-question: unexpected record state '$state' for '$id'";;
  esac
  # One in-flight question at a time — a second ask before the first is consumed would silently
  # clobber it, whether or not it's been answered yet: an answered-but-unconsumed question still
  # holds an answer the executor hasn't read, and a fresh ask would overwrite that answer along with
  # the question (the designer could also be mid-answer to the first).
  local cur_q
  cur_q=$(get_field "$file" question)
  if [ -n "$cur_q" ]; then
    die "ask-question: run '$id' already has a pending question — consume it first (answer it first if unanswered)"
  fi
  write_record "$file" "" "" "" "" "false" "" "" "" "" "" "" "" "" "" "$text" "" ""
  local qid; qid=$(get_field "$file" question_id)
  echo "asked question $qid on $file"
}

cmd_answer_question(){
  local id=$1; shift
  local text="" want_id=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --text)        require_val --text "${2:-}";        text=$2;    shift 2;;
      --question-id) require_val --question-id "${2:-}"; want_id=$2; shift 2;;
      *) die "answer-question: unknown arg '$1'";;
    esac
  done
  [ -n "$text" ] || die "answer-question: --text is required"
  local file; file=$(record_path "$id")
  local state; state=$(classify_record "$file")
  case "$state" in
    absent)  die "answer-question: no record for '$id'";;
    invalid) die "answer-question: run '$id' has a malformed record on disk — refusing to modify (inspect $file)";;
    stopped) die "answer-question: run '$id' is stopped (terminal) — refusing to modify";;
    closed)  die "answer-question: run '$id' is closed (terminal) — refusing to modify";;
    active)  : ;;
    *)       die "answer-question: unexpected record state '$state' for '$id'";;
  esac
  local cur_q cur_id cur_a
  cur_q=$(get_field "$file" question)
  [ -n "$cur_q" ] || die "answer-question: run '$id' has no pending question to answer"
  # Same one-in-flight guard as ask-question's own (see #223's answered-but-unconsumed clobber fix):
  # an already-answered-but-unconsumed pending question must not be silently re-answered — that would
  # destroy an answer the executor hasn't read yet. consume-question first.
  cur_a=$(get_field "$file" answer)
  if [ -n "$cur_a" ]; then
    die "answer-question: run '$id' already has an unconsumed answer for the pending question — consume it first before answering again"
  fi
  if [ -n "$want_id" ]; then
    cur_id=$(get_field "$file" question_id)
    [ "$want_id" = "$cur_id" ] || die "answer-question: --question-id $want_id does not match the current pending question_id $cur_id (it may have moved on — re-read the question first)"
  fi
  write_record "$file" "" "" "" "" "false" "" "" "" "" "" "" "" "" "" "" "$text" ""
  echo "answered question on $file"
}

cmd_consume_question(){
  local id=$1; local file; file=$(record_path "$id")
  # Consuming is allowed on any classified state (active or terminal — residual Q&A cleanup at close),
  # same permissiveness as clear-relaunch; only missing/corrupt records fail closed.
  local state; state=$(classify_record "$file")
  case "$state" in
    absent)  die "consume-question: no record for '$id'";;
    invalid) die "consume-question: run '$id' has a malformed record on disk — refusing to modify (inspect $file)";;
    stopped|closed|active) : ;;
    *)       die "consume-question: unexpected record state '$state' for '$id'";;
  esac
  local cur_q cur_a
  cur_q=$(get_field "$file" question)
  cur_a=$(get_field "$file" answer)
  if [ -n "$cur_q" ] && [ -z "$cur_a" ]; then
    die "consume-question: run '$id' has an unanswered pending question — cannot consume before it is answered"
  fi
  write_record "$file" "" "" "" "" "false" "" "" "" "" "" "" "" "" "" "" "" "true"
  echo "consumed question/answer on $file"
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

# has-question: exit 0 iff an unanswered question is pending on a still-active record; else exit 1
# (fail-closed on missing/corrupt/terminal — same shape as is-relaunch-requested).
cmd_has_question(){
  local id=$1; local file; file=$(record_path "$id")
  [ -f "$file" ] || exit 1
  local q a active stopped closed
  q=$(get_field "$file" question)
  a=$(get_field "$file" answer)
  active=$(get_field "$file" desired_active)
  stopped=$(get_field "$file" stopped)
  closed=$(get_field "$file" closed)
  if [ -n "$q" ] && [ -z "$a" ] && [ "$active" = "true" ] && [ "$stopped" != "true" ] && [ "$closed" != "true" ]; then
    exit 0
  fi
  exit 1
}

# has-answer: exit 0 iff the pending question has been answered (awaiting consume-question) on a
# still-active record; else exit 1.
cmd_has_answer(){
  local id=$1; local file; file=$(record_path "$id")
  [ -f "$file" ] || exit 1
  local q a active stopped closed
  q=$(get_field "$file" question)
  a=$(get_field "$file" answer)
  active=$(get_field "$file" desired_active)
  stopped=$(get_field "$file" stopped)
  closed=$(get_field "$file" closed)
  if [ -n "$q" ] && [ -n "$a" ] && [ "$active" = "true" ] && [ "$stopped" != "true" ] && [ "$closed" != "true" ]; then
    exit 0
  fi
  exit 1
}

# snapshot-verify-fields: print state + the verify-bootstrap fields from ONE json.load(), so classification
# and field values can never straddle a concurrent stop/close (automated-researcher#628 review round-1:
# separate classify_record + per-field get_field calls could observe "active" then read fields from a
# record that went terminal in between, letting a stop/close race verification into a false PASS). ALWAYS
# emits exactly 7 lines (state, then the 6 fields, "" when unset/no record) so a fixed-count `read` on the
# caller side never blocks on a short read; a value is never itself multi-line (opaque names/enum/paths).
snapshot_verify_fields(){ # <file>
  python3 - "$1" <<'PY'
import json, os, sys

FIELDS = ("executor_family", "supervision_mode", "worktree_path", "question_route", "terminal_state_route", "look_again_by")

def emit(state, d):
    print(state)
    for name in FIELDS:
        v = (d or {}).get(name)
        if v is None:
            print("")
        elif isinstance(v, bool):
            print("true" if v else "false")
        else:
            print(v)

path = sys.argv[1]
if not os.path.exists(path):
    emit("absent", None)
    sys.exit(0)
try:
    d = json.load(open(path))
    if not isinstance(d, dict):
        raise ValueError
except Exception:
    emit("invalid", None)
    sys.exit(0)
if d.get("closed") is True:
    state = "closed"
elif d.get("stopped") is True:
    state = "stopped"
else:
    state = "active"
emit(state, d)
PY
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

# supervision-mode / executor-family / question-route / terminal-route: print the respective opaque/enum
# value; exit 1 (no output) if the record or the field is absent. Same shape as session-handle/worktree-path.
cmd_supervision_mode(){
  local id=$1; local file; file=$(record_path "$id")
  [ -f "$file" ] || exit 1
  local v; v=$(get_field "$file" supervision_mode)
  [ -n "$v" ] || exit 1
  printf '%s\n' "$v"
}

cmd_executor_family(){
  local id=$1; local file; file=$(record_path "$id")
  [ -f "$file" ] || exit 1
  local v; v=$(get_field "$file" executor_family)
  [ -n "$v" ] || exit 1
  printf '%s\n' "$v"
}

cmd_question_route(){
  local id=$1; local file; file=$(record_path "$id")
  [ -f "$file" ] || exit 1
  local v; v=$(get_field "$file" question_route)
  [ -n "$v" ] || exit 1
  printf '%s\n' "$v"
}

cmd_terminal_route(){
  local id=$1; local file; file=$(record_path "$id")
  [ -f "$file" ] || exit 1
  local v; v=$(get_field "$file" terminal_state_route)
  [ -n "$v" ] || exit 1
  printf '%s\n' "$v"
}

# look-again: print the executor's opaque look-again-by receipt (#628's supervision-bootstrap positive
# liveness signal, set via --look-again on start/checkpoint); exit 1 (no output) if the record or the
# field is absent. Same shape as session-handle/worktree-path.
cmd_look_again(){
  local id=$1; local file; file=$(record_path "$id")
  [ -f "$file" ] || exit 1
  local v; v=$(get_field "$file" look_again_by)
  [ -n "$v" ] || exit 1
  printf '%s\n' "$v"
}

# verify-bootstrap: the designer-side supervision-bootstrap-receipt gate (automated-researcher#628). Polls
# (bounded by --timeout-sec) until the record is active/desired-active AND executor_family/supervision_mode/
# worktree_path/question_route/terminal_state_route all match the expected values EXACTLY AND look_again_by
# is bound — the full "dispatch is durably supervised" state, not merely "a thread/record exists". Does NOT
# take the per-record lock (see the file-header note): this must never block the executor's own concurrent
# start/checkpoint writes while it polls.
cmd_verify_bootstrap(){
  local id=$1; shift
  local exp_family="" exp_mode="" exp_worktree="" exp_qroute="" exp_troute=""
  local timeout_sec=300 poll_sec=5
  while [ $# -gt 0 ]; do
    case "$1" in
      --executor-family)   require_val --executor-family "${2:-}";   exp_family=$2;   shift 2;;
      --supervision-mode)  require_val --supervision-mode "${2:-}";  validate_supervision_mode "$2"; exp_mode=$2; shift 2;;
      --worktree)          require_val --worktree "${2:-}";          exp_worktree=$2; shift 2;;
      --question-route)    require_val --question-route "${2:-}";    exp_qroute=$2;   shift 2;;
      --terminal-route)    require_val --terminal-route "${2:-}";    exp_troute=$2;   shift 2;;
      --timeout-sec)       require_val --timeout-sec "${2:-}";       timeout_sec=$2;  shift 2;;
      --poll-interval-sec) require_val --poll-interval-sec "${2:-}"; poll_sec=$2;      shift 2;;
      *) die "verify-bootstrap: unknown arg '$1'";;
    esac
  done
  [ -n "$exp_family" ]   || die "verify-bootstrap: --executor-family is required"
  [ -n "$exp_mode" ]     || die "verify-bootstrap: --supervision-mode is required"
  [ -n "$exp_worktree" ] || die "verify-bootstrap: --worktree is required"
  [ -n "$exp_qroute" ]   || die "verify-bootstrap: --question-route is required"
  [ -n "$exp_troute" ]   || die "verify-bootstrap: --terminal-route is required"
  case "$timeout_sec" in ''|*[!0-9]*) die "verify-bootstrap: --timeout-sec must be a non-negative integer (got '$timeout_sec')";; esac
  case "$poll_sec"    in ''|*[!0-9]*) die "verify-bootstrap: --poll-interval-sec must be a non-negative integer (got '$poll_sec')";; esac

  local file; file=$(record_path "$id")
  local start_ts; start_ts=$(date +%s)
  local state
  while :; do
    # One snapshot call per iteration: state and all six fields come from the SAME json.load(), so a
    # concurrent stop/close can never be observed as "active" alongside terminal-stale field values (see
    # snapshot_verify_fields's header note — the round-1 TOCTOU this closes).
    local got_family got_mode got_wt got_qr got_tr got_la
    { IFS= read -r state; IFS= read -r got_family; IFS= read -r got_mode; IFS= read -r got_wt; \
      IFS= read -r got_qr; IFS= read -r got_tr; IFS= read -r got_la; } < <(snapshot_verify_fields "$file")
    case "$state" in
      invalid) die "verify-bootstrap: run '$id' has a malformed record on disk — refusing to treat dispatch as complete (inspect $file)";;
      stopped) die "verify-bootstrap: run '$id' is stopped (terminal) before bootstrap completed — dispatch cannot be treated as complete";;
      closed)  die "verify-bootstrap: run '$id' is closed (terminal) before bootstrap completed — dispatch cannot be treated as complete";;
      absent)  : ;;  # keep polling — the executor may not have created the record yet
      active)
        # A field that is SET but WRONG never self-corrects by waiting longer — fail fast, not at the deadline.
        [ -z "$got_family" ] || [ "$got_family" = "$exp_family" ] || \
          die "verify-bootstrap: run '$id' executor_family mismatch — expected '$exp_family', got '$got_family'"
        [ -z "$got_mode" ] || [ "$got_mode" = "$exp_mode" ] || \
          die "verify-bootstrap: run '$id' supervision_mode mismatch — expected '$exp_mode', got '$got_mode'"
        [ -z "$got_wt" ] || [ "$got_wt" = "$exp_worktree" ] || \
          die "verify-bootstrap: run '$id' worktree_path mismatch — expected '$exp_worktree', got '$got_wt'"
        [ -z "$got_qr" ] || [ "$got_qr" = "$exp_qroute" ] || \
          die "verify-bootstrap: run '$id' question_route mismatch — expected '$exp_qroute', got '$got_qr'"
        [ -z "$got_tr" ] || [ "$got_tr" = "$exp_troute" ] || \
          die "verify-bootstrap: run '$id' terminal_state_route mismatch — expected '$exp_troute', got '$got_tr'"
        if [ "$got_family" = "$exp_family" ] && [ "$got_mode" = "$exp_mode" ] && [ "$got_wt" = "$exp_worktree" ] \
           && [ "$got_qr" = "$exp_qroute" ] && [ "$got_tr" = "$exp_troute" ] && [ -n "$got_la" ]; then
          echo "supervision-bootstrap receipt PASSED: $file (executor_family=$got_family supervision_mode=$got_mode worktree=$got_wt question_route=$got_qr terminal_route=$got_tr look_again_by=$got_la)"
          return 0
        fi
        ;;
      *) die "verify-bootstrap: unexpected record state '$state' for '$id'";;
    esac
    local now elapsed; now=$(date +%s); elapsed=$(( now - start_ts ))
    if [ "$elapsed" -ge "$timeout_sec" ]; then
      if [ "$state" = "absent" ]; then
        die "verify-bootstrap: timed out after ${timeout_sec}s waiting for run '$id' — no supervision record ever appeared (executor never started run_supervision_record.sh, or the run-id is wrong)"
      else
        die "verify-bootstrap: timed out after ${timeout_sec}s waiting for run '$id' bootstrap to complete — record is active but never reached the full expected state with a look-again receipt (inspect $file)"
      fi
    fi
    # Clamp the sleep to what's left of the deadline — sleeping the full --poll-interval-sec regardless
    # would let a coarse poll interval overshoot --timeout-sec by up to that interval (round-1 review P0).
    if [ "$poll_sec" -gt 0 ]; then
      local remaining=$(( timeout_sec - elapsed )) sleep_for=$poll_sec
      [ "$remaining" -lt "$sleep_for" ] && sleep_for=$remaining
      [ "$sleep_for" -gt 0 ] && sleep "$sleep_for"
    fi
  done
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
print(f"executor_family={rec.get('executor_family') or ''}")
print(f"supervision_mode={rec.get('supervision_mode') or ''}")
print(f"question_route={rec.get('question_route') or ''}")
print(f"terminal_state_route={rec.get('terminal_state_route') or ''}")
print(f"look_again_by={rec.get('look_again_by') or ''}")
question = rec.get("question")
if question:
    print(f"question_id={rec.get('question_id') or ''}")
    print(f"question={question}")
    answer = rec.get("answer")
    print(f"answer={answer or ''}")
PY
}

main(){
  local sub=${1:-}; shift || true
  local id=${1:-}
  case "$sub" in
    create|start|update|checkpoint|stop|close|request-relaunch|clear-relaunch|is-desired-active|is-relaunch-requested|is-closed|session-handle|worktree-path|status|show|ask-question|answer-question|consume-question|has-question|has-answer|supervision-mode|executor-family|question-route|terminal-route|look-again|verify-bootstrap)
      validate_id "$id"; shift;;
    list) [ $# -eq 0 ] || die "list: unexpected extra argument(s): $*";;
    "") die "usage: run_supervision_record.sh <start|create|checkpoint|update|stop|close|request-relaunch|clear-relaunch|ask-question|answer-question|consume-question|verify-bootstrap|is-desired-active|is-relaunch-requested|is-closed|has-question|has-answer|session-handle|worktree-path|supervision-mode|executor-family|question-route|terminal-route|look-again|status|show|list> <run-id> [...]";;
    *) die "unknown subcommand '$sub'";;
  esac
  # commands that take NO further args must reject surplus tokens — a malformed wrapper call must fail
  # closed, especially before a terminal mutation, not silently stop/close a run.
  case "$sub" in
    stop|close|clear-relaunch|status|show|is-desired-active|is-relaunch-requested|is-closed|session-handle|worktree-path|consume-question|has-question|has-answer|supervision-mode|executor-family|question-route|terminal-route|look-again)
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
    ask-question)          with_lock "$id" cmd_ask_question     "$id" "$@";;
    answer-question)       with_lock "$id" cmd_answer_question  "$id" "$@";;
    consume-question)      with_lock "$id" cmd_consume_question "$id";;
    # the is-*/has-* predicates + session-handle/worktree-path/supervision-mode/executor-family/
    # question-route/terminal-route/look-again exit 0/1 (or print+exit) from inside with_lock; preserve that exit code
    is-desired-active)     with_lock "$id" cmd_is_desired_active     "$id";;
    is-relaunch-requested) with_lock "$id" cmd_is_relaunch_requested "$id";;
    is-closed)             with_lock "$id" cmd_is_closed             "$id";;
    has-question)          with_lock "$id" cmd_has_question          "$id";;
    has-answer)            with_lock "$id" cmd_has_answer            "$id";;
    session-handle)        with_lock "$id" cmd_session_handle        "$id";;
    worktree-path)         with_lock "$id" cmd_worktree_path         "$id";;
    supervision-mode)      with_lock "$id" cmd_supervision_mode      "$id";;
    executor-family)       with_lock "$id" cmd_executor_family       "$id";;
    question-route)        with_lock "$id" cmd_question_route        "$id";;
    terminal-route)        with_lock "$id" cmd_terminal_route        "$id";;
    look-again)             with_lock "$id" cmd_look_again           "$id";;
    # verify-bootstrap deliberately does NOT take the lock: it polls over a bounded timeout, and holding
    # the flock across that whole poll would deadlock the executor's own concurrent start/checkpoint calls.
    verify-bootstrap)      cmd_verify_bootstrap "$id" "$@";;
    status)                with_lock "$id" cmd_status           "$id";;
    show)                  with_lock "$id" cmd_show             "$id";;
    list)                  cmd_list;;
  esac
}

main "$@"
