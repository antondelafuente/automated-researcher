#!/usr/bin/env bash
# Smoke for local_job_queue.sh — the concurrency-capped LOCAL job queue (#402). Behavior the deterministic
# JSON/syntax checks can't catch: argument validation, comment/blank-line skipping, and real CAP
# enforcement using REAL background processes (never more than <cap> launched jobs running at once, and
# every launched command eventually runs) — a genuine regression test for the exact "launch all N at once"
# footgun this helper exists to fix. No `pgrep`/pattern matching is involved (the queue counts via the
# shell's own job table, `jobs -rp`, scoped to jobs THIS invocation launched), so there is no self-match /
# ancestor-collision class of bug to guard against here.
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
Q="$HERE/local_job_queue.sh"
[ -f "$Q" ] || { echo "FAIL: missing $Q"; exit 1; }

TMP=$(mktemp -d) || { echo "FAIL: mktemp"; exit 1; }
trap 'rm -rf "$TMP"' EXIT

fails=0
ok(){ echo "ok   $1"; }
no(){ echo "FAIL $1"; fails=1; }
nlines(){ [ -f "$1" ] && { wc -l < "$1" | tr -d ' '; } || echo 0; }

# --- 1. argument validation ---------------------------------------------------------------
DUMMY="$TMP/dummy_cmds"; echo "echo hi" > "$DUMMY"
if bash "$Q" 0 "$DUMMY" >/dev/null 2>&1; then no cap-zero-rejected; else ok cap-zero-rejected; fi
if bash "$Q" abc "$DUMMY" >/dev/null 2>&1; then no cap-nonint-rejected; else ok cap-nonint-rejected; fi
if bash "$Q" 2 "$TMP/nope_cmds" >/dev/null 2>&1; then no missing-cmdfile-rejected; else ok missing-cmdfile-rejected; fi
if bash "$Q" 2 "$DUMMY" abc >/dev/null 2>&1; then no poll-nonint-rejected; else ok poll-nonint-rejected; fi
if bash "$Q" 1 2 3 4 >/dev/null 2>&1; then no surplus-args-rejected; else ok surplus-args-rejected; fi
if bash "$Q" 1 >/dev/null 2>&1; then no missing-args-rejected; else ok missing-args-rejected; fi

EMPTYCMDS="$TMP/empty_cmds"
printf '# just a comment\n\n   \n' > "$EMPTYCMDS"
if bash "$Q" 2 "$EMPTYCMDS" >/dev/null 2>&1; then no no-runnable-commands-rejected; else ok no-runnable-commands-rejected; fi

# --- 2. comment/blank-line skipping; cap >= total launches everything, correct total count -----
STARTED2="$TMP/started2"; : > "$STARTED2"
CMDS2="$TMP/cmds2"
cat > "$CMDS2" <<EOF
# a leading comment, must be skipped

echo j1 >> $STARTED2
echo j2 >> $STARTED2
EOF
OUT2="$TMP/out2"
bash "$Q" 5 "$CMDS2" 0 > "$OUT2" 2>&1
[ "$(grep -c 'launched' "$OUT2")" = 2 ] && ok comments-and-blanks-skipped || no "comments-and-blanks-skipped ($(cat "$OUT2"))"
grep -q '^launched 1/2 ' "$OUT2" && grep -q '^launched 2/2 ' "$OUT2" && ok total-count-in-output || no "total-count-in-output ($(cat "$OUT2"))"
i=0; while [ "$(nlines "$STARTED2")" -lt 2 ] && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
[ "$(nlines "$STARTED2")" = 2 ] && ok cap-above-total-runs-both || no cap-above-total-runs-both

# --- 3. real CAP enforcement: never more than <cap> concurrently running (4 jobs, cap=2) -------
STARTED3="$TMP/started3"; DONE3="$TMP/done3"; : > "$STARTED3"; : > "$DONE3"
CMDS3="$TMP/cmds3"; : > "$CMDS3"
for i in 1 2 3 4; do
  echo "echo s$i >> $STARTED3; sleep 1; echo d$i >> $DONE3" >> "$CMDS3"
done
OUT3="$TMP/out3"
bash "$Q" 2 "$CMDS3" 0 > "$OUT3" 2>&1 &
Q3PID=$!
sleep 0.5   # well before any 1s job finishes; give slow sandboxes room for the 2 immediate launches
i=0; while [ "$(nlines "$STARTED3")" -lt 2 ] && [ "$i" -lt 20 ]; do sleep 0.1; i=$((i + 1)); done
[ "$(nlines "$STARTED3")" = 2 ] && [ "$(nlines "$DONE3")" = 0 ] && ok cap-enforced-only-two-running \
  || no "cap-enforced-only-two-running (started=$(nlines "$STARTED3") done=$(nlines "$DONE3"))"
i=0; while [ "$(nlines "$DONE3")" -lt 4 ] && [ "$i" -lt 150 ]; do sleep 0.1; i=$((i + 1)); done
[ "$(nlines "$DONE3")" = 4 ] && ok all-four-jobs-eventually-complete || no "all-four-jobs-eventually-complete (done=$(nlines "$DONE3"))"
wait "$Q3PID" 2>/dev/null
[ "$(nlines "$STARTED3")" = 4 ] && ok all-four-jobs-launched || no "all-four-jobs-launched (started=$(nlines "$STARTED3"))"

[ "$fails" = 0 ] && { echo "local_job_queue smoke PASS"; exit 0; } || { echo "local_job_queue smoke FAIL"; exit 1; }
