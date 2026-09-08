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
# VERBS
#   detect [--pid <pid>] [--transcript <path>] [--max-depth <n>]
#       Print the session kind of the process ancestry this script is running under:
#         terminal  a claude process with no print/SDK-mode flags — scheduled jobs fire here (when idle)
#         bridge    print/SDK mode (`--print` / `-p` / `--sdk-url`) — scheduled jobs silently no-op
#         unknown   no claude ancestor reachable (exit 3) — the CALLER decides, and the skills say: take the
#                   bridge path, because the timer-`Monitor` fallback works in BOTH kinds and a cron does not.
#       `--transcript` is the second signal named on #849: the harness transcript's `entrypoint` field
#       (`sdk-cli` = bridge). When given and it yields a value it WINS — it is the harness's own statement
#       about itself, where the ancestry walk is an inference from a command line.
#   classify --cmdline <text>
#       The pure classifier over one command line: prints `bridge` / `terminal` / `unknown` (exit 3) without
#       touching the process table. This is what the ancestry walk applies per candidate; exposed as its own
#       verb so the behavior smoke pins it directly, and so a caller holding a command line from elsewhere
#       (a `ps` line for another session's pane) can ask the same question.
#
# NOT THIS SCRIPT'S JOB: arming anything, or deciding what to arm. It reports a fact. The first-tick receipt —
# "listed is not fired" — is the gate that consumes it, and that lives in the two SKILL.md files.
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
# Padded with spaces so a flag at either end still matches on a word boundary; `--sdk-url=` covers the
# joined-value spelling. `-p` is claude's own short form of `--print`.
is_print_mode(){
  case " $1 " in
    *" --sdk-url "*|*" --sdk-url="*|*" --print "*|*" -p "*) return 0 ;;
  esac
  return 1
}

# A candidate counts as the claude process only by its EXECUTABLE name, never by "claude" appearing anywhere in
# the line: an ancestor shell whose command text merely mentions a `~/.claude/...` path (which any shell in this
# product routinely does) must not be read as the harness. The one exception is `--sdk-url`, which nothing but
# an SDK-mode harness carries and which is decisive on its own.
is_claude_proc(){
  local exe=${1%% *}
  case "${exe##*/}" in claude|claude-code) return 0 ;; esac
  case " $1 " in *" --sdk-url "*|*" --sdk-url="*) return 0 ;; esac
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

    # 1. The harness's own statement about itself, when the caller can point at it.
    if [ -n "$TRANSCRIPT" ]; then
      if ep=$(transcript_entrypoint "$TRANSCRIPT"); then
        if [ "$ep" = "sdk-cli" ]; then
          note "transcript entrypoint=$ep -> bridge (print/SDK mode: scheduled jobs silently no-op)"
          echo bridge; exit 0
        fi
        note "transcript entrypoint=$ep -> terminal"
        echo terminal; exit 0
      fi
      note "transcript carried no entrypoint field ($TRANSCRIPT) — falling back to the ancestry walk"
    fi

    # 2. The ancestry walk. `ps -o ppid=,args=` is POSIX, so this reads the same on Linux and macOS without a
    #    /proc dependency. Bounded by depth AND by a seen-set: a pid whose ppid loops (or is reparented to
    #    itself) must not spin here.
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
        note "pid $pid -> $kind: $args"
        echo "$kind"; exit 0
      fi
      pid=$ppid
      depth=$((depth + 1))
    done

    note "no claude process in the ancestry of pid $START_PID (depth<=$MAX_DEPTH) — kind undetermined"
    echo unknown
    exit 3
    ;;

  -h|--help) usage ;;
  *) die "unknown verb: $cmd" ;;
esac
