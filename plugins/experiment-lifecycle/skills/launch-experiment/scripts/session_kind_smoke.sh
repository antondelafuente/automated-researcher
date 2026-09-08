#!/usr/bin/env bash
# Smoke for session_kind.sh — the check both supervision layers now consult before claiming a periodic wake
# is armed (automated-researcher#849). Behavior the deterministic syntax checks can't catch:
#   classify   — print/SDK mode is recognized in every spelling the harness actually uses (`--print`, `-p`,
#                `--sdk-url`, `--sdk-url=`) AND by flag family (`--sdk…`, `--print…`), an interactive
#                `claude --remote-control` line is NOT, and a non-harness ancestor whose text merely MENTIONS a
#                `~/.claude/...` path or the word `--print` is `unknown` rather than a guess (the
#                false-positive that would silently route a terminal launcher onto the fallback, or worse, a
#                bridge one onto a dead cron).
#   detect     — the asymmetric resolution rule holds across BOTH signals: a recognized print/SDK marker from
#                either the transcript or ANY ancestor wins over an interactive marker from the other (the
#                walk therefore does not stop at the nearest claude), an `entrypoint` value the script does not
#                recognize is not evidence at all rather than a stand-in for `terminal` (the round-2 fail-open:
#                `sdk-cli-v2` overriding a decisive `--sdk-url` ancestor), a missing claude ancestor is
#                `unknown` with exit 3 (never a defaulted `terminal`, which is the fail-open the incident was
#                made of), and the walk is bounded by BOTH --max-depth and a seen-set so a looping ppid cannot
#                hang the arming step it gates.
#   packaging  — the run-experiment copy (its self-wake gate calls its own co-located one, same
#                per-skill-copy precedent as sparse_worktree.sh / aar_profile_snapshot.sh) has not drifted,
#                and the whole suite re-runs green against THAT copy — matching bytes is not the same claim
#                as the copy a standalone run-experiment install actually executes behaving correctly.
# `ps` is stubbed on PATH against a synthetic process table — offline, no real process inspected.
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
# SESSION_KIND_UNDER_TEST lets this file re-run itself against the sibling copy (see the tail); unset = the
# canonical copy beside this smoke.
S=${SESSION_KIND_UNDER_TEST:-$HERE/session_kind.sh}
[ -f "$S" ] || { echo "FAIL: missing $S"; exit 1; }
# Skipped when that skill dir isn't present (a single-skill symlink install of launch-experiment alone).
RE_COPY="$HERE/../../run-experiment/scripts/session_kind.sh"

TMP=$(mktemp -d) || { echo "FAIL: mktemp"; exit 1; }
trap 'rm -rf "$TMP"' EXIT

fails=0
ok(){ echo "ok   $1"; }
no(){ echo "FAIL $1"; fails=1; }

# ── the ps stub: a fixture file of "<pid> <ppid> <args...>" lines, one process per line ─────────────────────
mkdir -p "$TMP/bin"
cat > "$TMP/bin/ps" <<'STUB'
#!/usr/bin/env bash
# Minimal `ps -o ppid=,args= -p <pid>` against $PS_TABLE. Anything else is a hard error, so a change to the
# script's ps invocation fails LOUD here instead of silently degrading to "unknown".
want=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) shift 2>/dev/null; [ "${1:-}" = "ppid=,args=" ] || { echo "stub-ps: unexpected -o '${1:-}'" >&2; exit 64; }; shift ;;
    -p) shift; want=${1:-}; shift ;;
    *) echo "stub-ps: unexpected arg '$1'" >&2; exit 64 ;;
  esac
done
[ -n "$want" ] || { echo "stub-ps: no -p" >&2; exit 64; }
while read -r pid ppid rest; do
  [ "$pid" = "$want" ] || continue
  printf ' %s %s\n' "$ppid" "$rest"
  exit 0
done < "$PS_TABLE"
exit 1
STUB
chmod +x "$TMP/bin/ps"

sk(){ PATH="$TMP/bin:$PATH" bash "$S" "$@" 2>/dev/null; }

# expect <label> <expected-kind> <expected-exit> -- <args...>
expect(){
  local label=$1 want_kind=$2 want_rc=$3; shift 4
  local out rc
  out=$(sk "$@"); rc=$?
  if [ "$out" = "$want_kind" ] && [ "$rc" = "$want_rc" ]; then ok "$label"
  else no "$label (got '$out' rc=$rc, want '$want_kind' rc=$want_rc)"; fi
}

