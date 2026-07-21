#!/usr/bin/env bash
# Smoke + reference call-site for job_lib.sh's serve_adapters_eval (#296). Behavior the deterministic
# JSON/syntax checks can't catch: per-adapter output ISOLATION (a pre-planted stale cache is wiped,
# never reused), teardown BETWEEN adapters (ordering), the serve_fn PID contract (numeric-or-die,
# both default + custom serve paths), and the distinctness assertion that catches the exact
# "identical numbers across adapters" reuse bug (error dies, warn continues loud); and self-safety
# (#299) — a caller pattern that matches the driver's OWN command line must never kill the driver.
# Fully OFFLINE: nvidia-smi / curl / pgrep are stubbed on PATH, and serve_wait is shadowed — no GPU, no vLLM.
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
source "$HERE/job_lib.sh" || { echo "FAIL: cannot source job_lib.sh"; exit 1; }

TMP=$(mktemp -d) || { echo "FAIL: mktemp"; exit 1; }
trap 'rm -rf "$TMP"' EXIT

# --- offline stubs on PATH ---------------------------------------------------------------
BIN="$TMP/bin"; mkdir -p "$BIN"
cat > "$BIN/nvidia-smi" <<'EOF'
#!/usr/bin/env bash
echo 0            # memory.used always below the floor -> GPU reads free
EOF
cat > "$BIN/curl" <<'EOF'
#!/usr/bin/env bash
exit 1            # /v1/models always refuses -> ma_teardown's port-free check passes
EOF
cat > "$BIN/pgrep" <<'EOF'
#!/usr/bin/env bash
[ -n "${MA_SMOKE_ORDER:-}" ] && echo KILL >> "$MA_SMOKE_ORDER"   # record teardowns for the ordering test
exit 1                                                            # no pattern matches -> nothing to kill
EOF
# fake `python`: stand in for the vLLM api_server launch so vllm_serve_lora's real $! is a live PID
cat > "$BIN/python" <<'EOF'
#!/usr/bin/env bash
sleep 30
EOF
chmod +x "$BIN"/*
export PATH="$BIN:$PATH"

# serve_wait uses curl (stubbed to always refuse); shadow it to "ready" so the loop proceeds
serve_wait(){ return 0; }

fails=0
ok(){ echo "ok   $1"; }
no(){ echo "FAIL $1"; fails=1; }

# --- reference callbacks -----------------------------------------------------------------
CALLS="$TMP/serve_calls"; : > "$CALLS"
# serve stubs spawn a REAL bg process so the helper's kill -0 PID-liveness gate passes (teardown kills
# it). Redirect the bg process's fds (</dev/null >/dev/null 2>&1) so it does NOT hold the `$(serve_fn)`
# command-substitution pipe open — otherwise the capture blocks until the sleep exits.
ref_serve(){ echo "serve $1" >> "$CALLS"; sleep 30 </dev/null >/dev/null 2>&1 & echo $!; }  # $1=adapter $2=port $3=log; echo live PID
ref_eval(){ echo "result-for-$1" > "$2/result.txt"; }            # distinct content per adapter

# serve_adapters_eval calls die() (exit) on failure; run every invocation in a SUBSHELL so a
# catchable failure doesn't terminate the smoke. FS side-effects still land in $TMP (real files).

# --- 1. happy path: distinct adapters -> loop completes, isolated dirs, one serve each ---
OUT="$TMP/out1"
if ( serve_adapters_eval "$OUT" 8000 ref_serve ref_eval -- adapterA adapterB adapterC ) >/dev/null 2>&1; then ok loop-completes; else no loop-completes; fi
[ -f "$OUT/01-adapterA/result.txt" ] && [ -f "$OUT/02-adapterB/result.txt" ] && [ -f "$OUT/03-adapterC/result.txt" ] && ok isolated-dirs || no isolated-dirs
[ "$(grep -c . "$CALLS")" = 3 ] && ok serve-per-adapter || no "serve-per-adapter ($(grep -c . "$CALLS"))"

# --- 2. NO stale-cache reuse: a pre-planted .eval in the target dir must be WIPED, not reused ---
OUT2="$TMP/out2"; mkdir -p "$OUT2/01-adapterA"
echo STALE-DO-NOT-REUSE > "$OUT2/01-adapterA/old.eval"
( serve_adapters_eval "$OUT2" 8000 ref_serve ref_eval -- adapterA adapterB ) >/dev/null 2>&1
if [ ! -e "$OUT2/01-adapterA/old.eval" ] && [ -f "$OUT2/01-adapterA/result.txt" ]; then ok stale-cache-wiped; else no stale-cache-wiped; fi

# --- 3. teardown BETWEEN adapters (ordering): a teardown precedes the first serve and separates serves ---
ORDER="$TMP/order"; : > "$ORDER"
ord_serve(){ echo SERVE >> "$MA_SMOKE_ORDER"; sleep 30 </dev/null >/dev/null 2>&1 & echo $!; }
( MA_SMOKE_ORDER="$ORDER" serve_adapters_eval "$TMP/out3" 8000 ord_serve ref_eval -- a1 a2 ) >/dev/null 2>&1
DEDUP=$(awk 'NR==1||$0!=p{print}{p=$0}' "$ORDER" | tr '\n' ' ')
case "$DEDUP" in "KILL SERVE"*) ok teardown-before-first-serve ;; *) no "teardown-before-first-serve ($DEDUP)" ;; esac
if echo "$DEDUP" | grep -q "SERVE SERVE"; then no "teardown-between-serves ($DEDUP)"; else ok teardown-between-serves; fi

# --- 4. distinctness catches identical outputs: error mode DIES, warn mode CONTINUES ---
same_eval(){ echo IDENTICAL > "$2/result.txt"; }
if ( serve_adapters_eval "$TMP/out4" 8000 ref_serve same_eval -- a1 a2 ) >/dev/null 2>&1; then no distinctness-error-dies; else ok distinctness-error-dies; fi
if ( MA_DISTINCT_MODE=warn serve_adapters_eval "$TMP/out5" 8000 ref_serve same_eval -- a1 a2 ) >/dev/null 2>&1; then ok distinctness-warn-continues; else no distinctness-warn-continues; fi

# --- 5. serve_fn PID contract, fail-closed: non-numeric / empty / unsafe-0 / dead PID all die ---
bad_serve(){ echo "not-a-pid"; }
if ( serve_adapters_eval "$TMP/out6" 8000 bad_serve ref_eval -- a1 ) >/dev/null 2>&1; then no pid-contract-nonnumeric; else ok pid-contract-nonnumeric; fi
empty_serve(){ echo ""; }
if ( serve_adapters_eval "$TMP/out7" 8000 empty_serve ref_eval -- a1 ) >/dev/null 2>&1; then no pid-contract-empty; else ok pid-contract-empty; fi
zero_serve(){ echo 0; }                                    # 0 -> kill_tree KILL would hit the process group
if ( serve_adapters_eval "$TMP/out8" 8000 zero_serve ref_eval -- a1 ) >/dev/null 2>&1; then no pid-contract-zero; else ok pid-contract-zero; fi
dead_serve(){ echo 2147483646; }                           # numeric but not a live process -> kill -0 fails
if ( serve_adapters_eval "$TMP/out9" 8000 dead_serve ref_eval -- a1 ) >/dev/null 2>&1; then no pid-contract-dead; else ok pid-contract-dead; fi

# --- 6. default serve path (vllm_serve_lora) honors the PID contract: echoes a real numeric PID ---
def_serve(){ vllm_serve_lora /fake/base "$1" "$2" "$3"; }        # closes over a fake base model
PID=$(def_serve adapterX 8000 "$TMP/serve.log")
case "$PID" in ''|*[!0-9]*) no "default-serve-numeric-pid ($PID)";; *) ok default-serve-numeric-pid; kill "$PID" 2>/dev/null;; esac

# --- 7. self-safety (#299): a caller pattern that matches the DRIVER's own command line must not
# kill the driver. Stub pgrep to report the smoke's own PID (self-match) plus an unrelated survivor
# PID for the crafted pattern; override the `kill` builtin to LOG targets instead of signaling them,
# so a bug here can't actually kill this smoke run.
SELF=$$
cat > "$BIN/pgrep" <<EOF
#!/usr/bin/env bash
case "\$*" in
  *driver-pattern*) echo $SELF; echo 99999 ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$BIN/pgrep"
KILLED="$TMP/killed_pids"; : > "$KILLED"
kill(){ echo "$2" >> "$KILLED"; }   # override the builtin: record the target instead of signaling it
( MA_KILL_PATTERNS="driver-pattern" ma_teardown "" 8000 ) >/dev/null 2>&1
unset -f kill
grep -qx "$SELF" "$KILLED" && no "self-safety-no-self-kill (killed self pid $SELF)" || ok self-safety-no-self-kill
grep -qx "99999" "$KILLED" && ok self-safety-kills-others || no "self-safety-kills-others ($(cat "$KILLED"))"

[ "$fails" = 0 ] && { echo "PASS multi_adapter_smoke"; exit 0; } || { echo "FAIL multi_adapter_smoke"; exit 1; }
