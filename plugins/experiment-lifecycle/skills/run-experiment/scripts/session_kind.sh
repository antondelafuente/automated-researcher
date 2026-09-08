#!/bin/bash
# session_kind.sh — answer ONE question deterministically, before you arm a periodic wake: is THIS session a
# kind whose harness will actually FIRE a scheduled job (automated-researcher#849)?
#
# WHY A SCRIPT (the incident, research-lab 2026-09-06/08): both supervision layers this plugin prescribes —
# the launcher heartbeat (`launch-experiment` Step 7) and the executor self-wake (`run-experiment`) — rest on
# Claude Code's `CronCreate` (the primitive the loop skill registers). In a **bridge** session — the kind the
# Remote-Control host spawns (`claude rc --spawn worktree`), which runs as
# `claude --print --sdk-url … --session-id cse_…` (transcript `entrypoint: sdk-cli`) — the schedule tools are
# advertised but silently no-op: print/SDK mode has no long-lived REPL runtime to fire them
# (anthropics/claude-code#59864, closed not-planned). The harness still returns a job id and `CronList` still
# lists the job, so the "supervision armed" check of automated-researcher#658 passed while NOTHING would ever
# fire. Measured in one bridge designer session: three hourly heartbeat crons across three runs (~30
# job-hours) plus a 4-minute one-shot test, ZERO firings, all still listed. Downstream, two executors sat 9.5 h
# and 7 h parked (a permission prompt at a close commit; a budget question) until the researcher looked.
# Crons are NOT globally dead — interactive executors got 57 and 5 ticks the same days — so the answer is not
# "stop using crons", it is "know which kind of session you are in", and that is a mechanical check, not a
# judgment call. Hence a script, so neither skill re-derives it by eye.
#
# THE INVARIANT THIS SCRIPT IS BUILT AROUND (the asymmetry that decides every ambiguous case): the two answers
# are NOT equally costly when wrong. `terminal` selects the cron path, which in the wrong session silently
# never fires — the incident above. `bridge` selects the timer-`Monitor` path, which works in BOTH kinds. So
# `terminal` may be printed ONLY from a positively recognized interactive marker, `bridge` short-circuits
# everything the moment any positively recognized print/SDK marker is seen, and a signal this script does not
# recognize is NOT EVIDENCE — it neither decides nor preempts a later signal. Exhausting every signal without
# recognizing one prints `unknown` (exit 3), which both skills route to the bridge path. "Not the value I know
# about, therefore terminal" is the shape of the original fail-open and must not reappear anywhere here.
#
# VERBS
#   detect [--pid <pid>] [--transcript <path>] [--max-depth <n>]
#       Print the session kind, resolved over ALL available signals (not first-signal-wins):
#         bridge    any recognized print/SDK marker — the transcript's `entrypoint` being SDK-family, or a
#                   `--print` / `-p` / `--sdk…` flag on ANY claude process in the ancestry. Decisive: it wins
#                   over a terminal signal from the other source, because a print/SDK process between this one
#                   and the terminal means no REPL runtime will fire a scheduled job.
#         terminal  a recognized interactive marker (`entrypoint: cli`, or a claude ancestor carrying no
#                   print/SDK flag) AND no bridge marker anywhere in reach.
#         unknown   nothing recognized (exit 3) — the CALLER decides, and the skills say: take the bridge
#                   path, because the timer-`Monitor` fallback works in BOTH kinds and a cron does not.
#       `--transcript` is the second signal named on #849: the harness transcript's `entrypoint` field. It is
#       the harness's own statement about itself, so an SDK-family value there ends the question — but it is a
#       harness-internal enum whose members change, so it is read through an ALLOWLIST in both directions and
#       an unrecognized value falls through to the ancestry walk instead of standing in for one.
#   classify --cmdline <text>
#       The pure classifier over one command line: prints `bridge` / `terminal` / `unknown` (exit 3) without
#       touching the process table. This is what the ancestry walk applies per candidate; exposed as its own
#       verb so the behavior smoke pins it directly, and so a caller holding a command line from elsewhere
#       (a `ps` line for another session's pane) can ask the same question. Its `bridge` is decisive, but its
#       `terminal` is only a CANDIDATE — `detect` promotes it to the answer solely after every other signal
#       has been read without a print/SDK marker turning up.
#
# NOT THIS SCRIPT'S JOB: arming anything, or deciding what to arm. It reports a fact. The first-tick receipt —
# "listed is not fired" — is the gate that consumes it, and that lives in the two SKILL.md files.
#
# Packaging: BOTH skills that arm a periodic wake need this check at arm time, and each installs
# independently, so this file ships as a byte-identical copy under run-experiment/scripts/ (the executor
# self-wake gate) as well as here (the launcher heartbeat, Step 7) — same per-skill-copy precedent as
# sparse_worktree.sh, aar_profile_snapshot.sh, the aar-profile SCHEMA.md, and feedback-loop's init helper.
# A cross-skill reference instead of a copy would break exactly the standalone/symlink install the Agent
# Skills layout exists to make work. Edit one, mirror the other: session_kind_smoke.sh (beside the
# launch-experiment copy) asserts the two are byte-identical.
set -uo pipefail