# ── classify: the pure predicate ───────────────────────────────────────────────────────────────────────────
expect "classify-bridge-print-sdk"   bridge   0 -- classify --cmdline 'claude --print --sdk-url https://api.anthropic.com/v1/code/sessions/x --session-id cse_1'
expect "classify-bridge-short-p"     bridge   0 -- classify --cmdline '/home/r/.local/bin/claude -p some prompt'
expect "classify-bridge-sdkurl-eq"   bridge   0 -- classify --cmdline 'claude --sdk-url=https://api.anthropic.com/v1/code/sessions/x'
# --sdk-url is decisive even when the executable is not named claude (a wrapper/node spelling)
expect "classify-bridge-nonclaude-exe" bridge 0 -- classify --cmdline 'node /opt/cc/cli.js --print --sdk-url https://x'
# matched by FLAG FAMILY, not exact spelling: a future --sdk…/--print… variant must not read as interactive
expect "classify-bridge-sdk-family"  bridge   0 -- classify --cmdline 'claude --sdk-transport unix:///tmp/s'
expect "classify-bridge-print-family" bridge  0 -- classify --cmdline 'claude --print-format stream-json'
expect "classify-terminal-interactive" terminal 0 -- classify --cmdline 'claude'
expect "classify-terminal-rc"        terminal 0 -- classify --cmdline 'claude --remote-control run-depv1-negemo-1'
expect "classify-terminal-modelpin"  terminal 0 -- classify --cmdline '/usr/local/bin/claude --model claude-sonnet-5 --dangerously-skip-permissions'
# a shell whose text merely mentions a .claude path / the word --print is NOT the harness
expect "classify-unknown-shell-mentions-claude" unknown 3 -- classify --cmdline 'bash -c cat /home/r/.claude/projects/x.jsonl'
expect "classify-unknown-shell-mentions-print"  unknown 3 -- classify --cmdline 'bash -c grep --print foo'
expect "classify-unknown-plain-shell" unknown 3 -- classify --cmdline '-bash'

# ── detect: the ancestry walk ──────────────────────────────────────────────────────────────────────────────
# terminal harness two shells up from the caller
cat > "$TMP/table-terminal" <<'EOF'
500 400 bash session_kind.sh detect
400 300 bash -c ./launch.sh
300 1 claude --remote-control run-depv1-negemo-1
EOF
run_detect(){ local table=$1; shift; PS_TABLE="$table" PATH="$TMP/bin:$PATH" bash "$S" "$@" 2>/dev/null; }

d(){  # d <label> <table> <want-kind> <want-rc> -- <extra args>
  local label=$1 table=$2 want_kind=$3 want_rc=$4; shift 5
  local out rc
  out=$(run_detect "$table" detect "$@"); rc=$?
  if [ "$out" = "$want_kind" ] && [ "$rc" = "$want_rc" ]; then ok "$label"
  else no "$label (got '$out' rc=$rc, want '$want_kind' rc=$want_rc)"; fi
}

d "detect-terminal-through-shells" "$TMP/table-terminal" terminal 0 -- --pid 500

cat > "$TMP/table-bridge" <<'EOF'
500 400 bash session_kind.sh detect
400 300 bash -c ./launch.sh
300 1 claude --print --sdk-url https://api.anthropic.com/v1/code/sessions/abc --session-id cse_01f5
EOF
d "detect-bridge-through-shells" "$TMP/table-bridge" bridge 0 -- --pid 500

# no harness anywhere in the ancestry -> unknown/3, never a defaulted terminal
cat > "$TMP/table-noclaude" <<'EOF'
500 400 bash session_kind.sh detect
400 300 bash -c ./launch.sh
300 1 /sbin/init
EOF
d "detect-unknown-no-harness" "$TMP/table-noclaude" unknown 3 -- --pid 500

# the harness sits deeper than --max-depth allows -> unknown, not a wrong answer
d "detect-unknown-depth-bounded" "$TMP/table-terminal" unknown 3 -- --pid 500 --max-depth 1

# the walk does NOT stop at the nearest claude: a print/SDK ancestor ABOVE an interactive-looking one still
# means this process's harness is print/SDK, so bridge wins over the closer terminal candidate.
cat > "$TMP/table-nested" <<'EOF'
500 400 bash session_kind.sh detect
400 300 claude --remote-control run-depv1-negemo-1
300 1 claude --print --sdk-url https://api.anthropic.com/v1/code/sessions/abc --session-id cse_01f5
EOF
d "detect-bridge-ancestor-beats-nearer-terminal" "$TMP/table-nested" bridge 0 -- --pid 500

# a looping ppid must terminate (the seen-set), not spin
cat > "$TMP/table-loop" <<'EOF'
500 400 bash session_kind.sh detect
400 500 bash -c ./launch.sh
EOF
out=$(PS_TABLE="$TMP/table-loop" PATH="$TMP/bin:$PATH" timeout 20 bash "$S" detect --pid 500 2>/dev/null); rc=$?
if [ "$out" = unknown ] && [ "$rc" = 3 ]; then ok "detect-loop-terminates"
else no "detect-loop-terminates (got '$out' rc=$rc)"; fi

