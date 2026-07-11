#!/bin/bash
# judge_balance_check.sh — pre-flight balance-vs-estimated-spend check for a long LLM-judge (or other
# metered-API) driver (#354).
#
# Incident: a dedicated OpenRouter judge key ran out of credits mid-judging-run TWICE in the same
# experiment close — once starting from ~$0 balance (no check before launch), and again after a top-up
# that lasted only 1-2 hours of judging. Each depletion was discovered only via a burst of runtime
# `JUDGE_CALL_FAILED ... Insufficient credits` errors, not proactively, costing a work stoppage and a
# human round-trip each time. This helper is the arithmetic side of the fix: it takes a balance number you
# already fetched (however your instance's cost_policy recipe says to fetch it — this script has no
# opinion on the provider or the fetch command) and decides whether that balance covers the estimated
# remaining spend for the rows still left to judge, so depletion is caught before (re)launching instead of
# via a runtime error burst.
#
# USAGE: judge_balance_check.sh --balance <dollars> --rows-left <int> --rate <dollars-per-row> [--threshold <dollars>]
#   --balance     current provider balance in dollars (float >= 0)
#   --rows-left   rows still to judge (int >= 0)
#   --rate        THIS run's own observed $/row (float >= 0) — measure it live, don't guess
#   --threshold   estimated-remaining-spend floor below which the check is skipped (default 5) — mirrors
#                 "any judge run estimated to cost more than some threshold" from the incident writeup
#
# Prints one line and exits 0 ("OK: ...") when the estimated remaining spend (rows-left * rate) is at/under
# the threshold, or when the balance covers it. Exits 1 ("BLOCKED: ...") when the estimate exceeds both the
# threshold and the current balance — top up or switch keys before (re)launching. Run this before every
# (re)launch of a long-running judge driver, not just the first one (the incident hit both cases).
set -euo pipefail

die(){ echo "judge_balance_check: $*" >&2; exit 1; }

balance="" rows_left="" rate="" threshold=5
while [ $# -gt 0 ]; do
  case "$1" in
    --balance) balance=${2:-}; shift 2 ;;
    --rows-left) rows_left=${2:-}; shift 2 ;;
    --rate) rate=${2:-}; shift 2 ;;
    --threshold) threshold=${2:-}; shift 2 ;;
    *) die "unknown argument: $1 (usage: --balance <dollars> --rows-left <int> --rate <dollars-per-row> [--threshold <dollars>])" ;;
  esac
done

[ -n "$balance" ] && [ -n "$rows_left" ] && [ -n "$rate" ] \
  || die "usage: judge_balance_check.sh --balance <dollars> --rows-left <int> --rate <dollars-per-row> [--threshold <dollars>]"

set +e
output=$(BALANCE="$balance" ROWS_LEFT="$rows_left" RATE="$rate" THRESHOLD="$threshold" python3 - <<'PY'
import os
import sys

try:
    balance = float(os.environ["BALANCE"])
    rate = float(os.environ["RATE"])
    threshold = float(os.environ["THRESHOLD"])
    rows_left = int(os.environ["ROWS_LEFT"])
except ValueError as e:
    print(f"invalid numeric argument: {e}", file=sys.stderr)
    sys.exit(2)

if balance < 0 or rate < 0 or threshold < 0 or rows_left < 0:
    print("balance, rows-left, rate, and threshold must all be non-negative", file=sys.stderr)
    sys.exit(2)

estimated = rows_left * rate
if estimated <= threshold:
    print(f"OK: estimated remaining spend ${estimated:.2f} ({rows_left} rows x ${rate:.4f}/row) "
          f"<= threshold ${threshold:.2f} -- no balance check needed")
    sys.exit(0)
if balance < estimated:
    print(f"BLOCKED: estimated remaining spend ${estimated:.2f} ({rows_left} rows x ${rate:.4f}/row) "
          f"exceeds current balance ${balance:.2f} -- top up or switch keys before (re)launching")
    sys.exit(1)
print(f"OK: balance ${balance:.2f} covers estimated remaining spend ${estimated:.2f} "
      f"({rows_left} rows x ${rate:.4f}/row)")
sys.exit(0)
PY
)
code=$?
set -e

[ "$code" = 2 ] && die "$output"
echo "$output"
exit "$code"