die(){ echo "BLOCKED: $*" >&2; exit 2; }
note(){ [ "${QUIET:-0}" = 1 ] || echo "  session_kind: $*" >&2; }

usage(){
  cat >&2 <<'EOF'
usage:
  session_kind.sh detect [--pid <pid>] [--transcript <path>] [--max-depth <n>]
  session_kind.sh classify --cmdline <command line text>
exit: 0 kind determined (terminal|bridge on stdout) · 3 unknown · 2 usage error
EOF
  exit 2
}

# ── the two predicates, over one command line ──────────────────────────────────────────────────────────────
# Padded with spaces so a flag at either end still matches on a word boundary. Matched by FAMILY PREFIX, not by
# exact spelling: `--print…` covers `--print` and any later variant, `--sdk…` covers `--sdk-url`, its
# `--sdk-url=` joined spelling, and any sibling SDK-transport flag. `-p` is claude's own short form of
# `--print` and is matched exactly, since no other flag family starts there. Widening this way is the same
# fail-closed reasoning as the entrypoint allowlist, applied in the direction each surface allows: an
# unrecognized value on a CLOSED, documented flag surface (print mode has had one canonical spelling since it
# shipped — changing it would break every user's scripts) is safely read as interactive, while an unrecognized
# value in the harness's OPEN internal entrypoint enum is not read as anything at all.
is_print_mode(){
  case " $1 " in
    *" --sdk"*|*" --print"*|*" -p "*) return 0 ;;
  esac
  return 1
}

# A candidate counts as the claude process only by its EXECUTABLE name, never by "claude" appearing anywhere in
# the line: an ancestor shell whose command text merely mentions a `~/.claude/...` path (which any shell in this
# product routinely does) must not be read as the harness. The one exception is the `--sdk…` flag family
# (`--sdk-url` today), which nothing but an SDK-mode harness carries and which is decisive on its own — a
# wrapper/`node cli.js` spelling of the harness is still a harness.
is_claude_proc(){
  local exe=${1%% *}
  case "${exe##*/}" in claude|claude-code) return 0 ;; esac
  case " $1 " in *" --sdk"*) return 0 ;; esac
  return 1
}

classify_cmdline(){   # prints kind, returns 0 determined / 3 unknown
  local cmd=$1
  is_claude_proc "$cmd" || { echo unknown; return 3; }
  if is_print_mode "$cmd"; then echo bridge; else echo terminal; fi
  return 0
}

# ── the transcript signal ──────────────────────────────────────────────────────────────────────────────────
# The LAST `entrypoint` in the JSONL: a transcript is append-only, so the most recent line is the one that
# describes the process writing it now.
transcript_entrypoint(){
  [ -r "$1" ] || return 1
  local v
  v=$(grep -o '"entrypoint"[[:space:]]*:[[:space:]]*"[^"]*"' "$1" 2>/dev/null | tail -1 \
        | sed -E 's/.*"([^"]*)"[[:space:]]*$/\1/')
  [ -n "$v" ] || return 1
  printf '%s\n' "$v"
}

cmd=${1:-}
[ -n "$cmd" ] || usage
shift || true