# ── the transcript signal, resolved against the walk under the asymmetric rule ─────────────────────────────
printf '%s\n' \
  '{"type":"summary","summary":"x"}' \
  '{"type":"user","entrypoint":"sdk-cli","sessionId":"cse_01f5"}' > "$TMP/sdk.jsonl"
printf '%s\n' \
  '{"type":"user","entrypoint":"cli","sessionId":"abc"}' > "$TMP/cli.jsonl"
# an SDK-FAMILY value the script has never seen by name is still decisive for bridge...
printf '%s\n' '{"type":"user","entrypoint":"sdk-cli-v2","sessionId":"cse_9"}' > "$TMP/sdkv2.jsonl"
# ...while a value from neither allowlist is NOT EVIDENCE: it must not decide, and must not preempt the walk
printf '%s\n' '{"type":"user","entrypoint":"vscode-ext","sessionId":"abc"}' > "$TMP/unknown-ep.jsonl"

d "detect-transcript-sdkcli-beats-terminal-walk" "$TMP/table-terminal" bridge 0 -- --pid 500 --transcript "$TMP/sdk.jsonl"
d "detect-transcript-sdkfamily-unseen-value"     "$TMP/table-terminal" bridge 0 -- --pid 500 --transcript "$TMP/sdkv2.jsonl"
# a decisive --sdk-url ancestor OUTRANKS an interactive transcript: bridge is the answer that is safe when wrong
d "detect-bridge-walk-beats-transcript-cli"      "$TMP/table-bridge" bridge 0 -- --pid 500 --transcript "$TMP/cli.jsonl"
d "detect-transcript-cli-with-terminal-walk"     "$TMP/table-terminal" terminal 0 -- --pid 500 --transcript "$TMP/cli.jsonl"
# entrypoint=cli is a recognized interactive marker on its own when the walk finds no harness at all
d "detect-transcript-cli-alone-is-terminal"      "$TMP/table-noclaude" terminal 0 -- --pid 500 --transcript "$TMP/cli.jsonl"
# the round-2 fail-open, pinned: an unrecognized entrypoint may not select the dead-cron path
d "detect-unknown-entrypoint-cannot-preempt-bridge" "$TMP/table-bridge"   bridge   0 -- --pid 500 --transcript "$TMP/unknown-ep.jsonl"
d "detect-unknown-entrypoint-falls-to-walk"         "$TMP/table-terminal" terminal 0 -- --pid 500 --transcript "$TMP/unknown-ep.jsonl"
d "detect-unknown-entrypoint-alone-is-unknown"      "$TMP/table-noclaude" unknown  3 -- --pid 500 --transcript "$TMP/unknown-ep.jsonl"
# a transcript with no entrypoint field (or an unreadable path) falls back to the walk rather than failing
printf '%s\n' '{"type":"user","sessionId":"abc"}' > "$TMP/bare.jsonl"
d "detect-transcript-no-entrypoint-falls-back" "$TMP/table-bridge" bridge 0 -- --pid 500 --transcript "$TMP/bare.jsonl"
d "detect-transcript-missing-file-falls-back"  "$TMP/table-terminal" terminal 0 -- --pid 500 --transcript "$TMP/nope.jsonl"

# ── argument validation fails closed (exit 2), never silently answers ──────────────────────────────────────
for bad in "detect --pid" "detect --pid abc" "detect --max-depth 0" "detect --nope" "classify" "nonsense"; do
  # shellcheck disable=SC2086
  out=$(PS_TABLE="$TMP/table-terminal" PATH="$TMP/bin:$PATH" bash "$S" $bad 2>/dev/null); rc=$?
  if [ "$rc" = 2 ] && [ -z "$out" ]; then ok "usage-fail-closed [$bad]"
  else no "usage-fail-closed [$bad] (rc=$rc out='$out')"; fi
done

# ── packaging: the run-experiment copy must not drift, and must pass this same suite ───────────────────────
# Only from the canonical pass (SESSION_KIND_UNDER_TEST unset), so the re-run below cannot recurse.
if [ -z "${SESSION_KIND_UNDER_TEST:-}" ]; then
  if [ ! -f "$RE_COPY" ]; then
    ok "run-experiment copy absent (single-skill install) — packaging checks skipped"
  else
    cmp -s "$S" "$RE_COPY" && ok "launch-experiment and run-experiment copies are byte-identical" \
      || no "launch-experiment and run-experiment copies have drifted (edit one, mirror the other)"
    if SESSION_KIND_UNDER_TEST="$RE_COPY" bash "$0" >/dev/null 2>&1; then
      ok "run-experiment copy passes the same suite"
    else
      no "run-experiment copy FAILED the suite (re-run: SESSION_KIND_UNDER_TEST=$RE_COPY bash $0)"
    fi
  fi
fi

[ "$fails" = 0 ] && { echo "session_kind smoke PASS"; exit 0; } || { echo "session_kind smoke FAIL"; exit 1; }
