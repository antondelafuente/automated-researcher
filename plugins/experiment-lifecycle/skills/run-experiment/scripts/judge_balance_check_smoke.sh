#!/usr/bin/env bash
# Smoke for judge_balance_check.sh — the pre-flight balance-vs-estimated-spend gate (#354). Behavior the
# deterministic JSON/syntax checks can't catch: argument validation, the below-threshold skip path, the
# sufficient-vs-insufficient balance decision at the estimated-remaining-spend boundary, the custom
# --threshold override, and the zero-rows-left trivial-OK case. Fully offline (pure arithmetic; no network,
# no real provider key).
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
B="$HERE/judge_balance_check.sh"
[ -f "$B" ] || { echo "FAIL: missing $B"; exit 1; }

fails=0
ok(){ echo "ok   $1"; }
no(){ echo "FAIL $1"; fails=1; }

# --- 1. argument validation ------------------------------------------------------------------
if bash "$B" >/dev/null 2>&1; then no missing-all-args-rejected; else ok missing-all-args-rejected; fi
if bash "$B" --balance 10 --rows-left 5 >/dev/null 2>&1; then no missing-rate-rejected; else ok missing-rate-rejected; fi
if bash "$B" --balance 10 --rate 0.01 >/dev/null 2>&1; then no missing-rows-left-rejected; else ok missing-rows-left-rejected; fi
if bash "$B" --rows-left 5 --rate 0.01 >/dev/null 2>&1; then no missing-balance-rejected; else ok missing-balance-rejected; fi
if bash "$B" --balance abc --rows-left 5 --rate 0.01 >/dev/null 2>&1; then no non-numeric-balance-rejected; else ok non-numeric-balance-rejected; fi
if bash "$B" --balance 10 --rows-left abc --rate 0.01 >/dev/null 2>&1; then no non-numeric-rows-left-rejected; else ok non-numeric-rows-left-rejected; fi
if bash "$B" --balance 10 --rows-left 5 --rate 0.01 --threshold abc >/dev/null 2>&1; then no non-numeric-threshold-rejected; else ok non-numeric-threshold-rejected; fi
if bash "$B" --balance -1 --rows-left 5 --rate 0.01 >/dev/null 2>&1; then no negative-balance-rejected; else ok negative-balance-rejected; fi
if bash "$B" --balance 10 --rows-left -1 --rate 0.01 >/dev/null 2>&1; then no negative-rows-left-rejected; else ok negative-rows-left-rejected; fi
if bash "$B" --balance 10 --rows-left 5 --rate 0.01 --bogus xyz >/dev/null 2>&1; then no unknown-flag-rejected; else ok unknown-flag-rejected; fi

# --- 2. below-threshold estimate always OK, regardless of balance -------------------------------
OUT=$(bash "$B" --balance 0 --rows-left 10 --rate 0.01)   # estimated $0.10 <= default $5 threshold
RC=$?
[ "$RC" = 0 ] && echo "$OUT" | grep -q '^OK:' && ok below-threshold-skips-check || no "below-threshold-skips-check (rc=$RC out=$OUT)"

# --- 3. zero rows left is trivially OK -----------------------------------------------------------
OUT=$(bash "$B" --balance 0 --rows-left 0 --rate 5)
RC=$?
[ "$RC" = 0 ] && echo "$OUT" | grep -q '^OK:' && ok zero-rows-left-ok || no "zero-rows-left-ok (rc=$RC out=$OUT)"

# --- 4. above-threshold, balance covers estimate -> OK -------------------------------------------
OUT=$(bash "$B" --balance 100 --rows-left 1000 --rate 0.05)   # estimated $50, threshold default $5
RC=$?
[ "$RC" = 0 ] && echo "$OUT" | grep -q '^OK:' && ok sufficient-balance-ok || no "sufficient-balance-ok (rc=$RC out=$OUT)"

# --- 5. above-threshold, balance short of estimate -> BLOCKED, exit 1 ----------------------------
OUT=$(bash "$B" --balance 10 --rows-left 1000 --rate 0.05)   # estimated $50 > balance $10
RC=$?
[ "$RC" = 1 ] && echo "$OUT" | grep -q '^BLOCKED:' && ok insufficient-balance-blocked || no "insufficient-balance-blocked (rc=$RC out=$OUT)"

# --- 6. custom --threshold changes the skip boundary ----------------------------------------------
# estimated $50 with balance $10 would BLOCK at the default threshold; raising --threshold above the
# estimate must skip the check regardless of the (insufficient) balance.
OUT=$(bash "$B" --balance 10 --rows-left 1000 --rate 0.05 --threshold 100)
RC=$?
[ "$RC" = 0 ] && echo "$OUT" | grep -q '^OK:' && ok custom-threshold-raises-skip-boundary || no "custom-threshold-raises-skip-boundary (rc=$RC out=$OUT)"

[ "$fails" = 0 ] && { echo "judge_balance_check smoke PASS"; exit 0; } || { echo "judge_balance_check smoke FAIL"; exit 1; }