case "$cmd" in
  classify)
    CMDLINE=""; have=0
    while [ $# -gt 0 ]; do
      case "$1" in
        --cmdline) [ $# -ge 2 ] || die "--cmdline needs a value"; CMDLINE=$2; have=1; shift 2 ;;
        -h|--help) usage ;;
        *) die "unknown argument: $1" ;;
      esac
    done
    [ "$have" = 1 ] || die "classify needs --cmdline"
    kind=$(classify_cmdline "$CMDLINE"); rc=$?
    printf '%s\n' "$kind"
    exit $rc
    ;;

  detect)
    START_PID=$$
    TRANSCRIPT=""
    MAX_DEPTH=12
    while [ $# -gt 0 ]; do
      case "$1" in
        --pid) [ $# -ge 2 ] || die "--pid needs a value"; START_PID=$2; shift 2 ;;
        --transcript) [ $# -ge 2 ] || die "--transcript needs a value"; TRANSCRIPT=$2; shift 2 ;;
        --max-depth) [ $# -ge 2 ] || die "--max-depth needs a value"; MAX_DEPTH=$2; shift 2 ;;
        -h|--help) usage ;;
        *) die "unknown argument: $1" ;;
      esac
    done
    case "$START_PID" in ''|*[!0-9]*) die "--pid must be a positive integer (got '$START_PID')" ;; esac
    case "$MAX_DEPTH" in ''|*[!0-9]*) die "--max-depth must be a positive integer (got '$MAX_DEPTH')" ;; esac
    [ "$MAX_DEPTH" -ge 1 ] || die "--max-depth must be >= 1"

    # Collected, not raced: a recognized bridge marker from EITHER source ends the question immediately, and a
    # recognized interactive marker only answers once the other source has been exhausted without one.
    terminal_evidence=""

    # 1. The harness's own statement about itself, when the caller can point at it. Read through an allowlist
    #    in BOTH directions — SDK-family (`sdk-cli` and any sibling/successor spelling) is decisive for bridge,
    #    exactly `cli` is the interactive REPL, and anything else is a value this script has never been taught,
    #    so it says nothing. Mapping "not sdk-cli" onto terminal is what let an unrecognized future value
    #    override a decisive `--sdk-url` ancestor and pick the dead-cron path (#855 review round 2).
    if [ -n "$TRANSCRIPT" ]; then
      if ep=$(transcript_entrypoint "$TRANSCRIPT"); then
        case "$ep" in
          *sdk*)
            note "transcript entrypoint=$ep -> bridge (SDK-family: no REPL runtime, scheduled jobs no-op)"
            echo bridge; exit 0 ;;
          cli)
            note "transcript entrypoint=$ep -> interactive REPL; still walking the ancestry for a print/SDK parent"
            terminal_evidence="transcript entrypoint=$ep" ;;
          *)
            note "transcript entrypoint=$ep is not a value this script recognizes — not evidence either way" ;;
        esac
      else
        note "transcript carried no entrypoint field ($TRANSCRIPT) — falling back to the ancestry walk"
      fi
    fi

    # 2. The ancestry walk. `ps -o ppid=,args=` is POSIX, so this reads the same on Linux and macOS without a
    #    /proc dependency. Bounded by depth AND by a seen-set: a pid whose ppid loops (or is reparented to
    #    itself) must not spin here. It does NOT stop at the nearest claude process: a print/SDK ancestor above
    #    an interactive-looking one still means this process's harness is print/SDK, so the walk keeps going
    #    past a terminal candidate and only a bridge match short-circuits.
    pid=$START_PID
    depth=0
    seen=" "
    while [ "$depth" -lt "$MAX_DEPTH" ]; do
      case "$pid" in ''|*[!0-9]*) break ;; esac
      [ "$pid" -gt 1 ] || break
      case "$seen" in *" $pid "*) note "ancestry loops at pid $pid — stopping"; break ;; esac
      seen="$seen$pid "
      line=$(ps -o ppid=,args= -p "$pid" 2>/dev/null | head -1)
      [ -n "$line" ] || break
      ppid=$(printf '%s\n' "$line" | awk '{print $1; exit}')
      args=$(printf '%s\n' "$line" | sed -E 's/^[[:space:]]*[0-9]+[[:space:]]*//')
      if kind=$(classify_cmdline "$args"); then
        if [ "$kind" = bridge ]; then
          note "pid $pid -> bridge: $args"
          echo bridge; exit 0
        fi
        note "pid $pid -> interactive candidate: $args (walk continues — a print/SDK ancestor would override)"
        [ -n "$terminal_evidence" ] || terminal_evidence="pid $pid: $args"
      fi
      pid=$ppid
      depth=$((depth + 1))
    done

    if [ -n "$terminal_evidence" ]; then
      note "no print/SDK marker in reach -> terminal ($terminal_evidence)"
      echo terminal
      exit 0
    fi

    note "nothing recognized in the ancestry of pid $START_PID (depth<=$MAX_DEPTH) — kind undetermined"
    echo unknown
    exit 3
    ;;

  -h|--help) usage ;;
  *) die "unknown verb: $cmd" ;;
esac
